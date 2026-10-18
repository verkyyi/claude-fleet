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


REAL_CAPABILITY = runtime.idle_accept_capability


class ConditionalAcceptance(unittest.TestCase):
    """A provider the adapter has no accept for: unavailable, no I/O, no receipt.
    (Claude had none until #4618 — stood in for here; its own: ClaudeIdleAccept.)"""

    def setUp(self):
        self.delivery = "55555555-5555-4555-8555-555555555555"
        self.snapshot = Snapshot().observation()
        self.snapshot["identity"]["provider"] = "claude"
        p = mock.patch.object(runtime, "idle_accept_capability",
                              side_effect=lambda provider: REAL_CAPABILITY("future-provider"))
        p.start(); self.addCleanup(p.stop)
        for target in ("subprocess.run", "subprocess.Popen", "socket.socket", "builtins.open"):
            p = mock.patch(target, side_effect=AssertionError("unavailable must do no I/O"))
            p.start(); self.addCleanup(p.stop)
        p = mock.patch.object(runtime, "RPC", side_effect=AssertionError("unavailable must not connect"))
        p.start(); self.addCleanup(p.stop)
        p = mock.patch.object(runtime.time, "time", return_value=101.)
        p.start(); self.addCleanup(p.stop)

    def attempt(self, snapshot=None, **kw):
        args = dict(pane="%7", expected=self.snapshot if snapshot is None else snapshot,
                    delivery_id=self.delivery, text="private loop message")
        args.update(kw)
        result = runtime.accept_if_idle(**args)
        self.assertEqual(result["state"], "unknown")
        self.assertFalse(result["submitted"])
        self.assertIsNone(result["receipt"])
        if result["reason"] != "invalid_request":
            self.assertNotEqual(result["capability"]["state"], "available")
        self.assertNotIn("private loop message", json.dumps(result))
        return result

    def test_capability_does_not_guess_from_provider_or_version(self):
        for provider in ("future-provider", None, {}, "Claude"):
            c = REAL_CAPABILITY(provider)
            self.assertEqual(c["version"], 1)
            self.assertEqual(c["state"], "unavailable")
            self.assertIsNone(c["native_method"])
            self.assertEqual(c["support"], "native_atomic_precondition_and_receipt_required")
        c = REAL_CAPABILITY("codex")
        self.assertEqual((c["state"], c["native_method"]), ("available", "thread/queue/start"))
        self.assertEqual(c["fence"], dict(idle="native", turn="precheck"))
        c = REAL_CAPABILITY("claude")
        self.assertEqual((c["state"], c["native_method"]), ("available", "mod/prompt.submit"))
        self.assertEqual(c["fence"], dict(idle="entry_boundary", turn="entry_boundary"))

    def test_previous_idle_observation_without_capability_never_sends(self):
        before = copy.deepcopy(self.snapshot)
        # A previous read is no authority over a concurrent user turn.
        result = self.attempt()
        self.assertEqual(result["reason"], "capability_unavailable")
        self.assertEqual(result["delivery_id"], self.delivery)
        self.assertEqual(result["request_identity"], before["identity"])
        self.assertEqual(self.snapshot, before)

    def test_old_identity_and_late_ack_cannot_create_a_receipt(self):
        for key in self.snapshot["identity"]:
            if key == "provider":
                continue
            old = copy.deepcopy(self.snapshot)
            old["identity"][key] = "old-generation-or-session"
            old["controller_delivery"] = dict(state="accepted", delivery_id=self.delivery,
                                              accepted_turn="late-old-turn")
            old["capability"] = dict(state="available", native_method="turn/start")
            self.attempt(old)

    def test_repeat_restart_and_all_blockers_stay_unknown(self):
        for state in ("idle", "active", "ask", "approval", "interrupted", "unknown"):
            for gate in ("tool", "bg", "dirty", "recent_input", "transfer", "handoff", "quota", "disconnected"):
                s = copy.deepcopy(self.snapshot)
                s["runtime"].update(state=state, reason=gate)
                a = self.attempt(s)
                self.assertEqual(a, self.attempt(s))  # no retry or durable effect
        for now in (99., 105., 200.):
            with mock.patch.object(runtime.time, "time", return_value=now):
                self.attempt()

    def test_invalid_requests_and_untrusted_receipts_fail_closed(self):
        for provider in ("claude", "codex"):
            for snapshot in ({}, {"version": 2}, {"identity": []}):
                self.assertEqual(self.attempt(snapshot)["reason"], "invalid_request")
            self.snapshot["identity"]["provider"] = provider
            for kw in (dict(pane=""), dict(delivery_id=""), dict(text=""), dict(text=123),
                       dict(text="x" * 65537)):
                self.assertEqual(self.attempt(**kw)["reason"], "invalid_request")


