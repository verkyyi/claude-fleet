#!/bin/bash
# fleet-node-maintenance-selftest.sh — bin/fleet-node-maintenance.sh (issue
# #1427): this machine's 维护中 flag on the hub, with the transport stubbed
# through FLEET_HUB_CURL and the node token in a sandbox node.env — no hub, no
# network, no tmux.
#
# What it pins:
#   A. off       CCQUOTA_FLEET unset: exit 10, curl NEVER called, one stderr
#                line — the single-machine degenerate case touches nothing
#   B. no token  module on, no node.env: exit 1 with the `no node token` phrase
#                and the fix; curl never called
#   C. enter     POST /v1/node/maintenance {"action":"enter","reason":…} with
#                the bearer token FROM node.env (the caller's environment has
#                none, and gets none back), Content-Type json, a reason with
#                quotes and CJK intact; prints `ENTERED m5 · <reason> · since …
#                · by …`; exit 0
#   D. status    GET (no body, no -X POST); online → `m5 online`; flagged →
#                `m5 maintenance · <reason> · since …`
#   E. leave     POST {"action":"leave"}; prints `LEFT m5`; exit 0
#   F. old hub   404 → exit 4 and the "predates issue #1427" note; 409 → exit 4
#                naming the agent; 401 → exit 4 naming the token
#   G. down      curl fails (exit 7): exit 1, `hub unreachable`, nothing printed
#                on stdout
#   H. usage     no action / two actions / --reason with leave / a 201-char
#                reason: exit 2, curl never called
#   I. no leak   CCQUOTA_TOKEN is not in the environment of anything the script
#                leaves behind (the token is exported inside one subshell only)
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$BIN/fleet-node-maintenance.sh"
CHECKS=0
fail() { printf 'fleet-node-maintenance selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-maintenance-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT

# The stub curl: records argv + the body it was given, answers per FAKE_CODE
# (HTTP code) and FAKE_BODY (JSON), or fails with FAKE_RC.
STUB="$WORK/curl"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_LOG"
body=''
while [ $# -gt 0 ]; do case "$1" in --data-binary) body="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' "$body" > "$STUB_BODY"
env | grep '^CCQUOTA_TOKEN=' > "$STUB_ENV" || :
[ "${FAKE_RC:-0}" -eq 0 ] || exit "$FAKE_RC"
printf '%s\n%s' "${FAKE_BODY:-{\}}" "${FAKE_CODE:-200}"
EOF
chmod +x "$STUB"
export STUB_LOG="$WORK/curl.log" STUB_BODY="$WORK/curl.body" STUB_ENV="$WORK/curl.env" FLEET_HUB_CURL="$STUB"
reset() { rm -f "$STUB_LOG" "$STUB_BODY" "$STUB_ENV"; }

ONLINE='{"machine":"m5","status":"online","maintenance":null}'
FLAGGED='{"machine":"m5","status":"maintenance","maintenance":{"machine":"m5","reason":"升级 macOS \"Tahoe\"","since":"2026-10-05T12:00:00Z","by":"node:verkyyi@m5"}}'

# A. off
reset
out=$("$SUT" enter 2>"$WORK/err"); rc=$?
[ "$rc" -eq 10 ] || fail "A: exit $rc, want 10 with the module off"
[ ! -e "$STUB_LOG" ] || fail "A: curl was called with the module off: $(cat "$STUB_LOG")"
grep -q 'module is off' "$WORK/err" || fail "A: stderr: $(cat "$WORK/err")"
[ -z "$out" ] || fail "A: stdout should be empty, got: $out"
ok

export CCQUOTA_FLEET=1

# B. no token
reset
out=$("$SUT" status 2>"$WORK/err"); rc=$?
[ "$rc" -eq 1 ] || fail "B: exit $rc, want 1 without node.env"
{ grep -q 'no node token' "$WORK/err" && grep -q 'node.env missing' "$WORK/err"; } || fail "B: stderr: $(cat "$WORK/err")"
grep -q 'fleet-hub-node.sh env --write' "$WORK/err" || fail "B: no fix named: $(cat "$WORK/err")"
[ ! -e "$STUB_LOG" ] || fail "B: curl was called without a token"
ok

# node.env from here on: the token lives in the file, NOT in our environment
printf 'CCQUOTA_HUB_URL=https://hub.example/\nCCQUOTA_TOKEN=tok-m5-secret\nCCQUOTA_FLEET=1\n' > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"

# C. enter
reset
out=$(FAKE_BODY="$FLAGGED" "$SUT" enter --reason '升级 macOS "Tahoe"' 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || fail "C: exit $rc: $out / $(cat "$WORK/err")"
[ "$out" = 'maintenance: ENTERED m5 · 升级 macOS "Tahoe" · since 2026-10-05T12:00:00Z · by node:verkyyi@m5' ] || fail "C: line: $out"
grep -q -- '-X POST' "$STUB_LOG" || fail "C: not a POST: $(cat "$STUB_LOG")"
grep -q 'https://hub.example/v1/node/maintenance' "$STUB_LOG" || fail "C: url (trailing slash folded): $(cat "$STUB_LOG")"
grep -q 'Authorization: Bearer tok-m5-secret' "$STUB_LOG" || fail "C: bearer from node.env missing: $(cat "$STUB_LOG")"
grep -q 'Content-Type: application/json' "$STUB_LOG" || fail "C: content type: $(cat "$STUB_LOG")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d=={"action":"enter","reason":"升级 macOS \"Tahoe\""}, d' "$STUB_BODY" || fail "C: body: $(cat "$STUB_BODY")"
[ -z "${CCQUOTA_TOKEN:-}" ] || fail "C: the token leaked into THIS shell"
ok

# D. status
reset
out=$(FAKE_BODY="$ONLINE" "$SUT" status 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = 'maintenance: m5 online' ]; } || fail "D: online: rc=$rc [$out]"
grep -q -- '-X POST' "$STUB_LOG" && fail "D: status must be a GET: $(cat "$STUB_LOG")"
[ ! -s "$STUB_BODY" ] || fail "D: status sent a body: $(cat "$STUB_BODY")"
out=$(FAKE_BODY="$FLAGGED" "$SUT" status 2>"$WORK/err")
[ "$out" = 'maintenance: m5 maintenance · 升级 macOS "Tahoe" · since 2026-10-05T12:00:00Z · by node:verkyyi@m5' ] || fail "D: flagged: [$out]"
ok

# E. leave
reset
out=$(FAKE_BODY="$ONLINE" "$SUT" leave 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = 'maintenance: LEFT m5' ]; } || fail "E: rc=$rc [$out]"
[ "$(cat "$STUB_BODY")" = '{"action":"leave"}' ] || fail "E: body: $(cat "$STUB_BODY")"
ok

