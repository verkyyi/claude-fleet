#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('warm', BIN / 'fleet-codex-warm.py')
warm = importlib.util.module_from_spec(spec); spec.loader.exec_module(warm)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='codex-policy-'); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name); install = self.root / 'install'; self.bin = install / 'bin'; self.bin.mkdir(parents=True)
        for name in ('fleet-claude.sh', 'fleet-codex.sh', 'fleet-lib.sh', 'fleet-codex-policy.py', 'fleet-codex-runtime.py', 'fleet-hooks-emit.sh'):
            shutil.copy2(BIN / name, self.bin / name)
        shutil.copytree(BIN.parent / 'hooks', install / 'hooks')
        fake = self.root / 'fake'; fake.mkdir(); self.home = self.root / "account home's directory"; self.home.mkdir()
        codex = fake / 'codex'
        codex.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['TEST_ROOT']);args=sys.argv[1:]
if 'mcp' in args:
 (root/'enumerated.json').write_text(json.dumps(args))
 if os.environ.get('ENUM_FAIL'):sys.exit(1)
 print(json.dumps([{'name':'legacy','transport':{'type':'stdio','command':'fixture-server','env':{'TOKEN':'secret-fixture'}}},{'name':'other.server','transport':{'type':'streamable_http','url':'https://example.invalid/mcp','http_headers':{'Authorization':'secret-fixture'}}}]))
else:
 (root/'launched.json').write_text(json.dumps({'args':args,'home':os.environ.get('CODEX_HOME')}))
