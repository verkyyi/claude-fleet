#!/bin/bash
# fleet-reach-report-selftest.sh — the view machine's reachability report (task
# FQAR): bin/fleet-reach-report.py folds view-switch.ndjson + peerlink.ndjson into
# hourly rows and sends them to POST /v1/fleet/reach-stats. A sandbox conf dir,
# fixture ledgers, a stand-in hub on 127.0.0.1 — never the person's hub.
#
#   A  fold — enters: local ok / slower than 10 s / gone; far ones by the link's
#      route class at that moment (direct, then relay after the ledger switched);
#      a peer-wait an `up` answered within 10 s is ok (its ms include the wait),
#      one never answered is not; far-none is unknown; forward is no enter
#   B  fold — links: wanted / up time from event to event, split at the hour,
#      at most FLEET_REACH_STALE_SECS past the last event; a down→up recovery
#      in its bucket (gap_s when the ledger has it); no hour above 3600000 ms
#   C  privacy: no machine or login in what is sent, a link is 16 hex from a
#      0600 salt of this login's, another salt gives another id
#   D  send / tick: the body goes to the seam whole; FLEET_REACH_REPORT=0 sends
#      nothing; tick sends once an hour, retries 600 s after a failure, and says
#      nothing on a machine with no ledgers
#   E  the real POST: a stand-in hub gets the Bearer token in a header (never a
#      URL), the path and {rows}
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/reach.XXXXXX")"; T="$(cd "$T" && pwd -P)"
st_tally
cleanup() {
  [ -n "${HUBPID:-}" ] && { kill "$HUBPID" 2>/dev/null; wait "$HUBPID" 2>/dev/null; }
  rm -rf "$T"
}
trap cleanup EXIT

export HOME="$T/home" FLEET_CONF_DIR="$T/conf" XDG_CACHE_HOME="$T/cache"
mkdir -p "$HOME" "$FLEET_CONF_DIR/logs"
unset FLEET_HUB_URL FLEET_HUB_TOKEN FLEET_REACH_POST_CMD FLEET_REACH_REPORT FLEET_REACH_NOW
RR="$BIN/fleet-reach-report.py"
VL="$FLEET_CONF_DIR/logs/view-switch.ndjson"
PL="$FLEET_CONF_DIR/logs/peerlink.ndjson"

# Hour H0 = 2026-11-02 10:00 UTC; NOW = H0 + 1 h 30 min.
H0=1793613600
NOW=$((H0 + 5400))
python3 - "$VL" "$PL" "$H0" <<'PY'
import json, sys
vl, pl, h0 = sys.argv[1], sys.argv[2], int(sys.argv[3])
def v(t, method, ms, to="@5", machine="mac-c", login="kim"):
    return {"ts": h0 + t, "view": "Mac-abc", "from": "@1", "to": to, "machine": machine, "login": login,
            "method": method, "ms": ms, "how": "popup"}
far = "c7d3/ca4b"
views = [
    v(10, "select-window", 40), v(20, "select-window", 12000), v(30, "gone", 5),   # local: 3 attempts, 1 ok
    v(100, "peer-select", 250, far, "mac-d", "lee"),                              # direct at 100
    v(700, "gone", 30, far, "mac-d", "lee"),                                      # link down: a failure
    v(1300, "peer-window", 900, far, "mac-d", "lee"),                             # relay after the switch
    v(895, "peer-wait", 100, far, "mac-d", "lee"),                                # up at 900: ok, 5100 ms
    v(2000, "peer-wait", 100, far, "mac-d", "lee"),                               # no up within 10 s
    v(2100, "far-none", 9, far, "", ""),                                          # unknown
    v(2200, "forward", 0, "", "", ""),                                            # not an enter
]
with open(vl, "w") as f:
    for x in views:
        f.write(json.dumps(x) + "\n")
def e(t, event, route, cause="ok", gap=None):
    return {"ts": h0 + t, "machine": "mac-d", "login": "lee", "route": route, "event": event, "cause": cause,
            "detail": "", "gap_s": gap, "rtt_ms": None}
evs = [
    e(0, "up", "tailnet"),
    e(600, "down", "tailnet", "timeout"),
    e(700, "retry", "tailnet", "network"),
    e(900, "up", "peer-relay", "ok", 300.0),
    # silence after 900: wanted until 900 + 900 = 1800 only
]
with open(pl, "w") as f:
    for x in evs:
        f.write(json.dumps(x) + "\n")
