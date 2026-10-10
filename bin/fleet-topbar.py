#!/usr/bin/env python3
"""fleet-topbar.py — the session's top line in the client (issue #1904, EPIC #1906
C11): the line above the right pane, which the shell's STAGE server draws
(conf/tmux-shell-stage.conf's status-left) — and, at phone width, the way round
the sessions with a thumb.

    fleet-topbar.py render cw=<cols> [down=<epoch>] [rr=<route>] [rv=<auto|manual> <route>]
                           [rp=<pinned route>] [rt=<reconnects>] [wn=<window name>] [gen=…]
        the line, as tmux format: ‹ i/n ›  state  key  title …… PR  repo  @machine
    fleet-topbar.py render --node view=<id> s=<fleet> reg=<dir> g=<dir> sock=<socket> cw= w= [pc=] [pd=]
        the same line drawn ON the machine, as a thin client's 看台's status line
        (issue #2763, EPIC #2999 C1; fleet-remote-view.sh attach --thin) — see
        render_node below
    fleet-topbar.py click <range> <shell session>
        a tap on one of its parts (the stage's MouseDown1Status bind):
        prev / next — the session above / below, as ⌘↑ ⌘↓ (the list's queue);
        title — the full-screen switcher (fleet-quickopen.py --full);
        key — the issue, pr — the PR, opened on the person's computer
        (fleet-open.sh); machine — what is known about that machine, as a note
    fleet-topbar.py fit <cols> <record.json>   the plain text of the line (selftest)
    fleet-topbar.py goodbye [node=<machine>]
        the two lines the one-session view (issue #2265) leaves in the terminal
        when its attach returns (fleet-shell.sh attach_client): 「会话在后台继续
        （<machine>）· 下次输入 fleet 回来」 — or, when the list detached it because
        the session ENDED (fleet-sidebar.py solo_ended's file, taken here), 「会话
        已结束 · fleet 可以恢复」

What it says comes from ONE record, `switch-bar.json` in the client's switch
state dir (fleet-quickopen.py state_dir), written by the task list
(fleet-sidebar.py bar_record) off the very rows it paints — so the line and the
list never disagree — and only on change, when it also bumps the stage's
`@fleet_bar_gen`, which status-left names: tmux runs the line again at once.
The stage adds what only it knows: `@remote_down` (this machine's connection to
that one dropped: ⟳ and for how long), `@remote_route` (on the hub relay) and —
claude-fleet#2886 — `@remote_via` (the route and who chose it: 自动 / 手动),
`@remote_pin` + `@remote_tries` (a pinned route reconnecting: 第 N 次).

Narrow, the line gives up, in this order (the prototype's widths): the repo
(< 130 columns), the PR (< 110), the state's word (< 70, its glyph stays), then
the title is clipped with `…`. ‹ i/n ›, the key and the machine are never
dropped. The whole line turns red only while the session asks you a question,
grey only while its machine is out of reach.

When another client of yours is looking at the same session (issue #1932: a
person may hold several clients at once), the line says so before the machine —
「也在 iPhone 上打开」 — off the clients the keeper last heard from the hub
(client.list.json: each client's `viewing`, the session's worker id), never a
network ask of its own; dropped first when narrow.
"""
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent

# state → (glyph, word). The six of the design, plus the two the list also has.
STATES = {
    "working": ("●", "working"), "preparing": ("●", "working"), "waking": ("●", "working"),
    "looping": ("↻", "looping"), "done": ("✓", "done"), "failed": ("✖", "failed"),
    "exited": ("⏏", "exited"),
}
ASK = ("?", "asking you")
PERM = ("⊘", "needs OK")
IDLE = ("○", "idle")

# colours: the stage's own (conf/tmux-shell-stage.conf)
FG, DIM, HL, OK, WARN, BAD = "#a9b1d6", "#565f89", "#7aa2f7", "#9ece6a", "#e0af68", "#f7768e"
BG_ASK, BG_DOWN = "#f7768e", "#3b4261"

