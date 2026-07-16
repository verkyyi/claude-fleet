#!/bin/bash
# fleet-keys.sh — the fleet keymap cheatsheet (issue #110). One curated source
# of truth for EVERY fleet shortcut, grouped by context:
#   tmux prefix binds · dashboard fzf · backlog fzf · config modal fzf.
#
# Opened by `prefix ?` (display-popup -E; see conf/tmux-attention.conf) and by a
# `?` bind inside the dash/backlog. The popup closes on q/esc.
#
# Context scoping (issue #265): the global `prefix ?` shows the WHOLE sheet, but
# when opened from INSIDE a panel it shows only the shortcuts that apply there —
# that panel's own binds plus the global `tmux prefix` binds (which fire from any
# pane, the dash included), not the other panels' inner binds. Pass the panel via
# `--context dash|backlog` (default `all` = every group).
#
# Usage:
#   fleet-keys.sh                    # full sheet, wait for q/esc (popup mode)
#   fleet-keys.sh --context dash     # dashboard-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --context backlog  # backlog-scoped sheet (+ tmux prefix)
#   fleet-keys.sh --plain            # print once and exit (no wait) — pipes/tests
#                                    #   also implied when stdout is not a tty
#
# Drift guard: bin/fleet-keys-selftest.sh cross-checks the keys listed here
# against the binds actually shipped in conf/tmux-attention.conf + the dash/
# backlog fzf --binds, so this sheet can't silently go stale.
set -u

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
case "$CONTEXT" in all|dash|backlog) ;; *) CONTEXT="all" ;; esac
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

# want <group> — is this group in scope for the current $CONTEXT? The global
# `tmux prefix` binds fire from any pane, so they show in every scope; the
# per-panel groups (dashboard/backlog/config modal) show only in the full sheet
# or when that panel is the active context.
want() {
  case "$CONTEXT" in
    all)     return 0 ;;
    dash)    case "$1" in prefix|dashboard) return 0 ;; *) return 1 ;; esac ;;
    backlog) case "$1" in prefix|backlog)   return 0 ;; *) return 1 ;; esac ;;
    *)       return 0 ;;
  esac
}

print_sheet() {
  local sub
  case "$CONTEXT" in
    dash)    sub="(dashboard panel · prefix binds work here too · q/esc to close)" ;;
    backlog) sub="(backlog panel · prefix binds work here too · q/esc to close)" ;;
    *)       sub="(prefix = your tmux prefix, default C-b · q/esc to close)" ;;
  esac
  printf '%s%s fleet keymap %s  %s%s%s\n' "$B" "$CYAN" "$R" "$DIM" "$sub" "$R"

  if want prefix; then
  group "tmux prefix" "— global, from any window"
  key "prefix a" "jump to the next window that needs you (red first, then green)"
  key "prefix g" "focus the dash — jump to the hub's dash pane; press again to zoom it"
  key "prefix b" "backlog modal — GitHub issues; enter spawns the issue's session"
  key "prefix c" "config modal — view/edit FLEET_* across layers"
  key "prefix ?" "this cheatsheet"
  key "F9" "(no prefix) jump back to this session's steward hub"
  key "click ● N" "the needs badge (bottom-left) cycles to the next 'needs' window"
  key "click ● N (orange)" "cross-fleet dot = N needy windows in OTHER fleets; click to jump"
  key "click ◉ / usage" "footer account chip / usage stat — opens the usage + account modal"
  fi

  if want dashboard; then
  group "dashboard" "— inside the hub dash pane (prefix g)"
  key "enter" "jump to the highlighted window"
  key "⌃n" "new issue — file one AND spawn its worker (quick-dispatch)"
  key "⌃s" "raw scratch session (optional name) — plain claude, no issue/worktree/PR"
  key "⌃x" "reap a finished worker (window + worktree + issue) — confirms when the row isn't merged+clean"
  key "⌃t" "toggle live ⇄ landed (finished sessions)"
  key "⌃o" "restore the highlighted landed session into a new window (claude --resume)"
  key "enter (landed)" "resume the highlighted landed session — same as ⌃o"
  key "⌃p (landed)" "open the highlighted landed row's PR in the browser"
  key "⌃r" "refresh now"
  key "?" "this cheatsheet"
  key "esc" "relaunch the dash (it's the always-on hub pane)"
  fi

  if want backlog; then
  group "backlog" "— inside prefix b"
  key "space" "toggle the preview pane (body/labels/comments) — off by default"
  key "/" "filter issues (type to narrow; off by default)"
  key "enter" "work the issue — spawn its session"
  key "⌃n" "file a new issue"
  key "⌃x" "close the highlighted issue (y/n confirm)"
  key "⌃y" "cycle the issue's priority label (none→p2→p1→p0→none)"
  key "⌃o" "open the issue on the web"
  key "⌃r" "refresh now"
  key "?" "this cheatsheet"
  key "esc" "close"
  fi

  if want config; then
  group "config modal" "— inside prefix c"
  key "enter" "edit the highlighted key / expand the section"
  key "tab" "expand/collapse a section"
  key "⌃s" "toggle the write scope (global ⇄ per-fleet)"
  key "?" "reveal the raw FLEET_* keys inline"
  key "⌃r" "refresh now"
  key "esc" "close"
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