'''); codex.chmod(0o755)
        self.env = dict(os.environ, PATH=str(fake)+':'+os.environ['PATH'], HOME=str(self.root),
                        FLEET_CONF_DIR=str(self.root/'conf'), TEST_ROOT=str(self.root), FLEET_CODEX_HOME=str(self.home))
        for key in ('TMUX', 'TMUX_PANE', 'FLEET_LOOP_SPEC', 'CODEX_HOME'):
            self.env.pop(key, None)

    def launch(self, *args, **settings):
        return subprocess.run(['bash', str(self.bin/'fleet-codex.sh'), *args],
                              env=dict(self.env, **settings), text=True, capture_output=True)

    def test_pool_launcher_uses_owning_fleet_overlay(self):
        config = self.root/'conf/fleets/tf/conf'; config.parent.mkdir(parents=True)
        config.write_text('FLEET_AGENT=codex\nFLEET_CODEX_MODEL=native-worker\nFLEET_MCP_CONFIG=none\n')
        tmux = self.root/'fake/tmux'
        tmux.write_text('#!/bin/sh\ncase "$*" in *session_name*) echo tf-pool;; esac\n')
        tmux.chmod(0o755)
        p = subprocess.run(['bash', str(self.bin/'fleet-claude.sh'), 'seed'], text=True, capture_output=True,
                           env=dict(self.env, TMUX='isolated,0,0', TMUX_PANE='%1', FLEET_LAUNCH_SESSION='tf', FLEET_CODEX_SERVER='0'))
        self.assertEqual(p.returncode, 0, p.stderr)
        args = json.loads((self.root/'launched.json').read_text())['args']
        self.assertIn('native-worker', args)
        self.assertIn('agents.default_subagent_model="native-worker"', args)
        self.assertIn('features.apps=false', args)

    def test_none_is_strict_and_subagents_use_native_keys(self):
        p = self.launch('seed', FLEET_MCP_CONFIG='none', FLEET_CODEX_SUBAGENT_MODEL='native-model', FLEET_CODEX_SUBAGENT_EFFORT='high')
        self.assertEqual(p.returncode, 0, p.stderr)
        result = json.loads((self.root/'launched.json').read_text()); args = result['args']
        self.assertEqual(result['home'], str(self.home))
        for value in ('features.apps=false', 'agents.default_subagent_model="native-model"',
                      'agents.default_subagent_reasoning_effort="high"'):
            self.assertIn(value, args)
        self.assertIn('mcp_servers={"legacy"={"command"="fixture-server","enabled"=false},"other.server"={"url"="https://example.invalid/mcp","enabled"=false}}', args)
        self.assertNotIn('secret-fixture', '\n'.join(args))
        self.assertEqual(args[-1], 'seed'); self.assertNotIn('--mcp-config', args)

    def test_shipped_worker_set_inherited_by_codex(self):
        # issue #1078: FLEET_MCP_CONFIG -> the shipped conf/mcp-worker.json, with no
        # Codex-specific key, must trim a Codex worker to the same (empty) set:
        # every enumerated server disabled, apps + skill MCP installs closed.
        path = BIN.parent / 'conf' / 'mcp-worker.json'
        self.assertTrue(path.is_file(), path)
        p = self.launch('seed', FLEET_MCP_CONFIG=str(path))
        self.assertEqual(p.returncode, 0, p.stderr)
        args = json.loads((self.root/'launched.json').read_text())['args']
        self.assertIn('features.apps=false', args)
        self.assertIn('features.skill_mcp_dependency_install=false', args)
        self.assertIn('mcp_servers={"legacy"={"command"="fixture-server","enabled"=false},"other.server"={"url"="https://example.invalid/mcp","enabled"=false}}', args)
        self.assertEqual(args[-1], 'seed'); self.assertNotIn('--mcp-config', args)

    def test_shared_allowlist_and_explicit_caller_override(self):
        value = json.dumps({'mcpServers': {'docs': {'type': 'http', 'url': 'https://example.invalid/mcp', 'headers': {'X-Test': 'fixture'}}}})
        override = 'mcp_servers.legacy.enabled=true'
        p = self.launch('-c', override, 'seed', FLEET_MCP_CONFIG=value)
        self.assertEqual(p.returncode, 0, p.stderr)
        args = json.loads((self.root/'launched.json').read_text())['args']
        policy = next(x for x in args if x.startswith('mcp_servers='))
        self.assertIn('"http_headers"={"X-Test"="fixture"}', policy)
        self.assertGreater(args.index(override), args.index(policy))
        self.assertIn(override, json.loads((self.root/'enumerated.json').read_text()))

    def test_explicit_codex_policy_and_recorded_home_win(self):
        home = self.root/'saved home'; home.mkdir()
        p = self.launch('--codex-home', str(home), 'seed', FLEET_MCP_CONFIG='none', FLEET_CODEX_MCP_CONFIG='', FLEET_CODEX_SUBAGENT_MODEL='inherit')
        self.assertEqual(p.returncode, 0, p.stderr)
        data = json.loads((self.root/'launched.json').read_text())
        self.assertEqual(data['home'], str(home)); self.assertFalse((self.root/'enumerated.json').exists())
        self.assertFalse(any('default_subagent_model' in x for x in data['args']))

    def test_bad_policy_and_failed_enumeration_never_launch(self):
        for value, extra in [('none', {'ENUM_FAIL':'1'}), ('{"mcpServers":{"bad":{"type":"sse","url":"fixture"}}}', {}), ('{"unrecognised":{}}', {})]:
            p = self.launch('seed', FLEET_CODEX_MCP_CONFIG=value, **extra)
            self.assertEqual(p.returncode, 2, p.stderr)
            self.assertFalse((self.root/'launched.json').exists())

    def test_native_toml_policy_preserves_native_fields(self):
        try: import tomllib  # noqa: F401
        except ImportError: self.skipTest('native TOML policy requires Python 3.11')
        path = self.root/'policy.toml'
        path.write_text('[mcp_servers.docs]\ncommand="fixture-server"\nargs=["$(not-a-shell)"]\nenv_vars=["FIXTURE_TOKEN"]\nstartup_timeout_sec=4.5\n')
        p = self.launch('seed', FLEET_CODEX_MCP_CONFIG=str(path))
        self.assertEqual(p.returncode, 0, p.stderr)
        args = json.loads((self.root/'launched.json').read_text())['args']
        policy = next(x for x in args if x.startswith('mcp_servers='))
        self.assertIn('"env_vars"=["FIXTURE_TOKEN"]', policy)
        self.assertIn('"args"=["$(not-a-shell)"]', policy)


class WarmTests(unittest.TestCase):
    def probe(self, echo=True, clear=True, menu=False, shell=False, replace=False):
        calls = []; now = [0]; state = ['empty']; reads = [0]
        def clock(): now[0] += .25; return now[0]
        def tm(args, **_):
            calls.append(args); command = args[3]
            if command == 'display-message':
                reads[0] += 1
                owner = os.getpid()+10000000 if replace and reads[0]>2 else os.getpid()
                x = 3 if state[0]=='typed' else 2
                return f'codex|{owner}|0|{"bash" if shell else "codex"}|{x}|0|0|'.encode()
            if command == 'capture-pane':
                text = '1. Yes, continue' if menu else '~' if state[0]=='typed' else '\x1b[2mAsk Codex to do anything\x1b[0m'
                return ('› '+text+'\n').encode()
            if command == 'send-keys':
                if args[-1]=='~' and echo:state[0]='typed'
                if args[-1]=='C-u' and clear:state[0]='empty'
                return b''
            raise AssertionError(args)
        with patch.object(warm, 'has_agent', return_value=False), patch.object(warm.subprocess, 'check_output', side_effect=tm), patch.object(warm.time, 'monotonic', side_effect=clock), patch.object(warm.time, 'sleep'):
            result = warm.warm('isolated', '%1', timeout=5, settle=0, hits=1)
        return result, [args for args in calls if args[3]=='send-keys']

    def test_echo_and_clear_without_submitting(self):
        ok, calls = self.probe(); self.assertTrue(ok)
        self.assertEqual([a[-1] for a in calls], ['~','C-u'])

    def test_unresponsive_or_uncleared_input_is_not_ready(self):
        self.assertFalse(self.probe(echo=False)[0]); self.assertFalse(self.probe(clear=False)[0])

    def test_trust_dialog_and_leftover_shell_receive_no_keys(self):
        for kw in ({'menu':True},{'shell':True}):
            ok, calls = self.probe(**kw); self.assertFalse(ok); self.assertEqual(calls, [])

    def test_replacement_launcher_is_refused(self):
        with self.assertRaisesRegex(ValueError, 'changed'): self.probe(replace=True)


unittest.main(verbosity=2)
