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
#   • skip the hub/backlog PANELS by name (dash/plan/backlog) — the steward lives
#     in the `plan` hub, so this also leaves the steward alone;
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

# restart_idle_claude_windows — for every eligible window in THIS fleet's session,
# exit its live Claude TUI and relaunch it under the now-active account. A running
# `claude` baked its OAuth token in at launch and cannot rotate in place, so the
# only way to move it is a restart; `fleet-claude.sh --continue` re-exports the
# fresh token, re-stamps @cc_account (collector attribution), applies the fleet
# model flag, and resumes the pane's most-recent transcript from its cwd. Prints
# the number of windows it restarted. bare `tmux` inherits $TMUX → this fleet's
# own socket (issue #159), and `list-windows` (no -a) stays scoped to this session.
restart_idle_claude_windows() {
  local wid name state raw cmd restarted=0
  while IFS=$'\t' read -r wid name state raw; do
    [ -n "$wid" ] || continue
    _ap_restart_eligible "$name" "$state" "$raw" || continue

    # Double ctrl-c exits the Claude TUI (it needs two); harmless if the pane is
    # already sitting at a shell.
    tmux send-keys -t "$wid" C-c 2>/dev/null || continue
    tmux send-keys -t "$wid" C-c 2>/dev/null

    # Wait (up to ~3s) for the pane to drop to its shell (spawns end with
    # `; exec $SHELL`) before typing. If it never reaches a shell — e.g. a modal
    # dialog swallowed the ctrl-c — SKIP: typing here would land in the still-live
    # Claude as an LLM turn.
    cmd=""
    for _ in $(seq 1 10); do
      cmd=$(tmux display-message -p -t "$wid" '#{pane_current_command}' 2>/dev/null)
      case "$cmd" in *zsh|*bash|sh|dash|fish) break;; esac
      sleep 0.3
    done
    case "$cmd" in *zsh|*bash|sh|dash|fish) ;; *) continue;; esac

    # Text and Enter as SEPARATE send-keys calls (an inline Enter gets eaten by
    # bracketed paste). Re-wrap with `; exec $SHELL` so the pane survives a later
    # Claude exit, exactly like the original spawn (dash-issue-session.sh).
    tmux send-keys -t "$wid" "'$BIN/fleet-claude.sh' --continue; exec \$SHELL" 2>/dev/null
    tmux send-keys -t "$wid" Enter 2>/dev/null
    restarted=$((restarted + 1))
  done < <(
    # Real tab separators via $'\t' (tmux does NOT expand a literal \t in -F).
    tmux list-windows -F \
      "#{window_id}"$'\t'"#{window_name}"$'\t'"#{@claude_state}"$'\t'"#{?@raw,#{@raw},}" 2>/dev/null
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
  n=$(restart_idle_claude_windows)
  [ "${n:-0}" -gt 0 ] && tmux display-message "fleet: restarted ${n} idle session$([ "$n" = 1 ] || printf s) on the new account"
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
hdr="switch the account fleet sessions use  ·  enter=select · esc=cancel   [now: ${active}]"
[ -n "$usg" ] && hdr="${usg}"$'\n'"${hdr}"

# --header-lines=1 pins the table's column-title row (line 1 of `list`) so it
# stays aligned with the data rows and out of the selectable set; the usage
# summary rides above it via --header. Data rows lead with the bare label, so
# `awk '{print $1}'` recovers the pick even with the trailing ANSI in STATE.
pick=$(printf '%s\n' "$listing" \
  | fzf --ansi --no-sort --layout=reverse --height=100% --header-lines=1 \
        --prompt='active account ▸ ' \
        --header="$hdr" \
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
    tmux run-shell -b "bash '$0' --restart-idle"
    msg="${msg}  ·  restarting idle sessions…"
  fi
  tmux display-message "$msg"
fi

fi
