#!/bin/bash
# fleet-onboard-drill.sh [--login <name>] [--invite <code>] [--hub <url>] [--scan-cmd <cmd>]
#                        [--keep] [--timeout <secs>] [--ssh-host <h>] [--ssh-port <p>]
#                        [--name <scratch>] | --teardown <login> [--invite <code>]
#   — a new colleague's first time, from nothing, as ONE command (issue #1901,
#     EPIC #1906 C8): a throwaway OS login gets only the hub's install line,
#     answers what it asks with Enter, joins, opens the client and starts a
#     scratch session in it; every screen is captured, then the login and all it
#     left (device, node, services) are removed.
#
# Each step prints PASS / FAIL / SKIP and adds a row to steps.md — 看到什么 ·
# 按了什么 · 用时 · 要人帮吗 — the table docs/INSTALL.md's 「新同事第一次」 is
# copied from. Every screen lands as screen-NN-<step>.txt in the run's dir.
#
#   1 open      a bare login: sysadminctl -addUser, createhomedir, Remote Login
#               (com.apple.access_ssh), a temporary key — NO fleet clone, no
#               daemons, nothing of the fleet's: this is the colleague's computer.
#               One line of ~/.zshenv, FLEET_CLIENT_IDENTITY=test (#1931): the
#               client the drill opens holds a TEST lease, never the person's.
#   2 ssh       `ssh -tt <login>@<host>` with that key, inside a tmux server of
#               the run's own (-L fleet-drill-<login>, never a fleet's).
#   3 paste     types `curl -fsSL <hub>/install | sh` — the one line the person has.
#   4 ask       every 「回车 = 1 ›」 the installer asks is answered with Enter
#               (the defaults are the answers a new colleague should give).
#   5 download  until the QR, the 「能力:」 line or an error; every `curl: (`
#               line on the way is counted — each one is noise on their screen.
#   6 scan      the person's OWN step, never 「要人帮」: the QR's confirm URL is
#               printed (and handed to --scan-cmd <cmd> as $1, e.g. a notifier);
#               waits for 「✓ 已登记到入口」 (「能力:」 alone also follows an
#               expired code). A refusal the page
#               gives (no login on any machine yet, …) IS 要人帮 — a FAIL naming it.
#               With --invite <code> (issue #2010) nobody scans: the code `fleet
#               drill invite` printed confirms it (POST /fleet/login/approve) as
#               the DRILL PERSON the hub minted — never as you, so the run walks
#               a new colleague's first time, not your second computer's.
#   7 client    the installer execs `fleet`: the task list must come up — `open
#               terminal failed` there is a FAIL (fixed in #1901).
#   8 scratch   the writing area (prefix c — ⌘N, the key the client's bar
#               names, is iTerm2's spelling of it; the list itself takes no
#               keys since #1950), a name typed, Enter; the repo question and
#               「开在哪」 each Enter (the default, 自动); a new ROW — never the
#               input line 「› <name>」, never a line outside the split (the
#               shell prompt 「<login>@host % …」 above it, #2221) — must
#               appear, the name a whole word (default `first`: never a part
#               of the login, which is refused). Before any key: the right
#               pane's 「入口没有在线的机器」 is a FAIL (issue #2220 — a
#               newcomer is told 「正在为你开机器」 or who to ask). The
#               sidebar's refusal (no repo / no machine of yours / hub down,
#               zh or en) is 要人帮 — a FAIL naming it. The row's line is the
#               evidence.
#   9 offboard  stop the login's processes, revoke its device on the hub
#               (POST /v1/fleet/devices/revoke, viewer token from the
#               environment), then fleet-login-remove.sh <login> --delete-home
#               --apply — which takes the login's node off the hub as the login
#               itself (`fleet node leave --hub-only`, #1928). Only when that did
#               not: FLEET_DRILL_RETIRE_CMD <ep_id>, else the operator's
#               POST /v1/fleet/nodes/retire, else a WARN naming the machines
#               page's 「移除」 — never kubectl.
#               With --invite: the drill person deletes ITSELF instead — person,
#               device, node (DELETE /v1/self, signed by the login's own
#               certificate, else the code) — no operator token needed.
#  10 residue   no login record, home, process, access group entry; the device
#               revoked on the hub. With --invite: the hub no longer knows the
#               drill person (its answer is kept as hub-residue.txt).
#
# The reading: 「要人帮的步骤」 = the FAILs a person would have had to be asked
# about. The scan is the colleague's own and is not counted.
#
# --teardown <login>: steps 9–10 only, for a run left up (--keep) or cut short.
#
# --runs N: the 60-second standard instead (bin/fleet-onboard-clock.sh, #2267) —
# `fleet-onboard-drill.sh --hub prod --runs 3`: sandbox HOMEs, no new login.
#
# Needs: an admin login (never root), a sudo ticket (`sudo -v` first — nothing
# here prompts), ssh, tmux, Remote Login on --ssh-host:--ssh-port (default
# 127.0.0.1:22), and for the device revoke CCQUOTA_VIEWER_TOKEN (or
# FLEET_HUB_TOKEN) in the environment — read at start, never written.
# NEVER from a fleet worker on the machine it runs on: it opens a real login and
# runs sudo (EPIC #1212 convention 2) — run it on the machine meant for drills.
#
# Exit: 0 every step passed · 1 a step failed (the teardown still ran) ·
#       2 bad arguments / preflight · 3 the login (or its home) already exists
# Env: FLEET_DRILL_TIMEOUT (900 s, the download) · FLEET_DRILL_SCAN_SECS (600,
#      the QR's life) · FLEET_DRILL_STEP_SECS (120, any other wait) ·
#      FLEET_DRILL_POLL_SECS (2) · FLEET_DRILL_RETIRE_CMD · FLEET_LOGIN_HOMES (/Users)
set -u

