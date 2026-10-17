#!/usr/bin/env python3
"""fleet_selftest_procs.py — the process half of the selftest reaper (issue #4360).

A selftest builds its sandbox under a mktemp root ($TMPDIR, /tmp) and starts real
processes from it — a supervisor, its account children, a planted stray copy. A
run killed before its teardown (or a teardown that misses one) leaves them as
PPID=1 orphans that run for days: on 2026-10-15 mini2 had
`…/T/fns.yyu6qtxh/Users/alice/.claude/fleet/bin/keep.sh` alive 2 days 15 hours,
its sandbox dir long gone. fleet-selftest-reap.sh removes the dirs and the tmux
servers; this removes the processes.

A tree is reaped only when ALL hold:
  1. its top is ours (uid) and a direct child of init (PPID=1) — the process that
     made it is gone; a test still running keeps its children under itself;
  2. the top's argv or cwd lies under a TEST ROOT: <mktemp root>/<name> with <name>
     matching one of the globs (default `fleet-selftest-root.* fleet-selftest-*
     *selftest* fns.* fns-*`; FLEET_SELFTEST_PROC_GLOBS replaces it);
  3. the top has lived at least <min-age> seconds (default 3600);
  4. no process OUTSIDE every candidate tree names that test root in its argv —
     a live creator (run-selftests.sh re-exec'd from its shadow root) spares
     everything under it;
  5. the top is not a tmux client/server we did not start from a test root, and
     not an agent (claude / codex).
Another login's processes (fleet-ci's runner jobs) are never looked at.

Usage: fleet_selftest_procs.py list|reap [--min-age SECS] [--grace SECS] [ROOT…]
  ROOTs default to $FLEET_SELFTEST_REAP_ROOTS, else "$TMPDIR /tmp".
Prints one line per tree: "reaped|would reap <top> age=<s>s root=<root> argv=<argv>".
Always exits 0.
"""
import fnmatch
import os
import signal
import subprocess
import sys
import time

DEFAULT_GLOBS = "fleet-selftest-root.* fleet-selftest-* *selftest* fns.* fns-*"
AGENTS = ("claude", "codex")


