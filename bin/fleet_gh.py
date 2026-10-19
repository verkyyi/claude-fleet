"""fleet_gh.py — the GitHub layer for a Python caller (issue #4842, EPIC #4839 C3).

A Python program never builds a `["gh", …]` argv of its own: it asks for one here,
and the call runs `bin/fleet-gh.sh run …` — fleet_gh in bin/fleet-gh-lib.sh, the
one judge of «GitHub 不通» (FLEET_GH_TIMEOUT seconds, the shared gh-down marker,
a FLEET_FORGE=none repo refused). Nothing here decides anything itself.

    argv(*args, gh=None)   → the argv to hand subprocess
    env(gh=None)           → os.environ, plus FLEET_GH_BIN when a caller's own test
                             seam names a fake gh (it then rides the layer too)
    run(*args, gh=None, timeout=None, **kw) → subprocess.CompletedProcess

DOWN (75): GitHub unreachable or rate-limited — «not now», never a failure.
NOFORGE (78): the repo has no GitHub.
"""
import os
import subprocess
from pathlib import Path

BIN = Path(__file__).resolve().parent
DOWN = 75
NOFORGE = 78
# the layer's own clock is FLEET_GH_TIMEOUT (15 s); this outer bound only catches
# a layer that could not start
TIMEOUT = 60


def argv(*args):
    return ["bash", str(BIN / "fleet-gh.sh"), "run", *map(str, args)]


def env(gh=None, base=None):
    e = dict(os.environ if base is None else base)
    if gh:
        e["FLEET_GH_BIN"] = gh
    return e


def run(*args, gh=None, timeout=None, **kw):
    kw.setdefault("env", env(gh))
    return subprocess.run(argv(*args), timeout=timeout or TIMEOUT, **kw)
