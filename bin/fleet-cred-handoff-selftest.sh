#!/usr/bin/env bash
# fleet-cred-handoff-selftest.sh — the shared credential proxy restarts without a
# moment of nobody listening (T595). bin/fleet-cred-proxy.py `serve --shared`
# in a sandbox (one tenant: this login), a fake upstream on loopback, and a
# client pounding its port and a login's old port the whole time:
#
#   A  three starts with FLEET_CRED_HANDOFF=1 (the machine daemon's, passed on by
#      bin/fleet-credsep-launch.py) while requests run: every one answered — not
#      one ECONNREFUSED, reset or error; a slow request in flight at a handoff
#      finishes on the copy that took it
#   B  after them: one proxy left, its pid in <run>/pid, the control socket the
#      same one (never unlinked), each old copy logged `handoff` then `drained`
#   C  an old proxy that cannot hand over (no handoff.sock — a release before
#      T595): the new start stops it as a stale one and serves (the old road)
#   D  without FLEET_CRED_HANDOFF an identical proxy is «already running» (exit 0),
#      as before
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/cred-handoff-st.XXXXXX")
fails=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
cleanup() {
  for p in $(pgrep -f "serve --shared $SB/tenants.json" 2>/dev/null) $(cat "$SB/up.pid" 2>/dev/null); do
    { kill "$p"; wait "$p"; } 2>/dev/null
  done
  rm -rf "$SB"
}
trap cleanup EXIT
mkdir -p "$SB/st" "$SB/run" "$SB/tst"

python3 - "$SB" <<'PY' & echo $! > "$SB/up.pid"
import sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        time.sleep(float(self.headers.get("x-delay", "0") or 0))
        b = b'{"ok":true}'
        self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + "/up.port.tmp", "w").write(str(s.server_address[1]))
import os; os.replace(sys.argv[1] + "/up.port.tmp", sys.argv[1] + "/up.port")
s.serve_forever()
PY
i=0; while [ ! -s "$SB/up.port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done

PORTS=$(python3 -c 'import socket
ps = []
for _ in range(2):
    s = socket.socket(); s.bind(("127.0.0.1", 0)); ps.append(s.getsockname()[1]); s.close()
print(" ".join(map(str, ps)))')
set -- $PORTS
PORT=$1 LEGACY=$2
python3 - "$SB" "$PORT" "$LEGACY" <<'PY'
import json, os, sys
sb, port, legacy = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
json.dump({"state": sb + "/st", "run": sb + "/run", "user": "", "version": "v1", "port": port,
           "tenants": [{"login": os.environ.get("USER") or "me", "uid": os.getuid(), "state": sb + "/tst",
                        "accounts": sb + "/acc", "codex_auth": sb + "/ca.json", "codex_homes": sb + "/ch",
                        "node_env": sb + "/node.env", "log": sb + "/t.log", "legacy_port": legacy,
                        "settings": {}}]}, open(sb + "/tenants.json", "w"))
PY

FLEET_CRED_ANTHROPIC_URL="http://127.0.0.1:$(cat "$SB/up.port")"
export FLEET_CRED_SHARED_TEST=1 FLEET_CREDSEP_TEST=1 FLEET_CRED_BUDGET=0 FLEET_CRED_ANTHROPIC_URL \
  FLEET_CRED_PROXY_LOG="$SB/shared.log" FLEET_CRED_DRAIN_IDLE_SECS=3
unset FLEET_CRED_HANDOFF
serve() { python3 -I "$BIN/fleet-cred-proxy.py" serve --shared "$SB/tenants.json"; }
up() {  # <not this pid>: until <run>/pid names another live proxy that answers
  local i=0
  while [ "$i" -lt 100 ]; do
    p=$(cat "$SB/run/pid" 2>/dev/null)
    if [ -n "$p" ] && [ "$p" != "${1:-}" ] && kill -0 "$p" 2>/dev/null \
       && curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/hello"; then
      echo "$p"; return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

serve 2>"$SB/a.err" &
P0=$(up) || { fail "the first proxy never came up: $(cat "$SB/a.err")"; exit 1; }
CTL_INO=$(ls -i "$SB/run/ctl.sock" | awk '{print $1}')

# ── A: handoffs under load ───────────────────────────────────────────────────
python3 - "$PORT" "$LEGACY" 14 > "$SB/load.json" <<'PY' &
import collections, http.client, json, sys, threading, time
ports, secs = [int(sys.argv[1]), int(sys.argv[2])], float(sys.argv[3])
errs, ok, lk, end = collections.Counter(), collections.Counter(), threading.Lock(), time.time() + secs
def go(kind, port):
    c = None
    while time.time() < end:
        try:
            if c is None:
                c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            c.request("GET", "/api/hello", headers={"x-delay": "2"} if kind == "slow" else {})
            r = c.getresponse(); r.read()
            if kind != "keep" or (r.getheader("connection") or "").lower() == "close":
                c.close(); c = None
            with lk: ok[kind] += 1
        except Exception as e:
            with lk: errs["%s %s: %s" % (kind, type(e).__name__, str(e)[:60])] += 1
            c = None
        time.sleep(0.02)
ts = [threading.Thread(target=go, args=(k, p)) for p in ports for k, n in
      (("fresh", 3), ("keep", 2), ("slow", 2)) for _ in range(n)]
for t in ts: t.start()
for t in ts: t.join()
print(json.dumps({"ok": dict(ok), "errors": dict(errs)}))
PY
LOAD=$!
PREV=$P0 OLD=""
for n in 1 2 3; do
  sleep 3
  FLEET_CRED_HANDOFF=1 serve 2>"$SB/b$n.err" &
  NEW=$(up "$PREV") || { fail "A start $n never took over: $(cat "$SB/b$n.err")"; break; }
  OLD="$OLD $PREV"; PREV=$NEW
done
wait "$LOAD"
res=$(cat "$SB/load.json")
case "$res" in
  *'"errors": {}'*) pass "A 3 handoffs under load: every request answered, none refused ($res)" ;;
  *) fail "A requests failed across a handoff: $res" ;;
esac
case "$res" in *'"slow": '[1-9]*) pass "A slow requests in flight at a handoff finished" ;;
  *) fail "A no slow request finished: $res" ;; esac
