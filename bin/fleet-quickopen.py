#!/usr/bin/env python3
"""fleet-quickopen.py — ⌘P: type a few letters, ↵, and the client is on that
session (issue #1903, EPIC #1906 C10) — and the switch history ⌘[ / ⌘] walk.

    fleet-quickopen.py [--session S] [--pane <list pane>]
                                              the popup (conf/tmux-shell.conf's
                                              ⌘P / prefix / open it through the
                                              one popup door)
    fleet-quickopen.py --switch [--session S] ⌘K (issue #2266, EPIC #2259 C7): the
                                              same popup, every session most recent
                                              first with how long ago it was in view,
                                              then 「+ 新会话」, a rule and
                                              「打开多会话视图」 (in the one-session
                                              view) / 「收起侧栏」 (anywhere else)
    fleet-quickopen.py switch [<query>]       ⌘K's lines, plain (the selftest's view)
    fleet-quickopen.py switch-run <key|new|layout:multi|layout:solo|quit|route> [<session>]
                                              ↵ on that line
    fleet-quickopen.py rank [--all] [<query>] the ranked rows, one per line
                                              (`key<TAB>name`) — the selftest's view;
                                              --all reads every session as the popup does
    fleet-quickopen.py jump <key>             hand <key> to the list, as ↵ does
    fleet-quickopen.py --full [--session S]   the FULL-SCREEN switcher (issue #1904:
                                              F1 / a tap on the top line's title at
                                              phone width): 在等你的 · 最近 (1–9) ·
                                              全部, two-line rows big enough for a
                                              thumb; type to filter, tap or ↵ to go
    fleet-quickopen.py --view <view> · do <verb> --view <view> · view-keys ·
    go <view> <target> · view-rows --view <view> · view-peers --view <view>
                                              the 看台's switcher on the home machine
                                              (issue #3000, EPIC #2999 C2; another
                                              machine's windows, C4): its node
                                              half, bin/fleet_view.py, says it all
    fleet-quickopen.py do <verb>              next | prev | back | fwd | needs — the
                                              one-pane layout's F2–F4 and ⌘ keys
                                              (the list is zoomed away there, so
                                              {top-left} is not it): as the binds do
    fleet-quickopen.py commands               THE command table (issue #1952), one
                                              `action<TAB>group` line each, in order
                                              — what the row menu reads to order
                                              its items (fleet-sidebar-menu.sh)
    fleet-quickopen.py cmds [--target K] [<query>]
                                              what `>` lists for that row (default:
                                              the one in view), `action<TAB>name<TAB>
                                              hint`, a greyed one's name led by `-`
    fleet-quickopen.py run <action> [--target K]
                                              do it, as ↵ on its `>` line does

Two files, ONE writer each, under the client's state dir
(FLEET_SWITCH_STATE, else $XDG_STATE_HOME/claude-fleet, else
~/.local/state/claude-fleet — one per client computer):

    switch-rows.tsv      the list's live rows as it last painted them, written by
                         fleet-sidebar.py on change: key · state · glyph · name ·
                         machine · group · badge — what the popup shows at once;
                         a moment later it has every session, a folded subtree's
                         too (the list's producer, run with FLEET_ROWS_UNFOLD=1)
    switch-history.json  the switches, written by fleet-sidebar.py on every
                         change of the row in view: `stack` + `at` (⌘[ ⌘] walk
                         it like a browser's back/forward), `mru` (most recent
                         first — the order an empty ⌘P shows) and `seen` (when
                         each was last in view — ⌘K's age column)

The popup never switches anything itself: ↵ appends `jump=<key>` to the list
pane's @sidebar_do and wakes it with F12, so a switch goes through the list's own
jump() — the one place that knows a proxy window from a local one — exactly as
⌘↓ / ⌘[ do (their binds append `next` / `back` the same way).

Commands (issue #1952, EPIC #1949 C3): a query that starts with `>` lists what
can be done to the row in view — rename, pin, move, reap, the landed list, the
detail column, and everything else its right-click menu has — ↑↓ and ↵. It is
ONE table, `COMMANDS` below: the row menu (fleet-sidebar-menu.sh) orders its
items by it, and `>` lists the items that menu builds for the row — the label it
would show (greyed when it would grey it), the hint off the menu's letter table
(fleet-ui-lang.sh `menu_keys`) and the tmux command it would run. So a command is
never spelt twice: ↵ runs exactly what picking it in the menu runs.

ONE PANEL OF SESSIONS AND ACTIONS (issue #2365, 「一切优化为 CLI」): ⌘P is the way
in, not the right-click menu (which stays, unadvertised). Each row carries its
单号 · 机器 · 状态 · PR · 回收方式 (the bar no longer says them); ⌃R 改名 · ⌃X
回收 · ⌃A 回答 · ⌃E 改回收方式 · ⌃O 打开 PR act on the lit row — each runs THAT
row's menu item (ROW_KEYS → menu_items), so a key never spells an action twice;
⌃A off a waiting row moves onto the first one that waits, and ⌃O on a row with
no 「打开 PR」 item (another machine's) opens its PR's — else its issue's — page.
ON TOP, NO `>` NEEDED (issue #2753): 「⚡ 派一件事…」 (the ⌘T popup,
bin/fleet-quick-dispatch.py, run in this one), + 新会话, the layout flip and 退出 fleet
are a pinned group above the sessions (top_lines; a query keeps the ones it
names). An empty ⌘P still lights the session before, so ↵ is «the one before»
as it was; ↑ reaches the group.
`>` lists the panel's own lines first (panel_cmds: 派一件事 · 退出 fleet · 新会话 claude |
codex · 切到多 / 单会话视图 · 改名当前会话 — ⌘K's tail folded in; ⌘K and prefix s
open this same panel now), then the row menu's. The last line always says the
keys (the bar's @fleet_hint_palette says the same). An empty query lists the
rows waiting on you first.
    fleet-quickopen.py panel-cmds                `>`'s own lines, plain

Ranking (`rank`): an empty query lists the most recent first, the row in view
last (↵ on an empty ⌘P is «the one before»); a query keeps the rows it matches —
a substring of the name first (earlier is better, a word start best), then a
substring of the machine / state / group, then the letters in order with word
starts and runs scored (`crr` finds 「Codex: reap rules」) — ties broken by
recency, then list order.
"""
import curses
import json
import locale
import os
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent

US = "\x1f"
STACK_MAX = 50
WAITING = ("needs", "failed")   # the rows an empty ⌘P lists first (issue #2365)
MRU_MAX = 100
STATE_WORDS = {"needs": "needs ask 在问你", "failed": "failed 失败", "working": "working 在干活",
               "idle": "idle 空闲", "done": "done 完成", "landed": "landed"}


def state_dir():
    """The client's switch state dir: FLEET_SWITCH_STATE, else the XDG state dir —
    or, when that cannot be made or written (a `~/.local/state` another account
    created, issue #2739: every write into it failed and nothing said so), the
    cache dir's `claude-fleet/state`. The writer (the list) and the readers (the
    top line, ⌘P) all ask here, so they agree on the fallback too."""
    env = os.environ.get("FLEET_SWITCH_STATE")
    if env:
        return Path(env)
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    main = Path(base) / "claude-fleet"
    if usable_dir(main):
        return main
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(cache) / "claude-fleet" / "state"


