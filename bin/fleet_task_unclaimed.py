"""Retire only a never-claimed allocation under fresh explicit Hub authority.

This is a private record in Control's existing operation journal, not a forged
worker_stop. LOCAL starts need not have received either original control request
and source_stop deliberately carries no actor/request bytes. The active slots
cannot retain an old FID after replacement and there is no retired-session table.
A succeeded local-only subtype preserves that stop fact without inventing a Hub
request, native exit proof, pending operation or separate ledger.
"""
import json
import sqlite3
import time
import uuid

from fleet_hub_common import Database, canonical, is_identity
from fleet_task_execution import FIELDS, FenceRefused, _snapshot, validate_request

RETIREMENT = 'task_unclaimed_retirement'


def source_stop(value, incoming):
    if not isinstance(value, dict) or set(value) != set(FIELDS):
        raise FenceRefused('unclaimed source requires its complete immutable stopped snapshot')
    stopped = _snapshot(value, allow_unclaimed=True)
    if (stopped['execution_owner'] or not is_identity(stopped['cancel_request'])
            or not stopped['task_fid'] or not stopped['operation_id'] or not stopped['execution_endpoint']
            or not stopped['binding_generation'] or stopped['generation'] != stopped['binding_generation'] + 1
            or incoming['generation'] != stopped['generation'] + 1 or incoming['cancel_request']
            or any(incoming[k] != stopped[k] for k in ('task_ref', 'task_fid', 'execution_endpoint'))
            or incoming['operation_id'] in (stopped['operation_id'], stopped['cancel_request'])):
        raise FenceRefused('unclaimed stop does not authorize this Task, endpoint or generation')
    return stopped


def retirement(row):
    """Validate private immutable provenance on every recovery/historical read."""
    request, result = json.loads(row['request']), json.loads(row['result'])
    if (row['action'] != RETIREMENT or row['status'] != 'succeeded'
            or not isinstance(request, dict) or set(request) != {'source_stop', 'next'}
            or not isinstance(result, dict) or set(result) != {RETIREMENT}
            or not isinstance(result[RETIREMENT], dict) or set(result[RETIREMENT]) != {'retired', 'snapshot'}):
        raise FenceRefused('malformed unclaimed retirement journal')
    saved = result[RETIREMENT]
    incoming = _snapshot(request['next'], allow_unclaimed=True)
    stopped = source_stop(request['source_stop'], incoming)
    allocated = _snapshot(saved['snapshot'])
    retired = saved['retired']
    if (incoming['execution_owner'] or allocated != dict(incoming, execution_owner=allocated['execution_owner'])
            or allocated['execution_owner'].split('/')[0] != row['fleet_id']
            or allocated['execution_owner'].split('/')[1] == allocated['task_fid']):
        raise FenceRefused('unclaimed successor allocation conflicts with its journal')
    if retired is not None:
        retired = _snapshot(retired)
        if (retired != dict(stopped, execution_owner=retired['execution_owner']) or not retired['execution_owner']
                or retired['execution_owner'].split('/')[0] != row['fleet_id']
                or retired['execution_owner'] == allocated['execution_owner']):
            raise FenceRefused('unclaimed retired identity conflicts with its stopped source')
    return stopped, allocated, retired


def historical_stop(db, fid):
    rows = db.execute("""SELECT * FROM operations WHERE action=?
        AND json_extract(result,'$.task_unclaimed_retirement.retired.execution_owner') LIKE ?""",
        (RETIREMENT, '%/' + fid)).fetchall()
    found = None
    for row in rows:
        _, _, retired = retirement(row)
        if found is not None and found != retired:
            raise FenceRefused('session has conflicting unclaimed retirement facts')
        found = retired
    return found


