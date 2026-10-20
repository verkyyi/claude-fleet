#!/bin/bash
# fleet-view-c7-selftest.sh — ⌘N ⌘T ⌃\ ⌘Q and `fleet ls / open / claude` on the
# thin path (issue #3004, EPIC #2999 C7).
#
# Isolated sockets only, as fleet-view-selftest.sh: an INNER server is the home
# machine (a fleet session `fl` + a 看台 `fl@view-v1` grouped onto it, key-table
# fleet-view), an OUTER server is the person's terminal — its panes `tmux attach`
# to the inner one, so a byte sent into an outer pane is a key typed on the
# client, and capture-pane of the outer pane is what the person sees. A second
# outer pane attaches to `fl` DIRECTLY: every key there must do nothing of ours.
#
#   N  ⌘N (T670, EPIC T651 C2): the 「新会话」 box, both values chosen — the session
#      in view's repo (its @repo), else the last new session's (不绑仓库 counts) —
#      and ↵ (2 keys) opens a NEW session every time (fleet_view.go_new, issue
#      #3119): dash-raw-session.sh --origin hub --no-repo | --repo R --agent A
#      --print <fleet> (FLEET_VIEW_NEW_CMD) — once — the 看台 onto the window it printed
#      (logged how=new) — never the window holding the orchestrator, even with
#      orch_<fleet> naming one, and no orchestrator script run at all
#      (FLEET_VIEW_ORCH_CMD would leave a mark); a direct attach: nothing;
#      each ⌘N one run in timing/session.ndjson (#3551, T684): window · typeable · total
#   T  ⌘T and ⌘K, keys issue #3328 folded into ⌘P: the panel (its first
#      frame one run in timing/panel.ndjson, #3551) — ⌘T lit on
#      its ⚡ row, no 派一件事 popup — saying 「⌘T 已并进 ⌘P」 the first time only;
#      each press logged how=old:<action>; `send --agent codex` still carries; a direct attach: nothing
#   S  ⌃\: the session's shell — here: a window of the 看台 (@view_shell, panel,
#      @peer_view) whose shell's directory is the session's @worktree; ⌃\ again is
#      back on the session, ⌃\ there selects the same one (one a session); the
#      session's window gone takes its shell along. Another machine's: a channel
#      on C5's link (`ssh -S <link> -l <login> mac-a … shell-here <wid>`), its prompt
#      in the far worktree. A direct attach: no shell window. Issue #3183: `do
#      shell --target` (a row's Tab page) opens THAT session's shell though it is not on screen, in
#      the directory its agent is in (@agent_cwd — its last Bash call's cwd — else
#      the agent pane's: cd'd into bin/ → …/bin; both gone → @worktree; `do shell
#      --target <window | fleet_id>`), ⌘P from the
#      shell lights its session (↵ back), a second one selects the one open, and
#      `exit` closes the shell window alone — the session's window, its
#      @claude_state and its process unchanged
#   H  ⌘\ · ⌃\ (EPIC T651 C3): the home shell — this machine's login shell in
#      $HOME, one window of the 看台 (`@view_shell home`), from a session, from
#      ⌘P's list and its 新会话 box (⌘\ sends ⌃\'s byte), back and forth;
#      `do home`; a direct attach: nothing
#   P  ⌘P's one entry (issue #3327, EPIC #3178 ④ — 方案 B; #3180 before it): the
#      search line is the only input; under the sessions ONE ⚡ row (「⚡ 新会话」)
#      then ⏻ 退出 — no other command row; FLEET_PANEL_COMMANDS `none` takes them
#      away, the retired `shell` / `newsess` make none (`view-panel`). ⚡ (↵ on
#      words that hit nothing, Tab on it) opens the 「新会话」 box (T652, EPIC T651
#      C1): 仓库 ‹›, Agent ‹›, 开 ↵ — three items, nothing to type, opened on 开 with
#      both chosen; ↑↓ walk, ←→ change, ↵ on a value goes to 开, ↵ on 开 is ⌘N's
#      argv with --repo / --no-repo and --agent (no send, no words), the 看台 on
#      it, the choice kept per view; ⏻ = ⌘Q's OSC 7502 + detach
#   I  ⌘P's language row (issue #3329, EPIC #3178 D7): 语言 lights 「◐ 语言 / Language」,
#      ↵ flips to English — kept on the hub (a seam) and re-read here at once, the
#      panel redrawn in it with a 3 s line — Tab's 跟系统走 takes it back; none
#      said ⇒ 中文 and the Termius line (D9). FLEET_VIEW_LANG_EVIDENCE=<prefix>
#      keeps the two screens.
#   Q  ⌘Q: `ESC ] 7502 ; quit ; token=<the row's> BEL` on the client's tty, then
#      the client detached; a direct attach stays
#   L  `fleet ls` with no client tmux: one ssh to the home (fleet-thin.py --run:
#      ControlMaster=no, ControlPath=none, -T) running `fleet-session-cli.py --home
#      ls` — two machines' sessions listed; `--home open` moves the newest live 看台
#   C  `fleet claude` with FLEET_CLIENT=thin: the home's fleet-client-place.sh
#      `- home --agent claude` over --run, then the thin client onto the worker id
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$(cd "$BIN/.." && pwd)"
st_need tmux
W=$(mktemp -d "${TMPDIR:-/tmp}/fview7.XXXXXX") || exit 1
IN="$W/in.sock"; OUT="$W/out.sock"
cleanup() {
  [ -n "${FLEET_VIEW_KEEP:-}" ] && { echo "kept: $W" >&2; return; }
  for s in "$IN" "$OUT"; do tmux -S "$s" kill-server 2>/dev/null; done
  rm -rf "$W"
}
trap cleanup EXIT INT TERM
mkdir -p "$W/wt-gamma/bin" "$W/wt-delta/gone" "$W/conf/remote-views/v1.d" "$W/conf/peerlink" "$W/g" "$W/home" "$W/state" "$W/wt-alpha" "$W/farwt" "$W/rbin"
ME=$(id -un)
US=$'\037'
T=$'\t'
UU=11111111-2222-3333-4444-555555555555; MU=22222222-3333-4444-5555-666666666666
ti() { tmux -S "$IN" "$@"; }
to() { tmux -S "$OUT" "$@"; }
cur() { ti display-message -p -t 'fl@view-v1:' '#{window_id}'; }
waitfor() {   # <secs*4> <cmd…> — until the command succeeds (looked at every 0.1 s)
  local n=$(( $1 * 5 / 2 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done
  return 1
}
# prompt_ready — the 看台's pane shows a shell prompt (bounded 1 s, as the sleep it
# replaces: a prompt that looks otherwise only costs that second)
prompt_ready() { waitfor 4 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -v '^\$' | tail -n 1 | grep -q '[\$#] *\$'" || :; }
# now_on <window> — the 看台 shows that window (bounded 0.3 s, as before)
now_on() { waitfor 1 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$1' ]" || :; }

# --- the seams the home machine's keys run through ------------------------------
# ⌘N: dash-raw-session.sh's stand-in — its argv kept, a window opened, the
# --print receipt (`<window_id>\t<name>\t<worktree>\t<fleet_id>`) back
cat > "$W/newsess.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> '$W/new.argv'
n=\$(wc -l < '$W/new.argv' | tr -d ' ')
w=\$(tmux -S '$IN' new-window -d -P -F '#{window_id}' -t fl -n "new\$n" 'sleep 600') || exit 1
printf '%s\tnew%s\t\tfid%s\n' "\$w" "\$n" "\$n"
EOF
# an orchestrator script, should anything still call one: it leaves a mark
cat > "$W/ensure.sh" <<EOF
#!/bin/sh
: > '$W/orch.called'
exit 1
EOF
# ⌘T's send: the payload kept, one filed line back
cat > "$W/send.sh" <<EOF
#!/bin/sh
i=0; while [ -e '$W/slow' ] && [ \$i -lt 30 ]; do sleep 0.1; i=\$((i + 1)); done
cp "\$1" '$W/sent.json'
echo x >> '$W/send.calls'
echo 'REMOTE mac-a start done $MU/new9	filed: #77'
EOF
# C5's link to mac-a: a fake ssh — `select` answers at once, anything else is the far
# shell: its argv kept, a shell in the far worktree
cat > "$W/fakessh.sh" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in *'fleet-remote-view.sh select'*) exit 0 ;; esac; done
printf '%s\n' "\$@" > '$W/ssh.argv'
cd '$W/farwt' && exec /bin/sh -i
EOF
# the person's task authority, asked of no real hub: legacy (the 新会话 box's repo start)
printf '#!/bin/sh\necho legacy\n' > "$W/legacy.sh"
chmod +x "$W/ensure.sh" "$W/newsess.sh" "$W/send.sh" "$W/fakessh.sh" "$W/legacy.sh"
: > "$W/conf/peerlink/mac-a.sock"
printf '{"links":[{"machine":"mac-a","login":"%s","phase":"up","sock":"%s","host":"mac-a"}]}\n' "$ME" "$W/conf/peerlink/mac-a.sock" \
  > "$W/conf/peerlink/state.json"
printf 'acme/app\nacme/web\n' > "$W/g/hub_repos"
: > "$W/rows.txt"

export HOME="$W/home" FLEET_CONF_DIR="$W/conf" FLEET_STATUS_G="$W/g" FLEET_UI_LANG=zh LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
  FLEET_VIEW_ORCH_CMD="sh $W/ensure.sh" FLEET_VIEW_NEW_CMD="sh $W/newsess.sh" FLEET_DISPATCH_SEND_CMD="sh $W/send.sh" FLEET_DISPATCH_AGENTS_HERE=claude \
  FLEET_DISPATCH_AUTHORITY_CMD="$W/legacy.sh" \
  FLEET_SWITCH_STATE="$W/state" FLEET_AGENT=claude FLEET_SESSION_SHELL_WATCH=1 FLEET_PEERLINK_SSH="$W/fakessh.sh" \
  SHELL=/bin/sh FLEET_VIEW_ROWS_CMD="cat '$W/rows.txt'"
unset TMUX TMUX_PANE FLEET_SHELL FLEET_SESSION FLEET_CLIENT
# C7's keys are a person's to add since issue #3185 (by default only the panel)
export FLEET_KEYS_EXTRA='next=cmd+down prev=cmd+up back=cmd+[ fwd=cmd+] new=cmd+n dispatch=cmd+t quit=cmd+q shell=ctrl+\\'
export FLEET_KEYS_PHONE_EXTRA='ctrl+]n=next ctrl+]b=prev ctrl+]c=new ctrl+]t=dispatch ctrl+]q=quit ctrl+]\\=shell'

# --- the home: a fleet, a 看台, two clients ------------------------------------------------
# panes ignore ⌃\ (stty -isig) so a key that reaches one shows instead of killing it
pane() { printf "sh -c 'echo %s; stty -isig 2>/dev/null; exec cat > \"%s\"'" "$1" "$2"; }
ti -f /dev/null new-session -d -s fl -x 120 -y 30 -n orch "$(pane ORCH "$W/pane0.in")" || st_fail "inner tmux"
ti source-file "$ROOT/conf/tmux-view.conf" 2>"$W/src.err" || st_fail "tmux-view.conf did not source: $(cat "$W/src.err")"
W0=$(ti display-message -p -t 'fl:orch' '#{window_id}')
W1=$(ti new-window -d -P -F '#{window_id}' -t fl -n alpha -c "$W/wt-alpha" "$(pane ALPHA "$W/pane1.in")")
W2=$(ti new-window -d -P -F '#{window_id}' -t fl -n beta "$(pane BETA "$W/pane2.in")")
ti set-option -w -t "$W0" @fleet_role orchestrator
ti set-option -w -t "$W1" @fleet_id f1; ti set-option -w -t "$W1" @worktree "$W/wt-alpha"
ti set-option -w -t "$W2" @fleet_id f2
ti new-session -d -t fl -s 'fl@view-v1' || st_fail "no 看台 session"
ti set-option -t 'fl@view-v1' key-table fleet-view
ti select-window -t "=fl@view-v1:$W2"
printf '%s\tfl\tthin\t%s\t%s\tcur=%s/f2\troute=lan\tdevice=\ttoken=tok7\tfuid=%s\tnode=nodeA\n' \
  /dev/null "$(date +%s)" "$$" "$UU" "$UU" > "$W/conf/remote-views/v1"
to -f /dev/null new-session -d -s o -x 120 -y 32 -n view "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'" || st_fail "outer tmux"
to new-window -d -t o -n direct "TMUX= tmux -S '$IN' attach -t fl"
waitfor 8 sh -c "[ \"\$(tmux -S '$IN' list-clients | wc -l | tr -d ' ')\" = 2 ]"
[ "$(ti list-clients | wc -l | tr -d ' ')" = 2 ] || st_fail "the two clients did not attach: $(ti list-clients)"
nwin() { ti list-windows -t fl | wc -l | tr -d ' '; }

# --- N: ⌘N ----------------------------------------------------------------------------------
before=$(nwin); fcur=$(ti display-message -p -t 'fl:' '#{window_id}')
to send-keys -t o:direct -H 1b 5b 39 32 38 7e
sleep 1
[ "$(nwin)" = "$before" ] && [ "$(ti display-message -p -t 'fl:' '#{window_id}')" = "$fcur" ] \
  || st_fail "N: ⌘N did something in a session attached directly"
[ -s "$W/pane0.in" ] && st_fail "N: ⌘N's bytes reached a pane in a direct attach: $(od -c "$W/pane0.in" | head -2)"
# the orchestrator's holder here and orch_<fleet> naming another machine's: ⌘N
# goes to neither — a new session, every press
printf '%s\n' "$MU/orch4${US}mac-a${US}online${US}working${US}${US}" > "$W/g/orch_fl"
# ⌘N: the box, opened chosen (the view is on beta — no repo — and nothing was
# opened before: 不绑仓库 · the fleet's Claude); ↵ opens
nbox() {
  # the last box's popup has closed (it closes once the 看台 is on the new session)
  waitfor 20 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q '⚡'" || st_fail "N: the last box stayed open"
  to send-keys -t o:view -H 1b 5b 39 32 38 7e
  waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '开 ↵'" || st_fail "N: ⌘N did not open the box: $(to capture-pane -p -t o:view)"
  waitfor 48 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -Eq '仓库 ‹(acme/|不绑仓库)'" || st_fail "N: the box's repo did not load"
  to capture-pane -p -t o:view > "$W/nbox.txt"
}
nbox
grep -q '仓库 ‹不绑仓库›' "$W/nbox.txt" && grep -q 'Agent ‹Claude›' "$W/nbox.txt" \
  || st_fail "N: ⌘N's box did not open on 不绑仓库 · Claude: $(grep -v '^$' "$W/nbox.txt")"
grep -q '已并进' "$W/nbox.txt" && st_fail "N: ⌘N still says it was folded into ⌘P"
to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new1" || st_fail "N: ⌘N ↵ in the 看台 opened no new session"
N1=$(ti list-windows -t fl -F '#{window_id} #{window_name}' | awk '$2 == "new1" { print $1 }')
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$N1' ]" \
  || st_fail "N: ⌘N did not land the 看台 on the new session (now $(cur), it is $N1)"
[ "$(cur)" != "$W0" ] || st_fail "N: ⌘N landed on the orchestrator's holder"
[ "$(head -1 "$W/new.argv")" = "--origin hub --no-repo --agent claude --print fl" ] \
  || st_fail "N: the new session was not asked as a no-repo one of this fleet: $(head -1 "$W/new.argv")"
log="$W/conf/logs/view-switch.ndjson"
tail -1 "$log" | grep -q '"how":"new"' || st_fail "N: the switch is not logged how=new: $(tail -1 "$log")"
# looking at a session of acme/app: the next box is acme/app's
ti set-option -w -t "$N1" @repo acme/app
nbox
grep -q '仓库 ‹acme/app›' "$W/nbox.txt" || st_fail "N: ⌘N on an acme/app session did not default to acme/app: $(grep -v '^$' "$W/nbox.txt")"
[ -n "${FLEET_VIEW_EVIDENCE:-}" ] && cp "$W/nbox.txt" "$FLEET_VIEW_EVIDENCE.cmdn"
to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new2" || st_fail "N: a second ⌘N opened no second session"
[ "$(sed -n 2p "$W/new.argv")" = "--origin hub --repo acme/app --agent claude --print fl" ] \
  || st_fail "N: the second ⌘N did not open acme/app's: $(sed -n 2p "$W/new.argv")"
waitfor 10 python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repo"]=="acme/app" and d["agent_by_repo"]=={"":"claude","acme/app":"claude"}, d' \
  "$W/state/compose-state.json" 2>/dev/null || st_fail "N: the box's choices were not remembered: $(cat "$W/state/compose-state.json")"
# esc closes a ⌘N box at once — there is no list it came from
waitfor 20 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q '⚡'" || st_fail "N: the second box stayed open"
to send-keys -t o:view -H 1b 5b 39 32 38 7e
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '开 ↵'" || st_fail "N: a third ⌘N opened no box"
to send-keys -t o:view Escape
waitfor 8 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q '⚡'" || st_fail "N: esc did not close a ⌘N box"
N2=$(ti list-windows -t fl -F '#{window_id} #{window_name}' | awk '$2 == "new2" { print $1 }')
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$N2' ]" \
  || st_fail "N: the second ⌘N did not land on its new session (now $(cur), it is $N2)"
[ -e "$W/orch.called" ] && st_fail "N: ⌘N ran an orchestrator script"
# the session clock (issue #3551, T684): every ⌘N a run in timing/session.ndjson —
# window · typeable · total, each since the ↵ (a session starts cold, T495)
waitfor 10 sh -c "python3 '$BIN/fleet_timing.py' check | grep -q '^session n=2 .* cold=0\$'" \
  || st_fail "N: the two ⌘N are not two session runs: $(python3 "$BIN/fleet_timing.py" check)"
python3 - "$FLEET_CONF_DIR/timing/session.ndjson" <<'PY' || st_fail "N: a ⌘N's run is not window · typeable · total"
import json, sys
runs = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    assert set(r) == {"ts", "what", "seg", "ms"} and r["what"] == "session", r
    runs.setdefault(r["ts"], []).append(r["seg"])
sys.exit(0 if all(v == ["window", "typeable", "total"] for v in runs.values()) else 1)
PY
rm -f "$W/g/orch_fl"
# another machine's C4 window (made here, link up) — the S and Q legs use it
PW=$(ti new-window -d -P -F '#{window_id}' -t fl -n @mac-a 'sleep 600')
for o in "@fleet_role panel" "@peer mac-a@$ME" "@peer_view v1" "@peer_node mac-a" "@peer_login $ME" "@peer_cur wid:$MU/far1"; do
  ti set-option -w -t "$PW" ${o%% *} "${o#* }"
done
st_ok_all "N  ⌘N: the box chosen (the session in view's repo, else the last), ↵ a new session every time, the 看台 on it — never the orchestrator's holder, no orchestrator script; a direct attach: nothing"

# --- T: ⌘T and the other keys issue #3328 / T685 took away ------------------------------------
# ⌘T's 派一件事 popup has no entry any more: ⌘T, as the person's own extra
# (dispatch=cmd+t), opens the panel lit on its ⚡ row. A key T685 gave back to
# iTerm2 (⌘K here — code 930, no extra names it) does nothing when an older
# profile still sends it: no panel, no line in view-switch.ndjson.
to send-keys -t o:direct -H 1b 5b 39 33 32 7e
sleep 1.5
to capture-pane -p -t o:direct | grep -q '⚡' && st_fail "T: ⌘T opened the panel in a direct attach"
log="$W/conf/logs/view-switch.ndjson"
# the panel runs leg N's ⌘N boxes left (each is the panel too)
pn=$(python3 "$BIN/fleet_timing.py" check | sed -n 's/^panel n=\([0-9]*\) .*/\1/p'); pn=${pn:-0}
to send-keys -t o:view -H 1b 5b 39 33 32 7e
ok=''; for _ in $(seq 1 80); do
  sleep 0.1; to capture-pane -p -t o:view > "$W/dispatch.txt"; grep -q '  ⚡ 新会话' "$W/dispatch.txt" && { ok=1; break; }
done
[ -n "$ok" ] || st_fail "T: ⌘T in the 看台 did not open the panel lit on ⚡: $(grep -v '^$' "$W/dispatch.txt")"
grep -q '已并进' "$W/dispatch.txt" && st_fail "T: ⌘T still says 「已并进 ⌘P」 (the hint went with T685)"
grep -q '用哪个 Coding Agent' "$W/dispatch.txt" && st_fail "T: ⌘T still opened the 派一件事 popup"
# the panel's own rows (T685): 回家命令行 and 退出 fleet stand in it
grep -q '⌂ 回家命令行' "$W/dispatch.txt" || st_fail "T: the panel has no 回家命令行 row: $(grep -v '^$' "$W/dispatch.txt")"
grep -q '⏻ 退出 fleet' "$W/dispatch.txt" || st_fail "T: the panel has no 退出 fleet row"
# the panel clock (issue #3551): the frame drawn ⇒ one run boot · read · frame · total
waitfor 10 sh -c "python3 '$BIN/fleet_timing.py' check | grep -q '^panel n=$((pn + 1)) '" \
  || st_fail "T: the panel's first frame left no run in timing/panel.ndjson: $(python3 "$BIN/fleet_timing.py" check)"
python3 "$BIN/fleet_timing.py" table panel | grep -q '^| frame | ' || st_fail "T: the panel run has no frame segment: $(python3 "$BIN/fleet_timing.py" table panel)"
[ -n "${FLEET_VIEW_EVIDENCE:-}" ] && cp "$W/dispatch.txt" "$FLEET_VIEW_EVIDENCE"
# typed words land on a row of the panel's own: 退出 → ⏻, and ↵ asks before it quits
to send-keys -t o:view -l '退出'
waitfor 10 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '  ⏻ 退出 fleet'" || st_fail "T: typing 退出 did not light ⏻: $(to capture-pane -p -t o:view | grep -v '^$' | tail -6)"
to send-keys -t o:view Enter
waitfor 10 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '(y/n)'" || st_fail "T: ↵ on ⏻ did not ask first: $(to capture-pane -p -t o:view | grep -v '^$' | tail -4)"
to send-keys -t o:view n
sleep 0.5; [ -n "$(to list-panes -t o:view -F '#{pane_dead}' | grep -x 0)" ] || st_fail "T: n on 退出's question ended the connection"
to send-keys -t o:view Escape; to send-keys -t o:view Escape; waitfor 4 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q '  ⚡'"
lines=$(grep -c . "$log" 2>/dev/null || echo 0)
to send-keys -t o:view -H 1b 5b 39 33 30 7e
sleep 1.5
to capture-pane -p -t o:view | grep -q '  ⚡' && st_fail "T: ⌘K (retired code 930) opened the panel (T685: it does nothing)"
[ "$(grep -c . "$log" 2>/dev/null || echo 0)" = "$lines" ] || st_fail "T: ⌘K (930) left a line in view-switch.ndjson: $(tail -1 "$log")"
grep -q '"how":"old:' "$log" 2>/dev/null && st_fail "T: a press is still logged how=old:<action> (the forwards went with T685)"
# the one message after the update (fleet-remote-view.sh attach --thin runs view-notice):
# on the 看台's client once, then never again on this login
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" view-notice --view fl@view-v1 || st_fail "T: view-notice exited non-zero"
[ -s "$W/conf/keys-notice-T685" ] || st_fail "T: view-notice left no mark — it would say it at every attach"
grep -q 'view-notice --view' "$BIN/fleet-remote-view.sh" || st_fail "T: attach --thin does not run view-notice"
# ⌘T's send itself is ⌘P's ⚡ (leg P); `send` keeps its --agent
python3 "$BIN/fleet-quick-dispatch.py" send --title '看日志' --repo acme/web --agent codex --view fl@view-v1 >/dev/null \
  || st_fail "T: send --agent codex --view exited non-zero"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agent"))' "$W/sent.json")" = codex ] \
  || st_fail "T: --agent codex did not ride the payload: $(cat "$W/sent.json")"
rm -f "$W/sent.json"
st_ok_all "T  ⌘T (an extra): the panel lit on ⚡, no hint; ⌂ 回家命令行 and ⏻ 退出 fleet rows, 退出 typed lands on ⏻ and asks y/n; ⌘K (retired 930) does nothing (T685); nothing in a direct attach"

# --- S: ⌃\ -----------------------------------------------------------------------------------
ti select-window -t "=fl@view-v1:$W1"; now_on "$W1"
before=$(nwin)
to send-keys -t o:direct 'C-\'
sleep 1
[ "$(nwin)" = "$before" ] || st_fail "S: ⌃\\ opened a window from a direct attach"
to send-keys -t o:view 'C-\'
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W1'" \
  || st_fail "S: ⌃\\ on alpha made no shell window: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}')"
SW=$(ti list-windows -t fl -F "#{window_id} #{@view_shell}" | awk -v k="nodeA@$ME:$W1" '$2 == k { print $1 }')
[ "$(cur)" = "$SW" ] || st_fail "S: the 看台 is not on the shell window ($(cur))"
[ "$(ti display-message -p -t "$SW" '#{@fleet_role}|#{@peer_view}')" = "panel|v1" ] || st_fail "S: the shell window's marks: $(ti display-message -p -t "$SW" '#{@fleet_role}|#{@peer_view}')"
prompt_ready; to send-keys -t o:view -l 'echo "AT=$(pwd)"'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-alpha'" \
  || st_fail "S: the shell is not in the session's worktree: $(to capture-pane -p -t o:view | tail -5)"
to send-keys -t o:view 'C-\'
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$W1' ]" || st_fail "S: ⌃\\ in the shell is not back on alpha ($(cur))"
to send-keys -t o:view 'C-\'
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$SW' ]" || st_fail "S: ⌃\\ on alpha again did not select its shell ($(cur))"
[ "$(ti list-windows -t fl -F '#{@view_shell}' | grep -c .)" = 1 ] || st_fail "S: a second shell window for one session"
[ -s "$W/pane1.in" ] && st_fail "S: ⌃\\ reached alpha's pane"
ti kill-window -t "$W1"
waitfor 24 sh -c "! tmux -S '$IN' list-windows -t fl -F '#{window_id}' | grep -qx '$SW'" || st_fail "S: alpha gone, its shell stayed"
# another machine's: the mac-a window, on far1
ti select-window -t "=fl@view-v1:$PW"; ti set-option -w -t "$PW" @peer_cur "wid:$MU/far1"; now_on "$PW"
to send-keys -t o:view 'C-\'
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'mac-a@$ME:$MU/far1'" \
  || st_fail "S: ⌃\\ on mac-a's session made no shell window: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}')"
