#!/bin/bash
# fleet-gh-selftest.sh — bin/fleet-gh.sh reads the local copy first (issue #1263,
# EPIC #1262 C3).
#
#   CACHE   a fresh collector issues/labels cache or pr-refresh prmap answers with
#           ZERO gh calls (a PATH shim counts them), `_source: cache` + `_age`.
#   SNAP    the spawn snapshot of this worktree's issue serves body/comments.
#   MISS    stale (file mtime past --max-age), a field the cache lacks, an issue
#           not in the open list, a clipped assignee, --max-age 0 → exactly ONE
#           gh call, `_source: gh`.
#   REST    GraphQL limited (real refusal text, or FLEET_GH_FAKE_LIMIT=graphql) →
#           the same field names over `gh api repos/…`, `_source: rest`.
#   REPO    keyed by (repo, N): another repo's cache never answers, and the gh
#           call carries that repo's --repo.
# Offline; never touches the real account.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null 2>&1 || { printf 'fleet-gh-selftest: jq absent — SKIP\n'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleetgh-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/fakebin" "$WORK/tmp" "$WORK/fix"
export FLEET_STATE_DIR="$WORK/state" FLEET_GH_LOG="$WORK/gh-limit.log" FLEET_CONF_DIR="$WORK/conf"
export FLEET_WEBHOOK_STATE_DIR="$WORK/wh"   # no live forward unless a leg plants one
unset FLEET_GH_FAKE_LIMIT
C="$WORK/tmp/.claude-dash/fleets"
mkdir -p "$C/o-r" "$C/o-other"

# --- the caches, as the collector / pr-refresh write them ---------------------
printf '%s\t#%s\t%s\t%s\n' \
  'v1' 5 'alice' 'Cached five' \
  '· no milestone' 6 '·' $'tab\tin title' \
  '· no milestone' 7 'abcdefghij' 'clipped assignee' > "$C/o-r/issues"
printf '%s\t%s\n' 5 'bug,p1' 6 '' 7 '' > "$C/o-r/labels"
printf '%s\t#%s\t%s\t%s\t%s\t%s\n' \
  issue-5 9 OPEN '✓' ready '' \
  issue-3 8 MERGED '✓' '' deadbeef \
  issue-4 10 OPEN '…' '' '' > "$C/o-r/prmap"
printf '%s\t#%s\t%s\t%s\n' '· no milestone' 5 '·' 'OTHER repo five' > "$C/o-other/issues"
date +%s > "$C/o-r/issues.ts"; date +%s > "$C/o-r/prmap.ts"; date +%s > "$C/o-other/issues.ts"

# --- fake gh ------------------------------------------------------------------
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
( IFS='|'; printf '%s\n' "$*" ) >> "$GHLOG"
if [ "${1:-}" != api ]; then
  if [ "${FAKE_GQL:-ok}" = limited ]; then
    echo 'GraphQL: API rate limit already exceeded for user ID 2718137.' >&2; exit 1
  fi
  repo='' f=''
  a=("$@"); i=0
  while [ "$i" -lt "${#a[@]}" ]; do
    case "${a[$i]}" in --repo) i=$((i+1)); repo="${a[$i]}" ;; --json) i=$((i+1)); f="${a[$i]}" ;; esac
    i=$((i+1))
  done
  case "$1 $2" in
    "issue view") jq -c --arg f "$f" --arg r "$repo" '($f|split(",")) as $w | {number:5,title:("live " + $r),state:"OPEN",body:"live body",labels:[],assignees:[],comments:[]} | with_entries(select(.key as $k | $w|index($k)))' <<< 'null' ;;
    "pr view")    jq -c --arg f "$f" '($f|split(",")) as $w | {number:9,title:"live pr",state:"OPEN",headRefName:"issue-5"} | with_entries(select(.key as $k | $w|index($k)))' <<< 'null' ;;
    "pr checks")  echo '[{"name":"ci","bucket":"pending","state":"IN_PROGRESS"},{"name":"lint","bucket":"pass","state":"SUCCESS"}]'; exit 8 ;;
  esac
  exit 0
