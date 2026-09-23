#!/bin/bash
# fleet-launchd-probe.sh — "does this user's launchd domain still spawn jobs AT
# ALL?", answered by a disposable job that is not part of the fleet (issue #711).
#
# WHY A PROBE AND NOT MORE DAEMON WATCHING. #639→#682 built a self-heal ladder for
# a unit that stops being scheduled: notice, kick, count ineffective kicks,
# escalate to bootout+bootstrap. Every rung of it assumes the FAULT IS THE UNIT'S.
# On 2026-09-15 that assumption broke: nine of nine interval units stopped inside
# the same minute, `launchctl print` showed `runs` frozen for all of them, and
# fleet-doctor duly printed NINE lines each saying "com.claude-fleet.<x> last
# ticked 11m ago — nothing is scheduling it". Nine true statements that add up to
# a false one: the operator reads "the fleet's daemons are broken" and goes
# looking at plists, scripts, ProcessType and load, none of which is the problem.
#
# The measurement that ends that hunt in 40 seconds is this one. Bootstrap a job
# that shares NOTHING with the fleet but the domain — a one-line /bin/sh that
# appends to a file, `ProcessType=Standard`, `RunAtLoad=true`, a short
# `StartInterval` — wait, and count how many times it ran:
#
#   ticks ≥ 2   ok            RunAtLoad fired AND at least one interval spawn
#                             followed ⇒ the domain schedules; a stale unit is
#                             that unit's own problem, keep the per-unit alarms.
#   ticks = 1   no-interval   the job was spawned once at load and never again ⇒
#                             `StartInterval` scheduling is pended domain-wide.
#   ticks = 0   no-spawn      not even RunAtLoad ran, on a job launchd confirms is
#                             loaded ⇒ the domain spawns NOTHING automatically.
#                             This is the 2026-09-15 state, and it is machine
#                             state, not fleet state: the same install on the same
#                             commit was ticking normally on the other host.
#   unknown                   nothing was measured (no launchctl, bootstrap
#                             refused, a peer holds the lock). NEVER reported as
#                             a verdict — an unmeasured "all fine" is the failure
#                             mode this whole file exists to prevent.
#
# WHAT IT DOES NOT DO: fix it. A domain that has stopped spawning is recovered by
# logging out or rebooting, which is the operator's call and no automation's. The
# probe's entire job is to stop the fleet from taking the blame — and to tell the
# operator which of the two things to do.
#
# CLEANUP IS IN THE JOB, NOT IN A TRAP (the #697 lesson, applied). A trap lives in
# the PARENT, so a SIGKILLed or disowned parent takes the cleanup with it — and
# what leaks here is not a CPU burner but a registered LaunchAgent that would tick
# for ever. So the probe program carries its OWN deadline: every time it runs it
# checks the epoch baked into it and, past that, boots ITSELF out and deletes its
# own plist. The parent's trap is the fast path, not the guarantee. A probe that
# leaks because the domain never spawned it is harmless by construction (it is
# not running), and the lock-guarded sweep below reaps it on the next probe.
#
# Usage:
#   fleet-launchd-probe.sh                  # probe now (~40s), print the verdict
#   fleet-launchd-probe.sh --quiet          # ditto, exit code only
#   fleet-launchd-probe.sh --window 60 --interval 15
#   fleet-launchd-probe.sh --cached [TTL]   # last verdict if younger than TTL
#                                           #   (default FLEET_LAUNCHD_PROBE_TTL,
#                                           #   900s); never probes
#   fleet-launchd-probe.sh --sweep          # reap leftover probe jobs, nothing else
#
# Exit: 0 ok · 1 not scheduling (no-spawn/no-interval) · 2 bad argument
#       3 unknown (not measured) · 4 --cached with no usable cache
#
# Env: FLEET_LAUNCHD_PROBE_WINDOW (40)  FLEET_LAUNCHD_PROBE_INTERVAL (15)
#      FLEET_LAUNCHD_PROBE_TTL (900)    FLEET_LAUNCHD_PROBE (1 — 0 refuses to probe)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
_fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings"; [ -f "$_fs" ] && . "$_fs"   # the login's settings win (#979)
# shellcheck source=/dev/null
. "$BIN/fleet-daemon-lib.sh"

ROOT="$BIN/.."
STATE="$(fleet_daemon_state_dir "$ROOT")"
LABEL_PREFIX='com.claude-fleet.spawnprobe'

