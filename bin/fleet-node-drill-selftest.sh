#!/bin/bash
# fleet-node-drill-selftest.sh — bin/fleet-node-drill.sh in a sandbox (issue #2336,
# EPIC #2329 C8). The three scripts it drives (fleet-node-install.sh,
# fleet-node-supervisor.py, fleet-node-update.py) are fakes through its seams;
# the daemon dir, /Users, /etc/hosts and the state dir are temp dirs. Nothing
# touches /Library, /var or /etc.
#
#   A  count: services / machine / kinds / github / parts read off the plists,
#      leftovers (.bak, .retired …) not counted, a managed login is one kind
#   B  run --yes: every step PASS, two 人 steps, the report's two tables, exit 0
#   C  the GitHub block is in /etc/hosts DURING the offline step only — the file
#      comes back byte for byte; a leftover block is taken out at the next start
#   D  the join code is never printed, logged or left on disk; --join-file is
#      deleted once read
#   E  a login that will not adopt stops the run (exit 1) with the way back
#   F  the updater rolling back during the UPGRADE wait is a FAIL, not a wait
#   G  usage: no --to / --fail → exit 2
#
# FND_BASH=/bin/bash runs the drill under macOS's bash 3.2.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
DRILL="$BIN/fleet-node-drill.sh"
SH="${FND_BASH:-bash}"
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /'; }

TO=$(printf '%040d' 0 | tr 0 a)
BADSHA=$(printf '%040d' 0 | tr 0 b)
CODE=fj_cccccccccccccccccccccccccc

SB=""
setup() {
  [ -n "$SB" ] && rm -rf "$SB"
  SB="$(mktemp -d "${TMPDIR:-/tmp}/fnd.XXXXXX")"
  mkdir -p "$SB/state" "$SB/root/$TO" "$SB/daemons" "$SB/users/alice/Library/LaunchAgents" \
           "$SB/users/bob/Library/LaunchAgents" "$SB/users/Shared" "$SB/fake"
  local u x
  for u in alice bob; do
    for x in cleanup install-sync spinner; do : >"$SB/daemons/com.claude-fleet.$u.$x.plist"; done
    : >"$SB/daemons/com.ccquota.agent.$u.plist"
  done
  : >"$SB/daemons/com.claude-fleet.bob.webhook.plist"          # bob differs → 2 kinds
  : >"$SB/daemons/com.claude-fleet.alice.cleanup.plist.bak"     # leftovers: never counted
  : >"$SB/daemons/com.claude-fleet.alice.sleep.retired.plist"
  : >"$SB/daemons/com.claude-fleet.cred-proxy-shared.plist"     # machine-level
  : >"$SB/users/alice/Library/LaunchAgents/com.claude-fleet.alice.dispatch.plist"
  printf '127.0.0.1 localhost\n255.255.255.255 broadcasthost\n' >"$SB/hosts"
  cp "$SB/hosts" "$SB/hosts.orig"
  # fake install: converges; offline (hosts blocked) it must not need GitHub
  cat >"$SB/fake/install.sh" <<EOF
#!/bin/bash
case " \$* " in *" --hub https://hub.invalid "*) ;; *) echo "✗ 检查：不知道入口地址"; exit 1 ;; esac
if printf '%s\n' "\$@" | grep -qx -- --join; then
  [ -n "\${FND_INSTALL_ARGS:-}" ] && echo "joined" >>"\$FND_INSTALL_ARGS"
  ln -sfn "$SB/root/$TO" "$SB/root/current"
  echo "✓ 加入 机器令牌已写"; echo "✓ 运行时 $TO"; echo "跳过 角色用户：已在"
else
  grep -q 'fleet-node-drill' "$SB/hosts" && echo "(github blocked)" >>"$SB/offline-seen"
  echo "跳过 加入：令牌入口仍认"; echo "跳过 运行时：已装齐"
