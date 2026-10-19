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
#   J. no macos gate      (issues #4663, #4671) gate 5 is retired: a red macOS
#                         run on the target, no run at all, a cancelled `macOS
#                         shard *` check — none refuses, nothing is dispatched or
#                         waited for
#   L. --ignore-check     the caller's own pending CI job (exact name) is passed
#                         over; any other pending run still refuses; the flag
#                         repeats (issue #3143) — every name it gives is passed over
#   P. derived runs       (issue #3143) a red publish / move / train / hub-deploy run
#                         on the target (a release workflow's own run, matched by
#                         its check suite) is passed over and named; a red run of
#                         any other workflow still refuses; FLEET_STABLE_DERIVED_RE=''
#                         counts every run again
#   N. the release train  (issue #3141) --precheck runs trunk / forward / oldcfg /
#                         release.json / artifacts only — red or pending CI pass,
#                         nothing is pushed or dispatched; backward and a bad
#                         release.json still refuse. The shared matrix's
#                         `macOS / shard K` checks are no verdict
#   O. --train <run>      (issue #3142) gate 3 reads THAT run's jobs, never the
#                         commit's check runs: a red / unfinished job refuses (CI),
#                         a red or missing macOS job does not, the job
#                         --ignore-check names is passed over, all green moves
#   Q. one release line   (issues #4671, #4790) --ref / --seed / --with-stable /
#                         --macos-timeout are unknown flags (exit 2), nothing pushed
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
# no hub here: gate 7 (the hub's artifacts, issue #2631) says so and passes —
# its refusal is docs/dev/BREAK-IT.md's release-artifact-missing drill
export FLEET_CONF_DIR="$WORK/conf" XDG_CONFIG_HOME="$WORK/conf"
unset CCQUOTA_HUB_URL FLEET_HUB_URL 2>/dev/null
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
  *'actions/runs?head_sha='*) cat "$WORK/derived" 2>/dev/null ;;
  *actions/runs/*/jobs*) cat "$WORK/jobs" 2>/dev/null ;;
  *'cn path'*) cat "$WORK/cnstatus" 2>/dev/null ;;
  */issues/*) cat "$WORK/cnissue" 2>/dev/null ;;
  */statuses*) cat "$WORK/statuses" 2>/dev/null ;;
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

# --- J. no macOS gate (issues #4663, #4671) ------------------------------------------
# The tree carries the macOS workflow from here; gate 5 is retired, so nothing about
# it holds stable. h.sh comes back too: stable C8's hook table still calls it.
mkdir -p "$SEED/.github/workflows"; echo 'name: selftests (macOS)' > "$SEED/.github/workflows/selftests-macos.yml"
mkdir -p "$SEED/bin"; printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$SEED/bin/h.sh"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'bsd half'; C9=$(git -C "$SEED" rev-parse HEAD); push
# The generic gate must not count the macOS shards; a red macOS run is no refusal.
printf 'completed success shard 1\ncompleted cancelled macOS shard 1\n' > "$WORK/checks"
printf '%s\tcompleted\tfailure\tpush\t11\tselftests (macOS)\n' "$C9" > "$WORK/macos"
run move "$C9"
eq "J: a red macOS run does not hold stable" 0 "$RC"; eq "J: tag at C9" "$C9" "$(tag)"
case "$OUT" in *"not green: completed cancelled"*) fail "J: the generic gate counted a macOS shard" ;; esac
case "$OUT" in *"macos:"*) fail "J: gate 5 still spoke: $OUT" ;; esac
# No macOS run at all: nothing dispatched, nothing waited for.
C10=$(commit ten); push; : > "$WORK/macos"
run move "$C10"
eq "J: no macOS run → moves" 0 "$RC"; eq "J: tag at C10" "$C10" "$(tag)"
eq "J: dispatched nothing" no "$([ -f "$WORK/dispatched" ] && echo yes || echo no)"
C11=$(commit eleven); push
run move "$C11" --dry-run
eq "J: dry-run passes with no macOS run" 0 "$RC"
run move "$C11"
eq "J: tag at C11" 0 "$RC"; eq "J: …C11" "$C11" "$(tag)"

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

