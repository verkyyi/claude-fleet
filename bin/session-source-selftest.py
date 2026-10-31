#!/usr/bin/env python3
# selftest-entry
"""Who opened a session (task DDBQ): the one stamp, the one column, the one reader.

A  inventory_row reads the last column `source=agent|schedule|api|studio` into `source`;
   a person's row (no column) and an unknown word carry none — the row as before.
B  every spawner says it: dash-raw-session.sh --source (stamped only for
   agent|schedule|api, derived `agent` from a session's --origin, carried over
   the --bg re-exec), dash-issue-session.sh from --origin, fleet-task-record.sh
   (via 编排 ⇒ agent), the two schedule runners (--source schedule); the
   inventory reads @session_source (a window from before it: reap origin probe,
   no test identity ⇒ schedule — X24T); the
   inventory reads @session_source and a migration carries it.
C  the hub decides once (fleet_board.go boardSource) and both lists read it:
   session-list.ts rowSource and fleet_view.py SOURCES.
"""
import os
import re
import shutil
import subprocess
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
_, extra = inventory_row(base + ["park=", "source=studio"])
check("A: source=studio is read (V374)", extra.get("source") == "studio")

# ---- B: the spawners --------------------------------------------------------------
raw = read("bin", "dash-raw-session.sh")
check("B: dash-raw-session.sh takes --source", "--source)" in raw and "--source=*)" in raw)
check("B: refuses an unknown source", "case \"$SOURCE\" in ''|person|agent|schedule|api|studio) ;;" in raw)
check("B: a session's --origin is an agent's",
      "[ -n \"$SOURCE\" ] || case \"$ORIGIN\" in ''|hub) ;; *) SOURCE=agent ;; esac" in raw)
check("B: a person's session is stamped nothing",
      "case \"$SOURCE\" in agent|schedule|api|studio) stamp_option @session_source \"$SOURCE\"" in raw)
check("B: the --bg re-exec carries it", "owarg=\"$owarg --source=$SOURCE\"" in raw)
check("B: a scheduled run's first sentence is its name (X24T)",
      '[ "$SOURCE" = schedule ] && [ -n "$custom" ] && stamp_option @task_line "$custom"' in raw)
check("B: dash-issue-session.sh stamps a session's spawn",
      re.search(r"case \"\$ORIGIN\" in ''\|hub\) ;; \*\) _sw\+=\(.*@session_source agent\)", read("bin", "dash-issue-session.sh")) is not None)
rec = read("bin", "fleet-task-record.sh")
check("B: the task tool (via 编排) opens an agent's", "src=''; [ \"$via\" = 编排 ] && src=agent" in rec
      and rec.count('${src:+--source "$src"}') == 2)
check("B: a scheduled run says schedule (python runner)", "'--source','schedule'" in read("bin", "fleet_schedule_run.py"))
check("B: a scheduled run says schedule (shell runner)", "--source schedule" in read("bin", "fleet-task-run.sh"))
ctl = read("bin", "fleet-control-read.sh")
SRC_FMT = ("#{?@session_source,#{@session_source},#{?#{==:#{@reap_origin}/#{@test_identity},probe/},schedule,"
           "#{?#{==:#{@agent_def},livepage-studio},studio,#{?#{==:#{@agent_def},bubble-cloud-deck},studio,}}}}")
check("B: the inventory reads @session_source", SRC_FMT + "' 2>/dev/null) || cwds=''" in ctl
      and 'suffix += ("\\tsource=" + src) if src else ""' in ctl)
# X24T: a window a scheduler opened before the stamp (reap origin probe, not a
# test identity) is a schedule's — asked of a real tmux on an isolated socket.
if shutil.which("tmux"):
    sock = "src-selftest-%d" % os.getpid()
    tm = lambda *a: subprocess.run(["tmux", "-L", sock, "-f", "/dev/null"] + list(a), capture_output=True, text=True)
    try:
        tm("new-session", "-d", "-s", "t", "-n", "person")
        for n, opts in (("old", {"@reap_origin": "probe"}), ("test", {"@reap_origin": "probe", "@test_identity": "1"}),
                        ("agent", {"@session_source": "agent", "@reap_origin": "probe"}), ("mine", {"@reap_origin": "person"}),
                        ("lp", {"@agent_def": "livepage-studio"}), ("bc", {"@agent_def": "bubble-cloud-deck"}),
                        ("other", {"@agent_def": "fleet-worker"})):
            tm("new-window", "-t", "t:", "-n", n)
            for k, v in opts.items():
                tm("set-option", "-w", "-t", "t:" + n, k, v)
        got = dict(l.split("=", 1) for l in tm("list-windows", "-t", "t:", "-F", "#{window_name}=" + SRC_FMT).stdout.split())
        check("B: an old scheduled window reads schedule", got.get("old") == "schedule")
        check("B: a test identity, a person's and a stamped window keep theirs",
              got.get("test") == "" and got.get("person") == "" and got.get("mine") == "" and got.get("agent") == "agent")
        check("B: an old workbench window reads studio (V374)",
              got.get("lp") == "studio" and got.get("bc") == "studio" and got.get("other") == "")
    finally:
        tm("kill-server")
check("B: the workbench opens a studio session (V374)",
      '["--as", profile, "--source", "studio"]' in read("extras", "web-chat", "server.mjs"))
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
