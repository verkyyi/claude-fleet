#!/bin/bash
# fleet-webchat-handoff-selftest.sh — the terminal and WebChat taking turns on one
# conversation (task T810): bin/fleet-webchat-handoff.sh and bin/fleet-convo-lock.py
# on an isolated tmux socket, a stub agent in the window and a stub WebChat on a
# unix socket. 在 WebChat 里继续 refuses while either side answers, else WebChat
# adopts the session, the record says webchat and the agent stops onto its end
# page; ↵ back waits for WebChat; 在这里继续 stops an idle terminal.
# bin/fleet-session-page.py's handed line, and bin/fleet-cleanup-idle.py keeping
# a handed window, are checked at the end.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
command -v tmux >/dev/null 2>&1 || { echo "SKIP fleet-webchat-handoff-selftest: no tmux"; exit 0; }
WORK=$(mktemp -d "/tmp/fwho.XXXXXX")
SOCKET="scratch-webchat-handoff-$$"
CHATPID=''
cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || :
  [ -n "$CHATPID" ] && { kill "$CHATPID" 2>/dev/null; wait "$CHATPID" 2>/dev/null; } || :
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/conf/fleets/$SOCKET"
: > "$WORK/conf/fleets/$SOCKET/conf"
for source in "$BIN"/*; do ln -s "$source" "$WORK/bin/${source##*/}"; done
rm "$WORK/bin/fleet-open.sh" "$WORK/bin/fleet-webchat.sh"
printf '#!/bin/bash\necho "$*" >> "%s"\n' "$WORK/open.log" > "$WORK/bin/fleet-open.sh"
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/fleet-webchat.sh"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_UI_LANG=zh
export FLEET_HUB_URL=https://hub.example CCQUOTA_HUB_URL=https://hub.example
export FLEET_WEBCHAT_SOCK="$WORK/chat.sock" FLEET_HANDOFF_EXIT_WAIT=8
unset TMUX TMUX_PANE
H="$WORK/bin/fleet-webchat-handoff.sh"
LOCK="$WORK/bin/fleet-convo-lock.py"

# ---- the stub WebChat: /healthz · /api/state (busy while $WORK/webbusy) · /api/adopt · /api/release
cat > "$WORK/chat.py" <<'EOF'
import http.server, json, os, socketserver, sys
work, sock = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def address_string(self): return "unix"
    def do_GET(self):
        if self.path == "/healthz": return self.reply(200, {"ok": True})
        if self.path == "/api/state": return self.reply(200, {"busy": os.path.exists(work + "/webbusy"), "session": ""})
        self.reply(404, {})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode()
        with open(work + "/chat.log", "a") as f: f.write(self.path + " " + (self.headers.get("X-Fleet-Webchat") or "-") + " " + body + "\n")
        if self.path == "/api/adopt" and os.path.exists(work + "/refuse"): return self.reply(409, {"error": "还在回复上一句"})
        self.reply(200, {"ok": True})
class S(socketserver.UnixStreamServer):
    def get_request(self):
        r, _ = super().get_request(); return r, ("unix", 0)
S(sock, H).serve_forever()
EOF
python3 "$WORK/chat.py" "$WORK" "$FLEET_WEBCHAT_SOCK" & CHATPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$FLEET_WEBCHAT_SOCK" ] && break; sleep 0.2; done

# ---- the stub agent: the fleet's /exit ends it the way the wrapper's page does (exited)
cat > "$WORK/agent.sh" <<'EOF'
#!/bin/bash
stty -echo 2>/dev/null
while IFS= read -r l; do
  case "$l" in *"/exit"*) tmux set-option -w -t "$TMUX_PANE" @claude_state exited; exec sleep 600 ;; esac
