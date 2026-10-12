#!/bin/bash
# fleet-issue-bridge-hub-selftest.sh — a hub ticket's comment reaches its session
# (issue #3597, EPIC #3570 C4) — bin/fleet-issue-bridge.sh against a FAKE hub on
# 127.0.0.1 (a real HTTP server, so "the hub is down" is a stopped server), a fake
# tmux and a gh that only records it was asked.
#
#   E1 EVENT       the node agent's --event: an idle worker's window gets it once;
#                  the same event again is a dup (nothing typed twice).
#   E2 ECHO        a comment the fleet wrote (source=fleet) is never sent back.
#   E3 BUSY        a working worker: exit 75, not marked seen (the backstop's).
#   E4 ELSEWHERE   no window on this node: exit 0, not seen, no forward, no revive.
#   P1 BACKSTOP    the poll of a FLEET_TICKETS=hub repo asks the hub, never gh;
#                  with the hub down it holds the watermark, and once the hub is
#                  back the comment it missed is typed in (docs/BREAK-IT.md
#                  ticket-hub-down) — then the watermark is the hub's own #max.
#   R1 ROWS        fleet_bridge_rows: a hub-ticket repo is bridged by default,
#                  FLEET_ISSUE_BRIDGE=0 still turns it off; a GitHub repo is not
#                  (byte for byte).
#   G  GH ZERO     none of the above asked gh anything.
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-issue-bridge.sh"
command -v python3 >/dev/null 2>&1 || { echo 'selftest: python3 missing — SKIP' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fibh-selftest.XXXXXX")" || exit 2
HUBPID=''
stop_hub() { [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null; [ -n "$HUBPID" ] && wait "$HUBPID" 2>/dev/null; HUBPID=''; }
trap 'stop_hub; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf/fleets/s1/repos" "$WORK/state" "$WORK/leases"
for f in fleet-issue-bridge.sh fleet-lib.sh fleet-input.py fleet_ticket.py fleet-ticket.sh; do
  cp "$BIN/$f" "$WORK/bin/$f"
done
INJECT="$WORK/inject.log"; GHLOG="$WORK/gh.log"; SPAWN_LOG="$WORK/spawn.log"
: > "$INJECT"; : > "$GHLOG"; : > "$SPAWN_LOG"

cat > "$WORK/bin/dash-issue-session.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$SPAWN_LOG"
FAKE
chmod +x "$WORK/bin/dash-issue-session.sh"

cat > "$WORK/fakepath/gh" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$GHLOG"
exit 1
FAKE
chmod +x "$WORK/fakepath/gh"

# The window table: @1 #10 idle, @2 #11 working. No #12 here.
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
args="\$*"
case "\$1" in
  info|has-session) exit 0 ;;
  list-windows)
    case "\$args" in
      *@claude_state*) u=\$'\037'; printf '%s\n' "s1\${u}@1\${u}done\${u}10" "s1\${u}@2\${u}working\${u}11" ;;
    esac ;;
  capture-pane) printf 'a past user turn\n❯ \n  status\n' ;;
  display-message) case "\$args" in *'@repo'*) printf 'fake/repo||\n' ;; *) printf '\n' ;; esac ;;
  set-buffer|paste-buffer|send-keys|delete-buffer) printf '%s\n' "\$args" >> "$INJECT" ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"

printf 'FLEET_SESSION=s1\n' > "$WORK/conf/fleets/s1/conf"
printf 'FLEET_REPO=fake/repo\nFLEET_TICKETS=hub\n' > "$WORK/conf/fleets/s1/repos/fake-repo.conf"
printf 'fake/repo\n' > "$WORK/conf/fleets/s1/repos/.order"

# --- the fake hub: GET /v1/fleet/tickets[?…] and /v1/fleet/tickets/fake/repo/<N>,
# answered from $WORK/hub.json, re-read on every request.
HUBDATA="$WORK/hub.json"
cat > "$WORK/hub.py" <<'PY'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
data = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        d = json.load(open(data))
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if self.headers.get('Authorization') != 'Bearer tok':
            return self.send(401, {'error': 'no'})
        if u.path == '/v1/fleet/tickets':
            since = (q.get('since') or [''])[0]
            ts = [t for t in d['tickets'] if not since or t['updated_at'] >= since]
            return self.send(200, {'tickets': ts})
        p = u.path[len('/v1/fleet/tickets/'):].split('/')
        if len(p) == 3:
            t = [x for x in d['tickets'] if str(x['number']) == p[2]]
            if t:
                return self.send(200, {'ticket': t[0], 'comments': d['comments'].get(p[2], [])})
        self.send(404, {'error': 'no such ticket'})
    def send(self, code, doc):
        b = json.dumps(doc).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
