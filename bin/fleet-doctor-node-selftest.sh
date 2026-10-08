#!/bin/bash
# fleet-doctor-node-selftest.sh — the node-token verdict in bin/fleet-doctor.sh (issue
# #1491), carried by the `承载` row since issue #1806 (it was a row of its own,
# `node`): with CCQUOTA_FLEET=1, can `ccquota lease|place|move` act for this login?
# They act as this machine's agent and need its token — CCQUOTA_TOKEN in the
# environment, else $FLEET_CONF_DIR/node.env (fleet_hub_* read it per call). With
# neither, the entry's lease / placement / move all fell back SILENTLY on two
# machines for a day (EPIC #1419 C3/C6/C7), which is what this line exists to say.
#
#   OFF      CCQUOTA_FLEET unset everywhere → no token verdict: the 承载 row (this
#            login has a fleet, so it hosts) says 不接入口 (the degenerate case)
#   MISSING  on, ccquota on PATH, no token, no node.env → WARN naming node.env and
#            the one command that writes it (fleet-hub-node.sh env --write)
#   FILE     node.env 0600 with a token → PASS, 「不进窗格环境」
#   PERMS    node.env 0644 → WARN, chmod 600
#   NOLINE   node.env without a CCQUOTA_TOKEN= line → WARN, --write --force
#   EXPORT   CCQUOTA_TOKEN exported (the pre-#1491 fleet.conf stop-gap) → WARN:
#            every worker inherits the credential; drop the export (with node.env),
#            or write the file first (without)
#   NOCCQ    on, no ccquota on PATH → WARN, install the agent
#   CONF     the switch read from the install's fleet.conf (`export CCQUOTA_FLEET=1`,
#            how the operator spells it) and from a fleet's conf, not only the env
#
# Hermetic: a FAKE ccquota on PATH, scratch conf dir, HOME, TMPDIR. No network, no
# tmux. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-account.sh fleet_iso.py fleet-lib.sh usage-lib.sh fleet-quotawatch.sh fleet-hub-node.sh fleet-daemon-lib.sh fleet-conf.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-node-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/ccq" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in fleet-doctor.sh fleet-account.sh fleet_iso.py fleet-lib.sh usage-lib.sh fleet-quotawatch.sh fleet-hub-node.sh fleet-daemon-lib.sh fleet-conf.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
cat > "$WORK/ccq/ccquota" <<'FAKE'
#!/bin/bash
[ "${1:-}" = version ] && { echo 'ccquota 9.9.9-testbuild'; exit 0; }
exit 0
FAKE
chmod +x "$WORK/ccq/ccquota"
NE="$WORK/conf/node.env"
unset CCQUOTA_FLEET CCQUOTA_TOKEN CCQUOTA_HUB_URL

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- node line(s) ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS+1)); }
contains() { case "$2" in *"$3"*) ok ;; *) fail "$1 — lacks [$3]" "$2" ;; esac; }
not_contains() { case "$2" in *"$3"*) fail "$1 — carries [$3]" "$2" ;; *) ok ;; esac; }
# node_lines [CCQUOTA_FLEET=…] [CCQUOTA_TOKEN=…] → the doctor's `承载` line(s)
# only; the rest of the doctor is the host's business. NOCCQ=1 = no ccquota on PATH.
node_lines() {
  local p="$WORK/ccq:$PATH"
  # NOCCQ: the system dirs only — the operator's PATH may carry a real ccquota
  [ "${NOCCQ:-0}" = 1 ] && p="/usr/bin:/bin:/usr/sbin:/sbin"
  env "$@" PATH="$p" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
    bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+承载([[:space:]]|$)'
}

# OFF
l=$(node_lines)
contains "OFF: the 承载 row says no hub" "$l" "PASS  承载"
contains "OFF: 不接入口" "$l" "不接入口（只走本机）"
not_contains "OFF: no token verdict" "$l" "node.env"

# MISSING
l=$(node_lines CCQUOTA_FLEET=1)
contains "MISSING: WARN" "$l" "WARN  承载"
contains "MISSING: names node.env" "$l" "CCQUOTA_TOKEN unset and $NE missing"
contains "MISSING: says what falls back" "$l" "lease / placement / move all fall back silently"
contains "MISSING: the fix" "$l" "fleet-hub-node.sh env --write"
contains "MISSING: the issue" "$l" "issue #1491"

# FILE
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\n' > "$NE"; chmod 600 "$NE"
l=$(node_lines CCQUOTA_FLEET=1)
contains "FILE: PASS" "$l" "PASS  承载"
contains "FILE: names the file" "$l" "通行证 ~/conf/node.env（0600"
contains "FILE: says the token stays out of panes" "$l" "不进窗格环境"
not_contains "FILE: the token's value is never printed" "$l" "fn_abc"