WINDOW="${FLEET_LAUNCHD_PROBE_WINDOW:-40}"
INTERVAL="${FLEET_LAUNCHD_PROBE_INTERVAL:-15}"
TTL="${FLEET_LAUNCHD_PROBE_TTL:-900}"
QUIET=0; CACHED=0; SWEEP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --window)   WINDOW="${2:-}"; shift ;;
    --interval) INTERVAL="${2:-}"; shift ;;
    --cached)   CACHED=1
                case "${2:-}" in ''|-*) ;; *) TTL="$2"; shift ;; esac ;;
    --sweep)    SWEEP=1 ;;
    --quiet|-q) QUIET=1 ;;
    -h|--help)  sed -n '2,70p' "$0"; exit 0 ;;
    *) printf 'fleet-launchd-probe: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
for n in "$WINDOW" "$INTERVAL" "$TTL"; do
  case "$n" in ''|*[!0-9]*) printf 'fleet-launchd-probe: --window/--interval/TTL want whole seconds\n' >&2; exit 2 ;; esac
done
[ "$INTERVAL" -ge 10 ] || INTERVAL=10   # launchd throttles a job to one spawn per
                                        # 10s (ThrottleInterval); a smaller interval
                                        # would measure the throttle, not the domain.

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$1"; }

# --- the cache -----------------------------------------------------------------
# A probe costs $WINDOW seconds of wall clock, so the verdict is written down and
# read back by anything that wants it cheaply (fleet-doctor). Format is one TSV
# line; fleet_daemon_probe_* in the lib is the reader.
report() {   # $1=verdict $2=ticks $3=runs
  fleet_daemon_probe_write "$1" "$2" "$WINDOW" "$INTERVAL" "${3:--}" "$ROOT"
  case "$1" in
    ok)          say "ok  launchd gui/$(id -u) spawns on schedule — the probe ran $2× in ${WINDOW}s (StartInterval=${INTERVAL}s)"; exit 0 ;;
    no-interval) say "no-interval  launchd gui/$(id -u) ran the probe at load but NEVER on its interval ($2 run in ${WINDOW}s, StartInterval=${INTERVAL}s) — interval scheduling is pended domain-wide"; exit 1 ;;
    no-spawn)    say "no-spawn  launchd gui/$(id -u) spawned the probe ZERO times in ${WINDOW}s — not even RunAtLoad. The domain is not spawning jobs at all; this is machine state, not fleet state (log out / reboot to recover)"; exit 1 ;;
    *)           say "unknown  ${2:-not measured}"; exit 3 ;;
  esac
}
# unknown never touches the cache: an unmeasured run must not overwrite a real
# verdict, and must not be mistakable for one later.
unknown() { say "unknown  $1"; exit 3; }

if [ "$CACHED" = 1 ]; then
  v=$(fleet_daemon_probe_verdict "$ROOT" "$TTL")
  [ -n "$v" ] || exit 4
  a=$(fleet_daemon_probe_age "$ROOT")
  say "$v  (cached ${a}s ago)"
  case "$v" in ok) exit 0 ;; no-spawn|no-interval) exit 1 ;; *) exit 3 ;; esac
fi

command -v launchctl >/dev/null 2>&1 || unknown "no launchctl on PATH — this probe is launchd-only (a systemd host pends differently)"
[ "${FLEET_LAUNCHD_PROBE:-1}" = 0 ] && unknown "probing is disabled (FLEET_LAUNCHD_PROBE=0)"

UID_="$(id -u)"

# --- ONE prober at a time ------------------------------------------------------
# The sweep below boots out every leftover probe job, which is only safe if no
# peer is mid-probe. Same mkdir primitive bin/fleet-daemon-watch.sh uses (no flock
# on macOS); debris older than two windows is taken over rather than waited on.
mkdir -p "$STATE" 2>/dev/null || unknown "cannot create the state dir $STATE"
LOCK="$STATE/launchd-probe.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  lts=$(cat "$LOCK/ts" 2>/dev/null); case "$lts" in ''|*[!0-9]*) lts=0 ;; esac
  if [ "$(( $(date +%s) - lts ))" -lt "$(( WINDOW * 2 + 60 ))" ]; then
    unknown "another probe is already running (lock $LOCK) — read --cached instead"
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || unknown "cannot take the probe lock $LOCK"
fi
date +%s > "$LOCK/ts"

