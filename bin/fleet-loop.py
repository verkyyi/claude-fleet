#!/usr/bin/env python3
"""Fleet-owned recurring wakeups for a transferred Codex CLI session.

Usage: fleet-loop.py status | bind | defer --seconds N [--prompt-file FILE] | stop
       fleet-loop.py from-claude --transcript FILE --output FILE

The transfer's private loop spec opts in to a per-pane Codex app server. The TUI
and scheduler use that same server; no keystrokes, second writer, global daemon,
or guessed rollout is involved. The controller ends when its TUI exits.
"""

import argparse
import base64
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time


def save(path, value):
    path = Path(path)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def spec(value):
    if not isinstance(value, dict):
        raise ValueError('loop spec must be a JSON object')
    prompt = value.get('prompt')
    seconds = value.get('interval_seconds')
    if not isinstance(prompt, str) or not prompt.strip() or len(prompt.encode()) > 65536:
        raise ValueError('loop prompt must contain 1..65536 UTF-8 bytes')
    if type(seconds) is not int or not 30 <= seconds <= 604800:
        raise ValueError('interval_seconds must be an integer in 30..604800')
    due = value.get('next_run_at', time.time() + seconds)
    if not isinstance(due, (int, float)) or not 0 <= due <= time.time() + 604800:
        raise ValueError('next_run_at must be a Unix timestamp within the next seven days')
    # A missing per-turn rearm retains the last chosen cadence. Never replay
    # missed intervals: a late wakeup is one turn, not a catch-up burst.
    return {'prompt': prompt, 'interval_seconds': seconds, 'next_run_at': due}


def tm(r, *args):
    return subprocess.check_output(['tmux', '-L', r['fleet']['session'], *args],
                                   stderr=subprocess.PIPE, timeout=5).decode().strip()


def pane(r, fmt):
    return tm(r, 'display-message', '-p', '-t', r['fleet']['pane_id'], fmt)


def current(r):
    f = r['fleet']
    want = '|'.join([f['session'], f['window_id'], str(r['pane_pid']), 'codex',
                     r['manifest'], r['worktree']])
    got = pane(r, '#{session_name}|#{window_id}|#{pane_pid}|#{@cc_agent}|#{@handoff_manifest}|#{@worktree}')
    if got != want or pane(r, '#{pane_dead}') == '1':
        raise ValueError('pane, agent, worktree or handoff identity changed')
    if r.get('thread_id'):
        identity = json.loads(pane(r, '#{@codex_identity}') or '{}')
        if identity.get('session_id') != r['thread_id']:
            raise ValueError('the TUI switched to another Codex thread')


