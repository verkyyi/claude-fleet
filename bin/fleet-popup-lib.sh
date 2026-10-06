#!/bin/bash
# fleet-popup-lib.sh — THE popup frame (issue #1619, EPIC #1615 C4). Sourced,
# never run. Every fleet popup is one style: a rounded PAL_DIM border, the title
# centred ON the border, the body in one colour, one key-hint line at the bottom,
# and nothing but conf/fleet-palette.conf colours — and this file holds the
# fleet's ONLY `tmux display-popup` call (dash-popup-selftest.sh greps for a
# second one).
#
#   fleet_popup <title> <w> <h> -- <cmd> [args…]
#       open a popup from a SCRIPT: bin/dash-popup.sh --title … -w … -h … -- cmd,
#       which resolves the client, raises @popup_open and falls back inline.
#       A tmux bind cannot call a shell function, so a bind names dash-popup.sh
#       itself — the same door.
#   fleet_popup_draw <client> <width> <title> <cmd> [<w> <h>]
#       the draw: the frame below around <cmd>, on <client> (whose
#       #{client_width} is <width>). Blocks until the popup closes. Called by
#       dash-popup.sh only; its exit status means nothing (see there, #454).
#   fleet_popup_screen <socket-label> <client> <cmd>
#       a WHOLE-SCREEN state, not a dialog: no frame, no title, 100% × 100% on
#       <client> of the server `-L <socket-label>` (none = the current one).
#       Blocks until it closes. The shell's standby screen (fleet-shell.sh, #1715).
#   fleet_popup_title <text>      → $FPOP_TITLE, the -T format: centred, # → ##
#   fleet_popup_geom <width> <w> <h> → $FPOP_W $FPOP_H. A client 80 columns or
#       narrower (the iPad's 54) gets 96% × 90% whatever was asked, so the border
#       and the title are never the part that is cut; a fixed row count (an S
#       prompt's 16) is kept.
#   fleet_fzf_opts                → $FLEET_FZF_OPTS: --color all mapped to PAL_*,
#       --border=none (the popup's border is the frame), --info=hidden,
#       --pointer=›. Exported into every popup as FZF_DEFAULT_OPTS, so every fzf
#       a popup runs is drawn in the palette without naming it; a script's own
#       flags still win.
#   fleet_fzf_hint <keys> [<header>] → FZF_HINT=(--footer=<keys> [--header=<header>])
#       — the bottom key line, plus the caller's own header if it has one — or,
#       on an fzf older than --footer (0.63), (--header=<header>⏎<keys>).
#   fleet_fzf_click <action>      → FZF_CLICK=(--bind click-header:<action>
#       [--bind click-footer:<action>]): a tap on the hint line, whichever line
#       that is. The clicked word is "$FZF_CLICK_FOOTER_WORD$FZF_CLICK_HEADER_WORD"
#       (only one is set).
#   fleet_fzf_frame [<label>]     → FZF_FRAME: inside a fleet popup
#       ($FLEET_POPUP=1) (--border=none) — the popup's border is the frame, and
#       <label> is left in $FZF_FRAME_LABEL for the caller's header; in a pane of
#       its own the fzf keeps its rounded border with <label> on it.
#   fleet_menu_style              → FMENU_STYLE=(-b rounded -S … -H …): the same
#       frame for a `display-menu` (the sidebar's row menu).
#
# What fzf supports is probed once and remembered in $FLEET_FZF_FOOTER (1/0),
# which a popup also inherits; the probe is cached on disk against the fzf
# binary's own mtime (`-nt`, no fork), so an open costs no extra fzf run.
# shellcheck disable=SC2034  # FPOP_* FZF_HINT FZF_CLICK FZF_FRAME* FMENU_STYLE are results
case "${BASH_SOURCE[0]}" in */*) _FPOP_BIN="${BASH_SOURCE[0]%/*}" ;; *) _FPOP_BIN=. ;; esac
. "$_FPOP_BIN/fleet-palette.sh"

fleet_popup() {
  local t="$1" w="$2" h="$3"; shift 3
  [ "${1:-}" = -- ] && shift
  bash "$_FPOP_BIN/dash-popup.sh" --title "$t" -w "$w" -h "$h" -- "$@"
}

fleet_popup_screen() {
  tmux ${1:+-L "$1"} display-popup -c "$2" -E -w 100% -h 100% "$3"
}

fleet_popup_title() {
  FPOP_TITLE=''
  [ -n "$1" ] || return 0
  FPOP_TITLE="#[align=centre] ${1//\#/##} "
}

fleet_popup_geom() {
  FPOP_W=$2; FPOP_H=$3
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  [ "$1" -le "${FLEET_POPUP_NARROW:-80}" ] || return 0
  FPOP_W=96%
  case "$FPOP_H" in *%) FPOP_H=90% ;; esac
}

# _fleet_fzf_caps → $FLEET_FZF_FOOTER: 1 when this fzf takes --footer, a footer
# colour, a click-footer bind and --gutter; 0 when it does not (or no fzf).
# The cache file is versioned (-v2) by what the probe asks.
# --cached: read the cache only, never run fzf — the popup DOOR uses this. The
# door runs before the popup opens and holds @popup_open while it does, so an fzf
# that blocks (a stub, a wrapper that waits on a tty) must never run there; with
# no cache yet it leaves FLEET_FZF_FOOTER unset and the popup's own script probes.
_fleet_fzf_caps() {
  [ -n "${FLEET_FZF_FOOTER:-}" ] && return 0
  local f c v
  f=$(command -v fzf 2>/dev/null) || { FLEET_FZF_FOOTER=0; return 0; }
  c="${TMPDIR:-/tmp}/.claude-dash/fzf-caps-v2-$(printf '%s' "$f" | tr -c 'A-Za-z0-9' _)"
  if [ -f "$c" ] && [ "$c" -nt "$f" ]; then
    read -r v < "$c" 2>/dev/null; FLEET_FZF_FOOTER=${v:-0}; return 0
  fi
  [ "${1:-}" = --cached ] && return 0
  FLEET_FZF_FOOTER=0
  fzf --filter= --footer=x --color=footer:1 --bind click-footer:abort --gutter=' ' </dev/null >/dev/null 2>&1
  [ $? -le 1 ] && FLEET_FZF_FOOTER=1   # 0/1 = ran (match/no match); 2 = refused an option
  mkdir -p "${c%/*}" 2>/dev/null && printf '%s\n' "$FLEET_FZF_FOOTER" > "$c" 2>/dev/null
  return 0
}

fleet_fzf_opts() {
  _fleet_fzf_caps "${1:-}"
  FLEET_FZF_OPTS='--border=none --info=hidden --pointer=›'
  fleet_palette_load || return 0   # no palette ⇒ fzf's own colours, never one of ours
  local c="fg:$PAL_FG,bg:-1,hl:$PAL_BLUE,fg+:$PAL_FG,bg+:$PAL_SEL,hl+:$PAL_BLUE"
  c="$c,query:$PAL_FG,prompt:$PAL_BLUE,pointer:$PAL_BLUE,marker:$PAL_GREEN"
  c="$c,info:$PAL_DIM,spinner:$PAL_DIM,header:$PAL_DIM,border:$PAL_DIM"
  c="$c,separator:$PAL_DIM,scrollbar:$PAL_DIM,label:$PAL_FG,gutter:-1"
  FLEET_FZF_OPTS="--color=$c $FLEET_FZF_OPTS"
  # a blank gutter: the selected row's › is the only mark in that column
  [ "${FLEET_FZF_FOOTER:-}" = 1 ] && FLEET_FZF_OPTS="--color=footer:$PAL_DIM --gutter=' ' $FLEET_FZF_OPTS"
}

fleet_fzf_hint() {
  _fleet_fzf_caps
  if [ "$FLEET_FZF_FOOTER" = 1 ]; then
    FZF_HINT=(--footer="$1")
    [ -z "${2:-}" ] || FZF_HINT+=(--header="$2")
  elif [ -n "${2:-}" ]; then FZF_HINT=(--header="$2"$'\n'"$1")
  else FZF_HINT=(--header="$1"); fi
}

fleet_fzf_click() {
  _fleet_fzf_caps
  FZF_CLICK=(--bind "click-header:$1")
  [ "$FLEET_FZF_FOOTER" = 1 ] && FZF_CLICK+=(--bind "click-footer:$1")
  return 0
}

fleet_fzf_frame() {
  FZF_FRAME_LABEL=''
  if [ "${FLEET_POPUP:-}" = 1 ]; then
    FZF_FRAME=(--border=none)
    FZF_FRAME_LABEL=$(printf '%s' "${1:-}" | sed 's/^ *//; s/ *$//')
  else
    FZF_FRAME=(--border=rounded)
    [ -z "${1:-}" ] || FZF_FRAME+=(--border-label="$1" --border-label-pos=3)
  fi
  return 0
}

