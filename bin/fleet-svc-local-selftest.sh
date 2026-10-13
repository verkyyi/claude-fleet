#!/bin/bash
# fleet-svc-local-selftest.sh — one service run on THIS machine, as the service
# login (issue #4086): bin/fleet-svc-local.sh around bin/fleet-svc-runner.py,
# against a stand-in hub on 127.0.0.1 and a stand-in claude that tries to leave
# things behind. docs/dev/BREAK-IT.md row `svc-run-leaks-across-runs`.
#
#   A. run      the attempt fetches its spec, runs, hands in exit 0 once
#   B. gone     after it: no run directory, no process carrying its tag — not the
#               backgrounded `sleep`, not the one that setsid()-ed out of the group
#   C. apart    the next run sees nothing of the last one: its directory is gone,
#               its HOME / TMPDIR are new; the session's environment holds neither
#               the key nor its path, and its settings deny reading the key, the
#               pass and the login's own dot directories
#   D. killed   an attempt SIGKILLed mid-run (the agent's deadline / cancel) leaves
#               its directory and a straggler; `clean <R> <k>` removes both
#   E. twice    an attempt whose directory exists already is refused (exit 3) —
#               a redelivered start never shares a directory
# No network beyond 127.0.0.1, no claude, no root. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
L="$BIN/fleet-svc-local.sh"
command -v python3 >/dev/null 2>&1 || { echo 'svc-local selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/svc-local-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
HUBPID=""
cleanup() {
  [ -n "$HUBPID" ] && kill "$HUBPID" 2>/dev/null
  pkill -f "sleep 3007$" 2>/dev/null; pkill -f "time.sleep.3008" 2>/dev/null; pkill -f "sleep 3009$" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }
[ -f "$L" ] || { echo "FAIL bin/fleet-svc-local.sh is missing"; exit 1; }

# ---- the stand-in hub: spec once per attempt, every result recorded
cat > "$WORK/hub.py" <<'PY'
import json, sys, http.server
W = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, st, obj):
        b = json.dumps(obj).encode(); self.send_response(st)
        self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer ' + open(W + '/key').read().strip():
            return self._send(401, {'error': 'key'})
        self._send(200, {'agent_md': '---\nname: report\n---\nwrite the report\n',
                         'inputs': {'request': 'r'}, 'pass': 'fcp-h1.drillpass'})
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        with open(W + '/results', 'a') as f:
            f.write(self.path + ' ' + self.rfile.read(n).decode() + '\n')
        self._send(200, {'state': 'succeeded'})
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(W + '/port', 'w').write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$WORK/hub.py" "$WORK" & HUBPID=$!
for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "FAIL the stand-in hub did not start"; exit 1; }
HUB="http://127.0.0.1:$(cat "$WORK/port")"

# ---- the stand-in claude: leaves files, a child, a setsid()-ed grandchild
mkdir -p "$WORK/bin"
cat > "$WORK/bin/claude" <<'SH'
#!/bin/bash
[ "${1:-}" = --help ] && { echo '  --agent <name>   the agent'; exit 0; }
out=""; prev_a=""
for a in "$@"; do [ "$prev_a" = --add-dir ] && out=$a; prev_a=$a; done
n=$(cat "$DRILL/n")
echo secret > "$HOME/leak-$n"; echo x > "${TMPDIR:-/tmp}/leak-$n"
sleep 3007 </dev/null >/dev/null 2>&1 &
python3 -c 'import os,time; os.setsid(); time.sleep(3008)' </dev/null >/dev/null 2>&1 &
prev=$(cat "$DRILL/prev-dir" 2>/dev/null || true); seen=no
[ -n "$prev" ] && [ -e "$prev" ] && seen=yes
[ -n "$prev" ] && [ -e "$prev/home/leak-$((n-1))" ] && seen=yes
echo "$seen" > "$DRILL/seen-$n"
dirname "$PWD" > "$DRILL/prev-dir"
env > "$DRILL/env-$n"
cp "$HOME/.claude/settings.json" "$DRILL/settings-$n" 2>/dev/null
[ "${DRILL_HANG:-0}" = 1 ] && { sleep 3009 & wait; }
printf '# report %s\n' "$n" > "$out/report.md"
printf '{"title":"t","summary":"s"}' > "$out/meta.json"
echo '{"type":"result","is_error":false,"usage":{"input_tokens":1,"output_tokens":1}}'
SH
chmod 755 "$WORK/bin/claude"
export DRILL="$WORK" FLEET_SVC_CLAUDE="$WORK/bin/claude" FLEET_SVC_RUNS_DIR="$WORK/runs"
KEY="fsj_$(printf 'a%.0s' $(seq 1 52))"
printf '%s\n' "$KEY" > "$WORK/key"

