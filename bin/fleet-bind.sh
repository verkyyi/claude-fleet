#!/bin/bash
# fleet-bind.sh <issue-number> [--force] [--title <t>] — promote THIS scratch
# session into the worker for a GitHub issue, IN PLACE (issue #520).
#
# The flow it serves: press ⌃s (or type a task on the dash prompt line), refine the
# requirement in conversation until it is clear enough to track, file an issue —
# and have THIS session, which already holds all the context, become its worker.
# Before this, the only escalations were `fleet-issue-file.sh --spawn` (which files
# AND starts a SECOND worker that must re-ground from zero) or pushing `scratch-N`
# by hand (which leaves the window unbound: no PR-map row, no gate-reap, and
# /fleet-claim REFUSEs it). The dash's ⌃g bind was pruned in #289.
#
# Since #290 a scratch already owns a `scratch-<K>` branch in its own
# `<repo>-scratch-<K>` worktree, so the promotion is small and local:
#
#   1. RENAME THE BRANCH, NOT THE DIRECTORY — `git branch -m scratch-K issue-N`.
#      The worktree dir keeps its `-scratch-K` name on purpose: moving it under a
#      RUNNING Claude would strand its Bash cwd on a deleted inode and orphan the
#      transcript dir (which is keyed by cwd). The branch is what every downstream
#      consumer actually reads — the repo-wide PR map keys on `headRefName`, the
#      janitor + fleet-cleanup match `issue-<N>`, and the PR closes the issue — so
#      renaming it is the whole promotion.
#   2. RE-MARK THE WINDOW — set @issue=<N>, UNSET @raw (it is no longer an
#      experiment: the reapers must now gate it on the PR like any worker), KEEP
#      @worktree (dash ⌃x still resolves the worktree through it), rename the
#      window after the issue title, and reseed the dash summary.
#   3. CLAIM — assign the issue to @me, the same claim-at-spawn
#      dash-issue-session.sh does, so a peer sees the claim within ~1s.
#
# After it returns, the session IS an ordinary worker: `/fleet-claim` works (the
# seat widened in #520 for exactly this shape), the dash shows a worker row, and
# the ship contract is unchanged — push `issue-<N>`, open a PR with `Closes #<N>`,
# merge it on a READY verdict.
#
# --force (alias --reclaim) is the escape hatch past a stale claim, mirroring
# dash-issue-session.sh: it skips the claim CHECK and the claim WRITE entirely.
# --title <t> is the authoritative window name for a create-then-bind caller
# (fleet-issue-file.sh --bind), which just wrote the issue and needs no gh read.
#
# Exit codes — one per rail, each printed on stderr:
#   0  bound
#   2  usage (no/garbage issue number, unknown flag)
#   3  REFUSE — wrong pane: not inside a tmux pane, already @issue-bound, or not a
#      scratch (`@raw` + a `scratch-<K>` worktree on the matching branch)
#   4  taken — a live window in this fleet already binds #N, or the issue is
#      claimed/closed/has an open PR (use --force to override a stale claim)
#   1  failed — no fleet checkout, the `issue-<N>` branch already exists, or the
#      rename failed. The scratch is left exactly as it was.
#
# Pane-only by design, so bare `tmux` is correct: inside a pane $TMUX already names
# this fleet's socket (the CLAUDE.md socket rail), like fleet-claim-brief.sh.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() {  # <message> <exit-code> — stderr is the record; the status line is the glance
  printf 'fleet-bind: %s\n' "$1" >&2
  tmux display-message -d "${FLEET_REFUSE_MS:-4000}" "#[fg=red,bold] bind: $1 " 2>/dev/null
  exit "${2:-1}"
}

# --- args ---------------------------------------------------------------------
num=""; FORCE=0; TITLE=""; _want=""
for _a in "$@"; do
  if [ -n "$_want" ]; then
    case "$_want" in title) TITLE="$_a" ;; esac
    _want=""; continue
  fi
  case "$_a" in
    --force|--reclaim) FORCE=1 ;;
    --title)   _want=title ;;
    --title=*) TITLE="${_a#--title=}" ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    # An unknown dash-flag is a caller bug (a typo like --forc). NEVER let it fall
    # through to the issue-number slot: it strips to "" and would bind the wrong thing.
    --*) printf 'fleet-bind: unknown flag %s\n' "$_a" >&2; exit 2 ;;
    *)   [ -z "$num" ] && num="$_a" ;;
  esac
done
[ -n "$_want" ] && { printf 'fleet-bind: --title needs a value\n' >&2; exit 2; }
num="${num//[^0-9]/}"
[ -n "$num" ] || { printf 'fleet-bind: usage: fleet-bind.sh <issue-number> [--force] [--title <t>]\n' >&2; exit 2; }

# --- the caller's pane: one probe, five fields --------------------------------
[ -n "${TMUX_PANE:-}" ] || die "not inside a tmux pane — run this from the scratch session you want to bind" 3
probe=$(tmux display-message -p -t "$TMUX_PANE" \
          '#{window_id}|#{@issue}|#{@raw}|#{@worktree}|#{pane_current_path}' 2>/dev/null)
