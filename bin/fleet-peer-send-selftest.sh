#!/bin/bash
# fleet-peer-send-selftest.sh — hermetic test for fleet_peer_send / bin/fleet-peer-send.sh
# (issue #513): the fleet's way to message a LIVE Claude session over its local
# inbox socket (the SendMessage channel) instead of tmux send-keys.
#
# A python3 unix-socket listener stands in for a session's inbox; a scratch
# ~/.claude/sessions holds the registry record + key file the helpers read. Pins:
#   • the wire: an auth frame `{"type":"auth","token":<peerToken>}`, then a user
#     frame `{"type":"user","message":{"role":"user","content":…}}`, newline-
#     delimited, in that order;
#   • the content rides Claude Code's canonical cross-session envelope with
#     from-name + from-mode (the attestation a bypass-mode recipient needs, or it
#     HOLDS the message behind a dialog), body verbatim (multi-line ok);
#   • target resolution: pid, session uuid → pid via the registry; no key /
#     no socket / dead pid → exit 1 and nothing written.
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-peer-send selftest: python3 absent — skipped\n'; exit 0; }

CHECKS=0
fail() { printf 'fleet-peer-send selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-peer-send.XXXXXX")" || exit 2
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
unset TMUX TMUX_PANE
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# a "session": a long-lived pid (sleep) with a registry record + key + inbox socket
sleep 60 & PID=$!
SOCK="$WORK/inbox.sock"; SID="0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b"
printf '{"pid":%s,"sessionId":"%s","cwd":"/x","messagingSocketPath":"%s","name":"tester"}\n' "$PID" "$SID" "$SOCK" > "$FLEET_CC_SESSIONS_DIR/$PID.json"
printf '{"peerToken":"tok-abc-123","procStart":"x","pidDomain":"darwin"}' > "$FLEET_CC_SESSIONS_DIR/$PID.deadbeef.key"
# the listener: accept one connection, dump everything received to $WORK/got
python3 - "$SOCK" "$WORK/got" <<'PY' &
import socket, sys, os
sock, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sock); s.listen(1); s.settimeout(15)
c, _ = s.accept(); c.settimeout(5); buf = b""
try:
    while True:
        d = c.recv(65536)
        if not d: break
        buf += d
except Exception: pass
open(out, "wb").write(buf); c.close(); s.close()
PY
LISTENER=$!
cleanup() { kill "$PID" "$LISTENER" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
for _ in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || fail "rig: listener socket never appeared"

# --- 1. the wire + the envelope (via the CLI, session-uuid target)
out=$(FLEET_PEER_MODE=bypass bash "$BIN/fleet-peer-send.sh" "$SID" "hello worker"$'\n'"line two") || fail "fleet-peer-send.sh exit non-zero: $out"
ok; printf '%s' "$out" | grep -q "sent → pid $PID" || fail "CLI must report the resolved pid: $out"
wait "$LISTENER" 2>/dev/null
[ -s "$WORK/got" ] || fail "nothing reached the inbox socket"
python3 - "$WORK/got" <<'PY' || fail "frame check failed (see above)"
import json, sys
raw = open(sys.argv[1], "rb").read().decode()
lines = raw.split("\n")
assert raw.endswith("\n"), "frames must be newline-terminated: %r" % raw
frames = [json.loads(l) for l in lines if l.strip()]
assert len(frames) == 2, "expected exactly 2 frames (auth, user), got %d: %r" % (len(frames), raw)
assert frames[0] == {"type": "auth", "token": "tok-abc-123"}, "auth frame wrong: %r" % frames[0]
u = frames[1]
assert u["type"] == "user" and u["message"]["role"] == "user", "user frame wrong: %r" % u
c = u["message"]["content"]
exp = '<cross-session-message from-name="fleet" from-mode="bypass">\nhello worker\nline two\n</cross-session-message>'
assert c == exp, "envelope not canonical:\n got: %r\nwant: %r" % (c, exp)
print("frames ok")
PY
ok

# --- 2. from-name + prompting mode, pid target, via the lib directly
rm -f "$WORK/got"
python3 - "$SOCK" "$WORK/got" <<'PY' &
import socket, sys, os
sock, out = sys.argv[1], sys.argv[2]
os.unlink(sock)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(sock); s.listen(1); s.settimeout(15)
c, _ = s.accept(); c.settimeout(5); buf = b""
try:
    while True:
        d = c.recv(65536)
        if not d: break
        buf += d
except Exception: pass
open(out, "wb").write(buf); c.close(); s.close()
PY
LISTENER=$!; sleep 0.5
ok; FLEET_PEER_MODE=prompting fleet_peer_send "$PID" 'say "hi" <now>' 'quota"watch<x>' || fail "fleet_peer_send (pid target) must succeed"
wait "$LISTENER" 2>/dev/null
ok; python3 - "$WORK/got" <<'PY' || fail "from-name must be scrubbed of quotes/angles, from-mode honoured, body verbatim (see above)"
import json, sys
f = [json.loads(l) for l in open(sys.argv[1]).read().split("\n") if l.strip()]
c = f[1]["message"]["content"]
exp = '<cross-session-message from-name="quotawatchx" from-mode="prompting">\nsay "hi" <now>\n</cross-session-message>'
assert c == exp, "got: %r\nwant: %r" % (c, exp)
PY

# --- 3. refusals: no key, no socket, dead pid, unknown target — nothing sent, exit 1
sleep 60 & P2=$!
printf '{"pid":%s,"sessionId":"aaaa-bbbb","messagingSocketPath":"%s"}\n' "$P2" "$WORK/none.sock" > "$FLEET_CC_SESSIONS_DIR/$P2.json"
ok; fleet_peer_send "$P2" "x" && fail "no key file → must refuse"
printf '{"peerToken":"t"}' > "$FLEET_CC_SESSIONS_DIR/$P2.k.key"
ok; fleet_peer_send "$P2" "x" && fail "no socket → must refuse"
kill "$P2" 2>/dev/null; wait "$P2" 2>/dev/null
ok; bash "$BIN/fleet-peer-send.sh" "$P2" "x" >/dev/null 2>&1 && fail "dead pid → CLI must exit 1"
ok; bash "$BIN/fleet-peer-send.sh" "no-such-session-uuid-0000" "x" >/dev/null 2>&1 && fail "unknown target → CLI must exit 1"
ok; [ "$(fleet_cc_pid_for_session "$SID")" = "$PID" ] || fail "fleet_cc_pid_for_session must resolve the registry pid"
ok; [ "$(fleet_cc_peer_token "$PID")" = "tok-abc-123" ] || fail "fleet_cc_peer_token must read peerToken off the key file"

printf 'fleet-peer-send selftest: OK (%d checks)\n' "$CHECKS"
exit 0
