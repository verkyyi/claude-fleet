#!/bin/bash
# fleet-pr-verdict.sh <PR> [--repo R] [-q] [--wait [--until-merged] [--timeout S]
#                     [--no-checks-timeout S] [--interval S]]
#   — the ONE merge-gate read (issue #441), and its blocking form (issue #950).
#
# Since #441 a worker LANDS ITS OWN PR once the gates are green, so it needs a
# deterministic answer to "may I merge this yet?" — not an LLM squinting at raw
# `gh pr view` JSON. This is that answer: ONE `gh` call, folded through the shared
# taxonomy in bin/fleet-land-lease.sh (land_classify + land_verdict), printing ONE
# verdict token on stdout.
#
# Verdicts (stdout, exactly one line):
#   READY     green + mergeable + up to date       → merge it
#   PENDING   checks still running / not final yet → wait, re-read later
#   BEHIND    out of date with the base            → `gh pr update-branch <PR>`
#   FAILING   a check is RED                       → fix it; never merge red
#   CONFLICT  conflicting / DIRTY                  → rebase on the base branch
#   BLOCKED   green + mergeable but branch protection says no (review required,
#             …) → NOT yours to force; say so on the issue and stop
#   DRAFT     still a draft                        → `gh pr ready <PR>`
#   MERGED    already landed  (the confirm-after-merge read)
#   CLOSED    closed unmerged
#
# Exit codes (so a caller can branch without parsing): 0 READY · 1 any other
# verdict · 2 error (no repo / no gh / no such PR) · 3 TIMEOUT (--wait only).
# Diagnostics go to stderr; with -q even those are suppressed, leaving the bare
# token.
#
# --wait (issue #950) BLOCKS while the verdict is PENDING and prints the first
# verdict that isn't — run it with the harness's background mode, and the session
# wakes the moment CI settles instead of spending a turn per re-read:
#   * fail fast: a RED check is FAILING the moment it lands (the fold ranks fail
#     above pending), never "wait for the other lanes first".
#   * "no checks yet" is read from the EMPTY ROLLUP, never an exit code, and is
#     waited out (a push's CI can take minutes to register) — even when
#     mergeStateStatus already says CLEAN, which the one-shot folds to READY. Past
#     --no-checks-timeout (default 600s) it prints TIMEOUT, exit 3, with the
#     mergeStateStatus: UNDETERMINED, never red. A repo with no CI at all: the
#     one-shot read (no --wait) says READY.
#   * a rebase/re-run that resets the check set mid-wait (back to pending or
#     empty) just keeps waiting; the no-checks bound restarts from the reset.
#   * --until-merged: READY with auto-merge ARMED keeps waiting until MERGED, so
#     the wake-up means "landed" (exit 0 on MERGED in this mode). READY with no
#     auto-merge armed returns READY — merging is still yours.
#   * --timeout (default 3600s) bounds the whole wait → TIMEOUT, exit 3.
#   * API budget: GraphQL is 5,000/hr SHARED by every session on the account, so
#     it is ONE `gh` call per poll, every 20s for the first 2 minutes (CI is young)
#     and while no checks exist, then every --interval (default 15s, floor 10s).
#     A failed read mid-wait (network, rate limit) backs off and retries; 5 in a
#     row is exit 2.
#
# `macOS shard *` checks are not part of the merge gate (issue #2286): the BSD half
# runs on master after the merge and gates `fleet-stable.sh move` instead.
#
# `CI 结论` (issue #4815, .github/workflows/ci.yml) is read FIRST when the PR
# carries it: it is the one check that says every check its plan selected is green
# and every other skipped. Present ⇒ it decides (pending until it completes — a
# check still running elsewhere no longer holds the verdict once it is green),
# except that any other red check still reads FAILING (fail fast while it waits). Absent
# (a branch from before ci.yml, a repo without it) ⇒ every check, as before.
#
# The CHECK ROLLUP fold reads none/fail/pending/pass and counts TIMED_OUT /
# CANCELLED / ACTION_REQUIRED as red.
#
# GraphQL rate-limited (issue #1042): the read falls back to REST (pr_rest_view
# below: `pulls/N` + the head's check-runs + combined status), folded by the SAME
# land_verdict — so READY/FAILING/… mean exactly what they mean on the GraphQL
# path. stdout is still the one token; stderr says `via REST`. The GitHub layer
# that once carried this (fleet-gh-lib.sh) is gone (issue #4899): plain gh, and
# this file's own fallback is the part the gate still needs.
#
# Read-only: it merges nothing, arms nothing, and touches no worktree/window.
set -uo pipefail

