#!/usr/bin/env python3
"""fleet_upstream_stats.py — what the machine's credential proxy met upstream
(T657): the ONE reader of the per-minute counts bin/fleet-cred-proxy.py writes
(UpstreamStats: upstream-stats.ndjson + the open minute in upstream-now.json,
0644 — every login reads them; never a token, a header or a body).

    fleet_upstream_stats.py doctor            the doctor's 上游 row: `PASS|WARN — <text>`
                                              (exit 3 = nothing recorded on this machine: no row)
    fleet_upstream_stats.py show [--since 24h] [--json]
                                              the detail: each class's count, per account, and
                                              every failure (time · class · account · login ·
                                              session · route · ms · what) — `fleet-cred-proxy.sh upstream`
    fleet_upstream_stats.py banner            the 看台's line: `<class>\\t<its n>` while the last
                                              FLEET_UPSTREAM_BANNER_SECS (300) hold at least
                                              FLEET_UPSTREAM_BANNER_MIN (3) connection / 5xx /
                                              529 / 429 failures and they are at least
                                              FLEET_UPSTREAM_BANNER_PCT (20) % of the attempts;
                                              nothing otherwise (exit 1)

Where: $FLEET_UPSTREAM_STATS_DIR, else the shared proxy's (the record's "stats",
<root base>/.stats, its run dir), else this login's own proxy dir
($FLEET_CONF_DIR/cred-proxy). Classes: ok · refused · reset · timeout · tls · dns
· neterr · 4xx · 429 · 5xx · 529.
"""
import json
import os
import sys
import time
import unicodedata

FILE, NOW = "upstream-stats.ndjson", "upstream-now.json"
CLASSES = ("refused", "reset", "timeout", "tls", "dns", "neterr", "429", "4xx", "5xx", "529")
# what the top line calls 「上游连不上」: the road or the provider failing, never
# a request the provider turned down as malformed (a plain 4xx)
BANNER = ("refused", "reset", "timeout", "tls", "dns", "neterr", "429", "5xx", "529")
WORDS = {"ok": "成功", "refused": "连接被拒", "reset": "连接被重置", "timeout": "连接超时", "tls": "TLS 失败",
         "dns": "DNS 失败", "neterr": "网络错误", "4xx": "4xx", "429": "429 限流", "5xx": "5xx", "529": "529 过载"}


def stats_dir():
    d = os.environ.get("FLEET_UPSTREAM_STATS_DIR")
    if d:
        return d if os.path.isfile(os.path.join(d, FILE)) or os.path.isfile(os.path.join(d, NOW)) else ""
    root = os.environ.get("FLEET_CREDSEP_ROOT_BASE") or "/var/db/fleet-cred"
    cands = []
    try:
        with open(os.path.join(root, ".shared.json")) as f:
            rec = json.load(f)
        cands += [rec.get("stats") or "", rec.get("run") or ""]
    except (OSError, ValueError, AttributeError):
        pass
    conf = os.environ.get("FLEET_CONF_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "claude-fleet")
    cands += [os.path.join(root, ".stats"), os.path.join(conf, "cred-proxy")]
    for c in cands:
        if c and (os.path.isfile(os.path.join(c, FILE)) or os.path.isfile(os.path.join(c, NOW))):
            return c
    return ""


def _rows(d, since, tail=None):
    """Every minute row from `since` on, the open minute last. `tail` bytes read
    off the file's end only (the top line, every 2 s)."""
    out = []
    try:
        with open(os.path.join(d, FILE), "rb") as f:
            if tail:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - tail))
            data = f.read().decode("utf-8", "replace").splitlines()
        if tail and data:
            data = data[1:]     # a cut first line
    except OSError:
        data = []
    for ln in data:
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        if isinstance(r, dict) and isinstance(r.get("m"), int) and r["m"] + 60 > since:
            out.append(r)
    try:
        with open(os.path.join(d, NOW)) as f:
            r = json.load(f)
        if isinstance(r, dict) and isinstance(r.get("m"), int) and r["m"] + 60 > since and r.get("n"):
            # a minute already closed into the file is not the open one any more
            if not any(x["m"] == r["m"] and x.get("n") == r.get("n") and x.get("c") == r.get("c") for x in out):
                out.append(r)
    except (OSError, ValueError):
        pass
    return out


def summary(rows, since):
    """-> {n, c: {class: n}, a: {acct: {class: n}}, f: [failure…] newest last, ms_max}."""
    s = {"n": 0, "c": {}, "a": {}, "f": [], "ms_max": 0, "ms_sum": 0}
    for r in rows:
        s["n"] += int(r.get("n") or 0)
        s["ms_max"] = max(s["ms_max"], int(r.get("ms_max") or 0))
        s["ms_sum"] += int(r.get("ms_sum") or 0)
        for k, v in (r.get("c") or {}).items():
            s["c"][k] = s["c"].get(k, 0) + int(v)
        for acct, cs in (r.get("a") or {}).items():
            a = s["a"].setdefault(acct, {})
            for k, v in (cs or {}).items():
                a[k] = a.get(k, 0) + int(v)
        s["f"] += [e for e in (r.get("f") or []) if isinstance(e, dict) and (e.get("t") or 0) >= since]
    s["f"].sort(key=lambda e: e.get("t") or 0)
    return s


def fails(s, classes=CLASSES):
    return sum(v for k, v in s["c"].items() if k in classes)


