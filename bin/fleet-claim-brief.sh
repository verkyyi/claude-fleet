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
# atomic block of output (zero gh calls with a fresh spawn snapshot, #459). The charter + directive stop being skippable because
# there is no separate step left to skip.
#
# It prints, in order:
#   fleet     — session / repo / base branch / base checkout / merge method / seat,
#               and (issue #574) the window's `@origin`: WHO spawned this worker,
#               so the child knows from turn one that it owes someone a report
#   issue     — number, title, state, labels, ASSIGNEES (the claim), url, body and
#               every comment, from a fresh spawn snapshot or ONE gh read
#   claim     — already claimed (pre-claim at spawn) vs UNCLAIMED + the exact
#               `gh issue edit … --add-assignee @me` to run on the (rare) miss
#   charter   — fleet_worker_charter: the repo/overlay layers + tap-first block
#   directive — fleet_worker_prompt_body: the per-fleet HOW-to guidance (#234)
#   language  — the one rule that keeps a non-English session from being dragged
#               back to English by the fleet's all-English scaffolding (#620),
#               printed LAST because the most recent instruction is the one a
#               model follows — which is the whole mechanism of that bug
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
at_issue=$(fleet_pane_fmt '#{@issue}')     # this pane only, never `-t ""` (issue #1537)
at_issue="${at_issue//[^0-9]/}"
# Spawn provenance (issue #574): the SAME @origin the dash already renders as `↳#483`,
# read here so the worker knows it has a parent to report back to at ship time. One
# tmux read, zero gh cost; empty ≡ the operator spawned it from the hub.
at_origin=$(fleet_pane_fmt '#{@origin}')
# `:` stays: it is the repo-qualified key's separator (`<slug>:issue-<N>`, issue
# #789). Stripped, that key read as `<slug>issue-<N>` — which no branch below knows,
# so a monorepo child was told nobody was waiting on it (issue #1511).
at_origin=$(printf '%s' "$at_origin" | tr -cd 'A-Za-z0-9._:-')
# The parent's worker_id (issue #3439): when its fleet is another machine's, the
# report goes there through the hub — the key alone would read as nobody here.
at_owid=$(fleet_pane_fmt '#{@origin_wid}' | tr -cd 'A-Za-z0-9._:/-')
at_remote=''
if [ -n "$at_owid" ] && [ -n "$at_origin" ]; then
  fleet_wid_home "$at_owid" >/dev/null 2>&1; [ "$?" = 1 ] && at_remote=1
fi
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
if [ "$(fleet_repo_land "$repo" "$sess")" = fleet ]; then
  # A repo the fleet lands itself (issue #3602): no PR, no gh — the land line instead.
  printf 'land: fleet  (no PR: pr_verdict → pr_merge with no pr — bin/fleet-land.sh rebases onto %s, runs the repo check %s, fast-forwards)\n' \
    "$base" "$(c=$(fleet_repo_conf_get "$sess" "$repo" FLEET_CHECK_CMD); [ -n "$c" ] && printf '`%s`' "$c" || printf '(none registered — 没跑检查)')"
else
  printf 'merge=%s  (how you land: fleet-pr-merge.sh <PR> on a READY verdict — gh pr merge --%s --delete-branch, REST when GraphQL is rate-limited)\n' \
  "$(fleet_merge_method)" "$(fleet_merge_method)"
fi
printf 'issue=%s  (@issue=%s worktree=%s%s)\n' \
  "$issue" "${at_issue:-none}" "${wt_issue:-none}" \
  "$([ -n "$issue_arg" ] && printf ' --issue=%s' "$issue_arg")"
# The `origin:` line is the address half of the ship step (issue #574): when it
# names a window key, /fleet-claim's last move before stopping is one
# fleet-report-parent.sh call, so the session that spawned this one hears the
# outcome instead of polling the dash for it.
if [ -n "$at_remote" ]; then
  printf 'origin: %s on another machine (worker_id %s — report to it when you ship: the report / send parent tools carry it through the hub; `queued` means it waits there until that session can take it)\n' "$at_origin" "$at_owid"
