#!/usr/bin/env python3
"""fleet route — pin the route the client takes to a machine (claude-fleet#2886).

    fleet route                              every machine: its route, auto or
                                             pinned, and the last handshakes
    fleet route <machine>                    that one machine
    fleet route <machine> auto|relay|direct|tailscale|<route name>|<host[:port]>
                                             pin it (auto: back to measuring)
    fleet route --json                       the list as JSON
    fleet route --get <name>…                the pin of the first name that has
                                             one (exit 1: none) — the view loop
    fleet route --pick                       choose one by number — ⌘P 连接路线…

A pinned machine is connected over that one route every time — `fleet
connect`, the client's warm connection and its view loop alike: no measuring,
no switching to a faster line, and a drop comes back over the same route (the
bar says 「钉住：中转（手动）· 第 N 次重连」, and after 5 failures in a row
suggests going back to auto — it never goes back by itself). `auto` is the
measuring `fleet connect` has always done; a reconnect there tries the route
remembered last first, and measures every route only when that one does not
answer.

The routes: `relay` — through the hub (入口中转); `tailscale` — the machine's
tailnet name; `direct` — its first direct route that is not the tailnet, in the
hub's order (`lan`, `public` …); any route name the hub lists; or an address,
host[:port] (port 22 when none). The pins live in ~/.config/claude-fleet/routes,
one `<machine> <route>` a line.

Standard library only, beside fleet-connect.py (whose functions it uses).
"""
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def connect_module():
    spec = importlib.util.spec_from_file_location("fleet_connect", os.path.join(HERE, "fleet-connect.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


fc = connect_module()


def known():
    """{alias: entry} — every machine the connect cache remembers, once."""
    cache = fc.load_cache()
    entries = cache.get("machines") if isinstance(cache.get("machines"), dict) else {}
    out = {}
    for ent in entries.values():
        m = ent.get("machine") if isinstance(ent, dict) else None
        if not isinstance(m, dict):
            continue
        name = m.get("alias") or m.get("hostname")
        if name and (name not in out or float(ent.get("at", 0)) > float(out[name].get("at", 0))):
            out[name] = ent
    return out, cache.get("last") or ""


def canon(name):
    """NAME as the machine's alias when the cache knows it by any of its names."""
    ms, _ = known()
    for alias, ent in ms.items():
        if name in fc.machine_names(ent.get("machine")) or name == alias:
            return alias
    return name


def pin_of(*names):
    ms, _ = known()
    more = []
    for n in names:
        for alias, ent in ms.items():
            if n in fc.machine_names(ent.get("machine")):
                more += fc.machine_names(ent.get("machine"))
    return fc.pin_for(*(list(names) + more))


def ago(t):
    s = max(0, int(time.time() - float(t or 0)))
    if s < 60:
        return "刚刚"
    if s < 3600:
        return "%d 分钟前" % (s // 60)
    if s < 86400:
        return "%d 小时前" % (s // 3600)
    return "%d 天前" % (s // 86400)


def rows():
    ms, last = known()
    pins = fc.load_pins()
    names = sorted(set(ms) | set(pins), key=lambda n: (n != last, n))
    out = []
    for n in names:
        ent = ms.get(n) or {}
        pin = pin_of(n)
        r = ent.get("route") or {}
        table = [{"name": t.get("name"), "ok": t.get("ok"), "median_ms": t.get("median_ms"), "skip": t.get("skip")}
                 for t in ent.get("table") or [] if isinstance(t, dict)]
        out.append({"machine": n, "mode": "manual" if pin else "auto", "pin": pin,
                    "route": {"kind": r.get("kind"), "name": r.get("name")} if r else None,
                    "measured_at": ent.get("at") if table else None, "table": table,
                    "last": n == last})
    return out


def handshakes(row):
    if not row["table"]:
        return "（还没测过）"
    parts = []
    for t in row["table"]:
        label = "中转" if t["name"] == "relay" else t["name"]
        if t.get("skip"):
            parts.append("%s —" % label)
        elif t.get("median_ms") is not None:
            parts.append("%s %.0fms" % (label, t["median_ms"]))
        else:
            parts.append("%s 不通" % label)
    return " · ".join(parts) + "（%s）" % ago(row["measured_at"])


def describe(row):
    if row["pin"]:
        return "钉住：%s（手动）" % fc.pin_label(row["pin"])
    r = row["route"]
    return "自动" + ("（上次 %s）" % fc.route_label(r["kind"], r["name"]) if r and r.get("kind") else "")


def print_list(only=None):
    rs = [r for r in rows() if only is None or r["machine"] == only]
    if only is not None and not rs:
        rs = [{"machine": only, "mode": "auto", "pin": "", "route": None, "measured_at": None, "table": [],
               "last": False}]
    if not rs:
        print("还没连过任何机器 · 钉一条：fleet route <机器> relay|direct|tailscale|<地址>")
        return 0
    w = max(4, max(fc_cells(r["machine"]) + (2 if r["last"] else 0) for r in rs)) + 2
    print(fc.pad("机器", w) + fc.pad("路线", 24) + "最近一次各路线握手")
    for r in rs:
        print(fc.pad(r["machine"] + (" *" if r["last"] else ""), w) + fc.pad(describe(r), 24) + handshakes(r))
    print("改：fleet route <机器> auto|relay|direct|tailscale|<地址[:端口]>")
    return 0


def fc_cells(s):
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def set_pin(machine, route):
    if not fc.PIN_RE.match(route):
        sys.stderr.write("fleet route: 「%s」不是一条路线 — auto · relay · direct · tailscale · 路线名 · 地址[:端口]\n" % route)
        return 2
    name = canon(machine)
    ms, _ = known()
    fc.save_pin(name, route)
    if route == "auto":
        print("%s 改回自动选路：下次连接测速选最快的；重连先试上次那条" % name)
    else:
        print("已钉住 %s：%s（手动）· 从下次连接起只走这条，不测速、不切换 · 改回：fleet route %s auto"
              % (name, fc.pin_label(route), name))
        if name not in ms:
            print("（还没连过 %s：连的时候才知道它有没有这条线）" % name)
    return 0


def pick():
    """The ⌘P popup: a machine (the one used last by default), then a route."""
    rs = rows()
    if not rs:
        print("还没连过任何机器 — 先用 fleet 连一次")
        input("回车关闭 ")
        return 1
    for i, r in enumerate(rs, 1):
        print("  %d  %s  %s" % (i, fc.pad(r["machine"], 12), describe(r)))
    a = input("哪台机器？[1] ").strip() or "1"
    if not a.isdigit() or not 1 <= int(a) <= len(rs):
        return 1
    r = rs[int(a) - 1]
    print("\n%s · 最近握手：%s\n" % (r["machine"], handshakes(r)))
    opts = [("auto", "自动（测速选最快）"), ("relay", "入口中转"), ("direct", "直连"), ("tailscale", "Tailscale"),
            ("", "某个地址…")]
    for i, (k, label) in enumerate(opts, 1):
        print("  %d  %s%s" % (i, label, "  ← 现在" if (k == (r["pin"] or "auto")) else ""))
    b = input("走哪条？ ").strip()
    if not b.isdigit() or not 1 <= int(b) <= len(opts):
        return 1
    route = opts[int(b) - 1][0] or input("地址（host 或 host:port）：").strip()
    if not route:
        return 1
    rc = set_pin(r["machine"], route)
    print("\n已生效于下次连接 · 断开或重连时换到这条")
    time.sleep(2)
    return rc


def main(argv):
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    if argv[:1] == ["--json"]:
        print(json.dumps(rows(), ensure_ascii=False))
        return 0
    if argv[:1] == ["--get"]:
        p = pin_of(*argv[1:])
        if p:
            print(p)
        return 0 if p else 1
    if argv[:1] == ["--pick"]:
        try:
            return pick()
        except (EOFError, KeyboardInterrupt):
            return 1
    if not argv:
        return print_list()
    if len(argv) == 1:
        return print_list(canon(argv[0]))
    if len(argv) == 2:
        return set_pin(argv[0], argv[1])
    sys.stderr.write("用法：fleet route [<机器> [auto|relay|direct|tailscale|<地址>]]（fleet route --help）\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
