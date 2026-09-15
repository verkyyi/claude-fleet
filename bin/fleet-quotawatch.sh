#!/bin/bash
# fleet-quotawatch.sh — the ccquota-driven PRE-EMPTIVE account rotation, as its
# OWN ~60s tick (issue #551). Reads every pool account's exact 5h/7d utilization
# off the ccquota hub and, per account, warns its sessions at
# FLEET_ACCOUNT_WARN_PCT and benches + moves them at FLEET_ACCOUNT_CEILING —
# BEFORE the subscription wall (issue #513's policy, unchanged).
#
# Why its own tick (#551): this policy used to be the LAST block of the dash
# collector's tick, after the per-repo gh fetches, the git/ctx/usage scans and
# the pane scrapes. On a 21-window fleet a tick ran 2–3 minutes, and a tick that
# stalled (an un-timeboxed `gh` on a bad network) or died before its end simply
# never reached the quota block — the cache went 2.5h stale, the 70%/85% branches
# never ran, and every session on the account rode the 5-hour window to 100%.
# The watch is now (a) this script on its own launchd/systemd 60s unit
# (com.claude-fleet.quotawatch) and (b) ALSO the first thing every collector tick
# runs — so an install whose daemon set predates #551 keeps the watch at the
# collector's cadence, and a healthy install gets a real 60s cadence that no gh
# latency can push around. Both callers are safe together: the once-per-reset-
# window markers dedup the actions, `fleet-account.sh quota` refetches at most
# every FLEET_ACCOUNT_QUOTA_TTL s, and the lock below serializes overlapping ticks.
#
# What it writes (all under $TMPDIR/.claude-dash/global/):
#   account.quota(.ts)      — via `fleet-account.sh quota` (the TTL-gated fetch)
#   quota.warn.<label>      — reset epoch the 70% warning was sent for
#   quota.ceiling.<label>   — reset epoch the 85% bench+move was done for
#   quota.phase             — reset epoch the 5h phase stagger was planned for
#                             (issue #598; only with FLEET_ACCOUNT_PHASE_AUTO=1)
#   quotawatch.heartbeat    — key=value: pid/caller/start/phase/end/dur/rows/
#                             fetched, plus the per-phase breakdown t_modelcap/
#                             t_fetch/t_policy (issue #582) and budget/over/
#                             skipped — the tick's own budget, what blew its
#                             budget and was killed, and what the tick budget
#                             deferred to the next tick (issue #698)
#   quotawatch.lock/        — mkdir lock (pid + ts inside) — overlap guard,
#                             released only by the tick that still holds it (#582)
#   quotawatch.sweep.start  — fairness cursor: the fleet whose cap probe was cut
#                             short last tick, swept first on the next one (#582)
#   quotawatch.modelcap.<fleet> — that fleet's cap-probe health: streak= of
#                             consecutive timeouts, lastok= when it last finished,
#                             step= where the last timeout died (#706)
#   quotawatch.probe.trace.<fleet> — the live breadcrumb of that fleet's cap
#                             probe, read off its corpse when the budget kills it
#                             (#706). Deliberately NOT under the .modelcap.
#                             prefix: fleet-doctor globs that one by fleet name.
#
# Staleness alarm (#551): `account.quota.ts` is the watch's liveness — every tick
# restamps it even when the hub is unreachable (empty rows still refresh the
# stamp). Once it is older than FLEET_ACCOUNT_QUOTA_STALE (default 600s = 10×
# the TTL) while the pool + hub are configured, the watch is BLIND: the status
# bar shows `⚠ quota stale 47m` (bin/tmux-status.sh via usage-lib.sh),
# fleet-doctor FAILs, and the next tick that does run notifies once that it was
# blind for that long. `--status` prints the same verdict for scripts.
#
# SECOND job — the PER-MODEL cap sweep (issue #569). A model cap ("You've reached
# your Fable limit …", #524) is detected by the dash collector's banner phase, and
# that phase sits behind the whole tick: on a monorepo fleet the git scan alone ran
# 551 s, so nine walled workers idled for the better part of an hour on
# 2026-09-12 while the recovery trickled through one cold `--resume` at a time. The
# detection belongs on a fast tick, and the recovery does not need a restart at all
# — so every tick now also runs `fleet-model-switch.sh --capped` per fleet, which
# types `/model <fallback>` at each walled session's own prompt (~5 s, process and
# background agents and context all kept) and only falls back to
# `fleet-migrate.sh --model` when it cannot verify the flip. Reaction time goes
# from a tick of unbounded length to ≤60 s. The collector's #524 branch stays as
# the backstop for installs whose daemon set predates this; `@model_migrating`
# (180 s) and the pane's own status line keep the two callers from double-typing.
#
# BUDGETS (issue #582). The cap sweep is the unbounded half of this tick: ~8 tmux
# round-trips per window per fleet, and on a loaded server one `display-message`
# can block for minutes — so on 2026-09-13 a tick sat in a single probe for 26
# MINUTES against a 120 s deadline. It could not be superseded (bash defers a
# trapped signal until the foreground command returns) and, when it finally died,
# its unconditional lock release deleted its successor's lock — so ticks piled up
# three-deep on the same tmux server, each making the others slower. The unit
# looked healthy the whole time (`launchctl list` → exit 0) while the launchd log
# filled with `skip — still running` and the quota stamp aged past STALE: the
# pre-emptive rotation this script exists for was BLIND. Now: each fleet's probe
# runs under FLEET_QUOTAWATCH_PROBE_BUDGET (20 s, tree-killed on expiry), the
# phase as a whole under FLEET_QUOTAWATCH_SWEEP_BUDGET (40 s), whatever is left
# over is swept first next tick, and the ccquota fetch — the cheap half, ~1 s,
# and the one whose stamp is the liveness signal — can no longer be starved by it.
#
# THIRD, a side errand — the COLLECTOR's self-heal (issue #636). launchd can
# PEND com.claude-fleet.collect indefinitely (103 minutes, observed, `last exit
# code = 0`), which freezes every number on the dash without emptying it. Every
# tick therefore asks bin/fleet-collect-kick.sh whether the collector's heartbeat
# has gone stale and, if so, kicks its unit — rate-limited, logged, and traced on
# the status bar. Runs before the gates below: a fleet with no accounts pool
# still has a dash. This is a backstop, not the primary path: the same launchd
# stall pends THIS unit too, which is why the kick also lives in the status bar
# and in the KeepAlive spinner.
#
# FOURTH, the tick's OWN budget (issue #698). Everything above bounds a PIECE of
# the tick — a probe, the sweep phase, a superseded predecessor. Nothing bounded
# the tick itself. FLEET_QUOTAWATCH_DEADLINE (120 s) reads like a budget and is
# not one: it appears only in the overlap guard, where it tells a SUCCESSOR that
# the tick holding the lock is stuck and may be superseded. The successor is the
# problem — launchd's StartInterval does not overlap a job, so while a slow tick
# is running there IS no next tick to come and judge it, and #671 (correctly)
# gates the collector's in-tick fallback off whenever this unit is running. The
# one thing that could enforce the 120 s was structurally absent exactly when it
# was needed. Live, on 2026-09-15 06:42 — with #688 already applied, so this was
# not the #682 wedge — a tick ran 5m45s against that 120 s: not stuck, PROGRESSING,
# and unbounded.
#
# So the tick now budgets itself, the way the collector does (#653's
# FLEET_COLLECT_TICK_BUDGET): FLEET_QUOTAWATCH_TICK_BUDGET is checked before every
# phase and before every ITERATION of the two loops, each phase's own budget is
# CLAMPED to what the tick has left, and the individual calls a loop iteration
# makes — every tmux round-trip in the policy loop, the ccquota fetch — carry a
# budget of their own. Without that last part the per-iteration check is theatre:
# one `tmux display-message` that never returns (57 s observed, #582) defeats any
# number of checks between iterations.
#
# WIND DOWN, never self-kill. At the budget the tick stops STARTING work, writes
# its heartbeat, releases the lock and exits 0; whatever it did not reach is left
# for the next tick 60 s later, which is safe because the sweep has its fairness
# cursor and the policy's once-per-window markers are written only for an account
# that was actually handled. A `kill $$` at the deadline would be the #582
# regression: this process holds the LOCK, and only its EXIT trap releases it.
#
# THE BUDGET MUST STAY BELOW THE DEADLINE, and that is pinned in code rather than
# left to two defaults agreeing (issue #686's lesson). QW_WINDDOWN is the margin
# the wind-down gets: a phase may overshoot its budget by fleet_timebox's poll
# granularity plus the kill grace, and the tick must still be finished before a
# successor would call it stuck and tree-kill it mid-wind-down. Set them
# inconsistently and TICK_BUDGET is clamped down, loudly — never DEADLINE up.
#
# Fail-open, per job: the model sweep needs only an accounts pool (the cap ledger
# is per-account), the ccquota policy needs a hub URL too. Neither configured →
# exit 0 and nothing here runs (the collector self-heal above still does).
#
# Usage:
#   fleet-quotawatch.sh [--caller <name>] [--dry-run]
#   fleet-quotawatch.sh --status        # off | never | fresh | stale  <TAB> age-s
#
# Env: FLEET_QUOTAWATCH_TICK_BUDGET (100) FLEET_QUOTAWATCH_DEADLINE (120)
#      FLEET_QUOTAWATCH_PROBE_BUDGET (20) FLEET_QUOTAWATCH_SWEEP_BUDGET (40)
#      FLEET_QUOTAWATCH_FETCH_BUDGET (30) FLEET_QUOTAWATCH_POLICY_BUDGET (40)
#      FLEET_QUOTAWATCH_KICK_BUDGET (15) FLEET_QUOTAWATCH_TMUX_BUDGET (10)
#      FLEET_ACCOUNT_QUOTA_STALE (600)
# Read by fleet-doctor, not here: FLEET_QUOTAWATCH_MODELCAP_STREAK (3).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"         # fleet_quota_stale_age / fleet_quota_watch_configured

