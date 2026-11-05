#!/bin/bash
# selftest-entry
# shellcheck disable=SC2154,SC2016 # sourced rig fields; bash -c positional args
# Real remote select + phone-sized thin view; all servers and homes are isolated.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need tmux python3
REAL_TMUX=$(command -v tmux)
PR_WORK=$(mktemp -d /tmp/fce.XXXXXX)
unset TMUX TMUX_PANE FLEET_C FLEET_STATUS_G
. "$BIN/fleet-view-peer-rig.sh"
cleanup() { pr_down; rm -rf "$PR_WORK"; }
trap cleanup EXIT INT TERM
pr_up || st_fail 'peer rig failed'
pr_attach
pr_wait 15 pr_up_link far1 || st_fail 'link did not come up'
pr_wait 15 test -f "$PR_WORK/m/home/conf/remote-views/v1" || st_fail 'home view did not attach'
pr_wait 15 pr_t far1 has-session -t "=$PR_FS1@view-v1-via-home" 2>/dev/null || st_fail 'far view did not attach'
fid=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
# Old record: no titles/options extension is needed to restore its window.
pr_in far1 python3 - "$BIN" "$fid" "$PR_FS1" <<'PYREC'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_park_cold as c
c.gate.fid_dir(sys.argv[2]).mkdir(parents=True, exist_ok=True)
c.write(sys.argv[2], dict(session=sys.argv[3], name='cold conversation'))
PYREC
cat > "$PR_WORK/reopen" <<'REOPEN'
#!/bin/bash
sleep 4
w=$(tmux -L "$FLEET_SESSION" new-window -d -P -F '#{window_id}' -t "=$FLEET_SESSION:" 'printf "COLD-RESTORED\n"; sleep 120')
tmux -L "$FLEET_SESSION" set-option -w -t "$w" @fleet_id "$1" \; set-option -w -t "$w" @fleet_role worker \; set-option -w -t "$w" @parked 1 \; set-option -w -t "$w" @park_held 1
printf '%s\n' "$w" > "$PR_WORK/restored"
REOPEN
chmod +x "$PR_WORK/reopen"
printf ' FLEET_PARK_COLD_REOPEN_CMD=%s\n' "$PR_WORK/reopen" >> "$PR_WORK/env/far1"
pr_t term send-keys -t "=$PR_TL:view" Escape
# A small terminal uses exactly the same remote selector; >3s startup proves
# the old peer timeout cannot lose this successful restore.
pr_t term resize-window -t "=$PR_TL:view" -x 50 -y 24
if ! pr_in home python3 - "$BIN" "$PR_U_far1/$fid" "$PR_ME" <<'PYGO'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_view as v
import importlib.util
s=importlib.util.spec_from_file_location('qo', sys.argv[1]+'/fleet-quickopen.py')
q=importlib.util.module_from_spec(s); s.loader.exec_module(q)
rc=v.go(q, 'v1', sys.argv[2], 'search', meta=dict(machine='far1', login=sys.argv[3], state='parked', recoverable=True))
assert rc == 0, rc
PYGO
then st_fail 'cold remote search did not land'; fi
[ -s "$PR_WORK/restored" ] || st_fail 'no restored window'
want=$(cat "$PR_WORK/restored")
got=$(pr_t far1 display-message -p -t "=$PR_FS1@view-v1-via-home:" '#{window_id}')
[ "$got" = "$want" ] || st_fail "selected $got instead of $want"
pr_wait 5 bash -c '"$1" -L "$2" capture-pane -p -t "=$2:view" | grep -q COLD-RESTORED' _ "$REAL_TMUX" "$PR_TL" || { pr_screen; pr_t home list-windows -a -F '#{session_name} #{window_id} #{@peer_cur}'; st_fail 'phone did not display restored session'; }
# Browser / reconnect --want passes through the same target-side warming gate.
pr_in far1 bash "$BIN/fleet-remote-view.sh" select "$PR_U_far1/$fid" v1-via-home || st_fail 'second select failed'
echo 'PASS cold remote select, delayed wake, phone screen and search identity'
