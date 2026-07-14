#!/bin/bash
# fleet-base-sync.sh [--dry-run] [session...] — the BASE-SYNC daemon
# (com.claude-fleet.base-sync, ~60s; issue #327).
#
# Keeps each fleet's LOCAL BASE checkout ($FLEET_MAIN) fast-forwarded to the
# remote default branch — INDEPENDENT of merges. Today the base only advances as
# a SIDE-EFFECT of reaping a merged PR: bin/fleet-cleanup.sh does the
# `git pull --ff-only` under the shared land lease, but ONLY when a merged PR
# still has a local issue-<N> worktree/window to reap. So a merge with no local
# reap — a PR merged on the web, a commit from another machine/contributor, a
# direct push to the default branch — never triggers a base pull, and the local
# base SILENTLY LAGS the remote until the next merge that does have a worktree.
# Fresh worktrees + `cw` then branch off a STALE base. This daemon closes that
# gap with a dedicated, merge-independent ff-only sync ticker.
#
# It is the EXACT ff-only pull the cleaner already performs, just triggered by
# the clock instead of by a reap. It reuses the same machinery, so there is no
# new race:
#   - one base-mover PER REPO, not per fleet — two fleets on one repo share one
#     base checkout, so we dedup on the RESOLVED base path and move it once;
#   - the SHARED land lease (bin/fleet-land-lease.sh, land-<slug>.lock) — the
#     SAME lock every base-mover holds — serializes us against the cleanup
#     daemon's fast-forward. We take it NON-BLOCKING: if a cleaner (or another
#     base-syncer) already holds it, the base is already being advanced, so we
#     skip this tick rather than queue.
#
# Each mover tick: `git -C $FLEET_MAIN fetch origin $BASE` + `git pull --ff-only`.
# `--ff-only` IS the whole safety story: if the local base diverged (someone
# committed to the base checkout — which the read-only hook already forbids, but
# defense-in-depth), the pull refuses; we surface it once like fleet-cleanup.sh
# ("base checkout would not fast-forward — resolve by hand") and move on. Never
# merge, never rebase, never force. An already-current base is a cheap no-op, so
# a quiet repo costs one `fetch` per tick and nothing else.
#
# BASE ONLY. It never touches worktrees, windows, branches, issues, or PRs —
# pure `fetch` + `pull --ff-only` on $FLEET_MAIN. Runs OUTSIDE any session (a
# daemon, no $TMUX), so it needs no tmux at all: just git + the lease. It fans
# out over live fleets like the cleanup/ledger daemons but the tmux socket is
# only used (via fleet_hub_sessions) to DISCOVER which fleets are up.
#
# ON BY DEFAULT for every fleet, like the collector — cost is one `fetch`/tick,
# no gh, no LLM (opt out per fleet with FLEET_BASE_SYNC=0). `--dry-run` prints
# "would ff $MAIN <old>..<new>" without moving the base (it fetches to learn the
# remote tip but never pulls, takes no lease, and bypasses the disk gate).
#
# Env knobs (all per-fleet, in $FLEET_CONF_DIR/<session>.conf or global fleet.conf):
#   FLEET_BASE_SYNC             0 to disable for this fleet          (default 1/on)
#   FLEET_BASE_SYNC_LEASE_TTL   land-lease lifetime, seconds         (default 120)
#   FLEET_LAND_LEASE_DIR        SHARED land-lease dir (with the cleaner + landers)
#                                                     (default ~/.claude/leases)
#   LAND_LEASE_DIR             per-tool override of the lease dir (tests)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

DRY=0
ARGV_SESS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           printf 'fleet-base-sync: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)            ARGV_SESS+=("$1") ;;
  esac
  shift
done

LEASE_TTL="${FLEET_BASE_SYNC_LEASE_TTL:-120}"
# The SHARED land-lease dir — resolve it EXACTLY like fleet-cleanup.sh so this
# daemon and the cleaner contend for the SAME land-<slug>.lock in production.
LEASE_DIR="${LAND_LEASE_DIR:-${FLEET_LAND_LEASE_DIR:-$HOME/.claude/leases}}"

