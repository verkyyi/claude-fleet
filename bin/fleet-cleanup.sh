#!/bin/bash
# fleet-cleanup.sh <PR> [--dry-run] — the SEAT-AGNOSTIC, no-LLM, no-merge janitor
# (issue #277). The fleet NEVER merges: GitHub auto-merge (armed by /fleet-ship),
# a human clicking Merge on the web, or a collaborator does the merge; this script
# is what runs AFTER a merge to clean up and keep the session resumable. It is the
# mechanical core the cleanup daemon (com.claude-fleet.cleanup) and the manual
# /fleet-cleanup command both drive.
#
# It is bin/fleet-land.sh MINUS the merge: no lease-hold-through-green, no
# gh pr merge, no --match-head-commit race. Given a PR whose state is already
# FINAL (MERGED, or CLOSED-unmerged) it:
#
#   1. CAPTURE THE LEDGER ROW FIRST — session/transcript id, window, worktree
#      path, branch, merge sha, issue — while the worktree/window still exist.
#      Resume depends on this ordering (fleet-history.sh record, best-effort).
#   2. base fast-forward — git -C $FLEET_MAIN pull --ff-only, holding the per-repo
#      land lease (the SAME lock every base-mover took — serialize base movers;
#      the lease survives even though the merge moved to GitHub). MERGED only.
#   3. ordered teardown — kill the worker window FIRST (frees the busy cwd), THEN
#      git worktree remove + branch -D issue-<N>. If the CALLER stands on the
#      worktree being removed (a worker cleaning up its own merged PR), teardown
#      detaches into the tmux server so it can't saw off the branch it sits on.
#      worktree-autoclean.sh stays the backstop.
#
# Merge-source-agnostic: it reaps the same whether GitHub auto-merge, a web merge,
# or a collaborator did the merge — it reads the PR's final state, it does not
# merge. Idempotent + safe on already-half-cleaned state: an already-torn-down PR
# is a no-op (skip:nothing). An OPEN PR is not final — nothing to clean yet.
#
# It touches only $FLEET_MAIN (the base pull + teardown) — never another fleet's
# repo, and never the live install (~/.claude/fleet). It makes NO merge and NO
# force: a PR that is still OPEN is left alone (skip:not-final).
#
# Result token on stdout (the ONLY thing on stdout; progress is on stderr):
#   cleaned:<sha>    MERGED → ledger recorded + base fast-forwarded + teardown
#   cleaned:closed   CLOSED-unmerged → orphan worktree/window reaped (no base pull)
#   skip:not-final   PR still OPEN — not merged/closed, nothing to clean (rc 0)
#   skip:nothing     final PR but no worktree AND no window to reap (already clean)
#   error:<reason>   a precondition failed (no repo/main/gh/PR) — rc 2
#
# Env knobs (all optional):
#   LAND_LEASE_TTL       lease lifetime, seconds           (default 3600)
#   LAND_QUEUE_TIMEOUT   max seconds to WAIT for the lease (default 300)
#   LAND_POLL            seconds between lease-queue polls  (default 15)
#   FLEET_LAND_LEASE_DIR SHARED lease dir for ALL landers  (default ~/.claude/leases)
#   LAND_LEASE_DIR       per-tool override of the lease dir (tests)
#   CLEANUP_DRY_TEARDOWN 1 = print the teardown cmds, don't run them (tests)
#   FLEET_SESSION        override the resolved fleet session (daemon callers)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

POLL="${LAND_POLL:-15}"
QUEUE_TIMEOUT="${LAND_QUEUE_TIMEOUT:-300}"
LEASE_TTL="${LAND_LEASE_TTL:-3600}"
LEASE_DIR="${LAND_LEASE_DIR:-${FLEET_LAND_LEASE_DIR:-$HOME/.claude/leases}}"

# --- args ---------------------------------------------------------------------
PR=""; DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) shift; PR="${1:-}"; PR="${PR//[^0-9]/}" ;;
    --dry-run|-n) DRY=1 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'fleet-cleanup: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)  PR="${1//[^0-9]/}" ;;
  esac
  shift