s = HTTPServer(('127.0.0.1', 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
PORT=''
start_hub() {
  local f="$WORK/port.$RANDOM" i=0
  python3 "$WORK/hub.py" "$HUBDATA" > "$f" 2>/dev/null &
  HUBPID=$!
  while [ ! -s "$f" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  PORT=$(head -1 "$f")
  [ -n "$PORT" ] || { echo 'selftest: the fake hub did not start' >&2; exit 2; }
}
hub_data() {  # <comments-json-object>
  python3 - "$HUBDATA" "$1" <<'PY'
import json, sys
c = json.loads(sys.argv[2])
ts = []
for n, cs in c.items():
    up = max([x['created_at'] for x in cs] or ['2026-10-12T00:00:00Z'])
    ts.append({'repo': 'fake/repo', 'number': int(n), 'backend': 'hub', 'state': 'open', 'updated_at': up})
json.dump({'tickets': ts, 'comments': c}, open(sys.argv[1], 'w'))
PY
}

runbridge() {
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_ISSUE_BRIDGE_STATE_DIR="$WORK/state" FLEET_DISPATCH_LEASE_DIR="$WORK/leases" \
  CCQUOTA_HUB_URL="http://127.0.0.1:${PORT:-1}" CCQUOTA_TOKEN=tok CCQUOTA_FLEET=1 \
  FLEET_ISSUE_BRIDGE_REVIVE=1 SPAWN_LOG="$SPAWN_LOG" FLEET_HUB_TIMEOUT=2 \
    bash "$WORK/bin/fleet-issue-bridge.sh" "$@" 2>>"$WORK/log"
}
fail() { printf 'selftest FAIL: %s\n--- log ---\n' "$1" >&2; cat "$WORK/log" >&2
         printf -- '--- inject ---\n' >&2; cat "$INJECT" >&2; exit 1; }
typed() { grep -c 'send-keys -t @1 Enter' "$INJECT" 2>/dev/null || true; }
seen() { find "$WORK/conf" "$WORK/state" -name "*seen*" -type f -exec cat {} + 2>/dev/null | grep -qxF "$1"; }
sincef() { find "$WORK/conf" "$WORK/state" -name "*since*" -type f | head -1; }
: > "$WORK/log"

hub_data '{"10":[{"id":500,"author":"boss","body":"hub says hello","source":"hub","created_at":"2026-10-12T01:00:00.123456789Z"},
                 {"id":501,"author":"fleet","body":"a worker note","source":"fleet","created_at":"2026-10-12T01:00:01Z"}],
           "11":[{"id":510,"author":"boss","body":"for the busy one","source":"hub","created_at":"2026-10-12T01:00:02Z"}],
           "12":[{"id":520,"author":"boss","body":"for nobody here","source":"hub","created_at":"2026-10-12T01:00:03Z"}]}'
start_hub

# ---- E1 ---------------------------------------------------------------------
runbridge --event fake/repo 10 500; rc=$?
[ "$rc" = 0 ] || fail "E1: --event exit $rc, want 0"
[ "$(typed)" = 1 ] || fail "E1: want one paste into @1, got $(typed)"
grep -qF 'hub says hello' "$INJECT" || fail "E1: the comment's words were not typed"
grep -qF '[issue #10 — comment from @boss]' "$INJECT" || fail "E1: the relay header is the bridge's own"
seen 500 || fail "E1: c500 must be marked seen"
runbridge --event fake/repo 10 500; rc=$?
[ "$rc" = 0 ] && [ "$(typed)" = 1 ] || fail "E1: the same event twice must type it once (rc $rc, typed $(typed))"
echo 'selftest: E1 event → one paste, a repeat is a dup — PASS' >&2

# ---- E2 ---------------------------------------------------------------------
runbridge --event fake/repo 10 501; rc=$?
[ "$rc" = 0 ] || fail "E2: exit $rc"
grep -qF 'a worker note' "$INJECT" && fail "E2: a source=fleet comment must never be typed back"
grep -q 'suppress:fleet' "$WORK/log" || fail "E2: the log must say suppress:fleet"
echo 'selftest: E2 source=fleet never echoed — PASS' >&2

# ---- E3 ---------------------------------------------------------------------
runbridge --event fake/repo 11 510; rc=$?
[ "$rc" = 75 ] || fail "E3: a busy worker must answer 75, got $rc"
grep -qF 'for the busy one' "$INJECT" && fail "E3: nothing typed into a working worker"
seen 510 && fail "E3: c510 must stay unseen (the backstop retries it)"
echo 'selftest: E3 busy → 75, unseen — PASS' >&2

# ---- E4 ---------------------------------------------------------------------
runbridge --event fake/repo 12 520; rc=$?
[ "$rc" = 0 ] || fail "E4: no window here must exit 0, got $rc"
seen 520 && fail "E4: c520 must stay unseen on a node without its window"
[ -s "$SPAWN_LOG" ] && fail "E4: an event never revives ($(cat "$SPAWN_LOG"))"
grep -q 'elsewhere' "$WORK/log" || fail "E4: the log must say elsewhere"
echo 'selftest: E4 elsewhere → 0, unseen, no revive — PASS' >&2

# ---- P1 (BREAK-IT ticket-hub-down) --------------------------------------------
SINCE=$(sincef); [ -n "$SINCE" ] || SINCE="$(dirname "$(find "$WORK/conf" "$WORK/state" -name '*seen*' -type f | head -1)")/since"
printf '2026-10-12T02:00:00Z\n' > "$SINCE"
stop_hub                                     # the hub goes away …
hub_data '{"10":[{"id":600,"author":"boss","body":"said while the hub was down","source":"hub","created_at":"2026-10-12T02:00:05Z"}]}'
before=$(typed)
runbridge --poll || fail "P1: a poll with the hub down must exit 0"
[ "$(typed)" = "$before" ] || fail "P1: nothing to type while the hub is down"
[ "$(cat "$SINCE")" = '2026-10-12T02:00:00Z' ] || fail "P1: the watermark must hold while the hub is down ($(cat "$SINCE"))"
grep -q '入口不通' "$WORK/log" || fail "P1: the log must say 入口不通"
start_hub                                    # … and comes back
runbridge --poll || fail "P1: the poll after the hub is back exited non-zero"
grep -qF 'said while the hub was down' "$INJECT" || fail "P1: the backstop must type the comment the event missed"
[ "$(typed)" = $((before + 1)) ] || fail "P1: exactly one paste"
[ "$(cat "$SINCE")" = '2026-10-12T02:00:05Z' ] || fail "P1: the watermark is the hub's #max ($(cat "$SINCE"))"
runbridge --poll || fail "P1: a second poll exited non-zero"
[ "$(typed)" = $((before + 1)) ] || fail "P1: the second poll must type nothing new (dedup)"
echo 'selftest: P1 hub down → held, back → backstop types it once — PASS' >&2

# ---- R1 ---------------------------------------------------------------------
rows() { FLEET_CONF_DIR="$WORK/conf" PATH="$WORK/fakepath:$PATH" bash -c '. "$1/fleet-lib.sh"; fleet_bridge_rows' _ "$WORK/bin" | cut -f1; }
[ "$(rows)" = fake/repo ] || fail "R1: a hub-ticket repo is bridged by default (got [$(rows)])"
printf 'FLEET_REPO=fake/repo\nFLEET_TICKETS=hub\nFLEET_ISSUE_BRIDGE=0\n' > "$WORK/conf/fleets/s1/repos/fake-repo.conf"
[ -z "$(rows)" ] || fail "R1: FLEET_ISSUE_BRIDGE=0 still turns it off"
printf 'FLEET_REPO=fake/repo\n' > "$WORK/conf/fleets/s1/repos/fake-repo.conf"
[ -z "$(rows)" ] || fail "R1: a GitHub-ticket repo stays off unless it says 1 (byte for byte)"
echo 'selftest: R1 bridge rows — PASS' >&2

# ---- G ----------------------------------------------------------------------
[ -s "$GHLOG" ] && fail "G: a hub-ticket repo must never ask gh: $(cat "$GHLOG")"
echo 'selftest PASS: event + echo + busy + elsewhere + hub-down backstop + rows, gh asked 0 times'
exit 0
