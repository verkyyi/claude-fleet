#!/bin/bash
# fleet-client-place-selftest.sh — open a session from the client (issue #1777,
# EPIC #1776 C1): bin/fleet-client-place.sh against a FAKE hub.
#
# The fake hub is a python HTTP server on 127.0.0.1 (an ephemeral port, dies
# with the test) that answers POST /v1/fleet/client/place the way the real one
# does: 401 unless the payload's HMAC checks under the lease's action key and
# the lease is the current one; then a canned answer per request. The client's
# lease id and key are files in a sandbox FLEET_CLIENT_DIR, as the client
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
#   H. back to the last home session (issue #2564): `- home` carries home=true,
#      `--new` new=true; a RESUME answer is printed as it is, exit 0, and
#      FLEET_PLACE_RESULT holds {worker_id, machine, resume, also_open}; --new
#      on anything but home is exit 2
#   I. no hub, a fleet here (issue #3097 — a 看台's ⌘T): the node's own adapter
#      (fleet-control-read.sh, faked) opens it — `LOCAL <host>` + its first line —
#      and FLEET_PLACE_RESULT names the window it opened (a cold spawn's last
#      `@N`, a warm start's receipt) with the issue filed and this machine, so
#      the 看台 goes to it; a declined start writes none and keeps the
#      adapter's last stderr line (the spawn's own reason) on the line
# python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcp-st.XXXXXX")" || exit 2
mkdir -p "$WORK/tmp"; export TMPDIR="$WORK/tmp"   # the client cache (fleet_logins, #2430) stays in the sandbox
export HOME="$WORK/home"; mkdir -p "$HOME/.config/claude-fleet"
export XDG_CONFIG_HOME="$HOME/.config" FLEET_CONF_DIR="$HOME/.config/claude-fleet"
mkdir -p "$FLEET_CONF_DIR"
: > "$FLEET_CONF_DIR/home-session.first"
export FLEET_CLIENT_DIR="$WORK/cl"; mkdir -p "$FLEET_CLIENT_DIR"
export FLEET_CLIENT_KEY_FILE="$FLEET_CLIENT_DIR/client.key"
unset FLEET_HUB_URL FLEET_HUB_TOKEN CCQUOTA_FLEET TMUX TMUX_PANE
LEASE=abcdef0123456789abcdef01
KEY=0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f
UUID=11111111-1111-4111-8111-111111111111
NEW=0123456789abcdef01234567

