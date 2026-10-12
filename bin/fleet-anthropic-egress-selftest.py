#!/usr/bin/env python3
"""Hermetic checks for mandatory CONNECT, TLS identity and root-only routing."""
import contextlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

BIN = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), BIN / (name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class MandatoryEgress(unittest.TestCase):
    def test_policy_has_one_route_and_retains_trust_gate(self):
        m = module('fleet-cred-proxy')
        with tempfile.TemporaryDirectory() as d:
            cfg = SimpleNamespace(state=d, relay_url='https://sg.example', relay_token='offline',
                                  anthropic_proxy='http://us:3128')
            r = m.Router(cfg)
            r.trust, r.trust_why = 'trusted', 'hub'
            self.assertEqual(r.candidates('claude', True)[0], ['direct'])
            for trust in ('unknown', 'untrusted'):
                r.trust = trust
                self.assertEqual(r.candidates('claude', True)[0], [])
                self.assertEqual(r.candidates('codex', True)[0], ['central'])
            for bad in ('https://us:3128', 'http://user:pass@us:3128', 'http://us',
                        'http://us:0', 'http://us:65536', 'http://us:3128/a',
                        'http://us:3128?token=x', 'http://us:3128\n'):
                with self.assertRaises(ValueError, msg=bad):
                    m.parse_connect_proxy(bad)
            with self.assertRaises(ValueError):
                m.upstream_https(urlsplit('http://api.anthropic.com'), 1, cfg.anthropic_proxy)

    def test_real_connect_keeps_upstream_sni_and_certificate_verification(self):
        if not shutil.which('openssl'):
            self.skipTest('openssl unavailable')
        m = module('fleet-cred-proxy')
        with tempfile.TemporaryDirectory() as d:
            cert, key = str(Path(d, 'cert.pem')), str(Path(d, 'key.pem'))
            # Generated only for this test. This key is never a deployment credential.
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', key, '-out', cert, '-days', '1', '-subj', '/CN=api.anthropic.com',
                            '-addext', 'subjectAltName=DNS:api.anthropic.com'], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_ctx.load_cert_chain(cert, key)
            observed = []
            server_ctx.set_servername_callback(lambda sock, name, ctx: observed.append(('sni', name)))
            client_ctx = ssl.create_default_context(cafile=cert)
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            listener.settimeout(5)
            port = listener.getsockname()[1]
            errors = []

            def serve():
                for _ in range(2):
                    try:
                        conn, _ = listener.accept()
                        with conn:
                            head = b''
                            while not head.endswith(b'\r\n\r\n'):
                                head += conn.recv(1)
                            observed.append(('connect', head.split(b'\r\n')[0]))
                            conn.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
                            try:
                                with server_ctx.wrap_socket(conn, server_side=True) as tls:
                                    request = tls.recv(8192)
                                    observed.append(('request', request))
                                    tls.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok')
                            except ssl.SSLError:
                                pass  # the second request must reject the hostname
                    except Exception as e:
                        errors.append(e)
                listener.close()

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            with patch.object(m.ssl, '_create_default_https_context', return_value=client_ctx):
                c = m.upstream_https(urlsplit('https://api.anthropic.com'), 3, 'http://127.0.0.1:%d' % port)
                c.request('GET', '/')
                self.assertEqual(c.getresponse().read(), b'ok')
                c.close()
                c = m.upstream_https(urlsplit('https://wrong.claude.ai'), 3, 'http://127.0.0.1:%d' % port)
                with self.assertRaises(ssl.SSLCertVerificationError):
                    c.connect()
                c.close()
            thread.join(6)
            self.assertFalse(thread.is_alive())
            self.assertFalse(errors, errors)
            # Python 3.12 uses HTTP/1.1 for CONNECT; older runtimes use HTTP/1.0.
            connects = [value.split() for kind, value in observed if kind == 'connect']
            self.assertEqual([line[:2] for line in connects], [
                [b'CONNECT', b'api.anthropic.com:443'],
                [b'CONNECT', b'wrong.claude.ai:443']])
            self.assertTrue(all(line[2] in (b'HTTP/1.0', b'HTTP/1.1') for line in connects))
            self.assertIn(('sni', 'api.anthropic.com'), observed)
            self.assertIn(('sni', 'wrong.claude.ai'), observed)
            # An absent gateway raises rather than resolving the provider locally.
            with patch.object(m.socket, 'create_connection', side_effect=OSError('gateway_down')) as dial:
                c = m.upstream_https(urlsplit('https://api.anthropic.com'), 1, 'http://us.invalid:3128')
                with self.assertRaises(OSError):
                    c.connect()
                self.assertEqual(dial.call_count, 1)
                self.assertEqual(dial.call_args.args[0], ('us.invalid', 3128))

    def test_tenant_cannot_redirect_the_gateway_and_node_heal_preserves_it(self):
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {'FLEET_CREDSEP_TEST': '1',
                'FLEET_CREDSEP_LIB': d, 'FLEET_CRED_CENTRAL_URL': ''}):
            launch = module('fleet-credsep-launch')
            conf = Path(d, 'conf')
            conf.mkdir()
            (conf / 'fleet.conf').write_text('FLEET_CRED_ANTHROPIC_PROXY=http://evil:3128\n')
            root = Path(d, 'alice.conf')
            root.write_text('FLEET_CRED_ANTHROPIC_PROXY=http://us:3128\n')
            root.chmod(0o600)
            meta = {'login': 'alice', 'conf_dir': str(conf), 'install_dir': d}
            self.assertEqual(launch.tenant_settings(meta)['FLEET_CRED_ANTHROPIC_PROXY'], 'http://us:3128')
            n = module('fleet-node-linux')
            c = SimpleNamespace(LIB=d, proxy_mod=lambda: module('fleet-cred-proxy'))
            def write(path, data):
                Path(path).write_text(data)
            with patch.object(n, 'private_write', side_effect=write), patch.dict(os.environ,
                    {'FLEET_ANTHROPIC_PROXY': 'http://us:3128'}):
                n.route_settings(c, 'alice', 'https://hub.example', 'https://sg.example')
                self.assertEqual(n.env_read(root)['FLEET_CRED_ANTHROPIC_PROXY'], 'http://us:3128')
            with patch.object(n, 'private_write', side_effect=write), patch.dict(os.environ,
                    {'FLEET_ANTHROPIC_PROXY': ''}):
                n.route_settings(c, 'alice', 'https://hub.example', 'https://sg.example')
                self.assertEqual(n.env_read(root)['FLEET_CRED_ANTHROPIC_PROXY'], 'http://us:3128')
            cmd = [os.sys.executable, str(BIN.parent / 'extras/managed-node/render.py'),
                   '--image', 'example/node@sha256:' + 'a' * 64, '--hub', 'https://hub.example', '--storage-class', 'disk',
                   '--anthropic-proxy', 'http://fleet-us-egress.fleet-workers.svc.cluster.local:3128']
            objects = json.loads(subprocess.check_output(cmd))['items']
            sts = next(o for o in objects if o['kind'] == 'StatefulSet')
            env = sts['spec']['template']['spec']['containers'][0]['env']
            self.assertIn({'name': 'FLEET_ANTHROPIC_PROXY', 'value': cmd[-1]}, env)
            user_objects = json.loads(subprocess.check_output(cmd + ['--user-pod', 'u-canary']))['items']
            dep = next(o for o in user_objects if o['kind'] == 'Deployment')
            self.assertIn({'name': 'FLEET_ANTHROPIC_PROXY', 'value': cmd[-1]},
                          dep['spec']['template']['spec']['containers'][0]['env'])
            incompatible = subprocess.run(cmd + ['--cred-central', 'https://central.example'],
                                          capture_output=True, text=True)
            self.assertNotEqual(incompatible.returncode, 0)
            self.assertIn('configure US egress on the central proxy', incompatible.stderr)
            managed = Path(d, 'managed-settings.json')
            managed.write_text(json.dumps({'permissions': {'defaultMode': 'default'},
                                          'env': {'EXISTING_POLICY': 'keep'}}))
            _, shell = n.devnet_settings({'FLEET_EGRESS_PROXY': 'http://us:3128'})
            n.claude_proxy_settings(shell, managed)
            data = json.loads(managed.read_text())
            self.assertEqual(data['permissions'], {'defaultMode': 'default'})
            self.assertEqual(data['env']['EXISTING_POLICY'], 'keep')
            self.assertEqual(data['env']['https_proxy'], 'http://us:3128')
            self.assertEqual(data['env']['HTTPS_PROXY'], 'http://us:3128')


if __name__ == '__main__':
    unittest.main()
