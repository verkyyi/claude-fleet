#!/usr/bin/env python3
"""Prove an unused Codex TUI can echo and clear input; never submit a turn."""
import argparse
import os
from pathlib import Path
import runpy
import subprocess
import sys
import time

INPUT = runpy.run_path(str(Path(__file__).with_name('scratch-prefill.py')))


def has_agent(owner):
    # tmux may report the launcher's zsh even while the Codex TUI owns input.
    rows = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], timeout=3).decode().splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows[int(fields[0])] = (int(fields[1]), Path(fields[2]).name)
    pending, seen = [int(owner)], set()
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        name = rows.get(pid, (0, ''))[1]
        if name == 'codex' or name.startswith('codex-'):
            return True
        pending.extend(p for p, (parent, _) in rows.items() if parent == pid and p != pid)
    return False


def warm(socket, pane, timeout=120, settle=10, hits=8):
    def tm(*args):
        return subprocess.check_output(['tmux', '-L', socket, *args], stderr=subprocess.PIPE,
                                       timeout=5).decode('utf-8', 'replace').rstrip('\n')

    owner = None

    def screen():
        nonlocal owner
        row = tm('display-message', '-p', '-t', pane,
                 '#{@cc_agent}|#{@cc_launcher_pid}|#{pane_dead}|#{pane_current_command}|'
                 '#{cursor_x}|#{cursor_y}|#{pane_in_mode}|#{@claude_state}').split('|')
        if len(row) != 8 or row[0] != 'codex' or not row[1].isdigit():
            return None
        if owner is None:
            owner = row[1]
        if row[1] != owner or row[2] != '0' or row[6] != '0' or row[7] in ('busy', 'working', 'needs'):
            raise ValueError('Codex pool entry changed or is already in use')
        os.kill(int(owner), 0)
        if row[3] not in ('codex', 'node') and not has_agent(owner):
            return None  # no input goes into a leftover shell
        text = tm('capture-pane', '-p', '-e', '-t', pane)
        return text, INPUT['input_status'](text, int(row[4]), int(row[5]))

    deadline = time.monotonic() + timeout
    appeared, previous, stable = None, None, 0
    while time.monotonic() < deadline:
        snapshot = screen()
        now = time.monotonic()
        if snapshot and snapshot[1] == 'empty':
            appeared = now if appeared is None else appeared
            stable = stable + 1 if snapshot[0] == previous else 0
            previous = snapshot[0]
            if now - appeared >= settle and stable >= hits:
                break
        else:
            appeared, previous, stable = None, None, 0
        time.sleep(0.5)
    else:
        return False
    tm('send-keys', '-t', pane, '-l', '~')
    while time.monotonic() < deadline:
        time.sleep(0.1)
        snapshot = screen()
        if snapshot and any(line.strip() == '› ~' for line in INPUT['SGR'].sub('', snapshot[0]).splitlines()):
            tm('send-keys', '-t', pane, 'C-u')
            break
    else:
        return False
    while time.monotonic() < deadline:
        time.sleep(0.1)
        snapshot = screen()
        if snapshot and snapshot[1] == 'empty':
            return True
    return False


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', required=True)
    parser.add_argument('--pane', required=True)
    parser.add_argument('--timeout', type=float, default=120)
    parser.add_argument('--settle', type=float, default=10)
    parser.add_argument('--stable-hits', type=int, default=8)
    args = parser.parse_args()
    try:
        if not 0 < args.timeout <= 240 or not 0 <= args.settle <= 240 or not 0 <= args.stable_hits <= 480:
            raise ValueError('invalid warm-up timing bounds')
        sys.exit(0 if warm(args.socket, args.pane, args.timeout, args.settle, args.stable_hits) else 1)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('fleet-codex-warm: ' + str(error), file=sys.stderr)
        sys.exit(1)
