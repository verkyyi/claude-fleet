#!/bin/bash
# fleet-onboard-drill-selftest.sh — bin/fleet-onboard-drill.sh's refusals
# (issue #1901). The drill opens a real OS login and runs sudo, so this drives
# ONLY the paths that stop before anything is changed — usage, names, the hub,
# the sudo ticket, a login that already exists, a teardown with nothing to
# clean — against PATH shims: a shim sudo answers the ticket question and
# refuses everything else, so no run here can ever create a login.
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
# nothing past the preflight ran: no run dir was made
if ls -d "$T"/fleet-onboard-drill.* >/dev/null 2>&1; then bad 'a refused run left a run dir'; else ok 'no refused run made a run dir'; fi

[ "$FAILS" = 0 ] && { echo 'fleet-onboard-drill-selftest: PASS'; exit 0; }
echo "fleet-onboard-drill-selftest: FAIL ($FAILS)"; exit 1
