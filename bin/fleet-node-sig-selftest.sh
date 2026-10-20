#!/bin/bash
# fleet-node-sig-selftest.sh — the shell's half of a node's signed requests
# (issue #3710, after #3699): fleet_node_auth (bin/fleet-lib.sh) and
# fleet_node_sig.py auth sign a request ONLY once the hub took this login's key
# (<key>.ok = "<keyid> <hub>", the agent's nodesig.Ensure writes it); every other
# case is `Bearer <token>`, byte for byte as before.
#   A. no key / a key with no .ok / a .ok of another key or hub → Bearer
#   B. a confirmed key → FleetSig over METHOD + the URL's path?query, a new
#      nonce every call, and the signature verifies (fleet_ed25519)
#   C. separated login (credsep.json) and CCQUOTA_NODE_KEY=off → Bearer;
#      CCQUOTA_NODE_KEY names another file
# Drives fleet-lib.sh, fleet_node_sig.py, fleet_ed25519.py.
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nodesig-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM
export FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$FLEET_CONF_DIR"
unset CCQUOTA_NODE_KEY
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
SIG="$BIN/fleet_node_sig.py"
HUB=https://hub.test

pass=0 FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then printf '  ok   %s\n' "$name"; pass=$((pass + 1))
  else st_miss "$name"; fi
}

echo "A  no confirmed key → the bearer"
check "no key file → Bearer" [ "$(fleet_node_auth GET "$HUB/v1/node/peers" tok-1)" = "Bearer tok-1" ]
python3 -I "$SIG" keygen "$FLEET_CONF_DIR/node.key" >/dev/null
KID=$(python3 -I "$SIG" keyid "$FLEET_CONF_DIR/node.key")
check "a key the hub has not taken (no .ok) → Bearer" [ "$(fleet_node_auth GET "$HUB/v1/node/peers" tok-1)" = "Bearer tok-1" ]
python3 -I "$SIG" auth "$FLEET_CONF_DIR/node.key" GET "$HUB/x" >/dev/null 2>&1; rc=$?
check "fleet_node_sig.py auth with no .ok → exit 3" [ "$rc" = 3 ]
echo "nk_000000000000000000000000 $HUB" > "$FLEET_CONF_DIR/node.key.ok"
check "a .ok naming another key → Bearer" [ "$(fleet_node_auth GET "$HUB/v1/node/peers" tok-1)" = "Bearer tok-1" ]
echo "$KID https://other.test" > "$FLEET_CONF_DIR/node.key.ok"
check "a .ok naming another hub → Bearer" [ "$(fleet_node_auth GET "$HUB/v1/node/peers" tok-1)" = "Bearer tok-1" ]
echo "$KID $HUB" > "$FLEET_CONF_DIR/node.key.ok"
check "a hub URL that only shares a prefix → Bearer" [ "$(fleet_node_auth GET "${HUB}x/v1/node/peers" tok-1)" = "Bearer tok-1" ]

echo "B  a confirmed key → FleetSig, once per call"
v1=$(fleet_node_auth POST "$HUB/v1/node/tasks?x=1" tok-1)
v2=$(fleet_node_auth POST "$HUB/v1/node/tasks?x=1" tok-1)
check "FleetSig keyid=$KID" sh -c "printf '%s' '$v1' | grep -q '^FleetSig keyid=$KID, ts=[0-9]*, nonce=[A-Za-z0-9_-]*, sig='"
check "the token is not in it" sh -c "! printf '%s' '$v1' | grep -q tok-1"
check "a new nonce every call" [ "$v1" != "$v2" ]
check "the signature verifies over POST + /v1/node/tasks?x=1" python3 -I - "$BIN" "$FLEET_CONF_DIR/node.key" "$v1" <<'PY'
import base64, sys
sys.path.insert(0, sys.argv[1])
import fleet_ed25519, fleet_node_sig
seed = fleet_node_sig._read_seed(sys.argv[2])
f = dict(p.strip().split("=", 1) for p in sys.argv[3][len("FleetSig "):].split(","))
msg = fleet_node_sig.message(f["keyid"], f["ts"], f["nonce"], "POST", "/v1/node/tasks?x=1")
sig = base64.urlsafe_b64decode(f["sig"] + "=" * (-len(f["sig"]) % 4))
pub = fleet_ed25519.public_key(seed)
sys.exit(0 if fleet_ed25519.verify(pub, msg, sig) else 1)
PY
check "a trailing slash on the .ok's hub is the same hub" bash -c "echo '$KID $HUB/' > '$FLEET_CONF_DIR/node.key.ok' && . '$BIN/fleet-lib.sh' && fleet_node_auth GET '$HUB/v1/node/peers' tok-1 | grep -q '^FleetSig '"
echo "$KID $HUB" > "$FLEET_CONF_DIR/node.key.ok"

echo "C  who never signs from the home"
check "CCQUOTA_NODE_KEY=off → Bearer" [ "$(CCQUOTA_NODE_KEY=off fleet_node_auth GET "$HUB/x" tok-1)" = "Bearer tok-1" ]
: > "$FLEET_CONF_DIR/credsep.json"
check "a separated login (credsep.json) → Bearer" [ "$(fleet_node_auth GET "$HUB/x" tok-1)" = "Bearer tok-1" ]
check "  … unless CCQUOTA_NODE_KEY names its key" bash -c "CCQUOTA_NODE_KEY='$FLEET_CONF_DIR/node.key' && export CCQUOTA_NODE_KEY && . '$BIN/fleet-lib.sh' && fleet_node_auth GET '$HUB/x' tok-1 | grep -q '^FleetSig '"
rm -f "$FLEET_CONF_DIR/credsep.json"

printf '\nfleet-node-sig-selftest: %d passed, %d failed\n' "$pass" "$FAIL"
st_done