st_tally count miss
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

    def do_GET(self):
        if self.path == "/v1/fleet/client-settings":
            try:
                with open(os.path.join(os.path.dirname(LOG), "team-default")) as f:
                    agent = f.read().strip()
            except OSError:
                agent = ""
            return self.answer(200, {"settings": {"FLEET_AGENT": agent}})
        return self.answer(404, {})

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
                return self.answer(200, {"line": "REMOTE mac-b op7 done %s/issue-7\tmac-a excluded: full" % UUID, "exit": 0, "state": "done"})
            return self.answer(200, {"line": "UNKNOWN mac-b %s\tstill starting" % op, "exit": 6, "state": "pending", "operation_id": op})
        kind, issue = p.get("kind"), p.get("issue")
        if p.get("action") == "models":   # leg M (task J7BN): no file = a hub older than it
            try:
                with open(os.path.join(os.path.dirname(LOG), "models")) as f:
                    return self.answer(200, {"models": f.read().split()})
            except OSError:
                return self.answer(400, {"error": "action must be place, draft or status"})
        if p.get("action") == "draft" and p.get("name") == "old-hub":
            return self.answer(400, {"error": "action must be place or status"})
        if p.get("task"):   # leg T: the hub wrote the record first (issue #3325)
            return self.answer(200, {"line": "REMOTE mac-a op30 done %s/scratch-9\tchose mac-a" % UUID, "exit": 0, "state": "done",
                                     "worker_id": "%s/scratch-9" % UUID, "machine": "mac-a", "task": "T218"})
        if kind == "new":   # leg G: an older hub answers no `attached`
            out = {"line": "REMOTE mac-a op20 done %s/issue-20\tchose mac-a" % UUID, "exit": 0, "state": "done"}
            if p.get("title") != "old hub":
                out["attached"] = len(p.get("attachments") or [])
            return self.answer(200, out)
        if kind == "scratch" and p.get("home") and not p.get("new") and p.get("agent") == "claude":
            # leg H: the person's current home session (issue #2564)
            return self.answer(200, {"line": "RESUME mac-a %s/scratch-1\t回到你上一次的会话（mac-a）" % UUID, "exit": 0, "state": "resume",
                                     "machine": "mac-a", "worker_id": "%s/scratch-1" % UUID, "login": "erin",
                                     "also_open": ["MacBook"]})
        if kind == "scratch":
            # an older hub (no `login`): the chosen candidate's os_user says it (#2430)
            return self.answer(200, {"line": "REMOTE mac-b op1 done %s/scratch-3\tmac-a excluded: load 1.00/core > 0.8" % UUID, "exit": 0, "state": "done",
                                     "placement": {"fleet_id": UUID, "candidates": [{"fleet_id": "other", "os_user": "frank"},
                                                                                   {"fleet_id": UUID, "os_user": "erin"}]}})
        if kind == "restore":
            return self.answer(200, {"line": "REMOTE mac-a op3 done %s/%s\tits /fleet-history row is on mac-a" % (UUID, p["key"]), "exit": 0, "state": "done",
                                     "login": "bob", "worker_id": "%s/%s" % (UUID, p["key"])})
        table = {
            7: {"line": "UNKNOWN mac-b op7\tstarting", "exit": 6, "state": "pending", "operation_id": "op7"},
            9: {"line": "HELD mac-a\t#9 is leased to mac-a", "exit": 3, "state": "held"},
            11: {"line": "REFUSED AT_CAPACITY\tall-full: every machine is at its session cap — mac-b: at cap 8/8; mac-a: at cap 4/4", "exit": 4, "state": "refused"},
            12: {"line": "DECLINED mac-a op12 2\tfleet-mac-a is full", "exit": 5, "state": "refused"},
            13: {"line": "UNKNOWN mac-b op13\tstarting", "exit": 6, "state": "pending", "operation_id": "op13"},
            14: {"line": "UNKNOWN m3 op14\tstarting\tafter mac-d:op140:1", "exit": 6, "state": "pending", "operation_id": "op14",
                 "attempts": [{"machine": "mac-d", "operation_id": "op140", "state": "failed", "exit": 1,
                               "why": "fleet discover: fork/exec fleet-control.py: invalid argument"}]},
            15: {"line": "REFUSED ALL_DECLINED\tevery machine that could take it said no — mac-d: declined: fork; m3: declined: full\tafter mac-d:op150:1,m3:op151:2",
                 "exit": 4, "state": "refused",
                 "attempts": [{"machine": "mac-d", "operation_id": "op150", "exit": 1, "why": "fork"},
                              {"machine": "m3", "operation_id": "op151", "exit": 2, "why": "full"}]},
            # issue #2480: THIS computer only coordinates, its other login's fleet is down
            16: {"line": "DECLINED mac-a op16 1\tfleet discover: INTERNAL: Local controller failed", "exit": 5, "state": "failed",
                 "placement": {"machine": "mac-a", "reason": "chose mac-a (score 0.556); %s excluded: compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)" % SELF,
                               "candidates": [{"machine": "mac-a", "os_user": "bob", "eligible": True},
                                              {"machine": SELF, "os_user": "erin", "eligible": False,
                                               "excluded": "compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)"},
                                              {"machine": SELF, "os_user": "erin", "eligible": False, "excluded": "tmux 服务没在跑"},
                                              {"machine": SELF.upper() + ".local", "os_user": "alice", "eligible": False,
                                               "excluded": "compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)"}]}},
            # ... and one whose candidates do not hold this computer at all
            17: {"line": "REFUSED NO_ELIGIBLE_NODE\tmac-a excluded: full", "exit": 4, "state": "refused",
                 "placement": {"reason": "mac-a excluded: full",
                               "candidates": [{"machine": "mac-a", "os_user": "bob", "eligible": False, "excluded": "full"}]}},
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
printf 'active\t%s\tmac-a\t\t\n' "$(cat "$WORK/next")"
SH
chmod +x "$WORK/lease"
export WORK FAKE_KEY="$KEY" FLEET_CLIENT_LEASE_CMD="$WORK/lease"
run() { OUT=$("$@" 2>"$WORK/err"); RC=$?; ERR=$(cat "$WORK/err"); }
lastreq() { tail -n1 "$WORK/log"; }

# --- D. degenerate first: no hub, no fleet ------------------------------------------
run "$P" verkyyi/claude-fleet scratch
st_eq "D: no hub + no fleet exit" 1 "$RC"
st_eq "D: no hub + no fleet stdout" "" "$OUT"
st_eq "D: no hub + no fleet line" "这台电脑没有 fleet，也连不上入口" "$ERR"
# a hub but no lease to sign with: the same (nothing asked)
FLEET_HUB_URL=$HUB FLEET_HUB_TOKEN=tok run "$P" verkyyi/claude-fleet scratch
st_eq "D: no lease exit" 1 "$RC"
[ -f "$WORK/log" ] && st_miss "D: a request went out without a lease" "$(cat "$WORK/log")"

printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"
printf '%s\n' "$KEY" > "$FLEET_CLIENT_KEY_FILE"
export FLEET_HUB_URL=$HUB FLEET_HUB_TOKEN=tok

# --- A. the three kinds ---------------------------------------------------------------
run "$P" verkyyi/claude-fleet scratch --node auto --title '看看日志'
st_eq "A: scratch exit" 0 "$RC"
st_eq "A: scratch line" "REMOTE mac-b op1 done $UUID/scratch-3	mac-a excluded: load 1.00/core > 0.8" "$OUT"
st_has "A: scratch payload kind" "$(lastreq)" '"kind": "scratch"'
st_has "A: scratch payload node" "$(lastreq)" '"node": "auto"'
st_has "A: scratch payload title" "$(lastreq)" '"title": "看看日志"'
st_has "A: scratch payload repo" "$(lastreq)" '"repo": "verkyyi/claude-fleet"'
# issue #2430: the login it landed under is remembered against its fleet
st_eq "A: scratch login remembered (candidate os_user)" "$UUID	erin" "$(tail -n1 "$TMPDIR/.claude-dash/global/fleet_logins" 2>/dev/null)"

# An omitted agent follows the shared default; local and explicit choices win.
printf '%s\n' codex > "$WORK/team-default"
run "$P" verkyyi/claude-fleet scratch
st_has "A: omitted agent uses team default" "$(lastreq)" '"resolved_agent": "codex"'
st_has "A: team default is not an explicit choice" "$(lastreq)" '"agent_source": "fleet"'
FLEET_AGENT=claude run "$P" verkyyi/claude-fleet scratch
st_has "A: local default overrides team" "$(lastreq)" '"resolved_agent": "claude"'
run "$P" verkyyi/claude-fleet scratch --agent claude
st_has "A: explicit choice overrides team" "$(lastreq)" '"agent_source": "explicit"'
rm -f "$WORK/team-default"
run "$P" verkyyi/claude-fleet scratch
st_has "A: clearing team default restores legacy choice" "$(lastreq)" '"resolved_agent": "claude"'

# `fleet codex` (issue #2403): a HOME session carries its agent to the hub
run "$P" - home --agent codex
st_eq "A: home exit" 0 "$RC"
st_has "A: home payload no_repo" "$(lastreq)" '"no_repo": true'
st_has "A: home payload agent" "$(lastreq)" '"agent": "codex"'

# --- H. back to the last home session (issue #2564) -------------------------------------
st_has "H: home payload home" "$(lastreq)" '"home": true'
case "$(lastreq)" in *'"new"'*) st_miss "H: a plain home carried new" "$(lastreq)" ;; esac
FLEET_PLACE_RESULT="$WORK/res.json" run "$P" - home --agent claude
st_eq "H: RESUME exit" 0 "$RC"
st_eq "H: RESUME line" "RESUME mac-a $UUID/scratch-1	回到你上一次的会话（mac-a）" "$OUT"
st_eq "H: RESUME result" "{\"machine\": \"mac-a\", \"worker_id\": \"$UUID/scratch-1\", \"resume\": true, \"also_open\": [\"MacBook\"]}" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k: d[k] for k in ("machine","worker_id","resume","also_open")}, ensure_ascii=False))' "$WORK/res.json" 2>/dev/null)"
run "$P" - home --agent claude --new
st_eq "H: --new exit (a new one)" 0 "$RC"
st_has "H: --new line" "$OUT" "REMOTE mac-b op1 done"
st_has "H: --new payload" "$(lastreq)" '"new": true'
run "$P" - scratch --new
st_eq "H: --new on a scratch: exit 2" 2 "$RC"

