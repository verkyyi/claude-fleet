#!/bin/bash
# fleet-landed-selftest.sh — "did the work land?" is git's to say (issue #3601,
# EPIC #3570 C8): fleet_land_check / fleet_landed (bin/fleet-lib.sh) on real git
# repos with a bare origin, and a `gh` on PATH that only records and always fails.
#
#   A. the four landings each read `landed <sha> <epoch>`: a fast-forward (the tip),
#      a merge commit (the merge), a squash (the squash commit), a rebase-merge with
#      rewritten commits (the tip's twin)
#   B. `open`: a branch changed again after its squash landed; a branch just cut from
#      the base (tip == base); an unpushed branch with work of its own
#   C. fleet_landed: fetches origin, caches per (repo, tip), rc 2 when the remote
#      cannot be fetched, a booked landing (fleet_landed_note) is landed; gh 0 times
#   D. fleet_reap_ok: a squash with no merged-PR answer is `landed` (rc 0); the
#      merged-PR / ancestor / unmerged answers are byte for byte what they were
#   E. dash-reap.sh on a squash-merged session with every gh call failing: the ⌃x
#      verdict is `landed`, reaped with no confirm (the issue's 上线证据)
#   F. FLEET_FORGE=none: fleet_repo_forge, the 「已合并」 check, fleet-cleanup.sh
#      --branch and the history row answer from git — gh 0 times
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v git >/dev/null 2>&1 || { echo 'selftest: git missing — SKIP' >&2; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/landed-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '     %s\n' "$2" >&2; fails=$((fails + 1)); }
expect() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

# a gh that records every call and always fails (the 共同约定 3 stub)
mkdir -p "$WORK/fake"
cat > "$WORK/fake/gh" <<'GH'
#!/bin/sh
echo "gh $*" >> "$GHLOG"; exit 1
GH
chmod +x "$WORK/fake/gh"
export GHLOG="$WORK/gh.log"; : > "$GHLOG"
export PATH="$WORK/fake:$PATH"
export FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp"; mkdir -p "$FLEET_CONF_DIR" "$TMPDIR"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset FLEET_SESSION
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

git init -q --bare -b main "$WORK/origin.git" 2>/dev/null || git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/dev" 2>/dev/null
D="$WORK/dev"; g() { git -C "$D" "$@"; }
g checkout -q -B main
commit() { printf '%s\n' "$2" >> "$D/$1"; g add "$1"; g commit -q -m "$1: $2"; }
commit base.txt one; g push -q origin main
br() { g checkout -q -B "$1" main; }

# A1 fast-forward
br ff; commit ff.txt a; commit ff.txt b; tip_ff=$(g rev-parse HEAD)
g checkout -q main; g merge -q --ff-only ff; commit base.txt after-ff
# A2 merge commit
br mc; commit mc.txt a; tip_mc=$(g rev-parse HEAD)
g checkout -q main; g merge -q --no-ff -m 'merge mc' mc; m_mc=$(g rev-parse HEAD)
# A3 squash, base moved on after the fork
br sq; commit sq.txt a; commit sq.txt b; tip_sq=$(g rev-parse HEAD)
g checkout -q main; commit base.txt before-sq; g merge -q --squash sq >/dev/null 2>&1; g commit -q -m 'squash sq'; s_sq=$(g rev-parse HEAD)
# A4 rebase-merge: both commits rewritten onto a moved base
br rb; commit rb1.txt a; commit rb2.txt b; tip_rb=$(g rev-parse HEAD)
g checkout -q main; commit base.txt before-rb
g cherry-pick "$tip_rb~1" "$tip_rb" >/dev/null; r_rb=$(g rev-parse HEAD)
# B1 squash landed, then the branch moved on
br sq2; commit sq2.txt a; g checkout -q main; g merge -q --squash sq2 >/dev/null 2>&1; g commit -q -m 'squash sq2'
g checkout -q sq2; commit sq2.txt more; tip_sq2=$(g rev-parse HEAD)
g checkout -q main; g push -q origin main
# B2 fresh branch; B3 own unlanded work
br fresh; tip_fresh=$(g rev-parse HEAD)
br wip; commit wip.txt a; tip_wip=$(g rev-parse HEAD)
g checkout -q main

