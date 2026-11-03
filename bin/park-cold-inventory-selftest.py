#!/usr/bin/env python3
# selftest-entry
"""A cold park stays on the lists (task PV5W): the node's inventory lists each
cold park (fleet_park_cold.py) as a parked, window-less row with its key, birth
and opener, so the hub keeps it parked and nested — never 看不到会话 — and no
action ever targets it.

A  fleet_park_cold.records lists one fleet's cold parks.
B  fleet_control.cold_workers: the key from the record's repo, else the one hosted
   repo the worktree is named after; born from the record, else its ID ledger;
   from / source / pin passed on; a record of another fleet is not listed.
C  the cooler keeps those fields; find_workers, a start's proof and id_presence
   skip a cold row.
"""
import importlib.util
import json
import os
import sys
import tempfile

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
fails = 0


def check(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


def read(name):
    with open(os.path.join(BIN, name), encoding="utf-8") as f:
        return f.read()


tmp = tempfile.mkdtemp()
os.environ["FLEET_GATE_DIR"] = os.path.join(tmp, "gate")
os.environ["FLEET_ID_DIR"] = os.path.join(tmp, "ids")
os.makedirs(os.environ["FLEET_ID_DIR"])
import fleet_park_cold  # noqa: E402

A = "0b7e8c1a-8888-4222-8333-000000000001"
B = "0b7e8c1a-8888-4222-8333-000000000002"
C = "0b7e8c1a-8888-4222-8333-000000000003"
OPENER = "0b7e8c1a-8888-4222-8333-0000000000ff"
fleet_park_cold.write(A, dict(session="fleet", agent="codex", name="Tokenman Optimize",
                              worktree="/p/claude-fleet-scratch-12", repo="verkyyi/claude-fleet", raw="1",
                              born="1793000000", from_fid=OPENER, source="agent", pin="1"))
fleet_park_cold.write(B, dict(session="fleet", agent="claude", name="old record",
                              worktree="/p/web-app-scratch-70", since="1793500000"))
fleet_park_cold.write(C, dict(session="other", name="another fleet", worktree="/p/x-scratch-1"))
with open(os.path.join(os.environ["FLEET_ID_DIR"], B + ".ndjson"), "w") as f:
    f.write(json.dumps({"ev": "opened", "id": B, "seq": 1, "ts": 1792000000}) + "\n")

# ---- A ------------------------------------------------------------------------
check("A: one fleet's cold parks", sorted(r["fid"] for r in fleet_park_cold.records("fleet")) == sorted([A, B]))
check("A: every fleet's", len(fleet_park_cold.records()) == 3)

# ---- B ------------------------------------------------------------------------
spec = importlib.util.spec_from_file_location("fleet_control_t", os.path.join(BIN, "fleet_control.py"))
fc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fc)
fleet = dict(name="fleet", fleet_id="11111111-2222-4333-8444-555555555555", agent="claude",
             repos=["verkyyi/claude-fleet", "acme/web-app"])
ws = {w["identity"]: w for w in fc.cold_workers(fleet)}
a, b = ws.get(A, {}), ws.get(B, {})
check("B: another fleet's record is not listed", set(ws) == {A, B})
check("B: a parked, window-less, cold row", a.get("state") == "parked" and a.get("window_id") == ""
      and a.get("cold") is True and a.get("can_talk") is False)
check("B: its key from its repo", a.get("key") == "verkyyi-claude-fleet:scratch-12")
check("B: an older record's repo from its worktree", b.get("key") == "acme-web-app:scratch-70"
      and b.get("repo") == "acme/web-app")
check("B: born from the record, else the ID ledger (never the park time)",
      a.get("born") == 1793000000 and b.get("born") == 1792000000)
check("B: opener, source and pin passed on", a.get("from") == OPENER and a.get("source") == "agent"
      and a.get("pin") is True and "from" not in b and "source" not in b)
check("B: its worker_id is the fleet's and its key", a.get("worker_id", "").endswith("/verkyyi-claude-fleet:scratch-12")
      or a.get("worker_id", "").endswith("/" + A))
fleet2 = dict(fleet, repos=["verkyyi/claude-fleet"])
check("B: no hosted repo of that name: no key, never a guess",
      {w["identity"]: w for w in fc.cold_workers(fleet2)}[B].get("key") is None)

# ---- C ------------------------------------------------------------------------
idle = read("fleet-cleanup-idle.py")
check("C: the cooler keeps key, birth, task and opener",
      all(s in idle for s in ('repo=snap.get("@repo", "")', 'born=snap.get("@born", "")',
                              'from_fid=snap.get("@from_fid", "")', 'source=snap.get("@session_source", "")',
                              '"@from_fid", "@session_source"')))
ctl = read("fleet_control.py")
check("C: find_workers never targets a cold row",
      'live = [w for w in snapshot["workers"] if not w.get("cold")]' in ctl)
check("C: a start's proof never a cold row", ctl.count("windowed(snapshot)") >= 4)
check("C: id_presence lists windows only", 'for w in snap["workers"]\n                                      if not w.get("cold")]' in ctl)
check("C: the inventory adds cold rows only for the whole fleet, never twice",
      'if whole:\n            seen = {w.get("identity") for w in workers}' in ctl
      and 'whole = not window' in ctl)

# ---- D: the inventory itself (the row loop reuses `window`) --------------------
class Fake(fc.Control):
    def __init__(self):
        pass

    def adapter(self, mode, *args, **kw):
        row = "\t".join(["@7", "", "1", "/p/claude-fleet-scratch-3", "idle", "claude", "", "", "verkyyi/claude-fleet",
                         "w", "", "", "0b7e8c1a-8888-4222-8333-0000000000aa"])
        return 0, (row + "\n").encode(), b""


snap = Fake().workers(fleet)
ids = [w.get("identity") for w in snap["workers"]]
check("D: a whole-fleet read lists its windows and its cold parks",
      "0b7e8c1a-8888-4222-8333-0000000000aa" in ids and A in ids and B in ids)
check("D: one window's read lists that window only",
      [w.get("identity") for w in Fake().workers(fleet, "@7")["workers"]] == ["0b7e8c1a-8888-4222-8333-0000000000aa"])

print("park-cold-inventory-selftest: %s" % ("PASS" if not fails else "%d FAIL" % fails))
sys.exit(1 if fails else 0)
