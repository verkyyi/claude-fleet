#!/usr/bin/env python3
"""Window-local reap notice, invalidated by activity or a missed daemon tick."""
import argparse
import subprocess
import time


def tmux(socket=None):
    prefix = ["tmux"] + (["-L", socket] if socket else [])

    def run(*args):
        return subprocess.check_output(prefix + list(args), text=True,
                                       stderr=subprocess.DEVNULL, timeout=5).strip()
    return run


def option(tm, window, name):
    return tm("display-message", "-p", "-t", window, "#{" + name + "}")


def clear(tm, window):
    for name in ("@reap_due", "@reap_seen", "@reap_state_ts", "@reap_key"):
        tm("set-option", "-wu", "-t", window, name)


def notice(tm, window, key, deadline, now=None, dry=False):
    now = int(time.time()) if now is None else now
    state = option(tm, window, "@claude_state")
    stamp = option(tm, window, "@claude_state_ts")
    if state != "done" or not stamp.isdigit() or not 0 < int(stamp) <= now:
        if not dry:
            clear(tm, window)
        raise ValueError("window is not verifiably done")
    old_key = option(tm, window, "@reap_key")
    due = option(tm, window, "@reap_due")
    seen = option(tm, window, "@reap_seen")
    old_stamp = option(tm, window, "@reap_state_ts")
    if (old_key != key or old_stamp != stamp or not due.isdigit()
            or not seen.isdigit() or not 0 <= now - int(seen) <= 180):
        due = now + 60  # At least one visible tick, even for old merged PRs.
    due = max(int(due), deadline)
    if not dry:
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
    a = p.parse_args()
    try:
        due = notice(tmux(a.socket_name), a.window, a.key, a.deadline, dry=a.dry_run)
        print(due)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print("reap notice unavailable: " + str(exc), file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
