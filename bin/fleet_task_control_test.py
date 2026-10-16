#!/usr/bin/env python3
"""Isolated fixtures. Every external command/network road is denied or recorded."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import fleet_task_control as control


class TaskControlTests(unittest.TestCase):
    def test_unknown_does_not_become_done(self):
        self.assertEqual(control.verdict(None), "UNKNOWN")
        self.assertEqual(control.verdict(dict(state="running", outcome="")), "WAITING")
        self.assertEqual(control.verdict(dict(state="succeeded", outcome="succeeded")), "SUCCEEDED")
        self.assertEqual(control.verdict(dict(state="done", outcome="")), "WAITING")

    def test_await_unavailable_and_deadline(self):
        with patch.object(control, "call", side_effect=ValueError("offline")), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.wait_task("T7", 1, 1), 3)
        self.assertIn("UNKNOWN", out.getvalue())
        with patch.object(control, "call", return_value={"task": dict(id="T7", authority_version=1, generation=4, state="running")}), patch.object(control.time, "monotonic", side_effect=[0, 0, 2]), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.wait_task("T7", 1, 1), 3)
        self.assertIn("WAITING", out.getvalue())
        self.assertIn("generation: 4", out.getvalue())

    def test_shell_await_and_children_with_all_github_access_denied(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); conf = root / "conf"; conf.mkdir()
            (conf / "node.env").write_text("CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fixture\n")
            stub = root / "hub"
            stub.write_text("#!" + sys.executable + "\n" + '''import json,os,sys
from pathlib import Path
sys.stdin.read()
url=sys.argv[-1]
with open(os.environ["CALL_LOG"],"a") as f: f.write(url+"\\n")
if not url.startswith("https://hub.test/"): sys.exit(90)
if os.environ.get("OFFLINE"): sys.exit(7)
t=dict(id="T7",authority_version=1,generation=2,execution_owner="fleet/session",state="succeeded",outcome="succeeded")
if url.endswith("/children"): print(json.dumps(dict(parent="T7",parent_generation=2,children=[t])))
else: print(json.dumps(dict(task=t)))
print("200")
''')
            stub.chmod(0o700)
            for tool in ("gh", "curl"):
                f = root / tool
                f.write_text('#!/bin/sh\necho denied >> "$DENY_LOG"\nexit 91\n'); f.chmod(0o700)
            env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ["PATH"], FLEET_CONF_DIR=str(conf),
                       FLEET_SKIP_GLOBAL_CONF="1", FLEET_HUB_CURL=str(stub), CALL_LOG=str(root/"calls"), DENY_LOG=str(root/"denied"))
            for key in ("TMUX", "TMUX_PANE", "FLEET_SESSION", "FLEET_LAUNCH_CONTEXT"):
                env.pop(key, None)
            result = subprocess.run(["bash", str(control.BIN/"fleet-await.sh"), "T7", "--timeout", "1", "--no-spawn"], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn("SUCCEEDED", result.stdout)
            result = subprocess.run(["bash", str(control.BIN/"fleet-children.sh"), "T7", "--json"], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertEqual(len(json.loads(result.stdout)["children"]), 1)
            result = subprocess.run(["bash", str(control.BIN/"fleet-await.sh"), "T7", "--timeout", "1"], env=dict(env, OFFLINE="1"), capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 3, result.stdout+result.stderr)
            self.assertIn("UNKNOWN", result.stdout)
            self.assertFalse((root/"denied").exists(), "GitHub/default HTTP was attempted")
            self.assertTrue(all(url.startswith("https://hub.test/") for url in (root/"calls").read_text().splitlines()))
            print("fixture shell: gh=0, GitHub HTTP=0; T7 success, children=1, outage UNKNOWN")

    def test_receive_duplicate_reconnect_and_parent_generation(self):
        with tempfile.TemporaryDirectory() as temp:
            r = dict(task="T8", owner="alice", generation=1, worker_id="child/session", ticket_ref="gh:two/repo#7",
                     parent_task="T7", parent_session="parent/session", parent_generation=2,
                     outcome="succeeded", evidence="fixture stop", execution_stopped=True, event_id="done", summary="done")
            t = dict(id="T8", owner="alice", generation=1, execution_owner="child/session", outcome="succeeded")
            parent = dict(id="T7", owner="alice", generation=2, execution_owner="parent/session")
            f = Path(temp)/"relay.json"
            f.write_text(json.dumps(dict(id="child/session#done", **{"from":"child/session", "to":"parent/session"}, payload=dict(task_report=r))))
            sends = []
            def run(args, **kwargs):
                if args[-2:] == [str(control.BIN), "parent/session"]:
                    return subprocess.CompletedProcess(args,0,"socket\n@7\n"+temp+"\n","")
                sends.append(kwargs.get("input")); return subprocess.CompletedProcess(args,0,"","")
            def call(action, task, *args, **kwargs):
                return dict(task=parent if task == "T7" else t)
            with patch.object(control,"call",side_effect=call), patch.object(control,"context",return_value=dict(task="T7", generation=2, worker_id="parent/session")), patch.object(control.launch,"inspect",return_value=dict(actual_provider="codex")), patch.object(control.subprocess,"run",side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(control.receive(f),0)
                self.assertEqual(control.receive(f),0)  # lost acknowledgement/reconnect
                parent["generation"]=3
                with patch.dict(os.environ, {"FLEET_CONF_DIR":temp}):
                    self.assertEqual(control.receive(f),0)
            self.assertEqual(len(sends),1)
            self.assertEqual(len((Path(temp)/"T7-g2.ndjson").read_text().splitlines()),1)
            self.assertTrue((Path(temp)/"global/orphan-reports.ndjson").exists())
            print("fixture report: event=done, reconnect rows=1, deliveries=1; parent g3 rejected")

    def test_native_alive_cannot_ack_cancel(self):
        c=dict(task="T7",owner="alice",generation=1,worker_id="fleet/session")
        t=dict(id="T7",owner="alice",generation=1,execution_owner="fleet/session",cancel_request="stop")
        proof=dict(pid=123,birth="one",executable="/native",native_session="sid")
        with patch.object(control,"context",return_value=c), patch.object(control,"call",side_effect=[dict(task=t),dict(report=None)]) as calls, patch.object(control.launch,"option",side_effect=["",json.dumps(proof)]), patch.object(control.launch,"check_receipt",return_value=proof), patch.object(control.os,"kill"), patch.object(control.launch,"process",return_value=proof):
            with self.assertRaisesRegex(ValueError,"still alive"):
                control.finalize("@7")
            self.assertEqual(calls.call_count,2)


if __name__ == "__main__":
    unittest.main()
