#!/usr/bin/env python3
"""A compact live hub list. One view per attached fleet; no hidden render loops.

The worker keeps tmux's active-pane identity even during keyboard navigation.
That matters: collectors, messages and recovery tools resolve a window to its
active agent pane. Mouse forwarding and the fleet-sidebar key table deliver
input explicitly to this view without changing that identity. A terminal paste
is the one input tmux forwards with no table lookup, to the CLIENT's pane: while
the keyboard is here that pane is this view (issue #1105, PIN_KEY below) — a
per-client pointer, so the window's active pane is still the worker.
"""
import codecs
import curses
import errno
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
VIEW_VERSION = "23"  # #1536: never blank, never frozen — 刷新中…, popup pid, lock wait, watchdog
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
# Never blank, never frozen (issue #1536). The FIRST frame waits this long for
# real rows, then paints 「刷新中…」 over an empty list instead of a blank pane.
FIRST_WAIT = 1.0
# A painted frame older than this (counted from when the view last became
# visible) gets the 「刷新中…」 top row: the last good rows stay, and the row says
# what the view is waiting for.
STALE_SECS = 3
# The watchdog: every WATCHDOG_SECS it checks the frame's age, and past
# STALL_SECS writes one line to logs/sidebar-stall.log and restarts the producer.
WATCHDOG_SECS = 60
STALL_SECS = 5
# A jump waits at most this long for the view lock (a hook sync holds it), then
# gives up for now: the list keeps painting what was pressed, and the jump is
# retried after LOCK_RETRY.
LOCK_WAIT = 0.5
LOCK_RETRY = 0.25
# The input line (issue #896): a refused spawn's reason stays this long, then
# the typed name — which is kept — shows again.
TOAST_SECS = 4


def load_text():
    """Every string this view draws, from THE table (issue #1535): one
    `fleet-ui-lang.sh dump` at start — the shell resolves FLEET_UI_LANG / the
    locale exactly as every other fleet surface does, and a printf argument
    comes back as a \\001 slot for tr() to fill."""
    try:
        out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "sidebar_", "no_repo"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = b""
    parts = out.decode("utf-8", "replace").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


TEXT = load_text()


def tr(key, *args):
    text = TEXT.get(key, key)   # a missing key shows itself, never a blank
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


PLACEHOLDER = tr("sidebar_placeholder")
# The 置顶 group's heading key (issue #1170): selectable so ←/→ can fold it, but
# it names no repo — a tap only highlights it, never opens the new-session popup.
PIN_HEADING = "hdr:pin"
# The one row above the input line (issue #948): a tap on it, or `?` on an empty
# input line, opens this sidebar's key sheet — Claude Code's "? for shortcuts".
# An explicit exception to EPIC #894 convention 5 (no resident rows), chosen by
# the operator: on an iPad a whole row is a tap target a hint glyph is not.
HELP_ROW = tr("sidebar_help_row")
# A Chinese IME turns the `.` and `?` keys into full-width 。/． and ？ (issue
# #965). On an EMPTY input line they are the same keys — the row menu and the
# key sheet — so the operator need not switch to English first; inside a name
# they type as themselves, like `.` and `?` do.
KEY_ALIASES = {"。": ".", "．": ".", "？": "?"}
# The SHELL (bin/fleet-shell.sh, issue #1484) runs this view on a computer with
# no fleet: no conf, no gh, no worktree, and its install ships none of the
# scripts a new task / restore / scratch spawn runs. There every row is on a
# machine, so those keys say so (issue #1518) instead of doing nothing.
SHELL = os.environ.get("FLEET_SHELL") == "1"


def shell_refusal():
    """The toast (text, until) a local-only key shows in the shell."""
    return tr("sidebar_shell_local_only"), time.monotonic() + TOAST_SECS
# The paste route's PIN (issue #1105). tmux forwards a bracketed paste to the
# CLIENT's pane before any key table, so no bind can catch one; under the
# `active-pane` client flag `select-pane` moves that client's own pane instead of
# the window's. Only a command run AS the client can do that — a `select-pane`
# from this process is a session-less CLI client and would move the window's —
# so the conf binds this unpressable key in the fleet-sidebar table to set the
# flag and pin `{top-left}`, and `send-keys -K -c <client> PIN_KEY` runs it as
# the client. `join-pane` forgets a moved pane's client entries: re-pin after a
# follow. In root the same key only drops a stale flag (conf/tmux-attention.conf).
PIN_KEY = "C-M-S-F12"


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
        # `@sidebar_moved`, in the same batch as the join: fit_view's drag test
        # (issue #1521) reads it, so a width that changed after a move — the
        # view left and came back between two of its ticks, and the window was
        # scaled meanwhile — is never taken for the operator's drag.
        commands = ["set-option", "-p", "-t", pane, "@sidebar_moved", str(time.time_ns()), ";",
                    "set-option", "-uw", "-t", source[0], "@sidebar_worker", ";",
                    "set-option", "-w", "-t", window, "@sidebar_worker", worker, ";",
                    "join-pane", "-d", "-h", "-b", "-f", "-l", str(width),
                    "-s", pane, "-t", worker]
    if select:
        if commands:
            commands.append(";")
        commands += ["select-window", "-t", window, ";", "select-pane", "-t", worker]
    return not commands or run(["tmux", *commands]).returncode == 0


def clients(session):
    """(name, key table, pinned) of every client attached to the session."""
    out = []
    for line in tmux("list-clients", "-t", session, "-F",
                     US.join(("#{client_name}", "#{client_key_table}",
                              "#{client_flags}"))).splitlines():
        parts = line.split(US)
        if len(parts) == 3:
            out.append((parts[0], parts[1], "active-pane" in parts[2].split(",")))
    return out


_pin_bound = None


def pin_bound():
    """Whether the server's conf binds PIN_KEY. Unbound — a live server not yet
    reloaded after an upgrade, a selftest fixture — the key would fall through
    to root and reach the worker as bytes, so nothing injects it. Read once: a
    conf reload also replaces this view (VIEW_VERSION)."""
    global _pin_bound
    if _pin_bound is None:
        _pin_bound = run(["tmux", "list-keys", "-T", "fleet-sidebar", PIN_KEY]).returncode == 0
    return _pin_bound


def pin_view(session):
    """Point each navigating client's own pane at the view again (issue #1105):
    the view just moved (join-pane) or was just created, and tmux keeps no
    client entry for either. Run as the client, through PIN_KEY (see it)."""
    if not pin_bound():
        return
    for client, table, _ in clients(session):
        if table == "fleet-sidebar":
            tmux("send-keys", "-K", "-c", client, PIN_KEY)


def route_input(session):
    """The 1s reconcile of the paste route (issue #1105). The binds set the pin
    on every take and drop it on every hand-back they own; a prefix command
    (prefix i, a popup) leaves the table with neither, and its stale pin would
    send a paste — and the first typed key — to this view: drop it. A client
    that is navigating unpinned (an older bind, a hand-rolled switch-client)
    gets pinned, so its paste lands here."""
    for client, table, pinned in clients(session):
        if table == "fleet-sidebar" and not pinned:
            if pin_bound():
                tmux("send-keys", "-K", "-c", client, PIN_KEY)
        elif table == "root" and pinned:
            tmux("refresh-client", "-t", client, "-f", "!active-pane")


def leave_navigation(session):
    # A hidden sidebar must not keep intercepting a client's arrow keys — nor
    # keep its pane pinned as the client's own (issue #1105).
    for client, table, pinned in clients(session):
        if table == "fleet-sidebar":
            tmux("switch-client", "-c", client, "-T", "root")
        if pinned:
            tmux("refresh-client", "-t", client, "-f", "!active-pane")


def sync(session, enabled, width, lock):
    info = fields(session + ":", US.join(("#{window_id}", "#{window_name}",
                  "#{window_width}", "#{session_attached}", "#{@issue}",
                  "#{@raw}", "#{@worktree}", "#{@norepo}", "#{window_zoomed_flag}",
                  "#{@sidebar_width_manual}", "#{@remote}", "#{@remote_view_solo}")))
    if len(info) != 12:
        return
    (window, name, cols, attached, issue, raw, worktree, norepo, zoomed, manual,
     remote, solo) = info
    # A width the operator dragged to (issue #1328) is the width from then on.
    if manual.isdigit():
        width = max(24, min(60, int(manual)))
    all_panes = panes(session)
    workers = [p for p in all_panes if p[1] == window and p[2] != "1" and p[4] != "1"]
    wanted = (enabled == "1" and attached != "0" and
              # This session is another machine's proxy view, and its ONLY client
              # (fleet-remote-view.sh attach, issue #1475): it is drawn inside THAT
              # machine's sidebar, so no list of its own — one list, not two.
              solo != "1" and
              name not in ("plan", "dash", "backlog") and
              # A task: issue worker, repo scratch, a no-repo session in $HOME (#996),
              # or a proxy window onto another machine's session (`@remote`, #1475):
              # the list stays on the left, the other machine's pane on the right.
              # `home` — the fleet's resting window once the full-screen list
              # retired (issue #1533): a shell, but the list's input line is how
              # a fleet with no task yet starts one, so the list shows there too.
              bool(issue or raw == "1" or worktree or norepo == "1" or remote or
                   name == "home") and
              bool(workers) and int(cols) >= width + 1 + 80)
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
            pin_view(session)
            return
        remove_view(reusable[0][0])
    # A reused view must not keep its first worker's worktree alive after moving.
    cwd = str(BIN.parent)
    # tmux spawns the pane from the server environment, not this process's
    # sourced shell environment, so pass UI language explicitly.
    cmd = " ".join(shlex.quote(arg) for arg in (
        "env", "FLEET_UI_LANG=" + os.environ.get("FLEET_UI_LANG", ""),
        "FLEET_SIDEBAR_WIDTH=" + str(width),
        "FLEET_SIDEBAR_WIDTH_MAX=" + os.environ.get("FLEET_SIDEBAR_WIDTH_MAX", ""),
        "python3", str(BIN / "fleet-sidebar.py"), "ui", session, worker, lock))
    pane = tmux("split-window", "-d", "-h", "-b", "-f", "-l", str(width),
                "-t", worker, "-c", cwd, "-P", "-F", "#{pane_id}", cmd)
    if not pane.startswith("%"):
        return
    tmux("set-option", "-p", "-t", pane, "@sidebar", "1", ";",
         "set-option", "-p", "-t", pane, "@sidebar_version", VIEW_VERSION, ";",
         "set-option", "-w", "-t", pane, "@sidebar_worker", worker, ";",
         "set-option", "-p", "-t", pane, "remain-on-exit", "off")
    pin_view(session)


