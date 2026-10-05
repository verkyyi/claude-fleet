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
#
# And the client's one dependency (issue #1629), shared by the two installers —
# bin/fleet-install.sh (sources this file once it is downloaded) and
# bin/fleet-node-join.sh (run as `curl … | bash`, so it carries a copy of
# fc_tmux_ok that fleet-install-selftest.sh leg F holds byte-identical to this
# one). Both are POSIX sh — the installer runs under dash on Linux:
#   fc_tmux_ok                 → 0 iff tmux ≥ 3.2 on PATH; FC_TMUX_V its version
#   fc_pkg_install <pkg>       → install with Homebrew (macOS; never installs
#                                Homebrew itself) or apt-get / dnf / yum / apk
#                                as root or through `sudo -n` (Linux; never a
#                                password prompt). 0 ran · 1 the install failed
#                                · 2 no way to install here; FC_WHY says which,
#                                FC_HOW the one command to run. Seams: FC_OS
#                                (darwin|linux), FC_SUDO (default `sudo -n`),
#                                FC_BREW_DIRS (where else to look for brew),
#                                FC_LOG (the package manager's output)
# shellcheck disable=SC2034  # the FC_* globals are read by the sourcing script

fc_session() {
  FC_SESS=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
  [ -n "$FC_SESS" ] || { FC_WHY='cannot resolve this pane'"'"'s tmux session'; return 1; }
}
# fc_clients <fmt> — `list-clients -F <fmt>` for every client of FC_SESS, its view
# sessions' included (`<fleet>@view-<id>`, issue #1489: a shell or proxy sits on
# one of those, and it is the newest client fleet-open must find). The row is
# asked for as `$sid:<fleet>\t<fmt>` and the prefix split off again; a row without
# that shape (a selftest's fake tmux printing canned lines) passes through as it is.
fc_clients() {
  tmux list-clients -F "#{session_id}:#{?#{session_group},#{session_group},#{session_name}}	$1" 2>/dev/null \
    | awk -F '\t' -v s="$FC_SESS" '$1 !~ /^\$[0-9]+:/ { print; next }
                               { k = $1; sub(/^[^:]*:/, "", k); if (k != s) next; sub(/^[^\t]*\t/, ""); print }'
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

# fc_tmux_ok — tmux ≥ 3.2 on PATH (the shell's key tables and `-e` need it); an
# older one counts as none. FC_TMUX_V = what `tmux -V` said, minus "tmux ".
fc_tmux_ok() {
  FC_TMUX_V=""
  command -v tmux >/dev/null 2>&1 || return 1
  FC_TMUX_V=$(tmux -V 2>/dev/null); FC_TMUX_V=${FC_TMUX_V#tmux }
  _fc_v=${FC_TMUX_V#next-}; _fc_maj=${_fc_v%%.*}
  case "$_fc_v" in *.*) _fc_min=${_fc_v#*.}; _fc_min=${_fc_min%%[!0-9]*} ;; *) _fc_maj=${_fc_maj%%[!0-9]*}; _fc_min=0 ;; esac
  case "$_fc_maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$_fc_min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_fc_maj" -gt 3 ] || { [ "$_fc_maj" -eq 3 ] && [ "$_fc_min" -ge 2 ]; }
}

fc_brew_bin() {
  for _fc_b in "$(command -v brew 2>/dev/null)" ${FC_BREW_DIRS-/opt/homebrew/bin /usr/local/bin}; do
    case "$_fc_b" in '') continue ;; */brew) ;; *) _fc_b="$_fc_b/brew" ;; esac
    [ -x "$_fc_b" ] && { echo "$_fc_b"; return 0; }
  done
  return 1
}

# fc_priv <cmd…> — root, or passwordless sudo, or nothing: never a password prompt.
fc_priv() {
  if [ "$(id -u)" = 0 ]; then "$@"; return; fi
  [ -n "${FC_SUDO-sudo -n}" ] || return 1
  # shellcheck disable=SC2086
  ${FC_SUDO-sudo -n} "$@"
}

fc_pkg_install() {  # <pkg>
  FC_WHY=""; FC_HOW=""
  _fc_log="${FC_LOG:-/dev/null}"
  _fc_os="${FC_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
  if [ "$_fc_os" = darwin ]; then
    FC_HOW="brew install $1"
    _fc_brew=$(fc_brew_bin) || { FC_WHY="没有 Homebrew（不替你装）：先装 https://brew.sh，再 $FC_HOW"; return 2; }
    eval "$("$_fc_brew" shellenv 2>/dev/null)"
    "$_fc_brew" install "$1" >>"$_fc_log" 2>&1 || { FC_WHY="$FC_HOW 失败：$(tail -n 2 "$_fc_log" 2>/dev/null | tr '\n' ' ')"; return 1; }
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then FC_HOW="sudo apt-get install -y $1"
  elif command -v dnf >/dev/null 2>&1; then FC_HOW="sudo dnf install -y $1"
  elif command -v yum >/dev/null 2>&1; then FC_HOW="sudo yum install -y $1"
  elif command -v apk >/dev/null 2>&1; then FC_HOW="sudo apk add $1"
  else FC_WHY="没有 apt-get / dnf / yum / apk：用这台机器的包管理器装 $1"; return 2; fi
  fc_priv true >/dev/null 2>&1 </dev/null || { FC_WHY="装 $1 要 root 或免密 sudo（不弹密码框）：自己执行 $FC_HOW"; return 2; }
  case "$FC_HOW" in
    *apt-get*) fc_priv env DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$_fc_log" 2>&1 </dev/null
               fc_priv env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >>"$_fc_log" 2>&1 </dev/null ;;
    *dnf*) fc_priv dnf install -y "$1" >>"$_fc_log" 2>&1 </dev/null ;;
    *yum*) fc_priv yum install -y "$1" >>"$_fc_log" 2>&1 </dev/null ;;
    *) fc_priv apk add --no-cache "$1" >>"$_fc_log" 2>&1 </dev/null ;;
  esac || { FC_WHY="${FC_HOW#sudo } 失败：$(tail -n 2 "$_fc_log" 2>/dev/null | tr '\n' ' ')"; return 1; }
  return 0
}
