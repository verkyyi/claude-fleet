"""fleet_view.py — the 看台's switcher, on the home machine (issue #3000, EPIC #2999 C2).

The thin client has no tmux and no list of its own: its ⌘ keys land in the 看台
(`<fleet>@view-<id>`, fleet-remote-view.sh attach --thin) as the `fleet-view` key
table (conf/tmux-view.conf), and every one of them comes here, through
fleet-quickopen.py (this module is its node half — the client never loads it):

    fleet-quickopen.py view-keys [--if-stale] [--socket <label>]
                                              (conf/tmux-view.conf at every load;
                                              attach --thin, if root moved since)
                                              rebuild `fleet-view` + `fleet-view-pfx`:
                                              root copied over, then the 看台's keys
    fleet-quickopen.py --view <view> [--client <c>]
                                              ⌘P / ⌘K: every session of yours, every
                                              machine, every login, grouped by
                                              (machine, login); 停放 · 待你动手 · 已结束
                                              under them; ↵ goes there
    fleet-quickopen.py do next|prev|back|fwd --view <view>
                                              ⌘↓ ⌘↑ (the list's order) · ⌘[ ⌘] (history)
    fleet-quickopen.py view-order --view <view>
                                              rewrite the order ⌘↓ ⌘↑ walk (below)
    fleet-quickopen.py view-rows --view <view> [<query>]
                                              the popup's lines, plain (the selftest)
    fleet-quickopen.py go <view> <target>     THE way a 看台 changes session (= bin/fleet-view-go.sh)
    fleet-quickopen.py view-peers --view <view> [--socket <label>]
                                              (attach --thin, in the background) one
                                              window per other (machine, login) — C4

`<view>` is the 看台's id or its session's name (`fleet@view-<id>`, what a key's
`#{session_name}` says). `<target>` is a window here (`@12`) or a worker id
(`<fleet UUID>/<fleet_id>`, or its `<fleet UUID>/<key>` alias).

GO (共同约定 8): the one entry every 看台 switch takes — the popup's ↵, ⌘↑↓, ⌘[ ],
C4's other machines and C7's keys. A session of THIS login on this machine is a
window of the 看台's own group: `select-window` on the 看台, nothing else (no
client switch, no redraw of our own).

Another machine's — or another login's here — is a PEER WINDOW's (issue #2751,
EPIC #2999 C4): one window per (machine, login) in the 看台's group, made when the
看台 attaches (`view-peers`, so the first visit is warm too) or by the first go
that needs it — `@fleet_role panel` (no list, no restore, no cap), `@peer
<machine>@<login>` (+ `@peer_node` / `@peer_login`, C1's top line), `@peer_view
<view>`, its pane `fleet-peerlink.py pane`, an ssh
on C5's standing link attached to the far machine's 看台 `<view>-via-<home>` (bare:
no top line, no key table — this machine draws both). Going there is the window's
`select-window`, after — only when the far 看台 shows another session than
`@peer_cur` — ONE channel on the link running the far end's `fleet-remote-view.sh
select` (its pre-lib fast path: three tmux calls). The link down (no socket C5
calls up) → `@peer_want` on the window, the window selected (it says 「正在连」),
rc 3; its pane lands there when the link is back. The windows go with their 看台
(rv_prune's peer sweep).

Every go appends one line to `$FLEET_CONF_DIR/logs/view-switch.ndjson` — ts ·
view · from · to · machine · login · method (`select-window` | `peer-window` (the
far 看台 already there) | `peer-select` (+ `peer_ms`, the channel) | `peer-wait` |
`far-none` (no machine known) | `gone`) · ms (the decision and every call, until
select-window returned) · how (popup | next | back …) — C10's reading. The history (⌘[ ⌘]) lives beside the 看台's registry row,
`$FLEET_CONF_DIR/remote-views/<id>.d/history.json` (rv_prune takes it with the
row), in fleet-quickopen.py's own stack / at / mru shape; beside it `order.json`,
the list's session order as last drawn — ⌘↓ ⌘↑ read it (a press never waits
~0.2 s for the row producer) and refresh it in the background after the switch.

WORDS (#2752): no row says `merged` or `done:2h` — the reap policy is
「合并后关」 / 「空闲 2 小时关」, and only on the lit row's line at the foot;
names are the issue's title as wide as the popup is (the producer's 12-cell name
when there is none) with no `⇢cla` tag; a state is a word, never `!`; the
orchestrator is 「新任务（编排）」. All of it through fleet-ui-lang.sh (`view_*`).
"""
import curses
import getpass
import importlib.util
import shlex
import json
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

US = "\x1f"
VIEW_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")
# The 看台's actions off dash-keymap.sh --panel switch: the verb each one runs.
# zoom / new / fold / quit / dispatch are C7's (EPIC #2999) — caught by user-keys,
# bound to nothing here yet.
VIEW_ACTIONS = {"next": "do next", "prev": "do prev", "back": "do back", "fwd": "do fwd",
                "quickopen": "popup", "switcher": "popup"}
PFX_KEY = "C-]"
NARROW = 100      # a client narrower than this (a phone) gets the switcher full-screen (#3006)
HERE, ME = "here", "me"


# --- where things are ---------------------------------------------------------------

def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.join(os.path.expanduser("~"), ".config", "claude-fleet"))


def views_dir():
    return conf_dir() / "remote-views"


