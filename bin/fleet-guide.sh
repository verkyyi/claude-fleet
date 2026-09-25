#!/bin/bash
# cf --guide: recall the pinned onboarding guide in this login's fleet.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

live=$(fleet_sockets)
if [ -n "${TMUX:-}" ]; then
  sess=$(fleet_current_session)
  case "
$live
" in *"
$sess
"*) ;; *) echo 'cf --guide: current tmux session is not a running fleet' >&2; exit 1 ;; esac
else
  # One fleet per login. A stale second fleet uses the same recent-activity rule
  # as fleet-attach.sh, rather than an arbitrary order from the config files.
  sess=""; newest=-1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    activity=$(tmux -L "$candidate" display-message -p -t "$candidate" '#{session_activity}' 2>/dev/null)
    case "$activity" in ''|*[!0-9]*) activity=0 ;; esac
    if [ "$activity" -ge "$newest" ]; then sess="$candidate"; newest="$activity"; fi
  done <<EOF
$live
EOF
fi
[ -n "$sess" ] || { echo 'cf --guide: no running fleet; run cf first' >&2; exit 1; }

fleet_guide_open "$sess" || { echo 'cf --guide: could not open the guide' >&2; exit 1; }
tmux -L "$sess" select-window -t "$sess:guide" \
  || { echo 'cf --guide: could not focus the guide' >&2; exit 1; }
[ -n "${TMUX:-}" ] || exec tmux -L "$sess" attach -t "$sess"