REPO_MIN, PR_MIN, WORD_MIN = 130, 110, 70


def state_dir():
    """The client's switch state dir — fleet-quickopen.py's, the one definition."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("fleet_quickopen", str(BIN / "fleet-quickopen.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.state_dir()


def read_record(path=None):
    try:
        rec = json.loads((path or state_dir() / "switch-bar.json").read_text())
    except (OSError, ValueError):
        return None
    return rec if isinstance(rec, dict) else None


def also_on(rec):
    """「也在 <device> 上打开」 when another of the person's clients views this
    session (issue #1932), '' otherwise. Off the keeper's client.list.json."""
    wid = rec.get("wid") or ""
    if not wid:
        return ""
    f = os.environ.get("FLEET_CLIENT_LIST_FILE") or os.path.join(os.environ.get("TMPDIR") or "/tmp", "client.list.json")
    try:
        with open(f) as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return ""
    if not isinstance(d, dict):
        return ""
    own = d.get("lease") or ""
    devs = []
    for c in d.get("clients") or []:
        if isinstance(c, dict) and c.get("id") != own and c.get("viewing") == wid:
            dev = (c.get("device") or "?").strip()
            if dev not in devs:
                devs.append(dev)
    if not devs:
        return ""
    r = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "t", "topbar_also_fmt", "、".join(devs)],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return r.stdout.strip()


def cells(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1
               for c in text)


def clip(text, room):
    """`text` in at most `room` cells, ending in `…` when cut; "" for no room."""
    if cells(text) <= room:
        return text
    if room < 2:
        return ""
    out, used = "", 0
    for c in text:
        w = cells(c)
        if used + w > room - 1:
            break
        out, used = out + c, used + w
    return out + "…"


def state_of(rec):
    if rec.get("state") == "needs":
        return PERM if rec.get("kind") == "perm" else ASK
    return STATES.get(rec.get("state", ""), IDLE)


def node_old(node):
    """Whether the hub calls that machine's fleet behind the stable mark (#644,
    `old:<n>` in hub_nodes' ver_state — the word the bar's machine chip drew
    before the title became this line)."""
    g = os.environ.get("FLEET_STATUS_G") or os.path.join(os.environ.get("TMPDIR") or f"/tmp/claude-fleet-{os.getuid()}", ".claude-dash", "global")
    try:
        with open(os.path.join(g, "hub_nodes"), encoding="utf-8", errors="replace") as f:
            for line in f:
                part = line.rstrip("\n").split("\x1f")
                if part[0] == node and len(part) > 10:
                    return part[10].startswith("old:")
    except OSError:
        pass
    return False


PIN_WORDS = {"relay": "中转", "tailscale": "Tailscale", "tailnet": "Tailscale", "direct": "直连"}


def machine_text(rec, down, route, now, via="", pin="", tries="", cols=100):
    """@machine and its connection: offline · ⟳ (dropped, how long) · the route.
    The route (claude-fleet#2886): `via` is the stage's `@remote_via`, `<auto|
    manual> <route in words>` — a pinned one always 「· 中转·手动」, an automatic
    one 「· Tailscale·自动」 from 100 columns (the relay keeps its 「· 中转」 below);
    no via ⇒ `route` alone, as before. `pin` / `tries` (`@remote_pin` /
    `@remote_tries`): while a pinned line is down, 「钉住：中转（手动）· 第 N 次重连」."""
    m = "@" + (rec.get("node") or "?")
    if rec.get("node") and node_old(rec["node"]):
        m += " 旧"
    if rec.get("lost"):
        return m + " offline", True
    if down:
        secs = now - int(down) if str(down).isdigit() and int(down) > 1 else -1
        m += " ⟳ %ds" % secs if secs >= 0 else " ⟳"
        if pin:
            word = PIN_WORDS.get(pin, pin)
            n = int(tries) if str(tries).isdigit() else 0
            if cols >= 100:
                m += " · 钉住：%s（手动）" % word + ("· 第 %d 次重连" % n if n else "")
            else:
                m += " · 钉%s" % word + (" %d" % n if n else "")
        return m, True
    src, _, label = (via or "").partition(" ")
    if label and src == "manual":
        return m + " · %s·手动" % label, False
    if label and cols >= 100:
        return m + " · %s·自动" % label, False
    if route == "relay":
        return m + " · 中转", False
    return m, False


