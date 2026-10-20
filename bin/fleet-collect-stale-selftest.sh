#!/bin/bash
# fleet-collect-stale-selftest.sh — the dash's collector-liveness alarm and its
# rate-limited self-heal (#636): the REAL usage-lib.sh, fleet-collect-kick.sh (the
# collector's entry onto fleet-daemon-watch.sh, #639) and fleet-alerts.sh against a
# fake launchctl. The alarm fires off the heartbeat alone; the kick is rate-limited
# and leaves a trace. Cases: 1 fresh · 2 inflight · 3 never (fail-open) · 4 stale
# (one kickstart) · 5 cooldown · 6 trace · 7 log · 8 off · 9 no-unit · 10 the bar
# self-heals · 11 callers · 12 relative threshold · 12b in-flight.
# Exit 0 = pass, non-zero = fail.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
FILES='fleet-collect-kick.sh fleet-daemon-watch.sh fleet-daemon-lib.sh usage-lib.sh fleet-alerts.sh fleet-palette.sh'
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
export FLEET_CONF_DIR="$WORK/conf"   # the kick log is the login's record (#4668)
KICKLOG="$FLEET_CONF_DIR/logs/daemon-kick.log"

# fake launchctl: `print` succeeds iff FAKE_UNIT_LOADED, `kickstart` logs.
cat > "$WORK/fakepath/launchctl" <<'FAKE'
#!/bin/bash
case "$1" in
  print)     [ "${FAKE_UNIT_LOADED:-1}" = 1 ] && exit 0 || exit 113 ;;
  kickstart) echo "$*" >> "$FAKE_KICK_LOG"; exit "${FAKE_KICK_RC:-0}" ;;
esac
exit 0
FAKE
cat > "$WORK/fakepath/systemctl" <<'FAKE'
#!/bin/bash
exit 1
FAKE
chmod +x "$WORK/fakepath/launchctl" "$WORK/fakepath/systemctl"

export PATH="$WORK/fakepath:$PATH"
export TMPDIR="$WORK"                 # every cache read/write lands under WORK
# This tree IS the install under test: declare it live, or its stamps are scoped
# away from global/ on purpose (#639; asserted in fleet-daemon-watch-selftest).
export FLEET_LIVE_ROOT="$WORK"
# …with NO installed plists, so §9 never depends on the operator's machine.
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

# hb <age-of-phase_ts> [<age-of-start>] — a completed tick's heartbeat.
hb() {
  local pts=$(( $(now) - $1 )) st=$(( $(now) - ${2:-$1} ))
  printf 'pid=1234\nstart=%s\nphase=done\nphase_ts=%s\nphases=git=69 ctx=1\nend=%s\ndur=%s\n' \
    "$st" "$pts" "$pts" "$(( pts - st ))" > "$HB"
}
# hb_running <age-of-start> <age-of-phase_ts> — a tick in flight: no end=.
hb_running() {
  printf 'pid=1234\nstart=%s\nphase=git\nphase_ts=%s\nphases=quotawatch=2\n' \
    "$(( $(now) - $1 ))" "$(( $(now) - $2 ))" > "$HB"
}

lib() {  # run one expression against the real helpers, in a clean shell.
  # Both libs, as the consumers source them (#639: the fallback otherwise).
  bash -c 'set -uo pipefail; . "$1/usage-lib.sh"; . "$1/fleet-daemon-lib.sh"; shift; eval "$@"' _ "$WORK/bin" "$@"
}
kick()   { bash "$WORK/bin/fleet-collect-kick.sh" "$@" 2>>"$WORK/kick.err"; }
# bar() renders with the self-heal disarmed (its kick is a fork that would race
# the other assertions); bar_live() may kick (§10). TTL 0: every render rewrites.
bar()      { FLEET_CONF_DIR="$WORK/noconf" FLEET_ALERTS_TTL=0 FLEET_COLLECT_KICK=0 bash "$WORK/bin/fleet-alerts.sh" refresh --kick >/dev/null 2>&1
             bash "$WORK/bin/fleet-alerts.sh" bar 2>/dev/null; echo; bash "$WORK/bin/fleet-alerts.sh" list --plain 2>/dev/null; }
