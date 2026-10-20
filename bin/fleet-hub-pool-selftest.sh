#!/bin/bash
# fleet-hub-pool-selftest.sh — a node takes the pool's setting from the hub
# (issue #2029): bin/fleet-hub-pool.sh (fetch / status), the hub-pool.env that
# bin/fleet-lib.sh sources before fleet.conf, and the quotawatch tick that runs
# the fetch. The hub is a file:// tree (/v1/fleet/client-settings is a file), so
# no port is bound; FLEET_CONF_DIR is a sandbox.
#
# Legs:
#   A. no hub      nothing configured → fetch exits 0 and writes nothing;
#                  fleet-lib.sh reads no CEILING/FAILOVER (byte for byte as
#                  before); a stale hub-pool.env from a removed hub is deleted
#   B. hub         pool 70 → hub-pool.env; fleet-lib.sh and fleet-account.sh's
#                  `CEILING=${FLEET_ACCOUNT_CEILING:-85}` read 70; status says 入口
#   C. local wins  fleet.conf FLEET_ACCOUNT_CEILING=90, an exported value → each
#                  wins over the hub
#   D. bad / old   an out-of-range value is dropped (named on stderr); a hub with
#                  no `pool` block and a hub out of reach leave the file as it was
#   G. retired     pool.move_when_full is gone (T543): an older hub's
#                  FLEET_FAILOVER=1 is never written, a file an older release
#                  wrote with FLEET_FAILOVER='1' reads as unset, and an exported
#                  value passes through untouched
#   E. TTL         a second fetch inside FLEET_HUB_POOL_SECS asks nothing;
#                  --force asks
#   F. tick        fleet-quotawatch.sh launches the fetch (and --status does not)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-hub-pool-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

