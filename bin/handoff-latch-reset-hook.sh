#!/bin/sh
# handoff-latch-reset-hook.sh — clear the auto-handoff debounce latch at a session
# boundary (issue #330). Wired to the Claude Code `SessionStart` hook.
#
# The Stop hook (bin/set-claude-state.sh) sets @handoff_armed=1 the first time it
# nudges a pane to run /fleet-handoff, and SKIPS while the latch is set — without
# it the nudge would re-fire every turn until the context actually drops (a loop),
# because arming the handoff doesn't lower the context; only the post-turn /clear
# does. A SessionStart is exactly the boundary that ends that high-context session:
#   • the auto-handoff cycle's /clear fires SessionStart(source=clear) on the SAME
#     pane — the fresh, low-context session must be able to earn a future nudge;
#   • a crash-restore / fresh startup also begins a new session, and @handoff_armed
#     is a tmux WINDOW option that outlives the claude process — a stale latch left
#     by a crash would otherwise wedge auto-handoff off forever.
# So we clear it UNCONDITIONALLY (every session boundary is a clean slate). After a
# /clear the context is low anyway, so re-nudging can't happen until it climbs back.
#
# No-op outside tmux / with no owning pane. Always exits 0 (SessionStart can't block).
set -u
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

tmux set-window-option -u -t "$TMUX_PANE" @handoff_armed 2>/dev/null || true

exit 0
