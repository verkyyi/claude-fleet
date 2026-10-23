#!/usr/bin/env python3
"""Legacy web conversations remain in the ordinary ID history after cutover."""
import json
import os
from pathlib import Path
import tempfile
import unittest
import uuid

import fleet_id
import fleet_webchat_legacy as legacy
import fleet_history_read


class LegacyHistory(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self.previous)))
        os.environ.update(FLEET_ID_DIR=self.tmp.name, FLEET_ID_PUSH='0')

    def test_both_agents_chains_and_idempotent_retry(self):
        a, b, c = [str(uuid.uuid4()) for _ in range(3)]
        rows = [dict(agent='claude', session=b, cwd='/home/alice', chain=[dict(id=a, cwd='/home/alice/previous')]),
                dict(agent='codex', session=c, cwd='/home/alice', codex_home='/home/alice/.codex')]
        first = legacy.import_entries(rows)
        self.assertEqual(len(first), 2)
        before = {p.name: p.read_bytes() for p in Path(self.tmp.name).glob('*.ndjson')}
        self.assertEqual(legacy.import_entries(rows), first)
        self.assertEqual(before, {p.name: p.read_bytes() for p in Path(self.tmp.name).glob('*.ndjson')})
        claude = fleet_id.fold(fleet_id.read(first[0]))
        self.assertEqual([x['native'] for x in claude['segments']], [a, b])
        self.assertIsNotNone(claude['closed'])
        self.assertEqual(claude['opened']['origin'], 'web')
        self.assertEqual(fleet_id.continue_plan(first[0], 1)['worktree'], '/home/alice/previous')
        self.assertEqual(fleet_id.continue_plan(first[1])['codex_home'], '/home/alice/.codex')

    def test_existing_identity_is_reused_without_closing_it(self):
        fid, sid = str(uuid.uuid4()), str(uuid.uuid4())
        fleet_id.open_id(fid, dict(agent='claude', title='Existing task'))
        fleet_id.record_native(fid, 'claude', sid, 'startup')
        before = fleet_id.read(fid)
        self.assertEqual(legacy.import_entries([dict(agent='claude', session=sid)]), [fid])
        self.assertEqual(fleet_id.read(fid), before)

    def test_native_transcripts_readable_and_resumable_after_import(self):
        root = Path(self.tmp.name)
        claude, codex = str(uuid.uuid4()), str(uuid.uuid4())
        projects = root / 'claude-projects'
        (projects / 'project').mkdir(parents=True)
        (projects / 'project' / (claude + '.jsonl')).write_text(json.dumps({'sessionId': claude, 'type': 'user'}) + '\n')
        home = root / 'codex-home'
        rollouts = home / 'sessions' / '2026' / '01' / '01'
        rollouts.mkdir(parents=True)
        (rollouts / ('rollout-' + codex + '.jsonl')).write_text(json.dumps({
            'type': 'session_meta', 'payload': {'id': codex, 'cwd': str(root)}}) + '\n')
        os.environ['CLAUDE_PROJECTS_DIR'] = str(projects)
        ids = legacy.import_entries([dict(agent='claude', session=claude, cwd=str(root)),
                                     dict(agent='codex', session=codex, cwd=str(root), codex_home=str(home))])
        for fid in ids:
            history = fleet_history_read.history(fid)
            self.assertTrue(history['readable'])
            self.assertTrue(history['resumable'])
        self.assertEqual({x['id'] for x in fleet_id.history_rows({})}, set(ids))

    def test_invalid_entry_refuses_before_any_write(self):
        with self.assertRaises(ValueError):
            legacy.import_entries([dict(agent='claude', session=str(uuid.uuid4())),
                                   dict(agent='codex', session='../not-a-session')])
        self.assertEqual(list(Path(self.tmp.name).glob('*.ndjson')), [])


if __name__ == '__main__':
    unittest.main()
