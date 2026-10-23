#!/usr/bin/env python3
"""Ownership refusal tests: real isolated control DB, no native tool execution."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import fleet_native_cancel as cancel
from fleet_native_proc import process
from fleet_task_execution import ExecutionFence


class Ownership(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='native-cancel-owner-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.conf = self.root / 'conf'
        self.registry = self.root / 'sessions'
        self.registry.mkdir()
        self.project = self.root / 'project'
        (self.project / '.claude').mkdir(parents=True)
        self.sid = '22222222-2222-4222-8222-222222222222'
        self.launch = '33333333-3333-4333-8333-333333333333'
        self.grant = dict(task_ref='T970', task_fid='44444444-4444-4444-8444-444444444444',
            generation=1, binding_generation=1, attempt_id='task:T970:g1', operation_id='start-fixture',
            execution_endpoint='fixture', execution_owner='55555555-5555-4555-8555-555555555555/'
            + '66666666-6666-4666-8666-666666666666', cancel_request='')
        self.fence = ExecutionFence(self.conf)
        self.fence.bind(self.grant, authorized=True)
        self.process = process(os.getpid())
        with self.fence.admission(self.grant) as permit:
            permit.reserve_launch(self.launch, self.process)
            permit.register_child(self.launch, self.process)
            permit.register_native(self.launch, 'agent', self.process)
        self.stopped = dict(self.grant, generation=2, cancel_request='stop-fixture')
        self.fence.apply_stop(self.stopped)
        self.identity = self.registry / (str(os.getpid()) + '.json')
        self.identity.write_text(json.dumps(dict(sessionId=self.sid, cwd=str(self.project))))
        start = subprocess.check_output(['ps', '-p', str(os.getpid()), '-o', 'lstart='],
            env=dict(os.environ, TZ='UTC', LC_ALL='C'), text=True).strip()
        self.own = dict(id='1234abcd', cron='7 1 1 1 *', prompt='owned fixture', createdAt=1,
            createdBySessionId=self.sid, createdByPid=os.getpid(), createdByProcStart=start,
            createdInProject=str(self.project))
        self.foreign = dict(self.own, id='5678abcd', createdBySessionId='77777777-7777-4777-8777-777777777777')
        self.table = self.project / '.claude/scheduled_tasks.json'
        self.save_table()
        self.request = dict(cancel='native.cancel.v1', nonce='a' * 32, execution=self.stopped,
            launch_id=self.launch, session_id=self.sid, deadline=time.time() + 2.9, cron_ids=['1234abcd'])
        self.payload = dict(request=self.request, session_id=self.sid, project=str(self.project),
                            ids=['1234abcd'], expected={})

    def save_table(self):
        self.table.write_text(json.dumps(dict(tasks=[self.own, self.foreign])))

    def verify(self, payload=None):
        return cancel.verify(payload or self.payload, conf_dir=self.conf, registry_dir=self.registry)

    def test_exact_stopped_root_verifies_without_mutating_anything(self):
        files = {p: p.read_bytes() for p in (self.table, self.identity)}
        before = self.fence.read('T970')
        result = self.verify()
        self.assertEqual(result['present_ids'], ['1234abcd'])
        self.assertEqual(set(result['evidence']), {'1234abcd'})
        self.assertEqual(self.fence.read('T970'), before)
        self.assertEqual({p: p.read_bytes() for p in files}, files)

    def test_other_session_same_project_is_refused(self):
        self.request['cron_ids'] = self.payload['ids'] = [self.foreign['id']]
        with self.assertRaisesRegex(ValueError, 'another session'):
            self.verify()

    def test_session_only_absent_or_ambiguous_plan_is_refused(self):
        self.request['cron_ids'] = self.payload['ids'] = ['abcdef12']
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            self.verify()
        self.request['cron_ids'] = self.payload['ids'] = [self.own['id']]
        self.table.write_text(json.dumps(dict(tasks=[self.own, self.own])))
        with self.assertRaisesRegex(ValueError, 'ambiguous'):
            self.verify()

    def test_owner_pid_birth_project_or_session_change_refuses(self):
        for key, value in [('createdByPid', 1), ('createdByProcStart', 'old'),
                           ('createdInProject', str(self.root)), ('createdBySessionId', 'old')]:
            with self.subTest(key=key):
                old = self.own[key]
                self.own[key] = value
                self.save_table()
                with self.assertRaises(ValueError):
                    self.verify()
                self.own[key] = old

    def test_resource_modified_since_preflight_refuses(self):
        proof = self.verify()
        self.payload['expected'] = proof['evidence']
        self.own['prompt'] = 'changed after preflight'
        self.save_table()
        with self.assertRaisesRegex(ValueError, 'changed after preflight'):
            self.verify()

    def test_active_stale_generation_launch_and_native_session_refuse(self):
        for field, value in [('execution', self.grant), ('launch_id', self.sid), ('session_id', self.launch)]:
            payload = copy.deepcopy(self.payload)
            payload['request'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(payload)
        self.fence.request_stop('T970', 'stop-fixture', generation=3)
        with self.assertRaises(ValueError):
            self.verify()

    def test_deadline_unknown_fields_and_task_ids_refuse(self):
        for update in [dict(deadline=time.time() - 1), dict(deadline=time.time() + 4),
                       dict(deadline=float('nan')), dict(tool='Bash'), dict(task_ids=['other'])]:
            payload = copy.deepcopy(self.payload)
            payload['request'].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError):
                self.verify(payload)

    def test_registration_change_during_read_refuses(self):
        original = cancel.read_json
        def changed(path):
            result = original(path)
            if path == self.table:
                self.fence.request_stop('T970', 'stop-fixture', generation=3)
            return result
        with patch.object(cancel, 'read_json', side_effect=changed), self.assertRaises(ValueError):
            self.verify()

    def test_unrelated_live_process_is_not_the_callers_root(self):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)'])
        try:
            proof = process(child.pid)
            with self.assertRaisesRegex(ValueError, 'not inside'):
                cancel.own_root(dict(pid=proof['pid'], birth=proof['birth']))
        finally:
            child.terminate()
            child.wait(timeout=3)


if __name__ == '__main__':
    unittest.main()
