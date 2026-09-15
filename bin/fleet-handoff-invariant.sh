#!/bin/sh
# fleet-handoff-invariant.sh — is the handoff cycle still able to survive a turn
# whose Stop hook never fired? Exit 0 = the invariant holds, 1 = VIOLATED, 2 =
# could not be evaluated (a source file moved or stopped matching).
#
# Why this exists (issue #677). Auto-handoff — the thing that lets a long loop
# (`/fleet-epic run`, an overnight worker) live past one context window — depends
# on TWO timeouts that live in two different files and have never known about each
# other:
#
#   bin/tmux-spinner.sh        STUCK_SECS + a 2-strike debounce on a
#                              STUCK_CHECK_SECS sweep  → forces @claude_state=done
#   bin/fleet-handoff-cycle.sh IDLE_TIMEOUT            → WAIT-IDLE gives up and
#                              ABORTS WITHOUT CLEARING
#
# The load-bearing case is a turn the model never finished emitting — a fable cap
# (#580), a crash, a dropped Stop hook. `@claude_state` stays `working` FOREVER, so
# WAIT-IDLE's gate can only ever be opened by the spinner's stuck-working backstop
# (#101). That backstop lands at worst
#
#     STUCK_SECS + 2 × STUCK_CHECK_SECS      (first sweep = strike 1, next = demote)
#
# seconds after the pane froze. If that number is not STRICTLY BELOW IDLE_TIMEOUT,
# the cycle gives up first and the handoff never happens. And the failure is
# SILENT: no error, no red window — the loop's context simply fills up and the
# session stops doing anything, which on an overnight run means every remaining
# hour is wasted.
#
# Shipped, the two numbers were 140 vs 180 — a 40s margin nobody was guarding, in
# files whose authors could not see each other, behind knobs an operator can set
# independently. This script makes the relation explicit, and fleet-doctor.sh +
# bin/fleet-handoff-invariant-selftest.sh both read it, so editing either default
# into a dangerous relation goes red instead of going unnoticed.
#
# A SECOND invariant rides along, for the same reason: the cycle's own watchdog
# (HARD_TIMEOUT) TERMs the whole run, so WAIT-IDLE + VERIFY must fit inside it or
# a late-but-legitimate idle is killed mid-clear. Raising IDLE_TIMEOUT to buy
# margin on invariant #1 is exactly what tightens #2, so they are checked together.
#
# WHERE THE NUMBERS COME FROM. Parsed out of the two scripts themselves — never
# re-declared here, because a third copy of a constant is the bug this file exists
# to prevent — then overlaid with what the config would actually set:
#
#   file default  →  environment  →  global fleet.conf  →  per-fleet overlay
#
# matching fleet_load_conf's rule (the environment is the floor; a conf assignment
# overrides it). FLEET_STUCK_WORKING_SECS takes no per-fleet overlay: it is in
# fleet-lib.sh's _FLEET_GLOBAL_ONLY list, because ONE spinner daemon serves every
# fleet on the machine. (That daemon is launched by launchd/systemd and so reads
# the global conf, not a login shell's environment — an env value is counted here
# anyway, conservatively: better to flag a number the operator set than to hide it.)
#
# Usage:
#   fleet-handoff-invariant.sh [--session <sess>] [--quiet]
#                              [--spinner <file>] [--cycle <file>] [--conf <file>]
#
#   --session   resolve the per-fleet overlay for the handoff knobs too
#   --oneline   one compact summary line (what fleet-doctor.sh prints)
#   --quiet     exit code only
#   --spinner / --cycle / --conf   point at fixtures instead of the install
#                                  (bin/fleet-handoff-invariant-selftest.sh)
#
# Shell-options policy: EXECUTED, /bin/sh → set -u only.
set -u  # POSIX sh: pipefail is bash-only (dash has none)

BIN="$(cd "$(dirname "$0")" && pwd)"
SPINNER="$BIN/tmux-spinner.sh"
CYCLE="$BIN/fleet-handoff-cycle.sh"
GCONF="$BIN/../fleet.conf"
SESS='' QUIET=0 ONELINE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) SESS="${2:-}"; shift 2 ;;
    --quiet|-q) QUIET=1; shift ;;
    --oneline)  ONELINE=1; shift ;;
    --spinner) SPINNER="${2:-}"; shift 2 ;;
    --cycle)   CYCLE="${2:-}"; shift 2 ;;
    --conf)    GCONF="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,64p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

say() { [ "$QUIET" = 1 ] || [ "$ONELINE" = 1 ] || printf '%s\n' "$*"; }
SUM=''
one() { if [ -z "$SUM" ]; then SUM="$*"; else SUM="$SUM · $*"; fi; }
die() { [ "$QUIET" = 1 ] || printf 'fleet-handoff-invariant: %s\n' "$*" >&2; exit 2; }

[ -r "$SPINNER" ] || die "cannot read $SPINNER"
[ -r "$CYCLE" ]   || die "cannot read $CYCLE"

