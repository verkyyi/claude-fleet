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
_fleet_daemon_key() { printf '%s' "${1:-}" | tr 'a-z-' 'A-Z_'; }

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
  mkdir -p "$_fd_d" 2>/dev/null || return 0
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
  _fd_nw=$(date +%s)
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
  _fd_a=$(( $(date +%s) - _fd_t ))
  [ "$_fd_a" -ge "$(fleet_daemon_stale_secs "${1:-}")" ] && printf '%s' "$_fd_a"
  return 0
}

# fleet_daemon_kick_age <unit> [root] — seconds since this unit was last kicked, or
# nothing if it never was. The TRACE: the status bar keeps showing it for
# FLEET_DAEMON_KICK_TRACE after the unit recovers, so a self-heal is never silent.
fleet_daemon_kick_age() {
  _fd_k=$(_fleet_daemon_epoch "$(fleet_daemon_state_dir "${2:-}")/${1:-}.kick.ts")
  [ "$_fd_k" -gt 0 ] || return 0
  printf '%s' $(( $(date +%s) - _fd_k ))
  return 0
}

# fleet_daemon_kick_cooldown <unit> — seconds between two kicks of the same unit.
# FLEET_COLLECT_KICK_COOLDOWN still governs `collect` (#638's knob).
fleet_daemon_kick_cooldown() {
  _fd_c=''   # the eval below sets it from the per-unit env override, if any
  eval "_fd_c=\${FLEET_DAEMON_KICK_COOLDOWN_$(_fleet_daemon_key "${1:-}"):-}"
  [ -z "$_fd_c" ] && [ "${1:-}" = collect ] && _fd_c="${FLEET_COLLECT_KICK_COOLDOWN:-}"
  [ -z "$_fd_c" ] && _fd_c="${FLEET_DAEMON_KICK_COOLDOWN:-${FLEET_COLLECT_KICK_COOLDOWN:-600}}"
  case "$_fd_c" in ''|*[!0-9]*) _fd_c=600 ;; esac
  printf '%s' "$_fd_c"
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
