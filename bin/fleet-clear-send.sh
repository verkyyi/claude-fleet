#!/bin/bash
# fleet-clear-send.sh <ID | code> [--socket L] [--timeout S] [--by WHO]
#   — run `/clear` in ANOTHER session, by its ID (T592; `fleet-id.sh clear` is the
#   same thing, the `clear` tool of `fleet-orch` its MCP road).
#
# The sanctioned road for «clear that session's context» — the hand-typed
# `FLEET_ALLOW_SENDKEYS=1 tmux send-keys … /clear` it replaces is what
# hooks/bash-guard.py refuses. Same shape as fleet-compact-send.sh (/compact) and
# fleet-model-switch.sh (/model): find the window, gate, deliver, verify.
#
#   find     the address goes through fleet_win_for_addr — a full ID or its short
#            code (`K3F9`, any case; the old `T-<code>` for one version) — on --socket, else this
#            pane's server, else every fleet socket of this login. Only THIS
#            machine: an ID no window here carries is refused (rc 1), never sent
#            over another road; two windows (or two IDs) answering ⇒ rc 2, the
#            candidates on stderr, never a pick.
#   gate     only an agent pane (@cc_agent claude | codex) whose @claude_state says
#            its turn is over (done · idle). working / needs (a dialog is open — the
#            keys would land in it) / looping (a loop is pending) / exited / unknown
#            ⇒ refused, nothing typed (rc 3). A client at that window with a
#            keypress within FLEET_HANDOFF_DEFER_SECS (30) ⇒ refused (rc 5): never
#            type over a person's draft.
#   deliver  through the fleet mod's command inbox first (fleet_session_command,
#            STATE.md «The command inbox»), else keystrokes — text and Enter as
#            SEPARATE send-keys calls. The agents differ only here (the adapter,
#            `_keys_<agent>`): Claude gets an Escape first (dismiss a palette) and
#            a 0.3 s gap; Codex no Escape (twice is its «edit previous message») and
#            a 1 s gap (its paste-burst guard reads a fast Enter as a newline).
#   verify   the ID's ledger (bin/fleet_id.py) gains a native segment — the
#            SessionStart(source=clear) hook writes it, trigger `clear` (Codex `new`
#            counts) — within --timeout (FLEET_CLEAR_VERIFY_SECS, 30). No segment ⇒
#            rc 4: sent, unconfirmed (never typed twice).
#
# One line on stdout: `cleared <code> <ID> seg <n> (<trigger>) via <mod|send-keys>`,
# or the refusal on stderr. Every attempt — refused, sent, confirmed — appends one
# audit line to $FLEET_CONF_DIR/logs/clear-send.log: when · by whom (--by, else
# the calling window's code / ID, else $USER) · which ID · window · agent · outcome.
#
# Exit: 0 cleared · 1 no such ID / no window here · 2 usage / ambiguous ·
#       3 refused, not idle (nothing typed) · 4 sent, unconfirmed · 5 a person is typing
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

addr='' sock='' timeout="${FLEET_CLEAR_VERIFY_SECS:-30}" by=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket)  sock="${2:-}"; shift 2 ;;
    --timeout) timeout="${2:-}"; shift 2 ;;
    --by)      by="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    -*) printf 'fleet-clear: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) [ -z "$addr" ] || { printf 'fleet-clear: one address only\n' >&2; exit 2; }
       addr=$1; shift ;;
  esac
done
[ -n "$addr" ] || { printf 'usage: fleet-clear-send.sh <ID | code> [--socket L] [--timeout S] [--by WHO]\n' >&2; exit 2; }
case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
DEFER="${FLEET_HANDOFF_DEFER_SECS:-30}"
case "$DEFER" in ''|*[!0-9]*) DEFER=30 ;; esac
# A bare word is a short code (`K3F9`, any case — C11; the old `T-…` as written).
fleet_is_fid "$addr" || fleet_is_idcode "$addr" || { printf 'fleet-clear-send: %s is no ID or short code\n' "$addr" >&2; exit 1; }

if [ -z "$by" ]; then
  if [ -n "${TMUX_PANE:-}" ]; then
    by=$(tmux display-message -p -t "$TMUX_PANE" '#{@task_short} #{@fleet_id}' 2>/dev/null | awk '{print ($1 != "" ? $1 : $2)}')
  fi
  [ -n "$by" ] || by="${USER:-?}"
fi

LOGD="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs"
FID='' WIN='' AGENT='-'
audit() {
  mkdir -p "$LOGD" 2>/dev/null && printf '%s by=%s id=%s addr=%s window=%s agent=%s %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" "$by" "${FID:--}" "$addr" "${WIN:--}" "$AGENT" "$1" \
    >> "$LOGD/clear-send.log" 2>/dev/null
  return 0
}
die() { local rc=$1; shift; printf 'fleet-clear: %s\n' "$1" >&2; audit "refused rc=$rc: $1"; exit "$rc"; }

