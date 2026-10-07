#!/usr/bin/env python3
"""A compact live hub list. One view per attached fleet; no hidden render loops.

The worker keeps tmux's active-pane identity: collectors, messages and
recovery tools resolve a window to its active agent pane. The list only shows
and taps (issue #1950, EPIC #1949 C1): mouse forwarding delivers a tap or a
right-click to this view, and no key table ever routes the keyboard here — a
question it asks opens on one line under the session (bin/fleet-ask.py), and
what it has to say goes on the bar (`say`, tmux display-message).
"""
import curses
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import unicodedata

BIN = Path(__file__).absolute().parent  # preserve the selftest shadow root
US = "\x1f"
VIEW_VERSION = "28"  # #1953: 「新任务」 on top + `compose` · #1950: sessions only, no keys — questions under the session (fleet-ask.py)
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
# What the list has to say — a refusal, 「正在 m5 上开…」 — is on the bar this
# long (issue #1950: it was the input line's, for 4s).
TOAST_SECS = 10


def load_text():
    """Every string this view draws, from THE table (issue #1535): one
    `fleet-ui-lang.sh dump` at start — the shell resolves FLEET_UI_LANG / the
    locale exactly as every other fleet surface does, and a printf argument
    comes back as a \\001 slot for tr() to fill."""
    try:
        out = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "dump", "sidebar_", "no_repo", "needs_"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        out = b""
    parts = out.decode("utf-8", "replace").split("\0")
    return dict(zip(parts[0::2], parts[1::2]))


try:   # the reap-policy grammar (issue #1902) — one parser, beside this file
    import fleet_reap_policy
except ImportError:   # a half-synced install: rows simply carry no reap word
    fleet_reap_policy = None

TEXT = load_text()


def tr(key, *args):
    text = TEXT.get(key, key)   # a missing key shows itself, never a blank
    for arg in args:
        text = text.replace("\x01", str(arg), 1)
    return text.replace("\x01", "")


# The 置顶 group's heading key (issue #1170): selectable so ←/→ can fold it, but
# it names no repo — a tap only highlights it, never opens the new-session popup.
PIN_HEADING = "hdr:pin"
# The SHELL (bin/fleet-shell.sh, issue #1484) runs this view on a computer with
# no fleet: no conf, no gh, no worktree, and its install ships none of the
# scripts a new task / restore / scratch spawn runs. There every row is on a
# machine, so those keys open the session ON one, through the hub (place_start,
# issue #1778 — they only said so before, #1518).
SHELL = os.environ.get("FLEET_SHELL") == "1"


# The shell's STAGE (issue #1759, bin/fleet-shell.sh): a tmux server of its own
# holding one proxy window per machine, shown by a nested client in the right pane
# of the shell's one window. A switch is its `select-window` — never one here, so
# this server (the list, its borders, the bar) is not repainted. Unset (a fleet,
# or a shell started before the stage): everything below is as it was.
STAGE = os.environ.get("FLEET_SHELL_STAGE", "") if SHELL else ""

# The writing area (issue #1953, EPIC #1949 C4): with a stage, the list's first
# row is 「新任务」 — the stage's `@fleet_role portal` window, whose `@remote` is
# this key — then a rule. A tap (or ⌘N, prefix c) opens it (fleet-shell.sh
# portal); its ↵ queues `compose` here, and while the new session is on its way
# a 「开工中…」 row stands under it. Neither row is a session: no history entry,
# no ⌘↓ stop, never a place's answer.
PORTAL_KEY = "new"
PLACING_KEY = "placing"
PLACING_TITLE = 14   # cells of the sent title the 「开工中…」 row shows


# Switching from anywhere (issue #1903): ⌘↓ ⌘↑ ⌘[ ⌘] and ⌘P (conf/tmux-shell.conf)
# append verbs to this pane's @sidebar_do and wake it with F12; the history ⌘[ ⌘]
# walk and the rows ⌘P lists are written here, by the one view that knows them
# (bin/fleet-quickopen.py names the files). The client's list only — a node's
# selftest view writes them when FLEET_SWITCH_STATE points somewhere.
SWITCH_ON = SHELL or bool(os.environ.get("FLEET_SWITCH_STATE"))
_SWITCH = []


def switch_lib():
    """bin/fleet-quickopen.py as a module, loaded once (its name has a dash)."""
    if not _SWITCH:
        import importlib.util
        spec = importlib.util.spec_from_file_location("fleet_quickopen", str(BIN / "fleet-quickopen.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _SWITCH.append(mod)
    return _SWITCH[0]


def switch_visit(row):
    """The row in view became `row`: one step in the history (a step ⌘[ / ⌘]
    already stands on moves only its recency)."""
    if SWITCH_ON and row and row != PORTAL_KEY:
        lib = switch_lib()
        lib.save(lib.visit(lib.load(), row))


def take_switch(pane):
    """The verbs queued on @sidebar_do since the last wake, read and cleared in
    one tmux call — every press a step, none lost to a press racing the read."""
    return tmux("show-options", "-pqv", "-t", pane, "@sidebar_do", ";",
                "set-option", "-up", "-t", pane, "@sidebar_do").split()


def switch_target(verbs, rows, current, live, session=""):
    """Where the queued verbs land, read against the live rows: `next` / `prev`
    the session row below / above (no wrap), `back` / `fwd` the history, `jump=<key>`
    that row (⌘P's pick — it may sit in a folded subtree). Each verb steps from
    where the one before it landed. "" = stay. A history entry the list does not
    paint is looked up once among every session (folded ones too) before it is
    stepped over as closed. The 「新任务」 row is no stop (issue #1953)."""
    ids = [key for key in selectable(rows) if acts(key) and key != PORTAL_KEY]
    live = set(live)
    unfolded = []

    def alive(key):
        if key in live:
            return True
        if not unfolded:
            unfolded.append({r["key"] for r in (switch_lib().full_rows(session, timeout=4) or [])})
        return key in unfolded[0]
    base, target = current, ""
    for verb in verbs:
        nxt = ""
        if verb in ("next", "prev") and ids and (base in ids or not alive(base)):
            # from no row at all (nothing picked yet), the first / last; a row
            # not painted yet — a folded one ⌘P just opened, before the list's
            # next read — is no place to step from: stay, never the top
            i = ids.index(base) if base in ids else (-1 if verb == "next" else len(ids))
            j = i + (1 if verb == "next" else -1)
            nxt = ids[j] if 0 <= j < len(ids) else ""
        elif verb in ("back", "fwd") and SWITCH_ON:
            lib = switch_lib()
            hist = lib.load()
            nxt = lib.step(hist, alive, -1 if verb == "back" else 1)
            if nxt:
                lib.save(hist)
        elif verb.startswith("jump="):
            nxt = acts(verb[5:]) if verb[5:].startswith(("@", "wid:")) else ""
        if nxt:
            base = target = nxt
    return target


def bar_record(rows, current):
    """What the stage's top line says about the row in view (issue #1904), off
    the rows this list paints — so the line and the list never disagree: its
    place among the session rows (‹ i/n ›), state, needs kind, key, title, PR,
    repo (only in a fleet showing more than one), machine and whether it is lost,
    and how many rows wait on you. None when the row is not on the list — or is
    the writing area (issue #1953): the top line is then its window's name."""
    if current == PORTAL_KEY:
        return None
    ids = [key for key in selectable(rows) if acts(key) and key != PORTAL_KEY]
    repos, repo, slug, hit = set(), "", "", None
    for row in rows:
        if row[0] == "hdr":
            if len(row) > 3 and row[1] and row[1] != PIN_HEADING[4:]:
                repo, slug = row[3].strip().lstrip("▸ ").strip(), row[1]
                repos.add(slug)
            continue
        if row[0] == current:
            hit = (row, repo, slug)
    if hit is None:
        return None
    row, repo, slug = hit
    row = list(row) + [""] * (14 - len(row))
    kind = ""
    if row[1] == "needs":
        kind = "perm" if row[7] == tr("needs_perm") else "ask"
    node = row[8]
    pr = row[10] if row[10] not in ("", "—", "·") else ""
    return {
        "i": ids.index(current) + 1 if current in ids else 0, "n": len(ids),
        "state": row[1], "kind": kind, "key": row[9] if row[9] not in ("—", "·") else "",
        "title": (row[13] or row[3]).strip(), "pr": pr,
        "repo": repo if len(repos) > 1 else "", "slug": slug if slug != "none" else "",
        "node": machine_tag(node.rstrip("!~"))[1:] if node.rstrip("!~") else tr("sidebar_here"),
        "lost": node.endswith("!"), "direct": node.endswith("~"),
        "ask": sum(1 for r in rows if r[0] != "hdr" and r[1] in FOLD_KEEP),
        # the session's worker id: the top line matches it against what the
        # person's other clients are viewing (issue #1932)
        "wid": current[4:] if current.startswith("wid:") else "",
    }


def publish_bar(rows, current, last):
    """Write the top line's record (bar_record) for the stage, only on change, and
    bump the stage session's `@fleet_bar_gen`: the stage's status-left names it,
    so tmux runs the line again at once (bin/fleet-topbar.py)."""
    rec = bar_record(rows, current)
    text = json.dumps(rec, ensure_ascii=False, sort_keys=True)
    if text == last:
        return last
    if switch_lib().write_atomic(switch_lib().state_dir() / "switch-bar.json", text + "\n"):
        run(["tmux", "-L", STAGE, "set-option", "-t", "=" + STAGE, "@fleet_bar_gen",
             str(time.time_ns())])
        return text
    return last


def stage_remote():
    """`@remote` of the stage's current window — the row the right pane shows."""
    if not STAGE:
        return ""
    return run(["tmux", "-L", STAGE, "display-message", "-p", "-t", "=" + STAGE + ":",
                "#{@remote}"]).stdout.strip()



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
                   "#{@sidebar_version}", "#{@sidebar_slot}",
                   # a question's pane (bin/fleet-ask.py): its mark, or — the
                   # moment before the mark lands — its program
                   "#{?#{@stage_ask},1,#{?#{m:*fleet-ask.py run*,#{pane_start_command}},1,}}"))
    return [line.split(US) for line in tmux(
        "list-panes", "-s", "-t", session, "-F", fmt).splitlines()
        if len(line.split(US)) == 9]


def is_worker(pane):
    """A panes() row that is the window's own content: not the view, not a slot,
    not a question open under the session (`@stage_ask`, bin/fleet-ask.py)."""
    return pane[2] != "1" and pane[7] != "1" and pane[4] != "1" and pane[8] != "1"


def remove_view(pane):
    # Verify ownership immediately before removal; never close an agent pane.
    if fields(pane, "#{@sidebar}") == ["1"]:
        tmux("set-option", "-uw", "-t", pane, "@sidebar_worker")
        tmux("kill-pane", "-t", pane)


# The SLOT (issue #1702). There is one view and it moves; moving it with
# join-pane re-lays out BOTH windows — the one it leaves widens its app pane back
# to full width, the one it enters narrows it — and every resize is a SIGWINCH
# into the program inside. In a proxy window (`@remote`) that program is another
# machine's Claude Code, so each switch between machines repainted two whole
# screens, one of them across the network. So a proxy window the view leaves
# keeps a SLOT in the view's cell: a blank pane of the same width, swapped with
# the view (`swap-pane` between two same-size cells resizes nothing). Steady
# state, switching between machines changes no app pane's size at all. A local
# window keeps none — its content repaints locally, and every reader that wants
# "the one worker pane" stays as it was. The slot exits on its own once it is
# alone in its window, so it never keeps a closed proxy window open.
SLOT_CMD = ("printf '\033[?25l'; while sleep 5; do "
            "n=$(tmux display-message -p -t \"$TMUX_PANE\" '#{window_panes}' 2>/dev/null) || exit 0; "
            "[ \"${n:-1}\" -gt 1 ] || exit 0; done")


def remove_slot(pane):
    # Ownership first, as remove_view: never close an agent pane.
    if fields(pane, "#{@sidebar_slot}") == ["1"]:
        tmux("kill-pane", "-t", pane)


