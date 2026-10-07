#!/usr/bin/env python3
"""fleet-quickopen.py — ⌘P: type a few letters, ↵, and the client is on that
session (issue #1903, EPIC #1906 C10) — and the switch history ⌘[ / ⌘] walk.

    fleet-quickopen.py [--session S] [--pane <list pane>]
                                              the popup (conf/tmux-shell.conf's
                                              ⌘P / prefix / open it through the
                                              one popup door)
    fleet-quickopen.py rank [--all] [<query>] the ranked rows, one per line
                                              (`key<TAB>name`) — the selftest's view;
                                              --all reads every session as the popup does
    fleet-quickopen.py jump <key>             hand <key> to the list, as ↵ does
    fleet-quickopen.py --full [--session S]   the FULL-SCREEN switcher (issue #1904:
                                              F1 / a tap on the top line's title at
                                              phone width): 在等你的 · 最近 (1–9) ·
                                              全部, two-line rows big enough for a
                                              thumb; type to filter, tap or ↵ to go
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
                         it like a browser's back/forward) and `mru` (most recent
                         first — the order an empty ⌘P shows)

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
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent

US = "\x1f"
STACK_MAX = 50
MRU_MAX = 100
STATE_WORDS = {"needs": "needs ask 在问你", "failed": "failed 失败", "working": "working 在干活",
               "idle": "idle 空闲", "done": "done 完成", "landed": "landed"}


def state_dir():
    env = os.environ.get("FLEET_SWITCH_STATE")
    if env:
        return Path(env)
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "claude-fleet"


def history_path():
    return state_dir() / "switch-history.json"


def rows_path():
    return state_dir() / "switch-rows.tsv"


def write_atomic(path, text):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name)
        with os.fdopen(fd, "w") as out:
            out.write(text)
        os.replace(tmp, str(path))
        return True
    except OSError:
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
    return {"stack": stack, "at": at, "mru": mru}


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
    """The list's rows (fleet-sidebar.py's 13-field rows) as switch-rows.tsv:
    every session row, with the repo heading it sits under."""
    out, group = [], ""
    for row in rows:
        if row[0] == "hdr":
            if len(row) > 3 and row[1]:
                group = row[3].strip()
            continue
        if row[0].startswith("landed:"):
            continue
        clean = [(f or "").replace("\t", " ").replace("\n", " ") for f in row]
        out.append("\t".join((clean[0], clean[1], clean[2], clean[3].strip(), clean[8],
                              group, clean[5])))
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
    rows = [(line.split(US, 12) + [""] * 13)[:13] for line in out.stdout.split("\n") if line.count(US) >= 4]
    return parse_rows(rows_text(rows))


def parse_rows(text):
    rows = []
    for line in text.splitlines():
        f = line.split("\t")
        if len(f) >= 4 and f[0]:
            f += [""] * (7 - len(f))
            rows.append({"key": f[0], "state": f[1], "glyph": f[2], "name": f[3],
                         "node": f[4].rstrip("!~"), "group": f[5], "badge": f[6]})
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
    hay = " ".join((row["node"], STATE_WORDS.get(row["state"], row["state"]), row["group"], row["badge"])).lower()
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
    """The rows the popup shows, best first, each with its name's marks."""
    recency = {k: i for i, k in enumerate(mru)}
    far = len(mru) + 1
    order = {r["key"]: i for i, r in enumerate(rows)}
    if not query.strip():
        def empty_key(r):
            return (r["key"] == current, recency.get(r["key"], far), order[r["key"]])
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


# --- the commands (issue #1952) ---------------------------------------------------

