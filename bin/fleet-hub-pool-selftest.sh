#!/bin/bash
# fleet-hub-pool-selftest.sh — a node takes the pool's setting from the hub
# (issue #2029): bin/fleet-hub-pool.sh (fetch / status), the hub-pool.env that
# bin/fleet-lib.sh sources before fleet.conf, and the reconcile tick that runs
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
#   F. tick        fleet-reconcile-tick.sh launches the fetch
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-hub-pool-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
st_tally

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
  st_ok_all "A no hub → nothing written, nothing read (85 / unset)"
else st_miss "A no hub: rc=$rc out=$([ -e "$OUT" ] && echo yes) ceil=$(ceiling)"; fi
echo "[ -n \"\${FLEET_ACCOUNT_CEILING+x}\" ] || FLEET_ACCOUNT_CEILING='70'" > "$OUT"
fetch
[ ! -e "$OUT" ] && st_ok_all "A a removed hub's file is deleted" || st_miss "A stale hub-pool.env kept with no hub"

# --- B. hub ------------------------------------------------------------------
printf 'FLEET_HUB_URL=file://%s\n' "$HUBD" > "$FLEET_CONF_DIR/fleet.conf"
fetch; rc=$?
st=$(bash "$BIN/fleet-hub-pool.sh" status)
if [ "$rc" = 0 ] && [ -f "$OUT" ] && [ "$(ceiling)" = 70 ] \
   && [ "$st" = "FLEET_ACCOUNT_CEILING	70	入口" ]; then
  st_ok_all "B hub 70 → fleet-account.sh reads 70; status 入口"
else st_miss "B hub: rc=$rc ceil=$(ceiling) status=[$st]"; fi

# --- C. local wins -------------------------------------------------------------
echo 'FLEET_ACCOUNT_CEILING=90' >> "$FLEET_CONF_DIR/fleet.conf"
st=$(bash "$BIN/fleet-hub-pool.sh" status)
if [ "$(ceiling)" = 90 ] && printf '%s\n' "$st" | grep -q "^FLEET_ACCOUNT_CEILING	90	本机$"; then
  st_ok_all "C fleet.conf 90 wins over the hub's 70 (status 本机)"
else st_miss "C fleet.conf: ceil=$(ceiling) status=[$st]"; fi
printf 'FLEET_HUB_URL=file://%s\n' "$HUBD" > "$FLEET_CONF_DIR/fleet.conf"
[ "$(FLEET_ACCOUNT_CEILING=60 ceiling)" = 60 ] && st_ok_all "C an exported value wins" || st_miss "C env: $(FLEET_ACCOUNT_CEILING=60 ceiling)"

# --- D. bad / old / unreachable ----------------------------------------------
hub_says 500
err=$(fetch --force 2>&1 >/dev/null)
if ! grep -q FLEET_ACCOUNT_CEILING "$OUT" && printf '%s' "$err" | grep -q 'FLEET_ACCOUNT_CEILING 不合规'; then
  st_ok_all "D an out-of-range CEILING is dropped and named"
else st_miss "D bad value: err=[$err] file=[$(cat "$OUT")]"; fi
hub_says 70; fetch --force
before=$(cat "$OUT")
echo '{"settings":{},"keys":[]}' > "$HUBD/v1/fleet/client-settings"
fetch --force
[ "$(cat "$OUT")" = "$before" ] && st_ok_all "D a hub with no pool block leaves the file" || st_miss "D old hub changed the file"
rm -f "$HUBD/v1/fleet/client-settings"
fetch --force; rc=$?
[ "$rc" = 1 ] && [ "$(cat "$OUT")" = "$before" ] && st_ok_all "D a hub out of reach → exit 1, file kept" || st_miss "D unreachable: rc=$rc"

# --- E. TTL --------------------------------------------------------------------
hub_says 55
fetch                                   # inside the TTL of the last --force
[ "$(ceiling)" = 70 ] && st_ok_all "E inside FLEET_HUB_POOL_SECS: nothing asked" || st_miss "E TTL: ceil=$(ceiling)"
FLEET_HUB_POOL_SECS=0 fetch
[ "$(ceiling)" = 55 ] && st_ok_all "E past the TTL: the new value" || st_miss "E past TTL: ceil=$(ceiling)"

# --- F. the reconcile tick launches it (it took it from the quota watch, T549) ----
grep -q 'fleet-hub-pool.sh" fetch' "$BIN/fleet-reconcile-tick.sh" \
  && st_ok_all "F fleet-reconcile-tick.sh launches the fetch" || st_miss "F the reconcile tick does not launch the fetch"

# --- G. pool.move_when_full retired (T543) ---------------------------------------
printf '{"settings":{},"keys":[],"pool":{"FLEET_ACCOUNT_CEILING":"70","FLEET_FAILOVER":"1","FLEET_ACCOUNT_PAUSED":""}}\n' \
  > "$HUBD/v1/fleet/client-settings"
fetch --force
if ! grep -q FLEET_FAILOVER "$OUT" && [ "$(ceiling)" = 70 ] && [ "$(reads FLEET_FAILOVER)" = - ]; then
  st_ok_all "G an older hub's FLEET_FAILOVER=1 is never written"
else st_miss "G older hub: file=[$(cat "$OUT")] fo=$(reads FLEET_FAILOVER)"; fi
printf '%s\n' "[ -n \"\${FLEET_ACCOUNT_CEILING+x}\" ] || FLEET_ACCOUNT_CEILING='70'" \
  "[ -n \"\${FLEET_FAILOVER+x}\" ] || FLEET_FAILOVER='1'" > "$OUT"
if [ "$(reads FLEET_FAILOVER)" = - ] && [ "$(ceiling)" = 70 ] \
   && [ "$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; [ -z "${FLEET_FAILOVER+x}" ] && echo unset' _ "$BIN")" = unset ]; then
  st_ok_all "G an old hub-pool.env's FLEET_FAILOVER='1' reads as unset (0)"
else st_miss "G old file: fo=$(reads FLEET_FAILOVER)"; fi
[ "$(FLEET_FAILOVER=0 reads FLEET_FAILOVER)" = 0 ] && [ "$(FLEET_FAILOVER=1 reads FLEET_FAILOVER)" = 1 ] \
  && st_ok_all "G an exported FLEET_FAILOVER passes through as it was" || st_miss "G env: $(FLEET_FAILOVER=0 reads FLEET_FAILOVER)"

# C6: retention must survive the hub -> node whitelist, not only the API response.
printf '{"pool":{"FLEET_SESSION_REAP_PARKED":"345600"}}\n' > "$HUBD/v1/fleet/client-settings"
fetch --force
[ "$(reads FLEET_SESSION_REAP_PARKED)" = 345600 ] \
  && st_ok_all "H parked retention reaches node settings" || st_miss "H retention dropped"
printf '{"pool":{"FLEET_SESSION_REAP_PARKED":"30"}}\n' > "$HUBD/v1/fleet/client-settings"
fetch --force 2>/dev/null
[ "$(reads FLEET_SESSION_REAP_PARKED)" = - ] \
  && st_ok_all "H invalid retention is refused" || st_miss "H invalid retention kept"

st_done