# PERMS
chmod 644 "$NE"
l=$(node_lines CCQUOTA_FLEET=1)
contains "PERMS: WARN" "$l" "WARN  承载"
contains "PERMS: chmod 600" "$l" "group/other-readable (-rw-r--r--) — \`chmod 600 $NE\`"
chmod 600 "$NE"

# NOLINE
printf 'CCQUOTA_HUB_URL=https://hub.test\n' > "$NE"
l=$(node_lines CCQUOTA_FLEET=1)
contains "NOLINE: WARN" "$l" "WARN  承载"
contains "NOLINE: names the missing line" "$l" "$NE has no CCQUOTA_TOKEN= line"
contains "NOLINE: --write --force" "$l" "fleet-hub-node.sh env --write --force"

# EXPORT
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\n' > "$NE"; chmod 600 "$NE"
l=$(node_lines CCQUOTA_FLEET=1 CCQUOTA_TOKEN=fn_env)
contains "EXPORT+file: WARN" "$l" "WARN  承载"
contains "EXPORT+file: every worker inherits it" "$l" "every worker spawned from a pane inherits a node credential"
contains "EXPORT+file: drop the export" "$l" "drop the export"
not_contains "EXPORT+file: the token's value is never printed" "$l" "fn_env"
rm -f "$NE"
l=$(node_lines CCQUOTA_FLEET=1 CCQUOTA_TOKEN=fn_env)
contains "EXPORT-nofile: WARN" "$l" "WARN  承载"
contains "EXPORT-nofile: node.env missing" "$l" "$NE is missing"
contains "EXPORT-nofile: write the file, then drop" "$l" "write the file, then drop the export"

# NOCCQ (skipped where a ccquota sits in a system dir — nothing to hide it behind)
if PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v ccquota >/dev/null 2>&1; then
  echo "NOCCQ: skip — a ccquota lives in a system dir here"
else
  l=$(NOCCQ=1 node_lines CCQUOTA_FLEET=1)
  contains "NOCCQ: WARN" "$l" "WARN  承载"
  contains "NOCCQ: ccquota not on PATH" "$l" "ccquota is not on PATH"
  contains "NOCCQ: install" "$l" "fleet-node-join.sh"
fi

# CONF: the switch from the install's fleet.conf (export spelling) …
printf 'export CCQUOTA_FLEET=1\n' > "$WORK/fleet.conf"
l=$(node_lines)
contains "CONF install: read through `export`" "$l" "WARN  承载"
contains "CONF install: the MISSING verdict" "$l" "$NE missing"
printf '# export CCQUOTA_FLEET=1\n' > "$WORK/fleet.conf"
l=$(node_lines)
contains "CONF install: a commented switch is off" "$l" "不接入口"
rm -f "$WORK/fleet.conf"
# … and from a fleet's conf
printf 'FLEET_REPO="acme/widgets"\nCCQUOTA_FLEET=1\n' > "$WORK/conf/fleets/sessA/conf"
l=$(node_lines)
contains "CONF fleet: read from fleets/<sess>/conf" "$l" "WARN  承载"
printf 'FLEET_REPO="acme/widgets"\nCCQUOTA_FLEET=0\n' > "$WORK/conf/fleets/sessA/conf"
l=$(node_lines)
contains "CONF fleet: CCQUOTA_FLEET=0 is off" "$l" "不接入口"

