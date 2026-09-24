#!/usr/bin/env python3
"""A compact live hub list. One view per attached fleet; no hidden render loops.

The worker keeps tmux's active-pane identity even during keyboard navigation.
That matters: collectors, messages and recovery tools resolve a window to its
active agent pane. Mouse forwarding and the fleet-sidebar key table deliver
input explicitly to this view without changing that identity.
"""
import codecs
import curses
import fcntl
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata

BIN = Path(__file__).absolute().parent  # preserve the selftest shadow root
US = "\x1f"
VIEW_VERSION = "15"  # #1097: the input line has a cursor; replace live v14 views once
# ↑↓ follow (issue #822): an arrow moves the highlight at once and switches to
# it only after this much quiet. A held key on a slow link is one switch, not
# one per row, and a row passed over is never selected — so the wake hook's
# dwell (fleet-sleep.py) never sees it either. 0.12s since the arrow binds stopped
# forking (issue #1033): a held key still repeats faster than this.
FOLLOW_SECS = 0.12
# The row producer runs BESIDE the UI loop (issue #1033) — it takes 0.3–0.5s, and
# run inline it froze input for a third of every second. The loop polls it this
# often while it runs, and kills one that hangs.
PRODUCER_POLL = 0.05
PRODUCER_TIMEOUT = 10
# The input line (issue #896): a refused spawn's reason stays this long, then
# the typed name — which is kept — shows again.
TOAST_SECS = 4
PLACEHOLDER = "新会话名…"
# The one row above the input line (issue #948): a tap on it, or `?` on an empty
# input line, opens this sidebar's key sheet — Claude Code's "? for shortcuts".
# An explicit exception to EPIC #894 convention 5 (no resident rows), chosen by
# the operator: on an iPad a whole row is a tap target a hint glyph is not.
HELP_ROW = " ? 快捷键"
# A Chinese IME turns the `.` and `?` keys into full-width 。/． and ？ (issue
# #965). On an EMPTY input line they are the same keys — the row menu and the
# key sheet — so the operator need not switch to English first; inside a name
# they type as themselves, like `.` and `?` do.
KEY_ALIASES = {"。": ".", "．": ".", "？": "?"}


def run(args, **kwargs):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=10, **kwargs)


def tmux(*args):
    return run(["tmux", *args]).stdout.rstrip("\n").replace("\\037", US)


def fields(target, fmt):
    return tmux("display-message", "-p", "-t", target, fmt).split(US)


def panes(session):
    fmt = US.join(("#{pane_id}", "#{window_id}", "#{@sidebar}",
                   "#{pane_active}", "#{pane_dead}", "#{@sidebar_worker}",
                   "#{@sidebar_version}"))
    return [line.split(US) for line in tmux(
        "list-panes", "-s", "-t", session, "-F", fmt).splitlines()
        if len(line.split(US)) == 7]


def remove_view(pane):
    # Verify ownership immediately before removal; never close an agent pane.
    if fields(pane, "#{@sidebar}") == ["1"]:
        tmux("set-option", "-uw", "-t", pane, "@sidebar_worker")
        tmux("kill-pane", "-t", pane)


def move_view(pane, worker, width, select=False):
    """Move the populated grid before selecting its new window, in one queue."""
    source = fields(pane, US.join(("#{window_id}", "#{@sidebar}")))
    target = fields(worker, US.join(("#{window_id}", "#{window_width}",
                                    "#{window_zoomed_flag}")))
    if len(source) != 2 or source[1] != "1" or len(target) != 3:
        return False
    window, cols, zoomed = target
    if not cols.isdigit() or int(cols) < width + 81 or zoomed == "1":
        return False
    commands = []
    if source[0] != window:
        commands = ["set-option", "-uw", "-t", source[0], "@sidebar_worker", ";",
                    "set-option", "-w", "-t", window, "@sidebar_worker", worker, ";",
                    "join-pane", "-d", "-h", "-b", "-f", "-l", str(width),
                    "-s", pane, "-t", worker]
    if select:
        if commands:
            commands.append(";")
        commands += ["select-window", "-t", window, ";", "select-pane", "-t", worker]
    return not commands or run(["tmux", *commands]).returncode == 0


def leave_navigation(session):
    # A hidden sidebar must not keep intercepting a client's arrow keys.
    for line in tmux("list-clients", "-t", session, "-F",
                     US.join(("#{client_name}", "#{client_key_table}"))).splitlines():
        client, _, table = line.partition(US)
        if table == "fleet-sidebar":
            tmux("switch-client", "-c", client, "-T", "root")