done
[ -z "$PR" ] && { printf 'fleet-cleanup: a PR number is required (fleet-cleanup.sh <PR>).\n' >&2; exit 2; }

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
[ -z "$REPO" ] && { note "fleet-cleanup: no repo resolved — run inside a fleet."; done_token "error:no-repo"; exit 2; }
[ -d "$MAIN/.git" ] || { note "fleet-cleanup: FLEET_MAIN is not a git checkout."; done_token "error:no-main"; exit 2; }
command -v gh >/dev/null 2>&1 || { note "fleet-cleanup: gh not on PATH."; done_token "error:no-gh"; exit 2; }

# tmux dividing line (issue #159): in a pane $TMUX carries the right socket → bare
# tmux; a daemon has no $TMUX → target the fleet's OWN socket by label.
ftmux() {
  if [ -n "${TMUX:-}" ]; then tmux "$@"
  else tmux -L "$(fleet_socket "$FLEET_SESSION")" "$@"; fi
}

# --- PR state -----------------------------------------------------------------
# TSV: state headOid headRef  (no mergeability/checks — we don't merge)
pr_fields() {
  gh pr view "$1" --repo "$REPO" \
    --json state,headRefOid,headRefName \
    --jq '[.state, .headRefOid, .headRefName] | @tsv' 2>/dev/null
}

fields=$(pr_fields "$PR")
[ -z "$fields" ] && { note "fleet-cleanup: PR #$PR not found on $REPO."; done_token "error:pr-not-found"; exit 2; }
IFS=$'\t' read -r st oid href <<<"$fields"
case "$href" in
  issue-[0-9]*) ISSUE="${href#issue-}"; ISSUE="${ISSUE%%[!0-9]*}" ;;
  *) ISSUE="" ;;   # a non-issue-<N> head PR has no worktree/window to reap
esac

note "fleet-cleanup: repo=$REPO  pr=#$PR  head=$href  issue=${ISSUE:-none}  state=$st$([ "$DRY" = 1 ] && echo '  (dry-run)')"

# --- only FINAL PRs are cleanable ---------------------------------------------
case "$st" in
  MERGED) : ;;
  CLOSED) : ;;
  *)      note "  #$PR is $st — not final (not merged/closed); nothing to clean."; done_token "skip:not-final"; exit 0 ;;
esac

# --- dry-run: report what we WOULD do, take no lease, mutate nothing ----------
if [ "$DRY" = 1 ]; then
  case "$st" in
    MERGED) done_token "dry:would-clean-merged" ;;
    CLOSED) done_token "dry:would-reap-closed" ;;
  esac
  exit 0
fi

# --- resolve the worktree + window for issue-<N> (idempotency hinges on this) --
# Both empty on a final PR ⇒ already cleaned (or a non-issue head) ⇒ no-op.
WT=""; WIN=""
if [ -n "$ISSUE" ]; then
  WT=$(git -C "$MAIN" worktree list --porcelain 2>/dev/null | \
       awk -v b="issue-$ISSUE" '/^worktree /{p=$2} $0 ~ "branch refs/heads/"b"$"{print p}')
  WIN=$(ftmux list-windows -t "$FLEET_SESSION" -F '#{window_id} #{@issue}' 2>/dev/null | \
        awk -v i="$ISSUE" '$2==i{print $1}')
fi

