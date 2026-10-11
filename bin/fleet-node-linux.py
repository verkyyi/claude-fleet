#!/usr/bin/env python3
"""Linux managed-node bootstrap and foreground container lifecycle (#3022).

Root opens and removes non-sudo tenants — `login open|remove|list`, the one
road (EPIC #3208 C1, the Linux twin of fleet-login-new.sh / fleet-login-remove.sh;
nothing else here runs useradd / userdel). Each login is declared on the volume
(linux-tenants/<login>.json, its UID never reused) and `boot` rebuilds every one
before the supervisor starts. Machine and tenants use separate hub join codes and
retain their own tokens. This uses the existing supervisor, shared credential
store and login bootstrap; it never starts a second node agent.

login open <login> [--full-name N] [--join-file F]   exit 0 · 3 bad argument ·
login remove <login> --keep-home|--delete-home       4 no such login (remove) ·
login list   → <login> <uid> <home> <state>           5 an administrator already;
                                                      last line `credsep: <word>`
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
import shutil
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
    # Some store subdirectories belong to the credential role. Walk with
    # directory descriptors and O_NOFOLLOW so a replaced parent cannot turn
    # root's atomic write/chown into a write anywhere else on the machine.
    path = Path(path).absolute()
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parent = os.open('/', flags)
    tmp = path.name + '.tmp-' + uuid.uuid4().hex
    try:
        for part in path.parent.parts[1:]:
            try:
                child = os.open(part, flags, dir_fd=parent)
            except FileNotFoundError:
                os.mkdir(part, 0o700, dir_fd=parent)
                child = os.open(part, flags, dir_fd=parent)
                os.fchown(child, uid, gid)
            os.close(parent)
            parent = child
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'w') as f:
            os.fchown(f.fileno(), uid, gid)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path.name, src_dir_fd=parent, dst_dir_fd=parent)
    finally:
        try:
            os.unlink(tmp, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def env_read(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return {}
    with os.fdopen(fd) as f:
        return dict(line.split('=', 1) for line in f.read().splitlines()
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


# ---------------------------------------------------------------- tenants ----
# One declaration per login on the volume (EPIC #3208 convention 2): /etc/passwd
# lives in the image layer and is gone on every container start, so the volume's
# linux-tenants/<login>.json is the truth boot rebuilds from. A UID is never
# reused: .next-uid is the high-water mark and .retired the removed ones.
FIRST_UID = 10002
RESERVED = ('root', 'admin', 'daemon', 'nobody', 'guest', 'shared')


class Refuse(ValueError):
    """An argument the caller must change (exit 3) — or, with rc 5, a name that
    is already an administrator."""

    def __init__(self, msg, rc=3):
        super().__init__(msg)
        self.rc = rc


class NoLogin(ValueError):
    """remove: no such login here (exit 4, fleet-login-remove.sh's)."""


def valid_name(login):
    # control.ValidCreateLogin(login, existing=true): a digit may lead
    # (`24haowan`), never all digits — a numeric name reads as a UID.
    return (isinstance(login, str) and 2 <= len(login) <= 16 and login not in RESERVED
            and re.fullmatch(r'[a-z0-9]+', login) is not None and re.search(r'[a-z]', login) is not None)


def valid_full_name(name):
    # control.ValidFullName, plus the two characters a passwd GECOS cannot hold.
    return (0 < len(name) <= 64 and not name.startswith('-')
            and not any(ord(ch) < 32 or ord(ch) == 127 or ch in ':,' for ch in name))


def tenants_dir(paths):
    return Path(paths.state) / 'linux-tenants'


def tenant_path(paths, login):
    return tenants_dir(paths) / (login + '.json')


def _num(path, default=0):
    try:
        return int(Path(path).read_text().strip() or default)
    except (OSError, ValueError):
        return default


def retired_uids(paths):
    try:
        return {int(x) for x in (tenants_dir(paths) / '.retired').read_text().split() if x.isdigit()}
    except OSError:
        return set()


def tenants(paths):
    """{login: declaration} — every login this machine opened, read from the volume."""
    migrate_legacy(paths)
    out = {}
    d = tenants_dir(paths)
    for f in sorted(d.glob('*.json')) if d.is_dir() else []:
        try:
            t = json.loads(f.read_text())
        except (OSError, ValueError):
            raise ValueError('unreadable tenant declaration %s' % f) from None
        if t.get('login') != f.stem or not isinstance(t.get('uid'), int) or t.get('gid') != t.get('uid'):
            raise ValueError('tenant declaration %s does not match its name/UID' % f)
        out[f.stem] = t
    return out


def migrate_legacy(paths):
    # compat-1v: 下一批删 — the single-login linux-tenant.json (#3022) becomes
    # linux-tenants/<login>.json; the old file stays beside it as .bak.
    old = Path(paths.state) / 'linux-tenant.json'
    if not old.is_file():
        return
    t = json.loads(old.read_text())
    login = t.get('login', '')
    new = tenant_path(paths, login)
    if not new.exists():
        if not re.fullmatch(r'[a-z][a-z0-9_-]{0,30}', login) or int(t.get('uid', 0)) < 1000:
            raise ValueError('legacy linux-tenant.json is not a valid declaration')
        t.setdefault('since', int(old.stat().st_mtime))
        private_write(new, json.dumps(t, sort_keys=True) + '\n')
        nxt = tenants_dir(paths) / '.next-uid'
        if _num(nxt, FIRST_UID) <= t['uid']:
            private_write(nxt, '%d\n' % (t['uid'] + 1))
    os.replace(old, str(old) + '.bak')


def uid_taken(uid):
    for look in (pwd.getpwuid, grp.getgrgid):
        try:
            look(uid)
            return True
        except KeyError:
            pass
    return False


def allocate_uid(paths, declared, want=None):
    """The next number never handed out on this volume (or `want`, checked)."""
    used = {t['uid'] for t in declared.values()} | retired_uids(paths)
    if want is not None:
        if want < 1000 or want in used or uid_taken(want):
            raise Refuse('UID %d is taken, retired or below 1000' % want)
        uid = want
    else:
        uid = max([_num(tenants_dir(paths) / '.next-uid', FIRST_UID), FIRST_UID] + [u + 1 for u in used])
        while uid in used or uid_taken(uid):
            uid += 1
    private_write(tenants_dir(paths) / '.next-uid',
                  '%d\n' % max(uid + 1, _num(tenants_dir(paths) / '.next-uid', FIRST_UID)))
    return uid


def _bad_name_flag(tool, login):
    # Debian's shadow refuses a digit-leading name unless told; the flag's
    # spelling moved between shadow versions (convention 5: this one place).
    if not login[0].isdigit():
        return []
    try:
        helptext = subprocess.run([tool, '--help'], capture_output=True, text=True).stdout
    except OSError:
        return []
    return [f for f in ('--badname', '--badnames') if f in helptext][:1]


def owner_of(path):
    st = os.lstat(path)
    return st.st_uid, st.st_gid


def check_home(t):
    """A home that exists belongs to its declared UID — or nothing goes on.
    Never chown: a wrong owner means another person's files (linux-uid-reuse)."""
    home = Path(t['home'])
    if home.is_symlink():
        raise ValueError('tenant home %s must not be a symlink' % home)
    if home.exists():
        owner = owner_of(home)
        if owner != (t['uid'], t['gid']):
            raise ValueError('home %s belongs to %d:%d, not %s (%d) — stopped, nothing chowned'
                             % ((home,) + owner + (t['login'], t['uid'])))
        return True
    return False


def make_user(t, full_name=''):
    """groupadd/useradd exactly as declared; an existing entry must match it."""
    login, uid = t['login'], t['uid']
    try:
        g = grp.getgrnam(login)
        if g.gr_gid != uid:
            raise ValueError('group %s has GID %d, declared %d' % (login, g.gr_gid, uid))
    except KeyError:
        subprocess.run(['groupadd'] + _bad_name_flag('groupadd', login) + ['--gid', str(uid), login], check=True)
    try:
        p = pwd.getpwnam(login)
    except KeyError:
        try:
            other = pwd.getpwuid(uid).pw_name
        except KeyError:
            other = None
        if other:
            raise ValueError('UID %d already belongs to %s' % (uid, other))
        subprocess.run(['useradd'] + _bad_name_flag('useradd', login) +
                       ['--uid', str(uid), '--gid', str(uid), '--no-create-home', '--home-dir', t['home'],
                        '--shell', '/bin/zsh'] + (['--comment', full_name] if full_name else []) + [login], check=True)
        p = pwd.getpwnam(login)
    if (p.pw_uid, p.pw_gid, p.pw_dir) != (uid, uid, t['home']):
        raise ValueError('existing login %s does not match the declared UID/GID/home' % login)
    return p


def boot(a=None):
    """Container start, before the supervisor: every declared login back with
    its own number and home. A home owned by anyone else stops the boot."""
    s = load('fleet-node-supervisor')
    paths = s.Paths()
    declared = tenants(paths)
    for t in sorted(declared.values(), key=lambda t: t['uid']):
        check_home(t)
        make_user(t)
        if Path(t['home']).exists():
            os.chmod(t['home'], 0o700)
    attic_sweep(paths)
    print('boot: %d login(s) restored: %s' % (len(declared), ' '.join(sorted(declared)) or '-'))


def attic_sweep(paths):
    days = float(os.environ.get('FLEET_NODE_ATTIC_HOME_DAYS', '30'))
    attic = Path(paths.users) / '.attic'
    for f in attic.glob('*.tar.gz') if attic.is_dir() else []:
        if time.time() - f.stat().st_mtime > days * 86400:
            f.unlink()


def tenants_lock(paths):
    tenants_dir(paths).mkdir(parents=True, exist_ok=True)
    os.chmod(tenants_dir(paths), 0o700)
    f = open(tenants_dir(paths) / '.lock', 'a')
    fcntl.flock(f, fcntl.LOCK_EX)
    return f


def ensure_login(s, paths, login, uid=None, full_name=''):
    """Declare (number from the allocator), create and home one login."""
    if not valid_name(login) and not tenant_path(paths, login).exists():
        raise Refuse('login %r: 2-16 of a-z0-9, at least one letter' % login)
    declared = tenants(paths)
    t = declared.get(login)
    if t is None:
        try:
            p = pwd.getpwnam(login)
        except KeyError:
            p = None
        if p is not None:
            why, _ = s.tenant_privileges(login)
            if why:
                raise Refuse('%s is already an administrator here (%s)' % (login, why), rc=5)
            raise Refuse('login %s already exists outside fleet-node-linux; choose a fresh name' % login)
        uid = allocate_uid(paths, declared, uid)
        t = {'login': login, 'uid': uid, 'gid': uid, 'home': str(Path(paths.users) / login), 'since': int(time.time())}
        # Declared before passwd changes, so an interrupted open is reconciled by
        # the next open or boot rather than leaving an unnamed number behind.
        private_write(tenant_path(paths, login), json.dumps(t, sort_keys=True) + '\n')
    elif uid is not None and uid != t['uid']:
        raise ValueError('tenant identity differs from the persistent volume; use the original login/UID')
    had = check_home(t)
    p = make_user(t, full_name)
    why, complete = s.tenant_privileges(login)
    if why or not complete:
        raise Refuse('tenant must have no admin/sudo/container-management privileges', rc=5)
    if not had:
        home = Path(t['home'])
        home.parent.mkdir(parents=True, exist_ok=True)
        home.mkdir(mode=0o700)
        os.chown(home, t['uid'], t['gid'])
    os.chmod(t['home'], 0o700)
    return p


def machine_hub(paths, hub):
    return (hub or env_read(Path(paths.state) / 'machine.env').get('CCQUOTA_HUB_URL', '')).rstrip('/')


def prepare(a):
    """compat-1v: 下一批删 — the old single-login verb; `login open` now."""
    a.name, a.full_name, a.start = a.login, '', False
    return login_open(a)


def login_open(a):
    s = load('fleet-node-supervisor')
    paths = s.Paths()
    login = a.name
    if not valid_name(login) and not tenant_path(paths, login).exists():
        raise Refuse('login %r: 2-16 of a-z0-9, at least one letter' % login)
    if a.full_name and not valid_full_name(a.full_name):
        raise Refuse('full name: 1-64 characters, no control characters, no : or ,, not starting with -')
    code = None
    # A restart after the one-time Secret is gone has no file: read only when given.
    if a.join_file and os.path.exists(a.join_file):
        try:
            code = Path(a.join_file).read_text().strip()
        except OSError:
            raise Refuse('cannot read the join file') from None
        if not re.fullmatch(r'fj_[a-z2-7]{26}', code):
            raise Refuse('invalid tenant join code')
    if not Path(paths.state, 'machine.env').is_file():
        raise ValueError('enroll the machine with fleet node install first')
    hub = machine_hub(paths, a.hub)
    if not hub:
        raise ValueError('no hub URL (--hub, or CCQUOTA_HUB_URL in machine.env)')
    os.environ.setdefault('FLEET_NODE_SERVICE', 'systemd')
    with tenants_lock(paths):
        p = ensure_login(s, paths, login, getattr(a, 'uid', None), a.full_name)
    conf = Path(p.pw_dir) / '.config/claude-fleet'
    # User-owned files are written after dropping privileges, including on retry.
    as_tenant(s, login, ['python3', '-c',
        'from pathlib import Path; p=Path.home()/".config/claude-fleet"; p.mkdir(parents=True,exist_ok=True); '
        'f=p/"fleet.conf"; '
        'f.write_text("[common]\\nFLEET_CRED_PROXY=1\\nFLEET_CRED_SEPARATE=1\\n") if not f.exists() else None'])
    c = load('fleet-credsep')
    # The node store, never the tenant's home, holds the token from its first byte.
    c.ensure_role()
    role = pwd.getpwnam(c.ROLE)
    store = Path(c.ROOT_BASE) / login
    store.mkdir(parents=True, exist_ok=True)
    os.chmod(store, 0o700)
    os.chown(store, role.pw_uid, role.pw_gid)
    token_path = store / 'node.env'
    ne = env_read(token_path)
    if ne.get('CCQUOTA_TOKEN'):
        if ne.get('CCQUOTA_HUB_URL') != hub:
            raise ValueError('persisted tenant belongs to a different hub')
        # Never re-enroll on a network/auth failure: that would fork the identity.
        request(hub, '/v1/node/self', ne['CCQUOTA_TOKEN'])
    else:
        if not code:
            raise Refuse('first tenant enrollment needs --join-file (a second trusted hub join code)')
        joined = request(hub, '/v1/node/join', body={
            'code': code, 'hostname': socket.gethostname(), 'os_user': login})
        token = joined.get('token') or joined.get('agent_token')
        if not isinstance(token, str) or not token or '\n' in token:
            raise ValueError('hub returned no tenant token')
        ne = {'CCQUOTA_HUB_URL': hub, 'CCQUOTA_TOKEN': token,
              'CCQUOTA_FLEET': '1', 'CCQUOTA_FLEET_COMPUTE': '1', 'CCQUOTA_FLEET_CREDS': '1'}
        private_write(token_path, ''.join(k + '=' + v + '\n' for k, v in ne.items()), role.pw_uid, role.pw_gid)
    # The pool reaches a login only through its own lease (issue #3211): the node
    # program leases — into the shared proxy, the label marker into accounts/ —
    # only for a login whose env says CCQUOTA_FLEET_CREDS=1, as a Mac login's
    # does. A store written before this has none: add it, every other line kept.
    if ne.get('CCQUOTA_FLEET_CREDS') != '1':
        ne['CCQUOTA_FLEET_CREDS'] = '1'
        private_write(token_path, ''.join(k + '=' + v + '\n' for k, v in ne.items()), role.pw_uid, role.pw_gid)
    # These are root-authored route settings; a tenant cannot redirect its token.
    lib = Path(c.LIB)
    lib.mkdir(parents=True, exist_ok=True)
    route = {'FLEET_HUB_URL': hub, 'FLEET_CRED_RELAY_URL': a.relay}
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
    setting_path = lib / (login + '.conf')
    settings = env_read(setting_path)
    settings.update(route)
    private_write(setting_path, ''.join(k + '=' + v + '\n' for k, v in settings.items()))
    # machine install keeps every tenant the shared proxy already serves.
    c.machine_install(argparse.Namespace(logins=login, force=False))
    # A readable token-free node.pub.env and an unreadable node.env pointer are
    # needed by the shell helpers; create them as the tenant, not by root in HOME.
    public = {k: v for k, v in ne.items() if k != 'CCQUOTA_TOKEN'}
    public['CCQUOTA_FLEET_CRED_STORE'] = str(Path(c.SHARED_RUN) / 'ctl.sock')
    as_tenant(s, login, ['python3', '-c',
        'import pathlib,sys; p=pathlib.Path(sys.argv[1]); '
        '(p/"node.pub.env").write_text(sys.argv[2]); '
        'f=p/"node.env"; f.unlink(missing_ok=True); f.symlink_to(sys.argv[3])',
        str(conf), ''.join(k + '=' + v + '\n' for k, v in public.items()), str(token_path)])
    relay = request(hub, '/v1/node/relay-credential', ne['CCQUOTA_TOKEN'], {})
    relay_token = relay.get('token') or relay.get('credential')
    if not isinstance(relay_token, str) or not relay_token:
        raise ValueError('hub returned no relay pass; verify tenant trust')
    private_write(store / 'cred-proxy/relay.token', relay_token + '\n', role.pw_uid, role.pw_gid)
    machine_env = dict(ne, FLEET_CONF_DIR=str(conf), CCQUOTA_FLEET_CRED_STORE=str(Path(c.SHARED_RUN) / 'ctl.sock'))
    s.write_login_env(paths, login, machine_env)
    os.environ['FLEET_NODE_ADOPT_FOLLOW'] = '0'
    if s.account_adopt(paths, login):
        raise ValueError('supervisor refused tenant adoption')
    print('prepared tenant %s (UID %d); credentials separated' % (login, p.pw_uid))
    if a.start:
        bootstrap(argparse.Namespace(login=login))
    # Opened with --no-start (the installer, before the proxy runs): no wait.
    word, rc = credsep_word(s, login, conf, int(os.environ.get('FLEET_LOGIN_CREDSEP_WAIT', '15')) if a.start else 0)
    print('credsep: ' + word)
    return rc


def credsep_word(s, login, conf, wait):
    """fleet-login-new.sh's one judgement: status separated AND check OK."""
    st = as_tenant(s, login, [sys.executable, '-I', str(HERE / 'fleet-credsep.py'), 'status', '--conf-dir', str(conf)],
                   check=False, capture_output=True, text=True)
    if st.returncode:
        return 'not separated', 1
    for t in range(wait + 1):
        ck = as_tenant(s, login, [sys.executable, '-I', str(HERE / 'fleet-credsep.py'), 'check', '--conf-dir', str(conf)],
                       check=False, capture_output=True, text=True)
        if ck.returncode == 0:
            return 'separated', 0
        if t < wait:
            time.sleep(1)
    why = (ck.stdout + ck.stderr).strip().splitlines()
    return 'pending — ' + (why[-1] if why else 'check rc %d' % ck.returncode), 0


def live_pids(uid):
    """Processes of a real UID that still run — a zombie waits on its parent's
    reap, it holds nothing of the login (pgrep would count it)."""
    out = []
    for d in Path('/proc').glob('[0-9]*'):
        try:
            st = dict(line.split(':', 1) for line in (d / 'status').read_text().splitlines() if ':' in line)
        except OSError:
            continue
        if int(st.get('Uid', '-1').split()[0]) == uid and not st.get('State', '').strip().startswith(('Z', 'X')):
            out.append(int(d.name))
    return out


def kill_uid(uid, rounds=3):
    for _ in range(rounds):
        subprocess.run(['pkill', '-KILL', '-U', str(uid)], check=False)
        time.sleep(0.5)
        if not live_pids(uid):
            return
    raise RuntimeError('processes still run as UID %d after three kills; stopped before deleting the login' % uid)


def login_remove(a):
    s = load('fleet-node-supervisor')
    paths = s.Paths()
    login = a.name
    with tenants_lock(paths):
        declared = tenants(paths)
        t = declared.get(login)
        if t is None:
            try:
                pwd.getpwnam(login)
            except KeyError:
                raise NoLogin('no login %s on this machine: nothing to remove' % login) from None
            raise Refuse('%s was not opened by fleet-node-linux; not removing it' % login)
        try:
            p = pwd.getpwnam(login)
        except KeyError:
            p = None        # a boot that has not recreated it yet: the rest still goes
        print('[1] stop %s\'s live fleet' % login)
        if p is not None:
            as_tenant(s, login, ['bash', '-c', 'source "$1"; while IFS= read -r sess; do [ -n "$sess" ] || continue; '
                                 'bash "$2" "$sess" --yes; done < <(fleet_sockets)', '_',
                                 str(HERE / 'fleet-lib.sh'), str(HERE / 'fleet-down.sh')], check=False,
                      stdin=subprocess.DEVNULL)
        print('[1b] take %s off the hub (node leave)' % login)
        c = load('fleet-credsep')
        ne = env_read(Path(c.ROOT_BASE) / login / 'node.env')
        if ne.get('CCQUOTA_TOKEN') and ne.get('CCQUOTA_HUB_URL'):
            try:
                request(ne['CCQUOTA_HUB_URL'], '/v1/node/leave', ne['CCQUOTA_TOKEN'], {'reason': 'login %s removed' % login})
            except (RuntimeError, OSError, ValueError) as e:
                if 'HTTP 401' not in str(e):
                    print('WARN %s was not taken off the hub (%s) — remove it on the machines page' % (login, e),
                          file=sys.stderr)
        print('[1c] take %s out of the machine daemon (account forget)' % login)
        rc = s.account_forget(paths, login)
        if rc:
            return rc
        print('[2b] remove %s\'s credential separation' % login)
        c.purge(argparse.Namespace(login=login))
        print('[4] stop remaining processes of UID %d' % t['uid'])
        kill_uid(t['uid'])
        home = Path(t['home'])
        archive = None
        if a.home == 'keep' and home.is_dir():
            print('[5] archive %s' % home)
            attic = Path(paths.users) / '.attic'
            attic.mkdir(mode=0o700, exist_ok=True)
            os.chmod(attic, 0o700)
            archive = attic / ('%s-%s.tar.gz' % (login, time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())))
            tar = subprocess.run(['tar', '-czf', str(archive), '--exclude=./.cache', '-C', str(home), '.'],
                                 capture_output=True, text=True)
            os.chmod(archive, 0o600)
            if subprocess.run(['tar', '-tzf', str(archive)], capture_output=True).returncode:
                raise RuntimeError('home archive did not read back (tar rc %d); the login is kept' % tar.returncode)
        print('[6] delete the OS login and its home')
        if p is not None:
            subprocess.run(['userdel', login], check=True)
        try:
            grp.getgrnam(login)
            subprocess.run(['groupdel', login], check=True)
        except KeyError:
            pass
        if home.is_dir() and not home.is_symlink():
            shutil.rmtree(home)
        s.remove_login_env(paths, login)
        retired = sorted(retired_uids(paths) | {t['uid']})
        private_write(tenants_dir(paths) / '.retired', ''.join('%d\n' % u for u in retired))
        tenant_path(paths, login).unlink()
    print('removed %s (UID %d retired)%s' % (login, t['uid'], '; home archived: %s' % archive if archive else ''))
    print('credsep: purged')
    return 0


