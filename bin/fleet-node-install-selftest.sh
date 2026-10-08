#!/bin/bash
# fleet-node-install-selftest.sh — `fleet node install` in a sandbox (issue #2330,
# EPIC #2329 C1): bin/fleet-node-install.sh against a fake hub (a curl that
# answers from a fixture dir), a fake launchctl and sshd, and FLEET_NODE_STATE /
# FLEET_NODE_ROOT under a temp dir. The release fixtures and the fake ccquota
# are bin/fleet-node-update-selftest.py's (--make-release / --fake-ccquota); the
# runtime step runs the real bin/fleet-node-update.py, the daemon step the real
# bin/fleet-node-supervisor.py install. Nothing touches /Library, /var or /etc.
#
#   A  empty → converged in one run: every step ✓, exit 0, every part in place
#   B  the same command again: every step 跳过, no join spent, nothing rewritten
#   C  one part deleted → a rerun redoes only that part (machine.env, release.pub,
#      expected.json, current, the ssh CA key, the LaunchDaemon)
#   D  a step that fails stops there and leaves nothing half written: a bad code,
#      no release key, a release the hub cannot give, a missing role account,
#      `sshd -t` refusing (the old CA key comes back byte for byte); fixed, the
#      same command converges
#   E  piped from curl (no checkout beside it): the updater comes from the signed
#      release itself
#   F  the old roads on a managed machine: `fleet node join` / `fleet host on`
#      point at `fleet node install`; `fleet node install` dispatches here
#
# FNI_BASH=/bin/bash runs the installer under macOS's bash 3.2.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
INST="$BIN/fleet-node-install.sh"
TK="$BIN/fleet-node-update-selftest.py"
PASS=0 FAIL=0
export OUT=""   # the checks' sh -c read it
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d" "${OUT:-}"; fi; }

V1=$(printf '%040d' 0 | tr 0 1)
CODE1=fj_aaaaaaaaaaaaaaaaaaaaaaaaaa
CODE2=fj_bbbbbbbbbbbbbbbbbbbbbbbbbb
KEY="ed25519 Z9pXbb/KZmF68CgH7UjbuVUMjx+/jEFCGsYlEd85ipQ="
CA="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFleetUserCaKeyForTheSelftestOnly000000 fleet-ca"

SB=""
cleanup() { [ -n "$SB" ] && rm -rf "$SB"; }

# sandbox — a fresh machine and a fresh hub
sandbox() {
  cleanup
  SB="$(mktemp -d "${TMPDIR:-/tmp}/fni.XXXXXX")"
  HUBD="$SB/hub"; mkdir -p "$HUBD/dist" "$SB/rel" "$SB/LaunchDaemons" "$SB/ssh" "$SB/fake" "$SB/Users"
  python3 "$TK" --fake-ccquota "$HUBD/dist/darwin-arm64" || exit 1
  python3 "$TK" --make-release "$SB/rel" "$V1" '{"claude":"2.1.1"}' || exit 1
  printf '%s\n' "$CODE1" > "$HUBD/codes"
  printf '%s\n' "$KEY" > "$HUBD/release.key"
  printf '%s\n' "$CA" > "$HUBD/ssh-ca.pub"
  printf '{"endpoint_id":"ep_1","version":2,"release":"%s","components":{},"accounts":[],"spare_accounts":0,"trust":"trusted","trust_source":"join_code","role":"managed"}\n' "$V1" > "$HUBD/desired.json"
  # the fake hub: one curl that answers each path from $HUBD
  cat > "$SB/fake/curl" <<'SH'
#!/bin/bash
out=/dev/stdout w="" hdr="" data="" auth="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;; -w) w=$2; shift ;; -D) hdr=$2; shift ;;
    --data-binary|-d) data=$2; shift ;;
    -H) case "$2" in Authorization:*) auth=${2#*Bearer };; esac; shift ;;
    -X|--max-time|-m) shift ;; -*) ;; *) url=$1 ;;
  esac
  shift
