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

    def test_no_headings_and_no_tree_or_second_question_line(self):
        items = [dict(kind="hdr", group="work", text="工作"),
                 row("member", group="work", depth=2, fold="driver"),
                 row("driver", group="pin", epic=dict(done=1, total=2), expanded=False),
                 row("ask", state="needs", ask="where?", group="ask"),
                 dict(kind="ask", of="ask", text="where?"),
                 dict(kind="cmd", cmd="reapall", text="legacy cleanup")]
        shown = v.visible(items, "", set())
        self.assertFalse([e for e in shown if e["kind"] == "hdr"], "no PIN heading: a pinned row says ⇡ itself")
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
                # a schedule's own row (synthetic, one per schedule) is not one of the fixture's rows
                sessions = [e for e in projected if e["kind"] == "sess" and not e.get("sched_parent")]
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
                    nxt = next((i for i, e in enumerate(projected) if i > (at or 0) and e["kind"] == "sec"), len(projected))
                    members = [e["target"] for e in projected[at + 1:nxt] if e["kind"] == "sess" and not e.get("sched_parent")
                               ][:len(c["sources"].get(k, []))] if at is not None else []
                    self.assertEqual(members, c["sources"].get(k, []), k)
                    self.assertTrue(all(e.get("sec") == "src-" + k or e["target"] in c.get("shown_in_group", [])
                                        for e in sessions if e["target"] in c["sources"].get(k, [])), k)
                self.assertEqual(len({e["target"] for e in sessions}), len(items))
                self.assertEqual([e.get("sec") for e in items], ["gone" if r["group"] == "gone" else "" for r in c["rows"]], "folding never mutates source lifecycle")

    def test_schedule_label(self):
        self.assertEqual(v.schedule_label("LivePage 模板工厂 10-30 #2"), "LivePage 模板工厂")
        self.assertEqual(v.schedule_label("daily-2026-10-31"), "daily")
        self.assertEqual(v.schedule_label("daily-2026-11-03"), "daily")
        self.assertEqual(v.schedule_label("group-brief-2026-11-03-2"), "group-brief")
        self.assertEqual(v.schedule_label("group-brief-2026-11-03(-2)"), "group-brief")
        self.assertEqual(v.schedule_label("10-30"), "10-30")

    def test_history_and_search_preserve_fold(self):
        items = [row("old", sec="gone", gone=True, activity_at=time.time() - 86401), row("exited", state="exited", sec="gone", shut=True),
                 row("loop", loop=True, sec="gone"), row("lost", lost=True, sec="gone")]
        closed = v.visible(items, "", set())
        self.assertEqual([e["target"] for e in closed if e["kind"] == "sess"], ["exited", "loop", "lost"])
        self.assertEqual(closed[-1]["text"], "更多会话 · 1")
        self.assertEqual([e["target"] for e in v.visible(items, "old", set())], ["old"])
        self.assertEqual(v.visible(items, "", set())[-1]["closed"], True)
        self.assertIn("old", [e.get("target") for e in v.visible(items, "", {"gone"})])

    def test_recent_ended_row_keeps_status_and_restore_in_main_list(self):
        items = [row("id:closed", sec="gone", gone=True, ledger=True, state="exited",
                     activity_at=time.time() - 60),
                 row("legacy", sec="gone", activity_at=time.time() - 120)]
        shown = [e for e in v.visible(items, "", set()) if e["kind"] == "sess"]
        self.assertEqual([e["target"] for e in shown], ["id:closed", "legacy"])
        self.assertTrue(all(not e.get("sec") and v.ended(e) for e in shown))
        self.assertEqual(v.row_status(shown[0]), "quiet")
        self.assertTrue(v.reopen_row(shown[0]))
        self.assertEqual([a["id"] for a, _ in v.menu_of(shown[0])], ["resume"])
        self.assertEqual(items[0]["sec"], "gone", "presentation leaves source facts intact")

    def test_archives_follow_tree_activity_after_refresh(self):
        items = [row("a", archived=True, list_scope="archives", source_order=0, activity_at=100),
                 row("b", archived=True, list_scope="archives", source_order=1, activity_at=200),
                 row("c", archived=True, list_scope="archives", source_order=2, activity_at=50, tree_at=300)]
        targets = lambda: [e["target"] for e in v.visible(items, "", {"archived"}) if e["kind"] == "sess"]
        self.assertEqual(targets(), ["c", "b", "a"])
        items[0]["activity_at"] = 400
        self.assertEqual(targets(), ["a", "c", "b"], "new activity replaces first-seen order")
        items[1]["tree_at"] = 400
        self.assertEqual(targets(), ["a", "b", "c"], "equal activity uses identity")
        items[0]["tree_parent"] = "c"
        items[1]["tree_at"] = 350
        self.assertEqual(targets(), ["a", "c", "b"], "descendants also contribute to archive activity")
        self.assertFalse([e for e in v.visible(items, "", set()) if e["kind"] == "sess"])

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
    drawn inside the title column (status · title · Agent · repo), shut by
    default, a shut ▸ coloured by what it hides, duplicates folded into one."""

    def setUp(self):
        v._TASK_ORDER.clear()
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"FLEET_UI_LANG": "zh", "FLEET_CONF_DIR": self.tmp.name})
        self.env.start()
        for k in ("FLEET_GLYPHS", "NO_COLOR", "FLEET_COLOR"):
            os.environ.pop(k, None)
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

    OPEN = {"P": True, "A": True}

    @staticmethod
    def drawn(e, width=100):
        return "".join(t for t, _ in v.paint([e], -1, width, qo.cells, qo.clip)[0])

    @staticmethod
    def sess(items, query="", **kw):
        return [e for e in v.visible(items, query, set(), **kw) if e["kind"] == "sess"]

    @staticmethod
    def seg(e, text, width=100):
        return next(st for t, st in v.row_segs(e, width, qo.cells, qo.clip) if t == text)

    def test_nesting_columns_and_alignment_with_cjk_titles(self):
        shown = self.sess(self.family(), folds=self.OPEN)
        self.assertEqual([e["target"] for e in shown], ["P", "A", "C", "D", "B", "Q"],
                         "children under their opener, a third level drawn at the second")
        self.assertEqual({e["target"]: e.get("tree_prefix") for e in shown},
                         {"P": "", "A": "  ├ ", "C": "  │   ├ ", "D": "  │   └ ", "B": "  └ ", "Q": ""})
        self.assertEqual([e["tree_twisty"] for e in shown], ["open", "open", "", "", "", ""])
        for width in (100, 72, 60, 45, 39):
            lines = [self.drawn(e, width) for e in shown]
            self.assertTrue(all(qo.cells(x) == width for x in lines), (width, lines))
            # Agent (then repo) is a fixed column after the title: same cell on every row
            if width >= 40:
                agent_x = {qo.cells(x[:x.rindex("Codex")]) for x in lines}
                self.assertEqual(len(agent_x), 1, lines)
                want = width - v.AGENT_W - (v.REPO_W + 2 if width >= 60 else 1)
                self.assertEqual(agent_x, {want}, lines)
            else:
                self.assertNotIn("Codex", "".join(lines))
            if width >= 60:
                self.assertEqual(len({qo.cells(x[:x.rindex("test")]) for x in lines}), 1, lines)
        lines = [self.drawn(e) for e in shown]
        col = v.name_col(100)
        self.assertEqual(col, v.TEXT_X, "the title column starts right after the status slot")
        self.assertEqual(lines[0][col:col + 2], "▾ ")
        self.assertTrue(lines[0][col + 2:].startswith("父会话 中文标题"))
        self.assertTrue(lines[1][col:].startswith("  ├ ▾ 子任务 甲"))
        self.assertTrue(lines[2][col:].startswith("  │   ├   孙 一"))
        self.assertTrue(lines[4][col:].startswith("  └   子任务 乙"))
        self.assertTrue(lines[5][col:].startswith("  plain"), "a lone row keeps the two-cell slot")
        self.assertNotIn("AB12", "".join(lines))

    def test_ascii_glyphs(self):
        with patch.dict(os.environ, {"FLEET_GLYPHS": "ascii"}):
            shown = self.sess(self.family(), folds=self.OPEN)
            self.assertEqual(shown[1]["tree_prefix"], "  |-")
            self.assertEqual(shown[2]["tree_prefix"], "  |   |-")
            self.assertIn("v 父会话", self.drawn(shown[0]))

    def test_default_shut_hides_everything_and_counts(self):
        for facts in ({}, dict(state="working", running=True), dict(pending_start=True), dict(state="needs")):
            shown = self.sess(self.family(**facts))
            self.assertEqual([e["target"] for e in shown], ["P", "Q"], ("always shut by default", facts))
            self.assertEqual((shown[0]["tree_twisty"], shown[0]["tree_hidden_n"]), ("shut", 4))
        self.assertIn("▸ 父会话 中文标题 (4)", self.drawn(self.sess(self.family())[0]))
        # the person's choice is remembered either way
        self.assertEqual([e["target"] for e in self.sess(self.family(), folds={"P": True})], ["P", "A", "B", "Q"])
        self.assertEqual([e["target"] for e in self.sess(self.family(deep=dict(state="needs")), folds={"P": True})],
                         ["P", "A", "B", "Q"], "a question three levels down hides with its shut parent")
        # hidden rows are still searchable, drawn flat
        hit = self.sess(self.family(), "曾孙")
        self.assertEqual([e["target"] for e in hit], ["D"])
        self.assertTrue(hit[0]["tree_hidden"])
        self.assertTrue(self.drawn(hit[0])[v.name_col(100):].startswith("  曾孙 二"))

    def test_shut_twisty_and_count_colour_priority(self):
        quiet = self.sess(self.family())[0]
        self.assertEqual(quiet["tree_tone"], "")
        self.assertIn("dim", self.seg(quiet, "▸ "))
        self.assertIn("dim", self.seg(quiet, " (4)"))
        work = self.sess(self.family(state="working", running=True))[0]
        self.assertEqual(work["tree_tone"], "work")
        self.assertIn("c2", self.seg(work, "▸ "))
        self.assertIn("dim", self.seg(work, " (4)"))
        loop = self.sess(self.family(loop=True))[0]
        self.assertEqual(loop["tree_tone"], "work", "looping counts as working")
        ask = self.sess(self.family(state="working", running=True, deep=dict(state="needs")))[0]
        self.assertEqual(ask["tree_tone"], "ask", "asking wins over working")
        for text in ("▸ ", " (4)"):
            st = self.seg(ask, text)
            self.assertIn("c1", st)
            self.assertIn("bold", st)
        with patch.dict(os.environ, {"NO_COLOR": "1"}):
            self.assertNotIn("c1", self.seg(ask, "▸ "))
        # an asking row: glyph and title red/bold, no words added
        row_ = self.sess(self.family(deep=dict(state="needs")), folds=self.OPEN)[3]
        title = self.seg(row_, "曾孙 二")
        self.assertIn("c1", title)
        self.assertIn("bold", title)

    def test_asking_never_goes_to_more_sessions(self):
        items = self.family(deep=dict(state="needs"))
        for e in items:
            e["activity_at"] = self.now - 3 * 86400
        out = v.compact_task_list(items, now=self.now)
        p = next(e for e in out if e.get("target") == "P")
        self.assertFalse(p.get("sec"), "a tree holding a question stays in the list (shut)")
        self.assertEqual(next(e for e in out if e.get("target") == "Q").get("sec"), "gone")

    def test_arrow_g_and_reveal(self):
        shown = self.sess(self.family(), folds=self.OPEN)
        by = {e["target"]: e for e in shown}
        self.assertEqual(v.tree_arrow(by["P"], True), ("P", True))
        self.assertEqual(v.tree_arrow(by["P"], False), ("P", False))
        self.assertEqual(v.tree_arrow(by["B"], False), ("P", False), "← on a child: its parent, shut")
        self.assertIsNone(v.tree_arrow(by["B"], True), "→ on a leaf does nothing")
        self.assertEqual(v.tree_arrow(by["C"], False), ("A", False))
        self.assertIsNone(v.tree_arrow(by["Q"], False))
        self.assertEqual((by["D"]["tree_opener"], by["D"]["tree_opener_title"]), ("C", "孙 一"))
        self.assertEqual(v.tree_at_row(shown, by["B"]["tree_opener"], 4), 0)
        self.assertEqual(v.say("view_keys_tree_child_fmt", "孙 一"), "来自 孙 一  g 跳到它")
        # remembered per view; a row no longer listed is dropped from the book
        items = self.family()
        self.assertEqual(v.tree_toggle({"gone-row": True}, "fx", "P", True, items), {"P": True})
        self.assertEqual(v.tree_folds_load("fx"), {"P": True})
        self.assertEqual(v.tree_folds_load("other"), {})
        # the cursor lands on a hidden row (a search hit, a jump): its ancestors open
        folds = v.tree_reveal({}, "fy", items, "D")
        self.assertEqual(folds, {"P": True, "A": True})
        self.assertEqual(v.tree_folds_load("fy"), folds)
        self.assertIn("D", [e["target"] for e in self.sess(items, folds=folds)])
        self.assertEqual(v.tree_reveal({"P": True}, "fz", items, "B"), {"P": True}, "a shown row changes nothing")

    def test_duplicates_fold_into_the_newest(self):
        items = [self.node("P", text="driver"),
                 self.node("d1", "P", text="Fix  Tests", activity_at=self.now - 30),
                 self.node("d2", "P", text="fix tests", activity_at=self.now - 10),
                 self.node("d3", "P", text="Fix tests", activity_at=self.now - 20, state="needs"),
                 self.node("other", "P", text="Fix tests", source="api", activity_at=self.now - 5),
                 self.node("solo1", text="same"), self.node("solo2", text="same")]
        for e in items[1:5]:
            e["from"] = "P"
        shown = self.sess(items, folds={"P": True})
        self.assertEqual([e["target"] for e in shown], ["P", "other", "d2", "solo1", "solo2"],
                         "one row per (from, title, source); rows with no `from` never merge")
        d2 = shown[2]
        self.assertEqual(d2["dup_n"], 3)
        self.assertEqual(v.row_status(d2), "needs", "the group's most urgent")
        segs = v.row_segs(d2, 100, qo.cells, qo.clip)
        self.assertEqual(segs[1][0], v.TASK_GLYPHS["needs"])
        self.assertIn("dim", self.seg(d2, " ×3"))
        self.assertIn("fix tests ×3", self.drawn(d2))
        self.assertEqual(shown[0]["tree_hidden_n"], 0)
        # the others are searchable, never drawn; the parent's (N) counts rows, not copies
        hit = self.sess(items, "fix tests", folds={"P": True})
        self.assertEqual(sorted(e["target"] for e in hit), ["d1", "d2", "d3", "other"])
        self.assertNotIn("×", self.drawn([e for e in hit if e["target"] == "d2"][0]))
        shut = self.sess(items)[0]
        self.assertEqual((shut["tree_hidden_n"], shut["tree_tone"]), (2, "ask"))

    def test_from_sessions_section_is_gone_and_section_order(self):
        items = [self.node("mine"), self.node("bot", source="agent"), self.node("job", source="schedule"),
                 self.node("call", source="api", state="working", running=True),
                 self.node("old", activity_at=self.now - 5 * 86400), self.node("arch", archived=True)]
        out = v.compact_task_list(items, now=self.now)
        self.assertFalse(any(e.get("sec") == "src-agent" for e in out))
        self.assertEqual([e["target"] for e in v.visible(items, "", set()) if e["kind"] == "sess"], ["bot", "mine"])
        secs = [e["sec"] for e in out if e["kind"] == "sec"]
        self.assertEqual(secs, ["gone", "src-schedule", "src-api", "archived"], "更多会话 before the source groups")
        heads = {e["sec"]: e for e in v.visible(items, "", set()) if e["kind"] == "sec"}
        self.assertEqual(heads["src-api"]["text"], "API 派发 · 1")
        self.assertEqual(heads["src-api"]["tone"], "work")
        line = v.paint([heads["src-api"]], -1, 60, qo.cells, qo.clip)[0]
        self.assertEqual(line[1], ("▸", ("c2",)))
        self.assertEqual(v.paint([heads["src-schedule"]], -1, 60, qo.cells, qo.clip)[0][1], ("▸", ("dim",)))
        self.assertEqual(qo.cells("".join(t for t, _ in line)), 60)
        ask = [self.node("job2", source="schedule", state="needs")]
        h = next(e for e in v.visible(ask, "", set()) if e["kind"] == "sec")
        self.assertEqual(h["text"], "定时任务 · 1", "no count of questions in words")
        self.assertEqual(v.paint([h], -1, 60, qo.cells, qo.clip)[0][1], ("▸", ("c1", "bold")))

    def test_live_child_under_ended_parent(self):
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
        shown = v.visible(items, "", set(), folds={"kid": True})
        kinds = [(e["kind"], e.get("target")) for e in shown]
        at = kinds.index(("sess", "id:kid"))
        self.assertEqual(kinds[at + 1], ("sess", "id:sub"), "no line under it; the hub's parent nests sub")
        self.assertFalse(any(e["kind"] == "from" for e in shown))
        # who opened it, on the lit row's own line
        self.assertIn("来自 老会话（已结束）", v.note_of(shown[at])[0])
        self.assertNotIn("来自", v.note_of(shown[at + 1])[0])
        with patch.dict(os.environ, {"FLEET_UI_LANG": "en"}):
            v.caches_words_reset()
            self.assertEqual(v.say("view_from_ended_fmt", "old"), "From old (ended)")
        v.caches_words_reset()
        self.assertNotIn("来自", v.note_of(dict(shown[at], from_title=""))[0])

    def test_board_at_falls_back_to_activity(self):
        board = dict(rows=[dict(id="a", title="a", group="work", tag="working", at=0, activity_at=1234),
                           dict(id="b", title="b", group="work", tag="working", activity_at=77),
                           dict(id="c", title="c", group="work", tag="working", at=55, activity_at=77)])
        groups, _ = v.board_apply(board, {g: [] for g in v.GROUPS}, [], [], "node", "user")
        act = {e["fid"]: e.get("act") for es in groups.values() for e in es}
        self.assertEqual(act, {"a": 1234, "b": 77, "c": 55})

    def test_local_rows_nest_by_from_fid(self):
        parent = row("@1", fid="f1", state="working", running=True)
        child = row("@2", fid="f2", state="working", running=True)
        child["from"] = "f1"
        ended = row("@3", fid="f3", ended=True, text="结束的")
        orphan = row("@4", fid="f4")
        orphan["from"] = "f3"
        sess = self.sess([parent, child, ended, orphan], folds={"f1": True})
        by = {e["target"]: e for e in sess}
        self.assertEqual(by["@2"]["tree_prefix"], "  └ ")
        self.assertEqual(by["@4"]["tree_prefix"], "", "never nested under an ended opener")
        self.assertIn("来自 结束的（已结束）", v.note_of(by["@4"])[0])

    def test_old_hub_rows_stay_flat(self):
        board = dict(rows=[dict(id="a", title="a", group="work", tag="working", running=True),
                           dict(id="b", title="b", group="queue", tag="idle", depth=1)])
        groups, gone = v.board_apply(board, {g: [] for g in v.GROUPS}, [], [], "node", "user")
        shown = v.visible([e for es in groups.values() for e in es], "", set())
        self.assertEqual([(e["kind"], e.get("tree_prefix"), e.get("tree_twisty")) for e in shown],
                         [("sess", "", ""), ("sess", "", "")])

    def test_pinned_row_marker(self):
        items = [self.node("pinned", group="pin", text="置顶的 中文"),
                 self.node("pkid", "pinned", group="pin", text="孩子"),
                 self.node("plain", text="plain")]
        out = v.compact_task_list(items, now=self.now, folds={"pinned": True})
        self.assertFalse([e for e in out if e["kind"] == "hdr"])
        self.assertEqual([e["target"] for e in out if e["kind"] == "sess"], ["pinned", "pkid", "plain"])
        by = {e["target"]: e for e in out if e["kind"] == "sess"}
        line = self.drawn(by["pinned"])
        self.assertIn("置顶的 中文 ⇡", line)
        st = self.seg(by["pinned"], " ⇡")
        self.assertIn("c1", st)
        self.assertNotIn("⇡", self.drawn(by["pkid"]), "a pinned parent's child shows no marker")
        self.assertNotIn("⇡", self.drawn(by["plain"]))
        for w in (100, 60, 45, 30):
            self.assertEqual(qo.cells(self.drawn(by["pinned"], w)), w)
        shut = v.compact_task_list(items, now=self.now)
        self.assertIn("▸ 置顶的 中文 (1) ⇡", self.drawn(next(e for e in shut if e.get("target") == "pinned")))
        long = dict(by["pinned"], text="很长" * 60)
        self.assertIn("… ⇡ Codex", self.drawn(long), "clip_name keeps room for the marker")
        with patch.dict(os.environ, {"FLEET_GLYPHS": "ascii"}):
            self.assertIn("置顶的 中文 ^", self.drawn(by["pinned"]))

    def test_pin_carries_children_and_roots_order_by_tree_activity(self):
        items = [self.node("old", activity_at=self.now - 500),
                 self.node("kid", "old", activity_at=self.now - 10, state="working", running=True),
                 self.node("new", activity_at=self.now - 100),
                 self.node("pinned", group="pin", activity_at=self.now - 9000),
                 self.node("pkid", "pinned", activity_at=self.now - 20, state="working", running=True)]
        folds = {"old": True, "pinned": True}
        self.assertEqual([e["target"] for e in self.sess(items, folds=folds)], ["pinned", "pkid", "old", "kid", "new"],
                         "a root rises by its tree's newest activity; PIN carries its children")
        items[1]["tree_at"] = 0
        items[0]["tree_at"] = self.now - 1      # the hub's tree_at wins over the rows here
        self.assertEqual([e["target"] for e in self.sess(items, folds=folds)][2], "old")


class Schedules(unittest.TestCase):
    """定时任务: one row per schedule (a synthetic parent), its runs under it —
    shut by default, the last ended run's ✓ / ✗ and time on its row."""

    def setUp(self):
        v._TASK_ORDER.clear()
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"FLEET_UI_LANG": "zh", "FLEET_CONF_DIR": self.tmp.name})
        self.env.start()
        for k in ("FLEET_GLYPHS", "NO_COLOR", "FLEET_COLOR"):
            os.environ.pop(k, None)
        v.caches_words_reset()
        self.now = time.time()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def run_(self, t, title, ago, **x):
        x.setdefault("activity_at", self.now - ago)
        return row(t, text=title, name=title, source="schedule", fid=t, **x)

    def items(self):
        return [self.run_("a3", "Brief 10-31", 100, schedule_id="s1", state="working", running=True),
                self.run_("d2", "daily-2026-10-31", 200, gone=True, sym="done"),
                self.run_("a2", "Brief 10-30", 300, schedule_id="s1", tag="completed", act=int(self.now - 300)),
                self.run_("a1", "Brief 10-29", 400, schedule_id="s1", tag="failed"),
                self.run_("d1", "daily-2026-10-30", 500, gone=True, sym="done"),
                self.run_("g2", "group-brief-2026-11-03-2", 600, ended=True, sym="fail"),
                self.run_("g1", "group-brief-2026-11-03", 700, gone=True),
                self.run_("b1", "Brief 10-28", 3 * 86400, schedule_id="s2", tag="ended_no_result")]

    def shown(self, items, opened=("src-schedule",), query="", **kw):
        return [e for e in v.visible(items, query, set(opened), **kw) if e["kind"] in ("sess", "sec")]

    def test_one_row_per_schedule_shut_by_default(self):
        shown = self.shown(self.items())
        self.assertEqual([e.get("target") or e["text"] for e in shown],
                         ["定时任务 · 4", "sched:s1", "sched:title:daily", "sched:title:group-brief", "sched:s2"],
                         "grouped by schedule_id, else by the title without its day; newest schedule first")
        self.assertEqual(self.shown(self.items(), opened=())[0]["text"], "定时任务 · 4", "the heading counts schedules")
        self.assertEqual(len(self.shown(self.items(), opened=())), 1)
        by = {e["target"]: e for e in shown if e["kind"] == "sess"}
        s1 = by["sched:s1"]
        self.assertEqual((s1["text"], s1["tree_twisty"], s1["tree_hidden_n"]), ("Brief", "shut", 3))
        self.assertEqual(by["sched:title:group-brief"]["text"], "group-brief")
        self.assertFalse(any(e["kind"] == "sec" and "更早运行" in e["text"] for e in v.visible(self.items(), "", {"src-schedule"})))

    def test_last_result_and_time(self):
        by = {e["target"]: e for e in self.shown(self.items()) if e["kind"] == "sess"}
        hm = time.strftime("%H:%M", time.localtime(self.now - 300))
        self.assertEqual(by["sched:s1"]["sched_tail"], "✓ " + hm, "the last ENDED run, not the running one")
        line = "".join(t for t, _ in v.row_segs(by["sched:s1"], 100, qo.cells, qo.clip))
        self.assertIn("▸ Brief (3)  ✓ " + hm, line)
        st = next(st for t, st in v.row_segs(by["sched:s1"], 100, qo.cells, qo.clip) if t == "  ✓ " + hm)
        self.assertIn("dim", st)
        self.assertEqual(by["sched:title:daily"]["sched_tail"][0], "✓")
        self.assertEqual(by["sched:title:group-brief"]["sched_tail"][0], "✗", "the newest ended run failed")
        md = time.strftime("%m-%d", time.localtime(self.now - 3 * 86400))
        self.assertEqual(by["sched:s2"]["sched_tail"], "✗ " + md, "an older day shows MM-DD")
        self.assertEqual(v.sched_result(row("x", tag="cancelled")), "bad")
        self.assertEqual(v.sched_result(row("x", tag="refused")), "bad")
        self.assertEqual(v.sched_result(row("x", state="working", running=True, tag="working")), "")
        self.assertEqual(v.sched_result(row("x")), "", "an idle live run is not over")
        # no Agent word on a schedule's own row; widths hold
        for w in (100, 60, 45):
            self.assertEqual(qo.cells("".join(t for t, _ in v.row_segs(by["sched:s1"], w, qo.cells, qo.clip))), w)
        self.assertNotIn("未知", line)

    def test_status_slot_and_twisty_colour(self):
        items = self.items()
        s1 = next(e for e in self.shown(items) if e.get("target") == "sched:s1")
        self.assertEqual(v.row_status(s1), "work")
        self.assertEqual(v.row_segs(s1, 100, qo.cells, qo.clip)[1][0], v.TASK_GLYPHS["work"])
        self.assertEqual(s1["tree_tone"], "work")
        items[2].update(state="needs", tag="")
        s1 = next(e for e in self.shown(items) if e.get("target") == "sched:s1")
        self.assertEqual(v.row_status(s1), "needs", "asking > working")
        self.assertEqual(s1["tree_tone"], "ask")
        twisty = next(st for t, st in v.row_segs(s1, 100, qo.cells, qo.clip) if t == "▸ ")
        self.assertIn("c1", twisty)
        self.assertNotIn("a2", [e.get("target") for e in self.shown(items)], "a shut schedule hides an asking run too")
        self.assertNotIn("个在问你", self.shown(items)[0]["text"])
        heading = v.paint([dict(self.shown(items, opened=())[0], closed=True)], -1, 60, qo.cells, qo.clip)[0]
        self.assertEqual(heading[1], ("▸", ("c1", "bold")))
        pend = [self.run_("p1", "nightly 10-31", 10, pending_start=True), self.run_("p0", "nightly 10-30", 20, tag="completed")]
        self.assertEqual(v.row_status(next(e for e in self.shown(pend) if e.get("target") == "sched:title:nightly")), "pending")

    def test_fold_keys_and_search(self):
        folds = {"sched:s1": True}
        shown = self.shown(self.items(), folds=folds)
        self.assertEqual([e.get("target") for e in shown[1:5]], [ "sched:s1", "a3", "a2", "a1"], "runs newest first")
        a2 = next(e for e in shown if e.get("target") == "a2")
        self.assertEqual((a2["tree_prefix"], a2["agent"]), ("  ├ ", "codex"))
        self.assertIn("Codex", "".join(t for t, _ in v.row_segs(a2, 100, qo.cells, qo.clip)), "runs draw as ordinary rows")
        self.assertEqual(v.tree_arrow(a2, False), ("sched:s1", False))
        self.assertEqual(v.tree_arrow(shown[1], False), ("sched:s1", False))
        # remembered in tree-open, kept while its runs are listed
        got = v.tree_toggle({}, "fx", "sched:s1", True, self.items())
        self.assertEqual(v.tree_toggle(got, "fx", "sched:s2", True, self.items()), {"sched:s1": True, "sched:s2": True})
        # search finds the runs, never the schedule's own row
        hits = [e["target"] for e in v.visible(self.items(), "Brief", set()) if e["kind"] == "sess"]
        self.assertTrue({"a1", "a2", "a3", "b1"} <= set(hits), hits)
        self.assertFalse([t for t in hits if t.startswith("sched:")], hits)
        # ↵ / Tab on the schedule's row: its newest run
        items = self.items()
        self.assertEqual(v.sched_run(items, shown[1])["target"], "a3")
        self.assertIs(v.sched_run(items, a2), a2)
        # the cursor landing on a hidden run opens its schedule
        self.assertEqual(v.tree_reveal({}, "fy", items, "a1"), {"sched:s1": True})

    def test_board_tag_kept(self):
        board = dict(rows=[dict(id="r1", title="daily-2026-11-03", group="gone", tag="failed", source="schedule"),
                           dict(id="r2", title="daily-2026-11-02", group="gone", tag="completed", source="schedule")])
        _, gone = v.board_apply(board, {g: [] for g in v.GROUPS}, [], [], "node", "user")
        self.assertEqual({e["fid"]: e["tag"] for e in gone}, {"r1": "failed", "r2": "completed"})
        self.assertEqual(v.sched_result(gone[0]), "bad")


if __name__ == "__main__":
    unittest.main()
