#!/usr/bin/env python3
"""Short-lived spawn issue snapshots (#459), in linked-worktree Git metadata.

No repo .fleet/ content is read and no ignore/config file is modified. A cache
miss (including missing Python at the shell call site) always falls back to gh.
Only a successful spawn pre-claim writes a snapshot; its original assignees are
kept intact, with the confirmed @me assignment reported separately in the brief.
"""

import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

MAX_AGE = 120


def cache_path(worktree):
    def git(*args):
        return subprocess.check_output(
            ["git", "-C", worktree, "rev-parse", *args],
            stderr=subprocess.DEVNULL, text=True, timeout=5,
        ).strip()

    root = Path(git("--show-toplevel"))
    # Only linked worktrees: never write the base checkout's own .git directory.
    if not (root / ".git").is_file():
        raise ValueError("not a linked worktree")
    gitdir = Path(git("--absolute-git-dir"))
    if not gitdir.is_absolute() or not gitdir.is_dir():
        raise ValueError("missing worktree metadata")
    return gitdir / "fleet-issue.json", str(root.resolve())


def validate(issue, number):
    if not isinstance(issue, dict) or type(issue.get("number")) is not int:
        raise ValueError("invalid issue")
    if issue["number"] != int(number) or issue.get("state") != "OPEN":
        raise ValueError("wrong issue or state")
    for key in ("title", "url", "body"):
        if not isinstance(issue.get(key), str):
            raise ValueError("missing issue text")
    for key, fields in (("labels", ("name",)), ("assignees", ("login",)),
                        ("comments", ("body", "createdAt"))):
        if not isinstance(issue.get(key), list):
            raise ValueError("missing issue list")
        for row in issue[key]:
            if not isinstance(row, dict) or any(not isinstance(row.get(f), str) for f in fields):
                raise ValueError("invalid issue list")
            if key == "comments" and row.get("author") is not None:
                author = row["author"]
                if not isinstance(author, dict) or not isinstance(author.get("login"), str):
                    raise ValueError("invalid author")


def age_at(fetched_at):
    age = time.time() - float(fetched_at)
    if not math.isfinite(age) or not 0 <= age <= MAX_AGE:
        raise ValueError("stale snapshot")
    return int(age)


def render(issue, age, comments):
    labels = ", ".join(row["name"] for row in issue["labels"]) or "-"
    rows = [f"source: spawn snapshot ({age}s old; expires after {MAX_AGE}s). Re-read GitHub for newer comments.",
            f"title: {issue['title']}", f"state: {issue['state']}   labels: {labels}",
            "assignees: @me (assignment confirmed at spawn, after this snapshot)",
            f"url: {issue['url']}", "", "----- issue body -----", issue["body"] or "(empty)"]
    if comments:
        rows += ["", f"----- comments ({len(issue['comments'])}) -----"]
        for row in issue["comments"]:
            author = (row.get("author") or {}).get("login", "?")
            rows.append(f"--- @{author} · {row['createdAt']} ---\n{row['body']}")
        if not issue["comments"]:
            rows.append("(none)")
    rows += ["", "claim: HELD by @me — assignment confirmed at spawn. Do NOT re-assign."]
    return "\n".join(rows)


def main():
    action, worktree = sys.argv[1:3]
    path, root = cache_path(worktree)
    if action == "clear":
        path.unlink(missing_ok=True)
        return
    repo, number, option = sys.argv[3:6]
    if action == "write":
        issue = json.load(sys.stdin)
        validate(issue, number)
        if issue["assignees"]:
            raise ValueError("snapshot was already claimed")
        age_at(option)
        data = {"version": 1, "repo": repo, "worktree": root, "fetched_at": int(option),
                "preclaimed": True, "issue": issue}
        # tempfile mode 0600 + replace: readers see either the whole dump or a miss.
        fd, tmp = tempfile.mkstemp(prefix=".fleet-issue-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(data, stream)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    elif action == "read":
        if path.is_symlink():
            raise ValueError("symlink snapshot")
        data = json.loads(path.read_text())
        if (data["version"] != 1 or data["repo"] != repo or data["worktree"] != root
                or data["preclaimed"] is not True):
            raise ValueError("snapshot identity mismatch")
        validate(data["issue"], number)
        print(render(data["issue"], age_at(data["fetched_at"]), option == "1"))
    else:
        raise ValueError("unknown action")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit(1)
