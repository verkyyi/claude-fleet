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
#                ~/.ssh/fleet-ssh-config verbatim; remembers the hub URL as
#                FLEET_HUB_URL in ~/.config/claude-fleet/fleet.conf, the machine's
#                one config file, with FLEET_ROLE client (issue #1623) — hub.json
#                is left to its token (a token already there is kept);
#                draws a QR (block characters) and prints the user code
#   B. include   appends `Match all` + `Include ~/.ssh/fleet-ssh-config` to an
#                EXISTING ~/.ssh/config AFTER the user's own lines (theirs keep
#                winning), leaves those lines byte for byte, and a second login
#                does not add it twice; the existing key is reused, not replaced
#   C. refused   a denied poll exits 1 and writes no certificate
#   D. status    prints the ssh-keygen -L view of the certificate
#   E. renew     (#1470) `fleet login renew` signs "fleet-renew <ts>" with the
#                device key under fleet-renew@claude-fleet (the hub checks it
#                with `ssh-keygen -Y check-novalidate`), sends its public key
#                and device name, and writes the new certificate — no scan;
#                `check` reads the certificate's remaining validity
#   F. re-scan   the hub's device_idle / device_revoked refusal exits 3 (the
#                "scan again" code) and leaves the old certificate alone;
#                the start request carries the device name too
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
    def sign(self, pub, serial):
        d = tempfile.mkdtemp(dir=SB)
        open(os.path.join(d, "k.pub"), "w").write(pub + "\n")
        subprocess.run(["ssh-keygen", "-q", "-s", os.path.join(SB, "ca"), "-I", "wecom:Alice",
                        "-n", "alice", "-V", "-1m:+12h", "-z", str(serial), os.path.join(d, "k.pub")], check=True)
        return open(os.path.join(d, "k-cert.pub")).read()
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/v1/fleet/login/renew":
            # #1470: the device key's signature over "fleet-renew <ts>".
            with tempfile.TemporaryDirectory(dir=SB) as td:
                open(os.path.join(td, "sig"), "w").write(body.get("sig", ""))
                r = subprocess.run(["ssh-keygen", "-Y", "check-novalidate", "-n", "fleet-renew@claude-fleet",
                                    "-s", os.path.join(td, "sig")],
                                   input=("fleet-renew %d" % body.get("ts", 0)).encode(), capture_output=True)
            if r.returncode != 0 or not body.get("public_key", "").startswith("ssh-ed25519 "):
                return self.reply(401, {"error": "bad signature", "code": "bad_signature"})
            open(os.path.join(SB, "renew.json"), "w").write(json.dumps(body))
            if os.path.exists(os.path.join(SB, "idle")):
                return self.reply(403, {"error": "this device has not been used for 7 days", "code": "device_idle"})
            return self.reply(200, {"certificate": self.sign(body["public_key"], 2), "serial": "2", "key_id": "wecom:Alice",
                "principals": ["alice"], "valid_before": "2026-10-05T00:00:00Z", "ssh_config": CONF, "hub": ""})
        if self.path == "/v1/fleet/login/start":
            state["pub"] = body["public_key"]
            open(os.path.join(SB, "sent.pub"), "w").write(body["public_key"] + "\n")
            open(os.path.join(SB, "start.json"), "w").write(json.dumps(body))
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
export HOME="$SB/home" XDG_CONFIG_HOME="$SB/home/.config"
unset FLEET_CONF_DIR   # a laptop has none: fleet.conf is ~/.config/claude-fleet/fleet.conf (issue #1623)
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
grep -qx "export FLEET_HUB_URL=\"http://127.0.0.1:$PORT\"" "$HOME/.config/claude-fleet/fleet.conf" 2>/dev/null && ok "A hub remembered in fleet.conf" || bad "A hub not remembered: $(cat "$HOME/.config/claude-fleet/fleet.conf" 2>&1)"
grep -qx 'FLEET_ROLE="client"' "$HOME/.config/claude-fleet/fleet.conf" 2>/dev/null && ok "A role client" || bad "A no FLEET_ROLE client"
[ -f "$HOME/.config/claude-fleet/hub.json" ] && grep -q '"url"' "$HOME/.config/claude-fleet/hub.json" && bad "A the url went to hub.json too" || ok "A hub.json holds no url"
echo "$out" | grep -q 'BCDF-GHJK' && echo "$out" | grep -q '█\|▀\|▄' && ok "A code + QR shown" || bad "A no code/QR: $out"