PROG=fleet-onboard-drill
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
# list_row_named <name> (a screen on stdin): a list ROW carrying the name — the left column before 「│」,
# never the input line 「› <name>」 (the typed name is not a session; matching
# it passed the #1901 final run while the list said 「No sessions」). Only a
# line of the split counts (one with 「│」: the shell prompt 「drill1007b@mini2 %」
# above it passed #2221's run), and the name is a whole word — no letter,
# digit, @, _ or - against either side.
list_row_named() {
  grep -F '│' | sed 's/│.*//' | grep -Ev '^[[:space:]]*›' \
    | grep -E -- "(^|[^[:alnum:]@_-])$1(\$|[^[:alnum:]@_-])" | head -n 1 | sed 's/ *$//'
}

# qr_state <login> (a screen on stdin): qr — a 验证码 is up; none — the
# installer is past its end (「能力:」, or 「用时 N 秒」 — the newcomer's install
# prints no 能力 line, issue #2347) AND finished with no code (the client is up, it
# could not open, or the person is back at a prompt); wait — anything else.
# The installer prints 「能力:」 BEFORE its QR (#2255): 能力: alone is no proof
# that this computer was already known, so it never reads none by itself.
CLIENT_UP='新任务|New task'
INSTALL_END='^(能力:|用时 [0-9]+ 秒)'
qr_state() {
  local p
  p=$(cat)
  if printf '%s\n' "$p" | grep -Eq '验证码 [A-Z]{4}-[A-Z]{4}'; then echo qr
  elif printf '%s\n' "$p" | grep -Eq "$INSTALL_END" \
       && printf '%s\n' "$p" | grep -Eq -- "$CLIENT_UP|open terminal failed|not a terminal|$1@[^ ]+ [^ ]* ?[%\$#] *\$"; then echo none
  else echo wait; fi
}

# --runs N (issue #2267, EPIC #2259 C8): the 60-second standard — a sandbox per
# run, timed from the paste to the first key the agent takes, every known pit
# checked; no OS login is made. That is bin/fleet-onboard-clock.sh, whole.
for a in "$@"; do [ "$a" = --runs ] && exec bash "$BIN/fleet-onboard-clock.sh" "$@"; done

LOGIN='' HUB='' SCAN_CMD='' KEEP=0 TEARDOWN=0 NAME=first INVITE='' ROW_ONLY='' QR_ONLY=0
DRILL_NS=fleet-drill@claude-fleet
HOST=127.0.0.1 PORT=22
TIMEOUT=${FLEET_DRILL_TIMEOUT:-900} SCAN_SECS=${FLEET_DRILL_SCAN_SECS:-600}
STEP_SECS=${FLEET_DRILL_STEP_SECS:-120} POLL=${FLEET_DRILL_POLL_SECS:-2}
while [ $# -gt 0 ]; do
  case "$1" in
    --login)    [ $# -ge 2 ] || usage; LOGIN=$2; shift 2 ;;
    --hub)      [ $# -ge 2 ] || usage; HUB=$2; shift 2 ;;
    --scan-cmd) [ $# -ge 2 ] || usage; SCAN_CMD=$2; shift 2 ;;
    --timeout)  [ $# -ge 2 ] || usage; TIMEOUT=$2; shift 2 ;;
    --ssh-host) [ $# -ge 2 ] || usage; HOST=$2; shift 2 ;;
    --ssh-port) [ $# -ge 2 ] || usage; PORT=$2; shift 2 ;;
    --name)     [ $# -ge 2 ] || usage; NAME=$2; shift 2 ;;
    --teardown) [ $# -ge 2 ] || usage; LOGIN=$2; TEARDOWN=1; shift 2 ;;
    --invite)   [ $# -ge 2 ] || usage; INVITE=$2; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    --row-named) [ $# -ge 2 ] || usage; ROW_ONLY=$2; shift 2 ;;   # selftest seam: screen on stdin
    --qr-state) QR_ONLY=1; shift ;;                                 # selftest seam: screen on stdin
    -h|--help)  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)          die2 "unknown argument: $1" ;;
  esac
done
if [ "$QR_ONLY" = 1 ]; then qr_state "$LOGIN"; exit 0; fi
if [ -n "$ROW_ONLY" ]; then r=$(list_row_named "$ROW_ONLY"); [ -n "$r" ] && printf '%s\n' "$r"; [ -n "$r" ]; exit; fi
if [ -n "$INVITE" ]; then
  printf '%s' "$INVITE" | grep -Eq '^fd_[a-z2-7]{26}$' || die2 "--invite: not an approve code (fd_… from fleet drill invite)"
  # the drill person's certificate names ITS login: the OS login must be it
  [ -n "$LOGIN" ] || die2 "--invite needs --login <the login fleet drill invite printed>"
fi
[ -n "$LOGIN" ] || LOGIN="drill-$(date +%m%d%H%M)"
printf '%s' "$LOGIN" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' \
  || die2 "bad login name '$LOGIN' (lowercase letters, digits, _ and -; at most 32)"
printf '%s' "$NAME" | grep -Eq '^[a-z][a-z0-9-]{0,23}$' || die2 "--name: lowercase letters, digits and -, at most 24 (got '$NAME')"
# the screen still shows 「<login>@host %」: a name inside the login is no proof (#2221)
case "$LOGIN" in *"$NAME"*) die2 "--name '$NAME' is part of the login '$LOGIN' — pick a name the screen cannot already show" ;; esac
for v in "TIMEOUT=$TIMEOUT" "SCAN_SECS=$SCAN_SECS" "STEP_SECS=$STEP_SECS" "PORT=$PORT"; do
  printf '%s' "${v#*=}" | grep -Eq '^[0-9]+$' || die2 "${v%%=*}: not a number: '${v#*=}'"
