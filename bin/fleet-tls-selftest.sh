#!/bin/bash
# fleet-tls-selftest.sh — the ONE TLS context every hub-facing python uses
# (issue #2878): bin/fleet_tls.py, fleet-connect.py --tls-check (the doctor's
# `tls` row), fleet-login.py's verify-failure words, the install line's python.
# A throwaway CA + a 127.0.0.1 HTTPS server stand in for the hub; every CA road
# but the one under test is switched off (FLEET_TLS_SYSTEM_ROOTS / _CERTIFI /
# _DEFAULTS = 0, SSL_CERT_FILE / SSL_CERT_DIR empty), so the machine's own store
# never makes a case pass.
#
#   A. a bundle    FLEET_CA_BUNDLE=<ca> → check PASS, sources names it, and
#                  install() makes a bare urllib.request.urlopen verify with it
#   B. no road     every source off → check FAIL (exit 1), the text names this
#                  python, 「CA 来源」 and 修法; hint() says it for a verify error
#                  and '' for any other error
#   C. the row     fleet-connect.py --tls-check: PASS with the bundle, FAIL with
#                  none, rc 3 + nothing with no hub (no row)
#   D. login       fleet-login.py against the stand-in hub with no road dies
#                  「验不了入口的证书 … 修法」, not 「查网络」
#   E. wiring      every hub-facing script imports fleet_tls; the client manifest
#                  ships it; `fleet` puts $FLEET_CONF_DIR/pybin first on PATH; the
#                  install line records the python there
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$BIN/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-tls-st.XXXXXX")
SRV_PID=''
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; fails=$((fails + 1)); }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "want «$2» in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1" "did not want «$2» in: $3" ;; *) ok "$1" ;; esac; }

command -v openssl >/dev/null 2>&1 || { echo "SKIP no openssl"; exit 0; }

# --- a CA and a leaf for 127.0.0.1 ------------------------------------------
cd "$WORK" || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj '/CN=fleet-tls-st CA' >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj '/CN=127.0.0.1' >/dev/null 2>&1
printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\n' > leaf.ext
openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 -extfile leaf.ext >/dev/null 2>&1
[ -s leaf.pem ] || { echo "FAIL could not make a test certificate"; exit 1; }
: > empty.pem; mkdir -p emptydir home

cat > srv.py <<'PY'
import http.server, ssl, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    do_POST = do_GET
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("leaf.pem", "leaf.key")
s.socket = c.wrap_socket(s.socket, server_side=True)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
python3 srv.py > port.txt 2>/dev/null &
SRV_PID=$!
disown "$SRV_PID" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s port.txt ] && break; sleep 0.3; done
PORT=$(cat port.txt)
[ -n "$PORT" ] || { echo "FAIL the test server did not start"; exit 1; }
HUB="https://127.0.0.1:$PORT"

# every road off; a case turns one back on
noroads() {
  env -u FLEET_HUB_URL -u FLEET_CA_BUNDLE -u FLEET_CERT HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" XDG_CACHE_HOME="$WORK/home/.cache" \
      FLEET_CONF_DIR="$WORK/home/.config/claude-fleet" \
      FLEET_TLS_SYSTEM_ROOTS=0 FLEET_TLS_CERTIFI=0 FLEET_TLS_DEFAULTS=0 \
      SSL_CERT_FILE="$WORK/empty.pem" SSL_CERT_DIR="$WORK/emptydir" "$@"
}

