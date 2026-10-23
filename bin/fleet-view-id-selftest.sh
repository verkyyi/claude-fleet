#!/bin/bash
# fleet-view-id-selftest.sh — ⌘P's ID column is the window's own short code
# (EPIC T497 C3, design page §8; fleet_view.py's id_* over bin/fleet_id.py's ledger).
#
#   A  the ID column: 4 uppercase, a letter first, no `T-` (C11 — a window's ledger
#      `short`, else the prefix this login knows no other ID to share); two IDs
#      sharing 4 ⇒ 5; no @fleet_id ⇒ blank, never a `T?`; a hub task's T<n> and the
#      old `T-` code are aliases only (searched, not drawn); another machine's row
#      gets its code off its worker_id; offline the same (S9)
#   B  Agent: the newest native segment's (S4: a transfer reads Codex), else the one
#      it was opened with, else the window's @cc_agent (a window opened before C1 —
#      EPIC T497 C17), else the hub record's actual_agent, else 未知 (grey)
#   C  results never replace a live native state (including idle and unknown);
#      a reaped row whose ledger closed with no result is
#      ◌ 已退出 (S7), with one is its result
#   D  conflict (S9): two live windows on one native segment are both red 「等你」,
#      the other's code as the reason; close one and the other recovers
#   E  search: `4539` / `#4539` finds the ID whose ledger links issue 4539 (the
#      dispatch words' #N, results' issues), never 45390; the code and an alias find
#      their row
#   F  the actions page's ID block: code + full ID, aliases, every segment (agent ·
#      start–end · trigger · compactions), 未登记到 hub / a refusal in red, the
#      conflict's reason; no predecessor anywhere
#   G  repo (T593): a row whose window has no @repo takes its ledger's / its task
#      record's / an EPIC charter marker's `repo=` (a relay through opened.prev);
#      none ⇒ blank. A closed row finds its ID by its conversation (a scratch key is
#      recycled); a closed ID no history row lists is a row of its own, with its Agent
#   H  the read path with 200 closed IDs starts no process and asks no hub (records
#      come off view-tasks.json, a detached filler fills it) and takes < 100 ms
#   I  2 places (EPIC T644 C4): among 20 unfinished rows the two sharing their first
#      2 show 3, the rest 2, the page keeps the written 4; once one ends its
#      neighbour is 2 again; typing 2 lists both (an unfinished one first, never a
#      pick), fleet_id.resolve_open says rc 2; ids/.open feeds the top bar and the
#      notification title the same length; current work stays visible even when
#      the task has a previous result (PV4D)
#      — fleet_id.py display_short / resolve_open / open_save, fleet-topbar.py ticket,
#      fleet_notify.py subject
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-lib.sh"
st_need python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvid-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_CONF_DIR="$WORK/conf" FLEET_STATUS_G="$WORK/g" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
unset NO_COLOR FLEET_COLOR FLEET_GLYPHS FLEET_ID_DIR
mkdir -p "$WORK/conf"


python3 - "$BIN" <<'PY' || st_fail "ID column"
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

