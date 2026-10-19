#!/bin/bash
# fleet-break-it-node-selftest.sh — docs/dev/BREAK-IT.md row `node-supervisor-dead`
# (issue #2331, EPIC #2329 C3): the machine's one daemon dies. Its own file, like
# the cred-shared drill whose runner it sources (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill_* names here too.
#
#   node-core-bootstrap-lost bin/fleet-node-core.py install (serving_wait, the put-back) +
#                         bin/fleet-node-supervisor.py install / install_check / status --check
#                         (core_reading) + bin/fleet-node-install.sh 核心 + bin/fleet-doctor.sh
#                         `node` row (#3810): the core re-bootstrapped under a seated daemon
#                         answers EIO — no core, every child stopped, the install said done
#   node-core-swept       bin/fleet-node-supervisor.py _sweep / _retire_unit (CORE_LABEL) +
#                         tend_core (#3857): the hourly sweep, run by the core itself under a
#                         seated daemon, booted the core out — it vanished hours after a start
#   node-core-old-code    bin/fleet-node-core.py maybe_restart / code_files (#3959): a switch
#                         that changed only a sibling the core loaded (the supervisor's sweep)
#                         left the core on the old code — the old sweep booted the core out
#   core-restart-leaks-loops bin/fleet-node-core.py stray_copies / op_run_as / op_stop_as +
#                         fleet-node-supervisor.py sweep_strays · the `worker` class (#4231):
#                         a core restart left its resident jobs running beside the next copy
#   node-supervisor-dead  bin/fleet-node-supervisor.py (install's KeepAlive +
#                         ThrottleInterval, run's adopt + state.json, status --check),
#                         bin/fleet-doctor.sh's `node` row
#   node-supervisor-wedged bin/fleet-node-supervisor.py's watchdog (#3079, #3086): the
#                         loop stops coming round (a blocking open()) — it names the
#                         phase, dumps its stack, records it and exits; launchd brings it back
#   node-supervisor-stop-hang bin/fleet-node-supervisor.py run's stop + reap_tasks (#4144):
#                         a task deaf to the stop's TERM held the daemon in its stop for
#                         good, the watchdog already off — bounded and watched now
#   node-demote-in-forked-child bin/fleet-node-supervisor.py demote_kw + its callers in
#                         fleet-node-core.py / fleet-node-update.py / fleet-node-linux.py /
#                         fleet-ci-runner.py (#4144): initgroups() in a child forked from a
#                         threaded parent waited on libinfo's lock for good
#   node-fda-probe-hang   bin/fleet-node-supervisor.py's FDA probe (#3086): the open() of
#                         TCC.db never returns (tccd not answering) — a child, killed; the
#                         loop never waits on it
#   tcc-prompt-wedge      bin/fleet-tcc-disclaim.py + tokenledger/agent/node_accounts.go
#                         (tccDisclaimed) + bin/fleet-node-supervisor.py tcc_stuck_line (#3167):
#                         an account script's TCC dialog nobody answers wedges sandboxd —
#                         every user delete fails; the scripts never prompt now, and a
#                         stuck TCC is the doctor's FAIL with the way out
#   tcc-disclaim-sigpipe  bin/fleet-tcc-disclaim.py + bin/fleet-login-new.sh gen_password (#3419):
#                         the wrapper handed Python's ignored SIGPIPE to the script — a
#                         `… | head` never ended and the account create hung
#   per-login-machine-loops bin/fleet-machine-tasks.py + conf/node-tasks.tsv (#3546): every
#                         login probed the machine for itself; one table, one reading now;
#                         + bin/fleet-node-supervisor.py (#3671): session units only with a
#                         session, a restart adopts instead of doubling
#   webhook-per-login     bin/fleet-webhook-machine.py (#4358): one webhook forwarder for
#                         every login, routed by login as that login, idle by change
#   selftest-leftover-overnight bin/fleet_selftest_procs.py + fleet-selftest-reap.sh (#4360):
#                         a killed selftest's processes are reaped once their maker is gone
#   service-killed        bin/fleet-node-supervisor.py's login-level register (#2525):
#                         a registered service is kill -9'd / dies at start
#   service-login-moved   bin/fleet-node-supervisor.py `service move` + `account release`,
#                         bin/fleet-login-remove.sh (#2528): a login is moved to another
#                         one / retired while a registered task of it still runs
#   task-fail-silent      bin/fleet-node-supervisor.py's agent tasks + bin/fleet-task-run.sh
#                         (#2529): a scheduled agent task's session will not open, every try
#   service-failed-unseen bin/fleet-services.py (#2526): a registered service that
#                         keeps dying reads red in the doctor + the alert bar
#   services-elsewhere-rollback bin/fleet-services.py --doctor (#3978): the same person's
#                         failed service on another machine read FAIL in this login's
#                         doctor — a «new FAIL after the switch», so the install rolled back
#   service-handwritten   bin/fleet-node-supervisor.py's sweep + bin/fleet-services.py --doctor
#                         (#2530): a hand-written launchd plist runs as a login beside the
#                         register — the doctor WARNs until it is registered and archived
#   sweep-admin-agent     bin/fleet-node-supervisor.py's sweep `_extra_verdict` (#2997): a
#                         managed machine's sweep booted the admin login's own node agent
#                         (com.ccquota.agent.<admin>) into the attic — no admin node, no
#                         newcomer's login opened anywhere
#   task-rerun-root-only  bin/fleet-session-cli.py `fleet task run --now` → the hub's
#                         service_control → the node's fixed supervisor argv (#2527):
#                         a missed daily push is run again from the client, no root
#   account-adopt-stuck   bin/fleet-node-supervisor.py `account adopt|release` (#2332):
#                         one of a login's services will not unload mid-migration
#   tenant-admin-adopted  bin/fleet-node-supervisor.py `account adopt` + `tenants --check`
#                         + bin/fleet-doctor.sh's `tenants` row (#2842): an admin login
#                         taken over, or a taken-over login put in the admin group
#   account-adopt-agent-left  bin/fleet-node-supervisor.py `account adopt|release` (#2387):
#                         the login's own node agent (com.ccquota.agent.<login>) moves
#                         with it — logins/<login>.env written, the old one in the attic
#   login-remove-managed  bin/fleet-login-remove.sh step 1c + bin/fleet-node-supervisor.py
#                         `account forget` (#2924): a login the daemon took over is deleted —
#                         its demoted tasks came back after every kill, its entry stayed
#   linux-remove-task-running  bin/fleet-node-supervisor.py `account forget` _account_stop
#                         (#3379): a removed login's task hung in a git fetch outlived the
#                         20 s wait and failed the whole removal
#   account-release-gone-login  bin/fleet-node-supervisor.py `account release` (#2924):
#                         release of a login no longer on the machine loaded its services back
#   account-op-reload-cut bin/fleet-node-supervisor.py's node-agent `hold` (#2918) +
#                         tokenledger/agent/node_accounts.go's book
#                         (account-ops.json): logins/*.env changes while the machine's
#                         agent runs the very create that wrote it
#   node-agent-adopted-no-reload  bin/fleet-node-supervisor.py tend_children (#3136):
#                         the daemon restarted and adopted the live node agent; a new
#                         logins/<login>.env never reloaded it (the new login's node
#                         never came online)
#   account-op-rerun-exists  tokenledger/agent/node_accounts.go's settleOwnCreate
#                         + bin/fleet-login-new.sh's op mark (#2928): the same create
#                         reaches the agent twice (a re-ask, a restart that lost the
#                         book) after its first run made the login (go test, when a
#                         toolchain is here)
#   node-update-half      bin/fleet-node-update.py (#2334): an update killed half way,
#                         and a release whose new part fails the doctor
#   update-goes-back      bin/fleet-node-update.py backward (#4671): the target the hub
#                         names is older (a lower seq) than what the machine runs
#   user-pod-no-roll-road bin/fleet-node-update.py image_row (#4791): a person's pod
#                         runs the image's runtime and no update task, and nothing
#                         rolls it (no provisioner in its cluster) — the doctor says
#                         how far behind stable it is and how to roll it
#   node-update-stale-fail  bin/fleet-node-update.py key_row + skip_retry (#2906): one
#                         torn read an older updater never cleared rolled every new
#                         release back as a «new FAIL» and skipped each sha for good
#   node-install-half     bin/fleet-node-install.sh (#2330): `fleet node install`
#                         killed half way through, then a part deleted afterwards
#   linux-join-no-login   bin/fleet-node-install.sh (the last line) + bin/fleet-node-supervisor.py
#                         default_table / requirement_met (#4010): a Linux machine joined with
#                         the one public line said 「已收敛」 while its node program waited for a
#                         logins/*.env only the hub's first create (down that program) writes
#   linux-relay-not-handed  tokenledger/hub/api/fleet_node_desired.go (cred_relay_url) +
#                         bin/fleet-node-install.sh 期望状态 / 中转 + bin/fleet-node-linux.py
#                         route_settings / hub_relay (#4010): the hub's relay reached no login
#   installer-umask-077   bin/fleet-node-install.sh (umask 022) + bin/fleet-credsep.py mkdirs /
#                         lib_open + bin/fleet-node-linux.py mkdirs (#4010): under umask 077 the
#                         runtime and /usr/local/lib/claude-fleet came out 0700
#   credsep-stale-after-switch  bin/fleet-node-update.py + fleet-credsep.py `machine
#                         refresh` + the supervisor's cred-proxy-shared `reload` (#2435):
#                         a switch / rollback left the shared credential proxy on old code
#   codesign-identity-switch  bin/fleet_node_codesign.py + bin/fleet-node-update.py
#                         sign_ccquota / sync_agent_ccquota + tokenledger/agent/
#                         node_accounts.go tccGranted (#3433): a version switch changed the
#                         admin agent's signing identity and path, so its TCC grant lapsed
#   admin-agent-stale     bin/fleet-node-update.py follow_admin_agents (#3034): an admin
#                         login's own ccquota agent ran ~/.local/bin/ccquota, no release
#                         moved it, so it never learned login_join and opened no login
#   admin-agent-gui-converted bin/fleet-node-update.py agent_unit (#3508): an admin whose
#                         agent was a LaunchAgent — credsep runs it as LaunchDaemon
#                         com.ccquota.agent.<login> but keeps launchd-gui in meta.json — was
#                         never followed, so a Mac's stayed on its old ccquota and opened no login
#   runtime-gc-admin-tree bin/fleet-node-update.py keep_set / follow_installs / login_tree_rows
#                         (#3248): the runtime pruned a release an admin's (not taken over)
#                         ~/.claude/fleet still stood on — every script its agent ran gone
#   codex-helper-missing  bin/fleet-node-update.py helpers (#3017): codex without its
#                         codex-code-mode-host beside it runs no shell command
#   shift-enter-sends     conf/tmux-attention.conf, conf/tmux-view.conf
#                         (extended keys, #2760): ⇧↵ through the client's three tmux servers
#   release-fetch-slow    tokenledger/shared/release fetch.go (Fetcher: Cache, Platforms,
#                         Stall; go test, when a toolchain is here) + bin/fleet-node-update.py
#                         stage (#2701): a 700 MB release at ~1 MB/s against a whole-fetch
#                         deadline never landed, each try from zero
#   managed-login-install-stale  bin/fleet-install-sync.sh's managed branch +
#                         bin/fleet-node-update.py's `install` doctor row (#2688): a
#                         managed login's own ~/.claude/fleet sat on its bootstrap copy
#   managed-login-install-predates  bin/fleet-node-update.py follow_installs (#2714):
#                         a login install from before #2688 never follows — its own
#                         install-sync still answers off · managed
#   managed-login-own-copy  bin/fleet-node-update.py point + follow_installs
#                         (#2774, #4669): a managed login pointed back at an own old copy
#   managed-login-mod-escapes  bin/fleet-lib.sh fleet_mod_dir (#2964, #4669): the mod's
#                         files resolved outside --plugin-dir, Claude Code refused it
#                         (Path escapes plugin directory)
#   managed-cert-lapses-idle bin/fleet-login.py keep + bin/fleet-diskguard.sh managed_cert_watch +
#                         bin/fleet_managed.py (#4594, bin/fleet-managed-cert-selftest.sh):
#                         a managed login's certificate and 7-day device window ran out unused
#   svc-run-leaks-across-runs bin/fleet-svc-local.sh + bin/fleet-svc-runner.py (#4086,
#                         bin/fleet-svc-local-selftest.sh): a service run on a Mac
#                         service login reads, or leaves for, the next workspace's run
#   spotlight-on          bin/fleet-spotlight.sh + the machine daemon's `spotlight` task +
#                         bin/fleet-doctor.sh's `spotlight` row (#3402): Spotlight indexes
#                         every worktree and a knowledge agent burns a core on a managed Mac
#   wallpaper-aerial      bin/fleet-wallpaper.sh + the machine daemon's `wallpaper` task +
#                         bin/fleet-doctor.sh's `wallpaper` row (#4362): a headless managed
#                         Mac decodes an Aerial desktop nobody sees
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_node_supervisor_dead() {
  CAP=15   # kill -9 → launchd's ThrottleInterval + a python start + the first pass
  local sb thr sup pid1 cpid t0
  sb="$WORK/node"; mkdir -p "$sb/LaunchDaemons" "$sb/rt/bin"
  cp "$BIN/fleet-node-supervisor.py" "$sb/rt/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$sb/ok.sh"
  printf '{"children":[{"name":"c","cmd":["/bin/sleep","300"]}],"tasks":[{"name":"t","every":0.5,"cmd":["/bin/bash","%s"]}]}\n' "$sb/ok.sh" > "$sb/table.json"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_HEARTBEAT_STALE=5
  python3 "$sb/rt/bin/fleet-node-supervisor.py" install >"$sb/install.out" 2>&1 \
    || { WHY="install failed: $(tail -2 "$sb/install.out" | tr '\n' ' ')"; return 1; }
  thr=$(python3 -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); assert d["KeepAlive"] is True; print(d["ThrottleInterval"])' \
        "$sb/LaunchDaemons/com.claude-fleet.node.plist") || { WHY="the service is not KeepAlive"; return 1; }
  st() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$sb/db/state.json" "$1" 2>/dev/null; }
  # launchd's part, played here: start it, and again $thr s after it dies
  ( while :; do python3 -I "$sb/rt/bin/fleet-node-supervisor.py" run 2>>"$sb/sup.err"; sleep "$thr"; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 15 sh -c '[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"tasks\"][\"t\"].get(\"runs\",0))" "$1" 2>/dev/null)" -ge 2 ]' _ "$sb/db/state.json" \
    || { WHY="the supervisor never ran its task: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; return 1; }
  pid1=$(st 's["supervisor"]["pid"]'); cpid=$(st 's["children"]["c"]["pid"]')
  python3 "$sb/rt/bin/fleet-node-supervisor.py" status --check >/dev/null || { WHY="status --check not ok while up"; return 1; }
  kill -9 "$pid1"; t0=$(now)
  python3 "$sb/rt/bin/fleet-node-supervisor.py" status --check >"$sb/down.out"
  [ $? = 1 ] && grep -q DOWN "$sb/down.out" || { WHY="status --check did not say DOWN in the gap: $(cat "$sb/down.out")"; return 1; }
  until_ok 30 sh -c '[ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"supervisor\"][\"starts\"])" "$1" 2>/dev/null)" = 2 ]' _ "$sb/db/state.json" \
    || { WHY="the supervisor was not brought back"; return 1; }
  until_ok 10 python3 "$sb/rt/bin/fleet-node-supervisor.py" status --check >/dev/null || { WHY="status --check not ok after the restart"; return 1; }
  SECS=$(since "$t0")
  [ "$(st 's["children"]["c"]["pid"]')" = "$cpid" ] || { WHY="the child was not adopted (was $cpid, now $(st 's["children"]["c"]["pid"]'))"; return 1; }
  [ "$(st 's["tasks"]["t"]["runs"]')" -ge 2 ] || { WHY="task history lost"; return 1; }
  grep -q '"$_nsup" status --check' "$BIN/fleet-doctor.sh" || { WHY="fleet-doctor.sh has no node row"; return 1; }
  kill "$sup" 2>/dev/null; kill "$(st 's["supervisor"]["pid"]')" 2>/dev/null; kill "$cpid" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_HEARTBEAT_STALE
  WHAT="整机守护 kill -9：空档里 status --check 报 DOWN（体检 node 行报警），KeepAlive 按 ${thr}s 拉起，任务记录还在、子进程被认领不重起"
}

drill_node_supervisor_wedged() {
  CAP=20   # the watchdog's 2 s + launchd's ThrottleInterval + a python start + the first passes
  local sb thr sup t0 st
  sb="$WORK/wedge"; mkdir -p "$sb/LaunchDaemons" "$sb/rt/bin"
  cp "$BIN/fleet-node-supervisor.py" "$sb/rt/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$sb/ok.sh"
  printf '{"children":[],"tasks":[{"name":"t","every":0.5,"cmd":["/bin/bash","%s"]},{"name":"u","every":0.5,"cmd":["/bin/bash","%s"]}]}\n' \
    "$sb/ok.sh" "$sb/ok.sh" > "$sb/table.json"
  # the fda phase blocks in an open() of a FIFO nobody writes — mac-d's 2026-10-11
  # hang (its open() of TCC.db never returned: the loop stopped for good, and every
  # restart stopped again, the probe due at once)
  mkfifo "$sb/hang"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_WATCHDOG_SECS=2 \
    FLEET_NODE_TEST_HANG="fda:$sb/hang"
  python3 "$sb/rt/bin/fleet-node-supervisor.py" install >"$sb/install.out" 2>&1 \
    || { WHY="install failed: $(tail -2 "$sb/install.out" | tr '\n' ' ')"; return 1; }
  thr=$(python3 -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); assert d["KeepAlive"] is True; print(d["ThrottleInterval"])' \
        "$sb/LaunchDaemons/com.claude-fleet.node.plist") || { WHY="the service is not KeepAlive"; return 1; }
  # launchd's part, played here: start it, and again $thr s after it exits
  t0=$(now)
  ( while :; do python3 -I "$sb/rt/bin/fleet-node-supervisor.py" run 2>>"$sb/sup.err"; sleep "$thr"; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 10 grep -q 'stuck .* in «fda»' "$sb/sup.err" \
    || { WHY="the wedged loop was never ended (no watchdog line): $(tail -3 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup"; return 1; }
  grep -q 'in at' "$sb/sup.err" || { WHY="no stack of where it stuck"; kill "$sup"; return 1; }
  st=$(python3 "$sb/rt/bin/fleet-node-supervisor.py" status) || true
  case "$st" in *"watchdog    restarted it"*"«fda»"*) ;; *) WHY="status does not say the watchdog restarted it: $st"; kill "$sup"; return 1 ;; esac
  rm -f "$sb/hang"   # what wedged it is gone; the restarted loop runs on
  # both tasks run on in the restarted loop (the first pass spawned them before the wedge;
  # a finished run is counted only by a loop that came round)
  until_ok 20 sh -c 'python3 -c "import json,sys; t=json.load(open(sys.argv[1]))[\"tasks\"]; sys.exit(0 if t[\"t\"].get(\"runs\",0) >= 2 and t[\"u\"].get(\"runs\",0) >= 2 else 1)" "$1" 2>/dev/null' _ "$sb/db/state.json" \
    || { WHY="the supervisor was not brought back to run its tasks: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup"; return 1; }
  SECS=$(since "$t0")
  kill "$sup" 2>/dev/null
  pkill -f "$sb/rt/bin/fleet-node-supervisor.py" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_WATCHDOG_SECS FLEET_NODE_TEST_HANG
  WHAT="整机守护的主循环卡在一个不返回的 open() 上：看门狗 2s 后写一行「卡在 «fda»」+ 各线程的栈、记进 state.json 并退出，KeepAlive 按 ${thr}s 拉起，status 写明看门狗重启过，两项任务接着跑"
}

# node-supervisor-stop-hang (#4144): on 2026-10-14 a managed Mac's daemon was asked to
# restart onto a new release and its stop waited 111 minutes on the updater task,
# which never returned — the watchdog was already off, the children already
# stopped, the heartbeat still. The stop is bounded and watched now: a task still
# running FLEET_NODE_STOP_SECS after its TERM is left to run (its pid kept), the
# daemon exits, and the next one books it as an orphan — never a second copy.
drill_node_supervisor_stop_hang() {
  CAP=25   # the stop's 2 s + a python start + the passes that book the orphan
  local sb sup sup2 t0 n
  sb="$WORK/stophang"; mkdir -p "$sb/LaunchDaemons" "$sb/rt/bin"
  cp "$BIN/fleet-node-supervisor.py" "$sb/rt/bin/"
  # a task deaf to the stop's TERM (its sleep inherits the ignore across exec)
  printf '#!/bin/bash\ntrap "" TERM\nsleep 300\n' > "$sb/deaf.sh"
  printf '{"children":[],"tasks":[{"name":"deaf","every":0.5,"timeout":600,"cmd":["/bin/bash","%s"]}]}\n' "$sb/deaf.sh" > "$sb/table.json"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_WATCHDOG_SECS=2 FLEET_NODE_STOP_SECS=2
  python3 -I "$sb/rt/bin/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  # state.json, not `sh -c pgrep -f <path>`: that sh's own argv names the path
  until_ok 10 python3 -c 'import json,os,sys; t=json.load(open(sys.argv[1]))["tasks"]["deaf"]; os.kill(int(t["pid"]), 0); sys.exit(0 if t.get("result") == "running" else 1)' "$sb/db/state.json" 2>/dev/null \
    || { WHY="the task never started: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup"; return 1; }
  t0=$(now)
  kill -TERM "$sup"   # the same stop a restart request takes
  until_ok 10 sh -c '! kill -0 "$1" 2>/dev/null' _ "$sup" \
    || { WHY="the stop waited on a task deaf to TERM (still alive $(since "$t0")s after): $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill -9 "$sup"; pkill -f "$sb/deaf.sh"; return 1; }
  SECS=$(since "$t0")
  grep -q 'task deaf pid .* still running .* left to run' "$sb/sup.err" \
    || { WHY="the stop did not say it left the task: $(tail -3 "$sb/sup.err" | tr '\n' ' ')"; pkill -f "$sb/deaf.sh"; return 1; }
  pgrep -f "$sb/deaf.sh" >/dev/null || { WHY="the task was not left to run"; return 1; }
  # the next daemon books it, never a second copy beside it (#3671)
  python3 -I "$sb/rt/bin/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup2=$!; printf '%s\n' "$sup2" >> "$WORK/cred-pids"
  until_ok 10 python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["tasks"]["deaf"]; sys.exit(0 if t.get("result") == "busy" and t.get("orphan") else 1)' "$sb/db/state.json" 2>/dev/null \
    || { WHY="the next daemon did not book the left task: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup2"; pkill -f "$sb/deaf.sh"; return 1; }
  sleep 1
  n=$(pgrep -f "$sb/deaf.sh" | wc -l | tr -d ' ')
  kill "$sup2" 2>/dev/null; pkill -9 -f "$sb/deaf.sh" 2>/dev/null
  [ "$n" = 1 ] || { WHY="$n copies of the task after the restart"; return 1; }
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_WATCHDOG_SECS FLEET_NODE_STOP_SECS
  WHAT="整机守护停下（重启请求 / TERM）时一项任务不理 TERM：${SECS}s 内照样退出、日志写明「留着它跑」、pid 留在 state.json，下一个守护把它记成孤儿、不再起第二份——不再像那台 Mac 那样停在退出路径上 111 分钟"
}

# node-demote-in-forked-child (#4144): the same morning's cause. The root core
# serves a thread per connection; its exec-as / run-as forked with
# preexec_fn=demote(), which called initgroups() in the child — and a fork from a
# threaded parent copies libinfo's cache lock as another thread held it: the child
# (argv still `fleet-node-core.py serve`) waited on that mutex for good, Popen()
# waited on its exec with no timeout over it, and the updater never returned.
# A login's identity is Popen's user / group / extra_groups now (demote_kw: set in
# C between fork and exec, the groups looked up in the parent).
drill_node_demote_in_forked_child() {
  CAP=10; local t0 bad out
  t0=$(now)
  bad=$(grep -n 'preexec_fn=[^,)]*demote\|preexec_fn=.*initgroups' "$BIN"/*.py 2>/dev/null)
  [ -z "$bad" ] || { WHY="a Popen still demotes in the forked child: $bad"; return 1; }
  out=$(python3 -I - "$BIN/fleet-node-supervisor.py" <<'EOF' 2>&1
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sup", sys.argv[1]); sup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sup)
import pwd
me = pwd.getpwuid(os.getuid())
kw = sup.demote_kw(me.pw_name, me.pw_uid, me.pw_gid, me.pw_dir)
assert "preexec_fn" not in kw and kw["cwd"] in (me.pw_dir, "/"), kw
os.geteuid = lambda: 0      # root's answer, without root
kw = sup.demote_kw(me.pw_name, me.pw_uid, me.pw_gid, "/nonexistent-4144")
assert kw["user"] == me.pw_uid and kw["group"] == me.pw_gid and kw["cwd"] == "/", kw
assert kw["extra_groups"][0] == me.pw_gid and len(kw["extra_groups"]) <= os.sysconf("SC_NGROUPS_MAX"), kw
print("ok")
EOF
)
  [ "$out" = ok ] || { WHY="demote_kw: $out"; return 1; }
  SECS=$(since "$t0")
  WHAT="bin/ 里没有一处 Popen 在 fork 出的子进程里降权（preexec_fn=demote / initgroups）；demote_kw 给出 user / group / extra_groups（组在父进程里查好、不超 NGROUPS_MAX）和 cwd，没有 preexec_fn——多线程的 root core fork 后不再卡在 libinfo 的锁上"
}

drill_node_fda_probe_hang() {
  CAP=15   # the probe's 1 s timeout + a few passes
  local sb sup t0 n
  sb="$WORK/fdahang"; mkdir -p "$sb/LaunchDaemons" "$sb/rt/bin"
  cp "$BIN/fleet-node-supervisor.py" "$sb/rt/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$sb/ok.sh"
  printf '{"children":[],"tasks":[{"name":"t","every":0.3,"cmd":["/bin/bash","%s"]}]}\n' "$sb/ok.sh" > "$sb/table.json"
  mkfifo "$sb/TCC.db"   # an open() of it never returns — tccd not answering (mac-d, 2026-10-11)
  t0=$(now)
  FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_WATCHDOG_SECS=3 \
    FLEET_NODE_TCC_DB="$sb/TCC.db" FLEET_NODE_FDA_TIMEOUT=1 \
    python3 -I "$sb/rt/bin/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 10 python3 -c 'import json,sys; f=json.load(open(sys.argv[1])).get("fda") or {}; sys.exit(0 if f.get("timeout") and f.get("ok") is None else 1)' "$sb/db/state.json" 2>/dev/null \
    || { WHY="no «unknown» reading from the hung probe: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup"; return 1; }
  n=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tasks"]["t"].get("runs",0))' "$sb/db/state.json")
  until_ok 5 python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["tasks"]["t"].get("runs",0) > int(sys.argv[2]) + 3 else 1)' "$sb/db/state.json" "$n" \
    || { WHY="the loop stopped after the probe hung"; kill "$sup"; return 1; }
  kill -0 "$sup" 2>/dev/null || { WHY="the daemon exited (the watchdog fired: the loop was held)"; return 1; }
  grep -q 'watchdog: the main loop' "$sb/sup.err" && { WHY="the watchdog fired: the probe held the loop"; kill "$sup"; return 1; }
  SECS=$(since "$t0")
  kill "$sup" 2>/dev/null
  WHAT="完全磁盘访问探测读 TCC.db 的 open() 永不返回：探测是子进程，主循环照转，1s 后杀掉、记为「未知」（不报「没有权限」），任务一直在跑，看门狗没触发"
}

# tcc-prompt-wedge (#3167): mac-d's admin agent ran fleet-login-new.sh; sysadminctl
# asked TCC for SysAdminFiles, charged to ccquota (an ungranted identity on every
# release), and the dialog sat on a console nobody watched. The user tccd waited
# on it forever, sandboxd's approval queues filled behind it, and every user
# delete on the machine failed «disallowed by sandbox» — sudo dscl too. Now the
# agent runs every account script through fleet-tcc-disclaim.py (its own
# responsible process: /bin/bash, never prompted for), and probe timeouts in a
# row are the doctor's FAIL naming the way out.
drill_tcc_prompt_wedge() {
  CAP=30
  local sb sup t0 out rc f
  t0=$(now)
  # the wrapper: runs the command, hands its exit status back, signals as 128+N
  out=$(python3 -I "$BIN/fleet-tcc-disclaim.py" -- /bin/sh -c 'exit 7' 2>&1); rc=$?
  [ "$rc" = 7 ] || { WHY="fleet-tcc-disclaim.py did not hand the exit status back (rc $rc: $out)"; return 1; }
  out=$(python3 -I "$BIN/fleet-tcc-disclaim.py" -- /bin/sh -c 'kill -TERM $$' 2>&1); rc=$?
  [ "$rc" = 143 ] || { WHY="fleet-tcc-disclaim.py: a signalled child read rc $rc, not 143"; return 1; }
  f="$ROOT/tokenledger/agent/node_accounts_test.go"
  grep -q '^func TestAccountScriptTCCDisclaimed(' "$f" 2>/dev/null \
    || { WHY="the agent half's test TestAccountScriptTCCDisclaimed is not in ${f#$ROOT/}"; return 1; }
  # the supervisor: TCC.db whose open() never returns, probed every tick
  sb="$WORK/tccwedge"; mkdir -p "$sb/LaunchDaemons" "$sb/rt/bin"
  cp "$BIN/fleet-node-supervisor.py" "$sb/rt/bin/"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  mkfifo "$sb/TCC.db"
  FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_WATCHDOG_SECS=5 \
    FLEET_NODE_TCC_DB="$sb/TCC.db" FLEET_NODE_FDA_TIMEOUT=1 FLEET_NODE_TENANT_EVERY=0 \
    python3 -I "$sb/rt/bin/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 15 python3 -c 'import json,sys; f=json.load(open(sys.argv[1])).get("fda") or {}; sys.exit(0 if (f.get("stuck") or 0) >= 2 else 1)' "$sb/db/state.json" 2>/dev/null \
    || { WHY="probe timeouts in a row were not counted: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup"; return 1; }
  out=$(FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TEST=1 \
    python3 -I "$sb/rt/bin/fleet-node-supervisor.py" status --check 2>&1); rc=$?
  kill "$sup" 2>/dev/null
  [ "$rc" = 6 ] || { WHY="status --check read rc $rc on a stuck TCC, want 6: $out"; return 1; }
  case "$out" in *'killall -9 sandboxd'*) ;; *) WHY="the check does not name the way out: $out"; return 1 ;; esac
  grep -q 'fda.stuck' "$BIN/fleet-doctor.sh" || { WHY="the doctor's node row has no case for exit 6"; return 1; }
  SECS=$(since "$t0")
  WHAT="账号脚本经 fleet-tcc-disclaim.py 起（自己是责任进程，/bin/bash 不弹框，退出码原样带回）；TCC 探针连续超时 → status --check 6、体检 node FAIL 写明点掉框 / kill tccd / killall sandboxd"
}

# tcc-disclaim-sigpipe (#3419): Python starts with SIGPIPE ignored and a bare
# posix_spawn hands that on, so under the wrapper `tr </dev/urandom | head -c 22`
# never died — an account create spun 9 minutes in gen_password. (`yes` alone
# does not show it: it exits on its own write error; BSD tr keeps reading.)
drill_tcc_disclaim_sigpipe() {
  CAP=10
  local t0 out rc pw
  t0=$(now)
  out=$(python3 -I "$BIN/fleet-tcc-disclaim.py" -- /bin/sh -c 'yes | head -c 1 >/dev/null; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 1 >/dev/null; echo done' 2>&1 & p=$!
        ( sleep 5; kill -9 "$p" ) >/dev/null 2>&1 & w=$!
        wait "$p"; rc=$?; kill "$w" 2>/dev/null; exit "$rc"); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 0 ] && [ "$out" = "done" ] \
    || { WHY="\`tr </dev/urandom | head -c 1\` under fleet-tcc-disclaim.py did not end (rc $rc, ${SECS}s): $out"; return 1; }
  awk -v s="$SECS" 'BEGIN { exit !(s <= 1.5) }' || { WHY="\`tr </dev/urandom | head -c 1\` under the wrapper took ${SECS}s, want ≤ 1 (+ the clock's own startup)"; return 1; }
  pw=$(sed -n 's/^gen_password() { \(.*\) }$/\1/p' "$BIN/fleet-login-new.sh")
  [ -n "$pw" ] || { WHY="gen_password not found in fleet-login-new.sh"; return 1; }
  # with SIGPIPE ignored outright, the bounded form still ends and still gives 22 + a7
  out=$(python3 -I -c 'import signal,subprocess,sys; signal.signal(signal.SIGPIPE, signal.SIG_IGN); sys.exit(subprocess.call(["/bin/bash","-c",sys.argv[1]], restore_signals=False, timeout=5))' "$pw" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ "${#out}" = 24 ] || { WHY="gen_password with SIGPIPE ignored: rc $rc, out '$out'"; return 1; }
  SECS=$(since "$t0")
  WHAT="经 fleet-tcc-disclaim.py 起的脚本 SIGPIPE 是默认处置：\`tr </dev/urandom | head -c 1\` ≤ 1 秒结束；gen_password 即使在忽略 SIGPIPE 时也有界、照样出 24 位"
}

drill_task_fail_silent() {
  CAP=30   # the batch's bar is ≤ 1 h from the first failure; with no retry delay it is seconds
  local sb sup t0 ap
  sb="$WORK/task"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  # the session never opens (the prompt names no skill / the fleet is full): the spawner refuses every time
  printf '#!/bin/bash\necho "$*" >> "%s/calls"\necho "dash-raw-session: at capacity" >&2\nexit 2\n' "$sb" > "$sb/spawn.sh"
  chmod +x "$sb/spawn.sh"
  python3 -c 'import calendar; print(calendar.timegm((2026, 10, 10, 6, 59, 0)))' > "$sb/clock"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
    FLEET_NODE_CLOCK="$sb/clock"
  python3 "$BIN/fleet-node-supervisor.py" service add --kind task --login alice --name daily --at 07:00 --tz UTC \
    --fleet drill-sandbox --prompt '/no-such-skill' --retries 2 --retry-delay 0 --env FLEET_TASK_SPAWN="$sb/spawn.sh" \
    >"$sb/add.out" 2>&1 || { WHY="task add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  python3 -c 'import calendar; print(calendar.timegm((2026, 10, 10, 7, 0, 1)))' > "$sb/clock"
  until_ok 10 test -s "$sb/calls" || { WHY="the slot never ran: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  t0=$(now); ap="$sb/db/logins/alice/alerts/daily.json"
  until_ok 30 test -f "$ap" || { WHY="no alert after the last try ($(wc -l < "$sb/calls") calls)"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0"); sleep 1
  [ "$(wc -l < "$sb/calls" | tr -d ' ')" = 3 ] || { WHY="$(wc -l < "$sb/calls") tries, not 1 + 2 retries"; kill "$sup" 2>/dev/null; return 1; }
  python3 "$BIN/fleet-node-supervisor.py" status --json | python3 -c 'import json, sys; r = [x for x in json.load(sys.stdin)["services"] if x["name"] == "daily"][0]; assert r["status"] == "failed" and r["alert"] and "did not open" in r["last_error"], r' 2>"$sb/st.err" \
    || { WHY="services[] does not say failed: $(tail -1 "$sb/st.err")"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD FLEET_NODE_CLOCK
  WHAT="定时 agent 任务的会话一次也开不了：到点开一次、重试 2 次后不再试，状态 failed、告警文件落地，services[] 带 failed 与原因"
}

drill_service_killed() {
  CAP=30   # the issue's bar: a killed service is back within 30 s
  local sb sup p1 p2 t0
  sb="$WORK/svc"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\necho "up $(id -u) $USER"\nexec sleep 300\n' > "$sb/watch.sh"; chmod +x "$sb/watch.sh"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  python3 "$BIN/fleet-node-supervisor.py" service add --login alice --name watch -- "$sb/watch.sh" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  svc_pid() { python3 -c 'import json, sys; print((json.load(open(sys.argv[1]))["children"].get("svc:alice/watch") or {}).get("pid") or "")' "$sb/db/state.json" 2>/dev/null; }
  until_ok 15 sh -c 'grep -q "^up " "$1" 2>/dev/null' _ "$sb/log/logins/alice/watch.log" \
    || { WHY="the service never ran (no log): $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; return 1; }
  p1=$(svc_pid); [ -n "$p1" ] || { WHY="no pid recorded"; return 1; }
  kill -9 "$p1"; t0=$(now)
  until_ok 30 sh -c '[ -n "$2" ] && [ "$(python3 -c "import json,sys; print((json.load(open(sys.argv[1]))[\"children\"].get(\"svc:alice/watch\") or {}).get(\"pid\") or \"\")" "$1" 2>/dev/null)" != "$2" ] && [ "$(grep -c "^up " "$3")" -ge 2 ]' _ "$sb/db/state.json" "$p1" "$sb/log/logins/alice/watch.log" \
    || { WHY="the killed service was not brought back"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0"); p2=$(svc_pid)
  python3 "$BIN/fleet-node-supervisor.py" status --json | python3 -c 'import json, sys; r = [x for x in json.load(sys.stdin)["services"] if x["name"] == "watch"][0]; assert r["status"] == "running" and r["restarts"] >= 1, r' 2>"$sb/st.err" \
    || { WHY="status --json .services did not show it running with a restart: $(tail -1 "$sb/st.err")"; kill "$sup" 2>/dev/null; return 1; }
  python3 "$BIN/fleet-node-supervisor.py" service rm --login alice --name watch >/dev/null
  until_ok 10 sh -c '! kill -0 "$1" 2>/dev/null' _ "$p2" || { WHY="rm left the service running"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="登记的服务 kill -9：守护按子进程退避在 30 秒内以原登录身份重起，日志续写在 logins/<登录>/，status --json 的 services[] 记重启次数；rm 后停掉"
}

drill_service_login_moved() {
  CAP=30   # the move → the first run under the new login
  local sb sup ha hb t0 r
  sb="$WORK/svcmove"; ha="$sb/Users/frank"; hb="$sb/Users/erin"
  mkdir -p "$sb/LaunchDaemons" "$ha/daily-report/logs" "$ha/.claude/skills/daily-report" "$hb"
  printf '{"frank": {"uid": %s, "gid": %s, "home": "%s"}, "erin": {"uid": %s, "gid": %s, "home": "%s"}}\n' \
    "$(id -u)" "$(id -g)" "$ha" "$(id -u)" "$(id -g)" "$hb" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf 'skill\n' > "$ha/.claude/skills/daily-report/SKILL.md"
  # the 2026-10-08 case: the daily push gives up when its login's things are not there
  printf '#!/bin/bash\n[ -f "$HOME/.claude/skills/daily-report/SKILL.md" ] && [ -n "$BARK_KEY" ] || { echo "give up $USER"; exit 1; }\necho "pushed $USER" >> "$HOME/daily-report/logs/run.log"; echo "ok $USER"\nexec sleep 300\n' \
    > "$ha/daily-report/run.sh"; chmod +x "$ha/daily-report/run.sh"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  printf 'k\n' | python3 "$BIN/fleet-node-supervisor.py" service cred set --login frank --name BARK_KEY >/dev/null
  python3 "$BIN/fleet-node-supervisor.py" service add --login frank --name daily-report --cred BARK_KEY \
    --path "$ha/daily-report" --path "$ha/.claude/skills/daily-report" -- "$ha/daily-report/run.sh" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 15 grep -q '^ok frank' "$sb/log/logins/frank/daily-report.log" \
    || { WHY="it never ran as the old login: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  python3 "$BIN/fleet-node-supervisor.py" account release frank >"$sb/rel.out" 2>&1; r=$?
  [ "$r" = 6 ] && grep -q 'service move --login frank --name daily-report' "$sb/rel.out" \
    || { WHY="releasing the old login with a task left was not refused 6 (rc $r)"; kill "$sup" 2>/dev/null; return 1; }
  grep -q 'exit 6' "$BIN/fleet-login-remove.sh" || { WHY="fleet-login-remove.sh has no exit 6 refusal"; kill "$sup" 2>/dev/null; return 1; }
  t0=$(now)
  python3 "$BIN/fleet-node-supervisor.py" service move --login frank --name daily-report --to erin >"$sb/move.out" 2>&1 \
    || { WHY="service move failed: $(tail -2 "$sb/move.out" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  until_ok 30 grep -q '^ok erin$' "$sb/log/logins/erin/daily-report.log" \
    || { WHY="it did not run as the new login: $(tail -2 "$sb/log/logins/erin/daily-report.log" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0")
  grep -q '^give up' "$sb/log/logins/erin/daily-report.log" && { WHY="it gave up under the new login"; kill "$sup" 2>/dev/null; return 1; }
  [ -z "$(ls "$sb/db/logins/frank/services")" ] && [ ! -e "$ha/daily-report" ] && [ ! -e "$ha/.claude/skills/daily-report" ] \
    && [ ! -e "$sb/log/logins/frank/daily-report.log" ] && [ ! -e "$sb/db/logins/frank/creds/BARK_KEY" ] \
    || { WHY="something of it is left under the old login"; kill "$sup" 2>/dev/null; return 1; }
  grep -q 'pushed erin' "$hb/daily-report/logs/run.log" || { WHY="the job's own log is not in the new home"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="每日推送登记在旧登录下：退役旧登录（account release / fleet-login-remove）因有任务未迁走被拒（退 6，打印 move 命令）；service move 后条目、工作目录、技能目录、日志、凭据都到新登录下，旧登录下一样不剩，守护以新登录身份按时跑起来"
}

drill_service_failed_unseen() {
  CAP=30   # the EPIC's bar is ≤ 1 hour from the first failure to a red reading; here, seconds
  local sb sup t0 d a
  sb="$WORK/svcfail"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\necho "give up: skill not found"\nexit 1\n' > "$sb/report.sh"; chmod +x "$sb/report.sh"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  python3 "$BIN/fleet-node-supervisor.py" service add --login alice --name daily-report -- "$sb/report.sh" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  # before the daemon runs it: registered, never started — not a failure yet
  d=$(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --doctor)
  case "$d" in FAIL*) WHY="red before it ever ran: $d"; return 1 ;; esac
  t0=$(now)
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 30 sh -c 'FLEET_SERVICES_CACHE="" FLEET_SERVICES_STATE="$1" FLEET_SERVICES_LOGIN=alice python3 "$2" --doctor | grep -q "^FAIL 1/1 failed: alice/daily-report@"' \
      _ "$sb/db/state.json" "$BIN/fleet-services.py" \
    || { WHY="the dying service never read red in the doctor: $(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --doctor)"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0")
  a=$(FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --alerts)
  case "$a" in service-*-alice-daily-report*) ;; *) WHY="no alert line for it: [$a]"; kill "$sup" 2>/dev/null; return 1 ;; esac
  python3 "$BIN/fleet-node-supervisor.py" service rm --login alice --name daily-report >/dev/null
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="登记的服务一启动就退：几秒内体检 services 行 FAIL、告警栏多一条 ✖ service · failed（入口另有 service_failed），不再是 40 小时没人知道"
}

# ---- services-elsewhere-rollback (#3978): the hub hands this login the same
# person's services on every machine; one of them down on mac-a read FAIL in
# mac-b's doctor, and install-sync rolls back on a FAIL the old version lacked.
drill_services_elsewhere_rollback() {
  CAP=15; local sb t0 d tags
  sb="$WORK/svcelse"; mkdir -p "$sb"
  cat > "$sb/hub.json" <<'EOF'
{"ts": 1791529440, "machines": [
 {"hostname": "mac-a.example.ts.net", "label": "mac-a", "services": [
  {"name": "webchat", "kind": "service", "login": "alice", "state": "down", "last_rc": 3, "last_log_line": "fleet-webchat: another server already answers"}]},
 {"hostname": "mac-b.example.ts.net", "label": "mac-b", "services": [
  {"name": "webchat", "kind": "service", "login": "alice2", "state": "running"}]}]}
EOF
  sv() { FLEET_SERVICES_CACHE="$sb/hub.json" FLEET_SERVICES_STATE='' FLEET_SERVICES_HOST=mac-b \
         FLEET_SERVICES_LOGIN=alice2 FLEET_SERVICES_NOW=1791529500 python3 "$BIN/fleet-services.py" --doctor; }
  grep -q 'FAIL\\ \*) fail services' "$BIN/fleet-doctor.sh" || { WHY="fleet-doctor.sh no longer maps the services line"; return 1; }
  t0=$(now)
  d=$(sv)
  # install-sync's ruler (doctor_fail_tags): the tags of the doctor's FAIL lines
  tags=$(case "$d" in (FAIL\ *) echo services ;; esac)
  [ -z "$tags" ] || { WHY="mac-a's service is a FAIL tag in mac-b's doctor — the switch would roll back: $d"; return 1; }
  case "$d" in "WARN "*"alice/webchat@mac-a"*) ;; *) WHY="mac-a's failed service is no longer named: $d"; return 1 ;; esac
  sed 's/"alice2", "state": "running"/"alice2", "state": "down"/' "$sb/hub.json" > "$sb/h2" && mv "$sb/h2" "$sb/hub.json"
  d=$(sv)
  case "$d" in "FAIL 2/2 failed: alice2/webchat@mac-b"*) ;; *) WHY="this login's own failed service here is not FAIL: $d"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="同一个人在 mac-a 的服务已退出：mac-b 上 alice2 的体检 services 行只 WARN 点名它，不是 FAIL，安装跟随不因它回滚；本机本登录的服务挂了照旧 FAIL"
}

drill_service_handwritten() {
  CAP=20   # two sweeps + three doctor reads
  local sb t0 d w
  sb="$WORK/svchand"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice/bin" "$sb/Users/alice/Library/LaunchAgents"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\nsleep 300\n' > "$sb/Users/alice/bin/sms-watch"; chmod +x "$sb/Users/alice/bin/sms-watch"
  pl() {   # pl <file> <label> <user or ""> <program>
    python3 -c 'import plistlib, sys
d = {"Label": sys.argv[2], "ProgramArguments": [sys.argv[4]], "KeepAlive": True}
if sys.argv[3]: d["UserName"] = sys.argv[3]
plistlib.dump(d, open(sys.argv[1], "wb"))' "$@"
  }
  # the two hand-written ones (mac-d, 2026-10-09: com.frank.sms-watch, com.erin.daily-report) ...
  pl "$sb/LaunchDaemons/com.alice.sms-watch.plist" com.alice.sms-watch alice "$sb/Users/alice/bin/sms-watch"
  pl "$sb/Users/alice/Library/LaunchAgents/com.alice.daily-report.plist" com.alice.daily-report "" "$sb/Users/alice/bin/sms-watch"
  # ... and what is not a person's background task: a root daemon, a system account's, an app's own agent
  pl "$sb/LaunchDaemons/com.alice.net-tuning.plist" com.alice.net-tuning "" /usr/sbin/sysctl
  pl "$sb/LaunchDaemons/sh.brew.thing.plist" sh.brew.thing _brew /opt/homebrew/bin/thing
  pl "$sb/Users/alice/Library/LaunchAgents/com.vendor.updater.plist" com.vendor.updater "" "$sb/Users/alice/Library/Application Support/Vendor/updater"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  # the sweep looks only at the logins the daemon took over (#2702)
  mkdir -p "$sb/db/logins"; : > "$sb/db/logins/alice.env"
  doc() { FLEET_SERVICES_CACHE='' FLEET_SERVICES_STATE="$sb/db/state.json" FLEET_SERVICES_LOGIN=alice python3 "$BIN/fleet-services.py" --doctor; }
  t0=$(now)
  python3 "$BIN/fleet-node-supervisor.py" sweep >"$sb/sweep1.out" 2>&1 \
    || { WHY="sweep failed: $(tail -2 "$sb/sweep1.out" | tr '\n' ' ')"; return 1; }
  d=$(doc)
  case "$d" in "WARN 2 个手写启动项"*com.alice.sms-watch*) ;; *) WHY="the two hand-written plists did not read WARN 2: [$d] (sweep: $(tr '\n' ' ' < "$sb/sweep1.out"))"; return 1 ;; esac
  case "$d" in *net-tuning*|*brew*|*vendor*) WHY="counted what is not a person's task: [$d]"; return 1 ;; esac
  w=$(python3 "$BIN/fleet-node-supervisor.py" status | grep -c '^handwritten ')
  [ "$w" = 2 ] || { WHY="status names $w hand-written plists, not 2"; return 1; }
  # 收编: register it, then archive the plist — the next sweep has nothing left
  python3 "$BIN/fleet-node-supervisor.py" service add --login alice --name sms-watch -- "$sb/Users/alice/bin/sms-watch" >"$sb/add.out" 2>&1 \
    || { WHY="service add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  d=$(doc)
  case "$d" in WARN*) ;; *) WHY="registered but the plist still loaded, yet no WARN: [$d]"; return 1 ;; esac
  mkdir -p "$sb/attic"; mv "$sb/LaunchDaemons/com.alice.sms-watch.plist" "$sb/Users/alice/Library/LaunchAgents/com.alice.daily-report.plist" "$sb/attic/"
  python3 "$BIN/fleet-node-supervisor.py" sweep >/dev/null 2>&1
  d=$(doc)
  case "$d" in WARN*|FAIL*) WHY="still not green once archived: [$d]"; return 1 ;; esac
  SECS=$(since "$t0")
  python3 "$BIN/fleet-node-supervisor.py" service rm --login alice --name sms-watch >/dev/null 2>&1
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD
  WHAT="手写的 plist 以某个登录跑、登记表里没有：整机守护的清扫点名、体检 services 行 WARN；登记并归档后转绿（root 的、系统账号的、应用自带的不算）"
}

drill_sweep_admin_agent() {
  CAP=20   # two sweeps
  local sb t0 out
  sb="$WORK/sweepadmin"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/bob/Library/LaunchAgents" \
    "$sb/Users/alice/Library/LaunchAgents" "$sb/db/logins"
  # bob: the machine's admin (never taken over, #2842); alice: taken over
  printf '{"bob": {"uid": %s, "gid": %s, "home": "%s", "groups": ["staff", "admin"], "sudo": "(ALL) ALL"},
 "alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/bob" \
    "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  : > "$sb/db/logins/alice.env"
  printf '{"role": "managed", "version": 0}\n' > "$sb/db/expected.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  # launchctl: every bootout takes (print says gone)
  printf '#!/bin/bash\necho "$*" >> "%s/launchctl.log"\n[ "$1" = print ] && exit 113\nexit 0\n' "$sb" > "$sb/launchctl"
  chmod +x "$sb/launchctl"
  pl() {   # pl <file> <label> [user]
    python3 -c 'import plistlib, sys
d = {"Label": sys.argv[2], "ProgramArguments": ["/bin/true"]}
if len(sys.argv) > 3: d["UserName"] = sys.argv[3]
plistlib.dump(d, open(sys.argv[1], "wb"))' "$@"
  }
  # the 2026-10-10 machines: the admin's own node agent (a LaunchDaemon) and its fleet's daemons
  pl "$sb/LaunchDaemons/com.ccquota.agent.bob.plist" com.ccquota.agent.bob bob
  pl "$sb/Users/bob/Library/LaunchAgents/com.claude-fleet.dispatch.plist" com.claude-fleet.dispatch
  # what the sweep is for: a taken-over login's leftover
  pl "$sb/Users/alice/Library/LaunchAgents/com.claude-fleet.spinner.plist" com.claude-fleet.spinner
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_LAUNCHCTL="$sb/launchctl" FLEET_NODE_BOOTOUT_WAIT=0.3 FLEET_NODE_TEST=1 \
    FLEET_NODE_PASSWD="$sb/passwd.json" FLEET_NODE_SWEEP_HOLD="fbi-hold-$$.sh"
  t0=$(now)
  for _ in 1 2; do
    out=$(python3 "$BIN/fleet-node-supervisor.py" sweep 2>&1) \
      || { WHY="sweep failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; break; }
  done
  SECS=$(since "$t0")
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_LAUNCHCTL FLEET_NODE_BOOTOUT_WAIT FLEET_NODE_TEST FLEET_NODE_PASSWD FLEET_NODE_SWEEP_HOLD
  [ -z "${WHY:-}" ] || return 1
  [ -f "$sb/LaunchDaemons/com.ccquota.agent.bob.plist" ] \
    || { WHY="the admin's own node agent went to the attic: $(printf '%s' "$out" | tr '\n' ' ')"; return 1; }
  [ -f "$sb/Users/bob/Library/LaunchAgents/com.claude-fleet.dispatch.plist" ] \
    || { WHY="the admin's fleet daemon went to the attic"; return 1; }
  if grep -q 'bob' "$sb/launchctl.log" 2>/dev/null; then WHY="booted the admin's unit out: $(tr '\n' ' ' < "$sb/launchctl.log")"; return 1; fi
  [ ! -f "$sb/Users/alice/Library/LaunchAgents/com.claude-fleet.spinner.plist" ] \
    || { WHY="the taken-over login's leftover stayed — the sweep did nothing: $(printf '%s' "$out" | tr '\n' ' ')"; return 1; }
  WHAT="托管机器清扫两轮：管理员登录自己的节点 agent（com.ccquota.agent.<管理员>）和它的 fleet 守护原地不动、不 bootout；托管登录的残留照样进 attic"
}

drill_task_rerun_root_only() {
  CAP=60   # the issue's bar: the session is there within a minute of `fleet task run --now`
  local sb sup t0 out
  sb="$WORK/rerun"; mkdir -p "$sb/LaunchDaemons" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '#!/bin/bash\necho "$*" >> "%s/calls"\nprintf "@7\\tdaily\\t\\tfid\\n"\n' "$sb" > "$sb/spawn.sh"
  chmod +x "$sb/spawn.sh"
  # noon: today's 07:00 slot is long past and was never this entry's — nothing runs on its own
  python3 -c 'import calendar; print(calendar.timegm((2026, 10, 10, 12, 0, 0)))' > "$sb/clock"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" \
    FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" \
    FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
    FLEET_NODE_CLOCK="$sb/clock"
  python3 "$BIN/fleet-node-supervisor.py" service add --kind task --login alice --name daily --at 07:00 --tz UTC \
    --fleet drill-sandbox --prompt '/daily-report' --env FLEET_TASK_SPAWN="$sb/spawn.sh" \
    >"$sb/add.out" 2>&1 || { WHY="task add failed: $(tail -2 "$sb/add.out" | tr '\n' ' ')"; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  sleep 1
  [ ! -s "$sb/calls" ] || { WHY="a past slot ran by itself"; kill "$sup" 2>/dev/null; return 1; }
  # the client's table says where the entry lives; the "hub" stands in for the
  # node half the agent runs for service_control (node_service_ctl.go): its
  # fixed supervisor argv, on the lane's own login
  printf '{"ts": 1, "machines": [{"hostname": "mac-a.drill", "label": "mac-a", "services": [{"name": "daily", "kind": "task", "login": "alice", "state": "scheduled"}]}]}\n' > "$sb/hub_services"
  {
    printf '#!/bin/bash\n[ "$1" = service_control ] || exit 9\n'
    printf 'if python3 -I %q service run --login alice --name daily >/dev/null 2>%q; then\n' "$BIN/fleet-node-supervisor.py" "$sb/hub.err"
    printf '  echo %q\nelse\n  echo %q\nfi\n' '{"operation_id":"op","status":"succeeded","result":{"how":"service run"}}' \
      '{"operation_id":"op","status":"failed","result":{"error":{"code":"REFUSED","message":"supervisor refused"}}}'
  } > "$sb/hub.sh"
  chmod +x "$sb/hub.sh"
  t0=$(now)
  out=$(FLEET_SERVICES_CACHE="$sb/hub_services" FLEET_SERVICES_STATE='' FLEET_SESSION_CLI_WRITE="$sb/hub.sh" \
        python3 "$BIN/fleet-session-cli.py" task run daily --now 2>&1) \
    || { WHY="fleet task run --now: $out $(cat "$sb/hub.err" 2>/dev/null)"; kill "$sup" 2>/dev/null; return 1; }
  until_ok 60 test -s "$sb/calls" || { WHY="no session opened: $(tail -2 "$sb/sup.err" | tr '\n' ' ')"; kill "$sup" 2>/dev/null; return 1; }
  SECS=$(since "$t0")
  grep -q -- '--name daily-2026-10-10-now1200' "$sb/calls" \
    || { WHY="the run took the slot's window: $(cat "$sb/calls")"; kill "$sup" 2>/dev/null; return 1; }
  kill "$sup" 2>/dev/null; wait "$sup" 2>/dev/null
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD FLEET_NODE_CLOCK
  WHAT="漏了一次的定时任务从客户端补跑：fleet task run --now → service_control → 节点固定 argv 的 service run，几秒内会话打开（自己的窗口名 …-now<时分>），不再要 root 上机器 kickstart"
}

drill_account_adopt_stuck() {
  CAP=10
  local sb la t0 n
  sb="$WORK/acct"; la="$sb/Users/alice/Library/LaunchAgents"
  mkdir -p "$la" "$sb/lc/loaded" "$sb/lc/stuck" "$sb/LaunchDaemons" "$sb/Users/alice/.claude/fleet/bin"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  cat > "$sb/launchctl" <<'LC'
#!/bin/bash
d="$FAKE_LC"; echo "$*" >> "$d/log"
case "$1" in
  bootout) l="${2##*/}"; [ -e "$d/stuck/$l" ] && exit 5; rm -f "$d/loaded/$l" ;;
  bootstrap) touch "$d/loaded/$(basename "$3" .plist)" ;;
  print) [ -e "$d/loaded/${2##*/}" ] ;;
esac
LC
  chmod +x "$sb/launchctl"
  for u in cleanup dispatch spinner; do
    python3 -c 'import plistlib, sys; plistlib.dump({"Label": sys.argv[2], "ProgramArguments": ["/bin/true"]}, open(sys.argv[1], "wb"))' \
      "$la/com.claude-fleet.$u.plist" "com.claude-fleet.$u"
    : > "$sb/lc/loaded/com.claude-fleet.$u"
  done
  : > "$sb/lc/stuck/com.claude-fleet.dispatch"
  printf '{"account": []}\n' > "$sb/table.json"
  sup() { FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
          FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
          FLEET_NODE_LAUNCHCTL="$sb/launchctl" FLEET_NODE_BOOTOUT_WAIT=1 FAKE_LC="$sb/lc" python3 "$BIN/fleet-node-supervisor.py" "$@"; }
  t0=$(now)
  sup account adopt alice >"$sb/adopt.out" 2>&1 && { WHY="adopt succeeded past a service that did not unload"; return 1; }
  n=$(ls "$la" | wc -l | tr -d ' ')
  [ "$n" = 3 ] || { WHY="a half migration: $n of 3 plists left in LaunchAgents"; return 1; }
  [ "$(ls "$sb/lc/loaded" | wc -l | tr -d ' ')" = 3 ] || { WHY="a booted-out service was not loaded back: $(ls "$sb/lc/loaded" | tr '\n' ' ')"; return 1; }
  sup account manages alice && { WHY="alice reads managed after a failed adopt"; return 1; }
  rm -f "$sb/lc/stuck/com.claude-fleet.dispatch"
  sup account adopt alice >/dev/null 2>&1 || { WHY="adopt failed once the service unloads"; return 1; }
  [ -z "$(ls "$la")" ] && [ -z "$(ls "$sb/lc/loaded")" ] || { WHY="adopt left a per-account service"; return 1; }
  sup account release alice >/dev/null 2>&1 || { WHY="release failed"; return 1; }
  [ "$(ls "$la" | wc -l | tr -d ' ')" = 3 ] && [ "$(ls "$sb/lc/loaded" | wc -l | tr -d ' ')" = 3 ] \
    || { WHY="release did not put every service back and loaded"; return 1; }
  SECS=$(since "$t0")
  WHAT="迁移中一个服务卸不掉：adopt 退 1，已卸的全部放回并重新加载、账号不算托管；卸得掉之后 adopt 成功，release 一条命令全部还原"
}

