#!/bin/bash
# fleet-task-pick.sh — the task bar as a POPUP, for a window that has no task bar
# on screen (issue #902, EPIC #894 R2).
#
# The task bar hides itself below ~111 columns (an iPad in portrait, a split, a
# small window) and the operator can switch it off (prefix e). Without it, the
# only way to change task was the trip back to the hub. This opens the SAME list
# the bar draws — `tmux-dashboard-rows.sh --sidebar`: the hub's order, pins and
# folds, panels (hub/backlog) never listed — in an fzf popup:
#
#   ↵ on a row          switch to that task (select-window by its stable @id)
#   ↵ on no match       start a scratch session named after the typed text
#   ⌃s (the dash's      start a scratch session named after the typed text (empty
#     `scratch` key)      ⇒ unnamed) — the hub's ⌃s / the bar's input line: same
#                         script, `--origin hub`, focus follows the new window
#   F9                  go on to the hub (the second press of ⌂/F9, as on the bar)
#   esc                 close
#   [＋ new] [⌂ hub] [✕ close]   the same three as taps (iPad / Termius)
#
# Who opens it:
#   prefix Space        always (conf/tmux-attention.conf)
#   ⌂ tap / F9          in a task with NO task bar on screen — the "no bar" branch
#                       of C4's task-bar-first (hub-zoom.sh, FLEET_HOME_SIDEBAR_FIRST;
#                       0 turns both off). A zoomed task keeps going home.
#
# Usage:
#   fleet-task-pick.sh --popup [--session S] [--client C] [--cause home|f9|key]
#       Open the picker as a popup on client C and act on the pick once it
#       closes. Brackets the popup with the @popup_open epoch (#308/#431) and
#       clears it on every exit path. Exit 3 = the popup never ran (no client,
#       or another overlay is up) — nothing was shown, nothing was done.
#   fleet-task-pick.sh [--session S] [--current @id] [--out FILE]
#       The picker itself (what runs inside the popup). Writes ONE action line to
#       FILE — `select <@id>` · `scratch <name>` · `hub` — or nothing on cancel.
#       Without --out it performs the action itself (run inline in a pane).
#
# Every action is taken OUTSIDE the popup, by the --popup parent, once the
# overlay is gone: a select-window under a live popup would repaint beneath it,
# and a spawn's focus switch would race the popup's teardown.
#
# Bare `tmux` on purpose: run from a binding or a pane it inherits $TMUX and so
# targets THIS fleet's socket (issue #159).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"

POPUP=0 SESS='' CLIENT='' CAUSE=key CURRENT='' OUT=''
while [ $# -gt 0 ]; do
  case "$1" in
    --popup)   POPUP=1 ;;
    --session) SESS="${2:-}"; shift ;;
    --client)  CLIENT="${2:-}"; shift ;;
    --cause)   CAUSE="${2:-key}"; shift ;;
    --current) CURRENT="${2:-}"; shift ;;
    --out)     OUT="${2:-}"; shift ;;
    *) printf 'fleet-task-pick.sh: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# tmux display-message on the pressing client when we know it: without -c a
# command from a run-shell job has no client of its own and would guess.
tdm() { tmux display-message ${CLIENT:+-c "$CLIENT"} -p "$1" 2>/dev/null; }
[ -n "$SESS" ] || SESS=$(tdm '#{session_name}')
[ -n "$SESS" ] || { printf 'fleet-task-pick.sh: not inside a tmux session\n' >&2; exit 1; }

# act <action line> — the one place a pick turns into a tmux change.
act() {
  local verb="${1%% *}" arg=''
  case "$1" in *' '*) arg="${1#* }" ;; esac
  case "$verb" in
    select)
      case "$arg" in @[0-9]*) ;; *) return 0 ;; esac   # window ids only, never a name/index
      tmux select-window -t "$arg" 2>/dev/null || :
      ;;
    scratch)
      # The bar's input line and the hub's ⌃s: one script, hub provenance (a
      # session started here is not the current worker's child), focus follows.
      FLEET_SPAWN_FOCUS=1 bash "$BIN/dash-raw-session.sh" --bg ${arg:+--name "$arg"} \
        --origin hub "$SESS" >/dev/null 2>&1 || :
      ;;
    hub)
      local home=''; [ "$CAUSE" = home ] && home=--home
      bash "$BIN/hub-zoom.sh" --nav $home ${CLIENT:+--client "$CLIENT"} >/dev/null 2>&1 || :
      ;;
  esac
  return 0
}

