#!/usr/bin/env bash
# fleet-proxy-quota-selftest.sh — quota readings straight from the credential
# proxy (issue #1978, EPIC #1967 R3). Drives bin/fleet-cred-proxy.sh +
# bin/fleet-cred-proxy.py against a fake provider that answers with rate-limit
# headers, then bin/fleet-proxy-quota.sh + conf/statusline.sh on an ISOLATED
# tmux socket (sandbox TMUX_TMPDIR, HOME and FLEET_CONF_DIR; loopback only).
#
#   A  the parse: Claude utilization fractions and Codex used-percent land on
#      the bus's scale — ccquota's Utilization (×100), unrounded: statusline.sh
#      floors (57.5 → @rl7d 57, leg C)
#   B  a Claude and a Codex session's requests → `quota` holds each one's
#      reading under its sid; no credential in it
#   C  push: each window (@cred_sid) gets @rl5h @rl7d @rl_reset @rl_ts (= the
#      reading's time) and @rl_src proxy; a second push stamps nothing new
#   D  the proxy wins while fresh: a status-line render and a mod measure leave
#      the proxy's @rl* alone; once stale (FLEET_RL_PROXY_FRESH) they stamp again
#   E  a central-route session (fcp-h1. pass) is found through its qsid
#   F  the proxy kicks FLEET_CRED_QUOTA_PUSH itself after a fresh reading
#   G  revoke drops the session's reading
#   H  degenerate: no proxy → push stamps nothing, exit 0; the quota watch's
#      stamp line reads `proxy` as its own source (usage-lib fleet_quota_merge)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/proxy-quota-st.XXXXXX")
L="pq-st-$$"
cleanup() {
  tmux -L "$L" kill-server 2>/dev/null
  kill "$(cat "$SB/conf/cred-proxy/pid" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$SB/fake.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/conf" XDG_CONFIG_HOME="$SB/xdg" TMUX_TMPDIR="$SB"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$XDG_CONFIG_HOME"
unset FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_PROBE_FORCE_UNREACHABLE TMUX TMUX_PANE FLEET_RL_PROXY_FRESH

FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }

