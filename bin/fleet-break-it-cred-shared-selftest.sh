#!/bin/bash
# fleet-break-it-cred-shared-selftest.sh — docs/BREAK-IT.md row `cred-shared-down`
# (issue #2217): the machine's ONE shared credential proxy dies, and every
# login's sessions come back. Split from bin/fleet-break-it-cred-selftest.sh
# (whose helpers it sources, BREAK_CRED_LIB=1) because that run sits at the
# macOS per-test cap; bin/fleet-break-it-selftest.sh's lockstep lint reads the
# drill_cred_* names here too.
#
#   cred-shared-down    bin/fleet-credsep.py machine (the shared service's KeepAlive +
#                       ThrottleInterval), bin/fleet-credsep-launch.py shared,
#                       bin/fleet-cred-proxy.py serve --shared, bin/fleet-cred-proxy.sh mint
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_cred_shared_down() {
  CAP=10   # kill -9 → both logins' sessions answered again: the service's own restart delay + a python start
  local sb me uid gid port ta tb pid1 t0 thr sup
  me=$(id -un); uid=$(id -u); gid=$(id -g); sb="$WORK/shared"
  mkdir -p "$sb/daemons"
  cred_rig shared trusted reachable || return 1
  for L in alpha beta; do
    mkdir -p "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub" "$sb/homes/$L/.claude/fleet/bin"
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat-%s"}}' "$L" > "$sb/homes/$L/.config/claude-fleet/accounts/a1.hub/.credentials.json"
  done
  printf 'alpha:%s:%s:%s\nbeta:1999992:%s:%s\n' "$uid" "$gid" "$sb/homes/alpha" "$gid" "$sb/homes/beta" > "$sb/pw"
  port=$(cred_deadport)
  export FLEET_CREDSEP_ROOT_BASE="$sb/db" FLEET_CREDSEP_RUN_BASE="$sb/run" FLEET_CREDSEP_LOG_BASE="$sb/log" \
    FLEET_CREDSEP_LIB="$sb/lib" FLEET_CREDSEP_DAEMON_DIR="$sb/daemons" FLEET_CREDSEP_ROLE="$me" \
    FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_SUDO='' FLEET_CREDSEP_PW="$sb/pw" \
    FLEET_CRED_SHARED_PORT="$port" FLEET_CRED_ANTHROPIC_URL="$CU/direct-anthropic"
  bash "$BIN/fleet-credsep.sh" machine install --logins alpha,beta >"$sb/install.out" 2>&1 \
    || { WHY="machine install failed: $(tail -2 "$sb/install.out" | tr '\n' ' ')"; return 1; }
  # the restart delay the shipped service carries (launchd ThrottleInterval / systemd RestartSec)
  thr=$(python3 -c 'import plistlib, re, sys
p = sys.argv[1]
try:
    print(plistlib.load(open(p, "rb")).get("ThrottleInterval", 10))
except Exception:
    m = re.search(r"RestartSec=(\d+)", open(p).read()); print(m.group(1) if m else 10)' "$(ls "$sb/daemons"/*cred-proxy-shared* | head -n 1)")
  # launchd / systemd's part, played here: start it, and again $thr s after it dies
  ( while :; do python3 -I "$sb/lib/fleet-credsep-launch.py" shared 2>>"$sb/launch.err"; sleep "$thr"; done ) 2>/dev/null &
  sup=$!; printf '%s\n' "$sup" >> "$WORK/cred-pids"
  until_ok 30 test -S "$sb/run/.shared/ctl.sock" || { WHY="the shared proxy did not start: $(tail -2 "$sb/launch.err" | tr '\n' ' ')"; return 1; }
  until_ok 5 test -s "$sb/run/.shared/pid"; pid1=$(cat "$sb/run/.shared/pid"); CP="$port"
  ta=$(FLEET_CONF_DIR="$sb/homes/alpha/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid sa)
  tb=$(FLEET_CRED_TEST_PEER_UID=1999992 FLEET_CONF_DIR="$sb/homes/beta/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" mint --account a1 --sid sb)
  [ "$(cred_req "$ta" "$sb/ra")" = 200 ] && [ "$(cred_req "$tb" "$sb/rb")" = 200 ] \
    || { WHY="before the kill: $(cat "$sb/ra" "$sb/rb")"; return 1; }
  kill -9 "$pid1"; t0=$(now)
  [ "$(cred_req "$ta" "$sb/ra")" = 000 ] || { WHY="the kill did not take the proxy down"; return 1; }
  until_ok 60 sh -c '[ "$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $1" -d "{}" "http://127.0.0.1:$3/v1/messages")" = 200 ] && [ "$(curl -s -m 5 -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $2" -d "{}" "http://127.0.0.1:$3/v1/messages")" = 200 ]' _ "$ta" "$tb" "$port" \
    || { WHY="the sessions never came back after the kill -9 (pid now: $(cat "$sb/run/.shared/pid" 2>/dev/null))"; return 1; }
  SECS=$(since "$t0")
  [ "$(cat "$sb/run/.shared/pid")" != "$pid1" ] || { WHY="the same pid answers — nothing was killed?"; return 1; }
  kill "$sup" 2>/dev/null; kill "$(cat "$sb/run/.shared/pid" 2>/dev/null)" 2>/dev/null
  unset FLEET_CREDSEP_ROOT_BASE FLEET_CREDSEP_RUN_BASE FLEET_CREDSEP_LOG_BASE FLEET_CREDSEP_LIB FLEET_CREDSEP_DAEMON_DIR \
    FLEET_CREDSEP_ROLE FLEET_CREDSEP_SVC FLEET_CREDSEP_TEST FLEET_CREDSEP_SUDO FLEET_CREDSEP_PW FLEET_CRED_SHARED_PORT
  WHAT="全机共享代理 kill -9：两个登录的会话一起断，服务按自带的 ${thr}s 重启间隔拉起（同一端口 ${port}、各自的钥匙），两边原凭据下一请求都 200"
}

cred_run_drills "$0"