waitfor 20 test -s "$W/ssh.argv" || st_fail "S: no ssh on the link for mac-a's shell"
argv=$(tr '\n' ' ' < "$W/ssh.argv")
for want in "-S $W/conf/peerlink/mac-a.sock" "ControlMaster=no" "-tt" "-l $ME" " mac-a " "fleet-remote-view.sh shell-here $MU/far1"; do
  case " $argv " in *"$want"*) ;; *) st_fail "S: mac-a's shell ssh lacks 「${want}」: $argv" ;; esac
done
prompt_ready; to send-keys -t o:view -l 'echo "AT=$(pwd)"'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*farwt'" \
  || st_fail "S: mac-a's shell is not in its worktree: $(to capture-pane -p -t o:view | tail -5)"
# issue #3183: a session not on screen — gamma, its agent in bin/ (the row's Tab
# page 命令行 = `do shell --target`; ⌃\ in ⌘P is the home shell since EPIC T651 C3)
# (the cd runs in the pane's own process: tmux reads the cwd of the pane's
# foreground process group LEADER, and dash keeps a `sh -c` wrapper as that)
W3=$(ti new-window -d -P -F '#{window_id}' -t fl -n gamma "cd '$W/wt-gamma/bin' && stty -isig 2>/dev/null; exec cat > '$W/pane3.in'")
ti set-option -w -t "$W3" @fleet_id f3; ti set-option -w -t "$W3" @worktree "$W/wt-gamma"; ti set-option -w -t "$W3" @claude_state working
row() { local IFS="$US"; printf '%s\n' "$*"; }
row "$W3" working x gamma ' ' '' 0 '' '' '#33' - 50% ok 'Gamma task' merged '' '' '' '' > "$W/rows.txt"
P3=$(ti display-message -p -t "$W3" '#{pane_pid}')
ti select-window -t "=fl@view-v1:$W2"; now_on "$W2"
listed() { tmux -S "$OUT" capture-pane -p -t o:view | grep -q 'Gamma task'; }
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" 'do' shell --view fl@view-v1 --target "$W3" || st_fail "S: do shell --target $W3 exited non-zero"
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W3'" \
  || st_fail "S: ⌃\\ on gamma's row made no shell for it: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}') $(to capture-pane -p -t o:view | tail -3)"
