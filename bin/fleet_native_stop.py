#!/usr/bin/env python3
"""One bounded durable-plan cancellation opportunity before a Task root signal.

Private facts in Control's existing metadata, never a Task state or exit proof.
Missing/old/unknown facts give no grace. No transport runs under the stop write.
"""
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
import uuid
from urllib.parse import quote

from fleet_native_proc import birth_token, kernel_identity, valid_uuid

MAX_SECONDS = 3.0


def monotonic():
    # Python <3.10 on macOS gives time.monotonic() a per-process epoch.
    # Persist the kernel clock, shared by executor and supervisor instead.
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def key(snapshot):
    return 'native-stop:' + snapshot['task_ref'] + ':' + hashlib.sha256(snapshot['operation_id'].encode()).hexdigest()


def remember_stop(db, snapshot):
    """Called only on the first active -> stopped transition, inside its tx."""
    launch = db.execute('SELECT launch_id,operation_id FROM task_execution_launches WHERE task_ref=?',
                        (snapshot['task_ref'],)).fetchone()
    roots = (db.execute('SELECT component,process FROM task_execution_native WHERE task_ref=? AND launch_id=?',
                        (snapshot['task_ref'], launch['launch_id'])).fetchall() if launch else [])
    root = (json.loads(roots[0]['process']) if len(roots) == 1 and roots[0]['component'] == 'agent' else None)
    wall, mono = time.time(), monotonic()
    value = dict(version=1, task_ref=snapshot['task_ref'], operation_id=snapshot['operation_id'],
                 cancel_request=snapshot['cancel_request'], launch_id=launch['launch_id'] if launch else '',
                 root=root, wall_started=wall, mono_started=mono,
                 wall_deadline=wall + MAX_SECONDS, mono_deadline=mono + MAX_SECONDS,
                 phase='new', nonce='', result='')
    db.execute('INSERT OR IGNORE INTO metadata (key,value) VALUES (?,?)', (key(snapshot), encode(value)))


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


@contextlib.contextmanager
def connection(fence):
    # Never let the normal Database.connect's ten-second lock wait hold a stop.
    uri = 'file:' + quote(str(fence.store.path), safe='/') + '?mode=rw'
    with contextlib.closing(sqlite3.connect(uri, uri=True, timeout=.025)) as db:
        db.row_factory = sqlite3.Row
        with db:
            yield db


def remaining(row):
    wall, mono = time.time(), monotonic()
    values = [row[k] for k in ('wall_started','mono_started','wall_deadline','mono_deadline')]
    if any(type(v) not in (int,float) or not math.isfinite(v) for v in values):
        return 0
    if (wall < row['wall_started'] or mono < row['mono_started']
            or abs(row['wall_deadline'] - row['wall_started'] - MAX_SECONDS) > .001
            or abs(row['mono_deadline'] - row['mono_started'] - MAX_SECONDS) > .001):
        return 0
    return max(0, min(row['wall_deadline'] - wall, row['mono_deadline'] - mono))


def context(fence, task, launch_id):
    from fleet_task_execution import _session_exit_registrations, _snapshot
    with connection(fence) as db:
        db.execute('BEGIN')
        found = db.execute('SELECT * FROM task_execution_fences WHERE task_ref=?', (task,)).fetchone()
        if found is None or not found['cancel_request']:
            return None
        snapshot = _snapshot(dict(found))
        stored = db.execute('SELECT value FROM metadata WHERE key=?', (key(snapshot),)).fetchone()
        if stored is None:
            return None
        row = json.loads(stored[0])
        if (row['version'] != 1 or row['task_ref'] != task or row['operation_id'] != snapshot['operation_id']
                or row['cancel_request'] != snapshot['cancel_request'] or row['launch_id'] != launch_id
                or row['phase'] not in ('new','claimed','settled') or not row['root']):
            return None
        launch = _session_exit_registrations(db, snapshot, 'claude')[-1]
        if launch['launch_id'] != launch_id or launch['native'][0]['process'] != row['root']:
            return None
    current = kernel_identity(row['root']['pid'])
    if current['state'] == 'Z' or current['birth_token'] != birth_token(row['root']['birth']):
        return None
    return snapshot, launch, row, stored[0]


