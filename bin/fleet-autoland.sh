#!/bin/bash
# fleet-autoland.sh [--dry-run] [session...] — the AUTO-LAND daemon (issue #233).
#
# Lands landable-green PRs HANDS-OFF for each opt-in fleet — no steward turn, no
# human. It is the last automation in the lifecycle the dispatcher (spawn) and the
# watcher (wake) already automate: instead of the steward watching for a green PR
# and running /fleet-land, this daemon drives the SAME mechanical lander
# (bin/fleet-land.sh) the moment a PR shows up landable in the prmap cache.
#
# ⚠️ APPROVAL-GATE RELAXATION. Auto-land REMOVES the human "is the work complete?"
# gate — CI green + branch protection become the ONLY gate. So, like FLEET_AUTOFILL
# and FLEET_SELF_LAND, it is OFF BY DEFAULT and opt-in per fleet (FLEET_AUTOLAND=1),
# and it is a DELIBERATE relaxation of the "a human approves the land" rail. Bound
# what it can land with the optional label scope guard (FLEET_AUTOLAND_LABEL) so a
# fleet only auto-lands PRs it explicitly marked ready-to-auto-land. See docs/AUTOLAND.md.
#
# Design (per issue #233, mirrors fleet-dispatch.sh / fleet-watch.sh):
#   for each live fleet session (or the ones named on argv):
#     load its conf; skip unless FLEET_AUTOLAND=1
#     acquire a per-REPO LEASE (mkdir, steal-if-stale)      → single-writer
#     honor the diskguard GATE (fleet-diskguard.sh --gate)  → never land on a full disk
#     read the prmap_<slug> cache pr-refresh already writes  → ZERO extra gh
#     landable = its OPEN PRs whose `ready` column == "ready" (green + mergeable now)
#     [optional] keep only those whose bound issue carries FLEET_AUTOLAND_LABEL
#     land up to FLEET_AUTOLAND_MAX_PER_TICK of them via bin/fleet-land.sh <pr>
#     release the lease
#
#   Serialization with the OTHER landers (dash ⌃l, /fleet-land, self-land, land-train)
#   is the SHARED per-repo land-lease inside fleet-land.sh — this daemon's own lease is
#   only to stop two autoland ticks from double-driving one repo. fleet-land NEVER
#   forces: a PR that has drifted to conflict/behind/failing/blocked/draft since the
#   cache was written is EJECTED (not merged), and this daemon just logs the eject and
#   leaves it for the steward. Idempotent: an already-merged PR short-circuits.
#
# DETECTION IS CACHE-ONLY. We read prmap_<slug> (branch<TAB>#num<TAB>state<TAB>ci<TAB>ready)
# — the same file the dash + watcher read — so a tick that lands nothing costs a few
# file reads, no gh. Only fleet-land.sh talks to gh (one merge per landed PR). We land
# only `ready` rows in v1: `behind`/`conflict`/`blocked` are left to the steward (a
# `behind` PR is auto-resolvable via update-branch, but v1 keeps the surface minimal).
#
# Env knobs (all per-fleet, in $FLEET_CONF_DIR/<session>.conf or global fleet.conf):
#   FLEET_AUTOLAND              1 to enable for this fleet          (default 0/off)
#   FLEET_AUTOLAND_MAX_PER_TICK max PRs landed per fleet per tick   (default 1)
#   FLEET_AUTOLAND_LABEL        only land PRs whose issue has this label (default none)
#   FLEET_AUTOLAND_LEASE_TTL    lease lifetime, seconds             (default 300)
#   FLEET_DISPATCH_LEASE_DIR    lease dir (shared)    (default ~/.claude/leases)
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
    -*)           printf 'fleet-autoland: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)            ARGV_SESS+=("$1") ;;
  esac
  shift
done

LEASE_TTL="${FLEET_AUTOLAND_LEASE_TTL:-300}"
LEASE_DIR="${FLEET_DISPATCH_LEASE_DIR:-$HOME/.claude/leases}"

