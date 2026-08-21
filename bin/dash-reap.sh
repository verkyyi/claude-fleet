#!/bin/bash
# dash-reap.sh <window-target> [confirm] — reap a finished worker row from the
# dash on ONE key (⌃x, issue #289 merged the old ⌃x/⌥x pair): close its tmux
# window, remove its git worktree (when clean), and close its bound GitHub issue.
# The gate is the SHARED fleet_reap_ok() (same guarantees as the
# worktree-autoclean.sh janitor).
#
#   ⌃x on a clean+merged row (a MERGED PR for the branch, or the tip is an
#      ancestor of base) reaps STRAIGHT AWAY — the common case, and the cleanup
#      daemon reaps those anyway, so no confirm.
#   ⌃x on anything else (dirty, or clean-but-not-merged) opens a y/n confirm
#      popup FIRST, then force-reaps — but STILL never removes a dirty worktree
#      (a dirty worktree is KEPT; only the window + issue close).
# The same one-key rule applies to BOTH a bound worker row (issue-<N>) and a raw
# `scratch-<N>` row (issue #290 gave scratch its own writable worktree).
#
#   Row state            ⌃x
#   clean + merged       record row, reap wt+branch+issue+window   (no confirm)
#   clean + NOT merged   confirm → record row, reap all (issue closed)
#   dirty (any)          confirm → record row, close window+issue, KEEP wt
#   raw scratch, merged  record row, dispose wt+branch, close window (no confirm)
#   raw scratch, else    confirm → record row, dispose (dirty KEEPs the wt), close window
#   raw scratch, no wt   close window (ephemeral, pre-#290 / hermetic — nothing to record)
#   hub/panel (no issue) refuse
#
# EVERY ⌃x records a /fleet-history row before it disposes of anything (issue #471
# for a worker row, #466 for a scratch one) — ⌃x is the one path the SessionEnd hook
# can't cover (a `kill-window` is not a walk-away exit), and ledger-watch only
# notices ~60s later, by which time the worktree is gone and the row it writes has
# no sha to rebuild from. See reap_record() for the ordering rules.
#
# Operates on THIS fleet only (the dash's resolved fleet); never another fleet's
# worktree/issue. gh issue close is idempotent (a merge may have closed it
# already); a kept dirty worktree stays on disk for later.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

refuse() { tmux display-message "reap: $*" 2>/dev/null; exit 0; }

# close the bound issue (idempotent — a merge/janitor may have closed it already)
close_issue() {
  command -v gh >/dev/null 2>&1 || return 0
  local st; st="$(gh -R "$REPO" issue view "$iss" --json state -q .state 2>/dev/null)"
  [ "$st" = OPEN ] || return 0
  gh -R "$REPO" issue close "$iss" \
    --comment "Reaped from the fleet dash: window closed and worktree cleaned." \
    >/dev/null 2>&1 || true
}

# RECORD this reap into the /fleet-history ledger (issue #471). ⌃x used to be the
# one reaper that wrote nothing — see the header note — so a ⌃x'd worker was only
# indexed later, worktree-less and therefore unresumable.
#
# ORDERING, both halves load-bearing: called AFTER the kill-window (so #313's
# instant row-vanish is untouched — the dash summary-cache FILE outlives the window,
# so the summary column still resolves) and BEFORE any `git worktree remove` (#384 —
# the row's transcript dir is derived from the worktree PATH, and its rebuild sha is
# read out of the worktree itself).
#
# $reason is the verdict the INTERACTIVE pass already decided, threaded in through
# the --exec dispatch. It is deliberately NOT re-derived here: a second
# fleet_reap_ok can disagree with what the operator just confirmed (a merge landing
# in between; the worktree turning dirty) and would record a verdict nobody agreed
# to — besides re-paying the `gh pr list` #304 moved off the bind. Empty (an
# in-flight pre-#471 dispatch string) → the helper no-ops, i.e. exactly the old
# behavior, never an invented row. Idempotent, so racing the cleanup daemon /
# ledger-watch still yields ONE row.
#
# Caveat, deliberate: on a FORCE-reaped `unmerged` row the recorded sha is neither
# in base nor on a surviving branch, so `resume` can rebuild it only until git gc
# prunes that unreachable object (~2 weeks by default). Strictly better than the
# no-sha row ledger-watch used to leave, and the degrade path is already handled
# (worktree add fails → REVIEW-ONLY).
reap_record() {
  fleet_reap_record "${reason:-}" "$REPO" "$MAIN" "$iss" "$wtdir" "${wid:-}" \
    "${FLEET_SESSION:-}" "" "$branch"
}

