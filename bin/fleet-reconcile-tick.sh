#!/bin/bash
# fleet-reconcile-tick.sh — the state-reconcile unit's one bounded tick (T544,
# EPIC T542 C6): every 60 s, over every live fleet socket of this login,
#   1. fleet-state-reconcile.py  — a `working` window the agent itself says is
#      idle is demoted (#806)                                         ≤ 15 s
#   2. fleet-wait-reeval.sh      — an idle window's done ↔ looping + @claude_wait
#      is re-asked (#1376, #1880)                                     ≤ 15 s
#   3. fleet-cfg-restart.sh      — a session on an old configuration, idle long
#      enough, is reopened onto the current one (#1783)               ≤ 10 s
# and the four errands the retired quota watch used to run (T549, EPIC T542 C3),
# each clamped to what is left of the tick:
#   4. modelcap    — per fleet, `fleet-model-switch.sh --capped` probe; a window
#      walled on ONE model is switched in place (#569)  ≤ 20 s a fleet, 25 s all
#   5. proxyquota  — `fleet-proxy-quota.sh push`: the proxy's rate-limit reading
#      onto each window's @rl* stamps (#1978)                         ≤ 5 s
#   6. collectkick — the collector's self-heal, if its heartbeat went stale (#636) ≤ 5 s
#   7. alerts      — `fleet-alerts.sh write` re-raises / heals the alert set (#1238) ≤ 5 s
# Each one's seconds land in the heartbeat as t_<phase>=, a phase the tick had
# no room for in skipped_phases=.
# (the per-fleet worker-sleep scan that used to end it went with hibernation,
# T548 C8). Unit `reconcile` (com.claude-fleet.reconcile / claude-fleet-reconcile.timer);
# heartbeat global/reconcile.heartbeat; logs/reconcile.log holds only the lines
# that changed something. The whole tick stays ≤ 55 s under the 60 s interval.
# All state and tmux calls stay on fleet sockets.
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-daemon-lib.sh"
fleet_daemon_stamp_tick reconcile "$BIN/.."
deadline=$((SECONDS + 55))
sockets=$(fleet_sockets)
# State truth first (issue #806): a `working` window whose agent is natively idle
# (Claude's session registry, a bound Codex's RPC) past the grace is demoted here,
# so a Stop hook that never fired cannot pin the dash forever. It lives on its own
# tick, not in the spinner, so a wedged spinner no longer takes state truth down
# with it. Its heartbeat feeds fleet-doctor's `state` line.
# shellcheck disable=SC2086  # the socket list is newline-separated words by design
fleet_timebox 15 python3 "$BIN/fleet-state-reconcile.py" --cache-dir "$(fleet_cache_global)" -- $sockets || :
# …and the other half of that truth (issue #1376): an IDLE window's `done` ↔
# `looping` + @claude_wait, decided once at its Stop, is re-asked here — a child
# that finished, a background job that ended, a fleet tool call that returned
# (#1880), a window that stopped before #1370.
# shellcheck disable=SC2086
fleet_timebox 15 bash "$BIN/fleet-wait-reeval.sh" --quiet -- $sockets >/dev/null 2>&1 || :
# A session on an OLD configuration (issue #1783) that has been idle long enough
# is reopened onto the current one — same conversation, new window; the move
# itself runs detached (fleet-migrate.sh --cfg-stale), so this only picks.
# shellcheck disable=SC2086
fleet_timebox 10 bash "$BIN/fleet-cfg-restart.sh" --quiet -- $sockets >/dev/null 2>&1 || :

# --- the quota watch's four survivors (T549, EPIC T542 C3) --------------------
# The watch's own job — read every pool account's quota and warn / bench / move —
# is gone: a full subscription is the credential pool's to change. What it ran
# on the side still matters, so it runs here, each phase clamped to the tick.
G=$(fleet_cache_global); mkdir -p "$G" 2>/dev/null || :
PH_T=""; PH_SKIP=""
ph_left() {   # ph_left <own budget> — the smaller of it and the tick's remainder
  local l=$(( deadline - SECONDS - 5 ))
  [ "$l" -gt "$1" ] && l="$1"
  [ "$l" -lt 0 ] && l=0
  printf '%s' "$l"
}
ph_done() { PH_T="${PH_T}t_$1=$(( SECONDS - $2 ))"$'\n'; }
ph_skip() { PH_SKIP="${PH_SKIP}${PH_SKIP:+ }$1"; }

