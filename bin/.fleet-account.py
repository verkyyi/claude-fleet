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
        # `source` is who refreshes the login (issue #1666): 'hub' = a
        # hub-leased home the node agent renews (refresh_token is the hub
        # placeholder; nothing local ever refreshes it), 'local' = this
        # machine's Codex CLI. An older ccquota prints no source: local.
        login = row.get('login') or {}
        out.append(dict(agent='codex', profile=name, home=home,
                        account=row.get('account', ''), email=row.get('email', ''),
                        plan=row.get('plan', ''), default=row.get('default', False),
                        login=login.get('state', 'unknown'),
                        source=login.get('source') or 'local',
                        # ccquota's own words for a login that is not usable
                        # (claude-fleet#1404): "reauth_required" alone sends the
                        # operator looking; the reason says what to do.
                        login_reason=str(login.get('reason') or '')))
    # The ONE judge of a login's validity (EPIC #1665) also leaves the record
    # the status bar reads; a failed stamp never fails the read it rode on.
    try:
        stamp_reauth(out)
    except OSError:
        pass
    return out


# The one line that fixes a dead credential, per agent — the operator's words
# (EPIC #1665): Codex re-authenticates with the device flow, Claude mints a
# setup token to import again.
REAUTH_COMMAND = {'codex': 'codex login --device-auth', 'claude': 'claude setup-token'}


def stamp_reauth(local):
    """Record which profiles need a PERSON to sign in again, for
    bin/fleet-alerts.sh (issue #1469, EPIC #1665 C2): `account.reauth` in the
    account state dir — a header `<epoch>\tchecked`, then one row
    `<since>\t<agent>\t<profile>\t<account>\t<state>\t<command>` per profile
    whose login is reauth_required. `since` carries over while the key stands,
    so the ▲ row keeps its first-seen time across stamps. Written on every
    profiles() read (a launch, a failover, the bar's `logins` refresh), so the
    bar never judges a login itself."""
    path = state_dir() / 'account.reauth'
    old = {}
    try:
        for line in path.read_text().splitlines()[1:]:
            parts = line.split('\t')
            if len(parts) >= 6 and parts[0].isdigit():
                old[(parts[1], parts[2])] = parts[0]
    except OSError:
        pass
    now = int(time.time())
    rows = ['%d\tchecked' % now]
    for p in local:
        if p.get('login') != 'reauth_required':
            continue
        clean = lambda v: str(v or '').replace('\t', ' ').replace('\n', ' ')
        key = (p['agent'], p['profile'])
        rows.append('\t'.join([old.get(key, str(now)), clean(p['agent']), clean(p['profile']),
                               clean(p.get('email') or p.get('account')), 'reauth_required',
                               REAUTH_COMMAND.get(p['agent'], 'sign in again')]))
    # A Claude label marked by `fleet-account.sh mark-reauth` (#1667) is the same
    # fact for the bar: one row, its own first-seen time, the Claude fix.
    for label, mark in sorted(claude_marks().items()):
        clean = lambda v: str(v or '').replace('\t', ' ').replace('\n', ' ')
        rows.append('\t'.join([str(mark['since'] or now), 'claude', clean(label), clean(label),
                               'reauth_required', REAUTH_COMMAND['claude']]))
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write('\n'.join(rows) + '\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def logins():
    """`logins`: every profile's login state, metadata only — and, through
    profiles(), the account.reauth stamp fleet-alerts.sh draws from."""
    return [dict(agent=p['agent'], profile=p['profile'], account=p.get('email') or p.get('account') or '',
                 login=p['login']) for p in profiles()]


def profile(name='', home='', account=''):
    found = [p for p in profiles() if (not name or p['profile'] == name)
             and (not home or p['home'] == str(Path(home).resolve()))
             and (not account or p['account'] == account)]
    if len(found) != 1:
        raise ValueError('expected one registered Codex profile with the pinned account/home')
    p = found[0]
    if not p['account'] or p['login'] not in LOGIN_OK or not Path(p['home']).is_dir():
        if p.get('source') == 'hub' and p['login'] == 'access_rejected':
            # The upstream refused the lease itself (claude-fleet#1920): the
            # node agent cannot renew its way out of a revoked grant.
            raise ValueError('hub-managed Codex profile %s: the upstream refused its lease (%s); '
                             'the hub must issue a new one — a re-login here does not fix it'
                             % (p['profile'], p.get('login_reason') or 'access_rejected'))
        if p.get('source') == 'hub':
            # The hub refreshes this one; a re-login here would not fix it —
            # and ccquota's reason, when it has one, says what did happen.
            raise ValueError('hub-managed Codex profile %s has no valid lease (login=%s): the node agent renews it, '
                             'check `ccquota agent` / CCQUOTA_FLEET_CREDS=1 on this machine'
                             % (p['profile'], p['login'] + (' — ' + p['login_reason'] if p.get('login_reason') else '')))
        raise ValueError('Codex profile needs a verified subscription login: %s (%s)' % (p['profile'], login_trouble(p)))
    return p


def login_trouble(p):
    """Why this Codex profile cannot be used, in ccquota's words when it has them."""
    if not p.get('account'):
        return 'no account on the login'
    if p.get('login') not in LOGIN_OK:
        why = p.get('login') or 'unknown'
        return why + (' — ' + p['login_reason'] if p.get('login_reason') else '')
    if not Path(p['home']).is_dir():
        return 'Codex home missing: ' + p['home']
    return ''


# --- the target's LOGIN, judged in ONE place (issue #1667, EPIC #1665 C3) ----------
# «Can this account START an agent?» is a different question from «does it have
# quota?», and until #1667 only the quota half was asked before a switch: a Codex
# profile ccquota had marked reauth_required at 23:46Z was still handed a session
# at 09:10Z the next morning — the source /exit'ed, Codex came up on a login
# prompt, and the conversation was gone. profile() above is the Codex judge;
# claude_login() / claude_profile() are its Claude-side twins; target_auth() is the
# one entry every switch asks BEFORE it stops a source (fleet-transfer.sh,
# fleet-migrate.sh; the failover planner through check_target). Nothing here reads
# a token further than «is there one», and nothing prints one.
LOGIN_OK = ('valid', 'refresh_due')


def claude_accounts_dir():
    conf = os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))
    return Path(os.environ.get('FLEET_ACCOUNTS_DIR') or Path(conf) / 'accounts')


