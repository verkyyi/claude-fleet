#!/usr/bin/env python3
# selftest-entry
"""Short-lived broker credentials survive long-running schedule requests."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import fleet_cred_ctl
import fleet_node_http as http


class NodeHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conf = Path(self.tmp.name)
        self.conf.joinpath('credsep.json').write_text('{}')
        self.env = patch.dict(os.environ, {'FLEET_CONF_DIR': self.tmp.name,
                                         'CCQUOTA_NODE_KEY': 'off', 'CCQUOTA_HUB_SOCK': 'off'})
        self.env.start()
        self.addCleanup(self.env.stop)
        http._PAIR.clear()
        self.addCleanup(http._PAIR.clear)
        self.broker = patch.object(fleet_cred_ctl, 'ctl', side_effect=lambda op: (
            {'url': 'http://127.0.0.1:12345', 'token': 'fcpn1.test-%s' % self.ctl.call_count}, 0))
        self.ctl = self.broker.start()
        self.addCleanup(self.broker.stop)

    def test_refresh_after_long_run(self):
        with patch('time.monotonic', return_value=1000) as now:
            admitted = http.pair()
            now.return_value = 1479
            self.assertEqual(http.pair(), admitted)
            self.assertEqual(self.ctl.call_count, 1)
            now.return_value = 1481
            self.assertNotEqual(http.pair(), admitted)
            now.return_value = 2400  # finish after waiting fifteen more minutes
            http.pair()
            self.assertEqual(self.ctl.call_count, 3)

    def request(self, statuses):
        conn = Mock()
        conn.getresponse.side_effect = [Mock(status=s, read=Mock(return_value=b'result')) for s in statuses]
        with patch.object(http.http.client, 'HTTPConnection', return_value=conn):
            result = http.call('POST', '/finish', {'run': 'test'})
        return result, conn.request.call_args_list

    def test_401_refresh_and_replay(self):
        result, requests = self.request([401, 200])
        self.assertEqual(result, (200, 'result'))
        self.assertEqual(self.ctl.call_count, 2)
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[0].args, requests[1].args)
        self.assertEqual(requests[0].kwargs['body'], requests[1].kwargs['body'])
        self.assertNotEqual(requests[0].kwargs['headers']['Authorization'],
                            requests[1].kwargs['headers']['Authorization'])

    def test_401_retries_only_once(self):
        result, requests = self.request([401, 401])
        self.assertEqual(result[0], 401)
        self.assertEqual(len(requests), 2)
        self.assertEqual(self.ctl.call_count, 2)

    def test_other_errors_do_not_retry(self):
        for code in (403, 500):
            result, requests = self.request([code])
            self.assertEqual(result[0], code)
            self.assertEqual(len(requests), 1)

    def test_node_env_keeps_long_lived_pair_and_no_retry(self):
        self.conf.joinpath('node.env').write_text(
            "CCQUOTA_HUB_URL='http://127.0.0.1:12345/'\nCCQUOTA_TOKEN='test-long-lived'\n")
        with patch('time.monotonic', return_value=1000) as now:
            self.assertEqual(http.pair(), ('http://127.0.0.1:12345', 'test-long-lived'))
            now.return_value = 99999
            self.conf.joinpath('node.env').unlink()
            self.assertEqual(http.pair()[1], 'test-long-lived')
            result, requests = self.request([401])
        self.assertEqual(result[0], 401)
        self.assertEqual(len(requests), 1)
        self.ctl.assert_not_called()


if __name__ == '__main__':
    unittest.main()
