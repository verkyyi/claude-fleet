#!/bin/bash
# fleet-view-id-selftest.sh — ⌘P's ID column is the window's own short code
# (EPIC T497 C3, design page §8; fleet_view.py's id_* over bin/fleet_id.py's ledger).
#
#   A  the ID column: `T-` + 5 (a window's ledger `short`, else the prefix this login
#      knows no other ID to share); two IDs sharing 5 ⇒ 6; no @fleet_id ⇒ blank,
#      never a `T?`; a hub task's T<n> is an alias only (searched, not drawn);
#      another machine's row gets its code off its worker_id; offline the same (S9)
#   B  Agent: the newest native segment's (S4: a transfer reads Codex), else the one
#      it was opened with, else 未知 (grey) — never a guess when the ledger says none
#   C  results: the newest wins on a live idle window (S2: done then failed ⇒ ✗ 等你);
#      a working window keeps ↻; a reaped row whose ledger closed with no result is
#      ◌ 已退出 (S7), with one is its result
#   D  conflict (S9): two live windows on one native segment are both red 「等你」,
#      the other's code as the reason; close one and the other recovers
#   E  search: `4539` / `#4539` finds the ID whose ledger links issue 4539 (the
#      dispatch words' #N, results' issues), never 45390; the code and an alias find
#      their row
#   F  the actions page's ID block: code + full ID, aliases, every segment (agent ·
#      start–end · trigger · compactions), 未登记到 hub / a refusal in red, the
#      conflict's reason; no predecessor anywhere
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-id selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvid-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
unset NO_COLOR FLEET_COLOR FLEET_GLYPHS FLEET_ID_DIR
mkdir -p "$WORK/conf"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
pass() { echo "ok   $*"; }

python3 - "$BIN" <<'PY' || fail "ID column"
import importlib.util, json, os, re, sys, time
B = sys.argv[1]
sys.path.insert(0, B)
def load(name, f):
    spec = importlib.util.spec_from_file_location(name, os.path.join(B, f))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
fv = load("fleet_view", "fleet_view.py")
qo = load("qo", "fleet-quickopen.py")
import fleet_id as fi
US = "\x1f"
now = int(time.time())

F = {   # @2 and @3 share their first 7 hex digits ⇒ their first 5 code characters
    "@1": "11111111-1111-4111-8111-111111111111",
    "@2": "2222222f-2222-4222-8222-222222222222",
    "@3": "22222220-3333-4333-8333-333333333333",
    "@4": "44444444-4444-4444-8444-444444444444",
    "@5": "55555555-5555-4555-8555-555555555555",
    "@6": "66666666-6666-4666-8666-666666666666",
    "@7": "",
}
GONE = "77777777-7777-4777-8777-777777777777"
GONE2 = "88888888-8888-4888-8888-888888888888"
FAR = "99999999-9999-4999-8999-999999999999"
def ev(fid, **kw):
    fi.append(fid, kw)
ev(F["@1"], ev="opened", agent="claude", key="scratch-3", title="并行看一下")
ev(F["@1"], ev="native", agent="claude", native="nat-A", trigger="startup", seg=1)
ev(F["@2"], ev="opened", agent="claude", key="scratch-4", task="T367",
   body="修 verkyyi/claude-fleet#4539：批量切换检查仍用旧进程计数")