[ -n "$probe" ] || die "cannot read this pane's window (is tmux running?)" 3
WIN=${probe%%|*};  probe=${probe#*|}
at_issue=${probe%%|*}; probe=${probe#*|}
at_raw=${probe%%|*};   probe=${probe#*|}
at_wt=${probe%%|*};    pane_cwd=${probe#*|}
at_issue="${at_issue//[^0-9]/}"

# Already a worker → refuse. One worktree, one issue, one PR: re-binding a live
# worker would strand its branch and leave two windows racing on one issue.
[ -n "$at_issue" ] && die "this window is already bound to #$at_issue — one worktree, one issue" 3
[ "$at_raw" = 1 ] || die "not a scratch session (no @raw) — bind only promotes a scratch window" 3

# --- the scratch identity: worktree + its branch ------------------------------
WT="${at_wt:-$pane_cwd}"
slug=$(fleet_scratch_key "$WT")
[ -n "$slug" ] || die "no scratch worktree resolved (@worktree=${at_wt:-none}) — not a scratch-<N> worktree" 3
[ -d "$WT" ]   || die "the scratch worktree is gone: $WT" 3
cur_branch=$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)
[ "$cur_branch" = "$slug" ] \
  || die "worktree $WT is on branch '${cur_branch:-none}', not '$slug' — refusing to rename someone else's branch" 3

SESS=$(fleet_current_session)
fleet_load_conf "$SESS"
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$SESS"); [ -n "$_r" ] && REPO="$_r"
MAIN="${FLEET_MAIN:-}"
[ -d "$MAIN/.git" ] || die "FLEET_MAIN is not a git checkout — set it in fleet.conf" 1
branch="issue-$num"

# --- rails, cheapest first, each leaving the scratch untouched ----------------
# The target branch must be free. Checked BEFORE the gh gate so a doomed bind
# never claims an issue it cannot actually take.
git -C "$MAIN" show-ref --verify --quiet "refs/heads/$branch" \
  && die "branch $branch already exists — #$num already has a worktree somewhere" 1

# A live window in THIS fleet already bound to #N (the local half of the dedup
# dash-issue-session.sh does). Our own window is excluded — it has no @issue yet,
# but the id compare keeps this honest if that ever changes.
dup=$(tmux list-windows -F '#{@issue} #{window_id}' 2>/dev/null \
        | awk -v n="$num" -v self="$WIN" '$1==n && $2!=self {print $2; exit}')
[ -n "$dup" ] && die "#$num is already bound to a live window in this fleet — nothing to bind" 4

# Cross-machine claim gate — the same read dash-issue-session.sh makes at spawn.
# A gh outage degrades to bind-anyway (never a false refusal), matching the spawner.
if [ "$FORCE" != 1 ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  cs=$(gh issue view "$num" --repo "$REPO" --json assignees,state \
        --jq '"\(.assignees|length)\t\(.state)"' 2>/dev/null)
  n_assignee=${cs%%$'\t'*}; st=${cs#*$'\t'}
  n_assignee="${n_assignee//[^0-9]/}"
  n_open_pr=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq 'length' 2>/dev/null)
  n_open_pr="${n_open_pr//[^0-9]/}"
  if [ "${n_assignee:-0}" -gt 0 ] \
     || { [ -n "$st" ] && [ "$st" != OPEN ]; } || [ "${n_open_pr:-0}" -gt 0 ]; then
    die "#$num is already claimed (or closed / has an open PR) — --force to bind anyway" 4
  fi
fi

# --- the promotion ------------------------------------------------------------
# Run the rename FROM the worktree: the branch is checked out there, and git
# updates that worktree's HEAD in place, so the running session's cwd never moves.
git -C "$WT" branch -m "$slug" "$branch" >/dev/null 2>&1 \
  || die "could not rename branch $slug → $branch" 1

# Claim: assign @me, exactly the claim-at-spawn the spawner does, so a peer's
# dedup read sees this within ~1s. --force skips it (the claim is why it refused).
[ "$FORCE" != 1 ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1 \
  && gh issue edit "$num" --repo "$REPO" --add-assignee @me >/dev/null 2>&1

# Window name from the issue CONTENT (issue #216's rule): an explicit --title wins
# and costs no round-trip; else one gh read; else the bare issue-<N> slug.
title="$TITLE"
if [ -z "$title" ] && [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  title=$(gh issue view "$num" --repo "$REPO" --json title -q .title 2>/dev/null)
fi
wname=$(fleet_win_name "$title"); [ -z "$wname" ] && wname="$branch"

# Re-mark the window as a worker. @raw goes (the reapers must gate it on the PR
# now, not treat it as a disposable experiment); @worktree STAYS (dash ⌃x resolves
# the worktree through it, and the dir is still named -scratch-K, so the usual
# issue-<N> path guess would miss it).
tmux set-window-option -t "$WIN" @issue "$num" 2>/dev/null
tmux set-window-option -t "$WIN" -u @raw 2>/dev/null
tmux rename-window -t "$WIN" -- "$wname" 2>/dev/null

# Reseed the dash summary so the row stops reading "scratch-K (raw session)"
# before the next summarizer tick — same key/format the readers expect, and the
# same split the spawner uses: the FILE keeps the raw text, the window option
# takes the sanitized copy (pane-border-format re-parses it, #455).
seed="bound #$num"; [ -n "$title" ] && seed="$seed: $title"
printf '%s' "$seed" > "$(fleet_cache_global)/summary_$(fleet_summary_key "$SESS" "$WIN")" 2>/dev/null || :
tmux set-window-option -t "$WIN" @summary "$(fleet_summary_sanitize "$seed")" 2>/dev/null || :

printf 'bound: this session is now the worker for #%s (branch %s, worktree %s)\n' "$num" "$branch" "$WT"
printf 'ship it the usual way: git push -u origin %s · PR body "Closes #%s" · merge on a READY verdict\n' "$branch" "$num"
exit 0
