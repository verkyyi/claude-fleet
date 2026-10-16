#!/usr/bin/env python3
"""Shared observer/event wait for renderers (#4356, #4357).

Any supplied fleet socket with a client, OR fleet-client-where's active lease,
means watched. The lease has one reader; never infer a device/lease here.
wait-for broadcasts to all CURRENT waiters, and latches one signal with none.
Register before checking visibility/dirty markers to close the read→wait race.
An unobserved renderer blocks until an event, its caller's maintenance deadline,
or the 65s discovery fallback. Dead servers return once for rediscovery. All wait
clients are bounded and reaped; a lease lookup cannot overrun maintenance.

CLI: [--max-frames N] <frame seconds> <socket path>...
     → <elapsed frames> <lease frames left>.
Omitting --max-frames keeps the original 65s wait (#4357's shared interface).
The shell's hot path may test socket u+x (tmux's server_update_socket bit) and
the returned lease lifetime without starting this helper on each visible frame.
"""
import argparse
import json
import math
import os
from pathlib import Path
import selectors
import select
import signal
import stat
import subprocess
import sys
import time

FALLBACK = 65
CHANNEL = 'fleet-state-changed'
BIN = Path(__file__).resolve().parent


def attached(sockets):
    for path in sockets:
        try:
            mode = os.stat(path).st_mode
            if stat.S_ISSOCK(mode) and mode & stat.S_IXUSR:
                return True
        except OSError:
            pass
    return False


def stop(proc):
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    proc.wait()
    if proc.stdout:
        proc.stdout.close()


def wait(sockets, interval, timeout=FALLBACK):
    start = time.monotonic()
    timeout = min(FALLBACK, max(0, timeout))
    parent = os.getppid()
    cache = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'global/render-watch.json'
    lease_until = 0
    checked_until = 0
    try:
        cached = json.loads(cache.read_text())
        checked_until = float(cached['until'])
        # Discard cache from another boot or a bad clock/partial write.
        if not start <= checked_until <= start + FALLBACK:
            checked_until = 0
        if cached['active']:
            lease_until = checked_until
    except (OSError, ValueError, KeyError, TypeError):
        pass
    children = []
    query = None
    lease_output = b''
    owner = None
    owner_fd = None
    with selectors.DefaultSelector() as sel:
        try:
            # Parent death is an event too: no 1s lifetime polling on macOS/Linux.
            if hasattr(os, 'pidfd_open'):
                owner_fd = os.pidfd_open(parent)
            elif hasattr(select, 'kqueue'):
                owner = select.kqueue()
                owner.control([select.kevent(parent, filter=select.KQ_FILTER_PROC,
                                             flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                             fflags=select.KQ_NOTE_EXIT)], 0)
                owner_fd = owner.fileno()
            if owner_fd is not None:
                sel.register(owner_fd, selectors.EVENT_READ, 'owner')
            for path in sockets:
                proc = subprocess.Popen(['tmux', '-S', path, 'wait-for', CHANNEL],
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
                children.append(proc)
                sel.register(proc.stdout, selectors.EVENT_READ, 'event')
            if attached(sockets) or lease_until > start:
                return 1, max(0, math.ceil((lease_until - start) / interval))
            if any(Path(p + '.dirty').exists() for p in sockets):
                return 1, 0
            if checked_until <= start:
                query = subprocess.Popen(['bash', str(BIN / 'fleet-client-where.sh'), '--json'],
                                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                         start_new_session=True)
                children.append(query)
                sel.register(query.stdout, selectors.EVENT_READ, 'lease')
            while time.monotonic() - start < timeout:
                if os.getppid() != parent:
                    break
                deadline = min(3, timeout) if query else timeout
                events = sel.select(max(0, deadline - (time.monotonic() - start)))
                if any(key.data in ('event', 'owner') for key, _ in events):
                    break
                if query and any(key.data == 'lease' for key, _ in events):
                    # Readiness may be PARTIAL output, not process exit. Never
                    # communicate()/wait() here: a stalled lease reader must not
                    # hide state events or consume the maintenance deadline.
                    chunk = os.read(query.stdout.fileno(), 65536)
                    if chunk and len(lease_output) + len(chunk) <= 65536:
                        lease_output += chunk
                        continue
                    sel.unregister(query.stdout)
                    stop(query)
                    try:
                        active = not chunk and json.loads(lease_output).get('state') == 'active'
                    except (ValueError, AttributeError):
                        active = False
                    checked_until = time.monotonic() + FALLBACK
                    lease_until = checked_until if active else 0
                    try:
                        cache.parent.mkdir(parents=True, exist_ok=True)
                        tmp = cache.with_suffix('.%s.tmp' % os.getpid())
                        tmp.write_text(json.dumps({'until': checked_until, 'active': active}))
                        os.replace(tmp, cache)
                    except OSError:
                        pass  # a read-only cache must not prevent event wakeup
                    query = None
                    if active:
                        break
                if query and time.monotonic() - start >= 3:
                    sel.unregister(query.stdout)
                    stop(query)
                    query = None
            now = time.monotonic()
            return max(1, math.ceil((now - start) / interval)), max(0, math.ceil((lease_until - now) / interval))
        finally:
            for child in children:
                stop(child)
            if owner:
                owner.close()
            elif owner_fd is not None:
                os.close(owner_fd)


if __name__ == '__main__':
    # SIGTERM follows the same cleanup path as timeout/exception.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--max-frames', type=int)
    parser.add_argument('interval', type=float)
    parser.add_argument('sockets', nargs='*')
    args = parser.parse_args()
    if not math.isfinite(args.interval) or args.interval <= 0 or (
            args.max_frames is not None and args.max_frames < 1):
        parser.error('interval and max-frames must be positive')
    print(*wait(args.sockets, args.interval,
                FALLBACK if args.max_frames is None else args.max_frames * args.interval))
