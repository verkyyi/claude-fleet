#!/bin/bash
# fleet-onboard-selftest.sh — the onboarding wizard's memory (issue #1168).
#
# /fleet-onboard (commands/fleet-onboard.md) resumes at the step it left from
# $FLEET_CONF_DIR/global/onboard.state, written by bin/fleet-onboard.sh. What
# this pins:
#
#   1. RESUME — no state ⇒ `resume: repo`; after `set step=watch` a fresh `brief`
#      says `resume: watch` and still carries repo=/issue= from earlier calls.
#   2. MERGE — `set` keeps every key it was not given, the last value of a key
#      wins, `updated=` is restamped, the file is 0600.
#   3. NO FORGED KEYS — a newline in a value is folded, so a value can never
#      write a second `step=` line.
#   4. STEP GUARD — an unknown step is refused (exit 2) and the file is untouched.
#   5. SEED TAG — FLEET_SEED=1 tags the fleet conf's OWN repo `[seed]`, never an
#      overlay repo; without FLEET_SEED nothing is tagged (a normal fleet).
#   6. THE SKILL MATCHES THE SCRIPT — every `set step=<x>` in the skill is a step
#      the script accepts, every fleet script it names exists in bin/, and it
#      carries the installer's marker line.
#
# Hermetic: a temp FLEET_CONF_DIR, --session + --no-gh (no tmux, no network).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
OB="$BIN/fleet-onboard.sh"
SKILL="$ROOT/commands/fleet-onboard.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-onboard.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR"

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

STATE="$FLEET_CONF_DIR/global/onboard.state"
SESS=onb-test
mkdir -p "$FLEET_CONF_DIR/fleets/$SESS/repos"
printf 'FLEET_REPO=verkyyi/claude-fleet\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$SESS/conf"
printf 'FLEET_REPO=victor/app\n' > "$FLEET_CONF_DIR/fleets/$SESS/repos/victor-app.conf"
brief() { bash "$OB" brief --session "$SESS" --no-gh 2>&1; }

# --- 1. resume from nothing --------------------------------------------------
out=$(brief) || fail "brief failed on a fresh fleet" "$out"
printf '%s\n' "$out" | grep -qx 'resume: repo' || fail "fresh start must resume at repo" "$out"
[ "$(bash "$OB" path)" = "$STATE" ] || fail "path is not \$FLEET_CONF_DIR/global/onboard.state"
ok "fresh fleet: resume at repo, state under global/"

# --- 5. seed tag (FLEET_SEED absent ⇒ no tag) --------------------------------
printf '%s\n' "$out" | grep -q '\[seed\]' && fail "no FLEET_SEED, yet a repo was tagged [seed]" "$out"
printf 'FLEET_SEED=1\n' >> "$FLEET_CONF_DIR/fleets/$SESS/conf"
out=$(brief)
printf '%s\n' "$out" | grep -q '^  verkyyi/claude-fleet  \[seed\]' || fail "the conf's own repo is not tagged [seed]" "$out"
printf '%s\n' "$out" | grep -q '^  victor/app *$' || fail "an overlay repo must never be the seed" "$out"
ok "FLEET_SEED=1 tags only the conf's own repo"

# --- 2. merge ----------------------------------------------------------------
bash "$OB" set step=repo lang=zh || fail "set failed"
bash "$OB" set repo=victor/app step=issue || fail "second set failed"
bash "$OB" set issue=12 step=watch || fail "third set failed"
got=$(bash "$OB" get)
[ "$(bash "$OB" get lang)" = zh ]         || fail "lang lost across sets" "$got"
[ "$(bash "$OB" get repo)" = victor/app ] || fail "repo lost across sets" "$got"
[ "$(bash "$OB" get step)" = watch ]      || fail "last step did not win" "$got"
[ "$(grep -c '^step=' "$STATE")" = 1 ]    || fail "step written twice" "$got"
[ "$(grep -c '^updated=' "$STATE")" = 1 ] || fail "updated written twice" "$got"
bash "$OB" get nosuchkey >/dev/null && fail "get of a missing key must exit 1"
perm=$(stat -f '%Lp' "$STATE" 2>/dev/null || stat -c '%a' "$STATE" 2>/dev/null)
[ "$perm" = 600 ] || fail "state file mode is $perm, want 600"
ok "set merges, last value wins, one updated=, 0600"

# --- 1b. resume where it left ------------------------------------------------
out=$(brief)
printf '%s\n' "$out" | grep -qx 'resume: watch' || fail "brief does not resume at the saved step" "$out"
printf '%s\n' "$out" | grep -qx 'issue=12'      || fail "brief does not show the filed issue" "$out"
ok "brief resumes at watch with issue=12"

# --- 3. no forged keys -------------------------------------------------------
bash "$OB" set "note=hi
step=done" || fail "set with a newline failed"
[ "$(bash "$OB" get step)" = watch ] || fail "a newline in a value forged step=" "$(cat "$STATE")"
[ "$(grep -c '^step=' "$STATE")" = 1 ] || fail "forged a second step line" "$(cat "$STATE")"
ok "a newline in a value cannot forge a key"

# --- 4. step guard -----------------------------------------------------------
before=$(cat "$STATE")
bash "$OB" set step=bogus 2>/dev/null; rc=$?
[ "$rc" = 2 ] || fail "unknown step: exit $rc, want 2"
[ "$(cat "$STATE")" = "$before" ] || fail "a refused set changed the file"
bash "$OB" set 'bad key=1' 2>/dev/null; [ $? = 2 ] || fail "a bad key must be refused"
ok "unknown step / bad key refused, file untouched"

# --- reset -------------------------------------------------------------------
bash "$OB" reset
[ -e "$STATE" ] && fail "reset left the state file"
brief | grep -qx 'resume: repo' || fail "after reset brief must resume at repo"
ok "reset starts over"

# not inside a fleet
bash "$OB" brief --session no-such-fleet --no-gh >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || fail "brief outside a fleet: exit $rc, want 3"
ok "brief outside a fleet exits 3"

# --- 6. the skill matches the script -----------------------------------------
[ -r "$SKILL" ] || fail "commands/fleet-onboard.md missing"
grep -qx '<!-- fleet skill · owner: scratch -->' "$SKILL" || fail "skill marker line missing"
steps=$(sed -n 's/^STEPS="\(.*\)"$/\1/p' "$OB")
[ -n "$steps" ] || fail "cannot read STEPS from fleet-onboard.sh"
for s in $(grep -o 'step=[a-z]*' "$SKILL" | sed 's/step=//' | sort -u); do
  case " $steps " in *" $s "*) ;; *) fail "skill uses step=$s, the script accepts: $steps" ;; esac
done
for s in $steps; do
  grep -q "^## [0-9]\. \`$s\`" "$SKILL" || [ "$s" = done ] || fail "step $s has no section in the skill"
done
for f in $(grep -o '~/\.claude/fleet/bin/[A-Za-z0-9_.-]*' "$SKILL" | sed 's|.*/||' | sort -u); do
  [ -f "$BIN/$f" ] || fail "skill names bin/$f, which does not exist"
done
ok "skill steps, sections and script references match"

printf 'fleet-onboard selftest: %d passed\n' "$pass"
