#!/bin/bash
# fleet-keys.sh — the fleet keymap cheatsheet (issue #110). One curated source
# of truth for EVERY fleet shortcut, grouped by context:
#   tmux prefix binds · task sidebar · dashboard fzf · backlog fzf · config modal fzf.
#
# Opened by `prefix ?` (a fleet popup; see conf/tmux-attention.conf) and by a
# `?` bind inside the dash/backlog. The popup closes on q/esc.
#
# Context scoping (issue #265): the global `prefix ?` shows the WHOLE sheet, but
# when opened from INSIDE a panel it shows only the shortcuts that apply there —
# that panel's own binds plus the global `tmux prefix` binds (which fire from any
# pane, the dash included), not the other panels' inner binds. Pass the panel via
# `--context dash|backlog` (default `all` = every group). `--context sidebar`
# (issue #948, cut to one screen by #963) is the task sidebar's own `?` sheet:
# the six keys an operator actually uses there, in short Chinese, so the popup
# never needs scrolling. Everything else — the full task sidebar group and the
# `.` row menu's letters — stays in the full sheet, prefix ? away.
#
# Usage:
#   fleet-keys.sh                    # full sheet, wait for q/esc (popup mode)
#   fleet-keys.sh --context dash     # dashboard-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --context backlog  # backlog-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --context sidebar  # the task sidebar's sheet (its `?` / ? row)
#   fleet-keys.sh --plain            # print once and exit (no wait) — pipes/tests
#                                    #   also implied when stdout is not a tty
#
# Drift guard: bin/fleet-keys-selftest.sh cross-checks the keys listed here
# against the binds actually shipped in conf/tmux-attention.conf + the dash/
# backlog fzf --binds, so this sheet can't silently go stale.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || true
if command -v fleet_load_conf >/dev/null 2>&1; then
  sess="${FLEET_SESSION:-}"
  [ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null || true)
  [ -n "$sess" ] && fleet_load_conf "$sess" 2>/dev/null || true
fi
. "$BIN/fleet-ui-lang.sh"
fleet_ui_pin

PLAIN=""
CONTEXT="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --plain)      PLAIN=1 ;;
    --context)    shift; CONTEXT="${1:-all}" ;;
    --context=*)  CONTEXT="${1#--context=}" ;;
    *)            ;;  # ignore unknown args (forward-compat)
  esac
  shift
done
# Unknown context ⇒ fall back to the full sheet (never render nothing).
case "$CONTEXT" in all|dash|backlog|sidebar) ;; *) CONTEXT="all" ;; esac
# Non-interactive stdout (pipe/redirect/test) ⇒ print-and-exit, never block.
[ -t 1 ] || PLAIN=1

# --- colours (honour NO_COLOR + non-tty) --------------------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; YEL=$'\033[33m'; R=$'\033[0m'
else
  B=""; DIM=""; CYAN=""; YEL=""; R=""
fi

# --- panel keys: resolved tables, never the defaults (#556/#558) ------------
# tmux never delivers its prefix (or prefix2) to a pane, so the dash resolves
# every ⌃-key through bin/dash-keymap.sh at launch — the default, else its ⌥
# fallback. This sheet reads the SAME resolution: `dg <action>` is the glyph
# actually bound, `dn <action>` a trailing note when the default was dodged —
# so the sheet can never name a key the terminal will not deliver.
# Start with the dash table; backlog/config load their own before rendering.
eval "$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)"
dg() {
  local v; v="DASH_GLYPH_$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')"
  printf '%s' "${!v:-⌃?}"
}
dn() {
  local a s r g gl
  a=$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')
  s="DASH_KEYSTATE_$a"; r="DASH_REMAP_$a"; g="DASH_GLYPH_$a"; gl="${!g:-}"
  case "${!s:-ok}" in
    remapped)    fleet_ui_t keys_dn_remapped_fmt "${gl#⌥}" "${!r:-}" ;;
    unreachable) fleet_ui_t keys_dn_unreachable_fmt "$gl" "${!r:-}" ;;
  esac
}

