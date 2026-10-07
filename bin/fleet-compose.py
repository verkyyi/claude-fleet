#!/usr/bin/env python3
"""fleet-compose.py — ⌘N: the writing area on the right (issue #1953, EPIC #1949 C4).

    fleet-compose.py [--session S]        the writing area (curses) — the pane of
                                          the client stage's `@fleet_role portal`
                                          window (fleet-shell.sh portal opens it:
                                          ⌘N / prefix c / a tap on 「新任务」)
    fleet-compose.py --send <payload.json> [--repo R] [--node N] [--reap P]
                                          the ONE way out: the payload a ↵ wrote,
                                          to the machine that opens it —
                                          fleet-client-place.sh <repo> new (an
                                          issue, filed there, then its worker) or
                                          <repo> scratch (「记成 issue」 off: a
                                          scratch session). Prints the place's one
                                          line and returns its code. Later members
                                          (C6 repo choice, C7 the orchestrator)
                                          add their routes here
    fleet-compose.py payload <text-file> [--no-issue]
                                          the payload a ↵ on that text would write
                                          (title · body · attachments), as JSON —
                                          the selftest's view

The writing area: several lines (⇧↵ — the `fleet` iTerm2 profile sends it as
0x0a, ⌃j — or ⌥↵ makes a new line; ↵ sends), a file dropped on the window (its
path pasted) is an attachment, Tab walks to the 「记成 issue」 switch (space
flips it: off = a scratch session instead of an issue), esc goes back to the
session that was in view. The draft is on disk the whole time —
$XDG_STATE_HOME/claude-fleet/compose-draft (FLEET_SWITCH_STATE overrides the
directory, as for the switch history), so leaving and coming back, or the client
restarting, loses nothing.

↵ writes the payload (compose-send.json beside the draft: the first line is the
title, the whole text the body, every attachment's path listed under it) and
hands the task list `compose` on its @sidebar_do queue (F12 wakes it, exactly as
⌘P's pick does): the list knows the rows, so it resolves 「自动」 — the repo of
the session that was in view, else the only one — draws 「开工中…」 under the
「新任务」 row at once, runs --send in the background and switches to the new
session's row when it appears. No list on screen (an older client): --send runs
from here. Nothing on the way spends a token: the issue is filed by
fleet-issue-file.sh on the machine, the worker opened by its spawn.
"""
import curses
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent
MAX_TITLE = 256       # GitHub's bound — the hub's checkIssueTitle
MAX_BODY = 4000       # the hub's checkText — what a write may carry
MAX_SCRATCH = 64      # the hub's checkScratchName
PORTAL = "new"        # the portal window's @remote: the list's row key for it
SAVE_EVERY = 1.0      # the draft is written at most this often while typing


def state_dir():
    env = os.environ.get("FLEET_SWITCH_STATE")
    if env:
        return Path(env)
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return Path(base) / "claude-fleet"


def draft_path():
    return state_dir() / "compose-draft"


def send_path():
    return state_dir() / "compose-send.json"


def write_atomic(path, text):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name)
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(tmp, str(path))
        return True
    except OSError:
        return False


def load_text():
    try:
        out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "compose_"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = b""
    parts = out.decode("utf-8", "replace").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


TEXT = {}


def tr(key, *args):
    text = TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


# --- the payload ----------------------------------------------------------------

# A path a drop pastes: absolute or ~/, a backslash before each space (iTerm2's
# own quoting), or wrapped in quotes. Only one that exists here counts.
PATH_RE = re.compile(r"""'((?:~|/)[^'\n]+)'|"((?:~|/)[^"\n]+)"|((?:~|/)(?:\\.|[^\s\\])+)""")


def attachments(text):
    """The files a drop put in the text, in order, each once — the paths as they
    exist on this computer."""
    out = []
    for m in PATH_RE.finditer(text):
        raw = m.group(1) or m.group(2) or re.sub(r"\\(.)", r"\1", m.group(3))
        path = os.path.expanduser(raw.rstrip(".,;:，。；：)）"))
        if len(path) > 1 and os.path.isfile(path) and path not in out:
            out.append(path)
    return out


