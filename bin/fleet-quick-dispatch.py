#!/usr/bin/env python3
"""fleet-quick-dispatch.py — ⌘T: 派一件事 (issue #2753). One line, ↵, and a worker is
on it — from any window of the client: a worker's, the orchestrator's (Claude or
Codex), a bare shell, a session on another machine.

    fleet-quick-dispatch.py [--session S]       the popup (conf/tmux-shell.conf's ⌘T /
                                          prefix t, and ⌘P's first line 「⚡ 派一件事…」,
                                          open it through the one popup door)
    fleet-quick-dispatch.py payload --title T [--repo R] [--codex]
                                          the payload a ↵ would write, as JSON
                                          (the selftest's view)
    fleet-quick-dispatch.py send --title T [--repo R] [--codex]
                                          the ↵ without the screen: write it, hand
                                          it on; prints 「已发出：…」 or why not

The popup: 标题 (one line), 仓库 (every repo the hub says this person's machines
host — the one the last send went to first; ←→ picks, shown only when there is
more than one) and 交给 Codex (⌃X flips it; off = the fleet's own agent). ↵
sends, esc closes, Tab walks between the three.

There is no second road (EPIC #2230 共同约定 1, issue #2618's rule): a ↵ writes
the SAME payload the writing area writes — fleet-compose.py payload(), its
compose-send.json, its compose-state.json for 「上次用的仓库」 — and hands the
task list `compose` on its @sidebar_do queue (F12 wakes it), exactly as the
writing area's ↵ does. The list draws 「开工中…」, runs fleet-compose.py --send →
fleet-client-place.sh <repo> new (the machine that takes it files the issue
through fleet-issue-file.sh and opens its worker), switches to the new session's
row when it appears, and — the payload says `via: dispatch` — says
「已建 #N 并开工」. Nothing on the way calls a model or waits behind the
orchestrator's turn; `/qd` in the orchestrator's window files through the same
fleet-issue-file.sh, from the inside. No list on screen: --send runs from here
and the popup says how it ended.

FLEET_DISPATCH_SEND_CMD (tests): replaces `fleet-compose.py --send <payload>`.
"""
import curses
import importlib.util
import json
import locale
import os
import subprocess
import sys
import time
from pathlib import Path

