#!/usr/bin/env python3
# fleet-restore-resolve.py — stdin: TAB rows "window_name<TAB>worktree_path<TAB>issue"
# stdout: "WIN<TAB>name<TAB>path<TAB>claude-session-id<TAB>issue" for each work window.
# The session id is the stem of the NEWEST transcript in that worktree's project
# dir (same slug convention the collector uses), or '-' if none exists.
#
# One special input: a row whose name is the sentinel "__STEWARD__" is the fleet's
# steward hub pane (issue #143). It lives in the 'plan' window — a PANEL that WIN
# rows exclude — so its transcript would never be captured. For it we emit a
# "STEWARD<TAB>path<TAB>id" row instead of a WIN row, so restore() rebuilds the
# steward via steward-session.sh (`claude --resume`) rather than as a work window.
import sys, glob, os, re

PANELS = {"plan", "dash", "backlog"}
STEWARD = "__STEWARD__"


def newest_sid(path):
    """Stem of the newest transcript in `path`'s project dir, or '-' if none.

    CAVEAT (steward, issue #143): a worker's `path` is its OWN issue-<N> worktree,
    so it holds exactly one session's transcripts — newest == that worker's. The
    steward's `path` is the SHARED base checkout (FLEET_MAIN); if something else
    (e.g. an ad-hoc `claude` the user ran there) wrote a newer transcript, this
    picks THAT up instead. The resume then loads the wrong conversation. The
    restore fallback only catches an *invalid* id, not a valid-but-wrong one.
    Acceptable for now (matches the worker heuristic and the issue's spec); a
    fully robust fix would capture the steward pane's own session id directly
    (SessionStart hook, or matching the pane's claude PID to its open transcript).
    """
    slug = re.sub(r"[/._]", "-", path)
    files = glob.glob(os.path.expanduser(f"~/.claude/projects/{slug}/*.jsonl"))
    if not files:
        return "-"
    newest = max(files, key=os.path.getmtime)
    return os.path.basename(newest)[:-6]  # strip .jsonl


for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    name = parts[0] if len(parts) > 0 else ""
    path = parts[1] if len(parts) > 1 else ""
    issue = parts[2] if len(parts) > 2 and parts[2] else "-"
    if not name or not path:
        continue
    if name == STEWARD:
        print(f"STEWARD\t{path}\t{newest_sid(path)}")
        continue
    if name in PANELS:
        continue
    print(f"WIN\t{name}\t{path}\t{newest_sid(path)}\t{issue}")
