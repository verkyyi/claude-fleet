#!/usr/bin/env python3
"""Prefill a new scratch's input without submitting it; preserve existing input.

Args: socket-label pane-id name-file warm(0|1) — warm is always 0 since the
warm pool left (T495). The caller owns the window; this helper owns and removes
the temporary name file and tmux paste buffer. Cold readiness: a painted prompt
alone is too early (the TUI still drops what is typed while it mounts its input),
so wait for a stable screen AND ten seconds since the empty prompt appeared.
An agent that says so itself (OSC 7501 idle, @agent_status — issue #2536) needs
no guess: its own word stands for both who owns the pane and that its input is
up, so the draft goes in once the empty prompt holds for one poll.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


SGR = re.compile(r"\x1b\[([0-9;:]*)m")
PROMPT = re.compile(r"^([ │]*[❯›])(?:[ \u00a0]|$)")
POLL = 0.5
SETTLE = 10
STABLE = 4
TIMEOUT = 120
META = ("#{pane_dead}\t#{pane_current_command}\t#{cursor_x}\t#{cursor_y}"
        "\t#{@claude_state}\t#{pane_in_mode}\t#{@agent_status}")
RECHECK = 1.5  # after a paste: an input still empty swallowed it — paste once more


def agent_says_idle(raw, state):
    """The agent's own OSC 7501 report (the relay's @agent_status, cleared by the
    wrapper before every launch): idle/done from a known agent app, and the
    session not exited — a shell left behind by an exited agent never counts."""
    if state == "exited" or not raw:
        return False
    try:
        report = json.loads(raw)
    except ValueError:
        return False
    return (isinstance(report, dict) and report.get("state") in ("idle", "done")
            and report.get("app") in ("claude-code", "codex"))


def has_input(line, start):
    """Ignore dim placeholder text, including combined/extended-color SGRs."""
    dim = False
    pos = 0
    column = 0
    for match in list(SGR.finditer(line)) + [None]:
        end = match.start() if match else len(line)
        for char in line[pos:end]:
            if column >= start and not dim and not char.isspace() and char != "│":
                return True
            column += 1
        if match is None:
            break
        codes = match.group(1).split(";") if match.group(1) else ["0"]
        i = 0
        while i < len(codes):
            code = codes[i]
            if code in ("38", "48", "58") and i + 1 < len(codes):
                i += 5 if codes[i + 1] == "2" else 3
                continue
            if code in ("0", "22"):
                dim = False
            elif code == "2":
                dim = True
            i += 1
        pos = match.end()
    return False


def input_status(screen, cx, cy):
    """Return empty, busy, or waiting; a missing/unrecognized prompt is not ready."""
    lines = screen.splitlines()
    for y in range(len(lines) - 1, -1, -1):
        plain = SGR.sub("", lines[y])
        prompt = PROMPT.match(plain)
        if prompt:
            # capture-pane strips trailing ASCII spaces from a blank input.
            start = len(prompt.group(1)) + 1
            if has_input(lines[y], start):
                # NO_COLOR removes Claude's dim style as well as its colors.
                # Recognize only the standard startup placeholders, and only
                # with no SGR and the cursor parked at the input's beginning.
                # Unknown text is treated as an existing draft.
                placeholder = plain[start:].strip()
                glyph = prompt.group(1)[-1]
                ghost = ((glyph == "❯" and re.fullmatch(r'Try "[^"\n]+"', placeholder))
                         or (glyph == "›" and placeholder == "Ask Codex to do anything"))
                if SGR.search(lines[y]) or not ghost:
                    return "busy"
            if cy != y or cx < start:
                return "waiting"
            if cx != start:
                return "busy"
            return "empty"
    return "waiting"


def codex_owns_input(tm, pane):
    """A shell-named pane is safe only while its recorded launcher owns Codex."""
    identity = tm("display-message", "-p", "-t", pane,
                  "#{@cc_agent}|#{@cc_launcher_pid}|#{pane_pid}").decode().strip().split("|")
    if len(identity) != 3 or identity[0] != "codex" or not all(value.isdigit() for value in identity[1:]):
        return False
    launcher, pane_pid = map(int, identity[1:])
    processes = {}
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,comm="], timeout=3).decode()
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            processes[int(fields[0])] = (int(fields[1]), Path(fields[2]).name)

    def descendants(root):
        pending, seen = [root], set()
        while pending:
            current = pending.pop()
            if current in seen:
                continue
            seen.add(current)
            pending.extend(pid for pid, (parent, _) in processes.items() if parent == current and pid != current)
        return seen

    if launcher not in processes or launcher not in descendants(pane_pid):
        return False
    for pid in descendants(launcher):
        name = processes.get(pid, (0, ""))[1]
        if name != "codex" and not name.startswith("codex-"):
            continue
        arguments = subprocess.check_output(["ps", "-p", str(pid), "-o", "args="], timeout=3).decode()
        if arguments.strip() and not re.search(r"(?:^|\s)app-server(?:\s|$)", arguments):
            return True
    return False


def paste(tm, pane, text, record):
    buf = "scratch-draft-" + str(os.getpid())
    try:
        tm("set-buffer", "-b", buf, "--", text)
        tm("paste-buffer", "-p", "-d", "-b", buf, "-t", pane)
        record("delivered unsent")
    except (OSError, subprocess.SubprocessError):
        record("paste failed; not retried")
        raise
    finally:
        try:
            tm("delete-buffer", "-b", buf)
        except subprocess.CalledProcessError:
            pass


def prefill(socket, pane, draft, warm):
    prefix = ["tmux", "-L", socket]

    def tm(*args):
        return subprocess.run(prefix + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=5, check=True).stdout

    def record(outcome):
        try:
            tm("set-option", "-w", "-t", pane, "@scratch_prefill_result", outcome)
        except (OSError, subprocess.SubprocessError):
            pass

    def note(reason):
        record(reason)
        # one notice (T675, bin/fleet_notice.py): recorded, held, never a 0.75 s flash
        subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "fleet_notice.py"),
                        "notify", "warn", "scratch: name not prefilled — " + reason, "--sock", socket,
                        "--source", "scratch-prefill"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10)

    # A name is one input line. Drop terminal control bytes (especially CR/LF,
    # Escape and DEL) before pasting, so even unusual CLI names cannot submit or
    # end bracketed paste. Keep Unicode, spaces, #, quotes and the entire name.
    text = "".join(c for c in draft if ord(c) >= 32 and not 127 <= ord(c) < 160)
    if not text.strip():
        return
    record("waiting for input")
    deadline = time.monotonic() + TIMEOUT
    appeared = unchanged = None
    previous = None
    while time.monotonic() < deadline:
        try:
            meta = tm("display-message", "-p", "-t", pane, META).decode().strip("\n").split("\t")
        except (OSError, subprocess.SubprocessError):
            appeared = unchanged = previous = None
            time.sleep(POLL)
            continue
        if len(meta) != 7 or meta[0] != "0":
            record("pane is unavailable")
            return
        command, cx, cy, state, mode, status_raw = meta[1:]
        native = agent_says_idle(status_raw, state)
        if state in ("working", "busy", "needs", "looping") or mode != "0":
            note("session is already in use")
            return
        # Native Claude releases may report their version as the process name;
        # npm installs run as node. In particular, never paste into a shell left
        # behind by a failed/exited agent, even if its old prompt is still visible.
        try:
            owned = (native or command in ("claude", "codex", "node")
                     or re.fullmatch(r"\d+\.\d+\.\d+[\w.-]*", command)
                     or codex_owns_input(tm, pane))
            screen = (tm("capture-pane", "-p", "-e", "-t", pane).decode("utf-8", "replace")
                      if owned else None)
        except (OSError, subprocess.SubprocessError):
            appeared = unchanged = previous = None
            time.sleep(POLL)
            continue
        if screen is None:
            appeared = unchanged = previous = None
            time.sleep(POLL)
            continue
        status = input_status(screen, int(cx), int(cy))
        if status == "busy":
            note("input already contains text")
            return
        now = time.monotonic()
        if status == "empty":
            if appeared is None:
                appeared = now
            if unchanged is None or screen != previous:
                unchanged = now
            if (warm or (native and previous == screen)
                    or (now - appeared >= SETTLE and now - unchanged >= STABLE)):
                paste(tm, pane, text, record)
                if native and not warm:
                    # The agent's word can land a beat before its input is mounted;
                    # a swallowed paste leaves the prompt EMPTY. Re-paste only then:
                    # any text there (ours or the person's) is never pasted over.
                    time.sleep(RECHECK)
                    try:
                        cx, cy = tm("display-message", "-p", "-t", pane, META).decode().strip("\n").split("\t")[2:4]
                        after = tm("capture-pane", "-p", "-e", "-t", pane).decode("utf-8", "replace")
                    except (OSError, ValueError, subprocess.SubprocessError):
                        return
                    if input_status(after, int(cx), int(cy)) == "empty":
                        paste(tm, pane, text, record)
                        record("delivered unsent (second paste)")
                return  # Deliberately no Enter, no seed argument.
        else:
            appeared = unchanged = None
        previous = screen
        time.sleep(POLL)
    note("input did not become ready")


def main():
    socket, pane, filename, warm = sys.argv[1:]
    path = Path(filename)
    try:
        draft = path.read_text(encoding="utf-8")
        prefill(socket, pane, draft, warm == "1")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print("scratch-prefill: " + str(exc), file=sys.stderr)
        return 1
    finally:
        path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
