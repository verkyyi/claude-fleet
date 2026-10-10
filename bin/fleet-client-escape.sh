#!/bin/bash
# fleet-client-escape.sh — write the escape on stdin to the terminal of the tmux
# client in use (issue #1717): fleet-client-actions.py's iTerm2 road for an
# escape no other script sends (OSC 9, a notification). The client pick and the
# lock-client write are bin/fleet-client-lib.sh's — the same channel as
# fleet-show / fleet-open, never a second copy. Needs $TMUX + $TMUX_PANE on the
# server whose client it is (fleet-client-actions.py sets both).
#
#   --socket <path> --session <fleet session> --client <tty>   (issue #3005)
#     the home machine's own road to a thin client's 看台 (fleet_thin_lease.py
#     notify, from a loop with no pane): that server, that client — named, so no
#     pane and no termtype match is needed. The lock goes on the client's own
#     session (the 看台's), fc_run's FC_CSESS.
# Exit 0 = written; 1 = not (the reason on stderr).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-client-escape: python3 not found' >&2; exit 1; }
PY="$(command -v python3)"
# shellcheck source=/dev/null
. "$BIN/fleet-client-lib.sh"
esock='' esess='' ecli=''
while [ $# -gt 0 ]; do
  case "$1" in
    --socket) esock="${2:-}"; shift 2 ;;
    --session) esess="${2:-}"; shift 2 ;;
    --client) ecli="${2:-}"; shift 2 ;;
    *) echo "fleet-client-escape: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ -n "$esock" ]; then export TMUX="$esock,0,0"; unset TMUX_PANE; fi
if [ -n "$esess" ]; then FC_SESS="$esess"; else
  fc_session || { echo "fleet-client-escape: $FC_WHY" >&2; exit 1; }
fi
fc_pick "$ecli" "${FLEET_SHOW_TERM_RE:-^iTerm2}" || { echo "fleet-client-escape: $FC_WHY" >&2; exit 1; }
fc_lock || { echo "fleet-client-escape: $FC_WHY" >&2; exit 1; }
job=$(mktemp -d "${TMPDIR:-/tmp}/fleet-esc.XXXXXX") || { fc_unlock; exit 1; }
trap 'rm -rf "$job"; fc_unlock' EXIT
( umask 077; cat > "$job/escape" )
: > "$job/status"
fc_run "exec $(fc_sq "$PY") $(fc_sq "$BIN/fleet-show-send.py") --raw --out $(fc_sq "${FLEET_SHOW_OUT:-/dev/tty}") --status $(fc_sq "$job/status") $(fc_sq "$job/escape")" \
  || { echo "fleet-client-escape: $FC_WHY" >&2; exit 1; }
fc_wait "$job/status" 10 && grep -q '^ok	' "$job/status"
