#!/bin/bash
# worktree-autoclean.sh — headless pruning of merged, unattached git worktrees.
# Runs from launchd (com.claude-fleet.worktree-autoclean). Safe by construction:
# a worktree is removed ONLY when ALL of these hold:
#   * it is not the main worktree
#   * its branch is not protected (FLEET_PROTECTED_RE)
#   * no live tmux pane is cd'd inside it   (== "not attached to a session")
#   * it is clean (no uncommitted changes; untracked counts as dirty)
#   * it is merged: a MERGED PR exists for the branch on GitHub, OR the branch
#     tip is an ancestor of origin/<base>
# On prune of a merged `issue-<N>` worktree, the bound issue #N is AUTO-CLOSED
# (if still open) with a pointer to the merge — the net for a PR that landed
# without a `Closes #N` keyword.
# Fail-safe: if tmux is not running we cannot tell what's attached, so we SKIP.
# Pass --dry-run to print decisions (incl. would-close) without removing anything.
#
# Multi-fleet: cleans EVERY fleet — the global fleet.conf default fleet plus each
# per-fleet conf in $FLEET_CONF_DIR (~/.config/claude-fleet/*.conf). The "live
# tmux pane" set is shared across all fleets, so a worktree open in any session
# is protected everywhere.
set -uo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
LOGDIR="$BIN/../logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/worktree-autoclean.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
say() { if [ "$DRY" = 1 ]; then echo "$*"; else log "$*"; fi; }

# --- scratch (@raw) worktrees, issue #290 -------------------------------------
# A `scratch-<N>` worktree (dash-raw-session.sh) has no issue/PR, so the ancestor/
# merged-PR gate below already reaps a pristine or landed one for free. What it must
# NOT do is silently delete an EXPERIMENT: a scratch worktree that is dirty or has
# unmerged local commits is KEPT and surfaced ONCE (a deduped, best-effort notify to
# whatever fleet client is attached), so the operator knows to dispose of it with
# `dash ⌃x`. The surface marker lives outside the worktree (a marker inside would
# itself read as untracked → forever "dirty").
SURF_DIR="$LOGDIR/.scratch-surfaced"
scratch_key() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'; }
scratch_surface() {   # $1=worktree-dir  $2=branch  $3=reason-label
  say "KEEP  $2  ($3 — scratch experiment, window gone; ⌃x to dispose)"; kept=$((kept+1))
  [ "$DRY" = 1 ] && return
  local mk; mk="$SURF_DIR/$(scratch_key "$1")"
  [ -e "$mk" ] && return                    # already surfaced once — stay quiet
  mkdir -p "$SURF_DIR" 2>/dev/null || true; : > "$mk" 2>/dev/null || true
  for _s in $SOCKETS; do
    tmux -L "$_s" display-message "fleet: scratch $2 kept ($3) — ⌃x to dispose" 2>/dev/null || true
  done
}

command -v git >/dev/null 2>&1 || { say "git not found; abort"; exit 0; }

# Fail-safe: require a live fleet so the "attached" check is meaningful. Each fleet
# is its own tmux server now (issue #159), so gather the live pane paths across
# EVERY fleet socket; no live fleet → skip (we can't tell what's attached).
SOCKETS="$(fleet_sockets)"
if [ -z "$SOCKETS" ]; then
  say "no live fleet — skipping (cannot determine attached sessions)"; exit 0
fi
LIVE="$(for _s in $SOCKETS; do tmux -L "$_s" list-panes -a -F '#{pane_current_path}' 2>/dev/null; done)"

removed=0; kept=0; closed=0
dir=""; head=""; branch=""
REPO_ROOT=""; REPO=""; BASE=""; PROTECTED_RE=""; MASTER=""; MERGED_PRS=""

