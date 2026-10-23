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
from fleet_task_execution import ExecutionFence, FenceRefused, _snapshot
from fleet_task_exit_submit import acknowledged_native_exit


def validate_continuation(value):
    if (not isinstance(value, dict) or set(value) != {'version', 'exit_operation_id'}
            or type(value.get('version')) is not int or value['version'] != 1
            or not is_identity(value.get('exit_operation_id'))):
        raise FenceRefused('continuation requires version 1 and an exact exit operation ID')
    return value


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


def continuation_plan(snapshot, continuation, authority, *, conf_dir=None, history=None, home=None):
    expected = _snapshot(snapshot, allow_unclaimed=True)
    validate_continuation(continuation)
    actual = _snapshot(authority.get('task_execution'), allow_unclaimed=True)
    if actual != dict(expected, execution_owner=actual['execution_owner'] if not expected['execution_owner'] else expected['execution_owner']):
        raise FenceRefused('current start snapshot differs from continuation')
    fence = ExecutionFence(conf_dir)
    # Read only: no filesystem or authenticated network calls inside SQLite.
    with fence.store.connect() as db:
        row, stopped, result, receipt = acknowledged_native_exit(db, continuation['exit_operation_id'])
    start, source = authority.get('start'), authority.get('source_start')
    if (not isinstance(start, dict) or start.get('continuation') != continuation
            or start.get('operation_id') != expected['operation_id']
            or not isinstance(source, dict) or set(source) != {'operation_id', 'agent', 'repo', 'no_repo'}
            or source['operation_id'] != stopped['operation_id']
            or source['agent'] != receipt['payload']['proof']['provider']
            or not isinstance(source['repo'], str) or type(source['no_repo']) is not bool
            or source['repo'] != start.get('repo') or source['no_repo'] != start.get('no_repo')
            or expected['task_ref'] != stopped['task_ref'] or expected['task_fid'] != stopped['task_fid']
            or expected['execution_endpoint'] != stopped['execution_endpoint']
            or expected['generation'] != stopped['generation'] + 1 or expected['cancel_request']):
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
        allocation = receipt.get('continuation', {}).get('snapshot')
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
        raise FenceRefused('exact original native history is unavailable; continuation needs review')
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
    parser.add_argument('--exit-operation-id', required=True)
    args = parser.parse_args()
    try:
        from fleet_dispatch import check_current
        snapshot = json.loads(args.snapshot)
        continuation = dict(version=1, exit_operation_id=args.exit_operation_id)
        authority = check_current(json.loads(args.dispatch), execution=snapshot, continuation=continuation)
        print(json.dumps(continuation_plan(snapshot, continuation, authority), ensure_ascii=False))
    except (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError) as exc:
        print('fleet-task-continuation: ' + str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
