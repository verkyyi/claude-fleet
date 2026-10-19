#!/bin/bash
# dash-rename.sh --wid <@id|handle> [name] — rename a session's window from ⌘P's
# row menu (issue #898; the old dash's ⌃e fzf rename mode went with the dash,
# issue #4902). The view edits the name in its own input line and hands it here
# as an argv word — no tmux or shell parser ever sees it. Renames that window by
# its stable id (never an index); an EMPTY name cancels. It stamps @name_manual
# with the name (issue #3317): a name the person chose beats the issue title in
# every list. Without [name] it reads `@rename_to` off the window (and clears
# it) — a seam for callers that can only set an option.
set -uo pipefail
[ "${1:-}" = --wid ] || exit 0
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
w="${2:-}"
command -v fleet_wid_target >/dev/null 2>&1 && w="$(fleet_wid_target "$w")"
case "$w" in @[0-9]*) ;; *) exit 0 ;; esac
if [ "$#" -ge 3 ]; then name="$3"
else name=$(tmux show-options -wqv -t "$w" @rename_to 2>/dev/null)
fi
tmux set-option -uw -t "$w" @rename_to 2>/dev/null || :
[ -n "$name" ] || exit 0
name=${name//$'\t'/ }
# @name_manual (issue #3317): the name the person chose, so every list shows it
# over the issue title (fleet_view.py's rows, the inventory's title= column) —
# while the window still wears it; a later rename by the fleet ends it.
tmux rename-window -t "$w" -- "$name" \; set-option -w -t "$w" @name_manual "$name" 2>/dev/null || exit 0
exit 0
