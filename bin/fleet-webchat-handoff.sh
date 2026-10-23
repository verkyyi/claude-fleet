#!/usr/bin/env bash
# fleet-webchat-handoff.sh — one conversation, the terminal and WebChat taking
# turns (task T810). The conversation is the agent's own session (Claude Code's
# transcript, by its id); the side that HOLDS it talks, the other reads along —
# the record is bin/fleet-convo-lock.py's, whether a side is answering is read
# live here (the window's state · WebChat's own turn), never stored.
#
#   fleet-webchat-handoff.sh to-web fid:<fleet_id> [--no-open]
#       「在 WebChat 里继续」(⌘P's actions page, `fleet-webchat.sh continue`):
#       refused while either side is answering; else WebChat adopts the session
#       (its old conversation archived), the record says webchat, the window's
#       agent stops onto its end page — 「已在 WebChat 里继续 · ↵ 拿回终端」 — and
#       the page opens on the person's screen.
#   fleet-webchat-handoff.sh owner --agent A --sid S
#       WebChat's /api/conversation: {"holder", "busy", "label", "machine"} as JSON
#       (holder "" = no record: nobody ever handed it over).
#   fleet-webchat-handoff.sh to-webchat-take --agent A --sid S
#       WebChat's 「在这里继续」: the terminal must be idle; its agent stops onto the
#       end page, the record says webchat.
#   fleet-webchat-handoff.sh view-of fid:<fleet_id>
#       WebChat's /api/view (task F481): the session a window runs, to read along
#       — {"agent", "sid", "busy", "state", "label", "holder"} as JSON; rc 2 = no
#       such window on this login.
#   fleet-webchat-handoff.sh to-terminal --agent A --sid S --fid F
#       the end page's ↵ (fleet-session-wrap.sh): WebChat must be idle; the record
#       says terminal. No record ⇒ rc 0, nothing written.
#   fleet-webchat-handoff.sh give-back fid:<fleet_id>
#       the session workspace's 「交回终端」(task VV8F, EPIC GR5E C6): WebChat must be
#       idle; the window's end page gets its own ↵ — to-terminal and the same
#       conversation resumed there, the one road back. No window ⇒ the record
#       alone says terminal.
#
# rc 0 done · 2 cannot (no conversation id, not this agent, no WebChat here) ·
# 3 the other side is answering (its one line says where) · 1 anything else.
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"
# shellcheck source=fleet-ui-lang.sh
. "$BIN/fleet-ui-lang.sh"
LOCK="$BIN/fleet-convo-lock.py"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
CHAT_SOCK="${FLEET_WEBCHAT_SOCK:-$CONF/webchat/chat.sock}"
EXIT_WAIT="${FLEET_HANDOFF_EXIT_WAIT:-15}"

die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
SOCK=''
TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }
wopt() { TM show-options -wqv -t "$WIN" "$1" 2>/dev/null; }

# WebChat on this login: GET/POST over its socket (the entry is never in between)
chat() { # <method> <path> [json]
  [ -S "$CHAT_SOCK" ] || return 7
  local data=${3:-}
  [ -n "$data" ] || data='{}'
  if [ "$1" = POST ]; then
    curl -sS --max-time "${FLEET_HANDOFF_CHAT_TIMEOUT:-20}" --unix-socket "$CHAT_SOCK" -X POST \
      -H 'Content-Type: application/json' -H 'X-Fleet-Webchat: 1' --data-binary "$data" \
      -w '\n%{http_code}' "http://webchat$2"
  else
    curl -sS --max-time "${FLEET_HANDOFF_CHAT_TIMEOUT:-20}" --unix-socket "$CHAT_SOCK" -w '\n%{http_code}' "http://webchat$2"
  fi
}
chat_up() { # the service started on demand, as a person opening the page does
  [ -S "$CHAT_SOCK" ] && chat GET /healthz >/dev/null 2>&1 && return 0
  bash "$BIN/fleet-webchat.sh" ensure >/dev/null 2>&1 || true
  [ -S "$CHAT_SOCK" ]
}
# the WebChat side an agent's conversation is on: Claude's (no query) or Codex's (task R9A2)
side_q() { [ "${1:-claude}" = codex ] && printf '?provider=codex'; }
# is WebChat answering right now, on that agent's side? (no service = no)
chat_busy() { # [agent]
  local out
  out=$(chat GET "/api/state$(side_q "${1:-claude}")" 2>/dev/null) || return 1
  case "$(printf '%s' "$out" | tail -n 1)" in 200) ;; *) return 1 ;; esac
  printf '%s' "$out" | sed '$d' | python3 -c 'import json,sys
