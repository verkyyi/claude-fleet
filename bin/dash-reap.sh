#!/bin/bash
# dash-reap.sh <window-target> [--force] [confirm] — reap a finished worker row
# from the dash in one keystroke: close its tmux window, remove its git worktree
# (when clean), and close its bound GitHub issue. The safe rule is the SHARED
# fleet_reap_ok() gate (same guarantees as the worktree-autoclean.sh janitor).
#
#   ⌃x  safe reap  (no confirm): proceeds ONLY when the worktree is clean AND
#       merged (a MERGED PR for issue-<N>, or the tip is an ancestor of base).
#       Otherwise REFUSES via tmux display-message with the reason — no data loss.
#   ⌥x  force reap (y/n confirm): relaxes the *merged* requirement (for
#       abandoned/not-merged workers) but STILL never removes a dirty worktree —
#       a dirty worktree is kept, and only the window + issue are closed.
#       (⌥x, not ⌃X: a terminal can't send a distinct Ctrl+Shift byte — fzf
#        folds ctrl-X onto ctrl-x — so the force path rides a real second key.)
#
#   Row state           ⌃x (safe)                    ⌥x (force, confirm)
#   clean + merged      reap wt+branch+issue+window   (same)
#   clean + NOT merged  refuse ("PR not merged")      reap all (issue closed)
#   dirty (any)         refuse ("worktree changes")   close window+issue, KEEP wt
#   raw scratch (@raw)  close window (ephemeral)      (same)
#   hub/panel (no issue) refuse                       refuse
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

# full reap: remove worktree + delete branch, close issue, kill window
reap_full() {
  if [ -n "$wtdir" ] && [ -n "$MAIN" ]; then
    # Reap any detached process anchored to this worktree first (issue #151) — a
    # since-fixed hang left spinning would otherwise outlive the dir and drain a
    # core against the shared tmux server.
    fleet_reap_worktree_procs "$wtdir" >/dev/null 2>&1
    # plain remove (no --force): git itself refuses a dirty worktree, so even a
    # TOCTOU race after the fleet_reap_ok check cannot delete uncommitted work.
    git -C "$MAIN" worktree remove "$wtdir" 2>/dev/null \
      && git -C "$MAIN" branch -D "$branch" >/dev/null 2>&1
    git -C "$MAIN" worktree prune 2>/dev/null || true
  fi
  close_issue
  tmux kill-window -t "$target" 2>/dev/null || true
  tmux display-message "reaped #$iss ✓ (window + worktree + issue)" 2>/dev/null || true
}

# dirty force reap: KEEP the worktree, close issue + kill window only
reap_keep() {
  close_issue
  tmux kill-window -t "$target" 2>/dev/null || true
  tmux display-message "reaped #$iss ✓ (window + issue) — worktree kept (dirty)" 2>/dev/null || true
}

# --- parse args ---------------------------------------------------------------
target="${1:-}"; [ -z "$target" ] && exit 0
force=0; confirm=0
shift || true
for a in "$@"; do case "$a" in --force) force=1;; confirm) confirm=1;; esac; done

command -v git >/dev/null 2>&1 || refuse "git not found"

# --- raw scratch row: close the window + dispose its worktree by the gate ------
# A raw/scratch session (@raw=1) has NO @issue, but since issue #290 it DOES own a
# `scratch-<N>` git worktree off the base branch. So ⌃x closes the window AND
# applies the SAME safe gate the janitor uses (fleet_reap_ok): a clean+no-unmerged
# scratch worktree is removed with its branch; a dirty/unmerged one is KEPT (never
# silently delete an experiment) and ⌥x force disposes it (dirty still kept). With
# no resolvable worktree (a pre-#290 scratch, or a hermetic test) it degrades to the
# historic "just close the window" behavior. Detected BEFORE the hub/panel guard so
# a scratch stops looking like a no-op ⌃x; true hub/panel rows (plan/dash/backlog —
# no @issue AND no @raw) still fall through to the "nothing to reap" refuse below.
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

  # Safe path (⌃x): reap only a clean+no-unmerged scratch; else KEEP + note.
  if [ "$force" = 0 ]; then
    case "$sreason" in
      merged-pr|ancestor)
        scratch_remove
        tmux kill-window -t "$target" 2>/dev/null || true
        tmux display-message "closed scratch ✓ (worktree reaped)" 2>/dev/null || true ;;
      *)   # dirty | unmerged — keep the experiment, close the window only
        tmux kill-window -t "$target" 2>/dev/null || true
        tmux display-message "closed scratch ✓ — worktree KEPT ($sreason); ⌃X to dispose" 2>/dev/null || true ;;
    esac
    exit 0
  fi

  # Force path (⌥x): confirm once, then dispose. A DIRTY worktree is still KEPT
  # (git refuses a dirty remove anyway) — only the window closes.
  if [ "$confirm" = 0 ]; then
    tmux display-popup -w 68 -h 9 -E \
      "bash '$BIN/dash-reap.sh' '$target' --force confirm" 2>/dev/null || true
    exit 0
  fi
  if [ "$sreason" = dirty ]; then
    msg="Force-reap $sbranch? Worktree is DIRTY — it will be KEPT; window closes."
  else
    msg="Force-reap $sbranch? Removes the scratch worktree + branch, closes the window."
  fi
  printf '\n  %s\n\n  [y] reap    [n] cancel ' "$msg"
  read -rsn1 ans; echo
  case "$ans" in y|Y) ;; *) exit 0;; esac
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

# --- safe path (⌃x): reap only clean+merged, else refuse with the reason ------
if [ "$force" = 0 ]; then
  case "$reason" in
    dirty)    refuse "#$iss worktree has changes — use ⌃X to force (keeps the worktree)";;
    unmerged) refuse "#$iss PR not merged — use ⌃X to force";;
    *)        reap_full ;;   # merged-pr | ancestor
  esac
  exit 0
fi

# --- force path (⌃X): confirm once, then reap (dirty keeps the worktree) -------
if [ "$confirm" = 0 ]; then
  tmux display-popup -w 68 -h 9 -E \
    "bash '$BIN/dash-reap.sh' '$target' --force confirm" 2>/dev/null || true
  exit 0
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

if [ "$reason" = dirty ]; then reap_keep; else reap_full; fi
exit 0
