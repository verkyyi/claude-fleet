#!/bin/bash
# fleet-view-home-selftest.sh — whichever machine is the 看台's home, the panel is
# the same (EPIC T644 C7; bin/fleet_id.py's ID cache, bin/fleet_view.py id_record /
# far_fid / task_list, bin/fleet-id.sh pull, bin/fleet-hub-sessions.sh wid_ids).
#
# Three older tasks run on machine B, retaining legacy @epic/parent stamps.
# The list must show T9, T10 and T11 as independent, flat task rows. Home B sees them as its own windows, off its own ledgers; home A sees
# them as another machine's rows (keyed `<fleet UUID>/<key>`, no task, no ledger),
# off its ID cache — filled from the hub's records (GET /v1/node/ids?since=).
#
#   A  home A with the cache filled ⇒ every row's short code, name, group, glyph,
#      single status slot equal home B's, row by row; no headings/tree/aggregation
#   B  home A with nothing cached ⇒ a placeholder (the code this login computes,
#      id_pending), the members not hung; the frame asks for exactly those IDs in
#      the background (pull_later), and once they land the next frame equals B's
#   C  the hub silent ⇒ pull says 75 and leaves the cache as it was: the panel is
#      drawn off it unchanged; no hub here ⇒ 3, nothing touched
#   D  pull pages through the cursor, a full pass drops what the hub no longer
#      lists, an older hub (no cursor) changes nothing; `fleet-id.sh get` /
#      `children` on home A answer off the cache (no "has no ledger here")
#   E  a ledger here is filled from the cache, the hub winning: a longer short, an
#      `opened` field it lacked; its own results stay
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fvhome-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 FLEET_ID_PUSH=0
unset NO_COLOR FLEET_COLOR FLEET_GLYPHS FLEET_VIEW_EPIC_SECS FLEET_ID_DIR FLEET_ID_HUB_POST
mkdir -p "$WORK/A/g" "$WORK/B/g"
cat > "$WORK/children.json" <<'JSON'
{"parent": "T9", "children": [
 {"id": "T10", "title": "C1 · 账本", "state": "succeeded", "outcome": "succeeded"},
 {"id": "T11", "title": "C2 · 镜像", "state": "running", "outcome": ""}]}
JSON
export FLEET_VIEW_BOARD=0
export FLEET_VIEW_EPIC_CMD="echo queried >> '$WORK/children-queries'; cat '$WORK/children.json'"

python3 - "$BIN" "$WORK" <<'PY' || st_fail "the panel by home"
import importlib.util, json, os, subprocess, sys, time
B, W = sys.argv[1], sys.argv[2]
sys.path.insert(0, B)
def load(name, f):
    spec = importlib.util.spec_from_file_location(name, os.path.join(B, f))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
fv = load("fleet_view", "fleet_view.py")
import fleet_id as fi
US = "\x1f"
now = int(time.time())
UUID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
D, M1, M2, OLD = ("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
                  "33333333-3333-4333-8333-333333333333", "44444444-4444-4444-8444-444444444444")

def home(h):
    os.environ["FLEET_CONF_DIR"] = os.path.join(W, h, "conf")
    os.environ["FLEET_STATUS_G"] = os.path.join(W, h, "g")
    fv._ID_CACHE.clear()

# --- machine B writes its ledgers (the writer); the hub mirrors them
home("B")
for fid, task, title, extra in ((D, "T9", "EPIC 驱动", {}), (M1, "T10", "C1", {"parent": D}),
                                (M2, "T11", "C2", {"parent": D})):
    fi.append(fid, dict({"ev": "opened", "agent": "claude", "task": task, "title": title, "key": "k-" + task,
                         "short": fi.short_for(fid, {D, M1, M2, OLD}), "ts": now - 100}, **extra))
    fi.append(fid, {"ev": "native", "agent": "claude", "native": "n-" + task, "trigger": "startup", "ts": now - 90})
fi.append(M1, {"ev": "result", "state": "merged", "summary": "ok", "pr": "7", "ts": now - 10})

def hub_rec(fid):
    """What the hub answers for one of B's IDs (store.FleetIDRecord's shape)."""
    rec = fi.fold(fi.read(fid))
    o = rec["opened"]
    return {"id": fid, "short": o["short"], "machine": "mac-b", "login": "u", "title": o.get("title", ""),
            "agent": o.get("agent", ""), "task": o.get("task", ""), "parent": o.get("parent", ""), "key": o.get("key", ""),
            "issues": [], "aliases": [], "opened_at": o.get("ts"), "seq": len(fi.read(fid)),
            "natives": [{"n": s["n"], "seq": 2, "agent": s["agent"], "native": s["native"], "trigger": s["trigger"],
                         "compactions": 0, "start": s["start"]} for s in rec["segments"]],
            "results": [{"seq": 3, "state": r["state"], "summary": r.get("summary", ""), "pr": r.get("pr", ""),
                         "at": r.get("ts")} for r in rec["results"]]}
