#!/bin/bash
# fleet-remote-view-thin-selftest.sh — the thin client's 看台 (issue #2763, EPIC
# #2999 C1, 共同约定 6): bin/fleet-remote-view.sh `attach --thin` and the top line
# it wears, bin/fleet-topbar.py `render --node`.
#
# Two ISOLATED tmux servers: NODE (`-L <its session>`, the home machine's fleet —
# fleet_socket is the session name) and TERM (`-L tvT<pid>`), whose pane is the
# person's terminal: it runs the attach the way ssh -tt would, with $TMUX unset.
#   Z. degenerate — a plain / view attach (no --thin) and the proxy window's
#                   other modes are deleted (T606): one line, exit 2, nothing
#                   made; with a person's direct attach, the server's global
#                   options, window options, hooks and key tables byte for byte
#   A. attach     — `attach --thin` makes `<fleet>@view-<id>`: status on, at the
#                   top, every 2 s, its line `fleet-topbar.py render --node`, no
#                   destroy-unattached; with no cur= to go back to it hands the
#                   first screen to ⌘N's road (no session is anyone's home, issue
#                   #4341); registry row kind `thin` with cur= route=
#                   device= token= fuid=; the fleet session's own options and the
#                   global options / key tables untouched (only the [78] hook)
#   B. the line   — the client's screen's first line is the top line; for a window
#                   of this machine its own stamps: #7 · 剩余 62% · Opus 5.5 · high ·
#                   @<machine> · the route; for one on the refresh loop's cache its
#                   line (title, needs kind); at 40 columns (a phone, #3006) no
#                   剩余 · model · effort
#   C. cur=       — switching windows in the 看台 moves `cur=` (the [78] hook, gated
#                   on @view_thin: a switch in the fleet session writes nothing)
#   S. select     — `select <wid> <看台>` (a home's peer window, the fast path)
#                   moves that 看台 alone; with no 看台 the fleet session; a
#                   worker not here 3; a far 看台 not here yet 5
#   D. keep       — the client gone: the 看台 and its row stay (left=), `health`
#                   counts no orphan; `--resume` comes back to the same session on
#                   the same window
#   E. reap       — past FLEET_VIEW_KEEP_SECS `prune` takes row and session; a
#                   `--resume` then lands home (no cur= left); `--want` lands on
#                   the worker it names — by its fleet_id or its key (#3463); a
#                   leftover role mark (@fleet_role_def) makes no window home
#   G. (T690) FLEET_CLIENT_REHOMED=<old home> → the top line says 「家机器 <old>
#                   连不上，已自动换到 <this>」; a bad name nothing
#   H. last       — a plain attach (no --want / --resume) lands on the person's
#                   last session, kept in remote-views/.last by the `cur` hook past
#                   every 看台 (issue #4000): there from another device; gone ⇒
#                   ⌘N's road; none ⇒ ⌘N's road too; a bare window not kept
#   G. language   — `--lang <locale>` (or the entry door's FLEET_CLIENT_LANG in the
#                   environment) is recorded as the 看台's own @view_lang (issue
#                   #3326); each 看台 its own; a resume re-records it (empty too);
#                   no word given leaves it alone; a bad name is recorded as none.
#                   Issue #3329: FLEET_VIEW_LANG in the 看台 session's environment,
#                   and English detected for a device the first time ⇒ @view_flash
#                   (the top line's 8 s line) — once per device
#   R. restoring  — a `--resume` while a restore holds its lock and the 看台's
#                   session is not back yet: rc 3, no 看台 (issue #3511)
#   M. mtime      — a row with no left= is kept by its file's mtime, read portably
#                   (GNU stat too, issue #3513); past the window it is pruned
#   K. key table  — `key-table fleet-view` only once that table exists (C2)
#   O. cur OSC    — the thin loop is told the session in view (issue #3489): OSC
#                   7502 cur with the 看台's token on its client's tty, at the
#                   attach and on every switch (m=- l=- here, a peer window's
#                   @peer there); a far 看台 says nothing
#   R. bell       — a 看台 rings only for the window it shows (issue #3090): with the
#                   node's `bell-action any`, a BEL in another window reaches neither
#                   a 看台's terminal nor a far 看台's (`<id>-via-<home>`, the client
#                   a home's peer window is); a BEL in the shown window reaches both;
#                   a direct client of the fleet session still rings for any window
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-remote-view-thin selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-remote-view-thin selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/frvt-st.XXXXXX")" || exit 2
RS="tvR$$"; TL="tvT$$"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/control" "$FLEET_CONF_DIR/fleets/$RS"
export FLEET_SIDEBAR_HOST=nodebox FLEET_NODE_ALIASES='nodebox=m9'
export FLEET_UI_LANG=zh   # the line's words are the table's (issue #3324)
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_VIEW_KEEP_SECS FLEET_CLIENT_LANG

st_tally count miss
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
tn set-window-option -t "$OW" @fleet_role worker \; set-window-option -t "$OW" @fleet_id fid-orch
HW=$(tn display-message -p -t "=$RS:home" '#{window_id}')
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
# every attach's first screen with nowhere to go back to is ⌘N's road (issue #4341):
# the seam records it instead of opening a session, on every terminal here
tt set-environment -g FLEET_VIEW_FIRST_CMD "echo >> $WORK/first.log"