C="${TMPDIR:-/tmp}/.claude-dash"; G="$C/global"; mkdir -p "$G"
now() { date +%s; }
atomic_write() { local dest="$1" tmp="$1.$$"; cat > "$tmp" && mv "$tmp" "$dest"; }

CALLER=daemon; DRY=0; STATUS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --caller)  CALLER="${2:-daemon}"; shift ;;
    --dry-run) DRY=1 ;;
    --status)  STATUS=1 ;;
    -h|--help) sed -n '2,80p' "$0"; exit 0 ;;
    *) printf 'fleet-quotawatch: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# The tick's OWN clock starts HERE, before the collector self-heal, before the
# lock, before anything that can block (issue #698) — a budget that starts after
# the expensive part is not a budget. `SECONDS` is the bash builtin: same wall
# clock as `date +%s`, no fork, which is what #682 found to be load-bearing when
# the machine is starved enough for a budget to matter.
TICK_T0=$SECONDS

# --- scheduling heartbeat (issue #639) ---------------------------------------
# ONLY the daemon's own tick stamps. The collector runs this watch first thing
# every tick (`--caller collect`), which is why #551 gave the watch its own 60s
# unit — and why the heartbeat below cannot answer "did MY unit run?": #639 found
# a quotawatch.heartbeat that looked perfectly fresh and read `caller=collect`
# throughout, i.e. the independence #551 bought had silently lapsed while
# com.claude-fleet.quotawatch was pended. A stamp that credited the collector's
# invocation would reproduce exactly that blind spot, so it does not.
#
# Only a WORKING tick counts, which rules out more than the collector: `--status`
# is a pure query and fleet-doctor runs it on every invocation, so crediting it
# would have fleet-doctor itself refreshing the stamp that is supposed to tell it
# this unit has stopped. `--dry-run` is excluded on the same principle.
# The source is GUARDED and the stamp is a side errand: liveness instrumentation
# must never be able to kill the daemon it instruments. A half-synced install
# missing the lib then costs this unit its alarm (it reads `never`, which is
# silent by design) instead of costing the fleet the daemon.
# shellcheck source=/dev/null
if [ "$CALLER" != collect ] && [ "$STATUS" = 0 ] && [ "$DRY" = 0 ] \
   && [ -f "$BIN/fleet-daemon-lib.sh" ]; then
  . "$BIN/fleet-daemon-lib.sh"; fleet_daemon_stamp_tick quotawatch "$BIN/.."
fi

