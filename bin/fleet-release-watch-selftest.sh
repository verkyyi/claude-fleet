#!/bin/bash
# fleet-release-watch-selftest.sh — bin/fleet-release-watch.py (issue #4915): the 15
# minutes after a release, against a fake hub on 127.0.0.1 (health, /healthz, notice).
#
#   A  judge: clean ⇒ ok; the canary's hold `blocked`, a machine that rolled the sha
#      back, 5xx ≥ 20 AND ≥ 5 % of requests, /healthz failing 3 rounds ⇒ bad; 19 5xx,
#      or 25 in 10 000 requests ⇒ still ok
#   B  watch, bad: ONE whole-version rollback (`<stable> --since <prev> --repo …
#      --hub-tag prod-<hub-live7>`), a release-train dispatch, a notice `rolledback`
#      naming the why — the target is the hub's CURRENT stable, never older
#   C  watch, clean for the window ⇒ exit 0, no rollback, no notice
#   D  the rollback fails ⇒ exit 3, notice `rollback-failed`; a 「回退版本 <sha7>」 PR
#      already opened within the hour ⇒ nothing twice; /healthz down 3 rounds ⇒ bad
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
W="$BIN/fleet-release-watch.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }

FAILS=0 CHECKS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
eq()   { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1: want [$2] got [$3]"; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1: no [$3] in: $2" ;; esac; }
hasnt(){ CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1: [$3] in: $2" ;; esac; }

T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-release-watch-selftest.XXXXXX") || exit 1
SRV=''
trap '[ -z "$SRV" ] || { kill "$SRV"; wait "$SRV"; } 2>/dev/null; rm -rf "$T"' EXIT
SHA=$(printf 'b%.0s' $(seq 40)); PREV=$(printf 'a%.0s' $(seq 40)); NEWER=$(printf 'c%.0s' $(seq 40)); LIVE=$(printf 'd%.0s' $(seq 40))

# ── A ──
# (no $(…) around the JSON: bash 3.2 mis-reads escaped quotes inside a command substitution)
j() { printf '%s' "$2" > "$T/h.json"; python3 "$W" judge --health "$T/h.json" ${3:+--healthz-fails "$3"} >/dev/null 2>&1; eq "$1" "$4" "$?"; }
j "A: clean" "{\"sha\":\"$SHA\",\"http\":{\"total\":500,\"errors_5xx\":2}}" "" 0
j "A: the canary blocked it" "{\"sha\":\"$SHA\",\"hold\":{\"sha\":\"$SHA\",\"state\":\"blocked\",\"canary\":\"mini2\"}}" "" 1
j "A: …a hold on another sha says nothing" "{\"sha\":\"$SHA\",\"hold\":{\"sha\":\"$PREV\",\"state\":\"blocked\"}}" "" 0
j "A: a machine rolled it back" "{\"sha\":\"$SHA\",\"rolled_back\":[{\"machine\":\"mac-d\",\"reason\":\"doctor\"}]}" "" 1
j "A: 5xx past the threshold" "{\"sha\":\"$SHA\",\"http\":{\"total\":100,\"errors_5xx\":25}}" "" 1
j "A: 19 5xx is under the count" "{\"sha\":\"$SHA\",\"http\":{\"total\":20,\"errors_5xx\":19}}" "" 0
j "A: 25 in 10 000 is under the share" "{\"sha\":\"$SHA\",\"http\":{\"total\":10000,\"errors_5xx\":25}}" "" 0
j "A: /healthz down 3 rounds" "{\"sha\":\"$SHA\"}" "3" 1
j "A: …2 rounds is not yet" "{\"sha\":\"$SHA\"}" "2" 0

# the fake hub: GET health → $T/health.json · /healthz → 200 unless $T/down · POST
# notice → appended to $T/notices (the bearer must be the token)
cat > "$T/hub.py" <<'PY'
import http.server, os, sys
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body=b"{}"):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.startswith("/healthz"):
            return self._send(500 if os.path.exists(os.path.join(D, "down")) else 200, b"ok")
        if self.path.startswith("/v1/fleet/release/health"):
            if self.headers.get("Authorization") != "Bearer tok":
                return self._send(401)
            open(os.path.join(D, "asked"), "a").write(self.path + "\n")
            return self._send(200, open(os.path.join(D, "health.json"), "rb").read())
        self._send(404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        if self.path == "/v1/fleet/release/notice" and self.headers.get("Authorization") == "Bearer tok":
            open(os.path.join(D, "notices"), "ab").write(body + b"\n")
            return self._send(200, b'{"status":"sent"}')
        self._send(401)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$T/hub.py" "$T" & SRV=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
HUB="http://127.0.0.1:$(cat "$T/port")"

cat > "$T/rollback" <<SH
#!/bin/sh
echo "\$*" >> "$T/rolled"
[ ! -f "$T/rb-fails" ] || { echo "REFUSED — does not revert cleanly" >&2; exit 3; }
echo "rollback: merged"
SH
cat > "$T/gh" <<SH
#!/bin/sh
echo "\$*" >> "$T/gh-calls"
case "\$*" in
  'pr list'*) cat "$T/prs" 2>/dev/null || echo '[]' ;;
  *) : ;;