one() {  # one attempt: R<n> a<k>, the key on stdin
  printf '%s\n' "$KEY" | FLEET_SVC_RUN="R$1" FLEET_SVC_ATTEMPT="$2" FLEET_SVC_DEADLINE=120 \
    FLEET_SVC_HUB="$HUB" FLEET_SVC_CENTRAL="$HUB" bash "$L" run >"$WORK/run-$1.out" 2>&1
}
left() { pgrep -f "sleep 3007$" >/dev/null 2>&1 || pgrep -f "time.sleep.3008" >/dev/null 2>&1 || pgrep -f "sleep 3009$" >/dev/null 2>&1; }
settle() { for _ in $(seq 30); do left || return 0; sleep 0.1; done; return 1; }

# A + B
echo 1 > "$WORK/n"; one 1 1; rc=$?
[ "$rc" = 0 ] && grep -q '^/v1/node/svc-runs/R1/result .*"exit": 0' "$WORK/results" \
  && [ "$(grep -c '^/v1/node/svc-runs/R1/result' "$WORK/results")" = 1 ] \
  && ok "A run 1 handed in exit 0 once" || bad "A run 1 rc=$rc: $(tail -3 "$WORK/run-1.out" | tr '\n' ' ') results=$(cat "$WORK/results" 2>/dev/null)"
[ -z "$(ls -A "$WORK/runs" 2>/dev/null)" ] && ok "B no run directory left" || bad "B left: $(ls -A "$WORK/runs")"
settle && ok "B no process of the run left (child + setsid grandchild)" || bad "B a process outlived the run: $(pgrep -fl 'sleep 300[789]|time.sleep.3008' | head -3)"

# C
echo 2 > "$WORK/n"; one 2 1; rc=$?
[ "$rc" = 0 ] && ok "C run 2 handed in" || bad "C run 2 rc=$rc: $(tail -3 "$WORK/run-2.out" | tr '\n' ' ')"
[ "$(cat "$WORK/seen-2" 2>/dev/null)" = no ] && ok "C run 2 saw nothing of run 1" || bad "C run 2 saw run 1: $(cat "$WORK/seen-2" 2>/dev/null)"
if grep -q "$KEY" "$WORK/env-2" || grep -q 'FLEET_SVC_KEY_FILE\|FLEET_SVC_HUB' "$WORK/env-2"; then
  bad "C the session's environment holds the key or its road"
else ok "C the session's environment holds neither the key nor the hub's road"; fi
if python3 - "$WORK/settings-2" <<'PY'
import json, sys
deny = json.load(open(sys.argv[1]))['permissions']['deny']
need = ['/key)', '/run/**)', '/.config/**)', '/.ssh/**)', '/.claude/**)']
sys.exit(0 if all(any(d.startswith('Read(//') and d.endswith(n) for d in deny) for n in need) else 1)
PY
then ok "C the session's settings deny the key, the pass and the login's dot directories"
else bad "C settings deny: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["permissions"]["deny"])' "$WORK/settings-2" 2>&1)"; fi
settle || bad "C a process of run 2 outlived it"

# D
echo 3 > "$WORK/n"
( DRILL_HANG=1 FLEET_SVC_RUN=R3 FLEET_SVC_ATTEMPT=1 FLEET_SVC_DEADLINE=120 \
    FLEET_SVC_HUB="$HUB" FLEET_SVC_CENTRAL="$HUB" exec python3 -c 'import os,sys; os.setpgid(0,0); os.execvp(sys.argv[1], sys.argv[1:])' bash "$L" run <"$WORK/key" >"$WORK/run-3.out" 2>&1 ) &
pg=$!
for _ in $(seq 100); do pgrep -f "sleep 3009$" >/dev/null 2>&1 && break; sleep 0.1; done
kill -KILL -- "-$pg" 2>/dev/null; wait "$pg" 2>/dev/null
if [ -d "$WORK/runs/R3-a1" ]; then ok "D a SIGKILLed attempt left its directory (the agent cleans it)"
else bad "D a SIGKILLed attempt left no directory — the drill could not exercise clean: $(tail -3 "$WORK/run-3.out" | tr "\n" " ")"; fi
bash "$L" clean R3 1 >"$WORK/clean.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$WORK/runs/R3-a1" ] && ok "D clean removed its directory" || bad "D clean rc=$rc: $(cat "$WORK/clean.out")"
settle && ok "D clean killed its stragglers" || bad "D a straggler outlived clean: $(pgrep -fl 'sleep 300[789]|time.sleep.3008' | head -3)"

# E
mkdir -p "$WORK/runs/R4-a1"
echo 4 > "$WORK/n"; one 4 1; rc=$?
[ "$rc" = 3 ] && [ -d "$WORK/runs/R4-a1" ] && ! grep -q 'R4/result' "$WORK/results" \
  && ok "E a second start of one attempt is refused, the first's directory untouched" || bad "E rc=$rc"
rmdir "$WORK/runs/R4-a1"

[ "$fail" = 0 ] && echo "svc-local selftest: PASS" || echo "svc-local selftest: FAIL"
exit "$fail"
