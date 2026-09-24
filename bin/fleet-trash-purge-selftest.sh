#!/bin/bash
# fleet-trash-purge-selftest.sh — the SLOW trash purge (issue #893):
# fleet_trash_sweep in bin/fleet-lib.sh under FLEET_TRASH_PURGE_PER_TICK.
#
#   DEFAULT    unset ⇒ today's behaviour: one sweep empties the whole trash, at the
#              caller's own priority (`nice -n 0`).
#   CAPPED     PER_TICK=1 and 3 entries ⇒ 3 sweeps empty it, one entry each, every
#              delete at `nice -n 19`; the trash's .gitignore survives.
#   DEFERRED   load/core over FLEET_TRASH_PURGE_MAX_LOAD (default 1) ⇒ the sweep
#              deletes NOTHING and says `deferred:load <x>/core` with the count left.
#   KNOBS      MAX_LOAD=0 never defers; a higher ceiling lets the same load through;
#              an unreadable load does not defer.
#   URGENT     FLEET_TRASH_PURGE_URGENT=1 (a closed disk gate) drops cap AND load
#              check — the trash is what frees a full disk.
#   EMPTY      an empty trash under load reports `swept:0 left:0`, not a deferral.
#
# The load is a PATH shim for `sysctl` (tried first on macOS AND Linux by the lib);
# `nice` is a PATH shim that records its argv and runs the rest. No git, no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s missing\n' "$LIB" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-trash-purge.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# --- shims ----------------------------------------------------------------------
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/sysctl" <<SH
#!/bin/sh
case "\$*" in
  *hw.ncpu*)    echo 4 ;;
  *vm.loadavg*) [ -f "$WORK/noload" ] && { echo '{ }'; exit 0; }   # succeed, empty — no /proc fallback
                echo "{ \$(cat "$WORK/load") 0.00 0.00 }" ;;
  *)            exit 1 ;;
esac
SH
cat > "$SHIM/nice" <<SH
#!/bin/sh
printf '%s\n' "\$2" >> "$WORK/nice.log"
shift 2
exec "\$@"
SH
chmod +x "$SHIM/sysctl" "$SHIM/nice"
export PATH="$SHIM:$PATH"
unset FLEET_WORKTREE_ROOT FLEET_TRASH_PURGE_PER_TICK FLEET_TRASH_PURGE_MAX_LOAD FLEET_TRASH_PURGE_URGENT

# shellcheck source=/dev/null
. "$LIB"

MAIN="$WORK/repo"; mkdir -p "$MAIN"
TRASH="$WORK/.fleet-trash"
fill() {   # three trashed worktrees, each with a few files, plus the .gitignore
  rm -rf "$TRASH"; mkdir -p "$TRASH"; printf '*\n' > "$TRASH/.gitignore"
  local i; for i in 1 2 3; do
    mkdir -p "$TRASH/repo-issue-$i.1700000000.$i/node_modules/x"
    echo b > "$TRASH/repo-issue-$i.1700000000.$i/node_modules/x/f"
  done
  : > "$WORK/nice.log"
}
count() { find "$TRASH" -mindepth 1 -maxdepth 1 ! -name .gitignore | wc -l | tr -d ' '; }
load() { echo "$1" > "$WORK/load"; rm -f "$WORK/noload"; }

# --- DEFAULT: unset ⇒ one sweep empties it, at nice 0 --------------------------
load 8.00; fill
sw="$(fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:3 left:0" ] || fail "DEFAULT should sweep all 3 in one call" "$sw"
[ "$(count)" = 0 ] || fail "DEFAULT left entries behind"
grep -qvx 0 "$WORK/nice.log" && fail "DEFAULT must not lower priority" "$(cat "$WORK/nice.log")"
ok "DEFAULT unset key sweeps everything in one call, even under load (today's behaviour)"

# --- CAPPED: 3 entries → 3 ticks -----------------------------------------------
load 0.40; fill
export FLEET_TRASH_PURGE_PER_TICK=1
for want in "swept:1 left:2" "swept:1 left:1" "swept:1 left:0"; do
  sw="$(fleet_trash_sweep "$MAIN" 30)"
  [ "$sw" = "$want" ] || fail "CAPPED expected [$want]" "$sw"
done
[ "$(count)" = 0 ] || fail "CAPPED: 3 ticks should have emptied the trash"
[ -f "$TRASH/.gitignore" ] || fail "CAPPED swept the trash's own .gitignore"
[ "$(sort -u "$WORK/nice.log")" = 19 ] || fail "CAPPED deletes must run at nice 19" "$(cat "$WORK/nice.log")"
[ "$(wc -l < "$WORK/nice.log" | tr -d ' ')" = 3 ] || fail "CAPPED: one nice'd rm per entry" "$(cat "$WORK/nice.log")"
ok "CAPPED PER_TICK=1: 3 entries empty in 3 sweeps, each rm at nice -n 19"

FLEET_TRASH_PURGE_PER_TICK=2; fill
sw="$(fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:2 left:1" ] || fail "CAPPED PER_TICK=2 should take 2" "$sw"
FLEET_TRASH_PURGE_PER_TICK=1
ok "CAPPED PER_TICK=2 takes two per sweep"

# --- DEFERRED: load/core over the default ceiling of 1 --------------------------
load 8.00; fill      # 8 / 4 cores = 2.00/core
sw="$(fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:0 left:3 deferred:load 2.00/core" ] || fail "DEFERRED output" "$sw"
[ "$(count)" = 3 ] || fail "DEFERRED must delete nothing"
[ -s "$WORK/nice.log" ] && fail "DEFERRED must not even start an rm"
load 4.00            # exactly 1.00/core is NOT over the line
sw="$(fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:1 left:2" ] || fail "load == ceiling must not defer" "$sw"
ok "DEFERRED over 1/core the sweep skips the tick; at exactly 1/core it runs"

# --- KNOBS -----------------------------------------------------------------------
load 8.00; fill
sw="$(FLEET_TRASH_PURGE_MAX_LOAD=0 fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:1 left:2" ] || fail "MAX_LOAD=0 must never defer" "$sw"
sw="$(FLEET_TRASH_PURGE_MAX_LOAD=2.5 fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:1 left:1" ] || fail "MAX_LOAD=2.5 lets 2.00/core through" "$sw"
sw="$(FLEET_TRASH_PURGE_MAX_LOAD=junk fleet_trash_sweep "$MAIN" 30)"
case "$sw" in *deferred:load*) ;; *) fail "a junk MAX_LOAD falls back to 1 (defer at 2.00/core)" "$sw" ;; esac
touch "$WORK/noload"
sw="$(fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:1 left:0" ] || fail "an unreadable load must not defer" "$sw"
ok "KNOBS MAX_LOAD=0 off, a higher ceiling passes, junk → 1, unreadable load → no defer"

# --- URGENT: a closed disk gate drops cap + load check ---------------------------
load 8.00; fill
sw="$(FLEET_TRASH_PURGE_URGENT=1 fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:3 left:0" ] || fail "URGENT must sweep everything despite cap + load" "$sw"
ok "URGENT FLEET_TRASH_PURGE_URGENT=1 empties the trash under load, uncapped"

# --- EMPTY ---------------------------------------------------------------------
load 8.00; fill; rm -rf "$TRASH"/repo-*
sw="$(fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:0 left:0" ] || fail "EMPTY trash must report swept:0 left:0 (the callers' quiet line)" "$sw"
ok "EMPTY an empty trash under load stays the quiet swept:0 left:0"

printf 'fleet-trash-purge-selftest: %s checks passed\n' "$pass"
