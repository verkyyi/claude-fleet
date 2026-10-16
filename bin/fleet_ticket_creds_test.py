#!/usr/bin/env python3
"""Endpoint/identity pairs: fake credentials and transport, never a live hub."""
import io
import os
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import fleet_ticket as ticket


class CredentialPairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.lib = self.root / 'fleet-lib.sh'
        self.reader()
        for p in (patch.dict(os.environ, {'HOME': str(self.root)}, clear=True),
                  patch.object(ticket, 'BIN', str(self.root)),
                  patch.object(ticket, '_CREDS', None)):
            p.start()
            self.addCleanup(p.stop)

    def reader(self, body=None):
        # Behaves like the existing node.env reader: preserves inherited fields.
        self.lib.write_text('_fleet_hub_env() {\n' + (body or '''
  export CCQUOTA_HUB_URL="${CCQUOTA_HUB_URL:-http://127.0.0.1:12345/hub}"
  export CCQUOTA_TOKEN="${CCQUOTA_TOKEN:-fixture-broker}"
''') + '\n}\n')

    def test_complete_explicit_pair_never_uses_reader(self):
        os.environ.update(CCQUOTA_HUB_URL='https://example.invalid/', CCQUOTA_TOKEN='fixture-explicit')
        with patch.object(ticket.subprocess, 'run', side_effect=AssertionError('unexpected fallback')):
            self.assertEqual(ticket.creds(), ('https://example.invalid', 'fixture-explicit'))

    def test_missing_pair_uses_reader_pair(self):
        self.assertEqual(ticket.creds(), ('http://127.0.0.1:12345/hub', 'fixture-broker'))

    def test_url_only_cannot_borrow_reader_token(self):
        os.environ['CCQUOTA_HUB_URL'] = 'https://example.invalid'
        self.assertEqual(ticket.creds(), ('http://127.0.0.1:12345/hub', 'fixture-broker'))
        self.assertEqual(os.environ['CCQUOTA_HUB_URL'], 'https://example.invalid')
        self.assertNotIn('CCQUOTA_TOKEN', os.environ)

    def test_url_only_keeps_broker_pair_when_reader_replaces_url(self):
        self.reader('export CCQUOTA_HUB_URL=http://127.0.0.1:12345/hub CCQUOTA_TOKEN=fixture-broker')
        os.environ['CCQUOTA_HUB_URL'] = 'https://example.invalid'
        self.assertEqual(ticket.creds(), ('http://127.0.0.1:12345/hub', 'fixture-broker'))

    def test_token_only_refuses_without_switching_identity(self):
        os.environ['CCQUOTA_TOKEN'] = 'fixture-explicit'
        with patch.object(ticket.subprocess, 'run', side_effect=AssertionError('identity fallback')):
            with self.assertRaises(ticket.Fail) as error:
                ticket.creds()
        self.assertEqual(error.exception.rc, 4)
        self.assertIsNone(ticket._CREDS)

    def test_reader_failure_or_partial_output_never_caches_or_sends(self):
        for body in ('return 1', 'export CCQUOTA_HUB_URL=https://example.invalid',
                     'export CCQUOTA_TOKEN=fixture-broker',
                     'export CCQUOTA_HUB_URL=https://example.invalid CCQUOTA_TOKEN=fixture-broker; return 1'):
            for inherited in ('', 'https://inherited.invalid'):
                with self.subTest(body=body, inherited=inherited):
                    ticket._CREDS = None
                    os.environ['CCQUOTA_HUB_URL'] = inherited
                    self.reader(body)
                    with patch.object(ticket.urllib.request, 'urlopen', side_effect=AssertionError('unexpected send')) as send:
                        with self.assertRaises(ticket.Fail):
                            ticket.api('GET', '/authority')
                    send.assert_not_called()
                    self.assertIsNone(ticket._CREDS)

    def test_explicit_rejection_does_not_retry_as_broker(self):
        os.environ.update(CCQUOTA_HUB_URL='https://example.invalid', CCQUOTA_TOKEN='fixture-invalid')
        for status in (401, 403):
            with self.subTest(status=status), \
                    patch.object(ticket.subprocess, 'run', side_effect=AssertionError('identity fallback')), \
                    patch.object(ticket.urllib.request, 'urlopen', side_effect=urllib.error.HTTPError(
                        'https://example.invalid', status, 'refused', {}, io.BytesIO(b'{"error":"refused"}'))) as send:
                with self.assertRaisesRegex(ticket.Fail, 'HTTP ' + str(status)):
                    ticket.api('POST', '/authority/start', {'action': 'reserve'})
                send.assert_called_once()
                request = send.call_args.args[0]
                self.assertEqual(request.get_header('Authorization'), 'Bearer fixture-invalid')
                self.assertTrue(request.full_url.startswith('https://example.invalid/'))


if __name__ == '__main__':
    unittest.main()
