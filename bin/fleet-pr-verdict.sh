#!/bin/bash
# fleet-pr-verdict.sh <PR> [--repo R] [-q] — the ONE merge-gate read (issue #441).
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
# verdict · 2 error (no repo / no gh / no such PR). Diagnostics go to stderr; with
# -q even those are suppressed, leaving the bare token.
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

PR='' repo='' quiet=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)      shift; PR="${1:-}" ;;
    --repo)    shift; repo="${1:-}" ;;
    -q|--quiet) quiet=1 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-pr-verdict: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)         PR="$1" ;;
  esac
  shift
done
PR="${PR//[^0-9]/}"
[ -z "$PR" ] && { printf 'fleet-pr-verdict: a PR number is required\n' >&2; exit 2; }

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

# ONE gh read → five fields, ONE PER LINE: state, mergeable, mergeStateStatus,
# draft, checks. Line-separated, not TSV, because three of the five are legitimately
# EMPTY and tab is an IFS *whitespace* char — `IFS=$'\t' read` would silently
# collapse `CLEAN<tab><tab>fail` into four fields and shift the checks verdict onto
# the draft slot. One `read` per line has no such ambiguity.
# `--jq` is gh's BUILT-IN jq (no external dependency), same as tmux-pr-refresh.sh.
# statusCheckRollup mixes two shapes — a CheckRun (.status/.conclusion) and a
# StatusContext (.state) — so every branch tests both; a missing key is null and
# simply doesn't match.
# shellcheck disable=SC2016  # $r/$ck are jq variables, not shell — keep single-quoted
row=$(gh pr view "$PR" --repo "$repo" \
        --json state,mergeable,mergeStateStatus,isDraft,statusCheckRollup \
        --jq '(.statusCheckRollup // []) as $r |
              (if   ($r|length)==0                       then "none"
               elif ($r|any(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT"
                            or .conclusion=="CANCELLED" or .conclusion=="ACTION_REQUIRED"
                            or .state=="FAILURE" or .state=="ERROR"))          then "fail"
               elif ($r|any(.status!="COMPLETED" and .state!="SUCCESS"))       then "pending"
               else "pass" end) as $ck |
              [.state, (.mergeable // ""), (.mergeStateStatus // ""),
               (if .isDraft then "DRAFT" else "" end), $ck] | .[]' 2>/dev/null) \
  || { printf 'fleet-pr-verdict: cannot read PR #%s in %s\n' "$PR" "$repo" >&2; exit 2; }
[ -z "$row" ] && { printf 'fleet-pr-verdict: no such PR #%s in %s\n' "$PR" "$repo" >&2; exit 2; }

{ read -r st; read -r mg; read -r ms; read -r dr; read -r ck; } <<< "$row"
verdict=$(land_verdict "$st" "$mg" "$ms" "$dr" "$ck")
printf '%s\n' "$verdict"

case "$verdict" in
  READY)    note "#$PR is green + mergeable — merge it"; exit 0 ;;
  PENDING)  note "#$PR checks not final yet (checks=$ck, mss=$ms) — wait and re-read" ;;
  BEHIND)   note "#$PR is behind $repo's base — gh pr update-branch $PR" ;;
  FAILING)  note "#$PR has a RED check — fix it, never merge red" ;;
  CONFLICT) note "#$PR conflicts with the base — rebase" ;;
  BLOCKED)  note "#$PR is green but branch protection blocks the merge — not yours to force" ;;
  DRAFT)    note "#$PR is a draft — gh pr ready $PR" ;;
  MERGED)   note "#$PR is already merged" ;;
  CLOSED)   note "#$PR was closed unmerged" ;;
  *)        note "#$PR: $verdict (state=$st mergeable=$mg mss=$ms checks=$ck)" ;;
esac
exit 1
