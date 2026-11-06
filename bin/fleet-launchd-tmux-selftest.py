#!/usr/bin/env python3
# selftest-entry
"""GUI launch routing, isolated from the login's real launchd and tmux."""
import importlib.util
import os
from pathlib import Path
import subprocess
import shutil
import time
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('gui_tmux', BIN / 'fleet-launchd-tmux.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class LaunchTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
    def test_real_resident_server_and_no_autostart(self):
        # Only this test's private socket; no managed socket is ever addressed.
        with tempfile.TemporaryDirectory(prefix='fleet-gui-real.') as d:
            sock = str(Path(d) / 'server')
            tmux = m.real_tmux()
            proc = subprocess.Popen([tmux, '-D', '-S', sock, '-f', '/dev/null'],
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    result = subprocess.run([tmux, '-S', sock, '-N', 'show-options', '-s', 'exit-empty'], capture_output=True)
                    if result.returncode == 0:
                        break
                    time.sleep(.02)
                self.assertEqual(result.returncode, 0)
                self.assertIn(b'off', result.stdout)
                subprocess.run([tmux, '-S', sock, '-N', 'new-session', '-d', '-s', 'isolated', 'sleep 30'], check=True)
                self.assertIsNone(proc.poll())
                subprocess.run([tmux, '-S', sock, 'set-option', '-g', '@launchd_warning', 'launchd: Background'], check=True)
                bar = subprocess.run([sys.executable, str(BIN / 'fleet-topbar.py'), 'render', '--node', 'sock='+sock, 'cw=80'], capture_output=True, text=True, check=True)
                self.assertIn('launchd: Background', bar.stdout)
                self.assertIn('Aqua', bar.stdout)
            finally:
                subprocess.run([tmux, '-S', sock, 'kill-server'], capture_output=True)
                proc.wait(timeout=5)
            result = subprocess.run([tmux, '-S', sock, '-N', 'new-session', '-d'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_existing_server_is_never_restarted(self):
        with patch.object(m, 'alive', return_value=True), patch.object(m, 'run') as run:
            m.ensure('isolated', '/dev/null')
            run.assert_not_called()

    def test_missing_gui_refuses_without_start(self):
        with patch.object(m, 'alive', return_value=False), patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')) as run:
            with self.assertRaisesRegex(RuntimeError, 'gui/'):
                m.ensure('isolated', '/dev/null')
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][:2], ['launchctl', 'print'])

    def test_plist_foreground_and_no_secrets(self):
        with patch.dict(os.environ, {'FLEET_WORKER_CRED': 'secret', 'GH_TOKEN': 'secret'}):
            p = m.job('test-label', '/real/tmux', 'isolated', '/conf', '/log')
        self.assertIn('-D', p['ProgramArguments'])
        self.assertEqual(p['LimitLoadToSessionType'], 'Aqua')
        self.assertNotIn('KeepAlive', p)
        self.assertNotIn('secret', str(p))
        self.assertNotIn('TMUX', p['EnvironmentVariables'])

    def test_bootstrap_then_wait_no_kill(self):
        with tempfile.TemporaryDirectory(prefix='fleet-gui-test.') as d, patch.dict(os.environ, {'FLEET_CONF_DIR': d}), patch.object(m, 'alive', side_effect=[False, True]), patch.object(m.shutil, 'which', return_value='/real/tmux'), patch.object(m, 'run', side_effect=[subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0)]) as run:
            m.ensure('isolated', '/conf')
            calls = [c.args[0] for c in run.call_args_list]
            self.assertEqual(calls[-1][:2], ['launchctl', 'bootstrap'])
            self.assertFalse(any('bootout' in c or '-k' in c for c in calls))
            self.assertTrue(list(Path(d).rglob('*.plist')))

    def test_probe_error_is_visible(self):
        with patch.object(m.sys, 'platform', 'darwin'), patch.dict(os.environ, {'TMUX': '/isolated,1,0'}), patch.object(m, 'run', side_effect=[OSError('unavailable'), subprocess.CompletedProcess([], 0)]) as run:
            m.stamp()
            self.assertEqual(run.call_args.args[0][-1], 'launchd: unknown')

    def test_loaded_service_kickstart_never_kills(self):
        with tempfile.TemporaryDirectory(prefix='fleet-gui-test.') as d, patch.dict(os.environ, {'FLEET_CONF_DIR': d}), patch.object(m, 'alive', side_effect=[False, True]), patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            m.ensure('isolated', '/conf')
            self.assertEqual(run.call_args.args[0][:2], ['launchctl', 'kickstart'])
            self.assertNotIn('-k', run.call_args.args[0])

    def test_server_probe_reports_background_and_clears_aqua(self):
        for manager, warning in [('Background', 'launchd: Background'), ('Aqua', '')]:
            with patch.object(m.sys, 'platform', 'darwin'), patch.dict(os.environ, {'TMUX': '/isolated,1,0'}), patch.object(m, 'run', side_effect=[subprocess.CompletedProcess([], 0, manager+'\n'), subprocess.CompletedProcess([], 0)]) as run:
                m.stamp()
                self.assertEqual(run.call_args.args[0][-1], warning)


if __name__ == '__main__':
    unittest.main()
