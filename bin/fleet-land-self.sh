#!/bin/bash
# fleet-land-self.sh [--pr N] [--dry-run] — the WORKER-OWNED land: a one-PR
# merge-train step that a worker runs to land its OWN PR after the steward
# triggers it (issue #138). It is the mechanical core the /fleet-land-self skill
# calls, exactly as /fleet-land-train calls bin/land-train.sh.
#
# It mirrors ONE lap of the land-train, scoped to the caller's own issue-<N> PR:
#
#   lease acquire (per-repo)   the SAME lock bin/land-train.sh takes — landing on
#                              a repo is single-writer whoever drives it
#   HOLD THROUGH GREEN:
#     if BEHIND  → update-branch   (only while holding the lease — never early)
#     wait CLEAN → poll until green + up to date  (master can't move under us)
#     re-validate → land_lease_mine + --match-head-commit  (a stolen lease / a
#                   head-sha race aborts the merge instead of landing blind)
#     merge      → gh pr merge --squash --match-head-commit
#   base fast-forward          git -C $FLEET_MAIN pull --ff-only
#   self-destruct              a DETACHED, server-side tmux run-shell that kills
#                              this window, then removes the worktree + branch —
#                              the worker can't remove the ground it stands on, so
#                              it hands the teardown to the tmux server and exits.
#                              worktree-autoclean.sh stays the backstop.
#
# It NEVER forces: a PR that is conflicting / failing / blocked / not-its-own is
# EJECTED with a reason (rc 3) so the skill can /fleet-blocked instead of merging
# a red or foreign PR. It touches only $FLEET_REPO (one merge) and $FLEET_MAIN
# (the base pull) — never another fleet's repo, and never the live install.
#
# Result token on stdout (the ONLY thing on stdout; progress is on stderr):
#   landed:<sha>     merged + base fast-forwarded + self-destruct launched
#   landed:already   PR was already merged; base pulled + self-destruct launched
#   eject:<reason>   not landable (conflict/failing/blocked/foreign/timeout) — rc 3
#   error:<reason>   a precondition failed (no repo/branch/PR) — rc 2
#
# Env knobs (all optional):
#   LAND_SELF_METHOD        squash|merge|rebase            (default squash)
#   LAND_SELF_POLL          seconds between state polls     (default 15)
#   LAND_SELF_MAX_HOLD      max seconds to hold-through-green(default 1800)
#   LAND_SELF_QUEUE_TIMEOUT max seconds to WAIT for the lease(default 1800)
#   LAND_SELF_MAX_RETRY     bounded behind/race retries      (default 3)
#   LAND_SELF_LEASE_TTL     lease lifetime, seconds          (default 3600)
#   FLEET_LAND_LEASE_DIR    SHARED lease dir for BOTH landers (default
#                           ~/.claude/leases) — relocate the land lock here so
#                           land-train + self-land stay on the same lock
#   LAND_SELF_LEASE_DIR     per-tool override of the lease dir (tests)
#   LAND_SELF_DRY_DESTRUCT  1 = print the self-destruct cmd, don't run it (tests)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-land-lease.sh"

METHOD="${LAND_SELF_METHOD:-squash}"
POLL="${LAND_SELF_POLL:-15}"
MAX_HOLD="${LAND_SELF_MAX_HOLD:-1800}"
QUEUE_TIMEOUT="${LAND_SELF_QUEUE_TIMEOUT:-1800}"
MAX_RETRY="${LAND_SELF_MAX_RETRY:-3}"
LEASE_TTL="${LAND_SELF_LEASE_TTL:-3600}"
LEASE_DIR="${LAND_SELF_LEASE_DIR:-${FLEET_LAND_LEASE_DIR:-$HOME/.claude/leases}}"

# --- args ---------------------------------------------------------------------
PR=""; DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) shift; PR="${1:-}"; PR="${PR//[^0-9]/}" ;;
    --dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'fleet-land-self: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)  PR="${1//[^0-9]/}" ;;
  esac
  shift
