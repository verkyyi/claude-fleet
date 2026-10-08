#!/bin/bash
# fleet-onboard-clock.sh --hub <url|prod> [--runs N] [--host <machine>] [--login <drill…>]
#                        [--hand <secs>] [--budget <secs>] [--gate all|pits] [--out <dir>] [--keep]
#   — the 60-second standard, measured (claude-fleet#2267, EPIC #2259 C8): a
#     clean computer from the pasted line to the first key the agent takes,
#     timed in segments, with every known way a newcomer got stuck checked on
#     the way. Run it after any change to the install, the login or the client.
#
# Each run is a SANDBOX on this computer, never a new OS login (EPIC #2259
# 共同约定 6): a fresh HOME with no ~/.config/claude-fleet, no ~/.local, no
# Homebrew on PATH (/usr/bin:/bin:/usr/sbin:/sbin only), its own TMPDIR and
# TMUX_TMPDIR (so no tmux server of the sandbox can meet one of yours), driven
# in a terminal of the run's own tmux server (-S <sandbox>/drill.sock):
#
#   t_enter      the pasted `curl -fsSL <hub>/i/<invite> | sh` + Enter
#   t_installed  the installer's 「用时 N 秒」 (it then runs `fleet` by itself)
#   t_browser    `fleet` opened the authorize page — a stand-in `open` on PATH
#                takes it (FLEET_LOGIN_BROWSER=1); the person's hand is
#                --hand seconds (10), then the drill confirm code approves it
#                (POST /fleet/login/approve, bin/fleet-drill.sh approve)
#   t_cert       the certificate is in ~/.ssh
#   t_machine    the first HOME session is placed (conf dir's home-session.first)
#   t_ready      the agent's input line (❯ / ›) is on the screen
#   t_key        one typed letter stays on that line — Claude's TUI drops what
#                arrives while it mounts, so a letter that vanished is typed
#                again, and t_key is when one stayed
#
# Segments (the table): 安装 = t_installed − t_enter · 浏览器授权 = t_cert −
# t_installed (the hand included) · 拿到电脑 = t_machine − t_cert · 进会话 =
# t_ready − t_machine · 第一键 = t_key − t_ready · 合计 = t_key − t_enter.
#
# The five readings (EPIC #2259 指标): 合计 (the max over the runs ≤ --budget,
# 60) · 步骤 (what a PERSON did: the paste, the authorize, plus every Enter the
# drill had to give a question, and a phone scan if the browser path was not
# taken — target 2) · 管理员 (a refusal that sends the person to an admin —
# target 0) · 概念 (the fleet words on the screen before the first key: 入口 ·
# 只看只派/承载 · 扫码签发 · 列表与右侧 · 前缀键 · 选仓库 · 开在哪 · 记成
# issue/草稿会话 — target 0) · 坑 (the eight known ones, each PASS/FAIL —
# target 0 FAIL):
#
#   ① 企业微信 on no screen
#   ② the 验证码 on the terminal within 15 s of `fleet` asking for a login
#   ③ the authorize link opened in WeChat's in-app browser is a page (2xx/3xx),
#      not the API's JSON 401
#   ④ no screen stands still past 15 s (outside the hand) — every wait talks
#   ⑤ the certificate names the person's own login (--login / the minted one),
#      not one left on the machine
#   ⑥ the HOME session is placed for that person (a machine named)
#   ⑦ no 「没有活着的」 / 「正在连接 <this computer>」: the client never tries a
#      fleet this computer does not run
#   ⑧ no 「没有在线的机器」, and the typed letter lands in the agent's input
#
# Who the person is: --mint (the default with no FLEET_DRILL_INVITE) asks the
# hub for a drill person per run (bin/fleet-drill.sh invite --host <machine>
# --login <login>) and an invite (fleet hub invite) — as YOU (your connection
# certificate, else CCQUOTA_VIEWER_TOKEN) — and deletes the person at the end
# (DELETE /v1/self with its own code). Or hand them in: FLEET_DRILL_INVITE (the
# fd_… approve code, one run) and FLEET_DRILL_INSTALL_INVITE (an invite code;
# none → the plain /install line). Codes live in variables only: every saved
# screen has them blanked (共同约定 7).
#
# A real hub places the HOME session on a real machine as the drill person's
# login: that login must exist there (a spare, #2263) — creating one is the
# operator's call (共同约定 6), never this script's.
#
# Output: the run's directory (--out, else a temp dir) holds screens/,
# report.md (the table, for the EPIC page) and clock.tsv (one row per run:
# run t_enter t_installed t_browser t_cert t_machine t_ready t_key, ms since
# t_enter); report.md is also printed.
#
# The sandbox's computer is named newcomer-<run>-<pid> (FLEET_DEVICE_NAME): a
# newcomer's computer is never named like a fleet machine, the drill's runs on one.
#
# Exit: 0 every reading on target · 1 a reading missed (the table says which) ·
#       2 usage / preflight. --gate pits (CI on a fake hub, whose seconds and
#       words are not a newcomer's): 0 when every run reached its first key and
#       no pit failed — the other readings are printed, not judged.
# Env: FLEET_CLOCK_SSH_SHIM=<dir> (selftests / CI: put first on the sandbox's
#      PATH — a fake node has no sshd) · FLEET_CLOCK_STEP_SECS (180, the deadline
#      of each wait) · FLEET_CLOCK_POLL (0.25)
set -u