fi
EOF
  # fake supervisor: account adopt moves the login's plists away, writes accounts.json
  cat >"$SB/fake/sup.py" <<EOF
import json, os, sys, glob
a = sys.argv[1:]
if a[:2] == ["account", "adopt"]:
    l = a[2]
    if os.environ.get("FND_ADOPT_FAIL") == l:
        print("fleet-node-supervisor: com.claude-fleet.%s.cleanup did not unload — putting back" % l); sys.exit(1)
    for f in glob.glob("$SB/daemons/com.claude-fleet.%s.*.plist" % l) + ["$SB/daemons/com.ccquota.agent.%s.plist" % l] \
            + glob.glob("$SB/users/%s/Library/LaunchAgents/*.plist" % l):
        if os.path.exists(f): os.remove(f)
    p = "$SB/state/accounts.json"
    d = json.load(open(p)) if os.path.exists(p) else {}
    d[l] = {"managed": True}
    json.dump(d, open(p, "w"))
    print("adopted %s: 4 service(s) booted out and kept in the attic" % l)
EOF
  # fake updater: status pops one answer per call off a queue (the last one stays)
  printf 'committed\nrolled-back\n' >"$SB/queue"
  cat >"$SB/fake/upd.py" <<EOF
import json, os, sys
a = sys.argv[1:]
q = "$SB/queue"
if a[:1] == ["status"]:
    lines = open(q).read().split()
    r = lines[0] if lines else ""
    if len(lines) > 1: open(q, "w").write("\n".join(lines[1:]) + "\n")
    if "--json" in a: print(json.dumps({"result": r}))
    else: print("update  %s" % r)
elif a[:1] == ["doctor"]:
    for p in ("runtime", "ccquota", "claude", "codex", "tmux", "cache", "daemon"):
        print("  PASS  %-8s ok" % p)
    print("  INFO  runtime aaaa · claude 2.1 — 各部件 = 发布版声明")
elif a[:1] == ["versions"]:
    print("version  all = release")
EOF
  chmod +x "$SB/fake/install.sh"
  cat >"$SB/fake/fetch.sh" <<EOF
#!/bin/bash
grep -q 'fleet-node-drill' "$SB/hosts" || { echo "not offline"; exit 1; }
mkdir -p "\$2" && echo "fetched \$1"
EOF
  chmod +x "$SB/fake/fetch.sh"
}
envs() {
  export FLEET_NODE_TEST=1 FLEET_NODE_STATE="$SB/state" FLEET_NODE_ROOT="$SB/root" \
    FLEET_NODE_DAEMON_DIR="$SB/daemons" FLEET_NODE_USERS="$SB/users" FLEET_DRILL_HOSTS="$SB/hosts" \
    FLEET_DRILL_INSTALL="$SB/fake/install.sh" FLEET_DRILL_SUPERVISOR="$SB/fake/sup.py" \
    FLEET_DRILL_UPDATE="$SB/fake/upd.py" FLEET_DRILL_FETCH="$SB/fake/fetch.sh" FLEET_DRILL_POLL=0 FLEET_DRILL_WAIT=5 FLEET_HUB_URL=https://hub.invalid
}
drill() { ( envs; "$SH" "$DRILL" "$@" ); }
trap '[ -n "$SB" ] && rm -rf "$SB"' EXIT

echo "A  count"
setup
OUT="$(drill count)"
want="services=11
machine=1
kinds=2
github=2
parts=6
accounts=alice,bob"
[ "$OUT" = "$want" ] && ok "count reads the five numbers (leftovers skipped)" || bad "count" "$OUT"

echo "B  run --yes"
setup
printf '%s\n' "$CODE" >"$SB/join"
OUT="$(drill run --yes --to "$TO" --fail "$BADSHA" --join-file "$SB/join" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "exit $rc" "$OUT"
printf '%s\n' "$OUT" | grep -q '| 回话 | 人 | 0s | SKIP |' && ok "--yes leaves 回话 to a person (SKIP)" || bad "回话 not SKIP under --yes" "$OUT"
for s in 基线 加入码 安装 迁:alice 迁:bob 升级 回退 复查 断GitHub; do
  printf '%s\n' "$OUT" | grep -q "| $s | .* | PASS |" || bad "step $s PASS" "$OUT"
