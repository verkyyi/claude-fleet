#!/bin/bash
# fleet-popup-selftest.sh — the one popup style (issue #1619, EPIC #1615 C4).
#
#   A. 54 COLUMNS, FOR REAL. A 54×50 client (the iPad) attached to an isolated
#      server, itself running in a pane of a second isolated server, so the outer
#      `capture-pane` holds what the client really drew, popup overlay included.
#      dash-popup.sh opens the five bound popups (prefix b / c / u / ! / ?) with
#      the hub on (the title names this machine, its longest form); every one
#      must draw a ROUNDED border at 96% of the client with its whole title on it.
#      With fzf installed, the alerts popup's key line (fleet_fzf_hint) must be
#      whole on the bottom row too.
#   B. ONLY PALETTE COLOURS. Every colour FLEET_FZF_OPTS and the menu style name
#      is one of conf/fleet-palette.conf's.
#   C. KEY LINES FIT. Every hint_* string, zh and en, is at most 47 columns (a
#      54-column client's 96% popup, less its border and fzf's 2-column gutter).
#   D. WIRED. The bound popups' fzf take their key line from fleet_fzf_hint, the
#      row menu its frame from fleet_menu_style, and a script's popup goes
#      through fleet_popup / dash-popup.sh (dash-popup-selftest.sh owns the
#      one-door lint).
#
# Drives bin/dash-popup.sh, bin/fleet-popup-lib.sh, bin/fleet-alerts.sh,
# bin/usage-modal.sh, bin/tmux-issues.sh, bin/tmux-config.sh,
# bin/fleet-sidebar-menu.sh and bin/fleet-ui-lang.sh.
# tmux absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { echo 'selftest: tmux not installed — SKIP' >&2; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fpop-selftest.XXXXXX")" || exit 2
ISOCK="$WORK/in.sock"; OSOCK="$WORK/out.sock"
cleanup() {
  "$REAL_TMUX" -S "$ISOCK" kill-server 2>/dev/null
  "$REAL_TMUX" -S "$OSOCK" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
export FLEET_UI_LANG=zh TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
. "$BIN/fleet-ui-lang.sh"

# --- B. only palette colours --------------------------------------------------
pal=$(sed -n "s/^%hidden PAL_[A-Z]*='\(#[0-9a-fA-F]*\)'.*/\1/p" "$ROOT/conf/fleet-palette.conf" | tr 'A-F' 'a-f')
[ -n "$pal" ] || fail "palette: conf/fleet-palette.conf read nothing"
used=$(bash -c '. "$1/fleet-popup-lib.sh"; fleet_fzf_opts; fleet_menu_style; printf "%s\n" "$FLEET_FZF_OPTS" "${FMENU_STYLE[@]}"' _ "$BIN" \
  | grep -o '#[0-9a-fA-F]\{6\}' | tr 'A-F' 'a-f' | sort -u)
[ -n "$used" ] || fail "palette: FLEET_FZF_OPTS names no colour"
for c in $used; do
  printf '%s\n' "$pal" | grep -qxF "$c" || fail "palette: $c is not a conf/fleet-palette.conf colour"
done
for k in bg: fg: hl: fg+: bg+: hl+: prompt: pointer: header: border:; do
  case "$(bash -c '. "$1/fleet-popup-lib.sh"; fleet_fzf_opts; printf %s "$FLEET_FZF_OPTS"' _ "$BIN")" in
    *"$k"*) ;; *) fail "palette: FLEET_FZF_OPTS leaves fzf's $k to fzf's default" ;;
  esac
done
echo "ok: only palette colours — fzf and the menu frame"

# --- C. key lines fit 54 columns ---------------------------------------------
keys=$(grep -o '^ *zh:hint_[a-z_]*)' "$BIN/fleet-ui-lang.sh" | sed 's/^ *zh://; s/)$//')
[ -n "$keys" ] || fail "fit: no hint_* strings in fleet-ui-lang.sh"
for k in $keys; do
  for l in zh en; do
    t=$(FLEET_UI_LANG=$l fleet_ui_t "$k")
    [ "$t" != "$k" ] || fail "fit: $k has no $l text"
    w=$(printf '%s' "$t" | python3 -c 'import sys,unicodedata as u; print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in sys.stdin.read()))')
    [ "$w" -le 47 ] || fail "fit: $l $k is $w columns, > 47: $t"
  done
done
echo "ok: every key line fits a 54-column popup ($(printf '%s ' $keys))"

# --- D. wired ------------------------------------------------------------------
for f in fleet-alerts.sh usage-modal.sh tmux-issues.sh tmux-config.sh; do
  grep -q 'fleet_fzf_hint ' "$BIN/$f" || fail "wired: $f does not take its key line from fleet_fzf_hint"
done
for f in tmux-issues.sh tmux-config.sh dash-config-edit.sh fleet-repo-ask.sh; do
  grep -n -- '--border=rounded' "$BIN/$f" | grep -v 'FZF_FRAME=' | grep -qv '^[0-9]*:[[:space:]]*#' \
    && fail "wired: $f draws its own border inside the popup's"
