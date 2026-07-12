#!/bin/bash
# fleet-cleanup-daemon.sh [--dry-run] [session...] — the CLEANUP daemon
# (com.claude-fleet.cleanup, ~60s; issue #277, closes #260).
#
# THE FLEET NEVER MERGES — it cleans up AFTER merges and keeps sessions resumable.
# the worker /fleet-claim ship step arms GitHub auto-merge; GitHub (or a human on the web, or a
# collaborator) does the merge; this daemon is what reaps the leftover worktree +
# window + branch and records the resume ledger once the PR is final. It replaces
# the retired auto-land daemon: same single-writer + disk-gated shape, but it
# drives bin/fleet-cleanup.sh (no merge) instead of bin/fleet-land.sh (merge).
#
# It is NOT an approval-gate relaxation — it merges nothing. So, unlike the
# auto-land daemon it replaces, it is ON BY DEFAULT for every fleet (opt out per
# fleet with FLEET_CLEANUP=0); the janitorial work is the point of the design.
#
# Design (mirrors the other single-writer, disk-gated fleet daemons):
#   for each live fleet session (or the ones named on argv):
#     load its conf; skip if FLEET_CLEANUP=0
#     acquire a per-REPO LEASE (mkdir, steal-if-stale)      → single-writer
#     honor the diskguard GATE (fleet-diskguard.sh --gate)  → never reap on a full disk
#     read the prmap_<slug> cache pr-refresh already writes  → ZERO extra gh
#     candidates = its MERGED/CLOSED PRs whose issue-<N> STILL has a live worktree
#                  or window (a local git/tmux check — zero gh)
#     clean up to FLEET_CLEANUP_MAX_PER_TICK of them via bin/fleet-cleanup.sh <pr>
#     release the lease
#
#   Serialization with base-movers is the SHARED per-repo land-lease INSIDE
#   fleet-cleanup.sh (base fast-forward) — this daemon's own lease only stops two
#   cleanup ticks from double-driving one repo. Idempotent: a PR whose worktree +
#   window are already gone short-circuits (skip:nothing) inside fleet-cleanup.sh.
#
# DETECTION IS CACHE + LOCAL ONLY. We read prmap_<slug> (branch<TAB>#num<TAB>state
# <TAB>ci<TAB>ready) — the file the dash + watcher already read, written with
# `gh pr list --state all` so MERGED/CLOSED rows are present — plus a local
# `git worktree list` / `tmux list-windows`. A tick that reaps nothing costs no
# gh. Only fleet-cleanup.sh talks to gh (one pr view per reaped PR).
#
# Env knobs (all per-fleet, in $FLEET_CONF_DIR/<session>.conf or global fleet.conf):
#   FLEET_CLEANUP              0 to disable for this fleet          (default 1/on)
#   FLEET_CLEANUP_MAX_PER_TICK max PRs reaped per fleet per tick    (default 4)
#   FLEET_CLEANUP_LEASE_TTL    lease lifetime, seconds              (default 300)
#   FLEET_DISPATCH_LEASE_DIR   lease dir (shared)    (default ~/.claude/leases)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

DRY=0
ARGV_SESS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           printf 'fleet-cleanup-daemon: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)            ARGV_SESS+=("$1") ;;
  esac
  shift
done

LEASE_TTL="${FLEET_CLEANUP_LEASE_TTL:-300}"
LEASE_DIR="${FLEET_DISPATCH_LEASE_DIR:-$HOME/.claude/leases}"

