#!/bin/bash
# fleet-view-planb-selftest.sh — ⌘P's rows as plan B draws them (T486 v14 定稿, T493).
#
#   A  short_name: a cross-session envelope is 「来自 X：its words」 (an envelope
#      cut before its words is no name), the `T<n> Claude · ` prefix gives the ID,
#      a leading 「修 #N：」, brackets and paths go
#   B  row_cols / entries over fixture rows: the ID is field 22's T<n>, else the
#      name's prefix, else blank; the agent is field 23's (a window here with none
#      is Claude, another machine's 未知); the repo is the row's own field 24, not
#      its heading's (a pinned or no-repo row: blank)
#   C  the seven glyphs + lost (one cell each, no emoji form), exited ⇒ ◌ under
#      已结束 · 还开着 only, asleep ⇒ ☾; the legend lists all eight
#   D  paint: glyph(1) · ID(8, bold) · Agent(7) · name · repo(13); the repo column
#      is kept blank; only ! and ✗ are coloured (red + bold); 未知 is dim; a long
#      name is cut at its punctuation; no tag, issue or PR on the row
#   E  search: an issue number (4539 or #4539) finds its row exactly, never by a
#      substring; match_why says so; the ID is searched too; note_of carries the
#      tags, red for a broken configuration
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-planb selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvplanb-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
unset NO_COLOR FLEET_COLOR FLEET_GLYPHS
mkdir -p "$WORK/conf"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
pass() { echo "ok   $*"; }

python3 - "$BIN" <<'PY' || fail "plan B rows"
import importlib.util, os, sys, time, unicodedata
B = sys.argv[1]
def load(name, f):
    spec = importlib.util.spec_from_file_location(name, os.path.join(B, f))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
fv = load("fleet_view", "fleet_view.py")
qo = load("qo", "fleet-quickopen.py")
US = "\x1f"

# --- A: short names
sn = lambda t: fv.short_name(t)
assert sn('<cross-session-message from-name="fleet" from-mode="bypass"> 实施 ⌘P 面板方案 B（T486 定稿）') == \
    ("来自 fleet：实施 ⌘P 面板方案 B", ""), sn('<cross-session-message from-name="fleet"> x')
assert sn('<cross-session-message from-name="fleet…') == ("", "")
assert sn("T477 Claude · 减法批1续：删 hub 单据") == ("减法批1续：删 hub 单据", "T477")
assert sn("T364 循环消息的原生条件") == ("循环消息的原生条件", "T364")
assert sn("修 #4964：面板 bin/fleet_view.py 的行") == ("面板 的行", "")
assert sn("接手 #4587 编排：先读 host-a:/home/u/.clau…") == ("接手 #4587 编排：先读", "")
assert sn("编排 Claude · 我的会话（#4587）") == ("编排 Claude · 我的会话", "")
assert sn("（只有括号）") == ("（只有括号）", "")
assert sn("issue-4205") == ("issue-4205", "")
pass_a = "A"

# --- B: columns off fixture rows
now = int(time.time())
def row(*f): return US.join(f)
def full(*f, task="", agent="", repo=""):
    f = list(f) + [""] * (20 - len(f))
    return US.join(f + ["", task, agent, repo])
rows = "\n".join([
    row("hdr", "pin", "", "置顶 (1)", " "),
    full("@1", "working", "⠹", "pinned", " ", "", "0", "", "", "", "—", "·", "ok", "编排 Claude · 我的会话（#4587）", "keep", agent="claude"),
    row("hdr", "", "", "─" * 40, " "),
    row("hdr", "o/claude-fleet", "", "claude-fleet (5)", " "),
    full("@2", "working", "⠹", "w2", " ", "", "0", "", "", "#4539", "—", "50%", "ok", "批量切换检查仍用旧进程计数", "merged",
         task="T367", agent="claude", repo="o/claude-fleet"),
    full("@3", "done", "✓", "w3", " ", "", "0", "", "", "", "—", "·", "ok", "T484 Claude · ⌘P 新任务先建 T", "merged",
         agent="codex", repo="o/claude-fleet"),
    full("@4", "needs", "!", "w4", " ", "", "0", "question", "", "#45390", "—", "·", "broken", "要你拍板", "merged", "", "question", "合不合？",
         task="T12", repo="o/other-repo-with-a-long-name"),
    full("@5", "failed", "x", "w5", " ", "", "0", "", "", "", "—", "·", "ok", "失败的", "merged"),
    full("@6", "sleeping", "z", "w6", " ", "", "0", "", "", "", "—", "·", "ok", "睡着的", "merged", repo="o/claude-fleet"),
    full("@7", "exited", "∅", "w7", " ", "", "0", "", "", "", "—", "·", "ok", "退出了的", "merged", repo="o/claude-fleet"),
    full("wid:MU/far1", "idle", "·", "far", " ", "", "0", "", "mac-a", "", "—", "·", "ok", "别处的", "merged"),
    full("wid:MU/far2", "working", "⠹", "far2", " ", "", "0", "", "mac-b!", "", "—", "·", "ok", "失联的", "merged"),
]) + "\n"
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "nodeA"
fv.fleet_logins = lambda: {"MU": "carol"}
fv.windows = lambda fleet: {"@%d" % i: ("", "worker", now - 60) for i in range(1, 8)}
fv.gone_text = lambda fleet: ""
fv.produce = lambda fleet, **kw: rows
fv.hub_view_request = lambda f: None
fv.hub_fresh = lambda f: None
it = fv.entries("v1")
by = {e["target"]: e for e in it if e["kind"] == "sess"}
assert [by[t]["id"] for t in ("@1", "@2", "@3", "@4", "@5")] == ["", "T367", "T484", "T12", ""], \
    [by[t]["id"] for t in by]
