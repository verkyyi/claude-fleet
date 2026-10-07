#!/bin/bash
# fleet-reap-policy.sh — read or change WHEN the fleet may close a session on its
# own (issue #1902): the window option @reap_policy, chosen at spawn
# (dash-issue-session.sh / dash-raw-session.sh --reap), changed later here — by
# the session itself (the fleet tool `set_reap`), the sidebar's 「改回收方式…」, or
# a person's shell.
#
#   fleet-reap-policy.sh set <policy> [--win <@id> --session <sess>]
#       merged[:<dur>] | done[:<dur>] | loop-end | at:<ISO|HH:MM|epoch> | keep
#       (dur: 90 · 30m · 2h · 3d). No --win = the calling pane's OWN window
#       (fleet_pane_fmt — never "the pane the operator is looking at").
#       Prints `reap_policy=<canonical> · <label>`; exit 2 = not a policy,
#       1 = no window.
#   fleet-reap-policy.sh get [--win <@id> --session <sess>]
#       the stamped policy, or `default` when none is (the kind decides).
#   fleet-reap-policy.sh menu <sess> <@id> [<client>]
#       the sidebar menu's submenu: the five choices, the current one marked.
#
# Grammar and words live in ONE place, bin/fleet_reap_policy.py. The closing
# itself is the cleanup tick's (fleet-cleanup-idle.py / fleet-cleanup.sh), through
# the gates every automatic close goes through.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-reap-policy: %s\n' "$2" >&2; exit "$1"; }
sub=${1:-}; [ "$#" -gt 0 ] && shift

# _tm <args…> — on the fleet's own socket when the caller has no $TMUX (a daemon,
# a person's shell naming --session), else the inherited one.
SESS=''; WIN=''
_tm() {
  if [ -z "${TMUX:-}" ] && [ -n "$SESS" ]; then tmux -L "$(fleet_socket "$SESS")" "$@"
  else tmux "$@"; fi
}

resolve_win() {
  if [ -n "$WIN" ]; then
    case "$WIN" in @[0-9]*) ;; *) die 2 "--win takes a window id (@N), never a name or an index" ;; esac
    _tm display-message -p -t "$WIN" '#{window_id}' 2>/dev/null | grep -qx "$WIN" \
      || die 1 "no live window $WIN"
    return 0
  fi
  WIN=$(fleet_pane_fmt '#{window_id}') || WIN=''
  [ -n "$WIN" ] || die 1 "not inside a fleet pane (no \$TMUX_PANE); name --win <@id> --session <sess>"
}

case "$sub" in
  set|get)
    pol=''
    if [ "$sub" = set ]; then pol=${1:-}; [ "$#" -gt 0 ] && shift; fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --win) WIN=${2:-}; shift ;;
        --session) SESS=${2:-}; shift ;;
        *) die 2 "unknown argument $1" ;;
      esac
      shift
    done
    resolve_win
    if [ "$sub" = get ]; then
      cur=$(_tm show-options -wqv -t "$WIN" @reap_policy 2>/dev/null)
      printf '%s\n' "${cur:-default}"
      exit 0
    fi
    canon=$(python3 "$BIN/fleet_reap_policy.py" norm "$pol") || exit 2
    _tm set-option -w -t "$WIN" @reap_policy "$canon" 2>/dev/null || die 1 "could not stamp $WIN"
    # A countdown shown under the old policy no longer holds (fleet_reap_notice).
    for o in @reap_due @reap_seen @reap_state_ts @reap_key @reap_hold; do
      _tm set-option -wu -t "$WIN" "$o" 2>/dev/null
    done
    fleet_hub_nudge
    printf 'reap_policy=%s · %s\n' "$canon" "$(python3 "$BIN/fleet_reap_policy.py" label "$canon")"
    ;;
  menu)
    SESS=${1:-}; WIN=${2:-}; client=${3:-}
    [ -n "$SESS" ] && [ -n "$WIN" ] || die 2 "menu <sess> <@id> [<client>]"
    resolve_win
    . "$BIN/fleet-ui-lang.sh"; fleet_ui_pin
    cur=$(_tm show-options -wqv -t "$WIN" @reap_policy 2>/dev/null)
    self=$(printf '%q' "$BIN/fleet-reap-policy.sh")
    # single quotes inside: the `at` item nests this in command-prompt's "…"
    run() { printf "run-shell -b '%s set %s --win %s --session %s >/dev/null 2>&1 || :'" "$self" "$1" "$WIN" "$(printf '%q' "$SESS")"; }
    margs=(); n=0
    for p in merged done:2h loop-end at keep; do
      n=$((n + 1))
      case "$p" in   # literal keys: fleet-ui-lang-selftest reads them off the code
        merged) lbl=$(fleet_ui_t reap_menu_merged) ;;
        done:2h) lbl=$(fleet_ui_t reap_menu_done_2h) ;;
        loop-end) lbl=$(fleet_ui_t reap_menu_loop_end) ;;
        at) lbl=$(fleet_ui_t reap_menu_at) ;;
        *) lbl=$(fleet_ui_t reap_menu_keep) ;;
      esac
      [ -n "$cur" ] && [ "${cur%%:*}" = "${p%%:*}" ] && lbl="● $lbl"
      if [ "$p" = at ]; then
        cmd="command-prompt -p \"$(fleet_ui_t reap_menu_at_prompt)\" \"$(run 'at:%%')\""
      else cmd=$(run "$p"); fi
      margs+=("$lbl" "$n" "$cmd")
    done
    if [ "${4:-}" = --print ]; then
      i=0; while [ "$i" -lt "${#margs[@]}" ]; do printf '%s\t%s\t%s\n' "${margs[$((i+1))]}" "${margs[$i]}" "${margs[$((i+2))]}"; i=$((i+3)); done
      exit 0
    fi
    _tm display-menu ${client:+-c "$client"} -T "#[align=centre] $(fleet_ui_t reap_menu_title) " -x P -y P -- \
      ${margs[@]+"${margs[@]}"} 2>/dev/null || :
    ;;
  -h|--help|'') sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; [ -n "$sub" ] || exit 2 ;;
  *) die 2 "unknown subcommand $sub (set | get | menu)" ;;
esac
