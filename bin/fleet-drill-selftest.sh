#!/bin/bash
# fleet-drill-selftest.sh — bin/fleet-drill.sh (`fleet drill invite`, issue
# #2010) against a curl shim: its refusals, the operator-token door (no live
# certificate here — the token rides stdin, never an argv), the certificate
# door (an ssh-keygen shim: a live cert, a signature over the exact fields),
# and what it prints: the code, the expiry, and the drill command to run next.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
SH="$BIN/fleet-drill.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-drill-selftest.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAILS=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

mkdir -p "$T/shim" "$T/conf" "$T/home/.ssh"
printf 'export FLEET_HUB_URL="https://hub.example"\n' > "$T/conf/fleet.conf"
cat > "$T/shim/curl" <<'EOF'
#!/bin/bash
out='' m=GET url='' body='' hdr='' argv="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;; -X) m=$2; shift 2 ;; -w|-m|--max-time) shift 2 ;;
    -H) [ "$2" = @- ] && hdr=$(cat); shift 2 ;;
    --data-binary) if [ "$2" = @- ]; then body=$(cat); else body=$2; fi; shift 2 ;;
    http*) url=$1; shift ;; *) shift ;;
  esac
done
{ printf 'REQ %s %s\nHDR %s\nBODY %s\nARGV %s\n' "$m" "$url" "$hdr" "$body" "$argv"; } >> "$CURL_LOG"
case "${CURL_ANSWER:-ok}" in
  ok)  printf '{"person_id":"drill-ab12","kind":"drill","login":"drill10071200","host":"macmini-m4","approve_code":"fd_abcdefghijklmnopqrstuvwxyz","expires_at":"2026-10-07T14:00:00Z"}' > "$out"; printf 200 ;;
  403) printf '{"error":"only an admin can invite a drill person"}' > "$out"; printf 403 ;;
  ns)  printf '{"person_id":"drill-ab12","kind":"drill","login":"drill10071200","host":"m4","approve_code":"fd_abcdefghijklmnopqrstuvwxyz","expires_at":"2026-10-07T05:47:35.272044642Z"}' > "$out"; printf 200 ;;
  junk) printf '{"person_id":"drill-ab12","kind":"drill","login":"drill10071200","host":"m4","approve_code":"fd_abcdefghijklmnopqrstuvwxyz","expires_at":"next tuesday"}' > "$out"; printf 200 ;;
esac
EOF
chmod +x "$T/shim/curl"

# run <want-rc> <ERE> <label> [env…] -- <args…>
run() {
  local want=$1 re=$2 label=$3 rc out; shift 3
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$T/curl.log"
  out=$(env PATH="$T/shim:$PATH" HOME="$T/home" FLEET_CONF_DIR="$T/conf" CURL_LOG="$T/curl.log" \
        CCQUOTA_VIEWER_TOKEN='' CCQUOTA_HUB_URL='' FLEET_HUB_URL='' ${envs[@]+"${envs[@]}"} bash "$SH" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -Eq -- "$re"; then ok "$label (exit $rc)"
  else bad "$label: exit $rc (want $want): $(printf '%s' "$out" | head -n 4)"; fi
}

run 2 'fleet drill invite'   'no subcommand'               --
run 2 'unknown argument'     'an unknown option'           -- invite --frob
run 2 '--ttl'                'a bad --ttl'                 -- invite --ttl soon
run 2 '--login: drill'       'a login that is not a drill' -- invite --login verkyyi
run 2 'no live connection'   'no cert and no token'        -- invite --host m4
if grep -q REQ "$T/curl.log"; then bad 'a refusal still called the hub'; else ok 'no refusal called the hub'; fi

# the operator-token door: Bearer on stdin, the fields in the body, the output
run 0 'fleet-onboard-drill.sh --login drill10071200 --invite fd_abcdefghijklmnopqrstuvwxyz' \
  'the token door prints the next command' CCQUOTA_VIEWER_TOKEN=tok-secret -- invite --host macmini-m4 --ttl 90m
grep -q '^REQ POST https://hub.example/v1/admin/drill' "$T/curl.log" && ok 'POST /v1/admin/drill' || bad "no POST: $(cat "$T/curl.log")"
grep -q '^HDR Authorization: Bearer tok-secret' "$T/curl.log" && ok 'the token rides a header on stdin' || bad 'no Bearer header'
if grep '^ARGV' "$T/curl.log" | grep -q tok-secret; then bad 'the token reached an argv'; else ok 'the token never reached an argv'; fi
grep -q '^BODY .*"host": "macmini-m4".*"ttl_seconds": 5400' "$T/curl.log" && ok '--ttl 90m → 5400 s, the host in the body' || bad "body: $(grep ^BODY "$T/curl.log")"
run 1 'only an admin'        'the hub refusing is exit 1'  CCQUOTA_VIEWER_TOKEN=tok CURL_ANSWER=403 -- invite --host m4
run 0 '"approve_code"'       '--json prints the raw answer' CCQUOTA_VIEWER_TOKEN=tok -- invite --host m4 --json
# the hub's nanosecond time (issue #2024): read on any python3, and an expiry
# that will not parse never costs the code — it prints first, the time raw
run 0 '到期 +10-07 05:47'      'a nanosecond …Z expiry formats' TZ=UTC CCQUOTA_VIEWER_TOKEN=tok CURL_ANSWER=ns -- invite --host m4
if [ -x /usr/bin/python3 ]; then
  run 0 '到期 +10-07 05:47'    'and with /usr/bin/python3 first on PATH' PATH="$T/shim:/usr/bin:/bin" TZ=UTC CCQUOTA_VIEWER_TOKEN=tok CURL_ANSWER=ns -- invite --host m4
fi
run 0 '^确认码 +fd_abcdefghijklmnopqrstuvwxyz' 'the code line prints' CCQUOTA_VIEWER_TOKEN=tok CURL_ANSWER=ns -- invite --host m4
run 0 '到期 +next tuesday'     'an unreadable expiry prints raw, the code kept' CCQUOTA_VIEWER_TOKEN=tok CURL_ANSWER=junk -- invite --host m4

# the certificate door: a live cert → signed, no token sent
printf 'k\n' > "$T/home/.ssh/fleet-cert"; printf 'ssh-ed25519-cert-v01@openssh.com AAAA cert\n' > "$T/home/.ssh/fleet-cert-cert.pub"
cat > "$T/shim/ssh-keygen" <<'EOF'
#!/bin/bash
case "$1" in
  -L) echo '        Valid: from 2026-01-01T00:00:00 to 2999-01-01T00:00:00' ;;
  -Y) msg=$(cat); printf '%s\n' "$msg" > "$SIGNED"; echo '-----BEGIN SSH SIGNATURE-----'; echo 'c2ln'; echo '-----END SSH SIGNATURE-----' ;;
