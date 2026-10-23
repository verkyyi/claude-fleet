#!/usr/bin/env python3
"""Read-only ownership check for the Claude mod's narrow durable-plan cancel.

No tool execution, stop mutation, binding release, networking or process signal.
The caller must already have persisted the exact Task stop. Session-only plans
and native background tasks have no ownership proof here and are unsupported.
"""
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
from urllib.parse import quote

from fleet_native_proc import birth_token, kernel_identity, valid_uuid
from fleet_task_execution import _session_exit_registrations, _snapshot


KEYS = {'cancel', 'nonce', 'execution', 'launch_id', 'session_id', 'deadline', 'cron_ids'}
MAX_SECONDS = 3


def parse_request(value, now=None):
    now = time.time() if now is None else now
    if not isinstance(value, dict) or set(value) != KEYS or value.get('cancel') != 'native.cancel.v1':
        raise ValueError('unsupported native cancel request')
    if (not isinstance(value['nonce'], str) or not re.fullmatch('[0-9a-f]{32}', value['nonce'])
            or not valid_uuid(value['launch_id']) or not valid_uuid(value['session_id'])):
        raise ValueError('invalid native cancel identity')
    deadline = value['deadline']
    if (type(deadline) not in (int, float) or not math.isfinite(deadline)
            or deadline <= now or deadline - now > MAX_SECONDS):
        raise ValueError('native cancellation deadline expired or exceeds three seconds')
    ids = value['cron_ids']
    if (not isinstance(ids, list) or not 1 <= len(ids) <= 50
            or any(not isinstance(v, str) or not re.fullmatch('[0-9a-f]{8}', v) for v in ids)
            or len(set(ids)) != len(ids)):
        raise ValueError('native cancellation requires distinct durable plan IDs')
    execution = _snapshot(value['execution'])
    if execution != value['execution'] or not execution['cancel_request']:
        raise ValueError('native cancellation requires the exact stopped execution')
    return value


def registrations(conf, request):
    path = Path(conf) / 'control/state.sqlite3'
    with contextlib.closing(sqlite3.connect('file:' + quote(str(path), safe='/') + '?mode=ro',
                                            uri=True, timeout=.05)) as db:
        db.row_factory = sqlite3.Row
        db.execute('BEGIN')
        return _session_exit_registrations(db, request['execution'], 'claude')


def own_root(proof):
    """The helper must descend from this exact registered native process."""
    root = kernel_identity(proof['pid'])
    if root['state'] == 'Z' or root['birth_token'] != birth_token(proof['birth']):
        raise ValueError('registered native root changed or exited')
    pid = os.getpid()
    for _ in range(32):
        if pid == proof['pid']:
            return {key: root[key] for key in ('pid', 'ppid', 'birth_token')}
        item = kernel_identity(pid)
        pid = item['ppid']
        if pid <= 1:
            break
    raise ValueError('cancel verifier is not inside the registered native root')


def read_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError('native ownership source is unavailable')
    return json.loads(path.read_text())


def verify(payload, *, conf_dir=None, registry_dir=None):
    if not isinstance(payload, dict) or set(payload) != {'request', 'session_id', 'project', 'ids', 'expected'}:
        raise ValueError('invalid native cancel verification envelope')
    request = parse_request(payload['request'])
    if payload['session_id'] != request['session_id']:
        raise ValueError('native session changed')
    selected = payload['ids']
    expected = payload['expected']
    if (not isinstance(selected, list) or len(set(selected)) != len(selected)
            or any(i not in request['cron_ids'] for i in selected)
            or not isinstance(expected, dict) or any(i not in selected for i in expected)):
        raise ValueError('invalid selected native resources')
    project = payload['project']
    if not isinstance(project, str) or not Path(project).is_absolute():
        raise ValueError('native project is not absolute')
    project = Path(project).resolve(strict=True)
    conf = Path(conf_dir or os.environ.get('FLEET_CONF_DIR', Path.home() / '.config/claude-fleet')).absolute()
    before = registrations(conf, request)
    launch = before[-1]
    if launch['launch_id'] != request['launch_id']:
        raise ValueError('native launch changed')
    proof = launch['native'][0]['process']
    root = own_root(proof)
    native_conf = Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home() / '.claude'))
    registry = Path(registry_dir or os.environ.get('FLEET_CC_SESSIONS_DIR', native_conf / 'sessions'))
    identity = read_json(registry / ('%d.json' % proof['pid']))
    if (identity.get('sessionId') != request['session_id']
            or not isinstance(identity.get('cwd'), str)
            or Path(identity['cwd']).resolve() != project):
        raise ValueError('native session registry changed')
    start = subprocess.check_output(['ps', '-p', str(proof['pid']), '-o', 'lstart='], text=True,
                                    env=dict(os.environ, LC_ALL='C', TZ='UTC'), timeout=.4).strip()
    table_path = project / '.claude/scheduled_tasks.json'
    table = read_json(table_path)
    if not isinstance(table, dict) or not isinstance(table.get('tasks'), list):
        raise ValueError('unsupported native durable plan table')
    rows = table['tasks']
    if any(not isinstance(r, dict) or not isinstance(r.get('id'), str) for r in rows):
        raise ValueError('malformed native durable plan table')
    jobs = {r['id']: r for r in rows}
    if len(jobs) != len(rows):
        raise ValueError('ambiguous native plan identity')
    evidence = {}
    for ident in selected:
        row = jobs.get(ident)
        if row is None:
            raise ValueError('durable ownership unavailable; session-only or absent plan unsupported')
        if (row.get('createdBySessionId') != request['session_id']
                or type(row.get('createdByPid')) is not int or row['createdByPid'] != proof['pid']
                or row.get('createdByProcStart') != start
                or not isinstance(row.get('createdInProject'), str)
                or Path(row['createdInProject']).resolve() != project):
            raise ValueError('native durable plan belongs to another session or root')
        fingerprint = hashlib.sha256(json.dumps(row, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        if ident in expected and expected[ident] != fingerprint:
            raise ValueError('native durable plan changed after preflight')
        evidence[ident] = fingerprint
    if (read_json(table_path) != table or read_json(registry / ('%d.json' % proof['pid'])) != identity
            or own_root(proof) != root or registrations(conf, request) != before):
        raise ValueError('native ownership changed during verification')
    parse_request(request)
    return {'scope': 'native_durable_plans', 'session_id': request['session_id'],
            'launch_id': request['launch_id'], 'evidence': evidence,
            'present_ids': [ident for ident in request['cron_ids'] if ident in jobs]}


def main():
    try:
        raw = sys.stdin.read(65537)
        if len(raw) > 65536:
            raise ValueError('native cancellation request is too large')
        print(json.dumps(verify(json.loads(raw)), separators=(',', ':')))
        return 0
    except (ValueError, TypeError, KeyError, OSError, sqlite3.Error, subprocess.SubprocessError):
        # No payloads or resource contents in errors. The mod reports refusal.
        print('native cancellation ownership unavailable or changed', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
