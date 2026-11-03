#!/usr/bin/env python3
# selftest-entry
"""Who opened a session, by ID (task PV5W): the lists draw a session under the
session whose spawn / task tool opened it. Display only — nothing routes,
reports or reaps by it.

A  fleet-mcp.py spawn_env hands the CALLER's own @fleet_id as $FLEET_FROM_FID to
   the spawn and task tools' scripts — never an inherited value, never a non-ID.
B  the spawners stamp it as @from_fid (dash-raw-session.sh, dash-issue-session.sh),
   fleet-task-record.sh puts it in the record's request_payload.from_fid, and a
   migration carries it.
C  the inventory reads @from_fid as its last column `from=<ID>`; inventory_row
   reads it into `from` (after `source=` or alone), and a word that is no ID is
   nothing.
"""
import importlib.util
import os
import sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
from fleet_hub_common import inventory_row  # noqa: E402

fails = 0
FID = "0b7e8c1a-2222-4222-8333-000000000001"


def check(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


def read(*parts):
    with open(os.path.join(BIN, "..", *parts), encoding="utf-8") as f:
        return f.read()


# ---- A: the caller's ID, handed on ------------------------------------------------
spec = importlib.util.spec_from_file_location("fleet_mcp", os.path.join(BIN, "fleet-mcp.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)
mcp.hub_env = lambda ttl: None                       # no hub: inherit
for k in ("TMUX", "TMUX_PANE", "FLEET_FROM_FID"):
    os.environ.pop(k, None)
mcp.CALLER["claims"] = {"fid": FID}
env = mcp.spawn_env(60)
check("A: the credential's ID is handed on", env is not None and env.get("FLEET_FROM_FID") == FID)
mcp.CALLER["claims"] = {"fid": "scratch-3"}
check("A: a word that is no ID is not", mcp.spawn_env(60) is None)
os.environ["FLEET_FROM_FID"] = "0b7e8c1a-2222-4222-8333-0000000000ff"
mcp.CALLER["claims"] = None
env = mcp.spawn_env(60)
check("A: an inherited value never travels", env is not None and "FLEET_FROM_FID" not in env)
mcp.CALLER["claims"] = {"fid": FID}
check("A: the caller's own wins over an inherited one", mcp.spawn_env(60).get("FLEET_FROM_FID") == FID)
os.environ.pop("FLEET_FROM_FID", None)
src = read("bin", "fleet-mcp.py")
check("A: spawn and task use it", src.count("env=spawn_env(ASSERT_TTL_S)") == 2)

# ---- B: the stamp, the record, the carry ------------------------------------------
raw = read("bin", "dash-raw-session.sh")
check("B: dash-raw-session.sh stamps @from_fid",
      'fleet_is_fid "${FLEET_FROM_FID:-}" && [ "$FLEET_FROM_FID" != "$fid" ] && stamp_option @from_fid "$FLEET_FROM_FID"' in raw)
iss = read("bin", "dash-issue-session.sh")
check("B: dash-issue-session.sh stamps @from_fid",
      'fleet_is_fid "${FLEET_FROM_FID:-}" && _sw+=(\\; set-window-option -t "$win" @from_fid "$FLEET_FROM_FID")' in iss)
rec = read("bin", "fleet-task-record.sh")
check("B: the record's payload carries from_fid",
      '"${FLEET_FROM_FID:-}" <<\'JSON\'' in rec and '{"from_fid": from_fid}' in rec)
check("B: a migration carries it", "@session_source @from_fid\"" in read("bin", "fleet-migrate.sh"))

# ---- C: the column ----------------------------------------------------------------
ctl = read("bin", "fleet-control-read.sh")
check("C: the inventory reads @from_fid", "\\t#{@from_fid}' 2>/dev/null) || cwds=''" in ctl
      and 'suffix += ("\\tfrom=" + fid) if fid else ""' in ctl)
base = ["@1", "", "1", "/w", "idle", "claude", "h", "", "o/r"] + [""] * 27   # 36 columns
_, extra = inventory_row(base + ["park=", "source=agent", "from=" + FID])
check("C: from= after source= is read", extra.get("from") == FID and extra.get("source") == "agent")
_, extra = inventory_row(base + ["park=", "loop=0", "nativewait=", "activity=1800000000", "from=" + FID])
check("C: from= alone, after the native facts", extra.get("from") == FID and extra.get("activity_at") == 1800000000)
_, extra = inventory_row(base + ["park=", "from=scratch-3"])
check("C: a word that is no ID is nothing", "from" not in extra)
_, extra = inventory_row(base + ["park=", "source=agent"])
check("C: no column, no from (the row as before)", "from" not in extra and extra.get("source") == "agent")

print("session-from-selftest: %s" % ("PASS" if not fails else "%d FAIL" % fails))
sys.exit(1 if fails else 0)
