#!/usr/bin/env python3
"""Exercise the real spawner and brief against local Git, never live tmux/GitHub."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

BIN = Path(sys.argv[1])


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, check=True, **kwargs).stdout


def check(value, label):
    if not value:
        raise AssertionError(label)
    print("ok  " + label, flush=True)


with tempfile.TemporaryDirectory(prefix="issue-cache-selftest-") as tmp:
    root = Path(tmp).resolve()
    main = root / "main"
    fake = root / "fakebin"
    fake.mkdir()
    conf = root / "conf"
    conf.mkdir()
    run(["git", "init", "-q", str(main)])
    run(["git", "-C", str(main), "-c", "user.name=Test", "-c", "user.email=test@example.com",
         "commit", "--allow-empty", "-qm", "fixture"])
    run(["git", "-C", str(main), "branch", "-M", "master"])
    run(["git", "-C", str(main), "remote", "add", "origin", str(main)])
    log = root / "gh.log"
    windows = root / "windows"
    fixture = root / "issue.json"
    original = {"number": 459, "state": "OPEN", "title": "缓存 issue 数据",
                "url": "https://github.com/acme/widgets/issues/459", "body": "BODY\n多行",
                "labels": [{"name": "bug"}], "assignees": [],
                "comments": [{"author": {"login": "reviewer"}, "body": "COMMENT", "createdAt": "today"}]}
    fixture.write_text(json.dumps(original))
    (fake / "gh").write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
with open(os.environ['GH_LOG'], 'a') as f: f.write(json.dumps(args)+'\\n')
if args[:2] == ['issue', 'view']:
    if os.environ.get('VIEW_FAIL') == '1': sys.exit(1)
    data = pathlib.Path(os.environ['FIXTURE']).read_text()
    flag = '--jq' if '--jq' in args else '-q'
    if flag in args:
        sys.exit(subprocess.run(['jq', '-r', args[args.index(flag)+1]], input=data, text=True).returncode)
    print(data)
elif args[:2] == ['pr', 'list']: print(os.environ.get('OPEN_PRS', '0'))
elif args[:2] == ['issue', 'edit']: sys.exit(int(os.environ.get('EDIT_FAIL', '0')))
''')
    (fake / "tmux").write_text('''#!/bin/bash
if [ "${1:-}" = -L ]; then shift 2; fi
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{session_name}'*) echo testfleet ;;
      *'#{@issue}'*) echo 459 ;;
    esac ;;
  new-window) echo "$*" >> "$WINDOWS"; echo @9 ;;
esac
exit 0
''')
    for path in fake.iterdir():
        path.chmod(0o755)
    env = dict(os.environ, PATH=f"{fake}:{os.environ['PATH']}",
               FLEET_CONF_DIR=str(conf), FLEET_MAIN=str(main), FLEET_REPO="acme/widgets",
               FLEET_BASE_BRANCH="master", FLEET_GLOBAL_MAX_SESSIONS="0",
               FLEET_MAX_SESSIONS="0", FLEET_C=str(root / "cache"),
               TMPDIR=str(root), GH_LOG=str(log), FIXTURE=str(fixture), WINDOWS=str(windows))
    wt = root / "main-issue-459"

    def spawn(*args, **extra):
        return run(["bash", str(BIN / "dash-issue-session.sh"), "459", "testfleet", *args],
                   env=dict(env, **extra), cwd=root)

    def brief(*args, cwd=wt):
        log.write_text("")
        output = run(["bash", str(BIN / "fleet-claim-brief.sh"), *args], env=env, cwd=cwd)
        return output, log.read_text()

    spawn()
    cache = Path(run(["git", "-C", str(wt), "rev-parse", "--absolute-git-dir"]).strip()) / "fleet-issue.json"
    check(cache.is_file(), "spawn writes a per-worktree snapshot")
    data = json.loads(cache.read_text())
    check(data["issue"] == original and data["preclaimed"], "original JSON preserved; successful assignment recorded")
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    check(sum(call[:2] == ["issue", "view"] for call in calls) == 1, "spawn reuses one issue read for dedup, title and snapshot")
    check("缓存-issue-数据" in windows.read_text(), "fetched title names the window")
    check(cache.stat().st_mode & 0o777 == 0o600, "snapshot private mode 0600")
    check(not run(["git", "-C", str(wt), "status", "--porcelain"]), "snapshot cannot enter worktree status")
    run(["git", "-C", str(wt), "add", "-A"])
    check(not run(["git", "-C", str(wt), "diff", "--cached", "--name-only"]), "git add -A cannot stage snapshot")
    check(not (main / ".git" / "fleet-issue.json").exists(), "base has no issue snapshot")
    output, calls = brief()
    check(not calls and "source: spawn snapshot (" in output and "COMMENT" in output,
          "fresh brief reads body and comments with ZERO gh calls")
    check("claim: HELD by @me" in output and "claim: UNCLAIMED" not in output,
          "pre-edit empty assignees do not trigger duplicate assignment")
    check("===== charter" in output and "===== implementation directive" in output,
          "cache keeps the unconditional charter and directive")
    output, calls = brief("--no-comments")
    check(not calls and "COMMENT" not in output, "cached --no-comments omits comments")
    (wt / "subdir").mkdir()
    output, calls = brief(cwd=wt / "subdir")
    check(not calls and "spawn snapshot" in output, "brief finds snapshot from worktree subdirectory")

    # Corrupt identity, content and timestamps independently; each must fetch gh.
    mutations = [
        ("stale", lambda d: d.update(fetched_at=int(time.time())-121)),
        ("future", lambda d: d.update(fetched_at=int(time.time())+60)),
        ("repo", lambda d: d.update(repo="other/repo")),
        ("worktree", lambda d: d.update(worktree=str(main))),
        ("number", lambda d: d["issue"].update(number=460)),
        ("schema", lambda d: d.update(version=99)),
        ("unconfirmed", lambda d: d.update(preclaimed=False)),
        ("missing comments", lambda d: d["issue"].pop("comments")),
        ("invalid comment", lambda d: d["issue"].update(comments=[{"body": 42}])),
    ]
    for label, mutate in mutations:
        bad = json.loads(json.dumps(data))
        mutate(bad)
        cache.write_text(json.dumps(bad))
        output, calls = brief()
        check(len(calls.splitlines()) == 1 and "spawn snapshot" not in output and "BODY" in output,
              f"{label} snapshot falls back to one gh read")
    for label, value in (("corrupt", "{broken"), ("wrong type", "[]")):
        cache.write_text(value)
        output, calls = brief()
        check(len(calls.splitlines()) == 1 and "BODY" in output, f"{label} snapshot falls back")
    cache.unlink()
    (wt / ".fleet").mkdir()
    (wt / ".fleet" / "issue.json").write_text(json.dumps(data))
    output, calls = brief()
    check(len(calls.splitlines()) == 1 and "spawn snapshot" not in output,
          "repo .fleet/issue.json cannot masquerade as machine-local snapshot")
    cache.symlink_to(wt / ".fleet" / "issue.json")
    output, calls = brief()
    check(len(calls.splitlines()) == 1, "symlink snapshot falls back")
    cache.unlink()

    for label, args, extra in [
        ("force", ["--force"], {}),
        ("dedup opt-out", [], {"FLEET_PRESPAWN_DEDUP": "0"}),
        ("tail-only", [], {"FLEET_SPAWN_TAIL": "testfleet"}),
        ("failed assignment", [], {"EDIT_FAIL": "1"}),
        ("failed read", [], {"VIEW_FAIL": "1"}),
    ]:
        cache.write_text(json.dumps(data))
        spawn(*args, **extra)
        check(not cache.exists(), f"{label} spawn invalidates old snapshot")
        output, calls = brief()
        check(len(calls.splitlines()) == 1, f"{label} brief falls back")

    # A deterministic write failure even when tests run as root: target is a dir.
    cache.mkdir()
    before = len(windows.read_text().splitlines())
    spawn()
    check(len(windows.read_text().splitlines()) == before+1, "cache clear/write failure cannot wedge spawn")
    output, calls = brief()
    check(len(calls.splitlines()) == 1, "unreadable snapshot falls back")
    cache.rmdir()
    spawn()
    check(cache.is_file(), "next successful spawn recovers cache")

    # The enlarged gh read still refuses all three kinds of claimed issue.
    for label, fields, extra in [
        ("assigned", {"assignees": [{"login": "peer"}]}, {}),
        ("closed", {"state": "CLOSED"}, {}),
        ("open PR", {}, {"OPEN_PRS": "1"}),
    ]:
        fixture.write_text(json.dumps(dict(original, **fields)))
        before = windows.read_text()
        result = subprocess.run(
            ["bash", str(BIN / "dash-issue-session.sh"), "459", "testfleet"],
            env=dict(env, **extra), cwd=root, text=True, capture_output=True)
        check(result.returncode == 3 and windows.read_text() == before,
              f"full JSON gate refuses {label} without spawning")
    fixture.write_text(json.dumps(original))

    # gh absence should not prevent a fresh local brief.
    (fake / "gh").unlink()
    (fake / "gh").write_text("#!/bin/sh\nexit 99\n")
    (fake / "gh").chmod(0o755)
    output, calls = brief()
    check(not calls and "spawn snapshot" in output, "fresh cache works with unavailable gh")
    shutil.rmtree(wt / ".fleet")
    print("fleet-issue-cache-selftest: all checks passed", flush=True)
