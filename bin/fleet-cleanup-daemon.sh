#!/bin/bash
# fleet-cleanup-daemon.sh [--dry-run] [session...] — the CLEANUP daemon
# (com.claude-fleet.cleanup, ~60s; issue #277, closes #260).
#
# THIS DAEMON NEVER MERGES — it cleans up AFTER merges and keeps sessions resumable.
# The worker's /fleet-claim ship+land step merges its own PR on a green gate (#441) —
# or a human on the web, or a collaborator, does; this daemon is what reaps the
# leftover worktree + window + branch and records the resume ledger once the PR is
# final. It runs OUTSIDE every window, so reaping the window whose worker just
# merged is the ordinary case, not a special one. It replaces
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
#     candidates = its MERGED/CLOSED PRs whose head branch STILL has a live
#                  worktree or window (a local git/tmux check — zero gh)
#     clean up to FLEET_CLEANUP_MAX_PER_TICK of them via bin/fleet-cleanup.sh <pr>,
#       each under a FLEET_CLEANUP_CANDIDATE_TIMEOUT wall-clock budget
#     release the lease
#   then, once per tick and BEFORE the disk gate: fleet_trash_sweep, the budgeted
#   delete of the worktrees teardown renamed aside (issue #586)
#
#   Serialization with base-movers is the SHARED per-repo land-lease INSIDE
#   fleet-cleanup.sh (base fast-forward) — this daemon's own lease only stops two
#   cleanup ticks from double-driving one repo. Idempotent: a PR whose worktree +
#   window are already gone short-circuits (skip:nothing) inside fleet-cleanup.sh.
#
# EVERY CANDIDATE RUNS UNDER A WALL-CLOCK BUDGET (issue #587). This daemon is a
# single process on StartInterval=60: launchd starts no new tick while the old one
# is alive, so one wedged candidate does not slow this fleet down — it stops the
# cleanup of EVERY fleet behind it. On 2026-09-13 a tick sat 67 MINUTES inside one
# fleet-cleanup.sh call and froze all three fleets' pipelines. fleet-cleanup.sh has
# several calls that can block indefinitely (gh pr view, git pull --ff-only, the
# land-lease queue), and hardening them one at a time never covers the next one, so
# the budget goes HERE, around the whole call. A timed-out candidate is killed tree
# and all, logged, and skipped; the tick moves on to the next one.
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
#   FLEET_CLEANUP_CANDIDATE_TIMEOUT  per-candidate budget, seconds   (default 120)
#   FLEET_CLEANUP_SCRATCH_HEADS 1 = ALSO consider a MERGED PR whose head is not
#                              issue-<N> (a scratch that grew into a PR); the
#                              strict gate lives in fleet-cleanup.sh (default 0/off)
#   FLEET_CLEANUP_LEASE_TTL    lease lifetime, seconds              (default 300)
#   FLEET_DISPATCH_LEASE_DIR   lease dir (shared)    (default ~/.claude/leases)
#   FLEET_TRASH_SWEEP_BUDGET   seconds/tick spent deleting trashed worktrees
#                              (default 20; 0 disables the sweep). Read ONCE, before
#                              any per-fleet conf — global fleet.conf / env only.
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

