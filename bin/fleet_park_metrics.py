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


def census(socket, session, cache_dir):
    # Exact session, one row per window: grouped views never duplicate a pane.
    fmt = "\x1f".join(["#{window_id}", "#{pane_pid}", "#{@fleet_role}", "#{window_name}",
                          "#{@park_state}", "#{@park_saved_mb}", "#{@park_wrap_ver}",
                          "#{@park_why}", "#{@parked}", "#{@park_held}"])
    rows = command(["tmux", "-u", "-L", socket, "list-windows", "-t", "=" + session, "-F", fmt])
    watched = set(command(["tmux", "-L", socket, "list-clients", "-F", "#{window_id}"]).split())
    trees = process_trees(command(["ps", "-axo", "pid=,ppid=,rss=,time=,command="]))
    path = Path(cache_dir) / ("park-cpu-" + session + ".json")
    try:
        previous = json.loads(path.read_text())
    except (OSError, ValueError):
        previous = {}
    now, next_sample, result = time.time(), {}, {}
    for row in rows.split("\n"):
        fields = row.split("\x1f")
        if len(fields) != 10:
            continue
        wid, pid, role, name, parked, saved, wrap, why, gate_parked, held = fields
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
        next_sample[wid] = {"at": now, "cpu": cpu, "pid": pid, "quiet": quiet} if elapsed >= 60 or old.get("pid") != pid else old
        try:
            saved_mb = max(0, float(saved)) if saved else None
            if saved_mb is not None and not math.isfinite(saved_mb):
                saved_mb = None
        except ValueError:
            saved_mb = None
        result[wid] = {"state": "parked" if parked == "停放中" or (gate_parked and held) else "awake",
                       "rss_mb": round(rss, 2) if known else None, "saved_mb": saved_mb,
                       "why": "watched" if wid in watched else why or ("old-shell" if not wrap else "idle-delay"), "quiet": quiet}
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(".%d.tmp" % os.getpid())
        temp.write_text(json.dumps(next_sample))
        temp.replace(path)
    except OSError:
        pass  # No writable sample cache: eligibility stays unknown, never zero.
    return result


def summarize(workers):
    if any("park" not in w for w in workers):
        return None  # An older adapter cannot supply a partial, optimistic sum.
    out = dict(sessions_working=0, sessions_idle=0, sessions_parked=0,
               idle_rss_mb=0.0, parked_saved_mb=0.0, idle_reasons={}, idle_eligible=0, idle_eligible_rss_mb=0.0)
    reasons = Counter()
    for w in workers:
        p = w["park"]
        if p["state"] == "parked":
            out["sessions_parked"] += 1
            if p["saved_mb"] is None:
                out["parked_saved_mb"] = None
            elif out["parked_saved_mb"] is not None:
                out["parked_saved_mb"] += p["saved_mb"]
        elif w.get("state") not in ("done", "idle", "looping", "needs", "exited") or p.get("quiet") is False:
            out["sessions_working"] += 1
        else:
            out["sessions_idle"] += 1
            if p["rss_mb"] is None:
                out["idle_rss_mb"] = None
            elif out["idle_rss_mb"] is not None:
                out["idle_rss_mb"] += p["rss_mb"]
            why = "background" if w.get("busy") == "bg" else p["why"]
            if p.get("quiet") is None and why == "idle-delay":
                why = "sampling"
            reasons[why] += 1
            if p["quiet"] is None:
                out["idle_eligible"] = None
                out["idle_eligible_rss_mb"] = None
            elif out["idle_eligible"] is not None and p["quiet"] and why not in ("watched", "background"):
                out["idle_eligible"] += 1
                if p["rss_mb"] is None:
                    out["idle_eligible_rss_mb"] = None
                elif out["idle_eligible_rss_mb"] is not None:
                    out["idle_eligible_rss_mb"] += p["rss_mb"]
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
                    scheduled += 1
                    timely += 0 <= float(row["started"]) - float(row["next"]) <= 30
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
        total = {k: sum(s[k] for s in totals) for k in ("sessions_working", "sessions_idle", "sessions_parked")}
        saved = None if any(s["parked_saved_mb"] is None for s in totals) else sum(s["parked_saved_mb"] for s in totals)
        idle_rss = None if any(s["idle_rss_mb"] is None for s in totals) else sum(s["idle_rss_mb"] for s in totals)
        reasons = Counter()
        for s in totals:
            reasons.update(s["idle_reasons"])
        eligible = None if any(s["idle_eligible"] is None for s in totals) else sum(s["idle_eligible"] for s in totals)
        eligible_rss = None if any(s["idle_eligible_rss_mb"] is None for s in totals) else sum(s["idle_eligible_rss_mb"] for s in totals)
        detail = " · eligible " + ("unknown (needs 60s CPU sample)" if eligible is None else str(eligible))
        detail += " / " + ("unknown" if eligible_rss is None else "%.1f MB" % eligible_rss)
        if reasons:
            detail += " · " + ", ".join("%s %d" % pair for pair in sorted(reasons.items()))
        print("working {sessions_working} · idle {sessions_idle} · parked {sessions_parked} · saved ".format(**total) + ("unknown" if saved is None else "%.1f MB" % saved) + " · idle RSS " + ("unknown" if idle_rss is None else "%.1f MB" % idle_rss) + detail)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, RuntimeError) as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
