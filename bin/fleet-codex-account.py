#!/usr/bin/env python3
"""Isolated Codex account homes and native quota-based launch selection.

No credentials are copied or read. Quota caches contain only normalized usage
metadata; unavailable/stale data never means exhausted. No model request is made.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).absolute().parent


def root():
    return Path(os.environ.get('FLEET_CONF_DIR', '~/.config/claude-fleet')).expanduser() / 'codex'


def read(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


def home_path(value):
    path = Path(value).expanduser().resolve()
    if not path.is_dir() or any(x in str(path) for x in '\n\r\t'):
        raise ValueError('CODEX_HOME must be an existing directory without control separators')
    return str(path)


def registry():
    return read(root() / 'accounts.json')


def register(label, home):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', label):
        raise ValueError('account label must use 1..64 letters, digits, underscores or hyphens')
    home = home_path(home)
    root().mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root() / 'accounts.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = registry()
        if any(path == home and name != label for name, path in data.items()):
            raise ValueError('this CODEX_HOME already has a label')
        if label in data and data[label] != home:
            raise ValueError('label already names a different CODEX_HOME')
        data[label] = home
        save(root() / 'accounts.json', data)


def cache_path(home):
    return root() / 'quota' / (hashlib.sha256(home.encode()).hexdigest() + '.json')


def fingerprint(home):
    # Relogin/replacement of file-backed auth invalidates the previous reading.
    # The file contents (tokens) are never inspected or serialized.
    try:
        s = (Path(home) / 'auth.json').stat()
        return [s.st_ino, s.st_size, s.st_mtime_ns]
    except OSError:
        return None


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def normalize(response):
    if not isinstance(response, dict) or not isinstance(response.get('rateLimits'), dict):
        raise ValueError('unrecognized native quota response')
    def bucket(value):
        if not isinstance(value, dict): return {}
        result = {k: value[k] for k in ('limitId', 'normalModelSlug', 'planType', 'spendControlReached', 'rateLimitReachedType') if isinstance(value.get(k), (str, bool))}
        for key in ('primary', 'secondary'):
            row = value.get(key)
            if not isinstance(row, dict) or not numeric(row.get('usedPercent')): continue
            result[key] = {k: row[k] for k in ('usedPercent', 'windowDurationMins', 'resetsAt') if numeric(row.get(k))}
        credits = value.get('credits')
        if isinstance(credits, dict):
            result['credits'] = {k: credits[k] for k in ('hasCredits', 'unlimited') if isinstance(credits.get(k), bool)}
        return result
    data = {'rateLimits': bucket(response['rateLimits']), 'rateLimitsByLimitId': {}}
    buckets = response.get('rateLimitsByLimitId') or {}
    if not isinstance(buckets, dict): raise ValueError('unrecognized native quota buckets')
    for key, value in buckets.items():
        data['rateLimitsByLimitId'][key] = bucket(value)
    if isinstance(response.get('ordinaryUsageAllowed'), bool):
        data['ordinaryUsageAllowed'] = response['ordinaryUsageAllowed']
    return data


def native_read(home, timeout=8):
    """One short-lived stdio server; EOF also shuts it down if this reader dies."""
    env = dict(os.environ, CODEX_HOME=home)
    for key in ('CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'FLEET_CODEX_REMOTE'):
        env.pop(key, None)
    p = subprocess.Popen(['codex', 'app-server', '--listen', 'stdio://'], cwd=home, env=env,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    deadline = time.monotonic() + timeout
    pending = b''
    def send(data):
        p.stdin.write((json.dumps(data) + '\n').encode()); p.stdin.flush()
    def call(ident, method, params):
        nonlocal pending
        send({'id': ident, 'method': method, 'params': params})
        while True:
            if b'\n' not in pending:
                left = deadline - time.monotonic()
                if left <= 0 or not select.select([p.stdout], [], [], max(0, left))[0]:
                    raise TimeoutError('native quota read timed out')
                chunk = os.read(p.stdout.fileno(), 65536)
                if not chunk: raise ValueError('native quota server closed')
                pending += chunk
                if len(pending) > 4 * 1024 * 1024: raise ValueError('oversized quota response')
                continue
            line, pending = pending.split(b'\n', 1)
            data = json.loads(line)
            if data.get('id') != ident or 'method' in data: continue
            if 'error' in data: raise ValueError('native quota unavailable: ' + str(data['error'].get('message', 'RPC error')))
            return data.get('result')
    try:
        call(1, 'initialize', {'clientInfo': {'name': 'claude_fleet_quota', 'version': '1'}})
        send({'method': 'initialized'})
        return call(2, 'account/rateLimits/read', {'excludeResetCreditDetails': True})
    finally:
        p.stdin.close()
        try: p.wait(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGTERM)
            try: p.wait(timeout=1)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
        p.stdout.close()


def refresh(home, force=False, timeout=8):
    path = cache_path(home)
    data = read(path)
    now = time.time()
    if not force and data.get('auth') == fingerprint(home) and 0 <= now - data.get('attempt', 0) < 60:
        return data
    # Preserve a still-fresh successful reading across a transient RPC failure.
    data.update(home=home, attempt=now)
    try:
        before = fingerprint(home)
        response = native_read(home, timeout)
        if before != fingerprint(home): raise ValueError('account changed during quota read')
        data = dict(normalize(response), home=home, auth=before, at=time.time(), attempt=now)
    except (OSError, ValueError, subprocess.SubprocessError):
        data['error'] = 'quota unavailable'
    save(path, data)
    return data


def model_limits():
    mapping = json.loads(os.environ.get('FLEET_CODEX_MODEL_LIMIT_IDS') or '{}')
    if not isinstance(mapping, dict) or any(not isinstance(k, str) or not k or not isinstance(v, str) or not v for k, v in mapping.items()):
        raise ValueError('FLEET_CODEX_MODEL_LIMIT_IDS must map model names to native limit IDs')
    return mapping


def status(home, model='', now=None, limit_id=None):
    now = time.time() if now is None else now
    data = read(cache_path(home))
    ttl = max(1, min(3600, int(os.environ.get('FLEET_CODEX_QUOTA_TTL', '300'))))
    result = {'home': home, 'remaining': None, 'state': 'unknown', 'windows': []}
    if (data.get('home') != home or data.get('auth') != fingerprint(home)
            or not 0 <= now - data.get('at', 0) <= ttl): return result
    bucket = data.get('rateLimits', {})
    buckets = [bucket]
    by_id = data.get('rateLimitsByLimitId', {})
    if limit_id is not None:
        buckets = [by_id.get(limit_id, {})]
    elif model:
        # normalModelSlug describes a quota alias's presentation; it does not
        # prove that this bucket meters every use of the normal model.
        key = model_limits().get(model)
        if key: buckets.append(by_id.get(key, {}))
    remaining = []
    expired = False
    for b in buckets:
        # Explicit backend denials are authoritative while the snapshot is fresh.
        if b.get('spendControlReached') is True or b.get('rateLimitReachedType'):
            remaining.append(0)
        for key in ('primary', 'secondary'):
            row = b.get(key, {})
            used, reset = row.get('usedPercent'), row.get('resetsAt')
            if not numeric(used): continue
            if numeric(reset) and reset <= now:
                expired = True
                continue
            remaining.append(max(0, min(100, 100 - used)))
            result['windows'].append(dict(row))
    if data.get('ordinaryUsageAllowed') is False: remaining.append(0)
    if remaining:
        result['remaining'] = min(remaining)
        floor = max(0, min(100, int(os.environ.get('FLEET_CODEX_QUOTA_FLOOR', '5'))))
        result['state'] = 'available' if result['remaining'] > floor else 'low'
        if expired and result['state'] == 'available':
            result.update(remaining=None, state='unknown')
    return result


def candidates(exclude=''):
    accounts = registry()
    labels = os.environ.get('FLEET_CODEX_ACCOUNTS', '').split()
    result = []
    for label in labels:
        if label not in accounts: raise ValueError('unregistered Codex account: ' + label)
        home = home_path(accounts[label])
        if home != exclude:
            result.append(dict(status(home, os.environ.get('FLEET_CODEX_MODEL', '')), label=label))
    return result


def choose(exclude='', require_known=False):
    choices = candidates(exclude)
    known = [x for x in choices if x['state'] == 'available']
    if known: return max(known, key=lambda x: x['remaining'])
    unknown = [x for x in choices if x['state'] == 'unknown']
    if unknown and not require_known:
        current = os.environ.get('CODEX_HOME', '')
        return next((x for x in unknown if x['home'] == current), unknown[0])
    if choices: raise ValueError('no Codex pool account has usable quota' if require_known else 'all Codex pool accounts are below the quota floor')
    return None


def selection():
    if os.environ.get('FLEET_CODEX_HOME'):
        return home_path(os.environ['FLEET_CODEX_HOME'])
    try:
        selected = choose()
    except ValueError:
        if os.environ.get('FLEET_CODEX_QUOTA_GATE') == '1': raise
        choices = candidates()
        if not choices: raise
        selected = max(choices, key=lambda x: x['remaining'] if x['remaining'] is not None else -1)
    return selected['home'] if selected else home_path(os.environ.get('CODEX_HOME', '~/.codex'))


def idle(data):
    rpc = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client'](data.get('remote', ''), timeout=3)
    try:
        thread = rpc.call('thread/read', {'threadId': data['session_id'], 'includeTurns': False})['thread']
        return thread.get('id') == data['session_id'] and thread.get('status', {}).get('type') == 'idle'
    finally:
        rpc.close()


def watch(session):
    if session and os.environ.get('FLEET_CODEX_MODEL_FALLBACK'):
        if runpy.run_path(str(BIN / 'fleet-codex-model.py'))['watch'](session): return
    if os.environ.get('FLEET_CODEX_QUOTA_MIGRATE') != '1' or not session: return
    adapter = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
    rows = adapter['tmux'](['list-windows', '-t', session, '-F',
        '#{pane_id}|#{@claude_state}|#{@cc_agent}|#{@cc_launcher_pid}|#{@codex_identity}'], session)
    for line in rows.splitlines():
        try:
            pane, state, agent, owner, raw = line.split('|', 4)
            if agent != 'codex' or state != 'done': continue
            data = adapter['saved_identity'](raw, owner)
            if not data or status(data['home'])['state'] != 'low': continue
            target = choose(data['home'], require_known=True)
            if not target or not idle(data): continue
            key = hashlib.sha256((session + pane + owner).encode()).hexdigest()
            marker = root() / 'migrations' / (key + '.json')
            if time.time() - read(marker).get('attempt', 0) < 300: continue
            # Exact source is rechecked by the controller after its packet/lease.
            # Launch outside the collector's phase timebox; controller is bounded.
            save(marker, {'attempt': time.time()})
            log = marker.with_suffix('.log'); log.touch(mode=0o600)
            cmd = ['env', 'FLEET_CONF_DIR=' + str(root().parent), 'PATH=' + os.environ['PATH'],
                   'bash', str(BIN / 'fleet-transfer.sh'), '--session', session, '--window', pane,
                   '--to', 'codex', '--codex-home', target['home'], '--require-codex-idle',
                   '--expected-source', pane + ':' + owner + ':' + data['session_id']]
            adapter['tmux'](['run-shell', '-b', shlex.join(cmd) + ' >' + shlex.quote(str(log)) + ' 2>&1'], session)
            return  # At most one migration per fleet per collector tick.
        except (OSError, ValueError, KeyError, EOFError, subprocess.SubprocessError):
            continue


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=('register', 'list', 'refresh', 'select', 'gate', 'label', 'migrate', 'watch', 'idle'))
    p.add_argument('label', nargs='?', default='')
    p.add_argument('home', nargs='?', default='')
    p.add_argument('--budget', type=float, default=15)
    p.add_argument('--session', default='')
    p.add_argument('--window', default='')
    p.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    if a.command == 'watch': watch(a.session); return 0
    if a.command == 'idle':
        adapter = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
        return 0 if idle(adapter['identity'](a.window, a.session)) else 1
    if a.command == 'register': register(a.label, a.home); return 0
    if a.command == 'refresh':
        accounts = registry()
        if a.label and a.label not in accounts: raise ValueError('unregistered account')
        homes = [accounts[a.label]] if a.label else list(dict.fromkeys(accounts.values()))
        homes.sort(key=lambda h: read(cache_path(h)).get('attempt', 0))
        deadline = time.monotonic() + max(1, min(60, a.budget))
        for home in homes:
            left = deadline - time.monotonic() - 2
            if left < 1: break
            refresh(home_path(home), force=bool(a.label), timeout=min(8, left))
        return 0
    if a.command == 'list':
        print(json.dumps([dict(status(h, os.environ.get('FLEET_CODEX_MODEL', '')), label=l) for l, h in registry().items()], indent=2)); return 0
    if a.command == 'label':
        home = home_path(a.label)
        print(next((label for label, h in registry().items() if h == home), '')); return 0
    if a.command == 'select': print(selection()); return 0
    if a.command == 'gate':
        if os.environ.get('FLEET_CODEX_QUOTA_GATE') != '1': return 0
        if os.environ.get('FLEET_CODEX_HOME'):
            if status(home_path(os.environ['FLEET_CODEX_HOME']), os.environ.get('FLEET_CODEX_MODEL', ''))['state'] == 'low':
                print('Codex pinned account is below the quota floor'); return 1
        else:
            try: choose()
            except ValueError as error: print(str(error)); return 1
        return 0
    if a.command == 'migrate':
        if not a.session or not a.window: raise ValueError('migrate requires --session and --window')
        adapter = runpy.run_path(str(BIN / 'fleet-codex-session.py'))
        data = adapter['identity'](a.window, a.session)
        if not data: raise ValueError('no current Codex source identity')
        target = candidates()
        target = next((x for x in target if x['label'] == a.label), None) if a.label else choose(data['home'], require_known=True)
        if not target or target['home'] == data['home'] or target['state'] != 'available':
            raise ValueError('target needs a different home with fresh available quota')
        if not idle(data): raise ValueError('source is not natively idle')
        pane = adapter['tmux'](['display-message', '-p', '-t', a.window, '#{pane_id}'], a.session)
        cmd = ['bash', str(BIN / 'fleet-transfer.sh'), '--session', a.session, '--window', a.window,
               '--to', 'codex', '--codex-home', target['home'], '--require-codex-idle',
               '--expected-source', pane + ':' + data['owner'] + ':' + data['session_id']]
        if a.dry_run: cmd.append('--dry-run')
        return subprocess.call(cmd)
    return 0


if __name__ == '__main__':
    try: sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, EOFError, subprocess.SubprocessError) as error:
        print('fleet-codex-account: ' + str(error), file=sys.stderr)
        sys.exit(2)