# --- A. a bundle --------------------------------------------------------------
out=$(noroads FLEET_CA_BUNDLE="$WORK/ca.pem" python3 "$BIN/fleet_tls.py" check "$HUB"); rc=$?
[ $rc = 0 ] && ok "A: check exit 0 with the bundle" || bad "A: check exit 0 with the bundle" "rc=$rc $out"
has "A: PASS" "PASS	" "$out"
has "A: sources names the bundle" "FLEET_CA_BUNDLE=" "$(noroads FLEET_CA_BUNDLE="$WORK/ca.pem" python3 "$BIN/fleet_tls.py" sources)"
out=$(cd "$BIN" && noroads FLEET_CA_BUNDLE="$WORK/ca.pem" python3 -c '
import sys, urllib.request, fleet_tls
fleet_tls.install()
print(urllib.request.urlopen(sys.argv[1] + "/x", timeout=5).status)' "$HUB" 2>&1)
has "A: install() → a bare urlopen verifies" "200" "$out"

# --- B. no road -----------------------------------------------------------------
out=$(noroads python3 "$BIN/fleet_tls.py" check "$HUB"); rc=$?
[ $rc = 1 ] && ok "B: check exit 1 with no road" || bad "B: check exit 1 with no road" "rc=$rc $out"
has "B: FAIL" "FAIL	" "$out"
has "B: names the python" "python " "$out"
has "B: names the sources" "CA 来源" "$out"
has "B: says the fix" "修法" "$out"
out=$(cd "$BIN" && noroads python3 -c '
import sys, urllib.request, urllib.error, fleet_tls
fleet_tls.install()
try:
    urllib.request.urlopen(sys.argv[1] + "/x", timeout=5); print("no error")
except urllib.error.URLError as e:
    print("hint:", fleet_tls.hint(e))
print("other:[%s]" % fleet_tls.hint(OSError("connection refused")))' "$HUB" 2>&1)
has "B: hint() on a verify error" "hint: 这台电脑的 python3 验不了入口的证书" "$out"
has "B: hint() is empty for any other error" "other:[]" "$out"

# --- C. the doctor's row ----------------------------------------------------------
out=$(noroads FLEET_CA_BUNDLE="$WORK/ca.pem" FLEET_HUB_URL="$HUB" python3 "$BIN/fleet-connect.py" --tls-check)
has "C: --tls-check PASS" "PASS	127.0.0.1" "$out"
out=$(noroads FLEET_HUB_URL="$HUB" python3 "$BIN/fleet-connect.py" --tls-check)
has "C: --tls-check FAIL" "FAIL	127.0.0.1" "$out"
out=$(noroads python3 "$BIN/fleet-connect.py" --tls-check); rc=$?
[ $rc = 3 ] && [ -z "$out" ] && ok "C: no hub → rc 3, no row" || bad "C: no hub → rc 3, no row" "rc=$rc out=$out"
has "C: fleet-doctor.sh has the row" "pass tls" "$(cat "$BIN/fleet-doctor.sh")"
has "C: the client's doctor has the row" '--tls-check' "$(cat "$BIN/fleet")"

# --- D. fleet login's words -----------------------------------------------------------
if command -v ssh-keygen >/dev/null 2>&1; then
  out=$(noroads python3 "$BIN/fleet-login.py" --hub "$HUB" </dev/null 2>&1)
  has "D: login names the verify failure" "验不了入口的证书" "$out"
  has "D: login says the fix" "修法" "$out"
  hasnt "D: not the network words" "查网络" "$out"
else
  echo "skip D: no ssh-keygen"
fi

# --- E. wiring ------------------------------------------------------------------------
for f in fleet-login.py fleet-connect.py fleet-hub-admin.py fleet-client-lease.py fleet-client-actions.py \
         fleet-agent-team.py fleet-cred-scan.py fleet-cred-proxy.py; do
  grep -q 'fleet_tls.install()' "$BIN/$f" && ok "E: $f installs fleet_tls" || bad "E: $f installs fleet_tls"
done
grep -qx 'bin/fleet_tls.py' "$ROOT/tokenledger/internal/api/fleetclient/manifest" \
  && ok "E: the client manifest ships fleet_tls.py" || bad "E: the client manifest ships fleet_tls.py"
has "E: fleet puts pybin first" 'claude-fleet}/pybin"' "$(cat "$BIN/fleet")"
has "E: the install line records the python" '$CONF/pybin/python3' "$(cat "$BIN/fleet-install.sh")"
# the launcher's PATH, for real: a pybin python3 that says who it is
mkdir -p "$WORK/home/.config/claude-fleet/pybin"
printf '#!/bin/sh\necho pybin-python\n' > "$WORK/home/.config/claude-fleet/pybin/python3"
chmod +x "$WORK/home/.config/claude-fleet/pybin/python3"
out=$(sed -n '/^_fp=/,/^unset _fp/p' "$BIN/fleet" | env HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" \
      FLEET_CONF_DIR= sh -c '. /dev/stdin; python3')
has "E: \$FLEET_CONF_DIR/pybin/python3 is the python3 under fleet" "pybin-python" "$out"

echo
if [ "$fails" -gt 0 ]; then echo "fleet-tls-selftest: $fails FAILED"; exit 1; fi
echo "fleet-tls-selftest: all passed"
