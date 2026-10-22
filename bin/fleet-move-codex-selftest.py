#!/usr/bin/env python3
"""Codex migration regression: exact UUID, isolated homes and hostile bundles."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import fleet_move_codex as move

SID = '01a1625a-6695-7bd0-ab61-ab43e70180cc'
OTHER = '01a162f1-4e86-7b20-9b51-4928cb4d28ba'


class Move(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.rollout = self.root / 'source.jsonl'
        self.rollout.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': SID, 'cwd': '/old'}})+'\n'+
                                json.dumps({'type': 'response_item', 'payload': {'text': 'keep /old in conversation'}})+'\n'+
                                json.dumps({'type': 'turn_context', 'payload': {'cwd': '/old'}})+'\n')
        self.record = dict(format=1, agent='codex', sid=SID, turns=2,
                           transcript=str(self.rollout), metadata={'@fleet_id': OTHER})

    def tearDown(self):
        self.tmp.cleanup()

    def bundle(self):
        buf = io.BytesIO()
        move.pack(self.record, buf)
        buf.seek(0)
        return buf

    def test_round_trip_changes_location_only(self):
        home = Path(move.unpack(self.bundle(), SID, '/new', self.root))
        files = list(home.rglob('*.jsonl'))
        self.assertEqual(len(files), 1)
        rows = [json.loads(x) for x in files[0].read_text().splitlines()]
        self.assertEqual(rows[0]['payload'], {'id': SID, 'cwd': '/new'})
        self.assertEqual(rows[1]['payload']['text'], 'keep /old in conversation')
        self.assertEqual(rows[2]['payload']['cwd'], '/new')
        self.assertEqual(home.stat().st_mode & 0o777, 0o700)
        self.assertFalse((home/'auth.json').exists())
        self.assertFalse((home/'config.toml').exists())
        self.assertEqual(json.loads((home/'move.json').read_text())['metadata']['@fleet_id'], OTHER)

    def test_other_uuid_never_falls_back(self):
        self.record['sid'] = OTHER
        with self.assertRaisesRegex(ValueError, 'bound Codex UUID'):
            self.bundle()

    def test_existing_target_refuses_overwrite(self):
        home = Path(move.unpack(self.bundle(), SID, '/new', self.root))
        with self.assertRaises(FileExistsError):
            move.unpack(self.bundle(), SID, '/new', self.root)
        self.assertTrue((home/'move.json').exists())

    def test_mismatched_manifest_and_rollout_refused(self):
        with self.assertRaisesRegex(ValueError, 'manifest'):
            move.unpack(self.bundle(), OTHER, '/new', self.root)

    def test_archive_traversal_and_links_refused(self):
        for name, kind in [('../auth.json', tarfile.REGTYPE), ('move.json', tarfile.SYMTYPE)]:
            with self.subTest(name=name, kind=kind):
                buf = io.BytesIO()
                with tarfile.open(fileobj=buf, mode='w') as tar:
                    info=tarfile.TarInfo(name); info.type=kind; info.linkname='/tmp/escape'
                    tar.addfile(info)
                buf.seek(0)
                with self.assertRaisesRegex(ValueError, 'archive member'):
                    move.unpack(buf, SID, '/new', self.root)

    def test_stop_rechecks_identity_before_any_keys(self):
        with patch.object(move, 'same_source', side_effect=ValueError('changed')), patch.object(move, 'tm') as tm:
            with self.assertRaisesRegex(ValueError, 'changed'):
                move.stop(self.record, 1)
            tm.assert_not_called()

    def test_verify_rejects_wrong_target_uuid(self):
        with patch.dict(move.NATIVE, identity=lambda *args: {'session_id': OTHER}):
            with self.assertRaisesRegex(ValueError, 'same Codex UUID'):
                move.verify('scratch', '@1', SID, '/tmp/target', '/new')

    def test_verify_rejects_truncated_history(self):
        home = Path(move.unpack(self.bundle(), SID, '/new', self.root))
        path = next(home.rglob('*.jsonl'))
        class Client:
            def __init__(self,*a,**kw): pass
            def call(self,*a): return {'thread': {'id': SID, 'cwd': '/new', 'turns': []}}
            def close(self): pass
        with patch.dict(move.NATIVE, identity=lambda *a: {'session_id': SID, 'owner': '123'},
                        rollout=lambda d: (str(path), {})), patch.object(move, 'alive', return_value=True), patch.object(move, 'RPC', Client):
            with self.assertRaisesRegex(ValueError, 'history'):
                move.verify('scratch', '@1', SID, str(home), '/new')


if __name__ == '__main__':
    unittest.main(verbosity=2)
