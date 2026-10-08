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
#      reason as it is), DECLINED 5, UNKNOWN 6 once FLEET_CLIENT_PLACE_WAIT runs out;
#      (issue #1610) the machines the hub tried first: one stderr line each, and
#      the `after …` field kept on the line a status poll ends with; ALL_DECLINED 4;
#      (issue #2480) a placement that left THIS computer out: why, per login here,
#      in a person's words (compute off → fleet host on, tmux down → fleet up),
#      on stderr or to FLEET_PLACE_WHY; one with no placement adds nothing
#   C. a wrong key / a lease the hub no longer holds → 401 → exit 1, one stderr line
#   D. degenerate — no hub and no fleet on this computer: the one line
#      「这台电脑没有 fleet，也连不上入口」, exit 1, nothing asked
#   E. usage: a bad kind / repo is exit 2
#   F. a lease the hub no longer holds (issue #2464, e.g. a hub just redeployed):
#      401 not your client → released + acquired once (FLEET_CLIENT_LEASE_CMD, a
#      fake), `lease re-acquired once` on stderr, asked again → done; a second 401
#      → exit 1 with the hub's words; an acquire that fails → exit 1, words + hint
#   G. attachments (issue #2393, EPIC #2482 C1): --attach sends each file's bytes
#      (base64, name, from, sha256) with a new start — the hub receives exactly the
#      file; one over 10 MB stays behind and is said (stderr, the line's tail, the
#      body beside its path); a hub that answers no `attached` (older) is said too
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'fleet-client-place selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcp-st.XXXXXX")" || exit 2
mkdir -p "$WORK/tmp"; export TMPDIR="$WORK/tmp"   # the client cache (fleet_logins, #2430) stays in the sandbox
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
export FLEET_CLIENT_DIR="$WORK/cl"; mkdir -p "$FLEET_CLIENT_DIR"
export FLEET_CLIENT_KEY_FILE="$FLEET_CLIENT_DIR/client.key"
unset FLEET_HUB_URL FLEET_HUB_TOKEN CCQUOTA_FLEET TMUX TMUX_PANE
LEASE=abcdef0123456789abcdef01
KEY=0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f
UUID=11111111-1111-4111-8111-111111111111
NEW=0123456789abcdef01234567

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

