#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""Task FQAR: the list is honest about what ↵ can reach, and the actions page says
why. Fixture peerlink/state.json + fixture rows → the rendered row and bottom line;
the hub stale rule (60 s quiet, 15 s once a round failed) in both judges (the shell
lib and fleet_view); the 「连接」 block's lines and their width. No hub, no tmux, no
ssh, no keeper: everything is a file in a temporary directory.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_view as v  # noqa: E402
import fleet_view_link as L  # noqa: E402

NOW = 1_800_000_000.0


def row(target, **facts):
    e = dict(kind="sess", target=target, text="修登录页", name=target, group="work", state="working",
             running=True, sym="work", id="AB12", agent="claude", tags=[], foot="", repo="app", depth=0,
             ask="", far=True, machine="box-b", login="alice", word="干活中")
    e.update(facts)
    return e


def link(machine, login, phase, **kw):
    d = dict(machine=machine, login=login, host=machine + ".example.com", route="tailnet " + machine + ".example.com",
             sock="/nonexistent", pid=1, phase=phase, since=NOW - 300, last_check=NOW - 1, rtt_ms=25,
             fails=0, err="", bad_since=0.0, want_ts=NOW, strikes=0, probe_strikes=0)
    d.update(kw)
    return d


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.conf = Path(self.tmp.name) / "conf"
        self.g = Path(self.tmp.name) / "g"
        (self.conf / "peerlink").mkdir(parents=True)
        (self.conf / "logs").mkdir(parents=True)
        self.g.mkdir()
        self.env = patch.dict(os.environ, {"FLEET_UI_LANG": "zh", "FLEET_CONF_DIR": str(self.conf),
                                           "FLEET_STATUS_G": str(self.g), "NO_COLOR": "1"})
        self.env.start()
        for k in ("FLEET_HUB_SESSIONS_STALE", "FLEET_HUB_SESSIONS_STALE_FAIL", "FLEET_PEERLINK_STALE"):
            os.environ.pop(k, None)
        v.caches_words_reset()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def state(self, links, ts=NOW):
        (self.conf / "peerlink" / "state.json").write_text(json.dumps({"v": 1, "ts": ts, "links": links}))


class Overlay(Base):
    def test_down_link_marks_far_row_and_never_this_login(self):
        self.state([link("box-b", "alice", "down", bad_since=NOW - 45, err="ssh: connect timed out"),
                    link("box-c", "alice", "up"),
                    link("box-a", "bob", "connecting", since=NOW - 7)])
        items = [row("w1"),                                          # box-b@alice: down 45 s
                 row("w2", machine="box-c"),                         # up: untouched
                 row("@3", far=False, machine="box-a", login="alice"),  # this machine + login
                 row("w4", machine="box-a", login="bob"),            # another login here: rides a link
                 row("w5", lost=True),                               # the hub's 失联 wins
                 row("w6", machine="box-z"),                         # no link known: no word
                 row("w7", state="needs", running=False, word="等你回答")]
        v.link_overlay(items, "box-a", "alice", NOW)
        got = {e["target"]: e.get("unreach") for e in items}
        self.assertEqual(got, {"w1": 45, "w2": None, "@3": None, "w4": 7, "w5": None, "w6": None, "w7": 45})
        # rendered: no working glyph, dimmed, the bottom line says why
        segs = v.row_segs(items[0], 60, len, lambda t, n: t[:n])
        self.assertEqual(segs[1][0], " ", "a row that cannot be entered keeps no ↻")
        self.assertTrue(all("dim" in s for _, s in segs), segs)
        note, _red = v.note_of(items[0])
        self.assertTrue(note.startswith("不可进入 · 正在重连 45 秒"), note)
        self.assertNotIn("干活中", note)
        # a question still asks (answering goes through the hub, not the link)
        self.assertEqual(v.task_status(items[6]), "needs")
        self.assertIn("等你回答", v.note_of(items[6])[0])
        # the healthy one keeps its working state
        self.assertEqual(v.task_status(items[1]), "work")
        self.assertNotIn("不可进入", v.note_of(items[1])[0])

    def test_stale_or_missing_state_says_nothing(self):
        items = [row("w1")]
        v.link_overlay(items, "box-a", "alice", NOW)                  # no state.json at all
        self.assertIsNone(items[0].get("unreach"))
        self.state([link("box-b", "alice", "down", bad_since=NOW - 45)], ts=NOW - 120)
        v.link_overlay(items, "box-a", "alice", NOW)                  # the keeper stopped
        self.assertIsNone(items[0].get("unreach"))
        (self.conf / "peerlink" / "state.json").write_text("{not json")
        v.link_overlay(items, "box-a", "alice", NOW)
        self.assertIsNone(items[0].get("unreach"))

    def test_down_since_prefers_newer_fields(self):
        self.assertEqual(L.unreach(link("m", "l", "down", down_since=NOW - 9, bad_since=NOW - 99), NOW), 9)
        self.assertEqual(L.unreach(link("m", "l", "verifying", since=NOW - 3), NOW), 3)
        self.assertIsNone(L.unreach(link("m", "l", "up"), NOW))
        self.assertEqual(L.unreach_words(150, True), "can't enter · reconnecting 2 min")

    def test_link_of_without_login(self):
        st = {"links": [link("box-b", "alice", "up"), link("box-c", "x", "up"), link("box-c", "y", "down")]}
        self.assertEqual(L.link_of(st, "BOX-B")["login"], "alice")
        self.assertIsNone(L.link_of(st, "box-c"), "two logins there: no guess")
        self.assertEqual(L.link_of(st, "box-c", "y")["phase"], "down")


