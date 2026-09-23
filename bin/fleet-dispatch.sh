#!/bin/bash
# fleet-dispatch.sh [--dry-run] [session...] — the AUTOFILL dispatcher (issues #70, #421).
#
# Keeps each opt-in fleet's worker slots filled FROM ITS BACKLOG, BY PRIORITY,
# whenever capacity exists under BOTH caps — automating the manual "file issue →
# hold for cap → spawn when a slot frees" loop the operator does by hand. Run as an
# interval daemon (com.claude-fleet.dispatch, ~60s) or by hand for one fleet.
#
# OPT-IN ON A SPECIFIC LABEL (issue #421). An issue is auto-spawned ONLY when it
# carries the canonical `autofill` label — the per-issue opt-in gate. So autofill
# never touches the whole backlog; the operator tags exactly the issues that may
# fill idle slots hands-off (mirrors how `autoland` opts a PR into hands-off land).
#
# OFF BY DEFAULT per fleet, TOO. A fleet auto-spawns only when its conf sets
# FLEET_AUTOFILL=1 — a two-key gate (fleet armed AND issue labelled). Auto-spawning
# launches real Claude sessions that spend LLM tokens — it is aggressive, so it
# must be explicitly enabled per fleet on top of the per-issue label.
#
# Design (per issues #70, #421):
#   for each live fleet session (or the ones named on argv):
#     load its conf; skip unless FLEET_AUTOFILL=1
#     acquire a per-fleet LEASE (mkdir, steal-if-stale)   → single-writer
#     honor the diskguard GATE (fleet-diskguard.sh --gate) → never fill a full disk
#     honor the quotaguard GATE (fleet-quotaguard.sh --gate) → never spend the
#         last of a subscription's window on autofill (opt-in, fails open)
#     slots = min(global headroom, per-fleet headroom, MAX_PER_TICK)  → rate-limit
#     eligible = open, UNASSIGNED, carries `autofill`, not `blocked`,
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
# needs no schema — the labels are just GitHub labels the operator already sets.
#
# Anti-collision: the assignee IS the claim (issue #283) — /fleet-claim assigns the
# worker, and the pre-spawn dedup assigns AT SPAWN, so "has any assignee" is the
# cheap proxy for "already owned": one `gh issue list` call, no per-issue comment
# fetch. A live @issue window is the second guard (covers a just-spawned session
# before its /fleet-claim lands).
#
# Cross-machine (issue #258): the pre-spawn dedup is ON by default (unless a fleet
# sets FLEET_PRESPAWN_DEDUP=0), so the spawn claims AT SPAWN (assignee) instead of
# on the worker's first turn — a peer's claim shows up as an assignee almost
# immediately, and the SAME unassigned-only filter below is the autofill pre-filter
# that keeps this fleet's dispatcher from racing a peer for a claimed issue. The
# pre-spawn GitHub check in dash-issue-session.sh is then only the sub-second-race
# backstop, not the primary gate. (Still the cheap assignee proxy — no per-issue
# comment fetch; single shared gh account means assigned-at-all ⇒ taken.)
#
# Env knobs (all per-fleet, in $FLEET_CONF_DIR/<session>.conf or global fleet.conf):
#   FLEET_AUTOFILL              1 to enable for this fleet          (default 0/off)
#   FLEET_MAX_SESSIONS          per-fleet session ceiling           (default 0/unlimited)
#   FLEET_GLOBAL_MAX_SESSIONS   system-wide ceiling (shared)        (default 8)
#   FLEET_AUTOFILL_MAX_PER_TICK max spawns per fleet per tick       (default 1)
#   FLEET_DISPATCH_LEASE_TTL    lease lifetime, seconds             (default 300)
#   FLEET_DISPATCH_LEASE_DIR    lease dir             (default ~/.claude/leases)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
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
  fleet_daemon_stamp_tick dispatch "$BIN/.."; }

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
# Requires the `autofill` opt-in label (issue #421); excludes assigned / blocked
# (`blocked` is documented autofill-excluded, so an issue tagged BOTH autofill
# AND blocked still waits). One `gh issue list` call; jq does all the
# filtering + tiering. --limit is generous so FIFO isn't broken by a created-desc
# fetch dropping old (low-numbered, high-priority) issues at scale.
eligible_issues() {
  local repo="$1"
  # shellcheck disable=SC2016  # $l/$t are jq bindings, not shell expansions
  gh issue list --repo "$repo" --state open --limit 1000 \
    --json number,labels,assignees \
    --jq '.[]
      | select((.assignees|length)==0)
      | (.labels|map(.name)) as $l
      | select($l|any(.=="autofill"))
      | select(($l|any(.=="blocked"))|not)
      | ( if   ($l|any(.=="priority:p0")) then 0
          elif ($l|any(.=="priority:p1")) then 1
          elif ($l|any(.=="priority:p2")) then 2
          else 3 end ) as $t
      | "\($t)\t\(.number)"' 2>/dev/null \
    | sort -t"$(printf '\t')" -k1,1n -k2,2n
}

