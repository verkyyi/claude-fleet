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
import runpy
import subprocess
import sys
import time

# The @loop reader (issue #1331) sits beside this script — or beside its target,
# when only this file was linked into a sandbox bin/. Missing ⇒ the import fails
# and the probe exits non-zero: never permission to reap.
_HERE = Path(__file__).absolute().parent
LOOPMARK = runpy.run_path(str(next(
    (d / "fleet_loop_mark.py" for d in (_HERE, Path(__file__).resolve().parent)
     if (d / "fleet_loop_mark.py").is_file()), _HERE / "fleet_loop_mark.py")))
LIB = next((d / "fleet-lib.sh" for d in (_HERE, Path(__file__).resolve().parent)
            if (d / "fleet-lib.sh").is_file()), _HERE / "fleet-lib.sh")


def waiting(target, socket_name=None):
    """fleet_window_wait's other two reasons (issue #1370) — '' | 'children' | 'bg'.

    A parent whose sub-task is not finished, or whose agent still owns a Bash-tool
    job, is idle but not done: the same answer its Stop hook stamps `looping` +
    @claude_wait from. Asked here too, because a window stamped `done` before the
    sync (or by any writer that never asked) must not be reaped out from under it."""
    script = ('. "$1"; t=$2; L=$3\n'
              's=$(tmux ${L:+-L "$L"} display-message -p -t "$t" "#{?#{session_group},#{session_group},#{session_name}}" 2>/dev/null)\n'
              '[ -n "$L" ] && TMUX=\n'
              'fleet_window_waiting_children "$s" "$t" >/dev/null 2>&1 && { echo children; exit 0; }\n'
              'fleet_window_bg_busy "$s" "$t" 1 && echo bg\n'
              'exit 0\n')
    out = subprocess.run(["bash", "-c", script, "reap-live", str(LIB), target, socket_name or ""],
                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         text=True, timeout=30).stdout.strip()
    return out if out in ("children", "bg") else ""


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


def merged_in_life(merged_at, age, now):
    """True only when the merge provably happened while THIS agent ran (#1329).

    Start = now - etime. Unknown/future times never waive: an unparsed etime is
    age 0 (start = now), and a merge at or after `now` is not in the past."""
    if merged_at is None or now is None:
        return False
    return now - age < merged_at <= now


