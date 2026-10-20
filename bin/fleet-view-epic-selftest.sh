#!/bin/bash
# fleet-view-epic-selftest.sh — ⌘P hangs an EPIC's members under its driver
# (T507, T486 v18 定稿 ⑪–⑭; bin/fleet_view.py epic_tree / visible / row_segs).
#
#   A  only an EPIC hangs: a driver (@epic + @task) takes its hub children's open
#      rows into its own group, whatever their repo or state, ordered by task; an
#      ordinary dispatch stays flat; a member's name is the child's title
#   B  folded by default: only ! / ✗ members show (└ under the driver); the
#      driver says 已完成/总数 counting closed members; the heading counts every
#      session in its group — a folded member too (T541), the same number folded
#      or expanded; @expand=1 opens it (├ … └), epic_toggle writes @expand both ways
#   C  paint: ▸ / ▾ before the driver's name, N/N grey, !k red; a member's tree in
#      the name column only (glyph, ID, Agent, repo columns where they were)
#   D  a search still finds a folded member; the first frame (hub=False) reads the
#      kept copy only, never the hub; no driver ⇒ the list as before
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-epic selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvepic-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
unset NO_COLOR FLEET_COLOR FLEET_GLYPHS FLEET_VIEW_EPIC_SECS
mkdir -p "$WORK/conf"
cat > "$WORK/children.json" <<'JSON'
{"parent": "T497", "children": [
 {"id": "T498", "title": "C1 · 节点 ID 账本", "state": "succeeded", "outcome": "succeeded"},
 {"id": "T500", "title": "C2 · hub 镜像", "state": "succeeded", "outcome": "succeeded"},
 {"id": "T502", "title": "C4 · 结果改挂 ID", "state": "succeeded", "outcome": "succeeded"},
 {"id": "T503", "title": "C5 · EPIC 技能跟改", "state": "running", "outcome": ""},
 {"id": "T504", "title": "C6 · 迁移命令", "state": "running", "outcome": ""},
 {"id": "T509", "title": "C7 · 坏掉的", "state": "running", "outcome": ""}]}
JSON
export FLEET_VIEW_EPIC_CMD="echo \"\$1\" >> '$WORK/asked'; cat '$WORK/children.json'"


python3 - "$BIN" "$WORK" <<'PY' || st_fail "EPIC tree"
import importlib.util, os, sys, time
B, W = sys.argv[1], sys.argv[2]
def load(name, f):
    spec = importlib.util.spec_from_file_location(name, os.path.join(B, f))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
fv = load("fleet_view", "fleet_view.py")
qo = load("qo", "fleet-quickopen.py")
US = "\x1f"
now = int(time.time())
def full(*f, task="", agent="claude", repo=""):
    f = list(f) + [""] * (20 - len(f))
    return US.join(f + ["", task, agent, repo])
def hdr(*f): return US.join(f)
rows = "\n".join([
    hdr("hdr", "o/claude-fleet", "", "claude-fleet (6)", " "),
    full("@11", "working", "⠹", "w11", " ", "", "1", "", "", "", "—", "·", "ok", "来自 fleet：C5 · EPIC 技能跟改 父任务 T497", "merged",
         task="T503", repo="o/claude-fleet"),
    full("@14", "working", "⠹", "w14", " ", "", "1", "", "", "", "—", "·", "ok", "普通派单", "merged", task="T505", repo="o/claude-fleet"),
    full("@12", "done", "✓", "w12", " ", "", "0", "", "", "", "—", "·", "ok", "来自 fleet：C4", "merged", task="T502", repo="o/claude-fleet"),
    full("@13", "needs", "!", "w13", " ", "", "0", "question", "", "", "—", "·", "ok", "来自 fleet：C6", "merged", "", "question", "合不合？",
         task="T504", repo="o/claude-fleet"),
    full("@15", "failed", "x", "w15", " ", "", "0", "", "", "", "—", "·", "ok", "来自 fleet：C7", "merged", task="T509", repo="o/other"),
    hdr("hdr", "", "", "? · 未知仓库 (1)", " "),
    full("@10", "working", "⠹", "w10", " ", "", "0", "", "", "", "—", "·", "ok", "EPIC 会话T 驱动", "merged", task="T497"),
]) + "\n"
marks = {"@10": ("#T497", "")}
calls = []
def tm(*a, **k):
    calls.append(a)
    if a[:1] == ("set-option",):
        t = a[a.index("-t") + 1]
        if t in marks:
            marks[t] = (marks[t][0], "1" if "-w" in a and "-wu" not in a else "")
    return 0, ""
fv.tm = tm
fv.epic_windows = lambda fleet: dict(marks)
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "nodeA"
fv.fleet_logins = lambda: {}
fv.windows = lambda fleet: {"@%d" % i: ("", "worker", now - 60) for i in range(10, 16)}
fv.gone_text = lambda fleet: ""
fv.produce = lambda fleet, **kw: rows
fv.hub_view_request = lambda f: None
fv.hub_fresh = lambda f: None
asked = os.path.join(W, "asked")

# --- D (first): the first frame never asks the hub, and with no copy hangs nothing
it = fv.entries("v1", hub=False)
assert not os.path.exists(asked), "first frame asked the hub"
assert not any(e.get("epic") or e.get("fold") for e in it), "a tree with no copy"