def usable_dir(path):
    """`path` is (or could be made) a directory this process can write into."""
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError:
        return False
    return path.is_dir() and os.access(str(path), os.W_OK | os.X_OK)


def history_path():
    return state_dir() / "switch-history.json"


def rows_path():
    return state_dir() / "switch-rows.tsv"


# why the last write_atomic failed ("" after a good one): a caller that must not
# fail silently (the top line's record, issue #2739) logs it
WRITE_ERROR = [""]


def write_atomic(path, text):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name)
        with os.fdopen(fd, "w") as out:
            out.write(text)
        os.replace(tmp, str(path))
        WRITE_ERROR[0] = ""
        return True
    except OSError as err:
        WRITE_ERROR[0] = "%s: %s" % (path, err)
        return False


# --- the history ------------------------------------------------------------------

def load():
    try:
        h = json.loads(history_path().read_text())
    except (OSError, ValueError):
        h = {}
    stack = [k for k in h.get("stack", []) if isinstance(k, str) and k]
    at = h.get("at", len(stack) - 1)
    at = at if isinstance(at, int) and 0 <= at < len(stack) else len(stack) - 1
    mru = [k for k in h.get("mru", []) if isinstance(k, str) and k]
    seen = h.get("seen") if isinstance(h.get("seen"), dict) else {}
    seen = {k: v for k, v in seen.items() if k in mru and isinstance(v, int)}
    return {"stack": stack, "at": at, "mru": mru, "seen": seen}


def save(h):
    return write_atomic(history_path(), json.dumps(h, ensure_ascii=False) + "\n")


def visit(h, key):
    """The row in view became `key`. A step through the history already stands
    on it (stack[at] == key): only the recency moves. Anything else is a new
    switch: what was ahead of `at` is dropped, as a browser does."""
    if not key:
        return h
    stack, at = h["stack"], h["at"]
    if not (0 <= at < len(stack) and stack[at] == key):
        del stack[at + 1:]
        stack.append(key)
        if len(stack) > STACK_MAX:
            del stack[:len(stack) - STACK_MAX]
        h["at"] = len(stack) - 1
    mru = [k for k in h["mru"] if k != key]
    h["mru"] = ([key] + mru)[:MRU_MAX]
    # when each was last in view (issue #2266): the switcher's 「3 分钟前」
    seen = h.get("seen") or {}
    seen[key] = int(time.time())
    h["seen"] = {k: seen[k] for k in h["mru"] if k in seen}
    return h


def step(h, live, delta):
    """⌘[ (delta -1) / ⌘] (+1): the nearest entry that way still `live` (a set,
    or a test on one key) — a closed session is stepped over; `at` moves onto it.
    "" when none is."""
    alive = live if callable(live) else live.__contains__
    i = h["at"] + delta
    while 0 <= i < len(h["stack"]):
        if alive(h["stack"][i]):
            h["at"] = i
            return h["stack"][i]
        i += delta
    return ""


# --- the rows ---------------------------------------------------------------------

def rows_text(rows):
    """The list's rows (fleet-sidebar.py's 15-field rows) as switch-rows.tsv:
    every session row, with the repo heading it sits under — key · state ·
    glyph · name · machine · group · badge, then (issue #2365, appended so a
    reader of the seven is unchanged) issue · PR · reap policy · title · repo,
    and `1` (issue #2565) on a row of the 已结束 group — absent on every other."""
    out, group, repo, ended = [], "", "", ""
    for row in rows:
        if row[0] == "hdr":
            if len(row) > 3 and row[1]:
                group, repo = row[3].strip(), row[1].strip()
                # the 已结束 heading (issue #2565) names no repo; its rows say `ended`
                ended = "1" if repo == "ended" else ""
                if ended:
                    repo = ""
            continue
        if row[0].startswith("landed:"):
            continue
        clean = [(f or "").replace("\t", " ").replace("\n", " ") for f in row] + [""] * 15
        out.append("\t".join((clean[0], clean[1], clean[2], clean[3].strip(), clean[8],
                              group, clean[5], clean[9].strip(), clean[10].strip(),
                              clean[14].strip(), clean[13].strip(), repo)
                             + ((ended,) if ended else ())))
    return "\n".join(out) + ("\n" if out else "")


def read_rows():
    try:
        return parse_rows(rows_path().read_text())
    except OSError:
        return []


