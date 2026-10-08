#!/bin/bash
# fleet-client-place-selftest.sh — open a session from the client (issue #1777,
# EPIC #1776 C1): bin/fleet-client-place.sh against a FAKE hub.
#
# The fake hub is a python HTTP server on 127.0.0.1 (an ephemeral port, dies
# with the test) that answers POST /v1/fleet/client/place the way the real one
# does: 401 unless the payload's HMAC checks under the lease's action key and
# the lease is the current one; then a canned answer per request. The client's
# lease id and key are files in a sandbox FLEET_CLIENT_DIR, as fleet-shell.sh
# keeps them; FLEET_HUB_TOKEN stands in for the connection certificate.
#   A. the three kinds — scratch, issue (pending once, then done through a status
#      poll), restore:<key> — each prints the hub's line, exit 0; the payload
#      carried repo / kind / node / title, the issue number and the key
#   B. the refusals keep fleet_hub_place's codes: HELD 3, REFUSED 4 (the hub's
#      reason as it is), DECLINED 5, UNKNOWN 6 once FLEET_CLIENT_PLACE_WAIT runs out
#   C. a wrong key / a lease the hub no longer holds → 401 → exit 1, one stderr line
#   D. degenerate — no hub and no fleet on this computer: the one line
#      「这台电脑没有 fleet，也连不上入口」, exit 1, nothing asked
#   E. usage: a bad kind / repo is exit 2
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-place selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcp-st.XXXXXX")" || exit 2
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_CLIENT_DIR="$WORK/cl"; mkdir -p "$FLEET_CLIENT_DIR"
export FLEET_CLIENT_KEY_FILE="$FLEET_CLIENT_DIR/client.key"
unset FLEET_HUB_URL FLEET_HUB_TOKEN CCQUOTA_FLEET TMUX TMUX_PANE
LEASE=abcdef0123456789abcdef01
KEY=0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f
UUID=11111111-1111-4111-8111-111111111111

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 (want '$2')" "$3"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 (want '$3')" "$2" ;; esac; }
HUBPID=''
cleanup() { [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# --- the fake hub -------------------------------------------------------------------
cat > "$WORK/hub.py" <<'PY'
import hashlib, hmac, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LEASE, KEY, UUID, LOG, PORTF = sys.argv[1:6]
polls = {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def answer(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        env = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        if self.path != "/v1/fleet/client/place" or self.headers.get("Authorization") != "Bearer tok":
            return self.answer(404, {})
        mac = hmac.new(KEY.encode(), env.get("payload", "").encode(), hashlib.sha256).hexdigest()
        if env.get("lease") != LEASE or not hmac.compare_digest(mac, env.get("mac", "")):
            return self.answer(401, {"error": {"code": "UNAUTHENTICATED", "message": "not your current client"}})
        p = json.loads(env["payload"])
        with open(LOG, "a") as f:
            f.write(json.dumps(p, ensure_ascii=False, sort_keys=True) + "\n")
        if p.get("action") == "status":
            op = p["operation_id"]
            polls[op] = polls.get(op, 0) + 1
            if op == "op7":
                return self.answer(200, {"line": "REMOTE m5 op7 done %s/issue-7\tm4 excluded: full" % UUID, "exit": 0, "state": "done"})
            return self.answer(200, {"line": "UNKNOWN m5 %s\tstill starting" % op, "exit": 6, "state": "pending", "operation_id": op})
        kind, issue = p.get("kind"), p.get("issue")
        if kind == "scratch":
            return self.answer(200, {"line": "REMOTE m5 op1 done %s/scratch-3\tm4 excluded: load 1.00/core > 0.8" % UUID, "exit": 0, "state": "done"})
        if kind == "restore":
            return self.answer(200, {"line": "REMOTE m4 op3 done %s/%s\tits /fleet-history row is on m4" % (UUID, p["key"]), "exit": 0, "state": "done"})
        table = {
            7: {"line": "UNKNOWN m5 op7\tstarting", "exit": 6, "state": "pending", "operation_id": "op7"},
            9: {"line": "HELD m4\t#9 is leased to m4", "exit": 3, "state": "held"},
            11: {"line": "REFUSED AT_CAPACITY\tall-full: every machine is at its session cap — m5: at cap 8/8; m4: at cap 4/4", "exit": 4, "state": "refused"},
            12: {"line": "DECLINED m4 op12 2\tfleet-m4 is full", "exit": 5, "state": "refused"},
            13: {"line": "UNKNOWN m5 op13\tstarting", "exit": 6, "state": "pending", "operation_id": "op13"},
        }
        return self.answer(200, table[issue])


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTF + ".tmp", "w") as f:
    f.write(str(srv.server_port))
os.replace(PORTF + ".tmp", PORTF)
srv.serve_forever()
PY
python3 "$WORK/hub.py" "$LEASE" "$KEY" "$UUID" "$WORK/log" "$WORK/port" 2>"$WORK/hub.err" &
HUBPID=$!
# a cold python on a CI runner can take seconds to bind
for _ in $(seq 300); do
  [ -s "$WORK/port" ] && break
  kill -0 "$HUBPID" 2>/dev/null || break
  sleep 0.1
done
[ -s "$WORK/port" ] || { printf 'FAIL: the fake hub did not start\n' >&2; cat "$WORK/hub.err" >&2 2>/dev/null; exit 1; }
HUB="http://127.0.0.1:$(cat "$WORK/port")"

P="$BIN/fleet-client-place.sh"
run() { OUT=$("$@" 2>"$WORK/err"); RC=$?; ERR=$(cat "$WORK/err"); }
lastreq() { tail -n1 "$WORK/log"; }

# --- D. degenerate first: no hub, no fleet ------------------------------------------
run "$P" verkyyi/claude-fleet scratch
eq "D: no hub + no fleet exit" 1 "$RC"
eq "D: no hub + no fleet stdout" "" "$OUT"
eq "D: no hub + no fleet line" "这台电脑没有 fleet，也连不上入口" "$ERR"
# a hub but no lease to sign with: the same (nothing asked)
FLEET_HUB_URL=$HUB FLEET_HUB_TOKEN=tok run "$P" verkyyi/claude-fleet scratch
eq "D: no lease exit" 1 "$RC"
[ -f "$WORK/log" ] && fail "D: a request went out without a lease" "$(cat "$WORK/log")"

printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"
printf '%s\n' "$KEY" > "$FLEET_CLIENT_KEY_FILE"
export FLEET_HUB_URL=$HUB FLEET_HUB_TOKEN=tok

# --- A. the three kinds ---------------------------------------------------------------
run "$P" verkyyi/claude-fleet scratch --node auto --title '看看日志'
eq "A: scratch exit" 0 "$RC"
eq "A: scratch line" "REMOTE m5 op1 done $UUID/scratch-3	m4 excluded: load 1.00/core > 0.8" "$OUT"
has "A: scratch payload kind" "$(lastreq)" '"kind": "scratch"'
has "A: scratch payload node" "$(lastreq)" '"node": "auto"'
has "A: scratch payload title" "$(lastreq)" '"title": "看看日志"'
has "A: scratch payload repo" "$(lastreq)" '"repo": "verkyyi/claude-fleet"'

# `fleet codex` (issue #2403): a HOME session carries its agent to the hub
run "$P" - home --agent codex
eq "A: home exit" 0 "$RC"
has "A: home payload no_repo" "$(lastreq)" '"no_repo": true'
has "A: home payload agent" "$(lastreq)" '"agent": "codex"'

run "$P" verkyyi/claude-fleet 7 --node m5 --agent codex
eq "A: issue exit (after one status poll)" 0 "$RC"
eq "A: issue line" "REMOTE m5 op7 done $UUID/issue-7	m4 excluded: full" "$OUT"
has "A: issue polled its operation" "$(lastreq)" '"operation_id": "op7"'
has "A: issue payload" "$(tail -n2 "$WORK/log" | head -n1)" '"issue": 7'
has "A: issue payload node" "$(tail -n2 "$WORK/log" | head -n1)" '"node": "m5"'
has "A: issue payload agent" "$(tail -n2 "$WORK/log" | head -n1)" '"agent": "codex"'

run "$P" verkyyi/claude-fleet restore:issue-21
eq "A: restore exit" 0 "$RC"
eq "A: restore line" "REMOTE m4 op3 done $UUID/issue-21	its /fleet-history row is on m4" "$OUT"
has "A: restore payload" "$(lastreq)" '"key": "issue-21"'
has "A: restore payload kind" "$(lastreq)" '"kind": "restore"'

# --- B. refusals keep their codes -----------------------------------------------------
run "$P" verkyyi/claude-fleet issue-9
eq "B: held exit" 3 "$RC"; eq "B: held line" "HELD m4	#9 is leased to m4" "$OUT"
run "$P" verkyyi/claude-fleet 11
eq "B: all full exit" 4 "$RC"
has "B: all full reasons as the hub said" "$OUT" "m5: at cap 8/8; m4: at cap 4/4"
run "$P" verkyyi/claude-fleet 12
eq "B: declined exit" 5 "$RC"; eq "B: declined line" "DECLINED m4 op12 2	fleet-m4 is full" "$OUT"
FLEET_CLIENT_PLACE_WAIT=2 run "$P" verkyyi/claude-fleet 13
eq "B: unknown exit" 6 "$RC"; has "B: unknown line" "$OUT" "UNKNOWN m5 op13"

# --- C. a key that does not check -------------------------------------------------------
printf '%s\n' "$(printf '%s' "$KEY" | tr 0f f0)" > "$FLEET_CLIENT_KEY_FILE"
run "$P" verkyyi/claude-fleet scratch
eq "C: wrong key exit" 1 "$RC"; eq "C: wrong key stdout" "" "$OUT"
has "C: wrong key says 401" "$ERR" "HTTP 401"
printf '%s\n' "$KEY" > "$FLEET_CLIENT_KEY_FILE"
printf 'ffffffffffffffffffffffff\n' > "$FLEET_CLIENT_DIR/client.lease"
run "$P" verkyyi/claude-fleet scratch
eq "C: taken-over lease exit" 1 "$RC"

# --- E. usage -----------------------------------------------------------------------------
run "$P" verkyyi/claude-fleet bogus;  eq "E: bad kind" 2 "$RC"
run "$P" claude-fleet scratch;        eq "E: bad repo" 2 "$RC"
run "$P" verkyyi/claude-fleet;        eq "E: no kind" 2 "$RC"

if [ "$FAIL" -eq 0 ]; then
  printf 'fleet-client-place selftest: PASS (%d checks)\n' "$CHECKS"
  exit 0
fi
printf 'fleet-client-place selftest: %d FAIL of %d\n' "$FAIL" "$CHECKS" >&2
exit 1