PROG=fleet-onboard-clock
BIN="$(cd "$(dirname "$0")" && pwd -P)"
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

HUB='' RUNS=1 HOST='' LOGIN='' HAND=10 BUDGET=60 OUT='' KEEP=0 MINT='' GATE=all SEAM=''
STEP_SECS=${FLEET_CLOCK_STEP_SECS:-180}
POLL=${FLEET_CLOCK_POLL:-0.25}
while [ $# -gt 0 ]; do
  case "$1" in
    --hub)    [ $# -ge 2 ] || usage; HUB=$2; shift 2 ;;
    --runs)   [ $# -ge 2 ] || usage; RUNS=$2; shift 2 ;;
    --host)   [ $# -ge 2 ] || usage; HOST=$2; shift 2 ;;
    --login)  [ $# -ge 2 ] || usage; LOGIN=$2; shift 2 ;;
    --hand)   [ $# -ge 2 ] || usage; HAND=$2; shift 2 ;;
    --budget) [ $# -ge 2 ] || usage; BUDGET=$2; shift 2 ;;
    --out)    [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    --gate)   [ $# -ge 2 ] || usage; GATE=$2; shift 2 ;;
    --mint)   MINT=1; shift ;;
    --keep)   KEEP=1; shift ;;
    --concepts-of) SEAM=concepts; shift ;;   # selftest seam: a screen on stdin
    --scrub-of)    SEAM=scrub; shift ;;      # selftest seam: text on stdin
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die2 "unknown argument: $1" ;;
  esac
done
# --- helpers --------------------------------------------------------------------
nowms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
SECRETS=()
# blank every code this run holds (and any 验证码 / fd_ / invite-shaped word)
scrub() {
  local s sedargs=()
  for s in ${SECRETS[@]+"${SECRETS[@]}"}; do sedargs+=(-e "s/$s/…/g"); done
  sed ${sedargs[@]+"${sedargs[@]}"} -E -e 's/fd_[a-z2-7]{20,}/fd_…/g' -e 's#/i/[A-Za-z0-9_-]{16,64}#/i/…#g' \
      -e 's/(code=)[A-Z]{4}-[A-Z]{4}/\1…/g'
}
# hub_admin <args…>: `fleet hub …` as this computer's own person
hub_admin() { FLEET_HUB_URL="$HUB" python3 "$BIN/fleet-hub-admin.py" "$@"; }
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d.get(k, "") if isinstance(d, dict) else ""
print(d)' "$1"; }
# concepts <known…> (a screen on stdin): the known ones and those on the screen,
# one space-separated line — python, as a BSD `grep -o` drops all but the first
# alternative of a multibyte alternation
concepts() {
  python3 -c 'import re, sys
seen = set(sys.argv[2:]) | set(re.findall(sys.argv[1], sys.stdin.read()))
print(" ".join(sorted(seen)))' "$CONCEPTS" "$@"
}
CONCEPTS='入口|只看只派|只看、只派|承载|只协调|扫码|签发证书|右侧|右栏|左侧列表|前缀键|prefix key|选仓库|选择仓库|哪个仓库|开在哪|记成 ?issue|草稿会话'