class ClaudeIdleAccept(unittest.TestCase):
    """accept_if_idle for Claude: the mod's inbox answer stood in for; the real
    engine is fleet-idle-accept-claude-selftest.sh, the mod's half its own tests."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.inbox = Path(self.tmp.name) / "inbox"
        self.inbox.mkdir()
        self.projects = Path(self.tmp.name) / "projects"
        (self.projects / "-repo").mkdir(parents=True)
        self.snapshot = Snapshot().observation()
        self.snapshot["identity"]["provider"] = "claude"
        self.delivery = "77777777-7777-4777-8777-777777777777"
        self.state, self.advert, self.posts, self.now = "idle", "idle.v1", [], 101.
        self.answer = lambda req: dict(ok=True, state="accepted", reason="native_entry", nonce=req["nonce"],
                                       delivery_id=req["delivery_id"], turn_id="turn-2",
                                       previous_turn_id=req["expected_turn"])

        def read(pane, context=None, expected=None, socket=""):
            s = copy.deepcopy(self.snapshot)
            s["runtime"]["state"] = self.state
            return s

        def post(directory, request, wait):
            self.posts.append(request)
            a = self.answer(request)
            if isinstance(a, Exception):
                raise a
            return a
        opts = {"@mod_accept": lambda: self.advert}
        patches = [mock.patch.dict(os.environ, FLEET_CONF_DIR=self.tmp.name, FLEET_CC_PROJECTS_DIR=str(self.projects)),
                   mock.patch.object(runtime, "read", side_effect=read),
                   mock.patch.object(runtime, "claude_inbox", return_value=self.inbox),
                   mock.patch.object(runtime, "claude_post_accept", side_effect=post),
                   mock.patch.object(runtime.launch, "inspect", side_effect=lambda *a: R.copy()),
                   mock.patch.object(runtime.launch, "option", side_effect=lambda pane, name, socket="": opts[name]()),
                   mock.patch.object(runtime.time, "time", side_effect=lambda: self.now)]
        for p in patches:
            p.start(); self.addCleanup(p.stop)

    def accept(self, text="loop due message"):
        r = runtime.accept_if_idle("%7", self.snapshot, self.delivery, text)
        self.assertNotIn(text, json.dumps(r))
        return r

    def test_idle_accepts_once_with_the_mods_turn(self):
        r = self.accept()
        self.assertEqual((r["state"], r["submitted"], r["receipt"]["turn_id"]), ("accepted", True, "turn-2"))
        self.assertEqual((r["receipt"]["method"], r["receipt"]["previous_turn_id"]), ("mod/prompt.submit", "turn-1"))
        req = self.posts[0]
        self.assertEqual((req["accept"], req["expected_turn"], req["delivery_id"]), ("idle.v1", "turn-1", self.delivery))
        self.assertEqual(req["launch"], dict(C, provider="claude"))
        self.assertTrue(0 < req["deadline"] - self.now <= runtime.CLAUDE_ACCEPT_WINDOW)
        again = self.accept()
        self.assertEqual((again["state"], again["receipt"]["source"], len(self.posts)), ("accepted", "journal", 1))

    def test_no_mod_advert_or_not_idle_sends_nothing(self):
        self.advert = ""
        r = self.accept()
        self.assertEqual((r["state"], r["reason"], r["submitted"]), ("rejected", "mod_accept_unavailable", False))
        self.advert, self.state = "idle.v1", "active"
        r = self.accept()
        self.assertEqual((r["state"], r["reason"], r["submitted"]), ("rejected", "precheck_active", False))
        self.assertEqual(self.posts, [])

    def test_entry_drop_is_rejected_and_a_retry_may_post_again(self):
        self.answer = lambda req: dict(ok=True, state="rejected", reason="draft_present", nonce=req["nonce"],
                                       delivery_id=req["delivery_id"])
        r = self.accept()
        self.assertEqual((r["state"], r["reason"], r["submitted"], r["receipt"]), ("rejected", "draft_present", True, None))
        self.accept()
        self.assertEqual(len(self.posts), 2)

    def test_unanswered_is_settled_by_its_receipt_never_resent(self):
        self.answer = lambda req: runtime.Unknown("entry_unanswered")
        r = self.accept()
        self.assertEqual((r["state"], r["reason"]), ("unknown", "entry_unanswered"))
        # Within the window: still unsettled, no second post.
        self.assertEqual(self.accept()["reason"], "previous_attempt_unsettled")
        self.assertEqual(len(self.posts), 1)
        # The turn's hidden context names it, no receipt file: delivered, turn unknown.
        sid = R["native_session"]
        t = self.projects / "-repo" / (sid + ".jsonl")
        t.write_text(json.dumps(dict(type="user", message=dict(content=[
            dict(type="text", text=runtime.CLAUDE_RECEIPT_PREFIX + self.delivery)]))) + "\n")
        self.assertEqual(self.accept()["reason"], "receipt_turn_unknown")
        # The mod's durable receipt names the turn.
        (self.inbox / ("idle-accept-%s.receipt" % self.delivery)).write_text(json.dumps(dict(
            state="accepted", delivery_id=self.delivery, turn_id="turn-9")))
        r = self.accept()
        self.assertEqual((r["state"], r["reason"], r["receipt"]["turn_id"]), ("accepted", "mod_receipt", "turn-9"))
        self.assertEqual(len(self.posts), 1)

    def test_past_its_window_with_no_receipt_it_never_ran(self):
        self.answer = lambda req: runtime.Unknown("entry_unanswered")
        self.accept()
        sid = R["native_session"]
        (self.projects / "-repo" / (sid + ".jsonl")).write_text('{"type":"user"}\n')
        self.now += runtime.CLAUDE_ACCEPT_WINDOW + runtime.CLAUDE_ACCEPT_GRACE + runtime.CLAUDE_ACCEPT_POLL + 1
        self.answer = lambda req: dict(ok=True, state="accepted", reason="native_entry", nonce=req["nonce"],
                                       delivery_id=req["delivery_id"], turn_id="turn-3",
                                       previous_turn_id=req["expected_turn"])
        r = self.accept()
        self.assertEqual((r["state"], r["receipt"]["turn_id"], len(self.posts)), ("accepted", "turn-3", 2))
        # No transcript to read: never "not delivered".
        self.delivery = "88888888-8888-4888-8888-888888888888"
        self.answer = lambda req: runtime.Unknown("entry_unanswered")
        self.accept()
        (self.projects / "-repo" / (sid + ".jsonl")).unlink()
        self.now += 60
        self.assertEqual(self.accept()["reason"], "receipt_scan_incomplete")

    def test_reused_delivery_id_with_other_text_is_refused(self):
        self.accept()
        self.assertEqual(self.accept(text="another message")["reason"], "delivery_id_reused")
        self.assertEqual(len(self.posts), 1)

    def test_an_answer_for_another_turn_is_not_a_receipt(self):
        self.answer = lambda req: dict(ok=True, state="accepted", reason="native_entry", nonce=req["nonce"],
                                       delivery_id=req["delivery_id"], turn_id="turn-2", previous_turn_id="other")
        self.assertEqual(self.accept()["state"], "unknown")


class ClaudePostAccept(unittest.TestCase):
    """claude_post_accept on real files, a thread playing the mod's inbox poll."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        self.req = dict(accept="idle.v1", nonce="c" * 32, delivery_id="99999999-9999-4999-8999-999999999999")

    def mod(self, answer, take=True):
        import threading

        def run():
            for _ in range(200):
                try:
                    (self.d / "idle-accept.json").rename(self.d / "idle-accept.taken") if take else None
                    break
                except FileNotFoundError:
                    runtime.time.sleep(.01)
            if answer is not None:
                (self.d / "idle-accept.done").write_text(json.dumps(answer))
        t = threading.Thread(target=run)
        t.start()
        self.addCleanup(t.join)

    def test_answered(self):
        self.mod(dict(ok=True, state="accepted", nonce=self.req["nonce"], delivery_id=self.req["delivery_id"]))
        self.assertEqual(runtime.claude_post_accept(self.d, self.req, 3)["state"], "accepted")
        self.assertEqual(sorted(p.name for p in self.d.iterdir()), ["idle-accept.lock"])

    def test_never_taken_is_rejected_and_withdrawn(self):
        r = runtime.claude_post_accept(self.d, self.req, .2)
        self.assertEqual((r["state"], r["reason"]), ("rejected", "not_taken"))
        self.assertFalse((self.d / "idle-accept.json").exists())

    def test_taken_unanswered_is_unknown(self):
        self.mod(None)
        with self.assertRaises(runtime.Unknown):
            runtime.claude_post_accept(self.d, self.req, .5)

    def test_refused_and_mismatched(self):
        self.mod(dict(ok=False, error="launch_changed"))
        self.assertEqual(runtime.claude_post_accept(self.d, self.req, 3)["reason"], "mod_refused")
        self.mod(dict(ok=True, state="accepted", nonce="d" * 32, delivery_id=self.req["delivery_id"]))
        with self.assertRaises(runtime.Unknown):
            runtime.claude_post_accept(self.d, self.req, 3)


