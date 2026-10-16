#!/bin/bash
# fleet-pane-submit.sh <socket> <window|pane> <text-file> — submit <text-file> as
# the NEXT TURN of the agent idling in that pane (issue #2234, EPIC #2230 C4):
# the first sentence a start sends into a session claimed from the warm pool.
#
# A warm window is past its TUI's input-mount flush (scratch-pool.sh), so the one
# deterministic channel left is the issue bridge's two-step injection: a bracketed
# paste of the whole (multi-line) text, then a SEPARATE Enter — an Enter inside the
# same send-keys is eaten by the paste (fleet-issue-bridge.sh bridge_inject).
# Nothing is typed until the pane is an agent at rest with an EMPTY input box
# (fleet-input.py --busy), so a person's half-typed draft is never glued onto.
#
# stdout, on success: two epoch-ms stamps `<t_ready>\t<t_prompt>` — when the input
# was seen empty and idle, and when the Enter went in (EPIC #2230 共同约定 3).
# Exit: 0 submitted (the turn started, or the input emptied) · 3 never ready within
# FLEET_SUBMIT_WAIT_SECS (5) — NOTHING was typed · 4 typed but not confirmed (the
# text sits in the input; one more Enter was tried) · 2 usage · 1 tmux failed.
# The text file is the caller's; it is read, never removed.
# Keep the old command path for sessions launched before this optimization.
BIN="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$BIN/fleet-pane-submit.py" "$@"