if [ "$POPUP" = 1 ]; then
  cur=$(tdm '#{window_id}')
  res=$(mktemp "${TMPDIR:-/tmp}/fleet-task-pick.XXXXXX") || exit 0
  trap 'rm -f "$res" "$res.ran"; tmux set -g @popup_open 0 2>/dev/null' EXIT
  trap 'exit 130' INT TERM HUP
  from=$(tdm '#{?#{@wid},#{@wid},#{window_id}}')
  tmux set -g @popup_open "$(date +%s)" 2>/dev/null || :
  tmux display-popup ${CLIENT:+-c "$CLIENT"} -E -w 90% -h 80% -T ' tasks ' \
    "$(printf '%q ' bash "$BIN/fleet-task-pick.sh" --session "$SESS" --current "$cur" --out "$res")" \
    2>/dev/null || :
  tmux set -g @popup_open 0 2>/dev/null || :
  # display-popup exits 0 whether or not it drew anything (no client, another
  # overlay already up — see dash-popup.sh, issue #454), so the picker's first
  # act is to drop `$res.ran`. No marker ⇒ it never ran ⇒ exit 3, and the caller
  # (hub-zoom.sh) takes the old jump instead of leaving a dead key.
  [ -e "$res.ran" ] || exit 3
  # The meter (issue #897): a ⌂/F9 that opened this instead of the hub is a trip
  # that did NOT happen — recorded like C4's `*-sidebar` landings.
  case "$CAUSE" in
    home|f9) bash "$BIN/fleet-hub-visits.sh" record '' "$SESS" "$CAUSE-pick" "$from" '' >/dev/null 2>&1 || : ;;
  esac
  # The action line carries no trailing newline: read returns 1 on it, so the
  # line is taken whatever read's status.
  line=''; IFS= read -r line < "$res" 2>/dev/null || :
  [ -n "$line" ] && act "$line"
  exit 0
fi

# ---- the picker ----------------------------------------------------------------
[ -n "$OUT" ] && : > "$OUT.ran"   # proof for the --popup parent that the popup ran
[ -n "$CURRENT" ] || CURRENT=$(tdm '#{window_id}')
eval "$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)"   # $DASH_KEY_SCRATCH / glyph (#556)
: "${DASH_KEY_SCRATCH:=ctrl-s}" "${DASH_GLYPH_SCRATCH:=⌃s}"

US=$'\037'
rows=$(FLEET_SESSION="$SESS" FLEET_SIDEBAR_CURRENT="$CURRENT" \
         bash "$BIN/tmux-dashboard-rows.sh" --sidebar 2>/dev/null) || rows=''
# wid US state US glyph US label US tree  →  `wid<TAB>▶ glyph tree label`
list=''
while IFS="$US" read -r wid _state glyph label tree; do
  case "$wid" in @*) ;; *) continue ;; esac
  mark=' '; [ "$wid" = "$CURRENT" ] && mark='▶'
  list+="$wid	$mark ${glyph:- } ${tree:- } $label"$'\n'
done <<EOF
$rows
EOF

act_file="$OUT"
[ -n "$act_file" ] || { act_file=$(mktemp "${TMPDIR:-/tmp}/fleet-task-pick.XXXXXX") || exit 0; }
: > "$act_file"
qf=$(printf '%q' "$act_file")

# Two lines, the tap chips FIRST: this popup exists for narrow screens, where one
# long line would clip the chips — the only path an iPad has to ⌃s / F9.
hdr="[＋ new] [⌂ hub] [✕ close]"$'\n'"↵ switch · name + ${DASH_GLYPH_SCRATCH} or ↵ = new session · F9 hub"
out=$(printf '%s' "$list" | fzf --ansi --no-sort --layout=reverse-list --info=hidden \
        --border=rounded --height=100% --delimiter='	' --with-nth=2.. \
        --print-query --prompt='task ▸ ' --header="$hdr" \
        --bind "$DASH_KEY_SCRATCH:execute-silent(printf 'scratch %s' {q} > $qf)+abort" \
        --bind "f9:execute-silent(printf hub > $qf)+abort" \
        --bind "click-header:transform:case \"\$FZF_CLICK_HEADER_WORD\" in *＋*|*new*) printf 'scratch %s' {q} > $qf; echo abort ;; *⌂*|*hub*) printf hub > $qf; echo abort ;; *✕*|*close*) echo abort ;; esac")
query=$(printf '%s\n' "$out" | sed -n 1p)
pick=$(printf '%s\n' "$out" | sed -n 2p)
if [ ! -s "$act_file" ]; then
  if [ -n "$pick" ]; then
    printf 'select %s' "${pick%%	*}" > "$act_file"
  elif [ -n "$query" ]; then
    printf 'scratch %s' "$query" > "$act_file"
  fi
fi
if [ -z "$OUT" ]; then
  line=''; IFS= read -r line < "$act_file" 2>/dev/null || :
  rm -f "$act_file"
  [ -n "$line" ] && act "$line"
fi
exit 0