def send_key(session, key):
    if key not in ("Up", "Down", "Left", "Right", "Enter", "Escape", "Home", "End"):
        return
    window = fields(session + ":", "#{window_id}")[0]
    for pane in panes(session):
        if pane[1] == window and pane[2] == "1":
            # Only the marked UI receives these keys, never the worker prompt.
            tmux("send-keys", "-t", pane[0], key)
            return


def lock_within(handle, wait):
    """flock(LOCK_EX) for at most `wait` seconds (issue #1536): a hook sync holding
    the lock must never freeze the list a keypress is waiting on."""
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as error:
            if error.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                raise
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)


def jump(session, window, pane, lock):
    """Switch to `window`. False only when the view lock stayed busy past
    LOCK_WAIT — the caller paints what was pressed and retries."""
    # Another machine's row (`wid:<worker_id>`, #1423): step in through a proxy
    # window (fleet-remote-view.sh, issue #1424), which `open` creates or
    # retargets and prints — then land in it exactly as in a local task window
    # (issue #1475): the view moves along, so the list stays on the left and the
    # other machine's pane is on the right, never the whole window gone remote.
    # With the list taken from the hub (FLEET_SIDEBAR_SOURCE=hub, issue #1480) a
    # row of THIS machine still arrives as its own `@<n>` window id — the producer
    # renders it off its tmux line — so it takes the local path below, unchanged;
    # only a row on another machine is a `wid:`.
    if window.startswith("wid:") and "/" in window:
        env = dict(os.environ, FLEET_SESSION=session)
        out = run(["bash", str(BIN / "fleet-remote-view.sh"), "open", window], env=env,
                  stdin=subprocess.DEVNULL)
        window = out.stdout.strip().split("\n")[-1] if out.returncode == 0 else ""
    # Never resolve a stale row through a recycled index, or another fleet.
    if not window.startswith("@") or fields(window, "#{?#{session_group},#{session_group},#{session_name}}") != [session]:
        return True
    with open(lock, "w") as handle:
        if not lock_within(handle, env_float("FLEET_SIDEBAR_LOCK_WAIT", LOCK_WAIT)):
            return False
        workers = [p for p in panes(session) if p[1] == window and p[2] != "1" and p[4] != "1"]
        if workers:
            worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
            width = fields(pane, "#{pane_width}")[0]
            if width.isdigit() and move_view(pane, worker, int(width), select=True):
                # join-pane forgot the client's pin on the moved view (#1105).
                pin_view(session)
                return True
            tmux("select-window", "-t", window, ";", "select-pane", "-t", worker)
    return True


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


class Ask:
    """One question on the input line (issue #1620, EPIC #1615 C5): what used to
    be a popup with one field — a rename, a new task's title, a repo to add, a
    message or an answer for a row on another machine, the account to switch a
    worker to, the #543 restore question — is asked HERE, on the line the list
    already has, so nothing covers the session being looked at. `kind` picks
    what ↵ runs (submit); `prompt` leads the line; `hint` takes the `?` row
    above it; `choices` ((value, label) pairs) are what Tab steps through — a
    new task's repo in a 2+ repo fleet, a subscription's account; `keys` makes
    it a one-key question (restore: y / r, anything else cancels)."""

    def __init__(self, kind, prompt, arg="", hint="", node="", repo="", keys=""):
        self.kind, self.prompt, self.arg, self.hint = kind, prompt, arg, hint
        self.node, self.repo, self.keys = node, repo, keys
        self.choices, self.at, self.where = [], -1, ""

    def step(self):
        """Tab: the next choice. A repo choice re-targets the task; an account
        choice fills the line (it can still be edited)."""
        if not self.choices:
            return ""
        self.at = (self.at + 1) % len(self.choices)
        value, label = self.choices[self.at]
        if self.kind == "new":
            self.repo = value
            self.hint = new_hint(self)
            return ""
        self.hint = label
        return value


def new_hint(ask):
    """The new task's `?` row: where it goes (repo, machine), and Tab when the
    fleet has more than one repo to choose from."""
    repo = ask.repo or ask.where
    where = repo.rsplit("/", 1)[-1] if repo else tr("no_repo")
    if ask.node:
        where += " @" + ask.node
    return tr("sidebar_ask_to_fmt", where) + (tr("sidebar_ask_tab") if len(ask.choices) > 1 else "")


def ask_new(session, env, repo="", node=""):
    """⌃n, a selected heading's second tap, the menu's 新任务 / 新建到 m4…: an
    issue title on the input line (it was the hub's ⌃n popup). `repo` is the
    anchor row's (selection_repo); with none — or the `no repo` heading, where an
    issue cannot go — a 2+ repo fleet offers its repos on Tab, starting from the
    first; a one-repo fleet leaves it to dash-issue-new.sh, as before."""
    ask = Ask("new", tr("sidebar_ask_new"), node=node, repo="" if repo == "none" else repo)
    if not ask.repo:
        out = run(["bash", "-c", '. "$0/fleet-lib.sh" && fleet_repos "$1"', str(BIN), session], env=env)
        repos = out.stdout.split() if out.returncode == 0 else []
        if len(repos) > 1:
            ask.choices, ask.at, ask.repo = [(r, r) for r in repos], 0, repos[0]
        elif repos:
            ask.where = repos[0]  # the one repo: shown; dash-issue-new.sh resolves it, as before
    ask.hint = new_hint(ask)
    return ask


def start_job(args, env, done):
    """A submitted question's work, off this view's loop: the poll in ui() calls
    `done(rc, output)` when it exits, which answers (toast, next ask) — a
    refusal is one line on the input line, a success says nothing (EPIC #1615).
    Its own session, so the create or the clone in flight outlives a view that
    is restarted under it."""
    out = tempfile.TemporaryFile("w+")
    proc = subprocess.Popen(args, env=env, stdin=subprocess.DEVNULL, stdout=out,
                            stderr=subprocess.STDOUT, start_new_session=True)
    proc.out, proc.done = out, done
    return proc


def last_line(text):
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    return lines[-1] if lines else ""


def quiet(rc, text):
    """The script toasts its own outcome (or has none to tell)."""
    return "", None


def failed(rc, text):
    """A refusal's last line, only when it refused."""
    return ("✗ " + last_line(text).lstrip("✗ ") if rc != 0 and last_line(text) else ""), None


def repo_added(rc, text):
    """dash-repo-add.sh: its verdict line (stderr) comes before the result token
    (stdout); `added:` says nothing — the heading appears."""
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if lines and lines[-1].startswith("added:"):
        return "", None
    verdict = next((l for l in reversed(lines[:-1]) if not re.match(r"^(added|refused|failed):", l)), "")
    return verdict or (lines[-1] if lines else tr("sidebar_spawn_failed")), None


def sub_choices(ask):
    """fleet-manual-sub.sh list → the accounts Tab steps through, each with its
    fresh quota on the `?` row; a refusal (no fresh quota) is the row itself."""
    def done(rc, text):
        rows = [l.split("\t") for l in text.splitlines()[1:] if l.count("\t") >= 3]
        if rc != 0 or not rows:
            ask.hint = "✗ " + (last_line(text) or tr("sidebar_spawn_failed"))
            return "", None
        ask.choices = [(r[0], " · ".join(x for x in (r[0], "5h " + r[1] if r[1] else "", "7d " + r[2] if r[2] else "", r[3]) if x))
                       for r in rows]
        ask.hint = tr("sidebar_ask_sub_hint")
        return "", None
    return done


def restore_asked(session, target):
    """fleet-restore-pick.sh --ask: exit 4 with the question on stdout when the
    restore must ask first (#543, a CLOSED-unmerged PR) — asked as a one-key
    question; any other exit restored it, or says why not."""
    def done(rc, text):
        if rc == 4:
            return "", Ask("restore", tr("sidebar_ask_restore"), arg=target,
                           hint=last_line(text), keys="yYrR")
        return failed(rc, text)
    return done


