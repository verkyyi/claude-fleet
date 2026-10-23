#!/usr/bin/env python3
# selftest-entry
"""Claimed initial launch: real exited roots, exact worktree, no invented history."""
import copy
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest.mock import patch

import fleet_task_execution as execution
import fleet_task_continuation as continuation

BIN = Path(__file__).resolve().parent
fixture = runpy.run_path(str(BIN / 'fleet-task-continuation-start-selftest.py'))
GRANT, FLEET, EXIT = (fixture[k] for k in ('GRANT', 'FLEET', 'EXIT'))


def partial_register(case, grant, launch, *, native_epoch='', legacy_epoch=''):
    # Two real, reaped epochs prove that a clean last epoch cannot hide history.
    for suffix in ('-first', '-last'):
        proc = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        def cleanup(proc=proc):
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        case.addCleanup(cleanup)
        root = execution._kernel_process(proc.pid)
        with case.fence.admission(grant) as permit:
            permit.reserve_launch(launch + suffix, root,
                                  wrapper=execution._kernel_process(os.getpid()),
                                  admission_protocol=0 if suffix == legacy_epoch else 1)
            permit.register_child(launch + suffix, root)
            if suffix == native_epoch:
                permit.register_native(launch + suffix, 'agent', root)
        cleanup()


