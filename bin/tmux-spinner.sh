#!/bin/sh
# tmux-spinner.sh — frame-driver for the Claude session status animation.
# The animated element is the GLYPH's FONT COLOR only (spinner fades cyan while
# working, "!" fades red for needs). The window NAME is calm static text — no
# background block. Per window the daemon sets three options:
#   @spin  glyph text  (⠋… / ✓ / ! / blank)
#   @sfg   glyph fg hex (pulsing for working/needs)
#   @nfg   name  fg hex (static per state)
# window-status-format writes the #[fg=..] directives DIRECTLY and only
# substitutes these hex values, so styling is guaranteed to render.
#
# Single writer; change-detected; all changed windows for a frame apply in ONE
# `tmux source-file` -> the bar repaints once per frame. Static windows written
# once. Run from launchd (com.claude-fleet.spinner, KeepAlive) or any daemon
# supervisor. SPIN_INTERVAL = seconds per frame.
#
# ONE tmux PROCESS PER ANIMATING FLEET PER FRAME, ≤1/s PER QUIET ONE (issue #887).
# This loop used to run `list-windows -a` on every socket on EVERY frame, animated
# or not — 8 reads a second per fleet for a window table that changes every few
# minutes — and made tmux the most-spawned program on the machine (~215 exec/s).
# Now:
#   · a fleet with something animating is read by the SAME process that writes its
#     frame (`list-windows ';' source-file`): the read it rides on costs no fork,
#     and it is at most one frame old, as before.
#   · a quiet fleet is re-read every IDLE_READ_SECS, or at once when its dirty
#     marker appears (set-claude-state.sh touches it on every hook write — see
#     DIRTY MARKER below). Every other writer of @claude_state (the classifier, the
#     sweeps below, fleet-account/migrate, the python helpers) is caught by the
#     IDLE_READ_SECS re-read, so nothing is later than 1s behind.
#   · with nothing animating anywhere, the loop ticks every IDLE_TICK_SECS instead
#     of every frame, and every throttle below counts frame-EQUIVALENTS, so the
#     stuck/needs/kick/heartbeat cadences do not stretch when it does.
# Each tmux call is counted (TMUX_N) and the heartbeat publishes the rate.
#
# Three throttled side errands ride this loop, because being KeepAlive makes it the
# one fleet daemon that is always already running: the stuck-working sweep
# (issue #101), the stale-`needs` reconcile (issue #658) and the INTERVAL-DAEMON
# self-heal (issues #636, #639). All three exist for the same reason — a state
# written on an event and never re-checked outlives the event.
set -u  # POSIX sh: pipefail is bash-only (dash has none)
INTERVAL="${SPIN_INTERVAL:-0.12}"
NFRAMES=10
CMDF="${TMPDIR:-/tmp}/.claude-spin.cmds"
NAME_WORKING='#a9b1d6'   # calm neutral name while working
NAME_DONE='#9ece6a'
NAME_NEEDS='#f7768e'
NAME_IDLE='#565f89'
NL='
'   # literal newline — accumulator delimiter for the cross-fleet pass (issue #236)

# Global config (FLEET_STUCK_WORKING_SECS lives here). Sourced ONCE at startup,
# like the other daemons — a change needs a spinner restart.
BIN=$(cd "$(dirname "$0")" && pwd)
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
mkdir -p "$BIN/../logs" 2>/dev/null

# --- per-fleet sockets (issue #159) -----------------------------------------
# Each fleet runs on its OWN tmux server/socket now, so there is no single
# `tmux list-windows -a` that sees every fleet — this daemon fans every query out
# across the live fleet sockets. fleet-lib.sh's fleet_sockets can't be sourced
# here (this is POSIX /bin/sh; that file's process substitutions are bash-only
# and would fail to parse under dash), so inline a byte-equivalent POSIX copy.
# KEEP IN SYNC with fleet_sockets() in bin/fleet-lib.sh — except the liveness
# probe, which is `_sock_live` here (issue #887, below).
FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# Every tmux this daemon runs goes through here, so the heartbeat can publish how
# many it forks (issue #887: `tmux_calls_per_s=`, read by fleet-doctor's machine
# line). A call inside `$(…)` counts in the subshell and is lost — those sites add
# their own `TMUX_N=$((TMUX_N + 1))` beside the call.
TMUX_N=0
tmux() { TMUX_N=$((TMUX_N + 1)); command tmux "$@"; }

# Where `tmux -L <label>` puts its socket: tmux's own rule, resolved from THIS
# process's environment exactly as the tmux client below will resolve it. Used
# only to find the hook's dirty marker (DIRTY MARKER, below the sweeps).
TSOCKDIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u 2>/dev/null)"

