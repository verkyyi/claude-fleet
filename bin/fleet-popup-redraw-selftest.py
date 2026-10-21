#!/usr/bin/env python3
# Real terminal regression for bin/fleet-quickopen.py Heal + bin/fleet_view.py,
# through bin/dash-popup.sh and bin/fleet-popup-lib.sh (issue #4410).
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""Two isolated tmux servers: the outer terminal parses the real popup output.

Measure repeated frame writes as well as final cells (a screenshot misses the
flash). No terminal emulator dependency. Data providers are fixtures; curses,
the view loop, refresh, keys, popup door, palette and freeze/thaw are real.
"""
import curses
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).resolve().parent
ME = Path(__file__).resolve()


def panel(state):
    spec = importlib.util.spec_from_file_location("qo", BIN / "fleet-quickopen.py")
    qo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qo)
    import fleet_view as view

    def entries(*args, **kwargs):
        label = Path(state).read_text()
        return [] if not label else [dict(kind="sess", target="@0", text=label,
                                         name=label, sym="idle", word="idle")]

    view.entries = entries
    view.current = lambda _: "@0"
    view.view_fleet = lambda _: "fl"
    view.grid_read = lambda *_: view.bolt_new()["g"]
    view.view_lang_env = lambda _: None
    curses.wrapper(view.popup, qo, "test", "")


def background():
    # Bounded, low-rate terminal traffic, not a CPU/load experiment.
    end = time.monotonic() + 90
    while time.monotonic() < end:
        print("BACKGROUND-龘" * 30, flush=True)
        time.sleep(0.1)


def main():
    rt = shutil.which("tmux")
    failures = []
    with tempfile.TemporaryDirectory(prefix="pop-redraw-", dir="/tmp") as td:
        work = Path(td)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("FLEET_", "TMUX"))}
        env.update(HOME=str(work / "home"), FLEET_CONF_DIR=str(work / "conf"),
                   FLEET_STATUS_G=str(work / "g"), FLEET_UI_LANG="en",
                   FLEET_VIEW_REFRESH="0.2", TERM="xterm-256color", COLORTERM="truecolor")
        for name in ("home", "conf", "g", "shim"):
            (work / name).mkdir()
        inner, outer = str(work / "i"), str(work / "o")
        shim = work / "shim/tmux"
        shim.write_text("#!/bin/sh\nexec %s -S %s \"$@\"\n" % (shlex.quote(rt), shlex.quote(inner)))
        shim.chmod(0o755)
        env["PATH"] = str(shim.parent) + os.pathsep + env["PATH"]
        state, raw = work / "state", work / "raw"
        title = "PANEL-中文e\u0301" * 12
        state.write_text(title)

        def tm(sock, *args, check=True):
            return subprocess.run([rt, "-u", "-S", sock, *map(str, args)], env=env,
                                  capture_output=True, text=True, check=check, timeout=8).stdout.strip()

        def capture():
            return tm(outer, "capture-pane", "-p", "-t", "out:0")

        def until(fn, seconds=6):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                if fn():
                    return
                time.sleep(0.05)
            raise AssertionError("timed out: " + capture())

        def check(ok, label):
            print(("PASS " if ok else "FAIL ") + label, flush=True)
            if not ok:
                failures.append(label)

        def data():
            return raw.read_bytes() if raw.exists() else b""

        def frame():
            lines = capture().splitlines()
            top = next((i for i, line in enumerate(lines) if "╭" in line), None)
            bottom = next((i for i, line in enumerate(lines) if "╰" in line), None)
            assert top is not None and bottom is not None, lines
            # tmux capture supplies CJK glyphs once: use the renderer's cell
            # count only to locate the frame, not to implement a second renderer.
            import unicodedata
            cells = lambda s: sum(0 if unicodedata.combining(c) else
                                  2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
            x = cells(lines[top].split("╭")[0])
            width = cells(lines[bottom].split("╰")[1].split("╯")[0]) + 2
            body = lines[top + 1:bottom]
            assert "╮" in lines[top] and "╯" in lines[bottom], lines
            assert all(line.count("│") >= 2 and cells(line.split("│")[0]) == x and
                       cells("│".join(line.split("│")[1:-1])) == width - 2 for line in body), lines
            assert all("BACKGROUND" not in "│".join(line.split("│")[1:-1]) and "龘" not in "│".join(line.split("│")[1:-1])
                       for line in body), lines
            return top, x, width, bottom

        proc = None
        try:
            tm(inner, "-f", "/dev/null", "new-session", "-d", "-s", "fl", "-x", 120, "-y", 32,
               shlex.join([sys.executable, str(ME), "--background"]))
            tm(inner, "set", "-g", "status", "off")
            tm(inner, "set", "-g", "default-terminal", "tmux-256color")
            tm(inner, "set", "-g", "focus-events", "on")
            tm(inner, "set", "-s", "terminal-overrides", "*:Cmg@:Clmg@")
            attach = shlex.join([rt, "-u", "-S", inner, "attach", "-t", "fl"])
            # No live socket or user's configuration is read by either server.
            tm(outer, "-f", "/dev/null", "new-session", "-d", "-s", "out", "-x", 120, "-y", 32,
               "env -u TMUX " + attach)
            tm(outer, "set", "-g", "status", "off")
            tm(outer, "pipe-pane", "-t", "out:0", "cat > " + shlex.quote(str(raw)))
            until(lambda: "BACKGROUND" in capture())
            client = tm(inner, "list-clients", "-F", "#{client_name}").splitlines()[0]
            print("ENV %s TERM=xterm-256color -> tmux-256color; repository palette; Cmg/Clmg disabled" %
                  tm(inner, "-V"), flush=True)
            widths = [int(sys.argv[sys.argv.index("--width") + 1])] if "--width" in sys.argv \
                else [120] if "--idle" in sys.argv else [140, 100, 80, 45]
            for width in widths:
                tm(outer, "resize-window", "-t", "out:0", "-x", width, "-y", 32)
                until(lambda: tm(inner, "display", "-p", "-c", client, "#{client_width}") == str(width))
                cmd = ["bash", str(BIN / "dash-popup.sh"), "--client", client, "--no-inline", "--freeze",
                       "-w", "100%" if width < 100 else "90%", "-h", "100%" if width < 100 else "80%",
                       "--title", "view_title", "--", sys.executable, str(ME), "--panel", str(state)]
                proc = subprocess.Popen(cmd, env=dict(env, TMUX=inner + ",0,0"),
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                until(lambda: "PANEL-" in capture() and "╭" in capture())
                time.sleep(0.6)  # first frame + asynchronous fixture refresh
                check(tm(inner, "display", "-p", "-t", "fl:0", "#{pane_in_mode}") == "1",
                      "%d background frozen" % width)
                before_frame, start = frame(), len(data())
                time.sleep(2.25)  # exceeds two old HEAL periods
                chunk = data()[start:]
                redraws = chunk.count("╭".encode())
                check(redraws == 0, "%d idle 2.25s: frame writes=%d bytes=%d" % (width, redraws, len(chunk)))
                check(b"BACKGROUND" not in chunk and "龘".encode() not in chunk,
                      "%d no background output through popup" % width)
                check(frame() == before_frame, "%d idle frame cells stable" % width)
                # the 看台's window changes under the open panel (T741: the ⚡ job's
                # go, the window behind closed): the freeze follows the client, so
                # the window it moved to writes nothing either
                tm(inner, "new-window", "-d", "-t", "fl:1", shlex.join([sys.executable, str(ME), "--background"]))
                tm(inner, "select-window", "-t", "fl:1")
                time.sleep(0.6)  # the watcher's tick + its one redraw
                start = len(data())
                time.sleep(1.0)
                chunk = data()[start:]
                check(tm(inner, "display", "-p", "-t", "fl:1", "#{pane_in_mode}") == "1",
                      "%d window moved to under the popup is held" % width)
                check(b"BACKGROUND" not in chunk and "龘".encode() not in chunk,
                      "%d window moved to: no background output through popup" % width)
                # nothing of the background inside the frame (the frame's own
                # cells are left out: select-window repaints the whole screen, and
                # tmux 3.7c misdraws a wide glyph straddling a 90% popup's edge —
                # with or without the freeze)
                lines = capture().splitlines()
                top = next(i for i, line in enumerate(lines) if "╭" in line)
                bottom = next(i for i, line in enumerate(lines) if "╰" in line)
                inside = ["│".join(line.split("│")[1:-1]) for line in lines[top + 1:bottom]]
                check(not any("BACKGROUND" in t or "龘" in t for t in inside),
                      "%d window moved to: nothing of it inside the frame" % width)
                tm(inner, "select-window", "-t", "fl:0")
                tm(inner, "kill-window", "-t", "fl:1")
                time.sleep(0.4)

                if "--idle" not in sys.argv:
                    # Real list refresh still paints changed content.
                    state.write_text("UPDATED-中文e\u0301" * 12)
                    until(lambda: "UPDATED-" in capture())
                    check(True, "%d asynchronous content refresh" % width)
                    state.write_text(title)
                    until(lambda: "PANEL-" in capture())
                    # Focus notifications and repeated size changes through the
                    # client's PTY; the real curses KEY_RESIZE path handles them.
                    for new_width in (width - 4, width - 8, width):
                        tm(outer, "resize-window", "-t", "out:0", "-x", new_width, "-y", 30)
                        time.sleep(0.12)
                    tm(outer, "send-keys", "-t", "out:0", "-l", "\x1b[O\x1b[I")
                    time.sleep(1.1)
                    frame()
                    start = len(data())
                    time.sleep(1.2)
                    check(data()[start:].count("╭".encode()) == 0,
                          "%d resize settled: frame quiet, CJK background contained" % width)
                    tm(outer, "send-keys", "-t", "out:0", "Tab")
                    until(lambda: "run it" in capture())
                    frame()
                    tm(outer, "send-keys", "-t", "out:0", "Escape")
                    time.sleep(0.2)
                    # Empty data keeps the new-session entry and its box (T652).
                    state.write_text("")
                    until(lambda: "PANEL-" not in capture() and "New session" in capture())
                    tm(outer, "send-keys", "-t", "out:0", "Tab")
                    until(lambda: "↵ open" in capture())
                    frame()
                    check(proc.poll() is None, "%d menu / empty list / new-task cells remain open" % width)
                    state.write_text(title)

                tm(outer, "send-keys", "-t", "out:0", "Escape", "Escape")
                proc.wait(timeout=5)
                check(proc.returncode == 0, "%d popup exit: %s" % (width, proc.stderr.read().decode()))
                proc = None
                until(lambda: tm(inner, "display", "-p", "-t", "fl:0", "#{pane_in_mode}") == "0")
                until(lambda: "╭" not in capture() and "BACKGROUND" in capture())
                check(True, "%d close restores live terminal" % width)
        finally:
            # Only private sockets, even on assertion/timeout; reap the popup door
            # before removing its shim and temporary HOME.
            tm(inner, "kill-server", check=False)
            tm(outer, "kill-server", check=False)
            if proc:
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    proc.wait(timeout=5)
    return bool(failures)


def lanes(widths):
    """Each width in a process of its own — its own temp dir, its own two tmux
    servers — all at once: a width's checks are seconds of watching an idle
    frame, and nothing is shared between widths. Outputs print whole, in order;
    any width failing fails the run."""
    kids = [(w, subprocess.Popen([sys.executable, str(ME), "--width", str(w)],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT))
            for w in widths]
    rc = 0
    for w, kid in kids:
        out = kid.communicate()[0].decode(errors="replace")
        sys.stdout.write(out)
        if kid.returncode:
            print("FAIL width %d exited %d" % (w, kid.returncode), flush=True)
            rc = 1
    sys.stdout.flush()
    return rc


if __name__ == "__main__":
    if "--panel" in sys.argv:
        panel(sys.argv[-1])
    elif "--background" in sys.argv:
        background()
    elif not shutil.which("tmux"):
        print("SKIP: tmux absent")
    elif "--idle" in sys.argv or "--width" in sys.argv:
        sys.exit(main())
    else:
        sys.exit(lanes([140, 100, 80, 45]))