F = {   # @2 and @3 share their first 7 hex digits ⇒ their first 4 code characters
    "@1": "11111111-1111-4111-8111-111111111111",
    "@2": "2222222f-2222-4222-8222-222222222222",
    "@3": "22222220-3333-4333-8333-333333333333",
    "@4": "44444444-4444-4444-8444-444444444444",
    "@5": "55555555-5555-4555-8555-555555555555",
    "@6": "66666666-6666-4666-8666-666666666666",
    "@7": "",
    "@8": "aaaaaaaa-8888-4888-8888-888888888888",
    "@9": "bbbbbbbb-9999-4999-8999-999999999999",
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
ev(F["@8"], ev="progress", summary="tick")                      # opened before C1: no opened, no segment
ev(F["@9"], ev="opened", key="scratch-19", task="T901", lazy=True)   # only the hub knows its agent
TG = os.path.join(os.environ["FLEET_CONF_DIR"], "taskget")
open(TG, "w").write('#!/bin/sh\n[ "$1" = T901 ] && echo \'{"task":{"id":"T901","actual_agent":"codex"}}\' && exit 0\necho \'{"task":{}}\'\n')
os.chmod(TG, 0o755)
os.environ["FLEET_VIEW_TASK_GET"] = TG
# a frame reads the hub records off view-tasks.json only; what it lacks is queued
# for the detached filler (T593) — here the filler runs in line, nothing spawned
SPAWNED = []
fv.task_cache_spawn = lambda tasks: SPAWNED.append(sorted(tasks))
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
                        task={"@2": "T367"}.get(w, ""), agent={"@4": "?", "@8": "codex", "@9": "?"}.get(w, "claude"),
                        repo="o/claude-fleet"))
    out.append(full("wid:MU/" + FAR, "working", "⠹", "far", " ", "", "0", "", "mac-a", "", "—", "·", "ok", "别处的", "merged"))
    return "\n".join(out) + "\n"
STATES = {"@1": "idle", "@2": "working", "@3": "idle", "@4": "idle", "@5": "idle", "@6": "working", "@7": "idle", "@8": "idle", "@9": "idle"}
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
assert by["@9"]["agent"] == "" and SPAWNED and "T901" in SPAWNED[-1], (by["@9"], SPAWNED)   # not waited for
fv.task_cache_fill(SPAWNED[-1])
it, by = read(STATES)
code = lambda w: by[w].get("code") or by[w]["id"]   # the WRITTEN code (≥ 4); `id` is what the column shows (C4)

# --- A: the ID column
for w in ("@1", "@4", "@5", "@6"):
    assert re.fullmatch(r"[A-HJKMNP-TV-Z][0-9A-HJKMNP-TV-Z]{3}", code(w)), (w, code(w))
assert code("@1") == fi.fold(fi.read(F["@1"]))["opened"].get("short") or code("@1") == fi.short_for(F["@1"], fi.known_ids())
assert len(code("@2")) == len(code("@3")) == 5 and code("@2")[:4] == code("@3")[:4] and code("@2") != code("@3"), \
    (code("@2"), code("@3"))
assert code("@7") == "" and "T?" not in json.dumps([e.get("id") for e in by.values()]), code("@7")
old2 = "T-" + fi.legacy_encode(F["@2"])[:5]
assert by["@2"]["aliases"] == ["T367", old2], by["@2"]["aliases"]
assert re.fullmatch(r"[A-Z]\w{3}", by["MU/" + FAR]["code"]) and by["MU/" + FAR]["code"].startswith(by["MU/" + FAR]["id"]), by["MU/" + FAR]
assert fi.resolve(code("@2"))[1] == [F["@2"]] and fi.resolve(code("@2")[:4])[0] == 2
lines = fv.paint(fv.visible(it, "", set()), -1, 100, qo.cells, qo.clip)
drawn = ["".join(t for t, _ in l) for l in lines]
assert any(by["@2"]["id"] + " " in d for d in drawn) and not any("T367" in d or "#4539" in d or old2 in d for d in drawn), drawn

# --- B: Agent
assert by["@2"]["agent"] == "codex" and by["@1"]["agent"] == "claude", (by["@2"]["agent"], by["@1"]["agent"])
assert by["@4"]["agent"] == "" and fv.agent_word(by["@4"]) == "未知", by["@4"]["agent"]
seg = fv.row_segs(by["@4"], 100, qo.cells, qo.clip)
assert seg[4][0].startswith("未知") and "dim" in seg[4][1], seg[4]
assert by["@7"]["agent"] == "claude"          # no ID, no ledger: the producer's word, as before
assert by["@8"]["agent"] == "codex", by["@8"]   # C17: no segment, no opened agent ⇒ the window's @cc_agent
assert by["@9"]["agent"] == "codex", by["@9"]   # C17: nor a window word ⇒ the hub record's actual_agent

