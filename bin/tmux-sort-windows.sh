#!/bin/sh
# tmux-sort-windows.sh [session] — reorder a session's windows by @claude_state urgency.
# The lowest-indexed window is PINNED (your hub/dashboard window); the rest are
# re-slotted after it by rank:  needs(!) 0 · done(✓) 1 · working 2 · looping 3 · idle/other 4.
# Stable within rank (keeps current relative order) so a state flip moves only
# the window that changed. No-op when the order already matches.
# Called (backgrounded) from set-claude-state.sh on every state flip; safe to
# run by hand. Single writer via lockdir; concurrent callers set a rerun flag.
#
# Consequence: window NUMBERS are not stable (prefix+N muscle memory dies);
# navigate by name/position — slot 1 is always the most urgent session.
SESS="${1:-}"
[ -n "$SESS" ] || SESS=$(tmux display-message -p '#{session_name}' 2>/dev/null) || exit 0
[ -n "$SESS" ] || exit 0
LOCK="${TMPDIR:-/tmp}/.claude-sort.lock"
RERUN="${TMPDIR:-/tmp}/.claude-sort.rerun"
if ! mkdir "$LOCK" 2>/dev/null; then : > "$RERUN"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

while :; do
  rm -f "$RERUN"
  sleep 1   # coalesce bursts — parallel sessions often flip state together

  # tmux lists windows in index order; NR==1 is the pinned hub.
  snap=$(tmux list-windows -t "$SESS" -F '#{window_id} #{window_index} #{@claude_state}' 2>/dev/null)
  [ -n "$snap" ] || exit 0
  pin_idx=$(printf '%s\n' "$snap" | awk 'NR==1{print $2}')

  want=$(printf '%s\n' "$snap" | awk 'NR>1 {
      r = 4
      if ($3 == "needs") r = 0; else if ($3 == "done") r = 1
      else if ($3 == "working") r = 2; else if ($3 == "looping") r = 3
      printf "%d %06d %s\n", r, $2, $1
    }' | sort -n -k1,1 -k2,2 | awk '{print $3}')
  [ -n "$want" ] || exit 0

  cur=$(printf '%s\n' "$snap" | awk 'NR>1{print $1}')

  if [ "$want" != "$cur" ]; then
    # The window the user is actually viewing (stable window-id, survives reindex).
    # move-window -d de-selects it → tmux falls back to window 1; we restore after.
    active=$(tmux display-message -t "$SESS" -p '#{window_id}' 2>/dev/null)

    # Two-pass renumber: park at 900+ (collision-free), then compact to pin+1..N.
    i=900
    for wid in $want; do tmux move-window -d -s "$wid" -t "$SESS:$i" 2>/dev/null; i=$((i+1)); done
    j=$((pin_idx + 1))
    for wid in $want; do tmux move-window -d -s "$wid" -t "$SESS:$j" 2>/dev/null; j=$((j+1)); done

    # Keep the user on the same window they were watching (idempotent if unmoved).
    [ -n "$active" ] && tmux select-window -t "$active" 2>/dev/null
  fi

  [ -f "$RERUN" ] || break
done
exit 0