# --- per-fleet lease (single-writer; steal-if-stale). Mirrors fleet-cleanup-daemon.sh. ---
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

# --- liveness: a spawned pane parked on Claude Code's trust dialog (issue #563) ---
# A worker whose checkout is not trusted in ~/.claude.json stops at "Quick safety
# check: Is this a project you created or one you trust? ❯ 1. Yes, I trust this
# folder / 2. No, exit" — and with nobody in the pane it stays there while this
# dispatcher counts the slot as filled (macmini, 2026-09-12: 7+ minutes, no
# /fleet-claim, no comment, no branch, nothing in this log). The launcher now
# pre-trusts at spawn, so this is the backstop that makes a recurrence VISIBLE:
# once per window, log it + stamp `needs` (red on the dash, with the fix in the
# log). Discriminator against a WORKING session whose screen merely contains the
# words (a worker editing this very file): a parked pane has never run a hook, so
# its @claude_state is EMPTY — a live session always carries working/done/needs.
# The slot is deliberately NOT freed: freeing it would spawn another parked worker.
trust_sweep() { # $1 = session
  local sess="$1" sock wid iss wname
  sock=$(fleet_socket "$sess")
  # Filter in awk, not `read`: tab is IFS whitespace, so `read` COLLAPSES the empty
  # fields this filter is about (`@3<tab><tab><tab><tab>plan` would read as issue
  # "plan"). awk -F'\t' keeps them. Survivors have a non-empty @issue and the name
  # last, so the shell read below is safe.
  tmux -L "$sock" list-windows -t "$sess" -F '#{window_id}	#{@issue}	#{@claude_state}	#{@trust_stuck}	#{window_name}' 2>/dev/null \
  | awk -F'\t' '$2 != "" && $3 == "" && $4 == "" { print $1 "\t" $2 "\t" $5 }' \
  | while IFS=$(printf '\t') read -r wid iss wname; do
      # issue-bound (col 2), no hook ever fired (col 3 empty), not yet reported (col 4)
      tmux -L "$sock" capture-pane -p -t "$wid" 2>/dev/null | grep -q 'trust this folder' || continue
      log "$sess: #$iss ($wname, $wid) is PARKED at Claude Code's \"trust this folder?\" dialog — the slot is filled but nothing runs; fix: sh $BIN/fleet-trust.sh grant --main '${FLEET_MAIN:-<FLEET_MAIN>}' then answer 1 in the pane (or kill + respawn); marking needs"
      tmux -L "$sock" set-window-option -t "$wid" @claude_state needs 2>/dev/null
      tmux -L "$sock" set-window-option -t "$wid" @claude_state_ts "$(date +%s)" 2>/dev/null
      tmux -L "$sock" set-window-option -t "$wid" @trust_stuck 1 2>/dev/null
    done
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

  # The subscription gate measures Claude, while the disk/session caps apply to
  # every agent. Read the fleet's agent AFTER its overlay, and never let a Claude
  # quota hold stop Codex autofill (#730). The measurement is shared once per tick.
  if [ "${FLEET_FAILOVER:-0}" = 1 ]; then
    export FLEET_FAILOVER FLEET_FAILOVER_AGENTS FLEET_MODEL FLEET_CODEX_SERVER
    if ! "$BIN/fleet-account.sh" choose --agent "${FLEET_AGENT:-claude}" --spawn \
      | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("target") else 3)'; then
      log "$sess: subscription pools unavailable — autofill waits"
      exit 0
    fi
  elif [ "${FLEET_AGENT:-claude}" != codex ] && [ "$quota_closed" = 1 ]; then
    log "$sess: Claude quota gate closed — skip: ${quota_why}"
    exit 0
  fi
  if [ "${FLEET_FAILOVER:-0}" != 1 ] && [ "${FLEET_AGENT:-claude}" = codex ] && [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
    if ! codex_quota=$(FLEET_CONF_DIR="$FLEET_CONF_DIR" "$BIN/fleet-codex-account.sh" gate --session "$sess" 2>&1); then
      log "$sess: Codex quota gate closed — skip: $codex_quota"
      exit 0
    fi
  fi

  # An autofill fleet is by definition unattended — report a parked spawn before
  # counting slots (it stays counted; see trust_sweep).
  [ "$DRY" = 1 ] || trust_sweep "$sess"

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
  # A 2+ repo fleet's names carry a repo tag (`tl·issue-12`, issue #793).
  live=$(tmux -L "$(fleet_socket "$sess")" list-windows -t "$sess" -F '#{@issue}	#{window_name}' 2>/dev/null | awk -F'\t' '
    { if ($1 != "") print $1
      if ($2 ~ /^(.*·)?issue-[0-9]+$/) { n=$2; sub(/^.*issue-/, "", n); print n } }' | sort -u)
  is_live() { printf '%s\n' "$live" | grep -qxF "$1"; }
  # A fleet hosting 2+ repos keys the live set by (repo, N) (issue #790): repo A's
  # #12 window must not block spawning repo B's #12. A window whose repo is unknown
  # (`#N`) still blocks N in every repo — a skipped spawn retries next tick, a
  # double spawn spends tokens twice. A one-repo fleet keeps the set above as is.
  if fleet_multirepo "$sess"; then
    live=$(fleet_bound_windows "$sess" | cut -f1 | sort -u)
    is_live() { printf '%s\n' "$live" | grep -qxF -e "$(fleet_norm_repo "$repo")#$1" -e "#$1"; }
  fi

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
    # Keep the spawn's stderr (issue #683): a refusal prints its reason there —
    # the tmux toast lands on no screen this daemon owns — and the exit code says
    # WHICH refusal: 2 at capacity, 3 claimed elsewhere, 1 infrastructure.
    why=$("$BIN/dash-issue-session.sh" "$num" "$sess" --origin autofill 2>&1 >/dev/null); rc=$?
    why=${why#dash-issue-session: }; why=${why//$'\n'/ | }
    if [ "$rc" = 0 ]; then
      log "$sess: spawned #$num (p$tier)  [slot $((spawned + 1))/$slots]"
      spawned=$((spawned + 1))
    elif [ "$rc" = 3 ]; then
      # Claimed between our eligibility read and the spawn (a peer machine's
      # dedup won the race): this ISSUE is taken, the SLOT is still free — move
      # on to the next candidate rather than ending the tick on it.
      log "$sess: skip #$num (p$tier) — ${why:-claimed elsewhere}"
      continue
    else
      # At capacity (a slot filled between our count and the spawn — expected
      # backpressure, not an error) or an infrastructure failure: neither gets
      # better by trying the next issue, so stop this tick — and say why.
      log "$sess: spawn of #$num refused (rc=$rc: ${why:-no reason given}) — stop this tick"
      break
    fi
    [ "$spawned" -ge "$slots" ] && break
  done <<EOF
$(eligible_issues "$repo")
EOF

  if [ "$considered" -eq 0 ]; then
    log "$sess: backlog has no eligible autofill-labelled issues"
  elif [ "$spawned" -eq 0 ]; then
    log "$sess: nothing spawned (all eligible already bound, or no free slot)"
  else
    log "$sess: filled $spawned slot(s) (global_headroom=$gh_head fleet_headroom=$fl_head cap/tick=$k)"
  fi
) }

# --- which fleets? argv wins; else every live fleet session on this server. -----
SESSIONS=()
if [ "${#ARGV_SESS[@]}" -gt 0 ]; then
  SESSIONS=(${ARGV_SESS[@]+"${ARGV_SESS[@]}"})
else
  # A fleet session is one that owns a 'plan' or 'dash' hub window (same rule the
  # global count uses). fleet_hub_sessions fans this out across every live fleet
  # socket (issue #159) — no single server sees them all anymore.
  while IFS= read -r s; do
    [ -n "$s" ] && SESSIONS+=("$s")
  done < <(fleet_hub_sessions | sort)
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

# Quota measurement is shared by Claude fleets, so read it ONCE per tick.
# The verdict is applied inside dispatch_fleet after resolving its agent; it is
# not a machine-wide hold (Codex uses a different subscription). Autofill spends the
# subscription its spawned sessions run on; without this the dispatcher happily
# burns the last of a weekly window on whatever happened to be labelled
# `autofill`, and the operator discovers it when their own session is refused.
#
# OFF unless the fleet sets FLEET_QUOTA_GATE=1 and ccquota is installed with a
# hub configured — the guard is a no-op otherwise, so a fleet that has never
# heard of ccquota is unaffected. It fails OPEN, like the disk gate.
quota_closed=0; quota_why=''
if [ "$DRY" = 0 ] && [ -x "$BIN/fleet-quotaguard.sh" ]; then
  quota_why=$("$BIN/fleet-quotaguard.sh" --gate 2>&1 >/dev/null) || {
    quota_closed=1
  }
fi

for s in ${SESSIONS[@]+"${SESSIONS[@]}"}; do
  dispatch_fleet "$s"
done
exit 0