run "$P" verkyyi/claude-fleet 7 --node mac-b --agent codex
st_eq "A: issue exit (after one status poll)" 0 "$RC"
st_eq "A: issue line" "REMOTE mac-b op7 done $UUID/issue-7	mac-a excluded: full" "$OUT"
st_has "A: issue polled its operation" "$(lastreq)" '"operation_id": "op7"'
st_has "A: issue payload" "$(tail -n2 "$WORK/log" | head -n1)" '"issue": 7'
st_has "A: issue payload node" "$(tail -n2 "$WORK/log" | head -n1)" '"node": "mac-b"'
st_has "A: issue payload agent" "$(tail -n2 "$WORK/log" | head -n1)" '"agent": "codex"'

run "$P" verkyyi/claude-fleet restore:issue-21
st_eq "A: restore exit" 0 "$RC"
st_eq "A: restore line" "REMOTE mac-a op3 done $UUID/issue-21	its /fleet-history row is on mac-a" "$OUT"
st_has "A: restore payload" "$(lastreq)" '"key": "issue-21"'
st_has "A: restore payload kind" "$(lastreq)" '"kind": "restore"'
st_eq "A: restore login remembered (the hub's login)" "$UUID	bob" "$(tail -n1 "$TMPDIR/.claude-dash/global/fleet_logins" 2>/dev/null)"

