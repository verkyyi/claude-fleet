#!/bin/bash
# fleet-machine-policy-selftest.sh — bin/fleet-machine-policy.sh (issue #3824):
# the operator's per-person machine allowlist, with the transport stubbed
# through FLEET_HUB_CURL — no hub, no network.
#
#   A. usage     no action / unknown / set with no machine / deny with names /
#                show with two principals: exit 2, curl never called
#   B. no token  exit 1 naming CCQUOTA_VIEWER_TOKEN, curl never called
#   C. writes    set → PUT {"principal","allow":[…]}; deny → "allow":[];
#                clear → "allow":null; all → "all":true; each prints its SET line
#   D. reads     show lists every list (a malformed one says so; none says every
#                machine); show <principal> prints OPEN / OFF per machine + why
#   E. refused   400 → exit 4; 404 → exit 4 "predates"; curl fails → exit 1
#   F. no leak   the viewer token is in no curl argv, only on its stdin
set -uo pipefail
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$BIN/fleet-machine-policy.sh"
CHECKS=0
fail() { printf 'fleet-machine-policy selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-machine-policy-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_URL FLEET_HUB_CURL FLEET_HUB_TIMEOUT
. "$BIN/selftest-hub-curl.sh"   # the stub curl: reset · fake <body> [code]
hc_stub
VIEWER='viewer-SECRET-3824'
P=gh:2987262

# A. usage
for args in '' 'frob' 'set gh:1' 'deny gh:1 mac-e' 'all' 'show gh:1 gh:2' 'show --frob'; do
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
reset; fake '{"ok":true,"principal":"'$P'","allow":["linux-a"]}'
out=$("$SUT" set "$P" linux-a); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "machine-policy: SET $P: linux-a" ] || fail "C set: rc=$rc $out"
grep -qF 'PUT http://hub.test/v1/fleet/machine-policy {"principal": "'$P'", "allow": ["linux-a"]}' "$STUB_BODY" \
  || fail "C set body: $(cat "$STUB_BODY")"
ok
reset; fake '{"ok":true,"allow":[]}'
out=$("$SUT" deny "$P"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "machine-policy: SET $P: no machine at all" ] \
  && grep -qF '"allow": []' "$STUB_BODY" || fail "C deny: rc=$rc $out / $(cat "$STUB_BODY")"
ok
reset; fake '{"ok":true,"allow":null}'
out=$("$SUT" clear "$P"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "machine-policy: SET $P: no list — every machine" ] \
  && grep -qF '"allow": null' "$STUB_BODY" || fail "C clear: rc=$rc $out / $(cat "$STUB_BODY")"
ok
reset; fake '{"ok":true,"all":true,"allow":null}'
out=$("$SUT" all "$P"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "machine-policy: SET $P: every machine (explicit)" ] \
  && grep -qF '"all": true' "$STUB_BODY" || fail "C all: rc=$rc $out / $(cat "$STUB_BODY")"
ok

# D. reads
reset; fake '{"users":[{"principal":"gh:1","allow":["linux-a","mac-e"]},{"principal":"gh:2","allow":[],"error":"not a JSON list"},{"principal":"gh:3","allow":[]},{"principal":"gh:4","allow":[],"all":true}]}'
out=$("$SUT" show)
printf '%s\n' "$out" | grep -qx 'machine-policy: gh:1 linux-a mac-e' \
  && printf '%s\n' "$out" | grep -qx 'machine-policy: gh:2 MALFORMED (no machine): not a JSON list' \
  && printf '%s\n' "$out" | grep -qx 'machine-policy: gh:3 (no machine)' \
  && printf '%s\n' "$out" | grep -qx 'machine-policy: gh:4 (every machine)' || fail "D show: $out"
ok
reset; fake '{"users":[]}'
out=$("$SUT" show)
case "$out" in *"no lists — everyone may use every machine"*) ok ;; *) fail "D show none: $out" ;; esac
reset; fake '{"users":[{"principal":"'$P'","allow":["linux-a"]}],"effective":{"principal":"'$P'","restricted":true,"machines":[
  {"machine":"linux-a","allowed":true,"reason":""},
  {"machine":"mac-b","allowed":false,"reason":"这台机器暂未对你开放，可用：linux-a"}]}}'
out=$("$SUT" show "$P")
printf '%s\n' "$out" | grep -qx "machine-policy: $P linux-a" \
  && printf '%s\n' "$out" | grep -qx '  OPEN  linux-a' \
  && printf '%s\n' "$out" | grep -qx '  OFF   mac-b — 这台机器暂未对你开放，可用：linux-a' \
  && grep -qF 'GET http://hub.test/v1/fleet/machine-policy?principal=gh%3A2987262' "$STUB_BODY" || fail "D show principal: $out / $(cat "$STUB_BODY")"
ok

# E. refused / down
reset; fake '{"error":"bad"}' 400
"$SUT" set "$P" mac-e >/dev/null 2>&1; [ $? -eq 4 ] || fail "E 400"
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
reset; fake '{"users":[]}'
"$SUT" show >/dev/null
! grep -q "$VIEWER" "$STUB_LOG" && grep -q "Bearer $VIEWER" "$STUB_HDR" || fail "F: the token in an argv"
ok

printf 'fleet-machine-policy selftest: %d checks passed\n' "$CHECKS"