# --- C: results
assert by["@3"]["state"] == "idle" and by["@3"]["sym"] == "idle" and by["@3"]["group"] == "queue", by["@3"]
assert by["@6"]["sym"] == "work", by["@6"]         # working keeps ↻ over a done result
it2, by2 = read(dict(STATES, **{"@6": "idle"}))
assert by2["@6"]["sym"] == "idle" and by2["@6"]["group"] == "queue", by2["@6"]
# A historical blocked result is not a new question. Exercise the real ledger
# and producer read path; the stored result remains available as history.
for result in ("blocked", "failed", "done", "merged"):
    ev(F["@3"], ev="result", state=result)
    for native in ("idle", "working", "looping", "needs", "exited", "unknown"):
        _, observed = read(dict(STATES, **{"@3": native}))
        e = observed["@3"]
        assert e["state"] == native, (result, native, e)
        assert fv.task_status(e) == {"working": "work", "needs": "needs"}.get(native, "quiet"), (result, native, e)
assert fi.fold(fi.read(F["@3"]))["results"][-1]["state"] == "merged"
# The separately cached Hub outcome must not turn a live idle row into done.
from unittest.mock import patch
for outcome in ("succeeded", "failed", "cancelled", "refused"):
    with patch.object(fv, "hub_task", return_value={"outcome": outcome}):
        _, observed = read(dict(STATES, **{"@2": "idle"}))
    assert observed["@2"]["state"] == "idle" and observed["@2"]["open_id"], (outcome, observed["@2"])
g = {e["issue"]: e for e in it if e.get("gone")}
assert g["#4700"]["sym"] == "exited" and g["#4700"]["word"] == "已退出" and re.fullmatch(r"[A-Z]\w{3}", g["#4700"]["id"]) \
    and g["#4700"]["agent"] == "codex", g["#4700"]
assert g["#4701"]["sym"] == "done", g["#4701"]

# --- D: conflict
for w, other in (("@1", "@5"), ("@5", "@1")):
    e = by[w]
    assert e["group"] == "ask" and e["sym"] == "needs" and e["conflict"] == code(other), (w, e)
red = fv.row_segs(by["@1"], 100, qo.cells, qo.clip)[1]
assert red[0] == "!" and any(s.startswith("c") for s in red[1]), red
_, by3 = read({w: s for w, s in STATES.items() if w != "@5"})
assert not by3["@1"].get("conflict") and by3["@1"]["sym"] == "idle", by3["@1"]      # idle: 等你 by itself (回收 D), not red

# --- E: search
sess = lambda q: [e["target"] for e in fv.visible(it, q, set()) if e["kind"] == "sess"]
assert sess("4539") == ["@2"] and sess("#4539") == ["@2"], sess("4539")
assert fv.match_why(by["@2"], "#4539") == "匹配：关联 issue #4539"
assert sess("45390") == [] and sess("4601") == ["@3"] and sess("4600") == ["@3"], (sess("45390"), sess("4601"))
assert sess(code("@4").lower()) == ["@4"] and sess("T367") == ["@2"], (sess(code("@4")), sess("T367"))
old6 = "t-" + fi.legacy_encode(F["@2"])[:6]   # the old 5 are shared by @2 and @3, like the new 4
assert sess("#" + code("@4")) == ["@4"] and sess(old6) == ["@2"], (sess("#" + code("@4")), sess(old6))

# --- F: the actions page's block
txt = lambda e: [(t.strip(), st) for t, st in fv.id_page(e, 100)]
p2 = txt(by["@2"])
assert ("编号 %s  ·  %s" % (code("@2"), F["@2"]), ("dim",)) in p2, p2
assert ("别名 T367 " + old2, ("dim",)) in p2, p2
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

# --- G: a row's repo when its window has none, and a closed row's Agent (T593)
G = {w: "%08x-%04x-4%03x-8%03x-%012x" % (0xc0de0000 + i, i, i, i, i)
     for i, w in enumerate(("@20", "@21", "@22", "@23", "@24"), 1)}
