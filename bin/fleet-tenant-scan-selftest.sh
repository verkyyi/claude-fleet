#!/bin/bash
# fleet-tenant-scan-selftest.sh — the sandbox half of bin/fleet-tenant-scan.sh
# (issue #2298, EPIC #2293 C7): every item, refused AND let through, on a fake
# machine under one temp dir — fake homes / tmux dirs / credential stores /
# LaunchDaemons / bootstrap cache, a real doc-preview server.py and a real
# bin/fleet-cred-scan.py. The real-machine half is the same script run AS a new
# ordinary login (EPIC #2293 convention 5).
#
#   0  a clean machine: all eleven items PASS, the four metrics 0, exit 0; every
#      item names a row that is in docs/BREAK-IT.md (the table ⇔ the doc)
#   1  credsep       not separated → ①
#   2  cred-store    another login's store listable; a token-shaped public file → ①
#   3  cred-scan     a token at accounts/*.hub → ① (and the token never printed)
#   4  forward       root's <login>.conf writable · a pre-#2290 launcher · the drill red → ①
#   5  sudo          sudo -n true · a NOPASSWD rule · the admin group → ②
#   6  root-writes   a root job's log in a home · its program writable · a systemd unit → ②
#   7  homes         another home listable → ③
#   8  tmux          another uid's tmux dir listable → ③
#   9  shared        another login's file in the shared dir readable → ③
#  10  preview       an anonymous http.server → ③ (doc-preview's server.py stays 404;
#                    tailscaled's PeerAPI greeting is named, not counted)
#  11  bootstrap     no Claude Code in the cache → ④; a login cloned from the
#                    network → ④; the retired claude-fleet mirror is not asked
#                    for (#2775); a login linked to the runtime → no hit
#  12  usage         unknown item → exit 2; --json carries the same verdict
#
# Root (whom no chmod refuses) or no python3 → SKIP. TENANT_SCAN_LIB=1 sources
# the sandbox helpers only (bin/fleet-break-it-tenant-selftest.sh's drills).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
SCAN="$BIN/fleet-tenant-scan.sh"
TS_PIDS=''