# ── A: the parse ─────────────────────────────────────────────────────────────
a=$(python3 -I - "$BIN/fleet-cred-proxy.py" <<'PY'
import importlib.util, json, sys
sp = importlib.util.spec_from_file_location("p", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
out = [
  m.rl_reading("claude", [("Anthropic-Ratelimit-Unified-5h-Utilization", "0.29"), ("anthropic-ratelimit-unified-7d-utilization", "0.575"),
                          ("anthropic-ratelimit-unified-5h-reset", "1791341400"), ("anthropic-ratelimit-unified-7d-reset", "1791698400")]),
  m.rl_reading("codex", [("x-codex-primary-used-percent", "11.0"), ("x-codex-primary-window-minutes", "300"),
                         ("x-codex-primary-reset-at", "1791341400"), ("x-codex-secondary-used-percent", "40.7"),
                         ("x-codex-secondary-window-minutes", "10080"), ("x-codex-secondary-reset-after-seconds", "100")], now=1000),
  m.rl_reading("codex", [("x-codex-primary-used-percent", "60"), ("x-codex-primary-window-minutes", "10080"),
                         ("x-codex-secondary-used-percent", "5"), ("x-codex-secondary-window-minutes", "300")]),
  m.rl_reading("claude", [("anthropic-ratelimit-unified-5h-utilization", "0.2")]),
  m.rl_reading("claude", [("anthropic-ratelimit-unified-5h-utilization", "x"), ("anthropic-ratelimit-unified-7d-utilization", "0.1")]),
]
print(json.dumps(out, sort_keys=True))
PY
)
want='[{"rl5h": "29", "rl7d": "57.5", "rl_reset5": "1791341400", "rl_reset7": "1791698400"}, {"rl5h": "11", "rl7d": "40.7", "rl_reset5": "1791341400", "rl_reset7": "1100"}, {"rl5h": "5", "rl7d": "60", "rl_reset5": "-", "rl_reset7": "-"}, null, null]'
[ "$a" = "$want" ] && pass "A parse: Claude fraction ×100 (0.29→29, no float noise), Codex used-percent, unrounded; windows ordered by minutes; half a reading = none" \
  || fail "A parse: $a"

# ── the fake provider ────────────────────────────────────────────────────────
cat > "$SB/fake.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SB = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self): self.go()
    def do_POST(self): self.go()
    def go(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        if self.path == "/v1/node/self":
            t = open(os.path.join(SB, "trust")).read().strip()
            b = json.dumps({"endpoint_id": "e1", "trust": t}).encode()
            hdr = []
        elif "codex" in self.path:
            b = b'{"ok":"codex"}'
            hdr = [("x-codex-primary-used-percent", "11.0"), ("x-codex-primary-window-minutes", "300"),
                   ("x-codex-primary-reset-at", "1791341400"), ("x-codex-secondary-used-percent", "40.7"),
                   ("x-codex-secondary-window-minutes", "10080"), ("x-codex-secondary-reset-at", "1791698400")]
        else:
            u = open(os.path.join(SB, "util")).read().split()
            b = b'{"ok":"claude"}'
            hdr = [("anthropic-ratelimit-unified-5h-utilization", u[0]), ("anthropic-ratelimit-unified-7d-utilization", u[1]),
                   ("anthropic-ratelimit-unified-5h-reset", "1791341400"), ("anthropic-ratelimit-unified-7d-reset", "1791698400")]
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        for k, v in hdr: self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
srv.daemon_threads = True
open(os.path.join(SB, "fake.port"), "w").write(str(srv.server_address[1]))
open(os.path.join(SB, "fake.pid"), "w").write(str(os.getpid()))
srv.serve_forever()
PY
echo trusted > "$SB/trust"; echo "0.29 0.87" > "$SB/util"
python3 -I "$SB/fake.py" "$SB" & disown
i=0; while [ ! -s "$SB/fake.port" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$SB/fake.port" ] || { fail "start: the fake provider never came up"; exit 1; }
U="http://127.0.0.1:$(cat "$SB/fake.port")"

mkdir -p "$FLEET_CONF_DIR/accounts/a1.hub" "$SB/codex-homes/a1"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-REAL-a1"}}' > "$FLEET_CONF_DIR/accounts/a1.hub/.credentials.json"
printf '{"tokens":{"access_token":"cx-REAL-a1","account_id":"acct-a1"}}' > "$SB/codex-homes/a1/auth.json"
printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=nodetok\n' "$U" > "$FLEET_CONF_DIR/node.env"
printf '{"loc":"US","anthropic":"reachable","openai":"reachable","verdict":"ok"}\n' > "$FLEET_CONF_DIR/node-probe.json"
cat > "$FLEET_CONF_DIR/fleet.conf" <<EOF
FLEET_CRED_PROXY=1
FLEET_CRED_ANTHROPIC_URL=$U/direct-anthropic
FLEET_CRED_CODEX_URL=$U/direct-codex
FLEET_CRED_CENTRAL_URL=$U/central
FLEET_CRED_CODEX_HOMES=$SB/codex-homes
FLEET_CRED_PROXY_LOG=$SB/proxy.log
EOF
# F's seam: the push the proxy kicks is a stub that leaves a mark
printf '#!/bin/sh\necho "$*" >> "%s/pushed"\n' "$SB" > "$SB/pushstub"; chmod +x "$SB/pushstub"
FLEET_CRED_QUOTA_PUSH="$SB/pushstub" FLEET_CRED_QUOTA_PUSH_SECS=0.3 \
  bash "$BIN/fleet-cred-proxy.sh" ensure --max-seconds 300 >"$SB/port" 2>"$SB/ensure.err" \
  || { cat "$SB/ensure.err"; fail "start: ensure"; exit 1; }
PORT=$(cat "$SB/port")
CP() { bash "$BIN/fleet-cred-proxy.sh" "$@"; }
R() { # R <path> <token> → the status code
  python3 -I -c '
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=30)
c.request("POST", sys.argv[2], body=b"{}", headers={"authorization": "Bearer " + sys.argv[3], "content-type": "application/json"})
r = c.getresponse(); r.read(); print(r.status)' "$PORT" "$1" "$2"
}
qget() { CP quota | python3 -I -c 'import json,sys; d=json.load(sys.stdin).get(sys.argv[1]) or {}; print(" ".join(str(d.get(k, "")) for k in sys.argv[2:]))' "$@"; }

# ── B: readings per session ──────────────────────────────────────────────────
TC=$(CP mint --account a1 --sid wc1); TX=$(CP mint --account a1 --sid wx1)
sc=$(R /v1/messages "$TC"); sx=$(R /codex/responses "$TX")
b1=$(qget wc1 provider rl5h rl7d rl_reset5 rl_reset7 acct route)
b2=$(qget wx1 provider rl5h rl7d rl_reset5 rl_reset7)
if [ "$sc $sx" = "200 200" ] && [ "$b1" = "claude 29 87 1791341400 1791698400 a1 direct" ] \
   && [ "$b2" = "codex 11 40.7 1791341400 1791698400" ]; then
  pass "B quota: a Claude and a Codex session's readings, each under its sid"
else fail "B quota: status=$sc/$sx claude=[$b1] codex=[$b2]"; fi
CP quota | grep -Eq 'REAL|fcp1\.|nodetok' && fail "B a credential reached the quota answer"

# ── C: push onto the windows ─────────────────────────────────────────────────
tmux -L "$L" -f /dev/null new-session -d -s pq -n c1 'sleep 600' || { fail "C tmux"; exit 1; }
tmux -L "$L" new-window -d -t pq -n x1 'sleep 600'
tmux -L "$L" new-window -d -t pq -n none 'sleep 600'
WC=$(tmux -L "$L" display-message -p -t pq:c1 '#{window_id}'); WX=$(tmux -L "$L" display-message -p -t pq:x1 '#{window_id}')
WN=$(tmux -L "$L" display-message -p -t pq:none '#{window_id}')
tmux -L "$L" set-option -w -t "$WC" @cred_sid wc1 \; set-option -w -t "$WX" @cred_sid wx1
opts() { tmux -L "$L" display-message -p -t "$1" '#{@rl5h} #{@rl7d} #{@rl_reset} #{@rl_src} #{@rl_ts}'; }
ts_c=$(qget wc1 ts)
out=$(bash "$BIN/fleet-proxy-quota.sh" push --socket "$L")
oc=$(opts "$WC"); ox=$(opts "$WX"); on=$(opts "$WN")
if [ "$oc" = "29 87 1791341400 1791698400 proxy $ts_c" ] && [ "$ox" = "11 40 1791341400 1791698400 proxy $(qget wx1 ts)" ] \
   && [ "$on" = "    " ] && [ "$(printf '%s\n' "$out" | grep -c '^stamped')" = 2 ]; then
  pass "C push: Claude + Codex windows get @rl* (40.7 floored to 40 by statusline.sh) + @rl_src proxy, @rl_ts = the reading's time; a window with no session untouched"
else fail "C push: claude=[$oc] codex=[$ox] none=[$on] out=[$out]"; fi
out=$(bash "$BIN/fleet-proxy-quota.sh" push --socket "$L")
[ -z "$out" ] && pass "C a second push with nothing new stamps nothing" || fail "C re-push: $out"
tmux -L "$L" show-options -w -t "$WC" | grep -q '@ctx_src' && fail "C the proxy feed touched @ctx_src"

# ── D: the proxy wins while fresh ────────────────────────────────────────────
SLJ='{"context_window":{"used_percentage":12,"context_window_size":200000},"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1},"seven_day":{"used_percentage":6,"resets_at":2}}}'
spath=$(tmux -L "$L" display-message -p '#{socket_path}')
SLR() { TMUX="$spath,0,0" TMUX_PANE="$WC" bash "$BIN/../conf/statusline.sh" "$@"; }
SLR <<< "$SLJ"
SLR --from mod rl5h=7 rl7d=8 rl_reset5=3 rl_reset7=4
d1=$(opts "$WC"); d1ctx=$(tmux -L "$L" display-message -p -t "$WC" '#{@ctx_pct} #{@model}')
tmux -L "$L" set-option -w -t "$WC" @rl_ts $(( $(date +%s) - 400 ))
SLR <<< "$SLJ"
d2=$(opts "$WC")
if [ "$d1" = "29 87 1791341400 1791698400 proxy $ts_c" ] && [ "$d1ctx" = "12 Opus" ] && case "$d2" in "5 6 1 2  "*) true ;; *) false ;; esac; then
  pass "D a fresh proxy reading holds against the status line and the mod (context still stamped); stale, the status line stamps again"
