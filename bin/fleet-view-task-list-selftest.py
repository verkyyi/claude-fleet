#!/usr/bin/env python3
# selftest-entry
"""Task list contract: stable flat rows, one status slot, history and stop.
No live hub, tmux server, credentials or agent processes are used.
"""
import importlib.util
import contextlib
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_view as v
import fleet_task_control as task_control

spec = importlib.util.spec_from_file_location("quickopen", BIN / "fleet-quickopen.py")
qo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qo)
spec = importlib.util.spec_from_file_location("session_cli", BIN / "fleet-session-cli.py")
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


def row(target, **facts):
    e = dict(kind="sess", target=target, text=target, name=target, group="queue", state="idle",
             sym="idle", id="AB12", agent="codex", tags=[], foot="", repo="test", depth=0, ask="")
    e.update(facts)
    return e


class TaskList(unittest.TestCase):
    def setUp(self):
        v._TASK_ORDER.clear()
        self.env = patch.dict(os.environ, {"FLEET_UI_LANG": "zh"})
        self.env.start()
        v.caches_words_reset()

    def tearDown(self):
        self.env.stop()

    def test_one_slot_priority_and_quiet_states(self):
        examples = [
            (dict(state="needs", pending_start=True, loop=True), "needs"),
            (dict(state="blocked", pending_start=True, loop=True), "needs"),
            (dict(state="blocked"), "needs"),
            (dict(state="working", pending_start=True, loop=True), "pending"),
            (dict(state="working", loop=True), "work"),
            (dict(state="working", running=False, loop=True), "loop"),
            (dict(state="idle", running=True, loop=True), "work"),
            (dict(state="idle", loop=True), "loop"),
            (dict(state="looping"), "quiet"),
            (dict(state="looping", native_wait="bg"), "work"),
            (dict(state="idle"), "quiet"), (dict(state="exited"), "quiet"),
            (dict(state="done"), "quiet"), (dict(state="failed"), "quiet"),
            (dict(state="working", lost=True), "quiet"),
        ]
        for facts, want in examples:
            e = row("task", **facts)
            self.assertEqual(v.task_status(e), want)
            for width in (24, 39, 40, 59, 60, 100):
                segs = v.row_segs(e, width, qo.cells, qo.clip)
                text = "".join(t for t, _ in segs)
                self.assertEqual(qo.cells(text), width)
                self.assertEqual(segs[1][0], v.TASK_GLYPHS[want])
                self.assertEqual(qo.cells("".join(t for t, _ in segs[:1])), v.ICON_X)
                self.assertNotIn("idle", text)
                self.assertNotIn("exited", text)
                self.assertNotIn("待启动", text)
        # The single selected marker does not destroy the underlying facts.
        e = row("task", state="needs", loop=True, ask="发布到哪里？")
        self.assertIn("Loop 已开启", v.note_of(e)[0])
        self.assertIn("发布到哪里？", v.note_of(e)[0])

    def test_only_pin_heading_and_no_tree_or_second_question_line(self):
        items = [dict(kind="hdr", group="work", text="工作"),
                 row("member", group="work", depth=2, fold="driver"),
                 row("driver", group="pin", epic=dict(done=1, total=2), expanded=False),
                 row("ask", state="needs", ask="where?", group="ask"),
                 dict(kind="ask", of="ask", text="where?"),
                 dict(kind="cmd", cmd="reapall", text="legacy cleanup")]
        shown = v.visible(items, "", set())
        self.assertEqual([e["text"] for e in shown if e["kind"] == "hdr"], ["PIN"])
        self.assertEqual([e["target"] for e in shown if e["kind"] == "sess"], ["driver", "member", "ask"])
        self.assertFalse(any(e["kind"] in ("ask", "cmd") for e in shown))
        self.assertTrue(all(not e.get("depth") and not e.get("fold") and not e.get("epic") for e in shown))
        rendered = "".join(t for t, _ in v.row_segs(items[2], 80, qo.cells, qo.clip))
        self.assertNotIn("1/2", rendered)
        self.assertNotIn("▸", rendered)
        self.assertEqual(v.visible([row("plain")], "", set())[0]["kind"], "sess")

    def test_history_and_search_preserve_fold(self):
        items = [row("old", sec="gone", gone=True), row("exited", state="exited", sec="gone", shut=True),
                 row("loop", loop=True, sec="gone"), row("lost", lost=True, sec="gone")]
        closed = v.visible(items, "", set())
        self.assertEqual([e["target"] for e in closed if e["kind"] == "sess"], ["exited", "loop", "lost"])
        self.assertEqual(closed[-1]["text"], "更早的会话")
        self.assertEqual([e["target"] for e in v.visible(items, "old", set())], ["old"])
        self.assertEqual(v.visible(items, "", set())[-1]["closed"], True)
        self.assertIn("old", [e.get("target") for e in v.visible(items, "", {"gone"})])

    def test_state_refresh_preserves_order_and_pin_keeps_identity(self):
        a = row("a", group="work", list_scope="fixture", source_order=0)
        b = row("b", group="queue", list_scope="fixture", source_order=1)
        targets = lambda items: [e["target"] for e in v.visible(items, "", set()) if e["kind"] == "sess"]
        self.assertEqual(targets([a, b]), ["a", "b"])
        a.update(group="queue", source_order=1)
        b.update(group="ask", source_order=0, state="needs")
        self.assertEqual(targets([b, a]), ["a", "b"])
        b["group"] = "pin"
        self.assertEqual(targets([b, a]), ["b", "a"])
        b["group"] = "queue"
        self.assertEqual(targets([b, a]), ["a", "b"])

    def test_board_reserved_is_not_pending_start(self):
        v._BOARD["lang"] = "zh"
        board = dict(rows=[dict(id="reserved", tag="queued", group="queue"),
                           dict(id="starting", tag="starting", group="queue"),
                           dict(id="loop", tag="looping", state="idle", group="work")])
        groups, _ = v.board_apply(board, {g: [] for g in v.GROUPS}, [], [], "node", "user")
        rows = {e["fid"]: e for es in groups.values() for e in es}
        self.assertEqual(v.task_status(rows["reserved"]), "quiet")
        self.assertEqual(v.task_status(rows["starting"]), "pending")
        self.assertEqual(v.task_status(rows["loop"]), "quiet")

    def test_either_observation_source_lost_hides_running(self):
        for local_lost, hub_lost in ((False, True), (True, False)):
            e = row("@1", fid="same", state="working", lost=local_lost)
            groups = {g: [] for g in v.GROUPS}
            groups["work"] = [e]
            board = dict(rows=[dict(id="same", group="work", tag="working", state="working", running=True, lost=hub_lost)])
            got, _ = v.board_apply(board, groups, [], [], "node", "user")
            self.assertTrue(got["work"][0]["lost"])
            self.assertEqual(v.task_status(got["work"][0]), "quiet")
            self.assertIn("运行情况未知", v.note_of(got["work"][0])[0])

    def test_recurring_and_one_shot_marks_are_distinct(self):
        self.assertTrue(v.recurring_plan("id=job@999 cron=job@*/5_*_*_*_*", 100))
        self.assertFalse(v.recurring_plan("id=job@99 cron=job@*/5_*_*_*_*", 100))
        self.assertFalse(v.recurring_plan("id=job@999 at=job@500", 100))
        self.assertFalse(v.recurring_plan("next=500 ttl=400", 100))

    def test_inventory_optional_native_facts_preserve_older_shape(self):
        from fleet_hub_common import inventory_row
        base = ["@1", "", "1", "/work", "needs", "claude", "a1", "", "o/r", "scratch-1", "", "", ""]
        keys = "busy born cfg title reap detail role epic epicstale backfill ctxleft ctxband ctxts model effort agentstatus test orphanrep pin notices reapwhy origin cantalk park".split()
        old = base + [k + "=" for k in keys]
        before, oldfacts = inventory_row(old)
        after, facts = inventory_row(old + ["loop=1", "nativewait=bg,loop"])
        self.assertEqual(before, after)
        self.assertNotIn("loop", oldfacts)
        self.assertTrue(facts["loop"])
        self.assertEqual(facts["native_wait"], "bg,loop")
        self.assertIs(inventory_row(old + ["loop=0", "nativewait="])[1]["loop"], False)
        self.assertNotIn("loop", inventory_row(old + ["loop=unknown", "nativewait="])[1])

    def test_stop_uses_identity_without_reap_confirmation(self):
        e = row("@1", fid="test-id", far=False, gone=False, state="working")
        page = {a["id"]: (a, why) for a, _, why in v.page_of(e)}
        self.assertNotIn("reap", page)
        stop, why = page["stop"]
        self.assertFalse(why)
        self.assertIsNone(v.act_ask(stop, e))
        self.assertEqual(stop["local"](e, "", "fixture"), "taskstop")
        pending = row("id:pending", record_only=True, pending_start=True)
        a, _, why = v.page_of(pending)[0]
        self.assertEqual(a["id"], "stop")
        self.assertIn("请刷新核对", why)

    def pending(self, **facts):
        return row("id:reserved-fid", task="T17", record_only=True, pending_start=True,
                   pending_start_explicit=True, **facts)

    def test_cancel_start_only_for_explicit_pending_records(self):
        e = self.pending()
        a, label, why = v.page_of(e)[0]
        self.assertEqual((a["id"], label, why), ("cancelstart", "取消启动", ""))
        self.assertEqual(v.menu_of(e)[0][0]["id"], "cancelstart")
        for changed in (dict(task=""), dict(task="id:T17"), dict(task=17), dict(record_only=False),
                        dict(pending_start=False), dict(pending_start_explicit=False),
                        dict(worker_id="fleet/fid"), dict(lost=True), dict(gone=True), dict(running=True)):
            with self.subTest(changed=changed):
                r = dict(e, **changed)
                self.assertEqual(task_control.pending_start_task(r), "")
                self.assertNotIn("cancelstart", [a["id"] for a, _, why in v.page_of(r) if not why])

    def test_cli_reuses_board_projection_without_guessing_task_from_key(self):
        pending = dict(id="reserved-fid", task="T17", code="AB12", title="Queued work",
                       group="queue", tag="starting", pending_start=True, running=False)
        board = dict(rows=[pending, dict(pending, id="legacy", task="T18", pending_start=False),
                          dict(pending, id="live", task="T19", worker_id="fleet/live"),
                          dict(pending, id="id:T20", task=""),
                          {k: val for k, val in dict(pending, id="old", task="T21").items() if k != "pending_start"}])
        with patch.object(v, "board_read", return_value=board):
            rs = cli.pending_rows([])
        self.assertEqual([r["task"] for r in rs], ["T17"])
        self.assertEqual(cli.resolve(rs, "T17")[0], rs)
        self.assertEqual(cli.resolve(rs, "AB12")[0], rs)
        with patch.object(v, "board_read", return_value=board):
            known = [dict(key="@1", fleet_id="reserved-fid")]
            self.assertEqual(cli.pending_rows(known), known)
        with patch.object(v, "board_read", return_value=None):
            self.assertEqual(cli.pending_rows([]), [])

    def test_pending_mutation_uses_fresh_generation_and_owner_scoped_reader(self):
        t = dict(id="T17", authority_version=1, generation=4, state="starting")
        with patch.object(task_control, "call", side_effect=[{"task": t}, {"id": "T17", "state": "cancelled"}]) as call:
            rc, said = task_control.cancel_pending_start("T17")
        self.assertEqual(rc, 0)
        self.assertIn("不表示已确认远端进程退出", said)
        self.assertEqual(call.call_args_list[0].args[:2], ("get", "T17"))
        action, task, body = call.call_args_list[1].args
        self.assertEqual((action, task, body["generation"], body["expected_worker"], body["state"]),
                         ("mutate", "T17", 4, "", "cancelled"))
        self.assertTrue(body["idempotency_key"].startswith("cancel-start:"))
        self.assertNotIn("owner", body)  # Never substitute an owner supplied by a cached row.

    def test_opened_or_failed_cancellation_never_claims_stop(self):
        base = dict(id="T17", authority_version=1, generation=1, state="starting")
        for view in ({"task": dict(base, worker_id="fleet/fid")}, {"task": base, "started": {"segments": 1}},
                     {"task": base, "live": {"state": "idle"}}, {"task": dict(base, outcome="succeeded")},
                     {"task": dict(base, state="running")}, {"task": dict(base, authority_version=0)}):
            with self.subTest(view=view), patch.object(task_control, "call", return_value=view) as call:
                rc, said = task_control.cancel_pending_start("T17")
                self.assertEqual(rc, 1)
                self.assertIn("刷新", said)
                self.assertEqual(call.call_count, 1)
        # The session can open after GET: the mutation's 409 is not a stop receipt.
        with patch.object(task_control, "call", side_effect=[{"task": base}, ValueError("409 ID_SWITCH")]):
            rc, said = task_control.cancel_pending_start("T17")
            self.assertEqual(rc, 1)
            self.assertIn("取消启动未确认", said)
            self.assertIn("执行停止", said)
        with patch.object(task_control, "call", side_effect=OSError("offline")):
            self.assertEqual(task_control.cancel_pending_start("T17")[0], 1)
        with patch.object(task_control, "call", side_effect=[{"task": base}, {"id": "T18", "state": "cancelled"}]):
            self.assertEqual(task_control.cancel_pending_start("T17")[0], 1)
        with patch.object(task_control, "call", return_value={"task": dict(base, state="cancelled")}) as call:
            self.assertEqual(task_control.cancel_pending_start("T17")[0], 0)
            self.assertEqual(call.call_count, 1)

    def test_panel_and_cli_share_cancel_action_while_live_rows_still_stop(self):
        pending = self.pending(far=True)
        with patch.object(v, "cancel_pending_start", return_value=(0, "cancelled")) as cancel, \
                patch.object(v, "hub_reread"):
            self.assertEqual(v.act_run(qo, "view", "fleet", v.ACTION["cancelstart"], pending, ""),
                             (0, "cancelled", False))
            cancel.assert_called_once_with("T17", "zh")
        with patch.object(cli, "cancel_pending_start", return_value=(0, "cancelled")) as cancel, \
                patch.object(cli, "hub_write", side_effect=AssertionError("must not stop a guessed session")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.stop_row(pending), 0)
            cancel.assert_called_once_with("T17")
        live = dict(key="wid:fleet/fid", name="live", task="T17", state="idle", pending_start=True)
        with patch.object(task_control, "call", return_value={"task": {"id": "T17"}}), \
                patch.object(cli, "cancel_pending_start", side_effect=AssertionError("live task cannot cancel start")), \
                patch.object(cli, "hub_write", return_value=(True, "accepted")) as stop, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.stop_row(live), 0)
            stop.assert_called_once_with("worker_stop", {"worker_id": "fleet/fid"}, wait=90)


if __name__ == "__main__":
    unittest.main()