QTS="$G/account.quota.ts"
QDIAG="$G/quota.diag"                                 # last tick's quota_parse complaints (#628)
HB="$G/quotawatch.heartbeat"
LOCK="$G/quotawatch.lock"
STALE="${FLEET_ACCOUNT_QUOTA_STALE:-600}"
DEADLINE="${FLEET_QUOTAWATCH_DEADLINE:-120}"   # a tick past this is stuck → superseded
# Budgets for the model-cap sweep (issue #582) — the tick's unbounded half. The
# sweep makes ~8 tmux round-trips per window per fleet (23 windows on the monorepo
# fleet ⇒ ~180 client invocations), and on a loaded server a SINGLE
# `tmux display-message` can block for minutes: one was observed stuck for 57 s,
# inside a probe that had been running for 24. Unbudgeted, one wedged fleet
# starves the ccquota fetch below — the fetch that writes the stamp `--status`
# reads — so the watch goes stale and the pre-emptive rotation goes BLIND while
# the launchd unit still reports exit 0. Both budgets are per-TICK and
# best-effort: whatever is skipped is swept by the next tick, 60 s later.
PROBE_BUDGET="${FLEET_QUOTAWATCH_PROBE_BUDGET:-20}"   # one fleet's cap probe
SWEEP_BUDGET="${FLEET_QUOTAWATCH_SWEEP_BUDGET:-40}"   # the whole modelcap phase
SWEEP_START="$G/quotawatch.sweep.start"               # fairness rotation cursor
# Per-fleet cap-probe health (issue #706): a timeout STREAK and the last time the
# probe actually finished. The probe's outcome used to live only in this log, so a
# fleet whose model-cap detection had been blind for 788 ticks looked exactly like
# a healthy one to `fleet-doctor`. One file per fleet; the session name is already
# filename-safe (it IS the socket label).
MODELCAP_STATE="$G/quotawatch.modelcap"
# The tick's SELF-budget and the per-phase budgets it clamps (issue #698 — see the
# header). Every one of these is per-tick and best-effort: what a tick does not
# reach, the next tick 60 s later does.
TICK_BUDGET="${FLEET_QUOTAWATCH_TICK_BUDGET:-100}"    # the whole tick winds down here
FETCH_BUDGET="${FLEET_QUOTAWATCH_FETCH_BUDGET:-30}"   # the ccquota read
POLICY_BUDGET="${FLEET_QUOTAWATCH_POLICY_BUDGET:-40}" # the whole warn/bench/move loop
KICK_BUDGET="${FLEET_QUOTAWATCH_KICK_BUDGET:-15}"     # the collector self-heal errand
TMUX_BUDGET="${FLEET_QUOTAWATCH_TMUX_BUDGET:-10}"     # ONE tmux round-trip in the policy
QW_WINDDOWN=20   # margin between TICK_BUDGET and DEADLINE, for the last phase's tail
PHASE_MIN=5      # less headroom than this left ⇒ do not start the next phase/row at all
for _v in TICK_BUDGET FETCH_BUDGET POLICY_BUDGET KICK_BUDGET TMUX_BUDGET DEADLINE; do
  case "${!_v}" in ''|*[!0-9]*) printf 'fleet-quotawatch: %s is not a number (%s) — ignoring it\n' "$_v" "${!_v}" >&2
    case "$_v" in
      TICK_BUDGET) TICK_BUDGET=100 ;; FETCH_BUDGET) FETCH_BUDGET=30 ;; POLICY_BUDGET) POLICY_BUDGET=40 ;;
      KICK_BUDGET) KICK_BUDGET=15 ;; TMUX_BUDGET) TMUX_BUDGET=10 ;; DEADLINE) DEADLINE=120 ;;
    esac ;;
  esac
done
# THE INVARIANT, enforced rather than assumed: the tick must be DONE before a
# successor would call it stuck. Clamp the budget down; never raise the deadline.
if [ $(( TICK_BUDGET + QW_WINDDOWN )) -gt "$DEADLINE" ]; then
  _tb=$(( DEADLINE - QW_WINDDOWN )); [ "$_tb" -lt "$PHASE_MIN" ] && _tb="$PHASE_MIN"
  printf 'fleet-quotawatch: FLEET_QUOTAWATCH_TICK_BUDGET (%ss) + the %ss wind-down margin exceeds FLEET_QUOTAWATCH_DEADLINE (%ss) — a tick would still be running when its successor superseded it; clamping the budget to %ss\n' \
    "$TICK_BUDGET" "$QW_WINDDOWN" "$DEADLINE" "$_tb" >&2
  TICK_BUDGET="$_tb"
fi

# THE SECOND INVARIANT — the sweep can never starve the ccquota fetch (#582, now
# pinned instead of assumed). That was the whole point of giving the modelcap phase
# a budget: the fetch is the cheap half (~1 s) and the one whose stamp every
# staleness alarm reads, and the sweep runs FIRST because a walled worker is the
# most urgent thing this daemon fixes (#569). With four independent knobs it held
# only by arithmetic luck — 40 + 30 + 40 already sums past a 100 s tick — so the
# sweep is clamped to leave the fetch its full budget plus the room to start it.
_sweep_cap=$(( TICK_BUDGET - FETCH_BUDGET - PHASE_MIN ))
if [ "$_sweep_cap" -lt "$PHASE_MIN" ]; then _sweep_cap="$PHASE_MIN"; fi
case "$SWEEP_BUDGET" in ''|*[!0-9]*) SWEEP_BUDGET=40 ;; esac
case "$PROBE_BUDGET" in ''|*[!0-9]*) PROBE_BUDGET=20 ;; esac
if [ "$SWEEP_BUDGET" -gt "$_sweep_cap" ]; then
  printf 'fleet-quotawatch: FLEET_QUOTAWATCH_SWEEP_BUDGET (%ss) leaves the ccquota fetch less than its %ss budget inside a %ss tick — the sweep would starve the liveness stamp (#582); clamping the sweep to %ss\n' \
    "$SWEEP_BUDGET" "$FETCH_BUDGET" "$TICK_BUDGET" "$_sweep_cap" >&2
  SWEEP_BUDGET="$_sweep_cap"
fi

# tick_left — seconds of the tick's own budget still unspent (never negative).
tick_left() {
  local spent=$(( SECONDS - TICK_T0 ))
  [ "$spent" -ge "$TICK_BUDGET" ] && { printf '0'; return 0; }
  printf '%s' $(( TICK_BUDGET - spent ))
}
# qw_left <phase-start-SECONDS> <phase-budget> — how long the next unit of work in
# this phase may run: the SMALLER of what the phase's own budget has left and what
# the whole tick has left. The clamp is the half that matters — without it a call
# starting one second before the tick's budget could still add its full budget on
# top, and the tick would overrun by exactly the amount the budget was meant to
# prevent.
qw_left() {
  local p0="$1" b="$2" pleft left
  pleft=$(( b - ( SECONDS - p0 ) )); [ "$pleft" -lt 0 ] && pleft=0
  left=$(tick_left); [ "$pleft" -lt "$left" ] && left="$pleft"
  printf '%s' "$left"
}
# tick_room — is there enough of the TICK's budget left to START another phase or
# row at all? Kept separate from qw_left on purpose: PHASE_MIN is a floor on the
# tick's remaining room (starting work with two seconds left buys nothing and
# pushes the tail toward the deadline), NOT a floor on a phase's own budget — an
# operator who sets a 2 s fetch budget means 2 s, not "too small, skip it".
tick_room() { [ "$(tick_left)" -ge "$PHASE_MIN" ]; }
QW_SKIP=""   # what the TICK budget deferred to the next tick
QW_OVER=""   # what spent its OWN budget and was killed

# --status: off (pool/hub not configured) | never (configured, no stamp yet) |
# fresh | stale, then TAB + the stamp's age in seconds (0 for off/never).
if [ "$STATUS" = 1 ]; then
  if ! fleet_quota_watch_configured; then printf 'off\t0\n'; exit 0; fi
  ts=$(cat "$QTS" 2>/dev/null); case "$ts" in ''|*[!0-9]*) ts=0;; esac
  if [ "$ts" -eq 0 ]; then printf 'never\t0\n'; exit 0; fi
  age=$(( $(now) - ts ))
  if [ -n "$(fleet_quota_stale_age)" ]; then printf 'stale\t%s\n' "$age"; else printf 'fresh\t%s\n' "$age"; fi
  exit 0
fi

