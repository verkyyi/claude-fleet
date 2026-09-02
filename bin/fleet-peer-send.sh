#!/bin/bash
# fleet-peer-send.sh — deliver a message to a LIVE Claude session over its local
# inbox socket: the same channel the SendMessage / ListAgents tools use between
# sessions on this machine (issue #513). The recipient sees it as a message from
# another session on its next turn (queued while it is mid-turn). This is the
# sanctioned way for fleet tooling — the quota watch, an operator script — to talk
# to a running session; raw `tmux send-keys` into a prompt is not (issue #437).
#
#   fleet-peer-send.sh [-L <socket>] <target> [<text> | -]
#
#   <target>  @<window-id> / %<pane-id> / <sess>:<idx>  → the Claude under that pane
#             <pid>                                     → that Claude process
#             <session-uuid>                            → the process running it
#   <text>    the message; `-` or omitted → read stdin (multi-line ok)
#   -L        tmux socket label for a tmux target when run outside the fleet
#             ($TMUX unset); inside a pane bare tmux is already the right server.
#
# Exit 0 iff the frame was written; 1 = target not found / not a live session
# (no registry record, no key, no socket); 2 = usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

SOCK=""
while [ $# -gt 0 ]; do
  case "$1" in
    -L) SOCK="${2:-}"; shift 2 ;;
    -L*) SOCK="${1#-L}"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
tgt="${1:-}"; [ -n "$tgt" ] || { sed -n '9,18p' "$0" >&2; exit 2; }
shift
if [ $# -eq 0 ] || [ "$1" = "-" ]; then text=$(cat); else text="$*"; fi
[ -n "$text" ] || { echo "fleet-peer-send: empty message" >&2; exit 2; }

# fleet_peer_resolve_pid <target> [socket] — target grammar above → Claude pid.
pid=""
case "$tgt" in
  ''|*[!0-9]*)
    case "$tgt" in
      @*|%*|*:*) pid=$(fleet_pane_claude_pid "$tgt" "$SOCK") ;;
      *-*-*-*-*) pid=$(fleet_cc_pid_for_session "$tgt") ;;
    esac ;;
  *) pid="$tgt" ;;
esac
[ -n "$pid" ] || { echo "fleet-peer-send: no live Claude session for '$tgt'" >&2; exit 1; }
kill -0 "$pid" 2>/dev/null || { echo "fleet-peer-send: pid $pid is not running" >&2; exit 1; }
if fleet_peer_send "$pid" "$text"; then
  echo "sent → pid $pid ($(fleet_cc_session_field "$pid" name 2>/dev/null || :))"
else
  echo "fleet-peer-send: pid $pid has no reachable inbox (not a registered session, or no key/socket)" >&2; exit 1
fi