PY

fold() { FLEET_REACH_NOW=$NOW python3 "$RR" fold; }
OUT=$(fold)

# --- A / B --------------------------------------------------------------------
res=$(python3 - "$OUT" "$H0" <<'PY'
import json, sys
rows, h0 = json.loads(sys.argv[1]), int(sys.argv[2])
H = h0 // 3600
by = {}
for r in rows:
    by[(r["hour"] - H, r["link"] != "", r["route"])] = r
bad = []
def chk(name, got, want):
    if got != want:
        bad.append("%s: got %r want %r" % (name, got, want))
loc = by.get((0, False, "local"), {})
chk("local attempts/ok", (loc.get("attempts"), loc.get("ok")), (3, 1))
chk("local enter bucket <150", loc.get("enter", [None])[0], 1)
d0 = by.get((0, True, "direct"), {})
chk("direct attempts/ok (peer-select ok, gone not)", (d0.get("attempts"), d0.get("ok")), (2, 1))
chk("direct enter <300", d0.get("enter", [0] * 13)[2], 1)
r0 = by.get((0, True, "relay"), {})
# peer-window 900 ms ok + peer-wait answered (5100 ms) ok + peer-wait unanswered (route relay at 2000)
chk("relay attempts/ok", (r0.get("attempts"), r0.get("ok")), (3, 2))
chk("relay enter <1000", r0.get("enter", [0] * 13)[4], 1)
chk("relay enter <10000 (the waited one)", r0.get("enter", [0] * 13)[7], 1)
unk = by.get((0, False, "unknown"), {})
chk("far-none unknown", (unk.get("attempts"), unk.get("ok")), (1, 0))
chk("forward is no enter", sum(r["attempts"] for r in rows), 9)
# links, hour 0: tailnet up 0..600 (600 s up), down 600..900 (300 s wanted, not up) → direct
chk("direct want/up", (d0.get("want_ms"), d0.get("up_ms")), (900000, 600000))
# relay up 900..1800 (stale cap) — 900 s, all up; nothing in hour 1
chk("relay want/up", (r0.get("want_ms"), r0.get("up_ms")), (900000, 900000))
chk("recovery 300 s in the <1800000 bucket", r0.get("recover", [0] * 13)[11], 1)
chk("nothing after the stale cap", [k for k in by if k[0] == 1 and k[1]], [])
chk("no hour over 3600000", max(r["want_ms"] for r in rows) <= 3600000, True)
print("OK" if not bad else "\n".join(bad))
PY
)
st_eq "A+B: fold" "OK" "$res"
st_ok_all "A: enters — local / far by route class / peer-wait / far-none / forward"
st_ok_all "B: links — wanted / up, stale cap, recovery bucket"

# A segment that crosses an hour is split at it.
cat > "$T/pl2" <<EOF
{"ts": $((H0 + 3000)), "machine": "m", "login": "u", "route": "lan", "event": "up", "cause": "ok", "detail": "", "gap_s": null, "rtt_ms": null}
{"ts": $((H0 + 3500)), "machine": "m", "login": "u", "route": "lan", "event": "probe", "cause": "ok", "detail": "", "gap_s": null, "rtt_ms": 30}
{"ts": $((H0 + 4000)), "machine": "m", "login": "u", "route": "lan", "event": "probe", "cause": "ok", "detail": "", "gap_s": null, "rtt_ms": 30}
EOF
split=$(FLEET_REACH_NOW=$((H0 + 4300)) FLEET_REACH_VIEW_LOG=/nonexistent FLEET_REACH_PEERLINK_LOG="$T/pl2" python3 "$RR" fold \
  | python3 -c 'import json,sys; print(" ".join("%d:%d/%d" % (r["hour"]%24, r["want_ms"], r["up_ms"]) for r in json.load(sys.stdin)))')
st_eq "B: a segment split at the hour" "10:600000/600000 11:700000/700000" "$split"

