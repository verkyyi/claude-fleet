#!/bin/bash
# fleet-collect-stale-selftest.sh — the dash's collector-liveness alarm and its
# rate-limited self-heal (issue #636). Drives the REAL usage-lib.sh helpers,
# bin/fleet-collect-kick.sh and bin/tmux-status.sh against a fake `launchctl` on
# PATH — no launchd, no tmux server, no network.
#
# Since issue #639 the kick itself lives in bin/fleet-daemon-watch.sh, which does
# the same for every interval unit; fleet-collect-kick.sh is the collector's entry
# point onto it and its contract is UNCHANGED, which is exactly what this file
# pins. The registry, the relative-interval thresholds and the per-unit rails are
# covered by bin/fleet-daemon-watch-selftest.sh.
#
# Why this is worth pinning. When the collector stops, the dash does NOT go
# blank; it keeps drawing the last tick's world with no tell (launchd pended
# com.claude-fleet.collect for 103 minutes on 2026-09-14, `last exit code = 0`).
# So the alarm has to fire off the heartbeat alone, the self-heal has to be
# rate-limited (the status bar runs every 5s, per attached client — an unlimited
# kicker is a kick loop), and the recovery must leave a trace, or the outage
# disappears the moment it ends.
#
#   1. fresh    — a heartbeat stamped now ⇒ no alarm, `--status` fresh, no kick.
#   2. inflight — a tick that STARTED long ago but is advancing its phases ⇒ not
#                 stale (phase_ts, not start, is the progress signal).
#   3. never    — no heartbeat at all ⇒ fail-open: no alarm, no kick, status
#                 `never` (a fresh install must not paint the bar red).
#   4. stale    — heartbeat older than FLEET_COLLECT_STALE ⇒ age reported, the
#                 status bar shows `⚠ dash stale`, and the kick fires exactly one
#                 `launchctl kickstart -k` against the collector's own unit.
#   5. cooldown — a second (and third) run inside the cooldown kicks NOTHING while
#                 the alarm stays up; past the cooldown it kicks again. This is
#                 the "don't punch yourself every 60s" rail.
#   6. trace    — after a kick the bar shows `↻` WHILE stale, and keeps showing
#                 `↻ dash kicked` after the collector recovers, until the trace
#                 window expires. Then the bar is clean again.
#   7. log      — every kick appends one line to logs/daemon-kick.log with the
#                 unit, the staleness and the kickstart's exit code.
#   8. off      — FLEET_COLLECT_KICK=0 keeps the alarm and kicks nothing.
#   9. no-unit  — no launchd/systemd unit loaded ⇒ no kick, logged as `no-unit`,
#                 and the alarm is left standing.
#  10. bar      — rendering the REAL status bar with the self-heal armed kicks the
#                 collector by itself: the bar is who notices when no one runs
#                 fleet-doctor.
#  11. callers  — the three discovery paths are still wired: the status bar, the
#                 KeepAlive spinner (the only daemon that survived the launchd
#                 stall) and the quotawatch backstop.
#  12. relative  — with FLEET_COLLECT_STALE unset the threshold is MULTIPLES of the
#                 unit's own 60s StartInterval, not the old absolute 600s: the
#                 7–14-minute collector #639 measured alarms instead of reading
#                 `fresh 401 472` forever.
#
# Exit 0 = pass, non-zero = fail.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
FILES='fleet-collect-kick.sh fleet-daemon-watch.sh fleet-daemon-lib.sh usage-lib.sh tmux-status.sh'
for f in $FILES; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/collect-stale-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"   # physical path: the scripts resolve $BIN via pwd
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/.claude-dash/global"
for f in $FILES; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
G="$WORK/.claude-dash/global"
HB="$G/collect.heartbeat"
KTS="$G/collect.kick.ts"
KICKLOG="$WORK/logs/daemon-kick.log"

# --- fake launchctl: `print <target>` succeeds iff the unit is "loaded"
# ($FAKE_UNIT_LOADED), `kickstart` logs the call and returns $FAKE_KICK_RC.
cat > "$WORK/fakepath/launchctl" <<'FAKE'
#!/bin/bash
case "$1" in
  print)     [ "${FAKE_UNIT_LOADED:-1}" = 1 ] && exit 0 || exit 113 ;;
  kickstart) echo "$*" >> "$FAKE_KICK_LOG"; exit "${FAKE_KICK_RC:-0}" ;;
esac
exit 0
FAKE
# A host with systemd would otherwise fall through to it in the no-unit case.
cat > "$WORK/fakepath/systemctl" <<'FAKE'
#!/bin/bash
exit 1
FAKE
chmod +x "$WORK/fakepath/launchctl" "$WORK/fakepath/systemctl"

