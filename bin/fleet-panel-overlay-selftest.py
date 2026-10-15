#!/usr/bin/env python3
"""Native overlay regression, isolated actions/PTY, never a live fleet socket."""
import curses
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
import fleet_panel as p
import fleet_view as v
spec = importlib.util.spec_from_file_location("quickopen", BIN / "fleet-quickopen.py")
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


def rows():
    out = [{"kind": "hdr", "group": "work", "text": "在干活"}]
    for i, sym in enumerate(("needs", "fail", "work", "done", "idle", "lost") * 7):
        out.append(dict(kind="sess", target="@" + str(i + 1), name="session", text=("源中文 e\u0301 Alpha" if not i else "会话 %02d" % i),
                        state="working", sym=sym, group="work", far=False, gone=False, word="在干活", tags=[],
                        foot="DO NOT REPEAT", machine="isolated", issue="", depth=0, reap="", sec=""))
    return out


def fixture(directory):
    """The real popup, with deterministic producer and action boundaries."""
    root = Path(directory)
    os.environ.update(FLEET_VIEW_REFRESH="0", FLEET_CONF_DIR=str(root / "conf"), FLEET_STATUS_G=str(root / "cache"),
                      FLEET_UI_LANG="zh", FLEET_PANEL_COMMANDS="new quit", ESCDELAY="25")
    data = rows()
    v.entries = lambda *a, **k: data if not (root / "gone").exists() else data[2:]
    v.current = lambda *a: "@1"
    v.view_fleet = lambda *a: "isolated"
    v.view_row = lambda *a: {}
    v.view_lang_env = lambda *a: None
    v.order_save = lambda *a: None
    v.tm = lambda *a, **k: (0, "")
    v.banner = lambda *a: ""
    v.hub_stale = lambda *a: False
    v.grid_read = lambda *a: dict(repos=["acme/web", "acme/app"], last="acme/web", agent="codex",
                                missing={"codex": "Codex unavailable"} if (root / "nomodel").exists() else {}, blocked=[])
    v.facts = lambda f, e: dict(pin=False, life="", keep=False, agent="codex", fid=e["target"], pr="", needs="ask", pane="%1")

    def log(payload):
        with (root / "actions").open("a") as f:
            f.write(json.dumps(payload) + "\n")
    def act(*args, **kwargs):
        log({"action": args[3]["id"], "target": args[4].get("target"), "answer": args[5]})
        return 0, "ACTION OK", False
    v.act_run = act
    v.bolt_run = lambda argv, done: log({"argv": argv})
    v.go = lambda *args, **k: (log({"go": args[2]}) or 0)
    # Drive actual refresh in the input loop, with the same return contract.
    class Fresh:
        def __init__(self, *a, **k):
            self.last = None
        def poll(self):
            gone = (root / "gone").exists()
            if gone != self.last:
                self.last = gone
                return v.entries()
        def wait_ms(self):
            return 60
    v.Refresh = Fresh
    curses.wrapper(v.popup, q, "test", "")
    print("POPUP-CLOSED", flush=True)