# --- L. --ignore-check (a CI caller's own job) -----------------------------------------------
# The CI job that runs the move is a check run on the very commit it moves to, never
# finished yet: without the flag it is refused like any pending run; with its exact
# name it is passed over — and only that name (a pending run beside it still refuses).
C15=$(commit fifteen); push; macos_green "$C15" 24
printf 'completed success shard 1\nin_progress null move stable\n' > "$WORK/checks"
run move "$C15" --dry-run
eq "L: its own pending job refused without the flag" 3 "$RC"; contains "L: names it" "$OUT" "not green: in_progress null move stable"
run move "$C15" --ignore-check "move stable"
eq "L: --ignore-check passes over its own job" 0 "$RC"; eq "L: tag at C15" "$C15" "$(tag)"
C16=$(commit sixteen); push; macos_green "$C16" 25
printf 'completed success shard 1\nin_progress null move stable\nqueued null deploy hub\n' > "$WORK/checks"
run move "$C16" --ignore-check "move stable"
eq "L: another pending run still refuses" 3 "$RC"; contains "L: names the other one" "$OUT" "not green: queued null deploy hub"
case "$OUT" in *"not green: in_progress null move stable"*) fail "L: the ignored job was counted" ;; esac
eq "L: tag still C15" "$C15" "$(tag)"
run move "$C16" --ignore-check "move stable" --ignore-check "deploy hub" --dry-run
eq "L: a repeated --ignore-check passes over both" 0 "$RC"; contains "L: dry-run says so" "$OUT" "dry-run: would run"

# --- M. publish (issue #2772) ------------------------------------------------------------
# A moved stable is handed to the hub: outside CI the move dispatches stable-publish.yml
# for exactly the target; inside CI (GITHUB_ACTIONS=true — the release train publishes in
# its own step) and for a tree without that workflow, nothing is dispatched.
green; rm -f "$WORK/dispatched"; : > "$WORK/dispatch_to"   # the shim answers 0
mkdir -p "$SEED/.github/workflows"; printf 'name: stable publish\n' > "$SEED/.github/workflows/stable-publish.yml"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'publish workflow'; C17=$(git -C "$SEED" rev-parse HEAD); push
macos_green "$C17" 26
OUT=$(GITHUB_ACTIONS=true sh "$ST" move "$C17" --dir "$CO" --repo o/r 2>&1); RC=$?
eq "M: a move inside CI exits 0" 0 "$RC"; eq "M: tag at C17" "$C17" "$(tag)"
eq "M: inside CI nothing dispatched" no "$([ -f "$WORK/dispatched" ] && echo yes || echo no)"
C18=$(commit eighteen); push; macos_green "$C18" 27
OUT=$(env -u GITHUB_ACTIONS sh "$ST" move "$C18" --dir "$CO" --repo o/r 2>&1); RC=$?
eq "M: a move by hand exits 0" 0 "$RC"; eq "M: tag at C18" "$C18" "$(tag)"
contains "M: dispatched stable-publish.yml for the target" "$(cat "$WORK/dispatched" 2>/dev/null)" "workflow run stable-publish.yml --repo o/r --ref master -f sha=$C18"
contains "M: says so" "$OUT" "publish: dispatched stable-publish.yml"

# --- N. the release train (issue #3141) ----------------------------------------------------
# --precheck: the train's own jobs are its CI, so they are not read — a pending check
# passes; nothing is pushed, dispatched or waited for.
C19=$(commit nineteen); push; : > "$WORK/macos"; rm -f "$WORK/dispatched"
printf 'completed success shard 1\nin_progress null train / precheck\ncompleted failure deploy hub\n' > "$WORK/checks"
run move "$C19" --precheck
eq "N: precheck passes past red CI and no macOS run" 0 "$RC"; contains "N: says no tag pushed" "$OUT" "no tag pushed"
eq "N: precheck moved nothing" "$C18" "$(tag)"
eq "N: precheck dispatched nothing" no "$([ -f "$WORK/dispatched" ] && echo yes || echo no)"
run move "$C17" --precheck
eq "N: precheck still refuses backward" 3 "$RC"; contains "N: says forward" "$OUT" "only moves FORWARD"
printf '{"schema": 2}\n' > "$SEED/release.json"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'bad release.json again'; C20=$(git -C "$SEED" rev-parse HEAD); push
run move "$C20" --precheck
eq "N: precheck refuses a bad release.json" 3 "$RC"; contains "N: reason release:" "$OUT" "REFUSED — release:"
cp "$BIN/../release.json" "$SEED/release.json"
git -C "$SEED" add -A; git -C "$SEED" commit -qm 'release.json back'; C21=$(git -C "$SEED" rev-parse HEAD); push
run move "$C21" --precheck
eq "N: precheck passes once fixed" 0 "$RC"
# The shared matrix's `macOS / shard K` checks are no verdict; a red `mac follow: macOS`
# status holds nothing (one release line, #4671).
printf 'completed success shard 1\nin_progress null macOS / shard 2\n' > "$WORK/checks"; : > "$WORK/macos"
printf 'failure\n' > "$WORK/statuses"; rm -f "$WORK/dispatched"
run move "$C21"
eq "N: a red mac follow holds nothing" 0 "$RC"; eq "N: tag at C21" "$C21" "$(tag)"
case "$OUT" in *"not green: in_progress null macOS / shard 2"*) fail "N: the generic gate counted a train macOS shard" ;; esac
case "$(cat "$WORK/dispatched" 2>/dev/null)" in *selftests-macos*) fail "N: dispatched a full macOS run" ;; esac

