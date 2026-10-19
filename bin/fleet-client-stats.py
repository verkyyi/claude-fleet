#!/usr/bin/env python3
"""fleet-client-stats.py — the client's stability, read off its own logs: how
often the line drops, how fast it comes back, how often opening it draws nothing
(issue #4824, EPIC #4823 C1 — 共同约定 7: the ONE ruler, before and after).

    bin/fleet-client-stats.py [--json] [--days N] [--now ISO] <dir>…

Each <dir> is ONE computer's logs, in any of three layouts:
  · a client cache       ~/.cache/claude-fleet           thin.log + shell/logs/*.log
  · a diagnosis bundle   `fleet doctor --bundle <dir>`   logs/thin.log + logs/*.log
  · a bare log dir       …/shell/logs (or a copy)        thin.log? + connect.log + place.log
A rotated `<name>.1` is read before `<name>`. Only the last N days (default 7,
counted back from --now, default now) are read. The fields are
docs/dev/CLIENT-LOGS.md's; nothing is written anywhere.

The three readings (EPIC #4823 «读数口径»):

  drops / computer / day
      thin.log `connect` lines with reason `up` (the view was up, then the
      connection ended) whose NEXT lifecycle event is not `quit` / `end` — the
      person did not end it, the line did (ssh 255, cut). Divided by
      computer-days: the UTC days on which that computer's thin client logged
      anything (an unused day does not dilute it).
  reconnect (median / p90)
      from a drop's `connect` line to the next `drawn` line (the view drawn
      again) — the backoff, the pick (pick_ms) and the far end's first view
      (first_ms) are all inside that gap. Whole seconds (the log's resolution).
      A drop with no `drawn` before the client ended is counted `unrecovered`.
  open failures
      a START is the first lifecycle event after a `quit` / `end` (or at the
      top of the log); it failed when its first `connect` did not come up — rc
      1 from the pick (`fleet-connect --argv exit 1`: the hub gave no machine,
      which is also connect.log's `home` line) or `never up` — or when a
      `first` line in it said rc 1 (the first session did not open). `never up`
      with rc 3 is not a failure by itself: it is the first-session road (the
      home has no fleet of yours yet), judged by its `first` line. Reported
      beside it: starts that never drew a view at all, connect.log `home`
      failures by code, place.log asks and their non-zero exits.

Lifecycle events are connect · drawn · first · quit · end · exec · offline ·
rehome · restart; `run` (a one-shot `fleet ls/open/…`, its own process), `say`,
`open` and `upload` are ignored.

Exit 0 · 2 usage / nothing readable.
"""
import calendar
import json
import os
import sys
import time

LIFE = {"connect", "drawn", "first", "quit", "end", "exec", "offline", "rehome", "restart"}
TERMINAL = {"quit", "end"}


def epoch(ts):
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, TypeError):
        return None


def read_lines(path):
    rows = []
    for p in (path + ".1", path):
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                for line in f:
                    fs = line.rstrip("\n").split("\t")
                    t = epoch(fs[0]) if fs else None
                    if t is not None and len(fs) >= 2:
                        rows.append((t, fs))
        except OSError:
            pass
    rows.sort(key=lambda r: r[0])   # stable: same-second lines keep file order
    return rows


def locate(d):
    """(thin.log path | None, shell log dir | None) for one computer's dir."""
    thin = next((p for p in (os.path.join(d, "thin.log"), os.path.join(d, "logs", "thin.log"))
                 if os.path.exists(p) or os.path.exists(p + ".1")), None)
    logs = next((p for p in (os.path.join(d, "shell", "logs"), os.path.join(d, "logs"), d)
                 if any(os.path.exists(os.path.join(p, n)) or os.path.exists(os.path.join(p, n + ".1"))
                        for n in ("connect.log", "place.log"))), None)
    return thin, logs


def f(fs, i):
    return fs[i] if len(fs) > i else ""