# --- GitHub reads (issue #4899: the gate's half of the old GitHub layer) -------
# pr_gh_run <gh args…> — gh's own rc and output, except a rate-limit refusal is
# rc $PR_GH_LIMITED_RC with nothing printed, so the caller can take REST instead.
# Secondary first (its message also says "rate limit"), then GraphQL, else core.
PR_GH_LIMITED_RC=75
pr_gh_limit_text() {
  case "${1:-}" in
    *[Ss]econdary\ rate\ limit*|*graphql_rate_limit*|*GraphQL:*[Rr]ate\ limit*|*'"RATE_LIMIT"'*) return 0 ;;
    *[Rr]ate\ limit\ exceeded*|*[Rr]ate\ limit\ already\ exceeded*) return 0 ;;
  esac
  return 1
}
pr_gh_run() {
  local err rc
  err=$(mktemp "${TMPDIR:-/tmp}/fleet-pr-gh.XXXXXX") || { gh "$@"; return $?; }
  gh "$@" 2>"$err"; rc=$?
  if [ "$rc" -ne 0 ] && pr_gh_limit_text "$(cat "$err" 2>/dev/null)"; then rm -f "$err"; return "$PR_GH_LIMITED_RC"; fi
  [ "$rc" -eq 0 ] || cat "$err" >&2
  rm -f "$err"; return "$rc"
}

# pr_rest_view <repo> <pr> — the same seven lines the GraphQL read emits — state,
# mergeable, mergeStateStatus, draft, checks, auto-merge, CI — so one fold
# (land_verdict) judges both paths. REST's lowercase enums map 1:1 onto the
# GraphQL ones. A MERGED/CLOSED PR skips the check reads (the verdict ignores them).
pr_rest_view() {
  local repo="$1" pr="$2" row st mg ms dr sha am runs stats ck ci=''
  # shellcheck disable=SC2016
  row=$(pr_gh_run api "repos/$repo/pulls/$pr" --jq '
          (if .merged then "MERGED" elif .state=="closed" then "CLOSED" else "OPEN" end),
          (if .mergeable==true then "MERGEABLE" elif .mergeable==false then "CONFLICTING" else "UNKNOWN" end),
          ((.mergeable_state // "") | ascii_upcase),
          (if .draft then "DRAFT" else "" end),
          (.head.sha // ""),
          (if .auto_merge then "AUTO" else "" end)') || return $?
  [ -n "$row" ] || return 1
  { read -r st; read -r mg; read -r ms; read -r dr; read -r sha; read -r am; } <<< "$row"
  ck=none
  if [ "$st" = OPEN ] && [ -n "$sha" ]; then
    # `macOS shard *` is not part of the merge gate (issue #2286) — dropped here
    # exactly as the GraphQL fold below drops it.
    runs=$(pr_gh_run api "repos/$repo/commits/$sha/check-runs?per_page=100" --jq '
             .check_runs[] | select((.name // "") | startswith("macOS shard") | not) |
             (if .name == "CI 结论" then "ci-" else "" end) +
             (if (.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled"
                 or .conclusion=="action_required") then "fail"
              elif .status!="completed" then "pending" else "pass" end)') || return $?
    stats=$(pr_gh_run api "repos/$repo/commits/$sha/status" --jq '
             .statuses[] |
             if (.state=="failure" or .state=="error") then "fail"
             elif .state=="pending" then "pending" else "pass" end') || return $?
    runs="$runs
$stats"
    # `CI 结论` decides when present (issue #4815) — another red still fails
    # fast; the same fold as the GraphQL read
    if printf '%s\n' "$runs" | grep -q '^ci-'; then
      ci=CI
      if   printf '%s\n' "$runs" | grep -qE '^(ci-)?fail$'; then ck=fail
      elif printf '%s\n' "$runs" | grep -qx ci-pending;     then ck=pending
      else ck=pass
      fi
    elif printf '%s\n' "$runs" | grep -qx fail;    then ck=fail
    elif printf '%s\n' "$runs" | grep -qx pending; then ck=pending
    elif printf '%s\n' "$runs" | grep -qx pass;    then ck=pass
    fi
  fi
  printf '%s\n' "$st" "$mg" "$ms" "$dr" "$ck" "$am" "$ci"
}
# Sourced (fleet-pr-merge.sh takes the helpers above): stop here.
[ "${FLEET_PR_VERDICT_LIB:-0}" = 1 ] && return 0

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"


PR='' repo='' quiet=0 wait=0 until_merged=0
wait_timeout=3600 nochecks_timeout=600 interval=15
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)      shift; PR="${1:-}" ;;
    --repo)    shift; repo="${1:-}" ;;
    -q|--quiet) quiet=1 ;;
    --wait)    wait=1 ;;
    --until-merged) wait=1; until_merged=1 ;;
    --timeout)           shift; wait_timeout="${1:-}" ;;
    --no-checks-timeout) shift; nochecks_timeout="${1:-}" ;;
    --interval)          shift; interval="${1:-}" ;;
    -h|--help) sed -n '2,72p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-pr-verdict: unknown flag %s\n' "$1" >&2; exit 2 ;;
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
    || { printf 'fleet-pr-verdict: a PR number is required\n' >&2; exit 2; }
