#!/bin/bash
# fleet-keys.sh — the fleet keymap cheatsheet (issue #110). One curated source
# of truth for EVERY fleet shortcut, grouped by context:
#   tmux prefix binds · task sidebar · dashboard fzf · backlog fzf · config modal fzf.
#
# Opened by `prefix ?` in the client (a popup; see conf/tmux-shell.conf — the
# person's keys live only there since issue #1714) and by a `?` bind inside the
# dash/backlog. The popup closes on q/esc.
#
# Context scoping (issue #265): the global `prefix ?` shows the WHOLE sheet, but
# when opened from INSIDE a panel it shows only the shortcuts that apply there —
# that panel's own binds plus the global `tmux prefix` binds (which fire from any
# pane, the dash included), not the other panels' inner binds. Pass the panel via
# `--context dash|backlog` (default `all` = every group). `--context sidebar`
# (issue #948, cut to one screen by #963) is the task list's own short sheet —
# since issue #1950 the list takes no keys, so it is its four taps. The `.` row
# menu's letters stay in the full sheet, prefix ? away.
#
# Usage:
#   fleet-keys.sh                    # full sheet, wait for q/esc (popup mode)
#   fleet-keys.sh --context dash     # dashboard-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --context backlog  # backlog-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --context sidebar  # the task list's short sheet (its taps)
#   fleet-keys.sh --page             # ⌘/ / prefix ? (issue #1952): ONE page, opened
#                                    #   on the stage (fleet-shell.sh keys) — the ⌘
#                                    #   keys with each one's key in any other
#                                    #   terminal beside it, the writing area's, the
#                                    #   mouse's; fits a 38-row window
#   fleet-keys.sh --plain            # print once and exit (no wait) — pipes/tests
#                                    #   also implied when stdout is not a tty
#
# Drift guard: bin/fleet-keys-selftest.sh cross-checks the keys listed here
# against the binds actually shipped in conf/tmux-shell.conf + the dash/
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
PAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plain)      PLAIN=1 ;;
    --page)       PAGE=1 ;;
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

