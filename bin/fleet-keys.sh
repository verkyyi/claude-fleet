#!/bin/bash
# fleet-keys.sh — the fleet keymap cheatsheet (issue #110). One curated source
# of truth for EVERY fleet shortcut, grouped by context:
#   tmux prefix binds · dashboard fzf · backlog fzf · config modal fzf.
#
# Opened by `prefix ?` (display-popup -E; see conf/tmux-attention.conf) and by a
# `?` bind inside the dash/backlog. The popup closes on q/esc.
#
# Usage:
#   fleet-keys.sh            # print the sheet, then wait for q/esc (popup mode)
#   fleet-keys.sh --plain    # print once and exit (no wait) — for pipes / tests
#                            #   also implied when stdout is not a tty
#
# Drift guard: bin/fleet-keys-selftest.sh cross-checks the keys listed here
# against the binds actually shipped in conf/tmux-attention.conf + the dash/
# backlog fzf --binds, so this sheet can't silently go stale.
set -u

PLAIN=""
[ "${1:-}" = "--plain" ] && PLAIN=1
# Non-interactive stdout (pipe/redirect/test) ⇒ print-and-exit, never block.
[ -t 1 ] || PLAIN=1

# --- colours (honour NO_COLOR + non-tty) --------------------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[36m'; YEL=$'\033[33m'; R=$'\033[0m'
else
  B=""; DIM=""; CYAN=""; YEL=""; R=""
fi

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

print_sheet() {
  printf '%s%s fleet keymap %s  %s(prefix = your tmux prefix, default C-b · q/esc to close)%s\n' \
    "$B" "$CYAN" "$R" "$DIM" "$R"

  group "tmux prefix" "— global, from any window"
  key "prefix a" "jump to the next window that needs you (red first, then green)"
  key "prefix j" "dashboard window — fzf mission control (creates it if missing)"
  key "prefix G" "full-screen dash popup — peek without switching windows"
  key "prefix b" "backlog modal — GitHub issues; enter spawns the issue's session"
  key "prefix A" "switch the active subscription account (multi-account failover)"
  key "prefix c" "config modal — view/edit FLEET_* across layers"
  key "prefix r" "hot-reload tmux config"
  key "prefix ?" "this cheatsheet"
  key "F9" "(no prefix) jump back to this session's steward hub"
  key "click ● N" "the needs badge (bottom-left) cycles to the next 'needs' window"

  group "dashboard" "— inside prefix j / prefix G"
  key "enter" "jump to the highlighted window"
  key "⌃g" "new session — pick an issue to spawn"
  key "⌃e" "rename the highlighted window"
  key "⌃x" "reap a merged+clean worker (window + worktree + issue)"
  key "⌥x" "force-reap (skip the merged/clean gate)"
  key "⌃t" "toggle live ⇄ landed (finished sessions; enter opens the PR)"
  key "⌃r" "refresh now"
  key "?" "this cheatsheet"
  key "esc" "back (dash window) / close (popup)"

  group "backlog" "— inside prefix b"
  key "type" "filter issues"
  key "enter" "work the issue — spawn its session"
  key "⌃n" "file a new issue"
  key "⌃t" "comment on the highlighted issue"
  key "⌃x" "close the highlighted issue (y/n confirm)"
  key "⌃p" "toggle the preview pane (body/labels/comments)"
  key "tab" "collapse/expand the milestone group"
  key "⌃o" "open the issue on the web"
  key "⌃r" "refresh now"
  key "⌃k" "this cheatsheet (⌃k, not ? — ? filters here)"
  key "esc" "close"

  group "config modal" "— inside prefix c"
  key "enter" "edit the highlighted key / expand the section"
  key "tab" "expand/collapse a section"
  key "⌃s" "toggle the write scope (global ⇄ per-fleet)"
  key "?" "reveal the raw FLEET_* keys inline"
  key "⌃r" "refresh now"
  key "esc" "close"
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
