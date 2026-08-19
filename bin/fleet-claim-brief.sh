#!/bin/bash
# fleet-claim-brief.sh [--issue N] [--repo R] [--no-comments] [-h] — the ONE
# preamble read a freshly-spawned worker runs (issue #458).
#
# /fleet-claim used to open with FOUR steps that each cost their own Bash round
# trip — resolve the fleet, resolve+read the issue, check the assignee, load the
# charter — and env vars do not survive between tool calls, so every step
# re-`source`d fleet-lib.sh and the issue got fetched ~4× per worker. Measured
# over the 10 real worker sessions on this repo (issues 431–455): 13 turns / 4.9k
# output tokens before the first line of grounding, `gh issue view` 4× and
# `source fleet-lib.sh` 4× (max 12) — and, worse, a preamble a worker can
# PARTIALLY skip: issue #454 ran three turns and never loaded the charter layers
# or the operator's per-fleet implementation directive at all.
#
# This is that whole preamble as ONE call: one shell, one `gh` round-trip, one
# atomic block of output. The charter + directive stop being skippable because
# there is no separate step left to skip.
#
# It prints, in order:
#   fleet     — session / repo / base branch / base checkout / merge method / seat
#   issue     — number, title, state, labels, ASSIGNEES (the claim), url, body and
#               every comment, from ONE `gh issue view --json …` read
#   claim     — already claimed (pre-claim at spawn) vs UNCLAIMED + the exact
#               `gh issue edit … --add-assignee @me` to run on the (rare) miss
#   charter   — fleet_worker_charter: the repo/overlay layers + tap-first block
#   directive — fleet_worker_prompt_body: the per-fleet HOW-to guidance (#234)
#
# Exit codes (the skill's rails, one code each — the reason is also printed):
#   0  OK — brief printed
#   2  no fleet resolved            → ABORT  (never guess a repo)
#   3  not the worker seat          → REFUSE (/fleet-claim is worker-only)
#   4  no issue bound               → FAIL   (no @issue, cwd isn't issue-<N>)
#   5  the issue read failed        → gh missing / auth / no such issue. Everything
#      that does NOT depend on gh is still printed first, so the failure is loud
#      but not blinding.
#
# Issue resolution mirrors the skill it replaces: the window's `@issue` binding
# (what the spawner sets) WINS, falling back to the `issue-<N>` worktree in cwd
# for a hand-attached or renamed window. An explicit --issue overrides both.
#
# Strictly READ-ONLY: it assigns nobody, comments nowhere, and touches no
# worktree or window. The (never-yet-observed) assign-on-miss is the caller's —
# which is why the UNCLAIMED line PRINTS the command instead of running it.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

issue_arg='' repo_arg='' want_comments=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issue)       shift; issue_arg="${1:-}" ;;
    --repo)        shift; repo_arg="${1:-}" ;;
    --no-comments) want_comments=0 ;;
    -h|--help)     sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           printf 'fleet-claim-brief: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)             issue_arg="$1" ;;
  esac
  shift
done
issue_arg="${issue_arg//[^0-9]/}"

die() { printf '%s\n' "$1" >&2; exit "$2"; }

# ----------------------------------------------------------------- fleet + seat
sess=$(fleet_current_session)
fleet_load_conf "$sess"           # FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH / …

# Repo resolution mirrors fleet-pr-verdict.sh / fleet-issue-file.sh: an explicit
# --repo wins, then the conf's FLEET_REPO, then this fleet's cached repo.
repo="${repo_arg:-${FLEET_REPO:-}}"
if [ -z "$repo" ]; then
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && repo="$_r"
fi
base="${FLEET_BASE_BRANCH:-master}"
main="${FLEET_MAIN:-}"

