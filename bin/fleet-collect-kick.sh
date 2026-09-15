#!/bin/bash
# fleet-collect-kick.sh — the dash collector's self-heal: notice that the
# collector has stopped ticking and kick its daemon, at most once per cooldown,
# leaving a log line and a dash-visible trace behind (issue #636).
#
# WHY. On 2026-09-14 launchd held com.claude-fleet.collect for 103 minutes
# without running it once:
#
#     state = not running        runs = 2648        last exit code = 0
#     pended nondemand spawn = interval        run interval = 60 seconds
#
# Not a crash, not power management (AC, 100%, lowpowermode 0) — launchd simply
# never spawned the job. `launchctl kickstart -k` fixed it instantly, which is
# what makes a self-heal worth having. Meanwhile the dash showed a two-hour-old
# world with complete confidence: PR state, worker state, context %, quota, all
# read out of caches nothing was refreshing. The staleness ALARM lives in
# usage-lib.sh (`⚠ dash stale 47m` on the status bar); this script is the other
# half — the hand that reaches over and restarts the thing.
#
# THE THREE RAILS (all three are the point, not decoration):
#   1. rate limit — one kick per FLEET_COLLECT_KICK_COOLDOWN (600s), claimed
#      atomically under a mkdir lock, so a permanently broken daemon costs one
#      kick per 10 min instead of one per status-bar render. Callers pre-filter
#      with fleet_collect_kick_due, but the claim HERE is the actual limit: the
#      status bar runs every 5s per attached client and the quota watch every 60s.
#   2. log — every kick (and every refusal to kick) appends to
#      logs/collect-kick.log with the staleness that triggered it and the exit
#      code of the kickstart, so "did it self-heal, and did it work?" is
#      answerable after the fact.
#   3. trace — the kick stamps global/collect.kick.ts, which the status bar keeps
#      showing (`↻ dash kicked 4m`) for FLEET_COLLECT_KICK_TRACE after the
#      collector recovers. A silent recovery would hide exactly the failure this
#      issue is about.
#
# Never fatal: every caller invokes it as a side errand and it always exits 0
# (except on a bad argument). It does not run a collector tick itself — the
# daemon is what must be unstuck; running one inline would paper over the fault
# and put a 3-minute tick on the status bar's path.
#
# Usage:
#   fleet-collect-kick.sh                 # kick iff stale + cooldown elapsed
#   fleet-collect-kick.sh --force         # kick regardless of staleness (still
#                                         #   cooldown-limited; --force --now skips that too)
#   fleet-collect-kick.sh --dry-run       # say what it would do, touch nothing
#   fleet-collect-kick.sh --status        # fresh|stale|never <TAB> age <TAB> kick-age
#
# Env: FLEET_COLLECT_STALE (→ FLEET_COLLECT_DEADLINE, 600)
#      FLEET_COLLECT_KICK_COOLDOWN (600)  FLEET_COLLECT_KICK_TRACE (1800)
#      FLEET_COLLECT_KICK (1 — set 0 to disable the self-heal and keep the alarm)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"      # fleet_collect_stale_age / _kick_age / _stale_secs

G="$(fleet_usage_cache_dir)"; mkdir -p "$G"
KTS="$G/collect.kick.ts"
LOCK="$G/collect.kick.lock"
LOGD="$BIN/../logs"          # same logs/ the daemons write to (live install: ~/.claude/fleet/logs)
LOG="$LOGD/collect-kick.log"
COOLDOWN="${FLEET_COLLECT_KICK_COOLDOWN:-600}"
UNIT_LAUNCHD="com.claude-fleet.collect"
UNIT_SYSTEMD="claude-fleet-collect.service"

FORCE=0; NOW_=0; DRY=0; STATUS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1 ;;
    --now)     NOW_=1 ;;          # with --force: ignore the cooldown too (tests / by hand)
    --dry-run) DRY=1 ;;
    --status)  STATUS=1 ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) printf 'fleet-collect-kick: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

now() { date +%s; }

# --status: the verdict, for scripts (fleet-doctor, the selftest, a human).
#   never — no heartbeat at all (fresh install / hand-run collector)
#   fresh|stale <TAB> heartbeat age <TAB> seconds since the last kick (- = never)
if [ "$STATUS" = 1 ]; then
  hb_ts=$(fleet_collect_hb_ts); kage=$(fleet_collect_kick_age)
  if [ "$hb_ts" -le 0 ]; then printf 'never\t0\t%s\n' "${kage:--}"; exit 0; fi
  age=$(( $(now) - hb_ts ))
  if [ -n "$(fleet_collect_stale_age)" ]; then printf 'stale\t%s\t%s\n' "$age" "${kage:--}"
  else printf 'fresh\t%s\t%s\n' "$age" "${kage:--}"; fi
  exit 0
