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


def popup(screen, pane, session=""):
    curses.use_default_colors()
    try:
        curses.curs_set(1)
    except curses.error:
        pass
    curses.init_pair(1, curses.COLOR_YELLOW, -1)
    curses.init_pair(2, -1, curses.COLOR_BLUE)
    screen.keypad(True)
    rows, hist = read_rows(), load()
    current = hist["stack"][hist["at"]] if hist["stack"] else ""
    query, at = "", 0
    # the painted rows at once; every session (folded ones too) a moment later
    fetched = []
    reader = threading.Thread(target=lambda: fetched.append(full_rows(session)), daemon=True)
    reader.start()
    while True:
        if fetched and fetched[0]:
            rows, fetched[:] = fetched[0], [None]
        screen.timeout(150 if reader.is_alive() else -1)
        shown = rank(rows, query, hist["mru"], current)
        at = max(0, min(at, len(shown) - 1))
        height, width = screen.getmaxyx()
        screen.erase()
        for y, (row, marks) in enumerate(shown[:max(0, height - 2)], 2):
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
        prompt = "› " + query
        try:
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
            if shown:
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


def main(argv):
    locale.setlocale(locale.LC_ALL, "")
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
    if argv[:1] == ["jump"] and len(argv) == 2:
        return 0 if hand(list_pane(), "jump=" + argv[1]) else 1
    pane = argv[argv.index("--pane") + 1] if "--pane" in argv[:-1] else ""
    session = argv[argv.index("--session") + 1] if "--session" in argv[:-1] else ""
    os.environ.setdefault("ESCDELAY", "25")
    return curses.wrapper(popup, pane, session)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
