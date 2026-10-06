#!/usr/bin/env python3
"""
base-readonly-guard.py — a PreToolUse hook that makes the fleet's base checkout
edit-read-only for EVERY pane — worker, operator hub, scratch (issue #355).

Why it exists: CLAUDE.md and the worker charter promise a
"hook-enforced edit-read-only base checkout" — the load-bearing rail of the
fleet model (a worker edits inside its `issue-<N>` worktree and lands via PR;
the operator files/triages and hands implementation to a worker). Before this
hook the worker got NOTHING — it runs on bypassPermissions and inherits the
plain ~/.claude/settings.json, so a stray Edit/Write into the base checkout was
unguarded.

This closes the gap generically: deny Edit/Write/MultiEdit/NotebookEdit whose
target is inside the fleet's base checkout (FLEET_MAIN). Worktree siblings
(`<repo>-issue-N`, `scratch-N`) sit NEXT TO the base, not under it, so a worker
editing its own worktree passes; only a write into the base checkout itself is
denied.

Register it (matcher "Edit|Write|MultiEdit|NotebookEdit") — see
hooks/settings-hooks.json.

Codex (issue #547): a Codex worker edits through its `apply_patch` tool, whose
PreToolUse payload is {tool_name:"apply_patch", tool_input:{command:"<patch>"}}
(the same hook schema — bin/fleet-codex.sh wires this file with matcher
"apply_patch"). The patch names its targets on `*** Add File:` / `*** Update
File:` / `*** Delete File:` / `*** Move to:` lines, relative to the session cwd
unless absolute — every one is checked, and a single hit inside the base
checkout blocks the whole patch.

Contract (Claude Code hooks; Codex's is the same):
  - stdin: JSON with {tool_name, tool_input:{file_path|notebook_path,...}}
  - exit 0  -> allow
  - exit 2  -> BLOCK; stderr is shown to the model
  - ANY error / not-in-a-fleet -> exit 0 (fail OPEN): a guard bug or a
    non-fleet session must never lose the ability to edit files.

Resolving the base checkout: prefer FLEET_MAIN from the environment; otherwise
ask fleet-lib for the current session's base. Outside a fleet (no $TMUX, or no
FLEET_MAIN resolvable) there is nothing to protect, so we allow. A fleet that
hosts several repos (issue #788) has one base checkout per repo, and every one of
them is protected.
"""
import sys, os, glob, json, re, subprocess

# apply_patch target lines (Codex): the path is everything after the marker.
_PATCH_TARGET = re.compile(r"^\*\*\* (?:Add|Update|Delete) File: (.+?)\s*$|^\*\*\* Move to: (.+?)\s*$", re.M)


def _patch_targets(text):
    """Every file path an apply_patch body names (Add/Update/Delete/Move to)."""
    if not isinstance(text, str):
        return []
    out = []
    for m in _PATCH_TARGET.finditer(text):
        p = m.group(1) or m.group(2)
        if p:
            out.append(p)
    return out


def allow():
    sys.exit(0)


def block(path, base):
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/fleet/hooks/base-readonly-guard.py:\n"
        "  %s\n"
        "is inside the fleet base checkout (%s), which is edit-read-only.\n"
        "Workers edit inside their issue-<N> git worktree and land via PR; the\n"
        "operator files/triages and hands implementation to a worker. Never edit\n"
        "the base checkout directly.\n"
        % (path, base)
    )
    sys.exit(2)


def _any_repo_overlays():
    """True iff some fleet hosts a second repo (a fleets/<sess>/repos/ dir exists).
    A cheap glob, so a seat that exports FLEET_MAIN keeps skipping the subprocess
    whenever no fleet hosts more than one repo (issue #788)."""
    d = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
    return bool(glob.glob(os.path.join(d, "fleets", "*", "repos")))


def _resolve_bases():
    """Every base checkout to protect, realpath'd — [] if not in a fleet.

    A fleet may host several repos (issue #788); each hosted repo's FLEET_MAIN is
    a base checkout, so an edit into ANY of them is refused — not only the one the
    fleet conf (or this window's repo) names."""
    # 1) Env is authoritative and free if the seat exports it.
    bases = []
    env_base = os.environ.get("FLEET_MAIN", "").strip()
    if env_base:
        bases.append(env_base)
    # 2) Else resolve via fleet-lib for the current tmux session. Skip entirely
    #    when there's no $TMUX — a non-tmux session is never a fleet, and this
    #    avoids spawning a subprocess on every edit the operator makes elsewhere.
    if os.environ.get("TMUX") and (not env_base or _any_repo_overlays()):
        lib = os.path.expanduser(
            os.environ.get("FLEET_LIB", "~/.claude/fleet/bin/fleet-lib.sh")
        )
        if os.path.exists(lib):
            try:
                # Redirect the lib's own chatter to /dev/null so ONLY the mains
                # reach stdout (a stray echo during source/load would corrupt it).
                out = subprocess.run(
                    ["bash", "-c",
                     'source "$1" >/dev/null 2>&1; '
                     'S=$(fleet_current_session 2>/dev/null); '
                     '[ -n "$S" ] || exit 0; '
                     'fleet_load_conf "$S" >/dev/null 2>&1; '
                     'printf "%s\\n" "${FLEET_MAIN:-}"; '
                     'fleet_repo_mains "$S" 2>/dev/null',
                     "_", lib],
                    capture_output=True, text=True, timeout=5,
                )
                bases.extend(l.strip() for l in out.stdout.splitlines())
            except Exception:
                pass
    real = []
    for b in bases:
        if not b:
            continue
        try:
            rb = os.path.realpath(b)
        except Exception:
            continue
        if rb not in real:
            real.append(rb)
    return real


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
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        allow()
    if tool == "apply_patch":
        # Codex: one patch, many targets; relative paths resolve against the
        # session cwd the payload carries (the hook itself also runs there).
        paths = _patch_targets(ti.get("command") or ti.get("patch") or ti.get("input") or "")
        cwd = data.get("cwd") or os.getcwd()
        paths = [p if os.path.isabs(p) else os.path.join(cwd, p) for p in paths]
    elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        path = ti.get("file_path") or ti.get("notebook_path") or ""
        paths = [path] if path else []
    else:
        allow()
    if not paths:
        allow()

    bases = _resolve_bases()
    if not bases:
        allow()  # not in a fleet → nothing to protect

    for path in paths:
        for base in bases:
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
