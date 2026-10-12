#!/usr/bin/env python3
# fleet_ticket_url.py — a module (imported, not run); the line above keeps the
# client installer's "a script starts with #" check happy.
"""Where a person reads ticket N of a repo (issue #3596, EPIC #3570 C3) — for the
python callers (the sidebar's ⌘P list, the top bar, `fleet ls`'s batch row).

The ONE reader is fleet_ticket_url in bin/fleet-lib.sh; this asks it. Only when no
repo conf on this computer says FLEET_TICKETS=hub is the answer the GitHub page
straight away — byte for byte the link these callers spelled before, with no shell
started (a client-only computer has no repo confs at all).
"""
import glob
import os
import re
import subprocess
from pathlib import Path

BIN = Path(__file__).resolve().parent
_REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
_HUB_RE = re.compile(r"""^\s*(export\s+)?FLEET_TICKETS=["']?hub["']?\s*(#.*)?$""", re.M)


def _conf_dir():
    return os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")


def _any_hub_repo():
    """Does any fleet conf or repo overlay here put tickets on the hub?"""
    d = _conf_dir()
    for f in glob.glob(os.path.join(d, "fleets", "*", "repos", "*.conf")) + \
            glob.glob(os.path.join(d, "fleets", "*", "conf")) + glob.glob(os.path.join(d, "*.conf")):
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                if _HUB_RE.search(fh.read()):
                    return True
        except OSError:
            continue
    return False


def github_url(repo, n):
    return "https://github.com/%s/issues/%s" % (repo, n)


def ticket_url(repo, n, sess=None):
    """The page for ticket n of repo, "" when there is none to show."""
    n = str(n or "")
    if not (_REPO_RE.fullmatch(repo or "") and n.isdigit() and not n.startswith("0")):
        return ""
    if not _any_hub_repo():
        return github_url(repo, n)
    env = dict(os.environ)
    try:
        out = subprocess.run(
            ["bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_ticket_url "$2" "$3" "$4"', "_",
             str(BIN), repo, n, sess or ""],
            capture_output=True, text=True, timeout=10, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""