# --- side errand: the COLLECTOR's self-heal (issue #636) ----------------------
# Runs BEFORE this script's own fail-open gates and before its heavy phases, and
# is deliberately not gated on either job: an install with no accounts pool still
# has a dash, and the dash still freezes when the collector stops. This is the
# SECOND-best discoverer, not the primary one — on 2026-09-14 launchd pended
# every StartInterval unit in the domain at once, this one included, so the
# reliable pair is the status bar (while attached) and the KeepAlive spinner
# (always). It still covers the case this daemon is alive and the collector alone
# is wedged, which is cheap enough to be worth having. Skipped when the COLLECTOR
# itself is the caller (it is mid-tick by definition, so it cannot be stale). The
# pre-filter is two file reads; the rate limit, the log and the dash trace all
# live in the kick script. Never fatal.
# Budgeted like everything else (issue #698): the errand ends in `launchctl
# kickstart`, and a launchd domain wedged badly enough to need a kick is exactly
# the one that can leave that call hanging — this tick's job is the quota watch,
# not waiting on someone else's daemon.
if [ "$CALLER" != collect ] && [ "$DRY" = 0 ] && fleet_collect_kick_due; then
  _kb=$(qw_left "$SECONDS" "$KICK_BUDGET")
  if ! tick_room || [ "$_kb" -lt 1 ]; then
    QW_SKIP="${QW_SKIP}${QW_SKIP:+ }collectkick"
  else
    fleet_timebox "$_kb" bash "$BIN/fleet-collect-kick.sh" || {
      [ "$?" = 124 ] && { QW_OVER="${QW_OVER}${QW_OVER:+ }collectkick"
        printf 'fleet-quotawatch: the collector self-heal kick hit its %ss budget (FLEET_QUOTAWATCH_KICK_BUDGET) — killed; this tick runs on\n' "$_kb" >&2; }
      true
    }
  fi
fi

# Fail-open gates — one per job (#569). The MODEL sweep needs only an accounts
# pool: a per-model cap is recorded per account and recovered in place, neither of
# which touches ccquota. The ccquota POLICY additionally needs a hub URL — that is
# fleet_quota_watch_configured, identical to the collector's pre-#551 gate, and it
# alone still governs `--status`, the liveness stamp and the blind-spell alarm.
ACCT_DIR="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}"
MODEL_SWEEP=0; [ -d "$ACCT_DIR" ] && MODEL_SWEEP=1
QUOTA_POLICY=0; fleet_quota_watch_configured && QUOTA_POLICY=1
[ "$MODEL_SWEEP" = 1 ] || [ "$QUOTA_POLICY" = 1 ] || exit 0

# --- overlap guard: one tick at a time; a stuck one is superseded past DEADLINE.
# mkdir is the atomic primitive (no flock on macOS). The holder's pid + start
# epoch sit inside; a dead holder (crash without cleanup) or one past the
# deadline is taken over — and killed, so a wedged `ccquota` can't pin the lock.
if ! mkdir "$LOCK" 2>/dev/null; then
  opid=$(cat "$LOCK/pid" 2>/dev/null); ots=$(cat "$LOCK/ts" 2>/dev/null)
  case "$opid" in ''|*[!0-9]*) opid='';; esac
  case "$ots" in ''|*[!0-9]*) ots=0;; esac
  if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null \
     && ps -o command= -p "$opid" 2>/dev/null | grep -q 'fleet-quotawatch'; then
    age=$(( $(now) - ots ))
    if [ "$age" -lt "$DEADLINE" ]; then
      printf 'fleet-quotawatch: skip — tick %s still running (%ss)\n' "$opid" "$age" >&2
      exit 0
    fi
    printf 'fleet-quotawatch: tick %s past the %ss deadline (%ss) — superseding it\n' "$opid" "$DEADLINE" "$age" >&2
    # Kill the TREE, not just the script (issue #582). bash DEFERS a trapped
    # signal until the current foreground command returns, so a tick sitting in
    # `x=$(tmux …)` ignores its supersede for as long as that tmux takes — one
    # survived 26 MINUTES against this 120 s deadline — and meanwhile its tmux
    # clients keep loading the very server that wedged it. TERM the tree, brief
    # grace, SIGKILL the survivors.
    # SAY SO if the supersede did not take (issue #682). This path used to assume
    # the kill worked and take the lock regardless; a tree that outlived SIGKILL
    # means two ticks are live against one tmux server, which is the pileup #582
    # was about — and it must be in the log, not inferred later from `ps`.
    if ! fleet_kill_tree "$opid" 2; then
      printf 'fleet-quotawatch: supersede could NOT kill tick %s — it outlived SIGKILL; taking the lock anyway, so two ticks may now be live\n' "$opid" >&2
    fi
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || exit 0        # lost the takeover race → the other tick has it
fi
printf '%s' "$$" > "$LOCK/pid"; now > "$LOCK/ts"
# Release ONLY a lock we still hold (issue #582). The release used to be an
# unconditional `rm -rf "$LOCK"`, so a superseded-but-still-alive tick deleted its
# SUCCESSOR's lock the moment it finally died — admitting a third tick alongside
# the second. That is the pileup in the launchd log: three concurrent cap probes
# against one tmux server, each making the others slower, which wedges the next.
release_lock() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"; return 0; }
trap 'release_lock' EXIT
trap 'exit 143' INT TERM                       # so the EXIT trap (lock release) runs on a supersede

START=$(now)
hb() {  # $1 = phase, $2 = extra key=value lines (optional)
  printf 'pid=%s\ncaller=%s\nstart=%s\nphase=%s\nphase_ts=%s\n%s' "$$" "$CALLER" "$START" "$1" "$(now)" "${2:-}" | atomic_write "$HB"
}

SOCKETS=$(fleet_sockets)

# --- the PER-MODEL cap sweep (issue #569) -------------------------------------
# Runs FIRST and on every tick: it is capture-pane only until it finds something,
# it needs no network, and a walled worker is the most urgent thing this daemon
# can fix. The dry run is the cheap probe (no keystrokes, no sleeps); only a fleet
# with at least one candidate gets the real pass, and that one is backgrounded via
# fleet_bg so the ~5 s-per-window typing can never eat into DEADLINE. run-shell
# sets $TMUX for the job, so the switch's bare tmux calls stay on THIS fleet's
# server. fleet_bg, not a hand-rolled `run-shell -b` (issue #575): the switch
# prints a per-window report on stdout, and run-shell paints a backgrounded job's
# stdout over the operator's window as an Esc-to-dismiss view — fleet_bg silences
# it centrally; --toast still reports on the status line.
# modelcap_health <fleet> <ok|timeout> <step> — keep the per-fleet cap-probe
# streak fleet-doctor reads (issue #706). A single timeout is noise (a loaded
# tmux server, a tick that started with almost no budget left); a STREAK is the
# thing worth a verdict, because it means that fleet's model-cap detection — and
# so fleet-model-switch.sh --capped, and so every walled worker on it — has been
# dark the whole time. Cheap enough to run every tick: two small file writes.
modelcap_health() {
  local f="$MODELCAP_STATE.$1" st=0 lo=0
  [ -f "$f" ] && { st=$(sed -n 's/^streak=//p' "$f" | head -1); lo=$(sed -n 's/^lastok=//p' "$f" | head -1); }
  case "$st" in ''|*[!0-9]*) st=0 ;; esac
  case "$lo" in ''|*[!0-9]*) lo=0 ;; esac
  if [ "$2" = ok ]; then st=0; lo=$(now); else st=$(( st + 1 )); fi
  printf 'streak=%s\nlastok=%s\nstep=%s\nat=%s\n' "$st" "$lo" "${3:-}" "$(now)" > "$f" 2>/dev/null || :
}