# --- C ------------------------------------------------------------------------
st_hasnt "C: no machine name sent" "$OUT" "mac-d"
st_hasnt "C: no login sent" "$OUT" '"lee"'
st_hasnt "C: no view machine sent" "$OUT" "mac-c"
links=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(" ".join(sorted({r["link"] for r in json.load(sys.stdin) if r["link"]})))')
case "$links" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) st_ok_all "C: one link, 16 hex" ;;
  *) st_miss "C: links [$links]" ;; esac
mode=$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$FLEET_CONF_DIR/reach-salt")
st_eq "C: the salt is this login's alone" "0o600" "$mode"
cp "$FLEET_CONF_DIR/reach-salt" "$T/salt.keep"
printf '%064d\n' 7 > "$FLEET_CONF_DIR/reach-salt"
links2=$(fold | python3 -c 'import json,sys; print(" ".join(sorted({r["link"] for r in json.load(sys.stdin) if r["link"]})))')
[ "$links2" != "$links" ] && st_ok_all "C: another salt, another id" || st_miss "C: the id does not depend on the salt"
cp "$T/salt.keep" "$FLEET_CONF_DIR/reach-salt"

# --- D ------------------------------------------------------------------------
cat > "$T/post.sh" <<EOF
#!/bin/sh
cat > "$T/posted.\$\$.json"
echo x >> "$T/posts"
exit \${POST_RC:-0}
EOF
chmod +x "$T/post.sh"
export FLEET_REACH_POST_CMD="$T/post.sh"
s=$(FLEET_REACH_NOW=$NOW python3 "$RR" send)
st_eq "D: send" "sent $(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" "$s"
body=$(cat "$T"/posted.*.json)
st_has "D: the body is {rows}" "$body" '"rows": [{"hour":'
rm -f "$T"/posted.*.json "$T/posts"
FLEET_REACH_REPORT=0 FLEET_REACH_NOW=$NOW python3 "$RR" send >/dev/null
FLEET_REACH_REPORT=0 FLEET_REACH_NOW=$NOW python3 "$RR" tick
st_eq "D: FLEET_REACH_REPORT=0 sends nothing" "0" "$(cat "$T/posts" 2>/dev/null | wc -l | tr -d ' ')"
FLEET_REACH_NOW=$NOW python3 "$RR" tick
FLEET_REACH_NOW=$((NOW + 60)) python3 "$RR" tick
st_eq "D: tick sends once within the hour" "1" "$(wc -l < "$T/posts" | tr -d ' ')"
FLEET_REACH_NOW=$((NOW + 3700)) POST_RC=1 python3 "$RR" tick
FLEET_REACH_NOW=$((NOW + 3800)) python3 "$RR" tick
st_eq "D: a failure is not retried at once" "2" "$(wc -l < "$T/posts" | tr -d ' ')"
FLEET_REACH_NOW=$((NOW + 4400)) python3 "$RR" tick
st_eq "D: …but 600 s later" "3" "$(wc -l < "$T/posts" | tr -d ' ')"
out=$(FLEET_CONF_DIR="$T/empty" FLEET_REACH_NOW=$NOW python3 "$RR" tick 2>&1)
st_eq "D: no ledgers — nothing said, nothing sent" "|3" "$out|$(wc -l < "$T/posts" | tr -d ' ')"
unset FLEET_REACH_POST_CMD

# --- E ------------------------------------------------------------------------
python3 - "$T" <<'PY' &
import http.server, json, os, sys
T = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(os.path.join(T, "hub.req"), "w") as f:
            json.dump({"path": self.path, "auth": self.headers.get("Authorization"), "body": json.loads(body)}, f)
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"accepted":1,"refused":0}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(T, "hub.port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
HUBPID=$!
for _ in $(seq 50); do [ -s "$T/hub.port" ] && break; sleep 0.1; done
s=$(FLEET_HUB_URL="http://127.0.0.1:$(cat "$T/hub.port")" FLEET_HUB_TOKEN=tok-fixture FLEET_REACH_NOW=$NOW python3 "$RR" send)
st_has "E: sent to the stand-in hub" "$s" "sent "
req=$(cat "$T/hub.req" 2>/dev/null)
st_has "E: the path" "$req" '"path": "/v1/fleet/reach-stats"'
st_has "E: Bearer in a header" "$req" '"auth": "Bearer tok-fixture"'
st_has "E: the rows" "$req" '"rows": [{'
st_hasnt "E: no token in the path" "$req" '"path": "/v1/fleet/reach-stats?'

echo
st_done
