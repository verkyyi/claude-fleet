#!/bin/bash
# fleet-collect-quotawatch-gate-selftest.sh — the collector runs fleet-quotawatch.sh
# in its own tick ONLY when the quotawatch unit is not ticking (issue #671).
#
# Background (#671): #551 gave the pre-emptive quota rotation its own 60s unit and
# ALSO left an unconditional call at the top of every collector tick, on the stated
# grounds that it "costs nothing on a healthy one" — TTL-gated fetch, lock skips an
# in-flight tick, markers dedup every action. Measurement falsified that. The
# modelcap sweep is the watch's expensive half and is gated by NEITHER the TTL nor
# the markers, so the collector's copy kept running the full sweep: sampled phase
# durations 46 · 56 · 35 · 57 · 25 · 17 · 10 · 3 seconds, `quotawatch` permanently in
# the heartbeat's over= list and in fleet-doctor's "over budget" line, one phase
# eating a quarter of a 120s tick to redo work a dedicated 60s unit had just done.
#
# The fix keeps the stated purpose (cover an install whose daemon set predates #551)
# and drops the cost everywhere else. This pins the whole decision table:
#
#   1. no evidence of a quotawatch tick (no unit / fresh install) → the collector RUNS it
#   2. the unit is ticking                                        → the collector SKIPS it
#   3. the unit is loaded but PENDED (stale stamp)                 → the collector RUNS it
#   4. FLEET_COLLECT_QUOTAWATCH=always                             → RUNS it regardless
#   5. FLEET_COLLECT_QUOTAWATCH=never                              → SKIPS it regardless
#   6. fleet-daemon-lib.sh absent (half-synced install)            → fails OPEN, RUNS it
#   7. a gated-off tick still records the phase, at ~0s, first
#   8. NO FLAP — the collector's own invocation must never stamp the scheduling
#      heartbeat it gates on, or one fallback tick would fake the unit healthy and
#      the fallback would switch itself off. (#639 made `--caller collect` the one
#      caller that does not stamp; this pins that the two features compose.)
#
# Drives the REAL collector against a FAKE git / gh / tmux / ccquota and (cases 1-6)
# a stub fleet-quotawatch.sh that logs its invocation — case 8 swaps the REAL one
# back in, because "does it stamp?" is a question only the real script can answer.
# HOME is the scratch dir so the usage scan never touches real transcripts. Needs
# python3 (collector hard dep) — SKIPs if absent.
# Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC='tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-daemon-lib.sh fleet-restore.sh'
for f in $SRC; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/collect-quotawatch-gate-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in $SRC; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
G="$WORK/.claude-dash/global"
QW_REAL="$WORK/quotawatch.real.sh"; cp "$BIN/fleet-quotawatch.sh" "$QW_REAL"
QW_LOG="$WORK/quotawatch.calls"

# The stub the collector's `bash "$BIN/fleet-quotawatch.sh" --caller collect` hits.
stub_watch() {
  cat > "$WORK/bin/fleet-quotawatch.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_QW_LOG"
exit 0
FAKE
  chmod +x "$WORK/bin/fleet-quotawatch.sh"
}
real_watch() { cp "$QW_REAL" "$WORK/bin/fleet-quotawatch.sh"; chmod +x "$WORK/bin/fleet-quotawatch.sh"; }
stub_watch

cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
case "${1:-}" in has-session) exit 0 ;; *) exit 0 ;; esac
FAKE
cat > "$WORK/fakepath/git" <<'FAKE'
#!/bin/bash
exit 0
FAKE
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
exit 0
FAKE
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
printf '{"verdict":"ok","accounts":[]}'
FAKE
chmod +x "$WORK/fakepath/"*

# Where fleet_daemon_stamp_tick/tick_ts put THIS sandbox's stamps: the root is the
# collector's own "$BIN/..", i.e. $WORK, which is not the live install, so the lib
# hands back a private dev-<hash> sibling. Ask the lib rather than recomputing it,
# so the test cannot drift from fleet_daemon_state_dir's own rule.
STATE="$(TMPDIR="$WORK" HOME="$WORK" bash -c '. "$1/bin/fleet-daemon-lib.sh"; fleet_daemon_state_dir "$1"' _ "$WORK")"
[ -n "$STATE" ] || { printf 'selftest: could not resolve the daemon state dir\n' >&2; exit 2; }
mkdir -p "$STATE"