# --- FINAL PRs worth a cleanup attempt, from the prmap cache -------------------
# prmap row: branch<TAB>#num<TAB>state<TAB>ci<TAB>ready. Prints "num<TAB>branch":
#   * an issue-<N> head, MERGED or CLOSED — the historic candidate set;
#   * ANY OTHER head, MERGED only, when FLEET_CLEANUP_SCRATCH_HEADS=1 (issue #589).
# CLOSED stays issue-only on purpose: a closed-UNMERGED scratch PR abandoned work
# that is still sitting in its worktree, and #543/#544 exists to keep exactly that.
final_prs() { # $1 = prmap file, $2 = 1 when non-issue heads are armed
  local prmf="$1" scratch="${2:-0}"
  [ -s "$prmf" ] || return 0
  awk -F'\t' -v scratch="$scratch" '
    $1 == "" { next }
    ($3=="MERGED" || $3=="CLOSED") && $1 ~ /^issue-[0-9]+$/ {
      n=$2; sub(/^#/,"",n); print n "\t" $1; next
    }
    scratch=="1" && $3=="MERGED" && $1 !~ /^issue-[0-9]+$/ {
      n=$2; sub(/^#/,"",n); print n "\t" $1
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

  # Per-candidate wall-clock budget. A timed-out candidate spends a SLOT (not just
  # its own budget), so a tick is bounded by k * timeout no matter how many sick
  # candidates the prmap holds — the point of the exercise is that the NEXT tick
  # starts on time. An explicit 0 disables the budget (the pre-#587 behaviour); a
  # non-numeric value is a typo, not a request to disable, so it falls back to 120.
  cto="${FLEET_CLEANUP_CANDIDATE_TIMEOUT:-120}"
  case "$cto" in ''|*[!0-9]*) cto=120 ;; esac

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

  # Collect the live BRANCHES ONCE (local, zero gh) — a PR is a cleanup candidate
  # only if its head still has debris to reap. Keyed by branch name rather than by
  # issue number since #589, so one set serves an issue-<N> head and a scratch head
  # alike: every checked-out worktree branch, plus the issue-<N> a live window
  # binds via @issue (identity, cwd-independent — issue #353).
  live=$'\n'
  while IFS= read -r b; do [ -n "$b" ] && live="${live}${b}"$'\n'; done < <(
    git -C "$main" worktree list --porcelain 2>/dev/null | \
      sed -n 's#^branch refs/heads/##p'
    ftmux list-windows -t "$sess" -F '#{@issue}' 2>/dev/null | \
      sed 's/[^0-9]//g' | sed -n 's/^[0-9][0-9]*$/issue-&/p'
  )

  cleaned=0; considered=0; timedout=0
  while IFS=$'\t' read -r pr branch; do
    [ -z "$pr" ] && continue
    # live worktree or window for this head branch?
    case "$live" in *$'\n'"$branch"$'\n'*) : ;; *) continue ;; esac

    # A NON-issue head (issue #589): the authoritative gate is in fleet-cleanup.sh,
    # but reaching it costs a `gh pr view` EVERY tick. A scratch window is routinely
    # the operator's own workbench and can sit MERGED-but-busy for hours, so
    # pre-screen with the same LOCAL signal (zero gh) and spend the gh call only on
    # a worktree whose window says it is `done`. A worktree with NO live window in
    # it is not ours either — that one is worktree-autoclean.sh's.
    case "$branch" in
      issue-[0-9]*) : ;;
      *) wt=$(fleet_worktree_head "$main" "$branch" | cut -f1)
         [ -n "$wt" ] || continue
         ws=$(fleet_wt_window "$sess" "$wt" | cut -f2)
         if [ "$ws" != "done" ]; then
           log "$sess: PR #$pr ($branch) — its window is '${ws:-none}', not done; leaving it alone"
           continue
         fi ;;
    esac
    considered=$((considered + 1))

    if [ "$DRY" = 1 ]; then
      log "$sess: would clean PR #$pr ($branch)  [slot $((cleaned + 1))/$k]"
      cleaned=$((cleaned + 1))
      [ "$cleaned" -ge "$k" ] && break
      continue
    fi

    # Drive the shared mechanical janitor. Its ONE stdout line is the result token;
    # its progress notes go to stderr → this daemon's log. Pass FLEET_SESSION so it
    # resolves THIS fleet's repo/main/socket (it has no $TMUX) — via `env`, because
    # fleet_timebox runs its argv directly (no eval, so no VAR=val prefix).
    tok=$(fleet_timebox "$cto" env FLEET_SESSION="$sess" bash "$BIN/fleet-cleanup.sh" "$pr")
    rc=$?
    if [ "$rc" = 124 ]; then
      # fleet_timebox TERMs the whole TREE, then KILLs the survivors a second later:
      # fleet-cleanup.sh blocked in a child (gh, git) only reaches its own TERM trap
      # once that child dies, and that trap is what releases the shared land lease.
      # Whatever it still misses is steal-if-stale. The candidate keeps its debris
      # and is re-tried next tick — a slot spent, not a pipeline stalled.
      timedout=$((timedout + 1))
      log "$sess: PR #$pr ($branch) — timeout after ${cto}s (FLEET_CLEANUP_CANDIDATE_TIMEOUT) — killed, next candidate  [slot $((cleaned + timedout))/$k]"
      [ "$((cleaned + timedout))" -ge "$k" ] && break
      continue
    fi
    case "$tok" in
      cleaned:*) log "$sess: $tok  (PR #$pr, $branch)  [slot $((cleaned + timedout + 1))/$k]"; cleaned=$((cleaned + 1)) ;;
      skip:*)    log "$sess: PR #$pr ($branch) — $tok (nothing reaped)" ;;
      error:*)   log "$sess: PR #$pr cleanup error ($tok)" ;;
      *)         log "$sess: PR #$pr cleanup returned rc=$rc token='${tok:-none}'" ;;
    esac
    [ "$((cleaned + timedout))" -ge "$k" ] && break
  done <<EOF
