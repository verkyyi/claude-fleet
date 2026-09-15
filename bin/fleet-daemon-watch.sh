#!/bin/bash
# fleet-daemon-watch.sh — the fleet's daemon self-heal: notice that an INTERVAL
# unit has stopped being scheduled and kick it, at most once per cooldown per
# unit, leaving a log line and a dash-visible trace behind (issue #639).
#
# It generalizes bin/fleet-collect-kick.sh (#636/#638), which watched the
# collector only, to every interval unit in the registry — because the fault it
# was built for is not collector-shaped. On 2026-09-14 launchd stopped scheduling
# EVERY StartInterval unit in this user domain inside the same two minutes
# (ledger-watch, base-sync, cleanup, dispatch, issue-bridge, quotawatch), while
# the two KeepAlive units never missed a frame; see bin/fleet-daemon-lib.sh for
# the measurements, the relative-interval threshold, and why the stamps are
# scoped to the install root.
#
# THE THREE RAILS, NOW PER UNIT (all three are the point, not decoration):
#   1. rate limit — one kick per unit per cooldown, claimed atomically under a
#      per-unit mkdir lock, so a permanently broken daemon costs one kick per
#      cooldown instead of one per caller. Callers pre-filter with
#      fleet_daemon_kick_due; the claim HERE is the actual limit. The cooldown
#      SCALES with the unit's own interval (max(3x interval, 60s)) — it was a flat
#      600s until #711, which was sized for the 60s units and turned the 15s ones
#      into 10-minute daemons on a host where kicking was the only execution path
#      left. See fleet_daemon_kick_cooldown.
#   2. log — every kick, and every refusal to kick, appends to
#      logs/daemon-kick.log with the unit, the staleness that triggered it and the
#      exit code, so "did it self-heal, and did it work?" is answerable later.
#   3. trace — a kick stamps <unit>.kick.ts, which the status bar keeps showing
#      (`↻ dash kicked 4m`, `↻ daemon kicked 4m`) for FLEET_DAEMON_KICK_TRACE
#      after the unit recovers. A silent recovery would hide exactly the failure
#      these issues are about.
#   4. escalate — a kickstart buys ONE execution, not restored scheduling. Measured
#      on the #639 host: six of seven interval units logged ZERO runs across 27.8
#      minutes, each having last run at the hand-kick minutes earlier. So after
#      FLEET_DAEMON_RELOAD_AFTER ineffective kicks (counted in <unit>.kick.fails,
#      zeroed the moment the unit ticks again) the remedy escalates to a real
#      unload + reload of the unit — `bootout` then `bootstrap` on launchd,
#      `daemon-reload` + timer restart on systemd — on its own, much longer
#      cooldown. A reload that leaves the unit UNLOADED is the one outcome worse
#      than a pend, so it is verified and, if it failed, retried on the very next
#      pass instead of waiting out the cooldown.
#
# A RUNNING UNIT IS NOT KICKED FOR BEING SLOW — but "running" is not a licence to
# hang for ever (issue #682). `launchctl kickstart -k` KILLS the current
# invocation, so kicking a unit that is merely slow would abort a working tick —
# and a slow tick is the one thing a relative threshold can confuse with a pended
# one. launchd/systemd answer that directly (`state = running`), so an overdue
# unit is classified before anything is done to it.
#
# #639 made that guard absolute, and #682 is the bill: collect and quotawatch each
# sat `state = running` and frozen for ~54 minutes, `--status` called both `stale`
# — the alarm was right — and the self-heal stood down BY DESIGN while the dash
# served 53-minute-old data. "Slow" and "wedged" are separated by DURATION, not by
# whether something is running, and staleness is the duration that says so: a tick
# that is slow but alive stamps `phase_ts` at every phase boundary, so its
# staleness stays small however long it runs. Past fleet_daemon_wedged_secs (3x
# the unit's own stale threshold; FLEET_DAEMON_WEDGED_MULT=0 restores the old
# hands-off guard) it has stopped advancing its heartbeat at all, and takes the
# ordinary ladder.
#
#   reload  pended, and kicking it repeatedly did not help → unload + reload
#   never   no stamp at all      → silent (fresh install, or a unit this host
#                                  never had — #492: ledger-watch was missing for
#                                  months). Alarming here teaches people to ignore
#                                  the alarm.
#   ok      fresh                → nothing to do
#   slow    overdue, RUNNING     → reported, NOT kicked: it is alive, just behind
#   wedged  RUNNING, but stale past fleet_daemon_wedged_secs → not behind, stopped
#                                  → healed on the normal ladder (#682)
#   pended  overdue, not running → the #639 fault → kick it
#   bootstr overdue, not loaded, but its plist is on disk → bootstrapped back in
#   no-unit overdue, not loaded, no plist → logged + stamped, never kicked; the
#                                  alarm stands
#
# WHO CALLS IT. bin/tmux-spinner.sh, every KICK_CHECK_SECS — the spinner is
# KeepAlive, i.e. the one fleet daemon that is always already running, so it is
# the only one that can be relied on to notice. An interval unit has no business
# rescuing interval units: it is being pended right alongside its patient. The
# status bar also kicks the collector while somebody is attached (#638).
#
# Never fatal: every caller invokes it as a side errand and it always exits 0
# (except on a bad argument). It runs no daemon's work inline — the daemon is what
# must be unstuck, and doing its work here would paper over the fault.
#
# Usage:
#   fleet-daemon-watch.sh                      # every registry unit: kick what is pended
#   fleet-daemon-watch.sh --unit collect       # one unit (repeatable)
#   fleet-daemon-watch.sh --status             # TSV table, touch nothing
#   fleet-daemon-watch.sh --unit collect --status
#                                              # the legacy fleet-collect-kick line:
#                                              #   fresh|stale|never <TAB> age <TAB> kick-age
#   fleet-daemon-watch.sh --force [--now]      # kick regardless of staleness (and,
#                                              #   with --now, regardless of cooldown
#                                              #   and of the unit being RUNNING)
#   fleet-daemon-watch.sh --dry-run            # say what it would do, touch nothing
#
# Env: FLEET_DAEMON_STALE_MULT (5)  FLEET_DAEMON_STALE_FLOOR (180)
#      FLEET_DAEMON_STALE_<UNIT> / FLEET_COLLECT_STALE  — absolute per-unit override
#      FLEET_DAEMON_KICK_COOLDOWN (absolute override; default is
#        max(FLEET_DAEMON_KICK_COOLDOWN_MULT=3 x interval,
#            FLEET_DAEMON_KICK_COOLDOWN_FLOOR=60))
#      FLEET_DAEMON_KICK_COOLDOWN_<UNIT>
#      FLEET_DAEMON_KICK_TRACE (1800)
#      FLEET_DAEMON_KICK (1 — set 0 to disable every self-heal and keep the alarm)
#      FLEET_DAEMON_WEDGED_MULT (3 — x the unit's stale threshold before a RUNNING
#        unit counts as wedged; 0 = never touch a running unit, the pre-#682 guard)
#      FLEET_DAEMON_WEDGED_<UNIT> (that threshold in seconds, for one unit)
#      FLEET_COLLECT_KICK (1 — same, for `collect` alone; #638's knob)
#      FLEET_DAEMON_RELOAD_AFTER (3 — 0 disables the reload escalation)
#      FLEET_DAEMON_RELOAD_COOLDOWN (1800)
#      FLEET_LAUNCHD_AGENTS_DIR (~/Library/LaunchAgents — where the plists live)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-daemon-lib.sh"

