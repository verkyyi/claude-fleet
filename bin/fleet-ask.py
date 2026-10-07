#!/usr/bin/env python3
"""fleet-ask.py — a short question on ONE line at the bottom of the stage (issue #1950).

The task list only shows and taps now (EPIC #1949 C1): it has no input line, so
a rename, an answer, a message, the account to switch to, the restore y / r, a
repo to add — every question the list used to ask on its own last row (issue
#1620's Ask) — opens HERE instead: a pane one line high (a menu: one line per
item more) split under the session pane, with the keyboard in it. It is a real
pane, so typing, an IME commit and a bracketed paste reach it the way they
reach any program; no key table routes them and the list never takes a key.

    fleet-ask.py open --below <pane> [--wake <pane>] --spec-json <json>
    fleet-ask.py open --below <pane> --kind <k> --prompt <p> [--default <text>] [--hint <h>]
        split the pane, wait for the answer, close it. stdout: the answer as
        JSON — {"text": …} for a line, {"choice": …} as well when it has
        choices / is a menu, {"key": …} for a one-key question. Exit 0 answered,
        1 cancelled (Esc, ⌃c, an empty one-key answer, the pane closed), 2 the
        pane could not be opened. `--wake`: F11 to that pane once answered —
        the list reads its answer at once, not at its next tick.
    fleet-ask.py run <spec> <out>    the pane's own program (the line editor)

The spec: kind, prompt, text (the line's start), hint (dim, at the right),
keys (a one-key question: one of them answers, anything else cancels),
choices ([[value, label], …], Tab steps through them; `fill` fills the line
with the value, else the label takes the hint), menu ([[value, label, note,
greyed], …]: ↑↓ / Tab move, ↵ picks) and at (the highlighted item).

The pane is marked `@stage_ask 1` (fleet-sidebar.py keeps it out of the
window's content: no zoom, no heal, no list beside it) and closes itself. The
line editor below (Line, edit_of, the paste) is the list's old input line's.
"""
import codecs
import curses
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent  # preserve the selftest shadow root
_spec = importlib.util.spec_from_file_location("fleet_sidebar", BIN / "fleet-sidebar.py")
side = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(side)

# A Chinese IME turns the `.` and `?` keys into full-width 。/． and ？ (issue
# #965): a one-key question reads them as the keys they stand for.
KEY_ALIASES = {"。": ".", "．": ".", "？": "?"}

def no_discard():
    """With IXON on, ⌃s is XOFF and freezes this pane's output until a ⌃q; macOS's
    line discipline also eats ⌃o (VDISCARD) and ⌃t (VSTATUS) even in cbreak
    mode (issues #901, #1532 — the list's input line). Switch them off before
    curses saves the tty modes, so an endwin/refresh keeps them off."""
    try:
        attrs = termios.tcgetattr(0)
        attrs[0] &= ~termios.IXON
        try:
            off = os.fpathconf(0, "PC_VDISABLE")
        except (OSError, ValueError):
            off = 0  # POSIX _POSIX_VDISABLE on Linux; IXON stays off either way
        for char in ("VDISCARD", "VSTATUS"):
            if hasattr(termios, char):
                attrs[6][getattr(termios, char)] = off
        termios.tcsetattr(0, termios.TCSANOW, attrs)
    except (AttributeError, OSError, ValueError, termios.error):
        pass



def wordy(char):
    # A word is a run of letters/digits — CJK included — or `_`, as Claude's
    # prompt and readline's ⌥b/⌥f see one; spaces and punctuation separate.
    return char.isalnum() or char == "_"


