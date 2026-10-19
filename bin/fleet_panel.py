"""State for the thin panel's full pages (#4416; plan B, T493) and its editor.

No Fleet actions live here. A popup owns one page at a time and a per-view
draft; the caller hands explicit activations to its existing action routes.
"""
import curses
import json
import os
import tempfile
from pathlib import Path


def key_of(row):
    return row.get("kind"), row.get("cmd") or row.get("target") or row.get("sec")


def clamp_top(top, count, height):
    return max(0, min(top, max(0, count - max(1, height))))


def reveal(top, at, height):
    return min(top, at) if at < top else max(top, at - max(1, height) + 1)


class Editor:
    """A logical caret independent of terminal width, with cell-based wrapping."""
    def __init__(self, text="", pos=None):
        self.text = text
        self.pos = len(text) if pos is None else max(0, min(pos, len(text)))
        self.top = 0

    def insert(self, text):
        text = text.replace("\r\n", "\n").replace("\r", "\n")
        # Same body bound as the existing draft route. Never silently truncate.
        if len(self.text) + len(text) > 4000:
            return False
        self.text = self.text[:self.pos] + text + self.text[self.pos:]
        self.pos += len(text)
        return True

    def rows(self, width, cells):
        width = max(2, width)
        out, start, used = [], 0, 0
        for i, c in enumerate(self.text):
            if c == "\n":
                out.append((start, i))
                start, used = i + 1, 0
                continue
            n = cells(c)
            if used + n > width and i > start:
                out.append((start, i))
                start, used = i, 0
            used += n
        out.append((start, len(self.text)))
        if used == width:
            out.append((len(self.text), len(self.text)))
        return out

    def cursor(self, rows, cells):
        for i, (a, b) in enumerate(rows):
            if a <= self.pos <= b and (self.pos < b or i + 1 == len(rows) or rows[i + 1][0] > b):
                return i, cells(self.text[a:self.pos])
        return len(rows) - 1, 0

    def key(self, ch, width, cells):
        if ch in ("\n", "\r", curses.KEY_ENTER):
            return self.insert("\n")
        if ch in (curses.KEY_BACKSPACE, "\x7f", "\b"):
            if self.pos:
                self.text = self.text[:self.pos - 1] + self.text[self.pos:]
                self.pos -= 1
        elif ch == curses.KEY_DC:
            self.text = self.text[:self.pos] + self.text[self.pos + 1:]
        elif ch == curses.KEY_LEFT:
            self.pos = max(0, self.pos - 1)
        elif ch == curses.KEY_RIGHT:
            self.pos = min(len(self.text), self.pos + 1)
        elif ch in (curses.KEY_HOME, "\x01"):
            self.pos = self.text.rfind("\n", 0, self.pos) + 1
        elif ch in (curses.KEY_END, "\x05"):
            end = self.text.find("\n", self.pos)
            self.pos = len(self.text) if end < 0 else end
        elif ch in (curses.KEY_UP, curses.KEY_DOWN):
            rows = self.rows(width, cells)
            r, col = self.cursor(rows, cells)
            a, b = rows[max(0, min(len(rows) - 1, r + (-1 if ch == curses.KEY_UP else 1)))]
            self.pos, used = a, 0
            while self.pos < b and used + cells(self.text[self.pos]) <= col:
                used += cells(self.text[self.pos])
                self.pos += 1
        elif ch == "\x15":
            start = self.text.rfind("\n", 0, self.pos) + 1
            self.text = self.text[:start] + self.text[self.pos:]
            self.pos = start
        elif isinstance(ch, str) and ch.isprintable():
            return self.insert(ch)
        return True


