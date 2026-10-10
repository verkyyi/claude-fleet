#!/usr/bin/env python3
"""Linux managed-node bootstrap and foreground container lifecycle (#3022).

Root prepares one non-sudo tenant. Machine and tenant use separate hub join
codes and retain their own tokens. This uses the existing supervisor, shared
credential store and login bootstrap; it never starts a second node agent.
"""
import argparse
import fcntl
import grp
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), HERE / (name + '.py'))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def request(hub, path, token=None, body=None):
    url = urllib.parse.urlsplit(hub)
    if url.scheme != 'https' and not (url.scheme == 'http' and url.hostname in ('127.0.0.1', 'localhost', '::1')):
        raise ValueError('hub must use HTTPS (HTTP is allowed only on loopback)')
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(hub.rstrip('/') + path, headers=headers,
                                 data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError('hub %s returned HTTP %d' % (path, e.code)) from None


def private_write(path, data, uid=0, gid=0):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chown(tmp, uid, gid)
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def env_read(path):
    if not Path(path).exists():
        return {}
    return dict(line.split('=', 1) for line in Path(path).read_text().splitlines()
                if '=' in line and not line.startswith('#'))


def tenant_env(s, login):
    p = pwd.getpwnam(login)
    home = p.pw_dir
    e = {'HOME': home, 'USER': login, 'LOGNAME': login, 'SHELL': '/bin/zsh',
         'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
         'PATH': home + '/.local/bin:' + str(HERE) + ':' + str(HERE.parent / 'tools/bin') +
                 ':/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
         'FLEET_CONF_DIR': home + '/.config/claude-fleet', 'FLEET_INSTALL_PLATFORM': 'none'}
    e.update(s.node_environment())
    return p, e


def as_tenant(s, login, cmd, **kwargs):
    p, e = tenant_env(s, login)
    return subprocess.run(cmd, env=e, cwd=p.pw_dir,
                          preexec_fn=s.demote(login, p.pw_uid, p.pw_gid, p.pw_dir),
                          check=kwargs.pop('check', True), **kwargs)


def ensure_login(s, paths, login, uid):
    if not re.fullmatch(r'[a-z][a-z0-9_-]{0,30}', login) or uid < 1000:
        raise ValueError('a regular login name and UID >= 1000 are required')
    home = Path(paths.users) / login
    identity = Path(paths.state) / 'linux-tenant.json'
    expected = {'login': login, 'uid': uid, 'gid': uid, 'home': str(home)}
    if identity.exists() and json.loads(identity.read_text()) != expected:
        raise ValueError('tenant identity differs from the persistent volume; use the original login/UID')
    if home.is_symlink():
        raise ValueError('tenant home must not be a symlink')
    try:
        p = pwd.getpwnam(login)
        if not identity.exists():
            raise ValueError('login already exists outside this bootstrap; choose a fresh worker login')
    except KeyError:
        try:
            pwd.getpwuid(uid)
        except KeyError:
            pass
        else:
            raise ValueError('tenant UID is already in use')
        # Record the intended identity before passwd changes, so an interrupted
        # native bootstrap can reconcile its own partially created account.
        private_write(identity, json.dumps(expected) + '\n')
        try:
            g = grp.getgrnam(login)
            if g.gr_gid != uid:
                raise ValueError('tenant group has a different GID')
        except KeyError:
            subprocess.run(['groupadd', '--gid', str(uid), login], check=True)
        subprocess.run(['useradd', '--uid', str(uid), '--gid', str(uid), '--no-create-home',
                        '--home-dir', str(home), '--shell', '/bin/zsh', login], check=True)
        p = pwd.getpwnam(login)
    if (p.pw_uid, p.pw_gid, p.pw_dir) != (uid, uid, str(home)):
        raise ValueError('existing login does not match the declared UID/GID/home')
    why, complete = s.tenant_privileges(login)
    if why or not complete:
        raise ValueError('tenant must have no admin/sudo/container-management privileges')
    home.mkdir(parents=True, exist_ok=True)
    os.chown(home, uid, uid)
    os.chmod(home, 0o700)
    private_write(identity, json.dumps(expected) + '\n')
    return p


def prepare(a):
    s = load('fleet-node-supervisor')
    paths = s.Paths()
    if not Path(paths.state, 'machine.env').is_file():
        raise ValueError('enroll the machine with fleet node install first')
    os.environ.setdefault('FLEET_NODE_SERVICE', 'systemd')
    p = ensure_login(s, paths, a.login, a.uid)
    conf = Path(p.pw_dir) / '.config/claude-fleet'
    # User-owned files are written after dropping privileges, including on retry.
    as_tenant(s, a.login, ['python3', '-c',
        'from pathlib import Path; p=Path.home()/".config/claude-fleet"; p.mkdir(parents=True,exist_ok=True); '
        'f=p/"fleet.conf"; '
        'f.write_text("[common]\\nFLEET_CRED_PROXY=1\\nFLEET_CRED_SEPARATE=1\\n") if not f.exists() else None'])
    c = load('fleet-credsep')
    # The node store, never the tenant's home, holds the token from its first byte.
    c.ensure_role()
    role = pwd.getpwnam(c.ROLE)
    store = Path(c.ROOT_BASE) / a.login
    store.mkdir(parents=True, exist_ok=True)
    os.chmod(store, 0o700)
    os.chown(store, role.pw_uid, role.pw_gid)
    token_path = store / 'node.env'
    ne = env_read(token_path)
    if ne.get('CCQUOTA_TOKEN'):
        if ne.get('CCQUOTA_HUB_URL') != a.hub.rstrip('/'):
            raise ValueError('persisted tenant belongs to a different hub')
        # Never re-enroll on a network/auth failure: that would fork the identity.
        request(a.hub, '/v1/node/self', ne['CCQUOTA_TOKEN'])
    else:
        if not a.join_file:
            raise ValueError('first tenant enrollment needs --join-file (a second trusted hub join code)')
        code = Path(a.join_file).read_text().strip()
        if not re.fullmatch(r'fj_[a-z2-7]{26}', code):
            raise ValueError('invalid tenant join code')
        joined = request(a.hub, '/v1/node/join', body={
            'code': code, 'hostname': socket.gethostname(), 'os_user': a.login})
        token = joined.get('token') or joined.get('agent_token')
        if not isinstance(token, str) or not token or '\n' in token:
            raise ValueError('hub returned no tenant token')
        ne = {'CCQUOTA_HUB_URL': a.hub.rstrip('/'), 'CCQUOTA_TOKEN': token,
              'CCQUOTA_FLEET': '1', 'CCQUOTA_FLEET_COMPUTE': '1'}
        private_write(token_path, ''.join(k + '=' + v + '\n' for k, v in ne.items()), role.pw_uid, role.pw_gid)
    # These are root-authored route settings; a tenant cannot redirect its token.
    lib = Path(c.LIB)
    lib.mkdir(parents=True, exist_ok=True)
    route = {'FLEET_HUB_URL': a.hub.rstrip('/'), 'FLEET_CRED_RELAY_URL': a.relay}
    for value in route.values():
        if any(x in value for x in ('\n', '\r')):
            raise ValueError('invalid route setting')
    proxy = c.proxy_mod()
    # Root selected these endpoints. Persist their exact hosts in the launcher
    # allow-list too, so custom hub domains work after a container replacement.
    route['FLEET_CRED_ALLOW_HOSTS'] = ' '.join(sorted({
        urllib.parse.urlsplit(v).hostname or '' for v in route.values()}))
    proxy.ALLOWED = proxy.allowed_hosts(route['FLEET_CRED_ALLOW_HOSTS'])
    if not all(proxy.loopback_ok(route[k]) for k in ('FLEET_HUB_URL', 'FLEET_CRED_RELAY_URL')):
        raise ValueError('hub/relay must use HTTPS to an allowed host; configure root allow-list first')
    setting_path = lib / (a.login + '.conf')
    settings = env_read(setting_path)
    settings.update(route)
    private_write(setting_path, ''.join(k + '=' + v + '\n' for k, v in settings.items()))
    c.machine_install(argparse.Namespace(logins=a.login, force=False))
    # A readable token-free node.pub.env and an unreadable node.env pointer are
    # needed by the shell helpers; create them as the tenant, not by root in HOME.
    public = {k: v for k, v in ne.items() if k != 'CCQUOTA_TOKEN'}
    public['CCQUOTA_FLEET_CRED_STORE'] = str(Path(c.SHARED_RUN) / 'ctl.sock')
    as_tenant(s, a.login, ['python3', '-c',
        'import pathlib,sys; p=pathlib.Path(sys.argv[1]); '
        '(p/"node.pub.env").write_text(sys.argv[2]); '
        'f=p/"node.env"; f.unlink(missing_ok=True); f.symlink_to(sys.argv[3])',
        str(conf), ''.join(k + '=' + v + '\n' for k, v in public.items()), str(token_path)])
    relay = request(a.hub, '/v1/node/relay-credential', ne['CCQUOTA_TOKEN'], {})
    relay_token = relay.get('token') or relay.get('credential')
    if not isinstance(relay_token, str) or not relay_token:
        raise ValueError('hub returned no relay pass; verify tenant trust')
    private_write(store / 'cred-proxy/relay.token', relay_token + '\n', role.pw_uid, role.pw_gid)
    machine_env = dict(ne, FLEET_CONF_DIR=str(conf), CCQUOTA_FLEET_CRED_STORE=str(Path(c.SHARED_RUN) / 'ctl.sock'))
    s.write_login_env(paths, a.login, machine_env)
    os.environ['FLEET_NODE_ADOPT_FOLLOW'] = '0'
    if s.account_adopt(paths, a.login):
        raise ValueError('supervisor refused tenant adoption')
    print('prepared tenant %s (UID %d); credentials separated' % (a.login, a.uid))


def activate(_a):
    """Run as the tenant: reconcile an image, including a retry after failed apply.

    The previous image's files need not exist. Apply from an empty tree so all
    hooks/settings are reconciled, and stamp success only when apply succeeds.
    """
    root = Path(os.environ.get('FLEET_NODE_ROOT', '/opt/claude-fleet'))
    sha = (root / 'current').resolve().name
    updater = load('fleet-node-update')
    if updater.link_account(pwd.getpwuid(os.geteuid()).pw_name) or updater.link_tree(sha, apply=False):
        raise RuntimeError('could not link tenant to current runtime')
    home = Path.home()
    marker = home / '.config/claude-fleet/global/linux-image-applied'
    if marker.exists() and marker.read_text().strip() == sha:
        return
    live = home / '.claude/fleet'
    marker.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='image-apply-') as empty:
        subprocess.run(['bash', str(live / 'bin/fleet-install-apply.sh'), '--tree-from', empty,
                        '--tree-to', str(live.resolve()), '--root', str(live), '--from', 'none',
                        '--to', sha, '--no-daemons'], check=True)
    marker.write_text(sha + '\n')
    (marker.parent / 'bootstrap.applied').write_text(sha + '\n')