# ============================================================================
# Z. degenerate: no --thin ⇒ the server's globals byte for byte
# ============================================================================
Z0=$(globals); F0=$(fleetopts)
for m in "attach -" "attach - v0" "open $U/fid-7" "run m9 $U/fid-7" "serve v0" "watch v0" "back" "reconcile $RS"; do
  out=$(env -u TMUX bash "$BIN/fleet-remote-view.sh" $m 2>&1 </dev/null); rc=$?
  st_eq "Z: \`$m\` is deleted: exit 2" "2" "$rc"
  st_has "Z: …and says where the 看台 went" "$out" "已删除：看台走 fleet / attach --thin"
done
st_eq "Z: …it made no view session" "$RS" "$(tn list-sessions -F '#{session_name}')"
st_eq "Z: …and no registry row" "" "$(ls "$FLEET_CONF_DIR/remote-views" 2>/dev/null)"
tt new-window -d -t "=$TL:" -n direct "env -u TMUX '$REAL_TMUX' -L '$RS' attach -t '=$RS'; sleep 300"
sleep 1
st_eq "Z: the deleted modes and a direct attach leave the globals (options, window + server options, hooks, keys) byte for byte" "$Z0" "$(globals)"
st_hasnt "Z: no [78] hook without --thin" "$(tn show-hooks -g)" "session-window-changed[78]"
tt kill-window -t "=$TL:direct" 2>/dev/null
tn select-window -t "=$RS:home"
F0=$(fleetopts)
tn bind-key -T root F11 display-message x   # a stand-in for the globals the thin attach must not touch
Z1=$(tn show-options -g; tn show-options -gw; tn show-options -gs; tn list-keys)

# ============================================================================
# A. attach --thin
# ============================================================================
: > "$WORK/first.log"
termf thin1 "--thin --view dev1 --device $DEV --route tailscale --token t0k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs dev1)' 2>/dev/null" || st_miss "A: no 看台 session"
waitfor 5 sh -c "[ -s '$FLEET_CONF_DIR/remote-views/dev1' ]" || st_miss "A: no registry row"
V="=$(vs dev1):"
st_eq "A: status on" "on" "$(tn show-options -qv -t "$V" status)"
st_eq "A: at the top" "top" "$(tn show-options -qv -t "$V" status-position)"
st_eq "A: every 2 s" "2" "$(tn show-options -qv -t "$V" status-interval)"
st_has "A: its line is fleet-topbar.py render --node" "$(tn show-options -qv -t "$V" 'status-format[0]')" "fleet-topbar.py' render --node view=dev1"
st_eq "A: no destroy-unattached" "off" "$(tn show-options -qv -t "$V" destroy-unattached)"
st_eq "A: marked @view_thin" "dev1" "$(tn show-options -qv -t "$V" @view_thin)"
st_eq "A: no cur= to go back to: the session's own current window, nothing special" "$HW" "$(vcur dev1)"
waitfor 5 sh -c "grep -q 'do new --view $RS@view-dev1' '$WORK/first.log'" || st_miss "A: …and the first screen handed to ⌘N's road" "$(cat "$WORK/first.log")"
st_eq "A: the fleet session's current window never moved" "home" "$(tn display-message -p -t "=$RS:" '#{window_name}')"
st_eq "A: row kind thin" "thin" "$(row dev1 | cut -f2-3 | cut -f2)"
st_eq "A: row session" "$RS" "$(row dev1 | cut -f2)"
st_eq "A: cur= the window in view" "$HW" "$(rowget dev1 cur)"
st_eq "A: route=" "tailscale" "$(rowget dev1 route)"
st_eq "A: device=" "$DEV" "$(rowget dev1 device)"
st_eq "A: token=" "t0k" "$(rowget dev1 token)"
st_eq "A: fuid=" "$U" "$(rowget dev1 fuid)"
st_eq "A: node=" "m9" "$(rowget dev1 node)"
kill -0 "$(row dev1 | cut -f5)" 2>/dev/null; st_eq "A: its pid is the live attach" "0" "$?"
st_eq "A: the fleet session's own options untouched" "$F0" "$(fleetopts)"
st_eq "A: global options, window + server options, key tables untouched" "$Z1" "$(tn show-options -g; tn show-options -gw; tn show-options -gs; tn list-keys)"
st_has "A: the cur= hook is the one global addition, gated on @view_thin" "$(tn show-hooks -g | grep 'session-window-changed\[78\]')" "@view_thin"
st_eq "A: no key-table while C2's table does not exist" "" "$(tn show-options -qv -t "$V" key-table)"
st_eq "A: health — no shared client, no orphan" "shared=0 orphans=0" "$(env -u TMUX bash "$BIN/fleet-remote-view.sh" health)"

# ============================================================================
# B. the top line
# ============================================================================
render() {  # <window> [extra kv…] — the line's plain text, off the 看台's own command
  python3 "$BIN/fleet-topbar.py" render --node view=dev1 "s=$RS" "reg=$FLEET_CONF_DIR/remote-views" "g=$G" \
    "sock=$(tn display-message -p '#{socket_path}')" cw=160 "w=$1" "${@:2}" | sed 's/#\[[^]]*\]//g'
}
L7=$(render "$W7")
st_has "B: a window of this machine: its key" "$L7" "#7"
st_has "B: …剩余 % off its own stamps" "$L7" "剩余 62%"
st_has "B: …model · effort" "$L7" "Opus 5.5 · high"
st_hasnt "B: …no machine while it is reachable (#3194)" "$L7" "m9"
st_hasnt "B: …a Tailscale route is no trouble: nothing said" "$L7" "Tailscale"
st_has "B: …the ⌘P hint at 160" "$L7" "⌘P"
# a phone (issue #3194, was #3006 C9): the % stays, no model
L7n=$(python3 "$BIN/fleet-topbar.py" render --node view=dev1 "s=$RS" "reg=$FLEET_CONF_DIR/remote-views" "g=$G" \
  "sock=$(tn display-message -p '#{socket_path}')" cw=40 "w=$W7" | sed 's/#\[[^]]*\]//g')