class Rpc:
    """Bounded WebSocket JSON-RPC over Codex's private Unix control socket.

    Codex 0.154's `app-server proxy` copies raw bytes; it does NOT translate
    JSONL to WebSocket frames. No network listener or third-party package needed.
    """

    def __init__(self, sock):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.buf = b''
        self.seq = 0
        try:
            self.sock.connect(sock)
            key = base64.b64encode(os.urandom(16)).decode()
            self.sock.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                               'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                               'Sec-WebSocket-Key: ' + key + '\r\n\r\n').encode())
            while b'\r\n\r\n' not in self.buf:
                chunk = self.sock.recv(4096)
                if not chunk or len(self.buf) > 16384:
                    raise RuntimeError('invalid Codex WebSocket handshake')
                self.buf += chunk
            header, self.buf = self.buf.split(b'\r\n\r\n', 1)
            lines = header.decode().split('\r\n')
            headers = dict(x.lower().split(':', 1) for x in lines[1:] if ':' in x)
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            # Header names are case-insensitive; the accept value is NOT.
            received = next((x.split(':', 1)[1].strip() for x in lines[1:]
                             if x.lower().startswith('sec-websocket-accept:')), '')
            if ' 101 ' not in lines[0] or received != accept or headers.get('upgrade', '').strip() != 'websocket':
                raise RuntimeError('Codex WebSocket handshake rejected')
            self.call('initialize', {'clientInfo': {'name': 'fleet-loop', 'version': '1'}})
            self.send({'method': 'initialized'})
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.frame(1, json.dumps(value).encode())

    def frame(self, opcode, payload):
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack('!H', n)
        else:
            head += bytes([0x80 | 127]) + struct.pack('!Q', n)
        mask = os.urandom(4)
        self.sock.sendall(head + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(payload)))

    def take(self, count, deadline):
        while len(self.buf) < count:
            self.sock.settimeout(max(0.001, deadline-time.monotonic()))
            chunk = self.sock.recv(min(65536, count-len(self.buf)))
            if not chunk:
                raise RuntimeError('Codex control socket closed')
            self.buf += chunk
        out, self.buf = self.buf[:count], self.buf[count:]
        return out

    def receive(self, deadline):
        message = b''
        while time.monotonic() < deadline:
            a, b = self.take(2, deadline)
            op, size = a & 15, b & 127
            if b & 128 or a & 0x70:
                raise RuntimeError('unexpected Codex WebSocket frame')
            if size == 126: size = struct.unpack('!H', self.take(2, deadline))[0]
            elif size == 127: size = struct.unpack('!Q', self.take(8, deadline))[0]
            if size + len(message) > 4 * 1024 * 1024:
                raise RuntimeError('Codex control response too large')
            payload = self.take(size, deadline)
            if op == 8: raise RuntimeError('Codex closed the WebSocket')
            if op == 9:
                self.frame(10, payload)
                continue
            if op == 10: continue
            if op not in (0, 1): raise RuntimeError('expected Codex JSON text frame')
            message += payload
            if a & 0x80: return json.loads(message)
        raise TimeoutError('Codex control response timed out')

    def call(self, method, params):
        self.seq += 1
        self.send({'id': self.seq, 'method': method, 'params': params})
        end = time.monotonic() + 10
        while time.monotonic() < end:
            obj = self.receive(end)
            if obj.get('id') != self.seq:
                continue
            if 'error' in obj:
                raise RuntimeError(str(obj['error']))
            return obj['result']
        raise TimeoutError('Codex control request timed out: ' + method)

    def close(self):
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


@contextmanager
def locked(path, nonblocking=False):
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
        yield json.loads(path.read_text())


def record_path():
    value = os.environ.get('FLEET_LOOP_RECORD', '')
    if not value:
        raise ValueError('run this command inside the transferred loop session')
    return Path(value)


def thread(r, rpc):
    t = rpc.call('thread/read', {'threadId': r['thread_id'], 'includeTurns': False})['thread']
    if t['id'] != r['thread_id'] or Path(t['cwd']).resolve() != Path(r['worktree']).resolve():
        raise ValueError('Codex thread identity or working directory changed')
    if t.get('parentThreadId'):
        raise ValueError('a subagent cannot own the pane loop')
    return t


def command(a):
    path = record_path()
    with locked(path) as r:
        if a.command == 'status':
            print(json.dumps(r, ensure_ascii=False, indent=2))
            return
        current(r)
        sid = os.environ.get('CODEX_THREAD_ID', '')
        if not re.fullmatch(r'[0-9a-fA-F-]{36}', sid):
            raise ValueError('CODEX_THREAD_ID is required; never guess the latest rollout')
        if r.get('thread_id') and r['thread_id'] != sid:
            raise ValueError('this is not the loop owner thread')
        if a.command != 'bind' and r.get('thread_id') != sid:
            raise ValueError('bind the owning thread before changing its loop')
        if a.command == 'bind':
            r['thread_id'] = sid
            with Rpc(r['socket']) as rpc:
                thread(r, rpc)
            if r['status'] == 'unbound':
                r['status'] = 'active'
            elif r['status'] != 'active':
                raise ValueError('stopped/paused loop needs explicit operator recovery')
            tm(r, 'set-option', '-w', '-t', r['fleet']['window_id'], '@codex_thread_id', sid)
        elif a.command == 'defer':
            if r['status'] != 'active':
                raise ValueError('loop is not active; bind it first')
            update = dict(r['schedule'], interval_seconds=a.seconds,
                          next_run_at=time.time() + a.seconds)
            if a.prompt_file:
                update['prompt'] = Path(a.prompt_file).read_text()
            r['schedule'] = spec(update)
        elif a.command == 'stop':
            r['status'] = 'stopped'
            r['detail'] = 'Stopped by owner thread'
        save(path, r)
        print(json.dumps({'id': r['id'], 'status': r['status'],
                          'thread_id': r.get('thread_id'),
                          'next_run_at': r['schedule']['next_run_at']}, ensure_ascii=False))


