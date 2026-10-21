#!/usr/bin/env python3
# selftest-entry
"""The first screen with nowhere named to go back to (task Q1A8): a phone in
Termius, `ssh` to the entry, `fleet connect` — fleet-remote-view.sh's attach
hands it to fleet_view.py's `do land`, which opens a NEW session only when the
person has none anywhere (the list's own count: the hub's board, every machine);
with one, ⌘P's panel opens with its cursor on the most recently active
(FLEET_VIEW_LAND=last: the 看台 goes straight there; =new: the old road). Drives
land_pick / land / board_apply with every tmux and session road patched; no
tmux, no hub."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_view as v


def sess(target, act=0, **kw):
    e = dict(kind="sess", target=target, far=False, group="work", open=True, lost=False, act=act,
             machine="m", login="u")
    e.update(kw)
    return e


class Qo:
    __file__ = str(BIN / "fleet-quickopen.py")


class Pick(unittest.TestCase):
    def test_none_anywhere(self):
        self.assertEqual(v.land_pick([]), (False, None))
        put_away = [sess("id:a", gone=True), sess("@3", sec="gone", shut=True), sess("id:T9", record_only=True),
                    {"kind": "hdr", "group": "work"}]
        self.assertEqual(v.land_pick(put_away), (False, None), "closed / exited / a bare record is no session")

    def test_most_recent_anywhere(self):
        items = [sess("@1", act=100), sess("fu/far", act=300, far=True), sess("@2", act=200)]
        has, pick = v.land_pick(items)
        self.assertTrue(has)
        self.assertEqual(pick["target"], "fu/far", "another machine's session counts and can be the pick")

    def test_lost_machine_last(self):
        items = [sess("fu/lost", act=900, far=True, lost=True), sess("@1", act=10)]
        self.assertEqual(v.land_pick(items)[1]["target"], "@1")
        has, pick = v.land_pick([sess("fu/lost", act=900, far=True, lost=True)])
        self.assertTrue(has, "a session on a lost machine is still the person's: no new one")
        self.assertEqual(pick["target"], "fu/lost")

    def test_tie_keeps_list_order(self):
        self.assertEqual(v.land_pick([sess("@1"), sess("@2")])[1]["target"], "@1")

    def test_board_at_fills_act(self):
        groups = {g: [] for g in v.GROUPS}
        board = {"rows": [{"id": "f-x", "title": "far one", "group": "work", "tag": "working",
                           "words": ["在干活", "Working"], "worker_id": "fu/f-x", "at": 1234}]}
        out, _ = v.board_apply(board, groups, [], [], "m", "u")
        self.assertEqual(out["work"][0]["act"], 1234)


class Land(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.tmux = []
        self.items = []
        self.env = patch.dict(os.environ, {"FLEET_VIEW_LAND": ""})
        self.env.start()
        for name, fn in {
            "entries": lambda vid, *a, **k: self.items,
            "go_new": lambda qo, vid, client="", **k: self.calls.append(("new", vid)) or 0,
            "go": lambda qo, vid, target, how="go", client="", meta=None, record=True:
                self.calls.append(("go", target, how)) or 0,
            "view_fleet": lambda vid, row=None: "fl",
            "tm": self.tm,
        }.items():
            p = patch.object(v, name, fn)
            p.start()
            self.addCleanup(p.stop)

    def tearDown(self):
        self.env.stop()

    def tm(self, *args, timeout=5):
        self.tmux.append(args)
        if args[0] == "list-clients":
            return 0, "/dev/ttys009"
        if args[0] == "display-message":
            return 0, "60"
        return 0, ""

    def test_none_opens_new(self):
        self.assertEqual(v.land(Qo, "dev1"), 0)
        self.assertEqual(self.calls, [("new", "dev1")])
        self.assertFalse([a for a in self.tmux if a[0] == "run-shell"])

    def test_some_opens_the_panel_on_the_latest(self):
        self.items = [sess("@1", act=5), sess("@2", act=50)]
        self.assertEqual(v.land(Qo, "dev1"), 0)
        self.assertEqual(self.calls, [], "no new session, no switch")
        run = [a for a in self.tmux if a[0] == "run-shell"]
        self.assertEqual(len(run), 1)
        self.assertEqual(run[0][3], "fl@view-dev1:")
        cmd = run[0][4]
        self.assertIn("dash-popup.sh", cmd)
        self.assertIn("--client /dev/ttys009", cmd)
        self.assertIn("--at @2", cmd)
        self.assertIn("--view fl@view-dev1", cmd)
        self.assertIn("-w 100%", cmd, "a phone-narrow client gets the whole screen")

    def test_last_goes_there(self):
        self.items = [sess("@1", act=5), sess("@2", act=50)]
        with patch.dict(os.environ, {"FLEET_VIEW_LAND": "last"}):
            self.assertEqual(v.land(Qo, "dev1"), 0)
        self.assertEqual(self.calls, [("go", "@2", "land")])
        self.assertFalse([a for a in self.tmux if a[0] == "run-shell"])

    def test_new_is_the_old_road(self):
        self.items = [sess("@1", act=5)]
        with patch.dict(os.environ, {"FLEET_VIEW_LAND": "new"}):
            v.land(Qo, "dev1")
        self.assertEqual(self.calls, [("new", "dev1")])

    def test_do_routes_land(self):
        self.items = []
        self.assertEqual(v.do(Qo, "land", "dev1"), 0)
        self.assertEqual(self.calls, [("new", "dev1")])


class Wired(unittest.TestCase):
    def test_attach_hands_the_first_screen_to_land(self):
        src = (BIN / "fleet-remote-view.sh").read_text()
        self.assertIn('fleet-quickopen.py" "do" land --view', src)
        self.assertNotIn('fleet-quickopen.py" "do" new --view', src)


if __name__ == "__main__":
    unittest.main(verbosity=2)