# login-remove-managed (#2924): deleting a login the daemon took over — step 4
# killed its demoted tasks, root's supervisor started them again, three rounds,
# exit 1 (drill10092351 on mac-d); its accounts.json entry outlived the login.
# Now fleet-login-remove.sh's step 1c `account forget`s it first: the live
# daemon stops its tasks and starts none again, its entry and env go.
drill_login_remove_managed() {
  CAP=15
  local sb t0 kpid bpid apid
  sb="$WORK/forget"; mkdir -p "$sb/Users/alice/.claude/fleet/bin" "$sb/LaunchDaemons"
  grep -q 'account forget "\$LOGIN"' "$ROOT/bin/fleet-login-remove.sh" \
    || { WHY="fleet-login-remove.sh no longer has the machine daemon forget the login"; return 1; }
  [ "$(grep -n 'account forget' "$ROOT/bin/fleet-login-remove.sh" | head -1 | cut -d: -f1)" -lt \
    "$(grep -n "^step 2 " "$ROOT/bin/fleet-login-remove.sh" | cut -d: -f1)" ] \
    || { WHY="account forget runs after the services are booted out"; return 1; }
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}, "bob": {"uid": %s, "gid": %s, "home": "%s"}}\n' \
    "$(id -u)" "$(id -g)" "$sb/Users/alice" "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '#!/bin/bash\nexec sleep 300\n' > "$sb/Users/alice/.claude/fleet/bin/keep.sh"; chmod +x "$sb/Users/alice/.claude/fleet/bin/keep.sh"
  printf '{"children": [], "tasks": [], "account": [{"name": "keep", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/keep.sh"], "keepalive": true}]}\n' > "$sb/table.json"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
    FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' \
    FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json"
  python3 "$BIN/fleet-node-supervisor.py" account adopt alice >/dev/null 2>&1 \
    && python3 "$BIN/fleet-node-supervisor.py" account adopt bob >/dev/null 2>&1 || { WHY="adopt failed"; _forget_unset; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  _kp() { python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("children", {}).get(sys.argv[2]) or {}).get("pid") or "")' \
           "$sb/db/state.json" "$1" 2>/dev/null; }
  _has_kp() { [ -n "$(_kp "$1")" ]; }
  until_ok 10 _has_kp alice/keep && until_ok 10 _has_kp bob/keep \
    || { WHY="account tasks never started: $(tail -2 "$sb/sup.err")"; _forget_unset; return 1; }
  kpid=$(_kp alice/keep)
  bpid=$(_kp bob/keep)
  _forget_task_running "$kpid" && _forget_task_running "$bpid" \
    || { WHY="account task fixture is not running before forget"; _forget_unset; return 1; }
  t0=$(now)
  python3 "$BIN/fleet-node-supervisor.py" account forget alice >"$sb/forget.out" 2>&1 \
    || { WHY="account forget failed: $(cat "$sb/forget.out")"; _forget_unset; return 1; }
  # forget promises stopped, not reaped (#4481): a real TERM'd child can still
  # have the same PID/birth with stat Z until its daemon's next reap. This must
  # still reject a live task; do not wait longer or retry forget to hide it.
  _forget_task_running "$kpid" && { WHY="alice's task still runs after forget"; _forget_unset; return 1; }
  sleep 1
  apid=$(_kp alice/keep)
  [ -z "$apid" ] || ! _forget_task_running "$apid" \
    || { WHY="the daemon started alice's task again after forget"; _forget_unset; return 1; }
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); sys.exit(0 if "alice" not in a and a["bob"]["managed"] else 1)' \
    "$sb/db/accounts.json" || { WHY="accounts.json still holds alice (or lost bob)"; _forget_unset; return 1; }
  [ "$(_kp bob/keep)" = "$bpid" ] && _forget_task_running "$bpid" \
    || { WHY="forget stopped or replaced bob's task too"; _forget_unset; return 1; }
  SECS=$(since "$t0")
  _forget_unset
  WHAT="删托管账号前先 account forget：守护停掉它降权跑的任务、不再拉起，accounts.json / logins env 摘掉，别的账号不动"
}
_forget_task_running() {
  # The daemon may reap a zombie between kill(0) and ps (#4448). An empty /
  # failed ps is not proof either way: recheck existence before calling it live.
  kill -0 "$1" 2>/dev/null && ! ps -o stat= -p "$1" 2>/dev/null | grep -q '^ *Z' \
    && kill -0 "$1" 2>/dev/null
}