def submit(ask, text, session, env):
    """↵ (or a one-key answer) on a question: the job that does it, or None when
    there is nothing to do (an empty line cancels, as an empty name always has)."""
    if ask.kind == "restore":
        return start_job(["bash", str(BIN / "fleet-restore-pick.sh"), "--select", ask.arg,
                          "--session", session, "--answer", text.lower()], env, failed)
    if not text:
        return None
    if ask.kind == "rename":
        run(["bash", str(BIN / "dash-rename.sh"), "--wid", ask.arg, text], env=env)
        return None
    if ask.kind == "new":
        # The title is arbitrary text: it travels in a file (the mktemp the
        # popup used), never on a command line any shell parses.
        handle, path = tempfile.mkstemp(prefix="dash-new.", dir=os.environ.get("TMPDIR") or "/tmp")
        with os.fdopen(handle, "w") as out:
            out.write(text)
        return start_job(["env"] + (["CF_REPO=" + ask.repo] if ask.repo else []) +
                         ["bash", str(BIN / "dash-issue-new.sh"), "confirm", "--spawn", "--title-file=" + path] +
                         (["--node=" + ask.node] if ask.node else []), env, quiet)
    if ask.kind == "repo":
        return start_job(["bash", str(BIN / "dash-repo-add.sh"), "--session", session, text], env, repo_added)
    if ask.kind in ("message", "answer"):
        return start_job(["bash", str(BIN / "fleet-sidebar-remote.sh"), ask.kind, session, ask.arg],
                         dict(env, FLEET_SIDEBAR_TEXT=text), quiet)
    if ask.kind == "sub":
        return start_job(["bash", str(BIN / "dash-migrate.sh"), ask.arg, "to", text], env, failed)
    return None


def no_discard():
    """macOS's line discipline eats ⌃o as VDISCARD (flush output) even in cbreak
    mode, so the `restore` byte never reached getch. Switch that one character
    off before curses saves the tty modes, so an endwin/refresh keeps it off.
    The same for ⌃s (`scratch`, issue #1532): with IXON on it is XOFF and
    freezes this pane's output until a ⌃q — and ⌃t (`view`), BSD's VSTATUS."""
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


def open_help(screen, env):
    """The sidebar's `?` sheet (issue #948): fleet-keys.sh --context sidebar in
    a popup via dash-popup.sh (explicit client, the @popup_open epoch), exactly
    as the hub's `?` opens its own. Blocks until q/Esc closes it, which is the
    pause: nothing repaints under the popup. Leave curses meanwhile: with no
    client dash-popup.sh runs the sheet INLINE, in this pane.
    Sized to the sheet (issue #963): title + blank + eight rows (#1532) + the border,
    as wide as the editing row (#1097)."""
    curses.endwin()
    subprocess.call(["bash", str(BIN / "dash-popup.sh"), "-w", "50", "-h", "12", "--title", "popup_keys", "--",
                     "bash", str(BIN / "fleet-keys.sh"), "--context", "sidebar"], env=env)
    screen.clear()


def open_tap(session, action, key, env):
    """A second tap (issue #1032): a session row's menu, or — on a selected
    heading — a new task's title on the input line with that repo pinned
    (selection_repo resolves `hdr:…` exactly as it does for a typed name, so both
    paths agree on the target). Returns that Ask; "refused" when the shell
    refuses it (issue #1518); None after opening a menu."""
    if action == "new":
        if SHELL:
            return "refused"
        return ask_new(session, env, selection_repo(session, key, env))
    open_menu(session, key, env)
    return None


def open_menu(session, wid, env):
    """The row's action menu (issue #898). fleet-sidebar.sh owns every tmux
    command string in it; this only names the row, by its stable window id.
    Not waited on: a tmux display-menu can hold its caller until it closes, and
    this view keeps painting meanwhile."""
    # A row on another machine (`wid:…`) has one too (issue #1475): its title
    # names the machine (`<name> · 在 m4`) — the one place the list says it.
    if wid.startswith("@") or (wid.startswith("wid:") and "/" in wid):
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


def width_of(text):
    return sum(cells(char) for char in text)


def row_left(marker, glyph, tree, name):
    """`marker glyph tree name` (issue #836): the tree is the producer's indent +
    `└` + caret (issue #1328), so a child's name starts two cells right of its
    parent's, one level per generation."""
    return marker + " " + glyph + " " + (tree or " ") + " " + name


def row_right(badge, info=""):
    """What sits at a row's right edge: the subtree badge (`· k/N`), then — while
    the info column is open (⌃i, issue #1532) — `info_text`. A row on
    another machine shows NO machine name (issue #1475, the operator's call): a
    local row and a remote row look the same; the machine is in the row menu's
    title (fleet-sidebar-menu.sh) and the status line on top."""
    return " ".join(part for part in ("· " + badge if badge else "", info) if part)


# The info column (issue #1532): the hub's issue · PR · ctx% cells, which the
# producer hands every session row as fields 10-12. Fixed widths, so the three
# line up down the list; folded away by default — the width goes to the names.
INFO_WIDTHS = (5, 7, 4)


def info_text(row):
    """A session row's `#1532  #1552✓  45%`, or "" (a heading, a landed row, a
    row from a producer that predates the fields)."""
    if row[0] == "hdr" or len(row) < 12 or not any(row[9:12]):
        return ""
    return " ".join(" " * max(0, size - width_of(cell)) + cell
                    for cell, size in zip(row[9:12], INFO_WIDTHS))


def row_text(marker, glyph, tree, name, badge, width, info=""):
    """A session row laid out to `width` cells (issue #1328). The subtree badge
    (`· k/N`) is right-aligned and ALWAYS whole; the name gets what is left and,
    when it does not fit, ends in `…`. A narrow pane gives up name, never the
    count — the old joined label was clipped from the right, so the count went
    first. A row with no badge and a name that fits is exactly the old line."""
    left = row_left(marker, glyph, tree, "")
    right = row_right(badge, info)
    room = width - width_of(left) - (width_of(right) + 1 if right else 0)
    if width_of(name) > room:
        name = clip(name, max(0, room - 1)) + "…" if room > 0 else ""
    text = left + name
    if right:
        text += " " * max(1, width - width_of(text) - width_of(right)) + right
    return text


def row_need(row, info=False):
    """The cells `row` needs to show whole, plus the one the paint keeps free —
    its info column too while that is open."""
    wid, _state, glyph, name, tree, badge = row[:6]
    if wid == "hdr":
        return 0 if name.startswith("──") else width_of(name) + 1
    need = width_of(row_left(" ", glyph, tree, name)) + 1
    right = row_right(badge, info_text(row) if info else "")
    need += width_of(right) + 1 if right else 0
    return need + (2 if len(row) > 8 and row[8].endswith("~") else 0)   # the ⇄ cell (#1488)