done
[ "$EUID" != 0 ] || die2 'run this as the admin login, not under sudo — it sudo'"'"'s what needs root'
if [ -z "$HUB" ]; then
  HUB=$(sed -n 's/^export FLEET_HUB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.conf" 2>/dev/null | head -n 1)
fi
case "$HUB" in http://*|https://*) HUB=${HUB%/} ;; *) die2 "no hub: pass --hub https://<入口> (or set FLEET_HUB_URL in fleet.conf)" ;; esac
VIEWER=${CCQUOTA_VIEWER_TOKEN:-${FLEET_HUB_TOKEN:-}}

HOMES=${FLEET_LOGIN_HOMES:-/Users}
H="$HOMES/$LOGIN"
SOCK="fleet-drill-$LOGIN"        # this run's own tmux server (label), never a fleet's
TSESS=drill
RM_SH="${FLEET_DRILL_LOGIN_REMOVE:-$BIN/fleet-login-remove.sh}"   # the env is the selftest's seam
TMUXB=$(command -v tmux 2>/dev/null || :)
[ -n "$TMUXB" ] || for t in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do [ -x "$t" ] && TMUXB=$t && break; done

# --- preflight (exit 2 / 3): nothing below has changed anything yet ------------
for t in ssh ssh-keygen sudo curl python3; do
  command -v "$t" >/dev/null 2>&1 || die2 "$t not found — nothing was changed"
done
[ -n "$TMUXB" ] || die2 'tmux not found — nothing was changed'
[ -f "$RM_SH" ] || die2 "fleet-login-remove.sh not found beside $0"
sudo -n true >/dev/null 2>&1 || die2 "no sudo ticket — run 'sudo -v' first (this script never prompts)"
if [ "$TEARDOWN" = 0 ]; then
  if id "$LOGIN" >/dev/null 2>&1; then
    printf '%s: login %s already exists — refusing (another --login, or clean it: %s --teardown %s)\n' "$PROG" "$LOGIN" "$0" "$LOGIN" >&2
    exit 3
  fi
  [ ! -e "$H" ] || { printf '%s: %s already exists (no such login) — refusing\n' "$PROG" "$H" >&2; exit 3; }
else
  id "$LOGIN" >/dev/null 2>&1 || [ -e "$H" ] || die2 "--teardown: no login $LOGIN and no $H — nothing to clean"
fi

RUN=$(mktemp -d "${TMPDIR:-/tmp}/fleet-onboard-drill.$LOGIN.XXXXXX") || die2 'mktemp failed'
chmod 700 "$RUN"
printf '%s: login=%s  hub=%s  ssh=%s:%s  confirm=%s  log dir %s\n' "$PROG" "$LOGIN" "$HUB" "$HOST" "$PORT" \
  "$([ -n "$INVITE" ] && echo 'drill person (--invite)' || echo 'a person scans')" "$RUN"

# --- bookkeeping -----------------------------------------------------------------
T0=$SECONDS TS=$SECONDS
STEP=0 NPASS=0 NFAIL=0 NSKIP=0 NHELP=0 NSHOT=0
UIDN='' GUID='' FPR='' EPID='' TMUX_UP=0 SUMMARISED=0 NOISE=0 SCAN_URL=''
STEPS="$RUN/steps.md"
printf '| # | 看到什么 | 按了什么 | 用时 | 要人帮 |\n|---|---|---|---|---|\n' > "$STEPS"

line() { STEP=$((STEP + 1)); printf '%-4s  %-9s %s\n' "$1" "$2" "$3"; }
pass() { NPASS=$((NPASS + 1)); line PASS "$1" "$2"; }
failstep() { NFAIL=$((NFAIL + 1)); line FAIL "$1" "$2"; }
skip() { NSKIP=$((NSKIP + 1)); line SKIP "$1" "$2"; }
note() { printf '        %s\n' "$*"; }
# row <看到> <按了> <要人帮: 否|本人|是 — why>: one line of steps.md, timed since the last
row() {
  local n
  n=$(($(grep -c '^| [0-9]' "$STEPS") + 1))
  case "$3" in 是*) NHELP=$((NHELP + 1)) ;; esac
  printf '| %s | %s | %s | %ss | %s |\n' "$n" "$1" "$2" "$((SECONDS - TS))" "$3" >> "$STEPS"
  TS=$SECONDS
}
elapsed() { printf '%ss' "$((SECONDS - T0))"; }
as_login() { ( cd / && sudo -n -u "$LOGIN" -H "$@" ); }
keep_sudo() { sudo -n -v >/dev/null 2>&1 || :; }   # refreshes a ticket; NOPASSWD needs none
tmux_own() { TMUX='' "$TMUXB" -L "$SOCK" "$@"; }
pane() { tmux_own capture-pane -p -J -S - -t "$TSESS" 2>/dev/null; }
# shot <name>: the screen as the person sees it now (the visible pane only)
shot() {
  NSHOT=$((NSHOT + 1))
  tmux_own capture-pane -p -t "$TSESS" 2>/dev/null | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$RUN/$(printf 'screen-%02d-%s.txt' "$NSHOT" "$1")"
}
keys() { tmux_own send-keys -t "$TSESS" "$@"; }
# wait_for <secs> <ERE…>: polls the pane until one ERE matches; prints the index
# (1-based) of the one that did, rc 1 on the deadline
wait_for() {
  local secs=$1 deadline i p re; shift
  deadline=$((SECONDS + secs))
  while :; do
    keep_sudo
    p=$(pane)
    i=0
    for re in "$@"; do
      i=$((i + 1))
      if printf '%s\n' "$p" | grep -Eq -- "$re"; then printf '%s' "$i"; return 0; fi
    done
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}
# qr_wait <secs>: qr_state on the pane until it is not wait, or the deadline
qr_wait() {
  local deadline st
  deadline=$((SECONDS + $1))
  while :; do
    keep_sudo
    st=$(pane | qr_state "$LOGIN")
    [ "$st" = wait ] && [ "$SECONDS" -lt "$deadline" ] || { printf '%s' "$st"; return 0; }
    sleep "$POLL"
  done
}
# ask_wait <answered>: 1 when a question beyond the <answered> ones is on the
# pane, 2 when the install went on past the questions (QR, 能力:, an error);
# rc 1 on the deadline
ask_wait() {
  local answered=$1 deadline n p
  deadline=$((SECONDS + STEP_SECS))
  while :; do
    keep_sudo
    p=$(pane)
    n=$(printf '%s\n' "$p" | grep -Ec '回车 = [0-9]+ ›')
    if [ "$n" -gt "$answered" ]; then printf 1; return 0; fi
    if printf '%s\n' "$p" | grep -Eq '验证码 [A-Z]{4}-[A-Z]{4}|^能力:|^用时 [0-9]+ 秒|fleet-install: |✗ |command not found|Could not resolve'; then printf 2; return 0; fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep "$POLL"
  done
}
tail_pane() { pane | sed '/^[[:space:]]*$/d' | tail -n "${1:-12}" | sed 's/^/        │ /'; }
kill_own_tmux() {
  [ "$TMUX_UP" = 1 ] || return 0
  pane > "$RUN/pane-full.txt" 2>/dev/null || :
  tmux_own kill-server >/dev/null 2>&1 || :
  TMUX_UP=0
}