# linux-remove-task-running (#3379): `login remove <X> --host <linux machine>`
# failed at [1c] — the daemon dropped the login, but its fleet-base-sync.sh sat
# in a `git fetch` hung on the network, and `account forget` only WAITED
# FLEET_NODE_RELEASE_WAIT (20 s) for it, then exit 1 «the daemon has not dropped
# them». Now a run that outlives the wait is stopped: its process group TERM,
# then KILL — this one ignores TERM — and the removal goes on.
drill_linux_remove_task_running() {
  CAP=20
  local sb t0 tpid cpid bpid
  sb="$WORK/forget-hung"; mkdir -p "$sb/Users/alice/.claude/fleet/bin" "$sb/Users/bob/.claude/fleet/bin" "$sb/LaunchDaemons"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}, "bob": {"uid": %s, "gid": %s, "home": "%s"}}\n' \
    "$(id -u)" "$(id -g)" "$sb/Users/alice" "$(id -u)" "$(id -g)" "$sb/Users/bob" > "$sb/passwd.json"
  printf '#!/bin/bash\ntrap "" TERM\nsleep 300 &\necho "$!" > "$0.child"\nwait\n' > "$sb/Users/alice/.claude/fleet/bin/hung.sh"
  chmod +x "$sb/Users/alice/.claude/fleet/bin/hung.sh"
  printf '#!/bin/bash\nexec sleep 300\n' > "$sb/Users/bob/.claude/fleet/bin/hung.sh"
  printf '{"children": [], "tasks": [], "account": [{"name": "base-sync", "argv": ["/bin/bash", "__HOME__/.claude/fleet/bin/hung.sh"], "every": 1}]}\n' > "$sb/table.json"
  export FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
    FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' \
    FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" FLEET_NODE_RELEASE_WAIT=1 FLEET_NODE_FORGET_KILL_WAIT=1
  python3 "$BIN/fleet-node-supervisor.py" account adopt alice >/dev/null 2>&1 \
    && python3 "$BIN/fleet-node-supervisor.py" account adopt bob >/dev/null 2>&1 || { WHY="adopt failed"; _forget_unset; return 1; }
  python3 -I "$BIN/fleet-node-supervisor.py" run 2>>"$sb/sup.err" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  _tp() { python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("tasks", {}).get(sys.argv[2]) or {}).get("pid") or "")' \
           "$sb/db/state.json" "$1" 2>/dev/null; }
  _has_tp() { [ -n "$(_tp "$1")" ]; }
  until_ok 10 _has_tp alice/base-sync && until_ok 10 _has_tp bob/base-sync \
    && until_ok 10 test -s "$sb/Users/alice/.claude/fleet/bin/hung.sh.child" \
    || { WHY="tasks never started: $(tail -2 "$sb/sup.err")"; _forget_unset; return 1; }
  tpid=$(_tp alice/base-sync)
  bpid=$(_tp bob/base-sync)
  cpid=$(cat "$sb/Users/alice/.claude/fleet/bin/hung.sh.child")
  python3 -c 'import os,sys; a,c,b=map(int,sys.argv[1:]); assert os.getpgid(a)==os.getpgid(c)==a; assert os.getpgid(b)==b!=a' \
    "$tpid" "$cpid" "$bpid" || { WHY="task process groups do not match their recorded pids"; _forget_unset; return 1; }
  t0=$(now)
  python3 "$BIN/fleet-node-supervisor.py" account forget alice >"$sb/forget.out" 2>&1 \
    || { WHY="account forget failed on a hung task: $(tail -1 "$sb/forget.out")"; kill -9 -- -"$tpid" 2>/dev/null; _forget_unset; return 1; }
  # ended is ended: a killed run waits as a zombie for the daemon's tick to reap
  # it, and forget no longer waits for that (#4044)
  _forget_task_running "$tpid" \
    && { WHY="alice's hung task still runs after forget"; kill -9 -- -"$tpid" 2>/dev/null; _forget_unset; return 1; }
  _forget_task_running "$cpid" \
    && { WHY="alice's task child still runs after forget"; kill -9 -- -"$tpid" 2>/dev/null; _forget_unset; return 1; }
  grep -q 'sent KILL' "$sb/forget.out" || { WHY="forget never said it killed the run: $(cat "$sb/forget.out")"; _forget_unset; return 1; }
  python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); sys.exit(0 if "alice" not in a and a["bob"]["managed"] else 1)' "$sb/db/accounts.json" \
    || { WHY="accounts.json still holds alice (or lost bob)"; _forget_unset; return 1; }
  [ "$(_tp bob/base-sync)" = "$bpid" ] && _forget_task_running "$bpid" \
    || { WHY="forget stopped or replaced bob's task too"; _forget_unset; return 1; }
  SECS=$(since "$t0")
  _forget_unset
  WHAT="删号时该登录有个挂住的任务（不理 TERM）：account forget 对它的进程组 TERM 再 KILL，父子退出、别的账号任务不停，删号照样完成"
}
_forget_unset() {
  unset FLEET_NODE_STATE FLEET_NODE_LOG FLEET_NODE_RUNTIME FLEET_NODE_DAEMON_DIR FLEET_NODE_USERS FLEET_NODE_TABLE \
    FLEET_NODE_TICK FLEET_NODE_LAUNCHCTL FLEET_NODE_TEST FLEET_NODE_PASSWD FLEET_NODE_RELEASE_WAIT FLEET_NODE_FORGET_KILL_WAIT
}

