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
import pwd
import re
import socket
import stat
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
        self.own_pids = set()
        self.exclude = set(exclude) | {os.getpid()}
        self.ppid = {}               # pid → ppid at first sight (before any reparenting)
        self.cmd = {}
        self.uid = {}
        self.first = None            # pids of the first sample
        self.last = {}               # pid → (etime, cputime) in the newest sample it was in
        self.seen_at = {}            # pid → monotonic time of the newest sample it was in
        self.cpu0 = {}               # pid → cputime in the first sample
        self.samples = 0

    def run(self, argv, check=True):
        self.own += 1
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True)
        self.own_pids.add(p.pid)
        try:
            out, _ = p.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            raise RuntimeError("observer command timed out: " + argv[0])
        if check and p.returncode:
            raise RuntimeError("observer command failed: " + argv[0])
        return out

    def sample(self):
        out = self.run(["ps", "-axo", "pid=,ppid=,uid=,etime=,time=,command="])
        if not out.strip():
            raise RuntimeError("process table unreadable")
        now = time.monotonic()
        pids = set()
        for line in out.splitlines():
            f = line.split(None, 5)
            if len(f) < 5:
                continue
            try:
                pid, ppid = int(f[0]), int(f[1])
                uid = int(f[2])
                et, ct = secs_of(f[3]), secs_of(f[4])
            except ValueError:
                continue
            pids.add(pid)
            if pid not in self.ppid:
                self.ppid[pid] = ppid
                self.cmd[pid] = f[5] if len(f) > 5 else ""
                self.uid[pid] = uid
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