fi
for _n in "$wait_timeout" "$nochecks_timeout" "$interval"; do
  case "$_n" in ''|*[!0-9]*) printf 'fleet-pr-verdict: a duration must be whole seconds (got %s)\n' "$_n" >&2; exit 2 ;; esac
done
[ "$interval" -lt 10 ] && interval=10   # the shared GraphQL budget's floor (#950)

note() { [ "$quiet" = 1 ] || printf 'fleet-pr-verdict: %s\n' "$1" >&2; }

# Repo resolution: an explicit --repo wins (an EMPTY
# one is no repo — `--repo "$FLEET_REPO"` from a multi-repo pane), else $CF_REPO
# (passed through a popup); else fleet_target_repo — the pane's window repo (@repo),
# the fleet's only repo, or a refusal, the same however many repos it hosts (issue
# #1938). Never the dash's cached repo: that is whichever the dash last picked, and
# reading it answered #N of ANOTHER repo (issue #1822). Outside a fleet, FLEET_REPO.
repo="${repo:-${CF_REPO:-}}"
_sess=$(fleet_current_session 2>/dev/null)
if [ -z "$repo" ]; then
  # ONE rule however many repos the fleet hosts (issue #1938): the pane's window
  # repo, else the fleet's only repo, else a refusal — never the dash's cached repo
  # (#1822/#1461). Outside any fleet, the global FLEET_REPO.
  repo=$(fleet_target_repo "$_sess"); _rc=$?
  [ "$_rc" = 4 ] && {
    printf 'fleet-pr-verdict: fleet %s hosts several repos and this pane has none — pass --repo (%s)\n' \
      "$_sess" "$(fleet_repos "$_sess" | tr '\n' ' ' | sed 's/ $//')" >&2; exit 2; }
  [ -n "$repo" ] || repo="${FLEET_REPO:-}"