def dash_global():
    """The collector's machine-wide cache dir (tmux-dashboard-rows.sh's $G)."""
    base = os.environ.get("TMPDIR") or "/tmp/claude-fleet-%d" % os.getuid()
    return Path(os.environ.get("FLEET_STATUS_G") or os.path.join(base.rstrip("/"), ".claude-dash", "global"))


def switch_log():
    return conf_dir() / "logs" / "view-switch.ndjson"


# Outside a tmux server ($TMUX unset — a caller over ssh, a test's shell) the
# fleet's own socket: its label is the fleet session's name (fleet_socket).
_SOCK = [""]


def tm(*args, timeout=5):
    base = ["tmux"] if os.environ.get("TMUX") or not _SOCK[0] else ["tmux", "-L", _SOCK[0]]
    try:
        p = subprocess.run(base + list(args), capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.rstrip("\n")
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


_FLEET_HINT = {}


def view_id(arg):
    """`fleet@view-<id>` or `<id>` → `<id>`, "" when it is neither. The fleet a
    session name names is remembered for view_fleet()."""
    fleet, sep, v = (arg or "").rpartition("@view-")
    if not VIEW_RE.match(v):
        return ""
    if sep and fleet:
        _FLEET_HINT[v] = fleet
    return v


def view_row(vid):
    """The 看台's registry row: tty · session · kind · since · pid + its key=value cells."""
    try:
        line = (views_dir() / vid).read_text().split("\n", 1)[0]
    except OSError:
        return {}
    f = line.split("\t")
    if len(f) < 2:
        return {}
    row = {"tty": f[0], "session": f[1], "kind": f[2] if len(f) > 2 else ""}
    for cell in f[5:]:
        k, eq, v = cell.partition("=")
        if eq:
            row.setdefault(k, v)
    return row


def view_fleet(vid, row=None):
    """The fleet session a 看台 is grouped onto: its registry row's, else the name's."""
    row = view_row(vid) if row is None else row
    fleet = row.get("session") or _FLEET_HINT.get(vid, "")
    _SOCK[0] = _SOCK[0] or fleet
    return fleet


def here_label(row):
    """This machine as the rows name it: the registry's node= (rv_node_label), else
    the short hostname."""
    return row.get("node") or os.environ.get("FLEET_SIDEBAR_HOST") or socket.gethostname().split(".")[0]


# --- the words ------------------------------------------------------------------------

_WORDS = {}


def say(key, *args):
    if not _WORDS:
        try:
            raw = subprocess.run(["sh", str(Path(__file__).absolute().parent / "fleet-ui-lang.sh"), "dump", "view_"],
                                 capture_output=True, text=True, timeout=5).stdout.split("\0")
        except (OSError, subprocess.TimeoutExpired):
            raw = []
        _WORDS.update({k: v.replace("\1", "%s") for k, v in zip(raw[0::2], raw[1::2])})
        _WORDS.setdefault("_", "")
    text = _WORDS.get(key, key)
    try:
        return text % args if args else text
    except (TypeError, ValueError):
        return text


def dur(secs):
    """`45 分钟` · `3 小时` · `2 天` (the 「多久前」 of a row's end)."""
    secs = max(0, int(secs))
    if secs < 3600:
        return say("view_dur_m_fmt", max(1, secs // 60))
    if secs < 2 * 86400:
        return say("view_dur_h_fmt", secs // 3600)
    return say("view_dur_d_fmt", secs // 86400)


def span(text):
    """`2h` / `90m` / `3d` → the words (a reap policy's duration)."""
    m = re.fullmatch(r"(\d+)([smhd]?)", text or "")
    if not m:
        return text or ""
    n, u = int(m.group(1)), m.group(2) or "s"
    return dur(n * {"s": 1, "m": 60, "h": 3600, "d": 86400}[u])


def reap_words(policy):
    """A reap policy (fleet_reap_policy.py's grammar) as a sentence (#2752 item 1)."""
    p = (policy or "").strip()
    kind, _, arg = p.partition(":")
    if kind == "merged":
        return say("view_reap_merged_for", span(arg)) if arg else say("view_reap_merged")
    if kind == "done":
        return say("view_reap_done_for", span(arg)) if arg else say("view_reap_done")
    if kind == "loop-end":
        return say("view_reap_loop_end")
    if kind == "keep":
        return say("view_reap_keep")
    if kind == "at":
        return say("view_reap_at", arg)
    return ""


STATES = ("needs", "failed", "working", "looping", "idle", "done", "exited", "sleeping", "landed", "parked")


def state_words(state, needs=""):
    s = state if state in STATES else "idle"
    if s == "needs" and needs == "blocked":
        return say("view_state_blocked")
    return say("view_state_" + s)


TAG_RE = re.compile(r"\s*⇢\S*$")


# --- the rows -------------------------------------------------------------------------

def fleet_logins():
    out = {}
    try:
        for line in (dash_global() / "fleet_logins").read_text().splitlines():
            u, _, lg = line.partition("\t")
            if u and lg:
                out[u] = lg
    except OSError:
        pass
    return out


def produce(fleet):
    """tmux-dashboard-rows.sh --sidebar, every subtree open: the rows the old list
    drew, the same producer (it reads remote_<sess>, so other machines come too)."""
    env = dict(os.environ, FLEET_SESSION=fleet, FLEET_ROWS_UNFOLD="1")
    seam = os.environ.get("FLEET_VIEW_ROWS_CMD")
    argv = ["sh", "-c", seam] if seam else ["bash", str(Path(__file__).absolute().parent / "tmux-dashboard-rows.sh"), "--sidebar"]
    try:
        return subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def orch_line(fleet):
    """orch_<fleet> split, or [] (the steward's park= / todo= columns ride it)."""
    try:
        line = (dash_global() / ("orch_" + fleet)).read_text().split("\n", 1)[0]
    except OSError:
        return []
    return line.split(US)


def orch_list(p, name):
    import base64
    for cell in (p or [])[7:]:
        k, eq, v = cell.strip().partition("=")
        if not eq or k != name or not re.fullmatch(r"[-A-Za-z0-9_]{1,4000}", v):
            continue
        try:
            d = json.loads(base64.urlsafe_b64decode(v + "=" * (-len(v) % 4)).decode("utf-8"))
        except ValueError:
            return []
        return [e for e in d.get("i") or [] if isinstance(e, dict)] if isinstance(d, dict) else []
    return []


def orch_count(p, name):
    for cell in (p or [])[7:]:
        k, eq, v = cell.strip().partition("=")
        if eq and k == name and v.isdigit():
            return int(v)
    return 0


def windows(fleet):
    """{window id: (fleet_id, role, activity)} of the fleet session."""
    rc, out = tm("list-windows", "-t", "=" + fleet, "-F", "#{window_id}|#{@fleet_id}|#{@fleet_role}|#{window_activity}")
    res = {}
    for line in out.splitlines() if rc == 0 else []:
        w, fid, role, act = (line.split("|") + ["", "", ""])[:4]
        res[w] = (fid, role, int(act) if act.isdigit() else 0)
    return res


def entries(vid, now=None):
    """Every line the popup can show, in order. Each a dict:
    kind  hdr (a (machine, login) group) · sess · sec (停放 / 待你动手 / 已结束,
          folds) · park · todo — and `sec` names the section a line sits in
    text  the line's words · word (left column) · right (the issue) · foot (the
          lit row's line) · target (what go() takes) · far (another machine/login)"""
    now = time.time() if now is None else now
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    here, me = here_label(row), getpass.getuser()
    logins = fleet_logins()
    wins = windows(fleet) if fleet else {}
    groups, order, ended = {}, [], []
    section = ""
    for line in produce(fleet).splitlines():
        f = line.split(US)
        if f[0] == "hdr":
            section = "ended" if f[1:2] == ["ended"] else ""
            continue
        if len(f) < 15 or not f[0]:
            continue
        key = f[0]
        local = not key.startswith("wid:")
        target = key if local else key[4:]
        machine = f[8].rstrip("!~") or here
        login = me if local else logins.get(target.split("/", 1)[0], "")
        far = not local
        name = TAG_RE.sub("", f[3]).strip()
        title = (f[13] or "").strip()
        detail = (f[7] or "").strip()
        issue = f[9].strip() if f[9].strip() not in ("—", "·", "-") else ""
        depth = int(f[6]) if f[6].isdigit() else 0
        e = {"kind": "sess", "target": target, "far": far, "machine": machine, "login": login,
             "state": f[1], "text": title or name, "name": name, "issue": issue, "depth": depth,
             "word": state_words(f[1], detail if f[1] == "needs" else ""),
             "foot": " · ".join(x for x in (title or name, reap_words(f[14]),
                                            detail if detail and detail != f[1] else "",
                                            " · ".join(x for x in (machine, login) if x)) if x)}
        if section == "ended":
            act = wins.get(target, ("", "", 0))[2] if local else 0
            why = say("view_ended_merged") if f[10].strip() == "merged" else \
                say("view_ended_exited") if f[1] == "exited" else say("view_ended_done")
            e["word"] = why
            e["right"] = say("view_ago_fmt", dur(now - act)) if act else ""
            e["sec"] = "ended"
            ended.append(e)
            continue
        g = (machine, login)
        if g not in groups:
            groups[g] = []
            order.append(g)
        groups[g].append(e)
    # this login on this machine first, then the rest by machine, login
    order.sort(key=lambda g: (g != (here, me), g[0], g[1]))
    out = []
    orch = [w for w, v in wins.items() if v[1] == "orchestrator"]
    if orch:
        out.append({"kind": "sess", "target": orch[0], "far": False, "machine": here, "login": me,
                    "state": "", "text": say("view_portal"), "word": "", "issue": "", "depth": 0,
                    "foot": say("view_portal_foot"), "pin": True})
    for g in order:
        # a login the hub has not named yet (no fleet_logins line): the machine alone
        out.append({"kind": "hdr", "text": say("view_here_fmt", g[0], g[1]) if g == (here, me)
                    else say("view_group_fmt", g[0], g[1]) if g[1] else g[0], "machine": g[0], "login": g[1]})
        out.extend(groups[g])
    oline = orch_line(fleet) if fleet else []
    for name, kind in (("park", "park"), ("todo", "todo")):
        n = orch_count(oline, name)
        if n <= 0:
            continue
        out.append({"kind": "sec", "sec": name, "text": say("view_sec_" + name + "_fmt", n), "n": n})
        for it in orch_list(oline, name + "l"):
            if kind == "park":
                ref = str(it.get("r") or "")
                if not ref:
                    continue
                at = it.get("a") if isinstance(it.get("a"), int) else 0
                who = str(it.get("k") or "") or ref
                wait = str(it.get("w") or "")
                out.append({"kind": "park", "sec": name, "ref": ref, "word": say("view_state_parked"),
                            "text": say("view_park_item_fmt", who, wait),
                            "right": say("view_ago_fmt", dur(now - at)) if at else "",
                            "foot": say("view_park_foot_fmt", ref, wait)})
            else:
                iid = str(it.get("id") or "")
                if not iid:
                    continue
                what, src, due = str(it.get("w") or ""), str(it.get("s") or ""), str(it.get("d") or "")
                out.append({"kind": "todo", "sec": name, "ref": iid, "word": say("view_todo_word"),
                            "text": what, "right": say("view_due_fmt", due) if due else "",
                            "foot": say("view_todo_foot_fmt", what, src) if src else what,
                            "target": orch[0] if orch else ""})
    if ended:
        out.append({"kind": "sec", "sec": "ended", "text": say("view_sec_ended_fmt", len(ended)), "n": len(ended)})
        out.extend(ended)
    return out


def matches(e, query):
    words = query.lower().split()
    if not words:
        return True
    hay = " ".join(str(e.get(k) or "") for k in ("text", "name", "issue", "word", "machine", "login", "ref")).lower()
    return all(w in hay for w in words)


def visible(items, query, opened):
    """What the popup lists: a section's items only when it is open (a query opens
    every one), a group heading only when one of its rows is listed."""
    out, pend = [], None
    for e in items:
        if e["kind"] == "hdr":
            pend = e
            continue
        if e["kind"] == "sec":
            pend = None
            if not query:
                out.append(e)
            continue
        if e.get("sec") and not query and e["sec"] not in opened:
            continue
        if not matches(e, query):
            continue
        if pend is not None:
            out.append(pend)
            pend = None
        out.append(e)
    return out


def session_order(items):
    """The order ⌘↓ / ⌘↑ walk: every session line of the list, as it is drawn."""
    return [e["target"] for e in items if e["kind"] == "sess" and e.get("target")]


def order_file(vid):
    return views_dir() / (vid + ".d") / "order.json"


def order_save(vid, items):
    """Write the list's session order (+ each one's machine / login) — the popup on
    every open, view-order after a ⌘↓ — and return (seq, metas)."""
    seq = session_order(items)
    metas = {e["target"]: {"machine": e.get("machine", ""), "login": e.get("login", "")}
             for e in items if e["kind"] == "sess" and e.get("target")}
    path = order_file(vid)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name("." + path.name + ".%d" % os.getpid())
        tmp.write_text(json.dumps({"ts": int(time.time()), "seq": seq, "meta": metas}, ensure_ascii=False))
        os.replace(str(tmp), str(path))
    except OSError:
        pass
    return seq, metas


def order_load(vid):
    try:
        d = json.loads(order_file(vid).read_text())
    except (OSError, ValueError):
        return None
    seq = [t for t in d.get("seq") or [] if isinstance(t, str)]
    metas = d.get("meta") if isinstance(d.get("meta"), dict) else {}
    return (seq, metas) if seq else None


# --- go: the one way a 看台 changes session (共同约定 8) ---------------------------------

def history_file(vid):
    return views_dir() / (vid + ".d") / "history.json"


def hist_load(qo, vid):
    try:
        h = json.loads(history_file(vid).read_text())
    except (OSError, ValueError):
        h = {}
    stack = [k for k in h.get("stack", []) if isinstance(k, str) and k]
    at = h.get("at", len(stack) - 1)
    at = at if isinstance(at, int) and 0 <= at < len(stack) else len(stack) - 1
    mru = [k for k in h.get("mru", []) if isinstance(k, str) and k]
    seen = h.get("seen") if isinstance(h.get("seen"), dict) else {}
    return {"stack": stack, "at": at, "mru": mru, "seen": seen}


def hist_save(qo, vid, h):
    return qo.write_atomic(history_file(vid), json.dumps(h, ensure_ascii=False) + "\n")


def current(vid, fleet=None):
    """The 看台's session in view, as go() targets it: `@<window>` here, or the far
    session a C4 window shows (its @peer_cur)."""
    rc, out = tm("display-message", "-p", "-t", "=%s@view-%s:" % (fleet or view_fleet(vid), vid),
                 "#{window_id}|#{@peer_cur}")
    if rc != 0 or not out:
        return ""
    w, _, pc = out.partition("|")
    return pc[4:] if pc.startswith("wid:") else (pc or w)


def resolve(vid, target, row, fleet):
    """(window id in the fleet, far) for a target: a window here; a worker id of
    this fleet (its UUID = the registry's fuid=) by @fleet_id; anything else far."""
    if target.startswith("@"):
        return target, False
    uuid, _, fid = target.partition("/")
    if fid and uuid and uuid == row.get("fuid"):
        for w, v in windows(fleet).items():
            if v[0] == fid:
                return w, False
        return "", False
    return "", True


def log_switch(rec):
    try:
        path = switch_log()
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8") as out:
            out.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError:
        pass


def toast(client, text):
    tm("display-message", *(["-c", client] if client else []), text)


# --- peer windows: the other machines, inside the 看台 (issue #2751, EPIC #2999 C4) -----

_PL = []


def peerlink():
    """bin/fleet-peerlink.py as a module (C5: the one owner of the links)."""
    if not _PL:
        path = Path(__file__).absolute().parent / "fleet-peerlink.py"
        spec = importlib.util.spec_from_file_location("fleet_peerlink", str(path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _PL.append(mod)
    return _PL[0]


def peer_windows(fleet, vid):
    """{"<machine>@<login>": (window id, @peer_cur)} of the 看台's peer windows."""
    rc, out = tm("list-windows", "-t", "=" + fleet, "-F", "#{window_id}|#{@peer}|#{@peer_view}|#{@peer_cur}")
    res = {}
    for line in out.splitlines() if rc == 0 else []:
        w, peer, pv, pc = (line.split("|") + ["", "", ""])[:4]
        if peer and pv == vid:
            res.setdefault(peer, (w, pc))
    return res


def peer_make(fleet, vid, machine, login, want=""):
    """The 看台's window onto (machine, login): made hidden (-d), its pane the C5
    pane program (`want`: a worker id its first connect lands on). Its window id,
    "" when tmux said no."""
    me = getpass.getuser()
    pane = "exec python3 %s pane %s %s %s" % (
        shlex.quote(str(Path(__file__).absolute().parent / "fleet-peerlink.py")),
        shlex.quote(machine), shlex.quote(login), shlex.quote(vid))
    name = "@" + machine + ("" if login == me else "·" + login)
    rc, w = tm("new-window", "-d", "-P", "-F", "#{window_id}", "-t", "=%s@view-%s:" % (fleet, vid), "-n", name, pane)
    if rc != 0 or not w.startswith("@"):
        return ""
    tm("set-option", "-w", "-t", w, "@fleet_role", "panel", ";",
       "set-option", "-w", "-t", w, "@peer", "%s@%s" % (machine, login), ";",
       "set-option", "-w", "-t", w, "@peer_view", vid, ";",
       "set-option", "-w", "-t", w, "@peer_node", machine, ";",
       "set-option", "-w", "-t", w, "@peer_login", login, ";",
       "set-option", "-w", "-t", w, "automatic-rename", "off", ";",
       "set-option", "-w", "-t", w, "pane-border-status", "off",
       *([";", "set-option", "-w", "-t", w, "@peer_want", "wid:" + want] if want else []))
    return w


def peer_targets():
    """[(machine, login)] the 看台 should hold a window for: C5's own wanted set."""
    try:
        return sorted(peerlink().wanted_targets())
    except Exception:  # noqa: BLE001 — a broken peerlink makes no windows, never a crash
        return []


def view_peers(vid):
    """`view-peers`: a window for every (machine, login) your sessions are on."""
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet or "-via-" in vid:
        return 2
    have = peer_windows(fleet, vid)
    for m, l in peer_targets():
        if "%s@%s" % (m, l) not in have:
            peer_make(fleet, vid, m, l)
    return 0


def far_where(target, meta, fleet):
    """(machine, login) of a far worker id: the go's meta (the list's), else the
    hub's row for it (global/remote_<fleet>)."""
    m, l = (meta or {}).get("machine") or "", (meta or {}).get("login") or ""
    if not m and fleet:
        try:
            for line in (dash_global() / ("remote_" + fleet)).read_text().splitlines():
                f = line.split(US)
                if f[0] == "wid:" + target and len(f) > 1:
                    m = f[1].rstrip("!~")
                    break
        except OSError:
            pass
    if m and not l:
        l = fleet_logins().get(target.split("/", 1)[0], "") or getpass.getuser()
    return m, l


def peer_select(machine, login, sock, target, vid):
    """ONE channel on the link: the far 看台 shows `target`. The far end's rc (0 ·
    3 not live there · 5 no such 看台 there yet), 255 the channel failed."""
    pl = peerlink()
    cmd = "bash %s/fleet-remote-view.sh select %s %s" % (pl.remote_bin(), shlex.quote(target),
                                                         shlex.quote(pl.via_view(vid)))
    try:
        return subprocess.run(pl.ssh_cmd() + ["-S", sock, "-o", "ControlMaster=no", "-l", login,
                                              pl.ssh_host(machine), cmd],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=fenv("FLEET_VIEW_PEER_SECS", 3)).returncode
    except (OSError, subprocess.TimeoutExpired):
        return 255


def fenv(k, d):
    try:
        return float(os.environ.get(k) or d)
    except ValueError:
        return float(d)


def go_far(vid, fleet, g, target, meta, client):
    """go()'s other-machine half: (method, rc, machine, login, extra)."""
    m, l = far_where(target, meta, fleet)
    if not m:
        toast(client, say("view_far_fmt", "?"))
        return "far-none", 3, m, l, {}
    key = "%s@%s" % (m, l)
    w, pcur = peer_windows(fleet, vid).get(key, ("", ""))
    made = not w
    if made:
        w = peer_make(fleet, vid, m, l, target)
        if not w:
            toast(client, say("view_far_fmt", m))
            return "far-none", 3, m, l, {}
    if not made and pcur == "wid:" + target:
        code, _ = tm("select-window", "-t", "=%s:%s" % (g, w))
        return ("peer-window", 0) + (m, l, {}) if code == 0 else ("gone", 4, m, l, {})
    sock = "" if made else peerlink().up_sock(m, l)
    extra = {}
    if sock:
        t1 = time.monotonic()
        prc = peer_select(m, l, sock, target, vid)
        # 5: the far 看台 is not there yet — the window's pane is attaching right
        # now (a fresh 看台, a line just back); it is, within moments
        for _ in range(int(fenv("FLEET_VIEW_PEER_RETRIES", 8))):
            if prc != 5:
                break
            time.sleep(0.15)
            prc = peer_select(m, l, sock, target, vid)
        extra["peer_ms"] = round((time.monotonic() - t1) * 1000, 1)
        if prc == 0:
            code, _ = tm("select-window", "-t", "=%s:%s" % (g, w), ";",
                         "set-option", "-w", "-t", w, "@peer_cur", "wid:" + target, ";",
                         "set-option", "-w", "-u", "-t", w, "@peer_want")
            return ("peer-select", 0, m, l, extra) if code == 0 else ("gone", 4, m, l, extra)
        if prc == 3:
            toast(client, say("view_gone"))
            return "gone", 4, m, l, extra
    # the link not up (or the far 看台 not there yet): the window waits and lands there
    tm("set-option", "-w", "-t", w, "@peer_want", "wid:" + target)
    tm("select-window", "-t", "=%s:%s" % (g, w))
    toast(client, say("view_peer_wait_fmt", m))
    return "peer-wait", 3, m, l, extra


def go(qo, vid, target, how="go", client="", meta=None, record=True):
    """Switch the 看台 to `target`. rc 0 switched · 3 another machine / login whose
    link is not up yet (C4: its window shown, waiting to land there) · 4 gone ·
    2 no such 看台."""
    t0 = time.monotonic()
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    g = "%s@view-%s" % (fleet, vid)
    before = current(vid, fleet)
    meta = meta or {}
    w, far = resolve(vid, target, row, fleet)
    if far and not meta.get("machine"):
        cached = order_load(vid)
        meta = (cached[1].get(target) if cached else None) or meta
    extra = {}
    if far:
        method, rc, fm, fl, extra = go_far(vid, fleet, g, target, meta, client)
        meta = dict(meta, machine=fm or meta.get("machine") or "", login=fl or meta.get("login") or "")
    elif not w:
        method, rc = "gone", 4
        toast(client, say("view_gone"))
    else:
        code, _ = tm("select-window", "-t", "=%s:%s" % (g, w))
        method, rc = ("select-window", 0) if code == 0 else ("gone", 4)
    ms = round((time.monotonic() - t0) * 1000, 1)
    rec = {"ts": round(time.time(), 3), "view": vid, "from": before, "to": target,
           "machine": meta.get("machine") or ("" if far else row.get("node") or ""),
           "login": meta.get("login") or ("" if far else getpass.getuser()),
           "method": method, "ms": ms, "how": how}
    rec.update(extra)
    log_switch(rec)
    if rc == 0 and record:
        hist_save(qo, vid, qo.visit(hist_load(qo, vid), target if not target.startswith("@") else w))
    return rc


def do(qo, verb, vid, client=""):
    """⌘↓ ⌘↑ ⌘[ ⌘] in a 看台."""
    row = view_row(vid)
    fleet = view_fleet(vid, row)
    if not fleet:
        return 2
    cur = current(vid, fleet)
    if verb in ("next", "prev"):
        # The list's order as last drawn (order.json, beside the history): a press
        # never waits for the row producer (~0.2 s); it refreshes after the switch.
        cached = order_load(vid)
        if cached:
            seq, metas = cached
            refresh = True
        else:
            items = entries(vid)
            seq, metas = order_save(vid, items)
            refresh = False
        if not seq:
            return 1
        # the current window may be listed by its window id or its worker id
        wins = windows(fleet)
        fid = wins.get(cur, ("",))[0]
        alias = "%s/%s" % (row.get("fuid", ""), fid) if fid else ""
        i = next((n for n, t in enumerate(seq) if t in (cur, alias)), -1)
        i = (i + (1 if verb == "next" else -1)) % len(seq) if i >= 0 else 0
        rc = go(qo, vid, seq[i], verb, client, metas.get(seq[i]) or {})
        if refresh:
            subprocess.Popen([sys.executable, qo.__file__, "view-order", "--view", vid], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return rc
    if verb in ("back", "fwd"):
        h = hist_load(qo, vid)
        if not h["stack"]:
            return 1
        wins = windows(fleet)
        live = lambda k: k in wins or (not k.startswith("@") and "/" in k)
        key = qo.step(h, live, -1 if verb == "back" else 1)
        if not key:
            return 1
        rc = go(qo, vid, key, verb, client, record=False)
        if rc == 0:
            hist_save(qo, vid, qo.visit(h, key))
        return rc
    return 2


# --- the key tables (conf/tmux-view.conf) ------------------------------------------------

ROOT_RE = re.compile(r"^(bind-key(?:\s+-r)?)\s+-T\s+root\s")


def key_lines(me):
    """The commands that rebuild both tables: root copied into fleet-view, then the
    看台's keys off dash-keymap.sh's switch table (its code and prefix letter)."""
    rc, root = tm("list-keys", "-T", "root")
    lines = ["unbind-key -q -a -T fleet-view", "unbind-key -q -a -T fleet-view-pfx"]
    for line in root.splitlines() if rc == 0 else []:
        if ROOT_RE.match(line):
            lines.append(ROOT_RE.sub(r"\1 -T fleet-view ", line, count=1))
    keymap = lambda what: subprocess.run(["bash", str(Path(me).parent / "dash-keymap.sh"), "--panel", "switch", what],
                                         capture_output=True, text=True, timeout=5).stdout
    try:
        table = keymap("list")
        # ⌃] + a letter (issue #3006, C9): the 看台's own letters, a thumb's — p the list,
        # n / b down / up it, q quit; an action with none keeps its prefix-column letter
        letters = dict(t.split()[:2] for t in keymap("view").splitlines() if len(t.split()) >= 2)
    except (OSError, subprocess.TimeoutExpired):
        table, letters = "", {}
    # the codes too (conf/tmux-view.conf sets the same, idempotent)
    codes = sorted({t.split()[3] for t in table.splitlines() if len(t.split()) >= 5} | {"924", "926"})
    lines += ['set-option -s user-keys[%s] "\\e[%s~"' % (c, c) for c in codes if c.isdigit()]
    for t in table.splitlines():
        f = t.split()
        if len(f) < 5 or f[0] not in VIEW_ACTIONS:
            continue
        action, code, letter = f[0], f[3], letters.get(f[0], f[4])
        verb = VIEW_ACTIONS[action]
        if verb == "popup":
            # display-popup expands no format in its command (nor in -e), so the
            # popup opens from a run-shell, which does — the old client's road too.
            # Narrower than NARROW columns (a phone, C9): the whole screen
            size = lambda pc: "#{?#{e|<:#{client_width},%d},100%%,%d%%}" % (NARROW, pc)
            cmd = ("run-shell -b \"tmux display-popup -c '#{client_name}' -E -w %s -h %s -T ' %s ' "
                   "\\\"python3 '%s' --view '#{session_name}' --client '#{client_name}'\\\" "  # view-ok: the key's own session IS the 看台
                   ">/dev/null 2>&1 || :\"") % (size(90), size(80), say("view_title"), me)
        else:
            cmd = ("run-shell -b \"python3 '%s' %s --view '#{session_name}' --client '#{client_name}' "  # view-ok: the 看台
                   ">/dev/null 2>&1 || :\"") % (me, verb)
        lines.append("bind-key -T fleet-view User%s %s" % (code, cmd))
        if len(letter) == 1:
            lines.append("bind-key -T fleet-view-pfx %s %s" % ("'%s'" % letter if not letter.isalnum() else letter, cmd))
    lines.append("bind-key -T fleet-view %s switch-client -T fleet-view-pfx" % PFX_KEY)
    lines.append("bind-key -T fleet-view-pfx %s send-keys %s" % (PFX_KEY, PFX_KEY))
    return lines


def view_keys(me, if_stale=False):
    """Rebuild both tables. --if-stale (attach --thin, every attach): only when
    fleet-view exists and its copy of root no longer IS root — a personal conf
    re-sourced after the fleet's moved root, and the 看台's mouse with it."""
    if if_stale:
        rc, fv = tm("list-keys", "-T", "fleet-view")
        _, root = tm("list-keys", "-T", "root")
        norm = lambda line: " ".join(line.split())
        copy = sorted(norm(ROOT_RE.sub(r"\1 -T root ", l.replace(" -T fleet-view ", " -T root ", 1)))
                      for l in fv.splitlines() if not re.search(r" -T fleet-view +(User9\d\d|C-\]) ", l))
        if rc != 0 or not fv:
            return 0          # never loaded here: attach --thin adds no table (C1's rule)
        if copy == sorted(norm(l) for l in root.splitlines()):
            return 0
    import tempfile
    fd, tmp = tempfile.mkstemp(prefix="fleet-view-keys.", suffix=".conf")
    try:
        with os.fdopen(fd, "w") as out:
            out.write("\n".join(key_lines(me)) + "\n")
        rc, _ = tm("source-file", tmp)
        return rc
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# --- the popup -------------------------------------------------------------------------

def popup(screen, qo, vid, client):
    curses.curs_set(0)
    try:
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_RED, -1)
        curses.init_pair(2, 8 if curses.COLORS > 8 else curses.COLOR_WHITE, -1)
        curses.init_pair(3, curses.COLOR_CYAN, -1)
    except curses.error:
        pass
    items = entries(vid)
    order_save(vid, items)
    cur = current(vid)
    query, opened, msg = "", set(), ""
    shown = visible(items, query, opened)
    at = next((i for i, e in enumerate(shown) if e.get("target") == cur), 0)
    top = 0
    heal = qo.Heal()
    while True:
        heal.tick(screen)
        height, width = screen.getmaxyx()
        screen.erase()
        body = max(1, height - 3)
        sel = [i for i, e in enumerate(shown) if e["kind"] != "hdr"]
        if sel and at not in sel:
            at = min(sel, key=lambda i: abs(i - at))
        if at < top:
            top = at
        if at >= top + body:
            top = at - body + 1
        qline = "› " + query
        screen.addnstr(0, 0, qo.clip(qline, width - 1), width - 1)
        for row in range(body):
            i = top + row
            if i >= len(shown):
                break
            e = shown[i]
            y = row + 1
            lit = i == at
            if e["kind"] == "hdr":
                screen.addnstr(y, 0, qo.clip("─ " + e["text"] + " ", width - 1), width - 1, curses.A_BOLD)
                continue
            if e["kind"] == "sec":
                caret = "▾ " if e["sec"] in opened or query else "▸ "
                screen.addnstr(y, 0, qo.clip(caret + e["text"], width - 1), width - 1,
                               curses.A_BOLD | (curses.A_REVERSE if lit else 0))
                continue
            word = e.get("word") or ""
            wcol = 8
            indent = "  " * (e.get("depth") or 0)
            right = e.get("right") or ("#" + e["issue"].lstrip("#") if e.get("issue") else "")
            lw = width - 1 - 2 - wcol - 1 - (qo.cells(right) + 1 if right else 0)
            name = qo.clip(indent + (e.get("text") or ""), max(1, lw))
            line = "  " + word + " " * max(1, wcol - qo.cells(word) + 1) + name
            attr = curses.A_REVERSE if lit else 0
            if e.get("state") == "needs" or e.get("state") == "failed":
                attr |= curses.color_pair(1)
            elif e.get("far"):
                attr |= curses.color_pair(2)
            screen.addnstr(y, 0, qo.clip(line, width - 1), width - 1, attr)
            if right:
                x = max(0, width - 1 - qo.cells(right))
                try:
                    screen.addstr(y, x, right, attr | curses.color_pair(2))
                except curses.error:
                    pass
        foot = msg or (shown[at].get("foot", "") if 0 <= at < len(shown) else "")
        screen.addnstr(height - 2, 0, qo.clip(foot, width - 1), width - 1, curses.color_pair(3))
        screen.addnstr(height - 1, 0, qo.clip(say("view_keys"), width - 1), width - 1, curses.color_pair(2))
        screen.refresh()
        screen.timeout(heal.timeout(False) or 1000)
        try:
            ch = screen.get_wch()
        except curses.error:
            continue
        msg = ""
        if ch in ("\x1b",) or ch == "\x03":
            return 0
        if ch == curses.KEY_RESIZE:
            heal.resized(screen)
            continue
        if ch in (curses.KEY_UP, "\x10"):
            sel = [i for i, e in enumerate(shown) if e["kind"] != "hdr" and i < at]
            at = sel[-1] if sel else at
            continue
        if ch in (curses.KEY_DOWN, "\x0e"):
            sel = [i for i, e in enumerate(shown) if e["kind"] != "hdr" and i > at]
            at = sel[0] if sel else at
            continue
        if ch in ("\n", "\r", curses.KEY_ENTER):
            if not (0 <= at < len(shown)):
                continue
            e = shown[at]
            if e["kind"] == "sec":
                opened ^= {e["sec"]}
                shown = visible(items, query, opened)
                continue
            if e["kind"] == "park":
                fleet = view_fleet(vid)
                subprocess.Popen(["bash", str(Path(__file__).absolute().parent / "fleet-sidebar-steward.sh"),
                                  "wake", fleet, e["ref"]], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
                toast(client, say("view_waking_fmt", e["ref"]))
                return 0
            target = e.get("target") or ""
            if not target:
                continue
            rc = go(qo, vid, target, "popup", client, e)
            if rc == 0:
                return 0
            msg = say("view_far_fmt", e.get("machine") or "?") if rc == 3 else say("view_gone")
            continue
        if ch in (curses.KEY_BACKSPACE, "\x7f", "\b"):
            query = query[:-1]
        elif isinstance(ch, str) and ch.isprintable():
            query += ch
        else:
            continue
        shown = visible(items, query, opened)
        at = next((i for i, e in enumerate(shown) if e["kind"] != "hdr"), 0)
        top = 0


# --- the entry --------------------------------------------------------------------------

def opt(argv, name):
    return argv[argv.index(name) + 1] if name in argv[:-1] else ""


def main(argv, qo):
    me = os.path.normpath(os.path.abspath(qo.__file__)) if getattr(qo, "__file__", None) else ""
    if argv[:1] == ["view-keys"]:
        # --socket <label>: a caller outside the server (attach --thin over ssh)
        if opt(argv, "--socket"):
            _SOCK[0] = opt(argv, "--socket")
            os.environ.pop("TMUX", None)
        return view_keys(me, "--if-stale" in argv)
    if argv[:1] == ["go"] and len(argv) >= 3:
        vid = view_id(argv[1])
        return go(qo, vid, argv[2], opt(argv, "--how") or "go", opt(argv, "--client")) if vid else 2
    vid = view_id(opt(argv, "--view"))
    if not vid:
        return 2
    client = opt(argv, "--client")
    if argv[:1] == ["do"] and len(argv) >= 2:
        return do(qo, argv[1], vid, client)
    if argv[:1] == ["view-peers"]:
        if opt(argv, "--socket"):
            _SOCK[0] = opt(argv, "--socket")
            os.environ.pop("TMUX", None)
        return view_peers(vid)
    if argv[:1] == ["view-order"]:
        order_save(vid, entries(vid))
        return 0
    if argv[:1] == ["view-rows"]:
        rest = [a for i, a in enumerate(argv[1:], 1) if a not in ("--view", "--client")
                and argv[i - 1] not in ("--view", "--client")]
        for e in visible(entries(vid), " ".join(rest), {"park", "todo", "ended"}):
            print("\t".join((e["kind"], e.get("target") or e.get("ref") or e.get("sec") or "", e.get("word") or "",
                             e.get("text") or "", e.get("right") or "", e.get("foot") or "")))
        return 0
    os.environ.setdefault("ESCDELAY", "25")
    return curses.wrapper(popup, qo, vid, client)
