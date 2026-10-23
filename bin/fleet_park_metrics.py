# fleet_park_metrics.py — shared session census and bounded observation summaries
"""Park census shared by inventory, heartbeat and doctor (RBQG).

RSS is the pane's complete process tree, including its wrapper. No observations
are written to the action ledger. CPU eligibility needs two readings >=60s apart.
The existing collector alone appends a content-free sample with sample --record.
"""
import argparse
from collections import Counter, defaultdict
import fcntl
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time

import fleet_iso


def command(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=10)


def cpu_seconds(value):
    days, _, rest = value.rpartition("-")
    nums = [float(v) for v in rest.split(":")]
    return (float(days) * 86400 if days else 0) + sum(v * 60 ** i for i, v in enumerate(reversed(nums)))


def process_trees(text):
    procs, children = {}, defaultdict(list)
    for line in text.splitlines():
        cols = line.split(None, 4)
        if len(cols) < 4:
            continue
        try:
            pid, parent, rss = map(int, cols[:3])
            procs[pid] = (rss / 1024, cpu_seconds(cols[3]))
            children[parent].append(pid)
        except ValueError:
            continue

    def tree(root):
        todo, seen, rss, cpu = [root], set(), 0.0, 0.0
        while todo:
            pid = todo.pop()
            if pid in seen:
                continue
            seen.add(pid)
            r, c = procs.get(pid, (0, 0))
            rss += r
            cpu += c
            todo.extend(children[pid])
        return rss, cpu, root in procs
    return tree


def latest_park_rss(path):
    """Missing-stamp fallback, keyed by lifelong identity, from action rows only."""
    saved = {}
    try:
        with Path(path).open() as book:
            for line in book:
                try:
                    row = json.loads(line)
                    if row.get("act") != "park" or not row.get("fid"):
                        continue
                    rss = row.get("rss_mb")
                    saved[row["fid"]] = float(rss) if type(rss) in (int, float) and math.isfinite(rss) and rss >= 0 else None
                except (ValueError, TypeError, AttributeError):
                    continue
    except OSError:
        pass  # No readable book: missing snapshots stay unknown.
    return saved


def census(socket, session, cache_dir):
    # Exact session, one row per window: grouped views never duplicate a pane.
    fmt = "\x1f".join(["#{window_id}", "#{pane_pid}", "#{@fleet_role}", "#{window_name}",
                          "#{@parked}", "#{@park_saved_mb}", "#{@park_wrap_ver}",
                          "#{@park_since}", "#{@fleet_id}", "#{@park_why}",
                          "#{@park_held}", "#{@park_start}"])
    rows = command(["tmux", "-u", "-L", socket, "list-windows", "-t", "=" + session, "-F", fmt])
    clients = command(["tmux", "-L", socket, "list-clients", "-F", "#{client_control_mode}\x1f#{window_id}"])
    watched = {wid for row in clients.split("\n") for control, sep, wid in [row.replace("\\037", "\x1f").partition("\x1f")]
               if sep and control != "1"}
    trees = process_trees(command(["ps", "-axo", "pid=,ppid=,rss=,time=,command="]))
    saved_by_fid = latest_park_rss(Path(cache_dir).parent / "logs/park.ndjson")
    path = Path(cache_dir) / ("park-cpu-" + session + ".json")
    try:
        previous = json.loads(path.read_text())
    except (OSError, ValueError):
        previous = {}
    now, next_sample, result = time.time(), {}, {}
    for row in rows.split("\n"):
        # tmux <=3.4 vis-escapes this control separator even with -u.
        # Newer tmux emits the literal byte; both describe the same census row.
        fields = row.replace("\\037", "\x1f").split("\x1f")
        if len(fields) != 12:
            continue
        wid, pid, role, name, parked, saved, wrap, _since, fid, why, held, start = fields
        if role in ("home", "panel") or (not role and name in ("home", "dash", "plan", "backlog")):
            continue
        if not pid.isdigit():
            continue
        rss, cpu, known = trees(int(pid))
        old = previous.get(wid, {})
        elapsed = now - old.get("at", now)
        valid = old.get("pid") == pid and elapsed >= 60 and cpu >= old.get("cpu", cpu)
        quiet = old.get("quiet") if old.get("pid") == pid else None
        if valid:
            quiet = cpu - old["cpu"] < 0.5 * elapsed / 60
        if cpu < old.get("cpu", cpu):
            quiet = None
        if not known:
            quiet = None
        next_sample[wid] = {"at": now, "cpu": cpu, "pid": pid, "quiet": quiet} if elapsed >= 60 or old.get("pid") != pid else old
        try:
            saved_mb = float(saved) if saved else None
            if saved_mb is not None and (not math.isfinite(saved_mb) or saved_mb < 0):
                saved_mb = None
        except ValueError:
            saved_mb = None
        if not saved:
            saved_mb = saved_by_fid.get(fid)
        # HHV0's request plus confirmed holding page; C1 owns the RSS snapshot.
        is_parked = bool(parked and held)
        result[wid] = {"state": "parked" if is_parked else "awake",
                       "rss_mb": round(rss, 2) if known else None, "saved_mb": saved_mb,
                       "why": "working" if start and not is_parked else "watched" if wid in watched else why or ("old-shell" if not wrap else "idle-delay"), "quiet": quiet}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".%d.tmp" % os.getpid())
        temp.write_text(json.dumps(next_sample))
        temp.replace(path)
    except OSError:
        pass  # No writable sample cache: eligibility stays unknown, never zero.
    return result


