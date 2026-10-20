#!/bin/bash
# fleet-onboard-selftest.sh — the onboarding wizard's memory (issue #1168).
#
# /fleet-onboard (commands/fleet-onboard.md) resumes at the step it left from
# $FLEET_CONF_DIR/global/onboard.state, written by bin/fleet-onboard.sh. What
# this pins:
#
#   1. RESUME — no state ⇒ `resume: key` (the plain walk, issue #3332); after `set step=see` a fresh `brief`
#      says `resume: see` and still carries task= from earlier calls.
#   2. MERGE — `set` keeps every key it was not given, the last value of a key
#      wins, `updated=` is restamped, the file is 0600.
#   3. NO FORGED KEYS — a newline in a value is folded, so a value can never
#      write a second `step=` line.
#   4. STEP GUARD — an unknown step is refused (exit 2) and the file is untouched.
#   6. THE SKILL MATCHES THE SCRIPT — every `set step=<x>` in the skill is a step
#      the script accepts, every fleet script it names exists in bin/, and it
#      carries the installer's marker line.
#   8. THE PLAIN WALK (issue #3332) — a fleet with no repo briefs fine; the
#      brief prints lang= + every say.* line in zh and en from fleet-ui-lang.sh;
#      nothing the brief prints names a repo / issue / PR / GitHub, and the brief
#      never asks gh; an old saved step it no longer has (`handoff`, the developer
#      walk's `watch`, #4904) resumes done.
#   9. LOOK — `look` before `look --mark` refuses; after it, only a worker window
#      that was not there is printed (`new …`), home / panels never.
#  10. NO SEAT GRAB — the skill never takes a role, spawns, files an issue or
#      talks about the sidebar (issue #3320 gaps 2, 3, 5).
#   7. SPOKE MARKER (issue #1215) — the first `brief` inside a fleet writes
#      global/guide.spoke (0600-ish, a timestamp), a later brief leaves the
#      first stamp alone, `reset` keeps it, and a brief outside a fleet never
#      writes one.
#
# Hermetic: a temp FLEET_CONF_DIR, --session (no tmux, no network).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
ROOT="$(cd "$BIN/.." && pwd)"
OB="$BIN/fleet-onboard.sh"
SKILL="$ROOT/commands/fleet-onboard.md"

st_sandbox "${TMPDIR:-/tmp}/fleet-onboard.XXXXXX"
trap 'exit 130' INT TERM HUP
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR"

pass=0

STATE="$FLEET_CONF_DIR/global/onboard.state"
SESS=onb-test
mkdir -p "$FLEET_CONF_DIR/fleets/$SESS/repos"
: > "$FLEET_CONF_DIR/fleets/$SESS/conf"
fx_repo "$FLEET_CONF_DIR" "$SESS" verkyyi/claude-fleet FLEET_MAIN="$WORK/main"
printf 'FLEET_REPO=erin/app\n' > "$FLEET_CONF_DIR/fleets/$SESS/repos/erin-app.conf"
brief() { bash "$OB" brief --session "$SESS" 2>&1; }

# --- 1. resume from nothing --------------------------------------------------
out=$(brief) || st_fail "brief failed on a fresh fleet" "$out"
printf '%s\n' "$out" | grep -qx 'resume: key' || st_fail "fresh start must resume at key" "$out"
[ "$(bash "$OB" path)" = "$STATE" ] || st_fail "path is not \$FLEET_CONF_DIR/global/onboard.state"
st_pass "fresh fleet: resume at key, state under global/"

# --- 2. merge ----------------------------------------------------------------
bash "$OB" set step=key lang=zh || st_fail "set failed"
bash "$OB" set task=T7 step=try || st_fail "second set failed"
bash "$OB" set note=x step=see || st_fail "third set failed"
got=$(bash "$OB" get)
[ "$(bash "$OB" get lang)" = zh ]         || st_fail "lang lost across sets" "$got"
[ "$(bash "$OB" get task)" = T7 ]         || st_fail "task lost across sets" "$got"
[ "$(bash "$OB" get step)" = see ]        || st_fail "last step did not win" "$got"
[ "$(grep -c '^step=' "$STATE")" = 1 ]    || st_fail "step written twice" "$got"
[ "$(grep -c '^updated=' "$STATE")" = 1 ] || st_fail "updated written twice" "$got"
bash "$OB" get nosuchkey >/dev/null && st_fail "get of a missing key must exit 1"
perm=$(ls -l "$STATE" | cut -c1-10)   # ls, not stat: GNU `stat -f` is filesystem status
[ "$perm" = -rw------- ] || st_fail "state file mode is $perm, want -rw-------"
st_pass "set merges, last value wins, one updated=, 0600"