done
grep -q 'fleet_menu_style' "$BIN/fleet-sidebar-menu.sh" && grep -q 'FMENU_STYLE\[@\]' "$BIN/fleet-sidebar-menu.sh" \
  || fail "wired: the row menu does not take the popup frame"
# The popups' keys are the CLIENT's since issue #1714 (EPIC #1710 C4): prefix /
# (⌘P; prefix ?'s sheet went with issue #2362) opens through the one door there,
# and the node opens none (b c u ! retired).
grep -E '^bind / ' "$ROOT/conf/tmux-shell.conf" | grep -q 'dash-popup\.sh .*--title popup_' \
  || fail "wired: the client's prefix / does not open through dash-popup.sh with a title"
grep -v '^[[:space:]]*#' "$ROOT/conf/tmux-attention.conf" | grep -q 'dash-popup\.sh' && fail "wired: the node conf still opens a popup (#1714)"
echo "ok: wired — hints, frames, the menu and the client's / bind"

# --- A. 54 columns, for real ---------------------------------------------------
T() { "$REAL_TMUX" -S "$ISOCK" "$@"; }
T -f /dev/null new-session -d -s ev -x 54 -y 50 'sleep 600' || fail "54: no isolated server"
T set -g status off
"$REAL_TMUX" -S "$OSOCK" -f /dev/null new-session -d -s o -x 54 -y 50 \
  "env -u TMUX '$REAL_TMUX' -S '$ISOCK' attach -t ev" || fail "54: no outer server"
"$REAL_TMUX" -S "$OSOCK" set -g status off
cl=''
for _ in $(seq 1 50); do cl=$(T list-clients -F '#{client_name}' 2>/dev/null | head -1); [ -n "$cl" ] && break; sleep 0.1; done
[ -n "$cl" ] || fail "54: the client never attached"
[ "$(T display-message -p -c "$cl" '#{client_width}')" = 54 ] || fail "54: the client is not 54 columns"
export TMUX="$ISOCK,$$,0" TMUX_PANE
TMUX_PANE=$(T list-panes -t ev -F '#{pane_id}' | head -1)
# the hub on: the sidebar's cache names this machine, so titles are their longest
mkdir -p "$TMPDIR/.claude-dash/global"
printf '#ts\0371\n#me\037m5\n' > "$TMPDIR/.claude-dash/global/remote_ev"

shot() { "$REAL_TMUX" -S "$OSOCK" capture-pane -p -t o; }
# open <title-key> <size> <body…>: draw it, wait for its border, leave the frame in $SHOT
open_popup() {
  local key=$1 size=$2; shift 2
  rm -f "$WORK/close"
  bash "$BIN/dash-popup.sh" --client "$cl" --no-inline --size "$size" --title "$key" -- "$@" >/dev/null 2>&1 &
  local pid=$!
  SHOT=''
  for _ in $(seq 1 60); do
    SHOT=$(shot); case "$SHOT" in *'╭'*) [ -n "${WANT_LAST:-}" ] || break
      printf '%s\n' "$SHOT" | grep -qF -- "$WANT_LAST" && break ;; esac
    sleep 0.1
  done
  : > "$WORK/close"; wait "$pid" 2>/dev/null
  for _ in $(seq 1 30); do case "$(shot)" in *'╭'*) sleep 0.1 ;; *) break ;; esac; done
}
hold="while [ ! -e '$WORK/close' ]; do sleep 0.1; done"
for spec in popup_backlog:L popup_config:L popup_usage:M popup_alerts:M popup_keys:L; do
  key=${spec%:*}; title="$(fleet_ui_t "$key") · m5"
  WANT_LAST='' open_popup "$key" "${spec#*:}" sh -c "$hold"
  top=$(printf '%s\n' "$SHOT" | grep -m1 '╭')
  [ -n "$top" ] || fail "54: $key drew no rounded border: $(printf '%s' "$SHOT" | head -3)"
  case "$top" in *"╭"*"─ $title ─"*"╮"*) ;; *) fail "54: $key's title is not whole on the border: [$top]" ;; esac
  # 96% of 54 = 51 columns wide, border to border
  inner=${top#*╭}; inner=${inner%╮*}
  w=$(printf '%s' "$inner" | python3 -c 'import sys,unicodedata as u; print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in sys.stdin.read()))')
  [ "$w" -ge 47 ] || fail "54: $key is $((w + 2)) columns wide, not the narrow 96%: [$top]"
done
echo "ok: 54 columns — five popups, rounded, 96%, every title whole"

if command -v fzf >/dev/null 2>&1; then
  hint=$(fleet_ui_t hint_alerts)
  body=". '$BIN/fleet-popup-lib.sh'; fleet_fzf_hint '$hint'; printf 'a\nb\n' | fzf --layout=reverse \"\${FZF_HINT[@]}\" & p=\$!; $hold; kill \$p"
  WANT_LAST="$hint" open_popup popup_alerts M bash -c "$body"
  printf '%s\n' "$SHOT" | grep -qF -- "$hint" || fail "54: the alerts key line is not whole: $(printf '%s\n' "$SHOT" | grep '│' | tail -3)"
  echo "ok: 54 columns — the key line is whole at the bottom"
else
  echo "skip: no fzf — the key-line leg"
fi
echo "PASS fleet-popup-selftest"