sys.exit(0 if json.load(sys.stdin).get("busy") is True else 1)' 2>/dev/null
}

# the window a fleet_id names, on whichever socket it lives (sets SOCK, WIN)
find_win() {
  local loc
  loc=$(fleet_id_window "$1" 2>/dev/null) || return 1
  SOCK=${loc%%$'\t'*}; WIN=${loc#*$'\t'}
  [ -n "$WIN" ]
}
# is the window's agent answering? working / blocked (a question it waits on) — the reapers' reader
term_busy() {
  local st
  st=$(fleet_reap_state "$WIN" "$SOCK" 2>/dev/null) || return 1
  case "$st" in working|blocked|needs*|looping) return 0 ;; esac
  return 1
}
lock_get() { python3 "$LOCK" get --agent "$1" --sid "$2" 2>/dev/null || echo '{}'; }
jval() { python3 -c 'import json,sys; print(json.loads(sys.argv[1] or "{}").get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }

# stop the window's agent onto its end page, marked handed — the fleet's own
# /exit (fleet-transfer.sh's sequence), never a kill
stop_agent() { # <agent>
  TM set-option -w -t "$WIN" @handoff_web 1 2>/dev/null
  local pane; pane=$(TM display-message -p -t "$WIN" '#{pane_id}' 2>/dev/null)
  [ -n "$pane" ] || return 1
  SK() { FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$pane" "$@"; }
  SK Escape; SK C-u
  if [ "$(fleet_agent_get "$1" exit_paste)" = 1 ]; then SK -l $'\033[200~/exit\033[201~'
  else SK -l '/exit'; fi
  SK Enter
  local i=0
  while [ "$i" -lt "$EXIT_WAIT" ]; do
    [ "$(wopt @claude_state)" = exited ] && return 0
    sleep 1; i=$((i + 1))
  done
  TM set-option -wu -t "$WIN" @handoff_web 2>/dev/null
  return 1
}

hub_app_url() {
  local url
  url=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)}}
  [ -n "$url" ] || return 1
  printf '%s/app/%s' "${url%/}" "${1:-}"
}

# one handover of a window at a time (task VV8F): two pages, or a page and ⌘P,
# pressing 接管 together — the second is refused (rc 3), never both
take_guard() { # <fid>
  local d="$CONF/convo-lock"
  mkdir -p "$d" 2>/dev/null
  GUARD="$d/.taking-$1"
  # a guard older than a handover can take is a crashed one
  if [ -d "$GUARD" ] && [ -n "$(find "$GUARD" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rmdir "$GUARD" 2>/dev/null; fi
  mkdir "$GUARD" 2>/dev/null || return 1
  trap 'rmdir "$GUARD" 2>/dev/null' EXIT
}

to_web() {
  local addr=${1:-} open=1
  [ "${2:-}" = --no-open ] && open=0
  local fid=${addr#fid:}
  fleet_is_fid "$fid" || die "usage: fleet-webchat-handoff.sh to-web fid:<fleet_id> [--no-open]" 2
  find_win "$fid" || die "$(fleet_ui_t webchat_gone)" 2
  python3 "$BIN/fleet-webchat-execution.py" "$fid" || exit 2
  [ -z "$(wopt @task)$(wopt @task_execution)" ] || die "请在统一会话中继续此任务；旧 WebChat 不能启动第二个执行会话。" 2
  local agent sid label machine
  agent=$(fleet_agent_or_default "$(wopt @cc_agent)")
  sid=$(fleet_agent_session_id "$agent" wopt window)
  [ -n "$sid" ] || die "$(fleet_ui_t webchat_no_sid)" 2
  # Codex in WebChat is the page's Codex side (R9A2); FLEET_WEBCHAT_CODEX=0 turns it off here
  [ "$agent" = claude ] || { [ "$agent" = codex ] && [ "${FLEET_WEBCHAT_CODEX:-1}" = 1 ]; } || die "$(fleet_ui_t webchat_no_codex)" 2
  take_guard "$fid" || die "$(fleet_ui_t webchat_taking)" 3
  [ "$(wopt @claude_state)" = exited ] && [ "$(wopt @handoff_web)" = 1 ] && die "$(fleet_ui_t webchat_already)" 2
  term_busy && die "$(fleet_ui_t webchat_term_busy)" 3
  label=$(wopt @raw); [ -n "$label" ] || label=$(TM display-message -p -t "$WIN" '#{window_name}' 2>/dev/null)
  machine=$(hostname -s 2>/dev/null)
  chat_up || die "$(fleet_ui_t webchat_down)" 2
  chat_busy "$agent" && die "$(fleet_ui_t webchat_web_busy)" 3
  local body out code
  body=$(python3 -c 'import json,sys; print(json.dumps({"agent":sys.argv[1],"session":sys.argv[2],"label":sys.argv[3],"machine":sys.argv[4],"fid":sys.argv[5]}))' \
    "$agent" "$sid" "$label" "$machine" "$fid")
  out=$(chat POST /api/adopt "$body" 2>&1) || die "$(fleet_ui_t webchat_down)" 2
  code=$(printf '%s' "$out" | tail -n 1)
  [ "$code" = 200 ] || die "$(fleet_ui_t webchat_refused_fmt "$(printf '%s' "$out" | sed '$d' | jval_err)")" 1
  python3 "$LOCK" set --agent "$agent" --sid "$sid" --holder webchat --fid "$fid" --label "$label" --machine "$machine" >/dev/null \
    || die "fleet-convo-lock: cannot write" 1
  if ! stop_agent "$agent"; then
    python3 "$LOCK" set --agent "$agent" --sid "$sid" --holder terminal >/dev/null
    die "$(fleet_ui_t webchat_stop_failed)" 1
  fi
  if [ "$open" = 1 ]; then
    local u; u=$(hub_app_url) && bash "$BIN/fleet-open.sh" "$u" >/dev/null 2>&1
  fi
  fleet_ui_t webchat_done; echo
}
jval_err() { python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("error",""))
except Exception: print("")' 2>/dev/null; }

parse_as() { # --agent A --sid S [--fid F]
  AGENT=claude; SID=''; FID=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --agent) AGENT=${2:-}; shift 2 ;;
      --sid) SID=${2:-}; shift 2 ;;
      --fid) FID=${2:-}; shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$SID" ] || die "--sid is required" 2
}