def bootstrap(a):
    s = load('fleet-node-supervisor')
    ctl = Path(os.environ.get('FLEET_CREDSEP_RUN_BASE', '/var/run/fleet-cred')) / '.shared/ctl.sock'
    for _ in range(60):
        if ctl.exists():
            break
        time.sleep(1)
    else:
        raise ValueError('shared credential proxy did not become ready')
    as_tenant(s, a.login, [sys.executable, '-I', str(HERE / 'fleet-node-linux.py'), 'activate'])
    as_tenant(s, a.login, ['bash', str(HERE / 'fleet-login-bootstrap.sh')])
    restored = as_tenant(s, a.login, ['bash', str(HERE / 'fleet-sessions-snapshot.sh'), 'restore'], check=False)
    if restored.returncode not in (0, 3):  # 3 = a fresh home has no snapshot yet
        raise RuntimeError('persisted session restore failed')


def foreground(a):
    # The PVC lock covers enrollment as well as runtime. A second writer cannot
    # consume a second join code or run two agents for one endpoint.
    state = Path(os.environ.get('FLEET_NODE_STATE', '/var/db/fleet-node'))
    state.mkdir(parents=True, exist_ok=True)
    with open(state / 'container.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ.update(FLEET_NODE_SERVICE='foreground', FLEET_NODE_UPDATE_OWNER='image',
                          FLEET_NODE_BOOT_ID=uuid.uuid4().hex, FLEET_NODE_RUN_SSHD='1')
        # SSH host identity must also survive container replacement.
        ssh_dir = state / 'ssh'
        ssh_dir.mkdir(mode=0o700, exist_ok=True)
        key = ssh_dir / 'ssh_host_ed25519_key'
        if not key.exists():
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        Path('/run/sshd').mkdir(parents=True, exist_ok=True)
        Path('/etc/ssh/sshd_config.d/90-fleet-container.conf').write_text(
            'HostKey ' + str(key) + '\nUsePAM yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n')
        cmd = ['bash', str(HERE / 'fleet-node-install.sh'), '--hub', a.hub, '--service', 'foreground',
               '--login', a.login, '--login-join-file', a.join_file]
        if a.machine_join_file and Path(a.machine_join_file).exists():
            cmd += ['--join-file', a.machine_join_file]
        cmd += ['--release-key', '/etc/fleet-release.pub']
        subprocess.run(cmd, check=True)
        child = subprocess.Popen([sys.executable, '-I', str(HERE / 'fleet-node-supervisor.py'), 'run'])
        stopping = False

        def stop(_sig, _frame):
            nonlocal stopping
            stopping = True

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        ready = Path('/run/fleet-node-ready')
        ready.unlink(missing_ok=True)
        try:
            bootstrap(a)
            ready.write_text(os.environ['FLEET_NODE_BOOT_ID'])
            while child.poll() is None and not stopping:
                time.sleep(1)
        finally:
            ready.unlink(missing_ok=True)
            s = load('fleet-node-supervisor')
            try:
                as_tenant(s, a.login, ['bash', str(HERE / 'fleet-sessions-snapshot.sh'), 'save'], timeout=30)
            except (subprocess.SubprocessError, OSError):
                print('snapshot failed; periodic persisted snapshot remains', file=sys.stderr)
            child.terminate()
            try:
                child.wait(timeout=60)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        return 0 if stopping else child.returncode or 1



