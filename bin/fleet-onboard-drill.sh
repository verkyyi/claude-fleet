#!/bin/bash
# fleet-onboard-drill.sh [--login <name>] [--invite <code>] [--home <machine>] [--hub <url>]
#                        [--scan-cmd <cmd>] [--keep] [--timeout <secs>] [--ssh-host <h>]
#                        [--ssh-port <p>] [--name <scratch>] | --teardown <login> [--invite <code>] [--home <machine>]
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
# --home <machine> (issue #3432): the newcomer's login is opened on THAT
# machine — mini2, fleet-linux-0 — not where placement would put it. With no
# --invite the drill mints its own drill person for it (`fleet drill invite
# --login <login> --home <machine>`, an admin's certificate or token; the login
# is then drill<MMDDHHMM> unless --login names a drill<x>); with --invite the
# invite already carries its home and --home is the machine the run expects.
# Either way step 8 checks the session's row is on it (`fleet ls --json`), and
# step 10 restarts tmux THERE: here through sudo, on another machine through the
# login's own client (`fleet-thin.py --run --home <machine>`, the line every
# connection takes — the restart runs as that login, nothing else is reached).
# Only a drill person can carry a home: a real newcomer is always placed. Run
# the drill on another machine than --home (its own login there is the drill's).
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
#               waits for 「✓ 已登记到入口」, or the client coming up with the
#               scan's certificate in the login (a newcomer's install prints no
#               ✓ line, #2347) (「能力:」 alone also follows an
#               expired code). A refusal the page
#               gives (no login on any machine yet, …) IS 要人帮 — a FAIL naming it.
#               With --invite <code> (issue #2010) nobody scans: the code `fleet
#               drill invite` printed confirms it (POST /fleet/login/approve) as
#               the DRILL PERSON the hub minted — never as you, so the run walks
#               a new colleague's first time, not your second computer's.
#   7 client    the installer execs `fleet`: the task list must come up — `open
#               terminal failed` there is a FAIL (fixed in #1901).
#   8 scratch   THE THIN CLIENT (issue #3445 — plain `fleet` since EPIC #2999;
#               told by its own thin.log): its 看台 binds ONE key of ours, the
#               panel, and tmux's stock keys otherwise — prefix c there is a
#               bare new-window (drill 29 typed `first` into a zsh). So: the
#               panel's key as the client sends it, read off the client's OWN
#               switch table (dash-keymap.sh --panel switch: the default action,
#               quickopen — ⌘P — and its code, ESC [ 927 ~), the name typed into
#               its search line, ⚡ lit (↓ when the words hit a session), Enter:
#               the session must turn up in the client's `fleet ls --json` (its
#               name or title). Its panel never coming up, or 「新会话没开起来」,
#               is a FAIL. THE OLD CLIENT: the writing area (prefix c — ⌘N, the key the client's bar
#               names, is iTerm2's spelling of it; the list itself takes no
#               keys since #1950), a name typed, Enter; the repo question and
#               「开在哪」 each Enter (the default, 自动); a new ROW — never the
#               input line 「› <name>」, never a line outside the split (the
#               shell prompt 「<login>@host % …」 above it, #2221) — must
#               appear, the name a whole word (default `first`: never a part
#               of the login, which is refused). Before any key: the right
#               pane's 「入口没有在线的机器」 is a FAIL (issue #2220 — a
#               newcomer is told 「正在为你开机器」 or who to ask). While
#               the screen says 「正在为你开机器」 the step waits on — a real
#               create is 13 min+ (#2908) — until the row, the hub's failed, or
#               the hub's own give-up + 1 min; every ETA it shows is kept
#               (scratch-eta.txt) and one that went UP is 要人帮 (#2731). The
#               sidebar's refusal (no repo / no machine of yours / hub down,
#               zh or en) is 要人帮 — a FAIL naming it. The row's line is the
#               evidence.
#  8a claude-answers  (issue #3445) the pass line: in the session step 8 opened
#               (the 看台 is on it), claude's prompt up, one short line typed
#               (pong, asked back in capitals), its reply 「⏺ PONG」 on screen
#               within FLEET_DRILL_AGENT_SECS. 「API Error」 / 「Please run /login」
#               / an invalid key / a 403 on an error line is a FAIL quoting the
#               line. The old client: SKIP (its list holds the keys).
#   9 attach-attachment  (EPIC #2482 C1) a solid red PNG in the login's home,
#               its path typed into the writing area after 「看图 这张图是什么颜色？…」,
#               Enter; the session — on whatever machine the hub put it — must
#               show the file at ITS machine's path (…/attachments/<id>/…) and
#               answer 红 / red (FLEET_DRILL_AGENT_SECS, 300). 「附件没带过去」 or
#               no such path is 要人帮 — a FAIL naming it. The thin client: the
#               panel opens 看图, then the question is typed in the session and
#               the file DROPPED (a bracketed paste of its path — the thin loop
#               uploads it and pastes the path on the home), Enter.
#  10 node-restart-resume  (C5) the session's machine restarts its tmux as an
#               update does: as the login that runs it (found by the row's
#               @fleet_id, `fleet ls --json`), `fleet-sessions-snapshot.sh save`,
#               kill-server, `restore` — which must say `back`; the client must
#               come back on the same row and key, its text shown again (the
#               thin client: its visible screen no longer down, the text on it). A
#               session on another machine is restarted there, as its login,
#               over the login's own client (fleet-thin.py --run --home, #3432).
#  11 offboard  stop the login's processes, revoke its device on the hub
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
#               Every OTHER machine the login was put on (issue #3471 — drill 33
#               left drill10120108 on mini2 under a PASS): --home, and each
#               machine the hub's roster (GET /v1/fleet/accounts, the operator's
#               token) lists a login of that name on — the hub is asked to close
#               it (POST action remove) and the roster read until it is removed;
#               one still there after FLEET_DRILL_REMOVE_SECS is a FAIL naming
#               the machine, its state and the node's words.
#  12 residue   no login record, home, process, access or share group entry
#               (com.apple.sharepoint.group.*, its Public Folder), nor any login
#               made during the run (the hub's for the drill person); the device
#               revoked on the hub. With --invite: the hub no longer knows the
#               drill person (its answer is kept as hub-residue.txt). The same
#               look on EVERY other machine of step 11 (issue #3471), over ssh
#               (the hub's five-minute certificate, else plain ssh), read-only:
#               a machine that cannot be read is a FAIL, never a clean one
#               (residue-<machine>.txt). Never a PASS from this machine alone
#               when the login went elsewhere.
#
# The reading: 「要人帮的步骤」 = the FAILs a person would have had to be asked
# about. The scan is the colleague's own and is not counted. A run cut short
# (INT / TERM / HUP, or a step that died) still tears down, then reads
# `ABORTED (<why>)` — never PASS — exits 128+signal (1 for a died step) and
# gives the reading no number (issue #2865). `--invite ''` is refused, never
# taken for 「a person scans」.
#
# --teardown <login>: steps 11–12 only, for a run left up (--keep) or cut short.
# --home <machine> beside it names the machine the run's login was opened on
# (issue #3471): it is cleaned and checked even when this machine has none.
#
# --runs N: the 60-second standard instead (bin/fleet-onboard-clock.sh, #2267) —
# `fleet-onboard-drill.sh --hub prod --runs 3`: sandbox HOMEs, no new login.
#
# Needs: an admin login (never root), a sudo ticket (`sudo -v` first — nothing
# here prompts), ssh, tmux, Remote Login on --ssh-host:--ssh-port (default
# 127.0.0.1:22), and for the device revoke CCQUOTA_VIEWER_TOKEN (or
# FLEET_HUB_TOKEN) in the environment — read at start, never written.
# Who may run it is the LOGIN's ability, never a rule about the caller (issue
# #2842): it opens a real login and runs sudo, so the preflight asks `sudo -n
# true` and refuses with 「需要管理员登录（有 sudo）」 when it does not pass — a
# fleet worker runs on a taken-over login with no admin and no sudo, so it is
# refused by that, and a session that has the ability (the orchestrator over an
# admin's ssh) runs the drill. Run it on the machine meant for drills.
#
# Exit: 0 every step passed · 1 a step failed (the teardown still ran) ·
#       2 bad arguments / preflight · 3 the login (or its home) already exists
# Env: FLEET_DRILL_TIMEOUT (900 s, the download) · FLEET_DRILL_SCAN_SECS (600,
#      the QR's life) · FLEET_DRILL_STEP_SECS (120, any other wait) ·
#      FLEET_DRILL_OPENING_SECS (1260, while the hub still says 「正在为你开
#      机器」: its own 20 min give-up + 1) · FLEET_DRILL_OPENED_SECS (300, the row
#      after it stops saying so) ·
#      FLEET_DRILL_POLL_SECS (2) · FLEET_DRILL_REMOVE_SECS (600, the hub closing
#      the drill person's login) · FLEET_DRILL_RETIRE_CMD · FLEET_LOGIN_HOMES (/Users)
set -u

PROG=fleet-onboard-drill
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
# The screen judgments (list_row_named · qr_state · attach_state · ls_row ·
# drill_png) are platform-free and live in fleet-onboard-judge.sh, shared with
# the Linux newcomer run bin/newcomer-cn.sh (issue #2888); this script keeps
# the macOS login half (sysadminctl, Remote Login, fleet-login-remove).
# shellcheck source=fleet-onboard-judge.sh
. "$BIN/fleet-onboard-judge.sh"

# --runs N (issue #2267, EPIC #2259 C8): the 60-second standard — a sandbox per
# run, timed from the paste to the first key the agent takes, every known pit
# checked; no OS login is made. That is bin/fleet-onboard-clock.sh, whole.
for a in "$@"; do [ "$a" = --runs ] && exec bash "$BIN/fleet-onboard-clock.sh" "$@"; done

