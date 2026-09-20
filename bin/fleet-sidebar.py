#!/usr/bin/env python3
"""A compact live hub list. One view per attached fleet; no hidden render loops.

The worker keeps tmux's active-pane identity even during keyboard navigation.
That matters: collectors, messages and recovery tools resolve a window to its
active agent pane. Mouse forwarding and the fleet-sidebar key table deliver
input explicitly to this view without changing that identity.
"""
import curses
import fcntl
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import unicodedata

BIN = Path(__file__).absolute().parent  # preserve the selftest shadow root
US = "\x1f"
VIEW_VERSION = "4"  # #821: footer + bottom-row semantics changed; replace live v3 views once
# ↑↓ follow (issue #822): an arrow moves the highlight at once and switches to
# it only after this much quiet. A held key on a slow link is one switch, not
# one per row, and a row passed over is never selected — so the wake hook's
# dwell (fleet-sleep.py) never sees it either.
FOLLOW_SECS = 0.25


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
                  "#{@raw}", "#{@worktree}", "#{window_zoomed_flag}")))
    if len(info) != 8:
        return
    window, name, cols, attached, issue, raw, worktree, zoomed = info
    all_panes = panes(session)
    workers = [p for p in all_panes if p[1] == window and p[2] != "1" and p[4] != "1"]
    wanted = (enabled == "1" and attached != "0" and
              name not in ("plan", "dash", "backlog") and
              bool(issue or raw == "1" or worktree) and bool(workers) and
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
    if key not in ("Up", "Down", "Left", "Right", "Enter", "Escape", "q", "n", "Home", "End"):
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


def new_task(screen, env):
    """The hub's ⌃n popup, launched from this pane (issue #821): file an issue
    and spawn its worker. dash-popup.sh resolves the client, raises @popup_open
    for the popup's lifetime and clears it on the way out; the spawned window
    becomes current and the session-window-changed hook moves this view there.
    Leave curses meanwhile: a popup draws on the client, not on this pane, but
    when none can open (no client, an overlay already up) dash-popup.sh runs the
    command INLINE here, and its fzf title prompt then needs a sane tty. No
    timeout — the popup lives as long as the operator types."""
    curses.endwin()
    subprocess.call(["bash", str(BIN / "dash-popup.sh"), "-w", "90%", "-h", "12", "--",
                     "bash", str(BIN / "dash-issue-new.sh"), "confirm", "--spawn"], env=env)
    screen.clear()  # the next refresh resumes curses and repaints the whole grid


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
    screen.keypad(True)
    rows, selected, offset, refresh_at = [], window, 0, 0.0
    shown, navigation, follow_at = False, False, None
    while True:
        now = time.monotonic()
        if follow_at is not None and now >= follow_at:
            # The highlight settled: switch once. Nothing here touches the
            # client's key table, and the Up/Down binds re-enter fleet-sidebar
            # before their key arrives, so ↑↓ keep browsing after the switch;
            # Enter/Escape (whose binds do not re-enter) still hand input back.
            follow_at = None
            if selected and selected != window:
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
            if shown:
                result = run(["bash", str(BIN / "tmux-dashboard-rows.sh"), "--sidebar"], env=env)
                if result.returncode == 0:
                    rows = [line.split(US, 4) for line in result.stdout.split("\n")
                            if len(line.split(US, 4)) == 5]
        if not shown:
            follow_at = None  # a hidden view never switches windows
            screen.timeout(1000)
            screen.getch()
            continue
        height, width = screen.getmaxyx()
        ids = [row[0] for row in rows]
        if selected not in ids:
            selected = window if window in ids else (ids[0] if ids else "")
        index = ids.index(selected) if selected in ids else 0
        page = max(1, height - 2)
        offset = max(0, min(offset, max(0, len(rows) - page)))
        if index < offset:
            offset = index
        elif index >= offset + page:
            offset = index - page + 1

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
        # Hide is keyboard-only (q here, prefix e anywhere): a tap on the bottom
        # row used to hide the sidebar across every window, and on a touch
        # screen that row is the easiest one to mis-hit (issue #821).
        put(height - 2, " ↑↓ choose · ↵/Esc · q hide" if navigation else
            " Keyboard: WORKER →", curses.A_DIM)
        put(height - 1, " + n: new task", curses.A_DIM)
        screen.refresh()
        # Wake for whichever comes first: the next repaint or a pending follow.
        wait = refresh_at - time.monotonic()
        if follow_at is not None:
            wait = min(wait, follow_at - time.monotonic())
        screen.timeout(max(1, min(1000, int(wait * 1000))))
        key = screen.getch()
        if key in (curses.KEY_UP, ord("k")) and ids:
            selected = ids[max(0, index - 1)]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key in (curses.KEY_DOWN, ord("j")) and ids:
            selected = ids[min(len(ids) - 1, index + 1)]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key == curses.KEY_HOME and ids:
            selected = ids[0]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key == curses.KEY_END and ids:
            selected = ids[-1]
            follow_at = time.monotonic() + FOLLOW_SECS
        elif key in (10, 13, curses.KEY_ENTER):
            # The Enter bind already returned the client to root; the key reaches
            # here a run-shell hop later. If the follow (or anyone) has moved the
            # session since, a switch back to the row it was read against would
            # yank the operator — with nothing to jump to, Enter only hands over.
            follow_at = None
            if selected != window:
                jump(session, selected, pane, lock)
            refresh_at = 0
        elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and selected:
            verb = "collapse" if key == curses.KEY_LEFT else "expand"
            run(["bash", str(BIN / "dash-fold-toggle.sh"), verb, selected], env=env)
            refresh_at = 0
        elif key == ord("q"):
            run(["bash", str(BIN / "fleet-sidebar.sh"), "hide", session])
            return
        elif key == ord("n"):
            # The popup blocks; a follow scheduled just before must not fire
            # after it and switch away from the window the spawn made current.
            follow_at = None
            new_task(screen, env)
            refresh_at = 0
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
            if buttons & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED):
                refresh_at = 0
                if 0 <= y < page and offset + y < len(rows):
                    selected = rows[offset + y][0]
                    jump(session, selected, pane, lock)
                    refresh_at = 0
                elif y == height - 1:
                    new_task(screen, env)
            elif buttons & curses.BUTTON4_PRESSED and ids:
                selected = ids[max(0, index - 3)]
            elif buttons & getattr(curses, "BUTTON5_PRESSED", 0) and ids:
                selected = ids[min(len(ids) - 1, index + 3)]


def main():
    if sys.argv[1] == "ui":
        curses.wrapper(ui, sys.argv[2], sys.argv[3], sys.argv[4])
        return
    verb, session, lock, enabled, width, key = sys.argv[1:]
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
        sync(session, enabled, width, lock)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.TimeoutExpired, curses.error):
        # A closing pane/server is a normal race for hooks and views.
        sys.exit(0)