# ---- find --------------------------------------------------------------------------
socks=''
if [ -n "$sock" ]; then socks=$sock
elif [ -n "${TMUX:-}" ]; then socks=$(basename "${TMUX%%,*}")
else socks=$(fleet_sockets 2>/dev/null); fi
[ -n "$socks" ] || die 1 "no fleet tmux server on this machine to look in"
hit='' err=''
while IFS= read -r s; do
  [ -n "$s" ] || continue
  w=$(fleet_win_for_addr "$addr" "$s" 2>"${TMPDIR:-/tmp}/fleet-clear.$$"); rc=$?
  e=$(cat "${TMPDIR:-/tmp}/fleet-clear.$$" 2>/dev/null); rm -f "${TMPDIR:-/tmp}/fleet-clear.$$"
  case "$rc" in
    0) [ -z "$hit" ] || die 2 "$addr answers on two servers ($hit, $s:$w) — name the full ID"
       hit="$s:$w" ;;
    2) err=${e:-"$addr is ambiguous"}; die 2 "$err" ;;
  esac
done <<EOF
$socks
EOF
[ -n "$hit" ] || die 1 "no window on this machine carries $addr (a session on another machine: clear it there — no cross-machine road)"
sock=${hit%%:*} WIN=${hit#*:}
tm() { tmux -L "$sock" "$@"; }
IFS='|' read -r FID PANE AGENT st short <<EOF
$(tm display-message -p -t "$WIN" '#{@fleet_id}|#{pane_id}|#{@cc_agent}|#{@claude_state}|#{@task_short}' 2>/dev/null)
EOF
# the code as today's ledger reads it (an old window's @task_short may still say `T-…`)
fleet_is_fid "${FID:-}" && short=$(bash "$BIN/fleet-id.sh" short "$FID" 2>/dev/null) || :
[ -n "${AGENT:-}" ] || AGENT=claude   # a Claude window stamps no @cc_agent on older launches
case "$AGENT" in claude|codex) : ;; *) die 3 "$WIN is no agent session (@cc_agent=$AGENT)" ;; esac
[ -n "${PANE:-}" ] || die 1 "window $WIN has no pane"
[ "${TMUX_PANE:-}" != "$PANE" ] || die 3 "that is this session — /clear yourself by hand"

# ---- gate --------------------------------------------------------------------------
case "${st:-}" in
  done|idle) : ;;
  working) die 3 "${short:-$FID} is working — /clear only once its turn is over" ;;
  needs)   die 3 "${short:-$FID} is waiting on a question/permission — answer it first (answer_dialog)" ;;
  looping) die 3 "${short:-$FID} has a loop pending — /clear would drop it" ;;
  *)       die 3 "${short:-$FID} is not idle (@claude_state=${st:-unset})" ;;
esac
if [ "$DEFER" -gt 0 ]; then
  now=$(date +%s)
  held=$(tm list-clients -F '#{client_activity} #{window_id}' 2>/dev/null \
    | awk -v w="$WIN" -v now="$now" -v ds="$DEFER" '$2 == w && $1 ~ /^[0-9]+$/ && (now - $1) <= ds { print 1; exit }')
  [ "$held" != 1 ] || die 5 "a person is typing at ${short:-$FID} (a keypress within ${DEFER}s) — not typing over it"
fi

segn() { python3 "$BIN/fleet_id.py" get "$FID" --json 2>/dev/null | python3 -c 'import json,sys
try: s=json.load(sys.stdin).get("segments") or []
except ValueError: s=[]
print("%d %s" % (len(s), s[-1].get("trigger","") if s else ""))' 2>/dev/null || echo '0 '; }
read -r n0 _ <<EOF
$(segn)
EOF

# ---- deliver (the adapter: what differs between the agents) -------------------------
_keys_claude() {
  FLEET_ALLOW_SENDKEYS=1 tm send-keys -t "$PANE" Escape 2>/dev/null
  sleep 0.3 2>/dev/null || sleep 1
  FLEET_ALLOW_SENDKEYS=1 tm send-keys -t "$PANE" -l -- /clear 2>/dev/null
  sleep 0.3 2>/dev/null || sleep 1
  FLEET_ALLOW_SENDKEYS=1 tm send-keys -t "$PANE" Enter 2>/dev/null
}
_keys_codex() {
  FLEET_ALLOW_SENDKEYS=1 tm send-keys -t "$PANE" -l -- /clear 2>/dev/null
  sleep "${FLEET_CLEAR_CODEX_GAP:-1}"
  FLEET_ALLOW_SENDKEYS=1 tm send-keys -t "$PANE" Enter 2>/dev/null
}
rc=3
[ "$AGENT" = codex ] || { fleet_session_command --socket "$sock" --from clear-send "$PANE" /clear </dev/null >/dev/null 2>&1; rc=$?; }
case "$rc" in
  0|6) via=mod ;;
  *) via=send-keys; "_keys_$AGENT" ;;
esac

# ---- verify ------------------------------------------------------------------------
deadline=$(( $(date +%s) + timeout ))
while :; do
  read -r n1 trig <<EOF
$(segn)
EOF
  if [ "${n1:-0}" -gt "${n0:-0}" ]; then
    line="cleared ${short:-$FID} $FID seg $n1 (${trig:-?}) via $via"
    printf '%s\n' "$line"; audit "$line"; exit 0
  fi
  [ "$(date +%s)" -lt "$deadline" ] || break
  sleep 1
done
line="sent /clear to ${short:-$FID} via $via, but no new segment on its ledger within ${timeout}s — unconfirmed (not typed again)"
printf 'fleet-clear: %s\n' "$line" >&2; audit "unconfirmed: $line"
exit 4
