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
i=1
LAST='|'
frame='' cyan='' indigo=''   # reassigned each frame via eval below; declared so shellcheck sees them

while :; do
  wins=$(tmux list-windows -a -F '#{session_name}:#{window_index} #{@claude_state}' 2>/dev/null) \
    || { sleep 2; LAST='|'; continue; }

  set -- '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏';                                eval "frame=\${$i}"
  set -- '#3d6a85' '#4a82a5' '#5aa0c8' '#6bb8e0' '#7dcfff' '#a6e0ff' '#7dcfff' '#6bb8e0' '#5aa0c8' '#4a82a5'; eval "cyan=\${$i}"
  set -- '#5a4a8a' '#6a5a9e' '#7d6bb5' '#9078c8' '#a78bde' '#bb9af7' '#a78bde' '#9078c8' '#7d6bb5' '#6a5a9e'; eval "indigo=\${$i}"

  NEW='|'
  changed=0
  : > "$CMDF"
  while IFS=' ' read -r win st; do
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

  [ "$changed" = 1 ] && tmux source-file "$CMDF" 2>/dev/null
  LAST="$NEW"

  i=$((i + 1)); [ "$i" -gt "$NFRAMES" ] && i=1
  sleep "$INTERVAL"
done
