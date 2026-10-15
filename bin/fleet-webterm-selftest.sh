#!/bin/bash
# fleet-webterm-selftest.sh — a browser's ONE personal terminal (issue #4373,
# EPIC #3836 C4): bin/fleet-webterm.py and fleet-remote-view.sh `attach --thin
# --browser`.
#
# Two ISOLATED tmux servers: NODE (`-L <its session>`, the login's fleet) and TERM
# (`-L wtT<pid>`), whose windows are the browser's PTYs (C1's relay runs the
# attach the same way, $TMUX unset).
#   A. no fleet   — status / ensure: rc 3 `nofleet`, nothing written but the dir;
#                   ensure --init brings one up through the lifecycle entry (the
#                   FLEET_WEBTERM_UP_CMD seam) and makes the terminal there
#   B. singleton  — 8 simultaneous ensures on a fleet with no home window: ONE
#                   home window, ONE stamped pane, one id, generation 1; the home
#                   window `@reap_policy keep` + @webterm_home; state 0700/0600,
#                   no credential-shaped key
#   C. cycles     — 20 attach/release cycles: each lands on the home pane, never
#                   runs the new-session road (FLEET_VIEW_FIRST_CMD) even with a
#                   gone `.last` and no orchestrator; after each release no
#                   `@view-wt-` session and no attach process is left; a long
#                   command in the home pane keeps its pid throughout
#   D. targets    — `--worker` lands on that session; a remembered worker that is
#                   gone lands home (no replacement); `--shell` lands home
#   E. control    — claim / paused / take (Use here) / stale check, resize and
#                   release from the old epoch; the new controller survives the
#                   old one's cleanup; resize clamps; an expired lease is claimable
#   F. generation — the home shell exiting (respawn) ⇒ rc 5 `ended`, ensure waits
#                   (rc 5) until --renew (generation 2, same id); the host's server
#                   gone ⇒ `ended`, never `none`
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-webterm selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-webterm selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fwt-st.XXXXXX")" || exit 2
RS="wtR$$"; TL="wtT$$"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$RS"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_SESSION FLEET_VIEW_KEEP_SECS FLEET_CLIENT_LANG FLEET_WEBTERM_LEASE_SECS

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

WT() { python3 "$BIN/fleet-webterm.py" "$@"; }
jf() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read() or "{}"); print(d.get(sys.argv[1], ""))' "$1"; }
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s\n' "$WORK/main" > "$FLEET_CONF_DIR/fleets/$RS/conf"
up() {  # the fleet: a worker and an orchestrator-less session, NO home window
  tn -f /dev/null new-session -d -s "$RS" -n worker7 -x 160 -y 40 'while :; do sleep 300; done' 2>/dev/null || return 1
  tn set-option -g status off
  tn set-option -s exit-empty off
  tn set-window-option -t "=$RS:worker7" @fleet_role worker \; set-window-option -t "=$RS:worker7" @fleet_id fid-7
}

# --- A. no fleet -------------------------------------------------------------------
o=$(WT status); eq "A: status without a fleet" 3 "$?"; eq "A: says nofleet" nofleet "$(printf '%s' "$o" | jf state)"
o=$(WT ensure); eq "A: ensure without a fleet" 3 "$?"
CHECKS=$((CHECKS + 1)); [ ! -e "$FLEET_CONF_DIR/webterm/terminal.json" ] || fail "A: no terminal recorded without a fleet"
o=$(FLEET_WEBTERM_UP_CMD="'$REAL_TMUX' -L '$RS' -f /dev/null new-session -d -s '$RS' -n home 'while :; do sleep 300; done'" WT ensure --init)
eq "A: ensure --init" 0 "$?"; eq "A: live after init" live "$(printf '%s' "$o" | jf state)"
eq "A: one session, nothing else started" 1 "$(tn list-windows -t "=$RS" | wc -l | tr -d ' ')"
tn kill-server 2>/dev/null; rm -rf "$FLEET_CONF_DIR/webterm"
waitfor 3 sh -c "! '$REAL_TMUX' -L '$RS' has-session 2>/dev/null"

