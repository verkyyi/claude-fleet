#!/bin/bash
# fleet-node-leave-selftest.sh — `fleet node leave` (issue #1928) on a sandbox
# HOME with PATH shims: no hub, launchd, systemd or sudo is touched.
# Drives bin/fleet-node.sh (the `fleet node leave` dispatch) and
# bin/fleet-node-leave.sh. The bar: one call to the hub's /v1/node/leave with
# the node token on stdin (never an argv), the agent stopped and its service
# file gone, node.env deleted — and when the hub cannot be asked or refuses,
# nothing local changes.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/node-leave-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
H="$WORK/home"; CONF="$H/.config/claude-fleet"; LOG="$WORK/calls.log"
mkdir -p "$WORK/shim" "$WORK/daemons" "$WORK/units"
export FLEET_CONF_DIR="$CONF" FLEET_LEAVE_HOME="$H" FLEET_LEAVE_DAEMON_DIR="$WORK/daemons" \
  FLEET_LEAVE_UNIT_DIR="$WORK/units" FLEET_HUB_CURL="$WORK/shim/curl" FLEET_JOIN_SUDO="$WORK/shim/sudo" \
  FAKE_LOG="$LOG" PATH="$WORK/shim:$PATH"
ME=$(id -un)

# curl: logs its argv and its stdin; answers FAKE_CODE (200) with FAKE_BODY,
# or fails like an unreachable host when FAKE_CODE=down.
cat > "$WORK/shim/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$FAKE_LOG"
cat >> "$FAKE_LOG.stdin"
[ "${FAKE_CODE:-200}" = down ] && exit 7
printf '%s\n%s' "${FAKE_BODY:-{\"endpoint_id\":\"ep_42\",\"already\":false,\"removed\":true\}}" "${FAKE_CODE:-200}"
EOF
for t in launchctl systemctl; do
  printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >> "$FAKE_LOG"\nexit 0\n' "$t" > "$WORK/shim/$t"
done
printf '#!/bin/sh\nprintf "sudo %%s\\n" "$*" >> "$FAKE_LOG"\nexec "$@"\n' > "$WORK/shim/sudo"
chmod +x "$WORK/shim/"*

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -f "$WORK/out" ] && cat "$WORK/out" >&2; exit 1; }
has() { grep -aFq -- "$2" "$1" || fail "$3"; }
not_has() { ! grep -aFq -- "$2" "$1" || fail "$3"; }
fixture() {
  rm -rf "$H" "$WORK/daemons/"* "$WORK/units/"*; : > "$LOG"; : > "$LOG.stdin"
  mkdir -p "$CONF" "$H/.ccquota" "$H/Library/LaunchAgents" "$H/.config/systemd/user"
  printf 'CCQUOTA_HUB_URL=https://hub.test/\nCCQUOTA_TOKEN=tok-secret-1\nCCQUOTA_FLEET_COMPUTE=0\n' > "$CONF/node.env"
  printf 'plist\n' > "$H/Library/LaunchAgents/com.ccquota.agent.plist"
  printf 'plist\n' > "$WORK/daemons/com.ccquota.agent.$ME.plist"
  printf 'unit\n' > "$H/.config/systemd/user/ccquota-agent.service"
}
leave() { FLEET_LEAVE_OS="${OSX:-Darwin}" bash "$BIN/fleet-node.sh" leave "$@" > "$WORK/out" 2>&1; RC=$?; }

# A — a login that never joined: nothing to leave, the hub is not asked.
fixture; rm -f "$CONF/node.env"
leave
[ "$RC" = 0 ] || fail "A: no node.env exit $RC, want 0"
has "$WORK/out" '不用退出' 'A: the not-a-node line'
not_has "$LOG" 'curl' 'A: the hub was asked with no node.env'

