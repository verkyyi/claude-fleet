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
set -u  # POSIX sh: pipefail is bash-only (dash has none)
INTERVAL="${SPIN_INTERVAL:-0.12}"
NFRAMES=10
CMDF="${TMPDIR:-/tmp}/.claude-spin.cmds"
NAME_WORKING='#a9b1d6'   # calm neutral name while working
NAME_DONE='#9ece6a'
NAME_NEEDS='#f7768e'
NAME_IDLE='#565f89'

# Global config (FLEET_STUCK_WORKING_SECS lives here). Sourced ONCE at startup,
# like the other daemons — a change needs a spinner restart.
BIN=$(cd "$(dirname "$0")" && pwd)
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
mkdir -p "$BIN/../logs" 2>/dev/null

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
STUCK_STRIKES='|'   # window_ids that were stale on the PREVIOUS check (2-strike debounce)

# stuck_check — one throttled sweep: demote any working window whose pane has
# been frozen (window_activity stale >= STUCK_SECS) across two consecutive checks.
# Runs in the current shell (here-doc, no pipe) so STUCK_STRIKES persists.
stuck_check() {
  nows=$(date +%s)
  new='|'
  demoted=0
  wl=$(tmux list-windows -a -F '#{window_id} #{@claude_state} #{window_activity}' 2>/dev/null) || return 0
  while read -r wid st act; do
    [ "$st" = working ] || continue
    case "$act" in ''|*[!0-9]*) continue ;; esac   # need a numeric activity stamp
    age=$(( nows - act ))
    [ "$age" -ge "$STUCK_SECS" ] || continue        # still fresh -> not stuck, no strike
    case "$STUCK_STRIKES" in
      *"|$wid|"*)                                    # stale last check too -> 2nd strike -> demote
        tmux set-window-option -t "$wid" @claude_state 'done' 2>/dev/null
        tmux set-window-option -t "$wid" @claude_state_ts "$nows" 2>/dev/null
        printf '%s  %-10s working -> done (idle %ss; stop-hook missed)\n' \
          "$(date +%H:%M:%S)" "$wid" "$age" >> "$STUCK_LOG"
        ( "$BIN/classify-sessions.sh" --window "$wid" >/dev/null 2>&1 & )   # refine done|needs|looping
        demoted=1 ;;
      *) new="$new$wid|" ;;                          # 1st strike -> arm for next check
    esac
  done <<EOF
$wl
EOF
  STUCK_STRIKES="$new"
  [ "$demoted" = 1 ] && [ -f "$STUCK_LOG" ] && \
    { tail -n 300 "$STUCK_LOG" > "$STUCK_LOG.tmp" 2>/dev/null && mv "$STUCK_LOG.tmp" "$STUCK_LOG" 2>/dev/null; }
}

i=1
LAST='|'
LAST_NEEDS='|'   # per-session @attn_needs counts published last frame (change-detect)
LAST_STEWARD='|' # per-session @steward_needs flags published last frame (change-detect)
frame='' cyan='' indigo=''   # reassigned each frame via eval below; declared so shellcheck sees them