case "$SEAM" in
  concepts) concepts; exit 0 ;;
  scrub)    SECRETS=(); scrub; exit 0 ;;
esac

for v in "RUNS=$RUNS" "HAND=$HAND" "BUDGET=$BUDGET" "STEP_SECS=$STEP_SECS"; do
  printf '%s' "${v#*=}" | grep -Eq '^[0-9]+$' || die2 "${v%%=*}: not a number: '${v#*=}'"
done
[ "$RUNS" -ge 1 ] && [ "$RUNS" -le 10 ] || die2 '--runs: 1 to 10'
case "$GATE" in all|pits) ;; *) die2 "--gate: all or pits (got '$GATE')" ;; esac
case "$HUB" in
  prod|'') HUB=$(sed -n 's/^export FLEET_HUB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' \
                   "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.conf" 2>/dev/null | head -n 1) ;;
esac
case "$HUB" in http://*|https://*) HUB=${HUB%/} ;; *) die2 'no hub: --hub https://<入口> (or prod: the FLEET_HUB_URL in your fleet.conf)' ;; esac
# the codes come from the environment (never an argv) and leave it at once
APPROVE_IN=${FLEET_DRILL_INVITE:-}; INVITE_IN=${FLEET_DRILL_INSTALL_INVITE:-}
unset FLEET_DRILL_INVITE FLEET_DRILL_INSTALL_INVITE
if [ -n "$APPROVE_IN" ]; then
  printf '%s' "$APPROVE_IN" | grep -Eq '^fd_[a-z2-7]{26}$' || die2 'FLEET_DRILL_INVITE is not an approve code (fd_…)'
  [ "$RUNS" = 1 ] || die2 'FLEET_DRILL_INVITE is one person: --runs 1 (or --mint, a person per run)'
  [ -n "$LOGIN" ] || die2 'FLEET_DRILL_INVITE needs --login <the login fleet drill invite printed>'
  [ -z "$MINT" ] || die2 '--mint and FLEET_DRILL_INVITE: one or the other'
else
  MINT=1
fi
[ -z "$INVITE_IN" ] || printf '%s' "$INVITE_IN" | grep -Eq '^[A-Za-z0-9_-]{16,64}$' || die2 'FLEET_DRILL_INSTALL_INVITE is not an invite code'
for t in curl python3 ssh-keygen; do command -v "$t" >/dev/null 2>&1 || die2 "$t not found"; done
TMUXB=$(command -v tmux 2>/dev/null || :)
[ -n "$TMUXB" ] || for t in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do [ -x "$t" ] && TMUXB=$t && break; done
[ -n "$TMUXB" ] || die2 'tmux not found (the drill needs one terminal of its own)'
PSHELL=/bin/zsh; [ -x "$PSHELL" ] || PSHELL=/bin/bash
SHIM_IN=${FLEET_CLOCK_SSH_SHIM:-}
[ -z "$SHIM_IN" ] || [ -d "$SHIM_IN" ] || die2 "FLEET_CLOCK_SSH_SHIM: no such directory $SHIM_IN"
# this computer's name as the client reads it (a stand-in `hostname` in the shim wins)
LOCALHOST=$(PATH="${SHIM_IN:+$SHIM_IN:}$PATH" hostname -s 2>/dev/null || hostname)