LEASE, KEY, UUID, LOG, PORTF, CURF, SELF = sys.argv[1:8]
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
        cur = LEASE
        if os.path.exists(CURF):   # the lease the hub holds now (leg F)
            with open(CURF) as f:
                cur = f.read().strip()
        if env.get("lease") != cur or not hmac.compare_digest(mac, env.get("mac", "")):
            return self.answer(401, {"error": {"code": "UNAUTHENTICATED", "message":
                                     "not your client: the lease is not held (asked to leave, disconnected or lapsed) or the action key does not check"}})
        p = json.loads(env["payload"])
        with open(LOG, "a") as f:
            f.write(json.dumps(p, ensure_ascii=False, sort_keys=True) + "\n")
        if p.get("action") == "status":
            op = p["operation_id"]
            polls[op] = polls.get(op, 0) + 1
            if op == "op14":   # the machine tried second (issue #1610): its own line, no tail
                return self.answer(200, {"line": "REMOTE m3 op14 done %s/issue-14\tchose m3" % UUID, "exit": 0, "state": "done"})
            if op == "op7":
                return self.answer(200, {"line": "REMOTE m5 op7 done %s/issue-7\tm4 excluded: full" % UUID, "exit": 0, "state": "done"})
            return self.answer(200, {"line": "UNKNOWN m5 %s\tstill starting" % op, "exit": 6, "state": "pending", "operation_id": op})
        kind, issue = p.get("kind"), p.get("issue")
        if kind == "new":   # leg G: an older hub answers no `attached`
            out = {"line": "REMOTE m4 op20 done %s/issue-20\tchose m4" % UUID, "exit": 0, "state": "done"}
            if p.get("title") != "old hub":
                out["attached"] = len(p.get("attachments") or [])
            return self.answer(200, out)
        if kind == "scratch":
            # an older hub (no `login`): the chosen candidate's os_user says it (#2430)
            return self.answer(200, {"line": "REMOTE m5 op1 done %s/scratch-3\tm4 excluded: load 1.00/core > 0.8" % UUID, "exit": 0, "state": "done",
                                     "placement": {"fleet_id": UUID, "candidates": [{"fleet_id": "other", "os_user": "verkyyi"},
                                                                                   {"fleet_id": UUID, "os_user": "verky"}]}})
        if kind == "restore":
            return self.answer(200, {"line": "REMOTE m4 op3 done %s/%s\tits /fleet-history row is on m4" % (UUID, p["key"]), "exit": 0, "state": "done",
                                     "login": "bob", "worker_id": "%s/%s" % (UUID, p["key"])})
        table = {
            7: {"line": "UNKNOWN m5 op7\tstarting", "exit": 6, "state": "pending", "operation_id": "op7"},
            9: {"line": "HELD m4\t#9 is leased to m4", "exit": 3, "state": "held"},
            11: {"line": "REFUSED AT_CAPACITY\tall-full: every machine is at its session cap — m5: at cap 8/8; m4: at cap 4/4", "exit": 4, "state": "refused"},
            12: {"line": "DECLINED m4 op12 2\tfleet-m4 is full", "exit": 5, "state": "refused"},
            13: {"line": "UNKNOWN m5 op13\tstarting", "exit": 6, "state": "pending", "operation_id": "op13"},
            14: {"line": "UNKNOWN m3 op14\tstarting\tafter mini2:op140:1", "exit": 6, "state": "pending", "operation_id": "op14",
                 "attempts": [{"machine": "mini2", "operation_id": "op140", "state": "failed", "exit": 1,
                               "why": "fleet discover: fork/exec fleet-control.py: invalid argument"}]},
            15: {"line": "REFUSED ALL_DECLINED\tevery machine that could take it said no — mini2: declined: fork; m3: declined: full\tafter mini2:op150:1,m3:op151:2",
                 "exit": 4, "state": "refused",
                 "attempts": [{"machine": "mini2", "operation_id": "op150", "exit": 1, "why": "fork"},
                              {"machine": "m3", "operation_id": "op151", "exit": 2, "why": "full"}]},
            # issue #2480: THIS computer only coordinates, its other login's fleet is down
            16: {"line": "DECLINED m4 op16 1\tfleet discover: INTERNAL: Local controller failed", "exit": 5, "state": "failed",
                 "placement": {"machine": "m4", "reason": "chose m4 (score 0.556); %s excluded: compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)" % SELF,
                               "candidates": [{"machine": "m4", "os_user": "bob", "eligible": True},
                                              {"machine": SELF, "os_user": "verky", "eligible": False,
                                               "excluded": "compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)"},
                                              {"machine": SELF, "os_user": "verky", "eligible": False, "excluded": "tmux 服务没在跑"},
                                              {"machine": SELF.upper() + ".local", "os_user": "alice", "eligible": False,
                                               "excluded": "compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)"}]}},
            # ... and one whose candidates do not hold this computer at all
            17: {"line": "REFUSED NO_ELIGIBLE_NODE\tm4 excluded: full", "exit": 4, "state": "refused",
                 "placement": {"reason": "m4 excluded: full",
                               "candidates": [{"machine": "m4", "os_user": "bob", "eligible": False, "excluded": "full"}]}},
        }
        return self.answer(200, table[issue])


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORTF + ".tmp", "w") as f:
    f.write(str(srv.server_port))
os.replace(PORTF + ".tmp", PORTF)
srv.serve_forever()
PY
SELF=$(python3 -c 'import socket; print((socket.gethostname() or "").split(".")[0].lower())')
python3 "$WORK/hub.py" "$LEASE" "$KEY" "$UUID" "$WORK/log" "$WORK/port" "$WORK/curlease" "$SELF" 2>"$WORK/hub.err" &
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
# the lease tool (fleet-client-lease.py) faked: logs its argv; acquire answers the
# lease in $WORK/next (and writes the action key, as save_key does), or fails
# when there is none
cat > "$WORK/lease" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK/lease.log"
[ "$1" = acquire ] || { printf 'released\t%s\t\t\t\n' "$3"; exit 0; }
[ -s "$WORK/next" ] || exit 1
printf '%s\n' "$FAKE_KEY" > "$FLEET_CLIENT_KEY_FILE"
printf 'active\t%s\tm4\t\t\n' "$(cat "$WORK/next")"
SH
chmod +x "$WORK/lease"
export WORK FAKE_KEY="$KEY" FLEET_CLIENT_LEASE_CMD="$WORK/lease"
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
# issue #2430: the login it landed under is remembered against its fleet
eq "A: scratch login remembered (candidate os_user)" "$UUID	verky" "$(tail -n1 "$TMPDIR/.claude-dash/global/fleet_logins" 2>/dev/null)"

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
eq "A: restore login remembered (the hub's login)" "$UUID	bob" "$(tail -n1 "$TMPDIR/.claude-dash/global/fleet_logins" 2>/dev/null)"

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

