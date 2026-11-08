#!/usr/bin/env python3
# selftest-entry
"""GUI launch routing, isolated from the login's real launchd and tmux."""
import importlib.util
import base64
import json
import os
import re
from pathlib import Path
import subprocess
import shutil
import shlex
import time
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('gui_tmux', BIN / 'fleet-launchd-tmux.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.path.insert(0, str(BIN))
spec = importlib.util.spec_from_file_location('topbar', BIN / 'fleet-topbar.py')
tb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tb)


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
                def T(*args):
                    return subprocess.run([tmux, '-S', sock, *args], capture_output=True, text=True, check=True).stdout.strip()
                win = T('display-message', '-p', '#{window_id}')
                T('rename-window', '-t', win, 'test')
                T('set-option', '-w', '-t', win, '@ctx_left', '62')
                T('set-option', '-w', '-t', win, '@model', 'Opus')
                T('set-option', '-w', '-t', win, '@effort', 'high')
                env = dict(os.environ, HOME=d, FLEET_CONF_DIR=d, FLEET_SKIP_GLOBAL_CONF='1')
                # Run the doctor's real domain section against this socket only.
                docbin = Path(d) / 'bin'
                docbin.mkdir()
                (docbin / 'fleet-lib.sh').write_text('fleet_sockets() { echo isolated; }\n')
                shim = docbin / 'tmux'
                shim.write_text('#!/bin/sh\nshift 2\nexec '+shlex.quote(tmux)+' -S '+shlex.quote(sock)+' "$@"\n')
                shim.chmod(0o755)
                doctor_block = (BIN / 'fleet-doctor.sh').read_text().split('# --- launchd-domain:', 1)[1].split('# --- hub-image', 1)[0]
                doctor_block = doctor_block.split('\n', 1)[1]
                def doctor():
                    return subprocess.run(['bash', '-c', 'conf_dir=$FLEET_CONF_DIR; warn() { printf "%s %s\\n" "$1" "$2"; };\n'+doctor_block,
                                           str(docbin / 'fleet-doctor.sh')], capture_output=True, text=True, check=True,
                                          env=dict(env, PATH=str(docbin)+os.pathsep+env['PATH'])).stdout
                def render(cols=80, lang='en', *extra):
                    bar = subprocess.run([sys.executable, str(BIN / 'fleet-topbar.py'), 'render', '--node',
                                          'sock='+sock, 'w='+win, 'cw='+str(cols), 'vl=1:'+lang, *extra],
                                         capture_output=True, text=True, check=True, env=env).stdout.strip()
                    if not extra and cols == 80:
                        self.assertIn('62%', bar)
                    if extra:
                        self.assertIn('50%', bar)
                    T('set-option', '-w', '-t', win, '@test_render', bar)
                    return re.sub(r'#\[[^]]*\]', '', T('display-message', '-p', '-t', win, '#{E:@test_render}'))
                def stamp(domain):
                    def run(argv):
                        if argv[0] == 'launchctl':
                            return subprocess.CompletedProcess(argv, 0, domain+'\n')
                        return subprocess.run([tmux, '-S', sock, *argv[1:]], capture_output=True, text=True, check=True)
                    with patch.object(m.sys, 'platform', 'darwin'), patch.dict(os.environ, {'TMUX': sock+',1,0'}), patch.object(m, 'run', side_effect=run):
                        m.stamp()
                for lang, tag in [('en', '⚠ launchd:BG'), ('zh', '⚠ 后台域')]:
                    T('set-option', '-g', '@launchd_warning', '')
                    baseline = render(80, lang)
                    narrow = render(20, lang)
                    stamp('Background')
                    plain = render(80, lang)
                    self.assertIn(tag, plain)
                    self.assertIn('tokenman', plain)
                    self.assertIn('Opus high', plain)
                    self.assertEqual(plain.replace(tag, '').replace(' · ', ' ').split(), baseline.replace(' · ', ' ').split())
                    self.assertLessEqual(tb.cells(plain), 80)
                    self.assertEqual(render(20, lang), narrow)
                    T('set-option', '-g', '@launchd_warning_ack', 'launchd: Background')
                    stamp('Background')  # Session start / config reload preserves acknowledgement.
                    self.assertEqual(render(80, lang), baseline)
                    self.assertEqual(T('show-options', '-gqv', '@launchd_warning'), 'launchd: Background')
                    self.assertIn('launchd: Background', doctor())
                    stamp('System')
                    self.assertEqual(T('show-options', '-gqv', '@launchd_warning_ack'), '')
                    self.assertIn('⚠ launchd:SYS', render(80, lang))
                    stamp('Aqua')
                    self.assertEqual(render(80, lang), baseline)
                    self.assertEqual(doctor(), '')
                    stamp('Background')
                    self.assertIn(tag, render(80, lang))
                # Upload progress must still own the line while the warning is set.
                T('set-option', '-w', '-t', win, '@view_upload_id', 'test')
                T('set-option', '-w', '-t', win, '@view_upload_gen', 'gen')
                state = dict(id='test', generation='gen', window=win, phase='uploading', until=time.time()+60,
                             done=50, total=100, name='file.txt')
                upload = base64.b64encode(json.dumps(state).encode()).decode()
                line = render(80, 'en', 'up='+upload)
                self.assertIn('Uploading', line)
                self.assertIn('50', line)
                self.assertIn('cancel', line)
                self.assertNotIn('launchd', line)
            finally:
                subprocess.run([tmux, '-S', sock, 'kill-server'], capture_output=True)
                proc.wait(timeout=5)
            result = subprocess.run([tmux, '-S', sock, '-N', 'new-session', '-d'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_shim_resolution_keeps_the_managed_symlink(self):
        with tempfile.TemporaryDirectory(prefix='fleet-gui-tool.') as d:
            root = Path(d)
            shim = root / 'tmux-shim'
            stable = root / 'stable-bin'
            shim.mkdir(); stable.mkdir()
            binary = root / 'version-tmux'
            binary.write_text('#!/bin/sh\nexit 0\n')
            binary.chmod(0o755)
            (shim / 'tmux').symlink_to(binary)
            (stable / 'tmux').symlink_to(binary)
            with patch.dict(os.environ, {'PATH': str(shim)+os.pathsep+str(stable)}):
                self.assertEqual(m.real_tmux(), str(stable / 'tmux'))

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
        with patch.object(m.sys, 'platform', 'darwin'), patch.dict(os.environ, {'TMUX': '/isolated,1,0'}), patch.object(m, 'run', side_effect=[OSError('unavailable'), subprocess.CompletedProcess([], 0, ''), subprocess.CompletedProcess([], 0)]) as run:
            m.stamp()
            self.assertEqual(run.call_args.args[0][-1], 'launchd: unknown')

    def test_loaded_service_kickstart_never_kills(self):
        with tempfile.TemporaryDirectory(prefix='fleet-gui-test.') as d, patch.dict(os.environ, {'FLEET_CONF_DIR': d}), patch.object(m, 'alive', side_effect=[False, True]), patch.object(m, 'run', return_value=subprocess.CompletedProcess([], 0)) as run:
            m.ensure('isolated', '/conf')
            self.assertEqual(run.call_args.args[0][:2], ['launchctl', 'kickstart'])
            self.assertNotIn('-k', run.call_args.args[0])

    def test_server_probe_reports_background_and_clears_aqua(self):
        for manager, warning in [('Background', 'launchd: Background'), ('Aqua', '')]:
            with patch.object(m.sys, 'platform', 'darwin'), patch.dict(os.environ, {'TMUX': '/isolated,1,0'}), patch.object(m, 'run', side_effect=[subprocess.CompletedProcess([], 0, manager+'\n'), subprocess.CompletedProcess([], 0, ''), subprocess.CompletedProcess([], 0)]) as run:
                m.stamp()
                self.assertEqual(run.call_args.args[0][-1], warning)

    def test_tag_never_displaces_normal_content(self):
        rec = dict(title='A long session title with 中文', pr='#123✓', ctx_left=62,
                   model='Opus', effort='high', tokens_today=123456, node='peer')
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {'HOME': d, 'FLEET_CONF_DIR': d, 'FLEET_SKIP_GLOBAL_CONF': '1'}):
            for width in (20, 40, 45, 79, 80, 100, 139, 140, 180, 240):
                for trouble in ('', 'down'):
                    baseline, bg = tb.layout(rec, width, down=trouble, upstream='Upstream reset')
                    tagged, tag_bg = tb.layout(rec, width, down=trouble, upstream='Upstream reset', launchd='⚠ launchd:BG')
                    content = lambda parts: [(t, c, r) for t, c, r in parts if t.strip() and 'launchd:BG' not in t]
                    self.assertEqual(content(tagged), content(baseline))
                    self.assertEqual(sum(tb.cells(t) for t, _, _ in tagged), sum(tb.cells(t) for t, _, _ in baseline))
                    self.assertEqual(bg, tag_bg)


if __name__ == '__main__':
    unittest.main()