DRV0, OLDGEN, NOW42, ALONE, DEAD = ("%08x-0000-4000-8000-%012x" % (0xd0d00000 + i, i) for i in range(1, 6))
ev(DRV0, ev="opened", agent="claude", task="T910", title="EPIC: 一路")
ev(DRV0, ev="native", agent="claude", native="nat-E", trigger="startup", seg=1)
ev(DRV0, ev="closed", reason="stopped")
ev(G["@20"], ev="opened", agent="claude", task="T910", title="EPIC: 一路")          # the driver (@norepo)
ev(G["@21"], ev="opened", agent="claude", prev=DRV0, title="EPIC: 一路")           # its relay: no task of its own
ev(G["@22"], ev="opened", agent="claude", task="T911", title="无仓库的活")
ev(G["@23"], ev="opened", agent="claude", title="编排")                           # no task, no repo
ev(G["@24"], ev="opened", agent="claude", task="T912", title="普通的活")           # the record names its repo
ev(OLDGEN, ev="opened", agent="codex", key="scratch-42")                          # scratch-42's last generation
ev(OLDGEN, ev="native", agent="codex", native="cx-old", trigger="startup", seg=1)
ev(OLDGEN, ev="closed", reason="reaped")
ev(NOW42, ev="opened", key="scratch-42", lazy=True)                               # this one: reaped, never closed
ev(NOW42, ev="native", agent="claude", native="nat-H", trigger="startup", seg=1)
ev(NOW42, ev="result", state="merged", pr="77")
ev(ALONE, ev="opened", agent="codex", title="5018验证 · codex")                    # no history row lists it
ev(ALONE, ev="native", agent="codex", native="cx-A", trigger="startup", seg=1)
ev(ALONE, ev="closed", reason="stopped")
ev(DEAD, ev="closed", reason="stopped")                                           # C13's empty record
open(TG, "w").write('''#!/bin/sh
case "$1" in
T910) printf '%s\\n' '{"task":{"id":"T910","repo":"","request_payload":"{\\"body\\":\\"/fleet-epic-run\\\\n\\\\n<!-- fleet:epic repo=o/claude-fleet short=一路 cap=4 -->\\\\n# EPIC\\"}"}}' ;;
T911) echo '{"task":{"id":"T911","repo":"","request_payload":"{\\"body\\":\\"只做一件事\\"}"}}' ;;
T912) echo '{"task":{"id":"T912","repo":"o/other-repo"}}' ;;
*) echo '{"task":{}}' ;;
esac
''')
fv.task_cache_fill(["T910", "T911", "T912"])
def rows_g():
    out = [US.join(("hdr", "o/claude-fleet", "", "claude-fleet (1)", " ")),
           full("@1", "idle", "·", "w1", " ", "", "0", "", "", "", "—", "·", "ok", "会话1", "merged", agent="claude",
                repo="o/claude-fleet"),
           US.join(("hdr", "none", "", "无仓库 (5)", " "))]
    for w, t in (("@20", "T910"), ("@21", ""), ("@22", "T911"), ("@23", ""), ("@24", "T912")):
        out.append(full(w, "working", "⠹", "w" + w[1:], " ", "", "0", "", "", "", "—", "·", "ok", "会话" + w[1:], "merged",
                        task=t, agent="claude"))
    return "\n".join(out) + "\n"
GW = dict(G, **{"@1": F["@1"]})
fv.windows = lambda fleet: {w: (GW[w], "worker", now - 60) for w in GW}
fv.produce = lambda fleet, **kw: rows_g()
fv.gone_text = lambda fleet: "landed:scratch:scratch-42@o/claude-fleet" + US + "nat-H" + US + "x\n"
fv.gone_rows = lambda text, _now=None: [
    ("landed:scratch:scratch-42@o/claude-fleet", "✓", "~42", "c17", "C17 · 补段", "1 hour", "#77", now - 60)]
