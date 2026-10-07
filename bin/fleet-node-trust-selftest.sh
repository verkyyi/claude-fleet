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
#   C. set       PUT /v1/fleet/settings {"key":"fleet.node_trust.m9","value":
#                "trusted"} (a full name `M9.local` folds to `m9`), the bearer on
#                curl's STDIN (`-H @-`) — never in its argv; prints `SET m9
#                trusted`; exit 0
#   D. old hub   a 200 whose effective map lacks the key: exit 4, "predates"
#   E. status    the roster's machines with their trust + a machine only the
#                settings name; `status m5` filters; an unknown machine reads
#                untrusted; a roster with no trust word → exit 4
#   F. refused   401 / 403 → exit 4 "not the operator"; 400 → exit 4
#   G. down      curl fails: exit 1 `hub unreachable`, nothing on stdout
#   H. self      module off → exit 10, curl never called; node.env token →
#                GET /v1/node/self, prints `m4 trusted`; no trust → exit 4
#   I. no leak   neither token is in any curl argv, and the viewer token is
#                written to no file under HOME / FLEET_CONF_DIR
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$BIN/fleet-node-trust.sh"
CHECKS=0
fail() { printf 'fleet-node-trust selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-trust-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT

# The stub curl: appends argv to STUB_LOG, the stdin header to STUB_HDR, the
# body to STUB_BODY; answers by the URL's path from $FAKE_DIR/<name>.{body,code}
# (name: settings | nodes | self), or fails with FAKE_RC.
STUB="$WORK/curl"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
body='' url='' method=GET hdr=''
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) body="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -H) [ "$2" = @- ] && hdr=$(cat); shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$hdr" >> "$STUB_HDR"
printf '%s %s %s\n' "$method" "$url" "$body" >> "$STUB_BODY"
[ "${FAKE_RC:-0}" -eq 0 ] || exit "$FAKE_RC"
case "$url" in
  */v1/fleet/settings) n=settings ;;
  */v1/nodes) n=nodes ;;
  */v1/node/self) n=self ;;
  *) n=none ;;