ROOT="$BIN/.."
STATE="$(fleet_daemon_state_dir "$ROOT")"
LOGD="$BIN/../logs"          # same logs/ the daemons write to (live install: ~/.claude/fleet/logs)
LOG="$LOGD/daemon-kick.log"

FORCE=0; NOW_=0; DRY=0; STATUS=0; UNITS=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --unit)    [ -n "${2:-}" ] || { printf 'fleet-daemon-watch: --unit needs a unit name\n' >&2; exit 2; }
               fleet_daemon_known "$2" || { printf 'fleet-daemon-watch: unknown unit %s (see fleet_daemon_units in bin/fleet-daemon-lib.sh)\n' "$2" >&2; exit 2; }
               UNITS="${UNITS:+$UNITS }$2"; shift ;;
    --force)   FORCE=1 ;;
    --now)     NOW_=1 ;;          # with --force: ignore the cooldown AND the running guard
    --dry-run) DRY=1 ;;
    --status)  STATUS=1 ;;
    -h|--help) sed -n '2,80p' "$0"; exit 0 ;;
    *) printf 'fleet-daemon-watch: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$UNITS" ] || UNITS="$(fleet_daemon_unit_names | tr '\n' ' ')"

now() { date +%s; }

# probe <unit> — "<mgr> <target> <running 0|1>" for a LOADED unit; nothing
# otherwise. launchd's `print` answers both questions in one call, so an overdue
# unit costs one round-trip and a healthy one costs none. The top-level `state`
# line is the job's; the nested ones (one tab deeper) belong to its sockets.
probe() {
  local u="$1" uid out st
  uid="$(id -u)"
  # EXIT STATUS decides whether the unit exists — `print` fails on an unknown
  # label — and the output only refines it. An empty-but-successful print is
  # therefore "loaded, not running", never "absent": guessing "absent" there would
  # silently disable the self-heal on any launchctl whose output we cannot parse.
  if command -v launchctl >/dev/null 2>&1 \
     && out="$(launchctl print "gui/$uid/com.claude-fleet.$u" 2>/dev/null)"; then
    st="$(printf '%s\n' "$out" | awk -F'= *' '/^\tstate = /{print $2; exit}')"
    case "$st" in running*) st=1 ;; *) st=0 ;; esac
    printf 'launchd gui/%s/com.claude-fleet.%s %s' "$uid" "$u" "$st"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 \
     && systemctl --user cat "claude-fleet-$u.service" >/dev/null 2>&1; then
    st=0
    [ "$(systemctl --user show -p SubState --value "claude-fleet-$u.service" 2>/dev/null)" = running ] && st=1
    printf 'systemd claude-fleet-%s.service %s' "$u" "$st"
    return 0
  fi
  return 1
}

