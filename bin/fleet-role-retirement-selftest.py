#!/usr/bin/env python3
# selftest-entry
"""D1: old role entrypoints refuse before resolution; upgrades preserve user files."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / 'bin'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class Retirement(unittest.TestCase):
    def test_retired_role_has_distinct_hard_failure(self):
        with tempfile.TemporaryDirectory() as work:
            env = dict(os.environ, HOME=work, CLAUDE_CONFIG_DIR=work + '/cc', FLEET_CONF_DIR=work + '/conf',
                       FLEET_AGENT_PLUGINS_CMD='false')
            for name in ('orchestrator', 'steward', 'epic-driver', 'fleet-epic:epic-driver'):
                for command in ('launch', 'spawn-tools', 'check-role'):
                    result = subprocess.run(['python3', str(BIN / 'fleet-agent-def.py'), command, name, '--dir', work],
                                            text=True, capture_output=True, env=env)
                    self.assertEqual(result.returncode, 3, (name, command, result.stderr))
                    self.assertIn('ROLE_RETIRED', result.stderr)
                    self.assertEqual(result.stdout, '')

    def test_plain_custom_role_check_needs_no_plugin_or_file(self):
        result = subprocess.run(['python3', str(BIN / 'fleet-agent-def.py'), 'check-role', 'my-reviewer'],
                                capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))

    def test_upgrade_retires_untouched_role_but_keeps_user_edit(self):
        for edited in (False, True):
            with self.subTest(edited=edited), tempfile.TemporaryDirectory() as work:
                root = Path(work)
                cc, conf = root / 'cc', root / 'conf'
                (cc / 'agents').mkdir(parents=True)
                conf.mkdir()
                original = b'---\nname: orchestrator\n---\nold platform instructions\n'
                role = cc / 'agents/orchestrator.md'
                role.write_bytes(original + (b'personal override\n' if edited else b''))
                (conf / 'agents-shipped.json').write_text(json.dumps({'orchestrator': hashlib.sha256(original).hexdigest()}))
                env = dict(os.environ, HOME=work, CLAUDE_CONFIG_DIR=str(cc), FLEET_CONF_DIR=str(conf))
                result = subprocess.run(['python3', str(BIN / 'fleet-agent-def.py'), 'ship'], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(role.exists(), edited)
                if edited:
                    self.assertEqual(role.read_bytes(), original + b'personal override\n')
                self.assertTrue((cc / 'agents/fleet-worker.md').is_file())
                again = subprocess.run(['python3', str(BIN / 'fleet-agent-def.py'), 'ship'], env=env,
                                       capture_output=True, text=True)
                self.assertNotIn('wrote', again.stdout)
                self.assertEqual(role.exists(), edited)

    def test_epic_carryover_never_reinstalls_retired_automation(self):
        plugs = module('retired_plugins', BIN / 'fleet-plugins.py')
        with tempfile.TemporaryDirectory() as work:
            cc = Path(work)
            (cc / 'agents').mkdir()
            (cc / 'commands').mkdir()
            (cc / 'agents/epic-driver.md').write_text('old driver')
            (cc / 'commands/fleet-epic-run.md').write_text('old command')
            gone = ['conf/agent-defaults/claude/agents/epic-driver.md', 'commands/fleet-epic-run.md']
            self.assertEqual(plugs.carried(str(ROOT), {'fleet-epic': 'plugins/fleet-epic'}, gone, str(cc)), [])


if __name__ == '__main__':
    unittest.main()
