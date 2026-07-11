#!/bin/bash
# fleet-land.sh <PR> [--dry-run] — the SEAT-AGNOSTIC, no-LLM lander (issue #231):
# the single reusable script that runs the mechanical land for ONE PR OUTSIDE any
# LLM turn. It is the mechanical core /fleet-land, /fleet-land-train and the future
# dash ⌃l key + auto-land daemon all drive; the *judgment* ("should we land / is the
# work complete") stays the CALLER's concern — this script lands what it's told.
#
# It mirrors ONE lap of the land-train, but keyed on a PR NUMBER (not the caller's
# HEAD branch) so the steward pane, the dash, a daemon, or a worker can all call it:
#
#   lease acquire (per-repo)   the SAME lock bin/land-train.sh + bin/fleet-land-self.sh
#                              take — landing on a repo is single-writer whoever drives
#                              it (this ALSO fixes /fleet-land taking no lease at all).
#   HOLD THROUGH GREEN:
#     if BEHIND  → update-branch   (only while holding the lease — never early)
#     wait CLEAN → poll until green + up to date  (base can't move under us)
#     re-validate → land_lease_mine + --match-head-commit  (a stolen lease / a
#                   head-sha race aborts the merge instead of landing blind)
#     merge      → gh pr merge --squash --match-head-commit
#   base fast-forward          git -C $FLEET_MAIN pull --ff-only
#   history ledger             fleet-history.sh record  (BEFORE any removal)
#   ordered teardown           kill the worker window FIRST (frees the busy cwd),
#                              THEN git worktree remove + branch -D issue-<N>. If the
#                              CALLER stands on the worktree being removed (a worker
#                              landing its own PR), teardown detaches into the tmux
#                              server (kill-window → remove) so it can't saw off the
#                              branch it sits on — the same trick self-land uses.
#                              worktree-autoclean.sh stays the backstop.
#
# It NEVER forces: a PR that is conflicting / failing / blocked / draft / gone is
# EJECTED with a reason (rc 3) — never `--admin`-bypassed. It touches only
# $FLEET_REPO (one merge) and $FLEET_MAIN (the base pull + teardown) — never another
# fleet's repo, and never the live install (~/.claude/fleet).
#
# Result token on stdout (the ONLY thing on stdout; progress is on stderr):
#   landed:<sha>     merged + base fast-forwarded + teardown done/launched
#   landed:already   PR was already merged; base pulled + teardown
#   eject:<reason>   not landable (conflict/failing/blocked/draft/gone/timeout) — rc 3
#   error:<reason>   a precondition failed (no repo/main/gh/PR) — rc 2
#
# NOTE ON WORKERS: a worker landing its OWN PR should prefer bin/fleet-land-self.sh —
# it adds the own-PR ownership guard and pairs with the steward's /land trigger gate.
# fleet-land.sh's self-cwd detection is a safety net, not that approval gate.
#
# Env knobs (all optional):
#   LAND_METHOD          squash|merge|rebase             (default squash)
#   LAND_POLL            seconds between state polls       (default 15)
#   LAND_MAX_HOLD        max seconds to hold-through-green (default 1800)
#   LAND_QUEUE_TIMEOUT   max seconds to WAIT for the lease (default 1800)
#   LAND_MAX_RETRY       bounded behind/race retries       (default 3)
#   LAND_LEASE_TTL       lease lifetime, seconds           (default 3600)
#   FLEET_LAND_LEASE_DIR SHARED lease dir for ALL landers  (default ~/.claude/leases)
#   LAND_LEASE_DIR       per-tool override of the lease dir (tests)
#   LAND_DRY_TEARDOWN    1 = print the teardown cmds, don't run them (tests)
#   FLEET_SESSION        override the resolved fleet session (daemon callers)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

METHOD="${LAND_METHOD:-squash}"
POLL="${LAND_POLL:-15}"
MAX_HOLD="${LAND_MAX_HOLD:-1800}"
QUEUE_TIMEOUT="${LAND_QUEUE_TIMEOUT:-1800}"
MAX_RETRY="${LAND_MAX_RETRY:-3}"
LEASE_TTL="${LAND_LEASE_TTL:-3600}"
LEASE_DIR="${LAND_LEASE_DIR:-${FLEET_LAND_LEASE_DIR:-$HOME/.claude/leases}}"

