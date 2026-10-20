#!/usr/bin/env -S python3 -W ignore::ResourceWarning -I
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('proxy', Path(__file__).with_name('fleet-cred-proxy.py'))
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class Rejections(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.alpha = self.config('alpha', 1001)
        self.beta = self.config('beta', 1002)

    def config(self, name, uid):
        root = self.root / name
        (root / 'state').mkdir(parents=True)
        return SimpleNamespace(name=name, uid=uid, store=True, state=str(root / 'state'),
                               pool=str(self.root / 'pool'), accounts=str(root / 'accounts'),
                               codex_auth=str(root / 'codex/default/auth.json'),
                               codex_homes=str(root / 'codex'))

    def put(self, cfg, label, access, refresh='hub-managed', pooled=True):
        bundle = json.dumps(dict(tokens=dict(access_token=access, refresh_token=refresh,
                                            account_id='fixture-account'))).encode()
        if pooled:
            proxy.pool_put(cfg, 'codex', label, bundle)
            path = proxy.pool_entry(cfg, 'codex', label)
        else:
            path = proxy.codex_auth_path(cfg, label)
            proxy.write_private(path, bundle)
        _, _, fingerprint = proxy.codex_tokens(path)
        proxy.codex_verdict((os.path.dirname(path), fingerprint), 'direct', 401,
                            b'{"error":{"code":"token_expired"}}')
        return Path(path)

    def test_shared_store_reports_only_current_leased_tenant_tokens(self):
        self.put(self.alpha, 'default', 'fixture-shared-access')
        self.put(self.beta, 'default', 'fixture-shared-access')
        self.put(self.beta, 'private', 'fixture-beta-access')
        self.put(self.alpha, 'personal', 'fixture-personal-access', refresh='real-refresh')
        rows = proxy.ctl_handle({'op': 'upstream-rejections'}, SimpleNamespace(cfg=self.alpha))
        self.assertEqual(rows, dict(ok=True, rejected=[dict(provider='codex', account='default',
                         fingerprint=hashlib.sha256(b'fixture-shared-access').hexdigest(), error='token_expired')]))
        encoded = json.dumps(rows)
        for secret in ('fixture-shared-access', 'fixture-beta-access', 'real-refresh'):
            self.assertNotIn(secret, encoded)
        proxy.pool_put(self.alpha, 'codex', 'default', json.dumps(dict(tokens=dict(
            access_token='fixture-replacement', refresh_token='hub-managed', account_id='fixture-account'))).encode())
        self.assertEqual(proxy.codex_rejections(self.alpha), [])
        self.assertEqual(len(proxy.codex_rejections(self.beta)), 2)

    def test_own_store_stale_accepted_and_refresh_refusals(self):
        path = self.put(self.alpha, 'default', 'fixture-own-access', pooled=False)
        self.assertEqual(len(proxy.codex_rejections(self.alpha)), 1)
        verdict_path = path.parent / '.ccquota-upstream.json'
        original = json.loads(verdict_path.read_text())
        for change in (dict(credential_version='stale'), dict(state='accepted'),
                       dict(error='refresh_token_expired'), dict(error='relay_unauthorized')):
            proxy.write_json(str(verdict_path), dict(original, **change))
            self.assertEqual(proxy.codex_rejections(self.alpha), [])

    def test_unknown_or_removed_account_and_corrupt_data(self):
        path = self.put(self.alpha, 'default', 'fixture-access')
        proxy.write_json(str(path.parent / '.ccquota-upstream.json'), [])
        self.assertEqual(proxy.codex_rejections(self.alpha), [])
        self.put(self.alpha, 'default', 'fixture-access')
        proxy.write_json(os.path.join(self.alpha.state, 'pool.json'), {})
        self.assertEqual(proxy.codex_rejections(self.alpha), [])

    def test_control_peer_cannot_select_other_tenant(self):
        alpha = SimpleNamespace(name='alpha', cfg=self.alpha)
        beta = SimpleNamespace(name='beta', cfg=self.beta)
        with patch.object(proxy.Proxy, 'tenants', dict(alpha=alpha, beta=beta)), \
             patch.object(proxy, 'peer_uid', return_value=1001), \
             patch.dict(os.environ, {'FLEET_CRED_SHARED_TEST': '0'}):
            selected, refusal = proxy.ctl_tenant(None, {'op': 'upstream-rejections'})
            self.assertIs(selected, alpha)
            self.assertIsNone(refusal)
            selected, refusal = proxy.ctl_tenant(None, {'op': 'upstream-rejections', 'as': 'beta'})
            self.assertIsNone(selected)
            self.assertIsNotNone(refusal)


if __name__ == '__main__':
    unittest.main()