def login_list(a):
    s = load('fleet-node-supervisor')
    paths = s.Paths()
    for login, t in sorted(tenants(paths).items(), key=lambda kv: kv[1]['uid']):
        try:
            p = pwd.getpwnam(login)
            state = 'ok' if (p.pw_uid, p.pw_dir) == (t['uid'], t['home']) else 'mismatch'
        except KeyError:
            state = 'missing'
        if state == 'ok' and not Path(t['home']).is_dir():
            state = 'no-home'
        print('%s %d %s %s' % (login, t['uid'], t['home'], state))
    return 0


def login_cmd(rest):
    lp = argparse.ArgumentParser(prog='fleet-node-linux.py login')
    sub = lp.add_subparsers(dest='verb', required=True)
    o = sub.add_parser('open')
    o.add_argument('name')
    o.add_argument('--full-name', default='')
    o.add_argument('--join-file', default='')
    o.add_argument('--hub', default=os.environ.get('FLEET_HUB_URL', ''))
    o.add_argument('--relay', default=os.environ.get('FLEET_CRED_RELAY_URL', 'https://fleet-relay.24hw.cn'))
    o.add_argument('--uid', type=int, default=None)
    o.add_argument('--no-start', dest='start', action='store_false')
    r = sub.add_parser('remove')
    r.add_argument('name')
    hm = r.add_mutually_exclusive_group(required=True)
    hm.add_argument('--keep-home', dest='home', action='store_const', const='keep')
    hm.add_argument('--delete-home', dest='home', action='store_const', const='delete')
    sub.add_parser('list')
    try:
        a = lp.parse_args(rest)
    except SystemExit as e:
        return 3 if e.code else 0
    return {'open': login_open, 'remove': login_remove, 'list': login_list}[a.verb](a)


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
        # passwd is the image's: every declared login back before anything runs as one.
        boot()
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
        s = load('fleet-node-supervisor')
        logins = sorted(set(tenants(s.Paths())) | {a.login})
        try:
            for login in logins:
                try:
                    bootstrap(argparse.Namespace(login=login))
                except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as e:
                    if login == a.login:
                        raise
                    # One person's broken home never keeps the others' sessions down.
                    print('bootstrap %s failed (%s); the other logins go on' % (login, e), file=sys.stderr)
            ready.write_text(os.environ['FLEET_NODE_BOOT_ID'])
            while child.poll() is None and not stopping:
                time.sleep(1)
        finally:
            ready.unlink(missing_ok=True)
            for login in logins:
                try:
                    as_tenant(s, login, ['bash', str(HERE / 'fleet-sessions-snapshot.sh'), 'save'], timeout=30)
                except (subprocess.SubprocessError, OSError, KeyError):
                    print('snapshot of %s failed; periodic persisted snapshot remains' % login, file=sys.stderr)
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
    if sys.argv[1:2] == ['login']:
        if os.geteuid() != 0 or not sys.platform.startswith('linux'):
            print('fleet-node-linux: run as root on Linux', file=sys.stderr)
            return 3
        return guarded(lambda: login_cmd(sys.argv[2:]))
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('boot', 'prepare', 'activate', 'bootstrap', 'foreground', 'live', 'ready'))
    ap.add_argument('--login', default=os.environ.get('FLEET_NODE_LOGIN', 'fleet'))
    ap.add_argument('--uid', type=int, default=int(os.environ.get('FLEET_NODE_UID', '10002')))
    ap.add_argument('--hub', default=os.environ.get('FLEET_HUB_URL', ''))
    ap.add_argument('--relay', default=os.environ.get('FLEET_CRED_RELAY_URL', 'https://fleet-relay.24hw.cn'))
    ap.add_argument('--join-file', default=os.environ.get('FLEET_LOGIN_JOIN_FILE', ''))
    ap.add_argument('--machine-join-file', default=os.environ.get('FLEET_MACHINE_JOIN_FILE', ''))
    a = ap.parse_args()
    if (os.geteuid() != 0 and a.action != 'activate') or not sys.platform.startswith('linux'):
        ap.error('run as root on Linux')
    return guarded(lambda: {'boot': boot, 'prepare': prepare, 'activate': activate, 'bootstrap': bootstrap,
                            'foreground': foreground, 'live': probe, 'ready': probe}[a.action](a) or 0)


def guarded(fn):
    try:
        return fn()
    except Refuse as e:
        print('fleet-node-linux: %s' % e, file=sys.stderr)
        return e.rc
    except NoLogin as e:
        print('fleet-node-linux: %s' % e, file=sys.stderr)
        return 4
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as e:
        # Never print HTTP bodies, tokens or the enrollment command arguments.
        print('fleet-node-linux: %s' % (str(e) if not isinstance(e, subprocess.SubprocessError)
                                       else 'child command failed; see preceding step'), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