def full_rows(session, timeout=8):
    """Every session — a folded subtree's too, which the list does not paint:
    the list's own producer, run once with FLEET_ROWS_UNFOLD=1. None when it
    fails; the popup then keeps the painted rows it opened with."""
    env = dict(os.environ, FLEET_ROWS_UNFOLD="1")
    if session:
        env["FLEET_SESSION"] = session
    try:
        out = subprocess.run(["bash", str(BIN / "tmux-dashboard-rows.sh"), "--sidebar"], env=env,
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    # every field split: a row's 16th on (backfill #2235, what it asks #2538)
    # must not ride into its 15th, the reap policy
    rows = [(line.split(US) + [""] * 15)[:15] for line in out.stdout.split("\n") if line.count(US) >= 4]
    return parse_rows(rows_text(rows))


def cell(text):
    """A hub cell as text: its `—` / `·` (none) as ""."""
    text = (text or "").strip()
    return "" if text in ("—", "·", "-") else text


def parse_rows(text):
    rows = []
    for line in text.splitlines():
        f = line.split("\t")
        if len(f) >= 4 and f[0]:
            f += [""] * (13 - len(f))
            rows.append({"key": f[0], "state": f[1], "glyph": f[2], "name": f[3],
                         "node": f[4].rstrip("!~"), "group": f[5], "badge": f[6],
                         "issue": cell(f[7]).lstrip("#"), "pr": cell(f[8]), "reap": f[9],
                         "title": f[10], "repo": f[11], "ended": f[12]})
    return rows


# --- scoring ----------------------------------------------------------------------

def word_start(text, i):
    if i == 0:
        return True
    a, b = text[i - 1], text[i]
    return (not a.isalnum()) or (a.islower() and b.isupper())


def fuzzy(token, text):
    """(score, positions) of the letters of `token` in order in `text`, or None.
    Greedy, preferring a word start for each letter when one is ahead."""
    low, pos, at, score, last = text.lower(), [], 0, 0, -2
    for ch in token:
        i = low.find(ch, at)
        if i < 0:
            return None
        j = i
        while j >= 0 and not word_start(text, j) and j != last + 1:
            j = low.find(ch, j + 1)
        if j >= 0:
            i = j
        score += 10 if word_start(text, i) else 0
        score += 8 if i == last + 1 else -min(i - at, 10) * 0.2
        pos.append(i)
        last, at = i, i + 1
    return score, pos


def score_token(token, row):
    name = row["name"]
    low = name.lower()
    i = low.find(token)
    if i >= 0:
        return 3000 - i + (200 if word_start(name, i) else 0), list(range(i, i + len(token)))
    issue = row.get("issue") or ""
    hay = " ".join((row["node"], STATE_WORDS.get(row["state"], row["state"]), row["group"], row["badge"],
                    "#" + issue if issue else "", row.get("title") or "", row.get("repo") or "")).lower()
    i = hay.find(token)
    if i >= 0:
        return 2000 - i, []
    hit = fuzzy(token, name)
    if hit:
        return 1000 + hit[0], hit[1]
    return None


def score(query, row):
    """(score, name positions) or None when `query` does not match `row`."""
    total, marks = 0, set()
    for token in query.lower().split():
        hit = score_token(token, row)
        if hit is None:
            return None
        total += hit[0]
        marks.update(hit[1])
    return total, sorted(marks)


def rank(rows, query, mru, current=""):
    """The rows the popup shows, best first, each with its name's marks. An
    empty query puts the rows waiting on you first (issue #2365: the bar no
    longer counts them — the list's red `!` and this order do)."""
    recency = {k: i for i, k in enumerate(mru)}
    far = len(mru) + 1
    order = {r["key"]: i for i, r in enumerate(rows)}
    if not query.strip():
        def empty_key(r):
            return (r["key"] == current, r["state"] not in WAITING, recency.get(r["key"], far), order[r["key"]])
        return [(r, []) for r in sorted(rows, key=empty_key)]
    scored = []
    for r in rows:
        hit = score(query, r)
        if hit is not None:
            scored.append((-hit[0], recency.get(r["key"], far), order[r["key"]], r, hit[1]))
    scored.sort(key=lambda t: t[:3])
    return [(t[3], t[4]) for t in scored]


# --- handing a key to the list ----------------------------------------------------

def tmux(*args):
    return subprocess.run(["tmux", *args], capture_output=True, text=True).stdout.strip()


def list_pane():
    for line in tmux("list-panes", "-a", "-F", "#{pane_id} #{@sidebar}").splitlines():
        pid, _, flag = line.partition(" ")
        if flag == "1":
            return pid
    return ""


def hand(pane, verb):
    """Append `verb` to the list's @sidebar_do and wake it (F12): the list reads
    the queue whole, so two presses in a row are two steps, never one lost."""
    if not pane:
        return False
    tmux("set-option", "-pa", "-t", pane, "@sidebar_do", verb + " ", ";",
         "send-keys", "-t", pane, "F12")
    return True


def do(verb):
    """F2 / F3 / F4 and the ⌘ keys in the one-pane layout (issue #1904): the
    verb onto the list's queue — or, for `needs`, F10, the list's own ⌃k."""
    pane = list_pane()
    if not pane:
        return False
    if verb == "needs":
        tmux("send-keys", "-t", pane, "F10")
        return True
    return hand(pane, verb)


# --- ⌘K: the switcher (issue #2266, EPIC #2259 C7) ----------------------------------

# The layouts whose `home` is the one session alone: there the switcher's last
# line opens the list beside it (共同约定 1: `multi`, remembered); in any other
# it folds the list away again (`solo`).
ONE_PANE = ("solo", "single")


def layout_now():
    """The client's layout: the server's `@fleet_layout` (fleet-shell.sh's
    layout_apply), else FLEET_CLIENT_LAYOUT, else auto."""
    return (tmux("show-options", "-gqv", "@fleet_layout") or
            os.environ.get("FLEET_CLIENT_LAYOUT", "") or "auto")


def switch_tail(layout, say=None):
    """The switcher's lines under the sessions: (action, label) — a new HOME
    session, a rule (`sep`), the layout flip, and last 退出 fleet (issue #2349:
    the client's every process here goes, the sessions run on)."""
    say = say or {}
    if layout in ONE_PANE:
        flip = ("layout:multi", say.get("switch_multi") or "打开多会话视图")
    else:
        flip = ("layout:solo", say.get("switch_solo") or "收起侧栏")
    return [("new", say.get("switch_new") or "+ 新会话"), ("sep", ""), flip,
            ("quit", say.get("switch_quit") or "退出 fleet")]


def top_lines(query, layout, say=None):
    """⌘P's pinned group (issue #2753): 「⚡ 派一件事…」 first, then + 新会话, the
    layout flip and 退出 fleet — always on top, no `>` needed — and a rule under
    them. An empty query shows them all; a query keeps the ones it names (its
    label or action holds it), with no rule when none does."""
    say = say or {}
    acts = [("dispatch", say.get("panel_dispatch") or "⚡ 派一件事…")]
    acts += [a for a in switch_tail(layout, say) if a[0] != "sep"]
    q = query.strip().casefold()
    if q:
        acts = [a for a in acts if q in a[1].casefold() or q in a[0]]
    lines = [("act", a) for a in acts]
    return lines + [("sep", "")] if lines else lines


def ago(then, now=None):
    """`then` (epoch) as a short age — 刚刚 / 5m / 3h / 2d; '' for none."""
    if not then:
        return ""
    s = max(0, int((now or time.time()) - then))
    if s < 60:
        return "<1m"
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if s >= n:
            return "%d%s" % (s // n, unit)
    return ""


def detach(argv, env=None):
    subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, cwd=os.path.expanduser("~"))


def switch_act(action, session=""):
    """Run a switcher line's action. `new`: a HOME Claude session through the
    one primitive (fleet-shell.sh home-session, issue #2264), which puts the
    stage on it. `layout:<v>`: remembered in fleet.conf's [client]
    (fleet-conf.sh set-client) and switched live (fleet-shell.sh layout).
    `quit`: 退出 fleet (fleet-shell.sh quit, issue #2349), detached — it stops
    the server this popup runs on. `route`: 连接路线… (claude-fleet#2886), the
    `fleet route --pick` popup.
    FLEET_SWITCH_NEW_CMD / FLEET_SWITCH_LAYOUT_CMD / FLEET_SWITCH_QUIT_CMD are
    the selftest's seams."""
    env = dict(os.environ)
    if session:
        env["FLEET_SHELL_SESSION"] = session
    if action == "dispatch":
        # ⌘P's 「⚡ 派一件事…」 (issue #2753) outside the popup (switch-run): the
        # ⌘T popup, through the one popup door
        seam = os.environ.get("FLEET_SWITCH_DISPATCH_CMD")
        detach(seam.split() if seam else
               ["bash", str(BIN / "dash-popup.sh"), "--no-inline", "--size", "S", "--title", "popup_dispatch", "--",
                sys.executable, str(BIN / "fleet-quick-dispatch.py")] + (["--session", session] if session else []), env)
        return True
    if action == "route":
        # ⌘P's 连接路线… (claude-fleet#2886): `fleet route --pick` in a popup
        seam = os.environ.get("FLEET_SWITCH_ROUTE_CMD")
        detach(seam.split() if seam else
               ["bash", str(BIN / "dash-popup.sh"), "--no-inline", "--size", "S", "--title", "popup_route", "--",
                sys.executable, str(BIN / "fleet-route.py"), "--pick"], env)
        return True
    if action == "quit":
        seam = os.environ.get("FLEET_SWITCH_QUIT_CMD")
        detach((seam.split() if seam else ["bash", str(BIN / "fleet-shell.sh"), "quit"])
               + ([session] if session else []), env)
        return True
    if action == "new" or action in ("new:claude", "new:codex"):
        agent = action.partition(":")[2] or "claude"
        seam = os.environ.get("FLEET_SWITCH_NEW_CMD")
        detach(seam.split() + ([agent] if action != "new" else []) if seam else
               ["bash", str(BIN / "fleet-shell.sh"), "home-session", agent], env)
        return True
    if action.startswith("layout:"):
        lay = action.split(":", 1)[1]
        if lay not in ("multi", "solo"):
            return False
        try:
            ok = subprocess.run(["bash", str(BIN / "fleet-conf.sh"), "set-client", "FLEET_CLIENT_LAYOUT",
                                 "export FLEET_CLIENT_LAYOUT=" + lay], stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=10).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            ok = False
        seam = os.environ.get("FLEET_SWITCH_LAYOUT_CMD")
        argv = seam.split() if seam else ["bash", str(BIN / "fleet-shell.sh"), "layout"]
        argv += [lay] + ([session] if session else [])
        try:
            live = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True,
                                  timeout=10).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            live = False
        return ok and live
    return False