st_has "B: 40 columns: the key stays" "$L7n" "#7"
st_has "B: …the % stays on a phone (#3194)" "$L7n" "62%"
st_hasnt "B: …no model" "$L7n" "Opus"
# no issue, the hub's task record (issue #3325): the bar's number is T<n>
W7t=$(tn new-window -d -P -F '#{window_id}' -t "$RS:" -n task7 'while :; do sleep 300; done')
tn set-window-option -t "$W7t" @task T218 \; set-window-option -t "$W7t" @norepo 1
st_has "B: no issue, a task record: its T number" "$(render "$W7t")" "T218"
tn set-window-option -t "$W7t" @issue 3312
L7t=$(render "$W7t")
st_has "B: …an issue wins over the task number" "$L7t" "#3312"
st_hasnt "B: …and the T number goes" "$L7t" "T218"
tn kill-window -t "$W7t"
L8=$(python3 "$BIN/fleet-topbar.py" render --node view=dev1 "s=$RS" "reg=$FLEET_CONF_DIR/remote-views" "g=$G" \
  "sock=$(tn display-message -p '#{socket_path}')" cw=160 "w=$W8")
st_has "B: a window on the refresh loop's cache: its title" "$(printf '%s' "$L8" | sed 's/#\[[^]]*\]//g')" "修缓存"
st_has "B: …its ctx columns" "$(printf '%s' "$L8" | sed 's/#\[[^]]*\]//g')" "40% · Sonnet 5.5 · medium"
st_has "B: …a perm needs is the ! glyph, no word (#3194)" "$(printf '%s' "$L8" | sed 's/#\[[^]]*\]//g')" " ! #"
st_has "B: …and a red line (waiting on you)" "$L8" "bg=#f7768e"
# a login just opened (#3155): the hub's list has no line for this fleet yet —
# the window's own stamps still draw it; no ‹ i/n › any more (#3194)
mkdir -p "$TMPDIR/nocache"
L9=$(python3 "$BIN/fleet-topbar.py" render --node view=dev1 "s=$RS" "reg=$FLEET_CONF_DIR/remote-views" "g=$TMPDIR/nocache" \
  "sock=$(tn display-message -p '#{socket_path}')" cw=160 "w=$W7" | sed 's/#\[[^]]*\]//g')
st_has "B: no hub line yet: its key off its own stamps" "$L9" "#7"
st_hasnt "B: …no ‹ i/n › (#3194)" "$L9" "‹"
# the screen itself: the client's first line is that top line
tn select-window -t "$V$W7" 2>/dev/null   # no client switch: tmux redraws the 看台 anyway
waitfor 8 sh -c "'$REAL_TMUX' -L '$TL' capture-pane -p -t '=$TL:thin1' -S 0 -E 0 | grep -q '剩余 62%'" \
  || st_miss "B: the client's first line is the top line" "$(tt capture-pane -p -t "=$TL:thin1" -S 0 -E 1)"
st_has "B: …at the top, with its key" "$(tt capture-pane -p -t "=$TL:thin1" -S 0 -E 0)" "#7"

# ============================================================================
# C. cur= follows the window
# ============================================================================
waitfor 5 sh -c "[ \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^cur=//p')\" = '$U/fid-7' ]" \
  || st_miss "C: cur= follows a switch to worker 7" "$(rowget dev1 cur)"
tn select-window -t "$V$W8"
waitfor 5 sh -c "[ \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^cur=//p')\" = '$U/fid-8' ]" \
  || st_miss "C: …and to worker 8" "$(rowget dev1 cur)"
tn select-window -t "=$RS:$W7"; sleep 1
st_eq "C: a switch in the fleet session writes nothing" "$U/fid-8" "$(rowget dev1 cur)"
st_eq "C: …and only one row" "dev1" "$(ls "$FLEET_CONF_DIR/remote-views")"

# ============================================================================
# S. select — a home's peer window switching this 看台 (the fast path), and the
# slow road for a fleet session / a worker not here
# ============================================================================
tn select-window -t "=$RS:home"
env -u TMUX bash "$BIN/fleet-remote-view.sh" select "wid:$U/fid-7" dev1 2>/dev/null; st_eq "S: select <wid> <看台> answers 0" "0" "$?"
st_eq "S: …that 看台 shows worker 7, the fleet session stays where it was" "$W7 home" "$(vcur dev1) $(tn display-message -p -t "=$RS:" '#{window_name}')"
env -u TMUX bash "$BIN/fleet-remote-view.sh" select "$U/issue-8" 2>/dev/null; st_eq "S: select <wid> (by its key) with no 看台 answers 0" "0" "$?"
st_eq "S: …it moves the fleet session and nobody's 看台" "$W8 $W7" "$(tn display-message -p -t "=$RS:" '#{window_id}') $(vcur dev1)"
env -u TMUX bash "$BIN/fleet-remote-view.sh" select "$U/fid-gone" dev1 >/dev/null 2>&1; st_eq "S: a worker not live here: 3" "3" "$?"
env -u TMUX bash "$BIN/fleet-remote-view.sh" select "$U/fid-8" dev1-via-home >/dev/null 2>&1; st_eq "S: a far 看台 not here yet: 5" "5" "$?"
env -u TMUX bash "$BIN/fleet-remote-view.sh" select "$U/fid-8" dev1 2>/dev/null
waitfor 5 sh -c "[ \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^cur=//p')\" = '$U/fid-8' ]" \
  || st_miss "S: back on worker 8, cur= follows" "$(rowget dev1 cur)"

