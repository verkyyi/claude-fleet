#!/usr/bin/env python3
"""Linux managed lifecycle contracts (#3022), isolated from the live install."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
import json
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
            args = Mock(login='arvin2', uid=10003, hub='https://hub.example', join_file=str(code),
                        relay='https://relay.example')
            with patch.object(m, 'load', side_effect=lambda n: {'fleet-node-supervisor': s, 'fleet-credsep': c}[n]), \
                    patch.object(m, 'ensure_login', return_value=me), patch.object(m, 'as_tenant'), \
                    patch.object(m, 'request', side_effect=hub), patch.object(m, 'private_write', side_effect=write), \
                    patch.object(m.pwd, 'getpwnam', return_value=me), patch.object(m.os, 'chown'):
                m.prepare(args)
                s.account_adopt.assert_called_once()
                self.assertFalse((d / 'cred/arvin2/cred-proxy/relay.token').exists())
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
        doc = (BIN.parent / 'docs/MANAGED-LINUX.md').read_text()
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
            cfg = s.entry_config(s.EntryPaths(p), 22022, ['24haowan'])
        lines = set(cfg.splitlines())
        for want in ('Port 22022', 'AuthenticationMethods publickey', 'PasswordAuthentication no',
                     'KbdInteractiveAuthentication no', 'PermitRootLogin no', 'AllowUsers 24haowan'):
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
        # stable cannot move to a release without Linux artifacts: the hub's platforms
        rel = (BIN.parent / 'deploy/k8s/overlays/prod/deployment-release.yaml').read_text()
        self.assertRegex(rel, r'CCQUOTA_FLEET_RELEASE_PLATFORMS\n\s+value: darwin-arm64 linux-amd64')

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
            a = f.open('24haowan')
            b = f.open('drill2')
            self.assertEqual((a.pw_uid, b.pw_uid), (10002, 10003))
            self.assertTrue(any(c[0] == 'useradd' and c[-1] == '24haowan' for c in f.calls))
            f.reboot()
            self.m.boot()
            self.assertEqual(f.users['24haowan'][0], 10002)
            self.assertEqual(f.users['drill2'][0], 10003)
            self.assertEqual(f.remove('drill2'), 0)
            c = f.open('drill3')
            self.assertNotEqual(c.pw_uid, 10003)
            self.assertEqual(c.pw_uid, 10004)
            # the same name back is a NEW person: a new number, never the retired one
            self.assertEqual(f.open('drill2').pw_uid, 10005)
            # a wrong owner on a home stops the boot; nothing is chowned
            f.owner[f.paths.users + '/24haowan'] = (10004, 10004)
            f.reboot()
            chowns = dict(f.owner)
            with self.assertRaisesRegex(ValueError, 'nothing chowned'):
                self.m.boot()
            self.assertEqual(f.owner, chowns)
            self.assertNotIn('24haowan', f.users)

    def test_login_locked(self):
        """linux-login-locked (#3304): the entry sshd runs `UsePAM no`, which turns
        a LOCKED account (`!`) away even with its key — open and boot leave `*`,
        and a login an older open left locked is put right by the next boot."""
        with FakeOS(self.m, self.tmp.name) as f:
            f.open('24haowan')
            self.assertEqual(f.shadow['24haowan'], '*')
            f.shadow['24haowan'] = '!'          # what an older open / the image left
            self.m.boot()
            self.assertEqual(f.shadow['24haowan'], '*')
            f.reboot()
            self.m.boot()
            self.assertEqual(f.shadow['24haowan'], '*')
            f.shadow['24haowan'] = '!'
            f.open('24haowan')                  # an open of the existing login heals it too
            self.assertEqual(f.shadow['24haowan'], '*')
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

    def test_tenant_cross_read(self):
        """linux-tenant-cross-read: every home is 0700 after open and boot, and a
        new login never takes over a home another number owns."""
        with FakeOS(self.m, self.tmp.name) as f:
            f.open('24haowan')
            f.open('drill2')
            homes = Path(f.paths.users)
            os.chmod(homes / 'drill2', 0o755)       # someone widened it
            f.reboot()
            self.m.boot()
            for h in ('24haowan', 'drill2'):
                self.assertEqual((homes / h).stat().st_mode & 0o777, 0o700, h)
            (homes / 'drill9').mkdir()
            f.owner[str(homes / 'drill9')] = (10002, 10002)     # 24haowan's files
            with self.assertRaisesRegex(ValueError, 'nothing chowned'):
                f.open('drill9')
            self.assertEqual(f.owner[str(homes / 'drill9')], (10002, 10002))

    def test_names_and_exit_codes(self):
        m = self.m
        for good in ('24haowan', 'fleet', 'drill2'):
            self.assertTrue(m.valid_name(good), good)
        for bad in ('1234', 'a', 'root', 'Bob', '-x', 'a_b', 'x' * 17):
            self.assertFalse(m.valid_name(bad), bad)
        self.assertFalse(m.valid_full_name('a:b'))
        self.assertTrue(m.valid_full_name('Arvin Wang'))
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

    def test_hub_op_owns_its_login(self):
        """The hub's create (#3210): its op goes into the declaration; the same
        op again goes on, any other op (or a hand) meets 'exists' (3)."""
        m = self.m
        with FakeOS(m, self.tmp.name) as f:
            m.ensure_login(f.sup, f.paths, '24haowan', op='ab12')
            decl = json.loads(m.tenant_path(f.paths, '24haowan').read_text())
            self.assertEqual(decl['op'], 'ab12')
            m.ensure_login(f.sup, f.paths, '24haowan', op='ab12')       # a re-ask, a resume
            with self.assertRaises(m.Refuse) as e:
                m.ensure_login(f.sup, f.paths, '24haowan', op='cd34')
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