def sync(session, enabled, width, lock):
    info = fields(session + ":", US.join(("#{window_id}", "#{window_name}",
                  "#{window_width}", "#{session_attached}", "#{@issue}",
                  "#{@raw}", "#{@worktree}", "#{@norepo}", "#{window_zoomed_flag}")))
    if len(info) != 9:
        return
    window, name, cols, attached, issue, raw, worktree, norepo, zoomed = info
    all_panes = panes(session)
    workers = [p for p in all_panes if p[1] == window and p[2] != "1" and p[4] != "1"]
    wanted = (enabled == "1" and attached != "0" and
              name not in ("plan", "dash", "backlog") and
              # A task: issue worker, repo scratch, or a no-repo session in $HOME (#996).
              bool(issue or raw == "1" or worktree or norepo == "1") and bool(workers) and
              int(cols) >= width + 1 + 80)
    if not wanted or zoomed == "1":
        leave_navigation(session)
    current, reusable = [], []
    for pane in all_panes:
        if pane[2] != "1":
            continue
        if wanted and pane[1] == window and pane[4] != "1" and pane[6] == VIEW_VERSION and not current:
            current.append(pane)
        elif wanted and zoomed != "1" and pane[4] != "1" and pane[6] == VIEW_VERSION and not reusable:
            reusable.append(pane)
        else:
            remove_view(pane[0])
    if current:
        for pane in reusable:
            remove_view(pane[0])
    if not wanted or current or zoomed == "1":
        return
    worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
    if reusable:
        if move_view(reusable[0][0], worker, width):
            return
        remove_view(reusable[0][0])
    # A reused view must not keep its first worker's worktree alive after moving.
    cwd = str(BIN.parent)
    cmd = " ".join(shlex.quote(arg) for arg in (
        "python3", str(BIN / "fleet-sidebar.py"), "ui", session, worker, lock))
    pane = tmux("split-window", "-d", "-h", "-b", "-f", "-l", str(width),
                "-t", worker, "-c", cwd, "-P", "-F", "#{pane_id}", cmd)
    if not pane.startswith("%"):
        return
    tmux("set-option", "-p", "-t", pane, "@sidebar", "1", ";",
         "set-option", "-p", "-t", pane, "@sidebar_version", VIEW_VERSION, ";",
         "set-option", "-w", "-t", pane, "@sidebar_worker", worker, ";",
         "set-option", "-p", "-t", pane, "remain-on-exit", "off")


def send_key(session, key):
    if key not in ("Up", "Down", "Left", "Right", "Enter", "Escape", "Home", "End"):
        return
    window = fields(session + ":", "#{window_id}")[0]
    for pane in panes(session):
        if pane[1] == window and pane[2] == "1":
            # Only the marked UI receives these keys, never the worker prompt.
            tmux("send-keys", "-t", pane[0], key)
            return


def jump(session, window, pane, lock):
    # Never resolve a stale row through a recycled index, or another fleet.
    if not window.startswith("@") or fields(window, "#{session_name}") != [session]:
        return
    with open(lock, "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        workers = [p for p in panes(session) if p[1] == window and p[2] != "1" and p[4] != "1"]
        if workers:
            worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
            width = fields(pane, "#{pane_width}")[0]
            if width.isdigit() and move_view(pane, worker, int(width), select=True):
                return
            tmux("select-window", "-t", window, ";", "select-pane", "-t", worker)


def clip(text, width):
    """Clip terminal cells, discard controls, and retain combining accents."""
    out, used = [], 0
    for char in text:
        if unicodedata.category(char).startswith("C"):
            continue
        size = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in "WF" else 1)
        if used + size > width:
            break
        out.append(char)
        used += size
    return "".join(out)


def selection_repo(session, key, env):
    """Where a session started from this row goes (issues #1009/#997): under `all`
    in a 2+ repo fleet, a window row's own repo or a repo heading's (`hdr:<repo>`),
    `none` for a no-repo row or the `no repo` heading — fleet_selection_repo, the
    resolver the hub shares, never a guess. "" otherwise, and the caller keeps
    today's behavior — a scratch with no repo, ⌃n's repo picker. A single repo in
    view still wins downstream."""
    if not (key.startswith("@") or key.startswith("hdr:")):
        return ""
    result = run(["bash", "-c", '. "$0/fleet-lib.sh" && fleet_selection_repo "$1" "$2"',
                  str(BIN), session, key], env=env)
    return result.stdout.strip() if result.returncode == 0 else ""


def new_task(screen, env, repo=""):
    """The hub's ⌃n popup, launched from this pane by ⌃n (issue #821; a letter
    since #896 types into the input line instead): file an issue
    and spawn its worker. dash-popup.sh resolves the client, raises @popup_open
    for the popup's lifetime and clears it on the way out; the spawned window
    becomes current and the session-window-changed hook moves this view there.
    Leave curses meanwhile: a popup draws on the client, not on this pane, but
    when none can open (no client, an overlay already up) dash-popup.sh runs the
    command INLINE here, and its fzf title prompt then needs a sane tty. No
    timeout — the popup lives as long as the operator types. `repo` (the
    anchor row's, issue #1009) rides CF_REPO on the popup's command line: a
    popup's shell takes the server's environment, not this one."""
    curses.endwin()
    pin = ["env", "CF_REPO=" + repo] if repo and repo != "none" else []
    subprocess.call(["bash", str(BIN / "dash-popup.sh"), "-w", "90%", "-h", "12", "--"] + pin +
                    ["bash", str(BIN / "dash-issue-new.sh"), "confirm", "--spawn"], env=env)
    screen.clear()  # the next refresh resumes curses and repaints the whole grid


def restore_pick(screen, session, env):
    """The restore picker (issue #901), on ⌃o (dash-keymap.sh --panel sidebar
    `restore`): the hub's landed list in a popup, a pick restored as the current
    window. Blocks like new_task, and leaves curses for the same inline fallback."""
    curses.endwin()
    subprocess.call(["bash", str(BIN / "fleet-restore-pick.sh"), "--session", session], env=env)
    screen.clear()


