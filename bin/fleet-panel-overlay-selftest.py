#!/usr/bin/env python3
"""Native full-page regression (#4416; plan B, T493), isolated actions/PTY, never a live fleet socket."""
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
    def grid(vid, repo=""):
        # the box's values (fleet-quick-dispatch.py grid — its own selftest holds
        # the rules); `repo` is the session in view's (T670)
        (root / "grid-repo").write_text(repo)
        return dict(repos=["acme/web", "acme/app"], last="acme/web", agent="codex",
                    agents={"": "codex", "acme/web": "codex", "acme/app": "claude"},
                    missing={"codex": "Codex unavailable"} if (root / "nomodel").exists() else {}, blocked=[])
    v.grid_read = grid
    data[1]["repo"] = "acme/web"    # the session in view (@1) is acme/web's
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
    def launch(screen):
        (root / "mouse-prefix").write_bytes(curses.tigetstr("kmous") or b"")
        forward = (root / "forward").read_text() if (root / "forward").exists() else ""
        return v.popup(screen, q, "test", "", forward)
    curses.wrapper(launch)
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

    def test_actions_page_five_items_and_a_grey_agent(self):
        r = dict(kind="sess", target="@1", state="working", agent="codex", pr="#4966", pr_url="u", far=False, gone=False,
                 text="t", name="t")
        with patch.object(v, "say", side_effect=lambda k, *a: k if not a else k + ":" + ":".join(map(str, a))):
            ids = [a["id"] for a, _, _ in v.page_of(r)]
            self.assertEqual(ids, ["enter", "pr", "rename", "agent", "reap"])
            page = v.page_of(r, {"claude": "this machine has no claude"})
            self.assertEqual([why for _, _, why in page], ["", "", "", "this machine has no claude", ""])
            self.assertEqual([a["id"] for a, _, _ in v.page_of(dict(r, pr=""))], ["enter", "rename", "agent", "reap"])
            self.assertEqual([a["id"] for a, _, _ in v.page_of(dict(r, state="exited"))], ["enter", "pr", "rename", "reap"])
            self.assertEqual([a["id"] for a, _, _ in v.page_of(dict(r, gone=True, pr="", target="landed:1@o/r"))], ["resume"])

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

    def test_cancel_restore(self):
        data = rows()
        page = p.Page(data[9], "query", {"ended"}, 9, 7)
        self.assertEqual(page.restore(data), ("query", {"ended"}, 9, 7))
        page.retarget(data[3])     # [ ] moved it: esc lands on the last one acted on
        self.assertEqual(page.restore(data), ("query", {"ended"}, 3, 7))
        # the box's defaults are fleet-quick-dispatch.py's (T670): no per-view draft
        self.assertFalse(hasattr(p, "Draft"))


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

    def test_matrix_geometry_restore_and_continuous_resize(self):
        for width in (189, 100, 80, 60, 48):
            self.tm("resize-window", "-t", "test", "-x", str(width), "-y", "30")
            time.sleep(.15)
            before = self.screen().splitlines()
            self.keys("Tab")
            opened = self.wait("回收…").splitlines()
            # a whole page: the session line on top, a rule, one numbered item a line
            self.assertIn("源中文", opened[1])
            self.assertTrue(opened[2].startswith("───"), opened[2])
            self.assertEqual([x.strip() for x in opened[3:7]], ["1  进入", "2  改名…", "3  换成 Claude", "4  回收…"])
            self.assertNotIn("会话 02", "\n".join(opened))
            self.assertIn("会话 42", opened[0])
            self.assertNotIn("DO NOT REPEAT", "\n".join(opened))
            self.evidence.append("ACTIONS %d columns\n%s" % (width, "\n".join(opened)))
            self.keys("Escape")
            after = self.wait("Tab 操作").splitlines()
            self.assertEqual(before[1:-2], after[1:-2])
            # ↑ from the first row goes to New; Enter opens the box without any action.
            self.keys("Up", "Enter")
            box = self.wait("开 ↵")
            self.evidence.append("COMPOSER %d columns\n%s" % (width, box))
            self.assertEqual(len([x for x in box.splitlines() if x.strip().startswith(("仓库 ‹", "Agent ‹", "开 ↵"))]), 3)
            self.assertEqual(self.actions(), [])
            self.keys("Escape")
            # Cancel restores source (New); down wraps via 回家命令行 (T685)/language/quit to ✦ 消息 (T701, the first row).
            self.keys("Down", "Down", "Down", "Down", "Down")
        self.keys("Up", "Enter")
        self.wait("开 ↵")
        self.literal("中e\u0301文")       # nothing to type into: the words go nowhere
        self.keys("Up", "Up", "Right")
        self.wait("仓库 ‹acme/app›")
        for width in (189, 60, 100, 48, 80, 32, 48, 189):
            self.tm("resize-window", "-t", "test", "-x", str(width))
            time.sleep(.08)
        box = self.wait("仓库 ‹acme/app›")
        self.assertIn("Agent ‹Claude›", box)
        self.keys("Escape")
        self.assertFalse((self.root / "conf" / "panel-drafts").exists())
        self.assertEqual(self.actions(), [])
        self.keys("Escape")
        self.wait("POPUP-CLOSED")
        self.evidence.append("PASS widths 189/100/80/60/48; prefix/geometry/cancel unchanged; continuous resize keeps the box's choice; zero actions; terminal restored")

    def test_page_numbers_step_and_invalidation(self):
        # a number runs its item on the page's own row; [ ] steps to the next session
        self.keys("Tab", "1")
        self.assertEqual(self.actions(), [{"action": "enter", "target": "@1", "answer": ""}])
        self.keys("Tab", "]")
        self.wait("会话 01")
        self.keys("Enter")
        self.assertEqual(self.actions()[-1]["target"], "@2")
        # a question opened from the page: esc comes back to the page, not the list
        self.keys("Tab", "2")
        self.wait("新名字›")
        self.keys("Escape")
        self.wait("4  回收…")
        self.keys("Escape")
        self.wait("Tab 操作")
        self.keys("Up", "Tab")
        (self.root / "gone").touch()
        time.sleep(.25)
        count = len(self.actions())
        self.keys("Enter")
        self.wait("来源已失效")
        self.assertEqual(len(self.actions()), count)
        self.evidence.append("PASS numbers run on the page's row; [ ] steps; esc from a question returns to the page; a vanished source refuses")

    def test_view_cache_is_private(self):
        # The view's own row cache is the person's: never world-readable.
        cache = self.root / "tmp" / ".claude-dash" / "global"
        cache.mkdir(parents=True)
        view_cache = cache / "view-rows-test"
        view_cache.write_text("old public cache")
        view_cache.chmod(0o644)
        v.atomic_write(view_cache, "rows\n")
        self.assertEqual(view_cache.stat().st_mode & 0o777, 0o600)
        self.assertEqual(view_cache.read_text(), "rows\n")
        self.evidence.append("PASS the view's row cache is written 0600")

    def test_mouse_clicks_a_page_item_once(self):
        self.keys("Tab")
        lines = self.wait("回收…").splitlines()
        def click(x, y):
            # Match the application's terminfo, as tmux translates a real
            # client's mouse. macOS ncurses can still request X10, not SGR.
            if (self.root / "mouse-prefix").read_bytes() == b"\x1b[M":
                event = "\x1b[M" + chr(32) + chr(x + 32) + chr(y + 32)
                event += "\x1b[M" + chr(35) + chr(x + 32) + chr(y + 32)
            else:
                event = "\x1b[<0;%d;%dM\x1b[<0;%d;%dm" % (x, y, x, y)
            self.literal(event)
        y = next(i for i, line in enumerate(lines) if "1  进入" in line)
        click(6, y + 1)
        time.sleep(.3)
        self.assertEqual(self.actions(), [{"action": "enter", "target": "@1", "answer": ""}])
        self.evidence.append("PASS a click on a page item runs it once on the page's row")

    def test_unusable_default_agent_falls_to_a_usable_one(self):
        (self.root / "nomodel").touch()
        self.start()
        self.keys("Up", "Enter")
        box = self.wait("开 ↵")
        # the repo's agent (Codex) is not usable here: the box opens on Claude
        self.assertIn("Agent ‹Claude›", box)
        self.keys("Enter")
        argv = self.actions()[0]["argv"]
        self.assertEqual(argv[argv.index("--agent") + 1], "claude")
        self.evidence.append("PASS an unusable remembered agent opens on a usable one")

    def test_cmd_n_opens_the_box_chosen(self):
        # ⌘N (T670, EPIC T651 C2): straight into the box — the session in view's repo
        # and its agent — ↵ opens (2 keys); esc closes the popup, not back to a list
        self.keys("Escape")
        self.wait("POPUP-CLOSED")
        (self.root / "forward").write_text("new")
        import shlex
        cmd = " ".join(shlex.quote(x) for x in (sys.executable, str(Path(__file__).absolute()), "--fixture", str(self.root)))
        self.tm("respawn-pane", "-k", "-t", "test", cmd + "; sleep 120")
        box = self.wait("仓库 ‹acme/web›")
        self.assertIn("Agent ‹Codex›", box)
        self.assertNotIn("已并进", box)
        self.assertEqual((self.root / "grid-repo").read_text(), "acme/web")
        self.keys("Escape")
        self.wait("POPUP-CLOSED")
        self.assertEqual(self.actions(), [])
        self.tm("respawn-pane", "-k", "-t", "test", cmd + "; sleep 120")
        self.wait("仓库 ‹acme/web›")
        self.keys("Enter")
        argv = self.actions()[0]["argv"]
        self.assertEqual((argv[argv.index("--repo") + 1], argv[argv.index("--agent") + 1]), ("acme/web", "codex"))
        self.evidence.append("PASS ⌘N opens the box on the session in view's repo + its agent; ↵ opens; esc closes")

    def test_paste_never_activates_controls(self):
        self.keys("Up", "Enter")
        self.wait("开 ↵")
        # the box opens on 开: a pasted Enter / Tab is text nobody types, never a key
        self.literal("\x1b[200~literal\n\ttext\n\x1b[201~")
        time.sleep(.3)
        self.assertEqual(self.actions(), [])
        self.assertIn("开 ↵", self.screen())
        self.keys("Escape", "Escape")
        self.wait("POPUP-CLOSED")
        self.evidence.append("PASS a bracketed paste in the box dispatches nothing")

    def test_box_three_items_submit_once_and_persistence(self):
        self.keys("Up", "Enter")
        box = self.wait("开 ↵")
        # three items, opened chosen: the defaults' repo, that repo's agent
        self.assertEqual([x.strip() for x in box.splitlines() if x.strip().startswith(("仓库 ‹", "Agent ‹", "开 ↵"))],
                         ["仓库 ‹acme/web›", "Agent ‹Codex›", "开 ↵"])
        for word in ("开窗预填", "清空草稿", "开空白会话", "写任务"):
            self.assertNotIn(word, box)
        # ↑↑ 仓库 → acme/app: the agent follows the repo's own (Claude), untouched
        self.keys("Up", "Up", "Right")
        box = self.wait("仓库 ‹acme/app›")
        self.assertIn("Agent ‹Claude›", box)
        # ↓ Agent → Codex, ← back to Claude; ↵ on a value goes to 开 (nothing runs)
        self.keys("Down", "Right")
        self.wait("Agent ‹Codex›")
        self.keys("Left", "Enter")
        self.assertEqual(self.actions(), [])
        self.keys("Enter")
        actions = self.actions()
        self.assertEqual(len(actions), 1)
        argv = actions[0]["argv"]
        self.assertEqual(argv[argv.index("do"):argv.index("do") + 2], ["do", "new"])
        self.assertNotIn("--draft", argv)
        self.assertNotIn("--title", argv)
        self.assertEqual(argv[argv.index("--repo") + 1], "acme/app")
        self.assertEqual(argv[argv.index("--agent") + 1], "claude")
        self.evidence.append("PASS three items opened chosen; ↵ on a value goes to 开; the agent follows the repo; 开 runs `do new` once with acme/app and claude, no words")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
        fixture(sys.argv[2])
    else:
        with tempfile.TemporaryDirectory(prefix="panel-state-") as directory:
            os.environ.update(FLEET_CONF_DIR=directory, FLEET_STATUS_G=directory, FLEET_UI_LANG="zh")
            unittest.main()
