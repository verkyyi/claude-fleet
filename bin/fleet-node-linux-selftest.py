#!/usr/bin/env python3
"""Linux managed lifecycle contracts (#3022), isolated from the live install."""
import importlib.util
import io
from contextlib import redirect_stderr
import os
from pathlib import Path
import tempfile
import unittest
import json
import re
import hashlib
import subprocess
import sys
from unittest.mock import patch, Mock

BIN = Path(__file__).resolve().parent
REAL_RUN = subprocess.run


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), BIN / (name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class LinuxNode(unittest.TestCase):
    def test_native_stop_fixture_resolves_namespace_pid_without_guessing(self):
        probe = module('fleet-native-thread-stop-selftest')
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            process = proc / '4242'
            process.mkdir()
            argv = ['/usr/bin/python3', '-c', 'fixture', str(proc / 'unique-command')]
            command = b'\0'.join(os.fsencode(argument) for argument in argv) + b'\0'
            (process / 'cmdline').write_bytes(command)
            (process / 'status').write_text('Name:\tpython3\nNSpid:\t4242\t7\n')
            self.assertEqual(probe.fixture_host_pid(argv, 7, proc), 4242)
            for arguments, namespace in ((argv, 8), (argv[:-1], 7)):
                with self.assertRaises(AssertionError):
                    probe.fixture_host_pid(arguments, namespace, proc)
            with patch.object(probe.os, 'getuid', return_value=os.getuid() + 1):
                with self.assertRaises(AssertionError):
                    probe.fixture_host_pid(argv, 7, proc)
            duplicate = proc / '4343'
            duplicate.mkdir()
            (duplicate / 'cmdline').write_bytes(command)
            (duplicate / 'status').write_text('NSpid:\t4343\t7\n')
            with self.assertRaises(AssertionError):
                probe.fixture_host_pid(argv, 7, proc)

    def test_image_carries_native_sandbox_dependency_without_changing_policy(self):
        docker = (BIN.parent / 'extras/managed-node/Dockerfile').read_text()
        runtime = docker.split('FROM ${BASE}', 1)[1]
        self.assertRegex(runtime, r'apt-get install -y --no-install-recommends[\s\S]*?\bbubblewrap\b')
        self.assertIn('&& bwrap --version', runtime)
        workflow = (BIN.parent / '.github/workflows/native-managed-hooks.yml').read_text()
        self.assertIn('bubblewrap apparmor-profiles apparmor-utils', workflow)
        self.assertIn('"$RUNNER_ENVIRONMENT" = github-hosted', workflow)
        self.assertIn('apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict', workflow)
        self.assertIn('bwrap --unshare-user --unshare-pid --unshare-net --ro-bind / /', workflow)
        for text in (runtime, workflow):
            self.assertNotIn('sysctl -w', text)
            self.assertNotIn('seccomp=unconfined', text)
            self.assertNotIn('apparmor=unconfined', text)
            self.assertNotIn('--privileged', text)

    def test_linux_paths_and_systemd_environment(self):
        s = module('fleet-node-supervisor')
        with patch.object(s, 'MAC', False), patch.dict(os.environ, {
                'FLEET_NODE_ROOT': '/opt/fleet', 'FLEET_NODE_STATE': '/data/node',
                'FLEET_NODE_USERS': '/home', 'FLEET_NODE_RUNTIME': '/opt/fleet/current',
                'FLEET_NODE_DAEMON_DIR': '/etc/systemd/system'}):
            p = s.Paths()
            self.assertEqual(p.plist, '/etc/systemd/system/claude-fleet-node.service')
            unit = s.systemd_body(p)
            self.assertIn('"FLEET_NODE_STATE=/data/node"', unit)
            self.assertIn('ExecStart="/usr/bin/python3" "-I"', unit)
            self.assertNotIn('CCQUOTA_TOKEN', unit)
            child = s.Supervisor.__new__(s.Supervisor)
            child.p = p
            self.assertEqual(child.child_env({})['FLEET_NODE_ROOT'], '/opt/fleet')
            tenant = s.account_entry({'name': 'test', 'argv': ['/bin/true']}, 'fleet',
                                     (10002, 10002, '/home/fleet'), '/usr')
            self.assertEqual(tenant['env']['FLEET_NODE_STATE'], '/data/node')

    def test_image_table_has_no_updater(self):
        s = module('fleet-node-supervisor')
        with patch.dict(os.environ, {'FLEET_NODE_UPDATE_OWNER': 'image'}):
            self.assertNotIn('update', [x['name'] for x in s.default_table(s.Paths())['tasks']])
            pool = next(x for x in s.default_table(s.Paths())['tasks'] if x['name'] == 'credential-pool')
            self.assertEqual(pool['cmd'][-2:], ['machine', 'pool-sync'])
        with patch.dict(os.environ, {'FLEET_NODE_UPDATE_OWNER': 'hub'}):
            self.assertIn('update', [x['name'] for x in s.default_table(s.Paths())['tasks']])

    def test_sshd_path_and_supervision_are_independent(self):
        s = module('fleet-node-supervisor')
        with patch.object(s, 'MAC', False), patch.dict(os.environ, {
                'FLEET_NODE_RUN_SSHD': '1', 'FLEET_NODE_SSHD': '/usr/sbin/sshd'}):
            child = next(x for x in s.default_table(s.Paths())['children'] if x['name'] == 'sshd')
            self.assertEqual(child['cmd'][0], '/usr/sbin/sshd')

    def test_bootstrap_refreshes_image_before_restore_and_allows_empty_snapshot(self):
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {'FLEET_NODE_ROOT': d}), \
                patch.object(m, 'load'), patch.object(m.Path, 'exists', return_value=True), \
                patch.object(m, 'as_tenant', return_value=Mock(returncode=3)) as run:
            Path(d, 'current').symlink_to('a' * 40)
            m.bootstrap(Mock(login='fleet'))
            commands = [c.args[2] for c in run.call_args_list]
            self.assertEqual(commands[0][-1], 'activate')
            self.assertTrue(commands[1][-1].endswith('fleet-login-bootstrap.sh'))
            self.assertEqual(commands[2][-1], 'restore')

    def test_failed_restore_keeps_the_machine_ready(self):
        """BREAK-IT linux-restore-crashloop (#3289): restore exit 1 once raised out of
        bootstrap and foreground exited — the container crash-looped on the same
        snapshot. Now bootstrap sets the snapshot aside and foreground writes ready."""
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            conf = Path(d, 'conf')
            (conf / 'global').mkdir(parents=True)
            snap = conf / 'global/sessions.snapshot'
            snap.write_text('# fleet-sessions-snapshot v1\nfleet\twork\t/home/fleet\n')
            env = {'FLEET_CONF_DIR': str(conf)}
            with patch.object(m, 'load'), patch.object(m.Path, 'exists', return_value=True), \
                    patch.object(m, 'tenant_env', return_value=(None, env)), \
                    patch.object(m, 'as_tenant', return_value=Mock(returncode=1)):
                m.bootstrap(Mock(login='fleet'))
            self.assertFalse(snap.exists())
            kept = list((conf / 'global').glob('sessions.snapshot.failed-*'))
            self.assertEqual(len(kept), 1)
            self.assertIn('work', kept[0].read_text())

            # foreground: a failed restore on the container's own login still reaches ready
            state, run = Path(d, 'state'), Path(d, 'run')
            run.mkdir()
            seen = []
            real = m.Path

            def path(*parts):
                p = real(*parts)
                return run / p.name if str(p).startswith('/run/') or str(p).startswith('/etc/ssh') else p

            (run / 'cred/.shared').mkdir(parents=True)
            (run / 'cred/.shared/ctl.sock').write_text('')
            loop = Mock()
            loop.bin.return_value = Path(d)
            loop.tend.side_effect = lambda: seen.append((run / 'fleet-node-ready').exists()) or 0
            with patch.dict(os.environ, {'FLEET_NODE_STATE': str(state), 'FLEET_CREDSEP_RUN_BASE': str(run / 'cred')}), \
                    patch.object(m, 'Path', side_effect=path), patch.object(m, 'boot'), \
                    patch.object(m, 'lib_owner_heal'), patch.object(m, 'route_heal'), \
                    patch.object(m, 'Loop', return_value=loop), patch.object(m, 'load'), \
                    patch.object(m, 'tenants', return_value=[]), \
                    patch.object(m, 'as_tenant', return_value=Mock(returncode=1)), \
                    patch.object(m, 'tenant_env', return_value=(None, env)), \
                    patch.object(m.subprocess, 'run'), patch.object(m.signal, 'signal'):
                (state / 'ssh').mkdir(parents=True)
                (state / 'ssh/ssh_host_ed25519_key').write_text('k')
                m.foreground(Mock(login='fleet', hub='h', join_file='j', machine_join_file=''))
            self.assertEqual(seen, [True])  # ready was written, the loop ran

    def test_image_replacement_and_rollback_keep_home_and_retry_failed_apply(self):
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            home, root = Path(d, 'home'), Path(d, 'runtime')
            home.mkdir()
            root.mkdir()
            for sha in ('a' * 40, 'b' * 40):
                b = root / sha / 'bin'
                b.mkdir(parents=True)
                (b / 'fleet-install-apply.sh').write_text(
                    '#!/bin/bash\n[ ! -f "$HOME/fail-apply" ] || exit 7\n'
                    'echo applied >> "$HOME/applies"\n')
                (b / 'version').write_text(sha)
            cur = root / 'current'
            cur.symlink_to('a' * 40)
            with patch.dict(os.environ, {'HOME': str(home), 'FLEET_NODE_ROOT': str(root),
                                         'FLEET_INSTALL_PLATFORM': 'none'}):
                m.activate(None)
                live = home / '.claude/fleet'
                (live / 'logs').mkdir(exist_ok=True)
                (live / 'logs/kept').write_text('history')
                (home / 'project').write_text('worktree')
                marker = home / '.config/claude-fleet/global/linux-image-applied'
                m.activate(None)
                self.assertEqual((home / 'applies').read_text().splitlines(), ['applied'])
                cur.unlink()
                cur.symlink_to('b' * 40)
                # The previous image's runtime disappears, as on Kubernetes.
                import shutil
                shutil.rmtree(root / ('a' * 40))
                (home / 'fail-apply').touch()
                with self.assertRaises(subprocess.CalledProcessError):
                    m.activate(None)
                self.assertEqual(marker.read_text().strip(), 'a' * 40)
                (home / 'fail-apply').unlink()
                m.activate(None)
                self.assertEqual((live / 'bin/version').read_text(), 'b' * 40)
                # Restore image A and roll back against the same persistent home.
                shutil.copytree(root / ('b' * 40), root / ('a' * 40))
                (root / ('a' * 40) / 'bin/version').write_text('a' * 40)
                cur.unlink()
                cur.symlink_to('a' * 40)
                m.activate(None)
                self.assertEqual((live / 'bin/version').read_text(), 'a' * 40)
                self.assertEqual((live / 'logs/kept').read_text(), 'history')
                self.assertEqual((home / 'project').read_text(), 'worktree')
                self.assertEqual(len((home / 'applies').read_text().splitlines()), 3)

    def test_restart_with_ui_fail_only_is_applied(self):
        """BREAK-IT linux-restart-ui-crashloop (#3421): a container restart keeps
        /tmp, so a login's tmux fleet server is still there and install-apply's UI
        refresh FAILs on it — `apply: PARTIAL`, activate raised, the container
        exited, CrashLoop. A PARTIAL whose only FAIL is `ui` stamps the marker;
        any other FAIL still stops the start."""
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            home, root = Path(d, 'home'), Path(d, 'runtime')
            home.mkdir()
            b = root / ('a' * 40) / 'bin'
            b.mkdir(parents=True)
            (b / 'fleet-install-apply.sh').write_text(
                '#!/bin/bash\necho "ui: FAIL fleet-ui-refresh.sh: [fleet] conf: FAILED — x"\n'
                '[ ! -f "$HOME/fail-hooks" ] || echo "hooks: FAIL merge"\n'
                'echo "apply: PARTIAL — 1 step(s) failed"\nexit 1\n')
            (root / 'current').symlink_to('a' * 40)
            marker = home / '.config/claude-fleet/global/linux-image-applied'
            with patch.dict(os.environ, {'HOME': str(home), 'FLEET_NODE_ROOT': str(root),
                                         'FLEET_INSTALL_PLATFORM': 'none'}):
                (home / 'fail-hooks').touch()
                with self.assertRaises(subprocess.CalledProcessError):
                    m.activate(None)
                self.assertFalse(marker.exists())
                (home / 'fail-hooks').unlink()
                m.activate(None)
                self.assertEqual(marker.read_text().strip(), 'a' * 40)
        # install-apply names the server and tmux's words, not the summary line
        ia = (BIN / 'fleet-install-apply.sh').read_text()
        self.assertIn("grep -m1 ': FAILED'", ia)

    def test_no_primary_login_never_grows_back(self):
        """BREAK-IT linux-no-primary-regrows (#3526): FLEET_NODE_LOGIN=fleet made the
        container open its own `fleet` login at every start — ~54 idle processes and
        a warm pool nobody used. With `none` (the image's and the manifest's) a
        recreated pod passes no --login to the install, bootstraps only the logins
        linux-tenants/ declares, and opens nothing; one person's failed bootstrap
        never stops the machine."""
        m = module('fleet-node-linux')
        for word in ('none', '', ' none '):
            self.assertEqual(m.primary_login(Mock(login=word)), '')
        self.assertEqual(m.primary_login(Mock(login='fleet')), 'fleet')
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop('FLEET_NODE_LOGIN', None)
            with patch.object(sys, 'argv', ['x', 'ready']), patch.object(m.os, 'geteuid', return_value=0), \
                    patch.object(m.sys, 'platform', 'linux'), patch.object(m, 'probe', return_value=0) as pr:
                m.main()
            self.assertEqual(m.primary_login(pr.call_args.args[0]), '')
        with self.assertRaises(m.Refuse):
            m.bootstrap(Mock(login='none'))
        with tempfile.TemporaryDirectory() as d:
            state, run = Path(d, 'state'), Path(d, 'run')
            run.mkdir()
            real = m.Path

            def path(*parts):
                p = real(*parts)
                return run / p.name if str(p).startswith('/run/') or str(p).startswith('/etc/ssh') else p

            loop = Mock()
            loop.bin.return_value = Path(d)
            loop.tend.return_value = 0
            booted, installs = [], []

            def boot(ns):
                booted.append(ns.login)
                if ns.login == 'drill2':
                    raise RuntimeError('broken home')

            def run_cmd(cmd, **kw):
                installs.append(cmd)
                return Mock(returncode=0)

            with patch.dict(os.environ, {'FLEET_NODE_STATE': str(state)}), \
                    patch.object(m, 'Path', side_effect=path), patch.object(m, 'boot'), \
                    patch.object(m, 'lib_owner_heal'), patch.object(m, 'route_heal'), patch.object(m, 'devnet'), \
                    patch.object(m, 'Loop', return_value=loop), patch.object(m, 'load'), \
                    patch.object(m, 'tenants', return_value={'24acme': {}, 'drill2': {}}), \
                    patch.object(m, 'bootstrap', side_effect=boot), patch.object(m, 'as_tenant'), \
                    patch.object(m, 'login_open') as opened, patch.object(m, 'ensure_login') as ensured, \
                    patch.object(m.subprocess, 'run', side_effect=run_cmd), patch.object(m.signal, 'signal'):
                (state / 'ssh').mkdir(parents=True)
                (state / 'ssh/ssh_host_ed25519_key').write_text('k')
                m.foreground(Mock(login='none', hub='h', join_file='/run/fleet-join/login', machine_join_file=''))
            self.assertEqual(booted, ['24acme', 'drill2'])
            install = [c for c in installs if any(str(x).endswith('fleet-node-install.sh') for x in c)]
            self.assertEqual(len(install), 1)
            self.assertNotIn('--login', install[0])
            self.assertNotIn('--login-join-file', install[0])
            opened.assert_not_called()
            ensured.assert_not_called()
            self.assertTrue(loop.tend.called)  # ready was reached, the loop ran
        # the image and the manifest both say none
        docker = (BIN.parent / 'extras/managed-node/Dockerfile').read_text()
        self.assertIn('FLEET_NODE_LOGIN=none', docker)
        self.assertNotIn('FLEET_NODE_LOGIN=fleet', docker)
        raw = subprocess.check_output([sys.executable, str(BIN.parent / 'extras/managed-node/render.py'),
                                       '--image', 'example/image@sha256:' + 'a' * 64,
                                       '--hub', 'https://hub.example', '--storage-class', 'essd'])
        env = {e['name']: e.get('value') for e in
               json.loads(raw)['items'][-1]['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(env.get('FLEET_NODE_LOGIN'), 'none')
        self.assertNotIn('FLEET_LOGIN_JOIN_FILE', env)

    def test_recreate_rewrites_every_logins_route(self):
        """BREAK-IT linux-recreate-route-lost (#3421): credsep's root settings
        (<LIB>/<login>.conf, the image layer) were written for a `login open`
        login only at its create; after a pod recreate it had FLEET_HUB_URL alone
        — `route: direct`, unsupported_region from the CN egress. Every enrolled
        login's relay route is written again at each start, other lines kept; a
        login never enrolled is left to its open; a second start writes nothing.
        foreground runs it (and the LIB owner heal) before the install."""
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            state, cred, lib = d / 'state', d / 'cred', d / 'lib'
            (state / 'linux-tenants').mkdir(parents=True)
            (state / 'machine.env').write_text('CCQUOTA_HUB_URL=https://hub.example/\n')
            for i, login in enumerate(('fleet', '24acme', 'fresh')):
                (state / 'linux-tenants' / (login + '.json')).write_text(json.dumps(
                    {'login': login, 'uid': 10002 + i, 'gid': 10002 + i}))
            for login in ('fleet', '24acme'):
                (cred / login).mkdir(parents=True)
                (cred / login / 'node.env').write_text(
                    'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=t-%s\n' % login)
            lib.mkdir()
            (lib / '24acme.conf').write_text('FLEET_HUB_URL=https://hub.example\nFLEET_CRED_CENTRAL_URL=https://c.example\n')
            s = Mock()
            s.Paths.return_value = Mock(state=str(state))
            c = Mock(ROOT_BASE=str(cred), LIB=str(lib))
            c.proxy_mod.return_value.loopback_ok.return_value = True

            def write(path, data, uid=0, gid=0):
                Path(path).write_text(data)

            args = Mock(hub='', relay='https://relay.example')
            with patch.object(m, 'load', side_effect=lambda n: {'fleet-node-supervisor': s, 'fleet-credsep': c}[n]), \
                    patch.object(m, 'private_write', side_effect=write):
                m.route_heal(args)
                conf = m.env_read(lib / '24acme.conf')
                self.assertEqual(conf['FLEET_CRED_RELAY_URL'], 'https://relay.example')
                self.assertEqual(conf['FLEET_CRED_ALLOW_HOSTS'], 'hub.example relay.example')
                self.assertEqual(conf['FLEET_HUB_URL'], 'https://hub.example')
                self.assertEqual(conf['FLEET_CRED_CENTRAL_URL'], 'https://c.example')
                self.assertEqual(m.env_read(lib / 'fleet.conf')['FLEET_CRED_RELAY_URL'], 'https://relay.example')
                self.assertFalse((lib / 'fresh.conf').exists())
                before = (lib / '24acme.conf').stat().st_mtime_ns
                with patch.object(m, 'private_write') as pw:
                    m.route_heal(args)
                    pw.assert_not_called()
                self.assertEqual((lib / '24acme.conf').stat().st_mtime_ns, before)
        src = (BIN / 'fleet-node-linux.py').read_text()
        fg = src[src.index('def foreground('):src.index('class Loop(')]
        self.assertLess(fg.index('boot()'), fg.index('lib_owner_heal()'))
        self.assertLess(fg.index('route_heal(a)'), fg.index('fleet-node-install.sh'))

    def test_relay_handed_down_by_the_hub(self):
        """BREAK-IT linux-relay-not-handed (#4010): the hub's relay, in
        expected.json (`fleet node install` from /v1/node/desired), is every
        opened login's FLEET_CRED_RELAY_URL with no hand edit; one given wins; a
        hub with none writes none; a pod routing central takes none; the lib dir
        is 0755 under umask 077."""
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            c = Mock(LIB=str(d / 'usr' / 'claude-fleet' / 'credsep'))
            c.proxy_mod.return_value = module('fleet-cred-proxy')
            (d / 'db').mkdir()

            def write(path, data, uid=0, gid=0):
                Path(path).write_text(data)
            old = os.umask(0o077)
            try:
                with patch.dict(os.environ, {'FLEET_NODE_STATE': str(d / 'db')}), \
                        patch.object(m, 'private_write', side_effect=write), \
                        patch.object(m, 'compat_default', return_value=''), \
                        patch.object(m, 'central_url', return_value='') as cu:
                    m.route_settings(c, 'alice', 'https://hub.example.org', '')
                    self.assertNotIn('FLEET_CRED_RELAY_URL', m.env_read(Path(c.LIB) / 'alice.conf'))
                    (d / 'db' / 'expected.json').write_text(json.dumps({'version': 1, 'cred_relay_url': 'https://relay.example.net/'}))
                    m.route_settings(c, 'bob', 'https://hub.example.org', '')
                    conf = m.env_read(Path(c.LIB) / 'bob.conf')
                    self.assertEqual(conf['FLEET_CRED_RELAY_URL'], 'https://relay.example.net')
                    self.assertIn('relay.example.net', conf['FLEET_CRED_ALLOW_HOSTS'].split())
                    m.route_settings(c, 'carol', 'https://hub.example.org', 'https://relay.example.com')
                    self.assertEqual(m.env_read(Path(c.LIB) / 'carol.conf')['FLEET_CRED_RELAY_URL'], 'https://relay.example.com')
                    cu.return_value = 'http://fleet-credproxy.fleet-workers.svc.cluster.local'
                    m.route_settings(c, 'dave', 'https://hub.example.org', '')
                    self.assertNotIn('FLEET_CRED_RELAY_URL', m.env_read(Path(c.LIB) / 'dave.conf'))
                    (d / 'db' / 'expected.json').write_text(json.dumps({'cred_relay_url': 'http://relay.example.net'}))
                    self.assertEqual(m.hub_relay(), '', 'never a plain-http relay')
            finally:
                os.umask(old)
            for p in (d / 'usr', d / 'usr' / 'claude-fleet', Path(c.LIB)):
                self.assertEqual(p.stat().st_mode & 0o777, 0o755, p)

    def test_relay_is_configured_never_built_in(self):
        """issue #3577: the code names no relay of its own. No --relay /
        FLEET_CRED_RELAY_URL ⇒ no relay route; conf/compat-ours.conf's old value
        (compat-1v) only for a hub that file names — never for anyone else's."""
        m = module('fleet-node-linux')
        compat = module('fleet_compat')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            cf = d / 'compat.conf'
            cf.write_text('# x\nFLEET_COMPAT_HUB_HOSTS=hub.example.com other.example.com\n'
                          'FLEET_CRED_RELAY_URL=https://relay.example.com\n')
            self.assertEqual(compat.default('FLEET_CRED_RELAY_URL', 'https://HUB.example.com/', cf),
                             'https://relay.example.com')
            self.assertEqual(compat.default('FLEET_CRED_RELAY_URL', 'https://hub.example.org', cf), '')
            self.assertEqual(compat.default('FLEET_CRED_RELAY_URL', '', cf), '')
            self.assertEqual(compat.default('FLEET_CRED_RELAY_URL', 'https://hub.example.com', d / 'none'), '')
            c = Mock(LIB=str(d / 'lib'))
            c.proxy_mod.return_value = module('fleet-cred-proxy')

            def write(path, data, uid=0, gid=0):
                Path(path).write_text(data)

            fake = Mock(default=lambda k, hub: compat.default(k, hub, cf))
            with patch.object(m, 'load', side_effect=lambda n: {'fleet_compat': fake}[n]), \
                    patch.object(m, 'private_write', side_effect=write), patch.object(m, 'central_url', return_value=''):
                m.route_settings(c, 'alice', 'https://hub.example.org', '')
                conf = m.env_read(d / 'lib' / 'alice.conf')
                self.assertNotIn('FLEET_CRED_RELAY_URL', conf)             # another hub: no relay at all
                self.assertEqual(conf['FLEET_CRED_ALLOW_HOSTS'], 'hub.example.org')
                m.route_settings(c, 'bob', 'https://hub.example.com', '')
                conf = m.env_read(d / 'lib' / 'bob.conf')
                self.assertEqual(conf['FLEET_CRED_RELAY_URL'], 'https://relay.example.com')  # compat-1v
                m.route_settings(c, 'carol', 'https://hub.example.com', 'https://relay.example.net')
                self.assertEqual(m.env_read(d / 'lib' / 'carol.conf')['FLEET_CRED_RELAY_URL'],
                                 'https://relay.example.net')                 # given wins
        # the separated proxy's allow-list: the public upstreams + the hosts root's
        # config names — no hub or relay of ours written in the code
        px = module('fleet-cred-proxy')
        self.assertEqual(px.allowed_hosts(''), set(px.UPSTREAM_HOSTS))
        self.assertIn('relay.example.com', px.allowed_hosts('', ['https://relay.example.com/x', '']))
        self.assertFalse(any('example' in h for h in px.UPSTREAM_HOSTS))

    def test_image_usr_local_is_roots(self):
        """BREAK-IT linux-image-local-owner (#3421): tar as root keeps the
        archive's owner — node's uid 1001 on /usr/local/lib made the shared
        proxy's launcher `untrusted`, the pod never Ready. Every tar in the image
        runs --no-same-owner, the build asserts /usr/local is root's, and the
        start puts credsep LIB's ancestors back to root (go-w) on an older image."""
        df = (BIN.parent / 'extras/managed-node/Dockerfile').read_text()
        tars = [l for l in df.splitlines() if re.search(r'\btar -?[a-zA-Z-]*x', l) or 'tar --' in l]
        self.assertGreaterEqual(len(tars), 3)
        for l in tars:
            self.assertIn('--no-same-owner', l)
        self.assertIn('! -user root -o ! -group root', df)
        self.assertIn('/usr/local/lib; do', df)
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            lib = Path(d, 'usr/local/lib/claude-fleet/credsep')
            (lib.parent).mkdir(parents=True)  # LIB itself not made yet: skipped
            os.chmod(Path(d, 'usr/local'), 0o775)
            mine = {str(p) for p in [lib.parent] + list(lib.parent.parents) if os.lstat(p).st_uid != 0}
            # never touch the real ancestors (/tmp is 1777 on Linux): record only
            with patch.object(m.os, 'lchown') as lc, patch.object(m.os, 'chmod') as cm:
                fixed = m.lib_owner_heal(lib)
            self.assertEqual({c.args[0].__fspath__() for c in lc.call_args_list}, mine)
            self.assertTrue(all(c.args[1:] == (0, 0) for c in lc.call_args_list))
            modes = {str(c.args[0]): c.args[1] for c in cm.call_args_list}
            self.assertEqual(modes[str(Path(d, 'usr/local'))], 0o755)
            self.assertTrue(all(v & 0o022 == 0 for v in modes.values()))
            self.assertIn(str(Path(d, 'usr/local')), fixed)
            self.assertNotIn(str(lib), fixed)

    def test_every_login_leases_its_credentials(self):
        """issue #3211: the node program leases a login's pool / own accounts (and
        writes accounts/hub:<label>) only when its env says CCQUOTA_FLEET_CREDS=1 —
        a fresh login gets it, an older store gains it with its token untouched."""
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'state').mkdir()
            (d / 'state/machine.env').write_text('fixture')
            code = d / 'join'
            code.write_text('fj_' + 'a' * 26)
            written = {}
            s = Mock()
            s.Paths.return_value = Mock(state=str(d / 'state'))
            s.account_adopt.return_value = 0
            s.write_login_env.side_effect = lambda _p, login, kv: written.__setitem__(login, dict(kv))
            c = Mock(ROOT_BASE=str(d / 'cred'), LIB=str(d / 'lib'), SHARED_RUN=str(d / 'run/.shared'), ROLE='fleetcred')
            c.proxy_mod.return_value.loopback_ok.return_value = True

            def hub(_hub, path, token=None, body=None):
                return {'/v1/node/join': {'token': 'tenant-tok'},
                        '/v1/node/relay-credential': {'token': 'frl1.x'}}.get(path, {})

            def write(path, data, uid=0, gid=0):
                Path(path).parent.mkdir(parents=True, exist_ok=True)
                Path(path).write_text(data)

            me = Mock(pw_uid=os.getuid(), pw_gid=os.getgid(), pw_dir=str(d / 'home'))
            args = Mock(login='fleet', uid=10001, hub='https://hub.example', join_file=str(code),
                        relay='https://relay.example')
            with patch.object(m, 'load', side_effect=lambda n: {'fleet-node-supervisor': s, 'fleet-credsep': c}[n]), \
                    patch.object(m, 'ensure_login', return_value=me), patch.object(m, 'as_tenant'), \
                    patch.object(m, 'request', side_effect=hub), patch.object(m, 'private_write', side_effect=write), \
                    patch.object(m.pwd, 'getpwnam', return_value=me), patch.object(m.os, 'chown'):
                m.prepare(args)
                store = d / 'cred/fleet/node.env'
                self.assertIn('CCQUOTA_FLEET_CREDS=1', store.read_text().splitlines())
                self.assertEqual(written['fleet'].get('CCQUOTA_FLEET_CREDS'), '1')
                self.assertTrue(written['fleet'].get('CCQUOTA_FLEET_CRED_STORE', '').endswith('ctl.sock'))
                # The live PVC's store, written before #3211: the restart adds the flag
                # and keeps the token and every other line byte for byte.
                store.write_text('CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=tenant-tok\n'
                                 'CCQUOTA_FLEET=1\nCCQUOTA_FLEET_COMPUTE_FORCE=1\n')
                written.clear()
                m.prepare(args)
                self.assertEqual(store.read_text(), 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=tenant-tok\n'
                                 'CCQUOTA_FLEET=1\nCCQUOTA_FLEET_COMPUTE_FORCE=1\nCCQUOTA_FLEET_CREDS=1\n')
                self.assertEqual(written['fleet'].get('CCQUOTA_FLEET_CREDS'), '1')
                self.assertEqual(written['fleet'].get('CCQUOTA_FLEET_COMPUTE_FORCE'), '1')
                # A second restart writes nothing new.
                before = store.stat().st_mtime_ns
                m.prepare(args)
                self.assertEqual(store.stat().st_mtime_ns, before)

    def test_relay_refused_while_account_creating_keeps_login(self):
        """#3213: the hub's create op opens a login whose account is still
        `creating`, so /v1/node/relay-credential answers 403 no_principal — the
        open goes on (adopted, no relay.token, the proxy mints it later); any
        other failure still stops it."""
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'state').mkdir()
            (d / 'state/machine.env').write_text('fixture')
            code = d / 'join'
            code.write_text('fj_' + 'a' * 26)
            s = Mock()
            s.Paths.return_value = Mock(state=str(d / 'state'))
            s.account_adopt.return_value = 0
            c = Mock(ROOT_BASE=str(d / 'cred'), LIB=str(d / 'lib'), SHARED_RUN=str(d / 'run/.shared'), ROLE='fleetcred')
            c.proxy_mod.return_value.loopback_ok.return_value = True
            relay_code = [403]

            def hub(_hub, path, token=None, body=None):
                if path == '/v1/node/relay-credential':
                    raise m.HubHTTPError(path, relay_code[0])
                return {'/v1/node/join': {'token': 'tenant-tok'}}.get(path, {})

            def write(path, data, uid=0, gid=0):
                Path(path).parent.mkdir(parents=True, exist_ok=True)
                Path(path).write_text(data)

            me = Mock(pw_uid=os.getuid(), pw_gid=os.getgid(), pw_dir=str(d / 'home'))
            args = Mock(login='dana2', uid=10003, hub='https://hub.example', join_file=str(code),
                        relay='https://relay.example')
            with patch.object(m, 'load', side_effect=lambda n: {'fleet-node-supervisor': s, 'fleet-credsep': c}[n]), \
                    patch.object(m, 'ensure_login', return_value=me), patch.object(m, 'as_tenant'), \
                    patch.object(m, 'request', side_effect=hub), patch.object(m, 'private_write', side_effect=write), \
                    patch.object(m.pwd, 'getpwnam', return_value=me), patch.object(m.os, 'chown'):
                m.prepare(args)
                s.account_adopt.assert_called_once()
                self.assertFalse((d / 'cred/dana2/cred-proxy/relay.token').exists())
                relay_code[0] = 500
                with self.assertRaises(m.HubHTTPError):
                    m.prepare(args)

    def test_privileged_linux_groups_refused_without_sudo_binary(self):
        s = module('fleet-node-supervisor')
        with patch.object(s, 'MAC', False), patch.object(s.os, 'geteuid', return_value=0), \
                patch.object(s.subprocess, 'check_output', return_value='fleet docker'), \
                patch.object(s.subprocess, 'run', side_effect=FileNotFoundError), \
                patch.object(s, '_sudoers_files', return_value=[]), \
                patch.dict(os.environ, {'FLEET_NODE_TEST': '0'}):
            why, full = s.tenant_privileges('fleet')
            self.assertTrue(full)
            self.assertIn('docker 组', why)

    def test_shared_proxy_owned_before_first_supervisor_tick(self):
        c = module('fleet-credsep')
        with tempfile.TemporaryDirectory() as d, patch.object(c, 'MAC', False), \
                patch.object(c.os, 'geteuid', return_value=0), \
                patch.object(c, 'NODE_STATE', d), patch.object(c, 'SHARED_PATH', d + '/absent.service'), \
                patch.dict(os.environ, {'FLEET_NODE_SERVICE': 'foreground'}):
            Path(d, 'machine.env').write_text('fixture')
            self.assertTrue(c.shared_supervised())
            Path(d, 'absent.service').write_text('already owned by systemd')
            self.assertFalse(c.shared_supervised())

    def test_manifest_requires_digest_and_keeps_pvc(self):
        render = BIN.parent / 'extras/managed-node/render.py'
        r = subprocess.run([sys.executable, str(render), '--image', 'example/image:latest',
                            '--hub', 'https://hub.example', '--storage-class', 'essd'], capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        raw = subprocess.check_output([sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                                       '--hub', 'https://hub.example', '--storage-class', 'essd'])
        items = json.loads(raw)['items']
        st = items[-1]['spec']
        self.assertEqual(st['replicas'], 1)
        self.assertEqual(st['persistentVolumeClaimRetentionPolicy'], {'whenDeleted': 'Retain', 'whenScaled': 'Retain'})
        pod = st['template']['spec']
        self.assertFalse(pod['automountServiceAccountToken'])
        self.assertNotIn('hostPID', pod)
        self.assertNotIn('hostNetwork', pod)
        self.assertFalse(pod['containers'][0]['securityContext']['allowPrivilegeEscalation'])
        self.assertEqual(st['volumeClaimTemplates'][0]['spec']['accessModes'], ['ReadWriteOncePod'])
        self.assertEqual(pod['imagePullSecrets'], [{'name': 'acr-pull'}])

    def test_user_pod_template(self):
        """#3550 (EPIC #3500 C5): one person's pod — a Deployment (one replica,
        Recreate, its stable u-<nonce> hostname), a ClusterIP Service on 22 and a
        ReadWriteOncePod home disk; no Kubernetes token, no entry port, no
        fleet/principal (written once ready). Moving the ceiling changes that
        Deployment alone; a ceiling under the idle request refuses."""
        render = BIN.parent / 'extras/managed-node/render.py'
        base = [sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                '--hub', 'https://hub.example', '--storage-class', 'essd', '--user-pod', 'u-drill1',
                '--login', 'fleetu7', '--uid', '10002', '--cred-central', 'http://fleet-credproxy.fleet-workers.svc.cluster.local']
        items = json.loads(subprocess.check_output(base))['items']
        self.assertEqual([i['kind'] for i in items], ['PersistentVolumeClaim', 'Service', 'Deployment'])
        pvc, svc, dep = items
        self.assertEqual({i['metadata']['name'] for i in items}, {'u-drill1'})
        for i in items:
            self.assertEqual(i['metadata']['labels']['fleet/role'], 'user')
        self.assertNotIn('fleet/principal', json.dumps(items))
        self.assertEqual(pvc['spec']['accessModes'], ['ReadWriteOncePod'])
        self.assertEqual(pvc['spec']['resources']['requests']['storage'], '50Gi')
        self.assertEqual(svc['spec']['type'], 'ClusterIP')
        # 22 on the Service, sshd's 2222 in the pod (no NET_BIND_SERVICE, #3757)
        self.assertEqual([(x['port'], x['targetPort']) for x in svc['spec']['ports']], [(22, 'ssh')])
        self.assertEqual(svc['spec']['selector'], {'fleet/pod': 'u-drill1'})
        self.assertEqual(dep['spec']['replicas'], 1)
        self.assertEqual(dep['spec']['strategy'], {'type': 'Recreate'})
        pod = dep['spec']['template']['spec']
        self.assertEqual(pod['hostname'], 'u-drill1')
        self.assertFalse(pod['automountServiceAccountToken'])
        # its own account, no token (#3558): no Kubernetes credential in a person's pod
        self.assertEqual(pod['serviceAccountName'], 'fleet-user')
        self.assertEqual(pod['volumes'][0], {'name': 'data', 'persistentVolumeClaim': {'claimName': 'u-drill1'}})
        c, sshd = pod['containers']
        self.assertEqual((c['name'], sshd['name']), ('fleet', 'sshd'))
        env = {e['name']: e['value'] for e in c['env']}
        self.assertEqual((env['FLEET_NODE_PROFILE'], env['FLEET_USER_POD'], env['FLEET_ENTRY']),
                         ('user-pod', '1', '0'))
        self.assertEqual(env['FLEET_NODE_LOGIN'], 'none')
        self.assertEqual((env['FLEET_POD_LOGIN'], env['FLEET_POD_UID'], env['FLEET_NODE_UPDATE_OWNER']),
                         ('fleetu7', '10002', 'image'))
        self.assertEqual(c['resources'], {'requests': {'cpu': '250m', 'memory': '1536Mi'},
                                          'limits': {'cpu': '2', 'memory': '6Gi'}})
        # #3757: the node is the login — non-root, nothing added; root is sshd's alone
        sc = c['securityContext']
        self.assertEqual((sc['runAsUser'], sc['runAsGroup'], sc['runAsNonRoot']), (10002, 10002, True))
        self.assertEqual(sc['capabilities'], {'drop': ['ALL']})
        self.assertNotIn('ports', c)
        self.assertEqual(sshd['securityContext']['capabilities']['add'],
                         ['CHOWN', 'SETUID', 'SETGID', 'SYS_CHROOT', 'KILL', 'AUDIT_WRITE'])
        self.assertEqual([x['containerPort'] for x in sshd['ports']], [2222])
        self.assertEqual(pod['securityContext']['fsGroup'], 10002)
        self.assertNotIn('shareProcessNamespace', pod)
        self.assertEqual([i['name'] for i in pod['initContainers']], ['egress-guard', 'pod-etc'])
        etc = pod['initContainers'][1]
        self.assertEqual((etc['securityContext']['runAsUser'], etc['securityContext']['runAsNonRoot']), (65534, True))
        # passwd / group read-only in both containers: nobody in the pod writes them
        for cc in (c, sshd):
            m = {x['mountPath']: x for x in cc['volumeMounts']}
            self.assertEqual((m['/etc/passwd']['subPath'], m['/etc/passwd']['readOnly']), ('passwd', True))
            self.assertTrue(m['/etc/group']['readOnly'])
        # the sshd's key dir, read-only in the fleet container: its host.pub rides the
        # heartbeat for a relayed login (claude-fleet#4149); the private half stays root's
        fm = {x['mountPath']: x for x in c['volumeMounts']}
        self.assertEqual((fm['/run/sshd-key']['name'], fm['/run/sshd-key']['readOnly']), ('sshd-key', True))
        self.assertIn('chmod 711 /run/sshd-key\n', sshd['command'][2])
        # no login, a reserved one, root's number, no central route: not rendered
        for bad in (base[:base.index('--login')] + base[base.index('--uid') + 2:],
                    [x if x != 'fleetu7' else 'root' for x in base], [x if x != '10002' else '0' for x in base],
                    base[:-2]):
            self.assertNotEqual(subprocess.run(bad, capture_output=True).returncode, 0, bad)
        # the person's ceiling: the same text as the hub's fleet.user_pod_limits.<principal>
        moved = json.loads(subprocess.check_output(base + ['--limits', 'cpu=4,memory=8Gi']))['items']
        self.assertEqual(moved[:2], items[:2])
        self.assertEqual(moved[2]['spec']['template']['spec']['containers'][0]['resources']['limits'],
                         {'cpu': '4', 'memory': '8Gi'})
        patch_ = json.loads(subprocess.check_output([sys.executable, str(render), '--limits-patch',
                                                     '--limits', 'cpu=4,memory=8Gi']))
        self.assertEqual(patch_['spec']['template']['spec']['containers'],
                         [{'name': 'fleet', 'resources': moved[2]['spec']['template']['spec']['containers'][0]['resources']}])
        for bad in (['--limits', 'memory=1Gi'], ['--limits', 'cpu=100m'], ['--limits', 'gpu=1']):
            self.assertNotEqual(subprocess.run(base + bad, capture_output=True).returncode, 0, bad)
        bad_name = [x if x != 'u-drill1' else 'alice' for x in base]
        self.assertNotEqual(subprocess.run(bad_name, capture_output=True).returncode, 0)
        # the shared node renders as before
        node = json.loads(subprocess.check_output(base[:base.index('--user-pod')]))['items']
        self.assertEqual(node[-1]['kind'], 'StatefulSet')
        self.assertIn('User pods', (BIN.parent / 'docs/dev/MANAGED-LINUX.md').read_text())

    def test_user_pod_table_has_no_machine_loops(self):
        """#3550: a user pod runs no machine-level loop (they are the cluster's
        one copy); its own children stay. Off = the table as before."""
        s = module('fleet-node-supervisor')
        with patch.object(s, 'MAC', False), patch.dict(os.environ, {'FLEET_NODE_UPDATE_OWNER': 'hub'}):
            before = s.default_table(s.Paths())
            with patch.dict(os.environ, {'FLEET_NODE_PROFILE': 'user-pod'}):
                pod = s.default_table(s.Paths())
                self.assertEqual(s.node_environment().get('FLEET_NODE_PROFILE'), 'user-pod')
        self.assertEqual([t['name'] for t in pod['tasks']], ['update'])
        self.assertEqual(pod['children'], before['children'])
        self.assertIn('diskguard', [t['name'] for t in before['tasks']])

    def test_pod_runs_as_its_login(self):
        """#3757 (EPIC #3500 C16): a person's pod is its one login. pod-etc writes
        the image's passwd / group plus that login, and refuses a name or number
        the image has (root's above all); the daemon's table there is the node
        program alone (no task, no shared proxy, no sshd); `login open` opens only
        that login — any other name is 3 with nothing written — and remove is
        refused; only that uid may run the program. Off = as before."""
        lin = module('fleet-node-linux')
        s = module('fleet-node-supervisor')
        pod = {'FLEET_NODE_PROFILE': 'user-pod', 'FLEET_POD_LOGIN': 'fleetu7', 'FLEET_POD_UID': '10002'}
        with tempfile.TemporaryDirectory() as d:
            base, out = Path(d, 'base'), Path(d, 'out')
            base.mkdir()
            (base / 'passwd').write_text('root:x:0:0:root:/root:/bin/bash\nsshd:x:100:65534::/run/sshd:/usr/sbin/nologin\n')
            (base / 'group').write_text('root:x:0:\n')
            env = dict(pod, FLEET_GITHUB_PROXY='http://relay:3128')
            with patch.dict(os.environ, env):
                self.assertEqual(lin.pod_etc(_ns(base=str(base), out=str(out))), 0)
            self.assertEqual(Path(out, 'passwd').read_text().splitlines()[-1],
                             'fleetu7:*:10002:10002::/home/fleetu7:/bin/zsh')
            self.assertEqual(Path(out, 'group').read_text().splitlines()[-1], 'fleetu7:x:10002:')
            self.assertIn('FLEET_GITHUB_PROXY=http://relay:3128', Path(out, 'fleet-devnet.env').read_text())
            sshd = Path(out, 'sshd_config').read_text()
            for want in ('Port 2222', 'UsePAM no', 'PermitRootLogin no', 'AllowUsers fleetu7',
                         'HostKey /run/sshd-key/host', 'AuthorizedKeysFile none',
                         'SetEnv FLEET_USER_POD=1',
                         'ForceCommand /bin/bash /var/db/fleet-node/runtime/current/bin/fleet-entry.sh'):
                self.assertIn(want + '\n', sshd)
            self.assertNotIn('Include', sshd)
            # one rule on every address (claude-fleet#4193): the person's keys + the door's
            # through a command that never fails, the hub's user CA — no Match block
            self.assertIn('AuthorizedKeysCommand /bin/sh -c "/bin/cat /run/fleet-door/door.pub '
                          '/var/db/fleet-node/ssh/authorized_keys 2>/dev/null; exit 0"\n', sshd)
            self.assertIn('TrustedUserCAKeys /var/db/fleet-node/ssh/fleet_user_ca.pub\nPermitUserRC', sshd)
            self.assertNotIn('Match', sshd)
            for login, uid in (('root', '10002'), ('sshd', '10002'), ('fleetu7', '0'), ('fleetu7', '100'),
                               ('fleetu7', '65534'), ('Fleet', '10002')):
                with patch.dict(os.environ, dict(pod, FLEET_POD_LOGIN=login, FLEET_POD_UID=uid)):
                    with self.assertRaises(lin.Refuse, msg=(login, uid)):
                        lin.pod_etc(_ns(base=str(base), out=os.path.join(d, 'bad')))
            (base / 'passwd').write_text('root:x:0:0:root:/root:/bin/bash\nold:x:10002:10002::/:/bin/sh\n')
            with patch.dict(os.environ, pod), self.assertRaises(lin.Refuse):
                lin.pod_etc(_ns(base=str(base), out=os.path.join(d, 'bad')))
            self.assertFalse(os.path.exists(os.path.join(d, 'bad')))
        # the daemon as the login: the node program alone
        with patch.object(s, 'MAC', False), patch.dict(os.environ, dict(pod, FLEET_NODE_UPDATE_OWNER='image')):
            t = s.default_table(s.Paths())
            self.assertEqual(([c['name'] for c in t['children']], t['tasks']), (['node-agent'], []))
            # …up with no login yet: the hub's create comes down its own link (#3554)
            self.assertEqual(t['children'][0]['requires'], [str(Path(s.Paths().state, 'machine.env'))])
            self.assertEqual(s.node_environment().get('FLEET_POD_LOGIN'), 'fleetu7')
        with patch.object(s, 'MAC', False), patch.dict(os.environ, {'FLEET_NODE_PROFILE': 'user-pod'}):
            os.environ.pop('FLEET_POD_LOGIN', None)
            agent = [c for c in s.default_table(s.Paths())['children'] if c['name'] == 'node-agent'][0]
            # a shared node waits for a login unless it opens its own (#4010)
            self.assertTrue(any(isinstance(r, dict) and r['any'][0].endswith('*.env')
                                and r['any'][1]['is'] == 'FLEET_NODE_ACCOUNT_OPS=1' for r in agent['requires']))
        with patch.object(s, 'MAC', False), patch.dict(os.environ, {'FLEET_NODE_PROFILE': 'user-pod',
                                                                    'FLEET_POD_LOGIN': ''}):
            self.assertFalse(s.pod_own())
        # login open: only the pod's login; remove: never
        with patch.dict(os.environ, pod):
            self.assertTrue(lin.pod_own())
            with patch.object(lin, 'load', side_effect=AssertionError('nothing may be loaded or written')):
                with self.assertRaises(lin.Refuse) as e:
                    lin.login_open(_ns(name='drill2', full_name='', join_file='', hub='', relay='', start=False))
                self.assertEqual(e.exception.rc, 3)
            with self.assertRaises(lin.Refuse):
                lin.login_remove(_ns(name='fleetu7', home='keep'))
            with patch.object(lin.sys, 'platform', 'linux'), patch.object(lin.os, 'geteuid', return_value=0):
                self.assertFalse(lin.own_seat())          # root is not the pod's login
            with patch.object(lin.sys, 'platform', 'linux'), patch.object(lin.os, 'geteuid', return_value=10002):
                self.assertTrue(lin.own_seat())
        with patch.dict(os.environ, {'FLEET_NODE_PROFILE': 'user-pod', 'FLEET_POD_LOGIN': ''}):
            self.assertFalse(lin.pod_own())
            with patch.object(lin.sys, 'platform', 'linux'), patch.object(lin.os, 'geteuid', return_value=0):
                self.assertTrue(lin.own_seat())           # a shared node: root, as before

    def test_pod_login_reissued(self):
        """#4301: the hub asks a person's pod for its one login again (the
        endpoint retired — an expired drill, an `accounts forget`). The disk
        still declares it under the old op: the create claims it — the new op
        written, home and data kept, the retired token dropped for the new join
        code — never 「already exists」 rc 3, which left the pod failed."""
        lin = module('fleet-node-linux')
        uid = os.geteuid()
        with tempfile.TemporaryDirectory() as d:
            d = os.path.realpath(d)  # private_write walks with O_NOFOLLOW (macOS /var)
            state, users = Path(d, 'state'), Path(d, 'home')
            state.mkdir()
            (state / 'machine.env').write_text('CCQUOTA_HUB_URL=https://hub.example.com\n')
            home = users / 'drillcn'
            (home / '.config/claude-fleet').mkdir(parents=True)
            (home / 'keep.txt').write_text('data\n')
            os.chmod(home, 0o700)
            (home / '.config/claude-fleet/node.env').write_text(
                'CCQUOTA_HUB_URL=https://hub.example.com\nCCQUOTA_TOKEN=old-retired\n')
            tdir = state / 'linux-tenants'
            tdir.mkdir(mode=0o700)
            (tdir / 'drillcn.json').write_text(json.dumps(
                {'login': 'drillcn', 'uid': uid, 'gid': uid, 'home': str(home), 'op': 'aaaa', 'since': 1}))
            sup = Mock()
            sup.Paths.return_value = _ns(state=str(state), users=str(users))
            sup.account_adopt.return_value = 0
            seen = []

            def hub(_h, path, token=None, body=None):
                seen.append((path, token, (body or {}).get('code')))
                return {'token': 'new-tok'}
            pw = _ns(pw_dir=str(home))
            jf = Path(d, 'join')
            jf.write_text('fj_' + 'a' * 26 + '\n')
            env = {'FLEET_NODE_PROFILE': 'user-pod', 'FLEET_POD_LOGIN': 'drillcn', 'FLEET_LOGIN_OP_ID': 'bbbb'}
            with patch.dict(os.environ, env), patch.object(lin, 'load', return_value=sup), \
                    patch.object(lin, 'pod_self', return_value=('drillcn', uid, pw)), \
                    patch.object(lin, 'central_url', return_value='http://central'), \
                    patch.object(lin, 'hub_internal_url', return_value=''), \
                    patch.object(lin, 'pod_privileges', return_value=[]), \
                    patch.object(lin, 'machine_hub', return_value='https://hub.example.com'), \
                    patch.object(lin, 'as_tenant'), patch.object(lin, 'request', side_effect=hub), \
                    patch.object(lin, 'check_home', return_value=True), \
                    redirect_stderr(io.StringIO()), patch('sys.stdout', new=io.StringIO()):
                self.assertEqual(lin.pod_login_open(_ns(name='drillcn', full_name='', join_file=str(jf),
                                                        hub='', start=False)), 0)
            self.assertEqual(json.loads((tdir / 'drillcn.json').read_text())['op'], 'bbbb')
            self.assertEqual(seen, [('/v1/node/join', None, 'fj_' + 'a' * 26)])
            self.assertIn('CCQUOTA_TOKEN=new-tok', (home / '.config/claude-fleet/node.env').read_text())
            self.assertEqual((home / 'keep.txt').read_text(), 'data\n')
            sup.account_adopt.assert_called_once()

    def test_ops_template(self):
        """#3734 (EPIC #3500 C1's cloud half): the cluster's ONE fleet-ops — one
        replica, Recreate, its hostname the cluster's name, the read-only
        fleet-ops account (the one pod here that mounts a token), fleet/role
        control (the provisioner's only caller); the image's own ccquota as a
        plain agent, not root, read-only root, the token down a pipe from its
        Secret — never the environment."""
        render = BIN.parent / 'extras/managed-node/render.py'
        img = 'example/image@sha256:' + 'a' * 64
        items = json.loads(subprocess.check_output([sys.executable, str(render), '--ops', 'ack-sz', '--image', img,
                                                    '--hub', 'https://hub.example']))['items']
        self.assertEqual([(i['kind'], i['metadata']['name']) for i in items], [('Deployment', 'fleet-ops')])
        dep = items[0]
        self.assertEqual((dep['spec']['replicas'], dep['spec']['strategy']['type']), (1, 'Recreate'))
        self.assertEqual(dep['metadata']['labels']['fleet/role'], 'control')
        pod = dep['spec']['template']['spec']
        self.assertEqual(dep['spec']['template']['metadata']['labels']['fleet/role'], 'control')
        self.assertEqual((pod['hostname'], pod['serviceAccountName'], pod['automountServiceAccountToken']),
                         ('ack-sz', 'fleet-ops', True))
        c = pod['containers'][0]
        sec = c['securityContext']
        self.assertTrue(sec['runAsNonRoot'] and sec['readOnlyRootFilesystem'] and sec['runAsUser'] != 0)
        self.assertEqual(sec['capabilities'], {'drop': ['ALL']})
        env = {e['name']: e.get('value') for e in c['env']}
        self.assertEqual((env['CCQUOTA_FLEET'], env['CCQUOTA_FLEET_COMPUTE'], env['CCQUOTA_FLEET_PROVISIONER']),
                         ('1', '0', 'http://fleet-provisioner.fleet-workers.svc.cluster.local:8790'))
        self.assertNotIn('CCQUOTA_TOKEN', env)
        self.assertIn('CCQUOTA_TOKEN_FD=3', c['command'][-1])
        self.assertIn('/run/fleet-ops/token', c['command'][-1])
        self.assertNotIn('persistentVolumeClaim', json.dumps(pod))
        for bad in (['ack-sz', '--image', 'example/image:latest', '--hub', 'https://hub.example'],
                    ['ack-sz', '--image', img, '--hub', 'http://hub.example'],
                    ['Not_A_Name', '--image', img, '--hub', 'https://hub.example'],
                    ['ack-sz', '--image', img, '--hub', 'https://hub.example', '--provisioner', 'file:///x']):
            self.assertNotEqual(subprocess.run([sys.executable, str(render), '--ops'] + bad, capture_output=True).returncode, 0, bad)

    def test_door_template(self):
        """#3549 (EPIC #3500 C4): the cluster's one door — ONE LoadBalancer
        (22022 alone, externalTrafficPolicy Local) in front of a 2-replica
        Deployment in door mode, its Secret shared (host key, key to the pods,
        token); no disk, no Kubernetes token. A user pod mounts the key's public
        half and its sshd takes it alone; pod 22 is open to the door only."""
        render = BIN.parent / 'extras/managed-node/render.py'
        img = 'example/image@sha256:' + 'a' * 64
        items = json.loads(subprocess.check_output([sys.executable, str(render), '--door', '--image', img,
                                                    '--hub', 'https://hub.example']))['items']
        self.assertEqual([(i['kind'], i['metadata']['name']) for i in items],
                         [('Service', 'fleet-door'), ('Deployment', 'fleet-door')])
        svc, dep = items
        self.assertEqual((svc['spec']['type'], svc['spec']['externalTrafficPolicy']), ('LoadBalancer', 'Local'))
        self.assertEqual([(x['port'], x['targetPort']) for x in svc['spec']['ports']], [(22022, 22022)])
        self.assertEqual(svc['spec']['selector'], {'fleet/role': 'door'})
        self.assertEqual(dep['spec']['replicas'], 2)
        pod = dep['spec']['template']['spec']
        self.assertFalse(pod['automountServiceAccountToken'])
        self.assertNotIn('persistentVolumeClaim', json.dumps(pod))
        env = {e['name']: e['value'] for e in pod['containers'][0]['env']}
        self.assertEqual((env['FLEET_NODE_PROFILE'], env['FLEET_DOOR'], env['FLEET_ENTRY'], env['FLEET_ENTRY_PORT']),
                         ('door', '1', '1', '22022'))
        self.assertIn({'name': 'secret', 'secret': {'secretName': 'fleet-door', 'defaultMode': 0o400}}, pod['volumes'])
        self.assertNotIn('CCQUOTA_FLEET_NODE_ROUTES', env)
        # the load balancer's address, once it has one: the door's reach knocks
        # there, not on the NAT (#4112)
        lb = json.loads(subprocess.check_output([sys.executable, str(render), '--door', '--image', img,
                                                 '--hub', 'https://hub.example', '--entry-host', '203.0.113.7']))['items'][1]
        lbenv = {e['name']: e['value'] for e in lb['spec']['template']['spec']['containers'][0]['env']}
        self.assertEqual(lbenv['CCQUOTA_FLEET_NODE_ROUTES'], 'entry=203.0.113.7:22022')
        for bad in (['--image', 'example/image:latest', '--hub', 'https://hub.example'],
                    ['--image', img, '--hub', 'http://hub.example'], ['--image', img, '--hub', 'https://h', '--door-replicas', '9']):
            self.assertNotEqual(subprocess.run([sys.executable, str(render), '--door'] + bad, capture_output=True).returncode, 0, bad)
        # a user pod: the door's public key mounted, read at each login
        upod = json.loads(subprocess.check_output([sys.executable, str(render), '--image', img, '--hub', 'https://hub.example',
                                                   '--storage-class', 'essd', '--user-pod', 'u-drill1',
                                                   '--login', 'drill1', '--uid', '10002', '--cred-central', 'http://fleet-credproxy.fleet-workers.svc.cluster.local']))['items'][-1]
        spec = upod['spec']['template']['spec']
        self.assertIn({'name': 'door', 'secret': {'secretName': 'fleet-door-pub', 'optional': True, 'defaultMode': 0o444}},
                      spec['volumes'])
        # the door's key is sshd's (#3757: its own container), never the login's
        self.assertIn({'name': 'door', 'mountPath': '/run/fleet-door', 'readOnly': True},
                      spec['containers'][1]['volumeMounts'])
        self.assertNotIn('/run/fleet-door', json.dumps(spec['containers'][0]['volumeMounts']))
        lin = module('fleet-node-linux')
        text = lin.user_pod_sshd_text('/rt')
        for want in ('AuthorizedKeysFile none', 'AuthorizedKeysCommand /bin/cat /run/fleet-door/door.pub',
                     'AuthorizedKeysCommandUser nobody', 'TrustedUserCAKeys none', 'DisableForwarding yes',
                     'ForceCommand /bin/bash /rt/current/bin/fleet-entry.sh',
                     'AcceptEnv LANG LC_* FLEET_DOOR_FP FLEET_DOOR_SRC FLEET_DOOR_NAME'):
            self.assertIn(want + '\n', text)
        # 05- sorts before every other drop-in (the CA's is 100-): sshd keeps the first value
        self.assertLess(Path(lin.DOOR_SSHD_CONF).name, '100-fleet-user-ca.conf')
        with tempfile.TemporaryDirectory() as d:
            conf = os.path.join(d, '05-fleet-door.conf')
            with patch.dict(os.environ, {'FLEET_NODE_PROFILE': 'user-pod', 'FLEET_NODE_RUNTIME': '/rt'}):
                lin.user_pod_sshd(conf)
            self.assertEqual(Path(conf).read_text(), text)
            with patch.dict(os.environ, {'FLEET_NODE_PROFILE': ''}):
                lin.user_pod_sshd(conf)
            self.assertFalse(os.path.exists(conf))
            # the door's machine.env: the token from the Secret, never anywhere else
            Path(d, 'token').write_text('tok_' + 'x' * 30 + '\n')
            me = lin.door_env('https://hub.example/', d)
            self.assertIn('CCQUOTA_HUB_URL=https://hub.example\n', me)
            self.assertIn('CCQUOTA_TOKEN=tok_' + 'x' * 30 + '\n', me)
            self.assertIn('FLEET_DOOR=1\n', me)
            Path(d, 'token').write_text('bad token\n')
            self.assertRaises(ValueError, lin.door_env, 'https://hub.example', d)
        # the door runs its own `entry reach` (#4112): none at the start, the
        # first a minute on, one at a time, then every FLEET_ENTRY_REACH_EVERY
        t = [1000.0]

        class FakeLoop(object):
            def bin(self):
                return Path('/rt/current/bin')
        runs = []

        class Proc(object):
            def __init__(self, argv, **_kw):
                runs.append(argv)
                self.done = False

            def poll(self):
                return 0 if self.done else None
        with patch.object(lin.subprocess, 'Popen', Proc), patch.dict(os.environ, {'FLEET_ENTRY_REACH_EVERY': '300'}):
            r = lin.DoorReach(FakeLoop(), clock=lambda: t[0])
            r.tick()
            self.assertEqual(runs, [])
            t[0] += 60
            r.tick()
            self.assertEqual(len(runs), 1)
            self.assertEqual(runs[0][-3:], [str(Path('/rt/current/bin/fleet-node-supervisor.py').resolve()), 'entry', 'reach'])
            t[0] += 400
            r.tick()
            self.assertEqual(len(runs), 1)          # the last one still running
            r.proc.done = True
            r.tick()
            self.assertEqual(len(runs), 2)
            r.proc.done = True
            t[0] += 100
            r.tick()
            self.assertEqual(len(runs), 2)          # not due yet
        with patch.object(lin.subprocess, 'Popen', Proc), patch.dict(os.environ, {'FLEET_ENTRY_REACH_EVERY': '0'}):
            r = lin.DoorReach(FakeLoop(), clock=lambda: t[0])
            t[0] += 10000
            r.tick()
            self.assertEqual(len(runs), 2)          # 0 = off
        pol = (BIN.parent / 'deploy/k8s/fleet-workers/networkpolicy.yaml').read_text()
        for name in ('door-in', 'door-out'):
            self.assertIn('  name: %s\n' % name, pol)
        user_in = pol.split('  name: user-in\n')[1].split('\n---')[0]
        self.assertIn('fleet/role: door', user_in)

    def test_door_table_and_routes(self):
        """#3549: the door runs its entry sshd alone; its table gives each login
        ONE pod — a login two rows name, or a Service that is not a pod, none."""
        s = module('fleet-node-supervisor')
        with patch.object(s, 'MAC', False), patch.dict(os.environ, {'FLEET_NODE_PROFILE': 'door'}):
            t = s.default_table(s.Paths())
        self.assertEqual((t['children'], t['tasks'], t['account']), ([], [], []))
        routes = s.door_routes({'routes': [
            {'login': 'dana', 'service': 'u-k3x9q2'},
            {'login': 'bob', 'service': 'u-aaaa1'}, {'login': 'bob', 'service': 'u-bbbb2'},
            {'login': 'carol', 'service': 'fleet-linux'}, {'login': 'root;x', 'service': 'u-cccc3'}]})
        self.assertEqual(routes, {'dana': 'u-k3x9q2'})
        with tempfile.TemporaryDirectory() as d:
            pw = os.path.join(d, 'passwd')
            Path(pw).write_text(json.dumps({'other': {'uid': 1001, 'gid': 20, 'home': '/home/other'}}))
            with patch.dict(os.environ, {'FLEET_NODE_TEST': '1', 'FLEET_NODE_PASSWD': pw}):
                v = s.door_eligible(['dana', 'other', 'root', 'dave'], {'dana': 'u-k3x9q2', 'other': 'u-oooo1'})
            self.assertIsNone(v['dana'])
            self.assertIn('not a door account', v['other'])
            self.assertTrue(v['root'] and v['dave'])
            self.assertEqual(json.loads(Path(pw).read_text())['dana']['gecos'], 'fleet-door')

    def test_door_second_pod_route(self):
        """#3562: a person's second pod is <login>.<repo> on the door, logged in
        there as <login> (pod_login); a bad pod_login routes nothing."""
        s = module('fleet-node-supervisor')
        lst = {'routes': [
            {'login': 'dana', 'service': 'u-k3x9q2'},
            {'login': 'dana.web', 'service': 'u-w2e9q1', 'pod_login': 'dana'},
            {'login': 'eve.api', 'service': 'u-eeee1', 'pod_login': 'eve;rm'}]}
        self.assertEqual(s.door_route_rows(lst), {'dana': ('u-k3x9q2', 'dana'), 'dana.web': ('u-w2e9q1', 'dana')})
        self.assertEqual(s.door_routes(lst), {'dana': 'u-k3x9q2', 'dana.web': 'u-w2e9q1'})

    def test_pull_secret_is_a_flag(self):
        """#3290: ACK's password-free ACR plugin names its Secret acr-credential-<hash>;
        --pull-secret (repeatable) replaces the acr-pull default, a bad name refuses."""
        render = BIN.parent / 'extras/managed-node/render.py'
        base = [sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                '--hub', 'https://hub.example', '--storage-class', 'essd']
        pod = lambda extra: json.loads(subprocess.check_output(base + extra))['items'][-1]['spec']['template']['spec']
        self.assertEqual(pod(['--pull-secret', 'x'])['imagePullSecrets'], [{'name': 'x'}])
        self.assertEqual(pod(['--pull-secret', 'acr-credential-560b', '--pull-secret', 'y'])['imagePullSecrets'],
                         [{'name': 'acr-credential-560b'}, {'name': 'y'}])
        r = subprocess.run(base + ['--pull-secret', 'Bad Name'], capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        doc = (BIN.parent / 'docs/dev/MANAGED-LINUX.md').read_text()
        self.assertIn('--pull-secret', doc)

    def test_egress_guard_cuts_metadata_and_cluster(self):
        """BREAK-IT linux-egress-metadata (#3281): flannel enforces no NetworkPolicy,
        so an init container holding NET_ADMIN (+NET_RAW) writes OUTPUT rules into
        the pod's own netns — loopback, replies, DNS to kube-dns, then REJECT the
        cloud metadata address, the pod and service ranges and every private range;
        the fleet container never holds NET_ADMIN / NET_RAW, so root there cannot
        undo them. The ranges are flags, and a bad one refuses to render."""
        render = BIN.parent / 'extras/managed-node/render.py'
        base = [sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                '--hub', 'https://hub.example', '--storage-class', 'essd']
        pod = json.loads(subprocess.check_output(base))['items'][-1]['spec']['template']['spec']
        self.assertEqual([c['name'] for c in pod['initContainers']], ['egress-guard'])
        g = pod['initContainers'][0]
        self.assertEqual(g['image'], 'example/image@sha256:' + 'a' * 64)
        sc = g['securityContext']
        self.assertEqual(sc['capabilities'], {'drop': ['ALL'], 'add': ['NET_ADMIN', 'NET_RAW']})
        self.assertFalse(sc['allowPrivilegeEscalation'])
        self.assertTrue(sc['readOnlyRootFilesystem'])
        for c in pod['containers']:
            caps = c['securityContext']['capabilities']
            self.assertEqual(caps['drop'], ['ALL'], c['name'])
            self.assertFalse({'NET_ADMIN', 'NET_RAW', 'SYS_ADMIN'} & set(caps.get('add', [])), c['name'])
            self.assertNotIn('privileged', c['securityContext'])
        self.assertIn('egress-run', [v['name'] for v in pod['volumes']])
        script = g['command'][-1]
        v4 = [l for l in script.split("V4='", 1)[1].split('COMMIT', 1)[0].splitlines() if l.startswith('-A OUTPUT')]
        self.assertEqual(v4[:4], ['-A OUTPUT -o lo -j ACCEPT',
                                  '-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT',
                                  '-A OUTPUT -d 172.21.0.10/32 -p udp -m udp --dport 53 -j ACCEPT',
                                  '-A OUTPUT -d 172.21.0.10/32 -p tcp -m tcp --dport 53 -j ACCEPT'])
        cut = [l.split()[3] for l in v4[4:]]
        self.assertTrue(all(l.endswith(' -j REJECT') for l in v4[4:]), v4)
        for want in ('100.100.100.200/32', '172.20.0.0/16', '172.21.0.0/20', '10.0.0.0/8', '192.168.0.0/16'):
            self.assertIn(want, cut)
        self.assertEqual(cut[0], '100.100.100.200/32')
        self.assertIn('exit 1', script)  # no backend took the rules: the pod never starts
        # the ranges are flags
        pod = json.loads(subprocess.check_output(base + [
            '--egress-dns', '10.96.0.10', '--egress-pod-cidr', '10.244.0.0/16', '--egress-service-cidr',
            '10.96.0.0/12', '--egress-private', '10.0.0.0/8']))['items'][-1]['spec']['template']['spec']
        script = pod['initContainers'][0]['command'][-1]
        self.assertIn('-A OUTPUT -d 10.96.0.10/32 -p udp -m udp --dport 53 -j ACCEPT', script)
        self.assertIn('-A OUTPUT -d 10.244.0.0/16 -j REJECT', script)
        self.assertNotIn('192.168.0.0/16', script)
        for bad in (['--egress-pod-cidr', '172.20.0.1/16'], ['--egress-private', "10.0.0.0/8'; iptables -F #"],
                    ['--egress-dns', 'kube-dns']):
            r = subprocess.run(base + bad, capture_output=True)
            self.assertNotEqual(r.returncode, 0, bad)
        df = (BIN.parent / 'extras/managed-node/Dockerfile').read_text()
        self.assertRegex(df, r'\biptables\b')

    def test_dev_network_github_relay_mirror_and_toolchain(self):
        """BREAK-IT linux-github-unreachable (#3348): the CN egress cannot reach
        github.com's git transport, so the pod names the Singapore relay
        (extras/gh-relay, CONNECT to GitHub hosts :443 from the cluster egress
        only) and the in-cluster mirror; the node writes /etc/gitconfig (git's
        github.com traffic through the relay, a mirrored repo fetched from the
        mirror, pushes still to GitHub) and /etc/fleet-devnet.env (CN mirrors,
        the relay for the gh wrapper) for every login at each start. The guard
        lets exactly the named in-cluster destination through; the image carries
        the toolchain."""
        render = BIN.parent / 'extras/managed-node/render.py'
        mirror = ('git://git-mirror.arc-runners.svc.cluster.local/mono.git='
                  'https://github.com/Org/mono.git')
        base = [sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                '--hub', 'https://hub.example', '--storage-class', 'essd']
        plain = json.loads(subprocess.check_output(base))['items'][-1]['spec']['template']['spec']
        self.assertFalse([e for e in plain['containers'][0]['env'] if e['name'].startswith(('FLEET_GIT', 'FLEET_CN'))])
        pod = json.loads(subprocess.check_output(base + [
            '--github-proxy', 'http://203.0.113.211:3128', '--git-mirror', mirror, '--cn-mirrors',
            '--egress-allow', '172.21.5.6:9418']))['items'][-1]['spec']['template']['spec']
        env = {e['name']: e['value'] for e in pod['containers'][0]['env']}
        self.assertEqual(env['FLEET_GITHUB_PROXY'], 'http://203.0.113.211:3128')
        self.assertEqual(env['FLEET_GIT_MIRRORS'], mirror)
        self.assertEqual(env['FLEET_CN_MIRRORS'], '1')
        v4 = [l for l in pod['initContainers'][0]['command'][-1].splitlines() if l.startswith('-A OUTPUT')]
        allow = v4.index('-A OUTPUT -d 172.21.5.6/32 -p tcp -m tcp --dport 9418 -j ACCEPT')
        self.assertLess(allow, v4.index('-A OUTPUT -d 172.21.0.0/20 -j REJECT'))  # before the cut
        for bad in (['--egress-allow', '172.21.5.6'], ['--egress-allow', "172.21.5.6:9418'; iptables -F #"],
                    ['--github-proxy', 'socks5://x:1'], ['--github-proxy', 'http://x:1 -c core.sshCommand=sh'],
                    ['--git-mirror', 'git://m/x.git=https://example.com/a/b.git'],
                    ['--git-mirror', 'git://m/x.git=https://github.com/a/b']):
            r = subprocess.run(base + bad, capture_output=True)
            self.assertNotEqual(r.returncode, 0, bad)

        n = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            gc, ef = os.path.join(d, 'gitconfig'), os.path.join(d, 'devnet.env')
            n.devnet(env, gc, ef)
            git = {'GIT_CONFIG_SYSTEM': gc, 'GIT_CONFIG_GLOBAL': os.devnull, 'HOME': d,
                   'PATH': os.environ.get('PATH', '')}

            def cfg(*args):
                return subprocess.check_output(['git'] + list(args), env=git, cwd=d, text=True).strip()
            self.assertEqual(cfg('config', '--system', 'http.https://github.com/.proxy'), 'http://203.0.113.211:3128')
            subprocess.check_call(['git', 'init', '-q', 'r'], env=git, cwd=d)
            d2 = os.path.join(d, 'r')
            subprocess.check_call(['git', 'remote', 'add', 'origin', 'https://github.com/Org/mono.git'], env=git, cwd=d2)
            subprocess.check_call(['git', 'remote', 'add', 'other', 'https://github.com/Org/other.git'], env=git, cwd=d2)
            get = lambda *a: subprocess.check_output(['git', 'remote', 'get-url'] + list(a), env=git, cwd=d2, text=True).strip()
            self.assertEqual(get('origin'), 'git://git-mirror.arc-runners.svc.cluster.local/mono.git')
            self.assertEqual(get('--push', 'origin'), 'https://github.com/Org/mono.git')
            self.assertEqual(get('other'), 'https://github.com/Org/other.git')
            shell = Path(ef).read_text()
            for line in ('FLEET_GITHUB_PROXY=http://203.0.113.211:3128', 'npm_config_registry=https://registry.npmmirror.com',
                         'GOPROXY=https://goproxy.cn,direct', 'FNM_NODE_DIST_MIRROR=https://npmmirror.com/mirrors/node'):
                self.assertIn(line + '\n', shell)
            # what every shell sees, and a login's own value still wins
            prof = (BIN.parent / 'extras/managed-node/devnet/profile.sh').read_text().replace('/etc/fleet-devnet.env', ef)
            pf = os.path.join(d, 'profile.sh')
            Path(pf).write_text(prof)
            out = subprocess.check_output(['sh', '-c', '. "$1"; echo "$GOPROXY|$npm_config_registry"', 'sh', pf],
                                          env={'PATH': os.environ.get('PATH', ''), 'npm_config_registry': 'mine'}, text=True)
            self.assertEqual(out.strip(), 'https://goproxy.cn,direct|mine')
            # nothing set: the node's files go, a hand-made one stays
            n.devnet({}, gc, ef)
            self.assertFalse(os.path.exists(gc) or os.path.exists(ef))
            Path(gc).write_text('[user]\n\tname = hand\n')
            n.devnet({}, gc, ef)
            self.assertTrue(os.path.exists(gc))
            with self.assertRaises(ValueError):
                n.devnet_settings({'FLEET_GIT_MIRRORS': 'git://m/x.git=https://github.com/a/b'})
        # the relay refuses everything but GitHub :443 from the cluster egress
        r = subprocess.run([sys.executable, '-I', str(BIN.parent / 'extras/gh-relay/gh-relay.py'), '--selftest'],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        df = (BIN.parent / 'extras/managed-node/Dockerfile').read_text()
        for tool in ('NODE_SHA256', 'GO_SHA256', 'KUBECTL_SHA256', 'FNM_SHA256', 'ALIYUN_SHA256', 'corepack enable',
                     'sha256sum -c', '/usr/local/bin/gh', 'fleet-devnet.sh'):
            self.assertIn(tool, df)
        self.assertIn('devnet', (BIN.parent / 'extras/managed-node/prepare-image.sh').read_text())

    def test_cluster_caches(self):
        """#3548 (EPIC #3500 C3): in the cluster layout every login installs npm /
        pip / Go packages from the namespace's read-through caches
        (deploy/k8s/caches: fleet-npm:4873, fleet-pypi:3141, fleet-goproxy:3000)
        instead of the CN mirrors, Go falling through to goproxy.cn; the image
        carries the default MCP servers so a session starts them from disk."""
        render = BIN.parent / 'extras/managed-node/render.py'
        base = [sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                '--hub', 'https://hub.example', '--storage-class', 'essd']
        pod = json.loads(subprocess.check_output(base + ['--cluster-caches']))['items'][-1]['spec']['template']['spec']
        env = {e['name']: e['value'] for e in pod['containers'][0]['env']}
        self.assertEqual(env['FLEET_CLUSTER_CACHES'], 'fleet-workers')
        self.assertNotIn('FLEET_CN_MIRRORS', env)
        for bad in (['--cluster-caches', '--cn-mirrors'], ['--cluster-caches', '--namespace', 'Bad_NS']):
            r = subprocess.run(base + bad, capture_output=True)
            self.assertNotEqual(r.returncode, 0, bad)

        n = module('fleet-node-linux')
        _, shell = n.devnet_settings({'FLEET_CLUSTER_CACHES': 'fleet-workers', 'FLEET_CN_MIRRORS': '1'})
        npm = 'http://fleet-npm.fleet-workers.svc.cluster.local:4873'
        pypi = 'http://fleet-pypi.fleet-workers.svc.cluster.local:3141/root/pypi/+simple/'
        goproxy = 'http://fleet-goproxy.fleet-workers.svc.cluster.local:3000|https://goproxy.cn|direct'
        for line in ('npm_config_registry=' + npm, 'COREPACK_NPM_REGISTRY=' + npm, 'PIP_INDEX_URL=' + pypi,
                     'PIP_TRUSTED_HOST=fleet-pypi.fleet-workers.svc.cluster.local', 'UV_DEFAULT_INDEX=' + pypi,
                     'GOPROXY=' + goproxy, 'FNM_NODE_DIST_MIRROR=https://npmmirror.com/mirrors/node'):
            self.assertIn(line + '\n', shell)
        self.assertNotIn('registry.npmmirror.com', shell)  # the caches win over the CN mirrors
        with self.assertRaises(ValueError):
            n.devnet_settings({'FLEET_CLUSTER_CACHES': 'x;rm -rf /'})
        # every shell exports the `|` list whole
        with tempfile.TemporaryDirectory() as d:
            ef = os.path.join(d, 'devnet.env')
            n.devnet({'FLEET_CLUSTER_CACHES': 'fleet-workers'}, os.path.join(d, 'gitconfig'), ef)
            prof = (BIN.parent / 'extras/managed-node/devnet/profile.sh').read_text().replace('/etc/fleet-devnet.env', ef)
            pf = os.path.join(d, 'profile.sh')
            Path(pf).write_text(prof)
            out = subprocess.check_output(['sh', '-c', '. "$1"; echo "$GOPROXY"', 'sh', pf],
                                          env={'PATH': os.environ.get('PATH', '')}, text=True)
            self.assertEqual(out.strip(), goproxy)
        # the caches: read-only npm, devpi re-pointed at each start, two replicas a disk apiece
        caches = BIN.parent / 'deploy/k8s/caches'
        verdaccio = (caches / 'base/verdaccio.yaml').read_text()
        self.assertEqual(verdaccio.count('    publish: $nobody'), 2)
        self.assertIn('max_users: -1', verdaccio)
        self.assertEqual(subprocess.run(['sh', '-n', str(caches / 'base/devpi-start.sh')]).returncode, 0)
        self.assertIn('devpi index root/pypi "mirror_url=${FLEET_PYPI_UPSTREAM}"',
                      (caches / 'base/devpi-start.sh').read_text())
        pol = (BIN.parent / 'deploy/k8s/fleet-workers/networkpolicy.yaml').read_text()
        for port in ('4873', '3141', '3000', '9418'):
            self.assertIn('port: %s}' % port, pol)
        kubectl = subprocess.run(['sh', '-c', 'command -v kubectl'], capture_output=True, text=True).stdout.strip()
        if kubectl:
            out = subprocess.check_output([kubectl, 'kustomize', str(BIN.parent / 'deploy/k8s/fleet-workers')], text=True)
            docs = [x for x in out.split('\n---\n') if x.strip()]
            for name, port in (('fleet-npm', 4873), ('fleet-pypi', 3141), ('fleet-goproxy', 3000)):
                sts = [x for x in docs if '\nkind: StatefulSet' in '\n' + x and '\n  name: %s\n' % name in x]
                self.assertEqual(len(sts), 1, name)
                for want in ('replicas: 2', 'volumeClaimTemplates:', 'fleet/role: ops',
                             'automountServiceAccountToken: false', 'containerPort: %d' % port):
                    self.assertIn(want, sts[0], (name, want))
                svc = [x for x in docs if '\nkind: Service\n' in '\n' + x and '\n  name: %s\n' % name in x]
                self.assertIn('sessionAffinity: ClientIP', svc[0])
                self.assertTrue([x for x in docs if 'kind: PodDisruptionBudget' in x and '  name: %s\n' % name in x])
        # the default MCP servers ship in the image, pinned; uv by sha256
        df = (BIN.parent / 'extras/managed-node/Dockerfile').read_text()
        for want in ('@upstash/context7-mcp@', '@playwright/mcp@', '@modelcontextprotocol/server-github@',
                     'mcp-server-fetch==', 'UV_SHA256', 'echo "$UV_SHA256  uv.tgz" | sha256sum -c -'):
            self.assertIn(want, df)

    def test_hub_internal_dial(self):
        """#4175: a person's pod (and a service run) asks the hub at its
        in-cluster Service — render.py --hub-internal → FLEET_HUB_INTERNAL_URL —
        instead of the public door the egress does not carry (#4112/#4172: 403).
        FLEET_HUB_URL stays the public identity; only an http(s)
        NAME.NS.svc.cluster.local URL is taken; none named = byte for byte."""
        render = BIN.parent / 'extras/managed-node/render.py'
        internal = 'http://ccquota-hub.new-deploy.svc.cluster.local'
        img = 'example/image@sha256:' + 'a' * 64
        base = [sys.executable, str(render), '--image', img,
                '--hub', 'https://hub.example', '--storage-class', 'essd', '--user-pod', 'u-drill1',
                '--login', 'fleetu7', '--uid', '10002', '--cred-central', 'http://fleet-credproxy.fleet-workers.svc.cluster.local']

        def fleet_env(argv):
            dep = json.loads(subprocess.check_output(argv))['items'][-1]
            return {e['name']: e.get('value', '') for e in dep['spec']['template']['spec']['containers'][0]['env']}
        env = fleet_env(base + ['--hub-internal', internal])
        self.assertEqual(env['FLEET_HUB_INTERNAL_URL'], internal)
        self.assertEqual(env['FLEET_HUB_URL'], 'https://hub.example')   # the identity stays public
        self.assertNotIn('FLEET_HUB_INTERNAL_URL', fleet_env(base))
        for bad in ('http://hub.example', 'https://ccquota-hub.new-deploy.svc.cluster.local',
                    'http://ccquota-hub.svc.cluster.local', 'http://x.y.svc.cluster.local.evil.example',
                    internal + '/v1', 'http://ccquota-hub.new-deploy.svc'):
            r = subprocess.run(base + ['--hub-internal', bad], capture_output=True)
            self.assertNotEqual(r.returncode, 0, bad)
        run = [sys.executable, str(render), '--svc-run', 'R7', '--image', img, '--hub', 'https://hub.example.com',
               '--cred-central', 'http://fleet-credproxy.fleet-workers.svc.cluster.local',
               '--egress-proxy', 'http://fleet-egress-run.fleet-workers.svc.cluster.local:3128',
               '--egress-allow', '198.51.100.40:3128', '--egress-allow', '198.51.100.41:80']

        def svc_hub(argv):
            job = json.loads(subprocess.check_output(argv))['items'][0]
            env = {e['name']: e.get('value', '') for e in job['spec']['template']['spec']['containers'][0]['env']}
            return env['FLEET_SVC_HUB']
        self.assertEqual(svc_hub(run), 'https://hub.example.com')
        self.assertEqual(svc_hub(run + ['--hub-internal', internal + ':80']), internal + ':80')

        # the node program and every login job see it (the supervisor's passthrough)
        self.assertIn('FLEET_HUB_INTERNAL_URL', module('fleet-node-supervisor').NODE_ENV_KEYS)

        # the login's own fleet.conf names it; a pod with none writes no line
        m = module('fleet-node-linux')
        with patch.dict(os.environ, {'FLEET_HUB_INTERNAL_URL': internal + '/'}):
            self.assertEqual(m.hub_internal_url(), internal)
        with patch.dict(os.environ, {'FLEET_HUB_INTERNAL_URL': 'http://hub.example'}):
            self.assertEqual(m.hub_internal_url(), '')
        with tempfile.TemporaryDirectory() as d:
            conf = Path(d) / '.config/claude-fleet/fleet.conf'
            for extra, want in (([internal], 'FLEET_HUB_INTERNAL_URL=' + internal + '\n'), ([''], None), ([], None)):
                subprocess.run([sys.executable, '-c', m.POD_CONF, 'http://c.ns.svc.cluster.local'] + extra,
                               env=dict(os.environ, HOME=d), check=True)
                text = conf.read_text()
                self.assertEqual(text.count('FLEET_HUB_INTERNAL_URL='), 1 if want else 0, text)
                if want:
                    self.assertTrue(text.endswith(want), text)

        # the proxy's calls (broker, budget, renew, trust) dial it; node.env's hub
        # stays the identity checked; anything else = the hub, byte for byte
        px = module('fleet-cred-proxy')
        hub = 'https://hub.example'
        with patch.dict(os.environ, {'FLEET_HUB_INTERNAL_URL': internal}):
            self.assertEqual(px.hub_dial(hub), internal)
            self.assertEqual(px.hub_dial(''), '')
            self.assertIn('ccquota-hub.new-deploy.svc.cluster.local', px.allowed_hosts('', px.configured_urls([])))
            px.ALLOWED = px.allowed_hosts('')
            self.assertEqual(px.hub_dial(hub), hub)                       # separated: an allowed host only
            px.ALLOWED = None
        with patch.dict(os.environ, {'FLEET_HUB_INTERNAL_URL': 'http://evil.example'}):
            self.assertEqual(px.hub_dial(hub), hub)
        with patch.dict(os.environ, {'FLEET_HUB_INTERNAL_URL': ''}):
            self.assertEqual(px.hub_dial(hub), hub)
        src = (BIN / 'fleet-cred-proxy.py').read_text()
        for path in ('/v1/node/usage', '/v1/fleet/session-cred/renew', '/v1/node/self'):
            self.assertIn('hub_dial(hub) + "%s"' % path, src)
        # the session's own pass and its drop read it too (fleet.conf / the environment)
        sc = (BIN / 'fleet-session-cred.sh').read_text()
        self.assertEqual(sc.count('FSC_DIAL="$(hub_internal)"'), 2)
        self.assertEqual(sc.count('hub = dial'), 2)

    def test_central_pod_holds_no_credential(self):
        """BREAK-IT cred-in-user-pod (#3547, EPIC #3500 C2): a user pod in the
        cluster routes every session to the cluster credential proxy
        (fleet-credproxy:80) and fetches the outside through the one egress
        (fleet-egress:3128); no subscription credential is leased into it or
        kept on its volume, and its own guard rejects the public internet."""
        render = BIN.parent / 'extras/managed-node/render.py'
        central = 'http://fleet-credproxy.fleet-workers.svc.cluster.local'
        egress = 'http://fleet-egress.fleet-workers.svc.cluster.local:3128'
        base = [sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                '--hub', 'https://hub.example', '--storage-class', 'essd']
        items = json.loads(subprocess.check_output(base + [
            '--cred-central', central, '--egress-proxy', egress, '--egress-closed',
            '--egress-allow', '172.21.3.4:80', '--egress-allow', '172.21.3.5:3128',
            '--egress-allow', '203.0.113.9:443']))['items']
        sts = items[-1]['spec']
        self.assertEqual(sts['template']['metadata']['labels']['fleet/role'], 'user')
        self.assertNotIn('fleet/role', sts['selector']['matchLabels'])   # a selector never changes
        env = {e['name']: e.get('value', '') for e in sts['template']['spec']['containers'][0]['env']}
        self.assertEqual(env['FLEET_CRED_CENTRAL_URL'], central)
        self.assertEqual(env['FLEET_EGRESS_PROXY'], egress)
        self.assertFalse([k for k in env if re.search(r'TOKEN|SECRET|PASSWORD|CREDENTIAL', k)], env)
        script = sts['template']['spec']['initContainers'][0]['command'][-1]
        v4 = script.split("V4='", 1)[1].split("'", 1)[0].splitlines()
        v6 = script.split("V6='", 1)[1].split("'", 1)[0].splitlines()
        self.assertEqual(v4[-2:], ['-A OUTPUT -j REJECT', 'COMMIT'])      # closed: the last word
        self.assertEqual(v6[-2:], ['-A OUTPUT -j REJECT', 'COMMIT'])
        for want in ('-A OUTPUT -d 172.21.3.4/32 -p tcp -m tcp --dport 80 -j ACCEPT',
                     '-A OUTPUT -d 203.0.113.9/32 -p tcp -m tcp --dport 443 -j ACCEPT'):
            self.assertLess(v4.index(want), v4.index('-A OUTPUT -d 172.21.0.0/20 -j REJECT'))
        # open (no flag): byte for byte as before — no catch-all
        plain = json.loads(subprocess.check_output(base))['items'][-1]['spec']['template']
        self.assertNotIn('-A OUTPUT -j REJECT', plain['spec']['initContainers'][0]['command'][-1])
        self.assertFalse([e for e in plain['spec']['containers'][0]['env']
                          if e['name'] in ('FLEET_CRED_CENTRAL_URL', 'FLEET_EGRESS_PROXY')])
        for bad in (['--egress-closed'], ['--cred-central', 'http://credproxy.example'],
                    ['--cred-central', 'http://x.svc.cluster.local.evil.example'],
                    ['--egress-proxy', 'socks5://x:1'], ['--cred-central', central + '/x y']):
            r = subprocess.run(base + bad, capture_output=True)
            self.assertNotEqual(r.returncode, 0, bad)

        # the local proxy takes plain http to a cluster Service for the central
        # route only — never for the hub, never to another host
        px = module('fleet-cred-proxy')
        self.assertTrue(px.loopback_ok(central, cluster=True))
        self.assertFalse(px.loopback_ok(central))
        self.assertFalse(px.loopback_ok('http://credproxy.example', cluster=True))
        self.assertFalse(px.loopback_ok('http://svc.cluster.local', cluster=True))
        px.ALLOWED = px.allowed_hosts('')
        self.assertFalse(px.loopback_ok(central, cluster=True))           # separated: an allowed host only
        px.ALLOWED = px.allowed_hosts('fleet-credproxy.fleet-workers.svc.cluster.local')
        self.assertTrue(px.loopback_ok(central, cluster=True))
        px.ALLOWED = None

        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            state, cred, lib, logins = d / 'state', d / 'cred', d / 'lib', d / 'logins'
            (state / 'linux-tenants').mkdir(parents=True)
            logins.mkdir()
            (state / 'machine.env').write_text('CCQUOTA_HUB_URL=https://hub.example/\n')
            store = cred / 'dana'
            (state / 'linux-tenants' / 'dana.json').write_text(json.dumps({'login': 'dana', 'uid': 10003, 'gid': 10003}))
            for f, text in (('node.env', 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=node-tok\nCCQUOTA_FLEET_CREDS=1\n'),
                            ('accounts/max1.hub/.credentials.json', '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}'),
                            ('accounts/pooled', 'sk-ant-oat01-y'), ('accounts/max1.conf', 'label=max1\n'),
                            ('codex/team/auth.json', '{"tokens":{}}'), ('cred-proxy/pool.json', '{}'),
                            ('cred-proxy/relay.token', 'frl1.z\n'), ('cred-proxy/hub-passes.json', '{}')):
                (store / f).parent.mkdir(parents=True, exist_ok=True)
                (store / f).write_text(text)
            pool = cred / '.shared/pool/claude/' / ('a' * 32)
            pool.mkdir(parents=True)
            (pool / '.credentials.json').write_text('{"claudeAiOauth":{}}')
            (logins / 'dana.env').write_text('CCQUOTA_TOKEN=node-tok\nCCQUOTA_FLEET_CREDS=1\nFLEET_CONF_DIR=/home/dana/.config/claude-fleet\n')
            lib.mkdir()
            s = Mock()
            s.Paths.return_value = Mock(state=str(state))
            s.login_env_path.side_effect = lambda _p, login: str(logins / (login + '.env'))
            s.write_login_env.side_effect = lambda _p, login, kv: (logins / (login + '.env')).write_text(
                ''.join('%s=%s\n' % (k, kv[k]) for k in sorted(kv)))
            c = Mock(ROOT_BASE=str(cred), LIB=str(lib), SHARED_DIR=str(cred / '.shared'), ROLE='fleetcred')
            c.proxy_mod.return_value = px

            def write(path, data, uid=0, gid=0):
                Path(path).write_text(data)
            me = Mock(pw_uid=os.getuid(), pw_gid=os.getgid())
            with patch.object(m, 'load', side_effect=lambda n: {'fleet-node-supervisor': s, 'fleet-credsep': c}[n]), \
                    patch.object(m, 'private_write', side_effect=write), patch.object(m.pwd, 'getpwnam', return_value=me), \
                    patch.dict(os.environ, {'FLEET_CRED_CENTRAL_URL': central}):
                self.assertEqual(m.creds_flag(), '0')
                m.route_heal(Mock(hub='', relay='https://relay.example'))
                conf = m.env_read(lib / 'dana.conf')
                self.assertEqual(conf['FLEET_CRED_CENTRAL_URL'], central)
                self.assertIn('fleet-credproxy.fleet-workers.svc.cluster.local', conf['FLEET_CRED_ALLOW_HOSTS'].split())
                self.assertEqual(m.env_read(store / 'node.env')['CCQUOTA_FLEET_CREDS'], '0')
                self.assertEqual(m.env_read(store / 'node.env')['CCQUOTA_TOKEN'], 'node-tok')
                self.assertEqual(m.env_read(logins / 'dana.env')['CCQUOTA_FLEET_CREDS'], '0')
                self.assertEqual(m.env_read(logins / 'dana.env')['FLEET_CONF_DIR'], '/home/dana/.config/claude-fleet')
                left = sorted(str(f.relative_to(cred)) for f in cred.rglob('*') if f.is_file())
                self.assertEqual(left, ['dana/accounts/max1.conf', 'dana/cred-proxy/hub-passes.json',
                                        'dana/cred-proxy/relay.token', 'dana/node.env'])
                for f in cred.rglob('*'):
                    if f.is_file():
                        self.assertNotIn('sk-ant-', f.read_text(), f)
                # a second start finds nothing to do
                with patch.object(m, 'private_write') as pw:
                    self.assertFalse(m.central_heal(s, s.Paths(), c, 'dana'))
                    pw.assert_not_called()
                self.assertEqual(m.cred_purge(c, ['dana']), 0)
                # the dev network: the egress is every login's proxy, the cluster direct
                git, shell = m.devnet_settings({'FLEET_EGRESS_PROXY': egress})
                self.assertIn('[http]\n\tproxy = ' + egress, git)
                for line in ('HTTPS_PROXY=' + egress, 'https_proxy=' + egress, 'FLEET_GITHUB_PROXY=' + egress,
                             'NO_PROXY=localhost,127.0.0.1,::1,.svc,.cluster.local'):
                    self.assertIn(line + '\n', shell)
                # the fleet's own hub stays direct: the egress does not name it (issue #4112)
                _, shell = m.devnet_settings({'FLEET_EGRESS_PROXY': egress,
                                              'FLEET_HUB_URL': 'https://hub.example.com',
                                              'FLEET_CRED_CENTRAL_URL': 'https://hub.example.com/'})
                for k in ('NO_PROXY', 'no_proxy'):
                    self.assertIn(k + '=localhost,127.0.0.1,::1,.svc,.cluster.local,hub.example.com\n', shell)
                with self.assertRaises(ValueError):
                    m.devnet_settings({'FLEET_EGRESS_PROXY': 'http://x:1 -c core.sshCommand=sh'})
            # unset: the lease stays on, nothing is purged
            with patch.dict(os.environ, {'FLEET_CRED_CENTRAL_URL': ''}):
                self.assertEqual(m.creds_flag(), '1')
        # the egress itself: a host allow-list, the pod range only, GitHub via its parent
        r = subprocess.run([sys.executable, '-I', str(BIN.parent / 'deploy/k8s/egress/base/fleet-egress.py'),
                            '--selftest'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # the cluster's shared layer renders: one of each, two replicas, a PDB, no
        # public path, no Kubernetes token (kubectl where the runner has it)
        kubectl = subprocess.run(['sh', '-c', 'command -v kubectl'], capture_output=True, text=True).stdout.strip()
        if kubectl:
            out = subprocess.check_output([kubectl, 'kustomize', str(BIN.parent / 'deploy/k8s/fleet-workers')], text=True)
            docs = [x for x in out.split('\n---\n') if x.strip()]
            kinds = [(re.search(r'^kind: (\S+)', x, re.M).group(1), re.search(r'^  name: (\S+)', x, re.M).group(1))
                     for x in docs]
            for want in (('Service', 'fleet-credproxy'), ('Service', 'fleet-egress'), ('Deployment', 'fleet-credproxy'),
                         ('Deployment', 'fleet-egress'), ('PodDisruptionBudget', 'fleet-credproxy'),
                         ('PodDisruptionBudget', 'fleet-egress'), ('NetworkPolicy', 'default-deny')):
                self.assertIn(want, kinds)
            self.assertNotIn('Ingress', [k for k, _ in kinds])
            for x in docs:
                if x.startswith('apiVersion: apps/v1') or '\nkind: Deployment' in x:
                    self.assertIn('replicas: 2', x)
                    if '\n  name: fleet-provisioner\n' in x:
                        # the one writer carries its own account's token, by design (#3558)
                        self.assertIn('serviceAccountName: fleet-provisioner', x)
                        continue
                    self.assertIn('automountServiceAccountToken: false', x)
                    self.assertIn('namespace: fleet-workers', x)
            svc = [x for x in docs if 'kind: Service\n' in x and 'name: fleet-credproxy' in x][0]
            self.assertIn('port: 80', svc)
            self.assertIn('port: 3128', [x for x in docs if 'kind: Service\n' in x and 'name: fleet-egress' in x][0])

    def test_entry_door_is_the_entry_port_only(self):
        """BREAK-IT linux-entry-weak-door (#3213): the public Service carries 22022
        alone (Local), the system sshd's 22 stays on the headless one; the pod turns
        the entry on and names the load balancer as its entry= route, which reaches
        `entry reach` through the supervisor's filtered environment; the door's sshd
        takes keys from root's list only — no password, no root, no ~/.ssh."""
        render = BIN.parent / 'extras/managed-node/render.py'
        base = [sys.executable, str(render), '--image', 'example/image@sha256:' + 'a' * 64,
                '--hub', 'https://hub.example', '--storage-class', 'essd']
        items = json.loads(subprocess.check_output(base + ['--entry-host', '47.1.2.3']))['items']
        svcs = {i['metadata']['name']: i for i in items if i['kind'] == 'Service'}
        door = svcs['fleet-linux-entry']['spec']
        self.assertEqual(door['type'], 'LoadBalancer')
        self.assertEqual(door['externalTrafficPolicy'], 'Local')
        self.assertEqual([(x['port'], x['targetPort'], x['protocol']) for x in door['ports']],
                         [(22022, 22022, 'TCP')])
        ann = svcs['fleet-linux-entry']['metadata']['annotations']
        lb = 'service.beta.kubernetes.io/alibaba-cloud-loadbalancer-'
        self.assertEqual(ann[lb + 'address-type'], 'internet')
        self.assertEqual(ann[lb + 'charge-type'], 'paybytraffic')
        self.assertEqual(ann[lb + 'spec'], 'slb.s1.small')
        inner = svcs['fleet-linux']['spec']
        self.assertEqual(inner['clusterIP'], 'None')
        self.assertNotIn('type', inner)
        for name, svc in svcs.items():
            if svc['spec'].get('type') in ('LoadBalancer', 'NodePort'):
                self.assertNotIn(22, [x['port'] for x in svc['spec']['ports']], name)
        c = items[-1]['spec']['template']['spec']['containers'][0]
        env = dict((e['name'], e['value']) for e in c['env'])
        self.assertEqual(env['FLEET_ENTRY'], '1')
        self.assertEqual(env['FLEET_ENTRY_PORT'], '22022')
        self.assertEqual(env['CCQUOTA_FLEET_NODE_ROUTES'], 'entry=47.1.2.3:22022')
        self.assertIn(22022, [x['containerPort'] for x in c['ports']])
        # before the CLB has an address: the door is rendered, no route is guessed
        items = json.loads(subprocess.check_output(base + ['--entry-lb-spec', 'clcu']))['items']
        c = items[-1]['spec']['template']['spec']['containers'][0]
        self.assertNotIn('CCQUOTA_FLEET_NODE_ROUTES', [e['name'] for e in c['env']])
        ann = [i for i in items if i['metadata']['name'] == 'fleet-linux-entry'][0]['metadata']['annotations']
        self.assertEqual(ann[lb + 'instance-charge-type'], 'PayByCLCU')
        self.assertNotIn(lb + 'spec', ann)
        r = subprocess.run(base + ['--entry-host', 'evil host'], capture_output=True)
        self.assertNotEqual(r.returncode, 0)
        s = module('fleet-node-supervisor')
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {
                'FLEET_ENTRY': '1', 'CCQUOTA_FLEET_NODE_ROUTES': 'entry=47.1.2.3:22022'}):
            self.assertEqual(s.node_environment()['CCQUOTA_FLEET_NODE_ROUTES'], 'entry=47.1.2.3:22022')
            p = s.Paths()
            p.state = d
            self.assertEqual(s.entry_route(p, {}), ('47.1.2.3', 22022))
            cfg = s.entry_config(s.EntryPaths(p), 22022, ['24acme'])
        lines = set(cfg.splitlines())
        for want in ('Port 22022', 'AuthenticationMethods publickey', 'PasswordAuthentication no',
                     'KbdInteractiveAuthentication no', 'PermitRootLogin no', 'AllowUsers 24acme'):
            self.assertIn(want, lines)
        self.assertIn('AuthorizedKeysFile %s/entry/keys/%%u' % d, lines)
        self.assertFalse([l for l in lines if 'authorized_keys' in l and not l.startswith('#')])
        self.assertFalse([l for l in lines if l.startswith('AuthorizedKeysCommand')])

    def test_image_stages_and_verifies_codex_helper(self):
        spec = importlib.util.spec_from_file_location('image_stage', BIN.parent / 'extras/managed-node/image-stage.py')
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        with tempfile.TemporaryDirectory() as d:
            src, dest = Path(d, 'src'), Path(d, 'dest')
            artifacts = src / '.release/artifacts'
            artifacts.mkdir(parents=True)
            names = ('ccquota', 'claude', 'codex', 'tmux', 'codex-code-mode-host')
            manifest = {'sha': 'a' * 40, 'artifacts': []}
            for name in names:
                content = ('fixture ' + name).encode()
                (artifacts / name).write_bytes(content)
                manifest['artifacts'].append({'name': name, 'sha256': hashlib.sha256(content).hexdigest()})
            (src / '.release/manifest.json').write_text(json.dumps(manifest))
            release = {'components': {name: {'artifact': name, 'version': '1'} for name in names[:4]}}
            release['components']['codex']['helpers'] = {'codex-code-mode-host': 'codex-code-mode-host'}
            (src / 'release.json').write_text(json.dumps(release))
            helper = artifacts / 'codex-code-mode-host'
            original = helper.read_bytes()
            helper.write_bytes(b'wrong bytes')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                m.stage(src, dest)
            self.assertFalse(dest.exists())
            helper.write_bytes(original)
            m.stage(src, dest)
            installed = dest / 'current/tools/bin/codex-code-mode-host'
            self.assertEqual(installed.read_bytes(), original)
            self.assertTrue(installed.stat().st_mode & 0o111)

    def test_prepare_image_context_has_every_helper(self):
        """#3554: a ccquota whose --pinned drops helpers (older than #3017) made
        a context without codex-code-mode-host, and `docker build` died in
        stage. prepare-image.sh checks the context against image-stage's own
        `need` list, falls back to the whole release, and keeps only what the
        image takes; it names buildx for the build."""
        here = BIN.parent / 'extras/managed-node'
        with tempfile.TemporaryDirectory() as d:
            fake = Path(d, 'ccquota')
            fake.write_text(r'''#!/bin/bash
[ "$1" = version ] && { echo "ccquota old-1"; exit 0; }
dest=${@: -1}; mkdir -p "$dest/.release/artifacts"
cat > "$dest/release.json" <<'J'
{"components": {"ccquota": {"artifact": "ccquota-{os}-{arch}"},
 "claude": {"version": "2", "artifact": "claude-{version}-{os}-{arch}"},
 "codex": {"version": "9", "artifact": "codex-{version}-{os}-{arch}",
           "helpers": {"codex-code-mode-host": "codex-code-mode-host-{version}-{os}-{arch}"}},
 "tmux": {"version": "3", "artifact": "tmux-{version}-{os}-{arch}"}}}
J
echo "$*" >> "$(dirname "$0")/calls"
for n in ccquota-linux-amd64 claude-2-linux-amd64 codex-9-linux-amd64 tmux-3-linux-amd64; do echo x > "$dest/.release/artifacts/$n"; done
case " $* " in *" --pinned "*) ;; *) for n in codex-code-mode-host-9-linux-amd64 codex-9-darwin-arm64; do echo x > "$dest/.release/artifacts/$n"; done ;; esac
''')
            fake.chmod(0o755)
            key = Path(d, 'release.pub')
            key.write_text('ed25519 AAAA\n')
            ctx = Path(d, 'ctx')
            r = subprocess.run(['bash', str(here / 'prepare-image.sh'), 'https://hub.example', str(key), 'a' * 40,
                                str(ctx)], env=dict(os.environ, CCQUOTA=str(fake)), capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('codex-code-mode-host-9-linux-amd64', r.stderr)
            arts = sorted(p.name for p in (ctx / 'runtime/.release/artifacts').iterdir())
            self.assertEqual(arts, sorted(subprocess.run(
                ['python3', str(here / 'image-stage.py'), 'need', str(ctx / 'runtime'), 'amd64'],
                capture_output=True, text=True, check=True).stdout.split()))
            self.assertNotIn('codex-9-darwin-arm64', arts)
            self.assertEqual(len(Path(d, 'calls').read_text().splitlines()), 2)
            self.assertIn('docker buildx build --platform linux/amd64 --load', r.stdout)

    # ---- #3212: the image only seeds; the disk runtime follows stable
    def stage_mod(self):
        spec = importlib.util.spec_from_file_location('image_stage', BIN.parent / 'extras/managed-node/image-stage.py')
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        return m

    @staticmethod
    def fake_release(root, sha, seq):
        d = Path(root) / sha
        (d / '.release').mkdir(parents=True)
        (d / 'bin').mkdir()
        (d / '.release/staged.json').write_text('{}')
        (d / '.release/manifest.json').write_text(json.dumps({'sha': sha, 'seq': seq}))
        (d / 'bin/fleet-node-linux.py').write_text('# ' + sha)
        return d

    def test_restart_never_goes_back_to_image(self):
        """BREAK-IT linux-image-pins-old: the image is A; the updater moved the
        disk to B; a container restart keeps B. A newer image (C) is seeded once
        the updater is at rest; FLEET_NODE_UPDATE_OWNER=image puts the image's back."""
        m = self.stage_mod()
        A, B, C = 'a' * 40, 'b' * 40, 'c' * 40
        with tempfile.TemporaryDirectory() as d:
            seed, root, state = Path(d, 'seed'), Path(d, 'runtime'), Path(d, 'state')
            state.mkdir()
            self.fake_release(seed, A, 5)
            (seed / 'current').symlink_to(A)
            self.assertEqual(m.seed(seed, root, state), 'seeded')
            self.assertEqual(os.readlink(root / 'current'), A)
            self.assertTrue((root / A / 'bin/fleet-node-linux.py').is_file())
            self.assertEqual(m.seed(seed, root, state), 'kept')
            # the updater switches to B (a later stable, seq 6)
            self.fake_release(root, B, 6)
            m.swap(root / 'current', B)
            for _ in range(2):   # a container restart, twice
                self.assertEqual(m.seed(seed, root, state), 'kept')
                self.assertEqual(os.readlink(root / 'current'), B)
            # a new image C (seq 7) — but the updater is mid-switch: its own to finish
            self.fake_release(seed, C, 7)
            m.swap(seed / 'current', C)
            (state / 'update.json').write_text(json.dumps({'phase': 'switched', 'to': B}))
            self.assertEqual(m.seed(seed, root, state), 'kept')
            (state / 'update.json').write_text(json.dumps({'phase': 'idle'}))
            self.assertEqual(m.seed(seed, root, state), 'newer')
            self.assertEqual((os.readlink(root / 'current'), os.readlink(root / '.prev')), (C, B))
            # the off switch: the image's version, whatever the disk holds
            m.swap(seed / 'current', A)
            self.assertEqual(m.seed(seed, root, state), 'kept')
            m.seed(seed, root, state, force=True)
            self.assertEqual(os.readlink(root / 'current'), A)
            # an image without a staged runtime is refused, the disk untouched
            m.swap(seed / 'current', 'f' * 40)
            with self.assertRaisesRegex(ValueError, 'no staged runtime'):
                m.seed(seed, root, state)
            self.assertEqual(os.readlink(root / 'current'), A)

    def test_image_owned_runtime_never_piles_up(self):
        """BREAK-IT user-pod-runtime-pileup (#4283): a person's pod
        (FLEET_NODE_UPDATE_OWNER=image) seeds each new image's 1.3 GB runtime onto
        its PVC; with no updater to retire them, seven versions filled 9 GB of a
        20 GB disk and the disk guard refused every new session. An image-owned
        boot keeps `current` and `.prev` only; a node-owned one leaves the rest to
        the updater's prune."""
        m = self.stage_mod()
        shas = [c * 40 for c in 'abcde']
        with tempfile.TemporaryDirectory() as d:
            seed, root, state = Path(d, 'seed'), Path(d, 'runtime'), Path(d, 'state')
            state.mkdir()
            for i, sha in enumerate(shas):   # five image rollouts
                self.fake_release(seed, sha, i + 1)
                m.swap(seed / 'current', sha)
                with redirect_stderr(io.StringIO()):
                    m.seed(seed, root, state, force=True)
            self.assertEqual((os.readlink(root / 'current'), os.readlink(root / '.prev')), (shas[4], shas[3]))
            self.assertEqual(sorted(p.name for p in root.iterdir()), sorted(['current', '.prev', shas[3], shas[4]]))
            # a restart on the same image prunes what an older release left too
            (root / shas[0]).mkdir()
            (root / (shas[1] + '.seed-partial')).mkdir()
            (root / 'notes').mkdir()   # not a version: never ours to remove
            with redirect_stderr(io.StringIO()) as err:
                self.assertEqual(m.seed(seed, root, state, force=True), 'kept')
            self.assertIn('pruned runtime ' + shas[0][:12], err.getvalue())
            self.assertEqual(sorted(p.name for p in root.iterdir()),
                             sorted(['current', '.prev', 'notes', shas[3], shas[4]]))
            self.assertTrue((root / 'current' / 'bin/fleet-node-linux.py').is_file())
            # node-owned: the updater retires versions, the seed removes nothing
            (root / shas[0]).mkdir()
            self.assertEqual(m.seed(seed, root, state), 'kept')
            self.assertTrue((root / shas[0]).is_dir())

    def test_loop_restarts_supervisor_from_new_current(self):
        """A switch's restart request ends the supervisor; the loop starts it again
        from the re-read `current`, never exiting the container; one that keeps
        dying ends the loop."""
        m = module('fleet-node-linux')
        with tempfile.TemporaryDirectory() as d:
            root, out = Path(d), Path(d, 'ran')
            for sha in ('a' * 40, 'b' * 40):
                (root / sha / 'bin').mkdir(parents=True)
                (root / sha / 'bin/fleet-node-supervisor.py').write_text(
                    'import sys\nopen(%r, "a").write("%s\\n")\nsys.exit(0)\n' % (str(out), sha[:1]))
            (root / 'current').symlink_to('a' * 40)
            with patch.dict(os.environ, {'FLEET_NODE_HEARTBEAT': str(root / 'hb'),
                                         'FLEET_NODE_LOOP_CRASHES': '3'}):
                loop = m.Loop(root)
                loop.start()
                loop.child.wait()
                os.unlink(root / 'current')
                (root / 'current').symlink_to('b' * 40)   # the updater switched
                self.assertIsNone(loop.tend())
                loop.child.wait()
                self.assertEqual(out.read_text().split(), ['a', 'b'])
                loop.beat()
                st = self.stage_mod()
                st.HEARTBEAT = str(root / 'hb')
                self.assertEqual(st.live(), 0)
                os.utime(root / 'hb', (1, 1))
                self.assertEqual(st.live(), 1)
                for _ in range(2):
                    self.assertIsNone(loop.tend())
                    loop.child.wait()
                self.assertEqual(loop.tend(), 1)   # a 4th death in the window: give up

    def test_release_train_builds_the_image_in_the_cluster(self):
        """#3855: the release train builds each release's node image in the
        cluster (runs-on: fleet-ack, extras/managed-node/train-build.sh) and
        never lets it gate the move; the Dockerfile's sha256-pinned toolchain is
        its own `tools` stage, taken from TOOLS (default: the stage itself, so a
        build by hand is unchanged), tagged by tools-tag.sh from the stage's text."""
        me = BIN.parent / 'extras/managed-node'
        df = (me / 'Dockerfile').read_text()
        self.assertTrue(df.startswith('# Context'))
        self.assertIn('\nARG TOOLS=tools\nFROM debian:trixie-slim AS tools\n', df)
        self.assertIn('\nFROM ${TOOLS} AS toolsrc\n', df)
        # #4159: the image's base is BASE (Docker Hub by default), the train's copy in the cluster
        self.assertIn('\nARG BASE=debian:trixie-slim\nARG TOOLS=tools\n', df)
        self.assertIn('\nFROM ${BASE}\n', df)
        self.assertIn('COPY --from=toolsrc /opt/tools/usr/local/ /usr/local/', df)
        stage = df.split(' AS tools\n', 1)[1].split('FROM ${TOOLS}', 1)[0]
        for pin in ('NODE_SHA256', 'GO_SHA256', 'KUBECTL_SHA256', 'FNM_SHA256', 'ALIYUN_SHA256', 'UV_SHA256'):
            self.assertIn(pin, stage)   # every downloaded tool is the stage's: the tag covers it
        tag = subprocess.check_output(['bash', str(me / 'tools-tag.sh')], text=True).strip()
        self.assertRegex(tag, r'^tools-[0-9a-f]{16}$')
        with tempfile.TemporaryDirectory() as d:
            moved = Path(d, 'Dockerfile')
            moved.write_text(df.replace('ARG GO_VERSION=', 'ARG GO_VERSION=9'))
            self.assertNotEqual(subprocess.check_output(['bash', str(me / 'tools-tag.sh'), str(moved)], text=True).strip(), tag)
            moved.write_text(df.replace('COPY release.pub', 'COPY  release.pub'))   # outside the stage
            self.assertEqual(subprocess.check_output(['bash', str(me / 'tools-tag.sh'), str(moved)], text=True).strip(), tag)
        r = subprocess.run(['bash', str(me / 'train-build.sh'), 'https://hub', 'not-a-sha', 'r', 't'], capture_output=True)
        self.assertEqual(r.returncode, 2)
        tb = (me / 'train-build.sh').read_text()
        for want in ('conf/release-keys/root.pub', 'fleet-release-verify.py', 'ccquota-linux-amd64',
                     'prepare-image.sh', 'build-arg:TOOLS=', 'push=true', 'containerimage.digest'):
            self.assertIn(want, tb)
        wf = (BIN.parent / '.github/workflows/release-train.yml').read_text()
        self.assertIn('runs-on: fleet-ack', wf)
        self.assertIn('extras/managed-node/train-build.sh', wf)
        self.assertIn("--ignore-check 'node tools' --ignore-check 'node image'", wf)
        self.assertIn('role: gha-claudefleet-node-image', wf)
        self.assertIn('--target tools --provenance=false', wf)   # ACR refuses an attestation manifest
        # #4159: node tools copies the amd64 base beside it; node image builds FROM that copy, retrying a 5xx
        self.assertIn('imagetools create -t "$REPO:base-debian-trixie-slim"', wf)
        self.assertIn('"$BUILD_REPO@$TOOLS_DIGEST" "$BUILD_REPO@$BASE_DIGEST"', wf)
        for want in ('build-arg:BASE=$BASE', 'try $try of 3', 'failed to resolve source metadata', 'Bad Gateway'):
            self.assertIn(want, tb)
        node = wf.split('\n  node-image:\n', 1)[1]
        node = node[:node.index('build and push (train-build.sh)')]
        # #4109: the cluster's git mirror first; GitHub only when it fails, bounded
        self.assertIn('vars.FLEET_TRAIN_GIT_MIRROR', node)
        self.assertLess(node.index('git fetch -q --no-tags "$MIRROR"'), node.index('uses: actions/checkout@v4'))
        self.assertEqual(node.count("steps.mirror.outputs.ok != 'true'"), 2)
        self.assertEqual(node.count('timeout-minutes: 5'), 2)

    def test_image_self_updates_on_its_volume(self):
        """The image's defaults (#3212): the runtime on the PVC, owner node (the
        updater runs and the node program says CapRelease), a boot that seeds,
        PATH and /usr/local/bin following the disk's current, liveness on the loop."""
        df = (BIN.parent / 'extras/managed-node/Dockerfile').read_text()
        self.assertIn('FLEET_NODE_ROOT=/var/db/fleet-node/runtime', df)
        self.assertIn('FLEET_NODE_UPDATE_OWNER=node', df)
        self.assertIn('"/usr/local/lib/fleet-image-stage.py", "boot"]', df)
        self.assertIn('PATH=/var/db/fleet-node/runtime/current/tools/bin:', df)
        self.assertIn('/var/db/fleet-node/runtime/current/tools/bin/$t /usr/local/bin/$t', df)
        self.assertNotIn('/opt/claude-fleet/current', df)
        s = module('fleet-node-supervisor')
        with patch.dict(os.environ, {'FLEET_NODE_UPDATE_OWNER': 'node'}):
            self.assertIn('update', [x['name'] for x in s.default_table(s.Paths())['tasks']])
        raw = subprocess.check_output([sys.executable, str(BIN.parent / 'extras/managed-node/render.py'),
                                       '--image', 'example/image@sha256:' + 'a' * 64,
                                       '--hub', 'https://hub.example', '--storage-class', 'essd'])
        c = json.loads(raw)['items'][-1]['spec']['template']['spec']['containers'][0]
        self.assertEqual(c['livenessProbe']['exec']['command'][-2:], ['/usr/local/lib/fleet-image-stage.py', 'live'])
        self.assertIn('/var/db/fleet-node/runtime/current/bin/fleet-node-linux.py',
                      c['readinessProbe']['exec']['command'])
        # stable cannot move to a release without Linux artifacts: the hub's platforms —
        # in the deployment's own overlay (claude-fleet#3630: ours is in the private
        # deploy repo; FLEET_DEPLOY_K8S names a tree with it laid over)
        rel = Path(os.environ.get('FLEET_DEPLOY_K8S') or BIN.parent / 'deploy/k8s') / 'overlays/prod/deployment-release.yaml'
        if rel.exists():
            self.assertRegex(rel.read_text(), r'CCQUOTA_FLEET_RELEASE_PLATFORMS\n\s+value: darwin-arm64 linux-amd64')

    def test_image_update_never_resumes_saved_switch(self):
        u = module('fleet-node-update')
        obj = u.Updater.__new__(u.Updater)
        obj.st = {'phase': 'switching', 'to': 'a' * 40}
        obj.log = lambda msg: None
        with patch.dict(os.environ, {'FLEET_NODE_UPDATE_OWNER': 'image'}), \
                patch.object(obj, 'switch', side_effect=AssertionError('image runtime changed')):
            self.assertEqual(obj.tick(), 0)

    def test_new_container_does_not_adopt_old_pid(self):
        s = module('fleet-node-supervisor')
        obj = s.Supervisor.__new__(s.Supervisor)
        obj.state = {'supervisor': {'boot_id': 'old'},
                     'children': {'test': {'pid': 17, 'cmd': 'same'}}}
        obj.adopted = {}
        obj.all_children = lambda: [{'name': 'test'}]
        obj.log = lambda msg: None
        with patch.dict(os.environ, {'FLEET_NODE_BOOT_ID': 'new'}), \
                patch.object(s, 'pid_alive', return_value=True), patch.object(s, 'pid_cmd', return_value='same'):
            obj.adopt()
        self.assertEqual(obj.adopted, {})


class PodKeysPull(unittest.TestCase):
    """claude-fleet#4193: a person's pod pulls its login's keys for its own sshd
    (the door's jump needs no key of the door's), says ?jump=1, dials the
    in-cluster hub when it has one, and keeps the last file when the hub fails."""

    def test_pull(self):
        import base64
        lin = module('fleet-node-linux')
        s = module('fleet-node-supervisor')
        b64 = base64.b64encode(b'\x00\x00\x00\x0bssh-ed25519' + b'\x00' * 36).decode()
        key = {'fp': 'SHA256:abc', 'type': 'ssh-ed25519', 'b64': b64, 'name': 'phone'}
        other = dict(key, fp='SHA256:zzz')
        lst = {'version': 3, 'logins': {'alice': {'keys': [key, {'type': 'ssh-dss', 'b64': 'x'}]},
                                        'alice.web': {'keys': [key]}, 'bob': {'keys': [other]}}}
        seen = []

        class R(object):
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return self.body

        def fake(req, timeout=0):
            seen.append((req.full_url, req.headers.get('Authorization')))
            if isinstance(lst, Exception):
                raise lst
            return R(json.dumps(lst).encode())
        with tempfile.TemporaryDirectory() as d:
            Path(d, 'machine.env').write_text('CCQUOTA_HUB_URL=https://hub.example/\nCCQUOTA_TOKEN=tok123\n')
            k = lin.PodKeys(s, 'alice', d)
            with patch.object(lin.urllib.request, 'urlopen', fake), \
                    patch.dict(os.environ, {'FLEET_HUB_INTERNAL_URL': 'http://hub.fleet.svc.cluster.local:8080'}):
                k.pull()
            self.assertEqual(seen, [('http://hub.fleet.svc.cluster.local:8080/v1/node/entry-keys?jump=1', 'Bearer tok123')])
            path = Path(d, 'ssh', 'authorized_keys')
            self.assertEqual(path.read_text(), 'ssh-ed25519 %s fleet:SHA256:abc\n' % b64)
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
            # the hub away: the last file stands
            lst = OSError('down')
            with patch.object(lin.urllib.request, 'urlopen', fake), patch.dict(os.environ, {'FLEET_HUB_INTERNAL_URL': ''}):
                k.pull_quiet()
            self.assertEqual(seen[-1][0], 'https://hub.example/v1/node/entry-keys?jump=1')
            self.assertIn('fleet:SHA256:abc', path.read_text())
            # a key gone from the list is gone from the file
            lst = {'version': 4, 'logins': {'alice': {'keys': []}}}
            with patch.object(lin.urllib.request, 'urlopen', fake):
                k.pull()
            self.assertEqual(path.read_text(), '')


class StaleLane(unittest.TestCase):
    """issue #3333: a refused lane one login left behind took the whole pod
    out of the LoadBalancer — the door died for every login on the node."""

    def sandbox(self, d):
        return patch.dict(os.environ, {'FLEET_NODE_STATE': os.path.join(d, 'db'), 'FLEET_NODE_TEST': '1',
                                       'FLEET_NODE_LOG': os.path.join(d, 'log')})

    def lane(self, d, login):
        p = Path(d, 'db', 'agent', login, 'lane.json')
        p.parent.mkdir(parents=True)
        p.write_text(json.dumps({'state': 'refused', 'code': 'WRONG_LOGIN',
                                 'why': 'unrecognised enrollment token for login %s' % login}))
        return p

    def test_refused_lane_leaves_the_pod_ready(self):
        m = module('fleet-node-linux')
        s = module('fleet-node-supervisor')
        with tempfile.TemporaryDirectory() as d, self.sandbox(d):
            Path(d, 'db').mkdir()
            Path(d, 'db', 'accounts.json').write_text(json.dumps({'alice': {}}))
            self.lane(d, 'alice')
            self.assertEqual(sorted(s.lanes_now(s.Paths(), {})), ['alice'])
            with patch.object(m, 'load', return_value=s), patch.object(s, 'health', return_value=(0, 'ok')), \
                    patch.object(s, 'pid_alive', return_value=True), \
                    patch.object(m.Path, 'exists', return_value=True):
                self.assertEqual(m.probe(Mock(action='ready')), 0, 'a refused lane failed readiness')
                self.assertEqual(m.probe(Mock(action='live')), 0)
            with patch.object(m, 'load', return_value=s), patch.object(s, 'health', return_value=(0, 'ok')), \
                    patch.object(s, 'pid_alive', return_value=False), \
                    patch.object(m.Path, 'exists', return_value=True):
                self.assertEqual(m.probe(Mock(action='ready')), 1, 'machine-wide health no longer gates')

    def test_lane_of_a_login_gone_is_ignored(self):
        s = module('fleet-node-supervisor')
        with tempfile.TemporaryDirectory() as d, self.sandbox(d):
            self.lane(d, 'drill10111306x')
            self.assertEqual(s.lane_refusals(s.Paths()), {}, 'a deleted login\'s lane still counted')
            Path(d, 'db', 'logins').mkdir()
            Path(s.login_env_path(s.Paths(), 'drill10111306x')).write_text('CCQUOTA_TOKEN=x\n')
            self.assertEqual(sorted(s.lane_refusals(s.Paths())), ['drill10111306x'], 'a tenant\'s lane dropped')

    def test_forget_moves_the_agent_dir(self):
        s = module('fleet-node-supervisor')
        with tempfile.TemporaryDirectory() as d, self.sandbox(d):
            lane = self.lane(d, 'bob')
            Path(d, 'db', 'accounts.json').write_text(json.dumps({'bob': {}}))
            Path(d, 'db', 'agent', 'carol').mkdir()
            self.assertEqual(s.account_forget(s.Paths(), 'bob', force=True), 0)
            self.assertFalse(lane.parent.exists(), 'agent/bob is still there')
            self.assertTrue(Path(d, 'db', 'agent', 'carol').is_dir(), 'another login\'s dir went too')
            kept = list(Path(d, 'db', 'attic').glob('agent-bob-*/lane.json'))
            self.assertEqual(len(kept), 1, 'the lane was not kept in the attic')
            self.assertEqual(s.lanes_now(s.Paths(), {}), {})
            # idempotent: forgetting again moves nothing and still answers 0
            self.assertEqual(s.account_forget(s.Paths(), 'bob', force=True), 0)

    def test_login_remove_forgets_through_account_forget(self):
        src = (BIN / 'fleet-node-linux.py').read_text()
        body = src[src.index('def login_remove('):src.index('def login_list(')]
        self.assertIn('s.account_forget(paths, login)', body)


class FakeOS:
    """A passwd/group that vanishes like the image layer's, plus the calls
    login open/remove make — every write lands in a temp dir (EPIC #3208 C1)."""

    def __init__(self, m, d):
        self.m, self.d = m, Path(os.path.realpath(d))
        self.users, self.groups, self.calls, self.owner, self.shadow = {}, {}, [], {}, {}
        self.paths = Mock(state=str(self.d / 'state'), users=str(self.d / 'home'),
                          logins=str(self.d / 'state/logins'))
        Path(self.paths.users).mkdir(parents=True)
        self.sup = Mock(Paths=lambda: self.paths, tenant_privileges=lambda login: ([], True),
                        account_forget=Mock(return_value=0), remove_login_env=Mock(return_value=True))
        self.cred = Mock(ROOT_BASE=str(self.d / 'cred'), purge=Mock(return_value=0))

    def pw(self, name):
        if name not in self.users:
            raise KeyError(name)
        uid, home = self.users[name]
        return Mock(pw_name=name, pw_uid=uid, pw_gid=uid, pw_dir=home)

    def pwuid(self, uid):
        for n, (u, _) in self.users.items():
            if u == uid:
                return self.pw(n)
        raise KeyError(uid)

    def gr(self, name):
        if name not in self.groups:
            raise KeyError(name)
        return Mock(gr_gid=self.groups[name])

    def grgid(self, gid):
        for n, g in self.groups.items():
            if g == gid:
                return self.gr(n)
        raise KeyError(gid)

    def run(self, cmd, **kw):
        self.calls.append(list(cmd))
        tool = cmd[0]
        if cmd[1:] == ['--help']:
            return Mock(returncode=0, stdout='  -b, --badname    allow bad names\n')
        if tool in ('groupadd', 'useradd') and cmd[-1][0].isdigit() and '--badname' not in cmd:
            raise subprocess.CalledProcessError(3, cmd)     # Debian refuses a digit-leading name
        if tool == 'groupadd':
            self.groups[cmd[-1]] = int(cmd[cmd.index('--gid') + 1])
        elif tool == 'useradd':
            self.users[cmd[-1]] = (int(cmd[cmd.index('--uid') + 1]), cmd[cmd.index('--home-dir') + 1])
            # Debian's useradd locks a login it gave no password: `!`
            self.shadow[cmd[-1]] = cmd[cmd.index('--password') + 1] if '--password' in cmd else '!'
        elif tool == 'usermod' and '--password' in cmd:
            self.shadow[cmd[-1]] = cmd[cmd.index('--password') + 1]
        elif tool == 'userdel':
            self.users.pop(cmd[-1])
            self.shadow.pop(cmd[-1], None)
        elif tool == 'groupdel':
            self.groups.pop(cmd[-1])
        elif tool == 'pgrep':
            return Mock(returncode=1, stdout='')
        elif tool == 'tar':
            return REAL_RUN(cmd, capture_output=True, text=True)
        return Mock(returncode=0, stdout='', stderr='')

    def chown(self, path, uid, gid):
        self.owner[str(path)] = (uid, gid)

    def owner_of(self, path):
        return self.owner.get(str(path), (0, 0))

    def reboot(self):
        self.users.clear()
        self.groups.clear()
        self.shadow.clear()

    def __enter__(self):
        m = self.m
        self.stack = [patch.object(m.pwd, 'getpwnam', self.pw), patch.object(m.pwd, 'getpwuid', self.pwuid),
                      patch.object(m.grp, 'getgrnam', self.gr), patch.object(m.grp, 'getgrgid', self.grgid),
                      patch.object(m.subprocess, 'run', self.run), patch.object(m.os, 'chown', self.chown), patch.object(m.os, 'fchown', lambda *a: None),
                      patch.object(m, 'owner_of', self.owner_of), patch.object(m, 'shadow_password', self.shadow.get), patch.object(m, 'as_tenant'),
                      patch.object(m, 'request', return_value={}), patch.object(m, 'live_pids', return_value=[]), patch.object(m.time, 'sleep'),
                      patch.object(m, 'load', lambda n: self.sup if n == 'fleet-node-supervisor' else self.cred)]
        for p in self.stack:
            p.start()
        return self

    def __exit__(self, *exc):
        for p in self.stack:
            p.stop()

    def open(self, login, **kw):
        return self.m.ensure_login(self.sup, self.paths, login, kw.get('uid'), kw.get('full_name', ''))

    def remove(self, login, home='keep'):
        return self.m.login_remove(_ns(name=login, home=home))


def _ns(**kw):
    import argparse
    return argparse.Namespace(**kw)


class LinuxTenants(unittest.TestCase):
    """The three BREAK-IT rows of EPIC #3208 C1 — drilled through these."""

    def setUp(self):
        self.m = module('fleet-node-linux')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_legacy_declaration_migrates_to_per_login(self):
        with FakeOS(self.m, self.tmp.name) as f:
            st = Path(f.paths.state)
            st.mkdir()
            (st / 'linux-tenant.json').write_text(json.dumps(
                {'login': 'fleet', 'uid': 10002, 'gid': 10002, 'home': f.paths.users + '/fleet'}))
            got = self.m.tenants(f.paths)
            self.assertEqual(got['fleet']['uid'], 10002)
            self.assertTrue((st / 'linux-tenant.json.bak').is_file())
            self.assertFalse((st / 'linux-tenant.json').exists())
            self.assertEqual(f.open('drill2').pw_uid, 10003)

    def test_uid_reuse(self):
        """linux-uid-reuse: same number after a restart, a removed number never
        handed out again, a home owned by anyone else stops the boot."""
        with FakeOS(self.m, self.tmp.name) as f:
            a = f.open('24acme')
            b = f.open('drill2')
            self.assertEqual((a.pw_uid, b.pw_uid), (10002, 10003))
            self.assertTrue(any(c[0] == 'useradd' and c[-1] == '24acme' for c in f.calls))
            f.reboot()
            self.m.boot()
            self.assertEqual(f.users['24acme'][0], 10002)
            self.assertEqual(f.users['drill2'][0], 10003)
            self.assertEqual(f.remove('drill2'), 0)
            c = f.open('drill3')
            self.assertNotEqual(c.pw_uid, 10003)
            self.assertEqual(c.pw_uid, 10004)
            # the same name back is a NEW person: a new number, never the retired one
            self.assertEqual(f.open('drill2').pw_uid, 10005)
            # a wrong owner on a home stops the boot; nothing is chowned
            f.owner[f.paths.users + '/24acme'] = (10004, 10004)
            f.reboot()
            chowns = dict(f.owner)
            with self.assertRaisesRegex(ValueError, 'nothing chowned'):
                self.m.boot()
            self.assertEqual(f.owner, chowns)
            self.assertNotIn('24acme', f.users)

    def test_login_locked(self):
        """linux-login-locked (#3304): the entry sshd runs `UsePAM no`, which turns
        a LOCKED account (`!`) away even with its key — open and boot leave `*`,
        and a login an older open left locked is put right by the next boot."""
        with FakeOS(self.m, self.tmp.name) as f:
            f.open('24acme')
            self.assertEqual(f.shadow['24acme'], '*')
            f.shadow['24acme'] = '!'          # what an older open / the image left
            self.m.boot()
            self.assertEqual(f.shadow['24acme'], '*')
            f.reboot()
            self.m.boot()
            self.assertEqual(f.shadow['24acme'], '*')
            f.shadow['24acme'] = '!'
            f.open('24acme')                  # an open of the existing login heals it too
            self.assertEqual(f.shadow['24acme'], '*')
            n = len(f.calls)
            self.m.boot()                       # already `*`: nothing to change
            self.assertFalse(any(c[0] == 'usermod' for c in f.calls[n:]))

    def test_shadow_password_reads_the_second_field(self):
        with tempfile.NamedTemporaryFile('w', delete=False) as sh:
            sh.write('root:*:19000:0:99999:7:::\nfleet:!:19000:0:99999:7:::\n')
        self.addCleanup(os.unlink, sh.name)
        with patch.object(self.m, 'SHADOW', sh.name):
            self.assertEqual(self.m.shadow_password('fleet'), '!')
            self.assertEqual(self.m.shadow_password('root'), '*')
            self.assertIsNone(self.m.shadow_password('nobody'))

    def test_removed_login_lingers(self):
        """linux-removed-login-lingers: remove leaves no user, group, process,
        credsep tenant, daemon entry, node token or declaration; the home is in
        the attic."""
        with FakeOS(self.m, self.tmp.name) as f:
            f.open('drill2')
            home = Path(f.paths.users) / 'drill2'
            (home / 'work.txt').write_text('kept in the attic')
            store = Path(f.cred.ROOT_BASE) / 'drill2'
            store.mkdir(parents=True)
            (store / 'node.env').write_text('CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=t\n')
            self.assertEqual(f.remove('drill2'), 0)
            self.assertNotIn('drill2', f.users)
            self.assertNotIn('drill2', f.groups)
            self.assertFalse(home.exists())
            self.assertIn(['pkill', '-KILL', '-U', '10002'], f.calls)
            f.sup.account_forget.assert_called_once_with(f.paths, 'drill2')
            f.sup.remove_login_env.assert_called_once_with(f.paths, 'drill2')
            self.assertEqual(f.cred.purge.call_args[0][0].login, 'drill2')
            self.m.request.assert_any_call('https://hub.example', '/v1/node/leave', 't',
                                           {'reason': 'login drill2 removed'})
            self.assertFalse(self.m.tenant_path(f.paths, 'drill2').exists())
            archived = list((Path(f.paths.users) / '.attic').glob('drill2-*.tar.gz'))
            self.assertEqual(len(archived), 1)
            self.assertEqual(archived[0].stat().st_mode & 0o777, 0o600)
            self.assertIn('./work.txt', REAL_RUN(['tar', '-tzf', str(archived[0])],
                                                       capture_output=True, text=True).stdout)
            self.assertIn('10002', (self.m.tenants_dir(f.paths) / '.retired').read_text().split())
            with self.assertRaises(self.m.NoLogin):
                f.remove('drill2')

    def test_login_stop_keeps_the_home(self):
        """login stop (C10, #3554): sessions pinned first, the daemon lets go,
        every process stops — and the home, the declaration, the user and the
        credential store all stay; never fleet-down (a fleet marked down is one
        the pod's snapshot restore skips). A failed snapshot stops nothing."""
        with FakeOS(self.m, self.tmp.name) as f:
            f.open('24acme')
            home = Path(f.paths.users) / '24acme'
            (home / 'work.txt').write_text('moves with the home')
            self.m.as_tenant.return_value = Mock(returncode=1)
            with self.assertRaises(RuntimeError):
                self.m.login_stop(_ns(name='24acme'))
            f.sup.account_forget.assert_not_called()
            self.m.as_tenant.reset_mock()
            self.m.as_tenant.return_value = Mock(returncode=0)
            waits = []
            f.sup.account_forget.side_effect = lambda *a: waits.append(os.environ.get('FLEET_NODE_RELEASE_WAIT')) or 0
            with patch.dict(os.environ, {}, clear=False):
                os.environ.pop('FLEET_NODE_RELEASE_WAIT', None)
                self.assertEqual(self.m.login_stop(_ns(name='24acme')), 0)
            # a task mid-run is let go only when it ends: 20 s was short (#3554)
            self.assertEqual(waits, ['120'])
            cmds = [c.args[2] for c in self.m.as_tenant.call_args_list]
            self.assertEqual([c[-1] for c in cmds], ['save'])
            self.assertTrue(cmds[0][1].endswith('fleet-sessions-snapshot.sh'))
            self.assertNotIn('fleet-down.sh', ' '.join(' '.join(c) for c in cmds))
            f.sup.account_forget.assert_called_once_with(f.paths, '24acme')
            self.assertIn(['pkill', '-KILL', '-U', '10002'], f.calls)
            self.assertIn('24acme', f.users)
            self.assertEqual((home / 'work.txt').read_text(), 'moves with the home')
            self.assertTrue(self.m.tenant_path(f.paths, '24acme').exists())
            f.cred.purge.assert_not_called()
            self.assertNotIn('userdel', [c[0] for c in f.calls])
            with self.assertRaises(self.m.NoLogin):
                self.m.login_stop(_ns(name='nobody9'))

    def test_tenant_cross_read(self):
        """linux-tenant-cross-read: every home is 0700 after open and boot, and a
        new login never takes over a home another number owns."""
        with FakeOS(self.m, self.tmp.name) as f:
            f.open('24acme')
            f.open('drill2')
            homes = Path(f.paths.users)
            os.chmod(homes / 'drill2', 0o755)       # someone widened it
            f.reboot()
            self.m.boot()
            for h in ('24acme', 'drill2'):
                self.assertEqual((homes / h).stat().st_mode & 0o777, 0o700, h)
            (homes / 'drill9').mkdir()
            f.owner[str(homes / 'drill9')] = (10002, 10002)     # 24acme's files
            with self.assertRaisesRegex(ValueError, 'nothing chowned'):
                f.open('drill9')
            self.assertEqual(f.owner[str(homes / 'drill9')], (10002, 10002))

    def test_names_and_exit_codes(self):
        m = self.m
        for good in ('24acme', 'fleet', 'drill2'):
            self.assertTrue(m.valid_name(good), good)
        for bad in ('1234', 'a', 'root', 'Bob', '-x', 'a_b', 'x' * 17):
            self.assertFalse(m.valid_name(bad), bad)
        self.assertFalse(m.valid_full_name('a:b'))
        self.assertTrue(m.valid_full_name('Erin Wang'))
        with FakeOS(m, self.tmp.name) as f:
            f.users['admin1'] = (20000, '/home/admin1')
            f.sup.tenant_privileges = lambda login: (['sudo -l: (ALL) ALL'], True)
            with self.assertRaises(m.Refuse) as e:
                f.open('admin1')
            self.assertEqual(e.exception.rc, 5)
            # fleet-login-new.sh's codes (#3210): 2 bad argument, 3 exists, 4 none
            self.assertEqual(m.guarded(lambda: m.login_cmd(['open', '1234'])), 2)
            self.assertEqual(m.guarded(lambda: m.login_cmd(['remove', 'nobody2', '--keep-home'])), 4)
            self.assertEqual(m.guarded(lambda: m.login_cmd(['remove', 'nobody2'])), 2)
            f.sup.tenant_privileges = lambda login: ([], True)
            f.users['hand1'] = (20001, '/home/hand1')
            with self.assertRaises(m.Refuse) as e:
                f.open('hand1')
            self.assertEqual(e.exception.rc, 3)

    def test_user_pod_is_one_persons(self):
        """#3550: in a user pod a second login never moves in beside the first
        (3); the one there reopens as before. Off = any number of logins."""
        m = self.m
        with FakeOS(m, self.tmp.name) as f, patch.dict(os.environ, {'FLEET_NODE_PROFILE': 'user-pod'}):
            m.ensure_login(f.sup, f.paths, 'u1', op='ab12')
            m.ensure_login(f.sup, f.paths, 'u1', op='ab12')
            with self.assertRaises(m.Refuse) as e:
                m.ensure_login(f.sup, f.paths, 'drill2', op='cd34')
            self.assertEqual(e.exception.rc, 3)
            self.assertNotIn('drill2', f.users)
        with FakeOS(m, os.path.join(self.tmp.name, '2')) as f:
            f.open('u1')
            f.open('drill2')

    def test_hub_op_owns_its_login(self):
        """The hub's create (#3210): its op goes into the declaration; the same
        op again goes on, any other op (or a hand) meets 'exists' (3)."""
        m = self.m
        with FakeOS(m, self.tmp.name) as f:
            m.ensure_login(f.sup, f.paths, '24acme', op='ab12')
            decl = json.loads(m.tenant_path(f.paths, '24acme').read_text())
            self.assertEqual(decl['op'], 'ab12')
            m.ensure_login(f.sup, f.paths, '24acme', op='ab12')       # a re-ask, a resume
            with self.assertRaises(m.Refuse) as e:
                m.ensure_login(f.sup, f.paths, '24acme', op='cd34')
            self.assertEqual(e.exception.rc, 3)
            f.open('drill2')                                            # by hand: no op
            with self.assertRaises(m.Refuse) as e:
                m.ensure_login(f.sup, f.paths, 'drill2', op='ab12')
            self.assertEqual(e.exception.rc, 3)
            f.open('drill2')                                            # a hand reopens as before

    def test_join_code_from_env(self):
        m = self.m
        with FakeOS(m, self.tmp.name) as f, patch.dict(os.environ, {'FLEET_LOGIN_JOIN_CODE': 'fj_; rm -rf /'}):
            with self.assertRaises(m.Refuse) as e:
                m.login_open(_ns(name='drill3', full_name='', join_file='', hub='', relay='', start=False))
            self.assertIn('join code', str(e.exception))
            self.assertNotIn('drill3', f.users)
        with FakeOS(m, os.path.join(self.tmp.name, '2')) as f, patch.dict(os.environ, {'FLEET_LOGIN_OP_ID': 'NOT-HEX'}):
            with self.assertRaises(m.Refuse):
                m.login_open(_ns(name='drill3', full_name='', join_file='', hub='', relay='', start=False))

    def test_tenant_conf_is_sourceable(self):
        """#3224: fleet.conf is sourced — a section is a comment; an old literal
        `[common]` line is turned into one, the rest kept."""
        home = Path(self.tmp.name, 'h')
        conf = home / '.config/claude-fleet/fleet.conf'
        env = dict(os.environ, HOME=str(home))
        REAL_RUN([sys.executable, '-c', self.m.TENANT_CONF], env=env, check=True)
        self.assertTrue(conf.read_text().startswith('# ---- [common] ----\n'))
        conf.write_text('[common]\nFLEET_CRED_PROXY=1\nX=2\n')
        REAL_RUN([sys.executable, '-c', self.m.TENANT_CONF], env=env, check=True)
        self.assertEqual(conf.read_text(), '# ---- [common] ----\nFLEET_CRED_PROXY=1\nX=2\n')
        self.assertEqual(REAL_RUN(['sh', '-n', str(conf)]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