# full reap: remove worktree + delete branch, close issue, kill window
reap_full() {
  # Kill the window FIRST (issue #313): the dash row is driven live by
  # `tmux list-windows`, so dropping the window here makes the reaped row vanish
  # on the very next repaint instead of lingering behind the slow tail below (the
  # network `gh issue close` + `git worktree remove`). This whole function already
  # runs backgrounded (fleet_bg / run-shell -b, #304), so it never blocks the bind.
  tmux kill-window -t "$target" 2>/dev/null || true
  reap_record                                          # index it BEFORE the remove (#471)
  if [ -n "$wtdir" ] && [ -n "$MAIN" ]; then
    # Reap any detached process anchored to this worktree first (issue #151) — a
    # since-fixed hang left spinning would otherwise outlive the dir and drain a
    # core against the shared tmux server. (Also releases the just-killed pane's
    # shell if it was cwd'd in the worktree, so the remove below isn't blocked.)
    fleet_reap_worktree_procs "$wtdir" >/dev/null 2>&1
    # plain remove (no --force): git itself refuses a dirty worktree, so even a
    # TOCTOU race after the fleet_reap_ok check cannot delete uncommitted work.
    git -C "$MAIN" worktree remove "$wtdir" 2>/dev/null \
      && git -C "$MAIN" branch -D "$branch" >/dev/null 2>&1
    git -C "$MAIN" worktree prune 2>/dev/null || true
  fi
  close_issue
  tmux display-message "reaped #$iss ✓ (window + worktree + issue)" 2>/dev/null || true
}

# dirty force reap: KEEP the worktree, close issue + kill window only
reap_keep() {
  tmux kill-window -t "$target" 2>/dev/null || true   # drop the row first (#313)
  reap_record                                          # the KEPT worktree is resumable (#471)
  close_issue
  tmux display-message "reaped #$iss ✓ (window + issue) — worktree kept (dirty)" 2>/dev/null || true
}

# --- parse args ---------------------------------------------------------------
target="${1:-}"; [ -z "$target" ] && exit 0
confirm=0
shift || true
for a in "$@"; do case "$a" in confirm) confirm=1;; esac; done

command -v git >/dev/null 2>&1 || refuse "git not found"

# --- internal --exec <full|keep> [<gate-verdict>] (issue #304): the BACKGROUND reap
# the interactive path dispatches (via fleet_bg) ONCE the merged-check decision is
# made. Re-resolve only the CHEAP locals reap_full/reap_keep need — NO `gh pr list`
# (the decision is already made) — then run the slow tail (git worktree remove + gh
# issue close) off the interactive ⌃x bind so it returned instantly. $TMUX is
# inherited from the run-shell job, so the bare tmux/gh calls below stay on THIS
# fleet's server.
#
# $3 carries the GATE verdict (merged-pr|ancestor|unmerged|dirty) the interactive
# pass already computed — the one thing this pass cannot cheaply re-derive and the
# one thing the ledger row needs (issue #471). $2 stays the ACTION (full|keep).
if [ "${1:-}" = "--exec" ]; then
  verdict="${2:-}"; reason="${3:-}"
  iss="$(tmux display-message -t "$target" -p '#{@issue}' 2>/dev/null)"; iss="${iss//[^0-9]/}"
  [ -z "$iss" ] && exit 0
  FLEET_SESSION="$(fleet_current_session)"; export FLEET_SESSION
  fleet_load_conf "$FLEET_SESSION"
  REPO="${FLEET_REPO:-}"
  _r="$(fleet_repo_cached "$FLEET_SESSION")"; [ -n "$_r" ] && REPO="$_r"
  MAIN="${FLEET_MAIN:-}"; [ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""
  branch="issue-$iss"
  wtdir=""; whead=""
  [ -n "$MAIN" ] && IFS=$'\t' read -r wtdir whead < <(fleet_worktree_head "$MAIN" "$branch")
  # Window id for the ledger row's summary column — read BEFORE reap_* kills the
  # window (the cache FILE it keys survives; the window id would not be resolvable
  # afterwards). Empty is tolerated: the row just records no summary.
  wid="$(tmux display-message -t "$target" -p '#{window_id}' 2>/dev/null)"
  case "$verdict" in keep) reap_keep ;; *) reap_full ;; esac
  exit 0