def thin_stats(rows):
    days, starts, drops, gaps = set(), [], 0, []
    unrecovered = vanished = 0
    by_route = {}       # drops by the route that was up
    online_gaps = []    # gaps with no `offline` inside: this computer's own line was up
    cur = None          # the start being read: {"first_connect": fs|None, "first_rc1": bool, "drawn": bool}
    pending = None      # a drop's (time, offline seen since), waiting for the next drawn
    live = False        # a view drawn and its connection not yet ended (no `connect` line)
    life = [(t, fs) for t, fs in rows if fs[1] in LIFE]
    for i, (t, fs) in enumerate(life):
        ev = fs[1]
        days.add(time.strftime("%Y-%m-%d", time.gmtime(t)))
        if ev == "drawn" and live:
            # a second view with no end to the first: that process went with no
            # line at all (SIGKILL, a crash, the computer off) — a new start
            vanished += 1
            if pending is not None:
                unrecovered += 1
                pending = None
            cur = None
        if cur is None and ev not in TERMINAL:
            cur = {"first_connect": None, "first_rc1": False, "drawn": False}
            starts.append(cur)
        if ev == "drawn":
            live = True
            cur["drawn"] = True
            if pending is not None:
                gaps.append(t - pending[0])
                if not pending[1]:
                    online_gaps.append(t - pending[0])
                pending = None
        elif ev == "offline" and pending is not None:
            pending = (pending[0], True)
        elif ev == "first" and f(fs, 7) == "1":
            cur["first_rc1"] = True
        elif ev == "connect":
            live = False
            if cur["first_connect"] is None:
                cur["first_connect"] = fs
            if f(fs, 8) == "up":
                nxt = next((x for _, x in life[i + 1:]), None)
                if nxt is None or nxt[1] not in TERMINAL:
                    drops += 1
                    by_route[f(fs, 3) or "-"] = by_route.get(f(fs, 3) or "-", 0) + 1
                    if pending is not None:   # dropped again before it was drawn
                        unrecovered += 1
                    pending = (t, False)
        if ev in TERMINAL:
            if pending is not None:
                unrecovered += 1
                pending = None
            cur, live = None, False
    if pending is not None:
        unrecovered += 1

    def failed(s):
        c = s["first_connect"]
        if s["first_rc1"]:
            return True
        if c is None:
            return False
        r = f(c, 8)
        return r not in ("up", "quit") and not (r == "never up" and f(c, 7) == "3")
    fail_by = {}
    for st in starts:
        if failed(st):
            c = st["first_connect"]
            k = "first rc 1" if st["first_rc1"] and (c is None or f(c, 8) in ("up", "quit") or (
                f(c, 8) == "never up" and f(c, 7) == "3")) else "%s rc %s" % (f(c, 8), f(c, 7))
            fail_by[k] = fail_by.get(k, 0) + 1
    return {
        "days": sorted(days), "starts": len(starts), "open_failed": sum(1 for s in starts if failed(s)),
        "open_fail_by": fail_by, "drops_by_route": by_route,
        "never_drawn": sum(1 for s in starts if not s["drawn"]),
        "drops": drops, "gaps": gaps, "online_gaps": online_gaps, "unrecovered": unrecovered,
        "vanished": vanished,
    }