ev(F["@2"], ev="native", agent="claude", native="nat-B", trigger="startup", seg=1)
ev(F["@2"], ev="native", agent="claude", native="nat-B", compact=True, seg=1)
ev(F["@2"], ev="native", agent="claude", native="nat-B", compact=True, seg=1)
ev(F["@2"], ev="native", agent="codex", native="cx-1", trigger="transfer", seg=2)
ev(F["@3"], ev="opened", agent="claude", key="issue-4600")
ev(F["@3"], ev="native", agent="claude", native="nat-C", trigger="startup", seg=1)
ev(F["@3"], ev="result", state="done", summary="合了")
ev(F["@3"], ev="result", state="failed", summary="又坏了", issues=["o/r#4601"])
ev(F["@4"], ev="opened", key="scratch-9", lazy=True)            # no agent anywhere
ev(F["@5"], ev="opened", agent="claude", key="scratch-5")
ev(F["@5"], ev="native", agent="claude", native="nat-A", trigger="resume", seg=1)   # @1's segment
ev(F["@6"], ev="opened", agent="claude", key="scratch-6")
ev(F["@6"], ev="native", agent="claude", native="nat-D", trigger="startup", seg=1)
ev(F["@6"], ev="result", state="done")
ev(GONE, ev="opened", agent="codex", key="issue-4700")
ev(GONE, ev="native", agent="codex", native="cx-9", trigger="startup", seg=1)
ev(GONE, ev="closed", reason="reaped")
ev(GONE2, ev="opened", agent="claude", key="issue-4701")
ev(GONE2, ev="result", state="merged", pr="12")
ev(GONE2, ev="closed", reason="reaped")
# the hub has @1 (seq file); @2 never acknowledged; @6 refused (a cloned machine)
os.makedirs(fi.hub_dir(), exist_ok=True)
open(os.path.join(fi.hub_dir(), F["@1"] + ".seq"), "w").write("2 100\n")
open(os.path.join(fi.hub_dir(), F["@6"] + ".refused"), "w").write("DUPLICATE_ID\n")

def full(*f, task="", agent="", repo=""):
    f = list(f) + [""] * (20 - len(f))
    return US.join(f + ["", task, agent, repo])
def rows(states):
    out = [US.join(("hdr", "o/claude-fleet", "", "claude-fleet (6)", " "))]
    for w, st in states.items():
        out.append(full(w, st, "·", "w" + w[1:], " ", "", "0", "", "", "", "—", "·", "ok", "会话" + w[1:], "merged",
                        task={"@2": "T367"}.get(w, ""), agent="claude", repo="o/claude-fleet"))
    out.append(full("wid:MU/" + FAR, "working", "⠹", "far", " ", "", "0", "", "mac-a", "", "—", "·", "ok", "别处的", "merged"))
    return "\n".join(out) + "\n"
STATES = {"@1": "idle", "@2": "working", "@3": "idle", "@4": "idle", "@5": "idle", "@6": "working", "@7": "idle"}
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "nodeA"
fv.fleet_logins = lambda: {"MU": "carol"}
fv.hub_view_request = lambda f: None
fv.hub_fresh = lambda f: None
fv.gone_text = lambda fleet: "x"
fv.gone_rows = lambda text, _now=None: [
    ("landed:issue:4700@o/claude-fleet", "✗", "#4700", "g1", "收掉的", "1 hour", "—", now - 60),
    ("landed:issue:4701@o/claude-fleet", "✓", "#4701", "g2", "合了的", "1 hour", "#12", now - 60),
]
def read(states, wins=None):
    wins = wins or F
    fv.windows = lambda fleet: {w: (wins[w], "worker", now - 60) for w in states}
    fv.produce = lambda fleet, **kw: rows(states)
    it = fv.entries("v1")
    return it, {e["target"]: e for e in it if e["kind"] == "sess"}
it, by = read(STATES)
code = lambda w: by[w]["id"]

# --- A: the ID column
for w in ("@1", "@4", "@5", "@6"):
    assert re.fullmatch(r"T-[0-9a-hjkmnp-tv-z]{5}", code(w)), (w, code(w))
assert code("@1") == fi.fold(fi.read(F["@1"]))["opened"].get("short") or code("@1") == fi.short_for(F["@1"], fi.known_ids())
assert len(code("@2")) == len(code("@3")) == 8 and code("@2")[:7] == code("@3")[:7] and code("@2") != code("@3"), \
    (code("@2"), code("@3"))
assert code("@7") == "" and "T?" not in json.dumps([e.get("id") for e in by.values()]), code("@7")
assert by["@2"]["aliases"] == ["T367"], by["@2"]["aliases"]
assert re.fullmatch(r"T-\w{5}", by["MU/" + FAR]["id"]), by["MU/" + FAR]["id"]
assert fi.resolve(code("@2"))[1] == [F["@2"]] and fi.resolve(code("@2")[:7])[0] == 2
lines = fv.paint(fv.visible(it, "", set()), -1, 100, qo.cells, qo.clip)
drawn = ["".join(t for t, _ in l) for l in lines]
assert any(code("@2") + " " in d for d in drawn) and not any("T367" in d or "#4539" in d for d in drawn), drawn