done
ok "every step in the table"
printf '%s\n' "$OUT" | grep -q '要人动手的步骤 | 8 | 2 | ≤ 2 | ✓' && ok "two 人 steps" || bad "人 steps" "$OUT"
printf '%s\n' "$OUT" | grep -q '后台服务 | 11 | 1 | ≤ 3 | ✓' && ok "services 11 → 1" || bad "services" "$OUT"
printf '%s\n' "$OUT" | grep -q '不一致的种类 | 2 | 1 | ≤ 1 | ✓' && ok "kinds 2 → 1" || bad "kinds" "$OUT"
printf '%s\n' "$OUT" | grep -q '连 GitHub 的地方 | 2 | 0 | ≤ 0 | ✓' && ok "github 2 → 0" || bad "github" "$OUT"
printf '%s\n' "$OUT" | grep -q '自动更新的部件 | 6 | 0 | ≤ 0 | ✓' && ok "parts → 0" || bad "parts" "$OUT"
ls "$SB"/state/drill/*/report.md >/dev/null 2>&1 && ok "report.md kept" || bad "report.md"

echo "C  the GitHub block"
[ -f "$SB/offline-seen" ] && ok "blocked during the offline install" || bad "offline step not blocked"
cmp -s "$SB/hosts" "$SB/hosts.orig" && ok "hosts back byte for byte" || bad "hosts changed" "$(cat "$SB/hosts")"
printf '0.0.0.0 github.com # fleet-node-drill github block\n' >>"$SB/hosts"
drill unblock >/dev/null
cmp -s "$SB/hosts" "$SB/hosts.orig" && ok "unblock takes a leftover out" || bad "leftover stays"

echo "D  the join code"
[ ! -e "$SB/join" ] && ok "--join-file deleted" || bad "--join-file left on disk"
if printf '%s\n' "$OUT" | grep -q "$CODE" || grep -rq "$CODE" "$SB/state"; then bad "join code leaked"; else ok "join code nowhere"; fi

echo "E  a login that will not adopt"
setup
OUT="$(FND_ADOPT_FAIL=alice drill run --yes --to "$TO" --fail "$BADSHA" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc" "$OUT"
printf '%s\n' "$OUT" | grep -q '迁:alice .*FAIL.*account release alice' && ok "FAIL + the way back" || bad "no way back" "$OUT"
printf '%s\n' "$OUT" | grep -q '迁:bob' && bad "went on past the failure" "$OUT" || ok "stopped there"

echo "F  a rollback during the upgrade"
setup
printf 'rolled-back\n' >"$SB/queue"
OUT="$(drill run --yes --to "$TO" --fail "$BADSHA" 2>&1)"; rc=$?
printf '%s\n' "$OUT" | grep -q '| 升级 | 自动 | .* | FAIL |' && ok "upgrade FAIL" || bad "upgrade" "$OUT"
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc"

echo "H  an install that fails keeps the join file, reads no 人 count"
setup
printf '%s\n' "$CODE" >"$SB/join"
OUT="$(drill run --yes --hub https://wrong.invalid --to "$TO" --fail "$BADSHA" --join-file "$SB/join" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "exit 1" || bad "exit $rc" "$OUT"
[ -f "$SB/join" ] && ok "join file kept for the rerun" || bad "join file deleted on a failed install"
printf '%s\n' "$OUT" | grep -q '要人动手的步骤 | 8 | - | ≤ 2 | —' && ok "no 人 count off a failed install" || bad "人 count" "$OUT"

echo "G  usage"
setup
drill run --yes --to "$TO" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no --fail → 2" || bad "exit $rc"

echo
echo "fleet-node-drill-selftest: $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