# --- reading the constants back out of the source ------------------------------
# _dflt <file> <VAR> <ENVVAR>  → the literal in  VAR="${ENVVAR:-<int>}"
# _plain <file> <VAR>          → the literal in  VAR=<int>
# Both take the FIRST match: these are single-assignment tunables at the head of
# each file. An empty result is a parse failure, never a 0 — see the checks below.
_dflt()  { sed -n 's/^[[:space:]]*'"$2"'="\${'"$3"':-\([0-9][0-9]*\)}".*/\1/p' "$1" | head -1; }
_plain() { sed -n 's/^[[:space:]]*'"$2"'=\([0-9][0-9]*\)[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$1" | head -1; }

# _conf_val <file> <KEY> → the LAST uncommented assignment's value (same reader
# fleet-doctor.sh uses): what sourcing the file would leave in KEY.
_conf_val() {
  [ -f "$1" ] || return 0
  sed -n 's/^[[:space:]]*'"$2"'[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p' "$1" | tail -1 | tr -d "\"' 	"
}

# _overlay <sess> → this fleet's conf file, new layout then legacy flat (#181).
_overlay() {
  [ -n "$1" ] || return 0
  d="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
  [ -f "$d/fleets/$1/conf" ] && { printf '%s\n' "$d/fleets/$1/conf"; return 0; }
  [ -f "$d/$1.conf" ] && printf '%s\n' "$d/$1.conf"
}

# _resolve <file-default> <ENVVAR> <per-fleet?0|1> → the effective value.
# Layered low→high: file default, environment, global conf, per-fleet overlay.
# A non-integer at any layer is ignored rather than collapsed to 0 — the two
# consumers both do exactly that with their own knobs.
OVERLAY="$(_overlay "$SESS")"
_resolve() {
  _v="$1"
  # POSIX indirect read of $2's value; pre-set so it is never "referenced unassigned".
  _e=''; eval "_e=\${$2:-}"
  case "$_e" in ''|*[!0-9]*) ;; *) _v="$_e" ;; esac
  _c="$(_conf_val "$GCONF" "$2")"
  case "$_c" in ''|*[!0-9]*) ;; *) _v="$_c" ;; esac
  if [ "$3" = 1 ] && [ -n "$OVERLAY" ]; then
    _c="$(_conf_val "$OVERLAY" "$2")"
    case "$_c" in ''|*[!0-9]*) ;; *) _v="$_c" ;; esac
  fi
  printf '%s\n' "$_v"
}

d_stuck=$(_dflt  "$SPINNER" STUCK_SECS FLEET_STUCK_WORKING_SECS)
d_sweep=$(_plain "$SPINNER" STUCK_CHECK_SECS)
d_idle=$(_dflt   "$CYCLE"   IDLE_TIMEOUT   FLEET_HANDOFF_IDLE_TIMEOUT)
d_vfy=$(_dflt    "$CYCLE"   VERIFY_TIMEOUT FLEET_HANDOFF_VERIFY_TIMEOUT)
d_hard=$(_dflt   "$CYCLE"   HARD_TIMEOUT   FLEET_HANDOFF_HARD_TIMEOUT)
for _p in "STUCK_SECS:$d_stuck" "STUCK_CHECK_SECS:$d_sweep" "IDLE_TIMEOUT:$d_idle" \
          "VERIFY_TIMEOUT:$d_vfy" "HARD_TIMEOUT:$d_hard"; do
  case "${_p#*:}" in '') die "could not read ${_p%%:*} out of the source — the tunable was renamed or reshaped; update this parser (issue #677)" ;; esac
done

# FLEET_STUCK_WORKING_SECS is global-only (_FLEET_GLOBAL_ONLY in fleet-lib.sh):
# one spinner serves the machine, so a per-fleet value would be a silent no-op.
stuck=$(_resolve "$d_stuck" FLEET_STUCK_WORKING_SECS 0)
idle=$(_resolve  "$d_idle"  FLEET_HANDOFF_IDLE_TIMEOUT   1)
vfy=$(_resolve   "$d_vfy"   FLEET_HANDOFF_VERIFY_TIMEOUT 1)
hard=$(_resolve  "$d_hard"  FLEET_HANDOFF_HARD_TIMEOUT   1)
sweep="$d_sweep"   # not a knob — a literal inside the spinner's frame loop

rc=0
tail_=$(( idle + vfy ))   # referenced by invariant 1's summary as well as invariant 2