esac
SH
chmod +x "$T/rollback" "$T/gh"
watch() {
  rm -f "$T/rolled" "$T/gh-calls" "$T/notices" "$T/asked"
  OUT=$(FLEET_PUBLISH_TOKEN=tok FLEET_RELEASE_WATCH_ROLLBACK="$T/rollback" FLEET_RELEASE_WATCH_GH="$T/gh" \
        ACTIONS_ID_TOKEN_REQUEST_URL='' ACTIONS_ID_TOKEN_REQUEST_TOKEN='' RUNNER_TEMP="$T" \
        python3 "$W" watch --sha "$SHA" --prev "$PREV" --hub "$HUB" --repo o/r --run-id 77 "$@" 2>&1); RC=$?
}

# ── B ── the hub 5xxs after the release; stable has moved on to NEWER meanwhile
printf '{"sha":"%s","stable":"%s","http":{"replica":"r1","total":200,"errors_5xx":60}}' "$SHA" "$NEWER" > "$T/health.json"
watch --hub-live "$LIVE" --mins 1 --every 0
eq "B: a bad version exits 1 (rolled back)" 1 "$RC"
eq "B: ONE rollback, the whole version from the current stable" "$NEWER --since $PREV --repo o/r --hub-tag prod-${LIVE:0:7}" "$(cat "$T/rolled" 2>/dev/null)"
has "B: the revert is shipped by a train dispatch" "$(cat "$T/gh-calls" 2>/dev/null)" "workflow run release-train.yml --repo o/r --ref master"
has "B: the health read says since when" "$(cat "$T/asked" 2>/dev/null)" "sha=$SHA&since="
N=$(cat "$T/notices" 2>/dev/null)
has "B: a notice, verdict rolledback" "$N" '"verdict": "rolledback"'
has "B: …naming the why" "$N" "入口 5xx：60 / 200"
has "B: …and the way back" "$N" "已自动回退 ${NEWER:0:7} → ${PREV:0:7}"

# ── C ── clean for the window
printf '{"sha":"%s","stable":"%s","http":{"total":200,"errors_5xx":1}}' "$SHA" "$SHA" > "$T/health.json"
watch --mins 0.02 --every 0
eq "C: a clean window exits 0" 0 "$RC"
eq "C: no rollback" "" "$(cat "$T/rolled" 2>/dev/null)"
eq "C: no notice" "" "$(cat "$T/notices" 2>/dev/null)"
has "C: says it was clean" "$OUT" "clean for"

# ── D ──
printf '{"sha":"%s","stable":"%s","rolled_back":[{"machine":"mac-d","reason":"%s → back"}]}' "$SHA" "$SHA" "${SHA:0:12}" > "$T/health.json"
: > "$T/rb-fails"
watch --mins 1 --every 0
eq "D: a failed rollback exits 3" 3 "$RC"
has "D: …a notice rollback-failed" "$(cat "$T/notices" 2>/dev/null)" '"verdict": "rollback-failed"'
has "D: …saying a person must act" "$(cat "$T/notices" 2>/dev/null)" "请手动"
hasnt "D: …and no train dispatched" "$(cat "$T/gh-calls" 2>/dev/null)" "workflow run"
rm -f "$T/rb-fails"
printf '[{"title":"回退版本 %s → %s：#1","url":"https://x/pull/9","createdAt":"%s"}]' "${SHA:0:7}" "${PREV:0:7}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T/prs"
watch --mins 1 --every 0
eq "D: already rolled back ⇒ exit 0" 0 "$RC"
eq "D: …nothing twice" "" "$(cat "$T/rolled" 2>/dev/null)"
has "D: …saying where" "$OUT" "already rolled back: https://x/pull/9"
rm -f "$T/prs"
printf '{"sha":"%s","stable":"%s"}' "$SHA" "$SHA" > "$T/health.json"
: > "$T/down"
watch --mins 1 --every 0
eq "D: /healthz down 3 rounds rolls back" 1 "$RC"
has "D: …saying so" "$(cat "$T/notices" 2>/dev/null)" "/healthz 连续 3 次失败"

[ "$FAILS" -eq 0 ] && { printf 'fleet-release-watch-selftest OK (%d checks)\n' "$CHECKS"; exit 0; }
printf 'fleet-release-watch-selftest: %d of %d checks failed\n' "$FAILS" "$CHECKS"; exit 1
