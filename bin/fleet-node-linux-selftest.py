#!/usr/bin/env python3
"""Linux managed lifecycle contracts (#3022), isolated from the live install."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
import json
import subprocess
import sys
from unittest.mock import patch

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
        with patch.dict(os.environ, {'FLEET_NODE_UPDATE_OWNER': 'hub'}):
            self.assertIn('update', [x['name'] for x in s.default_table(s.Paths())['tasks']])

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