def probe(a):
    s = load('fleet-node-supervisor')
    p = s.Paths()
    st = s.read_json(p.state_file, {})
    code, _ = s.health(p, st)
    if code:
        return 1
    if a.action == 'live':
        return 0  # hub/credential outages are not reasons to restart the pod
    if not Path('/run/fleet-node-ready').exists() or s.lanes_now(p, st):
        return 1
    for name in ('node-agent', 'cred-proxy-shared', 'sshd'):
        if not s.pid_alive((st.get('children', {}).get(name) or {}).get('pid')):
            return 1
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'activate', 'bootstrap', 'foreground', 'live', 'ready'))
    ap.add_argument('--login', default=os.environ.get('FLEET_NODE_LOGIN', 'fleet'))
    ap.add_argument('--uid', type=int, default=int(os.environ.get('FLEET_NODE_UID', '10002')))
    ap.add_argument('--hub', default=os.environ.get('FLEET_HUB_URL', ''))
    ap.add_argument('--relay', default=os.environ.get('FLEET_CRED_RELAY_URL', 'https://fleet-relay.24hw.cn'))
    ap.add_argument('--join-file', default=os.environ.get('FLEET_LOGIN_JOIN_FILE', ''))
    ap.add_argument('--machine-join-file', default=os.environ.get('FLEET_MACHINE_JOIN_FILE', ''))
    a = ap.parse_args()
    if (os.geteuid() != 0 and a.action != 'activate') or not sys.platform.startswith('linux'):
        ap.error('run as root on Linux')
    try:
        return {'prepare': prepare, 'activate': activate, 'bootstrap': bootstrap, 'foreground': foreground,
                'live': probe, 'ready': probe}[a.action](a) or 0
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as e:
        # Never print HTTP bodies, tokens or the enrollment command arguments.
        print('fleet-node-linux: %s' % (str(e) if not isinstance(e, subprocess.SubprocessError)
                                       else 'child command failed; see preceding step'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