class Draft:
    """Private per-view state. Cancel, retarget and session changes keep it.

    Explicit clear or a confirmed successful *draft* opening clears text only;
    repo/agent persist. A blank-session opening never consumes the text.
    """
    def __init__(self, path):
        self.path = Path(path)
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                data = {}
        except (OSError, ValueError):
            data = {}
        text = data.get("text", "")
        self.editor = Editor(text if isinstance(text, str) and len(text) <= 4000 else "")
        pos = data.get("pos")
        if isinstance(pos, int):
            self.editor.pos = max(0, min(pos, len(self.editor.text)))
        self.editor.top = max(0, data.get("top", 0)) if isinstance(data.get("top", 0), int) else 0
        self.repo = data.get("repo") if isinstance(data.get("repo"), str) else None
        self.agent = data.get("agent") if data.get("agent") in ("claude", "codex") else None
        self.control = data.get("control", 0) if isinstance(data.get("control", 0), int) else 0
        self.control = max(0, min(self.control, 5))
        self.scroll = max(0, data.get("scroll", 0)) if isinstance(data.get("scroll", 0), int) else 0

    def save(self, bolt):
        self.repo, self.agent = bolt["repo"], bolt["agent"]
        data = dict(text=self.editor.text, pos=self.editor.pos, top=self.editor.top,
                    repo=self.repo, agent=self.agent, control=self.control, scroll=self.scroll)
        tmp = None
        try:
            self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".draft-", dir=str(self.path.parent))
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, self.path)
        except OSError:
            return False
        finally:
            if tmp and os.path.exists(tmp):
                os.unlink(tmp)
        return True


class Page:
    """One full page in the list's place (plan B, T486 v14 §2): the row it is
    about, and the list's search / open sections / selection / scroll to come back
    to — the lit row then the page's own, the last one acted on."""
    def __init__(self, row, query, opened, at, top):
        self.snapshot = query, set(opened), at, top
        self.scroll = 0
        self.follow = True
        self.retarget(row)

    def retarget(self, row):
        self.origin = key_of(row)
        self.row = row
        self.title = row.get("text", "")

    def restore(self, shown):
        query, opened, at, top = self.snapshot
        at = next((i for i, e in enumerate(shown) if key_of(e) == self.origin), min(at, max(0, len(shown) - 1)))
        return query, set(opened), at, top


def put(screen, y, x, text, width, clip, style=0):
    """Clip by display cells before curses; never address the last column."""
    h, w = screen.getmaxyx()
    if y < 0 or y >= h or x < 0 or x >= w - 1:
        return
    text = clip(text, min(width, w - 1 - x))
    try:
        screen.addstr(y, x, text, style)
    except curses.error:
        pass


class Input:
    """Bracketed paste is text, never a sequence of buttons/Enter keystrokes.

    Partial pastes survive input timeouts and resize notifications. A cancelled
    or oversized paste never dispatches anything. Ordinary Escape still steps
    back a page; unrelated following keys are put back in order.
    """
    def __init__(self):
        self.paste = None

    def read(self, screen):
        ch = screen.get_wch()
        if self.paste is not None:
            if ch == curses.KEY_RESIZE:
                return ch
            if isinstance(ch, str):
                self.paste += ch
                if self.paste.endswith("\x1b[201~"):
                    text, self.paste = self.paste[:-6], None
                    return ("paste", text)
                # Keep bounded memory while retaining the end-marker suffix.
                if len(self.paste) > 4010:
                    self.paste = self.paste[:4001] + self.paste[-6:]
            return None
        if ch != "\x1b":
            return ch
        seq = []
        screen.timeout(25)
        try:
            for _ in range(5):
                try:
                    c = screen.get_wch()
                except curses.error:
                    break
                seq.append(c)
                if not isinstance(c, str) or not "[200~".startswith("".join(seq)):
                    break
                if "".join(seq) == "[200~":
                    self.paste = ""
                    return None
        finally:
            screen.timeout(100)
        # Terminal focus events aren't user Escape or search text.
        if seq in (["[", "I"], ["[", "O"]):
            return None
        for c in reversed(seq):
            if isinstance(c, int):
                curses.ungetch(c)
            else:
                curses.unget_wch(c)
        return "\x1b"
