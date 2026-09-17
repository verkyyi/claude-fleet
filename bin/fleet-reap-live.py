#!/usr/bin/env python3
"""Read-only last-moment liveness gate for dash reaping (#565).

0 = idle enough to continue the separate Git/confirmation gates; 1 = live or
unknown, never permission to reap. All tmux calls inherit this fleet's socket.
"""

import os
from pathlib import Path
import re
import subprocess
import sys


def read(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=5)


def age_seconds(value):
    match = re.fullmatch(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)", value)
    if not match:
        return 0  # An unknown process age is young, never permission to kill.
    days, hours, minutes, seconds = (int(x or 0) for x in match.groups())
    return days*86400+hours*3600+minutes*60+seconds


def agent_name(comm, command):
    name = Path(comm).name
    if name in ("claude", "codex", "codex-real"):
        return name
    if re.fullmatch(r"node\d*|bun", name):
        if re.search(r"claude-code/cli\.js|/claude(?:\s|$)", command):
            return "claude"
        if re.search(r"@openai/codex/|/codex\.js(?:\s|$)", command):
            return "codex"
    return None


def live_reason(target, minimum):
    if not re.fullmatch(r"@\d+", target):
        return "unknown:unstable-target"
    state = read("tmux", "display-message", "-p", "-t", target, "#{@claude_state}").strip()
    if state not in ("", "done"):
        return "state:"+state
    roots = read("tmux", "list-panes", "-t", target, "-F", "#{pane_pid}").split()
    if not roots or not all(p.isdigit() for p in roots):
        return "unknown:pane-pids"
    processes = {}
    children = {}
    for line in read("ps", "-axo", "pid=,ppid=,etime=,comm=").splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4 or not fields[0].isdigit() or not fields[1].isdigit():
            continue
        pid, parent, age, comm = fields
        processes[pid] = (age_seconds(age), comm)
        children.setdefault(parent, []).append(pid)
    if not all(pid in processes for pid in roots):
        return "unknown:pane-process"
    commands = {}
    for line in read("ps", "-axo", "pid=,command=").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            commands[parts[0]] = parts[1]
    seen, todo = set(), list(roots)
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        age, comm = processes[pid]
        agent = agent_name(comm, commands.get(pid, ""))
        if agent and age < minimum:
            return f"young-agent:{agent}:{age}s<{minimum}s"
        # A node/bun process without argv cannot be classified safely.
        if re.fullmatch(r"node\d*|bun", Path(comm).name) and pid not in commands:
            return "unknown:agent-command"
        todo.extend(children.get(pid, []))
    return None


def main():
    raw = os.environ.get("FLEET_REAP_MIN_AGE", "1800")
    minimum = int(raw) if re.fullmatch(r"\d+", raw) else 1800
    try:
        reason = live_reason(sys.argv[1], minimum)
    except (OSError, subprocess.SubprocessError):
        reason = "unknown:liveness-probe"
    if reason:
        print(reason)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
