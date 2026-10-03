#!/bin/bash
# fleet-gh-fallback-selftest.sh — the GraphQL rate-limit → REST fallback
# (issue #1042, EPIC #1262 C1) on its four paths, plus the healthy path unchanged.
#
#   LIB      fleet-gh-lib.sh: limit classification, the shared marker (format,
#            atomic write, expiry), FLEET_GH_FAKE_LIMIT injection, fleet_gh_run.
#   VERDICT  fleet-pr-verdict.sh reads the SAME token over REST as over GraphQL
#            for READY / FAILING / PENDING / CONFLICT / MERGED / CLOSED.
#   MERGE    fleet-pr-merge.sh: limited → `PUT pulls/N/merge` (sha-pinned) + the
#            branch deleted after it, confirmed MERGED; a non-READY PR is refused
#            on BOTH paths with no merge call at all.
#   REAP     fleet_gh_merged_heads (dash-reap's merged check) finds a MERGED PR
#            over REST, and skips a closed-unmerged one.
#   COMMENT  fleet-comment.sh posts the identical marked body via
#            `issues/N/comments -F body=@file`; --close closes via PATCH.
#   HEALTHY  GraphQL answering → the exact pre-#1042 argv, zero REST calls, same
#            stdout (the single-repo degenerate case, byte for byte).
#
# `gh` is faked on PATH: GraphQL subcommands refuse with the real error text when
# FAKE_GQL=limited, `gh api repos/…` serves fixtures through the script's REAL --jq
# program (system jq). Never touches the network or the real account's budget.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ghfallback-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export FLEET_STATE_DIR="$WORK/state" FLEET_GH_LOG="$WORK/gh-limit.log" FLEET_CONF_DIR="$WORK/conf"
unset FLEET_GH_FAKE_LIMIT
mkdir -p "$WORK/fakebin" "$WORK/fix"

# ===== LIB ====================================================================
# shellcheck source=/dev/null
. "$BIN/fleet-gh-lib.sh"

b() { fleet_gh_limit_bucket "$1"; }
[ "$(b 'GraphQL: API rate limit already exceeded for user ID 2718137.')" = graphql ] || fail "gh's GraphQL refusal → graphql"
[ "$(b '{"errors":[{"type":"RATE_LIMIT","code":"graphql_rate_limit","message":"x"}]}')" = graphql ] || fail "raw graphql JSON → graphql"
[ "$(b 'gh: You have exceeded a secondary rate limit. (HTTP 403)')" = secondary ] || fail "secondary → secondary"
[ "$(b 'gh: API rate limit exceeded for user ID 1. (HTTP 403)')" = core ] || fail "REST refusal → core"
b 'GraphQL: Could not resolve to a PullRequest with the number of 9.' >/dev/null && fail "a not-found is NOT a rate limit"
b 'HTTP 404: Not Found' >/dev/null && fail "a 404 is NOT a rate limit"
ok "limit classification reads the call's own error text (graphql / core / secondary / none)"

fleet_gh_limited graphql >/dev/null && fail "fresh state must not read limited"
FLEET_GH_FAKE_LIMIT=graphql fleet_gh_limited graphql >/dev/null || fail "FLEET_GH_FAKE_LIMIT=graphql must read limited"
FLEET_GH_FAKE_LIMIT=graphql fleet_gh_limited core >/dev/null && fail "fake graphql must not limit core"
FLEET_GH_FAKE_LIMIT=all fleet_gh_limited core >/dev/null || fail "fake all limits core"
[ -e "$FLEET_STATE_DIR/gh-limit.graphql" ] && fail "fault injection must never write the shared marker"
ok "FLEET_GH_FAKE_LIMIT injects a limit without touching the shared marker"