def inventory_park(reading, state, busy):
    """Join CPU/view observations with the inventory's turn and job state.

    Only these five fields cross the adapter boundary. `eligible` is the full
    batch definition, not just a CPU observation. A viewer or background job
    rules out idle even while the CPU sample is pending.
    """
    p = dict(reading)
    quiet = p.pop("quiet", None)
    ended = state in ("done", "looping", "needs") and p["why"] != "working"
    blocked = p["why"] == "watched" or busy == "bg"
    p["eligible"] = (False if p["state"] == "parked" or not ended or quiet is False or blocked
                     else None if quiet is None else True)
    if p["state"] != "parked":
        if not ended or quiet is False:
            p["why"] = "working"
        elif busy == "bg":
            p["why"] = "background"
        elif not blocked and quiet is None:
            p["why"] = "sampling"
    return p


def summarize(workers):
    if any("park" not in w for w in workers):
        return None  # An older adapter cannot supply a partial, optimistic sum.
    out = dict(sessions_working=0, sessions_idle=0, sessions_parked=0,
               idle_rss_mb=0.0, parked_saved_mb=0.0, idle_reasons={},
               idle_eligible=0, idle_eligible_rss_mb=0.0)
    reasons = Counter()
    sample_pending = False
    for w in workers:
        p = w["park"]
        # compat-1v: 下一批删 — observations from the #5277 adapter used quiet.
        if "quiet" in p:
            p = inventory_park(p, w.get("state"), w.get("busy"))
        if p["state"] == "parked":
            out["sessions_parked"] += 1
            if p["saved_mb"] is None:
                out["parked_saved_mb"] = None
            elif out["parked_saved_mb"] is not None:
                out["parked_saved_mb"] += p["saved_mb"]
        elif p["eligible"] is None:
            # Until a full CPU sample, neither a zero idle count nor a working
            # count is known. Preserve that uncertainty through the heartbeat.
            out["idle_rss_mb"] = None
            reasons["sampling"] += 1
            sample_pending = True
        elif p["eligible"]:
            out["sessions_idle"] += 1
            if p["rss_mb"] is None:
                out["idle_rss_mb"] = None
            elif out["idle_rss_mb"] is not None:
                out["idle_rss_mb"] += p["rss_mb"]
            reasons[p["why"]] += 1
        else:
            out["sessions_working"] += 1
            if p["why"] in ("watched", "background"):
                reasons[p["why"]] += 1
    if sample_pending:
        out["sessions_idle"] = out["sessions_working"] = None
    out["idle_eligible"] = out["sessions_idle"]
    out["idle_eligible_rss_mb"] = out["idle_rss_mb"]
    out["idle_reasons"] = dict(reasons)
    return out


def stamp(value):
    if isinstance(value, bool):
        raise ValueError("boolean is not a timestamp")
    result = float(value) if isinstance(value, (float, int)) else fleet_iso.parse(value, utc=True).timestamp()
    if not math.isfinite(result):
        raise ValueError("invalid timestamp")
    return result


