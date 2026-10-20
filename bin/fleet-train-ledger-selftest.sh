#!/usr/bin/env bash
# fleet-train-ledger-selftest.sh — bin/fleet-train-ledger.py (issue #3870, EPIC
# #3863 C7): every release-train run into the hub's ledger, shipped or not.
#   A  build folds a run's jobs into stages (shards → one span, skipped / the
#      ledger itself left out, the runner wait kept), reads the merges and the
#      first FAIL test (shards in number order; FLAKY / QUARANTINE are not red),
#      and ends the run at its last on-path stage (the node image beside it no)
#   B  build --mac: one `mac follow` stage hung on the train run
#   C  post: the bearer goes in a header, never the argv; the hub's 「卡在…」 line
#      lands on the summary; refused = 1, unreachable = 3
#   D  release-train.yml's `ledger` job runs always(), never reds, the move ignores
#      it, the release step builds its train part with the same script, and
#      mac-follow posts its stage
#   E  the off-path stages are the hub's (fleet_release_runs.go stageOffPath)
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/selftest-lib.sh"
L="$BIN/fleet-train-ledger.py"
ROOT="$BIN/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/train-ledger.XXXXXX")
trap 'kill "${HUB_PID:-}" 2>/dev/null; rm -rf "$T"' EXIT
fail=0
no() { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { if eval "$2"; then st_ok "$1"; else no "$1"; fi; }
eq() { if [ "$2" = "$3" ]; then st_ok "$1"; else no "$1 — got [$2], want [$3]"; fi; }
jq_() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2"; }

# ---- A: build ----
cat > "$T/jobs.ndjson" <<'J'
{"name":"board","status":"completed","conclusion":"success","created_at":"2026-10-13T08:00:00Z","started_at":"2026-10-13T08:00:05Z","completed_at":"2026-10-13T08:00:15Z"}
{"name":"Linux / shard 1","status":"completed","conclusion":"success","created_at":"2026-10-13T08:00:20Z","started_at":"2026-10-13T08:00:30Z","completed_at":"2026-10-13T08:02:00Z"}
{"name":"Linux / shard 2","status":"completed","conclusion":"failure","created_at":"2026-10-13T08:00:20Z","started_at":"2026-10-13T08:01:00Z","completed_at":"2026-10-13T08:04:20Z"}
{"name":"precheck","status":"completed","conclusion":"cancelled","created_at":"2026-10-13T08:00:20Z","started_at":"2026-10-13T08:00:25Z","completed_at":"2026-10-13T08:01:00Z"}
{"name":"hub plan","status":"completed","conclusion":"skipped","created_at":"2026-10-13T08:04:30Z","started_at":"2026-10-13T08:04:30Z","completed_at":"2026-10-13T08:04:30Z"}
{"name":"node image","status":"in_progress","conclusion":null,"created_at":"2026-10-13T08:04:30Z","started_at":"2026-10-13T08:04:40Z","completed_at":null}
{"name":"ledger","status":"in_progress","conclusion":null,"created_at":"2026-10-13T08:04:30Z","started_at":"2026-10-13T08:04:31Z","completed_at":null}
J
mkdir -p "$T/results/train-result-Linux-10" "$T/results/train-result-Linux-2"
printf 'TIMEOUT late-selftest.sh                       480s (limit 480s)\n' > "$T/results/train-result-Linux-10/train-result.txt"
printf 'FLAKY flaky-selftest.sh 2s\nQUARANTINE q-selftest.sh\nFAIL B snippet: a test of its own\nFAIL  dash-marker-selftest.sh                         4.2s (exit 1)\n' > "$T/results/train-result-Linux-2/train-result.txt"
SHA=$(printf 'ab%.0s' $(seq 20)); M=$(printf 'cd%.0s' $(seq 20))
MERGES="[{\"sha\":\"$M\",\"subject\":\"a change\",\"committed\":\"2026-10-13T07:58:00Z\"}]" \
  python3 "$L" build --jobs "$T/jobs.ndjson" --results "$T/results" --run-id 901 --sha "$SHA" \
    --conclusion failure --exclude ledger > "$T/run.json" 2> "$T/err"
check "A build answers JSON" "[ -s '$T/run.json' ] && python3 -c 'import json; json.load(open(\"$T/run.json\"))'"
eq "A shards fold into one Linux span, red" "$(jq_ "$T/run.json" "[(s['started_at'], s['ended_at'], s['result'], s['queue_secs']) for s in d['stages'] if s['name']=='Linux']")" "[('2026-10-13T08:00:30Z', '2026-10-13T08:04:20Z', 'failure', 40.0)]"
eq "A skipped and the ledger are no stage" "$(jq_ "$T/run.json" "','.join(s['name'] for s in d['stages'])")" 'board,precheck,Linux,node image'
eq "A cancelled kept apart from red" "$(jq_ "$T/run.json" "[s['result'] for s in d['stages'] if s['name']=='precheck'][0]")" cancelled
eq "A the run: first created → last on-path end" "$(jq_ "$T/run.json" "d['started_at']+' '+d['ended_at']")" '2026-10-13T08:00:00Z 2026-10-13T08:04:20Z'
eq "A first FAIL by shard number, the runner's own line (FLAKY / a test's FAIL not)" "$(jq_ "$T/run.json" "d['first_fail']")" dash-marker-selftest.sh
eq "A merges carry time and subject" "$(jq_ "$T/run.json" "d['merges'][0]['merged_at']+' '+d['merges'][0]['subject']")" '2026-10-13T07:58:00Z a change'
check "A a bad conclusion refuses" "! python3 '$L' build --jobs '$T/jobs.ndjson' --conclusion maybe >/dev/null 2>&1"
python3 "$L" build --jobs "$T/jobs.ndjson" --sha "$SHA" > "$T/train.json" 2>/dev/null
eq "A no --conclusion = success (the publish's train part)" "$(jq_ "$T/train.json" "d['conclusion']+' '+str(len(d['merges']))")" 'success 0'

# ---- B: build --mac ----
python3 "$L" build --mac --train-run 901 --jobs "$T/jobs.ndjson" --run-id 950 --conclusion success --exclude ledger > "$T/mac.json" 2>/dev/null
eq "B the Mac stage hangs on the train run" "$(jq_ "$T/mac.json" "d['train_run_id']+' '+d['run_id']+' '+d['stages'][0]['name']")" '901 950 mac follow'
check "B --mac needs --train-run" "! python3 '$L' build --mac --jobs '$T/jobs.ndjson' >/dev/null 2>&1"

# ---- C: post, to a hub on loopback ----
cat > "$T/hub.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(sys.argv[2], "a").write(self.headers.get("Authorization", "") + "\n")
        run = json.loads(body)
        if run.get("run_id") == "bad":
            self.send_response(400); self.end_headers(); self.wfile.write(b"conclusion: no"); return
        ans = {"status": "recorded", "total_secs": 260,
               "bottleneck": {"stage": "Linux", "secs": 230, "why": "dash-marker-selftest.sh"}}
        b = json.dumps(ans, ensure_ascii=False).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$T/hub.py" "$T/port" "$T/auth" & HUB_PID=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
: > "$T/summary"
env -u ACTIONS_ID_TOKEN_REQUEST_URL FLEET_PUBLISH_TOKEN=tok-xyz python3 "$L" post "$T/run.json" --hub "http://127.0.0.1:$PORT" --summary "$T/summary" > "$T/ans" 2>&1
rc=$?
check "C recorded = 0" "[ $rc = 0 ]"
check "C the bearer in the header" "grep -qx 'Bearer tok-xyz' '$T/auth'"
check "C the hub's line on the summary" "grep -q '卡在「Linux」：3 分 50 秒——dash-marker-selftest.sh（共 4 分 20 秒）' '$T/summary'"
python3 -c "import json; d=json.load(open('$T/run.json')); d['run_id']='bad'; json.dump(d, open('$T/bad.json','w'))"
env -u ACTIONS_ID_TOKEN_REQUEST_URL FLEET_PUBLISH_TOKEN=tok-xyz python3 "$L" post "$T/bad.json" --hub "http://127.0.0.1:$PORT" >/dev/null 2>&1
check "C refused = 1" "[ $? = 1 ]"
kill "$HUB_PID" 2>/dev/null; wait "$HUB_PID" 2>/dev/null
env -u ACTIONS_ID_TOKEN_REQUEST_URL FLEET_PUBLISH_TOKEN=tok-xyz python3 "$L" post "$T/run.json" --hub "http://127.0.0.1:$PORT" >/dev/null 2>&1
check "C unreachable = 3" "[ $? = 3 ]"
env -u ACTIONS_ID_TOKEN_REQUEST_URL -u FLEET_PUBLISH_TOKEN python3 "$L" post "$T/run.json" --hub "http://127.0.0.1:$PORT" >/dev/null 2>&1
check "C no identity = 3" "[ $? = 3 ]"
printf '{"status":"recorded","total_secs":190}' > "$T/quick.json"
eq "C a quick train says so" "$(python3 "$L" line "$T/quick.json")" '### 🚂 本趟 3 分 10 秒，没超 5 分钟'

# ---- D: the workflows ----
wf="$ROOT/.github/workflows/release-train.yml"; mf="$ROOT/.github/workflows/mac-follow.yml"
job=$(awk '/^  ledger:$/{on=1;next} on&&/^  [a-z-]+:$/{exit} on' "$wf")
printf '%s\n' "$job" > "$T/ledger.job"
check "D release-train has a ledger job" "[ -s '$T/ledger.job' ]"
check "D it runs always()" "grep -q \"if: always() && needs.board.outputs.skip == 'false'\" '$T/ledger.job'"
check "D it waits for release" "grep -q 'needs: \[.*release\]' '$T/ledger.job'"
check "D it posts with this run's OIDC" "grep -q 'id-token: write' '$T/ledger.job' && grep -q 'fleet-train-ledger.py post' '$T/ledger.job'"
n=$(grep -c -e '|| echo "::warning::' -e '|| { echo "::warning::' "$T/ledger.job")
check "D it never reds (each call falls back to a warning)" "! grep -q 'exit 1' '$T/ledger.job' && [ $n -ge 3 ]"
check "D the move ignores it" "grep -q -- \"--ignore-check ledger\" '$wf'"
check "D the release step builds its train part with the same script" "awk '/^  release:\$/{on=1} /^  ledger:\$/{on=0} on' '$wf' | grep -q 'fleet-train-ledger.py build --jobs jobs.ndjson'"
check "D mac-follow posts its stage" "grep -q 'fleet-train-ledger.py build --mac --train-run' '$mf' && grep -q 'id-token: write' '$mf'"

# ---- E: one list of what is never the bottleneck ----
py=$(python3 -c "import importlib.util as u; s=u.spec_from_file_location('l','$L'); m=u.module_from_spec(s); s.loader.exec_module(m); print(' '.join(sorted(m.OFF_PATH, key=lambda x: x.encode())))")
go=$(awk '/^var stageOffPath/{on=1} on{print} on&&/^}/{exit}' "$ROOT/tokenledger/hub/api/fleet_release_runs.go" |
  grep -o '"[^"]*": true' | sed 's/": true//; s/^"//'; grep -q 'stageMacFollow: true' "$ROOT/tokenledger/hub/api/fleet_release_runs.go" && echo 'mac follow')
go=$(printf '%s\n' "$go" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
eq "E off-path stages: script = hub" "$py" "$go"

[ "$fail" = 0 ] && echo "fleet-train-ledger-selftest: PASS" || { echo "fleet-train-ledger-selftest: FAIL"; exit 1; }