# TRUST (issue #1968): the `可信` row reads this machine's word off the hub
# (GET /v1/node/self through fleet-node-trust.sh, the transport stubbed) — only
# where the token row passed; no fleet-node-trust.sh / no hub → no row.
trust_lines() {
  env "$@" PATH="$WORK/ccq:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
    FLEET_HUB_CURL="$WORK/trustcurl" bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+可信([[:space:]]|$)'
}
rm -f "$WORK/conf/fleets/sessA/conf"; printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\n' > "$NE"; chmod 600 "$NE"
l=$(trust_lines CCQUOTA_FLEET=1)
[ -z "$l" ] && ok || fail "TRUST: a row without fleet-node-trust.sh" "$l"
cp "$BIN/fleet-node-trust.sh" "$WORK/bin/"; chmod +x "$WORK/bin/fleet-node-trust.sh"
cat > "$WORK/trustcurl" <<'FAKE'
#!/bin/bash
cat >/dev/null
[ -n "${TRUST_RC:-}" ] && exit "$TRUST_RC"
printf '{"hostname":"m9.local","status":"online","trust":"%s"}\n200' "$TRUST_WORD"
FAKE
chmod +x "$WORK/trustcurl"
l=$(trust_lines CCQUOTA_FLEET=1 TRUST_WORD=trusted)
contains "TRUST: trusted → PASS" "$l" "PASS  可信"
contains "TRUST: names the machine" "$l" "m9 · 可信"
l=$(trust_lines CCQUOTA_FLEET=1 TRUST_WORD=untrusted)
contains "TRUST: untrusted → WARN" "$l" "WARN  可信"
contains "TRUST: names the fix" "$l" "fleet-node-trust.sh set m9 trusted"
l=$(trust_lines CCQUOTA_FLEET=1 TRUST_WORD=untrusted FLEET_CRED_PROXY=1)
contains "TRUST: untrusted behind the proxy → INFO" "$l" "INFO  可信"
l=$(trust_lines CCQUOTA_FLEET=1 TRUST_RC=7)
contains "TRUST: hub down → INFO" "$l" "INFO  可信"
not_contains "TRUST: the token's value is never printed" "$l" "fn_abc"
l=$(trust_lines TRUST_WORD=trusted)
[ -z "$l" ] && ok || fail "TRUST: a row with the hub off" "$l"

# COMPUTE (issue #2480): node.env's CCQUOTA_FLEET_COMPUTE beside the hub's own
# verdict (compute_off / compute_why off GET /v1/node/self, fleet-node-trust.sh
# self --json): off says why and how to open it; on passes; the hub off → no row.
compute_lines() {
  env "$@" PATH="$WORK/ccq:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
    FLEET_HUB_CURL="$WORK/computecurl" bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+compute([[:space:]]|$)'
}
cat > "$WORK/computecurl" <<'FAKE'
#!/bin/bash
cat >/dev/null
[ -n "${TRUST_RC:-}" ] && exit "$TRUST_RC"
if [ "${COMPUTE_OFF:-}" = 1 ]; then
  printf '{"hostname":"m9.local","status":"online","trust":"trusted","compute_off":true,"compute_why":"%s"}\n200' "$COMPUTE_WHY"
else
  printf '{"hostname":"m9.local","status":"online","trust":"trusted"}\n200'
fi
FAKE
chmod +x "$WORK/computecurl"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\nCCQUOTA_FLEET_COMPUTE=0\n' > "$NE"; chmod 600 "$NE"
l=$(compute_lines CCQUOTA_FLEET=1 COMPUTE_OFF=1 "COMPUTE_WHY=compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)")
case "$l" in *"WARN  compute"*|*"INFO  compute"*) ok ;; *) fail "COMPUTE: off is not a WARN / INFO" "$l" ;; esac
contains "COMPUTE: off names the machine and login" "$l" "m9/$(id -un) · 只协调"
contains "COMPUTE: off says how to open it" "$l" "fleet host on（即 node.env CCQUOTA_FLEET_COMPUTE=1）"
contains "COMPUTE: off names the team policy" "$l" "fleet.compute_auto"
not_contains "COMPUTE: the token's value is never printed" "$l" "fn_abc"
l=$(compute_lines CCQUOTA_FLEET=1 COMPUTE_OFF=1 "COMPUTE_WHY=compute off (出口地区 CN 不在 Claude / OpenAI 支持范围)")
contains "COMPUTE: a closed region says --force" "$l" "fleet host on --force"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\nCCQUOTA_FLEET_COMPUTE=1\n' > "$NE"; chmod 600 "$NE"
l=$(compute_lines CCQUOTA_FLEET=1)
contains "COMPUTE: on → PASS" "$l" "PASS  compute"
contains "COMPUTE: on says node.env" "$l" "CCQUOTA_FLEET_COMPUTE=1"
l=$(compute_lines CCQUOTA_FLEET=1 COMPUTE_OFF=1 "COMPUTE_WHY=compute off (只协调: CCQUOTA_FLEET_COMPUTE=0)")
contains "COMPUTE: node.env on, hub off → says the beat" "$l" "下一次心跳"
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\nCCQUOTA_FLEET_COMPUTE=0\n' > "$NE"; chmod 600 "$NE"
l=$(compute_lines CCQUOTA_FLEET=1 TRUST_RC=7)
contains "COMPUTE: hub down, node.env 0 → still says it" "$l" "CCQUOTA_FLEET_COMPUTE=0：只协调"
l=$(compute_lines COMPUTE_OFF=1)
[ -z "$l" ] && ok || fail "COMPUTE: a row with the hub off" "$l"

printf 'fleet-doctor-node-selftest OK (%s checks)\n' "$CHECKS"
