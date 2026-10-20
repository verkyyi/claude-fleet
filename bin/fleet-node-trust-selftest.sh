#!/bin/bash
# fleet-node-trust-selftest.sh — bin/fleet-node-trust.sh (issue #1968): the
# operator's trust switch for a machine, with the transport stubbed through
# FLEET_HUB_CURL — no hub, no network, no tmux.
#
# What it pins:
#   A. usage     no action / unknown action / a bad value / a bad name / extra
#                args: exit 2, curl never called
#   B. no token  set / status with no CCQUOTA_VIEWER_TOKEN: exit 1 naming it,
#                curl never called; no hub URL: exit 1
#   C. set       PUT /v1/fleet/settings {"key":"fleet.node_trust.mac-n","value":
#                "trusted"} (a full name `MAC-N.local` folds to `mac-n`), the bearer on
#                curl's STDIN (`-H @-`) — never in its argv; prints `SET mac-n
#                trusted`; exit 0
#   D. old hub   a 200 whose effective map lacks the key: exit 4, "predates"
#   E. status    the roster's machines with their trust + a machine only the
#                settings name; `status mac-b` filters; an unknown machine reads
#                untrusted; a roster with no trust word → exit 4
#   F. refused   401 / 403 → exit 4 "not the operator"; 400 → exit 4
#   G. down      curl fails: exit 1 `hub unreachable`, nothing on stdout
#   H. self      module off → exit 10, curl never called; node.env token →
#                GET /v1/node/self, prints `mac-a trusted`; no trust → exit 4
#   I. no leak   neither token is in any curl argv, and the viewer token is
#                written to no file under HOME / FLEET_CONF_DIR
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/selftest-lib.sh"
SUT="$BIN/fleet-node-trust.sh"
CHECKS=0

st_sandbox "${TMPDIR:-/tmp}/fleet-node-trust-selftest.XXXXXX"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT

. "$BIN/selftest-hub-curl.sh"   # the stub curl: reset · fake <name> <body> [code]
hc_stub by-path

VIEWER='viewer-SECRET-1968'
NODETOK='node-SECRET-1968'

# A. usage
for args in '' 'frob' 'set mac-n maybe' 'set mac-n' 'set "bad name!" trusted' 'status mac-a mac-b' 'self extra'; do
  reset
  eval "\"\$SUT\" $args" >/dev/null 2>"$WORK/err"; rc=$?
  [ "$rc" -eq 2 ] || st_fail "A: '$args' exit $rc, want 2: $(cat "$WORK/err")"
  [ ! -e "$STUB_LOG" ] || st_fail "A: '$args' called curl"
done
st_count

# B. no token / no URL
reset
"$SUT" set mac-n trusted >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CCQUOTA_VIEWER_TOKEN' "$WORK/err" || st_fail "B: no token: exit $rc $(cat "$WORK/err")"
[ ! -e "$STUB_LOG" ] || st_fail "B: curl called without a token"
CCQUOTA_VIEWER_TOKEN=$VIEWER "$SUT" status >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no hub URL' "$WORK/err" || st_fail "B: no URL: exit $rc $(cat "$WORK/err")"
[ ! -e "$STUB_LOG" ] || st_fail "B: curl called without a URL"
st_count

export CCQUOTA_VIEWER_TOKEN=$VIEWER CCQUOTA_HUB_URL=http://hub.test/