# @issue is the source of truth; the issue-<N> worktree in cwd is the fallback for
# a window that lost its binding (hand-attached / renamed), mirroring fleet_seat.
at_issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null)
at_issue="${at_issue//[^0-9]/}"
cwd=$(pwd -P 2>/dev/null)
wt_issue=''
case "$cwd" in
  */*issue-[0-9]*) _n="${cwd##*issue-}"; wt_issue="${_n%%[!0-9]*}" ;;
esac
issue="$issue_arg"
[ -z "$issue" ] && issue="${at_issue:-$wt_issue}"

# fleet_seat needs BOTH @issue and the worktree cwd; a worker whose window lost
# its binding is still a worker (that is exactly what the cwd fallback above is
# for), so widen the seat the same way rather than refusing it at the door.
seat=$(fleet_seat)
[ -z "$seat" ] && [ -n "$wt_issue" ] && seat=worker

# --- the three rails, in the order /fleet-claim states them -------------------
[ -n "$repo" ] || die 'ABORT: not inside a fleet (no FLEET_REPO) — run /fleet-claim from a fleet session. Never guess a repo.' 2
if [ "$seat" != worker ]; then
  where='this pane is not in an issue-<N> worktree'
  hub=$(fleet_hub_pane "$sess" 2>/dev/null)
  [ -n "$hub" ] && [ "$hub" = "${TMUX_PANE:-}" ] && where="you're in the hub pane"
  [ -n "$issue" ] \
    && die "REFUSE: /fleet-claim is worker-only — $where (seat=${seat:-none}). Not proceeding from the wrong seat." 3
  die "FAIL: no issue bound (no @issue and cwd isn't an issue-<N> worktree) — run /fleet-claim inside a worker window. Never guess." 4
fi
[ -n "$issue" ] || die "FAIL: no issue bound (no @issue and cwd isn't an issue-<N> worktree) — run /fleet-claim inside a worker window. Never guess." 4

printf '===== fleet =====\n'
printf 'session=%s  seat=%s  repo=%s  base=%s\n' "$sess" "$seat" "$repo" "$base"
printf 'main=%s   (READ-ONLY base checkout — edit only in this worktree)\n' "${main:-?}"
printf 'worktree=%s\n' "$cwd"
printf 'merge=%s  (how you land: gh pr merge --%s --delete-branch on a READY verdict)\n' \
  "$(fleet_merge_method)" "$(fleet_merge_method)"
printf 'issue=%s  (@issue=%s worktree=%s%s)\n' \
  "$issue" "${at_issue:-none}" "${wt_issue:-none}" \
  "$([ -n "$issue_arg" ] && printf ' --issue=%s' "$issue_arg")"

# --------------------------------------------------------------- the ONE gh read
# ONE `gh issue view --json …` serves what used to be three separate reads: the
# issue thread (old step 1), the assignee/claim check (old step 2), and the
# re-fetch every session then did anyway because `--comments` dumps unstructured
# text. `--jq` is gh's BUILT-IN jq — no external dependency.
printf '\n===== issue #%s · %s =====\n' "$issue" "$repo"
if ! command -v gh >/dev/null 2>&1; then
  printf 'gh: NOT ON PATH — the issue could not be read (fleet + charter above are still valid)\n'
  rc=5
else
  fields='number,title,state,url,body,labels,assignees,comments'
  jqf='"title: \(.title)",
       "state: \(.state)   labels: \((.labels//[])|map(.name)|join(", ")|if .=="" then "-" else . end)",
       "assignees: \((.assignees//[])|map(.login)|join(", "))",
       "url: \(.url)",
       "",
       "----- issue body -----",
       (if (.body//"")=="" then "(empty)" else .body end)'
  if [ "$want_comments" = 1 ]; then
    jqf="$jqf,
       \"\",
       \"----- comments (\\((.comments//[])|length)) -----\",
       ((.comments//[]) | if length==0 then [\"(none)\"]
                          else map(\"--- @\\(.author.login // \"?\") · \\(.createdAt) ---\\n\\(.body)\") end | .[])"
  fi
  # gh's stderr goes to its own file, never into $body: on success the body IS the
  # brief, and a stray gh notice folded into it would read as issue content.
  gherr="${TMPDIR:-/tmp}/fleet-claim-brief.$$.err"
  trap 'rm -f "$gherr"' EXIT
  if body=$(gh issue view "$issue" --repo "$repo" --json "$fields" --jq "$jqf" 2>"$gherr") \
     && [ -n "$body" ]; then
    printf '%s\n' "$body"
    rc=0
    # The claim (issue #283): the ASSIGNEE is the claim, and the spawn pre-claims
    # it (dash-issue-session.sh), so this is a read, not a write — assign only on
    # the miss. Parsed off the header line the single read already printed.
    asg=$(printf '%s\n' "$body" | sed -n 's/^assignees: //p' | head -1)
    if [ -n "$asg" ]; then
      printf '\nclaim: HELD by %s — the spawn pre-claimed it (issue #283). Do NOT re-assign.\n' "$asg"
    else
      printf '\nclaim: UNCLAIMED — claim it now:  gh issue edit %s --repo %s --add-assignee @me\n' "$issue" "$repo"
    fi
  else
    printf 'gh: could not read issue #%s in %s — %s\n' "$issue" "$repo" \
      "$(tr '\n' ' ' < "$gherr" 2>/dev/null)"
    rc=5
  fi
fi

# ------------------------------------------------------- charter + directive
# Both used to be their own steps, and a worker could (and did — #454) skip them.
# Emitted here unconditionally: no separate call left to forget.
printf '\n===== charter · file layers, low→high precedence (built-in contract is the base) =====\n'
ch=$(fleet_worker_charter "$sess")
if [ -n "$ch" ]; then printf '%s\n' "$ch"
else printf '(no file layers — you run on the built-in contract in /fleet-claim step 2)\n'; fi

printf '\n===== implementation directive · this fleet (issue #234) =====\n'
printf '%s\n' "$(fleet_worker_prompt_body "$issue" "$repo")"

exit "${rc:-0}"
