#!/bin/bash
# pool-not-a-fleet-selftest.sh — the warm pool's holding session is not a fleet
# (issue #1020).
#
# The pool parks pre-warmed scratch windows in `<sess>-pool` (fleet_pool_session)
# on the fleet's OWN socket, so every per-socket reader meets it beside the real
# fleet. Before #1020 two of them took it for one:
#   • fleet-restore.sh --snapshot minted fleets/<sess>-pool/restore.map (plus a
#     pile of leaked .restore.<pid>.map temps); --if-down then probed a socket
#     labelled <sess>-pool that never exists, so a fleet read as DOWN forever and
#     restore() would fleet-up a fake one.
#   • fleet-list.sh printed `○ <sess>-pool` off the collector's sessmap row.
#
# Legs (a REAL isolated tmux server via the -S PATH-shim — never the live one):
#   PREDICATE  fleet_is_pool_session: exact with a socket; conf-aware without one
#              (a real fleet that merely ends in -pool keeps its conf → not a pool)
#   SNAPSHOT   fx + fx-pool live → fleets/fx/restore.map, and NO fleets/fx-pool/
#   SWEEP      a pre-#1020 pool dir loses its map + temps and the dir itself; an
#              orphaned temp in a real fleet dir goes, a fresh one (a live
#              snapshot's) stays
#   READERS    a stale pool map on disk is invisible to --dry-run (each_restore_map)
#   LIST       fleet-list.sh shows fx, never fx-pool
#
# tmux absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 absent — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-fleet-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp"
mkdir -p "$WORK/bin" "$FLEET_CONF_DIR" "$TMPDIR" "$WORK/main"

SOCK="$WORK/tmux.sock"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$FLEET_CONF_DIR/fleets/fx"
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=main\n' "$WORK/main" \
  > "$FLEET_CONF_DIR/fleets/fx/conf"

# ========================================================== 1. PREDICATE ======
pred() { ( . "$BIN/fleet-lib.sh"; fleet_is_pool_session "$@" ); }
pred fx-pool fx        || fail "predicate: fx-pool on socket fx must be its pool"
pred fx fx             && fail "predicate: the fleet itself is not its pool"
pred other-pool fx     && fail "predicate: another fleet's pool is not THIS socket's pool"
pred fx-pool           || fail "predicate: fx-pool (no conf of its own) must read as a pool"
pred fx                && fail "predicate: fx (no -pool suffix) must not read as a pool"
pred -pool             && fail "predicate: a bare '-pool' has no owner"
mkdir -p "$FLEET_CONF_DIR/fleets/bar-pool"
printf 'FLEET_REPO=acme/bar-pool\n' > "$FLEET_CONF_DIR/fleets/bar-pool/conf"
pred bar-pool          && fail "predicate: a REAL fleet named bar-pool (own conf) must not read as a pool"
rm -rf "$FLEET_CONF_DIR/fleets/bar-pool"

# ========================================================== 2. SNAPSHOT =======
tmux new-session -d -s fx -x 200 -y 50 -c "$WORK/main" 2>/dev/null \
  || fail "could not start isolated tmux server"
tmux rename-window -t fx issue-1
tmux set-window-option -t fx:issue-1 @issue 1
tmux new-session -d -s fx-pool -c "$WORK/main" 2>/dev/null || fail "could not start fx-pool"

# pre-#1020 litter: a pool dir with a map + a leaked temp, and two temps in fx's dir
P="$FLEET_CONF_DIR/fleets/fx-pool"; mkdir -p "$P"
printf 'FLEET\tfx-pool\tacme/widgets\t%s\tmain\n' "$WORK/main" > "$P/restore.map"
: > "$P/.restore.111.map"
: > "$FLEET_CONF_DIR/fleets/fx/.restore.222.map"
touch -t 202001010000 "$FLEET_CONF_DIR/fleets/fx/.restore.222.map"
: > "$FLEET_CONF_DIR/fleets/fx/.restore.333.map"            # fresh: a live snapshot's

# READERS first: while the stale pool map is still on disk, restore must not see it.
out=$(bash "$BIN/fleet-restore.sh" --dry-run 2>&1)
printf '%s\n' "$out" | grep -q 'fx-pool' \
  && fail "readers: --dry-run must not treat the stale fx-pool map as a fleet (got: $out)"

bash "$BIN/fleet-restore.sh" --snapshot 2>/dev/null || fail "--snapshot exited non-zero"
[ -f "$FLEET_CONF_DIR/fleets/fx/restore.map" ] || fail "snapshot: fx must still get its map"
awk -F'\t' '$1=="FLEET"{print $2}' "$FLEET_CONF_DIR/fleets/fx/restore.map" | grep -qx fx \
  || fail "snapshot: fx's map must name fx"
[ -e "$P" ] && fail "snapshot/sweep: fleets/fx-pool/ must not exist after a snapshot (has: $(ls -A "$P"))"

# ========================================================== 3. SWEEP ==========
[ -e "$FLEET_CONF_DIR/fleets/fx/.restore.222.map" ] \
  && fail "sweep: an orphaned (old) temp map in a fleet dir must be removed"
[ -e "$FLEET_CONF_DIR/fleets/fx/.restore.333.map" ] \
  || fail "sweep: a fresh temp map (a live snapshot's) must be left alone"
# rmdir, never rm -r: an unexpected file in a pool dir survives
mkdir -p "$P"; : > "$P/keep-me"; : > "$P/restore.map"
bash "$BIN/fleet-restore.sh" --snapshot 2>/dev/null
[ -f "$P/keep-me" ] || fail "sweep: must never delete a pool dir's unknown files"
[ -e "$P/restore.map" ] && fail "sweep: the pool's restore.map must be removed"
rm -rf "$P"

# ========================================================== 4. LIST ===========
mkdir -p "$TMPDIR/.claude-dash/global"
printf 'fx\tacme-widgets\tacme/widgets\nfx-pool\tacme-widgets\tacme/widgets\n' \
  > "$TMPDIR/.claude-dash/global/sessmap"
out=$(bash "$BIN/fleet-list.sh" 2>&1)
printf '%s\n' "$out" | grep -q ' fx ' || fail "list: fx must be listed (got: $out)"
printf '%s\n' "$out" | grep -q 'fx-pool' && fail "list: fx-pool must not be listed (got: $out)"

printf 'pool-not-a-fleet selftest: PASS\n'