LOGIN='' HUB='' SCAN_CMD='' KEEP=0 HOME_M='' TEARDOWN=0 NAME=first INVITE='' INVITE_SET=0 ROW_ONLY='' QR_ONLY=0
DRILL_NS=fleet-drill@claude-fleet
HOST=127.0.0.1 PORT=22
TIMEOUT=${FLEET_DRILL_TIMEOUT:-900} SCAN_SECS=${FLEET_DRILL_SCAN_SECS:-600}
STEP_SECS=${FLEET_DRILL_STEP_SECS:-120} POLL=${FLEET_DRILL_POLL_SECS:-2}
REMOVE_SECS=${FLEET_DRILL_REMOVE_SECS:-600}   # the hub closing the drill person's login (202 removing)
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
    --invite)   [ $# -ge 2 ] || usage; INVITE=$2; INVITE_SET=1; shift 2 ;;
    --home)     [ $# -ge 2 ] || usage; HOME_M=$2; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    --row-named) [ $# -ge 2 ] || usage; ROW_ONLY=$2; shift 2 ;;   # selftest seam: screen on stdin
    --qr-state) QR_ONLY=1; shift ;;                                 # selftest seam: screen on stdin
    --attach-state) attach_state; exit 0 ;;                         # selftest seam: screen on stdin
    --answer-state) [ $# -ge 2 ] || usage; answer_state "$2"; exit 0 ;;   # selftest seam: screen on stdin
    --answer-bad) answer_bad_line; exit 0 ;;                         # selftest seam: screen on stdin
    --opening-eta) opening_eta; exit 0 ;;                           # selftest seam: screen on stdin
    --eta-rises) eta_rises; exit 0 ;;                               # selftest seam: ETAs on stdin
    --thin-first) thin_first_state; exit 0 ;;                       # selftest seam: thin.log on stdin
    --thin-first-says) grep -Eq -- "$THIN_FIRST|$THIN_FIRST_FAILED"; exit $? ;;   # selftest seam: a screen on stdin
    --thin-view-up) grep -Eq -- "$CLIENT_UP|$VIEW_UP"; exit $? ;;    # selftest seam: a screen on stdin
    --ls-row)   [ $# -ge 2 ] || usage; ls_row "$2" "${3:-}"; exit ;;   # selftest seam: fleet ls --json on stdin [keys before]
    --ls-keys)  ls_keys; exit ;;                                     # selftest seam: fleet ls --json on stdin
    --png)      [ $# -ge 2 ] || usage; drill_png "$2"; exit ;;         # selftest seam: the test image
    -h|--help)  sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)          die2 "unknown argument: $1" ;;
  esac
done
if [ "$QR_ONLY" = 1 ]; then qr_state "$LOGIN"; exit 0; fi
if [ -n "$ROW_ONLY" ]; then r=$(list_row_named "$ROW_ONLY"); [ -n "$r" ] && printf '%s\n' "$r"; [ -n "$r" ]; exit; fi
# an --invite given empty (an unset $CODE) is a mistake, never 「a person scans」 (#2865)
[ "$INVITE_SET" = 0 ] || [ -n "$INVITE" ] || die2 "--invite: empty — pass the fd_… code fleet drill invite printed, or leave --invite off for a person to scan"
if [ -n "$INVITE" ]; then
  printf '%s' "$INVITE" | grep -Eq '^fd_[a-z2-7]{26}$' || die2 "--invite: not an approve code (fd_… from fleet drill invite)"
  # the drill person's certificate names ITS login: the OS login must be it
  [ -n "$LOGIN" ] || die2 "--invite needs --login <the login fleet drill invite printed>"
fi
if [ -n "$HOME_M" ]; then
  printf '%s' "$HOME_M" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' || die2 "--home: a machine name (got '$HOME_M')"
  # the drill mints its own drill person for the home: a drill login's name
  # (a --teardown --home only names the machine its steps 11–12 must clean, #3471)
  if [ -z "$INVITE" ] && [ "$TEARDOWN" = 0 ]; then
    [ -n "$LOGIN" ] || LOGIN="drill$(date +%m%d%H%M)"
    printf '%s' "$LOGIN" | grep -Eq '^drill[a-z0-9]{1,11}$' \
      || die2 "--home without --invite mints a drill person: --login must be drill + 1-11 lowercase letters or digits (got '$LOGIN')"
  fi
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
INVITE_SH="${FLEET_DRILL_INVITE_SH:-$BIN/fleet-drill.sh}"          # the env is the selftest's seam
# FLEET_DRILL_ONLY=8-10 (selftest seam, issue #3432; `8` = steps 8 + 8a, #3445): steps 8–10 against a client
# already up on this run's own tmux server (-L fleet-drill-<login>, session
# drill) — no login is opened and none is removed, the run's tmux is the test's
ONLY=${FLEET_DRILL_ONLY:-}
case "$ONLY" in ''|8|8-10) ;; *) die2 "FLEET_DRILL_ONLY: 8 or 8-10 (got '$ONLY')" ;; esac
TMUXB=$(command -v tmux 2>/dev/null || :)
[ -n "$TMUXB" ] || for t in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do [ -x "$t" ] && TMUXB=$t && break; done

# --- preflight (exit 2 / 3): nothing below has changed anything yet ------------
for t in ssh ssh-keygen sudo curl python3; do
  command -v "$t" >/dev/null 2>&1 || die2 "$t not found — nothing was changed"
done
[ -n "$TMUXB" ] || die2 'tmux not found — nothing was changed'
[ -f "$RM_SH" ] || die2 "fleet-login-remove.sh not found beside $0"
sudo -n true >/dev/null 2>&1 || die2 "需要管理员登录（有 sudo）— no sudo ticket for $(id -un): run it as an admin login; run 'sudo -v' first (this script never prompts)"
if [ -n "$ONLY" ]; then
  :   # the seam's login is the test's stand-in: it need not (and may) exist
elif [ "$TEARDOWN" = 0 ]; then
  if id "$LOGIN" >/dev/null 2>&1; then
    printf '%s: login %s already exists — refusing (another --login, or clean it: %s --teardown %s)\n' "$PROG" "$LOGIN" "$0" "$LOGIN" >&2
    exit 3
  fi
  [ ! -e "$H" ] || { printf '%s: %s already exists (no such login) — refusing\n' "$PROG" "$H" >&2; exit 3; }
else
  # with --home the login may be left on THAT machine alone (#3471)
  id "$LOGIN" >/dev/null 2>&1 || [ -e "$H" ] || [ -n "$HOME_M" ] \
    || die2 "--teardown: no login $LOGIN and no $H — nothing to clean (left on another machine? --home <machine>)"
fi

# --home with no --invite: this run's own drill person, its login opened on the
# home (issue #3432) — minted before anything is changed, so a refusal is exit 2
if [ -n "$HOME_M" ] && [ -z "$INVITE" ] && [ "$TEARDOWN" = 0 ]; then
  inv=$(bash "$INVITE_SH" invite --login "$LOGIN" --home "$HOME_M" --json 2>&1) \
    || die2 "--home: the hub did not mint a drill person for $HOME_M: $(printf '%s' "$inv" | tail -n 1)"
  INVITE=$(printf '%s' "$inv" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read().strip().splitlines()[-1])
except (ValueError, IndexError):
    sys.exit(1)
if d.get("login") != sys.argv[1]:
    sys.exit(1)
print(d.get("approve_code", ""))' "$LOGIN") || INVITE=''
  printf '%s' "$INVITE" | grep -Eq '^fd_[a-z2-7]{26}$' \
    || die2 "--home: the hub's answer carried no approve code for $LOGIN"
  printf '%s: drill person for %s minted, its login opened on %s\n' "$PROG" "$LOGIN" "$HOME_M"
fi

RUN=$(mktemp -d "${TMPDIR:-/tmp}/fleet-onboard-drill.$LOGIN.XXXXXX") || die2 'mktemp failed'
chmod 700 "$RUN"
printf '%s: login=%s  hub=%s  ssh=%s:%s  confirm=%s%s  log dir %s\n' "$PROG" "$LOGIN" "$HUB" "$HOST" "$PORT" \
  "$([ -n "$INVITE" ] && echo 'drill person (--invite)' || echo 'a person scans')" "${HOME_M:+  home=$HOME_M}" "$RUN"

