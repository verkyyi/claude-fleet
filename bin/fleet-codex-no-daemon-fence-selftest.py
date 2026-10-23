#!/usr/bin/env python3
# selftest-entry
"""Actual Codex no-daemon boundary obeys controlled admission and legacy argv."""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import unittest

from fleet_task_execution import FenceRefused, prove_native_session_exit

BIN = Path(__file__).resolve().parent
fixture_module = runpy.run_path(str(BIN / 'fleet-task-execution-native-selftest.py'))


class NoDaemonFenceTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture_module['NativeExecutionTests']()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        shutil.copy2(BIN/'fleet-codex-runtime.py', f.bin/'fleet-codex-runtime.py')
        f.launcher.write_text('''#!/usr/bin/env python3
import os,pathlib,sys,time
root=pathlib.Path(os.environ['TEST_ROOT'])
(root/'initializing').touch()
while not (root/'release').exists(): time.sleep(.02)
os.execv(sys.executable,[sys.executable,str(root/'bin/fleet-codex-runtime.py'),'--','--no-daemon','hello task'])
''')
        codex = f.bin/'codex'
        codex.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys,time
from fleet_native_proc import process
root=pathlib.Path(os.environ['TEST_ROOT'])
(root/'native.json').write_text(json.dumps(dict(process=process(os.getpid()), argv=sys.argv[1:],
    controlled='FLEET_TASK_EXECUTION' in os.environ, launch='FLEET_TASK_LAUNCH_ID' in os.environ)))
while root.exists() and not os.environ.get('FIXTURE_EXIT') and not (root/'native-exit').exists(): time.sleep(.02)
''')
        codex.chmod(0o700)
        f.env['PATH'] = str(f.bin)+os.pathsep+f.env.get('PATH', os.defpath)

    def runtime(self, env):
        f = self.fixture
        return subprocess.run([sys.executable,str(f.bin/'fleet-codex-runtime.py'),'--','--no-daemon','hello task'],
                              env=env, text=True, capture_output=True, timeout=8)

    def test_stopped_controlled_launch_cannot_enter_codex_exec(self):
        f = self.fixture
        f.fence.request_stop('T42', 'stop-before-native', generation=2)
        result = self.runtime(dict(f.env, FLEET_TASK_LAUNCH_ID='not-authorized', FIXTURE_EXIT='1'))
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse((f.root/'native.json').exists(), 'stale controlled --no-daemon reached native exec')

    def test_live_controlled_cli_registers_codex_client_and_strips_authority(self):
        f = self.fixture
        child = f.start(wrapper=False)
        f.wait_file('initializing', child)
        (f.root/'release').touch()
        f.wait_file('native.json', child)
        actual = json.loads((f.root/'native.json').read_text())
        launch = f.fence.launch('T42')
        self.assertEqual([item['component'] for item in launch['native']], ['client'])
        self.assertEqual(launch['native'][0]['process'], {key: actual['process'][key] for key in ('pid', 'birth')})
        self.assertEqual(actual['argv'], ['--no-daemon', 'hello task'])
        self.assertFalse(actual['controlled'])
        self.assertFalse(actual['launch'])
        stopped = f.fence.request_stop('T42', 'stop-client', generation=2)
        self.assertNotEqual(child.wait(timeout=8), 0)
        # This narrow boundary fix does not manufacture a complete server/client
        # exit proof, and must never relabel a Codex client as Claude's agent.
        for provider in ('codex', 'claude'):
            with self.assertRaises(FenceRefused):
                prove_native_session_exit(stopped, provider, conf_dir=f.root/'conf')

    def test_uncontrolled_no_daemon_keeps_original_argv(self):
        f = self.fixture
        env = dict(f.env, FIXTURE_EXIT='1')
        env.pop('FLEET_TASK_EXECUTION', None)
        env.pop('FLEET_TASK_LAUNCH_ID', None)
        result = self.runtime(env)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads((f.root/'native.json').read_text())
        self.assertEqual(actual['argv'], ['--no-daemon', 'hello task'])
        self.assertFalse(actual['controlled'])
        self.assertIsNone(f.fence.launch('T42'))


if __name__ == '__main__':
    unittest.main()
