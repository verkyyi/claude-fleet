#!/bin/sh
# fleet-daemon-lib.sh — "is this interval daemon still being SCHEDULED?", asked
# of EVERY fleet daemon and asked RELATIVE TO ITS OWN INTERVAL (issue #639).
#
# Pure: sourcing defines functions only (like fleet-lib.sh / usage-lib.sh). No
# tmux, no network, no launchctl — every read here is a stamp file. The part that
# needs a daemon manager (is a tick running? kick it) lives in the one script
# that acts: bin/fleet-daemon-watch.sh.
#
# WHY WATCHING THE COLLECTOR WAS NOT ENOUGH. #636/#638 gave the collector an
# alarm (`⚠ dash stale`) and a rate-limited self-heal. Two days later the same
# machine showed the fault is not collector-shaped: launchd stopped scheduling
# EVERY StartInterval unit in this user domain, all of their logs freezing inside
# the same two minutes —
#
#   16:30:57 ledger-watch   16:31:04 base-sync     16:31:27 cleanup
#   16:31:44 dispatch       16:32:21 issue-bridge  16:32:32 quotawatch
#
# — while the two KeepAlive units (spinner, webhook) never missed a frame and
# `launchctl kickstart -k` revived each interval unit instantly. So cleanup stops
# reaping workers, dispatch stops autofilling, base-sync stops fast-forwarding
# the base, issue-bridge stops relaying comments, ledger-watch stops indexing
# closed sessions — all silently, because only the collector had a heartbeat that
# could go stale. Same-day control: the OTHER machine, on the same commit, was
# ticking normally — this is host state (13 days of uptime), not a fleet bug,
# which is exactly why the answer is VISIBILITY + SELF-HEAL on every unit rather
# than a fix to any one daemon.
#
# AND WHY AN ABSOLUTE THRESHOLD MISSED THE COMMON CASE. #638 alarmed on a
# heartbeat older than FLEET_COLLECT_STALE (600s — the collector's own supersede
# deadline). But launchd's degradation is not binary: the measured collector was
# running once per 7–14 MINUTES against StartInterval=60 — twelve times too slow,
# every number on the dash twelve times too old — and its heartbeat age never
# crossed 600s, so the verdict read `fresh 401 472` the whole time. What makes
# both shapes visible with ONE number is age measured in MULTIPLES OF THE UNIT'S
# OWN INTERVAL: a 60s unit silent for five intervals is broken, a 3600s unit
# silent for 400s is healthy. Hence FLEET_DAEMON_STALE_MULT (×5) over each unit's
# StartInterval, with FLEET_DAEMON_STALE_FLOOR (180s) so the 15s units do not
# alarm on one slow `gh` call.
#
# EVIDENCE OF LIFE is the NEWEST of two stamps, which is what keeps a slow tick
# from being mistaken for a pended one:
#   • the SCHEDULING stamp `<unit>.tick` — epoch written at the TOP of the
#     daemon's script, before any early exit, so "launchd never spawned me" stays
#     distinguishable from "I ran and had nothing to do" (a gated dispatch tick);
#   • the PROGRESS heartbeat some daemons already keep (collect.heartbeat,
#     quotawatch.heartbeat) — `phase_ts` advances at every phase boundary, so a
#     legitimately long tick keeps proving it is alive mid-run.
#
# STATE DIR — and the false `↻ dash kicked` #638 shipped with. The stamps are
# machine-wide, under the shared `global/` cache the status bar reads. That is
# right for the LIVE install and wrong for anybody else: a worker testing the
# self-heal inside its own `issue-<N>` worktree wrote `collect.kick.ts` into the
# live operator's status bar, which is how `↻ dash kicked 7m` appeared on a
# machine whose logs/collect-kick.log did not exist. So the state dir follows the
# INSTALL ROOT: the live install keeps the shared path (unchanged on-disk
# contract, same file usage-lib.sh reads), and any other checkout gets a private
# sibling whose stamps no live reader ever sees.
#
# Shell-options policy: SOURCED lib → no `set` (never impose options on a caller).

