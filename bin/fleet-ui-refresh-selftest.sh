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
#   1. --all --dash respawns the @dash=1 pane on BOTH fleets (each server's marker
#      script runs), and NEVER a non-dash pane.
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
SUT="$BIN/fleet-ui-refresh.sh"
[ -f "$SUT" ] || { printf 'selftest: missing %s\n' "$SUT" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

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

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- two fleets, each its own server on its own socket ------------------------
# The session's first window runs a long-lived sleep so the server survives a
# headless CI (a default-shell window with no tty exits instantly, taking the
# session down). Each fleet gets a @dash=1 pane AND a plain (non-dash) pane, so we
# can prove the refresh hits ONLY the dash pane.
for f in fleetA fleetB; do
  tmux -L "$f" new-session -d -s "$f" -x 200 -y 50 'sleep 300' 2>/dev/null \
    || fail "could not start isolated tmux server for $f"
  # a @dash=1 pane (its own window running sleep so it survives until respawn)
  dwin=$(tmux -L "$f" new-window -d -P -F '#{pane_id}' -t "$f:" -n dashwin 'sleep 300')
  tmux -L "$f" set-option -p -t "$dwin" @dash 1 2>/dev/null
  # a plain pane with NO @dash marker — must never be respawned
  tmux -L "$f" new-window -d -t "$f:" -n plain 'sleep 300' >/dev/null
done

# --- 1. --all --dash respawns ONLY the @dash pane, on BOTH fleets -------------
# The launcher is overridden to a marker script that stamps <label> so we can prove
# each server's dash pane actually re-ran it. It writes then sleeps so respawn-pane
# has a live command (a pane whose command exits immediately can close the window).
LAUNCH="$WORK/launch.sh"
cat > "$LAUNCH" <<EOF
#!/bin/sh
# \$TMUX gives the running server's socket path; its basename is the -L label.
# (Escaped so THIS heredoc — written under the selftest's own set -u — doesn't try
# to expand \$TMUX, which is unset when the selftest runs outside tmux, e.g. in CI.)
label=\$(basename "\$(printf '%s' "\$TMUX" | cut -d, -f1)")
printf 'respawned\n' >> "$WORK/dash.\$label"
exec sleep 300
EOF
chmod +x "$LAUNCH"

out=$(FLEET_DASH_LAUNCHER="$LAUNCH" bash "$SUT" --all --dash 2>&1) \
  || fail "--all --dash exited non-zero: $out"

# DETERMINISTIC core assertion (the #248 fan-out): the helper reports respawning
# the @dash pane on BOTH fleets — 2 total, one per fleet, never the plain pane.
# This is read from the helper's OWN stdout, so it never races on pane execution.
printf '%s\n' "$out" | grep -q 'dash panes: 2' \
  || fail "summary should report 2 dash panes total — got: $out"
printf '%s\n' "$out" | grep -q '\[fleetA\] dash: 1 pane' \
  || fail "fleetA should report exactly 1 dash pane respawned — got: $out"
printf '%s\n' "$out" | grep -q '\[fleetB\] dash: 1 pane' \
  || fail "fleetB should report exactly 1 dash pane respawned — got: $out"

# END-TO-END confirmation: each server's respawned pane actually RAN the launcher
# (proving respawn-pane executed `bash <launcher>` on the right socket). The pane's
# bash is scheduled asynchronously, so poll with a REAL sleep up to ~15s — a fake
# no-sleep spin raced on a loaded CI runner and flaked (marker not yet written).
for _ in $(seq 1 50); do
  [ -f "$WORK/dash.fleetA" ] && [ -f "$WORK/dash.fleetB" ] && break
  sleep 0.3
done
[ -f "$WORK/dash.fleetA" ] || fail "fleetA dash pane never ran the launcher (marker missing after 15s)
out: $out"
[ -f "$WORK/dash.fleetB" ] || fail "fleetB dash pane never ran the launcher (marker missing after 15s)
out: $out"
# exactly one respawn per fleet (only the @dash pane, never the plain one)
[ "$(grep -c respawned "$WORK/dash.fleetA")" = 1 ] \
  || fail "fleetA: expected exactly 1 dash respawn (a non-dash pane was hit?)"
[ "$(grep -c respawned "$WORK/dash.fleetB")" = 1 ] \
  || fail "fleetB: expected exactly 1 dash respawn (a non-dash pane was hit?)"

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
    || fail "$f: precondition — bind Q should be present before reload"
done

out=$(bash "$SUT" --all --conf "$before" "$after" "$tmconf" 2>&1) \
  || fail "--all --conf exited non-zero: $out"
for f in fleetA fleetB; do
  tmux -L "$f" list-keys -T prefix 2>/dev/null | grep -q ' Q ' \
    && fail "$f: bind Q should have been unbound by the conf fan-out (issue #248)
out: $out"
done
printf '%s\n' "$out" | grep -q 'conf reloaded: 2' \
  || fail "summary should report conf reloaded on 2 fleets — got: $out"

# --- 3. --dry-run names both fleets and touches nothing ----------------------
# Re-bind Q on both, then dry-run: it must NOT unbind (Q survives) but must still
# name both fleets in its output.
for f in fleetA fleetB; do tmux -L "$f" bind-key Q display-message "hi" 2>/dev/null; done
out=$(bash "$SUT" --all --conf "$before" "$after" "$tmconf" --dry-run 2>&1) \
  || fail "--dry-run exited non-zero: $out"
for f in fleetA fleetB; do
  tmux -L "$f" list-keys -T prefix 2>/dev/null | grep -q ' Q ' \
    || fail "$f: --dry-run must NOT unbind Q"
  printf '%s\n' "$out" | grep -q "\[$f\]" || fail "--dry-run should name $f — got: $out"
done
printf '%s\n' "$out" | grep -q '(dry-run)' || fail "--dry-run summary should be tagged — got: $out"

# --- 4. usage errors exit non-zero -------------------------------------------
bash "$SUT" --dash >/dev/null 2>&1 && fail "missing --all should be a usage error"
bash "$SUT" --all  >/dev/null 2>&1 && fail "no --dash/--conf should be a usage error"

printf 'selftest PASS: fleet-ui-refresh --all fans dash respawn + conf reload over every live fleet (issue #248)\n'
exit 0
