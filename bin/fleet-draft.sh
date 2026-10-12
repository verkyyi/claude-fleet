#!/bin/bash
# fleet-draft.sh — a DRAFT-ONLY ticket: the worker opens a draft PR, reports
# `waiting` and stops; the PR is made ready and merged only after an approval
# (issue #3715). The daily brief's step 2 asks for exactly this: small changes
# prepared as draft PRs ahead of time, merged once the person says 「按方案做」.
#
# The mark is ONE line in the issue body, written by the filer (`--draft`) or by
# `mark`, and rewritten in place by approve / reject — so it travels with the
# ticket, is read off the body the worker's brief already fetched, and no label
# has to join the fixed taxonomy:
#
#   <!-- fleet:draft-only -->                                   waiting for approval
#   <!-- fleet:draft-only approved=<UTC> by=<who> -->           approved: land it
#   <!-- fleet:draft-only rejected=<UTC> by=<who> -->           rejected: PR closed
#
# An optional PR note (what the dispatcher wants in the PR body — 「日报回复
# <日期>#<n>」 and `<!-- daily-plan -->`) rides between two markers of its own,
# so an HTML comment inside the note never breaks the mark:
#
#   <!-- fleet:pr-note:begin -->
#   日报回复 2026-10-12#3
#   <!-- daily-plan -->
#   <!-- fleet:pr-note:end -->
#
# Usage:
#   fleet-draft.sh block [--pr-note TEXT]          the body block a filer appends
#   fleet-draft.sh scan                            a body on stdin → none|draft|approved|rejected,
#                                                  then the PR note's lines (if any)
#   fleet-draft.sh mark <N> [--repo R] [--pr-note TEXT]   add the block to issue N (idempotent)
#   fleet-draft.sh state <N> [--repo R]            none|draft|approved|rejected (a live read)
#   fleet-draft.sh gate <PR> [--repo R]            exit 0 = may merge; 1 = its ticket is
#                                                  draft-only and not approved (fleet-pr-merge.sh)
#   fleet-draft.sh approve <N> [--repo R] [--by WHO] [--merge]
#        the open PR on issue-<N> made ready, the mark stamped approved, the worker
#        told (a relayed comment: land it by the normal gate). --merge also waits for
#        the gate and merges here (fleet-pr-merge.sh) — for a ticket whose worker is gone.
#   fleet-draft.sh reject <N> --reason TEXT [--repo R] [--by WHO]
#        the PR closed with the reason, the mark stamped rejected, the reason on the issue.
#
# Exit: 0 ok · 1 gate refused / nothing done · 2 usage (or approve/reject from the
# ticket's own worker pane) · 3 no open PR on issue-<N>
# (approve / reject) · 4 the ticket is not draft-only (approve / reject).
# GitHub tickets only: a hub ticket (FLEET_TICKETS=hub) has no PR to hold.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

MARK='<!-- fleet:draft-only -->'
NOTE_BEGIN='<!-- fleet:pr-note:begin -->'
NOTE_END='<!-- fleet:pr-note:end -->'

die() { rc="$1"; shift; printf 'fleet-draft: %s\n' "$*" >&2; exit "$rc"; }
usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

block() {   # $1 = the PR note ('' = none)
  printf '%s\n' "$MARK"
  [ -n "${1:-}" ] && printf '%s\n%s\n%s\n' "$NOTE_BEGIN" "$1" "$NOTE_END"
  return 0
}

# A body on stdin → its state word, then the note's lines.
scan() {
  awk -v b="$NOTE_BEGIN" -v e="$NOTE_END" '
    index($0, "<!-- fleet:draft-only") && st == "" {
      if (index($0, " approved=")) st = "approved"
      else if (index($0, " rejected=")) st = "rejected"
      else st = "draft"
    }
    $0 == e { innote = 0 }
    innote  { note = note $0 "\n" }
    $0 == b { innote = 1 }
    END { print (st == "" ? "none" : st); printf "%s", note }'
}

resolve_repo() {
  [ -n "$repo" ] && return 0
  repo="${CF_REPO:-}"
  [ -n "$repo" ] && return 0
  repo=$(fleet_target_repo "$(fleet_current_session 2>/dev/null)" 2>/dev/null) || repo=''
  [ -n "$repo" ] || repo="${FLEET_REPO:-}"
  [ -n "$repo" ] || die 2 "no repo resolved (pass --repo)"
}

body_of() { gh issue view "$1" --repo "$repo" --json body --jq '.body // ""'; }

# Rewrite the mark line of issue $1 to $2 (the whole new line).
restamp() {
  local n="$1" line="$2" b nb
  b=$(body_of "$n") || die 1 "could not read #$n in $repo"
  nb=$(printf '%s\n' "$b" | awk -v l="$line" 'index($0, "<!-- fleet:draft-only") && !done { print l; done = 1; next } { print }')
  printf '%s\n' "$nb" | gh issue edit "$n" --repo "$repo" --body-file - >/dev/null \
    || die 1 "could not rewrite #$n's body in $repo"
}

open_pr() {   # $1 = issue → "<number> <isDraft>" of the open PR on issue-<N>, or nothing
  gh pr list --repo "$repo" --head "issue-$1" --state open --json number,isDraft \
    --jq '.[0] | select(.) | "\(.number) \(.isDraft)"' 2>/dev/null
}

