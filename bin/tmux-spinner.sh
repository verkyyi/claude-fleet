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
# KEEP IN SYNC with fleet_sockets() in bin/fleet-lib.sh.
FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
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
      tmux -L "$_label" has-session -t "$_label" 2>/dev/null && printf '%s\n' "$_label"
    done
  fi
  # Dual-read the legacy flat <sess>.conf (label = basename .conf) for a
  # half-migrated estate, but skip a session already covered by a new-layout dir.
  for _cf in "$FLEET_CONF_DIR"/*.conf; do
    [ -f "$_cf" ] || continue
    _label=$(basename "$_cf" .conf)
    [ -f "$FLEET_CONF_DIR/fleets/$_label/conf" ] && continue
    tmux -L "$_label" has-session -t "$_label" 2>/dev/null && printf '%s\n' "$_label"
  done
}
# The live socket list is refreshed on a ~2s throttle (fleets come/go rarely; a
# new WORKER window inside a known fleet still animates instantly because we
# already hold that fleet's socket). SOCK_EVERY = frames between refreshes.
SOCK_REFRESH_SECS=2
SOCK_EVERY=$(awk -v c="$SOCK_REFRESH_SECS" -v i="$INTERVAL" 'BEGIN{f=int(c/i+0.5); if(f<1)f=1; print f}')
socc=0
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
STUCK_STRIKES='|'   # window_ids that were stale on the PREVIOUS check (2-strike debounce)

# stuck_check — one throttled sweep: demote any working window whose pane has
# been frozen (window_activity stale >= STUCK_SECS) across two consecutive checks.
# Runs in the current shell (here-doc, no pipe) so STUCK_STRIKES persists.
stuck_check() {
  nows=$(date +%s)
  new='|'
  demoted=0
  # Fan out over every live fleet socket. window_id (@N) is unique only WITHIN a
  # server, so the strike key + demote target are namespaced by "<sock>:<wid>" and
  # the demote/classify run against that socket's -L.
  for sock in $SOCKETS; do
  wl=$(tmux -L "$sock" list-windows -a -F '#{window_id} #{@claude_state} #{window_activity}' 2>/dev/null) || continue
  while read -r wid st act; do
    [ -n "$wid" ] || continue
    [ "$st" = working ] || continue
    case "$act" in ''|*[!0-9]*) continue ;; esac   # need a numeric activity stamp
    age=$(( nows - act ))
    [ "$age" -ge "$STUCK_SECS" ] || continue        # still fresh -> not stuck, no strike
    skey="$sock:$wid"
    case "$STUCK_STRIKES" in
      *"|$skey|"*)                                   # stale last check too -> 2nd strike -> demote
        tmux -L "$sock" set-window-option -t "$wid" @claude_state 'done' 2>/dev/null
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
  [ "$demoted" = 1 ] && [ -f "$STUCK_LOG" ] && \
    { tail -n 300 "$STUCK_LOG" > "$STUCK_LOG.tmp" 2>/dev/null && mv "$STUCK_LOG.tmp" "$STUCK_LOG" 2>/dev/null; }
}

i=1
LAST='|'
LAST_NEEDS='|'   # per-session @attn_needs counts published last frame (change-detect)
LAST_STEWARD='|' # per-session @steward_needs flags published last frame (change-detect)
LAST_OTHER='|'   # per-session @attn_other_fleets counts published last frame (issue #236)
frame='' cyan='' indigo=''   # reassigned each frame via eval below; declared so shellcheck sees them

while :; do
  # Refresh the live fleet-socket list on a ~2s throttle; idle cheaply (and keep
  # re-probing) while no fleet is up so a freshly-spawned fleet is picked up fast.
  socc=$((socc + 1))
  if [ "$socc" -ge "$SOCK_EVERY" ] || [ -z "$SOCKETS" ]; then socc=0; SOCKETS=$(fleet_sockets); fi
  if [ -z "$SOCKETS" ]; then sleep 2; LAST='|'; LAST_NEEDS='|'; LAST_STEWARD='|'; LAST_OTHER='|'; continue; fi

  # Throttled stuck-working sweep (issue #101) — near-free per frame (one integer
  # compare); the actual window_activity scan runs only ~every STUCK_CHECK_SECS.
  if [ "$STUCK_SECS" -gt 0 ]; then
    sc=$((sc + 1))
    [ "$sc" -ge "$STUCK_EVERY" ] && { sc=0; stuck_check; }
  fi

  set -- '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏';                                eval "frame=\${$i}"
  set -- '#3d6a85' '#4a82a5' '#5aa0c8' '#6bb8e0' '#7dcfff' '#a6e0ff' '#7dcfff' '#6bb8e0' '#5aa0c8' '#4a82a5'; eval "cyan=\${$i}"
  set -- '#5a4a8a' '#6a5a9e' '#7d6bb5' '#9078c8' '#a78bde' '#bb9af7' '#a78bde' '#9078c8' '#7d6bb5' '#6a5a9e'; eval "indigo=\${$i}"

  # Each fleet is its OWN tmux server (issue #159): scan + apply PER SOCKET, each
  # with its own command file + `tmux -L … source-file`. Change-detection state
  # (LAST/LAST_NEEDS) stays GLOBAL, keyed by the globally-unique session:index
  # token, so a repaint still fires exactly once per real change across the estate.
  NEW='|'
  NEW_NEEDS='|'
  NEW_STEWARD='|'
  AGG=''   # "sess sock need" per live fleet this frame → cross-fleet pass (issue #236)
  # Each fleet is its OWN tmux server (issue #159): scan + apply PER SOCKET, each
  # with its own command file + `tmux -L … source-file`. Change-detection state
  # (LAST/LAST_NEEDS/LAST_STEWARD) stays GLOBAL, keyed by the globally-unique
  # session:index token, so a repaint fires exactly once per real change estate-wide.
  for sock in $SOCKETS; do
    # Fields SPACE-separated; a '-' placeholder for an EMPTY @claude_state keeps the
    # three fields parsing cleanly (issue #105) — else an empty middle field would
    # collapse the double space and shift #{window_name} into the state slot.
    wins=$(tmux -L "$sock" list-windows -a -F '#{session_name}:#{window_index} #{?@claude_state,#{@claude_state},-} #{window_name}' 2>/dev/null) || continue
    cmdf="$CMDF.$sock"
    changed=0
    : > "$cmdf"
    # wname reads the trailing #{window_name} so it never bleeds into $st (the case
    # matches $st exactly); the name is used only by the awk tally below.
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
          printf 'set-window-option -t %s @spin "%s"\n' "$win" "$glyph" >> "$cmdf"
          printf 'set-window-option -t %s @sfg "%s"\n'  "$win" "$sfg"   >> "$cmdf"
          printf 'set-window-option -t %s @nfg "%s"\n'  "$win" "$nfg"   >> "$cmdf"
          printf 'set-window-option -t %s window-status-style "%s"\n' "$win" "$wst" >> "$cmdf"
          changed=1 ;;
      esac
      NEW="$NEW$token|"
    done <<EOF
$wins
EOF

    # --- needs signals: worker badge + steward icon (issues #105, #166) --------
    # PER SESSION, split into two signals that never double-count a window:
    #   @attn_needs    — WORKERS: needy windows EXCLUDING hub panels (plan/dash/
    #                    backlog); status-left renders a red "● N" badge (hides at 0).
    #   @steward_needs — the HUB: 1 when a panel window is needy (the steward is
    #                    waiting on you), else 0; drives the ⌂ hub icon.
    # Reuses this socket's scan ($wins); change-detected + batched into this
    # socket's $cmdf so each only re-sets when it actually moves.
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
        *) printf 'set-option -t %s @attn_needs "%s"\n' "$nsess" "$ncnt" >> "$cmdf"; changed=1 ;;
      esac
      NEW_NEEDS="$NEW_NEEDS$ntok|"
      stok="$nsess=$nstew"
      case "$LAST_STEWARD" in
        *"|$stok|"*) : ;;
        *) printf 'set-option -t %s @steward_needs "%s"\n' "$nsess" "$nstew" >> "$cmdf"; changed=1 ;;
      esac
      NEW_STEWARD="$NEW_STEWARD$stok|"
      # Cross-fleet feed (issue #236): does THIS session need attention (a worker
      # badge > 0 OR a needy steward hub)? Record that flag + its socket so the
      # post-loop pass can tell every OTHER fleet how many fleets are waiting.
      oneed=0
      { [ "${ncnt:-0}" -gt 0 ] || [ "${nstew:-0}" -gt 0 ]; } 2>/dev/null && oneed=1
      AGG="$AGG$nsess $sock $oneed$NL"
    done <<EOF
$needs_map
EOF

    [ "$changed" = 1 ] && tmux -L "$sock" source-file "$cmdf" 2>/dev/null
  done
  LAST="$NEW"
  LAST_NEEDS="$NEW_NEEDS"
  LAST_STEWARD="$NEW_STEWARD"

  # --- cross-fleet needs → @attn_other_fleets (issue #236) --------------------
  # An operator attached to ONE fleet couldn't tell that a DIFFERENT fleet was
  # waiting — the needs signal (● badge / ⌂ beacon) is scoped to this fleet only.
  # Reuse the per-session need flags just gathered in $AGG (one "sess sock need"
  # line per live fleet) to publish, per fleet, how many OTHER live fleets need
  # attention. total_need = # of fleets waiting; each fleet's own count is
  # total_need minus its OWN need, so a needy fleet never counts itself and a calm
  # fleet sees them all. conf/tmux-attention.conf renders this into the EXISTING
  # #S fleet-switcher chip (no new bar element) — clicking #S opens the picker to
  # jump to the waiting fleet. Runs AFTER the socket loop because it needs the
  # estate-wide total first; change-detected + published per socket like @attn_needs.
  NEW_OTHER='|'
  if [ -n "$AGG" ]; then
    total_need=0
    while read -r asess asock aneed; do
      [ -n "$asess" ] || continue
      [ "$aneed" = 1 ] && total_need=$((total_need + 1))
    done <<EOF
$AGG
EOF
    otouched=''
    while read -r asess asock aneed; do
      [ -n "$asess" ] || continue
      oother=$((total_need - aneed))
      otok="$asess=$oother"
      case "$LAST_OTHER" in
        *"|$otok|"*) : ;;
        *)
          ocmd="$CMDF.$asock.other"
          case " $otouched " in
            *" $asock "*) : ;;
            *) : > "$ocmd"; otouched="$otouched $asock" ;;
          esac
          printf 'set-option -t %s @attn_other_fleets "%s"\n' "$asess" "$oother" >> "$ocmd" ;;
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

  i=$((i + 1)); [ "$i" -gt "$NFRAMES" ] && i=1
  sleep "$INTERVAL"
done
