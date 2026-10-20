#!/bin/bash
# hub-sessions-inv-selftest.sh — the refresh loop reads this machine's window
# inventory only when it can have changed (issue #3544).
#
# A watched fleet-hub-sessions.sh --loop refreshes every 2 s, and each round ran
# `fleet-control-read.sh workers` per fleet (~25 processes) to map the hub's rows
# onto local windows. The inventory only changes on a spawn, a close or a state
# change, each of which touches $FLEET_CONF_DIR/global/hub-nudge. Legs:
#   A. kept       — nudge older than the loop: ONE inventory read for a whole
#                   loop of rounds, and every round's map still holds its rows
#   B. nudged     — a nudge mid-loop: the next round reads again
#   C. one-shot   — two bare --refresh read twice (never reused)
#   D. no nudge   — no hub-nudge file: every round reads, as before
#   E. TTL 0      — FLEET_HUB_SESSIONS_INV_TTL=0: every round reads
# Drives bin/fleet-hub-sessions.sh with a counting stand-in for
# bin/fleet-control-read.sh (a shadow bin/ of symlinks; nothing else changed).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hubinv-selftest.XXXXXX")" || exit 2
S="hubi$$"
G="$WORK/.claude-dash/global"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_NODE_ALIASES FLEET_HUB_SESSIONS_USER \
      FLEET_HUB_SESSIONS_STALE FLEET_HUB_SESSIONS_CLIENT TMUX TMUX_PANE FLEET_HUB_URL FLEET_CERT \
      XDG_CONFIG_HOME FLEET_ACCOUNTS_DIR CODEX_HOME FLEET_HUB_SESSIONS_INV_TTL
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" CCQUOTA_FLEET=1
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/conf/global" "$WORK/bin" "$WORK/sbin" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/$S/conf"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"   # nobody watching: EVERY
export PATH="$WORK/bin:$PATH"
printf '{"machines": [], "sessions": [], "nodes": []}\n' > "$WORK/sessions.json"
export FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_HUB_SESSIONS_EVERY=1

# the shadow bin/: every file the real one has, the inventory read counting itself
for f in "$BIN"/*; do ln -s "$f" "$WORK/sbin/${f##*/}"; done
rm -f "$WORK/sbin/fleet-control-read.sh"
export READS="$WORK/reads"   # the stand-in counts into $READS: a lane below has its own
cat > "$WORK/sbin/fleet-control-read.sh" <<EOF
#!/bin/bash
[ "\${1:-}" = workers ] && { echo x >> "\$READS"; printf '@7\t42\t\t%s/wt\tworking\n' '$WORK'; }
exit 0
EOF
chmod +x "$WORK/sbin/fleet-control-read.sh"
HUBS="$WORK/sbin/fleet-hub-sessions.sh"

CHECKS=0
reads() { [ -f "$READS" ] && grep -c . "$READS" || echo 0; }
age() { python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
NUDGE="$WORK/conf/global/hub-nudge"

# lane <leg> — the loop legs (A, B, D, E: seconds of loop each) run at once, each
# a subshell with its own TMPDIR (so its own .claude-dash), conf dir, nudge file
# and read count; its count of checks comes back in a file, a FAIL as its exit.
lane() {
  ( L="$WORK/lane-$1"; mkdir -p "$L/.claude-dash/global" "$L/conf/global"
    cp -R "$WORK/conf/fleets" "$L/conf/fleets"
    export TMPDIR="$L" FLEET_CONF_DIR="$L/conf" READS="$L/reads"
    G="$L/.claude-dash/global"; NUDGE="$L/conf/global/hub-nudge"; CHECKS=0
    "leg_$1"; echo "$CHECKS" > "$L/checks" ) > "$WORK/lane-$1.log" 2>&1 &
  eval "lane_pid_$1=\$!"
}

leg_A() {
# --- A: kept across a loop's rounds -----------------------------------------------
: > "$NUDGE"; age "$NUDGE" 60
rm -f "$READS"
FLEET_HUB_SESSIONS_LOOP_SECS=5 bash "$HUBS" --loop >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" = 1 ] || st_fail "A: a loop of ~5 rounds with no nudge read the inventory $n times, want 1"
CHECKS=$((CHECKS+1)); grep -q "^$S	@7	42	" "$G/hubsess.inv.$S" 2>/dev/null \
  || st_fail "A: the kept inventory does not hold the window row" "$(cat "$G/hubsess.inv.$S" 2>/dev/null)"

}

leg_B() {
# --- B: a nudge mid-loop is read at the next round --------------------------------
: > "$NUDGE"; age "$NUDGE" 60   # as A left it: a nudge older than the loop
rm -f "$READS" "$G/hubsess.inv.$S"
( sleep 2.5; : > "$NUDGE" ) &
FLEET_HUB_SESSIONS_LOOP_SECS=5 bash "$HUBS" --loop >/dev/null 2>&1
wait
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" -ge 2 ] && [ "$n" -le 3 ] || st_fail "B: a nudge mid-loop — the inventory was read $n times, want 2 (once at the start, once after the nudge)"

}

# --- C: a one-shot --refresh never reuses ------------------------------------------
leg_C() {
: > "$NUDGE"; age "$NUDGE" 60
rm -f "$READS"
bash "$HUBS" --refresh >/dev/null 2>&1; bash "$HUBS" --refresh >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" = 2 ] || st_fail "C: two bare --refresh read the inventory $n times, want 2"

}

leg_D() {
# --- D: no nudge file — every round reads -----------------------------------------
rm -f "$NUDGE" "$READS" "$G/hubsess.inv.$S"
FLEET_HUB_SESSIONS_LOOP_SECS=4 bash "$HUBS" --loop >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" -ge 3 ] || st_fail "D: no hub-nudge file — the inventory was read $n times in ~4 rounds, want every round"
CHECKS=$((CHECKS+1)); [ ! -e "$G/hubsess.inv.$S" ] || st_fail "D: no hub-nudge file, yet an inventory was kept"

}

leg_E() {
# --- E: TTL 0 — every round reads --------------------------------------------------
: > "$NUDGE"; age "$NUDGE" 60
rm -f "$READS"
FLEET_HUB_SESSIONS_INV_TTL=0 FLEET_HUB_SESSIONS_LOOP_SECS=4 bash "$HUBS" --loop >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" -ge 3 ] || st_fail "E: FLEET_HUB_SESSIONS_INV_TTL=0 — the inventory was read $n times in ~4 rounds, want every round"

}

lane A; lane B; lane D; lane E
leg_C
rc=0
for l in A B D E; do
  eval "wait \$lane_pid_$l" || rc=1
  cat "$WORK/lane-$l.log"
  [ -s "$WORK/lane-$l/checks" ] && CHECKS=$((CHECKS + $(cat "$WORK/lane-$l/checks")))
done
[ "$rc" = 0 ] || exit 1

echo "hub-sessions-inv selftest: PASS ($CHECKS checks)"