HUB = {f: hub_rec(f) for f in (D, M1, M2)}
HUB[OLD] = {"id": OLD, "short": fi.short_for(OLD, {D, M1, M2, OLD}), "machine": "x", "login": "u", "title": "old",
            "issues": [], "aliases": [], "opened_at": now - 999, "seq": 1, "natives": [], "results": [], "closed_at": now - 900}

# the hub seam: GET /v1/node/ids?since=<cursor> pages of PAGE records (cursor = an index)
calls, mode = [], {"m": "ok", "page": 2, "old": False}
order = [D, M1, M2]
def call(method, path, body=None):
    calls.append(path)
    if mode["m"] == "down":
        return 0, None
    if mode["m"] == "none":
        return -3, None
    if path.startswith("/v1/node/ids?since="):
        if mode["old"]:
            return 200, {"ids": [{"id": f, "short": HUB[f]["short"]} for f in order]}
        cur = path.split("=", 1)[1]
        i = int(cur) if cur else 0
        page = order[i:i + mode["page"]]
        return 200, {"ids": [HUB[f] for f in page], "cursor": str(i + len(page)), "more": i + len(page) < len(order)}
    fid = path.rsplit("/", 1)[1]
    return (200, HUB[fid]) if fid in HUB else (404, {"error": "no"})

# --- the two panels' producers: B's rows are its windows, A's the hub's rows
def full(target, state, glyph, name, mach="", task="", epic=""):
    f = [target, state, glyph, name, " ", "", "0", "", mach, "", "—", "·", "ok", name, "merged"]
    f += [""] * (21 - len(f))
    return US.join(f + [task, "claude", "o/claude-fleet"] + (["1"] if epic else []))
HDR = US.join(("hdr", "o/claude-fleet", "", "claude-fleet (3)", " "))
ROWS = [("@10", D, "working", "⠹", "EPIC 驱动", "T9", "1"), ("@11", M1, "done", "✓", "C1", "T10", ""),
        ("@12", M2, "needs", "!", "C2", "T11", "")]
rows_b = "\n".join([HDR] + [full(t, s, g, n, task=task, epic=e) for t, _, s, g, n, task, e in ROWS]) + "\n"
wid = lambda t: "wid:%s/k-%s" % (UUID, t)
rows_a = "\n".join([HDR] + [full(wid(task), s, g, n, mach="mac-b", epic=e) for t, _, s, g, n, task, e in ROWS]) + "\n"
open(os.path.join(W, "A", "g", "wid_ids"), "w").write("".join("%s/k-%s\t%s\n" % (UUID, task, fid)
                                                            for _, fid, _, _, _, task, _ in ROWS))
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row=None: "fl"
fv.here_label = lambda row: "here"
fv.fleet_logins = lambda: {}
fv.gone_text = lambda fleet: ""
fv.hub_view_request = lambda f: None
fv.hub_fresh = lambda f: None
fv.tm = lambda *a, **k: (0, "")
kicked = []
fi.pull_later = lambda ids=(): kicked.append(sorted(ids)) or True

def panel(h):
    home(h)
    if h == "B":
        fv.windows = lambda fleet: {t: (fid, "worker", now - 60) for t, fid, *_ in ROWS}
        fv.epic_windows = lambda fleet: {"@10": ("#T9", "")}
        fv.produce = lambda fleet, **kw: rows_b
    else:
        fv.windows = lambda fleet: {}
        fv.epic_windows = lambda fleet: {}
        fv.produce = lambda fleet, **kw: rows_a
    it = fv.entries("v1")
    fv.id_cache_kick()
    out = []
    for e in fv.visible(it, "", set()):
        if e["kind"] == "sess":
            out.append((e.get("id"), e.get("fid"), e["text"], e["group"], fv.task_status(e), e.get("task"), e.get("tree"),
                        bool(e.get("fold")), json.dumps(e.get("epic"), sort_keys=True)))
        elif e["kind"] == "hdr":
            out.append(("hdr", e["text"]))
    return out, it

want, _ = panel("B")
assert not any(r[0] == "hdr" for r in want), want
# one order (task DDBQ): the asking row is not lifted; with no activity the source order holds
assert [r[1] for r in want] == [D, M1, M2], want
assert [r[4] for r in want] == ["work", "quiet", "needs"], want
assert [r[5] for r in want] == ["T9", "T10", "T11"], want
assert all(r[6:] == (None, False, "null") for r in want), want
assert not os.path.exists(os.path.join(W, "children-queries")), "panel queried the old child ledger"

