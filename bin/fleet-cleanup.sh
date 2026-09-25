#!/bin/bash
# fleet-cleanup.sh <PR> [--auto] [--dry-run] — the no-LLM, no-merge janitor
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
#   cleaned:closed   CLOSED-unmerged → ledger row + orphan reaped (no base pull)
#   skip:not-final   PR still OPEN — not merged/closed, nothing to clean (rc 0)
#   skip:nothing     final PR but no worktree AND no window to reap (already clean)
#   skip:protected   scratch-head reap refused: the base checkout / a protected branch
#   skip:unmerged    scratch-head reap refused: local commits past the merged head
#   skip:dirty       reap refused: the worktree has uncommitted work
#   skip:busy        scratch-head reap refused: its window is not `done`
#   skip:live        automatic MERGED or CLOSED-unmerged reap deferred: live/unknown
#   skip:grace       automatic MERGED cleanup deferred until its grace expires
#   skip:notice      automatic cleanup waiting for the visible dashboard notice
#   skip:issue-open  automatic reap deferred: the bound issue #N is still OPEN and
#                    the PR does not close it (issue #1156) — a side-fix PR shipped
#                    from branch issue-<N> is not task #N done. Unknown state defers.
#   error:<reason>   a precondition failed (no repo/main/gh/PR) — rc 2
#
# A CLOSED PR IS NOT PROOF THE WORK WAS ABANDONED (issue #544). This path used to
# reap on the PR state alone. #534's worker deleted its own remote branch after a
# failed squash — GitHub auto-closed the PR — and then spent four minutes
# resolving the conflict by hand; the next 60s tick SIGKILLed it mid-edit and
# force-dropped the uncommitted resolution with it. Restoring that session hit the
# same tick 60s later, forever, so ⌃o restore was unusable for a closed-unmerged
# worker. `closed_reap_gate` below now makes the reap prove the session is GONE
# (see its comment), the drop no longer forces past a dirty tree, and the row is
# recorded BEFORE teardown so a deferred-then-reaped session stays resumable.
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
#   FLEET_CLEANUP_CLOSED_GRACE   seconds a closed-unmerged window must have been
#                        SILENT before it may be reaped (issue #544, default 900)
#   FLEET_CLEANUP_MERGED_GRACE   seconds after mergedAt before --auto cleanup
#                        (default 600; 0 disables the delay, max 31536000)
#   LAND_LEASE_TTL       lease lifetime, seconds           (default 3600)
#   LAND_QUEUE_TIMEOUT   max seconds to WAIT for the lease (default 300)
#   LAND_POLL            seconds between lease-queue polls  (default 15)
#   FLEET_LAND_LEASE_DIR SHARED lease dir for ALL landers  (default ~/.claude/leases)
#   LAND_LEASE_DIR       per-tool override of the lease dir (tests)
#   CLEANUP_DRY_TEARDOWN 1 = print the teardown cmds, don't run them (tests)
#   FLEET_SESSION        override the resolved fleet session (daemon callers)
#
# --repo <owner/name> (issue #791): the repo the PR belongs to, in a fleet that
# hosts several. MAIN/base come from THAT repo's overlay, and the worker window is
# matched on (repo, issue) — repo A's merged #12 never finds repo B's #12 window.
# Without it the historic resolution applies (the fleet conf's / caller window's
# repo). A repo the fleet does not host is an error, never a guess.
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
CLOSED_GRACE="${FLEET_CLEANUP_CLOSED_GRACE:-900}"
case "$CLOSED_GRACE" in ''|*[!0-9]*) CLOSED_GRACE=900 ;; esac   # tolerate a garbled conf

# --- args ---------------------------------------------------------------------
PR=""; DRY=0; AUTO=0; REPO_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) shift; PR="${1:-}"; PR="${PR//[^0-9]/}" ;;
    --repo) shift; REPO_ARG="${1:-}" ;;
    --dry-run|-n) DRY=1 ;;
    --auto) AUTO=1 ;;
    -h|--help) sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
if [ -n "$REPO_ARG" ] && ! fleet_load_repo_conf "$FLEET_SESSION" "$REPO_ARG"; then
  note "fleet-cleanup: $REPO_ARG is not a repo fleet $FLEET_SESSION hosts."
  done_token "error:no-repo"; exit 2
