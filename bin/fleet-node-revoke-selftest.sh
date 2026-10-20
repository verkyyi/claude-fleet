#!/bin/bash
# fleet-node-revoke-selftest.sh — bin/fleet-node-revoke.sh (issue #1403): the
# operator takes a machine's enrollment back, with the transport stubbed
# through FLEET_HUB_CURL — no hub, no network, no tmux.
#
# What it pins:
#   A. usage     no target / a bad name / two targets / an unknown option /
#                --reason with no text: exit 2, curl never called
#   B. no token  no CCQUOTA_VIEWER_TOKEN: exit 1 naming it, curl never called;
#                no hub URL: exit 1
#   C. by name   `M9.local:alice` → GET /v1/nodes, then POST
#                /v1/fleet/nodes/revoke {"endpoint_id":"ep_9","reason":"lost"}
#                with the bearer on curl's STDIN; prints the REVOKED line
#   D. by id     `ep_7` → no roster read, straight to the revoke; ALREADY line
#   E. names     a machine with two logins → exit 5 naming both, nothing
#                revoked; a machine not on the roster → exit 5
#   F. refused   401 / 403 → exit 4 "not the operator"; 404 → exit 4; an
#                answer without a verdict (an old hub) → exit 4 "predates"
#   G. down      curl fails: exit 1 `hub unreachable`, nothing on stdout
#   H. no leak   the viewer token is in no curl argv and written to no file
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/selftest-lib.sh"
SUT="$BIN/fleet-node-revoke.sh"
CHECKS=0

st_sandbox "${TMPDIR:-/tmp}/fleet-node-revoke-selftest.XXXXXX"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT

. "$BIN/selftest-hub-curl.sh"   # the stub curl: reset · fake <name> <body> [code]
hc_stub by-path

VIEWER='viewer-SECRET-1403'
ROSTER='{"nodes":[{"endpoint_id":"ep_9","hostname":"m9.local","os_user":"alice"},{"endpoint_id":"ep_8","hostname":"m9","os_user":"bob"},{"endpoint_id":"ep_4","hostname":"mac-a","os_user":"alice"}]}'

# A. usage
for args in '' '"bad name!"' 'm9 mac-a' '--frob m9' 'm9 --reason' 'm9:al:ice'; do
  reset
  eval "\"\$SUT\" $args" >/dev/null 2>"$WORK/err"; rc=$?
  [ "$rc" -eq 2 ] || st_fail "A: '$args' exit $rc, want 2: $(cat "$WORK/err")"
  [ ! -e "$STUB_LOG" ] || st_fail "A: '$args' called curl"
done
st_count

# B. no token / no URL
reset
"$SUT" m9:alice >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CCQUOTA_VIEWER_TOKEN' "$WORK/err" || st_fail "B: no token: exit $rc $(cat "$WORK/err")"
[ ! -e "$STUB_LOG" ] || st_fail "B: curl called without a token"
CCQUOTA_VIEWER_TOKEN=$VIEWER "$SUT" m9:alice >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no hub URL' "$WORK/err" || st_fail "B: no URL: exit $rc $(cat "$WORK/err")"
[ ! -e "$STUB_LOG" ] || st_fail "B: curl called without a URL"
st_count

export CCQUOTA_VIEWER_TOKEN=$VIEWER CCQUOTA_HUB_URL=http://hub.test/

# C. by name
reset
fake nodes "$ROSTER"
fake revoke '{"endpoint_id":"ep_9","label":"m9","hostname":"m9.local","os_user":"alice","already":false,"passes":2,"relay":true,"link_closed":true}'
out=$("$SUT" M9.local:alice --reason lost 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || st_fail "C: exit $rc: $(cat "$WORK/err")"
[ "$out" = 'revoke: REVOKED m9:alice ep_9 passes=2 relay=yes link=closed' ] || st_fail "C: stdout: $out"
grep -qx 'GET http://hub.test/v1/nodes ' "$STUB_BODY" || st_fail "C: roster read: $(cat "$STUB_BODY")"
grep -qx 'POST http://hub.test/v1/fleet/nodes/revoke {"endpoint_id": "ep_9", "reason": "lost"}' "$STUB_BODY" || st_fail "C: request: $(cat "$STUB_BODY")"
grep -qx "Authorization: Bearer $VIEWER" "$STUB_HDR" || st_fail "C: header: $(cat "$STUB_HDR")"
st_count

# D. by id, already revoked
reset
fake revoke '{"endpoint_id":"ep_7","label":"verify-health-shipper","hostname":"","os_user":"","already":true,"passes":0}'
out=$("$SUT" ep_7 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'revoke: ALREADY ?:? ep_7' ] || st_fail "D: exit $rc out=$out $(cat "$WORK/err")"
grep -q '/v1/nodes ' "$STUB_BODY" && st_fail "D: read the roster for an id"
grep -qx 'POST http://hub.test/v1/fleet/nodes/revoke {"endpoint_id": "ep_7"}' "$STUB_BODY" || st_fail "D: request: $(cat "$STUB_BODY")"
st_count

# E. ambiguous / not on the roster
reset
fake nodes "$ROSTER"
"$SUT" m9 >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 5 ] && grep -q 'ep_8' "$WORK/err" && grep -q 'ep_9' "$WORK/err" || st_fail "E: ambiguous: exit $rc $(cat "$WORK/err")"
grep -q 'revoke' "$STUB_BODY" && st_fail "E: revoked an ambiguous name"
fake revoke '{"endpoint_id":"ep_4","hostname":"mac-a","os_user":"alice","already":false}'
out=$("$SUT" mac-a 2>/dev/null) || st_fail "E: one login on mac-a is not ambiguous"
reset
fake nodes "$ROSTER"
"$SUT" m7 >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 5 ] && grep -q 'not on the hub' "$WORK/err" || st_fail "E: unknown: exit $rc $(cat "$WORK/err")"
st_count

# F. refused
for c in 401 403; do
  reset; fake revoke '{"error":"only the operator"}' "$c"
  "$SUT" ep_9 >/dev/null 2>"$WORK/err"; rc=$?
  [ "$rc" -eq 4 ] && grep -q 'not the operator' "$WORK/err" || st_fail "F: $c exit $rc $(cat "$WORK/err")"
done
reset; fake revoke '{"error":"no such endpoint"}' 404
"$SUT" ep_9 >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] || st_fail "F: 404 exit $rc"
reset; fake revoke '{"ok":true}'
"$SUT" ep_9 >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'predates' "$WORK/err" || st_fail "F: old hub: exit $rc $(cat "$WORK/err")"
st_count

# G. down
reset; export FAKE_RC=7
out=$("$SUT" m9:alice 2>"$WORK/err"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'hub unreachable' "$WORK/err" && [ -z "$out" ] || st_fail "G: exit $rc out=$out $(cat "$WORK/err")"
unset FAKE_RC
st_count

# H. no leak
reset
fake nodes "$ROSTER"
fake revoke '{"endpoint_id":"ep_9","already":true}'
"$SUT" m9:alice >/dev/null 2>&1
if grep -q 'SECRET' "$STUB_LOG"; then st_fail "H: the token reached curl's argv: $(cat "$STUB_LOG")"; fi
if grep -rq "$VIEWER" "$HOME" "$FLEET_CONF_DIR" 2>/dev/null; then st_fail "H: the viewer token was written to a file"; fi
st_count

printf 'fleet-node-revoke selftest: PASS (%d checks)\n' "$CHECKS"
