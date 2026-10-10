#!/usr/bin/env python3
"""Linux/root integration test. Run ONLY on an ephemeral CI machine/container.

Real passwd entries, uid separation, store, shared proxy, and supervisor; a
loopback hub fixture counts joins. No live credentials or cloud resources.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import shlex
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    sp = importlib.util.spec_from_file_location(name, ROOT / 'bin' / (name + '.py'))
    m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m)
    return m


class Hub(BaseHTTPRequestHandler):
    joins = 0
    ca = b''

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/v1/fleet/ssh-ca.pub':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(self.ca)
            return
        self.reply({'trust': 'trusted', 'trusted': True, 'role': 'managed'})

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/v1/node/join':
            Hub.joins += 1
            self.reply({'token': 'fixture-node-token'})
        elif self.path == '/v1/node/relay-credential':
            self.reply({'token': 'frl1.fixture-relay-pass'})
        else:
            self.reply({})

    def reply(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    if os.geteuid() != 0 or not sys.platform.startswith('linux') or os.environ.get('CI') != 'true':
        raise SystemExit('only run as root on an ephemeral Linux CI machine (CI=true)')
    login = 'fleetci3022'
    try:
        pwd.getpwnam(login)
        raise SystemExit('fixture login already exists')
    except KeyError:
        pass
    hub = ThreadingHTTPServer(('127.0.0.1', 0), Hub)
    threading.Thread(target=hub.serve_forever, daemon=True).start()
    proc = None
    with tempfile.TemporaryDirectory(prefix='fleet-linux-ci-') as tmp:
        d = Path(tmp)
        d.chmod(0o755)
        state = d / 'state'
        state.mkdir()
        code = d / 'join'
        code.write_text('fj_' + 'a' * 26)
        code.chmod(0o600)
        os.environ.update(FLEET_NODE_STATE=str(state), FLEET_NODE_USERS=str(d / 'homes'),
                          FLEET_NODE_ROOT=str(d / 'runtime'), FLEET_NODE_RUNTIME=str(ROOT),
                          FLEET_NODE_LOG=str(d / 'logs'), FLEET_NODE_SERVICE='foreground',
                          FLEET_NODE_UPDATE_OWNER='image', FLEET_CREDSEP_TEST='1',
                          FLEET_CREDSEP_ROOT_BASE=str(d / 'cred'), FLEET_CREDSEP_RUN_BASE=str(d / 'run'),
                          FLEET_CREDSEP_LIB=str(d / 'lib'), FLEET_CREDSEP_LOG_BASE=str(d / 'credlogs'),
                          FLEET_CREDSEP_DAEMON_DIR=str(d / 'units'))
        (d / 'units').mkdir()
        # Run the real installer against a staged image and the loopback hub.
        # Files are copied out of the runner's private checkout so a real
        # unprivileged tenant can read its runtime.
        runtime = d / 'runtime' / ('a' * 40)
        shutil.copytree(ROOT / 'bin', runtime / 'bin')
        shutil.copytree(ROOT / 'conf', runtime / 'conf')
        (runtime / '.release').mkdir()
        (runtime / '.release/staged.json').write_text('{}')
        (runtime / 'bin/ccquota').write_text('#!/bin/sh\nexit 0\n')
        (runtime / 'bin/ccquota').chmod(0o755)
        (d / 'runtime/current').symlink_to(runtime.name)
        sshdir = d / 'ssh'
        sshdir.mkdir()
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(d / 'ca')], check=True)
        Hub.ca = (d / 'ca.pub').read_bytes()
        # The native daemon check uses a temporary config, never the runner's.
        conf = sshdir / 'sshd_config'
        conf.write_text('Include ' + str(sshdir / 'sshd_config.d/*.conf') + '\n'
                        'HostKey ' + str(d / 'ca') + '\nUsePAM yes\n')
        check = d / 'check-sshd'
        check.write_text('#!/bin/sh\nexec /usr/sbin/sshd -f ' + shlex.quote(str(conf)) + ' "$@"\n')
        check.chmod(0o755)
        Path('/run/sshd').mkdir(exist_ok=True)
        pub = d / 'release.pub'
        pub.write_text('ed25519 ' + 'A' * 43 + '=\n')
        os.environ.update(FLEET_NODE_RUNTIME=str(d / 'runtime/current'), FLEET_NODE_UID='31022',
                          FLEET_NODE_SSH_DIR=str(sshdir), FLEET_NODE_SSHD=str(check), FLEET_NODE_RUN_SSHD='1')
        m = load('fleet-node-linux')
        args = argparse.Namespace(login=login, uid=31022, hub='http://127.0.0.1:%d' % hub.server_port,
                                  join_file=str(code), relay='https://fleet-relay.24hw.cn')
        try:
            install = ['bash', str(runtime / 'bin/fleet-node-install.sh'), '--hub', args.hub,
                       '--join-file', str(code), '--login', login, '--login-join-file', str(code),
                       '--release-key', str(pub), '--service', 'foreground']
            subprocess.run(install, check=True)
            assert (sshdir / 'fleet_user_ca.pub').read_bytes() == Hub.ca
            token_path = d / 'cred' / login / 'node.env'
            original = token_path.read_bytes()
            code.unlink()  # restart after the one-time Secret has been removed
            m.prepare(args)
            assert Hub.joins == 2, 'restart enrolled another endpoint (one machine + one tenant expected)'
            assert token_path.read_bytes() == original, 'node token changed on retry'
            assert not list((d / 'units').glob('*.service')), 'duplicate proxy service was installed'
            s = load('fleet-node-supervisor')
            denied = subprocess.run(['cat', str(token_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    preexec_fn=s.demote(login, 31022, 31022, str(d / 'homes' / login)))
            assert denied.returncode != 0, 'tenant can read subscription/node store'
            env_path = state / 'logins' / (login + '.env')
            assert env_path.stat().st_mode & 0o777 == 0o600
            assert 'CCQUOTA_FLEET_CRED_STORE=' in env_path.read_text()
            launch_log = open(d / 'proxy.log', 'w')
            proc = subprocess.Popen([sys.executable, '-I', str(d / 'lib/fleet-credsep-launch.py'), 'shared'],
                                    stdout=launch_log, stderr=subprocess.STDOUT)
            for _ in range(100):
                if (d / 'run/.shared/ctl.sock').exists():
                    break
                if proc.poll() is not None:
                    raise RuntimeError((d / 'proxy.log').read_text())
                time.sleep(0.1)
            else:
                raise RuntimeError('proxy did not start: ' + (d / 'proxy.log').read_text())
            # A real tenant reaches only its own control socket and mints a
            # session pass; no provider credential enters its environment.
            p, env = m.tenant_env(s, login)
            env['FLEET_CRED_CTL_DIR'] = str(d / 'run/.shared')
            mint = d / 'mint.py'
            shutil.copyfile(ROOT / 'bin/fleet-cred-proxy.py', mint)
            mint.chmod(0o644)
            result = subprocess.run([sys.executable, str(mint), 'mint', '--sid', 'smoke', '--provider', 'claude'],
                                    env=env, cwd=p.pw_dir, preexec_fn=s.demote(login, p.pw_uid, p.pw_gid, p.pw_dir),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            assert result.returncode == 0 and result.stdout.strip().startswith('fcp1.'), result.stderr
            args.uid += 1
            try:
                m.prepare(args)
            except ValueError:
                pass
            else:
                raise AssertionError('changed tenant UID accepted on existing PVC')
            print('PASS Linux installer/SSH CA; one machine + one tenant join across retry; fixed UID; separated store; shared proxy; mint')
        finally:
            if proc:
                proc.terminate()
                proc.wait(timeout=10)
            subprocess.run(['userdel', login], check=False)
            hub.shutdown()
            hub.server_close()


if __name__ == '__main__':
    main()