fi

# --- raw scratch row: close the window + dispose its worktree by the gate ------
# A raw/scratch session (@raw=1) has NO @issue, but since issue #290 it DOES own a
# `scratch-<N>` git worktree off the base branch. So ⌃x closes the window AND
# applies the SAME one-key rule the issue-bound path below uses: a clean+merged
# scratch worktree is disposed straight away; a dirty/unmerged one is disposed
# only after a y/n confirm (and a dirty worktree is still KEPT — never silently
# delete an experiment). With no resolvable worktree (a pre-#290 scratch, or a
# hermetic test) it degrades to the historic "just close the window" behavior.
# Detected BEFORE the hub/panel guard so a scratch stops looking like a no-op ⌃x;
# true hub/panel rows (plan/dash/backlog — no @issue AND no @raw) still fall
# through to the "nothing to reap" refuse below.
if [ "$(tmux display-message -t "$target" -p '#{@raw}' 2>/dev/null)" = 1 ]; then
  # Drop the dash summary-cache seed the raw spawn wrote (dash-raw-session.sh) so a
  # reaped scratch leaves behind no stale summary row — same key the writer used
  # (fleet_summary_key of this fleet's session + this window id).
  wid="$(tmux display-message -t "$target" -p '#{window_id}' 2>/dev/null)"
  rm -f "$(fleet_cache_global)/summary_$(fleet_summary_key "$(fleet_current_session)" "$wid")" 2>/dev/null || true

  # Resolve this fleet's checkout + the scratch worktree. @worktree is written at
  # spawn (dash-raw-session.sh); fall back to the window's cwd. Only ever act on a
  # `scratch-<N>` branch under this fleet's MAIN — anything else degrades to a plain
  # window-close, so a stray cwd can never make ⌃x delete unrelated work.
  FLEET_SESSION="$(fleet_current_session)"; export FLEET_SESSION
  fleet_load_conf "$FLEET_SESSION"
  MAIN="${FLEET_MAIN:-}"; [ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""
  swt="$(tmux display-message -t "$target" -p '#{@worktree}' 2>/dev/null)"
  [ -z "$swt" ] && swt="$(tmux display-message -t "$target" -p '#{pane_current_path}' 2>/dev/null)"
  sbranch=""; shead=""
  if [ -n "$swt" ] && [ -n "$MAIN" ] && [ -e "$swt" ] \
     && git -C "$swt" rev-parse --git-dir >/dev/null 2>&1; then
    sbranch="$(git -C "$swt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    shead="$(git -C "$swt" rev-parse HEAD 2>/dev/null)"
  fi
  case "$sbranch" in scratch-*) ;; *) sbranch="" ;; esac   # scratch-only guard

  # No resolvable scratch worktree → historic behavior: just close the window.
  if [ -z "$sbranch" ]; then
    tmux kill-window -t "$target" 2>/dev/null || true
    tmux display-message "closed scratch ✓" 2>/dev/null || true
    exit 0
  fi

  # Gate the worktree the same way the issue-bound path does. No blocking fetch on
  # the interactive ⌃x path — use the locally-known origin/<base>.
  SBASE="${FLEET_BASE_BRANCH:-master}"
  SMASTER="$(git -C "$MAIN" rev-parse --verify -q "origin/$SBASE" 2>/dev/null \
    || git -C "$MAIN" rev-parse --verify -q "$SBASE" 2>/dev/null)"
  SMERGED=""
  command -v gh >/dev/null 2>&1 && SMERGED="$(gh -R "${FLEET_REPO:-}" pr list \
    --state merged --head "$sbranch" --json headRefName -q '.[].headRefName' 2>/dev/null)"
  sreason="$(fleet_reap_ok "$swt" "$MAIN" "$sbranch" "$shead" "$SMASTER" "$SMERGED")"

  scratch_remove() {   # remove worktree + branch (reap anchored procs first, #151)
    fleet_reap_worktree_procs "$swt" >/dev/null 2>&1
    git -C "$MAIN" worktree remove "$swt" 2>/dev/null \
      && git -C "$MAIN" branch -D "$sbranch" >/dev/null 2>&1
    git -C "$MAIN" worktree prune 2>/dev/null || true
  }

  # RECORD the /fleet-history row BEFORE any removal (issue #466). Both halves of a
  # resumable row come from the worktree while it still stands: the transcript dir is
  # derived from its PATH, and the HEAD sha is what lets `resume` rebuild it after
  # this ⌃x deletes it. Reap-then-record would strand the scratch's transcript —
  # indexed ~60s later by ledger-watch, but with no sha, i.e. REVIEW-ONLY forever.
  # The shared helper keys the row by the scratch branch (no issue) and dedups, so a
  # confirm-popup re-invocation records once. Deliberately NOT called on the cancel
  # path: a scratch whose window survives ⌃x is not a closed session.
  scratch_record() {
    fleet_reap_record "$sreason" "${FLEET_REPO:-}" "$MAIN" "" \
      "$swt" "$wid" "$FLEET_SESSION" "" "$sbranch"
  }

  # ⌃x (issue #289): a clean+merged scratch disposes straight away; a
  # dirty/unmerged one opens a y/n confirm popup FIRST (a dirty worktree stays
  # KEPT). The initial keypress (no `confirm` arg) decides which.
  if [ "$confirm" = 0 ]; then
    case "$sreason" in
      merged-pr|ancestor)
        scratch_record
        scratch_remove
        tmux kill-window -t "$target" 2>/dev/null || true
        tmux display-message "closed scratch ✓ (worktree reaped)" 2>/dev/null || true ;;
      *)   # dirty | unmerged — confirm before disposing / closing
        tmux display-popup -w 90% -h 9 -E \
          "bash '$BIN/dash-reap.sh' '$target' confirm" 2>/dev/null || true ;;
    esac
    exit 0
  fi

  # running inside the confirm popup. A DIRTY worktree is still KEPT (git refuses a
  # dirty remove anyway) — only the window closes.
  if [ "$sreason" = dirty ]; then
    msg="Dispose $sbranch? Worktree is DIRTY — it will be KEPT; window closes."
  else
    msg="Dispose $sbranch? Removes the scratch worktree + branch, closes the window."
  fi
  printf '\n  %s\n\n  [y] reap    [n] cancel ' "$msg"
  read -rsn1 ans; echo
  case "$ans" in y|Y) ;; *) exit 0;; esac
  scratch_record
  [ "$sreason" = dirty ] || scratch_remove
  tmux kill-window -t "$target" 2>/dev/null || true
  if [ "$sreason" = dirty ]; then
    tmux display-message "closed scratch ✓ — worktree kept (dirty)" 2>/dev/null || true
  else
    tmux display-message "closed scratch ✓ (worktree reaped)" 2>/dev/null || true
  fi
  exit 0