[ -n "$OUT" ] || OUT=$(mktemp -d "${TMPDIR:-/tmp}/fleet-onboard-clock.XXXXXX") || die2 'mktemp failed'
mkdir -p "$OUT/screens" || die2 "cannot write $OUT"
chmod 700 "$OUT"
printf '%s: hub=%s  runs=%s  hand=%ss  budget=%ss  person=%s  out %s\n' "$PROG" "$HUB" "$RUNS" "$HAND" "$BUDGET" \
  "$([ -n "$MINT" ] && echo 'minted per run' || echo "FLEET_DRILL_INVITE ($LOGIN)")" "$OUT"

# --- one run --------------------------------------------------------------------
# run_one <n>: fills R_* (times in ms since t_enter, '' = not reached) and P_* (坑)
run_one() {
  local n=$1 sb login approve invite inv_id url sock first opened code key_at hand_at tries
  local p last_p last_change gap maxgap t0 deadline seen ready_seen
  R_installed='' R_browser='' R_cert='' R_machine='' R_ready='' R_key='' R_why=''
  R_steps=1 R_admin=0 R_concepts='' R_gap=0 R_code_after='' R_tries=0
  P2=FAIL P3=FAIL P5=FAIL P6=FAIL P7=PASS P8=PASS P1=PASS P4=PASS
  sb=$(mktemp -d /tmp/fod.XXXXXX) || { R_why='mktemp failed'; return 1; }
  mkdir -p "$sb/home/.ssh" "$sb/tmp" "$sb/t" "$sb/shim" "$sb/admin"; chmod 700 "$sb/home/.ssh" "$sb/t"
  sock="$sb/drill.sock"
  login=$LOGIN approve=$APPROVE_IN invite=$INVITE_IN inv_id=''
  if [ -n "$MINT" ]; then
    [ -n "$login" ] || login="drill$(date +%d%H%M%S | cut -c1-8)"
    [ "$RUNS" = 1 ] || login="$(printf '%s' "$login" | cut -c1-10)$n"
    local d
    d=$(bash "$BIN/fleet-drill.sh" invite ${HOST:+--host "$HOST"} --login "$login" --ttl 30m --json 2>"$sb/mint.err") \
      || { R_why="fleet drill invite failed: $(tail -n 1 "$sb/mint.err")"; cleanup_run "$sb"; return 1; }
    approve=$(printf '%s' "$d" | jget approve_code)
    [ -n "$approve" ] || { R_why='fleet drill invite answered no approve code'; cleanup_run "$sb"; return 1; }
    if [ -z "$INVITE_IN" ]; then
      d=$(hub_admin invite --json 2>"$sb/mint.err") || d=''
      invite=$(printf '%s' "$d" | jget code 2>/dev/null); inv_id=$(printf '%s' "$d" | jget id 2>/dev/null)
      [ -n "$invite" ] || printf '        (no invite minted — %s; the plain /install line)\n' "$(tail -n 1 "$sb/mint.err" 2>/dev/null)"
    fi
  fi
  SECRETS=("$approve"); [ -n "$invite" ] && SECRETS+=("$invite")
  url="$HUB/install"; [ -n "$invite" ] && url="$HUB/i/$invite"

  # the browser: the page the person would click on; the drill's hand takes it
  cat > "$sb/shim/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$sb/opened.tmp" && mv "$sb/opened.tmp" "$sb/opened"
EOF
  cp "$sb/shim/open" "$sb/shim/xdg-open"; chmod +x "$sb/shim/open" "$sb/shim/xdg-open"
  local pth="$sb/shim:/usr/bin:/bin:/usr/sbin:/sbin"
  [ -n "$SHIM_IN" ] && pth="$SHIM_IN:$pth"
  # the person's terminal: a shell with nothing of yours in its environment
  TMUX='' "$TMUXB" -S "$sock" -f /dev/null new-session -d -s drill -x 160 -y 48 \
    env -i HOME="$sb/home" PATH="$pth" TERM=xterm-256color LANG=zh_CN.UTF-8 LC_CTYPE=zh_CN.UTF-8 \
      SHELL=/bin/zsh USER="$(id -un)" LOGNAME="$(id -un)" TMPDIR="$sb/tmp" TMUX_TMPDIR="$sb/t" \
      FLEET_LOGIN_BROWSER=1 FLEET_DEVICE_NAME="newcomer-$n-$$" PS1='newcomer% ' "$PSHELL" -f \
    || { R_why='the drill terminal did not start'; cleanup_run "$sb"; return 1; }
  sleep 0.5
  dt() { TMUX='' "$TMUXB" -S "$sock" "$@"; }
  dt send-keys -t drill -l "curl -fsSL $url | sh"
  dt send-keys -t drill Enter
  t0=$(nowms)
  last_p='' last_change=$t0 maxgap=0 first='' opened='' code='' key_at='' hand_at='' tries=0 ready_seen=''
  deadline=$(( $(date +%s) + STEP_SECS * 3 ))
  local shot=0 cert="$sb/home/.ssh/fleet-cert-cert.pub" conf="$sb/home/.config/claude-fleet" el
  while :; do
    p=$(dt capture-pane -p -t drill 2>/dev/null)
    el=$(( $(nowms) - t0 ))
    if [ "$p" != "$last_p" ]; then
      shot=$((shot + 1))
      printf '%s\n' "$p" | scrub > "$OUT/screens/run$n-$(printf '%03d' "$shot")-${el}ms.txt"
      last_p=$p last_change=$(nowms)
    else
      gap=$(( $(nowms) - last_change ))
      # the hand is the person's own pause, not a silent screen
      if [ -z "$hand_at" ] || [ -n "$R_cert" ]; then [ "$gap" -gt "$maxgap" ] && maxgap=$gap; fi
    fi
    # before the first key: what the person reads
    if [ -z "$R_key" ]; then
      printf '%s\n' "$p" | grep -q '企业微信' && P1=FAIL
      printf '%s\n' "$p" | grep -Eq "没有活着的|正在连接 $LOCALHOST([^A-Za-z0-9._-]|\$)" && P7=FAIL
      printf '%s\n' "$p" | grep -q '没有在线的机器' && P8=FAIL
      R_concepts=$(printf '%s\n' "$p" | concepts $R_concepts)
      if printf '%s\n' "$p" | grep -Eq '找管理员|联系管理员|请管理员|ask (your|an) admin|not_invited|不在名单'; then
        R_admin=1; R_why='the screen sends the person to an admin'; break
      fi
      # a question the drill has to answer: a step a person takes
      if printf '%s\n' "$p" | tail -n 3 | grep -Eq '回车 = [0-9]+ ›|\[[yY]/[nN]\]|按回车继续|Press Enter' \
         && [ $(( $(nowms) - last_change )) -gt 3000 ]; then
        dt send-keys -t drill Enter; R_steps=$((R_steps + 1)); last_change=$(nowms)
      fi
    fi
    [ -z "$R_installed" ] && printf '%s\n' "$p" | grep -Eq '^用时 [0-9]+ 秒' && R_installed=$el
    # `fleet` asked for a login: the code must be on the terminal within 15 s
    if [ -z "$first" ] && printf '%s\n' "$p" | grep -Eq '需要登录|已在浏览器里打开|用手机扫码|浏览器打不开'; then first=$el; fi
    if [ -n "$first" ] && [ -z "$R_code_after" ] && printf '%s\n' "$p" | grep -Eq '[A-Z]{4}-[A-Z]{4}'; then
      R_code_after=$(( el - first ))
    fi
    if [ -z "$opened" ] && [ -s "$sb/opened" ]; then
      opened=$(cat "$sb/opened"); R_browser=$el
      [ -z "$R_installed" ] && R_installed=$el
      code=$(printf '%s' "$opened" | grep -Eo 'code=[A-Z]{4}-[A-Z]{4}' | head -n 1 | cut -d= -f2)
      [ -n "$code" ] && SECRETS+=("$code")
      # ③ the same link in WeChat's in-app browser: a page, never the API's 401
      local wc
      wc=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Accept: text/html,application/xhtml+xml' \
             -H 'User-Agent: Mozilla/5.0 (iPhone) AppleWebKit/605.1.15 MicroMessenger/8.0.50' \
             -H 'X-Requested-With: com.tencent.mm' "$opened" 2>/dev/null)
      case "$wc" in 2??|3??) P3=PASS ;; *) P3="FAIL($wc)" ;; esac
      hand_at=$(nowms)
    fi
    # no browser (the QR road): the 验证码 on the screen is what a phone scans
    if [ -z "$opened" ] && [ -z "$hand_at" ] && printf '%s\n' "$p" | grep -q '用手机扫码'; then
      code=$(printf '%s\n' "$p" | grep -Eo '[A-Z]{4}-[A-Z]{4}' | head -n 1)
      if [ -n "$code" ]; then SECRETS+=("$code"); R_browser=$el; R_steps=$((R_steps + 1)); P3=SKIP; hand_at=$(nowms); fi
    fi
    # the hand: --hand seconds after the page opened, the person clicks 确认签发
    if [ -n "$hand_at" ] && [ -n "$code" ] && [ -z "$R_cert" ] && [ "$hand_at" != done ] \
       && [ $(( $(nowms) - hand_at )) -ge $(( HAND * 1000 )) ]; then
      env -i PATH="$PATH" HOME="$sb/admin" FLEET_CONF_DIR="$sb/admin/conf" FLEET_HUB_URL="$HUB" \
          FLEET_DRILL_INVITE="$approve" bash "$BIN/fleet-drill.sh" approve "$code" >"$sb/approve.out" 2>&1 \
        || { R_why="the drill could not confirm the login: $(tail -n 1 "$sb/approve.out" | scrub)"; break; }
      R_steps=$((R_steps + 1)); hand_at=done
    fi
    [ -z "$R_cert" ] && [ -s "$cert" ] && R_cert=$el
    [ -z "$R_machine" ] && [ -e "$conf/home-session.first" ] && R_machine=$el
    # the agent's input line: after the session is placed, a line led by ❯ / ›
    if [ -n "$R_machine" ] && [ -z "$R_key" ]; then
      if printf '%s\n' "$p" | grep -Eq '^[ │|]*[❯›>]( |$)'; then
        [ -z "$R_ready" ] && R_ready=$el
        if printf '%s\n' "$p" | grep -Eq '^[ │|]*[❯›>] +z( |$)'; then
          R_key=$(( key_at - t0 ))
          dt send-keys -t drill BSpace
        elif [ -z "$key_at" ] || [ $(( $(nowms) - key_at )) -gt 1500 ]; then
          # typed, and gone after 1.5 s: the TUI was still mounting — type it again
          tries=$((tries + 1)); key_at=$(nowms)
          dt send-keys -t drill -l z
        fi
      fi
    fi
    [ -n "$R_key" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then R_why='deadline'; break; fi
    # the installer or the client gave up: nothing more will come
    if printf '%s\n' "$p" | tail -n 2 | grep -q '^newcomer% *$' && [ -n "$R_installed" ] && [ -z "$R_machine" ] \
       && [ $(( $(nowms) - last_change )) -gt 5000 ]; then
      R_why="back at the prompt: $(printf '%s\n' "$p" | grep -v '^ *$' | tail -n 3 | head -n 1 | scrub)"; break
    fi
    sleep "$POLL"
  done
  R_gap=$maxgap R_tries=$tries
  [ -n "$R_code_after" ] && [ "$R_code_after" -le 15000 ] && P2=PASS
  [ "$maxgap" -gt 15000 ] && P4="FAIL($((maxgap / 1000))s)"
  if [ -s "$cert" ]; then
    local princ
    princ=$(ssh-keygen -L -f "$cert" 2>/dev/null | awk '/Principals:/{f=1;next} f&&/:/{f=0} f{print $1}' | tr '\n' ' ')
    case " $princ" in *" $login "*) P5=PASS ;; *) P5="FAIL($princ)" ;; esac
  fi
  if [ -e "$conf/home-session.first" ]; then
    local hl
    hl=$(grep -E '^REMOTE ' "$sb/home/.cache/claude-fleet/shell/home-first.log" 2>/dev/null | tail -n 1)
    case "$hl" in REMOTE\ *\ done\ *) P6=PASS ;; *) P6='FAIL(no REMOTE … done)' ;; esac
  fi
  [ -z "$R_key" ] && [ "$P8" = PASS ] && P8='FAIL(no key)'
  [ -n "$R_key" ] || [ -n "$R_why" ] || R_why='no first key'
  # the last screen, for the reading
  dt capture-pane -p -t drill 2>/dev/null | scrub > "$OUT/screens/run$n-last.txt"
  teardown_person "$sb" "$approve" "$inv_id"
  cleanup_run "$sb"
}