export PATH="$WORK/fakepath:$PATH"
export TMPDIR="$WORK"                 # every cache read/write lands under WORK
# The stamps a NON-live checkout writes are scoped away from the shared global/
# cache on purpose (issue #639: a worker testing the self-heal in its own
# worktree wrote `↻ dash kicked` onto the live operator's status bar). This work
# tree IS the install under test, so declare it live — otherwise the writer and
# the reader here would deliberately disagree. The scoping itself is asserted in
# bin/fleet-daemon-watch-selftest.sh.
export FLEET_LIVE_ROOT="$WORK"
# …and it has NO installed plists. §9 asserts the "nothing to kick" path, which
# since #639 first checks whether the unit's plist is on disk (a not-loaded unit
# with a plist is bootstrapped back rather than given up on). Pointing this at the
# real ~/Library/LaunchAgents would make §9 depend on the operator's own machine.
mkdir -p "$WORK/agents"
export FLEET_LAUNCHD_AGENTS_DIR="$WORK/agents"
export FAKE_KICK_LOG="$WORK/kicks.log"
export FLEET_COLLECT_STALE=300
export FLEET_COLLECT_KICK_COOLDOWN=600
export FLEET_COLLECT_KICK_TRACE=1800
: > "$FAKE_KICK_LOG"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }
now()  { date +%s; }
kicks() { wc -l < "$FAKE_KICK_LOG" 2>/dev/null | tr -d " " || echo 0; }

# hb <age-of-phase_ts-in-seconds> [<age-of-start>] — write a completed-tick
# heartbeat shaped exactly like bin/tmux-dash-collect.sh's hb_phase '' output.
hb() {
  local pts=$(( $(now) - $1 )) st=$(( $(now) - ${2:-$1} ))
  printf 'pid=1234\nstart=%s\nphase=done\nphase_ts=%s\nphases=git=69 ctx=1\nend=%s\ndur=%s\n' \
    "$st" "$pts" "$pts" "$(( pts - st ))" > "$HB"
}
# hb_running <age-of-start> <age-of-phase_ts> — a tick still in flight: no end=.
hb_running() {
  printf 'pid=1234\nstart=%s\nphase=git\nphase_ts=%s\nphases=quotawatch=2\n' \
    "$(( $(now) - $1 ))" "$(( $(now) - $2 ))" > "$HB"
}

lib() {  # run one expression against the real helpers, in a clean shell.
  # Both libs, in the order the real consumers source them: fleet_collect_stale_secs
  # delegates to fleet_daemon_stale_secs when it is defined (issue #639), and a
  # test that sourced only usage-lib.sh would silently exercise the fallback.
  bash -c 'set -uo pipefail; . "$1/usage-lib.sh"; . "$1/fleet-daemon-lib.sh"; shift; eval "$@"' _ "$WORK/bin" "$@"
}
kick()   { bash "$WORK/bin/fleet-collect-kick.sh" "$@" 2>>"$WORK/kick.err"; }
# The status bar SELF-HEALS (it forks the kick when one is due), which is the
# point of §10 — but it makes every other rendering assertion race the fork. So
# the ordinary bar() renders with the self-heal disarmed, and bar_live() is the
# one that is allowed to kick.
bar()      { FLEET_COLLECT_KICK=0 bash "$WORK/bin/tmux-status.sh" 2>/dev/null; }
bar_live() { bash "$WORK/bin/tmux-status.sh" 2>/dev/null; }
wait_kicks() {  # $1 = expected count; the bar's kick is a detached fork
  local i=0
  while [ "$(kicks)" -lt "$1" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  [ "$(kicks)" -eq "$1" ]
}

# ---------------------------------------------------------------- 1. fresh ----
hb 30
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "1: a 30s-old heartbeat reported stale"; ok
[ "$(kick --status | cut -f1)" = fresh ] || fail "1: --status not fresh"; ok
kick; [ "$(kicks)" -eq 0 ] || fail "1: kicked a healthy collector"; ok
case "$(bar)" in *"dash stale"*) fail "1: status bar alarmed on a fresh heartbeat" ;; esac; ok

# ------------------------------------------------------------- 2. inflight ----
# start 9 minutes ago (past STALE) but the phases are still advancing: the tick is
# slow, not dead. A `git` phase alone has been seen at 551s on a big fleet, so
# this is the ordinary case that must NEVER alarm.
hb_running 540 20
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "2: an advancing in-flight tick reported stale"; ok
kick; [ "$(kicks)" -eq 0 ] || fail "2: kicked a tick that is making progress"; ok
# …but one wedged in a single phase past the threshold IS stale (the #551 shape).
hb_running 900 600
[ -n "$(lib 'fleet_collect_stale_age')" ] || fail "2: a tick wedged 600s in one phase not reported stale"; ok

