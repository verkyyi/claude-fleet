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
        gone = [sess("id:f-local", "f-local", "folded", gone=True, sec="gone")]   # only this machine remembers it
        out, out_gone = v.board_apply(BOARD, groups, shut, gone, "m", "u")
        self.assertEqual([e["target"] for e in out["pin"]], ["fu/f-pin"])
        self.assertEqual([e["target"] for e in out["work"]], ["@5", "@6"], "the hub's row first, a stray at the end")
        self.assertTrue(out["work"][1].get("unboarded"))
        self.assertEqual(out["work"][0]["text"], "the task")
        self.assertEqual(out["work"][0]["word"], "在干活")
        rec = out["queue"][0]
        self.assertTrue(rec["record_only"] and rec["target"] == "id:f-rec" and rec["word"] == "排着")
        self.assertEqual(v.menu_of(rec), [], "a record with no session has nothing to act on")
        self.assertEqual([e["fid"] for e in out_gone], ["f-exit", "f-end"], "the hub's 已收起, in its order")
        self.assertNotIn("f-local", [e["fid"] for e in out_gone])
        items = [e for g in v.GROUPS for e in out[g]] + out_gone
        with patch.object(v, "say", side_effect=lambda k, x: x):
            # pin + the task + the record (+ the stray the hub will list next round)
            self.assertEqual(v.session_count(items), "4")
            self.assertEqual(v.session_count([e for e in items if not e.get("unboarded")]), str(BOARD["count"]))

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


if __name__ == "__main__":
    unittest.main()
