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
# Where things are comes from admin.conf BESIDE this copy (root's, like the
# copy: a caller can move neither), key=value lines, never sourced:
#
#   bin=<dir>       the release's bin/ (its fleet-login-*.sh, fleet_admin_ticket.py)
#   pub=<file>      the hub's account-op key, `ed25519 <b64>` (default <here>/account.pub)
#   used=<dir>      the spent-nonce book (default <here>/used)
#   machine=<name>  this machine as the hub names it (default: its hostname)
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
/usr/bin/python3 -I "$RBIN/fleet_admin_ticket.py" spend --pub "$PUB" --used "$USED" --op "$OP" --login "$LOGIN" \
  ${MARGS[@]+"${MARGS[@]}"} --trust "$HERE" --trust "$HERE/$NAME" --trust "$CONF" --trust "$RBIN/$NAME" -- "$TICKET" \
  || exit 3
exec "$RBIN/$NAME" "$@"
