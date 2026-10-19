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

    def test_closed_is_one_read_never_a_wait(self):
        # issue #4897: the reapers' reader — terminal ⇒ 0, open ⇒ 1, unknown ⇒ 3.
        for outcome, rc, word in (("succeeded", 0, "SUCCEEDED"), ("failed", 0, "FAILED"),
                                  ("cancelled", 0, "CANCELLED"), ("", 1, "WAITING")):
            t = dict(id="T7", authority_version=1, generation=1, state="running", outcome=outcome)
            with patch.object(control, "call", return_value={"task": t}) as calls, \
                 contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(control.closed("T7"), rc)
            self.assertEqual(calls.call_count, 1)
            self.assertTrue(out.getvalue().startswith(word + "\n"), out.getvalue())
        for answer in (ValueError("offline"), {"task": dict(id="T7", state="open")}):
            kw = dict(side_effect=answer) if isinstance(answer, Exception) else dict(return_value=answer)
            with patch.object(control, "call", **kw), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(control.closed("T7"), 3)
            self.assertTrue(out.getvalue().startswith("UNKNOWN\n"))

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
                f.write_text('#!/bin/sh\necho denied >> "$DENY_LOG.'+tool+'"\nexit 91\n'); f.chmod(0o700)
            env = dict(os.environ, PATH=str(root)+os.pathsep+os.environ["PATH"], FLEET_CONF_DIR=str(conf),
                       FLEET_SKIP_GLOBAL_CONF="1", FLEET_HUB_CURL=str(stub), CALL_LOG=str(root/"calls"), DENY_LOG=str(root/"denied"))
            for key in ("TMUX", "TMUX_PANE", "FLEET_SESSION", "FLEET_LAUNCH_CONTEXT"):
                env.pop(key, None)
            # the read itself (bash + the stub) is ~1 s on a busy runner, and await's
            # timeout bounds that read too: room for it — the verdict is the point (#4570)
            result = subprocess.run(["bash", str(control.BIN/"fleet-await.sh"), "T7", "--timeout", "10", "--no-spawn"], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn("SUCCEEDED", result.stdout)
            result = subprocess.run(["bash", str(control.BIN/"fleet-children.sh"), "T7", "--json"], env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertEqual(len(json.loads(result.stdout)["children"]), 1)
            result = subprocess.run(["bash", str(control.BIN/"fleet-await.sh"), "T7", "--timeout", "1"], env=dict(env, OFFLINE="1"), capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 3, result.stdout+result.stderr)
            self.assertIn("UNKNOWN", result.stdout)
            for tool in ("gh", "curl"):
                self.assertFalse((root/("denied."+tool)).exists(), tool+" was attempted")
            self.assertTrue(all(url.startswith("https://hub.test/") for url in (root/"calls").read_text().splitlines()))
            print("fixture shell: gh=0, GitHub HTTP=0; T7 success, children=1, outage UNKNOWN")

    def test_receive_duplicate_reconnect_and_parent_generation(self):
        with tempfile.TemporaryDirectory() as temp:
            r = dict(task="T8", owner="alice", generation=1, worker_id="child/session", ticket_ref="gh:two/repo#7",
                     parent_task="T7", parent_session="parent/session", parent_generation=2,
                     outcome="succeeded", evidence="fixture stop", execution_stopped=True, event_id="done", summary="done")
            t = dict(id="T8", owner="alice", generation=1, execution_owner="child/session", outcome="succeeded", **{k:r[k] for k in ("ticket_ref","parent_task","parent_session","parent_generation")})
            parent = dict(id="T7", owner="alice", generation=2, execution_owner="parent/session")
            f = Path(temp)/"relay.json"
            f.write_text(json.dumps(dict(id="child/session#done", **{"from":"child/session", "to":"parent/session"}, payload=dict(task_report=r))))
            sends = []
            def run(args, **kwargs):
                if args[-2:] == [str(control.BIN), "parent/session"]:
                    return subprocess.CompletedProcess(args,0,"socket\n@7\n"+temp+"\n","")
                self.assertEqual(json.loads(kwargs["env"]["FLEET_LAUNCH_CONTEXT"]), dict(task="T7", generation=2, worker_id="parent/session"))
                self.assertEqual(json.loads(kwargs["env"]["FLEET_LAUNCH_DELIVERY"]), dict(actual_provider="codex"))
                sends.append(kwargs.get("input")); return subprocess.CompletedProcess(args,0,"","")
            def call(action, task, *args, **kwargs):
                return dict(task=parent if task == "T7" else t)
            with patch.object(control,"call",side_effect=call), patch.object(control,"context",return_value=dict(task="T7", generation=2, worker_id="parent/session")), patch.object(control.launch,"inspect",return_value=dict(actual_provider="codex")), patch.object(control.subprocess,"run",side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(control.receive(f),0)
                self.assertEqual(control.receive(f),0)  # lost acknowledgement/reconnect
                envelope = json.loads(f.read_text()); envelope["id"] += "-different-transport"
                f.write_text(json.dumps(envelope))
                self.assertEqual(control.receive(f),0)  # event identity beats transport ID
                with patch.object(control.subprocess, "run", return_value=subprocess.CompletedProcess([],75,"","")), patch.object(control,"orphan") as orphan:
                    self.assertEqual(control.receive(f),75)
                    orphan.assert_not_called()  # unobservable/ambiguous is not retired
                with patch.object(control.subprocess, "run", return_value=subprocess.CompletedProcess([],76,"","")), patch.object(control,"orphan") as orphan:
                    self.assertEqual(control.receive(f),0)
                    orphan.assert_called_once()  # known absent stable identity
                parent["generation"]=3
                with patch.dict(os.environ, {"FLEET_CONF_DIR":temp}):
                    self.assertEqual(control.receive(f),0)
            self.assertEqual(len(sends),1)
            self.assertEqual(len((Path(temp)/"T7-g2.ndjson").read_text().splitlines()),1)
            self.assertTrue((Path(temp)/"global/orphan-reports.ndjson").exists())
            print("fixture report: event=done, reconnect rows=1, deliveries=1; parent g3 rejected")

    def test_completion_report_delivered_and_awaited_with_retained_native(self):
        # The native fixture really remains alive across explicit report ->
        # existing outbox -> await. Hub transaction/relay fencing is covered by
        # the matching store/API tests; no PR/GitHub or exit inference here.
        native = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            for outcome in ("succeeded", "failed"):
                c = dict(task="T8", owner="alice", generation=1, worker_id="child/session")
                t = dict(id="T8", authority_version=1, owner="alice", generation=1,
                         execution_owner="child/session", parent_session="parent/session")
                proof = dict(native_session="retained", actual_provider="codex", pid=native.pid)
                reports = []
                def call(action, task, payload=None, **kwargs):
                    if action == "get": return dict(task=t)
                    self.assertEqual(action, "report")
                    self.assertFalse(payload["execution_stopped"])
                    reports.append(payload)
                    t["outcome"] = payload["outcome"]
                    return dict(disposition="committed", task=t)
                with patch.object(control, "context", return_value=c), patch.object(control, "call", side_effect=call), patch.object(control.launch, "option", return_value=json.dumps(proof)), patch.object(control.launch, "check_receipt", return_value=proof), patch.object(control.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as delivery, contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(control.report("@8", "waiting", "Explicit work result", "", False, outcome=outcome), 3)
                    self.assertEqual(control.wait_task("T8", 1, 1), 0 if outcome == "succeeded" else 1)
                    self.assertIsNone(native.poll(), "completion killed native session")
                    self.assertEqual(json.loads(delivery.call_args.kwargs["input"])["task_report"], reports[0])
                    self.assertIn(outcome.upper(), out.getvalue())
                print("fixture retained native: report %s committed, delivery queued, await %s, process alive" % (outcome, outcome.upper()))
        finally:
            native.terminate()
            native.wait(timeout=5)

    def test_epic_parent_progress_is_recorded_never_relayed(self):
        # issue #4957: an EPIC driver's tick is a progress report on its OWN
        # (parent) task — one hub write, no child report, no GitHub.
        c = dict(task="T7", owner="alice", generation=2, worker_id="parent/session")
        t = dict(id="T7", authority_version=1, owner="alice", generation=2, execution_owner="parent/session",
                 parent_session="orch/session")
        writes = []
        def call(action, task, payload=None, **kwargs):
            if action == "get": return dict(task=t)
            writes.append((action, payload)); return dict(disposition="progress", task=t)
        with patch.object(control, "context", return_value=c), patch.object(control, "call", side_effect=call), \
             patch.object(control.subprocess, "run") as relay, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.progress("@7", "tick 3 · landed C1", "waiting", "tick-3"), 0)
            relay.assert_not_called()
        self.assertEqual(len(writes), 1)
        action, r = writes[0]
        self.assertEqual((action, r["status"], r["outcome"], r["summary"], r["event_id"]), ("report", "waiting", "", "tick 3 · landed C1", "tick-3"))
        self.assertIn("RECORDED", out.getvalue())
        t["outcome"] = "succeeded"   # a closed parent takes no more ticks
        with patch.object(control, "context", return_value=c), patch.object(control, "call", side_effect=call), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(control.progress("@7", "late", "waiting"), 0)
        self.assertEqual(len(writes), 1)
        with patch.object(control, "context", return_value=c), self.assertRaises(ValueError):
            control.progress("@7", "  ", "waiting")

    def test_children_summary_counts_outcomes(self):
        kids = [dict(outcome="succeeded"), dict(outcome="failed"), dict(outcome=""), dict()]
        self.assertEqual(control.child_summary(dict(children=kids)),
                         dict(open=2, succeeded=1, failed=1, cancelled=0, refused=0))
        hub = dict(open=0, succeeded=2, failed=0, cancelled=0, refused=0)
        self.assertEqual(control.child_summary(dict(children=kids, summary=hub)), hub)

    def test_stop_ack_does_not_republish_completed_work(self):
        c = dict(task="T7", owner="alice", generation=1, worker_id="fleet/session")
        t = dict(c, execution_owner="fleet/session", outcome="succeeded", cancel_request="stop")
        proof = dict(pid=123, birth="one", executable="/native", native_session="sid")
        with patch.object(control, "context", return_value=c), patch.object(control, "call", side_effect=[dict(task=t),t]) as calls, patch.object(control.launch, "option", return_value=json.dumps(proof)), patch.object(control.launch, "check_receipt", return_value=proof), patch.object(control.os, "kill", side_effect=ProcessLookupError):
            self.assertEqual(control.finalize("@7"), 0)
            self.assertEqual(calls.call_args.args[0], "stopped")
            self.assertTrue(calls.call_args.args[2]["execution_stopped"])
            self.assertNotIn("state", calls.call_args.args[2])

    def test_native_alive_cannot_ack_cancel(self):
        c=dict(task="T7",owner="alice",generation=1,worker_id="fleet/session")
        t=dict(id="T7",owner="alice",generation=1,execution_owner="fleet/session",cancel_request="stop")
        proof=dict(pid=123,birth="one",executable="/native",native_session="sid")
        with patch.object(control,"context",return_value=c), patch.object(control,"call",return_value=dict(task=t)) as calls, patch.object(control.launch,"option",return_value=json.dumps(proof)), patch.object(control.launch,"check_receipt",return_value=proof), patch.object(control.os,"kill"), patch.object(control.launch,"process",return_value=proof):
            with self.assertRaisesRegex(ValueError,"still alive"):
                control.finalize("@7")
            self.assertEqual(calls.call_count,1)


if __name__ == "__main__":
    unittest.main()