log() {  # $1 = one line; append + keep the file small (a line per unit per 10 min at worst)
  mkdir -p "$LOGD" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 500 "$LOG" > "$LOG.trim" 2>/dev/null && mv "$LOG.trim" "$LOG"
  fi
  return 0
}

# kick_enabled <unit> — the self-heal kill switches. FLEET_DAEMON_KICK=0 silences
# every unit's kick (the ALARM deliberately stays: #638 separated the two so an
# operator can watch without being healed); FLEET_COLLECT_KICK=0 keeps doing the
# same for the collector alone, which is the knob #638 shipped.
kick_enabled() {
  [ "${FLEET_DAEMON_KICK:-1}" = 0 ] && return 1
  [ "$1" = collect ] && [ "${FLEET_COLLECT_KICK:-1}" = 0 ] && return 1
  return 0
}

# --- --status: report, touch nothing ------------------------------------------
# ONE unit prints the legacy bin/fleet-collect-kick.sh contract verbatim —
# `fresh|stale|never <TAB> age <TAB> kick-age` — because that is what the shim,
# the selftests and a decade of muscle memory read. Several units print a table:
#   unit <TAB> verdict <TAB> age <TAB> threshold <TAB> kick-age <TAB> failed-kicks
if [ "$STATUS" = 1 ]; then
  n=0; for _c in $UNITS; do n=$((n + 1)); done
  for u in $UNITS; do
    ts=$(fleet_daemon_tick_ts "$u" "$ROOT")
    kage=$(fleet_daemon_kick_age "$u" "$ROOT")
    thr=$(fleet_daemon_stale_secs "$u")
    if [ "$ts" -le 0 ]; then verdict=never; age=0
    else
      age=$(( $(now) - ts ))
      if [ "$age" -ge "$thr" ]; then verdict=stale; else verdict=fresh; fi
    fi
    if [ "$n" = 1 ]; then printf '%s\t%s\t%s\n' "$verdict" "$age" "${kage:--}"
    else printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$u" "$verdict" "$age" "$thr" "${kage:--}" \
      "$(fleet_daemon_kick_fails "$u" "$ROOT")"; fi
  done
  exit 0
fi

# One trap for the whole loop, re-aimed as each unit takes its lock: a watcher
# killed mid-kick must not leave a lock for the 120s steal timeout to clean up.
LOCK=''
trap '[ -n "$LOCK" ] && rm -rf "$LOCK"' EXIT

