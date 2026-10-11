#!/bin/bash
# fleet-onboard-selftest.sh — the onboarding wizard's memory (issue #1168).
#
# /fleet-onboard (commands/fleet-onboard.md) resumes at the step it left from
# $FLEET_CONF_DIR/global/onboard.state, written by bin/fleet-onboard.sh. What
# this pins:
#
#   1. RESUME — no state ⇒ `resume: key` (the plain walk, issue #3332); after `set step=watch` a fresh `brief`
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
#   8. THE PLAIN WALK (issue #3332) — a fleet with no repo briefs fine; the
#      brief prints lang= + every say.* line in zh and en from fleet-ui-lang.sh;
#      no say line but `dev` (and nothing else the plain brief prints) names a
#      repo / issue / PR / GitHub, and the plain brief never asks gh; `--dev`
#      (or a saved path=dev) shows the repos; an old saved `handoff` resumes done.
#   9. LOOK — `look` before `look --mark` refuses; after it, only a worker window
#      that was not there is printed (`new …`), home / panels never.
#  10. NO SEAT GRAB — the skill never takes a role, spawns, files an issue or
#      talks about the sidebar (issue #3320 gaps 2, 3, 5).
#   7. SPOKE MARKER (issue #1215) — the first `brief` inside a fleet writes
#      global/guide.spoke (0600-ish, a timestamp), a later brief leaves the
#      first stamp alone, `reset` keeps it, and a brief outside a fleet never
#      writes one.
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
brief() { bash "$OB" brief --session "$SESS" --no-gh "$@" 2>&1; }

# --- 1. resume from nothing --------------------------------------------------
out=$(brief) || fail "brief failed on a fresh fleet" "$out"
printf '%s\n' "$out" | grep -qx 'resume: key' || fail "fresh start must resume at key" "$out"
[ "$(bash "$OB" path)" = "$STATE" ] || fail "path is not \$FLEET_CONF_DIR/global/onboard.state"
ok "fresh fleet: resume at key, state under global/"

# --- 5. seed tag (FLEET_SEED absent ⇒ no tag) --------------------------------
printf '%s\n' "$out" | grep -q '\[seed\]' && fail "no FLEET_SEED, yet a repo was tagged [seed]" "$out"
printf 'FLEET_SEED=1\n' >> "$FLEET_CONF_DIR/fleets/$SESS/conf"
out=$(brief --dev)
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
perm=$(ls -l "$STATE" | cut -c1-10)   # ls, not stat: GNU `stat -f` is filesystem status
[ "$perm" = -rw------- ] || fail "state file mode is $perm, want -rw-------"
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
brief | grep -qx 'resume: key' || fail "after reset brief must resume at key"
ok "reset starts over"

# not inside a fleet
bash "$OB" brief --session no-such-fleet --no-gh >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || fail "brief outside a fleet: exit $rc, want 3"
ok "brief outside a fleet exits 3"

# --- 7. the spoke marker (issue #1215) ---------------------------------------
SPOKE="$FLEET_CONF_DIR/global/guide.spoke"
[ -f "$SPOKE" ] || fail "brief inside a fleet did not write global/guide.spoke"
first=$(cat "$SPOKE")
[ -n "$first" ] || fail "guide.spoke is empty — it should carry when the guide first spoke"
sleep 1.1
brief >/dev/null || fail "second brief failed"
[ "$(cat "$SPOKE")" = "$first" ] || fail "a later brief overwrote the first spoke stamp"
bash "$OB" reset
[ -f "$SPOKE" ] || fail "reset removed guide.spoke — it forgets progress, not that the guide spoke"
rm -f "$SPOKE"
bash "$OB" brief --session no-such-fleet --no-gh >/dev/null 2>&1
[ ! -e "$SPOKE" ] || fail "brief outside a fleet wrote guide.spoke"
ok "brief writes guide.spoke once; reset keeps it; no fleet, no marker"

# --- 6. the skill matches the script -----------------------------------------
[ -r "$SKILL" ] || fail "commands/fleet-onboard.md missing"
grep -qx '<!-- fleet skill · owner: scratch -->' "$SKILL" || fail "skill marker line missing"
steps=$(sed -n 's/^STEPS="\(.*\)"$/\1/p' "$OB")
[ -n "$steps" ] || fail "cannot read STEPS from fleet-onboard.sh"
for s in $(grep -o 'step=[a-z]*' "$SKILL" | sed 's/step=//' | sort -u); do
  case " $steps " in *" $s "*) ;; *) fail "skill uses step=$s, the script accepts: $steps" ;; esac
done
for s in $steps; do
  grep -qE "^##+ [0-9.]+ \`$s\`" "$SKILL" || fail "step $s has no section in the skill"
done
for f in $(grep -o '[~]/\.claude/fleet/bin/[A-Za-z0-9_.-]*' "$SKILL" | sed 's|.*/||' | sort -u); do
  [ -f "$BIN/$f" ] || fail "skill names bin/$f, which does not exist"
done
ok "skill steps, sections and script references match"

