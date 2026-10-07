#!/usr/bin/env bash
# fleet-hub-pool.sh — this machine takes the subscription pool's two settings
# from the hub (issue #2029).
#
# #1986 put pool.skip_pct / pool.move_when_full on the hub (an admin's
# `fleet hub set`, audited); the hub hands them out in the `pool` block of
# GET /v1/fleet/client-settings under the names a node's fleet.conf gives them:
#
#   pool.skip_pct        → FLEET_ACCOUNT_CEILING   an integer 1–100
#   pool.move_when_full  → FLEET_FAILOVER          0 | 1
#
# `fetch` writes them to $FLEET_CONF_DIR/hub-pool.env, which fleet-lib.sh
# sources FIRST, beside hub-defaults.conf — so the order is the one the client
# defaults already use: hub < fleet.conf < a fleet's own conf < the environment.
# Each line is `[ -n "${KEY+x}" ] || KEY='value'`: a key this machine set always
# wins, a line here only fills the gap the built-in default (85 / 0) used to.
# Not a `*.conf` on purpose: the legacy scans read every $FLEET_CONF_DIR/*.conf
# as a fleet.
#
# No hub configured (FLEET_HUB_URL / CCQUOTA_HUB_URL) ⇒ the file is removed and
# everything reads as before. A hub out of reach, an answer with no `pool`, or a
# value out of range ⇒ the file stays as it was (a bad value is dropped, named
# on stderr). Called by the quotawatch tick (backgrounded, at most once per
# FLEET_HUB_POOL_SECS, default 300); never edit the file by hand.
#
# Usage:
#   fleet-hub-pool.sh fetch [--force]   ask the hub (TTL-gated unless --force)
#   fleet-hub-pool.sh status            what this machine reads, and from where
#
# Exit: 0 ok / nothing to do · 1 the hub could not be read · 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
TMO="${FLEET_HUB_POOL_TIMEOUT:-5}"

# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"                                   # FLEET_HUB_URL, from fleet.conf
CONF_DIR="${FLEET_CONF_DIR:-$CONF_DIR}"; OUT="$CONF_DIR/hub-pool.env"
hub_url() { local u="${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}"; printf '%s' "${u%/}"; }

cmd_fetch() {
  local force=0 hub secs now f
  [ "${1:-}" = --force ] && force=1
  hub=$(hub_url)
  if [ -z "$hub" ]; then rm -f "$OUT"; return 0; fi     # no hub: as before
  mkdir -p "$CONF_DIR" 2>/dev/null || return 1
  secs="${FLEET_HUB_POOL_SECS:-300}"; case "$secs" in ''|*[!0-9]*) secs=300 ;; esac
  now=$(date +%s)
  if [ "$force" = 0 ] && [ -f "$CONF_DIR/.hub-pool.checked" ] \
     && [ $(( now - $(cat "$CONF_DIR/.hub-pool.checked" 2>/dev/null || echo 0) )) -lt "$secs" ]; then
    return 0
  fi
  printf '%s\n' "$now" > "$CONF_DIR/.hub-pool.checked"
  f=$(mktemp "${TMPDIR:-/tmp}/fleet-hub-pool.XXXXXX") || return 1
  if ! curl -fsS --max-time "$TMO" "$hub/v1/fleet/client-settings" -o "$f" 2>/dev/null; then
    rm -f "$f"; return 1                                # out of reach: the file stays
  fi
  python3 - "$f" "$OUT" "$hub" <<'PY'
import json, os, re, sys
src, dst, hub = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    pool = json.load(open(src)).get("pool")
except Exception:
    sys.exit(1)
if not isinstance(pool, dict):
    sys.exit(0)                     # an older hub: no pool block, the file stays
rules = {
    "FLEET_ACCOUNT_CEILING": lambda v: re.fullmatch(r"[0-9]{1,3}", v) and 1 <= int(v) <= 100,
    "FLEET_FAILOVER": lambda v: v in ("0", "1"),
}
lines = []
for k in sorted(rules):
    v = pool.get(k)
    if v is None:
        continue
    if not isinstance(v, str) or not rules[k](v):
        sys.stderr.write("fleet: 入口下发的 %s 不合规，没写\n" % k)
        continue
    lines.append("[ -n \"${%s+x}\" ] || %s='%s'\n" % (k, k, v))
body = ("# hub-pool.env — the subscription pool's settings from %s (claude-fleet#2029).\n"
        "# Written by fleet-hub-pool.sh; never edit it. Read FIRST, so a key this\n"
        "# machine sets (fleet.conf, a fleet's conf, the environment) wins.\n" % hub) + "".join(lines)
try:
    if open(dst).read() == body:
        sys.exit(0)
except OSError:
    pass
tmp = dst + ".tmp"
with open(tmp, "w") as fh:
    fh.write(body)
os.chmod(tmp, 0o644)
os.replace(tmp, dst)
PY
  local rc=$?
  rm -f "$f"
  return "$rc"
}

# _eff <key> [skip-hub] — what a fresh process here reads for <key>
_eff() {
  env -u "$1" FLEET_CONF_DIR="$CONF_DIR" FLEET_SKIP_HUB_POOL="${2:-}" \
    _FLEET_GLOBAL_CONF_SOURCED= bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; eval "printf %s \"\${$2:-}\""' _ "$BIN" "$1"
}
# status — each key: the value fleet-account.sh reads, and where it came from
# (入口 the hub · 本机 this machine's conf · 默认 the built-in default)
cmd_status() {
  local k eff own src
  for k in FLEET_ACCOUNT_CEILING FLEET_FAILOVER; do
    eff=$(_eff "$k"); own=$(_eff "$k" 1)
    if [ -n "$own" ]; then src=本机
    elif [ -n "$eff" ]; then src=入口
    else src=默认; case "$k" in FLEET_ACCOUNT_CEILING) eff=85 ;; *) eff=0 ;; esac
    fi
    printf '%s\t%s\t%s\n' "$k" "$eff" "$src"
  done
}

case "${1:-}" in
  fetch)  shift; cmd_fetch "$@" ;;
  status) cmd_status ;;
  -h|--help) sed -n '2,32p' "$0" ;;
  *) printf 'usage: fleet-hub-pool.sh fetch [--force] | status\n' >&2; exit 2 ;;
esac
