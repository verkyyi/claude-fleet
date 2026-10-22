#!/usr/bin/env python3
# selftest-entry
"""Hermetic real report entry, local/hub transport and identity-fenced replay."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('delegation', BIN / 'fleet_report_delegation.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)
F = '11111111-1111-4111-8111-111111111111'
R = '22222222-2222-4222-8222-222222222222'
P = '33333333-3333-4333-8333-333333333333'
C = '44444444-4444-4444-8444-444444444444'
S = '55555555-5555-4555-8555-555555555555'
X = '66666666-6666-4666-8666-666666666666'


class DelegationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.conf = self.work / 'conf'
        self.conf.mkdir()
        self.env = patch.dict(os.environ, FLEET_CONF_DIR=str(self.conf))
        self.env.start()
        self.addCleanup(self.env.stop)

    def grant(self, parent=F+'/'+P, target=F+'/'+S, workers=(F+'/'+C,)):
        return d.change('grant', parent=parent, target=target, workers=workers,
                        authorization='operator-approved task example')

    def test_scope_chain_cycle_revoke_audit(self):
        g = self.grant()
        self.assertIsNone(d.lookup(F+'/'+X, F+'/'+P))
        self.assertIsNone(d.lookup(F+'/'+C, F+'/'+X))
        self.assertEqual(d.lookup(F+'/'+C, F+'/'+P)['target'], F+'/'+S)
        h = self.grant(parent=F+'/'+S, target=R+'/'+X)
        self.assertEqual([r['id'] for r in d.lookup(F+'/'+C, F+'/'+P)['chain']], [g['id'], h['id']])
        for parent, target in ((F+'/'+P, F+'/'+P), (R+'/'+X, F+'/'+P), (F+'/'+S, F+'/'+C)):
            with self.assertRaises(ValueError):
                self.grant(parent=parent, target=target)
        with self.assertRaises(ValueError):
            self.grant()  # overlapping scope is not last-writer-wins
        with self.assertRaises(ValueError):
            self.grant(workers=('scratch-1',))
        with self.assertRaises(ValueError):
            d.change('grant', authorization='', parent=F+'/'+P, target=F+'/'+S, workers=[F+'/'+C])
        d.change('revoke', grant_id=g['id'], authorization='operator rollback')
        self.assertIsNone(d.lookup(F+'/'+C, F+'/'+P))
        rows = [json.loads(l) for l in (self.conf/'report-delegation/audit.ndjson').read_text().splitlines()]
        self.assertEqual([r['action'] for r in rows], ['grant', 'grant', 'revoke'])
        self.assertTrue(all(r['uid'] == os.getuid() and r['authorization'] for r in rows))

    def test_cli_authority_readback_and_corruption(self):
        cli = ['python3', str(BIN/'fleet_report_delegation.py')]
        args = ['grant', '--parent', F+'/'+P, '--target', F+'/'+S, '--worker', F+'/'+C,
                '--authorization', 'explicit authorization record']
        result = subprocess.run(cli+args, capture_output=True, text=True, check=True)
        grant = json.loads(result.stdout)
        shown = subprocess.run(cli+['show'], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(shown.stdout), [grant])
        forged = subprocess.run(cli+args+['--actor', 'somebody-else'], capture_output=True)
        self.assertNotEqual(forged.returncode, 0)
        with (self.conf/'report-delegation/audit.ndjson').open('a') as f:
            f.write('{broken\n')
        with self.assertRaises(ValueError):
            d.lookup(F+'/'+C, F+'/'+P)

    def fixture(self):
        self.bin = self.work/'bin'
        self.bin.mkdir()
        for name in ('fleet-report-parent.sh', 'fleet-peer-queue.sh', 'fleet-report-delivery.sh',
                     'fleet_report_delegation.py', 'fleet-hub-node.sh', 'fleet-children.py',
                     'fleet_report_clip.py', 'fleet-peer-hand.py'):
            shutil.copy(BIN/name, self.bin/name)
        # Only machine observations and the final agent adapter are fakes. All
        # report/queue/relay/ledger/receipt code under test is the production entry.
        (self.bin/'fleet-lib.sh').write_text(r'''
fleet_is_operator_sender() { return 1; }
fleet_is_fid() { [[ "$1" =~ ^[0-9a-f-]{36}$ ]]; }
fleet_uuid() { printf '%s\n' "$TEST_FLEET"; }
fleet_current_session() { echo test; }
fleet_load_conf() { :; }
fleet_socket() { echo test; }
fleet_state_dir() { mkdir -p "$FLEET_CONF_DIR/fleets/test"; echo "$FLEET_CONF_DIR/fleets/test"; }
fleet_key_qualify() { echo "$2"; }
fleet_window_repo() { :; }
_fleet_key_prefix() { :; }
fleet_key_gen() { :; }
fleet_scratch_key() { echo scratch-2; }
fleet_child_busy() { return 1; }
fleet_wid_home() { case "${1#wid:}" in "$TEST_FLEET/"*) echo test ;; *) return 1 ;; esac; }
fleet_win_for_fid() { [ -f "$TEST_READY" ] && [ "$1" = "$TEST_TARGET" ] && echo @supervisor; }
fleet_agent_deliver() { [ -f "$TEST_READY" ] || return 3; printf '%s\n' "$3" >> "$TEST_LOG"; }
fleet_hub_outbox() { echo "$FLEET_CONF_DIR/control/hub-outbox"; }
''')
        # Use the real durable hub writer as well.
        lib = (BIN/'fleet-lib.sh').read_text()
        writer = lib[lib.index('fleet_hub_put() {'):lib.index('# fleet_hub_wait_sent')]
        with (self.bin/'fleet-lib.sh').open('a') as f:
            f.write(writer)
        (self.bin/'fleet-children-lib.sh').write_text(r'''
children_report_mode() { echo immediate; }
report_tier() { case "$1" in idle|degenerate) echo silent ;; *) echo loud ;; esac; }
children_append() { python3 "$BIN/fleet-children.py" append --file "$FLEET_CONF_DIR/children/$1.ndjson" <<< "$2"; }
''')
        (self.bin/'tmux').write_text('''#!/usr/bin/env python3
# selftest-entry
import os,sys
args=sys.argv[1:]
if 'display-message' in args:
    fmt=args[-1]
    if '|#{@origin}|' in fmt:
        print('|'.join(['@child','scratch-1','','','/tmp/example-scratch-2','done',
                        os.environ['TEST_PARENT'],'','',os.environ['TEST_PARENT'].split('/')[1],
                        os.environ['TEST_CHILD'],'','codex','test worker']))
    elif fmt == '#{@fleet_id}': print(os.environ['TEST_TARGET'])
else:
    with open(os.environ['TEST_MUTATIONS'],'a') as f: f.write(repr(args)+'\\n')
''')
        (self.bin/'tmux').chmod(0o755)
        os.environ.update(PATH=str(self.bin)+os.pathsep+os.environ['PATH'], TEST_FLEET=F,
                          TEST_PARENT=F+'/'+P, TEST_CHILD=C, TEST_TARGET=S,
                          TEST_READY=str(self.work/'ready'), TEST_LOG=str(self.work/'messages'),
                          TEST_MUTATIONS=str(self.work/'mutations'), CCQUOTA_FLEET='1',
                          FLEET_PEER_QUEUE_TTL='1', FLEET_PEER_QUEUE_ALERT_SECS='1',
                          FLEET_PEER_QUEUE_DEAD_SECS='1', FLEET_SKIP_GLOBAL_CONF='1')
        self.q = self.conf/'fleets/test/peer-queue'

    def run_script(self, script, *args, data=None, expected=0):
        p = subprocess.run(['bash', str(self.bin/script), *args], input=data, text=True,
                           capture_output=True, timeout=20)
        self.assertEqual(p.returncode, expected, p.stdout+p.stderr)
        self.assertNotIn('command not found', p.stderr)
        return p.stdout

    def report(self, state='blocked', expected=3):
        return self.run_script('fleet-report-parent.sh', '-L', 'test', '--win', '@child',
                               '--state', state, '--summary', 'result evidence', expected=expected)

    def test_real_entry_offline_replay_identity_and_provenance(self):
        self.fixture()
        self.grant()
        self.report()
        files = list(self.q.glob('*.json'))
        self.assertEqual(len(files), 1)
        queued = json.loads(files[0].read_text())
        body = queued['delegation']
        self.assertEqual(body['pfid'], P)
        self.assertEqual(body['fid'], C)
        self.assertEqual(body['original_origin'], 'scratch-1')
        self.assertEqual(body['report_delegation']['original_parent'], F+'/'+P)
        self.report()  # the same real hook replay: one queue item
        self.assertEqual(len(list(self.q.glob('*.json'))), 1)
        self.assertNotIn('@origin', (self.work/'mutations').read_text())
        ledger = self.conf/f'children/{P}.ndjson'
        self.assertEqual(len(ledger.read_text().splitlines()), 1)
        row = json.loads(ledger.read_text())
        self.assertEqual(row['pfid'], P)
        self.assertIn('report_delegation', row)
        # Expired by both old timers: still held, never handed or alerted.
        queued['created'] = 1
        files[0].write_text(json.dumps(queued))
        self.run_script('fleet-peer-queue.sh', 'drain', '-L', 'test')
        self.run_script('fleet-peer-queue.sh', 'stale', '-L', 'test', '--secs', '1')
        self.assertTrue(files[0].exists())
        self.assertFalse((self.conf/'global/orphan-reports.ndjson').exists())
        # Same window label now carries another ID: no delivery.
        (self.work/'ready').touch()
        os.environ['TEST_TARGET'] = X
        self.run_script('fleet-peer-queue.sh', 'drain', '-L', 'test')
        self.assertFalse((self.work/'messages').exists())
        os.environ['TEST_TARGET'] = S
        self.run_script('fleet-peer-queue.sh', 'drain', '-L', 'test')
        self.assertEqual(list(self.q.glob('*.json')), [])
        self.assertEqual((self.work/'messages').read_text().count('[child-report]'), 1)
        self.report(expected=0)
        self.assertEqual((self.work/'messages').read_text().count('[child-report]'), 1)
        self.assertEqual(ledger.read_text().count('"pfid"'), 1)
        for state in ('failed', 'merged', 'stopped'):
            self.report(state, expected=0)
        self.assertEqual((self.work/'messages').read_text().count('[child-report]'), 4)
        self.report('blocked', expected=0)  # a later transition back is fresh news
        self.assertEqual((self.work/'messages').read_text().count('[child-report]'), 5)
        self.report('blocked', expected=0)
        self.assertEqual((self.work/'messages').read_text().count('[child-report]'), 5)

    def test_batch_does_not_redeliver_and_revoke_keeps_pending(self):
        self.fixture()
        grant = self.grant()
        self.report()
        pending = next(self.q.glob('*.json')).read_bytes()
        d.change('revoke', grant_id=grant['id'], authorization='rollback record')
        self.assertEqual(next(self.q.glob('*.json')).read_bytes(), pending)
        # A normal sibling still triggers the parent's digest. Its text must
        # exclude this delegated worker, including when a digest is forced.
        ledger = self.conf/f'children/{P}.ndjson'
        p = subprocess.run(['python3', str(self.bin/'fleet-children.py'), 'append', '--file', str(ledger)],
                           input=json.dumps(dict(child='scratch-3', state='BLOCKED', tier='loud', title='sibling')),
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        result = subprocess.run(['python3', str(self.bin/'fleet-children.py'), 'digest',
                                 '--dir', str(ledger.parent), '--parent', P, '--force'],
                                input='{}', text=True, capture_output=True, check=True)
        digest = json.loads(result.stdout)
        self.assertIn('sibling', digest['text'])
        self.assertNotIn('test worker', digest['text'])
        (self.work/'ready').touch()
        self.run_script('fleet-peer-queue.sh', 'drain', '-L', 'test')
        self.assertEqual((self.work/'messages').read_text().count('[child-report]'), 1)

    def test_silent_hook_is_only_archived_and_dry_run_does_not_queue(self):
        self.fixture()
        self.grant()
        self.run_script('fleet-report-parent.sh', '-L', 'test', '--win', '@child',
                        '--state', 'blocked', '--dry-run')
        self.assertFalse(self.q.exists())
        self.assertFalse((self.conf/'report-delegation/events').exists())
        self.report('idle', expected=0)
        self.assertFalse(self.q.exists())
        self.assertFalse((self.work/'messages').exists())
        row = json.loads((self.conf/f'children/{P}.ndjson').read_text())
        self.assertEqual(row['state'], 'IDLE')
        self.assertEqual(row['pfid'], P)

    def test_cross_machine_real_hub_receiver_and_replay(self):
        self.fixture()
        self.grant(target=R+'/'+S)
        self.report('failed')
        outbox = self.conf/'control/hub-outbox'
        relays = list(outbox.glob('*.json'))
        self.assertEqual(len(relays), 1)
        relay = relays[0].read_text()
        body = json.loads(relay)
        self.assertEqual(body['to'], R+'/'+S)
        self.assertEqual(body['from'], F+'/'+C)
        self.assertNotIn('worker', body)  # a drain never borrows another item's assertion
        self.run_script('fleet-peer-queue.sh', 'drain', '-L', 'test')
        self.assertEqual(len(list(outbox.glob('*.json'))), 1)
        os.environ['TEST_FLEET'] = R
        wrong = json.loads(relay)
        wrong['payload']['report_delegation']['target'] = R+'/'+X
        self.run_script('fleet-hub-node.sh', 'deliver', data=json.dumps(wrong), expected=1)
        self.run_script('fleet-hub-node.sh', 'deliver', data=relay, expected=75)
        (self.work/'ready').touch()
        for _ in range(2):
            self.run_script('fleet-hub-node.sh', 'deliver', data=relay)
        self.assertEqual((self.work/'messages').read_text().count('[child-report]'), 1)
        self.assertFalse((self.conf/f'children/{S}.ndjson').exists())
        receipt = dict(id=body['id'], kind='receipt', to=body['from'], **{'from': body['to']},
                       payload=dict(rid=body['id'], kind='child_report', to=body['to'], status='delivered'))
        os.environ['TEST_FLEET'] = F
        self.run_script('fleet-hub-node.sh', 'deliver', data=json.dumps(receipt))
        self.run_script('fleet-peer-queue.sh', 'drain', '-L', 'test')
        self.assertEqual(list(self.q.glob('*.json')), [])
        self.assertFalse((self.conf/'global/orphan-reports.ndjson').exists())


if __name__ == '__main__':
    unittest.main()
