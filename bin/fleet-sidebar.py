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


def run(args, **kwargs):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=10, **kwargs)


def tmux(*args):
    return run(["tmux", *args]).stdout.rstrip("\n").replace("\\037", US)


def fields(target, fmt):
    return tmux("display-message", "-p", "-t", target, fmt).split(US)


def panes(session):
    fmt = US.join(("#{pane_id}", "#{window_id}", "#{@sidebar}",
                   "#{pane_active}", "#{pane_dead}", "#{@sidebar_worker}"))
    return [line.split(US) for line in tmux(
        "list-panes", "-s", "-t", session, "-F", fmt).splitlines()
        if len(line.split(US)) == 6]


def remove_view(pane):
    # Verify ownership immediately before removal; never close an agent pane.
    if fields(pane, "#{@sidebar}") == ["1"]:
        tmux("set-option", "-uw", "-t", pane, "@sidebar_worker")
        tmux("kill-pane", "-t", pane)


def sync(session, enabled, width):
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
    current = []
    for pane in all_panes:
        if pane[2] != "1":
            continue
        if wanted and pane[1] == window and pane[4] != "1" and not current:
            current.append(pane)
        else:
            remove_view(pane[0])
    if not wanted or current or zoomed == "1":
        return
    worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
    cwd = fields(worker, "#{pane_current_path}")[0]
    cmd = " ".join(shlex.quote(arg) for arg in (
        "python3", str(BIN / "fleet-sidebar.py"), "ui", session, worker))
    pane = tmux("split-window", "-d", "-h", "-b", "-f", "-l", str(width),
                "-t", worker, "-c", cwd, "-P", "-F", "#{pane_id}", cmd)
    if not pane.startswith("%"):
        return
    tmux("set-option", "-p", "-t", pane, "@sidebar", "1", ";",
         "set-option", "-w", "-t", pane, "@sidebar_worker", worker, ";",
         "set-option", "-p", "-t", pane, "remain-on-exit", "off")


def send_key(session, key):
    if key not in ("Up", "Down", "Left", "Right", "Enter", "Escape", "q", "Home", "End"):
        return
    window = fields(session + ":", "#{window_id}")[0]
    for pane in panes(session):
        if pane[1] == window and pane[2] == "1":
            # Only the marked UI receives these keys, never the worker prompt.
            tmux("send-keys", "-t", pane[0], key)
            return


def jump(session, window):
    # Never resolve a stale row through a recycled index, or another fleet.
    if not window.startswith("@") or fields(window, "#{session_name}") != [session]:
        return
    workers = [p for p in panes(session) if p[1] == window and p[2] != "1" and p[4] != "1"]
    if workers:
        worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
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


def ui(screen, session, worker):
    pane = os.environ["TMUX_PANE"]
    window = fields(worker, "#{window_id}")[0]
    env = dict(os.environ, FLEET_SESSION=session, FLEET_SIDEBAR_CURRENT=window)
    curses.curs_set(0)
    curses.use_default_colors()
    for number, color in enumerate((curses.COLOR_CYAN, curses.COLOR_RED,
                                     curses.COLOR_GREEN, curses.COLOR_MAGENTA), 1):
        curses.init_pair(number, color, -1)
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
    curses.mouseinterval(0)
    screen.keypad(True)
    screen.timeout(1000)
    rows, selected, offset, refresh_at = [], window, 0, 0.0
    shown = False
    while True:
        now = time.monotonic()
        if now >= refresh_at:
            refresh_at = now + 1
            # kill-pane does not emit pane-exited on every supported tmux.
            # Never let this view keep an otherwise closed worker window alive.
            if fields(worker, "#{pane_dead}") != ["0"]:
                return
            info = fields(pane, US.join(("#{window_active}", "#{window_zoomed_flag}",
                                         "#{session_attached}", "#{@popup_open}")))
            shown = visible(info, time.time())
            if shown:
                result = run(["bash", str(BIN / "tmux-dashboard-rows.sh"), "--sidebar"], env=env)
                if result.returncode == 0:
                    rows = [line.split(US, 3) for line in result.stdout.split("\n")
                            if len(line.split(US, 3)) == 4]
        if not shown:
            screen.getch()
            continue
        height, width = screen.getmaxyx()
        ids = [row[0] for row in rows]
        if selected not in ids:
            selected = window if window in ids else (ids[0] if ids else "")
        index = ids.index(selected) if selected in ids else 0
        page = max(1, height - 3)
        offset = max(0, min(offset, max(0, len(rows) - page)))
        if index < offset:
            offset = index
        elif index >= offset + page:
            offset = index - page + 1

        def put(y, text, attr=0):
            if 0 <= y < height:
                try:
                    screen.addstr(y, 0, clip(text, max(0, width - 1)), attr)
                except curses.error:
                    pass  # a resize may race this paint

        screen.erase()
        put(0, " Tasks · " + session, curses.A_BOLD)
        colors = {"working": 1, "needs": 2, "done": 3, "looping": 4}
        for y, (wid, state, glyph, label) in enumerate(rows[offset:offset + page], 1):
            attr = curses.color_pair(colors.get(state, 0))
            if wid == selected:
                attr |= curses.A_REVERSE
            if wid == window:
                attr |= curses.A_BOLD
            put(y, ("›" if wid == window else " ") + " " + glyph + " " + label, attr)
        put(height - 2, " prefix E: ↑↓ ↵ ←→", curses.A_DIM)
        put(height - 1, " ‹ Hide · prefix e", curses.A_DIM)
        screen.refresh()
        key = screen.getch()
        if key in (curses.KEY_UP, ord("k")) and ids:
            selected = ids[max(0, index - 1)]
        elif key in (curses.KEY_DOWN, ord("j")) and ids:
            selected = ids[min(len(ids) - 1, index + 1)]
        elif key == curses.KEY_HOME and ids:
            selected = ids[0]
        elif key == curses.KEY_END and ids:
            selected = ids[-1]
        elif key in (10, 13, curses.KEY_ENTER):
            jump(session, selected)
        elif key in (curses.KEY_LEFT, curses.KEY_RIGHT) and selected:
            verb = "collapse" if key == curses.KEY_LEFT else "expand"
            run(["bash", str(BIN / "dash-fold-toggle.sh"), verb, selected], env=env)
            refresh_at = 0
        elif key == ord("q"):
            run(["bash", str(BIN / "fleet-sidebar.sh"), "hide", session])
            return
        elif key == 27:
            selected = window
        elif key == curses.KEY_MOUSE:
            try:
                _, _, y, _, buttons = curses.getmouse()
            except curses.error:
                continue
            if buttons & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED):
                if 1 <= y <= page and offset + y - 1 < len(rows):
                    jump(session, rows[offset + y - 1][0])
                elif y == height - 1:
                    run(["bash", str(BIN / "fleet-sidebar.sh"), "hide", session])
                    return
            elif buttons & curses.BUTTON4_PRESSED and ids:
                selected = ids[max(0, index - 3)]
            elif buttons & getattr(curses, "BUTTON5_PRESSED", 0) and ids:
                selected = ids[min(len(ids) - 1, index + 3)]


def main():
    if sys.argv[1] == "ui":
        curses.wrapper(ui, sys.argv[2], sys.argv[3])
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
        sync(session, enabled, width)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.TimeoutExpired, curses.error):
        # A closing pane/server is a normal race for hooks and views.
        sys.exit(0)