class FakeCodex:
    """The queue semantics the real Codex 0.162.1 app-server showed (#4617):
    add on an idle thread starts at once; start on a busy thread is refused;
    delete and every start share one dispatch lock; an idle edge drains the head.
    """

    def __init__(self):
        self.turns = [dict(id="turn-1", clientId=None)]
        self.queue = []
        self.active = None
        self.seq = 1
        self.delivered = []
        self.calls = []
        self.version = "0.162.1"
        self.young = False       # store without paginated history yet
        self.fail = {}           # method -> exception, once
        self.before = {}         # method -> callable, once, before handling

    def next_id(self, kind):
        self.seq += 1
        return "%s-%d" % (kind, self.seq)

    def start_turn(self, client_id, text=""):
        t = dict(id=self.next_id("turn"), clientId=client_id)
        self.turns.append(t)
        self.active = t["id"]
        if client_id:
            self.delivered.append(client_id)
        return t

    def user_turn(self):
        return self.start_turn(None)

    def finish(self):
        self.active = None
        if self.queue:  # the native idle edge drains the head
            q = self.queue.pop(0)
            self.start_turn(q["clientUserMessageId"])
            self.active = None

    def call(self, method, params):
        self.calls.append(method)
        if method in self.before:
            self.before.pop(method)()
        if method in self.fail:
            raise self.fail.pop(method)
        if method == "thread/queue/add":
            q = dict(id=self.next_id("q"), clientUserMessageId=params["clientUserMessageId"],
                     input=params["input"])
            self.queue.append(q)
            if self.active is None:
                self.queue.remove(q)
                self.start_turn(q["clientUserMessageId"])
                self.active = None
            return dict(queuedSubmission=q)
        if method == "thread/queue/start":
            q = [x for x in self.queue if x["id"] == params["queuedSubmissionId"]]
            if not q:
                raise ValueError("queued submission not found: " + params["queuedSubmissionId"])
            if self.active is not None:
                raise ValueError("thread already has an active or pending turn")
            self.queue.remove(q[0])
            t = self.start_turn(q[0]["clientUserMessageId"])
            self.active = None
            return dict(turn=dict(id=t["id"], status="inProgress", items=[]))
        if method == "thread/queue/delete":
            q = [x for x in self.queue if x["id"] == params["queuedSubmissionId"]]
            for x in q:
                self.queue.remove(x)
            return dict(deleted=bool(q))
        if method == "thread/queue/list":
            return dict(data=list(self.queue), nextCursor=None)
        if method == "thread/read":
            assert params["includeTurns"] is True
            return dict(thread=dict(id=params["threadId"], turns=[
                dict(id=t["id"], items=[dict(type="userMessage", clientId=t["clientId"])]) for t in self.turns]))
        if method == "thread/turns/list":
            if self.young:
                raise ValueError("list_turns is not supported yet")
            self.assertDesc(params)
            off = int(params.get("cursor") or 0)
            rows = list(reversed(self.turns))[off:off + params["limit"]]
            nxt = str(off + len(rows)) if off + len(rows) < len(self.turns) else None
            return dict(data=[dict(id=t["id"], items=[dict(type="userMessage", clientId=t["clientId"])])
                              for t in rows], nextCursor=nxt)
        raise AssertionError("unexpected native call " + method)

    @staticmethod
    def assertDesc(params):
        assert params["sortDirection"] == "desc" and params["itemsView"] == "summary", params


