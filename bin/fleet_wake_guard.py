#!/usr/bin/env python3
"""C7: the existing wrapper's bounded native-start guard, not a dispatcher.

Slots are machine-wide flock files. The owner holds one through the first native
receipt (or process exit), then waits for its child without polling. Queue tickets
are themselves locked: a dead waiter cannot block humans or leave a stale slot.
"""
import argparse
import fcntl
from functools import lru_cache
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import uuid

import fleet_session_gate as gate

HUMAN = {'键盘', '网页', '回答', 'keyboard', 'web', 'answer'}


@lru_cache(maxsize=1)
def settings():
    # Wrappers live across hub setting updates. Read the ordinary config road
    # at each wake rather than freezing the slot count in their launch env.
    try:
        p = subprocess.run(['bash', '-c', '. "$1/fleet-lib.sh" >/dev/null 2>&1; '
                            'printf "%s\\n%s" "${FLEET_SESSION_WAKE_SLOTS:-3}" "${FLEET_WAKE_SLOT_DIR:-}"',
                            'wake-settings', str(gate.BIN)], capture_output=True, text=True, timeout=10)
        if p.returncode == 0:
            lines = p.stdout.split('\n', 1)
            return lines[0], lines[1] if len(lines) > 1 else ''
    except (OSError, subprocess.SubprocessError):
        pass
    return '3', ''


def slots():
    raw = os.environ.get('FLEET_SESSION_WAKE_SLOTS') or settings()[0]
    value = int(raw) if raw.isdigit() else 3
    return value if 1 <= value <= 32 else 3


def root():
    base = '/Users/Shared/claude-fleet/wake' if sys.platform == 'darwin' else '/var/tmp/claude-fleet/wake'
    path = Path(os.environ.get('FLEET_WAKE_SLOT_DIR') or settings()[1] or base)
    # The directory is shared across managed logins, never under a login HOME.
    for directory in (path.parent, path):
        try:
            directory.mkdir(mode=0o1777, parents=True)
            directory.chmod(0o1777)
        except FileExistsError:
            pass
    return path


def shared_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError('wake slot is not a regular file')
    if os.fstat(fd).st_uid == os.getuid():
        os.fchmod(fd, 0o644)
    return os.fdopen(fd, 'r')


def try_lock(file):
    try:
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def humans_waiting(directory):
    for path in directory.glob('human-*'):
        try:
            with shared_file(path) as file:
                if not try_lock(file):
                    return True
        except FileNotFoundError:
            continue
    return False


def admitted():
    """Use the existing machine admission reader (including its hysteresis)."""
    import shlex
    seam = os.environ.get('FLEET_WAKE_ADMIT_CMD')
    cmd = shlex.split(seam) if seam else [
        'bash', '-c', '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_machine_admit --short', 'wake', str(gate.BIN)]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return p.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def defer(meta_path, meta, why):
    meta.update(deferred=why, retry_at=time.time() + 30)
    gate.write_json(meta_path, meta)
    gate.write_json(meta['seed'] + '.deferred', meta)
    gate.park_log(meta['fid'], 'deferred', meta.get('why', ''), result=why,
                  next_at=meta.get('next', 0), started=meta.get('started', 0))


def acquire(meta_path, meta):
    directory = root()
    human = meta.get('why') in HUMAN
    ticket = directory / (('human-' if human else 'timer-') + uuid.uuid4().hex)
    with shared_file(ticket) as waiting:
        fcntl.flock(waiting, fcntl.LOCK_EX)
        try:
            end = time.monotonic() + 60
            while time.monotonic() < end:
                if human or not humans_waiting(directory):
                    for i in range(slots()):
                        file = shared_file(directory / ('slot-%d' % i))
                        if try_lock(file):
                            # A timer waits for capacity to recover; a person's
                            # submitted words have priority, but still need a slot.
                            if not human and not admitted():
                                file.close()
                                defer(meta_path, meta, 'memory')
                                return None
                            if time.monotonic() >= end:
                                file.close()
                                defer(meta_path, meta, 'wake_queue_timeout')
                                return None
                            return file
                        file.close()
                time.sleep(.1)
            defer(meta_path, meta, 'wake_queue_timeout')
            return None
        finally:
            ticket.unlink(missing_ok=True)


def run(meta_path, cmd):
    meta = gate.read_json(meta_path)
    if not meta or not cmd:
        return 2
    # Kept separately so old gate callers still read the original metadata.
    seed = Path(meta['seed'])
    lease = None
    child = None
    old_handlers = {}
    try:
        lease = acquire(meta_path, meta)
        if lease is None:
            return 75
        gate.write_json(str(seed) + '.admitted', dict(at=time.time()))
        # Inherit the lease into the launch: SIGKILL of this guard must not
        # free capacity while its child is still starting. LOCK_UN on the shared
        # open description releases both copies only after native readiness.
        child = subprocess.Popen(cmd, start_new_session=True, pass_fds=(lease.fileno(),))
        def forward(signum, _frame):
            if child.poll() is None:
                os.killpg(child.pid, signum)
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT, signal.SIGWINCH):
            old_handlers[sig] = signal.signal(sig, forward)
        end = time.monotonic() + gate.num_env('FLEET_GATE_WAKE_SECS', 20)
        while child.poll() is None:
            if Path(str(seed) + '.launched').exists():
                fcntl.flock(lease, fcntl.LOCK_UN)
                lease.close()
                lease = None
                return child.wait()
            if time.monotonic() >= end:
                # The wrapper receives the failure only AFTER this launch is
                # dead. A timed-out first prompt cannot start behind its retry.
                gate.write_json(str(seed) + '.error', dict(reason='wake_timeout'))
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                return 1
            time.sleep(.05)
        return child.returncode
    except OSError as error:
        gate.write_json(str(seed) + '.error', dict(reason='wake_guard', detail=str(error)))
        return 1
    finally:
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait()
        if lease is not None:
            lease.close()
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['run'])
    p.add_argument('--meta', required=True)
    args, cmd = p.parse_known_args()
    return run(Path(args.meta), cmd[1:] if cmd[:1] == ['--'] else cmd)


if __name__ == '__main__':
    sys.exit(main())
