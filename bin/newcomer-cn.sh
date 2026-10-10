#!/bin/bash
# newcomer-cn.sh [--hub <url>] [--host <machine>] [--connect <machine>] [--login drill<x>]
#                [--out <dir>] [--proxy <url>] [--keep]
#   — a newcomer's whole first time against the REAL hub, from a 国内 network
#     (issue #2888): the GitHub Actions runner in the Shenzhen ACK cluster
#     (`runs-on: ack`, newcomer-cn.yml — staged in extras/workflows/) is a Linux box behind
#     the same Great Firewall Arvin's new machine was. Every step is timed and
#     judged by bin/fleet-onboard-judge.sh — the screens fleet-onboard-drill.sh
#     (macOS) reads the same way.
#
#   1 user     a clean throwaway login (`useradd -m`, removed at the end): no
#              ~/.ssh, no ~/.config/claude-fleet, no ~/.local — nothing of ours
#   2 invite   `fleet drill invite --host <machine>` as the ADMIN (the token in
#              the environment, never in the newcomer's): the stand-in person
#              whose one-time approve code confirms the scan
#   3 install  `curl -fsSL <hub>/install | sh` as the login     ≤ 60 s
#   4 login    `fleet login`, the 验证码 confirmed by the drill code (no scan) ≤ 10 s
#   5 session  `fleet claude --new <一句话>` in a terminal of its own: the hub
#              opens the drill person a login on a machine and a HOME session
#              there; its screen drawn                               ≤ 120 s
#   6 answer   that session's agent answers the sentence (⏺ … 好)    ≤ 180 s
#   7 connect  `fleet connect <machine> -- true` — the relay's bare ssh, the
#              machine the session landed on (--connect overrides)  ≤ 2 s
#   8 doctor   `fleet doctor` on the client: a FAIL row fails the step, a WARN
#              is noted
#   9 cleanup  the drill person deletes itself (DELETE /v1/self with its code:
#              person, device, node, and the login the hub opened for it — it
#              also expires on its own after --ttl), the login's processes, then
#              `userdel -r`. fleet-login-remove.sh is the macOS half (sysadminctl);
#              a Linux login has none of its launchd / Remote Login to undo.
#
# A step past its budget is a FAIL that still lets the rest run (the numbers
# are the point); a step that cannot go on (no install, no certificate) stops
# the run and cleans up. Every step's screen lands in <out>/screen-<step>.txt;
# the table — 步骤 · 结果 · 用时 · 门槛 — goes to <out>/summary.md and, under
# Actions, $GITHUB_STEP_SUMMARY, with the last screen of every FAIL folded in.
# No credential is printed: the admin token and the approve code stay in
# variables and the screens are scrubbed (fd_… / bearer) before they are kept.
#
# --proxy <url>: the login's http(s)_proxy / all_proxy point at it — the matrix
# leg that simulates Clash (an unsteady proxy); off by default.
#
# Needs: Linux, root or `sudo -n` (useradd / userdel), curl, python3, and
# CCQUOTA_VIEWER_TOKEN (an admin's hub token — the repo Secret) in the
# environment. Budgets: NCCN_INSTALL_SECS (60) · NCCN_LOGIN_SECS (10) ·
# NCCN_SESSION_SECS (120) · NCCN_ANSWER_SECS (180) · NCCN_CONNECT_SECS (2);
# NCCN_POLL (1) the screen poll.
#
# Exit: 0 every step within budget · 1 a step failed (cleanup still ran) ·
#       2 usage / preflight (nothing was changed)
set -uo pipefail
PROG=newcomer-cn
BIN="$(cd "$(dirname "$0")" && pwd -P)"
helpn=$(awk '/^set -uo pipefail/ { print NR - 1; exit }' "$0")
usage() { sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
# shellcheck source=fleet-onboard-judge.sh
. "$BIN/fleet-onboard-judge.sh"

HUB=https://claudefleet.24haowan.com HOST=mini2 CONNECT='' LOGIN='' OUT='' PROXY='' KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hub)     [ $# -ge 2 ] || usage; HUB=${2%/}; shift 2 ;;
    --host)    [ $# -ge 2 ] || usage; HOST=$2; shift 2 ;;
    --connect) [ $# -ge 2 ] || usage; CONNECT=$2; shift 2 ;;
    --login)   [ $# -ge 2 ] || usage; LOGIN=$2; shift 2 ;;
    --out)     [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    --proxy)   [ $# -ge 2 ] || usage; PROXY=$2; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n "2,${helpn}p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die2 "unknown argument: $1" ;;
  esac
done
INSTALL_SECS=${NCCN_INSTALL_SECS:-60} LOGIN_SECS=${NCCN_LOGIN_SECS:-10}
SESSION_SECS=${NCCN_SESSION_SECS:-120} ANSWER_SECS=${NCCN_ANSWER_SECS:-180}
CONNECT_SECS=${NCCN_CONNECT_SECS:-2} POLL=${NCCN_POLL:-1}
for v in "INSTALL_SECS=$INSTALL_SECS" "LOGIN_SECS=$LOGIN_SECS" "SESSION_SECS=$SESSION_SECS" \
         "ANSWER_SECS=$ANSWER_SECS" "CONNECT_SECS=$CONNECT_SECS" "POLL=$POLL"; do
  printf '%s' "${v#*=}" | grep -Eq '^[0-9]+$' || die2 "${v%%=*}: not a number: '${v#*=}'"
done
case "$HUB" in http://*|https://*) ;; *) die2 "--hub: not a URL ($HUB)" ;; esac
[ -n "$LOGIN" ] || LOGIN="drillcn$(date +%d%H%M%S)"
printf '%s' "$LOGIN" | grep -Eq '^drill[a-z0-9]{1,11}$' || die2 "--login: drill + 1-11 lowercase letters/digits (got '$LOGIN')"
case "$PROXY" in ''|http://*|https://*|socks5://*|socks5h://*) ;; *) die2 "--proxy: not a proxy URL ($PROXY)" ;; esac

# --- preflight (exit 2): nothing below has changed anything yet ----------------
[ "$(uname -s)" = Linux ] || die2 'Linux only — the macOS drill is bin/fleet-onboard-drill.sh'
for t in curl python3 useradd userdel; do
  command -v "$t" >/dev/null 2>&1 || die2 "$t not found — nothing was changed"
done
# SUDO runs root's half (useradd / userdel / pkill / a test in the login's
# home); RUNAS the login's — runuser as root, else sudo -u
if [ "$(id -u)" = 0 ]; then
  SUDO=''
  if command -v runuser >/dev/null 2>&1; then RUNAS='runuser -u'; else RUNAS='sudo -n -H -u'; fi
else
  SUDO='sudo -n' RUNAS='sudo -n -H -u'
  sudo -n true >/dev/null 2>&1 || die2 'needs root or a sudo that does not prompt (useradd / userdel)'
fi
ADMIN_TOKEN=${CCQUOTA_VIEWER_TOKEN:-}
[ -n "$ADMIN_TOKEN" ] || die2 'CCQUOTA_VIEWER_TOKEN (an admin hub token — the repo Secret) is not set'
id "$LOGIN" >/dev/null 2>&1 && die2 "login $LOGIN already exists"

if [ -z "$OUT" ]; then OUT=$(mktemp -d "${TMPDIR:-/tmp}/newcomer-cn.XXXXXX") || die2 'mktemp failed'; fi
mkdir -p "$OUT" || die2 "cannot make $OUT"
OUT=$(cd "$OUT" && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nccn-w.XXXXXX") || die2 'mktemp failed'
chmod 700 "$WORK"
SUMMARY="$OUT/summary.md"
SOCK="nccn-$$"                  # this run's own tmux server, as the login — never a fleet's
H='' TMUXB='' FLEET='' APPROVE='' NODE='' NFAIL=0 CLEANED=0 STOPPED=''
printf '%s: login=%s hub=%s host=%s proxy=%s out=%s\n' "$PROG" "$LOGIN" "$HUB" "$HOST" "${PROXY:-none}" "$OUT"

# --- bookkeeping -------------------------------------------------------------------
printf '| 步骤 | 结果 | 用时 | 门槛 | 说明 |\n|---|---|---|---|---|\n' > "$SUMMARY"
: > "$OUT/fails.md"
scrub() { sed -E 's/fd_[a-z2-7]{26}/fd_<scrubbed>/g; s/([Bb]earer )[^ ]+/\1<scrubbed>/g'; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }
# record <step> <PASS|FAIL|SKIP> <secs|-> <budget|-> <note> [screen file]
record() {
  local st=$1 res=$2 took=$3 cap=$4 msg=$5 scr=${6-}
  printf '%-4s  %-8s %6ss  (≤%ss)  %s\n' "$res" "$st" "$took" "$cap" "$msg"
  printf '| %s | %s | %ss | %s | %s |\n' "$st" "$([ "$res" = PASS ] && echo '✅' || { [ "$res" = SKIP ] && echo '⏭' || echo '❌'; })" \
    "$took" "$([ "$cap" = - ] && echo - || echo "≤ ${cap}s")" "$(printf '%s' "$msg" | tr '|' '/' | scrub)" >> "$SUMMARY"
  if [ "$res" = FAIL ]; then
    NFAIL=$((NFAIL + 1))
    { printf '\n<details><summary>❌ %s — %s</summary>\n\n```\n' "$st" "$(printf '%s' "$msg" | scrub)"
      if [ -n "$scr" ] && [ -s "$scr" ]; then sed '/^[[:space:]]*$/d' "$scr" | tail -n 40 | scrub; else echo '(no screen)'; fi
      printf '```\n</details>\n'; } >> "$OUT/fails.md"
  fi
}
# within <took> <cap>: the took (seconds, one decimal) is at most the cap
within() { awk -v t="$1" -v c="$2" 'BEGIN { exit !(t <= c) }'; }
as_user() { ( cd / && $RUNAS "$LOGIN" -- env -i HOME="$H" USER="$LOGIN" LOGNAME="$LOGIN" SHELL=/bin/bash \
               PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" TERM=xterm-256color LANG=C.UTF-8 LC_ALL=C.UTF-8 \
               ${PROXY:+http_proxy="$PROXY" https_proxy="$PROXY" all_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"} \
               "$@" ); }
admin() { env HOME="$WORK/admin" FLEET_CONF_DIR="$WORK/admin/conf" FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN="$ADMIN_TOKEN" "$@"; }
ut() { as_user "$TMUXB" -L "$SOCK" "$@"; }
pane() { ut capture-pane -p -J -S - -t nccn 2>/dev/null; }
keep_screen() { scrub > "$OUT/screen-$1.txt"; }

cleanup() {
  [ "$CLEANED" = 1 ] && return 0
  CLEANED=1
  local t0 t1 msg='' code
  t0=$(now_ms)
  if [ -n "$H" ] && [ -n "$TMUXB" ]; then pane | keep_screen last 2>/dev/null; ut kill-server >/dev/null 2>&1; fi
  if [ "$KEEP" = 1 ]; then
    printf '%s: --keep — login %s and drill person left up; clean by hand: userdel -r %s\n' "$PROG" "$LOGIN" "$LOGIN" >&2
    record cleanup SKIP - - '--keep: left up'
    return 0
  fi
  if [ -n "$APPROVE" ]; then
    code=$(printf '{"approve_code":"%s"}' "$APPROVE" | curl -s -m 20 -o "$WORK/self.out" -w '%{http_code}' \
             ${PROXY:+--proxy "$PROXY"} -X DELETE -H 'Content-Type: application/json' --data-binary @- "$HUB/v1/self")
    case "$code" in 200|202|204) msg="drill person deleted (HTTP $code)" ;;
      *) msg="DELETE /v1/self: HTTP $code — it expires on its own (--ttl)" ;; esac
  fi
  if id "$LOGIN" >/dev/null 2>&1; then
    $SUDO pkill -KILL -u "$LOGIN" >/dev/null 2>&1; sleep 1
    if $SUDO userdel -r "$LOGIN" >/dev/null 2>"$WORK/userdel.err" || ! id "$LOGIN" >/dev/null 2>&1; then
      msg="${msg:+$msg · }login removed"
    else
      msg="${msg:+$msg · }userdel failed: $(head -n 1 "$WORK/userdel.err")"; t1=$(now_ms)
      record cleanup FAIL "$(secs "$t0" "$t1")" - "$msg"; return 0
    fi
  fi
  t1=$(now_ms)
  record cleanup PASS "$(secs "$t0" "$t1")" - "${msg:-nothing to clean}"
}
finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  cleanup
  [ -n "$STOPPED" ] && printf '\n**stopped at**: %s\n' "$STOPPED" >> "$SUMMARY"
  cat "$OUT/fails.md" >> "$SUMMARY"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { printf '### 国内新人全流程 · %s%s\n\n' "$HUB" "${PROXY:+ · 代理 $PROXY}"; cat "$SUMMARY"; echo; } >> "$GITHUB_STEP_SUMMARY"
  fi
  rm -rf "$WORK"
  if [ "$NFAIL" -gt 0 ] || [ -n "$STOPPED" ]; then
    printf '%s: RED — %s step(s) failed%s · %s\n' "$PROG" "$NFAIL" "${STOPPED:+, stopped at $STOPPED}" "$SUMMARY"
    exit 1
  fi
  [ "$rc" = 0 ] || exit "$rc"
  printf '%s: GREEN · %s\n' "$PROG" "$SUMMARY"
  exit 0
}
trap finish EXIT
trap 'STOPPED="${STOPPED:-signal}"; exit 1' INT TERM HUP
stop() { STOPPED=$1; exit 1; }