# --- the registry -------------------------------------------------------------
# "<unit> <StartInterval seconds> <evidence source>" — one line per daemon that
# launchd/systemd runs ON AN INTERVAL, which is exactly the population #639 is
# about. The two KeepAlive units (spinner, webhook) are deliberately absent: they
# are never pended, and the spinner is the hand that kicks the rest.
#
# Evidence source (comma-separated, all MAXed with the `<unit>.tick` stamp):
#   `tick`      nothing beyond the scheduling stamp this lib writes
#   `hb:<file>` that daemon's own per-phase heartbeat in the shared global/ cache
#               (read for `phase_ts`, then `end`, then `start`)
#   `pid:<file>` an overlap-guard pid file: a LIVE tick counts as evidence NOW, not
#               as of when it started. This is what keeps a long tick from being
#               read as a pended one. The collector's phase heartbeat advances at
#               phase BOUNDARIES, and one phase can legitimately run for minutes —
#               a 551s `git` phase is on record from a big monorepo fleet — so
#               without this a 300s threshold would paint `⚠ dash stale` over a
#               collector that is working perfectly well, every single tick. A tick
#               older than FLEET_COLLECT_DEADLINE is NOT evidence: past that the
#               collector itself calls it wedged, kills it and supersedes it.
# Only `collect` gets an `hb:`. quotawatch keeps one too, but the collector writes
# it as well (`--caller collect`, the pre-#551 cadence), so reading it here would
# reproduce the exact blind spot #639 found: a heartbeat that looks fresh while
# com.claude-fleet.quotawatch itself has not been scheduled for hours.
#
# KEEP IN SYNC with launchd/*.plist.tmpl — bin/fleet-daemon-watch-selftest.sh
# parses every template's StartInterval and fails if this table disagrees, so the
# two cannot drift (the same lockstep rule fleet-keys-selftest.sh enforces).
fleet_daemon_units() {
  printf '%s\n' \
    'collect 60 hb:collect.heartbeat,pid:collect.pid' \
    'quotawatch 60 tick' \
    'cleanup 60 tick' \
    'sleep 60 tick' \
    'dispatch 60 tick' \
    'base-sync 60 tick' \
    'diskguard 60 tick' \
    'ledger-watch 60 tick' \
    'issue-bridge 15 tick' \
    'pr-refresh 15 tick' \
    'worktree-autoclean 3600 tick'
}

# fleet_daemon_unit_names — just the unit names, in registry order.
fleet_daemon_unit_names() { fleet_daemon_units | while read -r _fdn _fdi _fds; do
  [ -n "$_fdn" ] && printf '%s\n' "$_fdn"; done; }

# fleet_daemon_known <unit> — 0 iff the unit is in the registry.
fleet_daemon_known() {
  _fdk=$(fleet_daemon_units | while read -r _n _i _s; do
    [ "$_n" = "${1:-}" ] && printf 'y'; done)
  [ -n "$_fdk" ]
}

# fleet_daemon_field <unit> <2|3> — the interval or the evidence source.
fleet_daemon_field() {
  fleet_daemon_units | while read -r _n _i _s; do
    [ "$_n" = "${1:-}" ] || continue
    case "${2:-2}" in 3) printf '%s' "$_s" ;; *) printf '%s' "$_i" ;; esac
  done
}

# _fleet_daemon_key <unit> — the unit name as an env-var suffix (`-` → `_`), so a
# per-unit override reads FLEET_DAEMON_STALE_BASE_SYNC for `base-sync`.
# Forkless (issue #888): it was `printf | tr 'a-z-' 'A-Z_'`, and the status bar
# asks it twice per unit per render — 22 `tr` every 5s per attached client. POSIX
# sh has no case conversion, so it walks the name a character at a time; anything
# outside a-z and `-` passes through untouched, exactly as `tr` left it.
_fleet_daemon_key() {
  _fdk_in="${1:-}"; _fdk_out=''
  while [ -n "$_fdk_in" ]; do
    _fdk_rest="${_fdk_in#?}"; _fdk_c="${_fdk_in%"$_fdk_rest"}"; _fdk_in="$_fdk_rest"
    case "$_fdk_c" in
      a) _fdk_c=A ;; b) _fdk_c=B ;; c) _fdk_c=C ;; d) _fdk_c=D ;; e) _fdk_c=E ;;
      f) _fdk_c=F ;; g) _fdk_c=G ;; h) _fdk_c=H ;; i) _fdk_c=I ;; j) _fdk_c=J ;;
      k) _fdk_c=K ;; l) _fdk_c=L ;; m) _fdk_c=M ;; n) _fdk_c=N ;; o) _fdk_c=O ;;
      p) _fdk_c=P ;; q) _fdk_c=Q ;; r) _fdk_c=R ;; s) _fdk_c=S ;; t) _fdk_c=T ;;
      u) _fdk_c=U ;; v) _fdk_c=V ;; w) _fdk_c=W ;; x) _fdk_c=X ;; y) _fdk_c=Y ;;
      z) _fdk_c=Z ;; -) _fdk_c=_ ;;
    esac
    _fdk_out="$_fdk_out$_fdk_c"
  done
  printf '%s' "$_fdk_out"
}

