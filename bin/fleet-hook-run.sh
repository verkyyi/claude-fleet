#!/bin/sh
# fleet-hook-run.sh — how a CLIENT-only computer runs the fleet's Claude Code
# hooks (issue #1725, EPIC #1718 C7).
#
# hooks/settings-hooks.json wires every hook at the full install's path,
# `<interp> ~/.claude/fleet/{hooks,bin}/<name> [args]`. A computer that has only
# the client (the base in ~/.claude/fleet, #1804) lacks most of them — and a PreToolUse
# `python3 <missing>.py` exits 2, which Claude Code reads as BLOCK. So the
# client's apply (fleet-install-apply.sh --bundle → fleet-hooks-merge.py merge
# --via <root>) wires each one through this shim instead:
#
#   sh <root>/bin/fleet-hook-run.sh <interp> ~/.claude/fleet/<dir>/<name> [args]
#
# The wired path stays in the command, so the hook's identity (event, matcher,
# script basename) is the full install's: a later `fleet node join` / sync on
# this login replaces the entry in place, never beside it. Here:
#
#   1. the full install's script exists (this login became a node — the
#      part that runs sessions, bin/fleet-up.sh, is there) → run it;
#   2. the package carries it (<root>/<dir>/<name>: the four guards) → run that,
#      with TMUX / TMUX_PANE unset — no pane on a client is a fleet pane, so
#      every guard takes its "not a fleet" path, as it does in a plain terminal;
#   3. neither (pane plumbing: set-claude-state, classify, precompact …, which
#      act only inside a fleet pane, and a fleet pane lives on a node) → exit 0.
#
# Never blocks a session on its own account: anything it cannot resolve is 0.
interp="${1:-}" wired="${2:-}"
[ -n "$interp" ] && [ -n "$wired" ] || exit 0
shift 2
# shellcheck disable=SC2088  # a literal ~/ the shell left unexpanded
case "$wired" in "~/"*) wired="$HOME/${wired#"~/"}" ;; esac
# (1) only when it IS the full install: the install line's base sits at the
# same path (issue #1804) and is a client, so it takes (2)/(3)
if [ -f "$wired" ] && [ -f "$HOME/.claude/fleet/bin/fleet-up.sh" ]; then
  exec "$interp" "$wired" "$@"
fi
rel="${wired##*/.claude/fleet/}"
[ "$rel" != "$wired" ] || exit 0
root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)" || exit 0
[ -f "$root/$rel" ] || exit 0
unset TMUX TMUX_PANE
exec "$interp" "$root/$rel" "$@"