# ============================================================================
# D. the client goes; the 看台 stays; --resume comes back
# ============================================================================
GID=$(tn display-message -p -t "$V" '#{session_id}')
EV_BEFORE=$(printf -- '--- capture-pane -p (client, before the disconnect) ---\n'; tt capture-pane -p -t "=$TL:thin1" -S 0 -E 2
  printf -- '--- row ---\n'; row dev1)
tt kill-window -t "=$TL:thin1"
waitfor 5 sh -c "[ -n \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^left=//p')\" ]" || st_miss "D: no left= once the client went"
st_eq "D: the 看台 stays" "$GID" "$(tn display-message -p -t "$V" '#{session_id}' 2>/dev/null)"
st_eq "D: …unattached" "0" "$(tn display-message -p -t "$V" '#{session_attached}')"
env -u TMUX bash "$BIN/fleet-remote-view.sh" prune
st_eq "D: prune within the keep window keeps it" "$GID" "$(tn display-message -p -t "$V" '#{session_id}' 2>/dev/null)"
st_eq "D: …and its row" "$U/fid-8" "$(rowget dev1 cur)"
term thin2 "--thin --view dev1 --resume --device $DEV --route relay --token t1k"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '$V' '#{session_attached}')\" = 1 ]" || st_miss "D: --resume never attached"
waitfor 8 sh -c "'$REAL_TMUX' -L '$TL' capture-pane -p -t '=$TL:thin2' -S 0 -E 0 | grep -q 'm9 经中转'" || st_miss "D: the resumed client has no top line"
st_eq "D: --resume: the same 看台" "$GID" "$(tn display-message -p -t "$V" '#{session_id}')"
st_eq "D: …on the same window" "$W8" "$(vcur dev1)"
waitfor 5 sh -c "[ \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^token=//p')\" = t1k ]" || st_miss "D: the row is the new connection's"
st_eq "D: …route relay" "relay" "$(rowget dev1 route)"
st_eq "D: …no left= while attached" "" "$(rowget dev1 left)"
st_has "D: the line says 经中转 on the relay — the one time the machine is named (#3194)" "$(render "$W8")" "m9 经中转"

# FRVT_EVIDENCE=<file>: the 上线证据 — the client's screen and the row before / after the reconnect
[ -n "${FRVT_EVIDENCE:-}" ] && { printf '%s\n' "$EV_BEFORE"; printf -- '--- after --resume: capture-pane -p (client) ---\n'
  tt capture-pane -p -t "=$TL:thin2" -S 0 -E 2; printf -- '--- row ---\n'; row dev1; } > "$FRVT_EVIDENCE"

# ============================================================================
# E. past the keep window: reaped; --resume then lands home; --want names a worker
# ============================================================================
tt kill-window -t "=$TL:thin2"
waitfor 5 sh -c "[ -n \"\$(tr '\t' '\n' < '$FLEET_CONF_DIR/remote-views/dev1' | sed -n 's/^left=//p')\" ]" || st_miss "E: no left="
FLEET_VIEW_KEEP_SECS=0 env -u TMUX bash "$BIN/fleet-remote-view.sh" prune
tn has-session -t "$V" 2>/dev/null; st_eq "E: past FLEET_VIEW_KEEP_SECS the 看台 is gone" "1" "$?"
st_eq "E: …and its row" "" "$(row dev1)"
termf thin3 "--thin --view dev1 --resume --device $DEV --route lan --token t2k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '$V' 2>/dev/null" || st_miss "E: no 看台 on a resume after the reap"
# the session exists a moment before attach --thin selects its window: wait for it
waitfor 5 sh -c "grep -q 'do new --view $RS@view-dev1' '$WORK/first.log'" \
  || st_miss "E: --resume with no cur= hands the first screen to ⌘N's road" "$(cat "$WORK/first.log")"
# a first use: the attach hands the first screen to ⌘N's road (`do new`), never a
# bare home shell (issue #3007)
tt kill-window -t "=$TL:thin3"
rm -f "$FLEET_CONF_DIR/remote-views/.last"   # a first use: no last session (H tests one)
: > "$WORK/first.log"
termf thin3b "--thin --view dev9 --device $DEV --route lan --token t9k"
waitfor 5 sh -c "grep -q 'do new --view' '$WORK/first.log'" || st_miss "E: a first use → the first screen was not handed to ⌘N's road: $(cat "$WORK/first.log")"
st_has "E: … for this 看台" "$(cat "$WORK/first.log")" "--view $RS@view-dev9"
tt kill-window -t "=$TL:thin3b"
term thin4 "--thin --view dev2 --want $U/fid-7 --device $DEV --route lan --token t3k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs dev2):' 2>/dev/null" || st_miss "E: no 看台 for --want"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '=$(vs dev2):' '#{window_id}' 2>/dev/null)\" = '$W7' ]"
st_eq "E: --want lands on the worker it names" "$W7" "$(vcur dev2)"
tt kill-window -t "=$TL:thin4"
# issue #3463: a worker named by its KEY (`<uuid>/issue-8` — what the list hands for
# an issue-bound session, and so a peer window's @peer_cur its reconnect asks for)
# lands on it, never on whatever the fleet session shows (a bare shell on the phone)
tn select-window -t "=$RS:home"
term thin4k "--thin --view dev4 --want $U/issue-8 --device $DEV --route lan --token t4k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs dev4):' 2>/dev/null" || st_miss "E: no 看台 for a key --want"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '=$(vs dev4):' '#{window_id}' 2>/dev/null)\" = '$W8' ]"
st_eq "E: --want <uuid>/<key> lands on that worker (#3463)" "$W8" "$(vcur dev4)"
tt kill-window -t "=$TL:thin4k"
# a window still wearing an old role mark (@fleet_role_def / an old seat's
# @fleet_role) is an ordinary session (issue #4341): no home, ⌘N's road as for any
tn set-window-option -t "$OW" @fleet_role_def orchestrator
rm -f "$FLEET_CONF_DIR/remote-views/.last"
: > "$WORK/first.log"
termf thin4h "--thin --view dev5 --device $DEV --route lan --token t5k"
waitfor 5 sh -c "grep -q 'do new --view $RS@view-dev5' '$WORK/first.log'" \
  || st_miss "E: a leftover role mark made a window home" "$(cat "$WORK/first.log")"