done
case "$METHOD" in squash|merge|rebase) ;; *) printf 'fleet-land-self: bad method %s\n' "$METHOD" >&2; exit 2 ;; esac

# All human-facing progress goes to STDERR so the caller can capture the single
# result token off stdout (the land-train #68 lesson).
note() { printf '%s\n' "$*" >&2; }
done_token() { printf '%s\n' "$1"; }

# --- resolve fleet identity (this fleet only — never a cwd default) ------------
FLEET_SESSION=$(fleet_current_session)
fleet_load_conf "$FLEET_SESSION"
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
MAIN="${FLEET_MAIN:-}"
BASE="${FLEET_BASE_BRANCH:-master}"
[ -z "$REPO" ] && { note "fleet-land-self: no repo resolved — run inside a fleet."; done_token "error:no-repo"; exit 2; }
[ -d "$MAIN/.git" ] || { note "fleet-land-self: FLEET_MAIN is not a git checkout."; done_token "error:no-main"; exit 2; }
command -v gh >/dev/null 2>&1 || { note "fleet-land-self: gh not on PATH."; done_token "error:no-gh"; exit 2; }

# --- resolve THIS worker's branch / issue / PR --------------------------------
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
case "$BRANCH" in
  issue-[0-9]*) ISSUE="${BRANCH#issue-}"; ISSUE="${ISSUE%%[!0-9]*}" ;;
  *) note "fleet-land-self: not on an issue-<N> branch (HEAD=$BRANCH) — self-land runs from a worker worktree."; done_token "error:not-a-worker-branch"; exit 2 ;;
esac
WT=$(pwd -P 2>/dev/null)
# This worker's window-id, resolved ONCE (both the history record and the
# self-destruct need it; resolving it here avoids re-forking tmux on the hot path).
SELF_WIN=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)

# Resolve the PR for this branch if not given explicitly.
if [ -z "$PR" ]; then
  PR=$(gh pr view "$BRANCH" --repo "$REPO" --json number -q .number 2>/dev/null)
  PR="${PR//[^0-9]/}"
fi
[ -z "$PR" ] && { note "fleet-land-self: no PR found for $BRANCH — /fleet-ship first."; done_token "error:no-pr"; exit 2; }

# --- PR state -----------------------------------------------------------------
# TSV: state mergeable mergeStateStatus draft checks headOid headRef
pr_fields() {
  gh pr view "$1" --repo "$REPO" \
    --json state,mergeable,mergeStateStatus,isDraft,statusCheckRollup,headRefOid,headRefName \
    --jq '[.state, .mergeable, .mergeStateStatus,
           (if .isDraft then "DRAFT" else "-" end),
           ((.statusCheckRollup // []) |
             if length==0 then "none"
             elif any(.conclusion=="FAILURE" or .conclusion=="CANCELLED"
                      or .conclusion=="TIMED_OUT" or .conclusion=="ACTION_REQUIRED") then "fail"
             elif any(.status!="COMPLETED") then "pending"
             else "pass" end),
           .headRefOid, .headRefName] | @tsv' 2>/dev/null
}

# The verdict taxonomy is the SHARED land_classify (bin/fleet-land-lease.sh) — one
# source so self-land and land-train can't drift. We only add MERGED on top: an
# already-landed PR (a manual steward merge, or a prior run that merged but whose
# self-destruct failed) short-circuits to the base-pull + cleanup path.
classify() {
  [ "$1" = MERGED ] && { echo MERGED; return; }
  land_classify "$@"
}

backoff() { local b=$(( POLL * $1 )); [ "$b" -gt 60 ] && b=60; printf '%s' "$b"; }

# --- ownership guard: refuse to land a PR that isn't this worker's own ---------
fields=$(pr_fields "$PR")
[ -z "$fields" ] && { note "fleet-land-self: PR #$PR not found on $REPO."; done_token "error:pr-not-found"; exit 2; }
IFS=$'\t' read -r st mg ms dr ck oid href <<<"$fields"
if [ "$href" != "$BRANCH" ]; then
  note "fleet-land-self: PR #$PR head is '$href', not this worker's '$BRANCH' — refusing to land a foreign PR."
  done_token "eject:not-own-pr"; exit 3