else
case "$at_origin" in
  orchestrator|steward) printf 'origin: %s (spawned by the session holding the %s role — report to it when you ship: bin/fleet-report-parent.sh)\n' "$at_origin" "$at_origin" ;;
  issue-*)   printf 'origin: %s (spawned by the worker on issue #%s — report to it when you ship: bin/fleet-report-parent.sh)\n' "$at_origin" "${at_origin#issue-}" ;;
  scratch-*) printf 'origin: %s (spawned by scratch session ~%s — report to it when you ship: bin/fleet-report-parent.sh)\n' "$at_origin" "${at_origin#scratch-}" ;;
  # Repo-qualified (issue #789 — a fleet hosting 2+ repos): the same two keys with
  # the parent's repo slug in front. A window key all the same (issue #1511).
  ?*:issue-*)   printf 'origin: %s (spawned by the worker on issue #%s of %s — report to it when you ship: bin/fleet-report-parent.sh)\n' "$at_origin" "${at_origin##*:issue-}" "${at_origin%%:*}" ;;
  ?*:scratch-*) printf 'origin: %s (spawned by scratch session ~%s of %s — report to it when you ship: bin/fleet-report-parent.sh)\n' "$at_origin" "${at_origin##*:scratch-}" "${at_origin%%:*}" ;;
  '')        printf 'origin: none (hub-spawned — the operator has the dash; nothing to report back to)\n' ;;
  *)         if fleet_is_fid "$at_origin"; then
               printf 'origin: %s (spawned by a session named by its identity — report to it when you ship: bin/fleet-report-parent.sh)\n' "$at_origin"
             else
               printf 'origin: %s (not a live-window key — a daemon or another fleet; nothing to report back to)\n' "$at_origin"
             fi ;;
esac
fi

# --------------------------------------------------------- snapshot or ONE gh read
# A fresh machine-local spawn snapshot costs zero gh calls (#459). On a miss,
# ONE `gh issue view --json …` serves what used to be three separate reads: the
# issue thread (old step 1), the assignee/claim check (old step 2), and the
# re-fetch every session then did anyway because `--comments` dumps unstructured
# text. `--jq` is gh's BUILT-IN jq — no external dependency.
printf '\n===== issue #%s · %s =====\n' "$issue" "$repo"
cached_body=$(python3 "$BIN/fleet-issue-cache.py" read "$cwd" "$repo" "$issue" "$want_comments" 2>/dev/null) || cached_body=''
# The ONE read's fields and its gh --jq render, shared by both homes below.
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
# claim_line <assignees> <how to claim> — the claim (issue #283): the spawn
# pre-claims it, so this is a read, not a write — claim only on the miss.
claim_line() {
  if [ -n "$1" ]; then
    printf '\nclaim: HELD by %s — the spawn pre-claimed it (issue #283). Do NOT re-assign.\n' "$1"
  else
    printf '\nclaim: UNCLAIMED — claim it now:  %s\n' "$2"
  fi
}
if [ -n "$cached_body" ]; then
  printf '%s\n' "$cached_body"
  rc=0
elif fleet_ticket_hub "$repo" "$sess"; then
  # A hub ticket (FLEET_TICKETS=hub, issue #3598): read through the door, rendered
  # by the same filter; the claim is the hub's (atomic) — no gh.
  tid="hub:$(fleet_norm_repo "$repo")#$issue"
  if body=$(fleet_ticket_view "$repo" "$issue" "$fields" "$jqf") && [ -n "$body" ]; then
    printf '%s\n' "$body"
    rc=0
    claim_line "$(printf '%s\n' "$body" | sed -n 's/^assignees: //p' | head -1)" \
      "bash ~/.claude/fleet/bin/fleet-ticket.sh claim '$tid' --by '$(fleet_ticket_claimant)'"
  else
    printf 'the ticket door could not read %s — is the hub reachable? (fleet-ticket.sh read %s)\n' "$tid" "$tid"
    rc=5
  fi
elif ! command -v gh >/dev/null 2>&1; then
  printf 'gh: NOT ON PATH — the issue could not be read (fleet + charter above are still valid)\n'
  rc=5