fi

# --- resolve the row: bound issue, repo, branch, worktree, base ---------------
iss="$(tmux display-message -t "$target" -p '#{@issue}' 2>/dev/null)"
iss="${iss//[^0-9]/}"
[ -z "$iss" ] && refuse "no issue on this row (hub/panel) — nothing to reap"

FLEET_SESSION="$(fleet_current_session)"; export FLEET_SESSION
# Overlay THIS fleet's per-session conf so FLEET_MAIN/FLEET_BASE_BRANCH/FLEET_REPO
# target the reaped row's fleet, not the global default (a secondary fleet has its
# own checkout) — same as dash-issue-session.sh / dash-new-session.sh.
fleet_load_conf "$FLEET_SESSION"
REPO="${FLEET_REPO:-}"
_r="$(fleet_repo_cached "$FLEET_SESSION")"; [ -n "$_r" ] && REPO="$_r"
[ -z "$REPO" ] && refuse "no repo resolved — cannot reap #$iss"

MAIN="${FLEET_MAIN:-}"
[ -n "$MAIN" ] && [ ! -d "$MAIN/.git" ] && MAIN=""
branch="issue-$iss"

# worktree dir + HEAD for this branch (branch→worktree is authoritative).
wtdir=""; whead=""
[ -n "$MAIN" ] && IFS=$'\t' read -r wtdir whead < <(fleet_worktree_head "$MAIN" "$branch")