# B — macOS: the hub retires it, the agent stops, both service shapes and
# node.env go; the token rides stdin only.
fixture
leave --reason drill
[ "$RC" = 0 ] || fail "B: exit $RC"
has "$LOG" 'https://hub.test/v1/node/leave' 'B: the hub leave route was not called'
[ "$(grep -c '^curl' "$LOG")" = 1 ] || fail 'B: the hub must be asked exactly once'
has "$LOG" '{"reason":"drill"}' 'B: the reason was not sent'
not_has "$LOG" 'tok-secret-1' 'B: the node token reached an argv'
has "$LOG.stdin" 'Authorization: Bearer tok-secret-1' 'B: the node token was not on stdin'
has "$WORK/out" 'ep_42' 'B: the retire verdict was not printed'
has "$LOG" "launchctl bootout gui/$(id -u)/com.ccquota.agent" 'B: the LaunchAgent was not booted out'
has "$LOG" "launchctl bootout system/com.ccquota.agent.$ME" 'B: the LaunchDaemon was not booted out'
[ ! -e "$H/Library/LaunchAgents/com.ccquota.agent.plist" ] || fail 'B: the LaunchAgent plist stayed'
[ ! -e "$WORK/daemons/com.ccquota.agent.$ME.plist" ] || fail 'B: the LaunchDaemon plist stayed'
[ ! -e "$CONF/node.env" ] || fail 'B: node.env stayed'
has "$WORK/out" 'agent 已停' 'B: the agent line'
python3 - "$LOG" <<'PY' || fail 'B: the hub must be asked before anything local changes'
import pathlib, sys
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
assert lines[0].startswith('curl'), lines
PY

# C — a detached agent (agent.pid) is killed and its pid file removed.
fixture; rm -f "$H/Library/LaunchAgents/com.ccquota.agent.plist" "$WORK/daemons/"*
sleep 300 & SPID=$!
echo "$SPID" > "$H/.ccquota/agent.pid"
leave
[ "$RC" = 0 ] || fail "C: exit $RC"
sleep 0.2
kill -0 "$SPID" 2>/dev/null && { kill "$SPID"; fail 'C: the detached agent still runs'; }
[ ! -e "$H/.ccquota/agent.pid" ] || fail 'C: agent.pid stayed'

# D — Linux: the systemd user unit is disabled and removed.
fixture
OSX=Linux leave
[ "$RC" = 0 ] || fail "D: exit $RC"
has "$LOG" 'systemctl --user disable --now ccquota-agent.service' 'D: the user unit was not stopped'
[ ! -e "$H/.config/systemd/user/ccquota-agent.service" ] || fail 'D: the unit file stayed'
not_has "$LOG" 'launchctl' 'D: launchctl ran on Linux'

# E — the hub no longer knows the token (401): already gone, local steps run.
fixture
FAKE_CODE=401 FAKE_BODY='{"error":"unrecognised enrollment token"}' leave
[ "$RC" = 0 ] || fail "E: 401 exit $RC, want 0"
[ ! -e "$CONF/node.env" ] || fail 'E: node.env stayed after a 401'

# F — a hub before #1928 (404), a refusal (403), an unreachable hub: nothing
# local changes — node.env and the services stay, so a rerun can finish.
for c in 404 403 down; do
  fixture
  FAKE_CODE=$c FAKE_BODY='{"error":"x"}' leave
  case "$c" in down) want=1 ;; *) want=4 ;; esac
  [ "$RC" = "$want" ] || fail "F: hub $c exit $RC, want $want"
  [ -f "$CONF/node.env" ] || fail "F: hub $c removed node.env"
  [ -f "$H/Library/LaunchAgents/com.ccquota.agent.plist" ] || fail "F: hub $c removed the agent"
  not_has "$LOG" 'launchctl' "F: hub $c stopped the agent"
done
has "$WORK/out" '重跑同一条命令' 'F: the unreachable line names the rerun'

# G — --hub-only (fleet-login-remove.sh's): the hub and node.env, never the agent.
fixture
leave --hub-only
[ "$RC" = 0 ] || fail "G: exit $RC"
[ -f "$H/Library/LaunchAgents/com.ccquota.agent.plist" ] || fail 'G: --hub-only removed the agent'
not_has "$LOG" 'launchctl' 'G: --hub-only booted out a service'
[ ! -e "$CONF/node.env" ] || fail 'G: --hub-only kept node.env'

# H — --dry-run changes nothing and asks no one.
fixture
leave --dry-run
[ "$RC" = 0 ] || fail "H: exit $RC"
not_has "$LOG" 'curl' 'H: --dry-run asked the hub'
not_has "$LOG" 'launchctl' 'H: --dry-run booted out a service'
[ -f "$CONF/node.env" ] && [ -f "$H/Library/LaunchAgents/com.ccquota.agent.plist" ] || fail 'H: --dry-run changed a file'
has "$WORK/out" 'would ask: POST https://hub.test/v1/node/leave' 'H: the dry run does not say what it would ask'

# I — usage.
leave --bogus; [ "$RC" = 2 ] || fail "I: an unknown option exit $RC, want 2"
leave --reason 'a"b'; [ "$RC" = 2 ] || fail "I: a quote in the reason exit $RC, want 2"

printf 'fleet-node-leave-selftest: PASS\n'