# --- A
it = fv.entries("v1")
assert open(asked).read().split() == ["T497"], open(asked).read()
by = {e["target"]: e for e in it if e["kind"] == "sess"}
d = by["@10"]
assert d["epic"] == {"done": 3, "total": 6, "needs": 1, "fail": 1}, d["epic"]
assert not d["expanded"]
seq = [e["target"] for e in it if e["kind"] == "sess"]
i = seq.index("@10")
assert seq[i:i + 5] == ["@10", "@12", "@11", "@13", "@15"], seq    # by task: C4 T502 before C5 T503
for t in ("@11", "@12", "@13", "@15"):
    assert by[t]["fold"] == "@10" and by[t]["group"] == d["group"] and by[t]["depth"] == 0, by[t]
assert by["@11"]["text"] == "C5 · EPIC 技能跟改" and by["@13"]["text"] == "C6 · 迁移命令", by["@11"]["text"]
assert "fold" not in by["@14"] and by["@14"]["group"] == "work", by["@14"]
assert by["@12"]["sym"] == "done" and by["@15"]["repo"] == "other"
# a kept copy: the next read inside FLEET_VIEW_EPIC_SECS does not ask again
fv.entries("v1")
assert open(asked).read().split() == ["T497"], "asked again inside the window"

# --- B: folded — only ! / ✗ show, └ on the last
sh = fv.visible(it, "", set())
mem = [(e["target"], e.get("tree")) for e in sh if e["kind"] == "sess" and e.get("fold")]
assert mem == [("@13", "├ "), ("@15", "└ ")], mem
ask = [e for e in sh if e["kind"] == "ask" and e["of"] == "@13"]
assert ask and ask[0]["tree"] == "│ ", ask
hd = {e["group"]: e["text"] for e in it if e["kind"] == "hdr"}
assert hd[d["group"]] == fv.say("view_grp_%s_fmt" % d["group"], 6), hd     # @10 @14 + all 4 members, folded too (T541)
fv.epic_toggle(it, "fl", "@10", True)
assert any(c[:1] == ("set-option",) and "@expand" in c and "1" in c for c in calls), calls
assert marks["@10"][1] == "1"
sh = fv.visible(it, "", set())
mem = [(e["target"], e.get("tree")) for e in sh if e["kind"] == "sess" and e.get("fold")]
assert mem == [("@12", "├ "), ("@11", "├ "), ("@13", "├ "), ("@15", "└ ")], mem
hd = {e["group"]: e["text"] for e in it if e["kind"] == "hdr"}
assert hd[d["group"]] == fv.say("view_grp_%s_fmt" % d["group"], 6), hd     # expanded: the same count (T541)
# a member in another repo (@15, o/other) counts in its driver's group, not elsewhere
assert sum(1 for e in it if e["kind"] == "sess" and e["group"] == d["group"]) == 6
# ⑭: the window's mark is what the next read keeps
it2 = fv.entries("v1")
assert [e for e in it2 if e.get("epic")][0]["expanded"]
fv.epic_toggle(it2, "fl", "@10", False)
assert any("-wu" in c for c in calls) and marks["@10"][1] == ""

# --- C: paint
W_ = 100
it = fv.entries("v1")
sh = fv.visible(it, "", set())
lines = fv.paint(sh, -1, W_, qo.cells, qo.clip)
txt = {e.get("target"): (segs, "".join(t for t, _ in segs)) for e, segs in zip(sh, lines) if e["kind"] == "sess"}
segs, t = txt["@10"]
assert qo.cells(t) == W_, (qo.cells(t), t)
assert segs[5][0].startswith("▸ EPIC 会话T 驱动"), segs[5]
assert segs[6] == (" 3/6", ("dim",)), segs[6]
assert segs[7][0] == " !1" and any(s.startswith("c") for s in segs[7][1]), segs[7]
assert segs[8][0] == " ✗1", segs[8]
segs, t = txt["@13"]
assert qo.cells(t) == W_ and len(segs) == 7, segs
assert segs[5][0].startswith("├ C6 · 迁移命令"), segs[5]
assert segs[1][0] == "!" and segs[6][0].strip() == "claude-fleet", segs
n10 = txt["@10"][1].index("▸"); n13 = txt["@13"][1].index("├")
assert n10 == n13 == fv.name_col(W_), (n10, n13, fv.name_col(W_))

# --- D: a search finds a folded member, flat
hits = fv.visible(it, "技能", set())
assert [e["target"] for e in hits if e["kind"] == "sess"] == ["@11"] and not hits[0].get("tree"), hits

# no driver mark ⇒ the list as before
marks.clear()
it = fv.entries("v1")
assert not any(e.get("epic") or e.get("fold") for e in it), [(e.get("target"), e.get("epic"), e.get("fold")) for e in it if e.get("epic") or e.get("fold")]
flat = [e["target"] for e in fv.visible(it, "", set()) if e["kind"] == "sess"]
assert flat == ["@13", "@15", "@11", "@14", "@10", "@12"], flat
print("ok   A only an EPIC hangs · B folded ! / ✗, N/N, @expand · C paint · D search, first frame, no driver")
PY
