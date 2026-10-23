#!/usr/bin/env python3
# selftest-entry
"""Real tmux snapshots preserve empty columns and use one batch read."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_reap_notice as notice
spec = importlib.util.spec_from_file_location("idle", BIN / "fleet-cleanup-idle.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


@unittest.skipUnless(shutil.which("tmux"), "tmux absent")
class Snapshot(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tmux-snapshot-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {"TMUX_TMPDIR": str(root), "FLEET_CONF_DIR": str(root / "conf")})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.sock = "snapshot-" + str(os.getpid())
        subprocess.run(["tmux", "-L", self.sock, "-f", "/dev/null", "new-session", "-d", "-s", self.sock,
                        "sleep 600"], check=True, timeout=5)
        self.addCleanup(lambda: subprocess.run(["tmux", "-L", self.sock, "kill-server"],
                                              check=True, timeout=5))
        self.tm = notice.tmux(self.sock)
        self.win = self.tm("display-message", "-p", "-t", self.sock, "#{window_id}")

    def set(self, key, value):
        self.tm("set-option", "-w", "-t", self.win, key, value)

    def cleaner(self):
        return idle.Cleaner(argparse.Namespace(socket_name=self.sock, session=self.sock,
                             main="", repo="", base="master", window_repo=False, dry_run=True))

    def test_reader_preserves_empty_columns(self):
        self.set("@probe_value", "middle")
        fmt = "#{@missing_first}\x1f#{@probe_value}\x1f#{@missing_last}"
        self.assertEqual(self.tm("display-message", "-p", "-t", self.win, fmt), "\x1fmiddle\x1f")

    def test_reader_removes_only_its_transport_newline(self):
        self.set("@probe_value", "  first\nsecond \n")
        self.assertEqual(self.tm("display-message", "-p", "-t", self.win, "#{@probe_value}"), "  first\nsecond \n")
        self.assertEqual(self.tm("display-message", "-p", "-t", self.win, "plain"), "plain")
        self.assertEqual(self.tm("display-message", "-p", "-t", self.win, "#{@missing}"), "")

    def test_snapshot_with_empty_edges_is_one_real_batch(self):
        self.set("@claude_state", "done")
        c = self.cleaner()
        with patch.object(c, "tm", wraps=c.tm) as observed:
            snap = c.snapshot(self.win)
        self.assertEqual(observed.call_count, 1)
        self.assertEqual(snap["@raw"], "")
        self.assertEqual(snap["@claude_state"], "done")
        self.assertEqual(snap["@reap_work_pending"], "")

    def test_embedded_separator_still_uses_safe_fallback(self):
        self.set("@repo", "owner/one\x1fpart")
        self.set("@reap_policy", "keep")
        c = self.cleaner()
        with patch.object(c, "tm", wraps=c.tm) as observed:
            snap = c.snapshot(self.win)
        self.assertGreater(observed.call_count, 1)
        self.assertEqual(snap["@repo"], "owner/one\x1fpart")
        self.assertEqual(snap["@reap_policy"], "keep")
        self.assertEqual(snap["@raw"], "")
        self.assertEqual(snap["@reap_work_pending"], "")


if __name__ == "__main__":
    unittest.main()