SG=$(ti list-windows -t fl -F "#{window_id} #{@view_shell}" | awk -v k="nodeA@$ME:$W3" '$2 == k { print $1 }')
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$SG' ]" || st_fail "S: the 看台 is not on gamma's shell ($(cur))"
prompt_ready; to send-keys -t o:view -l 'echo "AT=$(pwd)"'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-gamma/bin'" \
  || st_fail "S: gamma's shell is not where its agent is (…/wt-gamma/bin): $(to capture-pane -p -t o:view | grep -v '^$'; ti display-message -p -t "$SG" 'mode=#{pane_in_mode} dead=#{pane_dead} cmd=#{pane_current_command} pid=#{pane_pid}'; ti capture-pane -p -t "$SG" | grep -v '^$')"
# ⌘P from the shell: its session lit — ↵ is back on gamma
to send-keys -t o:view -H 1b 5b 39 32 37 7e
waitfor 20 listed || st_fail "S: ⌘P from the shell listed nothing"
sleep 0.3
to capture-pane -p -t o:view | grep -q '  .*Gamma task' || st_fail "S: ⌘P in gamma's shell does not light gamma: $(to capture-pane -p -t o:view | grep -n 'Gamma task')"
to send-keys -t o:view Enter
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$W3' ]" || st_fail "S: ↵ from the shell's ⌘P is not back on gamma ($(cur))"
# again: the one open, selected
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" 'do' shell --view fl@view-v1 --target "$W3" || st_fail "S: do shell --target $W3 (again) exited non-zero"
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$SG' ]" || st_fail "S: a second do shell on gamma did not select its shell ($(cur))"
[ "$(ti list-windows -t fl -F '#{@view_shell}' | grep -cx "nodeA@$ME:$W3")" = 1 ] || st_fail "S: a second shell window for gamma"
# exit: the shell window alone goes
to send-keys -t o:view -l 'exit'; to send-keys -t o:view Enter
waitfor 20 sh -c "! tmux -S '$IN' list-windows -t fl -F '#{window_id}' | grep -qx '$SG'" || st_fail "S: exit left gamma's shell window"
ti list-windows -t fl -F '#{window_id}' | grep -qx "$W3" || st_fail "S: exit in the shell took gamma's window"
[ "$(ti display-message -p -t "$W3" '#{@claude_state}|#{pane_pid}|#{pane_dead}')" = "working|$P3|0" ] \
  || st_fail "S: gamma changed under its shell's exit: $(ti display-message -p -t "$W3" '#{@claude_state}|#{pane_pid}|#{pane_dead}') (was working|$P3|0)"