done
[ -f "$HUBD/down" ] && { [ -n "$w" ] && printf '000'; exit 7; }
path="/${url#*://*/}"
echo "$path" >> "$HUBD/calls"
tok=$(cat "$HUBD/token" 2>/dev/null)
code=200 body="" file=""
case "$path" in
  /v1/node/self) [ -n "$tok" ] && [ "$auth" = "$tok" ] && body='{"status":"online"}' || code=401 ;;
  /v1/node/join)
    c=$(sed -n 's/.*"code": *"\([^"]*\)".*/\1/p' "${data#@}")
    if grep -qx "$c" "$HUBD/codes" 2>/dev/null; then
      grep -vx "$c" "$HUBD/codes" > "$HUBD/codes.n"; mv "$HUBD/codes.n" "$HUBD/codes"
      n=$(( $(cat "$HUBD/joins" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$HUBD/joins"
      echo "tok-$n" > "$HUBD/token"
      body='{"endpoint_id":"ep_'$n'","label":"m4-root","token":"tok-'$n'","hub":"x","admin":false,"dist":["darwin-arm64"],"kind":"fixed"}'
    else code=401 body='{"error":"invalid join code"}'; fi ;;
  /v1/node/desired) [ "$auth" = "$tok" ] && file="$HUBD/desired.json" || code=401 ;;
  /v1/fleet/release/key) file="$HUBD/release.key" ;;
  /v1/fleet/ssh-ca.pub) file="$HUBD/ssh-ca.pub" ;;
  /v1/node/dist/*) file="$HUBD/dist/${path##*/}"
    [ -f "$file" ] && [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\nX-Ccquota-Sha256: %s\r\n\r\n' "$(shasum -a 256 "$file" | awk '{print $1}')" > "$hdr" ;;
  *) code=404 ;;
esac
if [ -n "$file" ]; then [ -f "$file" ] && cat "$file" > "$out" || { code=404; : > "$out"; }
else printf '%s' "$body" > "$out"; fi
[ -n "$w" ] && printf '%s' "$code"
exit 0
SH
  # launchd: a plist bootstrapped is loaded until booted out
  cat > "$SB/fake/launchctl" <<SH
#!/bin/bash
echo "\$*" >> "$SB/launchctl.calls"
case "\$1" in
  bootstrap) touch "$SB/loaded" ;; bootout) rm -f "$SB/loaded" ;;
  print) [ -f "$SB/loaded" ] ;;
esac
SH
  # sshd: -t fails while $SB/sshd.bad exists; -T says what the drop-in says
  cat > "$SB/fake/sshd" <<SH
#!/bin/bash
case "\$1" in
  -t) [ ! -f "$SB/sshd.bad" ] || { echo "sshd: bad configuration line 3" >&2; exit 255; } ;;
  -T) awk '\$1 == "TrustedUserCAKeys" { print "trustedusercakeys " \$2 }' "$SB/ssh/sshd_config.d/"*.conf 2>/dev/null ;;
esac
SH
  chmod +x "$SB/fake/"*
  printf '{}\n' > "$SB/passwd.json"
  export HUBD FAKE_REL="$SB/rel" \
    FLEET_NODE_STATE="$SB/db" FLEET_NODE_ROOT="$SB/root" FLEET_NODE_LOG="$SB/log" \
    FLEET_NODE_DAEMON_DIR="$SB/LaunchDaemons" FLEET_NODE_USERS="$SB/Users" FLEET_NODE_PASSWD="$SB/passwd.json" \
    FLEET_NODE_LAUNCHCTL="$SB/fake/launchctl" FLEET_NODE_TEST=1 \
    FLEET_NODE_INSTALL_CURL="$SB/fake/curl" FLEET_NODE_INSTALL_OS=darwin FLEET_NODE_INSTALL_ARCH=arm64 \
    FLEET_NODE_PYTHON="$(command -v python3)" FLEET_NODE_SSH_DIR="$SB/ssh" FLEET_NODE_SSHD="$SB/fake/sshd" \
    FLEET_CREDSEP_ROLE="$(id -un)" \
    FLEET_NODE_UPDATE_PLATFORM=darwin-arm64 FLEET_NODE_UPDATE_SETTLE=0 FLEET_NODE_UPDATE_LIB=/nonexistent
}