def secs(et):
    days = 0
    if "-" in et:
        d, et = et.split("-", 1)
        days = int(d) if d.isdigit() else 0
    parts = [int(x) if x.isdigit() else 0 for x in et.split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts[-3:]
    return days * 86400 + h * 3600 + m * 60 + s


def table():
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,uid=,etime=,command="],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    procs = {}
    for line in out.splitlines():
        f = line.split(None, 4)
        if len(f) < 5 or not f[0].isdigit() or not f[1].isdigit():
            continue
        procs[int(f[0])] = {"ppid": int(f[1]), "uid": f[2], "age": secs(f[3]), "argv": f[4]}
    return procs


def cwd_of(pids):
    """{pid: cwd} for <pids> — /proc on Linux, else one lsof."""
    res = {}
    if not pids:
        return res
    if os.path.isdir("/proc/self"):
        for p in pids:
            try:
                res[p] = os.readlink("/proc/%d/cwd" % p)
            except OSError:
                pass
        return res
    try:
        out = subprocess.run(["lsof", "-w", "-a", "-p", ",".join(str(p) for p in pids), "-d", "cwd", "-Fpn"],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return res
    cur = None
    for line in out.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            cur = int(line[1:])
        elif line.startswith("n") and cur is not None:
            res[cur] = line[1:]
    return res


class Roots:
    def __init__(self, roots, globs):
        self.prefixes = []
        for r in roots:
            r = r.rstrip("/")
            if not r:
                continue
            for v in {r, os.path.realpath(r)}:
                # $TMPDIR ends in `/`, so a path may carry `…/T//name` (selftest-shadow-root.sh)
                self.prefixes += [v + "/", v + "//"]
        self.globs = globs

    def find(self, text):
        """The first test root <text> names (a path inside it, or the root itself)."""
        for pre in self.prefixes:
            i = text.find(pre)
            while i >= 0:
                if i and text[i - 1] not in " =:'\"":  # `/tmp/` inside `/Users/x/tmp/` is not /tmp
                    i = text.find(pre, i + 1)
                    continue
                rest = text[i + len(pre):]
                name = (rest.split("/", 1)[0].split() or [""])[0]
                if name and any(fnmatch.fnmatchcase(name, g) for g in self.globs):
                    return (pre.rstrip("/") + "/" + name).replace("//", "/")
                i = text.find(pre, i + 1)
        return ""


def top_of(procs, pid):
    q, hops = pid, 0
    while q in procs and procs[q]["ppid"] > 1 and procs[q]["ppid"] in procs and hops < 128:
        q, hops = procs[q]["ppid"], hops + 1
    return q


def tree(procs, top):
    kids = {}
    for p, r in procs.items():
        kids.setdefault(r["ppid"], []).append(p)
    out, todo = [], [top]
    while todo:
        p = todo.pop()
        if p in out:
            continue
        out.append(p)
        todo += kids.get(p, [])
    return out


def candidates(roots, min_age):
    me, self_pids = str(os.getuid()), {os.getpid(), os.getppid()}
    procs = table()
    tops, need_cwd = {}, []
    for p, r in procs.items():
        if r["ppid"] != 1 or r["uid"] != me or p in self_pids or r["age"] < min_age:
            continue
        base = os.path.basename(r["argv"].split()[0]) if r["argv"] else ""
        if base in AGENTS or "/claude/versions/" in r["argv"]:
            continue
        root = roots.find(r["argv"])
        if root:
            tops[p] = root
        elif not (base == "tmux" or base.startswith("tmux:")):
            need_cwd.append(p)
    for p, c in cwd_of(need_cwd).items():
        root = roots.find(c.rstrip("/") + "/")
        if root:
            tops[p] = root
    if not tops:
        return procs, []
    # 4: a process outside every candidate tree that names the root is its creator
    inside = set()
    for t in tops:
        inside.update(tree(procs, t))
    owned = set()
    for p, r in procs.items():
        if p in inside or p in self_pids or r["uid"] != me:
            continue
        root = roots.find(r["argv"])
        if root:
            owned.add(root)
    return procs, [(t, tops[t]) for t in sorted(tops) if tops[t] not in owned]


def kill_tree(top, grace):
    """TERM the tree, wait <grace>, then KILL whatever of it is left — the first
    round's members too (a TERMed top's children are reparented, off its tree)."""
    seen = set()
    for rnd in range(3):
        procs = table()
        live = set(p for p in seen if p in procs)
        if top in procs:
            live.update(tree(procs, top))
        if not live:
            break
        seen |= live
        sig = signal.SIGTERM if rnd == 0 else signal.SIGKILL
        for p in sorted(live):
            try:
                os.kill(p, sig)
            except OSError:
                pass
        time.sleep(grace if rnd == 0 else 0.2)


def main(argv):
    mode = argv[0] if argv else "list"
    min_age, grace, roots = 3600, 2.0, []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--min-age" and i + 1 < len(argv):
            min_age = int(argv[i + 1]) if argv[i + 1].isdigit() else min_age
            i += 1
        elif a == "--grace" and i + 1 < len(argv):
            try:
                grace = float(argv[i + 1])
            except ValueError:
                pass
            i += 1
        else:
            roots.append(a)
        i += 1
    if not roots:
        roots = (os.environ.get("FLEET_SELFTEST_REAP_ROOTS")
                 or "%s /tmp" % (os.environ.get("TMPDIR") or "/tmp")).split()
    globs = (os.environ.get("FLEET_SELFTEST_PROC_GLOBS") or DEFAULT_GLOBS).split()
    procs, cands = candidates(Roots(roots, globs), min_age)
    verb = "reaped" if mode == "reap" else "would reap"
    for top, root in cands:
        r = procs.get(top, {})
        if mode == "reap":
            kill_tree(top, grace)
        print("%s %d age=%ds root=%s argv=%.160s" % (verb, top, r.get("age", 0), root, r.get("argv", "")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # a reaper must not fail loud
        print("fleet_selftest_procs: %s" % e, file=sys.stderr)
        sys.exit(0)