# --- B. refusals keep their codes -----------------------------------------------------
printf '完整文字 #42 %s' "$(printf 'literal %.0s' {1..40})" > "$WORK/draft.txt"
run "$P" verkyyi/claude-fleet scratch --name short --draft-file "$WORK/draft.txt"
st_eq "draft: placement succeeds" 0 "$RC"
st_has "draft: old hubs must reject the new action" "$(lastreq)" '"action": "draft"'
python3 - "$WORK/log" "$WORK/draft.txt" <<'PY' || st_miss "draft text was truncated or became a submitted seed"
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[-1])
assert request['draft'] == pathlib.Path(sys.argv[2]).read_text()
assert not any(field in request for field in ('body', 'task', 'attachments'))
PY
run "$P" verkyyi/claude-fleet scratch --name old-hub --draft-file "$WORK/draft.txt"
st_eq "draft: old hub refusal is not silently downgraded" 1 "$RC"
run "$P" verkyyi/claude-fleet scratch --draft-file "$WORK/draft.txt" --body-file "$WORK/draft.txt"
st_eq "draft: ambiguous seed rejected before placement" 2 "$RC"

run "$P" verkyyi/claude-fleet issue-9
st_eq "B: held exit" 3 "$RC"; st_eq "B: held line" "HELD mac-a	#9 is leased to mac-a" "$OUT"
run "$P" verkyyi/claude-fleet 11
st_eq "B: all full exit" 4 "$RC"
st_has "B: all full reasons as the hub said" "$OUT" "mac-b: at cap 8/8; mac-a: at cap 4/4"
run "$P" verkyyi/claude-fleet 12
st_eq "B: declined exit" 5 "$RC"; st_eq "B: declined line" "DECLINED mac-a op12 2	fleet-mac-a is full" "$OUT"
FLEET_CLIENT_PLACE_WAIT=2 run "$P" verkyyi/claude-fleet 13
st_eq "B: unknown exit" 6 "$RC"; st_has "B: unknown line" "$OUT" "UNKNOWN mac-b op13"

# issue #1610: the hub tried the next machine — each decline on stderr, the
# first answer's `after …` field kept on the line a status poll ends with
run "$P" verkyyi/claude-fleet 14
st_eq "B: next machine exit" 0 "$RC"
st_eq "B: next machine line keeps who declined first" "REMOTE m3 op14 done $UUID/issue-14	chose m3	after mac-d:op140:1" "$OUT"
st_has "B: next machine stderr names the decline" "$ERR" "mac-d declined (exit 1): fleet discover: fork/exec fleet-control.py: invalid argument"
run "$P" verkyyi/claude-fleet 15
st_eq "B: all declined exit" 4 "$RC"
st_has "B: all declined line" "$OUT" "REFUSED ALL_DECLINED	every machine that could take it said no — mac-d: declined: fork; m3: declined: full	after mac-d:op150:1,m3:op151:2"
st_has "B: all declined stderr, one per machine" "$ERR" "m3 declined (exit 2): full"