class Line:
    """The question's line as a line editor (issue #1097 — the list's input line
    until #1950): the text and a cursor on it. ←→ Home End ⌥←→ ⌃a ⌃e ⌃w ⌃k ⌃u
    behave as on Claude's prompt and readline."""

    def __init__(self, text=""):
        self.set(text)

    def set(self, text):
        self.text, self.pos = text, len(text)

    def clear(self):
        self.set("")

    def insert(self, chars):
        self.text = self.text[:self.pos] + chars + self.text[self.pos:]
        self.pos += len(chars)

    def backspace(self):
        if self.pos:
            self.text = self.text[:self.pos - 1] + self.text[self.pos:]
            self.pos -= 1

    def delete(self):
        self.text = self.text[:self.pos] + self.text[self.pos + 1:]

    def left(self):
        self.pos = max(0, self.pos - 1)

    def right(self):
        self.pos = min(len(self.text), self.pos + 1)

    def home(self):
        self.pos = 0

    def end(self):
        self.pos = len(self.text)

    def _word_start(self):
        at = self.pos
        while at and not wordy(self.text[at - 1]):
            at -= 1
        while at and wordy(self.text[at - 1]):
            at -= 1
        return at

    def word_left(self):
        self.pos = self._word_start()

    def word_right(self):
        at, size = self.pos, len(self.text)
        while at < size and not wordy(self.text[at]):
            at += 1
        while at < size and wordy(self.text[at]):
            at += 1
        self.pos = at

    def kill_word(self):
        at = self._word_start()
        self.text, self.pos = self.text[:at] + self.text[self.pos:], at

    def kill_eol(self):
        self.text = self.text[:self.pos]

    def view(self, width, cursor="▏"):
        """`width` cells of the line around the cursor, `cursor` drawn at it.
        Wide (CJK) characters take two cells. Short text shows whole; a long one
        keeps the cursor in view, text after it getting at least half the room."""
        left, right = self.halves(width - len(cursor))
        return left + cursor + right

    def halves(self, room):
        """The text shown left and right of the cursor in `room` cells — what
        view() draws around its glyph; the terminal cursor (issue #1756) sits
        after the left half instead."""
        room = max(0, room)
        before, after = self.text[:self.pos], self.text[self.pos:]
        right = side.head(after, max(room // 2, room - sum(map(side.cells, before))))
        return side.tail(before, room - sum(map(side.cells, right))), right


# ⌥←/⌥→ read off the raw escape sequence (issue #1097): the pseudo-keys
# escape_word returns for them, next to curses' own codes.
WORD_LEFT, WORD_RIGHT = -2, -3


def escape_word(screen):
    """After an ESC byte: ⌥← / ⌥→ as the terminal spelled them, else the ESC.
    tmux writes M-b / M-f / M-Left / M-Right (⌃← / ⌃→ too) as ESC b, ESC f,
    ESC[1;3D … — which keypad parsing only knows when the terminfo does. A lone
    Escape has nothing behind it and stays 27; an unknown CSI sequence is
    swallowed (-1) rather than typed as `[1;2A`. ESC[200~ opens a bracketed
    paste (issue #1105; the line asks for it): its text, up to the ESC[201~
    tmux writes after the last byte, comes back as a str."""
    screen.nodelay(True)
    try:
        nxt = screen.getch()
        if nxt in (ord("b"), ord("f")):
            return WORD_LEFT if nxt == ord("b") else WORD_RIGHT
        if nxt != ord("["):
            if nxt != -1:
                curses.ungetch(nxt)
            return 27
        seq = ""
        while len(seq) < 8:
            nxt = screen.getch()
            if not 0 <= nxt < 128:
                break
            seq += chr(nxt)
            if chr(nxt).isalpha() or seq.endswith("~"):
                break
        if re.fullmatch(r"1;[3579][CD]", seq):
            return WORD_LEFT if seq.endswith("D") else WORD_RIGHT
        if seq == "200~":
            return pasted(screen)
        return -1
    finally:
        screen.nodelay(False)


PASTE_END = b"\x1b[201~"


def pasted(screen):
    """The body of a bracketed paste, read to its end marker. tmux writes the
    paste in pieces (one per key on 3.4), so wait a little between them; a paste
    with no end within a second is taken as it stands."""
    body, deadline = bytearray(), time.monotonic() + 1.0
    screen.nodelay(False)
    screen.timeout(100)
    while not body.endswith(PASTE_END) and time.monotonic() < deadline:
        nxt = screen.getch()
        if nxt == -1:
            if body:
                break
            continue
        if 0 <= nxt < 256:
            body.append(nxt)
        if len(body) > 1 << 16:
            break
    if body.endswith(PASTE_END):
        del body[-len(PASTE_END):]
    return body.decode("utf-8", "ignore")


def paste_text(text):
    """A paste as ONE line for the question: line breaks and tabs become
    spaces (a pasted paragraph must not submit at its first newline), the end
    of the paste loses its newline, other controls are dropped."""
    text = text.rstrip("\r\n")
    text = re.sub(r"[\r\n\t]+", " ", text)
    return "".join(c for c in text if typed(c))


def edit_of(key):
    """The Line method `key` runs (issue #1097), or "" when it is none: ⌃a ⌃e ⌃w
    ⌃k readline's start / end / kill-word / kill-to-end, ⌃u clears, ←→ Home End
    ⌥←→ move. (On the list's input line ←→ Home End and ⌃k had a second meaning
    on an empty line; the question's line has only the one, issue #1950.)"""
    simple = {1: "home", 5: "end", 23: "kill_word", 11: "kill_eol", 21: "clear",
              8: "backspace", 127: "backspace", curses.KEY_BACKSPACE: "backspace",
              curses.KEY_DC: "delete", curses.KEY_LEFT: "left", curses.KEY_RIGHT: "right",
              curses.KEY_HOME: "home", curses.KEY_END: "end"}
    if key in simple:
        return simple[key]
    try:
        name = curses.keyname(key) if key > 255 else b""
    except (curses.error, ValueError):
        name = b""
    if key == WORD_LEFT or name in (b"kLFT3", b"kLFT5"):
        return "word_left"
    if key == WORD_RIGHT or name in (b"kRIT3", b"kRIT5"):
        return "word_right"
    return ""


def typed(char):
    """A character the line takes: printable text, CJK included."""
    return not unicodedata.category(char).startswith("C")


# How long a question waits for its answer before it closes on its own.
WAIT_SECS = 1800
POLL = 0.05


def tmux(*args):
    return subprocess.run(["tmux", *args], text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=10)


def height_of(spec):
    """The pane's lines: the question's, plus one per menu item (at most 8)."""
    return 1 + min(8, len(spec.get("menu") or []))


def open_ask(below, spec):
    """Split a pane under `below`, wait for its answer: (rc, answer dict)."""
    handle, path = tempfile.mkstemp(prefix="fleet-ask.", suffix=".json",
                                    dir=os.environ.get("TMPDIR") or "/tmp")
    with os.fdopen(handle, "w") as out:
        json.dump(spec, out)
    result = path + ".out"
    try:
        cmd = " ".join(shlex.quote(a) for a in (
            "exec", "env", "FLEET_UI_LANG=" + os.environ.get("FLEET_UI_LANG", ""),
            "python3", str(BIN / "fleet-ask.py"), "run", path, result))
        # Marked in the SAME command list as the split: the layout hook's sync
        # must never take the new pane for the window's content.
        made = tmux("split-window", "-v", "-l", str(height_of(spec)), "-t", below,
                    "-c", os.path.expanduser("~"), "-P", "-F", "#{pane_id}", cmd, ";",
                    "set-option", "-p", "@stage_ask", "1", ";",
                    "set-option", "-p", "remain-on-exit", "off")
        pane = made.stdout.strip()
        if made.returncode != 0 or not pane.startswith("%"):
            return 2, {}
        deadline = time.monotonic() + WAIT_SECS
        while not os.path.exists(result):
            gone = tmux("display-message", "-p", "-t", pane, "#{pane_id}")
            if gone.returncode != 0 or gone.stdout.strip() != pane or time.monotonic() > deadline:
                break
            time.sleep(POLL)
        tmux("kill-pane", "-t", pane)
        # the keyboard back where it was: the session the question was asked over
        tmux("select-pane", "-t", below)
        try:
            answer = json.loads(Path(result).read_text())
        except (OSError, ValueError):
            return 1, {}
        return (0 if answer else 1), answer
    finally:
        for name in (path, result):
            try:
                os.unlink(name)
            except OSError:
                pass


class Question:
    """The pane's state: the line, the choice and the menu item in view."""

    def __init__(self, spec):
        self.spec = spec
        self.line = Line(spec.get("text", ""))
        self.hint = spec.get("hint", "")
        self.keys = spec.get("keys", "")
        self.choices = spec.get("choices") or []
        self.menu = spec.get("menu") or []
        self.at = int(spec.get("at", 0 if self.choices or self.menu else -1))
        if self.menu and self.menu[self.at][3]:
            self.move(1)

    def move(self, step):
        """↑↓ on a menu: the next item that is not greyed, wrapping round."""
        n = len(self.menu)
        i = self.at
        for _ in range(n):
            i = (i + step) % n
            if not self.menu[i][3]:
                self.at = i
                return

    def step(self, by=1):
        """Tab: the next choice — it fills the line, or names the target."""
        if not self.choices:
            return
        self.at = (self.at + by) % len(self.choices)
        value, label = self.choices[self.at][:2]
        if self.spec.get("fill"):
            self.line.set(value)
        self.hint = label

    def answer(self):
        out = {"text": self.line.text}
        if self.menu:
            out = {"choice": self.menu[self.at][0]}
        elif self.choices and self.at >= 0:
            out["choice"] = self.choices[self.at][0]
        return out


def draw(screen, q, attrs):
    height, width = screen.getmaxyx()
    screen.erase()
    span = max(0, width - 1)
    prompt = q.spec.get("prompt", "")
    items = list(enumerate(q.menu))
    room = max(0, height - 1)
    if len(items) > room:  # too short for all: the highlighted one stays in view
        first = min(max(0, q.at - room + 1), len(items) - room)
        items = items[first:first + room]
    for y, (i, (_value, label, note, greyed)) in enumerate(items):
        text = ("› " if i == q.at else "  ") + label
        if note and side.width_of(text) + 2 + side.width_of(note) <= span:
            text += " " * (span - side.width_of(text) - side.width_of(note)) + note
        attr = attrs["sel"] if i == q.at else attrs["dim"] if greyed else attrs["fg"]
        try:
            screen.hline(y, 0, " ", span, attr)
            screen.addstr(y, 0, side.clip(text, span), attr)
        except curses.error:
            pass
    y = height - 1
    lead = " " + prompt + " "
    hint = q.hint
    room = span - side.width_of(lead) - (side.width_of(hint) + 2 if hint else 0)
    if room < 8:
        hint, room = "", span - side.width_of(lead)
    caret = None
    try:
        screen.addstr(y, 0, side.clip(lead, span), attrs["prompt"])
        if not q.menu and not q.keys:
            left, right = q.line.halves(max(0, room - 1))
            screen.addstr(y, side.width_of(lead), side.clip(left + right, max(0, room)), attrs["text"])
            caret = side.width_of(lead) + side.width_of(left)
        if hint:
            screen.addstr(y, span - side.width_of(hint), hint, attrs["dim"])
    except curses.error:
        pass
    try:
        curses.curs_set(1 if caret is not None else 0)
        if caret is not None and caret < span:
            screen.move(y, caret)
    except curses.error:
        pass
    screen.refresh()


def ui(screen, spec_path, out_path):
    spec = json.loads(Path(spec_path).read_text())
    q = Question(spec)
    curses.use_default_colors()
    pal = side.palette_colors(side.palette(), curses.COLORS)
    blue = side.xterm256(side.palette().get("PAL_BLUE", "#7aa2f7")) if curses.COLORS >= 256 else curses.COLOR_BLUE
    curses.init_pair(1, pal["PAL_FG"], -1)
    curses.init_pair(2, pal["PAL_DIM"], -1)
    curses.init_pair(3, pal["PAL_FG"], pal["PAL_SEL"])
    curses.init_pair(4, blue, -1)
    dim = curses.color_pair(2) | (curses.A_DIM if pal["PAL_DIM"] == -1 else 0)
    attrs = {"fg": curses.color_pair(1), "dim": dim, "sel": curses.color_pair(3) | curses.A_BOLD,
             "prompt": curses.color_pair(4) | curses.A_BOLD, "text": curses.color_pair(1) | curses.A_BOLD}
    screen.keypad(True)
    curses.meta(True)
    os.write(1, b"\x1b[?2004h\x1b[5 q")   # bracketed paste; the editor's blinking bar
    decoder = codecs.getincrementaldecoder("utf-8")("ignore")

    def done(answer):
        tmp = out_path + ".tmp"
        Path(tmp).write_text(json.dumps(answer))
        os.replace(tmp, out_path)

    while True:
        draw(screen, q, attrs)
        key = screen.getch()
        if key == 27:
            key = escape_word(screen)
        if key == 3:          # ⌃c: a cancel, never a signal to the list
            return done({})
        if isinstance(key, str):
            if not q.keys and not q.menu:
                q.line.insert(paste_text(key))
            continue
        if q.menu:
            if key in (curses.KEY_UP, curses.KEY_BTAB):
                q.move(-1)
            elif key in (curses.KEY_DOWN, 9):
                q.move(1)
            elif key in (10, 13, curses.KEY_ENTER):
                return done(q.answer())
            elif key == 27:
                return done({})
            continue
        byte = 0 <= key < 256 and key not in (8, 9, 10, 13, 27, 127)
        chars = "".join(c for c in decoder.decode(bytes([key])) if typed(c)) if byte else ""
        if q.keys:
            if byte and not chars:
                continue  # the first byte of a multi-byte key: wait for it
            press = KEY_ALIASES.get(chars, chars)
            return done({"key": press} if press and press in q.keys else {})
        if key in (10, 13, curses.KEY_ENTER):
            return done(q.answer())
        if key == 27:
            return done({})
        if key == 9:
            q.step(1)
            continue
        if key == curses.KEY_BTAB:
            q.step(-1)
            continue
        op = edit_of(key)
        if op:
            getattr(q.line, op)()
        elif chars:
            q.line.insert(chars)
        elif not byte:
            decoder.reset()


def main():
    args = sys.argv[1:]
    if args[:1] == ["run"] and len(args) == 3:
        os.environ.setdefault("ESCDELAY", "25")
        no_discard()
        try:
            curses.wrapper(ui, args[1], args[2])
        except KeyboardInterrupt:
            pass
        return 0
    if args[:1] != ["open"]:
        print(__doc__.split("\n\n", 2)[1], file=sys.stderr)
        return 2
    below, wake, spec, i = "", "", {}, 1
    while i < len(args):
        flag, value = args[i], args[i + 1] if i + 1 < len(args) else ""
        if flag == "--below":
            below = value
        elif flag == "--wake":
            wake = value
        elif flag == "--spec-json":
            spec = json.loads(value)
        elif flag == "--kind":
            spec["kind"] = value
        elif flag == "--prompt":
            spec["prompt"] = value
        elif flag == "--default":
            spec["text"] = value
        elif flag == "--hint":
            spec["hint"] = value
        i += 2
    if not below:
        print("fleet-ask.py open: --below <pane> is required", file=sys.stderr)
        return 2
    if not (spec.get("hint") or spec.get("keys") or spec.get("menu")):
        spec["hint"] = side.tr("sidebar_ask_keys")
    rc, answer = open_ask(below, spec)
    if rc == 0:
        print(json.dumps(answer, ensure_ascii=False))
    sys.stdout.flush()
    if wake:
        # the answer is out: wake the asker, which waits for this exit (F11)
        tmux("send-keys", "-t", wake, "F11")
    return rc


if __name__ == "__main__":
    sys.exit(main())