# hub_json <method> <path> <json>: the hub's answer, its HTTP code on the LAST
# line ('' = no answer). The body travels on stdin — an approve code never
# reaches an argv.
hub_json() {
  local out code
  out=$(mktemp "$RUN/hub.XXXXXX") || return 1
  code=$(printf '%s' "$3" | curl -sS --max-time 20 -o "$out" -w '%{http_code}' -X "$1" \
         -H 'Content-Type: application/json' --data-binary @- "$HUB$2" 2>/dev/null)
  cat "$out"; rm -f "$out"
  printf '\n%s' "$code"
}
hub_code() { printf '%s' "${1##*$'\n'}"; }
hub_body() { case "$1" in *$'\n'*) printf '%s' "${1%$'\n'*}" ;; esac; }

# --- 1 open ------------------------------------------------------------------------
step_open() {
  local pw key="$RUN/id_ed25519"
  ssh-keygen -q -t ed25519 -N '' -C "$PROG-$LOGIN" -f "$key" || { failstep open 'ssh-keygen failed'; return 1; }
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  if ! ( cd / && sudo -n sysadminctl -addUser "$LOGIN" -fullName "Onboard Drill ($LOGIN)" -password "$pw" ) > "$RUN/open.log" 2>&1; then
    failstep open "sysadminctl -addUser $LOGIN: $(tail -n 1 "$RUN/open.log")"
    return 1
  fi
  pw=''
  ( cd / && sudo -n createhomedir -c -u "$LOGIN" ) >> "$RUN/open.log" 2>&1 || :
  if dseditgroup -o read com.apple.access_ssh >/dev/null 2>&1; then
    ( cd / && sudo -n dseditgroup -o edit -a "$LOGIN" -t user com.apple.access_ssh ) >> "$RUN/open.log" 2>&1 || :
  fi
  ( cd / && sudo -n install -d -o "$LOGIN" -g staff -m 700 "$H/.ssh" \
      && sudo -n install -o "$LOGIN" -g staff -m 600 "$key.pub" "$H/.ssh/authorized_keys" ) >> "$RUN/open.log" 2>&1 \
    || { failstep open "authorized_keys for $LOGIN: $(tail -n 1 "$RUN/open.log")"; return 1; }
  # the drill's client is the TEST identity (#1931): its own lease slot at the
  # hub's test door, never the operator's one-client lease (2026-10-06, #1901)
  printf 'export FLEET_CLIENT_IDENTITY=test\n' > "$RUN/zshenv"
  ( cd / && sudo -n install -o "$LOGIN" -g staff -m 644 "$RUN/zshenv" "$H/.zshenv" ) >> "$RUN/open.log" 2>&1 \
    || { failstep open "$H/.zshenv for $LOGIN: $(tail -n 1 "$RUN/open.log")"; return 1; }
  UIDN=$(id -u "$LOGIN" 2>/dev/null || :)
  GUID=$(dscl . -read "/Users/$LOGIN" GeneratedUID 2>/dev/null | awk '$1=="GeneratedUID:" {print $2; exit}')
  pass open "login $LOGIN (uid ${UIDN:-?}): a bare account, a temporary key, the test identity — nothing of the fleet's · $(elapsed)"
}

# --- 2 ssh ---------------------------------------------------------------------------
step_ssh() {
  local cmd
  cmd=$(printf '%q ' ssh -tt -i "$RUN/id_ed25519" -p "$PORT" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=15 "$LOGIN@$HOST")
  if ! tmux_own new-session -d -s "$TSESS" -x 160 -y 50 \
       "${cmd% }; printf '[$PROG] ssh exited %s\\n' \$?; sleep 3600" 2>"$RUN/tmux.err"; then
    failstep ssh "cannot start the run's own tmux server (-L $SOCK): $(head -n 1 "$RUN/tmux.err")"
    return 1
  fi
  TMUX_UP=1
  case $(wait_for "$STEP_SECS" "$LOGIN@[^ ]+ [^ ]* ?[%\$#] *\$" "\\[$PROG\\] ssh exited") in
    1) shot ssh; pass ssh "ssh -tt $LOGIN@$HOST:$PORT: a shell prompt"; TS=$SECONDS ;;
    *) failstep ssh "no shell prompt within ${STEP_SECS}s:"; tail_pane; return 1 ;;
  esac
}

