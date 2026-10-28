#!/usr/bin/env python3
# selftest-entry
"""The one session list on the ⌘P panel (claude-fleet A4G2): fleet_view.py lays
its list on the hub's `board` (global/hubsess.body, written by
fleet-hub-sessions.sh) while it is fresh — the console draws the same rows, so
the two show one list, one order and one count. Drives board_read / board_apply /
session_count with isolated files only; no tmux, no hub."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_view as v


def sess(target, fid, group, far=False, **kw):
    e = dict(kind="sess", target=target, fid=fid, far=far, group=group, text="window " + target, name=target,
             state="working", sym="work", word="working", tags=[], foot="", machine="m", login="u", issue="",
             depth=0, reap="", repo="", ask="", lost=False, open=True)
    e.update(kw)
    return e


BOARD = {"count": 3, "gone_days": 7, "digest": "d", "groups": {"pin": 1, "work": 1, "queue": 1, "gone": 2}, "rows": [
    {"id": "f-pin", "title": "编排", "group": "pin", "tag": "looping", "words": ["在循环", "Looping"], "worker_id": "fu/f-pin", "at": 9},
    {"id": "f-run", "task": "T2", "code": "A4G2", "title": "the task", "group": "work", "tag": "working", "words": ["在干活", "Working"], "at": 8},
    {"id": "f-rec", "task": "T3", "code": "QQ11", "title": "not started", "group": "queue", "tag": "queued", "words": ["排着", "Queued"], "at": 7},
    {"id": "f-exit", "title": "exited one", "group": "gone", "tag": "exited", "words": ["已退出", "Exited"], "at": 6},
    {"id": "f-end", "title": "ended", "group": "gone", "tag": "ended_no_result", "words": ["结束·没交回结果", "Ended · no result"], "at": 5},
]}


class Board(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.p = patch.object(v, "dash_global", lambda: self.dir)
        self.p.start()
        v._BOARD.clear()
        v._BOARD["lang"] = "zh"

    def tearDown(self):
        self.p.stop()

    def write(self, board, age=1):
        (self.dir / "hubsess.body").write_text(json.dumps({"sessions": [], "board": board}))
        (self.dir / "hub_ok").write_text("%d\n" % (time.time() - age))

    def test_read_fresh_stale_absent(self):
        self.assertIsNone(v.board_read())                      # no hub here
        self.write(BOARD)
        self.assertEqual(v.board_read()["count"], 3)
        v._BOARD.pop("sig")
        self.write(BOARD, age=600)
        self.assertIsNone(v.board_read(), "a stale list is never drawn")
        self.write(None)
        self.assertIsNone(v.board_read(), "an older hub sends none")
        self.write(BOARD)
        with patch.dict(os.environ, {"FLEET_VIEW_BOARD": "0"}):
            self.assertIsNone(v.board_read())

    def test_apply_is_the_hub_list(self):
        groups = {g: [] for g in v.GROUPS}
        pin = sess("fu/f-pin", "", "pin", far=True, state="looping")        # another machine's, matched by worker_id
        run = sess("@5", "f-run", "queue", state="idle")                    # here: the hub's group wins
        stray = sess("@6", "f-new", "work")                                 # here, not heard by the hub yet
        groups["pin"], groups["queue"], groups["work"] = [pin], [run], [stray]
        shut = [sess("@7", "f-exit", "folded", sec="gone", shut=True, state="exited")]
        gone = [sess("id:f-local", "f-local", "folded", gone=True, sec="gone"),    # only this machine remembers it
                sess("id:f-rec", "f-rec", "folded", gone=True, sec="gone", ledger=True)]  # closed here, its record open
        out, out_gone = v.board_apply(BOARD, groups, shut, gone, "m", "u")
        self.assertEqual([e["target"] for e in out["pin"]], ["fu/f-pin"])
        self.assertEqual([e["target"] for e in out["work"]], ["@5", "@6"], "the hub's row first, a stray at the end")
        self.assertTrue(out["work"][1].get("unboarded"))
        self.assertEqual(out["work"][0]["text"], "the task")
        self.assertEqual(out["work"][0]["word"], "在干活")
        rec = out["queue"][0]
        self.assertTrue(rec["record_only"] and rec["target"] == "id:f-rec" and rec["word"] == "排着")
        self.assertFalse(rec.get("gone"), "an open record is drawn and counted even when its session closed here")
        self.assertEqual([a["id"] for a, _ in v.menu_of(rec)], ["archive"], "an unstarted record can be archived without any execution action")
        self.assertEqual([e["fid"] for e in out_gone], ["f-exit", "f-end"], "the hub's 已收起, in its order")
        self.assertNotIn("f-local", [e["fid"] for e in out_gone])
        items = [e for g in v.GROUPS for e in out[g]] + out_gone
        with patch.object(v, "say", side_effect=lambda k, x: x):
            # the ACTIVE ones (AWVX): pin + the task (+ the stray the hub will list
            # next round) — the record has no session running
            self.assertEqual(v.session_count(items), "3")
            self.assertEqual(v.session_count([e for e in items if not e.get("unboarded")]), str(BOARD["count"] - 1))

    def test_planned_board_only(self):
        board = {"rows": [{"id": "planned", "group": "queue", "tag": "queued",
                  "words": ["未派发", "Not dispatched"], "agent": "codex", "agent_basis": "planned",
                  "agent_words": ["Codex（计划）", "Codex (planned)"],
                  "context": ["尚未启动 · 协调负责人：AB12", "Not started · Coordinator: AB12"]}]}
        out, _ = v.board_apply(board, {g: [] for g in v.GROUPS}, [], [], "m", "u")
        rec = out["queue"][0]
        self.assertEqual(v.agent_word(rec), "Codex（计划）")
        self.assertIn("AB12", v.note_of(rec)[0])
        self.assertEqual(rec["word"], "未派发")
        import importlib.util
        spec = importlib.util.spec_from_file_location("qo", BIN / "fleet-quickopen.py")
        qo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(qo)
        drawn = "".join(t for t, _ in v.row_segs(rec, 50, qo.cells, qo.clip))
        self.assertIn("Cod·计", drawn)
        v._BOARD["lang"] = "en"
        drawn = "".join(t for t, _ in v.row_segs(rec, 50, qo.cells, qo.clip))
        self.assertIn("Cod(P)", drawn)

    def test_actual_and_legacy_board(self):
        for group in ("work", "gone"):
            e = sess("@1", "actual", group, agent="codex")
            board = {"rows": [{"id": "actual", "group": group, "tag": "working",
                               "agent": "claude", "agent_basis": "native", "agent_words": ["Claude", "Claude"]}]}
            groups = {g: [] for g in v.GROUPS}
            groups["work"] = [e]
            out, gone = v.board_apply(board, groups, [], [], "m", "u")
            self.assertEqual(v.agent_word((gone if group == "gone" else out[group])[0]), "Claude")
        groups = {g: [] for g in v.GROUPS}
        groups["work"] = [sess("@1", "legacy", "work", agent="codex")]
        out, _ = v.board_apply({"rows": [{"id": "legacy", "group": "work"}]}, groups, [], [], "m", "u")
        self.assertEqual(v.agent_word(out["work"][0]), "Codex", "old hub preserves local evidence")

    def test_web_opened_session_is_a_row(self):
        """会话合一 (task PQ41): a session the web opened is one row of the same
        list — its place, its word, the count — and a parked one reads 空闲."""
        board = {"count": 2, "digest": "w", "groups": {"work": 1, "queue": 1}, "rows": [
            {"id": "f-web", "title": "我的对话", "group": "work", "tag": "working", "words": ["在干活", "Working"],
             "origin": "web", "can_talk": True, "at": 9},
            {"id": "f-park", "title": "旧话题", "group": "queue", "tag": "idle", "words": ["空闲", "Idle"],
             "origin": "web", "can_talk": True, "state": "parked", "at": 8},
        ]}
        groups = {g: [] for g in v.GROUPS}
        groups["work"] = [sess("@3", "f-web", "work")]
        out, out_gone = v.board_apply(board, groups, [], [], "m", "u")
        self.assertEqual(out["work"][0]["target"], "@3")
        self.assertEqual((out["work"][0]["text"], out["work"][0]["origin"]), ("我的对话", "web"))
        park = out["queue"][0]
        self.assertEqual((park["word"], park["origin"]), ("空闲", "web"), "a parked session reads as idle")
        items = [e for g in v.GROUPS for e in out[g]] + out_gone
        with patch.object(v, "say", side_effect=lambda k, x: x):
            # listed both, active one (AWVX): the parked session runs no agent
            self.assertEqual(v.session_count(items), "1")
            board["rows"][1]["active"], board["rows"][0]["active"] = False, True
            out, out_gone = v.board_apply(board, groups, [], [], "m", "u")
            self.assertEqual(v.session_count([e for g in v.GROUPS for e in out[g]]), "1", "the hub's word wins")

    def test_exited_window_is_not_counted(self):
        items = [sess("@1", "a", "work"), sess("@2", "b", "folded", sec="gone", shut=True, state="exited")]
        with patch.object(v, "say", side_effect=lambda k, x: x):
            self.assertEqual(v.session_count(items), "1")


class Diff(unittest.TestCase):
    def test_diff_zero_and_not(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("bdiff", BIN / "fleet-board-diff.py")
        d = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(d)
        groups = {g: [] for g in v.GROUPS}
        groups["pin"] = [sess("fu/f-pin", "", "pin", far=True)]
        groups["work"] = [sess("@5", "f-run", "work")]
        v._BOARD["lang"] = "zh"
        out, gone = v.board_apply(BOARD, groups, [], [], "m", "u")
        items = [e for g in v.GROUPS for e in out[g]] + gone
        got = d.compare(BOARD, items)
        self.assertEqual((got["diff"], got["count_hub"], got["count_panel"]), (0, 3, 3), got)
        items = [e for e in items if e.get("fid") != "f-rec"] + [sess("@9", "f-x", "work")]
        got = d.compare(BOARD, items)
        self.assertEqual([x["id"] for x in got["only_hub"]], ["f-rec"])
        self.assertEqual([x["id"] for x in got["only_panel"]], ["f-x"])
        self.assertEqual(got["diff"], 2)


class EpicOnBoard(unittest.TestCase):
    """Older board parent/member metadata cannot hide or aggregate task rows."""

    def board_epic(self, kid_groups):
        groups = {g: [] for g in v.GROUPS}
        drv = sess("@1", "f-drv", "work", task="T10", expanded=True,
                   epic={"done": 0, "total": len(kid_groups), "rows": len(kid_groups), "needs": 0, "fail": 0})
        kids = [sess("@%d" % (2 + i), "f-k%d" % i, g, task="T%d" % (11 + i), fold="@1")
                for i, g in enumerate(kid_groups)]
        other = sess("@9", "f-oth", "work")
        rows = []
        # the board's order: a member in another group first, the EPIC below it
        for i, g in enumerate(kid_groups):
            if g != "work":
                rows.append({"id": "f-k%d" % i, "group": g, "tag": "asking", "at": 20 - i})
        rows.append({"id": "f-drv", "group": "work", "tag": "working", "at": 10})
        rows.append({"id": "f-oth", "group": "work", "tag": "working", "at": 9})
        for i, g in enumerate(kid_groups):
            if g == "work":     # an older hub, or a stray: below another row
                rows.append({"id": "f-k%d" % i, "group": "work", "tag": "working", "at": 8 - i})
        for e in [drv, other] + kids:
            groups[e["group"]].append(e)
        out, out_gone = v.board_apply({"rows": rows}, groups, [], [], "m", "u")
        items = [e for g in v.GROUPS for e in out[g]]
        return items, drv

    def test_all_members_visible_without_driver_expansion(self):
        items, drv = self.board_epic(["work", "work"])
        drv["expanded"] = False
        with patch.object(v.time, "time", return_value=0):
            shown = v.visible(items, "", set())
        self.assertEqual([e["target"] for e in shown if e["kind"] == "sess"], ["@1", "@9", "@2", "@3"])
        self.assertTrue(all(not e.get("fold") and not e.get("epic") and not e.get("depth") for e in shown))

    def test_members_in_other_groups_stay_independent(self):
        items, drv = self.board_epic(["ask"])
        drv["expanded"] = False
        with patch.object(v.time, "time", return_value=0):
            shown = v.visible(items, "", set())
        self.assertEqual([e["target"] for e in shown if e["kind"] == "sess"], ["@2", "@1", "@9"])
        self.assertTrue(all(not e.get("fold") and not e.get("epic") for e in shown))


if __name__ == "__main__":
    unittest.main()