# =============================================================================
# 1 user
t0=$(now_ms)
$SUDO useradd -m -s /bin/bash "$LOGIN" 2>"$WORK/useradd.err" || {
  record user FAIL - - "useradd: $(head -n 1 "$WORK/useradd.err")"; stop user; }
H=$(getent passwd "$LOGIN" | cut -d: -f6)
[ -n "$H" ] && [ -d "$H" ] || { record user FAIL - - "no home for $LOGIN"; stop user; }
record user PASS "$(secs "$t0" "$(now_ms)")" - "useradd $LOGIN, home $H"

# 2 invite (the admin side)
t0=$(now_ms)
mkdir -p "$WORK/admin/conf"
D=$(admin bash "$BIN/fleet-drill.sh" invite --host "$HOST" --login "$LOGIN" --ttl 2h --json 2>"$WORK/drill.err")
APPROVE=$(printf '%s' "$D" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("approve_code",""))' 2>/dev/null)
if [ -z "$APPROVE" ]; then
  scrub < "$WORK/drill.err" > "$OUT/screen-invite.txt"
  record invite FAIL "$(secs "$t0" "$(now_ms)")" - "fleet drill invite --host $HOST refused" "$OUT/screen-invite.txt"; stop invite
fi
record invite PASS "$(secs "$t0" "$(now_ms)")" - "drill person $LOGIN@$HOST (2h)"