# --- 3 paste · 4 ask · 5 download -------------------------------------------------------
step_install() {
  local line="curl -fsSL $HUB/install | sh" k asked=0 got
  keys -l "$line"; keys Enter
  shot paste
  row "终端提示符" "粘贴 \`$line\`，回车" 否
  pass paste "typed: $line"
  # 4 ask: each question is answered with Enter, until no question is left. A
  # question is NEW only while the pane holds more 「回车 =」 prompts than were
  # answered: an answered one stays in the scrollback (the 「→」 echo is on the
  # next line), and matching it again pressed Enter forever past the QR.
  while :; do
    got=$(ask_wait "$asked")
    case "$got" in
      1) asked=$((asked + 1)); shot "ask-$asked"
         row "问题 ${asked}：$(pane | grep -B4 '回车 = [0-9]* ›' | grep -v '^ \|回车 =' | tail -n 1 | sed 's/|/／/g')" "回车（默认）" 否
         keys Enter
         sleep 1 ;;
      *) break ;;
    esac
  done
  pass ask "$asked question(s), each answered with Enter (the default)"
  # 5 download: on to the QR, the end, or an error
  k=$(wait_for "$TIMEOUT" '验证码 [A-Z]{4}-[A-Z]{4}' "$INSTALL_END" 'fleet-install: |✗ |\[fleet-onboard-drill\] ssh exited')
  NOISE=$(pane | grep -c 'curl: (')
  case "$k" in
    1|2) shot download
         row "下载安装$([ "$NOISE" = 0 ] || printf '（屏上 %s 行 curl 报错）' "$NOISE")" "等" "$([ "$NOISE" = 0 ] && echo 否 || echo "是 — $NOISE 行 curl 报错会让人以为装坏了")"
         if [ "$NOISE" = 0 ]; then pass download "the client downloaded with no error on screen · $(elapsed)"
         else failstep download "the client downloaded, but $NOISE 'curl: (' line(s) on the person's screen"; fi ;;
    3)   shot download; row "安装报错：$(pane | grep -E 'fleet-install: |✗ ' | tail -n 1)" "—" "是 — 安装失败"
         failstep download "the installer stopped:"; tail_pane; return 1 ;;
    *)   shot download; row "下载 ${TIMEOUT}s 未完成" "等" "是 — 装不完"
         failstep download "no QR and no 能力: line within ${TIMEOUT}s ($NOISE 'curl: (' lines):"; tail_pane; return 1 ;;
  esac
}

# --- 6 scan -------------------------------------------------------------------------
step_scan() {
  local code k
  # SKIP only once the installer has finished with no code: it prints
  # 「能力:」 before the QR, and download stops at whichever comes first (#2255)
  case $(qr_wait "$STEP_SECS") in
    none) skip scan 'no QR: this computer was already known to the hub'; return 0 ;;
    wait) shot scan; row "「能力:」之后 ${STEP_SECS}s 既没有二维码、也没装完" "等" "是 — 装到一半停住"
          failstep scan "past 能力: but no QR and no client/prompt within ${STEP_SECS}s:"; tail_pane; return 1 ;;
  esac
  code=$(pane | grep -Eo '验证码 [A-Z]{4}-[A-Z]{4}' | tail -n 1 | awk '{print $2}')
  SCAN_URL=$(pane | grep -Eo 'https?://[^ ]+/fleet/login\?code=[A-Z-]+' | tail -n 1)
  FPR=$(pane | grep -Eo 'SHA256:[A-Za-z0-9+/]+' | tail -n 1)
  shot scan
  if [ -n "$INVITE" ]; then
    # bin/fleet-drill.sh approve: the code is the only credential it sends
    if ! FLEET_DRILL_INVITE=$INVITE FLEET_HUB_URL=$HUB CCQUOTA_HUB_URL='' \
         bash "$BIN/fleet-drill.sh" approve "$code" > "$RUN/approve.json" 2> "$RUN/approve.err"; then
      shot scan
      row "二维码 + 验证码 $code" "演练确认码代扫" "是 — 入口不肯确认（$(tail -n 1 "$RUN/approve.err")）"
      failstep scan "the hub refused the drill's approve code: $(tail -n 1 "$RUN/approve.err") $(head -c 200 "$RUN/approve.json")"
      return 1
    fi
    printf '\n  >>> 扫码由演练确认码代办：确认人是演练同事 %s（%s），不是运营者\n\n' \
      "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("person_id","?"))' "$RUN/approve.json" 2>/dev/null)" "$LOGIN"
  else
    printf '\n  >>> 扫码（同事本人的一步）：%s  (验证码 %s, %ss 内有效)\n\n' "${SCAN_URL:-?}" "$code" "$SCAN_SECS"
    [ -z "$SCAN_CMD" ] || [ -z "$SCAN_URL" ] || sh -c "$SCAN_CMD \"\$1\"" _ "$SCAN_URL" > "$RUN/scan-cmd.log" 2>&1 || :
  fi
  # 「已登记到入口」 only: the installer goes on to 「能力:」 after a refused or
  # expired scan too (「not issued (HTTP 410)」), so 能力: is no confirmation
  k=$(wait_for "$SCAN_SECS" '已登记到入口' '✗ |还不能签发|access_denied|已过期|not issued|没登记成|机器登录')
  EPID=$(pane | grep -Eo '已登记到入口：[^（]*（ep_[0-9]+）' | grep -Eo 'ep_[0-9]+' | tail -n 1)
  shot joined
  case "$k" in
    1) row "GitHub 登录二维码 + 验证码 $code" "$([ -n "$INVITE" ] && echo '演练确认码代扫（演练同事）' || echo '扫码、用 GitHub 登录、点确认')" "本人"
       pass scan "confirmed: device ${FPR:-?} · node ${EPID:-none} · $(elapsed)" ;;
    2) row "扫码后：$(pane | grep -E '✗ |还不能签发|access_denied|已过期|not issued|没登记成|机器登录' | head -n 1)" "扫码" "是 — 入口不肯签发"
       failstep scan "the hub did not issue (refused, or the code expired):"; tail_pane; return 1 ;;
    *) row "二维码 ${SCAN_SECS}s 内没人扫" "—" "本人（没扫）"
       failstep scan "nobody confirmed within ${SCAN_SECS}s"; return 1 ;;
  esac
}

