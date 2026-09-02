#!/bin/bash
# usage-modal.sh — the consolidated Claude usage + subscription-account modal
# (issue #289; merges the old usage-popup.sh + account-pick.sh into ONE surface).
# Opened by clicking the footer usage stat OR the ◉ account chip
# (MouseDown1Status in conf/tmux-attention.conf) — there is no keyboard path any
# more (prefix A/u were dropped in the shortcut prune). It shows:
#   • usage DETAIL as the header — the local 5h/7d proxy + the official
#     weekly/N-hour limit line (which limit + reset), read via usage-lib.sh — the
#     SAME shared reader that colors the footer, so they can't drift;
#   • the account POOL as the selectable body — Enter switches the account new
#     sessions launch under (via bin/fleet-claude.sh) AND restarts this fleet's
#     IDLE Claude windows in place with `--continue` so they resume their
#     transcript on the new account (issue #263); mid-turn (working) and looping
#     sessions keep their old account until their next restart; Esc cancels.
#     Picking a currently-limited account still rotates past it at spawn time.
# On a SINGLE-account install (no token files) there is no pool to pick: it shows
# the usage detail only + a pointer to register accounts, and holds for a key.
# Run inside `tmux display-popup -E`.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"

# --- colours (Tokyo Night; honour NO_COLOR + non-tty) -------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  UB=$'\033[1m'; UDIM=$'\033[38;2;86;95;137m'; UR=$'\033[0m'
  URED=$'\033[38;2;247;118;142m'; UYEL=$'\033[38;2;224;175;104m'
  UGRN=$'\033[38;2;158;206;106m'; UIND=$'\033[38;2;187;154;247m'
else
  UB=""; UDIM=""; UR=""; URED=""; UYEL=""; UGRN=""; UIND=""
fi

# Colour + one-word gloss for a severity token (shared shape with the footer).
_um_sev_color() { case "$1" in crit) printf '%s' "$URED";; warn) printf '%s' "$UYEL";; *) printf '%s' "$UGRN";; esac; }
_um_sev_word()  { case "$1" in crit) echo "at/near limit";; warn) echo "approaching limit";; *) echo "ok";; esac; }
_um_row()       { printf '  %s%-13s%s %s\n' "$UDIM" "$1" "$UR" "$2"; }

# render_usage_detail — the usage/limit header: the local 5h/7d proxy row + the
# official weekly/N-hour limit row (which limit + reset, colored by severity).
# The single source is usage-lib.sh (same reader the footer + account body use).
# This is the modal's whole body on a single-account install and its header text
# on a multi-account one.
render_usage_detail() {
  local proxy rl pct line sev
  printf '\n  %s%sClaude usage%s %s— this machine (one shared ~/.claude)%s\n\n' "$UB" "$UIND" "$UR" "$UDIM" "$UR"
  proxy=$(fleet_usage_proxy)
  if [ -n "$proxy" ]; then _um_row "rolling" "${proxy}"
  else _um_row "rolling" "${UDIM}no usage proxy yet (collector hasn't run)${UR}"; fi
  rl=$(fleet_usage_ratelimit)
  if [ -n "$rl" ]; then
    pct="${rl%%$'\t'*}"; line="${rl#*$'\t'}"
    sev=$(fleet_usage_severity "$pct")
    _um_row "limit" "$(_um_sev_color "$sev")${line}${UR}   ${UDIM}[$(_um_sev_word "$sev")]${UR}"
  else
    _um_row "limit" "${UDIM}no official limit signal in the last $(( ${FLEET_RATELIMIT_TTL:-21600} / 3600 ))h${UR}"
  fi
}

# _ap_restart_eligible <name> <state> <raw> — 0 iff this window is an idle,
# issue-bound Claude worker we can safely restart in place (issue #263):
#   • skip the hub/backlog PANELS by name (dash/plan/backlog) — the operator pane
#     lives in the `plan` hub, so this also leaves the hub alone;
#   • skip @raw scratch sessions — they share FLEET_MAIN as their cwd, so a
#     `--continue` there can't reliably resolve WHICH transcript to resume (issue
#     #214); they are ephemeral anyway and a fresh dash `⌃s` uses the new account;
#   • skip non-Claude windows (no @claude_state);
#   • restart ONLY the idle states done/needs — a `working` window is mid-turn and
#     a `looping` window is between /loop iterations; interrupting either is worse
#     than letting it move accounts on its next natural restart.
# Kept pure + sourceable so usage-modal-selftest.sh can pin the matrix.
_ap_restart_eligible() {
  local name="$1" state="$2" raw="$3"
  case "$name" in dash|plan|backlog) return 1;; esac
  [ "$raw" = "1" ] && return 1
  case "$state" in done|needs) return 0;; *) return 1;; esac
}