# account-release-gone-login (#2924): `account release` of a login already
# deleted put its node agent's LaunchDaemon back and loaded it — a daemon for a
# user that is not there, exiting 1 forever (drill10092257 on mac-c). Now a
# release of a login not on the machine loads nothing and only forgets it.
drill_account_release_gone_login() {
  CAP=10
  local sb dd t0
  sb="$WORK/relgone"; dd="$sb/LaunchDaemons"; mkdir -p "$dd" "$sb/lc/loaded" "$sb/Users/alice"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  cat > "$sb/launchctl" <<'LC'
#!/bin/bash
d="$FAKE_LC"; echo "$*" >> "$d/log"
case "$1" in
  bootout) rm -f "$d/loaded/${2##*/}" ;;
  bootstrap) touch "$d/loaded/$(basename "$3" .plist)" ;;
  print) [ -e "$d/loaded/${2##*/}" ] ;;
esac
LC
  chmod +x "$sb/launchctl"
  python3 -c 'import plistlib, sys; plistlib.dump({"Label": "com.claude-fleet.alice.collect", "ProgramArguments": ["/bin/true"]}, open(sys.argv[1], "wb"))' \
    "$dd/com.claude-fleet.alice.collect.plist"
  : > "$sb/lc/loaded/com.claude-fleet.alice.collect"
  printf '{"account": []}\n' > "$sb/table.json"
  sup() { FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$dd" \
          FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
          FLEET_NODE_LAUNCHCTL="$sb/launchctl" FLEET_NODE_BOOTOUT_WAIT=1 FAKE_LC="$sb/lc" python3 "$BIN/fleet-node-supervisor.py" "$@"; }
  sup account adopt alice >/dev/null 2>&1 || { WHY="adopt failed"; return 1; }
  printf '{}\n' > "$sb/passwd.json"      # the login is deleted
  t0=$(now)
  sup account release alice >"$sb/rel.out" 2>&1 || { WHY="release of a gone login failed: $(cat "$sb/rel.out")"; return 1; }
  [ ! -e "$dd/com.claude-fleet.alice.collect.plist" ] && [ ! -e "$sb/lc/loaded/com.claude-fleet.alice.collect" ] \
    || { WHY="release put a gone login's service back and loaded it"; return 1; }
  grep -q '"alice"' "$sb/db/accounts.json" && { WHY="release left the gone login in accounts.json"; return 1; }
  SECS=$(since "$t0")
  WHAT="对已删掉的登录 account release：不装回、不加载任何 plist，只把它从 accounts.json 摘掉"
}

# tenant-admin-adopted (#2842): what a session may destroy is its login's ability,
# so a taken-over login that can sudo is the whole guarantee gone. adopt refuses an
# admin (5, nothing moved); a tenant that LATER joins admin reads FAIL on the
# doctor's row, and PASS again once it is out.
drill_tenant_admin_adopted() {
  CAP=10
  local sb t0 rc
  sb="$WORK/tenant-admin"; mkdir -p "$sb/LaunchDaemons" "$sb/db/logins" "$sb/Users/alice" "$sb/Users/bob/Library/LaunchAgents"
  python3 -c 'import plistlib, sys; plistlib.dump({"Label": "com.claude-fleet.cleanup", "ProgramArguments": ["/bin/true"]}, open(sys.argv[1], "wb"))' \
    "$sb/Users/bob/Library/LaunchAgents/com.claude-fleet.cleanup.plist"
  pw() { printf '{"alice": {"uid": %s, "gid": %s, "home": "%s", "groups": [%s]}, "bob": {"uid": %s, "gid": %s, "home": "%s", "groups": ["staff", "admin"], "sudo": "(ALL) NOPASSWD: ALL"}}\n' \
         "$(id -u)" "$(id -g)" "$sb/Users/alice" "$1" "$(id -u)" "$(id -g)" "$sb/Users/bob" > "$sb/passwd.json"; }
  sup() { FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
          FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" FLEET_NODE_LAUNCHCTL='' \
          python3 "$BIN/fleet-node-supervisor.py" "$@"; }
  grep -q 'tenants --check' "$BIN/fleet-doctor.sh" && grep -q 'fail tenants' "$BIN/fleet-doctor.sh" \
    || { WHY="fleet-doctor.sh has no tenants row"; return 1; }
  t0=$(now)
  pw '"staff"'
  sup account adopt bob >"$sb/adopt.out" 2>&1; rc=$?
  [ "$rc" = 5 ] || { WHY="adopt of an admin login exited $rc, not 5: $(head -c 200 "$sb/adopt.out")"; return 1; }
  [ -e "$sb/Users/bob/Library/LaunchAgents/com.claude-fleet.cleanup.plist" ] || { WHY="a refused adopt moved bob's service"; return 1; }
  : > "$sb/db/logins/alice.env"
  sup tenants --check >/dev/null 2>&1 || { WHY="a clean tenant does not PASS"; return 1; }
  pw '"staff", "admin"'
  sup tenants --check >"$sb/fail.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && grep -q 'alice: admin' "$sb/fail.out" || { WHY="a tenant in the admin group reads rc $rc: $(head -c 200 "$sb/fail.out")"; return 1; }
  pw '"staff"'
  sup tenants --check >/dev/null 2>&1 || { WHY="still FAIL once alice left the admin group"; return 1; }
  SECS=$(since "$t0")
  WHAT="接管管理员登录被拒（退 5、什么没挪）；已接管的登录进了 admin 组 → tenants FAIL 写明是谁，撤出后回到 PASS"
}

# account-adopt-agent-left (#2387): adopt moved a login's fleet services but not
# its own node agent — the machine's one node program waited forever for
# logins/<login>.env and every login kept its old com.ccquota.agent.<login>.
drill_account_adopt_agent_left() {
  CAP=10
  local sb la dd conf t0 envf out
  sb="$WORK/acctag"; la="$sb/Users/alice/Library/LaunchAgents"; dd="$sb/LaunchDaemons"
  conf="$sb/Users/alice/.config/claude-fleet"
  mkdir -p "$la" "$sb/lc/loaded" "$sb/lc/stuck" "$dd" "$conf"
  printf '{"alice": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  cat > "$sb/launchctl" <<'LC'
#!/bin/bash
d="$FAKE_LC"; echo "$*" >> "$d/log"
case "$1" in
  bootout) l="${2##*/}"; [ -e "$d/stuck/$l" ] && exit 5; rm -f "$d/loaded/$l" ;;
  bootstrap) touch "$d/loaded/$(basename "$3" .plist)" ;;
  print) [ -e "$d/loaded/${2##*/}" ] ;;
