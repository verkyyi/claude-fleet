#!/usr/bin/env python3
"""fleet-topbar.py — the session's top line in the client (issue #1904, EPIC #1906
C11): the line above the right pane, which the shell's STAGE server draws
(conf/tmux-shell-stage.conf's status-left). It says THIS session only, in the
⌘P panel's own glyphs (issue #3194, EPIC #3178): going round the sessions, and
what the others are doing, is the panel's.

    fleet-topbar.py render cw=<cols> [down=<epoch>] [rr=<route>] [rv=<auto|manual> <route>]
                           [rp=<pinned route>] [rt=<reconnects>] [wn=<window name>] [gen=…]
        the line, as tmux format: glyph (word ·) #N title (· repo) …… PR · context (· 今天 N) (· machine) (· ⌘P)
    fleet-topbar.py render --node view=<id> s=<fleet> reg=<dir> g=<dir> sock=<socket> cw= w= [pc=] [pd=]
        the same line drawn ON the machine, as a thin client's 看台's status line
        (issue #2763, EPIC #2999 C1; fleet-remote-view.sh attach --thin) — see
        render_node below
    fleet-topbar.py click <range> <shell session>
        a tap on one of its parts (the stage's MouseDown1Status bind):
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
that one dropped), `@remote_route` (on the hub relay), `@remote_via`
(claude-fleet#2886: the route and who chose it), `@remote_pin` + `@remote_tries`
(a pinned route reconnecting: 第 N 次).

Three widths, the design's: a phone (~45 columns) has the glyph, #N, the title
and 「62%」; from 80 the state's word, 「PR #N」 and 「62% Opus 5.5 high」; from
140 the repo after the title, the PR's checks, 「剩余 62% · Opus 5.5 · high」 and
「⌘P」 at the right. On every width 「今天 12.3 万」 after the context when the
hub recorded pool tokens for the session today (issue #3377, the record's
tokens_today — none ⇒ nothing, never 0). The title is clipped with `…`. The six glyphs and their
colours are fleet_view.py's table (! x » ✓ ∙ ?, FLEET_GLYPHS=ascii, NO_COLOR):
the whole line red while the session waits on you (its question in the title's
place), grey with ? while its machine is out of reach or on the relay — the only
time the machine is written.
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

sys.path.insert(0, str(BIN))
import fleet_ticket_url as FTU  # noqa: E402 — where a ticket reads (#3596)
import fleet_view as FV   # noqa: E402 — the ⌘P panel: its glyph table is the one table (#3194)

# a state the panel's sym_of reads as idle but this line calls working (the design:
# 在干活 含循环中、准备中、唤醒中)
WORKING = ("preparing", "waking")

# colours: the stage's own (conf/tmux-shell-stage.conf); the glyphs' are the
# panel's 16-colour palette numbers (FV.GLYPH_COLORS), as tmux colourN
FG, DIM, HL, OK, WARN, BAD = "#a9b1d6", "#565f89", "#7aa2f7", "#9ece6a", "#e0af68", "#f7768e"
BG_ASK, BG_DOWN = "#f7768e", "#3b4261"

# the design's three widths: a phone (~45) has the glyph, #N, the title and the %;
# from MID the state's word, the PR, the model and effort; from WIDE the repo, the
# PR's checks, 「剩余」 and the ⌘P hint
MID, WIDE = 80, 140


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


def cells(text):
    """Cells as the panel counts them (fleet-quickopen.py char_cells): wide /
    full-width 2, a riding mark or zero-width 0, else 1 — so » and ∙ (ambiguous
    width) are one cell, as the panel draws them."""
    return sum(0 if unicodedata.category(c) in ("Mn", "Me", "Cf") else
               2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


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


def sym_of(rec, trouble=False):
    """The record's glyph class off the panel's table: lost wins (out of reach,
    the reading stale, on the relay), then the state."""
    state = rec.get("state") or "idle"
    return FV.sym_of("working" if state in WORKING else state, trouble)


def state_word(rec, sym):
    """在干活 · 做完了 · 已退出 / 失败 · 空闲 — the panel's words; ! and ? say none."""
    if sym in ("needs", "lost"):
        return ""
    if sym == "fail":
        return FV.state_words("failed" if rec.get("state") == "failed" else "exited")
    return FV.state_words({"work": "working", "done": "done"}.get(sym, "idle"))


# @remote_via's route word for the hub relay: fleet-connect.py route_label's, a value
# the stage carries (`auto 中转`), matched here — never drawn
RELAY_WORD = "\u4e2d\u8f6c"