# _ap_pane_claude_pid <wid> — pid of the Claude process running under the window's
# pane (any descendant of pane_pid whose command is `claude`, or a node/bun that
# runs the npm-installed cli), or nothing. THIS is the exit gate (issue #511):
# `pane_current_command` reads the `zsh -c` runner (`zsh`) for the whole life of a
# session on macOS, so it said "shell" while Claude was alive and the relaunch line
# went into the prompt as an LLM turn. Portable: `ps -axo` on macOS + Linux.
_ap_pane_claude_pid() {
  local pp ps p c kids seen=" "
  pp=$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null) || return 1
  [ -n "$pp" ] || return 1
  ps=$(ps -axo pid=,ppid=,comm=) || return 1
  set -- "$pp"
  while [ $# -gt 0 ]; do
    p=$1; shift
    case "$seen" in *" $p "*) continue;; esac; seen="$seen$p "
    c=$(printf '%s\n' "$ps" | awk -v p="$p" '$1==p{print $3}')
    case "${c##*/}" in
      claude) printf '%s\n' "$p"; return 0;;
      node|node[0-9]*|bun)
        case " $(ps -o command= -p "$p" 2>/dev/null) " in
          *"claude-code/cli.js"*|*"/claude "*) printf '%s\n' "$p"; return 0;;
        esac;;
    esac
    kids=$(printf '%s\n' "$ps" | awk -v p="$p" '$2==p{print $1}')
    # shellcheck disable=SC2086  # deliberate word-split: one pid per word
    set -- "$@" $kids
  done
  return 1
}

# _ap_restart_window <wid> [nudge] — exit the live Claude TUI in ONE window and
# relaunch it under the now-active account. A running `claude` baked its OAuth
# token in at launch and cannot rotate in place, so the only way to move it is a
# restart; `fleet-claude.sh --continue` re-exports the fresh token, re-stamps
# @cc_account (collector attribution), applies the fleet model flag, and resumes
# the pane's most-recent transcript from its cwd. An optional <nudge> rides along
# as the resumed session's first prompt (fleet-restore.sh's interrupted-turn
# pattern) — keep it apostrophe-free, it is single-quoted into the typed command.
# Returns 0 iff the relaunch was typed.
_ap_restart_window() {
  local wid="$1" nudge="${2:-}" alive=1
  # Double ctrl-c exits the Claude TUI (it needs two); harmless if the pane is
  # already sitting at a shell.
  # FLEET_ALLOW_SENDKEYS=1: sanctioned auto-continue plumbing (issue #437),
  # prefixed (not exported) so the resumed pane never inherits the hatch.
  FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$wid" C-c 2>/dev/null || return 1
  FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$wid" C-c 2>/dev/null

  # Wait (up to ~3s) for the pane's Claude to actually be GONE before typing
  # (issue #511). If it is still there — the "Usage limit reached · continuing
  # automatically" wait swallows both ctrl-c, a modal dialog does too — SKIP:
  # typing here would land in the still-live Claude as an LLM turn. If the window
  # itself is gone (session-end-hook.sh kill-windows on exit), there is nothing to
  # type into either — also a skip.
  for _ in $(seq 1 10); do
    tmux display-message -p -t "$wid" '#{pane_pid}' >/dev/null 2>&1 || return 1
    if _ap_pane_claude_pid "$wid" >/dev/null; then sleep 0.3; else alive=0; break; fi
  done
  [ "$alive" = 0 ] || return 1
  tmux display-message -p -t "$wid" '#{pane_pid}' >/dev/null 2>&1 || return 1

  # Drop the scrollback BEFORE relaunching (issue #495): the pane's history may
  # still hold the "hit your … limit" banner that benched the OLD account. The
  # relaunch re-stamps @cc_account to the NEW label, and the collector reads
  # banners out of scrollback — leave it and the stale banner gets attributed to
  # the fresh account, benching it too (a false cascade through the whole pool).
  tmux clear-history -t "$wid" 2>/dev/null || true

  # Text and Enter as SEPARATE send-keys calls (an inline Enter gets eaten by
  # bracketed paste). Re-wrap with `; exec $SHELL` so the pane survives a later
  # Claude exit, exactly like the original spawn (dash-issue-session.sh).
  FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$wid" "'$BIN/fleet-claude.sh' --continue${nudge:+ '$nudge'}; exec \$SHELL" 2>/dev/null
  FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t "$wid" Enter 2>/dev/null
}

