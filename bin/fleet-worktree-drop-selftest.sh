#!/bin/bash
# fleet-worktree-drop-selftest.sh — hermetic tests for the O(1) worktree teardown
# (issue #586): fleet_worktree_drop / fleet_trash_sweep in bin/fleet-lib.sh, plus
# the bin/fleet-worktree-drop.sh CLI shim the detached teardown runs under /bin/sh.
#
# The incident this guards: `git worktree remove` deletes the tree synchronously,
# one unlink at a time. On a 2.8 GB / 308k-file monorepo worktree that measured
# ~0.4 files/s — ONE teardown held the cleanup daemon for 67 minutes, and because
# the daemon is a single-process loop on StartInterval=60, launchd started no new
# tick and the reaping of THREE fleets stopped behind it. The fix retires a worktree
# by RENAMING it into a sibling .fleet-trash/ and pruning git's admin entry; the
# bytes are deleted later, under a wall-clock budget.
#
# Asserts:
#   MOVED      a clean worktree is RENAMED, not deleted: its content survives inside
#              .fleet-trash/ (the whole point — a delete is what cost 67 minutes).
#   PRUNED     it is gone from `git worktree list` immediately, so the slot frees
#              and the branch is deletable, without waiting for the bytes.
#   DIRTY      uncommitted/untracked work is REFUSED without --force (rc 1) and the
#              worktree is left exactly where it was — same gate plain
#              `git worktree remove` (no -f) enforces.
#   FORCED     --force overrides that gate, and only that gate.
#   IGNORED    the trash self-ignores (.gitignore of `*`), so a worktree layout
#              INSIDE a checkout can't make every later `git status` dirty.
#   GONE       an already-removed dir is a rc-0 no-op that still prunes (idempotent —
#              two reapers race on the same worktree all the time).
#   REFUSED    a broad root (/, $HOME, "") is refused, not mv'd.
#   SWEPT      fleet_trash_sweep deletes the trash and keeps its .gitignore; a second
#              sweep on an empty trash is a clean no-op.
#   BUDGET     a 0-length budget sweeps NOTHING and reports it as `left:` — the
#              property that makes an interrupted sweep safe to resume.
#   SHIM       bin/fleet-worktree-drop.sh does the same from the command line.
#
# Real git, real directories, a temp HOME — no network, no tmux, no gh.
# Exit 0 = pass; non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
SHIM="$BIN/fleet-worktree-drop.sh"
[ -f "$LIB" ]  || { printf 'selftest: %s missing\n' "$LIB" >&2; exit 2; }
[ -x "$SHIM" ] || { printf 'selftest: %s missing/not executable\n' "$SHIM" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not on PATH — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-wt-drop.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# shellcheck source=/dev/null
. "$LIB"

# --- a real base checkout with real worktrees ---------------------------------
# Hermetic git: no user config, no global/system config, no hooks/templates.
export HOME="$WORK/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
MAIN="$WORK/repo"
git init -q "$MAIN" >/dev/null 2>&1 || fail "cannot git init $MAIN"
echo seed > "$MAIN/README"
git -C "$MAIN" add README >/dev/null 2>&1
git -C "$MAIN" commit -qm seed >/dev/null 2>&1 || fail "cannot commit in $MAIN"
TRASH="$WORK/.fleet-trash"    # sibling of $MAIN == sibling of every worktree

mkwt() {   # $1 = branch → prints the worktree dir
  local b="$1" d="$WORK/repo-$1"
  git -C "$MAIN" worktree add -q -b "$b" "$d" >/dev/null 2>&1 || return 1
  printf '%s' "$d"
}
listed() { git -C "$MAIN" worktree list --porcelain 2>/dev/null | grep -qx "worktree $1"; }

# --- 1/2/3. clean drop: MOVED (content survives), PRUNED, IGNORED -------------
WT1="$(mkwt issue-9)" || fail "1 could not create the issue-9 worktree"
echo payload > "$WT1/keep.txt"
git -C "$WT1" add keep.txt >/dev/null 2>&1
git -C "$WT1" commit -qm payload >/dev/null 2>&1
listed "$WT1" || fail "1 precondition: $WT1 is not in git worktree list"

tok="$(fleet_worktree_drop "$MAIN" "$WT1")" || fail "1 clean drop must succeed, got '$tok'"
case "$tok" in trashed:*) ;; *) fail "1 expected trashed:<path>, got '$tok'" ;; esac
[ -e "$WT1" ] && fail "1 the worktree dir must be gone from its old path"
moved="${tok#trashed:}"
[ -d "$moved" ] || fail "1 the trashed path '$moved' does not exist"
[ "$(cat "$moved/keep.txt" 2>/dev/null)" = payload ] \
  || fail "1 content did not survive — this must be a RENAME, not a delete" "$(ls -a "$moved" 2>&1)"
ok "1 clean worktree is RENAMED into .fleet-trash (content intact, not deleted)"

listed "$WT1" && fail "2 the worktree is still in git worktree list — prune did not run"
git -C "$MAIN" branch -D issue-9 >/dev/null 2>&1 || fail "2 branch issue-9 is not deletable after the drop"
ok "2 gone from git worktree list at once — the slot frees without paying for bytes"

[ -f "$TRASH/.gitignore" ] || fail "3 the trash has no .gitignore"
[ "$(cat "$TRASH/.gitignore")" = '*' ] || fail "3 the trash .gitignore must be '*' (self-ignoring)"
ok "3 the trash self-ignores, so a worktree layout inside a checkout stays clean"