# All progress goes to stderr — a daemon's stdout is /dev/null; stderr is the log.
now() { date +%s 2>/dev/null || echo 0; }
log() { printf '%s fleet-autoland: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# --- per-repo lease (single-writer; steal-if-stale). Mirrors fleet-dispatch.sh. ---
# The holder id ($2) is a fully-defaulted string (never bare $USER, which is unset in
# a launchd/systemd daemon env and would abort under `set -u`).
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
# Release ONLY if we still hold it: an autolander that overran its TTL and had its
# lease stolen must not delete the thief's freshly-minted lease on EXIT.
# shellcheck disable=SC2329  # invoked indirectly via the `trap '…' EXIT` below
lease_release() { # $1 = lease path, $2 = my holder id
  [ "$(sed -n 1p "$1/holder" 2>/dev/null)" = "$2" ] && rm -rf "$1" 2>/dev/null
  return 0
}

# --- landable PRs from the prmap cache -----------------------------------------
# prmap row: branch<TAB>#num<TAB>state<TAB>ci<TAB>ready. A row is LANDABLE when its
# PR is OPEN and its `ready` column (pr-refresh's mergeability verdict from
# mergeStateStatus/mergeable, only ever set for a CI-green PR) is exactly "ready" —
# i.e. green AND up-to-date AND mergeable NOW. behind/conflict/blocked/"" are NOT
# auto-landed in v1 (left to the steward). Prints "num<TAB>branch" per landable row.
landable_prs() { # $1 = prmap file
  local prmf="$1"
  [ -s "$prmf" ] || return 0
  awk -F'\t' '$3=="OPEN" && $5=="ready" { n=$2; sub(/^#/,"",n); print n "\t" $1 }' \
    "$prmf" 2>/dev/null
}

# The labels the issues/labels cache holds for one issue number (comma-joined), or
# empty. Zero gh — reads the labels_<slug> cache the collector already writes.
labels_for_issue() { # $1 = labels file, $2 = issue number
  awk -F'\t' -v x="$2" '$1==x{print $2; exit}' "$1" 2>/dev/null
}

# --- autoland ONE fleet. Runs in a subshell so its per-fleet conf never leaks. ---
autoland_fleet() { (
  sess="$1"
  fleet_load_conf "$sess"
  if [ "${FLEET_AUTOLAND:-0}" != 1 ]; then
    log "$sess: autoland off (FLEET_AUTOLAND≠1) — skip"
    exit 0
  fi

  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && repo="$_r"
  [ -z "$repo" ] && { log "$sess: no repo resolved — skip"; exit 0; }
  command -v gh >/dev/null 2>&1 || { log "$sess: gh not on PATH — skip"; exit 0; }
  slug=$(fleet_slug "$(fleet_norm_repo "$repo")")

  # Rate-limit: at most K lands this tick (the 60s interval is the cooldown). 0 → skip.
  k="${FLEET_AUTOLAND_MAX_PER_TICK:-1}"
  case "$k" in ''|*[!0-9]*) k=1;; esac
  if [ "$k" -le 0 ]; then
    log "$sess: per-tick cap is 0 (FLEET_AUTOLAND_MAX_PER_TICK) — skip"
    exit 0
  fi

  # Single-writer per REPO: two sessions serving one repo don't double-drive a land.
  # The holder id is fully defaulted (sess is always set) — never bare $USER.
  lease="$LEASE_DIR/autoland-$slug.lock"
  me="autoland:$sess:$$@$(hostname -s 2>/dev/null || echo host)"
  if [ "$DRY" = 0 ]; then
    lease_acquire "$lease" "$me" || { log "$sess: another autolander holds the lease — skip"; exit 0; }
    trap 'lease_release "$lease" "$me"' EXIT
  fi

  # Detection is cache-only: the prmap pr-refresh already writes (ZERO extra gh).
  prmf=$(fleet_cache prmap "$sess")
  if [ ! -s "$prmf" ]; then
    log "$sess: no prmap cache yet (pr-refresh hasn't run for $slug?) — skip"
    exit 0
  fi

  # Optional label scope guard: only land PRs whose bound issue carries the label.
  label="${FLEET_AUTOLAND_LABEL:-}"
  labf=''
  [ -n "$label" ] && labf=$(fleet_cache labels "$sess")

  landed=0; considered=0
  while IFS=$'\t' read -r pr branch; do
    [ -z "$pr" ] && continue
    considered=$((considered + 1))

    # Label scope guard (FAIL-CLOSED): only auto-land a PR whose bound issue carries
    # FLEET_AUTOLAND_LABEL. Derive the issue from the issue-<N> head; a non-issue head
    # or a labels cache we can't read means we CAN'T prove the gate → skip (never land
    # what we can't verify is in scope). No gh — the label comes from the cache.
    if [ -n "$label" ]; then
      case "$branch" in
        issue-[0-9]*) iss="${branch#issue-}"; iss="${iss%%[!0-9]*}" ;;
        *) iss='' ;;
      esac
      if [ -z "$iss" ]; then
        log "$sess: skip PR #$pr — label gate '$label' on, head '$branch' has no issue-<N>"
        continue
      fi
      if [ ! -s "$labf" ]; then
        log "$sess: skip PR #$pr (#$iss) — label gate '$label' on but labels cache missing"
        continue
      fi
      case ",$(labels_for_issue "$labf" "$iss")," in
        *,"$label",*) : ;;                                       # carries the gate → eligible
        *) log "$sess: skip PR #$pr (#$iss) — missing gate label '$label'"; continue ;;
      esac
    fi

    if [ "$DRY" = 1 ]; then
      log "$sess: would land PR #$pr (branch $branch)  [slot $((landed + 1))/$k]"
      landed=$((landed + 1))
      [ "$landed" -ge "$k" ] && break
      continue
    fi

    # Drive the shared mechanical lander. Its ONE stdout line is the result token;
    # its progress notes go to stderr, which flows through to our daemon log. Pass
    # FLEET_SESSION so it resolves THIS fleet's repo/main/socket (it has no $TMUX).
    tok=$(FLEET_SESSION="$sess" bash "$BIN/fleet-land.sh" "$pr")
    rc=$?
    case "$tok" in
      landed:*) log "$sess: $tok  (PR #$pr)  [slot $((landed + 1))/$k]"; landed=$((landed + 1)) ;;
      eject:*)  log "$sess: PR #$pr not landed ($tok) — leaving for the steward" ;;
      error:*)  log "$sess: PR #$pr land error ($tok)" ;;
      *)        log "$sess: PR #$pr land returned rc=$rc token='${tok:-none}'" ;;
    esac
    [ "$landed" -ge "$k" ] && break
  done <<EOF