def daily(path, day, *, opportunities=None, as_of=None):
    """Successful wakes are observations, never the scheduling denominator.

    A complete opportunity manifest must come from the scheduler's durable due
    events, including events that never started. An action ledger alone cannot
    prove their absence. Keep the acceptance rate unknown without that manifest.
    """
    start = datetime.fromisoformat(day).replace(tzinfo=timezone.utc).timestamp()
    end = start + 86400
    as_of = time.time() if as_of is None else stamp(as_of)
    counts, durations, observed, starts = Counter(), [], set(), {}
    for line in Path(path).read_text().splitlines() if Path(path).exists() else []:
        try:
            row = json.loads(line)
            when = stamp(row["ts"])
            act = row.get("act")
            if act not in ("park", "wake", "fail", "deferred", "fresh"):
                continue
            success = act == "wake" and row.get("result") in ("ok", "已接回", "resumed")
            if start <= when < end:
                counts[act] += 1
                if success:
                    secs = float(row["secs"])
                    if math.isfinite(secs) and secs >= 0:
                        durations.append(secs)
            due = stamp(row.get("next", row.get("next_at", 0)))
            fid = row.get("fid")
            if isinstance(fid, str) and fid and start <= due < end:
                key = (fid, due)
                observed.add(key)
                if success:
                    began = stamp(row.get("started", 0))
                    if due <= began <= as_of:
                        starts[key] = min(starts.get(key, began), began)
        except (ValueError, TypeError, KeyError, OverflowError, AttributeError):
            continue
    complete, expected = False, set()
    if opportunities is not None:
        # Reject malformed manifests rather than silently shrinking a denominator.
        if not isinstance(opportunities, dict) or not isinstance(opportunities.get("opportunities"), list):
            raise ValueError("scheduled opportunities require a coverage manifest")
        coverage_start = stamp(opportunities["coverage_start"])
        coverage_end = stamp(opportunities["coverage_end"])
        if coverage_end < coverage_start:
            raise ValueError("opportunity coverage is reversed")
        complete = (opportunities.get("complete") is True and coverage_start <= start
                    and coverage_end >= end and as_of >= end)
        for row in opportunities["opportunities"]:
            fid, due = row.get("fid"), stamp(row["due"])
            if not isinstance(fid, str) or not fid:
                raise ValueError("opportunity requires an immutable session identity")
            if start <= due < end:
                expected.add((fid, due))
        # A manifest missing an observed due event is demonstrably incomplete.
        complete = complete and observed.issubset(expected)
    timely = sum(key in starts and starts[key] - key[1] <= 30 for key in expected)
    durations.sort()
    percentile = lambda p: durations[max(0, math.ceil(len(durations) * p) - 1)] if durations else None
    return dict(day=day, timezone="UTC", **{k: counts[k] for k in ("park", "wake", "fail", "deferred", "fresh")},
                p50=percentile(.5), p95=percentile(.95), wake_samples=len(durations),
                observed_scheduled=len(observed), scheduled_complete=complete,
                scheduled=len(expected) if complete else None,
                on_time_rate=timely / len(expected) if complete and expected else None)


def integrate_samples(samples, start, end, *, scope, max_gap_secs=120):
    """Trapezoidal estimate only across bounded, known observations in one scope.

    Missing boundaries, unknown readings and long gaps remain uncovered. Never
    extrapolate the first or last sample, or turn absent collection into zero.
    """
    start, end = stamp(start), stamp(end)
    if end <= start or not math.isfinite(max_gap_secs) or max_gap_secs <= 0:
        raise ValueError("a positive observation interval and max gap are required")
    readings = {}
    for row in samples:
        if row.get("scope") != scope:
            continue
        ts = stamp(row["ts"])
        value = row.get("idle_count")
        if type(value) is not int or value < 0:
            value = None
        # Conflicting duplicate timestamps are unknown, not whichever came last.
        readings[ts] = value if ts not in readings or readings[ts] == value else None
    ordered = sorted(readings.items())
    covered, hours = 0.0, 0.0
    for (left, nleft), (right, nright) in zip(ordered, ordered[1:]):
        a, b = max(start, left), min(end, right)
        if b <= a or right - left > max_gap_secs or nleft is None or nright is None:
            continue
        # Linear interpolation clips a partial boundary interval consistently.
        slope = (nright - nleft) / (right - left)
        first, last = nleft + slope * (a - left), nleft + slope * (b - left)
        covered += b - a
        hours += (first + last) / 2 * (b - a) / 3600
    duration = end - start
    return dict(scope=scope, start=start, end=end, samples=len(ordered),
                covered_seconds=covered, uncovered_seconds=duration - covered,
                coverage=covered / duration, complete=covered == duration,
                observed_idle_session_hours=hours if covered else None,
                method="trapezoidal estimate on bounded observed intervals; no extrapolation",
                max_gap_seconds=max_gap_secs)


def sample():
    """One content-free reading for the existing collector's scheduled tick."""
    import getpass
    import socket
    from fleet_control import Control
    ctl = Control()
    fleets = ctl.inventory()
    values = [ctl.workers(fleet)["park_metrics"]["sessions_idle"] for fleet in fleets]
    return dict(ts=time.time(), scope=socket.gethostname() + "/" + getpass.getuser(),
                idle_count=None if any(v is None for v in values) else sum(values),
                fleet_count=len(fleets))


