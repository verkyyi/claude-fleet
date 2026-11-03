#!/usr/bin/env python3
"""fleet_view_link.py — the 看台's word on THIS machine's link to a row's machine
(task FQAR): is that session enterable from here right now, and why not.

A row's state comes from the hub; entering it rides this machine's standing link
(bin/fleet-peerlink.py, its keeper's peerlink/state.json). The two can disagree:
the hub sees the session working while the link to its (machine, login) is down,
and ↵ would only loop on 「正在连…」. So the list asks both — read-only here; the
keeper is the one writer of the state (this module never opens, checks or closes
a link):

    link_state(conf)            peerlink/state.json, or {} (none / unreadable /
                                stale: its keeper stopped — then no word at all)
    link_of(st, machine, login) the link dict for that (machine, login), or None;
                                no login known ⇒ the machine's only link
    unreach(link, now)          seconds the link has been down when its phase is
                                down / connecting / verifying, else None
    overlay(items, st, here, me, now)
                                mark every far, live, non-lost row whose link is
                                not up: e["unreach"] = seconds, e["link_phase"];
                                a row of THIS machine and login is never touched
    unreach_words(secs, en)     「不可进入 · 正在重连 45 秒」
    enter_stats(path, ...)      p50 / p95 / n of the logged enters
                                (logs/view-switch.ndjson's ms), for a target and
                                for its (machine, login)
    node_of(path, machine)      the hub's word on that machine (global/hub_nodes):
                                online|lost, age, place
    detail_lines(e, link, node, stats, now, en, hub_age)
                                the actions page's 「连接」 block: one fact a line,
                                short enough for a ~40-column pane

Optional link fields (a keeper newer than this file may write them, an older one
does not): cause (ok|auth|hostkey|http4xx|http5xx|dns|timeout|network|check|
unknown), err_ts, down_since. Each is used when present, never required. The
durable ledger logs/peerlink.ndjson is not read here.
"""
import json
import os
import time

DOWN_PHASES = ("down", "connecting", "verifying")
# the keeper re-stamps state.json every few seconds (fleet-peerlink.py's STALE,
# 30 s): older than this, nothing it says is current
STATE_STALE = 30.0


def fenv(k, d):
    try:
        return float(os.environ.get(k) or d)
    except ValueError:
        return float(d)


