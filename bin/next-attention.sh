#!/bin/sh
# next-attention.sh — jump to the next Claude window that needs attention.
# Priority: 'needs' (red = answer me) first, then 'done' (green = finished/stopped);
# lowest index first. Bound to `prefix + a` in conf/tmux-attention.conf.
#
# --needs-cycle: cycle through ONLY the 'needs' windows — jump to the first
# 'needs' window whose index is strictly greater than the current window's,
# wrapping to the lowest when there is none above. Repeated invocations walk
# every needs window in turn. Wired to the bottom-left needs badge's click
# (MouseDown1Status) so clicking it steps through them; prefix+a keeps the
# priority-jump behavior above.
set -u  # POSIX sh: pipefail is bash-only (dash has none)
sess=$(tmux display-message -p '#{session_name}')

if [ "${1:-}" = "--needs-cycle" ]; then
  cur=$(tmux display-message -p '#{window_index}')
  target=$(tmux list-windows -t "$sess" -F '#{window_index} #{@claude_state}' | awk -v cur="$cur" '
    $2 == "needs" { idx[n++] = $1 + 0 }
    END {
      if (n == 0) exit 0
      for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (idx[j] < idx[i]) { t = idx[i]; idx[i] = idx[j]; idx[j] = t }
      for (i = 0; i < n; i++) if (idx[i] > cur + 0) { print idx[i]; exit }
      print idx[0]  # none above -> wrap to the lowest needs index
    }
  ')
  if [ -n "$target" ]; then
    tmux select-window -t "$sess:$target"
  else
    tmux display-message "✓ No window needs you"
  fi
  exit 0
fi

target=$(tmux list-windows -t "$sess" -F '#{window_index} #{@claude_state}' | awk '
  $2 == "needs" && n == "" { n = $1 }
  $2 == "done"  && d == "" { d = $1 }
  END { if (n != "") print n; else if (d != "") print d }
')

if [ -n "$target" ]; then
  tmux select-window -t "$sess:$target"
else
  tmux display-message "✓ No session needs you or is finished — all busy"
fi