WORK=''
cleanup() {
  [ -n "$WORK" ] && [ -d "$WORK" ] && {
    lbl=$(cat "$WORK/label" 2>/dev/null)
    [ -n "$lbl" ] && launchctl bootout "gui/$UID_/$lbl" >/dev/null 2>&1
    rm -rf "$WORK"
  }
  rm -rf "$LOCK"
  return 0
}
trap cleanup EXIT INT TERM

# --- sweep: reap any leftover probe job ----------------------------------------
# A probe whose parent was killed outright leaves a registered agent behind. It
# self-destructs the next time it RUNS, but on the very domain this tool exists to
# catch it never runs — so the next probe is what reaps it. Under the lock, any
# surviving spawnprobe job is debris by definition.
sweep() {
  launchctl list 2>/dev/null | awk -v p="$LABEL_PREFIX" '$3 ~ "^"p {print $3}' | while read -r old; do
    [ -n "$old" ] || continue
    launchctl bootout "gui/$UID_/$old" >/dev/null 2>&1
    printf '%s\n' "$old"
  done
  rm -rf "${TMPDIR:-/tmp}"/.claude-fleet-spawnprobe.* 2>/dev/null
  return 0
}
swept=$(sweep)
[ -n "$swept" ] && printf 'fleet-launchd-probe: reaped leftover probe job(s): %s\n' "$(printf '%s' "$swept" | tr '\n' ' ')" >&2
if [ "$SWEEP" = 1 ]; then say "swept${swept:+ $(printf '%s' "$swept" | tr '\n' ' ')}"; exit 0; fi

# --- build the probe -----------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/.claude-fleet-spawnprobe.XXXXXX")" || unknown "cannot create a work dir"
LABEL="$LABEL_PREFIX.$$"
printf '%s\n' "$LABEL" > "$WORK/label"
TICKS="$WORK/ticks"
PLIST="$WORK/$LABEL.plist"
: > "$TICKS"
# The job's own deadline: generous enough that a HEALTHY domain still gets several
# interval spawns inside the measurement window, short enough that a leaked job
# ends itself long before anyone notices it.
DEADLINE=$(( $(date +%s) + WINDOW + 120 ))

cat > "$WORK/probe.sh" <<SH
#!/bin/sh
# Disposable. Deliberately shares nothing with the fleet: no git, no tmux, no
# fork beyond \`date\`, ProcessType=Standard. If this file's runs stop, the DOMAIN
# stopped — there is nothing else here to blame.
date +%s >> "$TICKS" 2>/dev/null
# Self-destruct past the baked-in deadline — see the header: the parent's trap is
# the fast path, this is the guarantee (#697).
[ "\$(date +%s)" -ge $DEADLINE ] && {
  launchctl bootout "gui/$UID_/$LABEL" >/dev/null 2>&1
  rm -rf "$WORK" 2>/dev/null
}
exit 0
SH
chmod +x "$WORK/probe.sh"

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>$WORK/probe.sh</string>
  </array>
  <key>ProcessType</key><string>Standard</string>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PL

rc=0
launchctl bootstrap "gui/$UID_" "$PLIST" >/dev/null 2>&1 || rc=$?
if ! launchctl print "gui/$UID_/$LABEL" >/dev/null 2>&1; then
  unknown "the probe job would not bootstrap into gui/$UID_ (rc=$rc) — cannot tell whether the domain spawns; check \`launchctl bootstrap gui/$UID_ $PLIST\` by hand"
fi

# --- measure -------------------------------------------------------------------
sleep "$WINDOW"

ticks=$(wc -l < "$TICKS" 2>/dev/null | tr -d ' ')
case "$ticks" in ''|*[!0-9]*) ticks=0 ;; esac
# launchd's own counter, when this launchctl prints one. Corroboration only: the
# tick file is what proves the program actually EXECUTED, and a `runs` we cannot
# parse must never downgrade a measurement we have.
runs=$(launchctl print "gui/$UID_/$LABEL" 2>/dev/null | awk -F'= *' '/^\truns = /{print $2; exit}')
case "$runs" in ''|*[!0-9]*) runs='-' ;; esac

if   [ "$ticks" -ge 2 ]; then report ok "$ticks" "$runs"
elif [ "$ticks" -eq 1 ]; then report no-interval "$ticks" "$runs"
else                          report no-spawn "$ticks" "$runs"
fi
