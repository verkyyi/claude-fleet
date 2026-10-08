#!/bin/bash
# fleet-break-it-node-selftest.sh — docs/BREAK-IT.md row `node-supervisor-dead`
# (issue #2331, EPIC #2329 C3): the machine's one daemon dies. Its own file, like
# the cred-shared drill whose runner it sources (BREAK_CRED_LIB=1);
# bin/fleet-break-it-selftest.sh's lockstep lint reads the drill_* names here too.
#
#   node-supervisor-dead  bin/fleet-node-supervisor.py (install's KeepAlive +
#                         ThrottleInterval, run's adopt + state.json, status --check),
#                         bin/fleet-doctor.sh's `node` row
#   account-adopt-stuck   bin/fleet-node-supervisor.py `account adopt|release` (#2332):
#                         one of a login's services will not unload mid-migration
#   node-update-half      bin/fleet-node-update.py (#2334): an update killed half way,
#                         and a release whose new part fails the doctor
#   node-install-half     bin/fleet-node-install.sh (#2330): `fleet node install`
#                         killed half way through, then a part deleted afterwards
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
          FLEET_NODE_LAUNCHCTL="$sb/launchctl" FAKE_LC="$sb/lc" python3 "$BIN/fleet-node-supervisor.py" "$@"; }
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
    [ "$RC" = 0 ] && [ "$(shape)" = "+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 -ssh +守护 " ] \
      || res "" "a deleted daemon was not the only thing redone: $(shape)"
    clean || res "" "something half written was left: $(find "$SB" -name '*.partial' -o -name '*.tmp-*' | grep -v /rel/ | head -n 1)"
    res "$(since "$t0")" ""
  )
  { read -r SECS; read -r WHY; } < "$WORK/fni.res"
  WHAT="装到一半（取运行时时）被 kill -9：没有 current、没有半个发布版；同一条命令不带码重跑，从断处做完、不再花加入码；之后删掉守护的服务定义，重跑只补它一件"
}

cred_run_drills "$0"
