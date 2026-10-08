#!/bin/bash
# fleet-stable-selftest.sh — bin/fleet-stable.sh + the doctor's stable INFO line
# (issue #1118), fully hermetic.
#
# A local BARE repo stands in for github; a clone of it is the checkout the
# script runs in; `gh` is a PATH shim that prints whatever check-run lines the
# test put in $WORK/checks. Nothing touches the real `stable` tag or the network.
#
# What it pins:
#   A. show, no tag       says `none` (verdict NONE, exit 1) — never a silent 0
#   B. CI gate            zero check runs / pending / failure all REFUSE (exit 3);
#                         --allow-no-checks is the one deliberate override
#   C. first move         all green → tag pushed; show says CURRENT / behind 0
#   D. behind count       trunk moves on → show says BEHIND N
#   E. forward only       an older commit, a sideways (off-trunk) commit are
#                         refused and the tag does not move; same target = no-op
#   F. --dry-run          passes every check, pushes nothing
#   G. lease              a concurrent move between read and push → push rejected
#                         (exit 4), the concurrent value survives
#   H. doctor             the `install` INFO line carries the behind count
#   I. oldcfg gate        a target that deletes a script stable's hook table still
#                         calls is REFUSED (`oldcfg:`, the script named, tag untouched);
#                         --force moves it and logs one line (issue #2075)
#   J. macos gate         (issue #2286) a target whose newest macOS run is red is
#                         REFUSED (`macos:`); the generic check gate ignores the
#                         `macOS shard *` runs; --dry-run with no run refuses and
#                         dispatches nothing; no run (or only a cancelled one) →
#                         the full suite is dispatched with -f sha=<target> and
#                         waited for, then the tag moves; --force moves past red
#                         and logs `macos=`
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ST="$BIN/fleet-stable.sh"
[ -f "$ST" ] || { printf 'selftest: %s not found\n' "$ST" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "fleet-stable-selftest SKIP (no git)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-stable-selftest.XXXXXX")" || exit 2
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:
$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"

# gh shim: `gh api …/check-runs --jq …` → the lines in $WORK/checks; the macOS
# workflow's runs → $WORK/macos (head_sha status conclusion event id title, TSV);
# `gh workflow run` is logged to $WORK/dispatched and appends $WORK/dispatch_to.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *actions/workflows/*) cat "$WORK/macos" 2>/dev/null ;;
  'workflow run'*) echo "\$*" >> "$WORK/dispatched"; cat "$WORK/dispatch_to" >> "$WORK/macos" 2>/dev/null ;;
  *) cat "$WORK/checks" ;;
esac
SH
chmod +x "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"
green() { printf 'completed success shard 1\ncompleted skipped docs\n' > "$WORK/checks"; }

BARE="$WORK/origin.git" SEED="$WORK/seed" CO="$WORK/co"
git init -q --bare -b master "$BARE"
git clone -q "$BARE" "$SEED" 2>/dev/null
commit() { echo "$1" >> "$SEED/f"; git -C "$SEED" add f; git -C "$SEED" commit -qm "$1"; git -C "$SEED" rev-parse HEAD; }
push() { git -C "$SEED" push -q origin HEAD:master; }
C1=$(commit one); C2=$(commit two); C3=$(commit three); push
git clone -q "$BARE" "$CO" 2>/dev/null

run() { OUT=$(sh "$ST" "$@" --dir "$CO" --repo o/r 2>&1); RC=$?; }
tag() { git --git-dir="$BARE" rev-parse -q --verify refs/tags/stable 2>/dev/null || echo none; }

# --- A. no tag ---------------------------------------------------------------
run show
eq "A: show without a tag exits 1" 1 "$RC"
contains "A: says none" "$OUT" "stable:  none"
contains "A: verdict NONE" "$OUT" "verdict: NONE"

# --- B. CI gate ----------------------------------------------------------------
: > "$WORK/checks"
run move "$C2"
eq "B: zero check runs refused" 3 "$RC"; contains "B: says no check runs" "$OUT" "NO check runs"
printf 'completed success a\nin_progress null shard 2\n' > "$WORK/checks"
run move "$C2"
eq "B: pending refused" 3 "$RC"; contains "B: names the pending run" "$OUT" "not green: in_progress null shard 2"
printf 'completed failure shard 3\n' > "$WORK/checks"
run move "$C2"
eq "B: failure refused" 3 "$RC"; eq "B: tag untouched" none "$(tag)"

