# fleet_park_metrics.py — shared read-only session census and action summaries
"""Read-only park census shared by inventory, heartbeat and doctor (RBQG).

RSS is the pane's complete process tree, including its wrapper. No observations
are written to the action ledger. CPU eligibility needs two readings >=60s apart.
"""
import argparse
from collections import Counter, defaultdict
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


def daily(path, day):
    counts, durations, scheduled, timely = Counter(), [], 0, 0
    for line in Path(path).read_text().splitlines() if Path(path).exists() else []:
        try:
            row = json.loads(line)
            ts = row["ts"]
            stamp = datetime.fromtimestamp(ts, timezone.utc) if isinstance(ts, (float, int)) else fleet_iso.parse(ts, utc=True)
            if stamp.astimezone(timezone.utc).date().isoformat() != day:
                continue
            act = row.get("act")
            if act not in ("park", "wake", "fail", "deferred", "fresh"):
                continue
            counts[act] += 1
            if act == "wake" and row.get("result") in ("ok", "已接回", "resumed"):
                secs = float(row["secs"])
                if math.isfinite(secs) and secs >= 0:
                    durations.append(secs)
                if row.get("next") is not None and row.get("started") is not None:
                    due, started = float(row["next"]), float(row["started"])
                    if math.isfinite(due) and math.isfinite(started) and due > 0 and started > 0:
                        scheduled += 1
                        timely += 0 <= started - due <= 30
        except (ValueError, TypeError, KeyError, OverflowError):
            continue
    durations.sort()
    percentile = lambda p: durations[max(0, math.ceil(len(durations) * p) - 1)] if durations else None
    return dict(day=day, timezone="UTC", **{k: counts[k] for k in ("park", "wake", "fail", "deferred", "fresh")},
                p50=percentile(.5), p95=percentile(.95), scheduled=scheduled,
                on_time_rate=timely / scheduled if scheduled else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("census", "doctor", "daily"))
    parser.add_argument("--socket")
    parser.add_argument("--session")
    parser.add_argument("--day", default=datetime.now(timezone.utc).date().isoformat())
    args = parser.parse_args()
    conf = Path(os.environ.get("FLEET_CONF_DIR", Path.home() / ".config/claude-fleet"))
    if args.mode == "census":
        print(json.dumps(census(args.socket, args.session, conf / "global"), separators=(",", ":")))
    elif args.mode == "daily":
        print(json.dumps(daily(conf / "logs/park.ndjson", args.day)))
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
    except (OSError, subprocess.SubprocessError, RuntimeError) as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