# issue #2480: why THIS computer was not chosen — after the line, in a person's words
USER=erin run "$P" verkyyi/claude-fleet 16
st_eq "B: self declined exit" 5 "$RC"
st_eq "B: self declined line as it was" "DECLINED mac-a op16 1	fleet discover: INTERNAL: Local controller failed" "$OUT"
st_has "B: self — this login's compute off, and how to open it" "$ERR" "fleet-client-place: 你这台（${SELF}/erin）没被选：compute off（只协调）——在这台运行 fleet host on 打开"
st_has "B: self — the policy named too" "$ERR" "fleet.compute_auto"
st_has "B: self — both reasons of this login on one line" "$ERR" "；这台 fleet 的 tmux 服务没在跑——在这台运行 fleet up 拉起"
st_has "B: self — another login here, by its name" "$ERR" "这台的另一个登录（${SELF}/alice）没被选：compute off"
st_has "B: self — another login's fix is run as that login" "$ERR" "以 alice 登录在这台运行 fleet host on"
case "$ERR" in *mac-a*没被选*) st_miss "B: self — a hint about another machine" "$ERR" ;; esac
WHY="$WORK/why"; : > "$WHY"
USER=erin FLEET_PLACE_WHY="$WHY" run "$P" verkyyi/claude-fleet 16
case "$ERR" in *没被选*) st_miss "B: self — on stderr though FLEET_PLACE_WHY was set" "$ERR" ;; esac
st_has "B: self — written to FLEET_PLACE_WHY" "$(head -n1 "$WHY")" "你这台（${SELF}/erin）没被选：compute off"
st_eq "B: self — one line per login" 2 "$(wc -l < "$WHY" | tr -d ' ')"
run "$P" verkyyi/claude-fleet 17
st_eq "B: self absent exit" 4 "$RC"
st_has "B: self absent — said so" "$ERR" "你这台（${SELF}）不在入口的候选里"
# … but not to a newcomer's client, nor beside this login's own place elsewhere
# (issue #2953): their sessions run on the login the hub opened, and the hint
# sent them after the wrong computer
rm -f "$FLEET_CONF_DIR/home-session.first"
run "$P" verkyyi/claude-fleet 17
: > "$FLEET_CONF_DIR/home-session.first"
case "$ERR" in *候选*) st_miss "B: self absent — said to a solo (newcomer) client" "$ERR" ;; esac
USER=bob run "$P" verkyyi/claude-fleet 17
case "$ERR" in *候选*) st_miss "B: self absent — said though this login is a candidate elsewhere" "$ERR" ;; esac
run "$P" verkyyi/claude-fleet 12
case "$ERR" in *没被选*|*候选*) st_miss "B: no placement — a self hint anyway" "$ERR" ;; esac

# --- C. a key that does not check (and no lease to take again) ---------------------------
printf '%s\n' "$(printf '%s' "$KEY" | tr 0f f0)" > "$FLEET_CLIENT_KEY_FILE"
run "$P" verkyyi/claude-fleet scratch
st_eq "C: wrong key exit" 1 "$RC"; st_eq "C: wrong key stdout" "" "$OUT"
st_has "C: wrong key says 401" "$ERR" "HTTP 401"
printf '%s\n' "$KEY" > "$FLEET_CLIENT_KEY_FILE"
printf 'ffffffffffffffffffffffff\n' > "$FLEET_CLIENT_DIR/client.lease"
run "$P" verkyyi/claude-fleet scratch
st_eq "C: taken-over lease exit" 1 "$RC"