itg = fv.entries("v1")
bg = {e["target"]: e for e in itg if e["kind"] == "sess"}
assert bg["@20"]["repo"] == "claude-fleet", bg["@20"]        # an EPIC driver: the charter marker's repo=
assert bg["@21"]["repo"] == "claude-fleet", bg["@21"]        # its relay: through opened.prev
assert bg["@22"]["repo"] == "" and bg["@23"]["repo"] == "", (bg["@22"], bg["@23"])   # truly none: blank
assert bg["@24"]["repo"] == "other-repo" and "other-repo" in bg["@24"]["tags"], bg["@24"]   # the record's; 2 repos ⇒ tagged
h42 = bg["landed:scratch:scratch-42@o/claude-fleet"]
assert h42["fid"] == NOW42 and h42["agent"] == "claude", h42   # by its conversation, not the recycled key
al = bg["id:" + ALONE]
assert al["agent"] == "codex" and al["gone"] and al["sec"] == "gone" and al["text"].startswith("5018"), al
assert "id:" + DEAD not in bg and "id:" + DRV0 in bg and bg["id:" + DRV0]["agent"] == "claude", sorted(bg)
assert "id:" + OLDGEN in bg and bg["id:" + OLDGEN]["agent"] == "codex", sorted(bg)
assert not any(a[0]["id"] == "resume" for a in fv.page_of(al)) and any(a[0]["id"] == "resume" for a in fv.page_of(h42)), \
    (fv.page_of(al), fv.page_of(h42))   # nothing to restore off a ledger alone

# --- H: the read path with 200 closed IDs — no process started, no hub asked, < 100 ms (T593)
import subprocess, shutil
for i in range(200):
    f = "%08x-0000-4000-8000-%012x" % (0xe0000000 + i, i)
    ev(f, ev="opened", agent=("claude", "codex")[i % 2], key="scratch-%d" % (i % 30), task="T%d" % (2000 + i),
       title="关掉的 %d" % i)
    ev(f, ev="native", agent=("claude", "codex")[i % 2], native="nat-p%d" % i, trigger="startup", seg=1)
    ev(f, ev="result", state="merged", pr=str(i))
    ev(f, ev="closed", reason="reaped")
txt = "".join("landed:scratch:scratch-%d@o/claude-fleet%snat-p%d%sx\n" % (i % 30, US, i, US) for i in range(200))
fv.gone_text = lambda fleet: txt
fv.gone_rows = lambda text, _now=None: [("landed:scratch:scratch-%d@o/claude-fleet" % (i % 30), "✓", "~%d" % (i % 30),
                                         "g%d" % i, "关掉的 %d" % i, "1 hour", "#%d" % i, now - 60) for i in range(30)]
runs = []
real = (subprocess.run, subprocess.Popen)
def no_proc(real_one):
    def call(argv, *a, **k):
        # tmux is the read path's own (the windows, the EPIC marks); a fleet script,
        # a hub read or a filler would be this change's — none may run in a frame
        if (argv or [""])[0] != "tmux":
            raise AssertionError("the read path started a process: %r" % (argv,))
        return real_one(argv, *a, **k)
    return call
for _ in range(3):
    fv._ID_CACHE.clear()          # a popup is a new process: nothing in memory
    subprocess.run, subprocess.Popen = no_proc(real[0]), no_proc(real[1])
    try:
        t0 = time.perf_counter()
        ith = fv.entries("v1", hub=False)
        runs.append((time.perf_counter() - t0) * 1000)
    finally:
        subprocess.run, subprocess.Popen = real
