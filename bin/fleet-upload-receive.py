#!/usr/bin/env python3
"""Checked thin-client upload protocol (#4379), invoked by client-upload.

The SSH login is the authority. A connection token + selection generation must
still own an attached view; the existing identity resolver pins its destination.
Only staged files are removed on failure. Completed uploads are never rolled back.
"""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).resolve().parent
LIMIT = 100 << 20
FMT = '#{window_id}|#{@fleet_id}|#{@peer_cur}|#{pane_id}|#{pane_pid}|#{@cc_launcher_pid}|#{@cc_session_id}|#{@codex_session_id}|#{pane_current_command}|#{pane_dead}'
ID = re.compile(r'^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}$')


def load(name):
    spec = importlib.util.spec_from_file_location(name, BIN / (name + '.py'))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


def run(cmd, data=None, source=None, limit=65536):
    p = subprocess.Popen(cmd, stdin=source if source else subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    out = bytearray()
    try:
        if source is None:
            if data: p.stdin.write(data)
            p.stdin.close()
        deadline = time.monotonic() + (110 if source else 10)
        while time.monotonic() < deadline:
            if not select.select([p.stdout], [], [], .05)[0]: continue
            b = os.read(p.stdout.fileno(), 8192)
            if not b: break
            out.extend(b)
            if len(out) > limit: raise ValueError('reply over limit')
        else:
            raise ValueError('target timed out')
        if p.wait(timeout=1): raise ValueError('target unavailable')
        return out.decode().strip()
    finally:
        try: os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        p.wait()
        p.stdout.close()


def identity(wid):
    if not ID.fullmatch(wid):
        raise ValueError('stable worker identity required')
    script = '''. "$1/fleet-lib.sh"
s=$(fleet_wid_home "$2") || exit 1
w=$(fleet_win_for_addr "${2#*/}" "$s") || exit 1
tmux -L "$s" display-message -p -t "$w" "$3"
'''
    snap = run(['bash', '-c', script, 'upload-target', str(BIN), wid, FMT])
    if len(snap.split('|')) != 10 or snap.endswith('|1'):
        raise ValueError('target not live')
    # A wrapper can resume the same conversation in the same pane. Its direct
    # child changes even when pane_pid and the conversation id do not. Include
    # start times too, so PID reuse cannot accept an old completion.
    pid = snap.split('|')[4]
    processes = run(['ps', '-axo', 'pid=,ppid=,lstart='], limit=1 << 20)
    children = []
    for line in processes.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == pid:
            children.append(parts[0] + ':' + parts[2])
    return snap + '|' + ','.join(sorted(children))


def peer(up, machine, login, words):
    if not re.fullmatch(r'[A-Za-z0-9._-]+', machine) or not re.fullmatch(r'[A-Za-z0-9._-]+', login):
        raise ValueError('invalid peer')
    sock = up.peerlink_sock(machine, login)
    if not os.path.exists(sock):
        raise ValueError('no authenticated peer link')
    ssh = shlex.split(os.environ.get('FLEET_REMOTE_SSH_CMD') or 'ssh')
    # A missing control socket must never open an unrelated fallback connection.
    run(ssh + ['-S', sock, '-O', 'check', machine])
    return ssh + ['-S', sock, '-o', 'ControlMaster=no', '-o', 'ControlPersist=no',
                  '-o', 'ProxyCommand=false', '-o', 'BatchMode=yes', machine,
                  ' '.join(shlex.quote(str(x)) for x in words)]


def target(up, h):
    leases = load('fleet_thin_lease')
    row = leases.rows().get(h.get('view'), {})
    if not h.get('token') or row.get('token') != h['token'] or not h.get('generation'):
        raise ValueError('connection changed')
    if row.get('upload_gen') != h['generation'] or not leases.attached(row):
        raise ValueError('selection changed')
    # A taken lease is immediately unusable even if the tmux detach is pending.
    book = leases.load_book()
    entry = book.get('views', {}).get(h['view'], {})
    if entry.get('state') in ('taken', 'revoked') or entry.get('taken'):
        raise ValueError('client taken over')
    sess = row['sess']
    snap = run([leases.tmux_bin(), '-L', sess, 'display-message', '-p',
                '-t', '=%s@view-%s:' % (sess, h['view']), FMT])
    if snap != row.get('upload_target') or snap.endswith('|1'):
        raise ValueError('pane or agent changed')
    parts = snap.split('|')
    if len(parts) != 10:
        raise ValueError('no pane')
    m, l, wid = h['cur']
    if not ID.fullmatch(wid):
        raise ValueError('stable identity required')
    if parts[2]:
        current = parts[2].removeprefix('wid:')
        route = run([leases.tmux_bin(), '-L', sess, 'display-message', '-p',
                     '-t', '=%s@view-%s:' % (sess, h['view']), '#{@peer}'])
        if current != wid or route != m + '@' + l:
            raise ValueError('peer selection changed')
        dest = run(peer(up, m, l, ['python3', '.claude/fleet/bin/fleet-client-upload.py', 'identity', wid]))
    else:
        if [m, l] != ['-', '-'] or row.get('fuid', '') + '/' + parts[1] != wid:
            raise ValueError('selection changed')
        dest = identity(wid)
    result = {'home': snap, 'destination': dest}
    if h.get('identity') is not None and h['identity'] != result:
        raise ValueError('target replaced')
    return result


def header():
    # Do not buffer past the header: subsequent reads use select on fd 0.
    line = bytearray()
    while len(line) <= 16384:
        if not select.select([0], [], [], 10)[0]:
            raise ValueError('header timeout')
        b = os.read(0, 1)
        if not b: raise ValueError('missing header')
        if b == b'\n': return json.loads(line)
        line.extend(b)
    raise ValueError('header too large')


def receive(up, h, dest):
    size, sha = h.get('size'), h.get('sha256', '')
    name = up.safe(h.get('name') or 'file')
    if not isinstance(size, int) or not 0 <= size <= up.bound(name) or not re.fullmatch('[0-9a-f]{64}', sha):
        raise ValueError('invalid file bounds')
    digest, count = hashlib.sha256(), 0
    while True:
        if not select.select([0], [], [], 10)[0]:
            raise ValueError('upload stalled')
        b = os.read(0, min(1 << 20, size - count + 1))
        if not b: break
        count += len(b)
        if count > size: raise ValueError('upload too large')
        dest.write(b); digest.update(b)
    if count != size or digest.hexdigest() != sha:
        raise ValueError('incomplete upload')
    dest.flush()


def commit(up, h, source):
    wid = h['cur'][2]
    if identity(wid) != h['identity']['destination']:
        raise ValueError('target replaced')
    folder = Path(up.inbox_root()) / wid.split('/')[1]
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(folder, 0o700)
    # Content identity is the retry identity. A failed acknowledgement can only
    # find this same committed object, never overwrite somebody else's upload.
    path = folder / (h['sha256'] + '-' + up.safe(h['name']))
    with open(folder / '.upload-lock', 'a') as lock:
        end = time.monotonic() + 3
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); break
            except BlockingIOError:
                if time.monotonic() >= end: raise ValueError('inbox busy')
                time.sleep(.02)
        # Refuse at capacity; generic failure cleanup never deletes completed files.
        cap = min(1024, max(1, int(os.environ.get('FLEET_INBOX_CAP_MB') or 1024))) << 20
        used = sum(p.stat().st_size for p in folder.parent.glob('*/*') if p.is_file())
        if not path.exists() and used + h['size'] > cap: raise ValueError('inbox full')
        fd, partial = tempfile.mkstemp(prefix='.upload-', suffix='.part', dir=folder)
        try:
            with os.fdopen(fd, 'wb') as dest:
                source.seek(0)
                digest = hashlib.sha256()
                for b in iter(lambda: source.read(1 << 20), b''):
                    dest.write(b); digest.update(b)
                dest.flush(); os.fsync(dest.fileno())
            if os.path.getsize(partial) != h['size'] or digest.hexdigest() != h['sha256'] or identity(wid) != h['identity']['destination']:
                raise ValueError('commit changed')
            os.replace(partial, path)
        finally:
            try: os.unlink(partial)
            except FileNotFoundError: pass
    return {'path': str(path), 'sha256': h['sha256'], 'size': h['size']}


def main(action, up, args):
    def stop(_s, _f): raise ValueError('upload interrupted')
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGALRM): signal.signal(sig, stop)
    signal.alarm(120)
    try:
        if action == 'identity':
            print(identity(args[0])); return 0
        h = header()
        if action == 'target':
            result = target(up, h)
        else:
            if action == 'recv-checked': target(up, h)
            with tempfile.TemporaryFile() as f:
                receive(up, h, f)
                m, l, _ = h['cur']
                if action == 'recv-stage' or (m == '-' and l == '-'):
                    result = commit(up, h, f)
                else:
                    with tempfile.TemporaryFile() as wire:
                        wire.write(json.dumps(h).encode() + b'\n'); f.seek(0)
                        for b in iter(lambda: f.read(1 << 20), b''): wire.write(b)
                        wire.seek(0)
                        result = json.loads(run(peer(up, m, l, ['python3', '.claude/fleet/bin/fleet-client-upload.py', 'recv-stage']), source=wire))
                if action == 'recv-checked': target(up, h)
        print(json.dumps(result)); return 0
    except Exception:
        sys.stderr.write('fleet: attachment target changed, incomplete, unavailable or over limit\n')
        return 1
    finally:
        signal.alarm(0)