# --- F. the hub no longer holds our lease: take it again once (issue #2464) ---------------
printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"
printf '%s\n' "$NEW" > "$WORK/curlease"; printf '%s\n' "$NEW" > "$WORK/next"; : > "$WORK/lease.log"
printf '{"device": "iPhone"}\n' > "$FLEET_CLIENT_DIR/client.where.json"
run "$P" verkyyi/claude-fleet scratch
st_eq "F: re-acquired exit" 0 "$RC"
st_has "F: re-acquired line" "$OUT" "REMOTE mac-b op1 done $UUID/scratch-3"
st_has "F: re-acquired said" "$ERR" "fleet-client-place: lease re-acquired once"
st_has "F: the old lease released" "$(cat "$WORK/lease.log")" "release --lease $LEASE"
st_has "F: acquired on the same device" "$(tail -n1 "$WORK/lease.log")" "acquire --where-file $FLEET_CLIENT_DIR/client.where.json"
st_eq "F: the new lease kept" "$NEW" "$(cat "$FLEET_CLIENT_DIR/client.lease")"
# the new lease asked nothing again: one acquire, one release
st_eq "F: one release + one acquire" 2 "$(wc -l < "$WORK/lease.log" | tr -d ' ')"
# a second 401: exit 1, the hub's words on stderr, no third ask
printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"
printf 'eeeeeeeeeeeeeeeeeeeeeeee\n' > "$WORK/next"; : > "$WORK/lease.log"
run "$P" verkyyi/claude-fleet scratch
st_eq "F: twice 401 exit" 1 "$RC"; st_eq "F: twice 401 stdout" "" "$OUT"
st_has "F: twice 401 re-acquired once" "$ERR" "lease re-acquired once"
st_has "F: twice 401 words" "$ERR" "HTTP 401: not your client: the lease is not held"
st_eq "F: twice 401 one acquire" 1 "$(grep -c '^acquire' "$WORK/lease.log")"
# an acquire that fails: exit 1, the 401's words and what to do
printf '%s\n' "$LEASE" > "$FLEET_CLIENT_DIR/client.lease"; : > "$WORK/next"
run "$P" verkyyi/claude-fleet scratch
st_eq "F: acquire failed exit" 1 "$RC"
st_has "F: acquire failed words" "$ERR" "HTTP 401: not your client"
st_has "F: acquire failed hint" "$ERR" "restart the client"
rm -f "$WORK/curlease"

# --- G. attachments go with the start (issue #2393) -----------------------------------------
printf '\211PNG the error in the screenshot' > "$WORK/shot 1.png"
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"x" * (10 * 1024 * 1024 + 1))' "$WORK/big.bin"
printf '看这张 %s\n\n附件:\n- %s\n- %s' "$WORK/shot 1.png" "$WORK/shot 1.png" "$WORK/big.bin" > "$WORK/body"
run "$P" verkyyi/claude-fleet new --title '看这张' --body-file "$WORK/body" --attach "$WORK/shot 1.png" --attach "$WORK/big.bin"
st_eq "G: attach exit" 0 "$RC"
st_eq "G: the hub received the file's bytes" "ok" "$(lastreq | python3 -c '
import base64, hashlib, json, sys
p = json.loads(sys.stdin.read()); a = p.get("attachments") or []
want = open(sys.argv[1], "rb").read()
print("ok" if len(a) == 1 and base64.b64decode(a[0]["data"]) == want and a[0]["name"] == "shot 1.png"
      and a[0]["from"] == sys.argv[1] and a[0]["sha256"] == hashlib.sha256(want).hexdigest() else a)' "$WORK/shot 1.png")"
st_has "G: the big one is said on the line" "$OUT" "	附件没带过去：big.bin（超过 10 MB）"
st_has "G: … and on stderr" "$ERR" "附件没带过去：big.bin（超过 10 MB）"
st_has "G: … and beside its path in the body" "$(lastreq)" "big.bin（附件没带过去：超过 10 MB）"
run "$P" verkyyi/claude-fleet new --title 'old hub' --attach "$WORK/shot 1.png"
st_eq "G: older hub exit" 0 "$RC"
st_has "G: an older hub's start says the file did not go" "$OUT" "附件没带过去：shot 1.png（入口还不收附件"
run "$P" verkyyi/claude-fleet 7 --attach "$WORK/shot 1.png";  st_eq "G: --attach on an issue start" 2 "$RC"

