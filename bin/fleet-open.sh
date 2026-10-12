#!/bin/bash
# fleet-open.sh <url | :port[/path] | file> [--client <tty>] [--print] [--browser] — open
# a link or a page served HERE on the operator's OWN computer (issue #1379).
#
# An agent that wants the operator to look at a page used to run `open <url>` —
# which opens it on this Mac mini's screen, where nobody is sitting — or
# bin/open-url.sh, which needs a reverse tunnel + a listener on the laptop and,
# for a page served here, hands over a tailnet address. This rides the SSH
# connection the operator already has: an iTerm2 custom control sequence written
# to THEIR terminal, which their side (#1380: an iTerm2 script) decodes and opens.
#
#   ESC ] 1337 ; Custom=id=<secret>:<base64 JSON> BEL
#
# The JSON (built by bin/fleet-open-addr.py — the contract #1380 reads):
#   {"v":1,"kind":"forward","rport":8765,"path":"/d/x/","scheme":"http","host":"<ssh alias>","ts":…}
#       a page on THIS machine (:port, localhost / 127.0.0.1, or this machine's
#       tailnet name — mapped to the loopback port `tailscale serve` or doc-preview
#       fronts): the laptop forwards a local port over its ssh to 127.0.0.1:<rport>
#   {"v":1,"kind":"url","url":"https://…","host":…,"ts":…}   anything else, as is
# A FILE goes to bin/fleet-show.sh (a download into their ~/Downloads).
#
# The secret: ~/.config/claude-fleet/open.secret (0600, made on first run). The
# laptop installer reads it over ssh, and its script ignores an escape whose id
# does not match — so nothing else printed to the terminal (a `cat` of a hostile
# file, a remote log) can make the operator's machine open a URL. Never print it.
#
# WHERE + WHICH client: the same channel as fleet-show (bin/fleet-client-lib.sh):
# the client the operator is USING, which must be iTerm2 (FLEET_SHOW_TERM_RE), and
# written through `tmux lock-client` so no tmux frame lands inside the escape.
#
# DEGRADE: no tmux, FLEET_OPEN=0, the active client is not iTerm2, the send did
# not finish → bin/open-url.sh: its reverse-tunnel opener (2226) if live, else a
# popup with the URL + OSC 52 to the operator's clipboard.
#   No receipt: iTerm2 accepting the escape says nothing about the laptop side
# (iTerm2 drops an unknown Custom= silently), so this road is `unconfirmed` (#3540).
# `fleet-doctor`'s `open` line shows the secret + the last result.
#
# THE CLIENT FIRST (issue #1717, EPIC #1710 C7): before any of the above,
# fleet-client-where.sh says where the person is. Their client holds the hub's
# lease → the address goes to that client through the hub
# (fleet-client-actions.py send) and it opens it on the device in their hands —
# a page on this machine's loopback forwarded over the client's own ssh master,
# a phone given a link to tap (the tailnet address fleet-open-addr.py found) —
# `opened` on its done. No hub and the one client here is on this computer's own screen
# → `open` here, `opened` on its exit 0. Nobody connected → the roads above, unchanged.
#
# THE AGENT'S BROWSER (issue #3236): `--browser` is how bin/fleet-browser.sh — the
# BROWSER a session gets while the person turned fleet-browser on — calls this. It
# reads an OAuth page's loopback redirect_uri port into the payload (`cport`,
# fleet-open-addr.py) so the person's side forwards exactly that port back here
# before it opens the page. A thin 看台 on THIS machine (the person's `fleet` over
# ssh, issue #3003) is told directly — OSC 7502 `open` with its connection's token on
# the 看台's own tty — and its loop forwards, opens and answers; since #3538 for every
# open, not only while fleet-browser is on (an escape there reached no one).
#
# A RECEIPT, not a send (issue #3538): every open carries an id, and a road whose far
# side can answer waits up to FLEET_OPEN_ACK_WAIT seconds (12) for it — the client's
# action loop through the hub (its done/failed), a thin client's loop (one ssh back to
# its home: `fleet-open.sh --ack <id> ok|fail <why>`), the local opener's exit. A road
# with no answer (the iTerm2 escape, a proxy spool, open-url.sh) is `unconfirmed`, and
# the stderr line gives the person's side the link. Which road it took is on stderr.
#
# THE HOME (issue #3538): a session on THIS machine watched through another machine's
# 看台 (`<id>-via-<home>`, EPIC #2999 C4 — 「经 mini2」) cannot reach the person's loop:
# their loop talks to the home only. So the open goes to the home over this machine's
# peer link (`fleet-peerlink.py exec <home>`) as `fleet-open.sh --from-peer <me>:<login>`:
# the home adds a forward to us on ITS link to this machine (`fleet-peerlink.py fwd`),
# hands its own 看台's loop the home's port — which the loop forwards over its own ssh
# — and its result line comes back here as ours. ssh end to end: no tailnet anywhere.
#
# Prints ONE result line (stderr names the road):
#   opened           the far side said it opened it                  exit 0
#   unconfirmed      handed over, no receipt within the wait (or a road that
#                    has none); stderr gives the link                exit 0
#   failed:<why>     the far side said it could not                  exit 4
#   failed:<why>     a file fleet-show could not send (PATH line above) exit 2
# exit 1 = usage / an address it cannot parse.
#
# Knobs (fleet.conf or the fleet's conf; env wins):
#   FLEET_OPEN=0               never write the escape; straight to open-url.sh
#   FLEET_OPEN_CLIENT=0        skip the client road (#1717); FLEET_OPEN_CLIENT_WAIT
#                              how long to wait for the client's answer (5 s)
#   FLEET_OPEN_LOCAL_CMD       (selftests) the local opener; FLEET_OPEN_WHERE_CMD
#                              (selftests, shared with fleet-show) the where read; FLEET_OPEN_ACTIONS_BIN
#                              (selftests) the sender
#   FLEET_OPEN_SSH_HOST        this machine's ssh alias, a hint in the payload
#   FLEET_SHOW_TERM_RE         shared with fleet-show (default ^iTerm2)
#   FLEET_OPEN_ACK_WAIT        seconds to wait for a receipt (12; 0 = none, unconfirmed)
#   FLEET_OPEN_RELAY_CMD       (selftests) the peer runner instead of `fleet-peerlink.py exec`
#   FLEET_OPEN_FWD_CMD         (selftests) the home's forwarder instead of `fleet-peerlink.py fwd`
#   FLEET_OPEN_SECRET_FILE     (selftests) the secret's path
#   FLEET_OPEN_URL_BIN         (selftests) the fallback opener
#   FLEET_SHOW_OUT             (selftests) where the sender writes instead of /dev/tty
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
  printf '  --client <tty> send to this tmux client (skips the iTerm2 match)\n'
  printf '  --print        print the payload JSON and stop (sends nothing)\n'
  printf '  --browser      called as the agent'"'"'s browser (fleet-browser.sh): forward an OAuth callback port\n'
  printf '  --ack <id> ok|fail [why]   (a client loop) the receipt of open <id>\n'
  printf '  --from-peer <machine>:<login>   (a home, over the peer link) the page is on <machine>'"'"'s loopback\n'
}