# ts_build <dir> — a clean fake machine in <dir>; sets TS_PORT (doc-preview's port)
ts_build() {
  local d="$1"
  mkdir -p "$d"/Users/{me,alice,bob,Shared} "$d/Users/me/.config/claude-fleet" "$d/tmp/tmux-99998" "$d/tmp/tmux-12345" \
    "$d/shared/heavy" "$d/shared/sessions" "$d/shared/other" "$d/db/alice" "$d/ro/lib" "$d/ro/log" \
    "$d/ro/cache/claude/1.0.0" "$d/bin" "$d/rw" "$d/daemons" "$d/serve"
  # ① the login's own credsep verdict, root's launcher copy, the #2290 drill
  printf '#!/bin/bash\ncase "$1" in status) echo "separated · %s/db/me · _fleetcred · port 1"; exit 0 ;;\n  check) echo "credsep: OK — fake"; exit 0 ;; esac\nexit 2\n' "$d" > "$d/bin/credsep"
  printf '#!/bin/bash\necho "PASS  cred-upstream-tenant-override   1.0s ≤30s  fake"\n' > "$d/bin/drill"
  printf '#!/bin/bash\ncase "$*" in "-n true") echo "a password is required"; exit 1 ;; "-n -l") echo "a password is required"; exit 1 ;; esac\nexit 1\n' > "$d/bin/sudo"
  chmod +x "$d/bin/credsep" "$d/bin/drill" "$d/bin/sudo"
  printf 'LOGIN_KEYS = re.compile(r"^FLEET_CRED_PROXY_PORT$")\n' > "$d/ro/lib/fleet-credsep-launch.py"
  printf '# proxy\n' > "$d/ro/lib/fleet-cred-proxy.py"
  printf 'FLEET_CRED_ANTHROPIC_URL=https://api.anthropic.com\n' > "$d/ro/lib/uid99998.conf"
  printf '{"mode": "shared", "port": 18923}\n' > "$d/db/.shared.json"
  # ② a root job whose program and log root alone can change; a login's own job
  python3 - "$d" <<'PY'
import os, plistlib, sys
d = sys.argv[1]
os.makedirs(d + "/ro/bin", exist_ok=True)
os.symlink("/usr/bin/true", d + "/ro/bin/py")     # a symlink's own 0777 is not "writable" (ubuntu's /usr/bin/python3)
plistlib.dump({"Label": "com.x.root", "ProgramArguments": [d + "/ro/bin/py", "-I", d + "/ro/lib/fleet-credsep-launch.py",
               "agent", "alice"], "StandardOutPath": d + "/ro/log/a.log", "StandardErrorPath": "/dev/null"},
              open(d + "/daemons/com.x.root.plist", "wb"))
plistlib.dump({"Label": "com.x.alice", "UserName": "alice", "ProgramArguments": ["/bin/sh", "-c",
               "exec '/bin/bash' '%s/Users/alice/.claude/fleet/bin/x.sh'" % d],
               "StandardErrorPath": d + "/Users/alice/x.log"}, open(d + "/daemons/com.x.alice.plist", "wb"))
open(d + "/daemons/x-alice.service", "w").write("[Service]\nUser=alice\nExecStart=%s/Users/alice/run.sh\n" % d)
open(d + "/daemons/x-root.service", "w").write("[Service]\nExecStart=/usr/bin/true\nStandardOutput=append:%s/ro/log/b.log\n" % d)
PY
  # ③ other people's things: closed; the by-design shared rows: open
  printf '39131\talice\tgit-push\t1\n' > "$d/shared/heavy/slot-1"
  printf '0 1791445150\n' > "$d/shared/sessions/alice"
  printf '{"role":"user","content":"secret plan"}\n' > "$d/shared/other/t.jsonl"
  printf 'x\n' > "$d/Users/alice/notes"
  # ④ the Claude Code cache, and this login's checkout cloned from a local repo
  git init -q --bare "$d/ro/cache/claude-fleet.git"
  git init -q "$d/seed" && git -C "$d/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed \
    && git -C "$d/seed" push -q "$d/ro/cache/claude-fleet.git" HEAD:refs/heads/master \
    && git -C "$d/ro/cache/claude-fleet.git" tag stable master
  mkdir -p "$d/Users/me/.claude"
  git clone -q "$d/ro/cache/claude-fleet.git" "$d/Users/me/.claude/fleet"
  printf '1.0.0\n' > "$d/ro/cache/claude/current"
  printf '#!/bin/sh\n' > "$d/ro/cache/claude/1.0.0/claude"
  # the doc-preview server, as a login runs it: nothing without a code
  TS_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  python3 "$ROOT/skills/doc-preview/server.py" "$TS_PORT" "$d/serve" "$ROOT/skills/doc-preview" >"$d/srv.log" 2>&1 &
  TS_PIDS="$TS_PIDS $!"
  local i=0
  until curl -s -o /dev/null "http://127.0.0.1:$TS_PORT/" 2>/dev/null || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
  printf '%s\n' "$TS_PORT" > "$d/ports"
  chmod 000 "$d/Users/alice" "$d/Users/bob" "$d/tmp/tmux-12345" "$d/db/alice" "$d/shared/other/t.jsonl"
  chmod -R a-w "$d/ro"
}