bar_live() { FLEET_CONF_DIR="$WORK/noconf" FLEET_ALERTS_TTL=0 bash "$WORK/bin/fleet-alerts.sh" refresh --kick >/dev/null 2>&1
             bash "$WORK/bin/fleet-alerts.sh" bar 2>/dev/null; echo; bash "$WORK/bin/fleet-alerts.sh" list --plain 2>/dev/null; }
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
case "$(bar)" in *"✖  dash · stale"*) fail "1: status bar alarmed on a fresh heartbeat" ;; esac; ok

# ------------------------------------------------------------- 2. inflight ----
# Started 9 min ago but its phases advance: slow, not dead — never alarm.
hb_running 540 20
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "2: an advancing in-flight tick reported stale"; ok
kick; [ "$(kicks)" -eq 0 ] || fail "2: kicked a tick that is making progress"; ok
hb_running 900 600
[ -n "$(lib 'fleet_collect_stale_age')" ] || fail "2: a tick wedged 600s in one phase not reported stale"; ok

# ---------------------------------------------------------------- 3. never ----
rm -f "$HB"
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "3: alarmed with no heartbeat at all"; ok
[ "$(kick --status | cut -f1)" = never ] || fail "3: --status not never"; ok
kick; [ "$(kicks)" -eq 0 ] || fail "3: kicked with no heartbeat (fresh install)"; ok
case "$(bar)" in *"✖  dash · stale"*) fail "3: status bar alarmed on a fresh install" ;; esac; ok

# ---------------------------------------------------------------- 4. stale ----
hb 900
age=$(lib 'fleet_collect_stale_age')
[ -n "$age" ] && [ "$age" -ge 900 ] || fail "4: stale age not reported (got '$age')"; ok
[ "$(kick --status | cut -f1)" = stale ] || fail "4: --status not stale"; ok
case "$(bar)" in *"✖ 1#"*"dash · stale · 15m"*) ok ;; *) fail "4: status bar missing '✖ 1' + 'dash · stale · 15m': $(bar)" ;; esac
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
printf '%s\n' "$(( $(now) - 700 ))" > "$KTS"
lib 'fleet_collect_kick_due' || fail "5: kick not due again past the cooldown"; ok
kick
[ "$(kicks)" -eq 2 ] || fail "5: no second kick past the cooldown ($(kicks) total)"; ok

# ---------------------------------------------------------------- 6. trace ----
case "$(bar)" in *"✖  dash · stale"*"↻"*) ok ;; *) fail "6: no ↻ trace while stale after a kick: $(bar)" ;; esac
hb 30                                    # the collector recovers…
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "6: still stale after recovery"; ok
case "$(bar)" in *"↻  dash · stale · kicked"*) ok ;; *) fail "6: recovery was silent — no kick trace: $(bar)" ;; esac
printf '%s\n' "$(( $(now) - 2000 ))" > "$KTS"    # …and the trace window expires
case "$(bar)" in *"dash · stale"*) fail "6: trace outlived its window: $(bar)" ;; esac; ok

# ------------------------------------------------------------------ 7. log ----
[ -f "$KICKLOG" ] || fail "7: no logs/daemon-kick.log"; ok
[ "$(grep -c '^.* kick ' "$KICKLOG")" -eq 2 ] || fail "7: expected 2 logged kicks, got: $(cat "$KICKLOG")"; ok
grep -q 'stale=.*mgr=launchd.*rc=0' "$KICKLOG" || fail "7: log line missing staleness/mgr/rc: $(cat "$KICKLOG")"; ok

# ------------------------------------------------------------------ 8. off ----
hb 900; rm -f "$KTS"; : > "$FAKE_KICK_LOG"
FLEET_COLLECT_KICK=0 kick
[ "$(kicks)" -eq 0 ] || fail "8: kicked with FLEET_COLLECT_KICK=0"; ok
case "$(bar)" in *"✖  dash · stale"*) ok ;; *) fail "8: FLEET_COLLECT_KICK=0 also silenced the alarm" ;; esac

# -------------------------------------------------------------- 9. no-unit ----
FAKE_UNIT_LOADED=0 kick
[ "$(kicks)" -eq 0 ] || fail "9: kicked a unit that is not loaded"; ok
grep -q '^.* no-unit ' "$KICKLOG" || fail "9: no-unit not logged: $(cat "$KICKLOG")"; ok
case "$(bar)" in *"✖  dash · stale"*) ok ;; *) fail "9: alarm dropped when no unit is loaded" ;; esac