# --- B. singleton ------------------------------------------------------------------
up || { printf 'fleet-webterm selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }
for i in 1 2 3 4 5 6 7 8; do ( WT ensure > "$WORK/e$i.json" ) & done; wait
ids=$(for i in 1 2 3 4 5 6 7 8; do jf id < "$WORK/e$i.json"; done | sort -u)
eq "B: 8 ensures, one id" 1 "$(printf '%s\n' "$ids" | grep -c .)"
eq "B: generation 1" 1 "$(jf generation < "$WORK/e1.json")"
eq "B: one home window" 1 "$(tn list-windows -t "=$RS" -F '#{@fleet_role}' | grep -cx home)"
eq "B: one stamped pane" 1 "$(tn list-panes -s -t "=$RS" -F '#{@webterm_id}' | grep -c .)"
HW=$(jf window < "$WORK/e1.json"); HP=$(jf pane < "$WORK/e1.json"); ID=$(jf id < "$WORK/e1.json")
eq "B: home window keeps itself" keep "$(tn show-options -wv -t "$HW" @reap_policy)"
eq "B: home window marked" "$ID" "$(tn show-options -wv -t "$HW" @webterm_home)"
eq "B: agent windows untouched" "" "$(tn show-options -wv -t "=$RS:worker7" @reap_policy 2>/dev/null)"
eq "B: state dir 0700" 700 "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$FLEET_CONF_DIR/webterm")"
eq "B: state file 0600" 600 "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$FLEET_CONF_DIR/webterm/terminal.json")"
hasnt "B: no credential in the state" "$(tr 'A-Z' 'a-z' < "$FLEET_CONF_DIR/webterm/terminal.json")" token
o=$(WT ensure); eq "B: a later ensure reuses it" "$ID" "$(printf '%s' "$o" | jf id)"

# --- C. 20 attach / release cycles -------------------------------------------------
tn send-keys -t "$HP" 'sleep 7777' Enter
spid() { pgrep -f '^sleep 7777$' | head -n 1; }
waitfor 5 sh -c "pgrep -f '^sleep 7777\$' >/dev/null" || fail "C: the long command never started"
SP=$(spid)
mkdir -p "$FLEET_CONF_DIR/remote-views"; printf '%s\n' "deadbeef/fid-gone" > "$FLEET_CONF_DIR/remote-views/.last"
: > "$WORK/first.log"
tt -f /dev/null new-session -d -s "$TL" -n idle -x 160 -y 40 'while :; do sleep 300; done'
browser() {  # <conn> <args…> — a browser PTY running the attach
  local c="$1"; shift
  tt new-window -d -t "=$TL:" -n "b-$c" -e "FLEET_VIEW_FIRST_CMD=echo >> $WORK/first.log" \
    "env -u TMUX FLEET_CONF_DIR='$FLEET_CONF_DIR' TMPDIR='$TMPDIR' python3 '$BIN/fleet-webterm.py' attach --conn $c $*; sleep 300"
}
# no attach for that connection left — a function, not `sh -c`: pgrep -f would
# match the sh holding its own pattern (Linux's dash keeps it as the parent)
noattach() { ! pgrep -f "fleet-remote-view.sh attach --thin --browser --view wt-$1 " >/dev/null; }
attached() { tn list-clients -t "=$RS@view-wt-$1" -F x 2>/dev/null | grep -q x; }
vcur() { tn display-message -p -t "=$RS@view-wt-$1:" '#{window_id}' 2>/dev/null; }
bad=0
for i in $(seq 1 20); do
  c="c$i"; browser "$c"
  waitfor 8 attached "$c" || { bad=$((bad + 1)); fail "C: cycle $i never attached"; continue; }
  [ "$(vcur "$c")" = "$HW" ] || { bad=$((bad + 1)); fail "C: cycle $i not on the home window" "$(vcur "$c")"; }
  tt kill-window -t "=$TL:b-$c"          # the browser goes: its PTY closes
  WT release --conn "$c" >/dev/null
  waitfor 5 noattach "$c" \
    || { bad=$((bad + 1)); fail "C: cycle $i left its attach running"; }
done
eq "C: every cycle clean" 0 "$bad"
eq "C: no view session left" 0 "$(tn list-sessions -F '#{session_name}' | grep -c '@view-wt-')"
eq "C: no registry row left" 0 "$(find "$FLEET_CONF_DIR/remote-views" -name 'wt-*' | wc -l | tr -d ' ')"
eq "C: the long command kept its pid" "$SP" "$(spid)"
eq "C: one personal pane still" 1 "$(tn list-panes -s -t "=$RS" -F '#{@webterm_id}' | grep -c .)"
eq "C: the same terminal" "$ID" "$(WT status | jf id)"
eq "C: never the new-session road" "" "$(cat "$WORK/first.log")"
eq "C: no session started" 2 "$(tn list-windows -t "=$RS" | wc -l | tr -d ' ')"

