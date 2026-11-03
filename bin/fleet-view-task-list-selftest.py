#!/usr/bin/env python3
# selftest-entry
"""Task list contract: stable flat rows, one status slot, history and stop.
No live hub, tmux server, credentials or agent processes are used.
"""
import importlib.util
import contextlib
import io
import json
import time
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

    def test_turn_activity_reorders_live_and_history_but_not_pin(self):
        items = [row("pin-a", group="pin", activity_at=1), row("pin-b", group="pin", activity_at=99),
                 row("a", activity_at=10, list_scope="turns"), row("b", activity_at=20, list_scope="turns"),
                 row("old-a", sec="gone", activity_at=30), row("old-b", sec="gone", activity_at=5)]
        targets = lambda rows: [e["target"] for e in v.task_list(rows) if e["kind"] == "sess"]
        self.assertEqual(targets(items), ["pin-a", "pin-b", "b", "a", "old-a", "old-b"])
        items[2]["activity_at"] = 40
        self.assertEqual(targets(items), ["pin-a", "pin-b", "a", "b", "old-a", "old-b"])
        items[3]["state"] = "needs"
        self.assertEqual(targets(items), ["pin-a", "pin-b", "a", "b", "old-a", "old-b"])
        items[2]["activity_at"] = 20
        self.assertEqual(targets(items), ["pin-a", "pin-b", "a", "b", "old-a", "old-b"])

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
        # one order (task DDBQ): asking is not a group; with no activity the source order holds
        self.assertEqual([e["target"] for e in shown if e["kind"] == "sess"], ["driver", "member", "ask"])
        self.assertFalse(any(e["kind"] in ("ask", "cmd") for e in shown))
        self.assertTrue(all(not e.get("depth") and not e.get("fold") and not e.get("epic") for e in shown))
        rendered = "".join(t for t, _ in v.row_segs(items[2], 80, qo.cells, qo.clip))
        self.assertNotIn("1/2", rendered)
        self.assertNotIn("▸", rendered)
        self.assertEqual(v.visible([row("plain")], "", set())[0]["kind"], "sess")

    def test_folded_running_session_keeps_live_actions(self):
        items = [row(str(i), state="working", activity_at=100-i) for i in range(12)]
        folded = [e for e in v.compact_task_list(items, now=200) if e.get("target") == "11"][0]
        self.assertEqual(folded["sec"], "gone")
        self.assertTrue(v.live(folded))
        self.assertFalse(v.ended(folded), "list overflow is not lifecycle completion")
        self.assertFalse(items[-1].get("sec"))
        history = row("history", sec="gone", gone=True, state="done")
        current = [e for e in v.compact_task_list([history], current="history") if e["kind"] == "sess"][0]
        self.assertTrue(v.ended(current), "viewing history never makes it live")

    def test_shared_compact_policy(self):
        # Shared with extras/web-console/test/session-list.mjs.
        fixtures = BIN.parent / "extras/web-console/test/fixtures/session-list-policy.json"
        for c in json.loads(fixtures.read_text()):
            with self.subTest(c["name"]):
                items = [row(r["id"], state=r["state"], group=r["group"], activity_at=r["activity_at"], source=r.get("source", ""),
                             sec="gone" if r["group"] == "gone" else "", gone=r["group"] == "gone",
                             running=r["state"] == "working", lost=r["state"] == "unknown") for r in c["rows"]]
                projected = v.compact_task_list(items, c.get("current", ""), c.get("preferences"), c["now"])
                sessions = [e for e in projected if e["kind"] == "sess"]
                # a session's own rows are ordinary rows now (the session tree): no
                # 「会话派出的」 section — read past them where the fixture still folds them
                spawned = set(c["sources"].get("agent", []))
                self.assertFalse(any(e.get("sec") == "src-agent" for e in projected))
                self.assertTrue(all(not e.get("sec", "").startswith("src-") for e in sessions if e["target"] in spawned))
                self.assertEqual([e["target"] for e in sessions if not e.get("sec") and e["target"] not in c.get("shown_in_group", [])
                                  and e["target"] not in spawned], c["visible"])
                self.assertEqual([e["target"] for e in sessions if e.get("sec") == "gone" and e["target"] not in spawned], c["more"])
                self.assertEqual([e["target"] for e in sessions if v.needs_attention(e)], c["attention"])
                for k in v.SECTION_SOURCES:
                    at = next((i for i, e in enumerate(projected) if e.get("sec") == "src-" + k and e["kind"] == "sec"), None)
                    members = [e["target"] for e in projected[at + 1:at + 1 + len(c["sources"].get(k, []))]] if at is not None else []
                    self.assertEqual(members, c["sources"].get(k, []), k)
                    self.assertTrue(all(e.get("sec") == "src-" + k or e["target"] in c.get("shown_in_group", [])
                                        for e in sessions if e["target"] in c["sources"].get(k, [])), k)
                self.assertEqual(len({e["target"] for e in sessions}), len(items))
                self.assertEqual([e.get("sec") for e in items], ["gone" if r["group"] == "gone" else "" for r in c["rows"]], "folding never mutates source lifecycle")

    def test_schedule_runs_fold_per_schedule(self):
        # X24T: inside 定时任务 one schedule is one line — session-list.ts scheduleRuns
        self.assertEqual(v.schedule_label("LivePage 模板工厂 10-30 #2"), "LivePage 模板工厂")
        self.assertEqual(v.schedule_label("daily-2026-10-31"), "daily")
        self.assertEqual(v.schedule_label("10-30"), "10-30")
        run = lambda t, title, at, **x: row(t, text=title, name=title, source="schedule", activity_at=at, **x)
        items = [run("a3", "Brief 10-31", 9, schedule_id="s1"), run("d2", "daily-2026-10-31", 8),
                 run("a2", "Brief 10-30", 7, schedule_id="s1", state="needs"), run("a1", "Brief 10-29", 6, schedule_id="s1"),
                 run("d1", "daily-2026-10-30", 5), run("b1", "Brief 10-28", 4, schedule_id="s2")]
        targets = lambda opened: [e.get("target") or e["text"] for e in v.visible(items, "", opened) if e.get("sec", "").startswith(("src-", "sched-")) or e["kind"] == "sess"]
        self.assertEqual(targets(set()), ["定时任务 · 6 · 1 个在问你"])
        self.assertEqual(targets({"src-schedule"}), ["定时任务 · 6 · 1 个在问你", "a3", "a2", "  Brief · 1 次更早运行",
                                                     "d2", "  daily · 1 次更早运行", "b1"])
        self.assertEqual(targets({"src-schedule", "sched-s1"})[:5], ["定时任务 · 6 · 1 个在问你", "a3", "a2", "  Brief · 1 次更早运行", "a1"])
        self.assertNotIn("a1", targets({"sched-s1"}), "a run folds with its group too")
        self.assertIn("a1", [e["target"] for e in v.visible(items, "", set(), current="a1") if e["kind"] == "sess"],
                      "the run open now is never folded")

    def test_history_and_search_preserve_fold(self):
        items = [row("old", sec="gone", gone=True), row("exited", state="exited", sec="gone", shut=True),
                 row("loop", loop=True, sec="gone"), row("lost", lost=True, sec="gone")]
        closed = v.visible(items, "", set())
        self.assertEqual([e["target"] for e in closed if e["kind"] == "sess"], ["exited", "loop", "lost"])
        self.assertEqual(closed[-1]["text"], "更多会话 · 1")
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
        self.assertEqual(targets([b, a]), ["a", "b"], "a state change alone never moves a row (DDBQ)")
        b["group"] = "pin"
        self.assertEqual(targets([b, a]), ["b", "a"])
        b["group"] = "queue"
        self.assertEqual(targets([b, a]), ["a", "b"])
        # entering needs is activity (set-claude-state stamps @turn_activity_at): it rises by time
        t = int(time.time())
        a["activity_at"], b["activity_at"] = t - 30, t - 20
        self.assertEqual(targets([b, a]), ["b", "a"])
        a["activity_at"] = t - 10
        self.assertEqual(targets([b, a]), ["a", "b"], "a newer turn passes an asking row")

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
        _, facts = inventory_row(old + ["loop=0", "nativewait=", "activity=1792800000"])
        self.assertEqual(facts["activity_at"], 1792800000)
        self.assertIs(facts["loop"], False)
        for value in ("", "0", "-1", "NaN", "999999999999999"):
            self.assertNotIn("activity_at", inventory_row(old + ["loop=0", "nativewait=", "activity=" + value])[1])

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