for u in $UNITS; do
  kick_enabled "$u" || continue

  stale=$(fleet_daemon_overdue "$u" "$ROOT")
  if [ -z "$stale" ]; then
    # Ticking again ⇒ whatever we last did worked (or nothing was ever wrong), so
    # the escalation ladder resets. Without this, one bad afternoon would leave
    # every unit permanently one pend away from a reload.
    [ -f "$STATE/$u.kick.fails" ] && rm -f "$STATE/$u.kick.fails" 2>/dev/null
    [ "$FORCE" != 1 ] && continue
  fi

  # --- the atomic claim: ONE kicker per unit, one kick per cooldown ------------
  # mkdir is the primitive (no flock on macOS). A lock left behind by a killed
  # kicker is taken over after 120s — the whole run is one launchctl call, so
  # anything older than that is debris, not a peer.
  mkdir -p "$STATE" 2>/dev/null || continue
  # $LOCK is assigned ONLY once this process owns the directory, because the EXIT
  # trap removes whatever $LOCK names — pointing it at a lock we failed to take
  # would have a losing kicker delete the WINNER's lock on the way out.
  cand="$STATE/$u.kick.lock"
  if ! mkdir "$cand" 2>/dev/null; then
    lts=$(cat "$cand/ts" 2>/dev/null); case "$lts" in ''|*[!0-9]*) lts=0 ;; esac
    if [ "$(( $(now) - lts ))" -lt 120 ]; then continue; fi   # a peer is mid-kick
    rm -rf "$cand"; mkdir "$cand" 2>/dev/null || continue
  fi
  LOCK="$cand"
  now > "$LOCK/ts"
  KTS="$STATE/$u.kick.ts"

  # Re-read the stamp INSIDE the lock — the caller's pre-filter raced.
  kage=$(fleet_daemon_kick_age "$u" "$ROOT")
  cool=$(fleet_daemon_kick_cooldown "$u")
  if [ -n "$kage" ] && [ "$kage" -lt "$cool" ] && ! { [ "$FORCE" = 1 ] && [ "$NOW_" = 1 ]; }; then
    printf 'fleet-daemon-watch: %s — skip, kicked %ss ago (cooldown %ss); still stale %ss\n' \
      "$u" "$kage" "$cool" "${stale:-0}" >&2
    rm -rf "$LOCK"; LOCK=''; continue
  fi

  # --- which manager, is the unit loaded, and is a tick RUNNING right now? -----
  # Everything from here to the ACT section is read-only classification, so that
  # --dry-run can report the exact remedy without performing any part of it.
  plist="${FLEET_LAUNCHD_AGENTS_DIR:-$HOME/Library/LaunchAgents}/com.claude-fleet.$u.plist"
  p="$(probe "$u")" || p=''
  mgr=''; target=''; running=0
  [ -n "$p" ] && read -r mgr target running <<EOF
