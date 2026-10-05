#!/bin/bash
# hub-sessions-loop-selftest.sh — the other machines' sessions keep refreshing
# while NOBODY is looking (issue #1596, EPIC #1645 C6).
#
# The collector (a launchd job, 60s) runs `fleet-hub-sessions.sh --ensure`, which
# starts a ~70s refresh loop. When a launchd job's tick exits, launchd kills every
# process left in its process group — the loop died ~1 s after each start, and
# with no client attached (the sidebar's keeper is the other caller) remote_<sess>
# stood still for 10 hours on m4. Legs:
#   A. survives the tick — --ensure run by a process-group leader that is then
#      SIGKILLed as a group (what launchd does): the loop lives on, in a process
#      group of its own, and keeps writing the cache (hub_ok moves)
#   B. one at a time     — a second --ensure with the loop alive starts nothing
#   C. recycled pid      — a pid file naming a live process that is NOT a --loop
#      (pid reuse) does not count as alive: --ensure starts a real loop
#   D. --status          — `loop <pid> · cache <age>s`, rc 0 with a live loop and
#      a fresh cache; `loop none`, rc 1, with none; `off` with the hub off
#   E. systemd parity    — claude-fleet-collect.service says KillMode=process, and
#      fleet-doctor reads --status (the `hub-sessions` row)
# Drives bin/fleet-hub-sessions.sh, names bin/tmux-dash-collect.sh (its caller) and
# bin/fleet-doctor.sh.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HUBS="$BIN/fleet-hub-sessions.sh"
command -v python3 >/dev/null 2>&1 || { echo 'hub-sessions-loop selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hubloop-selftest.XXXXXX")" || exit 2
S="hubl$$"
G="$WORK/.claude-dash/global"
killloop() { local p; { read -r p < "$G/hubsess.pid"; } 2>/dev/null && kill "$p" 2>/dev/null; :; }
cleanup() { killloop; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_HUB_SESSIONS_CLIENT TMUX TMUX_PANE \
      FLEET_HUB_URL FLEET_CERT XDG_CONFIG_HOME FLEET_ACCOUNTS_DIR CODEX_HOME
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/bin" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/$S/conf"
# no tmux server here: the loop's `watched` probe and local rows see nothing
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
printf '{"machines": [], "sessions": [], "nodes": []}\n' > "$WORK/sessions.json"
export FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_LOOP_SECS=30

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
# wait_for <secs> <cmd…> — poll every 0.2s until <cmd> succeeds; rc 1 on timeout
wait_for() { local n=$(( $1 * 5 )); shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n-1)); done; return 1; }
loop_alive() { local p; { read -r p < "$G/hubsess.pid"; } 2>/dev/null && kill -0 "$p" 2>/dev/null; }

# --- D (off) ------------------------------------------------------------------
out=$(bash "$HUBS" --status 2>&1); rc=$?
CHECKS=$((CHECKS+1)); [ "$out" = off ] && [ "$rc" = 0 ] || fail "D: hub off — --status must say off, rc 0 (rc=$rc)" "$out"
export CCQUOTA_FLEET=1
out=$(bash "$HUBS" --status 2>&1); rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" = 1 ] || fail "D: no loop — --status rc must be 1 (rc=$rc)" "$out"
case "$out" in 'loop none · cache none') : ;; *) fail "D: no loop, no cache — wrong line" "$out" ;; esac
CHECKS=$((CHECKS+1))

# --- A: launchd's group kill ------------------------------------------------------
# A group leader of its own runs --ensure, then the WHOLE group is SIGKILLed —
# exactly launchd's cleanup of a job without AbandonProcessGroup.
python3 - "$HUBS" <<'PY'   # dies by its own SIGKILL: its rc is not the verdict
import os, signal, subprocess, sys, time
os.setsid()                                   # we are the job: our own group
subprocess.run(["bash", sys.argv[1], "--ensure"], check=False)
time.sleep(0.5)                               # the loop is up and in its first round
signal.signal(signal.SIGTERM, signal.SIG_IGN)
os.killpg(os.getpgid(0), signal.SIGKILL)      # launchd: the tick is over
PY
wait_for 5 loop_alive || fail "A: the loop died with the tick's process group"
CHECKS=$((CHECKS+1))
read -r P < "$G/hubsess.pid"
pg=$(ps -o pgid= -p "$P" 2>/dev/null | tr -d ' ')
CHECKS=$((CHECKS+1)); [ "$pg" = "$P" ] || fail "A: the loop must lead a process group of its own (pid $P pgid $pg)"
wait_for 5 test -s "$G/hub_ok" || fail "A: the surviving loop never wrote hub_ok"
read -r t1 < "$G/hub_ok"
wait_for 6 sh -c '[ "$(cat "$1")" -gt "$2" ]' _ "$G/hub_ok" "$t1" || fail "A: hub_ok does not move — the loop is not refreshing"
CHECKS=$((CHECKS+1))

# --- D (alive) ----------------------------------------------------------------
out=$(bash "$HUBS" --status 2>&1); rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" = 0 ] || fail "D: live loop + fresh cache — --status rc must be 0 (rc=$rc)" "$out"
case "$out" in "loop $P · cache "[0-9]*s) : ;; *) fail "D: live loop — wrong line" "$out" ;; esac
CHECKS=$((CHECKS+1))

# --- B: one at a time ---------------------------------------------------------------
bash "$HUBS" --ensure
sleep 1
read -r P2 < "$G/hubsess.pid"
CHECKS=$((CHECKS+1)); [ "$P2" = "$P" ] || fail "B: a second --ensure replaced the live loop ($P → $P2)"

# --- C: a recycled pid ----------------------------------------------------------
killloop; wait_for 5 sh -c '! kill -0 "$1" 2>/dev/null' _ "$P" || fail "C: could not stop the leg-A loop"
sleep 30 & DECOY=$!                           # alive, and not a --loop
printf '%s\n' "$DECOY" > "$G/hubsess.pid"
out=$(bash "$HUBS" --status 2>&1)
case "$out" in 'loop none'*) : ;; *) kill "$DECOY" 2>/dev/null; fail "C: a recycled pid counted as the loop" "$out" ;; esac
CHECKS=$((CHECKS+1))
bash "$HUBS" --ensure
wait_for 5 sh -c 'read -r p < "$1" && [ "$p" != "$2" ] && kill -0 "$p"' _ "$G/hubsess.pid" "$DECOY" \
  || { kill "$DECOY" 2>/dev/null; fail "C: --ensure trusted a recycled pid and started no loop"; }
CHECKS=$((CHECKS+1))
kill "$DECOY" 2>/dev/null

# --- E: systemd parity + the doctor row -----------------------------------------
CHECKS=$((CHECKS+1)); grep -q '^KillMode=process$' "$BIN/../systemd/claude-fleet-collect.service" \
  || fail "E: claude-fleet-collect.service must say KillMode=process (the loop outlives the tick)"
CHECKS=$((CHECKS+1)); grep -q 'fleet-hub-sessions.sh" --status' "$BIN/fleet-doctor.sh" \
  || fail "E: fleet-doctor must read fleet-hub-sessions.sh --status"
CHECKS=$((CHECKS+1)); grep -q 'fleet-hub-sessions.sh" --ensure' "$BIN/tmux-dash-collect.sh" \
  || fail "E: the collector no longer runs --ensure every tick"

printf 'hub-sessions-loop selftest: PASS (%s checks)\n' "$CHECKS"
