#!/bin/bash
# fleet-client-lib.sh — write to the operator's OWN terminal through the tmux client
# they are using (sourced; issues #1367/#1371, shared with fleet-open by #1379).
#
# Two scripts put an iTerm2 escape on the operator's terminal: bin/fleet-show.sh
# (OSC 1337 MultipartFile — a file) and bin/fleet-open.sh (OSC 1337 Custom — a
# link for their machine to open). Both need the same two things, and this is the
# ONE copy of each:
#
#   WHICH client — the one the operator is USING: the most recent
#     #{client_activity} of this pane's session, whose #{client_termtype} must
#     match the terminal regex (FLEET_SHOW_TERM_RE, default ^iTerm2). A newer
#     non-iTerm2 client does NOT fall back to an older iTerm2 one (#1371: that sent
#     the file to a stale iTerm2 at home while the operator read the fleet from a
#     phone). An empty termtype (tmux < 3.4, or no XTVERSION answer) is not iTerm2.
#     `--client <tty>` names one outright and skips the match.
#
#   HOW it is written — `tmux lock-client` with the session's lock-command swapped
#     for one lock: the CLIENT process leaves tmux mode and runs the sender as the
#     only writer on its tty, so no tmux frame lands inside the escape (see
#     fleet-show.sh's header for the measurements). The previous lock-command is
#     restored right after the lock is issued. One send per session at a time.
#
# Functions set FC_* globals; a failure sets FC_WHY (operator-facing) and returns 1.
#   fc_session                 → FC_SESS (this pane's session)
#   fc_pick <client> <re>      → FC_CLIENT FC_TERMTYPE FC_GEOM (cols,rows,cw,ch)
#   fc_lock                    → FC_LOCKDIR held (needs FC_SESS); fc_unlock frees it
#   fc_run <cmd>               → lock-client FC_CLIENT running <cmd> (needs FC_SESS)
#   fc_wait <status> <secs>    → 0 once <status> holds a `done` line
# shellcheck disable=SC2034  # the FC_* globals are read by the sourcing script

fc_session() {
  FC_SESS=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
  [ -n "$FC_SESS" ] || { FC_WHY='cannot resolve this pane'"'"'s tmux session'; return 1; }
}
# fc_clients <fmt> — `list-clients -F <fmt>` for every client of FC_SESS, its view
# sessions' included (`<fleet>@view-<id>`, issue #1489: a shell or proxy sits on
# one of those, and it is the newest client fleet-open must find).
fc_clients() {
  tmux list-clients -F "#{?#{session_group},#{session_group},#{session_name}}	$1" 2>/dev/null \
    | awk -F '\t' -v s="$FC_SESS" '$1 == s { sub(/^[^\t]*\t/, ""); print }'
}

fc_pick() {  # <client tty, or empty> <termtype ERE>
  local want="$1" re="$2" rows pick _tty _tt
  FC_CLIENT=""; FC_TERMTYPE=""; FC_GEOM="0,0,0,0"
  # activity <TAB> tty <TAB> termtype <TAB> cols,rows,cell-w,cell-h
  rows=$(fc_clients '#{client_activity}	#{client_tty}	#{client_termtype}	#{client_width},#{client_height},#{client_cell_width},#{client_cell_height}')
  if [ -n "$want" ]; then
    pick=$(printf '%s\n' "$rows" | awk -F '\t' -v c="$want" '$2 == c { print $2 "\t" $3 "\t" $4; exit }')
    [ -n "$pick" ] || { FC_WHY="$want is not a client of session '$FC_SESS'"; return 1; }
  else
    # The newest client is the one the operator is at — it must BE iTerm2 (#1371).
    pick=$(printf '%s\n' "$rows" | awk -F '\t' 'NF >= 2' | sort -t '	' -k1,1nr | head -n 1 \
      | awk -F '\t' '{ print $2 "\t" $3 "\t" $4 }')
    [ -n "$pick" ] || { FC_WHY="no client is attached to session '$FC_SESS'"; return 1; }
    _tty="${pick%%	*}"; _tt="${pick#*	}"; _tt="${_tt%%	*}"
    [ -n "$_tt" ] || { FC_WHY="当前活跃 client ${_tty} 的终端类型未知（tmux < 3.4，或终端没回应 XTVERSION），不是 iTerm2"; return 1; }
    printf '%s\n' "$_tt" | grep -Eq -- "$re" \
      || { FC_WHY="当前活跃 client ${_tty} 是 ${_tt}，不是 iTerm2（/${re}/）"; return 1; }
  fi
  FC_CLIENT="${pick%%	*}"; FC_TERMTYPE="${pick#*	}"; FC_GEOM="${FC_TERMTYPE#*	}"; FC_TERMTYPE="${FC_TERMTYPE%%	*}"
  [ "$FC_GEOM" != "$FC_TERMTYPE" ] || FC_GEOM=""
  case "$FC_GEOM" in *[!0-9,]*|'') FC_GEOM="0,0,0,0" ;; esac
  return 0
}

fc_lock() {
  local _
  FC_LOCKDIR="${TMPDIR:-/tmp}/fleet-show.$(id -u).$(printf '%s' "$FC_SESS" | tr -c 'A-Za-z0-9._-' '_').lock"
  for _ in $(seq 1 100); do
    mkdir "$FC_LOCKDIR" 2>/dev/null && return 0
    # a holder killed mid-send leaves the dir: stale after 5 min
    if [ -n "$(find "$FC_LOCKDIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$FC_LOCKDIR" 2>/dev/null; continue; fi
    sleep 0.2
  done
  FC_WHY='another fleet-show / fleet-open is sending in this session'
  return 1
}
fc_unlock() { [ -n "${FC_LOCKDIR:-}" ] && rmdir "$FC_LOCKDIR" 2>/dev/null; return 0; }

fc_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

fc_run() {  # <cmd> — swap the session's lock-command for one lock, then put back
  # exactly what was there (a session value, or none — the global default shows through)
  local cmd="$1" prev_set prev_val lrc
  prev_set=$(tmux show-options -q -t "$FC_SESS" lock-command 2>/dev/null)
  prev_val=$(tmux show-options -qv -t "$FC_SESS" lock-command 2>/dev/null)
  tmux set-option -t "$FC_SESS" lock-command "$cmd" 2>/dev/null || { FC_WHY='cannot set lock-command'; return 1; }
  tmux lock-client -t "$FC_CLIENT" 2>/dev/null; lrc=$?
  if [ -n "$prev_set" ]; then tmux set-option -t "$FC_SESS" lock-command "$prev_val" 2>/dev/null
  else tmux set-option -u -t "$FC_SESS" lock-command 2>/dev/null; fi
  [ "$lrc" = 0 ] || { FC_WHY="tmux lock-client -t $FC_CLIENT failed"; return 1; }
}

fc_wait() {  # <status file> <limit seconds>
  local status="$1" limit="$2" waited=0
  while ! grep -qx 'done' "$status" 2>/dev/null; do
    [ "$waited" -ge $(( limit * 5 )) ] && break
    sleep 0.2; waited=$(( waited + 1 ))
  done
  grep -qx 'done' "$status" 2>/dev/null
}
