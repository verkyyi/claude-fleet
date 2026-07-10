#!/bin/bash
# dash-toggle-show-bound.sh "<session>" — toggle whether the backlog panel shows
# issues already bound to a live worker session in THIS fleet.
#
# State is per-fleet (keyed by the tmux session name) so a multi-fleet box keeps
# each backlog's show/hide setting independent — mirrors the $ACT naming in
# tmux-issues.sh. Existence of the file = "show bound"; absent = "hide" (the
# default). tmux-issues-rows.sh reads the same path.
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"
sess="${1:-}"
f="$C/backlog_show_bound_${sess:-_}"
mkdir -p "$C" 2>/dev/null || true
if [ -f "$f" ]; then rm -f "$f"; else : > "$f"; fi