def link_state(conf, now=None):
    """peerlink/state.json under <conf>, {} when there is none, it does not parse,
    or its keeper has not stamped it within FLEET_PEERLINK_STALE (30 s)."""
    try:
        with open(os.path.join(str(conf), "peerlink", "state.json"), encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        return {}
    if not isinstance(st, dict):
        return {}
    now = time.time() if now is None else now
    try:
        ts = float(st.get("ts") or 0)
    except (TypeError, ValueError):
        ts = 0.0
    if now - ts > fenv("FLEET_PEERLINK_STALE", STATE_STALE):
        return {}
    return st


def link_of(st, machine, login=""):
    links = [l for l in (st or {}).get("links") or [] if isinstance(l, dict)]
    m = (machine or "").lower()
    if not m:
        return None
    same = [l for l in links if (l.get("machine") or "").lower() == m]
    if login:
        for l in same:
            if l.get("login") == login:
                return l
        return None
    return same[0] if len(same) == 1 else None


def _num(v):
    try:
        return float(v or 0)
    except (TypeError, ValueError):
        return 0.0


def down_since(link):
    """When the link stopped being enterable: down_since, else bad_since, else the
    phase's since (a link connecting for the first time), else 0."""
    for k in ("down_since", "bad_since", "since"):
        t = _num(link.get(k))
        if t > 0:
            return t
    return 0.0


def unreach(link, now=None):
    if not link or link.get("phase") not in DOWN_PHASES:
        return None
    now = time.time() if now is None else now
    t = down_since(link)
    return max(0, int(now - t)) if t else 0


def overlay(items, st, here, me, now=None):
    """Mark the rows this machine cannot enter right now (in place; the items)."""
    if not st:
        return items
    now = time.time() if now is None else now
    for e in items:
        if e.get("kind") != "sess" or not e.get("far") or e.get("gone") or e.get("lost") or e.get("record_only"):
            continue
        machine, login = e.get("machine") or "", e.get("login") or ""
        if machine == here and (login or me) == me:
            continue                       # this machine and login: no link involved
        link = link_of(st, machine, login)
        secs = unreach(link, now)
        if secs is not None:
            e["unreach"] = secs
            e["link_phase"] = link.get("phase")
    return items


def secs_words(secs, en=False):
    s = max(0, int(secs or 0))
    if s < 120:
        return ("%d s" % s) if en else ("%d 秒" % s)
    if s < 7200:
        return ("%d min" % (s // 60)) if en else ("%d 分钟" % (s // 60))
    return ("%d h" % (s // 3600)) if en else ("%d 小时" % (s // 3600))


def unreach_words(secs, en=False):
    if en:
        return "can't enter · reconnecting %s" % secs_words(secs, True)
    return "不可进入 · 正在重连 %s" % secs_words(secs)


def _tail_lines(path, limit):
    try:
        with open(str(path), "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - limit))
            data = f.read()
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    return lines[1:] if size > limit else lines


def pct(vals, p):
    if not vals:
        return None
    v = sorted(vals)                      # nearest rank
    k = max(0, min(len(v) - 1, -(-p * len(v) // 100) - 1))
    return v[k]


def enter_stats(path, target="", machine="", login="", limit=262144):
    """{"target": (p50, p95, n), "link": (p50, p95, n)} over the last <limit>
    bytes of view-switch.ndjson: the enters of this very target, and of every
    target on that (machine, login). A missing log or no match ⇒ n = 0."""
    by_t, by_l = [], []
    m = (machine or "").lower()
    for line in _tail_lines(path, limit):
        try:
            r = json.loads(line)
            ms = float(r.get("ms"))
        except (ValueError, TypeError, AttributeError):
            continue
        if r.get("method") in ("gone", "far-none"):
            continue
        if target and r.get("to") == target:
            by_t.append(ms)
        if m and (r.get("machine") or "").lower() == m and (not login or r.get("login") == login):
            by_l.append(ms)
    return {"target": (pct(by_t, 50), pct(by_t, 95), len(by_t)),
            "link": (pct(by_l, 50), pct(by_l, 95), len(by_l))}


def node_of(path, machine):
    """The hub's machine line (global/hub_nodes) for <machine>, or {}."""
    m = (machine or "").lower()
    try:
        with open(str(path), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return {}
    ts = 0
    for line in lines:
        p = line.split("\x1f")
        if p[0] == "#ts":
            ts = int(p[1]) if len(p) > 1 and p[1].isdigit() else 0
            continue
        if p[0].startswith("#") or (p[0] or "").lower() != m:
            continue
        p += [""] * (13 - len(p))
        return {"state": p[1], "age": int(p[7]) if p[7].isdigit() else None, "place": p[11],
                "hostname": p[12], "ts": ts}
    return {}


def _ms(v):
    return "—" if v is None else ("%dms" % v if v < 10000 else "%.1fs" % (v / 1000.0))


def _clock(t):
    return time.strftime("%H:%M:%S", time.localtime(t)) if t else ""


PHASE_WORDS = {"up": ("已连上", "up"), "connecting": ("正在连", "connecting"),
               "verifying": ("正在核对登录", "verifying"), "down": ("断开", "down")}
PLACE_WORDS = {"coord": ("协调机", "coordinator"), "maint": ("维护中", "maintenance")}


def detail_lines(e, link, node, stats, now=None, en=False, hub_age=None, hub_stale=False):
    """The 「连接」 block of the actions page: [text], one fact a line, labels short
    (a ~40-column pane). `e` the row; `link` link_of's; `node` node_of's; `stats`
    enter_stats'; hub_age the seconds since the hub last answered (None: no hub)."""
    now = time.time() if now is None else now
    L = (lambda zh, en_: en_) if en else (lambda zh, en_: zh)
    out = [L("连接", "Link")]
    machine = e.get("machine") or "?"
    login = e.get("login") or ""
    out.append(L("机器  ", "machine  ") + machine + (" · " + login if login else ""))
    if node.get("place") in PLACE_WORDS:
        out.append(L("位置  ", "place  ") + PLACE_WORDS[node["place"]][en])
    if not e.get("far"):
        out.append(L("本机会话，不经连接", "this machine: no link"))
    elif not link:
        out.append(L("没有这台的常开连接", "no standing link to it"))
    else:
        route = link.get("route") or link.get("host") or ""
        if route:
            out.append(L("路线  ", "route  ") + route)
        ph = link.get("phase") or "?"
        word = PHASE_WORDS.get(ph, (ph, ph))[en]
        if ph == "up":
            t = _num(link.get("since"))
            out.append(L("状态  ", "state  ") + word + (L(" · 自 ", " · since ") + _clock(t) if t else ""))
            rtt = link.get("rtt_ms")
            out.append(L("往返  ", "rtt  ") + ("%d ms" % rtt if isinstance(rtt, (int, float)) else "—"))
        else:
            out.append(L("状态  ", "state  ") + word + " · " + secs_words(unreach(link, now) or 0, en))
        out.append(L("失败  %d · 检查超时 %d · 通道超时 %d", "fails %d · check %d · probe %d")
                   % (int(_num(link.get("fails"))), int(_num(link.get("strikes"))),
                      int(_num(link.get("probe_strikes")))))
        err = (link.get("err") or "").strip()
        if err:
            cause = link.get("cause") or ""
            t = _num(link.get("err_ts"))
            out.append(L("上次错  ", "last err  ") + (cause + ": " if cause and cause != "ok" else "") + err
                       + (" @" + _clock(t) if t else ""))
    tp, tq, tn = (stats or {}).get("target", (None, None, 0))
    lp, lq, ln = (stats or {}).get("link", (None, None, 0))
    if tn:
        out.append(L("进入本会话  ", "enter this  ") + "p50 %s · p95 %s · %d" % (_ms(tp), _ms(tq), tn))
    if ln:
        out.append(L("进入这台  ", "enter there  ") + "p50 %s · p95 %s · %d" % (_ms(lp), _ms(lq), ln))
    if not tn and not ln:
        out.append(L("进入耗时  还没记录", "enter time  none logged"))
    if hub_age is None:
        out.append(L("入口  没有", "hub  none"))
    else:
        hs = L("失联", "lost") if hub_stale else L("在线", "online")
        out.append(L("入口  ", "hub  ") + hs + L(" · %s前答过", " · answered %s ago") % secs_words(hub_age, en))
    if node:
        ns = {"online": L("在线", "online"), "lost": L("失联", "lost")}.get(node.get("state"), node.get("state") or "?")
        age = node.get("age")
        out.append(L("入口看这台  ", "hub sees it  ") + ns
                   + (L(" · 心跳 %s前", " · beat %s ago") % secs_words(age, en) if age is not None else ""))
    return out
