#!/bin/bash
# fleet-cleanup.sh <PR> [--dry-run] — the SEAT-AGNOSTIC, no-LLM, no-merge janitor
# (issue #277). THIS script never merges: the worker that shipped the PR merges it
# itself on a green gate (issue #441), or a human clicks Merge on the web, or a
# collaborator does; this script is what runs AFTER a merge to clean up and keep the
# session resumable. It is the
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
#      DROP the worktree + branch -D issue-<N>. Dropping is a rename into a sibling
#      .fleet-trash/ plus a `worktree prune` (fleet_worktree_drop, issue #586), never
#      a synchronous delete: a 308k-file node_modules worktree once took this step 67
#      minutes and stalled the whole cleanup daemon behind it. The bytes go to the
#      daemon's budgeted fleet_trash_sweep. If the CALLER stands on the worktree being
#      removed (a worker cleaning up its own merged PR), teardown detaches into the
#      tmux server so it can't saw off the branch it sits on. worktree-autoclean.sh
#      stays the backstop.
#
# Merge-source-agnostic: it reaps the same whether the worker itself, a web merge,
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
#   skip:protected   scratch-head reap refused: the base checkout / a protected branch
#   skip:unmerged    scratch-head reap refused: local commits past the merged head
#   skip:dirty       scratch-head reap refused: the worktree has uncommitted work
#   skip:busy        scratch-head reap refused: its window is not `done`
#   error:<reason>   a precondition failed (no repo/main/gh/PR) — rc 2
#
# NON-issue-<N> HEADS (issue #589). Everything above is addressed by `issue-<N>`,
# so a session that started as a scratch (`scratch-<N>`) and grew into a PR is
# never reaped: its window hangs around forever and its worktree keeps the disk.
# That is deliberate (#543/#544) — a scratch window is routinely the operator's own
# workbench. FLEET_CLEANUP_SCRATCH_HEADS=1 opts a fleet INTO reaping those too, but
# only behind the strict gate in `scratch_head_gate` below; the default (0) is the
# historic behavior, byte for byte.
#
# Env knobs (all optional):
#   FLEET_CLEANUP_SCRATCH_HEADS  1 = also reap a MERGED PR whose head is not
#                        issue-<N>, behind the strict gate      (default 0/off)
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
    -h|--help) sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# BRANCH is what the teardown addresses; ISSUE stays the issue-<N> identity (the
# @issue window binding, the ledger key, the branch name). They coincide for a
# worker; for an opted-in non-issue head BRANCH is the PR's head and ISSUE empty.
SCRATCH_HEAD=0
case "$href" in
  issue-[0-9]*) ISSUE="${href#issue-}"; ISSUE="${ISSUE%%[!0-9]*}"; BRANCH="issue-$ISSUE" ;;
  *)
    ISSUE=""; BRANCH=""
    # Opt-in only, MERGED only (issue #589). A CLOSED-unmerged non-issue PR
    # abandoned work that is still sitting in its worktree — never reap that.
    if [ "${FLEET_CLEANUP_SCRATCH_HEADS:-0}" = 1 ] && [ "$st" = MERGED ] && [ -n "$href" ]; then
      SCRATCH_HEAD=1; BRANCH="$href"
    fi ;;
esac

note "fleet-cleanup: repo=$REPO  pr=#$PR  head=$href  issue=${ISSUE:-none}  branch=${BRANCH:-none}  state=$st$([ "$DRY" = 1 ] && echo '  (dry-run)')"

# --- only FINAL PRs are cleanable ---------------------------------------------
case "$st" in
  MERGED) : ;;
  CLOSED) : ;;
  *)      note "  #$PR is $st — not final (not merged/closed); nothing to clean."; done_token "skip:not-final"; exit 0 ;;
esac

