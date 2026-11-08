#!/usr/bin/env python3
# selftest-entry
"""Stale Claude work and stage-specific park refusals, with no live fleet."""
import os
import runpy
import socket
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleet_session_gate as gate
import fleet_worker_life as life
import fleet_reap_policy as policy


class Followup(unittest.TestCase):
    def test_script_operand_does_not_misread_shell_syntax(self):
        scripts = runpy.run_path(str(life.BIN / 'fleet-preview.py'))['command_scripts']
        self.assertEqual(scripts(['sh', '-c', 'node /tmp/app.mjs; wait']), [Path('/tmp/app.mjs')])
        self.assertEqual(scripts(['sh', '-c', 'node "$SCRIPT"']), [])
        self.assertEqual(scripts(['node', '-e', 'console.log(1)']), [])

    def test_stale_claude_shell(self):
        with tempfile.TemporaryDirectory() as d:
            transcript = Path(d) / 'session.jsonl'
            transcript.write_text('old output')
            os.utime(transcript, (100, 100))
            worker = Mock()
            worker.opt.side_effect = lambda k: {'@claude_state_ts': '100', '@cc_sid': 'sid'}.get(k, '')
            worker.inspect.return_value = dict(agent='claude', pid=42, transcript=str(transcript))
            with patch.object(life, 'Worker', return_value=worker), \
                    patch.object(life, 'quiet_processes', side_effect=lambda *a, **k: k['background'].append(43)), \
                    patch.object(life, 'background_stale', return_value=True) as stale:
                self.assertEqual(life.child_busy('isolated', '@1', reap=True), [])
                stale.assert_called_once()
                self.assertEqual(worker.stamp.call_args.args[0], '@bg_stale')
                self.assertTrue(worker.stamp.call_args.args[1].isdigit())
                stale.return_value = False
                self.assertEqual(life.child_busy('isolated', '@1', reap=True), [43])

    def test_preview_beneath_mcp_is_work_and_missing_script_is_reclaimed(self):
        with tempfile.TemporaryDirectory() as d:
            source = dict(agent='claude', pid=40, worktree=d)
            rows = {40: (1, 'claude'), 41: (40, 'Python'), 42: (41, 'Python'),
                    43: (42, 'sh'), 44: (43, 'node'), 99: (1, 'node')}
            # The still-running MCP and preview both came from the old install.
            argv = {40: ['claude'], 41: ['python3', d + '/old/bin/fleet-mcp.py'],
                    42: ['python3', d + '/old/bin/fleet-preview.py', 'dev', '--name', 'test',
                         '--', '/bin/sh', '-c', 'node ' + d + '/gone.mjs']}
            with patch.dict(life.TRANSFER, process_rows=lambda: rows), \
                    patch.dict(life.ARGV, process_argv=lambda pid: argv[pid]), \
                    patch('fleet_native_proc.kernel_identity', side_effect=lambda pid: dict(birth_token='one', ppid=rows[pid][0])), \
                    patch('fleet_native_proc.process_gone', return_value=True), \
                    patch.object(life.os, 'kill') as kill:
                self.assertEqual(set(life.preview_background(source, '100')), {42, 43, 44})
                kill.assert_not_called()
                self.assertEqual(life.preview_background(source, '100', reap=True), [])
                self.assertEqual({c.args[0] for c in kill.call_args_list}, {42, 43, 44})

    def test_preview_request_progress_is_not_waived_by_shell_timer(self):
        worker = Mock()
        worker.opt.side_effect = lambda k: '100' if k == '@claude_state_ts' else ''
        worker.inspect.return_value = dict(agent='claude', pid=42)
        with patch.object(life, 'Worker', return_value=worker), \
                patch.object(life, 'quiet_processes'), \
                patch.object(life, 'preview_background', return_value=[43]), \
                patch.object(life, 'background_stale', return_value=True):
            self.assertEqual(life.child_busy('isolated', '@1', reap=True), [43])

    def test_doctor_names_specific_probe_stage(self):
        snap = {'@park_wrap_ver': '1', '@park_refusal': 'probe_timeout:claude_inbox_unclaimed'}
        with patch.object(policy, 'report_hold', return_value=''):
            self.assertIn('next=park-held why=probe_timeout:claude_inbox_unclaimed', policy.explain(snap))

    def test_relay_timeout_names_operation(self):
        with patch.object(gate.socket, 'socket') as sock:
            sock.return_value.__enter__.return_value.recv.side_effect = socket.timeout()
            self.assertEqual(gate.relay_request(dict(relay='/isolated/ctl'), dict(op='status'))['why'],
                             'probe_timeout:relay_status')

    def test_legacy_uncertain_is_not_composer_input(self):
        rows = [dict(state='native', legacy=True, delivery='receipt-1')]
        with patch.object(gate, 'records', return_value=rows):
            self.assertEqual(gate.pending_words_reason('fid'), 'delivery_uncertain:receipt-1')
            rows[0]['legacy'] = False
            self.assertEqual(gate.pending_words_reason('fid'), 'words_waiting')

    def test_inbox_timeout_names_stage_and_retries(self):
        with tempfile.TemporaryDirectory() as d, \
                patch.object(gate, 'claude_inbox', return_value=Path(d)), \
                patch.object(gate.time, 'sleep'), \
                patch.object(gate.time, 'monotonic', side_effect=range(100)):
            result = gate.park_proof(dict(agent='claude'))
            self.assertEqual(result['why'], 'probe_timeout:claude_inbox_unclaimed')
            self.assertEqual(result['attempts'], 2)
            self.assertEqual(list(Path(d).glob('*.json')), [])

    def test_claimed_probe_names_handler(self):
        with tempfile.TemporaryDirectory() as d, \
                patch.object(gate, 'claude_inbox', return_value=Path(d)), \
                patch.object(gate.time, 'sleep'), \
                patch.object(gate.time, 'monotonic', side_effect=range(100)):
            write = gate.write_json
            def claim(p, data):
                write(p, data)
                p.rename(p.with_suffix('.taken'))
            with patch.object(gate, 'write_json', side_effect=claim):
                result = gate.park_proof(dict(agent='claude'))
            self.assertEqual(result['why'], 'probe_timeout:claude_inbox_handler')


if __name__ == '__main__':
    unittest.main()