def live_reason(target, minimum, socket_name=None, merged_at=None, waived=None, now=None):
    if not re.fullmatch(r"@\d+", target):
        return "unknown:unstable-target"
    tmux = ["tmux"] + (["-L", socket_name] if socket_name is not None else [])
    # A HOLD (issue #1244) is the operator's "keep this one" — e.g. a sleeper
    # parked on post-release verification. It retains any worker, asleep or not.
    if read(*tmux, "display-message", "-p", "-t", target, "#{@reap_hold}").strip() == "1":
        return "retained:hold"
    # A pending LOOP (issue #1331) — the agent scheduled its own next round
    # (ScheduleWakeup / CronCreate → @loop) or a fleet-loop.py ledger holds one.
    # The window is idle between rounds, not finished: reaping it would take the
    # Loop with it. Ahead of the lifecycle, age and state gates; a stopped or
    # expired Loop reads `none` here and the window reaps by the ordinary rules.
    raw = read(*tmux, "display-message", "-p", "-t", target,
               "#{@loop}\t#{@handoff_manifest}").rstrip("\n")
    value, _, manifest = raw.partition("\t")
    if (value or manifest) and LOOPMARK["status"](value, manifest)[0] == "active":
        return "retained:loop"
    why = waiting(target, socket_name)
    if why:
        return "retained:" + why
    lifecycle = read(*tmux, "display-message", "-p", "-t", target, "#{@worker_lifecycle}").strip()
    # A SLEEPING worker has no agent at all — its pane is the park page — so it is
    # the safest reap there is (issue #1244): no age gate, only the process walk
    # below, which refuses ANY agent found under it (a wake mid-flight). The state
    # gate still applies — a `looping` sleeper has a scheduled wake pending. The
    # transitional phases (preparing/waking) and a failed wake stay retained.
    sleeping = lifecycle == "sleeping"
    if lifecycle and not sleeping:
        return "retained:" + lifecycle
    state = read(*tmux, "display-message", "-p", "-t", target, "#{@claude_state}").strip()
    # A `looping` stamp on a worker whose PR merged (issue #1356, R4 of EPIC
    # #1529): its own ship is done, and what holds the stamp is a round it
    # scheduled to wait for that merge. It is waived ONLY with a merge time and
    # only when the walk below finds an agent and every agent was alive at the
    # merge — an ACTIVE @loop mark, a running child or bg job already returned above
    # (#1331's ruling: a live Loop is kept), so this never takes a pending round.
    looping = state == "looping" and merged_at is not None
    # `exited` (issue #1784): the agent left and the pane holds the recovery page —
    # as idle as `done`; the walk below still refuses any agent found under it.
    if state not in ("", "done", "exited") and not looping:
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
    seen, todo, shipped = set(), list(roots), False
    while todo:
        pid = todo.pop()
        if pid in seen:
            continue
        seen.add(pid)
        age, comm = processes[pid]
        agent = agent_name(comm, commands.get(pid, ""))
        if agent and sleeping:
            return f"retained:sleeping:agent-{agent}"
        # The age gate protects a freshly spawned AWAKE agent (#565); a sleeper
        # never reaches it — it has no agent to protect. A short worker that
        # merged its own PR is not fresh (#1329): with an explicit `done` and a
        # mergedAt AFTER this agent started, the merge happened in its life. A
        # worker spawned onto an already-merged branch started after the merge
        # and keeps its protection.
        if agent and looping:
            if not merged_in_life(merged_at, age, now):
                return "state:looping"
            shipped = True
        if agent and age < minimum:
            if state in ("done", "looping") and merged_in_life(merged_at, age, now):
                if waived is not None:
                    waived.append(f"{agent}:{age}s<{minimum}s")
            else:
                return f"young-agent:{agent}:{age}s<{minimum}s"
        # A node/bun process without argv cannot be classified safely.
        if re.fullmatch(r"node\d*|bun", Path(comm).name) and pid not in commands:
            return "unknown:agent-command"
        todo.extend(children.get(pid, []))
    if looping:
        # No agent under the pane proves nothing shipped: keep the stamp's word.
        if not shipped:
            return "state:looping"
        if waived is not None:
            waived.append("looping")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?")
    parser.add_argument("--socket-name", help="fleet socket label for callers outside tmux")
    parser.add_argument("--worktree", help="check bound windows/pane paths across registered fleets")
    parser.add_argument("--socket-names", default="", help="newline-separated registered socket labels")
    parser.add_argument("--merged-at", help="PR merge epoch: waive the age gate for an agent alive at the merge (#1329)")
    args = parser.parse_args()
    raw = os.environ.get("FLEET_REAP_MIN_AGE", "1800")
    minimum = int(raw) if re.fullmatch(r"\d+", raw) else 1800
    merged_at = None
    if args.merged_at is not None and re.fullmatch(r"[1-9]\d*", args.merged_at):
        merged_at = int(args.merged_at)
    waived = []
    try:
        if args.worktree:
            reason = worktree_reason(args.worktree, minimum, args.socket_names.splitlines(),
                                     merged_at, int(time.time()) if merged_at is not None else None)
        elif args.target:
            reason = live_reason(args.target, minimum, args.socket_name, merged_at, waived,
                                 int(time.time()) if merged_at is not None else None)
        else:
            reason = "unknown:missing-target"
    except (OSError, ValueError, subprocess.SubprocessError):
        reason = "unknown:liveness-probe"
    if reason:
        print(reason)
        return 1
    if waived:
        # Exit 0 still means reapable; the line only lets the caller log the waiver.
        print("waived:" + ",".join(w if w == "looping" else "young-agent:" + w for w in waived))
    return 0


def worktree_reason(worktree, minimum, sockets, merged_at=None, now=None):
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
                    reason = live_reason(window, minimum, socket, merged_at, None, now)
                    if reason:
                        return reason
                    break
    return None


if __name__ == "__main__":
    sys.exit(main())