# --- 8. the plain walk (issue #3332) -----------------------------------------
NOREPO=onb-norepo
mkdir -p "$FLEET_CONF_DIR/fleets/$NOREPO"
printf 'FLEET_MAIN=%s/none\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$NOREPO/conf"
# a gh that leaves a mark: the plain brief must never ask it
mkdir -p "$WORK/shim"
printf '#!/bin/sh\n: > "%s/gh.called"\necho someone\n' "$WORK" > "$WORK/shim/gh"; chmod +x "$WORK/shim/gh"
bash "$OB" reset
out=$(PATH="$WORK/shim:$PATH" FLEET_UI_LANG=zh bash "$OB" brief --session "$NOREPO" 2>&1) || fail "a fleet with no repo must brief (exit 0)" "$out"
printf '%s\n' "$out" | grep -qx 'resume: key' || fail "no-repo fleet: resume is not key" "$out"
[ -e "$WORK/gh.called" ] && fail "the plain brief asked gh (GitHub belongs to the developer walk only)" "$out"
printf '%s\n' "$out" | grep -q '^repos:' && fail "the plain brief lists repos" "$out"
printf '%s\n' "$out" | grep -q 'lang=zh' || fail "FLEET_UI_LANG=zh: brief does not say lang=zh" "$out"
says=$(sed -n 's/^SAY="\(.*\)"$/\1/p' "$OB")
[ -n "$says" ] || fail "cannot read SAY from fleet-onboard.sh"
for L in zh en; do
  o=$(FLEET_UI_LANG=$L bash "$OB" brief --session "$NOREPO" 2>&1)
  for n in $says; do
    line=$(printf '%s\n' "$o" | sed -n "s/^say\.$n: //p")
    [ -n "$line" ] && [ "$line" != "onboard_$n" ] || fail "$L: say.$n missing from the table" "$o"
  done
  plain=$(printf '%s\n' "$o" | grep -v '^say\.dev: ')
  hit=$(printf '%s\n' "$plain" | grep -inE '仓库|issue|\bPR\b|pull request|github|\brepo|worktree|分支|branch|单号|建单')
  [ -z "$hit" ] || fail "$L: the plain walk names a developer word" "$hit"
done
en=$(FLEET_UI_LANG=en bash "$OB" brief --session "$NOREPO" | sed -n 's/^say\.key: //p')
zh=$(FLEET_UI_LANG=zh bash "$OB" brief --session "$NOREPO" | sed -n 's/^say\.key: //p')
[ "$en" != "$zh" ] || fail "say.key reads the same in zh and en"
printf '%s\n%s\n' "$en" "$zh" | grep -q '⌘P' || fail "say.key does not teach ⌘P"
printf '%s\n' "$zh" | grep -q '⌃空格' || fail "zh say.key does not teach ⌃空格 (the phone)"
bash "$OB" set step=try lang=en
[ "$(bash "$OB" brief --session "$NOREPO" | sed -n 's/^.*lang=\([a-z]*\).*$/\1/p' | head -n 1)" = en ] || fail "a saved lang= does not win over the table's language"
bash "$OB" set path=dev
o=$(PATH="$WORK/shim:$PATH" bash "$OB" brief --session "$SESS" 2>&1)
printf '%s\n' "$o" | grep -q '^repos:' || fail "path=dev: the brief does not list repos" "$o"
[ -e "$WORK/gh.called" ] || fail "path=dev: the brief does not ask gh for the login" "$o"
printf 'step=handoff\n' > "$STATE"
bash "$OB" brief --session "$NOREPO" | grep -qx 'resume: done' || fail "an old saved handoff must resume as done"
bash "$OB" reset
ok "plain walk: no repo needed, zh+en say lines, no developer words, gh only on --dev"

# --- 9. look ------------------------------------------------------------------
ROWS="$WORK/rows"
printf '#!/bin/sh\ncat "%s"\n' "$ROWS" > "$WORK/shim/tmux"; chmod +x "$WORK/shim/tmux"
printf 'fid-guide|guide|worker|done||||\nfid-home|home|home|||||\n' > "$ROWS"
look() { PATH="$WORK/shim:$PATH" bash "$OB" look "$@" 2>&1; }
rm -f "$FLEET_CONF_DIR/global/onboard.seen"
look >/dev/null && fail "look before look --mark must refuse"
look --mark | grep -q '^marked: 2' || fail "look --mark did not remember both windows" "$(look --mark)"
[ "$(look)" = none ] || fail "nothing new yet, look printed: $(look)"
printf 'fid-pan|plan|panel|||||\nfid-new|norepo-3|worker|working|T7|||帮我写一封请假邮件\n' >> "$ROWS"
got=$(look)
[ "$got" = "$(printf 'new\tworking\tT7\t\t-\t帮我写一封请假邮件')" ] || fail "look did not print exactly the new worker" "$got"
ok "look: refuses unmarked, prints only the window that is new"

# --- 10. no seat grab, no ticket, no sidebar (issue #3320) -------------------
for bad in fleet-role-take '--spawn' 'fleet-issue-file' sidebar 'fleet-keys.sh'; do
  grep -q -- "$bad" "$SKILL" && fail "the skill still says '$bad' (#3320: no role, no spawn, no ticket, no sidebar)"
done
ok "the skill takes no role, spawns nothing, files nothing, has no sidebar"

printf 'fleet-onboard selftest: %d passed\n' "$pass"
