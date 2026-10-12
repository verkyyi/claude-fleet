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
command -v python3 >/dev/null 2>&1 || { echo 'hub-sessions-inv selftest: python3 absent — SKIP'; exit 0; }

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
READS="$WORK/reads"
cat > "$WORK/sbin/fleet-control-read.sh" <<EOF
#!/bin/bash
[ "\${1:-}" = workers ] && { echo x >> '$READS'; printf '@7\t42\t\t%s/wt\tworking\n' '$WORK'; }
exit 0
EOF
chmod +x "$WORK/sbin/fleet-control-read.sh"
HUBS="$WORK/sbin/fleet-hub-sessions.sh"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
reads() { [ -f "$READS" ] && grep -c . "$READS" || echo 0; }
age() { python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
NUDGE="$WORK/conf/global/hub-nudge"

# --- A: kept across a loop's rounds -----------------------------------------------
: > "$NUDGE"; age "$NUDGE" 60
rm -f "$READS"
FLEET_HUB_SESSIONS_LOOP_SECS=5 bash "$HUBS" --loop >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" = 1 ] || fail "A: a loop of ~5 rounds with no nudge read the inventory $n times, want 1"
CHECKS=$((CHECKS+1)); grep -q "^$S	@7	42	" "$G/hubsess.inv.$S" 2>/dev/null \
  || fail "A: the kept inventory does not hold the window row" "$(cat "$G/hubsess.inv.$S" 2>/dev/null)"

# --- B: a nudge mid-loop is read at the next round --------------------------------
rm -f "$READS" "$G/hubsess.inv.$S"
( sleep 2.5; : > "$NUDGE" ) &
FLEET_HUB_SESSIONS_LOOP_SECS=5 bash "$HUBS" --loop >/dev/null 2>&1
wait
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" -ge 2 ] && [ "$n" -le 3 ] || fail "B: a nudge mid-loop — the inventory was read $n times, want 2 (once at the start, once after the nudge)"

# --- C: a one-shot --refresh never reuses ------------------------------------------
age "$NUDGE" 60
rm -f "$READS"
bash "$HUBS" --refresh >/dev/null 2>&1; bash "$HUBS" --refresh >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" = 2 ] || fail "C: two bare --refresh read the inventory $n times, want 2"

# --- D: no nudge file — every round reads -----------------------------------------
rm -f "$NUDGE" "$READS" "$G/hubsess.inv.$S"
FLEET_HUB_SESSIONS_LOOP_SECS=4 bash "$HUBS" --loop >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" -ge 3 ] || fail "D: no hub-nudge file — the inventory was read $n times in ~4 rounds, want every round"
CHECKS=$((CHECKS+1)); [ ! -e "$G/hubsess.inv.$S" ] || fail "D: no hub-nudge file, yet an inventory was kept"

# --- E: TTL 0 — every round reads --------------------------------------------------
: > "$NUDGE"; age "$NUDGE" 60
rm -f "$READS"
FLEET_HUB_SESSIONS_INV_TTL=0 FLEET_HUB_SESSIONS_LOOP_SECS=4 bash "$HUBS" --loop >/dev/null 2>&1
n=$(reads)
CHECKS=$((CHECKS+1)); [ "$n" -ge 3 ] || fail "E: FLEET_HUB_SESSIONS_INV_TTL=0 — the inventory was read $n times in ~4 rounds, want every round"

echo "hub-sessions-inv selftest: PASS ($CHECKS checks)"