$(final_prs "$prmf" "${FLEET_CLEANUP_SCRATCH_HEADS:-0}")
EOF

  to_note=""
  [ "$timedout" -gt 0 ] && to_note=", $timedout timed out (${cto}s each)"
  if [ "$considered" -eq 0 ]; then
    log "$sess: no MERGED/CLOSED PRs with leftover worktree/window in the prmap cache"
  elif [ "$cleaned" -eq 0 ]; then
    log "$sess: nothing reaped (all candidates already clean$to_note)"
  else
    log "$sess: reaped $cleaned PR(s) (cap/tick=$k$to_note)"
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

# --- pay for the trashed worktrees FIRST, before the disk gate (issue #586) -----
# A teardown no longer deletes a worktree inline: fleet_worktree_drop RENAMES it into
# a sibling .fleet-trash/ (O(1)) so a 308k-file node_modules tree cannot hold a tick
# for 67 minutes and stall the reaping of every fleet behind it. THIS is where those
# bytes are actually paid for — in one budgeted instalment per tick, shared across
# every fleet (distinct base checkouts only; two sessions on one repo share a trash).
# Whatever the budget does not finish stays half-deleted in the trash for the next
# tick, which is harmless: it is already out of `git worktree list` and nothing waits
# on it.
#
# It runs BEFORE the disk gate on purpose. A closed gate means the volume is full,
# and emptying the trash is exactly what unsticks it — gating the sweep on free disk
# would be the one ordering that can deadlock.
SWEEP_BUDGET="${FLEET_TRASH_SWEEP_BUDGET:-20}"
case "$SWEEP_BUDGET" in ''|*[!0-9]*) SWEEP_BUDGET=20 ;; esac
if [ "$DRY" = 0 ] && [ "$SWEEP_BUDGET" -gt 0 ]; then
  sweep_deadline=$(( $(now) + SWEEP_BUDGET ))
  swept_mains=""
  for s in "${SESSIONS[@]}"; do
    # A subshell read: fleet_load_conf in THIS shell would leak one fleet's conf
    # into the next one's cleanup.
    m=$(fleet_load_conf "$s" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}")
    [ -n "$m" ] || continue
    case " $swept_mains " in *" $m "*) continue ;; esac
    swept_mains="$swept_mains $m"
    budget_left=$(( sweep_deadline - $(now) ))
    [ "$budget_left" -gt 0 ] || break
    sweep=$(fleet_trash_sweep "$m" "$budget_left")
    case "$sweep" in "swept:0 left:0") ;; *) log "$s: worktree trash $sweep ($m)" ;; esac
  done
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