# ---------------------------------------------------------------- 3. never ----
rm -f "$HB"
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "3: alarmed with no heartbeat at all"; ok
[ "$(kick --status | cut -f1)" = never ] || fail "3: --status not never"; ok
kick; [ "$(kicks)" -eq 0 ] || fail "3: kicked with no heartbeat (fresh install)"; ok
case "$(bar)" in *"dash stale"*) fail "3: status bar alarmed on a fresh install" ;; esac; ok

# ---------------------------------------------------------------- 4. stale ----
hb 900
age=$(lib 'fleet_collect_stale_age')
[ -n "$age" ] && [ "$age" -ge 900 ] || fail "4: stale age not reported (got '$age')"; ok
[ "$(kick --status | cut -f1)" = stale ] || fail "4: --status not stale"; ok
case "$(bar)" in *"⚠ dash stale 15m"*) ok ;; *) fail "4: status bar missing '⚠ dash stale 15m': $(bar)" ;; esac
lib 'fleet_collect_kick_due' || fail "4: kick not due on a stale collector with no prior kick"; ok
kick
[ "$(kicks)" -eq 1 ] || fail "4: expected exactly 1 kickstart, got $(kicks)"; ok
grep -q 'kickstart -k gui/.*/com.claude-fleet.collect' "$FAKE_KICK_LOG" \
  || fail "4: kicked the wrong target: $(cat "$FAKE_KICK_LOG")"; ok
[ -f "$KTS" ] || fail "4: no kick stamp written"; ok

# ------------------------------------------------------------- 5. cooldown ----
kick; kick
[ "$(kicks)" -eq 1 ] || fail "5: kicked again inside the cooldown ($(kicks) total)"; ok
lib 'fleet_collect_kick_due' && fail "5: kick still reported due inside the cooldown"; ok
[ -n "$(lib 'fleet_collect_stale_age')" ] || fail "5: alarm dropped while still stale"; ok
# Past the cooldown it kicks again — a stuck daemon is retried, just not spun on.
printf '%s\n' "$(( $(now) - 700 ))" > "$KTS"
lib 'fleet_collect_kick_due' || fail "5: kick not due again past the cooldown"; ok
kick
[ "$(kicks)" -eq 2 ] || fail "5: no second kick past the cooldown ($(kicks) total)"; ok

# ---------------------------------------------------------------- 6. trace ----
case "$(bar)" in *"dash stale"*"↻"*) ok ;; *) fail "6: no ↻ trace while stale after a kick: $(bar)" ;; esac
hb 30                                    # the collector recovers…
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "6: still stale after recovery"; ok
case "$(bar)" in *"↻ dash kicked"*) ok ;; *) fail "6: recovery was silent — no kick trace: $(bar)" ;; esac
printf '%s\n' "$(( $(now) - 2000 ))" > "$KTS"    # …and the trace window expires
case "$(bar)" in *"dash kicked"*|*"dash stale"*) fail "6: trace outlived its window: $(bar)" ;; esac; ok

# ------------------------------------------------------------------ 7. log ----
[ -f "$KICKLOG" ] || fail "7: no logs/daemon-kick.log"; ok
[ "$(grep -c '^.* kick ' "$KICKLOG")" -eq 2 ] || fail "7: expected 2 logged kicks, got: $(cat "$KICKLOG")"; ok
grep -q 'stale=.*mgr=launchd.*rc=0' "$KICKLOG" || fail "7: log line missing staleness/mgr/rc: $(cat "$KICKLOG")"; ok

# ------------------------------------------------------------------ 8. off ----
hb 900; rm -f "$KTS"; : > "$FAKE_KICK_LOG"
FLEET_COLLECT_KICK=0 kick
[ "$(kicks)" -eq 0 ] || fail "8: kicked with FLEET_COLLECT_KICK=0"; ok
case "$(bar)" in *"⚠ dash stale"*) ok ;; *) fail "8: FLEET_COLLECT_KICK=0 also silenced the alarm" ;; esac

# -------------------------------------------------------------- 9. no-unit ----
# Nothing loaded: don't kick into the void, but say so and leave the alarm up.
FAKE_UNIT_LOADED=0 kick
[ "$(kicks)" -eq 0 ] || fail "9: kicked a unit that is not loaded"; ok
grep -q '^.* no-unit ' "$KICKLOG" || fail "9: no-unit not logged: $(cat "$KICKLOG")"; ok
case "$(bar)" in *"⚠ dash stale"*) ok ;; *) fail "9: alarm dropped when no unit is loaded" ;; esac

# ------------------------------------------------------- 10. bar self-heals ----
# The whole point of #636: nobody was watching a doctor run, so whoever DOES see
# the staleness must act on it. Render the real status bar with the self-heal
# armed and the kick must land on its own.
hb 900; rm -f "$KTS"; : > "$FAKE_KICK_LOG"
case "$(bar_live)" in *"⚠ dash stale"*) ok ;; *) fail "10: bar did not alarm" ;; esac
wait_kicks 1 || fail "10: the status bar did not self-heal a stale collector (kicks=$(kicks))"; ok
case "$(bar)" in *"dash stale"*"↻"*) ok ;; *) fail "10: no trace after the bar's own kick: $(bar)" ;; esac