# fleet_now — epoch seconds. `date +%s` unless the calling script PINNED its clock
# with fleet_now_pin: then the pin plus the shell's own $SECONDS since pinning, so
# every age this lib (and usage-lib.sh, which delegates here) computes shares ONE
# `date` fork per script run instead of paying one per age (issue #888: the status
# bar forked `date` 26 times per render). It stays live — accurate to ±1s — however
# long the script runs; a shell without $SECONDS (dash) holds the pinned value,
# which only a one-shot script should rely on. Neither bash 3.2 nor POSIX sh has
# $EPOCHSECONDS.
#
# The pin is keyed on $$ (unchanged in a subshell, different in any child process),
# so an accidentally exported pin cannot leak into a child script: the child's
# $SECONDS restarted at 0, and it simply falls back to `date`.
# shellcheck disable=SC3028  # $SECONDS is optional by design: absent (dash) → held pin
fleet_now() {
  if [ -n "${_FLEET_NOW:-}" ] && [ "${_FLEET_NOW_PID:-}" = "$$" ]; then
    if [ -n "${_FLEET_NOW_S0:-}" ]; then
      printf '%s' $(( _FLEET_NOW + SECONDS - _FLEET_NOW_S0 ))
    else
      printf '%s' "$_FLEET_NOW"
    fi
  else
    date +%s
  fi
}
# shellcheck disable=SC3028  # see fleet_now
fleet_now_pin() { _FLEET_NOW=$(date +%s); _FLEET_NOW_S0="${SECONDS:-}"; _FLEET_NOW_PID=$$; }

# fleet_daemon_state_dir [root] — where this install's daemon stamps live.
# The LIVE install (or an unknown root) gets the shared machine-wide global/ dir
# the status bar and fleet-doctor read; any other checkout gets a private sibling
# so a worker's test cannot write the operator's live status bar (see header).
# `root` is the install root, i.e. the caller's "$BIN/..".
fleet_daemon_state_dir() {
  _fd_root="${1:-${FLEET_DAEMON_ROOT:-}}"
  _fd_base="${TMPDIR:-/tmp}/.claude-dash"
  if [ -n "$_fd_root" ]; then
    _fd_rp=$(cd "$_fd_root" 2>/dev/null && pwd -P) || _fd_rp=''
    _fd_lp=$(cd "${FLEET_LIVE_ROOT:-$HOME/.claude/fleet}" 2>/dev/null && pwd -P) || _fd_lp=''
    if [ -n "$_fd_rp" ] && [ "$_fd_rp" != "$_fd_lp" ]; then
      printf '%s/dev-%s' "$_fd_base" "$(printf '%s' "$_fd_rp" | cksum | tr -cd '0-9')"
      return 0
    fi
  fi
  printf '%s/global' "$_fd_base"
}

# fleet_daemon_interval <unit> — the unit's StartInterval in seconds. Overridable
# per unit (FLEET_DAEMON_INTERVAL_<UNIT>) for a host that templated a different
# cadence; an unknown unit falls back to 60.
fleet_daemon_interval() {
  _fd_i=$(fleet_daemon_field "${1:-}" 2)
  _fd_o=''   # the eval below sets it from the per-unit env override, if any
  eval "_fd_o=\${FLEET_DAEMON_INTERVAL_$(_fleet_daemon_key "${1:-}"):-}"
  case "$_fd_o" in ''|*[!0-9]*) : ;; *) [ "$_fd_o" -gt 0 ] && _fd_i="$_fd_o" ;; esac
  case "$_fd_i" in ''|*[!0-9]*) _fd_i=60 ;; esac
  [ "$_fd_i" -gt 0 ] || _fd_i=60
  printf '%s' "$_fd_i"
}

# fleet_daemon_fair_budget <remaining-secs> <units-left-including-this> [floor] —
# an even split of a tick's remaining budget across the units (fleets) still to
# visit, so one slow unit cannot starve the rest WITHIN a tick (issue #850). The
# caller's cursor rotation already gives fairness ACROSS ticks; this gives it
# within one. Adaptive: a unit that finishes early shrinks the divisor for the
# next, handing over its leftover. Floored (default 5s) so every unit gets a
# usable slice, and capped at what remains so the total never overruns the tick.
fleet_daemon_fair_budget() {
  _fd_rem="${1:-0}"; _fd_n="${2:-1}"; _fd_fl="${3:-5}"
  case "$_fd_rem" in ''|*[!0-9]*) _fd_rem=0 ;; esac
  case "$_fd_n"   in ''|*[!0-9]*) _fd_n=1 ;; esac
  case "$_fd_fl"  in ''|*[!0-9]*) _fd_fl=5 ;; esac
  [ "$_fd_n" -ge 1 ] || _fd_n=1
  _fd_b=$(( _fd_rem / _fd_n ))
  [ "$_fd_b" -lt "$_fd_fl" ] && _fd_b="$_fd_fl"
  [ "$_fd_b" -gt "$_fd_rem" ] && _fd_b="$_fd_rem"
  printf '%s' "$_fd_b"
}