[ -s "$W/pane3.in" ] && st_fail "S: the shell sent keys to gamma's pane: $(od -c "$W/pane3.in" | head -2)"
# the cwd its last Bash call left (@agent_cwd) outranks the pane's
mkdir -p "$W/wt-gamma/lib"; ti set-option -w -t "$W3" @agent_cwd "$W/wt-gamma/lib"
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" 'do' shell --view fl@view-v1 --target "$W3" || st_fail "S: do shell --target $W3 exited non-zero"
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W3'" || st_fail "S: --target $W3 made no shell for gamma"
prompt_ready; to send-keys -t o:view -l 'echo "AT=$(pwd)=="'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-gamma/lib=='" \
  || st_fail "S: gamma's @agent_cwd is not where its shell opened: $(to capture-pane -p -t o:view | grep -v '^$')"
to send-keys -t o:view -l 'exit'; to send-keys -t o:view Enter
# the agent's directory gone (and a stale @agent_cwd) → @worktree; `--target <bare fleet_id>`
W4=$(ti new-window -d -P -F '#{window_id}' -t fl -n delta "cd '$W/wt-delta/gone' && exec cat > /dev/null")
ti set-option -w -t "$W4" @fleet_id f4; ti set-option -w -t "$W4" @worktree "$W/wt-delta"; ti set-option -w -t "$W4" @agent_cwd "$W/nope"
sleep 0.3; rmdir "$W/wt-delta/gone"
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" 'do' shell --view fl@view-v1 --target f4 || st_fail "S: do shell --target f4 exited non-zero"
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -qx 'nodeA@$ME:$W4'" || st_fail "S: --target f4 made no shell for delta"
prompt_ready; to send-keys -t o:view -l 'echo "AT=$(pwd)=="'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=.*wt-delta=='" \
  || st_fail "S: delta's agent directory gone, the shell is not in its @worktree: $(to capture-pane -p -t o:view | grep -v '^$'; ti list-windows -t fl -F '#{window_id} #{@view_shell} mode=#{pane_in_mode} cmd=#{pane_current_command}')"
