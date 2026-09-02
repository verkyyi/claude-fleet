#!/bin/bash
# worktree-autoclean.sh — headless pruning of merged, unattached git worktrees.
# Runs from launchd (com.claude-fleet.worktree-autoclean). Safe by construction:
# a worktree is removed ONLY when ALL of these hold:
#   * it is not the main worktree
#   * its branch is not protected (FLEET_PROTECTED_RE)
#   * no live worker is bound to it: no live pane binds @issue=<N> for an
#     issue-<N> worktree, AND no live pane's cwd is inside it (issue #353 — the
#     @issue identity check is cwd-independent, so a busy worker whose cwd has
#     wandered into a subdir is not false-reaped)
#   * no live fleet tmux SERVER is cwd'd inside it (issue #509 — a server chdir's
#     itself into panes it spawns, and reaping the dir it sits in strands it on a
#     deleted inode, breaking every future spawn on that server)
#   * it is clean (no uncommitted changes; untracked counts as dirty)
#   * it is merged: a MERGED PR exists for the branch on GitHub, OR the branch
#     tip is an ancestor of origin/<base>
# On prune of a merged `issue-<N>` worktree, the bound issue #N is AUTO-CLOSED
# (if still open) with a pointer to the merge — the net for a PR that landed
# without a `Closes #N` keyword.
# A KEPT worktree still gets its detached processes swept (issue #469): the
# liveness gate above has already established that no window is bound to it, so a
# dev/mock server still anchored to the worktree — or to that session's scratchpad
# dir outside it — is by definition an orphan and would otherwise run forever (11
# were found alive 2 days after their window closed, two of them pegging a core).
# Only the KEEP-because-dirty/unmerged paths sweep; a worktree kept as PROTECTED
# never reaches the liveness gate and is never touched. Set FLEET_REAP_KEPT_PROCS=0
# to leave an intentionally long-lived preview server alone.
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
# merged-PR gate below reaps a PRISTINE (never-used) or landed one for free. What it
# must NOT do is silently delete WORK: a scratch worktree that is dirty or has
# unmerged local commits is KEPT and surfaced ONCE (a deduped, best-effort notify to
# whatever fleet client is attached), so the operator knows to dispose of it with
# `dash ⌃x` — and a CLEAN scratch where a real session ran (a Q&A / research
# conversation writes no files, but the conversation IS the work) is kept + surfaced
# the same way rather than silently pruned; see the ancestor arm in process().
# The surface marker lives outside the worktree (a marker inside would
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
# Also gather @issue across every live pane (issue #353). A worker window binds
# @issue=<N> at spawn (a window user-option, inherited per-pane), so this is a
# proxy for worker IDENTITY that is robust to the pane's cwd — unlike the exact
# pane_current_path match above, which false-negatives a busy worker whenever its
# foreground cwd has wandered into a subdir/scratch dir or has not settled right
# after spawn, and can then false-reap the live worker's worktree.
LIVE_ISSUES="$(for _s in $SOCKETS; do tmux -L "$_s" list-panes -a -F '#{@issue}' 2>/dev/null; done)"

# Also gather each live fleet SERVER's OWN process cwd (issue #509). A tmux server
# chdir's itself into the panes it spawns, so its cwd drifts into a worktree over
# time; reaping THAT worktree strands the server on a deleted inode and every
# window it spawns afterwards is born in a dead cwd — Claude Code aborts at launch
# with "The current working directory was deleted". The drift is cross-fleet (it
# follows pane creation, not the repo), so this reads EVERY fleet server's cwd, and
# a worktree any of them sits in is treated as live below. See fleet_server_cwds.
LIVE_SERVER_CWDS="$(fleet_server_cwds)"