# --- 7 client -----------------------------------------------------------------------
step_client() {
  local k
  # the list is up once its 「新任务」 row is (the list's border has no label
  # since issue #2167)
  k=$(wait_for "$STEP_SECS" "$CLIENT_UP" 'open terminal failed|not a terminal' "$LOGIN@[^ ]+ [^ ]* ?[%\$#] *\$")
  shot client
  case "$k" in
    1) row "客户端：左边任务列表、右边主页" "—（装完自己打开）" 否
       pass client "the installer opened the client: the task list is up · $(elapsed)" ;;
    2) row "客户端没打开：$(pane | grep -E 'open terminal failed|not a terminal' | tail -n 1)" "再敲 fleet" "是 — 装完没进客户端"
       failstep client "the installer's own 'fleet' did not open:"; tail_pane 4
       keys -l fleet; keys Enter
       wait_for "$STEP_SECS" "$CLIENT_UP" >/dev/null || return 1
       shot client-again ;;
    *) row "装完回到提示符" "敲 fleet" "是 — 装完没进客户端"
       failstep client "back at the prompt, no client"; keys -l fleet; keys Enter
       wait_for "$STEP_SECS" "$CLIENT_UP" >/dev/null || return 1
       shot client-again ;;
  esac
}

# --- 8 scratch ----------------------------------------------------------------------
# row_named <name>: list_row_named (top of this file) on the drill's screen
row_named() { pane | list_row_named "$1"; }
# the right pane's note while no machine is up (fleet-shell.sh wait): the
# generic one is what a newcomer must never be left with (issue #2220)
SCRATCH_NOHOST='入口没有在线的机器|no machine of yours is online'
# the sidebar's refusals (fleet-ui-lang.sh sidebar_place_*, zh + en): held on
# the bar until a key since #2069 (a 4 s toast before), polled every second
SCRATCH_NO='还没有仓库|还没有能开会话的机器|入口连不上|开机器没成功|机器还没开好|no repo yet|no machine of yours|hub is unreachable|machine for you failed|machine is not ready yet'
# the hub opening the person's first login (issue #2069): not a refusal — the
# sidebar holds the Enter and opens the session itself once the login is up,
# so the step waits (FLEET_DRILL_OPENING_SECS, default 360) and it is no 要人帮
SCRATCH_OPENING='正在为你开机器|opening a machine for you'
step_scratch() {
  local k said deadline p answered=0 r opening=
  if pane | grep -Eq -- "$SCRATCH_NOHOST"; then
    shot scratch-nohost
    said=$(pane | grep -Eo -- "($SCRATCH_NOHOST)[^│]*" | head -n 1 | sed 's/ *$//')
    row "右边：$said" "—" "是 — 新人没机器，入口没说在开、也没说找谁"
    failstep scratch "the right pane says no machine and nothing about opening one: $said"; return 1
  fi
  keys C-b c
  sleep 1
  keys -l "$NAME"; keys Enter
  deadline=$((SECONDS + STEP_SECS)); k=''
  while [ "$SECONDS" -lt "$deadline" ]; do
    keep_sudo
    p=$(pane)
    if printf '%s\n' "$p" | grep -Eq -- "$SCRATCH_NO"; then k=no; break; fi
    if [ -n "$(row_named "$NAME")" ]; then k=row; break; fi
    if [ -z "$opening" ] && printf '%s\n' "$p" | grep -Eq -- "$SCRATCH_OPENING"; then
      opening=$(printf '%s\n' "$p" | grep -Eo -- "($SCRATCH_OPENING)[^│]*" | head -n 1 | sed 's/ *$//')
      shot scratch-opening
      deadline=$((SECONDS + ${FLEET_DRILL_OPENING_SECS:-360}))
    fi
    if printf '%s\n' "$p" | grep -Eq '→ 开在哪|→ where|→ 选仓库|New session → repo'; then
      # the repo question, then 「开在哪」: Enter takes the highlighted default
      answered=$((answered + 1)); [ "$answered" -le 3 ] || { k=stuck; break; }
      shot "scratch-ask-$answered"; keys Enter; sleep 2; continue
    fi
    sleep 1
  done
  case "$k" in
    no)  shot scratch-refused
         said=$(printf '%s\n' "$p" | grep -Eo -- "($SCRATCH_NO)[^│]*" | head -n 1 | sed 's/ *$//')
         row "提示：$said" "prefix c 新任务，敲名字 ${NAME}，回车" "是 — 开不出会话：$said"
         failstep scratch "the list refused a new session: $said"; return 1 ;;
    row) : ;;
    *)   shot scratch-none
         row "敲名字回车后没有问题、没有新行、也没有提示" "prefix c 新任务，敲名字，回车" "是 — 不知道怎么开会话"
         failstep scratch "no question, no row named $NAME and no refusal within ${STEP_SECS}s:"; tail_pane; return 1 ;;
  esac
  [ -z "$opening" ] || row "提示：$opening" "等（入口在开机器，开好自动接着开）" 否
  [ "$answered" = 0 ] || row "问题（选仓库 / 开在哪）×$answered" "回车（默认，自动）" 否
  shot scratch
  r=$(row_named "$NAME")
  row "列表里新的一行 ${NAME}，右边切到它" "等" 否
  pass scratch "the new session's row: $r · $(elapsed)"
}

