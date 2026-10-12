#!/bin/bash
# fleet-break-it-seats-selftest.sh — the docs/dev/BREAK-IT.md rows of who runs the
# machine's services (issue #3556, EPIC #3500 C14 · 共同约定 11): each drill builds
# a sandbox managed machine (FLEET_NODE_TEST=1 — a fake passwd, a unit directory, a
# process table), puts the wrong thing back for real, and passes when
# `fleet-node-supervisor.py seats --check` — the doctor's `seats` row — goes red
# naming it, and green again once it is gone. Runner and timing helpers are
# bin/fleet-break-it-cred-selftest.sh's (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill names here too.
#
#   personal-account-runs-machine-service
#                         bin/fleet-node-supervisor.py seats_reading / seats_check:
#                         a fleet machine service (a LaunchDaemon with a person's
#                         UserName, the daemon / node program running as a person)
#                         or the admin agent under a person's login
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

# seats_sandbox <dir> — a managed machine: the daemon's unit, two people (alice, a
# tenant; bob, an admin), the fleet's role accounts, a clean process table
seats_sandbox() {
  local sb="$1"
  mkdir -p "$sb/db" "$sb/LaunchDaemons" "$sb/Users/alice" "$sb/Users/bob"
  cat > "$sb/LaunchDaemons/com.claude-fleet.node.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.claude-fleet.node</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>fleet-node-supervisor.py</string><string>run</string></array>
</dict></plist>
EOF
  cat > "$sb/passwd.json" <<EOF
{"alice": {"uid": 501, "gid": 20, "home": "$sb/Users/alice"},
 "bob": {"uid": 502, "gid": 20, "home": "$sb/Users/bob", "groups": ["admin"]},
 "_fleetnode": {"uid": 451, "gid": 451, "home": "/var/empty"},
 "_fleetcred": {"uid": 499, "gid": 499, "home": "/var/empty"}}
EOF
  cat > "$sb/ps.txt" <<'EOF'
root 100 /usr/bin/python3 -I /Library/Application Support/claude-fleet/current/bin/fleet-node-supervisor.py run
_fleetnode 101 /Library/Application Support/claude-fleet/current/bin/ccquota agent --machine --machine-env /var/db/fleet-node/machine.env
_fleetcred 102 /usr/bin/python3 -I /Library/Application Support/claude-fleet/credsep/fleet-credsep-launch.py shared
alice 103 /bin/sh /Users/alice/.claude/fleet/bin/tmux-spinner.sh
EOF
}

# seats <dir> — the doctor's reading; sets RC and OUT
seats() {
  local sb="$1"
  OUT=$(env FLEET_NODE_TEST=1 FLEET_NODE_LAUNCHCTL='' "FLEET_NODE_STATE=$sb/db" "FLEET_NODE_LOG=$sb/log" \
    "FLEET_NODE_DAEMON_DIR=$sb/LaunchDaemons" "FLEET_NODE_USERS=$sb/Users" "FLEET_NODE_PASSWD=$sb/passwd.json" \
    "FLEET_NODE_SEATS_PS=$sb/ps.txt" python3 "$BIN/fleet-node-supervisor.py" seats --check 2>&1)
  RC=$?
}

# personal-account-runs-machine-service (#3556): a fleet machine service — or the
# admin agent — is put back under a person's login: a LaunchDaemon whose UserName
# is that login, the machine's daemon running as it, the admin agent's unit on an
# admin login once its role account exists. The seats row FAILs naming the login
# and the service each time; gone again, it is green. Before C15 made _fleetadmin
# the admin agent alone is a WARN (3), never a silent pass.
drill_personal_account_runs_machine_service() {
  CAP=30
  local sb t0
  sb="$WORK/seats"; seats_sandbox "$sb"
  seats "$sb"
  [ "$RC" = 0 ] || { WHY="red before the break (rc $RC): $OUT"; return 1; }
  t0=$(now)
  # 1. a machine unit installed with a person's UserName
  cat > "$sb/LaunchDaemons/com.claude-fleet.memguard.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.claude-fleet.memguard</string>
<key>UserName</key><string>alice</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>fleet-memguard.sh</string><string>--daemon</string></array>
</dict></plist>
EOF
  seats "$sb"
  [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'alice: com.claude-fleet.memguard' \
    || { WHY="a machine LaunchDaemon as alice: rc $RC: $OUT"; return 1; }
  rm "$sb/LaunchDaemons/com.claude-fleet.memguard.plist"
  # 2. the machine's daemon running as a person
  printf 'alice 4242 /usr/bin/python3 -I /Users/alice/.claude/fleet/bin/fleet-node-supervisor.py run\n' >> "$sb/ps.txt"
  seats "$sb"
  [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'alice: 节点守护 fleet-node-supervisor（pid 4242）' \
    || { WHY="the daemon running as alice: rc $RC: $OUT"; return 1; }
  sed -i.bak '/^alice 4242 /d' "$sb/ps.txt"
  seats "$sb"
  [ "$RC" = 0 ] || { WHY="gone again, still red (rc $RC): $OUT"; return 1; }
  # 3. the admin agent under the admin's own login: WARN before _fleetadmin, FAIL after
  cat > "$sb/LaunchDaemons/com.ccquota.agent.bob.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.ccquota.agent.bob</string>
<key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>-I</string><string>/Library/Application Support/claude-fleet/credsep/fleet-credsep-launch.py</string><string>agent</string><string>bob</string></array>
</dict></plist>
EOF
  seats "$sb"
  [ "$RC" = 3 ] && printf '%s' "$OUT" | grep -q 'bob: 管理员 agent' \
    || { WHY="the admin agent before _fleetadmin: rc $RC (want the WARN, 3): $OUT"; return 1; }
  python3 - "$sb/passwd.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); p["_fleetadmin"] = {"uid": 452, "gid": 452, "home": "/var/empty"}
json.dump(p, open(sys.argv[1], "w"))
PY
  seats "$sb"
  [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q 'bob: 管理员 agent（.*com.ccquota.agent.bob.plist' \
    || { WHY="the admin agent under bob once _fleetadmin exists: rc $RC: $OUT"; return 1; }
  rm "$sb/LaunchDaemons/com.ccquota.agent.bob.plist"
  seats "$sb"
  SECS=$(since "$t0")
  [ "$RC" = 0 ] || { WHY="every way closed, still red (rc $RC): $OUT"; return 1; }
  WHAT="个人账号名下装回整机服务（UserName 是他的 LaunchDaemon、以他跑的节点守护）或管理员 agent：seats 行红、指名是谁哪个；拿掉就绿（_fleetadmin 建好前管理员 agent 只 WARN）"
}

cred_run_drills "$0"
