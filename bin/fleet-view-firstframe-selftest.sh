#!/bin/bash
# fleet-view-firstframe-selftest.sh — ⌘P's first frame runs no script it can
# keep (issue #3514: on a throttled 2-core home the popup took ~5 s to appear).
#
#   A  rows — produce(kept=True), the first frame's read, answers the copy the
#      last read kept (view-rows-<fleet>) while it is younger than
#      FLEET_VIEW_ROWS_KEEP; a plain read always runs the producer and keeps its
#      answer; KEEP=0, an old copy or no copy runs it; under a producer seam with
#      no KEEP set the first frame runs it too (a selftest changes those rows)
#   B  words — say() runs fleet-ui-lang.sh dump once per language input: a second
#      popup (a fresh process) reads the kept dump; another language, another dump
#   C  panel commands — FLEET_PANEL_COMMANDS read from fleet.conf with no shell:
#      the last line wins, `none` empties, no file ⇒ the default
#
# Drives bin/fleet_view.py (produce · say · panel_commands) in python, the real
# bin/fleet-ui-lang.sh, a producer seam for the rows.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-view-firstframe: python3 absent — SKIP'; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vfirst.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
export FLEET_STATUS_G="$WORK/g" FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home"
mkdir -p "$FLEET_STATUS_G" "$FLEET_CONF_DIR" "$HOME"
unset FLEET_VIEW_ROWS_KEEP FLEET_PANEL_COMMANDS FLEET_UI_LANG FLEET_VIEW_LANG

python3 - "$BIN" "$WORK" <<'PY'
import os, subprocess, sys, time
from pathlib import Path
BIN, WORK = sys.argv[1], Path(sys.argv[2])
sys.path.insert(0, BIN)
import fleet_view as fv

fails = []
def check(leg, ok, what):
    print("%s %s: %s" % ("PASS" if ok else "FAIL", leg, what))
    if not ok:
        fails.append(leg)

# ---- A: rows -----------------------------------------------------------------
rows, count = WORK / "rows", WORK / "count"
rows.write_text("r1\n")
os.environ["FLEET_VIEW_ROWS_CMD"] = "cat %s; echo x >> %s" % (rows, count)
runs = lambda: len(count.read_text().splitlines()) if count.exists() else 0
os.environ["FLEET_VIEW_ROWS_KEEP"] = "600"
check("A1", fv.produce("f", kept=True) == "r1\n" and runs() == 1, "no copy yet: the first frame runs the producer")
rows.write_text("r2\n")
check("A2", fv.produce("f", kept=True) == "r1\n" and runs() == 1, "a young copy is drawn, no producer run")
check("A3", fv.produce("f") == "r2\n" and runs() == 2, "a plain read runs it and keeps the new rows")
check("A4", fv.produce("f", kept=True) == "r2\n" and runs() == 2, "the next first frame draws the new copy")
old = time.time() - 700
os.utime(fv.rows_cache("f"), (old, old))
check("A5", fv.produce("f", kept=True) == "r2\n" and runs() == 3, "a copy older than KEEP is read again")
os.environ["FLEET_VIEW_ROWS_KEEP"] = "0"
check("A6", fv.produce("f", kept=True) and runs() == 4, "KEEP=0: always the producer")
del os.environ["FLEET_VIEW_ROWS_KEEP"]
check("A7", fv.produce("f", kept=True) and runs() == 5, "a seam with no KEEP: always the producer")
check("A8", fv.rows_cache("f") != fv.rows_cache("g"), "one copy per fleet")

# ---- B: words ------------------------------------------------------------------
real, dumps = subprocess.run, []
def counted(argv, *a, **k):
    if "dump" in argv:
        dumps.append(argv)
    return real(argv, *a, **k)
fv.subprocess.run = counted
os.environ["LANG"] = "zh_CN.UTF-8"
fv._WORDS.clear(); fv.say("view_bolt")
fv._WORDS.clear(); fv.say("view_bolt")
check("B1", len(dumps) == 1 and fv._WORDS.get("_") == "", "a second popup reads the kept dump (%d runs)" % len(dumps))
os.environ["LANG"] = "en_US.UTF-8"
fv._WORDS.clear(); fv.say("view_bolt")
check("B2", len(dumps) == 2, "another language: its own dump")
check("B3", len(fv._WORDS) > 5, "the kept dump carries the table (%d words)" % len(fv._WORDS))
fv.subprocess.run = real

# ---- C: panel commands -------------------------------------------------------
conf = Path(os.environ["FLEET_CONF_DIR"]) / "fleet.conf"
check("C1", fv.panel_commands() == ["new", "quit"], "no fleet.conf: the default")
conf.write_text("[common]\nFLEET_PANEL_COMMANDS='new'\nexport FLEET_PANEL_COMMANDS=\"landed\"\n")
check("C2", fv.panel_commands() == ["new", "quit", "landed"], "the last line wins")
conf.write_text("  FLEET_PANEL_COMMANDS=none\n")
check("C3", fv.panel_commands() == [], "none empties")
sys.exit(1 if fails else 0)
PY
rc=$?
[ $rc = 0 ] && echo 'fleet-view-firstframe: ALL PASS' || echo 'fleet-view-firstframe: FAILED'
exit $rc