# C. set
reset
fake settings '{"settings":{"fleet.node_trust.mac-n":"trusted"},"effective":{"fleet.node_trust.mac-n":"trusted"}}'
out=$("$SUT" set MAC-N.local trusted 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || st_fail "C: exit $rc: $(cat "$WORK/err")"
[ "$out" = 'trust: SET mac-n trusted' ] || st_fail "C: stdout: $out"
grep -qx 'PUT http://hub.test/v1/fleet/settings {"key":"fleet.node_trust.mac-n","value":"trusted"}' "$STUB_BODY" || st_fail "C: request: $(cat "$STUB_BODY")"
grep -qx "Authorization: Bearer $VIEWER" "$STUB_HDR" || st_fail "C: header: $(cat "$STUB_HDR")"
st_count

# D. old hub: 200 without the key
reset
fake settings '{"settings":{},"effective":{}}'
"$SUT" set mac-n untrusted >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'predates' "$WORK/err" || st_fail "D: exit $rc $(cat "$WORK/err")"
st_count

# E. status
reset
fake nodes '{"nodes":[{"hostname":"mac-a.local","trust":"trusted"},{"hostname":"mac-a.local","trust":"trusted"},{"hostname":"mac-b","trust":"untrusted"}]}'
fake settings '{"settings":{"fleet.node_trust.mac-n":"trusted","fleet.node_cap.mac-a":"8"}}'
out=$("$SUT" status 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || st_fail "E: exit $rc: $(cat "$WORK/err")"
[ "$out" = "$(printf 'trust: mac-a trusted\ntrust: mac-b untrusted\ntrust: mac-n trusted')" ] || st_fail "E: stdout: $out"
[ "$("$SUT" status mac-b.local 2>/dev/null)" = 'trust: mac-b untrusted' ] || st_fail "E: filter mac-b"
[ "$("$SUT" status mac-l 2>/dev/null)" = 'trust: mac-l untrusted' ] || st_fail "E: unknown machine"
fake nodes '{"nodes":[{"hostname":"mac-a"}]}'
"$SUT" status >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'predates' "$WORK/err" || st_fail "E: old roster: exit $rc $(cat "$WORK/err")"
st_count

# F. refused
for c in 401 403; do
  reset; fake settings '{"error":"only the operator"}' "$c"
  "$SUT" set mac-n trusted >/dev/null 2>"$WORK/err"; rc=$?
  [ "$rc" -eq 4 ] && grep -q 'not the operator' "$WORK/err" || st_fail "F: $c exit $rc $(cat "$WORK/err")"
done
reset; fake settings '{"error":"bad"}' 400
"$SUT" set mac-n trusted >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] || st_fail "F: 400 exit $rc"
st_count

# G. down
reset; export FAKE_RC=7
out=$("$SUT" status 2>"$WORK/err"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'hub unreachable' "$WORK/err" && [ -z "$out" ] || st_fail "G: exit $rc out=$out $(cat "$WORK/err")"
unset FAKE_RC
st_count

# H. self
reset
"$SUT" self >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 10 ] && [ ! -e "$STUB_LOG" ] || st_fail "H: module off: exit $rc"
export CCQUOTA_FLEET=1
unset CCQUOTA_HUB_URL
printf 'CCQUOTA_TOKEN=%s\nCCQUOTA_HUB_URL=http://hub.test\n' "$NODETOK" > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"
fake self '{"hostname":"mac-a.local","status":"online","trust":"trusted"}'
out=$("$SUT" self 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'trust: mac-a trusted' ] || st_fail "H: exit $rc out=$out $(cat "$WORK/err")"
grep -qx 'GET http://hub.test/v1/node/self ' "$STUB_BODY" || st_fail "H: request: $(cat "$STUB_BODY")"
grep -qx "Authorization: Bearer $NODETOK" "$STUB_HDR" || st_fail "H: header: $(cat "$STUB_HDR")"
fake self '{"hostname":"mac-a.local","status":"online"}'
"$SUT" self >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'predates' "$WORK/err" || st_fail "H: old hub: exit $rc $(cat "$WORK/err")"
st_count

# I. no leak
reset
export CCQUOTA_HUB_URL=http://hub.test
fake settings '{"effective":{"fleet.node_trust.mac-n":"trusted"}}'
"$SUT" set mac-n trusted >/dev/null 2>&1
"$SUT" self >/dev/null 2>&1
if grep -q 'SECRET' "$STUB_LOG"; then st_fail "I: a token reached curl's argv: $(cat "$STUB_LOG")"; fi
if grep -rq "$VIEWER" "$HOME" "$FLEET_CONF_DIR" 2>/dev/null; then st_fail "I: the viewer token was written to a file"; fi
st_count

printf 'fleet-node-trust selftest: PASS (%d checks)\n' "$CHECKS"