# --- teardown: kill window → drop worktree → delete branch --------------------
# If the CALLER is inside the worktree (a worker cleaning up its own PR), detach
# the teardown into the tmux server — you can't remove the ground you stand on.
teardown() {
  [ -z "$ISSUE" ] && { note "  no issue-<N> head — nothing to reap."; return 0; }
  local self_win cwd
  self_win=$(ftmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)
  cwd=$(pwd -P 2>/dev/null)

  local detach=0
  [ -n "$WIN" ] && [ -n "$self_win" ] && [ "$WIN" = "$self_win" ] && detach=1
  if [ -n "$WT" ]; then case "$cwd" in "$WT"|"$WT"/*) detach=1 ;; esac; fi

  if [ "$detach" = 1 ]; then
    # Silence the git steps (issue #192): run-shell surfaces non-empty output as a
    # view-mode overlay on the attached client.
    local cmd="tmux kill-window -t ${WIN:-@self}; { git -C '$MAIN' worktree remove --force '$WT'; git -C '$MAIN' branch -D 'issue-$ISSUE'; } >/dev/null 2>&1"
    note "  teardown (detached): $cmd"
    [ "${CLEANUP_DRY_TEARDOWN:-0}" = 1 ] && return 0
    ftmux run-shell -b "$cmd" 2>/dev/null || \
      note "  teardown: tmux run-shell failed — worktree-autoclean.sh will reap the merged worktree."
    return 0
  fi

  note "  teardown: kill-window ${WIN:-none} → worktree remove ${WT:-none} → branch -D issue-$ISSUE"
  if [ "${CLEANUP_DRY_TEARDOWN:-0}" = 1 ]; then return 0; fi
  # Ordering is load-bearing: kill the window FIRST so the worker process dies and
  # releases the busy cwd, THEN remove the worktree, THEN delete the branch.
  [ -n "$WIN" ] && ftmux kill-window -t "$WIN" 2>/dev/null
  if [ -n "$WT" ]; then
    git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || \
      note "  worktree remove failed for $WT — worktree-autoclean.sh will reap it."
  fi
  git -C "$MAIN" branch -D "issue-$ISSUE" >/dev/null 2>&1 || true
}

# --- closed-unmerged: reap the orphan worktree/window, no base pull, no ledger -
# A closed-unmerged PR abandoned its work — there is nothing merged into the base
# and it is not a "landed" session, so we skip both the base pull and the resume
# ledger; we only reap the orphaned worktree + window so the estate stays clean.
if [ "$st" = CLOSED ]; then
  if [ -z "$WT" ] && [ -z "$WIN" ]; then
    note "  #$PR closed-unmerged, nothing left to reap (already clean)."
    done_token "skip:nothing"; exit 0
  fi
  note "  #$PR closed-unmerged — reaping the orphaned worktree/window (no merge, no base pull)."
  teardown
  done_token "cleaned:closed"; exit 0
fi

# --- MERGED: ledger row → base fast-forward (lease) → teardown -----------------
if [ -z "$WT" ] && [ -z "$WIN" ]; then
  # Both gone ⇒ another cleaner (daemon, janitor, a prior run) already reaped it.
  # The base pull is idempotent, but with nothing to reap we treat this as a no-op
  # so a second run doesn't append a duplicate ledger row.
  note "  #$PR merged but no worktree/window left to reap (already cleaned)."
  done_token "skip:nothing"; exit 0
fi

# History ledger BEFORE teardown, while the worktree path (→ transcript dir +
# session id) is still resolvable. Best-effort — never blocks the cleanup.
if [ -n "$ISSUE" ] && [ -n "$WT" ]; then
  bash "$BIN/fleet-history.sh" record \
    --repo "$REPO" --main "$MAIN" --session "$FLEET_SESSION" \
    --pr "$PR" --issue "$ISSUE" --worktree "$WT" --win "$WIN" >/dev/null 2>&1 || true
fi

# Base fast-forward under the SHARED land lease — serialize base movers. We take
# the lease ONLY for the pull (a quick, bounded op), not a hold-through-green.
LEASE="$LEASE_DIR/land-$(fleet_slug "$(fleet_norm_repo "$REPO")").lock"
# shellcheck disable=SC2329  # invoked via the EXIT/INT/TERM traps below
cleanup_lease() { land_lease_release "$LEASE"; }
trap cleanup_lease EXIT
trap 'cleanup_lease; exit 130' INT
trap 'cleanup_lease; exit 143' TERM

note "  acquiring land lease $LEASE (base fast-forward) …"
SECONDS=0
until land_lease_acquire "$LEASE" "$LEASE_TTL" "${FLEET_SESSION:-$USER}:$$"; do
  if [ "$SECONDS" -ge "$QUEUE_TIMEOUT" ]; then
    note "  gave up waiting ${QUEUE_TIMEOUT}s for the land lease (held by $(land_lease_holder "$LEASE")) — reaping anyway; the next base-mover will pull."
    break
  fi
  note "  land lease busy (held by $(land_lease_holder "$LEASE")) — waiting ${POLL}s"
  sleep "$POLL"
done

git -C "$MAIN" fetch origin "$BASE" --quiet 2>/dev/null
if ! git -C "$MAIN" pull --ff-only >/dev/null 2>&1; then
  note "  base checkout $MAIN would not fast-forward — resolve it by hand (something diverged locally)."
fi
land_lease_release "$LEASE"

teardown
done_token "cleaned:${oid:-merged}"
exit 0