# --- 9 offboard ---------------------------------------------------------------------
hub_revoke() {
  local fp=$1 out
  [ -n "$VIEWER" ] || { printf 'no CCQUOTA_VIEWER_TOKEN / FLEET_HUB_TOKEN in the environment'; return 1; }
  out=$(printf '{"fingerprint":"%s"}' "$fp" | curl -fsS --max-time 15 -X POST \
        -H "Authorization: Bearer $VIEWER" -H 'Content-Type: application/json' \
        --data-binary @- "$HUB/v1/fleet/devices/revoke" 2>&1) || { printf '%s' "$out"; return 1; }
  printf '%s' "$out"
}
# hub_retire <ep_id>: the operator takes a node off the hub (#1928) — the
# fallback when the login's own `fleet node leave` did not.
hub_retire() {
  local ep=$1 out
  [ -n "$VIEWER" ] || { printf 'no CCQUOTA_VIEWER_TOKEN / FLEET_HUB_TOKEN in the environment'; return 1; }
  out=$(printf '{"endpoint_id":"%s","reason":"onboard drill teardown"}' "$ep" | curl -fsS --max-time 15 -X POST \
        -H "Authorization: Bearer $VIEWER" -H 'Content-Type: application/json' \
        --data-binary @- "$HUB/v1/fleet/nodes/retire" 2>&1) || { printf '%s' "$out"; return 1; }
  printf '%s' "$out"
}
# hub_self_delete: the drill person removes itself — person, devices, nodes —
# signed by the login's own certificate, else proven by the approve code (a
# scan that never finished left no certificate). Prints the hub's answer.
hub_self_delete() {
  local ts sig cert body resp
  if cert=$(as_login head -n 1 "$H/.ssh/fleet-cert-cert.pub" 2>/dev/null) && [ -n "$cert" ]; then
    ts=$(date +%s)
    if sig=$(printf 'fleet-drill %s delete-self' "$ts" | as_login ssh-keygen -Y sign -f "$H/.ssh/fleet-cert" -n "$DRILL_NS" 2>/dev/null); then
      body=$(python3 -c 'import json,sys; print(json.dumps({"cert":sys.argv[1],"sig":sys.argv[2],"ts":int(sys.argv[3])}))' "$cert" "$sig" "$ts")
      resp=$(hub_json DELETE /v1/self "$body")
      if [ "$(hub_code "$resp")" = 200 ]; then printf 'by its certificate: %s' "$(hub_body "$resp")"; return 0; fi
    fi
  fi
  resp=$(hub_json DELETE /v1/self "$(printf '{"approve_code":"%s"}' "$INVITE")")
  if [ "$(hub_code "$resp")" = 200 ]; then printf 'by the approve code: %s' "$(hub_body "$resp")"; return 0; fi
  printf 'HTTP %s %s' "$(hub_code "$resp")" "$(hub_body "$resp" | head -c 200)"
  return 1
}
step_offboard() {
  local fp rc warn='' out
  # what to take back on the hub, read off the login before it goes
  fp=$(as_login ssh-keygen -lf "$H/.ssh/fleet-cert.pub" 2>/dev/null | awk '{print $2}')
  FPR=${fp:-$FPR}
  [ -n "$EPID" ] || EPID=$(as_login cat "$H/.config/claude-fleet/node-join.log" 2>/dev/null | grep -Eo 'ep_[0-9]+' | tail -n 1)
  if [ -n "$INVITE" ]; then
    # the drill person's own way off the hub (#2010) — before its files go
    if out=$(hub_self_delete); then note "drill person deleted itself on the hub $out"
    else warn="$warn · the drill person did not delete itself ($out) — the hub deletes it when its life ends"; fi
    FPR='' EPID=''   # its device and node went with it
  fi
  kill_own_tmux
  ( cd / && sudo -n pkill -u "$LOGIN" ) >/dev/null 2>&1 || :
  if [ -n "$FPR" ]; then
    if out=$(hub_revoke "$FPR"); then note "device $FPR revoked on the hub: $out"
    else warn="$warn · device $FPR not revoked ($out)"; fi
  fi
  ( cd "$HOME" && bash "$RM_SH" "$LOGIN" --delete-home --apply ) > "$RUN/login-remove.log" 2>&1; rc=$?
  # The node: fleet-login-remove.sh's own `fleet node leave` (#1928), else the
  # operator's retire — never a step inside the cluster.
  if [ -n "$EPID" ]; then
    if grep -aEq 'the hub (had already )?retired|no longer knows this token' "$RUN/login-remove.log"; then
      note "node $EPID taken off the hub by fleet node leave"
    elif [ -n "${FLEET_DRILL_RETIRE_CMD:-}" ]; then
      if sh -c "$FLEET_DRILL_RETIRE_CMD \"\$1\"" _ "$EPID" > "$RUN/retire.log" 2>&1; then note "node $EPID retired: $(tail -n 1 "$RUN/retire.log")"
      else warn="$warn · node $EPID not retired ($(tail -n 1 "$RUN/retire.log"))"; fi
    elif out=$(hub_retire "$EPID"); then
      note "node $EPID retired by the operator: $out"
    else
      warn="$warn · node $EPID stays on the hub ($out) — remove it on the machines page (「移除」)"
    fi
  fi
  if [ "$rc" != 0 ]; then
    failstep offboard "fleet-login-remove.sh $LOGIN --delete-home --apply: exit $rc — $(tail -n 1 "$RUN/login-remove.log")$warn"
    return 1
  fi
  if [ -n "$warn" ]; then
    pass offboard "login removed (fleet-login-remove.sh --delete-home) · WARN$warn"
  elif [ -n "$INVITE" ]; then
    pass offboard "login removed (fleet-login-remove.sh --delete-home) · drill person, device and node deleted on the hub"
  else
    pass offboard "login removed (fleet-login-remove.sh --delete-home)$([ -n "$FPR" ] && printf ' · device revoked')$([ -n "$EPID" ] && printf ' · node retired')"
  fi
}