# --- 1b. resume where it left ------------------------------------------------
out=$(brief)
printf '%s\n' "$out" | grep -qx 'resume: see' || st_fail "brief does not resume at the saved step" "$out"
printf '%s\n' "$out" | grep -qx 'task=T7'     || st_fail "brief does not show the saved task" "$out"
st_pass "brief resumes at see with task=T7"

# --- 3. no forged keys -------------------------------------------------------
bash "$OB" set "note=hi
step=done" || st_fail "set with a newline failed"
[ "$(bash "$OB" get step)" = see ] || st_fail "a newline in a value forged step=" "$(cat "$STATE")"
[ "$(grep -c '^step=' "$STATE")" = 1 ] || st_fail "forged a second step line" "$(cat "$STATE")"
st_pass "a newline in a value cannot forge a key"

# --- 4. step guard -----------------------------------------------------------
before=$(cat "$STATE")
bash "$OB" set step=bogus 2>/dev/null; rc=$?
[ "$rc" = 2 ] || st_fail "unknown step: exit $rc, want 2"
[ "$(cat "$STATE")" = "$before" ] || st_fail "a refused set changed the file"
bash "$OB" set 'bad key=1' 2>/dev/null; [ $? = 2 ] || st_fail "a bad key must be refused"
st_pass "unknown step / bad key refused, file untouched"

# --- reset -------------------------------------------------------------------
bash "$OB" reset
[ -e "$STATE" ] && st_fail "reset left the state file"
brief | grep -qx 'resume: key' || st_fail "after reset brief must resume at key"
st_pass "reset starts over"

# not inside a fleet
bash "$OB" brief --session no-such-fleet >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || st_fail "brief outside a fleet: exit $rc, want 3"
st_pass "brief outside a fleet exits 3"

# --- 7. the spoke marker (issue #1215) ---------------------------------------
SPOKE="$FLEET_CONF_DIR/global/guide.spoke"
[ -f "$SPOKE" ] || st_fail "brief inside a fleet did not write global/guide.spoke"
first=$(cat "$SPOKE")
[ -n "$first" ] || st_fail "guide.spoke is empty — it should carry when the guide first spoke"
sleep 1.1
brief >/dev/null || st_fail "second brief failed"
[ "$(cat "$SPOKE")" = "$first" ] || st_fail "a later brief overwrote the first spoke stamp"
bash "$OB" reset
[ -f "$SPOKE" ] || st_fail "reset removed guide.spoke — it forgets progress, not that the guide spoke"
rm -f "$SPOKE"
bash "$OB" brief --session no-such-fleet >/dev/null 2>&1
[ ! -e "$SPOKE" ] || st_fail "brief outside a fleet wrote guide.spoke"
st_pass "brief writes guide.spoke once; reset keeps it; no fleet, no marker"

# --- 6. the skill matches the script -----------------------------------------
[ -r "$SKILL" ] || st_fail "commands/fleet-onboard.md missing"
grep -qx '<!-- fleet skill · owner: scratch -->' "$SKILL" || st_fail "skill marker line missing"
steps=$(sed -n 's/^STEPS="\(.*\)"$/\1/p' "$OB")
[ -n "$steps" ] || st_fail "cannot read STEPS from fleet-onboard.sh"
for s in $(grep -o 'step=[a-z]*' "$SKILL" | sed 's/step=//' | sort -u); do
  case " $steps " in *" $s "*) ;; *) st_fail "skill uses step=$s, the script accepts: $steps" ;; esac
done
for s in $steps; do
  grep -qE "^##+ [0-9.]+ \`$s\`" "$SKILL" || st_fail "step $s has no section in the skill"
done
for f in $(grep -o '[~]/\.claude/fleet/bin/[A-Za-z0-9_.-]*' "$SKILL" | sed 's|.*/||' | sort -u); do
  [ -f "$BIN/$f" ] || st_fail "skill names bin/$f, which does not exist"
done
st_pass "skill steps, sections and script references match"

