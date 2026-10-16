#!/usr/bin/env python3
"""Submit a warm pane's first turn, keeping observation and clocks in one process.

The shell entry point remains compatible with old sessions. The paste and Enter
stay separate, with the same settling delay and bounded confirmation/retries.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time


spec = importlib.util.spec_from_file_location("fleet_input", Path(__file__).with_name("fleet-input.py"))
prompt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prompt)


def seconds(name, default):
    value = os.environ.get(name, str(default))
    return int(value) if value and value.isascii() and value.isdigit() else default


def now_ms():
    return time.time_ns() // 1_000_000


def submit(sock, target, text):
    base = ["tmux", "-L", sock]

    def tm(*args):
        return subprocess.check_output(base + list(args), stderr=subprocess.DEVNULL,
                                       text=True, timeout=5).rstrip("\n")

    try:
        pane = tm("display-message", "-p", "-t", target, "#{pane_id}")
    except (OSError, subprocess.SubprocessError):
        pane = ""
    if not pane.startswith("%") or not pane[1:].isdigit():
        print("fleet-pane-submit: no pane at " + target, file=sys.stderr)
        return 1

    def state():
        try:
            return tm("display-message", "-p", "-t", pane,
                      "#{pane_dead}#{pane_in_mode} #{@claude_state}")
        except (OSError, subprocess.SubprocessError):
            return ""

    def busy():
        # Keep fleet-input.py --busy's existing unknown-screen semantics.
        try:
            return prompt.snapshot(sock, pane)["busy"]
        except (OSError, ValueError, subprocess.SubprocessError):
            return False

    ready = False
    for _ in range(seconds("FLEET_SUBMIT_WAIT_SECS", 5) * 10 + 1):
        st = state()
        if st.startswith("00 ") and not st[3:].startswith(("working", "looping", "needs", "waking")):
            if not busy():
                ready = True
                break
        time.sleep(0.1)
    if not ready:
        print(f"fleet-pane-submit: {target} never showed an idle, empty input — nothing typed", file=sys.stderr)
        return 3
    t_ready = now_ms()
    buf = "fleet-submit-" + str(os.getpid())
    try:
        tm("set-buffer", "-b", buf, "--", text)
    except (OSError, subprocess.SubprocessError):
        print("fleet-pane-submit: set-buffer failed", file=sys.stderr)
        return 1
    try:
        tm("paste-buffer", "-t", pane, "-b", buf, "-d", "-p")
    except (OSError, subprocess.SubprocessError):
        try:
            tm("delete-buffer", "-b", buf)
        except (OSError, subprocess.SubprocessError):
            pass
        print("fleet-pane-submit: paste failed", file=sys.stderr)
        return 1
    time.sleep(0.15)
    # The sanctioned two-step injection; no shell or interpolated tmux command.
    try:
        tm("send-keys", "-t", pane, "Enter")
    except (OSError, subprocess.SubprocessError):
        print("fleet-pane-submit: Enter failed", file=sys.stderr)
        return 1
    t_prompt = now_ms()
    again = 0
    for t in range(1, seconds("FLEET_SUBMIT_CONFIRM_SECS", 6) * 10 + 1):
        time.sleep(0.1)
        if state().startswith("00 working"):
            print(f"{t_ready}\t{t_prompt}")
            return 0
        if busy():
            if again < 3 and t >= 6 + again * 10:
                again += 1
                try:
                    tm("send-keys", "-t", pane, "Enter")
                except (OSError, subprocess.SubprocessError):
                    pass
        elif t >= 3:
            print(f"{t_ready}\t{t_prompt}")
            return 0
    print(f"fleet-pane-submit: the text was typed into {target} but the turn did not start", file=sys.stderr)
    return 4


def main():
    if len(sys.argv) != 4 or not all(sys.argv[1:3]) or not Path(sys.argv[3]).is_file():
        print("usage: fleet-pane-submit.sh <socket> <window|pane> <text-file>", file=sys.stderr)
        return 2
    text = Path(sys.argv[3]).read_bytes().decode("utf-8").rstrip("\n")
    if not text.strip():
        print("fleet-pane-submit: nothing to submit", file=sys.stderr)
        return 2
    return submit(sys.argv[1], sys.argv[2], text)


if __name__ == "__main__":
    sys.exit(main())
