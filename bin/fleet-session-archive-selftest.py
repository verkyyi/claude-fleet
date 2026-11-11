#!/usr/bin/env python3
# selftest-entry
"""`fleet archive` reaches the session's identity (task M6WH): a keyed window's
hub row carries its worker_id's key alias (`<fleet UUID>/<slug>:scratch-N`), so
bin/fleet-session-cli.py's own_ids takes the window's @fleet_id instead and the
hub's list merges onto it; an already-stopped session is chosen by its short
code or task number; an id that is no identity is refused BEFORE any stop.
Drives: bin/fleet-session-cli.py, bin/fleet_view.py."""
import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_view  # noqa: E402

FU = "c7d372cf-903b-5229-8e55-3e286e9c026d"
LIVE = "a3be6ff9-5bef-476c-a4d6-481360d506e2"
GONE = "5d0e4908-e471-49f4-b00a-23f28a6f8dfa"


def load():
    spec = importlib.util.spec_from_file_location("fsc_archive", str(BIN / "fleet-session-cli.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def live_row(**kw):
    r = dict(key="@175", name="活页 MCP v2：修体检四个", title="活页 MCP v2：修体检四个 P1", state="done",
             issue="", node="", pr="", reap="merged", group="", repo="o/r", ended="", task="", code="")
    r.update(kw)
    return r


def board(live_fid=LIVE):
    live = dict(fid=live_fid, board=live_fid, worker_id=FU + "/" + live_fid, code="R29E", task="T1382",
                name="活页 MCP v2：修体检四个 P1", text="活页 MCP v2：修体检四个 P1", archived=False, state="done")
    gone = dict(fid=GONE, board=GONE, worker_id="", code="HZWX", task="T1378", gone=True, archived=False,
                name="活页 MCP v2：工具说明去掉 v1 旧名", text="活页 MCP v2：工具说明去掉 v1 旧名",
                state="ended_no_result", machine="mac-a", repo="r")
    return {"x": [live]}, [gone]


class Archive(unittest.TestCase):
    def setUp(self):
        self.m = load()
        self.writes, self.stops = [], []
        qo = type("QO", (), {"full_rows": staticmethod(lambda sess, timeout=8: [live_row()])})
        line = ["wid:%s/o-r:scratch-118" % FU, "mac-a", "online", "", "o/r", "done", "claude", "x", "", "", "1", "@175"]
        self.p = [
            patch.dict(os.environ, {"FLEET_SESSION": "fleet"}),
            patch.object(self.m, "lib", return_value=qo),
            patch.object(self.m, "HOME", [""]),
            patch.object(self.m, "cache_lines", return_value=[line]),
            patch.object(self.m, "window_fids", return_value={"@175": LIVE}),
            patch.object(self.m, "hub_freshen", return_value=None),
            patch.object(self.m, "pending_start_task", return_value=None),
            patch.object(self.m, "hub_write", side_effect=lambda t, a, wait=30: self.writes.append((t, a)) or (True, "")),
            patch.object(self.m, "stop_row", side_effect=lambda r: self.stops.append(r["key"]) or 0),
            patch.object(fleet_view, "board_read", return_value={"rows": []}),
            patch.object(fleet_view, "board_apply", side_effect=lambda *a: board()),
            patch.object(fleet_view, "controlled_stop_task", return_value=None),
        ]
        for p in self.p:
            p.start()

    def tearDown(self):
        for p in reversed(self.p):
            p.stop()

    def test_alias_row_gets_window_identity(self):
        r = [x for x in self.m.rows() if x["key"] == "@175"][0]
        self.assertEqual(r["fleet_id"], LIVE, "a key alias is never the fleet_id")
        self.assertEqual((r["board"], r["code"], r["task"]), (LIVE, "R29E", "T1382"), "the hub's list merges by identity")

    def test_archive_by_name_sends_identity(self):
        self.assertEqual(self.m.cmd_archive(["活页 MCP v2：修体检四个", "--yes"]), 0)
        self.assertEqual(self.stops, ["@175"])
        self.assertEqual(self.writes, [("session_archive", {"id": LIVE, "archived": True})])

    def test_archive_live_by_code(self):
        self.assertEqual(self.m.cmd_archive(["R29E", "--yes"]), 0)
        self.assertEqual(self.writes[-1][1]["id"], LIVE)

    def test_archive_stopped_by_code_and_task(self):
        for q in ("HZWX", "T1378"):
            self.writes.clear()
            self.assertEqual(self.m.cmd_archive([q, "--yes"]), 0, q)
            self.assertEqual(self.writes, [("session_archive", {"id": GONE, "archived": True})], q)
        self.assertEqual(self.stops, [], "an ended session is not stopped again")

    def test_gone_rows_stay_out_of_ls(self):
        self.assertNotIn("HZWX", [r.get("code") for r in self.m.rows()])

    def test_no_identity_refused_before_stop(self):
        with patch.object(self.m, "window_fids", return_value={}):
            with patch.object(fleet_view, "board_apply", side_effect=lambda *a: ({"x": []}, [])):
                self.assertEqual(self.m.cmd_archive(["活页 MCP v2：修体检四个", "--yes"]), 1)
        self.assertEqual((self.stops, self.writes), ([], []))


class RemoteAlias(Archive):
    """Another machine's keyed session (a parked one in the field, R29E): the cache
    row is `wid:<fleet UUID>/<slug>:scratch-N`, the list's `<fleet UUID>/<fid>` —
    joined by the fleet and the title the cache clipped."""
    def setUp(self):
        super().setUp()
        far = dict(key="wid:%s/o-r:scratch-118" % FU, name="活页 MCP v2：修体检四个", title="活页 MCP v2：修体检…",
                   state="done", issue="", node="mac-b", pr="", reap="", group="", repo="o/r", ended="", task="", code="")
        twin = dict(far, key="wid:%s/o-r:scratch-119" % FU, name="别的会话", title="别的会话")
        qo = type("QO", (), {"full_rows": staticmethod(lambda sess, timeout=8: [far, twin])})
        for p in (patch.object(self.m, "lib", return_value=qo), patch.object(self.m, "cache_lines", return_value=[]),
                  patch.object(self.m, "window_fids", return_value={})):
            p.start()
            self.p.append(p)

    def test_alias_row_gets_window_identity(self):
        r = [x for x in self.m.rows() if x["key"].endswith("scratch-118")][0]
        self.assertEqual((r["fleet_id"], r["board"], r["code"]), (LIVE, LIVE, "R29E"))
        other = [x for x in self.m.rows() if x["key"].endswith("scratch-119")][0]
        self.assertFalse(other.get("board"), "a title that is not the list's joins nothing")

    def test_archive_by_name_sends_identity(self):
        self.assertEqual(self.m.cmd_archive(["活页 MCP v2：修体检四个", "--yes"]), 0)
        self.assertEqual(self.writes, [("session_archive", {"id": LIVE, "archived": True})])

    def test_two_candidates_join_nothing(self):
        dup = [dict(key="wid:%s/o-r:scratch-%d" % (FU, n), name="活页 MCP v2", title="活页 MCP v2",
                    state="done", issue="", node="", pr="", reap="", group="", repo="", ended="", task="", code="")
               for n in (1, 2)]
        with patch.object(self.m, "lib", return_value=type("QO", (), {"full_rows": staticmethod(lambda s, timeout=8: dup)})):
            self.assertFalse(any(x.get("board") for x in self.m.rows()), "never a guess")

    def test_no_identity_refused_before_stop(self):
        with patch.object(fleet_view, "board_apply", side_effect=lambda *a: ({"x": []}, [])):
            self.assertEqual(self.m.cmd_archive(["活页 MCP v2：修体检四个", "--yes"]), 1)
        self.assertEqual((self.stops, self.writes), ([], []))


if __name__ == "__main__":
    unittest.main()