def switch_lines(rows, query, hist, current, layout, say=None):
    """What ⌘K shows, top to bottom: [(kind, payload)] — `row` (row, marks) for
    each session ranked as ⌘P ranks them (most recent first), then the tail:
    `act` (action, label) and `sep`."""
    out = [("row", rm) for rm in rank(rows, query, hist["mru"], current)]
    return out + [("sep" if a == "sep" else "act", (a, label)) for a, label in switch_tail(layout, say)]


# --- the commands (issue #1952) ---------------------------------------------------

# THE command table: (action, group), in the order both the row menu and `>`
# show them. An action is the row menu's (fleet-ui-lang.sh `menu_keys`, which
# holds its letter and its hint); a group is one of the menu's rules — 进入 /
# 消息 / 控制 / 其它. A new row action is a line here, a line in menu_keys and its
# item in fleet-sidebar-menu.sh; nothing else lists it.
COMMANDS = (
    ("orch", "enter"),       # 进编排会话 — 「新任务」's menu / row-less (issue #2146)
    ("steward", "enter"),    # 进管家会话 — 「新任务」's menu (issue #2735)
    ("stewardpage", "enter"),  # 管家页 — the steward's page, in the person's browser
    ("open", "enter"),       # 进入 — the proxy window (a row on another machine)
    ("pr", "enter"),         # 打开 PR
    ("message", "message"),  # 发消息…
    ("answer", "message"),   # 回答
    ("rename", "control"),   # 改名 — on one line under the session
    ("pin", "control"),      # 置顶 / 取消置顶
    ("sub", "control"),      # 迁移到另一个账号
    ("stop", "control"),
    ("resume", "control"),
    ("wake", "control"),
    ("awake", "control"),
    ("reappol", "control"),  # 改回收方式…
    ("reap", "control"),     # 关闭 — asks y/n first
    ("agent", "other"),
    ("new", "other"),
    ("newto", "other"),      # 新建到 <机器>… (1–9)
    ("restore", "other"),    # 已落地 — the landed list, in place
    ("repo", "other"),
    ("clients", "other"),
    ("quit", "other"),       # 退出 fleet — the client only, the last line (issue #2349)
)


def ui(*words):
    try:
        return subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), *words], capture_output=True,
                              text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def menu_keys():
    """{letter: (action, hint)} off the menu's letter table — `1-9` (newto) is
    every digit. The hint is the line's words after its 「 — 」, the item's own
    label being its name."""
    out = {}
    for line in ui("t", "menu_keys").splitlines():
        f = line.split("\t")
        if len(f) < 3:
            continue
        what = f[2].split(" — ", 1)[-1]
        for letter in ("123456789" if f[1] == "1-9" else (f[1],)):
            out[letter] = (f[0], what)
    return out


def target_of(key):
    """A row the menu has items for — a window here (`@3`) or a row on another
    machine (`wid:<fleet>/<name>`) — else `-`, the row-less items alone."""
    return key if key.startswith("@") or (key.startswith("wid:") and "/" in key) else "-"


