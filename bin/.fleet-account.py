#!/usr/bin/env python3
"""Provider adapters for fleet-account.sh. ccquota owns credentials and readings.

This module only selects locally reachable subscriptions. It never copies login
tokens, changes ccquota's default profile, or treats an unknown reading as zero.
Claude scores/phase/bench come from the existing shell policy owner.
"""
import argparse
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).absolute().parent  # Preserve the selftest shadow install root.


def run(argv, timeout=15, env=None):
    return subprocess.check_output([str(x) for x in argv], env=env, timeout=timeout,
                                   stderr=subprocess.PIPE, text=True).strip()


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def state_dir():
    return Path(os.environ.get('FLEET_C', str(Path(os.environ.get('TMPDIR', '/tmp')) / '.claude-dash'))) / 'global'


@contextmanager
def locked(path, nonblocking=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
        yield


def number(value):
    if isinstance(value, bool):
        return None
    try:
        value = float(value)
        return value if math.isfinite(value) else None
    except (TypeError, ValueError):
        return None


def epoch(value):
    n = number(value)
    if n is not None:
        return int(n)
    try:
        return int(datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp())
    except (AttributeError, TypeError, ValueError):
        return 0


def ccquota(*args):
    env = dict(os.environ)
    # A worker's selected home must not redefine the pool's default profile.
    # Custom homes join the pool through ccquota's existing registry.
    env.pop('CODEX_HOME', None)
    return json.loads(run([os.environ.get('FLEET_QUOTA_BIN', 'ccquota'), *args], env=env))


def profiles():
    rows = ccquota('codex', 'list', '--json')
    if not isinstance(rows, list):
        raise ValueError('ccquota codex list --json is unavailable or has an unknown schema')
    out, homes = [], set()
    for row in rows:
        if not isinstance(row, dict):
            continue
        home, name = row.get('home'), row.get('name')
        if not isinstance(home, str) or not Path(home).is_absolute() or not isinstance(name, str):
            continue
        home = str(Path(home).resolve())
        if home in homes:
            continue
        homes.add(home)
        # Only metadata crosses this boundary. Do not persist the raw response.
        out.append(dict(agent='codex', profile=name, home=home,
                        account=row.get('account', ''), email=row.get('email', ''),
                        plan=row.get('plan', ''), default=row.get('default', False),
                        login=(row.get('login') or {}).get('state', 'unknown')))
    return out


def profile(name='', home='', account=''):
    found = [p for p in profiles() if (not name or p['profile'] == name)
             and (not home or p['home'] == str(Path(home).resolve()))
             and (not account or p['account'] == account)]
    if len(found) != 1:
        raise ValueError('expected one registered Codex profile with the pinned account/home')
    p = found[0]
    if not p['account'] or p['login'] not in ('valid', 'refresh_due') or not Path(p['home']).is_dir():
        raise ValueError('Codex profile needs a verified subscription login: ' + p['profile'])
    return p


def codex_reading(refresh=False):
    path = state_dir() / 'account.codex-quota.json'
    ttl = max(1, min(600, int(os.environ.get('FLEET_ACCOUNT_QUOTA_TTL', '60'))))
    cache = read(path, {})
    if not refresh and 0 <= time.time() - cache.get('fetched_at', 0) < ttl:
        return cache
    with locked(path.with_suffix('.lock')):
        # A failed refresh replaces the old success; failures never extend its life.
        cache = {'fetched_at': time.time(), 'accounts': [], 'reason': ''}
        try:
            data = ccquota('budget', '--source', 'codex', '--account', 'all', '--json', '--timeout', '10s')
            if data.get('source') != 'codex' or not isinstance(data.get('accounts'), list):
                raise ValueError('ccquota budget lacks provider-aware Codex readings')
            cache['accounts'] = data['accounts']
            cache['reason'] = data.get('reason', '')
        except (OSError, ValueError, subprocess.SubprocessError):
            cache['reason'] = 'Codex quota unavailable; check ccquota version, login and hub'
        save(path, cache)
    return cache


def normalize_codex(p, reading, now=None, scope=None):
    now = time.time() if now is None else now
    row = dict(p, key='codex/' + p['account'], available=False, utilization=None,
               score=None, reset_at=0, hold_until=0, limited_until=0, windows=[])
    if not p.get('account') or p.get('login') not in ('valid', 'refresh_due'):
        row['reason'] = 'auth-unavailable'
        return row
    if not reading or reading.get('available') is not True:
        row['reason'] = 'unreadable'
        return row
    windows = []
    for w in reading.get('windows', []):
        if not isinstance(w, dict):
            row['reason'] = 'unreadable-window'
            return row
        if scope is not None and not str(w.get('id','')).startswith(scope + ':'):
            continue
        used = number(w.get('utilization'))
        until = epoch(w.get('resets_at'))
        if until and until <= now:
            continue
        minutes = number(w.get('minutes'))
        if used is None or not 0 <= used <= 100 or (minutes is not None and minutes < 0):
            row['reason'] = 'unreadable-window'
            return row
        windows.append(dict(id=w.get('id', ''), minutes=minutes or None, utilization=used, resets_at=until))
    blocked = reading.get('blocked') is True
    if not windows and not blocked:
        row['reason'] = 'unreadable'
        return row
    used = 100 if blocked else max(w['utilization'] for w in windows)
    ordered = sorted(windows, key=lambda w: w['minutes'] or float('inf'))
    if os.environ.get('FLEET_ACCOUNT_PICK') == 'minmax' or len(ordered) < 2 or any(w['minutes'] is None for w in windows):
        score = (100 - used) * 2
    else:
        score = (100 - ordered[0]['utilization']) * 2 + (100 - max(w['utilization'] for w in ordered[1:]))
    ceiling = float(os.environ.get('FLEET_ACCOUNT_CEILING', '85'))
    blocking = [w['resets_at'] for w in windows if w['utilization'] >= ceiling and w['resets_at'] > now]
    # All constraining windows must reset before this subscription is eligible.
    row.update(available=True, utilization=used, score=score, reset_at=max(blocking, default=0),
               windows=windows, reason='exhausted' if used >= ceiling else 'available')
    return row


def inventory(refresh=False):
    accounts, errors = [], []
    try:
        args = ['bash', BIN / 'fleet-account.sh', '_claude-inventory']
        if refresh:
            args.append('--refresh')
        for line in run(args, timeout=20).splitlines():
            fields = line.split('\t')
            if len(fields) != 10:
                continue
            label, account, used, score, limited, hold, reset, fresh, token, model_ok = fields
            available = fresh == '1' and number(used) is not None
            accounts.append(dict(agent='claude', label=label, account=account or label,
                key='claude/' + (account or label), available=available, utilization=number(used),
                score=number(score), limited_until=int(limited), hold_until=int(hold), reset_at=int(reset),
                login='valid' if token == '1' else 'no_credentials', model_ok=model_ok == '1',
                reason='available' if available else 'unreadable'))
    except (OSError, ValueError, subprocess.SubprocessError):
        errors.append('Claude account inventory unavailable')
    try:
        local = profiles()
        data = codex_reading(refresh)
        readings = {a.get('account_uuid'): a for a in data['accounts'] if isinstance(a, dict)}
        benches = read(state_dir() / 'account.codex-limited.json', {})
        for p in local:
            reading = readings.get(p['account'])
            row = normalize_codex(p, reading, scope='codex')
            row['model_ok'] = True
            mapping = json.loads(os.environ.get('FLEET_CODEX_MODEL_LIMIT_IDS') or '{}')
            if not isinstance(mapping,dict) or any(not isinstance(k,str) or not isinstance(v,str) or not v for k,v in mapping.items()):
                raise ValueError('invalid Codex model limit mapping')
            model = os.environ.get('FLEET_CODEX_MODEL','')
            if model and mapping.get(model):
                model_row = normalize_codex(p,reading,scope=mapping[model])
                row['model_ok'] = model_row['available'] and model_row['utilization'] < float(os.environ.get('FLEET_ACCOUNT_CEILING','85'))
                fallback = os.environ.get('FLEET_CODEX_MODEL_FALLBACK','')
                if not row['model_ok'] and fallback and mapping.get(fallback):
                    alt = normalize_codex(p,reading,scope=mapping[fallback])
                    row['model_ok'] = alt['available'] and alt['utilization'] < float(os.environ.get('FLEET_ACCOUNT_CEILING','85'))
                    if row['model_ok']: row['model'] = fallback
            row['capable'] = os.environ.get('FLEET_CODEX_SERVER', '1') != '0'
            row['limited_until'] = benches.get(row['key'], {}).get('until', 0)
            if not Path(p['home']).is_dir():
                row.update(login='no_home', reason='auth-unavailable')
            accounts.append(row)
        if data.get('reason') and not data['accounts']:
            errors.append(data['reason'])
    except (OSError, ValueError, subprocess.SubprocessError):
        errors.append('Codex profiles unavailable; ccquota codex list --json is required')
    return {'accounts': accounts, 'errors': errors, 'observed_at': time.time()}


def allowed_codex(row):
    """Honor the existing home/label pool; ccquota remains the login registry."""
    labels = os.environ.get('FLEET_CODEX_ACCOUNTS', '').split()
    if not labels:
        return True
    legacy = read(Path(os.environ.get('FLEET_CONF_DIR', str(Path.home()/'.config/claude-fleet'))) / 'codex/accounts.json', {})
    return row.get('profile') in labels or row.get('home') in [legacy.get(label) for label in labels]


def eligible(row, now=None):
    now = time.time() if now is None else now
    return (row.get('available') is True and row.get('login') in ('valid', 'refresh_due')
            and (row.get('agent') != 'codex' or allowed_codex(row))
            and row.get('model_ok', True) and row.get('capable', True) and number(row.get('utilization')) is not None
            and row['utilization'] < float(os.environ.get('FLEET_ACCOUNT_CEILING', '85'))
            and row.get('limited_until', 0) <= now and row.get('score') is not None)


def choose(data, agent, exclude=(), current='', allowed=('claude', 'codex')):
    now = time.time()
    excluded = set(exclude)
    for kind in [agent] + [a for a in allowed if a != agent]:
        if kind not in allowed:
            continue
        candidates = [a for a in data['accounts'] if a['agent'] == kind
                      and a['key'] not in excluded and eligible(a, now)]
        held = [a for a in candidates if a.get('hold_until', 0) <= now]
        candidates = held or candidates  # Existing phase preference is fail-open.
        if not candidates:
            continue
        candidates.sort(key=lambda a: (-a['score'], not a.get('default', False)))
        best = candidates[0]
        for row in candidates:
            if row['key'] == current and best['score'] - row['score'] <= 2 * float(os.environ.get('FLEET_ACCOUNT_PICK_HYST', '10')):
                best = row
                break
        return {'state': 'ready', 'target': best, 'reason': 'same-agent' if kind == agent else 'cross-agent'}
    return {'state': 'waiting-quota', 'target': None, 'reason': 'no locally reachable, readable subscription below ceiling'}


def choose_spawn(data, agent, allowed=('claude', 'codex')):
    result = choose(data, agent, allowed=allowed)
    if result['target'] or any(a.get('available') for a in data['accounts']):
        return result
    # Preserve the old gate's unknown-reading fail-open contract for new work,
    # never for a migration and never across providers on an unknown reading.
    for row in data['accounts']:
        if (row['agent'] == agent and row.get('login') in ('valid','refresh_due')
                and row.get('limited_until',0) <= time.time() and row.get('model_ok',True)
                and row.get('capable',True)):
            if row['agent'] == 'codex' and not allowed_codex(row):
                continue
            return {'state':'ready','target':row,'reason':'quota-unknown-spawn'}
    return result


def check_target(target, quota=True):
    data = inventory(refresh=quota)
    matches = [p for p in data['accounts'] if p['key'] == target.get('key') and p['agent'] == target.get('agent')
               and p.get('label') == target.get('label') and p.get('profile') == target.get('profile')
               and p.get('home') == target.get('home')]
    if len(matches) != 1 or (quota and not eligible(matches[0])):
        raise ValueError('pinned destination is no longer eligible')
    if target['agent'] == 'codex':
        profile(target['profile'], target['home'], target['account'])
    return matches[0]


def verify_codex_runtime(remote, source=None):
    """Verify the locked profile and native auth/config before sending a task."""
    expected = read_subscription()
    if not expected:
        return
    actual = profile(expected['profile'], expected['home'], expected['account'])
    Client = runpy.run_path(str(BIN / 'fleet-codex-rpc.py'))['Client']
    rpc = Client(remote, timeout=5)
    try:
        auth = rpc.call('account/read', {'refreshToken': False})
        account = auth.get('account') or {}
        if source:
            # An existing thread's effective provider is native runtime state.
            # Old servers can lose transient feature-override files, making a
            # fresh config/read fail even while the bound thread keeps working.
            thread = rpc.call('thread/read', {'threadId': source['session_id'], 'includeTurns': False})['thread']
            if (thread.get('id') != source['session_id'] or thread.get('modelProvider') != 'openai'
                    or Path(thread['cwd']).resolve() != Path(source['worktree']).resolve()):
                raise ValueError('existing Codex thread did not confirm the source identity/provider')
            provider = thread['modelProvider']
        else:
            config = rpc.call('config/read', {'includeLayers': False}).get('config', {})
            provider = config.get('model_provider', 'openai')
        if (account.get('type') != 'chatgpt' or not auth.get('requiresOpenaiAuth')
                or provider not in (None, 'openai')
                or not actual.get('email') or (account.get('email') or '').lower() != actual['email'].lower()):
            raise ValueError('private Codex server did not confirm the pinned ChatGPT subscription')
    finally:
        rpc.close()


def read_subscription():
    return json.loads(os.environ.get('FLEET_CODEX_SUBSCRIPTION', '{}'))


def bench(key, until, reason):
    if not key.startswith('codex/') or until <= time.time():
        raise ValueError('Codex bench requires a future reset and an account key')
    path = state_dir() / 'account.codex-limited.json'
    with locked(path.with_suffix('.lock')):
        data = read(path, {})
        data[key] = {'until': until, 'reason': reason}
        save(path, data)


def launch(agent, argv):
    allowed = os.environ.get('FLEET_FAILOVER_AGENTS', 'claude,codex').split(',')
    # Provider-specific flags cannot silently become another CLI's flags.
    if len(argv) > 1 or (argv and argv[0].startswith('-')):
        allowed = [agent]
    result = choose_spawn(inventory(), agent, allowed=allowed)
    if result['target'] is None:
        print('fleet-account: ' + result['reason'], file=sys.stderr)
        return 3
    target = result['target']
    env = dict(os.environ, FLEET_ACCOUNT_TARGET=json.dumps(target), FLEET_ACCOUNT_SELECTED='1')
    if target['agent'] == 'codex':
        env.update(FLEET_CODEX_PROFILE=target['profile'], FLEET_CODEX_ACCOUNT=target['account'],
                   CODEX_HOME=target['home'])
        if target.get('model') and not any(a in ('-m','--model') or a.startswith('--model=') for a in argv):
            argv = ['-m',target['model'],*argv]
    else:
        env['FLEET_ACCOUNT_LABEL'] = target['label']
    os.execve(str(BIN / 'fleet-claude.sh'), [str(BIN / 'fleet-claude.sh'), '--agent', target['agent'], *argv], env)


def main():
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    for name in ('inventory', 'choose'):
        q = sub.add_parser(name)
        q.add_argument('--refresh', action='store_true')
        if name == 'choose':
            q.add_argument('--agent', choices=('claude', 'codex'), required=True)
            q.add_argument('--exclude', action='append', default=[])
            q.add_argument('--current', default='')
            q.add_argument('--allow', default=os.environ.get('FLEET_FAILOVER_AGENTS', 'claude,codex'))
            q.add_argument('--spawn', action='store_true')
    q = sub.add_parser('profile')
    q.add_argument('--name', default=''); q.add_argument('--home', default=''); q.add_argument('--account', default='')
    q = sub.add_parser('check-target'); q.add_argument('path')
    q = sub.add_parser('bench-codex'); q.add_argument('key'); q.add_argument('until', type=int); q.add_argument('reason')
    q = sub.add_parser('launch'); q.add_argument('--agent', choices=('claude', 'codex'), required=True); q.add_argument('argv', nargs=argparse.REMAINDER)
    a = p.parse_args()
    if a.command == 'profile': result = profile(a.name, a.home, a.account)
    elif a.command == 'inventory': result = inventory(a.refresh)
    elif a.command == 'choose':
        data = inventory(a.refresh)
        result = choose_spawn(data,a.agent,a.allow.split(',')) if a.spawn else choose(data,a.agent,a.exclude,a.current,a.allow.split(','))
    elif a.command == 'check-target': result = check_target(read(a.path, {}))
    elif a.command == 'bench-codex': bench(a.key, a.until, a.reason); return 0
    elif a.command == 'launch': return launch(a.agent, a.argv[1:] if a.argv[:1] == ['--'] else a.argv)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # subprocess exceptions may carry command output; never emit it here.
        print('fleet-account: ' + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