class Stale(Base):
    def lost_sh(self, age, why):
        (self.g / "hub_ok").write_text("%d\n" % (NOW - age))
        if why:
            (self.g / "hub_why").write_text("unreachable\t%d\tno answer\n" % NOW)
        else:
            (self.g / "hub_why").unlink(missing_ok=True)
        sh = ('FLEET_STATUS_G="$1"; . "$2/fleet-status-lib.sh"; fleet_status_hub_ok 0; '
              'fleet_status_hub_lost "$3" && echo lost || echo fresh')
        return subprocess.run(["bash", "-c", sh, "_", str(self.g), str(BIN), str(int(NOW))],
                              capture_output=True, text=True).stdout.strip()

    def test_shell_and_python_agree(self):
        for age, why, want in ((20, False, "fresh"), (20, True, "lost"), (10, True, "fresh"),
                               (70, False, "lost"), (59, False, "fresh")):
            self.assertEqual(self.lost_sh(age, why), want, (age, why))
            self.assertEqual(v.hub_stale(NOW), want == "lost", (age, why))

    def test_knobs(self):
        os.environ["FLEET_HUB_SESSIONS_STALE_FAIL"] = "40"
        self.assertEqual(self.lost_sh(30, True), "fresh")
        self.assertFalse(v.hub_stale(NOW))
        os.environ["FLEET_HUB_SESSIONS_STALE"] = "20"     # the fail budget never exceeds the quiet one
        self.assertEqual(self.lost_sh(30, True), "lost")
        self.assertTrue(v.hub_stale(NOW))


class Detail(Base):
    def test_lines_fit_a_narrow_pane(self):
        self.state([link("box-b", "alice", "down", bad_since=NOW - 45, fails=3, strikes=1,
                         err="ssh: connect timed out", cause="timeout", err_ts=NOW - 40)])
        log = self.conf / "logs" / "view-switch.ndjson"
        recs = [{"ts": NOW - i, "to": "w1", "machine": "box-b", "login": "alice", "method": "peer-window",
                 "ms": ms} for i, ms in enumerate((100, 120, 140, 900))]
        recs.append({"ts": NOW, "to": "w9", "machine": "box-b", "login": "alice", "method": "peer-select", "ms": 300})
        recs.append({"ts": NOW, "to": "w9", "machine": "box-b", "login": "alice", "method": "gone", "ms": 1})
        log.write_text("\n".join(json.dumps(r) for r in recs) + "\nnot json\n")
        (self.g / "hub_nodes").write_text("#ts\x1f%d\nbox-b\x1fonline\x1f1\x1f4\x1f50\x1f2\x1fabc\x1f6"
                                          "\x1f1\x1f2\x1f\x1fcoord\x1fbox-b\n" % NOW)
        (self.g / "hub_ok").write_text("%d\n" % (NOW - 3))
        e = row("w1")
        v.link_overlay([e], "box-a", "alice", NOW)
        with patch.object(time, "time", return_value=NOW):
            page = v.link_page(e, NOW)
        text = [t for t, _ in page]
        joined = "\n".join(text)
        for want in ("机器  box-b · alice", "位置  协调机", "路线  tailnet box-b.example.com",
                     "状态  断开 · 45 秒", "失败  3 · 检查超时 1 · 通道超时 0",
                     "上次错  timeout: ssh: connect timed out @",
                     "进入本会话  p50 120ms · p95 900ms · 4", "进入这台  p50 140ms · p95 900ms · 5",
                     "入口  在线 · 3 秒前答过", "入口看这台  在线 · 心跳 6 秒前"):
            self.assertIn(want, joined)
        self.assertIn(("red",), [s for t, s in page if "状态" in t])
        # one fact a line, each short enough for a ~40-column pane (the error line may clip)
        for t in text:
            if "上次错" not in t:
                self.assertLessEqual(cells(t), 40, t)

    def test_up_link_and_local_row(self):
        self.state([link("box-b", "alice", "up", since=NOW - 600, rtt_ms=31)])
        up = "\n".join(L.detail_lines(row("w1"), L.link_of(L.link_state(self.conf, NOW), "box-b", "alice"),
                                      {}, L.enter_stats(self.conf / "nope", "w1", "box-b"), NOW, False, None))
        self.assertIn("状态  已连上 · 自 ", up)
        self.assertIn("往返  31 ms", up)
        self.assertIn("进入耗时  还没记录", up)
        self.assertIn("入口  没有", up)
        here = L.detail_lines(row("@1", far=False, machine="box-a"), None, {}, {}, NOW, True, 5, False)
        self.assertIn("this machine: no link", here)
        self.assertIn("hub  online · answered 5 s ago", here)


def cells(s):
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


if __name__ == "__main__":
    unittest.main()
