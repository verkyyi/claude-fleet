#!/bin/bash
# fleet-client-actions-selftest.sh — open it on the device in your hands (issue
# #1717, EPIC #1710 C7): bin/fleet-open.sh / bin/fleet-show.sh hand a page or a
# file to the person's client through the hub (bin/fleet-client-actions.py send),
# and the client (fleet-client-actions.py run) does it on its own device — or
# refuses it.
#
# Nothing real is reached: the hub is a python HTTP server on 127.0.0.1 (killed at
# the end) that signs each action with the lease's key exactly as the Go hub does
# (HMAC-SHA256 over the payload), the opener / notifier / escape writer /
# fleet-open on the client are recorders, `ssh` and the master's connect are fakes,
# `tailscale` answers nothing.
#   A. another machine  — fleet-open.sh on a node with no tmux and no terminal of
#                         the person's → `sent:client`; the client's opener ran
#                         ONCE with the URL; actions.log has the line
#   B. loopback page    — `:8765/d/x/` → the client opens a master to that machine,
#                         forwards a local port to its 127.0.0.1:8765, and only
#                         then opens http://127.0.0.1:<that port>/d/x/
#   C. forged           — an action with no signature, a wrong one, another
#                         lease's, a stale one, a replay → never run, each logged
#                         `refused: …`
#   D. no hub           — the client runs on this screen → `open` here,
#                         `sent:local`; nobody connected → the old road, byte for
#                         byte (open-url.sh's `fallback:copied`)
#   E. iTerm2           — caps iterm2 (no open_url): a note is OSC 9 to the
#                         terminal; a page goes through fleet-open.sh's escape
#   F. link only        — a phone: the page's tailnet address (via tailnet), the
#                         hub's (via public), 「回到电脑上再看」 + links.pending
#                         (neither); a page elsewhere → its own URL
#   G. a file           — fleet-show.sh → show_file; the client fetches it over the
#                         master (`cat`) into Downloads and opens it
#   H. the key          — fleet-client-lease.py writes the acquire's action key
#                         0600 to FLEET_CLIENT_KEY_FILE and never prints it
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-actions selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fca-st.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet" "$WORK/fakebin" "$WORK/client"
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
unset TMUX TMUX_PANE FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_HUB_TOKEN SSH_CONNECTION FLEET_NODE_ALIASES
unset FLEET_CLIENT_WHERE_CMD FLEET_OPEN_WHERE_CMD FLEET_REMOTE_SSH
export FLEET_SHELL_SESSION="fcaS$$" FLEET_SHELL_CACHE="$WORK/shellcache"
export NO_PROXY='*' no_proxy='*'   # a runner's proxy must not stand between us and 127.0.0.1
HUBPID=''

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 (must not hold '$3')" "$2" ;; esac; }
cleanup() { [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# --- fakes ----------------------------------------------------------------------
printf '#!/bin/sh\necho "{}"\n' > "$WORK/fakebin/tailscale"
# the client's opener / notifier / escape writer / fleet-open: recorders
cat > "$WORK/fakebin/rec-open" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$WORK/opened"
EOF
cat > "$WORK/fakebin/rec-notify" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$1" "\$2" >> "$WORK/notified"
EOF
cat > "$WORK/fakebin/rec-escape" <<EOF
#!/bin/sh
cat >> "$WORK/escapes"
EOF
cat > "$WORK/fakebin/rec-fleet-open" <<EOF
#!/bin/sh
printf '%s FLEET_OPEN_CLIENT=%s\n' "\$*" "\${FLEET_OPEN_CLIENT:-}" >> "$WORK/fleetopen"
echo sent:iterm2
EOF
# ssh: -O check / -O forward recorded and answered yes; a slave command run here
cat > "$WORK/fakebin/fake-ssh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/ssh.log"
op=''; cmd=''; i=0; args=("\$@")
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -O) op=\${args[\$((i+1))]}; i=\$((i+2)) ;;
    -S|-L|-o) i=\$((i+2)) ;;
    *) host=\${args[\$i]}; cmd="\${args[*]:\$((i+1))}"; break ;;
  esac
