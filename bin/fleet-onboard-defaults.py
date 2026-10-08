#!/usr/bin/env python3
"""Seed Claude's first-run UI and the new login's wizard command permissions.

Only fleet-login-bootstrap.sh calls this, after install-apply and before fleet-up.
Existing logins never reach it. Existing values and allow rules are kept.

Claude Code's first start asks questions a fleet pane has nobody to answer
(issue #2401): the onboarding (theme, the welcome), and — on 2.1.29x with
permissions.defaultMode=bypassPermissions — "Make auto mode your default
permission mode?", which parked every new login's first `guide` session for good.
Both answers are Claude Code's own ~/.claude.json keys, FIRST_RUN below; their
values are conf/claude-settings.default.json's "globalConfig" (the ONE source the
install-apply settings pass fills into every existing login). That pass never
creates a .claude.json Claude Code did not write — so a new login, which has none
before its first start, gets them HERE, before fleet-up opens the first session.
The fleet default stays bypass: hasSeenAutoDefaultNudge is "No, keep bypass".

  fleet-onboard-defaults.py HOME           seed (fill only)
  fleet-onboard-defaults.py --check HOME   read-only, fleet-doctor's `firstrun` row:
      `ok …` (exit 0) · `missing …` / `differs …` lines (exit 1)
"""

import json
import os
from pathlib import Path
import sys
import tempfile


# The wizard confirms every write in conversation before running it. Keep this
# list aligned with commands/fleet-onboard.md; its selftest extracts the code
# blocks from that file and checks every executable line against these rules.
ALLOW = [
    "Bash(~/.claude/fleet/bin/fleet-onboard.sh brief)",
    "Bash(~/.claude/fleet/bin/fleet-onboard.sh reset)",
    "Bash(~/.claude/fleet/bin/fleet-onboard.sh set *)",
    "Bash(~/.claude/fleet/bin/fleet-repo.sh add *)",
    "Bash(~/.claude/fleet/bin/fleet-repo.sh remove *)",
    "Bash(~/.claude/fleet/bin/fleet-issue-file.sh --repo *)",
    "Bash(~/.claude/fleet/bin/fleet-keys.sh --context sidebar --plain)",
    "Bash(~/.claude/fleet/bin/fleet-keys.sh --plain)",
    "Bash(~/.claude/fleet/bin/fleet-pr-verdict.sh *)",
    "Bash(~/.claude/fleet/bin/fleet-peer-send.sh issue:*)",
    "Bash(gh repo list *)",
    "Bash(gh repo create *)",
    "Bash(gh repo view *)",
    "Bash(gh pr list *)",
    "Bash(gh pr view *)",
    "Bash(gh pr diff *)",
    "Bash(gh pr merge *)",
    "Bash(tmux list-windows *)",
]


# The ~/.claude.json keys that answer Claude Code's first-run questions. Values come
# from conf/claude-settings.default.json's globalConfig, never from here.
FIRST_RUN = ("hasCompletedOnboarding", "hasSeenAutoDefaultNudge")
DEFAULTS = Path(__file__).resolve().parent.parent / "conf" / "claude-settings.default.json"


def first_run_defaults():
    table = read_object(DEFAULTS).get("globalConfig", {})
    missing = [k for k in FIRST_RUN if k not in table]
    if missing:
        raise ValueError(f"{DEFAULTS} globalConfig lacks {', '.join(missing)}")
    return {k: table[k] for k in FIRST_RUN}


def shielded_keys(home):
    """~/.claude/settings.fleet-override.json: keys the login keeps for itself."""
    try:
        src = json.loads((home / ".claude" / "settings.fleet-override.json").read_text())
    except (FileNotFoundError, ValueError):
        return set()
    return {k for k in src if isinstance(k, str)} if isinstance(src, (list, dict)) else set()


def check(home):
    state_path = home / ".claude.json"
    want = first_run_defaults()
    kept = shielded_keys(home)
    try:
        state = read_object(state_path)
    except ValueError as exc:
        print(f"unreadable {exc}")
        return 1
    if not state_path.exists():
        print(f"missing    {state_path} — Claude Code's first start will stop on its onboarding")
        return 1
    bad = []
    for k, v in want.items():
        if k in kept:
            continue
        if k not in state:
            bad.append(f"missing    claude.json {k} (default {json.dumps(v)})")
        elif state[k] != v:
            bad.append(f"differs    claude.json {k} = {json.dumps(state[k])} (default {json.dumps(v)})")
    note = f"; left to this login: {', '.join(sorted(kept & set(want)))}" if kept & set(want) else ""
    if not bad:
        print(f"ok {len(want)} first-run answer(s) in place{note}")
        return 0
    print(f"{len(bad)} first-run answer(s) not in place — the next Claude start asks{note}")
    for line in bad:
        print(line)
    return 1


def read_object(path):
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def write_if_changed(path, old, new):
    if old == new:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w") as stream:
            json.dump(new, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return True


def main(home):
    state_path = home / ".claude.json"
    state = read_object(state_path)
    desired = dict(state)
    for key, value in first_run_defaults().items():
        desired.setdefault(key, value)
    desired.setdefault("theme", "dark")

    settings_path = home / ".claude" / "settings.json"
    settings = read_object(settings_path)
    merged = dict(settings)
    if not isinstance(settings.get("permissions", {}), dict):
        raise ValueError(f"{settings_path} has invalid permissions.allow")
    permissions = dict(settings.get("permissions", {}))
    if not isinstance(permissions.get("allow", []), list):
        raise ValueError(f"{settings_path} has invalid permissions.allow")
    allow = list(permissions.get("allow", []))
    for rule in ALLOW:
        if rule not in allow:
            allow.append(rule)
    permissions["allow"] = allow
    merged["permissions"] = permissions

    # Validate both inputs before changing either file.
    state_changed = write_if_changed(state_path, state, desired)
    settings_changed = write_if_changed(settings_path, settings, merged)
    print(f"onboard: claude.json {'seeded' if state_changed else 'kept'}; settings.json {'allowed' if settings_changed else 'kept'}")


if __name__ == "__main__":
    args = sys.argv[1:]
    checking = args[:1] == ["--check"]
    if checking:
        args = args[1:]
    if len(args) != 1:
        sys.exit("usage: fleet-onboard-defaults.py [--check] HOME")
    try:
        if checking:
            sys.exit(check(Path(args[0])))
        main(Path(args[0]))
    except (OSError, ValueError, TypeError) as exc:
        if checking:
            print(f"unreadable {exc}")
            sys.exit(2)
        sys.exit(f"fleet-onboard-defaults: {exc}")
