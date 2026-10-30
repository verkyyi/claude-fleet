#!/usr/bin/env python3
# selftest-entry
"""Who opened a session (task DDBQ): the one stamp, the one column, the one reader.

A  inventory_row reads the last column `source=agent|schedule|api` into `source`;
   a person's row (no column) and an unknown word carry none — the row as before.
B  every spawner says it: dash-raw-session.sh --source (stamped only for
   agent|schedule|api, derived `agent` from a session's --origin, carried over
   the --bg re-exec), dash-issue-session.sh from --origin, fleet-task-record.sh
   (via 编排 ⇒ agent), the two schedule runners (--source schedule); the
   inventory reads @session_source and a migration carries it.
C  the hub decides once (fleet_board.go boardSource) and both lists read it:
   session-list.ts rowSource and fleet_view.py SOURCES.
"""
import os
import re
import sys

BIN = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BIN)
from fleet_hub_common import inventory_row  # noqa: E402

fails = 0


def check(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


def read(*parts):
    with open(os.path.join(BIN, "..", *parts), encoding="utf-8") as f:
        return f.read()


# ---- A: the column --------------------------------------------------------------
base = ["@1", "", "1", "/w", "idle", "claude", "h", "", "o/r"] + [""] * 27   # 36 columns
_, extra = inventory_row(base + ["park=", "source=agent"])
check("A: source=agent is read", extra.get("source") == "agent")
_, extra = inventory_row(base + ["park=", "loop=0", "nativewait=", "activity=1800000000", "source=schedule"])
check("A: after the native facts too", extra.get("source") == "schedule" and extra.get("activity_at") == 1800000000)
_, extra = inventory_row(base + ["park=", "loop=0", "nativewait=", "activity=1800000000"])
check("A: a person's row has none", "source" not in extra and extra.get("activity_at") == 1800000000)
_, extra = inventory_row(base + ["park=", "source=person"])
check("A: an unknown word is no source", "source" not in extra)

# ---- B: the spawners --------------------------------------------------------------
raw = read("bin", "dash-raw-session.sh")
check("B: dash-raw-session.sh takes --source", "--source)" in raw and "--source=*)" in raw)
check("B: refuses an unknown source", "case \"$SOURCE\" in ''|person|agent|schedule|api) ;;" in raw)
check("B: a session's --origin is an agent's",
      "[ -n \"$SOURCE\" ] || case \"$ORIGIN\" in ''|hub) ;; *) SOURCE=agent ;; esac" in raw)
check("B: a person's session is stamped nothing",
      "case \"$SOURCE\" in agent|schedule|api) stamp_option @session_source \"$SOURCE\"" in raw)
check("B: the --bg re-exec carries it", "owarg=\"$owarg --source=$SOURCE\"" in raw)
check("B: dash-issue-session.sh stamps a session's spawn",
      re.search(r"case \"\$ORIGIN\" in ''\|hub\) ;; \*\) _sw\+=\(.*@session_source agent\)", read("bin", "dash-issue-session.sh")) is not None)
rec = read("bin", "fleet-task-record.sh")
check("B: the task tool (via 编排) opens an agent's", "src=''; [ \"$via\" = 编排 ] && src=agent" in rec
      and rec.count('${src:+--source "$src"}') == 2)
check("B: a scheduled run says schedule (python runner)", "'--source','schedule'" in read("bin", "fleet_schedule_run.py"))
check("B: a scheduled run says schedule (shell runner)", "--source schedule" in read("bin", "fleet-task-run.sh"))
ctl = read("bin", "fleet-control-read.sh")
check("B: the inventory reads @session_source", "#{@session_source}' 2>/dev/null) || cwds=''" in ctl
      and 'suffix += ("\\tsource=" + src) if src else ""' in ctl)
check("B: a migration carries it", re.search(r'^MIGRATE_CARRY="[^"]*@session_source', read("bin", "fleet-migrate.sh"), re.M) is not None)

# ---- C: one decision, two readers ---------------------------------------------------
board = read("tokenledger", "hub", "api", "fleet_board.go")
check("C: the hub decides in boardSource", "func boardSource(r BoardRow) string" in board and "r.Source = boardSource(*r)" in board)
check("C: a bearer worker_start is api", "API: bearer(r) != \"\"" in read("tokenledger", "hub", "api", "fleet.go")
      and "via = boardSourceAPI" in read("tokenledger", "hub", "api", "fleet_dispatch.go"))
check("C: the web reads board.source", "const s = r.board?.source;" in read("extras", "web-console", "src", "app", "session-list.ts"))
check("C: the panel reads the row's source", 'e["source"] = r.get("source") if r.get("source") in SOURCES else ""' in read("bin", "fleet_view.py"))

print("session-source selftest: %s" % ("OK" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
