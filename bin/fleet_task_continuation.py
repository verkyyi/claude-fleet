#!/usr/bin/env python3
"""Resolve a controlled continuation from existing receipts and identity history.

No supplied workspace, native resume, parent routing or separate continuation
ledger. The original ACK packet remains the authority for the source session.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys

from fleet_hub_common import is_identity
from fleet_task_execution import (ExecutionFence, FenceRefused, _snapshot, _process_proof,
                                  _session_exit_registrations, _match_exit_registrations)
from fleet_task_exit_submit import acknowledged_native_exit


def validate_continuation(value):
    if (not isinstance(value, dict) or set(value) not in ({'version', 'exit_operation_id'}, {'version', 'stop_operation_id'})
            or type(value.get('version')) is not int or value['version'] != 1
            or not is_identity(value.get('exit_operation_id', value.get('stop_operation_id')))):
        raise FenceRefused('continuation requires version 1 and exactly one exit or unclaimed stop operation ID')
    return value


def validate_metadata(expected, continuation, authority):
    """Both transports read the same strict immutable start union."""
    validate_continuation(continuation)
    start, source = authority.get('start'), authority.get('source_start')
    if (not isinstance(start, dict) or start.get('continuation') != continuation
            or start.get('operation_id') != expected['operation_id']
            or start.get('agent') not in ('claude', 'codex')
            or not isinstance(start.get('repo'), str) or type(start.get('no_repo')) is not bool
            or bool(start['repo']) == start['no_repo']):
        raise FenceRefused('invalid immutable continuation start')

    def check_source(value):
        if (not isinstance(value, dict) or set(value) != {'operation_id', 'agent', 'repo', 'no_repo'}
                or not isinstance(value['operation_id'], str) or not value['operation_id']
                or value['agent'] not in ('claude', 'codex')
                or not isinstance(value['repo'], str) or type(value['no_repo']) is not bool
                or value['repo'] != start['repo'] or value['no_repo'] != start['no_repo']):
            raise FenceRefused('invalid immutable continuation source')
    check_source(source)
    if 'exit_operation_id' in continuation:
        if 'source_stop' in authority or 'workspace_source' in authority:
            raise FenceRefused('native continuation cannot carry unclaimed stop metadata')
        return
    from fleet_task_unclaimed import source_stop
    stopped = source_stop(authority.get('source_stop'), expected)
    if stopped['cancel_request'] != continuation['stop_operation_id'] or source['operation_id'] != stopped['operation_id']:
        raise FenceRefused('immutable unclaimed source names another stop or start')
    if 'workspace_source' in authority:
        workspace = authority['workspace_source']
        if (not isinstance(workspace, dict) or set(workspace) != {'exit_operation_id', 'start'}
                or not is_identity(workspace['exit_operation_id'])):
            raise FenceRefused('invalid immutable workspace source')
        check_source(workspace['start'])


def managed_home():
    home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=True)
    if Path(os.environ.get('HOME', '')).resolve(strict=True) != home or not home.is_dir():
        raise FenceRefused('no-repo continuation requires this managed login home')
    return str(home)


def local_history(fid, conf_dir):
    env = dict(os.environ, FLEET_CONF_DIR=str(conf_dir))
    env.pop('FLEET_ID_DIR', None)
    result = subprocess.run([sys.executable, str(Path(__file__).with_name('fleet_history_read.py')), fid],
                            env=env, text=True, capture_output=True, timeout=20)
    if result.returncode:
        raise FenceRefused('original session history is unavailable')
    return json.loads(result.stdout)


def _opened(conf_dir, fid):
    from fleet_id import fold
    path = Path(conf_dir) / 'ids' / (fid + '.ndjson')
    # Use the existing ledger name; never an environment-selected alternate book.
    events = [json.loads(line) for line in path.read_text().splitlines()]
    if (not events or any(not isinstance(e, dict) or e.get('id') != fid
                         or type(e.get('seq')) is not int or e['seq'] != i
                         for i, e in enumerate(events, 1))):
        raise FenceRefused('original identity ledger is incomplete or inconsistent')
    if not any(e.get('ev') == 'opened' and not e.get('lazy') and e.get('task') for e in events):
        raise FenceRefused('original identity ledger has no managed task opening')
    return fold(events)['opened']


def _workspace(path, fid, task, successor=''):
    if not isinstance(path, str) or not os.path.isabs(path):
        raise FenceRefused('original worktree path is not recorded')
    wt = Path(path)
    if str(wt.resolve(strict=True)) != path or not wt.is_dir():
        raise FenceRefused('original worktree path is no longer canonical')
    def git(*args):
        result = subprocess.run(['git', '-C', path, 'rev-parse', *args],
                                text=True, capture_output=True, timeout=10)
        if result.returncode:
            raise FenceRefused('original worktree is unavailable')
        return result.stdout.strip()
    gd = Path(git('--absolute-git-dir')).resolve(strict=True)
    common = Path(git('--path-format=absolute', '--git-common-dir')).resolve(strict=True)
    if (gd == common or Path(git('--show-toplevel')).resolve(strict=True) != wt
            or (gd / 'fleet-id').read_text().strip() not in ({fid, successor} if successor else {fid})
            or (gd / 'fleet-task').read_text().strip() != task):
        raise FenceRefused('worktree identity does not match the stopped session and task')
    return path


def _initial_start(fence, expected, stopped, receipt, past, source_fid, provider):
    # The authenticated Hub chain only permits a root start at generation 1.
    # SourceStart intentionally omits continuation: its absence proves nothing.
    if stopped['binding_generation'] != 1 or stopped['generation'] != 2:
        raise FenceRefused('interrupted continuation needs exact original history; only the initial start may begin without it')
    if (not isinstance(past, dict) or past.get('history_status') != 'never_started'
            or past.get('id', source_fid) != source_fid or past.get('agent', provider) != provider
            or past.get('readable') or past.get('transcript') or past.get('native') or past.get('sid')):
        raise FenceRefused('exact original native history is unavailable; continuation needs review')
    with fence.store.connect() as db:
        db.execute('BEGIN')
        _, checked_stop, _, checked_receipt = acknowledged_native_exit(db, receipt['operation_id'])
        if checked_stop != stopped or checked_receipt != receipt:
            raise FenceRefused('original native exit changed while resolving first start')
        saved = receipt.get('continuation')
        if saved is None:
            launches = _session_exit_registrations(db, stopped, provider)
        else:
            if not isinstance(saved, dict) or set(saved) != {'snapshot', 'registrations'}:
                raise FenceRefused('first start has malformed original registration archive')
            allocated = _snapshot(saved['snapshot'])
            slot = db.execute('SELECT * FROM task_execution_sessions WHERE task_ref=?', (expected['task_ref'],)).fetchone()
            if (allocated != dict(expected, execution_owner=allocated['execution_owner'])
                    or expected['execution_owner'] not in ('', allocated['execution_owner'])
                    or fence._read(db, expected['task_ref']) != allocated
                    or slot is None or slot['operation_id'] != allocated['operation_id']
                    or slot['execution_owner'] != allocated['execution_owner']):
                raise FenceRefused('first start allocation was replaced, stopped or conflicts with this grant')
            launches = saved['registrations']
    if not isinstance(launches, list) or not launches:
        raise FenceRefused('first start has no original launch registrations')
    keys = {'task_ref', 'launch_id', 'operation_id', 'supervisor', 'wrapper', 'child', 'native', 'admission_protocol'}
    seen = set()
    for launch in launches:
        if (not isinstance(launch, dict) or set(launch) != keys
                or launch['task_ref'] != stopped['task_ref'] or launch['operation_id'] != stopped['operation_id']
                or not isinstance(launch['launch_id'], str) or not launch['launch_id'] or launch['launch_id'] in seen
                or type(launch['admission_protocol']) is not int or launch['admission_protocol'] != 1
                or launch['native'] != [] or launch['wrapper'] != receipt['payload']['proof']['wrapper']):
            raise FenceRefused('first start requires every original epoch qualified and no admitted native component')
        seen.add(launch['launch_id'])
        for key in ('supervisor', 'wrapper', 'child'):
            if _process_proof(launch[key]) != launch[key]:
                raise FenceRefused('first start has incomplete original process identity')
    _match_exit_registrations(receipt['payload']['proof'], launches)


def continuation_plan(snapshot, continuation, authority, *, conf_dir=None, history=None, home=None):
    expected = _snapshot(snapshot, allow_unclaimed=True)
    validate_metadata(expected, continuation, authority)
    actual = _snapshot(authority.get('task_execution'), allow_unclaimed=True)
    if actual != dict(expected, execution_owner=actual['execution_owner'] if not expected['execution_owner'] else expected['execution_owner']):
        raise FenceRefused('current start snapshot differs from continuation')
    expected = actual
    fence = ExecutionFence(conf_dir)
    start, source = authority['start'], authority['source_start']
    unclaimed = 'stop_operation_id' in continuation
    workspace = authority.get('workspace_source') if unclaimed else None
    if unclaimed and workspace is None:
        # First actual run: no manufactured history or guessed preclaim path.
        return dict(source_fid='', worktree='', cwd=(home or managed_home)() if source['no_repo'] else '',
                    repo=source['repo'], no_repo=source['no_repo'], seed=None)
    exit_id = workspace['exit_operation_id'] if workspace else continuation['exit_operation_id']
    if workspace:
        source = workspace['start']
    # Read only: no filesystem or authenticated network calls inside SQLite.
    with fence.store.connect() as db:
        row, stopped, result, receipt = acknowledged_native_exit(db, exit_id)
        allocation = receipt.get('continuation', {}).get('snapshot')
        if unclaimed and expected['execution_owner']:
            from fleet_task_unclaimed import RETIREMENT, retirement
            rows = db.execute("""SELECT * FROM operations WHERE action=?
                AND json_extract(request,'$.source_stop.cancel_request')=?""",
                (RETIREMENT, continuation['stop_operation_id'])).fetchall()
            if len(rows) != 1:
                raise FenceRefused('current workspace successor allocation is unavailable or ambiguous')
            saved_stop, allocation, _ = retirement(rows[0])
            if saved_stop != authority['source_stop']:
                raise FenceRefused('workspace successor names another unclaimed stop')
    distance = expected['generation'] - stopped['generation']
    if (source['operation_id'] != stopped['operation_id']
            or source['agent'] != receipt['payload']['proof']['provider']
            or not isinstance(source['repo'], str) or type(source['no_repo']) is not bool
            or source['repo'] != start.get('repo') or source['no_repo'] != start.get('no_repo')
            or expected['task_ref'] != stopped['task_ref'] or expected['task_fid'] != stopped['task_fid']
            or expected['execution_endpoint'] != stopped['execution_endpoint']
            or (distance < 3 or distance % 2 != 1 if unclaimed else distance != 1)
            or expected['cancel_request']):
        raise FenceRefused('original start and acknowledged exit do not authorize this continuation')
    source_fid = stopped['execution_owner'].split('/')[1]
    opened = _opened(fence.conf_dir, source_fid)
    if (opened.get('task') != expected['task_ref'] or opened.get('repo', '') != source['repo']
            or opened.get('agent') != source['agent']):
        raise FenceRefused('original session ledger names another task, repo or agent')
    if source['no_repo']:
        if source['repo'] or opened.get('worktree'):
            raise FenceRefused('no-repo continuation has conflicting workspace evidence')
        cwd, worktree = (home or managed_home)(), ''
    else:
        if not source['repo']:
            raise FenceRefused('original start did not explicitly identify a workspace')
        successor = ''
        if allocation and expected['execution_owner'] and allocation == expected:
            candidate = expected['execution_owner'].split('/')[1]
            try:
                new_opened = _opened(fence.conf_dir, candidate)
            except FileNotFoundError:
                new_opened = {}
            if (new_opened.get('prev') == source_fid and new_opened.get('task') == expected['task_ref']
                    and new_opened.get('repo') == source['repo']
                    and new_opened.get('worktree') == opened.get('worktree')):
                successor = candidate
        cwd = worktree = _workspace(opened.get('worktree'), source_fid, expected['task_ref'], successor)
    past = (history or local_history)(source_fid, fence.conf_dir)
    if (not isinstance(past, dict) or past.get('id') != source_fid or past.get('agent') != source['agent'] or not past.get('readable')
            or not past.get('transcript') or not Path(past['transcript']).is_file()):
        _initial_start(fence, expected, stopped, receipt, past, source_fid, source['agent'])
        seed = ('开始任务 ' + expected['task_ref'] + ' 的首次执行。\n'
                '此前启动在 Agent 执行前已停止，没有可读取的原生会话历史。'
                '这是用户明确发起的新原生会话，请读取本任务描述并核对当前文件后开始。\n'
                '原会话 FID：' + source_fid + '\n原工作目录：' + cwd + '\n'
                '保留现有工作文件和未提交修改，不恢复旧队列或定时唤醒。')
        return dict(source_fid=source_fid, worktree=worktree, cwd=cwd, repo=source['repo'],
                    no_repo=source['no_repo'], seed=seed)
    seed = ('继续任务 ' + expected['task_ref'] + '，这是用户明确发起的新原生会话。\n'
            '原会话 FID：' + source_fid + '\n原工作目录：' + cwd + '\n'
            '先读取原会话历史，核对最近用户要求、已完成工作、当前文件及下一步，再继续；'
            '历史中的旧计划、队列和定时唤醒仅作背景，不构成重新执行的授权。'
            '若历史指向交接笔记，核对它属于本任务后再读取。\n'
            '原会话历史文件：' + past['transcript'] + '\n'
            '原身份账本：' + str(fence.conf_dir / 'ids' / (source_fid + '.ndjson')) + '\n'
            '保留现有工作文件，不重做原始首句任务，不恢复原生旧会话或旧队列。')
    return dict(source_fid=source_fid, worktree=worktree, cwd=cwd, repo=source['repo'],
                no_repo=source['no_repo'], seed=seed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot', required=True)
    parser.add_argument('--dispatch', required=True)
    proof = parser.add_mutually_exclusive_group(required=True)
    proof.add_argument('--exit-operation-id')
    proof.add_argument('--stop-operation-id')
    args = parser.parse_args()
    try:
        from fleet_dispatch import check_current
        snapshot = json.loads(args.snapshot)
        continuation = dict(version=1, **({'exit_operation_id': args.exit_operation_id} if args.exit_operation_id
                                        else {'stop_operation_id': args.stop_operation_id}))
        authority = check_current(json.loads(args.dispatch), execution=snapshot, continuation=continuation)
        print(json.dumps(continuation_plan(snapshot, continuation, authority), ensure_ascii=False))
    except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError) as exc:
        print('fleet-task-continuation: ' + str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
