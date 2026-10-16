#!/usr/bin/env python3
"""Panel preparation generations; sandbox HOME, no live sessions or messages."""
import importlib.util
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import subprocess
import shutil
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
loader = importlib.util.spec_from_file_location('preparation', BIN/'.fleet-transfer-norepo.py')
prep = importlib.util.module_from_spec(loader)
loader.loader.exec_module(prep)


@unittest.skipUnless(shutil.which('tmux'), 'tmux required')
class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.socket = 'transfer-identity-' + prep.uuid.uuid4().hex[:12]
        self.tm('-f', '/dev/null', 'new-session', '-d', '-s', 'identity')
        self.addCleanup(self.tm, 'kill-server')
        self.pane = self.tm('display-message', '-p', '-t', 'identity:', '#{pane_id}').strip()

    def tm(self, *args):
        return subprocess.check_output(['tmux', '-L', self.socket, *args], text=True)

    def test_identity_reads_all_fields_in_one_client_without_reinterpreting_values(self):
        values = dict.fromkeys(prep.FIELDS, '')
        values.update(fleet_id='11111111-1111-4111-8111-111111111111',
                      task_line='原样 | \\"quote\\" #{pane_id}\nsecond\tline\x1f end',
                      origin='scratch-1', norepo='1', fleet_role='worker')
        for key, value in values.items():
            if value:
                self.tm('set-option', '-w', '-t', self.pane, '@' + key, value)
        with patch.object(prep.subprocess, 'check_output', wraps=subprocess.check_output) as calls:
            self.assertEqual(prep.identity(self.socket, self.pane), values)
        self.assertEqual(calls.call_count, 1, 'one identity observation must not spawn a client per field')
        # Each later observation is fresh: no cross-phase identity cache.
        self.tm('set-option', '-w', '-t', self.pane, '@origin', 'scratch-2')
        self.assertEqual(prep.identity(self.socket, self.pane)['origin'], 'scratch-2')

    def test_gone_pane_cannot_validate_as_managed_home(self):
        values = prep.identity(self.socket, '%999999')
        with self.assertRaisesRegex(ValueError, 'managed HOME'):
            prep.validate(values, Path.home())


class PreparationTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name).resolve()
        self.values = dict.fromkeys(prep.FIELDS, '')
        self.values.update(norepo='1', fleet_role='worker', fleet_id='11111111-1111-4111-8111-111111111111')
        for mock in (patch.dict(os.environ, HOME=str(self.home), FLEET_CONF_DIR=str(self.home/'conf')),
                     patch.object(prep, 'identity', return_value=self.values),
                     patch.object(prep.runpy, 'run_path', return_value={'snapshot': lambda *a, **k: {'state': 'empty'}})):
            mock.start(); self.addCleanup(mock.stop)
        sender = patch.object(prep.subprocess, 'run')
        self.send = sender.start(); self.addCleanup(sender.stop)
        self.args = ('isolated', '%1', 'transcript', '123', 'sid', 'codex')
        self.check = ('isolated', '%1', '123', 'sid', 'codex')
        self.path = self.home/'conf/transfer-preparation'/f"{self.values['fleet_id']}.json"

    def request(self):
        output = io.StringIO()
        with redirect_stdout(output):
            prep.request_preparation(*self.args)
        self.output = output.getvalue()
        return json.loads(self.path.read_text())

    def change(self, **changes):
        row = json.loads(self.path.read_text()); row.update(changes)
        self.path.write_text(json.dumps(row))

    def notes(self, request):
        p = self.home/(request['request_id']+'.md')
        p.write_text('Fleet-Preparation-Request: '+request['request_id']+'\nVerified notes.\n')
        return str(p)

    def test_expired_explicit_click_replaces_generation_and_fences_old_notes(self):
        first = self.request(); notes = self.notes(first)
        prep.preparation_check(*self.check, notes=notes)
        self.assertEqual(self.request()['request_id'], first['request_id'])
        self.assertEqual(self.send.call_count, 1)
        self.change(expires_at=0)
        with self.assertRaises(ValueError): prep.preparation_check(*self.check, notes=notes)
        second = self.request()
        self.assertNotEqual(second['request_id'], first['request_id'])
        self.assertEqual(self.send.call_count, 2)
        with self.assertRaisesRegex(ValueError, 'request'):
            prep.preparation_check(*self.check, notes=notes)
        with self.assertRaises(ValueError): prep.preparation_check(*self.check)
        prep.preparation_check(*self.check, notes=self.notes(second))
        # The waiter carries the ID it armed with, never whichever file is latest.
        with self.assertRaises(ValueError):
            prep.preparation_check(*self.check, request_id=first['request_id'], notes=self.notes(second))

    def test_uncertain_or_interrupted_send_never_blindly_resends(self):
        first = self.request()
        for state in ('sending', 'uncertain'):
            self.change(state=state, expires_at=0)
            self.assertEqual(self.request()['request_id'], first['request_id'])
            self.assertIn('unconfirmed', self.output)
        self.assertEqual(self.send.call_count, 1)

    def test_lost_receipt_is_persisted_and_unknown_state_refuses(self):
        self.send.side_effect = subprocess.TimeoutExpired('peer-send', 30)
        with self.assertRaisesRegex(ValueError, 'unconfirmed'):
            self.request()
        row = json.loads(self.path.read_text())
        self.assertEqual(row['state'], 'uncertain')
        self.change(expires_at=0)
        self.assertEqual(self.request()['request_id'], row['request_id'])
        self.assertEqual(self.send.call_count, 1)
        self.change(state='unknown')
        with self.assertRaises(ValueError): self.request()
        self.assertEqual(self.send.call_count, 1)

    def test_source_rejection_allows_click_but_old_completion_cannot_touch_new(self):
        first = self.request()
        with patch.object(prep, 'source_identity', return_value={'pid':456, 'session_id':'new-source'}):
            with self.assertRaises(ValueError): prep.preparation_reject('isolated', '%1', first['request_id'])
        with patch.object(prep, 'source_identity', return_value={'pid':123, 'session_id':'sid'}):
            prep.preparation_reject('isolated', '%1', first['request_id'])
        with self.assertRaises(ValueError): prep.preparation_check(*self.check, notes=self.notes(first))
        second = self.request()
        self.assertNotEqual(first['request_id'], second['request_id'])
        with self.assertRaises(ValueError):
            prep.preparation_complete('isolated', '%1', first['request_id'])
        self.assertEqual(json.loads(self.path.read_text())['state'], 'requested')
        with patch.object(prep, 'source_identity', return_value={'pid':123, 'session_id':'sid'}):
            with self.assertRaises(ValueError): prep.preparation_reject('isolated', '%1', first['request_id'])

    def test_cutover_commit_fences_retry_until_result(self):
        request = self.request()
        prep.preparation_check(*self.check, notes=self.notes(request), commit=True)
        self.change(expires_at=0)
        self.assertEqual(self.request()['request_id'], request['request_id'])
        self.assertIn('committed', self.output)
        self.assertEqual(self.send.call_count, 1)
        prep.preparation_complete('isolated', '%1', request['request_id'])
        with self.assertRaises(ValueError): prep.preparation_check(*self.check, notes=self.notes(request))
        self.assertNotEqual(self.request()['request_id'], request['request_id'])

    def test_terminal_requests_allow_new_click_and_missing_records_reject_old_notes(self):
        row = self.request()
        for state in ('failed', 'cancelled', 'rejected'):
            self.change(state=state)
            fresh = self.request()
            self.assertNotEqual(fresh['request_id'], row['request_id'])
            row = fresh
        notes = self.notes(row)
        self.path.unlink()
        with self.assertRaises(ValueError): prep.preparation_check(*self.check, notes=notes)


if __name__ == '__main__':
    unittest.main()