# issue #1610: the hub tried the next machine — each decline on stderr, the
# first answer's `after …` field kept on the line a status poll ends with
run "$P" verkyyi/claude-fleet 14
eq "B: next machine exit" 0 "$RC"
eq "B: next machine line keeps who declined first" "REMOTE m3 op14 done $UUID/issue-14	chose m3	after mini2:op140:1" "$OUT"
has "B: next machine stderr names the decline" "$ERR" "mini2 declined (exit 1): fleet discover: fork/exec fleet-control.py: invalid argument"
run "$P" verkyyi/claude-fleet 15
eq "B: all declined exit" 4 "$RC"
has "B: all declined line" "$OUT" "REFUSED ALL_DECLINED	every machine that could take it said no — mini2: declined: fork; m3: declined: full	after mini2:op150:1,m3:op151:2"
has "B: all declined stderr, one per machine" "$ERR" "m3 declined (exit 2): full"

# issue #2480: why THIS computer was not chosen — after the line, in a person's words
USER=verky run "$P" verkyyi/claude-fleet 16
eq "B: self declined exit" 5 "$RC"
eq "B: self declined line as it was" "DECLINED m4 op16 1	fleet discover: INTERNAL: Local controller failed" "$OUT"
has "B: self — this login's compute off, and how to open it" "$ERR" "fleet-client-place: 你这台（${SELF}/verky）没被选：compute off（只协调）——在这台运行 fleet host on 打开"
has "B: self — the policy named too" "$ERR" "fleet.compute_auto"
has "B: self — both reasons of this login on one line" "$ERR" "；这台 fleet 的 tmux 服务没在跑——在这台运行 fleet up 拉起"
has "B: self — another login here, by its name" "$ERR" "这台的另一个登录（${SELF}/alice）没被选：compute off"
has "B: self — another login's fix is run as that login" "$ERR" "以 alice 登录在这台运行 fleet host on"
case "$ERR" in *m4*没被选*) fail "B: self — a hint about another machine" "$ERR" ;; esac
WHY="$WORK/why"; : > "$WHY"
USER=verky FLEET_PLACE_WHY="$WHY" run "$P" verkyyi/claude-fleet 16
case "$ERR" in *没被选*) fail "B: self — on stderr though FLEET_PLACE_WHY was set" "$ERR" ;; esac
has "B: self — written to FLEET_PLACE_WHY" "$(head -n1 "$WHY")" "你这台（${SELF}/verky）没被选：compute off"
eq "B: self — one line per login" 2 "$(wc -l < "$WHY" | tr -d ' ')"
run "$P" verkyyi/claude-fleet 17
eq "B: self absent exit" 4 "$RC"
has "B: self absent — said so" "$ERR" "你这台（${SELF}）不在入口的候选里"
run "$P" verkyyi/claude-fleet 12
case "$ERR" in *没被选*|*候选*) fail "B: no placement — a self hint anyway" "$ERR" ;; esac

# --- C. a key that does not check (and no lease to take again) ---------------------------
printf '%s\n' "$(printf '%s' "$KEY" | tr 0f f0)" > "$FLEET_CLIENT_KEY_FILE"
run "$P" verkyyi/claude-fleet scratch
eq "C: wrong key exit" 1 "$RC"; eq "C: wrong key stdout" "" "$OUT"
has "C: wrong key says 401" "$ERR" "HTTP 401"
printf '%s\n' "$KEY" > "$FLEET_CLIENT_KEY_FILE"
printf 'ffffffffffffffffffffffff\n' > "$FLEET_CLIENT_DIR/client.lease"
run "$P" verkyyi/claude-fleet scratch
eq "C: taken-over lease exit" 1 "$RC"