# --- O. --train: this run's jobs are the CI (issue #3142) ----------------------------------------
C22=$(commit twentytwo); push; : > "$WORK/macos"; : > "$WORK/statuses"; rm -f "$WORK/dispatched"
printf 'completed failure some derived run\n' > "$WORK/checks"   # never read with --train
printf 'completed success board\ncompleted success Linux / shard 1\nin_progress null hub / deploy\ncompleted success macOS / shard 1\nin_progress null release\n' > "$WORK/jobs"
run move "$C22" --train 77 --ignore-check release
eq "O: an unfinished job refuses" 3 "$RC"; contains "O: names it" "$OUT" "not green: in_progress null hub / deploy"
printf 'in_progress null release\n' > "$WORK/jobs"
run move "$C22" --train 77 --ignore-check release
eq "O: nothing finished refuses" 3 "$RC"; contains "O: says no finished job" "$OUT" "no finished job"
printf 'completed success board\ncompleted success Linux / shard 1\ncompleted skipped hub\ncompleted failure macOS / shard 1\nin_progress null release\n' > "$WORK/jobs"
run move "$C22" --train 77 --ignore-check release
eq "O: an all-green train moves (a red macOS shard is no verdict)" 0 "$RC"; eq "O: tag at C22" "$C22" "$(tag)"
contains "O: says the run" "$OUT" "job(s) of train run 77 green"
case "$(cat "$WORK/dispatched" 2>/dev/null)" in *selftests-macos*) fail "O: dispatched a macOS run past a green train run" ;; esac
run move --train abc
eq "O: --train takes a run id" 2 "$RC"

# --- P. a release workflow's own red run is not the target's CI (issue #3143) ------------------
# One failed publish and one failed move on the target used to block every move after
# them, one --ignore-check name at a time. They are derived from releasing it: passed over.
C23=$(commit twentythree); push; macos_green "$C23" 28; rm -f "$WORK/dispatched"
printf '501 .github/workflows/selftests.yml\n502 .github/workflows/stable-publish.yml\n503 .github/workflows/stable-auto.yml\n504 .github/workflows/release-train.yml\n505 .github/workflows/hub-deploy.yml\n' > "$WORK/derived"
printf '501 completed success shard 1\n502 completed failure publish stable\n503 completed failure move stable\n504 completed failure train\n505 completed cancelled deploy\n' > "$WORK/checks"
run move "$C23" --dry-run
eq "P: derived reds are passed over" 0 "$RC"
contains "P: names the publish it passed over" "$OUT" "passed over (a release workflow's own run): completed failure publish stable"
contains "P: names the move" "$OUT" "completed failure move stable"
contains "P: counts the one real check" "$OUT" "checks: 1 green"
printf '501 completed failure shard 1\n502 completed failure publish stable\n' > "$WORK/checks"
run move "$C23" --dry-run
eq "P: a red test run still refuses" 3 "$RC"; contains "P: names it" "$OUT" "not green: completed failure shard 1"
printf '501 completed success shard 1\n502 completed failure publish stable\n' > "$WORK/checks"
OUT=$(FLEET_STABLE_DERIVED_RE='' sh "$ST" move "$C23" --dry-run --dir "$CO" --repo o/r 2>&1); RC=$?
eq "P: an empty FLEET_STABLE_DERIVED_RE counts every run" 3 "$RC"
OUT=$(FLEET_STABLE_DERIVED_RE='^selftests\.yml$' sh "$ST" move "$C23" --dry-run --dir "$CO" --repo o/r 2>&1); RC=$?
eq "P: FLEET_STABLE_DERIVED_RE names the workflows" 3 "$RC"; contains "P: … the publish counts then" "$OUT" "not green: completed failure publish stable"
: > "$WORK/derived"; green