class StateTests(unittest.TestCase):
    def test_count_projection_and_unknown(self):
        data = rows()[:4]
        data += [dict(data[1]), dict(data[1], target="@90", state="done", sec="ended"),
                 dict(data[1], target="gone", gone=True), {"kind": "cmd", "target": "@91"}]
        with patch.object(v, "say", side_effect=lambda k, x: x):
            self.assertEqual(v.session_count(data), "4")
            self.assertEqual(v.session_count(data, "Alpha"), "2/4")
            data.append(dict(data[1], target="far/fid", far=True, lost=True))
            self.assertEqual(v.session_count(data, "Alpha"), "2+?/4+?")
            self.assertEqual(v.session_count([], remote_unknown=True), "0+?")

    def test_producer_canonical_alias_does_not_merge_windows_with_same_fid(self):
        def raw(target):
            f = [target, "done", "✓", "name", "", "", "0", "", "", "", "", "", "", "title", ""]
            return v.US.join(f)
        source = "\n".join(raw(t) for t in ("@1", "@1", "wid:U/a", "@2", "@3", "helper", "@4"))
        with patch.object(v, "view_row", return_value={"fuid": "U"}), patch.object(v, "view_fleet", return_value="test"), \
                patch.object(v, "windows", return_value={"@1": ("a", "worker", 0), "@2": ("b", "worker", 0),
                                                        "@3": ("b", "worker", 0), "@4": ("c", "panel", 0)}), \
                patch.object(v, "produce", return_value=source), patch.object(v, "names_raw", return_value={}), \
                patch.object(v, "fleet_only_slug", return_value=""), patch.object(v, "gone_text", return_value=""), \
                patch.object(v, "fleet_logins", return_value={}), patch.object(v, "conf_word", return_value=""), \
                patch.object(v, "hub_age", return_value=None):
            entries = v.entries("test", hub=False)
        self.assertEqual([e["target"] for e in entries if e["kind"] == "sess"], ["@1", "@2", "@3"])

    def test_selection_and_pin_never_move_glyph_or_title(self):
        data = rows()[1:7]
        for glyphs in ("ascii", ""):
            with patch.dict(os.environ, FLEET_GLYPHS=glyphs):
                base = ["".join(x for x, _ in r) for r in v.paint(data, -1, 80, q.cells, q.clip)]
                for at in range(len(data)):
                    selected = v.paint([dict(e, group="pin") for e in data], at, 80, q.cells, q.clip)
                    self.assertEqual(base, ["".join(x for x, _ in r) for r in selected])
                    self.assertIn("lit", selected[at][1][1])
                    self.assertNotIn("▶", base[at])

    def test_geometry_cell_bounds_and_prefix(self):
        for width in (189, 100, 80, 60, 48, 30, 12):
            for y in (-20, 1, 10, 27, 100):
                b = p.anchor_box(width, 1, 26, y, 80, 20)
                self.assertGreaterEqual(b.x, min(8, width - 4))
                self.assertLessEqual(b.x + b.w, width - 1)
                self.assertGreaterEqual(b.y, 1)
                self.assertLessEqual(b.y + b.h, 27)
                self.assertLessEqual(b.h, int(26 * .72))
                if width >= 48:
                    self.assertEqual(b.w, max(22, min(42, round(.32 * (width - 4)))))

    def test_editor_enter_unicode_caret_and_resize(self):
        ed = p.Editor("中e\u0301文" * 50)
        ed.pos = 7
        before = ed.pos
        ed.key("\n", 20, q.cells)
        self.assertEqual(ed.text[before], "\n")
        pos = ed.pos
        for width in (42, 30, 22, 30, 42, 22):
            rs = ed.rows(width, q.cells)
            self.assertTrue(all(q.cells(ed.text[a:b]) <= width for a, b in rs))
            self.assertEqual(ed.pos, pos)
        ed.key(curses.KEY_LEFT, 22, q.cells)
        ed.insert("X")
        self.assertEqual(ed.text[before], "X")
        self.assertEqual(q.cells("中e\u0301"), 3)

    def test_cancel_restore_and_private_draft_lifecycle(self):
        data = rows()
        overlay = p.Overlay(data[9], "query", {"ended"}, 9, 7, 3)
        overlay.focus = False
        self.assertEqual(overlay.restore(data), ("query", {"ended"}, 9, 7))
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "draft.json"
            d = p.Draft(path)
            d.editor.insert("中\ne\u0301")
            d.editor.pos, d.editor.top, d.scroll, d.control = 1, 2, 3, 2
            self.assertTrue(d.save(dict(repo="acme/web", agent="codex")))
            again = p.Draft(path)
            self.assertEqual((again.editor.text, again.editor.pos, again.editor.top, again.scroll, again.control),
                             ("中\ne\u0301", 1, 2, 3, 2))
            self.assertEqual((again.repo, again.agent), ("acme/web", "codex"))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