esac
LC
  chmod +x "$sb/launchctl"
  python3 -c 'import plistlib, sys; plistlib.dump({"Label": "com.claude-fleet.dispatch", "ProgramArguments": ["/bin/true"]}, open(sys.argv[1], "wb"))' \
    "$la/com.claude-fleet.dispatch.plist"
  python3 -c 'import plistlib, sys; plistlib.dump({"Label": "com.ccquota.agent.alice", "ProgramArguments": ["/bin/true"],
    "EnvironmentVariables": {"CCQUOTA_HUB_URL": "https://hub.invalid", "CCQUOTA_FLEET": "1", "FLEET_CONF_DIR": sys.argv[2], "PATH": "/usr/bin"}},
    open(sys.argv[1], "wb"))' "$dd/com.ccquota.agent.alice.plist" "$conf"
  printf 'CCQUOTA_HUB_URL=https://hub.invalid\nCCQUOTA_TOKEN=drill-secret-alice\n' > "$conf/node.env"; chmod 600 "$conf/node.env"
  : > "$sb/lc/loaded/com.claude-fleet.dispatch"; : > "$sb/lc/loaded/com.ccquota.agent.alice"
  : > "$sb/lc/stuck/com.ccquota.agent.alice"
  printf '{"account": []}\n' > "$sb/table.json"
  envf="$sb/db/logins/alice.env"
  sup() { FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$dd" \
          FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$sb/passwd.json" \
          FLEET_NODE_LAUNCHCTL="$sb/launchctl" FLEET_NODE_BOOTOUT_WAIT=1 FAKE_LC="$sb/lc" FLEET_CREDSEP_ROOT_BASE="$sb/cred" \
          python3 "$BIN/fleet-node-supervisor.py" "$@"; }
  t0=$(now)
  # 1. the old agent will not unload: nothing half done, no env for the machine's agent
  sup account adopt alice >"$sb/adopt.out" 2>&1 && { WHY="adopt succeeded past an agent that did not unload"; return 1; }
  [ ! -e "$envf" ] || { WHY="a failed adopt left logins/alice.env — two agents would speak for alice"; return 1; }
  [ -f "$dd/com.ccquota.agent.alice.plist" ] && [ -f "$la/com.claude-fleet.dispatch.plist" ] \
    && [ -e "$sb/lc/loaded/com.claude-fleet.dispatch" ] || { WHY="a failed adopt did not put everything back"; return 1; }
  rm -f "$sb/lc/stuck/com.ccquota.agent.alice"
  # 2. adopt: the env for the machine's agent, the old agent in the attic, no token printed
  out=$(sup account adopt alice 2>&1) || { WHY="adopt failed once the agent unloads: $out"; return 1; }
  case "$out" in *drill-secret*) WHY="adopt printed the token"; return 1 ;; esac
  [ -f "$envf" ] && [ "$(ls -l "$envf" | cut -c1-10)" = "-rw-------" ] || { WHY="no logins/alice.env, or not 0600"; return 1; }
  grep -qx 'CCQUOTA_TOKEN=drill-secret-alice' "$envf" && grep -q '^FLEET_CONF_DIR=' "$envf" \
    || { WHY="logins/alice.env lacks the token or FLEET_CONF_DIR"; return 1; }
  [ ! -e "$dd/com.ccquota.agent.alice.plist" ] && [ ! -e "$sb/lc/loaded/com.ccquota.agent.alice" ] \
    || { WHY="the old agent still runs beside the machine's node program"; return 1; }
  # 3. release: the env goes, the old agent comes back loaded
  sup account release alice >/dev/null 2>&1 || { WHY="release failed"; return 1; }
  [ ! -e "$envf" ] || { WHY="release left logins/alice.env"; return 1; }
  [ -f "$dd/com.ccquota.agent.alice.plist" ] && [ -e "$sb/lc/loaded/com.ccquota.agent.alice" ] \
    || { WHY="release did not put the old agent back and loaded"; return 1; }
  SECS=$(since "$t0")
  WHAT="adopt 连账号自己的节点程序一起迁：旧 agent 卸不掉就全部放回、不写 logins/alice.env；卸得掉则写 600 的 env（含令牌、不打印）、旧 agent 进 attic；release 删 env、放回旧 agent"
}

drill_account_op_reload_cut() {
  CAP=12   # a 2 s "create" held through, then the restart on the next tick
  local sb lg na t0 pid1 pid2 st
  sb="$WORK/opcut"; lg="$sb/db/logins"; mkdir -p "$lg" "$sb/db/agent/erin" "$sb/LaunchDaemons"
  # the default table holds the node agent on its tenants' books — the file the agent writes
  grep -q '"hold": os.path.join(paths.state, "agent", "\*", "account-ops.json")' "$BIN/fleet-node-supervisor.py" \
    || { WHY="the node-agent child has no hold on account-ops.json"; return 1; }
  grep -q 'accountOpsFile = "account-ops.json"' "$BIN/../tokenledger/agent/node_accounts.go" \
    || { WHY="the agent no longer writes account-ops.json"; return 1; }
  printf 'CCQUOTA_TOKEN=x\n' > "$lg/erin.env"
  # the node agent, played: its first run opens "alice" (2 s), marking the op in its
  # book with its own pid, and says done with that pid; a later run just serves
  na="$sb/na.sh"
  cat > "$na" <<'NA'
#!/bin/bash
b="$1/agent/erin/account-ops.json"
[ -e "$1/done" ] && exec sleep 300
printf '{"inflight":{"op-1":{"op":"create","login":"alice","pid":%s}}}\n' "$$" > "$b.tmp" && mv "$b.tmp" "$b"
: > "$1/started"; sleep 2
printf '%s\n' "$$" > "$1/done"
printf '{"outbox":{"op-1":{"type":"account_result","op_id":"op-1"}}}\n' > "$b.tmp" && mv "$b.tmp" "$b"
exec sleep 300
NA
  chmod +x "$na"
  python3 -c 'import json, sys; d = sys.argv[1]; json.dump({"children": [{"name": "node-agent", "cmd": ["/bin/bash", sys.argv[2], d + "/db"],
    "requires": [d + "/db/logins/*.env"], "reload": d + "/db/logins/*.env", "hold": d + "/db/agent/*/account-ops.json"}]}, open(d + "/table.json", "w"))' "$sb" "$na"
  st() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["children"]["node-agent"].get(sys.argv[2]) or "")' "$sb/db/state.json" "$1" 2>/dev/null; }
  FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
    FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 \
    python3 -I "$BIN/fleet-node-supervisor.py" run >"$sb/sup.log" 2>&1 &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  until_ok 10 test -e "$sb/db/started" || { WHY="the node agent never started its op: $(tail -2 "$sb/sup.log" | tr '\n' ' ')"; return 1; }
  pid1=$(st pid)
  # the create writes the new login's .env half way through
  printf 'CCQUOTA_TOKEN=y\n' > "$lg/alice.env"; t0=$(now)
  until_ok 10 test -e "$sb/db/done" || { WHY="the op never finished"; return 1; }
  [ "$(cat "$sb/db/done")" = "$pid1" ] || { WHY="the op was cut off: the node agent (pid $pid1) was restarted mid-create — $(grep node-agent "$sb/sup.log" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -q 'held while account create alice' "$sb/sup.log" || { WHY="no held line in the supervisor log"; return 1; }
  moved() { local p; p=$(st pid); [ -n "$p" ] && [ "$p" != "$pid1" ]; }
  until_ok 5 moved
  pid2=$(st pid)
  [ -n "$pid2" ] && [ "$pid2" != "$pid1" ] || { WHY="the op ended and the node agent kept its old tenants"; return 1; }
  SECS=$(since "$t0")
  kill "$pid2" 2>/dev/null
  WHAT="开号写下 logins/alice.env 时节点程序正在跑这次开号：守护记一行 held、等操作结束（同一 pid 报完结果）才重启换租户；节点程序重启后按账本补答、入口按同一 op_id 再问由 go test（TestAdminAgentAnswersAnOpCutOffByARestart、TestFleetFirstSignInProvisionsAutoAssigned）钉住"
}

drill_node_agent_adopted_no_reload() {
  CAP=10   # the second daemon's adopt + the next tick's reload (stop + start)
  local sb lg sup1 sup2 pid1 pid2 t0 st
  sb="$WORK/adoptreload"; lg="$sb/db/logins"; mkdir -p "$lg" "$sb/LaunchDaemons"
  printf 'CCQUOTA_TOKEN=x\n' > "$lg/erin.env"
  # a plain argv: adopt matches the live process's command line to the one recorded
  python3 -c 'import json, sys; d = sys.argv[1]; json.dump({"children": [{"name": "node-agent", "cmd": ["/bin/sleep", "300"],
    "requires": [d + "/db/logins/*.env"], "reload": d + "/db/logins/*.env"}]}, open(d + "/table.json", "w"))' "$sb"
  st() { python3 -c 'import json, sys; s = json.load(open(sys.argv[1])); print(eval(sys.argv[2]) or "")' "$sb/db/state.json" "$1" 2>/dev/null; }
  run() {
    FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/rt" FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" \
      FLEET_NODE_USERS="$sb/Users" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_TICK=0.2 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_TEST=1 \
      exec python3 -I "$BIN/fleet-node-supervisor.py" run >>"$sb/sup.log" 2>&1
  }
  run & sup1=$!; printf '%s\n' "$sup1" >> "$WORK/cred-pids"
  until_ok 10 sh -c '[ -n "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"children\"][\"node-agent\"].get(\"pid\") or \"\")" "$1" 2>/dev/null)" ]' _ "$sb/db/state.json" \
    || { WHY="the node agent never started: $(tail -2 "$sb/sup.log" | tr '\n' ' ')"; return 1; }
  pid1=$(st 's["children"]["node-agent"]["pid"]')
  # an update restarts the daemon: kill -9, a new one adopts the live node agent
  kill -9 "$sup1"; wait "$sup1" 2>/dev/null
  run & sup2=$!; printf '%s\n' "$sup2" >> "$WORK/cred-pids"
  until_ok 10 grep -q "adopted child node-agent pid $pid1" "$sb/sup.log" \
    || { WHY="the second daemon did not adopt the node agent: $(tail -3 "$sb/sup.log" | tr '\n' ' ')"; return 1; }
  # a login opened that same moment
  printf 'CCQUOTA_TOKEN=y\n' > "$lg/drill.env"; t0=$(now)
  moved() { local p; p=$(st 's["children"]["node-agent"]["pid"]'); [ -n "$p" ] && [ "$p" != "$pid1" ]; }
  until_ok 8 moved || { WHY="the adopted node agent (pid $pid1) was never reloaded on logins/drill.env — $(grep node-agent "$sb/sup.log" | tail -2 | tr '\n' ' ')"; return 1; }
  pid2=$(st 's["children"]["node-agent"]["pid"]')
  SECS=$(since "$t0")
  grep -q 'node-agent.*changed — starting it again' "$sb/sup.log" || { WHY="no reload line in the daemon log"; return 1; }
  until_ok 3 sh -c '! kill -0 "$1" 2>/dev/null' _ "$pid1" || { WHY="the old node agent (pid $pid1) still runs beside the new one"; return 1; }
  kill "$sup2" 2>/dev/null; wait "$sup2" 2>/dev/null; kill "$pid2" 2>/dev/null
  WHAT="守护重启（kill -9 后新守护认领活着的节点程序 pid ${pid1}）同一刻来了新登录 logins/drill.env：下一拍照样比签名、记「changed — starting it again」，旧进程等它退了才起新的（pid ${pid2}）"
}

drill_account_op_rerun_exists() {
  CAP=120; local t0 out rc tests f
  tests='TestCreateArrivingTwiceIsAnsweredFromItsFirstRun TestCreateCutOffHalfWayIsRolledBack TestCreateStillRunningIsWaitedFor TestCreateFailingAfterMakingTheLoginIsRolledBack TestRestartSettlesItsOwnCreateFromTheMark TestCreateOfSomeoneElsesLoginStillExists'
  f="$ROOT/tokenledger/agent/node_accounts_rerun_test.go"
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the agent half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  # the script half: the op's mark is written before step 1 and its result at the end
  grep -q 'FLEET_LOGIN_OP_ID' "$BIN/fleet-login-new.sh" && grep -q "printf 'done=%s" "$BIN/fleet-login-new.sh" \
    || { WHY="fleet-login-new.sh no longer marks the login as its op's (~/<login>-onboard/op)"; return 1; }
  grep -q '"FLEET_LOGIN_OP_ID="+opID' "$ROOT/tokenledger/agent/node_accounts.go" \
    || { WHY="the agent no longer hands the script its op_id"; return 1; }
  t0=$(now)
  WHAT='同一个开号第二次到达（入口再问、重启丢了账本）：脚本留下的 ~/<login>-onboard/op 记着这次 op——跑完了就按它的结果答成功、不再跑脚本、不报「已存在」；还在跑就等；半路停了就收回登录（remove，家目录保留）再报失败；别的 op 的登录照旧「已存在」'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" github.com/verkyyi/claude-fleet/tokenledger/agent 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the agent half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}（go test 六条）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
      *) WHY="the agent half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT="${WHAT}；没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们"
  fi
  SECS=$(since "$t0")
}

drill_node_update_half() {
  CAP=20
  local sb t0 u tk cl out
  sb="$WORK/upd"; mkdir -p "$sb/root" "$sb/rel" "$sb/db" "$sb/Users/alice" "$sb/LaunchDaemons"
  mkdir -p "$sb/bin"; cp "$BIN/fleet-node-update.py" "$BIN/fleet-node-supervisor.py" "$sb/bin/"
  u="$sb/bin/fleet-node-update.py"; tk="$BIN/fleet-node-update-selftest.py"
  python3 "$tk" --fake-ccquota "$sb/ccquota" || { WHY="no fake ccquota"; return 1; }
  V1=$(printf '%040d' 0 | tr 0 1); V2=$(printf '%040d' 0 | tr 0 2); V3=$(printf '%040d' 0 | tr 0 3)
  python3 "$tk" --make-release "$sb/rel" "$V1" '{"claude":"2.1.1"}' \
    && python3 "$tk" --make-release "$sb/rel" "$V2" '{"claude":"2.1.2"}' \
    && python3 "$tk" --make-release "$sb/rel" "$V3" '{"claude":"2.1.3","broken":["claude-"]}' \
    || { WHY="fixtures not built"; return 1; }
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '{"alice":{"uid":%s,"gid":%s,"home":"%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"alice":{"managed":true}}\n' > "$sb/db/accounts.json"
  printf 'CCQUOTA_HUB_URL=https://hub.invalid\n' > "$sb/db/machine.env"; printf 'ed25519 AAAA\n' > "$sb/db/release.pub"
  upd() { env FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/root/current" \
      FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_PASSWD="$sb/passwd.json" \
      FLEET_NODE_TEST=1 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_CCQUOTA="$sb/ccquota" FAKE_REL="$sb/rel" \
      FLEET_NODE_UPDATE_PLATFORM=darwin-arm64 FLEET_NODE_UPDATE_SETTLE=0 FLEET_NODE_UPDATE_LIB=/nonexistent "$@"; }
  # launchd's part: the daemon comes back on whatever `current` names
  daemon() { python3 -c 'import json,os,sys,time; json.dump({"supervisor":{"pid":os.getppid(),"heartbeat":time.time(),"runtime":sys.argv[2]}},open(sys.argv[1],"w"))' "$sb/db/state.json" "$(basename "$(readlink "$sb/root/current")")"; }
  on() { cl=$("$sb/root/current/tools/bin/claude" 2>/dev/null); [ "$(basename "$(readlink "$sb/root/current")")" = "$1" ] && [ "$cl" = "$2 (Claude Code)" ] \
      && [ "$("$sb/Users/alice/.local/bin/claude" 2>/dev/null)" = "$2 (Claude Code)" ] \
      && [ "$(cat "$sb/root/cache/claude/current" 2>/dev/null)" = "$2" ] \
      && [ "$("$sb/root/current/bin/ccquota")" = "ccquota prod-$(printf '%s' "$1" | cut -c1-7)" ]; }
  upd FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" tick >/dev/null && daemon && upd FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" tick >/dev/null
  on "$V1" 2.1.1 || { WHY="v1 never landed whole"; return 1; }
  # 1. killed half way through fetching v2: nothing moved, nothing half
  upd FLEET_NODE_UPDATE_TARGET="$V2" FAKE_SLOW=5 python3 "$u" tick >/dev/null 2>&1 &
  out=$!; until_ok 5 test -d "$sb/root/$V2.partial" || { WHY="the fetch never started"; return 1; }
  pkill -9 -f "$u tick"; pkill -9 -f "$sb/ccquota" 2>/dev/null; wait "$out" 2>/dev/null; t0=$(now)
  ! pgrep -f "$u tick" >/dev/null || { WHY="the tick survived kill -9"; return 1; }
  on "$V1" 2.1.1 || { WHY="a killed fetch left the machine half new"; return 1; }
  # 2. the next tick finishes it, whole
  upd FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" tick >/dev/null && daemon && upd FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" tick >/dev/null
  on "$V2" 2.1.2 || { WHY="the resumed update did not land every part"; return 1; }
  [ ! -e "$sb/root/$V2.partial" ] || { WHY="the cut-short fetch left $V2.partial"; return 1; }
  # 3. v3's Claude Code fails the doctor: every part back to v2, v3 skipped
  upd FLEET_NODE_UPDATE_TARGET="$V3" python3 "$u" tick >/dev/null && daemon
  out=$(upd FLEET_NODE_UPDATE_TARGET="$V3" python3 "$u" tick 2>&1)
  case "$out" in *rolled-back*claude*) ;; *) WHY="no rollback on a new FAIL: $out"; return 1 ;; esac
  on "$V2" 2.1.2 || { WHY="the rollback left a part on v3"; return 1; }
  daemon; out=$(upd FLEET_NODE_UPDATE_TARGET="$V3" python3 "$u" tick 2>&1)
  case "$out" in *skipped*) ;; *) WHY="the rejected release was tried again: $out"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="更新取包时被 kill -9：整台机器原样不动；下一轮从头取完、所有部件一起换上；新版体检多出 FAIL（Claude Code 起不来）→ 运行时、ccquota、Claude、开号缓存、账号链接全部回到上一版，这一版不再重试"
}