T_MODEL=0; T_FETCH=0; T_POLICY=0; MTIMES=""; DEFERRED=""
if [ "$MODEL_SWEEP" = 1 ] && [ -x "$BIN/fleet-model-switch.sh" ]; then
  hb "modelcap"
  m0=$(now)
  # Fairness rotation (issue #582): start from the fleet the LAST tick ran out of
  # budget on, so a chronically slow fleet cannot permanently starve the ones
  # behind it in fleet_sockets' fixed order. The cursor is cleared every tick and
  # re-armed only by a defer or a timeout below.
  msweep="$SOCKETS"; mfirst=$(cat "$SWEEP_START" 2>/dev/null)
  if [ -n "$mfirst" ] && printf '%s\n' "$SOCKETS" | grep -qxF "$mfirst"; then
    msweep=$(printf '%s\n' "$SOCKETS" | grep -xF "$mfirst"; printf '%s\n' "$SOCKETS" | grep -vxF "$mfirst")
  fi
  : > "$SWEEP_START"
  ms0=$SECONDS
  for ms in $msweep; do
    # Phase budget, now CLAMPED to the tick's own (issue #698): stop probing once
    # the sweep has spent SWEEP_BUDGET *or* the tick has nothing left to give it.
    # SWEEP_BUDGET < TICK_BUDGET is what reserves room for the ccquota fetch below
    # — the cheap half, and the one whose stamp is the liveness signal (#582).
    mleft=$(qw_left "$ms0" "$SWEEP_BUDGET")
    if [ "$mleft" -lt 1 ] || ! tick_room; then
      DEFERRED="$DEFERRED $ms"; [ -s "$SWEEP_START" ] || printf '%s' "$ms" > "$SWEEP_START"
      continue
    fi
    mpb="$PROBE_BUDGET"; [ "$mpb" -gt "$mleft" ] && mpb="$mleft"   # the phase/tick budget wins
    p0=$(now)
    # The breadcrumb (issue #706). fleet_timebox tree-KILLS the probe on expiry, so
    # nothing the probe was about to print survives — which is why a timeout used
    # to be the whole diagnosis, for 69% of all ticks, with no way to tell a slow
    # tmux from a slow ledger read without re-measuring by hand. The probe rewrites
    # this file at every step boundary; we read it off its corpse.
    mtr="$G/quotawatch.probe.trace.$ms"; : > "$mtr" 2>/dev/null || :
    mout=$(FLEET_MODEL_SWITCH_TRACE="$mtr" fleet_timebox "$mpb" "$BIN/fleet-model-switch.sh" --capped --dry-run --session "$ms" 2>/dev/null); mrc=$?
    if [ "$mrc" = 124 ]; then
      # Report it honestly rather than letting it eat the tick (issue #582): the
      # probe and every tmux client under it are dead, and this fleet goes first
      # on the next tick.
      mstep=$(sed -n 's/^step=//p' "$mtr" 2>/dev/null | head -1)
      mwin=$(sed -n 's/^win=//p' "$mtr" 2>/dev/null | head -1)
      msteps=$(sed -n 's/^steps=//p' "$mtr" 2>/dev/null | head -1)
      MTIMES="$MTIMES $ms=timeout@${mstep:-?}${mwin:+ ($mwin w)}"
      QW_OVER="${QW_OVER}${QW_OVER:+ }modelcap:$ms"
      [ -s "$SWEEP_START" ] || printf '%s' "$ms" > "$SWEEP_START"
      modelcap_health "$ms" timeout "${mstep:-?}"
      printf 'fleet-quotawatch: modelcap probe on %s hit its %ss budget in step %s (window %s) — killed, not swept this tick [%s]\n' \
        "$ms" "$mpb" "${mstep:-?}" "${mwin:-?}" "${msteps:-no step timings}" >&2
      continue
    fi
    modelcap_health "$ms" ok ""
    MTIMES="$MTIMES $ms=$(( $(now) - p0 ))s"
    mplan=$(printf '%s\n' "$mout" | grep -c '^  would:')
    case "$mplan" in ''|*[!0-9]*) mplan=0 ;; esac
    [ "$mplan" -gt 0 ] || continue
    if [ "$DRY" = 1 ]; then
      printf 'would: switch %s walled window(s) on %s in place (/model <fallback>)\n' "$mplan" "$ms"
      continue
    fi
    printf 'fleet-quotawatch: %s walled window(s) on %s — switching in place\n' "$mplan" "$ms" >&2
    fleet_bg -L "$ms" "bash '$BIN/fleet-model-switch.sh' --capped --session '$ms' --toast"
  done
  T_MODEL=$(( $(now) - m0 ))
  if [ -n "$DEFERRED" ]; then
    QW_SKIP="${QW_SKIP}${QW_SKIP:+ }modelcap"
    printf 'fleet-quotawatch: modelcap phase spent its %ss budget (%ss) — deferred to the next tick:%s\n' "$SWEEP_BUDGET" "$T_MODEL" "$DEFERRED" >&2
  fi
fi

if [ "$QUOTA_POLICY" != 1 ]; then
  END=$(now)
  hb "done" "end=$END"$'\n'"dur=$(( END - START ))"$'\n'"modelsweep=1"$'\n'"t_modelcap=$T_MODEL"$'\n'"budget=$TICK_BUDGET"$'\n'"over=$QW_OVER"$'\n'"skipped=$QW_SKIP"$'\n'
  printf 'fleet-quotawatch: tick done in %ss — modelcap %ss [%s ], no ccquota policy (no hub)%s%s\n' \
    "$(( END - START ))" "$T_MODEL" "${MTIMES:- none}" "${QW_OVER:+, over: $QW_OVER}" "${QW_SKIP:+, deferred: $QW_SKIP}" >&2
  exit 0
fi

# --- blind-spell alarm: how old was the stamp BEFORE this tick? A stamp older
# than STALE (and not "never": a fresh install has no stamp) means no tick ran
# for that long — say so once, now that one is running, so the gap is visible in
# the notifier's history and not only on the status bar while it lasted.
pre_ts=$(cat "$QTS" 2>/dev/null); case "$pre_ts" in ''|*[!0-9]*) pre_ts=0;; esac
blind=0
if [ "$pre_ts" -gt 0 ] && [ $(( START - pre_ts )) -ge "$STALE" ]; then blind=$(( START - pre_ts )); fi

hb "fetch"
f0=$(now)
# stderr is KEPT (issue #628): quota_parse complains there about an account
# ccquota cannot read (available=false) and about a payload shape it does not
# understand — the rows themselves can only say it by being absent. Deduped
# against the last tick's text so a persistent condition costs one line, not one
# per 60 s, and a change (including back to clean) is always announced.
qdiagf="$G/quota.diag.$$.new"    # NOT quota.diag.$$ — that is atomic_write's own temp
# Budgeted (issue #698). This is the tick's one NETWORK call: a hub that accepts
# the connection and then never answers used to hang the tick with nothing at all
# to stop it, and this is the phase whose stamp every staleness alarm reads. A
# fetch that blows its budget leaves $qrows empty, which the policy below already
# treats as "nothing known, do nothing" — the safe direction.
fb=$(qw_left "$SECONDS" "$FETCH_BUDGET")
if ! tick_room || [ "$fb" -lt 1 ]; then
  QW_SKIP="${QW_SKIP}${QW_SKIP:+ }fetch"
  printf 'fleet-quotawatch: no room left in the %ss tick budget for the ccquota fetch — skipped, the next tick refetches\n' "$TICK_BUDGET" >&2
  qrows=""; : > "$qdiagf"