done
[ -n "\$op" ] && exit 0
exec bash -c "\$cmd"
EOF
# the master's connect: makes the control socket's path exist, records the call
cat > "$WORK/fakebin/fake-connect" <<EOF
#!/bin/bash
printf 'connect %s\n' "\$*" >> "$WORK/ssh.log"
for a in "\$@"; do case "\$a" in ControlPath=*) : > "\${a#ControlPath=}" ;; esac; done
EOF
chmod +x "$WORK/fakebin/"*
export PATH="$WORK/fakebin:$PATH"

# --- the fake hub: the Go hub's two action doors + the lease read, same signing ---
KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
LEASE=lease-$$
cat > "$WORK/hub.py" <<'PY'
import hashlib, hmac, json, os, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, key, lease = sys.argv[1:4]
q, done, cv = [], {}, threading.Condition()

def where():
    try:
        return json.load(open(work + "/where.json"))
    except (OSError, ValueError):
        return None

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, d, code=200):
        b = json.dumps(d).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
    def do_GET(self):
        if self.path == "/v1/node/client" and self.headers.get("Authorization") == "Bearer NODETOK":
            w = where()
            return self.reply({"state": "active", "lease": dict(w, id=lease)} if w else {"state": "none"})
        self.reply({}, 404)
    def do_POST(self):
        auth = self.headers.get("Authorization")
        d = self.body()
        if self.path == "/v1/node/client/actions" and auth == "Bearer NODETOK":
            w = where()
            if not w:
                return self.reply({"state": "none"})
            a = {k: v for k, v in d.items() if k != "wait"}
            a.update(id=uuid.uuid4().hex[:12], lease=lease, ts=int(time.time()), machine="otherbox", host="otherbox.lan")
            p = json.dumps(a)
            with cv:
                q.append({"payload": p, "sig": hmac.new(key.encode(), p.encode(), hashlib.sha256).hexdigest()})
                cv.notify_all()
                end = time.time() + int(d.get("wait") or 0)
                while a["id"] not in done and time.time() < end:
                    cv.wait(end - time.time())
                r = done.get(a["id"])
            open(work + "/sent.log", "a").write(p + "\n")
            out = {"state": ("done" if r[0] else "failed") if r else "queued", "id": a["id"], "client": w}
            if r:
                out["result"] = r[1]
            return self.reply(out)
        if self.path == "/v1/fleet/client/actions" and auth == "Bearer CLIENTTOK":
            if d.get("action") == "done":
                with cv:
                    done[d.get("id")] = (bool(d.get("ok")), d.get("result") or "")
                    cv.notify_all()
                return self.reply({"state": "recorded"})
            with cv:
                out, q[:] = list(q), []
            return self.reply({"state": "active", "actions": out})
        if self.path == "/v1/fleet/client" and auth == "Bearer CLIENTTOK":
            return self.reply({"state": "active", "lease": {"id": lease, "device": "MacBook"}, "action_key": key})
        self.reply({}, 404)

s = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(work + "/hub.port.tmp", "w") as f:
    f.write(str(s.server_address[1]))
os.replace(work + "/hub.port.tmp", work + "/hub.port")
s.serve_forever()
PY
python3 "$WORK/hub.py" "$WORK" "$KEY" "$LEASE" & HUBPID=$!
n=300; while [ ! -s "$WORK/hub.port" ] && [ "$n" -gt 0 ]; do sleep 0.1; n=$((n - 1)); done
PORT=$(cat "$WORK/hub.port" 2>/dev/null)
[ -n "$PORT" ] || { fail "the fake hub never listened"; exit 1; }
HUB="http://127.0.0.1:$PORT"

