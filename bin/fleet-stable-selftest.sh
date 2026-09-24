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

# gh shim: `gh api …/check-runs --jq …` → the lines in $WORK/checks.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
cat "$WORK/checks"
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

printf 'fleet-stable-selftest OK (%d checks)\n' "$CHECKS"
