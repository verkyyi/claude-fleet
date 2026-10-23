#!/usr/bin/env python3
# selftest-entry
"""Unclaimed continuation replaces only exact pure allocations, never launches."""
import copy
import json
from pathlib import Path
import tempfile
import fcntl
import os
import runpy
import sqlite3
import threading
import time
import unittest
from unittest.mock import patch

from fleet_control import Control
from fleet_hub_common import canonical, Fault
import fleet_task_execution as execution
import fleet_task_continuation as continuation
import fleet_dispatch as dispatch

BIN = Path(__file__).resolve().parent
GRANT = json.loads((BIN.parent / 'tokenledger/hub/store/testdata/task_execution.json').read_text())
FLEET = GRANT['execution_owner'].split('/')[0]
STOP_ID = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
FIRST = dict(GRANT, execution_owner='')
STOP = dict(FIRST, generation=2, cancel_request=STOP_ID)
NEXT = dict(FIRST, generation=3, binding_generation=3, attempt_id='task:T42:g3', operation_id='next-start')
PROOF = dict(version=1, stop_operation_id=STOP_ID)
SOURCE = dict(operation_id=FIRST['operation_id'], agent='claude', repo='owner/repo', no_repo=False)
AUTH = dict(control_version=1, task_execution=NEXT, source_stop=STOP, source_start=SOURCE,
            start=dict(operation_id=NEXT['operation_id'], agent='codex', repo='owner/repo', no_repo=False,
                       continuation=PROOF))
ENVELOPE = dict(version=1, request_id='next-start', requested_agent='codex', resolved_agent='codex',
                agent_source='explicit', task='T42', generation=3, attempt_id='task:T42:g3')


class UnclaimedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='task-unclaimed-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.control = Control(self.root)
        self.fence = self.control.execution

    def state(self):
        with self.fence.store.connect() as db:
            tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
            return {t: [tuple(r) for r in db.execute('SELECT * FROM '+t+' ORDER BY rowid')] for t in tables}

    def refuse(self, fn):
        before = self.state()
        with self.assertRaises(execution.FenceRefused):
            fn()
        self.assertEqual(self.state(), before)

    def proceed(self, grant=NEXT, stopped=STOP):
        return self.fence.continue_unclaimed(grant, FLEET, stopped, authorized=True)

    def test_strict_union_and_metadata(self):
        self.assertEqual(continuation.validate_continuation(PROOF), PROOF)
        for bad in (dict(PROOF, exit_operation_id=''), dict(PROOF, version=True),
                    dict(PROOF, stop_operation_id=None), dict(PROOF, path='/tmp')):
            with self.assertRaises(ValueError): continuation.validate_continuation(bad)
        self.assertEqual(dispatch.check_current(ENVELOPE, execution=NEXT, continuation=PROOF,
                                                read_start=lambda _: AUTH), AUTH)
        for changes in ({'source_stop': None}, {'source_stop': dict(STOP, execution_owner=GRANT['execution_owner'])},
                        {'workspace_source': {}}, {'source_stop': dict(STOP, generation=4)}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                dispatch.check_current(ENVELOPE, execution=NEXT, continuation=PROOF,
                                       read_start=lambda _: dict(AUTH, **changes))

    def test_missing_local_records_first_run_and_idempotent_allocation(self):
        first = self.proceed()
        self.assertEqual(self.proceed(), first)
        self.assertNotEqual(first['execution_owner'], GRANT['execution_owner'])
        self.assertEqual(self.fence.allocate_worker(NEXT, FLEET), first['execution_owner'])
        with self.fence.store.connect() as db:
            rows = db.execute("SELECT * FROM operations").fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['action'], 'task_unclaimed_retirement')
        self.assertEqual(rows[0]['status'], 'succeeded')
        self.assertNotEqual(rows[0]['id'], STOP_ID)
        self.assertNotIn('task_unclaimed_retirement', self.control.get_operation(rows[0]['id']).get('result', {}))

    def test_pure_allocation_retired_and_stays_stopped_across_repeated_cycles(self):
        worker = self.fence.allocate_worker(FIRST, FLEET)
        # A failed native continuation can leave a speculative local owner.
        self.fence.bind(dict(FIRST, execution_owner=worker), authorized=True)
        self.fence.apply_stop(STOP)
        claimed = self.proceed()
        retired = execution.read_session(worker.split('/')[1], conf_dir=self.root)
        self.assertEqual(retired, dict(STOP, execution_owner=worker))
        with self.assertRaises(execution.FenceRefused):
            execution.check_session(worker.split('/')[1], conf_dir=self.root)
        stopped = dict(NEXT, generation=4, cancel_request='bbbbbbbb-1111-4111-8111-aaaaaaaaaaaa')
        self.fence.apply_stop(stopped)
        third = dict(NEXT, generation=5, binding_generation=5, attempt_id='task:T42:g5', operation_id='third')
        latest = self.proceed(third, stopped)
        self.assertNotEqual(latest['execution_owner'], claimed['execution_owner'])
        self.assertEqual(execution.read_session(claimed['execution_owner'].split('/')[1], conf_dir=self.root)['cancel_request'], stopped['cancel_request'])
        self.refuse(lambda: self.proceed())

    def test_any_registration_refuses_and_preserves_evidence(self):
        for table, values in (
            ('task_execution_windows', ('T42', FIRST['operation_id'], GRANT['execution_owner'])),
            ('task_execution_launches', ('T42', 'launch', FIRST['operation_id'], '{}', '{}', '', 0)),
            ('task_execution_native', ('T42', 'launch', 'agent', '{}')),
            ('task_execution_launch_history', ('T42', 'launch', '{}'))):
            with self.subTest(table=table):
                with self.fence.store.connect() as db:
                    db.execute('INSERT INTO '+table+' VALUES ('+','.join('?' for _ in values)+')', values)
                self.refuse(lambda: self.proceed())
                with self.fence.store.connect() as db: db.execute('DELETE FROM '+table)

    def test_identity_ledger_is_not_pure_allocation(self):
        worker = self.fence.allocate_worker(FIRST, FLEET)
        path = self.root/'ids'/(worker.split('/')[1]+'.ndjson')
        path.parent.mkdir(); path.write_text('{}\n')
        self.refuse(lambda: self.proceed())
        self.assertEqual(path.read_text(), '{}\n')

    def test_unclaimed_source_must_be_exact_and_authorized(self):
        for bad in (dict(STOP, execution_owner=GRANT['execution_owner']), dict(STOP, operation_id=''),
                    dict(STOP, generation=3), dict(STOP, task_fid=''), dict(STOP, cancel_request='')):
            self.refuse(lambda: self.proceed(stopped=bad))
        self.refuse(lambda: self.fence.continue_unclaimed(NEXT, FLEET, STOP))
        self.refuse(lambda: self.proceed(dict(NEXT, execution_owner=GRANT['execution_owner'])))

    def test_first_actual_run_does_not_invent_history_or_reuse_preclaim_directories(self):
        leftover = self.root/'repo-scratch-12'; leftover.mkdir(); (leftover/'work').write_text('keep')
        plan = continuation.continuation_plan(NEXT, PROOF, AUTH, conf_dir=self.root,
                                              history=lambda *_: self.fail('no native history exists'))
        self.assertEqual(plan['source_fid'], '')
        self.assertEqual(plan['worktree'], '')
        self.assertIsNone(plan['seed'])
        self.assertEqual((leftover/'work').read_text(), 'keep')
        authority = copy.deepcopy(AUTH)
        for key in ('start', 'source_start'):
            authority[key].update(repo='', no_repo=True)
        plan = continuation.continuation_plan(NEXT, PROOF, authority, conf_dir=self.root, home=lambda: str(self.root))
        self.assertEqual(plan['cwd'], str(self.root))
        self.assertEqual(plan['worktree'], '')

    def test_offline_authority_never_allocates_from_cached_stop(self):
        self.fence.apply_stop(STOP)
        before = self.state()
        def offline(_): raise OSError('offline')
        with self.assertRaises(execution.FenceRefused):
            execution.continue_unclaimed_execution(NEXT, FLEET, PROOF, ENVELOPE, conf_dir=self.root,
                read_start=offline, read_stops=lambda: dict(control_version=1, task_executions=[]))
        self.assertEqual(self.state(), before)

    def authenticated_continue(self, **kwargs):
        return execution.continue_unclaimed_execution(NEXT, FLEET, PROOF, ENVELOPE, conf_dir=self.root,
            read_start=lambda _: AUTH, read_stops=lambda: dict(control_version=1, task_executions=[]), **kwargs)

    def test_claim_ack_loss_retries_same_fid_and_network_is_outside_locks(self):
        workers = []
        def claim(_, body):
            workers.append(body['worker_id'])
            with self.fence.store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
            fd = os.open(self.fence._locks / 'T42.lock', os.O_RDWR)
            try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally: os.close(fd)
            if len(workers) == 1: raise execution.FenceRefused('lost claim ACK')
            return dict(NEXT, execution_owner=body['worker_id'])
        with self.assertRaises(execution.FenceRefused): self.authenticated_continue(call=claim)
        claimed = self.authenticated_continue(call=claim)
        self.assertEqual(workers, [claimed['execution_owner']] * 2)

    def test_latest_stop_before_or_during_claim_refuses_without_launch(self):
        cancelled = dict(NEXT, generation=4, cancel_request='bbbbbbbb-1111-4111-8111-aaaaaaaaaaaa')
        with self.assertRaises(execution.FenceRefused):
            execution.continue_unclaimed_execution(NEXT, FLEET, PROOF, ENVELOPE, conf_dir=self.root,
                read_start=lambda _: dict(AUTH, task_execution=cancelled),
                read_stops=lambda: dict(control_version=1, task_executions=[]),
                call=lambda *_: self.fail('stale start must not claim'))
        self.assertIsNone(self.fence.read('T42'))
        with self.assertRaises(execution.FenceRefused): self.authenticated_continue(call=lambda *_: cancelled)
        self.assertEqual(self.fence.read('T42')['cancel_request'], cancelled['cancel_request'])
        self.refuse(lambda: self.proceed())

    def test_concurrent_same_request_uses_one_allocation_other_operation_refuses(self):
        results, failures = [], []
        gate = threading.Barrier(2)
        def go():
            try:
                gate.wait(); results.append(self.proceed())
            except Exception as exc: failures.append(exc)
        threads = [threading.Thread(target=go) for _ in range(2)]
        for t in threads: t.start()
        for t in threads: t.join(5); self.assertFalse(t.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(len(results), 2)
        self.assertEqual(results[0], results[1])
        self.refuse(lambda: self.proceed(dict(NEXT, operation_id='another-start')))

    def test_transaction_failure_preserves_allocation_and_stop(self):
        self.fence.allocate_worker(FIRST, FLEET)
        self.fence.apply_stop(STOP)
        before = self.state()
        with patch.object(self.fence, '_save', side_effect=sqlite3.OperationalError('disk full')):
            with self.assertRaises(execution.FenceRefused): self.proceed()
        self.assertEqual(self.state(), before)

    def test_local_record_never_replayed_and_remote_stop_keeps_exact_request(self):
        worker = self.fence.allocate_worker(FIRST, FLEET)
        self.proceed()
        with self.fence.store.connect() as db:
            record = dict(db.execute('SELECT * FROM operations').fetchone())
        with patch.object(self.control, 'adapter', side_effect=AssertionError('not an external operation')):
            self.control.execute(record['id'])
            self.assertEqual(self.control.retry_native_exits(), 0)
        request = dict(operation_id=STOP_ID, fleet_id=FLEET, action='worker_stop', actor='real-user', control_version=1,
                       task_execution=STOP, params=dict(task='T42', worker_id='', execution_endpoint=STOP['execution_endpoint'],
                       start_operation_id=FIRST['operation_id'], generation=1, attempt_id=FIRST['attempt_id']))
        with self.assertRaises(ValueError): self.control.submit(request)
        self.assertEqual(execution.read_session(worker.split('/')[1], conf_dir=self.root)['cancel_request'], STOP_ID)
        with self.fence.store.connect() as db:
            self.assertIsNone(db.execute('SELECT id FROM operations WHERE id=?', (STOP_ID,)).fetchone())
        with self.assertRaises(Fault):
            self.control.submit(dict(operation_id=record['id'], fleet_id=FLEET, action='task_unclaimed_retirement', actor='user', params={}))

    def test_delivered_stop_is_checked_and_never_rewritten(self):
        request = dict(operation_id=STOP_ID, fleet_id=FLEET, action='worker_stop', actor='real-user', control_version=1,
                       task_execution=STOP, params=dict(task='T42', worker_id='', execution_endpoint=STOP['execution_endpoint'],
                       start_operation_id=FIRST['operation_id'], generation=1, attempt_id=FIRST['attempt_id']))
        with self.control.store.connect() as db:
            db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)',
                (STOP_ID, FLEET, 'worker_stop', canonical(request), 'real-user', 'accepted', time.time(), time.time()))
        self.fence.allocate_worker(FIRST, FLEET)
        self.fence.apply_stop(STOP)
        self.proceed()
        with self.control.store.connect() as db:
            self.assertEqual(db.execute('SELECT request FROM operations WHERE id=?', (STOP_ID,)).fetchone()[0], canonical(request))
            bad = copy.deepcopy(request)
            bad['task_execution']['execution_owner'] = GRANT['execution_owner']
            bad['params']['worker_id'] = GRANT['execution_owner']
            db.execute('UPDATE operations SET request=? WHERE id=?', (canonical(bad), STOP_ID))
        self.refuse(lambda: self.proceed())

    def test_retry_rejects_old_operation_registration(self):
        allocated = self.proceed()
        with self.fence.store.connect() as db:
            db.execute('INSERT INTO task_execution_windows VALUES (?,?,?)', ('T42', FIRST['operation_id'], GRANT['execution_owner']))
        self.refuse(lambda: self.proceed())
        with self.fence.store.connect() as db:
            db.execute('UPDATE task_execution_windows SET operation_id=?,execution_owner=?', (allocated['operation_id'], allocated['execution_owner']))
        self.assertEqual(self.proceed(), allocated)

    def test_remote_controller_preserves_original_user_input_for_first_actual_run(self):
        grant = dict(NEXT, operation_id='55555555-1111-4111-8111-aaaaaaaaaaaa')
        authority = copy.deepcopy(AUTH)
        authority['task_execution'] = grant; authority['start']['operation_id'] = grant['operation_id']
        envelope = dict(ENVELOPE, request_id=grant['operation_id'])
        request = dict(operation_id=grant['operation_id'], fleet_id=FLEET, action='worker_start', actor='fixture',
                       control_version=1, task_execution=grant, params=dict(kind='new', task='T42', repo='owner/repo',
                       title='original', body='the user task, exactly once', agent='codex', dispatch=envelope, continuation=PROOF))
        with self.control.store.connect() as db:
            db.execute('INSERT INTO operations VALUES (?,?,?,?,?,?,?,?,NULL)',
                (request['operation_id'], FLEET, 'worker_start', canonical(request), 'fixture', 'accepted', time.time(), time.time()))
        actual_continue = execution.continue_unclaimed_execution
        def proceed(*args, **kwargs):
            return actual_continue(*args, **kwargs, read_start=lambda _: authority,
                read_stops=lambda: dict(control_version=1, task_executions=[]),
                call=lambda _, body: dict(grant, execution_owner=body['worker_id']))
        calls = []
        def adapter(mode, *args, **kwargs):
            calls.append(kwargs)
            return 0, ('@42\tscratch-17\t/tmp/fixture\t'+kwargs['execution']['execution_owner'].split('/')[1]+'\n').encode(), b''
        def workers(*args):
            return dict(workers=[dict(identity=self.fence.read('T42')['execution_owner'].split('/')[1], window_id='@42', agent='codex')], observed_at=time.time())
        with patch('fleet_dispatch.read_execution_start', return_value=authority), \
             patch('fleet_task_execution.continue_unclaimed_execution', side_effect=proceed), \
             patch.object(self.control, 'fleet', return_value=dict(name='fixture')), \
             patch.object(self.control, 'adapter', side_effect=adapter), \
             patch.object(self.control, 'workers', side_effect=workers), patch.object(self.control, 'watch_ready'):
            self.control._execute_once(request['operation_id'])
        self.assertEqual(len(calls), 1, self.control.get_operation(request['operation_id']))
        self.assertIn(b'the user task, exactly once', calls[0]['payload'])
        self.assertEqual(calls[0]['continuation'], PROOF)
        with patch('fleet_control.run', return_value=(0, b'', b'')) as run:
            self.control.adapter('start', 'fixture', 'new', execution=grant, continuation=PROOF)
        self.assertEqual(run.call_args.kwargs['env']['FLEET_TASK_CONTINUATION_STOP'], STOP_ID)
        self.assertNotIn('FLEET_TASK_CONTINUATION', run.call_args.kwargs['env'])