# _sock_live <label> — the fleet_sockets probe, made cheap (issue #887). The lib's
# form forks a `has-session` for every fleet conf on disk every refresh — retired
# fleets included — which with a handful of dead confs was a steady ~2-4 tmux/s by
# itself. Two short-cuts:
#   · a label this loop READ successfully since the last refresh is live — that
#     read was a stronger probe than has-session (a failed read clears SOCK_KNOWN).
#     Exact.
#   · a label whose probe FAILED is not re-probed until SOCK_DEAD is cleared, every
#     DEAD_EVERY-th refresh (~6s) — the price is that a fleet brought up from a conf
#     that already existed starts animating up to ~6s later instead of ~2s.
#     (Not a socket-file test: the selftests' PATH-shim pattern points `-L` at an
#     `-S` path, which a file test would read as "no server".)
SOCK_KNOWN=' '
SOCK_DEAD=' '
_sock_live() {
  case "$SOCK_KNOWN" in *" $1 "*) return 0 ;; esac
  case "$SOCK_DEAD" in *" $1 "*) return 1 ;; esac
  tmux -L "$1" has-session -t "$1" 2>/dev/null && return 0
  SOCK_DEAD="$SOCK_DEAD$1 "
  return 1
}
fleet_sockets() {
  [ -d "$FLEET_CONF_DIR" ] || return 0
  # New per-fleet layout (#181): fleets/<sess>/conf, label = the DIRECTORY basename
  # (NOT `basename … .conf`, which would yield "conf"). Iterating the flat
  # *.conf glob matched nothing post-migration and broke discovery (issue #203).
  if [ -d "$FLEET_CONF_DIR/fleets" ]; then
    for _d in "$FLEET_CONF_DIR"/fleets/*/; do
      [ -d "$_d" ] || continue
      [ -f "${_d}conf" ] || continue
      _label=${_d%/}; _label=${_label##*/}
      _sock_live "$_label" && printf '%s\n' "$_label"
    done
  fi
  # Dual-read the legacy flat <sess>.conf (label = basename .conf) for a
  # half-migrated estate, but skip a session already covered by a new-layout dir.
  for _cf in "$FLEET_CONF_DIR"/*.conf; do
    [ -f "$_cf" ] || continue
    _label=$(basename "$_cf" .conf)
    [ -f "$FLEET_CONF_DIR/fleets/$_label/conf" ] && continue
    _sock_live "$_label" && printf '%s\n' "$_label"
  done
}
# The live socket list is refreshed on a ~2s throttle (fleets come/go rarely; a
# new WORKER window inside a known fleet still animates instantly because we
# already hold that fleet's socket). SOCK_EVERY = frames between refreshes.
SOCK_REFRESH_SECS=2
SOCK_EVERY=$(awk -v c="$SOCK_REFRESH_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
socc=0
DEAD_EVERY=3   # refreshes between re-probes of a dead label (issue #887, _sock_live)
deadc=0
SOCKETS=''

# --- stuck-working demotion (issue #101) ------------------------------------
# A window pinned at @claude_state=working whose Stop hook was missed (crash /
# race / a turn that didn't emit Stop) stays "working" FOREVER — the classifier
# backstop deliberately skips working windows, trusting the hook heartbeat. Catch
# it MARKER-AGNOSTICALLY (never grep the pane for "esc to interrupt" — not every
# working sub-state renders it, so that would false-demote busy sessions): a
# genuinely-working Claude session repaints its pane at least once/second (the
# elapsed-time counter ticks), so tmux's #{window_activity} stays fresh; a
# stopped session's pane freezes and its activity goes stale. So a working window
# whose window_activity age exceeds FLEET_STUCK_WORKING_SECS is provably idle ->
# demote to done and kick classify-sessions.sh to refine it (done|needs|looping).
# Non-LLM, per-tick-cheap, and biased HARD to false-negatives: the large
# threshold plus a 2-strike debounce make a false demote of a live session
# effectively impossible (validated — live workers and an 18s SILENT tool call
# never exceeded 1s of activity age; see the PR). Set to 0 to disable.
STUCK_SECS="${FLEET_STUCK_WORKING_SECS:-120}"
case "$STUCK_SECS" in ''|*[!0-9]*) STUCK_SECS=120 ;; esac  # non-integer -> default (0 disables)
STUCK_LOG="$BIN/../logs/stuck.log"
STUCK_CHECK_SECS=10   # evaluate at most ~every 10s, not every frame
# frames between checks (~STUCK_CHECK_SECS / INTERVAL); computed once, min 1.
STUCK_EVERY=$(awk -v c="$STUCK_CHECK_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
sc=0            # frame counter for the throttle

# --- interval-daemon self-heal throttle (issues #636, #639) ------------------
# See the call site in the frame loop for why the SPINNER is the daemon that
# carries this. Same throttle idiom as the stuck sweep above: frames, computed
# once from the frame interval, at least 1.
KICK_CHECK_SECS=30
KICK_EVERY=$(awk -v c="$KICK_CHECK_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
kc=0

# --- liveness heartbeat (issue #677) -----------------------------------------
# This daemon is the ONLY thing that can unpin a window whose Stop hook never
# fired — and /fleet-handoff's whole auto-cycle rests on that (a capped turn, #580,
# is otherwise `working` forever and WAIT-IDLE can only time out). So "is the
# spinner running?" stopped being a cosmetic question and became a load-bearing
# one, and nothing could answer it: this unit is KeepAlive, so it is deliberately
# absent from the interval-daemon registry (bin/fleet-daemon-lib.sh) that every
# other daemon's liveness is read from, and `launchctl list` only reports whether
# launchd HOLDS a pid — not whether the frame loop is still turning.
#
# So stamp one. A wedged-but-alive spinner is the failure that matters (a dead one
# KeepAlive restarts within seconds), and only the loop itself can disprove that.
# Read by fleet-doctor.sh and by fleet-handoff-cycle.sh's abort diagnosis.
SPIN_HB="$BIN/../logs/spinner.heartbeat"
HB_CHECK_SECS="${SPIN_HB_SECS:-20}"   # nominal; a frame-EQUIVALENT count, so the real cadence is ~20-30s
case "$HB_CHECK_SECS" in ''|*[!0-9]*) HB_CHECK_SECS=20 ;; esac
HB_EVERY=$(awk -v c="$HB_CHECK_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
hbc=0
# tmp+rename so a reader never catches a half-written stamp.
#
# FORMAT: `<epoch> tmux_calls_per_s=<n.n>` (issue #887). The FIRST token stays the
# bare epoch — fleet-doctor's handoff check and fleet-handoff-cycle.sh read it with
# `${hb%% *}` — and the rate is this daemon's own tmux forks since the previous
# stamp (fleet-doctor's machine line greps it). The startup stamp has no previous
# one to measure from, so it carries the epoch alone.
HB_T='' HB_N=0
hb_stamp() {
  _now=$(date +%s 2>/dev/null) || return 0
  _rate=''
  if [ -n "$HB_T" ] && [ "$_now" -gt "$HB_T" ]; then
    _d=$((_now - HB_T))
    _x=$(( ((TMUX_N - HB_N) * 10 + _d / 2) / _d ))   # tenths, rounded — sh has no floats
    _rate=" tmux_calls_per_s=$((_x / 10)).$((_x % 10))"
    HB_T=$_now; HB_N=$TMUX_N
  elif [ -z "$HB_T" ]; then
    HB_T=$_now; HB_N=$TMUX_N
  fi
  printf '%s%s\n' "$_now" "$_rate" > "$SPIN_HB.tmp" 2>/dev/null && mv -f "$SPIN_HB.tmp" "$SPIN_HB" 2>/dev/null
}
# --- idle nap (issue #1077) ----------------------------------------------------
# With no live fleet the loop below used to turn every 2s for ever — a socket
# probe, a heartbeat fork and a `sleep` 1800 times an hour on a login nobody is
# using. Past FLEET_DAEMON_IDLE_AFTER (default 300s; 0 = off) of no fleet it naps
# IDLE_NAP_SECS (60) instead: still well inside the 180s the heartbeat readers
# allow (fleet-doctor, fleet-handoff-cycle), and a fleet brought up mid-nap is
# picked up within that minute. A spawn's wake marker (fleet_daemon_wake) restarts
# the 2s grace, and any live socket ends the spell. The lib is POSIX and pure —
# sourced guarded, like every daemon's use of it: without it the nap is off.
IDLE_NAP_SECS=60
IDLE_AFTER=0 WAKE_F='' IDLE_T0=''
# shellcheck source=/dev/null
if [ -f "$BIN/fleet-daemon-lib.sh" ] && . "$BIN/fleet-daemon-lib.sh" 2>/dev/null; then
  IDLE_AFTER=$(fleet_idle_after)
  WAKE_F="$(fleet_daemon_state_dir "$BIN/..")/wake"
fi
# idle_nap — how long the no-fleet branch sleeps: 2 in the grace window, else the
# nap. Reads `_now` from the hb_stamp just before it (no fork of its own).
idle_nap() {
  NAP=2
  [ "$IDLE_AFTER" -gt 0 ] 2>/dev/null || return 0
  case "${_now:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$IDLE_T0" ] || IDLE_T0=$_now
  _iw=''
  [ -f "$WAKE_F" ] && IFS= read -r _iw < "$WAKE_F" 2>/dev/null
  case "$_iw" in ''|*[!0-9]*) _iw=0 ;; esac
  [ "$_iw" -gt 0 ] && [ "$_iw" -ge "$IDLE_T0" ] && IDLE_T0=$_now   # a spawn: restart the grace
  [ $(( _now - IDLE_T0 )) -ge "$IDLE_AFTER" ] && NAP=$IDLE_NAP_SECS
  return 0
}

hb_stamp   # once at startup, so a freshly (re)started spinner is never read as dead
           # during the first throttle window — on a KeepAlive unit that window is
           # every restart, and "no heartbeat at all" is the doctor's loudest verdict.

STUCK_STRIKES='|'   # window_ids that were stale on the PREVIOUS check (2-strike debounce)
STUCK_SCREENS=''    # sidebar workers: socket:window:pane|screen checksum|last change

# stuck_check — one throttled sweep: demote any working window whose pane has
# been frozen (window_activity stale >= STUCK_SECS) across two consecutive checks.
# Runs in the current shell (here-doc, no pipe) so STUCK_STRIKES persists.
stuck_check() {
  nows=$(date +%s)
  new='|'
  new_screens=''
  demoted=0
  # Fan out over every live fleet socket. window_id (@N) is unique only WITHIN a
  # server, so the strike key + demote target are namespaced by "<sock>:<wid>" and
  # the demote/classify run against that socket's -L.
  # Only sockets whose last read showed an ANIMATED window (ANIM_SOCKS, issue #887):
  # a `working` window animates by definition, so a quiet fleet has no candidate and
  # its scan was a tmux fork that could only ever find nothing.
  # Standalone (a selftest sourcing this function without the loop) there is no
  # ANIM_SOCKS yet: fall back to every socket, which is what it used to scan.
  for sock in ${ANIM_SOCKS-$SOCKETS}; do
  TMUX_N=$((TMUX_N + 1))
  wl=$(tmux -L "$sock" list-windows -a -F '#{window_id} #{@claude_state} #{window_activity} #{@sidebar_worker}' 2>/dev/null) || continue
  while read -r wid st act worker; do
    [ -n "$wid" ] || continue
    [ "$st" = working ] || continue
    # A sidebar's output is window activity too. While it is present, measure
    # changes to the AGENT screen instead, so a busy fleet list cannot keep a
    # frozen worker alive forever. Missing captures fail open; a new sample
    # starts a fresh grace period, and the table is pruned on every sweep.
    if [ -n "$worker" ]; then
      TMUX_N=$((TMUX_N + 1))
      screen=$(tmux -L "$sock" capture-pane -p -t "$worker" 2>/dev/null) || continue
      digest=$(printf '%s' "$screen" | cksum)
      screenkey="$sock:$wid:$worker"
      old=${STUCK_SCREENS#*"$NL$screenkey|"}
      old=${old%%"$NL"*}
      act=$nows
      if [ "${old%|*}" = "$digest" ]; then act=${old##*|}; fi
      new_screens="$new_screens$NL$screenkey|$digest|$act"
    fi
    case "$act" in ''|*[!0-9]*) continue ;; esac   # need a numeric activity stamp
    age=$(( nows - act ))
    [ "$age" -ge "$STUCK_SECS" ] || continue        # still fresh -> not stuck, no strike
    skey="$sock:$wid"
    case "$STUCK_STRIKES" in
      *"|$skey|"*)                                   # stale last check too -> 2nd strike -> demote
        tmux -L "$sock" set-window-option -t "$wid" @claude_state 'done' 2>/dev/null
        tmux -L "$sock" set-window-option -t "$wid" @claude_needs '' 2>/dev/null   # #640: no stale reason on a fresh state
        tmux -L "$sock" set-window-option -t "$wid" @claude_state_ts "$nows" 2>/dev/null
        printf '%s  %-10s working -> done (idle %ss; stop-hook missed)\n' \
          "$(date +%H:%M:%S)" "$skey" "$age" >> "$STUCK_LOG"
        ( CLASSIFY_SOCK="$sock" "$BIN/classify-sessions.sh" --window "$wid" >/dev/null 2>&1 & )   # refine done|needs|looping
        demoted=1 ;;
      *) new="$new$skey|" ;;                         # 1st strike -> arm for next check
    esac
  done <<EOF
$wl
EOF
  done
  STUCK_STRIKES="$new"
  STUCK_SCREENS="$new_screens"
  [ "$demoted" = 1 ] && [ -f "$STUCK_LOG" ] && \
    { tail -n 300 "$STUCK_LOG" > "$STUCK_LOG.tmp" 2>/dev/null && mv "$STUCK_LOG.tmp" "$STUCK_LOG" 2>/dev/null; }
}

# --- stale-`needs` reconcile (issue #658) ------------------------------------
# @claude_state is written on EVENTS — a hook edge, a classifier verdict — and then
# never re-read against reality, so a red that was RIGHT when it was stamped stays
# red long after its cause is gone: nothing re-evaluates a window that is not moving.
# Two shapes of that were live on 2026-09-14. A window whose Claude EXITED while red
# can never fire another hook. And two windows sat at `⊘` ("only a human may press
# this") over an open AskUserQuestion — stamped by the pre-#657 wording rule minutes
# before the fix went live, and unreachable by it afterwards, because a session
# BLOCKED on a dialog fires no further hook. A red the operator is told not to touch,
# on a question they could have answered from the dash with ⌃k, is #640's value
# exactly inverted — and it is self-sealing, because the mislabel is what stops the
# operator from ending it.
#
# So the spinner reconciles the stamp against the transcript. It is the daemon that
# can: KeepAlive, already iterating every window, and the one unit still alive when
# launchd stops spawning the interval units (#639). Per candidate window it asks
# bin/fleet-pending-tool.sh — the SAME "tool_use with no tool_result" oracle that
# stamped the subtype (#656) and that fleet-answer.sh/fleet-permission.sh act on —
# and applies one of three verdicts:
#
#   ask|perm + nothing pending   → clear to `done` (the red is provably over)
#   any subtype + no live Claude → clear to ``     (nothing can be waiting)
#   ask|perm + something pending → re-settle the SUBTYPE only (ask ⇄ perm); the
#                                  window stays red, and @claude_state_ts is left
#                                  alone because the session's last activity did
#                                  not move — only our reading of it did.
#
# ONE DIRECTION ONLY. It never creates a `needs` and never re-reddens a window.
# Inferring a red out of band is the hook's job; a second guesser would only
# manufacture false alarms, which is the failure this whole file exists to avoid.
# It also does NOT kick the classifier afterwards (unlike the stuck-working demote):
# the classifier CAN return `needs` off a stale screen, which would re-redden what
# was just cleared and flap every tick.
#
# WHAT "nothing pending" PROVES — AND HOW LONG TO WAIT BEFORE ACTING ON IT (#699).
# `ask`/`perm` are DEFINED by a pending tool_use (#656 settles both off this very
# oracle), so an empty transcript refutes the stamp outright: clear it at the ordinary
# grace. An EMPTY subtype is weaker evidence, and #658 treated it as no evidence at
# all — it required ask|perm here, so a plain `needs` produced NO verdict and nothing
# ever cleared it. That is the 1.5-hour zombie red #699 was filed on.
#
# That guard stranded a whole red PATH, not a handful of legacy stamps. An empty
# subtype is what bin/classify-sessions.sh writes — it clears the subtype by design
# (#640: a screen read cannot justify one) — and the classifier only ever runs at
# Stop, where a pending tool_use cannot exist. So "empty ⇒ never clearable" meant
# "the classifier's red is never clearable", however stale it got.
#
# But clearing it at the SAME 20s grace is no better, because that red is a real
# CATEGORY and not merely a relic: a worker that ends its turn asking the operator a
# question IN PROSE is genuinely waiting on a human, with no tool_use open. (Live,
# 2026-09-15: a window stopped after #648 with "merging is outward-facing and
# irreversible — you haven't said to merge". That red was correct. It became a zombie
# only once the operator merged by hand and nothing came back to clear it.) At 20s
# that red would be gone before the operator ever looked — a useful signal destroyed
# to fix a stale one.
#
# So the empty subtype gets its own, much longer age: FLEET_NEEDS_PLAIN_SECS. THE
# NUMBER IS A TRADE, and that trade is the whole reason the knob is separate:
#   lower  → a real "I asked you something" red fades while the operator is away from
#            the dash — the signal exists and is never seen.
#   higher → a stale red survives longer; the zombie ceiling rises with it.
# 900s (15 min) keeps a real question inside an operator's dash-checking rhythm while
# capping a zombie at a quarter hour instead of the 1.5 hours #699 measured. 0
# collapses it onto the ordinary grace (#699's literal proposal); a very large value
# restores #658's "an empty subtype is never clearable".
#
# The DEAD verdict below is deliberately NOT slowed by any of this: "no live Claude
# under the pane" is not weak evidence about what is open — it is proof that nothing
# can be.
#
# A `blocked` subtype (issue #704) gets NO dwell at all — it is never `idle`. It is
# the worker's own declaration (`set-claude-state.sh blocked`, the charter's
# `⛔ blocked` rail), and "nothing pending in the transcript" is precisely what a
# blocked worker looks like: it commented, stamped, reported and stopped. An empty
# transcript refutes an `ask`, dates a classifier's guess, and says nothing about a
# blocked. What clears it is the hook, on the next prompt — or `dead`, which is the
# one verdict here that proves the declaration has no one left to make it.
#
# GRACE ON BOTH AXES. A stamp younger than one window is still settling (PreToolUse
# stamps `ask` a beat before the transcript line lands), and the same verdict must
# repeat across two consecutive checks before anything is written — the 2-strike
# idiom the stuck-working sweep above uses, keyed on the VERDICT so a changed reading
# restarts the count. Effective grace: FLEET_NEEDS_RECONCILE_SECS to 2×.
#
# COST, measured on this machine (2026-09-14): ~150 ms per CANDIDATE — a bash hop +
# `ps` tree walk to find the pane's Claude (~70 ms) and a python read of the
# transcript (~35 ms on a 2.1 MB file), plus two `sh` startups. Candidates are only
# windows already stamped `needs` (0-2 on a live fleet), the check runs at most every
# FLEET_NEEDS_RECONCILE_SECS, and the per-FRAME cost is one integer compare — the
# frame loop's own budget is untouched. NEEDS_BUDGET bounds a pathological fleet from
# stalling the animation; the windows it skips are picked up by the next check.
# Set FLEET_NEEDS_RECONCILE_SECS=0 to disable.
NEEDS_SECS="${FLEET_NEEDS_RECONCILE_SECS:-20}"
case "$NEEDS_SECS" in ''|*[!0-9]*) NEEDS_SECS=20 ;; esac   # non-integer -> default (0 disables)
# The EMPTY-subtype dwell (issue #699) — see the trade documented above. It gates the
# `idle` verdict only: `dead` stays on NEEDS_SECS, and 0 means "no extra dwell".
NEEDS_PLAIN_SECS="${FLEET_NEEDS_PLAIN_SECS:-900}"
case "$NEEDS_PLAIN_SECS" in ''|*[!0-9]*) NEEDS_PLAIN_SECS=900 ;; esac
NEEDS_LOG="$BIN/../logs/needs.log"
NEEDS_BUDGET=8
NEEDS_EVERY=$(awk -v c="$NEEDS_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
nc=0
# The strike table is a FILE, not a variable, for two reasons: `tmux-spinner.sh
# --needs-check` runs one pass out of band (an operator forcing a reconcile without
# waiting for the daemon; the selftest driving exactly N passes), and it must observe
# the same two-checks-agree rule the daemon does. Its first field is the epoch of the
# check that wrote it: a table older than the strike TTL is DISCARDED, so a restart
# — or a long-dead one-shot — never lets a single stale reading count as agreement.
#
# THAT TTL IS ITS OWN KNOB (issue #691), defaulting to 3x the interval. It used to BE
# only that expression, which quietly turned the 2-strike rule back into a WALL-CLOCK
# rule for anyone who turned the interval down. bin/needs-reconcile-selftest.sh drives
# passes by COUNT at FLEET_NEEDS_RECONCILE_SECS=1 precisely so it does not depend on
# wall time — and inherited a THREE-SECOND deadline for its arm-then-act pair, each
# pass of which forks a candidate scan plus a fleet-pending-tool.sh per red window. On
# a loaded machine the two passes drifted past 3s, the first strike aged out, the
# second could only re-arm, and the assertion went red with nothing wrong in the code
# under test. Pinning "two checks agree" by count therefore means holding NEEDS_SECS
# low and FLEET_NEEDS_STRIKE_TTL high: the two numbers answer different questions —
# how OFTEN to look, and how long one reading stays meaningful — and only stayed
# welded together because the daemon never needs them apart. Its own default is
# unchanged (20s ⇒ 60s), which is roomy against a ~1-pass-per-20s cadence. Unlike
# FLEET_NEEDS_RECONCILE_SECS, 0 here is not "disabled" but its literal reading — no
# previous table is ever recent enough — so every pass can only arm and nothing is
# ever written. A non-integer falls back to the default rather than meaning that.
NEEDS_STRIKE_F="$BIN/../logs/.needs-strikes"

# FLEET_NEEDS_TRACE=1 — log EVERY pass, not just the ones that acted (issue #675).
#
# needs.log is a record of what the reconcile DID: a pass that only arms a strike
# writes nothing at all. That is the right default — a daemon ticking every 20s
# forever would otherwise bury the verdicts under 4300 lines a day of "looked,
# changed nothing" — but it leaves the one question a stalled reconcile raises
# unanswerable. When #675 was filed, seven assertions went red reading `got:
# state=needs` and nothing else: a daemon that never started, a pass starved out
# by NEEDS_BUDGET, and twenty passes that could never get two readings to agree
# (which is what it turned out to be — the 3s strike TTL of #691) all present as
# the identical "the state did not change", with no evidence on disk to tell them
# apart. One line per pass — candidates seen, verdicts acted, candidates starved,
# and the exact set armed for next time — separates all three. Off by default;
# bin/needs-reconcile-selftest.sh drives its own daemon with it ON, so a red run
# there arrives WITH the trace instead of sending the next reader back to guessing.
NEEDS_TRACE="${FLEET_NEEDS_TRACE:-0}"

# needs_check <sockets> — one reconcile pass over the `needs` windows of those
# sockets. The daemon passes only the sockets whose last read showed a `needs`
# window (NEEDS_SOCKS, issue #887) — the rest cannot hold a candidate; the one-shot
# passes them all. Runs in the current shell (here-doc, no pipe) so the budget and
# the strike accumulator persist.
needs_check() {
  nows=$(date +%s)
  new='|'
  prev='|'
  # Last check's readings, if they are recent enough to mean "the previous check".
  # Resolved HERE rather than at parse time on purpose: the --needs-check one-shot
  # below raises NEEDS_SECS off 0 after this function is defined, and the default
  # must follow the value the pass actually runs with. A non-integer falls back the
  # same way NEEDS_SECS itself does.
  _ttl="${FLEET_NEEDS_STRIKE_TTL:-}"
  case "$_ttl" in ''|*[!0-9]*) _ttl=$(( NEEDS_SECS * 3 )) ;; esac
  if [ -f "$NEEDS_STRIKE_F" ]; then
    _pl=$(cat "$NEEDS_STRIKE_F" 2>/dev/null)
    _pt=${_pl%% *}
    case "$_pt" in
      ''|*[!0-9]*) : ;;
      *) [ $(( nows - _pt )) -le "$_ttl" ] && prev="${_pl#* }" ;;
    esac
  fi
  left="$NEEDS_BUDGET"
  touched=0
  ncand=0 nstarved=0   # trace counters (issue #675) — three ints, no forks
  needs_fmt='#{window_id} #{?@worker_lifecycle,#{@worker_lifecycle},#{?@claude_state,#{@claude_state},-}} #{?@claude_needs,#{@claude_needs},-} #{?@claude_state_ts,#{@claude_state_ts},0} #{?@cc_agent,#{@cc_agent},claude}'
  for sock in $1; do
    [ "$left" -gt 0 ] || break
    # Own scan, like stuck_check's: window_id (the write target, stable across
    # re-slotting) plus the three stamps the verdict needs. '-'/'0' placeholders keep
    # the fields parsing when an option is empty (issue #105).
    TMUX_N=$((TMUX_N + 1))
    wl=$(tmux -L "$sock" list-windows -a -F "$needs_fmt" 2>/dev/null) || continue
    while read -r wid st nsub ts agent; do
      [ -n "$wid" ] || continue
      [ "$st" = needs ] || continue                       # ONLY red windows are candidates
      case "$agent" in ''|claude) : ;; *) continue ;; esac # Claude transcript oracle only (#730)
      [ "$left" -gt 0 ] || { nstarved=$((nstarved + 1)); continue; }   # budget spent; next check resumes
      case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
      [ $(( nows - ts )) -ge "$NEEDS_SECS" ] || continue   # fresh stamp — still settling
      left=$((left - 1)); ncand=$((ncand + 1))
      name=$("$BIN/fleet-pending-tool.sh" -L "$sock" "$wid" 2>/dev/null); prc=$?
      verdict=''; want=''
      case "$prc" in
        3) verdict=dead ;;                                # no Claude under the pane
        1) case "$nsub" in                                # read the transcript: nothing open
             ask|perm) verdict=idle ;;                    # transcript-defined ⇒ refuted outright
             blocked) : ;;                                # worker-declared (#704): silence is its normal state
             *) if [ $(( nows - ts )) -ge "$NEEDS_PLAIN_SECS" ]; then verdict=idle; fi ;;
           esac ;;                                        # …a screen verdict serves its dwell first
        0) case "$nsub" in                                # something IS open — is it what we said?
             ask|perm)
               want=perm; [ "$name" = AskUserQuestion ] && want=ask
               [ "$want" = "$nsub" ] || verdict="sub-$want" ;;
           esac ;;
        *) : ;;                                           # 4 (unknown) / anything else -> leave it
      esac
      [ -n "$verdict" ] || continue
      skey="$sock:$wid:$verdict"
      case "$prev" in
        *"|$skey|"*) : ;;                                 # same reading twice -> act
        *) new="$new$skey|"; continue ;;                  # 1st strike -> arm for next check
      esac
      # The transcript probe is slow enough for a worker to stamp `blocked` (or a
      # prompt to resume it) after our scan. A verdict about the OLD stamp cannot
      # overwrite that event, even if it agrees with the previous pass (#704).
      TMUX_N=$((TMUX_N + 1))
      [ "$(tmux -L "$sock" display-message -p -t "$wid" "$needs_fmt" 2>/dev/null)" = "$wid $st $nsub $ts $agent" ] || continue
      case "$verdict" in
        dead)
          tmux -L "$sock" set-window-option -t "$wid" @claude_state '' 2>/dev/null
          tmux -L "$sock" set-window-option -t "$wid" @claude_needs '' 2>/dev/null
          tmux -L "$sock" set-window-option -t "$wid" @claude_state_ts "$nows" 2>/dev/null
          msg="needs/${nsub:--} -> (idle)   no live Claude under the pane" ;;
        idle)
          tmux -L "$sock" set-window-option -t "$wid" @claude_state 'done' 2>/dev/null
          tmux -L "$sock" set-window-option -t "$wid" @claude_needs '' 2>/dev/null
          tmux -L "$sock" set-window-option -t "$wid" @claude_state_ts "$nows" 2>/dev/null
          msg="needs/${nsub:--} -> done     no tool_use pending in the transcript" ;;
        *)
          tmux -L "$sock" set-window-option -t "$wid" @claude_needs "$want" 2>/dev/null
          msg="needs/${nsub:--} -> needs/$want  pending tool_use is $name" ;;
      esac
      printf '%s  %-24s %s\n' "$(date +%H:%M:%S)" "$sock:$wid" "$msg" >> "$NEEDS_LOG"
      touched=$((touched + 1))
    done <<EOF
$wl
EOF
  done
  printf '%s %s\n' "$nows" "$new" > "$NEEDS_STRIKE_F" 2>/dev/null
  # The pass line (issue #675). `armed=` is the verbatim table just written, so the
  # trace and the strike file can never disagree about what this pass decided.
  [ "$NEEDS_TRACE" = 1 ] && \
    printf '%s  %-24s pass  cand=%s acted=%s starved=%s armed=%s\n' \
      "$(date +%H:%M:%S)" "(reconcile)" "$ncand" "$touched" "$nstarved" "$new" >> "$NEEDS_LOG"
  # Rotate whenever THIS pass appended — the trace writes on every pass, so gating
  # the trim on `touched` alone would let a traced daemon grow needs.log unbounded.
  { [ "$touched" -gt 0 ] || [ "$NEEDS_TRACE" = 1 ]; } && [ -f "$NEEDS_LOG" ] && \
    { tail -n 300 "$NEEDS_LOG" > "$NEEDS_LOG.tmp" 2>/dev/null && mv "$NEEDS_LOG.tmp" "$NEEDS_LOG" 2>/dev/null; }
}

# --- one-shot reconcile: `tmux-spinner.sh --needs-check` (issue #658) ---------
# Runs exactly ONE reconcile pass over every live fleet and exits, without starting
# the animation loop. Two callers: an operator who wants a stale red re-judged NOW
# rather than at the daemon's next tick, and bin/needs-reconcile-selftest.sh, which
# drives passes one at a time so the two-checks-agree rule can be pinned by COUNT
# instead of by wall clock. Same code, same strike file, same verdicts — so this can
# never drift from what the daemon does.
#
# FLEET_NEEDS_RECONCILE_SECS=0 disables the daemon's ERRAND, not this command: an
# explicit invocation is the operator asking for it. The knob still sets the grace
# window, so 0 falls back to the 20s default here rather than collapsing it to none.
if [ "${1:-}" = "--needs-check" ]; then
  [ "$NEEDS_SECS" -gt 0 ] || NEEDS_SECS=20
  SOCKETS=$(fleet_sockets)
  [ -n "$SOCKETS" ] || { echo "tmux-spinner: no live fleet" >&2; exit 1; }
  needs_check "$SOCKETS"
  exit 0
fi

# --- read cadence (issue #887) ------------------------------------------------
# IDLE_READ_SECS: how stale a QUIET fleet's window table may get — the ceiling on
# "state changed by a writer that does not touch the dirty marker" → "the bar shows
# it". IDLE_TICK_SECS: the loop's tick while nothing animates anywhere — the ceiling
# on a HOOK write (which does touch the marker) → the bar. Both are converted to
# frame-EQUIVALENTS once, like every throttle above: `step` is how many frames the
# tick just slept, and every counter advances by it.
IDLE_READ_SECS=1
IDLE_TICK_SECS=0.25
IDLE_EVERY=$(awk -v c="$IDLE_READ_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
TICK_STEP=$(awk -v c="$IDLE_TICK_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
# A tick shorter than a frame is not a backoff — never tick faster than the frame.
[ "$TICK_STEP" -ge 1 ] || TICK_STEP=1
TICK_SLEEP=$(awk -v s="$TICK_STEP" -v i="$INTERVAL" 'BEGIN{print s*i}')
step=1

# DIRTY MARKER (issue #887): `<socket path>.dirty`, i.e. `$TSOCKDIR/<label>.dirty`
# beside tmux's own socket. set-claude-state.sh creates it after every state write
# (a builtin redirection — no fork on the hook's hot path); a QUIET fleet whose
# marker exists is re-read on the next tick, and the marker is removed BEFORE that
# read so a write racing the read re-creates it and is picked up on the tick after.
# Why beside the socket and not in $TMPDIR: the hook runs in a pane and this daemon
# under launchd, whose $TMPDIR need not agree; both already agree on the socket
# path, because that is how the hook's tmux calls reach the server at all. While a
# fleet animates the marker is simply ignored — that fleet is read every frame.

# Per-socket cache (issue #887), POSITIONAL: slot n = the n-th entry of $SOCKETS,
# held in C_<field>_<n> via eval (POSIX sh has no arrays). C_SOCK_n names the label
# the slot was filled for, so a reshuffled socket list invalidates exactly the slots
# that moved. Fields: AGE (frame-equivalents since the last read), ANIM (1 = the last
# read showed an animated window), TOK/NTOK/AGG (the tokens this socket contributed
# to NEW / NEW_NEEDS / AGG, replayed on a frame that skips it). The window table
# itself is a FILE, $CMDF.<label>.wins, written straight by tmux and read by `read`
# and awk — so a cached frame forks nothing.
ANIM_SOCKS=''    # sockets whose last read showed an animated window  → stuck_check
NEEDS_SOCKS=''   # sockets whose last read showed a `needs` window    → needs_check
WFMT='#{session_name}:#{window_index} #{?@worker_lifecycle,#{@worker_lifecycle},#{?@claude_state,#{@claude_state},-}} #{?@claude_needs,#{@claude_needs},-} #{window_name}'

i=1
LAST='|'
LAST_NEEDS='|'   # per-session @attn_needs counts published last frame (change-detect)
LAST_OTHER='|'   # per-session @attn_other_windows counts published last frame (issues #236, #368)
frame='' cyan='' indigo=''   # reassigned each frame via eval below; declared so shellcheck sees them

while :; do
  # Refresh the live fleet-socket list on a ~2s throttle; idle cheaply (and keep
  # re-probing) while no fleet is up so a freshly-spawned fleet is picked up fast.
  # Written to a file and read back rather than `$(fleet_sockets)`, so the probes it
  # forks are counted in THIS shell (TMUX_N).
  socc=$((socc + step))
  if [ "$socc" -ge "$SOCK_EVERY" ] || [ -z "$SOCKETS" ]; then
    socc=0
    deadc=$((deadc + 1))
    [ "$deadc" -ge "$DEAD_EVERY" ] && { deadc=0; SOCK_DEAD=' '; }
    fleet_sockets > "$CMDF.sockets" 2>/dev/null
    SOCKETS=''
    while read -r _s; do [ -n "$_s" ] && SOCKETS="$SOCKETS$_s$NL"; done < "$CMDF.sockets"
    SOCK_KNOWN=' '   # re-earned by this refresh's reads
  fi
  # Stamp liveness BEFORE the no-fleet bail: with no fleet up the loop still turns,
  # and a heartbeat that went stale every time the machine was quiet would be a
  # false alarm exactly when the operator is least able to check (issue #677).
  # This branch already sleeps 2s, so an unthrottled stamp here costs one fork/2s.
  # Past the idle grace the sleep is a NAP (issue #1077, idle_nap above).
  if [ -z "$SOCKETS" ]; then hb_stamp; idle_nap; sleep "$NAP"; LAST='|'; LAST_NEEDS='|'; LAST_OTHER='|'; ANIM_SOCKS=''; NEEDS_SOCKS=''; step=1; continue; fi
  IDLE_T0=''   # a live fleet ends the idle spell

  hbc=$((hbc + step))
  [ "$hbc" -ge "$HB_EVERY" ] && { hbc=0; hb_stamp; }

  # Throttled stuck-working sweep (issue #101) — near-free per frame (one integer
  # compare); the actual window_activity scan runs only ~every STUCK_CHECK_SECS.
  if [ "$STUCK_SECS" -gt 0 ]; then
    sc=$((sc + step))
    [ "$sc" -ge "$STUCK_EVERY" ] && { sc=0; stuck_check; }
  fi

  # Throttled stale-`needs` reconcile (issue #658) — same shape as the sweep above:
  # one integer compare per frame, and the reconcile itself only over windows already
  # stamped `needs` (0-2 on a live fleet), at most every NEEDS_SECS.
  if [ "$NEEDS_SECS" -gt 0 ]; then
    nc=$((nc + step))
    [ "$nc" -ge "$NEEDS_EVERY" ] && { nc=0; needs_check "$NEEDS_SOCKS"; }
  fi

  # Throttled interval-daemon self-heal (issues #636, #639). This daemon is
  # KeepAlive — a single process that has been up since boot — while EVERY other
  # fleet daemon is a StartInterval unit. On 2026-09-14 launchd stopped spawning
  # the interval units in this user domain for 103 minutes (collect, quotawatch,
  # cleanup, dispatch, base-sync, issue-bridge, ledger-watch: every log stopped
  # inside the same two minutes, and `kickstart -k` revived them instantly); the
  # spinner and the webhook, the two long-running ones, never missed a frame. So
  # the spinner is the ONE daemon that can be relied on to notice, and a self-heal
  # that lived only in another interval unit would have been pended right
  # alongside its patient — which is precisely why #639 moved the kick from the
  # collector-only script to the whole registry HERE, and not into a new unit.
  # The status bar kicks the collector too, but only while somebody is attached.
  # Cost: one integer compare per frame; the watch itself at most every
  # KICK_CHECK_SECS, and it costs ~10 forkless stamp reads when every unit is
  # healthy (a launchctl round-trip only for a unit that already looks overdue).
  # The rate limit, the log and the dash trace all live inside it, per unit.
  kc=$((kc + step))
  if [ "$kc" -ge "$KICK_EVERY" ]; then
    kc=0
    [ -x "$BIN/fleet-daemon-watch.sh" ] && bash "$BIN/fleet-daemon-watch.sh" >/dev/null 2>&1
  fi

  set -- '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏';                                eval "frame=\${$i}"
  set -- '#3d6a85' '#4a82a5' '#5aa0c8' '#6bb8e0' '#7dcfff' '#a6e0ff' '#7dcfff' '#6bb8e0' '#5aa0c8' '#4a82a5'; eval "cyan=\${$i}"
  set -- '#5a4a8a' '#6a5a9e' '#7d6bb5' '#9078c8' '#a78bde' '#bb9af7' '#a78bde' '#9078c8' '#7d6bb5' '#6a5a9e'; eval "indigo=\${$i}"

  # Each fleet is its OWN tmux server (issue #159): scan + apply PER SOCKET, each
  # with its own command file + `tmux -L … source-file`. Change-detection state
  # (LAST/LAST_NEEDS) stays GLOBAL, keyed by the globally-unique
  # session:index token, so a repaint fires exactly once per real change estate-wide.
  NEW='|'
  NEW_NEEDS='|'
  AGG=''   # "sess sock count" per live fleet this frame → cross-fleet pass (issues #236, #368)
  anim_socks='' needs_socks=''
  n=0
  for sock in $SOCKETS; do
    n=$((n + 1))
    cmdf="$CMDF.$sock"
    winsf="$CMDF.$sock.wins"
    eval "c_sock=\${C_SOCK_$n-} c_age=\${C_AGE_$n:-0} c_anim=\${C_ANIM_$n:-0}"

    # --- does this socket need tmux this frame? (issue #887) --------------------
    #   animated last read → yes: write the frame, and read on the same process
    #   quiet              → only when its table is IDLE_READ_SECS old, or the hook
    #                        dropped its dirty marker; otherwise replay the cache.
    #   slot not ours yet  → read it first (a new fleet, a reshuffled list).
    if [ "$c_sock" != "$sock" ]; then
      c_anim=0; due=1
    elif [ "$c_anim" = 1 ]; then
      due=1
    else
      due=0
      c_age=$((c_age + step))
      [ "$c_age" -ge "$IDLE_EVERY" ] && due=1
      if [ -e "$TSOCKDIR/$sock.dirty" ]; then
        rm -f "$TSOCKDIR/$sock.dirty" 2>/dev/null   # BEFORE the read: a racing write re-creates it
        due=1
      fi
    fi
    if [ "$due" = 0 ]; then
      _tok="" _ntok="" _agg="" _needy=0   # assigned by the eval below (shellcheck SC2154)
      eval "_tok=\${C_TOK_$n-} _ntok=\${C_NTOK_$n-} _agg=\${C_AGG_$n-} _needy=\${C_NEEDY_$n:-0}"
      NEW="$NEW$_tok"; NEW_NEEDS="$NEW_NEEDS$_ntok"; AGG="$AGG$_agg"
      [ "$_needy" = 1 ] && needs_socks="$needs_socks $sock"
      eval "C_AGE_$n=\$c_age"
      continue
    fi
    # A quiet socket reads FIRST, so a window that just turned `working` starts
    # spinning this frame, not the next. An animated one already holds a table at
    # most one frame old (read by last frame's write) and reads AFTER building.
    if [ "$c_anim" != 1 ]; then
      if ! tmux -L "$sock" list-windows -a -F "$WFMT" > "$winsf" 2>/dev/null; then
        # The server is gone (or going): forget the slot, and re-probe the socket
        # list on the next frame instead of the next refresh.
        eval "C_SOCK_$n=''"; SOCK_KNOWN=' '; socc=$SOCK_EVERY
        continue
      fi
    fi

    changed=0
    anim=0 needy=0
    tok_s='' ntok_s='' agg_s=''
    : > "$cmdf"
    # Fields SPACE-separated; a '-' placeholder for an EMPTY @claude_state keeps the
    # fields parsing cleanly (issue #105) — else an empty middle field would
    # collapse the double space and shift #{window_name} into the state slot. The
    # same placeholder covers @claude_needs, the `needs` SUBTYPE (issue #640), which
    # is empty for every window that is not red. #{window_name} stays LAST because a
    # name may contain spaces and `read`'s final name swallows the rest; a new field
    # goes BEFORE it, and the awk tally below counts columns from the same list.
    # wname reads the trailing #{window_name} so it never bleeds into $nsub (the
    # case matches $nsub exactly); the name is used only by the awk tally below.
    # shellcheck disable=SC2034  # wname read only to keep $st clean
    while IFS=' ' read -r win st nsub wname; do
      [ -z "$win" ] && continue
      # wst = window-status-style (the BACKGROUND). Only 'needs' gets bold red;
      # every other state is font-color-only (no bg) — this also clears any
      # stale per-window styling left by an earlier design.
      case "$st" in
        working) glyph="$frame "; sfg="$cyan";      nfg="$NAME_WORKING"; wst="fg=#565f89"; anim=1 ;;
        looping) glyph="$frame "; sfg="$indigo";    nfg="#9d7cd8";       wst="fg=#565f89"; anim=1 ;;
        sleeping) glyph="z "; sfg="$NAME_IDLE"; nfg="$NAME_IDLE"; wst="fg=#565f89" ;;
        preparing|waking) glyph="↻ "; sfg="$cyan"; nfg="$NAME_WORKING"; wst="fg=#565f89"; anim=1 ;;
        failed) glyph="! "; sfg="$NAME_NEEDS"; nfg="$NAME_NEEDS"; wst="fg=$NAME_NEEDS,bold" ;;
        done)    glyph="✓ ";      sfg="$NAME_DONE"; nfg="$NAME_DONE";    wst="fg=#565f89" ;;
        # `needs` splits by its subtype (issue #640) so the TAB says which reflex it
        # wants: `?` is an AskUserQuestion — answerable from the dash (⌃k) without
        # leaving your seat — while `⊘` is a permission prompt, which by design only
        # a human may approve, so that tab is telling you to go there yourself. `!`
        # stays the undifferentiated case; `blocked` is the worker's declaration.
        # Every glyph is ONE cell wide + a pad, like
        # the states around it; a 2-cell emoji here would shift the whole tab strip.
        needs)   case "$nsub" in
                   ask)     glyph="? " ;;
                   perm)    glyph="⊘ " ;;
                   blocked) glyph="⊠ " ;;   # the worker said `⛔ blocked` (#704): read the issue
                   *)       glyph="! " ;;
                 esac
                 needy=1
                 sfg="$NAME_NEEDS"; nfg="$NAME_NEEDS"; wst="fg=$NAME_NEEDS,bold" ;;  # urgent = red FONT (no block)
        *)       glyph="  ";      sfg="$NAME_IDLE"; nfg="$NAME_IDLE";    wst="fg=#565f89" ;;
      esac
      token="$win^$glyph^$sfg^$nfg^$wst"
      case "$LAST" in
        *"|$token|"*) : ;;
        *)
          printf 'set-window-option -t %s @spin "%s"\n' "$win" "$glyph" >> "$cmdf"
          printf 'set-window-option -t %s @sfg "%s"\n'  "$win" "$sfg"   >> "$cmdf"
          printf 'set-window-option -t %s @nfg "%s"\n'  "$win" "$nfg"   >> "$cmdf"
          printf 'set-window-option -t %s window-status-style "%s"\n' "$win" "$wst" >> "$cmdf"
          changed=1 ;;
      esac
      tok_s="$tok_s$token|"
    done < "$winsf"

    # --- needs signal: one unified "● N" badge (issues #105, #166, #368) --------
    # PER SESSION: @attn_needs = count of needy windows, counting the plan
    # (hub) window as a normal session alongside the workers (issue #368) and
    # excluding only the non-claude panels dash/backlog. status-left renders it as a
    # red "● N" badge (hidden at 0, with a render-time active-window discount).
    # A needy hub now lands in this one number instead of the retired
    # per-fleet beacon flag, so the ⌂ icon is nav-only. Reuses this socket's scan
    # ($winsf); change-detected + batched into this socket's $cmdf so it only re-sets
    # when it actually moves.
    needs_map=$(awk '
      { n = split($1, a, ":"); s = a[1]; for (k = 2; k < n; k++) s = s ":" a[k]
        if (!(s in seen)) { seen[s] = 1; ord[++o] = s }
        # plan(hub) + workers count into the badge; only dash/backlog (non-claude
        # panels) are excluded (issue #368). $4 is the window name: $3 is the
        # @claude_needs subtype added by issue #640 — keep this in step with $WFMT.
        if ($2 == "needs" && $4 !~ /^(dash|backlog)$/) c[s]++ }
      END { for (k = 1; k <= o; k++) { s = ord[k]; printf "%s %d\n", s, c[s] + 0 } }
    ' "$winsf")
    while read -r nsess ncnt; do
      [ -z "$nsess" ] && continue
      ntok="$nsess=$ncnt"
      case "$LAST_NEEDS" in
        *"|$ntok|"*) : ;;
        *) printf 'set-option -t %s @attn_needs "%s"\n' "$nsess" "$ncnt" >> "$cmdf"; changed=1 ;;
      esac
      ntok_s="$ntok_s$ntok|"
      # Cross-fleet feed (issues #236, #368): record THIS session's needy-WINDOW
      # count + its socket so the post-loop pass can tell every OTHER fleet how many
      # needy windows wait elsewhere — the orange cross-fleet ● shows a WINDOW count
      # (same unit as the local ● badge), not a fleet count.
      agg_s="$agg_s$nsess $sock $ncnt$NL"
    done <<EOF
$needs_map
EOF

    # Apply. An animated socket's write carries its NEXT read on the same tmux
    # process — list FIRST, so a write that fails (a window closed mid-frame) cannot
    # cancel the read, and it is exact anyway: the write touches only
    # @spin/@sfg/@nfg/window-status-style, none of which WFMT reads.
    if [ "$c_anim" = 1 ]; then
      if [ "$changed" = 1 ]; then
        tmux -L "$sock" list-windows -a -F "$WFMT" ';' source-file "$cmdf" > "$winsf" 2>/dev/null
      else
        tmux -L "$sock" list-windows -a -F "$WFMT" > "$winsf" 2>/dev/null
      fi
    else
      [ "$changed" = 1 ] && tmux -L "$sock" source-file "$cmdf" 2>/dev/null
    fi

    NEW="$NEW$tok_s"; NEW_NEEDS="$NEW_NEEDS$ntok_s"; AGG="$AGG$agg_s"
    [ "$anim" = 1 ] && anim_socks="$anim_socks $sock"
    [ "$needy" = 1 ] && needs_socks="$needs_socks $sock"
    # A live server always has a window, so an EMPTY table is one that went away
    # mid-frame: forget the slot (it re-reads quiet-style) and re-probe the list.
    if [ -s "$winsf" ]; then
      c_sock=$sock; SOCK_KNOWN="$SOCK_KNOWN$sock "
    else
      c_sock=''; anim=0; SOCK_KNOWN=' '; socc=$SOCK_EVERY
    fi
    eval "C_SOCK_$n=\$c_sock C_AGE_$n=0 C_ANIM_$n=\$anim C_NEEDY_$n=\$needy C_TOK_$n=\$tok_s C_NTOK_$n=\$ntok_s C_AGG_$n=\$agg_s"
  done
  LAST="$NEW"
  LAST_NEEDS="$NEW_NEEDS"
  ANIM_SOCKS="$anim_socks"
  NEEDS_SOCKS="$needs_socks"

  # --- cross-fleet needs → @attn_other_windows (issues #236, #368) ------------
  # An operator attached to ONE fleet couldn't tell that a DIFFERENT fleet was
  # waiting — the local needs signal (● badge) is scoped to this fleet only. Reuse
  # the per-session needy-WINDOW counts just gathered in $AGG (one "sess sock count"
  # line per live fleet) to publish, per fleet, how many needy windows wait in OTHER
  # fleets: total_windows (estate-wide sum) minus this fleet's own count, so a fleet
  # never counts its own windows and a calm fleet sees them all. Same UNIT as the
  # local ● badge (issue #368 replaced the old ⚑ fleet-count flag with a second,
  # ORANGE "● N" dot in conf/tmux-attention.conf) — clicking that dot one-tap jumps
  # to the waiting fleet. Runs AFTER the socket loop because it needs the estate-wide
  # total first; change-detected + published per socket like @attn_needs.
  NEW_OTHER='|'
  if [ -n "$AGG" ]; then
    total_windows=0
    while read -r asess asock acnt; do
      [ -n "$asess" ] || continue
      case "$acnt" in ''|*[!0-9]*) acnt=0 ;; esac
      total_windows=$((total_windows + acnt))
    done <<EOF
$AGG
EOF
    otouched=''
    while read -r asess asock acnt; do
      [ -n "$asess" ] || continue
      case "$acnt" in ''|*[!0-9]*) acnt=0 ;; esac
      oother=$((total_windows - acnt))
      otok="$asess=$oother"
      case "$LAST_OTHER" in
        *"|$otok|"*) : ;;
        *)
          ocmd="$CMDF.$asock.other"
          case " $otouched " in
            *" $asock "*) : ;;
            *) : > "$ocmd"; otouched="$otouched $asock" ;;
          esac
          printf 'set-option -t %s @attn_other_windows "%s"\n' "$asess" "$oother" >> "$ocmd" ;;
      esac
      NEW_OTHER="$NEW_OTHER$otok|"
    done <<EOF
$AGG
EOF
    for asock in $otouched; do
      tmux -L "$asock" source-file "$CMDF.$asock.other" 2>/dev/null
    done
  fi
  LAST_OTHER="$NEW_OTHER"

  # Frame or tick (issue #887): while anything animates, advance the glyph and
  # sleep one frame; with nothing animating anywhere, the glyph has nothing to
  # draw, so sleep a whole tick and let every throttle count it as TICK_STEP frames.
  if [ -n "$ANIM_SOCKS" ]; then
    i=$((i + 1)); [ "$i" -gt "$NFRAMES" ] && i=1
    step=1
    sleep "$INTERVAL"
  else
    step=$TICK_STEP
    sleep "$TICK_SLEEP"
  fi
done