esac
EOF
chmod +x "$T/shim/ssh-keygen"
run 0 'fleet-onboard-drill.sh' 'the cert door' SIGNED="$T/signed" CCQUOTA_VIEWER_TOKEN=tok-secret -- invite --host m4 --login drillx1
if grep -Eq '^fleet-drill [0-9]+ invite m4 drillx1 0$' "$T/signed" 2>/dev/null; then ok 'it signs "fleet-drill <ts> invite <host> <login> <ttl>"'
else bad "signed: $(cat "$T/signed" 2>/dev/null)"; fi
if grep -q '^HDR Authorization' "$T/curl.log"; then bad 'a live cert still sent the token'; else ok 'a live cert sends no token'; fi
grep -q '^BODY .*"cert": "ssh-ed25519-cert-v01@openssh.com AAAA cert"' "$T/curl.log" && ok 'the cert rides the body' || bad "body: $(grep ^BODY "$T/curl.log")"

# approve: the drill's scan — the code (from the environment) is the only
# credential sent, even with a token and a live cert right here
run 2 '验证码 looks like'      'approve: a bad 验证码'          FLEET_DRILL_INVITE=fd_abcdefghijklmnopqrstuvwxyz -- approve nope
run 2 'FLEET_DRILL_INVITE'    'approve: no code in the env'   -- approve ABCD-EFGH
run 0 'person_id'             'approve: confirmed'            SIGNED="$T/signed" CCQUOTA_VIEWER_TOKEN=tok-secret FLEET_DRILL_INVITE=fd_abcdefghijklmnopqrstuvwxyz -- approve abcd-efgh
grep -q '^REQ POST https://hub.example/fleet/login/approve' "$T/curl.log" && ok 'POST /fleet/login/approve' || bad "approve: $(cat "$T/curl.log")"
grep -qF 'BODY {"code":"ABCD-EFGH","approve_code":"fd_abcdefghijklmnopqrstuvwxyz"}' "$T/curl.log" && ok 'the body carries the 验证码 and the code' || bad "approve body: $(grep ^BODY "$T/curl.log")"
if grep -q '^HDR .' "$T/curl.log" || grep '^BODY' "$T/curl.log" | grep -q '"cert"'; then bad 'approve sent the token or the certificate'; else ok 'approve sends neither the token nor the certificate'; fi
if grep '^ARGV' "$T/curl.log" | grep -q fd_; then bad 'the approve code reached an argv'; else ok 'the approve code never reached an argv'; fi

[ "$FAILS" = 0 ] && { echo 'fleet-drill-selftest: PASS'; exit 0; }
echo "fleet-drill-selftest: FAIL ($FAILS)"; exit 1