st_hasnt "E: …and not on that window" "$(vcur dev5)" "$OW"
tt kill-window -t "=$TL:thin4h"
tn set-window-option -t "$OW" -u @fleet_role_def

# ============================================================================
# H. a plain `fleet` comes back to the LAST session (issue #4000): the `cur` hook
# keeps `.last` past every 看台 — first use ⇒ ⌘N's road; last here ⇒ there,
# from any device (another view id); last gone ⇒ ⌘N's road;
# a bare window (no @fleet_id) is never remembered
# ============================================================================
LAST="$FLEET_CONF_DIR/remote-views/.last"
lastis() { [ "$(cat "$LAST" 2>/dev/null)" = "$1" ]; }
rm -f "$LAST"; : > "$WORK/first.log"
termf lasth1 "--thin --view devh1 --device $DEV --route lan --token th1"
waitfor 5 sh -c "grep -q 'do new --view $RS@view-devh1' '$WORK/first.log'" \
  || st_miss "H: first use (no last session): ⌘N's road" "$(cat "$WORK/first.log")"
tn select-window -t "=$(vs devh1):$OW"
waitfor 8 lastis "$U/fid-orch" || st_miss "H: the session in view was not kept as the last one" "$(cat "$LAST" 2>/dev/null)"
tn select-window -t "=$(vs devh1):$W7"
waitfor 5 lastis "$U/fid-7" || st_miss "H: a switch did not move the last session" "$(cat "$LAST" 2>/dev/null)"
tn select-window -t "=$(vs devh1):home"
sleep 1
st_eq "H: a bare window is never the last session" "$U/fid-7" "$(cat "$LAST" 2>/dev/null)"
tt kill-window -t "=$TL:lasth1"
FLEET_VIEW_KEEP_SECS=0 env -u TMUX bash "$BIN/fleet-remote-view.sh" prune
st_eq "H: the 看台 reaped, the last session kept" "$U/fid-7" "$(cat "$LAST" 2>/dev/null)"
termf lasth2 "--thin --view devh2 --device $DEV --route lan --token th2"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '=$(vs devh2):' '#{window_id}' 2>/dev/null)\" = '$W7' ]"
st_eq "H: a new run, another device: lands on the last session" "$W7" "$(vcur devh2)"
sleep 1
st_eq "H: …and opens no new session" "0" "$(grep -c 'devh2' "$WORK/first.log")"
tt kill-window -t "=$TL:lasth2"
printf '%s/fid-gone\n' "$U" > "$LAST"
termf lasth3 "--thin --view devh3 --device $DEV --route lan --token th3"
waitfor 5 sh -c "grep -q 'do new --view $RS@view-devh3' '$WORK/first.log'" \
  || st_miss "H: the last session is gone, yet no new session was opened" "$(cat "$WORK/first.log")"
st_hasnt "H: …and not on another session" "$(vcur devh3)" "$OW"
tt kill-window -t "=$TL:lasth3"
rm -f "$LAST"   # the legs below are first uses

