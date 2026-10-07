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
#   prefix Space        always — until issue #1714 moved the person's keys to the
#                       client (conf/tmux-shell.conf), whose Space focuses its list
#   ⌂ tap / F9          in a task with NO task bar on screen — the "no bar" branch
#                       of C4's task-bar-first (hub-zoom.sh, FLEET_HOME_SIDEBAR_FIRST;
#                       0 turns both off). A zoomed task keeps going home.
#
# Usage:
#   fleet-task-pick.sh --popup [--session S] [--client C] [--cause home|f9|bar|key]
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
. "$BIN/fleet-trace-lib.sh"   # the ⌂ latency trace (issue #1611): no-op unless hub-zoom.sh started one

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
[ -n "$SESS" ] || SESS=$(tdm '#{session_name}')   # view-ok: the client shell's own server, never a node's view
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

# keys_env — `dash-keymap.sh env`, cached per tmux prefix pair under the dash
# cache (issue #1611): the resolver is ~25 forks (~70 ms idle, more under load)
# for an answer that changes only with the prefix or the script itself. A test
# seam (FLEET_TMUX_PREFIX*) bypasses the cache, as it bypasses the server.
keys_env() {
  local c="${TMPDIR:-/tmp}/.claude-dash" p f
  if [ -n "${FLEET_TMUX_PREFIX+x}" ] || [ -n "${FLEET_TMUX_PREFIX2+x}" ]; then
    bash "$BIN/dash-keymap.sh" env 2>/dev/null; return 0
  fi
  p=$(tmux show -gv prefix \; show -gv prefix2 2>/dev/null | tr '\n' '_' | tr -c 'A-Za-z0-9_-' '.')
  f="$c/task-pick-keys.${p:-none}"
  if [ -s "$f" ] && [ "$f" -nt "$BIN/dash-keymap.sh" ]; then cat "$f"; return 0; fi
  [ -d "$c" ] || mkdir -p "$c" 2>/dev/null
  { bash "$BIN/dash-keymap.sh" env 2>/dev/null | tee "$f.$$" && mv -f "$f.$$" "$f"; } 2>/dev/null || rm -f "$f.$$"
}

if [ "$POPUP" = 1 ]; then
  cur=$(tdm '#{window_id}|#{?#{@wid},#{@wid},#{window_id}}')   # one read: the window, and its handle for the meter
  from=${cur#*|}; cur=${cur%%|*}
  res=$(mktemp "${TMPDIR:-/tmp}/fleet-task-pick.XXXXXX") || exit 0
  # `wait` first: the two pre-reads below may still be writing when a refused
  # popup exits early, and a file written after its rm would leak.
  trap 'wait; rm -f "$res" "$res".*' EXIT
  trap 'exit 130' INT TERM HUP
  fleet_home_mark pick
  # The list and the keymap are the picker's two big reads (~180 ms + ~70 ms on
  # an idle M-series, more under load — issue #1611). Start both NOW, in the
  # background, so they overlap dash-popup.sh's own work and tmux opening the
  # popup; the picker inside takes the results off `$res.rows` / `$res.keys`
  # instead of recomputing them. Each job rings a FIFO when its file is whole
  # and the picker blocks on that (`read -t`), no polling: both FIFOs stay open
  # here, read-write, for the popup's lifetime, so a job's byte never waits
  # for a reader and sits in the pipe until the picker takes it; a job that
  # outlives a refused popup writes through its own read-write open and exits.
  # The files exist BEFORE the jobs start, so the picker can tell "pre-read,
  # wait for it" (a FIFO beside the file) from "no pre-read, compute".
  : > "$res.rows"; : > "$res.keys"
  mkfifo "$res.rows.done" "$res.keys.done" 2>/dev/null
  exec 8<>"$res.rows.done" 9<>"$res.keys.done"
  { FLEET_SESSION="$SESS" FLEET_SIDEBAR_CURRENT="$cur" \
      bash "$BIN/tmux-dashboard-rows.sh" --sidebar > "$res.rows" 2>/dev/null; printf 'x\n' 1<>"$res.rows.done"; } 8<&- 9<&- &
  { keys_env > "$res.keys" 2>/dev/null; printf 'x\n' 1<>"$res.keys.done"; } 8<&- 9<&- &
  # The one popup frame (issue #1535): dash-popup.sh draws it — size, the
  # 「任务 · 机器 … Esc 关闭」 title row, the @popup_open epoch. --no-inline:
  # this runs from a bind / hub-zoom.sh with no pane of its own to fall back to.
  bash "$BIN/dash-popup.sh" ${CLIENT:+--client "$CLIENT"} --session "$SESS" --no-inline --size L --title popup_tasks -- \
    bash "$BIN/fleet-task-pick.sh" --session "$SESS" --current "$cur" --out "$res" \
    >/dev/null 2>&1 || :
  # the popup command exits 0 whether or not it drew anything (no client, another
  # overlay already up — see dash-popup.sh, issue #454), so the picker's first
  # act is to drop `$res.ran`. No marker ⇒ it never ran ⇒ exit 3, and the caller
  # (hub-zoom.sh) takes the old jump instead of leaving a dead key.
  exec 8<&- 9<&-   # the FIFOs' job is done: a spawn below must not inherit them
  [ -e "$res.ran" ] || exit 3
  fleet_home_end 'done'   # the picker's own marks are in the trace file already
  # The meter (issue #897): a ⌂/F9 that opened this instead of the hub is a trip
  # that did NOT happen — recorded like C4's `*-sidebar` landings; the 4th
  # column is the trace (issue #1611).
  case "$CAUSE" in
    home|f9|bar) bash "$BIN/fleet-hub-visits.sh" record '' "$SESS" "$CAUSE-pick" "$from" '' "$(fleet_home_extra)" >/dev/null 2>&1 || : ;;
  esac
  # The action line carries no trailing newline: read returns 1 on it, so the
  # line is taken whatever read's status.
  line=''; IFS= read -r line < "$res" 2>/dev/null || :
  [ -n "$line" ] && act "$line"
  exit 0