# --- orphan procs of a KEPT worktree, issue #469 -------------------------------
# #151 reaps a worktree's detached processes when it is PRUNED. A dirty/unmerged
# worktree is KEPT forever (correctly — #290 must never silently delete an
# experiment), so before #469 its processes were never swept at all. Call this ONLY
# from past the liveness gate, where "no window is bound to $dir" already holds.
# The age gate matters here in a way it does not at prune time: this runs hourly
# against a live machine, and the reaper's argv matcher would otherwise catch a
# live session's transient command that merely mentions the path.
REAP_MINAGE="${FLEET_REAP_KEPT_MINAGE:-600}"
reap_detached() {   # $1=worktree-dir  $2=branch
  [ "${FLEET_REAP_KEPT_PROCS:-1}" = 1 ] || return 0
  local rp
  if [ "$DRY" = 1 ]; then
    rp="$(fleet_reap_worktree_procs "$1" dry 2 "$REAP_MINAGE")"
    case "$rp" in would\ reap:*) echo "      $rp  (window gone — kept worktree)" ;; esac
    return 0
  fi
  rp="$(fleet_reap_worktree_procs "$1" kill 2 "$REAP_MINAGE")"
  case "$rp" in no\ orphan\ procs) ;; *) log "REAP  $2 — $rp (kept worktree, window gone)" ;; esac
}

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
  # Liveness (issue #353): key off worker IDENTITY first, cwd only as a fallback.
  # A worker window binds @issue=<N> and lives in the issue-<N> worktree, so an
  # exact @issue match KEEPs it whether or not its pane cwd happens to sit at the
  # worktree root — this is what stops a busy worker (cwd in a subdir, a scratch
  # dir, or unsettled just after spawn) from being false-reaped. The cwd check
  # remains for non-issue worktrees (e.g. scratch-*), now a PREFIX match so a pane
  # cd'd into a subdir of the worktree still counts as attached.
  local _inum=""
  case "$branch" in issue-[0-9]*) _inum="${branch#issue-}"; _inum="${_inum%%[!0-9]*}" ;; esac
  if [ -n "$_inum" ] && printf '%s\n' "$LIVE_ISSUES" | grep -qxF "$_inum"; then
    say "KEEP  $branch  (live worker window @issue=$_inum)"; kept=$((kept+1)); return
  fi
  if printf '%s\n' "$LIVE" | grep -qxF "$dir" || printf '%s\n' "$LIVE" | grep -qF "$dir/"; then
    say "KEEP  $branch  (live tmux session)"; kept=$((kept+1)); return
  fi
  # A tmux SERVER whose own cwd is inside this worktree keeps it (issue #509):
  # reaping it would strand the server on a deleted inode, and every window it
  # spawns after that is born in a dead cwd (Claude Code aborts at launch). Same
  # exact-or-prefix match as the live-pane gate above — a server cwd'd in a subdir
  # still counts. This is a fleet-wide signal (fleet_server_cwds walks every live
  # server), so a claude-fleet server drifted into a 24haowan worktree protects it.
  if printf '%s\n' "$LIVE_SERVER_CWDS" | grep -qxF "$dir" || printf '%s\n' "$LIVE_SERVER_CWDS" | grep -qF "$dir/"; then
    say "KEEP  $branch  (a tmux server is cwd'd here)"; kept=$((kept+1)); return
  fi
  # clean + merged? — the shared gate (identical logic in dash-reap.sh).
  local merged is_scratch=0
  case "$branch" in scratch-*) is_scratch=1 ;; esac   # issue #290
  merged="$(fleet_reap_ok "$dir" "$REPO_ROOT" "$branch" "$head" "$MASTER" "$MERGED_PRS")"
  case "$merged" in
    dirty)
      # The worktree stays, its orphaned processes do not (#469).
      reap_detached "$dir" "$branch"
      # scratch: never silently delete an experiment — keep + surface once (#290).
      if [ "$is_scratch" = 1 ]; then scratch_surface "$dir" "$branch" "dirty"; return; fi
      say "KEEP  $branch  (dirty — uncommitted changes)"; kept=$((kept+1)); return ;;
    unmerged)
      reap_detached "$dir" "$branch"
      if [ "$is_scratch" = 1 ]; then scratch_surface "$dir" "$branch" "unmerged work"; return; fi
      say "KEEP  $branch  (not merged)"; kept=$((kept+1)); return ;;
    ancestor)
      # A clean scratch whose tip never moved off base is NOT disposable when a
      # REAL session ran in it: "no file writes" describes most Q&A / research
      # scratches, and the conversation IS the work. The git-state gate alone
      # can't tell that apart from a never-used worktree, so consult the
      # transcript dir: a human session there → KEEP + surface (⌃x remains the
      # deliberate disposal path); helper-only or no transcripts (a warm-pool
      # slot, a spawn nobody typed into) → still pruned silently, as ever.
      if [ "$is_scratch" = 1 ]; then
        local hsid; hsid="$(fleet_newest_human_session "$(fleet_transcript_dir "$dir")")"
        if [ -n "$hsid" ]; then
          # Still RECORD the /fleet-history row (#466's safety net — SessionEnd /
          # ledger-watch usually beat us here, but a crashed window may have
          # missed both; idempotent, so at most one row). Recording while the
          # worktree stands captures the transcript path + HEAD sha as ever.
          [ "$DRY" = 1 ] || fleet_reap_record "ancestor" "$REPO" "$REPO_ROOT" "" "$dir" "" "" "" "$branch"
          reap_detached "$dir" "$branch"
          scratch_surface "$dir" "$branch" "clean, but a session ran here"
          return
        fi
      fi
      merged="ancestor-of-$BASE" ;;   # restore base-qualified label for the log/comment
    merged-pr) merged="merged-PR" ;;
  esac
  # Past the gate: this is a clean+no-unmerged-work scratch NOBODY used (silently) OR
  # a clean+merged (issue or escalated scratch) worktree → prune below.
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
  # Record a /fleet-history row BEFORE we remove the worktree (issue #384). The
  # cleanup daemon is not the only reaper, so autoclean must write the row itself —
  # else with FLEET_CLEANUP=0 (and ledger-watch unloaded) every worker reaped here
  # silently vanishes from /fleet-history. The shared helper (also driven by
  # fleet-cleanup.sh) maps a merged-PR reap → a `landed` row (PR resolved from the
  # branch) and a clean-ancestor reap → a `closed-unlanded` row; it is idempotent,
  # so it never double-records when the cleanup daemon is ALSO on. The window is
  # already gone (this worktree passed the liveness gate), so there is no live
  # --win/--session summary to pass — the recorded title still names the row.
  # Scratch too (issue #466): $inum is empty for a `scratch-<N>` branch, and the
  # helper then keys the row by that slug — so the silent prune of a clean scratch
  # worktree below leaves an indexed, resumable /fleet-history row behind instead of
  # dropping the experiment's transcript on the floor. Order matters as ever: this
  # runs BEFORE the remove, which is where the row's transcript path and rebuild sha
  # come from.
  fleet_reap_record "$merged" "$REPO" "$REPO_ROOT" "$inum" "$dir" "" "" "" "$branch"
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