run() { OUT="$(${FNI_BASH:-bash} "$INST" --hub https://hub.test "$@" 2>&1)"; RC=$?; }
line() { printf '%s\n' "$OUT" | grep -q "^$1"; }
# every step's line, in order, by its first word (✓ / 跳过 / ✗)
shape() { printf '%s\n' "$OUT" | LC_ALL=C awk '/^(✓|跳过|✗) /{ s = $2; sub(/：.*/, "", s); printf "%s%s ", ($1 == "✓" ? "+" : ($1 == "跳过" ? "-" : "!")), s }'; }
# no half-written file anywhere in the sandbox
clean() { [ -z "$(find "$SB" \( -name '*.tmp-*' -o -name '*.partial' -o -name '.*.tmp*' \) 2>/dev/null | grep -v '/rel/')" ]; }
# the daemon's first tick after the switch: launchd brought it up on `current`
daemon_commits() {
  python3 -c 'import json,os,sys,time; json.dump({"supervisor":{"pid":os.getppid(),"heartbeat":time.time(),"runtime":sys.argv[2]}},open(sys.argv[1],"w"))' \
    "$SB/db/state.json" "$(basename "$(readlink "$SB/root/current")")"
  python3 "$SB/root/current/bin/fleet-node-update.py" tick >/dev/null 2>&1
  python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["result"] != "committed")' "$SB/db/update.json"
}
fp() { (cd "$SB" && find db root ssh LaunchDaemons -type f ! -name 'update.json' ! -name 'state.json' ! -name '*.log' -print0 2>/dev/null \
  | sort -z | xargs -0 shasum -a 256 2>/dev/null); }
mode() { python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

# FNI_LIB=1: only the sandbox and its helpers (the BREAK-IT drill node-install-half)
[ "${FNI_LIB:-}" = 1 ] && return 0
trap cleanup EXIT

echo "A  empty → converged"
sandbox
run --join "$CODE1"
check "exit 0" [ "$RC" = 0 ]
check "every step ✓ (检查 加入 发布公钥 期望状态 ccquota 运行时; 角色用户 already there)" \
  [ "$(shape)" = "+检查 +加入 +发布公钥 +期望状态 +ccquota +运行时 -角色用户 +ssh +守护 " ]
check "says it converged" line "已收敛"
check "machine.env: the hub + the machine's token, root 600" \
  sh -c "grep -qx 'CCQUOTA_TOKEN=tok-1' '$SB/db/machine.env' && grep -qx 'CCQUOTA_HUB_URL=https://hub.test' '$SB/db/machine.env' && [ $(mode "$SB/db/machine.env") = 600 ]"
check "the token is never printed" sh -c "! printf '%s' \"\$OUT\" | grep -q tok-1"
check "release.pub pinned" [ "$(cat "$SB/db/release.pub")" = "$KEY" ]
check "expected.json: the hub's desired state, an empty accounts left out" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["release"] == sys.argv[2] and d["version"] == 2 and "accounts" not in d))' "$SB/db/expected.json" "$V1"
check "current → the release expected.json names, staged whole" \
  sh -c "[ \"\$(basename \"\$(readlink '$SB/root/current')\")\" = $V1 ] && [ -f '$SB/root/current/.release/staged.json' ] && [ -x '$SB/root/current/bin/ccquota' ] && [ -x '$SB/root/current/tools/bin/tmux' ]"
check "the ssh CA + the drop-in the admin agent writes" \
  sh -c "[ \"\$(cat '$SB/ssh/fleet_user_ca.pub')\" = '$CA' ] && grep -qx 'TrustedUserCAKeys $SB/ssh/fleet_user_ca.pub' '$SB/ssh/sshd_config.d/100-fleet-user-ca.conf'"