# --- bookkeeping -----------------------------------------------------------------
T0=$SECONDS TS=$SECONDS
STEP=0 NPASS=0 NFAIL=0 NSKIP=0 NHELP=0 NSHOT=0
UIDN='' GUID='' FPR='' EPID='' TMUX_UP=0 SUMMARISED=0 NOISE=0 SCAN_URL='' ABORTED='' ABORT_RC=1
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
# screen: the visible pane only — what it says NOW, never what scrolled past
screen() { tmux_own capture-pane -p -J -t "$TSESS" 2>/dev/null; }
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
  local pw t out key="$RUN/id_ed25519"
  ssh-keygen -q -t ed25519 -N '' -C "$PROG-$LOGIN" -f "$key" || { failstep open 'ssh-keygen failed'; return 1; }
  # the password: 24 random letters and digits, ending in one of each — the
  # machine's policy wants both (macmini: minLength12 · hasLetter · hasDigit),
  # and a draw with no digit made sysadminctl refuse it, 5402 (C9 run 11)
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 22)a7"
  # every login before this run: a login the hub opens for the drill person
  # (its session's machine, when that is this one) must be gone at the residue
  dscl . -list /Users 2>/dev/null | sort > "$RUN/users-before.txt"
  t=$SECONDS
  # No password on any argv (#2396): created shell-less, the password goes in
  # on dscl's stdin, then the shell is given back — fleet-login-new.sh's road
  ( cd / && sudo -n sysadminctl -addUser "$LOGIN" -fullName "Onboard Drill ($LOGIN)" -shell /usr/bin/false ) > "$RUN/open.log" 2>&1
  # sysadminctl's exit says nothing about whether the login exists (#2210)
  if ! id "$LOGIN" >/dev/null 2>&1; then
    failstep open "sysadminctl -addUser $LOGIN made no login: $(grep -v '^-*$' "$RUN/open.log" | grep -v -- '-----' | tail -n 1)"
    return 1
  fi
  out=$(printf 'passwd /Users/%s %s\n' "$LOGIN" "$pw" | ( cd / && sudo -n dscl . ) 2>&1)
  pw=''
  if printf '%s' "$out" | grep -qi 'error'; then
    failstep open "dscl passwd $LOGIN: $(printf '%s' "$out" | tail -n 1)"
    return 1
  fi
  ( cd / && sudo -n dscl . -create "/Users/$LOGIN" UserShell /bin/zsh ) >> "$RUN/open.log" 2>&1
  # how long addUser itself took here — the hub's create of the drill
  # person's login takes ~5 min in it on macmini (#2908); this is the
  # comparison from an admin's shell
  t=$((SECONDS - t)); note "sysadminctl -addUser: ${t}s"; printf 'sysadminctl -addUser: %ss\n' "$t" >> "$RUN/open.log"
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
  NOISE=$(pane | curl_noise)
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
  local code k deadline
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
  # A newcomer's install says nothing after the scan (#2347 — no 入口 / 节点
  # line) and goes straight into the client, whose screen covers the rest and
  # whose labels change (C9 runs 1 and 2, 2026-10-09: approved, client up, 600 s
  # of waiting): the certificate the scan writes into the login is the proof.
  deadline=$((SECONDS + SCAN_SECS)) k=''
  while :; do
    k=$(wait_for 0 '已登记到入口' '✗ |还不能签发|access_denied|已过期|not issued|没登记成|机器登录')
    [ -z "$k" ] || break
    as_login test -s "$H/.ssh/fleet-cert-cert.pub" 2>/dev/null && { k=1; break; }
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$POLL"
  done
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
  k=$(wait_for "$STEP_SECS" "$CLIENT_UP" 'open terminal failed|not a terminal' "$THIN_FIRST|$THIN_FIRST_FAILED" "$LOGIN@[^ ]+ [^ ]* ?[%\$#] *\$")
  shot client
  case "$k" in
    1) row "客户端：左边任务列表、右边主页" "—（装完自己打开）" 否
       pass client "the installer opened the client: the task list is up · $(elapsed)" ;;
    3) client_thin ;;
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