def auto_width(rows, cols, base, top, info=False):
    """The width the view wants for `rows` in a `cols`-wide window (issue #1328):
    its longest row, between `base` (FLEET_SIDEBAR_WIDTH, 30) and `top`
    (FLEET_SIDEBAR_WIDTH_MAX, 44), and never past a quarter of the window nor into
    the worker's 80 columns (move_view's rule) — but never under `base`, which is
    what the view was opened at. An open info column (issue #1532) widens it
    within the same `top`: past that, the names give way."""
    want = max([base] + [row_need(row, info) for row in rows])
    want = min(want, top, cols // 4, cols - 81)
    return max(base, want)


def detail_line(row):
    """The selected row's line above the input (issue #1328): its WHOLE name, for
    a row whose name the list clipped. Which `!` it is and why a ↻ waits (row[7])
    moved to the worker pane's header, @title_info (issue #1377) — a parent row
    almost always carries one, and it took the `?` line from the hints."""
    return " " + row[3]


def hint_line(row, width, info=False):
    """What takes the `?` row for the selected `row` in a `width`-wide view: its
    whole name when the list clipped it, else None (`? 快捷键` stays)."""
    if row is not None and row_need(row, info) > max(0, width - 1):
        return detail_line(row)
    return None


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
    CSI sequence is swallowed (-1) rather than typed as `[1;2A`. ESC[200~ opens
    a bracketed paste (issue #1105; the view asks for it): its text, up to the
    ESC[201~ tmux writes after the last byte, comes back as a str."""
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
    """A paste as ONE name for the input line: line breaks and tabs become
    spaces (a pasted paragraph must not submit at its first newline), the end
    of the paste loses its newline, other controls are dropped."""
    text = text.rstrip("\r\n")
    text = re.sub(r"[\r\n\t]+", " ", text)
    return "".join(c for c in text if typed(c))


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


def spawn_scratch(name, env, repo="", selection="", node=""):
    """The hub's ⌃s with a name (issue #896): the same script and the same
    provenance (`--origin hub` — the sidebar sits in a worker's window, and a
    session started here is not that worker's child). Focus follows the new
    window, and the window-changed hook moves this view there. stderr (the
    refusal reason) goes to a file, not a pipe: whatever the spawn leaves running
    would hold a pipe open, and reading it would freeze this view. `repo` (the
    highlighted row's, issues #1009/#997) goes as --repo, `none` as --no-repo;
    empty keeps dash-raw-session.sh's own resolution.
    The sidebar's own ⌃s (issue #1532) is the hub's ⌃s: no name, the
    highlighted row as --selection. Not --bg: this view already polls the spawn
    without blocking, and the foreground run keeps the `…` up until the window
    exists and hands back the whole refusal. `node` (a new task's «新建到 m4…»,
    ⌃s on its title line) opens it on that machine (#1541)."""
    log = tempfile.TemporaryFile("w+")
    args = (["--selection", selection] if selection else []) + (["--node=" + node] if node else [])
    proc = subprocess.Popen(
        ["bash", str(BIN / "dash-raw-session.sh")] + (["--name", name] if name else []) +
        args + ["--origin", "hub"] +
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
    opens in $HOME). "" for anything that is not a heading with a spawn target —
    the 置顶 heading (`hdr:pin`, issue #1170) included: it folds, it names no repo."""
    if not key.startswith("hdr:") or key == PIN_HEADING:
        return ""
    repo = key[4:]
    return tr("no_repo") if repo == "none" else repo.rsplit("/", 1)[-1]


def placeholder(key):
    """The empty input line's hint: it names the destination whenever a heading
    is selected (issue #1032), so where a typed name goes is never a guess."""
    name = target_name(key)
    return tr("sidebar_new_to_fmt", name) if name else PLACEHOLDER


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
    if hit == PIN_HEADING:
        return "select"  # a fold stop only (issue #1170): no repo to open a session in
    if hit.startswith("hdr:"):
        return "new" if hit == highlighted else "select"
    return "menu" if hit == highlighted else "jump"


def acts(key):
    """The highlighted row as a target for any action but a new session or a fold:
    a heading (`hdr:…`) is none — jump, menu, tap all stay no-ops on it (EPIC #994)
    — and so is a landed row (`landed:…`, issue #1532): its one action is ↵,
    restore, which the landed view handles itself."""
    return "" if key.startswith(("hdr", "landed:")) else key


def folds(key):
    """The highlighted row as a ←/→ target: a session row (its subtree), or a repo
    heading with a spawn target — `hdr:<target>`, which dash-fold-toggle.sh reads
    as that repo's whole group (issue #1037). A bare `hdr` (the `?` heading, the
    empty-state hint) or no row at all: nothing to fold."""
    return key if key and key != "hdr" else ""


# ←/→ fold AT ONCE (issue #1530): the view applies the fold to the rows it has
# and paints them, then dash-fold-toggle.sh writes the bit and the producer's next
# frame — the first one read after the write — corrects whatever the guess got
# wrong. The guess mirrors the producer's rules (tmux-dashboard-rows.sh): a block
# is the rows nested deeper than its row, or under a heading every row to the
# next heading; `←` shuts the innermost OPEN block the cursor is in; a `needs` /
# `failed` row and the current window never fold away. An opened block is drawn
# from the rows last seen in it (`cache`), so children appear in the same frame
# as the caret turns — none cached (never seen open), the caret turns and the
# producer brings them.
FOLD_KEEP = ("needs", "failed")  # rk 0 in the producer: the loud layer never folds


def row_depth(row):
    return int(row[6]) if len(row) > 6 and row[6].isdigit() else 0


def owns_fold(row):
    """A row with a block to fold: a heading, or a session row with a caret."""
    return row[0] == "hdr" or row[4].endswith(("▾", "▸"))


def fold_open(row):
    return not row[3].startswith("▸ ") if row[0] == "hdr" else row[4].endswith("▾")


def with_fold(row, opened):
    row = list(row)
    if row[0] == "hdr":
        name = row[3][2:] if row[3].startswith("▸ ") else row[3]
        row[3] = name if opened else "▸ " + name
    else:
        row[4] = row[4][:-1] + ("▾" if opened else "▸")
    return row


def block_end(rows, i):
    """One past the last row of rows[i]'s block."""
    heading, depth, j = rows[i][0] == "hdr", row_depth(rows[i]), i + 1
    while j < len(rows) and rows[j][0] != "hdr" and (heading or row_depth(rows[j]) > depth):
        j += 1
    return j


def remember_folds(rows, cache):
    """Keep every OPEN block's rows, for drawing it again the moment it reopens."""
    for i, row in enumerate(rows):
        key = key_of(row)
        if key != "hdr" and owns_fold(row) and fold_open(row):
            end = block_end(rows, i)
            if end > i + 1:
                cache[key] = rows[i + 1:end]


def fold_now(rows, key, verb, current, cache):
    """The ←/→ guess: (rows, holder) — holder is the row whose block opened or
    shut, None when this key folds nothing here (the producer still decides)."""
    keys = [key_of(row) for row in rows]
    if not key or key.startswith("wid:") or key not in keys:
        return rows, None
    i = keys.index(key)
    if verb == "expand":
        if not owns_fold(rows[i]) or fold_open(rows[i]):
            return rows, None
        end = block_end(rows, i)
        shown = {row[0]: row for row in rows[i + 1:end]}
        kids = [shown.get(row[0], row) for row in cache.get(key, [])]
        have = {row[0] for row in kids}
        kids += [row for row in rows[i + 1:end] if row[0] not in have]
        return rows[:i] + [with_fold(rows[i], True)] + kids + rows[end:], key
    j = i
    if rows[i][0] != "hdr":
        while not (owns_fold(rows[j]) and fold_open(rows[j])):
            depth = row_depth(rows[j])
            k = j - 1
            while k >= 0 and rows[k][0] != "hdr" and row_depth(rows[k]) >= depth:
                k -= 1
            if depth == 0 or k < 0 or rows[k][0] == "hdr":
                return rows, None
            j = k
    elif not fold_open(rows[i]):
        return rows, None
    end = block_end(rows, j)
    hidden = rows[j + 1:end]
    if hidden:
        cache[key_of(rows[j])] = hidden
    keep = [row for row in hidden if row[1] in FOLD_KEEP or row[0] == current]
    return rows[:j] + [with_fold(rows[j], False)] + keep + rows[end:], key_of(rows[j])


def start_rows(env):
    """Launch the row producer without waiting for it (issue #1033). Output goes
    to a file, not a pipe: a full pipe would stall a producer this loop only
    polls. `started` bounds a hung one."""
    out = tempfile.TemporaryFile("w+")
    proc = subprocess.Popen(["bash", str(BIN / "tmux-dashboard-rows.sh"), "--sidebar"],
                            env=dict(env), stdin=subprocess.DEVNULL, stdout=out,
                            stderr=subprocess.DEVNULL, text=True)
    proc.out, proc.started, proc.stale, proc.failure = out, time.monotonic(), False, ""
    proc.current, proc.view, proc.parse = env["FLEET_SIDEBAR_CURRENT"], "live", None
    return proc


# The landed list (issue #1532): ⌃t swaps the running list for the hub's own
# landed view, read from the ledger that view reads — `fleet-history.sh rows`,
# what tmux-dashboard-rows.sh execs into on the hub's ⌃t. It changes when a
# session lands, not every second: read on the switch, on ⌃r, and every
# LANDED_SECS while it is shown.
LANDED_SECS = 10
NEVER = float("-inf")  # "read it now": a monotonic clock may start near 0
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# A landed row's fixed left block — glyph · issue · tree · name, 38 cells
# (fleet-history.sh cmd_rows LEFTW): the rest is the hub's wide right columns.
LANDED_LEFT = 38


def start_landed(env):
    """The landed producer, launched like start_rows (a file, never a pipe)."""
    out = tempfile.TemporaryFile("w+")
    proc = subprocess.Popen(["bash", str(BIN / "fleet-history.sh"), "rows"],
                            env=dict(env, FZF_COLUMNS="120"), stdin=subprocess.DEVNULL,
                            stdout=out, stderr=subprocess.DEVNULL, text=True)
    proc.out, proc.started, proc.stale, proc.failure = out, time.monotonic(), False, ""
    proc.current, proc.view, proc.parse = env["FLEET_SIDEBAR_CURRENT"], "landed", landed_rows
    return proc


def landed_rows(text):
    """`fleet-history.sh rows` as the view's rows: a heading that says which list
    this is, then one row per `landed:…` target — its glyph, and the issue +
    name the hub's left block shows, whitespace folded so it fits 30 columns.
    The target is the row's key: ↵ hands it to the restore, as the hub's ⌃o."""
    rows = []
    for line in text.split("\n"):
        parts = line.split(US, 2)
        if len(parts) < 3 or not parts[0].startswith("landed:"):
            continue  # the column header, the "(no landed sessions…)" filler
        glyph, _, name = " ".join(head(ANSI.sub("", parts[2]), LANDED_LEFT).split()).partition(" ")
        rows.append([parts[0], "landed", glyph, name, " ", "", "0"] + [""] * (ROW_FIELDS - 7))
    pad = [""] * (ROW_FIELDS - 4)
    top = ["hdr", "", "", tr("sidebar_landed_heading_fmt", len(rows))] + pad
    return [top] + (rows or [["hdr", "", "", tr("sidebar_landed_empty")] + pad])


def restore_landed(session, target, env):
    """↵ on a landed row: the hub's ⌃o for that target, with focus — the picker's
    own step after a pick (fleet-restore-pick.sh --select), in the background. A
    row that may have to ask first (`landed:issue:…`, a CLOSED-unmerged PR —
    #543) asks on the input line (--ask, issue #1620): the job is returned so the
    loop can turn its exit 4 into the question; nothing else needs a terminal."""
    cmd = ["bash", str(BIN / "fleet-restore-pick.sh"), "--select", target, "--session", session]
    if target.startswith("landed:issue:"):
        return start_job(cmd + ["--ask"], env, restore_asked(session, target))
    subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)
    return None


def drop_rows(proc):
    """Abandon a producer in flight: its list is no longer the one shown."""
    if proc is not None:
        proc.kill()
        proc.wait()
        proc.out.close()


def collect_rows(proc):
    """A finished producer's rows, or None (failed, killed, still running)."""
    if proc.poll() is None:
        if time.monotonic() - proc.started < PRODUCER_TIMEOUT:
            return None
        proc.kill()
        proc.wait()
        proc.failure = "producer hung %ds, killed" % PRODUCER_TIMEOUT
    proc.out.seek(0)
    text = proc.out.read()
    proc.out.close()
    if proc.returncode != 0:
        if not getattr(proc, "failure", ""):
            proc.failure = "producer exit %d" % proc.returncode
        return None
    if proc.parse is not None:
        return proc.parse(text)
    return [row_fields(line) for line in text.split("\n") if line.count(US) >= 4]


# wid state glyph name tree badge depth detail node issue pr ctx (issues #1328,
# #1475, #1532)
ROW_FIELDS = 12


def row_fields(line):
    """One producer line as its ROW_FIELDS fields: a heading's line stops at its
    tree field (5), a session row's carries the badge / depth / detail and, last,
    its machine — empty for a local row, `m4` for a row on another machine, `m4!`
    when that machine is lost (issue #1475), `m5~` when the row came over the
    shell's own connection to it while the hub is silent (issue #1488). The view
    never DRAWS the machine (the rows look alike); `!` dims the row, `~` ends it
    in a dim ⇄, and the menu titles it."""
    parts = line.split(US, ROW_FIELDS - 1)
    return parts + [""] * (ROW_FIELDS - len(parts))


def env_int(name, default):
    try:
        return int(os.environ.get(name) or default)
    except ValueError:
        return default


def env_float(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return default


def fit_plan(pw, ww, window, zoomed, manual, rows, sized, moved="", info=False):
    """What holds the view's width (issues #1328, #1521), as (action, sized):
    action is ("manual", w) — record w as the operator's width — or ("resize", w)
    — one resize-pane — or None; `sized` is the (pane width, window width,
    window, move stamp) the view is at after it, or the old one when there is
    nothing to do. Pure (no tmux), so the selftest pins every branch.

    The width is `@sidebar_width_manual` once the operator has dragged to one,
    else auto_width for the rows — and EITHER is re-applied when the pane left
    it. tmux scales every pane in proportion when a window takes a client's
    size (`window-size latest`: a 210-column window first shown on a 189-column
    client), and before #1521 a manual width was never corrected, so the list
    sat at 26 until the next move brought back 37 — a width that jumped on every
    switch. A drag is the one width change that is the operator's: the pane
    moved while the view stayed in the same window (`moved`, move_view's stamp,
    unchanged — the view may have left and come back since the last tick) at
    the same window width. Zoomed, or a window too narrow to keep the worker's
    80 columns beside the width: nothing (sync hides the view below that anyway)."""
    if zoomed:
        return None, sized
    if sized is not None and sized[1:] == (ww, window, moved) and sized[0] != pw:
        return ("manual", pw), (pw, ww, window, moved)
    if manual.isdigit():
        want = max(24, min(60, int(manual)))
    else:
        base = max(24, min(60, env_int("FLEET_SIDEBAR_WIDTH", 30)))
        want = auto_width(rows, ww, base, max(base, env_int("FLEET_SIDEBAR_WIDTH_MAX", 44)), info)
    if want != pw and ww >= want + 81:
        return ("resize", want), (want, ww, window, moved)
    return None, (pw, ww, window, moved)


def fit_view(session, pane, rows, sized, wide=False):
    """Apply fit_plan to the view: at most one tmux write a tick, and none at all
    while the pane is at the width it wants — the ONE writer of the view's width
    (a hook-driven sync has no memory of the last fit, so it could not tell the
    operator's drag from tmux's scaling and would undo the drag). `sized` is what
    this function last left the view at; returns the next. `wide`: the info
    column is open (issue #1532)."""
    info = fields(pane, US.join(("#{pane_width}", "#{window_width}", "#{window_id}",
                                 "#{window_zoomed_flag}", "#{@sidebar_width_manual}",
                                 "#{@sidebar_moved}")))
    if len(info) != 6 or not info[0].isdigit() or not info[1].isdigit():
        return sized
    action, sized = fit_plan(int(info[0]), int(info[1]), info[2], info[3] == "1",
                             info[4], rows, sized, info[5], wide)
    if action is None:
        return sized
    if action[0] == "manual":
        tmux("set-option", "-t", "=" + session + ":", "@sidebar_width_manual", str(action[1]))
        return sized
    tmux("resize-pane", "-t", pane, "-x", str(action[1]))
    got = fields(pane, "#{pane_width}")[0]
    return (int(got) if got.isdigit() else sized[0],) + sized[1:]


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True  # EPERM: it exists, under another uid
    return True


def popup_up(popup, holder, now):
    """Is a popup over the client (the @popup_open epoch)? Event-driven where it
    can be (issue #1536): dash-popup.sh stamps `@popup_pid <epoch>:<pid>`, and a
    holder that is gone — closed, or SIGKILLed past its trap — ends the pause at
    once. A flag with no holder of ITS epoch (a prefix bind's popup) keeps the
    old 30-second bound, so a stale flag still cannot freeze the list."""
    try:
        age = now - int(popup)
    except ValueError:
        return False
    if not 0 <= age < 30:
        return False
    epoch, _, pid = holder.partition(":")
    if epoch == popup and pid.isdigit():
        return alive(int(pid))
    return True


def visible(info, now):
    if len(info) not in (4, 5):
        return False
    active, zoomed, attached, popup = info[:4]
    modal = popup_up(popup, info[4] if len(info) == 5 else "", now)
    return active == "1" and zoomed != "1" and attached != "0" and not modal


def palette(path=None):
    """conf/fleet-palette.conf, the fleet's ONE colour table (issue #1534) →
    {"PAL_BLUE": "#rrggbb", …}. The same line rule as bin/fleet-palette.sh:
    `%hidden PAL_<NAME>='#rrggbb'`; a missing file is an empty table."""
    table = {}
    try:
        text = Path(path or BIN.parent / "conf" / "fleet-palette.conf").read_text(encoding="utf-8")
    except OSError:
        return table
    for line in text.splitlines():
        m = re.match(r"(?:%hidden\s+)?(PAL_[A-Z_]+)='(#[0-9a-fA-F]{6})'", line.strip())
        if m:
            table[m.group(1)] = m.group(2)
    return table


def xterm256(hexcolor):
    """The xterm-256 index nearest a `#rrggbb` — the 6×6×6 cube or the grey ramp,
    whichever is closer. curses cannot draw truecolour (tmux's terminfo cannot
    redefine a colour), so this is how the sidebar draws the palette's colours."""
    rgb = [int(hexcolor[i:i + 2], 16) for i in (1, 3, 5)]
    steps = (0, 95, 135, 175, 215, 255)
    cube = [min(range(6), key=lambda i, v=v: abs(steps[i] - v)) for v in rgb]
    cube_dist = sum((steps[c] - v) ** 2 for c, v in zip(cube, rgb))
    grey = max(0, min(23, round((sum(rgb) / 3 - 8) / 10)))
    grey_dist = sum((8 + 10 * grey - v) ** 2 for v in rgb)
    if grey_dist < cube_dist:
        return 232 + grey
    return 16 + 36 * cube[0] + 6 * cube[1] + cube[2]


# A terminal of fewer than 256 colours cannot show the palette at all; it gets the
# basic colour each palette name stands for — the sidebar's colours before #1534.
# -1 is the terminal's own colour: text and dim text keep it there (dim then
# comes from A_DIM, see `dim_attr`).
PALETTE_BASIC = {"PAL_FG": -1, "PAL_DIM": -1, "PAL_SEL": curses.COLOR_BLUE,
                 "PAL_CYAN": curses.COLOR_CYAN, "PAL_RED": curses.COLOR_RED,
                 "PAL_GREEN": curses.COLOR_GREEN, "PAL_MAGENTA": curses.COLOR_MAGENTA}

# The sidebar's colour pairs (issue #1622): a row's TEXT is one colour (PAL_FG,
# or PAL_DIM for a dim one) and only its state glyph carries the state's colour
# — the red 「等你」 dot is no longer drowned in rows painted whole. The current
# row and the keyboard's row share one quiet PAL_SEL ground, told apart by ▶ / ›.
# {pair: (fg, bg)}, None = the terminal's default.
STATE_PAIR = {"working": 1, "needs": 2, "done": 3, "looping": 4}
STATE_COLOR = {"working": "PAL_CYAN", "needs": "PAL_RED", "done": "PAL_GREEN",
               "looping": "PAL_MAGENTA"}
PAIR_SEL, PAIR_TOAST, PAIR_FG, PAIR_DIM, SEL_GLYPH = 5, 7, 8, 9, 10
PAIRS = {PAIR_SEL: ("PAL_FG", "PAL_SEL"), PAIR_TOAST: ("PAL_RED", None),
         PAIR_FG: ("PAL_FG", None), PAIR_DIM: ("PAL_DIM", None)}
for _state, _pair in STATE_PAIR.items():
    PAIRS[_pair] = (STATE_COLOR[_state], None)
    PAIRS[_pair + SEL_GLYPH] = (STATE_COLOR[_state], "PAL_SEL")


def palette_colors(table, colors):
    """{name: curses colour number} for every name the sidebar draws with."""
    return {name: xterm256(table[name]) if colors >= 256 and name in table else basic
            for name, basic in PALETTE_BASIC.items()}


def shown_row(window, remote):
    """The row the current window stands for: itself — or, in a proxy window onto
    another machine's session (`@remote=<node>:<worker_id>`, issue #1475), that
    machine's row `wid:<worker_id>`, so the ▶ and the cursor land on it."""
    return "wid:" + remote.split(":", 1)[1] if ":" in remote else window


def stall_log(session, pane, reason, result):
    """One line per stall (issue #1536): time · view · why · what self-heal did."""
    path = Path(os.environ.get("FLEET_SIDEBAR_STALL_LOG") or BIN.parent / "logs" / "sidebar-stall.log")
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as log:
            log.write("%s · %s %s · %s · %s\n" % (stamp, session, pane, reason, result))
    except OSError:
        pass


def ui(screen, session, worker, lock):
    pane = os.environ["TMUX_PANE"]
    window, remote = (fields(worker, US.join(("#{window_id}", "#{@remote}"))) + ["", ""])[:2]
    current_row = shown_row(window, remote)
    env = dict(os.environ, FLEET_SESSION=session, FLEET_SIDEBAR_CURRENT=window)
    curses.curs_set(0)
    curses.use_default_colors()
    pal = palette_colors(palette(), curses.COLORS)
    for number, (fg, bg) in PAIRS.items():
        curses.init_pair(number, pal[fg] if fg else -1, pal[bg] if bg else -1)
    # Dim text is PAL_DIM; a terminal with no palette colour for it dims instead.
    dim_attr = curses.color_pair(PAIR_DIM) | (curses.A_DIM if pal["PAL_DIM"] == -1 else 0)
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
    curses.mouseinterval(0)
    screen.keypad(True)
    curses.meta(True)
    # Bracketed paste (issue #1105): with it on, tmux writes a paste as
    # ESC[200~ … ESC[201~ (input_key drops the markers for a pane without it),
    # so a pasted paragraph is one insert, not a line typed and submitted per
    # newline. Written past curses: it never touches this private mode.
    os.write(1, b"\x1b[?2004h")
    rows, selected, offset, refresh_at = [], current_row, 0, 0.0
    help_shown, sized = True, None
    shown, navigation, follow_at = False, False, None
    # The input line (issue #896). Keys arrive as BYTES through the fleet-sidebar
    # table's Any bind; decode them here, so a CJK name survives whatever locale
    # tmux started this pane under.
    line, toast, toast_until, spawning = Line(), "", 0.0, None
    # A press on the already-highlighted row arms the menu; its RELEASE opens it
    # (issue #898). Opening on the press would lose the menu at once: tmux closes
    # a menu on a button release outside it, and that release is this tap's own.
    armed = None
    # A question on the input line (issue #1620, the Ask class): the menu's 改名
    # (issue #898 — the name goes to dash-rename.sh as an argv word; no tmux or
    # shell parser ever sees it), ⌃n's title, 加仓库, a remote row's message or
    # answer, 切换 sub, the #543 restore question. `jobs`: what a submitted one
    # runs, polled below — its refusal comes back as a toast.
    asking, jobs = None, []
    decoder = codecs.getincrementaldecoder("utf-8")("ignore")
    mark_input(pane, "")
    published = None  # the (window, candidates) last written to @sidebar_next
    # The row producer in flight (issue #1033), and whether any run has landed:
    # only the FIRST frame waits for one — every later frame paints the last
    # good rows, so a jump's `▶` moves as soon as the pane has.
    producer, loaded = None, False
    # ←/→ (issue #1530): the toggle writing the fold bit, and the blocks last seen
    # open — no producer starts until the toggle has written, so the next frame
    # is the first one read after it.
    folding, fold_cache = None, {}
    # Never blank, never frozen (issue #1536): when the painted rows landed, when
    # the view last became visible (a hidden view's frame does not age), why the
    # last refresh gave nothing, whether one empty frame was held back, the
    # watchdog's next check, and whether this stall is already logged.
    frame_at, shown_at, failure, empty_held, stalled = None, None, "", False, False
    watch_at = time.monotonic() + env_float("FLEET_SIDEBAR_WATCHDOG_SECS", WATCHDOG_SECS)
    # The full-screen list's own actions (issue #1532): which list is shown
    # (⌃t: `live` ⇄ `landed`), the live rows kept while the landed one is up so
    # ⌃t back paints at once, when the landed rows were last read (⌃r: now), and
    # whether the info column is open (⌃i).
    view, live_rows, landed, landed_at, wide = "live", [], None, NEVER, False
    while True:
        now = time.monotonic()
        if folding is not None and folding.poll() is not None:
            folding, refresh_at = None, 0
        if producer is not None and (producer.poll() is not None or
                                     now - producer.started >= PRODUCER_TIMEOUT):
            fresh, current, stale = collect_rows(producer), producer.current, producer.stale
            failure = producer.failure if fresh is None else failure
            made, producer = producer.view, None
            if made != view:
                # Read for the list ⌃t just switched away from: read again now.
                refresh_at = 0
            elif made == "landed":
                if fresh is not None:
                    rows, landed = fresh, fresh
                landed_at = now
            elif stale and loaded:
                # Started before something this view did (a fold, a jump, a menu
                # action): its rows would undo what is painted. Read again now.
                refresh_at = 0
            elif current != window:
                # Read against a window this view has since left: its fold
                # exemptions are for the wrong row. Drop it, read again now.
                refresh_at = 0
            elif fresh is not None and not fresh and rows and not empty_held:
                # An empty frame never blanks a painted list on its own (issue
                # #1536): a producer that caught tmux mid-change can print
                # nothing. Keep the rows; the next run, at once, decides.
                empty_held, failure, refresh_at = True, "empty frame", 0
            elif fresh is not None:
                rows, loaded, frame_at, failure, empty_held, stalled = fresh, True, now, "", False, False
                remember_folds(rows, fold_cache)
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
                reason = error[-1] if error else tr("sidebar_spawn_failed")
                toast = "✗ " + reason.split(": ", 1)[-1]
                toast_until = now + TOAST_SECS
            spawning = None
            refresh_at = 0
        for job in [j for j in jobs if j.poll() is not None]:
            jobs.remove(job)
            job.out.seek(0)
            said, nxt = job.done(job.returncode, job.out.read())
            job.out.close()
            if said:
                toast, toast_until = said, now + TOAST_SECS
            if nxt is not None and asking is None and spawning is None:
                asking = nxt
                line.clear()
                mark_input(pane, "1")
            refresh_at = 0
        if follow_at is not None and now >= follow_at:
            # The highlight settled: switch once. Nothing here touches the
            # client's key table, and the Up/Down binds re-enter fleet-sidebar
            # before their key arrives, so ↑↓ keep browsing after the switch;
            # Enter/Escape (whose binds do not re-enter) still hand input back.
            follow_at = None
            if acts(selected) and selected != window:
                if jump(session, selected, pane, lock):
                    refresh_at = 0
                    continue
                # The lock is busy (issue #1536): keep painting the highlight,
                # try the switch again shortly.
                follow_at = time.monotonic() + LOCK_RETRY
        if now >= refresh_at:
            try:
                if refresh_at == 0 and producer is not None:
                    # Asked for NOW while a run is in flight (issue #1530): that run
                    # read the state before the ask — drop it when it lands and start
                    # one at once, rather than paint it and wait a whole tick.
                    producer.stale = True
                refresh_at = now + 1
                info = fields(pane, US.join(("#{window_active}", "#{window_zoomed_flag}",
                                             "#{session_attached}", "#{@popup_open}",
                                             "#{window_id}", "#{@sidebar_worker}",
                                             "#{client_key_table}", "#{@remote}",
                                             "#{@popup_pid}")))
                if len(info) != 9:
                    return
                # The pane (and curses grid) survives navigation. Follow its new
                # worker before testing liveness or building current-row exemptions.
                if info[4] != window:
                    window = info[4]
                    current_row = shown_row(window, info[7])
                    selected = current_row
                    env["FLEET_SIDEBAR_CURRENT"] = window
                worker = info[5] or worker
                navigation = info[6] == "fleet-sidebar"
                route_input(session)
                # kill-pane does not emit pane-exited on every supported tmux.
                # Never let this view keep an otherwise closed worker window alive.
                if fields(worker, "#{pane_dead}") != ["0"]:
                    return
                shown = visible(info[:4] + info[8:], time.time())
                if not shown and info[3] not in ("", "0"):
                    # Under a popup: look again soon, so its close repaints the
                    # list within a second (issue #1536), not at the next tick.
                    refresh_at = now + 0.25
                if shown and loaded:
                    sized = fit_view(session, pane, rows, sized, wide)
                if shown and producer is None and view == "landed":
                    if now - landed_at >= LANDED_SECS:
                        producer = start_landed(env)
                elif shown and producer is None and folding is None:
                    producer = start_rows(env)
                    if not loaded:
                        # The first frame waits briefly for real rows rather than
                        # flash an empty list — but never a blank pane for the
                        # producer's whole timeout (issue #1536): past FIRST_WAIT
                        # it paints 「刷新中…」 and keeps polling.
                        try:
                            producer.wait(timeout=FIRST_WAIT)
                            continue
                        except subprocess.TimeoutExpired:
                            pass
            except subprocess.TimeoutExpired:
                # A tmux call past run()'s 10s bound (issue #1536) used to end this
                # view — a blank strip until the next hook sync. Paint the rows we
                # have and try again next tick; the watchdog logs it if it lasts.
                failure, refresh_at = "tmux call timed out", time.monotonic() + 1
        if not shown:
            follow_at = None  # a hidden view never switches windows
            shown_at = None   # nor does its frame age
            screen.timeout(max(1, min(1000, int((refresh_at - time.monotonic()) * 1000))))
            screen.getch()
            continue
        if shown_at is None:
            shown_at = now
        # The landed list (issue #1532) is read every LANDED_SECS, not every
        # second: its frame never counts as stale.
        age = 0 if view == "landed" else now - max(frame_at or shown_at, shown_at)
        if now >= watch_at:
            # The watchdog (issue #1536): a frame older than STALL_SECS is a stall.
            # Log it — once per stall, however many checks it lasts — then heal:
            # kill whatever holds the next frame back, start a fresh producer now.
            watch_at = now + env_float("FLEET_SIDEBAR_WATCHDOG_SECS", WATCHDOG_SECS)
            if age > env_float("FLEET_SIDEBAR_STALL_SECS", STALL_SECS):
                if producer is not None:
                    reason = "producer running %.0fs" % (now - producer.started)
                elif folding is not None:
                    reason = "fold write running"
                else:
                    reason = failure or ("no frame yet" if not loaded else "no refresh")
                healed = []
                for proc in (producer, folding):
                    if proc is not None and proc.poll() is None:
                        proc.kill()
                        proc.wait()
                if producer is not None:
                    producer.out.close()
                    healed.append("producer killed")
                if folding is not None:
                    healed.append("fold write killed")
                producer, folding, refresh_at = None, None, 0
                if not stalled:
                    stall_log(session, pane, "%s, frame %.0fs old" % (reason, age),
                              ", ".join(healed + ["producer restarted"]))
                stalled = True
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
        # The 「刷新中…」 row (issue #1536): the list waits on a frame that has not
        # come — the first, or one past STALE_SECS. The rows it has stay painted
        # one row lower; the top row says what the view is waiting for.
        waiting = 1 if height >= 4 and (not loaded or age > STALE_SECS) else 0
        page = max(1, height - waiting - (1 if help_y is None else 2))
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
        if waiting:
            put(0, tr("sidebar_refreshing"), dim_attr)
        for y, row in enumerate(rows[offset:offset + page], waiting):
            wid, state, glyph, label, tree, badge, _depth, _detail, node = row[:9]
            if wid == "hdr":
                if navigation and key_of((wid, state)) == selected:
                    put(y, "› " + label, curses.color_pair(PAIR_SEL) | curses.A_BOLD, fill=True)
                else:
                    put(y, label, dim_attr | curses.A_BOLD)
                continue
            # The text is one colour; the glyph alone says the state (issue #1622).
            raised = wid == current_row or (navigation and wid == selected)
            attr = curses.color_pair(PAIR_SEL if raised else PAIR_FG)
            lost = node.endswith("!") and not raised
            if lost:
                attr = dim_attr  # a lost machine's row (issue #1475)
            pair = STATE_PAIR.get(state)
            glyph_attr = curses.color_pair(pair + SEL_GLYPH if raised else pair) if pair else attr
            if lost:
                glyph_attr |= curses.A_DIM
            marker = "▶" if wid == current_row else "›" if navigation and wid == selected else " "
            # `marker glyph tree label` (issue #836): the hierarchy glyph is its own
            # fixed cell between the state glyph and the name, so at 30 columns every
            # name starts in the same place instead of a child's text sitting two
            # columns right of its parent's.
            # A row heard over the shell's own connection while the hub is silent
            # (`m5~`, issue #1488) gives up its last two cells to a dim ⇄ — the
            # source mark the operator asked for; the badge keeps its place left of it.
            w = max(0, width - 1)
            via = node.endswith("~") and w > 2
            text = row_text(marker, glyph, tree, label, badge, w - 2 if via else w,
                            info_text(row) if wide else "")
            put(y, text, attr, fill=raised)
            # The state glyph, painted over its own cell in the state's colour —
            # where row_left put it, and only when the row is wide enough for it.
            at = width_of(marker) + 1
            if glyph.strip() and at + width_of(glyph) <= w and 0 <= y < height:
                try:
                    screen.addstr(y, at, glyph, glyph_attr)
                except curses.error:
                    pass
            if via:
                try:
                    screen.addstr(y, w - 1, "⇄", dim_attr)
                except curses.error:
                    pass
        # The selected row's whole name takes the `?` row while the keyboard is
        # here and the list clipped it (issue #1328); its status words live in
        # the worker pane's header now (issue #1377), so `? 快捷键` stays put.
        info = None
        if help_y is not None and asking is not None:
            info = asking.hint or None  # a rename has none: `? 快捷键` stays
        elif help_y is not None and navigation:
            row = next((r for r in rows if r[0] == selected and r[0] != "hdr"), None)
            info = hint_line(row, width, wide)
        help_shown = help_y is not None and info is None
        if info is not None:
            put(help_y, info, curses.color_pair(PAIR_FG) | curses.A_BOLD)
        elif help_y is not None:
            put(help_y, HELP_ROW, dim_attr)
        # ONE input line closes the list (issue #896): the hints moved to the
        # `?` sheet. Typing while the keyboard is here fills it; Enter starts a
        # scratch session named after it. Away from the sidebar only `›` shows.
        # Hide is keyboard-only (prefix e): no tap here hides anything (#821).
        room = max(0, width - 3)
        if asking is not None:
            prefix = asking.prompt
            put(height - 1, prefix + line.view(max(0, room - sum(map(cells, prefix))),
                                               "" if asking.keys else "▏"),
                curses.A_BOLD)
        elif spawning is not None:
            put(height - 1, "› " + line.view(max(0, room - 2), "") + " …", dim_attr)
        elif toast and time.monotonic() < toast_until:
            put(height - 1, "› " + toast, curses.color_pair(PAIR_TOAST))
        elif line.text:
            put(height - 1, "› " + line.view(room if navigation else room - 1,
                                             "▏" if navigation else ""),
                curses.color_pair(PAIR_FG) | curses.A_BOLD if navigation else dim_attr)
        else:
            put(height - 1, "› " + placeholder(selected) if navigation else "›", dim_attr)
        screen.refresh()
        # Wake for whichever comes first: the next repaint, a pending follow or
        # a finished spawn.
        wait = refresh_at - time.monotonic()
        if follow_at is not None:
            wait = min(wait, follow_at - time.monotonic())
        if spawning is not None or jobs:
            wait = min(wait, 0.2)
        if producer is not None or folding is not None:
            wait = min(wait, PRODUCER_POLL)
        screen.timeout(max(1, min(1000, int(wait * 1000))))
        key = screen.getch()
        if key != -1 and spawning is not None and spawning.poll() is not None:
            # The spawn finished during this wait. Settle it first (the top of
            # the loop reaps it: the line empties, the keyboard leaves the
            # sidebar) and only then handle the key — a ⌃s or ↵ typed in the
            # same tick was otherwise dropped as «a spawn in flight» (issue
            # #1541: the sidebar selftest's ⌃s right after a typed spawn).
            curses.ungetch(key)
            continue
        if key == curses.KEY_RESIZE:
            # The pane was resized under the view — the window took a client's
            # size, the operator dragged the divider, or fit_view's own
            # resize-pane — so re-fit now, not at the next tick (issue #1521).
            # Never a loop: at the width it wants, fit_view writes nothing.
            refresh_at = 0
            continue
        if key == curses.KEY_F11:
            # A menu action finished (fleet-sidebar-menu.sh wakes the view with
            # F11, issue #1530): read the rows now, not at the next tick.
            refresh_at = 0
            continue
        if key == curses.KEY_F12:
            # A menu item that asks here (issue #1620): it parked
            # `<kind> <arg>…` in @sidebar_ask on this pane (a rename: the row's
            # @id in @sidebar_rename, as since #898), switched the client to the
            # sidebar table and sent F12 to wake us.
            parked = tmux("show-options", "-pqv", "-t", pane, "@sidebar_ask")
            wid = tmux("show-options", "-pqv", "-t", pane, "@sidebar_rename")
            tmux("set-option", "-up", "-t", pane, "@sidebar_ask", ";",
                 "set-option", "-up", "-t", pane, "@sidebar_rename")
            if wid and not parked:
                parked = "rename " + wid
            kind, _, rest = parked.strip().partition(" ")
            arg, _, extra = rest.partition(" ")
            if spawning is not None or not kind:
                continue
            follow_at, toast, nxt = None, "", None
            if kind == "rename" and arg.startswith("@"):
                nxt = Ask("rename", tr("sidebar_rename"), arg=arg)
                line.set(fields(arg, "#{window_name}")[0])
            elif kind == "new" and not SHELL:
                nxt = ask_new(session, env, selection_repo(session, selected or window, env), node=arg)
            elif kind == "repo" and not SHELL:
                nxt = Ask("repo", tr("sidebar_ask_repo"), hint=tr("sidebar_ask_repo_hint"))
            elif kind in ("message", "answer") and arg.startswith("wid:"):
                hint = tr("sidebar_ask_to_fmt", arg.rsplit("/", 1)[-1])
                if kind == "answer":
                    hint = tr("sidebar_ask_perm_hint" if extra == "perm" else "sidebar_ask_answer_hint")
                nxt = Ask(kind, tr("sidebar_ask_answer" if kind == "answer" else "sidebar_ask_message"),
                          arg=arg, hint=hint)
            elif kind == "sub" and arg.startswith("@"):
                nxt = Ask("sub", tr("sidebar_ask_sub"), arg=arg, hint=tr("sidebar_ask_sub_loading"))
                jobs.append(start_job(["bash", str(BIN / "fleet-manual-sub.sh"), "list", session],
                                      env, sub_choices(nxt)))
            elif kind == "landed" and view == "live" and not SHELL:
                curses.ungetch(20)  # ⌃t: the landed list, in place (issue #1532)
            elif kind == "jump" and acts(arg):
                # 回答 on a row of this machine: its own question, in its own
                # pane — the window the answer popup only copied.
                selected = arg
                if not jump(session, arg, pane, lock):
                    follow_at = time.monotonic() + LOCK_RETRY
            if nxt is not None:
                if kind != "rename":
                    line.clear()
                asking = nxt
                mark_input(pane, "1")
            refresh_at = 0
            continue
        if key == 27:
            key = escape_word(screen)
        if isinstance(key, str):
            # A bracketed paste (issue #1105): one insert at the cursor, on the
            # name or the rename alike. A spawn in flight owns the name.
            chars = paste_text(key)
            if chars and spawning is None:
                was, toast = line.text, ""
                line.insert(chars)
                if not was:
                    mark_input(pane, line.text)
            continue
        op = edit_of(key, line.text)
        if op:
            # The input line's own keys (issue #1097). A spawn in flight owns
            # the name, so they wait like typing does.
            if spawning is None:
                was, toast = line.text, ""
                getattr(line, op)()
                if bool(was) != bool(line.text):
                    mark_input(pane, "1" if asking is not None else line.text)
            continue
        # A typed key is a byte; a multi-byte one (。 ？, CJK) completes over
        # several getch calls, and only the last one yields its character.
        byte = 0 <= key < 256 and key not in (8, 9, 10, 13, 14, 15, 18, 19, 20, 27, 127)
        chars = "".join(c for c in decoder.decode(bytes([key])) if typed(c)) if byte else ""
        press = KEY_ALIASES.get(chars, chars)
        if asking is not None and asking.keys and (byte or key in (10, 13, curses.KEY_ENTER)):
            # A one-key question (restore: y / r): the key IS the answer; any
            # other key — Enter included — cancels it.
            if not chars and byte:
                continue  # the first byte of a multi-byte key: wait for it
            ask, asking = asking, None
            mark_input(pane, line.text)
            decoder.reset()
            if press and press in ask.keys:
                jobs.append(submit(ask, press, session, env))
            refresh_at = 0
            continue
        if press == "." and not line.text and asking is None and spawning is None and acts(selected):
            # `.` on an EMPTY line is the row menu (dash-keymap.sh --panel sidebar
            # `menu`); inside a name it types. The follow is dropped: the menu
            # acts on the highlighted row and the window in view stays put.
            follow_at = None
            open_menu(session, selected, env)
            continue
        if press == "?" and not line.text and asking is None and spawning is None:
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
        elif key in (10, 13, curses.KEY_ENTER) and asking is not None:
            # ↵ answers the question (submit). An empty rename still goes to
            # dash-rename.sh, which decides (an empty name cancels, as in the
            # hub); any other empty answer cancels here.
            ask, text, asking = asking, line.text.strip(), None
            line.clear()
            mark_input(pane, line.text)
            if ask.kind == "rename":
                run(["bash", str(BIN / "dash-rename.sh"), "--wid", ask.arg, text], env=env)
            else:
                job = submit(ask, text, session, env)
                if job is not None:
                    jobs.append(job)
            refresh_at = 0
        elif key == 27 and asking is not None:
            asking = None
            line.clear()
            mark_input(pane, line.text)
        elif key == 9 and asking is not None:
            # Tab steps a question's choices (a new task's repo, an account);
            # ⌃i's info column waits until the question is answered.
            value = asking.step()
            if value:
                line.set(value)
        elif key in (10, 13, curses.KEY_ENTER) and line.text.strip():
            # A typed name: start its scratch session (the bind kept the
            # keyboard here while @sidebar_input was set). One spawn at a time.
            follow_at = None
            if SHELL:
                toast, toast_until = shell_refusal()
            elif spawning is None:
                toast = ""
                spawning = spawn_scratch(line.text.strip(), env,
                                         selection_repo(session, selected or window, env))
        elif key in (10, 13, curses.KEY_ENTER) and view == "landed":
            # ↵ on a landed row restores it (issue #1532) — the hub's ⌃o, as the
            # current window — and the list goes back to the running one, where
            # the restored session shows up as ▶.
            follow_at = None
            if selected.startswith("landed:"):
                job = restore_landed(session, selected, env)
                if job is not None:
                    jobs.append(job)
                view, rows, selected = "live", live_rows, window
            refresh_at = 0
        elif key in (10, 13, curses.KEY_ENTER):
            # The Enter bind already returned the client to root and sent the key
            # straight here (issue #1530). If the follow (or anyone) has moved the
            # session since, a switch back to the row it was read against would
            # yank the operator — with nothing to jump to, Enter only hands over.
            follow_at = None
            if acts(selected) and selected != window and not jump(session, selected, pane, lock):
                follow_at = time.monotonic() + LOCK_RETRY  # lock busy: retried (#1536)
            refresh_at = 0
        elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and view == "landed":
            pass  # the landed list folds in the hub (⌃t there); here it is flat
        elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and folds(selected):
            # A session row folds its subtree; a repo heading its whole group
            # (issue #1037) — one helper, the hub's, for both.
            # Painted at once (fold_now), written in the background; the
            # producer waits for the write, so its frame is never the old one.
            verb = "collapse" if key == curses.KEY_LEFT else "expand"
            target = folds(selected)
            rows, holder = fold_now(rows, target, verb, window, fold_cache)
            if holder and verb == "collapse":
                selected = holder
            if folding is not None:
                try:
                    folding.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    folding.kill()
            folding = subprocess.Popen(["bash", str(BIN / "dash-fold-toggle.sh"), verb, target],
                                       env=dict(env, DASH_FOLD_PLAIN="1"), stdin=subprocess.DEVNULL,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            refresh_at = 0
        elif key == 14:
            # ⌃n (dash-keymap.sh --panel sidebar `new`; its ⌥n fallback is
            # rewritten to ⌃n by the bind). The popup blocks; a follow scheduled
            # just before must not fire after it and switch away from the window
            # the spawn made current.
            follow_at = None
            if SHELL:
                toast, toast_until = shell_refusal()
            elif asking is None and spawning is None:
                # The title on the input line (issue #1620; it was a popup) —
                # whatever is typed already starts it.
                asking = ask_new(session, env, selection_repo(session, selected or window, env))
                mark_input(pane, "1")
            refresh_at = 0
        elif key == 15:
            # ⌃o (`restore`; its ⌥o fallback is rewritten to ⌃o by the bind). The
            # restored window becomes current; the hook moves this view there.
            follow_at = None
            if SHELL:
                toast, toast_until = shell_refusal()
            elif view == "live":
                # The landed list, in place — ⌃t's (issue #1620: the restore
                # popup was the same list a second time).
                curses.ungetch(20)
            refresh_at = 0
        elif key == 19:
            # ⌃s (`scratch`, issue #1532): the hub's ⌃s — a scratch session NOW,
            # unnamed (a typed name, if any, names it), its repo the highlighted
            # row's. It becomes current like a typed ↵'s; a refusal toasts.
            follow_at = None
            if SHELL:
                toast, toast_until = shell_refusal()
            elif spawning is None and asking is not None and asking.kind == "new":
                # ⌃s on a new task's title: a scratch session by that name
                # instead, there (its repo, its machine) — the popup's ⌃s (#1541).
                ask, asking, toast = asking, None, ""
                spawning = spawn_scratch(line.text.strip(), env, ask.repo, node=ask.node)
            elif spawning is None and asking is None:
                toast = ""
                anchor = window if not selected or selected.startswith("landed:") else selected
                spawning = spawn_scratch(line.text.strip(), env, selection=anchor)
        elif key == 20:
            # ⌃t (`view`, issue #1532): the running list ⇄ the landed one, in
            # place — the hub's ⌃t. Either side paints what it last had at once,
            # and the run in flight for the other one is dropped, not waited on.
            follow_at = None
            drop_rows(producer)
            producer = None
            if view == "live":
                view, live_rows, rows = "landed", rows, landed or [
                    ["hdr", "", "", tr("sidebar_landed_loading")] + [""] * (ROW_FIELDS - 4)]
                landed_at = NEVER
            else:
                view, rows, selected = "live", live_rows, window
            refresh_at = 0
        elif key == 18:
            # ⌃r (`reload`, issue #1532): read the shown list now, landed included.
            landed_at = NEVER
            refresh_at = 0
        elif key == 9:
            # ⌃i / Tab (`info`, issue #1532): open or fold the info column —
            # issue · PR · ctx%, right-aligned. The width follows at once, within
            # FLEET_SIDEBAR_WIDTH_MAX; folded is the default, names come first.
            wide = not wide
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
            ry = y - waiting  # below the 「刷新中…」 row when it shows (issue #1536)
            hit = key_of(rows[offset + ry]) if 0 <= ry < page and offset + ry < len(rows) else None
            # `selected`, not the painted cue: a fast double tap lands its second
            # press before the next refresh repaints the first one's switch.
            action = tap(hit, selected)
            if hit and hit.startswith("landed:"):
                # A landed row (issue #1532): a tap highlights it, a tap on the
                # highlighted one restores it — the session row's two-tap grammar.
                action = "restore" if action == "menu" else "select"
            if buttons & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED):
                refresh_at = 0
                armed = None
                if help_y is not None and y == help_y and help_shown:
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
                        nxt = open_tap(session, action, hit, env)
                        if nxt == "refused":
                            toast, toast_until = shell_refusal()
                        elif nxt is not None and asking is None and spawning is None:
                            asking = nxt
                            mark_input(pane, "1")
                    else:
                        armed = hit
                elif action == "restore":
                    follow_at = None
                    if buttons & curses.BUTTON1_CLICKED:
                        job = restore_landed(session, hit, env)
                        if job is not None:
                            jobs.append(job)
                        view, rows, selected = "live", live_rows, window
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
                    if not jump(session, selected, pane, lock):
                        follow_at = time.monotonic() + LOCK_RETRY  # lock busy (#1536)
                # Anywhere else (the input line included) the click only focuses:
                # the bind already moved the keyboard here, so typing follows.
            elif buttons & curses.BUTTON1_RELEASED:
                if armed == HELP_ROW and y == help_y and help_shown:
                    open_help(screen, env)
                elif armed is not None and hit == armed and armed.startswith("landed:"):
                    job = restore_landed(session, armed, env)
                    if job is not None:
                        jobs.append(job)
                    view, rows, selected = "live", live_rows, window
                    refresh_at = 0
                elif armed is not None and hit == armed:
                    nxt = open_tap(session, "new" if armed.startswith("hdr:") else "menu", armed, env)
                    if nxt == "refused":
                        toast, toast_until = shell_refusal()
                    elif nxt is not None and asking is None and spawning is None:
                        asking = nxt
                        mark_input(pane, "1")
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