# fleet_daemon_stale_secs <unit> — the staleness threshold, RELATIVE to the unit's
# own interval: max(MULT × interval, FLOOR). An absolute per-unit override wins
# outright (FLEET_DAEMON_STALE_<UNIT>, and FLEET_COLLECT_STALE for `collect` so
# #638's knob keeps working).
#
# Defaults: MULT=5, FLOOR=180. Five intervals is well clear of one slow tick
# (the collector's phases are 1–3 min) yet far below the 7–14 min cadence #639
# measured; the floor keeps the 15s units (issue-bridge, pr-refresh) from
# alarming on a single slow `gh` round-trip. Raise MULT on a fleet whose ticks
# are genuinely long — a big monorepo has been seen with a 551s git phase, and
# that host wants FLEET_DAEMON_STALE_COLLECT (or a bigger MULT), not silence.
fleet_daemon_stale_secs() {
  _fd_u="${1:-}"
  _fd_ov=''   # the eval below sets it from the per-unit env override, if any
  eval "_fd_ov=\${FLEET_DAEMON_STALE_$(_fleet_daemon_key "$_fd_u"):-}"
  [ "$_fd_u" = collect ] && [ -z "$_fd_ov" ] && _fd_ov="${FLEET_COLLECT_STALE:-}"
  case "$_fd_ov" in ''|*[!0-9]*) : ;; *) printf '%s' "$_fd_ov"; return 0 ;; esac
  _fd_m="${FLEET_DAEMON_STALE_MULT:-5}"; case "$_fd_m" in ''|*[!0-9]*) _fd_m=5 ;; esac
  [ "$_fd_m" -gt 0 ] || _fd_m=5
  _fd_f="${FLEET_DAEMON_STALE_FLOOR:-180}"; case "$_fd_f" in ''|*[!0-9]*) _fd_f=180 ;; esac
  _fd_t=$(( _fd_m * $(fleet_daemon_interval "$_fd_u") ))
  [ "$_fd_t" -ge "$_fd_f" ] || _fd_t="$_fd_f"
  printf '%s' "$_fd_t"
}

# fleet_daemon_wedged_secs <unit> — how long a RUNNING unit may show no progress
# before it counts as WEDGED rather than slow (issue #682). 0 disables it, and a
# unit is never wedged while it is still advancing its heartbeat.
#
# Why this exists. #639's self-heal has a deliberate guard: a unit whose state is
# `running` is never kicked, because `launchctl kickstart -k` KILLS the current
# invocation and aborting a merely-slow tick is worse than waiting for it. That
# was right about the remedy and wrong about the question — it treated "slow" and
# "stopped for ever" as one state. On 2026-09-15 collect and quotawatch each sat
# `running` and frozen for ~54 minutes; `--status` reported both `stale`, the
# alarm was accurate, and the self-heal stood down by design while the dash served
# 53-minute-old data with nothing left that could recover it.
#
# DURATION is what separates the two, and staleness is the honest duration to
# measure: a tick that is slow but alive stamps `phase_ts` at every phase boundary
# (see _fleet_daemon_hb_ts), so however long that tick runs its staleness stays
# small. A unit that has been stale for several whole alarm windows is not behind
# — it has stopped advancing its own heartbeat, and only then does it go down the
# normal ladder (kick → count → bootout/bootstrap).
#
# The threshold is a MULTIPLE of the unit's own staleness threshold, which is
# already per-unit and interval-derived, so a host that legitimately runs long
# ticks raises one knob and both numbers move together. Default MULT=3, i.e. 900s
# for a 60s unit like collect (3 x max(5 x 60, 180)). Note this is ~7x collect's
# 120s tick budget, not the 3x the issue first proposed: the budget is not visible
# from here, and a generous first setting is the right bias when the remedy aborts
# a live tick. FLEET_DAEMON_WEDGED_MULT retunes every unit;
# FLEET_DAEMON_WEDGED_<UNIT> sets one outright; either set to 0 restores the
# pre-#682 behaviour of never touching a running unit.
fleet_daemon_wedged_secs() {
  _fd_u="${1:-}"
  _fd_wo=''   # the eval below sets it from the per-unit env override, if any
  eval "_fd_wo=\${FLEET_DAEMON_WEDGED_$(_fleet_daemon_key "$_fd_u"):-}"
  case "$_fd_wo" in ''|*[!0-9]*) : ;; *) printf '%s' "$_fd_wo"; return 0 ;; esac
  _fd_wm="${FLEET_DAEMON_WEDGED_MULT:-3}"; case "$_fd_wm" in ''|*[!0-9]*) _fd_wm=3 ;; esac
  [ "$_fd_wm" -gt 0 ] || { printf '0'; return 0; }
  printf '%s' $(( _fd_wm * $(fleet_daemon_stale_secs "$_fd_u") ))
}

# _fleet_daemon_epoch <file> — the first line of <file> iff it is a positive
# integer, else 0. Builtin `read`, no fork: the status bar calls this ~10× every
# 5s per attached client.
_fleet_daemon_epoch() {
  _fd_e=''
  [ -f "${1:-}" ] && IFS= read -r _fd_e < "$1" 2>/dev/null
  case "$_fd_e" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_fd_e" ;; esac
}