# client_thin: the thin client is on its first-session road (#3054) — opening
# the newcomer's first login, waiting for its fleet (#3062), placing the session.
# Not 「back at the prompt」: wait for it, up to OPENING_CAP, by its own book
# (thin.log: placed, then a connection that drew the view), or the screen
# showing the 看台 itself (VIEW_UP: its top line's ‹ i/n ›, #3276 — the log's
# `drawn` needs the home's OSC 7502 cur, which no home sends yet).
client_thin() {
  local deadline st log="$H/.cache/claude-fleet/thin.log"
  deadline=$((SECONDS + OPENING_CAP))
  while :; do
    keep_sudo
    st=$( ( cd / && sudo -n cat "$log" ) 2>/dev/null | thin_first_state)
    case "$st" in landed|failed) break ;; esac
    pane | grep -Eq -- "$THIN_FIRST_FAILED" && { st=failed; break; }
    pane | grep -Eq -- "$CLIENT_UP|$VIEW_UP" && { st=landed; break; }
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$POLL"
  done
  shot client-thin
  case "$st" in
    landed) THINC=1
            row "瘦客户端：开出第一个会话并连上" "—（装完自己打开）" 否
            pass client "the thin client opened the first session and drew it · $(elapsed)" ;;
    failed) row "瘦客户端：第一个会话没开出来" "—" "是 — 首会话没开出来"
            failstep client "the thin client's first session did not open:"; tail_pane 6; return 1 ;;
    *)      row "瘦客户端：${OPENING_CAP}s 内没开出第一个会话" "—" "是 — 首会话没开出来"
            failstep client "the thin client's first session was not up within ${OPENING_CAP}s:"; tail_pane 6; return 1 ;;
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
# sidebar holds the Enter and opens the session itself once the login is up.
# A real create on a Mac takes 13 min and more (sysadminctl alone ~5, #2908),
# so while the VISIBLE screen still says it (opening_eta, fleet-onboard-judge.sh)
# the step keeps waiting — up to FLEET_DRILL_OPENING_SECS from the first
# sighting (1260 s: the hub's own give-up, openingGiveUp 20 min, + 1 min; past
# it the hub says failed) — and once it stops saying it, FLEET_DRILL_OPENED_SECS
# (300) more for the row. A 360 s cap shorter than a real create judged a
# login still being opened a FAIL (#2908). It is no 要人帮.
SCRATCH_OPENING=$OPENING_SAYS
# ssh's first-contact question on the way to the opened machine: a newcomer
# cannot judge a fingerprint, so it is 要人帮 — named, never 「没开好」 (run 13)
SCRATCH_HOSTKEY='Are you sure you want to continue connecting|authenticity of host'
OPENING_CAP=${FLEET_DRILL_OPENING_SECS:-1260}
# The thin client (issue #3445): it has no writing area and no list — its 看台
# takes one key of ours, the panel (⌘P), and tmux's stock keys otherwise (prefix
# c there is a bare new-window: drill 29 typed `first` into a zsh). A new session
# is the panel's ⚡ row: its words typed into the search line, ↵.
THINC=''
# thin_is: is the newcomer's client the thin loop? its own book says so
# (thin.log, written on its first connection), once known it stays known
thin_is() {
  [ -z "$THINC" ] || { [ "$THINC" = 1 ]; return; }
  if ( cd / && sudo -n test -s "$H/.cache/claude-fleet/thin.log" ) 2>/dev/null; then THINC=1; else THINC=0; fi
  [ "$THINC" = 1 ]
}
# panel_code: the private code the newcomer's client sends for the panel, read
# off ITS OWN install, never guessed — the switch table's default action
# (dash-keymap.sh --panel switch default: quickopen, ⌘P) and that action's code
# (list's 4th column, 927): iTerm2's fleet profile turns ⌘P into ESC [ <code> ~
# (fleet-iterm-profile.py), which the 看台 binds as User<code> (fleet_view.key_lines)
panel_code() {
  local km="$H/.local/share/claude-fleet/bin/dash-keymap.sh" run=as_login a
  ( cd / && sudo -n test -f "$km" ) 2>/dev/null || { km="$BIN/dash-keymap.sh" run=''; }
  a=$($run bash "$km" --panel switch default 2>/dev/null | awk '{print $1; exit}')
  [ -n "$a" ] || return 1
  $run bash "$km" --panel switch list 2>/dev/null | awk -v a="$a" '$1 == a && $4 ~ /^[0-9]+$/ {print $4; exit}'
}
hexof() { printf '%s' "$1" | od -An -tx1; }
PANEL_UP='⚡ (新会话|新任务|New session|New task)'
PANEL_NOMATCH='没有会话叫这句话|no session goes by these words'
# the panel's ⚡ row that did not open (fleet-ui-lang.sh view_new_failed)
PANEL_NO='新会话没开起来|the new session did not open'
# pw_row <name>: the new session's row — the old client's list row on screen;
# the thin client's (no list) the client's own `fleet ls --json`, as
# 「<name> · <machine> · <key>」 — the row whose key was not in PW_BEFORE (the
# keys just before the panel's ↵, issue #3464: a no-repo session is named
# 「我的会话」, so by name alone an older one could answer, or none). A list that could not be READ (not JSON — on
# 202937a7 a working row's spinner byte crashed it, #3444) leaves its last stderr
# line in PW_LSERR: drill 30 (#3452) read that as «nothing opened» while the new
# session was answering on screen.
PW_LSERR=''
pw_row() {
  local r out err
  if [ "$THINC" = 1 ]; then
    err=$(mktemp "${TMPDIR:-/tmp}/drill-ls.XXXXXX") || err=/dev/null
    out=$(as_login "$H/.local/bin/fleet" ls --json 2>"$err")
    if printf '%s' "$out" | python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin), list) else 1)' 2>/dev/null; then
      PW_LSERR=''
    else
      PW_LSERR=$(sed '/^[[:space:]]*$/d' "$err" 2>/dev/null | tail -n 1 | cut -c1-160)
      PW_LSERR=${PW_LSERR:-not JSON: $(printf '%s' "$out" | head -n 1 | cut -c1-80)}
    fi
    [ "$err" = /dev/null ] || rm -f "$err"
    r=$(printf '%s' "$out" | ls_row "$1" "$PW_BEFORE") || return 0
    printf '%s · %s · %s\n' "$1" "$(printf '%s' "$r" | cut -f1)" "$(printf '%s' "$r" | cut -f2)"
  else
    row_named "$1"
  fi
}
# thin_open <words>: the thin client's new session — the panel (its own key), the
# words, ⚡ lit (words that hit no session light it; one that hit is lit instead,
# and ↓ is ⚡), ↵. 1 = the panel did not come up within STEP_SECS.
thin_open() {
  local code deadline
  code=$(panel_code) || code=''
  [ -n "$code" ] || { PW_P="no panel key in the client's switch table (dash-keymap.sh --panel switch)"; return 1; }
  # shellcheck disable=SC2046  # one hex byte a word
  keys -H 1b 5b $(hexof "$code") 7e
  deadline=$((SECONDS + STEP_SECS))
  until screen | grep -Eq -- "$PANEL_UP"; do
    [ "$SECONDS" -lt "$deadline" ] || { PW_P=$(screen); return 1; }
    sleep 1
  done
  shot "$2-panel"
  keys -l "$1"; sleep 1
  screen | grep -Eq -- "$PANEL_NOMATCH" || { keys Down; sleep 1; }
  shot "$2-panel-words"
  keys Enter
}
# place_wait <text> <row name> <shot prefix>: the writing area (prefix c), the
# text typed, Enter; the questions on the way each answered with Enter. On the
# thin client: thin_open (PW_K=nopanel when its panel never came up). Sets
# PW_K (row · no · hostkey · stuck · '' = nothing within the wait), PW_P (the last
# screen), PW_ANSWERED, PW_OPENING (the hub's 「正在为你开机器」, if said) and
# PW_OPENED (seconds from it first said to the end), PW_SAID (on `no`: the refusal
# line as the screen says it — the list's, or the thin panel's 「新会话没开起来：<why>」,
# issue #3458). Every ETA it read lands in
# $RUN/<shot prefix>-eta.txt (<secs since first said> <eta>, one a change).
PW_K='' PW_P='' PW_ANSWERED=0 PW_OPENING='' PW_OPENED=0 PW_SAID='' PW_BEFORE=''
# pw_said <screen>: the refusal line on it, up to the box's edge (issue #3458: the
# panel's line is PANEL_NO's, which SCRATCH_NO never matched — the FAIL ended at «:»)
pw_said() { printf '%s\n' "$1" | grep -Eo -- "($SCRATCH_NO|$PANEL_NO)[^│]*" | head -n 1 | sed 's/ *$//'; }
place_wait() {
  local deadline open0='' open_end=0 eta last_eta='' v
  PW_K='' PW_P='' PW_ANSWERED=0 PW_OPENING='' PW_OPENED=0 PW_LSERR='' PW_SAID='' PW_BEFORE=''
  if thin_is; then
    # the keys before ⚡: the new session is the one that was not there (#3464);
    # a list that cannot be read leaves PW_BEFORE empty — then by name, as before
    PW_BEFORE=''
    if as_login "$H/.local/bin/fleet" ls --json 2>/dev/null | ls_keys > "$RUN/$3-before.keys"; then
      PW_BEFORE="$RUN/$3-before.keys"
    fi
    thin_open "$1" "$3" || { PW_K=nopanel; return 0; }
  else
    keys C-b c
    sleep 1
    keys -l "$1"; keys Enter
  fi
  deadline=$((SECONDS + STEP_SECS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    keep_sudo
    PW_P=$(pane)
    if printf '%s\n' "$PW_P" | grep -Eq -- "$SCRATCH_NO"; then PW_K=no PW_SAID=$(pw_said "$PW_P"); break; fi
    v=$(screen)
    if [ "$THINC" = 1 ] && printf '%s\n' "$v" | grep -Eq -- "$PANEL_NO"; then PW_K=no PW_P=$v PW_SAID=$(pw_said "$v"); break; fi
    # not $(pw_row): its PW_LSERR must reach the verdict
    pw_row "$2" > "$RUN/pw-row.txt"
    if [ -s "$RUN/pw-row.txt" ]; then PW_K=row; break; fi
    if printf '%s\n' "$v" | grep -Eq -- "$SCRATCH_HOSTKEY"; then PW_K=hostkey; break; fi
    if printf '%s\n' "$v" | grep -Eq -- "$SCRATCH_OPENING"; then
      if [ -z "$open0" ]; then
        open0=$SECONDS open_end=$((SECONDS + OPENING_CAP))
        PW_OPENING=$(printf '%s\n' "$v" | grep -Eo -- "($SCRATCH_OPENING)[^│]*" | head -n 1 | sed 's/ *$//')
        shot "$3-opening"
      fi
      eta=$(printf '%s\n' "$v" | opening_eta)
      if [ -n "$eta" ] && [ "$eta" != "$last_eta" ]; then
        printf '%s %s\n' "$((SECONDS - open0))" "$eta" >> "$RUN/$3-eta.txt"; last_eta=$eta
      fi
      # still opening: wait on, never past the hub's own give-up (+ a minute)
      deadline=$open_end
    elif [ -n "$open0" ] && [ "$deadline" -ge "$open_end" ]; then
      # it stopped saying so: the login is up (or failed) — the row is next
      deadline=$((SECONDS + ${FLEET_DRILL_OPENED_SECS:-300}))
      [ "$deadline" -le "$open_end" ] || deadline=$open_end
      [ "$deadline" -gt "$SECONDS" ] || deadline=$((SECONDS + 1))
    fi
    if printf '%s\n' "$PW_P" | grep -Eq '→ 开在哪|→ where|→ 选仓库|New session → repo'; then
      # the repo question, then 「开在哪」: Enter takes the highlighted default
      PW_ANSWERED=$((PW_ANSWERED + 1)); [ "$PW_ANSWERED" -le 3 ] || { PW_K=stuck; break; }
      shot "$3-ask-$PW_ANSWERED"; keys Enter; sleep 2; continue
    fi
    sleep 1
  done
  [ -z "$open0" ] || PW_OPENED=$((SECONDS - open0))
}
# eta_row <shot prefix>: the ETAs place_wait read, as one steps.md row — a
# number that went UP is 要人帮 (#2731: the hub's ETA only goes down)
eta_row() {
  local f="$RUN/$1-eta.txt" seen up
  [ -s "$f" ] || return 0
  seen=$(awk '{ printf "%s%s秒@%ss", (NR > 1 ? " → " : ""), $2, $1 }' "$f")
  up=$(awk '{ print $2 }' "$f" | eta_rises)
  if [ -n "$up" ]; then
    row "ETA：$seen" "等" "是 — ETA 回跳 ${up}（应只降不升，#2731）"; note "ETA rose: $up ($seen)"
  else
    row "ETA：$seen" "等" 否
  fi
}
# new_keys <words>: what the person pressed for a new session, as steps.md says it
new_keys() {
  if [ "$THINC" = 1 ]; then printf '⌘P，敲「%s」，⚡ 回车' "$1"; else printf 'prefix c 新任务，敲名字 %s，回车' "$1"; fi
}
step_scratch() {
  local k said p answered r opening
  if pane | grep -Eq -- "$SCRATCH_NOHOST"; then
    shot scratch-nohost
    said=$(pane | grep -Eo -- "($SCRATCH_NOHOST)[^│]*" | head -n 1 | sed 's/ *$//')
    row "右边：$said" "—" "是 — 新人没机器，入口没说在开、也没说找谁"
    failstep scratch "the right pane says no machine and nothing about opening one: $said"; return 1
  fi
  place_wait "$NAME" "$NAME" scratch
  k=$PW_K p=$PW_P answered=$PW_ANSWERED opening=$PW_OPENING
  eta_row scratch
  case "$k" in
    no)  shot scratch-refused
         said=$PW_SAID
         if [ -n "$opening" ]; then
           # the hub said opening, then failed: a result that says why (#2908)
           row "提示：${opening}，${PW_OPENED}s 后：$said" "等" "是 — 入口开机器失败：$said"
           failstep scratch "the hub said '$opening', then after ${PW_OPENED}s: $said"; return 1
         fi
         row "提示：$said" "$(new_keys "$NAME")" "是 — 开不出会话：$said"
         failstep scratch "the list refused a new session: $said"; return 1 ;;
    row) : ;;
    nopanel)
         shot scratch-nopanel
         row "按面板键（⌘P）后没有面板：$(printf '%s' "$PW_P" | sed '/^[[:space:]]*$/d' | tail -n 1 | cut -c1-80)" "⌘P" "是 — 瘦客户端开不出新任务面板"
         failstep scratch "the thin client's panel did not open within ${STEP_SECS}s: $(printf '%s' "$PW_P" | sed '/^[[:space:]]*$/d' | tail -n 1)"; return 1 ;;
    hostkey)
         shot scratch-hostkey
         said=$(printf '%s\n' "$p" | grep -Eo -- "authenticity of host '[^']*'" | head -n 1)
         row "ssh 问：${said:-authenticity of host} … continue connecting (yes/no)?" "—" "是 — 连到新开的机器时 ssh 问主机指纹，新人判断不了"
         failstep scratch "the client stopped at ssh's host-key question on the way to the opened machine:"; tail_pane; return 1 ;;
    *)   shot scratch-none
         if [ -n "$opening" ]; then
           # the hub said it is opening a machine (#2069) and neither a row
           # nor its failed came in its own give-up + a minute (#2908)
           row "提示：${opening}，${PW_OPENED}s 后左边仍没有机器、入口也没说失败" "等" "是 — 入口说在开机器，过了它自己的放弃时限仍没开好也没说失败"
           failstep scratch "the hub said '$opening' and neither a row $NAME nor a failure came within ${PW_OPENED}s (cap ${OPENING_CAP}s):"; tail_pane; return 1
         fi
         if [ "$THINC" = 1 ] && [ -n "$PW_LSERR" ]; then
           # the list could not be read: say so, never «nothing opened» (#3452)
           row "面板 ↵ 之后读不出会话列表（fleet ls --json：${PW_LSERR}）" "$(new_keys "$NAME")" "是 — 会话列表读不出来，看不到新任务有没有开"
           failstep scratch "fleet ls --json could not be read, so no row $NAME could be seen within ${STEP_SECS}s: $PW_LSERR"; tail_pane; return 1
         fi
         row "敲名字回车后没有问题、没有新行、也没有提示" "$(new_keys "$NAME")" "是 — 不知道怎么开会话"
         failstep scratch "no question, no row named $NAME and no refusal within ${STEP_SECS}s:"; tail_pane; return 1 ;;
  esac
  [ -z "$opening" ] || row "提示：${opening}（${PW_OPENED}s 后开好）" "等（入口在开机器，开好自动接着开）" 否
  [ "$answered" = 0 ] || row "问题（选仓库 / 开在哪）×$answered" "回车（默认，自动）" 否
  shot scratch
  r=$(pw_row "$NAME")
  home_check "$NAME" || return 1
  if [ "$THINC" = 1 ]; then
    row "面板关了，看台切到新会话 ${NAME}${HOME_M:+（开在 ${HOME_M}）}" "$(new_keys "$NAME")" 否
  else
    row "列表里新的一行 ${NAME}，右边切到它${HOME_M:+（开在 ${HOME_M}）}" "等" 否
  fi
  pass scratch "the new session's row: $r${HOME_M:+ · on $HOME_M} · $(elapsed)"
}
# same_machine <a> <b>: one machine, spelled either way (macmini-m4 · macmini-m4.local)
same_machine() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$(printf '%s' "${1%%.*}" | tr 'A-Z' 'a-z')" = "$(printf '%s' "${2%%.*}" | tr 'A-Z' 'a-z')" ]
}
# home_check <row name>: with --home (issue #3432) the session must be ON it —
# the client's own list says where (`fleet ls --json`'s node). Placed elsewhere
# is a FAIL naming both: the drill asked for a machine and did not get it.
home_check() {
  local r node deadline
  [ -n "$HOME_M" ] || return 0
  deadline=$((SECONDS + STEP_SECS)); r=''
  while [ -z "$r" ] && [ "$SECONDS" -lt "$deadline" ]; do
    r=$(as_login "$H/.local/bin/fleet" ls --json 2>"$RUN/ls.err" | tee "$RUN/ls-home.json" | ls_row "$1" "$PW_BEFORE")
    [ -n "$r" ] || sleep "$POLL"
  done
  node=$(printf '%s' "$r" | cut -f1)
  if [ -z "$r" ]; then
    row "列表里有 $1，但 fleet ls 里没有" "等" "是 — 看不出会话开在哪台"
    failstep scratch "--home $HOME_M: no row $1 in \`fleet ls --json\` ($(head -c 160 "$RUN/ls.err")) — cannot tell where it runs"; return 1
  fi
  if [ "$node" = - ]; then
    # a row of the listing machine's own carries no node unless the list names it
    # by the hub's #me (issue #3464) — say that, never «runs on -»
    row "列表里有 $1（$(printf '%s' "$r" | cut -f2)），但没写它在哪台机器" "等" "是 — 看不出会话开在哪台"
    failstep scratch "--home $HOME_M: the row $1 ($(printf '%s' "$r" | cut -f2)) names no machine in \`fleet ls --json\` — the listing machine's own row, unnamed (fleet ls older than #3464?)"; return 1
  fi
  if ! same_machine "$node" "$HOME_M"; then
    row "会话开在 ${node}，不是 --home $HOME_M" "等" "是 — 演练指定的机器没用上"
    failstep scratch "--home $HOME_M: the session $1 runs on $node"; return 1
  fi
  return 0
}

