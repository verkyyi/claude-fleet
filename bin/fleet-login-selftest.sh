#!/bin/bash
# fleet-login-selftest.sh — bin/fleet-login.py (`fleet login`, issue #1412)
# against a fake hub on 127.0.0.1, fully hermetic: HOME is a sandbox, the hub
# is a tiny python server that answers start/poll the way tokenledger does and
# signs with a REAL throwaway CA (`ssh-keygen -s`), so the certificate the
# client writes is checked with `ssh-keygen -L` like the 上线证据 says.
#
# What it pins:
#   A. login     makes ~/.ssh/fleet-cert (ed25519) and sends ITS public half;
#                waits through a pending poll; writes ~/.ssh/fleet-cert-cert.pub
#                (a user cert, principal alice, ~12h, signed by the CA) and
#                ~/.ssh/fleet-ssh-config verbatim; remembers the hub URL in
#                ~/.config/claude-fleet/hub.json (a token already there is kept);
#                draws a QR (block characters) and prints the user code
#   B. include   appends `Match all` + `Include ~/.ssh/fleet-ssh-config` to an
#                EXISTING ~/.ssh/config AFTER the user's own lines (theirs keep
#                winning), leaves those lines byte for byte, and a second login
#                does not add it twice; the existing key is reused, not replaced
#   C. refused   a denied poll exits 1 and writes no certificate
#   D. status    prints the ssh-keygen -L view of the certificate
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/fleet-cert-st.XXXXXX")"
HUB_PID=""
cleanup() { [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null; rm -rf "$SB"; }
trap cleanup EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

command -v ssh-keygen >/dev/null || { echo "skip: no ssh-keygen"; exit 0; }
ssh-keygen -q -t ed25519 -N '' -C fleet-ca -f "$SB/ca" || exit 1

cat >"$SB/hub.py" <<'PY'
import json, os, subprocess, sys, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
SB = sys.argv[1]
state = {"polls": 0, "pub": None, "deny": os.path.exists(os.path.join(SB, "deny"))}
CONF = "# fleet-ssh-config v1 — test\n\nHost m4 fleet-m4 fleet-m4-public\n  HostName 127.0.0.1\n  User alice\n  IdentityFile ~/.ssh/fleet-cert\n  CertificateFile ~/.ssh/fleet-cert-cert.pub\n"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/fleet/login/start":
            state["pub"] = body["public_key"]
            open(os.path.join(SB, "sent.pub"), "w").write(body["public_key"] + "\n")
            return self.reply(200, {"device_code": "d" * 64, "user_code": "BCDF-GHJK",
                "verification_uri": "http://127.0.0.1/fleet/login?code=BCDF-GHJK", "expires_in": 30,
                "interval": 1, "key_fingerprint": "SHA256:test", "qr": ["#.#", ".#.", "#.#"]})
        if self.path == "/v1/fleet/login/poll":
            state["polls"] += 1
            if state["polls"] < 2:
                return self.reply(202, {"status": "authorization_pending"})
            if state["deny"]:
                return self.reply(403, {"error": "access_denied"})
            d = tempfile.mkdtemp(dir=SB)
            open(os.path.join(d, "k.pub"), "w").write(state["pub"] + "\n")
            subprocess.run(["ssh-keygen", "-q", "-s", os.path.join(SB, "ca"), "-I", "wecom:Alice",
                            "-n", "alice", "-V", "-1m:+12h", "-z", "1", os.path.join(d, "k.pub")], check=True)
            cert = open(os.path.join(d, "k-cert.pub")).read()
            return self.reply(200, {"certificate": cert, "serial": "1", "key_id": "wecom:Alice",
                "principals": ["alice"], "valid_before": "2026-10-04T12:00:00Z", "ssh_config": CONF, "hub": ""})
        self.reply(404, {})
srv = HTTPServer(("127.0.0.1", int(sys.argv[2]) if len(sys.argv) > 2 else 0), H)
open(os.path.join(SB, "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY

start_hub() {
  rm -f "$SB/port"
  # The same port every time after the first: the client remembers the URL.
  python3 "$SB/hub.py" "$SB" ${PORT:-} & HUB_PID=$!
  # A cold python3 on a CI runner can take seconds to bind: wait up to 30s,
  # and stop loudly rather than point the client at an empty port.
  for _ in $(seq 300); do [ -s "$SB/port" ] && break; sleep 0.1; done
  [ -s "$SB/port" ] || { echo "FAIL fake hub never started"; exit 1; }
  PORT="$(cat "$SB/port")"
}
stop_hub() { kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; HUB_PID=""; }

PORT=""
export HOME="$SB/home"
mkdir -p "$HOME/.ssh"
printf 'Host mine\n  HostName 10.0.0.1\n  User me\n' >"$HOME/.ssh/config"
ORIG_CONF="$(cat "$HOME/.ssh/config")"

# ── A ──
start_hub
out="$(python3 "$BIN/fleet-login.py" --hub "http://127.0.0.1:$PORT" 2>&1)"; rc=$?
stop_hub
[ "$rc" = 0 ] && ok "A login exit 0" || bad "A login exit $rc: $out"
[ -f "$HOME/.ssh/fleet-cert" ] && grep -q '^ssh-ed25519 ' "$HOME/.ssh/fleet-cert.pub" && ok "A key made" || bad "A no ed25519 key"
cmp -s "$HOME/.ssh/fleet-cert.pub" "$SB/sent.pub" && ok "A sent its own public key" || bad "A sent a different key"
L="$(ssh-keygen -L -f "$HOME/.ssh/fleet-cert-cert.pub" 2>&1)"
echo "$L" | grep -q 'user certificate' && ok "A user certificate" || bad "A not a user cert: $L"
echo "$L" | grep -A1 'Principals:' | grep -qx '[[:space:]]*alice' && ok "A principal alice" || bad "A principals: $L"
echo "$L" | grep -q "Signing CA: ED25519 $(ssh-keygen -lf "$SB/ca.pub" | awk '{print $2}')" && ok "A signed by the CA" || bad "A signing CA: $L"
grep -q '^Host m4 fleet-m4 fleet-m4-public$' "$HOME/.ssh/fleet-ssh-config" && ok "A ssh config written" || bad "A ssh config"
[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$HOME/.config/claude-fleet/hub.json")" = "http://127.0.0.1:$PORT" ] && ok "A hub remembered in hub.json" || bad "A hub not remembered"
echo "$out" | grep -q 'BCDF-GHJK' && echo "$out" | grep -q '█\|▀\|▄' && ok "A code + QR shown" || bad "A no code/QR: $out"

# ── B ──
conf="$(cat "$HOME/.ssh/config")"
[ "${conf:0:${#ORIG_CONF}}" = "$ORIG_CONF" ] && ok "B user's lines first, untouched" || bad "B config changed: $conf"
printf '%s\n' "$conf" | tail -4 | tr '\n' '|' | grep -q 'Match all|Include ~/.ssh/fleet-ssh-config|' && ok "B Include appended" || bad "B include: $conf"
key_before="$(cat "$HOME/.ssh/fleet-cert.pub")"
python3 - "$HOME/.config/claude-fleet/hub.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1])); d["token"] = "tok-123"; json.dump(d, open(sys.argv[1], "w"))
PY2
start_hub
python3 "$BIN/fleet-login.py" >/dev/null 2>&1; rc=$?   # remembered hub
stop_hub
[ "$rc" = 0 ] && ok "B second login (remembered hub)" || bad "B second login exit $rc"
grep -q '"token": "tok-123"' "$HOME/.config/claude-fleet/hub.json" && ok "B hub.json token kept" || bad "B hub.json token lost"
[ "$(grep -c 'Include ~/.ssh/fleet-ssh-config' "$HOME/.ssh/config")" = 1 ] && ok "B Include once" || bad "B Include duplicated"
[ "$(cat "$HOME/.ssh/fleet-cert.pub")" = "$key_before" ] && ok "B key reused" || bad "B key replaced"

# ── C ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub"; touch "$SB/deny"
start_hub
python3 "$BIN/fleet-login.py" >/dev/null 2>&1; rc=$?
stop_hub
[ "$rc" = 1 ] && [ ! -e "$HOME/.ssh/fleet-cert-cert.pub" ] && ok "C denied → exit 1, no cert" || bad "C denied rc=$rc"
rm -f "$SB/deny"

# ── D ──
start_hub; python3 "$BIN/fleet-login.py" >/dev/null 2>&1; stop_hub
python3 "$BIN/fleet-login.py" status | grep -q 'Key ID: "wecom:Alice"' && ok "D status" || bad "D status"

[ "$fail" = 0 ] && echo "PASS fleet-login-selftest" || echo "FAIL fleet-login-selftest"
exit "$fail"