lc() { fleet_land_check "$D" "$1" origin/main | cut -d' ' -f1-2; }
expect 'A1 fast-forward → landed at the tip'        "$(lc "$tip_ff")" "landed $tip_ff"
expect 'A2 merge commit → landed at the merge'      "$(lc "$tip_mc")" "landed $m_mc"
expect 'A3 squash → landed at the squash commit'    "$(lc "$tip_sq")" "landed $s_sq"
expect 'A4 rebase-merge → landed at the tip twin'   "$(lc "$tip_rb")" "landed $r_rb"
ep=$(fleet_land_check "$D" "$tip_sq" origin/main | cut -d' ' -f3)
expect 'A  epoch is the landing commit time'        "$ep" "$(g log -1 --format=%ct "$s_sq")"
expect 'B1 changed after its squash → open'          "$(lc "$tip_sq2")" open
expect 'B2 tip == base → open'                       "$(lc "$tip_fresh")" open
expect 'B3 own work, not landed → open'              "$(lc "$tip_wip")" open
fleet_land_check "$D" "$tip_wip" origin/main >/dev/null; expect 'B  open is rc 1' "$?" 1

# C fleet_landed: the repo's checkout + base named, origin fetched
expect 'C1 squash by branch name'  "$(fleet_landed o/r sq "$D" main | cut -d' ' -f1-2)" "landed $s_sq"
if grep -q "^$tip_sq	" "$FLEET_C/global/landed-o-r.tsv" 2>/dev/null; then ok 'C2 verdict cached per (repo, tip)'
else bad 'C2 verdict cached per (repo, tip)'; fi
expect 'C3 wip by sha → open'      "$(fleet_landed o/r "$tip_wip" "$D" main)" open
g remote set-url origin "$WORK/nowhere.git"
out=$(FLEET_LANDED_FETCH_SECS=0 fleet_landed o/r sq "$D" main); rc=$?
expect 'C4 remote gone → rc 2, nothing printed' "$rc:$out" "2:"
g remote set-url origin "$WORK/origin.git"
fleet_landed_note o/r fresh "$tip_fresh" "$tip_fresh" 1700000000
expect 'C5 booked landing (③) → landed'  "$(fleet_land_check "$D" "$tip_fresh" origin/main)" "landed $tip_fresh 1700000000"
expect 'C6 gh called 0 times'            "$(wc -l < "$GHLOG" | tr -d ' ')" 0

# D fleet_reap_ok, no fleet sockets (no liveness probe)
fleet_sockets() { :; }
wt() { g worktree add -q "$WORK/wt-$1" "$1" 2>/dev/null; printf '%s' "$WORK/wt-$1"; }
expect 'D1 squash, no PR answer → landed' "$(fleet_reap_ok "$(wt sq)" "$D" sq "$tip_sq" origin/main "")" landed
fleet_reap_ok "$WORK/wt-sq" "$D" sq "$tip_sq" origin/main "" >/dev/null; expect 'D1 rc 0' "$?" 0
expect 'D2 merged PR answer unchanged' "$(fleet_reap_ok "$WORK/wt-sq" "$D" sq "$tip_sq" origin/main "sq $tip_sq")" merged-pr
expect 'D3 ancestor unchanged'          "$(fleet_reap_ok "$(wt ff)" "$D" ff "$tip_ff" origin/main "")" ancestor
expect 'D4 unmerged unchanged'          "$(fleet_reap_ok "$(wt wip)" "$D" wip "$tip_wip" origin/main "")" unmerged
expect 'D5 moved on after squash → unmerged' "$(fleet_reap_ok "$(wt sq2)" "$D" sq2 "$tip_sq2" origin/main "")" unmerged

# E dash-reap.sh (the 上线证据): a squash-merged session, every gh call failing —
# the ⌃x verdict is `landed` and it reaps straight away, with no y/n.
mkdir -p "$WORK/fakepath" "$WORK/rt"
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
case "$*" in
  run-shell*) shift; [ "${1:-}" = -b ] && shift; sh -c "$1" ;;
  *'#{@claude_state}'*) echo done ;;
  *'#{pane_pid}'*) echo "$PPID" ;;
  *list-clients*) ;;
  *@issue*) echo 9 ;;
  *@raw*|*@reap_hold*|*@worker_lifecycle*|*@fleet_id*|*@worktree*|*pane_current_path*) echo ;;
  *window_id*) [ -e "$TMLOG.killed" ] && exit 1; echo @9 ;;
  *session_name*) echo s1 ;;
  *window_name*) echo worker ;;
  *kill-window*) : > "$TMLOG.killed" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"
