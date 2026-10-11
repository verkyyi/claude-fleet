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


def multi_login(d, state, runtime, hub, first, s, made):
    """EPIC #3208 C1 for real: open · restart · remove · open again."""
    for name in ('24haowan', 'drill2', 'drill3'):
        try:
            pwd.getpwnam(name)
            raise SystemExit('fixture login %s already exists' % name)
        except KeyError:
            pass
    tool = [sys.executable, '-I', str(runtime / 'bin/fleet-node-linux.py')]

    def login(*argv, rc=0):
        r = subprocess.run(tool + ['login'] + list(argv), capture_output=True, text=True)
        assert r.returncode == rc, 'login %s: rc %d (want %d)\n%s%s' % (argv, r.returncode, rc, r.stdout, r.stderr)
        return r.stdout

    def opened(name):
        code = d / ('join-' + name)
        code.write_text('fj_' + 'b' * 26)
        code.chmod(0o600)
        out = login('open', name, '--no-start', '--hub', hub, '--join-file', str(code))
        made.append(name)
        assert out.strip().splitlines()[-1].startswith('credsep: '), out
        return pwd.getpwnam(name)

    assert json.loads((state / 'linux-tenants' / (first + '.json')).read_text())['uid'] == 31022, 'legacy not migrated'
    assert (state / 'linux-tenant.json.bak').is_file() and not (state / 'linux-tenant.json').exists()
    login('open', '1234', rc=3)
    a, b = opened('24haowan'), opened('drill2')
    assert len({a.pw_uid, b.pw_uid, 31022}) == 3, 'two logins share a number'
    before = {n: (pwd.getpwnam(n).pw_uid, os.stat(pwd.getpwnam(n).pw_dir).st_uid) for n in (first, '24haowan', 'drill2')}
    # Another login cannot enter a home.
    denied = subprocess.run(['ls', b.pw_dir], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            preexec_fn=s.demote('24haowan', a.pw_uid, a.pw_gid, a.pw_dir))
    assert denied.returncode != 0, '24haowan can list drill2\'s home'
    # A container restart: the image's passwd comes back without them.
    for n in before:
        subprocess.run(['userdel', n], check=True)
        subprocess.run(['groupdel', n], check=False)
    subprocess.run(tool + ['boot'], check=True)
    after = {n: (pwd.getpwnam(n).pw_uid, os.stat(pwd.getpwnam(n).pw_dir).st_uid) for n in before}
    assert after == before, 'restart changed a number or a home owner: %r → %r' % (before, after)
    print(login('list'), end='')
    print(subprocess.run(['id', '24haowan'], capture_output=True, text=True).stdout, end='')
    # A running process of drill2's is gone with it.
    sleeper = subprocess.Popen(['sleep', '300'], preexec_fn=s.demote('drill2', b.pw_uid, b.pw_gid, b.pw_dir))
    out = login('remove', 'drill2', '--keep-home')
    assert out.strip().splitlines()[-1] == 'credsep: purged', out
    sleeper.wait(timeout=10)
    made.remove('drill2')
    try:
        pwd.getpwnam('drill2')
        raise AssertionError('drill2 still in passwd')
    except KeyError:
        pass
    assert not Path(b.pw_dir).exists(), 'drill2 home left behind'
    assert list((d / 'homes/.attic').glob('drill2-*.tar.gz')), 'drill2 home not archived'
    assert not (d / 'cred/drill2').exists() and not (d / 'lib/drill2.conf').exists(), 'drill2 credsep left behind'
    assert not (state / 'logins/drill2.env').exists(), 'drill2 still in the machine daemon'
    assert subprocess.run(['pgrep', '-U', str(b.pw_uid)], capture_output=True).returncode != 0
    login('remove', 'drill2', '--keep-home', rc=4)
    c = opened('drill3')
    assert c.pw_uid != b.pw_uid and c.pw_uid not in (31022, a.pw_uid), 'drill3 got a used number'