# --- I. no hub, a fleet here: the local road names its window (issue #3097) ----------
IB="$WORK/i-bin"; mkdir -p "$IB" "$FLEET_CONF_DIR/fleets/tf"
for f in "$BIN"/*; do ln -sf "$f" "$IB/"; done
rm -f "$IB/fleet-control-read.sh"
cat > "$IB/fleet-control-read.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$WORK/i-args"
case "${I_MODE:-cold}" in
  cold) printf 'https://github.com/acme/web/issues/42\n@17\n' ;;
  warm) printf 'warm\t@18\tacme-web·x\t/w\tF1\t1\t2\t3\n' ;;
  scratch) printf '@19\tfull draft title\t/work tree\tF1\t1\t2\t3\n' ;;
  no)   printf 'dash-issue-session: #42 should run in Codex, but …\n' >&2
        printf 'start: filed #42 but its session did not open (no Codex login) — it is on the backlog\n' >&2; exit 1 ;;
esac
SH
chmod +x "$IB/fleet-control-read.sh"
printf 'FLEET_REPO=acme/web\n' > "$FLEET_CONF_DIR/fleets/tf/conf"
H=$(hostname -s 2>/dev/null); H=${H%%.*}
mv "$FLEET_CLIENT_DIR/client.lease" "$WORK/lease.kept" 2>/dev/null
mkdir -p "$WORK/import-guard"
cat > "$WORK/import-guard/sitecustomize.py" <<'PY'
import sys

class RejectHubImports:
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "urllib.request":
            raise RuntimeError("fixture HTTP imports forbidden")

sys.meta_path.insert(0, RejectHubImports())
PY
rm -f "$IB/fleet-connect.py"
cat > "$IB/fleet-connect.py" <<'PY'
import os
from pathlib import Path
Path(os.environ["WORK"], "connect-loaded").write_text("loaded")
raise RuntimeError("fixture connection reader")
PY
PYTHONPATH="$WORK/import-guard" FLEET_PLACE_RESULT="$WORK/i.json" run "$IB/fleet-client-place.sh" acme/web new --title 'x' --agent codex
st_eq "I: cold local start exit" 0 "$RC"
CHECKS=$((CHECKS + 1)); [ ! -e "$WORK/connect-loaded" ] || st_miss "I: no lease must not load the connection reader"
st_has "I: the LOCAL line" "$OUT" "LOCAL $H"
st_has "I: the adapter was asked for codex" "$(cat "$WORK/i-args")" "start tf new codex acme/web"
st_eq "I: the window it opened" '@17' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("window_id"))' "$WORK/i.json")"
st_eq "I: the issue filed" 'https://github.com/acme/web/issues/42' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("filed"))' "$WORK/i.json")"
st_eq "I: this machine" "$H" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("machine"))' "$WORK/i.json")"
rm -f "$WORK/i.json"
I_MODE=warm FLEET_PLACE_RESULT="$WORK/i.json" run "$IB/fleet-client-place.sh" acme/web new --title 'x'
st_eq "I: a warm start's window" '@18' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("window_id"))' "$WORK/i.json")"
rm -f "$WORK/i.json"
PYTHONPATH="$WORK/import-guard" I_MODE=scratch FLEET_PLACE_RESULT="$WORK/i.json" run "$IB/fleet-client-place.sh" acme/web scratch --name short --agent codex --draft-file "$WORK/draft.txt"
st_eq "I: cold draft start exit" 0 "$RC"
st_eq "I: a cold draft's tab-separated window" '@19' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("window_id"))' "$WORK/i.json")"
st_eq "I: a cold draft does not file an issue" '' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("filed", ""))' "$WORK/i.json")"
rm -f "$WORK/i.json"
I_MODE=no FLEET_PLACE_RESULT="$WORK/i.json" run "$IB/fleet-client-place.sh" acme/web new --title 'x' --agent codex
st_eq "I: a declined start" 5 "$RC"
st_has "I: …keeps the spawn's reason on its line" "$OUT" "no Codex login"
CHECKS=$((CHECKS + 1)); [ -s "$WORK/i.json" ] && st_miss "I: a declined start named a window" "$(cat "$WORK/i.json")"
mv "$WORK/lease.kept" "$FLEET_CLIENT_DIR/client.lease"
mv "$FLEET_CLIENT_KEY_FILE" "$WORK/key.kept"
PYTHONPATH="$WORK/import-guard" I_MODE=scratch run "$IB/fleet-client-place.sh" acme/web scratch --agent codex
st_eq "I: missing key keeps the local route" 0 "$RC"
CHECKS=$((CHECKS + 1)); [ ! -e "$WORK/connect-loaded" ] || st_miss "I: no key must not load the connection reader"
mv "$WORK/key.kept" "$FLEET_CLIENT_KEY_FILE"
rm -f "$WORK/i-args"
PYTHONPATH="$WORK/import-guard" run "$IB/fleet-client-place.sh" acme/web scratch --agent codex
st_eq "I: live lease requires the HTTP implementation" 1 "$RC"
st_has "I: HTTP dependency failure is reported" "$ERR" 'fixture HTTP imports forbidden'
CHECKS=$((CHECKS + 1)); [ ! -e "$WORK/i-args" ] || st_miss "I: failed HTTP preparation must not launch locally"
run "$IB/fleet-client-place.sh" acme/web scratch --agent codex
st_eq "I: live lease keeps connection-reader failures fail-closed" 1 "$RC"
CHECKS=$((CHECKS + 1)); [ -f "$WORK/connect-loaded" ] || st_miss "I: live lease must load the connection reader"
CHECKS=$((CHECKS + 1)); [ ! -e "$WORK/i-args" ] || st_miss "I: failed hub preparation must not launch locally"
rm -rf "$FLEET_CONF_DIR/fleets"

# --- T. a task (issue #3325): the record first, its number back -----------------------------
rm -f "$WORK/t.json"
FLEET_PLACE_RESULT="$WORK/t.json" run "$P" - scratch --name 看看风扇 --task --via ⌘P
st_eq "T: a task opens" 0 "$RC"
st_has "T: …asked as a task" "$(lastreq)" '"task": true'
st_has "T: …from ⌘P" "$(lastreq)" '"via": "⌘P"'
st_has "T: …a no-repo scratch" "$(lastreq)" '"no_repo": true'
st_has "T: the record's number on stderr" "$ERR" 'task: T218'
st_eq "T: …and in the result" 'T218' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("task"))' "$WORK/t.json")"
run "$P" verkyyi/claude-fleet scratch
CHECKS=$((CHECKS + 1)); case "$(lastreq)" in *'"task"'*|*'"via"'*) st_miss "T: a plain start asks for no task" "$(lastreq)" ;; esac
case "$ERR" in *'task:'*) st_miss "T: a plain start says no record" "$ERR" ;; esac
run "$P" acme/web issue-3 --task;          st_eq "T: --task is for new / a no-repo scratch" 2 "$RC"
run "$P" acme/web scratch --task;          st_eq "T: …not a repo scratch" 2 "$RC"
run "$P" - home --task;                    st_eq "T: …not a home" 2 "$RC"
run "$P" - scratch --via ⌘P;               st_eq "T: --via goes with --task" 2 "$RC"

# --- M. a DeepSeek session (task J7BN): offered by the hub, placed by the hub, never here --
rm -f "$WORK/models"
run "$P" --models
st_eq "M: a hub older than J7BN: nothing to offer" "1 " "$RC $OUT"
: > "$WORK/models"
run "$P" --models
st_eq "M: the hub offers none" "0 " "$RC $OUT"
printf 'deepseek deepseek-pro gpt-5\n' > "$WORK/models"
run "$P" --models
st_eq "M: the hub offers both (only known names)" "0 deepseek deepseek-pro" "$RC $(printf '%s' "$OUT" | tr '\n' ' ' | sed 's/ $//')"
st_has "M: …asked as action=models" "$(lastreq)" '"action": "models"'
run "$P" - scratch --name 看看 --task --via ⌘P --model DeepSeek-Pro
st_eq "M: a DeepSeek task opens through the hub" 0 "$RC"
st_has "M: …with its model" "$(lastreq)" '"model": "deepseek-pro"'
st_has "M: …as Claude" "$(lastreq)" '"resolved_agent": "claude"'
run "$P" verkyyi/claude-fleet scratch
CHECKS=$((CHECKS + 1)); case "$(lastreq)" in *'"model"'*) st_miss "M: a plain start names no model" "$(lastreq)" ;; esac
run "$P" - scratch --model gpt-5;               st_eq "M: an unknown model is usage" 2 "$RC"
run "$P" - scratch --model deepseek --agent codex; st_eq "M: …so is codex with it" 2 "$RC"
(unset FLEET_HUB_URL FLEET_HUB_TOKEN; run "$P" --models; printf '%s' "$RC" > "$WORK/m.rc")
st_eq "M: no hub: --models offers nothing" 1 "$(cat "$WORK/m.rc")"

# --- E. usage -----------------------------------------------------------------------------
run "$P" verkyyi/claude-fleet bogus;  st_eq "E: bad kind" 2 "$RC"
run "$P" claude-fleet scratch;        st_eq "E: bad repo" 2 "$RC"
run "$P" verkyyi/claude-fleet;        st_eq "E: no kind" 2 "$RC"

st_done