owner() {
  parse_as "$@"
  local rec holder fid busy=false
  rec=$(lock_get "$AGENT" "$SID")
  holder=$(jval "$rec" holder)
  if [ "$holder" = terminal ]; then
    fid=$(jval "$rec" window_fid)
    if fleet_is_fid "$fid" && find_win "$fid" && term_busy; then busy=true; fi
  fi
  python3 -c 'import json,sys
r=json.loads(sys.argv[1] or "{}")
print(json.dumps({"holder":r.get("holder",""),"busy":sys.argv[2]=="true","label":r.get("label",""),"machine":r.get("machine","")},ensure_ascii=False))' "$rec" "$busy"
}

# WebChat's 「在这里继续」
webchat_take() {
  parse_as "$@"
  local rec holder fid
  rec=$(lock_get "$AGENT" "$SID")
  holder=$(jval "$rec" holder)
  [ "$holder" = terminal ] || { echo ok; return 0; }
  fid=$(jval "$rec" window_fid)
  if [ -n "$fid" ]; then python3 "$BIN/fleet-webchat-execution.py" "$fid" || exit 2; fi
  if fleet_is_fid "$fid" && find_win "$fid"; then
    [ -z "$(wopt @task)$(wopt @task_execution)" ] || die "请在统一会话中继续此任务；旧 WebChat 不能启动第二个执行会话。" 2
    term_busy && die "$(fleet_ui_t webchat_term_busy)" 3
    if [ "$(wopt @claude_state)" != exited ]; then
      python3 "$LOCK" set --agent "$AGENT" --sid "$SID" --holder webchat --if-holder terminal >/dev/null \
        || die "$(fleet_ui_t webchat_term_busy)" 3
      stop_agent "$AGENT" || { python3 "$LOCK" set --agent "$AGENT" --sid "$SID" --holder terminal >/dev/null
        die "$(fleet_ui_t webchat_stop_failed)" 1; }
      echo ok; return 0
    fi
    TM set-option -w -t "$WIN" @handoff_web 1 2>/dev/null
  fi
  python3 "$LOCK" set --agent "$AGENT" --sid "$SID" --holder webchat --if-holder terminal >/dev/null \
    || die "$(fleet_ui_t webchat_term_busy)" 3
  echo ok
}

