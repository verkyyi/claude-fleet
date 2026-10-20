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
#      over one (a session start judged since the warm pool left, T495)
#   G  every new session's stages since its ↵ (T684): Run.at / `at` under
#      FLEET_TIMING_T0 join one run (no T0 ⇒ nothing); `p90` is the nearest-rank
#      九成分位 of each stage over the last 24 h, older runs and old-form runs out
#   H  the doctor's 「新建耗时」 row (spawn-time): the four stages' p90 in seconds;
#      nothing in 24 h ⇒ no row
#   I  `ready`: fleet_id.hook_timing_ready writes it under the window's @timing_t0
#      once and clears the stamp; dash-raw-session.sh stamps @timing_t0 off
#      FLEET_TIMING_T0, fleet-task-record.sh writes `placed`, fleet-quick-dispatch.py
#      `window`, fleet_view.go_new carries the ↵ (`do new --t0`)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
st_sandbox "${TMPDIR:-/tmp}/ftiming.XXXXXX"
export FLEET_CONF_DIR="$WORK/conf"
unset FLEET_TIMING_PANEL_MS FLEET_TIMING_SESSION_MS
FAIL=0
T() { python3 "$BIN/fleet_timing.py" "$@"; }

# --- A ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' && st_ok "A add: {ts, what, seg, ms} per segment, one ts a run; a Clock's marks sum to its total" || st_miss "A add / Clock"
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
  && st_ok "B table: median · max per segment over the last N; cold counted, the total without it" \
  || st_miss "B table: $out"

# --- C ---------------------------------------------------------------------------
f0=$FAIL
out=$(T check); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'panel n=3 p50=200 limit=500 over=0 cold=0' \
  && printf '%s\n' "$out" | grep -qx 'session n=2 p50=300 limit=8000 over=0 cold=1' \
  || st_miss "C check under the limits: rc=$rc $out"
out=$(FLEET_TIMING_PANEL_MS=150 T check); rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qx 'panel n=3 p50=200 limit=150 over=1 cold=0' \
  || st_miss "C check over the panel limit: rc=$rc $out"
[ -z "$(FLEET_CONF_DIR="$WORK/none" T check)" ] || st_miss "C no file printed something"
[ "$FAIL" = "$f0" ] && st_ok "C check: medians against the limits, cold not judged, over ⇒ exit 1, no file ⇒ nothing"

# --- D ---------------------------------------------------------------------------
python3 - "$BIN" "$WORK" <<'PY' && st_ok "D a long file keeps its newest half; an unwritable home costs only the line" || st_miss "D rotation / unwritable"
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
python3 - "$BIN" <<'PY' && st_ok "E proc_start: Linux the process's own start, else None" || st_miss "E proc_start"
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
sed -n '/^# --- timing: ⌘P/,/^# --- 新建耗时/p' "$BIN/fleet-doctor.sh" | sed "s#\$(dirname \"\$0\")#$BIN#" > "$WORK/row.sh"
row() { bash -c 'pass() { echo "PASS $1 $2"; }; warn() { echo "WARN $1 $2"; }; . "$1"' _ "$WORK/row.sh"; }
f0=$FAIL
out=$(row)
printf '%s\n' "$out" | grep -q '^PASS timing ⌘P → 面板 p50 0.20s (3 次) · 新会话 → 能打字 p50 0.30s (2 次，冷启 1)$' \
  || st_miss "F PASS under the limits: $out"
out=$(FLEET_TIMING_PANEL_MS=150 row)
printf '%s\n' "$out" | grep -q '^WARN timing ⌘P → 面板 p50 0.20s (3 次) > 0.1s' || st_miss "F WARN over a limit: $out"
rm -f "$FLEET_CONF_DIR/timing/session.ndjson"; T add session start=9000 go=10 total=9010
out=$(row)
printf '%s\n' "$out" | grep -q '^WARN timing .*新会话 → 能打字 p50 9.01s (1 次) > 8.0s' || st_miss "F WARN a slow start: $out"
[ -z "$(FLEET_CONF_DIR="$WORK/none" row)" ] || st_miss "F no run printed a row"
[ "$FAIL" = "$f0" ] && st_ok "F doctor timing: PASS under, WARN over (a slow start too), no row with nothing measured"