# --- C. first move -------------------------------------------------------------
green
run move "$C2"
eq "C: green move exits 0" 0 "$RC"; eq "C: tag at C2" "$C2" "$(tag)"
run show
eq "C: show exits 0" 0 "$RC"; contains "C: behind 1" "$OUT" "behind:  1"; contains "C: BEHIND" "$OUT" "verdict: BEHIND"
run move
eq "C: default target = trunk tip" 0 "$RC"; eq "C: tag at C3" "$C3" "$(tag)"
run show
contains "C: CURRENT" "$OUT" "verdict: CURRENT"; contains "C: behind 0" "$OUT" "behind:  0"

# --- D. trunk moves on -----------------------------------------------------------
C4=$(commit four); C5=$(commit five); push
run show
contains "D: behind 2" "$OUT" "behind:  2"; contains "D: BEHIND" "$OUT" "verdict: BEHIND"

# --- E. forward only ---------------------------------------------------------------
run move "$C1"
eq "E: backward refused" 3 "$RC"; contains "E: says forward" "$OUT" "FORWARD"; eq "E: tag still C3" "$C3" "$(tag)"
git -C "$SEED" checkout -q -b side "$C2"; SIDE=$(commit side); git -C "$SEED" push -q origin side; git -C "$SEED" checkout -q master
run move "$SIDE"
eq "E: off-trunk refused" 3 "$RC"; contains "E: says not on trunk" "$OUT" "is not on origin/master"; eq "E: tag still C3" "$C3" "$(tag)"
run move "$C3"
eq "E: same target is a no-op" 0 "$RC"; contains "E: says already" "$OUT" "already at"
: > "$WORK/checks"
run move "$C4" --allow-no-checks
eq "E: --allow-no-checks moves" 0 "$RC"; eq "E: tag at C4" "$C4" "$(tag)"
green

# --- F. dry-run ----------------------------------------------------------------------
run move --dry-run
eq "F: dry-run exits 0" 0 "$RC"; contains "F: prints the push" "$OUT" "force-with-lease=refs/tags/stable:$C4"; eq "F: tag not moved" "$C4" "$(tag)"

# --- G. lease: someone else moves stable between our read and our push ----------------
REALGIT=$(command -v git)
mkdir -p "$WORK/racer"
cat > "$WORK/racer/git" <<SH
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = push ]; then "$REALGIT" --git-dir="$BARE" update-ref refs/tags/stable "$C5"; break; fi
done
exec "$REALGIT" "\$@"
SH
chmod +x "$WORK/racer/git"
# The racer moves stable to C5 (forward from C4) while we try to move it to C6.
C6=$(commit six); push
OUT=$(PATH="$WORK/racer:$PATH" sh "$ST" move "$C6" --dir "$CO" --repo o/r 2>&1); RC=$?
eq "G: lost lease exits 4" 4 "$RC"; contains "G: says lease" "$OUT" "lease lost"; eq "G: racer's C5 kept, not our C6" "$C5" "$(tag)"

# --- H. doctor ---------------------------------------------------------------------------
if [ -f "$BIN/fleet-doctor.sh" ]; then
  OUT=$(FLEET_LIVE_DIR="$CO" sh "$BIN/fleet-doctor.sh" 2>&1)
  contains "H: doctor INFO carries behind count" "$OUT" "is 1 commit(s) behind origin/master — installs follow stable"
fi

