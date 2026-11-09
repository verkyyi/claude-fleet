#!/usr/bin/env python3
# selftest-entry
"""Hermetic fseventsd leak drill; no signals to host daemons."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("watchdog", BIN / "fleet-fseventsd.py")
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class Watchdog(unittest.TestCase):
    def sample(self, **kw):
        return dict(dict(rss_mb=100, swap_mb=24000, pid=123,
                         compressed_mb=20000, biggest=True), **kw)

    def test_trigger_attribution_and_thresholds(self):
        for sample, expected in [
            (self.sample(rss_mb=1024, swap_mb=0, biggest=False), "rss"),
            (self.sample(), "swap+compressed-holder"),
            (self.sample(biggest=False), ""),
            (self.sample(swap_mb=None), ""),
            (self.sample(swap_mb=8191), ""),
            (self.sample(pid=None), ""),
            (self.sample(rss_mb=None), ""),
        ]:
            self.assertEqual(w.reason(sample, w.DEFAULTS), expected)
        off = dict(w.DEFAULTS, FLEET_FSEVENTSD_RESTART_MB=0, FLEET_FSEVENTSD_SWAP_MB=0)
        self.assertEqual(w.reason(self.sample(rss_mb=5000), off), "")

    def test_macos_parsers_and_unknown_attribution(self):
        self.assertEqual(w.swap_used("total = 24.00G used = 24576.00M free = 0.00M (encrypted)"), 24576)
        self.assertIsNone(w.swap_used("sysctl: permission denied"))
        prefix = "Processes: 10 total\nVM: swapouts\nPID COMMAND CMPRS\n"
        self.assertEqual(w.compressed_holder(prefix + "123 fseventsd 20G\n42 Safari 512M\n", 123), (20480, True))
        for text in ["", "PID COMMAND CMPRS\n123 fseventsd 20G", prefix + "123 fseventsd 0B\n42 Safari 0B",
                     prefix + "123 fseventsd 20G\n42 Safari 20G", prefix + "123 fseventsd 20G\n42 Safari ???"]:
            self.assertFalse(w.compressed_holder(text, 123)[1])

    def test_probe_root_identity_and_only_attribution_when_needed(self):
        ps = "501 42 9000000 /usr/sbin/fseventsd\n0 123 102400 /usr/sbin/fseventsd\n0 456 9000000 /tmp/fseventsd\n"
        def read(argv):
            if argv[0].endswith("sysctl"):
                return "total = 24G used = 24G free = 0B"
            if argv[0].endswith("ps"):
                return ps
            self.assertNotIn("-n", argv)  # macOS top -n 0 prints NO processes
            return "PID COMMAND CMPRS\n123 fseventsd 20G\n42 Safari 1G\n"
        with patch.object(w.platform, "system", return_value="Darwin"), patch.object(w, "run", side_effect=read) as run, \
                patch.object(w, "process_rows", return_value=ps):
            self.assertEqual(w.probe()["rss_mb"], 100)
            self.assertTrue(w.probe()["biggest"])
            run.reset_mock()
            self.assertIsNone(w.probe(0)["compressed_mb"])
            self.assertEqual(run.call_count, 1)
            self.assertIn("system swap 24576 MiB", w.doctor())
        with patch.object(w.platform, "system", return_value="Linux"), patch.object(w, "run") as run:
            self.assertIsNone(w.probe()["rss_mb"])
            run.assert_not_called()

    def test_settings_are_numeric_and_cooldown_cannot_shrink(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            conf = Path(tmp) / "fleet.conf"
            conf.write_text("FLEET_FSEVENTSD_RESTART_MB='2048' # bigger\nFLEET_FSEVENTSD_COOLDOWN=1\nFLEET_FSEVENTSD_SWAP_MB=$(id)\n")
            cfg = w.settings(conf)
            self.assertEqual(cfg["FLEET_FSEVENTSD_RESTART_MB"], 2048)
            self.assertEqual(cfg["FLEET_FSEVENTSD_COOLDOWN"], 3600)
            self.assertEqual(cfg["FLEET_FSEVENTSD_SWAP_MB"], 8192)

    def test_no_signal_when_disabled_unrelated_or_locked(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(w, "restart") as restart, patch.object(w, "alert") as alert:
            state = Path(tmp)
            with patch.object(w, "probe", return_value=self.sample(biggest=False)):
                self.assertEqual(w.tick(state, w.DEFAULTS), "healthy")
            self.assertEqual(w.tick(state, dict(w.DEFAULTS, FLEET_FSEVENTSD_WATCHDOG=0)), "disabled")
            with (state / "lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(w.tick(state, w.DEFAULTS), "busy")
            restart.assert_not_called()
            alert.assert_not_called()

    def test_failed_signal_is_logged_alerted_and_rate_limited(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(w, "probe", return_value=self.sample()), \
             patch.object(w, "restart", side_effect=PermissionError) as restart, patch.object(w, "alert") as alert:
            state = Path(tmp)
            cfg = dict(w.DEFAULTS, FLEET_FSEVENTSD_COOLDOWN=1)
            self.assertEqual(w.tick(state, cfg, now=10000), "failed")
            self.assertEqual(w.tick(state, cfg, now=10001), "cooldown")
            self.assertEqual(json.loads((state / "alert.json").read_text())["result"], "failed")
            restart.assert_called_once()
            alert.assert_called_once()
            (state / "last-attempt.json").write_text("bad json")
            with self.assertRaises(ValueError):
                w.tick(state, cfg, now=20000)
            restart.assert_called_once()

    def test_machine_table_and_seated_core_route(self):
        sys.path.insert(0, str(BIN))
        spec = importlib.util.spec_from_file_location("supervisor", BIN / "fleet-node-supervisor.py")
        sup = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sup)
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"FLEET_NODE_STATE": tmp, "FLEET_NODE_RUNTIME": str(BIN.parent)}):
            paths = sup.Paths()
            with patch.object(sup, "MAC", True):
                tasks = sup.default_table(paths)["tasks"]
            task = next(t for t in tasks if t["name"] == "fseventsd")
            self.assertEqual(task["every"], 60)
            self.assertFalse(task["idle"])
            self.assertEqual(task["env"]["FLEET_NODE_STATE"], tmp)
            supervisor = object.__new__(sup.Supervisor)
            supervisor.seated, supervisor.p = True, paths
            with patch.object(sup.core, "available", return_value=True), patch.object(sup, "trusted", return_value=True):
                cmd = supervisor.core_cmd(task)
            self.assertIn("machine", cmd)
            self.assertIn('{"action": "start", "job": "fseventsd"}', cmd)
            with patch.object(sup, "MAC", False):
                self.assertNotIn("fseventsd", [t["name"] for t in sup.default_table(paths)["tasks"]])

    def test_root_alert_reaches_login_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            node = Path(tmp)
            (node / "fseventsd").mkdir()
            w.write_json(node / "fseventsd" / "alert.json", {"at": 12345.25, "message": "fseventsd restarted"})
            script = '''source "$1/fleet-alerts.sh"
fleet_usage_cache_dir() { printf '%s/cache' "$FLEET_NODE_STATE"; }
fleet_alert() { printf '%s %s\\n' "$1" "$2"; }
_fa_fseventsd
_fa_fseventsd
'''
            env = dict(os.environ, FLEET_NODE_STATE=tmp)
            result = subprocess.run(["/bin/bash", "-uc", script, "test", str(BIN)], env=env,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, "fseventsd fseventsd restarted\n")
            result = subprocess.run(["/bin/bash", "-uc", script, "test", str(BIN)], env=env,
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, "")

    def test_swapped_daemon_restart_and_persistent_cooldown(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            alerts = []
            killed = []
            sample = dict(rss_mb=100, swap_mb=24000, pid=123,
                          compressed_mb=20000, biggest=True)
            # A real disposable process stands in for launchd's daemon. The
            # signal adapter replaces it, as launchd does after TERM.
            child = subprocess.Popen(["/bin/sleep", "60"])
            def restart():
                nonlocal child
                killed.append(child.pid)
                child.terminate()
                child.wait(timeout=5)
                child = subprocess.Popen(["/bin/sleep", "60"])
            try:
                with patch.object(w, "probe", return_value=sample), \
                     patch.object(w, "restart", side_effect=restart), \
                     patch.object(w, "alert", side_effect=alerts.append):
                    self.assertEqual(w.tick(state, w.DEFAULTS, now=10000), "restarted")
                    self.assertNotEqual(child.pid, killed[0])
                    self.assertEqual(w.tick(state, w.DEFAULTS, now=13599), "cooldown")
                    self.assertEqual(len(alerts), 1)
                    self.assertEqual(len((state / "restarts.ndjson").read_text().splitlines()), 1)
                    self.assertEqual(w.tick(state, w.DEFAULTS, now=13600), "restarted")
                    self.assertEqual(len(alerts), 2)
            finally:
                child.terminate()
                child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