# ts_scan <dir> <args…> — the scan on the fake machine; → OUT, RC
ts_scan() {
  local d="$1"; shift
  OUT=$(cd "$d/Users/me" && env HOME="$d/Users/me" FLEET_CONF_DIR="$d/Users/me/.config/claude-fleet" \
    FLEET_TENANT_SCAN_UID=99998 FLEET_TENANT_SCAN_HOME="$d/Users/me" FLEET_TENANT_SCAN_HOMES="$d/Users" \
    FLEET_TENANT_SCAN_TMUX="$d/tmp/tmux-*" FLEET_TENANT_SCAN_SHARED="$d/shared" FLEET_TENANT_SCAN_DAEMONS="$d/daemons" \
    FLEET_TENANT_SCAN_SUDO="$d/bin/sudo" FLEET_TENANT_SCAN_GROUPS="${TS_GROUPS:-staff everyone}" \
    FLEET_TENANT_SCAN_PORTS="$(cat "$d/ports")" FLEET_TENANT_SCAN_HOSTS=127.0.0.1 \
    FLEET_TENANT_SCAN_FLEET="$d/Users/me/.claude/fleet" FLEET_TENANT_SCAN_CREDSEP="$d/bin/credsep" \
    FLEET_TENANT_SCAN_DRILL="$d/bin/drill" FLEET_TENANT_SCAN_TOP="$d" FLEET_CREDSEP_ROOT_BASE="$d/db" \
    FLEET_CREDSEP_LIB="$d/ro/lib" FLEET_BOOTSTRAP_CACHE="$d/ro/cache" \
    bash "$SCAN" --no-hub "$@" 2>&1); RC=$?
}

# ts_row <item> — that item's table row from OUT
ts_row() { printf '%s\n' "$OUT" | grep -m1 "^| $1 |"; }
# ts_metric <n> — metric n's count from OUT
ts_metric() {
  local c
  case "$1" in 1) c=① ;; 2) c=② ;; 3) c=③ ;; *) c=④ ;; esac
  printf '%s\n' "$OUT" | grep "^$c" | sed 's/.*：//'
}

ts_cleanup() {
  local p
  for p in $TS_PIDS; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
  [ -n "${1:-}" ] && [ -d "$1" ] && { chmod -R u+rwx "$1" 2>/dev/null; rm -rf "$1"; }
}

[ -n "${TENANT_SCAN_LIB:-}" ] && return 0

command -v python3 >/dev/null 2>&1 || { echo "fleet-tenant-scan selftest: python3 absent — SKIP"; exit 0; }
[ "$(id -u)" != 0 ] || { echo "fleet-tenant-scan selftest: running as root, whom chmod 000 does not refuse — SKIP"; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tscan.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'ts_cleanup "$WORK"' EXIT
FAILS=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { FAILS=$((FAILS + 1)); printf 'FAIL  %s\n%s\n' "$1" "$(printf '%s\n' "$OUT" | sed 's/^/      /' | tail -25)"; }
# expect <item> <PASS|HIT> <label>
expect() {
  local r; r=$(ts_row "$1")
  case "$r" in "| $1 | "*" | $2 | "*) ok "$3" ;; *) bad "$3 — wanted $1 $2, got: ${r:-no row}" ;; esac
}
# rw <cmd…> — run with the fake machine's read-only half writable for a moment
rw() { chmod -R u+w "$D/ro"; "$@"; chmod -R a-w "$D/ro"; }

D="$WORK/m"
ts_build "$D"

# ---- 0. a clean machine -------------------------------------------------------
ts_scan "$D" --no-drill
for it in credsep cred-store cred-scan forward sudo root-writes homes tmux shared preview bootstrap; do
  expect "$it" PASS "0: $it refused on a clean machine"
done
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^tenant-scan: PASS' && ok "0: exit 0, verdict PASS" || bad "0: exit $RC, not PASS"
for m in 1 2 3 4; do [ "$(ts_metric $m)" = 0 ] || bad "0: metric $m is not 0"; done
[ "$(printf '%s\n' "$OUT" | grep -c '^| [a-z-]* | [①②③④] |')" = 11 ] && ok "0: eleven rows" || bad "0: not eleven rows"
MISS=''
for r in $(printf '%s\n' "$OUT" | sed -n 's/.*| `\([a-z0-9-]*\)` |$/\1/p' | sort -u); do
  grep -qF -- "| \`$r\` |" "$ROOT/docs/BREAK-IT.md" || MISS="$MISS $r"
