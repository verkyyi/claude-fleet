#!/bin/bash
# fleet-managed-cert-selftest.sh — docs/dev/BREAK-IT.md row `managed-cert-lapses-idle`
# (issue #4594): a login a managed node took over is the ops service's to keep,
# its connection certificate included, and nobody on it is ever asked to run
# `fleet login`. Hermetic: a sandbox HOME, a fake hub on 127.0.0.1 that signs
# with a REAL throwaway CA and refuses a device idle past seven days (its clock
# is the device's last use, kept in a file).
#
#   A. the idle node: certificate expired, device last used 6 days 23 hours ago —
#      the diskguard tick's step (managed_cert_watch → bin/fleet-login.py keep)
#      renews by the device key, why=keep, and the hub's last use moves to now
#   D. a device already idle past seven days: keep exits 3, the tick raises ONE
#      breakage alert in the ops service's words (not again on the next tick),
#      and no output — keep, renew, status, the doctor's cert row —
#      tells the person to run `fleet login`
#   E. not managed: the tick's step does nothing, asks nothing
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
SB="$(mktemp -d "${TMPDIR:-/tmp}/fleet-managed-cert.XXXXXX")"
HUB_PID=""
cleanup() { [ -n "$HUB_PID" ] && { kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null; }; rm -rf "$SB"; }
trap cleanup EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
command -v ssh-keygen >/dev/null || { echo "skip: no ssh-keygen"; exit 0; }
ssh-keygen -q -t ed25519 -N '' -C fleet-ca -f "$SB/ca" || exit 1

cat >"$SB/hub.py" <<'PY'
import json, os, subprocess, sys, tempfile, time
from http.server import BaseHTTPRequestHandler, HTTPServer
SB = sys.argv[1]
USED = os.path.join(SB, "last_used")          # the device's last use (epoch)
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path != "/v1/fleet/login/renew":
            return self.reply(404, {})
        with open(os.path.join(SB, "renews"), "a") as f:
            f.write("renew\n")
        if time.time() - float(open(USED).read()) > 7 * 86400:
            return self.reply(403, {"error": "this device has not been used for 7 days — scan to sign in again", "code": "device_idle"})
        d = tempfile.mkdtemp(dir=SB)
        open(os.path.join(d, "k.pub"), "w").write(body["public_key"] + "\n")
        subprocess.run(["ssh-keygen", "-q", "-s", os.path.join(SB, "ca"), "-I", "gh:Alice", "-n", "alice",
                        "-V", "-1m:+12h", "-z", "2", os.path.join(d, "k.pub")], check=True)
        open(USED, "w").write(str(time.time()))
        self.reply(200, {"certificate": open(os.path.join(d, "k-cert.pub")).read(), "serial": "2", "key_id": "gh:Alice",
                         "principals": ["alice"], "valid_before": "", "ssh_config": "# fleet-ssh-config v1\n", "hub": ""})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(SB, "port"), "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 "$SB/hub.py" "$SB" & HUB_PID=$!
for _ in $(seq 300); do [ -s "$SB/port" ] && break; sleep 0.1; done
[ -s "$SB/port" ] || { echo "FAIL fake hub never started"; exit 1; }
HUB="http://127.0.0.1:$(cat "$SB/port")"

export HOME="$SB/home" XDG_CONFIG_HOME="$SB/home/.config" FLEET_CONF_DIR="$SB/conf" FLEET_HUB_URL="$HUB" \
  FLEET_NODE_STATE="$SB/state" FLEET_INSTALL_LOGIN=alice FLEET_CLIENT_LOG_DIR="$SB/clog"
unset FLEET_CERT CCQUOTA_VIEWER_TOKEN CCQUOTA_HUB_URL
mkdir -p "$HOME/.ssh" "$FLEET_CONF_DIR/diskguard" "$SB/state" "$SB/shim"
printf '{"alice": {"managed": true}}\n' > "$SB/state/accounts.json"
# the device registered a while ago: its key, and a certificate that already ran out
ssh-keygen -q -t ed25519 -N '' -C fleet -f "$HOME/.ssh/fleet-cert"
ssh-keygen -q -s "$SB/ca" -I gh:Alice -n alice -V 20260101000000:20260101120000 -z 1 "$HOME/.ssh/fleet-cert.pub"
LAST="$FLEET_CONF_DIR/cert-renew.last"
ALL=""