# THE command table: (action, group), in the order both the row menu and `>`
# show them. An action is the row menu's (fleet-ui-lang.sh `menu_keys`, which
# holds its letter and its hint); a group is one of the menu's rules — 进入 /
# 消息 / 控制 / 其它. A new row action is a line here, a line in menu_keys and its
# item in fleet-sidebar-menu.sh; nothing else lists it.
COMMANDS = (
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
    ("info", "other"),       # 详情列 — issue · PR · ctx%
    ("repo", "other"),
    ("clients", "other"),
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


# --- the popup --------------------------------------------------------------------

def cells(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def clip(text, width):
    out, used = "", 0
    for c in text:
        w = 2 if unicodedata.east_asian_width(c) in "WF" else 1
        if used + w > width:
            break
        out, used = out + c, used + w
    return out


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
    for y, it in enumerate((items or [])[:max(0, height - base_y)], base_y):
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


def popup(screen, pane, session="", target=""):
    curses.use_default_colors()
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
    query, at = "", 0
    # the painted rows at once; every session (folded ones too) a moment later —
    # and the screen's words with them
    fetched, say = [], {}
    def fetch():
        say.update(words("quickopen_cmd_hint", "quickopen_cmd_for_fmt", "quickopen_cmd_none",
                         "quickopen_cmd_loading"))
        fetched.append(full_rows(session))
    reader = threading.Thread(target=fetch, daemon=True)
    reader.start()
    # `>` (issue #1952): the row menu's items for the row in view (or the one
    # --target names), read once, the first time `>` is typed
    cmds, cmd_reader = [], None
    def fetch_cmds():
        cmds.append(menu_items(session or session_of(), target or current))
    while True:
        if fetched and fetched[0]:
            rows, fetched[:] = fetched[0], [None]
        command = query.startswith(">")
        if command and cmd_reader is None:
            cmd_reader = threading.Thread(target=fetch_cmds, daemon=True)
            cmd_reader.start()
        busy = reader.is_alive() or (cmd_reader is not None and cmd_reader.is_alive())
        screen.timeout(150 if busy else -1)
        height, width = screen.getmaxyx()
        screen.erase()
        if command:
            title, items = cmds[0] if cmds else ("", None)
            shown = rank_cmds(items, query[1:]) if items is not None else None
            at = max(0, min(at, len(shown or []) - 1))
            draw_cmds(screen, query, title, shown, at, width, height, say)
        else:
            shown = rank(rows, query, hist["mru"], current)
            at = max(0, min(at, len(shown) - 1))
            body = height - 2 - (2 if say.get("quickopen_cmd_hint") else 0)
            for y, (row, marks) in enumerate(shown[:max(0, body)], 2):
                sel = y - 2 == at
                node = "@" + row["node"] if row["node"] else ""
                left = "%s %s " % ("›" if sel else " ", row["glyph"] or " ")
                name = clip(row["name"], max(0, width - cells(left) - cells(node) - 2))
                base = curses.color_pair(2) if sel else curses.A_NORMAL
                try:
                    screen.addstr(y, 0, " " * (width - 1), base)
                    screen.addstr(y, 0, left, base)
                    x = cells(left)
                    for i, c in enumerate(name):
                        screen.addstr(y, x, c, base | (curses.color_pair(1) | curses.A_BOLD if i in marks else 0))
                        x += cells(c)
                    if node:
                        screen.addstr(y, width - 1 - cells(node), node, base | curses.A_DIM)
                except curses.error:
                    pass
            if say.get("quickopen_cmd_hint") and height > 4:
                try:
                    screen.addstr(height - 1, 2, clip(say["quickopen_cmd_hint"], width - 3), curses.A_DIM)
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
        if key in ("\x1b", "\x03", "\x07") or key == curses.KEY_EXIT:
            return 0
        if key in ("\n", "\r") or key == curses.KEY_ENTER:
            if command:
                if not shown:
                    continue
                if shown[at][1].startswith("-") or not shown[at][3]:
                    curses.beep()   # greyed: the menu would not run it either
                    continue
                run_cmd(shown[at][3])
            elif shown:
                hand(pane or list_pane(), "jump=" + shown[at][0]["key"])
            return 0
        if key in (curses.KEY_UP, "\x10"):
            at -= 1
        elif key in (curses.KEY_DOWN, "\x0e", "\t"):
            at += 1
        elif key in (curses.KEY_BACKSPACE, "\x7f", "\x08"):
            query, at = query[:-1], 0
        elif key == "\x15":
            query, at = "", 0
        elif isinstance(key, str) and key.isprintable():
            query, at = query + key, 0


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
    while True:
        if fetched and fetched[0]:
            rows, fetched[:] = fetched[0], [None]
        screen.timeout(150 if reader.is_alive() else -1)
        items = full_items(rows, query, hist["mru"], current)
        picks = [i for i, it in enumerate(items) if it[0] == "row"]
        at = max(0, min(at, len(picks) - 1))
        height, width = screen.getmaxyx()
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
    return curses.wrapper(popup, pane, session, target)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
