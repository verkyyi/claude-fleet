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

    def log_message(self, *_):
        pass

    def do_GET(self):
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
        (state / 'machine.env').write_text('CCQUOTA_TOKEN=fixture-machine-token\n')
        (state / 'machine.env').chmod(0o600)
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
        m = load('fleet-node-linux')
        args = argparse.Namespace(login=login, uid=31022, hub='http://127.0.0.1:%d' % hub.server_port,
                                  join_file=str(code), relay='https://fleet-relay.24hw.cn')
        try:
            m.prepare(args)
            token_path = d / 'cred' / login / 'node.env'
            original = token_path.read_bytes()
            code.unlink()  # restart after the one-time Secret has been removed
            m.prepare(args)
            assert Hub.joins == 1, 'restart enrolled a second endpoint'
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
            result = subprocess.run([sys.executable, str(mint), 'mint', '--sid', 'smoke'],
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
            print('PASS Linux tenant: one join across restart; fixed UID; root-only store; shared proxy; session mint')
        finally:
            if proc:
                proc.terminate()
                proc.wait(timeout=10)
            subprocess.run(['userdel', login], check=False)
            hub.shutdown()
            hub.server_close()


if __name__ == '__main__':
    main()
