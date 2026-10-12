#!/bin/bash
# fleet-admin-gate.sh — the two scripts the admin role account may sudo (issue
# #3557, EPIC #3500 C15 · 共同约定 11).
#
# The machine's account ops move off the admin's own login onto _fleetadmin /
# fleetadmin, whose sudoers file names exactly two paths:
#
#   /var/db/fleet-node/admin/fleet-login-new.sh      (open a login)
#   /var/db/fleet-node/admin/fleet-login-remove.sh   (delete it; --recycle washes it)
#
# Both are THIS script, root-owned copies; which one it is decides the op. So
# sudo grants nothing but this check: it runs an op only with a ticket the hub
# signed for exactly that op, login and machine, unexpired and never used
# before (bin/fleet_admin_ticket.py spends its nonce), with exactly the argv the
# agent builds (tokenledger accountArgv) — no other flag reaches a root script:
#
#   fleet-login-new.sh    --ticket <t> <login> --full-name <name> --share-pool --apply
#   fleet-login-remove.sh --ticket <t> <login> [--recycle] --keep-home|--delete-home --apply
#
# Then it runs the release's own script of that name with the rest of the argv.
# A create that fails after its run made the login is rolled back HERE (#3696:
# the seat holds no remove ticket for it): when the login exists and its mark,
# <this dir>/<login>-onboard/op, names this op, the release's
# fleet-login-remove.sh <login> --keep-home --apply runs and one line says so;
# the exit stays the create's.
# Where things are comes from admin.conf BESIDE this copy (root's, like the
# copy: a caller can move neither), key=value lines, never sourced:
#
#   bin=<dir>       the release's bin/ (its fleet-login-*.sh, fleet_admin_ticket.py)
#   pub=<file>      the hub's account-op key, `ed25519 <b64>` (default <here>/account.pub)
#   used=<dir>      the spent-nonce book (default <here>/used)
#   machine=<name>  this machine as the hub names it (default: its hostname)
#   hub=<url>       the hub the release's script joins a new login to (#3696)
#
# The script runs with a clean environment the gate makes (#3696 — sudo resets
# the caller's anyway, and nothing a caller sets may reach a root script):
# FLEET_LOGIN_OP_ID = the ticket's nonce (the op's op_id, the mark it leaves),
# FLEET_LOGIN_HUB = admin.conf's hub=, FLEET_LOGIN_ADMIN_DIR = this directory
# (where a root run keeps <login>-onboard/), and for a create / a recycle
# FLEET_LOGIN_JOIN_CODE from the caller's stdin — at most one line
# `FLEET_LOGIN_JOIN_CODE=fj_<26 base32>`, anything else refused.
#
# Exit: 3 refused (one line why; nothing ran, nothing spent) · 2 usage ·
# else the script's own. BREAK-IT fleetadmin-forged-op
# (bin/fleet-break-it-admin-selftest.sh).
set -uo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
PROG=fleet-admin-gate
refuse() { printf '%s: refused: %s\n' "$PROG" "$1" >&2; exit 3; }
usage() { printf '%s: usage: %s --ticket <t> <args…>\n' "$PROG" "$NAME" >&2; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd -P) || refuse 'cannot resolve its own directory'
NAME=$(basename "$0")
case "$NAME" in
  fleet-login-new.sh) OP=create ;;
  fleet-login-remove.sh) OP=remove ;;
  *) refuse "installed as $NAME: only fleet-login-new.sh / fleet-login-remove.sh run an account op" ;;
esac

