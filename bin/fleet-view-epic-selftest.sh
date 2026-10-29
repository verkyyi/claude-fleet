#!/bin/bash
# Legacy EPIC stamps must not change the task list: every member stays visible,
# flat, with no children reads, driver counters, expansion writes or state groups.
# Drives the real entries -> visible -> paint projection with isolated fixtures.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvepic-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
unset NO_COLOR FLEET_COLOR FLEET_GLYPHS FLEET_VIEW_EPIC_SECS
export FLEET_VIEW_BOARD=0   # the machine's live hub board is fleet-view-board-selftest.py's
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

# Legacy @epic stamps and children books must no longer create a UI hierarchy.
for hub in (False, True):
    it = fv.entries("v1", hub=hub)
    assert not os.path.exists(asked), "task list queried a legacy child ledger"
    assert not any(e.get("epic") or e.get("fold") for e in it)
    shown = fv.visible(it, "", set())
    targets = [e["target"] for e in shown if e["kind"] == "sess"]
    # one order (task DDBQ): asking (@13) and failed (@15) are not lifted
    assert targets == ["@11", "@14", "@12", "@13", "@15", "@10"], targets
    assert not any(e["kind"] in ("hdr", "ask") for e in shown), shown
    assert all(e.get("depth", 0) == 0 for e in shown)
    text = "\n".join("".join(t for t, _ in segs) for segs in fv.paint([e for e in shown if e["kind"] == "sess"], -1, 100, qo.cells, qo.clip))
    assert "3/6" not in text and "├" not in text and "▸" not in text, text
    hits = fv.visible(it, "技能", set())
    assert [e["target"] for e in hits] == ["@11"], hits
assert not calls, "list wrote tmux EPIC expansion state"
print("ok legacy EPIC stamps ignored; every task flat; no children reads, driver counts or expansion writes")
PY
