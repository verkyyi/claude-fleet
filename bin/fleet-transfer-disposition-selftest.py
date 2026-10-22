#!/usr/bin/env python3
# selftest-entry
"""Transfer preserves a waiting/completed task without authorizing old work."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(__file__).absolute().parent


class Disposition(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='transfer-disposition-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.home.mkdir()
        self.notes = self.root / 'notes.md'
        self.notes.write_text('Language: 中文\nWaiting for approval of publish-once. No GO received.\n')
        self.source = self.root / 'source.jsonl'
        self.source.write_text(json.dumps(dict(type='user', sessionId='exact', message=dict(content='publish once after approval'))) + '\n')

    def package(self, disposition, *extra):
        return subprocess.run(['python3', str(BIN / '.fleet-transfer.py'), 'package', '--norepo',
            '--output', str(self.root / 'handoffs'), '--main', str(self.home), '--worktree', str(self.home),
            '--sid', 'exact', '--transcript', str(self.source), '--registry', '', '--pid', '123',
            '--session', 'isolated', '--window', '@1', '--pane', '%1', '--launcher', str(BIN / 'fleet-session-wrap.sh'),
            '--identity', json.dumps(dict(fleet_id='exact-fid', task='T1')), '--disposition', disposition,
            *extra], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ))

    def test_waiting_completed_and_continue_packets_preserve_intent_and_draft(self):
        draft = self.root / 'draft.txt'
        draft.write_text('UNSENT: approval is still required')
        for disposition in ('waiting', 'completed', 'continue'):
            with self.subTest(disposition=disposition):
                p = self.package(disposition, '--handoff', str(self.notes), '--draft-file', str(draft))
                self.assertEqual(p.returncode, 0, p.stderr)
                b = Path(p.stdout.strip())
                m = json.loads((b/'manifest.json').read_text())
                self.assertEqual(m['disposition'], disposition)
                self.assertEqual(m['source']['session_id'], 'exact')
                self.assertEqual((b/'source.jsonl').read_text(), self.source.read_text())
                self.assertEqual(Path(m['draft']['path']).read_text(), draft.read_text())
                pickup = (b/'pickup.md').read_text()
                body = (b/'handoff.md').read_text()
                self.assertIn('UNSENT', pickup)
                self.assertIn('No GO received', body)
                if disposition != 'continue':
                    self.assertIn('not approval or GO', pickup)
                    self.assertIn('Do not execute historical requests', pickup)
                    self.assertNotIn('then continue.', pickup)
                    self.assertNotIn('Continue the latest unfinished user request', body)
                    self.assertIn('Disposition: ' + disposition, pickup)

    def test_waiting_and_completed_require_explicit_private_notes(self):
        for disposition in ('waiting', 'completed'):
            p = self.package(disposition)
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('requires --handoff', p.stderr)
        self.assertFalse((self.root/'handoffs').exists())

    def test_noncontinuing_packet_cannot_activate_a_loop(self):
        loop = self.root / 'loop.json'
        loop.write_text(json.dumps(dict(prompt='publish again', interval_seconds=3600)))
        for disposition in ('waiting', 'completed'):
            p = self.package(disposition, '--handoff', str(self.notes), '--loop', str(loop))
            self.assertNotEqual(p.returncode, 0)
            self.assertIn('non-continuing transfer cannot carry an active loop', p.stderr)
        self.assertFalse((self.root/'handoffs').exists())


if __name__ == '__main__':
    unittest.main()