def claude_reauth(label):
    """The `fleet-account.sh mark-reauth` marker for one label, or None. A bench
    (account.limited) clears itself at a reset; this does not — only
    `clear-reauth` after a new login (EPIC #1665 C5 runs that)."""
    return claude_marks().get(label)


def claude_marks():
    """Every `mark-reauth` row: account.claude-reauth, `label<TAB>since<TAB>reason`
    — its OWN file, because account.reauth (C2, #1469) is a STAMP rewritten on
    every profiles() read; stamp_reauth() folds these rows into it so the bar's
    `▲ accounts · reauth` names a marked Claude label the same way."""
    marks = {}
    try:
        for line in (state_dir() / 'account.claude-reauth').read_text().splitlines():
            fields = line.split('\t')
            if fields and fields[0]:
                since = fields[1] if len(fields) > 1 and fields[1].isdigit() else '0'
                marks[fields[0]] = dict(since=int(since), reason=fields[2] if len(fields) > 2 else '')
    except OSError:
        pass
    return marks


def claude_login(label, now=None):
    """'valid' | 'reauth_required' | 'expired' | 'no_credentials' for one pool label.
    A plain token file (`claude setup-token`): readable, first line non-empty. A
    hub-managed `hub:<label>` (#1415): the agent-renewed .credentials.json beside
    it, unexpired — the launcher points Claude at that file, so an expired one
    starts a session that cannot speak. Either kind: not marked by mark-reauth."""
    now = time.time() if now is None else now
    if not label or '/' in label or label.startswith('.'):
        return 'no_credentials'
    if claude_reauth(label):
        return 'reauth_required'
    try:
        lines = (claude_accounts_dir() / label).read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return 'no_credentials'
    token = lines[0].strip() if lines else ''
    if not token:
        return 'no_credentials'
    if not token.startswith('hub:'):
        return 'valid'
    hub_label = token[4:] or label
    creds = None
    for name in (label, hub_label):
        creds = read(claude_accounts_dir() / (name + '.hub') / '.credentials.json')
        if isinstance(creds, dict):
            break
    if not isinstance(creds, dict):
        return 'no_credentials'
    oauth = creds.get('claudeAiOauth') if isinstance(creds.get('claudeAiOauth'), dict) else creds
    if not oauth.get('accessToken'):
        return 'no_credentials'
    expires = number(oauth.get('expiresAt'))
    if expires is not None and expires / 1000.0 <= now:
        return 'expired'
    return 'valid'


