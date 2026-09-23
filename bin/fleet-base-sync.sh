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
# a quiet repo costs one `fetch` per tick and nothing else. A base checkout that
# is not ON $BASE (a side branch, a detached HEAD) is never pulled at all — the
# pull would follow the wrong branch and report "already current" forever; the
# tick logs "base … is on <branch>, not <base> — not syncing" instead (#1044).
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
#   FLEET_BASE_DEPS             1 = after each tick, reinstall base dirs whose
#                               lockfile moved (fleet-deps-link.sh --refresh-base);
#                               unset = on iff FLEET_WORKTREE_SETUP is fleet-deps-link
#                               (fleet_base_deps_on, issue #961); 0 = off
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# --- scheduling heartbeat (issue #639) ---------------------------------------
# Stamped at the TOP, before any early exit, so "launchd never spawned me" stays
# distinguishable from "I ran and had nothing to do" — a conf-gated tick that
# exits immediately still proves it was scheduled. bin/fleet-daemon-watch.sh
# alarms on, and kicks, a unit whose stamp ages past FLEET_DAEMON_STALE_MULT ×
# this unit's StartInterval; without it, a pended unit is silent (issue #639:
# launchd stopped scheduling EVERY interval unit in this user domain and the only
# daemon anyone noticed was the one collector heartbeat #638 had instrumented).
# The source is GUARDED and the stamp is a side errand: liveness instrumentation
# must never be able to kill the daemon it instruments. A half-synced install
# missing the lib then costs this unit its alarm (it reads `never`, which is
# silent by design) instead of costing the fleet the daemon.
# shellcheck source=/dev/null
[ -f "$BIN/fleet-daemon-lib.sh" ] && { . "$BIN/fleet-daemon-lib.sh"
  fleet_daemon_stamp_tick base-sync "$BIN/.."; }

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

DRY=0
ARGV_SESS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# --- extract ONE fleet's base identities (subshelled so its conf never leaks into
# the discovery loop). Prints TSV: on-flag \t repo \t main \t base-branch \t deps
# — one row, or in a multi-repo fleet one row PER HOSTED REPO, each read through
# that repo's overlay (issue #978): its own base checkout, and its own
# FLEET_WORKTREE_SETUP / FLEET_BASE_DEPS deciding whether its deps are refreshed.
fleet_ident() { (
  fleet_load_conf "$1"
  if fleet_has_repo_overlays "$1"; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      ( fleet_load_repo_conf "$1" "$r" || exit 0
        deps=0; fleet_base_deps_on && deps=1
        printf '%s\t%s\t%s\t%s\t%s\n' "${FLEET_BASE_SYNC:-1}" "$r" "${FLEET_MAIN:-}" "${FLEET_BASE_BRANCH:-master}" "$deps" )
    done <<EOF
$(fleet_repos "$1")
EOF
    exit 0
  fi
  off="${FLEET_BASE_SYNC:-1}"
  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$1"); [ -n "$_r" ] && repo="$_r"
  deps=0; fleet_base_deps_on && deps=1
  printf '%s\t%s\t%s\t%s\t%s\n' "$off" "$repo" "${FLEET_MAIN:-}" "${FLEET_BASE_BRANCH:-master}" "$deps"
) }

# --- move ONE repo's base. Runs in a subshell so its lease trap is scoped to the
# single mover (never leaks across the discovery loop). No conf is sourced here.
sync_repo() { (
  sess="$1"; repo="$2"; main="$3"; base="$4"; slug="$5"; deps="${6:-0}"
  lease="$LEASE_DIR/land-$slug.lock"
  old=$(git -C "$main" rev-parse --short HEAD 2>/dev/null)

  # WRONG BRANCH (issue #1044): `pull --ff-only` follows whatever is checked out,
  # so a base left on a side branch is level with its OWN upstream and would read
  # "already current" every tick while $base runs away. Never pull it — fetch only
  # (keeps origin/$base current, so the behind count here and in the doctor is
  # real), say so, and leave the checkout to the operator. The deps refresh below
  # still runs against the tree that IS checked out; the doctor flags it.
  if cur=$(fleet_base_off_branch "$main" "$base"); then
    git -C "$main" fetch origin "$base" --quiet 2>/dev/null
    behind=$(git -C "$main" rev-list --count "HEAD..refs/remotes/origin/$base" 2>/dev/null)
    log "$sess: base $main is on $cur, not $base${behind:+ ($behind behind origin/$base)} — not syncing; git -C $main checkout $base"
    [ "$DRY" = 1 ] && exit 0
  else
    # DRY-RUN: fetch to learn the remote tip (read-only w.r.t. the base branch —
    # it moves only FETCH_HEAD / remote-tracking refs), report, take no lease, and
    # never pull. This previews EXACTLY what a real tick would fast-forward.
    if [ "$DRY" = 1 ]; then
      [ "$deps" = 1 ] && log "$sess: would keep $main's shared deps current (dry-run)"
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
  fi

  # Shared deps (issue #961): the base's node_modules must follow its lockfiles, or
  # every worktree fleet-deps-link points at it borrows a stale tree. Reinstall what
  # this ff changed (old..HEAD) plus anything still stale from an earlier move — a
  # cleaner's ff, a failed or killed install. AFTER the lease: an install can take
  # minutes and must not hold the cleaner off the base. Never affects the ff.
  if [ "$deps" = 1 ] && [ -x "$BIN/fleet-deps-link.sh" ]; then
    "$BIN/fleet-deps-link.sh" --refresh-base "$main" ${old:+"$old"} ${old:+HEAD} 2>/dev/null \
      | while IFS= read -r l; do log "$sess: deps $l"; done
  fi
) }

# --- which fleets? argv wins; else every live fleet session on this server. -----
SESSIONS=()
if [ "${#ARGV_SESS[@]}" -gt 0 ]; then
  SESSIONS=(${ARGV_SESS[@]+"${ARGV_SESS[@]}"})
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
for sess in ${SESSIONS[@]+"${SESSIONS[@]}"}; do
  while IFS=$'\t' read -r off repo main base deps; do
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
    sync_repo "$sess" "$repo" "$main" "$base" "$slug" "$deps" </dev/null
  done < <(fleet_ident "$sess")
done
exit 0
