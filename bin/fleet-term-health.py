#!/usr/bin/env python3
"""fleet term health — how the browser terminals held up (task RMVE).

    fleet term health [--hours N] [--json]

Reads GET /v1/fleet/term/health — the operator's: auth and hub as `fleet hub`
(CCQUOTA_VIEWER_TOKEN, else FLEET_HUB_SESSION; --hub, else the configured hub)
— and prints, over the last N hours (default 24):

    打开就连上        a page opened (or a button pressed) that got a path in 10 s
    断开后自己接回    a terminal that had a path and dropped (not because its page
                      went) that came back by itself within a minute, and how fast
    人工点按钮        connections a button made — the target is 0

then each drop's cause (hub_restart · node_closed · ended · …).
`--from <file>` reads that answer from a file instead (the selftest's seam).

Exit 0 printed · 1 the hub refused · 2 usage · 3 no hub / no credential / unreachable.
"""
import argparse
import importlib.util
import json
import os
import sys

HEALTH_PATH = "/v1/fleet/term/health"

REASON = {"hub_restart": "入口发布", "node_closed": "家里节点断开", "ended": "终端结束",
          "open_elsewhere": "另一处打开", "interrupted": "终端换代", "node_error": "节点出错",
          "revoked": "登录失效", "node_unavailable": "节点重连", "maintenance": "维护中",
          "door_unavailable": "门不可用"}


def die(msg, rc=1):
    print("fleet term health · " + msg, file=sys.stderr)
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


def pad(label, width=18):
    # CJK counts two columns
    w = sum(2 if ord(c) > 0x2e80 else 1 for c in label)
    return label + " " * max(1, width - w)


def pct(n, d):
    return "—" if not d else "%d%%（%d/%d）" % (round(100.0 * n / d), n, d)


def render(h, hours):
    out = ["网页终端 · 近 %d 小时 · %d 条连接" % (hours, h.get("sessions") or 0)]
    out.append("  " + pad("打开就连上") + pct(h.get("opens_ok") or 0, h.get("opens") or 0))
    line = pct(h.get("recovered") or 0, h.get("drops") or 0)
    if h.get("recovered"):
        line += " · 中位 %.1f 秒 · p95 %.1f 秒" % (h.get("recover_p50_secs") or 0, h.get("recover_p95_secs") or 0)
    out.append("  " + pad("断开后自己接回") + line)
    out.append("  " + pad("人工点按钮") + "%d 次" % (h.get("manual") or 0))
    reasons = h.get("drop_reasons") or {}
    if reasons:
        out.append("断开原因")
        for k, n in sorted(reasons.items(), key=lambda kv: -kv[1]):
            out.append("  " + pad(REASON.get(k, k)) + str(n))
    if h.get("unrecorded"):
        out.append("  （另 %d 条没写收尾：入口副本走得比收尾快）" % h["unrecorded"])
    return "\n".join(out)


def main(argv):
    ap = argparse.ArgumentParser(prog="fleet term health", description=__doc__.split("\n")[0])
    ap.add_argument("--hours", type=int, default=24, help="how many hours back (1..720, default 24)")
    ap.add_argument("--json", action="store_true", help="print the hub's answer as JSON")
    ap.add_argument("--hub", help="the hub's URL")
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--from", dest="from_file", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    if not 1 <= a.hours <= 720:
        die("--hours: want 1..720, got %d" % a.hours, 2)
    if a.from_file:
        try:
            with open(a.from_file) as f:
                h = json.load(f)
        except (OSError, ValueError) as e:
            die("--from %s: %s" % (a.from_file, e), 2)
    else:
        h = hub_admin().call(a, "GET", "%s?hours=%d" % (HEALTH_PATH, a.hours))
    print(json.dumps(h, ensure_ascii=False, indent=2) if a.json else render(h, a.hours))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
