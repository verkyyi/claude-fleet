#!/usr/bin/env python3
# selftest-entry
"""Explicit local continuation: real journal, roots and repeated stop cycles."""
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from fleet_control import Control
from fleet_hub_common import canonical
import fleet_task_execution as execution

BIN = Path(__file__).resolve().parent
GRANT = json.loads((BIN.parent / 'tokenledger/hub/store/testdata/task_execution.json').read_text())
FLEET = GRANT['execution_owner'].split('/')[0]
EXIT = 'bbbbbbbb-1111-4111-8111-aaaaaaaaaaaa'
STOP = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
STOP2 = 'dddddddd-1111-4111-8111-aaaaaaaaaaaa'


class ContinuationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='task-continuation-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.control = Control(self.root)
        self.fence = self.control.execution
        self.fence.bind(GRANT, authorized=True)
        with self.fence.store.connect() as db:
            db.execute('INSERT INTO task_execution_sessions VALUES (?,?,?)',
                       ('T42', GRANT['operation_id'], GRANT['execution_owner']))
        self.fence.reserve_window(GRANT)
        self.register(GRANT, 'old-launch')
        self.stop(GRANT, STOP)
        self.confirm(STOP, EXIT)
        self.next = dict(GRANT, generation=3, binding_generation=3, attempt_id='task:T42:g3',
                         operation_id='new-start', execution_owner='')

    def register(self, grant, launch):
        proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        def cleanup():
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        self.addCleanup(cleanup)
        proof = execution._kernel_process(proc.pid)
        with self.fence.admission(grant) as permit:
            permit.reserve_launch(launch, proof, wrapper=execution._kernel_process(os.getpid()))
            permit.register_child(launch, proof)
            permit.register_native(launch, 'agent', proof)
        cleanup()

    def stop(self, grant, stop):
        req = dict(operation_id=stop, fleet_id=FLEET, action='worker_stop', actor='fixture', control_version=1,
                   task_execution=dict(grant, generation=grant['generation'] + 1, cancel_request=stop),
                   params=dict(task='T42', worker_id=grant['execution_owner'], execution_endpoint=grant['execution_endpoint'],
                               start_operation_id=grant['operation_id'], generation=grant['generation'], attempt_id=grant['attempt_id']))
        with patch('fleet_control.subprocess.Popen', return_value=Mock(wait=Mock(return_value=0))):
            self.control.submit(req)

    def confirm(self, stop, exit_id):
        ack = dict(control_version=1, scope='native_session', execution_exit_confirmed=True,
                   operation=dict(operation_id=exit_id, action='task_session_exit', status='succeeded'))
        with patch.object(self.control, 'send_native_exit', return_value=ack):
            self.assertTrue(self.control.submit_native_exit(stop))

    def journal(self, stop=STOP):
        with self.fence.store.connect() as db:
            return json.loads(db.execute('SELECT result FROM operations WHERE id=?', (stop,)).fetchone()[0])

    def test_two_cycles_keep_old_fid_stopped_and_old_proof_immutable(self):
        before = self.journal()['native_exit_receipt']['payload']
        allocated = self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True)
        self.assertNotEqual(allocated['execution_owner'], GRANT['execution_owner'])
        self.assertEqual(allocated['task_fid'], GRANT['task_fid'])
        self.assertEqual(self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True), allocated)
        old_fid = GRANT['execution_owner'].split('/')[1]
        self.assertEqual(execution.read_session(old_fid, conf_dir=self.root)['cancel_request'], STOP)
        with self.assertRaises(execution.FenceRefused):
            execution.check_session(old_fid, conf_dir=self.root)
        with self.assertRaises(execution.FenceRefused):
            execution.check_session(old_fid, conf_dir=self.root, expected=GRANT, controlled=True)
        self.assertEqual(self.fence.for_session(old_fid)['cancel_request'], STOP)
        with self.assertRaises(execution.FenceRefused):
            self.fence.assert_session_allowed(old_fid)
        self.fence.bind(allocated, authorized=True)
        self.fence.reserve_window(allocated)
        self.register(allocated, 'second-launch')
        self.stop(allocated, STOP2)
        self.confirm(STOP2, 'cccccccc-1111-4111-8111-aaaaaaaaaaaa')
        self.assertEqual(self.journal()['native_exit_receipt']['payload'], before)
        proof = self.journal(STOP2)['native_exit_receipt']['payload']['proof']
        self.assertEqual([x['launch_id'] for x in proof['launches']], ['second-launch'])
        self.assertEqual(proof['snapshot']['operation_id'], 'new-start')
        third = dict(self.next, generation=5, binding_generation=5, attempt_id='task:T42:g5', operation_id='third-start')
        successor = self.fence.continue_binding(third, FLEET, 'cccccccc-1111-4111-8111-aaaaaaaaaaaa', authorized=True)
        self.assertNotEqual(successor['execution_owner'], allocated['execution_owner'])
        for worker, stop in ((GRANT['execution_owner'], STOP), (allocated['execution_owner'], STOP2)):
            self.assertEqual(execution.read_session(worker.split('/')[1], conf_dir=self.root)['cancel_request'], stop)
        self.assertEqual(self.journal()['native_exit_receipt']['payload'], before)

    def state(self):
        with self.fence.store.connect() as db:
            tables = [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
            return {table: [tuple(row) for row in db.execute('SELECT * FROM ' + table + ' ORDER BY rowid')]
                    for table in tables}

    def refuse_unchanged(self, action):
        before = self.state()
        with self.assertRaises(execution.FenceRefused):
            action()
        self.assertEqual(self.state(), before)

    def replace_receipt(self, change):
        result = self.journal()
        change(result['native_exit_receipt'])
        with self.fence.store.connect() as db:
            db.execute('UPDATE operations SET result=? WHERE id=?', (canonical(result), STOP))

    def test_plain_bind_and_unapproved_or_wrong_grants_never_continue(self):
        claimed = dict(self.next, execution_owner=FLEET + '/33333333-3333-4333-8333-333333333333')
        self.refuse_unchanged(lambda: self.fence.bind(claimed, authorized=True))
        self.refuse_unchanged(lambda: self.fence.continue_binding(self.next, FLEET, EXIT))
        for change in ({'task_ref': 'T43', 'attempt_id': 'task:T43:g3'},
                       {'task_fid': '55555555-5555-4555-8555-555555555555'},
                       {'generation': 2, 'binding_generation': 2, 'attempt_id': 'task:T42:g2'},
                       {'generation': 4, 'binding_generation': 4, 'attempt_id': 'task:T42:g4'},
                       {'execution_endpoint': 'other-node'}, {'operation_id': GRANT['operation_id']},
                       {'operation_id': STOP}, {'cancel_request': STOP},
                       {'execution_owner': claimed['execution_owner']}):
            with self.subTest(change=change):
                self.refuse_unchanged(lambda: self.fence.continue_binding(dict(self.next, **change), FLEET, EXIT, authorized=True))
        self.refuse_unchanged(lambda: self.fence.continue_binding(self.next, FLEET, 'eeeeeeee-1111-4111-8111-aaaaaaaaaaaa', authorized=True))

    def test_ack_and_original_packet_required(self):
        original = self.journal()
        for change in (lambda r: r.pop('confirmed'), lambda r: r.update(confirmed=False),
                       lambda r: r.pop('payload'), lambda r: r.update(payload=[]),
                       lambda r: r['payload'].update(control_version=True),
                       lambda r: r['payload'].update(idempotency_key='different'),
                       lambda r: r['payload']['proof']['snapshot'].update(operation_id='wrong-start'),
                       lambda r: r['payload']['proof'].update(scope='all_descendants'),
                       lambda r: r['payload']['proof'].update(observed_at=True),
                       lambda r: r['payload']['proof'].update(observed_at=float('inf')),
                       lambda r: r['payload']['proof'].update(observed_at=10**400),
                       lambda r: r['payload']['proof'].update(launch_id='wrong-launch'),
                       lambda r: r['payload']['proof']['launches'][0]['roots'][0].update(pid=99),
                       lambda r: r['payload']['proof']['launches'][0].update(roots=[])):
            with self.fence.store.connect() as db:
                db.execute('UPDATE operations SET result=? WHERE id=?', (canonical(original), STOP))
            self.replace_receipt(change)
            self.refuse_unchanged(lambda: self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True))

    def test_unproved_or_changed_registration_is_never_retired(self):
        with self.fence.store.connect() as db:
            db.execute("UPDATE task_execution_windows SET operation_id='other'")
        self.refuse_unchanged(lambda: self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True))
        with self.fence.store.connect() as db:
            db.execute('UPDATE task_execution_windows SET operation_id=?', (GRANT['operation_id'],))
            db.execute('INSERT INTO task_execution_native VALUES (?,?,?,?)',
                       ('T42', 'unproved-orphan', 'agent', json.dumps(execution._kernel_process(os.getpid()))))
        self.refuse_unchanged(lambda: self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True))

    def test_atomic_rollback_keeps_proof_allocations_and_registration(self):
        with patch.object(self.fence, '_save', side_effect=sqlite3.OperationalError('disk full')):
            self.refuse_unchanged(lambda: self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True))
        self.assertIsNotNone(self.fence.launch('T42'))
        self.assertNotIn('continuation', self.journal()['native_exit_receipt'])

    def test_process_crash_before_commit_rolls_back_then_restart_reuses_allocation(self):
        before = self.state()
        script = '''import json,os,sys
sys.path.insert(0,sys.argv[1])
from fleet_task_execution import ExecutionFence
f=ExecutionFence(sys.argv[2])
save=f._save
def crash(db,row):
    save(db,row)
    os._exit(9)
f._save=crash
f.continue_binding(json.loads(sys.argv[3]),sys.argv[4],sys.argv[5],authorized=True)
'''
        crashed = subprocess.run([sys.executable, '-c', script, str(BIN), str(self.root), json.dumps(self.next), FLEET, EXIT],
                                 timeout=10, capture_output=True, text=True)
        self.assertEqual(crashed.returncode, 9, crashed.stderr)
        self.assertEqual(self.state(), before)
        script = '''import json,os,sys
sys.path.insert(0,sys.argv[1])
from fleet_task_execution import ExecutionFence
f=ExecutionFence(sys.argv[2])
f.continue_binding(json.loads(sys.argv[3]),sys.argv[4],sys.argv[5],authorized=True)
os._exit(9)
'''
        committed = subprocess.run([sys.executable, '-c', script, str(BIN), str(self.root), json.dumps(self.next), FLEET, EXIT],
                                   timeout=10, capture_output=True, text=True)
        self.assertEqual(committed.returncode, 9, committed.stderr)
        allocated = self.fence.read('T42')
        self.assertEqual(execution.ExecutionFence(self.root).continue_binding(self.next, FLEET, EXIT, authorized=True), allocated)
        self.fence.reserve_window(allocated)
        with self.assertRaises(execution.FenceRefused):
            self.fence.reserve_window(allocated)

    def test_new_stop_while_continuation_waits_cannot_be_cleared(self):
        started, errors = threading.Event(), []
        def proceed():
            started.set()
            try:
                self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True)
            except execution.FenceRefused as exc:
                errors.append(exc)
        with self.fence._admission_lock('T42'):
            thread = threading.Thread(target=proceed)
            thread.start()
            self.assertTrue(started.wait(timeout=5))
            # Stop persistence bypasses admission; it wins while the explicit
            # continuation waits, and must survive once that waiter proceeds.
            stopped = self.fence.request_stop('T42', STOP, generation=3)
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(errors), 1)
        self.assertEqual(self.fence.read('T42'), stopped)
        self.assertNotIn('continuation', self.journal()['native_exit_receipt'])

    def test_concurrent_same_grant_allocates_once_and_different_grant_loses(self):
        outputs, errors = [], []
        barrier = threading.Barrier(8)
        def proceed():
            try:
                fence = execution.ExecutionFence(self.root)
                barrier.wait(timeout=5)
                outputs.append(fence.continue_binding(self.next, FLEET, EXIT, authorized=True))
            except Exception as exc:
                errors.append(exc)
        threads = [threading.Thread(target=proceed) for _ in range(8)]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=10)
        self.assertFalse(errors)
        self.assertEqual(len(outputs), 8)
        self.assertEqual(len({x['execution_owner'] for x in outputs}), 1)
        self.refuse_unchanged(lambda: self.fence.continue_binding(dict(self.next, operation_id='another-start'), FLEET, EXIT, authorized=True))
        self.assertEqual(execution.ExecutionFence(self.root).continue_binding(self.next, FLEET, EXIT, authorized=True), outputs[0])

    def transport_unlocked(self):
        fd = os.open(self.root / 'control/task-admission/T42.lock', os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd)
        with self.fence.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')

    def test_fresh_authority_and_claim_network_are_outside_locks(self):
        calls = []
        def read(task):
            self.transport_unlocked()
            self.assertEqual(task, 'T42')
            calls.append('read')
            return dict(self.next)
        def claim(task, body):
            self.transport_unlocked()
            calls.append('claim')
            return dict(self.next, execution_owner=body['worker_id'])
        def stops():
            self.transport_unlocked()
            return dict(control_version=1, task_executions=[])
        result = execution.continue_execution(self.next, FLEET, EXIT, conf_dir=self.root, read=read, call=claim, read_stops=stops)
        self.assertEqual(calls, ['read', 'claim'])
        self.assertEqual(result, self.fence.read('T42'))
        # A later authenticated GET may already carry the claimed worker. The
        # original unclaimed grant retries the same allocation, never a new FID.
        again = execution.continue_execution(self.next, FLEET, EXIT, conf_dir=self.root,
                    read=lambda task: result, call=claim, read_stops=stops)
        self.assertEqual(again, result)

    def test_stale_or_unavailable_authority_does_not_retire_old_binding(self):
        before = self.state()
        with self.assertRaises(execution.FenceRefused):
            execution.continue_execution(self.next, FLEET, EXIT, conf_dir=self.root,
                read=lambda task: dict(self.next, operation_id='changed'),
                call=lambda *args: self.fail('must not claim'), read_stops=lambda: dict(control_version=1, task_executions=[]))
        self.assertEqual(self.state(), before)
        with self.assertRaises(OSError):
            execution.continue_execution(self.next, FLEET, EXIT, conf_dir=self.root,
                read=Mock(side_effect=OSError('offline')),
                call=lambda *args: self.fail('must not claim'), read_stops=lambda: dict(control_version=1, task_executions=[]))
        self.assertEqual(self.state(), before)

    def test_claim_failure_retries_allocation_and_stop_wins(self):
        stops = lambda: dict(control_version=1, task_executions=[])
        with self.assertRaises(OSError):
            execution.continue_execution(self.next, FLEET, EXIT, conf_dir=self.root,
                read=lambda task: self.next, call=Mock(side_effect=OSError('ACK lost')), read_stops=stops)
        allocated = self.fence.read('T42')
        self.assertEqual(self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True), allocated)
        claims = []
        def retry(task, body):
            claims.append(body['worker_id'])
            return dict(self.next, execution_owner=body['worker_id'])
        self.assertEqual(execution.continue_execution(self.next, FLEET, EXIT, conf_dir=self.root,
                read=lambda task: self.next, call=retry, read_stops=stops), allocated)
        self.assertEqual(claims, [allocated['execution_owner']])
        self.fence.request_stop('T42', STOP2, generation=4)
        self.refuse_unchanged(lambda: self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True))
        with self.assertRaises(execution.FenceRefused):
            self.fence.bind(allocated, authorized=True)

    def test_old_receipt_replay_and_cleanup_cannot_change_new_binding(self):
        allocated = self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True)
        before = self.journal()['native_exit_receipt']
        with patch.object(self.control, 'send_native_exit', side_effect=AssertionError('ACK already persisted')):
            self.assertTrue(self.control.submit_native_exit(STOP))
        self.control.finish(STOP, 'failed', {'error': {'code': 'NOT_FOUND'}})
        self.assertEqual(self.journal()['native_exit_receipt'], before)
        self.assertEqual(self.fence.read('T42'), allocated)
        self.assertEqual(self.fence.for_session(GRANT['execution_owner'].split('/')[1])['cancel_request'], STOP)
        with self.control.store.connect() as db:
            original = json.loads(db.execute('SELECT request FROM operations WHERE id=?', (STOP,)).fetchone()[0])
        with patch('fleet_control.subprocess.Popen', side_effect=AssertionError('old stop must not launch cleanup')):
            self.refuse_unchanged(lambda: self.control.submit(original))
        self.assertEqual(self.journal()['native_exit_receipt'], before)
        self.assertEqual(self.fence.read('T42'), allocated)

    def test_ack_already_in_flight_preserves_new_continuation(self):
        self.replace_receipt(lambda r: r.update(confirmed=False))
        sending, release = threading.Event(), threading.Event()
        results = []
        ack = dict(control_version=1, scope='native_session', execution_exit_confirmed=True,
                   operation=dict(operation_id=EXIT, action='task_session_exit', status='succeeded'))
        def delayed(task, body, timeout):
            sending.set()
            if not release.wait(timeout=5):
                raise TimeoutError('test did not release ACK')
            return ack
        first = Control(self.root)
        with patch.object(first, 'send_native_exit', side_effect=delayed):
            thread = threading.Thread(target=lambda: results.append(first.submit_native_exit(STOP)))
            thread.start()
            self.assertTrue(sending.wait(timeout=5))
            try:
                self.confirm(STOP, EXIT)
                allocated = self.fence.continue_binding(self.next, FLEET, EXIT, authorized=True)
                receipt = self.journal()['native_exit_receipt']
            finally:
                release.set()
            thread.join(timeout=5)
        self.assertEqual(results, [True])
        self.assertEqual(self.fence.read('T42'), allocated)
        self.assertEqual(self.journal()['native_exit_receipt'], receipt)


if __name__ == '__main__':
    unittest.main()