n=$(grep -c "socket(s) handed over" "$SB"/b[123].err 2>/dev/null | awk -F: '{s += $2} END {print s + 0}')
[ "$n" = 3 ] && pass "A each start took the sockets over (handoff, not a stop)" || fail "A handed over $n/3: $(cat "$SB"/b*.err)"

# ── B: one proxy left, the same control socket, the old ones drained ─────────
i=0; while [ "$i" -lt 100 ]; do
  alive=0; for p in $OLD; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
  [ "$alive" = 0 ] && break; sleep 0.1; i=$((i + 1))
done
[ "$alive" = 0 ] && pass "B every old copy drained and went" || fail "B $alive old copies still run"
[ "$(cat "$SB/run/pid")" = "$PREV" ] && kill -0 "$PREV" 2>/dev/null && pass "B <run>/pid is the last copy ($PREV)" \
  || fail "B <run>/pid $(cat "$SB/run/pid") (want $PREV)"
[ "$(ls -i "$SB/run/ctl.sock" | awk '{print $1}')" = "$CTL_INO" ] && pass "B the control socket is the same one (never unlinked)" \
  || fail "B ctl.sock was replaced"
h=$(grep -c '"ev": "handoff"' "$SB/shared.log"); d=$(grep -c '"ev": "drained"' "$SB/shared.log")
[ "$h" = 3 ] && [ "$d" = 3 ] && pass "B 3 handoff + 3 drained in the log" || fail "B log: handoff $h drained $d"

# ── C: an old proxy that cannot hand over is stopped, the new one serves ────
rm -f "$SB/st/handoff.sock"
FLEET_CRED_HANDOFF=1 serve 2>"$SB/c.err" &
NEW=$(up "$PREV") && ! kill -0 "$PREV" 2>/dev/null && grep -q "taking over" "$SB/c.err" \
  && pass "C no handoff.sock: the old copy stopped, the new one serves (the old road)" \
  || fail "C fallback: $(cat "$SB/c.err")"
PREV=${NEW:-$PREV}

# ── D: without the switch an identical proxy is «already running» ──────────
serve 2>"$SB/d.err"; rc=$?
[ "$rc" = 0 ] && grep -q "already running" "$SB/d.err" && kill -0 "$PREV" 2>/dev/null \
  && pass "D no FLEET_CRED_HANDOFF: «already running», the serving one untouched" \
  || fail "D rc=$rc $(cat "$SB/d.err")"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