class IdleGuard:
    """One idle definition, shared by --idle, sampling and the collector.

    Other logins publish an optional second line in the existing machine session
    file. Old readers still consume the unchanged first line. Until a login has
    upgraded, an awake login is unknown; missing state never becomes zero work.
    """
    def __init__(self, a, sampler):
        self.a, self.s = a, sampler
        self.previous = None
        self.peer_activity = {}
        self.started = time.time()
        self.activity_before = None
        self.self_activity = None
        self.activity_dir = (os.path.join(a.conf_dir, "idle-cost", "activity")
                             if a.conf_dir else "")
        if self.activity_dir:
            os.makedirs(self.activity_dir, mode=0o700, exist_ok=True)

    def activity(self):
        """Never clear counters: another observer can still need their baseline.

        Size is monotonic even when timestamps collide, and inode changes or
        deletions invalidate an in-flight reading instead of hiding activity.
        An unreadable tree is unknown, never a successful empty scan.
        """
        counters = {}
        if not self.activity_dir:
            return counters

        def scan(directory):
            with os.scandir(directory) as entries:
                for entry in entries:
                    st = entry.stat(follow_symlinks=False)
                    if st.st_uid != os.getuid():
                        raise RuntimeError("local activity has wrong owner")
                    if stat.S_ISDIR(st.st_mode):
                        scan(entry.path)
                    elif stat.S_ISREG(st.st_mode):
                        if entry.path != self.self_activity:
                            counters[entry.path] = (st.st_ino, st.st_size)
                    else:
                        raise RuntimeError("local activity has wrong type")
        scan(self.activity_dir)
        return counters

    def caller_activity(self):
        # Pin the caller's server lifetime once. Another server on the same
        # socket with a recycled @id must not inherit this exclusion.
        if self.self_activity is None:
            self.self_activity = ""
            if self.activity_dir and self.a.self_socket and self.a.self_window:
                try:
                    identity = self.s.run(["tmux", "-S", self.a.self_socket,
                                           "display-message", "-p", "-t", self.a.self_window,
                                           "#{socket_path}/#{pid}/#{window_id}"]).strip()
                except RuntimeError:
                    return
                # A missing target may resolve to nothing; never exclude a
                # different window from a partial/default tmux match.
                if re.fullmatch(re.escape(self.a.self_socket) + r"/\d+/" +
                                re.escape(self.a.self_window), identity):
                    self.self_activity = self.activity_dir + identity

    def local(self):
        sockets = {r.split("\t", 1)[0] for r in self.a.configs.splitlines() if r}
        # A new fleet configured during a window must enter the next probe.
        d = os.path.join(self.a.conf_dir, "fleets")
        if os.path.isdir(d):
            sockets.update(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, "conf")))
        rows = {}
        for label in sorted(sockets):
            path = os.path.join(os.environ.get("TMUX_TMPDIR", "/tmp"),
                                "tmux-%s" % os.getuid(), label)
            try:
                out = self.s.run(["tmux", "-L", label, "list-windows", "-a", "-F",
                                  self.a.window_format + "|#{pid}"])
            except RuntimeError:
                # A configured but stopped fleet has no socket. A server that
                # exists but cannot answer is unknown, not an empty scan.
                try:
                    os.stat(path)
                except FileNotFoundError:
                    continue
                raise
            # fleet_lw_fmt / fleet_lw_filter, kept in sync with fleet-lib.sh:
            # drop view rows and duplicate window ids before reading the body.
            seen = set()
            for line in out.splitlines():
                prefix, sep, body = line.partition(" ")
                if re.match(r"^@\d+:\$\d+:", prefix):
                    wid, _, session = prefix.split(":", 2)
                    if "@view-" in session or session.endswith("-pool") or wid in seen:
                        continue
                    seen.add(wid)
                    line = body
                f = line.split("|")
                if len(f) != 7:
                    raise RuntimeError("malformed window state: " + label)
                sock, wid, role, state, changed, life, server = f
                # FLEET_ROLE_FMT is supplied by fleet-lib; same fallback as
                # FLEET_ROLE_AWK, for windows predating role stamps.
                worker = role == "=worker" or (not role.startswith("=") and
                                               role not in {"home", "plan", "dash", "backlog"})
                if worker and life not in {"sleeping", "remote"}:
                    rows[(sock, wid)] = (state, changed, life, server)
        return rows

    def snapshot(self):
        marker = os.path.join(self.a.sessions_dir, ".idle-" + self.a.login)
        try:
            fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            os.fchmod(fd, 0o644)
            os.close(fd)
        except FileExistsError:
            pass
        st = os.lstat(marker)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            raise RuntimeError("activity marker has wrong owner or type")
        activity = st.st_mtime_ns
        rows = self.local()
        return {"ts": time.time(), "working": sum(v[0] == "working" for v in rows.values()),
                "unknown": any(not v[0] or v[2] in {"preparing", "waking"} for v in rows.values()),
                "changed": max([float(v[1] or 0) for v in rows.values()] or [0]),
                "activity": activity}

    def peers(self, foreign):
        d = self.a.sessions_dir
        try:
            names = os.listdir(d)
        except FileNotFoundError:
            names = []
        except OSError:
            return "unknown: machine session inventory unreadable"
        if set(self.peer_activity) - set(names):
            return "unknown: a login disappeared during sampling"
        covered = set()
        for name in names:
            if name.startswith(".") or name == self.a.login:
                continue
            try:
                st, count, r = read_published(d, name)
                if r is None:
                    if count or st.st_uid in foreign:
                        raise ValueError("working state not published")
                else:
                    if r["working"]:
                        return "working: %s session(s) in login %s" % (r["working"], name)
                    mark = published_mark(d, name, st, r)
                    if self.previous is not None and mark.st_mtime_ns >= self.started * 1e9:
                        return "busy interval: activity in login " + name
                    old = self.peer_activity.setdefault(name, mark.st_mtime_ns)
                    if old != mark.st_mtime_ns:
                        return "busy interval: activity in login " + name
                    if self.previous is not None and r["changed"] >= self.started:
                        return "busy interval: state changed in login " + name
                covered.add(st.st_uid)
            except (OSError, ValueError, KeyError, IndexError, TypeError) as e:
                return "unknown: login %s (%s)" % (name, e)
        if foreign - covered:
            return "unknown: another login has sessions but no fresh inventory"
        return ""

    def check(self, alive):
        self.caller_activity()
        before = self.activity()
        if self.activity_before is None:
            self.activity_before = before
        if before != self.activity_before:
            return "busy interval: worker activity during sampling"
        rows = self.local()
        # Bracket the tmux scan, including the first one. A transition during
        # discovery cannot get incorporated into a later baseline unnoticed.
        if self.activity() != self.activity_before:
            return "busy interval: worker activity during sampling"
        caller = (self.a.self_socket, self.a.self_window)
        own = rows.get(caller)
        if own and self.self_activity == (
                self.activity_dir + caller[0] + "/" + own[3] + "/" + caller[1]):
            rows.pop(caller)
        working = sum(v[0] == "working" or v[2] in {"preparing", "waking"} for v in rows.values())
        if working:
            return "working: %s session(s)" % working
        if any(not v[0] for v in rows.values()):
            return "unknown: worker state unavailable"
        if self.previous is not None and rows != self.previous:
            return "busy interval: worker state changed during sampling"
        pat = os.environ.get("FLEET_CI_WORKER_PAT", "Runner.Worker")
        foreign = set()
        for p in alive:
            cmd = self.s.cmd.get(p, "")
            if p in self.s.own_pids or self.s.excluded(p):
                continue
            if pat and pat in cmd:
                return "ci: 1 job(s) running"
            if self.s.uid[p] != os.getuid() and re.search(r"(?:^|/|\s)(?:tmux|claude|codex)(?::|\s|$)", cmd):
                foreign.add(self.s.uid[p])
        reason = self.peers(foreign)
        self.previous = rows
        return reason