# --- I. the old-session replay gate (issue #2075) ----------------------------------
# A stable whose hook table calls bin/h.sh, then a target that deletes the script.
mkdir -p "$SEED/hooks" "$SEED/bin"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}]}}\n' > "$SEED/hooks/settings-hooks.json"
mkdir -p "$SEED/bin"; printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$SEED/bin/h.sh"
git -C "$SEED" add -A; git -C "$SEED" commit -qm hooked; C7=$(git -C "$SEED" rev-parse HEAD); push
green
run move "$C7"
eq "I: a table whose scripts exist moves" 0 "$RC"; contains "I: says GREEN" "$OUT" "oldcfg-replay: GREEN"; eq "I: tag at C7" "$C7" "$(tag)"
git -C "$SEED" rm -q bin/h.sh; git -C "$SEED" commit -qm 'drop h.sh'; C8=$(git -C "$SEED" rev-parse HEAD); push
run move "$C8"
eq "I: a deleted hook script is refused" 3 "$RC"; contains "I: reason prefixed oldcfg:" "$OUT" "REFUSED — oldcfg:"
contains "I: names the script" "$OUT" "bin/h.sh not in the new tree"; contains "I: names the event" "$OUT" "MISSING  Stop"
eq "I: tag still C7" "$C7" "$(tag)"
run move "$C8" --dry-run
eq "I: --dry-run runs the gate too" 3 "$RC"; eq "I: tag still C7 after dry-run" "$C7" "$(tag)"
OUT=$(FLEET_STABLE_LOG="$WORK/stable-move.log" sh "$ST" move "$C8" --force --dir "$CO" --repo o/r 2>&1); RC=$?
eq "I: --force moves" 0 "$RC"; eq "I: tag at C8" "$C8" "$(tag)"; contains "I: says FORCED" "$OUT" "oldcfg: FORCED past the replay"
contains "I: one line logged" "$(cat "$WORK/stable-move.log" 2>/dev/null)" "	forced	old=$(git -C "$CO" rev-parse --short "$C7")	new=$(git -C "$CO" rev-parse --short "$C8")	by="
contains "I: the log carries the replay's verdict" "$(cat "$WORK/stable-move.log" 2>/dev/null)" "oldcfg=oldcfg-replay: RED — 1 finding(s)"