# restart_idle_claude_windows [skip_wid] [skip_acct] — _ap_restart_window every
# eligible window in THIS fleet's session. Prints the number of windows it
# restarted. bare `tmux` inherits $TMUX → this fleet's own socket (issue #159),
# and `list-windows` (no -a) stays scoped to this session. skip_wid drops a
# window something else already restarted (the banner window in the
# --restart-after-rotate pass); skip_acct drops windows whose @cc_account is
# ALREADY the target label — restarting those is pure churn.
restart_idle_claude_windows() {
  local skip_wid="${1:-}" skip_acct="${2:-}" wid name state raw acct restarted=0
  while IFS=$'\t' read -r wid name state raw acct; do
    [ -n "$wid" ] || continue
    [ -n "$skip_wid" ] && [ "$wid" = "$skip_wid" ] && continue
    [ -n "$skip_acct" ] && [ "$acct" = "$skip_acct" ] && continue
    _ap_restart_eligible "$name" "$state" "$raw" || continue
    _ap_restart_window "$wid" || continue
    restarted=$((restarted + 1))
  done < <(
    # Real tab separators via $'\t' (tmux does NOT expand a literal \t in -F).
    # Tab is IFS *whitespace*, so `read` COLLAPSES consecutive tabs — an empty
    # middle field shifts every later one left. Hence sentinels for the fields
    # that can be unset: state '-' (never done/needs → skipped) and raw '0'
    # (never "1" → not raw); @cc_account stays last, where empty is safe.
    tmux list-windows -F \
      "#{window_id}"$'\t'"#{window_name}"$'\t'"#{?@claude_state,#{@claude_state},-}"$'\t'"#{?@raw,#{@raw},0}"$'\t'"#{@cc_account}" 2>/dev/null
  )
  printf '%s' "$restarted"
}

# Sourced by usage-modal-selftest.sh → define the helpers WITHOUT opening fzf or
# touching account state. Only a direct run drops into the interactive picker.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then

# Internal --restart-idle (issue #304): the BACKGROUND restart pass the account
# picker dispatches via `run-shell -b` (the fleet's non-blocking-bind convention,
# same as fleet_bg) so the popup CLOSES INSTANTLY instead of blocking on the
# per-idle-window ctrl-c + up-to-3s settle loop — which scales with the # of idle
# windows. Re-uses this file's restart_idle_claude_windows and toasts its OWN count
# (the popup is gone by the time it runs). $TMUX is inherited from the run-shell
# job, so restart's bare tmux calls stay on THIS fleet's server.
if [ "${1:-}" = "--restart-idle" ]; then
  # Optional $2 = the new active label: windows already stamped with it are skipped.
  n=$(restart_idle_claude_windows "" "${2:-}")
  [ "${n:-0}" -gt 0 ] && tmux display-message "fleet: restarted ${n} idle session$([ "$n" = 1 ] || printf s) on the new account"
  exit 0
fi

# Internal --restart-after-rotate <wid> <new-label> (issue #495): the background
# pass the COLLECTOR dispatches when a limit banner auto-rotates the active
# account (tmux-dash-collect.sh, mark-limited exit 10) — running sessions cannot
# hot-swap their token (apiKeyHelper only carries API-key credentials, not
# subscription OAuth tokens; verified empirically on #495), so following the
# rotation means restarting them. Two steps:
#   1. the BANNER window itself — the window that hit the limit. Its turn is
#      already dead (every request on the benched account fails until reset), so
#      the idle-only gate does not apply: restart it even in `working` state,
#      with a nudge so the resumed session re-orients and continues on its own.
#      Panels (dash/plan/backlog) and @raw scratch sessions still never restart
#      (same reasons as _ap_restart_eligible — @raw cwd can't resolve --continue).
#   2. the usual idle pass — minus that window (just restarted) and minus
#      windows already stamped with the new label (nothing to move).
if [ "${1:-}" = "--restart-after-rotate" ]; then
  wid="${2:-}"; newacct="${3:-}"; bumped=0
  if [ -n "$wid" ]; then
    name=$(tmux display-message -p -t "$wid" '#{window_name}' 2>/dev/null)
    raw=$(tmux display-message -p -t "$wid" '#{?@raw,#{@raw},}' 2>/dev/null)
    case "$name" in
      dash|plan|backlog|'') : ;;
      *) if [ "$raw" != "1" ]; then
           nudge="This session hit its subscription account usage limit mid-turn; the fleet rotated to a fresh account and restarted you here with --continue. Re-check git status, your branch, and your PR to see where the interrupted turn left off, then continue the task — or just stop if it is already complete."
           _ap_restart_window "$wid" "$nudge" && bumped=1
         fi ;;
    esac
  fi
  n=$(restart_idle_claude_windows "$wid" "$newacct")
  total=$(( ${n:-0} + bumped ))
  [ "$total" -gt 0 ] && tmux display-message "fleet: moved ${total} running session$([ "$total" = 1 ] || printf s) onto ${newacct:-the new account} (--continue)"
  exit 0