# update-goes-back (#4671): a machine only moves forward. The day the Mac lane went in
# (10-13) a Mac was taken back to an older release missing a key fix. Rig: the
# machine runs V2 (seq 5); the target is V1 (seq 4) — a stable rolled back on the hub,
# a stale pin. The tick refuses it (`refused`, one history row), nothing moves, the
# check reds; FLEET_NODE_UPDATE_BACKWARD=1 is the operator's way back.
drill_update_goes_back() {
  CAP=20
  local sb t0 u tk out
  sb="$WORK/back"; mkdir -p "$sb/root" "$sb/rel" "$sb/db" "$sb/Users/alice" "$sb/LaunchDaemons" "$sb/bin"
  cp "$BIN/fleet-node-update.py" "$BIN/fleet-node-supervisor.py" "$sb/bin/"
  u="$sb/bin/fleet-node-update.py"; tk="$BIN/fleet-node-update-selftest.py"
  python3 "$tk" --fake-ccquota "$sb/ccquota" || { WHY="no fake ccquota"; return 1; }
  V1=$(printf '%040d' 0 | tr 0 1); V2=$(printf '%040d' 0 | tr 0 2)
  python3 "$tk" --make-release "$sb/rel" "$V1" '{"seq":4}' \
    && python3 "$tk" --make-release "$sb/rel" "$V2" '{"seq":5}' || { WHY="fixtures not built"; return 1; }
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '{"alice":{"uid":%s,"gid":%s,"home":"%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf '{"alice":{"managed":true}}\n' > "$sb/db/accounts.json"
  printf 'CCQUOTA_HUB_URL=https://hub.invalid\n' > "$sb/db/machine.env"; printf 'ed25519 AAAA\n' > "$sb/db/release.pub"
  upd() { env FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/root/current" \
      FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_PASSWD="$sb/passwd.json" \
      FLEET_NODE_TEST=1 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_CCQUOTA="$sb/ccquota" FAKE_REL="$sb/rel" \
      FLEET_NODE_UPDATE_PLATFORM=darwin-arm64 FLEET_NODE_UPDATE_SETTLE=0 FLEET_NODE_UPDATE_LIB=/nonexistent "$@"; }
  daemon() { python3 -c 'import json,os,sys,time; json.dump({"supervisor":{"pid":os.getppid(),"heartbeat":time.time(),"runtime":sys.argv[2]}},open(sys.argv[1],"w"))' "$sb/db/state.json" "$(basename "$(readlink "$sb/root/current")")"; }
  cur() { basename "$(readlink "$sb/root/current")"; }
  upd FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" tick >/dev/null && daemon && upd FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" tick >/dev/null
  [ "$(cur)" = "$V2" ] || { WHY="V2 never landed"; return 1; }
  t0=$(now)
  out=$(upd FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" tick 2>&1)
  [ "$(cur)" = "$V2" ] || { WHY="the machine went back to the older V1: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1; }
  case "$out" in *refused*'only moves forward'*) ;; *) WHY="the older target was not refused as such: $(printf '%s' "$out" | tail -2 | tr '\n' '|')"; return 1 ;; esac
  upd FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" tick >/dev/null 2>&1
  [ "$(python3 -c 'import json,sys; print(sum(1 for h in json.load(open(sys.argv[1]))["history"] if h["result"] == "refused"))' "$sb/db/update.json")" = 1 ] \
    || { WHY="a refused target was booked more than once"; return 1; }
  upd python3 "$u" status --check >/dev/null 2>&1 && { WHY="status --check is green while the machine refuses its target"; return 1; }
  upd FLEET_NODE_UPDATE_TARGET="$V1" FLEET_NODE_UPDATE_BACKWARD=1 python3 "$u" tick >/dev/null 2>&1
  [ "$(cur)" = "$V1" ] || { WHY="FLEET_NODE_UPDATE_BACKWARD=1 did not take the operator back"; return 1; }
  SECS=$(since "$t0")
  WHAT="目标比正在跑的旧（seq 4 < 5）：拒切、记 refused（历史一行）、status --check 报错，机器留在新版；FLEET_NODE_UPDATE_BACKWARD=1 才退"
}

# user-pod-no-roll-road (#4791): u-3wnuf3v654 ran c48dd07 for days after stable
# moved on — its runtime is the image's (FLEET_NODE_UPDATE_OWNER=image, no update
# task) and its cluster had no provisioner, so the hub's roll-user-pod never
# reached it and every new Codex task stayed `starting`. Nothing said so: the
# machine doctor now does, against the hub's stable.
drill_user_pod_no_roll_road() {
  CAP=20
  local sb t0 u tk out
  sb="$WORK/noroll"; mkdir -p "$sb/root" "$sb/rel" "$sb/db" "$sb/Users/alice" "$sb/LaunchDaemons" "$sb/bin"
  cp "$BIN/fleet-node-update.py" "$BIN/fleet-node-supervisor.py" "$sb/bin/"
  u="$sb/bin/fleet-node-update.py"; tk="$BIN/fleet-node-update-selftest.py"
  python3 "$tk" --fake-ccquota "$sb/ccquota" || { WHY="no fake ccquota"; return 1; }
  V1=$(printf '%040d' 0 | tr 0 1); V2=$(printf '%040d' 0 | tr 0 2)
  python3 "$tk" --make-release "$sb/rel" "$V1" '{"seq":4}' || { WHY="fixtures not built"; return 1; }
  printf '{"children":[],"tasks":[]}\n' > "$sb/table.json"
  printf '{"alice":{"uid":%s,"gid":%s,"home":"%s"}}\n' "$(id -u)" "$(id -g)" "$sb/Users/alice" > "$sb/passwd.json"
  printf 'CCQUOTA_HUB_URL=https://hub.invalid\n' > "$sb/db/machine.env"; printf 'ed25519 AAAA\n' > "$sb/db/release.pub"
  upd() { env FLEET_NODE_STATE="$sb/db" FLEET_NODE_LOG="$sb/log" FLEET_NODE_RUNTIME="$sb/root/current" \
      FLEET_NODE_DAEMON_DIR="$sb/LaunchDaemons" FLEET_NODE_TABLE="$sb/table.json" FLEET_NODE_PASSWD="$sb/passwd.json" \
      FLEET_NODE_TEST=1 FLEET_NODE_LAUNCHCTL='' FLEET_NODE_CCQUOTA="$sb/ccquota" FAKE_REL="$sb/rel" \
      FLEET_NODE_UPDATE_PLATFORM=darwin-arm64 FLEET_NODE_UPDATE_SETTLE=0 FLEET_NODE_UPDATE_LIB=/nonexistent "$@"; }
  upd FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" tick >/dev/null 2>&1
  [ "$(basename "$(readlink "$sb/root/current")")" = "$V1" ] || { WHY="the pod's runtime V1 never landed"; return 1; }
  t0=$(now)
  out=$(upd FLEET_NODE_UPDATE_OWNER=image FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" doctor 2>&1)
  case "$out" in *WARN*image*"${V1:0:12}"*"nothing in this pod updates it"*"${V2:0:12}"*roll-user-pod*image-patch*) ;;
    *) WHY="a pod behind stable with no roll was not said: $(printf '%s' "$out" | grep -E 'image|FAIL' | head -3 | tr '\n' '|')"; return 1 ;; esac
  out=$(upd FLEET_NODE_UPDATE_OWNER=image FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" tick 2>&1)
  case "$out" in *"fleet doctor --machine"*) ;; *) WHY="the image-managed tick does not point at the doctor: $out"; return 1 ;; esac
  out=$(upd FLEET_NODE_UPDATE_OWNER=image FLEET_NODE_UPDATE_TARGET="$V1" python3 "$u" doctor 2>&1)
  case "$out" in *PASS*image*"is the image's and stable"*) ;; *) WHY="a pod on stable was not PASS: $(printf '%s' "$out" | grep image | head -2 | tr '\n' '|')"; return 1 ;; esac
  out=$(upd FLEET_NODE_UPDATE_TARGET="$V2" python3 "$u" doctor 2>&1)
  case "$out" in *" image "*) WHY="a machine whose updater runs grew an image row"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="镜像归属的运行时（个人 pod，没有更新任务）落后 hub 的 stable：机器体检 image 行 WARN，写出两边的版本和滚动的两条路（入口 roll-user-pod / render.py --image-patch + kubectl patch）；在 stable 上 PASS；自己会更新的机器没有这一行"
}

# node-update-stale-fail (#2906): mac-c sat on ee7099a for hours — a torn read
# recorded at 00:17 by an updater that never cleared `failed` after a stage that
# landed; every new release's doctor (the first with a key row) called it a new
# FAIL, rolled back, and skipped that sha until stable moved again.
drill_node_update_stale_fail() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-torn-read 2>&1) \
    || { WHY="a past failure still rolls back / pins the machine: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="一条之后已有签名取包成功的 torn read：体检 key 行 PASS、新版提交不回退；仍是当下的 torn read 只 WARN；被回退的版本原因消失就重试、否则按 6h 起翻倍再试"
}

# codex-helper-missing (#3017): the release carried codex alone, and codex 0.154
# runs every shell command through codex-code-mode-host found beside the path it
# was started from (~/.local/bin) — no session started from the release ran `ls`.
drill_codex_helper_missing() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-helpers 2>&1) \
    || { WHY="codex's helper is not beside it: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="发布版钉的 codex-code-mode-host 装进工具缓存、链在 current/tools/bin 和账号 ~/.local/bin 的 codex 旁；手放的副本换成链接；旧更新器装的版本下一轮补上（有制品就地装，没有再取）"
}

# credsep-stale-after-switch (#2435): the updater moved `current` but credsep's
# root code copy and the shared proxy stayed on the old release.
drill_credsep_stale_after_switch() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-credsep 2>&1) \
    || { WHY="the proxy did not follow the release: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="换版两次再回退一次：每次 credsep 副本的 sha = 发布版，守护的共享代理子进程用新副本重启（pid 换了），回退时副本和代理一起回旧版，不另写 plist"
}

# admin-agent-stale (#3034): the admin login's agent (com.ccquota.agent.<admin>,
# never taken over) ran its own ~/.local/bin/ccquota; the updater moved
# `current` and the managed logins, never it.
drill_admin_agent_stale() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-admin-agent 2>&1) \
    || { WHY="the admin agent did not follow the release: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="管理员登录的 agent：credsep meta.json 的 agent_argv 指向 current/bin/ccquota，换版、回退各重启一次（同一版不重复）；托管登录不动；手放回旧二进制 → 体检 admin-agent WARN，下一轮再指回、重启"
}

# admin-agent-gui-converted (#3508): a Mac's admin agent had started life as
# a LaunchAgent; credsep made it LaunchDaemon com.ccquota.agent.<admin> but kept
# `launchd-gui` in meta.json (for release), and the updater read only that kind.
drill_admin_agent_gui_converted() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-admin-agent-gui 2>&1) \
    || { WHY="a converted LaunchAgent admin is not followed: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="meta.json 说 launchd-gui、LaunchDaemons 里有 com.ccquota.agent.<login>：更新器把 agent_argv 指向 <root>/agent/ccquota、kickstart system/com.ccquota.agent.<login>，meta 的 agent 原样留给 release；没有那个 LaunchDaemon 则不动"
}

# codesign-identity-switch (#3433): ccquota was ad-hoc signed and run from
# <sha>/bin/ccquota, so every version switch gave the admin agent a new identity
# and a new path — the Full Disk Access a person granted lapsed, and account ops
# met a prompt / eDSPermissionError / hang. On macOS the drill runs the updater's
# T_Codesign for real (a sandbox keychain, real codesign): one identity, signed
# at stage, refused when the signature does not check, the same path and the same
# requirement after a switch. Elsewhere signing is off by design — the drill
# checks it says so and that the agent half's test is there.
drill_codesign_identity_switch() {
  CAP=60
  local t0 out f
  t0=$(now)
  f="$ROOT/tokenledger/agent/node_accounts_test.go"
  grep -q '"darwin granted"' "$f" 2>/dev/null \
    || { WHY="the agent half (a granted agent runs the script undisclaimed) has no case in ${f#$ROOT/}"; return 1; }
  if [ "$(uname -s)" = Darwin ] && [ -x /usr/bin/codesign ] && [ -x /usr/bin/security ] && [ -x /usr/bin/openssl ]; then
    out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-codesign 2>&1) \
      || { WHY="the identity did not survive the switch: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
    case "$out" in *skipped*) WHY="T_Codesign skipped on a Mac with the tools: $out"; return 1 ;; esac
    WHAT="一个机器身份（本机钥匙串，只生成一次）：暂存时签 ccquota、签不上就拒暂存；换版后 <root>/agent/ccquota 路径不变、换版前记下的指定要求仍满足（TCC 授权照旧有效）；旧版暂存的 current 下一轮补签"
  else
    out=$(FLEET_NODE_STATE="$WORK/cs-db" python3 -I "$BIN/fleet_node_codesign.py" status 2>&1)
    case "$out" in *'codesign: off'*) ;; *) WHY="off macOS signing is not off: $out"; return 1 ;; esac
    WHAT="非 macOS：签名关着（status 说 off），什么都不签；节点程序那半的用例在（授权了就不绕开）"
  fi
  SECS=$(since "$t0")
}

# runtime-gc-admin-tree (#3248): mac-d's admin frank (never taken over) had a
# ~/.claude/fleet linked into <root>/fc6b100…; the updater only counted managed
# logins' trees, pruned fc6b100, and the admin agent's fork/exec of
# bin/fleet-login-new.sh failed — no login opened, none removed. Now any login's
# ~/.claude/fleet is one link to <root>/current (#4669) and moves with the machine;
# a link whose target is gone FAILs the machine doctor's login-tree row.
drill_runtime_gc_admin_tree() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-admin-tree 2>&1) \
    || { WHY="an admin's linked tree lost its release: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="非托管管理员的 ~/.claude/fleet 直链 <root>/current：随整机换版一起动；链接指向的东西没了 → 机器体检 login-tree FAIL；登录自己的副本不动"
}

# ---- release-fetch-slow (#2701): a new managed machine's release fetch at ~1 MB/s.
# Before: ccquota's 10-minute whole-body deadline cut a 700 MB fetch (every artifact
# the hub carries, every platform and old version), dest.partial was deleted and
# the next try began at zero, after an hour's backoff. Now: only release.json's
# pins for this machine, each artifact resumed from <root>/.fetch, cut only after
# 30 s without a byte, no backoff when the fetch moved. The updater half is its
# Python case (L_ResumableFetch); the ccquota half its Go tests, run where a
# toolchain is.
drill_release_fetch_slow() {
  CAP=120; local t0 out rc tests f
  tests='TestFetchResumesAfterStall TestFetchResumesAcrossRuns TestFetchPinnedOnly TestFetchCachedNotRefetched TestFetchSlowButSteady'
  f="$ROOT/tokenledger/shared/release/fetch_test.go"
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the ccquota half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-fetch 2>&1) \
    || { WHY="the updater half: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  WHAT='更新器：只取本机钉住的制品、缓存先填已有的、断了不退避下一轮接着取'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" github.com/verkyyi/claude-fleet/tokenledger/shared/release 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the ccquota half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}；ccquota：静默 30 秒才断、同一次和下一次都从断点续传、慢而不停不超时、已缓存不重下（go test 五条）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="${WHAT}；ccquota 的 Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
      *) WHY="the ccquota half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT="${WHAT}；没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们"
  fi
  SECS=$(since "$t0")
}

drill_node_install_half() {
  CAP=30
  # its own subshell: the sandbox exports FLEET_NODE_* for every step it drives
  (
    TMPDIR="$WORK" FNI_LIB=1 . "$BIN/fleet-node-install-selftest.sh"
    sandbox
    res() { printf '%s\n%s\n%s\n' "${1:-}" "${2:-}" "${3:-}" > "$WORK/fni.res"; exit 0; }
    # 1. killed while the runtime is being fetched (a slow hub)
    FAKE_SLOW=5 bash "$INST" --hub https://hub.test --join "$CODE1" >/dev/null 2>&1 &
    p=$!
    until_ok 10 test -d "$SB/root/$V1.partial" || res "" "the fetch never started"
    pkill -9 -f "$INST" 2>/dev/null; pkill -9 -f "$BIN/fleet-node-update.py tick" 2>/dev/null
    pkill -9 -f "$SB/db/bin/ccquota" 2>/dev/null; wait "$p" 2>/dev/null
    t0=$(now)
    [ ! -e "$SB/root/current" ] || res "" "a killed install left a current"
    # 2. the same command, no code (the token is already the machine's): converged
    run
    [ "$RC" = 0 ] && line 已收敛 || res "" "the rerun did not converge: $(printf '%s' "$OUT" | grep '^✗' | head -n 1)"
    [ "$(basename "$(readlink "$SB/root/current")")" = "$V1" ] && [ -f "$SB/root/current/.release/staged.json" ] \
      || res "" "the rerun left a half release"
    [ "$(cat "$HUBD/joins")" = 1 ] || res "" "the rerun spent a second join"
    # 3. a part deleted later (the LaunchDaemon): only it comes back
    rm -f "$SB/LaunchDaemons/com.claude-fleet.node.plist" "$SB/loaded"
    run
    [ "$RC" = 0 ] && [ "$(shape)" = "+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -机器钥匙 -角色用户 -ssh -删号通道 +守护 -入口 " ] \
      || res "" "a deleted daemon was not the only thing redone: $(shape)"
    clean || res "" "something half written was left: $(find "$SB" -name '*.partial' -o -name '*.tmp-*' | grep -v /rel/ | head -n 1)"
    res "$(since "$t0")" ""
  )
  { read -r SECS; read -r WHY; } < "$WORK/fni.res"
  WHAT="装到一半（取运行时时）被 kill -9：没有 current、没有半个发布版；同一条命令不带码重跑，从断处做完、不再花加入码；之后删掉守护的服务定义，重跑只补它一件"
}

# linux-join-no-login (#4010): the public §2.2 line joins a Linux machine and
# printed 「已收敛」, but the supervisor held the node program until a
# logins/*.env existed — which only the hub's first create, sent down that very
# program's link, writes: the first login sat pending until it failed. Now the
# program runs with none while FLEET_NODE_ACCOUNT_OPS=1, and the installer's last
# line says what is still missing.
drill_linux_join_no_login() {
  CAP=40
  (
    TMPDIR="$WORK" FNI_LIB=1 . "$BIN/fleet-node-install-selftest.sh"
    sandbox_linux
    res() { printf '%s\n%s\n' "${1:-}" "${2:-}" > "$WORK/fni.res"; exit 0; }
    t0=$(now)
    run --join "$CODE1"
    [ "$RC" = 0 ] || res "" "the install failed: $(printf '%s' "$OUT" | grep '^✗' | head -n 1)"
    ! printf '%s' "$OUT" | grep -q 已收敛 || res "" "no login on the machine and it said 已收敛"
    printf '%s' "$OUT" | grep -q 'fleet hub accounts assign' || res "" "the next step (the hub's first create) was not named"
    python3 - "$BIN/fleet-node-supervisor.py" "$WORK/fni.why" <<'PY' || res "" "the node program still waits for a login: $(cat "$WORK/fni.why" 2>/dev/null)"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("sup", sys.argv[1]); s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)
s.MAC = False
agent = [c for c in s.default_table(s.Paths())["children"] if c["name"] == "node-agent"][0]
miss = s.requires_missing(agent)
if miss:
    open(sys.argv[2], "w").write(", ".join(miss)); sys.exit(1)
PY
    res "$(since "$t0")" ""
  )
  { read -r SECS; read -r WHY; } < "$WORK/fni.res"
  WHAT="Linux 照对外那一行加入、还没有账号：不再说「已收敛」，说出下一步（入口派第一个号）；machine.env 有 FLEET_NODE_ACCOUNT_OPS=1 时守护不再等 logins/*.env，节点程序起来接入口的开号"
}

