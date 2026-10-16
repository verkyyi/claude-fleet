#!/usr/bin/env python3
"""Deterministic process fixtures; no account, network or live fleet writes."""
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1)).resolve()
sys.path.insert(0, str(BIN))
LIB = runpy.run_path(str(BIN / 'fleet-sleep.py'))


class CodexBusy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='codex-busy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.server = self.root / 'mcp.py'
        self.server.touch()
        self.remote = 'unix://' + str(self.root / 'native.sock')
        self.source = dict(agent='codex', pid=101, session_id='native-sid',
                           worktree=str(self.root), transcript=str(self.root / 'rollout.jsonl'),
                           home=str(self.root), codex_identity=dict(owner='101', session_id='native-sid',
                           home=str(self.root), remote=self.remote))
        self.rows = {101: (1, 'bash'), 102: (101, 'codex'), 103: (102, 'python')}
        self.argv = {101: ['bash', str(BIN / 'fleet-codex.sh')],
                     102: ['codex', 'app-server', '--listen', self.remote],
                     103: [sys.executable, str(self.server)]}
        self.exes = {101: Path('/bin/bash'), 102: Path('/release/codex'),
                     103: Path(sys.executable).resolve()}
        self.config = {'service': dict(command=sys.executable, args=[str(self.server)])}
        test = self

        class Client:
            def __init__(self, remote, **kw): test.assertEqual(remote, test.remote)
            def close(self): pass
            def call(self, method, params):
                if method == 'config/read': return {'config': {'mcp_servers': test.config}}
                if method == 'mcpServerStatus/list':
                    return {'data': [{'name': 'service', 'runtimeStatus': 'ready'}]}
                raise AssertionError(method)

        for p in (patch.dict(LIB['TRANSFER'], process_rows=lambda: self.rows),
                  patch.dict(LIB['ARGV'], process_argv=lambda pid: self.argv[pid],
                             process_executable=lambda pid: self.exes[pid]),
                  patch.dict(LIB['quiet_processes'].__globals__, RPC=Client)):
            p.start(); self.addCleanup(p.stop)

    def busy(self):
        result = []
        LIB['quiet_processes'](self.source, background=result, strict=False)
        return result

    def test_idle_persistent_mcp_is_not_work(self):
        self.assertEqual(self.busy(), [])

    def test_app_server_can_be_the_bound_root(self):
        self.source['pid'] = 102
        self.source['codex_identity']['owner'] = '102'
        self.assertEqual(self.busy(), [])

    def test_mcp_job_is_still_work(self):
        self.rows[104] = (103, 'python')
        self.argv[104] = [sys.executable, '-c', 'background job']
        self.exes[104] = Path(sys.executable).resolve()
        self.assertEqual(self.busy(), [104])

    def test_same_named_unconfigured_service_is_work(self):
        self.argv[103].append('--different')
        self.assertEqual(self.busy(), [103])

    def test_bundled_helper_and_its_jobs(self):
        # Linux comm truncates the bundled executable's name to 15 bytes.
        self.rows[104] = (102, 'codex-code-mode')
        self.argv[104] = ['/release/codex-code-mode-host']
        self.exes[104] = Path('/release/codex-code-mode-host')
        self.assertEqual(self.busy(), [])
        self.rows[105] = (104, 'bash')
        self.argv[105] = ['/bin/bash', '-c', 'background job']
        self.exes[105] = Path('/bin/bash')
        self.assertEqual(self.busy(), [105])
        self.exes[104] = Path('/other/codex-code-mode-host')
        self.assertIn(104, self.busy())

    def test_bg_unknown_retains_codex(self):
        # Exercise the actual shell consumer: rc 2 is NOT an idle verdict.
        script = '''. "$1/fleet-lib.sh"
_fleet_tmux() { printf 'codex\\n'; }
python3() { return 2; }
fleet_window_bg_busy fleet @1 1
'''
        r = subprocess.run(['bash', '-c', script, '_', str(BIN)], capture_output=True,
                           env=dict(os.environ, FLEET_SKIP_GLOBAL_CONF='1',
                                    FLEET_CONF_DIR=str(self.root), TMUX='isolated,1,0'))
        self.assertEqual(r.returncode, 0, r.stderr.decode())


if __name__ == '__main__':
    unittest.main()