# ============================================================================
# G. the client's language, per 看台 (issue #3326)
# ============================================================================
vlang() { tn show-options -qv -t "=$(vs "$1"):" @view_lang 2>/dev/null; }
vlset() { tn show-options -t "=$(vs "$1"):" 2>/dev/null | grep -cE '^@view_lang( |$)'; }
venv() { tn show-environment -t "=$(vs "$1"):" FLEET_VIEW_LANG 2>/dev/null; }
vflash() { tn show-options -qv -t "=$(vs "$1"):" @view_flash 2>/dev/null; }
# termu: `term` with the language left to the rules (no FLEET_UI_LANG forced), as on a machine
termu() {
  local n="$1"; shift
  tt new-window -d -t "=$TL:" -n "$n" "env -u TMUX -u FLEET_UI_LANG FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach $*; sleep 300"
}
termu lang1 "--thin --view devl1 --device $DEV --route entry --token tl1 --lang en_US.UTF-8"
# one attach at a time: an attach's prune takes a 看台 session no row has claimed yet
waitfor 5 sh -c "[ -s '$FLEET_CONF_DIR/remote-views/devl1' ]" || st_miss "G: devl1 never registered"
tt new-window -d -t "=$TL:" -n lang2 "env -u TMUX FLEET_CLIENT_LANG=fr_FR.UTF-8 FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach --thin --view devl2 --want $U/fid-7 --device $DEV --route entry --token tl2; sleep 300"
waitfor 5 sh -c "[ -n \"\$('$REAL_TMUX' -L '$RS' show-options -qv -t '=$(vs devl1):' @view_lang 2>/dev/null)\" ]" || st_miss "G: no @view_lang on devl1"
waitfor 5 sh -c "[ -n \"\$('$REAL_TMUX' -L '$RS' show-options -qv -t '=$(vs devl2):' @view_lang 2>/dev/null)\" ]" || st_miss "G: no @view_lang on devl2"
st_eq "G: --lang is the 看台's @view_lang" "en_US.UTF-8" "$(vlang devl1)"
st_eq "G: … the entry door's FLEET_CLIENT_LANG, each 看台 its own" "fr_FR.UTF-8" "$(vlang devl2)"
st_eq "G: … a session option of the 看台, never the fleet session's" "" "$(tn show-options -qv -t "=$RS:" @view_lang)"
st_hasnt "G: … never the server's environment" "$(tn show-environment -g 2>/dev/null)" "fr_FR"
# issue #3329: the 看台 draws in it — its session's environment, and the first time
# a device comes in on English detected for it, the top line's 8-second line
waitfor 5 sh -c "[ -n \"\$('$REAL_TMUX' -L '$RS' show-options -qv -t '=$(vs devl1):' @view_flash 2>/dev/null)\" ]" || st_miss "G: no one-time line on devl1"
st_eq "G: FLEET_VIEW_LANG in the 看台 session's environment" "FLEET_VIEW_LANG=en_US.UTF-8" "$(venv devl1)"
st_has "G: … the first time, the one-time line (D8)" "$(vflash devl1)" "Using English from your system (LANG=en_US.UTF-8)"
[ -e "$FLEET_CONF_DIR/entry/devl1.lang-hinted" ] || st_miss "G: the device was not stamped as hinted"
st_has "G: … the top line's format reads it" "$(tn show-options -qv -t "=$(vs devl1):" 'status-format[0]')" "fl=#{q:@view_flash}"
tt kill-window -t "=$TL:lang1"
tt new-window -d -t "=$TL:" -n lang1b "env -u TMUX FLEET_CLIENT_LANG= FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach --thin --view devl1 --resume --device $DEV --route entry --token tl3; sleep 300"
waitfor 5 sh -c "tr '\\t' '\\n' < '$FLEET_CONF_DIR/remote-views/devl1' 2>/dev/null | grep -qx token=tl3" || st_miss "G: the resume never registered"
st_eq "G: a resume that brought none records none (not the last one's)" "" "$(vlang devl1)"
st_eq "G: … recorded as empty, still set" "1" "$(vlset devl1)"
st_eq "G: … and its environment says none" "FLEET_VIEW_LANG=" "$(venv devl1)"
tt kill-window -t "=$TL:lang1b"
tn set-option -t "=$(vs devl1):" -u @view_flash
termu lang1c "--thin --view devl1 --resume --device $DEV --route entry --token tl6 --lang en_US.UTF-8"
waitfor 5 sh -c "tr '\\t' '\\n' < '$FLEET_CONF_DIR/remote-views/devl1' 2>/dev/null | grep -qx token=tl6" || st_miss "G: the third attach never registered"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' show-environment -t '=$(vs devl1):' FLEET_VIEW_LANG 2>/dev/null)\" = FLEET_VIEW_LANG=en_US.UTF-8 ]" || st_miss "G: the third attach set no language"
sleep 1
st_eq "G: the same device again: no second one-time line" "" "$(vflash devl1)"
st_eq "G: … its language is back" "FLEET_VIEW_LANG=en_US.UTF-8" "$(venv devl1)"
tt kill-window -t "=$TL:lang1c"
st_eq "G: the other 看台 untouched" "fr_FR.UTF-8" "$(vlang devl2)"
term lang3 "--thin --view devl3 --device $DEV --route lan --token tl4"
term lang4 "--thin --view devl4 --device $DEV --route lan --token tl5 --lang 'x;y'"
waitfor 10 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs devl4)' 2>/dev/null && [ -s '$FLEET_CONF_DIR/remote-views/devl4' ] && [ -s '$FLEET_CONF_DIR/remote-views/devl3' ]" || st_miss "G: no 看台 devl3 / devl4"
st_eq "G: no word given (a thin client's attach) leaves no @view_lang" "0" "$(vlset devl3)"
st_eq "G: a bad name is recorded as none" "" "$(vlang devl4)"
for w in lang2 lang3 lang4; do tt kill-window -t "=$TL:$w" 2>/dev/null; done
# T690: a thin loop that gave up on its home brings FLEET_CLIENT_REHOMED — the new
# home's top line says which home was given up and which this is; a bad name says nothing
tt new-window -d -t "=$TL:" -n rh1 "env -u TMUX FLEET_UI_LANG=zh FLEET_CLIENT_REHOMED=m1 FLEET_SIDEBAR_HOST=m2 FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach --thin --view devr1 --device $DEV --route lan --token tr1; sleep 300"
waitfor 5 sh -c "[ -n \"\$('$REAL_TMUX' -L '$RS' show-options -qv -t '=$(vs devr1):' @view_flash 2>/dev/null)\" ]" || st_miss "G: no rehome line on devr1"
st_eq "G: 换家 → the new home's top line says so (T690)" "家机器 m1 连不上，已自动换到 m2" "$(vflash devr1)"
tt new-window -d -t "=$TL:" -n rh2 "env -u TMUX FLEET_UI_LANG=zh 'FLEET_CLIENT_REHOMED=m1;x' FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach --thin --view devr2 --device $DEV --route lan --token tr2; sleep 300"
waitfor 5 sh -c "[ -s '$FLEET_CONF_DIR/remote-views/devr2' ]" || st_miss "G: devr2 never registered"
sleep 0.5
st_eq "G: … a bad name: nothing said" "" "$(vflash devr2)"
for w in rh1 rh2; do tt kill-window -t "=$TL:$w" 2>/dev/null; done