def window(secs, now=None, tail=None):
    now = time.time() if now is None else now
    d = stats_dir()
    if not d:
        return None
    return summary(_rows(d, now - secs, tail), now - secs)


def class_list(s, classes=CLASSES):
    return " · ".join("%s %d" % (WORDS[k], s["c"][k]) for k in sorted(
        (k for k in classes if s["c"].get(k)), key=lambda k: -s["c"][k]))


def pad(text, width):
    """`text` left-aligned in `width` terminal cells (a CJK character is two)."""
    text = str(text)
    used = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)
    return text + " " * max(0, width - used)


def hm(t):
    return time.strftime("%m-%d %H:%M", time.localtime(t))


def doctor(now=None):
    """-> (level, text) or None (nothing recorded)."""
    now = time.time() if now is None else now
    d = stats_dir()
    if not d:
        return None
    h1 = summary(_rows(d, now - 3600), now - 3600)
    h24 = summary(_rows(d, now - 86400), now - 86400)
    f1, f24 = fails(h1), fails(h24)
    text = "近 1 小时 %d 次失败 / %d 次请求%s · 24 小时 %d 次 / %d 次%s" % (
        f1, h1["n"], "（%s）" % class_list(h1) if f1 else "",
        f24, h24["n"], "（%s）" % class_list(h24) if f24 else "")
    last = h24["f"][-1] if h24["f"] else None
    if last:
        text += " · 最近一次 %s %s" % (hm(last["t"]), WORDS.get(last.get("c"), last.get("c")))
    elif f24:
        text += " · 最近一次在 24 小时内"
    text += " — 明细：fleet-cred-proxy.sh upstream --since 24h"
    b1 = fails(h1, BANNER)
    bad = b1 >= 3 and b1 * 100 >= 20 * max(1, h1["n"])
    return ("WARN" if bad else "PASS"), text


def banner(now=None):
    """-> (the commonest failing class, its count) while the upstream is failing, else None."""
    secs = int(os.environ.get("FLEET_UPSTREAM_BANNER_SECS") or 300)
    least = int(os.environ.get("FLEET_UPSTREAM_BANNER_MIN") or 3)
    pct = float(os.environ.get("FLEET_UPSTREAM_BANNER_PCT") or 20)
    s = window(secs, now, tail=65536)
    if not s:
        return None
    n = fails(s, BANNER)
    if n < least or n * 100 < pct * max(1, s["n"]):
        return None
    top = max((k for k in BANNER if s["c"].get(k)), key=lambda k: s["c"][k])
    return top, s["c"][top]


def parse_since(v):
    v = (v or "24h").strip()
    mul = {"s": 1, "m": 60, "h": 3600, "d": 86400}.get(v[-1:], None)
    try:
        return int(float(v[:-1]) * mul) if mul else int(v)
    except ValueError:
        raise SystemExit("--since: %r is not like 30m / 1h / 24h / 7d" % v)


def show(argv):
    since, js = "24h", "--json" in argv
    if "--since" in argv:
        i = argv.index("--since")
        since = argv[i + 1] if i + 1 < len(argv) else ""
    secs = parse_since(since)
    d = stats_dir()
    if not d:
        print("上游：这台机器没有记录（凭据代理没在记，或还没有请求）")
        return 3
    now = time.time()
    s = summary(_rows(d, now - secs), now - secs)
    if js:
        print(json.dumps(dict(s, since=secs, dir=d), ensure_ascii=False))
        return 0
    print("上游 · 近 %s · %d 次请求 · %d 次失败 · 最慢 %d ms · %s" % (since, s["n"], fails(s), s["ms_max"], d))
    print("  %s %6s" % (pad("类别", 12), "次数"))
    for k in ("ok",) + CLASSES:
        if s["c"].get(k):
            print("  %s %6d" % (pad(WORDS[k], 12), s["c"][k]))
    if s["a"]:
        print("  按账号：")
        for acct in sorted(s["a"]):
            cs = s["a"][acct]
            print("    %s %s" % (pad(acct, 24), " · ".join("%s %d" % (WORDS.get(k, k), v) for k, v in sorted(cs.items()))))
    if s["f"]:
        print("  失败明细（时间 · 类别 · 账号 · 登录 · 会话 · 路 · 耗时 · 原话）：")
        for e in s["f"]:
            print("    %s  %s %s %s %s %s %6s ms  %s" % (
                time.strftime("%m-%d %H:%M:%S", time.localtime(e.get("t") or 0)),
                pad(WORDS.get(e.get("c"), e.get("c")), 10), pad(e.get("acct", "-"), 20), pad(e.get("login", "-"), 10),
                pad(e.get("sid", "-"), 14), pad(e.get("route", "-"), 8), e.get("ms", "-"), e.get("st", "")))
        listed = len(s["f"])
        if listed < fails(s):
            print("    （每分钟最多记 40 条明细；共 %d 次失败，列出 %d 条）" % (fails(s), listed))
    return 0


def main(argv):
    if argv[:1] == ["doctor"]:
        r = doctor()
        if not r:
            return 3
        print("%s — %s" % r)
        return 0
    if argv[:1] == ["show"]:
        return show(argv[1:])
    if argv[:1] == ["banner"]:
        b = banner()
        if not b:
            return 1
        print("%s\t%d" % b)
        return 0
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