fi
case "$2" in
  repos/o/r/issues/5) echo '{"number":5,"title":"rest five","state":"open","state_reason":null,"body":"rest body","html_url":"https://github.com/o/r/issues/5","labels":[{"name":"bug","color":"f00","description":""}],"assignees":[{"login":"alice"}],"user":{"login":"bob"},"created_at":"t0","updated_at":"t1","closed_at":null,"milestone":null}' ;;
  repos/o/r/issues/5/comments*) echo '[{"user":{"login":"carol"},"body":"hi","created_at":"t2","html_url":"u"}]' ;;
  repos/o/r/pulls/9) echo '{"number":9,"title":"rest pr","state":"open","merged":false,"body":"","html_url":"u","head":{"ref":"issue-5","sha":"abc"},"base":{"ref":"master"},"draft":false,"mergeable":true,"mergeable_state":"clean","merged_at":null,"merge_commit_sha":null,"auto_merge":null,"additions":1,"deletions":0,"changed_files":1,"labels":[],"assignees":[],"user":{"login":"bob"}}' ;;
  repos/o/r/commits/abc/check-runs*) echo '{"check_runs":[{"name":"ci","status":"completed","conclusion":"failure","html_url":"l","started_at":"a","completed_at":"b","output":{"title":"x"}},{"name":"lint","status":"completed","conclusion":"success"}]}' ;;
  repos/o/r/commits/abc/status) echo '{"statuses":[{"context":"ext","state":"success","target_url":"t","created_at":"a","updated_at":"b","description":"d"}]}' ;;
  *) echo "gh: HTTP 404: Not Found ($2)" >&2; exit 1 ;;
esac
GHFAKE
chmod +x "$WORK/fakebin/gh"
export GHLOG="$WORK/gh.log"

run() {  # run <gql ok|limited> <fleet-gh args…> → $OUT, $RC, $CALLS
  local gql="$1"; shift
  rm -f "$FLEET_STATE_DIR"/gh-limit.*; : > "$GHLOG"
  OUT=$(cd "$WORK" && PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FAKE_GQL="$gql" \
        FLEET_GH_FAKE_LIMIT="${FLEET_GH_FAKE_LIMIT:-}" FLEET_REPO=o/r TMUX_PANE='' TMUX='' \
        bash "$BIN/fleet-gh.sh" "$@" 2>"$WORK/err"); RC=$?
  CALLS=$(grep -c . "$GHLOG")
}
j() { jq -r "$1" <<< "$OUT"; }

# ===== CACHE ===================================================================
run ok issue view 5 --repo o/r --json title,state,labels,assignees,milestone,number
[ "$RC" = 0 ] && [ "$CALLS" = 0 ] || fail "fresh issue cache must make zero gh calls" "$OUT rc=$RC $(cat "$GHLOG" "$WORK/err")"
[ "$(j ._source)" = cache ] && [ "$(j '._age|type')" = number ] || fail "_source/_age" "$OUT"
[ "$(j .title)/$(j .state)/$(j .number)" = "Cached five/OPEN/5" ] || fail "issue fields" "$OUT"
[ "$(j '[.labels[].name]|join(",")')" = bug,p1 ] || fail "labels" "$OUT"
[ "$(j '.assignees[0].login')/$(j .milestone.title)" = alice/v1 ] || fail "assignees/milestone" "$OUT"
run ok issue view 6 --repo o/r --json title,assignees,milestone,labels
[ "$CALLS" = 0 ] && [ "$(j .title)" = $'tab\tin title' ] && [ "$(j '.assignees|length')" = 0 ] \
  && [ "$(j .milestone)" = null ] && [ "$(j '.labels|length')" = 0 ] || fail "empty assignee/milestone/labels + a tab in the title" "$OUT"
run ok issue view 5
[ "$CALLS" = 0 ] && [ "$(j 'keys|join(",")')" = "_age,_source,number,state,title" ] || fail "default issue fields" "$OUT"
FLEET_REPO=o/r run ok issue view 5 --json title
[ "$CALLS" = 0 ] && [ "$(j .title)" = "Cached five" ] || fail "repo defaults to FLEET_REPO" "$OUT"
ok "fresh collector cache: zero gh calls, gh field names, _source=cache + _age"

run ok pr view 8 --repo o/r --json number,state,headRefName,mergeCommit
[ "$CALLS" = 0 ] && [ "$(j .state)/$(j .headRefName)/$(j .mergeCommit.oid)/$(j ._source)" = MERGED/issue-3/deadbeef/cache ] \
  || fail "pr view from prmap" "$OUT $(cat "$GHLOG")"
run ok pr view 9 --repo o/r --json state,mergeCommit
[ "$CALLS" = 0 ] && [ "$(j .mergeCommit)" = null ] || fail "open PR: mergeCommit null" "$OUT"
run ok pr checks 9 --repo o/r
[ "$CALLS" = 0 ] && [ "$(j .bucket)" = pass ] && [ "$(j .checks)" = null ] || fail "checks rollup from prmap ✓" "$OUT"
run ok pr checks 10 --repo o/r
[ "$CALLS" = 0 ] && [ "$(j .bucket)" = pending ] || fail "checks rollup from prmap …" "$OUT"
ok "fresh prmap: pr view (state/headRefName/mergeCommit) and the checks rollup with zero gh calls"