# ------------------------------------------------- 11. the headless callers ----
# The discovery paths are the design, so pin them from the source. The KeepAlive
# spinner is the only fleet daemon that survived the 2026-09-14 launchd stall —
# every StartInterval unit, quotawatch included, was pended together — so a
# self-heal wired ONLY into another interval unit would have been asleep next to
# its patient. Both call sites must stay.
grep -q 'fleet-daemon-watch.sh' "$BIN/tmux-spinner.sh" \
  || fail "11: the KeepAlive spinner no longer runs the daemon self-heal — the headless path is gone"; ok
grep -q 'KICK_EVERY' "$BIN/tmux-spinner.sh" \
  || fail "11: the spinner's self-heal lost its frame throttle"; ok
grep -q 'fleet-collect-kick.sh' "$BIN/fleet-quotawatch.sh" \
  || fail "11: the quota watch no longer runs the collector self-heal backstop"; ok
grep -q 'fleet_collect_kick_due' "$BIN/tmux-status.sh" \
  || fail "11: the status bar no longer self-heals"; ok

# ------------------------------------------------------------- 12. relative ----
# 12b (below) also covers the in-flight guard end-to-end: it is the STATUS BAR
# that has to stay quiet while a tick is legitimately long, and the bar reads
# fleet_collect_stale_age — so the guard has to be visible from there, not only
# from the daemon lib's own helper.

# The regression #639 is about: `FLEET_COLLECT_STALE=600` (the collector's own
# supersede deadline) is above the age a 7–14-minute collector ever reaches
# between spawns, so the alarm that #638 shipped never fired on the degradation
# that actually happens — only on a full stop. Unset, the threshold is now
# FLEET_DAEMON_STALE_MULT × the unit's own 60s interval.
unset FLEET_COLLECT_STALE
[ "$(lib 'fleet_collect_stale_secs')" = 300 ] \
  || fail "12: default threshold is not 5× the 60s interval (got $(lib 'fleet_collect_stale_secs'))"; ok
[ "$(FLEET_DAEMON_STALE_MULT=10 lib 'fleet_collect_stale_secs')" = 600 ] \
  || fail "12: FLEET_DAEMON_STALE_MULT does not scale the threshold"; ok
[ "$(FLEET_COLLECT_STALE=900 lib 'fleet_collect_stale_secs')" = 900 ] \
  || fail "12: the absolute FLEET_COLLECT_STALE override stopped winning"; ok
# 401s — the exact staleness #639 measured reading `fresh` — now alarms.
hb 401
[ -n "$(lib 'fleet_collect_stale_age')" ] \
  || fail "12: a collector 401s behind a 60s interval still reads fresh (the #639 blind spot)"; ok
[ -z "$(FLEET_COLLECT_STALE=600 lib 'fleet_collect_stale_age')" ] \
  || fail "12: 401s should be fresh under the OLD absolute 600s threshold — the fixture no longer reproduces #639"; ok
case "$(bar)" in *"⚠ dash stale"*) ok ;; *) fail "12: the bar did not alarm at 401s: $(bar)" ;; esac

# 12b. …and a tick that is IN FLIGHT silences it again, straight from the bar. A
# 551s git phase is on record from a monorepo fleet: without this the tighter
# threshold would paint the bar red through every one of that fleet's ticks.
printf 'pid=1234\nstart=%s\nphase=git\nphase_ts=%s\n' \
  "$(( $(now) - 900 ))" "$(( $(now) - 900 ))" > "$HB"
case "$(bar)" in *"⚠ dash stale"*) ok ;; *) fail "12b: no alarm with a 900s-silent heartbeat and no tick: $(bar)" ;; esac
printf '%s\t%s\n' "$$" "$(( $(now) - 400 ))" > "$G/collect.pid"
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "12b: a live tick 400s in was still called stale"; ok
case "$(bar)" in *"dash stale"*) fail "12b: the bar alarmed while a tick was in flight: $(bar)" ;; esac; ok
printf '%s\t%s\n' "$$" "$(( $(now) - 900 ))" > "$G/collect.pid"   # past the deadline ⇒ wedged
[ -n "$(lib 'fleet_collect_stale_age')" ] || fail "12b: a tick past the supersede deadline still counted as alive"; ok
rm -f "$G/collect.pid"

printf 'selftest PASS: %s assertions (fresh · inflight · never · stale · cooldown · trace · log · off · no-unit · bar-self-heal · callers · relative · in-flight)\n' "$CHECKS"
exit 0