# --- resolve the worktree + window for BRANCH (idempotency hinges on this) -----
# Both empty on a final PR ⇒ already cleaned (or a head we may not reap) ⇒ no-op.
WT=""; WT_HEAD=""; WIN=""; WIN_STATE=""
if [ -n "$BRANCH" ]; then
  IFS=$'\t' read -r WT WT_HEAD <<<"$(fleet_worktree_head "$MAIN" "$BRANCH")"
  if [ "$SCRATCH_HEAD" = 1 ]; then
    # No @issue binding on a non-issue head → the window is addressed by pane cwd.
    [ -n "$WT" ] && IFS=$'\t' read -r WIN WIN_STATE <<<"$(fleet_wt_window "$FLEET_SESSION" "$WT")"
  else
    WIN=$(ftmux list-windows -t "$FLEET_SESSION" -F '#{window_id} #{@issue}' 2>/dev/null | \
          awk -v i="$ISSUE" '$2==i{print $1}')
  fi
fi

# --- the scratch-head gate (issue #589) ---------------------------------------
# Reaping on head branch alone would kill live work — a `scratch-<N>` window is
# routinely the operator's own workbench, which is exactly why #543/#544 protects
# it. So the opt-in buys only this: the worktree janitor's full liveness gate,
# PLUS "the window itself says it is finished". Every check below is a READ, so it
# runs in --dry-run too and makes that classification honest.
scratch_head_gate() {
  local re="${FLEET_PROTECTED_RE:-^(master|main|develop|test)\$}"
  # Protection is a property of the BRANCH, so it is answered before we go looking
  # for a worktree: a protected head is refused whether or not one is checked out.
  if printf '%s\n' "$BRANCH" | grep -Eq "$re"; then
    note "  refusing $BRANCH: it is a protected branch (FLEET_PROTECTED_RE)."
    done_token "skip:protected"; return 1
  fi
  if [ -z "$WT" ]; then
    note "  no worktree is checked out on $BRANCH — nothing of ours to reap."
    done_token "skip:nothing"; return 1
  fi
  if [ "$WT" = "$MAIN" ]; then
    note "  refusing $BRANCH: it is checked out in the BASE checkout $MAIN."
    done_token "skip:protected"; return 1
  fi
  # The local branch must be EXACTLY the commit GitHub merged. `--is-ancestor`
  # cannot answer this: a squash merge (the fleet default) leaves the head tip off
  # the base's history entirely, so every squash-merged branch would read as
  # unmerged. Compare against the PR's own headRefOid instead — anything past it
  # was pushed after the merge and was never merged. WT_HEAD is that tip already
  # (the porcelain HEAD of the worktree this branch is attached to), so this costs
  # no extra git call.
  if [ -n "$oid" ] && [ -n "$WT_HEAD" ] && [ "$WT_HEAD" != "$oid" ]; then
    note "  refusing $BRANCH: local tip $WT_HEAD != merged head $oid (commits past the merge)."
    done_token "skip:unmerged"; return 1
  fi
  if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    note "  refusing $BRANCH: worktree $WT is dirty (uncommitted or untracked files)."
    done_token "skip:dirty"; return 1
  fi
  # The window's own verdict, and it must EXIST. Fail CLOSED on purpose: the window
  # is located by comparing the porcelain worktree path to a pane cwd, and any
  # reason that comparison comes up empty (a symlinked checkout, a pane whose cwd
  # has not settled) would otherwise read as "nobody home" and kill a live session.
  # Requiring it costs nothing — a clean, merged worktree with NO live pane is
  # already worktree-autoclean.sh's job, and that is the one reaper that handles it.
  if [ -z "$WIN" ]; then
    note "  refusing $BRANCH: no live window sits in $WT — worktree-autoclean.sh owns that case."
    done_token "skip:nothing"; return 1
  fi
  # Anything but `done` — working, needs, or a window that never stamped a state
  # at all — means a session is still using this worktree; leave it alone.
  if [ "$WIN_STATE" != "done" ]; then
    note "  refusing $BRANCH: window $WIN is '${WIN_STATE:--}' (not done) — a session is still using $WT."
    done_token "skip:busy"; return 1
  fi
  note "  scratch-head reap armed: $BRANCH → wt=$WT win=${WIN:-none}/${WIN_STATE:--}"
  return 0
}
if [ "$SCRATCH_HEAD" = 1 ]; then
  scratch_head_gate || exit 0
fi