# --- 8a claude-answers ---------------------------------------------------------------
# The pass line (issue #3445): claude ANSWERS in the newcomer's first session —
# a session that opened but whose agent says 「API Error」 / 「Please run /login」
# / a 403 is no first session. On the thin client the 看台 is on the session
# step 8 opened: its prompt up, one short line typed, its reply on screen.
# The word asked for is in nothing typed (pong, asked back in capitals).
ANSWER_ASK='只回复一个词：把 pong 写成大写字母'
ANSWER_WORD=PONG
step_answer() {
  local deadline st said
  if [ "$THINC" != 1 ]; then
    skip claude-answers "the old client: its list keeps the keys, the session's input is not in front"; return 0
  fi
  deadline=$((SECONDS + STEP_SECS)); st='wait'
  while :; do
    keep_sudo
    st=$(screen | answer_state "$ANSWER_WORD")
    case "$st" in up|bad) break ;; esac
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$POLL"
  done
  if [ "$st" = up ]; then
    shot answer-up
    keys -l "$ANSWER_ASK"; sleep 1; keys Enter
    deadline=$((SECONDS + ${FLEET_DRILL_AGENT_SECS:-300}))
    while :; do
      keep_sudo
      st=$(screen | answer_state "$ANSWER_WORD")
      case "$st" in answered|bad) break ;; esac
      [ "$SECONDS" -lt "$deadline" ] || break
      sleep "$POLL"
    done
  fi
  shot answer
  case "$st" in
    answered)
      row "会话里问一句「${ANSWER_ASK}」，claude 答 ${ANSWER_WORD}" "敲一句，回车" 否
      pass claude-answers "claude answered in the first session: $(screen | grep -E '^[[:space:]]*(│[[:space:]]*)?⏺' | grep -F -- "$ANSWER_WORD" | head -n 1 | sed 's/^[[:space:]]*//') · $(elapsed)" ;;
    bad)
      said=$(screen | answer_bad_line)
      row "claude 不答：$said" "敲一句，回车" "是 — 会话开了，claude 答不了：$said"
      failstep claude-answers "claude cannot answer: \"$said\""; return 1 ;;
    up)
      row "问了「${ANSWER_ASK}」，${FLEET_DRILL_AGENT_SECS:-300}s 内 claude 没答" "敲一句，回车" "是 — claude 没答"
      failstep claude-answers "no reply carrying $ANSWER_WORD within ${FLEET_DRILL_AGENT_SECS:-300}s:"; tail_pane; return 1 ;;
    *)
      row "会话里 ${STEP_SECS}s 没出现 claude 的输入框" "等" "是 — 会话里没有 claude"
      failstep claude-answers "claude's prompt did not come up within ${STEP_SECS}s:"; tail_pane; return 1 ;;
  esac
}

# --- 9 attach-attachment ---------------------------------------------------------------
# A task with a screenshot (EPIC #2482 C1, #2393): an image on the colleague's
# computer, its path dropped into the writing area with a question about it;
# the session — wherever the hub put it — must get the FILE (its text shows the
# path on the session's machine, $FLEET_CONF_DIR/attachments/<id>/<name>) and
# answer what the image shows. The image is one solid red square: 红 / red is
# the answer, and nothing typed says it.
ATTACH_FILE=drill-shot.png
ATTACH_ASK='看图 这张图是什么颜色？只回答一个颜色词'
RESUME_NAME='' RESUME_MARK=''
attach_keys() {
  if [ "$THINC" = 1 ]; then printf '⌘P，敲「看图」，⚡ 回车；会话里问一句、拖进截图，回车'
  else printf 'prefix c 新任务，拖进截图、问一句，回车'; fi
}
step_attach() {
  local f="$H/$ATTACH_FILE" png="$RUN/$ATTACH_FILE" st deadline k said
  drill_png "$png" || { failstep attach-attachment "cannot write the test image"; return 1; }
  ( cd / && sudo -n install -o "$LOGIN" -g staff -m 644 "$png" "$f" ) >> "$RUN/open.log" 2>&1 \
    || { failstep attach-attachment "cannot hand the test image to $LOGIN: $(tail -n 1 "$RUN/open.log")"; return 1; }
  if thin_is; then
    # the thin client (issue #3445): the panel opens the session (its words 看图),
    # then the question and the file go into it — the file dropped, a bracketed
    # paste of its path, which the thin loop carries to the home (fleet-thin.py's
    # Rewriter → fleet-client-upload.py) and pastes as the path there
    place_wait 看图 看图 attach
  else
    place_wait "$ATTACH_ASK $f" 看图 attach
  fi
  k=$PW_K
  case "$k" in
    row) : ;;
    no)  shot attach-refused
         said=$PW_SAID
         row "提示：$said" "$(attach_keys)" "是 — 带图的任务开不出会话：$said"
         failstep attach-attachment "the list refused the task with a screenshot: $said"; return 1 ;;
    *)   shot attach-none
         row "带图的任务回车后没有新行" "$(attach_keys)" "是 — 带图的任务开不出会话"
         failstep attach-attachment "no row 看图 within ${STEP_SECS}s:"; tail_pane; return 1 ;;
  esac
  RESUME_NAME=看图
  [ "$PW_ANSWERED" = 0 ] || row "问题（选仓库 / 开在哪）×$PW_ANSWERED" "回车（默认，自动）" 否
  shot attach-row
  if [ "$THINC" = 1 ]; then
    deadline=$((SECONDS + STEP_SECS))
    until [ "$(screen | answer_state 红)" = up ] || [ "$SECONDS" -ge "$deadline" ]; do sleep "$POLL"; done
    keys -l "$ATTACH_ASK "
    # shellcheck disable=SC2046  # one hex byte a word
    keys -H 1b 5b 32 30 30 7e $(hexof "$f") 1b 5b 32 30 31 7e
    sleep 3; keys Enter
  fi
  deadline=$((SECONDS + ${FLEET_DRILL_AGENT_SECS:-300}))
  while :; do
    keep_sudo
    st=$(pane | attach_state)
    case "$st" in lost|answered) break ;; esac
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep "$POLL"
  done
  shot attach
  case "$st" in
    answered)
      RESUME_MARK='/attachments/'
      row "会话里：图在会话那台机器上（…/attachments/…/${ATTACH_FILE}），回答「$(pane | attach_answer)」" "等" 否
      pass attach-attachment "the screenshot went with the task: the session read it on its machine and said $(pane | attach_answer) · $(elapsed)" ;;
    lost)
      said=$(pane | grep -Eo '附件没带过去[^│]*' | head -n 1 | sed 's/ *$//')
      row "提示：$said" "等" "是 — 截图没带到会话那台机器"
      failstep attach-attachment "the screenshot did not go: $said"; return 1 ;;
    path)
      RESUME_MARK='/attachments/'
      row "会话里有图的路径，但没说出图里是什么" "等" "是 — 会话没读图"
      failstep attach-attachment "the file reached the session's machine, but no answer within ${FLEET_DRILL_AGENT_SECS:-300}s:"; tail_pane; return 1 ;;
    *)
      row "会话里没有这张图（没有会话那台机器上的路径）" "等" "是 — 截图没带到会话那台机器"
      failstep attach-attachment "no path on the session's machine within ${FLEET_DRILL_AGENT_SECS:-300}s:"; tail_pane; return 1 ;;
  esac
}

