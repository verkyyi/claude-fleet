#!/bin/bash
# fleet-onboard-drill-selftest.sh — bin/fleet-onboard-drill.sh's refusals
# (issue #1901). The drill opens a real OS login and runs sudo, so this drives
# ONLY the paths that stop before anything is changed — usage, names, the hub,
# the sudo ticket, a login that already exists, a teardown with nothing to
# clean — against PATH shims: a shim sudo answers the ticket question and
# refuses everything else, so no run here can ever create a login.
# Issue #2010 adds --invite (the drill person): its refusals, and a teardown
# whose hub half runs against a curl shim — the drill person deletes ITSELF
# (DELETE /v1/self, the approve code on stdin, never an argv), no operator
# token in the environment, and the residue check reads the hub's 401.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
DRILL="$BIN/fleet-onboard-drill.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/onboard-drill-selftest.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAILS=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

mkdir -p "$T/shim" "$T/conf" "$T/homes"
# sudo: `sudo -n true` is the ticket check — $SUDO_OK decides; anything else
# is refused, so a regression past the preflight cannot touch the machine
cat > "$T/shim/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && [ "$2" = true ] && [ "${SUDO_OK:-0}" = 1 ] && exit 0
[ "$1" = -n ] && [ "$2" = -v ] && exit 0
echo "selftest sudo shim: refusing $*" >&2; exit 1
EOF
for t in tmux ssh ssh-keygen; do printf '#!/bin/sh\nexit 0\n' > "$T/shim/$t"; done
chmod +x "$T/shim/"*
printf 'export FLEET_HUB_URL="https://hub.example"\n' > "$T/conf/fleet.conf"

# run <expect-rc> <expect-stderr-ERE> <label> <args…>
run() {
  local want=$1 re=$2 label=$3 rc out; shift 3
  out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" \
        TMPDIR="$T" bash "$DRILL" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && printf '%s\n' "$out" | grep -Eq -- "$re"; then ok "$label (exit $rc)"
  else bad "$label: exit $rc (want $want), output: $(printf '%s' "$out" | head -n 3)"; fi
}

out=$(bash "$DRILL" --help 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '新同事\|new colleague'; then ok '--help prints the header (exit 0)'
else bad "--help: exit $rc"; fi

run 2 'unknown argument'            'an unknown argument'       --frobnicate
run 2 'bad login name'              'a bad login name'          --login 'Bad Name'
run 2 '--name: lowercase'           'a bad scratch name'        --login drilltest --name 'X Y'
run 2 'not a number'                'a non-numeric timeout'     --login drilltest --timeout soon
SUDO_OK=0 run 2 'no sudo ticket'    'no sudo ticket'            --login drilltest
out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/empty" FLEET_LOGIN_HOMES="$T/homes" bash "$DRILL" --login drilltest 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s\n' "$out" | grep -q 'no hub'; then ok 'no hub anywhere (exit 2)'; else bad "no hub: exit $rc: $out"; fi
# a login that exists (the one running this test) → 3, before anything is made
export SUDO_OK=1
run 3 'already exists'              'the login already exists'  --login "$(id -un | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')"
mkdir -p "$T/homes/drillghost"
run 3 'already exists'              'a home with no login'      --login drillghost
run 2 'nothing to clean'            'a teardown of nothing'     --teardown drillnone
run 2 'not an approve code'         '--invite: a malformed code' --login drillx --invite nope
run 2 'needs --login'               '--invite with no --login'  --invite fd_abcdefghijklmnopqrstuvwxyz
# nothing past the preflight ran: no run dir was made
if ls -d "$T"/fleet-onboard-drill.* >/dev/null 2>&1; then bad 'a refused run left a run dir'; else ok 'no refused run made a run dir'; fi

# --- --teardown --invite: the drill person deletes itself on the hub -----------
# curl: logs method · url · stdin body, answers DELETE /v1/self 200 the first
# time and 401 after (the person is gone); argv must never hold the code
cat > "$T/shim/curl" <<'EOF'
#!/bin/bash
out='' m=GET url='' body='' argv="$*"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;; -X) m=$2; shift 2 ;; -w|-H|--max-time|-m) shift 2 ;;
    --data-binary) [ "$2" = @- ] && body=$(cat); shift 2 ;;
    http*) url=$1; shift ;; *) shift ;;
  esac
done
printf '%s %s %s\n' "$m" "$url" "$body" >> "$CURL_LOG"
printf 'ARGV %s\n' "$argv" >> "$CURL_LOG"
n=$(grep -c '^DELETE ' "$CURL_LOG")
if [ "$m" = DELETE ] && [ "$n" = 1 ]; then
  printf '{"person_id":"drill-1","devices":1,"accounts":1,"nodes":["ep_9"]}' > "$out"; printf 200
else
  printf '{"error":"approve code unknown or expired"}' > "$out"; printf 401
fi
EOF
cat > "$T/shim/remove" <<'EOF'
#!/bin/sh
# the login-remove seam: removes the sandbox home only
rm -rf "$FLEET_LOGIN_HOMES/$1"; echo "removed $1"
EOF
chmod +x "$T/shim/curl" "$T/shim/remove"
mkdir -p "$T/homes/drillx"
CODE=fd_abcdefghijklmnopqrstuvwxyz
out=$(env PATH="$T/shim:$PATH" FLEET_CONF_DIR="$T/conf" FLEET_LOGIN_HOMES="$T/homes" TMPDIR="$T" \
      CURL_LOG="$T/curl.log" FLEET_DRILL_LOGIN_REMOVE="$T/shim/remove" CCQUOTA_VIEWER_TOKEN='' FLEET_HUB_TOKEN='' \
      bash "$DRILL" --teardown drillx --invite "$CODE" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'drill person deleted itself on the hub by the approve code' \
   && printf '%s\n' "$out" | grep -q 'no drill person on the hub'; then ok 'teardown --invite: the drill person deletes itself, residue reads the hub (exit 0)'
else bad "teardown --invite: exit $rc: $(printf '%s' "$out" | tail -n 6)"; fi
if grep -qF "DELETE https://hub.example/v1/self {\"approve_code\":\"$CODE\"}" "$T/curl.log" 2>/dev/null; then ok 'the self-delete went to DELETE /v1/self with the code in the body'
else bad "no DELETE /v1/self with the code: $(cat "$T/curl.log" 2>/dev/null)"; fi
if grep '^ARGV' "$T/curl.log" | grep -q "$CODE"; then bad "the approve code reached curl's argv"; else ok 'the approve code never reached an argv'; fi
if grep -q 'devices/revoke' "$T/curl.log"; then bad 'a drill-person teardown still asked the operator-token revoke'; else ok 'no operator-token revoke on the drill-person path'; fi
r=$(ls "$T"/fleet-onboard-drill.drillx.*/hub-residue.txt 2>/dev/null | head -n 1)
if [ -n "$r" ] && grep -q 'HTTP 401' "$r"; then ok "the hub's 401 is kept as evidence (hub-residue.txt)"; else bad "no hub-residue.txt with the 401 (${r:-none})"; fi

[ "$FAILS" = 0 ] && { echo 'fleet-onboard-drill-selftest: PASS'; exit 0; }
echo "fleet-onboard-drill-selftest: FAIL ($FAILS)"; exit 1