while :; do
  # Fields are SPACE-separated, and BOTH the render loop and the awk tally below
  # split on whitespace — which collapses runs. @claude_state is EMPTY for any
  # non-Claude / freshly-spawned window, so an empty middle field would collapse
  # the double space and shift #{window_name} into the state slot (a window named
  # 'needs'/'done' would then be miscounted/misstyled). Emit a '-' placeholder for
  # empty state so the three fields always parse cleanly; '-' is not a real state,
  # so it renders as idle and never counts.
  wins=$(tmux list-windows -a -F '#{session_name}:#{window_index} #{?@claude_state,#{@claude_state},-} #{window_name}' 2>/dev/null) \
    || { sleep 2; LAST='|'; continue; }

  # Throttled stuck-working sweep (issue #101) — near-free per frame (one integer
  # compare); the actual window_activity scan runs only ~every STUCK_CHECK_SECS.
  if [ "$STUCK_SECS" -gt 0 ]; then
    sc=$((sc + 1))
    [ "$sc" -ge "$STUCK_EVERY" ] && { sc=0; stuck_check; }
  fi

  set -- '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏';                                eval "frame=\${$i}"
  set -- '#3d6a85' '#4a82a5' '#5aa0c8' '#6bb8e0' '#7dcfff' '#a6e0ff' '#7dcfff' '#6bb8e0' '#5aa0c8' '#4a82a5'; eval "cyan=\${$i}"
  set -- '#5a4a8a' '#6a5a9e' '#7d6bb5' '#9078c8' '#a78bde' '#bb9af7' '#a78bde' '#9078c8' '#7d6bb5' '#6a5a9e'; eval "indigo=\${$i}"

  NEW='|'
  changed=0
  : > "$CMDF"
  # wname reads the trailing #{window_name} field so it never bleeds into $st
  # (the case below matches $st exactly); the name itself is used by the awk
  # tally further down, not here. Empty @claude_state can't collapse the fields —
  # the scan above emits a '-' placeholder for it.
  # shellcheck disable=SC2034  # wname read only to keep $st clean
  while IFS=' ' read -r win st wname; do
    [ -z "$win" ] && continue
    # wst = window-status-style (the BACKGROUND). Only 'needs' gets bold red;
    # every other state is font-color-only (no bg) — this also clears any
    # stale per-window styling left by an earlier design.
    case "$st" in
      working) glyph="$frame "; sfg="$cyan";      nfg="$NAME_WORKING"; wst="fg=#565f89" ;;
      looping) glyph="$frame "; sfg="$indigo";    nfg="#9d7cd8";       wst="fg=#565f89" ;;
      done)    glyph="✓ ";      sfg="$NAME_DONE"; nfg="$NAME_DONE";    wst="fg=#565f89" ;;
      needs)   glyph="! ";      sfg="$NAME_NEEDS"; nfg="$NAME_NEEDS"; wst="fg=$NAME_NEEDS,bold" ;;  # urgent = red FONT (no block)
      *)       glyph="  ";      sfg="$NAME_IDLE"; nfg="$NAME_IDLE";    wst="fg=#565f89" ;;
    esac
    token="$win^$glyph^$sfg^$nfg^$wst"
    case "$LAST" in
      *"|$token|"*) : ;;
      *)
        printf 'set-window-option -t %s @spin "%s"\n' "$win" "$glyph" >> "$CMDF"
        printf 'set-window-option -t %s @sfg "%s"\n'  "$win" "$sfg"   >> "$CMDF"
        printf 'set-window-option -t %s @nfg "%s"\n'  "$win" "$nfg"   >> "$CMDF"
        printf 'set-window-option -t %s window-status-style "%s"\n' "$win" "$wst" >> "$CMDF"
        changed=1 ;;
    esac
    NEW="$NEW$token|"
  done <<EOF
$wins
EOF

  # --- needs signals: worker badge + steward icon (issues #105, #166) --------
  # Tally windows in @claude_state=needs PER SESSION, split into two independent
  # signals that never double-count the same window:
  #   @attn_needs   — WORKERS only: count of needy windows EXCLUDING the hub
  #                   panels (plan/dash/backlog). status-left renders it as a red
  #                   "● N" badge (hidden at 0).
  #   @steward_needs — the HUB: 1 when a panel window (plan/dash/backlog) is in
  #                   needs (the steward is waiting on you), else 0. status-left's
  #                   ⌂ hub icon renders a solid red block when it's 1, from every
  #                   window in the fleet.
  # Both reuse this frame's window scan ($wins) — no extra tmux query — folded
  # once by awk; change-detected and batched into the same $CMDF, so each only
  # re-sets when it actually moves. A session with windows but none needy emits
  # "0" for both (badge hides, icon clears); a vanished session drops out of
  # $wins and keeps its last (irrelevant) value.
  NEW_NEEDS='|'
  NEW_STEWARD='|'
  needs_map=$(awk '
    { n = split($1, a, ":"); s = a[1]; for (k = 2; k < n; k++) s = s ":" a[k]
      if (!(s in seen)) { seen[s] = 1; ord[++o] = s }
      if ($2 == "needs") {
        if ($3 ~ /^(plan|dash|backlog)$/) sw[s] = 1   # hub panel  → steward icon
        else c[s]++                                    # worker win → badge
      } }
    END { for (k = 1; k <= o; k++) { s = ord[k]; printf "%s %d %d\n", s, c[s] + 0, sw[s] + 0 } }
  ' <<EOF
$wins
EOF
)
  while read -r nsess ncnt nstew; do
    [ -z "$nsess" ] && continue
    ntok="$nsess=$ncnt"
    case "$LAST_NEEDS" in
      *"|$ntok|"*) : ;;
      *) printf 'set-option -t %s @attn_needs "%s"\n' "$nsess" "$ncnt" >> "$CMDF"; changed=1 ;;
    esac
    NEW_NEEDS="$NEW_NEEDS$ntok|"
    stok="$nsess=$nstew"
    case "$LAST_STEWARD" in
      *"|$stok|"*) : ;;
      *) printf 'set-option -t %s @steward_needs "%s"\n' "$nsess" "$nstew" >> "$CMDF"; changed=1 ;;
    esac
    NEW_STEWARD="$NEW_STEWARD$stok|"
  done <<EOF
$needs_map
EOF
  LAST_NEEDS="$NEW_NEEDS"
  LAST_STEWARD="$NEW_STEWARD"

  [ "$changed" = 1 ] && tmux source-file "$CMDF" 2>/dev/null
  LAST="$NEW"

  i=$((i + 1)); [ "$i" -gt "$NFRAMES" ] && i=1
  sleep "$INTERVAL"
done
