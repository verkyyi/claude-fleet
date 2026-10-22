#!/usr/bin/env python3
"""Exact Codex identity and credential-free transcript transport for fleet-move.

Only the SSH transport currently negotiates this format. Never fall back to a
Claude project directory, a home's newest thread, or another login's credentials.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tarfile
import time
from types import SimpleNamespace

BIN = Path(__file__).resolve().parent
NATIVE = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))
RPC = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
OPTIONS = ('@fleet_id', '@born', '@task', '@task_id', '@origin_wid', '@agent_def',
           '@model', '@effort', '@cc_model', '@reap_policy', '@reported')
LIMIT = 256 * 1024 * 1024


def tm(sock, *args):
    return NATIVE['tmux'](list(args), sock)


def inspect(sock, window, worktree):
    worktree = str(Path(worktree).resolve())
    fields = TRANSFER['thread_source'](SimpleNamespace(pane=window, socket=sock,
                                                       worktree=worktree, exact=True))
    owner, sid, home, transcript, _ = fields
    data = NATIVE['identity'](window, sock)
    client = RPC(data.get('remote', ''), timeout=5)
    try:
        thread = client.call('thread/read', {'threadId': sid, 'includeTurns': True})['thread']
        if thread.get('id') != sid or thread.get('status', {}).get('type') != 'idle':
            raise ValueError('Codex thread is not idle')
        if str(Path(thread['cwd']).resolve()) != worktree:
            raise ValueError('native thread cwd differs from the source worktree')
        queue = client.call('thread/queue/list', {'threadId': sid, 'limit': 1})
        if queue.get('data') != [] or queue.get('nextCursor'):
            raise ValueError('Codex has queued input')
    finally:
        client.close()
    state = tm(sock, 'display-message', '-p', '-t', window, '#{@claude_state}')
    if state not in ('done', 'looping'):
        raise ValueError('source is not at an idle boundary')
    # The existing native background judge includes tools, goals and subagents.
    bg = subprocess.run(['bash', '-c', '. "$1/fleet-lib.sh"; fleet_window_bg_busy "$2" "$3" "" 1',
                         'move-bg', str(BIN), sock, window], capture_output=True, timeout=20)
    if bg.returncode != 1:
        raise ValueError('source has background work or its inventory is unknown')
    snap = runpy.run_path(str(BIN / 'fleet-input.py'))['snapshot'](sock, window, 'codex')
    if snap.get('state') != 'empty':
        raise ValueError('source input is not provably empty')
    metadata = {k: tm(sock, 'show-options', '-wqv', '-t', window, k) for k in OPTIONS}
    return dict(format=1, agent='codex', socket=sock, window=window, owner=owner,
                sid=sid, home=home, transcript=transcript, worktree=worktree,
                turns=len(thread.get('turns') or []), metadata=metadata)


def same_source(record):
    current = inspect(record['socket'], record['window'], record['worktree'])
    for key in ('owner', 'sid', 'home', 'transcript'):
        if current[key] != record[key]:
            raise ValueError('source identity changed: ' + key)
    return current


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False


def stop(record, wait):
    same_source(record)  # last native proof, immediately before the exit
    sock, win = record['socket'], record['window']
    tm(sock, 'set-option', '-p', '-t', win, 'remain-on-exit', 'on')
    tm(sock, 'set-option', '-w', '-t', win, '@reported', '1')
    tm(sock, 'set-option', '-w', '-t', win, '@wrap_quiet', '1')
    env = dict(os.environ, FLEET_ALLOW_SENDKEYS='1')
    # Codex's paste-aware TUI: /exit must be pasted, then submitted separately.
    prefix = ['tmux', '-L', sock, 'send-keys', '-t', win]
    subprocess.run(prefix + ['-l', '\x1b[200~/exit\x1b[201~'], env=env, check=True)
    subprocess.run(prefix + ['Enter'], env=env, check=True)
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if not alive(record['owner']):
            return
        time.sleep(.2)
    raise ValueError('source did not exit; target was not launched, source window retained')


def pack(record, output):
    path = Path(record['transcript'])
    if NATIVE['meta'](path, record['sid']) is None:
        raise ValueError('source rollout does not match the bound Codex UUID')
    data = path.read_bytes()
    if len(data) > LIMIT:
        raise ValueError('Codex rollout exceeds move limit')
    manifest = {k: record[k] for k in ('format', 'agent', 'sid', 'turns', 'metadata')}
    manifest['sha256'] = hashlib.sha256(data).hexdigest()
    with tarfile.open(fileobj=output, mode='w|') as tar:
        for name, raw in [('move.json', json.dumps(manifest).encode()), ('rollout.jsonl', data)]:
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(raw), 0o600
            tar.addfile(info, io.BytesIO(raw))


def unpack(stream, sid, worktree, root=None):
    if not NATIVE['valid_id'](sid):
        raise ValueError('invalid Codex UUID')
    members = {}
    with tarfile.open(fileobj=stream, mode='r|*') as tar:
        for info in tar:
            if (info.name not in ('move.json', 'rollout.jsonl') or info.name in members
                    or not info.isfile() or info.size > LIMIT):
                raise ValueError('invalid Codex move archive member')
            members[info.name] = tar.extractfile(info).read()
    manifest = json.loads(members.get('move.json', b'{}'))
    data = members.get('rollout.jsonl', b'')
    if (manifest.get('format') != 1 or manifest.get('agent') != 'codex'
            or manifest.get('sid') != sid or hashlib.sha256(data).hexdigest() != manifest.get('sha256')):
        raise ValueError('Codex move manifest or digest mismatch')
    lines = data.splitlines(keepends=True)
    header = json.loads(lines[0]) if lines else {}
    if header.get('type') != 'session_meta' or header.get('payload', {}).get('id') != sid:
        raise ValueError('Codex rollout UUID mismatch')
    # Change location metadata only, never conversation content or credentials.
    for i, line in enumerate(lines):
        item = json.loads(line)
        if item.get('type') in ('session_meta', 'turn_context') and 'cwd' in item.get('payload', {}):
            item['payload']['cwd'] = str(Path(worktree).resolve())
            lines[i] = (json.dumps(item, ensure_ascii=False) + '\n').encode()
    root = Path(root or os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet')))
    home = root / 'moves' / 'codex' / sid
    home.mkdir(parents=True, mode=0o700, exist_ok=False)  # refuse a fork/overwrite
    os.chmod(home, 0o700)
    dest = home / 'sessions' / '2000' / '01' / '01'
    dest.mkdir(parents=True, mode=0o700)
    (dest / ('rollout-2000-01-01T00-00-00-' + sid + '.jsonl')).write_bytes(b''.join(lines))
    (home / 'move.json').write_text(json.dumps(manifest))
    return str(home)


def verify(sock, window, sid, home, worktree):
    data = NATIVE['identity'](window, sock)
    if data.get('session_id') != sid or not alive(data.get('owner', 0)):
        raise ValueError('target has not bound the same Codex UUID')
    path, _ = NATIVE['rollout'](data)
    if not path or not Path(path).resolve().is_relative_to(Path(home).resolve()):
        raise ValueError('target did not resume the imported rollout')
    client = RPC(data.get('remote', ''), timeout=5)
    try:
        thread = client.call('thread/read', {'threadId': sid, 'includeTurns': True})['thread']
    finally:
        client.close()
    manifest = json.loads((Path(home) / 'move.json').read_text())
    if (thread.get('id') != sid or str(Path(thread['cwd']).resolve()) != str(Path(worktree).resolve())
            or len(thread.get('turns') or []) < manifest['turns']):
        raise ValueError('target native history or worktree verification failed')
    return data['owner']


def main():
    p = argparse.ArgumentParser()
    p.add_argument('action', choices=('inspect', 'stop', 'pack', 'unpack', 'verify'))
    for key in ('socket', 'window', 'worktree', 'record', 'sid', 'home'):
        p.add_argument('--' + key, default='')
    p.add_argument('--wait', type=int, default=30)
    a = p.parse_args()
    if a.action == 'inspect':
        print(json.dumps(inspect(a.socket, a.window, a.worktree)))
    elif a.action in ('stop', 'pack'):
        record = json.loads(Path(a.record).read_text())
        if a.action == 'stop':
            stop(record, a.wait)
        else:
            pack(record, sys.stdout.buffer)
    elif a.action == 'unpack':
        print(unpack(sys.stdin.buffer, a.sid, a.worktree))
    else:
        print(verify(a.socket, a.window, a.sid, a.home, a.worktree))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, tarfile.TarError) as e:
        print('fleet-move codex: ' + str(e), file=sys.stderr)
        sys.exit(1)
