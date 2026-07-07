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
# Fail-safe: if tmux is not running we cannot tell what's attached, so we SKIP.
# Pass --dry-run to print decisions without removing anything.
#
# Multi-fleet: cleans EVERY fleet — the global fleet.conf default fleet plus each
# per-fleet conf in $FLEET_CONF_DIR (~/.config/claude-fleet/*.conf). The "live
# tmux pane" set is shared across all fleets, so a worktree open in any session
# is protected everywhere.
set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
LOGDIR="$BIN/../logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/worktree-autoclean.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
say() { if [ "$DRY" = 1 ]; then echo "$*"; else log "$*"; fi; }

command -v git >/dev/null 2>&1 || { say "git not found; abort"; exit 0; }

# Fail-safe: require a live tmux server so the "attached" check is meaningful.
if ! tmux info >/dev/null 2>&1; then
  say "tmux not running — skipping (cannot determine attached sessions)"; exit 0
fi
LIVE="$(tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null)"

removed=0; kept=0
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
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    say "KEEP  $branch  (dirty — uncommitted changes)"; kept=$((kept+1)); return
  fi
  local merged=""
  if printf '%s\n' "$MERGED_PRS" | grep -qxF "$branch"; then
    merged="merged-PR"
  elif git -C "$REPO_ROOT" merge-base --is-ancestor "$head" "$MASTER" 2>/dev/null; then
    merged="ancestor-of-$BASE"
  fi
  if [ -z "$merged" ]; then
    say "KEEP  $branch  (not merged)"; kept=$((kept+1)); return
  fi
  if [ "$DRY" = 1 ]; then
    echo "PRUNE $branch  ($merged)  -> ${dir##*/}"; removed=$((removed+1)); return
  fi
  if git -C "$REPO_ROOT" worktree remove "$dir" 2>/dev/null; then
    git -C "$REPO_ROOT" branch -D "$branch" >/dev/null 2>&1
    log "PRUNED $branch ($merged) — removed ${dir##*/} + deleted branch"
    removed=$((removed+1))
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
if [ -d "$FLEET_CONF_DIR" ]; then
  for cf in "$FLEET_CONF_DIR"/*.conf; do
    [ -f "$cf" ] || continue
    IFS=$'\t' read -r fm fr fb fp < <( . "$cf" >/dev/null 2>&1
      printf '%s\t%s\t%s\t%s' "${FLEET_MAIN:-}" "${FLEET_REPO:-}" \
        "${FLEET_BASE_BRANCH:-main}" "${FLEET_PROTECTED_RE:-}" )
    [ -n "$fm" ] || continue
    [ "$fm" = "$DEFAULT_MAIN" ] && continue   # already cleaned as the global default
    clean_fleet "$fm" "$fr" "$fb" "$fp"
  done
fi

say "done: pruned=$removed kept=$kept"
# keep the log from growing unbounded
if [ "$DRY" = 0 ] && [ -f "$LOG" ]; then tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
exit 0