# 4. modelcap — a model cap ("You've reached your Fable limit", #524) is not the
# subscription wall: the session types `/model <fallback>` at its own prompt and
# keeps its process, background agents and context (#569). The probe is per
# fleet and budgeted (#582); the fleet whose probe was cut short is probed first
# next tick, and a timeout STREAK per fleet (reconcile.modelcap.<fleet>) is what
# fleet-doctor's modelcap row FAILs on (#706).
modelcap_health() {   # <fleet> ok|timeout [step]
  local f="$G/reconcile.modelcap.$1" st=0 lo=0
  [ -f "$f" ] && { st=$(sed -n 's/^streak=//p' "$f" | head -1); lo=$(sed -n 's/^lastok=//p' "$f" | head -1); }
  case "$st" in ''|*[!0-9]*) st=0 ;; esac
  case "$lo" in ''|*[!0-9]*) lo=0 ;; esac
  if [ "$2" = ok ]; then st=0; lo=$(date +%s); else st=$(( st + 1 )); fi
  printf 'streak=%s\nlastok=%s\nstep=%s\nat=%s\n' "$st" "$lo" "${3:-}" "$(date +%s)" > "$f" 2>/dev/null || :
}
if [ -n "$sockets" ] && [ -x "$BIN/fleet-model-switch.sh" ] \
   && [ -d "${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/accounts}" ]; then
  m0=$SECONDS
  mprobe="${FLEET_MODELCAP_PROBE_BUDGET:-20}"
  case "$mprobe" in ''|*[!0-9]*) mprobe=20 ;; esac
  mfirst=$(cat "$G/reconcile.modelcap.start" 2>/dev/null)
  msweep="$sockets"
  if [ -n "$mfirst" ] && printf '%s\n' "$sockets" | grep -qxF "$mfirst"; then
    msweep=$(printf '%s\n' "$sockets" | grep -xF "$mfirst"; printf '%s\n' "$sockets" | grep -vxF "$mfirst")
  fi
  : > "$G/reconcile.modelcap.start"
  for ms in $msweep; do
    mb=$(ph_left 25); [ "$(( 25 - (SECONDS - m0) ))" -lt "$mb" ] && mb=$(( 25 - (SECONDS - m0) ))
    [ "$mb" -gt "$mprobe" ] && mb="$mprobe"
    if [ "$mb" -lt 1 ]; then
      [ -s "$G/reconcile.modelcap.start" ] || printf '%s' "$ms" > "$G/reconcile.modelcap.start"
      ph_skip "modelcap:$ms"; continue
    fi
    mtr="$G/reconcile.modelcap.trace.$ms"; : > "$mtr" 2>/dev/null || :
    mout=$(FLEET_MODEL_SWITCH_TRACE="$mtr" fleet_timebox "$mb" "$BIN/fleet-model-switch.sh" --capped --dry-run --session "$ms" 2>/dev/null); mrc=$?
    if [ "$mrc" = 124 ]; then
      mstep=$(sed -n 's/^step=//p' "$mtr" 2>/dev/null | head -1)
      [ -s "$G/reconcile.modelcap.start" ] || printf '%s' "$ms" > "$G/reconcile.modelcap.start"
      modelcap_health "$ms" timeout "${mstep:-?}"
      printf 'fleet-reconcile-tick: modelcap probe on %s hit its %ss budget in step %s — killed, not swept this tick\n' "$ms" "$mb" "${mstep:-?}" >&2
      continue
    fi
    modelcap_health "$ms" ok
    mplan=$(printf '%s\n' "$mout" | grep -c '^  would:')
    case "$mplan" in ''|*[!0-9]*) mplan=0 ;; esac
    [ "$mplan" -gt 0 ] || continue
    printf 'fleet-reconcile-tick: %s walled window(s) on %s — switching in place\n' "$mplan" "$ms" >&2
    fleet_bg -L "$ms" "bash '$BIN/fleet-model-switch.sh' --capped --session '$ms' --alert"
  done
  ph_done modelcap "$m0"
fi

# 5. proxyquota — with the credential proxy on, each session's last rate-limit
# headers go onto its window (@rl*, `--from proxy`), so the top line's 剩余 % is
# the session's own (#1978). Nothing else writes those stamps on a proxy login.
if [ "${FLEET_CRED_PROXY:-0}" = 1 ] && [ -n "$sockets" ] && [ -x "$BIN/fleet-proxy-quota.sh" ]; then
  q0=$SECONDS; qb=$(ph_left 5)
  if [ "$qb" -ge 1 ]; then
    qpa=()
    for qs in $sockets; do qpa+=(--socket "$qs"); done
    fleet_timebox "$qb" "$BIN/fleet-proxy-quota.sh" push ${qpa[@]+"${qpa[@]}"} >/dev/null 2>&1 || :
    ph_done proxyquota "$q0"
  else ph_skip proxyquota; fi
fi

# 6. collectkick — launchd can pend com.claude-fleet.collect for an hour with
# `last exit code = 0` (#636); a stale collector heartbeat is kicked here,
# rate-limited and logged inside the kick script. The status bar and the
# KeepAlive spinner kick it too — this is the backstop.
if [ -f "$BIN/usage-lib.sh" ] && [ -f "$BIN/fleet-collect-kick.sh" ]; then
  # shellcheck source=/dev/null
  . "$BIN/usage-lib.sh"
  if command -v fleet_collect_kick_due >/dev/null 2>&1 && fleet_collect_kick_due; then
    k0=$SECONDS; kb=$(ph_left 5)
    if [ "$kb" -ge 1 ]; then fleet_timebox "$kb" bash "$BIN/fleet-collect-kick.sh" >/dev/null 2>&1 || :; ph_done collectkick "$k0"
    else ph_skip collectkick; fi
  fi
fi

# 7. alerts — the alert set is written once a minute even when nothing else
# changed, so a condition that ended heals and one that holds is re-raised (#1238).
if [ -f "$BIN/fleet-alerts.sh" ]; then
  a0=$SECONDS; ab=$(ph_left 5)
  if [ "$ab" -ge 1 ]; then fleet_timebox "$ab" bash "$BIN/fleet-alerts.sh" write >/dev/null 2>&1 || :; ph_done alerts "$a0"
  else ph_skip alerts; fi
fi

# The pool's settings from the hub (issue #2029): detached and TTL-gated inside,
# so a slow hub never costs this tick.
[ -f "$BIN/fleet-hub-pool.sh" ] && ( nohup bash "$BIN/fleet-hub-pool.sh" fetch </dev/null >/dev/null 2>&1 & )

# The phases' seconds go into the state reconcile's own heartbeat (it rewrites
# the file every tick; an earlier tick's t_ lines are dropped either way).
rhb="$G/reconcile.heartbeat"
{ grep -Ev '^(t_|skipped_phases=)' "$rhb" 2>/dev/null
  printf '%sskipped_phases=%s\n' "$PH_T" "$PH_SKIP"; } > "$rhb.$$" && mv -f "$rhb.$$" "$rhb"
exit 0