# ── B ──
conf="$(cat "$HOME/.ssh/config")"
[ "${conf:0:${#ORIG_CONF}}" = "$ORIG_CONF" ] && ok "B user's lines first, untouched" || bad "B config changed: $conf"
printf '%s\n' "$conf" | tail -4 | tr '\n' '|' | grep -q 'Match all|Include ~/.ssh/fleet-ssh-config|' && ok "B Include appended" || bad "B include: $conf"
key_before="$(cat "$HOME/.ssh/fleet-cert.pub")"
python3 - "$HOME/.config/claude-fleet/hub.json" <<'PY2'
import json, sys
try: d = json.load(open(sys.argv[1]))
except OSError: d = {}
d["token"] = "tok-123"; json.dump(d, open(sys.argv[1], "w"))
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

# ── E — renew by the device key (#1470) ──
grep -q '"device_name": "[A-Za-z0-9._-]' "$SB/start.json" && ok "E start carried the device name" || bad "E start.json: $(cat "$SB/start.json")"
out="$(python3 "$BIN/fleet-login.py" check)"; rc=$?
case "$rc:$out" in 0:valid\ [0-9]*) ok "E check: valid, seconds left" ;; *) bad "E check rc=$rc out=$out" ;; esac
rm -f "$SB/renew.json"
start_hub
out="$(python3 "$BIN/fleet-login.py" renew 2>&1)"; rc=$?
stop_hub
[ "$rc" = 0 ] && echo "$out" | grep -q '已续期' && ok "E renew exit 0" || bad "E renew rc=$rc: $out"
[ -s "$SB/renew.json" ] && grep -q '"device_name"' "$SB/renew.json" && ok "E renew sent public key + device name, signature verified by the hub" || bad "E renew request: $(cat "$SB/renew.json" 2>/dev/null)"
L="$(ssh-keygen -L -f "$HOME/.ssh/fleet-cert-cert.pub" 2>&1)"
echo "$L" | grep -q 'Serial: 2' && ok "E new certificate written (serial 2)" || bad "E certificate: $L"
[ "$(grep -c 'Include ~/.ssh/fleet-ssh-config' "$HOME/.ssh/config")" = 1 ] && ok "E Include still once" || bad "E Include duplicated by renew"
start_hub
python3 "$BIN/fleet-login.py" renew --quiet >"$SB/quiet.out" 2>&1; rc=$?
stop_hub
[ "$rc" = 0 ] && [ ! -s "$SB/quiet.out" ] && ok "E renew --quiet says nothing" || bad "E quiet rc=$rc: $(cat "$SB/quiet.out")"

# ── F — the hub says: scan again ──
touch "$SB/idle"
start_hub
out="$(python3 "$BIN/fleet-login.py" renew 2>&1)"; rc=$?
stop_hub
rm -f "$SB/idle"
[ "$rc" = 3 ] && echo "$out" | grep -q '重新扫码' && ok "F device_idle → exit 3 (scan again)" || bad "F idle rc=$rc: $out"
ssh-keygen -L -f "$HOME/.ssh/fleet-cert-cert.pub" 2>&1 | grep -q 'Serial: 2' && ok "F old certificate left alone" || bad "F certificate touched"
mv "$HOME/.ssh/fleet-cert" "$SB/key.bak"
out="$(python3 "$BIN/fleet-login.py" renew --hub "http://127.0.0.1:1" 2>&1)"; rc=$?
mv "$SB/key.bak" "$HOME/.ssh/fleet-cert"
[ "$rc" = 3 ] && ok "F no device key → exit 3" || bad "F no key rc=$rc: $out"
out="$(python3 "$BIN/fleet-login.py" renew --hub "http://127.0.0.1:1" 2>&1)"; rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q 'unreachable' && ok "F hub unreachable → exit 1" || bad "F unreachable rc=$rc: $out"
rm -f "$HOME/.ssh/fleet-cert-cert.pub"
out="$(python3 "$BIN/fleet-login.py" check)"; rc=$?
[ "$rc" = 1 ] && [ "$out" = none ] && ok "F check: none" || bad "F check rc=$rc out=$out"

[ "$fail" = 0 ] && echo "PASS fleet-login-selftest" || echo "FAIL fleet-login-selftest"
exit "$fail"