done
[ -z "$MISS" ] && ok "0: every item names a docs/BREAK-IT.md row" || bad "0: rows not in docs/BREAK-IT.md:$MISS"
ts_scan "$D" --only forward
expect forward PASS "0: the #2290 drill green → forward PASS"

# ---- 1. credsep -----------------------------------------------------------------
cp "$D/bin/credsep" "$WORK/credsep.ok"
printf '#!/bin/bash\n[ "$1" = status ] && { echo "not separated"; exit 3; }\necho "credsep: INFO — off"\n' > "$D/bin/credsep"
ts_scan "$D" --only credsep
expect credsep HIT "1: not separated → credsep HIT"
[ "$RC" = 1 ] && [ "$(ts_metric 1)" = 1 ] && ok "1: exit 1, ① = 1" || bad "1: exit $RC / ① $(ts_metric 1)"
cp "$WORK/credsep.ok" "$D/bin/credsep"

# ---- 2. cred-store --------------------------------------------------------------
chmod 700 "$D/db/alice"
ts_scan "$D" --only cred-store
expect cred-store HIT "2: another login's store listable → HIT"
chmod 000 "$D/db/alice"
printf '{"token": "sk-ant-oat01-AAAAAAAAAAAAAAAAAAAAAAAAAAAA"}\n' > "$D/db/.shared.json"
ts_scan "$D" --only cred-store
expect cred-store HIT "2: a token-shaped public file → HIT"
printf '%s' "$OUT" | grep -q 'sk-ant-oat01-AAAA' && bad "2: the token was printed" || ok "2: the token is not in the output"
printf '{"mode": "shared"}\n' > "$D/db/.shared.json"

# ---- 3. cred-scan ---------------------------------------------------------------
mkdir -p "$D/Users/me/.config/claude-fleet/accounts/a1.hub"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-BBBBBBBBBBBBBBBBBBBBBBBBBBBB"}}' \
  > "$D/Users/me/.config/claude-fleet/accounts/a1.hub/.credentials.json"
ts_scan "$D" --only cred-scan
expect cred-scan HIT "3: a token at accounts/*.hub → cred-scan HIT"
printf '%s' "$OUT" | grep -q 'sk-ant-oat01-BBBB' && bad "3: the token was printed" || ok "3: the token is not in the output"
rm -rf "$D/Users/me/.config/claude-fleet/accounts"

# ---- 4. forward -----------------------------------------------------------------
chmod u+w "$D/ro/lib/uid99998.conf"
ts_scan "$D" --only forward --no-drill
expect forward HIT "4: root's <login>.conf writable by the login → HIT"
chmod a-w "$D/ro/lib/uid99998.conf"
rw sh -c "printf '# old launcher\n' > '$D/ro/lib/fleet-credsep-launch.py'"
ts_scan "$D" --only forward --no-drill
expect forward HIT "4: a pre-#2290 launcher → HIT"
rw sh -c "printf 'LOGIN_KEYS = 1\n' > '$D/ro/lib/fleet-credsep-launch.py'"
printf '#!/bin/bash\necho "FAIL  cred-upstream-tenant-override the login'"'"'s own listener was asked"; exit 1\n' > "$D/bin/drill"
ts_scan "$D" --only forward
expect forward HIT "4: the #2290 drill red → HIT"
printf '#!/bin/bash\necho "PASS  cred-upstream-tenant-override   1.0s ≤30s  fake"\n' > "$D/bin/drill"

# ---- 5. sudo --------------------------------------------------------------------
cp "$D/bin/sudo" "$WORK/sudo.ok"
printf '#!/bin/bash\nexit 0\n' > "$D/bin/sudo"
ts_scan "$D" --only sudo
expect sudo HIT "5: sudo -n true succeeds → HIT"
printf '#!/bin/bash\n[ "$*" = "-n -l" ] && { echo "    (root) NOPASSWD: /Users/me/bin/x.sh"; exit 0; }\nexit 1\n' > "$D/bin/sudo"
ts_scan "$D" --only sudo
expect sudo HIT "5: a NOPASSWD rule → HIT"
cp "$WORK/sudo.ok" "$D/bin/sudo"
TS_GROUPS="staff admin" ts_scan "$D" --only sudo
expect sudo HIT "5: in the admin group → HIT"
[ "$(ts_metric 2)" = 1 ] && ok "5: ② counts it" || bad "5: ② = $(ts_metric 2)"

