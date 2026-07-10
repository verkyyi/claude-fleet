#!/bin/sh
# steward-readopt-hook.sh — re-inject the STEWARD's identity after a /clear (issue #155).
#
# Wired to the Claude Code `SessionStart` hook. A /clear keeps the SAME claude
# process alive (same PID/cwd/tmux markers) but wipes the conversation context —
# so the steward, whose identity was injected exactly once by the spawn seed
# prompt (bin/steward-session.sh), silently goes amnesiac. Worse, CC reloads the
# cwd CLAUDE.md on every SessionStart, and for the steward that cwd is the base
# checkout whose CLAUDE.md is the *install playbook* — so post-/clear the steward
# re-adopts the WRONG (installer) persona. Nothing re-injects steward.md.
#
# This hook closes that gap: on a /clear in a @steward pane it prints steward.md
# (plus a pointer to the newest handoff) back into the model's context. For
# SessionStart, plain stdout IS added to the model's context (confirmed against
# the CC hooks docs), so we print ONLY the context string and nothing else.
#
# Scope is deliberately TIGHT — SessionStart also fires on startup/resume/compact,
# and every SessionStart hook's output is concatenated, so we re-adopt on `clear`
# ONLY:
#   • startup — the spawn seed prompt already reads steward.md (and the @steward
#     marker is often not set yet at startup, so the gate below would skip anyway);
#   • resume  — a `claude --resume` carries the steward.md adoption in its restored
#     history, and the fresh-fallback path (#143) re-reads steward.md itself;
#   • compact — identity is preserved in the compaction summary.
# Re-injecting on those would just pile redundant context onto every session.
#
# Two hard gates keep this from ever mis-firing:
#   1. source == clear   (the only case the crash-resume path #143 doesn't cover);
#   2. the pane is @steward=1 — a worker/scout pane running /clear must NEVER be
#      handed the steward's standing orders.
# No-op outside tmux, with no pane, or if ~/.claude/steward.md is absent (the
# identity file is a personal rail, not shipped in the repo — nothing to adopt).
#
# Testable seam: FLEET_READOPT_SOURCE overrides the stdin source (the selftest
# has no real hook payload). Always exits 0 — SessionStart cannot block.
set -u

# 1. No-op outside tmux / with no owning pane.
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0

# 2. Resolve the SessionStart source. Prefer the test override; else parse the
#    hook's stdin JSON ({"...","source":"clear",...}). Guard against a tty so a
#    manual invocation without a piped payload never hangs on cat.
if [ -n "${FLEET_READOPT_SOURCE:-}" ]; then
  src="$FLEET_READOPT_SOURCE"
elif [ ! -t 0 ]; then
  payload=$(cat 2>/dev/null || true)
  src=$(printf '%s' "$payload" \
    | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
else
  src=""
fi
# Re-adopt on /clear ONLY (see header for why startup/resume/compact are excluded).
[ "$src" = "clear" ] || exit 0

# 3. Hard gate: only a @steward=1 pane gets steward identity. An unmarked pane
#    (worker/scout) reports empty here and is skipped.
st=$(tmux display-message -p -t "$TMUX_PANE" '#{@steward}' 2>/dev/null)
[ "$st" = "1" ] || exit 0

# 4. The identity file. steward.md is a personal rail (~/.claude/steward.md), not
#    shipped in the repo; if it is absent there is nothing to re-adopt — no-op.
ORDERS="$HOME/.claude/steward.md"
[ -f "$ORDERS" ] || exit 0

# 5. Newest steward handoff, if any — a pointer only (the steward decides whether
#    to /handoff pick it up; we do not dump its whole body).
# shellcheck disable=SC2012  # steward-<date>.md are our own [a-z0-9-]-safe names, not arbitrary
handoff=$(ls -t "$HOME"/.claude/handoff/steward-*.md 2>/dev/null | head -n1)

# 6. Emit the re-adopt context. The preamble is a QUOTED heredoc (no expansion),
#    framed as factual statements — not imperative "SYSTEM:" text — so CC adopts
#    it rather than surfacing it as suspected prompt injection.
cat <<'MSG'
[fleet steward re-adopt] Your conversation context was just cleared (/clear), but
you are still the SAME long-lived STEWARD process for this fleet — the same PID,
cwd, tmux @steward marker, worktrees and daemons are all intact; only your
conversation memory was wiped. The standing orders below (from ~/.claude/steward.md)
still apply — re-adopt them now. A fleet == one tmux session == one GitHub repo;
resolve your bound repo from the fleet conf:
    source ~/.claude/fleet/bin/fleet-lib.sh
    S=$(fleet_current_session); fleet_load_conf "$S"   # -> FLEET_REPO / FLEET_MAIN
Note: this repo's cwd CLAUDE.md is an *install playbook*, reloaded on every
SessionStart — that is NOT your identity; these steward orders are. Do NOT run
/sweep and do NOT arm /loop. Stay quiet until asked.

===== ~/.claude/steward.md =====
MSG
cat "$ORDERS"

if [ -n "$handoff" ]; then
  # shellcheck disable=SC2016  # the backticks are literal markdown code-span text, not expansions
  printf '\nA recent steward handoff exists: %s\nConsider `/handoff` picking up the newest one to recover in-flight state.\n' "$handoff"
fi
exit 0
