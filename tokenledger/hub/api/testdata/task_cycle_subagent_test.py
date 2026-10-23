#!/usr/bin/env python3
"""Offline Subagent fixture checks: synthetic RPC shapes, real bounded process.

No Coding Agent, network, credential mint, production pane or model request.
"""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[3] / 'bin'))
from fleet_task_execution import _kernel_process, FenceRefused
from task_cycle_subagent import SubagentSample, SampleRefused, spawned_child, running_tool

ROOT = '11111111-1111-4111-8111-111111111111'
CHILD = '22222222-2222-4222-8222-222222222222'


class Identity(unittest.TestCase):
    def setUp(self):
        self.call = dict(type='collabAgentToolCall', tool='spawnAgent', status='completed',
                         senderThreadId=ROOT, receiverThreadIds=[CHILD])

    def test_spawn_must_be_one_exact_completed_root_call(self):
        self.assertEqual(spawned_child(ROOT, [dict(items=[self.call])]), CHILD)
        self.assertIsNone(spawned_child(ROOT, []))
        for changes in ({'senderThreadId': CHILD}, {'receiverThreadIds': [ROOT]},
                        {'receiverThreadIds': [CHILD, CHILD]}, {'status': 'failed'}):
            with self.subTest(changes=changes), self.assertRaises(SampleRefused):
                spawned_child(ROOT, [dict(items=[dict(self.call, **changes)])])
        with self.assertRaises(SampleRefused):
            spawned_child(ROOT, [dict(items=[self.call, self.call])])

    def test_child_parent_and_actual_tool_output_are_required(self):
        child = dict(id=CHILD, parentThreadId=ROOT, status={'type': 'active'})
        item = dict(id='tool', type='commandExecution', status='inProgress',
                    command='python3 /fixture/sleep.py', aggregatedOutput='ready-exact\n')
        turns = [dict(id='turn', status='inProgress', items=[item])]
        read = lambda c, ts: running_tool(ROOT, CHILD, c, ts, '/fixture/sleep.py', 'ready-exact')
        self.assertEqual(read(child, turns)['item_id'], 'tool')
        with self.assertRaises(SampleRefused): read(dict(child, parentThreadId=CHILD), turns)
        for key, value in [('aggregatedOutput', 'ready-other'), ('command', 'python3 other.py'),
                           ('status', 'completed')]:
            changed = copy.deepcopy(turns); changed[0]['items'][0][key] = value
            self.assertIsNone(read(child, changed))
        changed = copy.deepcopy(turns); changed[0]['status'] = 'completed'
        self.assertIsNone(read(child, changed))


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='subagent-offline-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        snapshot = dict(cancel_request='stop', operation_id='start')
        self.probe = SimpleNamespace(root=self.root, manifest={'subagent': {}}, save=lambda: None,
                                    control=SimpleNamespace(execution=SimpleNamespace(read=lambda _: snapshot)))
        self.sample = SubagentSample(self.probe)
        self.sample.prompt()
        self.proc = subprocess.Popen([sys.executable, str(self.sample.script)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup)
        # The real helper writes ready before its one bounded foreground sleep.
        deadline = time.monotonic() + 3
        while not self.sample.ready.exists():
            self.assertLess(time.monotonic(), deadline)
            self.assertIsNone(self.proc.poll())
            time.sleep(.01)
        self.proof = _kernel_process(self.proc.pid)
        transcript = self.root / 'child.jsonl'; transcript.write_text('fixture history\n')
        self.sample.observed = dict(task='T1', operation_id='start', tool_process=self.proof,
                                    native_roots={'server': self.proof}, child_transcript=str(transcript),
                                    observe_until=time.monotonic()+95)

    def cleanup(self):
        if self.proc.poll() is None: self.proc.kill()
        self.proc.wait(timeout=3)
        self.proc.stdout.close(); self.proc.stderr.close()

    def test_live_tool_and_incomplete_observation_never_pass(self):
        self.sample.before_stop('T1')
        out = self.sample.after_stop('T1', 'stop')
        self.assertFalse(out['child_lifecycle_confirmed'])
        self.assertIsNone(out['tool_exit_evidence'])
        self.proc.kill(); self.proc.wait(timeout=3)
        self.assertFalse(self.sample.after_stop('T1','stop')['child_lifecycle_confirmed'])
        self.sample.observed['observe_until'] = time.monotonic()-1
        self.assertTrue(self.sample.after_stop('T1','stop')['child_lifecycle_confirmed'])
        # Completion after stop is a failed cancellation even when roots exit.
        self.sample.finished.write_text('completed anyway')
        self.assertFalse(self.sample.after_stop('T1','stop')['child_lifecycle_confirmed'])

    def test_wrong_stop_and_task_refuse(self):
        with self.assertRaises(SampleRefused): self.sample.before_stop('T2')
        self.sample.before_stop('T1')
        with self.assertRaises(SampleRefused): self.sample.after_stop('T1','different-stop')
        with self.assertRaises(SampleRefused): self.sample.before_stop('T1')

    def test_stale_birth_never_authorizes_cleanup(self):
        self.sample.observed['tool_process'] = dict(self.proof, birth='invalid')
        with self.assertRaises((FenceRefused, ValueError)): self.sample.cleanup()
        self.assertIsNone(self.proc.poll())

    def test_fallback_cleanup_is_separate_from_native_success(self):
        self.assertTrue(self.sample.cleanup())
        self.proc.wait(timeout=3)
        self.assertFalse(self.sample.cleanup())
        self.assertNotIn('child_lifecycle_confirmed', self.probe.manifest['subagent'])


if __name__ == '__main__':
    unittest.main()