# --- args ---------------------------------------------------------------------
PR=""; DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) shift; PR="${1:-}"; PR="${PR//[^0-9]/}" ;;
    --dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'fleet-land: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)  PR="${1//[^0-9]/}" ;;
  esac
  shift
done
case "$METHOD" in squash|merge|rebase) ;; *) printf 'fleet-land: bad method %s\n' "$METHOD" >&2; exit 2 ;; esac
[ -z "$PR" ] && { printf 'fleet-land: a PR number is required (fleet-land.sh <PR>).\n' >&2; exit 2; }

# All human-facing progress goes to STDERR so the caller can capture the single
# result token off stdout (the land-train #68 lesson).
note() { printf '%s\n' "$*" >&2; }
done_token() { printf '%s\n' "$1"; }

# --- resolve fleet identity (this fleet only — never a cwd default) ------------
FLEET_SESSION="${FLEET_SESSION:-$(fleet_current_session)}"
fleet_load_conf "$FLEET_SESSION"
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
MAIN="${FLEET_MAIN:-}"
BASE="${FLEET_BASE_BRANCH:-master}"
[ -z "$REPO" ] && { note "fleet-land: no repo resolved — run inside a fleet."; done_token "error:no-repo"; exit 2; }
[ -d "$MAIN/.git" ] || { note "fleet-land: FLEET_MAIN is not a git checkout."; done_token "error:no-main"; exit 2; }
command -v gh >/dev/null 2>&1 || { note "fleet-land: gh not on PATH."; done_token "error:no-gh"; exit 2; }

# tmux dividing line (issue #159): in a pane $TMUX carries the right socket → bare
# tmux; a daemon has no $TMUX → target the fleet's OWN socket by label. One helper
# so every window op below is socket-correct regardless of who called us.
ftmux() {
  if [ -n "${TMUX:-}" ]; then tmux "$@"
  else tmux -L "$(fleet_socket "$FLEET_SESSION")" "$@"; fi
}

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
# source so every lander agrees. We only add MERGED on top: an already-landed PR
# short-circuits to the base-pull + teardown path.
classify() {
  [ "$1" = MERGED ] && { echo MERGED; return; }
  land_classify "$@"
}

backoff() { local b=$(( POLL * $1 )); [ "$b" -gt 60 ] && b=60; printf '%s' "$b"; }

# --- validate the PR + resolve its issue --------------------------------------
fields=$(pr_fields "$PR")
[ -z "$fields" ] && { note "fleet-land: PR #$PR not found on $REPO."; done_token "error:pr-not-found"; exit 2; }
IFS=$'\t' read -r st mg ms dr ck oid href <<<"$fields"
case "$href" in
  issue-[0-9]*) ISSUE="${href#issue-}"; ISSUE="${ISSUE%%[!0-9]*}" ;;
  *) ISSUE="" ;;   # a non-issue-<N> head PR still lands; there's just no worktree/window to reap
esac

note "fleet-land: repo=$REPO  pr=#$PR  head=$href  issue=${ISSUE:-none}  method=$METHOD$([ "$DRY" = 1 ] && echo '  (dry-run)')"

# --- lease: one lander per repo (shared with land-train + self-land) -----------
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