else fail "D proxy-wins: fresh=[$d1] ctx=[$d1ctx] stale=[$d2]"; fi
echo "0.30 0.88" > "$SB/util"; R /v1/messages "$TC" >/dev/null
bash "$BIN/fleet-proxy-quota.sh" push --socket "$L" >/dev/null
case "$(opts "$WC")" in "30 88 "*" proxy "*) pass "D the next proxy reading takes the window back" ;; *) fail "D retake: $(opts "$WC")" ;; esac

# ── E: a central-route session ───────────────────────────────────────────────
echo untrusted > "$SB/trust"
CP route --refresh >/dev/null
HP="fcp-h1.passforwe1"
qs=$(printf '%s' "$HP" | python3 -I -c 'import hashlib,sys; print("h-" + hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:10])')
mkdir -p "$FLEET_CONF_DIR/cred-proxy/sessions"
printf 'route=central\nqsid=%s\n' "$qs" > "$FLEET_CONF_DIR/cred-proxy/sessions/we1"
tmux -L "$L" set-option -w -t "$WN" @cred_sid we1
sc=$(R /v1/messages "$HP")
bash "$BIN/fleet-proxy-quota.sh" push --socket "$L" >/dev/null
case "$sc $(opts "$WN")" in "200 30 88 "*" proxy "*) pass "E central: the pass's reading (h-<hash>) finds its window through qsid" ;;
  *) fail "E central: status=$sc opts=[$(opts "$WN")] quota=$(CP quota)" ;; esac