# 3 install
t0=$(now_ms)
as_user sh -c "curl -fsSL '$HUB/install' | FLEET_INSTALL_NO_RUN=1 sh" >"$WORK/install.log" 2>&1 </dev/null; rc=$?
t1=$(now_ms); took=$(secs "$t0" "$t1")
keep_screen install < "$WORK/install.log"
FLEET="$H/.local/bin/fleet"
if [ "$rc" != 0 ] || ! $SUDO test -x "$FLEET"; then
  record install FAIL "$took" "$INSTALL_SECS" "the install line exited $rc$($SUDO test -x "$FLEET" || echo ', no ~/.local/bin/fleet')" "$OUT/screen-install.txt"
  stop install
fi
noise=$(curl_noise < "$WORK/install.log")
if within "$took" "$INSTALL_SECS"; then
  record install PASS "$took" "$INSTALL_SECS" "fleet installed$([ "$noise" = 0 ] || echo " · 屏上 $noise 行 curl 报错")"
else
  record install FAIL "$took" "$INSTALL_SECS" "installed, over budget$([ "$noise" = 0 ] || echo " · 屏上 $noise 行 curl 报错")" "$OUT/screen-install.txt"
fi
TMUXB=$(as_user sh -c 'command -v tmux' 2>/dev/null)
[ -n "$TMUXB" ] || TMUXB=$(command -v tmux 2>/dev/null)