check "the daemon's LaunchDaemon, bootstrapped" sh -c "[ -f '$SB/LaunchDaemons/com.claude-fleet.node.plist' ] && [ -f '$SB/loaded' ]"
check "logins/ ready for the node program" [ "$(mode "$SB/db/logins")" = 700 ]
check "one join spent" [ "$(cat "$HUBD/joins")" = 1 ]
check "nothing half written" clean
check "the daemon's first tick commits it" daemon_commits

echo "B  the same command again: nothing to do"
before="$(fp)"
calls0=$(grep -c . "$HUBD/calls")
run --join "$CODE2"
check "exit 0" [ "$RC" = 0 ]
check "every step 跳过" [ "$(shape)" = "+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 -ssh -守护 " ]
check "no join spent" sh -c "! sed -n '$((calls0 + 1)),\$p' '$HUBD/calls' | grep -q /v1/node/join"
check "nothing rewritten" [ "$(fp)" = "$before" ]
run
check "without a code too" sh -c "[ $RC = 0 ] && [ \"$(shape)\" = '+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 -ssh -守护 ' ]"

echo "C  one part gone → only that part comes back"
redo() { # <what> <step> <rm…>
  local what="$1" step="$2"; shift 2
  rm -rf "$@"
  run --join "$CODE2"
  local want="+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 -ssh -守护 "
  want="${want/-$step /+$step }"
  OUT="$OUT
(shape: $(shape))"
  check "$what → only $step" sh -c "[ $RC = 0 ] && [ \"$(shape)\" = \"$want\" ]"
}
redo "release.pub" 发布公钥 "$SB/db/release.pub"
redo "expected.json" 期望状态 "$SB/db/expected.json"
redo "the current link" 运行时 "$SB/root/current"
check "  … and current is the same release again" [ "$(basename "$(readlink "$SB/root/current")")" = "$V1" ]
daemon_commits >/dev/null 2>&1
redo "the ssh CA key" ssh "$SB/ssh/fleet_user_ca.pub"
redo "the LaunchDaemon" 守护 "$SB/LaunchDaemons/com.claude-fleet.node.plist"
rm -f "$SB/loaded"; run
check "the daemon unloaded → reloaded" sh -c "[ \"$(shape)\" = '+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 -ssh +守护 ' ] && [ -f '$SB/loaded' ]"
printf '%s\n' "$CODE2" >> "$HUBD/codes"; rm -f "$HUBD/token"
run --join "$CODE2"
check "the hub forgot the token → a new code joins again, nothing else redone" \
  sh -c "[ $RC = 0 ] && [ \"$(shape)\" = '+检查 +加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 -ssh -守护 ' ] && grep -qx CCQUOTA_TOKEN=tok-2 '$SB/db/machine.env'"
rm -f "$HUBD/token"; run
check "… and without a code it says so" sh -c "[ $RC = 1 ] && printf '%s' \"\$OUT\" | grep -q '^✗ 加入：' && printf '%s' \"\$OUT\" | grep -q '重跑：sudo fleet node install --join <码>'"
check "nothing half written" clean

echo "D  a failing step stops there, leaves nothing half written"
sandbox
run --join fj_zzzzzzzzzzzzzzzzzzzzzzzzzz
check "a code the hub does not know: ✗ 加入, exit 1, no machine.env" \
  sh -c "[ $RC = 1 ] && [ \"$(shape)\" = '+检查 !加入 ' ] && [ ! -e '$SB/db/machine.env' ]"
check "the rerun line elides the code" sh -c "printf '%s' \"\$OUT\" | grep -q '重跑：sudo fleet node install --join <码> --hub https://hub.test' && ! printf '%s' \"\$OUT\" | grep -q fj_zzz"
mv "$HUBD/release.key" "$HUBD/release.key.off"
run --join "$CODE1"
check "the hub signs no releases: ✗ 发布公钥, no release.pub" \
  sh -c "[ $RC = 1 ] && [ \"$(shape)\" = '+检查 +加入 !发布公钥 ' ] && [ ! -e '$SB/db/release.pub' ]"
