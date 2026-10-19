#!/bin/bash
# fleet-pr-merge.sh <PR> [--repo R] [--method squash|merge|rebase] [-q]
#   — the worker's ONE merge command (issue #1042): gate, merge, confirm.
#
# 1. GATE  — bin/fleet-pr-verdict.sh must read READY (green + mergeable + up to
#            date). Anything else is printed and refused, exit 1 — this never
#            merges past a red, running, conflicting or blocked PR. MERGED reads
#            as already done (exit 0), so a re-run is harmless.
# 2. MERGE — `gh pr merge <PR> --repo R --<method> --delete-branch`, exactly the
#            pre-#1042 command. If GraphQL answers with a rate limit, the SAME
#            merge goes over REST instead (rest_merge below: `PUT pulls/N/merge`
#            pinned to the head sha, then the head branch deleted — only after
#            GitHub says merged). No more parking a green PR until the GraphQL reset (#954,
#            #1042: a worker waited ~50 min).
# 3. CONFIRM — re-read the verdict; MERGED is the only success. gh's own exit code
#            is not trusted: it can fail AFTER merging (deleting the local branch
#            a worktree stands on).
#
# stdout: the final verdict token (MERGED on success). Exit: 0 merged · 1 not
# READY / merge refused · 2 error (no PR / no repo / unreadable).
# Method: --method, else this fleet's FLEET_MERGE_METHOD (fleet_merge_method),
# else squash.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# The gate's GitHub helpers (pr_gh_run, PR_GH_LIMITED_RC) live in fleet-pr-verdict.sh
# (issue #4899): sourced as a lib, it defines them and stops.
# shellcheck source=/dev/null
FLEET_PR_VERDICT_LIB=1 . "$BIN/fleet-pr-verdict.sh"

# rest_merge <repo> <pr> <method> — merge over REST, pinned to the head sha it reads
# (a push that lands between the read and the PUT makes GitHub refuse rather than
# merge unverified code), and delete the head branch ONLY after GitHub says merged —
# never on a failed merge (issue #544). The gate above owns the judgement.
rest_merge() {
  local repo="$1" pr="$2" method="${3:-squash}" head sha ref same merged
  # shellcheck disable=SC2016
  head=$(pr_gh_run api "repos/$repo/pulls/$pr" \
           --jq '(.head.sha // ""), (.head.ref // ""), (if .head.repo.full_name == .base.repo.full_name then "same" else "" end)') || return $?
  { read -r sha; read -r ref; read -r same; } <<< "$head"
  [ -n "$sha" ] || return 1
  merged=$(pr_gh_run api -X PUT "repos/$repo/pulls/$pr/merge" \
             -f "merge_method=$method" -f "sha=$sha" --jq '.merged') || return $?
  [ "$merged" = true ] || return 1
  if [ -n "$ref" ] && [ "$same" = same ]; then
    pr_gh_run api -X DELETE "repos/$repo/git/refs/heads/$ref" >/dev/null \
      || printf 'fleet-pr-merge: merged #%s, but deleting branch %s failed (harmless)\n' "$pr" "$ref" >&2
  fi
  return 0
}

PR='' repo='' method='' quiet=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|-R) shift; repo="${1:-}" ;;
    --method)  shift; method="${1:-}" ;;
    --squash|--merge|--rebase) method="${1#--}" ;;
    -q|--quiet) quiet=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-pr-merge: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)         PR="$1" ;;
  esac
  shift
done
PR="${PR//[^0-9]/}"
# A repo the fleet lands itself (FLEET_LAND=fleet, issue #3602) has no PR: there the
# number is optional — bin/fleet-land.sh takes the window's branch.
if [ -z "$PR" ]; then
  _lr="${repo:-${CF_REPO:-}}"; [ -n "$_lr" ] || _lr=$(fleet_target_repo "$(fleet_current_session 2>/dev/null)" 2>/dev/null)
  [ -n "$_lr" ] && [ "$(fleet_repo_land "$_lr" "$(fleet_current_session 2>/dev/null)")" = fleet ] \
    || { printf 'fleet-pr-merge: a PR number is required\n' >&2; exit 2; }
fi
note() { [ "$quiet" = 1 ] || printf 'fleet-pr-merge: %s\n' "$1" >&2; }

# Same resolution as fleet-pr-verdict.sh: the pane's window repo (@repo), else the
# fleet's only repo, else a refusal — never the dash's cached repo, which would
# merge #N of ANOTHER repo (issues #1822, #1938).
repo="${repo:-${CF_REPO:-}}"
sess=$(fleet_current_session 2>/dev/null)
if [ -z "$repo" ]; then
  # ONE rule however many repos the fleet hosts (issue #1938): the pane's window
  # repo, else the fleet's only repo, else a refusal — never the dash's cached repo
  # (#1822/#1461). Outside any fleet, the global FLEET_REPO.
  repo=$(fleet_target_repo "$sess"); _rc=$?
  [ "$_rc" = 4 ] && {
    printf 'fleet-pr-merge: fleet %s hosts several repos and this pane has none — pass --repo (%s)\n' \
      "$sess" "$(fleet_repos "$sess" | tr '\n' ' ' | sed 's/ $//')" >&2; exit 2; }
  [ -n "$repo" ] || repo="${FLEET_REPO:-}"
fi
[ -z "$repo" ] && { printf 'fleet-pr-merge: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 2; }
# FLEET_LAND=fleet (issue #3602, EPIC #3570 C9): the fleet lands it — rebase, the
# repo's check, a fast-forward push — never a PR, never gh.
if [ "$(fleet_repo_land "$repo" "$sess")" = fleet ]; then
  _lq=""; [ "$quiet" = 1 ] && _lq=-q
  exec "$BIN/fleet-land.sh" ${PR:+--issue "$PR"} ${_lq:+"$_lq"} "$repo"
fi
if [ -z "$method" ]; then
  [ -n "$sess" ] && fleet_load_conf "$sess" >/dev/null 2>&1
  method=$(fleet_merge_method)
fi
case "$method" in squash|merge|rebase) ;; *) printf 'fleet-pr-merge: bad --method %s\n' "$method" >&2; exit 2 ;; esac

qflag=''; [ "$quiet" = 1 ] && qflag=-q
verdict() { "$BIN/fleet-pr-verdict.sh" "$PR" --repo "$repo" ${qflag:+"$qflag"}; }

v=$(verdict); rc=$?
[ "$rc" -eq 2 ] && exit 2
case "$v" in
  MERGED) printf 'MERGED\n'; note "#$PR is already merged"; exit 0 ;;
  READY)  ;;
  *)      printf '%s\n' "$v"; note "#$PR is $v, not READY — refusing to merge"; exit 1 ;;
esac

pr_gh_run pr merge "$PR" --repo "$repo" "--$method" --delete-branch >/dev/null; mrc=$?
if [ "$mrc" -eq "$PR_GH_LIMITED_RC" ]; then
  note "GraphQL rate-limited — merging #$PR via REST (PUT pulls/$PR/merge)"
  rest_merge "$repo" "$PR" "$method" || note "REST merge of #$PR failed — branch left in place"
elif [ "$mrc" -ne 0 ]; then
  note "gh pr merge exited $mrc — confirming against the PR's real state"
fi

v=$(verdict); rc=$?
[ "$rc" -eq 2 ] && exit 2
printf '%s\n' "$v"
[ "$v" = MERGED ] && exit 0
note "#$PR did not merge (now $v) — fix and re-run; the branch was not deleted"
exit 1