def no_discard():
    """macOS's line discipline eats ⌃o as VDISCARD (flush output) even in cbreak
    mode, so the `restore` byte never reached getch. Switch that one character
    off before curses saves the tty modes, so an endwin/refresh keeps it off."""
    try:
        attrs = termios.tcgetattr(0)
        attrs[6][termios.VDISCARD] = os.fpathconf(0, "PC_VDISABLE")
        termios.tcsetattr(0, termios.TCSANOW, attrs)
    except (AttributeError, OSError, ValueError, termios.error):
        pass


def open_help(screen, env):
    """The sidebar's `?` sheet (issue #948): fleet-keys.sh --context sidebar in
    a popup via dash-popup.sh (explicit client, the @popup_open epoch), exactly
    as the hub's `?` opens its own. Blocks until q/Esc closes it, which is the
    pause: nothing repaints under the popup. Leave curses meanwhile for the same
    reason new_task does — with no client the sheet runs INLINE in this pane.
    Sized to the sheet (issue #963): title + blank + seven rows + the border,
    as wide as the editing row (#1097)."""
    curses.endwin()
    subprocess.call(["bash", str(BIN / "dash-popup.sh"), "-w", "50", "-h", "11", "--",
                     "bash", str(BIN / "fleet-keys.sh"), "--context", "sidebar"], env=env)
    screen.clear()


def open_tap(screen, session, action, key, env):
    """A second tap's popup (issue #1032): a session row's menu, or a selected
    heading's ⌃n popup with its repo pinned — selection_repo resolves `hdr:…`
    exactly as it does for a typed name, so both paths agree on the target."""
    if action == "new":
        new_task(screen, env, selection_repo(session, key, env))
    else:
        open_menu(session, key, env)


def open_menu(session, wid, env):
    """The row's action menu (issue #898). fleet-sidebar.sh owns every tmux
    command string in it; this only names the row, by its stable window id.
    Not waited on: a tmux display-menu can hold its caller until it closes, and
    this view keeps painting meanwhile."""
    if wid.startswith("@"):
        subprocess.Popen(["bash", str(BIN / "fleet-sidebar.sh"), "menu", session, wid],
                         env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)


def cells(char):
    return 2 if unicodedata.east_asian_width(char) in "WF" else 1


def tail(text, width):
    """The END of `text` in `width` cells."""
    out, used = [], 0
    for char in reversed(text):
        if used + cells(char) > width:
            break
        out.append(char)
        used += cells(char)
    return "".join(reversed(out))


def head(text, width):
    """The START of `text` in `width` cells."""
    out, used = [], 0
    for char in text:
        if used + cells(char) > width:
            break
        out.append(char)
        used += cells(char)
    return "".join(out)


def wordy(char):
    # A word is a run of letters/digits — CJK included — or `_`, as Claude's
    # prompt and readline's ⌥b/⌥f see one; spaces and punctuation separate.
    return char.isalnum() or char == "_"