def replace_unclaimed(fence, snapshot, fleet_id, stopped, *, authorized=False):
    incoming = _snapshot(snapshot, allow_unclaimed=True)
    stopped = source_stop(stopped, incoming)
    if authorized is not True or not is_identity(fleet_id):
        raise FenceRefused('unclaimed continuation requires explicit current Hub authority')
    # Reuse the existing Control journal schema for LOCAL with no delivered stop.
    from fleet_control import SCHEMA
    Database(fence.store.root, SCHEMA)
    try:
        with fence._admission_lock(incoming['task_ref']), fence.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            stop_row = db.execute('SELECT * FROM operations WHERE id=?', (stopped['cancel_request'],)).fetchone()
            if stop_row is not None:
                stop_request = json.loads(stop_row['request'])
                if (stop_row['action'] != 'worker_stop' or stop_row['fleet_id'] != fleet_id
                        or stop_request.get('operation_id') != stopped['cancel_request']
                        or validate_request(stop_request) != stopped):
                    raise FenceRefused('delivered stop contradicts authenticated unclaimed source')
            rows = db.execute("""SELECT * FROM operations WHERE action=? AND
                (json_extract(request,'$.source_stop.cancel_request')=? OR
                 json_extract(request,'$.next.operation_id')=?)""",
                (RETIREMENT, stopped['cancel_request'], incoming['operation_id'])).fetchall()
            old = fence._read(db, incoming['task_ref'])
            session = db.execute('SELECT * FROM task_execution_sessions WHERE task_ref=?', (incoming['task_ref'],)).fetchone()
            if rows:
                if len(rows) != 1:
                    raise FenceRefused('ambiguous unclaimed continuation allocation')
                saved_stop, allocated, _ = retirement(rows[0])
                if (saved_stop != stopped or allocated != dict(incoming, execution_owner=allocated['execution_owner'])
                        or incoming['execution_owner'] not in ('', allocated['execution_owner'])
                        or rows[0]['fleet_id'] != fleet_id or old != allocated
                        or session is None or session['operation_id'] != allocated['operation_id']
                        or session['execution_owner'] != allocated['execution_owner']):
                    raise FenceRefused('unclaimed continuation was replaced, stopped or conflicts with its allocation')
                window = db.execute('SELECT * FROM task_execution_windows WHERE task_ref=?', (incoming['task_ref'],)).fetchone()
                if window and (window['operation_id'] != allocated['operation_id'] or window['execution_owner'] != allocated['execution_owner']):
                    raise FenceRefused('retry found another operation window reservation')
                launches = [dict(r) for r in db.execute('SELECT * FROM task_execution_launches WHERE task_ref=?', (incoming['task_ref'],))]
                for r in db.execute('SELECT * FROM task_execution_launch_history WHERE task_ref=?', (incoming['task_ref'],)):
                    registration = json.loads(r['registration'])
                    if not isinstance(registration, dict) or registration.get('launch_id') != r['launch_id']:
                        raise FenceRefused('retry found inconsistent launch history')
                    launches.append(registration)
                if any(r.get('operation_id') != allocated['operation_id'] or r.get('task_ref') != allocated['task_ref'] for r in launches):
                    raise FenceRefused('retry found another operation launch registration')
                launch_ids = {r['launch_id'] for r in launches}
                native = list(db.execute('SELECT launch_id FROM task_execution_native WHERE task_ref=?', (incoming['task_ref'],)))
                if (launches or native) and (not window or any(r['launch_id'] not in launch_ids for r in native)):
                    raise FenceRefused('retry found orphan native or history registration')
                return allocated
            if incoming['execution_owner']:
                raise FenceRefused('cannot adopt a claimed successor without its original allocation')
            start_row = db.execute('SELECT * FROM operations WHERE id=?', (stopped['operation_id'],)).fetchone()
            if start_row is not None:
                request = json.loads(start_row['request'])
                prior = json.loads(start_row['result']) if start_row['result'] else {}
                source = dict(stopped, generation=stopped['binding_generation'], cancel_request='')
                if (start_row['action'] != 'worker_start' or start_row['fleet_id'] != fleet_id
                        or request.get('operation_id') != stopped['operation_id']
                        or validate_request(request) != source or not isinstance(prior, dict)
                        or any(prior.get(k) for k in ('window', 'window_id', 'worker', 'workers', 'worker_id', 'pid'))):
                    raise FenceRefused('original start journal contradicts a pure unclaimed allocation')
            for table in ('task_execution_windows', 'task_execution_launches', 'task_execution_native',
                          'task_execution_launch_history'):
                if db.execute('SELECT 1 FROM '+table+' WHERE task_ref=?', (incoming['task_ref'],)).fetchone():
                    raise FenceRefused('unclaimed continuation has window, launch or history registration')
            retired = None
            if session:
                worker = session['execution_owner']
                retired = _snapshot(dict(stopped, execution_owner=worker))
                ledger = fence.conf_dir / 'ids' / (worker.split('/')[1] + '.ndjson')
                if (session['operation_id'] != stopped['operation_id'] or worker.split('/')[0] != fleet_id
                        or ledger.exists() or ledger.is_symlink()):
                    raise FenceRefused('old session is not an exact pure allocation')
            if old is not None:
                owner = retired['execution_owner'] if retired else ''
                # Stop delivery may not yet have reached this node. A speculative
                # preclaim fence is allowed only when its exact allocation exists.
                candidates = [dict(stopped, execution_owner=old['execution_owner']),
                              dict(stopped, generation=stopped['binding_generation'], cancel_request='',
                                   execution_owner=old['execution_owner'])]
                if old not in candidates or old['execution_owner'] not in ('', owner):
                    raise FenceRefused('local execution contradicts the unclaimed source')
            worker = fleet_id + '/' + str(uuid.uuid4())
            if (worker.split('/')[1] == incoming['task_fid'] or (retired and worker == retired['execution_owner'])):
                raise FenceRefused('unclaimed continuation requires a fresh Session FID')
            allocated = dict(incoming, execution_owner=worker)
            stamp = time.time()
            db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,?)',
                       (str(uuid.uuid4()), fleet_id, RETIREMENT,
                        canonical(dict(source_stop=stopped, next=incoming)), 'local:unclaimed-continuation',
                        'succeeded', stamp, stamp, canonical({RETIREMENT: dict(retired=retired, snapshot=allocated)})))
            db.execute('INSERT OR REPLACE INTO task_execution_sessions VALUES (?,?,?)',
                       (incoming['task_ref'], incoming['operation_id'], worker))
            fence._save(db, allocated)
            return allocated
    except (sqlite3.Error, OSError, ValueError, KeyError, TypeError, IndexError) as exc:
        if isinstance(exc, FenceRefused): raise
        raise FenceRefused('unclaimed continuation evidence is unavailable or inconsistent') from exc
