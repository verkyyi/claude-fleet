#!/usr/bin/env python3
# fleet-restore-resolve.py — stdin: TAB rows "window_name<TAB>worktree_path<TAB>issue"
# stdout: "WIN<TAB>name<TAB>path<TAB>claude-session-id<TAB>issue" for each work window.
# The session id is the stem of the NEWEST transcript in that worktree's project
# dir (same slug convention the collector uses), or '-' if none exists.
import sys, glob, os, re

PANELS = {"plan", "dash", "backlog"}

for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    name = parts[0] if len(parts) > 0 else ""
    path = parts[1] if len(parts) > 1 else ""
    issue = parts[2] if len(parts) > 2 and parts[2] else "-"
    if not name or not path or name in PANELS:
        continue
    slug = re.sub(r"[/._]", "-", path)
    files = glob.glob(os.path.expanduser(f"~/.claude/projects/{slug}/*.jsonl"))
    sid = "-"
    if files:
        newest = max(files, key=os.path.getmtime)
        sid = os.path.basename(newest)[:-6]  # strip .jsonl
    print(f"WIN\t{name}\t{path}\t{sid}\t{issue}")
