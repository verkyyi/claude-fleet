#!/bin/bash
# fleet-open.sh <url | :port[/path] | file> [--client <tty>] [--print] — open a link
# or a page served HERE on the operator's OWN computer (issue #1379).
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
#   No receipt yet: iTerm2 accepting the escape is `sent:iterm2` even when the
# laptop side is not installed (iTerm2 drops an unknown Custom= silently).
# `fleet-doctor`'s `open` line shows the secret + the last result.
#
# Prints ONE result line:
#   sent:iterm2      written to the operator's iTerm2               exit 0
#   sent:proxy       handed to the proxy window the operator is viewing this
#                    session through, from another machine (#1424)  exit 0
#   sent:tunnel      open-url.sh's reverse-tunnel opener took it   exit 0
#   fallback:copied  copied to their clipboard + one line saying so exit 0
#   fallback:path    a file fleet-show could not send (PATH line above) exit 2
# exit 1 = usage / an address it cannot parse.
#
# Knobs (fleet.conf or the fleet's conf; env wins):
#   FLEET_OPEN=0               never write the escape; straight to open-url.sh
#   FLEET_OPEN_SSH_HOST        this machine's ssh alias, a hint in the payload
#   FLEET_SHOW_TERM_RE         shared with fleet-show (default ^iTerm2)
#   FLEET_OPEN_SECRET_FILE     (selftests) the secret's path
#   FLEET_OPEN_URL_BIN         (selftests) the fallback opener
#   FLEET_SHOW_OUT             (selftests) where the sender writes instead of /dev/tty
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
  printf '  --client <tty> send to this tmux client (skips the iTerm2 match)\n'
  printf '  --print        print the payload JSON and stop (sends nothing)\n'
}

target=""; client=""; print=0
while [ $# -gt 0 ]; do
  case "$1" in
    --client) client="${2:-}"; shift ;;
    --client=*) client="${1#--client=}" ;;
    --print) print=1 ;;
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

# ---- a file → fleet-show --------------------------------------------------------
case "$target" in file://*) f="${target#file://}"; [ -f "$f" ] && target="$f" ;; esac
if [ -f "$target" ]; then
  out=$("$BIN/fleet-show.sh" ${client:+--client "$client"} -- "$target"); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  case "$rc" in
    0) record sent:iterm2 file; echo 'sent:iterm2'; exit 0 ;;
    2) record fallback:path file; printf '%s\n' "$out" | grep '^PATH '; echo 'fallback:path'; exit 2 ;;
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
kind="${addr%%	*}"; rest="${addr#*	}"; json="${rest%%	*}"; fallback_url="${rest#*	}"
[ "$print" = 1 ] && { printf '%s\n' "$json"; exit 0; }

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
  case "$res" in sent:tunnel|fallback:copied) ;; *) res=fallback:copied ;; esac
  record "$res" "$kind"
  echo "$res"
  exit 0
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
  _view=$(awk -F '\t' -v t="$_newest" -v s="$FC_SESS" '$1 == t && $2 == s { n = FILENAME; sub(/.*\//, "", n); print n; exit }' \
    "$RV_DIR"/* 2>/dev/null)
  if [ -n "$_newest" ] && [ -n "$_view" ] && [ -d "$RV_DIR/$_view.d" ]; then
    _rq="$RV_DIR/$_view.d/$(date +%s)-$$"
    if ( umask 077; printf '%s\n' "$json" > "$_rq.tmp" ) && mv -f "$_rq.tmp" "$_rq.json"; then
      printf 'fleet-open: %s → proxy view %s (%s)\n' "$kind" "$_view" "$_newest" >&2
      record sent:proxy "$kind"
      echo 'sent:proxy'
      exit 0
    fi
    rm -f "$_rq.tmp"
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
open(sys.argv[2], "wb").write(f"\033]1337;Custom=id={secret}:{payload}\a".encode())
' "$SECRET" "$job/escape" "$json"
) || fallback 'cannot build the escape'

cmd="exec $(fc_sq "$PY") $(fc_sq "$BIN/fleet-show-send.py") --raw --out $(fc_sq "${FLEET_SHOW_OUT:-/dev/tty}") --status $(fc_sq "$status") $(fc_sq "$job/escape")"
fc_run "$cmd" || fallback "$FC_WHY"
fc_wait "$status" 10 || fallback "the client did not finish within 10s (status: $(tr '\n' ' ' < "$status"))"
grep -q '^ok	' "$status" || fallback "the sender failed: $(grep '^err' "$status" | head -n 1 | cut -f2)"

printf 'fleet-open: %s → %s%s\n' "$kind" "$FC_CLIENT" "${FC_TERMTYPE:+ [$FC_TERMTYPE]}" >&2
record sent:iterm2 "$kind"
echo 'sent:iterm2'