else
  # gh's stderr goes to its own file, never into $body: on success the body IS the
  # brief, and a stray gh notice folded into it would read as issue content.
  gherr="${TMPDIR:-/tmp}/fleet-claim-brief.$$.err"
  trap 'rm -f "$gherr"' EXIT
  if body=$(gh issue view "$issue" --repo "$repo" --json "$fields" --jq "$jqf" 2>"$gherr") \
     && [ -n "$body" ]; then
    printf '%s\n' "$body"
    rc=0
    # Parsed off the header line the single read already printed.
    claim_line "$(printf '%s\n' "$body" | sed -n 's/^assignees: //p' | head -1)" \
      "gh issue edit $issue --repo $repo --add-assignee @me"
  else
    printf 'gh: could not read issue #%s in %s — %s\n' "$issue" "$repo" \
      "$(tr '\n' ' ' < "$gherr" 2>/dev/null)"
    rc=5
  fi
fi

# ------------------------------------------------------- draft-only (issue #3715)
# A ticket whose body carries the draft-only mark changes the finish line: a DRAFT
# PR, `report waiting`, stop. Read off the issue text already printed above — no
# second read. Absent ⇒ nothing printed, byte for byte as before.
_itext="${cached_body:-${body:-}}"
case "$_itext" in
  *'<!-- fleet:draft-only'*)
    _dscan=$(printf '%s\n' "$_itext" | bash "$BIN/fleet-draft.sh" scan 2>/dev/null)
    _dst=$(printf '%s\n' "$_dscan" | head -1)
    printf '\n===== draft-only · this ticket waits for approval (issue #3715) =====\n'
    case "$_dst" in
      approved) printf 'draft: APPROVED — land it by the normal gate (pr_verdict → pr_merge), then report merged.\n' ;;
      rejected) printf 'draft: REJECTED — the PR was closed; read the reason on the issue, do not reopen it.\n' ;;
      *)        printf 'draft: WAITING — open the PR as a DRAFT (gh pr create --draft), take the after-evidence,\n'
                printf '       then report state=waiting with the PR link, and STOP. Never gh pr ready, never merge:\n'
                printf '       pr_merge refuses it (DRAFT-ONLY) until `fleet-draft.sh approve %s`.\n' "$issue" ;;
    esac
    _dnote=$(printf '%s\n' "$_dscan" | sed '1d')
    if [ -n "$_dnote" ]; then
      printf 'pr body must carry, verbatim:\n%s\n' "$_dnote"
    fi ;;
esac

# ------------------------------------------------------- charter + directive
# Both used to be their own steps, and a worker could (and did — #454) skip them.
# Emitted here unconditionally: no separate call left to forget.
printf '\n===== charter · file layers, low→high precedence (built-in contract is the base) =====\n'
ch=$(fleet_worker_charter "$sess")
if [ -n "$ch" ]; then printf '%s\n' "$ch"
else printf '(no file layers — you run on the built-in contract in /fleet-claim step 2)\n'; fi

printf '\n===== implementation directive · this fleet (issue #234) =====\n'
printf '%s\n' "$(fleet_worker_prompt_body "$issue" "$repo")"

# ------------------------------------------------------------------- language
# The Claude seed path's half of issue #620. conf/codex-preamble.md has told a
# CODEX worker to "Reply in the language the issue is written in" since #547; the
# Claude path was never given the equivalent, so a worker spawned on a Chinese
# issue would answer in English for no reason other than that every word of its
# scaffolding is English. This is that rule, single-sourced with the ones the
# resume nudges and notices carry (bin/fleet-lang.sh).
#
# LAST on purpose. The whole bug this closes is that a model follows its most
# recent instruction, and everything above this line — the fleet facts, the
# charter, the directive — is English prose. Printing the rule last is what makes
# it win over its own surroundings.
#
# The second sentence pre-empts the notice class: a worker that later takes a
# quota warning or a child report in its pane has already been told those are
# notices, not a language switch.
if [ -n "${FLEET_LANG_RULE_SEED:-}" ]; then
  printf '\n===== language · keep the session in ONE language (issue #620) =====\n'
  printf '%s\n' "$FLEET_LANG_RULE_SEED" \
                 "The fleet's own automation always speaks English (resume nudges, quota" \
                 "warnings, child reports). Those are notices, never a signal to switch language."
fi

exit "${rc:-0}"