# group <title>; then key <keys> <desc> rows. Two columns; the key column is
# padded to a fixed DISPLAY width — computed from ${#k} (character count, not
# bytes) so multi-byte glyphs like ⌃ / ⌥ / ● still line up in a UTF-8 locale.
group() { printf '\n%s%s%s %s%s\n' "$B" "$CYAN" "$1" "$R" "${2:+$DIM$2$R}"; }
key() {
  local k="$1" desc="$2" pad n
  n=$((11 - ${#k})); [ "$n" -lt 1 ] && n=1
  printf -v pad '%*s' "$n" ''
  printf '  %s%s%s%s%s\n' "$YEL" "$k" "$R" "$pad" "$desc"
}

# want <group> — is this group in scope for the current $CONTEXT? The global
# `tmux prefix` binds fire from any pane, so they show in every scope; the
# per-panel groups (dashboard/backlog/config modal) show only in the full sheet
# or when that panel is the active context.
want() {
  case "$CONTEXT" in
    all)     return 0 ;;
    dash)    case "$1" in prefix|dashboard) return 0 ;; *) return 1 ;; esac ;;
    backlog) case "$1" in prefix|backlog)   return 0 ;; *) return 1 ;; esac ;;
    sidebar) return 1 ;;   # its own compact sheet: print_sidebar_sheet
    *)       return 0 ;;
  esac
}