stamp_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
who_default() { printf '%s' "${by:-$(fleet_origin_key 2>/dev/null || true)}" | tr -d ' \t\n'; }

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
num='' repo='' note='' by='' merge=0 reason=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|-R) shift; repo="${1:-}" ;;
    --pr-note) shift; note="${1:-}" ;;
    --by)      shift; by="${1:-}" ;;
    --merge)   merge=1 ;;
    --reason)  shift; reason="${1:-}" ;;
    -h|--help) usage ;;
    --*)       die 2 "unknown flag $1" ;;
    *)         num="${1//[^0-9]/}" ;;
  esac
  shift
done

case "$cmd" in
  block) block "$note"; exit 0 ;;
  scan)  scan; exit 0 ;;
esac
[ -n "$num" ] || usage
resolve_repo
# The approval is someone else's: the worker bound to the ticket never decides it.
case "$cmd" in approve|reject)
  [ "$(fleet_pane_fmt '#{@issue}' 2>/dev/null)" = "$num" ] \
    && die 2 "#$num is this window's own ticket — its approval comes from whoever dispatched it" ;;
esac

case "$cmd" in
  mark)
    b=$(body_of "$num") || die 1 "could not read #$num in $repo"
    if [ "$(printf '%s\n' "$b" | scan | head -1)" != none ]; then
      printf 'fleet-draft: #%s is already draft-only\n' "$num" >&2; exit 0
    fi
    { printf '%s\n\n' "$b"; block "$note"; } | gh issue edit "$num" --repo "$repo" --body-file - >/dev/null \
      || die 1 "could not mark #$num in $repo"
    printf 'fleet-draft: #%s marked draft-only — its worker opens a draft PR and waits for approve\n' "$num" >&2
    ;;
  state)
    b=$(body_of "$num") || die 1 "could not read #$num in $repo"
    printf '%s\n' "$b" | scan | head -1
    ;;
  gate)
    # $num is a PR here. Its head names the ticket: issue-<N>. Not one of ours, or
    # nothing readable ⇒ not this gate's to refuse (the verdict still is).
    head=$(gh pr view "$num" --repo "$repo" --json headRefName --jq .headRefName 2>/dev/null) || exit 0
    case "$head" in issue-[0-9]*) n="${head#issue-}" ;; *) exit 0 ;; esac
    case "$n" in *[!0-9]*) exit 0 ;; esac
    st=$(body_of "$n" 2>/dev/null | scan | head -1)
    case "$st" in
      draft|rejected)
        printf 'fleet-draft: #%s is a draft-only ticket (%s) — PR #%s waits for approval: fleet-draft.sh approve %s\n' \
          "$n" "$st" "$num" "$n" >&2
        exit 1 ;;
    esac
    exit 0
    ;;
  approve)
    st=$(body_of "$num" | scan | head -1) || st=''
    [ "$st" = draft ] || [ "$st" = approved ] || die 4 "#$num is not a draft-only ticket ($st)"
    pr=$(open_pr "$num")
    [ -n "$pr" ] || die 3 "no open PR on issue-$num yet — the worker has not opened its draft"
    prn="${pr%% *}"
    if [ "${pr#* }" = true ]; then
      gh pr ready "$prn" --repo "$repo" >/dev/null || die 1 "gh pr ready #$prn failed"
    fi
    [ "$st" = approved ] || restamp "$num" "<!-- fleet:draft-only approved=$(stamp_now) by=$(who_default) -->"
    printf '批准（草稿单）：PR #%s 已转正。按常规门禁合并（pr_verdict wait → pr_merge），然后 report merged。\n' "$prn" \
      | bash "$BIN/fleet-comment.sh" "$num" --repo "$repo" --to-worker --body-file - >/dev/null 2>&1 \
      || printf 'fleet-draft: approved, but the worker could not be told on #%s\n' "$num" >&2
    printf 'approved #%s → PR #%s ready\n' "$num" "$prn"
    if [ "$merge" = 1 ]; then
      bash "$BIN/fleet-pr-verdict.sh" "$prn" --repo "$repo" --wait >/dev/null
      exec bash "$BIN/fleet-pr-merge.sh" "$prn" --repo "$repo"
    fi
    ;;
  reject)
    [ -n "$reason" ] || die 2 "reject needs --reason"
    st=$(body_of "$num" | scan | head -1) || st=''
    [ "$st" = draft ] || [ "$st" = approved ] || die 4 "#$num is not a draft-only ticket ($st)"
    pr=$(open_pr "$num")
    if [ -n "$pr" ]; then
      gh pr close "${pr%% *}" --repo "$repo" --comment "不做（草稿单被拒）：$reason" >/dev/null \
        || die 1 "gh pr close #${pr%% *} failed"
    fi
    restamp "$num" "<!-- fleet:draft-only rejected=$(stamp_now) by=$(who_default) -->"
    printf '拒绝（草稿单）：%s%s\n' "$reason" "${pr:+ — PR #${pr%% *} 已关闭}" \
      | bash "$BIN/fleet-comment.sh" "$num" --repo "$repo" --to-worker --body-file - >/dev/null 2>&1 \
      || printf 'fleet-draft: rejected, but the reason could not be posted on #%s\n' "$num" >&2
    printf 'rejected #%s%s\n' "$num" "${pr:+ → PR #${pr%% *} closed}"
    ;;
  *) usage ;;
esac