def swap(fence, snapshot, old, row):
    with connection(fence) as db:
        return db.execute('UPDATE metadata SET value=? WHERE key=? AND value=?',
                          (encode(row), key(snapshot), old)).rowcount == 1


def before_signal(fence, task, launch_id, *, abort=lambda: False):
    """One producer, concurrent waiters, one fixed deadline; failures release stop.

    Returns the shared monotonic signal deadline, not cancellation/exit proof.
    A process that dies after claim cannot start a fresh chance on replay.
    """
    try:
        while not abort():
            found = context(fence, task, launch_id)
            if found is None:
                return None
            snapshot, launch, row, raw = found
            if row['phase'] == 'settled' or remaining(row) <= 0:
                return time.monotonic() + remaining(row)
            if row['phase'] == 'claimed':
                time.sleep(min(.025, remaining(row)))
                continue
            claimed = dict(row, phase='claimed', nonce=uuid.uuid4().hex)
            if not swap(fence, snapshot, raw, claimed):
                continue
            outcome = 'unknown'
            try:
                if not abort() and remaining(claimed) > 0:
                    result = dispatch_native(fence, snapshot, launch, claimed, abort)
                    outcome = result.get('state', 'unknown')
            except (OSError, ValueError, TypeError, KeyError, sqlite3.Error, subprocess.SubprocessError):
                pass
            finally:
                swap(fence, snapshot, encode(claimed), dict(claimed, phase='settled', result=outcome))
            return time.monotonic() + remaining(claimed)
    except (OSError, ValueError, TypeError, KeyError, sqlite3.Error, subprocess.SubprocessError):
        return None
    return None


def run(argv, row, *, cap=.4, env=None):
    budget = min(cap, remaining(row))
    if budget <= 0:
        raise ValueError('native cancellation deadline expired')
    result = subprocess.run(argv, capture_output=True, text=True, timeout=budget, env=env)
    if result.returncode:
        raise ValueError('native cancellation lookup unavailable')
    return result.stdout.strip()


def window(snapshot, row):
    """Resolve through the existing FID resolver, then pin its exact pane facts."""
    owner = snapshot['execution_owner'].split('/')
    if len(owner) != 2 or not all(valid_uuid(value) for value in owner):
        raise ValueError('cancellation has no exact worker identity')
    fid = owner[1]
    binary = str(Path(__file__).resolve().parent)
    location = None
    # The supervisor inherits its exact pane; verify its FID below. A Control
    # executor without that binding uses the one existing cross-socket resolver.
    own_socket = os.environ.get('TMUX','').split(',')[0]
    own_pane = os.environ.get('TMUX_PANE','')
    if os.path.isabs(own_socket) and re.fullmatch(r'%[0-9]+',own_pane):
        seen = run(['tmux','-S',own_socket,'display-message','-p','-t',own_pane,'#{@fleet_id}'],row)
        if seen == fid:
            location = own_socket + '\t' + own_pane
    if location is None:
        location = run(['bash','-c','. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_id_window "$2"',
                        'native-stop', binary, fid], row)
    lines = location.splitlines()
    if len(lines) != 1 or '\t' not in lines[0]:
        raise ValueError('ambiguous cancellation window')
    sock, win = lines[0].split('\t')
    if not sock or not re.fullmatch(r'[@%][0-9]+',win):
        raise ValueError('invalid cancellation window')
    fields = ['#{@fleet_id}','#{@task}','#{@cc_agent}','#{@cc_session_id}','#{@mod_state}',
              '#{@mod_alive}','#{pane_id}','#{pane_pid}','#{socket_path}']
    values = run(['tmux', '-S' if os.path.isabs(sock) else '-L',sock,
                  'display-message','-p','-t',win,'\t'.join(fields)],row).split('\t')
    if (len(values) != len(fields) or values[0] != fid or values[1] != snapshot['task_ref']
            or values[2] not in ('','claude') or not valid_uuid(values[3]) or values[4] != 'on'
            or not re.fullmatch(r'%[0-9]+',values[6]) or not values[7].isdigit()
            or not os.path.isabs(values[8]) or not 0 <= time.time()-float(values[5]) <= 45):
        raise ValueError('cancellation pane identity unavailable')
    # A matching SID option is insufficient: the registered native PID must
    # still descend from this exact pane, never a sibling sharing the project.
    pid = row['root']['pid']
    for _ in range(32):
        if pid == int(values[7]):
            return dict(session_id=values[3], pane=values[6], socket=values[8])
        pid = kernel_identity(pid)['ppid']
        if pid <= 1:
            break
    raise ValueError('registered native root is outside the addressed pane')


