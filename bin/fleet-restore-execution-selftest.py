#!/usr/bin/env python3
# selftest-entry
"""Real restore + wrapper on a private tmux socket; no native Coding Agent."""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
from fleet_task_execution import ExecutionFence

FIXTURE = json.loads((BIN.parent / 'tokenledger/hub/store/testdata/task_execution.json').read_text())
FID = FIXTURE['execution_owner'].split('/')[1]
TMUX = shutil.which('tmux')


@unittest.skipUnless(TMUX, 'tmux unavailable')
class RestoreExecution(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='restore-execution-')
        self.root = Path(self.tmp.name).resolve()
        self.sock = str(self.root / 'tmux.sock')
        self.conf = self.root / 'conf'
        self.fleet = self.conf / 'fleets/oc'
        self.fleet.mkdir(parents=True)
        (self.fleet / 'conf').write_text('FLEET_SESSION=oc\n')
        self.map = self.fleet / 'restore.map'
        self.fake = self.root / 'fake'
        self.fake.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FLEET_', 'RESTORE_', 'HUB_'))
                    and k not in ('TMUX', 'TMUX_PANE', 'QUIET')}
        self.env.update(HOME=str(self.root), FLEET_CONF_DIR=str(self.conf), SHELL='/bin/sh',
                        FLEET_SKIP_GLOBAL_CONF='1', FLEET_RESTORE_PROBE_SECS='1',
                        FLEET_EXIT_CLOSE_SECS='0', PYTHONDONTWRITEBYTECODE='1', TMUX_TMPDIR=str(self.root),
                        PATH=str(self.fake) + ':' + self.env.get('PATH', ''))
        # Delay only the old parent-side identity write: the real pane must see
        # identity before the wrapper starts, independent of tmux scheduling.
        self.script('tmux', '#!/bin/sh\n'
                    'case "$*" in *"set-window-option"*"@fleet_id"*) sleep 0.5;; esac\n'
                    'case "$*" in *"set-option"*) fail=$(cat ' + shlex.quote(str(self.root / 'fail-stamp')) +
                    ' 2>/dev/null); if [ -n "$fail" ]; then for arg do [ "$arg" != "$fail" ] || exit 1; done; fi;; esac\n'
                    'exec ' + shlex.quote(TMUX) + ' -S ' + shlex.quote(self.sock) + ' "$@"\n')
        self.script('native', '#!/bin/sh\n'
                    'tmux display-message -p -t "$TMUX_PANE" "#{@fleet_id}|#{@id_next_trigger}" >> '
                    + shlex.quote(str(self.root / 'native.log')) + '\n'
                    'printf "❯ \\n"\nexec sleep 600\n')
        self.env['FLEET_WRAP_LAUNCH'] = str(self.fake / 'native')
        self.tmux('new-session', '-d', '-s', 'oc', '-n', 'home', '-c', str(self.root), 'sleep 600')
        self.tmux('set-option', '-g', 'remain-on-exit', 'on')
        self.tmux('set-option', '-w', '-t', 'oc:home', '@fleet_role', 'home')

    def tearDown(self):
        subprocess.run([TMUX, '-S', self.sock, 'kill-server'], capture_output=True, env=self.env)
        self.tmp.cleanup()

    def script(self, name, content):
        p = self.fake / name
        p.write_text(content)
        p.chmod(0o755)

    def tmux(self, *args):
        return subprocess.check_output([TMUX, '-S', self.sock, *args], env=self.env, text=True).strip()

    def seed(self, execution=None):
        row = ['WIN', 'sample', str(self.root), '11111111-2222-4333-8444-555555555555',
               '-', 'working', '-', '-', '-', 'claude', '-', '-', '-', '-', '-', '-']
        data = 'FLEET\toc\t\t\t\nFID\t' + FID + '\n' + '\t'.join(row) + '\n'
        if execution is not None:
            raw = json.dumps(execution) if isinstance(execution, dict) else execution
            data += 'EXECUTION\t' + FID + '\t' + base64.b64encode(raw.encode()).decode() + '\n'
        self.map.write_text(data)

    def restore(self):
        run = subprocess.run(['bash', str(BIN / 'fleet-restore.sh')], env=self.env,
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return run.stdout

    def native(self):
        p = self.root / 'native.log'
        return p.read_text().splitlines() if p.exists() else []

    def test_stopped_binding_never_resumes_as_legacy(self):
        fence = ExecutionFence(self.conf)
        fence.bind(FIXTURE, authorized=True)
        fence.apply_stop(dict(FIXTURE, generation=2, cancel_request='human-stop'))
        self.seed()  # Older map still has a lifelong FID and durable local fence.
        self.restore()
        self.assertEqual(self.native(), [], 'stopped Task reached native launcher as legacy')
        self.assertEqual(self.tmux('show-options', '-wqv', '-t', 'oc:sample', '@fleet_id'), FID)

    def test_explicit_contract_survives_missing_database(self):
        self.seed(FIXTURE)
        self.restore()
        self.assertEqual(self.native(), [], 'lost local database downgraded controlled restore to legacy')
        self.assertEqual(json.loads(self.tmux('show-options', '-wqv', '-t', 'oc:sample', '@task_execution')), FIXTURE)

    def test_malformed_contract_is_held_without_shell_execution(self):
        self.seed("not-json' ; touch " + str(self.root / 'injected') + "; #")
        self.restore()
        self.assertEqual(self.native(), [])
        self.assertFalse((self.root / 'injected').exists())

    def test_failed_identity_stamp_does_not_start_wrapper(self):
        self.seed()
        (self.root / 'fail-stamp').write_text('@fleet_id')
        self.restore()
        self.assertEqual(self.native(), [], 'failed identity stamp continued to launcher')

    def test_failed_execution_stamp_does_not_start_wrapper(self):
        self.seed(FIXTURE)
        (self.root / 'fail-stamp').write_text('@task_execution')
        self.restore()
        self.assertEqual(self.native(), [], 'failed execution stamp continued as legacy')

    def test_legacy_restore_keeps_identity_before_native_entry(self):
        self.seed()
        self.restore()
        self.assertEqual(len(self.native()), 1, 'uncontrolled offline restore must remain available')
        self.assertTrue(self.native()[0].startswith(FID + '|reopen:'), self.native())

    def test_snapshot_keeps_explicit_contract_in_identity_row(self):
        self.seed()
        self.restore()
        raw = json.dumps(FIXTURE, separators=(',', ':'))
        self.tmux('set-option', '-w', '-t', 'oc:sample', '@task_execution', raw)
        self.tmux('set-option', '-w', '-t', 'oc:sample', '@cc_session_id', '11111111-2222-4333-8444-555555555555')
        run = subprocess.run(['bash', str(BIN / 'fleet-restore.sh'), '--snapshot'], env=self.env,
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        rows = [line.split('\t') for line in self.map.read_text().splitlines() if line.startswith('EXECUTION\t')]
        self.assertEqual(len(rows), 1, self.map.read_text())
        self.assertEqual(rows[0][1], FID)
        self.assertEqual(json.loads(base64.b64decode(rows[0][2])), FIXTURE)
        self.tmux('kill-window', '-t', 'oc:sample')  # This test's private socket only.
        self.restore()
        self.assertEqual(len(self.native()), 1, 'snapshot roundtrip without local authority started again')


if __name__ == '__main__':
    unittest.main()
