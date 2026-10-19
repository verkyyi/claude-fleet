#!/usr/bin/env python3
"""go-ci-cache.py — what a Go CI job got from its restored cache, and what it
saves back (issue #4817, EPIC #4810 C7).

  go-ci-cache.py mark   [--state DIR]            before the build: list GOCACHE
  go-ci-cache.py report [--state DIR] [--log F]… after the tests: one Markdown
                                                 line — build entries reused / new,
                                                 test results taken from the cache
  go-ci-cache.py prune  [--state DIR]            before the save: drop every entry
                                                 this job did not use

Why prune: the repo's Actions cache is capped at 10 GB and was full already
(setup-go's ~170 MB a PR), so a part that saved its whole GOCACHE would only push
the others out. Go marks an entry it uses by moving its mtime forward when the
mtime is older than an hour (cmd/go/internal/cache: mtimeInterval), so after the
job an entry whose mtime is older than (job start − 1 h) was not used — it was
restored and sat there. Those go; what this job built or read stays, and is what
the next push of the same PR restores.

GOCACHE is `go env GOCACHE`; the state (the list taken at mark, its time) lives in
--state (default $RUNNER_TEMP or /tmp, `go-ci-cache/`).
"""
import argparse
import os
import re
import subprocess
import sys
import time

MTIME_INTERVAL = 3600  # cmd/go/internal/cache: an entry's mtime moves at most hourly


def gocache():
    env = os.environ.get("GOCACHE")
    if env:
        return env
    try:
        return subprocess.run(["go", "env", "GOCACHE"], capture_output=True, text=True,
                              check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def entries(root):
    """{path: (mtime, size)} for every cache entry file under root."""
    out = {}
    if not root or not os.path.isdir(root):
        return out
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            try:
                st = os.stat(p)
            except OSError:
                continue
            out[p] = (st.st_mtime, st.st_size)
    return out


def state_dir(arg):
    d = arg or os.path.join(os.environ.get("RUNNER_TEMP") or "/tmp", "go-ci-cache")
    os.makedirs(d, exist_ok=True)
    return d


def mark(st):
    root = gocache()
    ents = entries(root)
    with open(os.path.join(st, "before"), "w") as fh:
        for p in ents:
            fh.write(p + "\n")
    with open(os.path.join(st, "t0"), "w") as fh:
        fh.write("%d\n" % int(time.time()))
    print("go cache: %d entries restored (%.0f MB) in %s"
          % (len(ents), sum(s for _, s in ents.values()) / 1e6, root or "?"))


def load(st):
    try:
        with open(os.path.join(st, "before")) as fh:
            before = set(l.rstrip("\n") for l in fh if l.strip())
        with open(os.path.join(st, "t0")) as fh:
            t0 = int(fh.read().strip())
    except OSError:
        return None, None
    return before, t0


PKG_LINE = re.compile(r"^(ok|FAIL)\s+(\S+)(\s+(\S+))?")


def report(st, logs):
    before, t0 = load(st)
    if before is None:
        print("go cache: not marked")
        return
    ents = entries(gocache())
    cut = t0 - MTIME_INTERVAL
    reused = sum(1 for p in before if p in ents and ents[p][0] >= cut)
    new = sum(1 for p in ents if p not in before)
    # test results: a package line `ok  <pkg>  (cached)` came from the cache
    pkgs = cached = 0
    for f in logs:
        try:
            with open(f, errors="replace") as fh:
                for line in fh:
                    m = PKG_LINE.match(line)
                    if not m or "/" not in m.group(2):
                        continue
                    pkgs += 1
                    if m.group(4) == "(cached)":
                        cached += 1
        except OSError:
            pass
    used = reused + new
    rate = (100.0 * reused / used) if used else 0.0
    trate = (100.0 * cached / pkgs) if pkgs else 0.0
    print("go cache: build %d of %d entries reused (%.0f%%), %d new · test results %d of %d package(s) from the cache (%.0f%%)"
          % (reused, used, rate, new, cached, pkgs, trate))


def prune(st):
    before, t0 = load(st)
    if before is None:
        print("go cache: not marked — nothing pruned")
        return
    root = gocache()
    cut = t0 - MTIME_INTERVAL
    gone = gone_b = kept_b = 0
    for p, (mt, sz) in entries(root).items():
        # trim.txt / README are the cache's own; keep them
        if os.path.basename(p) in ("trim.txt", "README"):
            kept_b += sz
            continue
        if p in before and mt < cut:
            try:
                os.remove(p)
                gone += 1
                gone_b += sz
            except OSError:
                kept_b += sz
        else:
            kept_b += sz
    print("go cache: pruned %d unused entries (%.0f MB), saving %.0f MB"
          % (gone, gone_b / 1e6, kept_b / 1e6))


def main(argv):
    ap = argparse.ArgumentParser(prog="go-ci-cache.py")
    ap.add_argument("cmd", choices=["mark", "report", "prune"])
    ap.add_argument("--state")
    ap.add_argument("--log", action="append", default=[])
    a = ap.parse_args(argv)
    st = state_dir(a.state)
    if a.cmd == "mark":
        mark(st)
    elif a.cmd == "report":
        report(st, a.log)
    else:
        prune(st)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
