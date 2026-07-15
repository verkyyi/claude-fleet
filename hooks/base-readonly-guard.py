#!/usr/bin/env python3
"""
base-readonly-guard.py — a PreToolUse hook that makes the fleet's base checkout
edit-read-only for EVERY seat (issue #355).

Why it exists: CLAUDE.md and every worker/steward charter promise a
"hook-enforced edit-read-only base checkout" — the load-bearing rail of the
steward/worker model (a worker edits inside its `issue-<N>` worktree and lands
via PR; a steward files/triages and never codes). Auditing that rail found it
only HALF shipped:
  * The STEWARD gets it via `permissions.deny` in conf/steward-settings.template.json.
  * The WORKER got NOTHING — it runs on bypassPermissions and inherits the plain
    ~/.claude/settings.json, so a stray Edit/Write into the base checkout was
    unguarded. (The steward template comment even claimed a "PreToolUse
    read-only-base-checkout hook remains the backstop" — this is that hook.)

This closes the gap generically: deny Edit/Write/MultiEdit/NotebookEdit whose
target is inside the fleet's base checkout (FLEET_MAIN). Worktree siblings
(`<repo>-issue-N`, `scratch-N`) sit NEXT TO the base, not under it, so a worker
editing its own worktree passes; only a write into the base checkout itself is
denied.

Register it (matcher "Edit|Write|MultiEdit|NotebookEdit") — see
hooks/settings-hooks.json.

Contract (Claude Code hooks):
  - stdin: JSON with {tool_name, tool_input:{file_path|notebook_path,...}}
  - exit 0  -> allow
  - exit 2  -> BLOCK; stderr is shown to the model
  - ANY error / not-in-a-fleet -> exit 0 (fail OPEN): a guard bug or a
    non-fleet session must never lose the ability to edit files.

Resolving the base checkout: prefer FLEET_MAIN from the environment; otherwise
ask fleet-lib for the current session's base. Outside a fleet (no $TMUX, or no
FLEET_MAIN resolvable) there is nothing to protect, so we allow.
"""
import sys, os, json, subprocess


def allow():
    sys.exit(0)


def block(path, base):
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/fleet/hooks/base-readonly-guard.py:\n"
        "  %s\n"
        "is inside the fleet base checkout (%s), which is edit-read-only.\n"
        "Workers edit inside their issue-<N> git worktree and land via PR; the\n"
        "steward files/triages and hands implementation to a worker. Never edit\n"
        "the base checkout directly.\n"
        % (path, base)
    )
    sys.exit(2)


def _resolve_base():
    """The fleet base checkout to protect, realpath'd — or "" if not in a fleet."""
    # 1) Env is authoritative and free if the seat exports it.
    base = os.environ.get("FLEET_MAIN", "").strip()
    # 2) Else resolve via fleet-lib for the current tmux session. Skip entirely
    #    when there's no $TMUX — a non-tmux session is never a fleet, and this
    #    avoids spawning a subprocess on every edit the operator makes elsewhere.
    if not base and os.environ.get("TMUX"):
        lib = os.path.expanduser(
            os.environ.get("FLEET_LIB", "~/.claude/fleet/bin/fleet-lib.sh")
        )
        if os.path.exists(lib):
            try:
                # Redirect the lib's own chatter to /dev/null so ONLY FLEET_MAIN
                # reaches stdout (a stray echo during source/load would corrupt it).
                out = subprocess.run(
                    ["bash", "-c",
                     'source "$1" >/dev/null 2>&1; '
                     'S=$(fleet_current_session 2>/dev/null); '
                     '[ -n "$S" ] && fleet_load_conf "$S" >/dev/null 2>&1; '
                     'printf "%s" "${FLEET_MAIN:-}"',
                     "_", lib],
                    capture_output=True, text=True, timeout=5,
                )
                base = out.stdout.strip()
            except Exception:
                base = ""
    if not base:
        return ""
    try:
        return os.path.realpath(base)
    except Exception:
        return ""


def _under(path, base):
    """True iff realpath(path) is the base dir itself or a descendant of it."""
    try:
        p = os.path.realpath(path)
    except Exception:
        return False
    # Component-aware prefix: base + os.sep so `<base>-issue-5` does NOT match.
    return p == base or p.startswith(base + os.sep)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()  # fail open

    tool = data.get("tool_name")
    if tool not in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        allow()
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        allow()
    path = ti.get("file_path") or ti.get("notebook_path") or ""
    if not path:
        allow()

    base = _resolve_base()
    if not base:
        allow()  # not in a fleet → nothing to protect

    if _under(path, base):
        block(os.path.realpath(path), base)
    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # never brick a session on a guard bug
