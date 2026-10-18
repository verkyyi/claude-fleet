#!/bin/bash
# fleet-login-ready.sh <login> --home <dir> [--root <dir>] [--wait <secs>]
#   — a login is ready only once it really works (issue #4673, EPIC #4667 C6).
#
# fleet-login-new.sh runs it ONCE, at the end of a login the hub opened or washed
# (never on a clock): three steps AS THE LOGIN, each stamped with the epoch second
# it passed, the way the person's first session will take them —
#
#   cred   fleet-session-cred.sh mint --provider claude --sid <probe>: a session
#          credential from the machine's proxy (the road every session takes);
#          revoked at the end
#   home   the login's fleet has a home window (fleet_sockets, a window whose
#          @fleet_role or name is home) — polled up to --wait, because a wash
#          starts its fleet detached (fleet-login-new.sh fleet_up_step)
#   reply  `claude -p` one minimal request through that credential (fleet-claude.sh's
#          wiring: ANTHROPIC_BASE_URL + CLAUDE_CODE_OAUTH_TOKEN) answers, non-empty
#
# One line on stdout — the line the hub reads (the agent's readyResult):
#   ready: cred_ok=<s> home_ok=<s> first_reply_ok=<s>
#   ready: FAIL <cred|home|reply>: <why>[ cred_ok=<s>][ home_ok=<s>]
# A step that failed stops the rest: the hub hands no such login out and keeps why.
#
# As root it runs each step `sudo -n -u <login> -H`; run by the login itself, bare.
# --root is the login's install (default: this script's own); its bin/ is used.
# Env: FLEET_LOGIN_READY_WAIT (300 s, --wait's default) · FLEET_LOGIN_READY_REPLY_SECS
#      (120 s, the request's bound) · FLEET_CLAUDE_BIN (the claude to run)
# Exit: 0 all three · 1 a step failed · 2 usage
set -u

PROG=fleet-login-ready
LOGIN='' H='' ROOT='' WAIT=${FLEET_LOGIN_READY_WAIT:-300}
REPLY_SECS=${FLEET_LOGIN_READY_REPLY_SECS:-120}
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --home) H=${2:-}; shift 2 ;;
    --root) ROOT=${2:-}; shift 2 ;;
    --wait) WAIT=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die2 "unknown option $1" ;;
    *) [ -z "$LOGIN" ] || die2 "one login only"; LOGIN=$1; shift ;;
  esac
done
[ -n "$LOGIN" ] || die2 'usage: fleet-login-ready.sh <login> --home <dir> [--root <dir>] [--wait <secs>]'
printf '%s' "$LOGIN" | grep -Eq '^[a-z0-9_][a-z0-9_-]{0,31}$' || die2 "bad login name '$LOGIN'"
case "$H" in /*) ;; *) die2 "--home is the login's home, an absolute path" ;; esac
case "$WAIT" in ''|*[!0-9]*) die2 "--wait is whole seconds" ;; esac
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CD="$H/.config/claude-fleet"
BPATH="$H/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

as_login() { # <cmd…> — the command as the login, its own HOME / conf / PATH
  if [ "$LOGIN" = "$(id -un)" ]; then
    env HOME="$H" FLEET_CONF_DIR="$CD" PATH="$BPATH" "$@"
  else
    sudo -n -u "$LOGIN" -H env FLEET_CONF_DIR="$CD" PATH="$BPATH" "$@"
  fi
}
oneline() { tr '\n\t' '  ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-200; }
STAMPS=''
fail() { printf 'ready: FAIL %s: %s%s\n' "$1" "$2" "$STAMPS"; exit 1; }

SID="ready-$$-$(date +%s)"
CRED=''
# shellcheck disable=SC2329 # run by the EXIT trap
revoke() { [ -z "$CRED" ] || as_login bash "$ROOT/bin/fleet-session-cred.sh" revoke --sid "$SID" >/dev/null 2>&1 || :; }
trap revoke EXIT

# 1 cred — the proxy hands this login a session credential
out=$(as_login bash "$ROOT/bin/fleet-session-cred.sh" mint --provider claude --sid "$SID" 2>&1); rc=$?
[ "$rc" = 0 ] || fail cred "fleet-session-cred.sh mint exited $rc: $(printf '%s' "$out" | oneline)"
IFS=$'\t' read -r _route port CRED <<< "$out"
case "$port" in ''|*[!0-9]*) CRED=''; fail cred "the proxy answered no port: $(printf '%s' "$out" | cut -f1-2 | oneline)" ;; esac
[ -n "$CRED" ] || fail cred 'the proxy answered no session credential'
C_OK=$(date +%s); STAMPS=" cred_ok=$C_OK"

# 2 home — the login's fleet is up with its home window
# shellcheck disable=SC2016 # expanded by the inner bash, as the login
home_up() {
  as_login bash -c '. "$1/bin/fleet-lib.sh" >/dev/null 2>&1 || exit 1
    for s in $(fleet_sockets); do tmux -L "$s" list-windows -t "$s" -F "#{@fleet_role}|#{window_name}" 2>/dev/null; done' \
    _ "$ROOT" 2>/dev/null | grep -Eq '^home\||\|home$'
}
end=$(( $(date +%s) + WAIT ))
until home_up; do
  [ "$(date +%s)" -lt "$end" ] || fail home "no fleet with a home window after ${WAIT}s (fleet-login-bootstrap.sh: $CD/logs/bootstrap.log)"
  sleep 3
done
H_OK=$(date +%s); STAMPS="$STAMPS home_ok=$H_OK"

# 3 reply — one minimal request through that credential answers
claude=${FLEET_CLAUDE_BIN:-claude}
# shellcheck disable=SC2016 # expanded by the inner bash, as the login
out=$(printf '%s' "$CRED" | as_login bash -c 'IFS= read -r tok; export CLAUDE_CODE_OAUTH_TOKEN="$tok" ANTHROPIC_BASE_URL="http://127.0.0.1:$1" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  cd "$HOME" && exec perl -e "alarm shift; exec @ARGV" "$2" "$3" -p "Reply with the single word: ok" </dev/null' \
  _ "$port" "$REPLY_SECS" "$claude" 2>&1); rc=$?
[ "$rc" = 0 ] || fail reply "claude -p exited $rc: $(printf '%s' "$out" | oneline)"
[ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] || fail reply 'claude -p answered nothing'
printf 'ready: cred_ok=%s home_ok=%s first_reply_ok=%s\n' "$C_OK" "$H_OK" "$(date +%s)"
exit 0