bh = [e for e in ith if e["kind"] == "sess" and e.get("gone")]
assert len(bh) >= 200 and sum(1 for e in bh if e["agent"]) >= 200, (len(bh), sum(1 for e in bh if e["agent"]))
assert min(runs) < 100, runs
print("   read with %d closed rows: %.0f ms (best of 3)" % (len(bh), min(runs)))
PY
st_ok_all "A  ID column: 4 uppercase, letter first (5 when two share), blank without an ID, T<n> and the old T- code aliases, far rows too"
st_ok_all "B  Agent: newest segment (transfer → Codex), else opened, else @cc_agent, else the hub's actual_agent, else 未知 (grey)"
st_ok_all "C  results stay historical: native idle/working/looping/needs/exited/unknown survive; closed rows retain their results"
st_ok_all "D  conflict: two live windows on one segment both red 等你; closing one clears it"
st_ok_all "E  search: 4539 / #4539 via the ID's issues, not 45390; code and alias find their row"
st_ok_all "F  actions page: code + ID, aliases, segments, 未登记到 hub / refusal red, conflict reason"
st_ok_all "G  repo: an EPIC driver's charter repo= (its relay too), a record's repo, none ⇒ blank; a closed row by its conversation, a closed ID alone is its own row (T593)"
st_ok_all "H  read path, 200 closed IDs: no process, no hub call, < 100 ms (T593)"

python3 - "$BIN" <<'PY' || st_fail "2 places"
import importlib.util, json, os, re, sys, time, uuid
B = sys.argv[1]
sys.path.insert(0, B)
def load(name, f):
    spec = importlib.util.spec_from_file_location(name, os.path.join(B, f))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
fv = load("fleet_view", "fleet_view.py")
tb = load("fleet_topbar", "fleet-topbar.py")
import fleet_id as fi, fleet_notify
US = "\x1f"
now = int(time.time())
# 20 unfinished IDs with 20 different first 2 places, and a 21st sharing its first 2
# with the first one (and not its third)
import hashlib
mk = lambda n: str(uuid.UUID(bytes=hashlib.sha256(b"c4-%d" % n).digest()[:16], version=4))
ids, seen, n = [], {}, 0
while len(ids) < 20:
    f = mk(n); n += 1
    c = fi.encode(f)
    if c[:2] not in seen:
        seen[c[:2]] = f; ids.append(f)
while True:
    f = mk(n); n += 1
    c = fi.encode(f)
    if c[:2] == fi.encode(ids[0])[:2] and c[2] != fi.encode(ids[0])[2]:
        CLASH = f; break
DONE_T = mk(n + 1)
for i, f in enumerate(ids + [CLASH, DONE_T]):
    fi.append(f, {"ev": "opened", "agent": "claude", "key": "scratch-%d" % (100 + i), "title": "活 %d" % i,
                  **({"task": "T950"} if f == DONE_T else {})})
TG = os.path.join(os.environ["FLEET_CONF_DIR"], "taskget2")
open(TG, "w").write('#!/bin/sh\n[ "$1" = T950 ] && echo \'{"task":{"id":"T950","outcome":"succeeded","authority_version":1}}\' && exit 0\necho \'{"task":{}}\'\n')
os.chmod(TG, 0o755)
os.environ["FLEET_VIEW_TASK_GET"] = TG
fv.task_cache_spawn = lambda tasks: None
fv.task_cache_fill(["T950"])
W = {"@%d" % (i + 1): f for i, f in enumerate(ids + [CLASH, DONE_T])}
def full(*f, task="", agent="claude", repo="o/claude-fleet"):
    f = list(f) + [""] * (20 - len(f))
    return US.join(f + ["", task, agent, repo])
for k, v in dict(view_row=lambda vid: {}, view_fleet=lambda vid, row=None: "fl", here_label=lambda row: "nodeA",
                 fleet_logins=lambda: {}, hub_view_request=lambda f: None, hub_fresh=lambda f: None,
                 gone_text=lambda fleet: "", gone_rows=lambda text, _now=None: []).items():
    setattr(fv, k, v)
