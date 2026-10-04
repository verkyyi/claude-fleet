#!/bin/bash
# fleet-palette-selftest.sh — pins issue #1534 (EPIC #1529 E5): the status bar,
# the dash rows and the sidebar draw their colours from ONE table,
# conf/fleet-palette.conf, and nothing else.
#
#   A  no colour of their own: no `#rrggbb` in conf/tmux-bar.conf's settings, in
#      bin/tmux-status.sh, in fleet_alerts_bar (bin/fleet-alerts.sh) or in
#      bin/fleet-sidebar.py; no truecolour literal (`38;2;r;g;b`) in
#      bin/tmux-dashboard-rows.sh — the metric 「配色 4 处 → 1 处」, as a grep
#   B  the readers agree: bin/fleet-palette.sh and fleet-sidebar.py's palette()
#      read the same ten names and values; fleet_palette_rgb / _expand
#   C  tmux reads it: the two `source-file -F` lines of conf/tmux-attention.conf,
#      on an ISOLATED server, leave every `$PAL_*` expanded in the bar's formats,
#      status-interval 2, and no PAL_* in the environment a pane would inherit
#   D  one edit recolours every surface: a root whose palette says otherwise →
#      tmux-status.sh, the rows' escapes and the sidebar's colour numbers follow;
#      a root with no palette at all → an uncoloured bar, never a crash
#
# Drives bin/tmux-status.sh, bin/tmux-dashboard-rows.sh, bin/fleet-sidebar.py,
# bin/fleet-alerts.sh and bin/fleet-palette.sh against conf/fleet-palette.conf,
# conf/tmux-bar.conf and conf/tmux-attention.conf.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/  /' >&2; exit 1; }
ok() { CHECKS=$((CHECKS+1)); }
eq() { [ "$2" = "$3" ] || fail "$1" "want: [$2]
 got: [$3]"; ok; }
has() { case "$3" in *"$2"*) ok ;; *) fail "$1" "want a substring: [$2]
 got: [$3]" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "must not contain: [$2]
 got: [$3]" ;; *) ok ;; esac; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/palette-selftest.XXXXXX") || exit 2
REAL_TMUX="$(command -v tmux 2>/dev/null)"
SOCK="$WORK/s"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
[ -n "${KEEP:-}" ] || trap cleanup EXIT
trap 'exit 130' INT TERM HUP
PAL="$ROOT/conf/fleet-palette.conf"
[ -f "$PAL" ] || fail "no conf/fleet-palette.conf"

# ---- A: no colour of their own
hexes() { grep -nE '#[0-9a-fA-F]{6}\b' "$@" | grep -vE '^[0-9]+:[[:space:]]*#( |$|!)'; }   # code lines only
eq "A: conf/tmux-bar.conf spells no hex" "" "$(hexes "$ROOT/conf/tmux-bar.conf")"
eq "A: tmux-status.sh spells no hex" "" "$(hexes "$BIN/tmux-status.sh")"
eq "A: fleet-sidebar.py spells no hex" "" "$(hexes "$BIN/fleet-sidebar.py")"
eq "A: fleet_alerts_bar spells no hex" "" "$(sed -n '/^fleet_alerts_bar()/,/^}/p' "$BIN/fleet-alerts.sh" | grep -E '#[0-9a-fA-F]{6}')"
eq "A: tmux-dashboard-rows.sh spells no truecolour literal" "" "$(grep -nE '38;2;[0-9]' "$BIN/tmux-dashboard-rows.sh")"
grep -q 'init_pair([0-9], curses.COLOR_' "$BIN/fleet-sidebar.py" && fail "A: the sidebar still pairs a basic colour directly"; ok
eq "A: tmux-attention.conf no longer sets the bar itself" "" "$(grep -nE '^set -g (status-(left|right|style)|message-style) ' "$ROOT/conf/tmux-attention.conf")"

# ---- B: the readers agree
. "$BIN/fleet-palette.sh"
fleet_palette_load || fail "B: fleet_palette_load could not read the palette"
names='PAL_BG PAL_FG PAL_DIM PAL_BLUE PAL_GREEN PAL_YELLOW PAL_RED PAL_CYAN PAL_MAGENTA PAL_SEL'
sh_table=''
for k in $names; do
  case "${!k:-}" in '#'[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) fail "B: $k is not a #rrggbb" "${!k:-}" ;; esac
  sh_table="$sh_table$k=${!k} "
done; ok
py_table=$(python3 - "$BIN/fleet-sidebar.py" "$names" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
t = mod.palette()
print("".join(f"{k}={t.get(k, '')} " for k in sys.argv[2].split()), end="")
EOF
)
eq "B: fleet-sidebar.py's palette() reads what the shell reads" "$sh_table" "$py_table"
eq "B: the Tokyo Night values of before (a first version moves no pixel)" \
   'PAL_BG=#1a1b26 PAL_FG=#a9b1d6 PAL_DIM=#565f89 PAL_BLUE=#7aa2f7 PAL_GREEN=#9ece6a PAL_YELLOW=#e0af68 PAL_RED=#f7768e PAL_CYAN=#7dcfff PAL_MAGENTA=#bb9af7 PAL_SEL=#414868 ' "$sh_table"
fleet_palette_rgb '#565f89'; eq "B: rgb of #565f89" '86;95;137' "$_fpr"
fleet_palette_rgb 'nope'; eq "B: rgb of junk is empty" '' "$_fpr"
fleet_palette_expand 'a $PAL_BLUE#,b $PAL_BG] $PAL_NONE'; eq "B: expand: known names only" 'a #7aa2f7#,b #1a1b26] $PAL_NONE' "$_fpe"