# 4 login
t0=$(now_ms)
as_user "$FLEET" login >"$WORK/login.out" 2>&1 </dev/null &
LPID=$!
UC=''
for _ in $(seq 1 $((LOGIN_SECS * 3 + 30))); do
  UC=$(grep -Eo '[A-Z]{4}-[A-Z]{4}' "$WORK/login.out" | head -n 1)
  [ -n "$UC" ] && break
  kill -0 "$LPID" 2>/dev/null || break
  sleep 0.5
done
if [ -z "$UC" ]; then
  kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
  keep_screen login < "$WORK/login.out"
  record login FAIL "$(secs "$t0" "$(now_ms)")" "$LOGIN_SECS" 'fleet login printed no 验证码' "$OUT/screen-login.txt"; stop login
fi
admin env FLEET_DRILL_INVITE="$APPROVE" bash "$BIN/fleet-drill.sh" approve "$UC" >"$WORK/approve.out" 2>&1 \
  || { kill "$LPID" 2>/dev/null; cat "$WORK/approve.out" >> "$WORK/login.out"; }
for _ in $(seq 1 $((LOGIN_SECS * 6 + 60))); do kill -0 "$LPID" 2>/dev/null || break; sleep 0.5; done
kill "$LPID" 2>/dev/null; wait "$LPID"; rc=$?
t1=$(now_ms); took=$(secs "$t0" "$t1")
keep_screen login < "$WORK/login.out"
if [ "$rc" != 0 ] || ! $SUDO test -s "$H/.ssh/fleet-cert-cert.pub"; then
  record login FAIL "$took" "$LOGIN_SECS" "fleet login exited $rc$($SUDO test -s "$H/.ssh/fleet-cert-cert.pub" || echo ', no certificate')" "$OUT/screen-login.txt"
  stop login