fi

# ---- the picker ----------------------------------------------------------------
[ -n "$OUT" ] && : > "$OUT.ran"   # proof for the --popup parent that the popup ran
fleet_home_mark open
[ -n "$CURRENT" ] || CURRENT=$(tdm '#{window_id}')
# pre_read <file> — a read the --popup parent started before the popup opened
# (issue #1611): print it once the parent's job rings `<file>.done` (a FIFO the
# parent holds open; `read -t` blocks on it, no polling — ≤ 3 s, after which a
# job that never finished — SIGKILLed — leaves rc 1 and the caller computes as
# before). Only a FIFO the parent made counts; the inline picker has none.
pre_read() {
  [ -n "$OUT" ] && [ -p "$1.done" ] || return 1
  local _x
  read -r -t 3 _x 0<>"$1.done" || return 1
  cat "$1"
}
keys=$(pre_read "$OUT.keys") || keys=$(bash "$BIN/dash-keymap.sh" env 2>/dev/null)
eval "$keys"   # $DASH_KEY_SCRATCH / glyph (#556)
: "${DASH_KEY_SCRATCH:=ctrl-s}" "${DASH_GLYPH_SCRATCH:=⌃s}"
fleet_home_mark keys

US=$'\037'
rows=$(pre_read "$OUT.rows") ||
  rows=$(FLEET_SESSION="$SESS" FLEET_SIDEBAR_CURRENT="$CURRENT" \
           bash "$BIN/tmux-dashboard-rows.sh" --sidebar 2>/dev/null) || rows=''
fleet_home_mark rows
# wid US state US glyph US name US tree US badge US depth US detail (#1328)
#   →  `wid<TAB>▶ glyph tree name · badge`
list=''
while IFS="$US" read -r wid _state glyph label tree badge _; do
  case "$wid" in @*) ;; *) continue ;; esac
  mark=' '; [ "$wid" = "$CURRENT" ] && mark='▶'
  list+="$wid	$mark ${glyph:- } ${tree:- } $label${badge:+ · $badge}"$'\n'
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
# --sync: the rows are already in memory, so fzf draws ONCE, the list in its
# first frame, instead of an empty frame and a second full redraw when stdin
# ends — half the bytes down a slow link (issue #1611: ~17 KB → ~9 KB a popup
# on a 54x50 client). No --border: the popup's own frame (dash-popup.sh, #1535)
# is the border; a second one inside cost two columns and ~2 KB a draw.
fleet_home_mark fzf
out=$(printf '%s' "$list" | fzf --ansi --no-sort --layout=reverse-list --info=hidden --sync \
        --height=100% --delimiter='	' --with-nth=2.. \
        --print-query --prompt='task ▸ ' --header="$hdr" \
        --bind "$DASH_KEY_SCRATCH:execute-silent(printf 'scratch %s' {q} > $qf)+abort" \
        --bind "f9:execute-silent(printf hub > $qf)+abort" \
        --bind "click-header:transform:case \"\$FZF_CLICK_HEADER_WORD\" in *＋*|*new*) printf 'scratch %s' {q} > $qf; echo abort ;; *⌂*|*hub*) printf hub > $qf; echo abort ;; *✕*|*close*) echo abort ;; esac")
fleet_home_end close   # lands before the parent reads the trace
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