# base ref for the ancestor test. No blocking `git fetch` on the interactive ⌃x
# path — use the locally-known origin/<base> (kept fresh by the fleet's normal
# fetches); a merged-but-not-locally-visible branch is still caught by the gh
# merged-PR check below, and a stale-negative only makes the SAFE path refuse
# (no data loss). BASE from FLEET_BASE_BRANCH default matches fleet-lib's 'main'.
BASE="${FLEET_BASE_BRANCH:-main}"; MASTER=""
if [ -n "$MAIN" ]; then
  MASTER="$(git -C "$MAIN" rev-parse --verify -q "origin/$BASE" 2>/dev/null \
    || git -C "$MAIN" rev-parse --verify -q "$BASE" 2>/dev/null)"
fi

# merged PR head-refs for this branch (a --head filter keeps it to one branch).
MERGED_PRS=""
command -v gh >/dev/null 2>&1 && MERGED_PRS="$(gh -R "$REPO" pr list \
  --state merged --head "$branch" --json headRefName -q '.[].headRefName' 2>/dev/null)"

reason="$(fleet_reap_ok "$wtdir" "$MAIN" "$branch" "$whead" "$MASTER" "$MERGED_PRS")"

# --- ⌃x (issue #289): clean+merged reaps straight away; anything else confirms -
# first, then force-reaps. The initial keypress (no `confirm` arg) decides which:
#   merged-pr | ancestor → reap_full now (the cleanup daemon reaps these anyway);
#   dirty | unmerged     → open a y/n confirm popup that re-invokes us `confirm`.
if [ "$confirm" = 0 ]; then
  case "$reason" in
    dirty|unmerged)
      tmux display-popup -w 90% -h 9 -E \
        "bash '$BIN/dash-reap.sh' '$target' confirm" 2>/dev/null || true
      exit 0 ;;
    # merged-pr | ancestor — clean+merged, no confirm. Background the reap (issue
    # #304): the slow git worktree remove + gh issue close run off the ⌃x bind, which
    # returns instantly; the row clears when the bg kill-window lands + the dash
    # refreshes.
    # The verdict rides along so the bg pass can record the right row kind (#471);
    # it is a fixed token from fleet_reap_ok, so it is shell-safe to interpolate.
    *)  fleet_bg "bash '$BIN/dash-reap.sh' '$target' --exec full '$reason'"; exit 0 ;;
  esac
fi

# running inside the confirm popup
if [ "$reason" = dirty ]; then
  msg="Force-reap #$iss? Worktree is DIRTY — it will be KEPT; window + issue close."
else
  msg="Force-reap #$iss? Removes worktree + branch, closes issue + window."
fi
printf '\n  %s\n\n  [y] reap    [n] cancel ' "$msg"
read -rsn1 ans; echo
case "$ans" in y|Y) ;; *) exit 0;; esac

# Background the confirmed reap too (issue #304) so the popup closes INSTANTLY
# instead of blocking on the git remove + gh close.
if [ "$reason" = dirty ]; then fleet_bg "bash '$BIN/dash-reap.sh' '$target' --exec keep '$reason'"
else fleet_bg "bash '$BIN/dash-reap.sh' '$target' --exec full '$reason'"; fi
exit 0