# The task sidebar's `?` sheet (issue #963): the seven keys an operator uses on
# the sidebar (the input line's editing keys share one row, #1097), one short
# line each, so the whole sheet fits its popup
# (fleet-sidebar.py's open_help sizes it to this) — the popup cannot scroll.
# `skey <key> <desc>`: the key column is 14 CELLS. ${#k} counts a CJK character
# once though it takes two, so wide() counts those: their UTF-8 lead bytes
# (U+3000–U+9FFF: E3–E9, the full-width forms: EF). The arrows and ⌃ ⌥ ⌂ glyphs
# lead with E2 and stay one cell.
# Keymap-resolved keys still come from `--panel sidebar` (dg), never hardcoded.
wide() { printf '%s' "$1" | LC_ALL=C tr -cd '\343-\351\357' | wc -c | tr -d ' '; }
skey() {
  local k="$1" pad n
  n=$((14 - ${#k} - $(wide "$k"))); [ "$n" -lt 1 ] && n=1
  printf -v pad '%*s' "$n" ''
  printf '  %s%s%s%s%s\n' "$YEL" "$k" "$R" "$pad" "$2"
}
print_sidebar_sheet() {
  eval "$(bash "$BIN/dash-keymap.sh" --panel sidebar env 2>/dev/null)"
  printf '%s%s %s %s  %s%s%s\n\n' "$B" "$CYAN" "$(fleet_ui_t keys_sidebar_title)" "$R" "$DIM" "$(fleet_ui_t keys_close)" "$R"
  skey "$(fleet_ui_t keys_sb_type_k)" "$(fleet_ui_t keys_sb_type)"
  skey "↑ ↓" "$(fleet_ui_t keys_sb_switch)"
  skey "$(fleet_ui_t keys_sb_edit_k)" "←→ Home End ⌥←→ $(dg bol) $(dg eol) $(dg kill_word) $(dg kill_eol) ⌃u" # ui-lang-ok: key glyphs, no words
  skey "$(fleet_ui_t keys_sb_menu_k_fmt "$(dg menu)")" "$(fleet_ui_t keys_sb_menu)$(dn menu)"
  skey "esc" "$(fleet_ui_t keys_sb_esc)"
  skey "$(dg scratch) $(dg view) $(dg reload) $(dg info)" "$(fleet_ui_t keys_sb_more)"
  skey "F9" "$(fleet_ui_t keys_sb_home)"
  skey "prefix ?" "$(fleet_ui_t keys_sb_all_fmt "${DASH_KEYMAP_PREFIX:-C-b}")"
}

# THE sheet — one structure, every string from fleet-ui-lang.sh (issue #1535:
# the zh copy of this whole function folded into the one table, row for row).
print_sheet() {
  local sub
  if [ "$CONTEXT" = sidebar ]; then print_sidebar_sheet; return; fi
  case "$CONTEXT" in
    dash)    sub=$(fleet_ui_t keys_sub_dash) ;;
    backlog) sub=$(fleet_ui_t keys_sub_backlog) ;;
    *)       sub=$(fleet_ui_t keys_sub_all_fmt "${DASH_KEYMAP_PREFIX:-C-b}") ;;
  esac
  printf '%s%s %s %s  %s%s%s\n' "$B" "$CYAN" "$(fleet_ui_t keys_title)" "$R" "$DIM" "$sub" "$R"

  if want prefix; then
  group "$(fleet_ui_t keys_g_prefix)" "$(fleet_ui_t keys_g_prefix_sub)"
  key "prefix a" "$(fleet_ui_t keys_prefix_01)"
  key "prefix g" "$(fleet_ui_t keys_prefix_02)"
  key "prefix e" "$(fleet_ui_t keys_prefix_03)"
  key "prefix E" "$(fleet_ui_t keys_prefix_04)"
  key "prefix h" "$(fleet_ui_t keys_prefix_05)"
  key "prefix Space" "$(fleet_ui_t keys_prefix_06 "$(dg scratch)")$(dn scratch)"
  key "prefix b" "$(fleet_ui_t keys_prefix_07)"
  key "prefix c" "$(fleet_ui_t keys_prefix_08)"
  key "prefix z" "$(fleet_ui_t keys_prefix_09)"
  key "prefix [" "$(fleet_ui_t keys_prefix_10)"
  key "prefix u" "$(fleet_ui_t keys_prefix_11)"
  key "prefix !" "$(fleet_ui_t keys_prefix_12)"
  key "prefix ?" "$(fleet_ui_t keys_prefix_13)"
  key "F9" "$(fleet_ui_t keys_prefix_14)"
  key "cf --guide" "$(fleet_ui_t keys_prefix_15)"
  key "click ● N" "$(fleet_ui_t keys_prefix_16)"
  key "click ✖ / ▲" "$(fleet_ui_t keys_prefix_17)"
  fi

  if want sidebar; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel sidebar env 2>/dev/null)"
  group "$(fleet_ui_t keys_g_sidebar)" "$(fleet_ui_t keys_g_sidebar_sub)"
  key "$(fleet_ui_t keys_sidebar_01k)" "$(fleet_ui_t keys_sidebar_01)"
  key "$(fleet_ui_t keys_sidebar_02k)" "$(fleet_ui_t keys_sidebar_02)"
  key "enter" "$(fleet_ui_t keys_sidebar_03)"
  key "esc" "$(fleet_ui_t keys_sidebar_04)"
  key "↑ / ↓" "$(fleet_ui_t keys_sidebar_05)"
  key "← / →" "$(fleet_ui_t keys_sidebar_06)"
  key "⌥← / ⌥→" "$(fleet_ui_t keys_sidebar_07)"
  key "$(dg bol)" "$(fleet_ui_t keys_sidebar_08)$(dn bol)"
  key "$(dg eol)" "$(fleet_ui_t keys_sidebar_09)$(dn eol)"
  key "$(dg kill_word)" "$(fleet_ui_t keys_sidebar_10)$(dn kill_word)"
  key "$(dg kill_eol)" "$(fleet_ui_t keys_sidebar_11)$(dn kill_eol)"
  key "$(fleet_ui_t keys_sidebar_12k)" "$(fleet_ui_t keys_sidebar_12)"
  key "$(dg new)" "$(fleet_ui_t keys_sidebar_13)$(dn new)"
  key "$(dg menu)" "$(fleet_ui_t keys_sidebar_14)$(dn menu)"
  key "$(dg restore)" "$(fleet_ui_t keys_sidebar_15)$(dn restore)"
  key "$(dg help)" "$(fleet_ui_t keys_sidebar_16)$(dn help)"
  key "$(dg scratch)" "$(fleet_ui_t keys_sidebar_18)$(dn scratch)"
  key "$(dg view)" "$(fleet_ui_t keys_sidebar_19)$(dn view)"
  key "$(dg reload)" "$(fleet_ui_t keys_sidebar_20)$(dn reload)"
  key "$(dg info)" "$(fleet_ui_t keys_sidebar_21)$(dn info)"
  key "prefix e" "$(fleet_ui_t keys_sidebar_17)"
  fi

  if want menu; then
  group "$(fleet_ui_t keys_g_menu)" "$(fleet_ui_t keys_g_menu_sub)"
  local mk what
  while IFS='	' read -r mk what; do
    [ -n "$mk" ] && key "$mk" "$what"
  done <<EOF