export HOME="$WORK/home"
export FLEET_CONF_DIR="$WORK/conf"
unset FLEET_HUB_URL CCQUOTA_HUB_URL FLEET_ACCOUNT_CEILING FLEET_FAILOVER FLEET_HUB_POOL_SECS _FLEET_GLOBAL_CONF_SOURCED FLEET_SKIP_GLOBAL_CONF
HUBD="$WORK/hub"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$HUBD/v1/fleet"
OUT="$FLEET_CONF_DIR/hub-pool.env"
hub_says() {   # hub_says <ceiling> — the hub's answer
  printf '{"settings":{},"keys":[],"pool":{"FLEET_ACCOUNT_CEILING":"%s","FLEET_ACCOUNT_PAUSED":""}}\n' "$1" \
    > "$HUBD/v1/fleet/client-settings"
}
# reads <var> — what a fresh process sourcing fleet-lib.sh sees (unset ⇒ "-")
reads() { bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; eval "printf %s \"\${$2:--}\""' _ "$BIN" "$1"; }
# ceiling — fleet-account.sh's own line, under the lib
ceiling() { bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; CEILING="${FLEET_ACCOUNT_CEILING:-85}"; printf %s "$CEILING"' _ "$BIN"; }
fetch() { bash "$BIN/fleet-hub-pool.sh" fetch "$@"; }

# --- A. no hub --------------------------------------------------------------
hub_says 70
fetch; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$OUT" ] && [ "$(reads FLEET_ACCOUNT_CEILING)" = - ] && [ "$(reads FLEET_FAILOVER)" = - ] \
   && [ "$(ceiling)" = 85 ]; then
  ok "A no hub → nothing written, nothing read (85 / unset)"
else bad "A no hub: rc=$rc out=$([ -e "$OUT" ] && echo yes) ceil=$(ceiling)"; fi
echo "[ -n \"\${FLEET_ACCOUNT_CEILING+x}\" ] || FLEET_ACCOUNT_CEILING='70'" > "$OUT"
fetch
[ ! -e "$OUT" ] && ok "A a removed hub's file is deleted" || bad "A stale hub-pool.env kept with no hub"

# --- B. hub ------------------------------------------------------------------
printf 'FLEET_HUB_URL=file://%s\n' "$HUBD" > "$FLEET_CONF_DIR/fleet.conf"
fetch; rc=$?
st=$(bash "$BIN/fleet-hub-pool.sh" status)
if [ "$rc" = 0 ] && [ -f "$OUT" ] && [ "$(ceiling)" = 70 ] \
   && [ "$st" = "FLEET_ACCOUNT_CEILING	70	入口" ]; then
  ok "B hub 70 → fleet-account.sh reads 70; status 入口"
else bad "B hub: rc=$rc ceil=$(ceiling) status=[$st]"; fi

# --- C. local wins -------------------------------------------------------------
echo 'FLEET_ACCOUNT_CEILING=90' >> "$FLEET_CONF_DIR/fleet.conf"
st=$(bash "$BIN/fleet-hub-pool.sh" status)
if [ "$(ceiling)" = 90 ] && printf '%s\n' "$st" | grep -q "^FLEET_ACCOUNT_CEILING	90	本机$"; then
  ok "C fleet.conf 90 wins over the hub's 70 (status 本机)"
else bad "C fleet.conf: ceil=$(ceiling) status=[$st]"; fi
printf 'FLEET_HUB_URL=file://%s\n' "$HUBD" > "$FLEET_CONF_DIR/fleet.conf"
[ "$(FLEET_ACCOUNT_CEILING=60 ceiling)" = 60 ] && ok "C an exported value wins" || bad "C env: $(FLEET_ACCOUNT_CEILING=60 ceiling)"

# --- D. bad / old / unreachable ----------------------------------------------
hub_says 500
err=$(fetch --force 2>&1 >/dev/null)
if ! grep -q FLEET_ACCOUNT_CEILING "$OUT" && printf '%s' "$err" | grep -q 'FLEET_ACCOUNT_CEILING 不合规'; then
  ok "D an out-of-range CEILING is dropped and named"
else bad "D bad value: err=[$err] file=[$(cat "$OUT")]"; fi
hub_says 70; fetch --force
before=$(cat "$OUT")
echo '{"settings":{},"keys":[]}' > "$HUBD/v1/fleet/client-settings"
fetch --force
[ "$(cat "$OUT")" = "$before" ] && ok "D a hub with no pool block leaves the file" || bad "D old hub changed the file"
rm -f "$HUBD/v1/fleet/client-settings"
fetch --force; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$OUT")" = "$before" ] && ok "D a hub out of reach → exit 1, file kept" || bad "D unreachable: rc=$rc"

# --- E. TTL --------------------------------------------------------------------
hub_says 55
fetch                                   # inside the TTL of the last --force
[ "$(ceiling)" = 70 ] && ok "E inside FLEET_HUB_POOL_SECS: nothing asked" || bad "E TTL: ceil=$(ceiling)"
FLEET_HUB_POOL_SECS=0 fetch
[ "$(ceiling)" = 55 ] && ok "E past the TTL: the new value" || bad "E past TTL: ceil=$(ceiling)"

# --- F. the quotawatch tick launches it ------------------------------------------
grep -q 'fleet-hub-pool.sh" fetch' "$BIN/fleet-quotawatch.sh" \
  && awk '/fleet-hub-pool.sh" fetch/{exit !(p ~ /STATUS" = 0/ && p ~ /DRY" = 0/)} {p=$0}' "$BIN/fleet-quotawatch.sh" \
  && ok "F fleet-quotawatch.sh fetches on a working tick only" || bad "F quotawatch does not launch the fetch on a working tick"

# --- G. pool.move_when_full retired (T543) ---------------------------------------
printf '{"settings":{},"keys":[],"pool":{"FLEET_ACCOUNT_CEILING":"70","FLEET_FAILOVER":"1","FLEET_ACCOUNT_PAUSED":""}}\n' \
  > "$HUBD/v1/fleet/client-settings"
fetch --force
if ! grep -q FLEET_FAILOVER "$OUT" && [ "$(ceiling)" = 70 ] && [ "$(reads FLEET_FAILOVER)" = - ]; then
  ok "G an older hub's FLEET_FAILOVER=1 is never written"
else bad "G older hub: file=[$(cat "$OUT")] fo=$(reads FLEET_FAILOVER)"; fi
printf '%s\n' "[ -n \"\${FLEET_ACCOUNT_CEILING+x}\" ] || FLEET_ACCOUNT_CEILING='70'" \
  "[ -n \"\${FLEET_FAILOVER+x}\" ] || FLEET_FAILOVER='1'" > "$OUT"
if [ "$(reads FLEET_FAILOVER)" = - ] && [ "$(ceiling)" = 70 ] \
   && [ "$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; [ -z "${FLEET_FAILOVER+x}" ] && echo unset' _ "$BIN")" = unset ]; then
  ok "G an old hub-pool.env's FLEET_FAILOVER='1' reads as unset (0)"
else bad "G old file: fo=$(reads FLEET_FAILOVER)"; fi
[ "$(FLEET_FAILOVER=0 reads FLEET_FAILOVER)" = 0 ] && [ "$(FLEET_FAILOVER=1 reads FLEET_FAILOVER)" = 1 ] \
  && ok "G an exported FLEET_FAILOVER passes through as it was" || bad "G env: $(FLEET_FAILOVER=0 reads FLEET_FAILOVER)"

[ "$fail" = 0 ] && echo "PASS fleet-hub-pool-selftest" || echo "FAIL fleet-hub-pool-selftest"
exit "$fail"