def record_sample(conf, row):
    """One append per collector tick; reuse the existing size rotation helper.

    Eight MiB plus one previous file keeps well over a week of minute readings.
    Reports still disclose missing coverage after rotation; retention is not
    evidence of elapsed observation. No history is parsed during collection.
    """
    from fleet_clientlog import rotate
    directory = Path(conf) / "logs"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / "park-samples.ndjson"
    lock = os.open(str(path) + ".lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rotate(str(path), limit=8 * 1024 * 1024)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps(row, separators=(",", ":")) + "\n").encode())
        finally:
            os.close(fd)
    finally:
        os.close(lock)


def sample_history(path):
    rows = []
    for source in (Path(str(path) + ".1"), Path(path)):
        if source.exists():
            rows.extend(json.loads(line) for line in source.read_text().splitlines() if line.strip())
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("census", "doctor", "daily", "sample", "history"))
    parser.add_argument("--socket")
    parser.add_argument("--session")
    parser.add_argument("--day", default=datetime.now(timezone.utc).date().isoformat())
    parser.add_argument("--opportunities", help="scheduler's complete due-event coverage manifest")
    parser.add_argument("--samples", help="NDJSON from sample, recorded by the existing collector")
    parser.add_argument("--start")
    parser.add_argument("--end")
    parser.add_argument("--scope")
    parser.add_argument("--max-gap-secs", type=float, default=120)
    parser.add_argument("--record", action="store_true", help="append one sample for the existing collector")
    args = parser.parse_args()
    conf = Path(os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet"))
    if args.mode == "sample":
        row = sample()
        if args.record:
            record_sample(conf, row)
        else:
            print(json.dumps(row))
    elif args.mode == "history":
        if not all((args.samples, args.start, args.end, args.scope)):
            parser.error("history requires --samples, --start, --end and --scope")
        rows = sample_history(args.samples)
        print(json.dumps(integrate_samples(rows, args.start, args.end, scope=args.scope,
                                          max_gap_secs=args.max_gap_secs)))
    elif args.mode == "census":
        print(json.dumps(census(args.socket, args.session, conf / "global"), separators=(",", ":")))
    elif args.mode == "daily":
        import getpass
        import socket
        report = daily(conf / "logs/park.ndjson", args.day,
                       opportunities=json.loads(Path(args.opportunities).read_text()) if args.opportunities else None)
        start = datetime.fromisoformat(args.day).replace(tzinfo=timezone.utc).timestamp()
        report["observation"] = integrate_samples(sample_history(conf / "logs/park-samples.ndjson"), start, start + 86400,
            scope=args.scope or socket.gethostname() + "/" + getpass.getuser(), max_gap_secs=args.max_gap_secs)
        print(json.dumps(report))
    else:
        from fleet_control import Control
        ctl = Control()
        totals = []
        for fleet in ctl.inventory():
            reading = ctl.workers(fleet)
            stats = reading.get("park_metrics")
            if stats is None:
                raise RuntimeError("park metrics unavailable for " + fleet["name"])
            totals.append(stats)
        total = {k: (None if any(s[k] is None for s in totals) else sum(s[k] for s in totals))
                 for k in ("sessions_working", "sessions_idle", "sessions_parked", "idle_eligible")}
        saved = None if any(s["parked_saved_mb"] is None for s in totals) else sum(s["parked_saved_mb"] for s in totals)
        idle_rss = None if any(s["idle_rss_mb"] is None for s in totals) else sum(s["idle_rss_mb"] for s in totals)
        eligible_rss = None if any(s["idle_eligible_rss_mb"] is None for s in totals) else sum(s["idle_eligible_rss_mb"] for s in totals)
        reasons = Counter()
        for s in totals:
            reasons.update(s["idle_reasons"])
        detail = ""
        if reasons:
            detail += " · " + ", ".join("%s %d" % pair for pair in sorted(reasons.items()))
        counts = {k: "unknown (needs 60s CPU sample)" if v is None else str(v) for k, v in total.items()}
        print("working {sessions_working} · idle {sessions_idle} · parked {sessions_parked} · saved ".format(**counts) + ("unknown" if saved is None else "%.1f MB" % saved) + " · idle RSS " + ("unknown" if idle_rss is None else "%.1f MB" % idle_rss) + " · eligible {idle_eligible} · eligible RSS ".format(**counts) + ("unknown" if eligible_rss is None else "%.1f MB" % eligible_rss) + detail)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError, KeyError) as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