# _fleet_daemon_hb_ts <file> — a daemon's own per-phase heartbeat, as an epoch:
# `phase_ts` (written at every phase boundary, so it advances mid-tick), then
# `end`, then `start` for a partial or older file. 0 when there is none. Forkless
# for the same reason as above.
_fleet_daemon_hb_ts() {
  _fd_p=0; _fd_n=0; _fd_s=0
  [ -f "${1:-}" ] || { printf '0'; return 0; }
  while IFS='=' read -r _fd_k _fd_v; do
    case "$_fd_v" in ''|*[!0-9]*) continue ;; esac
    case "$_fd_k" in
      phase_ts) _fd_p="$_fd_v" ;;
      end)      _fd_n="$_fd_v" ;;
      start)    _fd_s="$_fd_v" ;;
    esac
  done < "$1"
  if [ "$_fd_p" -gt 0 ]; then printf '%s' "$_fd_p"
  elif [ "$_fd_n" -gt 0 ]; then printf '%s' "$_fd_n"
  else printf '%s' "$_fd_s"; fi
}

# fleet_daemon_stamp_tick <unit> [root] — the SCHEDULING heartbeat. Called once at
# the top of each interval daemon, BEFORE any early exit, so a gated tick that
# does nothing still proves launchd spawned it. Never fatal: a daemon must not
# die because a stamp could not be written.
fleet_daemon_stamp_tick() {
  _fd_d=$(fleet_daemon_state_dir "${2:-}")
  [ -d "$_fd_d" ] || mkdir -p "$_fd_d" 2>/dev/null || return 0   # test first: no exec once it exists (#888)
  date +%s > "$_fd_d/${1:-unknown}.tick" 2>/dev/null || return 0
  return 0
}

# fleet_daemon_tick_ts <unit> [root] — epoch of the unit's last EVIDENCE OF LIFE:
# the newer of its scheduling stamp and its own progress heartbeat (see header).
# 0 = no evidence ever, which every caller treats as "say nothing": a fresh
# install, a host that never had this unit (#492 — ledger-watch was missing for
# months), or a daemon run by hand. Alarming there would only teach people to
# ignore the alarm.
fleet_daemon_tick_ts() {
  _fd_dir=$(fleet_daemon_state_dir "${2:-}")
  _fd_ts=$(_fleet_daemon_epoch "$_fd_dir/${1:-}.tick")
  _fd_gl="${TMPDIR:-/tmp}/.claude-dash/global"
  # Resolve the source list BEFORE narrowing IFS: fleet_daemon_field splits the
  # registry row with `read`, which honours IFS — running it under IFS=',' would
  # hand back the whole row instead of the third field.
  _fd_src=$(fleet_daemon_field "${1:-}" 3)
  _fd_ifs_save="$IFS"; IFS=','
  for _fd_one in $_fd_src; do
    case "$_fd_one" in
      hb:*)
        _fd_h=$(_fleet_daemon_hb_ts "$_fd_gl/${_fd_one#hb:}")
        [ "$_fd_h" -gt "$_fd_ts" ] && _fd_ts="$_fd_h" ;;
      pid:*)
        _fd_h=$(_fleet_daemon_inflight "$_fd_gl/${_fd_one#pid:}")
        [ "$_fd_h" -gt "$_fd_ts" ] && _fd_ts="$_fd_h" ;;
    esac
  done
  IFS="$_fd_ifs_save"
  printf '%s' "$_fd_ts"
}

# _fleet_daemon_inflight <pid-file> — NOW if that overlap-guard pid file ("pid<TAB>
# start-epoch") names a live process whose tick is younger than the collector's
# supersede deadline, else 0. `kill -0` is a builtin, so this stays forkless on the
# status bar's 5s path; deliberately no `ps` command check (that would fork), which
# leaves only pid REUSE as a way to be fooled — and the window is bounded by the
# deadline either way, after which a tick stops counting as alive at all.
_fleet_daemon_inflight() {
  [ -f "${1:-}" ] || { printf '0'; return 0; }
  _fd_tab=$(printf '\t')
  _fd_pid=''; _fd_pts=''
  IFS="$_fd_tab" read -r _fd_pid _fd_pts < "$1" 2>/dev/null
  case "$_fd_pid" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  case "$_fd_pts" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  kill -0 "$_fd_pid" 2>/dev/null || { printf '0'; return 0; }
  _fd_nw=$(fleet_now)
  if [ "$(( _fd_nw - _fd_pts ))" -lt "${FLEET_COLLECT_DEADLINE:-600}" ]; then
    printf '%s' "$_fd_nw"
  else
    printf '0'
  fi
}

# fleet_daemon_overdue <unit> [root] — the evidence age in seconds IFF the unit is
# past its threshold; prints NOTHING when it is fresh or has never ticked. Same
# fail-open shape as fleet_collect_stale_age, which it generalizes.
fleet_daemon_overdue() {
  _fd_t=$(fleet_daemon_tick_ts "${1:-}" "${2:-}")
  [ "$_fd_t" -gt 0 ] || return 0
  _fd_a=$(( $(fleet_now) - _fd_t ))
  [ "$_fd_a" -ge "$(fleet_daemon_stale_secs "${1:-}")" ] && printf '%s' "$_fd_a"
  return 0
}