# --- G ---------------------------------------------------------------------------
rm -rf "$FLEET_CONF_DIR/timing"
python3 - "$BIN" <<'PY' && st_ok "G stages since the ↵ join one run; no T0 ⇒ nothing; p90 nearest rank over 24 h, old runs out" || st_miss "G stages / p90"
import json, os, sys, time
sys.path.insert(0, sys.argv[1])
import fleet_timing as t
os.environ.pop("FLEET_TIMING_T0", None)
t.at_env("placed")                                      # no run: nothing written
assert t.whats() == [], t.whats()
t0 = time.time() - 1.5
os.environ["FLEET_TIMING_T0"] = "%.3f" % t0
t.at_env("placed")
r = t.Run("session", t0)
w = r.at("window")
assert 1450 <= w < 5000, w
os.environ["FLEET_TIMING_T0"] = "garbage"; t.at_env("typeable")      # garbage: nothing
os.environ["FLEET_TIMING_T0"] = "%.3f" % (time.time() - 7200); t.at_env("typeable")   # too old: nothing
rs = t.runs("session", 10)
assert len(rs) == 1 and set(rs[0]) == {"placed", "window"}, rs
assert t.p90([5, 1, 3, 2, 4, 6, 7, 8, 9, 10]) == 9 and t.p90([7]) == 7 and t.p90([]) is None
assert t.p90([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]) == 10
# ten runs today, one two days ago (out), one old-form run (no stage: out)
os.remove(os.path.join(t.timing_dir(), "session.ndjson"))
now = time.time()
for i in range(10):
    t.add("session", [("placed", 1000 + i * 100), ("window", 2000 + i * 100), ("typeable", 3000 + i * 100),
                      ("total", 3000 + i * 100)], ts=now - 60 - i)
    t.add("session", [("ready", 6000 + i * 100)], ts=now - 60 - i)
t.add("session", [("placed", 99000), ("typeable", 99000)], ts=now - 2 * 86400)
t.add("session", [("start", 50000), ("go", 10), ("total", 50010)], ts=now - 30)
line = t.spawn_p90("session", 24)
assert line == "n=10 placed=1800 window=2800 typeable=3800 ready=6800", line
assert t.spawn_p90("session", 0.001) == "", t.spawn_p90("session", 0.001)
PY
out=$(T p90 session --hours 24)
[ "$out" = "n=10 placed=1800 window=2800 typeable=3800 ready=6800" ] || st_miss "G p90 CLI: $out"
[ -z "$(FLEET_CONF_DIR="$WORK/none" T p90)" ] || st_miss "G p90 with no file printed something"
[ -z "$(FLEET_TIMING_T0='' T at session x; ls "$WORK/none" 2>/dev/null)" ] || st_miss "G at without T0 wrote"

# --- H ---------------------------------------------------------------------------
sed -n '/^# --- 新建耗时/,/^# --- perl/p' "$BIN/fleet-doctor.sh" | sed "s#\$(dirname \"\$0\")#$BIN#" > "$WORK/row2.sh"
row2() { bash -c 'info() { echo "INFO $1 $2"; }; . "$1"' _ "$WORK/row2.sh"; }
out=$(row2)
printf '%s\n' "$out" | grep -qx 'INFO spawn-time 新建耗时 近 24 小时 10 次 · 九成 · hub 结论 1.8s · 开窗 2.8s · 能打字 3.8s · agent 就绪 6.8s — fleet_timing.py table session shows each run'"'"'s stages' \
  && [ -z "$(FLEET_CONF_DIR="$WORK/none" row2)" ] \
  && st_ok "H doctor 新建耗时: the four stages' p90 in seconds, no row with nothing in 24 h" \
  || st_miss "H doctor spawn-time: $out"

# --- I ---------------------------------------------------------------------------
python3 - "$BIN" <<'PY' && st_ok "I ready: under the window's @timing_t0, once, the stamp cleared" || st_miss "I ready"
import os, sys, time
sys.path.insert(0, sys.argv[1])
import fleet_id, fleet_timing as t
os.remove(os.path.join(t.timing_dir(), "session.ndjson"))
t0 = round(time.time() - 4.2, 3)
opts = {"@timing_t0": "%.3f" % t0}
fleet_id.wopt = lambda pane, name: opts.get(name, "")
fleet_id.wset = lambda pane, name, value=None: opts.pop(name, None) if value is None else opts.__setitem__(name, value)
fleet_id.hook_timing_ready("%1")
fleet_id.hook_timing_ready("%1")                        # a later SessionStart (/clear): nothing
rs = t.runs("session", 10)
assert len(rs) == 1 and list(rs[0]) == ["ready"] and 4150 <= rs[0]["ready"] < 9000, rs
assert "@timing_t0" not in opts, opts
PY
grep -q 'fleet_win_stamp_cmd @timing_t0 "$FLEET_TIMING_T0"' "$BIN/dash-raw-session.sh" \
  && grep -q 'fleet_timing.py" at session placed' "$BIN/fleet-task-record.sh" \
  && grep -q 'timing_at("window")' "$BIN/fleet-quick-dispatch.py" \
  && grep -q '"--t0", "%.3f" % time.time()' "$BIN/fleet_view.py" \
  && grep -q 'hook_timing_ready(pane)' "$BIN/fleet_id.py" \
  || st_miss "I a stage's writer is gone from its road"

st_done
