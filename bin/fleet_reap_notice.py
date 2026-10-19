#!/usr/bin/env python3
"""Window-local reap notice, invalidated by activity or a missed daemon tick."""
import argparse
import json
import subprocess
import time

# The agent's own last word (OSC 7501, @agent_status — issue #2540) outranks the
# hook stamp for «has it finished?»: fleet-reap-live.py's SELF_STATES, the
# finished half. A Stop hook stamps `looping` while a child or a job is pending
# (issue #1370) and keeps that stamp after the child is gone; the gates that read
# the pending work themselves (fleet-reap-live.py, busy()) still hold such a
# window — the stamp alone must not (issue #4822).
FINISHED_WORDS = {"done": "done", "idle": "done", "error": "exited", "exited": "exited"}


def reap_state(stamped, status):
    """@claude_state + @agent_status → the state a reaper judges a finished
    window by: the agent's finished 7501 word when it said one, else the stamp."""
    try:
        rec = json.loads(status) if status else None
    except ValueError:
        rec = None
    word = rec.get("state") if isinstance(rec, dict) else None
    return FINISHED_WORDS.get(word, stamped)


def tmux(socket=None):
    prefix = ["tmux"] + (["-L", socket] if socket else [])

    def run(*args):
        return subprocess.check_output(prefix + list(args), text=True,
                                       stderr=subprocess.DEVNULL, timeout=5).strip()
    return run


def option(tm, window, name):
    return tm("display-message", "-p", "-t", window, "#{" + name + "}")


def clear(tm, window):
    for name in ("@reap_due", "@reap_seen", "@reap_state_ts", "@reap_key", "@reap_hold"):
        tm("set-option", "-wu", "-t", window, name)


def notice(tm, window, key, deadline, now=None, dry=False, hold=None):
    now = int(time.time()) if now is None else now
    state = reap_state(option(tm, window, "@claude_state"), option(tm, window, "@agent_status"))
    stamp = option(tm, window, "@claude_state_ts")
    # exited (issue #1784): the agent gone, the pane on its recovery page — as
    # idle as a finished turn, and the no-PR pass closes it too (issue #1832).
    if state not in ("done", "exited") or not stamp.isdigit() or not 0 < int(stamp) <= now:
        if not dry:
            clear(tm, window)
        raise ValueError("window is not verifiably done")
    if hold is not None:
        # Held, not counting down (issue #1156): the reap is refused until the
        # operator acts, so there is no due time. Same freshness contract as a
        # countdown -- tied to this done turn, expires without a confirming tick.
        if not dry:
            for name, value in (("@reap_key", key), ("@reap_state_ts", stamp),
                                ("@reap_due", "hold"), ("@reap_seen", str(now)),
                                ("@reap_hold", hold)):
                tm("set-option", "-w", "-t", window, name, value)
        return "hold"
    old_key = option(tm, window, "@reap_key")
    due = option(tm, window, "@reap_due")
    was_held = due == "hold"
    seen = option(tm, window, "@reap_seen")
    old_stamp = option(tm, window, "@reap_state_ts")
    if (old_key != key or old_stamp != stamp or not due.isdigit()
            or not seen.isdigit() or not 0 <= now - int(seen) <= 180):
        due = now + 60  # At least one visible tick, even for old merged PRs.
    due = max(int(due), deadline)
    if not dry:
        if was_held:
            tm("set-option", "-wu", "-t", window, "@reap_hold")
        for name, value in (("@reap_key", key), ("@reap_state_ts", stamp),
                            ("@reap_due", str(due)), ("@reap_seen", str(now))):
            tm("set-option", "-w", "-t", window, name, value)
    return due


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("window")
    p.add_argument("key")
    p.add_argument("deadline", type=int)
    p.add_argument("--socket-name")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--hold", help="reap refused: show this text instead of a countdown")
    a = p.parse_args()
    try:
        due = notice(tmux(a.socket_name), a.window, a.key, a.deadline,
                     dry=a.dry_run, hold=a.hold)
        print(due)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print("reap notice unavailable: " + str(exc), file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