def read_published(d, name):
    """One login's published machine-session row (fleet_machine_sessions_publish):
    (stat, count, working-state record | None when the login publishes none). A
    file that is not its login's own regular file, garbled or stale, or a record
    that is stale / unknown / malformed raises ValueError — never zero work."""
    path = os.path.join(d, name)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) |
                 getattr(os, "O_NONBLOCK", 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("not a regular file")
        if os.environ.get("FLEET_MACHINE_SESSIONS_OWNER_CHECK", "1") != "0":
            owner = pwd.getpwuid(st.st_uid)
            if name not in (owner.pw_name, os.path.basename(owner.pw_dir)):
                raise ValueError("wrong owner")
        lines = os.read(fd, 65536).decode().splitlines()
    finally:
        os.close(fd)
    count, ts = [int(x) for x in lines[0].split()[:2]]
    age = time.time() - ts
    if count < 0 or age < -60 or age > 300:
        raise ValueError("stale inventory")
    if len(lines) < 2 or not lines[1].startswith("idle-v1 "):
        return st, count, None
    r = json.loads(lines[1][8:])
    if not 0 <= time.time() - r["ts"] <= 300 or r["unknown"]:
        raise ValueError("working state unavailable")
    if not isinstance(r["working"], int) or r["working"] < 0:
        raise ValueError("invalid working count")
    return st, count, r


def published_mark(d, name, st, r):
    """The login's activity marker, checked against its record: a state change
    since the snapshot (fleet-idle-activity.sh touched it) raises ValueError."""
    mark = os.lstat(os.path.join(d, ".idle-" + name))
    if not stat.S_ISREG(mark.st_mode) or mark.st_uid != st.st_uid:
        raise ValueError("activity marker has wrong owner or type")
    if mark.st_mtime_ns != r["activity"]:
        raise ValueError("activity since the last working-state snapshot")
    return mark


def published_idle(d, ci_busy=False):
    """The machine's idle answer from what every login PUBLISHED — the same rule
    as IdleGuard.peers, applied to every login, with no tmux, no `ps` and no fork
    (issue #4359): for a reader that runs on a beat and cannot scan another
    login's tmux — the node daemon backing its own clocks off. "" = idle, else
    the reason. A login with sessions but no fresh working-state record, a stale
    or foreign file, or a state change since its snapshot is NOT idle; so is a CI
    job (ci_busy: the runner's own word). An empty or missing directory is idle:
    no login has a session to work in."""
    if ci_busy:
        return "ci: a job running"
    try:
        names = os.listdir(d)
    except FileNotFoundError:
        return ""
    except OSError:
        return "unknown: machine session inventory unreadable"
    for name in sorted(names):
        if name.startswith("."):
            continue
        try:
            st, count, r = read_published(d, name)
            if r is None:
                if count:
                    raise ValueError("working state not published")
                continue
            if r["working"]:
                return "working: %s session(s) in login %s" % (r["working"], name)
            published_mark(d, name, st, r)
        except (OSError, ValueError, KeyError, IndexError, TypeError) as e:
            return "unknown: login %s (%s)" % (name, e)
    return ""


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
    alive = s.sample()
    guard = IdleGuard(a, s) if a.configs is not None else None
    if guard:
        why = guard.check(alive)
        if why:
            print(why)
            return 3
    forks0 = fork_counter()
    p0 = probe_pid(s) if forks0 is None else 0
    own0 = s.own
    t0 = time.monotonic()
    while time.monotonic() - t0 < a.secs:
        time.sleep(min(a.interval, max(0, a.secs - (time.monotonic() - t0))))
        alive = s.sample()
        if guard:
            why = guard.check(alive)
            if why:
                print(why)
                return 3
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
    # Known observer children were already removed from the kernel/PID count.
    # Do not subtract the ps processes a second time when a snapshot saw them.
    mine = [p for p in newp if s.excluded(p) and p not in s.own_pids]
    new = max(0, new - len(mine))
    owners = {}
    for p in newp:
        if s.excluded(p) or p in s.own_pids:
            continue
        a_ = s.ppid.get(p)
        top = p
        owner = None
        ancestors = set()
        while a_ is not None and a_ not in ancestors:
            ancestors.add(a_)
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
            key = (1, who(s.cmd.get(1, "init")) + " ← " + who(s.cmd.get(top, "")))
        else:
            key = (owner, who(s.cmd.get(owner, "")))
        owners[key] = owners.get(key, 0) + 1
    seen_total = sum(owners.values()) or 1
    spawn = sorted(owners.items(), key=lambda kv: -kv[1])[:a.top]
    rate = new / secs if secs else 0.0
    spawn_rows = [{"rank": i + 1, "pid": k[0], "who": k[1], "seen": n,
                   "rate": round(rate * n / seen_total, 2), "estimated": True}
                  for i, (k, n) in enumerate(spawn)]
    cpu = []
    fleet_cpu = 0.0
    for p, c0 in s.cpu0.items():
        if p not in alive or s.excluded(p) or s.last[p][0] < a.min_age:
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
        "state": "idle" if guard else "unverified", "secs": round(secs, 1), "samples": s.samples,
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
    ip = sub.add_parser("idle")
    cp = sub.add_parser("snapshot")
    for parser in (sp, ip, cp):
        parser.add_argument("--configs", default=None)
        parser.add_argument("--conf-dir", default="")
        parser.add_argument("--sessions-dir", default="")
        parser.add_argument("--login", default="")
        parser.add_argument("--self-window", default="")
        parser.add_argument("--self-socket", default="")
        parser.add_argument("--window-format", default="")
    rp = sub.add_parser("render")
    rp.add_argument("file")
    rp.add_argument("--json", action="store_true")
    rp.add_argument("--top", type=int, default=10)
    a = ap.parse_args(argv)
    if a.cmd in {"idle", "snapshot"}:
        s = Sampler([])
        guard = IdleGuard(a, s)
        if a.cmd == "snapshot":
            print(json.dumps(guard.snapshot(), separators=(",", ":")))
            return 0
        reason = guard.check(s.sample())
        print(reason or "idle")
        return 1 if reason else 0
    if a.cmd == "sample":
        if not (0 < a.secs <= 3600 and 0 < a.interval <= a.secs and a.top > 0):
            ap.error("sample needs 0 < interval <= secs <= 3600 and top > 0")
        return cmd_sample(a)
    if a.cmd == "render":
        return cmd_render(a)
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError) as e:
        mode = sys.argv[1] if len(sys.argv) > 1 else ""
        print("unknown: " + str(e), file=sys.stdout if mode in {"idle", "sample"} else sys.stderr)
        sys.exit(3 if mode == "sample" else 1)