def make_slot(worker, width):
    """A slot beside `worker`, in the cell a view would take. "" on failure."""
    slot = tmux("split-window", "-d", "-h", "-b", "-f", "-l", str(width),
                "-t", worker, "-c", str(BIN.parent), "-P", "-F", "#{pane_id}",
                "sh", "-c", SLOT_CMD)
    if not slot.startswith("%"):
        return ""
    tmux("set-option", "-p", "-t", slot, "@sidebar_slot", "1", ";",
         "set-option", "-p", "-t", slot, "remain-on-exit", "off")
    return slot


def window_slot(window):
    """(pane id, width) of the first live slot in `window`, or ("", "")."""
    for line in tmux("list-panes", "-t", window, "-F",
                     US.join(("#{pane_id}", "#{@sidebar_slot}", "#{pane_dead}",
                              "#{pane_width}"))).splitlines():
        part = line.split(US)
        if len(part) == 4 and part[1] == "1" and part[2] != "1":
            return part[0], part[3]
    return "", ""


def move_view(pane, worker, width, select=False):
    """Move the populated grid before selecting its new window, in one queue."""
    source = fields(pane, US.join(("#{window_id}", "#{@sidebar}", "#{@remote}")))
    target = fields(worker, US.join(("#{window_id}", "#{window_width}",
                                    "#{window_zoomed_flag}")))
    if len(source) != 3 or source[1] != "1" or len(target) != 3:
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
                    "set-option", "-w", "-t", window, "@sidebar_worker", worker, ";"]
        # A slot to swap with (issue #1702, SLOT_CMD): the target's own, or — when
        # the view leaves a proxy window, which keeps one — a new one made in the
        # target (that window's one resize, the join's). Leaving a local window,
        # the slot it is handed is closed at once: that window widens as before.
        slot, slot_width = window_slot(window)
        keep = bool(source[2])
        if not slot and keep:
            slot, slot_width = make_slot(worker, width), str(width)
        if slot:
            if slot_width != str(width):
                commands += ["resize-pane", "-t", slot, "-x", str(width), ";"]
            commands += ["swap-pane", "-d", "-s", pane, "-t", slot]
            if not keep:
                commands += [";", "kill-pane", "-t", slot]
        else:
            commands += ["join-pane", "-d", "-h", "-b", "-f", "-l", str(width),
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


def leave_navigation(session):
    # No client is ever left in the list's old key table, nor with its pane
    # pinned to the list (issue #1105's paste route, retired with the input line
    # by #1950): a client a since-upgraded conf left there is handed back.
    for client, table, pinned in clients(session):
        if table == "fleet-sidebar":
            tmux("switch-client", "-c", client, "-T", "root")
        if pinned:
            tmux("refresh-client", "-t", client, "-f", "!active-pane")


def heal_frame(session, window):
    """The client's `home` (`@shell_frame`, issue #1785) never loses its right
    pane. That pane is the stage's viewer (fleet-shell.sh viewer); it is kept with
    remain-on-exit, so whatever ends it — a kill, a crash, a disconnect — leaves a
    DEAD pane, respawned here. A pane gone outright (a kill-pane typed at the
    prompt, a shell started before this) leaves the list alone in the window: the
    list's own pane becomes the viewer, and the sync below draws the list again
    beside it. Returns whether anything was respawned."""
    frame = [p for p in panes(session) if p[1] == window]
    content = [p for p in frame if p[2] != "1" and p[7] != "1" and p[8] != "1"]
    if not frame or any(p[4] != "1" for p in content):
        return False
    target = content[0][0] if content else next(
        (p[0] for p in frame if p[2] == "1"), frame[0][0])
    # One that died within 2s of its last respawn waits a little first: a viewer
    # that cannot start must not spin the hooks.
    last = (fields(target, "#{@shell_viewer_at}") + [""])[0]
    hold = "sleep 2; " if last.isdigit() and time.time() - int(last) < 2 else ""
    cmd = hold + "exec bash " + shlex.quote(str(BIN / "fleet-shell.sh")) + " viewer " + shlex.quote(session)
    if run(["tmux", "respawn-pane", "-k", "-t", target, "-c", os.path.expanduser("~"),
            cmd]).returncode != 0:
        return False
    tmux("set-option", "-pu", "-t", target, "@sidebar", ";",
         "set-option", "-pu", "-t", target, "@sidebar_version", ";",
         "set-option", "-pu", "-t", target, "@sidebar_slot", ";",
         "set-option", "-p", "-t", target, "@shell_viewer", "1", ";",
         "set-option", "-p", "-t", target, "@shell_viewer_at", str(int(time.time())), ";",
         "set-option", "-p", "-t", target, "remain-on-exit", "on")
    return True


def single_layout(frame, cols, width):
    """Whether the client's `home` shows ONE pane (issue #1904): only the
    client's frame (`@shell_frame`), never a fleet window. FLEET_CLIENT_LAYOUT is
    auto (the default: one pane when the list does not fit beside 80 columns of
    session — the width under which the list used to be taken away with nothing
    in its place), single (always) or split (never: the old rule, byte for byte)."""
    if not (SHELL and frame) or not cols.isdigit():
        return False
    layout = os.environ.get("FLEET_CLIENT_LAYOUT", "auto")
    if layout == "single":
        return True
    if layout == "split":
        return False
    return int(cols) < width + 1 + 80


def fit_single(window, workers, single, wanted, zoomed, asking=False):
    """Hold the one-pane layout (issue #1904) on the client's `home`: single →
    the session pane zoomed and `@fleet_single` on the window (the conf's keys
    and F1–F4 read it); not single → `@fleet_single` off and the zoom it made
    undone — a zoom the person made (F9) is theirs and stays. A question open
    under the session (`asking`, bin/fleet-ask.py — its split unzoomed the
    window) is not zoomed away: the zoom comes back when it closes. Returns the
    window's zoom flag after it, as sync reads it."""
    was = fields(window, "#{@fleet_single}") == ["1"]
    if single and wanted and workers:
        if not was:
            tmux("set-option", "-w", "-t", window, "@fleet_single", "1")
        if zoomed != "1" and not asking:
            worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
            tmux("resize-pane", "-Z", "-t", worker)
        return "1"
    if was:
        tmux("set-option", "-uw", "-t", window, "@fleet_single")
        if zoomed == "1":
            tmux("resize-pane", "-Z", "-t", window)
            return "0"
    return zoomed


def sync(session, enabled, width, lock):
    info = fields(session + ":", US.join(("#{window_id}", "#{window_name}",
                  "#{window_width}", "#{session_attached}", "#{@issue}",
                  "#{@raw}", "#{@worktree}", "#{@norepo}", "#{window_zoomed_flag}",
                  "#{@sidebar_width_manual}", "#{@remote}", "#{@shell_frame}")))
    if len(info) != 12:
        return
    (window, name, cols, attached, issue, raw, worktree, norepo, zoomed, manual,
     remote, frame) = info
    if frame:
        heal_frame(session, window)  # the right pane first: the list's worker
    # A width the operator dragged to (issue #1328) is the width from then on.
    if manual.isdigit():
        width = max(24, min(60, int(manual)))
    all_panes = panes(session)
    workers = [p for p in all_panes if p[1] == window and is_worker(p)]
    # The client's one-pane layout (issue #1904): the client's `home` on a
    # screen too narrow for the list beside 80 columns of session (a phone, an
    # iPad in portrait), or FLEET_CLIENT_LAYOUT=single. The list stays — zoomed
    # away behind the session, still reading rows and taking the queued switches
    # — and the stage's top line is the way round (‹ › and the switcher).
    single = single_layout(frame, cols, width)
    # A node's fleet session never gets here with enabled == "1" (issue #1713:
    # fleet-sidebar.sh draws the list only on the client's server), so a viewer
    # needs no marker of its own any more — one list, the client's.
    wanted = (enabled == "1" and attached != "0" and
              name not in ("plan", "dash", "backlog") and
              # A task: issue worker, repo scratch, a no-repo session in $HOME (#996),
              # or a proxy window onto another machine's session (`@remote`, #1475):
              # the list stays on the left, the other machine's pane on the right.
              # `home` — the fleet's resting window once the full-screen list
              # retired (issue #1533): a shell, but the list is how a fleet with
              # no task yet starts one (a heading's tap), so it shows there too.
              bool(issue or raw == "1" or worktree or norepo == "1" or remote or
                   name == "home") and
              bool(workers) and (single or int(cols) >= width + 1 + 80))
    if frame and not (single and wanted):
        zoomed = fit_single(window, workers, False, wanted, zoomed)
    elif frame and zoomed == "1" and not any(p[1] == window and p[2] == "1" for p in all_panes):
        # one pane, and no list behind it yet: unzoom so it can be drawn (below)
        tmux("resize-pane", "-Z", "-t", window)
        zoomed = "0"
    if not wanted or zoomed == "1":
        leave_navigation(session)
    # Slots (issue #1702): none at all while the list is off; none in a window
    # with no content left (the slot must not hold it open); and none in the
    # window on screen unless the view is about to take it — below.
    hosts = {p[1] for p in all_panes if is_worker(p)}
    slots = [p for p in all_panes if p[7] == "1" and p[4] != "1"]
    for pane in slots:
        if enabled != "1" or pane[1] not in hosts:
            remove_slot(pane[0])
    here = next((p[0] for p in slots if p[1] == window and enabled == "1" and p[1] in hosts), "")
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
    if single and wanted and current:
        asking = any(p[1] == window and p[8] == "1" for p in all_panes)
        zoomed = fit_single(window, workers, True, wanted, zoomed, asking)
    if not wanted or current or zoomed == "1":
        # The window on screen shows no list: its slot would be a blank column.
        if here and zoomed != "1":
            remove_slot(here)
        return
    worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
    if reusable:
        if move_view(reusable[0][0], worker, width):
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
    if here and run(["tmux", "respawn-pane", "-k", "-t", here, "-c", cwd, cmd]).returncode == 0:
        # The window keeps a slot (issue #1702): the new view takes its cell.
        pane = here
        tmux("set-option", "-up", "-t", pane, "@sidebar_slot")
    else:
        pane = tmux("split-window", "-d", "-h", "-b", "-f", "-l", str(width),
                    "-t", worker, "-c", cwd, "-P", "-F", "#{pane_id}", cmd)
    if not pane.startswith("%"):
        return
    tmux("set-option", "-p", "-t", pane, "@sidebar", "1", ";",
         "set-option", "-p", "-t", pane, "@sidebar_version", VIEW_VERSION, ";",
         "set-option", "-w", "-t", pane, "@sidebar_worker", worker, ";",
         "set-option", "-p", "-t", pane, "remain-on-exit", "off")
    if single:
        fit_single(window, workers, True, wanted, "0")


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
    if window == PORTAL_KEY:
        # 「新任务」 (issue #1953): the stage's writing-area window, made once.
        open_portal(session)
        return True
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
        if STAGE and stage_remote():
            # The shell's stage (issue #1759): `open` selected the row's window
            # THERE, and the right pane shows it — the list stays where it is.
            return True
        window = out.stdout.strip().split("\n")[-1] if out.returncode == 0 else ""
    # Never resolve a stale row through a recycled index, or another fleet.
    if not window.startswith("@") or fields(window, "#{?#{session_group},#{session_group},#{session_name}}") != [session]:
        return True
    with open(lock, "w") as handle:
        if not lock_within(handle, env_float("FLEET_SIDEBAR_LOCK_WAIT", LOCK_WAIT)):
            return False
        workers = [p for p in panes(session) if p[1] == window and is_worker(p)]
        if workers:
            worker = next((p[0] for p in workers if p[3] == "1"), workers[0][0])
            width = fields(pane, "#{pane_width}")[0]
            if width.isdigit() and move_view(pane, worker, int(width), select=True):
                return True
            tmux("select-window", "-t", window, ";", "select-pane", "-t", worker)
    return True


def open_portal(session):
    """The writing area on the right (issue #1953): fleet-shell.sh portal — the
    same door ⌘N and prefix c take."""
    run(["bash", str(BIN / "fleet-shell.sh"), "portal", session], stdin=subprocess.DEVNULL)


def with_portal(rows, placing):
    """The rows as painted in the shell (issue #1953): 「新任务」, the 「开工中…」 row
    of a task ↵ just sent, a rule — then the list. Built again every frame from
    the list without them, so a fresh producer frame and a place ending both
    show at once."""
    if not STAGE:
        return rows
    body = [row for row in rows if row[0] not in (PORTAL_KEY, PLACING_KEY) and
            not (row[0] == "hdr" and row[1] == "" and row[2] == "─")]
    pad = [""] * (ROW_FIELDS - 9)
    top = [[PORTAL_KEY, "portal", "+", tr("sidebar_portal"), " ", "", "0", "", ""] + pad]
    if placing is not None and placing.get("verb") == "compose" and placing.get("state") in ("placing", "await"):
        title = placing.get("title", "")
        if cells_of(title) > PLACING_TITLE:   # never the row that widens the list
            title = clip(title, PLACING_TITLE - 1) + "…"
        top.append([PLACING_KEY, "working", "⠇", tr("sidebar_portal_placing_fmt", title),
                    " ", "", "0", "", ""] + pad)
    top.append(["hdr", "", "─", "─" * 120] + [""] * (ROW_FIELDS - 4))
    return top + body


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
    """One short question (issue #1620, EPIC #1615 C5): a rename, a new task's
    title, a repo to add, a message or an answer for a row on another machine,
    the account to switch a worker to, the #543 restore question, a step of the
    shell's open-a-session flow. Asked on ONE line under the session since
    issue #1950 (bin/fleet-ask.py — the list has no input line any more): `kind`
    picks what the answer runs (`answered` in ui); `prompt` leads the line,
    `text` is what it starts with (a rename's old name), `hint` sits at its
    right; `choices` ((value, label) pairs) are what Tab steps through — a new
    task's repo in a 2+ repo fleet, a subscription's account; `keys` makes it a
    one-key question (restore: y / r, anything else cancels); a `menu` is
    (value, label, note, greyed) lines above it, ↑↓ / Tab between the ones that
    are not greyed, ↵ picks."""

    def __init__(self, kind, prompt, arg="", hint="", node="", repo="", keys="", menu=None, plan=None, text=""):
        self.kind, self.prompt, self.arg, self.hint = kind, prompt, arg, hint
        self.node, self.repo, self.keys, self.text = node, repo, keys, text
        self.choices, self.at, self.where = [], -1, ""
        # `plan` is the shell's open-a-session flow a menu is one step of.
        self.menu, self.plan = menu, plan
        if menu:
            self.at = next((i for i, item in enumerate(menu) if not item[3]), 0)

    def spec(self):
        """What bin/fleet-ask.py draws: the question as JSON. A new task's
        choices are its repos, each with the hint that names it (`new_hint`);
        an account's fill the line."""
        out = {"kind": self.kind, "prompt": self.prompt.rstrip(), "text": self.text,
               "hint": self.hint or ("" if self.keys or self.menu else tr("sidebar_ask_keys")),
               "keys": self.keys}
        if self.menu:
            out["menu"] = [list(item) for item in self.menu]
            out["at"] = self.at
        elif self.choices:
            if self.kind == "new":
                was = self.repo
                out["choices"] = []
                for value, _label in self.choices:
                    self.repo = value
                    out["choices"].append([value, new_hint(self)])
                self.repo = was
            else:
                out["choices"] = [list(c) for c in self.choices]
                out["fill"] = True
            out["at"] = self.at
        return out


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
    `done(rc, output)` when it exits, which answers (a word, the next ask) — a
    refusal is one line on the bar, a success says nothing (EPIC #1615).
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
    fresh quota as the hint; the question opens once they are read. A refusal
    (no fresh quota) is said on the bar instead."""
    def done(rc, text):
        rows = [l.split("\t") for l in text.splitlines()[1:] if l.count("\t") >= 3]
        if rc != 0 or not rows:
            return "✗ " + (last_line(text) or tr("sidebar_spawn_failed")), None
        ask.choices = [(r[0], " · ".join(x for x in (r[0], "5h " + r[1] if r[1] else "", "7d " + r[2] if r[2] else "", r[3]) if x))
                       for r in rows]
        ask.hint = tr("sidebar_ask_sub_hint")
        return "", ask
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


# The shell's new / restore / scratch (issue #1778): the computer has no fleet,
# so each opens a session ON a machine through the hub — fleet-client-place.sh
# (#1777). First the repo (the list's own repo headings), then — ⌃n / ⌃o — the
# issue or the key on the input line, then 「开在哪」: 自动 · each machine that
# can take one, idlest first · the ones that cannot, greyed. Off the hub's
# /v1/nodes, as the refresh loop cached it (global/hub_nodes). The place runs in
# the background, the top row says where it is opening, and when the hub's list
# carries the new session it is selected and switched to.
PLACE_WORDS = ("REMOTE", "LOCAL", "HELD", "REFUSED", "DECLINED", "UNKNOWN")
# How long the new row may take to show in the list after the hub said done:
# the refresh loop's round (2 s while someone looks) plus the node's report.
PLACE_FIND_SECS = 30


def status_dir():
    """The refresh loop's cache dir (fleet-status-lib.sh FLEET_STATUS_G)."""
    return os.environ.get("FLEET_STATUS_G") or os.path.join(
        os.environ.get("TMPDIR") or "/tmp", ".claude-dash", "global")


def hub_down():
    """The bar's 入口连不上 (fleet_status_hub_lost): the last round of the refresh
    loop that stood is older than FLEET_HUB_SESSIONS_STALE. No hub_ok at all — a
    shell with no hub — is not «down»: fleet-client-place.sh decides there."""
    try:
        with open(os.path.join(status_dir(), "hub_ok")) as f:
            ts = int((f.read().split() or ["0"])[0])
    except (OSError, ValueError):
        return False
    return time.time() - ts > env_int("FLEET_HUB_SESSIONS_STALE", 60)


def where_menu():
    """「开在哪」: (node, label, note, greyed) — 自动 first, then every machine
    that can take a session by its count of running ones, then the ones that
    cannot (only coordinates, 维护中, 失联), greyed. node is the hostname the hub
    resolves (hub_nodes' 13th field), the label what this login calls it."""
    try:
        with open(os.path.join(status_dir(), "hub_nodes"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        lines = []
    can, cannot = [], []
    for line in lines:
        f = line.split(US)
        if not f[0] or f[0].startswith("#") or len(f) < 6:
            continue
        f += [""] * (13 - len(f))
        label, av, sess, word, host = f[0], f[1], f[5], f[11], f[12] or f[0]
        if word == "coord":
            cannot.append((0, (host, label, tr("sidebar_place_coord"), True)))
        elif word == "maint":
            cannot.append((1, (host, label, tr("sidebar_place_maint"), True)))
        elif av != "online":
            cannot.append((2, (host, label, tr("sidebar_place_lost"), True)))
        else:
            n = int(sess) if sess.isdigit() else 1 << 30   # `?`: unknown, last
            can.append((n, (host, label, tr("sidebar_place_running_fmt", sess), False)))
    return ([("auto", tr("sidebar_place_auto"), tr("sidebar_place_rec"), False)] +
            [item for _, item in sorted(can, key=lambda c: c[0])] +
            [item for _, item in sorted(cannot, key=lambda c: c[0])])


def shell_repos(rows):
    """The repos the shell's list shows — its `hdr:<owner/name>` headings."""
    out = []
    for row in rows:
        key = key_of(row)
        if key.startswith("hdr:") and "/" in key and key[4:] not in out:
            out.append(key[4:])
    return out


def hub_repos():
    """The repos the hub says this person's machines host (issue #1927):
    fleet-hub-sessions.sh's global/hub_repos, one per line under its `#ts`
    line. None when there is no file (no hub, or a round that never stood);
    [] when the hub answered and no machine of theirs hosts one."""
    try:
        with open(os.path.join(status_dir(), "hub_repos"), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    return [r for r in lines if r and not r.startswith("#") and "/" in r]


def repo_of(rows, key):
    """The repo a highlighted row is in: a heading's own, else the nearest
    heading above the row. "" when neither names one."""
    if key.startswith("hdr:"):
        return key[4:] if "/" in key else ""
    repo = ""
    for row in rows:
        k = key_of(row)
        if k.startswith("hdr:"):
            repo = k[4:] if "/" in k else ""
        elif k == key:
            return repo
    return ""


def place_start(verb, rows, anchor, name="", pin=False):
    """⌃n (`new`), ⌃o (`restore`), ⌃s / a typed name (`scratch`) in the shell:
    the first question — or (None, toast) when nothing can be opened. `pin` (a
    heading's second tap) skips the repo question: the heading named it."""
    if hub_down():
        return None, tr("sidebar_place_hubdown")
    repos = shell_repos(rows)
    if not repos:
        # An empty list (a newcomer's first look, issue #1927): the repos the
        # hub says their machines host; none there is a person no machine
        # was given to yet — say who to ask.
        repos = hub_repos()
        if repos is None:
            return None, tr("sidebar_place_norepo")
        if not repos:
            return None, tr("sidebar_place_nohost")
    plan = {"verb": verb, "name": name, "repo": repo_of(rows, anchor)}
    if (pin and plan["repo"]) or len(repos) == 1:
        plan["repo"] = plan["repo"] or repos[0]
        return place_after_repo(plan), ""
    ask = Ask("place-repo", tr("sidebar_place_repo"), hint=tr("sidebar_place_keys"), plan=plan,
              menu=[(r, r.rsplit("/", 1)[-1], r.split("/", 1)[0], False) for r in repos])
    if plan["repo"] in repos:
        ask.at = repos.index(plan["repo"])
    return ask, ""


def place_after_repo(plan):
    """The repo is known: ⌃n asks the issue, ⌃o the key; a scratch goes on."""
    short = plan["repo"].rsplit("/", 1)[-1]
    if plan["verb"] == "new":
        return Ask("place-issue", tr("sidebar_place_issue"), plan=plan,
                   hint=tr("sidebar_place_issue_hint_fmt", short))
    if plan["verb"] == "restore":
        return Ask("place-restore", tr("sidebar_place_restore"), plan=plan,
                   hint=tr("sidebar_place_restore_hint_fmt", short))
    plan["what"] = "scratch"
    return place_where(plan)


def place_where(plan):
    """The last question: 「开在哪」, 自动 highlighted."""
    short = plan["repo"].rsplit("/", 1)[-1]
    what = plan["what"]
    if what == "scratch":
        what = tr("sidebar_place_draft_fmt", plan.get("name") or "").strip()
    elif what.startswith("restore:"):
        what = what[len("restore:"):]
    else:
        what = "#" + what
    return Ask("place-where", tr("sidebar_place_where_fmt", short + " " + what),
               hint=tr("sidebar_place_keys"), menu=where_menu(), plan=plan)


def place_answer(ask, value):
    """One answer to a step of the flow: (the next Ask, a toast, start?) —
    start is True once 「开在哪」 is answered and the place should run."""
    plan = ask.plan
    if ask.kind == "place-repo":
        plan["repo"] = value
        if plan.get("verb") == "compose":
            return None, "", True   # the writing area (issue #1953): the rest is said
        return place_after_repo(plan), "", False
    if ask.kind == "place-issue":
        text = value.strip().lstrip("#")
        if not text:
            return None, "", False
        if text.isdigit() and int(text) > 0:
            plan["what"] = text
        else:
            plan["what"], plan["name"] = "scratch", value.strip()
        return place_where(plan), "", False
    if ask.kind == "place-restore":
        text = value.strip().lstrip("#")
        if text.isdigit():
            text = "issue-" + text
        if not re.fullmatch(r"(issue|scratch)-[1-9][0-9]*", text):
            return None, ("✗ " + tr("sidebar_place_restore_hint_fmt", plan["repo"].rsplit("/", 1)[-1])
                          if text else ""), False
        plan["what"] = "restore:" + text
        return place_where(plan), "", False
    if ask.kind == "place-where":
        item = next((m for m in ask.menu if m[0] == value), None)
        if item is None or item[3]:
            return None, ("✗ " + tr("sidebar_place_cant_fmt", item[1], item[2]) if item else ""), False
        plan["node"], plan["label"] = item[0], "" if item[0] == "auto" else item[1]
        if plan["what"].startswith("restore:"):
            return None, "", True   # a restored session keeps the policy it had
        return place_reap(plan), "", False
    if ask.kind == "place-reap":
        if value == "at":
            return Ask("place-reap-at", tr("sidebar_place_reap_at_ask"), plan=plan,
                       hint=tr("sidebar_place_reap_bad")), "", False
        # The kind's default is not sent (the opening machine stamps it the same),
        # so a hub from before #1902 sees exactly the request it always did.
        dflt = "merged" if plan["what"] != "scratch" else "done:2h"
        plan["reap"] = "" if value == dflt else value
        return None, "", True
    if ask.kind == "place-reap-at":
        text = value.strip()
        if not text:
            return None, "", False
        canon = fleet_reap_policy.norm("at:" + text) if fleet_reap_policy else None
        if not canon:
            return None, "✗ " + tr("sidebar_place_reap_bad"), False
        plan["reap"] = canon
        return None, "", True
    return None, "", False


# 「什么时候回收？」(issue #1902): the five reap policies, the kind's default
# highlighted so ↵ takes it — merged for an issue, done:2h for a scratch.
REAP_CHOICES = (("merged", "sidebar_place_reap_merged"), ("done:2h", "sidebar_place_reap_done"),
                ("loop-end", "sidebar_place_reap_loop_end"), ("at", "sidebar_place_reap_at"),
                ("keep", "sidebar_place_reap_keep"))


def place_reap(plan):
    """The last question of a new session: when may the fleet close it?"""
    short = plan["repo"].rsplit("/", 1)[-1]
    dflt = "merged" if plan["what"] != "scratch" else "done:2h"
    menu = []
    for value, key in REAP_CHOICES:
        label, _, note = tr(key).partition("\t")
        if value == dflt:
            note = (note + " · " if note else "") + tr("sidebar_place_reap_default")
        menu.append((value, label, note, False))
    ask = Ask("place-reap", tr("sidebar_place_reap_fmt", short), plan=plan,
              hint=tr("sidebar_place_reap_keys", next(m[1] for m in menu if m[0] == dflt)), menu=menu)
    ask.at = [m[0] for m in menu].index(dflt)
    return ask


def place_job(plan, rows, env):
    """fleet-client-place.sh for the answered flow, in the background. The keys
    the list holds now are kept: the new session is the row that was not there."""
    plan["known"] = {key_of(row) for row in rows}
    plan["note"] = (tr("sidebar_place_opening_fmt", plan["label"]) if plan["label"]
                    else tr("sidebar_place_opening_auto"))
    plan["state"] = "placing"
    if plan.get("verb") == "compose":
        # The writing area's one way out (issue #1953): fleet-compose.py --send,
        # which says fleet-client-place.sh's line and code as they are.
        how = {"none": ["--no-repo"], "multi": ["--multi"]}.get(plan.get("repo_mode", ""), ["--repo", plan["repo"]])
        args = [sys.executable, str(BIN / "fleet-compose.py"), "--send", plan["payload"]] + how + \
            ["--node", plan["node"]]
        if plan.get("reap"):
            args += ["--reap", plan["reap"]]
        return start_job(args, env, placed(plan))
    args = ["bash", str(BIN / "fleet-client-place.sh"), plan["repo"], plan["what"],
            "--node", plan["node"]]
    if plan.get("name") and plan["what"] == "scratch":
        args += ["--name", plan["name"]]   # an argv word: no shell parses it
    if plan.get("reap"):
        args += ["--reap", plan["reap"]]   # canonical: fleet_reap_policy.norm (#1902)
    return start_job(args, env, placed(plan))


def placed(plan):
    """fleet-client-place.sh's one line, in words (its exit codes, #1777): done →
    wait for the row; the issue held elsewhere → «y 切过去»; a refusal → its
    reason as the hub said it; the hub not reachable → 入口连不上."""
    def done(rc, text):
        if plan.get("payload"):
            try:
                os.unlink(plan["payload"])
            except OSError:
                pass
        line = next((l for l in reversed(text.splitlines()) if l.split(" ", 1)[0] in PLACE_WORDS), "")
        head, _, why = line.partition("\t")
        words = head.split()
        machine = words[1] if len(words) > 1 else plan.get("label") or ""
        plan["state"] = "end"
        if rc == 0 and words[:1] in (["REMOTE"], ["LOCAL"]):
            who = words[4] if words[0] == "REMOTE" and len(words) > 4 else ""
            plan.update(state="await", machine=machine, key="wid:" + who if "/" in who else "",
                        until=time.monotonic() + PLACE_FIND_SECS,
                        note=tr("sidebar_place_opening_fmt", machine))
            return "", None
        if rc == 3:
            return "", Ask("place-held", tr("sidebar_place_held_fmt", machine), hint=why.strip(),
                           keys="yY", node=machine, plan=plan)
        if rc == 4:
            return "✗ " + tr("sidebar_place_refused_fmt", why.strip() or head), None
        if rc == 5:
            return "✗ " + tr("sidebar_place_declined_fmt", machine, why.strip() or head), None
        if rc == 6:
            return tr("sidebar_place_unknown_fmt", machine), None
        last = last_line(text)
        if rc == 1 and re.search(r"HTTP 4(0[0-9]|[1-9][0-9])", last) and "HTTP 401" not in last:
            # the hub answered and said no (a bad scratch name, …): its words
            return "✗ " + tr("sidebar_place_refused_fmt", last.split(": ", 2)[-1]), None
        if rc == 1:
            return "✗ " + tr("sidebar_place_hubdown"), None
        return failed(rc, text)
    return done


def place_found(rows, plan):
    """The new session's row once the list carries it: the worker_id the hub
    named; else the row of this issue / key on that machine; else a row that was
    not there when the place started, on that machine. "" until then."""
    rows = [row for row in rows if row[0] not in (PORTAL_KEY, PLACING_KEY)]
    keys = [key_of(row) for row in rows if row[0] != "hdr"]
    if plan.get("key") in keys:
        return plan["key"]
    return held_row(rows, plan, plan.get("machine", ""), fresh=True)


def held_row(rows, plan, machine, fresh=False):
    """A row of the plan's issue / restore key — on `machine` first, then on
    any (the hub's name for a machine and this login's may differ); `fresh`
    adds a row the list did not hold when the place started, likewise."""
    what = plan.get("what", "")
    want = ("issue-" + what if what.isdigit() else
            what[len("restore:"):] if what.startswith("restore:") else "")
    known = plan.get("known") or set()
    live = [row for row in rows if row[0] != "hdr"]

    def on(row):
        return not machine or (row[8] if len(row) > 8 else "").rstrip("!~") in (machine, "")

    def ours(row):
        return bool(want) and (row[0].endswith("/" + want) or
                               (what.isdigit() and len(row) > 9 and row[9] == what))

    tests = [lambda r: on(r) and ours(r), ours]
    if fresh:
        tests += [lambda r: on(r) and r[0] not in known, lambda r: r[0] not in known]
    for test in tests:
        hit = [row[0] for row in live if test(row)]
        if hit:
            return hit[-1]
    return ""


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


def open_tap(session, action, key, env):
    """A second tap (issue #1032): a session row's menu, or — on a selected
    heading — a new task's title asked under the session with that repo pinned
    (selection_repo resolves `hdr:…` exactly as it does for a typed name, so both
    paths agree on the target). Returns that Ask; "refused" in the shell, which
    has no fleet to file into — the caller asks there instead (place_start,
    issue #1778); None after opening a menu."""
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
    # names the machine (`<name> · 在 m4`), as the row's own @ mark does (#1780).
    if wid.startswith("@") or (wid.startswith("wid:") and "/" in wid):
        subprocess.Popen(["bash", str(BIN / "fleet-sidebar.sh"), "menu", session, wid],
                         env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)


def cells(char):
    return 2 if unicodedata.east_asian_width(char) in "WF" else 1


def cells_of(text):
    return sum(map(cells, text))


PRESS = curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED
# A right-click (issue #1950) is held the same way: its menu is the row's.
PRESS |= curses.BUTTON3_PRESSED | curses.BUTTON3_CLICKED
# A press acts on what the view read at most this long before it (issue #1756).
FRESH_SECS = 0.05


def held_press():
    """The mouse event behind a KEY_MOUSE as (y, buttons, when, x), or None."""
    try:
        _, x, y, _, buttons = curses.getmouse()
    except curses.error:
        return None
    return y, buttons, time.monotonic(), x


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
    the info column is open (⌃i, issue #1532) — `info_text`. The machine's `@`
    mark (issue #1780) is painted after it, in its own colour: `machine_tag`."""
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


def row_layout(marker, glyph, tree, name, badge, width, info="", node="", cfg="", reap=""):
    """A session row in `width` cells with its machine's @ mark (issue #1780):
    (text, tag) — `row_text` in what the mark leaves, the mark (`fit_tag`) to
    paint at the row's last cells. No mark: the row is exactly `row_text`.
    A stale configuration (`cfg` == "stale", issue #1783) puts 配置旧 in front of
    the mark, one space between — `cfg_part(tag)` is that word, painted yellow;
    `renew` (issue #1895) puts 待换新 there the same way. A reap policy (issue
    #1902) puts its word — 合并后回收 · 做完就回收 · 常驻 … — between the two."""
    right = row_right(badge, info)
    room = width - width_of(row_left(marker, glyph, tree, "")) - (width_of(right) + 1 if right else 0)
    tag = fit_tag(node, room)
    rtag = fit_reap_tag(reap, room - (width_of(tag) + 1 if tag else 0))
    if rtag:
        tag = rtag + (" " + tag if tag else "")
    ctag = fit_cfg_tag(cfg, room - (width_of(tag) + 1 if tag else 0))
    if ctag:
        tag = ctag + (" " + tag if tag else "")
    cut = width_of(tag) + 1 if tag else 0
    return row_text(marker, glyph, tree, name, badge, width - cut, info), tag


def row_need(row, info=False):
    """The cells `row` needs to show whole, plus the one the paint keeps free —
    its info column too while that is open."""
    wid, _state, glyph, name, tree, badge = row[:6]
    if wid == "hdr":
        return 0 if name.startswith("──") else width_of(name) + 1
    need = width_of(row_left(" ", glyph, tree, name)) + 1
    right = row_right(badge, info_text(row) if info else "")
    need += width_of(right) + 1 if right else 0
    need += tag_need(row[8] if len(row) > 8 else "")   # the @ mark (#1780)
    ctag = cfg_tag(row[12] if len(row) > 12 else "")    # 配置旧 (#1783)
    rtag = reap_tag(row[14] if len(row) > 14 else "")   # 合并后回收 … (#1902)
    return need + (width_of(ctag) + 1 if ctag else 0) + (width_of(rtag) + 1 if rtag else 0)


def alias_of(name):
    """The short name FLEET_NODE_ALIASES gives a machine (`macmini=m5`, any case,
    domain dropped), else the name itself — fleet-client-badge.sh's alias_of."""
    name = (name or "").split(".", 1)[0]
    for pair in os.environ.get("FLEET_NODE_ALIASES", "").split():
        key, _, val = pair.partition("=")
        if val and key.lower() == name.lower():
            return val
    return name


def here_names():
    """The names THIS computer goes by (issue #1780): its short hostname and its
    alias — the client's own machine, as the status bar's ⌂ names it (C3, #1779).
    FLEET_SIDEBAR_HOST stands in for the hostname (tests)."""
    host = os.environ.get("FLEET_SIDEBAR_HOST") or os.uname().nodename
    return {n.lower() for n in (host.split(".", 1)[0], alias_of(host)) if n}


HERE = here_names()
# The name column keeps at least this many cells beside the @ mark (issue #1780);
# narrower, the mark shrinks to `@` + its first letter.
NAME_MIN = 18


def machine_tag(node, narrow=False):
    """The `@` mark a session row ends in (issue #1780): the machine the session
    runs on — `@m4`; `@本机` when that is the computer this list runs on; `@m4!`
    once that machine is lost; `@m5~` when the row came over the shell's own
    connection while the hub is silent (#1488). `narrow` keeps `@` + the first
    letter (+ its mark). An empty field 9 — this machine's own row on a node's
    list — has none: a node's list marks the OTHER machines' rows only."""
    base = node.rstrip("!~")
    if not base:
        return ""
    name = tr("sidebar_here") if base.lower() in HERE else base
    return "@" + (name[:1] if narrow else name) + node[len(base):]


def tag_pair(node, raised=False):
    """The @ mark's colour pair (issue #1780): `@本机` magenta, every other
    machine's — a lost one's included, even this computer's — dim; on the
    raised row's ground when the row is raised."""
    base = node.rstrip("!~")
    if base and base.lower() in HERE and not node.endswith("!"):
        return PAIR_HERE + SEL_GLYPH if raised else PAIR_HERE
    return PAIR_DIM_SEL if raised else PAIR_DIM


def tag_need(node):
    """The cells the @ mark takes at a row's end: the tag plus its gap."""
    tag = machine_tag(node)
    return width_of(tag) + 1 if tag else 0


def fit_tag(node, room):
    """The @ mark for a row whose name and badge have `room` cells beside the mark
    (issue #1780): whole while the name keeps NAME_MIN cells, else `@` + the first
    letter; "" when even that leaves no name."""
    tag = machine_tag(node)
    if not tag:
        return ""
    if room - (width_of(tag) + 1) < NAME_MIN:
        tag = machine_tag(node, narrow=True)
    return tag if room - (width_of(tag) + 1) > 0 else ""


def cfg_tag(cfg, narrow=False):
    """The 配置旧 word a row whose configuration is stale carries left of its @
    mark (issue #1783) — `旧` when narrow; 待换新 (`换`) for a `renew` row, the
    same configuration on an older fleet version (issue #1895); "" for `ok` /
    unknown (empty)."""
    if cfg == "stale":
        return tr("sidebar_cfg_stale_narrow" if narrow else "sidebar_cfg_stale")
    if cfg == "renew":
        return tr("sidebar_cfg_renew_narrow" if narrow else "sidebar_cfg_renew")
    return ""


def fit_cfg_tag(cfg, room):
    """配置旧 for a row with `room` cells left beside the @ mark: whole while the
    name keeps NAME_MIN cells, else the narrow word; "" when even that leaves no
    name — the same rule as fit_tag, and the @ mark is fitted first."""
    tag = cfg_tag(cfg)
    if not tag:
        return ""
    if room - (width_of(tag) + 1) < NAME_MIN:
        tag = cfg_tag(cfg, narrow=True)
    return tag if room - (width_of(tag) + 1) > 0 else ""


def _compact(secs):
    for n, unit in ((86400, "d"), (3600, "h"), (60, "m")):
        if secs % n == 0 and not (unit == "d" and secs < 3 * 86400):
            return "%d%s" % (secs // n, unit)
    return "%ds" % secs


def reap_tag(policy, narrow=False):
    """The word a row's reap policy (issue #1902, @reap_policy) carries left of
    its @ mark — the new-session question's words; `narrow` the short one. ""
    for none (an old window: its kind decides, nothing is drawn) or a garbled one."""
    if not policy or fleet_reap_policy is None:
        return ""
    got = fleet_reap_policy.parse(policy)
    if got is None:
        return ""
    kind, val = got
    if kind == "at":
        lt = time.localtime(val)
        when = time.strftime("%H:%M" if time.localtime()[:3] == lt[:3] else "%m-%d %H:%M", lt)
        return tr("sidebar_reap_at_narrow", when) if narrow else tr("sidebar_reap_at", when)
    if kind == "merged" and val:
        return tr("sidebar_reap_merged_for_narrow" if narrow else "sidebar_reap_merged_for", _compact(val))
    if kind == "done" and val != fleet_reap_policy.DONE_DEFAULT:
        return tr("sidebar_reap_done_for_narrow" if narrow else "sidebar_reap_done_for", _compact(val))
    return tr(REAP_WORDS[kind][1 if narrow else 0])


REAP_WORDS = {"merged": ("sidebar_reap_merged", "sidebar_reap_merged_narrow"),
              "done": ("sidebar_reap_done", "sidebar_reap_done_narrow"),
              "loop-end": ("sidebar_reap_loop_end", "sidebar_reap_loop_end_narrow"),
              "keep": ("sidebar_reap_keep", "sidebar_reap_keep_narrow")}


def fit_reap_tag(policy, room):
    """reap_tag for a row with `room` cells left beside the @ mark — fit_cfg_tag's rule."""
    tag = reap_tag(policy)
    if not tag:
        return ""
    if room - (width_of(tag) + 1) < NAME_MIN:
        tag = reap_tag(policy, narrow=True)
    return tag if room - (width_of(tag) + 1) > 0 else ""


def reap_part(tag, cfg, policy):
    """(offset, word) of the reap word inside a row_layout tag, else (0, "")."""
    if not policy or not tag:
        return 0, ""
    at = 0
    c = cfg_part(tag, cfg)
    if c:
        at = width_of(c) + 1
    rest = tag[len(c) + 1:] if c else tag
    for word in (reap_tag(policy), reap_tag(policy, narrow=True)):
        if word and (rest == word or rest.startswith(word + " ")):
            return at, word
    return 0, ""


def cfg_part(tag, cfg):
    """The leading 配置旧 / 待换新 (or its narrow word) of a row_layout tag, else ""."""
    if cfg not in ("stale", "renew") or not tag:
        return ""
    for word in (cfg_tag(cfg), cfg_tag(cfg, narrow=True)):
        if tag == word or tag.startswith(word + " "):
            return word
    return ""


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


def say(session, text, secs=None):
    """What the list has to say, on the BAR of every client looking at it (issue
    #1950): a refusal's reason, 「正在 m5 上开…」 — tmux's display-message, so
    the whole window shows it and the list keeps every row. A literal: `#`
    would start a format."""
    if not text:
        return
    if secs is None:
        secs = env_float("FLEET_SIDEBAR_TOAST_SECS", TOAST_SECS)
    for client, _table, _pinned in clients(session):
        tmux("display-message", "-c", client, "-d", str(int(secs * 1000)), text.replace("#", "##"))


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


def next_attention(rows, selected):
    """The row ⌃k lands on (issue #1750): the next one waiting on you — `needs` /
    `failed`, FOLD_KEEP, which no fold ever hides — after the highlighted row in
    list order, wrapping round; "" when none is. In the born order those rows stay
    where they were born, so this, with the summary line above the list, is how
    they are reached."""
    loud = [row[0] for row in rows if row[0] != "hdr" and row[1] in FOLD_KEEP]
    if not loud:
        return ""
    keys = [row[0] for row in rows]
    at = keys.index(selected) if selected in keys else -1
    return next((k for k in loud if keys.index(k) > at), loud[0])


def is_attn_summary(row):
    """The 要你处理 summary line (issue #1750) — `hdr`, glyph `!`, text `! N …`.
    Not a cursor stop (key_of is bare `hdr`), but a tap on it is one ⌃k
    (issue #1771): onto the next row waiting on you, and over to it."""
    return bool(row) and row[0] == "hdr" and len(row) > 3 and row[2] == "!" and row[3].startswith("!")


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


def tap(hit, highlighted):
    """What a tap on list key `hit` does, given the highlighted key (issue #1032):
    the same two-tap grammar for both kinds of row. A session row: 1st tap
    `jump`s to it, 2nd opens its `menu` (#898). A repo heading with a spawn
    target: 1st tap `select`s it — highlight only, no window switch — and the 2nd
    opens the `new`-session popup pinned to its repo. A bare `hdr` (the `?`
    heading, the empty-state hint) or no row at all: None. A fleet with no
    headings never sees `select` or `new`, so it taps exactly as before."""
    if not hit or hit == "hdr" or hit == PLACING_KEY:
        return None
    if hit == PORTAL_KEY:
        return "jump"   # 「新任务」 (issue #1953): every tap opens the writing area
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
    return "" if key.startswith(("hdr", "landed:")) or key == PLACING_KEY else key


def folds(key):
    """The highlighted row as a ←/→ target: a session row (its subtree), or a repo
    heading with a spawn target — `hdr:<target>`, which dash-fold-toggle.sh reads
    as that repo's whole group (issue #1037). A bare `hdr` (the `?` heading, the
    empty-state hint) or no row at all: nothing to fold."""
    return key if key and key != "hdr" and key not in (PORTAL_KEY, PLACING_KEY) else ""


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


def on_caret(row, x):
    """Whether a tap at column `x` is on `row`'s fold caret (issue #1950: the
    mouse's ←/→): a session row's ▸ / ▾ — the last cell of its tree, laid out
    as `row_left` does with any marker — or a heading's first two cells, where
    its folded ▸ sits (`› ` when it is tapped)."""
    if not owns_fold(row):
        return False
    if row[0] == "hdr":
        return 0 <= x < 2
    at = width_of(row_left(" ", row[2], row[4], "")) - 2
    return at - 1 <= x <= at


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
    # a `wid:` row (another machine's) folds too (issue #1749): its bit is this
    # machine's own file, so on a client — where every row is one — ←/→ work
    if not key or key not in keys:
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


def current_of(env):
    """What a producer run was read against: the window AND the row it stands
    for — a proxy window keeps its id while it retargets (issue #1697)."""
    return env["FLEET_SIDEBAR_CURRENT"], env["FLEET_SIDEBAR_CURRENT_ROW"]


def start_rows(env):
    """Launch the row producer without waiting for it (issue #1033). Output goes
    to a file, not a pipe: a full pipe would stall a producer this loop only
    polls. `started` bounds a hung one."""
    out = tempfile.TemporaryFile("w+")
    proc = subprocess.Popen(["bash", str(BIN / "tmux-dashboard-rows.sh"), "--sidebar"],
                            env=dict(env), stdin=subprocess.DEVNULL, stdout=out,
                            stderr=subprocess.DEVNULL, text=True)
    proc.out, proc.started, proc.stale, proc.failure = out, time.monotonic(), False, ""
    proc.current, proc.view, proc.parse = current_of(env), "live", None
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
    proc.current, proc.view, proc.parse = current_of(env), "landed", landed_rows
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


# wid state glyph name tree badge depth detail node issue pr ctx cfg title reap
# (issues #1328, #1475, #1532, #1783 — cfg is `stale` / `renew` (#1895) / `ok`,
# absent when unknown; #1921 — title is the session's issue title, absent when
# none: a reader falls back to name; #1902 — reap is the @reap_policy, absent when
# none)
ROW_FIELDS = 15


def row_fields(line):
    """One producer line as its ROW_FIELDS fields: a heading's line stops at its
    tree field (5), a session row's carries the badge / depth / detail and, last,
    its machine — empty for a local row, `m4` for a row on another machine, `m4!`
    when that machine is lost (issue #1475), `m5~` when the row came over the
    shell's own connection to it while the hub is silent (issue #1488). The view
    ends the row in it as an `@` mark (`machine_tag`, issue #1780); `!` dims the
    row too, and the menu titles it."""
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
                 "PAL_GREEN": curses.COLOR_GREEN, "PAL_MAGENTA": curses.COLOR_MAGENTA,
                 "PAL_YELLOW": curses.COLOR_YELLOW}

# The sidebar's colour pairs (issue #1622): a row's TEXT is one colour (PAL_FG,
# or PAL_DIM for a dim one) and only its state glyph carries the state's colour
# — the red 「等你」 dot is no longer drowned in rows painted whole. The current
# row and the keyboard's row share one quiet PAL_SEL ground, told apart by ▶ / ›.
# {pair: (fg, bg)}, None = the terminal's default.
STATE_PAIR = {"working": 1, "needs": 2, "done": 3, "looping": 4, "exited": 18}   # 18: past PAIR_DIM_SEL (#1784)
STATE_COLOR = {"working": "PAL_CYAN", "needs": "PAL_RED", "done": "PAL_GREEN",
               "looping": "PAL_MAGENTA", "exited": "PAL_YELLOW"}
PAIR_SEL, PAIR_HERE, PAIR_TOAST, PAIR_FG, PAIR_DIM, SEL_GLYPH = 5, 6, 7, 8, 9, 10
# The @ mark (issue #1780): `@本机` magenta, any other machine's dim — on the
# raised row's ground too (PAIR_HERE + SEL_GLYPH, PAIR_DIM_SEL).
PAIR_DIM_SEL = 17
# 配置旧 (issue #1783): yellow, on the raised row's ground too (PAIR_STALE + SEL_GLYPH).
PAIR_STALE = 18
PAIRS = {PAIR_SEL: ("PAL_FG", "PAL_SEL"), PAIR_TOAST: ("PAL_RED", None),
         PAIR_FG: ("PAL_FG", None), PAIR_DIM: ("PAL_DIM", None),
         PAIR_HERE: ("PAL_MAGENTA", None), PAIR_HERE + SEL_GLYPH: ("PAL_MAGENTA", "PAL_SEL"),
         PAIR_DIM_SEL: ("PAL_DIM", "PAL_SEL"),
         PAIR_STALE: ("PAL_YELLOW", None), PAIR_STALE + SEL_GLYPH: ("PAL_YELLOW", "PAL_SEL")}
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
    machine's row `wid:<worker_id>`, so the ▶ and the cursor land on it. The
    stage's writing area (`@remote new`, issue #1953) stands for 「新任务」."""
    if STAGE and remote == PORTAL_KEY:
        return PORTAL_KEY
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


def crash_log(text):
    """One entry per ui() exception (issue #1950), beside the stall log."""
    path = Path(os.environ.get("FLEET_SIDEBAR_STALL_LOG") or BIN.parent / "logs" / "sidebar-stall.log")
    path = path.with_name("sidebar-crash.log")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as log:
            log.write("%s · %s\n%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                         os.environ.get("TMUX_PANE", ""), text.rstrip()))
    except OSError:
        pass


def ui(screen, session, worker, lock):
    pane = os.environ["TMUX_PANE"]
    window, remote = (fields(worker, US.join(("#{window_id}", "#{@remote}"))) + ["", ""])[:2]
    remote = stage_remote() or remote   # the shell's stage (issue #1759)
    current_row = shown_row(window, remote)
    # Two consumers, two values (issue #1697): the local window id for what joins
    # on a tmux window, the ROW key for the producer's keep-current fold rails —
    # in a proxy window onto another machine those differ (`@12` vs `wid:…`).
    env = dict(os.environ, FLEET_SESSION=session, FLEET_SIDEBAR_CURRENT=window,
               FLEET_SIDEBAR_CURRENT_ROW=current_row)
    try:
        curses.curs_set(0)   # the list takes no keys: no cursor to show (issue #1950)
    except curses.error:
        pass
    curses.use_default_colors()
    pal = palette_colors(palette(), curses.COLORS)
    for number, (fg, bg) in PAIRS.items():
        curses.init_pair(number, pal[fg] if fg else -1, pal[bg] if bg else -1)
    # Dim text is PAL_DIM; a terminal with no palette colour for it dims instead.
    pal_dim_default = pal["PAL_DIM"] == -1
    dim_attr = curses.color_pair(PAIR_DIM) | (curses.A_DIM if pal_dim_default else 0)
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
    curses.mouseinterval(0)
    screen.keypad(True)
    rows, selected, offset, refresh_at = [], current_row, 0, 0.0
    sized = None
    shown, follow_at = False, None
    # A press read before it is acted on (issue #1756): what this view knows of
    # tmux — the window in view, the row it stands for, whether it is shown —
    # is up to a refresh (1s) old, and a window switched from the session side
    # (prefix q, the bar, a spawn) left it stale: the first tap on the row just
    # left read as its SECOND (the menu), or fell in the hidden branch and was
    # dropped. `pressed` holds (y, buttons, when) until a read newer than it;
    # `read_at` is when the last one ran. Only a press pays it, never a tick.
    pressed, read_at = None, NEVER
    # A scratch session started from here (⌃s, issue #1532), polled below.
    spawning = None
    # A press on the already-highlighted row arms the menu; its RELEASE opens it
    # (issue #898). Opening on the press would lose the menu at once: tmux closes
    # a menu on a button release outside it, and that release is this tap's own.
    armed = None
    # The question open under the session (the Ask class, bin/fleet-ask.py — one
    # at a time): the menu's 改名 (issue #898 — the name goes to dash-rename.sh
    # as an argv word; no tmux or shell parser ever sees it), a new task's
    # title, 加仓库, a remote row's message or answer, 切换 sub, the #543 restore
    # question, a step of the shell's open-a-session flow. `jobs`: the question's
    # pane while it is open, then what its answer runs — polled below; a refusal
    # comes back on the bar (`say`).
    asking, jobs = None, []
    published = None  # the (window, candidates) last written to @sidebar_next
    switch_rows = None  # the switch-rows.tsv last written (issue #1903)
    bar_gen = None  # the stage top line's record last published (issue #1904)
    switch_visit(current_row)
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
    # The shell's open-a-session flow in flight (issue #1778): the plan whose
    # fleet-client-place.sh runs, then waits for its row — one at a time.
    placing = None

    def ask_now(nxt):
        """Open `nxt` on the line under the session (bin/fleet-ask.py): its pane
        is a job, and its answer comes back to `answered`. One at a time — a
        question asked while another is open is dropped, as a second popup was."""
        nonlocal asking
        if nxt is None or asking is not None:
            return
        asking = nxt
        job = start_job(["python3", str(BIN / "fleet-ask.py"), "open", "--below", worker,
                         "--wake", pane, "--spec-json", json.dumps(nxt.spec(), ensure_ascii=False)],
                        env, None)
        job.ask = nxt
        jobs.append(job)

    def place_step(nxt, said, go, plan):
        """One answered step of the shell's flow: the next question, a word on
        the bar, or — 「开在哪」 answered — the place itself, in the background."""
        nonlocal placing
        if said:
            say(session, said)
        if go and placing is None:
            placing = plan
            jobs.append(place_job(plan, rows, env))
            say(session, plan.get("note", ""))   # 「正在 m5 上开…」 (issue #1778)
        elif go:
            say(session, placing.get("note", ""))
        elif nxt is not None:
            ask_now(nxt)

    def act(verb, arg=""):
        """The list's own actions (issue #1532), each once a ⌃ key on it; since
        issue #1950 it takes no keys, so they are VERBS, parked in @sidebar_ask
        like a question (fleet-sidebar-menu.sh `ask`, the switcher's commands):
        `new [machine]` a new task · `restore` · `scratch` a scratch session now ·
        `view` the running list or the landed one · `reload` · `info` the issue ·
        PR · ctx% column · `needs` onto the next row waiting on you."""
        nonlocal follow_at, refresh_at, producer, view, live_rows, rows, landed_at
        nonlocal selected, wide, spawning
        follow_at = None
        if verb == "new":
            if SHELL:
                # new: repo, then the issue, then 「开在哪」 (issue #1778)
                place_step(*place_start("new", rows, selected or window), False, None)
            elif spawning is None:
                ask_now(ask_new(session, env, selection_repo(session, selected or window, env), node=arg))
        elif verb == "restore" and SHELL:
            # restore: repo, then the key, then 「开在哪」 (issue #1778) — the
            # landed list is the machines' ledger, not this computer's
            place_step(*place_start("restore", rows, selected or window), False, None)
        elif verb == "scratch":
            # the hub's ⌃s (issue #1532): a scratch session NOW, unnamed, its
            # repo the highlighted row's; it becomes current, a refusal is said
            anchor = window if not selected or selected.startswith("landed:") else selected
            if SHELL:
                place_step(*place_start("scratch", rows, anchor), False, None)
            elif spawning is None:
                spawning = spawn_scratch("", env, selection=anchor)
        elif verb in ("view", "restore"):
            # the running list or the landed one, in place — the hub's ⌃t (restore:
            # the landed list, issue #1620). Either side paints what it last had
            # at once; the run in flight for the other one is dropped.
            drop_rows(producer)
            producer = None
            if view == "live":
                view, live_rows, rows = "landed", rows, landed or [
                    ["hdr", "", "", tr("sidebar_landed_loading")] + [""] * (ROW_FIELDS - 4)]
                landed_at = NEVER
            elif verb == "view":
                view, rows, selected = "live", live_rows, current_row
        elif verb == "reload":
            landed_at = NEVER   # the shown list now, landed included
        elif verb == "info":
            # issue · PR · ctx%, right-aligned; the width follows at once, within
            # FLEET_SIDEBAR_WIDTH_MAX. Folded is the default, names come first.
            wide = not wide
        elif verb == "needs" and view == "live":
            nxt = next_attention(rows, selected)
            if nxt:
                selected = nxt
                if not jump(session, selected, pane, lock):
                    follow_at = time.monotonic() + LOCK_RETRY  # lock busy (#1536)
        refresh_at = 0

    def answered(ask, rc, out):
        """The answer from the question's line (bin/fleet-ask.py's JSON): run
        what it answers, through the path its kind always had. Cancelled (Esc,
        an empty one-key answer, the pane closed) does nothing."""
        nonlocal asking, selected, follow_at
        asking = None
        if rc == 2:
            # the line could not open: why, on the bar
            say(session, "✗ " + (last_line(out) or tr("sidebar_spawn_failed")))
            return
        try:
            answer = json.loads(out.strip().splitlines()[-1]) if rc == 0 and out.strip() else {}
        except ValueError:
            answer = {}
        if not answer:
            return
        if ask.keys:
            press = answer.get("key", "")
            if press and press in ask.keys and ask.kind == "place-held":
                # 「已在别处跑」→ y: over to the row that runs it (issue #1778)
                hit = held_row(rows, ask.plan, ask.node)
                if hit:
                    selected, follow_at = hit, None
                    if not jump(session, selected, pane, lock):
                        follow_at = time.monotonic() + LOCK_RETRY  # lock busy (#1536)
            elif press and press in ask.keys:
                job = submit(ask, press, session, env)
                if job is not None:
                    jobs.append(job)
            return
        if ask.menu:
            place_step(*place_answer(ask, answer.get("choice", "")), ask.plan)
            return
        text = answer.get("text", "").strip()
        if ask.kind == "new" and answer.get("choice"):
            ask.repo = answer["choice"]   # the repo Tab stepped to
        if ask.kind == "rename":
            # An empty rename still goes to dash-rename.sh, which decides (an
            # empty name cancels, as in the hub).
            run(["bash", str(BIN / "dash-rename.sh"), "--wid", ask.arg, text], env=env)
        elif ask.kind.startswith("place-"):
            place_step(*place_answer(ask, text), ask.plan)
        else:
            job = submit(ask, text, session, env)
            if job is not None:
                jobs.append(job)

    def compose_take(verbs):
        """The writing area's ↵ (issue #1953): `compose` on the queue means its
        payload waits in compose-send.json. Taken (renamed, so the next ↵ never
        overwrites it), its repo resolved — the payload's, else the repo of the
        row that was in view when the writing area opened (「自动」), else the only
        one, else the place-repo question — and placed in the background, its
        「开工中…」 row painted at once. The other verbs go on as they came."""
        rest = [v for v in verbs if v != "compose"]
        if len(rest) == len(verbs):
            return verbs
        if placing is not None:
            say(session, placing.get("note", ""))
            return rest
        src = switch_lib().state_dir() / "compose-send.json"
        dst = src.with_name("compose-send.%d.json" % time.time_ns())
        try:
            os.replace(str(src), str(dst))
            data = json.loads(dst.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return rest
        base = [row for row in rows if row[0] not in (PORTAL_KEY, PLACING_KEY)]
        plan = {"verb": "compose", "what": "new" if data.get("issue", True) else "scratch",
                "title": data.get("title", ""), "name": "", "payload": str(dst), "node": "auto",
                "label": "", "repo": data.get("repo") or repo_of(base, data.get("prev") or "")}
        if data.get("repo_mode") in ("none", "multi"):
            # 「不关联仓库」 / 「多个仓库」 (issue #1956): no repo to resolve — a
            # session of no repo, said to --send as --no-repo / --multi.
            plan.update(what="scratch", repo="", repo_mode=data["repo_mode"])
            place_step(None, "", True, plan)
            return rest
        if not plan["repo"]:
            repos = shell_repos(base) or hub_repos() or []
            if len(repos) == 1:
                plan["repo"] = repos[0]
            elif not repos:
                say(session, tr("sidebar_place_norepo"))
                return rest
            else:
                ask_now(Ask("place-repo", tr("sidebar_place_repo"), hint=tr("sidebar_place_keys"), plan=plan,
                            menu=[(r, r.rsplit("/", 1)[-1], r.split("/", 1)[0], False) for r in repos]))
                return rest
        place_step(None, "", True, plan)
        return rest

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
            elif current != (window, current_row):
                # Read against a window this view has since left: its fold
                # exemptions are for the wrong row. Drop it, read again now.
                refresh_at = 0
            elif fresh is not None and not fresh and rows and not empty_held:
                # An empty frame never blanks a painted list on its own (issue
                # #1536): a producer that caught tmux mid-change can print
                # nothing. Keep the rows; the next run, at once, decides.
                empty_held, failure, refresh_at = True, "empty frame", 0
            elif fresh is not None:
                # The 要你处理 summary row (issue #1750) is not drawn any more
                # (issue #1950): the list is sessions only, and a row waiting on
                # you is its own red `!`. The producer still writes it (EPIC
                # #1949 convention 3: it goes there after #1940).
                fresh = [row for row in fresh if not is_attn_summary(row)]
                rows, loaded, frame_at, failure, empty_held, stalled = fresh, True, now, "", False, False
                remember_folds(rows, fold_cache)
                if SWITCH_ON:
                    # what ⌘P lists (issue #1903) — written only on change
                    text = switch_lib().rows_text(rows)
                    if text != switch_rows and switch_lib().write_atomic(switch_lib().rows_path(), text):
                        switch_rows = text
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
            if spawning.returncode != 0:
                # Why it could not open, on the bar (issue #1950).
                reason = error[-1] if error else tr("sidebar_spawn_failed")
                say(session, "✗ " + reason.split(": ", 1)[-1])
            spawning = None
            refresh_at = 0
        for job in [j for j in jobs if j.poll() is not None]:
            jobs.remove(job)
            job.out.seek(0)
            out = job.out.read()
            job.out.close()
            if getattr(job, "ask", None) is not None:
                answered(job.ask, job.returncode, out)
            else:
                said, nxt = job.done(job.returncode, out)
                if said:
                    say(session, said)
                if spawning is None:
                    ask_now(nxt)
            refresh_at = 0
        if placing is not None and placing.get("state") == "end":
            placing = None
        elif placing is not None and placing.get("state") == "await" and view == "live":
            # The hub said done: the new session is selected and switched to as
            # soon as the list carries it (issue #1778) — read every second meanwhile.
            if not placing.get("said"):
                placing["said"] = True
                say(session, placing.get("note", ""))   # 「正在 m5 上开…」
            hit = place_found(rows, placing) if loaded else ""
            if hit:
                selected, follow_at = hit, None
                say(session, tr("sidebar_place_opened_fmt", placing["machine"]))
                placing = None
                if not jump(session, selected, pane, lock):
                    follow_at = time.monotonic() + LOCK_RETRY  # lock busy (#1536)
                refresh_at = 0
            elif now >= placing["until"]:
                say(session, tr("sidebar_place_notyet_fmt", placing["machine"]))
                placing = None
            else:
                refresh_at = min(refresh_at, now + 1)
        if follow_at is not None and now >= follow_at:
            # A switch the view lock held back (issue #1536): try it again.
            follow_at = None
            if acts(selected) and selected != current_row:
                if jump(session, selected, pane, lock):
                    refresh_at = 0
                    continue
                # The lock is busy (issue #1536): keep painting the highlight,
                # try the switch again shortly.
                follow_at = time.monotonic() + LOCK_RETRY
        if now >= refresh_at:
            read_at = now
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
                                             "#{@popup_pid}", "#{@fleet_single}",
                                             "#{@sidebar_ask}")))
                if len(info) != 11:
                    return
                if info[9] == "1":
                    # The one-pane layout (issue #1904): zoomed away behind the
                    # session on purpose — read rows and take keys as if shown.
                    info[1] = "0"
                # The pane (and curses grid) survives navigation. Follow its new
                # worker before testing liveness or building current-row exemptions.
                # A proxy window onto another machine is RETARGETED in place by
                # fleet-remote-view.sh open — same window id, a new `@remote` —
                # so the row it stands for is the test, not the id (issue #1697).
                row = shown_row(info[4], stage_remote() or info[7])
                if info[4] != window or row != current_row:
                    window, current_row, selected = info[4], row, row
                    env["FLEET_SIDEBAR_CURRENT"] = window
                    env["FLEET_SIDEBAR_CURRENT_ROW"] = current_row
                    switch_visit(current_row)
                worker = info[5] or worker
                leave_navigation(session)
                # kill-pane does not emit pane-exited on every supported tmux.
                # Never let this view keep an otherwise closed worker window alive.
                if fields(worker, "#{pane_dead}") != ["0"]:
                    return
                shown = visible(info[:4] + info[8:9], time.time())
                if shown and info[10]:
                    # A question or verb parked while this view was hidden (its F12
                    # landed mid-move): take it now, as its F12 would have.
                    curses.ungetch(curses.KEY_F12)
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
        if STAGE and loaded and view == "live":
            bar_gen = publish_bar(rows, current_row, bar_gen)
        if not shown:
            follow_at = None  # a hidden view never switches windows
            shown_at = None   # nor does its frame age
            if pressed is not None and read_at >= pressed[2]:
                pressed = None  # read again since, and still hidden: not ours
            screen.timeout(max(1, min(1000, int((refresh_at - time.monotonic()) * 1000))))
            key = screen.getch()
            if key == curses.KEY_F12:
                # ⌘P's pick lands while its popup still covers this view, and ⌘↓
                # may come with the session zoomed (issue #1903): a hidden view
                # still switches for the queue — never for a stray key.
                todo = compose_take(take_switch(pane))
                if todo and spawning is None:
                    base = rows if view == "live" else live_rows
                    nxt = switch_target(todo, base, current_row, sessions(base), session)
                    if nxt and nxt != current_row:
                        if view != "live":
                            view, rows = "live", live_rows
                        selected, refresh_at = nxt, 0
                        jump(session, nxt, pane, lock)
                continue
            if key == curses.KEY_MOUSE and pressed is None:
                # tmux sends a press only to a pane on screen: this view was
                # read as hidden before it moved into view. Read now, then act.
                event = held_press()
                if event is not None and event[1] & PRESS:
                    pressed, refresh_at = event, 0
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
        # id field. One with a spawn target is a tap stop since #997 — a tap
        # highlights it, a second one opens a new session THERE — but a jump and
        # the menu ignore it (`acts`); a tap on its caret folds and unfolds its
        # whole repo group (`folds`, issue #1037). `where` is the selection's
        # place in the PAINTED list, which the scroll offset is measured in.
        if view == "live":
            rows = with_portal(rows, placing)   # 「新任务」 on top (issue #1953)
        ids = selectable(rows)
        # Rows still in flight for a window just jumped to may not hold it yet (a
        # folded child shows only as the current row): keep the selection until
        # they land, rather than reset it to the top for one frame.
        if selected not in ids and producer is None:
            selected = current_row if current_row in ids else (ids[0] if ids else "")
        index = ids.index(selected) if selected in ids else 0
        where = next((i for i, row in enumerate(rows) if key_of(row) == selected), 0)
        # The 「刷新中…」 row (issue #1536): the list waits on a frame that has not
        # come — the first, or one past STALE_SECS. The rows it has stay painted
        # one row lower; the top row says what the view is waiting for. Nothing
        # else is ever a row here (issue #1950): no summary, no `?` row, no
        # input line — the whole height is the list's.
        waiting = 1 if height >= 4 and (not loaded or age > STALE_SECS) else 0
        page = max(1, height - waiting)
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
                if key_of((wid, state)) == selected:
                    # a tapped heading (issue #1032): its second tap opens a new
                    # session in that repo
                    put(y, "› " + label, curses.color_pair(PAIR_SEL) | curses.A_BOLD, fill=True)
                else:
                    put(y, label, dim_attr | curses.A_BOLD)
                continue
            # The text is one colour; the glyph alone says the state (issue #1622).
            raised = wid == current_row or wid == selected
            attr = curses.color_pair(PAIR_SEL if raised else PAIR_FG)
            lost = node.endswith("!") and not raised
            if lost:
                attr = dim_attr  # a lost machine's row (issue #1475)
            if wid == PORTAL_KEY:
                attr |= curses.A_BOLD   # 「新任务」 (issue #1953)
            pair = STATE_PAIR.get(state)
            glyph_attr = curses.color_pair(pair + SEL_GLYPH if raised else pair) if pair else attr
            if lost:
                glyph_attr |= curses.A_DIM
            marker = "▶" if wid == current_row else "›" if wid == selected else " "
            # `marker glyph tree label` (issue #836): the hierarchy glyph is its own
            # fixed cell between the state glyph and the name, so at 30 columns every
            # name starts in the same place instead of a child's text sitting two
            # columns right of its parent's.
            # The machine the session runs on (issue #1780): `@m4` grey at the
            # row's end, `@本机` magenta for this computer's own, `@m4!` dim on a
            # lost machine's (dimmed) row, `@m5~` heard over the shell's own
            # connection (#1488). Its cells come off the name, which keeps
            # NAME_MIN of them; narrower, the mark is `@` + its first letter. The
            # badge keeps its place left of it.
            w = max(0, width - 1)
            # A stale configuration (issue #1783): a yellow 配置旧 left of the mark.
            cfg = row[12] if len(row) > 12 else ""
            reap = row[14] if len(row) > 14 else ""   # the reap policy (#1902)
            text, tag = row_layout(marker, glyph, tree, label, badge, w,
                                   info_text(row) if wide else "", node, cfg, reap)
            put(y, text, attr, fill=raised)
            # The state glyph, painted over its own cell in the state's colour —
            # where row_left put it, and only when the row is wide enough for it.
            at = width_of(marker) + 1
            if glyph.strip() and at + width_of(glyph) <= w and 0 <= y < height:
                try:
                    screen.addstr(y, at, glyph, glyph_attr)
                except curses.error:
                    pass
            if tag:
                tpair = tag_pair(node, raised)
                tag_attr = dim_attr if tpair == PAIR_DIM else curses.color_pair(tpair)
                if tpair == PAIR_DIM_SEL and pal_dim_default:
                    tag_attr |= curses.A_DIM
                try:
                    screen.addstr(y, w - width_of(tag), tag, tag_attr)
                    ctag = cfg_part(tag, cfg)
                    if ctag:
                        screen.addstr(y, w - width_of(tag), ctag, curses.color_pair(
                            PAIR_STALE + SEL_GLYPH if raised else PAIR_STALE) | curses.A_BOLD)
                    # 常驻 (issue #1902) in the 本机 magenta: the one policy that
                    # says «this one stays»; every other word keeps the tag's dim.
                    roff, rword = reap_part(tag, cfg, reap)
                    if rword and reap == "keep":
                        screen.addstr(y, w - width_of(tag) + roff, rword, curses.color_pair(
                            PAIR_HERE + SEL_GLYPH if raised else PAIR_HERE))
                except curses.error:
                    pass
        screen.refresh()
        # Wake for whichever comes first: the next repaint, a pending follow or
        # a finished spawn.
        wait = refresh_at - time.monotonic()
        if follow_at is not None:
            wait = min(wait, follow_at - time.monotonic())
        if spawning is not None or any(getattr(j, "ask", None) is None for j in jobs):
            wait = min(wait, 0.2)   # an open question wakes us itself (F11)
        if producer is not None or folding is not None:
            wait = min(wait, PRODUCER_POLL)
        mouse = None
        if pressed is not None and read_at >= pressed[2]:
            key, mouse, pressed = curses.KEY_MOUSE, pressed, None
        else:
            screen.timeout(max(1, min(1000, int(wait * 1000))))
            key = screen.getch()
        if key != -1 and spawning is not None and spawning.poll() is not None and mouse is not None:
            pressed = mouse
            continue
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
            # F11, issue #1530): read the rows now, not at the next tick. A
            # question's line sends it too, its answer printed, as it exits
            # (bin/fleet-ask.py --wake): reap it now, the loop's top runs it.
            for job in jobs:
                if getattr(job, "ask", None) is not None:
                    try:
                        job.wait(timeout=0.5)
                    except subprocess.TimeoutExpired:
                        pass
            refresh_at = 0
            continue
        if key == curses.KEY_F10:
            # prefix k (issue #1771, conf/tmux-shell.conf): the 要你处理 jump from
            # wherever the keyboard is — onto the next row waiting on you and
            # over to it.
            if view != "live":
                view, rows, selected = "live", live_rows, current_row
            nxt = next_attention(rows, selected)
            if nxt:
                selected, follow_at, refresh_at = nxt, None, 0
                if not jump(session, selected, pane, lock):
                    follow_at = time.monotonic() + LOCK_RETRY  # lock busy (#1536)
            continue
        if key == curses.KEY_F12:
            # ⌘↓ ⌘↑ ⌘[ ⌘] ⌘P (issue #1903): the verbs queued on @sidebar_do since
            # the last wake, read and cleared in one tmux call — every press a step.
            todo = compose_take(take_switch(pane))
            if todo and spawning is None:
                if view != "live":
                    view, rows, selected = "live", live_rows, current_row
                nxt = switch_target(todo, rows, current_row, sessions(rows), session)
                if nxt and nxt != current_row:
                    selected, follow_at, refresh_at = nxt, None, 0
                    if not jump(session, nxt, pane, lock):
                        follow_at = time.monotonic() + LOCK_RETRY  # lock busy (#1536)
            # A menu item that asks (issue #1620): it parked `<kind> <arg>…` in
            # @sidebar_ask on this pane (a rename: the row's @id in
            # @sidebar_rename, as since #898) and sent F12 to wake us. The
            # question opens under the session (issue #1950, `ask_now`).
            if spawning is not None:
                # One spawn at a time: what is parked stays parked, and the
                # tick after the spawn ends takes it (the re-arm above).
                continue
            # Read and cleared in ONE tmux call (as take_switch): a verb parked
            # between a read and its clear would be cleared unread.
            got = run(["tmux", "show-options", "-pqv", "-t", pane, "@sidebar_ask", ";",
                       "display-message", "-p", "-t", pane, "@@", ";",
                       "show-options", "-pqv", "-t", pane, "@sidebar_rename", ";",
                       "set-option", "-up", "-t", pane, "@sidebar_ask", ";",
                       "set-option", "-up", "-t", pane, "@sidebar_rename"]).stdout
            # (a printable separator: tmux 3.4 vis-escapes a control one)
            parked, _, wid = got.partition("@@\n")
            parked, wid = parked.strip(), wid.strip()
            if wid and not parked:
                parked = "rename " + wid
            kind, _, rest = parked.strip().partition(" ")
            arg, _, extra = rest.partition(" ")
            if not kind:
                continue
            follow_at, nxt = None, None
            if kind == "rename" and arg.startswith("@"):
                nxt = Ask("rename", tr("sidebar_rename"), arg=arg,
                          text=fields(arg, "#{window_name}")[0])
            elif kind in ("new", "restore", "scratch", "view", "reload", "info", "needs"):
                act(kind, arg)
            elif kind == "landed" and not SHELL:
                act("view")   # the menu's 恢复已落地 (issue #1532)
            elif kind == "repo" and not SHELL:
                nxt = Ask("repo", tr("sidebar_ask_repo"), hint=tr("sidebar_ask_repo_hint"))
            elif kind in ("message", "answer") and arg.startswith("wid:"):
                hint = tr("sidebar_ask_to_fmt", arg.rsplit("/", 1)[-1])
                if kind == "answer":
                    hint = tr("sidebar_ask_perm_hint" if extra == "perm" else "sidebar_ask_answer_hint")
                nxt = Ask(kind, tr("sidebar_ask_answer" if kind == "answer" else "sidebar_ask_message"),
                          arg=arg, hint=hint)
            elif kind == "sub" and arg.startswith("@"):
                # the accounts first: the question opens once they are read
                say(session, tr("sidebar_ask_sub_loading"), 3)
                jobs.append(start_job(["bash", str(BIN / "fleet-manual-sub.sh"), "list", session],
                                      env, sub_choices(Ask("sub", tr("sidebar_ask_sub"), arg=arg))))
            elif kind == "jump" and acts(arg):
                # 回答 on a row of this machine: its own question, in its own
                # pane — the window the answer popup only copied.
                selected = arg
                if not jump(session, arg, pane, lock):
                    follow_at = time.monotonic() + LOCK_RETRY
            ask_now(nxt)
            refresh_at = 0
            continue
        if key == curses.KEY_MOUSE:
            if mouse is None:
                mouse = held_press()
                if mouse is None:
                    continue
                if mouse[1] & PRESS and mouse[2] - read_at > FRESH_SECS:
                    pressed, refresh_at = mouse, 0  # read tmux first (above)
                    continue
            y, buttons, _when, x = mouse
            ry = y - waiting  # below the 「刷新中…」 row when it shows (issue #1536)
            hit_row = rows[offset + ry] if 0 <= ry < page and offset + ry < len(rows) else None
            hit = key_of(hit_row) if hit_row is not None else None
            # `selected`, not the painted cue: a fast double tap lands its second
            # press before the next refresh repaints the first one's switch.
            action = tap(hit, selected)
            if hit and hit.startswith("landed:"):
                # A landed row (issue #1532): a tap highlights it, a tap on the
                # highlighted one restores it — the session row's two-tap grammar.
                action = "restore" if action == "menu" else "select"
            if buttons & (curses.BUTTON3_PRESSED | curses.BUTTON3_CLICKED):
                # A right-click (a long press on an iPad) on a row (issue #1950):
                # its menu at once, the row in view or not — a heading's is a new
                # session in that repo, as its second tap.
                follow_at, armed = None, None
                if hit and acts(hit) and view == "live":
                    open_menu(session, hit, env)
                elif hit and hit.startswith("hdr:") and hit != PIN_HEADING:
                    selected = hit
                    nxt = open_tap(session, "new", hit, env)
                    if nxt == "refused":
                        place_step(*place_start("new", rows, hit, pin=True), False, None)
                    elif spawning is None:
                        ask_now(nxt)
                refresh_at = 0
            elif buttons & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED):
                refresh_at = 0
                armed = None
                if hit_row is not None and view == "live" and folds(hit) and on_caret(hit_row, x):
                    # A tap on a row's caret (▸ / ▾, or a heading's first cells)
                    # folds or opens its block (issue #1950: ←/→ went with the
                    # keyboard). Painted at once (fold_now), written in the
                    # background; the producer waits for the write, so its frame
                    # is never the old one.
                    follow_at = None
                    verb = "collapse" if fold_open(hit_row) else "expand"
                    rows, holder = fold_now(rows, hit, verb, window, fold_cache)
                    if folding is not None:
                        try:
                            folding.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            folding.kill()
                    folding = subprocess.Popen(["bash", str(BIN / "dash-fold-toggle.sh"), verb, hit],
                                               env=dict(env, DASH_FOLD_PLAIN="1"), stdin=subprocess.DEVNULL,
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                elif action in ("menu", "new"):
                    # The second tap on a row (the first switched to it), or a tap
                    # on the row already in view: its action menu (issue #898). On
                    # a selected heading it is a new session in that repo (issue
                    # #1032). Both open on the release: tmux closes a menu on a
                    # release outside it, and this tap's own would be one.
                    follow_at = None
                    if buttons & curses.BUTTON1_CLICKED:
                        nxt = open_tap(session, action, hit, env)
                        if nxt == "refused":
                            # a heading's second tap: new, its repo pinned (#1778)
                            place_step(*place_start("new", rows, hit, pin=True), False, None)
                        elif spawning is None:
                            ask_now(nxt)
                    else:
                        armed = hit
                elif action == "restore":
                    follow_at = None
                    if buttons & curses.BUTTON1_CLICKED:
                        job = restore_landed(session, hit, env)
                        if job is not None:
                            jobs.append(job)
                        view, rows, selected = "live", live_rows, current_row
                    else:
                        armed = hit
                elif action == "select":
                    # A repo heading (issue #1032): highlight it, switch nothing.
                    # A second tap opens a new session there; a tap on a session
                    # row clears it.
                    follow_at = None
                    selected = hit
                elif action == "jump":
                    selected = hit
                    if not jump(session, selected, pane, lock):
                        follow_at = time.monotonic() + LOCK_RETRY  # lock busy (#1536)
                    refresh_at = 0  # re-read where it landed: ▶ follows (#1697)
            elif buttons & curses.BUTTON1_RELEASED:
                if armed is not None and hit == armed and armed.startswith("landed:"):
                    job = restore_landed(session, armed, env)
                    if job is not None:
                        jobs.append(job)
                    view, rows, selected = "live", live_rows, current_row
                    refresh_at = 0
                elif armed is not None and hit == armed:
                    nxt = open_tap(session, "new" if armed.startswith("hdr:") else "menu", armed, env)
                    if nxt == "refused":
                        place_step(*place_start("new", rows, armed, pin=True), False, None)
                    elif spawning is None:
                        ask_now(nxt)
                    refresh_at = 0
                armed = None
            elif buttons & curses.BUTTON4_PRESSED and ids:
                selected = ids[max(0, index - 3)]
            elif buttons & getattr(curses, "BUTTON5_PRESSED", 0) and ids:
                selected = ids[min(len(ids) - 1, index + 3)]


def steady():
    """The list leaves only when the fleet takes it away (issue #1785): kill-pane
    and respawn-pane -k end it with SIGHUP. ⌃c, ⌃\\ and ⌃z reach this pane as
    bytes (the fleet-sidebar table sends every key here) and curses' cbreak keeps
    the tty's signals on, so each one ended or froze the list; a stray TERM is
    no rebuild either. A handler, not SIG_IGN: an ignored signal is inherited
    across exec, and the jobs this list starts must stay killable."""
    for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGTSTP, signal.SIGTERM):
        signal.signal(sig, lambda *_: None)


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
        steady()
        restarts = []
        while True:
            try:
                curses.wrapper(ui, sys.argv[2], sys.argv[3], sys.argv[4])
                return
            except Exception:
                # Paint again rather than leave the pane (issue #1785): a list
                # that died on one bad frame took the keyboard's target with it.
                # A pane that is gone, or one failing over and over, exits — the
                # hooks' sync draws a fresh one. Each one is logged beside the
                # stall log (issue #1950): a list that restarts says why.
                crash_log(traceback.format_exc())
                now = time.monotonic()
                restarts = [t for t in restarts if now - t < 60] + [now]
                pane = os.environ.get("TMUX_PANE", "")
                if len(restarts) > 5 or not pane or run(
                        ["tmux", "display-message", "-p", "-t", pane, "#{pane_id}"]).returncode != 0:
                    raise
                time.sleep(0.5)
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