# All progress goes to stderr — a daemon's stdout is /dev/null; stderr is the log.
log() { printf '%s fleet-base-sync: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# --- extract ONE fleet's base identity (subshelled so its conf never leaks into
# the discovery loop). Prints TSV: on-flag \t repo \t main \t base-branch.
fleet_ident() { (
  fleet_load_conf "$1"
  off="${FLEET_BASE_SYNC:-1}"
  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$1"); [ -n "$_r" ] && repo="$_r"
  printf '%s\t%s\t%s\t%s\n' "$off" "$repo" "${FLEET_MAIN:-}" "${FLEET_BASE_BRANCH:-master}"
) }

# --- move ONE repo's base. Runs in a subshell so its lease trap is scoped to the
# single mover (never leaks across the discovery loop). No conf is sourced here.
sync_repo() { (
  sess="$1"; repo="$2"; main="$3"; base="$4"; slug="$5"
  lease="$LEASE_DIR/land-$slug.lock"
  old=$(git -C "$main" rev-parse --short HEAD 2>/dev/null)

  # DRY-RUN: fetch to learn the remote tip (read-only w.r.t. the base branch —
  # it moves only FETCH_HEAD / remote-tracking refs), report, take no lease, and
  # never pull. This previews EXACTLY what a real tick would fast-forward.
  if [ "$DRY" = 1 ]; then
    if ! git -C "$main" fetch origin "$base" --quiet 2>/dev/null; then
      log "$sess: fetch failed for $repo ($base) — skip (dry-run)"; exit 0
    fi
    new=$(git -C "$main" rev-parse --short FETCH_HEAD 2>/dev/null)
    if [ -z "$new" ] || [ "$new" = "$old" ]; then
      log "$sess: base $main already current at ${old:-?} (dry-run)"
    else
      log "$sess: would ff $main ${old:-?}..$new (dry-run)"
    fi
    exit 0
  fi

  # Shared land lease — the SAME lock every base-mover holds. NON-BLOCKING: if a
  # cleaner (or another base-syncer) holds it, the base is already being advanced
  # under it, so skip this tick instead of queueing behind it.
  if ! land_lease_acquire "$lease" "$LEASE_TTL" "base-sync:$sess:$$@$(land_lease_host)"; then
    log "$sess: land lease busy (held by $(land_lease_holder "$lease")) — another base-mover has $repo, skip"
    exit 0
  fi
  # shellcheck disable=SC2329  # invoked via the EXIT/INT/TERM traps below
  drop_lease() { land_lease_release "$lease"; }
  trap drop_lease EXIT
  trap 'drop_lease; exit 130' INT
  trap 'drop_lease; exit 143' TERM

  git -C "$main" fetch origin "$base" --quiet 2>/dev/null
  if git -C "$main" pull --ff-only >/dev/null 2>&1; then
    new=$(git -C "$main" rev-parse --short HEAD 2>/dev/null)
    if [ "$new" = "$old" ]; then
      log "$sess: base $main already current at ${old:-?}"
    else
      log "$sess: ff $main ${old:-?}..${new:-?}"
    fi
  else
    log "$sess: base checkout $main would not fast-forward — resolve it by hand (something diverged locally)."
  fi
  land_lease_release "$lease"
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
  log "no fleet sessions found (nothing to sync)"
  exit 0
fi

command -v git >/dev/null 2>&1 || { log "git not on PATH — nothing to sync"; exit 0; }

# Diskguard gate is a MACHINE-WIDE (per-volume) condition, so answer it ONCE per
# tick. A fetch + ff pull is trivial I/O, but don't add even that below the floor.
# Mirrors the other single-writer, disk-gated fleet daemons.
if [ "$DRY" = 0 ] && [ -x "$BIN/fleet-diskguard.sh" ] \
   && ! "$BIN/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
  log "disk gate closed — skipping all fleets this tick"
  exit 0
fi

# One base-mover PER REPO: dedup on the RESOLVED base path so two fleets serving
# the same repo (one shared base checkout) never double-move it in a tick.
synced=$'\n'
for sess in "${SESSIONS[@]}"; do
  IFS=$'\t' read -r off repo main base < <(fleet_ident "$sess")
  if [ "$off" = 0 ]; then
    log "$sess: base-sync off (FLEET_BASE_SYNC=0) — skip"
    continue
  fi
  [ -z "$repo" ] && { log "$sess: no repo resolved — skip"; continue; }
  [ -d "$main/.git" ] || { log "$sess: FLEET_MAIN is not a git checkout — skip"; continue; }
  cmain=$(cd "$main" 2>/dev/null && pwd -P); [ -z "$cmain" ] && cmain="$main"
  case "$synced" in
    *$'\n'"$cmain"$'\n'*)
      log "$sess: base $cmain already synced this tick (same repo as an earlier fleet) — skip"
      continue ;;
  esac
  synced="${synced}${cmain}"$'\n'
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")
  sync_repo "$sess" "$repo" "$main" "$base" "$slug"
done
exit 0