$(landable_prs "$prmf")
EOF

  if [ "$considered" -eq 0 ]; then
    log "$sess: no landable (ready) PRs in the prmap cache"
  elif [ "$landed" -eq 0 ]; then
    log "$sess: nothing landed (all ready PRs gated out or ejected on re-check)"
  else
    log "$sess: landed $landed PR(s) (cap/tick=$k)"
  fi
) }

# --- which fleets? argv wins; else every live fleet session on this server. -----
SESSIONS=()
if [ "${#ARGV_SESS[@]}" -gt 0 ]; then
  SESSIONS=("${ARGV_SESS[@]}")
else
  # A fleet session owns a 'plan' or 'dash' hub window (same rule the dispatcher +
  # watcher use). fleet_hub_sessions fans this out across every live fleet socket.
  while IFS= read -r s; do
    [ -n "$s" ] && SESSIONS+=("$s")
  done < <(fleet_hub_sessions | sort)
fi

if [ "${#SESSIONS[@]}" -eq 0 ]; then
  log "no fleet sessions found (nothing to auto-land)"
  exit 0
fi

# Diskguard gate is a MACHINE-WIDE (per-volume) condition, so answer it ONCE per
# tick — not once per fleet. A land does a base-checkout pull + worktree teardown;
# don't add that I/O below the floor (that is the crash-loop guard). Mirrors
# fleet-dispatch.sh / fleet-watch.sh.
if [ "$DRY" = 0 ] && [ -x "$BIN/fleet-diskguard.sh" ] \
   && ! "$BIN/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
  log "disk gate closed — skipping all fleets this tick"
  exit 0
fi

for s in "${SESSIONS[@]}"; do
  autoland_fleet "$s"
done
exit 0
