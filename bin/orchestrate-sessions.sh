#!/bin/bash
# orchestrate-sessions.sh [--dry-run] — auto-orchestrator. For each live fleet
# (tmux session) that OPTS IN via FLEET_MAX_SESSIONS, keep the fleet busy by
# spawning issue-bound Claude sessions off the remaining backlog until it has
# FLEET_MAX_SESSIONS *running* sessions. OPTIONAL — everything else works
# without it; a fleet with no FLEET_MAX_SESSIONS is left completely alone.
#
# Run from launchd (com.claude-fleet.orchestrate, StartInterval ~120) or a
# systemd user timer. Reads only the collector's issue cache (no gh/network of
# its own); the only side effect is `git worktree add` + `tmux new-window` via
# dash-issue-session.sh, exactly like pressing Enter on the backlog panel.
#
# Opt-in + cap, per fleet (global fleet.conf default, overridable per-fleet in
# $FLEET_CONF_DIR/<session>.conf):
#   FLEET_MAX_SESSIONS      cap on concurrently RUNNING sessions. Unset/≤0 → this
#                           fleet is not orchestrated (the daemon no-ops it).
#   FLEET_ORCHESTRATE_BATCH optional per-tick spawn cap (ramp control). Unset →
#                           fill straight to the cap in one tick.
#
# "Running" = windows bound to an issue (@issue set) whose @claude_state is not
# 'done' — freshly-spawned, working, needs, and looping sessions all count; a
# finished ('done') session frees its slot so the next backlog item can start.
# Panels (dash/plan/backlog and any window with no @issue) never count.
#
# Backlog eligibility (conservative — never touches human-owned work): an OPEN
# issue that is UNASSIGNED, not already bound to a window in this fleet, and has
# no leftover issue-<N> worktree on disk. Lowest issue number first (oldest).
# The spawned session self-claims the issue, so the next collector cycle drops
# it from the unassigned set — no double-spawn.
set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
LOGDIR="$BIN/../logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/orchestrator.log"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
say() { if [ "$DRY" = 1 ]; then echo "$*"; else log "$*"; fi; }

# Fail-safe: without a live tmux server we can't count windows or spawn — skip.
tmux info >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || { say "git not found; abort"; exit 0; }

# Single-writer lock: launchd/systemd can fire a new tick while the previous one
# is still spawning (worktree adds are slow). Overlap would double-spawn, so
# serialize with an atomic mkdir lock; steal it if a crashed run left it >10m.
LOCK="$C/orchestrator.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
    say "stole stale lock"
  else
    exit 0   # another tick is running
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# Orchestrate ONE fleet. Runs in a subshell (see the call site) so the per-fleet
# conf overlay never bleeds into the next fleet.
orchestrate_fleet() {
  local sess="$1"
  fleet_load_conf "$sess"                     # overlay this fleet's conf on the globals
  local max="${FLEET_MAX_SESSIONS:-}"
  case "$max" in ''|*[!0-9]*) return;; esac    # unset / non-numeric → not orchestrated
  [ "$max" -le 0 ] && return                    # 0 → explicitly off

  local MAIN="${FLEET_MAIN:-}" REPO="${FLEET_REPO:-}"
  if [ ! -d "$MAIN/.git" ]; then
    say "SKIP  $sess (FLEET_MAIN '$MAIN' is not a git checkout)"; return
  fi

  # running = @issue windows not yet 'done'
  local running
  running=$(tmux list-windows -t "$sess" -F '#{@issue}'$'\t''#{@claude_state}' 2>/dev/null \
    | awk -F'\t' '$1!="" && $2!="done"{c++} END{print c+0}')
  local deficit=$(( max - running ))
  if [ "$deficit" -le 0 ]; then
    say "fleet $sess (repo=${REPO:-·}) running=$running/max=$max — full"; return
  fi
  # optional per-tick ramp cap
  local batch="${FLEET_ORCHESTRATE_BATCH:-}"
  case "$batch" in ''|*[!0-9]*) : ;; *) [ "$batch" -ge 1 ] && [ "$deficit" -gt "$batch" ] && deficit="$batch";; esac

  # issues already bound to a window in THIS fleet (any state) → never re-spawn
  local bound
  bound=$(tmux list-windows -t "$sess" -F '#{@issue}' 2>/dev/null | awk 'NF')
  is_bound() { printf '%s\n' "$bound" | grep -qxF "$1"; }

  # this fleet's backlog cache (slug'd via the collector's sessmap; flat fallback)
  local ISSUES parent
  ISSUES=$(fleet_cache issues "$sess")
  parent="$(dirname "$MAIN")/$(basename "$MAIN")"
  say "fleet $sess (repo=${REPO:-·}) running=$running/max=$max — spawning up to $deficit"

  local spawned=0 num wt
  # unassigned open issues (assignee '·' in field 3), lowest number first
  while IFS= read -r num; do
    [ "$spawned" -ge "$deficit" ] && break
    [ -z "$num" ] && continue
    if is_bound "$num"; then continue; fi
    wt="$parent-issue-$num"
    if [ -e "$wt" ]; then say "  skip #$num (worktree $wt exists)"; continue; fi
    if [ "$DRY" = 1 ]; then echo "  SPAWN #$num → issue-$num"; spawned=$((spawned+1)); continue; fi
    if bash "$BIN/dash-issue-session.sh" "$num" "$sess" >/dev/null 2>&1; then
      say "  SPAWNED #$num (issue-$num)"; spawned=$((spawned+1))
    else
      say "  FAIL to spawn #$num"
    fi
  done <<EOF
$([ -s "$ISSUES" ] && awk -F'\t' '$3=="·"{n=$2; sub(/^#/,"",n); if(n ~ /^[0-9]+$/) print n}' "$ISSUES" | sort -n)
EOF
  say "fleet $sess — spawned $spawned this tick"
}

# --- enumerate live fleets (each tmux session ≡ one fleet) ---
for sess in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
  ( orchestrate_fleet "$sess" )     # subshell: isolate the sourced per-fleet conf
done

# keep the log bounded
if [ "$DRY" = 0 ] && [ -f "$LOG" ]; then tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
exit 0
