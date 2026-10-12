#!/usr/bin/env bash
# shellcheck disable=SC2034  # rows/out/j/rc are read inside check's eval strings
# fleet-gate-check-selftest.sh — bin/fleet-gate-check.sh (issue #3574, EPIC #3569
# C4): every item forged passing and failing in a sandbox (FLEET_GATE_PS /
# FLEET_GATE_ADMINS / FLEET_GATE_HUB_JSON), never this machine's own ps or hub.
# Also pins conf/public-gate.tsv (7 rows, one judge per node row) and the doctor's
# `gate` rows (INFO only — never counted as a FAIL).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
G="$BIN/fleet-gate-check.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

HUB_OK='{"items":[{"id":"release-key","pass":true,"why":"k"},{"id":"cloud-perms","pass":true,"why":"c"},{"id":"revocations","pass":true,"why":"r"},{"id":"cred-ttl","pass":true,"why":"t"}]}'
run() { FLEET_GATE_PS="$T/ps" FLEET_GATE_ADMINS="${ADMINS-}" FLEET_GATE_HUB_JSON="${HUB-$HUB_OK}" bash "$G" "$@"; }
item() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(*[("%s %s %s" % (i["id"], i["pass"], i["why"])) for i in d["items"] if i["id"]==sys.argv[1]])' "$1"; }

# A. the table
rows=$(grep -cv '^#' "$BIN/../conf/public-gate.tsv")
check "A1 seven rows" '[ "$rows" = 7 ]'
for id in $(awk -F'\t' '!/^#/ && $3=="node" {print $2}' "$BIN/../conf/public-gate.tsv"); do
  fn=gate_$(printf '%s' "$id" | tr - _)
  check "A2 node row $id has $fn" 'grep -q "^def $fn()" "$G"'
done

# B. everything passing: a managed machine done right
cat > "$T/ps" <<'P'
root /usr/local/libexec/fleet-node-core.py --serve
_fleetnode /opt/claude-fleet/current/bin/fleet-node-supervisor.py run
_fleetnode /opt/claude-fleet/current/bin/ccquota agent --machine --machine-env /var/db/fleet-node/machine.env
_fleetadmin /opt/claude-fleet/current/bin/ccquota agent --state /x
alice /bin/bash /Users/alice/.claude/fleet/bin/fleet-session-wrap.sh
alice /bin/bash /Users/alice/.claude/fleet/bin/fleet-x-selftest.sh fleet-node-supervisor.py ccquota agent --machine
P
ADMINS="root alice"
out=$(run); rc=$?
check "B1 all pass ⇒ exit 0" '[ "$rc" = 0 ]'
check "B2 count line 7/7" 'printf "%s\n" "$out" | grep -q "^gate: 7/7 PASS"'
check "B3 PASS lines name their source" 'printf "%s\n" "$out" | grep -q "^PASS  2 root-core .*由 #3500 C13 (#3555) 完成"'
check "B4 a selftest naming a daemon is not one" '! printf "%s\n" "$out" | grep -q "alice:"'

# C. today's machine: root runs the daemons, an admin login runs the agent
cat > "$T/ps" <<'P'
root /Library/Application Support/claude-fleet/current/bin/ccquota agent --machine --machine-env /var/db/fleet-node/machine.env
root /usr/bin/python3 -I /Library/Application Support/claude-fleet/current/bin/fleet-node-supervisor.py run
alice /usr/local/bin/ccquota agent --state /Users/alice/.ccquota/agent
bob /usr/local/bin/ccquota agent --state /Users/bob/.ccquota/agent
P
ADMINS="root alice"
j=$(run --json); rc=$?
check "C1 a red item ⇒ exit 1" '[ "$rc" = 1 ]'
check "C2 root-core red, names the program" 'item root-core <<<"$j" | grep -q "False .*fleet-node-supervisor.py"'
check "C3 node-daemon red, names root" 'item node-daemon <<<"$j" | grep -q "False .*root: ccquota agent --machine"'
check "C4 admin-seat red for the admin only" 'item admin-seat <<<"$j" | grep -q "False .*alice" && ! item admin-seat <<<"$j" | grep -q bob'
ADMINS="root"
j=$(run --json)
check "C5 a non-admin login's agent is fine" 'item admin-seat <<<"$j" | grep -q "^admin-seat True"'
# a personal account running a machine service
printf 'bob /Users/bob/.claude/fleet/bin/fleet-memguard.sh --tick\n' > "$T/ps"
j=$(run --json)
check "C6 a machine service in a personal account is red" 'item node-daemon <<<"$j" | grep -q "False .*bob: fleet-memguard.sh"'
: > "$T/ps"
j=$(run --json)
check "C7 nothing running ⇒ the node items pass" '[ "$(item root-core <<<"$j" | cut -d" " -f2)" = True ]'

# D. the hub's half
HUB='{"items":[{"id":"release-key","pass":false,"why":"入口拿着发布签名私钥"}]}'
j=$(run --json)
check "D1 a hub FAIL is carried" 'item release-key <<<"$j" | grep -q "False 入口拿着"'
check "D2 an item the hub did not judge is red" 'item revocations <<<"$j" | grep -q "False 入口没判"'
HUB=''
j=$(run --json)
check "D3 no hub answer ⇒ every hub row red, said so" '[ "$(item cred-ttl <<<"$j")" = "cred-ttl False 入口没答" ]'
HUB='not json'
j=$(run --json)
check "D4 garbage ⇒ red" 'item cloud-perms <<<"$j" | grep -q "False 入口的回答读不懂"'

# E. --local: only node rows, never the hub
HUB='{"items":[]}'
j=$(run --local)
check "E1 --local carries the three node rows" '[ "$(python3 -c "import json,sys;print(len(json.load(sys.stdin)[\"items\"]))" <<<"$j")" = 3 ]'

# F. usage and a broken table
FLEET_GATE_TABLE="$T/none" bash "$G" >/dev/null 2>&1; rc=$?
check "F1 no table ⇒ exit 2" '[ "$rc" = 2 ]'
printf '1\tx\tmars\ta\tb\tc\td\n' > "$T/bad.tsv"
FLEET_GATE_TABLE="$T/bad.tsv" FLEET_GATE_PS="$T/ps" bash "$G" >/dev/null 2>&1; rc=$?
check "F2 a bad row ⇒ exit 2" '[ "$rc" = 2 ]'
bash "$G" --nope >/dev/null 2>&1; rc=$?
check "F3 unknown argument ⇒ exit 2" '[ "$rc" = 2 ]'

# G. the doctor's rows are INFO, never counted
check "G1 doctor runs the gate" 'grep -q "fleet-gate-check.sh" "$BIN/fleet-doctor.sh"'
check "G2 gate rows are info only" '! grep -E "^[[:space:]]*(fail|warn) gate" "$BIN/fleet-doctor.sh" | grep -q .'

[ "$fails" = 0 ] && { echo "fleet-gate-check-selftest: all passed"; exit 0; }
echo "fleet-gate-check-selftest: $fails failed"; exit 1
