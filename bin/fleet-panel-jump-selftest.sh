#!/bin/bash
# fleet-panel-jump-selftest.sh — the panels' 「到 …」 button (issue #2834, EPIC
# #2831): bin/fleet-panel-jump.sh goes through fleet_win_for_key and refuses
# rather than guesses. On an isolated tmux server:
#   A  orchestrator: one window wears @fleet_role orchestrator → exit 0, the
#      session's current window is it
#   B  NOTFOUND: no window wears the role → exit 1, the current window unchanged
#   C  AMBIGUOUS: two windows wear it → exit 2, the current window unchanged
#   D  no key / no pane → exit 3
#   E  (issue #2833) the viewers: two control-mode clients — one on the fleet
#      session looking at the pane's window, one on a grouped view session
#      (#1489) looking elsewhere. A batch driver's key (scratch-<N>) moves ONLY
#      the first; nobody looking ⇒ the fleet session (its GROUP, never the view)
#      selects it and no client moves; `--pane` names whose viewers move.
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'panel-jump selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/panel-jump.XXXXXX")" || exit 2
L="pjump$$"
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE
CPIDS=''
cleanup() {
  exec 3>&- 4>&- 2>/dev/null
  tmux -L "$L" kill-server 2>/dev/null
  for p in $CPIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

FAIL=0
pass() { printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1" >&2; }

tmux -L "$L" -f /dev/null new-session -d -s "$L" -n steward -x 120 -y 30 'sleep 600'
tmux -L "$L" new-window -d -t "$L:" -n orch 'sleep 600'
tmux -L "$L" new-window -d -t "$L:" -n other 'sleep 600'
w_st=$(tmux -L "$L" display-message -p -t "$L:steward" '#{window_id}')
w_or=$(tmux -L "$L" display-message -p -t "$L:orch" '#{window_id}')
w_ot=$(tmux -L "$L" display-message -p -t "$L:other" '#{window_id}')
pane=$(tmux -L "$L" display-message -p -t "$L:steward" '#{pane_id}')
tmux -L "$L" set-option -w -t "$w_st" @fleet_role steward
sock=$(tmux -L "$L" display-message -p '#{socket_path}')
cur() { tmux -L "$L" display-message -p -t "$L:" '#{window_id}'; }
jump() { TMUX="$sock,1,0" TMUX_PANE="$pane" bash "$BIN/fleet-panel-jump.sh" "$@" 2>/dev/null; }

# B — nobody wears the role
tmux -L "$L" select-window -t "$w_st"
jump orchestrator; rc=$?
[ "$rc" = 1 ] && [ "$(cur)" = "$w_st" ] && pass "B: NOTFOUND → exit 1, nothing switched" || bad "B: rc=$rc cur=$(cur)"

# A — one orchestrator
tmux -L "$L" set-option -w -t "$w_or" @fleet_role orchestrator
jump orchestrator; rc=$?
[ "$rc" = 0 ] && [ "$(cur)" = "$w_or" ] && pass "A: orchestrator → exit 0, its window is current" || bad "A: rc=$rc cur=$(cur) want $w_or"

# C — two of them
tmux -L "$L" select-window -t "$w_st"
tmux -L "$L" set-option -w -t "$w_ot" @fleet_role orchestrator
jump orchestrator; rc=$?
[ "$rc" = 2 ] && [ "$(cur)" = "$w_st" ] && pass "C: AMBIGUOUS → exit 2, nothing switched" || bad "C: rc=$rc cur=$(cur)"

# D — usage
jump; rc=$?
TMUX="$sock,1,0" bash "$BIN/fleet-panel-jump.sh" orchestrator 2>/dev/null; rc2=$?
[ "$rc" = 3 ] && [ "$rc2" = 3 ] && pass "D: no key / no pane → exit 3" || bad "D: rc=$rc rc2=$rc2"

# E — the viewers (issue #2833)
mkdir -p "$WORK/app-scratch-5"
w_dr=$(tmux -L "$L" new-window -d -P -F '#{window_id}' -t "$L:" -n 面板·批次 'sleep 600')
tmux -L "$L" set-option -w -t "$w_dr" @raw 1; tmux -L "$L" set-option -w -t "$w_dr" @worktree "$WORK/app-scratch-5"
p_ot=$(tmux -L "$L" display-message -p -t "$w_ot" '#{pane_id}')
tmux -L "$L" select-window -t "$w_st"
tmux -L "$L" new-session -d -t "$L" -s "$L@view-1"
tmux -L "$L" select-window -t "$L@view-1:$w_ot"
# control-mode clients, kept attached by a FIFO this shell holds open — no sleeper to outlive the test
mkfifo "$WORK/c1" "$WORK/c2"
tmux -L "$L" -C attach -t "$L" <"$WORK/c1" >/dev/null 2>&1 & CPIDS="$CPIDS $!"
exec 3>"$WORK/c1"
tmux -L "$L" -C attach -t "$L@view-1" <"$WORK/c2" >/dev/null 2>&1 & CPIDS="$CPIDS $!"
exec 4>"$WORK/c2"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(tmux -L "$L" list-clients -F x 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ] && break; sleep 0.3
done
viewing() { tmux -L "$L" list-clients -F '#{session_name} #{window_id}' | awk -v s="$1" '$1 == s { print $2 }' | sort -u; }
if [ "$(viewing "$L")" = "$w_st" ] && [ "$(viewing "$L@view-1")" = "$w_ot" ]; then
  jump scratch-5; rc=$?
  [ "$rc" = 0 ] && [ "$(viewing "$L")" = "$w_dr" ] && [ "$(viewing "$L@view-1")" = "$w_ot" ] \
    && pass "E: the pane's viewer moves to the driver, the view session's does not" \
    || bad "E: rc=$rc fleet=$(viewing "$L") view=$(viewing "$L@view-1")"
  # nobody looks at the steward's window now: its fleet session (the group) selects it
  tmux -L "$L" select-window -t "$L:$w_ot"
  jump scratch-5; rc=$?
  [ "$rc" = 0 ] && [ "$(cur)" = "$w_dr" ] && [ "$(viewing "$L@view-1")" = "$w_ot" ] \
    && pass "E: nobody looking → the fleet session selects it, the view client stays" \
    || bad "E: nobody looking rc=$rc cur=$(cur) view=$(viewing "$L@view-1")"
  # --pane: the viewers of `other` (both clients now) move
  TMUX="$sock,1,0" bash "$BIN/fleet-panel-jump.sh" scratch-5 --pane "$p_ot" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] && [ "$(viewing "$L@view-1")" = "$w_dr" ] \
    && pass "E: --pane names whose viewers move" || bad "E: --pane rc=$rc view=$(viewing "$L@view-1")"
else
  bad "E: setup — clients look at $(tmux -L "$L" list-clients -F '#{session_name}:#{window_id}' | tr '\n' ' ')"
fi

[ "$FAIL" = 0 ] && echo 'panel-jump selftest: all passed' && exit 0
exit 1