fi

listing=$(bash "$BIN/fleet-account.sh" list 2>/dev/null)
case "$listing" in
  *OFF*|'')
    # SINGLE-account install (no token files): there's no pool to pick, so show
    # the usage/limit detail on its own + a pointer to register accounts, and hold
    # for a key — a read-only usage popup (issue #289 folded the old usage-popup
    # here). NB no `--summary` consumer remains, so that mode was dropped.
    render_usage_detail
    printf '\n  %sregister accounts to switch here — see docs/MULTI-ACCOUNT.md%s\n' "$UDIM" "$UR"
    printf '  %spress any key to close%s\n' "$UDIM" "$UR"
    IFS= read -rsn1 _ 2>/dev/null || true
    exit 0 ;;
esac

# --- MULTI-account: usage/limit DETAIL as the header, the account pool as the
# selectable body. The 5h/7d proxy + the official weekly/N-hour % (fresh-gated)
# come from usage-lib.sh, the same shared reader the footer colors and the
# single-account branch above renders, so the header can't drift. Empty when
# neither cache has anything. ---
usg=$(fleet_usage_summary_plain)

active=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
hdr="switch the account fleet sessions use  ·  enter=select · esc=cancel · [✕ close]   [now: ${active}]"
[ -n "$usg" ] && hdr="${usg}"$'\n'"${hdr}"

# --header-lines=1 pins the table's column-title row (line 1 of `list`) so it
# stays aligned with the data rows and out of the selectable set; the usage
# summary rides above it via --header. Data rows lead with the bare label, so
# `awk '{print $1}'` recovers the pick even with the trailing ANSI in STATE.
# The `[✕ close]` button chip in $hdr + the click-header bind add an iPad/Termius
# tap-to-dismiss where Escape is a reach (issue #346): tapping ✕/close aborts fzf
# → empty pick → exit. Bracketed as a button (issue #381), so the clicked word is
# `[✕` or `close]` — the case globs *✕*|*close*. The pinned column-title row
# carries no ✕/close, so a tap there never fires the bind.
pick=$(printf '%s\n' "$listing" \
  | fzf --ansi --no-sort --layout=reverse --height=100% --header-lines=1 \
        --prompt='active account ▸ ' \
        --header="$hdr" \
        --bind 'click-header:transform:case "$FZF_CLICK_HEADER_WORD" in *✕*|*close*) echo abort ;; esac' \
  | awk '{print $1}')

[ -n "$pick" ] || exit 0
prev="$active"
if bash "$BIN/fleet-account.sh" use "$pick" >/dev/null 2>&1; then
  now=$(bash "$BIN/fleet-account.sh" active 2>/dev/null)
  if [ "$now" = "$pick" ]; then
    msg="fleet: new sessions now use  ${pick}"
  else
    msg="fleet: ${pick} is limited — new sessions use  ${now}"
  fi
  # Move this fleet's IDLE running sessions onto the new account too (issue #263),
  # but only when the active account actually changed — a re-pick of the current
  # account restarts nothing. Background the restarts (issue #304): the ctrl-c +
  # up-to-3s settle loop scales with the # of idle windows and would otherwise hold
  # the popup OPEN. run-shell -b returns instantly; the bg job toasts its own count.
  if [ -n "$now" ] && [ "$now" != "$prev" ]; then
    tmux run-shell -b "bash '$0' --restart-idle '$now'"
    msg="${msg}  ·  restarting idle sessions…"
  fi
  tmux display-message "$msg"
fi

fi