def claude_profile(label=''):
    """profile() for Claude: the pool label a launch would run on (given, else
    FLEET_ACCOUNT_LABEL, else the active account), or ValueError. An empty label
    with multi-account off is not a profile at all — raise, the caller decides."""
    label = label or os.environ.get('FLEET_ACCOUNT_LABEL', '')
    if not label:
        label = run(['bash', BIN / 'fleet-account.sh', 'active'])
    if not label:
        raise ValueError('multi-account is off; no Claude pool account to verify')
    login = claude_login(label)
    if login not in LOGIN_OK:
        raise ValueError('target-auth: Claude account %s needs a new login (%s)' % (label, login))
    return dict(agent='claude', label=label, key='claude/' + label, login=login)


def target_auth(agent, label='', profile_name='', home='', account=''):
    """verdict `ok` | `refuse` | `unknown`, with key / login / reason. `refuse` is the
    only answer that stops a switch. `unknown` = there is no registry to ask (no
    ccquota, multi-account off, an unregistered Codex home on an install without
    the failover planner) and the launch behaves exactly as it always did. The
    Codex side mirrors fleet-codex.sh's own home resolution — FLEET_CODEX_HOME,
    else a FLEET_CODEX_ACCOUNTS pool pick, else ~/.codex — so the verdict is
    about the profile the launch would actually run."""
    if agent == 'claude':
        label = label or os.environ.get('FLEET_ACCOUNT_LABEL', '')
        if not label:
            try:
                label = run(['bash', BIN / 'fleet-account.sh', 'active'])
            except (OSError, subprocess.SubprocessError):
                label = ''
        if not label:
            return dict(verdict='unknown', agent=agent, key='', login='unknown',
                        reason='multi-account off; the ambient Claude login runs the target')
        login = claude_login(label)
        row = dict(agent=agent, key='claude/' + label, label=label, login=login)
        if login in LOGIN_OK:
            return dict(row, verdict='ok', reason='')
        return dict(row, verdict='refuse', reason='Claude account %s needs a new login (%s)' % (label, login))
    try:
        rows = profiles()
    except (OSError, ValueError, subprocess.SubprocessError):
        return dict(verdict='unknown', agent=agent, key='', login='unknown',
                    reason='no ccquota Codex profile registry here; the login cannot be verified')
    if not (profile_name or home or account):
        home = os.environ.get('FLEET_CODEX_HOME', '')
        if not home and os.environ.get('FLEET_CODEX_ACCOUNTS'):
            pool = [p for p in rows if allowed_codex(p)]
            good = [p for p in pool if p['login'] in LOGIN_OK and Path(p['home']).is_dir()]
            if good:
                p = good[0]
                return dict(agent=agent, key='codex/' + p['account'], profile=p['profile'], home=p['home'],
                            login=p['login'], verdict='ok', reason='')
            states = ', '.join(sorted(set(p['login'] for p in pool))) or 'none registered'
            return dict(verdict='refuse', agent=agent, key='', login=states,
                        reason='no Codex profile in the pool can log in (%s)' % states)
        home = home or str(Path.home() / '.codex')
    found = [p for p in rows if (not profile_name or p['profile'] == profile_name)
             and (not home or p['home'] == str(Path(home).resolve()))
             and (not account or p['account'] == account)]
    if len(found) != 1:
        what = profile_name or account or home
        if os.environ.get('FLEET_FAILOVER', '0') == '1':
            # fleet-codex.sh asks profile() for this home under the planner and exits 1
            return dict(verdict='refuse', agent=agent, key='', login='unknown',
                        reason='no registered Codex profile for %s; the launcher would refuse' % what)
        return dict(verdict='unknown', agent=agent, key='', login='unknown',
                    reason='no registered Codex profile for %s' % what)
    p = found[0]
    row = dict(agent=agent, key='codex/' + p['account'], profile=p['profile'], home=p['home'], login=p['login'])
    try:
        profile(p['profile'], p['home'], p['account'])
    except ValueError as error:
        # profile()'s own words (C7, #1404): ccquota's reason when it has one, and
        # a hub-managed lease names the agent, not a login, as the fix
        login = 'no_home' if not Path(p['home']).is_dir() else p['login']
        return dict(row, login=login, verdict='refuse', reason=str(error))
    return dict(row, verdict='ok', reason='')


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


def ceiling():
    return float(os.environ.get('FLEET_ACCOUNT_CEILING', '85'))