fi
[ -z "$repo" ] && { printf 'fleet-pr-verdict: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 2; }
# FLEET_LAND=fleet (issue #3602, EPIC #3570 C9): no PR and no gh — git's verdict,
# same words (READY · BEHIND · CONFLICT · FAILING · BLOCKED · MERGED).
if [ "$(fleet_repo_land "$repo" "$_sess")" = fleet ]; then
  _lq=""; [ "$quiet" = 1 ] && _lq=-q
  exec "$BIN/fleet-land.sh" --verdict ${PR:+--issue "$PR"} ${_lq:+"$_lq"} "$repo"
fi
command -v gh >/dev/null 2>&1 || { printf 'fleet-pr-verdict: gh not on PATH\n' >&2; exit 2; }

# ONE gh read → six fields, ONE PER LINE: state, mergeable, mergeStateStatus,
# draft, checks, auto-merge. Line-separated, not TSV, because four of the six are
# legitimately EMPTY and tab is an IFS *whitespace* char — `IFS=$'\t' read` would
# silently collapse `CLEAN<tab><tab>fail` into four fields and shift the checks
# verdict onto the draft slot. One `read` per line has no such ambiguity.
# `--jq` is gh's BUILT-IN jq (no external dependency).
# statusCheckRollup mixes two shapes — a CheckRun (.status/.conclusion) and a
# StatusContext (.state) — so every branch tests both; a missing key is null and
# simply doesn't match. `none` is the EMPTY rollup — "no checks reported yet" is
# read from the data, never inferred from an exit code (#950).
# A `macOS shard *` check is DROPPED before the fold (issue #2286): the BSD half
# runs after the merge, on master, and gates moving `stable`, not merging — so a
# PR opened before that change, still carrying a queued macOS shard, is not held
# PENDING by it (and a red one there is not this gate's to judge).
# read_pr → sets st/mg/ms/dr/ck/am; returns 2 (with a message in $read_err) when
# the PR can't be read.
read_err='' via=''
read_pr() {
  local row rc
  # shellcheck disable=SC2016  # $r/$ck are jq variables, not shell — keep single-quoted
  row=$(pr_gh_run pr view "$PR" --repo "$repo" \
          --json state,mergeable,mergeStateStatus,isDraft,statusCheckRollup,autoMergeRequest \
          --jq '[(.statusCheckRollup // [])[]
                 | select((.name // .context // "") | startswith("macOS shard") | not)] as $r |
                def red: .conclusion=="FAILURE" or .conclusion=="TIMED_OUT" or .conclusion=="CANCELLED"
                         or .conclusion=="ACTION_REQUIRED" or .state=="FAILURE" or .state=="ERROR";
                def open: .status!="COMPLETED" and .state!="SUCCESS";
                [$r[] | select((.name // .context // "") == "CI 结论")] as $c |
                [$r[] | select((.name // .context // "") != "CI 结论")] as $o |
                (if ($c|length) > 0 then
                   (if   ($c|any(red)) or ($o|any(red)) then "fail"
                    elif ($c|any(open))                  then "pending"
                    else "pass" end)
                 elif ($r|length)==0       then "none"
                 elif ($r|any(red))        then "fail"
                 elif ($r|any(open))       then "pending"
                 else "pass" end) as $ck |
                [.state, (.mergeable // ""), (.mergeStateStatus // ""),
                 (if .isDraft then "DRAFT" else "" end), $ck,
                 (if .autoMergeRequest then "AUTO" else "" end),
                 (if ($c|length) > 0 then "CI" else "" end)] | .[]' 2>/dev/null); rc=$?
  if [ "$rc" -eq "$PR_GH_LIMITED_RC" ]; then
    # GraphQL is rate-limited → the same six lines over REST (issue #1042).
    row=$(pr_rest_view "$repo" "$PR" 2>/dev/null) \
      || { read_err="cannot read PR #$PR in $repo (GraphQL rate-limited, REST failed too)"; return 2; }
    [ "$via" = REST ] || note "GraphQL rate-limited — reading #$PR via REST"
    via=REST
  elif [ "$rc" -ne 0 ]; then
    read_err="cannot read PR #$PR in $repo"; return 2
  else
    via=''
  fi
  [ -z "$row" ] && { read_err="no such PR #$PR in $repo"; return 2; }
  st='' mg='' ms='' dr='' ck='' am='' ci=''
  { read -r st; read -r mg; read -r ms; read -r dr; read -r ck; read -r am; read -r ci; } <<< "$row"
  return 0
}

explain() {  # explain <verdict> → the human note on stderr
  case "$1" in
    READY)    note "#$PR is green + mergeable — merge it" ;;
    PENDING)  note "#$PR checks not final yet (checks=$ck, mss=$ms) — wait: --wait blocks until they settle" ;;
    BEHIND)   note "#$PR is behind $repo's base — gh pr update-branch $PR" ;;
    FAILING)  note "#$PR has a RED check — fix it, never merge red" ;;
    CONFLICT) note "#$PR conflicts with the base — rebase" ;;
    BLOCKED)  note "#$PR is green but branch protection blocks the merge — not yours to force"
              # a branch from before the base's ci.yml has no `CI 结论` to satisfy a required one
              [ -n "$ci" ] || note "#$PR reports no 'CI 结论' check — if $repo requires it, the branch predates it: gh pr update-branch $PR" ;;
    DRAFT)    note "#$PR is a draft — gh pr ready $PR" ;;
    MERGED)   note "#$PR is already merged${via:+ (via $via)}" ;;
    CLOSED)   note "#$PR was closed unmerged" ;;
    *)        note "#$PR: $1 (state=$st mergeable=$mg mss=$ms checks=$ck)" ;;
  esac
}

st='' mg='' ms='' dr='' ck='' am='' ci=''
read_pr || { printf 'fleet-pr-verdict: %s\n' "$read_err" >&2; exit 2; }
verdict=$(land_verdict "$st" "$mg" "$ms" "$dr" "$ck")

if [ "$wait" = 1 ]; then
  # Elapsed time is the LARGER of the wall clock and the sum of our own sleeps:
  # the wall clock is the truth in production, the sleep sum keeps the bounds
  # honest (and the selftest deterministic) when `sleep` returns early.
  t0=$SECONDS slept=0 fails=0 none_since=0 last=''
  elapsed() { local w=$((SECONDS - t0)); [ "$w" -gt "$slept" ] && echo "$w" || echo "$slept"; }
  while :; do
    now=$(elapsed)
    # What does this read mean for a WAITER? `waiting` = keep blocking; empty =
    # return $verdict.
    waiting=''
    if [ "$ck" = none ] && { [ "$verdict" = READY ] || [ "$verdict" = PENDING ]; }; then
      waiting=nochecks   # CLEAN + no rollup is READY to the one-shot; not to a waiter
    elif [ "$verdict" = PENDING ]; then
      waiting=pending
    elif [ "$until_merged" = 1 ] && [ "$verdict" = READY ] && [ "$am" = AUTO ]; then
      waiting=automerge
    fi
    [ -z "$waiting" ] && break
    [ "$waiting" = nochecks ] || none_since=$now   # a reset restarts the no-checks bound
    if [ "$waiting" != "$last" ]; then
      note "#$PR waiting: $waiting (checks=$ck, mss=$ms, ${now}s in)"; last=$waiting
    fi
    if [ "$waiting" = nochecks ] && [ $((now - none_since)) -ge "$nochecks_timeout" ]; then
      printf 'TIMEOUT\n'
      note "#$PR UNDETERMINED: no check reported in ${nochecks_timeout}s (mss=$ms${mg:+, mergeable=$mg}) — not red; a DIRTY/CONFLICTING head runs no pull_request workflows, and a repo with no CI reads READY without --wait"
      exit 3
    fi
    if [ "$now" -ge "$wait_timeout" ]; then
      printf 'TIMEOUT\n'
      note "#$PR UNDETERMINED after ${wait_timeout}s: still $waiting (checks=$ck, mss=$ms) — not red; re-run --wait or read it once"
      exit 3
    fi
    # Poll pacing (#950): young CI and an empty rollup rarely change in 10s, so
    # 20s there; the configured interval once checks are running for real.
    iv=$interval
    if [ "$waiting" = nochecks ] || [ "$now" -lt 120 ]; then [ "$iv" -lt 20 ] && iv=20; fi
    if [ "$fails" -gt 0 ]; then iv=$((iv * (fails + 1))); [ "$iv" -gt 120 ] && iv=120; fi
    sleep "$iv"; slept=$((slept + iv))
    if read_pr; then
      fails=0
      verdict=$(land_verdict "$st" "$mg" "$ms" "$dr" "$ck")
    else
      fails=$((fails + 1))
      note "#$PR read failed mid-wait ($fails/5): $read_err"
      [ "$fails" -ge 5 ] && { printf 'fleet-pr-verdict: giving up — %s\n' "$read_err" >&2; exit 2; }
    fi
  done
fi

printf '%s\n' "$verdict"
explain "$verdict"
[ "$verdict" = READY ] && exit 0
[ "$until_merged" = 1 ] && [ "$verdict" = MERGED ] && exit 0
exit 1
