#!/usr/bin/env python3
"""fleet_timing.py — the segment clock of the two waits a person feels (issue
#3551, EPIC #3500 C6): ⌘P to the panel's first frame, and ⌘N / ⚡ to a session
they can type into.

    fleet_timing.py add <what> <seg>=<ms>...   one run's segments, appended
    fleet_timing.py table [<what>...] [--last N]
                                               the segment table: per segment the
                                               median and max over the last N runs
                                               (10) — the PR's / the EPIC's evidence
    fleet_timing.py check [--last N]           one line per <what> for fleet-doctor:
                                               `<what> n=<runs> p50=<ms> limit=<ms>
                                               over=<0|1> cold=<runs>`; exit 1 when
                                               one is over its limit

Every run is lines of `{ts, what, seg, ms}` in `$FLEET_CONF_DIR/timing/<what>.ndjson`
— one line per segment, all of a run's lines carrying the same `ts` (epoch
seconds, ms precision), and a `total` segment for end to end. The two writers:
    panel    fleet_view.popup (the 看台's ⌘P):
             boot (the process start → the panel's code loaded) · read (the rows
             off the cache) · frame (the first frame drawn) · total
    session  fleet_view.go_new (⌘N / ⚡): claim (a warm pool window bound) · cold
             (no warm window: a session started now — then the run is `cold`) ·
             go (the view onto it) · total
A file past MAX_LINES keeps its newest half. Writing never raises and never
blocks the person: a full disk or a read-only home costs the line, nothing else.

The limits (`check`, the doctor's `timing` row): FLEET_TIMING_PANEL_MS (500) on
the median panel total, FLEET_TIMING_SESSION_MS (3000) on the median total of the
warm opens (a cold open is counted apart: it says the pool was empty, not that
the open was slow). No file ⇒ nothing printed.
"""
import json
import os
import sys
import time

MAX_LINES = 4000
LIMITS = {"panel": ("FLEET_TIMING_PANEL_MS", 500), "session": ("FLEET_TIMING_SESSION_MS", 3000)}


def timing_dir():
    base = os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet")
    return os.path.join(base, "timing")


def proc_start():
    """When this process started, epoch seconds — off /proc on Linux (the popup's
    command is this process: `sh -c` execs it), so the interpreter's own start-up
    is inside `boot`; None elsewhere (a Mac: the caller's import time stands in)."""
    try:
        with open("/proc/self/stat") as f:
            ticks = int(f.read().rsplit(")", 1)[1].split()[19])
        with open("/proc/uptime") as f:
            up = float(f.read().split()[0])
        return time.time() - (up - ticks / float(os.sysconf("SC_CLK_TCK")))
    except (OSError, ValueError, IndexError):
        return None


def add(what, segs, ts=None):
    """Append one run: segs = [(seg, ms), …]. Never raises."""
    try:
        ts = round(time.time() if ts is None else ts, 3)
        d = timing_dir()
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, what + ".ndjson")
        with open(path, "a") as f:
            for seg, ms in segs:
                f.write(json.dumps({"ts": ts, "what": what, "seg": seg, "ms": round(float(ms), 1)}) + "\n")
        if os.path.getsize(path) > MAX_LINES * 80:
            with open(path) as f:
                lines = f.readlines()
            if len(lines) > MAX_LINES:
                tmp = path + ".tmp"
                with open(tmp, "w") as f:
                    f.writelines(lines[-(MAX_LINES // 2):])
                os.replace(tmp, path)
    except (OSError, ValueError, TypeError):
        pass


class Clock:
    """A run measured as it goes: mark(seg) closes the segment begun at the last
    mark (or at <t0>); done() adds `total` (t0 → now) and writes the run once."""

    def __init__(self, what, t0=None):
        self.what, self.t0 = what, (time.time() if t0 is None else t0)
        self.last, self.segs, self.written = self.t0, [], False

    def mark(self, seg):
        now = time.time()
        self.segs.append((seg, max(0.0, (now - self.last) * 1000)))
        self.last = now

    def done(self):
        if self.written:
            return
        self.written = True
        add(self.what, self.segs + [("total", max(0.0, (time.time() - self.t0) * 1000))])


def runs(what, last=10):
    """The last <last> runs of <what>: [{seg: ms}], oldest first."""
    by = {}
    try:
        with open(os.path.join(timing_dir(), what + ".ndjson")) as f:
            for line in f:
                try:
                    r = json.loads(line)
                    by.setdefault(r["ts"], {})[str(r["seg"])] = float(r["ms"])
                except (ValueError, KeyError, TypeError):
                    continue
    except OSError:
        return []
    return [by[k] for k in sorted(by)][-last:]


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def whats():
    try:
        return sorted(n[:-7] for n in os.listdir(timing_dir()) if n.endswith(".ndjson"))
    except OSError:
        return []


def fmt(ms):
    return "—" if ms is None else ("%.0f" % ms)


def table(names, last):
    out = []
    for what in names:
        rs = runs(what, last)
        if not rs:
            continue
        segs = []
        for r in rs:
            for s in r:
                if s != "total" and s not in segs:
                    segs.append(s)
        segs.append("total")
        cold = sum(1 for r in rs if "cold" in r)
        out.append("%s · %d 次%s" % (what, len(rs), (" · 其中冷启 %d 次" % cold) if cold else ""))
        out.append("| 段 | 中位 ms | 最大 ms | 次数 |")
        out.append("|---|---|---|---|")
        for s in segs:
            xs = [r[s] for r in rs if s in r]
            out.append("| %s | %s | %s | %d |" % (s, fmt(median(xs)), fmt(max(xs) if xs else None), len(xs)))
        if cold:
            xs = [r["total"] for r in rs if "cold" not in r and "total" in r]
            out.append("| total（不算冷启） | %s | %s | %d |" % (fmt(median(xs)), fmt(max(xs) if xs else None), len(xs)))
        out.append("")
    return out


def limit(what):
    k, d = LIMITS.get(what, ("", 0))
    try:
        return int(os.environ.get(k) or d) if k else 0
    except ValueError:
        return d


def check(last):
    over_any = False
    for what in whats():
        rs = runs(what, last)
        if not rs:
            continue
        lim = limit(what)
        judged = [r for r in rs if "cold" not in r]
        p50 = median([r["total"] for r in judged if "total" in r])
        over = bool(lim and p50 is not None and p50 > lim)
        over_any = over_any or over
        print("%s n=%d p50=%s limit=%s over=%d cold=%d" % (what, len(rs), fmt(p50), lim or "-", int(over),
                                                          len(rs) - len(judged)))
    return 1 if over_any else 0


def main(argv):
    last = 10
    if "--last" in argv[:-1]:
        i = argv.index("--last")
        try:
            last = max(1, int(argv[i + 1]))
        except ValueError:
            print("fleet_timing: --last takes a number", file=sys.stderr)
            return 2
        argv = argv[:i] + argv[i + 2:]
    if argv[:1] == ["add"] and len(argv) >= 3:
        segs = []
        for a in argv[2:]:
            seg, _, ms = a.partition("=")
            try:
                segs.append((seg, float(ms)))
            except ValueError:
                print("fleet_timing: %r is not <seg>=<ms>" % a, file=sys.stderr)
                return 2
        add(argv[1], segs)
        return 0
    if argv[:1] == ["table"]:
        lines = table(argv[1:] or whats(), last)
        print("\n".join(lines) if lines else "(还没有计时：%s)" % timing_dir())
        return 0
    if argv[:1] == ["check"]:
        return check(last)
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