def dispatch_native(fence, snapshot, launch, row, abort):
    from fleet_native_cancel import read_json
    if abort() or remaining(row) <= 0:
        return dict(state='unknown')
    # Only this launch's actual registry can nominate its project and native SID.
    native_conf = Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home()/'.claude'))
    registry = Path(os.environ.get('FLEET_CC_SESSIONS_DIR', native_conf/'sessions'))
    identity = read_json(registry / ('%d.json' % row['root']['pid']))
    if not isinstance(identity, dict):
        return dict(state='unsupported')
    sid, project = identity.get('sessionId'), identity.get('cwd')
    if not valid_uuid(sid) or not isinstance(project,str) or not Path(project).is_absolute():
        return dict(state='unsupported')
    project = Path(project).resolve(strict=True)
    table = read_json(project/'.claude/scheduled_tasks.json')
    if not isinstance(table, dict):
        return dict(state='unsupported')
    jobs = table.get('tasks')
    if not isinstance(jobs,list) or any(not isinstance(j,dict) or not isinstance(j.get('id'),str) for j in jobs):
        return dict(state='unsupported')
    if len({j['id'] for j in jobs}) != len(jobs):
        return dict(state='unsupported')
    start = run(['ps','-p',str(row['root']['pid']),'-o','lstart='],row,
                env=dict(os.environ, LC_ALL='C', TZ='UTC'))
    ids = [j['id'] for j in jobs if j.get('createdBySessionId') == sid
           and type(j.get('createdByPid')) is int and j['createdByPid'] == row['root']['pid']
           and j.get('createdByProcStart') == start and isinstance(j.get('createdInProject'),str)
           and Path(j['createdInProject']).resolve() == project]
    if not ids or len(ids) > 50 or any(not re.fullmatch('[0-9a-f]{8}',i) for i in ids):
        return dict(state='unsupported')
    w = window(snapshot,row)
    if w['session_id'] != sid or abort() or remaining(row) <= 0:
        return dict(state='unsupported')
    directory = fence.conf_dir/'global/mod-inbox'/Path(w['socket']).name/w['pane'][1:]
    if directory.is_symlink():
        return dict(state='unsupported')
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    lock_path = directory/'native-cancel.lock'
    fd = os.open(lock_path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
    with os.fdopen(fd,'a') as held:
        try:
            fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            return dict(state='busy')
        fresh = context(fence,snapshot['task_ref'],launch['launch_id'])
        if fresh is None or fresh[0] != snapshot or abort() or remaining(row) <= 0:
            return dict(state='unknown')
        slot, done = directory/'native-cancel.json', directory/'native-cancel.done'
        if slot.exists():
            return dict(state='busy')
        done.unlink(missing_ok=True)
        request = dict(cancel='native.cancel.v1',nonce=row['nonce'],execution=snapshot,
                       launch_id=launch['launch_id'],session_id=sid,deadline=row['wall_deadline'],cron_ids=ids)
        temporary = directory/('.native-cancel.'+row['nonce']+'.tmp')
        temporary.write_text(encode(request))
        temporary.replace(slot)
        try:
            while not abort() and remaining(row) > 0:
                if done.exists():
                    try:
                        result = read_json(done)
                    except (ValueError,OSError):
                        result = None  # native writer may not have finished yet
                    if isinstance(result,dict):
                        if result.get('nonce') != row['nonce'] or result.get('session_id') != sid:
                            return dict(state='unknown')
                        if result.get('state') != 'observed_absent':
                            return dict(state='unconfirmed')
                        if (result.get('ok') is True and result.get('scope') == 'native_durable_plans'
                                and result.get('cancelled_ids') == ids):
                            return dict(state='observed_absent')
                        return dict(state='unknown')
                time.sleep(min(.025,remaining(row)))
            return dict(state='deadline_unknown')
        finally:
            # Withdraw an unclaimed request. A .taken request may still execute;
            # the common signal deadline must end its native root regardless.
            try:
                slot.rename(directory/('.native-cancel.'+row['nonce']+'.withdrawn'))
            except FileNotFoundError:
                pass