# ------------------------------------------------------- 10. bar self-heals ----
# Nobody watches a doctor run (#636): the bar itself kicks.
hb 900; rm -f "$KTS"; : > "$FAKE_KICK_LOG"
case "$(bar_live)" in *"✖  dash · stale"*) ok ;; *) fail "10: bar did not alarm" ;; esac
wait_kicks 1 || fail "10: the status bar did not self-heal a stale collector (kicks=$(kicks))"; ok
case "$(bar)" in *"✖  dash · stale"*"↻"*) ok ;; *) fail "10: no trace after the bar's own kick: $(bar)" ;; esac

# ------------------------------------------------- 11. the headless callers ----
# The headless callers, pinned from the source: the KeepAlive spinner (the one
# daemon that survived the 2026-09-14 launchd stall) and the reconcile tick.
grep -q 'fleet-daemon-watch.sh' "$BIN/tmux-spinner.py" \
  || fail "11: the KeepAlive spinner no longer runs the daemon self-heal — the headless path is gone"; ok
grep -q 'daemon_watch=30' "$BIN/tmux-spinner.py" \
  || fail "11: the spinner's self-heal lost its frame throttle"; ok
grep -q 'fleet-collect-kick.sh' "$BIN/fleet-reconcile-tick.sh" \
  || fail "11: the reconcile tick no longer runs the collector self-heal backstop (it took it from the quota watch, T549)"; ok
grep -q 'fleet_collect_kick_due' "$BIN/fleet-alerts.sh" \
  || fail "11: the alerts producer no longer self-heals"; ok

# ------------------------------------------------------------- 12. relative ----
# Unset FLEET_COLLECT_STALE ⇒ FLEET_DAEMON_STALE_MULT × the unit's 60s interval,
# not the old absolute 600s a 7–14-minute collector never reached (#639).
unset FLEET_COLLECT_STALE
[ "$(lib 'fleet_collect_stale_secs')" = 300 ] \
  || fail "12: default threshold is not 5× the 60s interval (got $(lib 'fleet_collect_stale_secs'))"; ok
[ "$(FLEET_DAEMON_STALE_MULT=10 lib 'fleet_collect_stale_secs')" = 600 ] \
  || fail "12: FLEET_DAEMON_STALE_MULT does not scale the threshold"; ok
[ "$(FLEET_COLLECT_STALE=900 lib 'fleet_collect_stale_secs')" = 900 ] \
  || fail "12: the absolute FLEET_COLLECT_STALE override stopped winning"; ok
hb 401
[ -n "$(lib 'fleet_collect_stale_age')" ] \
  || fail "12: a collector 401s behind a 60s interval still reads fresh (the #639 blind spot)"; ok
[ -z "$(FLEET_COLLECT_STALE=600 lib 'fleet_collect_stale_age')" ] \
  || fail "12: 401s should be fresh under the OLD absolute 600s threshold — the fixture no longer reproduces #639"; ok
case "$(bar)" in *"✖  dash · stale"*) ok ;; *) fail "12: the bar did not alarm at 401s: $(bar)" ;; esac

# 12b. an IN-FLIGHT tick silences it again, read straight from the bar.
printf 'pid=1234\nstart=%s\nphase=git\nphase_ts=%s\n' \
  "$(( $(now) - 900 ))" "$(( $(now) - 900 ))" > "$HB"
case "$(bar)" in *"✖  dash · stale"*) ok ;; *) fail "12b: no alarm with a 900s-silent heartbeat and no tick: $(bar)" ;; esac
printf '%s\t%s\n' "$$" "$(( $(now) - 400 ))" > "$G/collect.pid"
[ -z "$(lib 'fleet_collect_stale_age')" ] || fail "12b: a live tick 400s in was still called stale"; ok
case "$(bar)" in *"✖  dash · stale"*) fail "12b: the bar alarmed while a tick was in flight: $(bar)" ;; esac; ok
printf '%s\t%s\n' "$$" "$(( $(now) - 900 ))" > "$G/collect.pid"   # past the deadline ⇒ wedged
[ -n "$(lib 'fleet_collect_stale_age')" ] || fail "12b: a tick past the supersede deadline still counted as alive"; ok
rm -f "$G/collect.pid"

printf 'selftest PASS: %s assertions (fresh · inflight · never · stale · cooldown · trace · log · off · no-unit · bar-self-heal · callers · relative · in-flight)\n' "$CHECKS"
exit 0