fi
if within "$took" "$LOGIN_SECS"; then record login PASS "$took" "$LOGIN_SECS" "验证码 $UC confirmed by the drill code, certificate in ~/.ssh"
else record login FAIL "$took" "$LOGIN_SECS" 'signed in, over budget' "$OUT/screen-login.txt"; fi

# 5 session + 6 answer
WORD=好
ASK="只回一个字：$WORD"
if [ -z "$TMUXB" ]; then
  record session FAIL - "$SESSION_SECS" 'no tmux on the login after the install line'; stop session
fi
t0=$(now_ms)
# its own terminal: a tmux of the run's own, as the login; TMUX unset inside so
# the client's attach is no nested one. The sentinel says the view came back.
ut new-session -d -s nccn -x 160 -y 48 \
  "env -u TMUX -u TMUX_PANE '$FLEET' claude --new '$ASK'; echo __NCCN_EXIT=\$?; sleep 3600" 2>"$WORK/tmux.err" \
  || { keep_screen session < "$WORK/tmux.err"; record session FAIL - "$SESSION_SECS" 'the run could not open its terminal' "$OUT/screen-session.txt"; stop session; }
st=wait up_ms=''
deadline=$((SECONDS + SESSION_SECS + ANSWER_SECS))
while [ "$SECONDS" -lt "$deadline" ]; do
  st=$(pane | agent_state "$WORD")
  [ "$st" != wait ] && [ -z "$up_ms" ] && up_ms=$(now_ms) && pane | keep_screen session
  case "$st" in answered|exited) break ;; esac
  sleep "$POLL"