$(bash "$BIN/fleet-sidebar-menu.sh" --keys 2>/dev/null)
EOF
  fi

  if want dashboard; then
  group "$(fleet_ui_t keys_g_dashboard)" "$(fleet_ui_t keys_g_dashboard_sub)"
  key "enter" "$(fleet_ui_t keys_dashboard_01)"
  key "→ / ←" "$(fleet_ui_t keys_dashboard_02)"
  key "id a1 b7" "$(fleet_ui_t keys_dashboard_03)"
  key "$(fleet_ui_t keys_dashboard_04k)" "$(fleet_ui_t keys_dashboard_04)"
  key "$(dg new)" "$(fleet_ui_t keys_dashboard_05)$(dn new)"
  key "$(dg scratch)" "$(fleet_ui_t keys_dashboard_06)$(dn scratch)"
  key "$(dg agent)" "$(fleet_ui_t keys_dashboard_07)$(dn agent)"
  key "$(dg rename)" "$(fleet_ui_t keys_dashboard_08)$(dn rename)"
  key "$(dg answer)" "$(fleet_ui_t keys_dashboard_09)$(dn answer)"
  key "$(dg reap)" "$(fleet_ui_t keys_dashboard_10)$(dn reap)"
  key "$(dg migrate)" "$(fleet_ui_t keys_dashboard_11)$(dn migrate)"
  key "$(dg pin)" "$(fleet_ui_t keys_dashboard_12)$(dn pin)"
  key "$(dg repo-add)" "$(fleet_ui_t keys_dashboard_13)$(dn repo-add)"
  key "$(dg view)" "$(fleet_ui_t keys_dashboard_14)$(dn view)"
  key "$(dg restore)" "$(fleet_ui_t keys_dashboard_15)$(dn restore)"
  key "enter (landed)" "$(fleet_ui_t keys_dashboard_16 "$(dg restore)")"
  key "$(dg pr) (landed)" "$(fleet_ui_t keys_dashboard_17)$(dn pr)"
  key "$(dg reload)" "$(fleet_ui_t keys_dashboard_18)$(dn reload)"
  key "?" "$(fleet_ui_t keys_dashboard_19)"
  key "esc" "$(fleet_ui_t keys_dashboard_20)"
  fi

  if want backlog; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel backlog env 2>/dev/null)"
  group "$(fleet_ui_t keys_g_backlog)" "$(fleet_ui_t keys_g_backlog_sub)"
  key "space" "$(fleet_ui_t keys_backlog_01)"
  key "/" "$(fleet_ui_t keys_backlog_02)"
  key "enter" "$(fleet_ui_t keys_backlog_03)"
  key "$(dg new)" "$(fleet_ui_t keys_backlog_04)$(dn new)"
  key "$(dg close)" "$(fleet_ui_t keys_backlog_05)$(dn close)"
  key "$(dg priority)" "$(fleet_ui_t keys_backlog_06)$(dn priority)"
  key "$(dg open)" "$(fleet_ui_t keys_backlog_07)$(dn open)"
  key "$(dg reload)" "$(fleet_ui_t keys_backlog_08)$(dn reload)"
  key "?" "$(fleet_ui_t keys_backlog_09)"
  key "esc" "$(fleet_ui_t keys_backlog_10)"
  fi

  if want config; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel config env 2>/dev/null)"
  group "$(fleet_ui_t keys_g_config)" "$(fleet_ui_t keys_g_config_sub)"
  key "enter" "$(fleet_ui_t keys_config_01)"
  key "tab" "$(fleet_ui_t keys_config_02)"
  key "$(dg scope)" "$(fleet_ui_t keys_config_03)$(dn scope)"
  key "space / $(dg preview)" "$(fleet_ui_t keys_config_04)$(dn preview)"
  key "?" "$(fleet_ui_t keys_config_05)"
  key "$(dg reload)" "$(fleet_ui_t keys_config_06)$(dn reload)"
  key "esc" "$(fleet_ui_t keys_config_07)"
  fi
}

print_sheet

[ -n "$PLAIN" ] && exit 0

# Interactive popup: hold open until q or esc. read -rsn1 grabs one keypress;
# $'\e' is the esc byte. Anything else just redraws nothing and waits again.
while :; do
  IFS= read -rsn1 k || break
  case "$k" in
    q|Q|$'\e') break ;;
  esac
done
