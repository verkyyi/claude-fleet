#!/usr/bin/env python3
"""Prefill a new scratch's input without submitting it; preserve existing input.

Args: socket-label pane-id name-file warm(0|1). The caller owns the window;
this helper owns and removes the temporary name file and tmux paste buffer.
Cold readiness follows scratch-pool.sh: a painted prompt alone is too early,
so wait for a stable screen AND ten seconds since the empty prompt appeared.
"""

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
            if cy != y or cx != start:
                return "busy"
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
            return "empty"
    return "waiting"


def prefill(socket, pane, draft, warm):
    prefix = ["tmux", "-L", socket]

    def tm(*args):
        return subprocess.run(prefix + list(args), stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=5, check=True).stdout

    def note(reason):
        tm("display-message", "scratch: name not prefilled — " + reason)

    # A name is one input line. Drop terminal control bytes (especially CR/LF,
    # Escape and DEL) before pasting, so even unusual CLI names cannot submit or
    # end bracketed paste. Keep Unicode, spaces, #, quotes and the entire name.
    text = "".join(c for c in draft if ord(c) >= 32 and not 127 <= ord(c) < 160)
    if not text.strip():
        return
    deadline = time.monotonic() + TIMEOUT
    appeared = unchanged = None
    previous = None
    while time.monotonic() < deadline:
        meta = tm("display-message", "-p", "-t", pane,
                  "#{pane_dead}\t#{pane_current_command}\t#{cursor_x}\t#{cursor_y}"
                  "\t#{@claude_state}\t#{pane_in_mode}").decode().strip().split("\t")
        if len(meta) != 6 or meta[0] != "0":
            return
        command, cx, cy, state, mode = meta[1:]
        if state in ("working", "busy", "needs", "looping") or mode != "0":
            note("session is already in use")
            return
        # Native Claude releases may report their version as the process name;
        # npm installs run as node. In particular, never paste into a shell left
        # behind by a failed/exited agent, even if its old prompt is still visible.
        if command not in ("claude", "codex", "node") and not re.fullmatch(r"\d+\.\d+\.\d+[\w.-]*", command):
            appeared = unchanged = previous = None
            time.sleep(POLL)
            continue
        screen = tm("capture-pane", "-p", "-e", "-t", pane).decode("utf-8", "replace")
        status = input_status(screen, int(cx), int(cy))
        if status == "busy":
            note("input already contains text")
            return
        now = time.monotonic()
        if status == "empty":
            if appeared is None:
                appeared = now
            if screen != previous:
                unchanged = now
            if warm or (now - appeared >= SETTLE and now - unchanged >= STABLE):
                buf = "scratch-draft-" + str(os.getpid())
                try:
                    tm("set-buffer", "-b", buf, "--", text)
                    tm("paste-buffer", "-p", "-d", "-b", buf, "-t", pane)
                finally:
                    try:
                        tm("delete-buffer", "-b", buf)
                    except subprocess.CalledProcessError:
                        pass
                return  # Deliberately no Enter, no seed argument, no retry paste.
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