mv "$HUBD/release.key.off" "$HUBD/release.key"
mv "$SB/rel/$V1" "$SB/rel/off"
run
check "the release cannot be fetched: ✗ 运行时, no current, no half release" \
  sh -c "[ $RC = 1 ] && [ \"$(shape)\" = '+检查 -加入 +发布公钥 +期望状态 +ccquota !运行时 ' ] && [ ! -e '$SB/root/current' ] && [ ! -e '$SB/root/$V1' ]"
check "nothing half written" clean
mv "$SB/rel/off" "$SB/rel/$V1"
FLEET_CREDSEP_ROLE=_fleetnosuchrole run
check "no role account and none can be made: ✗ 角色用户" \
  sh -c "[ $RC = 1 ] && [ \"$(shape)\" = '+检查 -加入 -发布公钥 -期望状态 -ccquota +运行时 !角色用户 ' ]"
printf 'ssh-ed25519 AAAAoldkey old\n' > "$SB/ssh/fleet_user_ca.pub"; touch "$SB/sshd.bad"
run
check "sshd -t refuses: ✗ ssh CA, the old key back byte for byte, no drop-in" \
  sh -c "[ $RC = 1 ] && [ \"$(shape)\" = '+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 !ssh ' ] && [ \"\$(cat '$SB/ssh/fleet_user_ca.pub')\" = 'ssh-ed25519 AAAAoldkey old' ] && [ ! -e '$SB/ssh/sshd_config.d/100-fleet-user-ca.conf' ]"
check "no daemon yet" [ ! -e "$SB/LaunchDaemons/com.claude-fleet.node.plist" ]
check "nothing half written" clean
rm -f "$SB/sshd.bad"
run
check "fixed → the same command converges, doing only what was left" \
  sh -c "[ $RC = 0 ] && [ \"$(shape)\" = '+检查 -加入 -发布公钥 -期望状态 -ccquota -运行时 -角色用户 +ssh +守护 ' ]"

echo "E  piped from curl"
sandbox
cp -R "$SB/rel/$V1" "$SB/rel/stable"
OUT="$(cd "$SB" && bash -s -- --hub https://hub.test --join "$CODE1" < "$INST" 2>&1)"; RC=$?
check "converged with no checkout beside the script" sh -c "[ $RC = 0 ] && [ \"$(shape)\" = '+检查 +加入 +发布公钥 +期望状态 +ccquota +运行时 -角色用户 +ssh +守护 ' ]"
check "the updater came from the release (stable fetched first)" grep -qx stable "$SB/rel/.fetched"

echo "F  the old roads on a managed machine"
OUT="$(FLEET_CONF_DIR="$SB/conf" bash "$BIN/fleet-node.sh" join --help 2>&1 >/dev/null)"
check "fleet node join points at fleet node install" sh -c "printf '%s' \"\$OUT\" | grep -q '托管机器.*sudo fleet node install --join'"
rm "$SB/db/machine.env"
OUT="$(FLEET_CONF_DIR="$SB/conf" bash "$BIN/fleet-node.sh" join --help 2>&1 >/dev/null)"
check "… not on an unmanaged one" [ -z "$OUT" ]
grep -q 'managed_hint$' <(sed -n '/^cmd_on() {/,/^}/p' "$BIN/fleet-host.sh")
check "fleet host on says it too" [ $? = 0 ]
OUT="$(bash "$BIN/fleet-node.sh" install --help 2>&1)"
check "fleet node install dispatches to fleet-node-install.sh" sh -c "printf '%s' \"\$OUT\" | grep -q 'make this Mac a MANAGED machine'"

echo
echo "fleet-node-install-selftest: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