st_ok_all "S  ⌃\\: the session's shell in its worktree (here; mac-a over the link's shell-here), ⌃\\ back and forth, one a session, gone with the session; nothing in a direct attach; a session off screen (do shell --target) — where its agent is (@agent_cwd, else its pane's bin/, else @worktree), ↵ back from its shell, exit closes the shell alone (#3183)"

# --- H: ⌘\ · ⌃\ — the home shell (EPIC T651 C3) ---------------------------------------------
# ⌘\ — the iTerm2 profile sends ⌃\'s byte, 0x1c (a private code would never reach
# a popup) — from a session: ONE window of the 看台 marked `@view_shell home`, a
# login shell in $HOME; ⌘\ there is back where you were, ⌘\ again the same window;
# in ⌘P — the list and the 新会话 box — the same key. A direct attach: nothing.
# Since T685 a key only when the person names it (home=cmd+\): leg S's
# FLEET_KEYS_EXTRA (⌃\ = the session's shell) dropped first; with no extra ⌃\
# is the session's own (sent on) and opens nothing.
ti set-option -gu @fleet_view_keys_extra
FLEET_KEYS_EXTRA='' TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" view-keys || st_fail "H: view-keys (defaults) exited non-zero"
ti list-keys -T fleet-view | awk '$4 == "C-\\\\"' | grep -q 'do home' && st_fail "H: ⌃\\ is the home shell with no extra naming it (T685)"
ti set-option -gu @fleet_view_keys_extra
FLEET_KEYS_EXTRA='home=cmd+\' TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" view-keys || st_fail "H: view-keys (home=cmd+\\) exited non-zero"
cmdbs() { to send-keys -t o:view -H 1c; }
homew() { ti list-windows -t fl -F '#{window_id} #{@view_shell} #{@peer_view}' | awk '$2 == "home" && $3 == "v1" { print $1 }'; }
ti select-window -t "=fl@view-v1:$W2"; now_on "$W2"
before=$(nwin)
to send-keys -t o:direct -H 1c
sleep 1
[ "$(nwin)" = "$before" ] || st_fail "H: ⌘\\ opened a window from a direct attach"
cmdbs
waitfor 20 sh -c "[ -n \"\$(tmux -S '$IN' list-windows -t fl -F '#{@view_shell}' | grep -x home)\" ]" \
  || st_fail "H: ⌘\\ made no home shell: $(ti list-windows -t fl -F '#{window_id} #{@view_shell}')"