# fleet_daemon_kick_age <unit> [root] — seconds since this unit was last kicked, or
# nothing if it never was. The TRACE: the status bar keeps showing it for
# FLEET_DAEMON_KICK_TRACE after the unit recovers, so a self-heal is never silent.
fleet_daemon_kick_age() {
  _fd_k=$(_fleet_daemon_epoch "$(fleet_daemon_state_dir "${2:-}")/${1:-}.kick.ts")
  [ "$_fd_k" -gt 0 ] || return 0
  printf '%s' $(( $(fleet_now) - _fd_k ))
  return 0
}

# fleet_daemon_kick_cooldown <unit> — seconds between two kicks of the same unit,
# RELATIVE to the unit's own interval: max(MULT x interval, FLOOR). Same shape,
# and the same reason, as fleet_daemon_stale_secs above.
#
# WHY IT STOPPED BEING A FLAT 600s (issue #711). The flat number was chosen when
# the cooldown's only job was "do not let the kick itself become the load", and it
# was sized for the 60s units. Then the domain-wide stall arrived: when launchd
# spawns NOTHING, `launchctl kickstart` is an EXPLICIT command and therefore the
# only execution path left — so the self-heal's cooldown silently becomes every
# daemon's effective period. Measured on 2026-09-15: issue-bridge and pr-refresh,
# both StartInterval=15, running once per 600s. A `fleet-comment.sh --to-worker`
# relay that should land in 15s took up to ten minutes, and quotawatch — which
# exists as its own 60s unit precisely because an 85% quota watch once missed a
# whole 5-hour window (#551/#553) — was reduced to one look per ten minutes.
#
# One cooldown for units whose intervals differ by 240x cannot be right for both,
# so it now scales like every other number here. MULT=3 keeps the cooldown at or
# BELOW each unit's staleness threshold across the whole registry (3x15=45→60 vs
# 180; 3x60=180 vs 300; 3x3600 vs 18000), which is the property worth having: the
# staleness threshold — already per-unit and already tuned — goes back to being
# the thing that rate-limits kicks, and the cooldown goes back to being what it
# was for, a guard against two watch passes kicking the same unit twice in a row.
#
# FLEET_DAEMON_KICK_COOLDOWN still wins outright when set, now as an ABSOLUTE
# override rather than the default, and FLEET_COLLECT_KICK_COOLDOWN still governs
# `collect` (#638's knob). FLEET_DAEMON_KICK_COOLDOWN_<UNIT> sets one unit.
fleet_daemon_kick_cooldown() {
  _fd_u="${1:-}"
  _fd_c=''   # the eval below sets it from the per-unit env override, if any
  eval "_fd_c=\${FLEET_DAEMON_KICK_COOLDOWN_$(_fleet_daemon_key "$_fd_u"):-}"
  [ -z "$_fd_c" ] && [ "$_fd_u" = collect ] && _fd_c="${FLEET_COLLECT_KICK_COOLDOWN:-}"
  [ -z "$_fd_c" ] && _fd_c="${FLEET_DAEMON_KICK_COOLDOWN:-}"
  case "$_fd_c" in ''|*[!0-9]*) : ;; *) printf '%s' "$_fd_c"; return 0 ;; esac
  # MULT/FLOOR are read from their own names, never through the per-unit eval
  # above: no registry unit is called `mult` or `floor`, and the check below keeps
  # a garbage value from turning into a zero cooldown (i.e. no rate limit at all).
  _fd_cm="${FLEET_DAEMON_KICK_COOLDOWN_MULT:-3}"; case "$_fd_cm" in ''|*[!0-9]*) _fd_cm=3 ;; esac
  [ "$_fd_cm" -gt 0 ] || _fd_cm=3
  _fd_cf="${FLEET_DAEMON_KICK_COOLDOWN_FLOOR:-60}"; case "$_fd_cf" in ''|*[!0-9]*) _fd_cf=60 ;; esac
  _fd_ct=$(( _fd_cm * $(fleet_daemon_interval "$_fd_u") ))
  [ "$_fd_ct" -ge "$_fd_cf" ] || _fd_ct="$_fd_cf"
  printf '%s' "$_fd_ct"
}