# linux-relay-not-handed (#4010): sessions on a Linux machine go out through the
# relay, each login's FLEET_CRED_RELAY_URL in root's credsep/<login>.conf — the hub
# handed none down and the join asked for none, so it was written by hand. Now
# /v1/node/desired carries the hub's CCQUOTA_FLEET_CRED_RELAY_URL as
# cred_relay_url, the installer keeps it in expected.json and every login open
# (and the installer's rerun, for the logins already here) writes it.
drill_linux_relay_not_handed() {
  CAP=40
  (
    TMPDIR="$WORK" FNI_LIB=1 . "$BIN/fleet-node-install-selftest.sh"
    sandbox_linux
    res() { printf '%s\n%s\n' "${1:-}" "${2:-}" > "$WORK/fni.res"; exit 0; }
    grep -q 'st.CredRelayURL = s.CredRelayURL' "$BIN/../tokenledger/hub/api/fleet_node_desired.go" \
      || res "" "the hub's /v1/node/desired hands no relay down"
    python3 - "$HUBD/desired.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["cred_relay_url"] = "https://relay.example.com"
json.dump(d, open(sys.argv[1], "w"))
PY
    t0=$(now)
    run --join "$CODE1"
    [ "$RC" = 0 ] || res "" "the install failed: $(printf '%s' "$OUT" | grep '^✗' | head -n 1)"
    grep -q '"cred_relay_url": "https://relay.example.com"' "$SB/db/expected.json" || res "" "expected.json kept no relay"
    out=$(python3 "$BIN/fleet-node-linux-selftest.py" LinuxNode.test_relay_handed_down_by_the_hub 2>&1) \
      || res "" "a login opened here gets no relay: $(printf '%s' "$out" | grep -E 'Error|assert' | head -n 1)"
    res "$(since "$t0")" ""
  )
  { read -r SECS; read -r WHY; } < "$WORK/fni.res"
  WHAT="入口配了 CCQUOTA_FLEET_CRED_RELAY_URL：/v1/node/desired 带 cred_relay_url，装机写进 expected.json，开号（和重跑装机对已有账号）把它写成 FLEET_CRED_RELAY_URL；入口没配就一个字不多（go test TestDesiredCredRelayURL）"
}

# installer-umask-077 (#4010): `sudo` under umask 077 hands it to the installer —
# the runtime and /usr/local/lib/claude-fleet came out 0700, fleetcred could not
# reach the proxy's code and the shared proxy exited every second (rc=2).
drill_installer_umask_077() {
  CAP=40
  (
    TMPDIR="$WORK" FNI_LIB=1 . "$BIN/fleet-node-install-selftest.sh"
    sandbox_linux
    res() { printf '%s\n%s\n' "${1:-}" "${2:-}" > "$WORK/fni.res"; exit 0; }
    t0=$(now)
    OUT="$(umask 077; bash "$INST" --hub https://hub.test --join "$CODE1" 2>&1)"; RC=$?
    [ "$RC" = 0 ] || res "" "the install failed: $(printf '%s' "$OUT" | grep '^✗' | head -n 1)"
    bad=$(umask_free "$SB/root/$V1") || res "" "the runtime under umask 077: $bad"
    lib="$SB/usr/local/lib/claude-fleet"
    mkdir -p "$SB/usr/local/lib"
    bad=$(umask 077; FLEET_CREDSEP_LIB="$lib/credsep" python3 - "$BIN/fleet-credsep.py" <<'PY'
import importlib.util, os, pwd, stat, sys
spec = importlib.util.spec_from_file_location("cs", sys.argv[1]); c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
c.mkdir(c.LIB, 0o755, pwd.getpwuid(os.getuid()).pw_name)
for d in (os.path.dirname(c.LIB), c.LIB):
    m = stat.S_IMODE(os.stat(d).st_mode)
    if m != 0o755:
        print("%o %s" % (m, d)); sys.exit(1)
os.chmod(os.path.dirname(c.LIB), 0o700)      # an earlier install's
c.mkdir(c.LIB, 0o755, pwd.getpwuid(os.getuid()).pw_name)
m = stat.S_IMODE(os.stat(os.path.dirname(c.LIB)).st_mode)
if m & 0o055 != 0o055:
    print("not repaired: %o" % m); sys.exit(1)
PY
) || res "" "the credential proxy's lib under umask 077: $bad"
    res "$(since "$t0")" ""
  )
  { read -r SECS; read -r WHY; } < "$WORK/fni.res"
  WHAT="umask 077 下装机：运行时的目录全是 0755、文件人人可读；凭据代理的 /usr/local/lib/claude-fleet 与 credsep 0755，旧的一次装出的 0700 重跑时补成可进"
}

# node-core-bootstrap-lost (#3810): `fleet node install` re-installs the root core
# under a daemon already on _fleetnode. launchd is still tearing the old core down
# when the bootstrap comes, so it answers EIO (rc 5) — the run used to stop there
# with the new plist in place and NO core loaded: every child of the seated daemon
# waiting on a socket that was gone, and the doctor's node row still PASS. Now the
# step waits the old job out and retries; a unit that never comes up puts the one
# it replaced back and fails the run before the daemon step; a seated daemon whose
# core does not answer is refused by its own install and is status --check 7 —
# the doctor's FAIL.
drill_node_core_bootstrap_lost() {
  CAP=60
  (
    TMPDIR="$WORK" FNI_LIB=1 . "$BIN/fleet-node-install-selftest.sh"
    sandbox
    res() { printf '%s\n%s\n' "${1:-}" "${2:-}" > "$WORK/fncb.res"; [ -n "${LP:-}" ] && kill "$LP" 2>/dev/null; rm -rf "${SD:-}"; exit 0; }
    run --join "$CODE1"
    [ "$RC" = 0 ] || res "" "the sandbox did not converge: $(printf '%s' "$OUT" | grep '^✗' | head -n 1)"
    for f in fleet-node-core.py fleet_node_core.py fleet_ed25519.py fleet-release-verify.py; do cp "$BIN/$f" "$SB/root/current/bin/"; done
    SD="$(mktemp -d /tmp/fncb.XXXXXX)"; export FLEET_NODE_CORE_SOCK="$SD/core.sock" FLEET_NODE_CORE_WAIT=3 FLEET_NODE_BOOTOUT_WAIT=5
    # the core "serving": something listening on its socket while launchd holds it
    python3 -c 'import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
while True: s.accept()[0].close()' "$FLEET_NODE_CORE_SOCK" &
    LP=$!
    until_ok 5 test -S "$FLEET_NODE_CORE_SOCK" || res "" "the stand-in core never listened"
    # launchd: the core's job leaves only a few prints after its bootout, and a
    # bootstrap before then is EIO; core.broken = the NEW unit never starts
    cat > "$SB/fake/launchctl" <<SH
#!/bin/bash
echo "\$*" >> "$SB/launchctl.calls"
case "\$*" in
  *node-core*)
    n=\$(cat "$SB/core.tearing" 2>/dev/null || echo 0)
    case "\$1" in
      bootout) [ -f "$SB/core.loaded" ] && { rm -f "$SB/core.loaded"; echo 3 > "$SB/core.tearing"; } ;;
      print) if [ "\$n" -gt 0 ]; then echo \$((n - 1)) > "$SB/core.tearing"; exit 0; fi; [ -f "$SB/core.loaded" ] ;;
      bootstrap) [ "\$n" -gt 0 ] && exit 5
        [ -f "$SB/core.broken" ] && grep -q "$SB/root/current" "\$3" && exit 5
        touch "$SB/core.loaded" ;;
    esac ;;
  *) case "\$1" in bootstrap) touch "$SB/loaded" ;; bootout) rm -f "$SB/loaded" ;; print) [ -f "$SB/loaded" ] ;; esac ;;
esac
SH
    chmod +x "$SB/fake/launchctl"
    stale() {
      python3 -c 'import plistlib,sys; plistlib.dump({"Label": "com.claude-fleet.node-core", "ProgramArguments": ["/usr/bin/python3", "-I", "/old/runtime/bin/fleet-node-core.py", "serve"]}, open(sys.argv[1], "wb"))' \
        "$SB/LaunchDaemons/com.claude-fleet.node-core.plist"
      touch "$SB/core.loaded"; rm -f "$SB/core.tearing"
    }
    t0=$(now)
    # 1. a core from an older runtime, loaded; the install replaces it while launchd is still tearing it down
    stale
    run
    [ "$RC" = 0 ] && line '✓ 核心' && [ -f "$SB/core.loaded" ] \
      || res "" "a bootstrap during the old core's teardown (EIO) left no core: rc $RC, $(printf '%s' "$OUT" | grep '核心' | head -n 1), loaded=$([ -f "$SB/core.loaded" ] && echo y || echo n)"
    # 2. the new unit never starts: the old one back (bytes and loaded), the run stops before 守护
    stale; before=$(shasum -a 256 < "$SB/LaunchDaemons/com.claude-fleet.node-core.plist"); touch "$SB/core.broken"
    run
    [ "$RC" = 1 ] && line '✗ 核心' && ! printf '%s' "$OUT" | grep -qE '^(✓|跳过|✗) 守护' \
      || res "" "a core that never came up did not stop the run: rc $RC, $(printf '%s' "$OUT" | grep -E '核心|守护' | tr '\n' ' ')"
    [ "$(shasum -a 256 < "$SB/LaunchDaemons/com.claude-fleet.node-core.plist")" = "$before" ] && [ -f "$SB/core.loaded" ] \
      || res "" "the core it replaced was not put back (unit changed or not loaded)"
    # 3. the daemon on its seat, the core gone: its own install refuses, status --check 7
    printf '{"_fleetnode": {"uid": %d, "gid": %d, "home": "/var/empty"}}\n' "$(id -u)" "$(id -g)" > "$SB/passwd.json"
    { kill "$LP"; wait "$LP"; } 2>/dev/null; LP=""; rm -f "$FLEET_NODE_CORE_SOCK" "$SB/core.loaded"
    nbefore=$(shasum -a 256 < "$SB/LaunchDaemons/com.claude-fleet.node.plist")
    out=$(python3 "$SB/root/current/bin/fleet-node-supervisor.py" install 2>&1); rc=$?
    [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'root core does not answer' \
      && [ "$(shasum -a 256 < "$SB/LaunchDaemons/com.claude-fleet.node.plist")" = "$nbefore" ] \
      || res "" "a seated daemon was installed without its core (rc $rc): $out"
    python3 -c 'import json,os,sys,time; json.dump({"supervisor":{"pid":int(sys.argv[2]),"heartbeat":time.time()}},open(sys.argv[1],"w"))' \
      "$SB/db/state.json" "$$"
    out=$(python3 "$SB/root/current/bin/fleet-node-supervisor.py" status --check 2>&1); rc=$?
    [ "$rc" = 7 ] && printf '%s' "$out" | grep -q 'core NOT ANSWERING' \
      || res "" "a seated daemon without its core reads healthy: status --check rc $rc: $out"
    grep -q '^    7) fail node ' "$BIN/fleet-doctor.sh" || res "" "the doctor's node row does not FAIL on status --check 7"
    res "$(since "$t0")" ""
  )
  { read -r SECS; read -r WHY; } < "$WORK/fncb.res"
  WHAT="守护已降到 _fleetnode 时重装根核心：launchd 还在拆旧核心、bootstrap 回 EIO——等旧的走完再重试，装上且 socket 答了才算；新的起不来就放回旧的、不往守护那步走；核心不答时守护自己的 install 拒绝、status --check 7（体检 node 行 FAIL）"
}

# node-core-swept (#3857): a managed machine's core vanished hours after a reboot — the
# hourly leftover sweep (a seated daemon has the core run it) took
# com.claude-fleet.node-core for a machine unit the daemon does not run and booted
# it out: the core died mid-sweep, gone from launchd, its plist left, every child
# waiting on its socket. Now the core's label is the machine's own (never swept,
# never retired), and a daemon that finds it gone says so once and — as root —
# bootstraps it back.
drill_node_core_swept() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-supervisor-selftest.py" \
          O_SweepRemoves.test_the_root_core_is_never_swept O_SweepRemoves.test_a_core_gone_from_launchd_is_put_back 2>&1) \
    || { WHY="the sweep still boots the core out, or a gone core stays gone: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="expected.json 不列 labels 的托管机：每小时的清理不再把 com.claude-fleet.node-core 当多余单元卸掉、也不进 attic；核心不在 launchd 里，守护记一行、root 守护自己 bootstrap 回来，status 写出不答多久了"
}

# node-core-old-code (#3959): bf32f003 → 58c7df7 changed only fleet-node-supervisor.py
# — the sweep the core runs as `sup`, where #3857's fix lives. The core hashed only
# its own file, so it stayed up on the old sweep after the switch, and that sweep
# booted the core out of launchd minutes later (mac-a, 4 h of every account task
# waiting). Now the core hashes every bin/ file it runs and restarts on any change.
drill_node_core_old_code() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-core-selftest.py" \
          G_Switch.test_switch_with_a_changed_sibling_restarts_the_core \
          G_Switch.test_switch_with_the_same_code_keeps_the_core 2>&1) \
    || { WHY="a switch that changed only a sibling left the core on old code: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="切换只改了核心加载的同目录文件（守护的 sweep）：核心回完话就退出、launchd 用新代码拉起；代码没变的切换不重启核心"
}