assert by["@3"]["text"] == "⌘P 新任务先建 T", by["@3"]["text"]
assert [by[t]["agent"] for t in ("@2", "@3", "@5", "MU/far1")] == ["claude", "codex", "claude", ""], \
    [by[t]["agent"] for t in by]
assert by["@1"]["repo"] == "" and by["@2"]["repo"] == "claude-fleet" and by["@4"]["repo"] == "other-repo-with-a-long-name" \
    and by["@5"]["repo"] == "claude-fleet", {t: e["repo"] for t, e in by.items()}

# --- C: glyphs
gl = fv.glyphs()
assert gl == {"needs": "!", "fail": "✗", "work": "↻", "done": "✓", "exited": "◌", "idle": "∙", "sleep": "☾", "lost": "?"}, gl
for c in gl.values():
    assert unicodedata.east_asian_width(c) in ("N", "Na") and len(c) == 1, c
sym = {t: e["sym"] for t, e in by.items()}
assert sym == {"@1": "work", "@2": "work", "@3": "done", "@4": "needs", "@5": "fail", "@6": "sleep", "@7": "exited",
               "MU/far1": "idle", "MU/far2": "lost"}, sym
grp = {t: e["group"] for t, e in by.items()}
assert grp["@7"] == "ended" and by["@7"]["sec"] == "ended" and grp["@3"] == "done" and grp["@6"] == "other", grp
assert not any(e["sym"] == "exited" and not e.get("sec") for e in by.values())
leg = fv.legend()
assert leg == "↻ 运行中  ! 等你  ✓ 已完成  ✗ 失败  ◌ 已退出  ∙ 空闲  ☾ 休眠  ? 失联", leg

# --- D: paint
W = 100
shown = fv.visible(it, "", {"ended"})
at = next(i for i, e in enumerate(shown) if e.get("target") == "@2")
lines = fv.paint(shown, at, W, qo.cells, qo.clip)
for e, segs in zip(shown, lines):
    text = "".join(t for t, _ in segs)
    if e["kind"] != "sess":
        continue
    assert qo.cells(text) == W, (qo.cells(text), text)
    assert segs[1][0] == gl[e["sym"]], segs
    assert segs[3][0] == (e["id"] or "").ljust(8) + " " and "bold" in segs[3][1], segs[3]
    agent = (e["agent"] or "").capitalize() or "未知"
    assert segs[4][0] == agent.ljust(7 - (qo.cells(agent) - len(agent))) + " ", segs[4]
    assert ("dim" in segs[4][1]) == (not e["agent"]) or e.get("lost"), segs[4]
    repo = segs[6][0]
    assert qo.cells(repo) == 15 and repo.startswith(" ") and repo.endswith(" "), repr(repo)
    red = any(st.startswith("c") for st in segs[1][1])
    assert red == (e["sym"] in ("needs", "fail")) and (not red or "bold" in segs[1][1]), segs[1]
    for bad in ("#4539", "会坏", "mac-a", "1/2", "merged"):
        assert bad not in text, (bad, text)
    if e["target"] == "@1":
        assert repo.strip() == "", repo
    if e["target"] == "@4":
        assert repo.strip() == "other-repo-w…" and qo.cells(repo.strip()) == 13, repo
    if e["target"] == "MU/far2":
        assert all("dim" in st for _, st in segs), segs
lit = lines[at]
assert all("lit" in st for _, st in lit), lit
long = dict(by["@2"], text="很长的标题第一段，" + "后面还有非常非常长的说明文字" * 6)
segs = fv.row_segs(long, W, qo.cells, qo.clip)
name = segs[5][0].rstrip()
assert name == "很长的标题第一段…" or name.endswith("…"), name
cut = fv.clip_name("前一半的文字比较长，后一半" + "很长" * 30, 34, qo.cells, qo.clip)
assert cut == "前一半的文字比较长…", cut
narrow = fv.row_segs(by["@2"], 50, qo.cells, qo.clip)
assert qo.cells("".join(t for t, _ in narrow)) == 50 and "claude-fleet" not in "".join(t for t, _ in narrow)

# --- E: search
v = [e["target"] for e in fv.visible(it, "4539", set()) if e["kind"] == "sess"]
assert v == ["@2"], v                                           # #45390 is not 4539
v = [e["target"] for e in fv.visible(it, "#4539", set()) if e["kind"] == "sess"]
assert v == ["@2"], v
assert fv.match_why(by["@2"], "4539") == "匹配：关联 issue #4539"
assert fv.match_why(by["@2"], "批量") == ""
v = [e["target"] for e in fv.visible(it, "T484", set()) if e["kind"] == "sess"]
assert v == ["@3"], v
note, red = fv.note_of(by["@4"])
assert "会坏·需重开" in note and red, (note, red)
note, red = fv.note_of(by["MU/far2"])
assert "失联" in note and not red, (note, red)
PY
pass "A  short names: 来自 X：…, T<n> prefix → ID, 修 #N：/ brackets / paths dropped"
pass "B  columns: ID (task → name prefix → blank), Agent (here: Claude; far: 未知), the row's own repo"
pass "C  ↻ ! ✓ ✗ ◌ ∙ ☾ ? — one cell each; ◌ only under 已结束; the legend"
pass "D  paint: glyph · ID · Agent · name · repo(13, kept blank); only ! ✗ red; cut at punctuation"
pass "E  search: issue number exact (4539 ≠ 45390), match_why; ID searched; note_of red on 会坏"