HW=$(homew)
now_on "$HW"; [ "$(cur)" = "$HW" ] || st_fail "H: the 看台 is not on the home shell ($(cur))"
[ "$(ti display-message -p -t "$HW" '#{@fleet_role}')" = panel ] || st_fail "H: the home shell is not a panel window"
prompt_ready; to send-keys -t o:view -l 'echo "AT=$(pwd)=="'; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'AT=$W/home=='" \
  || st_fail "H: the home shell is not in \$HOME ($W/home): $(to capture-pane -p -t o:view | grep -v '^$' | tail -5)"
cmdbs
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$W2' ]" || st_fail "H: ⌘\\ in the home shell is not back on the session ($(cur))"
cmdbs
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$HW' ]" || st_fail "H: ⌘\\ again did not select the home shell ($(cur))"
[ "$(homew | grep -c .)" = 1 ] || st_fail "H: a second home shell window"
# from ⌘P: on the list and in the 新会话 box
for how in list box; do
  cmdbs; now_on "$W2"
  to send-keys -t o:view -H 1b 5b 39 32 37 7e
  waitfor 20 listed || st_fail "H: ⌘P listed nothing ($how)"
  if [ "$how" = box ]; then
    to send-keys -t o:view -l zzqqxx; sleep 0.3; to send-keys -t o:view Enter
    waitfor 10 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '仓库'" || st_fail "H: ↵ on words that hit nothing opened no 新会话 box: $(to capture-pane -p -t o:view | grep -v '^$' | tail -6)"
  fi
  cmdbs
  waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$HW' ]" \
    || st_fail "H: ⌘\\ in ⌘P ($how) did not go to the home shell ($(cur)): $(to capture-pane -p -t o:view | grep -v '^$' | tail -4)"
done
[ "$(homew | grep -c .)" = 1 ] || st_fail "H: ⌘P made a second home shell window"
# the panel's 回家命令行 row (T685: the road with no key): ⌘P, type 回家, ↵
cmdbs; now_on "$W2"
to send-keys -t o:view -H 1b 5b 39 32 37 7e
waitfor 20 listed || st_fail "H: ⌘P listed nothing (row)"
to send-keys -t o:view -l '回家'
waitfor 10 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '  ⌂ 回家命令行'" || st_fail "H: typing 回家 did not light ⌂ 回家命令行: $(to capture-pane -p -t o:view | grep -v '^$' | tail -6)"
to send-keys -t o:view Enter
waitfor 12 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$HW' ]" \
  || st_fail "H: ↵ on ⌂ 回家命令行 did not go to the home shell ($(cur))"
# `do home` from outside a key; exit: the window alone goes
cmdbs; now_on "$W2"
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" 'do' home --view fl@view-v1 || st_fail "H: do home exited non-zero"
now_on "$HW"; [ "$(cur)" = "$HW" ] || st_fail "H: do home is not on the home shell ($(cur))"
prompt_ready; to send-keys -t o:view -l 'exit'; to send-keys -t o:view Enter
waitfor 20 sh -c "! tmux -S '$IN' list-windows -t fl -F '#{window_id}' | grep -qx '$HW'" || st_fail "H: exit left the home shell window"
# the legs below press the extras again (⌘Q = quit)
TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" view-keys || st_fail "H: view-keys (extras back) exited non-zero"
st_ok_all "H  ⌘\\ · ⌃\\ (named, T685) · the panel's ⌂ 回家命令行 row: the home shell — one window (@view_shell home) in \$HOME, back and forth, from ⌘P's list and 新会话 box, nothing in a direct attach, exit closes it (EPIC T651 C3)"

