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
#   fleet_popup_bind <narrow> <w> <h> <argv…>
#       PRINT the tmux command a KEY binds to open <argv…> in this frame with no
#       shell before it — not the door's, and not the popup's own (tmux runs an
#       argv of two words or more straight, no default-shell) (T890, the 看台's
#       ⌘P: run-shell + this door cost 0.13-0.37 s on a busy machine). tmux expands no format in a popup's command, so the
#       keypress's context rides in the session's environment
#       (`set-environment -F FLEET_PANEL_CTX` session · client · window ·
#       @peer_cur · @view_shell · @view_lang_set · @view_lang · client width); a
#       client narrower than <narrow> columns gets 100% × 100%, else <w> × <h>;
#       the title is the session's @view_popup_title (fleet_view.popup_title_set);
#       the popup's book (@popup_open, --freeze) is dash-popup.sh --hold's, which
#       the panel starts after its first frame. A refused popup (another overlay
#       up) does nothing — #454's toast needs the door's shell.
#   fleet_popup_screen <socket-label> <client> <cmd>
#       a WHOLE-SCREEN state, not a dialog: no frame, no title, 100% × 100% on
#       <client> of the server `-L <socket-label>` (none = the current one).
#       Blocks until it closes. The shell's standby screen (fleet-shell.sh, #1715).
#   fleet_popup_freeze <client>   → $FPOP_FROZEN: every pane of <client>'s window
#       that is in no mode is put in copy-mode (its indicator hidden) for the
#       popup's life; fleet_popup_thaw takes them out again (issue #3058). tmux
#       3.7c draws a WIDE character a pane writes under a popup through the wrong
#       cells (tty_cmd_cell's partly-covered path reads s->cx/s->cy, the cursor
#       AFTER the write), so a session streaming wrapped CJK behind the popup
#       paints whole glyphs and blanks over its frame and rows — at any size,
#       100% × 100% too. A pane in copy-mode writes nothing to the terminal (its
#       output goes on into the grid) and leaving the mode redraws it through the
#       clipped path. Only for a popup that types into no pane — keys sent to a
#       pane in copy-mode are copy-mode's (dash-popup.sh --freeze is opt-in).
#       tmux master (next-3.9) has the bug fixed; drop this with the pin past it.
#       The freeze FOLLOWS the client (T741): while the popup is up a watcher
#       (_fleet_popup_follow, every FLEET_POPUP_FOLLOW_SECS, 0.15 s) reads the
#       client's window again, and a window it has moved to — the ⚡ box's job
#       going onto the new session, the window behind closed and tmux moving the
#       client on, a go from anywhere else — is frozen too and the client redrawn
#       once (refresh-client), so what streamed in the moment between is painted
#       over. Before it, only the window of the press was held: on a phone the
#       panel sat over a live window and its CJK broke the frame.
#   fleet_popup_thaw              the panes fleet_popup_freeze froze (and its
#       watcher after it), still in copy-mode, back out (`send-keys -X cancel`);
#       a pane already in a mode before the popup is never touched.
#   fleet_popup_title <text>      → $FPOP_TITLE, the -T format: centred, # → ##
#   fleet_popup_geom <width> <w> <h> → $FPOP_W $FPOP_H. A client 80 columns or
#       narrower (the iPad's 54) gets 96% × 90% whatever was asked, so the border
#       and the title are never the part that is cut; a fixed row count (an S
#       prompt's 16) is kept, and so is an axis asked for at 100% — a whole-screen
#       panel (the full switcher a tap on the top line opens) must cover the
#       screen, or the session behind it shows round its edges.
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
#
# What fzf supports is probed once and remembered in $FLEET_FZF_FOOTER (1/0),
# which a popup also inherits; the probe is cached on disk against the fzf
# binary's own mtime (`-nt`, no fork), so an open costs no extra fzf run.
# shellcheck disable=SC2034  # FPOP_* FZF_HINT FZF_CLICK FZF_FRAME* are results
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

fleet_popup_bind() {
  local narrow="${1:-100}" w="${2:-90%}" h="${3:-80%}" frame='-b rounded' one cmd='' a
  shift 3
  for a in "$@"; do cmd="$cmd '${a//\'/\'\\\'\'}'"; done
  # text for tmux's parser, never for a shell: the quotes are meant literally
  # shellcheck disable=SC2089
  fleet_palette_load && frame="$frame -S 'fg=$PAL_DIM' -s 'bg=$PAL_BG'"
  one="display-popup -E $frame -T '#{@view_popup_title}' -e FLEET_POPUP=1 -e FLEET_PANEL_DIRECT=1"
  printf '%s' "{ set-environment -F FLEET_PANEL_CTX '#{session_name}|#{client_name}|#{window_id}|#{@peer_cur}|#{@view_shell}|#{@view_lang_set}|#{@view_lang}|#{client_width}' ; "  # view-ok: a key's own session IS the 看台 (its @view- name is the server's)
  printf '%s' "if-shell -F '#{e|<:#{client_width},$narrow}' { $one -w 100% -h 100%$cmd } { $one -w $w -h $h$cmd } }"
}

