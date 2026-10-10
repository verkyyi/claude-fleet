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
            run.return_value.returncode = 1
            with self.assertRaisesRegex(RuntimeError, 'restore failed'):
                m.bootstrap(Mock(login='fleet'))

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


if __name__ == '__main__':
    unittest.main()
