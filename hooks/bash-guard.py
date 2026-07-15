#!/usr/bin/env python3
"""
bash-guard.py — a GENERIC PreToolUse deny-list for Bash commands, the fleet's
last line of defense.

Why it exists: a fleet runs its workers on `bypassPermissions` (issue #355), so
Claude Code never prompts before a Bash call. For the handful of commands that
are genuinely irreversible, this deny-list is the only thing between a stray
token and a destroyed working tree. It ships GENERIC rails only — the ones that
are dangerous in ANY repo (rm -rf on / ~ .git; a force-push onto the base
branch). Operator-specific rails (prod hosts, DB/k8s guards) live in a local
overlay, `~/.claude/hooks/bash-guard-local.py`, that this skeleton runs if
present and NEVER ships (see the OVERLAY section at the bottom).

Register it (matcher "Bash") — see hooks/settings-hooks.json. It is merged into
`~/.claude/settings.json`, so it runs for every seat: worker, steward, scratch.

Contract (Claude Code hooks):
  - stdin: JSON with {tool_name, tool_input:{command,...}}
  - exit 0  -> allow
  - exit 2  -> BLOCK; stderr is shown to the model so it can course-correct
  - ANY error here -> exit 0 (fail OPEN) so a guard bug never bricks a session.

FALSE-POSITIVE DISCIPLINE — the hard-won engineering this skeleton keeps:
  * The command is split into statement SEGMENTS on ; \\n && || | before
    matching, so tokens from a commit message or an unrelated statement can't
    combine across segments (e.g. "-rf" in a message + "master" elsewhere).
  * Rules match the git SUBCOMMAND (a real `git push`), not just the word
    "push" appearing anywhere in the line.
  * Short-option bundles are matched as whole flag tokens (-rf, -Rf), so a
    dangerous letter inside `-print0` or a path does NOT trip a flag rule.
  * The guard fails OPEN on any internal error — a deny-list bug must never take
    every session down with it.
"""
import sys, re, json, os


def allow():
    sys.exit(0)


def block(reason):
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/fleet/hooks/bash-guard.py: %s\n"
        "This command is irreversible and is denied even in bypass mode.\n"
        "If it is truly intended, run it yourself in a terminal, or add an\n"
        "exception in ~/.claude/hooks/bash-guard-local.py.\n"
        % reason
    )
    sys.exit(2)


# A short-option bundle (e.g. -rf, -Rf) containing letter `c`; anchored so only
# real flag tokens match and a trailing non-letter (e.g. -print0) does NOT.
def has_short_flag(seg, c):
    return re.search(r"(?:^|\s)-[a-zA-Z]*" + c + r"[a-zA-Z]*(?=\s|$)", seg) is not None


# The segment's COMMAND (after optional `sudo` / `VAR=val` prefixes) is `name`.
# Anchoring here means a dangerous word inside a message, an echo, or another
# command's arguments cannot trigger a rule.
def cmd_is(seg, name):
    return re.match(r"\s*(?:sudo\s+|\w+=\S+\s+)*" + name + r"\b", seg) is not None


# Base branches a force-push must never touch. master/main are the near-universal
# defaults; a fleet that runs off another base exports FLEET_BASE_BRANCH and the
# hook subprocess inherits it, so its base is protected too.
def _base_branches():
    names = {"master", "main"}
    bb = os.environ.get("FLEET_BASE_BRANCH", "").strip()
    if bb:
        names.add(bb)
    return names


def check_segment(seg):
    """`seg` is one lower-cased statement segment. Raise (via block) to deny."""

    # 1) Force-push touching the base branch — must be an actual `git push`.
    if re.match(r"\s*(?:sudo\s+|\w+=\S+\s+)*git\b(?:\s+(?:-\S+|\S+=\S+))*\s+push\b", seg):
        branch_re = r"\b(?:%s)\b" % "|".join(re.escape(b.lower()) for b in _base_branches())
        forced = (
            "--force" in seg
            or "--force-with-lease" in seg
            or has_short_flag(seg, "f")                  # -f / -fv etc.
            or re.search(r"\+\S*" + branch_re, seg)      # +master refspec
        )
        if forced and re.search(branch_re, seg):
            block("force-push targeting the base branch (base = shared truth)")

    # 2) rm -rf on root / home / a .git dir — must be an `rm` command (so `git rm`
    #    is exempt), with real recursive AND force flags and a bare dangerous target.
    if cmd_is(seg, "rm"):
        recursive = ("--recursive" in seg) or has_short_flag(seg, "r")
        force     = ("--force" in seg)     or has_short_flag(seg, "f")
        if recursive and force:
            # bare dangerous target as its own arg — tolerates a trailing slash,
            # a `*`, and surrounding quotes ("/", "$HOME", ~/); but NOT a subpath
            # (/usr/..., $HOME/.cache) which stays allowed.
            if re.search(r"(?:^|\s|[\x22\x27])(?:/|~|\$home|\$\{home\})/?\*?[\x22\x27]?(?:\s|$)", seg):
                block("rm -rf targeting filesystem root or $HOME")
            if re.search(r"(?:^|\s)\S*\.git(?:\s|/|$)", seg):
                block("rm -rf touching a .git directory (use `git worktree remove`)")

    # Operator-specific rails, if the local overlay defines any (never shipped).
    _run_overlay(seg)


# --- OVERLAY -----------------------------------------------------------------
# Operator-specific rules (prod hosts, DB/k8s rails, anything host-local) live in
# ~/.claude/hooks/bash-guard-local.py and are NEVER committed here. The overlay,
# if present, defines:
#
#     def check_segment(seg, ctx):
#         # seg: one lower-cased statement segment
#         # ctx.block(reason)        -> deny (exit 2)
#         # ctx.cmd_is(seg, name)    -> segment's command is `name`
#         # ctx.has_short_flag(seg, c) -> a -xNx flag bundle contains letter c
#         if ctx.cmd_is(seg, "kubectl") and "delete namespace" in seg:
#             ctx.block("kubectl delete namespace")
#
# A missing overlay is skipped silently; an overlay that raises is ignored
# (fail-open) — but an overlay's ctx.block() propagates as a real deny.
class _Ctx:
    block = staticmethod(block)
    cmd_is = staticmethod(cmd_is)
    has_short_flag = staticmethod(has_short_flag)


_OVERLAY = None
_OVERLAY_LOADED = False


def _load_overlay():
    global _OVERLAY, _OVERLAY_LOADED
    if _OVERLAY_LOADED:
        return _OVERLAY
    _OVERLAY_LOADED = True
    path = os.path.expanduser("~/.claude/hooks/bash-guard-local.py")
    if not os.path.exists(path):
        return None
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("bash_guard_local", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _OVERLAY = mod
    except SystemExit:
        raise
    except Exception:
        _OVERLAY = None  # a broken overlay must not brick the guard
    return _OVERLAY


def _run_overlay(seg):
    mod = _load_overlay()
    if mod is None or not hasattr(mod, "check_segment"):
        return
    try:
        mod.check_segment(seg, _Ctx)
    except SystemExit:
        raise                  # an overlay block() is a real deny — honor it
    except Exception:
        pass                   # any other overlay error → fail open


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()  # fail open

    if data.get("tool_name") != "Bash":
        allow()
    ti = data.get("tool_input") or {}
    cmd = ti.get("command", "") if isinstance(ti, dict) else ""
    if not cmd:
        allow()

    # split into statement segments so unrelated tokens can't combine
    for seg in re.split(r"&&|\|\||\||;|\n", cmd):
        seg = seg.strip()
        if seg:
            check_segment(seg.lower())
    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # never brick a session on a guard bug
