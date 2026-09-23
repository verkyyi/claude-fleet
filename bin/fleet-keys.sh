#!/bin/bash
# fleet-keys.sh — the fleet keymap cheatsheet (issue #110). One curated source
# of truth for EVERY fleet shortcut, grouped by context:
#   tmux prefix binds · task sidebar · dashboard fzf · backlog fzf · config modal fzf.
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
BIN="$(cd "$(dirname "$0")" && pwd)"

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

# --- panel keys: resolved tables, never the defaults (#556/#558) ------------
# tmux never delivers its prefix (or prefix2) to a pane, so the dash resolves
# every ⌃-key through bin/dash-keymap.sh at launch — the default, else its ⌥
# fallback. This sheet reads the SAME resolution: `dg <action>` is the glyph
# actually bound, `dn <action>` a trailing note when the default was dodged —
# so the sheet can never name a key the terminal will not deliver.
# Start with the dash table; backlog/config load their own before rendering.
eval "$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)"
dg() {
  local v; v="DASH_GLYPH_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  printf '%s' "${!v:-⌃?}"
}
dn() {
  local a s r g gl
  a=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  s="DASH_KEYSTATE_$a"; r="DASH_REMAP_$a"; g="DASH_GLYPH_$a"; gl="${!g:-}"
  case "${!s:-ok}" in
    remapped)    printf ' — (⌥ fallback: ⌃%s is your tmux prefix %s)' "${gl#⌥}" "${!r:-}" ;;
    unreachable) printf ' — (UNREACHABLE: %s is your tmux prefix %s and its ⌥ twin is one too)' "$gl" "${!r:-}" ;;
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
    *)       return 0 ;;
  esac
}