fleet_menu_style() {
  FMENU_STYLE=(-b rounded)
  fleet_palette_load || return 0
  FMENU_STYLE+=(-S "fg=$PAL_DIM" -s "fg=$PAL_FG" -H "bg=$PAL_SEL,fg=$PAL_FG")
}

fleet_popup_draw() {
  local client="$1" width="$2" title="$3" cmd="$4" env
  fleet_popup_geom "$width" "${5:-}" "${6:-}"
  fleet_popup_title "$title"
  fleet_fzf_opts --cached
  # FZF_DEFAULT_OPTS is exported ahead of the command (an `export`, not a
  # prefix: <cmd> may be a list): a popup starts from the SERVER's environment,
  # not ours. The operator's own defaults stay first, so ours win where they
  # overlap and a script's own flags win over both.
  # Single-quoted by hand, not %q: %q writes a non-ASCII › as $'…', which a
  # POSIX sh (dash) running the popup's command does not read.
  local q="${FZF_DEFAULT_OPTS:+$FZF_DEFAULT_OPTS }$FLEET_FZF_OPTS"
  q=${q//\'/\'\\\'\'}
  env="export FZF_DEFAULT_OPTS='$q' ${FLEET_FZF_FOOTER:+FLEET_FZF_FOOTER=$FLEET_FZF_FOOTER }FLEET_POPUP=1;"
  local geom=()
  [ -n "$FPOP_W" ] && geom+=(-w "$FPOP_W")
  [ -n "$FPOP_H" ] && geom+=(-h "$FPOP_H")
  [ -n "$FPOP_TITLE" ] && geom+=(-T "$FPOP_TITLE")
  local style=(-b rounded)
  fleet_palette_load && style+=(-S "fg=$PAL_DIM")
  tmux display-popup -c "$client" -E ${style[@]+"${style[@]}"} ${geom[@]+"${geom[@]}"} "$env $cmd"
}