EFFORT_SHORT = {"low": "L", "medium": "M", "high": "H", "xhigh": "XH", "max": "MX"}


def short_model(model):
    """Opus 5.5 → O5.5, gpt-6-astra → g6a: the node header's 50–69 column form."""
    m = re.match(r"^([A-Z])[a-z]+ ([0-9][0-9.]*)", model)
    if m:
        return m.group(1) + m.group(2)
    m = re.match(r"^gpt-([0-9][0-9.]*)-([a-z])", model)
    return "g" + m.group(1) + m.group(2) if m else model


def ctx_parts(rec, cols, now):
    """The right side's 剩余 % · model · effort (issue #2717): the node's pane
    header (conf/tmux-attention.conf @fleet_ctx_hdr, #2431) said the same way —
    the % by what is left (>50 green, 20–50 amber, <20 red; handoff red +
    「⚠ 将交接」), the whole of it grey with 「· N 分钟前」 once the reading is
    5 minutes old, and its four widths: ≥100 all of it, 70–99 without 「剩余」,
    50–69 abbreviated, <50 the % alone. No ctx_left (a row nothing measured, an
    older node) ⇒ no parts."""
    left = rec.get("ctx_left")
    if not isinstance(left, int) or isinstance(left, bool):
        return []
    ts = rec.get("ctx_ts")
    old = isinstance(ts, int) and not isinstance(ts, bool) and ts > 0 and now - ts >= 300
    band = rec.get("ctx_band")
    pcol = DIM if old else BAD if band == "handoff" or left < 20 else WARN if left <= 50 else OK
    pct = ("剩余 " if cols >= 100 else "") + "%d%%" % left
    if band == "handoff" and cols >= 50:
        pct += " ⚠ 将交接" if cols >= 70 else " ⚠"
    out = [(pct, pcol, "")]
    model, effort = rec.get("model") or "", rec.get("effort") or ""
    tail = ""
    if model and cols >= 50:
        tail += " · " + (model if cols >= 70 else short_model(model))
        if effort:
            tail += " · " + (effort if cols >= 70 else EFFORT_SHORT.get(effort, effort))
    if old and cols >= 70:
        tail += " · %d 分钟前" % ((now - ts) // 60)
    if tail:
        out.append((tail, DIM if old else FG, ""))
    return out


def layout(rec, cols, down="", route="", now=None, via="", pin="", tries=""):
    """The line as a list of (text, colour, range) parts plus its background
    (None / BG_ASK / BG_DOWN). Pure: the selftest reads `fit`."""
    now = int(time.time()) if now is None else now
    glyph, word = state_of(rec)
    mach, grey = machine_text(rec, down, route, now, via, pin, tries, cols)
    asking = rec.get("state") == "needs" and rec.get("kind") != "perm"
    bg = BG_DOWN if grey else BG_ASK if asking else None
    scol = (BAD if glyph in ("?", "✖") else WARN if glyph in ("⊘", "↻") else
            OK if glyph == "✓" else HL if glyph == "●" else DIM)
    i, n = rec.get("i") or 0, rec.get("n") or 0
    left = [(" ‹ ", DIM, "prev"), ("%s/%s" % (i or "–", n), DIM, ""), (" ›", DIM, "next"), ("  ", None, "")]
    left.append((glyph + (" " + word if cols >= WORD_MIN else ""), scol, ""))
    left.append(("  ", None, ""))
    if rec.get("key"):
        left += [(rec["key"], HL, "key"), (" ", None, "")]
    right = []
    if rec.get("also") and cols >= REPO_MIN:
        right.append((rec["also"], WARN, ""))
    pr = rec.get("pr") or ""
    if pr and cols >= PR_MIN:
        prc = OK if pr.endswith("✓") or pr in ("merged", "live") else BAD if "✗" in pr or "✖" in pr else WARN
        right.append(("PR " + pr if pr[:1] == "#" else pr, prc, "pr"))
    if rec.get("repo") and cols >= REPO_MIN:
        right.append((rec["repo"], DIM, ""))
    ctx = ctx_parts(rec, cols, now)
    right.append((mach, WARN if grey else HL, "machine"))
    rtext = []
    for part in right:
        if part[2] == "machine" and ctx:
            rtext += ctx + [("  ", None, "")]
        rtext += [part, ("  ", None, "")]
    rtext[-1] = (" ", None, "")
    room = cols - sum(cells(t) for t, _, _ in left) - sum(cells(t) for t, _, _ in rtext) - 1
    title = clip(rec.get("title") or "", max(0, room))
    parts = left + [(title, FG if bg is None else None, "title")]
    pad = cols - sum(cells(t) for t, _, _ in parts) - sum(cells(t) for t, _, _ in rtext)
    parts.append((" " * max(1, pad), None, ""))
    return parts + rtext, bg


def fit(rec, cols, down="", route="", now=None, via="", pin="", tries=""):
    parts, bg = layout(rec, cols, down, route, now, via, pin, tries)
    return "".join(t for t, _, _ in parts), bg


def tmux_text(text):
    return text.replace("#", "##")


def render(args):
    kv = dict(a.split("=", 1) for a in args if "=" in a)
    cols = int(kv["cw"]) if kv.get("cw", "").isdigit() else 80
    if "--node" in args:
        return render_node(kv, cols)
    path = state_dir() / "switch-bar.json"
    rec = read_record(path)
    if rec is None:
        # no session row in view — a machine's bare shell, the writing area (the
        # list wrote `null`): the window's name. ‹ › and a tap on the name
        # still go round the sessions, so the one-pane layout (a phone in
        # Termius) never leaves a bare shell with no way to them. No record at
        # all (issue #2739) is said, not drawn as a bare shell: the list never
        # wrote one, and logs/topbar.log says why when a write failed.
        missing = "" if path.is_file() else "#[fg=%s]  %s" % (WARN, tmux_text(say("topbar_no_record") or "顶行无记录"))
        print("#[fg=%s]#[range=user|prev] ‹ #[norange]#[range=user|next]› #[norange] "
              "#[fg=%s,bold]#[range=user|title]%s#[norange]#[nobold]%s#[default]"
              % (DIM, HL, tmux_text(kv.get("wn", "")), missing))
        return 0
    rec["also"] = also_on(rec)
    parts, bg = layout(rec, cols, kv.get("down", ""), kv.get("rr", ""), None,
                       kv.get("rv", ""), kv.get("rp", ""), kv.get("rt", ""))
    print(paint(parts, bg))
    return 0


def paint(parts, bg):
    """The (text, colour, range) parts as tmux format, on `bg`."""
    fg_all = "#1a1b26" if bg == BG_ASK else None
    out = "#[bg=%s]" % bg if bg else ""
    if fg_all:
        out += "#[fg=%s]" % fg_all
    for text, colour, rng in parts:
        if not text:
            continue
        style = "fg=%s" % (fg_all or colour) if (colour or fg_all) else ""
        bold = ",bold" if rng in ("key", "title") and bg != BG_DOWN else ""
        seg = tmux_text(text)
        if rng:
            seg = "#[range=user|%s]%s#[norange]" % (rng, seg)
        if style:
            seg = "#[%s%s]%s#[nobold]" % (style, bold, seg)
        out += seg
    return out + "#[default]"


# --- the line drawn ON the machine (issue #2763, EPIC #2999 C1) ---------------------
# A thin client's 看台 (fleet-remote-view.sh attach --thin) wears its top line as
# its own status line: `render --node view=<id> s=<fleet session> reg=<registry dir>
# g=<the refresh loop's cache dir> sock=<socket> cw= w=<window> pc=<@peer_cur>
# pd=<pane_dead>`. No switch-bar.json and no task list here: the record is built
# off this machine's own books for the 看台's current window — the refresh loop's
# `remote_<session>` line for its worker id (the same columns cache_record reads;
# for another machine's window, C4, the far session's `@peer_cur`), else the
# window's own stamps (the measurement bus, the same ones `fleet ls` reads). The
# route comes from the 看台's registry row, another machine's link state from
# peerlink/state.json (C5). layout() and fit() are the client's, unchanged.

US = "\x1f"
NODE_FMT = "|".join(["#{@fleet_id}", "#{@peer_cur}", "#{@peer_node}", "#{@peer_login}",
                     "#{@claude_state}", "#{@claude_needs}", "#{@issue}", "#{@ctx_left}",
                     "#{@ctx_band}", "#{@ctx_ts}", "#{@model}", "#{@effort}", "#{@fleet_role}",
                     "#{window_name}"])


def reg_row(path):
    """A registry row's key=value columns (after the fifth) as a dict."""
    try:
        cols = path.read_text().split("\n", 1)[0].split("\t")
    except OSError:
        return {}
    return dict(c.split("=", 1) for c in cols[5:] if "=" in c)


def cache_lines(gdir, sess):
    try:
        with open(os.path.join(gdir, "remote_" + sess), encoding="utf-8", errors="replace") as f:
            return [l.rstrip("\n").split(US) for l in f if l.startswith("wid:")]
    except OSError:
        return []


def peer_down(conf_dir, node, login):
    """Whether the machine-to-machine link C5 keeps to <node> as <login> is
    down, off peerlink/state.json: its entry says not ok, or failures since its
    last good check. No file / no entry = not known = not down."""
    try:
        with open(os.path.join(conf_dir, "peerlink", "state.json")) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return False
    links = d.get("links", d) if isinstance(d, dict) else d
    if isinstance(links, dict):
        links = [dict(v, key=k) if isinstance(v, dict) else {} for k, v in links.items()]
    for e in links if isinstance(links, list) else []:
        if not isinstance(e, dict):
            continue
        if (e.get("machine") or e.get("node")) == node and (not login or e.get("login") in (login, None)):
            fails = e.get("fails") or e.get("failures") or 0
            return e.get("ok") is False or e.get("up") is False or (isinstance(fails, int) and fails > 0)
    return False


def stamp_ctx(p):
    """The window's own measurement-bus stamps as the record's ctx fields."""
    out = {}
    if p[7].isdigit() and int(p[7]) <= 100:
        out["ctx_left"] = int(p[7])
    if p[8] in ("ok", "watch", "handoff"):
        out["ctx_band"] = p[8]
    if p[9].isdigit() and int(p[9]) > 0:
        out["ctx_ts"] = int(p[9])
    if re.fullmatch(r"[A-Za-z0-9 ._()+-]{1,64}", p[10]):
        out["model"] = p[10]
    if re.fullmatch(r"[a-z]{1,16}", p[11]):
        out["effort"] = p[11]
    return out


def line_ctx(p):
    """The cache line's columns 21-25 (left|band|ts|model|effort) as ctx fields."""
    p = p + [""] * (25 - len(p))
    return stamp_ctx([""] * 7 + p[20:25])


def node_record(kv):
    """The record for the 看台's current window, and the route / down words."""
    reg = Path(kv.get("reg") or "")
    row = reg_row(reg / kv.get("view", "")) if kv.get("view") else {}
    sock, win, sess = kv.get("sock") or "", kv.get("w") or "", kv.get("s") or ""
    out = subprocess.run(["tmux", "-S", sock, "display-message", "-p", "-t", win, NODE_FMT],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout if sock and win else ""
    p = out.rstrip("\n").split("|", 13)
    p += [""] * (14 - len(p))
    fid, peer, pnode, plogin = p[0], p[1][4:] if p[1].startswith("wid:") else p[1], p[2], p[3]
    wid = peer or ("%s/%s" % (row["fuid"], fid) if row.get("fuid") and fid else "")
    lines = cache_lines(kv.get("g") or "", sess)
    hit = None
    for i, line in enumerate(lines):
        key = line[0][4:]
        if (wid and key == wid) or (not peer and fid and not row.get("fuid") and key.endswith("/" + fid)):
            hit = (i, line)
            break
    here = row.get("node") or ""
    if hit:
        i, line = hit
        q = line + [""] * (25 - len(line))
        state = q[5] or "idle"
        rec = {"i": i + 1, "n": len(lines), "state": state,
               "kind": ("perm" if q[9].startswith("perm") else "ask") if state == "needs" else "",
               "key": "#" + q[3] if q[3].isdigit() else "", "title": (q[16] or q[7]).strip(),
               "node": q[1].strip() or pnode or here, "lost": q[2] == "lost", "wid": q[0][4:]}
        rec.update(line_ctx(q))
    else:
        state = p[4] or "idle"
        rec = {"i": 0, "n": len(lines), "state": state,
               "kind": ("perm" if p[5].startswith("perm") else "ask") if state == "needs" else "",
               "key": "#" + p[6] if p[6].isdigit() else "", "title": p[13].strip(),
               "node": pnode or here, "lost": False, "wid": wid}
    if not peer:
        rec.update(stamp_ctx(p))   # this machine's own window: its stamps are the freshest reading
    if p[12] == "orchestrator" and not rec.get("title"):
        rec["title"] = say("sidebar_portal") or "新任务"
    down = ""
    if peer and (kv.get("pd") == "1" or peer_down(str(reg.parent), pnode, plogin)):
        down = "1"
    route = row.get("route") or ""
    src, _, rname = route.rpartition(":")
    via = "" if not rname or rname == "relay" else "%s %s" % ("manual" if src == "manual" else "auto",
                                                                 PIN_WORDS.get(rname, rname))
    return rec, down, "relay" if rname == "relay" else "", via


def render_node(kv, cols):
    rec, down, rr, via = node_record(kv)
    parts, bg = layout(rec, cols, down, rr, None, via)
    print(paint(parts, bg))
    return 0


# --- a tap on the line -------------------------------------------------------------

def shell_tmux(sess, *args):
    return subprocess.run(["tmux", "-L", sess, *args], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL).stdout.strip()


def shell_env(sess):
    """The environment a script needs to act on the shell's server as if run
    there: TMUX pointing at it (bare `tmux` in dash-popup.sh / fleet-open.sh)."""
    line = shell_tmux(sess, "display-message", "-p", "#{socket_path},#{pid},0")
    env = dict(os.environ)
    env.pop("TMUX_PANE", None)
    if line:
        env["TMUX"] = line
    return env


def shell_client(sess):
    best = ("", -1)
    for line in shell_tmux(sess, "list-clients", "-F", "#{client_activity} #{client_name}").splitlines():
        act, _, name = line.partition(" ")
        if act.isdigit() and int(act) > best[1]:
            best = (name, int(act))
    return best[0]


def list_pane(sess):
    for line in shell_tmux(sess, "list-panes", "-a", "-F", "#{pane_id} #{@sidebar}").splitlines():
        pid, _, flag = line.partition(" ")
        if flag == "1":
            return pid
    return ""


def note(sess, client, text):
    shell_tmux(sess, "display-message", *(["-c", client] if client else []), text)


def switcher_cmd(sess, client):
    """The full-screen switcher on the shell's client (F1's body, a tap on the title)."""
    return ["bash", str(BIN / "dash-popup.sh"), "--title", "popup_quickopen", "--client", client,
            "--no-inline", "-w", "100%", "-h", "100%", "--", "python3",
            str(BIN / "fleet-quickopen.py"), "--full", "--session", sess]


def click(what, sess):
    rec = read_record() or {}
    client = shell_client(sess)
    if what in ("prev", "next"):
        pane = list_pane(sess)
        if pane:
            shell_tmux(sess, "set-option", "-pa", "-t", pane, "@sidebar_do", what + " ", ";",
                       "send-keys", "-t", pane, "F12")
        return 0
    if what == "title":
        subprocess.run(switcher_cmd(sess, client), env=shell_env(sess), stdin=subprocess.DEVNULL,
                       capture_output=True)
        return 0
    if what in ("key", "pr"):
        num = re.search(r"[0-9]+", rec.get(what) or "")
        slug = rec.get("slug") or ""
        if not (num and "/" in slug):
            note(sess, client, "%s · %s" % (rec.get("key") or rec.get("title") or "", rec.get(what) or "—"))
            return 0
        url = "https://github.com/%s/%s/%s" % (slug, "issues" if what == "key" else "pull", num.group(0))
        subprocess.run(["bash", str(BIN / "fleet-open.sh"), url], env=shell_env(sess),
                       stdin=subprocess.DEVNULL, capture_output=True)
        return 0
    if what == "machine":
        mach = "@" + (rec.get("node") or "?")
        word = "offline" if rec.get("lost") else "online"
        if rec.get("direct"):
            word += " · 直连（入口没声音）"
        note(sess, client, "%s · %s · %s" % (mach, word, rec.get("title") or ""))
    return 0


def say(key, *args):
    r = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "t", key, *args],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return r.stdout.strip()


ENDED_FRESH = 600   # a solo-ended file older than this was never taken: a detach since is a plain one


def goodbye(args=()):
    """The one-session view's last words (issue #2265): the session in view is on
    its machine still (`node=`, the server's @fleet_view_node, else the record's)
    — or it ended, and fleet-sidebar.py left its file (`solo-ended`, the machine
    in it), taken once here."""
    ended = state_dir() / "solo-ended"
    node, gone = "", False
    try:
        if time.time() - ended.stat().st_mtime < ENDED_FRESH:
            node, gone = ended.read_text().strip(), True
        ended.unlink()
    except OSError:
        pass
    if not node:
        node = dict(a.split("=", 1) for a in args if "=" in a).get("node", "").strip()
    if not node:
        node = ((read_record() or {}).get("node") or "").strip()
    node = node or "fleet"
    if gone:
        print(say("solo_ended_fmt", node))
        print(say("solo_resume"))
    else:
        print(say("solo_left_fmt", node))
        print(say("solo_back"))
    return 0


def main(argv):
    if argv[:1] == ["goodbye"]:
        return goodbye(argv[1:])
    if argv[:1] == ["render"]:
        return render(argv[1:])
    if argv[:1] == ["click"] and len(argv) >= 3:
        return click(argv[1], argv[2])
    if argv[:1] == ["fit"] and len(argv) >= 3:
        rec = read_record(Path(argv[2])) or {}
        kv = dict(a.split("=", 1) for a in argv[3:] if "=" in a)
        text, bg = fit(rec, int(argv[1]), kv.get("down", ""), kv.get("rr", ""),
                       int(kv["now"]) if kv.get("now", "").isdigit() else None)
        print("%s\t%s" % ({None: "-", BG_ASK: "red", BG_DOWN: "grey"}[bg], text))
        return 0
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
