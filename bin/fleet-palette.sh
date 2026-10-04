#!/bin/bash
# fleet-palette.sh — the shell's reader of conf/fleet-palette.conf, the fleet's
# ONE colour table (issue #1534, EPIC #1529 E5). Sourced, never run.
#
#   fleet_palette_load [file]  → PAL_BG PAL_FG PAL_DIM PAL_BLUE PAL_GREEN
#       PAL_YELLOW PAL_RED PAL_CYAN PAL_MAGENTA PAL_SEL as `#rrggbb`, from <file>
#       (default: conf/fleet-palette.conf beside this script's bin/). rc 1 and
#       nothing set when the file is missing — a caller draws uncoloured then,
#       never with a colour of its own.
#   fleet_palette_rgb <#rrggbb> → $_fpr = `r;g;b`, the decimal triple an ANSI
#       truecolour escape (`\033[38;2;r;g;bm`) wants; '' for anything else.
#   fleet_palette_expand <text> → $_fpe = <text> with every `$PAL_<NAME>` the
#       loaded palette knows replaced by its value — what tmux does to a line of
#       conf/tmux-bar.conf, for a reader that takes a format out of that file.
#
# Builtins only — tmux-status.sh and the dash rows render this every tick (#888).
# shellcheck disable=SC2034  # _fpr / _fpe are the results, read by the sourcing script
case "${BASH_SOURCE[0]}" in */*) _FP_BIN="${BASH_SOURCE[0]%/*}" ;; *) _FP_BIN=. ;; esac

fleet_palette_load() {
  local f="${1:-$_FP_BIN/../conf/fleet-palette.conf}" line k v
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#%hidden }
    case "$line" in PAL_*=*) ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}; v=${v#\'}; v=${v%%\'*}
    case "$k" in *[!A-Z_]*) continue ;; esac
    printf -v "$k" '%s' "$v"
  done < "$f"
  return 0
}

fleet_palette_rgb() {
  local h="${1#\#}"
  _fpr=''
  case "$h" in [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;; *) return 1 ;; esac
  printf -v _fpr '%d;%d;%d' $(( 16#${h:0:2} )) $(( 16#${h:2:2} )) $(( 16#${h:4:2} ))
}

fleet_palette_expand() {
  local k
  _fpe=$1
  for k in PAL_MAGENTA PAL_YELLOW PAL_GREEN PAL_BLUE PAL_CYAN PAL_DIM PAL_RED PAL_SEL PAL_BG PAL_FG; do
    [ -n "${!k:-}" ] && _fpe=${_fpe//\$$k/${!k}}
  done
  return 0
}