# --- B: home A, nothing cached — a placeholder, the IDs asked for in the background
got, it = panel("A")
by = {e.get("fid"): e for e in it if e["kind"] == "sess"}
assert set(by) >= {D, M1, M2}, by.keys()
assert all(by[f].get("id_pending") for f in (D, M1, M2)), [by[f] for f in (D, M1, M2)]
assert not any(e.get("fold") for e in it if e["kind"] == "sess"), "hung with nothing cached"
assert kicked and kicked[-1] == sorted([D, M1, M2]), kicked
assert not calls, "the frame called the hub: %s" % calls

# the background pull (here: in the foreground, the same function) fills the cache
assert fi.pull(sorted([D, M1, M2]), call=call) == 0
calls.clear()
got, it = panel("A")
assert got == want, "\nA %s\nB %s" % (got, want)
assert not calls, "the frame called the hub: %s" % calls

# --- A: the cache from a sync pass (paged), then row by row the same
home("A")
import shutil
shutil.rmtree(fi.cache_dir())
assert fi.pull(call=call) == 0
assert [c for c in calls if "since=" in c] == ["/v1/node/ids?since=", "/v1/node/ids?since=2"], calls
assert sorted(fi.cache_ids()) == sorted([D, M1, M2])
got, _ = panel("A")
assert got == want, "\nA %s\nB %s" % (got, want)
# the next pass reads only from the cursor
calls.clear(); home("A")
assert fi.pull(call=call) == 0 and calls == ["/v1/node/ids?since=3"], calls

# --- C: the hub silent ⇒ 75, the cache untouched, the panel the same
home("A")
before = {f: open(fi.cache_path(f)).read() for f in fi.cache_ids()}
mode["m"] = "down"
assert fi.pull(call=call) == 75 and fi.pull([D], call=call) == 75
assert {f: open(fi.cache_path(f)).read() for f in fi.cache_ids()} == before
got, _ = panel("A")
assert got == want, "hub down:\nA %s\nB %s" % (got, want)
mode["m"] = "none"
home("A")
assert fi.pull(call=call) == 3
mode["m"] = "ok"

# --- D: a full pass drops what the hub no longer lists; an older hub changes nothing
home("A")
fi.cache_put(HUB[OLD])
assert OLD in fi.cache_ids()
assert fi.pull(call=call, full=True) == 0 and OLD not in fi.cache_ids(), fi.cache_ids()
fi.cache_put(HUB[OLD]); mode["old"] = True
assert fi.pull(call=call, full=True) == 0 and OLD in fi.cache_ids(), "an older hub pruned the cache"
mode["old"] = False
# known: the cache's IDs are this login's too (the short codes are kept apart from them)
assert {D, M1, M2} <= fi.known_ids()
# status / children off the cache: another machine's ID reads as the hub says
st = fi.status(M1, [])
assert st["state"] == "done" and st["src"] == "hub", st
kids = fi.children_of(D, [])
assert [k["id"] for k in kids] == [M1, M2] and kids[0]["label"] == "已完成", kids
# route stays this machine's: another machine's ID is `unknown` (the hub's road)
assert fi.route(M1, []) == (M1, "unknown")

# --- E: a ledger here is filled from the cache, the hub winning
home("A")
fi.append(OLD, {"ev": "opened", "agent": "codex", "short": HUB[OLD]["short"], "ts": now})
fi.append(OLD, {"ev": "result", "state": "failed", "summary": "mine"})
fi.cache_put(dict(HUB[OLD], short=fi.encode(OLD)[:6], title="hub's title"))   # the hub lengthened it (S12)
rec = fi.record(OLD)
assert rec["opened"]["short"] == fi.encode(OLD)[:6], rec["opened"]
assert rec["opened"]["title"] == "hub's title" and rec["opened"]["agent"] == "codex", rec["opened"]
assert rec["results"][-1]["summary"] == "mine", rec["results"]
assert not os.path.exists(os.path.join(W, "children-queries")), "a home/cache refresh queried child tasks"
print("ok")
PY

# --- D (shell): get / children on home A answer off the cache
export FLEET_CONF_DIR="$WORK/A/conf" FLEET_ID_LIVE_CMD="true" FLEET_ID_NOAGENT_CMD="true" FLEET_ID_PULL=0
out=$(bash "$BIN/fleet-id.sh" get 22222222-2222-4222-8222-222222222222 2>&1) || st_fail "get off the cache: $out"
case "$out" in *"结果"*merged*) ;; *) st_fail "get off the cache printed: $out" ;; esac
out=$(bash "$BIN/fleet-id.sh" children 11111111-1111-4111-8111-111111111111 2>&1)
case "$out" in *"2 children"*) ;; *) st_fail "children off the cache: $out" ;; esac
out=$(bash "$BIN/fleet-id.sh" get 55555555-5555-4555-8555-555555555555 2>&1) && st_fail "an unknown ID answered: $out"
case "$out" in *"nothing cached yet"*) ;; *) st_fail "an unknown ID said: $out" ;; esac

echo "ok   A same panel either home · B placeholder + background fill · C hub silent · D pull, get, children · E hub wins"
