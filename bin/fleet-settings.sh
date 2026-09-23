#!/bin/bash
# fleet-settings.sh — the login's ONE settings file (issue #979).
#
#   fleet-settings.sh path              print it ($FLEET_CONF_DIR/fleet.settings)
#   fleet-settings.sh merge [--dry-run] fold the two old files into it
#
# A login runs one fleet, so its settings were split for no reason: the machine-
# wide keys in the install's fleet.conf (<install>/fleet.conf) and the fleet's in
# $FLEET_CONF_DIR/fleets/<sess>/conf. `merge` writes both into fleet.settings —
# the install file first, the fleet's keys after it so they still win where both
# set a key — then trims the fleet conf to its identity (FLEET_REPO / FLEET_MAIN /
# FLEET_BASE_BRANCH, which fleet-up.sh owns) and moves the install file aside to
# fleet.conf.pre-merge. Every value resolves exactly as before:
#
#   install fleet.conf  <  fleet.settings  <  fleets/<sess>/conf (global-only keys stripped)
#
# is the read order (fleet-lib.sh), and each old file stays a dual-read fallback, so
# a login that never merges loads byte for byte as it always has. A global-only key
# ($_FLEET_GLOBAL_ONLY) found in the fleet conf is DROPPED, not carried: the fleet
# conf's copy was never read (fleet_load_conf strips it, #237), and carrying it
# into fleet.settings would suddenly make it win. The merge says which it dropped.
#
# Refuses with no fleet, with more than one (fold them first: fleet-repo.sh fold),
# or when fleet.settings already exists. Exit 0 ok, 1 refused/failed, 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"

die()   { echo "fleet-settings: $*" >&2; exit 1; }
usage() { sed -n '4,5p' "$0" | sed 's/^# //' >&2; exit 2; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "fleet-settings: unknown argument $1" >&2; usage ;;
  esac
done

S=$(fleet_settings_file)
case "$cmd" in
  path) printf '%s\n' "$S"; exit 0 ;;
  merge) ;;
  *) usage ;;
esac

[ -f "$S" ] && die "already merged: $S"
sess=$(fleet_login_fleet); rc=$?
case "$rc" in
  0) ;;
  1) die "no fleet is configured for this login — nothing to merge" ;;
  *) die "this login has several fleets ($(fleet_each_conf | cut -f1 | tr '\n' ' ')) — fold them into one first (fleet-repo.sh fold)" ;;
esac
CONF=$(fleet_conf_file "$sess")
INST="$BIN/../fleet.conf"
[ -f "$INST" ] || INST=""

identity='^[[:space:]]*(export[[:space:]]+)?FLEET_(REPO|MAIN|BASE_BRANCH)='
ourhdr='^# (claude-fleet: fleet .* written by fleet-up\.sh|Overlays the global fleet\.conf|FLEET_\* keys \(see fleet\.conf\.example\))'
globals="^[[:space:]]*(export[[:space:]]+)?(${_FLEET_GLOBAL_ONLY// /|})="
dropped=$(grep -E "$globals" "$CONF" 2>/dev/null | sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Z0-9_]+)=.*/\2/' | tr '\n' ' ')

tmp="$S.tmp.$$"
{
  printf "# claude-fleet: this login's settings — merged by fleet-settings.sh %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '# ONE file for the machine-wide keys and the fleet'\''s (issue #979). Assignments only.\n'
  if [ -n "$INST" ]; then
    printf '\n# ---- was %s (machine-wide) ----\n' "$INST"
    cat "$INST"
  fi
  printf '\n# ---- was %s (fleet %s) ----\n' "$CONF" "$sess"
  grep -Ev "$identity" "$CONF" | grep -Ev "$ourhdr" | grep -Ev "$globals"
  if [ -n "$dropped" ]; then
    printf '# dropped from the fleet conf (global-only, its copy there was never read): %s\n' "${dropped% }"
  fi
} > "$tmp" || { rm -f "$tmp"; die "failed to build $S"; }

if [ "$DRY" = 1 ]; then
  printf 'fleet-settings: would write %s:\n' "$S"
  sed 's/^/  | /' "$tmp"
  printf 'fleet-settings: would trim %s to FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH\n' "$CONF"
  [ -n "$INST" ] && printf 'fleet-settings: would move %s → %s.pre-merge\n' "$INST" "$INST"
  rm -f "$tmp"; exit 0
fi

repo=$( . "$CONF" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
main=$( . "$CONF" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
base=$( . "$CONF" >/dev/null 2>&1; printf '%s' "${FLEET_BASE_BRANCH:-}" )
# The fleet conf is rewritten from a FRESH path (fleet_write_conf preserves every
# other line of an existing file) and swapped in; the settings file lands first,
# so an interruption leaves at worst a duplicate key with the same value, never a
# lost one.
mv -f "$tmp" "$S" || { rm -f "$tmp"; die "failed to write $S"; }
cp -p "$CONF" "$CONF.pre-merge" 2>/dev/null
fleet_write_conf "$CONF.new.$$" "$sess" "$repo" "$main" "$base" "$(date '+%Y-%m-%d %H:%M:%S')" \
  && mv -f "$CONF.new.$$" "$CONF" || { rm -f "$CONF.new.$$"; die "wrote $S but could not trim $CONF"; }
if [ -n "$INST" ]; then
  mv -f "$INST" "$INST.pre-merge" || die "wrote $S but could not move $INST aside"
fi
echo "fleet-settings: merged into $S (fleet $sess)"
[ -n "$dropped" ] && echo "fleet-settings: dropped global-only keys the fleet conf never applied: ${dropped% }"
echo "fleet-settings: the old files are kept as *.pre-merge"
exit 0