def dispatch(path, now=None):
    now = time.time() if now is None else now
    try:
        with locked(path, nonblocking=True) as r:
            if r['status'] != 'active' or now < r['schedule']['next_run_at']:
                return
            try:
                current(r)
                # Wait behind a real turn, an operator dialog, or recent typing.
                if (pane(r, '#{@claude_state}') != 'done'
                        or pane(r, '#{@agent_transfer_request}')
                        or pane(r, '#{@handoff_armed}') == '1'):
                    return
                for line in tm(r, 'list-clients', '-F', '#{client_activity}|#{window_id}').splitlines():
                    activity, win = line.split('|', 1)
                    if win == r['fleet']['window_id'] and now - int(activity) <= 30:
                        return
                with Rpc(r['socket']) as rpc:
                    t = thread(r, rpc)
                    if t['status']['type'] == 'active':
                        return
                    if t['status']['type'] != 'idle':
                        raise ValueError('Codex thread is no longer loaded and idle')
                    # Persist BEFORE sending. A crash/timeout after sending is
                    # ambiguous and must never cause an automatic duplicate.
                    r['status'] = 'delivering'
                    r['detail'] = 'Delivery in progress; ambiguous failures require inspection'
                    save(path, r)
                    prompt = (r['schedule']['prompt'] + '\n\n[Fleet loop wakeup ' + r['id'] + ']\n'
                              'Continue in the existing conversation language. At the end of this iteration, '
                              'use fleet-loop.py defer --seconds N to choose the next delay (optionally '
                              '--prompt-file FILE for updated context), or fleet-loop.py stop if complete, '
                              'cancelled, or ALL remaining work requires a human decision. A blocked '
                              'item must not stop other authorized monitoring responsibilities. The script is at ' +
                              str(Path(__file__).absolute()) + '. Do not recreate a Claude /loop. '
                              'Do not repeat completed work or override pending approvals. Without a change, '
                              'Fleet retains the last interval; missed intervals are never replayed.')
                    result = rpc.call('turn/start', {'threadId': r['thread_id'],
                                                    'input': [{'type': 'text', 'text': prompt}]})
                    r['last_turn_id'] = result['turn']['id']
                r['status'] = 'active'
                r['last_delivered_at'] = now
                r['deliveries'] += 1
                r['schedule']['next_run_at'] = now + r['schedule']['interval_seconds']
                r['detail'] = 'Wakeup accepted by the bound Codex thread'
            except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
                r['status'] = 'paused'
                r['detail'] = str(error)
            save(path, r)
    except BlockingIOError:
        pass