# ===== SNAP ====================================================================
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  git init -q "$WORK/base" && git -C "$WORK/base" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git -C "$WORK/base" worktree add -q "$WORK/wt" -b issue-11 2>/dev/null || fail "worktree setup"
  jq -nc '{number:11,title:"Snap",state:"OPEN",url:"u",body:"snap body",labels:[],assignees:[],comments:[{author:{login:"x"},body:"c1",createdAt:"t"}]}' \
    | python3 "$BIN/fleet-issue-cache.py" write "$WORK/wt" o/r 11 "$(date +%s)" || fail "snapshot write"
  : > "$GHLOG"
  OUT=$(cd "$WORK/wt" && PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" bash "$BIN/fleet-gh.sh" issue view 11 --repo o/r --json title,body,comments 2>"$WORK/err")
  [ "$(grep -c . "$GHLOG")" = 0 ] && [ "$(j .body)/$(j '.comments[0].body')/$(j ._source)" = "snap body/c1/cache" ] \
    || fail "spawn snapshot serves body+comments" "$OUT $(cat "$WORK/err")"
  OUT=$(cd "$WORK/wt" && PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" bash "$BIN/fleet-gh.sh" issue view 11 --repo o/r --json title,assignees 2>"$WORK/err")
  [ "$(grep -c . "$GHLOG")" = 1 ] || fail "snapshot assignees predate the claim — must go to gh" "$OUT"
  ok "the spawn snapshot answers its own issue's body/comments; never its pre-claim assignees"
else
  printf 'skip SNAP: no python3/git\n'
fi

# ===== MISS ====================================================================
run ok issue view 5 --repo o/r --json title,body
[ "$CALLS" = 1 ] && [ "$(j ._source)/$(j ._age)/$(j .body)" = "gh/0/live body" ] || fail "a field the cache lacks → one gh call" "$OUT $(cat "$GHLOG")"
grep -qx 'issue|view|5|--repo|o/r|--json|title,body' "$GHLOG" || fail "gh argv" "$(cat "$GHLOG")"
run ok issue view 99 --repo o/r --json title
[ "$CALLS" = 1 ] && [ "$(j ._source)" = gh ] || fail "an issue absent from the open list → gh, never a guess" "$OUT"
run ok issue view 7 --repo o/r --json assignees
[ "$CALLS" = 1 ] || fail "a 10-char (possibly clipped) assignee → gh" "$OUT"
run ok issue view 5 --repo o/r --json title --max-age 0
[ "$CALLS" = 1 ] || fail "--max-age 0 → gh" "$OUT"
run ok pr view 9 --repo o/r --json title
[ "$CALLS" = 1 ] && [ "$(j .title)" = "live pr" ] || fail "pr field the prmap lacks → gh" "$OUT"
run ok pr checks 9 --repo o/r --json name,bucket
[ "$CALLS" = 1 ] && [ "$RC" = 0 ] && [ "$(j .bucket)/$(j '.checks|length')/$(j ._source)" = pending/2/gh ] \
  || fail "checks rows → gh (exit 8 while pending is still an answer)" "$OUT rc=$RC $(cat "$WORK/err")"
touch -t 202001010000 "$C/o-r/issues" "$C/o-r/labels" "$C/o-r/prmap"
date +%s > "$C/o-r/issues.ts"   # the .ts is stamped even on a failed fetch — must not count
run ok issue view 5 --repo o/r --json title
[ "$CALLS" = 1 ] && [ "$(j ._source)" = gh ] || fail "stale issues file → exactly one gh call" "$OUT"
run ok pr view 8 --repo o/r --json state
[ "$CALLS" = 1 ] || fail "stale prmap → gh" "$OUT"
run ok issue view 5 --repo o/r --json title --max-age 999999999
[ "$CALLS" = 0 ] && [ "$(j ._source)" = cache ] && [ "$(j '._age > 1000')" = true ] || fail "--max-age widens the window; _age is the file's" "$OUT"
ok "miss / stale / missing field / --max-age 0 → exactly one gh call, _source=gh"

# ===== WEBHOOK (issue #1272) ===================================================
# A prmap past --max-age is still CURRENT while o/r's forward is live and no
# delivery for the PR (or the repo) has landed since it was written.
mkdir -p "$WORK/wh/forwards" "$WORK/wh/events/o-r"
echo $$ > "$WORK/wh/handler.pid"; echo $$ > "$WORK/wh/forwards/o-r.pid"
perl -e '$t = time - 100; utime $t, $t, @ARGV' "$C/o-r/prmap"
run ok pr checks 10 --repo o/r
[ "$CALLS" = 0 ] && [ "$(j ._source)/$(j .bucket)" = cache/pending ] \
  || fail "webhook live + no event since the prmap → the 100s-old copy still serves" "$OUT $(cat "$WORK/err")"
printf '%s check_run 1.1\n' "$(( $(date +%s) - 300 ))" > "$WORK/wh/events/o-r/pr-10"
run ok pr checks 10 --repo o/r
[ "$CALLS" = 0 ] || fail "an event OLDER than the prmap leaves it current" "$OUT"
printf '%s check_run 1.2\n' "$(date +%s)" > "$WORK/wh/events/o-r/pr-10"
run ok pr checks 10 --repo o/r
[ "$CALLS" = 1 ] && [ "$(j ._source)" = gh ] || fail "a delivery since the prmap → gh" "$OUT"
rm -f "$WORK/wh/events/o-r/pr-10"; printf '%s reconnect 1.3\n' "$(date +%s)" > "$WORK/wh/events/o-r/repo"
run ok pr view 10 --repo o/r --json state
[ "$CALLS" = 1 ] || fail "a forward reconnect (repo stamp) since the prmap → gh" "$OUT"
rm -f "$WORK/wh/events/o-r/repo"; echo 999999 > "$WORK/wh/forwards/o-r.pid"
run ok pr checks 10 --repo o/r
[ "$CALLS" = 1 ] || fail "no live forward → the plain --max-age rule" "$OUT"
rm -rf "$WORK/wh"
ok "webhook live: an old prmap serves until a delivery lands; a dead forward → plain max-age"

# ===== REST ====================================================================
run limited issue view 5 --repo o/r --json title,state,body,labels,assignees,author,comments
[ "$RC" = 0 ] && [ "$(j ._source)" = rest ] || fail "GraphQL limited → REST" "$OUT rc=$RC $(cat "$WORK/err")"
[ "$(j .title)/$(j .state)/$(j .labels[0].name)/$(j .assignees[0].login)/$(j .author.login)/$(j .comments[0].author.login)" = "rest five/OPEN/bug/alice/bob/carol" ] \
  || fail "REST issue → gh field names" "$OUT"
[ -s "$FLEET_STATE_DIR/gh-limit.graphql" ] || fail "a real refusal writes the shared marker"
grep -q 'fallback-ok op=fleet-gh-issue repo=o/r n=5' "$FLEET_GH_LOG" || fail "fallback logged" "$(cat "$FLEET_GH_LOG")"
FLEET_GH_FAKE_LIMIT=graphql run ok pr view 9 --repo o/r --json state,headRefName,mergeable,statusCheckRollup
[ "$(j ._source)/$(j .state)/$(j .headRefName)/$(j .mergeable)/$(j .statusCheckRollup)" = rest/OPEN/issue-5/MERGEABLE/null ] \
  || fail "REST pr view" "$OUT"
grep -q 'statusCheckRollup' "$WORK/err" || fail "a field REST lacks is named on stderr" "$(cat "$WORK/err")"
grep -q '^pr|' "$GHLOG" && fail "FAKE_LIMIT=graphql must skip the GraphQL call" "$(cat "$GHLOG")"
FLEET_GH_FAKE_LIMIT=graphql run ok pr checks 9 --repo o/r --json name,state,bucket
[ "$(j ._source)/$(j .bucket)/$(j '.checks|length')/$(j '.checks[0].state')" = rest/fail/3/FAILURE ] || fail "REST checks rows + rollup" "$OUT"
ok "GraphQL limited → REST, same field names; FLEET_GH_FAKE_LIMIT skips the doomed call"

# ===== REPO ====================================================================
date +%s > "$C/o-other/issues.ts"; touch "$C/o-other/issues"
run ok issue view 5 --repo o/other --json title
[ "$CALLS" = 0 ] && [ "$(j .title)" = "OTHER repo five" ] || fail "o/other's own cache" "$OUT"
run ok issue view 5 --repo o/third --json title
[ "$CALLS" = 1 ] && [ "$(j .title)" = "live o/third" ] || fail "no cache for o/third → gh with --repo o/third, never o/r's #5" "$OUT"
ok "keyed by (repo, N): each repo reads only its own cache"

printf 'PASS fleet-gh-selftest (%d checks)\n' "$pass"
