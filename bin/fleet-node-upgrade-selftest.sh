#!/bin/bash
# fleet-node-upgrade-selftest.sh — bin/fleet-node-upgrade.sh (issue #1525) and
# the doctor's `agent` line it feeds (bin/fleet-doctor.sh).
#
#   A  DRY      --dry-run lists all 5 logins (4 LaunchDaemons + this login's
#               LaunchAgent; a .plist.bak decoy is not one) with the target, and
#               changes NOTHING: every file's bytes identical, no sudo, no launchctl
#   B  STATUS   --status: one row per login, disk + hub version, `summary: 5/5 behind`
#   C  UPGRADE  installs over the shared path (old kept as .prev, sha256 checked),
#               kickstarts login by login (system/… through sudo, gui/<uid>/… not),
#               each confirmed on the hub before the next; then status 0/5 and a
#               rerun is "nothing to do"
#   D  STUCK    a login whose control channel never comes back on the target →
#               exit 1 naming it; the logins after it are NOT restarted
#   E  REFUSE   a binary that says another version, or a --sha256 mismatch →
#               exit 1, nothing installed, nothing restarted
#   F  LOGINS   --logins a3 restarts only a3; an unknown login → exit 2
#   G  NONE     no agent service → exit 1 before any target read (no network);
#               non-macOS → exit 1
#   H  DOCTOR   `agent` WARN naming the behind logins → PASS once upgraded; no
#               agent service → no `agent` line at all (the degenerate case)
#
# Hermetic: fake launchd dirs, ps, sudo, launchctl and hub; scratch HOME/TMPDIR.
# No network, no tmux, no real service. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/fleet-node-upgrade.sh"
[ -f "$SUT" ] || { echo "selftest: $SUT not found" >&2; exit 2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/node-upgrade-selftest.XXXXXX")" || exit 2
W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
ok() { CHECKS=$((CHECKS+1)); }
contains() { case "$2" in *"$3"*) ok ;; *) fail "$1 — lacks [$3]" "$2" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 — carries [$3]" "$2" ;; *) ok ;; esac; }

FULL=bc4e8e1753e9470c1c896f4cd00b9af2c0e7d5cd
ME=$(id -un) MYUID=$(id -u)