# --- invariant 1: the backstop must land before WAIT-IDLE gives up --------------
# STUCK_SECS=0 DISABLES the backstop entirely (documented in fleet.conf.example).
# That is not "a large number" — it is NO number: a capped/crashed turn then pins
# @claude_state=working forever and auto-handoff can never fire again on that pane.
if [ "$stuck" -eq 0 ]; then
  say "handoff invariant: VIOLATED — stuck-working demotion is OFF (FLEET_STUCK_WORKING_SECS=0)"
  say "  nothing will ever clear a @claude_state=working pinned by a turn that never emitted Stop (#580),"
  say "  so /fleet-handoff WAIT-IDLE can only ever time out — auto-handoff is dead on this machine (#677)."
  one "stuck-working demotion is OFF (FLEET_STUCK_WORKING_SECS=0) — a turn that never emits Stop (#580) pins \`working\` forever, so auto-handoff can only ever time out (#677)"
  rc=1
else
  worst=$(( stuck + 2 * sweep ))
  margin=$(( idle - worst ))
  # A POSITIVE margin is not the same as a SAFE one, and #677 is about the
  # difference: shipped, the gap was 40s and nobody could see it from either file.
  # `worst` is a worst case only under a *nominal* sweep cadence, and the spinner
  # runs under launchd ProcessType=Background — the lowest CPU/IO tier. #653
  # measured a budgeted poll loop in that tier costing 1.9×–4.2× its nominal wall
  # clock at load 40+, so both throttled sweeps can slip badly exactly when a
  # machine is busy enough to be dropping Stop hooks in the first place. So require
  # headroom for two sweeps running at ~3× cadence (4 × STUCK_CHECK_SECS), with a
  # 60s floor so shortening the sweep cannot shrink the requirement to nothing.
  margin_min=$(( 4 * sweep )); [ "$margin_min" -lt 60 ] && margin_min=60
  case "${FLEET_HANDOFF_MARGIN_MIN:-}" in ''|*[!0-9]*) ;; *) margin_min="$FLEET_HANDOFF_MARGIN_MIN" ;; esac
  say "stuck demote (worst case) = ${worst}s   (FLEET_STUCK_WORKING_SECS=${stuck} + 2 × ${sweep}s sweep, 2-strike debounce)"
  say "handoff wait-idle ceiling = ${idle}s   (FLEET_HANDOFF_IDLE_TIMEOUT)"
  if [ "$margin" -ge "$margin_min" ]; then
    say "  → margin ${margin}s (need ≥ ${margin_min}s) — OK (the backstop lands before WAIT-IDLE aborts)"
    one "demote ≤${worst}s < ${idle}s wait-idle ceiling (${margin}s margin, need ≥ ${margin_min}s)"
  elif [ "$margin" -gt 0 ]; then
    say "  → margin ${margin}s — THIN: above zero, but under the ${margin_min}s needed to absorb a"
    say "    sweep that slips under load (the spinner runs ProcessType=Background, #653). One slow"
    say "    tick flips this into a silent no-handoff. Raise FLEET_HANDOFF_IDLE_TIMEOUT."
    one "demote ≤${worst}s vs ${idle}s wait-idle ceiling — only ${margin}s margin, need ≥ ${margin_min}s: one sweep slipping under load (#653) turns this into a SILENT no-handoff; raise FLEET_HANDOFF_IDLE_TIMEOUT (#677)"
    rc=1
  else
    say "  → margin ${margin}s — VIOLATED: WAIT-IDLE aborts BEFORE the spinner can demote,"
    say "    so a turn whose Stop hook never fired (a model cap, #580) can never hand off."
    say "    Fix: raise FLEET_HANDOFF_IDLE_TIMEOUT above ${worst}s, or lower FLEET_STUCK_WORKING_SECS."
    one "demote ≤${worst}s ≥ ${idle}s wait-idle ceiling — WAIT-IDLE aborts BEFORE the spinner can demote, so a capped turn (#580) SILENTLY never hands off; raise FLEET_HANDOFF_IDLE_TIMEOUT above ${worst}s (#677)"
    rc=1
  fi
fi

# --- invariant 2: WAIT-IDLE + VERIFY must fit inside the cycle's own watchdog ----
# The hard watchdog TERMs the process group; a clear that is typed and then killed
# before VERIFY confirms leaves the pane cleared with nobody sending the pickup.
if [ "$tail_" -lt "$hard" ]; then
  say "wait-idle + verify     = ${tail_}s < ${hard}s hard timeout — OK ($(( hard - tail_ ))s spare)"
  one "wait-idle+verify ${tail_}s < ${hard}s watchdog"
else
  say "wait-idle + verify     = ${tail_}s ≥ ${hard}s hard timeout — VIOLATED: the watchdog can TERM"
  say "  the cycle mid-VERIFY, after /clear was already typed. Raise FLEET_HANDOFF_HARD_TIMEOUT."
  one "wait-idle+verify ${tail_}s ≥ ${hard}s hard timeout — the watchdog can TERM the cycle mid-VERIFY, after /clear was typed; raise FLEET_HANDOFF_HARD_TIMEOUT (#677)"
  rc=1
fi

[ "$ONELINE" = 1 ] && [ "$QUIET" = 0 ] && printf '%s\n' "$SUM"
exit "$rc"