def read(wins):
    fv.windows = lambda fleet: {w: (W[w], "worker", now - 60) for w in wins}
    def produce(fleet, **kw):
        out = [US.join(("hdr", "o/claude-fleet", "", "claude-fleet", " "))]
        for w in wins:
            out.append(full(w, "working", "⠹", "w" + w[1:], " ", "", "0", "", "", "", "—", "·", "ok", "活 " + w[1:],
                            "merged", task="T950" if W[w] == DONE_T else ""))
        return "\n".join(out) + "\n"
    fv.produce = produce
    it = fv.entries("v1", hub=False)
    return it, {W[e["target"]]: e for e in it if e["kind"] == "sess" and e["target"] in W}
it, by = read(list(W))
A, C = fi.encode(ids[0]), fi.encode(CLASH)
assert by[ids[0]]["id"] == A[:3] and by[CLASH]["id"] == C[:3], (by[ids[0]]["id"], by[CLASH]["id"])
assert all(len(by[f]["id"]) == 2 for f in ids[1:]), [by[f]["id"] for f in ids[1:]]
assert all(len(by[f]["code"]) >= 4 and by[f]["code"].startswith(by[f]["id"]) for f in ids), [by[f]["code"] for f in ids]
assert any(t.strip().startswith("编号 " + by[ids[1]]["code"]) for t, _ in fv.id_page(by[ids[1]], 100)), fv.id_page(by[ids[1]], 100)
# A past result does not hide new work (PV4D); its live identity stays addressable.
d = by[DONE_T]
assert d["group"] == "work" and d["sym"] == "work" and d["open_id"] and len(d["id"]) >= 2, d
assert fi.open_ids() == set(ids + [CLASH, DONE_T]), len(fi.open_ids())
# typing 2: both unfinished ones, never a pick; 3 is the one
sess = lambda q: [W.get(e["target"]) for e in fv.visible(it, q, set()) if e["kind"] == "sess"]
assert sorted(sess(A[:2].lower())) == sorted([ids[0], CLASH]), sess(A[:2])
assert sess(A[:3]) == [ids[0]] and sess("#" + by[ids[5]]["id"]) == [ids[5]], (sess(A[:3]), sess(by[ids[5]]["id"]))
assert fi.resolve_open(A[:2], fi.open_ids()) == (2, sorted([ids[0], CLASH])), fi.resolve_open(A[:2], fi.open_ids())
assert fi.resolve_open(A[:3], fi.open_ids()) == (0, [ids[0]])
# a finished row's 2 places stay out while an unfinished one answers them
dd = fi.encode(DONE_T)[:2]
if not any(fi.encode(f).startswith(dd) for f in ids + [CLASH]):
    assert sess(dd) == [DONE_T], sess(dd)
# the top bar and the notification title: the same 2 or 3
assert tb.ticket("", "T950", ids[3]) == by[ids[3]]["id"] and tb.ticket("", "", CLASH) == C[:3], tb.ticket("", "", CLASH)
assert tb.ticket("4539", "", ids[3]) == "#4539" and tb.ticket("", "T12", "") == "T12"
assert fleet_notify.subject({"wid": "U/" + ids[3], "name": "活"}) == by[ids[3]]["id"] + " · 活"
assert fleet_notify.subject({"wid": "U/issue-7", "issue": 7}) == "#7"
# the clash ends (its window gone): its neighbour is 2 again
it, by = read([w for w in W if W[w] != CLASH])
assert by[ids[0]]["id"] == A[:2], by[ids[0]]["id"]
assert fi.resolve_open(A[:2], fi.open_ids()) == (0, [ids[0]]) and tb.ticket("", "", ids[0]) == A[:2]
print("   2 places: %s · %s (clash) · %s … ; after: %s" % (A[:3], C[:3], by[ids[1]]["id"], by[ids[0]]["id"]))
PY
st_ok_all "I  2 places: a clash shows 3, the rest 2, the page the written 4; the clash ends ⇒ 2 again; 2 typed lists both, never a pick; top bar + notification the same; a previous result leaves current work visible"
