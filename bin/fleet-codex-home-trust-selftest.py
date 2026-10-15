#!/usr/bin/env python3
"""Sandbox HOME pre-trust, symlink durability and explicit choices (#3029)."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import runpy
from unittest.mock import patch

BIN=Path(__file__).resolve().parent


class HomeTrustTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home=Path(self.temp.name)/'home'; self.home.mkdir(); self.home=self.home.resolve()
        self.config=self.home/'.codex/config.toml'; self.config.parent.mkdir()
        self.conf=Path(self.temp.name)/'conf'; (self.conf/'cred-proxy').mkdir(parents=True)
        (self.conf/'cred-proxy/trust.json').write_text(json.dumps(dict(trust='trusted',ts=time.time())))
        self.env=dict(os.environ,HOME=str(self.home),CODEX_HOME=str(self.config.parent),FLEET_CONF_DIR=str(self.conf),FLEET_PRETRUST='1')
    def run_trust(self,*args):
        return subprocess.run(['sh',str(BIN/'fleet-trust.sh'),*args],env=self.env,text=True,capture_output=True)
    def test_missing_entry_preflight_and_durable_symlink(self):
        proxy=self.home/'proxy'; proxy.mkdir()
        (proxy/'config.toml').symlink_to(self.config)
        self.env['CODEX_HOME']=str(proxy)
        r=self.run_trust('codex-ready','--home')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse(self.config.exists())
        r=self.run_trust('codex-ready','--home','--apply')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue((proxy/'config.toml').is_symlink())
        self.assertTrue(self.config.exists())
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        proxy2=self.home/'next-proxy'; proxy2.mkdir()
        (proxy2/'config.toml').symlink_to(self.config)
        self.env['CODEX_HOME']=str(proxy2)
        self.assertEqual(self.run_trust('codex-ready','--home').returncode,0)
        before=self.config.stat().st_mtime_ns
        self.assertEqual(self.run_trust('codex-grant','--home').returncode,0)
        self.assertEqual(before,self.config.stat().st_mtime_ns)
    def test_single_quotes_untrusted_optout_unknown(self):
        self.config.write_text("model = 'keep'\n[projects.'%s']\ntrust_level = 'untrusted'\n" % self.home)
        self.config.chmod(0o640)
        before=self.config.read_bytes()
        self.assertNotEqual(self.run_trust('codex-ready','--home','--apply').returncode,0)
        self.assertEqual(self.config.read_bytes(),before)

    def test_fresh_home_and_untrusted_node(self):
        self.config.parent.rmdir()
        self.assertEqual(self.run_trust('codex-ready','--home').returncode,0)
        self.assertFalse(self.config.parent.exists())
        (self.conf/'cred-proxy/trust.json').write_text(json.dumps(dict(trust='untrusted',ts=time.time())))
        self.assertNotEqual(self.run_trust('codex-ready','--home','--apply').returncode,0)
        self.assertFalse(self.config.parent.exists())
        (self.conf/'cred-proxy/trust.json').write_text(json.dumps(dict(trust='trusted',ts=time.time())))
        self.assertEqual(self.run_trust('codex-ready','--home','--apply').returncode,0)
        self.assertTrue(self.config.exists())

    def test_concurrent_config_update_preserves_other_settings_and_mode(self):
        ns=runpy.run_path(str(BIN/'fleet_codex_trust.py'))
        self.config.write_text("model = 'first'\n")
        self.config.chmod(0o640)
        real_fsync=os.fsync
        changed=[]
        def update(fd):
            real_fsync(fd)
            if not changed:
                self.config.write_text("model = 'second'\nmodel_reasoning_effort = 'high'\n")
                changed.append(True)
        with patch.object(os,'fsync',side_effect=update):
            ns['grant'](self.config,str(self.home))
        self.assertIn("model = 'second'",self.config.read_text())
        self.assertIn("model_reasoning_effort = 'high'",self.config.read_text())
        self.assertEqual(self.config.stat().st_mode & 0o777,0o640)

    def test_trusted_single_quotes_optout_and_unknown_node(self):
        self.config.write_text("model = 'keep'\n[projects.'%s']\ntrust_level = 'trusted'\n" % self.home)
        self.assertEqual(self.run_trust('codex-ready','--home').returncode,0)
        self.config.write_text("model = 'keep'\n")
        before=self.config.read_bytes()
        self.env['FLEET_PRETRUST']='0'
        self.assertNotEqual(self.run_trust('codex-ready','--home','--apply').returncode,0)
        self.assertEqual(self.config.read_bytes(),before)
        self.env['FLEET_PRETRUST']='1'
        (self.conf/'cred-proxy/trust.json').unlink()
        self.assertNotEqual(self.run_trust('codex-ready','--home','--apply').returncode,0)
        self.assertEqual(self.config.read_bytes(),before)

if __name__=='__main__': unittest.main()