# --- Q. one release line (issue #4671) ---------------------------------------------------------
# The Mac lane's flags are gone: an unknown flag, nothing pushed.
ltag() { git --git-dir="$BARE" rev-parse -q --verify refs/tags/stable-macos 2>/dev/null || echo none; }
green; : > "$WORK/statuses"; rm -f "$WORK/dispatched"; : > "$WORK/dispatch_to"
S0=$(tag)
for w in "--ref stable-macos" "--seed" "--with-stable" "--macos-timeout 3"; do
  # shellcheck disable=SC2086  # the words are the flags
  run move $w
  eq "Q: $w is an unknown flag" 2 "$RC"
  eq "Q: $w pushed no lane" none "$(ltag)"; eq "Q: $w left stable" "$S0" "$(tag)"
done
eq "Q: nothing dispatched" no "$([ -f "$WORK/dispatched" ] && echo yes || echo no)"
commit twentyfour >/dev/null; push
C25=$(commit twentyfive); push
printf '%s\tcompleted\tfailure\tpush\t32\tselftests (macOS)\n' "$C25" > "$WORK/macos"; printf 'failure\n' > "$WORK/statuses"
run move "$C25"
eq "Q: stable moves past a red macOS" 0 "$RC"; eq "Q: stable at C25" "$C25" "$(tag)"

# --- S. gate 9, the China real-user path (issue #4180) -------------------------------------------
# bin/fleet-cn-probe-watch.sh leaves `cn path` on the stable it walked; red holds stable while
# the breakage issue it names is open. macOS holds nothing, so only gate 9 decides here.
green; S25=$(tag)
C26=$(commit twentysix); push
printf 'failure\thttps://github.com/o/r/issues/77\t不通：卡在 codex:entry — no answer\n' > "$WORK/cnstatus"
printf 'open\n' > "$WORK/cnissue"
run move "$C26"
eq "S: a red China path on stable refuses" 3 "$RC"; contains "S: reason cn:" "$OUT" "REFUSED — cn:"
contains "S: names the layer" "$OUT" "卡在 codex:entry"; contains "S: names the issue" "$OUT" "issues/77"
eq "S: stable untouched" "$S25" "$(tag)"
run move "$C26" --precheck
eq "S: --precheck refuses it too" 3 "$RC"; contains "S: precheck reason cn:" "$OUT" "REFUSED — cn:"
export FLEET_STABLE_CN_GATE=0
run move "$C26" --dry-run
eq "S: FLEET_STABLE_CN_GATE=0 turns it off" 0 "$RC"
unset FLEET_STABLE_CN_GATE
printf 'closed\n' > "$WORK/cnissue"
run move "$C26"
eq "S: its issue closed → the fix ships, stable moves" 0 "$RC"; eq "S: stable at C26" "$C26" "$(tag)"
contains "S: says the issue is closed" "$OUT" "its issue is closed"
C27=$(commit twentyseven); push; printf 'open\n' > "$WORK/cnissue"
OUT=$(FLEET_STABLE_LOG="$WORK/stable-move.log" sh "$ST" move "$C27" --force --dir "$CO" --repo o/r 2>&1); RC=$?
eq "S: --force moves past a red path" 0 "$RC"
contains "S: …and logs cn=" "$(cat "$WORK/stable-move.log" 2>/dev/null)" "	cn=the China real-user path is red"
C28=$(commit twentyeight); push
printf 'success\t-\t通：自动选 entry\n' > "$WORK/cnstatus"
run move "$C28"
eq "S: a green path moves" 0 "$RC"; contains "S: says green" "$OUT" "cn: the China real-user path is green"
C29=$(commit twentynine); push; : > "$WORK/cnstatus"
run move "$C29"
eq "S: no verdict → not gated" 0 "$RC"; contains "S: says no verdict" "$OUT" 'no "cn path" verdict'
# issue #4663: only the product's red holds — env (an invalid test road) and probe (the probe's
# own error) are said and pass, with their issue still open
for cls in '环境无效（cert_expired）：卡在 cert — expired' '检测出错（no_verdict）：卡在 probe — no verdict'; do
  Cx=$(commit "cls-$cls"); push
  printf 'failure\thttps://github.com/o/r/issues/78\t%s\n' "$cls" > "$WORK/cnstatus"; printf 'open\n' > "$WORK/cnissue"
  run move "$Cx"
  eq "S: a red China path of class ${cls%%（*} moves" 0 "$RC"; eq "S: stable moved (${cls%%（*})" "$Cx" "$(tag)"
  contains "S: says it is not the product (${cls%%（*})" "$OUT" "not the product"
done
: > "$WORK/cnstatus"

green

printf 'fleet-stable-selftest OK (%d checks)\n' "$CHECKS"