# The task list's short sheet (issue #963): one short line each, so it fits a
# popup that cannot scroll. Since issue #1950 the list takes no keys — the
# lines are its taps, the same four the full sheet's group lists.
# `skey <key> <desc>`: the key column is 14 CELLS. ${#k} counts a CJK character
# once though it takes two, so wide() counts those: their UTF-8 lead bytes
# (U+3000–U+9FFF: E3–E9, the full-width forms: EF). The arrows and ⌃ ⌥ ⌂ glyphs
# lead with E2 and stay one cell.
wide() { printf '%s' "$1" | LC_ALL=C tr -cd '\343-\351\357' | wc -c | tr -d ' '; }
skey() {
  local k="$1" pad n
  n=$((16 - ${#k} - $(wide "$k"))); [ "$n" -lt 1 ] && n=1
  printf -v pad '%*s' "$n" ''
  printf '  %s%s%s%s%s\n' "$YEL" "$k" "$R" "$pad" "$2"
}
print_sidebar_sheet() {
  printf '%s%s %s %s  %s%s%s\n\n' "$B" "$CYAN" "$(fleet_ui_t keys_sidebar_title)" "$R" "$DIM" "$(fleet_ui_t keys_close)" "$R"
  skey "$(fleet_ui_t keys_sidebar_m1k)" "$(fleet_ui_t keys_sidebar_m1)"
  skey "$(fleet_ui_t keys_sidebar_m2k)" "$(fleet_ui_t keys_sidebar_m2)"
  skey "$(fleet_ui_t keys_sidebar_m3k)" "$(fleet_ui_t keys_sidebar_m3)"
  skey "$(fleet_ui_t keys_sidebar_12k)" "$(fleet_ui_t keys_sidebar_12)"
  skey "$(fleet_ui_t keys_sidebar_m4k)" "$(fleet_ui_t keys_sidebar_m4)"
}

# THE page (issue #1952): what ⌘/ opens on the right. Three groups — the ⌘ keys
# (read from `dash-keymap.sh --panel switch`, so the page can never name a chord
# the conf does not catch; a pair — ⌘↑ ⌘↓, ⌘[ ⌘] — is one line), the writing
# area's, the mouse's — and on every ⌘ line, from a fixed column, the key any
# other terminal presses for it. The panels' inner keys stay on the full sheet.
# `pkey <key> <desc> [<other>]`: the key column 16 cells, the desc to column 64.
pkey() {
  local k="$1" d="$2" o="${3:-}" pad n
  n=$((16 - ${#k} - $(wide "$k"))); [ "$n" -lt 1 ] && n=1
  printf -v pad '%*s' "$n" ''
  if [ -n "$o" ]; then
    local dpad m
    m=$((44 - ${#d} - $(wide "$d"))); [ "$m" -lt 1 ] && m=1
    printf -v dpad '%*s' "$m" ''
    printf '    %s%s%s%s%s%s%s%s%s\n' "$B$YEL" "$k" "$R" "$pad" "$d" "$dpad" "$DIM" "$o" "$R"
  else
    printf '    %s%s%s%s%s\n' "$B$YEL" "$k" "$R" "$pad" "$d"
  fi
}
pgroup() { printf '\n  %s%s%s%s%s\n' "$B" "$CYAN" "$1" "$R" "${2:+  $DIM$2$R}"; }
print_page() {
  local sa sg sp acts='' done_acts=''
  local G_next='' G_prev='' G_back='' G_fwd='' P_next='' P_prev='' P_back='' P_fwd=''
  printf '\n  %s%s%s  %s%s%s  %s%s%s\n' "$B" "$(fleet_ui_t keys_page_title)" "$R" \
    "$DIM" "$(fleet_ui_t keys_page_sub)" "$R" "$DIM" "$(fleet_ui_t keys_close)" "$R"
  pgroup "$(fleet_ui_t keys_page_cmd)"
  # one read of the table: each action's chord (G_<a>) and other key (P_<a>)
  while read -r sa sg _ _ sp; do
    [ -n "$sa" ] || continue
    case "$sp" in F[0-9]*) ;; *) sp="prefix $sp" ;; esac
    printf -v "G_$sa" '%s' "$sg"; printf -v "P_$sa" '%s' "$sp"
    acts="$acts $sa"
  done <<EOF
$(bash "$BIN/dash-keymap.sh" --panel switch list 2>/dev/null)
EOF
  # the prototype's order: new, quick open, the two pairs, the rest; a table
  # action this list does not know still gets its line (the sheet's words)
  for sa in new switcher quickopen prev back needs zoom help $acts; do
    case " $done_acts " in *" $sa "*) continue ;; esac
    done_acts="$done_acts $sa"
    sg="G_$sa"; sp="P_$sa"
    [ -n "${!sg:-}" ] || continue
    case "$sa" in
      prev) done_acts="$done_acts next"
            pkey "$G_prev $G_next" "$(fleet_ui_t keys_page_prevnext)" "$P_prev / ${P_next#prefix }" ;;
      back) done_acts="$done_acts fwd"
            pkey "$G_back $G_fwd" "$(fleet_ui_t keys_page_backfwd)" "$P_back / ${P_fwd#prefix }" ;;
      new|switcher|quickopen|needs|zoom|help|fold|quit) pkey "${!sg}" "$(fleet_ui_t "keys_page_$sa")" "${!sp}" ;;
      *) pkey "${!sg}" "$(fleet_ui_t "keys_switch_$sa")" "${!sp}" ;;
    esac
  done
  pgroup "$(fleet_ui_t keys_page_compose)"
  pkey "↵" "$(fleet_ui_t keys_page_c_send)"
  pkey "⇧↵  ⌥↵" "$(fleet_ui_t keys_page_c_nl)"
  pkey "Tab" "$(fleet_ui_t keys_page_c_tab)"
  pkey "⇧⇥" "$(fleet_ui_t keys_page_c_btab)"
  pkey "space" "$(fleet_ui_t keys_page_c_space)"
  pkey "esc" "$(fleet_ui_t keys_page_c_esc)"
  pgroup "$(fleet_ui_t keys_page_mouse)"
  pkey "$(fleet_ui_t keys_sidebar_m1k)" "$(fleet_ui_t keys_sidebar_m1)"
  pkey "$(fleet_ui_t keys_sidebar_m2k)" "$(fleet_ui_t keys_page_m_menu)"
  pkey "$(fleet_ui_t keys_sidebar_m3k)" "$(fleet_ui_t keys_sidebar_m3)"
  pkey "$(fleet_ui_t keys_sidebar_12k)" "$(fleet_ui_t keys_sidebar_12)"
  pkey "$(fleet_ui_t keys_sidebar_m4k)" "$(fleet_ui_t keys_sidebar_m4)"
  printf '\n  %s%s%s\n' "$DIM" "$(fleet_ui_t keys_page_more)" "$R"
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
  key "prefix q" "$(fleet_ui_t keys_prefix_05)"
  key "prefix k" "$(fleet_ui_t keys_prefix_16)"
  key "prefix z" "$(fleet_ui_t keys_prefix_09)"
  key "prefix [" "$(fleet_ui_t keys_prefix_10)"
  key "prefix ?" "$(fleet_ui_t keys_prefix_13)"
  key "F9" "$(fleet_ui_t keys_prefix_14)"
  key "fleet guide" "$(fleet_ui_t keys_prefix_15)"
  fi

  if want switch; then
  # one row per `dash-keymap.sh --panel switch` action (issue #1903): the prefix
  # key (F9 has none), then its ⌘ chord in iTerm2 — read from the table, so a row
  # can never name a key the conf does not catch (fleet-keys-selftest.sh leg 10)
  group "$(fleet_ui_t keys_g_switch)" "$(fleet_ui_t keys_g_switch_sub)"
  local sa sg sp
  while read -r sa sg _ _ sp; do
    [ -n "$sa" ] || continue
    case "$sp" in F[0-9]*) ;; *) sp="prefix $sp" ;; esac
    key "$sp" "$sg  $(fleet_ui_t "keys_switch_$sa")"
  done <<EOF
$(bash "$BIN/dash-keymap.sh" --panel switch list 2>/dev/null)
EOF
  # the one-pane layout's keys (issue #1904): a phone / a narrow window, where the
  # Termius extra-key row carries them; anywhere else they go to the session
  key "F1" "$(fleet_ui_t keys_single_f1)"
  key "F2 F3" "$(fleet_ui_t keys_single_f23)"
  key "F4" "$(fleet_ui_t keys_single_f4)"
  fi

  if want sidebar; then
  # the task list takes no keys (issue #1950): its group is its taps
  group "$(fleet_ui_t keys_g_sidebar)" "$(fleet_ui_t keys_g_sidebar_sub)"
  key "$(fleet_ui_t keys_sidebar_m1k)" "$(fleet_ui_t keys_sidebar_m1)"
  key "$(fleet_ui_t keys_sidebar_m2k)" "$(fleet_ui_t keys_sidebar_m2)"
  key "$(fleet_ui_t keys_sidebar_m3k)" "$(fleet_ui_t keys_sidebar_m3)"
  key "$(fleet_ui_t keys_sidebar_12k)" "$(fleet_ui_t keys_sidebar_12)"
  key "$(fleet_ui_t keys_sidebar_m4k)" "$(fleet_ui_t keys_sidebar_m4)"
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

if [ -n "$PAGE" ]; then
  [ -t 1 ] && printf '\033[?25l'   # no cursor on a page to read
  print_page
else
  print_sheet
fi

[ -n "$PLAIN" ] && exit 0

# Interactive popup: hold open until q or esc. read -rsn1 grabs one keypress;
# $'\e' is the esc byte. Anything else just redraws nothing and waits again.
while :; do
  IFS= read -rsn1 k || break
  case "$k" in
    q|Q|$'\e') break ;;
  esac
done