ACKS="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/open-acks"
# --ack: a client loop's receipt, written where the waiting fleet-open reads it.
if [ "${1:-}" = --ack ]; then
  case "${2:-}" in ''|*[!a-f0-9]*) echo 'fleet-open: --ack <hex id> ok|fail [why]' >&2; exit 1 ;; esac
  case "${3:-}" in ok|fail) ;; *) echo 'fleet-open: --ack <hex id> ok|fail [why]' >&2; exit 1 ;; esac
  mkdir -p "$ACKS" 2>/dev/null && chmod 700 "$ACKS" 2>/dev/null
  ( umask 077; printf '%s\t%s\n' "$3" "$(printf '%s' "${4:-}" | tr '\t\n' '  ' | cut -c1-200)" > "$ACKS/.$2.$$" \
      && mv -f "$ACKS/.$2.$$" "$ACKS/$2" ) || exit 1
  # a receipt nobody waits for does not pile up
  find "$ACKS" -type f -mmin +60 -exec rm -f {} + 2>/dev/null
  exit 0
fi

target=""; client=""; print=0; browser=0; from_peer=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from-peer) from_peer="${2:-}"; shift ;;
    --client) client="${2:-}"; shift ;;
    --client=*) client="${1#--client=}" ;;
    --print) print=1 ;;
    --browser) browser=1; export FLEET_OPEN_CALLBACK=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; target="${1:-}"; break ;;
    -*) printf 'fleet-open: unknown option %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) [ -z "$target" ] || { printf 'fleet-open: one address at a time\n' >&2; exit 1; }
       target="$1" ;;
  esac
  shift