# All progress goes to stderr — a daemon's stdout is /dev/null; stderr is the log.
now() { date +%s 2>/dev/null || echo 0; }
log() { printf '%s fleet-cleanup: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# --- per-repo lease (single-writer; steal-if-stale) ----------------------------
lease_acquire() { # $1 = lease path, $2 = my holder id
  local lease="$1" me="$2" now exp holder
  mkdir -p "$LEASE_DIR" 2>/dev/null
  now=$(now)
  if mkdir "$lease" 2>/dev/null; then
    printf '%s\n%s\n' "$me" "$((now + LEASE_TTL))" > "$lease/holder"
    return 0
  fi
  holder=$(sed -n 1p "$lease/holder" 2>/dev/null)
  exp=$(sed -n 2p "$lease/holder" 2>/dev/null); exp="${exp//[^0-9]/}"; exp="${exp:-0}"
  if [ "$now" -ge "$exp" ]; then                       # stale → steal
    rm -rf "$lease" 2>/dev/null
    if mkdir "$lease" 2>/dev/null; then
      printf '%s\n%s\n' "$me" "$((now + LEASE_TTL))" > "$lease/holder"
      log "stole stale lease (was ${holder:-?})"
      return 0
    fi
  fi
  return 1
}
# shellcheck disable=SC2329  # invoked indirectly via the `trap '…' EXIT` below
lease_release() { # $1 = lease path, $2 = my holder id
  [ "$(sed -n 1p "$1/holder" 2>/dev/null)" = "$2" ] && rm -rf "$1" 2>/dev/null
  return 0
}

# --- MERGED/CLOSED PRs with an issue-<N> head, from the prmap cache ------------
# prmap row: branch<TAB>#num<TAB>state<TAB>ci<TAB>ready. Prints "num<TAB>issue"
# for every MERGED/CLOSED row whose head is issue-<N>.
final_issue_prs() { # $1 = prmap file
  local prmf="$1"
  [ -s "$prmf" ] || return 0
  awk -F'\t' '
    ($3=="MERGED" || $3=="CLOSED") && $1 ~ /^issue-[0-9]+$/ {
      n=$2; sub(/^#/,"",n); iss=$1; sub(/^issue-/,"",iss); print n "\t" iss
    }' "$prmf" 2>/dev/null
}

# --- clean up ONE fleet. Runs in a subshell so its per-fleet conf never leaks. ---
cleanup_fleet() { (
  sess="$1"
  fleet_load_conf "$sess"
  if [ "${FLEET_CLEANUP:-1}" = 0 ]; then
    log "$sess: cleanup off (FLEET_CLEANUP=0) — skip"
    exit 0
  fi

  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && repo="$_r"
  [ -z "$repo" ] && { log "$sess: no repo resolved — skip"; exit 0; }
  command -v gh >/dev/null 2>&1 || { log "$sess: gh not on PATH — skip"; exit 0; }
  main="${FLEET_MAIN:-}"
  [ -d "$main/.git" ] || { log "$sess: FLEET_MAIN is not a git checkout — skip"; exit 0; }
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")

  # Rate-limit: at most K reaps this tick. 0 → skip.
  k="${FLEET_CLEANUP_MAX_PER_TICK:-4}"
  case "$k" in ''|*[!0-9]*) k=4;; esac
  if [ "$k" -le 0 ]; then
    log "$sess: per-tick cap is 0 (FLEET_CLEANUP_MAX_PER_TICK) — skip"
    exit 0
  fi

  # Single-writer per REPO: two sessions serving one repo don't double-drive a reap.
  lease="$LEASE_DIR/cleanup-$slug.lock"
  me="cleanup:$sess:$$@$(hostname -s 2>/dev/null || echo host)"
  if [ "$DRY" = 0 ]; then
    lease_acquire "$lease" "$me" || { log "$sess: another cleaner holds the lease — skip"; exit 0; }
    trap 'lease_release "$lease" "$me"' EXIT
  fi

  # Detection is cache-only: the prmap pr-refresh already writes (ZERO extra gh).
  prmf=$(fleet_cache prmap "$sess")
  if [ ! -s "$prmf" ]; then
    log "$sess: no prmap cache yet (pr-refresh hasn't run for $slug?) — skip"
    exit 0
  fi

  # tmux socket helper: the daemon has no $TMUX → target the fleet's OWN socket.
  ftmux() { tmux -L "$(fleet_socket "$sess")" "$@"; }

  # Collect the live issue-<N> worktrees + windows ONCE (local, zero gh) — a PR is
  # a cleanup candidate only if its issue still has debris to reap.
  live=$'\n'
  while IFS= read -r i; do [ -n "$i" ] && live="${live}${i}"$'\n'; done < <(
    git -C "$main" worktree list --porcelain 2>/dev/null | \
      sed -n 's#^branch refs/heads/issue-\([0-9][0-9]*\)$#\1#p'
    ftmux list-windows -t "$sess" -F '#{@issue}' 2>/dev/null | sed 's/[^0-9]//g'
  )

  cleaned=0; considered=0
  while IFS=$'\t' read -r pr iss; do
    [ -z "$pr" ] && continue
    # live worktree or window for this issue?
    case "$live" in *$'\n'"$iss"$'\n'*) : ;; *) continue ;; esac
    considered=$((considered + 1))

    if [ "$DRY" = 1 ]; then
      log "$sess: would clean PR #$pr (issue #$iss)  [slot $((cleaned + 1))/$k]"
      cleaned=$((cleaned + 1))
      [ "$cleaned" -ge "$k" ] && break
      continue
    fi

    # Drive the shared mechanical janitor. Its ONE stdout line is the result token;
    # its progress notes go to stderr → this daemon's log. Pass FLEET_SESSION so it
    # resolves THIS fleet's repo/main/socket (it has no $TMUX).
    tok=$(FLEET_SESSION="$sess" bash "$BIN/fleet-cleanup.sh" "$pr")
    rc=$?
    case "$tok" in
      cleaned:*) log "$sess: $tok  (PR #$pr, issue #$iss)  [slot $((cleaned + 1))/$k]"; cleaned=$((cleaned + 1)) ;;
      skip:*)    log "$sess: PR #$pr (#$iss) — $tok (nothing to reap)" ;;
      error:*)   log "$sess: PR #$pr cleanup error ($tok)" ;;
      *)         log "$sess: PR #$pr cleanup returned rc=$rc token='${tok:-none}'" ;;
    esac
    [ "$cleaned" -ge "$k" ] && break
  done <<EOF
$(final_issue_prs "$prmf")
EOF

  if [ "$considered" -eq 0 ]; then
    log "$sess: no MERGED/CLOSED PRs with leftover worktree/window in the prmap cache"
  elif [ "$cleaned" -eq 0 ]; then
    log "$sess: nothing reaped (all candidates already clean)"
  else
    log "$sess: reaped $cleaned PR(s) (cap/tick=$k)"
  fi
) }

# --- which fleets? argv wins; else every live fleet session on this server. -----
SESSIONS=()
if [ "${#ARGV_SESS[@]}" -gt 0 ]; then
  SESSIONS=("${ARGV_SESS[@]}")
else
  while IFS= read -r s; do
    [ -n "$s" ] && SESSIONS+=("$s")
  done < <(fleet_hub_sessions | sort)
fi

if [ "${#SESSIONS[@]}" -eq 0 ]; then
  log "no fleet sessions found (nothing to clean up)"
  exit 0
fi

# Diskguard gate is a MACHINE-WIDE (per-volume) condition, so answer it ONCE per
# tick. A cleanup does a base-checkout pull + worktree teardown; don't add that
# I/O below the floor. Mirrors the other single-writer, disk-gated fleet daemons.
if [ "$DRY" = 0 ] && [ -x "$BIN/fleet-diskguard.sh" ] \
   && ! "$BIN/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
  log "disk gate closed — skipping all fleets this tick"
  exit 0
fi

for s in "${SESSIONS[@]}"; do
  cleanup_fleet "$s"
done
exit 0
