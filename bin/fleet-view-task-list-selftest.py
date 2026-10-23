#!/usr/bin/env python3
# selftest-entry
"""Task list contract: stable flat rows, one status slot, history and stop.
No live hub, tmux server, credentials or agent processes are used.
"""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_view as v

spec = importlib.util.spec_from_file_location("quickopen", BIN / "fleet-quickopen.py")
qo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qo)


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
        self.assertEqual(stop["local"](e, "", "fixture")[-2:], ["fixture", "fid:test-id"])
        pending = row("id:pending", record_only=True, pending_start=True)
        a, _, why = v.page_of(pending)[0]
        self.assertEqual(a["id"], "stop")
        self.assertIn("尚不支持撤销待启动请求", why)


if __name__ == "__main__":
    unittest.main()