# --- teardown: kill window → drop worktree → delete branch --------------------
# Resolved lazily (after the merge) off $FLEET_MAIN + this fleet's session, so the
# steward/dash/daemon can reap a worker window they don't sit in. If the CALLER is
# inside the worktree (a worker self-landing), the teardown detaches into the tmux
# server — you can't remove the ground you stand on — mirroring self-land's ordering.
teardown() {
  [ -z "$ISSUE" ] && { note "  no issue-<N> head — nothing to reap."; return 0; }
  local wt win self_win cwd
  wt=$(git -C "$MAIN" worktree list --porcelain 2>/dev/null | \
       awk -v b="issue-$ISSUE" '/^worktree /{p=$2} $0 ~ "branch refs/heads/"b"$"{print p}')
  win=$(ftmux list-windows -t "$FLEET_SESSION" -F '#{window_id} #{@issue}' 2>/dev/null | \
        awk -v i="$ISSUE" '$2==i{print $1}')
  self_win=$(ftmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)
  cwd=$(pwd -P 2>/dev/null)

  # Do we stand on the ground we're about to remove? (own window, or cwd inside the
  # worktree). If so, detach the teardown into the tmux server so it runs AFTER we
  # exit — otherwise kill-window would kill us before the worktree removal ran.
  local detach=0
  [ -n "$win" ] && [ -n "$self_win" ] && [ "$win" = "$self_win" ] && detach=1
  if [ -n "$wt" ]; then case "$cwd" in "$wt"|"$wt"/*) detach=1 ;; esac; fi

  if [ "$detach" = 1 ]; then
    # Silence the git steps (issue #192): run-shell surfaces non-empty output as a
    # view-mode overlay on the attached client, and kill-window switches that client
    # to another window — so a stray "Deleted branch" would land as an overlay.
    local cmd="tmux kill-window -t ${win:-@self}; { git -C '$MAIN' worktree remove --force '$wt'; git -C '$MAIN' branch -D 'issue-$ISSUE'; } >/dev/null 2>&1"
    note "  teardown (detached): $cmd"
    [ "${LAND_DRY_TEARDOWN:-0}" = 1 ] && return 0
    ftmux run-shell -b "$cmd" 2>/dev/null || \
      note "  teardown: tmux run-shell failed — worktree-autoclean.sh will reap the merged worktree."
    return 0
  fi

  note "  teardown: kill-window ${win:-none} → worktree remove ${wt:-none} → branch -D issue-$ISSUE"
  if [ "${LAND_DRY_TEARDOWN:-0}" = 1 ]; then return 0; fi
  # Ordering is load-bearing: kill the window FIRST so the worker process dies and
  # releases the busy cwd, THEN remove the worktree, THEN delete the branch.
  [ -n "$win" ] && ftmux kill-window -t "$win" 2>/dev/null
  if [ -n "$wt" ]; then
    git -C "$MAIN" worktree remove --force "$wt" 2>/dev/null || \
      note "  worktree remove failed for $wt — worktree-autoclean.sh will reap it."
  fi
  git -C "$MAIN" branch -D "issue-$ISSUE" >/dev/null 2>&1 || true
}

# --- land: pull base, record history, teardown --------------------------------
land_after_merge() {
  local sha="$1" wt
  git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
  if ! git -C "$MAIN" pull --ff-only >/dev/null 2>&1; then
    note "  base checkout $MAIN would not fast-forward — resolve it by hand (something diverged locally)."
  fi
  # History ledger BEFORE teardown, while the worktree path (→ transcript dir +
  # session id) is still resolvable. Best-effort — never blocks the land.
  if [ -n "$ISSUE" ]; then
    wt=$(git -C "$MAIN" worktree list --porcelain 2>/dev/null | \
         awk -v b="issue-$ISSUE" '/^worktree /{p=$2} $0 ~ "branch refs/heads/"b"$"{print p}')
    local win; win=$(ftmux list-windows -t "$FLEET_SESSION" -F '#{window_id} #{@issue}' 2>/dev/null | \
        awk -v i="$ISSUE" '$2==i{print $1}')
    bash "$BIN/fleet-history.sh" record \
      --repo "$REPO" --main "$MAIN" --session "$FLEET_SESSION" \
      --pr "$PR" --issue "$ISSUE" --worktree "$wt" --win "$win" >/dev/null 2>&1 || true
  fi
  teardown
  done_token "landed:${sha:-merged}"
}

# --- run: acquire the lease (queue), then hold through green -------------------
note "  acquiring land lease $LEASE …"
SECONDS=0
until land_lease_acquire "$LEASE" "$LEASE_TTL" "${FLEET_SESSION:-$USER}:$$"; do
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
  # An empty read is almost always a TRANSIENT gh hiccup, NOT the PR vanishing —
  # tolerate a bounded run of consecutive empties before giving up (a good read
  # resets the counter), so a network blip never abandons a green, mergeable PR.
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
