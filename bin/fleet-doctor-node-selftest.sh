#!/bin/bash
# fleet-doctor-node-selftest.sh — the `node` verdict in bin/fleet-doctor.sh (issue
# #1491): with CCQUOTA_FLEET=1, can `ccquota lease|place|move` act for this login?
# They act as this machine's agent and need its token — CCQUOTA_TOKEN in the
# environment, else $FLEET_CONF_DIR/node.env (fleet_hub_* read it per call). With
# neither, the entry's lease / placement / move all fell back SILENTLY on two
# machines for a day (EPIC #1419 C3/C6/C7), which is what this line exists to say.
#
#   OFF      CCQUOTA_FLEET unset everywhere → NO `node` line (the degenerate case)
#   MISSING  on, ccquota on PATH, no token, no node.env → WARN naming node.env and
#            the one command that writes it (fleet-hub-node.sh env --write)
#   FILE     node.env 0600 with a token → PASS, "never enters a pane's environment"
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
for f in fleet-doctor.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-quotawatch.sh fleet-hub-node.sh fleet-daemon-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-node-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/ccq" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in fleet-doctor.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-quotawatch.sh fleet-hub-node.sh fleet-daemon-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
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
# node_lines [CCQUOTA_FLEET=…] [CCQUOTA_TOKEN=…] → the doctor's `node` line(s)
# only; the rest of the doctor is the host's business. NOCCQ=1 = no ccquota on PATH.
node_lines() {
  local p="$WORK/ccq:$PATH"
  # NOCCQ: the system dirs only — the operator's PATH may carry a real ccquota
  [ "${NOCCQ:-0}" = 1 ] && p="/usr/bin:/bin:/usr/sbin:/sbin"
  env "$@" PATH="$p" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
    bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+node([[:space:]]|$)'
}

# OFF
l=$(node_lines)
[ -z "$l" ] || fail "OFF: with CCQUOTA_FLEET unset the doctor must print no node line" "$l"
ok

# MISSING
l=$(node_lines CCQUOTA_FLEET=1)
contains "MISSING: WARN" "$l" "WARN  node"
contains "MISSING: names node.env" "$l" "CCQUOTA_TOKEN unset and $NE missing"
contains "MISSING: says what falls back" "$l" "lease / placement / move all fall back silently"
contains "MISSING: the fix" "$l" "fleet-hub-node.sh env --write"
contains "MISSING: the issue" "$l" "issue #1491"

# FILE
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\n' > "$NE"; chmod 600 "$NE"
l=$(node_lines CCQUOTA_FLEET=1)
contains "FILE: PASS" "$l" "PASS  node"
contains "FILE: names the file" "$l" "node token in $NE (0600)"
contains "FILE: says the token stays out of panes" "$l" "never enters a pane's environment"
not_contains "FILE: the token's value is never printed" "$l" "fn_abc"

# PERMS
chmod 644 "$NE"
l=$(node_lines CCQUOTA_FLEET=1)
contains "PERMS: WARN" "$l" "WARN  node"
contains "PERMS: chmod 600" "$l" "group/other-readable (-rw-r--r--) — \`chmod 600 $NE\`"
chmod 600 "$NE"

# NOLINE
printf 'CCQUOTA_HUB_URL=https://hub.test\n' > "$NE"
l=$(node_lines CCQUOTA_FLEET=1)
contains "NOLINE: WARN" "$l" "WARN  node"
contains "NOLINE: names the missing line" "$l" "$NE has no CCQUOTA_TOKEN= line"
contains "NOLINE: --write --force" "$l" "fleet-hub-node.sh env --write --force"

# EXPORT
printf 'CCQUOTA_HUB_URL=https://hub.test\nCCQUOTA_TOKEN=fn_abc\n' > "$NE"; chmod 600 "$NE"
l=$(node_lines CCQUOTA_FLEET=1 CCQUOTA_TOKEN=fn_env)
contains "EXPORT+file: WARN" "$l" "WARN  node"
contains "EXPORT+file: every worker inherits it" "$l" "every worker spawned from a pane inherits a node credential"
contains "EXPORT+file: drop the export" "$l" "drop the export"
not_contains "EXPORT+file: the token's value is never printed" "$l" "fn_env"
rm -f "$NE"
l=$(node_lines CCQUOTA_FLEET=1 CCQUOTA_TOKEN=fn_env)
contains "EXPORT-nofile: WARN" "$l" "WARN  node"
contains "EXPORT-nofile: node.env missing" "$l" "$NE is missing"
contains "EXPORT-nofile: write the file, then drop" "$l" "write the file, then drop the export"

# NOCCQ (skipped where a ccquota sits in a system dir — nothing to hide it behind)
if PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v ccquota >/dev/null 2>&1; then
  echo "NOCCQ: skip — a ccquota lives in a system dir here"
else
  l=$(NOCCQ=1 node_lines CCQUOTA_FLEET=1)
  contains "NOCCQ: WARN" "$l" "WARN  node"
  contains "NOCCQ: ccquota not on PATH" "$l" "ccquota is not on PATH"
  contains "NOCCQ: install" "$l" "fleet-node-join.sh"
fi

# CONF: the switch from the install's fleet.conf (export spelling) …
printf 'export CCQUOTA_FLEET=1\n' > "$WORK/fleet.conf"
l=$(node_lines)
contains "CONF install: read through `export`" "$l" "WARN  node"
contains "CONF install: the MISSING verdict" "$l" "$NE missing"
printf '# export CCQUOTA_FLEET=1\n' > "$WORK/fleet.conf"
l=$(node_lines)
[ -z "$l" ] || fail "CONF install: a commented switch is off" "$l"
ok
rm -f "$WORK/fleet.conf"
# … and from a fleet's conf
printf 'FLEET_REPO="acme/widgets"\nCCQUOTA_FLEET=1\n' > "$WORK/conf/fleets/sessA/conf"
l=$(node_lines)
contains "CONF fleet: read from fleets/<sess>/conf" "$l" "WARN  node"
printf 'FLEET_REPO="acme/widgets"\nCCQUOTA_FLEET=0\n' > "$WORK/conf/fleets/sessA/conf"
l=$(node_lines)
[ -z "$l" ] || fail "CONF fleet: CCQUOTA_FLEET=0 is off" "$l"
ok

printf 'fleet-doctor-node-selftest OK (%s checks)\n' "$CHECKS"
