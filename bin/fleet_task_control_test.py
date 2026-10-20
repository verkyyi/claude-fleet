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
t=dict(id="T7",authority_version=1,generation=2,state="succeeded",outcome="succeeded")
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

    def test_receive_duplicate_reconnect_and_parent_id(self):
        # EPIC T497 C4: the parent is its session's ID. A new parent generation (a
        # re-launch) or a /clear does not retire it; only a closed ID with nobody to
        # take over (77) or an ID its fleet does not know (76) goes to the person.
        with tempfile.TemporaryDirectory() as temp:
            r = dict(task="T8", owner="alice", generation=1, worker_id="child/session", ticket_ref="gh:two/repo#7",
                     parent_task="T7", parent_session="parent/session", parent_generation=2,
                     outcome="succeeded", evidence="fixture stop", execution_stopped=True, event_id="done", summary="done")
            t = dict(id="T8", owner="alice", generation=1, outcome="succeeded", **{k:r[k] for k in ("ticket_ref","parent_task","parent_session","parent_generation")})
            parent = dict(id="T7", owner="alice", generation=2)
            f = Path(temp)/"relay.json"
            f.write_text(json.dumps(dict(id="child/session#done", **{"from":"child/session", "to":"parent/session"}, payload=dict(task_report=r))))
            sends = []
            def run(args, **kwargs):
                if args[-2:] == [str(control.BIN), "parent/session"]:
                    return subprocess.CompletedProcess(args,0,"socket\n@7\n"+temp+"\nself\n","")
                self.assertNotIn("FLEET_LAUNCH_DELIVERY", kwargs.get("env") or {})  # no native proof gates it
                self.assertIn("children_send", args[2])
                sends.append(kwargs.get("input")); return subprocess.CompletedProcess(args,0,"","")
            def call(action, task, *args, **kwargs):
                return dict(task=parent if task == "T7" else t)
            with patch.object(control,"call",side_effect=call), patch.object(control.subprocess,"run",side_effect=run), contextlib.redirect_stdout(io.StringIO()):
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
                with patch.object(control.subprocess, "run", return_value=subprocess.CompletedProcess([],77,"","")), patch.object(control,"orphan") as orphan:
                    self.assertEqual(control.receive(f),0)
                    orphan.assert_called_once()  # closed ID, no successor / parent
            self.assertEqual(len(sends),1)
            self.assertEqual(len((Path(temp)/"T7-g2.ndjson").read_text().splitlines()),1)
            # a new parent generation (re-launch, /clear) still takes it: same ID
            r2 = dict(r, event_id="again"); parent["generation"] = 3
            f.write_text(json.dumps(dict(id="child/session#again", **{"from":"child/session", "to":"parent/session"}, payload=dict(task_report=r2))))
            with patch.object(control,"call",side_effect=call), patch.object(control.subprocess,"run",side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(control.receive(f),0)
            self.assertEqual(len(sends),2)
            print("fixture report: event=done, reconnect rows=1, deliveries=1; parent g3 still the same ID → delivered")

    def test_progress_goes_on_the_window_id(self):
        # EPIC T497 C12 / C8: the tick is a `progress` event on the window's own
        # ID's ledger — the task record is neither read nor written.
        import fleet_id
        fid = "3fa85f64-5717-4562-b3fc-2c963f66afa6"
        with tempfile.TemporaryDirectory() as d, \
             patch.dict(os.environ, FLEET_ID_DIR=d, FLEET_ID_PUSH="0"), \
             patch.object(control, "call") as hub, patch.object(control, "option", return_value=fid), \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.progress("@7", "tick 5 · report: pending", "waiting", "tick-5"), 0)
            self.assertEqual(control.progress("@7", "tick 5 again", "waiting", "tick-5"), 0)
            hub.assert_not_called()
            pg = fleet_id.fold(fleet_id.read(fid))["progress"]
            self.assertEqual((pg["summary"], pg["event"], pg["seq"]), ("tick 5 · report: pending", "tick-5", 1))
        self.assertIn("id: " + fid, out.getvalue())
        with patch.object(control, "option", return_value=""), self.assertRaises(ValueError):
            control.progress("@7", "tick 6", "waiting")

    def test_children_summary_counts_outcomes(self):
        kids = [dict(outcome="succeeded"), dict(outcome="failed"), dict(outcome=""), dict()]
        self.assertEqual(control.child_summary(dict(children=kids)),
                         dict(open=2, succeeded=1, failed=1, cancelled=0, refused=0))
        hub = dict(open=0, succeeded=2, failed=0, cancelled=0, refused=0)
        self.assertEqual(control.child_summary(dict(children=kids, summary=hub)), hub)

    def test_cancel_a_record_no_window_opened(self):
        # claude-fleet#4964 / EPIC T497 C13: a record no window ever opened is
        # cancelled by one transition; the hub answers for one an ID carries.
        t = dict(id="T361", authority_version=1, owner="alice", generation=1, state="accepted")
        with patch.object(control, "call", side_effect=[dict(task=t), t]) as calls, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.cancel("T361", "residual-T361"), 2)
        m = calls.call_args.args[2]
        self.assertEqual((calls.call_args.args[0], m["kind"], m["state"], m["expected_worker"]), ("mutate", "transition", "cancelled", ""))
        self.assertTrue(m["evidence"])
        self.assertIn("CANCELLED", out.getvalue())
        done = dict(t, outcome="cancelled")
        with patch.object(control, "call", return_value=dict(task=done)) as calls, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.cancel("T361", "ev"), 0)
        self.assertEqual(calls.call_count, 1)
        self.assertIn("CANCELLED", out.getvalue())

    def test_one_code_names_the_task(self):
        # EPIC T644 C3: a verdict / a children list names a task by its code — the
        # record's `short`, else the login's book — never its T<n>; an older hub
        # (no code anywhere) keeps T<n>.
        t = dict(id="T7", short="K7W0", authority_version=1, generation=1, state="succeeded", outcome="succeeded")
        with patch.object(control, "call", return_value={"task": t}), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(control.wait_task("k7", 5, 1), 0)
        self.assertEqual(out.getvalue(), "SUCCEEDED\ntask: K7W0\n")
        with patch.object(control, "call", return_value={"task": t}), contextlib.redirect_stdout(io.StringIO()) as out:
            control.closed("K7W0")
        self.assertNotIn("T7", out.getvalue())
        kids = dict(children=[dict(id="T8", short="K8AB", title="x", outcome=""), dict(id="T9", title="y", outcome="")])
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, FLEET_ID_DIR=d), \
             patch.object(control, "call", return_value=kids), contextlib.redirect_stdout(io.StringIO()) as out:
            Path(d, "task-codes.tsv").write_text("T9\tK9CD\tx\n")
            control.children("K7W0", False)
            self.assertEqual(control.child_label(dict(task="T9", worker_id="u/issue-4")), "#K9CD")
        lines = out.getvalue().splitlines()
        self.assertTrue(lines[1].startswith("K8AB ") and lines[2].startswith("K9CD "), lines)
        old = dict(t, short="")
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, FLEET_ID_DIR=d), \
             patch.object(control, "call", return_value={"task": old}), contextlib.redirect_stdout(io.StringIO()) as out:
            control.wait_task("T7", 5, 1)
        self.assertEqual(out.getvalue(), "SUCCEEDED\ntask: T7\n")

if __name__ == "__main__":
    unittest.main()
