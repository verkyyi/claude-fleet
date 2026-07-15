#!/bin/sh
# handoff-latch-reset-hook.sh — clear the auto-handoff debounce latch AND stamp the
# deterministic fresh-session marker at a session boundary (issues #330, #345).
# Wired to the Claude Code `SessionStart` hook.
#
# Two jobs, in order:
#
# 1. RESET THE LATCH (unconditional). The Stop hook (bin/set-claude-state.sh) sets
#    @handoff_armed=1 the first time it nudges a pane to run /fleet-handoff, and
#    SKIPS while the latch is set — without it the nudge would re-fire every turn
#    until the context actually drops (a loop), because arming the handoff doesn't
#    lower the context; only the post-turn /clear does. A SessionStart is exactly
#    the boundary that ends that high-context session:
#      • the auto-handoff cycle's /clear fires SessionStart(source=clear) on the SAME
#        pane — the fresh, low-context session must be able to earn a future nudge;
#      • a crash-restore / fresh startup also begins a new session, and @handoff_armed
#        is a tmux WINDOW option that outlives the claude process — a stale latch left
#        by a crash would otherwise wedge auto-handoff off forever.
#    So we clear it UNCONDITIONALLY (every session boundary is a clean slate). After a
#    /clear the context is low anyway, so re-nudging can't happen until it climbs back.
#
# 2. STAMP THE FRESH-SESSION MARKER (source=clear ONLY). The auto-handoff cycle
#    (bin/fleet-handoff-cycle.sh §4) used to CONFIRM that its /clear landed by
#    screen-scraping the live TUI (capture-pane for `❯`/`>`/banner text) — brittle,
#    TUI-version-dependent, and race-prone (~50% of cycles failed to confirm, #345).
#    A /clear fires SessionStart(source=clear) on this same pane, i.e. THIS hook is
#    the deterministic "the fresh session actually started" event. So on source=clear
#    we stamp a monotonic-epoch marker (@handoff_cleared_at=<epoch>) that the cycle
#    polls instead of grepping the screen — unambiguous and TUI-independent. The
#    cycle records t0 just before it types /clear and accepts only a marker >= t0, so
#    a stale value from an earlier clear never false-confirms; no cleanup needed.
#    We stamp on `clear` ONLY (not startup/resume/compact) — those are not the
#    cycle's /clear and must never be mistaken for a confirmed clear.
#
# Testable seam: FLEET_LATCH_RESET_SOURCE overrides the stdin source (the selftest
# has no real hook payload). No-op outside tmux / with no owning pane. Always exits 0
# (SessionStart can't block).
set -u
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

# 1. Reset the debounce latch (unconditional — every session boundary is clean).
tmux set-window-option -u -t "$TMUX_PANE" @handoff_armed 2>/dev/null || true

# 2. Resolve the SessionStart source. Prefer the test override; else parse the hook's
#    stdin JSON ({"...","source":"clear",...}). Guard against a tty so a manual
#    invocation without a piped payload never hangs on cat (mirrors steward-readopt).
if [ -n "${FLEET_LATCH_RESET_SOURCE:-}" ]; then
  src="$FLEET_LATCH_RESET_SOURCE"
elif [ ! -t 0 ]; then
  src=$(cat 2>/dev/null \
    | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
else
  src=""
fi

# Stamp the deterministic fresh-session marker on /clear ONLY (see header job 2).
if [ "$src" = "clear" ]; then
  now=$(date +%s 2>/dev/null || echo 0)
  tmux set-window-option -t "$TMUX_PANE" @handoff_cleared_at "$now" 2>/dev/null || true
fi

exit 0