def menu_items(session, target):
    """(title, [(action, name, hint, command)]) — the row menu's items for
    `target`, as it would draw them (fleet-sidebar.sh menu … --print), in
    COMMANDS order. A greyed item keeps its leading `-` and has no command."""
    try:
        out = subprocess.run(["bash", str(BIN / "fleet-sidebar.sh"), "menu", session, target_of(target), "--print"],
                             stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    keys, title, items = menu_keys(), "", []
    for line in out.splitlines():
        f = line.split("\t")
        if f[0] == "title" and len(f) == 2:
            title = f[1]
        elif len(f) == 3 and f[0] in keys and f[1]:
            action, hint = keys[f[0]]
            items.append((action, f[1], hint, f[2]))
    order = {a: i for i, (a, _) in enumerate(COMMANDS)}
    items.sort(key=lambda it: order.get(it[0], len(order)))
    return title, items


def rank_cmds(items, query):
    """The items a `>` query keeps, best first: every one for an empty query (the
    table's order), else those whose name, hint or action holds each word — the
    name before the rest, earlier better — or the name's letters in order."""
    words = query.lower().split()
    if not words:
        return list(items)
    scored = []
    for i, it in enumerate(items):
        name = it[1].lstrip("-")
        total = 0
        for w in words:
            j = name.lower().find(w)
            if j >= 0:
                total += 3000 - j
                continue
            j = (it[2] + " " + it[0]).lower().find(w)
            if j >= 0:
                total += 2000 - j
                continue
            hit = fuzzy(w, name)
            if not hit:
                break
            total += 1000 + hit[0]
        else:
            scored.append((-total, i, it))
    return [t[2] for t in sorted(scored, key=lambda t: t[:2])]


def run_cmd(command, delay=0.15):
    """Run a menu item's tmux command, as display-menu would: written to a file
    and `source-file`d, detached and a beat later — the popup gone by then, so a
    confirm-before or a second menu draws on the client, not under the popup."""
    if not command:
        return False
    try:
        fd, path = tempfile.mkstemp(prefix=".fleet-cmd.", suffix=".conf")
        with os.fdopen(fd, "w") as out:
            out.write(command + "\n")
    except OSError:
        return False
    subprocess.Popen(["sh", "-c", 'sleep "$1"; tmux source-file "$2"; rm -f "$2"', "sh", str(delay), path],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    return True


def in_view():
    hist = load()
    return hist["stack"][hist["at"]] if hist["stack"] else ""


def session_of():
    """The shell's / fleet's session the popup is on (its group's name)."""
    return tmux("display-message", "-p", "#{?#{session_group},#{session_group},#{session_name}}")


# --- ⌘P: one panel of sessions AND actions (issue #2365) -----------------------------

# ⌃<letter> on the lit row runs THAT row's menu item — the very command its
# right-click menu runs (menu_items), so a key is never a second spelling of an
# action. (key, menu action, the verb a refusal names.)
ROW_KEYS = {"\x12": ("rename", "改名"), "\x18": ("reap", "回收"), "\x01": ("answer", "回答"),
            "\x05": ("reappol", "改回收方式"), "\x0f": ("pr", "打开 PR")}


def row_command(session, key, action):
    """The command of row `key`'s menu item `action`, or "" (absent or greyed)."""
    _, items = menu_items(session, key)
    for it in items:
        if it[0] == action and not it[1].startswith("-"):
            return it[3]
    return ""


def pr_url(row):
    """A row with no 「打开 PR」 item (a row on another machine): its PR's page off
    the row's repo and PR cell (`#75✓`), else its issue's — which links the PR."""
    repo = row.get("repo") or ""
    if "/" not in repo:
        return ""
    num = "".join(c for c in (row.get("pr") or "").split("✓")[0].split("✗")[0] if c.isdigit())
    if num:
        return "https://github.com/%s/pull/%s" % (repo, num)
    return "https://github.com/%s/issues/%s" % (repo, row["issue"]) if row.get("issue") else ""


def open_url(url):
    """The client's own way to a browser (fleet-remote-view.sh's opener)."""
    opener = os.environ.get("FLEET_REMOTE_OPENER")
    detach((opener.split() if opener else ["bash", str(BIN / "fleet-shell.sh"), "open-url"]) + [url])
    return True


def panel_cmds(layout, session, current, say=None):
    """`>`'s own lines, above the row's (issue #2365 — ⌘K's tail folded in):
    [(action, name, hint, command)] — a command a tmux command string, or a
    `!<action>` run by panel_run (switch_act); a greyed line's name led by `-`.
    退出 fleet is the client's own quit (#2349: every process of the client
    here goes, the sessions run on) — not prefix d's 放到后台."""
    say = say or {}
    w = lambda k, d: say.get(k) or d
    out = [("dispatch", w("panel_dispatch", "⚡ 派一件事…"), "", "!dispatch"),
           ("quit", w("panel_quit", "退出 fleet（会话在后台继续）"), "", "!quit")]
    for agent in ("claude", "codex"):
        out.append(("new:" + agent, (say.get("panel_new_fmt") or "新会话 · %s") % agent, "", "!new:" + agent))
    if layout in ONE_PANE:
        out.append(("layout:multi", w("panel_multi", "切到多会话视图"), "", "!layout:multi"))
    else:
        out.append(("layout:solo", w("panel_solo", "切到单会话视图"), "", "!layout:solo"))
    rn = row_command(session, current, "rename") if current else ""
    out.append(("rename-current", ("" if rn else "-") + w("panel_rename_current", "改名当前会话"), "", rn))
    # claude-fleet#2886: pin the route to a machine (`fleet route`); 「/route」 in
    # its name is what a narrow screen types to find it
    out.append(("route", w("panel_route", "连接路线…（/route）"), "", "!route"))
    return out


def panel_run(command, session=""):
    """↵ on a `>` line: `!<action>` → switch_act, anything else → run_cmd."""
    if command.startswith("!"):
        return switch_act(command[1:], session)
    return run_cmd(command)


# --- the popup --------------------------------------------------------------------

def char_cells(c):
    """The cells one character takes, as the terminal and tmux count them: a
    wide or full-width one 2, a mark that rides on the one before (a combining
    accent, a variation selector, a zero-width joiner) 0, anything else 1. One
    count for every width here (issue #2362): a 中文 name and the column after it
    are measured the same way, so no half cell is left behind."""
    if unicodedata.category(c) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(c) in "WF" else 1


def cells(text):
    return sum(char_cells(c) for c in text)


def clip(text, width):
    out, used = "", 0
    for c in text:
        w = char_cells(c)
        if used + w > width:
            break
        out, used = out + c, used + w
    return out


class Heal:
    """The popup paints itself whole again now and then (issue #2362). tmux draws
    a popup's own output straight onto the terminal, cell by cell; the frame and
    every cell the popup never writes are painted only when tmux redraws the
    whole popup. After a resize tmux redraws the session pane behind it, and text
    of that session was left inside the list and across the frame until the
    popup closed. So, a moment after a resize and then every HEAL seconds, the
    popup asks tmux for that whole redraw — a line feed on its last row: a popup
    narrower than the terminal cannot be scrolled in place (the client keeps the
    terminal's left/right margins off, conf/tmux-shell.conf), so tmux draws the
    popup again, frame and all — and curses repaints from a cleared screen."""
    HEAL = 1.0      # seconds between two whole repaints of an idle popup
    SETTLE = 0.3    # after a resize: the session behind has redrawn by then

    def __init__(self):
        self.due = time.monotonic() + self.HEAL

    def resized(self, screen):
        screen.clearok(True)
        self.due = time.monotonic() + self.SETTLE

    def timeout(self, busy):
        """The ms get_wch waits: 150 while a read runs, else until the next heal."""
        left = max(0, int((self.due - time.monotonic()) * 1000))
        return min(150, left) if busy else left

    def tick(self, screen):
        """Before a draw: past due ⇒ tmux redraws the whole popup, and curses
        every cell of it."""
        if time.monotonic() < self.due:
            return
        height = screen.getmaxyx()[0]
        try:
            os.write(sys.stdout.fileno(), b"\x1b[%d;1H\n" % height)
        except OSError:
            pass
        screen.clearok(True)
        self.due = time.monotonic() + self.HEAL


def words(*keys):
    """{key: text} off fleet-ui-lang.sh in ONE call (its `dump`: KEY NUL TEXT NUL)."""
    raw = ui("dump", *keys).split("\0")
    return {k: v.replace("\1", "%s") for k, v in zip(raw[0::2], raw[1::2])}


def draw_cmds(screen, query, title, items, at, width, height, say):
    """The `>` screen: the row it acts on, then one line per command — its name
    (dim when greyed) and, from a fixed column, its hint."""
    base_y = 3
    try:
        if title:
            screen.addstr(2, 0, clip("  " + (say.get("quickopen_cmd_for_fmt") or "%s") % title, width - 1),
                          curses.A_DIM)
        if items is None:
            screen.addstr(base_y, 2, clip(say.get("quickopen_cmd_loading", "…"), width - 3), curses.A_DIM)
        elif not items:
            screen.addstr(base_y, 2, clip(say.get("quickopen_cmd_none", ""), width - 3), curses.A_DIM)
    except curses.error:
        pass
    col = min(34, max(12, width // 2))
    for y, it in enumerate((items or [])[:max(0, height - base_y - 2)], base_y):
        sel = y - base_y == at
        grey = it[1].startswith("-")
        base = curses.color_pair(2) if sel else curses.A_NORMAL
        name = ("› " if sel else "  ") + it[1].lstrip("-")
        try:
            screen.addstr(y, 0, " " * (width - 1), base)
            screen.addstr(y, 0, clip(name, col - 1), base | (curses.A_DIM if grey else curses.A_BOLD if sel else 0))
            screen.addstr(y, col, clip(it[2], max(0, width - 1 - col)), base | curses.A_DIM)
        except curses.error:
            pass


def popup(screen, pane, session="", target="", switch=False):
    curses.use_default_colors()
    # raw: ⌃O / ⌃V / ⌃C reach the panel as keys (the tty's discard / lnext /
    # intr would take them) — esc and ⌃C still close it
    curses.raw()
    try:
        curses.curs_set(1)
    except curses.error:
        pass
    curses.init_pair(1, curses.COLOR_YELLOW, -1)
    curses.init_pair(2, -1, curses.COLOR_BLUE)
    curses.init_pair(3, curses.COLOR_BLUE, -1)
    screen.keypad(True)
    rows, hist = read_rows(), load()
    current = hist["stack"][hist["at"]] if hist["stack"] else ""
    query, at = "", None   # None: the default line (popup's first paint, a new query)
    # the painted rows at once; every session (folded ones too) a moment later —
    # and the screen's words with them
    fetched, say = [], {}
    layout = layout_now()
    flash = [""]   # one line under the list until the next key (a refusal)
    def fetch():
        say.update(words("quickopen_keys", "quickopen_cmd_keys", "quickopen_cmd_for_fmt", "quickopen_cmd_none",
                         "quickopen_cmd_loading", "switch_new", "switch_multi", "switch_solo", "panel_quit",
                         "panel_new_fmt", "panel_multi", "panel_solo", "panel_rename_current",
                         "panel_no_action_fmt", "panel_no_waiting", "switch_quit", "panel_dispatch"))
        fetched.append(full_rows(session))
    reader = threading.Thread(target=fetch, daemon=True)
    reader.start()
    # `>` (issue #1952): the row menu's items for the row in view (or the one
    # --target names), read once, the first time `>` is typed
    cmds, cmd_reader = [], None
    def fetch_cmds():
        sess = session or session_of()
        title, items = menu_items(sess, target or current)
        cmds.append((title, panel_cmds(layout, sess, current, say) + items))
    heal = Heal()
    while True:
        if fetched and fetched[0]:
            rows, fetched[:] = fetched[0], [None]
        # `/` is `>` too (claude-fleet#2886): a narrow screen's 「/route」 finds 连接路线…
        command = query.startswith(">") or query.startswith("/")
        if command and cmd_reader is None:
            cmd_reader = threading.Thread(target=fetch_cmds, daemon=True)
            cmd_reader.start()
        busy = reader.is_alive() or (cmd_reader is not None and cmd_reader.is_alive())
        screen.timeout(heal.timeout(busy))
        height, width = screen.getmaxyx()
        heal.tick(screen)
        screen.erase()
        if command:
            title, items = cmds[0] if cmds else ("", None)
            shown = rank_cmds(items, query[1:]) if items is not None else None
            at = max(0, min(at or 0, len(shown or []) - 1))
            draw_cmds(screen, query, title, shown, at, width, height, say)
        else:
            # ⌘K (issue #2266): the sessions, then its tail — + 新会话, a rule,
            # the layout flip — the tail always on screen, under the last row
            # ⌘P (issue #2753): the pinned group on top — 「⚡ 派一件事…」 first
            lines = (switch_lines(rows, query, hist, current, layout, say) if switch
                     else top_lines(query, layout, say) + [("row", rm) for rm in rank(rows, query, hist["mru"], current)])
            shown = [ln for ln in lines if ln[0] != "sep"]
            if at is None:
                # an empty ⌘P still lights the session before (↵ = «the one
                # before»); ↑ reaches the group above it
                at = next((i for i, ln in enumerate(shown) if ln[0] == "row"), 0) if not query else 0
            at = max(0, min(at, len(shown) - 1))
            body = height - 4
            first = next((i for i, ln in enumerate(lines) if ln[0] == "row"), len(lines))
            head = lines[:first] if not switch else []
            tail = [ln for ln in lines[len(head):] if ln[0] != "row"]
            nrows = max(0, body - len(head) - len(tail))
            drawn = head + [ln for ln in lines if ln[0] == "row"][:nrows] + tail
            sel_ln = shown[at] if shown else None
            for y, (kind, payload) in enumerate(drawn[:max(0, body)], 2):
                sel = (kind, payload) == sel_ln if sel_ln else False
                if kind != "row":
                    try:
                        if kind == "sep":
                            screen.addstr(y, 2, "─" * max(0, width - 5), curses.A_DIM)
                        else:
                            base = curses.color_pair(2) if sel else curses.A_NORMAL
                            screen.addstr(y, 0, " " * (width - 1), base)
                            screen.addstr(y, 0, clip(("› " if sel else "  ") + payload[1], width - 1),
                                          base | (curses.A_BOLD if sel else curses.color_pair(3)))
                    except curses.error:
                        pass
                    continue
                row, marks = payload
                # the row's detail (issue #2365 — the bar no longer says it):
                # 单号 · 机器 · 状态 · PR · 回收方式, right-aligned and dim
                node = " · ".join(p for p in (("#" + row["issue"]) if row.get("issue") else "", row["node"],
                                              STATE_SAY.get(row["state"], ""), row.get("pr") or "",
                                              row.get("reap") or "") if p)
                if switch:
                    when = ago(hist["seen"].get(row["key"]))
                    node = ("%s  %s" % (when, node)).strip() if when else node
                node = clip(node, max(0, width // 2))
                left = "%s %s " % ("›" if sel else " ", row["glyph"] or " ")
                name = clip(row["name"], max(0, width - cells(left) - cells(node) - 2))
                base = curses.color_pair(2) if sel else curses.A_NORMAL
                try:
                    screen.addstr(y, 0, " " * (width - 1), base)
                    screen.addstr(y, 0, left, base)
                    # each letter where curses' own cursor stands after the one
                    # before — a mark that rides on a letter stays on it
                    for i, c in enumerate(name):
                        screen.addstr(c, base | (curses.color_pair(1) | curses.A_BOLD if i in marks else 0))
                    if node:
                        screen.addstr(y, width - 1 - cells(node), node, base | curses.A_DIM)
                except curses.error:
                    pass
        # the panel's keys on its last line, always (issue #2365) — or the one
        # thing the last key could not do
        if height > 4:
            line = flash[0] or (say.get("quickopen_cmd_keys") if command else say.get("quickopen_keys")) or ""
            try:
                screen.addstr(height - 2, 0, "─" * (width - 1), curses.A_DIM)
                screen.addstr(height - 1, 1, clip(line, width - 2),
                              (curses.color_pair(1) | curses.A_BOLD) if flash[0] else curses.A_DIM)
            except curses.error:
                pass
        prompt = ("> " + query[1:].lstrip()) if command else ("› " + query)
        try:
            if command:
                screen.addstr(0, 0, ">", curses.color_pair(3) | curses.A_BOLD)
                screen.addstr(0, 2, clip(prompt[2:], width - 3), curses.A_BOLD)
            else:
                screen.addstr(0, 0, clip(prompt, width - 1), curses.A_BOLD)
            screen.addstr(1, 0, "─" * (width - 1), curses.A_DIM)
            screen.move(0, min(width - 1, cells(prompt)))
        except curses.error:
            pass
        screen.refresh()
        try:
            key = screen.get_wch()
        except curses.error:
            continue  # a timeout: look for the full rows again
        flash[0] = ""
        if key == curses.KEY_RESIZE:
            # a new size (issue #2362): the whole popup again from a cleared
            # screen, never a diff against the old geometry — and once more when
            # the session behind has redrawn
            heal.resized(screen)
            continue
        if key in ("\x1b", "\x03", "\x07") or key == curses.KEY_EXIT:
            return 0
        if key in ROW_KEYS and not command:
            # ⌃R ⌃X ⌃A ⌃E ⌃O on the lit row (issue #2365)
            action, verb = ROW_KEYS[key]
            row = shown[at][1][0] if shown and shown[at][0] == "row" else None
            if action == "answer" and (row is None or row["state"] != "needs"):
                # ⌃A off a waiting row: onto the first one that is
                waiting = [i for i, ln in enumerate(shown) if ln[0] == "row" and ln[1][0]["state"] == "needs"]
                if waiting:
                    at = waiting[0]
                else:
                    flash[0] = say.get("panel_no_waiting") or "没有在问你的会话"
                continue
            if row is None:
                curses.beep()
                continue
            cmd = row_command(session or session_of(), row["key"], action)
            if cmd:
                run_cmd(cmd)
                return 0
            if action == "pr" and pr_url(row):
                open_url(pr_url(row))
                return 0
            flash[0] = (say.get("panel_no_action_fmt") or "这一行不能%s") % verb
            continue
        if key in ("\n", "\r") or key == curses.KEY_ENTER:
            if command:
                if not shown:
                    continue
                if shown[at][1].startswith("-") or not shown[at][3]:
                    curses.beep()   # greyed: the menu would not run it either
                    continue
                if shown[at][3] == "!dispatch":
                    return "dispatch"
                panel_run(shown[at][3], session or session_of())
            elif shown and shown[at][0] == "act":
                if shown[at][1][0] == "dispatch":
                    return "dispatch"   # main() runs the ⌘T popup in this one
                switch_act(shown[at][1][0], session or session_of())
            elif shown:
                hand(pane or list_pane(), "jump=" + shown[at][1][0]["key"])
            return 0
        if key in (curses.KEY_UP, "\x10"):
            # ⌘K: ↑ on the first line wraps to the last — the layout flip
            at = (10 ** 6) if switch and at == 0 and not command else at - 1
        elif key in (curses.KEY_DOWN, "\x0e", "\t"):
            at += 1
        elif key in (curses.KEY_BACKSPACE, "\x7f", "\x08"):
            query, at = query[:-1], None
        elif key == "\x15":
            query, at = "", None
        elif isinstance(key, str) and key.isprintable():
            query, at = query + key, None


NEEDS = ("needs", "failed")
STATE_SAY = {"needs": "在问你", "failed": "失败", "working": "在干活", "looping": "循环中",
             "done": "完成", "idle": "空闲", "exited": "已退出", "sleeping": "睡着"}


def full_items(rows, query, mru, current):
    """The full-screen switcher's lines (issue #1904): [(kind, text, row, num)],
    kind `sec` (a heading) or `row`. Empty query: 在等你的 (rows waiting on you),
    最近 (the most recent first, the one in view left out, numbered 1–9 — the
    digit picks it), 全部 (every row, the list's order). `?` alone: the waiting
    rows. Anything else: the ranked matches, as ⌘P ranks them."""
    q = query.strip()
    if q and q != "?":
        return [("row", "", r, 0) for r, _ in rank(rows, q, mru, current)]
    out = []
    loud = [r for r in rows if r["state"] in NEEDS]
    if loud:
        out.append(("sec", "在等你的", None, 0))
        out += [("row", "", r, 0) for r in loud]
    if q == "?":
        return out
    by = {r["key"]: r for r in rows}
    recent = [by[k] for k in mru if k in by and k != current][:9]
    if recent:
        out.append(("sec", "最近", None, 0))
        out += [("row", "", r, i) for i, r in enumerate(recent, 1)]
    out.append(("sec", "全部", None, 0))
    out += [("row", "", r, 0) for r in rows]
    return out


def full(screen, pane, session=""):
    curses.use_default_colors()
    for n, (fg, bg) in enumerate(((curses.COLOR_YELLOW, -1), (-1, curses.COLOR_BLUE),
                                  (curses.COLOR_RED, -1), (curses.COLOR_CYAN, -1)), 1):
        curses.init_pair(n, fg, bg)
    screen.keypad(True)
    curses.mousemask(curses.ALL_MOUSE_EVENTS | getattr(curses, "REPORT_MOUSE_POSITION", 0))
    curses.mouseinterval(0)
    rows, hist = read_rows(), load()
    current = hist["stack"][hist["at"]] if hist["stack"] else ""
    query, at, top = "", 0, 0
    fetched = []
    reader = threading.Thread(target=lambda: fetched.append(full_rows(session)), daemon=True)
    reader.start()
    heal = Heal()
    while True:
        if fetched and fetched[0]:
            rows, fetched[:] = fetched[0], [None]
        screen.timeout(heal.timeout(reader.is_alive()))
        items = full_items(rows, query, hist["mru"], current)
        picks = [i for i, it in enumerate(items) if it[0] == "row"]
        at = max(0, min(at, len(picks) - 1))
        height, width = screen.getmaxyx()
        heal.tick(screen)
        # every item two lines (a row: its name, then where / what it is): a thumb's
        # height on a phone; a heading one line
        lines, spot = [], {}
        for i, (kind, text, row, num) in enumerate(items):
            if kind == "sec":
                lines.append(("sec", text, i))
                continue
            spot[i] = len(lines)
            lines += [("name", row, i, num), ("info", row, i, num)]
        body = max(1, height - 3)
        sel = picks[at] if picks else -1
        if sel in spot:
            y = spot[sel]
            top = min(top, y)
            if y + 1 >= top + body:
                top = y + 2 - body
        top = max(0, min(top, max(0, len(lines) - body)))
        screen.erase()
        try:
            screen.addstr(0, 0, clip(" ✕  切换会话  · 打字过滤 · 点一行或 ↵ 切过去 · 1–9 最近 · Esc 关", width - 1),
                          curses.A_BOLD)
            prompt = " › " + (query or "")
            screen.addstr(1, 0, clip(prompt, width - 1), curses.A_BOLD)
            if not query:
                screen.addstr(1, cells(prompt), clip("名字、m4、? …", max(0, width - 1 - cells(prompt))),
                              curses.A_DIM)
            screen.addstr(2, 0, "─" * (width - 1), curses.A_DIM)
        except curses.error:
            pass
        rowmap = {}
        for y, line in enumerate(lines[top:top + body], 3):
            kind, idx = line[0], line[2]
            rowmap[y] = idx
            try:
                if kind == "sec":
                    screen.addstr(y, 1, clip(line[1], width - 2), curses.color_pair(4) | curses.A_BOLD)
                    continue
                row, num = line[1], line[3]
                on = idx == sel
                base = curses.color_pair(2) if on else curses.A_NORMAL
                screen.addstr(y, 0, " " * (width - 1), base)
                if kind == "name":
                    lead = " %s %s " % (str(num) if num else " ", row["glyph"] or " ")
                    gl = curses.color_pair(3) if row["state"] in NEEDS else 0
                    screen.addstr(y, 0, lead, base | gl)
                    screen.addstr(y, cells(lead), clip(row["name"], max(0, width - 1 - cells(lead))),
                                  base | curses.A_BOLD)
                else:
                    info = "     " + " · ".join(x for x in (
                        "@" + row["node"] if row["node"] else "", row["group"],
                        STATE_SAY.get(row["state"], row["state"])) if x)
                    screen.addstr(y, 0, clip(info, width - 1), base | curses.A_DIM)
            except curses.error:
                pass
        try:
            screen.move(1, min(width - 1, cells(" › " + query)))
        except curses.error:
            pass
        screen.refresh()
        try:
            key = screen.get_wch()
        except curses.error:
            continue
        if key == curses.KEY_MOUSE:
            try:
                _, mx, my, _, bstate = curses.getmouse()
            except curses.error:
                continue
            if not bstate & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED | curses.BUTTON1_RELEASED):
                continue
            if my == 0 and mx < 4:
                return 0
            idx = rowmap.get(my)
            if idx is not None and items[idx][0] == "row":
                hand(pane or list_pane(), "jump=" + items[idx][2]["key"])
                return 0
            continue
        if key == curses.KEY_RESIZE:
            # a new size (issue #2362): the whole popup again from a cleared
            # screen, never a diff against the old geometry — and once more when
            # the session behind has redrawn
            heal.resized(screen)
            continue
        if key in ("\x1b", "\x03", "\x07") or key == curses.KEY_EXIT:
            return 0
        if key in ("\n", "\r") or key == curses.KEY_ENTER:
            if picks:
                hand(pane or list_pane(), "jump=" + items[picks[at]][2]["key"])
            return 0
        if isinstance(key, str) and key in "123456789" and not query:
            hit = [it for it in items if it[3] == int(key)]
            if hit:
                hand(pane or list_pane(), "jump=" + hit[0][2]["key"])
                return 0
            continue
        if key in (curses.KEY_UP, "\x10"):
            at -= 1
        elif key in (curses.KEY_DOWN, "\x0e", "\t"):
            at += 1
        elif key == curses.KEY_PPAGE:
            at -= max(1, body // 2)
        elif key == curses.KEY_NPAGE:
            at += max(1, body // 2)
        elif key in (curses.KEY_BACKSPACE, "\x7f", "\x08"):
            query, at, top = query[:-1], 0, 0
        elif key == "\x15":
            query, at, top = "", 0, 0
        elif isinstance(key, str) and key.isprintable():
            query, at, top = query + key, 0, 0


def main(argv):
    locale.setlocale(locale.LC_ALL, "")
    if argv[:1] in (["view-keys"], ["go"], ["view-rows"], ["view-order"]) or "--view" in argv:
        # the 看台's half, on the home machine (issue #3000, EPIC #2999 C2) — the
        # client never comes here, and never ships fleet_view.py
        import fleet_view
        return fleet_view.main(argv, sys.modules[__name__])
    if argv[:1] == ["do"] and len(argv) == 2:
        return 0 if do(argv[1]) else 1
    if argv[:1] == ["items"]:
        # the full switcher's lines, plain (the selftest's view of --full)
        hist = load()
        current = hist["stack"][hist["at"]] if hist["stack"] else ""
        for kind, text, row, num in full_items(read_rows(), " ".join(argv[1:]), hist["mru"], current):
            print(("# " + text) if kind == "sec" else "%s\t%s\t%s" % (num or "", row["key"], row["name"]))
        return 0
    if argv[:1] == ["rank"]:
        hist = load()
        current = hist["stack"][hist["at"]] if hist["stack"] else ""
        words = argv[1:]
        rows = read_rows()
        if words[:1] == ["--all"]:
            words, rows = words[1:], full_rows(os.environ.get("FLEET_SESSION", "")) or rows
        for row, _ in rank(rows, " ".join(words), hist["mru"], current):
            print("%s\t%s" % (row["key"], row["name"]))
        return 0
    if argv[:1] == ["switch"]:
        # ⌘K's lines, plain (the selftest's view): a session `key<TAB>name<TAB>age`,
        # the rule `--`, an action `!<action><TAB>label`
        hist = load()
        current = hist["stack"][hist["at"]] if hist["stack"] else ""
        for kind, payload in switch_lines(read_rows(), " ".join(argv[1:]), hist, current, layout_now()):
            if kind == "row":
                print("%s\t%s\t%s" % (payload[0]["key"], payload[0]["name"], ago(hist["seen"].get(payload[0]["key"]))))
            elif kind == "sep":
                print("--")
            else:
                print("!%s\t%s" % payload)
        return 0
    if argv[:1] == ["switch-run"] and len(argv) in (2, 3):
        # ↵ on a ⌘K line: a session key jumps (as ↵ on it does), else the action
        session = argv[2] if len(argv) == 3 else os.environ.get("FLEET_SESSION", "")
        if argv[1] in ("new", "quit", "dispatch", "route") or argv[1].startswith(("new:", "layout:")):
            return 0 if switch_act(argv[1], session) else 1
        return 0 if hand(list_pane(), "jump=" + argv[1]) else 1
    if argv[:1] == ["panel-cmds"]:
        # `>`'s own lines (issue #2365), plain: `action<TAB>name<TAB>command`
        sess = os.environ.get("FLEET_SESSION") or session_of()
        for action, name, _, command in panel_cmds(layout_now(), sess, in_view()):
            print("%s\t%s\t%s" % (action, name, command))
        return 0
    if argv[:1] == ["commands"]:
        for action, group in COMMANDS:
            print("%s\t%s" % (action, group))
        return 0
    if argv[:1] in (["cmds"], ["run"]):
        verb, rest = argv[0], argv[1:]
        target = in_view()
        if "--target" in rest[:-1]:
            i = rest.index("--target")
            target, rest = rest[i + 1], rest[:i] + rest[i + 2:]
        _, items = menu_items(os.environ.get("FLEET_SESSION") or session_of(), target)
        if verb == "cmds":
            for it in rank_cmds(items, " ".join(rest)):
                print("%s\t%s\t%s" % it[:3])
            return 0
        hit = [it for it in items if it[0] == (rest[0] if rest else "") and not it[1].startswith("-")]
        return 0 if hit and run_cmd(hit[0][3], 0) else 1
    if argv[:1] == ["jump"] and len(argv) == 2:
        return 0 if hand(list_pane(), "jump=" + argv[1]) else 1
    pane = argv[argv.index("--pane") + 1] if "--pane" in argv[:-1] else ""
    session = argv[argv.index("--session") + 1] if "--session" in argv[:-1] else ""
    os.environ.setdefault("ESCDELAY", "25")
    if "--full" in argv:
        return curses.wrapper(full, pane, session)
    target = argv[argv.index("--target") + 1] if "--target" in argv[:-1] else ""
    rc = curses.wrapper(popup, pane, session, target, "--switch" in argv)
    if rc == "dispatch":
        # 「⚡ 派一件事…」 (issue #2753): the ⌘T popup takes this one's place —
        # a client holds one overlay at a time — and the bar says its keys
        tmux("set", "-g", "@popup_title", "popup_dispatch")
        disp = str(BIN / "fleet-quick-dispatch.py")
        os.execv(sys.executable, [sys.executable, disp] + (["--session", session] if session else []))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