@unittest.skipUnless(shutil.which("tmux"), "tmux not installed")
class NativeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="panel4416-", dir="/tmp")
        self.root = Path(self.temp.name)
        self.argv = ["tmux", "-S", str(self.root / "sock")]
        self.evidence = []
        self.tm("-f", "/dev/null", "new-session", "-d", "-s", "test", "-x", "100", "-y", "30", "sleep 120")
        self.tm("set-option", "-g", "status", "off")
        self.start()

    def tearDown(self):
        subprocess.run(self.argv + ["kill-server"], capture_output=True, timeout=5)
        output = os.environ.get("FLEET_PANEL_OVERLAY_EVIDENCE")
        if output:
            with open(output, "a") as f:
                f.write("\n".join(self.evidence) + "\n")
        self.temp.cleanup()

    def tm(self, *args):
        return subprocess.check_output(self.argv + list(args), text=True, stderr=subprocess.STDOUT, timeout=5)

    def start(self):
        import shlex
        cmd = " ".join(shlex.quote(x) for x in (sys.executable, str(Path(__file__).absolute()), "--fixture", str(self.root)))
        self.tm("respawn-pane", "-k", "-t", "test", cmd + "; sleep 120")
        self.wait("Tab 操作")

    def screen(self):
        return self.tm("capture-pane", "-p", "-t", "test")

    def wait(self, text):
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            screen = self.screen()
            if text in screen:
                return screen
            time.sleep(.04)
        self.fail("missing %r:\n%s" % (text, self.screen()))

    def keys(self, *keys):
        self.tm("send-keys", "-t", "test", *keys)
        time.sleep(.12)

    def literal(self, text):
        self.tm("send-keys", "-t", "test", "-l", text)
        time.sleep(.12)

    def actions(self):
        file = self.root / "actions"
        return [json.loads(x) for x in file.read_text().splitlines()] if file.exists() else []

    def draft(self):
        paths = list((self.root / "conf" / "panel-drafts").glob("*.json"))
        return json.loads(paths[0].read_text()) if paths else {}

    def test_matrix_geometry_restore_and_continuous_resize(self):
        for width in (189, 100, 80, 60, 48):
            self.tm("resize-window", "-t", "test", "-x", str(width), "-y", "30")
            time.sleep(.15)
            before = self.screen().splitlines()
            self.keys("Tab")
            opened = self.wait("回收…").splitlines()
            self.assertEqual([q.clip(x, 8) for x in before[1:-2]], [q.clip(x, 8) for x in opened[1:-2]])
            self.assertIn("会话 42", opened[0])
            self.assertNotIn("DO NOT REPEAT", "\n".join(opened))
            self.evidence.append("ACTIONS %d columns\n%s" % (width, "\n".join(opened)))
            self.keys("Escape")
            after = self.wait("Tab 操作").splitlines()
            self.assertEqual(before[1:-2], after[1:-2])
            # ↑ from the first row goes to New; Enter opens without any action.
            self.keys("Up", "Enter")
            self.wait("开窗预填")
            self.evidence.append("COMPOSER %d columns\n%s" % (width, self.screen()))
            self.assertEqual(self.actions(), [])
            self.keys("Escape")
            # Cancel restores source (New); down wraps via language/quit to first.
            self.keys("Down", "Down", "Down")
        self.keys("Up", "Enter")
        self.literal("中e\u0301文")
        self.keys("Enter")
        self.literal("second")
        self.keys("Left", "Left")
        before = self.draft()
        for width in (189, 60, 100, 48, 80, 32, 48, 189):
            self.tm("resize-window", "-t", "test", "-x", str(width))
            time.sleep(.08)
        self.keys("Escape")
        after = self.draft()
        self.assertEqual((before["text"], before["pos"], before["repo"], before["agent"]),
                         (after["text"], after["pos"], after["repo"], after["agent"]))
        self.assertEqual(self.actions(), [])
        self.keys("Escape")
        self.wait("POPUP-CLOSED")
        self.evidence.append("PASS widths 189/100/80/60/48; prefix/geometry/cancel unchanged; continuous resize preserves caret/draft; zero actions; terminal restored")

    def test_focus_frozen_target_retarget_and_invalidation(self):
        self.keys("Tab", "F6", "Down", "F6")
        # In the still-open original menu: Enter is the original row's go.
        self.keys("Enter")
        self.assertEqual(self.actions(), [{"action": "enter", "target": "@1", "answer": ""}])
        self.keys("Tab", "F6", "Down", "Tab", "Enter")
        self.assertEqual(self.actions()[-1]["target"], "@2")
        self.keys("Up", "Tab")
        (self.root / "gone").touch()
        time.sleep(.25)
        count = len(self.actions())
        self.keys("Enter")
        self.wait("来源已失效")
        self.assertEqual(len(self.actions()), count)
        self.evidence.append("PASS F6 changes selection without retarget; Tab explicitly retargets; vanished source refuses without action")

    def test_saved_agent_unavailable_refuses_instead_of_switching(self):
        self.literal("task")
        self.keys("Enter")
        self.wait("Agent ‹Codex›")
        self.keys("Escape", "Escape")
        self.wait("POPUP-CLOSED")
        (self.root / "nomodel").touch()
        self.start()
        self.keys("Up", "Enter")
        self.wait("Agent ‹Codex›")
        self.keys("Tab", "Tab", "Tab", "Enter")
        self.wait("Codex unavailable")
        self.assertEqual(self.actions(), [])
        self.assertEqual(self.draft()["agent"], "codex")

    def test_paste_never_activates_controls(self):
        self.keys("Up", "Enter")
        self.wait("开窗预填")
        self.literal("\x1b[200~literal\n\ttext\n\x1b[201~")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and self.draft().get("text") != "literal\n    text\n":
            time.sleep(.05)
        self.assertEqual(self.draft()["text"], "literal\n    text\n", self.screen())
        self.keys("Tab", "Tab", "Tab")
        self.literal("\x1b[200~\n\n\t\n\x1b[201~")
        self.assertEqual(self.actions(), [])
        self.keys("Escape", "Escape")
        self.wait("POPUP-CLOSED")
        self.evidence.append("PASS bracketed multiline paste stays text; pasted Enter/Tab on a button dispatches nothing")

    def test_multiline_submit_once_options_and_persistence(self):
        self.literal("draft")
        self.keys("Enter")
        self.wait("开窗预填")
        self.keys("Enter")
        self.literal("第二行 e\u0301")
        self.keys("Tab", "Right", "Tab", "Right")
        self.assertEqual(self.actions(), [])
        saved = self.draft()
        self.assertEqual(saved["text"], "draft\n第二行 e\u0301")
        self.assertEqual((saved["repo"], saved["agent"]), ("acme/app", "claude"))
        self.keys("Escape", "Escape")
        self.wait("POPUP-CLOSED")
        self.start()
        self.keys("Up", "Enter")
        self.wait("开窗预填")
        self.assertEqual(self.draft()["text"], saved["text"])
        # Focus (agent) is also retained; Tab -> explicit draft button.
        self.keys("Tab", "Enter", "Enter", "Enter")
        actions = self.actions()
        self.assertEqual(len(actions), 1)
        argv = actions[0]["argv"]
        self.assertIn("--draft", argv)
        self.assertEqual(argv[argv.index("--repo") + 1], "acme/app")
        self.assertEqual(argv[argv.index("--agent") + 1], "claude")
        self.assertEqual(argv[argv.index("--title") + 1], saved["text"])
        self.evidence.append("PASS multiline Enter does not submit; cancel/reopen preserves draft/repo/agent/focus; explicit button submits exactly once to acme/app with claude")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
        fixture(sys.argv[2])
    else:
        with tempfile.TemporaryDirectory(prefix="panel-state-") as directory:
            os.environ.update(FLEET_CONF_DIR=directory, FLEET_STATUS_G=directory, FLEET_UI_LANG="zh")
            unittest.main()
