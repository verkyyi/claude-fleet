#!/bin/bash
# account-pick.sh — popup picker to switch the ACTIVE subscription account (the
# one fleet sessions launch under, via bin/fleet-claude.sh). Enter selects, Esc
# cancels. Run inside `tmux display-popup -E`. No-op when multi-account is off
# (no token files). New spawns pick up the switch at launch; IDLE running
# sessions (done/needs) are restarted in place with `--continue` so they resume
# their transcript under the new account; mid-turn (working) and looping sessions
# keep their old account until their next restart. If you pick a currently-limited
# account, `active` still rotates past it at spawn time so sessions don't launch
# on a walled account.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

# _ap_restart_eligible <name> <state> <raw> — 0 iff this window is an idle,
# issue-bound Claude worker we can safely restart in place (issue #263):
#   • skip the hub/backlog PANELS by name (dash/plan/backlog) — the steward lives
#     in the `plan` hub, so this also leaves the steward alone;
#   • skip @raw scratch sessions — they share FLEET_MAIN as their cwd, so a
#     `--continue` there can't reliably resolve WHICH transcript to resume (issue
#     #214); they are ephemeral anyway and a fresh `prefix R` uses the new account;
#   • skip non-Claude windows (no @claude_state);
#   • restart ONLY the idle states done/needs — a `working` window is mid-turn and
#     a `looping` window is between /loop iterations; interrupting either is worse
#     than letting it move accounts on its next natural restart.
# Kept pure + sourceable so account-pick-selftest.sh can pin the matrix.
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

# Sourced by account-pick-selftest.sh → define the helpers WITHOUT opening fzf or
# touching account state. Only a direct run drops into the interactive picker.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then

listing=$(bash "$BIN/fleet-account.sh" list 2>/dev/null)
case "$listing" in
  *OFF*|'') printf '%s\n\n(no accounts registered — see docs/MULTI-ACCOUNT.md)\n' "$listing"; sleep 2.5; exit 0;;
esac

# --- Machine-wide window usage header (aggregate, NOT per-account — one shared
# ~/.claude, so transcripts can't be attributed to an OAuth account). The 5h/7d
# proxy + the official weekly/N-hour % (fresh-gated) come from usage-lib.sh, the
# same shared reader the footer colors and the usage popup (prefix+u) render, so
# this header can't drift from them. Empty when neither cache has anything. ---
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"
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
  # account restarts nothing.
  if [ -n "$now" ] && [ "$now" != "$prev" ]; then
    n=$(restart_idle_claude_windows)
    [ "${n:-0}" -gt 0 ] && msg="${msg}  ·  restarted ${n} idle session$([ "$n" = 1 ] || printf s)"
  fi
  tmux display-message "$msg"
fi

fi