esac
printf '%s\n%s' "$(cat "$FAKE_DIR/$n.body" 2>/dev/null || printf '{}')" "$(cat "$FAKE_DIR/$n.code" 2>/dev/null || printf 200)"
EOF
chmod +x "$STUB"
export STUB_LOG="$WORK/curl.log" STUB_HDR="$WORK/curl.hdr" STUB_BODY="$WORK/curl.body" FLEET_HUB_CURL="$STUB" FAKE_DIR="$WORK/fake"
mkdir -p "$FAKE_DIR"
reset() { rm -f "$STUB_LOG" "$STUB_HDR" "$STUB_BODY" "$FAKE_DIR"/*; unset FAKE_RC; }
fake() { printf '%s' "$2" > "$FAKE_DIR/$1.body"; printf '%s' "${3:-200}" > "$FAKE_DIR/$1.code"; }

VIEWER='viewer-SECRET-1968'
NODETOK='node-SECRET-1968'

# A. usage
for args in '' 'frob' 'set m9 maybe' 'set m9' 'set "bad name!" trusted' 'status m4 m5' 'self extra'; do
  reset
  eval "\"\$SUT\" $args" >/dev/null 2>"$WORK/err"; rc=$?
  [ "$rc" -eq 2 ] || fail "A: '$args' exit $rc, want 2: $(cat "$WORK/err")"
  [ ! -e "$STUB_LOG" ] || fail "A: '$args' called curl"
done
ok

# B. no token / no URL
reset
"$SUT" set m9 trusted >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'CCQUOTA_VIEWER_TOKEN' "$WORK/err" || fail "B: no token: exit $rc $(cat "$WORK/err")"
[ ! -e "$STUB_LOG" ] || fail "B: curl called without a token"
CCQUOTA_VIEWER_TOKEN=$VIEWER "$SUT" status >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no hub URL' "$WORK/err" || fail "B: no URL: exit $rc $(cat "$WORK/err")"
[ ! -e "$STUB_LOG" ] || fail "B: curl called without a URL"
ok

export CCQUOTA_VIEWER_TOKEN=$VIEWER CCQUOTA_HUB_URL=http://hub.test/

# C. set
reset
fake settings '{"settings":{"fleet.node_trust.m9":"trusted"},"effective":{"fleet.node_trust.m9":"trusted"}}'
out=$("$SUT" set M9.local trusted 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || fail "C: exit $rc: $(cat "$WORK/err")"
[ "$out" = 'trust: SET m9 trusted' ] || fail "C: stdout: $out"
grep -qx 'PUT http://hub.test/v1/fleet/settings {"key":"fleet.node_trust.m9","value":"trusted"}' "$STUB_BODY" || fail "C: request: $(cat "$STUB_BODY")"
grep -qx "Authorization: Bearer $VIEWER" "$STUB_HDR" || fail "C: header: $(cat "$STUB_HDR")"
ok

# D. old hub: 200 without the key
reset
fake settings '{"settings":{},"effective":{}}'
"$SUT" set m9 untrusted >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'predates' "$WORK/err" || fail "D: exit $rc $(cat "$WORK/err")"
ok

# E. status
reset
fake nodes '{"nodes":[{"hostname":"m4.local","trust":"trusted"},{"hostname":"m4.local","trust":"trusted"},{"hostname":"m5","trust":"untrusted"}]}'
fake settings '{"settings":{"fleet.node_trust.m9":"trusted","fleet.node_cap.m4":"8"}}'
out=$("$SUT" status 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] || fail "E: exit $rc: $(cat "$WORK/err")"
[ "$out" = "$(printf 'trust: m4 trusted\ntrust: m5 untrusted\ntrust: m9 trusted')" ] || fail "E: stdout: $out"
[ "$("$SUT" status m5.local 2>/dev/null)" = 'trust: m5 untrusted' ] || fail "E: filter m5"
[ "$("$SUT" status m7 2>/dev/null)" = 'trust: m7 untrusted' ] || fail "E: unknown machine"
fake nodes '{"nodes":[{"hostname":"m4"}]}'
"$SUT" status >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'predates' "$WORK/err" || fail "E: old roster: exit $rc $(cat "$WORK/err")"
ok

# F. refused
for c in 401 403; do
  reset; fake settings '{"error":"only the operator"}' "$c"
  "$SUT" set m9 trusted >/dev/null 2>"$WORK/err"; rc=$?
  [ "$rc" -eq 4 ] && grep -q 'not the operator' "$WORK/err" || fail "F: $c exit $rc $(cat "$WORK/err")"
done
reset; fake settings '{"error":"bad"}' 400
"$SUT" set m9 trusted >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] || fail "F: 400 exit $rc"
ok

# G. down
reset; export FAKE_RC=7
out=$("$SUT" status 2>"$WORK/err"); rc=$?
[ "$rc" -eq 1 ] && grep -q 'hub unreachable' "$WORK/err" && [ -z "$out" ] || fail "G: exit $rc out=$out $(cat "$WORK/err")"
unset FAKE_RC
ok

# H. self
reset
"$SUT" self >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 10 ] && [ ! -e "$STUB_LOG" ] || fail "H: module off: exit $rc"
export CCQUOTA_FLEET=1
unset CCQUOTA_HUB_URL
printf 'CCQUOTA_TOKEN=%s\nCCQUOTA_HUB_URL=http://hub.test\n' "$NODETOK" > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"
fake self '{"hostname":"m4.local","status":"online","trust":"trusted"}'
out=$("$SUT" self 2>"$WORK/err"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = 'trust: m4 trusted' ] || fail "H: exit $rc out=$out $(cat "$WORK/err")"
grep -qx 'GET http://hub.test/v1/node/self ' "$STUB_BODY" || fail "H: request: $(cat "$STUB_BODY")"
grep -qx "Authorization: Bearer $NODETOK" "$STUB_HDR" || fail "H: header: $(cat "$STUB_HDR")"
fake self '{"hostname":"m4.local","status":"online"}'
"$SUT" self >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'predates' "$WORK/err" || fail "H: old hub: exit $rc $(cat "$WORK/err")"
ok

# I. no leak
reset
export CCQUOTA_HUB_URL=http://hub.test
fake settings '{"effective":{"fleet.node_trust.m9":"trusted"}}'
"$SUT" set m9 trusted >/dev/null 2>&1
"$SUT" self >/dev/null 2>&1
if grep -q 'SECRET' "$STUB_LOG"; then fail "I: a token reached curl's argv: $(cat "$STUB_LOG")"; fi
if grep -rq "$VIEWER" "$HOME" "$FLEET_CONF_DIR" 2>/dev/null; then fail "I: the viewer token was written to a file"; fi
ok

printf 'fleet-node-trust selftest: PASS (%d checks)\n' "$CHECKS"
