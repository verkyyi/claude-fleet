#!/usr/bin/env python3
"""Codex migration regression: exact UUID, isolated homes and hostile bundles."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
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

    def test_legacy_move_metadata_does_not_create_parent(self):
        self.record['metadata']['@origin_wid'] = 'fleet/' + SID
        before = self.rollout.read_bytes()
        home = Path(move.unpack(self.bundle(), SID, '/new', self.root))
        metadata = json.loads((home / 'move.json').read_text())['metadata']
        self.assertNotIn('@origin_wid', metadata)
        self.assertEqual(metadata['@fleet_id'], OTHER)
        self.assertEqual(self.rollout.read_bytes(), before)

    def test_import_home_uses_only_target_default_pool(self):
        home = Path(move.unpack(self.bundle(), SID, '/new', self.root))
        self.assertEqual(move.account_home(home, self.root), 'default')
        with self.assertRaisesRegex(ValueError, 'not a managed'):
            move.account_home(home, self.root/'another-login')
        manifest=json.loads((home/'move.json').read_text()); manifest['sid']=OTHER
        (home/'move.json').write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, 'invalid Codex import'):
            move.account_home(home, self.root)

    def test_native_launch_preserves_model_effort_and_overrides_stored_cwd(self):
        self.record['metadata'].update({'@model':'gpt-6-astra','@effort':'high'})
        home=move.unpack(self.bundle(), SID, '/new dir', self.root)
        args=move.launch_args('/fleet/wrap',home,SID,'/new dir')
        self.assertEqual(args[args.index('--cd')+1],'/new dir')
        self.assertEqual(args[args.index('--resume')+1],SID)
        self.assertEqual(args[args.index('--model')+1],'gpt-6-astra')
        self.assertIn('model_reasoning_effort="high"',args)
        self.assertNotIn('--effort',args)
        with self.assertRaisesRegex(ValueError,'UUID mismatch'):
            move.launch_args('/fleet/wrap',home,OTHER,'/new dir')

    def test_stop_holds_source_before_exit_keys(self):
        record=dict(self.record,socket='scratch',window='@1',owner='123')
        events=[]
        with patch.object(move,'same_source'), patch.object(move,'alive',return_value=False), \
             patch.object(move,'tm',side_effect=lambda *a:events.append(a)), \
             patch.object(move.subprocess,'run',side_effect=lambda *a,**kw:events.append(('keys',))):
            move.stop(record,1)
        self.assertLess(next(i for i,e in enumerate(events) if '@reap_hold' in e),
                        next(i for i,e in enumerate(events) if e==('keys',)))

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

    def test_real_move_coordinator_never_retires_source_on_failed_receipt(self):
        source=(Path(__file__).parent/'fleet-move.sh').read_text()
        coordinator=source[source.index('  move_one_codex() ('):source.index('\n  move_one_body() {')]
        fixture=r'''
set -uo pipefail
VIA=ssh KEEP=0 BIN=/candidate SOCK=scratch wid=@1 wt=/source repo=o/r branch=work
REMOTE_BIN=/remote TARGET_FLEET='' TO=target DRY=0 name=worker EXIT_WAIT=1
raw=1 state=done hnd=a1 iss='' origin=''
say() { :; }
git() { return 0; }
TM() { printf '%s\n' "$*" >> "$TRACE"; }
fleet_win_retire() { printf 'retire\n' >> "$TRACE"; }
fleet_rotate_lease_held() { return 1; }
fleet_rotate_lease_take() { return 0; }
fleet_rotate_lease_drop() { return 0; }
python3() {
  case "${2:-}" in
    inspect) printf '{"sid":"01a1625a-6695-7bd0-ab61-ab43e70180cc"}\n' ;;
    stop) return 0 ;;
    pack) printf fixture ;;
    *) command python3 "$@" ;;
  esac
}
remote_cmd() { printf receive; }
move_ssh() { cat >/dev/null; printf '/import-home\n'; }
ssh_run() {
  case "$2" in
    plan) printf 'fleet\t/main\tmaster\n' ;;
    provision) printf 'fleet\t/target\tscratch\n' ;;
    launch)
      case "$MODE" in
        empty) printf '@9\t\tfleet\n' ;;
        nonzero) printf '@9\t123\tfleet\n'; return 10 ;;
        success) printf '@9\t123\tfleet\n' ;;
      esac ;;
  esac
}
'''
        for mode in ('empty','nonzero','success'):
            trace=self.root/(mode+'.trace')
            result=subprocess.run(['bash','-c',fixture+coordinator+'\nmove_one_codex\n'],
                                  env=dict(os.environ,TRACE=str(trace),MODE=mode),capture_output=True,text=True)
            calls=trace.read_text()
            self.assertEqual(result.returncode,0 if mode=='success' else 10,result.stderr)
            self.assertEqual('retire' in calls,mode=='success')
            self.assertEqual('kill-window' in calls,mode=='success')


if __name__ == '__main__':
    unittest.main(verbosity=2)