# --- D. targets --------------------------------------------------------------------
W7=$(tn display-message -p -t "=$RS:worker7" '#{window_id}')
browser d1 --worker "$W7"; waitfor 8 attached d1 || fail "D: --worker never attached"
eq "D: --worker lands on it" "$W7" "$(vcur d1)"
tt kill-window -t "=$TL:b-d1"; WT release --conn d1 >/dev/null
o=$(WT select --worker deadbeef/fid-gone); eq "D: select records" 0 "$?"
browser d2; waitfor 8 attached d2 || fail "D: remembered never attached"
eq "D: a gone remembered worker lands home" "$HW" "$(vcur d2)"
tt kill-window -t "=$TL:b-d2"; WT release --conn d2 >/dev/null
WT select --worker "$W7" >/dev/null
browser d3 --shell; waitfor 8 attached d3 || fail "D: --shell never attached"
eq "D: --shell lands home" "$HW" "$(vcur d3)"
tt kill-window -t "=$TL:b-d3"; WT release --conn d3 >/dev/null
eq "D: still no session started" "" "$(cat "$WORK/first.log")"
o=$(WT attach --conn 'x;y' 2>&1); eq "D: a bad conn id refused" 2 "$?"

# --- E. control --------------------------------------------------------------------
C() { WT control "$@" --target personal; }
o=$(C claim --conn a); eq "E: first claim" 0 "$?"; eq "E: epoch 1" 1 "$(printf '%s' "$o" | jf epoch)"
o=$(C claim --conn b); eq "E: second browser paused" 4 "$?"; eq "E: says paused" paused "$(printf '%s' "$o" | jf state)"
C check --conn a --epoch 1 >/dev/null; eq "E: controller's input ok" 0 "$?"
o=$(C take --conn b); eq "E: Use here" 0 "$?"; eq "E: epoch 2" 2 "$(printf '%s' "$o" | jf epoch)"
C check --conn a --epoch 1 >/dev/null; eq "E: old input rejected" 1 "$?"
C resize --conn a --epoch 1 --cols 80 --rows 24 >/dev/null; eq "E: old resize rejected" 1 "$?"
C release --conn a --epoch 1 >/dev/null; eq "E: old cleanup refused" 1 "$?"
C check --conn b --epoch 2 >/dev/null; eq "E: new controller survives it" 0 "$?"
o=$(C resize --conn b --epoch 2 --cols 99999 --rows 1)
eq "E: cols clamped" 500 "$(printf '%s' "$o" | jf cols)"; eq "E: rows clamped" 5 "$(printf '%s' "$o" | jf rows)"
C claim --conn a >/dev/null; eq "E: a fresh lease holds" 4 "$?"
f=$(find "$FLEET_CONF_DIR/webterm/control" -name '*.json' | head -n 1)
python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["ts"] = 0; json.dump(d, open(sys.argv[1], "w"))
PY
o=$(C claim --conn a); eq "E: an expired lease is claimable" 0 "$?"; eq "E: epoch 3" 3 "$(printf '%s' "$o" | jf epoch)"
C renew --conn b --epoch 2 >/dev/null; eq "E: the expired one cannot renew" 1 "$?"
C release --conn a --epoch 3 >/dev/null; eq "E: the controller releases" 0 "$?"

# --- F. generation -----------------------------------------------------------------
tn respawn-pane -k -t "$HP"
o=$(WT status); eq "F: shell gone ⇒ ended" 5 "$?"
o=$(WT ensure); eq "F: ensure waits for the user" 5 "$?"
eq "F: still generation 1" 1 "$(WT status | jf generation)"
o=$(WT ensure --renew); eq "F: --renew" 0 "$?"
eq "F: generation 2" 2 "$(printf '%s' "$o" | jf generation)"; eq "F: same terminal" "$ID" "$(printf '%s' "$o" | jf id)"
tn kill-server
waitfor 3 sh -c "! '$REAL_TMUX' -L '$RS' has-session 2>/dev/null"
o=$(WT status); eq "F: host lost ⇒ ended" 5 "$?"; eq "F: says ended" ended "$(printf '%s' "$o" | jf state)"

if [ "$FAIL" -eq 0 ]; then
  printf 'fleet-webterm selftest: PASS (%s checks)\n' "$CHECKS"; exit 0
fi
printf 'fleet-webterm selftest: %s of %s checks FAILED\n' "$FAIL" "$CHECKS" >&2; exit 1
