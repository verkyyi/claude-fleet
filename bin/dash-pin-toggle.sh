#!/bin/bash
# dash-pin-toggle.sh <window-target> — pin/unpin a dash row (dash ⌃y, issue #623).
#
# The dash sorts by urgency (needs > done > working > looping > idle), which is
# right for triage and wrong for the one session you are deliberately keeping an
# eye on — a long-running parent scratch, a worker you are babysitting. A pin is a
# tier ABOVE the status rank: tmux-dashboard-rows.sh sorts `@pin=1` windows before
# every unpinned one whatever their state, into a `置顶 (n)` group of their own at
# the top of the list (issue #1170 — the group says why they are up there; no row
# carries a mark), and floats a pinned parent's CHILDREN with it (the pin bit rides the
# same @origin inheritance the grouping already uses).
#
# State lives on the WINDOW (a tmux window option), which is the whole point:
#   • it dies with the window — reap a pinned row and there is no file, marker or
#     ledger entry left behind to clean up (acceptance: "no residue");
#   • it cannot be inherited by a recycled window INDEX, because the option is
#     keyed by window and this toggle addresses one by `window_id`;
#   • it is per-fleet for free (one tmux server per fleet, issue #159).
#
# Target: whatever the dash row hands over ({1} = `sess:idx`) or the fleet's short
# window handle (`a1`, issue #566) — normalised through fleet_wid_target like every
# other target-taking script, so `dash-pin-toggle.sh b3` works from a shell too.
# A landed-view row (`landed:*`), the header row or an empty target is a silent
# no-op: there is no live window to pin.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

target="${1:-}"
case "$target" in ''|hdr|landed:*) exit 0 ;; esac

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$BIN/fleet-ui-lang.sh" 2>/dev/null || true
if command -v fleet_wid_target >/dev/null 2>&1; then
  target="$(fleet_wid_target "$target")"
fi

# Bare `tmux`: this runs inside the dash pane, so $TMUX already points at THIS
# fleet's socket (the CLAUDE.md rail) — never another fleet's windows.
name=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null) || exit 0
[ -n "$name" ] || exit 0
sess=$(tmux display-message -p -t "$target" '#{session_name}' 2>/dev/null || true)
[ -n "$sess" ] && command -v fleet_load_conf >/dev/null 2>&1 && fleet_load_conf "$sess" 2>/dev/null || true

cur=$(tmux show-options -wqv -t "$target" @pin 2>/dev/null) || cur=''
if [ "$cur" = 1 ]; then
  # -u removes the option outright rather than parking a 0 — an unset @pin is the
  # ordinary state everywhere else (a window that was never pinned has none), so
  # unpinning must leave the window byte-identical to one that never was.
  tmux set-option -w -t "$target" -u @pin 2>/dev/null || exit 0
  msg=$(fleet_ui_t pin_unpinned_fmt "$name")
  tmux display-message "$msg" 2>/dev/null || true
else
  tmux set-option -w -t "$target" @pin 1 2>/dev/null || exit 0
  msg=$(fleet_ui_t pin_pinned_fmt "$name")
  tmux display-message "$msg" 2>/dev/null || true
fi
exit 0
