#!/bin/bash
# fleet-epic-floor-selftest.sh — bin/fleet-epic-floor.sh (issue #2934): a batch
# records the version each member started on, and says how many it spanned.
#
#   A. record reads the live install: a link into fleet.versions/<sha> (a
#      `-linked` suffix dropped), a plain checkout's HEAD;
#   B. show: `versions: K` + one line per version in first-seen order with its
#      members, a member recorded twice listed once; per (repo, epic) file;
#   C. nothing recorded → `versions: 0`; bad arguments → exit 2, nothing written.
# Hermetic: a sandbox FLEET_CONF_DIR and FLEET_LIVE_DIR. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
F="$BIN/fleet-epic-floor.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/epic-floor-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
N=0 BAD=0
ok() { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL: %s\n' "$1" >&2; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 — wanted «$3» in:
$2" ;; esac; }
eq() { [ "$2" = "$3" ] && ok || bad "$1 — wanted «$2», got «$3»"; }
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
export FLEET_CONF_DIR="$WORK/conf" FLEET_LIVE_DIR="$WORK/live"
mkdir -p "$WORK/v/$S1" "$WORK/v/$S2-linked" "$FLEET_CONF_DIR"
f() { OUT=$(bash "$F" "$@" 2>&1); RC=$?; }

# --- A. record --------------------------------------------------------------------
ln -s "$WORK/v/$S1" "$WORK/live"
f record 2934 '#12' --repo o/r; eq "A: record exits 0" 0 "$RC"; has "A: says the version" "$OUT" "recorded #12 on 1111111"
f record 2934 13 --repo o/r
ln -sfn "$WORK/v/$S2-linked" "$WORK/live"
f record 2934 14 --repo o/r; has "A: a -linked dir is its sha" "$OUT" "on 2222222"
f record 2934 12 --repo o/r
eq "A: one line per spawn" 4 "$(wc -l < "$FLEET_CONF_DIR/global/epic-floors/o-r-2934" | tr -d ' ')"
rm "$WORK/live"; mkdir -p "$WORK/live"
( cd "$WORK/live" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x ) || exit 2
H=$(git -C "$WORK/live" rev-parse HEAD)
f record 7 1 --repo o/r; has "A: a plain checkout is its HEAD" "$OUT" "on $(printf '%.7s' "$H")"

# --- B. show ----------------------------------------------------------------------
f show 2934 --repo o/r
eq "B: show exits 0" 0 "$RC"
eq "B: versions, members, first-seen order" "versions: 2
1111111  #12 #13
2222222  #14 #12" "$OUT"
f show 2934 --repo o/other; has "B: another repo's batch is its own" "$OUT" "versions: 0"

# --- C. nothing / usage -----------------------------------------------------------
f show 9 --repo o/r; has "C: nothing recorded" "$OUT" "versions: 0"
f record x 1; eq "C: a bad epic is usage" 2 "$RC"
f record 9 abc; eq "C: a bad member is usage" 2 "$RC"
f frob 9; eq "C: an unknown mode is usage" 2 "$RC"
[ -e "$FLEET_CONF_DIR/global/epic-floors/o-r-9" ] && bad "C: a usage error wrote" || ok

[ "$BAD" = 0 ] && { printf 'fleet-epic-floor-selftest: %d checks OK\n' "$N"; exit 0; }
printf 'fleet-epic-floor-selftest: %d of %d FAILED\n' "$BAD" "$N"; exit 1