def bridge(args):
    manifest = Path(os.environ['FLEET_HANDOFF_MANIFEST']).resolve()
    m = json.loads(manifest.read_text())
    if Path(os.environ['FLEET_LOOP_SPEC']).resolve() != Path(m['loop_spec_path']).resolve():
        raise ValueError('loop spec must belong to this transfer manifest')
    try:
        os.kill(m['source']['pid'], 0)
    except ProcessLookupError:
        pass
    else:
        raise ValueError('source process must have exited before enabling the Codex loop')
    schedule = spec(json.loads(Path(os.environ['FLEET_LOOP_SPEC']).read_text()))
    ident = hashlib.sha256(str(manifest).encode()).hexdigest()[:20]
    directory = manifest.parent / 'loop'
    directory.mkdir(mode=0o700)  # No accidental restart/duplicate controller.
    path = directory / 'state.json'
    runtime = Path(tempfile.mkdtemp(prefix='fleet-loop-', dir='/tmp'))
    sock = runtime / 'api.sock'  # Well below macOS's Unix socket path limit.
    r = {'schema_version': 1, 'id': ident, 'status': 'unbound', 'manifest': str(manifest),
         'fleet': m['fleet'], 'source': m['source'], 'worktree': m['workspace']['path'],
         'schedule': schedule, 'socket': str(sock), 'thread_id': None, 'deliveries': 0,
         'controller_pid': os.getpid()}
    r['pane_pid'] = int(pane(r, '#{pane_pid}'))
    current(r)
    save(path, r)
    env = dict(os.environ, FLEET_LOOP_RECORD=str(path), FLEET_CODEX_REMOTE='unix://' + str(sock))
    env.pop('CODEX_THREAD_ID', None)
    env.pop('CODEX_SESSION_ID', None)
    overrides = []
    for i, arg in enumerate(args[:-1]):
        if arg == '-c':
            overrides.extend(['-c', args[i+1]])
    # The app server owns all tools in THIS pane, so it inherits THIS fleet's
    # TMUX/FLEET environment. It is private, never shared across fleet sockets.
    server = client = None
    try:
        with (directory / 'server.log').open('ab') as log:
            server = subprocess.Popen(['codex', 'app-server', '--listen', 'unix://' + str(sock), *overrides],
                                      env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        end = time.monotonic() + 15
        while not sock.exists() and server.poll() is None and time.monotonic() < end:
            time.sleep(0.1)
        if not sock.exists():
            raise RuntimeError('Codex loop server did not start; inspect ' + str(directory / 'server.log'))
        client = subprocess.Popen(['codex', '--remote', 'unix://' + str(sock), *args], env=env)
        while client.poll() is None:
            if server.poll() is not None:
                raise RuntimeError('Codex loop server exited')
            dispatch(path)
            time.sleep(1)
        return client.returncode
    finally:
        # These are children created here, never another pane/server. The TUI
        # ending also ends its scheduler and provider runtime.
        with locked(path) as final:
            final['status'] = 'stopped'
            final['detail'] = 'Codex TUI/controller ended; no automatic restart'
            save(path, final)
        for child in (client, server):
            if child and child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        sock.unlink(missing_ok=True)
        runtime.rmdir()


def from_claude(a):
    calls = {}
    last = None
    scheduled_at = None
    with Path(a.transcript).open() as history:
        for line in history:
            row = json.loads(line)
            if row.get('isSidechain'):
                continue
            content = row.get('message', {}).get('content', [])
            for b in content if isinstance(content, list) else []:
                if not isinstance(b, dict):
                    continue
                if b.get('type') == 'tool_use' and b.get('name') == 'ScheduleWakeup':
                    calls[b['id']] = (b['input'], row.get('timestamp'))
                if b.get('type') == 'tool_result' and b.get('tool_use_id') in calls and not b.get('is_error'):
                    last, scheduled_at = calls[b['tool_use_id']]
    if not last or last.get('stop') or not last.get('prompt'):
        raise ValueError('no successful self-paced ScheduleWakeup to import; inspect the source')
    value = {'prompt': last['prompt'], 'interval_seconds': last['delaySeconds']}
    if scheduled_at:
        value['next_run_at'] = datetime.datetime.fromisoformat(scheduled_at.replace('Z', '+00:00')).timestamp() + last['delaySeconds']
    value = spec(value)
    save(Path(a.output), value)
    print('Saved last successful self-paced loop. Verify it is still intended before passing --loop: ' + a.output)


def main():
    os.umask(0o077)
    if len(sys.argv) > 2 and sys.argv[1:3] == ['bridge', '--']:
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, lambda *_: sys.exit(128))
        return bridge(sys.argv[3:])
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    for name in ('bind', 'status', 'stop'):
        sub.add_parser(name)
    d = sub.add_parser('defer')
    d.add_argument('--seconds', type=int, required=True)
    d.add_argument('--prompt-file')
    c = sub.add_parser('from-claude')
    c.add_argument('--transcript', required=True)
    c.add_argument('--output', required=True)
    a = p.parse_args()
    if a.command == 'from-claude':
        from_claude(a)
    else:
        command(a)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print('fleet-loop: ' + str(error), file=sys.stderr)
        sys.exit(1)