# fleet_daemon_kick_fails <unit> [root] — how many kicks in a row have failed to
# bring this unit back. Zeroed the moment it ticks again.
#
# WHY IT IS COUNTED. A `launchctl kickstart -k` buys ONE execution, not restored
# scheduling. Measured on the #639 host over a 27.8-minute window, by `runs`:
#
#   collect       2650 → 2653   (3 runs where ~28 were due)
#   cleanup       1877 → 1877   (0)    base-sync    1774 → 1774   (0)
#   dispatch      1929 → 1929   (0)    ledger-watch 6931 → 6931   (0)
#   issue-bridge 15684 → 15684  (0)    quotawatch   1583 → 1583   (0)
#
# Six of the seven were not throttled, they were DEAD — and each had been kicked
# by hand minutes before the window opened: that hand-kick was their last run. So
# a self-heal that only ever kickstarts keeps a 60s unit alive at one run per
# cooldown and never restores its cadence. Past FLEET_DAEMON_RELOAD_AFTER
# ineffective kicks, bin/fleet-daemon-watch.sh escalates to a real unload+reload
# of the unit, which is what an operator does by hand in this situation.
fleet_daemon_kick_fails() {
  printf '%s' "$(_fleet_daemon_epoch "$(fleet_daemon_state_dir "${2:-}")/${1:-}.kick.fails")"
}

# fleet_daemon_reload_after — ineffective kicks before escalating to a reload
# (0 disables the escalation and leaves kickstart as the only remedy).
fleet_daemon_reload_after() {
  _fd_ra="${FLEET_DAEMON_RELOAD_AFTER:-3}"
  case "$_fd_ra" in ''|*[!0-9]*) _fd_ra=3 ;; esac
  printf '%s' "$_fd_ra"
}

# fleet_daemon_reload_cooldown — seconds between two reloads of the same unit. Far
# longer than the kick cooldown: a reload tears the unit out of the domain and puts
# it back, so it is the heavier hammer and must not become the routine one.
fleet_daemon_reload_cooldown() {
  _fd_rc="${FLEET_DAEMON_RELOAD_COOLDOWN:-1800}"
  case "$_fd_rc" in ''|*[!0-9]*) _fd_rc=1800 ;; esac
  printf '%s' "$_fd_rc"
}

# fleet_daemon_kick_due <unit> [root] — 0 iff the unit is overdue AND its last kick
# is older than the cooldown. The cheap PRE-FILTER (two file reads, no fork) that
# callers gate on before spawning the watcher; the watcher re-checks and claims
# atomically, which is the actual rate limit.
fleet_daemon_kick_due() {
  [ -n "$(fleet_daemon_overdue "${1:-}" "${2:-}")" ] || return 1
  _fd_ka=$(fleet_daemon_kick_age "${1:-}" "${2:-}")
  [ -n "$_fd_ka" ] || return 0
  [ "$_fd_ka" -ge "$(fleet_daemon_kick_cooldown "${1:-}")" ]
}

# fleet_daemon_overdue_list [root] [skip-unit] — space-separated names of every
# registry unit that is currently overdue, in registry order. What the status bar
# renders and what fleet-doctor reports; empty in the healthy case. `skip-unit`
# drops one name (the bar renders `collect` in its own `⚠ dash stale` segment,
# because a frozen dash is the symptom operators already know that phrase for).
fleet_daemon_overdue_list() {
  _fd_out=''
  for _fd_u in $(fleet_daemon_unit_names); do
    [ "$_fd_u" = "${2:-}" ] && continue
    [ -n "$(fleet_daemon_overdue "$_fd_u" "${1:-}")" ] || continue
    _fd_out="${_fd_out:+$_fd_out }$_fd_u"
  done
  printf '%s' "$_fd_out"
}

# fleet_daemon_recent_kick [root] [skip-unit] — age in seconds of the MOST RECENT
# self-heal across the registry, or nothing if nothing was ever kicked. This is
# the aggregate TRACE: the status bar keeps showing it for FLEET_DAEMON_KICK_TRACE
# after the units recover, so a self-heal is never a silent one — #636's whole
# complaint was that the outage left no mark once it was over.
fleet_daemon_recent_kick() {
  _fd_min=''
  for _fd_u in $(fleet_daemon_unit_names); do
    [ "$_fd_u" = "${2:-}" ] && continue
    _fd_ka=$(fleet_daemon_kick_age "$_fd_u" "${1:-}")
    [ -n "$_fd_ka" ] || continue
    { [ -z "$_fd_min" ] || [ "$_fd_ka" -lt "$_fd_min" ]; } && _fd_min="$_fd_ka"
  done
  printf '%s' "$_fd_min"
}