$p
EOF

  # Would this be an escalation? Decided here, off the CURRENT fail count, so the
  # dry-run verdict and the real one cannot disagree.
  fails=$(fleet_daemon_kick_fails "$u" "$ROOT")
  after=$(fleet_daemon_reload_after)
  rcool=$(fleet_daemon_reload_cooldown)
  RTS="$STATE/$u.reload.ts"
  rage=''; rts_v=$(cat "$RTS" 2>/dev/null); case "$rts_v" in ''|*[!0-9]*) : ;; *) rage=$(( $(now) - rts_v )) ;; esac
  do_reload=0
  if [ -n "$mgr" ] && [ "$after" -gt 0 ] && [ "$fails" -ge "$after" ] \
     && { [ -z "$rage" ] || [ "$rage" -ge "$rcool" ]; }; then
    case "$mgr" in
      launchd) [ -f "$plist" ] && do_reload=1 ;;
      systemd) do_reload=1 ;;
    esac
  fi

  # Is a RUNNING unit merely slow, or WEDGED? (issue #682) Decided here, beside
  # do_reload, for the same reason: the dry-run verdict and the real one must not
  # be able to disagree. `stale` is seconds since this unit last showed ANY
  # evidence of life, and a tick that is slow but alive stamps `phase_ts` at every
  # phase boundary — so staleness measures "stopped", not "long". Past
  # fleet_daemon_wedged_secs the unit has not advanced its own heartbeat for
  # several whole alarm windows and the running-guard below stands down.
  wedged=0
  wthr=$(fleet_daemon_wedged_secs "$u")
  case "$wthr" in ''|*[!0-9]*) wthr=0 ;; esac
  if [ "$running" = 1 ] && [ "$wthr" -gt 0 ] && [ -n "$stale" ] && [ "$stale" -ge "$wthr" ]; then
    wedged=1
  fi

  # The verdict, in one place — and the whole of --dry-run.
  if [ "$DRY" = 1 ]; then
    if [ -z "$mgr" ]; then
      if [ -f "$plist" ]; then
        printf 'fleet-daemon-watch: would BOOTSTRAP %s (not loaded) from %s — %s stale %ss\n' "$u" "$plist" "$u" "${stale:-0}" >&2
      else
        printf 'fleet-daemon-watch: %s stale %ss, no unit and no plist — would do nothing\n' "$u" "${stale:-0}" >&2
      fi
    elif [ "$running" = 1 ] && [ "$wedged" = 1 ]; then
      printf 'fleet-daemon-watch: %s is RUNNING but WEDGED (stale %ss >= %ss) — would heal it anyway\n' "$u" "${stale:-0}" "$wthr" >&2
    elif [ "$running" = 1 ] && ! { [ "$FORCE" = 1 ] && [ "$NOW_" = 1 ]; }; then
      printf 'fleet-daemon-watch: %s stale %ss but a tick is RUNNING — would NOT touch it (wedged at %ss)\n' "$u" "${stale:-0}" "$wthr" >&2
    elif [ "$do_reload" = 1 ]; then
      printf 'fleet-daemon-watch: would RELOAD %s (%s) after %s ineffective kicks — %s stale %ss\n' "$target" "$mgr" "$fails" "$u" "${stale:-0}" >&2
    else
      printf 'fleet-daemon-watch: would kick %s (%s) — %s stale %ss\n' "$target" "$mgr" "$u" "${stale:-0}" >&2
    fi
    rm -rf "$LOCK"; LOCK=''; continue
  fi

  # --- ACT ---------------------------------------------------------------------
  if [ -z "$mgr" ]; then
    now > "$KTS"     # stamp first: it IS the rate limit, whatever we do below
    if [ -f "$plist" ] && command -v launchctl >/dev/null 2>&1; then
      # NOT LOADED but its plist is right there ⇒ recoverable, and the only remedy
      # is a bootstrap (kickstart has nothing to kick). Two ways to get here, both
      # real: a machine whose live install was synced but whose agents were never
      # (re)loaded, and — the one that matters — a `bootout` below whose paired
      # `bootstrap` failed. Without this branch that second case is a one-way door:
      # probe says "absent", the reload path is never reached again, and the unit
      # stays out of the domain until a human notices.
      rc=0
      launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || rc=$?
      launchctl kickstart "gui/$(id -u)/com.claude-fleet.$u" >/dev/null 2>&1 || :
      if probe "$u" >/dev/null 2>&1; then
        log "bootstrap unit=$u stale=${stale:-0}s rc=$rc — the unit was NOT loaded; bootstrapped from $plist"
        printf 'fleet-daemon-watch: %s was not loaded — bootstrapped from %s (rc=%s)\n' "$u" "$plist" "$rc" >&2
      else
        log "bootstrap-FAILED unit=$u rc=$rc — still not loaded after bootstrap gui/$(id -u) $plist; fix by hand"
        printf 'fleet-daemon-watch: %s is not loaded and bootstrap failed (rc=%s); see %s\n' "$u" "$rc" "$LOG" >&2
      fi
      rm -rf "$LOCK"; LOCK=''; continue
    fi
    # No unit and no plist to load one from: hand-run, or a host where this daemon
    # was never installed (#492). Do not kick into the void every cooldown forever
    # — but this is exactly the case where the operator wants to SEE why the fleet
    # is frozen, so log it and leave the alarm standing rather than falling silent.
    log "no-unit  unit=$u stale=${stale:-0}s — com.claude-fleet.$u is not loaded (launchd) and claude-fleet-$u.service is not known (systemd --user); nothing to kick"
    printf 'fleet-daemon-watch: %s stale %ss but its unit is not loaded — not kicking (see %s)\n' \
      "$u" "${stale:-0}" "$LOG" >&2
    rm -rf "$LOCK"; LOCK=''; continue
  fi
  # A RUNNING tick is alive, just behind — never kill it (see the header). Report
  # it and leave it alone; the alarm on the bar and in fleet-doctor still stands,
  # which is the whole point of separating "visible" from "healed". `--force
  # --now` is the deliberate override for a genuinely wedged tick.
  if [ "$running" = 1 ] && [ "$wedged" = 1 ]; then
    # Running, and stale for several whole alarm windows: not behind, stopped.
    # Falling through to the ladder is the point of #682 — before it, this was
    # the branch that watched a frozen tick for 54 minutes and did nothing.
    log "wedged   unit=$u stale=${stale:-0}s mgr=$mgr unit-state=running threshold=${wthr}s — RUNNING but not advancing its heartbeat; healing it (FLEET_DAEMON_WEDGED_MULT=0 restores the old hands-off guard)"
    printf 'fleet-daemon-watch: %s is RUNNING but WEDGED (stale %ss >= %ss) — healing it\n' \
      "$u" "${stale:-0}" "$wthr" >&2
  elif [ "$running" = 1 ] && ! { [ "$FORCE" = 1 ] && [ "$NOW_" = 1 ]; }; then
    log "slow     unit=$u stale=${stale:-0}s mgr=$mgr unit-state=running — behind but alive; NOT kicked (kickstart -k would abort the tick); wedged at ${wthr}s"
    printf 'fleet-daemon-watch: %s stale %ss but a tick is RUNNING — not kicked (wedged at %ss; --force --now aborts it now)\n' \
      "$u" "${stale:-0}" "$wthr" >&2
    rm -rf "$LOCK"; LOCK=''; continue
  fi

  # Stamp BEFORE acting: the stamp is the rate limit, so a remedy that hangs or
  # crashes this script must still cost the cooldown rather than freeing a retry
  # loop. The fail counter goes up at the same time and comes back down only when
  # the unit is seen ticking (top of this loop).
  now > "$KTS"
  printf '%s\n' "$(( fails + 1 ))" > "$STATE/$u.kick.fails" 2>/dev/null || :

  # Escalate (decided above)? Kicking a unit that has already been kicked
  # $RELOAD_AFTER times without coming back is just buying another single
  # execution — see the header's `runs` table. Unload it and put it back instead,
  # the same thing an operator does by hand, on its own long cooldown and only
  # when its plist is actually there to bootstrap FROM: booting a unit out with
  # nothing to boot back in is the one outcome worse than a pend.
  rc=0
  if [ "$do_reload" = 1 ]; then
    case "$mgr" in
      launchd)
        launchctl bootout "$target" >/dev/null 2>&1 || :   # already-out is fine
        launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || rc=$?
        launchctl kickstart "$target" >/dev/null 2>&1 || :  # run one now, don't wait an interval
        ;;
      systemd)
        systemctl --user daemon-reload >/dev/null 2>&1 || :
        systemctl --user restart "claude-fleet-$u.timer" >/dev/null 2>&1 || rc=$?
        systemctl --user start "$target" >/dev/null 2>&1 || :
        ;;
    esac
    # VERIFY. If the unit is not loaded afterwards the reload made things worse,
    # so say so at the top of the log and leave the reload cooldown UNSTAMPED —
    # the next pass retries immediately rather than sitting on an unloaded unit
    # for half an hour.
    if probe "$u" >/dev/null 2>&1; then
      now > "$RTS"
      log "reload   unit=$u stale=${stale:-0}s mgr=$mgr target=$target rc=$rc after=${fails} kicks — unloaded + reloaded (kickstart alone was not restoring the schedule)"
      printf 'fleet-daemon-watch: %s stale %ss — RELOADED %s (%s) after %s ineffective kicks, rc=%s\n' \
        "$u" "${stale:-0}" "$target" "$mgr" "$fails" "$rc" >&2
    else
      log "reload-FAILED unit=$u mgr=$mgr target=$target rc=$rc — the unit is NOT loaded after the reload; retrying on the next pass. Fix by hand: launchctl bootstrap gui/$(id -u) $plist"
      printf 'fleet-daemon-watch: %s RELOAD FAILED — the unit is not loaded now (rc=%s); see %s\n' \
        "$u" "$rc" "$LOG" >&2
    fi
    rm -rf "$LOCK"; LOCK=''; continue
  fi

  case "$mgr" in
    launchd) launchctl kickstart -k "$target" >/dev/null 2>&1 || rc=$? ;;
    systemd) systemctl --user restart "$target" >/dev/null 2>&1 || rc=$? ;;
  esac

  log "kick     unit=$u stale=${stale:-0}s mgr=$mgr target=$target rc=$rc cooldown=${cool}s fails=$(( fails + 1 ))"
  printf 'fleet-daemon-watch: %s stale %ss — kicked %s (%s), rc=%s\n' \
    "$u" "${stale:-0}" "$target" "$mgr" "$rc" >&2
  rm -rf "$LOCK"; LOCK=''
done
exit 0