class Line:
    """The input line as a line editor (issue #1097): the text and a cursor on it.
    Typing, rename and the typed-name spawn all edit through this, so ←→ Home End
    ⌥←→ ⌃a ⌃e ⌃w ⌃k ⌃u behave the same in each. The keys' double meaning (an
    EMPTY line keeps ←→ fold and Home/End first/last row) is the caller's."""

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
        room = max(0, width - len(cursor))
        before, after = self.text[:self.pos], self.text[self.pos:]
        right = head(after, max(room // 2, room - sum(map(cells, before))))
        return tail(before, room - sum(map(cells, right))) + cursor + right


# ⌥←/⌥→ read off the raw escape sequence (issue #1097): the pseudo-keys
# escape_word returns for them, next to curses' own codes.
WORD_LEFT, WORD_RIGHT = -2, -3


def escape_word(screen):
    """After an ESC byte: ⌥← / ⌥→ as the terminal spelled them, else the ESC.
    They reach this pane through the fleet-sidebar table's `Any` as whatever tmux
    writes for M-b / M-f / M-Left / M-Right (⌃← / ⌃→ too): ESC b, ESC f,
    ESC[1;3D … — which keypad parsing only knows when the terminfo does. A lone
    Escape (the Escape bind's) has nothing behind it and stays 27; an unknown
    CSI sequence is swallowed (-1) rather than typed as `[1;2A`."""
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
        return -1
    finally:
        screen.nodelay(False)


def edit_of(key, text):
    """The Line method `key` runs on the input line (issue #1097), or "" when the
    key is the list's. The ⌃ bytes are dash-keymap.sh --panel sidebar `bol`
    `eol` `kill_word` `kill_eol` (their ⌥ fallbacks are rewritten to these bytes
    by the conf); ⌃u clears, as before. ←→ and Home/End edit only while the line
    holds text: on an EMPTY line they stay the list's fold and first/last row —
    the hub's rule (dash-fold-toggle.sh), shared on purpose. ↑↓ never edit."""
    if key == 1:
        return "home"
    if key == 5:
        return "end"
    if key == 23:
        return "kill_word"
    if key == 11:
        return "kill_eol"
    if key == 21:
        return "clear"
    if key in (curses.KEY_BACKSPACE, 8, 127):
        return "backspace"
    if key == curses.KEY_DC:
        return "delete"
    try:
        name = curses.keyname(key) if key > 255 else b""
    except (curses.error, ValueError):
        name = b""
    if key == WORD_LEFT or name in (b"kLFT3", b"kLFT5"):
        return "word_left"
    if key == WORD_RIGHT or name in (b"kRIT3", b"kRIT5"):
        return "word_right"
    if not text:
        return ""
    return {curses.KEY_LEFT: "left", curses.KEY_RIGHT: "right",
            curses.KEY_HOME: "home", curses.KEY_END: "end"}.get(key, "")


def typed(char):
    """A character the input line takes: printable text, CJK included."""
    return not unicodedata.category(char).startswith("C")


def mark_input(pane, text):
    # @sidebar_input=1 while the line holds text: the Enter/Escape binds (and
    # C4's ⌂ / R2) read it to keep the keyboard here instead of handing it back.
    if text:
        tmux("set-option", "-p", "-t", pane, "@sidebar_input", "1")
    else:
        tmux("set-option", "-up", "-t", pane, "@sidebar_input")


def spawn_scratch(name, env, repo=""):
    """The hub's ⌃s with a name (issue #896): the same script and the same
    provenance (`--origin hub` — the sidebar sits in a worker's window, and a
    session started here is not that worker's child). Focus follows the new
    window, and the window-changed hook moves this view there. stderr (the
    refusal reason) goes to a file, not a pipe: whatever the spawn leaves running
    would hold a pipe open, and reading it would freeze this view. `repo` (the
    highlighted row's, issues #1009/#997) goes as --repo, `none` as --no-repo;
    empty keeps dash-raw-session.sh's own resolution."""
    log = tempfile.TemporaryFile("w+")
    proc = subprocess.Popen(
        ["bash", str(BIN / "dash-raw-session.sh"), "--name", name, "--origin", "hub"] +
        (["--no-repo"] if repo == "none" else ["--repo", repo] if repo else []),
        env=dict(env, FLEET_SPAWN_FOCUS="1"), stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=log)
    proc.log = log
    return proc


def landing(ids, window, limit=8):
    """Where closing `window` should land (issue #900): the rows below it in
    list order, then the rows above it nearest-first — so closing a middle task
    lands on the next one, closing the last lands on the one before. Several are
    kept, not one: the close hook takes the first that is still alive and not
    asleep, so a batch of closes (or a neighbour that sleeps) never falls back to
    the hub while a live task remains. Panels never appear in `ids`."""
    if window not in ids:
        return []
    at = ids.index(window)
    return (ids[at + 1:] + ids[:at][::-1])[:limit]


def key_of(row):
    """A row's cursor key: its window id, or `hdr:<target>` for a repo heading that
    names where a new session goes (issue #997 — the producer puts owner/name, or
    `none` for `no repo`, in a heading's state field). Every other `hdr` row (the
    `?` heading, the empty-state hint) stays bare `hdr`: never a cursor stop."""
    return "hdr:" + row[1] if row[0] == "hdr" and row[1] else row[0]


def selectable(rows):
    """The keys a cursor can rest on: every session row, plus a repo heading with a
    spawn target (issue #997) — the new-session path reads it, and every other
    action ignores it (`acts`). Other `hdr` rows (#974) are painted, never landed on."""
    return [key_of(row) for row in rows if key_of(row) != "hdr"]


def sessions(rows):
    """The window ids alone — what a close lands on (#900), never a heading."""
    return [row[0] for row in rows if row[0] != "hdr"]


def target_name(key):
    """The repo a selected heading names, as the input line shows it (issue
    #1032): `owner/name` → `name`, the `no repo` heading → `no repo` (its session
    opens in $HOME). "" for anything that is not a heading with a spawn target."""
    if not key.startswith("hdr:"):
        return ""
    repo = key[4:]
    return "no repo" if repo == "none" else repo.rsplit("/", 1)[-1]


def placeholder(key):
    """The empty input line's hint: it names the destination whenever a heading
    is selected (issue #1032), so where a typed name goes is never a guess."""
    name = target_name(key)
    return "新会话 → " + name + "…" if name else PLACEHOLDER


def tap(hit, highlighted):
    """What a tap on list key `hit` does, given the highlighted key (issue #1032):
    the same two-tap grammar for both kinds of row. A session row: 1st tap
    `jump`s to it, 2nd opens its `menu` (#898). A repo heading with a spawn
    target: 1st tap `select`s it — highlight only, no window switch — and the 2nd
    opens the `new`-session popup pinned to its repo. A bare `hdr` (the `?`
    heading, the empty-state hint) or no row at all: None. A fleet with no
    headings never sees `select` or `new`, so it taps exactly as before."""
    if not hit or hit == "hdr":
        return None
    if hit.startswith("hdr:"):
        return "new" if hit == highlighted else "select"
    return "menu" if hit == highlighted else "jump"


def acts(key):
    """The highlighted row as a target for any action but a new session or a fold:
    a heading (`hdr:…`) is none — jump, menu, tap all stay no-ops on it (EPIC #994)."""
    return "" if key.startswith("hdr") else key


def folds(key):
    """The highlighted row as a ←/→ target: a session row (its subtree), or a repo
    heading with a spawn target — `hdr:<target>`, which dash-fold-toggle.sh reads
    as that repo's whole group (issue #1037). A bare `hdr` (the `?` heading, the
    empty-state hint) or no row at all: nothing to fold."""
    return key if key and key != "hdr" else ""


def start_rows(env):
    """Launch the row producer without waiting for it (issue #1033). Output goes
    to a file, not a pipe: a full pipe would stall a producer this loop only
    polls. `started` bounds a hung one."""
    out = tempfile.TemporaryFile("w+")
    proc = subprocess.Popen(["bash", str(BIN / "tmux-dashboard-rows.sh"), "--sidebar"],
                            env=dict(env), stdin=subprocess.DEVNULL, stdout=out,
                            stderr=subprocess.DEVNULL, text=True)
    proc.out, proc.started = out, time.monotonic()
    proc.current = env["FLEET_SIDEBAR_CURRENT"]
    return proc


def collect_rows(proc):
    """A finished producer's rows, or None (failed, killed, still running)."""
    if proc.poll() is None:
        if time.monotonic() - proc.started < PRODUCER_TIMEOUT:
            return None
        proc.kill()
        proc.wait()
    proc.out.seek(0)
    text = proc.out.read()
    proc.out.close()
    if proc.returncode != 0:
        return None
    return [line.split(US, 4) for line in text.split("\n")
            if len(line.split(US, 4)) == 5]


def visible(info, now):
    if len(info) != 4:
        return False
    active, zoomed, attached, popup = info
    # Same bounded popup pause as the hub. A stale flag cannot freeze the list.
    try:
        modal = 0 <= now - int(popup) < 30
    except ValueError:
        modal = False
    return active == "1" and zoomed != "1" and attached != "0" and not modal


def ui(screen, session, worker, lock):
    pane = os.environ["TMUX_PANE"]
    window = fields(worker, "#{window_id}")[0]
    env = dict(os.environ, FLEET_SESSION=session, FLEET_SIDEBAR_CURRENT=window)
    curses.curs_set(0)
    curses.use_default_colors()
    for number, color in enumerate((curses.COLOR_CYAN, curses.COLOR_RED,
                                     curses.COLOR_GREEN, curses.COLOR_MAGENTA), 1):
        curses.init_pair(number, color, -1)
    curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_YELLOW)
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
    curses.mouseinterval(0)
    curses.init_pair(7, curses.COLOR_RED, -1)
    screen.keypad(True)
    curses.meta(True)
    rows, selected, offset, refresh_at = [], window, 0, 0.0
    shown, navigation, follow_at = False, False, None
    # The input line (issue #896). Keys arrive as BYTES through the fleet-sidebar
    # table's Any bind; decode them here, so a CJK name survives whatever locale
    # tmux started this pane under.
    line, toast, toast_until, spawning = Line(), "", 0.0, None
    # A press on the already-highlighted row arms the menu; its RELEASE opens it
    # (issue #898). Opening on the press would lose the menu at once: tmux closes
    # a menu on a button release outside it, and that release is this tap's own.
    armed = None
    # Rename (issue #898): the menu's 改名 turns THIS input line into the name
    # editor for one row — the hub's ⌃e does the same to its query line. The
    # name goes to dash-rename.sh as an argv word; no tmux or shell parser ever
    # sees it (a command-prompt template re-parses the reply, and tmux 3.4 and
    # 3.7 unescape it differently).
    renaming = None
    decoder = codecs.getincrementaldecoder("utf-8")("ignore")
    mark_input(pane, "")
    published = None  # the (window, candidates) last written to @sidebar_next
    # The row producer in flight (issue #1033), and whether any run has landed:
    # only the FIRST frame waits for one — every later frame paints the last
    # good rows, so a jump's `▶` moves as soon as the pane has.
    producer, loaded = None, False
    while True:
        now = time.monotonic()
        if producer is not None and (producer.poll() is not None or
                                     now - producer.started >= PRODUCER_TIMEOUT):
            fresh, current = collect_rows(producer), producer.current
            producer = None
            if current != window:
                # Read against a window this view has since left: its fold
                # exemptions are for the wrong row. Drop it, read again now.
                refresh_at = 0
            elif fresh is not None:
                rows, loaded = fresh, True
                # Publish the close-landing candidates for THIS window (issue
                # #900) — only on change, so an idle view forks nothing extra.
                # `@sidebar_next_of` pins them to the window they were read
                # against: the hub-arrival hook uses them only when THAT is
                # the window that just closed.
                nxt = " ".join(landing(sessions(rows), window))
                if (window, nxt) != published and window in [row[0] for row in rows]:
                    tmux("set-option", "-t", "=" + session + ":", "@sidebar_next", nxt, ";",
                         "set-option", "-t", "=" + session + ":", "@sidebar_next_of", window)
                    published = (window, nxt)
        if spawning is not None and spawning.poll() is not None:
            # The spawn selected its window; the hook has moved (or is moving)
            # this view there. Input goes to the new session's agent.
            spawning.log.seek(0)
            error = spawning.log.read().strip().splitlines()
            spawning.log.close()
            if spawning.returncode == 0:
                line.clear()
                mark_input(pane, line.text)
                leave_navigation(session)
            else:
                # Keep the name: a cap refusal is retried once a slot frees.
                reason = error[-1] if error else "spawn failed"
                toast = "✗ " + reason.split(": ", 1)[-1]
                toast_until = now + TOAST_SECS
            spawning = None
            refresh_at = 0
        if follow_at is not None and now >= follow_at:
            # The highlight settled: switch once. Nothing here touches the
            # client's key table, and the Up/Down binds re-enter fleet-sidebar
            # before their key arrives, so ↑↓ keep browsing after the switch;
            # Enter/Escape (whose binds do not re-enter) still hand input back.
            follow_at = None
            if acts(selected) and selected != window:
                jump(session, selected, pane, lock)
                refresh_at = 0
                continue
        if now >= refresh_at:
            refresh_at = now + 1
            info = fields(pane, US.join(("#{window_active}", "#{window_zoomed_flag}",
                                         "#{session_attached}", "#{@popup_open}",
                                         "#{window_id}", "#{@sidebar_worker}",
                                         "#{client_key_table}")))
            if len(info) != 7:
                return
            # The pane (and curses grid) survives navigation. Follow its new
            # worker before testing liveness or building current-row exemptions.
            if info[4] != window:
                window = info[4]
                selected = window
                env["FLEET_SIDEBAR_CURRENT"] = window
            worker = info[5] or worker
            navigation = info[6] == "fleet-sidebar"
            # kill-pane does not emit pane-exited on every supported tmux.
            # Never let this view keep an otherwise closed worker window alive.
            if fields(worker, "#{pane_dead}") != ["0"]:
                return
            shown = visible(info[:4], time.time())
            if shown and producer is None:
                producer = start_rows(env)
                if not loaded:
                    # The first frame waits for real rows rather than flash an
                    # empty list; input has nothing to act on before it anyway.
                    try:
                        producer.wait(timeout=PRODUCER_TIMEOUT)
                    except subprocess.TimeoutExpired:
                        pass
                    continue
        if not shown:
            follow_at = None  # a hidden view never switches windows
            screen.timeout(1000)
            screen.getch()
            continue
        height, width = screen.getmaxyx()
        # A repo group heading (issue #974) is inert to every action: `hdr` in the
        # id field. One with a spawn target is a cursor stop since #997 — ↑/↓ land
        # on it so a typed name starts THERE — but a tap, Enter, `.` and the
        # follow all ignore it (`acts`); ←/→ on it fold and unfold its whole repo
        # group (`folds`, issue #1037). `where` is the selection's place in the
        # PAINTED list, which the scroll offset is measured in.
        ids = selectable(rows)
        # Rows still in flight for a window just jumped to may not hold it yet (a
        # folded child shows only as the current row): keep the selection until
        # they land, rather than reset it to the top for one frame.
        if selected not in ids and producer is None:
            selected = window if window in ids else (ids[0] if ids else "")
        index = ids.index(selected) if selected in ids else 0
        where = next((i for i, row in enumerate(rows) if key_of(row) == selected), 0)
        # The `? 快捷键` row sits above the input line whenever a task row
        # still fits above it; the list loses that one row.
        help_y = height - 2 if height >= 3 else None
        page = max(1, height - (1 if help_y is None else 2))
        offset = max(0, min(offset, max(0, len(rows) - page)))
        if index == 0:
            where = 0  # the top row keeps the heading above it in view
        if where < offset:
            offset = where
        elif where >= offset + page:
            offset = where - page + 1

        def put(y, text, attr=0, fill=False):
            if 0 <= y < height:
                try:
                    if fill:
                        screen.hline(y, 0, " ", max(0, width - 1), attr)
                    screen.addstr(y, 0, clip(text, max(0, width - 1)), attr)
                except curses.error:
                    pass  # a resize may race this paint

        screen.erase()
        colors = {"working": 1, "needs": 2, "done": 3, "looping": 4}
        for y, (wid, state, glyph, label, tree) in enumerate(rows[offset:offset + page]):
            if wid == "hdr":
                if navigation and key_of((wid, state)) == selected:
                    put(y, "› " + label, curses.color_pair(6) | curses.A_BOLD, fill=True)
                else:
                    put(y, label, curses.A_DIM | curses.A_BOLD)
                continue
            attr = curses.color_pair(colors.get(state, 0))
            if wid == window:
                attr = curses.color_pair(5) | curses.A_BOLD
            if navigation and wid == selected:
                attr = curses.color_pair(6) | curses.A_BOLD
            marker = "▶" if wid == window else "›" if navigation and wid == selected else " "
            # `marker glyph tree label` (issue #836): the hierarchy glyph is its own
            # fixed cell between the state glyph and the name, so at 30 columns every
            # name starts in the same place instead of a child's text sitting two
            # columns right of its parent's.
            put(y, marker + " " + glyph + " " + (tree or " ") + " " + label, attr,
                fill=wid == window or (navigation and wid == selected))
        if help_y is not None:
            put(help_y, HELP_ROW, curses.A_DIM)
        # ONE input line closes the list (issue #896): the hints moved to the
        # `?` sheet. Typing while the keyboard is here fills it; Enter starts a
        # scratch session named after it. Away from the sidebar only `›` shows.
        # Hide is keyboard-only (prefix e): no tap here hides anything (#821).
        room = max(0, width - 3)
        if renaming is not None:
            put(height - 1, "改名› " + line.view(max(0, room - 4)), curses.A_BOLD)
        elif spawning is not None:
            put(height - 1, "› " + line.view(max(0, room - 2), "") + " …", curses.A_DIM)
        elif toast and time.monotonic() < toast_until:
            put(height - 1, "› " + toast, curses.color_pair(7))
        elif line.text:
            put(height - 1, "› " + line.view(room if navigation else room - 1,
                                             "▏" if navigation else ""),
                curses.A_BOLD if navigation else curses.A_DIM)
        else:
            put(height - 1, "› " + placeholder(selected) if navigation else "›", curses.A_DIM)
        screen.refresh()
        # Wake for whichever comes first: the next repaint, a pending follow or
        # a finished spawn.
        wait = refresh_at - time.monotonic()
        if follow_at is not None:
            wait = min(wait, follow_at - time.monotonic())
        if spawning is not None:
            wait = min(wait, 0.2)
        if producer is not None:
            wait = min(wait, PRODUCER_POLL)
        screen.timeout(max(1, min(1000, int(wait * 1000))))
        key = screen.getch()
        if key == curses.KEY_F12:
            # The menu's rename item: it parked the row's @id on this pane,
            # switched the client to the sidebar table and sent F12 to wake us.
            wid = tmux("show-options", "-pqv", "-t", pane, "@sidebar_rename")
            tmux("set-option", "-up", "-t", pane, "@sidebar_rename")
            if wid.startswith("@") and spawning is None:
                follow_at, renaming, toast = None, wid, ""
                line.set(fields(wid, "#{window_name}")[0])
                mark_input(pane, "1")
            continue
        if key == 27:
            key = escape_word(screen)
        op = edit_of(key, line.text)
        if op:
            # The input line's own keys (issue #1097). A spawn in flight owns
            # the name, so they wait like typing does.
            if spawning is None:
                was, toast = line.text, ""
                getattr(line, op)()
                if bool(was) != bool(line.text):
                    mark_input(pane, renaming or line.text)
            continue
        # A typed key is a byte; a multi-byte one (。 ？, CJK) completes over
        # several getch calls, and only the last one yields its character.
        byte = 0 <= key < 256 and key not in (8, 9, 10, 13, 14, 15, 27, 127)
        chars = "".join(c for c in decoder.decode(bytes([key])) if typed(c)) if byte else ""
        press = KEY_ALIASES.get(chars, chars)
        if press == "." and not line.text and renaming is None and spawning is None and acts(selected):
            # `.` on an EMPTY line is the row menu (dash-keymap.sh --panel sidebar
            # `menu`); inside a name it types. The follow is dropped: the menu
            # acts on the highlighted row and the window in view stays put.
            follow_at = None
            open_menu(session, selected, env)
            continue
        if press == "?" and not line.text and renaming is None and spawning is None:
            # `?` on an EMPTY line is the sidebar's key sheet (dash-keymap.sh
            # --panel sidebar `help`, issue #948); inside a name it types.
            follow_at = None
            open_help(screen, env)
            refresh_at = 0
            continue
        if byte:
            # A (piece of a) typed character. Every letter types — j k q n
            # included; movement is ↑↓ only, hide is prefix e.
            if chars and spawning is None:
                was, toast = line.text, ""
                line.insert(chars)
                if not was:
                    mark_input(pane, line.text)
            continue
        decoder.reset()
        if key == curses.KEY_UP and ids:
            selected = ids[max(0, index - 1)]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key == curses.KEY_DOWN and ids:
            selected = ids[min(len(ids) - 1, index + 1)]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key == curses.KEY_HOME and ids:
            selected = ids[0]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key == curses.KEY_END and ids:
            selected = ids[-1]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key in (10, 13, curses.KEY_ENTER) and renaming is not None:
            # An empty name cancels, as in the hub (dash-rename.sh decides).
            run(["bash", str(BIN / "dash-rename.sh"), "--wid", renaming, line.text.strip()], env=env)
            renaming = None
            line.clear()
            mark_input(pane, line.text)
            refresh_at = 0
        elif key == 27 and renaming is not None:
            renaming = None
            line.clear()
            mark_input(pane, line.text)
        elif key in (10, 13, curses.KEY_ENTER) and line.text.strip():
            # A typed name: start its scratch session (the bind kept the
            # keyboard here while @sidebar_input was set). One spawn at a time.
            follow_at = None
            if spawning is None:
                toast = ""
                spawning = spawn_scratch(line.text.strip(), env,
                                         selection_repo(session, selected or window, env))
        elif key in (10, 13, curses.KEY_ENTER):
            # The Enter bind already returned the client to root; the key reaches
            # here a run-shell hop later. If the follow (or anyone) has moved the
            # session since, a switch back to the row it was read against would
            # yank the operator — with nothing to jump to, Enter only hands over.
            follow_at = None
            if acts(selected) and selected != window:
                jump(session, selected, pane, lock)
            refresh_at = 0
        elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and folds(selected):
            # A session row folds its subtree; a repo heading its whole group
            # (issue #1037) — one helper, the hub's, for both.
            verb = "collapse" if key == curses.KEY_LEFT else "expand"
            run(["bash", str(BIN / "dash-fold-toggle.sh"), verb, folds(selected)], env=env)
            refresh_at = 0
        elif key == 14:
            # ⌃n (dash-keymap.sh --panel sidebar `new`; its ⌥n fallback is
            # rewritten to ⌃n by the bind). The popup blocks; a follow scheduled
            # just before must not fire after it and switch away from the window
            # the spawn made current.
            follow_at = None
            new_task(screen, env, selection_repo(session, selected or window, env))
            refresh_at = 0
        elif key == 15:
            # ⌃o (`restore`; its ⌥o fallback is rewritten to ⌃o by the bind). The
            # restored window becomes current; the hook moves this view there.
            follow_at = None
            restore_pick(screen, session, env)
            refresh_at = 0
        elif key == 27 and line.text and spawning is None:
            # Escape clears a typed name first; the keyboard stays here.
            line.clear()
            toast = ""
            mark_input(pane, line.text)
        elif key == 27:
            # Escape bails out of a pending follow too: the worker in view keeps input.
            follow_at = None
            selected = window
            refresh_at = 0
        elif key == curses.KEY_MOUSE:
            try:
                _, _, y, _, buttons = curses.getmouse()
            except curses.error:
                continue
            hit = key_of(rows[offset + y]) if 0 <= y < page and offset + y < len(rows) else None
            # `selected`, not the painted cue: a fast double tap lands its second
            # press before the next refresh repaints the first one's switch.
            action = tap(hit, selected)
            if buttons & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED):
                refresh_at = 0
                armed = None
                if help_y is not None and y == help_y:
                    # The `? 快捷键` row (issue #948). Opened on the release, like
                    # the menu: the popup must not swallow this tap's own release.
                    follow_at = None
                    if buttons & curses.BUTTON1_CLICKED:
                        open_help(screen, env)
                    else:
                        armed = HELP_ROW
                elif action in ("menu", "new"):
                    # The second tap on a row (the first switched to it), or a tap
                    # on the row already in view: its action menu — the touch
                    # path to what `.` opens (issue #898). On a selected heading
                    # it is ⌃n pinned to that repo (issue #1032). Both open on
                    # the release, for the same reason as the key sheet.
                    follow_at = None
                    if buttons & curses.BUTTON1_CLICKED:
                        open_tap(screen, session, action, hit, env)
                    else:
                        armed = hit
                elif action == "select":
                    # A repo heading (issue #1032): highlight it, switch nothing.
                    # A typed name / ⌃n now starts there; Esc or a tap on a
                    # session row clears it.
                    follow_at = None
                    selected = hit
                elif action == "jump":
                    selected = hit
                    jump(session, selected, pane, lock)
                # Anywhere else (the input line included) the click only focuses:
                # the bind already moved the keyboard here, so typing follows.
            elif buttons & curses.BUTTON1_RELEASED:
                if armed == HELP_ROW and y == help_y:
                    open_help(screen, env)
                elif armed is not None and hit == armed:
                    open_tap(screen, session, "new" if armed.startswith("hdr:") else "menu",
                             armed, env)
                    refresh_at = 0
                armed = None
            elif buttons & curses.BUTTON4_PRESSED and ids:
                selected = ids[max(0, index - 3)]
            elif buttons & getattr(curses, "BUTTON5_PRESSED", 0) and ids:
                selected = ids[min(len(ids) - 1, index + 3)]


