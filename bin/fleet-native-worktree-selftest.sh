#!/bin/bash
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = --native-cli ]; then
  shift
  exec python3 "$BIN/fleet-native-worktree-cli-selftest.py" "$@"
fi
ROOT="${1:-$(cd "$BIN/.." && pwd)}"
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
passed = 0


def check(condition, message):
    global passed
    if not condition:
        raise AssertionError(message)
    passed += 1
    print("ok " + message, flush=True)


with tempfile.TemporaryDirectory(prefix="fleet-native-worktree-") as temporary:
    root = Path(temporary).resolve()
    home = root / "home"
    home.mkdir()
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(home),
        "FLEET_CONF_DIR": str(home / "fleet-conf"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_AUTHOR_NAME": "Fleet fixture",
        "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
        "GIT_COMMITTER_NAME": "Fleet fixture",
        "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
    }

    def run(arguments, cwd=None, data=None):
        return subprocess.run(arguments, cwd=cwd, env=environment, input=data,
                              text=True, capture_output=True, timeout=30)

    def git(*arguments):
        result = run(["git", *map(str, arguments)])
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    main = root / "repository"
    git("init", "--quiet", main)
    (main / "tracked.txt").write_text("original\n", encoding="utf-8")
    git("-C", main, "add", "tracked.txt")
    git("-C", main, "commit", "--quiet", "-m", "fixture")
    external = root / "agent-managed" / "opaque-id"
    nested = main / ".claude" / "worktrees" / "opaque-id"
    git("-C", main, "worktree", "add", "--quiet", "--detach", external)
    git("-C", main, "worktree", "add", "--quiet", "--detach", nested)
    environment["FLEET_MAIN"] = str(main)

    for worktree in (external, nested):
        common = git("-C", worktree, "rev-parse", "--git-common-dir")
        check((worktree / common).resolve() == main / ".git",
              "real Git worktree shares expected repository: " + worktree.name)

    def guard(directory, target):
        payload = {
            "tool_name": "apply_patch",
            "cwd": str(directory),
            "tool_input": {"command": "*** Begin Patch\n*** Update File: " + str(target)
                           + "\n@@\n-original\n+changed\n*** End Patch"},
        }
        return run([sys.executable, str(source / "hooks/base-readonly-guard.py")],
                   cwd=directory, data=json.dumps(payload)).returncode

    check(guard(external, "tracked.txt") == 0,
          "external opaque worktree passes the base-readonly guard")
    check(guard(external, main / "tracked.txt") == 2,
          "absolute write to base remains blocked")
    check(guard(nested, "tracked.txt") == 2,
          "unadapted nested native layout remains blocked, not silently trusted")
    fake = main / ".codex" / "worktrees" / "unregistered"
    fake.mkdir(parents=True)
    (fake / ".git").write_text("gitdir: missing\n", encoding="utf-8")
    check(guard(fake, "tracked.txt") == 2,
          "a directory named like a native worktree grants no exception")
    (external / "base-link").symlink_to(main, target_is_directory=True)
    check(guard(external, "base-link/tracked.txt") == 2,
          "symlink into protected base remains blocked")

    seat = run(["bash", "-c",
                'source "$1"; fleet_pane_fmt() { printf "73|%s" "${BOUND_WORKTREE:-}"; }; fleet_seat',
                "_", str(source / "bin/fleet-lib.sh")], cwd=external)
    check(seat.returncode == 0 and not seat.stdout.strip(),
          "opaque worktree name without a path binding grants no worker seat")
    environment["BOUND_WORKTREE"] = str(external)
    seat = run(["bash", "-c",
                'source "$1"; fleet_pane_fmt() { printf "73|%s" "$BOUND_WORKTREE"; }; fleet_seat',
                "_", str(source / "bin/fleet-lib.sh")], cwd=external)
    check(seat.returncode == 0 and seat.stdout.strip() == "worker",
          "existing explicit worktree binding recognises an opaque worker path")
    key = run(["bash", "-c", 'source "$1"; fleet_scratch_key "$2"',
               "_", str(source / "bin/fleet-lib.sh"), str(external)])
    check(key.returncode == 0 and not key.stdout.strip(),
          "legacy scratch key does not fabricate an ID for a native directory")
    check((main / "tracked.txt").read_text(encoding="utf-8") == "original\n",
          "fixture base content remains unchanged")

print("native-worktree layout selftest: %s checks; not native CLI or panel acceptance" % passed)
PY