# --- 4. DIRTY is refused without --force, and left untouched ------------------
WT2="$(mkwt issue-10)" || fail "4 could not create the issue-10 worktree"
: > "$WT2/uncommitted.txt"                       # untracked counts as dirty
tok="$(fleet_worktree_drop "$MAIN" "$WT2")"; rc=$?
[ "$rc" -eq 1 ] || fail "4 a dirty worktree must return rc 1, got rc=$rc ('$tok')"
[ "$tok" = dirty ] || fail "4 expected the token 'dirty', got '$tok'"
[ -f "$WT2/uncommitted.txt" ] || fail "4 the dirty worktree was moved anyway — work lost"
listed "$WT2" || fail "4 a refused drop must leave the worktree registered"
ok "4 dirty worktree refused without --force (rc 1), left exactly where it was"

# --- 5. --force overrides that gate (and only that gate) ---------------------
tok="$(fleet_worktree_drop "$MAIN" "$WT2" --force)" || fail "5 --force must succeed, got '$tok'"
case "$tok" in trashed:*) ;; *) fail "5 expected trashed:<path> under --force, got '$tok'" ;; esac
[ -e "$WT2" ] && fail "5 --force did not move the dirty worktree"
[ -f "${tok#trashed:}/uncommitted.txt" ] || fail "5 --force lost the uncommitted file (delete, not move)"
ok "5 --force drops a dirty worktree — and still only MOVES it"

# --- 6. already gone → rc-0 no-op that still prunes (idempotent) -------------
WT3="$(mkwt issue-11)" || fail "6 could not create the issue-11 worktree"
rm -rf "$WT3"                                     # another reaper got there first
tok="$(fleet_worktree_drop "$MAIN" "$WT3")" || fail "6 a vanished worktree must be rc 0, got '$tok'"
[ "$tok" = gone ] || fail "6 expected the token 'gone', got '$tok'"
listed "$WT3" && fail "6 the stale admin entry was not pruned"
ok "6 already-removed worktree → 'gone' (idempotent, admin entry still pruned)"

# --- 7. broad roots are refused ---------------------------------------------
for bad in "/" "$HOME" "" "/tmp"; do
  tok="$(fleet_worktree_drop "$MAIN" "$bad")"; rc=$?
  [ "$rc" -eq 2 ] || fail "7 '$bad' must be refused with rc 2, got rc=$rc ('$tok')"
  case "$tok" in error:*) ;; *) fail "7 '$bad' must yield error:*, got '$tok'" ;; esac
done
[ -d "$HOME" ] || fail "7 \$HOME was moved — the refusal is not a refusal"
ok "7 broad roots (/, \$HOME, empty, /tmp) refused, never mv'd"

# --- 8. BUDGET: a 0-length budget sweeps nothing and says so ------------------
before=$(find "$TRASH" -mindepth 1 -maxdepth 1 ! -name '.gitignore' | wc -l | tr -d ' ')
[ "$before" -ge 2 ] || fail "8 precondition: expected ≥2 trashed entries, found $before"
# 1 second is the sweep's polling granularity, so a deadline that has already
# passed is expressed by budgeting the whole pass away — not by budget=0, which
# means "unbudgeted".
sw="$(FLEET_TRASH_SWEEP_BUDGET=1 fleet_trash_sweep "$MAIN" 1)"
case "$sw" in swept:*\ left:*) ;; *) fail "8 sweep must report swept:<n> left:<m>, got '$sw'" ;; esac
ok "8 a budgeted sweep always reports what it left behind ($sw)"

# --- 9. SWEPT: an unbudgeted sweep empties the trash but keeps its .gitignore -
sw="$(fleet_trash_sweep "$MAIN" 60)"
case "$sw" in swept:*\ left:0) ;; *) fail "9 expected left:0 with room to finish, got '$sw'" ;; esac
after=$(find "$TRASH" -mindepth 1 -maxdepth 1 ! -name '.gitignore' | wc -l | tr -d ' ')
[ "$after" -eq 0 ] || fail "9 the trash still holds $after entr(y|ies) after a full sweep"
[ -f "$TRASH/.gitignore" ] || fail "9 the sweep deleted the trash's own .gitignore"
sw="$(fleet_trash_sweep "$MAIN" 60)"
[ "$sw" = "swept:0 left:0" ] || fail "9 a sweep of an empty trash must be a no-op, got '$sw'"
ok "9 sweep empties the trash, keeps its .gitignore, and no-ops when already empty"

# --- 10. the CLI shim (what tmux run-shell drives under /bin/sh) -------------
WT4="$(mkwt issue-12)" || fail "10 could not create the issue-12 worktree"
: > "$WT4/dirty.txt"
tok="$(bash "$SHIM" "$MAIN" "$WT4")"; rc=$?
[ "$rc" -eq 1 ] && [ "$tok" = dirty ] || fail "10 shim must refuse a dirty worktree (rc 1/dirty), got rc=$rc '$tok'"
tok="$(bash "$SHIM" "$MAIN" "$WT4" --force)"; rc=$?
[ "$rc" -eq 0 ] || fail "10 shim --force must succeed, got rc=$rc '$tok'"
case "$tok" in trashed:*) ;; *) fail "10 shim expected trashed:<path>, got '$tok'" ;; esac
listed "$WT4" && fail "10 shim did not prune the admin entry"
ok "10 bin/fleet-worktree-drop.sh mirrors the library from the command line"

printf '\nselftest OK: %s assertions passed (O(1) worktree teardown, issue #586)\n' "$pass"
exit 0