# --- P: anchored composer; existing placement routes (#4416) -------------------
vp() { TMUX="$IN,0,0" python3 "$BIN/fleet-quickopen.py" view-panel --view fl@view-v1 "$@"; }
ti select-window -t "=fl@view-v1:$W3"; now_on "$W3"
vp > "$W/panel.txt" || st_fail "P: view-panel"
grep -qx "cmd${T}pin${T}置顶当前会话" "$W/panel.txt" || st_fail "P: plain pin row missing"
[ "$(tail -4 "$W/panel.txt" | cut -f1,2 | tr '\t\n' ': ')" = "cmd:new cmd:home cmd:lang cmd:quit " ] || st_fail "P: command order (⚡ · ⌂ 回家命令行 · 语言 · ⏻, T685)"
grep -q '^grid' "$W/panel.txt" && st_fail "P: composer controls still inserted in list"
for word in 置顶 pin; do vp "$word" | grep -q "^cmd${T}pin" || st_fail "P: pin search"; done
for word in 语言 lang english 中文; do vp "$word" | grep -q "^cmd${T}lang" || st_fail "P: language search"; done
vp Gamma | grep -q "^cmd${T}lang" && st_fail "P: unrelated language row in search"
FLEET_PANEL_COMMANDS=none vp | grep -q '^cmd' && st_fail "P: none still has commands"
[ "$(FLEET_PANEL_COMMANDS='new shell newsess' vp | grep '^cmd' | cut -f2 | tr '\n' ' ')" = "pin new home lang quit " ] || st_fail "P: retired commands"
for word in 回家 home shell; do vp "$word" | grep -q "^cmd${T}home" || st_fail "P: 回家命令行 search ($word)"; done
vp Gamma | grep -q "^cmd${T}home" && st_fail "P: unrelated 回家命令行 row in search"
# The box's defaults are fleet-quick-dispatch.py's (T670; its selftest holds the
# rules). Only this test's private conf is touched.
popen() {
  to send-keys -t o:view -H 1b 5b 39 32 37 7e
  waitfor 20 listed || st_fail "P: panel did not open"
}
# The 「新会话」 box (T652, EPIC T651 C1): ⚡ opens it on words that hit nothing
# (the words are only a search — nothing is typed into the box), or Tab on ⚡.
pbox() {
  popen
  to send-keys -t o:view -l "${1:-zzqx}"; sleep 0.3
  to send-keys -t o:view Enter
  waitfor 12 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '开 ↵'" || st_fail "P: the new-session box did not open"
  waitfor 48 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -Eq '仓库 ‹(acme/|不绑仓库)'" || st_fail "P: repositories did not load"
}
pclosed() { waitfor 20 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q '⚡'" || st_fail "P: panel stayed open"; }
: > "$W/send.calls"; rm -f "$W/sent.json"
pbox '修 3164 的列表'
to capture-pane -p -t o:view > "$W/panel-box.txt"
[ "$(grep -cE '(仓库 ‹|Agent ‹|开 ↵)' "$W/panel-box.txt")" = 3 ] || st_fail "P: the box is not three items: $(cat "$W/panel-box.txt")"
grep -Eq '开窗预填|清空草稿|开空白会话|写任务' "$W/panel-box.txt" && st_fail "P: the box still has the draft controls: $(cat "$W/panel-box.txt")"
grep -q '仓库 ‹acme/web›' "$W/panel-box.txt" && grep -q 'Agent ‹Claude›' "$W/panel-box.txt" \
  || st_fail "P: the box did not open chosen: $(cat "$W/panel-box.txt")"
[ ! -s "$W/send.calls" ] || st_fail "P: opening the box dispatched"
# opened chosen: the last send's repo (leg T's), the fleet's agent
# ↑↑ to 仓库, ← acme/app, ↵ back to 开, ↵ opens: ⌘N's road with the repo — no send, no words
to send-keys -t o:view Up Up Left; sleep 0.3
to capture-pane -p -t o:view > "$W/panel-grid.txt"
grep -q '仓库 ‹acme/app›' "$W/panel-grid.txt" || st_fail "P: ← did not pick the repo: $(cat "$W/panel-grid.txt")"
to send-keys -t o:view Enter Enter
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new3" || st_fail "P: the box opened no session: $(to capture-pane -p -t o:view) $(cat "$W/new.argv")"
[ "$(sed -n 3p "$W/new.argv")" = "--origin hub --repo acme/app --agent claude --print fl" ] || st_fail "P: repo argv: $(sed -n 3p "$W/new.argv")"
N3=$(ti list-windows -t fl -F '#{window_id} #{window_name}' | awk '$2 == "new3" { print $1 }')
waitfor 16 sh -c "[ \"\$(tmux -S '$IN' display-message -p -t 'fl@view-v1:' '#{window_id}')\" = '$N3' ]" || st_fail "P: not on new3"
[ ! -s "$W/send.calls" ] || st_fail "P: the box sent words"
pclosed
waitfor 10 python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repo"]=="acme/app" and d["agent_by_repo"]["acme/app"]=="claude", d' "$W/state/compose-state.json" 2>/dev/null \
  || st_fail "P: the box did not remember its repo and agent: $(cat "$W/state/compose-state.json")"
[ -e "$W/conf/panel-drafts" ] && st_fail "P: the box still writes panel-drafts"
# Search hit still enters the session; ↓ lights ⚡, Tab opens the box too
ti select-window -t "=fl@view-v1:$W3"; now_on "$W3"
popen
to send-keys -t o:view -l Gamma; sleep 0.3
to send-keys -t o:view Down Tab
waitfor 12 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '开 ↵'" || st_fail "P: Tab on ⚡ did not open the box"
to send-keys -t o:view Escape; sleep 0.2; to send-keys -t o:view Escape
pclosed
# ↵ at once: the defaults — gamma is acme/web's, so acme/web (not the last, acme/app) · Claude
ti set-option -w -t "$W3" @repo acme/web
pbox
to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$IN' list-windows -t fl -F '#{window_name}' | grep -qx new4" || st_fail "P: ↵ opened no session"
[ "$(sed -n 4p "$W/new.argv")" = "--origin hub --repo acme/web --agent claude --print fl" ] || st_fail "P: default argv: $(sed -n 4p "$W/new.argv")"
pclosed
# Quit still goes through OSC 7502 + detach — after its y / n (T685).
to pipe-pane -o -t o:view "cat > '$W/client-p.bytes'"; sleep 0.3
popen
to send-keys -t o:view -l 'zzz'; sleep 0.3; to send-keys -t o:view Down Enter
waitfor 10 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '(y/n)'" || st_fail "P: quit did not ask first"
to send-keys -t o:view y
waitfor 20 sh -c "! tmux -S '$IN' list-clients -F '#{session_name}' | grep -q 'view-v1'" || st_fail "P: quit did not detach"
sleep 0.3
python3 -c 'import sys; sys.exit(0 if b"\x1b]7502;quit;token=tok7\x07" in open(sys.argv[1],"rb").read() else 1)' "$W/client-p.bytes" || st_fail "P: quit OSC missing"
to new-window -d -t o -n view "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'"; sleep 1
st_ok_all "P  the 新会话 box: three items opened chosen, ↵ opens ⌘N's one road with repo and agent, nothing typed; quit"

# --- I: the language row (issue #3329, EPIC #3178 D7, L1–L3) --------------------------------
# The person's choice is kept on the hub (a seam: GET/PUT the state file) and read back
# at once into person-bundle.json; the 看台 said no language (FLEET_VIEW_LANG empty) ⇒
# Chinese, and the row's footer says how to bring one (D9). FLEET_UI_LANG auto here.
# The footer names this machine; a GitHub macOS runner's 60-odd-char hostname pushed
# the LANG= half past the popup's width (issue #3545), so the name is pinned short.
printf '{"version":1,"bundle":{}}' > "$W/person.json"
cat > "$W/person-hub.sh" <<EOF
#!/bin/sh
st='$W/person.json'; body=\$(cat)
[ "\$1" = GET ] && { cat "\$st"; exit 0; }
python3 -c '
import json, sys
b, st = json.loads(sys.argv[1]), sys.argv[2]
cur = json.load(open(st))
if b.get("base") != cur["version"]:
    print(json.dumps({"status": 409, "error": "stale"})); sys.exit()
new = {"version": cur["version"] + 1, "prev": cur["version"], "bundle": b["bundle"]}
json.dump(new, open(st, "w")); print(json.dumps(new))' "\$body" "\$st"
EOF
for k in FLEET_UI_LANG=auto FLEET_VIEW_LANG= FLEET_SIDEBAR_HOST=c7host "FLEET_PERSON_HUB_CMD=sh $W/person-hub.sh \"\$@\"" "FLEET_PERSON_BUNDLE_CMD=cat $W/person.json"; do
  ti set-environment -t 'fl@view-v1' "${k%%=*}" "${k#*=}"
done
lshot() { to capture-pane -p -t o:view | grep -v '^$'; }
to send-keys -t o:view -H 1b 5b 39 32 37 7e
waitfor 20 listed || st_fail "I: ⌘P listed nothing"
to send-keys -t o:view -l '语言'; sleep 0.5
waitfor 10 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '  ◐ 语言 / Language　中文 ✓ · English'" \
  || st_fail "I: typing 语言 did not light the language row: $(lshot)"
lshot | grep -q 'Termius → Hosts' && st_fail "I: footer repeats selected row detail"
[ -n "${FLEET_VIEW_LANG_EVIDENCE:-}" ] && lshot > "$FLEET_VIEW_LANG_EVIDENCE.zh.txt"
to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'Language: English · saved to your account'" \
  || st_fail "I: ↵ did not switch to English and say so: $(lshot)"
lshot | grep -q '◐ Language / 语言　English ✓ · 中文' || st_fail "I: the panel did not redraw in English: $(lshot)"
[ -n "${FLEET_VIEW_LANG_EVIDENCE:-}" ] && lshot > "$FLEET_VIEW_LANG_EVIDENCE.en.txt"
grep -q '"ui_lang": *"en"' "$W/person.json" || st_fail "I: the hub was not told: $(cat "$W/person.json")"
grep -q '"ui_lang": *"en"' "$W/conf/person-bundle.json" || st_fail "I: this computer's copy was not re-read: $(cat "$W/conf/person-bundle.json" 2>&1)"
[ "$(FLEET_VIEW_LANG=en_US.UTF-8 FLEET_UI_LANG=auto sh "$BIN/fleet-ui-lang.sh" first-hint devX)" = "" ] \
  || st_fail "I: a person who chose is still told about detection (D8)"
waitfor 24 sh -c "! tmux -S '$OUT' capture-pane -p -t o:view | grep -q 'Language: English · saved'" || st_fail "I: the confirmation did not go by itself (3 s): $(lshot)"
# Tab: 中文 · English · Follow the system — the last takes the choice away
to send-keys -t o:view Tab; sleep 0.4
lshot | grep -q 'Follow the system' || st_fail "I: Tab on the row offers no 跟系统走: $(lshot)"
to send-keys -t o:view Down; sleep 0.1; to send-keys -t o:view Down; sleep 0.1; to send-keys -t o:view Enter
waitfor 20 sh -c "tmux -S '$OUT' capture-pane -p -t o:view | grep -q '界面语言：跟系统走 · 已存到你的账号'" \
  || st_fail "I: 跟系统走 did not go back to the detected language (中文, none said): $(lshot)"
grep -q 'ui_lang' "$W/person.json" && st_fail "I: 跟系统走 left ui_lang on the hub: $(cat "$W/person.json")"
to send-keys -t o:view Escape
for k in FLEET_UI_LANG FLEET_VIEW_LANG FLEET_PERSON_HUB_CMD FLEET_PERSON_BUNDLE_CMD; do ti set-environment -t 'fl@view-v1' -u "$k"; done
rm -f "$W/conf/person-bundle.json" "$W/conf/person-bundle.good.json"
st_ok_all "I  ⌘P's language row: 语言 finds it, ↵ flips to English on the hub and here at once (the panel redraws, 3 s line), Tab 跟系统走 takes it back; no language said ⇒ 中文 + the Termius line (#3329)"

# --- Q: ⌘Q -----------------------------------------------------------------------------------
to pipe-pane -o -t o:view "cat > '$W/client.bytes'"; sleep 0.3
to send-keys -t o:direct -H 1b 5b 39 33 31 7e
sleep 1
ti list-clients -F '#{session_name}' | grep -qx fl || st_fail "Q: ⌘Q detached a direct attach"
to send-keys -t o:view -H 1b 5b 39 33 31 7e
waitfor 20 sh -c "! tmux -S '$IN' list-clients -F '#{session_name}' | grep -q 'view-v1'" || st_fail "Q: ⌘Q did not detach the 看台's client"
sleep 0.3
grep -q $'\033\\]7502;quit;token=tok7\a' "$W/client.bytes" 2>/dev/null \
  || python3 -c 'import sys; sys.exit(0 if b"\x1b]7502;quit;token=tok7\x07" in open(sys.argv[1],"rb").read() else 1)' "$W/client.bytes" \
  || st_fail "Q: no OSC 7502 quit with the row's token reached the client: $(od -c "$W/client.bytes" | tail -5)"
st_ok_all "Q  ⌘Q: OSC 7502 quit (the row's token) on the client's tty, then detached; a direct attach stays"

# --- L: fleet ls / open with no client tmux --------------------------------------------------
T=$'\t'
{
  printf '%s\n' "wid:$MU/issue-12${T}needs${T}!${T}登录页重做${T}mac-a${T}acme/web (2)${T}${T}#12${T}—${T}merged${T}登录页重做${T}acme/web"
  printf '%s\n' "$W2${T}working${T}●${T}样式${T}nodeA${T}acme/web (2)${T}${T}#13${T}—${T}done:2h${T}${T}acme/web"
} > "$W/rows.tsv"
cat > "$W/argv.sh" <<EOF
#!/bin/sh
printf '{"argv": ["sh", "$W/homessh.sh", "homebox"], "host": 2, "route": "lan"}\n'
EOF
# the home: one ssh — its options kept, the command run here with the home's rows
cat > "$W/homessh.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > '$W/home.argv'
for last; do :; done
FLEET_SESSION_CLI_ROWS='$W/rows.tsv' FLEET_SESSION_CLI_CACHE= exec sh -c "\$last"
EOF
out=$(FLEET_SESSION_CLI_ROAD=home FLEET_THIN_ARGV_CMD="sh $W/argv.sh" FLEET_REMOTE_BIN="$BIN" FLEET_THIN_LOG="$W/thin.log" \
  python3 "$BIN/fleet-session-cli.py" ls </dev/null 2>&1) || st_fail "L: fleet ls over the home exited non-zero: $out"
for want in 登录页重做 样式 mac-a nodeA; do
  case "$out" in *"$want"*) ;; *) st_fail "L: fleet ls lacks 「${want}」: $out" ;; esac