# The node's side: node.env carries the hub + this node's token (read, never sourced).
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=NODETOK\n' "$HUB" > "$FLEET_CONF_DIR/node.env"
# The client's side: its lease, key and where in its own dir.
CL="$WORK/client"
printf '%s\n' "$LEASE" > "$CL/client.lease"
( umask 077; printf '%s\n' "$KEY" > "$CL/client.key" )
where() {  # <caps json> <via> — the person's client, for the hub and for the client itself
  printf '{"device":"MacBook","os":"macOS","terminal":"iTerm2 3.6","via":"%s","host":"MacBook","caps":%s}\n' "$2" "$1" \
    | tee "$WORK/where.json" > "$CL/client.where.json"
}
# One background client: `run --once` rounds against the fake hub, as the real loop would.
client_env() {
  env FLEET_CLIENT_DIR="$CL" FLEET_CLIENT_KEY_FILE="$CL/client.key" FLEET_HUB_URL="$HUB" FLEET_HUB_TOKEN=CLIENTTOK \
      FLEET_CLIENT_OPEN_CMD="$WORK/fakebin/rec-open" FLEET_CLIENT_NOTIFY_CMD="$WORK/fakebin/rec-notify" \
      FLEET_CLIENT_ESCAPE_CMD="$WORK/fakebin/rec-escape" FLEET_CLIENT_FLEET_OPEN="$WORK/fakebin/rec-fleet-open" \
      FLEET_CLIENT_FLEET_SHOW="$WORK/fakebin/rec-fleet-open" FLEET_REMOTE_SSH_CMD="$WORK/fakebin/fake-ssh" \
      FLEET_CLIENT_ACTIONS_CONNECT="$WORK/fakebin/fake-connect" FLEET_CLIENT_DOWNLOADS="$WORK/Downloads" \
      CCQUOTA_TOKEN= "$@"
}
CLIENTPID=''
client_start() {
  ( for _ in $(seq 1 150); do
      client_env python3 "$BIN/fleet-client-actions.py" run --once --session "$FLEET_SHELL_SESSION" 2>>"$WORK/client.err"
      sleep 0.1
    done ) & CLIENTPID=$!
}
client_stop() { [ -n "$CLIENTPID" ] && { kill "$CLIENTPID" 2>/dev/null; wait "$CLIENTPID" 2>/dev/null; }; CLIENTPID=''; }
trap 'client_stop; cleanup' EXIT INT TERM
reset() { rm -f "$WORK/opened" "$WORK/ssh.log" "$WORK/escapes" "$WORK/fleetopen" "$WORK/notified" "$CL/actions.log" "$CL/links.shown" "$CL/links.pending"; }
OPEN() { env FLEET_OPEN_CLIENT_WAIT=8 FLEET_OPEN_URL_BIN="$WORK/fakebin/rec-open" bash "$BIN/fleet-open.sh" "$@" 2>"$WORK/open.err"; }