done
t1=$(now_ms)
pane | keep_screen answer
if [ -z "$up_ms" ] || [ "$st" = exited ]; then
  [ -n "$up_ms" ] || pane | keep_screen session
  record session FAIL "$(secs "$t0" "$t1")" "$SESSION_SECS" \
    "$([ "$st" = exited ] && echo "fleet claude came back: $(pane | grep -Eo '__NCCN_EXIT=[0-9]+' | head -n 1)" || echo 'no agent screen')" "$OUT/screen-session.txt"
  record answer SKIP - "$ANSWER_SECS" 'no session'
else
  took=$(secs "$t0" "$up_ms")
  if within "$took" "$SESSION_SECS"; then record session PASS "$took" "$SESSION_SECS" 'the session is up (agent screen drawn)'
  else record session FAIL "$took" "$SESSION_SECS" 'up, over budget' "$OUT/screen-session.txt"; fi
  took=$(secs "$up_ms" "$t1")
  if [ "$st" = answered ] && within "$took" "$ANSWER_SECS"; then record answer PASS "$took" "$ANSWER_SECS" "the agent answered $WORD"
  elif [ "$st" = answered ]; then record answer FAIL "$took" "$ANSWER_SECS" 'answered, over budget' "$OUT/screen-answer.txt"
  else record answer FAIL "$took" "$ANSWER_SECS" "no answer carrying $WORD" "$OUT/screen-answer.txt"; fi
fi

# where it landed — the machine the connect step goes to
as_user "$FLEET" ls --json >"$WORK/ls.json" 2>/dev/null
NODE=$(python3 -c 'import json,sys
try: rows = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for r in rows:
    if r.get("node"): print(r["node"]); break' "$WORK/ls.json" 2>/dev/null)
ut kill-session -t nccn >/dev/null 2>&1

# 7 connect
TARGET=${CONNECT:-${NODE:-$HOST}}
t0=$(now_ms)
as_user "$FLEET" connect "$TARGET" -- true >"$WORK/connect.out" 2>&1 </dev/null; rc=$?
t1=$(now_ms); took=$(secs "$t0" "$t1")
keep_screen connect < "$WORK/connect.out"
if [ "$rc" != 0 ]; then record connect FAIL "$took" "$CONNECT_SECS" "fleet connect $TARGET -- true exited $rc" "$OUT/screen-connect.txt"
elif within "$took" "$CONNECT_SECS"; then record connect PASS "$took" "$CONNECT_SECS" "fleet connect $TARGET -- true"
else record connect FAIL "$took" "$CONNECT_SECS" "fleet connect $TARGET: over budget" "$OUT/screen-connect.txt"; fi

# 8 doctor
t0=$(now_ms)
as_user "$FLEET" doctor >"$WORK/doctor.out" 2>&1 </dev/null
t1=$(now_ms); took=$(secs "$t0" "$t1")
keep_screen doctor < "$WORK/doctor.out"
nf=$(grep -Ec '^[[:space:]]*FAIL[[:space:]]' "$WORK/doctor.out")
nw=$(grep -Ec '^[[:space:]]*WARN[[:space:]]' "$WORK/doctor.out")
if [ "$nf" -gt 0 ]; then
  record doctor FAIL "$took" - "$nf FAIL · $nw WARN: $(grep -E '^[[:space:]]*FAIL[[:space:]]' "$WORK/doctor.out" | head -n 1 | sed 's/^[[:space:]]*//')" "$OUT/screen-doctor.txt"
else
  record doctor PASS "$took" - "no FAIL$([ "$nw" = 0 ] || echo " · $nw WARN: $(grep -E '^[[:space:]]*WARN[[:space:]]' "$WORK/doctor.out" | sed 's/^[[:space:]]*WARN[[:space:]]*//' | awk '{print $1}' | tr '\n' ' ')")"
fi
exit 0
