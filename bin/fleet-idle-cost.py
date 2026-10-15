#!/usr/bin/env python3
"""fleet-idle-cost.py — the idle-cost sampler (issue #4355, EPIC #4354 C1).

How much the machine spends when nobody is working: over one window it counts
the processes started (the rate) and charges each one it saw to the nearest
ancestor that is still alive and at least a minute old (the ranking), and reads
the CPU time each long-lived process used. bin/fleet-idle-cost.sh decides
whether the machine is idle (fleet_idle_now) and calls this; nothing else should.

  fleet-idle-cost.py sample --secs 60 [--interval 0.2] [--exclude-pid PID]…
        [--top 10] --out FILE           measure; write the reading (JSON) to FILE
  fleet-idle-cost.py render FILE [--json] [--top N]
        print a reading: TSV (default) or the JSON as is

The rate is exact where the kernel keeps a fork counter (Linux /proc/stat
`processes`) and the PID delta elsewhere (macOS hands out PIDs in order): a
`sh -c 'echo $$'` before and after, wrap-around at the PID ceiling handled.
Either way the sampler's own forks (one per `ps`) and the processes it saw start
under an excluded tree (--exclude-pid: the measuring session) are taken off.
A 0.2 s `ps` misses the shortest-lived processes, so the ranking sees fewer than
the rate counts: the rate is the number, the ranking says who.

TSV lines (tab-separated):
  idle-cost  <rate>/s  window=<s>s  new=<n>  method=<pid|forks>  fleet_cpu=<pct>%  load=<1,5,15>  cores=<n>
  spawn      <rank>  <rate>/s  <seen>  <pid>  <who>
  cpu        <rank>  <pct>%    <cpu s> <pid>  <who>
"""
import json
import os
import re
import socket
import subprocess
import sys
import time

INTERP = {"sh", "bash", "zsh", "dash", "env", "python", "python3", "node", "perl",
          "ruby", "osascript", "nice", "nohup", "timeout"}
FLEET_RE = re.compile(r"claude-fleet|/\.claude/fleet|/fleet[-_]|ccquota|\btmux\b")


def secs_of(t):
    """ps etime / time ([[dd-]hh:]mm:ss[.cc]) → seconds."""
    t = t.strip()
    days = 0
    if "-" in t:
        d, t = t.split("-", 1)
        days = int(d or 0)
    total = 0.0
    for part in t.split(":"):
        total = total * 60 + float(part or 0)
    return days * 86400 + total


def _path_tokens(toks, i):
    """toks[i] glued to the next tokens while that names an existing path
    (`/Library/Application Support/…` is one argument) → (path, next index)."""
    t, j = toks[i], i + 1
    if t.startswith("/"):
        k, cur = i + 1, t
        while k < len(toks):
            cur = cur + " " + toks[k]
            k += 1
            if os.path.exists(cur):
                t, j = cur, k
    return t, j


def who(cmd):
    """A short label: the executable's basename, plus the script an interpreter
    runs, plus the start of the rest."""
    toks = cmd.split()
    if not toks:
        return "?"
    exe, i = _path_tokens(toks, 0)
    out = [os.path.basename(exe).lstrip("-")]
    if out[0].lower().rstrip("0123456789.") in INTERP:
        while i < len(toks):
            if toks[i].startswith("-") or "=" in toks[i]:
                i += 1
                continue
            arg, i = _path_tokens(toks, i)
            out.append(os.path.basename(arg))
            break
    rest = " ".join(toks[i:])[:40]
    return (" ".join(out) + ((" " + rest) if rest else ""))[:80]


class Sampler:
    def __init__(self, exclude):
        self.own = 0                 # processes this sampler started
        self.exclude = set(exclude) | {os.getpid()}
        self.ppid = {}               # pid → ppid at first sight (before any reparenting)
        self.cmd = {}
        self.first = None            # pids of the first sample
        self.last = {}               # pid → (etime, cputime) in the newest sample it was in
        self.seen_at = {}            # pid → monotonic time of the newest sample it was in
        self.cpu0 = {}               # pid → cputime in the first sample
        self.samples = 0

    def run(self, argv):
        self.own += 1
        return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True).stdout

    def sample(self):
        out = self.run(["ps", "-axo", "pid=,ppid=,etime=,time=,command="])
        now = time.monotonic()
        pids = set()
        for line in out.splitlines():
            f = line.split(None, 4)
            if len(f) < 4:
                continue
            try:
                pid, ppid = int(f[0]), int(f[1])
                et, ct = secs_of(f[2]), secs_of(f[3])
            except ValueError:
                continue
            pids.add(pid)
            if pid not in self.ppid:
                self.ppid[pid] = ppid
                self.cmd[pid] = f[4] if len(f) > 4 else ""
            self.last[pid] = (et, ct)
            self.seen_at[pid] = now
            if self.first is None:
                self.cpu0[pid] = ct
        if self.first is None:
            self.first = pids
        self.samples += 1
        return pids

    def excluded(self, pid):
        seen = set()
        while pid in self.ppid and pid not in seen:
            if pid in self.exclude:
                return True
            seen.add(pid)
            pid = self.ppid[pid]
        return pid in self.exclude


def fork_counter():
    try:
        with open("/proc/stat") as fh:
            for line in fh:
                if line.startswith("processes "):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def pid_max():
    try:
        with open("/proc/sys/kernel/pid_max") as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return 99999          # macOS PID_MAX


def probe_pid(s):
    return int(s.run(["sh", "-c", "echo $$"]).strip() or 0)