fi

note "fleet-land-self: repo=$REPO  pr=#$PR  branch=$BRANCH  issue=#$ISSUE  method=$METHOD$([ "$DRY" = 1 ] && echo '  (dry-run)')"

# --- lease: one lander per repo (shared with land-train) -----------------------
LEASE="$LEASE_DIR/land-$(fleet_slug "$(fleet_norm_repo "$REPO")").lock"
# shellcheck disable=SC2329  # invoked via the EXIT/INT/TERM traps below
cleanup() { land_lease_release "$LEASE"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- dry-run: report the verdict, take no lease, mutate nothing ----------------
if [ "$DRY" = 1 ]; then
  cls=$(classify "$st" "$mg" "$ms" "$dr" "$ck")
  note "  #$PR [$ms/$ck] → $cls"
  case "$cls" in
    READY)   done_token "dry:would-merge" ;;
    BEHIND)  done_token "dry:would-update-then-merge" ;;
    PENDING) done_token "dry:would-wait" ;;
    MERGED)  done_token "dry:already-merged" ;;
    *)       done_token "dry:would-eject:$cls" ;;
  esac
  exit 0
fi

# --- self-destruct: a DETACHED server-side teardown (kill window → drop worktree)
# The worker's own process holds the worktree cwd, so we can't remove it from
# under ourselves. `tmux run-shell -b` runs in the tmux SERVER (not this pane), so
# after we exit it kills the window (our process dies, releasing the cwd) and only
# THEN removes the worktree + branch. Ordering is load-bearing: worktree-remove
# before the window dies would fail on the busy cwd.
self_destruct() {
  local cmd
  # Silence the git steps: run-shell surfaces any non-empty command output in a
  # view-mode overlay on the attached client, and since kill-window switches that
  # client to the plan window, `git branch -D`'s "Deleted branch …" line would land
  # as an Esc-to-dismiss overlay ON THE STEWARD (issue #192). kill-window stays
  # un-redirected (it produces no output on success); only the git stdout/stderr is dropped.
  cmd="tmux kill-window -t ${SELF_WIN:-@self}; { git -C '$MAIN' worktree remove --force '$WT'; git -C '$MAIN' branch -D 'issue-$ISSUE'; } >/dev/null 2>&1"
  note "  self-destruct: $cmd"
  if [ "${LAND_SELF_DRY_DESTRUCT:-0}" = 1 ]; then return 0; fi
  tmux run-shell -b "$cmd" 2>/dev/null || {
    note "  self-destruct: tmux run-shell failed — worktree-autoclean.sh will reap the merged worktree as the backstop."
    return 1
  }
}

# --- land: pull base, record history, self-destruct ---------------------------
land_after_merge() {
  local sha="$1"
  git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
  if ! git -C "$MAIN" pull --ff-only >/dev/null 2>&1; then
    note "  base checkout $MAIN would not fast-forward — resolve it by hand (something diverged locally)."
  fi
  # History ledger (best-effort; never blocks the land) so the finished session
  # stays reviewable/resumable after self-destruct removes the worktree.
  bash "$BIN/fleet-history.sh" record \
    --repo "$REPO" --main "$MAIN" \
    --pr "$PR" --issue "$ISSUE" --worktree "$WT" --win "$SELF_WIN" >/dev/null 2>&1 || true
  self_destruct || true
  done_token "landed:${sha:-merged}"
}

# --- run: acquire the lease (queue), then hold through green -------------------
note "  acquiring land lease $LEASE …"
SECONDS=0
until land_lease_acquire "$LEASE" "$LEASE_TTL"; do
  if [ "$SECONDS" -ge "$QUEUE_TIMEOUT" ]; then
    note "  gave up waiting ${QUEUE_TIMEOUT}s for the land lease (held by $(land_lease_holder "$LEASE"))."
    done_token "eject:lease-wait-timeout"; exit 3
  fi
  note "  land lease busy (held by $(land_lease_holder "$LEASE")) — waiting ${POLL}s"
  sleep "$POLL"
