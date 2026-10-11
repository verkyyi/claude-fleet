#!/bin/bash
# fleet-cred-policy-selftest.sh — bin/fleet-cred-policy.sh (issue #3043): the
# operator's subscription allowlists, with the transport stubbed through
# FLEET_HUB_CURL — no hub, no network.
#
#   A. usage     no action / unknown / set with no ID / deny with IDs / a bad
#                scope / effective with nothing: exit 2, curl never called
#   B. no token  exit 1 naming CCQUOTA_VIEWER_TOKEN, curl never called
#   C. writes    set → PUT {"scope","id","allow":[…]}; deny → "allow":[];
#                clear → "allow":null; each prints its SET line
#   D. reads     show lists every list (a malformed one says so; none says
#                unrestricted); effective prints ALLOW / DENY + the reason,
#                the query carries machine + principal
#   E. refused   400 → exit 4; 404 → exit 4 "predates"; curl fails → exit 1
#   F. no leak   the viewer token is in no curl argv, only on its stdin
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$BIN/fleet-cred-policy.sh"
CHECKS=0
fail() { printf 'fleet-cred-policy selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-cred-policy-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT

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
printf '%s\n%s' "$(cat "$FAKE_DIR/body" 2>/dev/null || printf '{}')" "$(cat "$FAKE_DIR/code" 2>/dev/null || printf 200)"
EOF
chmod +x "$STUB"
export STUB_LOG="$WORK/curl.log" STUB_HDR="$WORK/curl.hdr" STUB_BODY="$WORK/curl.body" FLEET_HUB_CURL="$STUB" FAKE_DIR="$WORK/fake"
mkdir -p "$FAKE_DIR"
reset() { rm -f "$STUB_LOG" "$STUB_HDR" "$STUB_BODY" "$FAKE_DIR"/*; unset FAKE_RC; }
fake() { printf '%s' "$1" > "$FAKE_DIR/body"; printf '%s' "${2:-200}" > "$FAKE_DIR/code"; }
VIEWER='viewer-SECRET-3043'
U1=11111111-1111-4111-8111-111111111111
CX=codex:account:0123456789abcdef0123456789abcdef

# A. usage
for args in '' 'frob' 'set node m4' 'deny user gh:1 x' 'clear login alice' 'effective' 'show extra'; do
  reset
  eval "CCQUOTA_VIEWER_TOKEN=$VIEWER CCQUOTA_HUB_URL=http://hub.test \"\$SUT\" $args" >/dev/null 2>"$WORK/err"; rc=$?
  [ "$rc" -eq 2 ] || fail "A: '$args' exit $rc, want 2: $(cat "$WORK/err")"
  [ ! -e "$STUB_LOG" ] || fail "A: '$args' called curl"
  ok
done

# B. no token
reset
CCQUOTA_HUB_URL=http://hub.test "$SUT" show >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 1 ] && grep -q CCQUOTA_VIEWER_TOKEN "$WORK/err" && [ ! -e "$STUB_LOG" ] || fail "B: rc=$rc $(cat "$WORK/err")"
ok

export CCQUOTA_VIEWER_TOKEN=$VIEWER CCQUOTA_HUB_URL=http://hub.test/

# C. writes
reset; fake '{"ok":true,"allow":["'$U1'","'$CX'"]}'
out=$("$SUT" set node M4.local "$U1" "$CX"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "cred-policy: SET node M4.local: $U1 $CX" ] || fail "C set: rc=$rc $out"
grep -qF 'PUT http://hub.test/v1/fleet/cred-policy {"scope": "node", "id": "M4.local", "allow": ["'$U1'", "'$CX'"]}' "$STUB_BODY" \
  || fail "C set body: $(cat "$STUB_BODY")"
ok
reset; fake '{"ok":true,"allow":[]}'
out=$("$SUT" deny user gh:2718137); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "cred-policy: SET user gh:2718137: deny all" ] \
  && grep -qF '"allow": []' "$STUB_BODY" || fail "C deny: rc=$rc $out / $(cat "$STUB_BODY")"
ok
reset; fake '{"ok":true,"allow":null}'
out=$("$SUT" clear user gh:2718137); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "cred-policy: SET user gh:2718137: unrestricted" ] \
  && grep -qF '"allow": null' "$STUB_BODY" || fail "C clear: rc=$rc $out / $(cat "$STUB_BODY")"
ok

# D. reads
reset; fake '{"nodes":[{"id":"m4","allow":["'$U1'"]}],"users":[{"id":"gh:1","allow":[],"error":"not a JSON list"},{"id":"gh:2","allow":[]}]}'
out=$("$SUT" show)
printf '%s\n' "$out" | grep -qx "cred-policy: node m4 $U1" \
  && printf '%s\n' "$out" | grep -q '^cred-policy: user gh:1 MALFORMED (denies all): not a JSON list$' \
  && printf '%s\n' "$out" | grep -qx 'cred-policy: user gh:2 (deny all)' || fail "D show: $out"
ok
reset; fake '{"nodes":[],"users":[]}'
out=$("$SUT" show)
case "$out" in *"no allowlists"*) ok ;; *) fail "D show none: $out" ;; esac
reset; fake '{"effective":{"machine":"m4","principal":"gh:1","restricted":true,"accounts":[
  {"provider":"claude","owner":"pool","account":"gmail","account_uuid":"'$U1'","allowed":true},
  {"provider":"claude","owner":"pool","account":"legacy","allowed":false,"reason":"no account UUID recorded"}]}}'
out=$("$SUT" effective --machine m4 --principal gh:1)
printf '%s\n' "$out" | grep -q '^cred-policy: effective machine=m4 principal=gh:1 restricted$' \
  && printf '%s\n' "$out" | grep -qF "  ALLOW pool/gmail · claude · $U1" \
  && printf '%s\n' "$out" | grep -qF "  DENY  pool/legacy · claude · (no account UUID) — no account UUID recorded" \
  && grep -qF 'GET http://hub.test/v1/fleet/cred-policy?machine=m4&principal=gh%3A1' "$STUB_BODY" || fail "D effective: $out / $(cat "$STUB_BODY")"
ok

# E. refused / down
reset; fake '{"error":"bad"}' 400
"$SUT" set node m4 "$U1" >/dev/null 2>&1; [ $? -eq 4 ] || fail "E 400"
ok
reset; fake '' 404
"$SUT" show >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q predates "$WORK/err" || fail "E 404: rc=$rc"
ok
reset; export FAKE_RC=7
out=$("$SUT" show 2>"$WORK/err"); rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && grep -q unreachable "$WORK/err" || fail "E down: rc=$rc"
unset FAKE_RC
ok

# F. no leak
reset; fake '{"nodes":[],"users":[]}'
"$SUT" show >/dev/null
! grep -q "$VIEWER" "$STUB_LOG" && grep -q "Bearer $VIEWER" "$STUB_HDR" || fail "F: the token in an argv"
ok

printf 'fleet-cred-policy selftest: %d checks passed\n' "$CHECKS"