def cmd_sample(a):
    s = Sampler(a.exclude)
    forks0 = fork_counter()
    p0 = probe_pid(s) if forks0 is None else 0
    own0 = s.own
    t0 = time.monotonic()
    s.sample()
    alive = s.first
    while time.monotonic() - t0 < a.secs:
        time.sleep(a.interval)
        alive = s.sample()
    secs = time.monotonic() - t0
    own = s.own - own0
    if forks0 is not None:
        new = fork_counter() - forks0 - own
        method = "forks"
    else:
        p1 = probe_pid(s)
        d = p1 - p0 if p1 >= p0 else p1 + pid_max() - p0
        new = d - 1 - own        # strictly between the two probes, ours off
        method = "pid"
    end = time.monotonic()
    newp = [p for p in s.ppid if p not in s.first]
    mine = [p for p in newp if s.excluded(p)]
    new = max(0, new - len(mine))
    owners = {}
    for p in newp:
        if p in mine:
            continue
        a_ = s.ppid.get(p)
        top = p
        owner = None
        guard = set()
        while a_ is not None and a_ not in guard:
            guard.add(a_)
            if a_ in alive and a_ in s.last:
                age = s.last[a_][0] + (end - s.seen_at[a_])
                if age >= a.min_age:
                    owner = a_
                    break
            if a_ not in s.ppid:
                break
            top = a_
            a_ = s.ppid[a_]
        if owner is None:
            key = (0, "(祖先已退出) " + who(s.cmd.get(top, "")))
        elif owner == 1:
            key = (1, "launchd ← " + who(s.cmd.get(top, "")))
        else:
            key = (owner, who(s.cmd.get(owner, "")))
        owners[key] = owners.get(key, 0) + 1
    seen_total = sum(owners.values()) or 1
    spawn = sorted(owners.items(), key=lambda kv: -kv[1])[:a.top]
    rate = new / secs if secs else 0.0
    spawn_rows = [{"rank": i + 1, "pid": k[0], "who": k[1], "seen": n,
                   "rate": round(rate * n / seen_total, 2)}
                  for i, (k, n) in enumerate(spawn)]
    cpu = []
    fleet_cpu = 0.0
    for p, c0 in s.cpu0.items():
        if p not in alive or p in s.exclude or s.excluded(p):
            continue
        d = s.last[p][1] - c0
        if d <= 0:
            continue
        isfleet = bool(FLEET_RE.search(s.cmd.get(p, "")))
        if isfleet:
            fleet_cpu += d
        cpu.append((d, p, isfleet))
    cpu.sort(reverse=True)
    cpu_rows = [{"rank": i + 1, "pid": p, "who": who(s.cmd.get(p, "")),
                 "cpu_s": round(d, 2), "pct": round(100 * d / secs, 1), "fleet": f}
                for i, (d, p, f) in enumerate(cpu[:a.top])]
    try:
        load = [round(x, 2) for x in os.getloadavg()]
    except OSError:
        load = []
    reading = {
        "ts": int(time.time()), "host": socket.gethostname().split(".")[0],
        "state": "idle", "secs": round(secs, 1), "samples": s.samples,
        "method": method, "new": new, "rate": round(rate, 2),
        "excluded": len(mine), "own_forks": own,
        "fleet_cpu_pct": round(100 * fleet_cpu / secs, 1) if secs else 0.0,
        "load": load, "cores": os.cpu_count() or 1,
        "spawn_top": spawn_rows, "cpu_top": cpu_rows,
    }
    tmp = a.out + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(reading, fh, ensure_ascii=False)
    os.replace(tmp, a.out)
    return 0


def cmd_render(a):
    with open(a.file) as fh:
        r = json.load(fh)
    if a.json:
        print(json.dumps(r, ensure_ascii=False))
        return 0
    print("\t".join(["idle-cost", "%s/s" % r["rate"], "window=%ss" % r["secs"],
                     "new=%s" % r["new"], "method=%s" % r["method"],
                     "fleet_cpu=%s%%" % r["fleet_cpu_pct"],
                     "load=%s" % ",".join(str(x) for x in r.get("load", [])),
                     "cores=%s" % r.get("cores", "")]))
    for row in r.get("spawn_top", [])[:a.top]:
        print("\t".join(["spawn", str(row["rank"]), "%s/s" % row["rate"],
                         str(row["seen"]), str(row["pid"]), row["who"]]))
    for row in r.get("cpu_top", [])[:a.top]:
        print("\t".join(["cpu", str(row["rank"]), "%s%%" % row["pct"],
                         "%ss" % row["cpu_s"], str(row["pid"]), row["who"]]))
    return 0


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet-idle-cost.py")
    sub = ap.add_subparsers(dest="cmd")
    sp = sub.add_parser("sample")
    sp.add_argument("--secs", type=float, default=60.0)
    sp.add_argument("--interval", type=float, default=0.2)
    sp.add_argument("--exclude-pid", dest="exclude", type=int, action="append", default=[])
    sp.add_argument("--top", type=int, default=10)
    sp.add_argument("--min-age", type=float, default=60.0,
                    help="an owner is alive at the end and at least this old (s)")
    sp.add_argument("--out", required=True)
    rp = sub.add_parser("render")
    rp.add_argument("file")
    rp.add_argument("--json", action="store_true")
    rp.add_argument("--top", type=int, default=10)
    a = ap.parse_args(argv)
    if a.cmd == "sample":
        return cmd_sample(a)
    if a.cmd == "render":
        return cmd_render(a)
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