done
EOF
chmod +x "$WORK/agent.sh"
FID=11111111-2222-4333-8444-555555555555
SID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
WIN=$(tmux -L "$SOCKET" -f /dev/null new-session -d -P -F '#{window_id}' -s "$SOCKET" "bash $WORK/agent.sh")
T() { tmux -L "$SOCKET" "$@"; }
T set-option -w -t "$WIN" @fleet_id "$FID"
T set-option -w -t "$WIN" @cc_agent claude
T set-option -w -t "$WIN" @raw scratch-20
T set-option -w -t "$WIN" @claude_state 'done'
T set-option -w -t "$WIN" @claude_state_ts "$(date +%s)"
rec() { python3 "$LOCK" get --agent claude --sid "$SID"; }
field() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2],""))' "$1" "$2"; }

# 1 · no conversation id yet
set +e; out=$(bash "$H" to-web "fid:$FID" 2>&1); rc=$?; set -e
st_eq 'no conversation id: rc 2' 2 "$rc"
st_has 'no conversation id: said' "$out" '还没有对话号'
T set-option -w -t "$WIN" @cc_session_id "$SID"

# 2 · the terminal is answering
T set-option -w -t "$WIN" @claude_state working
set +e; out=$(bash "$H" to-web "fid:$FID" 2>&1); rc=$?; set -e
st_eq 'terminal answering: rc 3' 3 "$rc"
st_has 'terminal answering: says where' "$out" '正在终端里回答'
T set-option -w -t "$WIN" @claude_state 'done'

# 3 · WebChat is answering
: > "$WORK/webbusy"
set +e; out=$(bash "$H" to-web "fid:$FID" 2>&1); rc=$?; set -e
st_eq 'WebChat answering: rc 3' 3 "$rc"
st_has 'WebChat answering: said' "$out" 'WebChat 正在回答'
rm -f "$WORK/webbusy"
st_eq 'nothing handed yet: no record' '{}' "$(rec)"

# 4 · WebChat refuses the adopt: nothing moves
: > "$WORK/refuse"
set +e; out=$(bash "$H" to-web "fid:$FID" 2>&1); rc=$?; set -e
st_eq 'adopt refused: rc 1' 1 "$rc"
st_has 'adopt refused: WebChat says why' "$out" 'WebChat 没接'
st_eq 'adopt refused: the agent still runs' 'done' "$(T show-options -wqv -t "$WIN" @claude_state)"
rm -f "$WORK/refuse"

# 5 · handed over
out=$(bash "$H" to-web "fid:$FID")
st_has 'handed: said' "$out" '已交给 WebChat'
st_has 'adopt carries the session, from this machine only' "$(tail -n 1 "$WORK/chat.log")" "/api/adopt 1 "
st_has 'adopt names the session' "$(tail -n 1 "$WORK/chat.log")" "\"session\": \"$SID\""
st_has 'adopt names the window' "$(tail -n 1 "$WORK/chat.log")" '"label": "scratch-20"'
r=$(rec)
st_eq 'the record: webchat holds it' webchat "$(field "$r" holder)"
st_eq 'the record: which window' "$FID" "$(field "$r" window_fid)"
st_eq 'the agent stopped onto its end page' exited "$(T show-options -wqv -t "$WIN" @claude_state)"
st_eq 'the window is marked handed' 1 "$(T show-options -wqv -t "$WIN" @handoff_web)"
st_eq 'the page opened on the person' 'https://hub.example/app/' "$(cat "$WORK/open.log")"
set +e; out=$(bash "$H" to-web "fid:$FID" 2>&1); rc=$?; set -e
st_eq 'handing it twice: rc 2' 2 "$rc"
st_eq 'owner while WebChat holds it' '{"holder": "webchat", "busy": false, "label": "scratch-20", "machine": "'"$(hostname -s)"'"}' \
  "$(bash "$H" owner --agent claude --sid "$SID")"

