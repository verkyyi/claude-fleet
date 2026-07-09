#!/bin/bash
# fleet-dispatch.sh [--dry-run] [session...] — the AUTOFILL dispatcher (issue #70).
#
# Keeps each opt-in fleet's worker slots filled FROM ITS BACKLOG, BY PRIORITY,
# whenever capacity exists under BOTH caps — automating the manual "file issue →
# hold for cap → spawn when a slot frees" loop the steward does today. Run as an
# interval daemon (com.claude-fleet.dispatch, ~60s) or by hand for one fleet.
#
# OFF BY DEFAULT. A fleet auto-spawns only when its conf sets FLEET_AUTOFILL=1.
# Auto-spawning launches real Claude sessions that spend LLM tokens — it is
# aggressive, so it must be explicitly enabled per fleet.
#
# Design (per issue #70):
#   for each live fleet session (or the ones named on argv):
#     load its conf; skip unless FLEET_AUTOFILL=1
#     acquire a per-fleet LEASE (mkdir, steal-if-stale)   → single-writer
#     honor the diskguard GATE (fleet-diskguard.sh --gate) → never fill a full disk
#     slots = min(global headroom, per-fleet headroom, MAX_PER_TICK)  → rate-limit
#     eligible = open, UNASSIGNED, not blocked/epic/meta, [ready-gated],
#                no live @issue window already bound                 → anti-collision
#     rank eligible by priority:p{0,1,2} tier then issue# (FIFO)      → priority
#     spawn the top `slots` via dash-issue-session.sh <N> <sess>      → reuse guards
#     release the lease
#
#   Idempotent: dash-issue-session.sh refuses a duplicate @issue window and
#   re-checks both caps, so even a raced double-run can't double-spawn. Every
#   decision is logged to stderr (→ the daemon's StandardErrorPath log).
#
# Priority signal: the `priority:p0|p1|p2` label tier (p0 highest); FIFO by issue
# number within a tier; unlabeled issues sort last (tier 3), still FIFO. This
# needs no schema — the labels are just GitHub labels the steward already sets.
#
# Anti-collision: /fleet-claim stakes BOTH a GitHub assignee AND a `▶ claiming` comment
# together, so "has any assignee" is the cheap proxy for "already owned" — one
# `gh issue list` call, no per-issue comment fetch. A live @issue window is the
# second guard (covers a just-spawned session before its /fleet-claim lands).
#
# Env knobs (all per-fleet, in $FLEET_CONF_DIR/<session>.conf or global fleet.conf):
#   FLEET_AUTOFILL              1 to enable for this fleet          (default 0/off)
#   FLEET_MAX_SESSIONS          per-fleet session ceiling           (default 0/unlimited)
#   FLEET_GLOBAL_MAX_SESSIONS   system-wide ceiling (shared)        (default 8)
#   FLEET_AUTOFILL_MAX_PER_TICK max spawns per fleet per tick       (default 1)
#   FLEET_AUTOFILL_READY_LABEL  require this label to be eligible   (default none)
#   FLEET_DISPATCH_LEASE_TTL    lease lifetime, seconds             (default 300)
#   FLEET_DISPATCH_LEASE_DIR    lease dir             (default ~/.claude/leases)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

DRY=0
ARGV_SESS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           printf 'fleet-dispatch: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)            ARGV_SESS+=("$1") ;;
  esac
  shift
done

LEASE_TTL="${FLEET_DISPATCH_LEASE_TTL:-300}"
LEASE_DIR="${FLEET_DISPATCH_LEASE_DIR:-$HOME/.claude/leases}"

# All progress goes to stderr — a daemon's stdout is /dev/null; stderr is the log.
log() { printf '%s fleet-dispatch: %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo '--:--:--')" "$*" >&2; }

# global headroom: FLEET_GLOBAL_MAX_SESSIONS - live sessions across ALL fleets.
# 0 (unlimited) → a large sentinel so it never bounds the min().
global_headroom() {
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}"
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac
  [ "$gmax" -eq 0 ] && { echo 9999; return; }
  echo $(( gmax - $(fleet_session_count) ))
}
# per-fleet headroom: FLEET_MAX_SESSIONS - live sessions in THIS fleet.
fleet_headroom() {
  local fmax="${FLEET_MAX_SESSIONS:-0}"
  case "$fmax" in ''|*[!0-9]*) fmax=0;; esac
  [ "$fmax" -eq 0 ] && { echo 9999; return; }
  echo $(( fmax - $(fleet_session_count_for "$1") ))
}

