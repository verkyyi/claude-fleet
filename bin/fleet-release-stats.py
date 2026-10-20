#!/usr/bin/env python3
"""fleet release stats — the release ledger's numbers (claude-fleet#3140, EPIC #3139 C1).

`fleet release` itself is bin/fleet-release.sh (the node's release run);
bin/fleet hands it `release stats` here, so it works on a client too.

    fleet release stats [--days N] [--json]

Every release train the CI publishes with its `train` part is written down on
the hub: the merges it carried, each stage's time, and when each managed machine first ran it. This prints, for the last N
days (default 7):

    合并后到所有机器都用上   median / p90 from a merge to the last machine
                             (online and not 维护中 at publish) running it
    每小时发出的版本         trains ÷ the hours master moved in

then each stage's median / p90 and the last few trains. A publish without a
train (from before the train) is in none of it.

A hub that keeps every run (claude-fleet#3870) adds, shipped or not:

    合并到 stable            median / slowest tenth from a merge to the stable
                             that carries it
    开跑后发出去             shipped of started · one train's median

and each run's line — 「卡在 X 段：N 秒，原因」 for one past 5 minutes or one
that shipped nothing (the hub's rule, the /trains page's words).

Reads GET /v1/fleet/release/stats — the operator's: auth and hub as `fleet hub`
(CCQUOTA_VIEWER_TOKEN, else FLEET_HUB_SESSION; --hub, else the configured hub).
`--from <file>` reads that answer from a file instead (the selftest's seam).

Exit 0 printed · 1 the hub refused · 2 usage · 3 no hub / no credential / unreachable.
"""
import argparse
import calendar
import importlib.util
import json
import os
import sys
import time

STATS_PATH = "/v1/fleet/release/stats"


def die(msg, rc=1):
    print("fleet release · " + msg, file=sys.stderr)
    sys.exit(rc)


def hub_admin():
    """bin/fleet-hub-admin.py — the one place the hub's address and the
    operator's credential are read."""
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "fleet-hub-admin.py")
    spec = importlib.util.spec_from_file_location("fleet_hub_admin", path)
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, os.path.dirname(path))
    spec.loader.exec_module(mod)
    mod.die = die
    return mod


def dur(s):
    if s is None:
        return "—"
    if s < 120:
        return "%d 秒" % round(s)
    if s < 7200:
        return "%d 分" % round(s / 60)
    return "%.1f 时" % (s / 3600)


def when(iso):
    """An RFC 3339 UTC time (the hub's) as this computer's local MM-DD HH:MM."""
    if not iso:
        return "—"
    try:
        epoch = calendar.timegm(time.strptime(iso[:19], "%Y-%m-%dT%H:%M:%S"))
        return time.strftime("%m-%d %H:%M", time.localtime(epoch))
    except (ValueError, OverflowError):
        return iso[:16]


def ms(s):
    """seconds as 3 分 05 秒 — a train's own scale."""
    if s is None:
        return "—"
    n = int(round(s))
    return "%d 分 %02d 秒" % (n // 60, n % 60) if n >= 60 else "%d 秒" % n


RUN_WORD = {"success": "已发", "superseded": "已被超越", "failure": "没发", "cancelled": "没发（取消）"}


def runs_lines(st):
    """What the hub's run ledger adds (claude-fleet#3870); nothing on an older hub."""
    if "runs_started" not in st:
        return []
    out = ["  " + pad("合并到 stable") + "中位 %s · 最慢一成 %s · %d 个合并"
           % (ms(st.get("merge_to_stable_p50")), ms(st.get("merge_to_stable_p95")), st.get("merge_to_stable_n") or 0),
           "  " + pad("开跑后发出去") + "%d/%d · 一趟中位 %s"
           % (st.get("runs_shipped") or 0, st.get("runs_started") or 0, ms(st.get("run_p50_secs")))]
    runs = (st.get("runs") or [])[:10]
    if runs:
        out.append("每一趟（超过 5 分钟或没发的，说出卡在哪段）")
        for r in runs:
            line = "  %s  %s  %s  %s" % (str(r.get("sha", ""))[:7], when(r.get("started_at")),
                                         RUN_WORD.get(r.get("conclusion"), r.get("conclusion") or "?"), ms(r.get("total_secs")))
            b = r.get("bottleneck")
            if b and b.get("stage"):
                line += "  卡在「%s」：%s——%s" % (b["stage"], ms(b.get("secs")), b.get("why") or "")
            elif b:
                line += "  没发出：%s" % (b.get("why") or "")
            out.append(line)
    return out


def pad(label, width=26):
    # CJK counts two columns
    w = sum(2 if ord(c) > 0x2e80 else 1 for c in label)
    return label + " " * max(1, width - w)


def render(st):
    days = st.get("days") or 7
    trains = st.get("trains") or 0
    out = []
    if not trains:
        out.append("发布账 · 近 %d 天 · 还没有带账的发布（旧发布不进统计）" % days)
    else:
        out.append("发布账 · 近 %d 天 · %d 趟车（%d 趟所有机器都已用上）" % (days, trains, st.get("trains_reached") or 0))
    m = st.get("merge_to_all") or {}
    line = "中位 %s · p90 %s · %d 个合并" % (dur(m.get("median_secs")), dur(m.get("p90_secs")), m.get("n") or 0)
    if st.get("merges_pending"):
        line += "（另 %d 个还在路上）" % st["merges_pending"]
    out.append("  " + pad("合并后到所有机器都用上") + line)
    ph = st.get("releases_per_hour") or {}
    rate = ph.get("rate")
    out.append("  " + pad("每小时发出的版本") + ("—" if rate is None else "%.2f（%d 趟 / %d 个 master 在动的小时）"
                                                % (rate, ph.get("releases") or 0, ph.get("active_hours") or 0)))
    out.extend(runs_lines(st))
    stages = st.get("stages") or []
    if stages:
        out.append("各段耗时（中位 / p90）")
        for s in stages:
            out.append("  " + pad(str(s.get("name", "?"))) + "%s / %s · %d 趟"
                       % (dur(s.get("median_secs")), dur(s.get("p90_secs")), s.get("n") or 0))
    recent = st.get("recent") or []
    if recent:
        out.append("最近几趟")
        for r in recent:
            have = "机器 %d/%d" % (r.get("reached") or 0, r.get("machines") or 0)
            if r.get("all_at"):
                have += " · 全部用上 " + when(r["all_at"])
            elif r.get("missing"):
                have += " · 差 " + " ".join(r["missing"])
            elif not r.get("machines"):
                have += " · 发布时没有在线的托管机器"
            out.append("  %s  %s  %d 个合并  %s" % (str(r.get("sha", ""))[:7], when(r.get("published_at")),
                                                 r.get("merges") or 0, have))
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser(prog="fleet release stats", description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=int, default=7, help="how many days back (1..90, default 7)")
    ap.add_argument("--json", action="store_true", help="print the hub's answer as JSON")
    ap.add_argument("--hub", help="the hub's URL")
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--from", dest="from_file", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    if not 1 <= a.days <= 90:
        die("--days: want 1..90, got %d" % a.days, 2)
    if a.from_file:
        try:
            with open(a.from_file) as f:
                st = json.load(f)
        except (OSError, ValueError) as e:
            die("--from %s: %s" % (a.from_file, e), 2)
    else:
        st = hub_admin().call(a, "GET", "%s?days=%d" % (STATS_PATH, a.days))
    if a.json:
        print(json.dumps(st, ensure_ascii=False, indent=2))
    else:
        print(render(st))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