workspace_base = runpy.run_path(str(BIN / 'fleet-task-continuation-start-selftest.py'))


class WorkspaceTests(unittest.TestCase):
    git = workspace_base['ContinuationStartTests'].git
    write_ledger = workspace_base['ContinuationStartTests'].write_ledger
    test_real_raw_spawner = workspace_base['ContinuationStartTests'].test_real_raw_spawner_keeps_workspace_history_and_only_deduplicates_new_fid

    def setUp(self):
        workspace_base['ContinuationStartTests'].setUp(self)
        first = self.grant
        self.base.fence.continue_binding(first, FLEET, workspace_base['EXIT'], authorized=True)
        self.proof = dict(PROOF, stop_operation_id='dddddddd-1111-4111-8111-aaaaaaaaaaaa')
        self.unclaimed_stop = dict(first, generation=4, cancel_request=self.proof['stop_operation_id'])
        self.base.fence.apply_stop(self.unclaimed_stop)
        self.grant = dict(first, generation=5, binding_generation=5, attempt_id='task:T42:g5',
                          operation_id='66666666-1111-4111-8111-aaaaaaaaaaaa')
        self.envelope = dict(workspace_base['ENVELOPE'], request_id=self.grant['operation_id'], generation=5, attempt_id=self.grant['attempt_id'])
        self.authority = dict(control_version=1, task_execution=self.grant,
            start=dict(operation_id=self.grant['operation_id'], agent='codex', repo='owner/repo', no_repo=False, continuation=self.proof),
            source_start=dict(operation_id=first['operation_id'], agent='codex', repo='owner/repo', no_repo=False),
            source_stop=self.unclaimed_stop,
            workspace_source=dict(exit_operation_id=workspace_base['EXIT'], start=SOURCE))

    def plan(self):
        return continuation.continuation_plan(self.grant, self.proof, self.authority, conf_dir=self.root, history=lambda *_: self.past)

    def test_workspace_comes_from_genuine_native_provider_not_unclaimed_choice(self):
        plan = self.plan()
        self.assertEqual(plan['worktree'], str(self.wt))
        self.assertEqual(plan['source_fid'], workspace_base['OLD_FID'])
        self.assertIn(str(self.transcript), plan['seed'])
        self.authority['workspace_source']['start']['agent'] = 'codex'
        with self.assertRaises(execution.FenceRefused): self.plan()

    def test_local_raw_spawner_claims_unclaimed_authority_and_retries_without_second_window(self):
        self.raw_local_unclaimed = True
        self.test_real_raw_spawner()

    def test_local_first_actual_run_preserves_task_input_and_unrelated_old_workspace(self):
        # No node start/stop journal or real source session for this Task. The
        # remaining directory belongs to an unrelated old session, never adopted.
        with self.base.fence.store.connect() as db:
            for table in ('operations', 'task_execution_fences', 'task_execution_sessions'):
                db.execute('DELETE FROM '+table)
        self.opened['task'] = 'T7'; self.write_ledger()
        (self.gd/'fleet-task').write_text('T7\n')
        self.grant = NEXT
        self.envelope = ENVELOPE
        self.authority = copy.deepcopy(AUTH)
        self.raw_local_unclaimed = self.raw_fresh = True
        self.test_real_raw_spawner()

    def test_first_actual_native_can_stop_and_continue_again(self):
        claimed = execution.continue_unclaimed_execution(self.grant,FLEET,self.proof,self.envelope,
            conf_dir=self.root,read_start=lambda _:self.authority,
            read_stops=lambda:dict(control_version=1,task_executions=[]),
            call=lambda _,body:dict(self.grant,execution_owner=body['worker_id']))
        self.base.fence.reserve_window(claimed)
        self.base.register(claimed, 'new-real-launch')
        stop = 'eeeeeeee-1111-4111-8111-aaaaaaaaaaaa'
        exit_id = 'ffffffff-1111-4111-8111-aaaaaaaaaaaa'
        self.base.stop(claimed, stop)
        self.base.confirm(stop, exit_id)
        proof = self.base.journal(stop)['native_exit_receipt']['payload']['proof']
        self.assertEqual(proof['snapshot']['operation_id'], self.grant['operation_id'])
        self.assertEqual([x['launch_id'] for x in proof['launches']], ['new-real-launch'])
        latest = dict(self.grant, generation=7, binding_generation=7, attempt_id='task:T42:g7', operation_id='final-start')
        next_session = self.base.fence.continue_binding(latest, FLEET, exit_id, authorized=True)
        self.assertNotEqual(next_session['execution_owner'], claimed['execution_owner'])

    def test_workspace_missing_ack_or_wrong_task_or_generation_refuses(self):
        for changes in ({'exit_operation_id': 'eeeeeeee-1111-4111-8111-aaaaaaaaaaaa'},
                        {'start': dict(SOURCE, operation_id='unrelated')}):
            old = copy.deepcopy(self.authority)
            self.authority['workspace_source'].update(changes)
            with self.assertRaises(execution.FenceRefused): self.plan()
            self.authority = old
        self.transcript.unlink()
        with self.assertRaises(execution.FenceRefused): self.plan()


if __name__ == '__main__':
    unittest.main()