now=$(date +%s)
fleet_gh_mark_limited graphql "$((now + 120))" unit
m="$FLEET_STATE_DIR/gh-limit.graphql"
[ "$(sed -n 's/^reset=//p' "$m")" = "$((now + 120))" ] || fail "marker reset=" "$(cat "$m")"
[ "$(sed -n 's/^source=//p' "$m")" = unit ] || fail "marker source=" "$(cat "$m")"
grep -q '^at=[0-9][0-9]*$' "$m" || fail "marker at=" "$(cat "$m")"
ls -A "$FLEET_STATE_DIR" | grep -q '^\.gh-limit' && fail "atomic write left a tmp file"
[ "$(fleet_gh_limited graphql)" = "$((now + 120))" ] || fail "limited prints the reset epoch"
fleet_gh_mark_limited graphql "$((now - 5))" unit
fleet_gh_limited graphql >/dev/null && fail "an expired marker must not read limited"
fleet_gh_mark_limited secondary '' unit
fleet_gh_limited core >/dev/null || fail "a secondary limit holds every bucket"
rm -f "$FLEET_STATE_DIR"/gh-limit.*
fleet_gh_mark_limited graphql '' unit
r=$(sed -n 's/^reset=//p' "$m"); [ "$r" -gt "$now" ] && [ "$r" -le "$((now + 700))" ] || fail "default hold ≈ 600s" "$r"
rm -f "$FLEET_STATE_DIR"/gh-limit.*
ok "shared marker: reset/source/at, atomic, expires, secondary holds all, default hold"

if ! command -v jq >/dev/null 2>&1; then
  printf 'skip CLI layers: no jq on PATH to run the real --jq programs\n'
  printf 'PASS fleet-gh-fallback-selftest (%d checks, CLI layers skipped)\n' "$pass"; exit 0
fi

# ===== the fake gh =============================================================
# Logs argv (one line per call, args joined by '|'). FIX selects the fixture set;
# a PUT …/merge flips $FIX/merged so the confirming read sees MERGED.
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
( IFS='|'; printf '%s\n' "$*" ) >> "$GHLOG"
[ "${1:-}" = -R ] && shift 2
if [ "${1:-}" != api ]; then
  if [ "${FAKE_GQL:-ok}" = limited ]; then
    echo 'GraphQL: API rate limit already exceeded for user ID 2718137.' >&2; exit 1
  fi
  case "$1 $2" in
    "pr view")  if [ -e "$FIX/merged" ]; then printf 'MERGED\nUNKNOWN\nUNKNOWN\n\npass\n\n'; else cat "$FIX/gql-row"; fi ;;
    "pr list")  cat "$FIX/gql-heads" 2>/dev/null ;;
    "pr merge") : > "$FIX/merged" ;;
    "issue comment") while [ "$#" -gt 0 ]; do [ "$1" = --body ] && { printf '%s' "$2" > "$WORK/posted"; }; shift; done
                     echo "https://github.com/o/r/issues/5#issuecomment-gql" ;;
    "issue close") : > "$WORK/closed" ;;
  esac
  exit 0
fi
shift
method=GET path='' prog='' fields=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) shift; method="$1" ;;
    --jq) shift; prog="$1" ;;
    -f|-F) shift; fields="$fields|$1" ;;
    *) [ -z "$path" ] && path="$1" ;;
  esac; shift