fi

[ "${FLEET_COLLECT_KICK:-1}" = 0 ] && exit 0

stale=$(fleet_collect_stale_age)
if [ -z "$stale" ] && [ "$FORCE" != 1 ]; then exit 0; fi

log() {  # $1 = one line; append + keep the file small (this is 1 line per 10 min)
  mkdir -p "$LOGD" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || return 0
  # Trim rarely and cheaply: only when the file has grown past ~2000 lines.
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 500 "$LOG" > "$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG"
  fi
  return 0
}

# --- the atomic claim: ONE kicker at a time, one kick per cooldown -------------
# mkdir is the primitive (no flock on macOS). A lock left behind by a killed
# kicker is taken over after 120s — the whole run is a launchctl call, so
# anything older than that is debris, not a peer.
if ! mkdir "$LOCK" 2>/dev/null; then
  lts=$(cat "$LOCK/ts" 2>/dev/null); case "$lts" in ''|*[!0-9]*) lts=0 ;; esac
  if [ "$(( $(now) - lts ))" -lt 120 ]; then exit 0; fi   # a peer is mid-kick
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 0
fi
now > "$LOCK/ts"
trap 'rm -rf "$LOCK"' EXIT

# Re-read the stamp INSIDE the lock — the pre-filter in usage-lib.sh raced.
kage=$(fleet_collect_kick_age)
if [ -n "$kage" ] && [ "$kage" -lt "$COOLDOWN" ] && ! { [ "$FORCE" = 1 ] && [ "$NOW_" = 1 ]; }; then
  printf 'fleet-collect-kick: skip — kicked %ss ago (cooldown %ss); collector still stale %ss\n' \
    "$kage" "$COOLDOWN" "${stale:-0}" >&2
  exit 0
fi

# --- which daemon manager, and is the unit even there? ------------------------
# A collector that is not run by a daemon at all (hand-run, or a host where the
# unit was deliberately unloaded) must not be kicked every cooldown forever — but
# it is exactly the case where the operator wants to SEE why the dash is frozen,
# so we log it and leave the alarm standing rather than falling silent.
mgr=''; target=''
if command -v launchctl >/dev/null 2>&1 \
   && launchctl print "gui/$(id -u)/$UNIT_LAUNCHD" >/dev/null 2>&1; then
  mgr=launchd; target="gui/$(id -u)/$UNIT_LAUNCHD"
elif command -v systemctl >/dev/null 2>&1 \
     && systemctl --user cat "$UNIT_SYSTEMD" >/dev/null 2>&1; then
  mgr=systemd; target="$UNIT_SYSTEMD"
fi

if [ -z "$mgr" ]; then
  log "no-unit  stale=${stale:-0}s — neither $UNIT_LAUNCHD (launchd) nor $UNIT_SYSTEMD (systemd --user) is loaded; nothing to kick"
  printf 'fleet-collect-kick: collector stale %ss but no daemon unit is loaded — not kicking (see %s)\n' \
    "${stale:-0}" "$LOG" >&2
  now > "$KTS"     # stamp anyway: it IS the rate limit, and the bar's ↻ trace says a self-heal was attempted
  exit 0
fi

if [ "$DRY" = 1 ]; then
  printf 'fleet-collect-kick: would kick %s (%s) — collector stale %ss\n' "$target" "$mgr" "${stale:-0}" >&2
  exit 0
fi

# Stamp BEFORE kicking: the stamp is the rate limit, so a kickstart that hangs or
# crashes this script must still cost the cooldown rather than freeing a retry loop.
now > "$KTS"

rc=0
case "$mgr" in
  launchd) launchctl kickstart -k "$target" >/dev/null 2>&1 || rc=$? ;;
  systemd) systemctl --user restart "$target" >/dev/null 2>&1 || rc=$? ;;
esac

log "kick     stale=${stale:-0}s mgr=$mgr unit=$target rc=$rc cooldown=${COOLDOWN}s"
printf 'fleet-collect-kick: collector stale %ss — kicked %s (%s), rc=%s\n' \
  "${stale:-0}" "$target" "$mgr" "$rc" >&2
exit 0
