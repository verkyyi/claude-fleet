#!/usr/bin/env python3
"""Nonblocking kernel locks shared by periodic entrypoints and the supervisor.

Never unlink a lock inode or steal by age: a slow live holder still owns it.
The exec runner keeps its descriptor through foreground children, including if
its shell dies. Detached fleet_bg work closes that descriptor before leaving.
"""
import fcntl
import os
from pathlib import Path
import re
import sys
import stat
import time


def acquire(path):
    """Return a held fd, or None when another invocation owns the inode."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(str(path), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644)
    except PermissionError:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode): raise OSError('lock is not a regular file')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    except BaseException:
        os.close(fd)
        raise
    return fd


def main(argv):
    if len(argv) < 3 or argv[0] != 'run' or not re.fullmatch(r'[A-Za-z0-9_.-]+', argv[1]):
        return 2
    key = argv[1]
    directory = os.environ.get('FLEET_JOB_LOCK_DIR') or str(
        Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'job-locks')
    fd = acquire(Path(directory) / (key + '.lock'))
    if fd is None:
        print('%s fleet-job: skip: busy %s' % (time.strftime('%Y-%m-%dT%H:%M:%S'), key), file=sys.stderr)
        return 0
    # Fixed descriptor makes it possible for the shell's detached-work helper
    # to close it without eval. Foreground processes keep the lease alive.
    os.dup2(fd, 198, inheritable=True)
    if fd != 198: os.close(fd)
    os.environ['FLEET_JOB_PID'] = str(os.getpid())
    os.environ['FLEET_JOB_KEY'] = key
    os.execvp(argv[2], argv[2:])


if __name__ == '__main__':
    try: sys.exit(main(sys.argv[1:]))
    except OSError as e:
        print('fleet-job: lock unavailable: %s' % e, file=sys.stderr)
        sys.exit(1)