# F. an older hub, an unknown node, a bad token
reset
out=$(FAKE_CODE=404 FAKE_BODY='not found' "$SUT" enter 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 4 ] && [ -z "$out" ]; } || fail "F: 404 rc=$rc [$out]"
{ grep -q 'predates issue #1427' "$WORK/err" && grep -q 'redeploy' "$WORK/err"; } || fail "F: 404 stderr: $(cat "$WORK/err")"
out=$(FAKE_CODE=409 FAKE_BODY='{"error":"not reported"}' "$SUT" enter 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 4 ] && grep -q 'never heard this node' "$WORK/err"; } || fail "F: 409 rc=$rc $(cat "$WORK/err")"
out=$(FAKE_CODE=401 FAKE_BODY='{"error":"bad token"}' "$SUT" status 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 4 ] && grep -q 'node token' "$WORK/err"; } || fail "F: 401 rc=$rc $(cat "$WORK/err")"
out=$(FAKE_CODE=500 FAKE_BODY='boom' "$SUT" status 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 4 ] && grep -q 'HTTP 500: boom' "$WORK/err"; } || fail "F: 500 rc=$rc $(cat "$WORK/err")"
ok

# G. hub down
reset
out=$(FAKE_RC=7 "$SUT" enter 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } || fail "G: rc=$rc [$out]"
{ grep -q 'hub unreachable (https://hub.example/)' "$WORK/err" && grep -q 'nothing changed' "$WORK/err"; } || fail "G: stderr: $(cat "$WORK/err")"
ok

# H. usage
for args in '' 'enter leave' 'leave --reason x' 'drain'; do
  reset
  # shellcheck disable=SC2086
  out=$("$SUT" $args 2>"$WORK/err"); rc=$?
  [ "$rc" -eq 2 ] || fail "H: [$args] exit $rc, want 2: $(cat "$WORK/err")"
  [ ! -e "$STUB_LOG" ] || fail "H: [$args] reached curl"
done
long=$(printf '%*s' 201 '' | tr ' ' 'x')
out=$("$SUT" enter --reason "$long" 2>"$WORK/err"); rc=$?
{ [ "$rc" -eq 2 ] && grep -q '200 characters' "$WORK/err"; } || fail "H: long reason rc=$rc $(cat "$WORK/err")"
ok

# I. no leak: the token reached curl (it must) but nothing else
reset
FAKE_BODY="$ONLINE" "$SUT" status >/dev/null 2>&1
grep -q '^CCQUOTA_TOKEN=tok-m5-secret$' "$STUB_ENV" || fail "I: curl ran without the token in its environment"
[ -z "${CCQUOTA_TOKEN:-}" ] || fail "I: token in the caller's environment"
ok

printf 'selftest OK: %s checks passed (fleet-node-maintenance)\n' "$CHECKS"