fleet_popup_freeze() {
  FPOP_FROZEN='' FPOP_FOLLOW='' FPOP_FROZEN_FILE=''
  local wid
  # the client's own window — its panes are the ones under its popup; no window
  # read ⇒ nothing frozen (an empty -t would be "the current window", a guess)
  wid=$(tmux display-message -p -c "$1" '#{window_id}' 2>/dev/null)
  case "$wid" in @[0-9]*) ;; *) return 0 ;; esac
  FPOP_FROZEN=$(_fleet_popup_hold "$wid")
  # the watcher's own book of what it froze (thaw reads it): a file, since it is
  # a child process and FPOP_FROZEN is this shell's
  FPOP_FROZEN_FILE=$(mktemp "${TMPDIR:-/tmp}/.fleet-popup-frozen.XXXXXX" 2>/dev/null) || FPOP_FROZEN_FILE=''
  [ -n "$FPOP_FROZEN_FILE" ] || return 0
  _fleet_popup_follow "$1" "$wid" "$FPOP_FROZEN_FILE" "$$" </dev/null >/dev/null 2>&1 &
  FPOP_FOLLOW=$!
  return 0
}

# _fleet_popup_hold <window id> [<book>] — put its panes in copy-mode (a pane
# already in a mode is left alone). No <book>: print the ids it froze, one line.
# With <book> (the watcher): each id is written there BEFORE its pane is frozen, so
# a thaw that reads the book never misses a pane this froze.
_fleet_popup_hold() {
  local p m out=''
  while read -r p m; do
    [ "$m" = 0 ] || continue
    if [ -n "${2:-}" ]; then
      printf '%s\n' "$p" >> "$2"
      tmux copy-mode -H -t "$p" 2>/dev/null
    else
      tmux copy-mode -H -t "$p" 2>/dev/null && out="$out $p"
    fi
  done <<EOF_FZ
$(tmux list-panes -t "$1" -F '#{pane_id} #{pane_in_mode}' 2>/dev/null)
EOF_FZ
  [ -n "${2:-}" ] || printf '%s\n' "$out"
}

# _fleet_popup_follow <client> <window> <book> <door pid> — the freeze's watcher:
# a window the client moves to while the popup is up is held too (its panes in
# <book>) and the client redrawn once. It ends when <book>.stop appears (the thaw
# asks, then waits for it), the door's pid is gone, or the client is.
_fleet_popup_follow() {
  local cl=$1 cur=$2 f=$3 door=$4 w n=0
  while kill -0 "$door" 2>/dev/null; do
    sleep "${FLEET_POPUP_FOLLOW_SECS:-0.15}"
    [ ! -e "$f.stop" ] || return 0
    # read off list-clients, never `display-message -c`: tmux 3.7c repaints the
    # client a display-message names, and every repaint redraws the frozen pane
    # round the popup (900 wide glyphs in 1.8 s at this pace)
    w=$(tmux list-clients -F '#{client_name}	#{window_id}' 2>/dev/null | awk -F '\t' -v c="$cl" '$1 == c { print $2; exit }')
    case "$w" in @[0-9]*) ;; *) return 0 ;; esac
    [ "$w" = "$cur" ] && continue
    [ ! -e "$f.stop" ] || return 0
    cur=$w
    _fleet_popup_hold "$w" "$f"
    tmux refresh-client -t "$cl" 2>/dev/null
    n=$((n + 1)); [ "$n" -lt 50 ] || return 0   # a bounded watcher, whatever happens
  done
}

fleet_popup_thaw() {
  local p i=0
  # the watcher first: asked to stop and waited for (a tmux command of its in
  # flight finishes first), so its book is whole when read; killed only if it
  # does not end within ~3 s
  if [ -n "${FPOP_FOLLOW:-}" ]; then
    [ -z "${FPOP_FROZEN_FILE:-}" ] || : > "$FPOP_FROZEN_FILE.stop" 2>/dev/null
    while kill -0 "$FPOP_FOLLOW" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
    kill -9 "$FPOP_FOLLOW" 2>/dev/null; wait "$FPOP_FOLLOW" 2>/dev/null
  fi
  [ -n "${FPOP_FROZEN_FILE:-}" ] && [ -f "$FPOP_FROZEN_FILE" ] && FPOP_FROZEN="$FPOP_FROZEN $(tr '\n' ' ' < "$FPOP_FROZEN_FILE")"
  for p in ${FPOP_FROZEN:-}; do
    [ "$(tmux display-message -p -t "$p" '#{pane_mode}' 2>/dev/null)" = copy-mode ] \
      && tmux send-keys -X -t "$p" cancel 2>/dev/null
  done
  [ -z "${FPOP_FROZEN_FILE:-}" ] || rm -f "$FPOP_FROZEN_FILE" "$FPOP_FROZEN_FILE.stop" 2>/dev/null
  FPOP_FROZEN='' FPOP_FOLLOW='' FPOP_FROZEN_FILE=''
  return 0
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
  case "$FPOP_W" in 100%) ;; *) FPOP_W=96% ;; esac
  case "$FPOP_H" in 100%) ;; *%) FPOP_H=90% ;; esac
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
  c="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/fzf-caps-v2-$(printf '%s' "$f" | tr -c 'A-Za-z0-9' _)"
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
  # -s: the content's own background (issue #2362) — every cell inside the frame
  # is the palette's, never the terminal's default, so nothing behind can read
  # as part of the popup
  local style=(-b rounded)
  fleet_palette_load && style+=(-S "fg=$PAL_DIM" -s "bg=$PAL_BG")
  tmux display-popup -c "$client" -E ${style[@]+"${style[@]}"} ${geom[@]+"${geom[@]}"} "$env $cmd"
}