# --- dry-run: report what we WOULD do, take no lease, mutate nothing ----------
if [ "$DRY" = 1 ]; then
  if [ -z "$WT" ] && [ -z "$WIN" ]; then done_token "dry:would-reap-nothing"; exit 0; fi
  case "$st" in
    MERGED) done_token "dry:would-clean-merged" ;;
    CLOSED) done_token "dry:would-reap-closed" ;;
  esac
  exit 0
fi

# --- teardown: kill window → drop worktree → delete branch --------------------
# If the CALLER is inside the worktree (a worker cleaning up its own PR), detach
# the teardown into the tmux server — you can't remove the ground you stand on.
teardown() {
  [ -z "$BRANCH" ] && { note "  head $href is not a branch we may reap — nothing to do."; return 0; }
  local self_win cwd
  self_win=$(ftmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)
  cwd=$(pwd -P 2>/dev/null)

  local detach=0
  [ -n "$WIN" ] && [ -n "$self_win" ] && [ "$WIN" = "$self_win" ] && detach=1
  if [ -n "$WT" ]; then case "$cwd" in "$WT"|"$WT"/*) detach=1 ;; esac; fi

  if [ "$detach" = 1 ]; then
    # Silence the git steps (issue #192): run-shell surfaces non-empty output as a
    # view-mode overlay on the attached client.
    # The worktree is DROPPED, not deleted (issue #586): fleet-worktree-drop.sh
    # renames it into a sibling .fleet-trash/ in milliseconds, so a 300k-file tree
    # cannot hold this teardown — nor the daemon tick driving it. run-shell runs the
    # string under /bin/sh, which cannot source fleet-lib.sh; hence the shim.
    local dropcmd=""
    [ -n "$WT" ] && dropcmd="bash '$BIN/fleet-worktree-drop.sh' '$MAIN' '$WT' --force; "
    local cmd="tmux kill-window -t ${WIN:-@self}; { ${dropcmd}git -C '$MAIN' branch -D '$BRANCH'; } >/dev/null 2>&1"
    note "  teardown (detached): $cmd"
    [ "${CLEANUP_DRY_TEARDOWN:-0}" = 1 ] && return 0
    ftmux run-shell -b "$cmd" 2>/dev/null || \
      note "  teardown: tmux run-shell failed — worktree-autoclean.sh will reap the merged worktree."
    return 0
  fi

  note "  teardown: kill-window ${WIN:-none} → worktree drop ${WT:-none} → branch -D $BRANCH"
  if [ "${CLEANUP_DRY_TEARDOWN:-0}" = 1 ]; then return 0; fi
  # Ordering is load-bearing: kill the window FIRST so the worker process dies and
  # releases the busy cwd, THEN drop the worktree, THEN delete the branch.
  [ -n "$WIN" ] && ftmux kill-window -t "$WIN" 2>/dev/null
  if [ -n "$WT" ]; then
    # Drop, don't delete (issue #586) — a rename into .fleet-trash/ plus a prune,
    # so the bytes are swept later under a budget instead of holding this tick.
    local drop; drop=$(fleet_worktree_drop "$MAIN" "$WT" --force)
    case "$drop" in
      trashed:*|removed:*|gone) note "  worktree $drop" ;;
      *) note "  worktree drop failed for $WT ($drop) — worktree-autoclean.sh will reap it." ;;
    esac
  fi
  git -C "$MAIN" branch -D "$BRANCH" >/dev/null 2>&1 || true
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
# session id) is still resolvable. Best-effort — never blocks the cleanup. Routed
# through the shared reap-and-record helper (issue #384) so this reaper and
# worktree-autoclean.sh write the row the SAME way and can't drift; the PR is known
# here, so the helper skips its branch→PR resolution and records a landed row.
# A non-issue head has no issue number, so the helper keys the row by the branch's
# `scratch-<N>` slug instead (issue #466) — the session stays in /fleet-history.
if [ -n "$BRANCH" ] && [ -n "$WT" ]; then
  fleet_reap_record "merged-pr" "$REPO" "$MAIN" "$ISSUE" "$WT" "$WIN" "$FLEET_SESSION" "$PR" "$BRANCH" || true
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