# 6 · ↵ back while WebChat answers, then once it is done
: > "$WORK/webbusy"
set +e; out=$(bash "$H" to-terminal --agent claude --sid "$SID" --fid "$FID" 2>&1); rc=$?; set -e
st_eq '↵ while WebChat answers: rc 3' 3 "$rc"
st_has '↵ while WebChat answers: said' "$out" '答完再按 ↵'
st_eq '↵ refused: WebChat still holds it' webchat "$(field "$(rec)" holder)"
rm -f "$WORK/webbusy"
bash "$H" to-terminal --agent claude --sid "$SID" --fid "$FID"
st_eq '↵: the terminal holds it' terminal "$(field "$(rec)" holder)"
st_has '↵: WebChat lets go of its warm agent' "$(tail -n 1 "$WORK/chat.log")" "/api/release 1 "
bash "$H" to-terminal --agent claude --sid "$SID" --fid "$FID"
st_eq '↵ again: nothing changes' terminal "$(field "$(rec)" holder)"
st_eq 'no record, no lock: ↵ is as before' 0 "$(bash "$H" to-terminal --agent claude --sid bbbbbbbb-0000-4000-8000-000000000000 >/dev/null; echo $?)"

# 7 · the terminal answering, seen from WebChat; 在这里继续 refused, then taken
T respawn-pane -k -t "$WIN" "bash $WORK/agent.sh"
T set-option -wu -t "$WIN" @handoff_web
T set-option -w -t "$WIN" @claude_state working
st_has 'owner: the terminal is answering' "$(bash "$H" owner --agent claude --sid "$SID")" '"holder": "terminal", "busy": true'
set +e; out=$(bash "$H" to-webchat-take --agent claude --sid "$SID" 2>&1); rc=$?; set -e
st_eq '在这里继续 while the terminal answers: rc 3' 3 "$rc"
st_eq 'refused: the terminal keeps it' terminal "$(field "$(rec)" holder)"
T set-option -w -t "$WIN" @claude_state 'done'
st_has 'owner: the terminal is idle' "$(bash "$H" owner --agent claude --sid "$SID")" '"holder": "terminal", "busy": false'
bash "$H" to-webchat-take --agent claude --sid "$SID" >/dev/null
st_eq '在这里继续: WebChat holds it' webchat "$(field "$(rec)" holder)"
st_eq '在这里继续: the terminal stopped onto its end page' exited "$(T show-options -wqv -t "$WIN" @claude_state)"
st_eq '在这里继续: the window is marked handed' 1 "$(T show-options -wqv -t "$WIN" @handoff_web)"

# 8 · the record itself
set +e; python3 "$LOCK" set --agent claude --sid "$SID" --holder terminal --if-holder terminal >/dev/null; rc=$?; set -e
st_eq 'a move from a holder that is not: rc 3' 3 "$rc"
set +e; python3 "$LOCK" get --agent claude --sid '../x' >/dev/null 2>&1; rc=$?; set -e
st_eq 'a bad session id: rc 2' 2 "$rc"
st_eq 'the record is 0600' 600 "$(stat -f %Lp "$WORK/conf/convo-lock/claude-$SID.json" 2>/dev/null || stat -c %a "$WORK/conf/convo-lock/claude-$SID.json")"

# 9 · the end page a handed window stops on
out=$(FLEET_UI_LANG=zh LANG=zh_CN.UTF-8 python3 "$WORK/bin/fleet-session-page.py" --handed web --print | sed 's/\x1b\[[0-9;]*m//g')
st_has 'end page: handed' "$out" '已在 WebChat 里继续 · ↵ 拿回终端 · ⌘P 回列表'
st_hasnt 'end page: no new chat here' "$out" 'r 新对话'
out=$(FLEET_UI_LANG=en LANG=en_US.UTF-8 python3 "$WORK/bin/fleet-session-page.py" --handed web --note 'WebChat is answering' --print | sed 's/\x1b\[[0-9;]*m//g')
st_has 'end page (en): handed' "$out" 'Continued in WebChat · ↵ take it back'
st_has 'end page: the note above' "$(printf '%s' "$out" | head -n 1)" 'WebChat is answering'

# 10 · a handed window is the way back: the idle reaper keeps it
st_has 'cleanup-idle reads the handed mark' "$(cat "$BIN/fleet-cleanup-idle.py")" '"@handoff_web"'
echo 'PASS fleet-webchat-handoff-selftest'