process() {
  [ -z "$dir" ] && return
  # skip main worktree and detached / no-branch worktrees
  if [ "$dir" = "$REPO_ROOT" ] || [ -z "$branch" ]; then return; fi
  if printf '%s\n' "$branch" | grep -Eq "$PROTECTED_RE"; then
    say "KEEP  $branch  (protected)"; kept=$((kept+1)); return
  fi
  if printf '%s\n' "$LIVE" | grep -qxF "$dir"; then
    say "KEEP  $branch  (live tmux session)"; kept=$((kept+1)); return
  fi
  # clean + merged? — the shared gate (identical logic in dash-reap.sh).
  local merged is_scratch=0
  case "$branch" in scratch-*) is_scratch=1 ;; esac   # issue #290
  merged="$(fleet_reap_ok "$dir" "$REPO_ROOT" "$branch" "$head" "$MASTER" "$MERGED_PRS")"
  case "$merged" in
    dirty)
      # scratch: never silently delete an experiment — keep + surface once (#290).
      if [ "$is_scratch" = 1 ]; then scratch_surface "$dir" "$branch" "dirty"; return; fi
      say "KEEP  $branch  (dirty — uncommitted changes)"; kept=$((kept+1)); return ;;
    unmerged)
      if [ "$is_scratch" = 1 ]; then scratch_surface "$dir" "$branch" "unmerged work"; return; fi
      say "KEEP  $branch  (not merged)"; kept=$((kept+1)); return ;;
    ancestor) merged="ancestor-of-$BASE" ;;   # restore base-qualified label for the log/comment
    merged-pr) merged="merged-PR" ;;
  esac
  # Past the gate: this is a clean+no-unmerged-work (scratch, silently) OR a
  # clean+merged (issue or escalated scratch) worktree → prune below.
  # issue number bound to this worktree (branch convention: issue-<N>)
  local inum=""
  case "$branch" in issue-[0-9]*) inum="${branch#issue-}"; inum="${inum%%[!0-9]*}" ;; esac
  if [ "$DRY" = 1 ]; then
    local ex=""
    if [ -n "$inum" ] && [ -n "$REPO" ]; then
      local st; st="$(gh -R "$REPO" issue view "$inum" --json state -q .state 2>/dev/null)"
      [ "$st" = "OPEN" ] && ex="  + close #$inum" || ex="  (#$inum already ${st:-?})"
    fi
    local dr; dr="$(fleet_reap_worktree_procs "$dir" dry)"
    case "$dr" in would\ reap:*) ex="$ex  [$dr]" ;; esac
    echo "PRUNE $branch  ($merged)  -> ${dir##*/}$ex"; removed=$((removed+1)); return
  fi
  # Reap any detached process still anchored to this worktree BEFORE removing it —
  # otherwise a since-fixed hang can outlive the dir and peg a core against the
  # shared tmux server (issue #151). Nothing should outlive its worktree.
  local rp; rp="$(fleet_reap_worktree_procs "$dir")"
  case "$rp" in no\ orphan\ procs) ;; *) log "REAP  $branch — $rp" ;; esac
  if git -C "$REPO_ROOT" worktree remove "$dir" 2>/dev/null; then
    git -C "$REPO_ROOT" branch -D "$branch" >/dev/null 2>&1
    log "PRUNED $branch ($merged) — removed ${dir##*/} + deleted branch"
    removed=$((removed+1))
    rm -f "$SURF_DIR/$(scratch_key "$dir")" 2>/dev/null || true   # drop any scratch surface marker (#290)
    # auto-close the bound issue if still open (net for a PR lacking Closes #N)
    if [ -n "$inum" ] && [ -n "$REPO" ]; then
      local st; st="$(gh -R "$REPO" issue view "$inum" --json state -q .state 2>/dev/null)"
      if [ "$st" = "OPEN" ]; then
        if gh -R "$REPO" issue close "$inum" \
             --comment "Auto-closed: branch \`$branch\` merged ($merged) and its worktree session was reaped by worktree-autoclean." >/dev/null 2>&1; then
          log "CLOSED #$inum ($REPO) — merged+reaped"; closed=$((closed+1))
        fi
      fi
    fi
  else
    log "FAIL  could not remove $dir (branch $branch)"
  fi
}

clean_fleet() {   # $1=main-checkout  $2=owner/name  $3=base-branch  $4=protected-re
  REPO_ROOT="$1"; REPO="$2"; BASE="${3:-main}"
  PROTECTED_RE="${4:-^(master|main|develop|test)$}"
  [ -d "$REPO_ROOT/.git" ] || { say "SKIP  $REPO_ROOT (not a git checkout)"; return; }
  git -C "$REPO_ROOT" fetch -q origin "$BASE" 2>/dev/null
  MASTER="$(git -C "$REPO_ROOT" rev-parse --verify -q "origin/$BASE" 2>/dev/null \
    || git -C "$REPO_ROOT" rev-parse --verify -q "$BASE")"
  [ -z "$MASTER" ] && { say "SKIP  $REPO_ROOT (cannot resolve base $BASE)"; return; }
  MERGED_PRS=""
  [ -n "$REPO" ] && MERGED_PRS="$(gh -R "$REPO" pr list \
    --state merged --limit 400 --json headRefName -q '.[].headRefName' 2>/dev/null)"
  say "fleet $REPO_ROOT  (repo=${REPO:-·} base=$BASE)"
  dir=""; head=""; branch=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) process; dir="${line#worktree }"; head=""; branch="" ;;
      "HEAD "*)     head="${line#HEAD }" ;;
      "branch "*)   branch="${line#branch refs/heads/}" ;;
    esac
  done <<EOF
$(git -C "$REPO_ROOT" worktree list --porcelain)
EOF
  process   # flush last block
  git -C "$REPO_ROOT" worktree prune 2>/dev/null   # drop stale admin entries
}

# --- enumerate fleets: the global/default fleet, then each per-fleet conf ---
DEFAULT_MAIN="${FLEET_MAIN:-}"
[ -n "$DEFAULT_MAIN" ] && clean_fleet "$DEFAULT_MAIN" "${FLEET_REPO:-}" \
  "${FLEET_BASE_BRANCH:-main}" "${FLEET_PROTECTED_RE:-}"
while IFS=$'\t' read -r _s cf; do
  [ -f "$cf" ] || continue
  IFS=$'\t' read -r fm fr fb fp < <( . "$cf" >/dev/null 2>&1
    printf '%s\t%s\t%s\t%s' "${FLEET_MAIN:-}" "${FLEET_REPO:-}" \
      "${FLEET_BASE_BRANCH:-main}" "${FLEET_PROTECTED_RE:-}" )
  [ -n "$fm" ] || continue
  [ "$fm" = "$DEFAULT_MAIN" ] && continue   # already cleaned as the global default
  clean_fleet "$fm" "$fr" "$fb" "$fp"
done < <(fleet_each_conf)

say "done: pruned=$removed closed=$closed kept=$kept"
# keep the log from growing unbounded
if [ "$DRY" = 0 ] && [ -f "$LOG" ]; then tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
exit 0