class SessionArchive(unittest.TestCase):
    def test_running_pinned_current_session_stays_archived(self):
        a = row("a", archived=True, board="fid-a", group="pin", state="working", running=True)
        b = row("b", state="idle")
        for current in ("", "a"):
            shown = v.visible([a, b], "", set(), current=current, selected="a")
            self.assertNotIn("a", [r.get("target") for r in shown])
            self.assertIn("archived", [r.get("sec") for r in shown])
        self.assertNotIn("a", [r.get("target") for r in v.visible([a,b], "a", set())])
        self.assertIn("a", [r.get("target") for r in v.visible([a,b], "a", {"archived"})])
        self.assertIn("a", [r.get("target") for r in v.visible([a,b], "", {"archived"})])
        for e in (a, dict(a, record_only=True), dict(a, gone=True, home=True, ledger=True, fid="fid-a", target="id:fid-a")):
            self.assertIn("archive", [act["id"] for act, label in v.menu_of(e)])
            with patch.object(v,"reopen_why",return_value="offline"):
                self.assertIn("archive", [act["id"] for act, label, why in v.page_of(e) if not why])
        argv = v.archive_action(a, "", "fleet")
        self.assertEqual(json.loads(argv[-1]), {"id": "fid-a", "archived": False})

    def test_archive_waits_for_saved_result_even_on_offline_rows(self):
        import subprocess
        e = row("id:fid-a", archived=False, board="fid-a", far=True, lost=True)
        for rc in (0,1):
            result = subprocess.CompletedProcess([],rc,'{"status":"succeeded"}' if rc==0 else '', 'save refused' if rc else '')
            with patch.object(v,"ui_lang",return_value="zh"), patch.object(v,"say",side_effect=lambda key,*args:key), \
                    patch.object(v.subprocess,"run",return_value=result) as run, patch.object(v,"act_env",return_value={}), patch.object(v,"hub_reread") as refresh:
                got = v.act_run(qo,"view","fleet",v.ACTION["archive"],e,"",wait=False)
                self.assertEqual(got[0],rc)
                run.assert_called_once()
                self.assertEqual(refresh.called,rc==0)

    def test_archive_stops_first_and_asks_only_while_running(self):
        # Archive = stop + hide (task DDBQ).
        import subprocess
        idle = row("@1", board="fid-i", fid="fid-i", state="idle")
        busy = row("@2", board="fid-b", fid="fid-b", state="working", running=True)
        gone = row("id:fid-g", board="fid-g", gone=True, sec="gone", state="done")
        # ui_lang() asks fleet-ui-lang.sh through subprocess.run when FLEET_UI_LANG is
        # unset (the gate's scrubbed environment): pinned, so only the archive counts
        with patch.object(v, "live", side_effect=lambda r: not r.get("gone")), patch.object(v, "ui_lang", return_value="zh"):
            self.assertTrue(v.archive_stops(idle))
            self.assertIsNone(v.archive_ask(idle), "an idle one just goes")
            self.assertEqual(v.archive_ask(busy), "key", "a running one asks first")
            self.assertFalse(v.archive_stops(dict(busy, archived=True)), "unarchive stops nothing")
            self.assertFalse(v.archive_stops(gone))
            saved = subprocess.CompletedProcess([], 0, "", "")
            calls = []
            with patch.object(v, "stop_task", side_effect=lambda r, *a, **k: calls.append("stop") or (0, "ok")), \
                    patch.object(v.subprocess, "run", side_effect=lambda *a, **k: calls.append("archive") or saved), \
                    patch.object(v, "act_env", return_value={}), patch.object(v, "hub_reread"), \
                    patch.object(v, "say", side_effect=lambda key, *args: key):
                self.assertEqual(v.act_run(qo, "view", "fleet", v.ACTION["archive"], idle, "", wait=False)[0], 0)
                self.assertEqual(calls, ["stop", "archive"], "stop first, then archive")
                calls.clear()
            with patch.object(v, "stop_task", return_value=(1, "refused")), \
                    patch.object(v.subprocess, "run", side_effect=lambda *a, **k: calls.append("archive") or saved), \
                    patch.object(v, "act_env", return_value={}), patch.object(v, "say", side_effect=lambda key, *args: key):
                self.assertEqual(v.act_run(qo, "view", "fleet", v.ACTION["archive"], idle, "", wait=False)[0], 1)
                self.assertEqual(calls, [], "a stop that fails archives nothing")
        live_row = dict(key="@3", name="w3", state="working", running=True, board="fid-c", archived=False)
        with patch.object(cli, "rows", return_value=[live_row]), patch.object(cli, "one", return_value=(live_row, 0)), \
                patch.object(cli, "stop_row", return_value=0) as stop, patch.object(cli, "hub_write", return_value=(True, "ok")) as write, \
                patch.object(cli, "hub_freshen"), contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            with patch.object(cli, "ask", return_value="n"):
                self.assertEqual(cli.cmd_archive(["w3"]), 1)
                stop.assert_not_called(); write.assert_not_called()
            with patch.object(cli, "ask", return_value=None):
                self.assertEqual(cli.cmd_archive(["w3"]), 2, "no terminal: --yes")
            self.assertEqual(cli.cmd_archive(["--yes", "w3"]), 0)
            stop.assert_called_once(); write.assert_called_once_with("session_archive", {"id": "fid-c", "archived": True})

    def test_cli_archives_are_explicit_and_use_stable_identity(self):
        board = {"rows": [{"id":"fid-a", "code":"AB12", "title":"Old archive", "group":"gone", "archived":True, "state":"exited"}]}
        with patch.object(v, "board_read", return_value=board):
            rs = cli.pending_rows([])
        self.assertEqual(rs[0]["state"], "exited")
        self.assertTrue(rs[0]["archived"])
        with patch.object(cli, "rows", return_value=rs), patch.object(cli, "attach_bus", side_effect=lambda x:x), patch.object(cli,"hub_freshen"):
            for args, want in ((["--json"],0),(["--all","--json"],0),(["--archived","--json"],1)):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(cli.cmd_ls(args), 0)
                self.assertEqual(len(json.loads(out.getvalue())), want)
            with patch.object(cli, "hub_write", return_value=(True,"ok")) as write, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.cmd_archive(["AB12"], False), 0)
                write.assert_called_once_with("session_archive", {"id":"fid-a", "archived":False})
            with patch.object(cli, "hub_write", return_value=(False,"offline")), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cli.cmd_archive(["AB12"]), 1)