def trouble_text(rec, down, route, via, pin, tries, cols):
    """The machine — only when something is wrong with reaching it: 「mac-a 连不上」
    (lost, or this machine's connection to it dropped; a pinned route reconnecting
    adds 「第 N 次重连」 from MID) or 「mac-a 经中转」 (on the hub relay). '' when all
    is well: the machine is otherwise never written (#3194)."""
    node = rec.get("node") or "?"
    if rec.get("lost") or down:
        n = int(tries) if str(tries).isdigit() else 0
        return say("topbar_down_fmt", node) + (" · " + say("topbar_retry_fmt", n)
                                               if down and pin and n and cols >= MID else "")
    if route == "relay" or (via or "").partition(" ")[2] == RELAY_WORD:
        return say("topbar_relay_fmt", node)
    return ""


def ctx_parts(rec, cols, now):
    """The context reading (issue #2717), on every width: 「62%」 · from MID
    「62% Opus 5.5 high」 · from WIDE 「剩余 62% · Opus 5.5 · high」. The % by
    what is left (>50 green, 20–50 amber, <20 red; the handoff band adds ⚠), the
    whole of it grey with 「· N 分钟前」 once the reading is 5 minutes old. No
    ctx_left (nothing measured, an older node) ⇒ no parts."""
    left = rec.get("ctx_left")
    if not isinstance(left, int) or isinstance(left, bool):
        return []
    ts = rec.get("ctx_ts")
    old = isinstance(ts, int) and not isinstance(ts, bool) and ts > 0 and now - ts >= 300
    band = rec.get("ctx_band")
    pcol = DIM if old else BAD if band == "handoff" or left < 20 else WARN if left <= 50 else OK
    pct = "%d%%" % left
    pct = (say("topbar_left_fmt", pct) if cols >= WIDE else pct) + (" ⚠" if band == "handoff" else "")
    out = [(pct, pcol, "")]
    model, effort = rec.get("model") or "", rec.get("effort") or ""
    sep = " · " if cols >= WIDE else " "
    tail = ""
    if model and cols >= MID:
        tail += sep + model + (sep + effort if effort else "")
    if old and cols >= MID:
        tail += " · " + say("topbar_ago_fmt", (now - ts) // 60)
    if tail:
        out.append((tail, DIM if old else FG, ""))
    return out


def pr_part(pr, cols):
    """「PR #3171」, from WIDE with its checks (✓ / … / ✗); a merged one
    「PR 已合并」. The producer's cell (tmux-dashboard-rows.sh): `#N<ci>` open,
    merged / live / deploy… / deploy✗, closed."""
    gl = FV.glyphs()
    if pr in FV.MERGED_PR:
        return (say("topbar_pr_merged") + ((" ✗" if gl is FV.GLYPHS else " x") if pr == "deploy✗" and cols >= WIDE else ""),
                BAD if pr == "deploy✗" else OK, "pr")
    if pr == "closed":
        return (say("topbar_pr_closed"), DIM, "pr")
    m = re.match(r"#([0-9]+)(.*)", pr)
    if not m:
        return (pr, DIM, "pr")
    ci = m.group(2)
    good, bad = ci.startswith("✓"), "✗" in ci or "✖" in ci or "!" in ci
    text = "PR #" + m.group(1)
    if cols >= WIDE:
        fancy = gl is FV.GLYPHS
        text += " " + (gl["done"] if good else ("✗" if fancy else "x") if bad else "…" if fancy else "...")
    return (text, OK if good else BAD if bad else WARN, "pr")


def layout(rec, cols, down="", route="", now=None, via="", pin="", tries=""):
    """The line as a list of (text, colour, range) parts plus its background
    (None / BG_ASK / BG_DOWN) — the ⌘P panel's blueprint (issue #3194, EPIC #3178):
    glyph · (word ·) #N · title (· repo) …… PR · context (· 今天 N) (· machine) (· ⌘P).
    The whole line red while the session waits on you (a question or an OK — the
    question's own words take the title's place), grey while out of reach or on
    the relay. Pure: the selftest reads `fit`."""
    now = int(time.time()) if now is None else now
    trouble = trouble_text(rec, down, route, via, pin, tries, cols)
    sym = sym_of(rec, bool(trouble))
    bg = BG_DOWN if trouble else BG_ASK if sym == "needs" else None
    scol = "colour%d" % FV.GLYPH_COLORS[sym] if FV.color_on() else None
    left = [(" ", None, ""), (FV.glyphs()[sym], scol, "sym")]
    word = state_word(rec, sym) if cols >= MID else ""
    if word:
        left.append((" " + word + " ·", scol, ""))
    if rec.get("key"):
        left += [(" ", None, ""), (rec["key"], HL, "key")]
    left.append((" ", None, ""))
    title = (rec.get("q") if sym == "needs" else "") or rec.get("title") or ""
    repo = " · " + rec["repo"] if rec.get("repo") and cols >= WIDE else ""
    right = []
    if rec.get("pr") and cols >= MID:
        right.append([pr_part(rec["pr"], cols)])
    ctx = ctx_parts(rec, cols, now)
    if ctx:
        right.append(ctx)
    tok = rec.get("tokens_today")
    if isinstance(tok, int) and not isinstance(tok, bool) and tok > 0:
        # what the session used today on the pool (issue #3377): the hub's count,
        # never a 0 when none is recorded
        right.append([(say("topbar_today_fmt", FV.tokens_short(tok)), DIM, "")])
    if trouble:
        right.append([(trouble, WARN, "machine")])
    if cols >= WIDE:
        right.append([("⌘P", DIM, "")])
    sep = " · " if cols >= MID else " "
    rtext = []
    for group in right:
        rtext += ([(sep, DIM, "")] if rtext else []) + group
    rtext.append((" ", None, ""))
    room = cols - sum(cells(t) for t, _, _ in left) - sum(cells(t) for t, _, _ in rtext) - 1
    if repo and cells(repo) > room - 6:
        repo = ""                 # the title's start before the repo
    title = clip(title, max(0, room - cells(repo)))
    parts = left + [(title, FG, "title"), (repo, DIM, "")]
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
        # list wrote `null`): the window's name; a tap on it opens the switcher
        # (going round the sessions is the panel's, #3194). No record at
        # all (issue #2739) is said, not drawn as a bare shell: the list never
        # wrote one, and logs/topbar.log says why when a write failed.
        missing = "" if path.is_file() else "#[fg=%s]  %s" % (WARN, tmux_text(say("topbar_no_record")))
        print("#[fg=%s,bold]#[range=user|title] %s#[norange]#[nobold]%s#[default]"
              % (HL, tmux_text(kv.get("wn", "")), missing))
        return 0
    parts, bg = layout(rec, cols, kv.get("down", ""), kv.get("rr", ""), None,
                       kv.get("rv", ""), kv.get("rp", ""), kv.get("rt", ""))
    print(paint(parts, bg))
    return 0


def paint(parts, bg):
    """The (text, colour, range) parts as tmux format, on `bg`: a red line is
    dark text throughout, a grey one plain text but for its yellow ?."""
    fg_all = "#1a1b26" if bg == BG_ASK else FG if bg == BG_DOWN else None
    out = "#[bg=%s]" % bg if bg else ""
    if fg_all:
        out += "#[fg=%s]" % fg_all
    for text, colour, rng in parts:
        if not text:
            continue
        own = colour if bg == BG_DOWN and rng == "sym" else None
        style = "fg=%s" % (own or fg_all or colour) if (colour or fg_all) else ""
        bold = ",bold" if rng in ("key", "title") and bg != BG_DOWN else ""
        seg = tmux_text(text)
        if rng and rng != "sym":
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
# peerlink/state.json (C5). layout() and fit() are the client's, unchanged — a
# phone's 看台 keeps the % too (#3194: it used to drop the reading under 100 columns).

US = "\x1f"
NODE_FMT = "|".join(["#{@fleet_id}", "#{@peer_cur}", "#{@peer_node}", "#{@peer_login}",
                     "#{@claude_state}", "#{@claude_needs}", "#{@issue}", "#{@ctx_left}",
                     "#{@ctx_band}", "#{@ctx_ts}", "#{@model}", "#{@effort}", "#{@fleet_role}",
                     "#{window_name}", "#{@task}"])
TASK_RE = re.compile(r"T[1-9][0-9]{0,17}")


def ticket(issue, task):
    """The number in the bar (issue #3325): the issue's #N when there is one,
    else the hub's task record T<n> (@task), else nothing."""
    if issue.isdigit():
        return "#" + issue
    return task if TASK_RE.fullmatch(task or "") else ""


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


def asked(sock, win):
    """What a local window waiting on you asks, in one line: the agent's own
    words (@agent_status's msg, issue #2538), else the hooks' @claude_needs_detail.
    One read each — either may hold a `|` (and tmux does not pass every control
    byte through display-message, so they cannot share NODE_FMT's line)."""
    def opt(name):
        return subprocess.run(["tmux", "-S", sock, "display-message", "-p", "-t", win, "#{%s}" % name],
                              capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
    try:
        msg = (json.loads(opt("@agent_status") or "{}") or {}).get("msg")
    except (ValueError, AttributeError):
        msg = ""
    return FV.one_line(msg if isinstance(msg, str) and msg else opt("@claude_needs_detail"))


def node_record(kv):
    """The record for the 看台's current window, and the route / down words."""
    reg = Path(kv.get("reg") or "")
    row = reg_row(reg / kv.get("view", "")) if kv.get("view") else {}
    sock, win, sess = kv.get("sock") or "", kv.get("w") or "", kv.get("s") or ""
    out = subprocess.run(["tmux", "-S", sock, "display-message", "-p", "-t", win, NODE_FMT],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout if sock and win else ""
    # the name may hold a `|`: it is cut off the front, @task (the last) off the end
    head, _, task = out.rstrip("\n").rpartition("|") if out.count("|") >= 14 else (out.rstrip("\n"), "", "")
    p = head.split("|", 13)
    p += [""] * (14 - len(p))
    p.append(task)
    fid, peer, pnode, plogin = p[0], p[1][4:] if p[1].startswith("wid:") else p[1], p[2], p[3]
    wid = peer or ("%s/%s" % (row["fuid"], fid) if row.get("fuid") and fid else "")
    lines = cache_lines(kv.get("g") or "", sess)
    hit = None
    for line in lines:
        key = line[0][4:]
        if (wid and key == wid) or (not peer and fid and not row.get("fuid") and key.endswith("/" + fid)):
            hit = line
            break
    here = row.get("node") or ""
    if hit:
        line = hit
        q = line + [""] * (28 - len(line))
        state = q[5] or "idle"
        rec = {"state": state,
               "kind": ("perm" if q[9].startswith("perm") else "ask") if state == "needs" else "",
               "q": FV.one_line(q[27]) if state == "needs" else "",
               "key": ticket(q[3], "" if peer else p[14]), "title": (q[16] or q[7]).strip(),
               "node": q[1].strip() or pnode or here, "lost": q[2] == "lost", "wid": q[0][4:]}
        rec.update(line_ctx(q))
    else:
        state = p[4] or "idle"
        rec = {"state": state,
               "kind": ("perm" if p[5].startswith("perm") else "ask") if state == "needs" else "",
               "key": ticket(p[6], p[14]), "title": p[13].strip(),
               "node": pnode or here, "lost": False, "wid": wid}
    if not peer:
        rec.update(stamp_ctx(p))   # this machine's own window: its stamps are the freshest reading
        if rec["state"] == "needs":
            rec["q"] = asked(sock, win) or rec.get("q", "")
    if p[12] == "orchestrator" and not rec.get("title"):
        rec["title"] = say("sidebar_portal")
    down = ""
    if peer and (kv.get("pd") == "1" or peer_down(str(reg.parent), pnode, plogin)):
        down = "1"
    route = row.get("route") or ""
    src, _, rname = route.rpartition(":")
    via = "" if not rname or rname == "relay" else "%s %s" % ("manual" if src == "manual" else "auto", rname)
    return rec, down, "relay" if rname == "relay" else "", via


def render_node(kv, cols):
    # this connection's language (issue #3329): the 看台's `@view_lang`, when the
    # door recorded one (`vl=1:<locale>`) — fleet-ui-lang.sh weighs it after the
    # person's own choice; set before the first word is looked up
    vl = kv.get("vl", "")
    if vl.startswith("1:"):
        os.environ["FLEET_VIEW_LANG"] = vl[2:]
    # the one-time language line (D8, L4): the whole line for 8 s, then the status
    flu = kv.get("flu", "")
    if kv.get("fl") and flu.isdigit() and time.time() < int(flu):
        print("#[fg=%s,bold] i #[nobold]#[fg=%s]%s#[default]" % (HL, FG, tmux_text(kv["fl"])))
        return 0
    rec, down, rr, via = node_record(kv)
    parts, bg = layout(rec, cols, down, rr, None, via)
    print(own_window(kv.get("w", ""), paint(parts, bg)))
    return 0


# --- the line belongs to ONE window (issue #3532) ----------------------------------
# tmux keeps one `#()` job per client for the 看台's status line and draws its LAST
# output until a new run finishes (format.c format_job_get): on a window switch — a
# close moving the 看台 to another window, a go, a select — the first redraw showed
# the window just left, for as long as python took (0.1 s idle, seconds on a busy
# machine). So the output says which window it was made for: tmux expands it again
# at every redraw in the client's CURRENT window, and a line made for another
# window gives way at once to quick_fmt() — tmux's own format off the new window's
# stamps (glyph · #N · name), no process — until this run's line lands. No hook, no
# option written, no extra redraw: idle costs exactly what it did.

def branch_text(fmt):
    """A tmux format made safe as a #{?…} branch: `,` and `}` escaped (`#,` `#}` —
    expanded back once, styles' commas included); `##` stays the literal `#`."""
    return fmt.replace(",", "#,").replace("}", "#}")


def quick_fmt():
    """The stand-in line, pure tmux format: the window's own @claude_state as the
    panel's glyph (sym_of's classes), its #N (@issue) else T<n> (@task), its name."""
    g, color = FV.glyphs(), FV.color_on()

    def glyph(sym):
        return ("#[fg=colour%d]%s#[default]" % (FV.GLYPH_COLORS[sym], g[sym]) if color else g[sym])
    sym = glyph("idle")
    for state, cls in (("done", "done"), ("landed", "done"), ("working", "work"), ("looping", "work"),
                       ("preparing", "work"), ("waking", "work"), ("failed", "fail"), ("exited", "fail"),
                       ("error", "fail"), ("needs", "needs")):
        sym = "#{?#{==:#{@claude_state},%s},%s,%s}" % (state, branch_text(glyph(cls)), sym)
    key = ("#{?#{m/r:^[0-9]+$,#{@issue}},#[fg=%s#,bold]###{@issue}#[nobold] ,"
           "#{?#{m/r:^T[1-9][0-9]*$,#{@task}},#[fg=%s#,bold]#{@task}#[nobold] ,}}" % (HL, HL))
    # a #{?…} branch itself (own_window's last): its own top-level commas escaped too
    return " %s %s#[fg=%s#,bold]#{=/64/…:window_name}#[default]" % (sym, key, FG)


def own_window(win, line):
    """`line` for window `win` only: #{?<the client's window is win>,line,quick}."""
    if not re.fullmatch(r"@[0-9]+", win or ""):
        return line
    return "#{?#{==:#{window_id},%s},%s,%s}" % (win, branch_text(line), quick_fmt())


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
        url = (FTU.ticket_url(slug, num.group(0)) if what == "key"
               else "https://github.com/%s/pull/%s" % (slug, num.group(0)))
        if not url:
            note(sess, client, "%s · %s" % (rec.get("key") or rec.get("title") or "", rec.get(what) or "—"))
            return 0
        subprocess.run(["bash", str(BIN / "fleet-open.sh"), url], env=shell_env(sess),
                       stdin=subprocess.DEVNULL, capture_output=True)
        return 0
    if what == "machine":
        mach = "@" + (rec.get("node") or "?")
        word = "offline" if rec.get("lost") else "online"
        if rec.get("direct"):
            word += " · " + say("topbar_direct_quiet")
        note(sess, client, "%s · %s · %s" % (mach, word, rec.get("title") or ""))
    return 0


_WORDS = {}


def say(key, *args):
    """A string off fleet-ui-lang.sh, the one table — read once per process
    (`dump`, as fleet_view.py and fleet-sidebar.py do); a key it lacks prints itself.
    The dump is a shell run (~70 ms, seconds on a busy box) a 看台's line paid on
    every render — each 2 s and each window switch (issue #3532): kept per
    FV.words_key(), as the panel's own (#3514)."""
    if not _WORDS:
        kept = FV.dash_global() / ("topbar-words-" + FV.words_key())
        try:
            raw = kept.read_text(encoding="utf-8").split("\0")
        except (OSError, ValueError):
            raw = []
        if len(raw) < 2:
            try:
                out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "topbar_", "sidebar_portal", "solo_"],
                                     capture_output=True, text=True, stdin=subprocess.DEVNULL,
                                     timeout=5).stdout
            except (OSError, subprocess.TimeoutExpired):
                out = ""
            raw = out.split("\0")
            if out:
                FV.atomic_write(kept, out)
        _WORDS.update({k: v.replace("\1", "%s") for k, v in zip(raw[0::2], raw[1::2])})
        _WORDS.setdefault("_", "")
    text = _WORDS.get(key, key)
    try:
        return text % args if args else text
    except (TypeError, ValueError):
        return text


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
