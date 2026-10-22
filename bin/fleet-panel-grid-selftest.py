#!/usr/bin/env python3
# fleet-panel-grid-selftest.py — ⌘P's one left grid (T923): every row the panel
# draws (bin/fleet_view.py panel_rows + paint, cmd_line, row_lead, fill; the words
# in bin/fleet-ui-lang.sh, the cell count in bin/fleet-quickopen.py) puts its icon
# in ONE cell at ICON_X and its words at TEXT_X, and a lit row spans the list.
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet-panel-grid-selftest.py — no tmux, no fleet: the panel's own functions
on a fixture list, in zh and en, at 40 / 54 / 80 / 142 columns, fancy and ASCII
glyphs, no query / a query, 已收起 shut and open, the list empty.

  A  the icon tables: every icon one character, one cell, East Asian width never
     W / F / A (no emoji, no ambiguous width) and — the fancy ones — a glyph Menlo
     has (the list below was read off Menlo.ttc's cmap)
  B  the words carry no icon: the command rows' strings, zh and en, start with no
     lone symbol and hold no U+3000
  C  every line of every frame: a session's glyph at ICON_X and its ID at TEXT_X;
     a command / section row `  <icon> <words>`, as wide as the list; a question
     under its row from name_col; a note at TEXT_X; a heading from the left edge
  D  a lit row of any kind is as wide as the list; a command too long for it ends
     in …; the 「新会话」 box's title, the keys line and a plain footer sit on the grid
  E  an empty list says so in one row the cursor never stops on
"""
import importlib.util
import os
import sys
import tempfile
import unicodedata
from pathlib import Path

BIN = Path(__file__).absolute().parent
sys.path.insert(0, str(BIN))
TMP = tempfile.mkdtemp(prefix="panel-grid-")
os.environ.update(FLEET_CONF_DIR=TMP, FLEET_STATUS_G=TMP, FLEET_UI_LANG="zh", FLEET_PANEL_COMMANDS="new quit")
os.environ.pop("FLEET_GLYPHS", None)
import fleet_view as fv  # noqa: E402

spec = importlib.util.spec_from_file_location("quickopen", BIN / "fleet-quickopen.py")
qo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qo)
cells, clip = qo.cells, qo.clip

# the glyphs Menlo draws itself (fontTools, Menlo.ttc cmap): one family, one weight
MENLO = set("!?$+✦✗✖↻✓◌∙▸▾⇡⇣⇄⏏⌫↺▲↵›")
FAILS = []


def check(ok, what):
    if not ok:
        FAILS.append(what)


def one_cell(ch, where):
    check(len(ch) == 1 and qo.char_cells(ch) == 1 and unicodedata.east_asian_width(ch) not in ("W", "F", "A"),
          "A %s: %r is not one plain cell (EAW %s)" % (where, ch, unicodedata.east_asian_width(ch[:1] or " ")))


# --- A ---------------------------------------------------------------------------
for name, table, fancy in (("CMD_ICONS", fv.CMD_ICONS, True), ("CMD_ICONS_ASCII", fv.CMD_ICONS_ASCII, False),
                           ("GLYPHS", fv.GLYPHS, True), ("GLYPHS_ASCII", fv.GLYPHS_ASCII, False)):
    for k, ch in table.items():
        one_cell(ch, "%s[%s]" % (name, k))
        if fancy:
            check(ch in MENLO, "A %s[%s]: %r is not a glyph Menlo has" % (name, k, ch))
        else:
            check(ch.isascii(), "A %s[%s]: %r is not ASCII" % (name, k, ch))
check(set(fv.CMD_ICONS) == set(fv.CMD_ICONS_ASCII), "A the two icon tables name different rows")
one_cell(fv.MSG_GLYPHS["inbox"], "MSG_GLYPHS[inbox]")

# --- fixture ---------------------------------------------------------------------


def sess(i, sym, text, tid, group, **kw):
    e = dict(kind="sess", target="@%d" % i, name=text, text=text, id=tid, agent="claude", state="working",
             sym=sym, group=group, far=False, gone=False, word="", tags=[], foot="", machine="m",
             issue="", depth=0, reap="", sec="", repo="claude-fleet", ask="", lost=False)
    e.update(kw)
    return e


def items():
    return [{"kind": "hdr", "group": "pin", "text": fv.say("view_grp_pin_fmt", 1)},
            sess(1, "work", "看台常驻面板 resident panel", "T890", "pin"),
            {"kind": "hdr", "group": "ask", "text": fv.say("view_grp_ask_fmt", 2)},
            sess(2, "needs", "任务设计 task design ⌘P", "T923", "ask", ask="要不要？ go?"),
            {"kind": "ask", "of": "@2", "text": "要不要？ go?", "depth": 0},
            sess(3, "fail", "hub 部署失败 deploy failed", "W8QW", "ask", agent="codex"),
            {"kind": "hdr", "group": "work", "text": fv.say("view_grp_work_fmt", 4)},
            sess(4, "work", "EPIC 错误调研", "EDN1", "work", epic=dict(done=1, total=3, needs=1, fail=0, rows=2),
                 expanded=True),
            sess(5, "done", "成员一 member one", "B1", "work", fold="@4"),
            sess(6, "needs", "成员二 member two", "B2", "work", fold="@4"),
            sess(7, "lost", "mini2 失联 lost", "Q8H1", "work", lost=True, far=True, agent=""),
            {"kind": "hdr", "group": "queue", "text": fv.say("view_grp_queue_fmt", 1)},
            sess(8, "exited", "已结束 " + "很长" * 40, "WACK", "queue", ended=True),
            {"kind": "cmd", "cmd": "reapall", "act": "reapall", "n": 1, "row": {"targets": []},
             "text": fv.say("view_cmd_reapall_fmt", 1)},
            {"kind": "sec", "sec": "gone", "text": fv.say("view_sec_gone_fmt", 1), "n": 1, "older": 3},
            sess(9, "done", "老会话 old one", "G00", "folded", sec="gone", gone=True),
            {"kind": "cmd", "cmd": "history", "act": "history", "sec": "gone", "n": 3, "row": {},
             "text": fv.say("view_cmd_older_fmt", 3)}]


CMD_KEYS = ("view_cmd_blank", "view_cmd_home", "view_cmd_quit", "view_cmd_reapall_fmt", "view_cmd_older_fmt",
            "view_lang_row", "view_pin_current", "view_unpin_current", "view_notices_row", "view_notices_row_fmt",
            "view_task_opening", "view_composer")

frames = 0
for lang in ("zh", "en"):
    os.environ["FLEET_UI_LANG"] = lang
    fv.caches_words_reset()
    # --- B -------------------------------------------------------------------------
    for k in CMD_KEYS:
        w = fv.say(k, 1)
        first = w.split(" ", 1)[0]
        check(not (len(first) == 1 and not first.isalnum()), "B %s %s: the words still lead with %r" % (lang, k, first))
        check("　" not in w, "B %s %s: an ideographic space" % (lang, k))
    for glyph in ("fancy", "ascii"):
        if glyph == "ascii":
            os.environ["FLEET_GLYPHS"] = "ascii"
        else:
            os.environ.pop("FLEET_GLYPHS", None)
        icons = fv.cmd_icons()
        for width in (40, 54, 80, 142):
            for query, opened, cur in (("", set(), "@1"), ("", {"gone"}, "@3"), ("hub", set(), "")):
                shown = fv.panel_rows(items(), query, opened, cmds=["new", "quit"], cur=cur)
                stops = [i for i, e in enumerate(shown) if fv.pickable(e)]
                for at in [-1] + stops:
                    frames += 1
                    for e, segs in zip(shown, fv.paint(shown, at, width, cells, clip)):
                        line = "".join(t for t, _ in segs)
                        tag = "%s/%s/%d/%r/%s" % (lang, glyph, width, query, e.get("cmd") or e.get("target") or e["kind"])
                        # --- C -------------------------------------------------------
                        if e["kind"] == "sess":
                            check(cells("".join(t for t, _ in segs[:1])) == fv.ICON_X, "C %s: glyph not at ICON_X: %r" % (tag, line))
                            check(cells(segs[1][0]) == 1, "C %s: glyph not one cell: %r" % (tag, segs[1][0]))
                            check(cells("".join(t for t, _ in segs[:3])) == fv.TEXT_X, "C %s: ID not at TEXT_X: %r" % (tag, line))
                            check(cells(line) == width, "C %s: %d cells, not %d" % (tag, cells(line), width))
                        elif e["kind"] in ("cmd", "sec"):
                            want = icons.get(e.get("icon") or e.get("cmd") or "") if e["kind"] == "cmd" else \
                                ("▸" if e.get("closed", True) else "▾")
                            check(line[:fv.ICON_X] == " " * fv.ICON_X and line[fv.ICON_X] == (want or " ")
                                  and line[fv.ICON_X + 1] == " " and line[fv.TEXT_X] != " ",
                                  "C %s: not `  <icon> <words>`: %r" % (tag, line))
                            check(cells(line) == width, "D %s: %d cells, not %d: %r" % (tag, cells(line), width, line))
                            if cells(e["text"]) + fv.TEXT_X > width:
                                check(line.endswith("…"), "D %s: cut without …: %r" % (tag, line))
                        elif e["kind"] == "ask":
                            check(line.startswith(" " * fv.name_col(width)) and line[fv.name_col(width)] != " ",
                                  "C %s: the question not at name_col: %r" % (tag, line))
                        elif e["kind"] == "note":
                            check(line[:fv.TEXT_X] == " " * fv.TEXT_X and line[fv.TEXT_X] != " ", "C %s: %r" % (tag, line))
                        elif e["kind"] == "hdr":
                            check(line.startswith("─"), "C %s: a heading not at the left edge: %r" % (tag, line))
        # --- D: the lines outside the list ------------------------------------------
        title = fv.compose_title(cells)
        check(title == "  %s %s" % (icons["new"], fv.say("view_composer")), "D %s/%s: the box's title %r" % (lang, glyph, title))
        keys = fv.cmd_line(fv.say("view_keys_short"), cells)
        check(keys.startswith("  ↵ "), "D %s: the keys line %r" % (lang, keys))
        foot = fv.cmd_line(fv.say("view_cmd_home_foot"), cells)
        check(foot.startswith(" " * fv.TEXT_X) and foot[fv.TEXT_X] != " ", "D %s: a plain footer %r" % (lang, foot))
        long_ = fv.fill(fv.cmd_line("x" * 300, cells), 54, cells, clip)
        check(cells(long_) == 54 and long_.endswith("…"), "D the fill of a long line: %r" % long_)
    # --- E -------------------------------------------------------------------------
    os.environ.pop("FLEET_GLYPHS", None)
    empty = fv.panel_rows([], "", set(), cmds=["new", "quit"])
    notes = [e for e in empty if e["kind"] == "note"]
    check(len(notes) == 1 and notes[0]["text"] == fv.say("view_empty"), "E %s: the empty list's row: %r" % (lang, empty))
    check(not any(fv.pickable(e) for e in notes), "E the note is a stop")
    check(not any(e["kind"] == "note" for e in fv.panel_rows([], "zz", set(), cmds=["new", "quit"])),
          "E a query with no hit says 还没有会话")
    check(not any(e["kind"] == "note" for e in fv.panel_rows(items(), "", set(), cmds=["new", "quit"])),
          "E a list with sessions says 还没有会话")

if FAILS:
    for f in FAILS[:40]:
        print("FAIL " + f)
    print("selftest FAIL: fleet-panel-grid — %d of the checks over %d frames" % (len(FAILS), frames))
    sys.exit(1)
print("selftest PASS: fleet-panel-grid — A icon tables · B words · C grid · D width/… · E empty, %d frames (T923)" % frames)