# ---- 6. root-writes -------------------------------------------------------------
python3 -c "import plistlib,sys; plistlib.dump({'Label':'com.x.home','ProgramArguments':['/usr/bin/true'],'StandardOutPath':sys.argv[1]+'/Users/me/.ccquota/agent.log'}, open(sys.argv[1]+'/daemons/com.x.home.plist','wb'))" "$D"
ts_scan "$D" --only root-writes
expect root-writes HIT "6: a root job's log in a home (#2296) → HIT"
rm -f "$D/daemons/com.x.home.plist"
printf '#!/bin/sh\n' > "$D/rw/job.sh"
python3 -c "import plistlib,sys; plistlib.dump({'Label':'com.x.rw','ProgramArguments':['/bin/bash',sys.argv[1]+'/rw/job.sh']}, open(sys.argv[1]+'/daemons/com.x.rw.plist','wb'))" "$D"
ts_scan "$D" --only root-writes
expect root-writes HIT "6: a root job's script writable by the login → HIT"
rm -f "$D/daemons/com.x.rw.plist"
printf '[Service]\nExecStart=/usr/bin/true\nStandardError=append:%s/Users/bob/err.log\n' "$D" > "$D/daemons/x-home.service"
ts_scan "$D" --only root-writes
expect root-writes HIT "6: a systemd unit (no User=) logging into a home → HIT"
rm -f "$D/daemons/x-home.service"

# ---- 7-9. other people's things -------------------------------------------------
chmod 755 "$D/Users/bob"
ts_scan "$D" --only homes
expect homes HIT "7: another home listable → HIT"
chmod 000 "$D/Users/bob"
chmod 700 "$D/tmp/tmux-12345"
ts_scan "$D" --only tmux
expect tmux HIT "8: another uid's tmux dir listable → HIT"
chmod 000 "$D/tmp/tmux-12345"
chmod 644 "$D/shared/other/t.jsonl"
ts_scan "$D" --only shared
expect shared HIT "9: another login's file in the shared dir readable → HIT"
printf '%s' "$OUT" | grep -q 'secret plan' && bad "9: the file's content was printed" || ok "9: content not printed"
chmod 000 "$D/shared/other/t.jsonl"

# ---- 10. preview ----------------------------------------------------------------
mkdir -p "$WORK/www" && printf '<title>someone else</title>\n' > "$WORK/www/index.html"
P2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
(cd "$WORK/www" && exec python3 -m http.server --bind 127.0.0.1 "$P2") >/dev/null 2>&1 &
TS_PIDS="$TS_PIDS $!"
i=0; until curl -s -o /dev/null "http://127.0.0.1:$P2/" 2>/dev/null || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
printf '%s %s\n' "$TS_PORT" "$P2" > "$D/ports"
ts_scan "$D" --only preview
expect preview HIT "10: an anonymous http.server → HIT"
printf '%s' "$(ts_row preview)" | grep -q ":$TS_PORT" && bad "10: doc-preview's server.py answered without a code" \
  || ok "10: doc-preview's server.py stays 404 beside it"
mkdir -p "$WORK/ts" && printf '<h1>Hello</h1>This is my Tailscale device. Your device is m.\n' > "$WORK/ts/index.html"
P3=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
(cd "$WORK/ts" && exec python3 -m http.server --bind 127.0.0.1 "$P3") >/dev/null 2>&1 &
TS_PIDS="$TS_PIDS $!"
i=0; until curl -s -o /dev/null "http://127.0.0.1:$P3/" 2>/dev/null || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
printf '%s %s\n' "$TS_PORT" "$P3" > "$D/ports"
ts_scan "$D" --only preview
expect preview PASS "10: tailscaled's PeerAPI greeting is a machine service, not counted"
printf '%s' "$(ts_row preview)" | grep -q "不计：127.0.0.1:$P3" && ok "10: …and named as not counted" || bad "10: PeerAPI not named"
printf '%s\n' "$TS_PORT" > "$D/ports"