# WebChat's 只读 view of a terminal session (task F481): which agent, which
# conversation, whether it is answering — read live, nothing written
view_of() {
  local fid=${1#fid:}
  fleet_is_fid "$fid" || die "usage: fleet-webchat-handoff.sh view-of fid:<fleet_id>" 2
  find_win "$fid" || die "no such window" 2
  local agent sid st busy=false label holder=''
  agent=$(fleet_agent_or_default "$(wopt @cc_agent)")
  sid=$(fleet_agent_session_id "$agent" wopt)
  st=$(wopt @claude_state)
  term_busy && busy=true
  label=$(wopt @raw); [ -n "$label" ] || label=$(TM display-message -p -t "$WIN" '#{window_name}' 2>/dev/null)
  [ -n "$sid" ] && holder=$(jval "$(lock_get "$agent" "$sid")" holder)
  python3 -c 'import json,sys
print(json.dumps({"agent":sys.argv[1],"sid":sys.argv[2],"busy":sys.argv[3]=="true","state":sys.argv[4],"label":sys.argv[5],"holder":sys.argv[6]},ensure_ascii=False))' \
    "$agent" "$sid" "$busy" "$st" "$label" "$holder"
}

# the end page's ↵: back to the terminal
to_terminal() {
  parse_as "$@"
  local rec holder
  rec=$(lock_get "$AGENT" "$SID")
  holder=$(jval "$rec" holder)
  [ -n "$holder" ] || return 0
  [ "$holder" = terminal ] && return 0
  chat_busy "$AGENT" && die "$(fleet_ui_t webchat_web_busy_wait)" 3
  python3 "$LOCK" set --agent "$AGENT" --sid "$SID" --holder terminal ${FID:+--fid "$FID"} --if-holder webchat >/dev/null \
    || die "$(fleet_ui_t webchat_web_busy_wait)" 3
  # WebChat lets go of its warm process on this session at its next read
  chat POST "/api/release$(side_q "$AGENT")" "{\"agent\":\"$AGENT\",\"session\":\"$SID\"}" >/dev/null 2>&1 || true
  return 0
}

# the workspace's 「交回终端」: the window's end page takes its own ↵
give_back() {
  local fid=${1#fid:}
  fleet_is_fid "$fid" || die "usage: fleet-webchat-handoff.sh give-back fid:<fleet_id>" 2
  find_win "$fid" || die "$(fleet_ui_t webchat_gone)" 2
  local agent sid holder
  agent=$(fleet_agent_or_default "$(wopt @cc_agent)")
  sid=$(fleet_agent_session_id "$agent" wopt window)
  [ -n "$sid" ] || die "$(fleet_ui_t webchat_no_sid)" 2
  holder=$(jval "$(lock_get "$agent" "$sid")" holder)
  [ "$holder" = webchat ] || { echo ok; return 0; }
  take_guard "$fid" || die "$(fleet_ui_t webchat_taking)" 3
  chat_busy "$agent" && die "$(fleet_ui_t webchat_web_busy_wait)" 3
  if [ "$(wopt @claude_state)" != exited ] || [ "$(wopt @handoff_web)" != 1 ]; then
    # no end page waiting (a window that went on otherwise): the record alone
    to_terminal --agent "$agent" --sid "$sid" --fid "$fid"
    echo ok; return 0
  fi
  local pane; pane=$(TM display-message -p -t "$WIN" '#{pane_id}' 2>/dev/null)
  [ -n "$pane" ] || die "$(fleet_ui_t webchat_gone)" 2
  FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$pane" Enter
  # the page runs to-terminal and unmarks the window once the record says terminal
  local i=0
  while [ "$i" -lt $((EXIT_WAIT * 5)) ]; do
    [ "$(wopt @handoff_web)" = 1 ] || { echo ok; return 0; }
    sleep 0.2; i=$((i + 1))
  done
  die "$(fleet_ui_t webchat_web_busy_wait)" 3
}

case "${1:-}" in
  to-web) shift; to_web "$@" ;;
  give-back) shift; give_back "$@" ;;
  owner) shift; owner "$@" ;;
  to-webchat-take) shift; webchat_take "$@" ;;
  to-terminal) shift; to_terminal "$@" ;;
  view-of) shift; view_of "$@" ;;
  *) die "usage: fleet-webchat-handoff.sh to-web fid:<id> [--no-open] | give-back fid:<id> | view-of fid:<id> | owner|to-webchat-take|to-terminal --agent A --sid S [--fid F]" 2 ;;
esac