# --- 8. the plain walk (issue #3332) -----------------------------------------
NOREPO=onb-norepo
mkdir -p "$FLEET_CONF_DIR/fleets/$NOREPO"
printf 'FLEET_MAIN=%s/none\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$NOREPO/conf"
# a gh that leaves a mark: the plain brief must never ask it
mkdir -p "$WORK/shim"
printf '#!/bin/sh\n: > "%s/gh.called"\necho someone\n' "$WORK" > "$WORK/shim/gh"; chmod +x "$WORK/shim/gh"
bash "$OB" reset
out=$(PATH="$WORK/shim:$PATH" FLEET_UI_LANG=zh bash "$OB" brief --session "$NOREPO" 2>&1) || st_fail "a fleet with no repo must brief (exit 0)" "$out"
printf '%s\n' "$out" | grep -qx 'resume: key' || st_fail "no-repo fleet: resume is not key" "$out"
[ -e "$WORK/gh.called" ] && st_fail "the brief asked gh" "$out"
printf '%s\n' "$out" | grep -q '^repos:' && st_fail "the plain brief lists repos" "$out"
printf '%s\n' "$out" | grep -q 'lang=zh' || st_fail "FLEET_UI_LANG=zh: brief does not say lang=zh" "$out"
says=$(sed -n 's/^SAY="\(.*\)"$/\1/p' "$OB")
[ -n "$says" ] || st_fail "cannot read SAY from fleet-onboard.sh"
for L in zh en; do
  o=$(FLEET_UI_LANG=$L bash "$OB" brief --session "$NOREPO" 2>&1)
  for n in $says; do
    line=$(printf '%s\n' "$o" | sed -n "s/^say\.$n: //p")
    [ -n "$line" ] && [ "$line" != "onboard_$n" ] || st_fail "$L: say.$n missing from the table" "$o"
  done
  hit=$(printf '%s\n' "$o" | grep -inE '仓库|issue|\bPR\b|pull request|github|\brepo|worktree|分支|branch|单号|建单')
  [ -z "$hit" ] || st_fail "$L: the plain walk names a developer word" "$hit"
done
en=$(FLEET_UI_LANG=en bash "$OB" brief --session "$NOREPO" | sed -n 's/^say\.key: //p')
zh=$(FLEET_UI_LANG=zh bash "$OB" brief --session "$NOREPO" | sed -n 's/^say\.key: //p')
[ "$en" != "$zh" ] || st_fail "say.key reads the same in zh and en"
printf '%s\n%s\n' "$en" "$zh" | grep -q '⌘P' || st_fail "say.key does not teach ⌘P"
printf '%s\n' "$zh" | grep -q '⌃空格' || st_fail "zh say.key does not teach ⌃空格 (the phone)"
bash "$OB" set step=try lang=en
[ "$(bash "$OB" brief --session "$NOREPO" | sed -n 's/^.*lang=\([a-z]*\).*$/\1/p' | head -n 1)" = en ] || st_fail "a saved lang= does not win over the table's language"
o=$(PATH="$WORK/shim:$PATH" bash "$OB" brief --session "$SESS" --dev 2>&1)
printf '%s\n' "$o" | grep -q '^repos:' && st_fail "an older skill's --dev still lists repos" "$o"
[ -e "$WORK/gh.called" ] && st_fail "an older skill's --dev still asks gh" "$o"
for old in handoff watch; do
  printf 'step=%s\n' "$old" > "$STATE"
  bash "$OB" brief --session "$NOREPO" | grep -qx 'resume: done' || st_fail "an old saved $old must resume as done"
done
bash "$OB" reset
st_pass "plain walk: no repo needed, zh+en say lines, no developer words, never gh; an old step resumes done"

# --- 9. look ------------------------------------------------------------------
ROWS="$WORK/rows"
printf '#!/bin/sh\ncat "%s"\n' "$ROWS" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
printf 'fid-guide|guide|worker|done||||\nfid-home|home|home|||||\n' > "$ROWS"
look() { PATH="$WORK/shim:$PATH" bash "$OB" look "$@" 2>&1; }
rm -f "$FLEET_CONF_DIR/global/onboard.seen"
look >/dev/null && st_fail "look before look --mark must refuse"
look --mark | grep -q '^marked: 2' || st_fail "look --mark did not remember both windows" "$(look --mark)"
[ "$(look)" = none ] || st_fail "nothing new yet, look printed: $(look)"
printf 'fid-pan|plan|panel|||||\nfid-new|norepo-3|worker|working|T7|||帮我写一封请假邮件\n' >> "$ROWS"
got=$(look)
[ "$got" = "$(printf 'new\tworking\tT7\t\t-\t帮我写一封请假邮件')" ] || st_fail "look did not print exactly the new worker" "$got"
st_pass "look: refuses unmarked, prints only the window that is new"

# (10. no seat grab, no spawn, no sidebar, #3320: conf/gone.list)

printf 'fleet-onboard selftest: %d passed\n' "$pass"
