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
#                one config file, with FLEET_HOST=0 (issues #1623, #1806) — hub.json
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
#   H. nologin   the hub denies a person with no machine login (code
#                no_machine_login): the client prints the reason, exits 1 (#2090)
#   I. pick      `fleet-connect.py --pick` that needs a scan: everything the
#                scan shows is on stderr, stdout is one JSON line (#2090)
#   J. orphan    (#2112) a renewal the hub signs (200) but whose key id its
#                roster no longer names: the check (a signed `get` on the client
#                lease) answers 401 「names no one」 → exit 3, scan again; a hub
#                with no lease door (404) leaves the renewal at exit 0
#   K. if-under  `renew --if-under SECS` asks nothing while more is left (and
#                with no certificate at all), renews when less is; --quiet
#                orphan → exit 3 and silent (the client keeper's call)
#   G. blip      a 503 between two polls (the ingress, the hub restarting) is
#                not a refusal: the client keeps waiting and gets its
#                certificate (#1901 — a colleague's first scan died on one)
#   L. browser   (#2262) with a screen here the confirmation page opens in this
#                computer's browser (a fake `open` / `xdg-open` records its
#                argv): the verification URL, no QR drawn, certificate written
#   M. no screen over ssh (SSH_CONNECTION) the opener is never called and the
#                QR is drawn; --qr does the same with a screen
#   N. no opener the browser will not open → says so, draws the QR, still logs in
#   O. waiting   every FLEET_LOGIN_NUDGE_SECS a 「还在等浏览器里授权…（按 q 改用
#                二维码）」 line; past FLEET_LOGIN_TIMEOUT_SECS it stops (exit 1)
#                with why and the next step, no certificate; defaults 15 / 120
#   P. q         on a real terminal (a pty) a `q` while waiting draws the QR
#   Q. old token a hub.json token the hub answers 401 (an old identity) is
#                removed before the scan, every other key kept; `fleet --pick`
#                with such a token logs this person in instead of failing
#   W. wording   no output of any leg says 企业微信
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
        subprocess.run(["ssh-keygen", "-q", "-s", os.path.join(SB, "ca"), "-I", "gh:Alice",
                        "-n", "alice", "-V", "-1m:+12h", "-z", str(serial), os.path.join(d, "k.pub")], check=True)
        return open(os.path.join(d, "k-cert.pub")).read()
    def do_GET(self):
        if self.path.startswith("/v1/fleet/home"):
            # #2262: a viewer token from an old identity is refused
            if self.headers.get("Authorization", "") == "Bearer dead-tok":
                return self.reply(401, {"error": "a session, a viewer token or a connection certificate is required"})
            return self.reply(200, {})
        self.reply(404, {})
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
            return self.reply(200, {"certificate": self.sign(body["public_key"], 2), "serial": "2", "key_id": "gh:Alice",
                "principals": ["alice"], "valid_before": "2026-10-05T00:00:00Z", "ssh_config": CONF, "hub": ""})
        if self.path == "/v1/fleet/client" and os.path.exists(os.path.join(SB, "orphan")):
            # #2112: the hub's roster no longer names the certificate's key id
            open(os.path.join(SB, "client.json"), "w").write(json.dumps(body))
            return self.reply(401, {"error": "connection certificate refused: its key id names no one this hub knows"})
        if self.path == "/v1/fleet/login/start":
            state["pub"] = body["public_key"]
            open(os.path.join(SB, "sent.pub"), "w").write(body["public_key"] + "\n")
            open(os.path.join(SB, "start.json"), "w").write(json.dumps(body))
            return self.reply(200, {"device_code": "d" * 64, "user_code": "BCDF-GHJK",
                "verification_uri": "http://127.0.0.1/fleet/login?code=BCDF-GHJK", "expires_in": 30,
                "interval": 1, "key_fingerprint": "SHA256:test", "qr": ["#.#", ".#.", "#.#"]})
        if self.path == "/v1/fleet/login/poll":
            state["polls"] += 1
            if os.path.exists(os.path.join(SB, "blip")) and state["polls"] == 1:
                return self.reply(503, {})
            if state["polls"] < 2 or os.path.exists(os.path.join(SB, "pending")):
                return self.reply(202, {"status": "authorization_pending"})
            if os.path.exists(os.path.join(SB, "nologin")):
                # #2090: the person has no machine login — the hub denies at once, with the reason
                return self.reply(403, {"error": "access_denied: no machine login", "code": "no_machine_login",
                    "reason": "入口还没给你分配机器登录 —— 请管理员在「使用者」页给 cjilyy 设机器登录"})
            if state["deny"]:
                return self.reply(403, {"error": "access_denied"})
            d = tempfile.mkdtemp(dir=SB)
            open(os.path.join(d, "k.pub"), "w").write(state["pub"] + "\n")
            subprocess.run(["ssh-keygen", "-q", "-s", os.path.join(SB, "ca"), "-I", "gh:Alice",
                            "-n", "alice", "-V", "-1m:+12h", "-z", "1", os.path.join(d, "k.pub")], check=True)
            cert = open(os.path.join(d, "k-cert.pub")).read()
            return self.reply(200, {"certificate": cert, "serial": "1", "key_id": "gh:Alice", "name": "alice-gh",
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
# The legs before L run as a terminal with no screen (the QR); L–Q choose.
export FLEET_LOGIN_BROWSER=0
unset SSH_CONNECTION SSH_TTY FLEET_HUB_TOKEN
# A fake browser opener for L–Q: records its argv, answers $SB/open.rc.
mkdir -p "$SB/fakebin"
for o in open xdg-open; do
  printf '#!/bin/sh\necho "$0 $*" >>"%s/opened"\nexit "$(cat "%s/open.rc" 2>/dev/null || echo 0)"\n' "$SB" "$SB" >"$SB/fakebin/$o"
  chmod +x "$SB/fakebin/$o"
done
ALL_OUT=""
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
# #2577: the hub's name (the GitHub login) kept beside the certificate, by key id
[ "$(cat "$HOME/.ssh/fleet-cert-who" 2>/dev/null)" = "$(printf 'gh:Alice\talice-gh')" ] && ok "A GitHub login recorded (fleet-cert-who)" \
  || bad "A who record: $(cat "$HOME/.ssh/fleet-cert-who" 2>&1)"
echo "$L" | grep -q "Signing CA: ED25519 $(ssh-keygen -lf "$SB/ca.pub" | awk '{print $2}')" && ok "A signed by the CA" || bad "A signing CA: $L"
grep -q '^Host m4 fleet-m4 fleet-m4-public$' "$HOME/.ssh/fleet-ssh-config" && ok "A ssh config written" || bad "A ssh config"
grep -qx "export FLEET_HUB_URL=\"http://127.0.0.1:$PORT\"" "$HOME/.config/claude-fleet/fleet.conf" 2>/dev/null && ok "A hub remembered in fleet.conf" || bad "A hub not remembered: $(cat "$HOME/.config/claude-fleet/fleet.conf" 2>&1)"
grep -qx 'FLEET_HOST=0' "$HOME/.config/claude-fleet/fleet.conf" 2>/dev/null && ok "A FLEET_HOST=0 (#1806)" || bad "A no FLEET_HOST=0: $(cat "$HOME/.config/claude-fleet/fleet.conf" 2>&1)"
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
python3 "$BIN/fleet-login.py" status | grep -q 'Key ID: "gh:Alice"' && ok "D status" || bad "D status"

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

# ── J — renewed, and still refused: the key id names no one (#2112) ──
start_hub; python3 "$BIN/fleet-login.py" renew --quiet >/dev/null 2>&1; stop_hub   # a certificate again
touch "$SB/orphan"; rm -f "$SB/client.json"
start_hub
out="$(python3 "$BIN/fleet-login.py" renew 2>&1)"; rc=$?
stop_hub
rm -f "$SB/orphan"
[ "$rc" = 3 ] && echo "$out" | grep -q '重新扫码' && echo "$out" | grep -q 'names no one' \
  && ok "J renew 200 but the certificate's key id names no one → exit 3 (scan again)" || bad "J orphan rc=$rc: $out"
grep -q '"action": "get"' "$SB/client.json" 2>/dev/null && grep -q '"cert": "ssh-ed25519-cert' "$SB/client.json" \
  && ok "J the check is a signed get on the client lease" || bad "J check request: $(cat "$SB/client.json" 2>/dev/null)"
start_hub
out="$(python3 "$BIN/fleet-login.py" renew 2>&1)"; rc=$?
stop_hub
[ "$rc" = 0 ] && ok "J a hub with no lease door (404) → the renewal stands, exit 0" || bad "J no-door rc=$rc: $out"

# ── K — --if-under: the keeper's margin call (#2112) ──
rm -f "$SB/renew.json"
start_hub
out="$(python3 "$BIN/fleet-login.py" renew --quiet --if-under 3600 2>&1)"; rc=$?
stop_hub
[ "$rc" = 0 ] && [ ! -e "$SB/renew.json" ] && ok "K 12h left, under 1h asked → exit 0, nothing asked" || bad "K early rc=$rc renew.json=$([ -e "$SB/renew.json" ] && echo yes): $out"
start_hub
out="$(python3 "$BIN/fleet-login.py" renew --quiet --if-under 86400 2>&1)"; rc=$?
stop_hub
[ "$rc" = 0 ] && [ -s "$SB/renew.json" ] && ok "K less left than asked → renewed" || bad "K due rc=$rc: $out"
touch "$SB/orphan"
start_hub
out="$(python3 "$BIN/fleet-login.py" renew --quiet --if-under 86400 2>&1)"; rc=$?
stop_hub
rm -f "$SB/orphan"
[ "$rc" = 3 ] && [ -z "$out" ] && ok "K --quiet orphan → exit 3, silent" || bad "K quiet orphan rc=$rc: $out"
mv "$HOME/.ssh/fleet-cert-cert.pub" "$SB/cert.bak"
out="$(python3 "$BIN/fleet-login.py" renew --quiet --if-under 3600 --hub "http://127.0.0.1:1" 2>&1)"; rc=$?
mv "$SB/cert.bak" "$HOME/.ssh/fleet-cert-cert.pub"
[ "$rc" = 0 ] && ok "K no certificate (signed in another way) → exit 0, nothing asked" || bad "K nocert rc=$rc: $out"

# ── G — a 5xx between two polls is a blip, not a «no» (#1901) ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub"; touch "$SB/blip"
start_hub
out="$(python3 "$BIN/fleet-login.py" 2>&1)"; rc=$?
stop_hub
rm -f "$SB/blip"
[ "$rc" = 0 ] && [ -s "$HOME/.ssh/fleet-cert-cert.pub" ] && ok "G a 503 poll → kept waiting, certificate written" || bad "G blip rc=$rc: $out"

# ── H — no machine login: the terminal says why at that poll and stops (#2090) ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub"; touch "$SB/nologin"
start_hub
out="$(python3 "$BIN/fleet-login.py" 2>&1)"; rc=$?
stop_hub
rm -f "$SB/nologin"
[ "$rc" = 1 ] && [ ! -e "$HOME/.ssh/fleet-cert-cert.pub" ] && echo "$out" | grep -q '「使用者」页给 cjilyy 设机器登录' \
  && ! echo "$out" | grep -q 'timed out' && ok "H no machine login → reason printed, exit 1" || bad "H nologin rc=$rc: $out"
echo "$out" | grep -q 'GitHub' && ! echo "$out" | grep -q '企业微信' && ok "H the prompt says GitHub, not WeCom" || bad "H prompt: $out"

# ── I — `fleet --pick` (fleet-shell.sh captures its stdout) that needs a scan:
#        the code, QR and link reach the person on stderr; stdout stays the one JSON line (#2090) ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub" "$HOME/.ssh/fleet-cert" "$HOME/.ssh/fleet-cert.pub" \
      "$HOME/.config/claude-fleet/hub.json"   # B's token would skip the certificate
start_hub
python3 "$BIN/fleet-connect.py" --hub "http://127.0.0.1:$PORT" --pick >"$SB/pick.out" 2>"$SB/pick.err" </dev/null; rc=$?
stop_hub
if [ "$(wc -l <"$SB/pick.out" | tr -d ' ')" = 1 ] && python3 -c 'import json,sys; json.loads(open(sys.argv[1]).read())' "$SB/pick.out" \
   && grep -q 'BCDF-GHJK' "$SB/pick.err" && grep -q '链接：http://' "$SB/pick.err" && grep -q '证书已写入' "$SB/pick.err"; then
  ok "I --pick with a scan: code + link + ✓ on stderr, stdout one JSON line"
else bad "I pick rc=$rc stdout=[$(cat "$SB/pick.out")] stderr=[$(cat "$SB/pick.err")]"; fi

# ── L — a screen here: the browser opens on the confirmation page (#2262) ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub" "$SB/opened" "$SB/open.rc"
start_hub
out="$(PATH="$SB/fakebin:$PATH" FLEET_LOGIN_BROWSER=1 python3 "$BIN/fleet-login.py" 2>&1 </dev/null)"; rc=$?
stop_hub
ALL_OUT="$ALL_OUT$out"
grep -q 'open.* http://127.0.0.1/fleet/login?code=BCDF-GHJK$' "$SB/opened" 2>/dev/null \
  && ok "L the browser opened on the verification URL" || bad "L opener: $(cat "$SB/opened" 2>&1)"
[ "$rc" = 0 ] && [ -s "$HOME/.ssh/fleet-cert-cert.pub" ] && echo "$out" | grep -q '已在浏览器里打开' \
  && echo "$out" | grep -q 'BCDF-GHJK' && ! echo "$out" | grep -q '█\|▀\|▄' \
  && ok "L said so, no QR drawn, certificate written" || bad "L rc=$rc: $out"

echo "$out" | grep -q '没看到？打开 http://.* ，或按 q 改用手机扫码' && ok "L the phone fallback is offered at once" || bad "L no fallback line: $out"
# L2 the newcomer's one-session view (solo, issue #2347): no fleet word before the first key
rm -f "$HOME/.ssh/fleet-cert-cert.pub" "$SB/opened"
start_hub
out="$(PATH="$SB/fakebin:$PATH" FLEET_LOGIN_BROWSER=1 FLEET_CLIENT_LAYOUT=solo python3 "$BIN/fleet-login.py" 2>&1 </dev/null)"; rc=$?
stop_hub
ALL_OUT="$ALL_OUT$out"
[ "$rc" = 0 ] && echo "$out" | grep -q '没看到？打开 http://127.0.0.1/fleet/login?code=BCDF-GHJK$' \
  && ! echo "$out" | grep -v '^⚠' | grep -Eq '扫码|只协调|入口' \
  && ok "L2 solo: the link only — 扫码 · 只协调 · 入口 never on the newcomer's screen" || bad "L2 rc=$rc: $out"

# ── M — no screen (ssh in), or --qr: the opener is never called, the QR is drawn ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub" "$SB/opened"
start_hub
out="$(PATH="$SB/fakebin:$PATH" SSH_CONNECTION="10.0.0.2 5000 10.0.0.1 22" FLEET_LOGIN_BROWSER=auto python3 "$BIN/fleet-login.py" 2>&1 </dev/null)"; rc=$?
stop_hub
ALL_OUT="$ALL_OUT$out"
[ "$rc" = 0 ] && [ ! -e "$SB/opened" ] && echo "$out" | grep -q '█\|▀\|▄' && echo "$out" | grep -q '链接：http://' \
  && ok "M over ssh: no browser, QR + link" || bad "M rc=$rc opened=$(cat "$SB/opened" 2>&1): $out"
rm -f "$HOME/.ssh/fleet-cert-cert.pub" "$SB/opened"
start_hub
out="$(PATH="$SB/fakebin:$PATH" FLEET_LOGIN_BROWSER=1 python3 "$BIN/fleet-login.py" --qr 2>&1 </dev/null)"; rc=$?
stop_hub
[ "$rc" = 0 ] && [ ! -e "$SB/opened" ] && echo "$out" | grep -q '█\|▀\|▄' \
  && ok "M --qr: no browser, QR" || bad "M --qr rc=$rc: $out"

# ── N — the browser will not open: say so, QR, still log in ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub" "$SB/opened"; echo 1 >"$SB/open.rc"
start_hub
out="$(PATH="$SB/fakebin:$PATH" FLEET_LOGIN_BROWSER=1 python3 "$BIN/fleet-login.py" 2>&1 </dev/null)"; rc=$?
stop_hub
rm -f "$SB/open.rc"
ALL_OUT="$ALL_OUT$out"
[ "$rc" = 0 ] && echo "$out" | grep -q '浏览器打不开' && echo "$out" | grep -q '█\|▀\|▄' && [ -s "$HOME/.ssh/fleet-cert-cert.pub" ] \
  && ok "N opener failed → said so, QR, certificate" || bad "N rc=$rc: $out"

# ── O — never a silent wait: a nudge every N seconds, a stop with the reason ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub"; touch "$SB/pending"
start_hub
out="$(PATH="$SB/fakebin:$PATH" FLEET_LOGIN_BROWSER=1 FLEET_LOGIN_NUDGE_SECS=1 FLEET_LOGIN_TIMEOUT_SECS=4 \
  python3 "$BIN/fleet-login.py" 2>&1 </dev/null)"; rc=$?
stop_hub
ALL_OUT="$ALL_OUT$out"
[ "$rc" = 1 ] && [ ! -e "$HOME/.ssh/fleet-cert-cert.pub" ] \
  && echo "$out" | grep -q '还在等浏览器里授权…（已等 [0-9]* 秒；按 q 改用二维码）' \
  && echo "$out" | grep -q '4 秒内浏览器里没有完成授权，已停下' && echo "$out" | grep -q 'fleet login --qr' \
  && ok "O nudges while waiting, stops with why + next step" || bad "O rc=$rc: $out"
start_hub
out="$(PATH="$SB/fakebin:$PATH" FLEET_LOGIN_BROWSER=0 FLEET_LOGIN_NUDGE_SECS=1 FLEET_LOGIN_TIMEOUT_SECS=3 \
  python3 "$BIN/fleet-login.py" 2>&1 </dev/null)"; rc=$?
stop_hub
[ "$rc" = 1 ] && echo "$out" | grep -q '还在等扫码确认' && echo "$out" | grep -q '3 秒内没有完成扫码确认' \
  && ok "O the QR wait nudges and stops too" || bad "O qr rc=$rc: $out"
grep -q '"FLEET_LOGIN_NUDGE_SECS", 15)' "$BIN/fleet-login.py" && grep -q '"FLEET_LOGIN_TIMEOUT_SECS", 120)' "$BIN/fleet-login.py" \
  && ok "O defaults: a nudge every 15 s, a stop at 2 minutes" || bad "O defaults changed"

# ── P — q on a real terminal switches to the QR ──
start_hub
out="$(PATH="$SB/fakebin:$PATH" FLEET_LOGIN_BROWSER=1 FLEET_LOGIN_TIMEOUT_SECS=4 python3 - "$BIN/fleet-login.py" <<'PTY' 2>&1
import os, pty, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("python3", ["python3", sys.argv[1]])
buf, sent, end = b"", False, time.time() + 15
while time.time() < end:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if not sent and "或按 q".encode() in buf:
        time.sleep(0.3); os.write(fd, b"q"); sent = True
os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
PTY
)"
stop_hub
rm -f "$SB/pending"
ALL_OUT="$ALL_OUT$out"
echo "$out" | grep -q '已在浏览器里打开' && echo "$out" | grep -q '█\|▀\|▄' && echo "$out" | grep -q '用手机扫码' \
  && ok "P q while waiting → the QR is drawn" || bad "P: $out"

# ── Q — an old identity's token does not outlive the hub (#2262) ──
rm -f "$HOME/.ssh/fleet-cert-cert.pub"
printf '{"token": "dead-tok", "keep": 1}\n' >"$HOME/.config/claude-fleet/hub.json"
start_hub
out="$(python3 "$BIN/fleet-login.py" 2>&1 </dev/null)"; rc=$?
stop_hub
ALL_OUT="$ALL_OUT$out"
[ "$rc" = 0 ] && ! grep -q 'dead-tok' "$HOME/.config/claude-fleet/hub.json" && grep -q '"keep": 1' "$HOME/.config/claude-fleet/hub.json" \
  && echo "$out" | grep -q '清掉了本机一个入口已不认的旧令牌' && ! echo "$out" | grep -q 'dead-tok' \
  && ok "Q a dead hub.json token is removed before the scan (other keys kept, value never printed)" || bad "Q rc=$rc hub.json=$(cat "$HOME/.config/claude-fleet/hub.json"): $out"
printf '{"token": "live-tok"}\n' >"$HOME/.config/claude-fleet/hub.json"
start_hub
python3 "$BIN/fleet-login.py" >/dev/null 2>&1 </dev/null
stop_hub
grep -q 'live-tok' "$HOME/.config/claude-fleet/hub.json" && ok "Q a token the hub accepts is kept" || bad "Q live token dropped"
rm -f "$HOME/.ssh/fleet-cert-cert.pub" "$HOME/.ssh/fleet-cert" "$HOME/.ssh/fleet-cert.pub"
printf '{"token": "dead-tok"}\n' >"$HOME/.config/claude-fleet/hub.json"
start_hub
python3 "$BIN/fleet-connect.py" --hub "http://127.0.0.1:$PORT" --pick >"$SB/pick.out" 2>"$SB/pick.err" </dev/null; rc=$?
stop_hub
ALL_OUT="$ALL_OUT$(cat "$SB/pick.err")"
[ ! -e "$HOME/.config/claude-fleet/hub.json" ] && [ -s "$HOME/.ssh/fleet-cert-cert.pub" ] && grep -q '清掉了本机一个入口已不认的旧令牌' "$SB/pick.err" \
  && ok "Q fleet --pick with a dead token: dropped, this person logged in" || bad "Q pick rc=$rc stderr=[$(cat "$SB/pick.err")]"

# ── W — no output says 企业微信 ──
echo "$ALL_OUT" | grep -q '企业微信' && bad "W some output says 企业微信" || ok "W no output says 企业微信"

[ "$fail" = 0 ] && echo "PASS fleet-login-selftest" || echo "FAIL fleet-login-selftest"
exit "$fail"