def pace_of(used, resets_at, minutes, now=None):
    """The weekly PACE (issue #1231), the shell's pace_of for a Codex window:
    used − ceiling × elapsed, elapsed = 1 − (resets_at − now) / window, clamped
    to [0, 1]; integer, rounded half away from zero. No reset or no length ⇒ 0."""
    now = time.time() if now is None else now
    if not resets_at or not minutes or minutes <= 0:
        return 0
    elapsed = min(1.0, max(0.0, 1 - (resets_at - now) / (minutes * 60.0)))
    p = used - ceiling() * elapsed
    return -int(-p + 0.5) if p < 0 else int(p + 0.5)


def pace_weight():
    try:
        lead = int(os.environ.get('FLEET_ACCOUNT_PACE_LEAD', '10'))
    except ValueError:
        lead = 10
    return 2 * 100 // (lead if lead > 0 else 10)


def pace_held(used_week, pace):
    """The shell's pace_held: more than FLEET_ACCOUNT_PACE_HOLD ahead, or the
    weekly window within FLEET_ACCOUNT_PACE_MARGIN of the ceiling."""
    if os.environ.get('FLEET_ACCOUNT_PICK', 'pace') != 'pace':
        return False
    hold = number(os.environ.get('FLEET_ACCOUNT_PACE_HOLD', '25')) or 25
    margin = number(os.environ.get('FLEET_ACCOUNT_PACE_MARGIN', '5')) or 5
    return used_week >= ceiling() - margin or pace > hold


def normalize_codex(p, reading, now=None, scope=None):
    now = time.time() if now is None else now
    row = dict(p, key='codex/' + p['account'], available=False, utilization=None,
               score=None, reset_at=0, hold_until=0, limited_until=0, windows=[],
               login_reason=p.get('login_reason', ''))
    if not p.get('account') or p.get('login') not in LOGIN_OK:
        row['reason'] = 'hub-lease-lapsed' if p.get('source') == 'hub' else 'auth-unavailable'
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
    mode = os.environ.get('FLEET_ACCOUNT_PICK', 'pace')
    pace, held = 0, False
    if mode == 'minmax' or len(ordered) < 2 or any(w['minutes'] is None for w in windows):
        score = (100 - used) * 2
    elif mode == '5h':
        score = (100 - ordered[0]['utilization']) * 2 + (100 - max(w['utilization'] for w in ordered[1:]))
    else:
        # The same pace ranking as fleet-account.sh pick_score (issue #1231): the
        # shortest window is the expiring one, the longest is the week.
        week = ordered[-1]
        pace = pace_of(week['utilization'], week['resets_at'], week['minutes'], now)
        held = pace_held(week['utilization'], pace)
        score = (100 - ordered[0]['utilization']) * 2 + (100 - pace) * pace_weight()
    blocking = [w['resets_at'] for w in windows if w['utilization'] >= ceiling() and w['resets_at'] > now]
    # All constraining windows must reset before this subscription is eligible.
    row.update(available=True, utilization=used, score=score, reset_at=max(blocking, default=0),
               windows=windows, pace=pace, pace_held=held,
               reason='exhausted' if used >= ceiling() else 'available')
    return row


