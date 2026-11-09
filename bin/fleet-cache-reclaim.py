#!/usr/bin/env python3
"""fleet-cache-reclaim.py — give back the disk that rebuildable tool caches hold
(task T1253).

The diskguard tick runs `--run` (detached, at most once every 6 hours) when free
space drops under FLEET_DISK_WARN_GB. One machine went 36 hours under the floor
while ~13 GB sat in caches any next build fills again. Only caches on the fixed
list below are touched, all of this login's own; each is something a tool
rebuilds on demand (a later build is slower, never broken):

  go-build    the Go build cache (`go clean -cache`, else its contents)
  playwright  every browser build but the newest of each kind; a build a running
              process names in its argv is kept
  yarn        Yarn's package cache
  npm         npm's content cache (~/.npm/_cacache)
  uv          uv's cache, through `uv cache clean` only (it holds uv's lock)
  pycache     the fleet's bytecode prefix: .pyc files untouched for 7 days

  fleet-cache-reclaim.py --plan            print `<bytes>\\t<name>\\t<path>` per target
  fleet-cache-reclaim.py --run             reclaim; one summary line on stdout

One run at a time (an flock under the diskguard dir); a second exits 0 quietly.
HOME is read from the environment, so a sandbox HOME touches only the sandbox.
"""
import fcntl
import os
import re
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
DARWIN = sys.platform == "darwin"
CACHE = os.path.join(HOME, "Library", "Caches") if DARWIN else (
    os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"))
PYC_KEEP_SECS = 7 * 86400


def du(path):
    total = 0
    for root, dirs, files in os.walk(path, onerror=lambda e: None):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_blocks * 512
            except OSError:
                pass
    return total


def tool(name):
    return shutil.which(name)


def gocache():
    go = tool("go")
    if go:
        try:
            out = subprocess.run([go, "env", "GOCACHE"], capture_output=True, text=True, timeout=20).stdout.strip()
            if out and out != "off":
                return out
        except (OSError, subprocess.SubprocessError):
            pass
    return os.path.join(CACHE, "go-build")


def argv_all():
    try:
        return subprocess.run(["ps", "-A", "-o", "command="], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None


def playwright_old(root):
    """Every browser dir but the highest-numbered of its kind (chromium-1248 over
    chromium-1217); None when the process table cannot be read (keep everything)."""
    try:
        names = os.listdir(root)
    except OSError:
        return []
    best = {}
    for n in names:
        m = re.match(r"^(.+)-(\d+)$", n)
        if m and os.path.isdir(os.path.join(root, n)):
            kind, ver = m.group(1), int(m.group(2))
            best.setdefault(kind, []).append((ver, n))
    procs = argv_all()
    if procs is None:
        return None
    old = []
    for vers in best.values():
        vers.sort()
        for _, n in vers[:-1]:
            p = os.path.join(root, n)
            if p not in procs:
                old.append(p)
    return old


def targets():
    """(name, path, how) for each cache present; how = rm | contents | cmd:<argv> | pyc."""
    out = []
    g = gocache()
    if os.path.isdir(g):
        out.append(("go-build", g, "cmd:go clean -cache" if tool("go") else "contents"))
    pw = os.environ.get("PLAYWRIGHT_BROWSERS_PATH") or os.path.join(CACHE, "ms-playwright")
    if os.path.isdir(pw):
        for p in playwright_old(pw) or []:
            out.append(("playwright", p, "rm"))
    y = os.path.join(CACHE, "Yarn" if DARWIN else "yarn")
    if os.path.isdir(y):
        out.append(("yarn", y, "contents"))
    n = os.path.join(HOME, ".npm", "_cacache")
    if os.path.isdir(n):
        out.append(("npm", n, "rm"))
    uv = os.path.join(HOME, ".cache", "uv") if DARWIN else os.path.join(CACHE, "uv")
    if os.path.isdir(uv) and tool("uv"):
        out.append(("uv", uv, "cmd:uv cache clean"))
    pyc = os.path.join(CACHE, "claude-fleet", "pycache")
    if os.path.isdir(pyc):
        out.append(("pycache", pyc, "pyc"))
    return out


def clear_contents(path):
    for n in os.listdir(path):
        p = os.path.join(path, n)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p, ignore_errors=True)
        else:
            try:
                os.unlink(p)
            except OSError:
                pass


def old_pyc(path, now):
    for root, dirs, files in os.walk(path, onerror=lambda e: None):
        for f in files:
            p = os.path.join(root, f)
            try:
                if now - os.lstat(p).st_mtime >= PYC_KEEP_SECS:
                    os.unlink(p)
            except OSError:
                pass


def reclaim(name, path, how):
    if how == "rm":
        shutil.rmtree(path, ignore_errors=True)
    elif how == "contents":
        clear_contents(path)
    elif how == "pyc":
        old_pyc(path, time.time())
    elif how.startswith("cmd:"):
        argv = how[4:].split()
        argv[0] = tool(argv[0]) or argv[0]
        try:
            subprocess.run(argv, capture_output=True, timeout=600)
        except (OSError, subprocess.SubprocessError):
            pass


def main(argv):
    if argv[:1] == ["--plan"]:
        for name, path, _ in targets():
            print("%d\t%s\t%s" % (du(path), name, path))
        return 0
    if argv[:1] != ["--run"]:
        print("usage: fleet-cache-reclaim.py --plan | --run", file=sys.stderr)
        return 2
    gdir = os.path.join(os.environ.get("FLEET_CONF_DIR") or os.path.join(HOME, ".config", "claude-fleet"), "diskguard")
    os.makedirs(gdir, exist_ok=True)
    lk = open(os.path.join(gdir, "cache-reclaim.lock"), "a")
    try:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0
    got = {}
    for name, path, how in targets():
        before = du(path)
        reclaim(name, path, how)
        got[name] = got.get(name, 0) + max(0, before - (du(path) if os.path.exists(path) else 0))
    parts = ["%s %dM" % (n, b >> 20) for n, b in got.items() if b]
    print("freed %dM%s" % (sum(got.values()) >> 20, (" · " + ", ".join(parts)) if parts else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
