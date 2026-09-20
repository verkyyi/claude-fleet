#!/usr/bin/env python3
"""
agent-guard.py — PreToolUse hook: inside a fleet, code-writing work goes to a
Fleet WORKER; a subagent may only do read-only fan-out (Explore / Plan).

WHY (issue #811): a general-purpose subagent spawned from a fleet pane runs
OUTSIDE every rail the fleet has. The dash cannot see it, it has no
@claude_state, the quota migration moves WINDOWS so a subagent that hits the
account limit simply dies mid-edit (the "taking over from the previous agent,
which was cut off by quota" re-dispatches in the 2026-09-19 transcript audit),
several subagents write the same worktree at once, there is no one-worker-one-PR,
no /fleet-history row and no handoff. The fleet already has the right primitive
for "implement this": a WORKER in its own issue-<N> worktree, spawned through
the one choke point that applies the session caps and the cross-machine dedup.
The rule was prose only (CLAUDE.md, commands/_template.md); this makes it a rail.

Wired from hooks/settings-hooks.json with matcher "Agent"; installed
machine-wide into ~/.claude/settings.json by /fleet-sync-install, so it covers
the hub, scratch sessions and workers on every fleet. Claude Code re-reads hooks
per turn — live sessions pick it up without a restart. Codex has no Agent tool;
hooks/codex-map.json drops the group explicitly.

Contract (same as the sibling guards):
  - stdin: JSON {tool_name, tool_input:{subagent_type?, isolation?, ...}}
  - exit 0  -> allow
  - exit 2  -> BLOCK; stderr is shown to the model (it says what to do instead)
  - any error / non-Agent tool -> exit 0 (fail OPEN — a guard bug must never
    brick a session)
  - FLEET_ALLOW_SUBAGENT=1 in the environment -> allow (the operator's escape
    hatch, same shape as FLEET_ALLOW_ARTIFACT)
  - outside a fleet -> allow. There are no rails to lose in a plain `claude`
    session, and nothing to point at instead. "In a fleet" = FLEET_MAIN in the
    environment (a seat that exports it; the selftest seam), or — under $TMUX —
    the current tmux session has a fleet conf (an ad-hoc session on the default
    socket is NOT a fleet, issue #159). No $TMUX is never a fleet, and skips the
    subprocess.

Verdict:
  - subagent_type in ALLOWED (read-only: Explore, Plan, claude-code-guide) -> allow
  - anything else — general-purpose, claude, fork, an unknown type, or NO type
    (the tool's default is general-purpose) -> BLOCK
  - isolation == "worktree" -> BLOCK even for an allowed type: a fork worktree
    lands under <repo>/.claude/worktrees, where base-readonly-guard.py refuses
    every edit, so allowing it yields an agent that can start but cannot write.
    A fresh worktree in a fleet comes from the fleet (issue-<N> / scratch-<N>).
"""
import json
import os
import subprocess
import sys

ALLOWED = {"explore", "plan", "claude-code-guide"}

MSG = (
    "⛔ BLOCKED by ~/.claude/fleet/hooks/agent-guard.py: in a fleet session,\n"
    "code-writing work goes to a Fleet WORKER, not a subagent (issue #811).\n"
    "  A subagent runs outside every fleet rail: the dash cannot see it, it has no\n"
    "  state, the quota migration moves windows (so a subagent that hits the limit\n"
    "  just dies mid-edit), several can write one worktree at once, and there is no\n"
    "  one-worker-one-PR, no history row, no handoff.\n"
    "  Instead:\n"
    "    implement an EXISTING issue  ~/.claude/fleet/bin/dash-issue-session.sh <N>\n"
    "    file + spawn a NEW one       ~/.claude/fleet/bin/fleet-issue-file.sh --title '…' --spawn\n"
    "                                 (add --parent <N> from a worker on issue N)\n"
    "    an ad-hoc, non-issue task    ~/.claude/fleet/bin/dash-raw-session.sh --prompt '…'\n"
    "  The worker claims, ships and lands on its own and pushes a [child-report] to\n"
    "  this session when it does; reach a live worker with ListAgents → SendMessage.\n"
    "  Read-only fan-out (find which files touch X) is still fine: subagent_type\n"
    "  Explore (or Plan / claude-code-guide), without isolation: worktree — a fork\n"
    "  worktree is edit-blocked by the base guard. Operator override:\n"
    "  FLEET_ALLOW_SUBAGENT=1.\n"
)


def allow():
    sys.exit(0)


def block():
    sys.stderr.write(MSG)
    sys.exit(2)


def _in_fleet():
    """True iff this pane belongs to a fleet (see the module doc)."""
    if os.environ.get("FLEET_MAIN", "").strip():
        return True
    if not os.environ.get("TMUX"):
        return False
    lib = os.path.expanduser(os.environ.get("FLEET_LIB", "~/.claude/fleet/bin/fleet-lib.sh"))
    if not os.path.exists(lib):
        return False
    try:
        # Only the verdict reaches stdout: the lib's own chatter is discarded.
        out = subprocess.run(
            ["bash", "-c",
             'source "$1" >/dev/null 2>&1; '
             'S=$(fleet_current_session 2>/dev/null); '
             '[ -n "$S" ] && [ -f "$(fleet_conf_file "$S" 2>/dev/null)" ] && printf 1',
             "_", lib],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip() == "1"
    except Exception:
        return False


def main():
    if os.environ.get("FLEET_ALLOW_SUBAGENT", "").strip() == "1":
        allow()
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()  # fail open
    if not isinstance(data, dict) or data.get("tool_name") not in ("Agent", "Task"):
        allow()
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        allow()
    if not _in_fleet():
        allow()
    isolation = str(ti.get("isolation") or "").strip().lower()
    if isolation == "worktree":
        block()
    stype = str(ti.get("subagent_type") or "").strip().lower()
    if stype in ALLOWED:
        allow()
    block()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # never brick a session on a guard bug
