#!/bin/bash
# fleet-pr-merge.sh <PR> [--repo R] [--method squash|merge|rebase] [-q]
#   — the worker's ONE merge command (issue #1042): gate, merge, confirm.
#
# 1. GATE  — bin/fleet-pr-verdict.sh must read READY (green + mergeable + up to
#            date). Anything else is printed and refused, exit 1 — this never
#            merges past a red, running, conflicting or blocked PR. MERGED reads
#            as already done (exit 0), so a re-run is harmless.
# 2. MERGE — `gh pr merge <PR> --repo R --<method> --delete-branch`, exactly the
#            pre-#1042 command. If GraphQL answers with a rate limit (or the shared
#            gh-limit marker already says it is limited), the SAME merge goes over
#            REST instead (bin/fleet-gh-lib.sh: `PUT pulls/N/merge` pinned to the
#            head sha, then the head branch deleted — only after GitHub says
#            merged). No more parking a green PR until the GraphQL reset (#954,
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
# shellcheck source=/dev/null
. "$BIN/fleet-gh-lib.sh"

PR='' repo='' method='' quiet=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|-R) shift; repo="${1:-}" ;;
    --method)  shift; method="${1:-}" ;;
    --squash|--merge|--rebase) method="${1#--}" ;;
    -q|--quiet) quiet=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-pr-merge: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)         PR="$1" ;;
  esac
  shift
done
PR="${PR//[^0-9]/}"
[ -z "$PR" ] && { printf 'fleet-pr-merge: a PR number is required\n' >&2; exit 2; }
note() { [ "$quiet" = 1 ] || printf 'fleet-pr-merge: %s\n' "$1" >&2; }

repo="${repo:-${CF_REPO:-}}"
sess=$(fleet_current_session 2>/dev/null)
if [ -z "$repo" ]; then
  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && repo="$_r"
fi
[ -z "$repo" ] && { printf 'fleet-pr-merge: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 2; }
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

fleet_gh_run graphql pr-merge pr merge "$PR" --repo "$repo" "--$method" --delete-branch >/dev/null; mrc=$?
if [ "$mrc" -eq "$FLEET_GH_LIMITED_RC" ]; then
  note "GraphQL rate-limited — merging #$PR via REST (PUT pulls/$PR/merge)"
  if fleet_gh_rest_merge "$repo" "$PR" "$method" --delete-branch; then
    fleet_gh_log "fallback-ok op=merge repo=$repo pr=$PR"
  else
    note "REST merge of #$PR failed — branch left in place"
  fi
elif [ "$mrc" -ne 0 ]; then
  note "gh pr merge exited $mrc — confirming against the PR's real state"
fi

v=$(verdict); rc=$?
[ "$rc" -eq 2 ] && exit 2
printf '%s\n' "$v"
[ "$v" = MERGED ] && exit 0
note "#$PR did not merge (now $v) — fix and re-run; the branch was not deleted"
exit 1