def inventory(refresh=False):
    accounts, errors = [], []
    try:
        args = ['bash', BIN / 'fleet-account.sh', '_claude-inventory']
        if refresh:
            args.append('--refresh')
        for line in run(args, timeout=20).splitlines():
            fields = line.split('\t')
            if len(fields) not in (10, 11, 13):
                continue
            label, account, used, score, limited, hold, reset, fresh, token, model_ok = fields[:10]
            # Field 11 (issue #1073): FLEET_MODEL itself has headroom here, not
            # just its fallback. Absent = the pre-#1073 row = no preference.
            primary = fields[10] != '0' if len(fields) > 10 else True
            # Fields 12–13 (issue #1231): the weekly pace and whether it holds the
            # account for new spawns. Absent = the pre-#1231 row = no hold.
            pace = number(fields[11]) if len(fields) > 12 else None
            pheld = fields[12] == '1' if len(fields) > 12 else False
            available = fresh == '1' and number(used) is not None
            # the login the launch would meet (issue #1667): the shell row already
            # read the token file (token=1); this layers the reauth mark and a hub
            # token's expiry on it. A file python cannot see while the shell could
            # (a sandboxed dir) is the shell's answer, never a refusal.
            login = 'no_credentials'
            if token == '1':
                login = claude_login(label)
                if login == 'no_credentials':
                    login = 'valid'
            accounts.append(dict(agent='claude', label=label, account=account or label,
                key='claude/' + (account or label), available=available, utilization=number(used),
                score=number(score), limited_until=int(limited), hold_until=int(hold), reset_at=int(reset),
                login=login, model_ok=model_ok == '1',
                model_primary=primary, pace=0 if pace is None else int(pace), pace_held=pheld,
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
                row.update(login='no_home', reason='auth-unavailable', login_reason='Codex home missing: ' + p['home'])
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
    return (row.get('available') is True and row.get('login') in LOGIN_OK
            and (row.get('agent') != 'codex' or allowed_codex(row))
            and row.get('model_ok', True) and row.get('capable', True) and number(row.get('utilization')) is not None
            and row['utilization'] < float(os.environ.get('FLEET_ACCOUNT_CEILING', '85'))
            and row.get('limited_until', 0) <= now and row.get('score') is not None)


def auth_excluded(data, allowed=('claude', 'codex')):
    """Every account an automatic pick skips for its LOGIN (issue #1670): one row
    each, reason `auth:<state>` — what `choose` returns beside its decision and
    what `failover-status` lists, so a waiting session says WHICH login to fix."""
    return [dict(state='excluded', agent=a.get('agent'), key=a.get('key'),
                 label=a.get('label') or a.get('profile') or '',
                 reason='auth:' + (a.get('login') or 'unknown'), detail=a.get('login_reason') or '')
            for a in data.get('accounts', []) if a.get('agent') in allowed and a.get('login') not in LOGIN_OK]


def choose(data, agent, exclude=(), current='', allowed=('claude', 'codex')):
    result = _choose(data, agent, exclude, current, allowed)
    result['excluded'] = auth_excluded(data, allowed)
    return result


def _choose(data, agent, exclude=(), current='', allowed=('claude', 'codex')):
    now = time.time()
    excluded = set(exclude)
    for kind in [agent] + [a for a in allowed if a != agent]:
        if kind not in allowed:
            continue
        candidates = [a for a in data['accounts'] if a['agent'] == kind
                      and a['key'] not in excluded and eligible(a, now)]
        held = [a for a in candidates if a.get('hold_until', 0) <= now]
        candidates = held or candidates  # Existing phase preference is fail-open.
        # A pace hold (issue #1231) is fail-open the same way, and outlasts the
        # phase preference: it guards a week, the slot guards a 5h window.
        paced = [a for a in candidates if not a.get('pace_held', False)]
        candidates = paced or candidates
        if not candidates:
            continue
        # An account that runs the fleet's model beats one that only has its
        # fallback (issue #1073); hysteresis never keeps a fallback-only current.
        candidates.sort(key=lambda a: (not a.get('model_primary', True), -a['score'], not a.get('default', False)))
        best = candidates[0]
        for row in candidates:
            if row.get('model_primary', True) != best.get('model_primary', True):
                continue
            if row['key'] == current and best['score'] - row['score'] <= 2 * float(os.environ.get('FLEET_ACCOUNT_PICK_HYST', '10')):
                best = row
                break
        return {'state': 'ready', 'target': best, 'reason': 'same-agent' if kind == agent else 'cross-agent'}
    reason = 'accounts · all capped'
    # An account that is out because its LOGIN is bad is not capped, and saying
    # so — in ccquota's words — is the difference between waiting for a window
    # to reset and going to sign in (claude-fleet#1404).
    needs = [a for a in data['accounts'] if a.get('agent') in allowed and a.get('key') not in excluded
             and a.get('login') not in ('valid', 'refresh_due')]
    if needs:
        reason += ' · login needed: ' + '; '.join(
            '%s %s%s' % (a.get('key'), a.get('login') or 'unknown',
                         ' — ' + a['login_reason'] if a.get('login_reason') else '') for a in needs)
    return {'state': 'waiting-quota', 'target': None, 'reason': reason}


def choose_spawn(data, agent, allowed=('claude', 'codex')):
    result = choose(data, agent, allowed=allowed)
    if result['target'] or any(a.get('available') for a in data['accounts']):
        return result
    # Preserve the old gate's unknown-reading fail-open contract for new work,
    # never for a migration and never across providers on an unknown reading.
    for row in data['accounts']:
        if (row['agent'] == agent and row.get('login') in LOGIN_OK
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
    if len(matches) != 1:
        raise ValueError('pinned destination is no longer eligible')
    row = matches[0]
    # A login that went bad since the pick is named as such (issue #1667): the
    # planner files it as `target-auth: …`, where a bare «no longer eligible» read
    # as quota and sent the operator to the wrong place.
    if row.get('login') not in LOGIN_OK:
        raise ValueError('target-auth: pinned destination %s needs a new login (%s)' % (row['key'], row.get('login') or 'unknown'))
    if quota and not eligible(row):
        raise ValueError('pinned destination is no longer eligible')
    if target['agent'] == 'codex':
        try:
            profile(target['profile'], target['home'], target['account'])
        except ValueError as error:
            raise ValueError('target-auth: ' + str(error))
    return row


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


def stamp_all_capped(data):
    """Record (or clear) `accounts · all capped` for bin/fleet-alerts.sh (issue
    #1238): `<epoch>\t<next-free epoch, 0 = unknown>` in the account state dir.
    It used to live only as a stderr line in a log."""
    path = state_dir() / 'account.all-capped'
    try:
        if data is None:
            path.unlink(missing_ok=True)
            return
        now = int(time.time())
        frees = [max(int(a.get('reset_at') or 0), int(a.get('limited_until') or 0), int(a.get('hold_until') or 0))
                 for a in data.get('accounts', [])]
        frees = [f for f in frees if f > now]
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + '.tmp')
        tmp.write_text('%d\t%d\n' % (now, min(frees) if frees else 0))
        tmp.replace(path)
    except (OSError, ValueError, TypeError):
        pass


def launch(agent, argv):
    allowed = os.environ.get('FLEET_FAILOVER_AGENTS', 'claude,codex').split(',')
    # Provider-specific flags cannot silently become another CLI's flags.
    if len(argv) > 1 or (argv and argv[0].startswith('-')):
        allowed = [agent]
    data = inventory()
    result = choose_spawn(data, agent, allowed=allowed)
    if result['target'] is None:
        stamp_all_capped(data)
        print('fleet-account: ' + result['reason'], file=sys.stderr)
        return 3
    stamp_all_capped(None)
    target = result['target']
    env = dict(os.environ, FLEET_ACCOUNT_TARGET=json.dumps(target), FLEET_ACCOUNT_SELECTED='1')
    if target['agent'] == 'codex':
        env.update(FLEET_CODEX_PROFILE=target['profile'], FLEET_CODEX_ACCOUNT=target['account'],
                   CODEX_HOME=target['home'])
        if target.get('model') and not any(a in ('-m','--model') or a.startswith('--model=') for a in argv):
            argv = ['-m',target['model'],*argv]
    else:
        env['FLEET_ACCOUNT_LABEL'] = target['label']
    # wrap-ok: called FROM fleet-claude.sh, already under fleet-session-wrap.sh (#1784)
    os.execve(str(BIN / 'fleet-claude.sh'), [str(BIN / 'fleet-claude.sh'), '--agent', target['agent'], *argv], env)  # wrap-ok: see above


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
    sub.add_parser('logins')
    q = sub.add_parser('target-auth')   # issue #1667: may this target account start an agent?
    q.add_argument('--agent', choices=('claude', 'codex'), required=True)
    for name in ('label', 'profile', 'home', 'account'):
        q.add_argument('--' + name, default='')
    q = sub.add_parser('claude-login')  # issue #1670: the spawn-path pick's judge for hub labels
    q.add_argument('labels', nargs='+')
    q = sub.add_parser('bench-codex'); q.add_argument('key'); q.add_argument('until', type=int); q.add_argument('reason')
    q = sub.add_parser('launch'); q.add_argument('--agent', choices=('claude', 'codex'), required=True); q.add_argument('argv', nargs=argparse.REMAINDER)
    a = p.parse_args()
    if a.command == 'profile': result = profile(a.name, a.home, a.account)
    elif a.command == 'inventory': result = inventory(a.refresh)
    elif a.command == 'choose':
        data = inventory(a.refresh)
        result = choose_spawn(data,a.agent,a.allow.split(',')) if a.spawn else choose(data,a.agent,a.exclude,a.current,a.allow.split(','))
    elif a.command == 'check-target': result = check_target(read(a.path, {}))
    elif a.command == 'logins': result = logins()
    elif a.command == 'target-auth':
        # JSON on stdout for every verdict; `refuse` also says why on stderr and
        # exits 1, so a shell caller needs only the exit code and that line.
        result = target_auth(a.agent, a.label, a.profile, a.home, a.account)
        print(json.dumps(result, ensure_ascii=False))
        if result['verdict'] == 'refuse':
            print('fleet-account: target-auth: ' + result['reason'], file=sys.stderr)
            return 1
        return 0
    elif a.command == 'claude-login':
        for label in a.labels:
            print('%s\t%s' % (label, claude_login(label)))
        return 0
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