CONF="$HERE/admin.conf"
[ -f "$CONF" ] || refuse "no $CONF"
conf() { sed -n "s/^$1=//p" "$CONF" | tail -n 1; }
RBIN=$(conf bin)
PUB=$(conf pub); PUB=${PUB:-$HERE/account.pub}
USED=$(conf used); USED=${USED:-$HERE/used}
MACHINE=$(conf machine)
HUBURL=$(conf hub)
case "$RBIN" in /*) ;; *) refuse "admin.conf: bin= is not an absolute directory" ;; esac
[ -x "$RBIN/$NAME" ] && [ -f "$RBIN/fleet_admin_ticket.py" ] || refuse "admin.conf: no $NAME / fleet_admin_ticket.py in $RBIN"

[ "${1:-}" = --ticket ] && [ $# -ge 2 ] || usage
TICKET=$2
shift 2
LOGIN=${1:-}
[ -n "$LOGIN" ] || usage

# exactly accountArgv's shapes
args_ok() {
  if [ "$OP" = create ]; then
    [ $# = 5 ] && [ "$2" = --full-name ] && [ -n "$3" ] && [ "$4" = --share-pool ] && [ "$5" = --apply ]
    return
  fi
  shift
  if [ "${1:-}" = --recycle ]; then OP=reset; shift; fi
  [ $# = 2 ] && { [ "$1" = --keep-home ] || [ "$1" = --delete-home ]; } && [ "$2" = --apply ]
}
args_ok "$@" || refuse "$NAME takes exactly the agent's argv, not: $*"

MARGS=()
[ -z "$MACHINE" ] || MARGS=(--machine "$MACHINE")
case "$HUBURL" in ''|http://*|https://*) ;; *) refuse "admin.conf: hub= is not an http(s) address" ;; esac

# the join code: one line on stdin, read only for an op that opens a login (a
# person's terminal gives none in a second, and that is no code)
CODE=""
if [ "$OP" != remove ] && [ ! -t 0 ]; then
  line=""; IFS= read -r -t 5 line || true
  case "$line" in
    '') ;;
    FLEET_LOGIN_JOIN_CODE=fj_*) CODE=${line#FLEET_LOGIN_JOIN_CODE=}
      printf '%s' "$CODE" | grep -Eq '^fj_[a-z2-7]{26}$' || refuse "stdin: not a join code" ;;
    *) refuse "stdin: only FLEET_LOGIN_JOIN_CODE=<code> is taken" ;;
  esac
  if IFS= read -r -t 1 line; then refuse "stdin: one line only"; fi
fi

NONCE=$(/usr/bin/python3 -I "$RBIN/fleet_admin_ticket.py" spend --pub "$PUB" --used "$USED" --op "$OP" --login "$LOGIN" \
  ${MARGS[@]+"${MARGS[@]}"} --trust "$HERE" --trust "$HERE/$NAME" --trust "$CONF" --trust "$RBIN/$NAME" -- "$TICKET") \
  || exit 3
printf '%s' "$NONCE" | grep -Eq '^[0-9a-f]{32}$' || refuse "the ticket checker answered no nonce"
ENVV=(PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 "HOME=${HOME:-/var/root}" "FLEET_LOGIN_OP_ID=$NONCE"
      "FLEET_LOGIN_ADMIN_DIR=$HERE")
[ -z "$HUBURL" ] || ENVV+=("FLEET_LOGIN_HUB=$HUBURL")
[ -z "$CODE" ] || ENVV+=("FLEET_LOGIN_JOIN_CODE=$CODE")
[ "$OP" = create ] || exec /usr/bin/env -i "${ENVV[@]}" "$RBIN/$NAME" "$@"
/usr/bin/env -i "${ENVV[@]}" "$RBIN/$NAME" "$@"
rc=$?
case "$rc" in 0|3) exit "$rc" ;; esac
mark="$HERE/$LOGIN-onboard/op"
if id -u "$LOGIN" >/dev/null 2>&1 && [ -f "$mark" ] && [ ! -L "$mark" ] \
   && [ "$(sed -n 's/^op=//p' "$mark" | head -n 1)" = "$NONCE" ]; then
  if /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 "HOME=${HOME:-/var/root}" \
       "FLEET_LOGIN_ADMIN_DIR=$HERE" "$RBIN/fleet-login-remove.sh" "$LOGIN" --keep-home --apply; then
    echo "rolled back: login $LOGIN removed (home kept)"
  else
    echo "rollback FAILED (fleet-login-remove exit $?): login $LOGIN is still on this machine — remove it"
  fi
fi
exit "$rc"