g checkout -q -B issue-9 main~0 2>/dev/null; g reset -q --hard "$(g rev-parse main)"
commit e9.txt a; commit e9.txt b; tip_e9=$(g rev-parse HEAD)
g checkout -q main; commit base.txt before-e9; g merge -q --squash issue-9 >/dev/null 2>&1; g commit -q -m 'squash (#9)'
g push -q origin main; g fetch -q origin
g worktree add -q "$WORK/wt-e9" issue-9 2>/dev/null
: > "$GHLOG"
tok=$(ISS=9 TMLOG="$WORK/tmlog" FLEET_REPO=o/r FLEET_MAIN="$D" FLEET_BASE_BRANCH=main \
  FLEET_CONF_DIR="$WORK/noconf" TMPDIR="$WORK/rt" FLEET_HISTORY_LEDGER="$WORK/hist.tsv" \
  CLAUDE_PROJECTS_DIR="$WORK/projects" PATH="$WORK/fakepath:$PATH" \
  bash "$BIN/dash-reap.sh" @9 2>"$WORK/reap.err")
grep -o 'reason=[a-z-]*' "$WORK/reap.err" | sort -u > "$WORK/reason" 2>/dev/null
expect 'E1 dash-reap: squash + gh failing → reason=landed' "$(cat "$WORK/reason")" reason=landed
expect 'E2 dash-reap: reaps with no confirm'                "$tok" reaped:full
[ ! -d "$WORK/wt-e9" ] && ok 'E3 worktree removed' || bad 'E3 worktree removed'
[ -n "${LANDED_EVIDENCE:-}" ] && { cat "$WORK/reap.err"; echo "token: $tok"; } > "$LANDED_EVIDENCE"

# F a repo with no GitHub (FLEET_FORGE=none): the history row, the 「已合并」 check
# and the branch-keyed janitor all answer from git, and gh runs 0 times.
mkdir -p "$FLEET_CONF_DIR/fleets/fl/repos"; : > "$FLEET_CONF_DIR/fleets/fl/conf"
printf 'FLEET_REPO=o/r\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=main\nFLEET_FORGE=none\n' "$D" > "$FLEET_CONF_DIR/fleets/fl/repos/o-r.conf"
expect 'F1 FLEET_FORGE=none read per repo' "$(fleet_repo_forge fl o/r)" none
expect 'F2 an unset forge is github'       "$(fleet_repo_forge fl other/x)" github
: > "$GHLOG"
expect 'F3 「已合并」 by git: squash → merged' "$(FLEET_SESSION=fl fleet_pr_merge_state o/r '' sq)" merged
expect 'F4 「已合并」 by git: wip → open'      "$(FLEET_SESSION=fl fleet_pr_merge_state o/r '' wip)" open
g checkout -q -B issue-11 main; commit f11.txt a; tip_11=$(g rev-parse HEAD)
g checkout -q main; commit base.txt before-11; g merge -q --squash issue-11 >/dev/null 2>&1; g commit -q -m 'squash 11'
s_11=$(g rev-parse HEAD); g push -q origin main
g worktree add -q "$WORK/wt-11" issue-11 2>/dev/null
out=$(FLEET_SESSION=fl FLEET_LANDED_FETCH_SECS=0 bash "$BIN/fleet-cleanup.sh" --branch issue-11 --repo o/r --dry-run 2>"$WORK/cl.err")
case "$out" in error:*|'') bad 'F5 fleet-cleanup --branch reads the landing from git' "$out $(tail -2 "$WORK/cl.err")" ;;
  *) grep -q 'state=MERGED' "$WORK/cl.err" && ok "F5 fleet-cleanup --branch: MERGED from git ($out)" \
       || bad 'F5 fleet-cleanup --branch reads the landing from git' "$(tail -3 "$WORK/cl.err")" ;; esac
expect 'F6 fleet-cleanup by PR on a forge-none repo refuses' \
  "$(FLEET_SESSION=fl bash "$BIN/fleet-cleanup.sh" 12 --repo o/r --dry-run 2>/dev/null)" error:no-forge
export FLEET_HISTORY_LEDGER="$WORK/hist-f.tsv" CLAUDE_PROJECTS_DIR="$WORK/projects"
mkdir -p "$CLAUDE_PROJECTS_DIR/$(printf '%s' "$WORK/wt-11" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
: > "$CLAUDE_PROJECTS_DIR/$(printf '%s' "$WORK/wt-11" | LC_ALL=C tr -c 'A-Za-z0-9' '-')/sess-11.jsonl"
fleet_reap_record landed o/r "$D" 11 "$WORK/wt-11" "" fl "" issue-11 "t" >/dev/null
expect 'F7 history row: landed, sha = the squash commit' \
  "$(awk -F'\t' '$2=="11"{print $10, $5}' "$FLEET_HISTORY_LEDGER" 2>/dev/null)" "landed $s_11"
expect 'F8 gh called 0 times on a forge-none repo' "$(wc -l < "$GHLOG" | tr -d ' ')" 0

[ "$fails" = 0 ] || { printf 'fleet-landed-selftest: %s failed\n' "$fails" >&2; exit 1; }
echo 'fleet-landed-selftest: all pass'
