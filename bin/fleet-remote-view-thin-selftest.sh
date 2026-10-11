#!/bin/bash
# fleet-remote-view-thin-selftest.sh — the thin client's 看台 (issue #2763, EPIC
# #2999 C1, 共同约定 6): bin/fleet-remote-view.sh `attach --thin` and the top line
# it wears, bin/fleet-topbar.py `render --node`.
#
# Two ISOLATED tmux servers: NODE (`-L <its session>`, the home machine's fleet —
# fleet_socket is the session name) and TERM (`-L tvT<pid>`), whose pane is the
# person's terminal: it runs the attach the way ssh -tt would, with $TMUX unset.
#   Z. degenerate — a plain attach (no --thin), a view attach and a person's
#                   direct attach leave the server's global options, window
#                   options, hooks and key tables byte for byte as they were
#   A. attach     — `attach --thin` makes `<fleet>@view-<id>`: status on, at the
#                   top, every 2 s, its line `fleet-topbar.py render --node`, no
#                   destroy-unattached; it lands on the orchestrator's window (no
#                   cur= to go back to); registry row kind `thin` with cur= route=
#                   device= token= fuid=; the fleet session's own options and the
#                   global options / key tables untouched (only the [78] hook)
#   B. the line   — the client's screen's first line is the top line; for a window
#                   of this machine its own stamps: #7 · 剩余 62% · Opus 5.5 · high ·
#                   @<machine> · the route; for one on the refresh loop's cache its
#                   line (title, needs kind); at 40 columns (a phone, #3006) no
#                   剩余 · model · effort
#   C. cur=       — switching windows in the 看台 moves `cur=` (the [78] hook, gated
#                   on @view_thin: a switch in the fleet session writes nothing)
#   D. keep       — the client gone: the 看台 and its row stay (left=), `health`
#                   counts no orphan; `--resume` comes back to the same session on
#                   the same window
#   E. reap       — past FLEET_VIEW_KEEP_SECS `prune` takes row and session; a
#                   `--resume` then lands home (no cur= left); `--want` lands on
#                   the worker it names
#   K. key table  — `key-table fleet-view` only once that table exists (C2)
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-remote-view-thin selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-remote-view-thin selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/frvt-st.XXXXXX")" || exit 2
RS="tvR$$"; TL="tvT$$"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/control" "$FLEET_CONF_DIR/fleets/$RS"
export FLEET_SIDEBAR_HOST=nodebox FLEET_NODE_ALIASES='nodebox=m9'
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_VIEW_KEEP_SECS

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
tn() { "$REAL_TMUX" -L "$RS" "$@"; }
tt() { "$REAL_TMUX" -L "$TL" "$@"; }
waitfor() {  # <secs> <cmd…> — until the command succeeds
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
cleanup() {
  "$REAL_TMUX" -L "$TL" kill-server 2>/dev/null
  "$REAL_TMUX" -L "$RS" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- the node's fleet: a conf + a machine id ⇒ a fleet UUID ------------------------
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$WORK/main" > "$FLEET_CONF_DIR/fleets/$RS/conf"
python3 - "$FLEET_CONF_DIR/control/state.sqlite3" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT)")
c.execute("INSERT INTO metadata VALUES ('machine_id', '0b8e2f3a-7c1d-4e5f-9a6b-1c2d3e4f5a6b')"); c.commit()
PY
U=$(. "$BIN/fleet-lib.sh"; fleet_uuid "$RS")
[ -n "$U" ] || { printf 'FAIL: rig: no fleet UUID for %s\n' "$RS" >&2; exit 1; }

tn -f /dev/null new-session -d -s "$RS" -n home -x 200 -y 50 'while :; do sleep 300; done' 2>/dev/null \
  || { printf 'fleet-remote-view-thin selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }
tn set-option -g status off
OW=$(tn new-window -d -P -F '#{window_id}' -t "$RS:" -n orchestrator 'while :; do sleep 300; done')
tn set-window-option -t "$OW" @fleet_role orchestrator \; set-window-option -t "$OW" @fleet_id fid-orch
W7=$(tn new-window -d -P -F '#{window_id}' -t "$RS:" -n worker7 'while :; do sleep 300; done')
NOW=$(date +%s)
tn set-window-option -t "$W7" @fleet_role worker \; set-window-option -t "$W7" @fleet_id fid-7 \; \
  set-window-option -t "$W7" @issue 7 \; set-window-option -t "$W7" @claude_state working \; \
  set-window-option -t "$W7" @ctx_left 62 \; set-window-option -t "$W7" @ctx_band ok \; \
  set-window-option -t "$W7" @ctx_ts "$NOW" \; set-window-option -t "$W7" @model 'Opus 5.5' \; \
  set-window-option -t "$W7" @effort high
W8=$(tn new-window -d -P -F '#{window_id}' -t "$RS:" -n worker8 'while :; do sleep 300; done')
tn set-window-option -t "$W8" @fleet_role worker \; set-window-option -t "$W8" @fleet_id fid-8 \; set-window-option -t "$W8" @issue 8
tn select-window -t "=$RS:home"
G="$TMPDIR/.claude-dash/global"; mkdir -p "$G"
US=$'\037'
# the refresh loop's line for worker 8 (cache_record's columns; 21-25 the bus)
{ printf '#ts%s%s\n' "$US" "$NOW"
  printf 'wid:%s/fid-8%sm9%sonline%s8%sacme/app%sneeds%sclaude%sworker8%s%sperm%s%s%s%s%s%s%s修缓存%s%s%s%s40%swatch%s%s%sSonnet 5.5%smedium\n' \
    "$U" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$NOW" "$US" "$US"
} > "$G/remote_$RS"

globals() { tn show-options -g; tn show-options -gw; tn show-options -gs; tn show-hooks -g; tn list-keys; }
fleetopts() { tn show-options -t "=$RS:"; }
vs() { printf '%s@view-%s' "$RS" "$1"; }
row() { cat "$FLEET_CONF_DIR/remote-views/$1" 2>/dev/null; }
rowget() { tr '\t' '\n' < "$FLEET_CONF_DIR/remote-views/$1" 2>/dev/null | sed -n "s/^$2=//p"; }
vcur() { tn display-message -p -t "=$(vs "$1"):" '#{window_id}' 2>/dev/null; }
DEV=$(printf '{"term":"iTerm2"}' | base64 | tr -d '\n')
# term <name> <args…> — a terminal window running the attach (then a sleep, so
# the window outlives it)
term() {
  local n="$1"; shift
  tt new-window -d -t "=$TL:" -n "$n" "env -u TMUX FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach $*; sleep 300"
}
# termf: the same, with the first-screen seam recording instead of switching
termf() {
  local n="$1"; shift
  tt new-window -d -t "=$TL:" -n "$n" -e "FLEET_VIEW_FIRST_CMD=echo >> $WORK/first.log" \
    "env -u TMUX FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach $*; sleep 300"
}
tt -f /dev/null new-session -d -s "$TL" -n idle -x 160 -y 40 'while :; do sleep 300; done'

# ============================================================================
# Z. degenerate: no --thin ⇒ the server's globals byte for byte
# ============================================================================
Z0=$(globals); F0=$(fleetopts)
term plain "-"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' list-clients 2>/dev/null | wc -l | tr -d ' ')\" -ge 1 ]" || fail "Z: the plain attach never arrived"
term shellv "--shell - v0"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$RS@view-v0' 2>/dev/null" || fail "Z: the view attach made no view session"
tt new-window -d -t "=$TL:" -n direct "env -u TMUX '$REAL_TMUX' -L '$RS' attach -t '=$RS'; sleep 300"
sleep 1
eq "Z: a plain / view / direct attach leaves the globals (options, window + server options, hooks, keys) byte for byte" "$Z0" "$(globals)"
hasnt "Z: no [78] hook without --thin" "$(tn show-hooks -g)" "session-window-changed[78]"
for w in plain shellv direct; do tt kill-window -t "=$TL:$w" 2>/dev/null; done
waitfor 5 sh -c "! '$REAL_TMUX' -L '$RS' has-session -t '=$RS@view-v0' 2>/dev/null" || fail "Z: the view session outlived its client"
tn select-window -t "=$RS:home"
F0=$(fleetopts)
tn bind-key -T root F11 display-message x   # a stand-in for the globals the thin attach must not touch
Z1=$(tn show-options -g; tn show-options -gw; tn show-options -gs; tn list-keys)

# ============================================================================
# A. attach --thin
# ============================================================================
term thin1 "--thin --view dev1 --device $DEV --route tailscale --token t0k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs dev1)' 2>/dev/null" || fail "A: no 看台 session"
waitfor 5 sh -c "[ -s '$FLEET_CONF_DIR/remote-views/dev1' ]" || fail "A: no registry row"
V="=$(vs dev1):"
eq "A: status on" "on" "$(tn show-options -qv -t "$V" status)"
eq "A: at the top" "top" "$(tn show-options -qv -t "$V" status-position)"
eq "A: every 2 s" "2" "$(tn show-options -qv -t "$V" status-interval)"
has "A: its line is fleet-topbar.py render --node" "$(tn show-options -qv -t "$V" 'status-format[0]')" "fleet-topbar.py' render --node view=dev1"
eq "A: no destroy-unattached" "off" "$(tn show-options -qv -t "$V" destroy-unattached)"
eq "A: marked @view_thin" "dev1" "$(tn show-options -qv -t "$V" @view_thin)"
eq "A: lands on the orchestrator's window (no cur= to go back to)" "$OW" "$(vcur dev1)"
eq "A: the fleet session's current window never moved" "home" "$(tn display-message -p -t "=$RS:" '#{window_name}')"
eq "A: row kind thin" "thin" "$(row dev1 | cut -f2-3 | cut -f2)"
eq "A: row session" "$RS" "$(row dev1 | cut -f2)"
eq "A: cur= the orchestrator's worker id" "$U/fid-orch" "$(rowget dev1 cur)"
eq "A: route=" "tailscale" "$(rowget dev1 route)"
eq "A: device=" "$DEV" "$(rowget dev1 device)"
eq "A: token=" "t0k" "$(rowget dev1 token)"
eq "A: fuid=" "$U" "$(rowget dev1 fuid)"
eq "A: node=" "m9" "$(rowget dev1 node)"
kill -0 "$(row dev1 | cut -f5)" 2>/dev/null; eq "A: its pid is the live attach" "0" "$?"
eq "A: the fleet session's own options untouched" "$F0" "$(fleetopts)"
eq "A: global options, window + server options, key tables untouched" "$Z1" "$(tn show-options -g; tn show-options -gw; tn show-options -gs; tn list-keys)"
has "A: the cur= hook is the one global addition, gated on @view_thin" "$(tn show-hooks -g | grep 'session-window-changed\[78\]')" "@view_thin"
eq "A: no key-table while C2's table does not exist" "" "$(tn show-options -qv -t "$V" key-table)"
eq "A: health — no shared client, no orphan" "shared=0 orphans=0" "$(env -u TMUX bash "$BIN/fleet-remote-view.sh" health)"

# ============================================================================
# B. the top line
# ============================================================================
render() {  # <window> [extra kv…] — the line's plain text, off the 看台's own command
  python3 "$BIN/fleet-topbar.py" render --node view=dev1 "s=$RS" "reg=$FLEET_CONF_DIR/remote-views" "g=$G" \
    "sock=$(tn display-message -p '#{socket_path}')" cw=160 "w=$1" "${@:2}" | sed 's/#\[[^]]*\]//g'
}
L7=$(render "$W7")
has "B: a window of this machine: its key" "$L7" "#7"
has "B: …剩余 % off its own stamps" "$L7" "剩余 62%"
has "B: …model · effort" "$L7" "Opus 5.5 · high"
has "B: …the machine (FLEET_NODE_ALIASES name)" "$L7" "@m9"
has "B: …the route off the registry row" "$L7" "Tailscale·自动"
# a phone (issue #3006, C9): narrower than 100 columns, no 剩余 · model · effort
L7n=$(python3 "$BIN/fleet-topbar.py" render --node view=dev1 "s=$RS" "reg=$FLEET_CONF_DIR/remote-views" "g=$G" \
  "sock=$(tn display-message -p '#{socket_path}')" cw=40 "w=$W7" | sed 's/#\[[^]]*\]//g')
has "B: 40 columns: the key stays" "$L7n" "#7"
hasnt "B: …no 剩余 %" "$L7n" "62%"
hasnt "B: …no model" "$L7n" "Opus"
L8=$(python3 "$BIN/fleet-topbar.py" render --node view=dev1 "s=$RS" "reg=$FLEET_CONF_DIR/remote-views" "g=$G" \
  "sock=$(tn display-message -p '#{socket_path}')" cw=160 "w=$W8")
has "B: a window on the refresh loop's cache: its title" "$(printf '%s' "$L8" | sed 's/#\[[^]]*\]//g')" "修缓存"
has "B: …its ctx columns" "$(printf '%s' "$L8" | sed 's/#\[[^]]*\]//g')" "40% · Sonnet 5.5 · medium"
has "B: …a perm needs is the ⊘ word" "$(printf '%s' "$L8" | sed 's/#\[[^]]*\]//g')" "⊘ needs OK"
hasnt "B: …and is no red line (only a question is)" "$L8" "bg=#f7768e"
# the screen itself: the client's first line is that top line
tn select-window -t "$V$W7" 2>/dev/null   # no client switch: tmux redraws the 看台 anyway
waitfor 8 sh -c "'$REAL_TMUX' -L '$TL' capture-pane -p -t '=$TL:thin1' -S 0 -E 0 | grep -q '剩余 62%'" \
  || fail "B: the client's first line is the top line" "$(tt capture-pane -p -t "=$TL:thin1" -S 0 -E 1)"
has "B: …at the top, with the machine" "$(tt capture-pane -p -t "=$TL:thin1" -S 0 -E 0)" "@m9"

# ============================================================================
# C. cur= follows the window
# ============================================================================
waitfor 5 sh -c "[ \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^cur=//p')\" = '$U/fid-7' ]" \
  || fail "C: cur= follows a switch to worker 7" "$(rowget dev1 cur)"
tn select-window -t "$V$W8"
waitfor 5 sh -c "[ \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^cur=//p')\" = '$U/fid-8' ]" \
  || fail "C: …and to worker 8" "$(rowget dev1 cur)"
tn select-window -t "=$RS:$W7"; sleep 1
eq "C: a switch in the fleet session writes nothing" "$U/fid-8" "$(rowget dev1 cur)"
eq "C: …and only one row" "dev1" "$(ls "$FLEET_CONF_DIR/remote-views")"

# ============================================================================
# D. the client goes; the 看台 stays; --resume comes back
# ============================================================================
GID=$(tn display-message -p -t "$V" '#{session_id}')
EV_BEFORE=$(printf -- '--- capture-pane -p (client, before the disconnect) ---\n'; tt capture-pane -p -t "=$TL:thin1" -S 0 -E 2
  printf -- '--- row ---\n'; row dev1)
tt kill-window -t "=$TL:thin1"
waitfor 5 sh -c "[ -n \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^left=//p')\" ]" || fail "D: no left= once the client went"
eq "D: the 看台 stays" "$GID" "$(tn display-message -p -t "$V" '#{session_id}' 2>/dev/null)"
eq "D: …unattached" "0" "$(tn display-message -p -t "$V" '#{session_attached}')"
env -u TMUX bash "$BIN/fleet-remote-view.sh" prune
eq "D: prune within the keep window keeps it" "$GID" "$(tn display-message -p -t "$V" '#{session_id}' 2>/dev/null)"
eq "D: …and its row" "$U/fid-8" "$(rowget dev1 cur)"
term thin2 "--thin --view dev1 --resume --device $DEV --route relay --token t1k"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '$V' '#{session_attached}')\" = 1 ]" || fail "D: --resume never attached"
waitfor 8 sh -c "'$REAL_TMUX' -L '$TL' capture-pane -p -t '=$TL:thin2' -S 0 -E 0 | grep -q '@m9'" || fail "D: the resumed client has no top line"
eq "D: --resume: the same 看台" "$GID" "$(tn display-message -p -t "$V" '#{session_id}')"
eq "D: …on the same window" "$W8" "$(vcur dev1)"
waitfor 5 sh -c "[ \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^token=//p')\" = t1k ]" || fail "D: the row is the new connection's"
eq "D: …route relay" "relay" "$(rowget dev1 route)"
eq "D: …no left= while attached" "" "$(rowget dev1 left)"
has "D: the line says 中转 on the relay" "$(render "$W8")" "· 中转"

# FRVT_EVIDENCE=<file>: the 上线证据 — the client's screen and the row before / after the reconnect
[ -n "${FRVT_EVIDENCE:-}" ] && { printf '%s\n' "$EV_BEFORE"; printf -- '--- after --resume: capture-pane -p (client) ---\n'
  tt capture-pane -p -t "=$TL:thin2" -S 0 -E 2; printf -- '--- row ---\n'; row dev1; } > "$FRVT_EVIDENCE"

# ============================================================================
# E. past the keep window: reaped; --resume then lands home; --want names a worker
# ============================================================================
tt kill-window -t "=$TL:thin2"
waitfor 5 sh -c "[ -n \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^left=//p')\" ]" || fail "E: no left="
FLEET_VIEW_KEEP_SECS=0 env -u TMUX bash "$BIN/fleet-remote-view.sh" prune
tn has-session -t "$V" 2>/dev/null; eq "E: past FLEET_VIEW_KEEP_SECS the 看台 is gone" "1" "$?"
eq "E: …and its row" "" "$(row dev1)"
term thin3 "--thin --view dev1 --resume --device $DEV --route lan --token t2k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '$V' 2>/dev/null" || fail "E: no 看台 on a resume after the reap"
# the session exists a moment before attach --thin selects its window: wait for it
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '=$(vs dev1):' '#{window_id}' 2>/dev/null)\" = '$OW' ]"
eq "E: --resume with no cur= lands on the orchestrator" "$OW" "$(vcur dev1)"
# no orchestrator window HERE (it runs on another machine): the attach hands the
# first screen to ⌘N's road (`do new`), never a bare home shell (issue #3007)
tn set-window-option -t "$OW" -u @fleet_role
tt kill-window -t "=$TL:thin3"
: > "$WORK/first.log"
termf thin3b "--thin --view dev9 --device $DEV --route lan --token t9k"
waitfor 5 sh -c "grep -q 'do new --view' '$WORK/first.log'" || fail "E: no orchestrator here → the first screen was not handed to ⌘N's road: $(cat "$WORK/first.log")"
has "E: … for this 看台" "$(cat "$WORK/first.log")" "--view $RS@view-dev9"
tn set-window-option -t "$OW" @fleet_role orchestrator
tt kill-window -t "=$TL:thin3b"
termf thin3c "--thin --view dev8 --device $DEV --route lan --token t8k"
sleep 1
[ "$(grep -c 'dev8' "$WORK/first.log")" = 0 ] || fail "E: an orchestrator here, yet the first screen went to ⌘N's road"
tt kill-window -t "=$TL:thin3c"
term thin4 "--thin --view dev2 --want $U/fid-7 --device $DEV --route lan --token t3k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs dev2):' 2>/dev/null" || fail "E: no 看台 for --want"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '=$(vs dev2):' '#{window_id}' 2>/dev/null)\" = '$W7' ]"
eq "E: --want lands on the worker it names" "$W7" "$(vcur dev2)"
tt kill-window -t "=$TL:thin4"

# ============================================================================
# K. C2's key table, once it exists
# ============================================================================
tn bind-key -T fleet-view F1 display-message x
term thin5 "--thin --view dev3 --device $DEV --route lan --token t4k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs dev3):' 2>/dev/null" || fail "K: no 看台"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' show-options -qv -t '=$(vs dev3):' key-table)\" = fleet-view ]"
eq "K: key-table fleet-view once the table exists" "fleet-view" "$(tn show-options -qv -t "=$(vs dev3):" key-table)"
eq "K: …the fleet session's key-table untouched" "" "$(tn show-options -qv -t "=$RS:" key-table)"
tt kill-window -t "=$TL:thin5"

# ============================================================================
# L. lint: the collector reaps a kept 看台 (its `views` phase)
# ============================================================================
has "L: the collector's views phase runs prune" "$(grep -n 'ph_views()' "$BIN/tmux-dash-collect.sh")" "fleet-remote-view.sh\" prune"

printf 'fleet-remote-view-thin selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
[ "$FAIL" -eq 0 ]