# Rank the eligible backlog: TSV "tier<TAB>number", priority tier then issue#.
# Excludes assigned / blocked / epic / meta; optionally requires the ready label.
# One `gh issue list` call; jq does all the filtering + tiering. gh's --jq has no
# --arg passthrough, so the ready label is spliced into the filter as a jq string
# literal — JSON-escaped (backslash + double-quote) so labels with spaces/parens/
# emoji match verbatim (a lossy strip would silently never match, or empty out the
# gate and hide the whole backlog). --limit is generous so FIFO isn't broken by a
# created-desc fetch dropping old (low-numbered, high-priority) issues at scale.
eligible_issues() {
  local repo="$1" ready="$2" gate='' esc
  if [ -n "$ready" ]; then
    esc=$(printf '%s' "$ready" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')  # jq string-literal escape
    # shellcheck disable=SC2016  # $l is a jq binding; only $esc is shell-expanded
    gate='| select($l|any(.=="'"$esc"'"))'
  fi
  # shellcheck disable=SC2016  # $l/$t are jq bindings, not shell expansions
  gh issue list --repo "$repo" --state open --limit 1000 \
    --json number,labels,assignees \
    --jq '.[]
      | select((.assignees|length)==0)
      | (.labels|map(.name)) as $l
      | select(($l|any(.=="epic" or .=="meta" or .=="blocked"))|not)
      '"$gate"'
      | ( if   ($l|any(.=="priority:p0")) then 0
          elif ($l|any(.=="priority:p1")) then 1
          elif ($l|any(.=="priority:p2")) then 2
          else 3 end ) as $t
      | "\($t)\t\(.number)"' 2>/dev/null \
    | sort -t"$(printf '\t')" -k1,1n -k2,2n
}

# --- per-fleet lease (single-writer; steal-if-stale). Mirrors land-train.sh. ---
# The holder id ($2) is passed in — a fully-defaulted string (never bare $USER,
# which is unset in a launchd/systemd daemon env and would abort under `set -u`).
lease_acquire() { # $1 = lease path, $2 = my holder id
  local lease="$1" me="$2" now exp holder
  mkdir -p "$LEASE_DIR" 2>/dev/null
  now=$(date +%s 2>/dev/null || echo 0)
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

# Release ONLY if we still hold it: a dispatcher that overran its TTL and had its
# lease stolen must not delete the thief's freshly-minted lease on EXIT.
# shellcheck disable=SC2329  # invoked indirectly via the `trap '…' EXIT` below
lease_release() { # $1 = lease path, $2 = my holder id
  [ "$(sed -n 1p "$1/holder" 2>/dev/null)" = "$2" ] && rm -rf "$1" 2>/dev/null
  return 0
}

# --- dispatch ONE fleet. Runs in a subshell so its per-fleet conf never leaks. --
dispatch_fleet() { (
  sess="$1"
  fleet_load_conf "$sess"
  if [ "${FLEET_AUTOFILL:-0}" != 1 ]; then
    log "$sess: autofill off (FLEET_AUTOFILL≠1) — skip"
    exit 0
  fi

  repo="${FLEET_REPO:-}"
  _r=$(fleet_repo_cached "$sess"); [ -n "$_r" ] && repo="$_r"
  [ -z "$repo" ] && { log "$sess: no repo resolved — skip"; exit 0; }
  command -v gh >/dev/null 2>&1 || { log "$sess: gh not on PATH — skip"; exit 0; }

  # Rate-limit: at most K spawns this tick (the 60s interval is the cooldown).
  k="${FLEET_AUTOFILL_MAX_PER_TICK:-1}"
  case "$k" in ''|*[!0-9]*) k=1;; esac

  gh_head=$(global_headroom); fl_head=$(fleet_headroom "$sess")
  slots=$gh_head; [ "$fl_head" -lt "$slots" ] && slots=$fl_head
  [ "$k" -lt "$slots" ] && slots=$k
  if [ "$slots" -le 0 ]; then
    log "$sess: no headroom (global=$gh_head fleet=$fl_head) — skip"
    exit 0
  fi

  # Single-writer for this fleet: only one dispatcher spawns into it at a time.
  # The holder id is fully defaulted (sess is always set) — never bare $USER.
  lease="$LEASE_DIR/dispatch-$(fleet_slug "$repo").lock"
  me="dispatch:$sess:$$@$(hostname -s 2>/dev/null || echo host)"
  if [ "$DRY" = 0 ]; then
    lease_acquire "$lease" "$me" || { log "$sess: another dispatcher holds the lease — skip"; exit 0; }
    trap 'lease_release "$lease" "$me"' EXIT
  fi

  # Anti-collision live set: never re-spawn an issue that already has a window.
  # Mirror dash-issue-session.sh's OWN dedup, which matches on BOTH the @issue
  # binding AND the bare "issue-<N>" window name — so a window whose @issue was
  # cleared (a slug-named window) is still recognised as live and not counted as
  # a fresh spawn. Second guard beyond the eligible-set's unassigned filter.
  live=$(tmux list-windows -t "$sess" -F '#{@issue}	#{window_name}' 2>/dev/null | awk -F'\t' '
    { if ($1 != "") print $1
      if ($2 ~ /^issue-[0-9]+$/) { n=$2; sub(/^issue-/, "", n); print n } }' | sort -u)
  is_live() { printf '%s\n' "$live" | grep -qxF "$1"; }

  ready="${FLEET_AUTOFILL_READY_LABEL:-}"
  spawned=0; considered=0
  while IFS=$(printf '\t') read -r tier num; do
    [ -z "$num" ] && continue
    considered=$((considered + 1))
    if is_live "$num"; then
      log "$sess: skip #$num (p$tier) — window already bound"
      continue
    fi
    if [ "$DRY" = 1 ]; then
      log "$sess: would spawn #$num (p$tier)  [slot $((spawned + 1))/$slots]"
      spawned=$((spawned + 1))
      [ "$spawned" -ge "$slots" ] && break
      continue
    fi
    if "$BIN/dash-issue-session.sh" "$num" "$sess" >/dev/null 2>&1; then
      log "$sess: spawned #$num (p$tier)  [slot $((spawned + 1))/$slots]"
      spawned=$((spawned + 1))
    else
      # dash-issue-session re-checks the caps + dedup; a refusal here is expected
      # backpressure (a slot filled between our count and the spawn), not an error.
      log "$sess: spawn of #$num refused (cap/dup race) — stop this tick"
      break
    fi
    [ "$spawned" -ge "$slots" ] && break
  done <<EOF
$(eligible_issues "$repo" "$ready")
EOF

  if [ "$considered" -eq 0 ]; then
    log "$sess: backlog has no eligible issues"
  elif [ "$spawned" -eq 0 ]; then
    log "$sess: nothing spawned (all eligible already bound, or no free slot)"
  else
    log "$sess: filled $spawned slot(s) (global_headroom=$gh_head fleet_headroom=$fl_head cap/tick=$k)"
  fi
) }

# --- which fleets? argv wins; else every live fleet session on this server. -----
SESSIONS=()
if [ "${#ARGV_SESS[@]}" -gt 0 ]; then
  SESSIONS=("${ARGV_SESS[@]}")
else
  # A fleet session is one that owns a 'plan' or 'dash' hub window (same rule the
  # global count uses). Derive the set from a single tmux scan.
  while IFS= read -r s; do
    [ -n "$s" ] && SESSIONS+=("$s")
  done < <(tmux list-windows -a -F '#{session_name} #{window_name}' 2>/dev/null | awk '
    { if ($2=="plan" || $2=="dash") fleet[$1]=1 }
    END { for (s in fleet) print s }' | sort)
fi

if [ "${#SESSIONS[@]}" -eq 0 ]; then
  log "no fleet sessions found (nothing to dispatch)"
  exit 0
fi

# Diskguard gate is a MACHINE-WIDE (per-volume) condition, so answer it ONCE per
# tick — not once per fleet. Low disk ⇒ skip the whole run (never auto-spawn onto
# a full volume; that is the crash-loop guard). fleet-up/restore share this gate.
if [ "$DRY" = 0 ] && [ -x "$BIN/fleet-diskguard.sh" ] \
   && ! "$BIN/fleet-diskguard.sh" --gate >/dev/null 2>&1; then
  log "disk gate closed — skipping all fleets this tick"
  exit 0
fi

for s in "${SESSIONS[@]}"; do
  dispatch_fleet "$s"
done
exit 0
