#!/usr/bin/env python3
# selftest-entry
"""Load governance regressions; no live fleet, processes or network."""
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_worker_life as life


class LoadGovernance(unittest.TestCase):
    def test_mac_population_corrects_extreme_load_only(self):
        script = '. "$1/fleet-lib.sh"; _fleet_load_hard_limit 5 2084 9784 15 Darwin'
        p = subprocess.run(['bash', '-c', script, '_', str(BIN)], capture_output=True, text=True,
                           env=dict(os.environ, FLEET_SKIP_GLOBAL_CONF='1'))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertGreater(float(p.stdout), 6)
        self.assertLessEqual(float(p.stdout), 15)

    def test_admission_and_panel_reason_use_corrected_ceiling(self):
        with tempfile.TemporaryDirectory() as d:
            env = dict(PATH=os.environ['PATH'], HOME=d, TMPDIR=d, FLEET_CONF_DIR=d,
                       FLEET_SKIP_GLOBAL_CONF='1', FLEET_MEM_TOTAL_MB='16000',
                       FLEET_MEM_PS_CMD='true', FLEET_MEM_PROBE_CMD='echo 1 66 0 0')
            script = '''. "$1/fleet-lib.sh"
uname() { echo Darwin; }
_fleet_admit_cpu() { :; }
_fleet_load_population() { echo '2084 9784 15'; }
load_value=$2; busy_value=$3
_fleet_load_per_core() { echo "$load_value"; }
_fleet_cpu_busy() { echo "$busy_value"; }
fleet_machine_admit --short
'''
            for load, busy, rc, reason in [('6', '.63', 0, ''), ('16', '.63', 1, '上限 15.00'), ('6', '.92', 1, 'CPU 92%')]:
                p = subprocess.run(['bash', '-c', script, '_', str(BIN), load, busy], env=env, capture_output=True, text=True)
                self.assertEqual(p.returncode, rc, p.stderr + p.stdout)
                self.assertIn(reason, p.stdout)

    def test_failed_native_turn_is_quiet_but_active_tool_is_not(self):
        thread = dict(id='sid', cwd='/tmp', path='/tmp/rollout', status=dict(type='systemError'),
                      turns=[dict(id='turn', status='failed', items=[])])
        class Client:
            def call(self, method, args):
                return {'thread': thread} if method == 'thread/read' else {'goal': None} if method == 'thread/goal/get' else {'data': ['sid']}
        source = dict(session_id='sid', worktree='/tmp', transcript='/tmp/rollout')
        self.assertEqual(life.codex_idle_turn(Client(), source)['id'], 'turn')
        thread['turns'][0]['items'] = [dict(status='inProgress')]
        with self.assertRaises(ValueError):
            life.codex_idle_turn(Client(), source)

    def test_long_dispatch_rejected_before_record(self):
        with tempfile.TemporaryDirectory() as d:
            p = subprocess.run(['bash', str(BIN/'fleet-task-record.sh'), 'dispatch', '--title', '测'*65],
                               env=dict(os.environ, HOME=d, FLEET_CONF_DIR=d, FLEET_SKIP_GLOBAL_CONF='1'),
                               capture_output=True, text=True)
            self.assertEqual(p.returncode, 2, p.stderr)
            self.assertIn('64', p.stderr)

    def test_node_runner_is_capped_including_explicit_high_limit(self):
        with tempfile.TemporaryDirectory() as d:
            node = Path(d)/'node'
            node.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
            node.chmod(0o755)
            env = dict(os.environ, PATH=str(BIN/'test-shim')+':'+d+':/usr/bin:/bin', FLEET_HEAVY='0', FLEET_SKIP_GLOBAL_CONF='1')
            p = subprocess.run([str(BIN/'test-shim/node'), '/repo/node_modules/vitest/vitest.mjs', 'run', '--maxWorkers=32'],
                               env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn('--maxWorkers=2', p.stdout)
            self.assertNotIn('--maxWorkers=32', p.stdout)

    def test_retry_restarts_entire_proof_and_never_masks_unknown(self):
        with patch.object(life, '_child_busy', side_effect=[TimeoutError(), []]) as probe:
            self.assertEqual(life.child_busy('isolated', '@1', reap=True), [])
            self.assertEqual([c.args[-1] for c in probe.call_args_list], [2, 5])
        with patch.object(life, '_child_busy', side_effect=ValueError('active')) as probe:
            with self.assertRaises(ValueError):
                life.child_busy('isolated', '@1', reap=True)
            self.assertEqual(probe.call_count, 1)
        with patch.object(life, '_child_busy', side_effect=TimeoutError()):
            with self.assertRaises(TimeoutError):
                life.child_busy('isolated', '@1', reap=True)

    def test_codex_source_uses_cached_binding_without_transfer_shell(self):
        from unittest.mock import Mock
        worker = object.__new__(life.Worker)
        worker.pane, worker.session = '%1', 'isolated'
        worker.opt = Mock(side_effect=lambda key: 'codex' if key == '@cc_agent' else '/tmp')
        binding = dict(session_id='sid', owner='42')
        with patch.dict(life.TRANSFER, thread_source=lambda a: ['42', 'sid', '/tmp', '/tmp/rollout', '']), \
                patch.dict(life.CODEX, identity=lambda *a: binding), patch.object(life, 'run') as shell:
            source = worker.inspect()
            self.assertEqual((source['pid'], source['session_id']), (42, 'sid'))
            shell.assert_not_called()
            binding['session_id'] = 'changed'
            with self.assertRaisesRegex(ValueError, 'binding changed'):
                worker.inspect()

    def test_test_runner_preserves_serial_and_smaller_limits(self):
        bounded = runpy.run_path(str(BIN/'fleet-test-runner.py'))['bounded']
        self.assertIn('--maxWorkers=1', bounded(['node', '/vitest/vitest.mjs', '--maxWorkers', '1']))
        serial = bounded(['node', '/jest/bin/jest.js', '--runInBand'])
        self.assertNotIn('--maxWorkers=2', serial)
        self.assertIn('--maxWorkers=2', bounded(['node', '/jest/bin/jest.js', '--maxWorkers=100%']))

    def test_unknown_probe_and_draft_never_authorize_park(self):
        import fleet_session_gate as gate
        w = dict(agent='codex', sock='isolated', win='@1')
        with patch.dict(os.environ, {}, clear=True), patch.object(life, 'child_busy', side_effect=TimeoutError()):
            self.assertEqual(gate.park_background(w), 'bg_probe_timeout')
        with patch.dict(os.environ, {}, clear=True), patch.object(life, 'child_busy', return_value=[99]):
            self.assertEqual(gate.park_background(w), 'bg')
        with patch.object(gate, '_park_native_input', side_effect=[dict(ok=False, why='probe_timeout'), dict(ok=False, why='draft')]) as probe:
            self.assertEqual(gate.park_native_input(w), dict(ok=False, why='draft'))
            self.assertEqual(probe.call_count, 2)


if __name__ == '__main__':
    unittest.main()
