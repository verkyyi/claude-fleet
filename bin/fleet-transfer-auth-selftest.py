#!/usr/bin/env python3
"""Transfer auth uses the target tenant's proxy, without exporting credentials."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

BIN = Path(__file__).absolute().parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, BIN / file)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


accounts = module('transfer_accounts', '.fleet-account.py')
proxy = module('transfer_proxy', 'fleet-cred-proxy.py')


class TransferAuth(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='transfer-auth-', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.conf = self.root / 'conf'
        self.conf.mkdir()
        self.home = self.root / '.codex'
        self.home.mkdir()
        self.state = self.conf / 'cred-proxy'
        self.state.mkdir()
        (self.conf / 'credsep.json').write_text(json.dumps({'run': str(self.state)}))
        self.env = patch.dict(os.environ, {'HOME': str(self.root), 'FLEET_CONF_DIR': str(self.conf),
                             'FLEET_CRED_CTL_DIR': str(self.state), 'FLEET_CRED_PROXY': '1'}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.auth = self.root / 'store' / 'default' / 'auth.json'
        self.auth.parent.mkdir(parents=True)
        self.token(time.time() + 3600)
        cfg = SimpleNamespace(store=str(self.auth.parent.parent), pool='', state=str(self.state),
                              codex_auth=str(self.auth), codex_homes=str(self.auth.parent.parent),
                              ctl_uid=os.getuid(), relay_url='')
        self.tenant = SimpleNamespace(cfg=cfg, log=lambda **kw: None,
                                     router=SimpleNamespace(candidates=lambda *a: (['direct'], 'trusted')))
        self.tenant_patch = patch.object(proxy.Proxy, 'T', self.tenant, create=True)
        self.tenant_patch.start()
        self.addCleanup(self.tenant_patch.stop)
        self.tenants_patch = patch.object(proxy.Proxy, 'tenants', {})
        self.tenants_patch.start()
        self.addCleanup(self.tenants_patch.stop)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(str(self.state / 'ctl.sock'))
        self.sock.listen()
        self.sock.settimeout(.1)
        self.done = threading.Event()
        def serve():
            while not self.done.is_set():
                try:
                    conn, _ = self.sock.accept()
                except socket.timeout:
                    continue
                proxy.ctl_conn(conn, cfg)
        self.thread = threading.Thread(target=serve)
        self.thread.start()
        self.addCleanup(self.stop)
        self.registry = patch.object(accounts, 'profiles', return_value=[dict(
            agent='codex', profile='default', account='', home=str(self.home), login='no_credentials')])
        self.registry.start()
        self.addCleanup(self.registry.stop)

    def stop(self):
        self.done.set()
        self.thread.join(timeout=2)
        self.sock.close()

    def token(self, expiry):
        body = base64.urlsafe_b64encode(json.dumps({'exp': expiry}).encode()).decode().rstrip('=')
        self.auth.write_text(json.dumps({'tokens': {'access_token': 'header.' + body + '.private',
                                                   'refresh_token': 'private-refresh', 'account_id': 'fixture'}}))

    def test_shared_proxy_without_local_login(self):
        result = accounts.target_auth('codex')
        self.assertEqual(result['verdict'], 'ok', result)
        self.assertEqual(result['source'], 'proxy')
        self.assertNotIn('private-refresh', json.dumps(result))
        self.assertNotIn('.private', json.dumps(result))
        self.assertFalse((self.home / 'auth.json').exists())

    def test_bad_or_missing_lease_refused(self):
        for bad in ('expired', 'missing', 'malformed', 'rejected'):
            with self.subTest(bad=bad):
                self.token(time.time() - 60 if bad == 'expired' else time.time() + 3600)
                if bad == 'missing':
                    self.auth.unlink()
                if bad == 'malformed':
                    self.auth.write_text('{')
                if bad == 'rejected':
                    _, _, fp = proxy.codex_tokens(str(self.auth))
                    (self.auth.parent / '.ccquota-upstream.json').write_text(json.dumps(
                        {'credential_version': fp, 'state': 'rejected'}))
                self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')

    def test_proxy_down_refuses_even_without_registry(self):
        self.stop()
        with patch.object(accounts, 'profiles', side_effect=OSError('absent')):
            self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')

    def test_explicit_profile_still_needs_local_login(self):
        self.assertEqual(accounts.target_auth('codex', profile_name='default')['verdict'], 'refuse')
        with patch.dict(os.environ, FLEET_CODEX_PROFILE='default'):
            self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')

    def test_named_home_checks_that_account(self):
        custom = self.root / '.codex-accounts' / 'missing'
        custom.mkdir(parents=True)
        self.assertEqual(accounts.target_auth('codex', home=str(custom))['verdict'], 'refuse')

    def test_disabled_proxy_does_not_admit(self):
        with patch.dict(os.environ, FLEET_CRED_PROXY='0'):
            self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')

    def test_central_route_cannot_be_attested_by_local_lease(self):
        self.tenant.router.candidates = lambda *a: (['central'], 'untrusted')
        self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')

    def test_other_tenants_lease_cannot_satisfy_target(self):
        self.auth.unlink()
        other = self.root / 'other-login' / 'auth.json'
        other.parent.mkdir()
        other.write_text('{}')
        with patch.object(proxy.Proxy, 'tenants', {'other': SimpleNamespace(cfg=SimpleNamespace(uid=os.getuid()+1))}):
            self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')

    def test_old_proxy_without_verdict_refuses(self):
        with patch.object(proxy, 'ctl_handle', return_value={'ok': False, 'err': 'unknown op'}):
            self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')

    def test_renewed_lease_does_not_inherit_rejection(self):
        _, _, fp = proxy.codex_tokens(str(self.auth))
        (self.auth.parent / '.ccquota-upstream.json').write_text(json.dumps(
            {'credential_version': fp, 'state': 'rejected'}))
        self.token(time.time() + 7200)
        self.assertEqual(accounts.target_auth('codex')['verdict'], 'ok')

    def test_shared_pool_uses_only_this_tenants_index(self):
        pool = self.root / 'pool'
        self.tenant.cfg.pool = str(pool)
        path = pool / 'codex' / 'fixture' / 'auth.json'
        path.parent.mkdir(parents=True)
        self.auth.rename(path)
        # A valid file elsewhere in the shared pool is not this tenant's lease.
        self.assertEqual(accounts.target_auth('codex')['verdict'], 'refuse')
        (self.state / 'pool.json').write_text(json.dumps({'codex:default': 'fixture'}))
        self.assertEqual(accounts.target_auth('codex')['verdict'], 'ok')


if __name__ == '__main__':
    unittest.main()
