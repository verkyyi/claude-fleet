#!/usr/bin/env python3
"""Read-only last-moment liveness gate for dash/automatic reaping (#565).

0 = idle enough to continue the separate Git/confirmation gates; 1 = live or
unknown, never permission to reap. Tmux inherits the pane's socket unless an
outside caller selects an explicit fleet socket label.
"""

import argparse
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


def live_reason(target, minimum, socket_name=None):
    if not re.fullmatch(r"@\d+", target):
        return "unknown:unstable-target"
    tmux = ["tmux"] + (["-L", socket_name] if socket_name is not None else [])
    lifecycle = read(*tmux, "display-message", "-p", "-t", target, "#{@worker_lifecycle}").strip()
    if lifecycle:
        return "retained:" + lifecycle
    state = read(*tmux, "display-message", "-p", "-t", target, "#{@claude_state}").strip()
    if state not in ("", "done"):
        return "state:"+state
    roots = read(*tmux, "list-panes", "-t", target, "-F", "#{pane_pid}").split()
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?")
    parser.add_argument("--socket-name", help="fleet socket label for callers outside tmux")
    parser.add_argument("--worktree", help="check bound windows/pane paths across registered fleets")
    parser.add_argument("--socket-names", default="", help="newline-separated registered socket labels")
    args = parser.parse_args()
    raw = os.environ.get("FLEET_REAP_MIN_AGE", "1800")
    minimum = int(raw) if re.fullmatch(r"\d+", raw) else 1800
    try:
        if args.worktree:
            reason = worktree_reason(args.worktree, minimum, args.socket_names.splitlines())
        elif args.target:
            reason = live_reason(args.target, minimum, args.socket_name)
        else:
            reason = "unknown:missing-target"
    except (OSError, ValueError, subprocess.SubprocessError):
        reason = "unknown:liveness-probe"
    if reason:
        print(reason)
        return 1
    return 0


def worktree_reason(worktree, minimum, sockets):
    target = Path(worktree).resolve()
    for socket in sockets:
        prefix = ("tmux", "-L", socket)
        windows = read(*prefix, "list-windows", "-a", "-F", "#{window_id}").split()
        for window in windows:
            if not re.fullmatch(r"@\d+", window):
                return "unknown:window-list"
            bound = read(*prefix, "display-message", "-p", "-t", window, "#{@worktree}").strip()
            paths = read(*prefix, "list-panes", "-t", window, "-F", "#{pane_current_path}").splitlines()
            if bound:
                paths.append(bound)
            for path in paths:
                if not path:
                    continue
                resolved = Path(path).resolve()
                if target == resolved or target in resolved.parents:
                    reason = live_reason(window, minimum, socket)
                    if reason:
                        return reason
                    break
    return None


if __name__ == "__main__":
    sys.exit(main())