BIN = Path(__file__).absolute().parent


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, str(BIN / file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


compose = _load("fleet_compose", "fleet-compose.py")
quick = _load("fleet_quickopen", "fleet-quickopen.py")

TEXT = {}


def tr(key, *args):
    text = TEXT.get(key, key)
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


def load_text():
    try:
        out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "dispatch_", "compose_"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = b""
    parts = out.decode("utf-8", "replace").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


def repos():
    return compose.hub_repos() or []


def repo_default(have=None, last=None):
    """The repo a ↵ goes to untouched: the one the last send went to (this
    popup's or the writing area's — one compose-state.json), else the first."""
    have = repos() if have is None else have
    last = compose.last_repo() if last is None else last
    if not have:
        return last
    return last if last in have else have[0]


def payload(title, repo, codex=False):
    """The writing area's payload for one line (fleet-compose.py payload), marked
    `via: dispatch` so the list says the number it filed. {} = nothing to send."""
    data = compose.payload(title, "", repo, None, "codex" if codex else None)
    if data:
        data["via"] = "dispatch"
    return data


def send(data):
    """Write it, hand it on. (ok, words): handed to the list → 「已发出：…」 and
    the list takes it from there; no list → --send here, and how it ended."""
    path = compose.send_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if not compose.write_atomic(path, json.dumps(data, ensure_ascii=False) + "\n"):
        return False, "✗ " + str(path)
    if data.get("repo"):
        compose.write_atomic(compose.state_path(), json.dumps({"repo": data["repo"]}) + "\n")
    if quick.hand(quick.list_pane(), "compose"):
        return True, tr("compose_sent_fmt", data["title"])
    seam = os.environ.get("FLEET_DISPATCH_SEND_CMD")
    argv = (seam.split() if seam else [sys.executable, str(BIN / "fleet-compose.py"), "--send"]) + [str(path)]
    try:
        out = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    except OSError as error:
        return False, tr("compose_failed_fmt", str(error))
    if out.returncode == 0:
        return True, tr("compose_result_fmt", compose.place_why(out.stdout or out.stderr))
    compose.keep_failed(path)
    return False, tr("compose_failed_fmt", compose.place_why((out.stdout or "") + "\n" + (out.stderr or ""))
                     or tr("compose_failed_unknown"))


def ui(screen, session=""):
    curses.use_default_colors()
    curses.raw()
    try:
        curses.curs_set(1)
    except curses.error:
        pass
    curses.init_pair(1, curses.COLOR_YELLOW, -1)
    curses.init_pair(2, -1, curses.COLOR_BLUE)
    curses.init_pair(3, curses.COLOR_RED, -1)
    screen.keypad(True)
    have = repos()
    repo = repo_default(have)
    title, codex, focus, note, bad = "", False, "title", "", False
    fields = ["title"] + (["repo"] if len(have) > 1 else []) + ["codex"]
    heal = quick.Heal()
    while True:
        screen.timeout(heal.timeout(False))
        height, width = screen.getmaxyx()
        heal.tick(screen)
        screen.erase()
        y = 0

        def line(text, attr=0, sel=False):
            nonlocal y
            if y >= height - 2:
                return
            try:
                base = curses.color_pair(2) if sel else 0
                screen.addstr(y, 0, " " * (width - 1), base)
                screen.addstr(y, 0, quick.clip(text, width - 1), base | attr)
            except curses.error:
                pass
            y += 1

        label = tr("dispatch_field_title") + "  "
        line(label + title, curses.A_BOLD)
        cursor = (0, min(width - 1, quick.cells(label + title)))
        line("─" * (width - 1), curses.A_DIM)
        if "repo" in fields:
            line("%s %s  ‹ %s ›" % ("›" if focus == "repo" else " ", tr("dispatch_field_repo"), repo),
                 sel=focus == "repo")
        elif repo:
            line("  %s  %s" % (tr("dispatch_field_repo"), repo), curses.A_DIM)
        line("%s %s  %s" % ("›" if focus == "codex" else " ", "[x]" if codex else "[ ]", tr("dispatch_field_codex")),
             sel=focus == "codex")
        if note:
            line("")
            line(note, (curses.color_pair(3) if bad else curses.color_pair(1)) | curses.A_BOLD)
        if height > 3:
            try:
                screen.addstr(height - 2, 0, "─" * (width - 1), curses.A_DIM)
                screen.addstr(height - 1, 1, quick.clip(tr("dispatch_keys"), width - 2), curses.A_DIM)
            except curses.error:
                pass
        try:
            curses.curs_set(1 if focus == "title" else 0)
            if focus == "title":
                screen.move(*cursor)
        except curses.error:
            pass
        screen.refresh()
        try:
            key = screen.get_wch()
        except curses.error:
            continue
        if key == curses.KEY_RESIZE:
            heal.resized(screen)
            continue
        if key in ("\x1b", "\x03", "\x07") or key == curses.KEY_EXIT:
            return 0
        note, bad = "", False
        if key in ("\n", "\r") or key == curses.KEY_ENTER:
            if not title.strip():
                note, bad = tr("compose_empty"), True
                continue
            if not repo:
                note, bad = tr("dispatch_norepo"), True
                continue
            note = tr("dispatch_sending")
            line(note, curses.color_pair(1))
            screen.refresh()
            ok, said = send(payload(title, repo, codex))
            if ok:
                quick.tmux("display-message", said)
                return 0
            note, bad = said, True
            continue
        if key in ("\t", curses.KEY_DOWN):
            focus = fields[(fields.index(focus) + 1) % len(fields)]
        elif key in (curses.KEY_BTAB, curses.KEY_UP):
            focus = fields[(fields.index(focus) - 1) % len(fields)]
        elif key == "\x18" or (focus == "codex" and key == " "):
            codex = not codex
        elif focus == "repo" and key in (curses.KEY_LEFT, curses.KEY_RIGHT, " ") and have:
            at = have.index(repo) if repo in have else 0
            repo = have[(at + (-1 if key == curses.KEY_LEFT else 1)) % len(have)]
        elif focus == "title" and key in (curses.KEY_BACKSPACE, "\x7f", "\x08"):
            title = title[:-1]
        elif focus == "title" and key == "\x15":
            title = ""
        elif isinstance(key, str) and key.isprintable():
            focus, title = "title", title + key


def opts(argv):
    out = {"--title": "", "--repo": "", "--session": ""}
    i = 0
    while i < len(argv):
        if argv[i] in out and i + 1 < len(argv):
            out[argv[i]] = argv[i + 1]
            i += 2
            continue
        out[argv[i]] = True
        i += 1
    return out


def main(argv):
    global TEXT
    locale.setlocale(locale.LC_ALL, "")
    TEXT = load_text()
    compose.TEXT = TEXT
    o = opts(argv[1:] if argv[:1] in (["payload"], ["send"]) else argv)
    if argv[:1] in (["payload"], ["send"]):
        data = payload(o["--title"], o["--repo"] or repo_default(), bool(o.get("--codex")))
        if not data:
            print(tr("compose_empty"), file=sys.stderr)
            return 2
        if argv[0] == "payload":
            print(json.dumps(data, ensure_ascii=False))
            return 0
        if not data["repo"]:
            print(tr("dispatch_norepo"), file=sys.stderr)
            return 2
        ok, said = send(data)
        print(said)
        return 0 if ok else 1
    os.environ.setdefault("ESCDELAY", "25")
    return curses.wrapper(ui, o["--session"])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
