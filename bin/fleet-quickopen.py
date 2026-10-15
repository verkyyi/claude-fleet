#!/usr/bin/env python3
"""fleet-quickopen.py — the 看台's switcher on the home machine (issue #3000, EPIC
#2999 C2; another machine's windows, C4): its node half, bin/fleet_view.py,
says it all.

    fleet-quickopen.py --view <view> · do <verb> --view <view> · view-keys ·
    go <view> <target> · view-rows --view <view> · view-panel --view <view> · view-peers --view <view>

It began as the old client's ⌘P popup (issue #1903, EPIC #1906 C10) — the
popup, the ⌘K switcher, the full-screen switcher, `>` commands and the switch
history files went with that client (issue #3008). What is left here is the
door into fleet_view.py and the few helpers it, fleet-quick-dispatch.py and
fleet-session-cli.py share: the cell count (`cells` / `clip` — a 中文 name and
the column after it measured the same way, issue #2362), the selected row's
ground (`sel_attr`, issue #3416), the popup's whole repaint (`Heal`), the switch
history's two steps (`visit` / `step`), an atomic write, and every session's
rows off a fleet machine's own producer (`full_rows` / `parse_rows`).
"""
import time
T_START = time.time()   # the 看台's ⌘P clock starts here where /proc cannot say (#3551)
import curses
import locale
import os
import subprocess
import sys
import tempfile
import unicodedata

from pathlib import Path

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))

US = "\x1f"
STACK_MAX = 50
MRU_MAX = 100


# why the last write_atomic failed ("" after a good one): a caller that must not
# fail silently logs it
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


# --- the history (the 看台 keeps its own file: fleet_view.py history_file) ---------


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
    """The list's rows (the producer’s session rows) as switch-rows.tsv:
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


def full_rows(session, timeout=8):
    """Every session — a folded subtree's too, which the list does not paint:
    the list's own producer, run once with FLEET_ROWS_UNFOLD=1. None when it
    fails; the popup then keeps the painted rows it opened with."""
    env = dict(os.environ, FLEET_ROWS_UNFOLD="1")
    if session:
        env["FLEET_SESSION"] = session
    try:
        # errors="replace" (issue #3444): a cell cut mid-character must not take
        # the whole list down with a UnicodeDecodeError (`fleet ls` died on one)
        out = subprocess.run(["bash", str(BIN / "tmux-dashboard-rows.sh"), "--rows"], env=env,
                             stdin=subprocess.DEVNULL, capture_output=True, encoding="utf-8",
                             errors="replace", timeout=timeout)
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
                         "node": f[4].rstrip("!~"), "lost": f[4].endswith("!"),
                         "group": f[5], "badge": f[6],
                         "issue": cell(f[7]).lstrip("#"), "pr": cell(f[8]), "reap": f[9],
                         "title": f[10], "repo": f[11], "ended": f[12]})
    return rows


# --- drawing (the 看台's popup and the ⌘T one) ----------------------------------


def tmux(*args):
    return subprocess.run(["tmux", *args], capture_output=True, text=True).stdout.strip()


def char_cells(c):
    """The cells one character takes, as the terminal and tmux count them: a
    wide or full-width one 2, a mark that rides on the one before (a combining
    accent, a variation selector, a zero-width joiner) 0, anything else 1. One
    count for every width here (issue #2362): a 中文 name and the column after it
    are measured the same way, so no half cell is left behind."""
    if unicodedata.category(c) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(c) in "WF" else 1


def rich_color(colors=None, env=None):
    """Does this terminal say it draws a coloured row ground faithfully (issue
    #3416)? Only a truecolour terminal (`COLORTERM` truecolor / 24bit) with 256+
    colours does: an xterm-256color that says nothing — iPhone Termius — mapped
    the ANSI blue ground onto its own background, so the selected row vanished."""
    env = os.environ if env is None else env
    if colors is None:
        colors = getattr(curses, "COLORS", 0)
    return colors >= 256 and env.get("COLORTERM", "").lower() in ("truecolor", "24bit")


def sel_attr(pair, colors=None, env=None):
    """The selected row's ground: the colour pair where `rich_color`, else reverse
    video — swaps the terminal's own fg / bg, so it shows under any scheme. Always
    bold, beside the `›` every list draws (a mark that needs no colour). Text on
    the selected row is never A_DIM: a dimmed fg on the swapped ground is the
    «can't read the row» the issue was about."""
    if rich_color(colors, env):
        return curses.color_pair(pair) | curses.A_BOLD
    return curses.A_REVERSE | curses.A_BOLD


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
    terminal's left/right margins off, conf/tmux-view.conf), so tmux draws the
    popup again, frame and all — and curses repaints from a cleared screen."""
    # The thin view freezes the pane behind its popup (#3058), so it needs only
    # the resize repair. Repeating the scroll/clear there flashes the frame even
    # when nothing changed (#4410). Keep periodic repair for the older callers
    # whose background is not frozen.
    HEAL = 1.0      # seconds between two whole repaints of an unfrozen popup
    SETTLE = 0.3    # after a resize: the session behind has redrawn by then

    def __init__(self, periodic=True):
        self.periodic = periodic
        self.due = time.monotonic() + self.HEAL if periodic else None

    def resized(self, screen):
        screen.clearok(True)
        self.due = time.monotonic() + self.SETTLE

    def timeout(self, busy):
        """Bound the input wait by a pending repair, without scheduling one."""
        left = 1000 if self.due is None else max(0, int((self.due - time.monotonic()) * 1000))
        return min(150, left) if busy else left

    def tick(self, screen):
        """Before a draw: past due ⇒ tmux redraws the whole popup, and curses
        every cell of it."""
        if self.due is None or time.monotonic() < self.due:
            return
        height = screen.getmaxyx()[0]
        try:
            os.write(sys.stdout.fileno(), b"\x1b[%d;1H\n" % height)
        except OSError:
            pass
        screen.clearok(True)
        self.due = time.monotonic() + self.HEAL if self.periodic else None


def set_locale():
    """The environment's locale, else C.UTF-8, else C (issue #3514): a LANG that
    names a locale this machine lacks (en_US.UTF-8 on a slim Linux image) made
    setlocale raise — the 看台's key tables were never built and ⌘P / ⚡ died at
    start, silently, on every thin client of the login."""
    for name in ("", "C.UTF-8", "C.utf8", "C"):
        try:
            return locale.setlocale(locale.LC_ALL, name)
        except locale.Error:
            continue
    return ""


def main(argv):
    set_locale()
    if argv[:1] in (["view-keys"], ["go"], ["view-rows"], ["view-order"]) or "--view" in argv:
        # the 看台's half, on the home machine (issue #3000, EPIC #2999 C2)
        import fleet_view
        return fleet_view.main(argv, sys.modules[__name__])
    print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