# --- B: Agent
assert by["@2"]["agent"] == "codex" and by["@1"]["agent"] == "claude", (by["@2"]["agent"], by["@1"]["agent"])
assert by["@4"]["agent"] == "" and fv.agent_word(by["@4"]) == "未知", by["@4"]["agent"]
seg = fv.row_segs(by["@4"], 100, qo.cells, qo.clip)
assert seg[4][0].startswith("未知") and "dim" in seg[4][1], seg[4]
assert by["@7"]["agent"] == "claude"          # no ID, no ledger: the producer's word, as before

# --- C: results
assert by["@3"]["state"] == "failed" and by["@3"]["sym"] == "fail" and by["@3"]["group"] == "ask", by["@3"]
assert by["@6"]["sym"] == "work", by["@6"]         # working keeps ↻ over a done result
it2, by2 = read(dict(STATES, **{"@6": "idle"}))
assert by2["@6"]["sym"] == "done" and by2["@6"]["group"] == "done", by2["@6"]
g = {e["issue"]: e for e in it if e.get("gone")}
assert g["#4700"]["sym"] == "exited" and g["#4700"]["word"] == "已退出" and re.fullmatch(r"T-\w{5}", g["#4700"]["id"]) \
    and g["#4700"]["agent"] == "codex", g["#4700"]
assert g["#4701"]["sym"] == "done", g["#4701"]

# --- D: conflict
for w, other in (("@1", "@5"), ("@5", "@1")):
    e = by[w]
    assert e["group"] == "ask" and e["sym"] == "needs" and e["conflict"] == code(other), (w, e)
red = fv.row_segs(by["@1"], 100, qo.cells, qo.clip)[1]
assert red[0] == "!" and any(s.startswith("c") for s in red[1]), red
_, by3 = read({w: s for w, s in STATES.items() if w != "@5"})
assert not by3["@1"].get("conflict") and by3["@1"]["group"] != "ask", by3["@1"]

# --- E: search
sess = lambda q: [e["target"] for e in fv.visible(it, q, set()) if e["kind"] == "sess"]
assert sess("4539") == ["@2"] and sess("#4539") == ["@2"], sess("4539")
assert fv.match_why(by["@2"], "#4539") == "匹配：关联 issue #4539"
assert sess("45390") == [] and sess("4601") == ["@3"] and sess("4600") == ["@3"], (sess("45390"), sess("4601"))
assert sess(code("@4").lower()) == ["@4"] and sess("T367") == ["@2"], (sess(code("@4")), sess("T367"))

# --- F: the actions page's block
txt = lambda e: [(t.strip(), st) for t, st in fv.id_page(e, 100)]
p2 = txt(by["@2"])
assert ("编号 %s  ·  %s" % (code("@2"), F["@2"]), ("dim",)) in p2, p2
assert ("别名 T367", ("dim",)) in p2, p2
segs = [t for t, _ in p2 if t.startswith("段 ")]
assert len(segs) == 2 and "Claude" in segs[0] and "startup" in segs[0] and "压缩×2" in segs[0] \
    and "Codex" in segs[1] and "transfer" in segs[1], segs
assert ("未登记到 hub", ("dim",)) in p2, p2
assert not any("未登记" in t for t, _ in txt(by["@1"])), txt(by["@1"])
assert any("hub 拒收" in t and st == ("red",) for t, st in txt(by2["@6"])), txt(by2["@6"])
assert any(t.startswith("冲突：与 " + code("@5")) and st == ("red",) for t, st in txt(by["@1"])), txt(by["@1"])
assert ("还没有对话段", ("dim",)) in txt(by["@4"]) and fv.id_page(by["@7"], 100) == []
for e in by.values():
    assert "prev" not in e and not any("prev" in t or "前任" in t for t, _ in fv.id_page(e, 100))
PY
pass "A  ID column: T- + 5 (6 when two share), blank without an ID, T<n> an alias, far rows too"
pass "B  Agent: newest segment (transfer → Codex), else opened, else 未知 (grey)"
pass "C  results: newest wins (done → failed = ✗ 等你), working keeps ↻, reaped without one = ◌ 已退出"
pass "D  conflict: two live windows on one segment both red 等你; closing one clears it"
pass "E  search: 4539 / #4539 via the ID's issues, not 45390; code and alias find their row"
pass "F  actions page: code + ID, aliases, segments, 未登记到 hub / refusal red, conflict reason"