setup() {
  rm -rf "$W/s"; mkdir -p "$W/s/bin" "$W/s/daemons" "$W/s/agents" "$W/s/usr" "$W/s/new" "$W/s/fake" "$W/s/up" "$W/s/home"
  S="$W/s"
  # A copy without a tokenledger/ beside it: the SUT never reaches for git here.
  cp "$SUT" "$S/bin/"
  for n in a1 a2 a3 a4; do printf '<plist/>\n' > "$S/daemons/com.ccquota.agent.$n.plist"; done
  printf '<plist/>\n' > "$S/daemons/com.ccquota.agent.a1.plist.bak-1453"
  printf '<plist/>\n' > "$S/agents/com.ccquota.agent.plist"
  printf '#!/bin/sh\n[ "$1" = version ] && echo "ccquota prod-9b7e562"\n' > "$S/usr/ccquota"
  printf '#!/bin/sh\n[ "$1" = version ] && echo "ccquota prod-bc4e8e1"\n' > "$S/new/ccquota"
  printf '#!/bin/sh\n[ "$1" = version ] && echo "ccquota prod-1234567"\n' > "$S/new/wrong"
  chmod 755 "$S/usr/ccquota" "$S/new/ccquota" "$S/new/wrong"
  : > "$S/ps"
  pid=100
  for u in 1001 1002 1003 1004 "$MYUID"; do pid=$((pid+1)); echo "$u $pid $S/usr/ccquota" >> "$S/ps"; done
  cat > "$S/fake/sudo" <<EOF
#!/bin/sh
echo "\$*" >> "$S/sudo.log"
exec "\$@"
EOF
  # kickstart -k <domain/label>: the agent restarts → the hub sees the new
  # version (unless it is STUCK).
  cat > "$S/fake/launchctl" <<EOF
#!/bin/sh
echo "\$*" >> "$S/launchctl.log"
[ "\$1" = kickstart ] && touch "$S/up/\$(basename "\$3")"
exit 0
EOF
  cat > "$S/fake/nodes" <<EOF
#!/bin/sh
printf '{"nodes":['
sep=''
for pair in a1:com.ccquota.agent.a1 a2:com.ccquota.agent.a2 a3:com.ccquota.agent.a3 a4:com.ccquota.agent.a4 $ME:com.ccquota.agent; do
  u=\${pair%%:*} l=\${pair#*:} v=prod-02e8161b
  [ -f "$S/up/\$l" ] && [ "\${STUCK:-}" != "\$u" ] && v=prod-bc4e8e1
  printf '%s{"hostname":"testhost.local","os_user":"%s","agent_version":"%s","connected":true,"age_sec":3}' "\$sep" "\$u" "\$v"
  sep=,
done
printf ',{"hostname":"other","os_user":"a1","agent_version":"prod-0000000","connected":true}]}'
EOF
  chmod 755 "$S/fake/"*
}

run() { # [VAR=val …] -- args…
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env HOME="$S/home" TMPDIR="$W" \
    FLEET_NODE_UPGRADE_OS=Darwin FLEET_NODE_UPGRADE_HOSTNAME=testhost \
    FLEET_NODE_UPGRADE_DAEMON_DIR="$S/daemons" FLEET_NODE_UPGRADE_AGENT_DIR="$S/agents" \
    FLEET_NODE_UPGRADE_PS="cat $S/ps" FLEET_NODE_UPGRADE_UIDS="a1=1001 a2=1002 a3=1003 a4=1004" \
    FLEET_NODE_UPGRADE_SUDO="$S/fake/sudo" FLEET_NODE_UPGRADE_LAUNCHCTL="$S/fake/launchctl" \
    FLEET_NODE_UPGRADE_NODES_CMD="$S/fake/nodes" FLEET_NODE_UPGRADE_POLL=1 \
    ${envs[@]+"${envs[@]}"} bash "$S/bin/fleet-node-upgrade.sh" "$@" 2>&1
}
tree_sum() { (cd "$S" && find . -path ./home -prune -o -type f -print | LC_ALL=C sort | while read -r f; do printf '%s ' "$f"; cksum < "$f"; done); }

# ── A dry-run ───────────────────────────────────────────────────────────────
setup
before=$(tree_sum)
out=$(run -- "$FULL" --dry-run); rc=$?
[ "$rc" = 0 ] || fail "A: dry-run exit $rc" "$out"
contains "A: target" "$out" "target: prod-bc4e8e1"
contains "A: would build" "$out" "would build tokenledger at bc4e8e1"
for n in a1 a2 a3 a4; do contains "A: $n listed" "$out" "  $n  system/com.ccquota.agent.$n  $S/usr/ccquota  disk prod-9b7e562 · hub prod-02e8161b  → upgrade"; done
contains "A: own LaunchAgent" "$out" "  $ME  gui/com.ccquota.agent  $S/usr/ccquota"
contains "A: count" "$out" "dry-run: 5 login(s) would be upgraded"
lacks "A: decoy" "$out" "bak-1453"
after=$(tree_sum); [ "$after" = "$before" ] || fail "A: dry-run changed a file" "$(diff <(echo "$before") <(echo "$after"))"; ok
[ ! -e "$S/sudo.log" ] && [ ! -e "$S/launchctl.log" ] || fail "A: dry-run ran sudo/launchctl" "$out"; ok

# ── B status ────────────────────────────────────────────────────────────────
out=$(run -- "$FULL" --status); rc=$?
[ "$rc" = 0 ] || fail "B: status exit $rc" "$out"
contains "B: header" "$out" "LOGIN      PATH"
contains "B: a1 row" "$out" "prod-9b7e562   prod-02e8161b  connected 3s  behind"
lacks "B: other host filtered" "$out" "prod-0000000"
contains "B: summary" "$out" "summary: 5/5 behind prod-bc4e8e1"
out=$(run -- "$FULL" --status --no-hub)
contains "B: --no-hub note" "$out" "hub: --no-hub"
contains "B: --no-hub summary" "$out" "summary: 5/5 behind"

# ── C upgrade ───────────────────────────────────────────────────────────────
out=$(run -- "$FULL" --binary "$S/new/ccquota" --wait 5); rc=$?
[ "$rc" = 0 ] || fail "C: upgrade exit $rc" "$out"
cmp -s "$S/usr/ccquota" "$S/new/ccquota" || fail "C: binary not installed" "$out"; ok
grep -q prod-9b7e562 "$S/usr/ccquota.prev" || fail "C: no .prev with the old bytes" "$out"; ok
[ ! -e "$S/usr/ccquota.new" ] || fail "C: .new left behind" "$out"; ok
contains "C: install line" "$out" "install: $S/usr/ccquota ← prod-bc4e8e1"
want="kickstart -k system/com.ccquota.agent.a1
kickstart -k system/com.ccquota.agent.a2
kickstart -k system/com.ccquota.agent.a3
kickstart -k system/com.ccquota.agent.a4
kickstart -k gui/$MYUID/com.ccquota.agent"
[ "$(cat "$S/launchctl.log")" = "$want" ] || fail "C: kickstart order/labels" "$(cat "$S/launchctl.log")"; ok
[ "$(grep -c kickstart "$S/sudo.log")" = 4 ] || fail "C: sudo only for the 4 system daemons" "$(cat "$S/sudo.log")"; ok
lacks "C: no sudo for a writable path" "$(cat "$S/sudo.log")" "install"
contains "C: confirmed on hub" "$out" "restart: a1 — hub: connected on prod-bc4e8e1"
contains "C: done" "$out" "done: 5/5 login(s) on prod-bc4e8e1"
out=$(run -- "$FULL" --status)
contains "C: status after" "$out" "summary: 0/5 behind prod-bc4e8e1"
out=$(run -- "$FULL" --dry-run)
contains "C: rerun nothing to do" "$out" "all 5 on prod-bc4e8e1 — nothing to do"

# ── D stuck ─────────────────────────────────────────────────────────────────
setup
out=$(run STUCK=a2 -- "$FULL" --binary "$S/new/ccquota" --wait 2); rc=$?
[ "$rc" = 1 ] || fail "D: stuck exit $rc (want 1)" "$out"
contains "D: names a2" "$out" "a2: restarted, but no control channel on prod-bc4e8e1"
contains "D: progress" "$out" "(1 done; the rest untouched)"
lacks "D: a3 untouched" "$(cat "$S/launchctl.log")" "agent.a3"

# ── E refuse ────────────────────────────────────────────────────────────────
setup
out=$(run -- "$FULL" --binary "$S/new/wrong"); rc=$?
[ "$rc" = 1 ] || fail "E: wrong version exit $rc" "$out"
contains "E: says why" "$out" "says 'prod-1234567', not prod-bc4e8e1"
out=$(run -- "$FULL" --binary "$S/new/ccquota" --sha256 deadbeef); rc=$?
[ "$rc" = 1 ] || fail "E: sha mismatch exit $rc" "$out"
contains "E: sha" "$out" "≠ --sha256 deadbeef"
grep -q prod-9b7e562 "$S/usr/ccquota" && [ ! -e "$S/usr/ccquota.prev" ] || fail "E: something was installed" "$out"; ok
[ ! -e "$S/launchctl.log" ] || fail "E: something was restarted" "$out"; ok

# ── F --logins ──────────────────────────────────────────────────────────────
setup
out=$(run -- "$FULL" --binary "$S/new/ccquota" --logins a3 --wait 5); rc=$?
[ "$rc" = 0 ] || fail "F: --logins a3 exit $rc" "$out"
[ "$(cat "$S/launchctl.log")" = "kickstart -k system/com.ccquota.agent.a3" ] || fail "F: only a3" "$(cat "$S/launchctl.log")"; ok
out=$(run -- "$FULL" --dry-run --logins nobody); rc=$?
[ "$rc" = 2 ] || fail "F: unknown login exit $rc (want 2)" "$out"
contains "F: unknown" "$out" "no agent for login 'nobody'"

# ── G none / non-macOS ──────────────────────────────────────────────────────
setup
rm -f "$S/daemons/"* "$S/agents/"*
out=$(run -- stable --status); rc=$?   # stable unreadable here (no fleet-stable.sh): must not get that far
[ "$rc" = 1 ] || fail "G: no agent exit $rc (want 1)" "$out"
contains "G: says so" "$out" "no ccquota agent service on testhost"
out=$(run FLEET_NODE_UPGRADE_OS=Linux -- "$FULL" --status); rc=$?
[ "$rc" = 1 ] || fail "G: Linux exit $rc" "$out"
contains "G: macOS only" "$out" "macOS (launchd) only"

# ── H doctor `agent` line ───────────────────────────────────────────────────
DFILES="fleet-doctor.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-quotawatch.sh fleet-hub-node.sh fleet-daemon-lib.sh fleet-node-upgrade.sh"
setup
mkdir -p "$S/dbin" "$S/conf"
for f in $DFILES; do [ -f "$BIN/$f" ] || fail "H: $f missing"; cp "$BIN/$f" "$S/dbin/"; done
agent_line() {
  env HOME="$S/home" TMPDIR="$W" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$S/conf" \
    FLEET_DOCTOR_AGENT_TARGET="$FULL" \
    FLEET_NODE_UPGRADE_OS=Darwin FLEET_NODE_UPGRADE_HOSTNAME=testhost \
    FLEET_NODE_UPGRADE_DAEMON_DIR="$S/daemons" FLEET_NODE_UPGRADE_AGENT_DIR="$S/agents" \
    FLEET_NODE_UPGRADE_PS="cat $S/ps" FLEET_NODE_UPGRADE_UIDS="a1=1001 a2=1002 a3=1003 a4=1004" \
    FLEET_NODE_UPGRADE_NODES_CMD="$S/fake/nodes" \
    bash "$S/dbin/fleet-doctor.sh" 2>/dev/null | grep -E '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+agent([[:space:]]|$)'
}
out=$(agent_line)
contains "H: WARN" "$out" "WARN  agent    5/5 login(s) behind stable prod-bc4e8e1: a1, a2, a3, a4, $ME"
contains "H: the fix" "$out" "fleet-node-upgrade.sh"
cp "$S/new/ccquota" "$S/usr/ccquota"; touch "$S/up/com.ccquota.agent.a1" "$S/up/com.ccquota.agent.a2" "$S/up/com.ccquota.agent.a3" "$S/up/com.ccquota.agent.a4" "$S/up/com.ccquota.agent"
out=$(agent_line)
contains "H: PASS" "$out" "PASS  agent    5 login(s) on this machine run prod-bc4e8e1"
# Upgraded on disk, one never restarted → still behind (the hub's view counts).
rm -f "$S/up/com.ccquota.agent.a4"
out=$(agent_line)
contains "H: not restarted is behind" "$out" "1/5 login(s) behind stable prod-bc4e8e1: a4"
rm -f "$S/daemons/"* "$S/agents/"*
out=$(agent_line)
[ -z "$out" ] || fail "H: no agent service must print no agent line" "$out"; ok

echo "fleet-node-upgrade-selftest: PASS ($CHECKS checks)"