fi
# Read AFTER the fleet overlay; these values are commonly not exported.
MERGED_GRACE="${FLEET_CLEANUP_MERGED_GRACE:-600}"
case "$MERGED_GRACE" in ''|*[!0-9]*) MERGED_GRACE=600 ;; esac
if [ "${#MERGED_GRACE}" -gt 8 ]; then MERGED_GRACE=600; fi
MERGED_GRACE=$((10#$MERGED_GRACE))
[ "$MERGED_GRACE" -le 31536000 ] || MERGED_GRACE=600
if [ -n "$REPO_ARG" ]; then REPO=$(fleet_norm_repo "$REPO_ARG")
else REPO=$(fleet_resolved_repo "$FLEET_SESSION"); fi
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
# TSV: state headOid headRef closedAt mergedAt closes (we don't merge).
# closes = the issues the PR closes on merge, `owner/name#N` comma-joined (issue
# #1156) — the same round-trip, so proving "this PR closes the bound issue" is free.
# closedAt is what the closed-unmerged gate compares transcript activity against
# (issue #544): a session that spoke AFTER its PR closed is working ON the close,
# not abandoned by it. Use sentinels: Bash read collapses empty TSV fields.
pr_fields() {
  gh pr view "$1" --repo "$REPO" \
    --json state,headRefOid,headRefName,closedAt,mergedAt,closingIssuesReferences \
    --jq '[.state, .headRefOid, .headRefName, (.closedAt // "-"), (.mergedAt // "-"),
           ([.closingIssuesReferences[]? | "\(.repository.owner.login)/\(.repository.name)#\(.number)"]
            | if length == 0 then "-" else join(",") end)] | @tsv' 2>/dev/null
}

fields=$(pr_fields "$PR")
[ -z "$fields" ] && { note "fleet-cleanup: PR #$PR not found on $REPO."; done_token "error:pr-not-found"; exit 2; }
IFS=$'\t' read -r st oid href closed_at merged_at closes <<<"$fields"
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
    # Keyed (repo, issue) — issue #791: a multi-repo fleet's other repo may have
    # its own #$ISSUE window, and that one is not ours to kill.
    WIN=$(fleet_issue_windows "$FLEET_SESSION" "$REPO" "$ISSUE")
    # Its @claude_state too — the closed-unmerged gate (issue #544) reads it, and
    # it is a second format pass over the same window list, not a second lookup.
    [ -n "$WIN" ] && WIN_STATE=$(ftmux list-windows -t "$FLEET_SESSION" \
          -F '#{window_id} #{@claude_state}' 2>/dev/null | \
          awk -v w="$WIN" '$1 == w { print $2; exit }')
  fi
fi

# --- the bound-issue gate (issue #1156) ---------------------------------------
# "A PR from branch issue-<N> merged" is NOT "task #N is done": a research worker
# on issue-9206 shipped side-fix PR #9208 (closing #9207), and --auto reaped the
# live window mid-EPIC-plan. So an AUTOMATIC reap of an issue head must prove the
# task is over, one of two ways:
#   A. the MERGED PR's own closingIssuesReferences names (repo, issue) — free, it
#      rode in on the PR read above; or
#   B. the bound issue is not OPEN any more — ONE `gh issue view`, spent only on a
#      final PR that still has debris and did not pass A.
# Unknown (gh failed) reads as OPEN: deferring costs a window until the next tick,
# reaping costs a session. Manual cleanup and non-issue heads never get here. Runs
# BEFORE the grace countdown, so the dash never counts down a reap that cannot
# happen; instead the window carries a held notice until #N closes.
issue_open_gate() {
  [ "$AUTO" = 1 ] && [ -n "$ISSUE" ] || return 0
  { [ -n "$WT" ] || [ -n "$WIN" ]; } || return 0
  local want c ist verb
  want=$(printf '%s#%s' "$(fleet_norm_repo "$REPO")" "$ISSUE" | tr '[:upper:]' '[:lower:]')
  if [ "$st" = MERGED ]; then
    for c in $(printf '%s' "${closes:--}" | tr ',' ' ' | tr '[:upper:]' '[:lower:]'); do
      [ "$c" = "$want" ] && return 0
    done
  fi
  ist=$(gh issue view "$ISSUE" --repo "$REPO" --json state --jq .state 2>/dev/null)
  [ "$ist" = CLOSED ] && return 0
  verb=merged; [ "$st" = CLOSED ] && verb=closed
  note "  #$PR $verb but bound issue #$ISSUE is ${ist:-unknown} and the PR does not close it — automatic cleanup deferred until #$ISSUE closes."
  if [[ "$WIN" =~ ^@[0-9]+$ ]]; then
    local hold_args=()
    [ -n "${TMUX:-}" ] || hold_args=(--socket-name "$(fleet_socket "$FLEET_SESSION")")
    [ "$DRY" = 1 ] && hold_args+=(--dry-run)
    python3 "$BIN/fleet_reap_notice.py" "$WIN" "issue-open:$PR:$ISSUE" 0 \
      --hold "PR #$PR $verb · #$ISSUE still open — continue or close?" \
      ${hold_args[@]+"${hold_args[@]}"} >/dev/null 2>&1 || true
  fi
  done_token "skip:issue-open"; return 1
}
issue_open_gate || exit 0

# A daemon must give a newly merged worker time to finish its report (#565).
# This only narrows automatic cleanup: all existing gates still apply, manual
# cleanup is immediate, and an already-cleaned PR remains an idempotent no-op.
# No ledger, lease, base pull or teardown occurs before this gate. Window-local
# notice metadata is the only write while waiting (and never in dry-run).
if [ "$AUTO" = 1 ] && [ "$st" = MERGED ] \
   && { [ -n "$WT" ] || [ -n "$WIN" ]; }; then
  merged_epoch=0
  if [[ "$merged_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    merged_epoch=$(fleet_epoch_from_iso "$merged_at") || merged_epoch=0
    # BSD date can normalize impossible calendar dates instead of rejecting them.
    merged_iso=$(date -u -r "$merged_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$merged_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    [ "$merged_iso" = "$merged_at" ] || merged_epoch=0
  fi
  case "$merged_epoch" in ''|*[!0-9]*) merged_epoch=0 ;; esac
  merge_age=$(( $(date +%s) - merged_epoch ))
  if { { [ "$merged_epoch" -gt 0 ] && [ "$merge_age" -ge 0 ]; } || [ "$MERGED_GRACE" = 0 ]; } \
     && [[ "$WIN" =~ ^@[0-9]+$ ]]; then
    notice_args=()
    [ -n "${TMUX:-}" ] || notice_args=(--socket-name "$(fleet_socket "$FLEET_SESSION")")
    [ "$DRY" = 1 ] && notice_args+=(--dry-run)
    notice_deadline=0
    [ "$MERGED_GRACE" -gt 0 ] && notice_deadline=$(( merged_epoch + MERGED_GRACE ))
    notice_due=$(python3 "$BIN/fleet_reap_notice.py" "$WIN" "merged:$PR:$oid" \
      "$notice_deadline" ${notice_args[@]+"${notice_args[@]}"} 2>/dev/null) || notice_due=''
  else notice_due=''; fi
  if [ "$MERGED_GRACE" -gt 0 ] && { [ "$merged_epoch" -eq 0 ] || [ "$merge_age" -lt "$MERGED_GRACE" ]; }; then
    note "  #$PR automatic cleanup deferred: mergedAt=${merged_at:--}, age=${merge_age}s, grace=${MERGED_GRACE}s (unknown/future times also defer)."
    done_token "skip:grace"; exit 0
  fi
  case "$notice_due" in ''|*[!0-9]*) done_token "skip:live"; exit 0 ;; esac
  if [ "$notice_due" -gt "$(date +%s)" ]; then
    note "  #$PR automatic cleanup notice displayed; waiting until $notice_due."
    done_token "skip:notice"; exit 0
  fi
fi

# Transfers protect MERGED as well as CLOSED-unmerged work. A PR webhook can
# race the short source-exit/target-start gap, even while the window is retained.
if [ -n "$WT" ] && _transfer_lease="$(fleet_rotate_lease_held "$WT")"; then
  note "  refusing $BRANCH: migration/transfer in flight — lease $_transfer_lease"
  done_token "skip:live"; exit 0
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

# --- the closed-unmerged gate (issue #544) ------------------------------------
# "PR is CLOSED" is a statement about GitHub, not about the worker. It is TRUE the
# instant a worker deletes its own remote branch after a failed merge — the exact
# moment that worker starts fixing the problem. Reaping on that alone SIGKILLed
# #534 mid-conflict-resolution and force-dropped the resolution with it.
#
# So the reap must prove the SESSION is gone, not just that the PR is. Every check
# below is a READ, so it runs under --dry-run too and keeps that classification
# honest, and every one of them fails CLOSED (defer) on the unknown: deferring
# costs a stale worktree until the next tick, reaping costs work nobody can get
# back. A deferral is not a leak — worktree-autoclean.sh reaps a clean, windowless
# worktree on its own schedule.
closed_reap_gate() {
  # (0) An account ROTATION is in flight in this worktree (issue #550). A migrate
  # is a close + resume, so the window is deliberately gone for a few seconds —
  # every "no window ⇒ no session" inference below is false for that window, and
  # the mover says so explicitly. TTL-bounded, so this can only ever defer.
  local _rl
  if [ -n "$WT" ] && _rl="$(fleet_rotate_lease_held "$WT")"; then
    note "  refusing $BRANCH: an account rotation is in flight in $WT (lease $_rl) — deferred."
    done_token "skip:live"; return 1
  fi
  # (1) Dirty ⇒ hands off, and that includes the WINDOW: uncommitted work is the
  # whole thing we lost. worktree-autoclean.sh already answers this case with
  # `KEEP (dirty — uncommitted changes)`; the two reapers disagreeing about a
  # dirty tree is what turned one lost merge into lost work.
  if [ -n "$WT" ] && [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
    note "  refusing $BRANCH: worktree $WT is dirty (uncommitted or untracked files) — worktree-autoclean.sh KEEPs it."
    done_token "skip:dirty"; return 1
  fi
  # No window ⇒ no session to kill; the orphan worktree is all that is left.
  [ -n "$WIN" ] || { note "  closed-unmerged reap armed: ${BRANCH:-none} → wt=${WT:-none}, no live window"; return 0; }

  # (2) The window's own verdict. `working` is a session mid-turn — exactly the
  # state #534 was in. Anything else still has to clear the transcript clock below.
  if [ "$WIN_STATE" = working ]; then
    note "  #$PR closed-unmerged but window $WIN is 'working' — still live, deferred."
    done_token "skip:live"; return 1
  fi

  # (2b) A window whose WORKTREE is already gone (a prior tick dropped the tree but
  # its kill-window failed) has no uncommitted work to lose — and no transcript dir
  # to read, since that dir is keyed by the worktree path. `working` is therefore
  # the whole gate for it; anything stricter would make such an orphan window
  # unreapable FOREVER, leaking a window and a `gh pr view` every tick.
  if [ -z "$WT" ]; then
    note "  closed-unmerged reap armed: ${BRANCH:-none} → win=$WIN state=${WIN_STATE:--}, worktree already gone"
    return 0
  fi

  # (3) The transcript clock. Two independent questions, both must say "gone":
  #   * has it spoken SINCE the PR closed? Then it is working ON the close (the
  #     #534 worker, or an operator who restored the session deliberately) — and
  #     this one has no timeout, which is what makes ⌃o restore usable again.
  #   * has it been silent long enough to call it finished? (CLOSED_GRACE)
  # No readable transcript ⇒ we cannot answer either ⇒ defer.
  local tdir last now age closed_epoch
  tdir=$(fleet_transcript_dir "$WT")
  last=$(fleet_newest_human_mtime "$tdir")
  if [ -z "$last" ]; then
    note "  #$PR closed-unmerged, window $WIN live with no readable transcript — cannot prove it idle; deferred."
    done_token "skip:live"; return 1
  fi
  closed_epoch=$(fleet_epoch_from_iso "$closed_at")
  if [ -n "$closed_epoch" ] && [ "$last" -ge "$closed_epoch" ]; then
    note "  #$PR closed-unmerged but window $WIN spoke $((last - closed_epoch))s AFTER the PR closed — still live, deferred."
    done_token "skip:live"; return 1
  fi
  now=$(date +%s 2>/dev/null || echo 0); age=$((now - last))
  if [ "$age" -lt "$CLOSED_GRACE" ]; then
    note "  #$PR closed-unmerged but window $WIN has been idle only ${age}s (< ${CLOSED_GRACE}s grace) — still live, deferred."
    done_token "skip:live"; return 1
  fi
  note "  closed-unmerged reap armed: ${BRANCH:-none} → wt=${WT:-none} win=$WIN state=${WIN_STATE:--} idle=${age}s"
  return 0
}

if [ "$SCRATCH_HEAD" = 1 ]; then
  scratch_head_gate || exit 0
elif [ "$st" = CLOSED ] && { [ -n "$WT" ] || [ -n "$WIN" ]; }; then
  closed_reap_gate || exit 0
fi

# Automatic cleanup must not turn a GitHub verdict into permission to
# kill a working session (#565). Pin one window, require an explicit done state,
# then share the dash's all-pane process-age/unknown-metadata guard. A missing
# window is NOT proof of inactivity; the windowless janitor owns that case.
# Run before history/pull and again after the lease/pull wait, just before kill.
auto_cleanup_gate() {
  [ "$AUTO" = 1 ] || return 0
  [ -n "$WT" ] || [ -n "$WIN" ] || return 0
  local why="" state self_win cwd lease git_state current_head base_head token="skip:live"
  local socket_args=()
  if ! [[ "$WIN" =~ ^@[0-9]+$ ]]; then
    why="missing or ambiguous window; leaving windowless work to worktree-autoclean"
  elif [ -n "$WT" ] && lease=$(fleet_rotate_lease_held "$WT"); then
    why="migration/transfer in flight: $lease"
  else
    # --auto is an external janitor, never a delayed self-destruct command. A
    # detached shell would outlive this final guard and could kill a resumed turn.
    cwd=$(pwd -P 2>/dev/null)
    if [ -n "$WT" ]; then
      case "$cwd" in "$WT"|"$WT"/*) why="caller is inside target worktree" ;; esac
    fi
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
      self_win=$(ftmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
      if [ -z "$self_win" ] || [ "$self_win" = "$WIN" ]; then why="caller window is target or unknown"; fi
    fi
    if [ -z "$why" ]; then
      if [ -z "$WT" ] || [ ! -d "$WT" ] \
         || ! git_state=$(git -C "$WT" status --porcelain 2>/dev/null); then
        why="worktree metadata unavailable"
      elif [ -n "$git_state" ]; then
        why="uncommitted work after the merge"; token="skip:dirty"
      elif ! current_head=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null); then
        why="local tip unavailable"
      elif [ "$st" = MERGED ]; then
        if [ -z "$oid" ] || [ "$current_head" != "$oid" ]; then
          why="local tip differs from the merged PR head"; token="skip:unmerged"
        fi
      elif ! base_head=$(git -C "$WT" rev-parse --verify "origin/${FLEET_BASE_BRANCH:-master}^{commit}" 2>/dev/null) \
           || [ "$current_head" = "$base_head" ] \
           || ! git -C "$WT" merge-base --is-ancestor "$current_head" "$base_head" 2>/dev/null; then
        why="closed-unmerged tip is not a strict ancestor of the remote base"; token="skip:unmerged"
      fi
    fi
    if [ -z "$why" ]; then
      if ! state=$(ftmux display-message -p -t "$WIN" '#{@claude_state}' 2>/dev/null); then
        why="cannot read window state"
      elif [ "$state" != "done" ]; then
        why="window state is '${state:-unset}', not done"
      else
        [ -n "${TMUX:-}" ] || socket_args=(--socket-name "$(fleet_socket "$FLEET_SESSION")")
        if ! why=$(FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-1800}" \
          python3 "$BIN/fleet-reap-live.py" "$WIN" ${socket_args[@]+"${socket_args[@]}"} 2>/dev/null); then
          why="${why:-liveness probe unavailable}"
        fi
      fi
    fi
  fi
  if [ -n "$why" ]; then
    note "  #$PR automatic cleanup deferred: $why"
    done_token "$token"; return 1
  fi
  return 0
}
auto_cleanup_gate || exit 0

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
#
# DROP_FORCE decides whether the drop may run over a dirty worktree. MERGED keeps
# the historic `--force` (the work is IN the base; whatever is left is scratch).
# CLOSED-unmerged clears it (issue #544): nothing was merged, so a dirty tree is
# the only copy of that work. The gate above already refuses a dirty CLOSED reap —
# this is the backstop for the seconds between the gate and the `mv`, and it makes
# the DETACHED path (which re-runs minutes later, inside tmux) safe too.
DROP_FORCE="--force"
teardown() {
  [ -z "$BRANCH" ] && { note "  head $href is not a branch we may reap — nothing to do."; return 0; }
  local self_win cwd
  self_win=$(ftmux display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)
  cwd=$(pwd -P 2>/dev/null)

  local detach=0
  [ -n "$WIN" ] && [ -n "$self_win" ] && [ "$WIN" = "$self_win" ] && detach=1
  if [ -n "$WT" ]; then case "$cwd" in "$WT"|"$WT"/*) detach=1 ;; esac; fi
  # The automatic gate above refused actual self-calls. A daemon's untargeted
  # display-message can report the active window; that is not a caller to detach.
  [ "$AUTO" = 1 ] && detach=0

  if [ "$detach" = 1 ]; then
    # Silence the git steps (issue #192): run-shell surfaces non-empty output as a
    # view-mode overlay on the attached client.
    # The worktree is DROPPED, not deleted (issue #586): fleet-worktree-drop.sh
    # renames it into a sibling .fleet-trash/ in milliseconds, so a 300k-file tree
    # cannot hold this teardown — nor the daemon tick driving it. run-shell runs the
    # string under /bin/sh, which cannot source fleet-lib.sh; hence the shim.
    local dropcmd=""
    [ -n "$WT" ] && dropcmd="bash '$BIN/fleet-worktree-drop.sh' '$MAIN' '$WT' $DROP_FORCE; "
    local cmd="tmux kill-window -t ${WIN:-@self}; { ${dropcmd}git -C '$MAIN' branch -D '$BRANCH'; } >/dev/null 2>&1"
    note "  teardown (detached): $cmd"
    [ "${CLEANUP_DRY_TEARDOWN:-0}" = 1 ] && return 0
    ftmux run-shell -b "$cmd" 2>/dev/null || \
      note "  teardown: tmux run-shell failed — worktree-autoclean.sh will reap the merged worktree."
    return 0
  fi

  auto_cleanup_gate || return 1
  note "  teardown: kill-window ${WIN:-none} → worktree drop ${WT:-none} → branch -D $BRANCH"
  if [ "${CLEANUP_DRY_TEARDOWN:-0}" = 1 ]; then return 0; fi
  # Ordering is load-bearing: kill the window FIRST so the worker process dies and
  # releases the busy cwd, THEN drop the worktree, THEN delete the branch.
  [ -n "$WIN" ] && ftmux kill-window -t "$WIN" 2>/dev/null
  if [ -n "$WT" ]; then
    # Drop, don't delete (issue #586) — a rename into .fleet-trash/ plus a prune,
    # so the bytes are swept later under a budget instead of holding this tick.
    local drop
    # shellcheck disable=SC2086  # DROP_FORCE is one flag or nothing, deliberately unquoted
    drop=$(fleet_worktree_drop "$MAIN" "$WT" $DROP_FORCE)
    case "$drop" in
      trashed:*|removed:*|gone) note "  worktree $drop" ;;
      dirty) note "  worktree $WT went dirty under us — KEPT (issue #544); worktree-autoclean.sh owns it." ;;
      *) note "  worktree drop failed for $WT ($drop) — worktree-autoclean.sh will reap it." ;;
    esac
  fi
  git -C "$MAIN" branch -D "$BRANCH" >/dev/null 2>&1 || true
}

# --- closed-unmerged: record, then reap the orphan (no base pull, no --force) --
# Nothing was merged into the base, so there is no fast-forward to do — but there
# IS a session, and it must stay findable. This path used to write NO ledger row
# at all ("not a landed session"), so a reaped closed-unmerged worker vanished from
# /fleet-history and ⌃t with it: no transcript pointer, no worktree sha, no way
# back. It goes through the SAME choke point the merged path uses (fleet_reap_record,
# issue #384) with the `unmerged` outcome, which routes to `record-closed` — the row
# the ledger-watch daemon would otherwise have to guess at, written while the
# worktree path (→ transcript dir + session id) is still resolvable.
if [ "$st" = CLOSED ]; then
  if [ -z "$WT" ] && [ -z "$WIN" ]; then
    note "  #$PR closed-unmerged, nothing left to reap (already clean)."
    done_token "skip:nothing"; exit 0
  fi
  if [ -n "$BRANCH" ] && [ -n "$WT" ]; then
    fleet_reap_record "unmerged" "$REPO" "$MAIN" "$ISSUE" "$WT" "$WIN" "$FLEET_SESSION" "$PR" "$BRANCH" || true
  fi
  note "  #$PR closed-unmerged — reaping the orphan (no merge, no base pull, no force-drop)."
  DROP_FORCE=""
  teardown || exit 0
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
# A base left on a side branch would pull THAT branch, not $BASE (issue #1044).
if off=$(fleet_base_off_branch "$MAIN" "$BASE"); then
  note "  base $MAIN is on $off, not $BASE — not syncing; git -C $MAIN checkout $BASE"
elif ! git -C "$MAIN" pull --ff-only >/dev/null 2>&1; then
  note "  base checkout $MAIN would not fast-forward — resolve it by hand (something diverged locally)."
fi
land_lease_release "$LEASE"

teardown || exit 0
done_token "cleaned:${oid:-merged}"
exit 0