def conf_enabled(conf, enabled):
    """FLEET_SIDEBAR as the fleet conf says NOW, read under the lock (issue #826).

    The shell entry point loads the conf before this process takes the lock, so
    a hook sync fired by a layout change can read `1`, wait out a `hide` that
    writes `0` and removes the view, then recreate it from the stale value.
    `hide`/`toggle` write the conf before taking the lock, so a value read here
    is never older than the last one they applied. No line = keep the caller's
    value (the global conf or the default).
    """
    try:
        text = Path(conf).read_text() if conf else ""
    except OSError:
        return enabled
    for line in text.splitlines():
        match = re.match(r"\s*(?:export\s+)?FLEET_SIDEBAR=(\S*)", line)
        if match:
            enabled = match.group(1).strip("\"'") or "1"
    return enabled


def main():
    if sys.argv[1] == "ui":
        # A lone Escape clears the input line; don't wait ncurses' default 1s.
        os.environ.setdefault("ESCDELAY", "25")
        no_discard()
        curses.wrapper(ui, sys.argv[2], sys.argv[3], sys.argv[4])
        return
    verb, session, lock, enabled, width, key = sys.argv[1:7]
    conf = sys.argv[7] if len(sys.argv) > 7 else ""
    if verb == "key":
        send_key(session, key)
        return
    try:
        width = max(24, min(60, int(width)))
    except ValueError:
        width = 30
    # Kernel-held lock releases even after SIGKILL. Serial hooks re-read the
    # active window, so rapid switching cannot create duplicate/stale views.
    with open(lock, "w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        sync(session, conf_enabled(conf, enabled), width, lock)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.TimeoutExpired, curses.error):
        # A closing pane/server is a normal race for hooks and views.
        sys.exit(0)