# --- J. the macOS gate (issue #2286) ------------------------------------------------
# From here the tree carries the macOS workflow, so gate 5 applies. h.sh comes back
# too: stable C8's hook table still calls it (gate 4 must stay green here).
mkdir -p "$SEED/.github/workflows"; echo 'name: selftests (macOS)' > "$SEED/.github/workflows/selftests-macos.yml"
mkdir -p "$SEED/bin"; printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$SEED/bin/h.sh"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'bsd half'; C9=$(git -C "$SEED" rev-parse HEAD); push
# The generic gate must not count the macOS shards: a cancelled one is no verdict.
printf 'completed success shard 1\ncompleted cancelled macOS shard 1\n' > "$WORK/checks"
printf '%s\tcompleted\tfailure\tpush\t11\tselftests (macOS)\n' "$C9" > "$WORK/macos"
run move "$C9"
eq "J: a red macOS run on the target is refused" 3 "$RC"; contains "J: reason prefixed macos:" "$OUT" "REFUSED — macos:"
contains "J: names the run" "$OUT" "is failure (run 11, push"; eq "J: tag still C8" "$C8" "$(tag)"
case "$OUT" in *"not green: completed cancelled"*) fail "J: the generic gate counted a macOS shard" ;; esac
# A target with no run: --dry-run refuses and dispatches nothing.
C10=$(commit ten); push
printf '%s\tcompleted\tcancelled\tpush\t13\tselftests (macOS)\n%s\tcompleted\tfailure\tpush\t11\tselftests (macOS)\n' "$C10" "$C9" > "$WORK/macos"
run move "$C10" --dry-run
eq "J: dry-run with no run refused" 3 "$RC"; contains "J: dry-run says it would dispatch" "$OUT" "a real move dispatches"
eq "J: dry-run dispatched nothing" no "$([ -f "$WORK/dispatched" ] && echo yes || echo no)"
# A real move dispatches the full suite on exactly C10 and waits: in_progress, then
# (after one poll) success. A cancelled run on C10 counted as none.
printf '%s\tin_progress\t\tworkflow_dispatch\t14\tselftests (macOS) @ %s\n' "$C9" "$C10" > "$WORK/dispatch_to"
mkdir -p "$WORK/sleepshim"
cat > "$WORK/sleepshim/sleep" <<SH
#!/bin/sh
printf '%s\tcompleted\tsuccess\tworkflow_dispatch\t14\tselftests (macOS) @ %s\n' "$C9" "$C10" > "$WORK/macos"
SH
chmod +x "$WORK/sleepshim/sleep"
OUT=$(PATH="$WORK/sleepshim:$PATH" FLEET_STABLE_MACOS_POLL=1 sh "$ST" move "$C10" --dir "$CO" --repo o/r 2>&1); RC=$?
eq "J: no run → dispatched, waited, moved" 0 "$RC"; eq "J: tag at C10" "$C10" "$(tag)"
contains "J: dispatched with the target sha" "$(cat "$WORK/dispatched" 2>/dev/null)" "workflow run selftests-macos.yml --repo o/r --ref master -f sha=$C10"
contains "J: says it dispatched" "$OUT" "dispatched the full suite"; contains "J: says green" "$OUT" "macos: green on"
# A run that never finishes refuses at --macos-timeout.
C11=$(commit eleven); push; rm -f "$WORK/dispatch_to"
printf '%s\tqueued\t\tpush\t15\tselftests (macOS)\n' "$C11" > "$WORK/macos"
mkdir -p "$WORK/nosleep"; printf '#!/bin/sh\nexit 0\n' > "$WORK/nosleep/sleep"; chmod +x "$WORK/nosleep/sleep"
OUT=$(PATH="$WORK/nosleep:$PATH" FLEET_STABLE_MACOS_POLL=1 sh "$ST" move "$C11" --macos-timeout 3 --dir "$CO" --repo o/r 2>&1); RC=$?
eq "J: an unfinished run refuses at the bound" 3 "$RC"; contains "J: says did not finish" "$OUT" "did not finish in 3s"; eq "J: tag still C10" "$C10" "$(tag)"
# --force past red: moves, one `macos=` line.
printf '%s\tcompleted\tfailure\tschedule\t16\tselftests (macOS)\n' "$C11" > "$WORK/macos"
OUT=$(FLEET_STABLE_LOG="$WORK/stable-move.log" sh "$ST" move "$C11" --force --dir "$CO" --repo o/r 2>&1); RC=$?
eq "J: --force moves past red" 0 "$RC"; eq "J: tag at C11" "$C11" "$(tag)"; contains "J: says FORCED" "$OUT" "macos: FORCED past the BSD half (failure)"
contains "J: the log carries macos=" "$(cat "$WORK/stable-move.log" 2>/dev/null)" "	macos=run 16 failure"

# --- K. release.json (issue #2334) ---------------------------------------------------
# A tree that ships the machine updater must declare what a managed machine runs.
macos_green() { printf '%s\tcompleted\tsuccess\tpush\t%s\tselftests (macOS)\n' "$1" "$2" > "$WORK/macos"; }
green
mkdir -p "$SEED/bin"; printf '#!/usr/bin/env python3\n' > "$SEED/bin/fleet-node-update.py"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'updater, no release.json'; C12=$(git -C "$SEED" rev-parse HEAD); push
macos_green "$C12" 21
run move "$C12"
eq "K: the updater without release.json is refused" 3 "$RC"; contains "K: reason prefixed release:" "$OUT" "REFUSED — release:"
contains "K: says what is missing" "$OUT" "no release.json"; eq "K: tag still C11" "$C11" "$(tag)"
printf '{"schema": 2}\n' > "$SEED/release.json"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'bad release.json'; C13=$(git -C "$SEED" rev-parse HEAD); push
macos_green "$C13" 22
run move "$C13"
eq "K: an invalid release.json is refused" 3 "$RC"; contains "K: names the fault" "$OUT" "schema must be 1"
cp "$BIN/../release.json" "$SEED/release.json"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'release.json'; C14=$(git -C "$SEED" rev-parse HEAD); push
macos_green "$C14" 23
run move "$C14"
eq "K: a valid release.json moves" 0 "$RC"; eq "K: tag at C14" "$C14" "$(tag)"; contains "K: says valid" "$OUT" "carries a valid release.json"

printf 'fleet-stable-selftest OK (%d checks)\n' "$CHECKS"