grep -q 'qs=\$(printf' "$BIN/fleet-session-cred.sh" && grep -q 'rec_set "$sid" qsid' "$BIN/fleet-session-cred.sh" \
  || fail "E fleet-session-cred.sh no longer records qsid"
echo trusted > "$SB/trust"; CP route --refresh >/dev/null

# ── F: the proxy kicks the push itself ───────────────────────────────────────
i=0; while [ ! -s "$SB/pushed" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
n=$(grep -c '^push$' "$SB/pushed" 2>/dev/null)
[ "${n:-0}" -ge 1 ] && [ "$n" -le 4 ] && pass "F a fresh reading kicks FLEET_CRED_QUOTA_PUSH push (debounced: $n kicks for 4 readings)" \
  || fail "F kick: $(cat "$SB/pushed" 2>/dev/null)"

# ── G: revoke ────────────────────────────────────────────────────────────────
CP revoke --sid wx1 >/dev/null
[ -z "$(qget wx1 rl5h)" ] && pass "G revoke drops the session's reading" || fail "G revoke: $(CP quota)"
grep -Eq 'REAL-a|nodetok|fcp1\.|fcp-h1\.' "$SB/proxy.log" && fail "G a credential reached the log"

# ── H: degenerate ────────────────────────────────────────────────────────────
kill "$(cat "$FLEET_CONF_DIR/cred-proxy/pid")" 2>/dev/null
i=0; while [ -S "$FLEET_CONF_DIR/cred-proxy/ctl.sock" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
tmux -L "$L" set-option -w -u -t "$WC" @rl_ts
before=$(opts "$WC")
out=$(bash "$BIN/fleet-proxy-quota.sh" push --socket "$L"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(opts "$WC")" = "$before" ] && pass "H no proxy: push exits 0 and stamps nothing" \
  || fail "H no proxy: rc=$rc out=[$out]"
m=$( . "$BIN/usage-lib.sh" 2>/dev/null; fleet_usage_now() { date +%s; }
     fleet_quota_merge "" 0 "a1 $(date +%s) 30 88 1 2 proxy" | cut -f1,2,3,8)
[ "$m" = "$(printf 'a1\t30\t88\tproxy')" ] && pass "H the quota watch's merge reads @rl_src proxy as source proxy" \
  || fail "H merge: [$m]"

[ "$FAIL" = 0 ] && echo "fleet-proxy-quota-selftest: OK" || echo "fleet-proxy-quota-selftest: FAILED"
exit "$FAIL"