def clean(text):
    """No control character but newline and tab; no `<!--` (the hub refuses a
    marker it did not stamp itself, so a pasted one is defused, not rejected)."""
    text = "".join(c for c in text if c in "\n\t" or unicodedata.category(c) != "Cc")
    return text.replace("<!--", "<! --")


def payload(text, issue=True, prev="", repo=""):
    """What a ↵ sends: the first line is the title, the whole text the body, the
    attachments listed under it. {} when there is nothing to send."""
    text = clean(text).strip("\n")
    lines = [l.strip() for l in text.split("\n")]
    title = next((l for l in lines if l), "")
    if not title:
        return {}
    files = attachments(text)
    body = text
    if files:
        body += "\n\n" + tr("compose_attach") + ":\n" + "\n".join("- " + f for f in files)
    if len(body) > MAX_BODY:
        body = body[:MAX_BODY - 1] + "…"
    title = " ".join(title.split())
    if len(title) > MAX_TITLE:
        title = title[:MAX_TITLE - 1] + "…"
    return {"title": title, "body": body, "issue": bool(issue), "attachments": files,
            "repo": repo, "prev": prev, "at": int(time.time())}


def scratch_name(title):
    name = " ".join(title.replace("#", " ").split())
    return name[:MAX_SCRATCH].strip()


def hub_repos():
    """The repos the hub says this person's machines host (the sidebar's
    hub_repos cache) — None when it was never read."""
    g = os.environ.get("FLEET_STATUS_G") or os.path.join(os.environ.get("TMPDIR") or "/tmp",
                                                          ".claude-dash", "global")
    try:
        with open(os.path.join(g, "hub_repos"), encoding="utf-8") as f:
            return [r for r in f.read().splitlines() if r and not r.startswith("#") and "/" in r]
    except OSError:
        return None


def send(path, repo="", node="auto", reap=""):
    """The way out (`--send`): the payload to fleet-client-place.sh. Prints its
    line, returns its code. 2 = nothing to send / no repo to send it to."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("fleet-compose: cannot read %s: %s" % (path, error), file=sys.stderr)
        return 2
    title = data.get("title") or ""
    if not title:
        print("fleet-compose: the payload has no title", file=sys.stderr)
        return 2
    repo = repo or data.get("repo") or ""
    if not repo:
        repos = hub_repos() or []
        if len(repos) == 1:
            repo = repos[0]
    if "/" not in repo:
        print("fleet-compose: name the repo (owner/name) — 「自动」 has none to go on", file=sys.stderr)
        return 2
    args = ["bash", str(BIN / "fleet-client-place.sh"), repo]
    bodyf = ""
    if data.get("issue", True):
        fd, bodyf = tempfile.mkstemp(prefix="fleet-compose-body.", dir=str(Path(path).parent))
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            out.write(data.get("body") or "")
        args += ["new", "--title", title, "--body-file", bodyf]
    else:
        args += ["scratch"]
        name = scratch_name(title)
        if name:
            args += ["--name", name]
    args += ["--node", node or "auto"]
    if reap:
        args += ["--reap", reap]
    try:
        out = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
    finally:
        if bodyf:
            try:
                os.unlink(bodyf)
            except OSError:
                pass
    sys.stdout.write(out.stdout)
    return out.returncode


# --- where the writing area came from ----------------------------------------------

def switch_lib():
    import importlib.util
    spec = importlib.util.spec_from_file_location("fleet_quickopen", str(BIN / "fleet-quickopen.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def previous():
    """(key, repo heading) of the session that was in view before this one —
    the history's most recent row that is not the portal."""
    try:
        lib = switch_lib()
        mru = [k for k in lib.load()["mru"] if k != PORTAL]
        rows = {r["key"]: r for r in lib.read_rows()}
    except Exception:
        return "", ""
    key = mru[0] if mru else ""
    group = (rows.get(key) or {}).get("group", "")
    return key, re.sub(r"\s*\(\d+\)$", "", group).strip()