# ---- C: tmux reads it (isolated server)
if [ -n "$REAL_TMUX" ]; then
  mkdir -p "$WORK/conf"
  ln -s "$PAL" "$WORK/conf/fleet-palette.conf"; ln -s "$ROOT/conf/tmux-bar.conf" "$WORK/conf/tmux-bar.conf"
  grep -E "^source-file -F '#\{d:current_file\}/(fleet-palette|tmux-bar)\.conf'$" "$ROOT/conf/tmux-attention.conf" > "$WORK/conf/main.conf"
  eq "C: tmux-attention.conf sources the palette, then the bar" \
     "source-file -F '#{d:current_file}/fleet-palette.conf'
source-file -F '#{d:current_file}/tmux-bar.conf'" "$(cat "$WORK/conf/main.conf")"
  tm() { "$REAL_TMUX" -S "$SOCK" "$@"; }
  tm -f /dev/null new-session -d -s p -x 200 -y 20 2>/dev/null || fail "C: no isolated tmux server"
  tm source-file "$WORK/conf/main.conf" || fail "C: tmux could not source the two files"
  for o in status-left status-right status-style message-style message-command-style; do
    v=$(tm show-options -gv "$o")
    hasnt "C: $o has no unexpanded \$PAL_" '$PAL' "$v"
  done
  has "C: status-left draws in the palette's blue" "fg=$PAL_BLUE" "$(tm show-options -gv status-left)"
  has "C: …and the ⌂ off the hub on PAL_SEL" "bg=$PAL_SEL" "$(tm show-options -gv status-left)"
  eq "C: status-style is the palette's bg/fg" "bg=$PAL_BG,fg=$PAL_FG" "$(tm show-options -gv status-style)"
  eq "C: status-interval 2 (issue #1534)" 2 "$(tm show-options -gv status-interval)"
  hasnt "C: no PAL_* in the environment a pane inherits (%hidden)" 'PAL_' "$(tm show-environment -g)"
  has "C: status-right passes the client's width" 'cw=#{client_width}' "$(tm show-options -gv status-right)"
  tm kill-server 2>/dev/null
else
  printf 'fleet-palette-selftest: no tmux — leg C skipped\n' >&2
fi

# ---- D: one edit recolours every surface
mkroot() {   # mkroot <dir> [palette-text] — bin/ = links to every script, conf/ = the palette or none
  mkdir -p "$1/bin" "$1/conf"
  for f in "$BIN"/*; do ln -s "$f" "$1/bin/${f##*/}"; done
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$1/conf/fleet-palette.conf"
}
mkroot "$WORK/alt" "$(sed -e "s/'#7aa2f7'/'#123456'/" -e "s/'#565f89'/'#010203'/" -e "s/'#7dcfff'/'#00ff00'/" "$PAL")"
mkroot "$WORK/none"
mkdir -p "$WORK/tmp"
st() { FLEET_ALERTS_DISK=0 FLEET_STATUS_CACHE_SECS=0 TMPDIR="$WORK/tmp/" FLEET_CONF_DIR="$WORK/cd" FLEET_ACCOUNTS_DIR="$WORK/acc" \
       CCQUOTA_HUB_URL=http://127.0.0.1:9 CCQUOTA_FLEET='' bash "$1/bin/tmux-status.sh" 2>/dev/null; }
out=$(st "$WORK/alt")
has "D: the bar's 本机 is the edited blue" '#[fg=#123456]本机' "$out"
has "D: the separators are the edited dim" '#[fg=#010203]· 负载' "$out"
has "D: the alert counts too" '#[fg=#010203]│ #[range=user|alarm]' "$out"
hasnt "D: the old blue is gone" '#7aa2f7' "$out"
out=$(st "$WORK/none")
has "D: no palette → the bar still renders" '本机 ' "$out"
hasnt "D: no palette → no colour of its own" '#[fg=' "$out"
rows=$(sed -n "/^E=\$'/,/^GYU=/p" "$BIN/tmux-dashboard-rows.sh")
[ -n "$rows" ] || fail "D: could not find the rows producer's colour block"
gy=$( unset $names; BIN="$WORK/alt/bin"; eval "$rows"; printf '%q|%q|%q' "$GY" "$GYU" "$CY" )
eq "D: the rows' escapes follow the palette" "$(printf '%q|%q|%q' $'\033[38;2;1;2;3m' $'\033[4;38;2;1;2;3m' $'\033[38;2;0;255;0m')" "$gy"
gy=$( unset $names; BIN="$WORK/none/bin"; eval "$rows"; printf '%s|%s' "$GY" "$CY" )
eq "D: no palette → the rows draw uncoloured" "|" "$gy"
cols=$(python3 - "$BIN/fleet-sidebar.py" "$WORK/alt/conf/fleet-palette.conf" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
alt = mod.palette_colors(mod.palette(sys.argv[2]), 256)
base = mod.palette_colors(mod.palette(), 256)
low = mod.palette_colors(mod.palette(), 8)
print(alt["PAL_CYAN"], base["PAL_CYAN"], base["PAL_RED"], low["PAL_CYAN"] == mod.curses.COLOR_CYAN)
EOF
)
eq "D: the sidebar's colours follow the palette (#00ff00 → 46; #7dcfff → 117, #f7768e → 210); < 256 colours → the basic ones" "46 117 210 True" "$cols"

printf 'fleet-palette-selftest: OK (%d checks) — one colour table for the bar, the rows and the sidebar (issue #1534)\n' "$CHECKS"
