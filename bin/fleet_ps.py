#!/usr/bin/env python3
"""One numeric-UID process snapshot per machine, at most once every five seconds.

The sticky directory is independent of HOME/TMPDIR. Standalone logins may refresh their own cache;
the supervisor publishes as root for every login; readers validate its owner.
The shared lock inode is never removed. Busy/cold/failed reads raise OSError,
never fall back to independent ps scans. No environment is collected.
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

from fleet_tick_lock import acquire

TTL = 5
FIELDS = 'pid,ppid,uid,pgid,stat,rss,pcpu,etime,time,lstart,tty,comm,command'


def directory():
    path = Path(os.environ.get('FLEET_PS_CACHE_DIR', '/tmp/claude-fleet-ps-v1'))
    try:
        path.mkdir(mode=0o1777)
        path.chmod(0o1777)  # mkdir's mode is subject to the caller's umask
    except FileExistsError:
        pass
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_mode & 0o1777 != 0o1777:
        raise OSError('unsafe process cache directory')
    return path


def read_file(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != int(path.stem) or st.st_mode & 0o022:
            raise OSError('unsafe process snapshot')
        return json.load(f)


def root_publisher(path):
    try:
        st = (path / 'publisher').lstat()
        return stat.S_ISREG(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022
    except OSError:
        return False


def latest(path):
    # On managed machines root publishes for all logins. Never let a tenant
    # forge another login's process/resource observations. Without that service
    # a standalone login keeps its own bounded cache.
    uid = 0 if root_publisher(path) else os.geteuid()
    try:
        row = read_file(path / ('%d.json' % uid))
        if 0 <= time.time() - row['at'] < TTL:
            return row
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return {}


def publish(path, row):
    fd, tmp = tempfile.mkstemp(prefix='.', dir=str(path))
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(row, f, separators=(',', ':'))
            os.fchmod(f.fileno(), 0o644)
        os.replace(tmp, path / ('%d.json' % os.geteuid()))
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def parse(text):
    lines = text.splitlines()
    if not lines: raise OSError('empty ps snapshot')
    header = lines[0]
    comm, command = header.index('COMM'), header.index('COMMAND')
    result = []
    for line in lines[1:]:
        # lstart is the five C-locale words after the first nine scalar columns.
        prefix = line[:comm].split()
        if len(prefix) != 15 or not all(prefix[i].lstrip("-").isdigit() for i in (0, 1, 2, 3, 5)):
            raise OSError('malformed ps snapshot')
        values = prefix[:9] + [' '.join(prefix[9:14]), prefix[14],
                               line[comm:command].strip(), line[command:].strip()]
        result.append(dict(zip(FIELDS.split(','), values)))
    if not result: raise OSError('empty ps snapshot')
    return result


def snapshot(publish_tick=False):
    path = directory()
    if publish_tick and os.geteuid() == 0:
        # Root opts this machine into read-only consumers before the first scan.
        # A stale publisher never causes a seven-login fallback stampede.
        fd = os.open(str(path / 'publisher'), os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644)
        try:
            st = os.fstat(fd)
            if st.st_uid != 0 or not stat.S_ISREG(st.st_mode):
                raise OSError('unsafe process publisher marker')
            os.fchmod(fd, 0o644)
        finally: os.close(fd)
    cached = {} if publish_tick else latest(path)
    if cached:
        if 'rows' not in cached: raise OSError('process refresh failed or in progress')
        return cached['rows']
    if not publish_tick and root_publisher(path):
        raise OSError('machine process snapshot unavailable; waiting for publisher')
    fd = acquire(path / 'refresh.lock')
    if fd is None: raise OSError('process refresh busy')
    try:
        # Readers from another login must be able to flock this same inode.
        if os.fstat(fd).st_uid == os.geteuid(): os.fchmod(fd, 0o644)
        cached = {} if publish_tick else latest(path)
        if cached:
            if 'rows' not in cached: raise OSError('process refresh failed or in progress')
            return cached['rows']
        # Persist failed attempts too: a broken ps cannot trigger a retry storm.
        # Keep a still-fresh completed sample readable during a proactive
        # publisher refresh: memguard often runs in the very same scheduler pass.
        if not publish_tick or 'rows' not in latest(path):
            publish(path, {'at': time.time()})
        # A non-final comm defaults to 16 columns on BSD. Its header sets a
        # portable minimum width; preserve paths/spaces up to PATH_MAX.
        width = 1024 if sys.platform == 'darwin' else 4096
        layout = FIELDS.replace('comm,', 'comm=' + 'COMM'.ljust(width, '_') + ',')
        raw = subprocess.run([os.environ.get('FLEET_PS_COMMAND', 'ps'), '-axww', '-o', layout],
                             capture_output=True, text=True, errors='replace', timeout=10,
                             check=True, env=dict(os.environ, LC_ALL='C'), pass_fds=(fd,)).stdout
        data = parse(raw)
        publish(path, {'at': time.time(), 'rows': data})
        return data
    except (subprocess.SubprocessError, ValueError) as e:
        raise OSError('process refresh failed') from e
    finally:
        os.close(fd)


def rows(fields):
    names = fields.replace('=', '').split(',')
    if any(n not in FIELDS.split(',') for n in names): raise ValueError('unsupported process field')
    data = snapshot()
    # ps lstart uses a fixed 24-column field; pending-tool's parser depends on it.
    def value(row, name):
        if name == 'lstart':
            return time.strftime('%a %b %e %H:%M:%S %Y', time.strptime(row[name], '%a %b %d %H:%M:%S %Y'))
        return row[name]
    return ''.join(' '.join(value(row, n) for n in names) + '\n' for row in data)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--publish']: snapshot(publish_tick=True)
        else: sys.stdout.write(rows(sys.argv[1]))
    except BrokenPipeError:
        sys.exit(0)
    except (OSError, ValueError, IndexError) as e:
        print('fleet-ps: %s' % e, file=sys.stderr)
        sys.exit(1)