else
  qrows=$(fleet_timebox "$fb" "$BIN/fleet-account.sh" quota 2>"$qdiagf"); qrc=$?
  if [ "$qrc" = 124 ]; then
    QW_OVER="${QW_OVER}${QW_OVER:+ }fetch"
    printf 'fleet-quotawatch: the ccquota fetch hit its %ss budget (FLEET_QUOTAWATCH_FETCH_BUDGET) — killed, no rows this tick\n' "$fb" >&2
    qrows=""
  fi
fi
if ! cmp -s "$qdiagf" "$QDIAG" 2>/dev/null; then
  if [ -s "$qdiagf" ]; then cat "$qdiagf" >&2
  elif [ -s "$QDIAG" ]; then printf 'fleet-quotawatch: ccquota reads every pool account again — the earlier no-reading/shape complaints are cleared\n' >&2; fi
  atomic_write "$QDIAG" < "$qdiagf"
fi
rm -f "$qdiagf"
T_FETCH=$(( $(now) - f0 ))
post_ts=$(cat "$QTS" 2>/dev/null); case "$post_ts" in ''|*[!0-9]*) post_ts=0;; esac
fetched=0; [ "$post_ts" -gt "$pre_ts" ] && fetched=1
nrows=$(printf '%s' "$qrows" | grep -c .)
hb "policy" "fetched=$fetched"$'\n'"rows=$nrows"$'\n'
y0=$(now)

if [ "$blind" -gt 0 ]; then
  bm=$(( blind / 60 ))
  printf 'fleet-quotawatch: the quota cache was %sm stale before this tick — the watch was blind for that long (caller now: %s)\n' "$bm" "$CALLER" >&2
  if [ "$DRY" = 0 ] && [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
    $FLEET_NOTIFY_CMD "# quota watch was blind for ${bm}m
the ccquota cache (\`account.quota.ts\`) had not been refreshed for ${bm}m — no pre-emptive rotation could fire in that window. It is ticking again now (caller: ${CALLER}). Check \`fleet-doctor.sh\` → quotawatch / collect, and that com.claude-fleet.quotawatch is loaded." >/dev/null 2>&1
  fi
fi

# --- the policy (issue #513, verbatim from the collector's former tail block):
#   ≥ FLEET_ACCOUNT_CEILING (85%)  bench until ccquota's reset instant (rotates
#                                  the active pointer past it — new spawns go
#                                  elsewhere at once), then move every session
#                                  still on it (fleet-account.sh migrate
#                                  --account, per fleet, backgrounded); notify once.
#                                  No OTHER account to move to (#567): bench
#                                  only, say so once — the sessions stay put.
#   ≥ FLEET_ACCOUNT_WARN_PCT (70%) tell every session on it, over its own peer
#                                  inbox (fleet_peer_send — the SendMessage
#                                  channel, not send-keys), that a move is coming
#                                  and to commit WIP; toast + FLEET_NOTIFY_CMD once.
# Once per (account, reset-window): a marker file holds the reset epoch the
# episode was handled for (fleet_same_window compares with tolerance — ccquota's
# resets_at jitters by a second between polls), so the next window re-arms it.
# Empty rows (no ccquota / hub unreachable / unknown verdict) → nothing runs.
qceil="${FLEET_ACCOUNT_CEILING:-85}"; qwarn="${FLEET_ACCOUNT_WARN_PCT:-70}"
# quota_move_target <label> — an account the ceiling branch could move <label>'s
# sessions onto: some OTHER pool account that is neither benched nor itself at
# the ceiling in THIS tick's rows. Prints it; empty + exit 1 ⇒ nowhere to move
# (issue #567). Why not just `fleet-account.sh active` after the bench: with every
# other account benched it keeps the CURRENT one — the right answer for "which
# account should a new spawn use" (there is no better), but the migrate fan-out
# then closes N sessions and cold-boots each one (~25 s) straight back onto the
# account that was just benched for being over the ceiling, still walled. Seen
# live on 2026-09-12 05:32: 12 sessions bounced onto the same wall with the reset
# 24 min away. A session that is walled and waiting for its own reset is strictly
# better off than one cold-booted into the same wall — so: bench (spawns must
# know), skip the move, say so. Rows matter too: an account that crosses the
# ceiling in the SAME tick (a later row, not benched yet) is no target either —
# its own row benches it seconds later and would bounce those sessions again.
# NO ROW is no target either (issue #628). It used to be the opposite: a label
# absent from the rows fell through the `[ -n "$u" ]` guard and was returned as a
# free account — so an account ccquota had just said `available:false, reason:
# no reading` about (which parsed into a row of zeroes, i.e. 0% used, and since
# #628 into no row at all) was the FIRST place a ceiling fan-out sent N sessions.
# Moving N sessions onto an account whose headroom nobody can read is the same
# gamble #567 refused: better to bench, say nothing moved, and let the operator
# see it — the doctor's quota line names the unreadable accounts. It also puts
# this in step with the SPAWN path, which has always worked that way: pick_best
# skips a label with no row outright, and only falls back to round-robin when NOT
# ONE account has a reading. A rowless label being un-spawnable but a legitimate
# landing spot for a dozen at once was never a defensible pair.
quota_move_target() {
  local skip="$1" f l u
  for f in "$ACCT_DIR"/*; do
    [ -f "$f" ] || continue
    l=${f##*/}; case "$l" in .*|*~|*.conf) continue;; esac
    [ "$l" != "$skip" ] || continue
    [ "$("$BIN/fleet-account.sh" limited-until "$l" 2>/dev/null || echo 0)" -le "$(now)" ] || continue
    u=$(printf '%s\n' "$qrows" | awk -F'\t' -v l="$l" '$1==l{print (($2+0)>($3+0))?$2+0:$3+0; exit}')
    [ -n "$u" ] || continue                           # no ccquota reading — see the header
    [ "$u" -ge "$qceil" ] && continue
    printf '%s' "$l"; return 0
  done
  return 1
}
# The policy loop's tmux work, budgeted PER FLEET SOCKET (issue #698). Every branch
# below talks to each fleet's tmux server — a toast per socket, a `list-windows` per
# socket, a `display-message -p` per WINDOW — and on a loaded server a single one of
# those has been measured blocking for 57 s (#582). Checking the clock between
# accounts buys nothing while one account can sit inside a call that never returns,
# so the clock has to reach inside the row.
#
# PER SOCKET, not per call, and that granularity is forced: fleet_timebox polls its
# job once a second, so a job that finishes instantly still costs the caller a full
# second. Wrapping each round-trip would put a 1 s floor on every WINDOW — 23 s of
# pure floor on the monorepo fleet, i.e. the budget would have become the slowness.
# One timebox per socket bounds the same blocking call while the floor scales with
# the number of FLEETS (two here), not windows.
#
# A killed fan-out is a missed toast or a few unsent warnings, never a missed bench:
# the ledger writes are local file writes and do not go through here.
qw_socket_budget() { local b; b=$(qw_left "$POLICY_T0" "$POLICY_BUDGET")
                     [ "$b" -gt "$TMUX_BUDGET" ] && b="$TMUX_BUDGET"
                     printf '%s' "$b"; }

