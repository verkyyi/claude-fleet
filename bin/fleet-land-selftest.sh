#!/bin/bash
# fleet-land-selftest.sh — a repo the fleet lands itself (issue #3602, EPIC #3570
# C9): bin/fleet-land.sh, and bin/fleet-pr-verdict.sh / bin/fleet-pr-merge.sh
# handing a FLEET_LAND=fleet repo to it — on a local bare origin, with a `gh` on PATH
# that only records and always fails.
#
#   A. check passes: verdict READY, merge MERGED — the base fast-forwards to the
#      branch, one landing record row (ndjson) + fleet_landed's ③, fleet_landed says
#      landed, the pushed branch is deleted on origin
#   B. check fails: verdict FAILING, merge FAILING with the check's last lines, the
#      base does not move, nothing recorded
#   C. two sessions land at once: serialized on the land lease — both MERGED, the
#      second rebased onto the first and checked again; the base is linear
#   D. a conflict: verdict CONFLICT, merge CONFLICT, the rebase aborted, the
#      worktree and the base untouched
#   E. the base moved: verdict BEHIND; merge rebases it and lands
#   F. no FLEET_CHECK_CMD: lands, the record and the note say 没跑检查;
#      FLEET_CHECK_REQUIRED=1 ⇒ BLOCKED; a branch with no worktree lands from a
#      temporary one (removed after)
#   G. the dispatch: pr_verdict / pr_merge's scripts with no PR number on a
#      FLEET_LAND=fleet repo answer from git, `issue-<N>` for a number — gh 0 times
#   H. FLEET_LAND=pr (unset): fleet_repo_land says pr, the PR path is byte for byte
#      what it was (one gh read, READY, the same stderr), no PR number ⇒ the same
#      refusal, fleet-land.sh never runs
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v git >/dev/null 2>&1 || { echo 'selftest: git missing — SKIP' >&2; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/land-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '     %s\n' "$2" >&2; fails=$((fails + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

mkdir -p "$WORK/fake"
cat > "$WORK/fake/gh" <<'GH'
#!/bin/sh
echo "gh $*" >> "$GHLOG"; exit 1
GH
chmod +x "$WORK/fake/gh"
export GHLOG="$WORK/gh.log"; : > "$GHLOG"
export PATH="$WORK/fake:$PATH"
export FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp" LAND_LEASE_DIR="$WORK/leases" FLEET_HEAVY=0
mkdir -p "$FLEET_CONF_DIR" "$TMPDIR"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset FLEET_SESSION TMUX TMUX_PANE CF_REPO FLEET_REPO
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

git init -q --bare -b main "$WORK/origin.git" 2>/dev/null || git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/main" 2>/dev/null
M="$WORK/main"; g() { git -C "$M" "$@"; }
g checkout -q -B main
printf 'one\n' > "$M/base.txt"; g add base.txt; g commit -q -m base; g push -q origin main

CONF="$FLEET_CONF_DIR/fleets/fl/repos/acme-app.conf"
mkdir -p "$(dirname "$CONF")"; : > "$FLEET_CONF_DIR/fleets/fl/conf"
setconf() {  # setconf [KEY=VALUE …] — the repo overlay, FLEET_LAND=fleet + the given keys
  { printf 'FLEET_REPO="acme/app"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$M"
    printf 'FLEET_REMOTE="%s"\nFLEET_FORGE="none"\nFLEET_LAND="fleet"\n' "$WORK/origin.git"
    for kv in "$@"; do printf '%s\n' "$kv"; done; } > "$CONF"
}
# a check that fails when the tree carries a file named BAD
setconf "FLEET_CHECK_CMD='test ! -e BAD || { echo BAD is here; exit 1; }'"

# wt <issue> — a worker worktree on issue-<N> off origin/main
wt() { g fetch -q origin main; g worktree add -q -b "issue-$1" "$WORK/wt-$1" origin/main 2>/dev/null; }
work() { printf '%s\n' "$3" >> "$WORK/wt-$1/$2"; git -C "$WORK/wt-$1" add "$2"; git -C "$WORK/wt-$1" commit -q -m "$2 $3"; }
land() { "$BIN/fleet-land.sh" "$@" 2>"$WORK/err"; }
head_main() { git -C "$WORK/origin.git" rev-parse main; }
rows() { [ -f "$FLEET_CONF_DIR/landed/acme-app.ndjson" ] && wc -l < "$FLEET_CONF_DIR/landed/acme-app.ndjson" | tr -d ' ' || echo 0; }

# --- A: a passing check lands -----------------------------------------------------
wt 1; work 1 a.txt hello; git -C "$WORK/wt-1" push -q origin issue-1
tip=$(git -C "$WORK/wt-1" rev-parse HEAD)
expect 'A verdict READY'               "$(land --verdict acme/app issue-1)" READY
expect 'A merge MERGED'                "$(land acme/app issue-1)" MERGED
expect 'A the base fast-forwarded'     "$(head_main)" "$tip"
expect 'A one landing record'          "$(rows)" 1
grep -q '"check":"pass"' "$FLEET_CONF_DIR/landed/acme-app.ndjson" && ok 'A record says pass' || bad 'A record says pass' "$(cat "$FLEET_CONF_DIR/landed/acme-app.ndjson")"
expect 'A fleet_landed ③ / ① landed'   "$(FLEET_SESSION=fl fleet_landed acme/app issue-1 | cut -d' ' -f1-2)" "landed $tip"
git -C "$WORK/origin.git" rev-parse -q --verify refs/heads/issue-1 >/dev/null \
  && bad 'A the pushed branch is deleted on origin' || ok 'A the pushed branch is deleted on origin'
expect 'A a re-run is MERGED'          "$(land acme/app issue-1)" MERGED
expect 'A no second record'            "$(rows)" 1

# --- B: a failing check never lands -----------------------------------------------
wt 2; work 2 BAD x; b0=$(head_main)
expect 'B verdict FAILING'             "$(land --verdict acme/app issue-2)" FAILING
expect 'B merge FAILING'               "$(land acme/app issue-2)" FAILING
grep -q '| BAD is here' "$WORK/err" && ok 'B the check output reaches the session' || bad 'B the check output reaches the session' "$(cat "$WORK/err")"
expect 'B the base did not move'       "$(head_main)" "$b0"
expect 'B nothing recorded'            "$(rows)" 1

# --- C: two landings at once serialize --------------------------------------------
setconf "FLEET_CHECK_CMD='sleep 2; test ! -e BAD'"
wt 3; work 3 c3.txt x; wt 4; work 4 c4.txt y
"$BIN/fleet-land.sh" acme/app issue-3 > "$WORK/c3" 2>"$WORK/c3.err" &
p3=$!
"$BIN/fleet-land.sh" acme/app issue-4 > "$WORK/c4" 2>"$WORK/c4.err" &
p4=$!
wait "$p3"; wait "$p4"
expect 'C both MERGED'                 "$(cat "$WORK/c3" "$WORK/c4" | tr '\n' ' ')" 'MERGED MERGED '
git -C "$WORK/origin.git" cat-file -e main:c3.txt 2>/dev/null && git -C "$WORK/origin.git" cat-file -e main:c4.txt 2>/dev/null \
  && ok 'C both changes are on the base' || bad 'C both changes are on the base'
expect 'C the base is linear'          "$(git -C "$WORK/origin.git" rev-list --merges main | wc -l | tr -d ' ')" 0
grep -q 'rebased' "$WORK/c3.err" "$WORK/c4.err" && ok 'C the second was rebased onto the first' \
  || bad 'C the second was rebased onto the first' "$(cat "$WORK/c3.err" "$WORK/c4.err")"
expect 'C three landing records'       "$(rows)" 3
setconf "FLEET_CHECK_CMD='test ! -e BAD'"

# --- D: a conflict hands back to the session --------------------------------------
wt 5; work 5 base.txt mine; wt 6; work 6 base.txt theirs
expect 'D (theirs lands first)'        "$(land acme/app issue-6)" MERGED
b0=$(head_main); t5=$(git -C "$WORK/wt-5" rev-parse HEAD)
expect 'D verdict CONFLICT'            "$(land --verdict acme/app issue-5)" CONFLICT
expect 'D merge CONFLICT'              "$(land acme/app issue-5)" CONFLICT
expect 'D the worktree is untouched'   "$(git -C "$WORK/wt-5" rev-parse HEAD) $(git -C "$WORK/wt-5" status --porcelain | wc -l | tr -d ' ')" "$t5 0"
[ -d "$(git -C "$WORK/wt-5" rev-parse --git-dir)/rebase-merge" ] && bad 'D the rebase was aborted' || ok 'D the rebase was aborted'
expect 'D the base did not move'       "$(head_main)" "$b0"
wt 7; work 7 d7.txt x; printf 'dirty\n' >> "$WORK/wt-7/d7.txt"
expect 'D uncommitted changes: CONFLICT' "$(land acme/app issue-7)" CONFLICT
git -C "$WORK/wt-7" checkout -q -- d7.txt

# --- E: the base moved — BEHIND, and the merge rebases ----------------------------
wt 8; work 8 e8.txt x; wt 9; work 9 e9.txt y
expect 'E (another lands first)'       "$(land acme/app issue-9)" MERGED
expect 'E verdict BEHIND'              "$(land --verdict acme/app issue-8)" BEHIND
expect 'E merge MERGED'                "$(land acme/app issue-8)" MERGED
expect 'E the base holds both'         "$(git -C "$WORK/origin.git" ls-tree --name-only main | grep -c '^e[89].txt$')" 2
expect 'E the worktree is on the base' "$(git -C "$WORK/wt-8" rev-parse HEAD)" "$(head_main)"

# --- F: no check registered; required; no worktree ---------------------------------
setconf
expect 'F (issue-7) lands with no check' "$(land acme/app issue-7)" MERGED
grep -q '没跑检查' "$WORK/err" && ok 'F the note says 没跑检查' || bad 'F the note says 没跑检查' "$(cat "$WORK/err")"
tail -n 1 "$FLEET_CONF_DIR/landed/acme-app.ndjson" | grep -q '"check":"none"' && ok 'F the record says none' \
  || bad 'F the record says none' "$(tail -n 1 "$FLEET_CONF_DIR/landed/acme-app.ndjson")"
setconf 'FLEET_CHECK_REQUIRED=1'
wt 10; work 10 f10.txt x
expect 'F required + none: verdict BLOCKED' "$(land --verdict acme/app issue-10)" BLOCKED
expect 'F required + none: merge BLOCKED'   "$(land acme/app issue-10)" BLOCKED
setconf "FLEET_CHECK_CMD='test ! -e BAD'"
g worktree remove --force "$WORK/wt-10"
expect 'F no worktree: MERGED'         "$(land acme/app issue-10)" MERGED
expect 'F the temp worktree is gone'   "$(g worktree list | grep -c fleet-land)" 0
git -C "$WORK/origin.git" cat-file -e main:f10.txt 2>/dev/null && ok 'F f10 is on the base' || bad 'F f10 is on the base'

# --- G: the dispatch — no PR, no gh -------------------------------------------------
expect 'G fleet_repo_land fleet'       "$(fleet_repo_land acme/app fl)" fleet
wt 11; work 11 g11.txt x
out=$(cd "$WORK/wt-11" && FLEET_SESSION=fl "$BIN/fleet-pr-verdict.sh" --repo acme/app 2>/dev/null); rc=$?
expect 'G pr_verdict (no pr, cwd branch) READY' "$out $rc" 'READY 0'
out=$(FLEET_SESSION=fl "$BIN/fleet-pr-verdict.sh" 11 --repo acme/app --wait 2>/dev/null)
expect 'G pr_verdict 11 --wait → issue-11 READY' "$out" READY
out=$(cd "$WORK/wt-11" && FLEET_SESSION=fl "$BIN/fleet-pr-merge.sh" --repo acme/app 2>/dev/null); rc=$?
expect 'G pr_merge (no pr) MERGED'     "$out $rc" 'MERGED 0'
out=$(FLEET_SESSION=fl "$BIN/fleet-pr-merge.sh" 11 --repo acme/app 2>/dev/null)
expect 'G pr_merge 11 again MERGED'    "$out" MERGED
expect 'G gh called 0 times'           "$(wc -l < "$GHLOG" | tr -d ' ')" 0

# --- H: FLEET_LAND=pr — byte for byte --------------------------------------------
P="$FLEET_CONF_DIR/fleets/fl/repos/acme-old.conf"
printf 'FLEET_REPO="acme/old"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$M" > "$P"
expect 'H fleet_repo_land pr (unset)'  "$(fleet_repo_land acme/old fl)" pr
expect 'H fleet_repo_land pr (no conf)' "$(fleet_repo_land other/repo fl)" pr
cat > "$WORK/fake/gh" <<'GH'
#!/bin/sh
echo "gh $*" >> "$GHLOG"
case "$*" in *"pr view 12"*) printf 'OPEN\nMERGEABLE\nCLEAN\n\npass\n\n'; exit 0 ;; esac
exit 1
GH
: > "$GHLOG"; ln0=$(rows)
out=$(FLEET_SESSION=fl "$BIN/fleet-pr-verdict.sh" 12 --repo acme/old 2>"$WORK/h.err"); rc=$?
expect 'H PR path: READY exit 0'       "$out $rc" 'READY 0'
expect 'H PR path: the same stderr'    "$(cat "$WORK/h.err")" 'fleet-pr-verdict: #12 is green + mergeable — merge it'
expect 'H PR path: one gh read'        "$(grep -c 'pr view 12' "$GHLOG")" 1
out=$(FLEET_SESSION=fl "$BIN/fleet-pr-verdict.sh" --repo acme/old 2>&1); rc=$?
expect 'H no PR number: the same refusal' "$out $rc" 'fleet-pr-verdict: a PR number is required 2'
out=$(FLEET_SESSION=fl "$BIN/fleet-pr-merge.sh" --repo acme/old 2>&1); rc=$?
expect 'H merge, no PR number: the same refusal' "$out $rc" 'fleet-pr-merge: a PR number is required 2'
expect 'H fleet-land.sh never ran'     "$(rows)" "$ln0"

[ "$fails" -eq 0 ] || { printf 'fleet-land-selftest: %d FAILED\n' "$fails" >&2; exit 1; }
printf 'fleet-land-selftest: all passed\n'
