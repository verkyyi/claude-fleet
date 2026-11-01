#!/usr/bin/env python3
# selftest-entry
"""fleet-cache-reclaim-selftest.py — bin/fleet-cache-reclaim.py touches only its
fixed list of rebuildable caches, under a sandbox HOME (task T1253):

  A  --plan names go-build, the older playwright builds, yarn, npm and the pycache
     prefix; never the newest playwright build, never another cache
  B  --run empties them: older browsers gone (one a process names in its argv
     kept), yarn emptied (dir kept), npm's _cacache gone, .pyc older than 7 days
     gone and a fresh one kept; a neighbour cache and the newest browsers untouched
  C  a second --run while one holds the lock exits 0 and does nothing
"""
import fcntl
import os
import subprocess
import sys
import tempfile
import time

BIN = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BIN, "fleet-cache-reclaim.py")
FAILS = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        FAILS.append(what)


def put(path, data=b"x" * 4096, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    if mtime:
        os.utime(path, (mtime, mtime))


def run(home, *args):
    env = {"HOME": home, "PATH": "/usr/bin:/bin", "FLEET_CONF_DIR": os.path.join(home, "conf")}
    return subprocess.run([sys.executable, SRC] + list(args), env=env, capture_output=True, text=True, timeout=120)


def main():
    home = tempfile.mkdtemp(prefix="fcr-selftest.")
    home = os.path.realpath(home)
    cache = os.path.join(home, "Library", "Caches") if sys.platform == "darwin" else os.path.join(home, ".cache")
    pw = os.path.join(cache, "ms-playwright")
    old = time.time() - 30 * 86400
    put(os.path.join(cache, "go-build", "00", "a-d"))
    for n in ("chromium-1217", "chromium-1248", "chromium-1300", "webkit-2368", "webkit-2370", "ffmpeg-1011"):
        put(os.path.join(pw, n, "bin"))
    put(os.path.join(cache, "Yarn" if sys.platform == "darwin" else "yarn", "v6", "pkg"))
    put(os.path.join(home, ".npm", "_cacache", "index"))
    put(os.path.join(cache, "claude-fleet", "pycache", "a", "old.pyc"), mtime=old)
    put(os.path.join(cache, "claude-fleet", "pycache", "a", "new.pyc"))
    put(os.path.join(cache, "SomeApp", "keep.db"))
    held = os.path.join(pw, "chromium-1248")
    holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", held])
    try:
        # A
        p = run(home, "--plan")
        names = {}
        for line in p.stdout.splitlines():
            size, name, path = line.split("\t")
            names.setdefault(name, []).append(path)
        check(p.returncode == 0, "A --plan exits 0")
        check(set(names) == {"go-build", "playwright", "yarn", "npm", "pycache"},
              "A the fixed list, nothing else: %s" % sorted(names))
        check(sorted(os.path.basename(x) for x in names.get("playwright", []))
              == ["chromium-1217", "webkit-2368"],
              "A playwright: older builds only, the one in use kept: %s" % names.get("playwright"))
        # C
        os.makedirs(os.path.join(home, "conf", "diskguard"), exist_ok=True)
        lk = open(os.path.join(home, "conf", "diskguard", "cache-reclaim.lock"), "a")
        fcntl.flock(lk, fcntl.LOCK_EX)
        p = run(home, "--run")
        check(p.returncode == 0 and not p.stdout.strip() and os.path.isdir(os.path.join(home, ".npm", "_cacache")),
              "C a run under someone else's lock does nothing")
        fcntl.flock(lk, fcntl.LOCK_UN)
        lk.close()
        # B
        p = run(home, "--run")
        check(p.returncode == 0 and p.stdout.startswith("freed "), "B --run says what it freed: %r" % p.stdout)
        check(not os.path.exists(os.path.join(pw, "chromium-1217")) and not os.path.exists(os.path.join(pw, "webkit-2368")),
              "B older browser builds gone")
        check(all(os.path.isdir(os.path.join(pw, n)) for n in ("chromium-1248", "chromium-1300", "webkit-2370", "ffmpeg-1011")),
              "B newest builds and the one in use kept")
        yarn = os.path.join(cache, "Yarn" if sys.platform == "darwin" else "yarn")
        check(os.path.isdir(yarn) and not os.listdir(yarn), "B yarn emptied, its dir kept")
        check(not os.path.exists(os.path.join(home, ".npm", "_cacache")), "B npm's _cacache gone")
        check(not os.listdir(os.path.join(cache, "go-build")), "B go-build emptied (no go on PATH)")
        check(not os.path.exists(os.path.join(cache, "claude-fleet", "pycache", "a", "old.pyc"))
              and os.path.exists(os.path.join(cache, "claude-fleet", "pycache", "a", "new.pyc")),
              "B pycache: stale .pyc gone, fresh kept")
        check(os.path.exists(os.path.join(cache, "SomeApp", "keep.db")), "B a cache off the list untouched")
    finally:
        holder.kill()
        subprocess.run(["rm", "-rf", home])
    if FAILS:
        print("selftest FAIL: %d" % len(FAILS))
        return 1
    print("selftest OK: fleet-cache-reclaim.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