done
src=''
case "$method $path" in
  "GET repos/o/r/pulls/7")              [ -e "$FIX/merged" ] && src="$FIX/pull-merged.json" || src="$FIX/pull.json" ;;
  GET\ repos/o/r/commits/*/check-runs*) src="$FIX/runs.json" ;;
  GET\ repos/o/r/commits/*/status)      src="$FIX/status.json" ;;
  "PUT repos/o/r/pulls/7/merge")        : > "$FIX/merged"; echo '{"merged":true}' > "$WORK/resp"; src="$WORK/resp" ;;
  DELETE\ repos/o/r/git/refs/heads/*)   exit 0 ;;
  GET\ repos/o/r/pulls\?state=closed*)  src="$FIX/closed.json" ;;
  "POST repos/o/r/issues/5/comments"|"GET repos/o/r/issues/5/comments")
     f="${fields#*body=@}"; f="${f%%|*}"; cp "$f" "$WORK/posted"
     echo '{"html_url":"https://github.com/o/r/issues/5#issuecomment-rest"}' > "$WORK/resp"; src="$WORK/resp" ;;
  "PATCH repos/o/r/issues/5")           : > "$WORK/closed"; echo '{"html_url":"u"}' > "$WORK/resp"; src="$WORK/resp" ;;
  *) echo "gh: HTTP 404: Not Found ($method $path)" >&2; exit 1 ;;
esac
if [ -n "$prog" ]; then jq -r "$prog" < "$src"; else cat "$src"; fi
GHFAKE
chmod +x "$WORK/fakebin/gh"
export GHLOG="$WORK/gh.log" WORK

# fixture <name> <gql-row lines> <pulls json> <check-runs json> <status json>
fixture() {
  local d="$WORK/fix/$1"; mkdir -p "$d"
  printf '%s\n' "$2" > "$d/gql-row"; printf '%s' "$3" > "$d/pull.json"
  printf '%s' "$4" > "$d/runs.json"; printf '%s' "$5" > "$d/status.json"
  printf '%s' '{"state":"closed","merged":true,"mergeable":null,"mergeable_state":"unknown","draft":false,"auto_merge":null,"head":{"sha":"abc","ref":"issue-7","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}}' > "$d/pull-merged.json"
}
pull() {  # pull <state> <merged> <mergeable> <mergeable_state>
  printf '{"state":"%s","merged":%s,"mergeable":%s,"mergeable_state":"%s","draft":false,"auto_merge":null,"head":{"sha":"abc","ref":"issue-7","repo":{"full_name":"o/r"}},"base":{"repo":{"full_name":"o/r"}}}' "$1" "$2" "$3" "$4"
}
GREEN_RUNS='{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}'
RED_RUNS='{"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}'
RUN_RUNS='{"check_runs":[{"status":"in_progress","conclusion":null}]}'
NO_STATUS='{"statuses":[]}'
fixture ready    $'OPEN\nMERGEABLE\nCLEAN\n\npass\n'   "$(pull open false true clean)"  "$GREEN_RUNS" "$NO_STATUS"
fixture failing  $'OPEN\nMERGEABLE\nCLEAN\n\nfail\n'   "$(pull open false true clean)"  "$RED_RUNS"   "$NO_STATUS"
fixture pending  $'OPEN\nMERGEABLE\nBLOCKED\n\npending\n' "$(pull open false true blocked)" "$RUN_RUNS" "$NO_STATUS"
fixture statred  $'OPEN\nMERGEABLE\nCLEAN\n\nfail\n'   "$(pull open false true clean)"  "$GREEN_RUNS" '{"statuses":[{"state":"error"}]}'
fixture conflict $'OPEN\nCONFLICTING\nDIRTY\n\nnone\n' "$(pull open false false dirty)" '{"check_runs":[]}' "$NO_STATUS"
fixture merged   $'MERGED\nUNKNOWN\nUNKNOWN\n\npass\n' "$(pull closed true null unknown)" "$GREEN_RUNS" "$NO_STATUS"
fixture closed   $'CLOSED\nUNKNOWN\nUNKNOWN\n\nnone\n' "$(pull closed false null unknown)" '{"check_runs":[]}' "$NO_STATUS"

run() {  # run <fixture> <gql ok|limited> <script> <args…> → stdout; rc in $RC; stderr in $WORK/err
  local fx="$1" gql="$2"; shift 2
  rm -f "$FLEET_STATE_DIR"/gh-limit.* "$WORK/fix/$fx/merged" "$WORK/posted" "$WORK/closed"; : > "$GHLOG"
  OUT=$(PATH="$WORK/fakebin:$PATH" FIX="$WORK/fix/$fx" FAKE_GQL="$gql" FLEET_GH_FAKE_LIMIT="${FLEET_GH_FAKE_LIMIT:-}" FLEET_REPO=o/r TMUX_PANE='' TMUX='' \
        bash "$@" 2>"$WORK/err"); RC=$?
}

# ===== VERDICT =================================================================
for fx in ready failing pending statred conflict merged closed; do
  run "$fx" ok      "$BIN/fleet-pr-verdict.sh" 7 --repo o/r; g="$OUT" grc=$RC
  run "$fx" limited "$BIN/fleet-pr-verdict.sh" 7 --repo o/r; r="$OUT" rrc=$RC
  [ "$g" = "$r" ] && [ "$grc" = "$rrc" ] || fail "verdict $fx: GraphQL=$g/$grc REST=$r/$rrc" "$(cat "$WORK/err")"
  grep -q 'via REST' "$WORK/err" || fail "verdict $fx: stderr should say via REST" "$(cat "$WORK/err")"
done
[ -s "$FLEET_STATE_DIR/gh-limit.graphql" ] || fail "a real refusal must write the shared graphql marker"
run ready ok "$BIN/fleet-pr-verdict.sh" 7 --repo o/r
FLEET_GH_FAKE_LIMIT=graphql run ready ok "$BIN/fleet-pr-verdict.sh" 7 --repo o/r
[ "$OUT" = READY ] || fail "FAKE_LIMIT=graphql verdict" "$OUT"
grep -q '^pr|view' "$GHLOG" && fail "FAKE_LIMIT=graphql must skip the GraphQL call" "$(cat "$GHLOG")"
grep -q 'fallback-ok op=verdict' "$FLEET_GH_LOG" || fail "fallback logged"
ok "verdict over REST = verdict over GraphQL (READY FAILING PENDING status-red CONFLICT MERGED CLOSED)"

run ready limited "$BIN/fleet-pr-verdict.sh" 7 --repo o/r --wait --timeout 30
[ "$OUT" = READY ] && [ "$RC" = 0 ] || fail "--wait under the limit" "$OUT/$RC $(cat "$WORK/err")"
ok "--wait keeps reading through the limit instead of failing 5× and giving up"

# ===== MERGE ===================================================================
run ready limited "$BIN/fleet-pr-merge.sh" 7 --repo o/r --method squash
[ "$OUT" = MERGED ] && [ "$RC" = 0 ] || fail "REST merge → MERGED" "$OUT/$RC $(cat "$WORK/err") $(cat "$GHLOG")"
grep -q '^api|-X|PUT|repos/o/r/pulls/7/merge|-f|merge_method=squash|-f|sha=abc|' "$GHLOG" || fail "PUT merge, sha-pinned" "$(cat "$GHLOG")"
grep -q '^api|-X|DELETE|repos/o/r/git/refs/heads/issue-7' "$GHLOG" || fail "branch deleted after merge" "$(cat "$GHLOG")"
[ "$(grep -n 'PUT' "$GHLOG" | cut -d: -f1)" -lt "$(grep -n 'DELETE' "$GHLOG" | cut -d: -f1)" ] || fail "delete must come AFTER the merge"
grep -q 'fallback-ok op=merge' "$FLEET_GH_LOG" || fail "merge fallback logged"
ok "GraphQL-limited merge goes over REST: PUT pulls/N/merge pinned to the head sha, then the branch delete"

for gql in ok limited; do
  for fx in failing pending conflict; do
    run "$fx" "$gql" "$BIN/fleet-pr-merge.sh" 7 --repo o/r
    [ "$RC" = 1 ] || fail "merge of $fx ($gql) must refuse" "$OUT/$RC"
    grep -q -e '^pr|merge' -e 'PUT' -e 'DELETE' "$GHLOG" && fail "no merge/delete call for $fx ($gql)" "$(cat "$GHLOG")"
  done
done
ok "a non-READY PR is refused on both paths — no merge, no branch delete"

run ready ok "$BIN/fleet-pr-merge.sh" 7 --repo o/r --method squash
[ "$RC" = 0 ] || fail "healthy merge" "$OUT/$RC $(cat "$WORK/err")"
grep -qx 'pr|merge|7|--repo|o/r|--squash|--delete-branch' "$GHLOG" || fail "healthy merge = the pre-#1042 gh pr merge argv" "$(cat "$GHLOG")"
grep -q '^api|' "$GHLOG" && fail "healthy merge must make no REST call" "$(cat "$GHLOG")"
ok "healthy merge: exactly gh pr merge <PR> --repo R --squash --delete-branch, no REST"

# ===== REAP ====================================================================
printf '%s' '[{"merged_at":null,"head":{"ref":"issue-7"}},{"merged_at":"2026-10-01T00:00:00Z","head":{"ref":"issue-7"}}]' > "$WORK/fix/ready/closed.json"
printf 'issue-7\n' > "$WORK/fix/ready/gql-heads"
cat > "$WORK/reap.sh" <<EOF
. "$BIN/fleet-gh-lib.sh"
fleet_gh_merged_heads o/r issue-7
EOF
run ready limited "$WORK/reap.sh"
[ "$OUT" = issue-7 ] || fail "REST merged-heads finds the MERGED PR" "$OUT $(cat "$WORK/err")"
grep -q '^api|repos/o/r/pulls?state=closed&head=o:issue-7&per_page=100' "$GHLOG" || fail "REST head filter" "$(cat "$GHLOG")"
printf '%s' '[{"merged_at":null,"head":{"ref":"issue-7"}}]' > "$WORK/fix/ready/closed.json"
run ready limited "$WORK/reap.sh"
[ -z "$OUT" ] || fail "a closed-UNMERGED PR is not merged" "$OUT"
run ready ok "$WORK/reap.sh"
[ "$OUT" = issue-7 ] || fail "healthy merged-heads" "$OUT"
[ "$(cat "$GHLOG")" = '-R|o/r|pr|list|--state|merged|--head|issue-7|--json|headRefName|-q|.[].headRefName' ] \
  || fail "healthy merged-heads = the pre-#1042 argv" "$(cat "$GHLOG")"
[ "$(grep -c 'fleet_gh_merged_heads' "$BIN/dash-reap.sh")" = 2 ] || fail "dash-reap uses fleet_gh_merged_heads at both merged checks"
grep -q 'gh -R .* pr list' "$BIN/dash-reap.sh" && fail "dash-reap still has a bare gh pr list merged check"
ok "reap's merged check: REST finds a MERGED PR under the limit (not 'unmerged'); healthy argv unchanged"

# ===== COMMENT =================================================================
FCS="$BIN/fleet-comment.sh"
run ready ok "$FCS" 5 --repo o/r --note --body 'tick 3'
cp "$WORK/posted" "$WORK/posted.gql"; gout="$OUT"
[ "$gout" = 'https://github.com/o/r/issues/5#issuecomment-gql' ] || fail "healthy comment URL" "$gout"
grep -q '^api|' "$GHLOG" && fail "healthy comment must make no REST call" "$(cat "$GHLOG")"
run ready limited "$FCS" 5 --repo o/r --note --body 'tick 3'
[ "$OUT" = 'https://github.com/o/r/issues/5#issuecomment-rest' ] && [ "$RC" = 0 ] || fail "REST comment URL" "$OUT/$RC $(cat "$WORK/err")"
cmp -s "$WORK/posted" "$WORK/posted.gql" || fail "REST body must equal the GraphQL body (marker + footer)" "$(diff "$WORK/posted.gql" "$WORK/posted")"
grep -q 'fleet:no-relay' "$WORK/posted" || fail "no-relay marker kept on the REST path"
grep -q 'via REST' "$WORK/err" || fail "comment says via REST"
run ready limited "$FCS" 5 --repo o/r --close --body 'done'
[ "$RC" = 0 ] && [ -e "$WORK/closed" ] || fail "REST close" "$RC $(cat "$WORK/err") $(cat "$GHLOG")"
grep -q '^api|-X|PATCH|repos/o/r/issues/5|-f|state=closed' "$GHLOG" || fail "close via PATCH state=closed" "$(cat "$GHLOG")"
ok "comment / --close: the same marked body over REST when GraphQL is limited; healthy path no REST"

printf 'PASS fleet-gh-fallback-selftest (%d checks)\n' "$pass"