def shell_stats(logs, lo, hi):
    home, place = {}, {"asks": 0, "nonzero": 0, "by": {}}
    if not logs:
        return home, place
    for _, fs in window(read_lines(os.path.join(logs, "connect.log")), lo, hi):
        if fs[1] == "home":
            code = f(fs, 5) or "-"
            home[code] = home.get(code, 0) + 1
    for _, fs in window(read_lines(os.path.join(logs, "place.log")), lo, hi):
        res = f(fs, 5)
        place["asks"] += 1
        place["by"][res] = place["by"].get(res, 0) + 1
        if not res.endswith(" 0"):
            place["nonzero"] += 1
    return home, place


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[max(0, min(len(s) - 1, -(-p * len(s) // 100) - 1))]   # nearest rank


def window(rows, lo, hi):
    return [(t, fs) for t, fs in rows if lo <= t <= hi]


def main(argv):
    as_json, days, now, dirs = False, 7, None, []
    it = iter(argv)
    for a in it:
        if a == "--json":
            as_json = True
        elif a == "--days":
            days = int(next(it, "7"))
        elif a == "--now":
            now = epoch(next(it, ""))
            if now is None:
                print("fleet-client-stats: --now wants 2026-10-19T00:00:00Z", file=sys.stderr)
                return 2
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            dirs.append(a)
    if not dirs:
        print("usage: fleet-client-stats.py [--json] [--days N] [--now ISO] <dir>…", file=sys.stderr)
        return 2
    hi = now if now is not None else int(time.time())
    lo = hi - days * 86400
    per, agg = [], {"drops": 0, "computer_days": 0, "gaps": [], "online_gaps": [], "unrecovered": 0,
                    "vanished": 0, "drops_by_route": {}, "open_fail_by": {}, "starts": 0,
                    "open_failed": 0, "never_drawn": 0, "home": {}, "place_asks": 0, "place_nonzero": 0}
    for d in dirs:
        thin, logs = locate(d)
        if not thin and not logs:
            print("fleet-client-stats: %s: no thin.log / connect.log / place.log there" % d, file=sys.stderr)
            continue
        ts = thin_stats(window(read_lines(thin), lo, hi) if thin else [])
        home, place = shell_stats(logs, lo, hi)
        name = os.path.basename(os.path.normpath(d))
        try:   # a bundle names its computer
            with open(os.path.join(d, "manifest.json")) as m:
                name = json.load(m).get("host") or name
        except (OSError, ValueError, AttributeError):
            pass
        nd = len(ts["days"])
        per.append({"computer": name, "dir": d, "days": nd, "first_day": ts["days"][0] if nd else None,
                    "last_day": ts["days"][-1] if nd else None, "drops": ts["drops"],
                    "drops_per_day": round(ts["drops"] / nd, 2) if nd else None,
                    "reconnect_median_s": pct(ts["gaps"], 50), "reconnect_p90_s": pct(ts["gaps"], 90),
                    "reconnect_online_median_s": pct(ts["online_gaps"], 50),
                    "reconnect_online_p90_s": pct(ts["online_gaps"], 90),
                    "reconnects": len(ts["gaps"]), "unrecovered": ts["unrecovered"], "vanished": ts["vanished"],
                    "drops_by_route": ts["drops_by_route"], "open_fail_by": ts["open_fail_by"],
                    "starts": ts["starts"], "open_failed": ts["open_failed"], "never_drawn": ts["never_drawn"],
                    "home_fail": home, "place_asks": place["asks"], "place_nonzero": place["nonzero"],
                    "place_by": place["by"]})
        agg["drops"] += ts["drops"]
        agg["computer_days"] += nd
        agg["gaps"] += ts["gaps"]
        agg["online_gaps"] += ts["online_gaps"]
        agg["vanished"] += ts["vanished"]
        for key in ("drops_by_route", "open_fail_by"):
            for k, v in ts[key].items():
                agg[key][k] = agg[key].get(k, 0) + v
        agg["unrecovered"] += ts["unrecovered"]
        agg["starts"] += ts["starts"]
        agg["open_failed"] += ts["open_failed"]
        agg["never_drawn"] += ts["never_drawn"]
        for k, v in home.items():
            agg["home"][k] = agg["home"].get(k, 0) + v
        agg["place_asks"] += place["asks"]
        agg["place_nonzero"] += place["nonzero"]
    if not per:
        return 2
    cd = agg["computer_days"]
    out = {
        "v": 1, "window": {"days": days, "from": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(lo)),
                           "to": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(hi))},
        "computers": len(per), "computer_days": cd,
        "drops": agg["drops"], "drops_per_computer_day": round(agg["drops"] / cd, 2) if cd else None,
        "reconnects": len(agg["gaps"]), "unrecovered": agg["unrecovered"],
        "reconnect_median_s": pct(agg["gaps"], 50), "reconnect_p90_s": pct(agg["gaps"], 90),
        "reconnect_online_median_s": pct(agg["online_gaps"], 50),
        "reconnect_online_p90_s": pct(agg["online_gaps"], 90), "reconnects_online": len(agg["online_gaps"]),
        "drops_by_route": agg["drops_by_route"], "open_fail_by": agg["open_fail_by"], "vanished": agg["vanished"],
        "starts": agg["starts"], "open_failed": agg["open_failed"],
        "open_fail_rate": round(agg["open_failed"] / agg["starts"], 4) if agg["starts"] else None,
        "never_drawn": agg["never_drawn"], "home_fail": agg["home"],
        "place_asks": agg["place_asks"], "place_nonzero": agg["place_nonzero"],
        "place_fail_rate": round(agg["place_nonzero"] / agg["place_asks"], 4) if agg["place_asks"] else None,
        "per_computer": per,
    }
    if as_json:
        print(json.dumps(out, ensure_ascii=False, indent=1))
        return 0
    na = lambda v, u="": "—" if v is None else "%s%s" % (v, u)
    print("fleet client stats · %d 台 · %d 台·天 · %s → %s（最近 %d 天）" % (
        out["computers"], cd, out["window"]["from"][:10], out["window"]["to"][:10], days))
    print("  断线 / 台 / 天     %s（%d 次断线）" % (na(out["drops_per_computer_day"]), out["drops"]))
    print("  接回 中位 / p90    %s / %s（%d 次接回，%d 次没接回）" % (
        na(out["reconnect_median_s"], " 秒"), na(out["reconnect_p90_s"], " 秒"), out["reconnects"], out["unrecovered"]))
    if out["reconnects_online"] != out["reconnects"]:
        print("    本机网络在线时    %s / %s（%d 次；其余期间本机自己也连不上入口）" % (
            na(out["reconnect_online_median_s"], " 秒"), na(out["reconnect_online_p90_s"], " 秒"),
            out["reconnects_online"]))
    top = lambda d: " · ".join("%s %d" % kv for kv in sorted(d.items(), key=lambda kv: (-kv[1], kv[0])))
    if out["drops_by_route"]:
        print("    断线按线路        " + top(out["drops_by_route"]))
    rate = out["open_fail_rate"]
    print("  打开失败          %s（%d / %d 次启动；%d 次启动一直没画出界面）" % (
        "—" if rate is None else "%.1f%%" % (rate * 100), out["open_failed"], out["starts"], out["never_drawn"]))
    if out["open_fail_by"]:
        print("    失败原因          " + top(out["open_fail_by"]))
    if out["vanished"]:
        print("  无声消失          %d 次（一个界面画着、没有结束行就又开了下一个）" % out["vanished"])
    if out["home_fail"]:
        print("  connect.log home  " + " · ".join("%s %d" % kv for kv in sorted(out["home_fail"].items())))
    if out["place_asks"]:
        print("  place.log         %d 次，非 0 退出 %d" % (out["place_asks"], out["place_nonzero"]))
    for p in per:
        print("  · %s  %d 天（%s → %s）断线 %d · 接回 中位 %s · 启动 %d 失败 %d" % (
            p["computer"], p["days"], p["first_day"] or "-", p["last_day"] or "-", p["drops"],
            na(p["reconnect_median_s"], "s"), p["starts"], p["open_failed"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