print_sheet() {
  local sub
  case "$CONTEXT" in
    dash)    sub="(dashboard panel · prefix binds work here too · q/esc to close)" ;;
    backlog) sub="(backlog panel · prefix binds work here too · q/esc to close)" ;;
    *)       sub="(prefix = your tmux prefix, ${DASH_KEYMAP_PREFIX:-C-b} here · q/esc to close)" ;;
  esac
  printf '%s%s fleet keymap %s  %s%s%s\n' "$B" "$CYAN" "$R" "$DIM" "$sub" "$R"

  if want prefix; then
  group "tmux prefix" "— global, from any window"
  key "prefix a" "jump to the next window that needs you (red first, then green)"
  key "prefix g" "focus the dash — jump to the hub's dash pane; press again to zoom it"
  key "prefix e" "show/hide the worker task sidebar (saved for this fleet; narrow screens hide it automatically)"
  key "prefix E" "focus the task sidebar (or click/tap it) — then type: see the 'task sidebar' group"
  key "prefix b" "backlog modal — GitHub issues; enter spawns the issue's session"
  key "prefix c" "config modal — view/edit FLEET_* across layers"
  key "prefix ?" "this cheatsheet"
  key "F9" "(no prefix) jump back to this session's hub — from a task showing the task bar, the first press focuses the bar (like prefix E) and a second press goes to the hub; the ⌂ tap does the same (FLEET_HOME_SIDEBAR_FIRST=0 turns it off)"
  key "click ● N" "the needs badge (bottom-left) cycles to the next 'needs' window"
  key "click ● N (orange)" "cross-fleet dot = N needy windows in OTHER fleets; click to jump"
  key "click usage" "footer usage stat — opens the usage + account modal"
  fi

  if want sidebar; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel sidebar env 2>/dev/null)"
  group "task sidebar" "— once prefix E or a tap puts the keyboard on it"
  key "type a name" "fills the ONE input line at the bottom — every letter types (q n j k too), CJK fine; backspace deletes"
  key "enter" "with a name: start a scratch session named after it (the hub's ⌃s) and switch to it — no popup, no hub. A refusal (cap, worktree) shows on the line and keeps the name. Empty line: give input back to the worker"
  key "esc" "clear the typed name; on an empty line give input back to the worker"
  key "↑ / ↓" "switch to the highlighted task (follows once you pause, ~¼s; a held key is one switch, a row passed over is never selected); home/end the ends"
  key "← / →" "fold / unfold the highlighted row's subtree"
  key "$(dg new)" "new task — file an issue AND spawn its worker (the hub's ⌃n popup)$(dn new)"
  key "$(dg menu)" "on an EMPTY line: the highlighted task's menu — rename · pin · open PR · answer its question · flip new sessions claude⇄codex · reap (asks y/n first) · new task. Inside a name it types a dot. Touch: tap the highlighted row again$(dn menu)"
  key "prefix e" "hide the sidebar (q types now; no tap hides it)"
  fi

  if want dashboard; then
  group "dashboard" "— inside the hub dash pane (prefix g)"
  key "enter" "jump to the highlighted window"
  key "→ / ←" "unfold / fold the highlighted row's subtree. A session spawned from another one nests under it (└ indent), and those children are COLLAPSED BY DEFAULT — the parent row's \`3/5 ✓ · 1!\` badge is what the folded block says, so the list stays one line per parent. → opens the block you are on, ← shuts the block you are IN (from the parent row or from any child in it, which puts the cursor back on the parent). A child in \`needs\` NEVER folds away — any red glyph (\`?\` question · \`⊘\` permission · \`⊠\` worker-declared blocker: read the issue · \`!\`) — because the quiet layer folds and the loud one does not. ▸ / ▾ on a row marks a folded / open block. The closed view (⌃t) nests and folds the same way, off the ledger's own record of what spawned what. With text typed on the prompt line, ←/→ are that line's cursor keys as always"
  key "id a1 b7" "the leftmost id column is that WINDOW's handle (a1…z9) — unique in this fleet, it survives a migrate/handoff, and it is accepted wherever a window target is: \`fleet-migrate.sh b3\`, \`dash-reap.sh a1\`. Freed for reuse once the window is gone; the landed view has none (⌃t shows \`·\`)"
  key "type a name, enter" "scratch named after the text, full text prefilled as an UNSENT draft; CJK + spaces fine, title capped at 24 cols (esc clears the dash input)"
  key "$(dg new)" "new issue — file one AND spawn its worker (quick-dispatch)$(dn new)"
  key "$(dg scratch)" "raw scratch session — spawns instantly (the fleet's default agent in its own scratch-N worktree, no issue, no prompt)$(dn scratch)"
  key "$(dg agent)" "flip this fleet's default agent for NEW sessions (claude ⇄ codex) — the prompt line shows it (claude ▸ / codex ▸); written to the fleet's conf, so every spawn path follows — this key, prefix+c or FLEET_AGENT in the conf are the ways to pick it (no prompt-line prefix)$(dn agent)"
  key "$(dg rename)" "rename the highlighted window — edit inline on the query line (↵ commits · esc cancels)$(dn rename)"
  key "$(dg answer)" "deal with the highlighted red row. A \`?\` row is an AskUserQuestion: a tappable list per question, one tap each (issue #605) — and the ONLY way to answer one, since a SendMessage is delivered between turns and a pending question IS the turn, so the message waits for the answer that waits for the message. A \`⊘\` row is a PERMISSION prompt: this SHOWS you the blocked command and the reason it was stopped, without attaching to the pane (issue #640) — approving one is a human decision and nothing here will press Yes. Either way nothing is typed unless the chosen option is visibly on the worker's screen$(dn answer)"
  key "$(dg reap)" "reap a finished worker (window + worktree + issue) — confirms when the row isn't merged+clean. Targets: @window-id, %pane-id, registered handle, issue-N or scratch-N; indexes/names are refused. From a SCRIPT: \`dash-reap.sh <handle> --yes\` takes that confirm branch unasked (a dirty worktree is still KEPT) and prints a result token (\`reaped:full\`/\`reaped:keep\`/\`skip:needs-confirm\`/\`refused:<slug>\`); with no client attached it never pops a box at you$(dn reap)"
  key "$(dg migrate)" "move the highlighted session onto another subscription account NOW — the unstick for a \`⚠ stuck\` row (issue #873). A confirm popup shows the target account and every background command the move will stop; y closes it (/exit), stops those commands, and resumes the same transcript in a new window on the account with headroom, the stopped commands named in its first prompt. Refuses when no account has room (every one benched) — it never bounces a session onto another wall. Same as \`fleet-account.sh migrate --force-bg <window>\`; \`migrate --stuck\` moves every stuck row$(dn migrate)"
  key "$(dg pin)" "pin/unpin the highlighted window to the TOP of the list — a pin beats the status sort (a pinned idle row sits above a red one), so the session you are deliberately watching stays where you left it. Pinning a PARENT floats its children with it, still nested; a pinned row is marked 📌. The pin lives on the tmux window, so it vanishes with the window — nothing to clean up$(dn pin)"
  key "$(dg view)" "toggle live ⇄ closed (finished sessions + scratch)$(dn view)"
  key "$(dg restore)" "restore the highlighted landed session into a new window (claude --resume)$(dn restore)"
  key "enter (landed)" "resume the highlighted landed session — same as $(dg restore)"
  key "$(dg pr) (landed)" "open the highlighted landed row's PR in the browser$(dn pr)"
  key "$(dg reload)" "refresh now$(dn reload)"
  key "?" "this cheatsheet — on an EMPTY prompt line (with text typed, ? is just a character)"
  key "esc" "relaunch the dash (it's the always-on hub pane)"
  fi

  if want backlog; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel backlog env 2>/dev/null)"
  group "backlog" "— inside prefix b"
  key "space" "toggle the preview pane (body/labels/comments) — off by default"
  key "/" "filter issues (type to narrow; off by default)"
  key "enter" "work the issue — spawn its session"
  key "$(dg new)" "file a new issue$(dn new)"
  key "$(dg close)" "close the highlighted issue (y/n confirm)$(dn close)"
  key "$(dg priority)" "cycle the issue's priority label (none→p2→p1→p0→none)$(dn priority)"
  key "$(dg open)" "open the issue on the web$(dn open)"
  key "$(dg reload)" "refresh now$(dn reload)"
  key "?" "this cheatsheet"
  key "esc" "close"
  fi

  if want config; then
  eval "$(bash "$BIN/dash-keymap.sh" --panel config env 2>/dev/null)"
  group "config modal" "— inside prefix c"
  key "enter" "edit the highlighted key / expand the section"
  key "tab" "expand/collapse a section"
  key "$(dg scope)" "toggle the write scope (global ⇄ per-fleet)$(dn scope)"
  key "space / $(dg preview)" "toggle the detail preview$(dn preview)"
  key "?" "reveal the raw FLEET_* keys inline"
  key "$(dg reload)" "refresh now$(dn reload)"
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