# qw_ceiling_socket <socket> <label> <util> <which> <resett> <to> — one fleet's
# share of a ceiling episode: start the migrate fan-out, then toast. <to> empty =
# the #567 nowhere-to-move case, which toasts and moves nobody.
qw_ceiling_socket() {
  local qs="$1" ql="$2" qutil="$3" qwhich="$4" qresett="$5" qnew="$6"
  if [ -n "$qnew" ]; then
    fleet_bg -L "$qs" "bash '$BIN/fleet-account.sh' migrate --account '$ql' --session '$qs' --toast"
    tmux -L "$qs" display-message "fleet: $ql at ${qutil}% of its $qwhich window (ccquota) → benched until $qresett; moving its sessions to $qnew" 2>/dev/null
  else
    tmux -L "$qs" display-message "fleet: $ql at ${qutil}% of its $qwhich window (ccquota) → benched until $qresett; nowhere to move: no other account is readable and under the ceiling — sessions stay on $ql until $qresett" 2>/dev/null
  fi
  return 0
}

# qw_warn_socket <socket> <label> <msg> <util> <which> <ceiling> — one fleet's share
# of a warn episode. Prints how many sessions it reached, because fleet_timebox runs
# it in a subshell and a counter variable would not survive it.
qw_warn_socket() {
  local qs="$1" ql="$2" qmsg="$3" qutil="$4" qwhich="$5" qceil="$6" qw qa qp n=0
  while read -r qw qa; do
    [ "$qa" = "$ql" ] || continue
    qp=$(fleet_pane_claude_pid "$qw" "$qs" 2>/dev/null) || continue
    [ -n "$qp" ] && fleet_peer_send "$qp" "$qmsg" fleet-quotawatch && n=$((n+1))
  done < <(tmux -L "$qs" list-windows -a -F '#{window_id} #{@cc_account}' 2>/dev/null)
  tmux -L "$qs" display-message "fleet: $ql at ${qutil}% of its $qwhich window (ccquota) — sessions warned; moves at ${qceil}%" 2>/dev/null
  printf '%s' "$n"
}
POLICY_T0=$SECONDS
QPOL_SKIP=""
# A here-string, NOT `printf | while` (issue #698): the loop must run in THIS shell
# so that what it deferred survives it — a pipeline's subshell would take that with
# it, and the wind-down line below would have nothing to report.
# shellcheck disable=SC2034  # qroom: headroom column, read by `list`/pick_active, not here
while IFS=$'\t' read -r ql q5 q7 qroom qr5 qr7 qpph; do
  [ -n "$ql" ] || continue
  # WIND DOWN at a row boundary, never mid-account. Deferring is safe precisely
  # because the once-per-window marker is written by the branch that HANDLES the
  # account: an account we never reached has no marker, so the next tick treats its
  # episode as unhandled and does the whole thing then.
  if [ "$(qw_left "$POLICY_T0" "$POLICY_BUDGET")" -lt 1 ] || ! tick_room; then
    QPOL_SKIP="${QPOL_SKIP}${QPOL_SKIP:+ }$ql"
    continue
  fi
  qutil=$q5; qwhich="5-hour"; qreset=$qr5
  if [ "${q7:-0}" -gt "$qutil" ]; then qutil=$q7; qwhich="7-day"; qreset=$qr7; fi
  qresett=$(date -r "$qreset" '+%H:%M' 2>/dev/null || date -d "@$qreset" '+%H:%M' 2>/dev/null || echo "?")
  if [ "$qutil" -ge "$qceil" ]; then
    mk="$G/quota.ceiling.$ql"
    fleet_same_window "$mk" "$qreset" && continue                          # this window already handled
    qto=$(quota_move_target "$ql") || qto=""
    if [ "$DRY" = 1 ]; then
      if [ -n "$qto" ]; then printf 'would: bench %s (%s%% of %s, resets %s) + migrate --account %s on: %s\n' "$ql" "$qutil" "$qwhich" "$qresett" "$ql" "$(printf '%s' "$SOCKETS" | tr '\n' ' ')"
      else printf 'would: bench %s (%s%% of %s, resets %s) — nowhere to move: every other account is benched, at its ceiling, or has no ccquota reading; its sessions would stay on %s until %s\n' "$ql" "$qutil" "$qwhich" "$qresett" "$ql" "$qresett"; fi
      continue
    fi
    printf '%s' "$qreset" | atomic_write "$mk"
    "$BIN/fleet-account.sh" bench "$ql" "$qreset" "ccquota: $qwhich window at ${qutil}%" >/dev/null 2>&1
    qnew=$("$BIN/fleet-account.sh" active 2>/dev/null)
    if [ -z "$qto" ]; then
      # #567: the bench is recorded (a new spawn must know), the move is not made.
      printf 'fleet-quotawatch: %s at %s%% of its %s window — benched until %s; nowhere to move: no other account is both readable and under the ceiling, its sessions stay on %s until then\n' "$ql" "$qutil" "$qwhich" "$qresett" "$ql" >&2
      for qs in $SOCKETS; do
        qsb=$(qw_socket_budget); [ "$qsb" -lt 1 ] && { QPOL_SKIP="${QPOL_SKIP}${QPOL_SKIP:+ }$ql:$qs"; continue; }
        fleet_timebox "$qsb" qw_ceiling_socket "$qs" "$ql" "$qutil" "$qwhich" "$qresett" "" || true
      done
      if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
        $FLEET_NOTIFY_CMD "# subscription at its limit — nowhere to move
**$ql** is at ${qutil}% of its $qwhich window (ccquota, exact) — benched until $qresett, but every other account is benched, at its ceiling, or unreadable to ccquota, so its sessions were NOT moved: they stay on **$ql** until $qresett (a walled session waiting for its own reset beats one cold-booted back into the same wall)" >/dev/null 2>&1
      fi
      continue
    fi
    for qs in $SOCKETS; do
      qsb=$(qw_socket_budget); [ "$qsb" -lt 1 ] && { QPOL_SKIP="${QPOL_SKIP}${QPOL_SKIP:+ }$ql:$qs"; continue; }
      fleet_timebox "$qsb" qw_ceiling_socket "$qs" "$ql" "$qutil" "$qwhich" "$qresett" "${qnew:-?}" || true
    done
    if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
      $FLEET_NOTIFY_CMD "# subscription near its limit — rotated early
