#!/bin/bash
# fleet-timing-selftest.sh — the segment clock of ⌘P → 面板 and ⌘N / ⚡ → 能打字
# (bin/fleet_timing.py, issue #3551, EPIC #3500 C6).
#
#   A  add: one line per segment, {ts, what, seg, ms} and nothing else, every line of
#      a run on the same ts; a Clock's marks add up to its total
#   B  table: per segment the median and max over the last N runs; a cold open
#      counted, and the total without it
#   C  check: the medians against FLEET_TIMING_PANEL_MS / FLEET_TIMING_SESSION_MS —
#      a cold open is not judged, one over its limit exits 1; no file ⇒ nothing
#   D  a file past MAX_LINES keeps its newest half; a home it cannot write costs the
#      line, never an error
#   E  proc_start: on Linux the process's own start, before the module loaded;
#      elsewhere None
#   F  the doctor's `timing` row (bin/fleet-doctor.sh): PASS under the limits, WARN
#      over one, WARN when every new session started cold
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'fleet-timing: python3 absent — SKIP'; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ftiming.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
export FLEET_CONF_DIR="$WORK/conf"
unset FLEET_TIMING_PANEL_MS FLEET_TIMING_SESSION_MS
fails=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
T() { python3 "$BIN/fleet_timing.py" "$@"; }

# --- A ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' && ok "A add: {ts, what, seg, ms} per segment, one ts a run; a Clock's marks sum to its total" || fail "A add / Clock"
import json, os, sys, time
sys.path.insert(0, sys.argv[1])
import fleet_timing as t
t.add("panel", [("boot", 100), ("total", 150)])
c = t.Clock("session", time.time() - 0.05)
c.mark("claim"); time.sleep(0.02); c.mark("go"); c.done(); c.done()
p = lambda w: os.path.join(os.environ["FLEET_CONF_DIR"], "timing", w + ".ndjson")
rows = [json.loads(x) for x in open(p("panel"))]
assert [r["seg"] for r in rows] == ["boot", "total"] and all(set(r) == {"ts", "what", "seg", "ms"} for r in rows), rows
assert rows[0]["ts"] == rows[1]["ts"] and rows[0]["what"] == "panel", rows
s = [json.loads(x) for x in open(p("session"))]
assert [r["seg"] for r in s] == ["claim", "go", "total"], s          # done() writes once
assert len(set(r["ts"] for r in s)) == 1, s
assert abs(s[0]["ms"] + s[1]["ms"] - s[2]["ms"]) < 5 and s[0]["ms"] >= 45, s
PY

# --- B ---------------------------------------------------------------------------
rm -rf "$FLEET_CONF_DIR/timing"
for ms in 100 200 300; do T add panel boot=$((ms - 50)) frame=50 total=$ms; sleep 0.01; done
T add session claim=200 go=100 total=300; sleep 0.01
T add session claim=10 cold=5000 go=100 total=5110
out=$(T table)
printf '%s\n' "$out" | grep -qx '| total | 200 | 300 | 3 |' \
  && printf '%s\n' "$out" | grep -q '^session · 2 次 · 其中冷启 1 次' \
  && printf '%s\n' "$out" | grep -qx '| total（不算冷启） | 300 | 300 | 1 |' \
  && [ "$(T table --last 2 panel | grep '^| total ')" = '| total | 250 | 300 | 2 |' ] \
  && ok "B table: median · max per segment over the last N; cold counted, the total without it" \
  || fail "B table: $out"

# --- C ---------------------------------------------------------------------------
f0=$fails
out=$(T check); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'panel n=3 p50=200 limit=500 over=0 cold=0' \
  && printf '%s\n' "$out" | grep -qx 'session n=2 p50=300 limit=3000 over=0 cold=1' \
  || fail "C check under the limits: rc=$rc $out"
out=$(FLEET_TIMING_PANEL_MS=150 T check); rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qx 'panel n=3 p50=200 limit=150 over=1 cold=0' \
  || fail "C check over the panel limit: rc=$rc $out"
[ -z "$(FLEET_CONF_DIR="$WORK/none" T check)" ] || fail "C no file printed something"
[ "$fails" = "$f0" ] && ok "C check: medians against the limits, cold not judged, over ⇒ exit 1, no file ⇒ nothing"

# --- D ---------------------------------------------------------------------------
python3 - "$BIN" "$WORK" <<'PY' && ok "D a long file keeps its newest half; an unwritable home costs only the line" || fail "D rotation / unwritable"
import os, sys
sys.path.insert(0, sys.argv[1])
import fleet_timing as t
os.environ["FLEET_CONF_DIR"] = os.path.join(sys.argv[2], "rot")
t.MAX_LINES = 40
for i in range(60):
    t.add("rot", [("total", i)], ts=1000 + i)
lines = open(os.path.join(os.environ["FLEET_CONF_DIR"], "timing", "rot.ndjson")).readlines()
assert len(lines) < 40 and '"ms": 59.0' in lines[-1], len(lines)
os.environ["FLEET_CONF_DIR"] = os.path.join(sys.argv[2], "ro")
open(os.environ["FLEET_CONF_DIR"], "w").close()       # a file where the dir would go
t.add("panel", [("total", 1)])                          # no raise
PY

# --- E ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' && ok "E proc_start: Linux the process's own start, else None" || fail "E proc_start"
import os, sys, time
t1 = time.time()
sys.path.insert(0, sys.argv[1])
import fleet_timing as t
s = t.proc_start()
if os.path.exists("/proc/self/stat"):
    assert s is not None and s <= t1 + 0.02 and t1 - s < 30, (s, t1)
else:
    assert s is None, s
PY

# --- F ---------------------------------------------------------------------------
# the doctor's row, cut out of fleet-doctor.sh and run with its two helpers
sed -n '/^# --- timing: ⌘P/,/^# --- perl/p' "$BIN/fleet-doctor.sh" | sed "s#\$(dirname \"\$0\")#$BIN#" > "$WORK/row.sh"
row() { bash -c 'pass() { echo "PASS $1 $2"; }; warn() { echo "WARN $1 $2"; }; . "$1"' _ "$WORK/row.sh"; }
f0=$fails
out=$(row)
printf '%s\n' "$out" | grep -q '^PASS timing ⌘P → 面板 p50 0.20s (3 次) · 新会话 → 能打字 p50 0.30s (2 次，冷启 1)$' \
  || fail "F PASS under the limits: $out"
out=$(FLEET_TIMING_PANEL_MS=150 row)
printf '%s\n' "$out" | grep -q '^WARN timing ⌘P → 面板 p50 0.20s (3 次) > 0.1s' || fail "F WARN over a limit: $out"
rm -f "$FLEET_CONF_DIR/timing/session.ndjson"; T add session claim=10 cold=4000 total=4010
out=$(row)
printf '%s\n' "$out" | grep -q '^WARN timing .*the warm pool is empty' || fail "F WARN all cold: $out"
[ -z "$(FLEET_CONF_DIR="$WORK/none" row)" ] || fail "F no run printed a row"
[ "$fails" = "$f0" ] && ok "F doctor timing: PASS under, WARN over or all cold, no row with nothing measured"

[ "$fails" = 0 ] || { echo "fleet-timing-selftest: $fails failed"; exit 1; }
echo "fleet-timing-selftest: all passed"