# --- F. the hub no longer holds our lease: take it again once (issue #2464) ---------------
printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"
printf '%s\n' "$NEW" > "$WORK/curlease"; printf '%s\n' "$NEW" > "$WORK/next"; : > "$WORK/lease.log"
printf '{"device": "iPhone"}\n' > "$FLEET_CLIENT_DIR/client.where.json"
run "$P" verkyyi/claude-fleet scratch
eq "F: re-acquired exit" 0 "$RC"
has "F: re-acquired line" "$OUT" "REMOTE m5 op1 done $UUID/scratch-3"
has "F: re-acquired said" "$ERR" "fleet-client-place: lease re-acquired once"
has "F: the old lease released" "$(cat "$WORK/lease.log")" "release --lease $LEASE"
has "F: acquired on the same device" "$(tail -n1 "$WORK/lease.log")" "acquire --where-file $FLEET_CLIENT_DIR/client.where.json"
eq "F: the new lease kept" "$NEW" "$(cat "$FLEET_CLIENT_DIR/client.lease")"
# the new lease asked nothing again: one acquire, one release
eq "F: one release + one acquire" 2 "$(wc -l < "$WORK/lease.log" | tr -d ' ')"
# a second 401: exit 1, the hub's words on stderr, no third ask
printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"
printf 'eeeeeeeeeeeeeeeeeeeeeeee\n' > "$WORK/next"; : > "$WORK/lease.log"
run "$P" verkyyi/claude-fleet scratch
eq "F: twice 401 exit" 1 "$RC"; eq "F: twice 401 stdout" "" "$OUT"
has "F: twice 401 re-acquired once" "$ERR" "lease re-acquired once"
has "F: twice 401 words" "$ERR" "HTTP 401: not your client: the lease is not held"
eq "F: twice 401 one acquire" 1 "$(grep -c '^acquire' "$WORK/lease.log")"
# an acquire that fails: exit 1, the 401's words and what to do
printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"; : > "$WORK/next"
run "$P" verkyyi/claude-fleet scratch
eq "F: acquire failed exit" 1 "$RC"
has "F: acquire failed words" "$ERR" "HTTP 401: not your client"
has "F: acquire failed hint" "$ERR" "restart the client"
rm -f "$WORK/curlease"

# --- G. attachments go with the start (issue #2393) -----------------------------------------
printf '\211PNG the error in the screenshot' > "$WORK/shot 1.png"
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"x" * (10 * 1024 * 1024 + 1))' "$WORK/big.bin"
printf '看这张 %s\n\n附件:\n- %s\n- %s' "$WORK/shot 1.png" "$WORK/shot 1.png" "$WORK/big.bin" > "$WORK/body"
run "$P" verkyyi/claude-fleet new --title '看这张' --body-file "$WORK/body" --attach "$WORK/shot 1.png" --attach "$WORK/big.bin"
eq "G: attach exit" 0 "$RC"
eq "G: the hub received the file's bytes" "ok" "$(lastreq | python3 -c '
import base64, hashlib, json, sys
p = json.loads(sys.stdin.read()); a = p.get("attachments") or []
want = open(sys.argv[1], "rb").read()
print("ok" if len(a) == 1 and base64.b64decode(a[0]["data"]) == want and a[0]["name"] == "shot 1.png"
      and a[0]["from"] == sys.argv[1] and a[0]["sha256"] == hashlib.sha256(want).hexdigest() else a)' "$WORK/shot 1.png")"
has "G: the big one is said on the line" "$OUT" "	附件没带过去：big.bin（超过 10 MB）"
has "G: … and on stderr" "$ERR" "附件没带过去：big.bin（超过 10 MB）"
has "G: … and beside its path in the body" "$(lastreq)" "big.bin（附件没带过去：超过 10 MB）"
run "$P" verkyyi/claude-fleet new --title 'old hub' --attach "$WORK/shot 1.png"
eq "G: older hub exit" 0 "$RC"
has "G: an older hub's start says the file did not go" "$OUT" "附件没带过去：shot 1.png（入口还不收附件"
run "$P" verkyyi/claude-fleet 7 --attach "$WORK/shot 1.png";  eq "G: --attach on an issue start" 2 "$RC"

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
