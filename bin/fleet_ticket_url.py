#!/usr/bin/env python3
# fleet_ticket_url.py — a module (imported, not run); the line above keeps the
# client installer's "a script starts with #" check happy.
"""Where a person reads issue N of a repo (issue #3596) — for the python callers
(the sidebar's ⌘P list, the top bar, `fleet ls`'s batch row): its GitHub page.

The hub ticket pages left with issue #4898 (the hub task record is the only
ticket), so the answer is the GitHub link these callers always spelled, with no
shell started — the same one fleet_ticket_url in the machine's library prints.
"""
import re

_REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


def github_url(repo, n):
    return "https://github.com/%s/issues/%s" % (repo, n)


def ticket_url(repo, n, sess=None):
    """The page for issue n of repo, "" when there is none to show."""
    n = str(n or "")
    if not (_REPO_RE.fullmatch(repo or "") and n.isdigit() and not n.startswith("0")):
        return ""
    return github_url(repo, n)
