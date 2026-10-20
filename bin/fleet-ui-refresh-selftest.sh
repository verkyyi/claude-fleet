#!/bin/bash
# fleet-ui-refresh-selftest.sh — guard for fleet-ui-refresh.sh --all (issue #248).
#
# The bug it prevents: /fleet-sync-install's UI-refresh steps (respawn @dash panes,
# unbind-aware conf reload) only touched the CURRENT fleet's tmux server, so after a
# sync that changed the dash launcher or conf/tmux-attention.conf, every OTHER live
# fleet kept a stale dash pane + stale server binds until respawned by hand. The fix
# is fleet-ui-refresh.sh --all, which fans BOTH refreshes out over fleet_sockets,
# running each per-server against its own `-L <label>`.
#
# This drives the REAL bin/fleet-ui-refresh.sh against TWO real, isolated tmux
# servers (their own `-L` sockets under a private TMUX_TMPDIR, torn down at exit —
# never the user's live server) and asserts:
#
#   1. --dash (the dash's pane respawn, gone with issue #4902) is accepted and does
#      nothing: no pane is respawned.
#   2. --all --conf <before> <after> unbinds a REMOVED bind on BOTH servers (the
#      real tmux-conf-reload.sh --socket path), proving the conf fan-out is real.
#   3. --dry-run touches nothing (the removed bind survives on both servers) yet
#      still names both fleets.
#   4. A usage error (no --all, or nothing to do) exits non-zero.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SUT="$BIN/fleet-ui-refresh.sh"
[ -f "$SUT" ] || { printf 'selftest: missing %s\n' "$SUT" >&2; exit 2; }
st_real_tmux

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ui-refresh-selftest.XXXXXX")" || exit 2

# Isolate EVERY `tmux -L <label>` onto sockets under WORK, so we never touch the
# user's live servers: TMUX_TMPDIR is where tmux puts its `-L`-named sockets.
export TMUX_TMPDIR="$WORK"
# fleet_sockets enumerates configured fleets from FLEET_CONF_DIR — scope it to WORK.
export FLEET_CONF_DIR="$WORK/config"
mkdir -p "$FLEET_CONF_DIR/fleets/fleetA" "$FLEET_CONF_DIR/fleets/fleetB"
: > "$FLEET_CONF_DIR/fleets/fleetA/conf"
: > "$FLEET_CONF_DIR/fleets/fleetB/conf"

cleanup() {
  tmux -L fleetA kill-server 2>/dev/null
  tmux -L fleetB kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does NOT fire on a signal — turn INT/TERM/HUP into a normal exit
# so cleanup reaps the isolated servers instead of leaking them (issue #152).
trap 'exit 130' INT TERM HUP


# --- two fleets, each its own server on its own socket ------------------------
# The session's first window runs a long-lived sleep so the server survives a
# headless CI (a default-shell window with no tty exits instantly, taking the
# session down). Each fleet gets a @dash=1 pane AND a plain (non-dash) pane, so we
# can prove the refresh hits ONLY the dash pane.
for f in fleetA fleetB; do
  tmux -L "$f" new-session -d -s "$f" -x 200 -y 50 'sleep 300' 2>/dev/null \
    || st_fail "could not start isolated tmux server for $f"
  # a @dash=1 pane (its own window running sleep so it survives until respawn)
  dwin=$(tmux -L "$f" new-window -d -P -F '#{pane_id}' -t "$f:" -n dashwin 'sleep 300')
  tmux -L "$f" set-option -p -t "$dwin" @dash 1 2>/dev/null
  # a plain pane with NO @dash marker — must never be respawned
  tmux -L "$f" new-window -d -t "$f:" -n plain 'sleep 300' >/dev/null
done

# --- 1. --dash is an older caller's flag: a no-op, it respawns nothing ---------
# (the dash went with issue #4902 — fleet-ui-refresh.sh still accepts it)
dpane=$(tmux -L fleetA list-panes -s -t fleetA -F '#{pane_id} #{@dash}' | awk '$2==1{print $1; exit}')
dpid=$(tmux -L fleetA display-message -p -t "$dpane" '#{pane_pid}')
bash "$SUT" --all --dash >/dev/null 2>&1 && st_fail "--dash alone (nothing to do) should be a usage error"
[ "$(tmux -L fleetA display-message -p -t "$dpane" '#{pane_pid}')" = "$dpid" ] || st_fail "--dash respawned a pane"

# --- 2. --all --conf unbinds a REMOVED bind on BOTH servers -------------------
# Bind a key on each server, then hand the helper a before/after conf pair where the
# key is REMOVED. The real tmux-conf-reload.sh --socket <label> must unbind it on
# each. (source-file targets a throwaway empty conf so re-sourcing is a clean no-op.)
before="$WORK/before.conf"; after="$WORK/after.conf"; tmconf="$WORK/tmux.conf"
printf 'bind Q display-message "gone soon"\n' > "$before"
: > "$after"          # Q removed
: > "$tmconf"         # nothing to (re)source
for f in fleetA fleetB; do
  tmux -L "$f" bind-key Q display-message "hi" 2>/dev/null
  tmux -L "$f" list-keys -T prefix 2>/dev/null | grep -q ' Q ' \
    || st_fail "$f: precondition — bind Q should be present before reload"
done

out=$(bash "$SUT" --all --dash --conf "$before" "$after" "$tmconf" 2>&1) \
  || st_fail "--all --dash --conf exited non-zero: $out"
[ "$(tmux -L fleetA display-message -p -t "$dpane" '#{pane_pid}')" = "$dpid" ] || st_fail "--dash --conf respawned a pane"
for f in fleetA fleetB; do
  tmux -L "$f" list-keys -T prefix 2>/dev/null | grep -q ' Q ' \
    && st_fail "$f: bind Q should have been unbound by the conf fan-out (issue #248)
out: $out"
done
printf '%s\n' "$out" | grep -q 'conf reloaded: 2' \
  || st_fail "summary should report conf reloaded on 2 fleets — got: $out"

# --- 3. --dry-run names both fleets and touches nothing ----------------------
# Re-bind Q on both, then dry-run: it must NOT unbind (Q survives) but must still
# name both fleets in its output.
for f in fleetA fleetB; do tmux -L "$f" bind-key Q display-message "hi" 2>/dev/null; done
out=$(bash "$SUT" --all --conf "$before" "$after" "$tmconf" --dry-run 2>&1) \
  || st_fail "--dry-run exited non-zero: $out"
for f in fleetA fleetB; do
  tmux -L "$f" list-keys -T prefix 2>/dev/null | grep -q ' Q ' \
    || st_fail "$f: --dry-run must NOT unbind Q"
  printf '%s\n' "$out" | grep -q "\[$f\]" || st_fail "--dry-run should name $f — got: $out"
done
printf '%s\n' "$out" | grep -q '(dry-run)' || st_fail "--dry-run summary should be tagged — got: $out"

# --- 4. usage errors exit non-zero -------------------------------------------
bash "$SUT" --dash >/dev/null 2>&1 && st_fail "missing --all should be a usage error"
bash "$SUT" --all  >/dev/null 2>&1 && st_fail "no --conf should be a usage error"

printf 'selftest PASS: fleet-ui-refresh --all fans the conf reload over every live fleet (issue #248); --dash is a no-op\n'
exit 0