**$ql** is at ${qutil}% of its $qwhich window (ccquota, exact) — benched until $qresett; new sessions now use **${qnew:-?}** and every session still on it is being moved (close + \`--resume\` in a new window), before it hits the wall" >/dev/null 2>&1
    fi
  elif [ "$qutil" -ge "$qwarn" ]; then
    mk="$G/quota.warn.$ql"
    fleet_same_window "$mk" "$qreset" && continue
    if [ "$DRY" = 1 ]; then printf 'would: warn the sessions on %s (%s%% of %s, resets %s)\n' "$ql" "$qutil" "$qwhich" "$qresett"; continue; fi
    printf '%s' "$qreset" | atomic_write "$mk"
    qeta=""; [ "${qpph:-0}" -gt 0 ] && qeta=" (~$(( (100 - qutil) * 60 / qpph )) min to 100% at the current rate)"
    # The trailing language rule (issue #620) is what keeps this English notice
    # from reading as a language switch to a session that has been speaking
    # Chinese for forty turns — the notice itself needs no translation.
    qmsg="[fleet quota watch] Subscription account $ql — the one this session runs on — is at ${qutil}% of its $qwhich window${qeta}; it resets at $qresett. At ${qceil}% the fleet will send /exit to this session and resume it in a new window under another account (claude --resume, same transcript). Commit or stash any work in progress and leave a one-line note of where you are, so the resumed session picks up cleanly. No reply is needed.${FLEET_LANG_RULE_NOTICE:+ $FLEET_LANG_RULE_NOTICE}"
    qn=0
    # qw_warn_socket does the per-window walk (space-separated: a window id has no
    # spaces and a label is a file name — tmux ≤3.4 would print a control-byte
    # separator as literal `\037`) under ONE budget for the whole fleet.
    for qs in $SOCKETS; do
      qsb=$(qw_socket_budget); [ "$qsb" -lt 1 ] && { QPOL_SKIP="${QPOL_SKIP}${QPOL_SKIP:+ }$ql:$qs"; continue; }
      qsent=$(fleet_timebox "$qsb" qw_warn_socket "$qs" "$ql" "$qmsg" "$qutil" "$qwhich" "$qceil")
      case "$qsent" in ''|*[!0-9]*) qsent=0 ;; esac
      qn=$(( qn + qsent ))
    done
    [ -n "${FLEET_NOTIFY_CMD:-}" ] && $FLEET_NOTIFY_CMD "# subscription approaching its limit
**$ql** is at ${qutil}% of its $qwhich window${qeta} (ccquota, exact) — $qn running session(s) warned to commit WIP; at ${qceil}% the fleet benches it and moves them" >/dev/null 2>&1
  else
    [ "$DRY" = 1 ] && printf 'ok: %s at %s%% of its %s window (warn %s%%, ceiling %s%%)\n' "$ql" "$qutil" "$qwhich" "$qwarn" "$qceil"
  fi
done <<< "$qrows"
if [ -n "$QPOL_SKIP" ]; then
  QW_SKIP="${QW_SKIP}${QW_SKIP:+ }policy"
  printf 'fleet-quotawatch: policy phase spent its %ss budget — deferred to the next tick: %s\n' "$POLICY_BUDGET" "$QPOL_SKIP" >&2
fi

# --- THIRD job (OPT-IN): re-plan the 5h-window PHASE stagger (issue #598) ------
# N subscriptions first used at around the same time keep their 5h windows in the
# same phase — they burn down together and reset together, so the pool's total
# headroom is a sawtooth whose trough is a full outage. `phase --plan --apply`
# staggers the accounts that have NO live window by 5h/N, which is a decision
# about WHEN each account may open its next window (see fleet-account.sh
# phase_plan). Once per window is the right cadence — the plan is a queue of
# start slots, not a rotation — so it is keyed on the earliest 5h reset in these
# rows, the same fleet_same_window dedup the ceiling/warn branches use.
#
# DEFAULT OFF. This tick is what keeps the fleet alive, and a phase hold makes an
# account temporarily un-spawnable: it is fail-open in pick_active (a hold can
# never be the reason a spawn has no account), but arming it is still the
# operator's call, after they have watched `fleet-account.sh phase --plan` agree
# with the pool they can see. FLEET_ACCOUNT_PHASE_AUTO=1 arms it;
# FLEET_ACCOUNT_PHASE=0 disables the holds themselves, wherever they came from.
# Under the tick budget like every other piece of work (issue #698): this is an
# OPT-IN extra at the very tail, so it is the first thing a tick that is out of
# time should drop — a stagger re-plan that waits 60 s costs nothing, a tick that
# overruns its deadline costs the whole watch.
if [ "${FLEET_ACCOUNT_PHASE_AUTO:-0}" = 1 ] && [ "${nrows:-0}" -gt 1 ] \
   && { tick_room || { QW_SKIP="${QW_SKIP}${QW_SKIP:+ }phaseplan"; false; }; }; then
  qpmin=$(printf '%s\n' "$qrows" | awk -F'\t' 'BEGIN{m=0} ($5+0)>0 && (m==0 || ($5+0)<m){m=$5+0} END{print m+0}')
  qpmk="$G/quota.phase"
  if [ "$qpmin" -gt 0 ] && ! fleet_same_window "$qpmk" "$qpmin"; then
    if [ "$DRY" = 1 ]; then
      printf 'would: re-plan the 5h phase stagger —\n'
      "$BIN/fleet-account.sh" phase --plan 2>&1 | sed 's/^/  /'
    else
      printf '%s' "$qpmin" | atomic_write "$qpmk"
      if qpout=$(fleet_timebox "$(tick_left)" "$BIN/fleet-account.sh" phase --plan --apply 2>&1); then
        printf 'fleet-quotawatch: re-planned the 5h phase stagger (issue #598)\n%s\n' "$qpout" >&2
      else
        printf 'fleet-quotawatch: phase re-plan declined — %s\n' "$qpout" >&2
      fi
    fi
  fi
fi

T_POLICY=$(( $(now) - y0 ))
END=$(now)
hb "done" "fetched=$fetched"$'\n'"rows=$nrows"$'\n'"end=$END"$'\n'"dur=$(( END - START ))"$'\n'"t_modelcap=$T_MODEL"$'\n'"t_fetch=$T_FETCH"$'\n'"t_policy=$T_POLICY"$'\n'"budget=$TICK_BUDGET"$'\n'"over=$QW_OVER"$'\n'"skipped=$QW_SKIP"$'\n'
# One line per tick, so the launchd log can answer "which HALF was slow?" without
# instrumenting anything after the fact (issue #582). Before this, the heartbeat
# held only the phase currently running and overwrote it, so a tick that took
# 143 s left no record of where the 143 s went.
#
# `over=` and `deferred=` are the #698 half, and the same argument as #653's: a
# tick that winds down on budget is a tick that did not do everything, and without
# the two lists the next person to ask "why did the watch not act on account X"
# has no record that it ran out of time rather than deciding not to.
printf 'fleet-quotawatch: tick done in %ss/%ss — modelcap %ss [%s ], fetch %ss, policy %ss, %s row(s)%s%s\n' \
  "$(( END - START ))" "$TICK_BUDGET" "$T_MODEL" "${MTIMES:- none}" "$T_FETCH" "$T_POLICY" "$nrows" \
  "${QW_OVER:+, over: $QW_OVER}" "${QW_SKIP:+, deferred: $QW_SKIP}" >&2
exit 0