# --- A. a session on another machine opens a page on the person's device -------------
where '["open_url","show_file","notify"]' local
reset; client_start
r=$(OPEN https://example.com/report)
client_stop
eq "A fleet-open → sent:client" "sent:client" "$r"
eq "A the client's opener ran once, with the URL" "https://example.com/report" "$(cat "$WORK/opened" 2>/dev/null)"
has "A the operator-facing line names the device" "$(cat "$WORK/open.err")" "客户端 MacBook"
has "A actions.log: one line, opened" "$(cat "$CL/actions.log" 2>/dev/null)" "open_url	opened"
eq "A actions.log has ONE line" "1" "$(wc -l < "$CL/actions.log" 2>/dev/null | tr -d ' ')"

# --- B. a page on that machine's loopback: forward first, then open ---------------------
reset; client_start
r=$(OPEN :8765/d/x/)
client_stop
eq "B → sent:client" "sent:client" "$r"
sshlog=$(cat "$WORK/ssh.log" 2>/dev/null)
has "B a master to the page's machine" "$sshlog" "connect otherbox -o ControlMaster=yes"
has "B a local port forwarded to its 127.0.0.1:8765" "$sshlog" ":127.0.0.1:8765 otherbox"
lport=$(printf '%s\n' "$sshlog" | sed -n 's/.*-O forward -L 127\.0\.0\.1:\([0-9]*\):127\.0\.0\.1:8765.*/\1/p' | head -n 1)
eq "B opened the forwarded address" "http://127.0.0.1:$lport/d/x/" "$(cat "$WORK/opened" 2>/dev/null)"
f_line=$(grep -n 'forward' "$WORK/ssh.log" | head -n 1 | cut -d: -f1); c_line=$(grep -n '^connect' "$WORK/ssh.log" | head -n 1 | cut -d: -f1)
CHECKS=$((CHECKS + 1)); [ -n "$f_line" ] && [ -n "$c_line" ] && [ "$c_line" -lt "$f_line" ] || fail "B the master came before the forward" "$sshlog"

# --- C. nothing unsigned, foreign, stale or replayed runs ------------------------------
reset
python3 - "$KEY" "$LEASE" > "$WORK/forged.json" <<'PY'
import hashlib, hmac, json, sys, time
key, lease = sys.argv[1:3]
def act(i, **kw):
    a = dict(id=i, lease=lease, kind="open_url", url="https://evil.example/" + i, machine="x", ts=int(time.time()))
    a.update(kw)
    return json.dumps(a)
def sign(p, k=key):
    return hmac.new(k.encode(), p.encode(), hashlib.sha256).hexdigest()
good = act("good")
out = [
    {"payload": act("nosig")},
    {"payload": act("badsig"), "sig": sign(act("badsig"), "0" * 64)},
    {"payload": act("other", lease="someone-else"), "sig": sign(act("other", lease="someone-else"))},
    {"payload": act("stale", ts=int(time.time()) - 3600), "sig": sign(act("stale", ts=int(time.time()) - 3600))},
    {"payload": good, "sig": sign(good)},
    {"payload": good, "sig": sign(good)},
]
print(json.dumps({"state": "active", "actions": out}))
PY
printf '#!/bin/sh\ncat "%s"\n' "$WORK/forged.json" > "$WORK/fakebin/poll-forged"; chmod +x "$WORK/fakebin/poll-forged"
client_env FLEET_CLIENT_ACTIONS_POLL="$WORK/fakebin/poll-forged" python3 "$BIN/fleet-client-actions.py" run --once --session x
log=$(cat "$CL/actions.log" 2>/dev/null)
eq "C only the one signed action ran, once" "https://evil.example/good" "$(cat "$WORK/opened" 2>/dev/null)"
has "C unsigned refused" "$log" "refused: unsigned"
has "C a wrong signature refused" "$log" "refused: bad signature"
has "C another lease's refused" "$log" "refused: another lease's"
has "C a stale one refused" "$log" "refused: stale"
has "C a replay refused" "$log" "refused: replayed"
# no key at all: nothing runs
reset; mv "$CL/client.key" "$CL/client.key.away"
client_env FLEET_CLIENT_ACTIONS_POLL="$WORK/fakebin/poll-forged" python3 "$BIN/fleet-client-actions.py" run --once --session x
eq "C no action key → nothing runs" "" "$(cat "$WORK/opened" 2>/dev/null)"
mv "$CL/client.key.away" "$CL/client.key"

# --- D. no hub: the client on this screen → open here; nobody → the old road ----------
mv "$FLEET_CONF_DIR/node.env" "$WORK/node.env.away"
printf '#!/bin/sh\necho %s\n' "'{\"state\":\"active\",\"source\":\"local\",\"via\":\"local\",\"caps\":[\"open_url\"]}'" > "$WORK/fakebin/where-local"
printf '#!/bin/sh\necho %s\nexit 3\n' "'{\"state\":\"none\",\"source\":\"local\"}'" > "$WORK/fakebin/where-none"
chmod +x "$WORK/fakebin/where-local" "$WORK/fakebin/where-none"
reset
r=$(FLEET_OPEN_WHERE_CMD="$WORK/fakebin/where-local" FLEET_OPEN_LOCAL_CMD="$WORK/fakebin/rec-open" OPEN :5173/app)
eq "D no hub, client here → sent:local" "sent:local" "$r"
eq "D opened right here, on the loopback" "http://127.0.0.1:5173/app" "$(cat "$WORK/opened" 2>/dev/null)"
reset
cat > "$WORK/fakebin/rec-openurl" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$WORK/openurl"
echo fallback:copied
EOF
chmod +x "$WORK/fakebin/rec-openurl"
r=$(FLEET_OPEN_WHERE_CMD="$WORK/fakebin/where-none" FLEET_OPEN_URL_BIN="$WORK/fakebin/rec-openurl" bash "$BIN/fleet-open.sh" https://example.com/x 2>/dev/null)
eq "D nobody connected → the old road (open-url.sh)" "fallback:copied" "$r"
eq "D … with the URL as before" "https://example.com/x" "$(cat "$WORK/openurl" 2>/dev/null)"
# and the real reader with no hub and no client anywhere: the same old road
rm -f "$WORK/openurl"
r=$(FLEET_OPEN_URL_BIN="$WORK/fakebin/rec-openurl" bash "$BIN/fleet-open.sh" https://example.com/y 2>/dev/null)
eq "D degenerate (no hub, no client) → old road" "fallback:copied" "$r"
mv "$WORK/node.env.away" "$FLEET_CONF_DIR/node.env"

# --- signed actions handed straight to one client round --------------------------------
signed() {  # <action json, without id/lease/ts> → a poll answer with it, signed
  python3 - "$KEY" "$LEASE" "$1" > "$WORK/signed.json" <<'PY'
import hashlib, hmac, json, sys, time, uuid
key, lease, a = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
a.update(id=uuid.uuid4().hex[:12], lease=lease, ts=int(time.time()))
a.setdefault("machine", "otherbox")
p = json.dumps(a)
print(json.dumps({"state": "active", "actions": [{"payload": p, "sig": hmac.new(key.encode(), p.encode(), hashlib.sha256).hexdigest()}]}))
PY
  printf '#!/bin/sh\ncat "%s"\n' "$WORK/signed.json" > "$WORK/fakebin/poll-signed"; chmod +x "$WORK/fakebin/poll-signed"
  client_env FLEET_CLIENT_ACTIONS_POLL="$WORK/fakebin/poll-signed" python3 "$BIN/fleet-client-actions.py" run --once --session x
}

# --- E. caps iterm2: the control sequences -------------------------------------------
where '["link","iterm2"]' tailnet
reset; signed '{"kind":"notify","title":"构建好了","body":"PR #1"}'
eq "E notify → OSC 9 to the terminal" "$(printf '\033]9;构建好了: PR #1\a')" "$(cat "$WORK/escapes" 2>/dev/null)"
eq "E … not the system notifier" "" "$(cat "$WORK/notified" 2>/dev/null)"
reset; signed '{"kind":"open_url","url":"https://example.com/pr"}'
has "E a page → fleet-open.sh's iTerm2 escape" "$(cat "$WORK/fleetopen" 2>/dev/null)" "https://example.com/pr"
has "E … with the client road off (no loop)" "$(cat "$WORK/fleetopen" 2>/dev/null)" "FLEET_OPEN_CLIENT=0"
has "E logged iterm2" "$(cat "$CL/actions.log")" "open_url	iterm2"
where '["open_url","show_file","notify"]' local
reset; signed '{"kind":"notify","title":"t","body":"b"}'
eq "E no iterm2, a computer → the system notifier" "t|b" "$(cat "$WORK/notified" 2>/dev/null)"

# --- F. a phone (caps link): a link to tap, never an open -------------------------------
where '["link"]' tailnet
reset; signed '{"kind":"open_url","rport":8765,"path":"/d/x/","links":{"tailnet":"https://box.tail0.ts.net/d/x/"}}'
has "F via tailnet → the tailnet address" "$(cat "$CL/links.shown" 2>/dev/null)" "打开：https://box.tail0.ts.net/d/x/"
eq "F … nothing opened, no forward" "|" "$(cat "$WORK/opened" 2>/dev/null)|$(cat "$WORK/ssh.log" 2>/dev/null)"
where '["link"]' public
reset; signed '{"kind":"open_url","rport":8765,"path":"/d/x/","links":{"tailnet":"https://box.tail0.ts.net/d/x/","hub":"https://hub.example/p/abc/"}}'
has "F via public → the hub's address" "$(cat "$CL/links.shown" 2>/dev/null)" "打开：https://hub.example/p/abc/"
reset; signed '{"kind":"open_url","rport":8765,"path":"/d/x/","links":{"tailnet":"https://box.tail0.ts.net/d/x/"}}'
has "F neither → 回到电脑上再看" "$(cat "$CL/links.shown" 2>/dev/null)" "回到电脑上再看"
has "F … and the page is on the 待看 list" "$(cat "$CL/links.pending" 2>/dev/null)" "otherbox:8765/d/x/"
has "F logged later" "$(cat "$CL/actions.log")" "open_url	later"
reset; signed '{"kind":"open_url","url":"https://github.com/x/y/pull/1"}'
has "F a page elsewhere → its own URL" "$(cat "$CL/links.shown" 2>/dev/null)" "打开：https://github.com/x/y/pull/1"

# --- G. a file: fleet-show.sh → show_file → fetched over the master, opened -------------
where '["open_url","show_file","notify"]' local
printf 'PNGDATA' > "$WORK/shot.png"
reset; client_start
r=$(env FLEET_SHOW_CLIENT_WAIT=8 bash "$BIN/fleet-show.sh" "$WORK/shot.png" 2>"$WORK/show.err")
client_stop
has "G fleet-show → SENT to the client" "$r" "SENT shot.png → 客户端 MacBook"
eq "G fetched into Downloads" "PNGDATA" "$(cat "$WORK/Downloads/shot.png" 2>/dev/null)"
eq "G … and opened there" "$WORK/Downloads/shot.png" "$(cat "$WORK/opened" 2>/dev/null)"
has "G fetched with cat over the master" "$(cat "$WORK/ssh.log" 2>/dev/null)" "cat -- $WORK/shot.png"
# fleet-open on a file says sent:client too
reset; client_start
r=$(env FLEET_SHOW_CLIENT_WAIT=8 bash "$BIN/fleet-open.sh" "$WORK/shot.png" 2>/dev/null)
client_stop
eq "G fleet-open <file> → sent:client" "sent:client" "$r"
where '["link"]' tailnet
reset; signed "{\"kind\":\"show_file\",\"file\":\"$WORK/shot.png\",\"name\":\"shot.png\"}"
has "G a phone: the file waits for the computer" "$(cat "$CL/links.shown" 2>/dev/null)" "文件 shot.png（在 otherbox 上）：回到电脑上再看"

# --- H. the key: written 0600 by the acquire, never printed ----------------------------
rm -f "$WORK/k"
out=$(env FLEET_HUB_URL="$HUB" FLEET_HUB_TOKEN=CLIENTTOK FLEET_CLIENT_KEY_FILE="$WORK/k" python3 "$BIN/fleet-client-lease.py" acquire --device MacBook 2>&1)
eq "H the key file holds the hub's key" "$KEY" "$(cat "$WORK/k" 2>/dev/null)"
mode=$(stat -f '%Lp' "$WORK/k" 2>/dev/null || stat -c '%a' "$WORK/k" 2>/dev/null)
eq "H … mode 0600" "600" "$mode"
hasnt "H … and is never printed" "$out" "$KEY"
has "H the lease line as before" "$out" "active	$LEASE"

if [ "$FAIL" -gt 0 ]; then
  printf 'fleet-client-actions selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  [ -s "$WORK/client.err" ] && { printf -- '--- client stderr ---\n' >&2; tail -n 20 "$WORK/client.err" >&2; }
  exit 1
fi
printf 'fleet-client-actions selftest: %d checks passed\n' "$CHECKS"