# teardown_person <sb> <approve> <invite id>: a minted person deletes itself;
# an invite it never spent is revoked
teardown_person() {
  [ -n "$MINT" ] || return 0
  local code
  code=$(printf '{"approve_code":"%s"}' "$2" | curl -s -m 10 -o "$1/self.out" -w '%{http_code}' \
           -X DELETE -H 'Content-Type: application/json' --data-binary @- "$HUB/v1/self")
  case "$code" in 200|204) ;; *) printf '        ⚠ the drill person was not deleted (HTTP %s) — it lapses with its ttl\n' "$code" ;; esac
  [ -n "$3" ] && hub_admin invite --revoke "$3" >/dev/null 2>&1
  return 0
}
cleanup_run() {
  local sb=$1 s
  for s in "$sb"/t/tmux-*/*; do [ -S "$s" ] && TMUX='' "$TMUXB" -S "$s" kill-server 2>/dev/null; done
  TMUX='' "$TMUXB" -S "$sb/drill.sock" kill-server 2>/dev/null
  pkill -f "$sb/" 2>/dev/null
  sleep 0.3; pkill -9 -f "$sb/" 2>/dev/null
  [ "$KEEP" = 1 ] && { printf '        sandbox kept: %s\n' "$sb"; return 0; }
  rm -rf "$sb"
}

# --- the runs -------------------------------------------------------------------
sec() { [ -n "$1" ] && awk -v a="$1" -v b="${2:-0}" 'BEGIN { printf "%.1f", (a - b) / 1000 }' || printf '—'; }
printf 'run\tt_enter\tt_installed\tt_browser\tt_cert\tt_machine\tt_ready\tt_key\n' > "$OUT/clock.tsv"
ROWS='' PITS='' MAX=0 FAILED=0 STEPS_MAX=0 ADMIN_MAX=0 CONCEPTS_ALL='' PIT_FAILS=0
i=1
while [ "$i" -le "$RUNS" ]; do
  printf '== run %s/%s\n' "$i" "$RUNS"
  run_one "$i"
  printf '%s\t0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$R_installed" "$R_browser" "$R_cert" "$R_machine" "$R_ready" "$R_key" >> "$OUT/clock.tsv"
  total=$(sec "$R_key")
  ROWS="$ROWS| $i | $(sec "$R_installed") | $(sec "$R_cert" "$R_installed") | $(sec "$R_machine" "$R_cert") | $(sec "$R_ready" "$R_machine") | $(sec "$R_key" "$R_ready") | **$total** | ${R_why:-—} |
"
  PITS="$PITS| $i | $P1 | $P2 | $P3 | $P4 | $P5 | $P6 | $P7 | $P8 |
"
  for p in "$P1" "$P2" "$P3" "$P4" "$P5" "$P6" "$P7" "$P8"; do case "$p" in FAIL*) PIT_FAILS=$((PIT_FAILS + 1)) ;; esac; done
  if [ -n "$R_key" ]; then [ "$R_key" -gt "$MAX" ] && MAX=$R_key; else FAILED=$((FAILED + 1)); fi
  [ "$R_steps" -gt "$STEPS_MAX" ] && STEPS_MAX=$R_steps
  [ "$R_admin" -gt "$ADMIN_MAX" ] && ADMIN_MAX=$R_admin
  CONCEPTS_ALL="$CONCEPTS_ALL $R_concepts"
  printf '   合计 %ss · 步骤 %s · 管理员 %s · 第一键打了 %s 次 · 最长无声 %ss%s\n' "$total" "$R_steps" "$R_admin" \
    "${R_tries:-0}" "$(sec "$R_gap")" "${R_why:+ · $R_why}"
  i=$((i + 1))
done

CONCEPTS_ALL=$(printf '%s\n' $CONCEPTS_ALL | LC_ALL=C sort -u | grep -v '^$' | tr '\n' ' ' | sed 's/ $//')
NCON=0; [ -n "$CONCEPTS_ALL" ] && NCON=$(printf '%s\n' $CONCEPTS_ALL | wc -l | tr -d ' ')
verdict() { [ "$1" = 1 ] && printf '✓' || printf '✗'; }
ok_time=0; [ "$FAILED" = 0 ] && [ "$MAX" -le $((BUDGET * 1000)) ] && ok_time=1
ok_steps=0; [ "$STEPS_MAX" -le 2 ] && ok_steps=1
ok_admin=0; [ "$ADMIN_MAX" = 0 ] && ok_admin=1
ok_con=0; [ "$NCON" = 0 ] && ok_con=1
ok_pit=0; [ "$PIT_FAILS" = 0 ] && ok_pit=1
maxs=$([ "$FAILED" = 0 ] && sec "$MAX" || printf '没走通 %s 次' "$FAILED")
{
  printf '## 60 秒上手 · %s · %s 次 · %s\n\n' "$HUB" "$RUNS" "$(date '+%Y-%m-%d %H:%M')"
  printf '| 指标 | 读数 | 目标 | |\n|---|---|---|---|\n'
  printf '| 粘贴 → 第一键（%s 次最大值） | %s s | ≤ %s s | %s |\n' "$RUNS" "$maxs" "$BUDGET" "$(verdict $ok_time)"
  printf '| 新人自己动手的步骤 | %s | 2 | %s |\n' "$STEPS_MAX" "$(verdict $ok_steps)"
  printf '| 需要管理员当场配合 | %s | 0 | %s |\n' "$ADMIN_MAX" "$(verdict $ok_admin)"
  printf '| 第一句话前碰到的 fleet 概念 | %s%s | 0 | %s |\n' "$NCON" "${CONCEPTS_ALL:+（${CONCEPTS_ALL}）}" "$(verdict $ok_con)"
  printf '| 已知的坑没修好 | %s | 0 | %s |\n\n' "$PIT_FAILS" "$(verdict $ok_pit)"
  printf '分段（秒；授权含 %s 秒人手）\n\n| 次 | 安装 | 浏览器授权 | 拿到电脑 | 进会话 | 第一键 | 合计 | 备注 |\n|---|---|---|---|---|---|---|---|\n%s\n' "$HAND" "$ROWS"
  printf '八个坑：①企业微信 ②验证码 15 秒内上屏 ③微信内置浏览器打开授权页 ④没有 15 秒以上的无声等待 ⑤证书是本人的登录 ⑥会话开给本人 ⑦不去连本机没有的 fleet ⑧不说「没有在线的机器」、字落进 Agent\n\n'
  printf '| 次 | ① | ② | ③ | ④ | ⑤ | ⑥ | ⑦ | ⑧ |\n|---|---|---|---|---|---|---|---|---|\n%s' "$PITS"
} > "$OUT/report.md"
printf '\n'; cat "$OUT/report.md"
printf '\n%s: %s (screens, clock.tsv, report.md)\n' "$PROG" "$OUT"
if [ "$GATE" = pits ]; then [ "$FAILED" = 0 ] && [ "$ok_pit" = 1 ]
else [ $((ok_time + ok_steps + ok_admin + ok_con + ok_pit)) = 5 ]; fi