def main():
    if os.geteuid() != 0 or not sys.platform.startswith('linux') or os.environ.get('CI') != 'true':
        raise SystemExit('only run as root on an ephemeral Linux CI machine (CI=true)')
    os.umask(0o022)
    login = 'fleetci3022'
    try:
        pwd.getpwnam(login)
        raise SystemExit('fixture login already exists')
    except KeyError:
        pass
    made = []
    hub = ThreadingHTTPServer(('127.0.0.1', 0), Hub)
    threading.Thread(target=hub.serve_forever, daemon=True).start()
    proc = None
    # Hosted runners may make /opt writable for tool installation. Select a
    # prefix through the supervisor's real trust check, never weaken that check.
    supervisor = load('fleet-node-supervisor')
    prefix = next((p for p in ('/opt', '/var/lib', '/usr/local/lib') if supervisor.trusted(p, as_root=True)), None)
    if prefix is None:
        raise RuntimeError('CI has no trusted root prefix for the native runtime test')
    with tempfile.TemporaryDirectory(prefix='fleet-linux-ci-', dir=prefix) as tmp:
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
        for path in (runtime, *runtime.rglob('*')):
            path.chmod(path.stat().st_mode & ~0o022)
        (runtime / '.release').mkdir()
        (runtime / '.release/staged.json').write_text('{}')
        (runtime / 'bin/ccquota').write_text('#!/bin/sh\nexit 0\n')
        (runtime / 'bin/ccquota').chmod(0o755)
        (d / 'runtime/current').symlink_to(runtime.name)
        sshdir = d / 'ssh'
        sshdir.mkdir()
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(d / 'ca')], check=True)
        (d / 'ca').chmod(0o600)
        Hub.ca = (d / 'ca.pub').read_bytes()
        # The native daemon check uses a temporary config, never the runner's.
        conf = sshdir / 'sshd_config'
        conf.write_text('Include ' + str(sshdir / 'sshd_config.d/*.conf') + '\n'
                        'HostKey ' + str(d / 'ca') + '\nUsePAM yes\n')
        check = d / 'check-sshd'
        check.write_text('#!/bin/sh\n/usr/sbin/sshd -f ' + shlex.quote(str(conf)) +
                         ' "$@" 2>' + shlex.quote(str(d / 'sshd-check.log')) +
                         '\nrc=$?\ncat ' + shlex.quote(str(d / 'sshd-check.log')) + ' >&2\nexit "$rc"\n')
        check.chmod(0o755)
        Path('/run/sshd').mkdir(exist_ok=True)
        pub = d / 'release.pub'
        pub.write_text('ed25519 ' + 'A' * 43 + '=\n')
        os.environ.update(FLEET_NODE_RUNTIME=str(d / 'runtime/current'), FLEET_NODE_UID='31022',
                          FLEET_NODE_SSH_DIR=str(sshdir), FLEET_NODE_SSHD=str(check), FLEET_NODE_RUN_SSHD='1')
        m = load('fleet-node-linux')
        outside = d / 'outside'
        outside.mkdir()
        (d / 'store-link').symlink_to(outside)
        try:
            m.private_write(d / 'store-link/blocked', 'fixture')
        except OSError:
            pass
        else:
            raise AssertionError('root store write followed a directory symlink')
        assert not (outside / 'blocked').exists()
        (outside / 'secret').write_text('CCQUOTA_TOKEN=fixture')
        (d / 'token-link').symlink_to(outside / 'secret')
        try:
            m.env_read(d / 'token-link')
        except OSError:
            pass
        else:
            raise AssertionError('root token read followed a symlink')
        # A volume from before EPIC #3208 C1: the single-login declaration.
        (state / 'linux-tenant.json').write_text(json.dumps(
            {'login': login, 'uid': 31022, 'gid': 31022, 'home': str(d / 'homes' / login)}))
        args = argparse.Namespace(login=login, uid=31022, hub='http://127.0.0.1:%d' % hub.server_port,
                                  join_file=str(code), relay='https://fleet-relay.24hw.cn')
        try:
            install = ['bash', str(runtime / 'bin/fleet-node-install.sh'), '--hub', args.hub,
                       '--join-file', str(code), '--login', login, '--login-join-file', str(code),
                       '--release-key', str(pub), '--service', 'foreground']
            result = subprocess.run(install)
            if result.returncode:
                raise RuntimeError('installer failed: ' + (d / 'sshd-check.log').read_text())
            assert (sshdir / 'fleet_user_ca.pub').read_bytes() == Hub.ca
            # Native systemd convergence uses a recording service manager, so
            # no service on the CI host is enabled or reloaded.
            manager = d / 'systemctl'
            calls = d / 'systemctl.calls'
            manager.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> ' + shlex.quote(str(calls)) + '\n')
            manager.chmod(0o755)
            native_env = dict(os.environ, FLEET_NODE_SYSTEMCTL=str(manager),
                              FLEET_NODE_DAEMON_DIR=str(d / 'units'))
            native = ['bash', str(runtime / 'bin/fleet-node-install.sh'), '--hub', args.hub,
                      '--release-key', str(pub), '--service', 'systemd']
            script = runtime / 'bin/fleet-node-supervisor.py'
            if not supervisor.trusted(str(script), as_root=True):
                detail = [(str(p), p.stat().st_uid, oct(p.stat().st_mode & 0o777)) for p in (script, *script.parents)]
                raise RuntimeError('CI runtime is untrusted: ' + repr(detail))
            subprocess.run(native, env=native_env, check=True)
            assert 'reload ssh.service' in calls.read_text()
            assert 'enable --now claude-fleet-node.service' in calls.read_text()
            assert (d / 'units/claude-fleet-node.service').is_file()
            token_path = d / 'cred' / login / 'node.env'
            original = token_path.read_bytes()
            code.unlink()  # restart after the one-time Secret has been removed
            m.prepare(args)
            assert Hub.joins == 2, 'restart enrolled another endpoint (one machine + one tenant expected)'
            assert token_path.read_bytes() == original, 'node token changed on retry'
            assert not (d / 'units/claude-fleet-cred-proxy-shared.service').exists(), 'duplicate proxy service was installed'
            s = load('fleet-node-supervisor')
            denied = subprocess.run(['cat', str(token_path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    preexec_fn=s.demote(login, 31022, 31022, str(d / 'homes' / login)))
            assert denied.returncode != 0, 'tenant can read subscription/node store'
            env_path = state / 'logins' / (login + '.env')
            assert env_path.stat().st_mode & 0o777 == 0o600
            assert 'CCQUOTA_FLEET_CRED_STORE=' in env_path.read_text()
            # issue #3211: the node program leases this login's accounts only on this line.
            assert 'CCQUOTA_FLEET_CREDS=1' in env_path.read_text().splitlines()
            assert 'CCQUOTA_FLEET_CREDS=1' in token_path.read_text().splitlines()
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
            multi_login(d, state, runtime, args.hub, login, s, made)
            print('PASS several logins: legacy declaration migrated; 24haowan + drill2 opened; numbers and homes '
                  'kept across a passwd wipe; drill2 removed whole; drill3 got a fresh number')
        finally:
            if proc:
                proc.terminate()
                proc.wait(timeout=10)
            for name in [login] + made:
                subprocess.run(['userdel', name], check=False)
                subprocess.run(['groupdel', name], check=False)
            hub.shutdown()
            hub.server_close()


if __name__ == '__main__':
    main()