class CodexIdleAccept(unittest.TestCase):
    """accept_if_idle through the fake app-server; the real binary is
    fleet-idle-accept-native-selftest.sh."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.native = FakeCodex()
        self.snapshot = Snapshot().observation()
        self.state = "idle"
        self.delivery = "66666666-6666-4666-8666-666666666666"
        client = mock.Mock()
        client.call.side_effect = self.native.call
        client.initialized = property(lambda _: None)
        type(client).initialized = mock.PropertyMock(
            side_effect=lambda: dict(userAgent="claude_fleet/%s (Mac OS; arm64)" % self.native.version))
        self.client = client

        def read(pane, context=None, expected=None, socket=""):
            s = copy.deepcopy(self.snapshot)
            s["identity"]["turn_id"] = self.native.turns[-1]["id"]
            s["runtime"]["state"] = "active" if self.native.active else self.state
            if expected is not None and expected["identity"] != s["identity"]:
                s["runtime"].update(state="unknown", reason="identity_changed")
            return s
        patches = [mock.patch.dict(os.environ, FLEET_CONF_DIR=self.tmp.name),
                   mock.patch.object(runtime, "read", side_effect=read),
                   mock.patch.object(runtime, "RPC", return_value=client),
                   mock.patch.object(runtime.launch, "inspect", side_effect=lambda *a: R.copy()),
                   mock.patch.dict(runtime.CODEX, identity=lambda *a: dict(
                       session_id=R["native_session"], remote=R["native_remote"], home=R["native_home"])),
                   mock.patch.object(runtime.time, "sleep", return_value=None)]
        for p in patches:
            p.start(); self.addCleanup(p.stop)

    def expected(self):
        s = copy.deepcopy(self.snapshot)
        s["identity"]["turn_id"] = self.native.turns[-1]["id"]
        return s

    def accept(self, expected=None, text="loop due message", delivery=None):
        r = runtime.accept_if_idle("%7", expected or self.expected(), delivery or self.delivery, text)
        self.assertNotIn(text, json.dumps(r))
        return r

    def test_idle_session_accepts_once_with_a_receipt(self):
        r = self.accept()
        self.assertEqual((r["state"], r["submitted"]), ("accepted", True))
        self.assertEqual(r["receipt"]["turn_id"], self.native.turns[-1]["id"])
        self.assertEqual(r["receipt"]["previous_turn_id"], "turn-1")
        self.assertFalse(r["receipt"]["intervening_turn"])
        self.assertEqual(self.native.delivered, [self.delivery])
        # The same delivery again is answered from the journal: no second native write.
        again = self.accept()
        self.assertEqual((again["state"], again["receipt"]["turn_id"], again["receipt"]["source"]),
                         ("accepted", r["receipt"]["turn_id"], "journal"))
        self.assertEqual(self.native.calls.count("thread/queue/add"), 1)
        self.assertEqual(self.native.delivered, [self.delivery])

    def test_user_turn_after_the_precheck_is_refused_and_deleted(self):
        expected = self.expected()
        self.native.before["thread/queue/add"] = self.native.user_turn
        r = self.accept(expected)
        self.assertEqual((r["state"], r["reason"], r["receipt"]), ("rejected", "native_not_idle", None))
        self.assertEqual(self.native.queue, [])
        self.native.finish()
        self.assertEqual(self.native.delivered, [])

    def test_refusal_then_native_idle_dispatch_is_an_accepted_receipt(self):
        self.native.before["thread/queue/add"] = self.native.user_turn
        self.native.before["thread/queue/delete"] = self.native.finish
        r = self.accept()
        self.assertEqual((r["state"], r["reason"]), ("accepted", "native_idle_dispatch"))
        self.assertTrue(r["receipt"]["intervening_turn"])
        self.assertEqual(self.native.delivered, [self.delivery])

    def test_our_own_start_names_the_accepted_turn(self):
        self.native.before["thread/queue/add"] = self.native.user_turn
        self.native.before["thread/queue/start"] = lambda: setattr(self.native, "active", None)
        r = self.accept()
        self.assertEqual((r["state"], r["reason"]), ("accepted", "native_started"))
        self.assertEqual(r["receipt"]["turn_id"], self.native.turns[-1]["id"])
        self.assertEqual(r["receipt"]["previous_turn_id"], self.native.turns[-2]["id"])
        self.assertTrue(r["receipt"]["intervening_turn"])
        self.assertEqual(self.native.delivered, [self.delivery])

    def test_young_thread_reads_the_receipt_from_the_full_record(self):
        self.native.young = True
        self.native.before["thread/queue/add"] = self.native.user_turn
        self.native.before["thread/queue/delete"] = self.native.finish
        r = self.accept()
        self.assertEqual((r["state"], r["reason"]), ("accepted", "native_idle_dispatch"))
        self.assertTrue(r["receipt"]["intervening_turn"])
        self.assertIn("thread/read", self.native.calls)

    def test_precheck_not_idle_or_changed_turn_writes_nothing(self):
        expected = self.expected()
        self.native.user_turn()
        for e in (expected, self.expected()):
            r = self.accept(e)
            self.assertEqual(r["state"], "rejected")
            self.assertTrue(r["reason"].startswith("precheck_"))
        self.assertNotIn("thread/queue/add", self.native.calls)
        self.assertFalse(Path(self.tmp.name, "global/idle-accept", self.delivery + ".json").exists())

    def test_disconnect_after_add_never_resends(self):
        self.native.before["thread/queue/add"] = self.native.user_turn
        self.native.fail["thread/queue/start"] = EOFError("socket closed")
        r = self.accept()
        self.assertEqual((r["state"], r["submitted"], r["receipt"]), ("unknown", True, None))
        self.assertEqual(len(self.native.queue), 1)
        # Still busy: the retry settles the same queued item, refused and deleted.
        r = self.accept()
        self.assertEqual((r["state"], r["reason"]), ("rejected", "precheck_active"))
        self.assertEqual(self.native.calls[-2:], ["thread/queue/start", "thread/queue/delete"])
        self.assertEqual(self.native.queue, [])
        self.native.finish()
        r = self.accept()
        self.assertEqual(r["state"], "accepted")
        self.assertEqual(self.native.delivered, [self.delivery])

    def test_disconnect_while_native_dispatch_took_it_reads_the_receipt(self):
        self.native.fail["thread/queue/start"] = EOFError("socket closed")
        self.native.before["thread/queue/add"] = self.native.user_turn
        self.assertEqual(self.accept()["state"], "unknown")
        self.native.finish()  # the native queue starts it on its own
        r = self.accept()
        self.assertEqual((r["state"], r["reason"]), ("accepted", "native_receipt"))
        self.assertEqual(self.native.calls.count("thread/queue/add"), 1)
        self.assertEqual(self.native.delivered, [self.delivery])

    def test_unreachable_anchor_is_unknown_never_a_resend(self):
        self.native.fail["thread/queue/start"] = EOFError("socket closed")
        self.native.before["thread/queue/add"] = self.native.user_turn
        self.accept()
        self.native.queue.clear()  # gone without a trace we can read
        for _ in range(runtime.RECEIPT_PAGES * runtime.RECEIPT_PAGE + 1):
            self.native.turns.insert(0, dict(id=self.native.next_id("old"), clientId=None))
        self.native.active = None
        path = Path(self.tmp.name, "global/idle-accept", self.delivery + ".json")
        rec = json.loads(path.read_text()); rec["anchor"] = "turn-gone"; path.write_text(json.dumps(rec))
        r = self.accept()
        self.assertEqual((r["state"], r["reason"]), ("unknown", "receipt_scan_incomplete"))
        self.assertEqual(self.native.calls.count("thread/queue/add"), 1)

    def test_old_generation_reused_id_and_untested_version_refuse(self):
        self.accept()
        old = self.expected(); old["identity"].update(generation=2, attempt_id="task:T1:g2")
        self.assertEqual(self.accept(old)["reason"], "delivery_identity_changed")
        self.assertEqual(self.accept(text="another message")["reason"], "delivery_id_reused")
        self.native.version = "0.161.9"
        other = "77777777-7777-4777-8777-777777777777"
        r = self.accept(delivery=other)
        self.assertEqual((r["state"], r["reason"], r["submitted"]), ("unknown", "native_version_untested", False))
        self.assertEqual(self.native.calls.count("thread/queue/add"), 1)

    def test_endpoint_or_native_identity_change_refuses(self):
        with mock.patch.object(runtime.launch, "inspect", side_effect=lambda *a: dict(R, birth="reused")):
            self.assertEqual(self.accept()["reason"], "native_identity_changed")
        with mock.patch.dict(runtime.CODEX, identity=lambda *a: dict(session_id="x", remote=R["native_remote"])):
            self.assertEqual(self.accept()["reason"], "endpoint_identity_changed")
        self.assertNotIn("thread/queue/add", self.native.calls)


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
        with mock.patch.object(runtime, "claude_registry", return_value=registry), \
             mock.patch.object(runtime, "query_claude", side_effect=runtime.Unknown("event_expired")) as query:
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
            fresh = dict(event, observed_at=101., query_id="a" * 32)
            def answer(*args):
                self.options["@runtime_claude"] = json.dumps(fresh)
                return fresh
            query.side_effect = answer
            registry["status"] = "idle"
            renewed = self.read()
            self.assertEqual(renewed["runtime"]["state"], "idle")
            self.assertEqual(renewed["source"], "claude:native-query")
            self.assertEqual(renewed["observed_at"], 101.)
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
            runtime.record_event(dict(a,turn_id="b",state="interrupted",sequence=6,
                                      start=False,query_id="a" * 32))
            self.assertEqual(saved["query_id"],"a" * 32)
            for change in (dict(turn_id="a"), dict(state="idle"), dict(start=True)):
                with self.assertRaises(runtime.Unknown):
                    runtime.record_event(dict(a,turn_id="b",state="interrupted",sequence=7,
                                              start=False,query_id="b" * 32) | change)


if __name__ == "__main__":
    unittest.main()