class SessionTree(unittest.TestCase):
    """A session opened by another session sits under it (the session tree):
    drawn inside the title column, folded by ▸ / ▾, never hiding a question."""

    def setUp(self):
        v._TASK_ORDER.clear()
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"FLEET_UI_LANG": "zh", "FLEET_CONF_DIR": self.tmp.name})
        self.env.start()
        os.environ.pop("FLEET_GLYPHS", None)
        os.environ.pop("NO_COLOR", None)
        os.environ.pop("FLEET_COLOR", None)
        v.caches_words_reset()
        v._BOARD["lang"] = "zh"
        self.now = time.time()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def node(self, t, parent="", **facts):
        facts.setdefault("activity_at", self.now - 60)
        return row(t, board=t, fid=t, tree_parent=parent, **facts)

    def family(self, deep=None, **child):
        return [self.node("P", text="父会话 中文标题"),
                self.node("A", "P", text="子任务 甲", **child),
                self.node("B", "P", text="子任务 乙"),
                self.node("C", "A", text="孙 一"),
                self.node("D", "C", text="曾孙 二", **(deep or {})),
                self.node("Q", text="plain")]

    @staticmethod
    def drawn(e, width=100):
        return "".join(t for t, _ in v.paint([e], -1, width, qo.cells, qo.clip)[0])

    @staticmethod
    def sess(items, query="", **kw):
        return [e for e in v.visible(items, query, set(), **kw) if e["kind"] == "sess"]

    def test_nesting_and_alignment_with_cjk_titles(self):
        items = self.family(deep=dict(state="working", running=True))
        shown = self.sess(items)
        self.assertEqual([e["target"] for e in shown], ["P", "A", "C", "D", "B", "Q"],
                         "children under their opener, a third level drawn at the second")
        prefix = {e["target"]: e.get("tree_prefix") for e in shown}
        self.assertEqual(prefix, {"P": "", "A": "  ├ ", "C": "  │   ├ ", "D": "  │   └ ", "B": "  └ ", "Q": ""})
        self.assertEqual([e["tree_twisty"] for e in shown], ["open", "open", "", "", "", ""])
        for width in (100, 72, 60, 45):
            lines = [self.drawn(e, width) for e in shown]
            self.assertTrue(all(qo.cells(x) == width for x in lines), (width, lines))
            # the repo column starts at the same cell on every row, CJK titles or not
            repo_x = {qo.cells(x[:x.rindex("test")]) for x in lines} if width >= 60 else {0}
            self.assertEqual(len(repo_x), 1, lines)
        lines = [self.drawn(e) for e in shown]
        col = v.name_col(100)
        self.assertEqual(lines[0][col:col + 2], "▾ ")
        self.assertTrue(lines[0][col + 2:].startswith("父会话 中文标题"))
        self.assertTrue(lines[1][col:].startswith("  ├ ▾ 子任务 甲"))
        self.assertTrue(lines[2][col:].startswith("  │   ├   孙 一"))
        self.assertTrue(lines[4][col:].startswith("  └   子任务 乙"))
        self.assertTrue(lines[5][col:].startswith("  plain"), "a lone row keeps the two-cell slot")
        # no new column, no session ID on the row
        self.assertNotIn("AB12", "".join(lines))

    def test_ascii_glyphs(self):
        with patch.dict(os.environ, {"FLEET_GLYPHS": "ascii"}):
            shown = self.sess(self.family(deep=dict(state="working", running=True)))
            self.assertEqual(shown[1]["tree_prefix"], "  |-")
            self.assertEqual(shown[2]["tree_prefix"], "  |   |-")
            self.assertIn("v 父会话", self.drawn(shown[0]))

    def test_default_fold_and_hidden_count(self):
        shown = self.sess(self.family())
        self.assertEqual([e["target"] for e in shown], ["P", "Q"], "nothing running under it: shut")
        self.assertEqual(shown[0]["tree_twisty"], "shut")
        self.assertEqual(shown[0]["tree_hidden_n"], 4)
        line = self.drawn(shown[0])
        self.assertIn("▸ 父会话 中文标题 (4)", line)
        # the hidden rows are still searchable, drawn flat
        hit = self.sess(self.family(), "曾孙")
        self.assertEqual([e["target"] for e in hit], ["D"])
        self.assertTrue(self.drawn(hit[0])[v.name_col(100):].startswith("  曾孙 二"))
        # pending under it opens it too
        shown = self.sess(self.family(pending_start=True))
        self.assertEqual(shown[0]["tree_twisty"], "open")
        # the person's choice wins, either way
        self.assertEqual([e["target"] for e in self.sess(self.family(), folds={"P": True})], ["P", "A", "B", "Q"])
        self.assertEqual([e["target"] for e in self.sess(self.family(), folds={"P": True, "A": True})],
                         ["P", "A", "C", "D", "B", "Q"])
        shut = self.sess(self.family(state="working", running=True), folds={"P": False})
        self.assertEqual([e["target"] for e in shut], ["P", "Q"])

    def test_working_twisty_colour(self):
        shut = self.sess(self.family(state="working", running=True), folds={"P": False})
        segs = v.row_segs(shut[0], 100, qo.cells, qo.clip)
        tw = next(st for t, st in segs if t == "▸ ")
        self.assertIn("c2", tw)
        self.assertNotIn("dim", tw)
        quiet = self.sess(self.family())
        tw = next(st for t, st in v.row_segs(quiet[0], 100, qo.cells, qo.clip) if t == "▸ ")
        self.assertIn("dim", tw)
        self.assertNotIn("c2", tw)
        with patch.dict(os.environ, {"NO_COLOR": "1"}):
            tw = next(st for t, st in v.row_segs(shut[0], 100, qo.cells, qo.clip) if t == "▸ ")
            self.assertNotIn("c2", tw)

    def test_asking_descendant_never_hidden_nor_folded_away(self):
        items = self.family()
        items[4].update(state="needs")          # D, three levels down, asks
        shown = self.sess(items, folds={"P": False, "A": False})
        self.assertEqual([e["target"] for e in shown], ["P", "A", "D", "Q"])
        self.assertEqual(shown[0]["tree_hidden_n"], 2, "B and C hidden, D shown")
        # asking: red/bold title as well as the glyph — no words added
        segs = v.row_segs(shown[2], 100, qo.cells, qo.clip)
        title = next(st for t, st in segs if t.startswith("曾孙"))
        self.assertIn("c1", title)
        self.assertIn("bold", title)
        self.assertNotIn("在问", self.drawn(shown[2]))
        # an old tree holding a question never goes to 更多会话
        for e in items:
            e["activity_at"] = self.now - 3 * 86400
        shown = self.sess(items)
        self.assertEqual([e["target"] for e in shown][:1], ["P"])
        self.assertTrue(all(not e.get("sec") for e in shown if e["target"] in ("P", "A", "D")))

    def test_arrow_and_g_keys(self):
        shown = self.sess(self.family(deep=dict(state="working", running=True)))
        by = {e["target"]: e for e in shown}
        self.assertEqual(v.tree_arrow(by["P"], True), ("P", True))
        self.assertEqual(v.tree_arrow(by["P"], False), ("P", False))
        self.assertEqual(v.tree_arrow(by["B"], False), ("P", False), "← on a child: its parent, shut")
        self.assertIsNone(v.tree_arrow(by["B"], True), "→ on a leaf does nothing")
        self.assertEqual(v.tree_arrow(by["C"], False), ("A", False))
        self.assertIsNone(v.tree_arrow(by["Q"], False))
        # g: the row of the session that opened it — D's opener is C, drawn beside it
        self.assertEqual(by["D"]["tree_opener"], "C")
        self.assertEqual(by["D"]["tree_opener_title"], "孙 一")
        self.assertEqual(by["B"]["tree_opener"], "P")
        self.assertEqual(v.tree_at_row(shown, by["B"]["tree_opener"], 4), 0)
        self.assertEqual(by["P"]["tree_opener"], "")
        # remembered per view; a row no longer listed is dropped from the book
        items = self.family()
        folds = v.tree_toggle({"gone-row": True}, "fx", "P", True, items)
        self.assertEqual(folds, {"P": True})
        self.assertEqual(v.tree_folds_load("fx"), {"P": True})
        self.assertEqual(v.tree_folds_load("other"), {})
        # the keys line words
        self.assertEqual(v.say("view_keys_tree_child_fmt", "孙 一"), "来自 孙 一  g 跳到它")

    def test_from_sessions_section_is_gone(self):
        items = [self.node("mine"), self.node("bot", source="agent"), self.node("job", source="schedule")]
        out = v.compact_task_list(items, now=self.now)
        self.assertFalse(any(e.get("sec") == "src-agent" for e in out))
        self.assertNotIn("会话派出的", " ".join(e.get("text") or "" for e in out if e["kind"] == "sec"))
        self.assertEqual([e["target"] for e in v.visible(items, "", set()) if e["kind"] == "sess"], ["bot", "mine"])
        self.assertIn("src-schedule", [e.get("sec") for e in out if e["kind"] == "sec"], "schedules keep their section")

    def test_live_child_under_ended_parent(self):
        v._BOARD["lang"] = "zh"
        board = dict(rows=[dict(id="old", title="老会话", group="gone", tag="ended"),
                           dict(id="kid", title="还在跑", group="work", tag="working", state="working", running=True,
                                **{"from": "old", "from_title": "老会话", "from_ended": True, "tree_at": 99}),
                           dict(id="sub", title="子", group="work", tag="working", state="working", running=True,
                                parent="kid", depth=1, **{"from": "kid"})])
        groups, gone = v.board_apply(board, {g: [] for g in v.GROUPS}, [], [], "node", "user")
        kid = next(e for es in groups.values() for e in es if e["fid"] == "kid")
        self.assertEqual((kid["from"], kid["from_title"], kid["from_ended"], kid["tree_at"], kid["tree_parent"]),
                         ("old", "老会话", True, 99, ""))
        items = [e for es in groups.values() for e in es] + gone
        shown = v.visible(items, "", set())
        kinds = [(e["kind"], e.get("target") or e.get("of")) for e in shown]
        at = kinds.index(("sess", "id:kid"))
        self.assertEqual(kinds[at + 1], ("from", "id:kid"))
        self.assertEqual(kinds[at + 2], ("sess", "id:sub"), "the hub's parent nests it")
        line = self.drawn(shown[at + 1])
        self.assertEqual(line.strip(), "来自 老会话（已结束）")
        self.assertTrue(line.startswith(" " * (v.name_col(100) + 2) + "来自"))
        self.assertFalse(v.pickable(shown[at + 1]))
        with patch.dict(os.environ, {"FLEET_UI_LANG": "en"}):
            v.caches_words_reset()
            self.assertEqual(v.say("view_from_ended_fmt", "old"), "From old (ended)")
        v.caches_words_reset()
        # no title, no line
        kid2 = dict(kid, from_title="")
        self.assertFalse(any(e["kind"] == "from" for e in v.visible([kid2], "", set())))

    def test_local_rows_nest_by_from_fid(self):
        # no hub: a window's @from_fid names its opener among the rows here
        parent = row("@1", fid="f1", state="working", running=True)
        child = row("@2", fid="f2", state="working", running=True)
        child["from"] = "f1"
        ended = row("@3", fid="f3", ended=True, text="结束的")
        orphan = row("@4", fid="f4")
        orphan["from"] = "f3"
        shown = v.visible([parent, child, ended, orphan], "", set())
        sess = [e for e in shown if e["kind"] == "sess"]
        by = {e["target"]: e for e in sess}
        self.assertEqual(by["@2"]["tree_prefix"], "  └ ")
        self.assertEqual(by["@4"]["tree_prefix"], "", "never nested under an ended opener")
        froms = [e for e in shown if e["kind"] == "from"]
        self.assertEqual([(e["of"], e["text"]) for e in froms], [("@4", "来自 结束的（已结束）")])

    def test_old_hub_rows_stay_flat(self):
        board = dict(rows=[dict(id="a", title="a", group="work", tag="working", running=True),
                           dict(id="b", title="b", group="queue", tag="idle", depth=1)])
        groups, gone = v.board_apply(board, {g: [] for g in v.GROUPS}, [], [], "node", "user")
        items = [e for es in groups.values() for e in es]
        shown = v.visible(items, "", set())
        self.assertEqual([(e["kind"], e.get("tree_prefix"), e.get("tree_twisty")) for e in shown],
                         [("sess", "", ""), ("sess", "", "")])

    def test_pin_carries_children_and_roots_order_by_tree_activity(self):
        items = [self.node("old", activity_at=self.now - 500),
                 self.node("kid", "old", activity_at=self.now - 10, state="working", running=True),
                 self.node("new", activity_at=self.now - 100),
                 self.node("pinned", group="pin", activity_at=self.now - 9000),
                 self.node("pkid", "pinned", activity_at=self.now - 20, state="working", running=True)]
        shown = self.sess(items)
        self.assertEqual([e["target"] for e in shown], ["pinned", "pkid", "old", "kid", "new"],
                         "a root rises by its tree's newest activity; PIN carries its children")
        items[1]["tree_at"] = 0
        items[0]["tree_at"] = self.now - 1      # the hub's tree_at wins over the rows here
        self.assertEqual([e["target"] for e in self.sess(items)][2], "old")


if __name__ == "__main__":
    unittest.main()