done
note "  land lease acquired."

behind_retry=0; merge_retry=0; blip_retry=0
SECONDS=0
while [ "$SECONDS" -lt "$MAX_HOLD" ]; do
  fields=$(pr_fields "$PR")
  # An empty read is almost always a TRANSIENT gh hiccup (network blip, a 5xx, a
  # secondary-rate-limit), NOT the PR vanishing — aborting the land on the first
  # one would abandon a green, mergeable PR (and release the lease) over a blip. So
  # tolerate a bounded run of consecutive empty reads before giving up; a good read
  # resets the counter. Only after MAX_RETRY blips in a row do we treat it as real.
  if [ -z "$fields" ]; then
    blip_retry=$((blip_retry + 1))
    if [ "$blip_retry" -gt "$MAX_RETRY" ]; then
      note "  #$PR unreadable after $blip_retry consecutive gh failures — giving up."
      done_token "error:pr-unreadable"; exit 2
    fi
    note "  #$PR read failed (transient?) — retry $blip_retry/$MAX_RETRY in ${POLL}s"
    sleep "$POLL"; continue
  fi
  blip_retry=0
  IFS=$'\t' read -r st mg ms dr ck oid href <<<"$fields"
  cls=$(classify "$st" "$mg" "$ms" "$dr" "$ck")
  case "$cls" in
    MERGED)
      note "  #$PR already merged — landing the base checkout."
      land_after_merge "already"; exit 0 ;;
    GONE)     note "  #$PR is closed (not merged) — nothing to land."; done_token "eject:closed-unmerged"; exit 3 ;;
    DRAFT)    note "  #$PR is a draft."; done_token "eject:draft"; exit 3 ;;
    CONFLICT) note "  #$PR conflicts with $BASE — needs a rebase."; done_token "eject:conflict-needs-rebase"; exit 3 ;;
    FAILING)  note "  #$PR has a failing required check."; done_token "eject:required-check-failed"; exit 3 ;;
    BLOCKED)  note "  #$PR is blocked (review required / branch protection)."; done_token "eject:blocked"; exit 3 ;;
    BEHIND)
      behind_retry=$((behind_retry + 1))
      if [ "$behind_retry" -gt "$MAX_RETRY" ]; then done_token "eject:stuck-behind"; exit 3; fi
      note "  #$PR behind $BASE — update-branch (attempt $behind_retry/$MAX_RETRY)"
      gh pr update-branch "$PR" --repo "$REPO" >/dev/null 2>&1 || true
      sleep "$(backoff "$behind_retry")" ;;
    PENDING)
      note "  #$PR checks pending — waiting ${POLL}s"
      sleep "$POLL" ;;
    READY)
      # Re-validate on resume: a lease we slept through CAN be stolen (steal-if-
      # stale), so confirm we still own it before merging. --match-head-commit is
      # the second guard: it refuses the merge if the head sha moved under us.
      if ! land_lease_mine "$LEASE"; then
        note "  lost the land lease while waiting (stolen as stale) — re-acquiring."
        land_lease_acquire "$LEASE" "$LEASE_TTL" || { done_token "eject:lease-lost"; exit 3; }
        continue
      fi
      note "  #$PR green + up to date — merging (--$METHOD, match-head $oid)"
      if out=$(gh pr merge "$PR" --repo "$REPO" "--$METHOD" --match-head-commit "$oid" 2>&1); then
        note "  #$PR merged."
        land_after_merge "$oid"; exit 0
      fi
      merge_retry=$((merge_retry + 1))
      if [ "$merge_retry" -gt "$MAX_RETRY" ]; then note "  merge failed: ${out##*$'\n'}"; done_token "eject:merge-failed"; exit 3; fi
      note "  #$PR merge lost the head-sha race — retry $merge_retry/$MAX_RETRY (${out##*$'\n'})"
      sleep "$(backoff "$merge_retry")" ;;
  esac
done
note "  exceeded max-hold ${MAX_HOLD}s holding the lease — releasing so the queue moves."
done_token "eject:max-hold-timeout"; exit 3
