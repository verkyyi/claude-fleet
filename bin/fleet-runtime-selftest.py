#!/usr/bin/env python3
"""Runtime observation contracts, with no live task authority or agent credentials."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import fleet_runtime as runtime


C = dict(version=1, operation_id="11111111-1111-4111-8111-111111111111", task="T1",
         owner="alice", generation=1, attempt_id="task:T1:g1", provider="codex",
         worker_id="22222222-2222-4222-8222-222222222222/33333333-3333-4333-8333-333333333333")
R = dict(C, actual_provider="codex", native_session="44444444-4444-4444-8444-444444444444",
         pid=42, birth="kernel-birth", executable="/native/codex", observed_at=10,
         native_remote="unix:///private/worker.sock", native_home="/private/home")


class Snapshot(unittest.TestCase):
    def observation(self, state="idle", **kw):
        return dict(identity=runtime.identity(C, R, "turn-1"), source="codex:rpc",
                    observed_at=100., expires_at=105., runtime=dict(state=state, reason="",
                    socket_ready=True, thread_ready=True, first_thread_deadline=55.),
                    task_result=dict(state="unknown"), controller_delivery=dict(state="unknown"),
                    reclaim=dict(eligible=False, reason="separate_gates_required"),
                    version=1, **kw)

    def test_expired_remote_and_clock_rollback_are_unknown(self):
        for now in (99., 105., 200.):
            s = runtime.project(self.observation(), now=now)
            self.assertEqual(s["runtime"]["state"], "unknown")
            self.assertFalse(s["reclaim"]["eligible"])
            self.assertEqual(s["observed_at"], 100.)
            self.assertEqual(s["expires_at"], 105.)

    def test_every_fence_and_turn_is_compared(self):
        old = self.observation()
        for k in old["identity"]:
            new = copy.deepcopy(old)
            new["identity"][k] = "other"
            self.assertEqual(runtime.project(new, expected=old, now=101.)["runtime"]["reason"], "identity_changed", k)

    def test_stop_unknown_merged_never_authorize(self):
        for state in ("unknown", "interrupted", "idle"):
            s = self.observation(state)
            s["task_result"] = dict(state="succeeded", workflow="MERGED")
            got = runtime.project(s, now=101.)
            self.assertFalse(got["reclaim"]["eligible"])
            self.assertEqual(got["controller_delivery"]["state"], "unknown")

    def test_malformed_projection_is_unknown(self):
        for change in (dict(version=2), dict(expires_at=float("nan")), dict(observed_at=True),
                       dict(expires_at=999.), dict(identity={})):
            s = dict(self.observation(), **change)
            self.assertEqual(runtime.project(s, now=101.)["runtime"]["state"], "unknown")


class Provider(unittest.TestCase):
    def setUp(self):
        self.receipt = R.copy()
        self.context = C.copy()
        self.thread = dict(id=R["native_session"], cwd="/work", status=dict(type="idle"))
        self.turn = dict(id="turn-1", status="completed", startedAt=80, completedAt=90)
        self.data = dict(session_id=R["native_session"], remote=R["native_remote"], home=R["native_home"])
        self.client = mock.Mock()
        def call(method, params):
            if method == "thread/read":
                self.assertFalse(params["includeTurns"])
                return dict(thread=copy.deepcopy(self.thread))
            self.assertEqual(method, "thread/turns/list")
            self.assertEqual(params["limit"], 1)
            self.assertEqual(params["itemsView"], "notLoaded")
            return dict(data=[self.turn] if self.turn else [])
        self.client.call.side_effect = call
        self.options = {"@launch": json.dumps(C), "@launch_receipt": json.dumps(R),
                        "pane_pid": "11", "@worktree": "/work"}
        self.task = dict(authority_version=1, owner="alice", generation=1,
                         execution_owner=C["worker_id"], resolved_agent="codex", outcome="", state="running")
        patches = [mock.patch.object(runtime, "RPC", return_value=self.client),
                   mock.patch.dict(runtime.CODEX, identity=lambda *a: self.data.copy()),
                   mock.patch.object(runtime.launch, "inspect", side_effect=lambda *a: self.receipt.copy()),
                   mock.patch.object(runtime.launch, "option", side_effect=lambda p,k,*a: self.options.get(k,"")),
                   mock.patch.object(runtime.launch, "process", return_value=dict(birth="Thu Jan  1 00:00:10 1970:10")),
                   mock.patch.object(runtime.launch, "task_call", side_effect=lambda *a: self.task.copy()),
                   mock.patch.object(runtime.time, "time", return_value=101.),
                   mock.patch.object(runtime.time, "mktime", return_value=10.)]
        for p in patches:
            p.start(); self.addCleanup(p.stop)

    def read(self):
        return runtime.read("%7")

    def test_native_long_tool_ci_and_attention(self):
        for flags, state in (([], "active"), (["waitingOnUserInput"], "ask"), (["waitingOnApproval"], "approval")):
            self.thread["status"] = dict(type="active", activeFlags=flags)
            self.turn["status"] = "inProgress"
            s = self.read()
            self.assertEqual(s["runtime"]["state"], state)
            self.assertEqual(s["identity"]["turn_id"], "turn-1")
            self.assertFalse(s["reclaim"]["eligible"])

    def test_idle_interrupt_failed_and_not_loaded(self):
        self.assertEqual(self.read()["runtime"]["state"], "idle")
        self.turn["status"] = "interrupted"
        self.assertEqual(self.read()["runtime"]["state"], "interrupted")
        self.turn["status"] = "failed"
        self.assertEqual(self.read()["runtime"]["state"], "unknown")
        self.thread["status"]["type"] = "notLoaded"
        self.assertEqual(self.read()["runtime"]["reason"], "thread_not_loaded")

    def test_socket_ready_is_not_thread_ready_and_deadline_does_not_slide(self):
        self.client.call.side_effect = ValueError("no thread yet")
        s = self.read()
        self.assertTrue(s["runtime"]["socket_ready"])
        self.assertIsNone(s["runtime"]["thread_ready"])
        self.assertEqual(s["runtime"]["reason"], "first_thread_timeout")
        self.assertEqual(s["runtime"]["first_thread_deadline"], self.read()["runtime"]["first_thread_deadline"])
        self.client.close.assert_called()

    def test_no_turn_and_reconnect_need_fresh_native_read(self):
        self.turn = None
        self.assertEqual(self.read()["runtime"]["reason"], "first_thread_timeout")
        self.client.call.side_effect = EOFError()
        self.assertEqual(self.read()["runtime"]["state"], "unknown")
        self.assertFalse(self.read()["reclaim"]["eligible"])

    def test_transfer_compaction_endpoint_and_nested_thread_refuse(self):
        for key, value in (("id", "new-thread"), ("cwd", "/elsewhere"), ("parentThreadId", "parent")):
            with mock.patch.dict(self.thread, {key:value}):
                self.assertEqual(self.read()["runtime"]["reason"], "native_identity_changed")
        self.data["remote"] = "unix:///another.sock"
        self.assertEqual(self.read()["runtime"]["reason"], "endpoint_identity_changed")

    def test_authority_outage_old_generation_and_racing_terminal_report(self):
        with mock.patch.object(runtime.launch, "task_call", side_effect=ValueError("down")):
            self.assertEqual(self.read()["runtime"]["state"], "unknown")
        self.task["generation"] = 2
        self.assertEqual(self.read()["runtime"]["reason"], "task_fence_changed")
        self.task["generation"] = 1
        with mock.patch.object(runtime.launch, "task_call", side_effect=[self.task, dict(self.task, outcome="succeeded")]):
            self.assertEqual(self.read()["runtime"]["reason"], "identity_changed_during_read")

    def test_task_result_and_runtime_are_independent(self):
        self.task["outcome"] = "succeeded"
        self.thread["status"] = dict(type="active", activeFlags=[])
        s = self.read()
        self.assertEqual(s["task_result"]["state"], "succeeded")
        self.assertEqual(s["runtime"]["state"], "active")
        self.assertFalse(s["reclaim"]["eligible"])

    def test_same_identity_reread_refuses_next_turn_and_pid_reuse(self):
        first = self.read()
        self.turn["id"] = "turn-2"
        s = runtime.read("%7", expected=first)
        self.assertEqual(s["runtime"]["reason"], "identity_changed")
        with mock.patch.object(runtime.launch, "inspect", side_effect=[self.receipt, dict(self.receipt,birth="reused")]):
            self.assertEqual(self.read()["runtime"]["reason"], "identity_changed_during_read")

    def test_no_label_fallback_or_missing_receipt(self):
        self.options["@launch"] = ""
        self.options["@claude_state"] = "done"
        self.assertEqual(self.read()["runtime"]["reason"], "missing_launch")
        self.options["@launch"] = json.dumps(C)
        self.options["@launch_receipt"] = ""
        self.assertEqual(self.read()["runtime"]["reason"], "first_thread_timeout")

    def test_frozen_launch_context_and_explicit_pane(self):
        s = runtime.read("%7", context=dict(C, owner="another"))
        self.assertEqual(s["runtime"]["reason"], "launch_changed")
        self.assertEqual(runtime.read("")["runtime"]["reason"], "explicit_pane_required")

    def test_claude_event_expiry_registry_and_old_generation(self):
        self.context["provider"] = "claude"
        self.receipt.update(self.context, actual_provider="claude")
        self.options["@launch"] = json.dumps(self.context)
        self.task["resolved_agent"] = "claude"
        event = dict(version=1, identity=runtime.identity(self.context,self.receipt),
                     turn_id="native-turn", observed_at=100., state="idle", sequence=2)
        self.options["@runtime_claude"] = json.dumps(event)
        registry = dict(sessionId=R["native_session"],pid=42,cwd="/work",status="idle")
        with mock.patch.object(runtime, "claude_registry", return_value=registry):
            self.assertEqual(self.read()["runtime"]["state"], "idle")
            registry["status"] = "busy"
            self.assertEqual(self.read()["runtime"]["reason"], "registry_contradicts_event")
            event["observed_at"] = 90.
            self.options["@runtime_claude"] = json.dumps(event)
            expired = self.read()
            self.assertEqual(expired["runtime"]["reason"], "event_expired")
            self.assertEqual(expired["source"], "claude:native-event")
            self.assertEqual(expired["observed_at"], 90.)
            self.assertEqual(expired["expires_at"], 95.)
            self.assertEqual(expired["identity"]["turn_id"], "native-turn")
            event["identity"]["generation"] = 2
            self.options["@runtime_claude"] = json.dumps(event)
            self.assertEqual(self.read()["runtime"]["reason"], "event_identity_changed")


class NativeEvents(unittest.TestCase):
    def test_late_duplicate_stop_and_previous_turn_cannot_replace_current(self):
        c = dict(C,provider="claude")
        r = dict(R,**c);r["actual_provider"]="claude"
        saved = {}
        def stamp(p,k,v):saved.update(v)
        with tempfile.TemporaryDirectory() as d, \
             mock.patch.dict(os.environ,TMUX_PANE="%7",FLEET_LAUNCH_CONTEXT=json.dumps(c)), \
             mock.patch.object(runtime.tempfile,"gettempdir",return_value=d), \
             mock.patch.object(runtime.launch,"inspect",return_value=r), \
             mock.patch.object(runtime.launch,"option",side_effect=lambda *a:json.dumps(saved)), \
             mock.patch.object(runtime.launch,"stamp",side_effect=stamp), \
             mock.patch.object(runtime,"claude_registry",return_value=dict(sessionId=r["native_session"])), \
             mock.patch.object(runtime.os,"getppid",return_value=r["pid"]), \
             mock.patch.object(runtime.time,"time",return_value=101.):
            a=dict(turn_id="a",state="active",observed_at=100.,sequence=1,start=True)
            runtime.record_event(a)
            with self.assertRaises(runtime.Unknown):runtime.record_event(a)
            runtime.record_event(dict(a,turn_id="b",sequence=2))
            for bad in (dict(a,state="idle",start=False,sequence=3),
                        dict(a,turn_id="b",state="Stop",sequence=3)):
                with self.assertRaises(runtime.Unknown):runtime.record_event(bad)
            self.assertEqual(saved["turn_id"],"b")
            runtime.record_event(dict(a,turn_id="b",state="interrupted",sequence=4,start=False))
            with self.assertRaises(runtime.Unknown):
                runtime.record_event(dict(a,turn_id="b",sequence=5,start=False))
            self.assertEqual(saved["state"],"interrupted")


if __name__ == "__main__":
    unittest.main()