done
[ -n "$target" ] || { usage >&2; exit 1; }

SECRET="${FLEET_OPEN_SECRET_FILE:-$HOME/.config/claude-fleet/open.secret}"
LAST="$(dirname "$SECRET")/open.last"
record() {  # <result> <kind> — the doctor's `open` line reads this; never the URL
  { mkdir -p "$(dirname "$LAST")" && printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" > "$LAST"; } 2>/dev/null
  return 0
}
# finish <word> <what> [rc] — the ONE result line (opened · unconfirmed · failed:<why>)
finish() {
  record "${1%%:*}" "$2"
  echo "$1"
  case "$1" in failed:*) exit "${3:-4}" ;; esac
  exit 0
}
# The open's id: its receipt is $ACKS/<id> (`--ack`, above).
OPEN_ID=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[ -n "$OPEN_ID" ] || OPEN_ID=$(printf '%x%x' "$(date +%s)" "$$")
# wait_ack <id> — up to FLEET_OPEN_ACK_WAIT s; ACK_STATE ok|fail, ACK_WHY. rc 1 = none.
wait_ack() {
  local f="$ACKS/$1" i=0 n
  n=$(( ${FLEET_OPEN_ACK_WAIT:-12} * 10 )); ACK_STATE=''; ACK_WHY=''
  while [ "$i" -lt "$n" ]; do
    if [ -s "$f" ]; then
      IFS='	' read -r ACK_STATE ACK_WHY < "$f"; rm -f "$f"
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ---- a file → fleet-show --------------------------------------------------------
case "$target" in file://*) f="${target#file://}"; [ -f "$f" ] && target="$f" ;; esac
if [ -f "$target" ]; then
  out=$("$BIN/fleet-show.sh" ${client:+--client "$client"} -- "$target"); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  # fleet-show has no receipt yet (issue #3541): only the local opener is one
  case "$rc" in
    0) case "$out" in
         *' → 本机'*) finish opened file ;;
         *) finish unconfirmed file ;;
       esac ;;
    2) printf '%s\n' "$out" | grep '^PATH '; finish 'failed:the file could not be sent — give the person its path' file 2 ;;
    *) exit "$rc" ;;
  esac
fi

# The fleet's knobs: global fleet.conf + this pane's fleet conf, under the env.
_env_open="${FLEET_OPEN-__unset}"; _env_re="${FLEET_SHOW_TERM_RE-__unset}"; _env_host="${FLEET_OPEN_SSH_HOST-__unset}"
if [ -f "$BIN/fleet-lib.sh" ] && [ -n "${TMUX:-}" ]; then
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh" 2>/dev/null && fleet_load_conf "$(fleet_current_session)" 2>/dev/null
fi
[ "$_env_open" = __unset ] || FLEET_OPEN="$_env_open"
[ "$_env_re" = __unset ]   || FLEET_SHOW_TERM_RE="$_env_re"
[ "$_env_host" = __unset ] || FLEET_OPEN_SSH_HOST="$_env_host"
export FLEET_OPEN_SSH_HOST="${FLEET_OPEN_SSH_HOST:-}"
TERM_RE="${FLEET_SHOW_TERM_RE:-^iTerm2}"

command -v python3 >/dev/null 2>&1 || { printf 'fleet-open: python3 not found\n' >&2; exit 1; }
PY="$(command -v python3)"
addr=$("$PY" "$BIN/fleet-open-addr.py" "$target") || exit 1
kind="${addr%%	*}"; rest="${addr#*	}"; json="${rest%%	*}"; rest="${rest#*	}"
fallback_url="${rest%%	*}"; tailnet_link=''; [ "$rest" = "$fallback_url" ] || tailnet_link="${rest#*	}"
[ "$print" = 1 ] && { printf '%s\n' "$json"; exit 0; }