# the diskguard tick's step, alone: the function body as the tick runs it, on
# this login (fleet-daemon-lib.sh's fleet_node_manages), alerts into a shim
cat > "$SB/shim/fleet-alerts.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$SB/alerts"
EOF
chmod +x "$SB/shim/fleet-alerts.sh"
tick() {
  rm -f "$FLEET_CONF_DIR/diskguard/last-managed-cert"
  FLEET_MANAGED_CERT_ALERT_CMD="$SB/shim/fleet-alerts.sh" bash -c '
    BIN=$1; GDIR=$2
    . "$BIN/fleet-daemon-lib.sh"; . "$BIN/fleet-lib.sh" 2>/dev/null
    now() { date +%s; }; tmo() { shift; "$@"; }
    eval "$(awk "/^managed_cert_watch\(\) \{/{p=1} p{print} p&&/^}/{exit}" "$BIN/fleet-diskguard.sh")"
    managed_cert_watch' _ "$BIN" "$FLEET_CONF_DIR/diskguard"
  [ "$1" = 0 ] && return 0
  for _ in $(seq 100); do [ -s "$FLEET_CONF_DIR/diskguard/managed-cert.log" ] && [ "$(wc -l < "$FLEET_CONF_DIR/diskguard/managed-cert.log")" -ge "$1" ] && break; sleep 0.1; done
  sleep 0.3
}

# ── A — six days and 23 hours idle, certificate expired: the tick renews ──
python3 -c 'import time; print(time.time() - 6 * 86400 - 23 * 3600)' > "$SB/last_used"
tick 1
read -r _ urc uwhy < "$LAST" 2>/dev/null
left=$(python3 "$BIN/fleet-login.py" check 2>/dev/null)
if [ "${urc:-}" = 0 ] && [ "${uwhy:-}" = keep ] && case "$left" in "valid "*) true ;; *) false ;; esac; then
  ok "A the idle node's tick renewed by the device key (why=keep, $left)"
else bad "A tick: last=$(cat "$LAST" 2>/dev/null) check=$left log=$(cat "$FLEET_CONF_DIR/diskguard/managed-cert.log" 2>/dev/null)"; fi
used=$(cat "$SB/last_used"); python3 -c 'import sys,time; sys.exit(0 if time.time() - float(sys.argv[1]) < 60 else 1)' "$used" \
  && ok "A the hub's last use moved to now: the 7-day window starts again" || bad "A last use still $used"
[ ! -e "$SB/alerts" ] && ok "A no alert" || bad "A alerted: $(cat "$SB/alerts")"

# ── D — the device already lapsed: an ops alert, never a scan for the person ──
python3 -c 'import time; print(time.time() - 8 * 86400)' > "$SB/last_used"
ssh-keygen -q -s "$SB/ca" -I gh:Alice -n alice -V 20260101000000:20260101120000 -z 1 "$HOME/.ssh/fleet-cert.pub"
tick 2
tick 3
grep -q 'rc=3 keep: ops' "$FLEET_CONF_DIR/diskguard/managed-cert.log" && ok "D keep exits 3 (the device key cannot renew)" \
  || bad "D log: $(cat "$FLEET_CONF_DIR/diskguard/managed-cert.log")"
[ "$(grep -c . "$SB/alerts" 2>/dev/null)" = 1 ] && grep -q 'event .*breakage .*ops service .*nobody on this login is asked to log in' "$SB/alerts" \
  && ok "D ONE breakage alert per streak, in the ops service's words" || bad "D alerts: $(cat "$SB/alerts" 2>/dev/null)"
ALL="$ALL$(python3 "$BIN/fleet-login.py" keep 2>&1)$(python3 "$BIN/fleet-login.py" renew 2>&1)$(python3 "$BIN/fleet-login.py" status 2>&1)"
ALL="$ALL$(python3 "$BIN/fleet-connect.py" --cert-check 2>&1)"
rm -f "$HOME/.ssh/fleet-cert-cert.pub"
ALL="$ALL$(python3 "$BIN/fleet-login.py" status 2>&1)"
# «fleet login: » is the program naming itself; any other mention is an instruction
TOLD=$(printf '%s' "$ALL" | sed 's/fleet login: //g' | grep 'fleet login')
if [ -n "$TOLD" ]; then bad "D a managed login was told to run fleet login: $(printf '%s' "$TOLD" | head -3)"
else ok "D nothing — keep, renew, status, the cert row — tells the person to run fleet login"; fi
printf '%s' "$ALL" | grep -q '运维' && ok "D they say the ops service has it" || bad "D no ops word: $ALL"

# ── E — not managed: the step does nothing ──
printf '{}\n' > "$SB/state/accounts.json"; : > "$SB/renews"; rm -f "$SB/alerts"
rm -f "$FLEET_CONF_DIR/diskguard/managed-cert.log"
tick 0; sleep 0.5
[ ! -s "$SB/renews" ] && [ ! -e "$FLEET_CONF_DIR/diskguard/managed-cert.log" ] && [ ! -e "$SB/alerts" ] \
  && ok "E not managed: no renewal, no log line, no alert" || bad "E renews=$(cat "$SB/renews") log=$(cat "$FLEET_CONF_DIR/diskguard/managed-cert.log" 2>/dev/null)"

[ "$fail" = 0 ] && echo "PASS fleet-managed-cert-selftest" || echo "FAIL fleet-managed-cert-selftest"
exit "$fail"
