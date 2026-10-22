#!/usr/bin/env python3
"""Explicit, producer-local report delivery grants; never a parent-link writer.

The OS login owns this private journal, just as it owns the fleet configuration.
Grant/revoke require an authorization reference, not a claimed actor argument.
Only enumerated lifelong worker IDs match. Receiving a delegated report never
resolves another grant: the complete chain is sealed by its producer.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import time
import uuid

BIN = Path(__file__).resolve().parent
UUID = r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}'
WID = re.compile(r'^' + UUID + '/' + UUID + r'$')


def root():
    return Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet')))


def identity(value):
    if not WID.fullmatch(value):
        raise ValueError('requires lifelong <fleet UUID>/<session UUID>, never a key or short code')
    return value


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


@contextlib.contextmanager
def journal():
    directory = root() / 'report-delegation'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077:
        raise ValueError('report-delegation directory must be owned by this login and mode 0700')
    with (directory / 'audit.ndjson').open('a+', encoding='utf-8') as f:
        os.chmod(f.name, 0o600)
        fcntl.flock(f, fcntl.LOCK_EX)
        f.seek(0)
        rows = [json.loads(line) for line in f if line.strip()]
        yield f, rows


def append(f, row):
    f.seek(0, os.SEEK_END)
    f.write(encode(row) + '\n')
    f.flush()
    os.fsync(f.fileno())


def active(rows):
    grants = {}
    for row in rows:
        if row['action'] == 'grant':
            grants[row['id']] = row
        elif row['action'] == 'revoke':
            grants.pop(row['id'], None)
    return list(grants.values())


def resolve(grants, worker, parent):
    chain, seen, target = [], {worker, parent}, parent
    while True:
        matches = [g for g in grants if g['parent'] == target and worker in g['workers']]
        if not matches:
            return {'reporter': worker, 'original_parent': parent,
                    'target': target, 'chain': chain} if chain else None
        if len(matches) != 1:
            raise ValueError('ambiguous delegation scope')
        grant = matches[0]
        target = grant['target']
        if target in seen:
            raise ValueError('delegation cycle or self-delivery')
        seen.add(target)
        # A report carries only this worker's authorization, never the whole
        # scope's roster or other workers' identities.
        chain.append({k: grant[k] for k in ('id', 'parent', 'target', 'ts', 'uid', 'actor', 'authorization')})
        if len(chain) > 8:
            raise ValueError('delegation chain exceeds 8 hops')


def change(action, *, authorization, parent='', target='', workers=(), grant_id=''):
    if not authorization.strip() or len(authorization) > 1000:
        raise ValueError('a nonempty authorization reference (at most 1000 characters) is required')
    # Actor is observed, never supplied by the caller. This is login authority,
    # not a claim that a task, short code or a string is an authentication token.
    row = dict(action=action, ts=int(time.time()), uid=os.getuid(),
               actor=pwd.getpwuid(os.getuid()).pw_name,
               authorization=authorization, id=grant_id or str(uuid.uuid4()))
    with journal() as (f, rows):
        grants = active(rows)
        if action == 'grant':
            row.update(parent=identity(parent), target=identity(target),
                       workers=sorted({identity(w) for w in workers}))
            if not row['workers'] or parent == target or target in row['workers']:
                raise ValueError('empty scope or self-delegation')
            proposed = grants + [row]
            for g in proposed:
                for worker in g['workers']:
                    resolve(proposed, worker, g['parent'])
        elif not any(g['id'] == grant_id for g in grants):
            raise ValueError('no active grant with this ID')
        append(f, row)
    return row


def lookup(worker, parent):
    if not (root() / 'report-delegation/audit.ndjson').exists():
        return None
    identity(worker)
    identity(parent)
    with journal() as (_, rows):
        return resolve(active(rows), worker, parent)


def event_sequence(reporter, fingerprint, dry_run):
    # Compare with the latest event, not all history: BLOCKED → IDLE → BLOCKED
    # is fresh news, whereas replaying the latest BLOCKED is the same send.
    directory = root() / 'report-delegation/events'
    if dry_run and not directory.exists():
        return 1
    directory.mkdir(parents=True, exist_ok=True)
    name = hashlib.sha256(reporter.encode()).hexdigest()
    state = directory / (name + '.json')
    if dry_run:
        old = json.loads(state.read_text()) if state.exists() else {}
        return old.get('seq', 0) + (old.get('fingerprint') != fingerprint)
    with (directory / (name + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old = json.loads(state.read_text()) if state.exists() else {}
        seq = old.get('seq', 0) + (old.get('fingerprint') != fingerprint)
        tmp = state.with_suffix('.tmp')
        with tmp.open('w') as f:
            json.dump(dict(seq=seq, fingerprint=fingerprint), f)
            f.flush()
            os.fsync(f.fileno())
        tmp.replace(state)
        return seq


def seal(route, row, msg, origin, dry_run=False):
    # Identical replay of the latest report/authorization has one durable ID.
    # A transition (including back to the same state) is a new event.
    body = dict(row, report_delegation=route, original_origin=origin)
    fingerprint = hashlib.sha256(encode(body).encode()).hexdigest()
    body['report_event'] = event_sequence(route['reporter'], fingerprint, dry_run)
    suffix = hashlib.sha256(encode(body).encode()).hexdigest()
    body['rid'] = route['reporter'] + '#' + suffix
    chain = ' -> '.join(g['id'] for g in route['chain'])
    body['msg'] = (msg + '\nreporter: ' + route['reporter'] +
                   '\noriginal parent: ' + route['original_parent'] +
                   '\ndelivery: ' + route['target'] + '\ndelegation: ' + chain)
    if len(encode(body).encode()) > 16384:
        raise ValueError('delegated report exceeds hub payload limit (16 KiB); shorten summary/authorization')
    return body


def deliver(path):
    """Shared local/hub receiver: serialize by report ID; only a successful
    adapter delivery settles it. An unavailable or changed identity stays held.
    """
    data = json.loads(Path(path).read_text())
    route = data['report_delegation']
    for k in ('reporter', 'original_parent', 'target'):
        identity(route[k])
    chain = route['chain']
    if not isinstance(chain, list) or not 1 <= len(chain) <= 8:
        raise ValueError('invalid delegation chain')
    parent, seen = route['original_parent'], {route['reporter'], route['original_parent']}
    for hop in chain:
        uuid.UUID(hop['id'])
        target = identity(hop['target'])
        if hop['parent'] != parent or target in seen:
            raise ValueError('broken or cyclic delegation chain')
        parent = target
        seen.add(target)
    if parent != route['target']:
        raise ValueError('delegation chain does not authorize target')
    rid = data['rid']
    if not rid.startswith(route['reporter'] + '#'):
        raise ValueError('report ID does not name its reporter')
    base = root() / 'report-delegation'
    base.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = base / 'receipts'
    directory.mkdir(parents=True, exist_ok=True)
    name = hashlib.sha256(rid.encode()).hexdigest()
    with (directory / (name + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        receipt = directory / (name + '.json')
        if receipt.exists():
            return 0
        rc = subprocess.run(['bash', str(BIN / 'fleet-report-delivery.sh'), '_local', str(path)]).returncode
        if rc == 0:
            tmp = receipt.with_suffix('.tmp')
            with tmp.open('w') as f:
                json.dump(dict(rid=rid, report=data, delivered=int(time.time())), f)
                f.flush()
                os.fsync(f.fileno())
            tmp.replace(receipt)
        return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='action', required=True)
    grant = sub.add_parser('grant')
    grant.add_argument('--parent', required=True)
    grant.add_argument('--target', required=True)
    grant.add_argument('--worker', action='append', required=True, dest='workers')
    grant.add_argument('--authorization', required=True)
    revoke = sub.add_parser('revoke')
    revoke.add_argument('--id', dest='grant_id', required=True)
    revoke.add_argument('--authorization', required=True)
    sub.add_parser('show')
    sub.add_parser('audit')
    route = sub.add_parser('resolve')
    route.add_argument('--worker', required=True)
    route.add_argument('--parent', required=True)
    pack = sub.add_parser('seal')
    pack.add_argument('--route', required=True)
    pack.add_argument('--row', required=True)
    pack.add_argument('--origin', required=True)
    pack.add_argument('--dry-run', action='store_true')
    receive = sub.add_parser('deliver')
    receive.add_argument('file')
    args = vars(ap.parse_args())
    action = args.pop('action')
    if action in ('grant', 'revoke'):
        result = change(action, **args)
    elif action in ('show', 'audit'):
        with journal() as (_, rows):
            result = active(rows) if action == 'show' else rows
    elif action == 'resolve':
        result = lookup(args['worker'], args['parent'])
        if result is None:
            return 4
    elif action == 'seal':
        result = seal(json.loads(args['route']), json.loads(args['row']), sys.stdin.read(), args['origin'], args['dry_run'])
    else:
        return deliver(args['file'])
    print(encode(result))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError) as exc:
        print('report-delegation: ' + str(exc), file=sys.stderr)
        sys.exit(1)
