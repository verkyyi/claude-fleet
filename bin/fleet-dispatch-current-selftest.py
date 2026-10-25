#!/usr/bin/env python3
"""Cancelled dispatches cannot reach the native launcher through stale input."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import fleet_dispatch as dispatch
import fleet_control as control

BIN = Path(__file__).resolve().parent
ENVELOPE = dict(version=1, request_id="test-start", requested_agent="codex",
                resolved_agent="codex", agent_source="explicit", task="T17",
                generation=1, attempt_id="task:T17:g1")
CURRENT = dict(id="T17", task="T17", authority_version=1, generation=1,
               attempt_id="task:T17:g1", resolved_agent="codex", cancel_request="",
               state="accepted", outcome="")


class DispatchCurrentTests(unittest.TestCase):
    def test_current_and_legacy(self):
        dispatch.check_current(ENVELOPE, read=lambda _: CURRENT)
        legacy = {k: v for k, v in ENVELOPE.items() if k not in ("task", "generation", "attempt_id")}
        dispatch.check_current(legacy, read=lambda _: self.fail("legacy made a hub request"))
        dispatch.check_current(None, read=lambda _: self.fail("legacy made a hub request"))

    def test_revoked_wrong_generation_and_malformed_records(self):
        cases = [dict(CURRENT, generation=2), dict(CURRENT, cancel_request="stop-1"),
                 dict(CURRENT, state="cancelled"), dict(CURRENT, outcome="cancelled"),
                 dict(CURRENT, attempt_id="task:T17:g2"), dict(CURRENT, id="T18", task="T18"),
                 dict(CURRENT, authority_version=0), dict(CURRENT, resolved_agent="claude"), None, {}]
        for record in cases:
            with self.subTest(record=record), self.assertRaises(ValueError):
                dispatch.check_current(ENVELOPE, read=lambda _, r=record: r)

    def test_unavailable_never_becomes_authorized(self):
        with self.assertRaises(ValueError):
            dispatch.check_current(ENVELOPE, read=lambda _: (_ for _ in ()).throw(OSError("unavailable")))

    def test_cancel_after_node_accept_before_executor_never_calls_spawner(self):
        with tempfile.TemporaryDirectory(prefix="dispatch-executor-") as tmp:
            node = control.Control(tmp)
            op_id = "11111111-1111-4111-8111-111111111111"
            request = dict(fleet_id="fixture", action="worker_start", actor="owner",
                           params=dict(kind="scratch", no_repo=True, task="T17", dispatch=ENVELOPE))
            with node.store.connect() as db:
                db.execute("INSERT INTO operations VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)",
                           (op_id, "fixture", "worker_start", json.dumps(request), "owner",
                            "accepted", time.time(), time.time()))
            with patch.object(node, "fleet", return_value={"name": "fixture"}), \
                    patch.object(node, "adapter", side_effect=AssertionError("spawner ran")), \
                    patch.object(dispatch, "read_current", return_value=dict(CURRENT, cancel_request="stop-1")):
                node.execute(op_id)
            with node.store.connect() as db:
                row = db.execute("SELECT status, result FROM operations WHERE id=?", (op_id,)).fetchone()
            self.assertEqual(row["status"], "failed")
            self.assertEqual(json.loads(row["result"])["error"]["code"], "TASK_START_REFUSED")

    def test_wrapper_refuses_cancelled_before_credentials_or_native_start(self):
        # Exercise the actual wrapper and CLI. Only tmux's metadata read and
        # authenticated record transport are replaced; no real fleet is touched.
        with tempfile.TemporaryDirectory(prefix="dispatch-current-") as tmp:
            root = Path(tmp)
            for name in ("fleet-session-wrap.sh", "fleet_dispatch.py"):
                shutil.copy2(BIN / name, root / name)
            (root / "fleet-task-record.sh").write_text(
                '#!/bin/sh\ncat "$FLEET_TEST_RECORD"\n')
            (root / "tmux").write_text(
                '#!/bin/sh\ncase "$*" in *"#{@dispatch}"*) cat "$FLEET_TEST_DISPATCH";; esac\n')
            (root / "tmux").chmod(0o700)
            record = root / "record.json"
            record.write_text(json.dumps({"task": dict(CURRENT, generation=2, cancel_request="stop-1")}))
            envelope = root / "dispatch.json"
            envelope.write_text(json.dumps(ENVELOPE))
            launcher = root / "launch"
            launcher.write_text('#!/bin/sh\ntouch "$FLEET_TEST_STARTED"\n')
            launcher.chmod(0o700)
            env = dict(os.environ, HOME=tmp, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       TMUX="test-only", TMUX_PANE="%1", FLEET_TEST_RECORD=str(record),
                       FLEET_TEST_DISPATCH=str(envelope), FLEET_WRAP_LAUNCH=str(launcher),
                       FLEET_START_DISPATCH=json.dumps(ENVELOPE),
                       FLEET_TEST_STARTED=str(root / "started"), FLEET_CONF_DIR=str(root / "conf"))
            result = subprocess.run(["bash", str(root / "fleet-session-wrap.sh")],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("dispatch", result.stderr.lower())
            self.assertFalse((root / "started").exists())
            self.assertFalse((root / "conf").exists())

    def test_wrapper_rechecks_after_initialization(self):
        with tempfile.TemporaryDirectory(prefix="dispatch-late-") as tmp:
            root = Path(tmp)
            for name in ("fleet-session-wrap.sh", "fleet_dispatch.py", "fleet-agent-adapter.sh"):
                shutil.copy2(BIN / name, root / name)
            reader = root / "fleet-task-record.sh"
            # the cancel lands while the wrapper initialises: its ONE check is the
            # last thing before the launch (T992 — an earlier copy of it went), so
            # the reader already says cancelled when it is asked
            reader.write_text('#!/bin/sh\ntouch "$FLEET_TEST_READ"; cat "$FLEET_TEST_CANCELLED"\n')
            for name, rec in (("current", CURRENT), ("cancelled", dict(CURRENT, cancel_request="stop-1"))):
                (root / (name + ".json")).write_text(json.dumps({"task": rec}))
            launcher = root / "launch"
            launcher.write_text('#!/bin/sh\ntouch "$FLEET_TEST_STARTED"\n')
            launcher.chmod(0o700)
            env = dict(os.environ, HOME=tmp, TMUX="", TMUX_PANE="", FLEET_CRED_PROXY="0", FLEET_MCP="0",
                       FLEET_TEST_READ=str(root / "read"), FLEET_TEST_CURRENT=str(root / "current.json"),
                       FLEET_TEST_CANCELLED=str(root / "cancelled.json"), FLEET_WRAP_LAUNCH=str(launcher),
                       FLEET_START_DISPATCH=json.dumps(ENVELOPE), FLEET_TEST_STARTED=str(root / "started"),
                       FLEET_CONF_DIR=str(root / "conf"))
            result = subprocess.run(["bash", str(root / "fleet-session-wrap.sh")], env=env,
                                    capture_output=True, text=True, timeout=15)
            self.assertTrue((root / "read").exists(), result.stderr)
            self.assertFalse((root / "started").exists(), result.stderr)
            self.assertIn("authorization changed or cancelled", result.stderr)


if __name__ == "__main__":
    unittest.main()