# The id rides the payload: the far side's receipt names it (issue #3538).
json=$(printf '%s' "$json" | "$PY" -c 'import json,sys
d = json.load(sys.stdin); d["id"] = sys.argv[1]
print(json.dumps(d, separators=(",", ":"), ensure_ascii=False))' "$OPEN_ID") || exit 1

# ---- a page on ANOTHER machine's loopback, asked of us as its home (issue #3538) ---------
# `--from-peer <machine>:<login>`: run on this machine over that machine's peer link,
# because the person watches it through OUR 看台. Its loopback port becomes one of ours
# (our link to it gets `-L`), and the rest is an open of a page here.
if [ -n "$from_peer" ]; then
  fp_m="${from_peer%%:*}"; fp_l="${from_peer#*:}"
  case "$fp_m:$fp_l" in *[!A-Za-z0-9._:-]*|:*|*:) echo 'fleet-open: --from-peer <machine>:<login>' >&2; exit 1 ;; esac
  if [ "$kind" = forward ]; then
    fp_r=$(printf '%s' "$json" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["rport"])')
    if [ -n "${FLEET_OPEN_FWD_CMD:-}" ]; then fp_p=$($FLEET_OPEN_FWD_CMD "$fp_m" "$fp_l" "$fp_r" 2>/dev/null)
    else fp_p=$("$PY" "$BIN/fleet-peerlink.py" fwd "$fp_m" "$fp_l" "$fp_r" 2>/dev/null); fi
    case "$fp_p" in ''|*[!0-9]*)
      printf 'fleet-open: 没能从 %s 转发 %s 的端口 %s（这台到它的连接不在）\n' "$(hostname -s)" "$fp_m" "$fp_r" >&2
      finish "failed:no link from the home to $fp_m" "$kind" ;;
    esac
    json=$(printf '%s' "$json" | "$PY" -c 'import json,sys
d = json.load(sys.stdin); d["rport"] = int(sys.argv[1]); d["node"] = sys.argv[2]
print(json.dumps(d, separators=(",", ":"), ensure_ascii=False))' "$fp_p" "$fp_m") || exit 1
    fallback_url="http://127.0.0.1:$fp_p$(printf '%s' "$json" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["path"])')"
    printf 'fleet-open: %s:%s → 本机 :%s（经到 %s 的连接）\n' "$fp_m" "$fp_r" "$fp_p" "$fp_m" >&2
  fi
  # this machine's fleet session, with no pane of ours: the first live one
  if [ -z "${TMUX:-}" ] && [ -f "$BIN/fleet-lib.sh" ]; then
    # shellcheck source=/dev/null
    . "$BIN/fleet-lib.sh" 2>/dev/null
    FC_SESS=$(fleet_sockets 2>/dev/null | head -n 1)
    [ -n "$FC_SESS" ] && FP_SOCK=$(fleet_socket "$FC_SESS") && tmux() { command tmux -L "$FP_SOCK" "$@"; }
  fi
fi

# ---- the agent's browser (issue #3236) ---------------------------------------
cport=$(printf '%s' "$json" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("cport") or "")
except Exception: print("")' 2>/dev/null)
RV_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/remote-views"
who_am_i() {  # the session asking, as the person reads it on their screen
  local w=''
  [ -n "${TMUX_PANE:-}" ] && w=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
  [ -z "$w" ] && [ -n "$from_peer" ] && w="${from_peer%%:*}"
  printf '%s' "${w:-?}"
}
# A receipt-less road: say where the link is, then `unconfirmed`.
unconfirmed() {  # <road words>
  local link="${tailnet_link:-$fallback_url}"
  printf 'fleet-open: %s — 没有回执，确认不了打开了；链接：%s\n' "$1" "$link" >&2
  finish unconfirmed "$kind"
}
# thin_open — OSC 7502 `open` on the tty of the thin 看台 the person is at, with
# its connection's token (约定 10: a 7502 without it does nothing): its loop
# forwards (a loopback page; an OAuth `cport`) over its own line, opens, and sends
# the receipt back (`--ack`, issue #3538). rc 1 = no such 看台 here (one from another
# home: `-via-` — via_relay below).
thin_open() {
  [ -d "$RV_DIR" ] || return 1
  # shellcheck source=/dev/null
  . "$BIN/fleet-client-lib.sh" || return 1
  [ -n "${FC_SESS:-}" ] || fc_session || return 1
  local rows row ttyp tok
  rows=$(awk -F '\t' -v s="$FC_SESS" '$2 == s && $3 == "thin" && FILENAME !~ /-via-[^\/]*$/ { print }' "$RV_DIR"/* 2>/dev/null)
  [ -n "$rows" ] || return 1
  # the client the person is at: the newest — a home's far 看台 newer than ours is
  # via_relay's, never an older 看台 of ours
  ttyp=$(fc_clients '#{client_activity}	#{client_tty}' | sort -t '	' -k1,1nr | head -n 1 | cut -f2)
  row=$(printf '%s\n' "$rows" | awk -F '\t' -v t="$ttyp" '$1 == t { print; exit }')
  [ -n "$row" ] || return 1
  tok=$(printf '%s\n' "$row" | tr '\t' '\n' | sed -n 's/^token=//p' | head -n 1)
  THIN_DEV=$(printf '%s\n' "$row" | tr '\t' '\n' | sed -n 's/^device=//p' | head -n 1)
  THIN_DEV=$(printf '%s' "$THIN_DEV" | "$PY" -c 'import base64,json,sys
try: print(json.loads(base64.urlsafe_b64decode(sys.stdin.read().strip().replace("+", "-").replace("/", "_") + "==")).get("device") or "")
except Exception: print("")' 2>/dev/null)
  case "$tok" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  case "$ttyp" in /dev/*) ;; *) return 1 ;; esac
  "$PY" - "${FLEET_THIN_OPEN_OUT:-$ttyp}" "$tok" "$json" "$(who_am_i)" "${FLEET_OPEN_CALLBACK_SECS:-600}" <<'PY'
import base64, json, os, sys
out, tok, js, who, ttl = sys.argv[1:6]
d = json.loads(js)
d["who"], d["ttl"] = who[:80], int(ttl or 600)
b = base64.b64encode(json.dumps(d, separators=(",", ":"), ensure_ascii=False).encode()).decode()
fd = os.open(out, os.O_WRONLY | os.O_NOCTTY | os.O_APPEND | (os.O_CREAT if not out.startswith("/dev/") else 0), 0o600)
try:
    os.write(fd, ("\x1b]7502;open;token=%s;j=%s\x07" % (tok, b)).encode())
finally:
    os.close(fd)
PY
}
# thin_result — after thin_open: the loop's receipt → the result line.
thin_result() {
  local dev="${THIN_DEV:-?}"
  if wait_ack "$OPEN_ID"; then
    if [ "$ACK_STATE" = ok ]; then
      printf 'fleet-open: %s → 客户端 %s（瘦客户端，已打开%s）\n' "$kind" "$dev" "${cport:+，转发回调端口 $cport}" >&2
      finish opened "$kind"
    fi
    printf 'fleet-open: 客户端 %s 没打开：%s\n' "$dev" "${ACK_WHY:-?}" >&2
    finish "failed:${ACK_WHY:-the client could not open it}" "$kind"
  fi
  unconfirmed "交给了客户端 ${dev}（瘦客户端），${FLEET_OPEN_ACK_WAIT:-12} 秒内没等到它的回执（它可能是旧版本）"
}
# via_relay — the person's newest client here is ANOTHER machine's 看台
# (`<id>-via-<home>`, C4): hand the open to that home over our peer link; its result
# line is ours. rc 1 = no such 看台, or the home could not be asked (an older home
# without --from-peer included) — the roads below, as before.
via_relay() {
  [ -z "$from_peer" ] && [ -d "$RV_DIR" ] || return 1
  # shellcheck source=/dev/null
  . "$BIN/fleet-client-lib.sh" || return 1
  [ -n "${FC_SESS:-}" ] || fc_session || return 1
  local newest f home node me u out rc res
  newest=$(fc_clients '#{client_activity}	#{client_tty}' | sort -t '	' -k1,1nr | head -n 1 | cut -f2)
  [ -n "$newest" ] || return 1
  f=$(awk -F '\t' -v t="$newest" '$1 == t && $3 == "thin" && FILENAME ~ /-via-[^\/]*$/ { print FILENAME; exit }' "$RV_DIR"/* 2>/dev/null)
  [ -n "$f" ] || return 1
  home="${f##*-via-}"
  node=$(tr '\t' '\n' < "$f" | sed -n 's/^node=//p' | head -n 1)
  [ -n "$node" ] || node=$(hostname -s)
  me=$(id -un)
  case "$home:$node:$me" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
  if [ "$kind" = forward ]; then
    u=$(printf '%s' "$json" | "$PY" -c 'import json,sys; d = json.load(sys.stdin)
print("%s://127.0.0.1:%d%s" % (d.get("scheme") or "http", d["rport"], d.get("path") or "/"))')
  else
    u="$fallback_url"
  fi
  local rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
  if [ -n "${FLEET_OPEN_RELAY_CMD:-}" ]; then
    out=$($FLEET_OPEN_RELAY_CMD "$home" bash "$rbin/fleet-open.sh" --from-peer "$node:$me" -- "$u"); rc=$?
  else
    out=$("$PY" "$BIN/fleet-peerlink.py" exec "$home" -- bash "$rbin/fleet-open.sh" --from-peer "$node:$me" -- "$u"); rc=$?
  fi
  res=$(printf '%s\n' "$out" | tail -n 1)
  case "$res" in
    opened|unconfirmed|failed:*) ;;
    *) printf 'fleet-open: 经 %s 没送到（%s）— 改走老路\n' "$home" "${res:-rc=$rc}" >&2; return 1 ;;
  esac
  printf 'fleet-open: %s → 经 %s 的看台\n' "$kind" "$home" >&2
  finish "$res" "$kind"
}

# Where the person is comes from fleet-client-where.sh alone (EPIC #1710 rule 7).
# A client holding the hub's lease → the action goes to IT, through the hub, and it
# opens the page on the device in their hands (a loopback page forwarded over its
# own ssh first; a phone gets a link to tap) and answers done/failed. No hub, and the
# one client here runs on this computer's own screen → open it right here. A thin
# client (its home holds the lease) → its loop, here or through its home. Anything
# else (nobody connected, a hub that cannot be asked, the client refused it) → the
# roads below.
if [ "${FLEET_OPEN_CLIENT:-1}" != 0 ]; then
  if [ -n "${FLEET_OPEN_WHERE_CMD:-}" ]; then cw=$($FLEET_OPEN_WHERE_CMD --json 2>/dev/null) || :
  else cw=$(bash "$BIN/fleet-client-where.sh" --json 2>/dev/null) || :; fi
  cw_src=$(printf '%s' "$cw" | "$PY" -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
print("%s %s %s" % (d.get("source") or "-", d.get("state") or "-", d.get("via") or "-"))' 2>/dev/null)
  case "$cw_src" in
    # a thin client (issue #3005, EPIC #2999 C8): its home machine holds the lease
    # and runs no action loop — its loop is told directly, on this machine's 看台
    # or through the home's (issue #3538; fleet-browser no longer gates it)
    "hub active thin"|"local active thin")
      thin_open && thin_result
      via_relay ;;
    "hub active "*)
      # fleet-open-addr.py's payload as it is: forward → rport/path/scheme, url → url
      res=$("$PY" "${FLEET_OPEN_ACTIONS_BIN:-$BIN/fleet-client-actions.py}" send --kind open_url \
              --from-addr "$json" --url "$fallback_url" --tailnet-link "$tailnet_link" ${cport:+--who "$(who_am_i)"} \
              --wait "${FLEET_OPEN_CLIENT_WAIT:-${FLEET_OPEN_ACK_WAIT:-12}}" 2>/dev/null) || res=''
      st=$(printf '%s' "$res" | "$PY" -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
c = d.get("client") or {}
print("%s\t%s\t%s" % (d.get("state") or "", c.get("device") or "", d.get("result") or ""))' 2>/dev/null)
      st_state=${st%%	*}; st_dev=$(printf '%s' "$st" | cut -f2); st_res=$(printf '%s' "$st" | cut -f3)
      case "$st_state:$st_res" in
        done:opened)
          printf 'fleet-open: %s → 客户端 %s（已打开）\n' "$kind" "$st_dev" >&2
          finish opened "$kind" ;;
        done:link:*)
          printf 'fleet-open: %s → 客户端 %s：链接已放在它的底栏，等人去点\n' "$kind" "$st_dev" >&2
          finish unconfirmed "$kind" ;;
        done:*) unconfirmed "交给了客户端 ${st_dev}（${st_res:-?}）" ;;
        queued:*) unconfirmed "客户端 $st_dev 已排队，稍后打开" ;;
        failed:*)
          printf 'fleet-open: 客户端 %s 没打开（%s）\n' "$st_dev" "$st_res" >&2
          finish "failed:${st_res:-the client could not open it}" "$kind" ;;
      esac ;;
    "local active local")
      lopen="${FLEET_OPEN_LOCAL_CMD:-}"
      [ -n "$lopen" ] || { [ "$(uname -s)" = Darwin ] && lopen=open || lopen=xdg-open; }
      if "$lopen" "$fallback_url" >/dev/null 2>&1; then
        printf 'fleet-open: %s → 本机（客户端就在这台电脑上）\n' "$kind" >&2
        finish opened "$kind"
      fi ;;
  esac
fi
# A home asked by a peer has no other road: what it could not hand its own 看台 is
# the asker's to say (its old roads still run there).
[ -z "$from_peer" ] || { thin_open && thin_result; finish 'failed:no thin client of the person on the home' "$kind"; }
# No lease word at all (no hub): the person's newest client may still be a home's 看台.
via_relay

# ---- the secret: 0600, made once ---------------------------------------------------
ensure_secret() {
  local d; d="$(dirname "$SECRET")"
  if [ ! -s "$SECRET" ]; then
    mkdir -p "$d" 2>/dev/null || return 1
    ( umask 077
      tmp="$(mktemp "$d/.open.secret.XXXXXX")" || exit 1
      "$PY" -c 'import secrets; print(secrets.token_hex(32))' > "$tmp" && mv -f "$tmp" "$SECRET" \
        || { rm -f "$tmp"; exit 1; } ) || return 1
  fi
  chmod 600 "$SECRET" 2>/dev/null
  [ -s "$SECRET" ]
}

fallback() {  # <why> — open-url.sh: the 2226 tunnel, else a popup + OSC 52
  local res rport
  printf 'fleet-open: not sent to the operator'"'"'s iTerm2 — %s\n' "$1" >&2
  case "$fallback_url" in http://127.0.0.1:*|https://127.0.0.1:*)
    rport="${fallback_url#*://127.0.0.1:}"; rport="${rport%%/*}"
    printf 'fleet-open: %s is on THIS machine — from the operator'"'"'s computer it needs `ssh -L %s:127.0.0.1:%s <this host>`\n' \
      "$fallback_url" "$rport" "$rport" >&2 ;;
  esac
  res=$(OPEN_URL_REPORT=1 sh "${FLEET_OPEN_URL_BIN:-$BIN/open-url.sh}" "$fallback_url" 2>/dev/null | tail -n 1)
  case "$res" in
    sent:tunnel) unconfirmed 'open-url.sh 的反向隧道接走了' ;;
    *) unconfirmed '复制到了对方剪贴板（open-url.sh）' ;;
  esac
}

[ "${FLEET_OPEN:-1}" = 0 ] && fallback 'FLEET_OPEN=0'
[ -n "${TMUX:-}" ] || fallback 'not inside tmux'
ensure_secret || fallback "cannot create $SECRET"

# shellcheck source=/dev/null
. "$BIN/fleet-client-lib.sh"
fc_session || fallback "$FC_WHY"

# The operator is looking through a PROXY WINDOW on another machine (issue #1424):
# this session's newest client is that proxy's ssh, registered by
# fleet-remote-view.sh attach. The operator's iTerm2 trusts only that machine's
# secret, and an escape would have to cross its tmux too — so the request goes in
# the view's spool and the proxy re-issues it there. No views dir: nothing changes.
RV_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/remote-views"
if [ -z "$client" ] && [ -d "$RV_DIR" ]; then
  _newest=$(fc_clients '#{client_activity}	#{client_tty}' \
    | sort -t '	' -k1,1nr | head -n 1 | cut -f2)
  # a thin 看台 (kind thin, issue #3005) has no spool: its terminal is written directly
  _view=$(awk -F '\t' -v t="$_newest" -v s="$FC_SESS" '$1 == t && $2 == s && $3 != "thin" { n = FILENAME; sub(/.*\//, "", n); print n; exit }' \
    "$RV_DIR"/* 2>/dev/null)
  if [ -n "$_newest" ] && [ -n "$_view" ] && [ -d "$RV_DIR/$_view.d" ]; then
    _rq="$RV_DIR/$_view.d/$(date +%s)-$$"
    if ( umask 077; printf '%s\n' "$json" > "$_rq.tmp" ) && mv -f "$_rq.tmp" "$_rq.json"; then
      printf 'fleet-open: %s → proxy view %s (%s)\n' "$kind" "$_view" "$_newest" >&2
      unconfirmed "交给了代理窗口 $_view"
    fi
    rm -f "$_rq.tmp"
  fi
fi

# Another home's window onto this machine (EPIC #2999 C4: a thin 看台 `<id>-via-<home>`,
# its client the home's ssh pane): the escape crosses the home's tmux as passthrough,
# and that client's terminal word is the home's tmux, never the person's — named here.
PT=0
if [ -z "$client" ] && [ -d "$RV_DIR" ]; then
  _newest=$(fc_clients '#{client_activity}	#{client_tty}' | sort -t '	' -k1,1nr | head -n 1 | cut -f2)
  if [ -n "$_newest" ] && awk -F '\t' -v t="$_newest" '$1 == t && $3 == "thin" && FILENAME ~ /-via-[^\/]*$/ { f = 1 } END { exit !f }' \
       "$RV_DIR"/* 2>/dev/null; then
    client="$_newest"; PT=1
  fi
fi
fc_pick "$client" "$TERM_RE" || fallback "$FC_WHY"
fc_lock || fallback "$FC_WHY"
job=$(mktemp -d "${TMPDIR:-/tmp}/fleet-show.XXXXXX") || { fc_unlock; fallback 'mktemp failed'; }
trap 'rm -rf "$job"; fc_unlock' EXIT
status="$job/status"; : > "$status"

# The escape is built into a 0600 file in the job dir, so the secret never reaches
# an argv (`ps`) or the tmux lock-command string.
( umask 077
  "$PY" -c '
import base64, sys
secret = open(sys.argv[1]).read().strip()
payload = base64.b64encode(sys.argv[3].encode()).decode()
esc = f"\033]1337;Custom=id={secret}:{payload}\a"
if sys.argv[4] == "1":   # through one more tmux: its passthrough, every ESC doubled
    esc = "\033Ptmux;" + esc.replace("\033", "\033\033") + "\033\\"
open(sys.argv[2], "wb").write(esc.encode())
' "$SECRET" "$job/escape" "$json" "$PT"
) || fallback 'cannot build the escape'

cmd="exec $(fc_sq "$PY") $(fc_sq "$BIN/fleet-show-send.py") --raw --out $(fc_sq "${FLEET_SHOW_OUT:-/dev/tty}") --status $(fc_sq "$status") $(fc_sq "$job/escape")"
fc_run "$cmd" || fallback "$FC_WHY"
fc_wait "$status" 10 || fallback "the client did not finish within 10s (status: $(tr '\n' ' ' < "$status"))"
grep -q '^ok	' "$status" || fallback "the sender failed: $(grep '^err' "$status" | head -n 1 | cut -f2)"

printf 'fleet-open: %s → %s%s\n' "$kind" "$FC_CLIENT" "${FC_TERMTYPE:+ [$FC_TERMTYPE]}" >&2
# iTerm2 took the escape; whether their side (#1380) opened it, nothing says yet (#3540).
unconfirmed "写到了 iTerm2（${FC_CLIENT}）"