# --- 10 residue ---------------------------------------------------------------------
step_residue() {
  local left='' g n st
  id "$LOGIN" >/dev/null 2>&1 && left="$left · login record"
  [ ! -e "$H" ] || left="$left · home $H"
  if [ -n "$UIDN" ]; then
    n=$(ps -axo uid= 2>/dev/null | awk -v u="$UIDN" '$1 == u' | grep -c .)
    [ "$n" = 0 ] || left="$left · $n process(es) of uid $UIDN"
  fi
  for g in $(dscl . -list /Groups 2>/dev/null | grep '^com\.apple\.access_' || :); do
    dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$LOGIN" && left="$left · $g lists $LOGIN"
    [ -z "$GUID" ] || { dscl . -read "/Groups/$g" GroupMembers 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$GUID" && left="$left · $g lists its GUID"; }
  done
  if [ -n "$FPR" ] && [ -n "$VIEWER" ]; then
    st=$(curl -fsS --max-time 15 -H "Authorization: Bearer $VIEWER" "$HUB/v1/fleet/devices" 2>/dev/null \
         | python3 -c 'import json,sys
fp=sys.argv[1]
for d in json.load(sys.stdin).get("devices") or []:
    if d.get("fingerprint")==fp:
        print("revoked" if d.get("revoked_at") or d.get("state")=="revoked" else "live"); break
else: print("gone")' "$FPR" 2>/dev/null)
    case "$st" in revoked|gone) ;; *) left="$left · device $FPR ${st:-unreadable} on the hub" ;; esac
  fi
  if [ -n "$INVITE" ]; then
    # the hub's own word (kept as evidence): a 401 = it knows no such drill
    # person. A 200 means it was still there — deleted now, but a leftover.
    local resp
    resp=$(hub_json DELETE /v1/self "$(printf '{"approve_code":"%s"}' "$INVITE")")
    printf 'DELETE %s/v1/self (approve code) → HTTP %s %s\n' "$HUB" "$(hub_code "$resp")" "$(hub_body "$resp")" > "$RUN/hub-residue.txt"
    case "$(hub_code "$resp")" in
      401) note "hub: $(hub_body "$resp" | head -c 120) — the drill person is gone" ;;
      200) left="$left · the drill person was still on the hub (deleted by this check)" ;;
      *)   left="$left · the hub's answer on the drill person: HTTP $(hub_code "$resp")" ;;
    esac
  fi
  if [ -z "$left" ]; then
    pass residue "none: no login, no home, no process, no access-group entry$([ -n "$FPR" ] && [ -n "$VIEWER" ] && printf ', device revoked')$([ -n "$INVITE" ] && printf ', no drill person on the hub')"
  else
    failstep residue "left behind:$left"
    return 1
  fi
}

# --- the end ----------------------------------------------------------------------
finish() {
  [ "$SUMMARISED" = 0 ] || return 0
  SUMMARISED=1
  if [ "$KEEP" = 1 ] && [ "$TEARDOWN" = 0 ]; then
    kill_own_tmux
    skip offboard "--keep: $LOGIN stays up — clean it with: $0 --teardown $LOGIN"
  elif id "$LOGIN" >/dev/null 2>&1 || [ -e "$H" ]; then
    step_offboard || :
    step_residue || :
  else
    kill_own_tmux
    skip offboard "login $LOGIN was never created — nothing to remove"
  fi
  rm -f "$RUN/id_ed25519" "$RUN/id_ed25519.pub"
  printf '\n'
  if [ "$NFAIL" = 0 ]; then
    printf '%s: PASS  %d passed · %d skipped · %s · log %s\n' "$PROG" "$NPASS" "$NSKIP" "$(elapsed)" "$RUN"
  else
    printf '%s: FAIL  %d passed · %d failed · %d skipped · %s · log %s\n' "$PROG" "$NPASS" "$NFAIL" "$NSKIP" "$(elapsed)" "$RUN"
  fi
  if [ "$TEARDOWN" = 0 ]; then
    printf '\nreading (EPIC #1906): 同事从拿到命令到开出第一个会话要人帮的步骤: %s\n' "$NHELP"
    printf 'steps (%s, %s screens beside it):\n' "$STEPS" "$NSHOT"
    sed 's/^/  /' "$STEPS"
  fi
  [ "$NFAIL" = 0 ] && exit 0
  exit 1
}
on_signal() { trap - INT TERM HUP; printf '\n%s: interrupted — tearing down\n' "$PROG" >&2; finish; }
trap on_signal INT TERM HUP
# a step that dies (set -u, a typo) still tears the login down: finish is idempotent
trap '[ "$SUMMARISED" = 1 ] || { printf "\\n%s: a step died — tearing down\\n" "$PROG" >&2; finish; }' EXIT

if [ "$TEARDOWN" = 1 ]; then
  UIDN=$(id -u "$LOGIN" 2>/dev/null || :)
  GUID=$(dscl . -read "/Users/$LOGIN" GeneratedUID 2>/dev/null | awk '$1=="GeneratedUID:" {print $2; exit}')
  finish
fi
step_open || finish
step_ssh || finish
step_install || finish
step_scan || finish
step_client || finish
step_scratch || :
finish