# --- 10 node-restart-resume -------------------------------------------------------------
# The session's machine restarts its tmux server (EPIC #2482 C5, #2484) the way
# an update does it: `fleet-sessions-snapshot.sh save`, kill-server, `restore`,
# as the login that runs the session, demoted exactly like fleet-node-update.py.
# The client must come back on the SAME session: restore says `back` for it,
# `fleet ls` still has its key, and the right pane shows its text again. Only
# a session on THIS machine can be restarted from here — elsewhere is a FAIL
# that says so (the drill runs on the machine the hub places on, m4).
SL='' SLH='' SFLEET='' SKEY='' SNODE='' SFID='' SFID_K=''
# as_sess <cmd…>: run as the session's login, its own HOME / conf dir / TMPDIR
as_sess() {
  ( cd / && sudo -n -u "$SL" -H env -i HOME="$SLH" USER="$SL" LOGNAME="$SL" LANG=en_US.UTF-8 \
      PATH="$SLH/.claude/fleet/tools/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      FLEET_CONF_DIR="$SLH/.config/claude-fleet" \
      /bin/sh -c 'TMPDIR="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; [ -n "$TMPDIR" ] || TMPDIR="/tmp/claude-fleet-$(id -u)"; export TMPDIR; exec "$@"' \
      fleet-sessions "$@" )
}
# locate <row name>: SKEY off the client's own list (`fleet ls --json`); SL ·
# SLH · SFLEET = the login of this machine, and its fleet, whose tmux holds the
# window with that row's @fleet_id (never a guess by name)
locate() {
  local r fid d s
  r=$(as_login "$H/.local/bin/fleet" ls --json 2>"$RUN/ls.err" | tee "$RUN/ls.json" | ls_row "$1")
  [ -n "$r" ] || { printf 'no row %s in `fleet ls --json` (%s)' "$1" "$(head -c 160 "$RUN/ls.err")"; return 1; }
  SKEY=$(printf '%s' "$r" | cut -f2) fid=$(printf '%s' "$r" | cut -f3); SFID_K=$fid
  # an own row of the home (`@7`, issue #3467) is as good as a wid: key — only a
  # row with no @fleet_id at all (a fleet ls older than #3467) cannot be found
  [ "$fid" != - ] || { printf '%s (%s) has no @fleet_id in `fleet ls --json` — cannot find its window (fleet ls older than #3467?)' "$1" "$SKEY"; return 1; }
  for d in "$HOMES"/*; do
    [ -d "$d" ] && [ "$d" != "$H" ] || continue
    for s in $( ( cd / && sudo -n ls "$d/.config/claude-fleet/fleets" ) 2>/dev/null); do
      SL=$(basename "$d") SLH=$d
      if as_sess "$TMUXB" -L "$s" list-windows -a -F '#{@fleet_id}' 2>/dev/null | grep -qxF -- "$fid"; then  # view-ok: presence test as another login (no fleet-lib); a view session's duplicate row is harmless
        SFLEET=$s; return 0
      fi
    done
  done
  SL='' SLH=''
  # another machine's (issue #3432 — --home mini2 / fleet-linux-0): restarted
  # there, as the session's own login, over that login's client
  SNODE=$(printf '%s' "$r" | cut -f1) SFID=$fid
  if [ "$SNODE" != - ] && ! same_machine "$SNODE" "$(hostname -s 2>/dev/null || hostname)"; then
    return 0
  fi
  SNODE=''
  printf '%s (@fleet_id %s) runs on %s — no login of this machine has it' "$1" "$fid" "$(printf '%s' "$r" | cut -f1)"
  return 1
}
# The restart on another machine, as the session's login there (issue #3432):
# ONE line in that login's shell over its own client's ssh (fleet-thin.py --run
# --home <machine>), never an admin's. `save <fid>`: the fleet holding the window
# with that @fleet_id, its pin (fleet-sessions-snapshot.sh save), then its tmux
# server killed — the update's own order; `restore <fleet>`: the pinned sessions
# back. FLEET_ALLOW_TMUX_DESTROY: this kill-server is the drill's deliberate one.
REMOTE_RESTART='op=$1 arg=$2
export FLEET_ALLOW_TMUX_DESTROY=1
PATH="$HOME/.claude/fleet/tools/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
B="$HOME/.claude/fleet/bin" C="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
[ -f "$B/fleet-sessions-snapshot.sh" ] || { echo "no fleet-sessions-snapshot.sh in $B"; exit 4; }
case $op in
  save)
    S=
    for d in "$C"/fleets/*/; do
      s=$(basename "$d")
      tmux -L "$s" list-windows -a -F "#{@fleet_id}" 2>/dev/null | grep -qxF -- "$arg" && { S=$s; break; }  # view-ok: a presence test in the remote login shell (no fleet-lib there), a view session duplicate row is harmless
    done
    [ -n "$S" ] || { echo "no fleet of $(id -un) has @fleet_id $arg"; exit 4; }
    printf "fleet\t%s\n" "$S"
    bash "$B/fleet-sessions-snapshot.sh" save 2>&1 || exit 5
    tmux -L "$S" kill-server >/dev/null 2>&1; exit 0 ;;
  restore) exec bash "$B/fleet-sessions-snapshot.sh" restore 2>&1 ;;
esac
echo "unknown op $op"; exit 2'
THIN="${FLEET_DRILL_THIN:-$H/.local/share/claude-fleet/bin/fleet-thin.py}"   # the env is the selftest's seam
# remote <op> <arg>: REMOTE_RESTART on $SNODE as the login, its output
remote() { as_login python3 "$THIN" --run --home "$SNODE" -- sh -c "$REMOTE_RESTART" fleet-drill-restart "$1" "$2" 2>&1; }
RESTART_DOWN='机器在重启|稍等|restarting|connection lost|连接断了|没有活着的'
# restart_back: the client is back on the session — the old client's list row
# and the session's text; the thin client (issue #3445: no list) the 看台 itself,
# the VISIBLE screen no longer saying it is down and showing the session's text
restart_back() {
  local v
  if [ "$THINC" = 1 ]; then
    v=$(screen)
    [ -n "$(printf '%s' "$v" | tr -d '[:space:]')" ] && ! printf '%s\n' "$v" | grep -Eq -- "$RESTART_DOWN" \
      && { [ -z "$RESUME_MARK" ] || printf '%s\n' "$v" | grep -qF -- "$RESUME_MARK"; }
  else
    [ -n "$(row_named "$RESUME_NAME")" ] && ! pane | grep -Eq -- "$RESTART_DOWN" \
      && { [ -z "$RESUME_MARK" ] || pane | grep -qF -- "$RESUME_MARK"; }
  fi
}
step_restart() {
  local bin out deadline k back
  [ -n "$RESUME_NAME" ] || RESUME_NAME=$NAME
  # locate's answer is its variables, so it runs here, its words captured apart
  locate "$RESUME_NAME" > "$RUN/locate.txt" || { failstep node-restart-resume "$(cat "$RUN/locate.txt")"; return 1; }
  if [ -n "$SNODE" ]; then
    # another machine (issue #3432): save + kill there, as the session's login
    SL=$LOGIN
    out=$(remote save "$SFID"); printf '%s\n' "$out" > "$RUN/restart-save.txt"
    SFLEET=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "fleet" {print $2; exit}')
    out=$(printf '%s\n' "$out" | awk -F'\t' '$1 != "fleet"')
    printf '%s\n' "$out" | grep -q '^saved ' \
      || { failstep node-restart-resume "snapshot save as $SL on $SNODE: $(printf '%s' "$out" | tail -n 1)"; return 1; }
    note "$SL@$SNODE ($SFLEET): $(printf '%s\n' "$out" | grep '^saved ' | tail -n 1)"
  else
    bin="${FLEET_DRILL_NODE_BIN:-$SLH/.claude/fleet/bin}"
    ( cd / && sudo -n test -x "$bin/fleet-sessions-snapshot.sh" ) 2>/dev/null \
      || { failstep node-restart-resume "no fleet-sessions-snapshot.sh in $bin ($SL's runtime)"; return 1; }
    out=$(as_sess /bin/bash "$bin/fleet-sessions-snapshot.sh" save 2>&1); printf '%s\n' "$out" > "$RUN/restart-save.txt"
    printf '%s\n' "$out" | grep -q '^saved ' \
      || { failstep node-restart-resume "snapshot save as $SL: $(printf '%s' "$out" | tail -n 1)"; return 1; }
    note "$SL: $(printf '%s\n' "$out" | grep '^saved ' | tail -n 1)"
    as_sess "$TMUXB" -L "$SFLEET" kill-server > "$RUN/restart-kill.txt" 2>&1 || :
  fi
  # the client sees it go (fleet-remote-view.sh run says the machine is restarting)
  wait_for 30 "$RESTART_DOWN" >/dev/null; shot restart-down
  if [ -n "$SNODE" ]; then out=$(remote restore -)
  else out=$(as_sess /bin/bash "$bin/fleet-sessions-snapshot.sh" restore 2>&1); fi
  printf '%s\n' "$out" > "$RUN/restart-restore.txt"
  back=$(printf '%s\n' "$out" | awk -F'\t' -v s="$SFLEET" '$1 == "back" && $2 == s' | grep -c .)
  if [ "$back" = 0 ] || printf '%s\n' "$out" | awk -F'\t' -v s="$SFLEET" '$2 == s && $1 != "back"' | grep -q .; then
    shot restart-restore
    row "机器 tmux 重启后：会话没回来（$(printf '%s\n' "$out" | awk -F'\t' -v s="$SFLEET" '$2 == s {print $1}' | sort -u | tr '\n' ' ')）" "等" "是 — 重启后会话没了"
    failstep node-restart-resume "restore as $SL did not bring $SFLEET back:"; printf '%s\n' "$out" | tail -n 6 | sed 's/^/        │ /'; return 1
  fi
  deadline=$((SECONDS + STEP_SECS)); k=''
  while [ "$SECONDS" -lt "$deadline" ]; do
    keep_sudo
    if restart_back; then k=back; break; fi
    sleep "$POLL"
  done
  shot restart-back
  if [ "$k" != back ]; then
    row "机器 tmux 重启后：客户端没回到 $RESUME_NAME" "等" "是 — 重启后要重新打开会话"
    failstep node-restart-resume "the client did not come back on $RESUME_NAME within ${STEP_SECS}s:"; tail_pane; return 1
  fi
  # the same session = the same @fleet_id: an own row's key is a window id, which
  # a restored server hands out afresh (issue #3467)
  if ! as_login "$H/.local/bin/fleet" ls --json 2>/dev/null | ls_row "$RESUME_NAME" | cut -f3 | grep -qxF -- "$SFID_K"; then
    row "机器 tmux 重启后：列表里 $RESUME_NAME 换了一个" "等" "是 — 回来的不是同一个会话"
    failstep node-restart-resume "$RESUME_NAME came back as another session (was $SKEY, @fleet_id $SFID_K)"; return 1
  fi
  row "会话那台机器${SNODE:+ $SNODE} tmux 重启（save · kill-server · restore）：右边回到 ${RESUME_NAME}，还是同一个会话" "等" 否
  pass node-restart-resume "$SL's tmux${SNODE:+ on $SNODE} restarted: $back session(s) back, the client on $RESUME_NAME ($SKEY) again · $(elapsed)"
}

# --- every machine the login was put on (issue #3471) -----------------------------
# Drill 33's login stayed on mini2 (its --home) while steps 11–12 read PASS: both
# looked at this machine only. Now the machines are the run's --home plus every
# machine the hub's roster lists a login of that name on (GET /v1/fleet/accounts,
# the operator's token); step 11 has the hub close each one and step 12 looks
# at each one itself.
THIS_M=$(hostname -s 2>/dev/null || hostname)
# hub_auth <method> <path> [json]: as hub_json, with the operator's token
hub_auth() {
  local out code
  out=$(mktemp "$RUN/hub.XXXXXX") || return 1
  code=$(printf '%s' "${3:-}" | curl -sS --max-time 20 -o "$out" -w '%{http_code}' -X "$1" \
         -H "Authorization: Bearer $VIEWER" -H 'Content-Type: application/json' \
         $([ -n "${3:-}" ] && printf -- '--data-binary @-') "$HUB$2" 2>/dev/null)
  cat "$out"; rm -f "$out"
  printf '\n%s' "$code"
}
# hub_roster: the hub's rows for a login named $LOGIN on another machine, one
# per line — host · state · principal · detail; rc 1 = no token, or no answer
hub_roster() {
  local resp
  [ -n "$VIEWER" ] || return 1
  resp=$(hub_auth GET /v1/fleet/accounts)
  [ "$(hub_code "$resp")" = 200 ] || return 1
  hub_body "$resp" > "$RUN/hub-accounts.json"
  python3 -c '
import json, sys
login, me = sys.argv[1], sys.argv[2].split(".")[0].lower()
d = json.load(open(sys.argv[3]))
for a in (d.get("accounts") or []) + (d.get("spares") or []):
    h = a.get("hostname") or ""
    if a.get("login") != login or a.get("op") == "login" or h.split(".")[0].lower() == me:
        continue
    print("\t".join([h, a.get("state") or "", a.get("principal_id") or "", " ".join((a.get("detail") or "").split())[:200]]))
' "$LOGIN" "$THIS_M" "$RUN/hub-accounts.json"
}
# other_machines: --home, then the roster's, one per line, once each (the roster
# read leaves $RUN/hub-accounts.json behind: that is how a caller tells it was read)
other_machines() {
  local rows
  rows=$(hub_roster) || rows=''
  { [ -z "$HOME_M" ] || same_machine "$HOME_M" "$THIS_M" || printf '%s\n' "$HOME_M"
    printf '%s\n' "$rows" | cut -f1; } | awk 'NF && !seen[tolower($0)]++'
}
# The residue on another machine, read-only and as nobody in particular (no
# sudo there): the record, the home, the processes, every access and share
# group naming the login. `probe-ok` last = the machine was read.
RESIDUE_PROBE='L=$1
u=$(id -u "$L" 2>/dev/null) && echo "left: login record (uid $u)"
if command -v dscl >/dev/null 2>&1; then
  [ -n "$u" ] || ! dscl . -read "/Users/$L" UniqueID >/dev/null 2>&1 || echo "left: directory record /Users/$L"
  [ ! -e "/Users/$L" ] || echo "left: home /Users/$L"
  for g in $(dscl . -list /Groups 2>/dev/null | grep -E "^com[.]apple[.](access_|sharepoint[.]group[.])"); do
    dscl . -read "/Groups/$g" GroupMembership 2>/dev/null | tr " " "\n" | grep -Fxq -- "$L" && echo "left: $g lists $L"
  done
else
  [ ! -e "/home/$L" ] || echo "left: home /home/$L"
fi
if [ -n "$u" ]; then n=$(ps -axo uid= 2>/dev/null | awk -v u="$u" "\$1 == u" | wc -l | tr -d " ")
else n=$(ps -axo user= 2>/dev/null | awk -v l="$L" "\$1 == l" | wc -l | tr -d " "); fi
[ "$n" = 0 ] || echo "left: $n process(es) of $L"
echo probe-ok'
# home_probe <machine>: what is left of $LOGIN there, one per line; rc 1 = the
# machine could not be read (said on stdout) — never taken for clean. The way in
# is the hub's five-minute certificate (fleet-peer-cert.sh), else plain ssh;
# FLEET_DRILL_HOME_SSH <machine> <cmd…> is the selftest's seam.
home_probe() {
  local m=$1 out o rc opts=()
  if [ -n "${FLEET_DRILL_HOME_SSH:-}" ]; then
    out=$(printf '%s\n' "$RESIDUE_PROBE" | sh -c "$FLEET_DRILL_HOME_SSH \"\$@\"" _ "$m" sh -s -- "$LOGIN" 2>&1)
  else
    o=$(bash "$BIN/fleet-peer-cert.sh" "$m" view 2>"$RUN/peer-cert-$m.err"); rc=$?
    case $rc in
      0) while IFS= read -r x; do [ -z "$x" ] || opts+=("$x"); done <<EOF
$o
EOF
         ;;
      3) ;;
      *) printf 'could not read %s: no way in (%s)' "$m" "$(tail -n 1 "$RUN/peer-cert-$m.err")"; return 1 ;;
    esac
    out=$(printf '%s\n' "$RESIDUE_PROBE" | ssh -o BatchMode=yes -o ConnectTimeout=15 ${opts[@]+"${opts[@]}"} "$m" sh -s -- "$LOGIN" 2>&1)
  fi
  printf '%s\n' "$out" > "$RUN/residue-$m.txt"
  if ! printf '%s\n' "$out" | grep -qx 'probe-ok'; then
    printf 'could not read %s: %s' "$m" "$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1 | head -c 160)"
    return 1
  fi
  printf '%s\n' "$out" | sed -n 's/^left: //p'
}
# close_remote: step 11 on the other machines — the operator's remove on every
# roster row still holding the login there (the drill person's self-delete has
# already asked for its own), then the roster read until each is removed or
# gone, FLEET_DRILL_REMOVE_SECS. Prints what stayed (login@host state: detail).
close_remote() {
  local rows t0 h st pid det body
  rows=$(hub_roster) || return 0
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r h st pid det; do
    [ -n "$h" ] || continue
    case "$st" in active|failed|unknown)
      body=$(python3 -c 'import json,sys; print(json.dumps({"action":"remove","principal_id":sys.argv[1],"hostname":sys.argv[2]}))' "$pid" "$h")
      # to stderr: this function's stdout is what stayed
      note "asked the hub to close $LOGIN@$h ($st): HTTP $(hub_code "$(hub_auth POST /v1/fleet/accounts "$body")")" >&2 ;;
    esac
  done
  t0=$SECONDS
  while :; do
    rows=$(hub_roster | awk -F'\t' '$2 != "removed"') || rows=''
    [ -n "$rows" ] && [ $((SECONDS - t0)) -lt "$REMOVE_SECS" ] || break
    keep_sudo; sleep "$POLL"
  done
  printf '%s\n' "$rows" | awk -F'\t' -v l="$LOGIN" 'NF {printf " · %s@%s still %s%s", l, $1, $2, ($4 != "" ? ": " $4 : "")}'
}