done
hargv=$(tr '\n' ' ' < "$W/home.argv")
for want in "ControlMaster=no" "ControlPath=none" "-T" "homebox" "fleet-session-cli.py --home ls"; do
  case " $hargv " in *"$want"*) ;; *) st_fail "L: the one-shot ssh lacks 「${want}」: $hargv" ;; esac
done
grep -q "${T}run${T}" "$W/thin.log" || st_fail "L: thin.log has no run line: $(cat "$W/thin.log")"
[ -n "${FLEET_VIEW_LS_EVIDENCE:-}" ] && printf '%s\n' "$out" > "$FLEET_VIEW_LS_EVIDENCE"
# --home open: the newest live 看台 here goes there (its client gone after ⌘Q: re-attach)
to new-window -d -t o -n view2 "TMUX= tmux -S '$IN' attach -t 'fl@view-v1'"; sleep 1
ti select-window -t "=fl@view-v1:$PW"
TMUX="$IN,0,0" FLEET_SESSION_CLI_ROWS="$W/rows.tsv" FLEET_SESSION_CLI_CACHE='' \
  python3 "$BIN/fleet-session-cli.py" --home open 样式 >/dev/null 2>&1 || st_fail "L: --home open exited non-zero"
[ "$(cur)" = "$W2" ] || st_fail "L: --home open did not move the 看台 to beta ($(cur))"
st_ok_all "L  fleet ls with no client tmux: one ssh to the home (no master), two machines' sessions; --home open moves the 看台"

# --- C: fleet claude, thin -------------------------------------------------------------------
cat > "$W/rbin/fleet-client-place.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > '$W/place.argv'
printf 'REMOTE mac-a start done %s\tok\n' '$MU/home1'
EOF
cat > "$W/claude.sh" <<EOF
#!/bin/sh
cd '$BIN' && FLEET_CLIENT=thin FLEET_THIN_ARGV_CMD="sh $W/argv.sh" FLEET_REMOTE_BIN='$W/rbin' FLEET_THIN_LOG='$W/thin.log' \
  FLEET_HOME_THIN_CMD='printf "%s\n" "\$@" > $W/thin.want' bash '$BIN/fleet-home-session.sh' claude
echo "rc=\$?" > '$W/claude.rc'
EOF
to new-window -d -t o -n claude "sh '$W/claude.sh'"
waitfor 40 test -s "$W/claude.rc" || st_fail "C: fleet claude did not finish"
[ "$(cat "$W/claude.rc")" = rc=0 ] || st_fail "C: fleet claude: $(cat "$W/claude.rc")"
[ "$(cat "$W/thin.want" 2>/dev/null)" = "$MU/home1" ] || st_fail "C: the thin client was not pointed at the new session: $(cat "$W/thin.want" 2>/dev/null)"
pargs=$(tr '\n' ' ' < "$W/place.argv")
case "$pargs" in "- home --agent claude "*) ;; *) st_fail "C: the home's place: $pargs" ;; esac
st_ok_all "C  fleet claude (thin): the home places it (- home --agent claude), then fleet --thin <its worker id>"
echo "fleet-view-c7-selftest: all passed"