# ---- 11. bootstrap --------------------------------------------------------------
rw mv "$D/ro/cache/claude" "$D/ro/cache/claude.off"
ts_scan "$D" --only bootstrap
expect bootstrap HIT "11: no Claude Code in the cache → HIT"
[ "$(ts_metric 4)" = 1 ] && ok "11: ④ = 1" || bad "11: ④ = $(ts_metric 4)"
rw mv "$D/ro/cache/claude-fleet.git" "$D/ro/cache/claude-fleet.off"
ts_scan "$D" --only bootstrap
[ "$(ts_metric 4)" = 1 ] && ok "11: no claude-fleet mirror is no reach any more (#2775) → ④ = 1" || bad "11: ④ = $(ts_metric 4)"
rw mv "$D/ro/cache/claude.off" "$D/ro/cache/claude"
rw mv "$D/ro/cache/claude-fleet.off" "$D/ro/cache/claude-fleet.git"
# a login linked to the machine's runtime (#2774/#2775): no reach, said so
mv "$D/Users/me/.claude/fleet" "$D/Users/me/.claude/fleet.co"
mkdir -p "$D/Users/me/.claude/fleet.versions/v1"
printf '{"sha": "%040d", "root": "/r"}\n' 0 > "$D/Users/me/.claude/fleet.versions/v1/.fleet-linked"
ln -s "$D/Users/me/.claude/fleet.versions/v1" "$D/Users/me/.claude/fleet"
ts_scan "$D" --only bootstrap
expect bootstrap PASS "11: a login linked to the runtime → no hit"
printf '%s' "$(ts_row bootstrap)" | grep -q '链接本机运行时' && ok "11: …and said so" || bad "11: linked not said: $(ts_row bootstrap)"
rm -f "$D/Users/me/.claude/fleet"; rm -rf "$D/Users/me/.claude/fleet.versions"
mv "$D/Users/me/.claude/fleet.co" "$D/Users/me/.claude/fleet"
LOGF="$D/Users/me/.claude/fleet/.git/logs/HEAD"
cp "$LOGF" "$WORK/HEAD.log"
sed 's#clone: from .*#clone: from https://github.com/verkyyi/claude-fleet.git#' "$WORK/HEAD.log" > "$LOGF"
ts_scan "$D" --only bootstrap
expect bootstrap HIT "11: this login cloned from the network → HIT"
cp "$WORK/HEAD.log" "$LOGF"

# ---- 12. usage + json -----------------------------------------------------------
ts_scan "$D" --only nope
[ "$RC" = 2 ] && ok "12: an unknown item → exit 2" || bad "12: unknown item exit $RC"
chmod 755 "$D/Users/bob"
ts_scan "$D" --json --no-drill
printf '%s' "$OUT" | python3 -c '
import json, sys
j = json.load(sys.stdin)
assert j["verdict"] == "FAIL", j["verdict"]
assert j["metrics"]["3"]["ways"] == 1, j["metrics"]
assert [i["result"] for i in j["items"] if i["id"] == "homes"] == ["HIT"]
assert all(i["break_it"] for i in j["items"]) and len(j["items"]) == 11
' && [ "$RC" = 1 ] && ok "12: --json: FAIL, ③ = 1, homes HIT, exit 1" || bad "12: --json"
chmod 000 "$D/Users/bob"

if [ "$FAILS" -gt 0 ]; then
  printf 'fleet-tenant-scan selftest: %d FAILED\n' "$FAILS" >&2
  exit 1
fi
echo "fleet-tenant-scan selftest: OK"