# --- 11 offboard ---------------------------------------------------------------------
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
  local t0=$SECONDS
  resp=$(hub_json DELETE /v1/self "$(printf '{"approve_code":"%s"}' "$INVITE")")
  # 202 removing: the hub is closing the login it opened for the drill
  # person's first session (#2549) — the person goes once that is gone.
  # Closing a login takes minutes (C9 run 2: still 「removing」 after 120 s).
  while [ "$(hub_code "$resp")" = 202 ] && [ $((SECONDS - t0)) -lt "$REMOVE_SECS" ]; do
    sleep "$POLL"
    resp=$(hub_json DELETE /v1/self "$(printf '{"approve_code":"%s"}' "$INVITE")")
  done
  if [ "$(hub_code "$resp")" = 200 ]; then printf 'by the approve code: %s' "$(hub_body "$resp")"; return 0; fi
  printf 'HTTP %s %s' "$(hub_code "$resp")" "$(hub_body "$resp" | head -c 200)"
  return 1
}
step_offboard() {
  local fp rc warn='' out remote_left
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
  if id "$LOGIN" >/dev/null 2>&1 || [ -e "$H" ]; then
    ( cd "$HOME" && bash "$RM_SH" "$LOGIN" --delete-home --apply ) > "$RUN/login-remove.log" 2>&1; rc=$?
  else
    printf 'no login %s on this machine (%s): nothing to remove here\n' "$LOGIN" "$THIS_M" > "$RUN/login-remove.log"; rc=0
  fi
  # the other machines (issue #3471): the hub closes the login it put there
  remote_left=$(close_remote)
  if [ -z "$VIEWER" ] && [ -n "$HOME_M" ] && [ -z "$INVITE" ]; then
    warn="$warn · no operator token: the hub was not asked to close $LOGIN on $HOME_M (CCQUOTA_VIEWER_TOKEN, or --invite <code>)"
  fi
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
    failstep offboard "fleet-login-remove.sh $LOGIN --delete-home --apply: exit $rc — $(tail -n 1 "$RUN/login-remove.log")$warn$remote_left"
    return 1
  fi
  if [ -n "$remote_left" ]; then
    failstep offboard "the hub did not close $LOGIN everywhere within ${REMOVE_SECS}s:$remote_left$warn"
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

# --- 12 residue ---------------------------------------------------------------------
step_residue() {
  local left='' g n st
  id "$LOGIN" >/dev/null 2>&1 && left="$left · login record"
  if [ -s "$RUN/users-before.txt" ]; then
    # the hub takes the login it opened for the drill person off on its own
    # once the person is gone — give it STEP_SECS, then name what stayed
    local deadline=$((SECONDS + STEP_SECS)) extra
    while :; do
      extra=$(dscl . -list /Users 2>/dev/null | sort | comm -13 "$RUN/users-before.txt" - | grep -vxF -- "$LOGIN" | tr '\n' ' ' | sed 's/ *$//')
      [ -n "$extra" ] && [ "$SECONDS" -lt "$deadline" ] || break
      keep_sudo; sleep "$POLL"
    done
    [ -z "$extra" ] || left="$left · login(s) made during the run: $extra"
  fi
  [ ! -e "$H" ] || left="$left · home $H"
  if [ -n "$UIDN" ]; then
    n=$(ps -axo uid= 2>/dev/null | awk -v u="$UIDN" '$1 == u' | grep -c .)
    [ "$n" = 0 ] || left="$left · $n process(es) of uid $UIDN"
  fi
  for g in $(dscl . -list /Groups 2>/dev/null | grep -E '^com\.apple\.(access_|sharepoint\.group\.)' || :); do
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
    local t0=$SECONDS
    resp=$(hub_json DELETE /v1/self "$(printf '{"approve_code":"%s"}' "$INVITE")")
    # still 202 removing: the hub is closing its login — wait it out, then read
    while [ "$(hub_code "$resp")" = 202 ] && [ $((SECONDS - t0)) -lt "$REMOVE_SECS" ]; do
      keep_sudo; sleep "$POLL"
      resp=$(hub_json DELETE /v1/self "$(printf '{"approve_code":"%s"}' "$INVITE")")
    done
    printf 'DELETE %s/v1/self (approve code) → HTTP %s %s\n' "$HUB" "$(hub_code "$resp")" "$(hub_body "$resp")" > "$RUN/hub-residue.txt"
    case "$(hub_code "$resp")" in
      401) note "hub: $(hub_body "$resp" | head -c 120) — the drill person is gone" ;;
      200) left="$left · the drill person was still on the hub (deleted by this check)" ;;
      202) left="$left · the hub was still closing the drill person's login after ${REMOVE_SECS}s: $(hub_body "$resp" | head -c 160)" ;;
      *)   left="$left · the hub's answer on the drill person: HTTP $(hub_code "$resp")" ;;
    esac
  fi
  # every other machine the login was put on (issue #3471): looked at, never assumed
  local m ms seen='' got
  rm -f "$RUN/hub-accounts.json"
  ms=$(other_machines)
  for m in $ms; do
    if got=$(home_probe "$m"); then
      [ -z "$got" ] || left="$left$(printf '%s\n' "$got" | sed "s/^/ · on $m: /" | tr -d '\n')"
      seen="$seen $m"
    else
      left="$left · $got"
    fi
  done
  [ -s "$RUN/hub-accounts.json" ] || note "the hub's roster was not read (no operator token, or no answer) — machines checked: $THIS_M${seen}"
  if [ -z "$left" ]; then
    pass residue "none on $THIS_M${seen}: no login, no home, no process, no access- or share-group entry$([ -n "$FPR" ] && [ -n "$VIEWER" ] && printf ', device revoked')$([ -n "$INVITE" ] && printf ', no drill person on the hub')"
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
  elif id "$LOGIN" >/dev/null 2>&1 || [ -e "$H" ] || [ -n "$HOME_M" ]; then
    step_offboard || :
    step_residue || :
  else
    kill_own_tmux
    skip offboard "login $LOGIN was never created — nothing to remove"
  fi
  rm -f "$RUN/id_ed25519" "$RUN/id_ed25519.pub"
  printf '\n'
  # an interrupted run is no verdict (#2865): never PASS, the reading gives no number
  if [ -n "$ABORTED" ]; then
    printf '%s: ABORTED (%s)  %d passed · %d failed · %d skipped · %s · log %s\n' "$PROG" "$ABORTED" "$NPASS" "$NFAIL" "$NSKIP" "$(elapsed)" "$RUN"
  elif [ "$NFAIL" = 0 ]; then
    printf '%s: PASS  %d passed · %d skipped · %s · log %s\n' "$PROG" "$NPASS" "$NSKIP" "$(elapsed)" "$RUN"
  else
    printf '%s: FAIL  %d passed · %d failed · %d skipped · %s · log %s\n' "$PROG" "$NPASS" "$NFAIL" "$NSKIP" "$(elapsed)" "$RUN"
  fi
  if [ "$TEARDOWN" = 0 ]; then
    if [ -n "$ABORTED" ]; then
      printf '\nreading (EPIC #1906): 不出数 — the drill was interrupted (%s) before its steps finished\n' "$ABORTED"
    else
      printf '\nreading (EPIC #1906): 同事从拿到命令到开出第一个会话要人帮的步骤: %s\n' "$NHELP"
    fi
    printf 'steps (%s, %s screens beside it):\n' "$STEPS" "$NSHOT"
    sed 's/^/  /' "$STEPS"
  fi
  [ -z "$ABORTED" ] || exit "$ABORT_RC"
  [ "$NFAIL" = 0 ] && exit 0
  exit 1
}
# on_signal <SIG> <rc>: a signal mid-finish (the teardown) marks the run too —
# the finish already under way prints the verdict when it resumes
on_signal() {
  trap - INT TERM HUP
  ABORTED="interrupted by SIG$1" ABORT_RC=$2
  printf '\n%s: interrupted (SIG%s) — tearing down\n' "$PROG" "$1" >&2
  finish
}
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM
trap 'on_signal HUP 129' HUP
# a step that dies (set -u, a typo) still tears the login down: finish is idempotent
trap '[ "$SUMMARISED" = 1 ] || { ABORTED="a step died"; printf "\\n%s: a step died — tearing down\\n" "$PROG" >&2; finish; }' EXIT

if [ "$TEARDOWN" = 1 ]; then
  UIDN=$(id -u "$LOGIN" 2>/dev/null || :)
  GUID=$(dscl . -read "/Users/$LOGIN" GeneratedUID 2>/dev/null | awk '$1=="GeneratedUID:" {print $2; exit}')
  finish
fi
if [ -n "$ONLY" ]; then
  # the seam (FLEET_DRILL_ONLY=8-10): the client is up on the test's tmux server
  TMUX_UP=0 SUMMARISED=1
  if [ "$ONLY" = 8 ]; then step_scratch && { step_answer || :; }
  else step_scratch && { step_answer || :; step_attach || :; step_restart || :; }; fi
  printf '\n%s: %s  %d passed · %d failed · steps %s only (FLEET_DRILL_ONLY) · log %s\n' "$PROG" \
    "$([ "$NFAIL" = 0 ] && echo PASS || echo FAIL)" "$NPASS" "$NFAIL" "$ONLY" "$RUN"
  sed 's/^/  /' "$STEPS"
  [ "$NFAIL" = 0 ]; exit
fi
step_open || finish
step_ssh || finish
step_install || finish
step_scan || finish
step_client || finish
step_scratch && { step_answer || :; step_attach || :; step_restart || :; }
finish