# ============================================================================
# K. C2's key table, once it exists
# ============================================================================
tn bind-key -T fleet-view F1 display-message x
term thin5 "--thin --view dev3 --device $DEV --route lan --token t4k"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs dev3):' 2>/dev/null" || st_miss "K: no 看台"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' show-options -qv -t '=$(vs dev3):' key-table)\" = fleet-view ]"
st_eq "K: key-table fleet-view once the table exists" "fleet-view" "$(tn show-options -qv -t "=$(vs dev3):" key-table)"
st_eq "K: …the fleet session's key-table untouched" "" "$(tn show-options -qv -t "=$RS:" key-table)"
tt kill-window -t "=$TL:thin5"

# ============================================================================
# R. bell: only the window the 看台 shows rings its terminal (issue #3090)
# ============================================================================
tn set-option -g monitor-bell on \; set-option -g bell-action any \; set-option -g visual-bell off
bell() { tt display-message -p -t "=$TL:$1" '#{window_bell_flag}' 2>/dev/null; }
ring() { printf '\a' > "$(tn display-message -p -t "$1" '#{pane_tty}')"; }
term bellh "--thin --view devb --want $U/fid-7 --device $DEV --route lan --token tbk"
term bellf "--thin --view devf-via-home --want $U/fid-7 --device $DEV --route lan --token tfk"
tt new-window -d -t "=$TL:" -n bello "env -u TMUX '$REAL_TMUX' -L '$RS' attach -t '=$RS'; sleep 300"
waitfor 5 sh -c "[ -n \"\$('$REAL_TMUX' -L '$RS' list-clients -t '=$RS' 2>/dev/null)\" ]" || st_miss "R: no direct client on the fleet session"
for v in devb devf-via-home; do
  waitfor 5 sh -c "[ -n \"\$('$REAL_TMUX' -L '$RS' list-clients -t '=$(vs $v)' 2>/dev/null)\" ]" || st_miss "R: no client on $(vs $v)"
done
tn select-window -t "=$RS:$W7"
waitfor 5 sh -c "[ \"\$('$REAL_TMUX' -L '$RS' display-message -p -t '=$(vs devb):' '#{window_id}' 2>/dev/null)\" = '$W7' ]"
st_eq "R: a 看台 says bell-action current" "current" "$(tn show-options -qv -t "=$(vs devb):" bell-action)"
st_eq "R: … a far 看台 too" "current" "$(tn show-options -qv -t "=$(vs devf-via-home):" bell-action)"
st_eq "R: the fleet session keeps the global" "" "$(tn show-options -qv -t "=$RS:" bell-action)"
sleep 0.5
st_eq "R: no bell before any BEL" "0 0 0" "$(bell bellh) $(bell bellf) $(bell bello)"
ring "$W8"; sleep 1
st_eq "R: a BEL in another window does not reach the 看台's terminal" "0" "$(bell bellh)"
st_eq "R: … nor a far 看台's (a peer window's client)" "0" "$(bell bellf)"
st_eq "R: a direct client of the fleet session still rings for any window" "1" "$(bell bello)"
ring "$W7"; sleep 1
st_eq "R: a BEL in the shown window reaches the 看台's terminal" "1" "$(bell bellh)"
st_eq "R: … and a far 看台's" "1" "$(bell bellf)"
for w in bellh bellf bello; do tt kill-window -t "=$TL:$w" 2>/dev/null; done

# ============================================================================
# O. the thin loop is told the session in view (issue #3489): OSC 7502 cur on
#    the attached client's tty — at the attach, and on every switch; m=- l=- for
#    a window of this machine, a peer window's @peer for another one's; a far
#    看台 (`-via-`) says nothing (its home's 看台 does)
# ============================================================================
osc() { tr '\033\007' '<>' < "$WORK/osc.$1" 2>/dev/null; }
tt new-window -d -t "=$TL:" -n osc1 "sleep 300"
tt pipe-pane -O -t "=$TL:osc1" "cat >> '$WORK/osc.osc1'"
tt respawn-pane -k -t "=$TL:osc1" "env -u TMUX FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach --thin --view devo1 --want $U/fid-7 --device $DEV --route lan --token tko; sleep 300"
tt pipe-pane -O -t "=$TL:osc1" "cat >> '$WORK/osc.osc1'"
waitfor 8 sh -c "tr '\033\007' '<>' < '$WORK/osc.osc1' 2>/dev/null | grep -qF '<]7502;cur;token=tko;m=-;l=-;w=$U/fid-7;g='" \
  || st_miss "O: the attach says the session in view" "$(osc osc1 | grep -o '7502;cur[^>]*' | tail -n 3)"
tn new-window -d -t "=$RS:" -n peerx "sleep 300"
PX=$(tn display-message -p -t "=$RS:peerx" '#{window_id}')
tn set-option -w -t "$PX" @peer 'far1@bob' \; set-option -w -t "$PX" @peer_cur "wid:FU9/ffar" \; set-option -w -t "$PX" @fleet_role panel
tn select-window -t "=$(vs devo1):$PX"
waitfor 5 sh -c "tr '\033\007' '<>' < '$WORK/osc.osc1' 2>/dev/null | grep -qF '<]7502;cur;token=tko;m=far1;l=bob;w=FU9/ffar;g='" \
  || st_miss "O: a peer window says its machine and login" "$(osc osc1 | grep -o '7502;cur[^>]*' | tail -n 3)"