# Nine ticks of a full collector cost ~90s of the CI gate's 10-minute wall, and
# almost all of it is spent on the ROTATING body — phases that run after the head
# and cannot reach the gate under test. So the tick budget is cut to TICK_BUDGET:
# the head (quotawatch, then sockets) runs exactly as it does in production and the
# rotation is truncated away, taking a tick from ~10s to ~3s. The gate lives in the
# head, before the first rotating phase, so nothing under test is elided — and
# `phase=done` is still reached, which case 1 asserts.
#
# The budget must stay clear of the collector's own PHASE_MIN (5s): `quotawatch` is
# the first phase, so it starts only while TICK_BUDGET minus the tick's setup is
# still ≥ 5. 7 leaves 2s of slack for a loaded runner, and gate_decided below turns
# the remaining sliver into a NAMED failure rather than a mystery — a tick that lost
# the phase to its budget cannot be read as the gate having skipped it.
TICK_BUDGET=7
run_collector() {   # $1.. = extra env assignments
  : > "$QW_LOG"
  env PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_REPO="" FLEET_REPOS="" FLEET_NOTIFY_CMD="" FLEET_CONF_DIR="$WORK/conf" \
    FLEET_ACCOUNTS_DIR="$WORK/no-accounts" CCQUOTA_HUB_URL="" \
    FLEET_COLLECT_TICK_BUDGET="$TICK_BUDGET" \
    FAKE_QW_LOG="$QW_LOG" "$@" \
    bash "$WORK/bin/tmux-dash-collect.sh" >"$WORK/stdout" 2>"$WORK/stderr"
}
fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- stderr ---\n' >&2; cat "$WORK/stderr" >&2 2>/dev/null
         printf -- '--- heartbeat ---\n' >&2; cat "$G/collect.heartbeat" >&2 2>/dev/null
         printf -- '--- quotawatch calls ---\n' >&2; cat "$QW_LOG" >&2 2>/dev/null
         exit 1; }
ok()     { printf '  ok — %s\n' "$1"; }
# Every case reads "did the GATE run the watch?" out of the call log — which is only
# an answer if the tick actually reached the phase. A tick that truncated `quotawatch`
# away under its own budget (see TICK_BUDGET above) would look exactly like a gated-off
# one, so say so instead of asserting on it.
gate_decided() {
  case " $(hbget skipped) " in *" quotawatch "*)
    fail "$1: the TICK budget truncated the quotawatch phase away — the gate never got to decide. Raise TICK_BUDGET in this test (skipped: $(hbget skipped))" ;;
  esac
}
hbget()  { sed -n "s/^$1=//p" "$G/collect.heartbeat" | head -1; }
order()  { hbget phases | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' '; }
phsecs() { hbget phases | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
calls()  { wc -l < "$QW_LOG" | tr -d ' '; }
set_tick() { printf '%s\n' "$1" > "$STATE/quotawatch.tick"; }
now()      { date +%s; }

# 1. NO EVIDENCE — no stamp at all: an install with no quotawatch unit, or one whose
#    daemon set predates #551. The #551 fallback must be fully intact here. --------
rm -f "$STATE/quotawatch.tick"
run_collector || fail "1: a full tick must exit 0"
gate_decided 1
[ "$(hbget phase)" = "done" ] || fail "1: the tick must reach phase=done"
[ "$(calls)" = 1 ] || fail "1: with no quotawatch stamp the collector must run the watch itself (calls: $(calls))"
grep -q -- '--caller collect' "$QW_LOG" || fail "1: the in-tick run must identify itself as --caller collect"
ok "no quotawatch stamp (no unit / pre-#551 install) — the collector runs the watch itself"

# 2. UNIT TICKING — the whole point of #671: a healthy install pays ~0 ------------
set_tick "$(now)"
run_collector || fail "2: a full tick must exit 0"
gate_decided 2
[ "$(calls)" = 0 ] || fail "2: with the unit ticking the collector must NOT run the watch (calls: $(calls))"
ok "quotawatch unit ticking — the collector skips it, no duplicate sweep"

# 7. …and the gated-off phase is still ACCOUNTED, first and at ~0s, so the gate
#    shows up as a number in the heartbeat instead of a phase that vanished. ------
case "$(order)" in quotawatch\ *) : ;; *) fail "7: quotawatch must stay the FIRST phase even when gated off (got: $(order))" ;; esac
s=$(phsecs quotawatch); case "$s" in ''|*[!0-9]*) fail "7: phases= must carry a numeric quotawatch= even when gated off (got: $(hbget phases))" ;; esac
# The floor is not 0: run_phase measures the boundary in whole seconds and
# fleet_timebox polls at 1s, so even a function that returns instantly reads 1-2s
# here. The number that moved is the one in the issue — 46 · 56 · 35 · 57 · 25 · 17
# · 10 · 3 — and over= below is the sharper half of the same assertion.
[ "$s" -le 3 ] || fail "7: a gated-off quotawatch phase must cost ~0s, not a sweep (got ${s}s)"
case " $(hbget over) " in *" quotawatch "*) fail "7: a gated-off quotawatch must never land in over= (got: $(hbget over))" ;; esac
ok "gated off, quotawatch is still the first phase, costs ${s}s, and is absent from over="

