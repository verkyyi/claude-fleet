"""EXPERIMENTAL: journaled handover of Claude 2.1.295 durable one-shots.

Not connected to production: native writers do not share this component's lock.
Read/replace can lose concurrent additions, and stale native writes can resurrect
a migrated task after completion or a controller crash. A shared writer fence
is required before this component can authorize any real transfer.

This is a private transfer prototype, not a general native task editor. A staged
Fleet spec is inert. Native ownership is fenced before withdrawal, and Fleet
activation requires the exact source process to have ended. Unknown owners,
changed records and ambiguous active delivery are never automatically replayed.
"""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import uuid
from fleet_cron import fields

SUPPORTED = '2.1.295'
MARGIN = 180


def proc_start(pid):
    return subprocess.check_output(
        ['ps', '-p', str(int(pid)), '-o', 'lstart='], text=True,
        env=dict(os.environ, LC_ALL='C', TZ='UTC'), stderr=subprocess.DEVNULL,
        timeout=5).strip()


def alive(pid, start):
    try:
        os.kill(int(pid), 0)
        return bool(start) and proc_start(pid) == start
    except (ProcessLookupError, subprocess.CalledProcessError):
        return False


def read(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('native ownership file must not be a symlink')
    data = json.loads(path.read_text())
    return data


def atomic(path, value, mode=0o600):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('native ownership file changed into a symlink')
    fd, name = tempfile.mkstemp(prefix='.'+path.name+'-fleet-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as out:
            os.fchmod(out.fileno(), mode)
            json.dump(value, out, ensure_ascii=False, indent=2)
            out.write('\n'); out.flush(); os.fsync(out.fileno())
        os.replace(name, path)
        fd = os.open(str(path.parent), os.O_RDONLY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(name): os.unlink(name)


def tasks(value):
    if not isinstance(value, dict) or not isinstance(value.get('tasks'), list):
        raise ValueError('unsupported native durable table')
    entries = value['tasks']
    if any(not isinstance(r, dict) or not isinstance(r.get('id'), str) for r in entries):
        raise ValueError('unknown native durable record')
    if len({r['id'] for r in entries}) != len(entries):
        raise ValueError('duplicate native task identities')
    return entries


def probe(home, pid, jobs, version):
    home = Path(home).resolve()
    if version != SUPPORTED:
        raise ValueError('native durable ownership requires verified Claude '+SUPPORTED)
    path, lock = home/'.claude/scheduled_tasks.json', home/'.claude/scheduled_tasks.lock'
    table, owner = read(path), read(lock)
    records = tasks(table)
    start = proc_start(pid)
    if not start or owner.get('pid') != int(pid) or owner.get('procStart') != start:
        raise ValueError('native scheduler execution owner is not the exact source process')
    by_id = {j['id']: j for j in jobs}
    if not records or {r['id'] for r in records} != set(by_id):
        raise ValueError('all native durable records must belong to this handover')
    for r in records:
        j = by_id[r['id']]
        if (r.get('createdByPid') != int(pid) or r.get('createdByProcStart') != start
                or r.get('createdBySessionId') != owner.get('sessionId')
                or r.get('createdInProject') != str(home)):
            raise ValueError('native task has a different or unknown creator execution owner')
        if (r.get('recurring', False) or j.get('recurring') is not False
                or r.get('prompt') != j['prompt'] or r.get('cron') != j['cron']):
            raise ValueError('only exact source-owned durable one-shots can move')
        if fields(j['cron'])[1][0] & {0, 30}:
            raise ValueError('native early-jitter one-shots cannot move without their selected firing time')
        if not j.get('next_run_at') or j['next_run_at'] <= time.time()+MARGIN:
            raise ValueError('durable task is due inside the ownership cutover margin')
    return dict(home=str(home), store=str(path), lock=str(lock), table=table,
                native_owner=owner, source_pid=int(pid), source_start=start,
                mode=stat.S_IMODE(path.stat().st_mode),
                lock_mode=stat.S_IMODE(lock.stat().st_mode),
                jobs=jobs, version=version)


def journal(bundle):
    return Path(bundle)/'durable-transfer.json'


@contextmanager
def locked(bundle):
    path = journal(bundle)
    with path.with_suffix('.lock').open('a') as fd:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield path, read(path)


def prepare(bundle, proof):
    path = journal(bundle)
    if path.exists():
        raise ValueError('durable ownership journal already exists')
    spec = read(Path(bundle)/'loop-spec.json')
    staged = {j['id']: j for j in spec.get('jobs', [])}
    for j in proof['jobs']:
        if staged.get(j['id']) != j:
            raise ValueError('durable Fleet job was not staged and read back exactly')
    record = dict(proof, state='prepared', token='fleet-'+str(uuid.uuid4()),
                  bundle=str(Path(bundle).resolve()))
    atomic(path, record)
    if read(path) != record:
        raise ValueError('durable ownership journal readback failed')


def lease(r, pid):
    return dict(sessionId=r['token'], pid=int(pid), procStart=proc_start(pid),
                acquiredAt=int(time.time()*1000))


def own_lock(r, pid=None):
    owner = read(r['lock'])
    if owner.get('sessionId') != r['token']:
        raise ValueError('native scheduler lock changed owner; refusing automatic recovery')
    if pid is not None and (owner.get('pid') != int(pid) or owner.get('procStart') != proc_start(pid)):
        raise ValueError('native scheduler lease belongs to another Fleet controller')
    return owner


def absent(r):
    ids = {j['id'] for j in r['jobs']}
    if any(t['id'] in ids for t in tasks(read(r['store']))):
        raise ValueError('a migrated native task reappeared; Fleet delivery is refused')


def withdraw(bundle, pid):
    with locked(bundle) as (path, r):
        if r['state'] != 'prepared':
            raise ValueError('durable withdrawal already attempted; recover its journal first')
        # No task or owner mutation before all checks, including staged job readback.
        if not alive(r['source_pid'], r['source_start']):
            raise ValueError('source exited before durable withdrawal')
        if read(r['store']) != r['table'] or read(r['lock']) != r['native_owner']:
            raise ValueError('native task table or execution owner changed')
        spec = {j['id']:j for j in read(Path(bundle)/'loop-spec.json')['jobs']}
        if any(spec.get(j['id']) != j or j['next_run_at'] <= time.time()+MARGIN for j in r['jobs']):
            raise ValueError('staged durable task changed or is due too soon')
        holder = lease(r,pid)
        r.update(state='withdrawing', lease=holder)
        atomic(path,r)  # write-ahead: either native mutation may have happened
        atomic(r['lock'],holder,r['lock_mode'])
        own_lock(r,pid)
        # The exact source remains alive, owns every migrated task, and cannot
        # reach its next round during the bounded exit. It cannot release our
        # different session identity's native lock when it exits.
        if read(r['store']) != r['table']:
            raise ValueError('native task table changed while fencing ownership')
        ids = {j['id'] for j in r['jobs']}
        table = dict(r['table'],tasks=[t for t in tasks(r['table']) if t['id'] not in ids])
        atomic(r['store'],table,r['mode'])
        absent(r)
        r['state']='withdrawn'; atomic(path,r)


def claim(bundle, pid, replace=False):
    with locked(bundle) as (path,r):
        if r['state'] not in ('withdrawn','bound','active'):
            raise ValueError('durable transaction is not ready for activation')
        if alive(r['source_pid'],r['source_start']):
            raise ValueError('source execution owner is still alive')
        old=own_lock(r)
        if r['state'] in ('bound','active') and old.get('pid') != int(pid) and alive(old['pid'],old['procStart']) and not replace:
            raise ValueError('another active Fleet controller owns this transaction')
        absent(r)
        holder=lease(r,pid)
        atomic(r['lock'],holder,r['lock_mode'])
        # A later owner must never erase activation history: aborting such a
        # journal could replay a one-shot already accepted by the old target.
        r.update(state='active' if r['state']=='active' else 'bound',lease=holder)
        atomic(path,r)


def activate(bundle, pid):
    """Called only after the transfer verifies the native target and loop binding."""
    with locked(bundle) as (path, r):
        if r['state'] not in ('bound', 'active'):
            raise ValueError('durable transaction is not bound')
        own_lock(r, pid); absent(r)
        if alive(r['source_pid'], r['source_start']):
            raise ValueError('source execution owner is still alive')
        r['state'] = 'active'
        atomic(path, r)


def guard(bundle,pid):
    with locked(bundle) as (_,r):
        if r['state']=='complete':
            return True
        if r['state']=='bound':
            own_lock(r,pid); absent(r)
            return False
        if r['state']!='active':
            raise ValueError('durable transaction is not active')
        own_lock(r,pid); absent(r)
        if alive(r['source_pid'],r['source_start']):
            raise ValueError('source execution owner is still alive')
        return True


def abort(bundle):
    with locked(bundle) as (path,r):
        if r['state']=='rolled_back':
            return
        if r['state']=='active' or r['state']=='complete':
            raise ValueError('active durable delivery cannot be automatically rolled back')
        if r['state']=='prepared':
            r['state']='rolled_back'; atomic(path,r); return
        if r['state']=='bound' and alive(r['lease']['pid'],r['lease']['procStart']):
            raise ValueError('bound target controller is still alive; refusing rollback')
        owner=read(r['lock'])
        if owner != r['native_owner'] and owner.get('sessionId') != r['token']:
            raise ValueError('native execution owner changed; refusing rollback')
        table=read(r['store']); entries=tasks(table)
        existing={t['id']:t for t in entries}
        originals=tasks(r['table'])
        for task in originals:
            if task['id'] in existing and existing[task['id']] != task:
                raise ValueError('native task changed; refusing to overwrite it on rollback')
        restored=dict(table,tasks=entries+[t for t in originals if t['id'] not in existing])
        atomic(r['store'],restored,r['mode'])
        if read(r['store']) != restored:
            raise ValueError('native task rollback readback failed')
        atomic(r['lock'],r['native_owner'],r['lock_mode'])
        r['state']='rolled_back'; atomic(path,r)


def complete(bundle,pid):
    with locked(bundle) as (path,r):
        if r['state']=='complete': return
        if r['state']!='active': raise ValueError('durable transaction is not active')
        own_lock(r,pid); absent(r)
        r['state']='complete'; atomic(path,r)
        Path(r['lock']).unlink()
