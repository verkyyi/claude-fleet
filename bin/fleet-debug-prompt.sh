#!/bin/sh
# fleet-debug-prompt.sh — after the third failure in a row, the client asks
# whether the hub should take a look (issue #2894, EPIC #2889 C5).
#
#   fleet-debug-prompt.sh after <action> <rc> [reason]
#       rc 0: a success — the failure book is emptied. Else the failure is
#       written down, then `ask`. Exits 0 always: the caller keeps its own code.
#   fleet-debug-prompt.sh fail <action> <rc> [reason]   only write it down
#   fleet-debug-prompt.sh ok                            only empty the book
#   fleet-debug-prompt.sh ask                           ask now, when due
#   fleet-debug-prompt.sh can     rc 0: may offer it at all (switch on, a ticket)
#   fleet-debug-prompt.sh stall <what>                  the right pane's 「正在连接」
#       page, stuck: `fleet-debug report --note <what>`, its output as it came
#
# <action> is login · place · connect. The book is the shell cache's
# `debug-fails` (FLEET_SHELL_CACHE, else ~/.cache/claude-fleet/shell): one line
# a failure — epoch · UTC time · action · exit code · reason — the last 20
# kept. FLEET_DEBUG_PROMPT_AFTER (3) failures inside FLEET_DEBUG_PROMPT_WINDOW
# (1800 s) ask, once: y runs `fleet-debug report --note "<the last failure>"`
# and passes its words on (an expired ticket: fleet-debug says how to get
# another), n says how to run it later and asks nothing again for
# FLEET_DEBUG_PROMPT_QUIET (86400 s, `debug-declined`).
#
# Never asked: FLEET_DEBUG_PROMPT=0 · no terminal on stdin AND stdout · inside
# the client's own tmux (FLEET_SHELL=1 — the sidebar, the stage, the keeper;
# the stage has its own 「按 d」, `stall`) · no debug ticket on this computer
# (the hub has no remote debugging — fleet-debug would only refuse).
#
# Seams (tests): FLEET_DEBUG_PROMPT_TTY=1 (as if both were terminals) ·
# FLEET_DEBUG_PROMPT_NOW (epoch) · FLEET_DEBUG_CMD (instead of
# `sh <here>/fleet-debug`).
set -u

here=$(cd "$(dirname "$0")" && pwd)
CACHE=${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}
BOOK="$CACHE/debug-fails"
QUIET_FILE="$CACHE/debug-declined"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
TICKET_FILE="$CONF/debug-ticket"   # KEEP IN SYNC: fleet-debug's TICKET_FILE

t() { sh "$here/fleet-ui-lang.sh" t "$@" 2>/dev/null; }
now() { printf '%s\n' "${FLEET_DEBUG_PROMPT_NOW:-$(date +%s)}"; }
num() { case ${1:-} in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac; }

# debug_run <note>: fleet-debug report, its words and its code as they came
debug_run() {
  if [ -n "${FLEET_DEBUG_CMD:-}" ]; then
    $FLEET_DEBUG_CMD report --note "$1"
  else
    sh "$here/fleet-debug" report --note "$1"
  fi
}

# the reason a caller did not give: the last line of the client's own log for
# that action (docs/CLIENT-LOGS.md, already redacted), its result · reason
log_reason() {
  f="${FLEET_CLIENT_LOG_DIR:-$CACHE/logs}/$1.log"
  [ -s "$f" ] || return 0
  tail -n 1 "$f" | awk -F '\t' '{ s = $6; if ($7 != "") s = s " · " $7; print s }'
}

record() {
  mkdir -p "$CACHE" 2>/dev/null || return 0
  r=${3:-}; [ -n "$r" ] || r=$(log_reason "$1")
  r=$(printf '%s' "$r" | tr '\t\n\r' '   ' | cut -c1-300)
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now)" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" "$r" >> "$BOOK" 2>/dev/null || return 0
  chmod 600 "$BOOK" 2>/dev/null
  if [ "$(wc -l < "$BOOK" | tr -d ' ')" -gt 20 ]; then
    tail -n 20 "$BOOK" > "$BOOK.tmp" 2>/dev/null && mv -f "$BOOK.tmp" "$BOOK"
  fi
  return 0
}

clear_book() { rm -f "$BOOK" 2>/dev/null; return 0; }

# due: rc 0 when this terminal should be asked now
due() {
  [ "${FLEET_DEBUG_PROMPT:-1}" != 0 ] || return 1
  [ "${FLEET_SHELL:-}" != 1 ] || return 1
  if [ "${FLEET_DEBUG_PROMPT_TTY:-}" != 1 ]; then
    [ -t 0 ] && [ -t 1 ] || return 1
  fi
  [ -s "$TICKET_FILE" ] || return 1
  [ -s "$BOOK" ] || return 1
  n=$(now)
  q=''; [ -s "$QUIET_FILE" ] && q=$(head -n 1 "$QUIET_FILE")
  q=$(num "$q" 0)
  [ $(( n - q )) -ge "$(num "${FLEET_DEBUG_PROMPT_QUIET:-}" 86400)" ] || return 1
  win=$(num "${FLEET_DEBUG_PROMPT_WINDOW:-}" 1800)
  c=$(awk -F '\t' -v since=$(( n - win )) '$1 + 0 >= since { c++ } END { print c + 0 }' "$BOOK")
  [ "$c" -ge "$(num "${FLEET_DEBUG_PROMPT_AFTER:-}" 3)" ]
}

# the note fleet-debug carries: the last failure, in one line
last_note() {
  tail -n 1 "$BOOK" 2>/dev/null | awk -F '\t' '{
    s = $2 " " $3 " exit " $4; if ($5 != "") s = s " · " $5; print s }'
}

ask() {
  due || return 0
  c=$(awk -F '\t' 'END { print NR }' "$BOOK")
  printf '\n%s\n%s\n%s ' "$(t debug_prompt_q_fmt "$c")" "$(t debug_prompt_what)" "$(t debug_prompt_keys)"
  a=''
  read -r a || a=''
  case $a in
    y|Y|yes|YES|是|好)
      note=$(last_note)
      printf '\n'
      debug_run "$note" && clear_book ;;
    *)
      now > "$QUIET_FILE" 2>/dev/null
      printf '%s\n' "$(t debug_prompt_no)" ;;
  esac
  return 0
}

case ${1:-} in
  after)
    [ $# -ge 3 ] || exit 2
    if [ "$3" = 0 ]; then clear_book; exit 0; fi
    record "$2" "$3" "${4:-}"
    ask; exit 0 ;;
  fail) [ $# -ge 3 ] || exit 2; record "$2" "$3" "${4:-}"; exit 0 ;;
  ok) clear_book; exit 0 ;;
  ask) ask; exit 0 ;;
  due) due ;;
  can) [ "${FLEET_DEBUG_PROMPT:-1}" != 0 ] && [ -s "$TICKET_FILE" ] ;;
  stall) shift; debug_run "${1:-}" ;;
  *) printf 'usage: fleet-debug-prompt.sh after|fail <action> <rc> [reason] · ok · ask · stall <what>\n' >&2; exit 2 ;;
esac