# 3. PENDED UNIT — loaded but no longer scheduled (the #639 fault). The stamp is
#    stale, so the fallback must come back on its own. -----------------------------
set_tick "$(( $(now) - 400 ))"     # > max(5 × 60s interval, 180s floor) = 300s
run_collector || fail "3: a full tick must exit 0"
gate_decided 3
[ "$(calls)" = 1 ] || fail "3: a STALE quotawatch stamp (unit pended) must re-engage the in-tick fallback (calls: $(calls))"
ok "quotawatch unit pended (stale stamp) — the fallback re-engages by itself"

# 4/5. the escape hatches ---------------------------------------------------------
set_tick "$(now)"
run_collector FLEET_COLLECT_QUOTAWATCH=always || fail "4: a full tick must exit 0"
gate_decided 4
[ "$(calls)" = 1 ] || fail "4: FLEET_COLLECT_QUOTAWATCH=always must restore the unconditional pre-#671 call (calls: $(calls))"
ok "FLEET_COLLECT_QUOTAWATCH=always — unconditional, even with the unit ticking"

rm -f "$STATE/quotawatch.tick"
run_collector FLEET_COLLECT_QUOTAWATCH=never || fail "5: a full tick must exit 0"
gate_decided 5
[ "$(calls)" = 0 ] || fail "5: FLEET_COLLECT_QUOTAWATCH=never must suppress the in-tick run (calls: $(calls))"
ok "FLEET_COLLECT_QUOTAWATCH=never — suppressed, even with no unit stamp"

# 6. HALF-SYNCED INSTALL — no fleet-daemon-lib.sh, so the gate cannot ask its
#    question. Running the watch twice costs seconds; not running it at all leaves
#    the pre-emptive rotation blind, so the gate must fail OPEN. -------------------
mv "$WORK/bin/fleet-daemon-lib.sh" "$WORK/daemon-lib.parked"
set_tick "$(now)"                       # fresh stamp: only the missing lib can decide this
run_collector || fail "6: a full tick must exit 0"
gate_decided 6
[ "$(calls)" = 1 ] || fail "6: with fleet-daemon-lib.sh missing the gate must fail OPEN and run the watch (calls: $(calls))"
mv "$WORK/daemon-lib.parked" "$WORK/bin/fleet-daemon-lib.sh"
ok "fleet-daemon-lib.sh missing — the gate fails open rather than leaving the fleet blind"

# 8. NO FLAP — the real watch, run BY the collector, must not stamp the scheduling
#    heartbeat. If it did, one fallback tick would look like a healthy unit and the
#    fallback would silently switch itself off (#639's blind spot, reintroduced). ---
real_watch
rm -f "$STATE/quotawatch.tick"
# "No stamp" is only evidence if the real script actually RAN TO COMPLETION — a run
# killed at its budget would leave no stamp either, and pass this vacuously. So every
# tick here also asserts the phase stayed out of over=. (It is cheap: with no accounts
# pool and no hub the real watch hits its fail-open gate and exits in well under a
# second, long after the stamp guard it is being tested on.)
ran_whole_watch() { case " $(hbget over) " in *" quotawatch "*) return 1 ;; esac; return 0; }
for pass in first second; do
  run_collector || fail "8: the $pass tick must exit 0"
  gate_decided "8/$pass"
  ran_whole_watch || fail "8: the $pass in-tick watch was KILLED at its budget — 'it did not stamp' proves nothing about a run that did not finish (over: $(hbget over))"
  [ "$(calls)" = 0 ] || [ ! -f "$STATE/quotawatch.tick" ] \
    || fail "8: the collector's own --caller collect run stamped quotawatch.tick on the $pass tick — the gate would fake itself healthy and switch the fallback off"
  [ ! -f "$STATE/quotawatch.tick" ] \
    || fail "8: the $pass in-tick fallback stamped quotawatch.tick — the fallback must stay engaged until the UNIT ticks"
done
ok "the in-tick fallback never stamps the scheduling heartbeat — it cannot switch itself off"

printf 'selftest PASS: the collector runs fleet-quotawatch.sh only when the unit is not ticking (issue #671)\n'