class FirstStartTests(unittest.TestCase):
    def setUp(self):
        self.case = fixture['ContinuationStartTests']()
        self.addCleanup(self.case.doCleanups)
        with patch.object(fixture['base']['ContinuationTests'], 'register', partial_register):
            self.case.setUp()
        self.case.transcript.unlink()
        self.case.past = dict(history_status='never_started', reason='No recorded native segment')

    def unchanged(self):
        self.assertEqual((self.case.wt / 'existing.txt').read_text(), 'unfinished user work\n')

    def refuse(self):
        before = self.case.base.state()
        with self.assertRaises((ValueError, OSError)):
            self.case.plan()
        self.assertEqual(before, self.case.base.state())
        self.unchanged()

    def allocate(self):
        grant = self.case.base.fence.continue_binding(self.case.grant, FLEET, EXIT, authorized=True)
        self.case.grant = grant
        self.case.authority['task_execution'] = grant
        return grant

    def test_initial_claimed_partial_begins_first_run_in_exact_workspace(self):
        plan = self.case.plan()
        self.assertEqual(plan['worktree'], str(self.case.wt))
        self.assertEqual(plan['source_fid'], fixture['OLD_FID'])
        self.assertIn('首次执行', plan['seed'])
        self.assertIn('T42', plan['seed'])
        self.assertNotIn(str(self.case.transcript), plan['seed'])
        self.assertNotIn('先读取原会话历史', plan['seed'])
        self.assertNotIn('continuation', self.case.base.journal()['native_exit_receipt'])
        self.unchanged()

    def test_controller_uses_explicit_first_start_seed(self):
        self.case.claimed_first_start = True
        self.case.test_controller_continues_with_fresh_seed_same_workspace_and_new_fid()

    def test_real_spawner_preserves_workspace_with_first_start_seed(self):
        # Real raw spawner, git and history reader; fake tmux and Hub transport.
        self.case.claimed_first_start = True
        self.case.test_real_raw_spawner_keeps_workspace_history_and_only_deduplicates_new_fid()
        self.unchanged()

    def test_allocation_retry_reuses_archived_proof_without_new_allocation(self):
        before = self.case.plan()
        payload = self.case.base.journal()['native_exit_receipt']['payload']
        self.allocate()
        state = self.case.base.state()
        self.assertEqual(self.case.plan(), before)
        self.assertEqual(self.case.plan(), before)
        self.assertEqual(state, self.case.base.state())
        self.assertEqual(payload, self.case.base.journal()['native_exit_receipt']['payload'])
        self.unchanged()

    def test_replaced_or_stopped_allocation_refuses_archived_first_start(self):
        self.allocate()
        with self.case.base.fence.store.connect() as db:
            db.execute("UPDATE task_execution_fences SET cancel_request='new-stop' WHERE task_ref='T42'")
        self.refuse()

    def test_current_unknown_protocol_missing_child_and_orphan_refuse(self):
        for sql in (
            "UPDATE task_execution_launches SET admission_protocol=0",
            "UPDATE task_execution_launches SET child=''",
            "UPDATE task_execution_launches SET operation_id='different-start'",
            "INSERT INTO task_execution_native SELECT task_ref,'orphan','agent',supervisor FROM task_execution_launches",
        ):
            with self.subTest(sql=sql):
                with self.case.base.fence.store.connect() as db:
                    db.execute(sql)
                self.refuse()
                # Each subcase gets a new real fixture, avoiding repaired fake proof.
                self.case.doCleanups()
                self.setUp()

    def test_archived_old_protocol_slots_missing_child_and_identity_refuse(self):
        self.allocate()
        original = self.case.base.journal()['native_exit_receipt']
        for mutation in (
            lambda r: r[0].update(admission_protocol=0),
            lambda r: r[0].pop('admission_protocol'),
            lambda r: r[0].update(child=None),
            lambda r: r[0].update(operation_id='other-start'),
            lambda r: r[0].update(native=[dict(component='agent', process=r[0]['child'])]),
            lambda r: r.pop(0),
            lambda r: r.append(copy.deepcopy(r[0])),
        ):
            changed = copy.deepcopy(original)
            mutation(changed['continuation']['registrations'])
            self.case.base.replace_receipt(lambda r: (r.clear(), r.update(changed)))
            self.refuse()
        self.case.base.replace_receipt(lambda r: (r.clear(), r.update(original)))
        self.assertIn('首次执行', self.case.plan()['seed'])

    def test_old_epoch_unknown_protocol_cannot_hide_behind_clean_last_epoch(self):
        with self.case.base.fence.store.connect() as db:
            row = db.execute('SELECT launch_id,registration FROM task_execution_launch_history').fetchone()
            old = json.loads(row['registration']); old.pop('admission_protocol')
            db.execute('UPDATE task_execution_launch_history SET registration=? WHERE launch_id=?',
                       (json.dumps(old), row['launch_id']))
        self.refuse()

    def test_real_ack_with_any_admitted_native_epoch_refuses_first_start(self):
        for native_epoch, legacy_epoch in (('-first', ''), ('-last', ''), ('-first', '-first')):
            with self.subTest(native=native_epoch, legacy=legacy_epoch):
                self.case.doCleanups()
                self.case = fixture['ContinuationStartTests']()
                self.addCleanup(self.case.doCleanups)
                def register(case, grant, launch):
                    partial_register(case, grant, launch, native_epoch=native_epoch, legacy_epoch=legacy_epoch)
                with patch.object(fixture['base']['ContinuationTests'], 'register', register):
                    self.case.setUp()
                self.case.past = dict(history_status='never_started')
                self.assertTrue(self.case.base.journal()['native_exit_receipt']['confirmed'])
                self.refuse()

    def test_unknown_or_contradictory_history_never_becomes_first_run(self):
        for past in ({}, dict(history_status='offline_unknown'),
                     dict(history_status='never_started', id='other'),
                     dict(history_status='never_started', agent='codex'),
                     dict(history_status='never_started', transcript='/missing'),
                     dict(history_status='never_started', readable=True)):
            self.case.past = past
            self.refuse()

    def test_exact_history_continuation_keeps_existing_seed(self):
        self.case.transcript.write_text('verified previous conversation\n')
        self.case.past = dict(id=fixture['OLD_FID'], agent='claude', readable=True,
                              transcript=str(self.case.transcript))
        plan = self.case.plan()
        self.assertIn('先读取原会话历史', plan['seed'])
        self.assertNotIn('首次执行', plan['seed'])

    def test_real_history_reader_and_read_failure(self):
        self.assertEqual(continuation.local_history(fixture['OLD_FID'], self.case.root)['history_status'], 'never_started')
        plan = continuation.continuation_plan(self.case.grant, fixture['CONTINUATION'], self.case.authority,
                                             conf_dir=self.case.root)
        self.assertIn('首次执行', plan['seed'])
        with patch.object(continuation, 'local_history', side_effect=OSError('unavailable')), self.assertRaises(OSError):
            continuation.continuation_plan(self.case.grant, fixture['CONTINUATION'], self.case.authority,
                                           conf_dir=self.case.root)
        self.unchanged()

    def test_no_repo_first_start_uses_managed_home(self):
        for source in ('start', 'source_start'):
            self.case.authority[source].update(repo='', no_repo=True)
        self.case.opened.pop('repo'); self.case.opened.pop('worktree'); self.case.write_ledger()
        plan = self.case.plan(home=lambda: str(self.case.root))
        self.assertEqual(plan['cwd'], str(self.case.root))
        self.assertEqual(plan['worktree'], '')
        self.assertIn('首次执行', plan['seed'])

    def test_symlink_workspace_and_wrong_archive_roots_refuse(self):
        link = self.case.root / 'alias'
        link.symlink_to(self.case.wt, target_is_directory=True)
        self.case.opened['worktree'] = str(link); self.case.write_ledger()
        self.refuse()
        self.case.opened['worktree'] = str(self.case.wt); self.case.write_ledger()
        self.allocate()
        self.case.base.replace_receipt(lambda r: r['continuation']['registrations'][0]['child'].update(pid=999999))
        self.refuse()

    def test_workspace_task_provider_and_ledger_identity_still_required(self):
        self.case.test_workspace_and_ledger_mismatch_refuse_without_mutation()
        self.case.test_source_facts_and_ack_required()
        self.unchanged()

    def test_second_interrupted_continuation_without_history_refuses(self):
        allocated = self.allocate()
        self.case.base.fence.reserve_window(allocated)
        partial_register(self.case.base, allocated, 'second')
        stop, exit_id = 'dddddddd-1111-4111-8111-aaaaaaaaaaaa', 'cccccccc-1111-4111-8111-aaaaaaaaaaaa'
        self.case.base.stop(allocated, stop)
        self.case.base.confirm(stop, exit_id)
        fid = allocated['execution_owner'].split('/')[1]
        opened = dict(self.case.opened, id=fid, prev=fixture['OLD_FID'])
        (self.case.root / 'ids' / (fid + '.ndjson')).write_text(json.dumps(opened) + '\n')
        (self.case.gd / 'fleet-id').write_text(fid + '\n')
        next_grant = dict(allocated, generation=5, binding_generation=5, attempt_id='task:T42:g5',
                          operation_id='third-start', execution_owner='')
        cont = dict(version=1, exit_operation_id=exit_id)
        authority = dict(self.case.authority, task_execution=next_grant,
                         start=dict(self.case.authority['start'], operation_id='third-start', continuation=cont),
                         source_start=dict(self.case.authority['source_start'], operation_id=allocated['operation_id']))
        with self.assertRaisesRegex(ValueError, 'history|first|initial'):
            continuation.continuation_plan(next_grant, cont, authority, conf_dir=self.case.root,
                                           history=lambda *_: self.case.past)
        self.unchanged()


if __name__ == '__main__':
    unittest.main()
