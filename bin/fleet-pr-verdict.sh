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
# The CHECK ROLLUP fold mirrors bin/tmux-pr-refresh.sh's dash glyphs
# (none/fail/pending/pass), widened on the failure side — a gate must count
# TIMED_OUT / CANCELLED / ACTION_REQUIRED as red, where a glance can shrug.
#
# Read-only: it merges nothing, arms nothing, and touches no worktree/window.
set -uo pipefail

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
    -h|--help) sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-pr-verdict: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)         PR="$1" ;;
  esac
  shift
done
PR="${PR//[^0-9]/}"
[ -z "$PR" ] && { printf 'fleet-pr-verdict: a PR number is required\n' >&2; exit 2; }
for _n in "$wait_timeout" "$nochecks_timeout" "$interval"; do
  case "$_n" in ''|*[!0-9]*) printf 'fleet-pr-verdict: a duration must be whole seconds (got %s)\n' "$_n" >&2; exit 2 ;; esac
done
[ "$interval" -lt 10 ] && interval=10   # the shared GraphQL budget's floor (#950)

note() { [ "$quiet" = 1 ] || printf 'fleet-pr-verdict: %s\n' "$1" >&2; }

# Repo resolution mirrors bin/fleet-issue-file.sh / bin/fleet-comment.sh: an
# explicit --repo wins, else $CF_REPO (passed through a popup), else this fleet's
# cached repo, else the global FLEET_REPO.
repo="${repo:-${CF_REPO:-}}"
if [ -z "$repo" ]; then
  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$(fleet_current_session)"); [ -n "$_r" ] && repo="$_r"
fi
[ -z "$repo" ] && { printf 'fleet-pr-verdict: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { printf 'fleet-pr-verdict: gh not on PATH\n' >&2; exit 2; }

# ONE gh read → six fields, ONE PER LINE: state, mergeable, mergeStateStatus,
# draft, checks, auto-merge. Line-separated, not TSV, because four of the six are
# legitimately EMPTY and tab is an IFS *whitespace* char — `IFS=$'\t' read` would
# silently collapse `CLEAN<tab><tab>fail` into four fields and shift the checks
# verdict onto the draft slot. One `read` per line has no such ambiguity.
# `--jq` is gh's BUILT-IN jq (no external dependency), same as tmux-pr-refresh.sh.
# statusCheckRollup mixes two shapes — a CheckRun (.status/.conclusion) and a
# StatusContext (.state) — so every branch tests both; a missing key is null and
# simply doesn't match. `none` is the EMPTY rollup — "no checks reported yet" is
# read from the data, never inferred from an exit code (#950).
# read_pr → sets st/mg/ms/dr/ck/am; returns 2 (with a message in $read_err) when
# the PR can't be read.
read_err=''
read_pr() {
  local row
  # shellcheck disable=SC2016  # $r/$ck are jq variables, not shell — keep single-quoted
  row=$(gh pr view "$PR" --repo "$repo" \
          --json state,mergeable,mergeStateStatus,isDraft,statusCheckRollup,autoMergeRequest \
          --jq '(.statusCheckRollup // []) as $r |
                (if   ($r|length)==0                       then "none"
                 elif ($r|any(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT"
                              or .conclusion=="CANCELLED" or .conclusion=="ACTION_REQUIRED"
                              or .state=="FAILURE" or .state=="ERROR"))          then "fail"
                 elif ($r|any(.status!="COMPLETED" and .state!="SUCCESS"))       then "pending"
                 else "pass" end) as $ck |
                [.state, (.mergeable // ""), (.mergeStateStatus // ""),
                 (if .isDraft then "DRAFT" else "" end), $ck,
                 (if .autoMergeRequest then "AUTO" else "" end)] | .[]' 2>/dev/null) \
    || { read_err="cannot read PR #$PR in $repo"; return 2; }
  [ -z "$row" ] && { read_err="no such PR #$PR in $repo"; return 2; }
  st='' mg='' ms='' dr='' ck='' am=''
  { read -r st; read -r mg; read -r ms; read -r dr; read -r ck; read -r am; } <<< "$row"
  return 0
}

explain() {  # explain <verdict> → the human note on stderr
  case "$1" in
    READY)    note "#$PR is green + mergeable — merge it" ;;
    PENDING)  note "#$PR checks not final yet (checks=$ck, mss=$ms) — wait: --wait blocks until they settle" ;;
    BEHIND)   note "#$PR is behind $repo's base — gh pr update-branch $PR" ;;
    FAILING)  note "#$PR has a RED check — fix it, never merge red" ;;
    CONFLICT) note "#$PR conflicts with the base — rebase" ;;
    BLOCKED)  note "#$PR is green but branch protection blocks the merge — not yours to force" ;;
    DRAFT)    note "#$PR is a draft — gh pr ready $PR" ;;
    MERGED)   note "#$PR is already merged" ;;
    CLOSED)   note "#$PR was closed unmerged" ;;
    *)        note "#$PR: $1 (state=$st mergeable=$mg mss=$ms checks=$ck)" ;;
  esac
}

st='' mg='' ms='' dr='' ck='' am=''
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