tn select-window -t "=$(vs devo1):$W8"
waitfor 5 sh -c "tr '\033\007' '<>' < '$WORK/osc.osc1' 2>/dev/null | grep -qF '<]7502;cur;token=tko;m=-;l=-;w=$U/fid-8;g='" \
  || st_miss "O: a switch back here says it" "$(osc osc1 | grep -o '7502;cur[^>]*' | tail -n 3)"
st_hasnt "O: no other token on that tty" "$(osc osc1 | grep -o '7502;[a-z]*;token=[^;>]*' | grep -v 'token=tko')" "token="
tt new-window -d -t "=$TL:" -n osc2 "sleep 300"
tt pipe-pane -O -t "=$TL:osc2" "cat >> '$WORK/osc.osc2'"
tt respawn-pane -k -t "=$TL:osc2" "env -u TMUX FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' bash '$BIN/fleet-remote-view.sh' attach --thin --view devo2-via-home --want $U/fid-7 --device $DEV --route lan --token tkf; sleep 300"
tt pipe-pane -O -t "=$TL:osc2" "cat >> '$WORK/osc.osc2'"
waitfor 5 sh -c "[ -n \"\$('$REAL_TMUX' -L '$RS' list-clients -t '=$(vs devo2-via-home)' 2>/dev/null)\" ]" || st_miss "O: no client on the far 看台"
tn select-window -t "=$(vs devo2-via-home):$W8"; sleep 2
st_hasnt "O: a far 看台 says nothing" "$(osc osc2)" "7502;cur"
for w in osc1 osc2; do tt kill-window -t "=$TL:$w" 2>/dev/null; done
tn kill-window -t "$PX" 2>/dev/null

# ============================================================================
# R. a restore under way (issue #3511): the home's tmux was restarted, the fleet is
#    back but the resumed 看台's session is not yet — rc 3, no 看台, so the thin loop
#    waits instead of landing home; the lock gone → the resume goes on as before
# ============================================================================
# (no left=: the row's mtime starts its keep window — on GNU stat too, issue #3513)
printf -- '-\t%s\tthin\t%s\t1\tcur=%s/fid-coming\troute=lan\tdevice=%s\ttoken=tr0\tfuid=%s\tnode=m9\n' \
  "$RS" "$(date +%s)" "$U" "$DEV" "$U" > "$FLEET_CONF_DIR/remote-views/devr"
mkdir -p "$FLEET_CONF_DIR/restore/.auto.lock"; echo $$ > "$FLEET_CONF_DIR/restore/.auto.lock/pid"
out=$(env -u TMUX bash "$BIN/fleet-remote-view.sh" attach --thin --view devr --resume --device "$DEV" --route lan --token tr1 2>&1 </dev/null); rc=$?
st_eq "R: a restore holding the lock, the session not back yet → 3" "3" "$rc"
st_has "R: …saying the home is restarting" "$out" "is restarting"
tn has-session -t "=$(vs devr)" 2>/dev/null; st_eq "R: …and no 看台 made" "1" "$?"
rm -rf "$FLEET_CONF_DIR/restore/.auto.lock"
term thinr "--thin --view devr --resume --device $DEV --route lan --token tr2"
waitfor 5 sh -c "'$REAL_TMUX' -L '$RS' has-session -t '=$(vs devr)' 2>/dev/null" || st_miss "R: no lock → the resume no longer attaches"
tt kill-window -t "=$TL:thinr" 2>/dev/null

# ============================================================================
# M. a kept row with no left= (issue #3513): its file's mtime starts the keep
#    window. GNU stat takes `-f` for its filesystem mode and prints that, so a
#    `stat -f %m || stat -c %Y` read is no number there and the row was pruned at
#    once — on a Linux home, a 看台 whose attach died before it wrote left=
# ============================================================================
sh -c 'exit 0' & MP=$!; wait "$MP"   # a pid that is gone: only the keep window holds the row
printf -- '-\t%s\tthin\t%s\t%s\tcur=-\troute=lan\tdevice=%s\ttoken=tm0\tfuid=%s\tnode=m9\n' \
  "$RS" "$(date +%s)" "$MP" "$DEV" "$U" > "$FLEET_CONF_DIR/remote-views/devm"
env -u TMUX bash "$BIN/fleet-remote-view.sh" prune
st_eq "M: no left=, a fresh mtime → prune keeps the row" "yes" "$([ -f "$FLEET_CONF_DIR/remote-views/devm" ] && echo yes)"
touch -t 202001010000 "$FLEET_CONF_DIR/remote-views/devm"
env -u TMUX bash "$BIN/fleet-remote-view.sh" prune
st_eq "M: …an mtime past FLEET_VIEW_KEEP_SECS → pruned" "" "$([ -f "$FLEET_CONF_DIR/remote-views/devm" ] && echo yes)"

# ============================================================================
# L. lint: the collector reaps a kept 看台 (its `views` phase)
# ============================================================================
st_has "L: the collector's views phase runs prune" "$(grep -n 'ph_views()' "$BIN/tmux-dash-collect.sh")" "fleet-remote-view.sh\" prune"

printf 'fleet-remote-view-thin selftest: %d checks, %d failed\n' "$CHECKS" "$FAIL"
st_done