# core-restart-leaks-loops (#4231): the root core restarts on every switch (#3959)
# and forgot the resident account jobs it ran — each ran on, the next run-as
# started another beside it, stop-as could not stop it, and the seated daemon's
# stray sweep was off. A 15-core managed Mac sat at load 34: eight webhooks of one
# login, four of a login with no session, and every spare login's issue-bridge /
# pr-refresh asking GitHub every 15 s through a stand-in that compiled the
# supervisor's 8k lines each time.
drill_node_versioned_python_script() {
  CAP=15
  local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-node-orphans-selftest.sh" Orphans.test_versioned_python_script_identity 2>&1) \
    || { WHY="versioned Python hid the managed script: $(printf '%s' "$out" | tail -8 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="python3.14、python3.15 和框架 Python 仍取实际脚本；账号孤儿匹配保留精确路径与参数，拒绝 inline payload、别的作业和相似解释器名称"
}

drill_node_restart_shared_orphan() {
  CAP=120
  local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-node-orphans-selftest.sh" 2>&1) \
    || { WHY="daemon restart left a shared lock holder / process group: $(printf '%s' "$out" | tail -8 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="隔离代理持有真实 flock：守护接管 exec 后的进程，根核心收回无账的旧锁，连续三次重启仍一份；组长先退后仍收顽固子进程，参数里提及脚本的活动作业不碰"
}

drill_core_restart_leaks_loops() {
  CAP=120
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-core-selftest.py" \
          C_RunAs.test_a_core_restart_leaves_no_second_copy 2>&1) \
    || { WHY="a killed core's resident job still runs beside the next copy: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-supervisor-selftest.py" \
          V_SessionUnits.test_spare_login_runs_no_github_job 2>&1) \
    || { WHY="a spare login with no session still runs its GitHub loops: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="核心被 kill 后它起的常驻任务还活着：下一个核心的 run-as 先停掉旧的、只留一份，stop-as 也停得掉没人记账的那份；替身 call 只加载线协议不加载守护；没有会话（醒着或睡着）的空闲登录不跑 issue-bridge / pr-refresh，开了会话就跑"
}

# managed-login-install-stale (#2688): the machine moved to a release, a managed
# login's ~/.claude/fleet (what every account task runs) stayed on its old commit
# — its install-sync tick answered `off · managed` and the updater never moved it.
# Since #2774 the updater links it to the runtime and moves it with the machine;
# the login's own tick says so (off · managed · 跟随 <root>/current, no fetch) and
# the machine doctor's install row WARNs until it is linked.
drill_managed_login_install_stale() {
  CAP=60
  local sb seed co c1 c2 t0 out g
  sb="$WORK/mlis"; seed="$sb/seed"; co="$sb/home/.claude/fleet"
  mkdir -p "$sb/home/.claude" "$sb/conf" "$sb/db" "$sb/noderoot" "$sb/tmp"
  : > "$sb/gitconfig"
  g() { GIT_CONFIG_GLOBAL="$sb/gitconfig" GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git "$@"; }
  g init -q --bare -b master "$sb/origin.git" && g clone -q "$sb/origin.git" "$seed" 2>/dev/null \
    || { WHY="no sandbox repo"; return 1; }
  echo 1 > "$seed/f"; g -C "$seed" add -A; g -C "$seed" commit -qm one; c1=$(g -C "$seed" rev-parse HEAD)
  echo 2 > "$seed/f"; g -C "$seed" commit -qam two; c2=$(g -C "$seed" rev-parse HEAD)
  g -C "$seed" push -q origin master && g --git-dir="$sb/origin.git" update-ref refs/tags/stable "$c2"
  g clone -q "$sb/origin.git" "$co" 2>/dev/null && g -C "$co" reset -q --hard "$c1"
  printf '{"%s": {"managed": true}}\n' "$(id -un)" > "$sb/db/accounts.json"
  ln -s "$sb/noderoot/$c2" "$sb/noderoot/current"     # the machine is on c2
  t0=$(now)
  out=$(env -i PATH="$PATH" HOME="$sb/home" FLEET_CONF_DIR="$sb/conf" TMPDIR="$sb/tmp" FLEET_SKIP_GLOBAL_CONF=1 \
        FLEET_NODE_STATE="$sb/db" FLEET_NODE_ROOT="$sb/noderoot" GIT_CONFIG_GLOBAL="$sb/gitconfig" GIT_CONFIG_SYSTEM=/dev/null \
        bash "$BIN/fleet-install-sync.sh" --root "$co" 2>&1) || { WHY="the tick failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; return 1; }
  grep -q "^reason: managed · 跟随 $sb/noderoot/current" "$sb/conf/global/install-sync.state" \
    || { WHY="the managed login's tick does not name what it follows: $(sed -n 's/^reason: //p' "$sb/conf/global/install-sync.state")"; return 1; }
  [ "$(g -C "$co" rev-parse HEAD)" = "$c1" ] || { WHY="the login's own tick moved its copy (the updater's, #2774)"; return 1; }
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-login-install 2>&1) \
    || { WHY="the machine doctor does not name a stale login install: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="整机在新发布版、托管登录的 ~/.claude/fleet 还在旧提交：登录自己的一拍答 off · managed · 跟随 <root>/current（不再自己去取），fleet doctor --machine 的 install 行未链接到发布版时 WARN、链接到位 PASS"
}

# managed-login-install-predates (#2714): the login's own install is older than
# #2688, so its install-sync — the code that would move it — still answers
# `off · managed`. The updater (root, always the release's code) moves it: since
# #4669 by pointing it at <root>/current (`point`) — the switch and the rollback
# then move it with `current` — and every tick at the release puts one back.
drill_managed_login_install_predates() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-login-follow 2>&1) \
    || { WHY="the updater did not move a login install behind the release: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="登录安装早于 #2688（自己的 install-sync 仍答 off · managed）：更新器把每个托管登录的 ~/.claude/fleet 指向 <root>/current（一个链接，不建树），换版 / 退回时随 current 一起动、各跑一次新版 apply（两目录模式），接管时当场做；旧版本目录过保留期后连 fleet.versions 一起删；放手时换回独立副本；钉在版本目录的客户端壳镜像改走登录链接"
}

# managed-login-own-copy (#2774, #4669): a managed login's ~/.claude/fleet pointed
# back by hand at an own old copy (or left on its bootstrap copy) no longer moves
# with the machine. The machine doctor WARNs (never FAIL), and the next update
# tick points it at <root>/current again — unless an EPIC batch with work holds it.
drill_managed_login_own_copy() {
  CAP=60
  local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-login-own-copy 2>&1) \
    || { WHY="a login pointed at an own copy was not linked back: $(printf '%s' "$out" | grep -E 'Error|FAIL' | head -3 | tr '\n' ' ')"; return 1; }
  SECS=$(since "$t0")
  WHAT="托管登录被手动指回一份独立旧副本：fleet doctor --machine 的 install 行 WARN（不 FAIL、不回退整机），下一拍更新器把它重新指向 <root>/current；有活的批次在跑时先等（同 2 小时封顶）；换版时两个登录随 current 一起动、体检 FAIL 一起退回"
}

# managed-login-mod-escapes (#2964, #4669): Claude Code resolves a plugin file's
# real path and refuses one outside --plugin-dir. A managed login's ~/.claude/fleet
# is a link to <root>/current now, so fleet_mod_dir hands Claude the release's
# PHYSICAL mod dir (<root>/<sha>/mod/fleet): every file inside it, and a session
# keeps the one release it started on even after `current` moves.
drill_managed_login_mod_escapes() {
  CAP=30
  local sb rt sha t0 got f
  sb="$WORK/mlme"; sha=$(printf 'c%.0s' $(seq 40)); rt="$sb/root"
  mkdir -p "$rt/$sha/bin" "$rt/$sha/mod/fleet/.claude-plugin" "$rt/$sha/mod/fleet/hooks" "$sb/home/.claude"
  for f in "$BIN"/*; do ln -s "$f" "$rt/$sha/bin/${f##*/}"; done
  echo '{"name":"fleet"}' > "$rt/$sha/mod/fleet/.claude-plugin/plugin.json"
  echo '// mod' > "$rt/$sha/mod/fleet/hooks/register.ts"
  ln -s "$rt/$sha" "$rt/current"; ln -s "$rt/current" "$sb/home/.claude/fleet"
  t0=$(now)
  got=$(env -i PATH="$PATH" HOME="$sb/home" bash -c '. "$1/.claude/fleet/bin/fleet-lib.sh" >/dev/null 2>&1; fleet_mod_dir' _ "$sb/home")     || { WHY="fleet_mod_dir found no mod through the link to current"; return 1; }
  [ "$got" = "$(cd "$rt/$sha" && pwd -P)/mod/fleet" ]     || { WHY="fleet_mod_dir gave $got, not the release's physical mod dir — Claude Code would see its files escape it"; return 1; }
  # every file under it resolves inside it
  while IFS= read -r f; do
    case "$(cd "$(dirname "$f")" && pwd -P)/" in "$got"/*) ;; *) WHY="$f resolves outside $got"; return 1 ;; esac
  done < <(find "$got" -type f -o -type l)
  SECS=$(since "$t0")
  WHAT="托管登录的 ~/.claude/fleet 是指向 <root>/current 的链接：fleet_mod_dir 给 Claude 的是发布版里 mod 的真实目录（<root>/<sha>/mod/fleet），插件文件都在目录内、不报 Path escapes plugin directory，会话一直用它起步时那一版的 mod"
}

# shift-enter-sends (#2760): the current node/view must preserve extended keys.
# Type CSI 13;2u into a real pty attached to an isolated node and read the bytes
# received by a pane asking for keys the same way Claude Code does.
drill_shift_enter_sends() {
  CAP=30; local d t0 got s ROOT REAL_TMUX
  ROOT="$(cd "$BIN/.." && pwd)"; REAL_TMUX=$(command -v tmux 2>/dev/null)
  [ -n "$REAL_TMUX" ] || { WHY="no tmux"; return 1; }
  d=$(mktemp -d /tmp/brk-keys.XXXXXX) || { WHY="mktemp"; return 1; }   # AF_UNIX: a short path
  cat > "$d/rec.py" <<'PY'
import os, sys, tty
tty.setraw(0)
os.write(1, b"\x1b[>4;2m\x1b[>5u\x1b[?2004hREADY\r\n")
with open(sys.argv[1], "ab", buffering=0) as f:
    while True:
        d = os.read(0, 1024)
        if not d:
            break
        f.write(d.hex().encode() + b"\n")
PY
  cat > "$d/term.py" <<'PY'
import fcntl, os, pty, re, select, struct, subprocess, sys, termios, time
tm, d = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(TERM="xterm-256color", HOME=d); os.environ.pop("TMUX", None)
    os.execvp(tm, [tm, "-S", d + "/n", "attach", "-t", "node"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
ANS = ((rb"\x1b\[>0?q", b"\x1bP>|iTerm2 3.6.6\x1b\\"), (rb"\x1b\[>0?c", b"\x1b[>0;95;0c"),
       (rb"\x1b\[0?c", b"\x1b[?62;22c"), (rb"\x1b\[\?996n", b"\x1b[?997;1n"),
       (rb"\x1b\]10;\?", b"\x1b]10;rgb:c0c0/caca/f5f5\x1b\\"), (rb"\x1b\]11;\?", b"\x1b]11;rgb:1a1a/1b1b/2626\x1b\\"))
def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.03)
        if r:
            try: b = os.read(fd, 65536)
            except OSError: return
            for q, a in ANS:
                if re.search(q, b): os.write(fd, a)
for _ in range(150):
    pump(0.1)
    if "READY" in subprocess.run([tm, "-S", d + "/n", "capture-pane", "-p", "-t", "node"], capture_output=True, text=True).stdout:
        break
pump(0.8)
open(d + "/rec.out", "w").close()
os.write(fd, b"\x1b[13;2u")
end = time.time() + 4
while time.time() < end and not os.path.getsize(d + "/rec.out"):
    pump(0.02)
pump(0.3)
print("".join(open(d + "/rec.out").read().split()))
os.kill(pid, 9)
PY
  t0=$(now)
    mkdir -p "$d/conf"
    for s in tmux-attention fleet-palette tmux-bar tmux-node-human tmux-view; do
      sed -e "s#__BIN__#$BIN#g" -e 's#__PREFIX__#C-b#g' -e 's#__STAGE__#kst#g' \
          -e 's#__SESS__#ks#g' -e 's#__PASTE__#0#g' -e '/^set-hook -g /d' -e '/^run-shell /d' \
          "$ROOT/conf/$s.conf" > "$d/conf/$s.conf"
    done
    HOME="$d" "$REAL_TMUX" -S "$d/n" -f "$d/conf/tmux-attention.conf" new-session -d -s node -x 96 -y 24 \
      "python3 $d/rec.py $d/rec.out"
    HOME="$d" "$REAL_TMUX" -S "$d/n" set -t node prefix None
    got=$(python3 "$d/term.py" "$REAL_TMUX" "$d" 2>/dev/null)
    "$REAL_TMUX" -S "$d/n" kill-server 2>/dev/null
    if [ "$got" != 1b5b31333b3275 ]; then
      rm -rf "$d"; WHY="⇧↵ reached the session as [$got] — not ⇧↵ (1b5b31333b3275; 0d = ↵, it sends)"; return 1
    fi
  rm -rf "$d"
  SECS=$(since "$t0"); WHAT="⇧↵ 经当前节点/看台的 tmux 配置到会话仍是 ⇧↵（扩展键）"
}

# spotlight-on (#3402): a managed Mac with a volume indexing and a person's
# CoreSpotlight knowledge agent at 99% for hours (mac-d, 2026-10-11, while every
# volume already read «Indexing disabled»). The doctor's row WARNs on both; one
# `off` (what the machine daemon runs at its start and hourly) turns the volume
# off and disables + boots out the agent, and the row reads PASS again.
drill_spotlight_on() {
  CAP=10
  local sb t0 rc out
  sb="$WORK/spotlight"; mkdir -p "$sb/state" "$sb/bin"; : > "$sb/state/machine.env"
  printf '/ off\n/System/Volumes/Data on\n' > "$sb/vols"
  printf 'frank 07:13:04 99.0 /System/Library/Frameworks/CoreSpotlight.framework/spotlightknowledged\n' > "$sb/ps"
  cat > "$sb/bin/mdutil" <<EOF
#!/bin/bash
case "\$*" in
  "-as") while read -r v st; do echo "\$v:"; [ "\$st" = on ] && printf '\tIndexing enabled.\n' || printf '\tIndexing disabled.\n'; done < "$sb/vols" ;;
  "-a -i off") sed -i.bak 's/ on\$/ off/' "$sb/vols" ;;
esac
EOF
  cat > "$sb/bin/launchctl" <<EOF
#!/bin/bash
case "\$1 \$2" in "bootout gui/501/com.apple.spotlightknowledged") : > "$sb/ps" ;; esac
EOF
  chmod +x "$sb/bin/"*
  spot() { FLEET_NODE_STATE="$sb/state" FLEET_NODE_TEST=1 FLEET_SPOTLIGHT_MDUTIL="$sb/bin/mdutil" \
           FLEET_SPOTLIGHT_LAUNCHCTL="$sb/bin/launchctl" FLEET_SPOTLIGHT_PS="cat $sb/ps" FLEET_SPOTLIGHT_UIDS=501 \
           bash "$BIN/fleet-spotlight.sh" "$@"; }
  grep -q '"fleet-spotlight.sh"), "off", "--tick"' "$BIN/fleet-node-supervisor.py" \
    || { WHY="the machine daemon runs no spotlight task"; return 1; }
  grep -q 'warn spotlight' "$BIN/fleet-doctor.sh" || { WHY="fleet-doctor.sh has no spotlight row"; return 1; }
  out=$(spot status --check); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'indexing on: /System/Volumes/Data' \
    && printf '%s' "$out" | grep -q 'spotlightknowledged(frank) 99.0%' \
    || { WHY="Spotlight on, yet the row is not WARN naming both (rc $rc): $out"; return 1; }
  t0=$(now)
  spot off --tick >/dev/null || { WHY="off --tick failed"; return 1; }
  out=$(spot status --check); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 0 ] || { WHY="after off the row still reads rc $rc: $out"; return 1; }
  WHAT="卷在索引、知识代理 99% 跑了 7 小时：体检 spotlight 行 WARN 写明两处；守护的 off 一次关掉卷索引、停掉代理，行回到 PASS"
}

# wallpaper-aerial (#4362): a headless managed Mac running the Aerial desktop for a
# login (a host Mac mini, 2026-10-15: ~10–15% of a core, nobody looking). The doctor's row
# WARNs; one `off` (the machine daemon's task) sets the static picture as that login
# once, and the row reads PASS. Switched back by hand, a second pass changes nothing.
drill_wallpaper_aerial() {
  CAP=10
  local sb t0 rc out
  sb="$WORK/wallpaper"; mkdir -p "$sb/state" "$sb/bin"; : > "$sb/state/machine.env"; : > "$sb/pic.png"
  printf '501 frank 2-01:00:00 4.3 /x/WallpaperAerialsExtension\n501 frank 2-01:00:00 2.1 /x/VTDecoderXPCService\n' > "$sb/ps"
  # launchctl asuser <uid> sudo -u <login> -H <cmd> …: the osascript call stops the Aerial rows
  cat > "$sb/bin/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$sb/calls"
case "\$7" in osascript) : > "$sb/ps"; echo 1 ;; esac
EOF
  chmod +x "$sb/bin/"*
  wall() { FLEET_NODE_STATE="$sb/state" FLEET_NODE_TEST=1 FLEET_WALLPAPER_LAUNCHCTL="$sb/bin/launchctl" \
           FLEET_WALLPAPER_SUDO=sudo FLEET_WALLPAPER_OSASCRIPT=osascript FLEET_WALLPAPER_DEFAULTS=defaults \
           FLEET_WALLPAPER_PS="cat $sb/ps" FLEET_WALLPAPER_DISPLAYS="echo 0" FLEET_WALLPAPER_IMAGE="$sb/pic.png" \
           bash "$BIN/fleet-wallpaper.sh" "$@"; }
  grep -q '"fleet-wallpaper.sh"), "off", "--tick"' "$BIN/fleet-node-supervisor.py" \
    || { WHY="the machine daemon runs no wallpaper task"; return 1; }
  grep -q 'warn wallpaper' "$BIN/fleet-doctor.sh" || { WHY="fleet-doctor.sh has no wallpaper row"; return 1; }
  out=$(wall status --check); rc=$?
  [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'WallpaperAerialsExtension(frank) 4.3%' \
    || { WHY="Aerial busy with no display, yet the row is not WARN naming it (rc $rc): $out"; return 1; }
  t0=$(now)
  wall off --tick >/dev/null || { WHY="off --tick failed"; return 1; }
  out=$(wall status --check); rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 0 ] || { WHY="after off the row still reads rc $rc: $out"; return 1; }
  [ "$(grep -c osascript "$sb/calls")" = 1 ] || { WHY="the picture was not set exactly once: $(cat "$sb/calls")"; return 1; }
  printf '501 frank 2-01:00:00 4.3 /x/WallpaperAerialsExtension\n' > "$sb/ps"
  wall off --tick >/dev/null
  [ "$(grep -c osascript "$sb/calls")" = 1 ] || { WHY="a login switched back by hand was changed again"; return 1; }
  WHAT="没接显示器、动态桌面占着 CPU：体检 wallpaper 行 WARN；守护的 off 以该登录换成静态图一次，行回到 PASS，人换回后不再改"
}

# ---- per-login-machine-loops (#3546, EPIC #3500 C1): every login on one managed
# machine probed the same machine for itself (memory, load — every capacity read,
# every spawn's admission), and nothing asked whether a new loop was the machine's
# or a login's. Now conf/node-tasks.tsv is that one table (a loop with no row is
# red), the daemon publishes ONE reading every 15 s and a login with
# FLEET_MACHINE_TASKS=off reads it instead of probing.
drill_per_login_machine_loops() {
  CAP=90; local t0
  t0=$(now)
  if ! bash "$BIN/fleet-machine-tasks-selftest.sh" >"$WORK/machine-tasks.out" 2>&1; then
    WHY="a login still probes the machine itself, or a loop has no row: $(grep FAIL "$WORK/machine-tasks.out" | head -3 | tr '\n' ' ')"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="新加的后台循环没在 node-tasks.tsv 登记就报红；标 machine 的模板不按登录跑；整机读数 15 秒一份，FLEET_MACHINE_TASKS=off 的登录直接读它、自己一次也不探，过期、空值或没有就照旧自己探；标 session 的单元只在登录有会话时跑，守护被 kill -9 后认领活着的单元、不再多起一份，孤儿副本被清，未跑完的任务不重复"
}

# ---- webhook-per-login (#4358, EPIC #4354 C4): every login on a managed machine
# ran its own webhook forwarder, all binding one port, an orphaned handler on it.
# bin/fleet-webhook-machine.py is one for every login: routed by login as that
# login, forwards its own children, idle by change, a wake within a tick.
drill_webhook_per_login() {
  CAP=60; local t0
  t0=$(now)
  if ! bash "$BIN/fleet-webhook-machine-selftest.sh" >"$WORK/webhook-machine.out" 2>&1; then
    WHY="the machine's one forwarder broke: $(grep FAIL "$WORK/webhook-machine.out" | head -3 | tr '\n' ' ')"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="两个登录一份程序：各自的转发以各自身份跑、进 /u/<login>；投递只到那个登录、陌生登录 404；转发死了退避重起并补齐；空闲几拍一次重扫都没有、改了配置只重扫那个登录；会话归零就停它的转发；宿主醒来一拍内恢复并强制补齐；TERM 收干净、SIGKILL 留下的转发下次启动按账本收掉；第二份拿不到锁；守护表里登录不再起 webhook 单元（入座 / 关掉时照旧）"
}

# ---- managed-cert-lapses-idle (#4594): a login a managed node took over is the
# ops service's — its connection certificate too — and nothing else uses it, so
# on-use renewal let it run out and, seven idle days later, the device; the cn
# probe then asked the operator to run `fleet login`. Now its diskguard tick
# keeps it (fleet-login.py keep), the drill renews on use, and nothing on such a
# login tells a person to log in.
drill_managed_cert_lapses_idle() {
  CAP=60; local t0
  t0=$(now)
  if ! bash "$BIN/fleet-managed-cert-selftest.sh" >"$WORK/managed-cert.out" 2>&1; then
    WHY="a managed login's certificate lapsed, or someone was asked to log in: $(grep FAIL "$WORK/managed-cert.out" | head -3 | tr '\n' ' ')"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="托管登录证书过期、设备 6 天 23 小时没用：diskguard 一拍用设备钥匙续上（why=keep），入口的设备窗口重新开始；设备已过 7 天时一段失败只报一条运维告警；keep · renew · status · 体检 cert 行没有一句叫人跑 fleet login"
}

# ---- selftest-leftover-overnight (#4360, EPIC #4354 C6): a selftest killed
# before its teardown left its sandbox's processes running for days as PPID=1
# orphans, the dir long removed. The hourly reaper now kills a tree under a test
# root once its maker is gone and it is past the age gate; a run in flight keeps it.
drill_selftest_leftover_overnight() {
  CAP=30; local t0
  t0=$(now)
  if ! bash "$BIN/fleet-selftest-procs-selftest.sh" >"$WORK/selftest-procs.out" 2>&1; then
    WHY="a selftest leftover was not reaped (or a live one was): $(grep FAIL "$WORK/selftest-procs.out" | head -3 | tr '\n' ' ')"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="测试临时根下、造它的进程已不在、过了存活阈值的孤儿树（按参数或 cwd 认，目录删了也认）整树先 TERM 后 KILL；年轻的、造它的进程还在的、不在测试根下的、父进程还活着的都不碰；-n 只数不杀"
}

# ---- svc-run-leaks-across-runs (#4086): service runs (svc:livepage, every
# workspace's) run on a Mac's service login, one login for many tenants — a
# run's files, processes, HOME or key reaching the next run is one workspace
# reading another's. bin/fleet-svc-local.sh gives each attempt a fresh 0700
# directory (HOME · work · out · tmp · key), kills everything carrying its tag
# (a setsid() escape too) and removes the directory; `clean` does the same after
# the agent's SIGKILL.
drill_svc_run_leaks_across_runs() {
  CAP=60; local t0
  t0=$(now)
  if ! bash "$BIN/fleet-svc-local-selftest.sh" >"$WORK/svc-local.out" 2>&1; then
    WHY="a run left something for the next: $(grep FAIL "$WORK/svc-local.out" | head -3 | tr '\n' ' ')"; return 1
  fi
  SECS=$(since "$t0")
  WHAT="同一个服务账号连跑两次：每次一个全新 0700 目录（HOME、work、out、tmp、钥匙都在里面），跑完目录没了、带本次标记的进程（含 setsid 逃出进程组的）全被杀；第二次看不到第一次任何东西；会话环境里没有钥匙、设置禁读钥匙和通行证；被 SIGKILL 的那次由 clean 收尾"
}

# this file runs part 1/6; the rest are its part files (issue #2694)
: "${BREAK_PART:=1/6}"
cred_run_drills "$0"