class Shell:
    """The client's own tmux server (`-L <session>`, the list's), seen from the
    stage: FLEET_COMPOSE_SHELL_SOCK names a socket path instead (the selftest)."""

    def __init__(self, session):
        sock = os.environ.get("FLEET_COMPOSE_SHELL_SOCK", "")
        self.cmd = ["tmux", "-S", sock] if sock else (["tmux", "-L", session] if session else [])

    def run(self, *args):
        if not self.cmd:
            return ""
        try:
            return subprocess.run(self.cmd + list(args), stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""

    def list_pane(self):
        for line in self.run("list-panes", "-a", "-F", "#{pane_id} #{@sidebar}").splitlines():
            pid, _, flag = line.partition(" ")
            if flag == "1":
                return pid
        return ""

    def hand(self, verb):
        pane = self.list_pane()
        if not pane:
            return False
        self.run("set-option", "-pa", "-t", pane, "@sidebar_do", verb + " ", ";", "send-keys", "-t", pane, "F12")
        return True


def go_back(shell, prev):
    """esc: the session that was in view — the list's own jump (`jump=<key>`),
    else the stage's window before this one."""
    if prev and prev.startswith(("@", "wid:")) and shell.hand("jump=" + prev):
        return
    subprocess.run(["tmux", "last-window"], stdin=subprocess.DEVNULL, capture_output=True)


# --- the text --------------------------------------------------------------------

def cells(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 0 if unicodedata.combining(c) else 1
               for c in text)


def wrap(line, width):
    """A logical line as screen rows of at most `width` cells: [(start, end)]."""
    out, start, used = [], 0, 0
    for i, c in enumerate(line):
        w = cells(c)
        if used + w > width and i > start:
            out.append((start, i))
            start, used = i, 0
        used += w
    out.append((start, len(line)))
    return out


class Editor:
    def __init__(self, text=""):
        self.lines = text.split("\n") if text else [""]
        self.row = len(self.lines) - 1
        self.col = len(self.lines[self.row])

    def text(self):
        return "\n".join(self.lines)

    def clear(self):
        self.lines, self.row, self.col = [""], 0, 0

    def insert(self, s):
        for part in re.split(r"(\n)", s.replace("\r\n", "\n").replace("\r", "\n")):
            if part == "\n":
                self.newline()
            elif part:
                line = self.lines[self.row]
                self.lines[self.row] = line[:self.col] + part + line[self.col:]
                self.col += len(part)

    def newline(self):
        line = self.lines[self.row]
        self.lines[self.row:self.row + 1] = [line[:self.col], line[self.col:]]
        self.row, self.col = self.row + 1, 0

    def backspace(self):
        if self.col:
            line = self.lines[self.row]
            self.lines[self.row] = line[:self.col - 1] + line[self.col:]
            self.col -= 1
        elif self.row:
            prev = self.lines[self.row - 1]
            self.lines[self.row - 1:self.row + 1] = [prev + self.lines[self.row]]
            self.row, self.col = self.row - 1, len(prev)

    def delete(self):
        line = self.lines[self.row]
        if self.col < len(line):
            self.lines[self.row] = line[:self.col] + line[self.col + 1:]
        elif self.row + 1 < len(self.lines):
            self.lines[self.row:self.row + 2] = [line + self.lines[self.row + 1]]

    def move(self, dr=0, dc=0):
        if dc:
            self.col += dc
            if self.col < 0 and self.row:
                self.row -= 1
                self.col = len(self.lines[self.row])
            elif self.col > len(self.lines[self.row]) and self.row + 1 < len(self.lines):
                self.row, self.col = self.row + 1, 0
            self.col = max(0, min(self.col, len(self.lines[self.row])))
        if dr:
            self.row = max(0, min(len(self.lines) - 1, self.row + dr))
            self.col = min(self.col, len(self.lines[self.row]))

    def kill_bol(self):
        self.lines[self.row] = self.lines[self.row][self.col:]
        self.col = 0

    def kill_eol(self):
        self.lines[self.row] = self.lines[self.row][:self.col]

    def kill_word(self):
        line = self.lines[self.row]
        i = self.col
        while i and line[i - 1] == " ":
            i -= 1
        while i and line[i - 1] != " ":
            i -= 1
        self.lines[self.row] = line[:i] + line[self.col:]
        self.col = i


# --- the screen ------------------------------------------------------------------

PAIR_BOX, PAIR_DIM, PAIR_ON, PAIR_GO, PAIR_TOAST = 1, 2, 3, 4, 5


def read_key(screen):
    """One key as ("text", s) | ("key", name): a CSI the terminal sent (⇧↵ as
    CSI-u, bracketed paste's markers) or ⌥↵ (ESC CR) read here, curses' own names
    for the rest. ("none", "") when nothing came."""
    k = screen.get_wch() if hasattr(screen, "get_wch") else screen.getch()
    if isinstance(k, int):
        if k == -1:
            return "none", ""
        names = {curses.KEY_BACKSPACE: "bs", curses.KEY_DC: "del", curses.KEY_LEFT: "left",
                 curses.KEY_RIGHT: "right", curses.KEY_UP: "up", curses.KEY_DOWN: "down",
                 curses.KEY_HOME: "home", curses.KEY_END: "end", curses.KEY_RESIZE: "resize",
                 curses.KEY_BTAB: "btab", curses.KEY_ENTER: "enter"}
        return "key", names.get(k, "")
    if k == "\x1b":
        screen.nodelay(True)
        seq = ""
        try:
            while len(seq) < 16:
                try:
                    c = screen.get_wch()
                except curses.error:
                    break
                if isinstance(c, int):
                    break
                seq += c
                if seq in ("\r", "\n") or (seq[:1] == "[" and len(seq) > 1 and seq[-1].isalpha() or seq[-1:] == "~"):
                    break
        finally:
            screen.nodelay(False)
        if seq in ("\r", "\n", "[13;2u", "[27;2;13~"):
            return "key", "newline"
        if seq == "[200~":
            return "key", "paste_on"
        if seq == "[201~":
            return "key", "paste_off"
        if seq == "":
            return "key", "esc"
        return "key", ""
    codes = {"\r": "enter", "\n": "newline", "\t": "tab", "\x7f": "bs", "\x08": "bs", "\x01": "home",
             "\x05": "end", "\x15": "kill_bol", "\x0b": "kill_eol", "\x17": "kill_word", "\x04": "del"}
    if k in codes:
        return "key", codes[k]
    if unicodedata.category(k) == "Cc":
        return "key", ""
    return "text", k


def ui(screen, session):
    os.write(1, b"\x1b[?2004h")   # bracketed paste: a drop is one insert, never a send
    try:
        curses.curs_set(1)
    except curses.error:
        pass
    curses.use_default_colors()
    curses.raw()
    curses.nonl()               # ↵ is CR (send), ⌃j / ⇧↵ is LF (a new line)
    for number, fg in ((PAIR_BOX, curses.COLOR_BLUE), (PAIR_DIM, 8 if curses.COLORS > 8 else curses.COLOR_WHITE),
                       (PAIR_ON, curses.COLOR_BLACK), (PAIR_GO, curses.COLOR_BLUE),
                       (PAIR_TOAST, curses.COLOR_YELLOW)):
        try:
            curses.init_pair(number, fg, curses.COLOR_BLUE if number == PAIR_ON else -1)
        except curses.error:
            pass
    screen.keypad(True)
    shell = Shell(session)
    try:
        draft = draft_path().read_text(encoding="utf-8")
    except OSError:
        draft = ""
    ed = Editor(draft)
    issue, focus, pasting = True, "body", False
    saved_text, saved_at, dirty_at = draft, (time.strftime("%H:%M") if draft else ""), None
    toast = ""
    prev, group = previous()

    def save(force=False):
        nonlocal saved_text, saved_at, dirty_at
        text = ed.text()
        if text == saved_text:
            dirty_at = None
            return
        if not force and dirty_at is not None and time.monotonic() - dirty_at < SAVE_EVERY:
            return
        if text.strip():
            write_atomic(draft_path(), text)
        else:
            try:
                draft_path().unlink()
            except OSError:
                pass
        saved_text, saved_at, dirty_at = text, time.strftime("%H:%M") if text.strip() else "", None

    def put(y, x, text, attr=0):
        h, w = screen.getmaxyx()
        if 0 <= y < h and x < w - 1:
            try:
                screen.addstr(y, x, clip(text, w - 1 - x), attr)
            except curses.error:
                pass

    while True:
        h, w = screen.getmaxyx()
        screen.erase()
        x0, bw = 3, max(10, w - 7)
        dim = curses.color_pair(PAIR_DIM)
        put(1, x0, tr("compose_head"), curses.A_BOLD)
        if saved_at and ed.text().strip():
            note = tr("compose_saved_fmt", saved_at)
            put(1, max(x0, x0 + bw - cells(note)), note, dim)
        inner = bw - 4
        rows = []
        for i, line in enumerate(ed.lines):
            for s, e in wrap(line, inner):
                rows.append((i, s, e))
        box_h = max(6, min(len(rows), max(6, h - 10)))
        cur = next((n for n, (i, s, e) in enumerate(rows)
                    if i == ed.row and s <= ed.col <= e and (ed.col < e or e == len(ed.lines[i]) or
                                                              n + 1 == len(rows) or rows[n + 1][0] != i)), 0)
        top = max(0, cur - box_h + 1)
        put(2, x0, "╭" + "─" * (bw - 2) + "╮", curses.color_pair(PAIR_BOX))
        for y in range(box_h):
            put(3 + y, x0, "│", curses.color_pair(PAIR_BOX))
            put(3 + y, x0 + bw - 1, "│", curses.color_pair(PAIR_BOX))
            n = top + y
            if n < len(rows):
                i, s, e = rows[n]
                put(3 + y, x0 + 2, ed.lines[i][s:e])
        if not ed.text():
            put(3, x0 + 3, tr("compose_placeholder"), dim)
        put(3 + box_h, x0, "╰" + "─" * (bw - 2) + "╯", curses.color_pair(PAIR_BOX))
        y = 4 + box_h
        x = x0 + 2
        put(y, x, tr("compose_repo") + " ", dim)
        x += cells(tr("compose_repo")) + 1
        repo = " " + (tr("compose_repo_auto_fmt", group) if group else tr("compose_repo_auto")) + " "
        put(y, x, repo, curses.A_BOLD)
        x += cells(repo) + 4
        put(y, x, tr("compose_issue") + " ", dim)
        x += cells(tr("compose_issue")) + 1
        box = " ✓ " if issue else "   "
        put(y, x, box, curses.color_pair(PAIR_ON) | curses.A_BOLD if focus == "issue" else curses.A_REVERSE)
        toggle_x = x
        x += cells(box) + 4
        files = attachments(ed.text())
        if files:
            put(y, x, tr("compose_attach") + " ", dim)
            put(y, x + cells(tr("compose_attach")) + 1, ", ".join(os.path.basename(f) for f in files))
        go = tr("compose_go_issue") if issue else tr("compose_go_draft")
        put(y, max(x, x0 + bw - cells(go)), go, curses.color_pair(PAIR_GO) | curses.A_BOLD)
        put(y + 2, x0 + 2, tr("compose_keys"), dim)
        if toast:
            put(y + 3, x0 + 2, toast, curses.color_pair(PAIR_TOAST))
        # the cursor: in the box on the body, on the switch otherwise
        if focus == "body":
            i, s, e = rows[cur] if rows else (0, 0, 0)
            cy, cx = 3 + cur - top, x0 + 2 + cells(ed.lines[i][s:ed.col])
        else:
            cy, cx = y, toggle_x + 1
        try:
            screen.move(min(cy, h - 1), min(cx, w - 2))
        except curses.error:
            pass
        screen.refresh()

        screen.timeout(int(SAVE_EVERY * 1000) if dirty_at is not None else -1)
        try:
            kind, k = read_key(screen)
        except curses.error:
            kind, k = "none", ""
        except KeyboardInterrupt:
            kind, k = "key", "esc"
        if kind == "none":
            save(force=True)   # idle a beat: the draft is on disk
            continue
        if kind == "text":
            if focus == "issue" and k == " " and not pasting:
                issue = not issue
                continue
            focus = "body"
            ed.insert(k)
            toast = ""
        elif k == "paste_on":
            pasting, focus = True, "body"
        elif k == "paste_off":
            pasting = False
        elif k in ("newline",) or (k == "enter" and pasting):
            focus = "body"
            ed.newline()
        elif k == "enter":
            data = payload(ed.text(), issue, prev)
            if not data:
                toast = tr("compose_empty")
                continue
            if not write_atomic(send_path(), json.dumps(data, ensure_ascii=False) + "\n"):
                toast = "✗ " + str(send_path())
                continue
            if shell.hand("compose"):
                toast = tr("compose_sent_fmt", data["title"])
            else:
                out = subprocess.run([sys.executable, str(Path(__file__).absolute()), "--send", str(send_path())],
                                     stdin=subprocess.DEVNULL, capture_output=True, text=True)
                toast = tr("compose_result_fmt", (out.stdout or out.stderr).strip().split("\n")[-1])
            ed.clear()
            issue, focus = True, "body"
            save(force=True)
        elif k == "tab" or k == "btab":
            focus = "issue" if focus == "body" else "body"
        elif k == "esc":
            save(force=True)
            go_back(shell, prev)
            prev, group = previous()
            continue
        elif k == "resize":
            continue
        elif focus == "body":
            {"bs": ed.backspace, "del": ed.delete, "left": lambda: ed.move(dc=-1),
             "right": lambda: ed.move(dc=1), "up": lambda: ed.move(dr=-1), "down": lambda: ed.move(dr=1),
             "home": lambda: setattr(ed, "col", 0), "end": lambda: setattr(ed, "col", len(ed.lines[ed.row])),
             "kill_bol": ed.kill_bol, "kill_eol": ed.kill_eol, "kill_word": ed.kill_word}.get(k, lambda: None)()
        if dirty_at is None and ed.text() != saved_text:
            dirty_at = time.monotonic()


def clip(text, width):
    out, used = [], 0
    for c in text:
        w = cells(c)
        if used + w > width:
            break
        out.append(c)
        used += w
    return "".join(out)


def main(argv):
    global TEXT
    TEXT = load_text()
    if argv[:1] == ["--send"] and len(argv) >= 2:
        opts = {"--repo": "", "--node": "auto", "--reap": ""}
        rest = argv[2:]
        while rest:
            if rest[0] in opts and len(rest) >= 2:
                opts[rest[0]] = rest[1]
                rest = rest[2:]
            else:
                print("fleet-compose: unknown argument %s" % rest[0], file=sys.stderr)
                return 2
        return send(argv[1], opts["--repo"], opts["--node"], opts["--reap"])
    if argv[:1] == ["payload"] and len(argv) >= 2:
        text = Path(argv[1]).read_text(encoding="utf-8")
        print(json.dumps(payload(text, "--no-issue" not in argv), ensure_ascii=False, sort_keys=True))
        return 0
    session = ""
    if argv[:1] == ["--session"] and len(argv) >= 2:
        session = argv[1]
    elif argv:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    os.environ.setdefault("ESCDELAY", "25")
    curses.wrapper(ui, session)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