# --- the launchd DOMAIN verdict (issue #711) -----------------------------------
# Everything above this line asks "is THIS unit being scheduled?". These three ask
# the question one level up — "is this user's launchd domain scheduling ANYTHING?"
# — and they are pure cache accessors, because the measurement that answers it
# needs launchctl and 40 seconds of wall clock, and neither belongs in a lib the
# status bar sources ten times every five seconds. bin/fleet-launchd-probe.sh does
# the measuring and writes the line; fleet-doctor reads it.
#
# WHY THE ANSWER IS WORTH CACHING AT ALL. On 2026-09-15 the whole gui/501 domain
# stopped spawning jobs on this host — nine of nine interval units at `Δruns = 0`,
# and a brand-new throwaway agent bootstrapped alongside them never ran once, not
# even its RunAtLoad. Every per-unit alarm above was telling the truth and the
# nine of them together told a lie: that the FLEET's daemons were broken. They
# were not; the same install on the same commit was ticking normally on the other
# machine. One line that says "the domain stopped spawning, this is machine state,
# log out or reboot" is worth more than nine accurate ones that send the operator
# to read plists.
#
# Line format (TSV, one line): <epoch> <verdict> <ticks> <window> <interval> <runs>
# Verdicts: ok · no-interval (RunAtLoad only) · no-spawn (nothing at all).
# `unknown` is never written — an unmeasured run must not overwrite a real verdict.
_fleet_daemon_probe_file() { printf '%s/launchd-probe.verdict' "$(fleet_daemon_state_dir "${1:-}")"; }

# fleet_daemon_probe_write <verdict> <ticks> <window> <interval> <runs> [root]
fleet_daemon_probe_write() {
  _fd_pf=$(_fleet_daemon_probe_file "${6:-}")
  mkdir -p "$(fleet_daemon_state_dir "${6:-}")" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${1:-unknown}" "${2:-0}" \
    "${3:-0}" "${4:-0}" "${5:--}" > "$_fd_pf" 2>/dev/null || return 0
  return 0
}

# fleet_daemon_probe_line [root] — the raw cached line, or nothing.
fleet_daemon_probe_line() {
  _fd_pf=$(_fleet_daemon_probe_file "${1:-}")
  [ -f "$_fd_pf" ] || return 0
  IFS= read -r _fd_pl < "$_fd_pf" 2>/dev/null || return 0
  printf '%s' "${_fd_pl:-}"
}

# fleet_daemon_probe_age [root] — seconds since the verdict was measured, or
# nothing if none was.
fleet_daemon_probe_age() {
  _fd_pt=''
  _fd_pline=$(fleet_daemon_probe_line "${1:-}")
  [ -n "$_fd_pline" ] || return 0
  _fd_pt=${_fd_pline%%	*}
  case "$_fd_pt" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' $(( $(fleet_now) - _fd_pt ))
}

# fleet_daemon_probe_verdict [root] [ttl] — the cached verdict iff it is younger
# than `ttl` (default FLEET_LAUNCHD_PROBE_TTL, 900s; 0 = any age). Empty means
# "nobody has measured this recently", which is NOT the same as "fine" — every
# caller must treat the two differently or it reintroduces the confident-but-
# unmeasured answer this whole mechanism exists to avoid.
fleet_daemon_probe_verdict() {
  _fd_pline=$(fleet_daemon_probe_line "${1:-}")
  [ -n "$_fd_pline" ] || return 0
  _fd_pa=$(fleet_daemon_probe_age "${1:-}")
  [ -n "$_fd_pa" ] || return 0
  _fd_pttl="${2:-${FLEET_LAUNCHD_PROBE_TTL:-900}}"
  case "$_fd_pttl" in ''|*[!0-9]*) _fd_pttl=900 ;; esac
  [ "$_fd_pttl" -eq 0 ] || [ "$_fd_pa" -lt "$_fd_pttl" ] || return 0
  # field 2 of the TSV line
  _fd_pv=${_fd_pline#*	}; _fd_pv=${_fd_pv%%	*}
  case "$_fd_pv" in ok|no-interval|no-spawn) printf '%s' "$_fd_pv" ;; esac
  return 0
}

# fleet_daemon_kicked_recently [root] [window] — how many registry units the
# self-heal has kicked inside `window` seconds (default 3600).
#
# THE SIGNAL THAT SURVIVES A WORKING SELF-HEAL (issue #711). "How many units are
# overdue right now" is the obvious way to spot a domain-wide stall, and it is the
# one that stops working the moment the self-heal is any good: each kick buys one
# execution, so the unit reads FRESH again for a whole interval and the count of
# simultaneously-overdue units collapses to one or two. Measured on the wedged
# host with kicks running: 1 unit overdue, and 9 units each kicked ~110 seconds
# earlier, every one of them logging the same `kick → stale again → kick` cycle.
#
# So the count of units under active self-heal is the honest measure of "this is
# not one broken daemon". On a healthy machine it is 0 — a kick only ever happens
# because something stopped being scheduled, which is why #636 made the trace
# visible in the first place.
fleet_daemon_kicked_recently() {
  _fd_kw="${2:-3600}"; case "$_fd_kw" in ''|*[!0-9]*) _fd_kw=3600 ;; esac
  _fd_kn=0
  for _fd_ku in $(fleet_daemon_unit_names); do
    _fd_ka=$(fleet_daemon_kick_age "$_fd_ku" "${1:-}")
    [ -n "$_fd_ka" ] || continue
    [ "$_fd_ka" -lt "$_fd_kw" ] && _fd_kn=$(( _fd_kn + 1 ))
  done
  printf '%s' "$_fd_kn"
}
