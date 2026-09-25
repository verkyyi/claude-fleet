#!/usr/bin/env python3
"""Seed Claude's first-run UI and the new login's wizard command permissions.

Only fleet-login-bootstrap.sh calls this, after install-apply and before fleet-up.
Existing logins never reach it. Existing values and allow rules are kept.
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
    desired.setdefault("hasCompletedOnboarding", True)
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
    if len(sys.argv) != 2:
        sys.exit("usage: fleet-onboard-defaults.py HOME")
    try:
        main(Path(sys.argv[1]))
    except (OSError, ValueError, TypeError) as exc:
        sys.exit(f"fleet-onboard-defaults: {exc}")
