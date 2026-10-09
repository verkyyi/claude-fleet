#!/usr/bin/env bash
# fleet-credsep-selftest.sh — separated credentials (issue #1971, EPIC #1967 C4),
# in a sandbox: bin/fleet-credsep.sh + fleet-credsep.py + fleet-credsep-launch.py
# + fleet-cred-proxy.py, with every root path moved under a temp dir
# (FLEET_CREDSEP_* seams), no sudo, the role account played by this user and no
# launchctl / systemctl run. The OS half — a real role account, and a session
# that gets "Permission denied" — is the issue's on-machine evidence, not this.
#
#   A  FLEET_CRED_SEPARATE=0: apply does nothing, every file byte for byte
#   B  install: leased credentials, hub-managed Codex auth.json and node.env
#      move into the store (same bytes); a personal Codex login stays; node.env
#      becomes a symlink, node.pub.env holds no token; the agent's service now
#      starts the launcher, its agent argv comes from run-agent.sh
#   C  the launcher starts the proxy against the store: a minted session reads
#      the moved credential; `store` (the agent's lease) lands in the store
#   D  the hub broker: fcpn1. → the real node token on the way out; POST
#      /v1/node/credentials (any spelling) refused before the hub sees it; no
#      credential → 401; node-hash = sha256(token); fleet-lib's
#      _fleet_node_env_val / _fleet_hub_env hand a session the broker pair, and
#      fleet-session-cred.sh's central pass (mint + revoke) rides it (issue #2392)
#   E  the ctl socket answers ONE peer uid (another uid is refused)
#   F  the launcher's agent mode: the token arrives on fd 3, never in the env
#   G  uninstall: every file back where it was, byte for byte; the store, the
#      record and the service changes gone
#   H  install --dry-run with NO sudo (issue #2135): runs as the login, names
#      every move, changes nothing
#   I  uninstall --dry-run as the login while the store is unreadable to it:
#      the way back is read from credsep.json's `back` (paths, no secret)
#   J  plan: every login under the homes dir, the ONE sudo line per login
#      carries --login, a `sudo -u` line carries that login's HOME
#   K  a login name may start with a digit (issue #2257): `machine install
#      --dry-run --logins 24haowan` passes; `Bad Name` / `-x` are still exit 2
#   L  root's settings (issue #2290): an upstream URL / FLEET_HUB_URL in the
#      login's fleet.conf is ignored (said on stderr + ignored.<login>), the
#      request goes to root's upstream; install --adopt takes only an https URL
#      to an allowed host, never FLEET_CRED_ALLOW_HOSTS
#   M  a root agent's log is not in the home (issue #2296): install points the
#      agent's stdout/stderr (the plist's Standard*Path, the drop-in's
#      StandardOutput) at $LOG_BASE/<login>/agent.log (0700); `rootlogs` is OK;
#      a definition from before #2296 (log back in the home) is WARN naming
#      `check --fix --login <login>`, which moves it; a root service that is
#      not the fleet's is named as such; a service with a UserName is not counted
#   N  --fresh (issue #2294, fleet-login-new.sh's step 7b): a login something
#      runs as is refused (exit 6, nothing made); --pool-src without --fresh is
#      exit 2 (fleet-login-new-selftest.sh drives the whole fresh install)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "/tmp/credsep-st.XXXXXX")
ME=$(id -un)
cleanup() {
  kill "$(cat "$SB/run/$ME/pid" 2>/dev/null)" 2>/dev/null
  [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null
  [ -n "${P2:-}" ] && kill "$P2" 2>/dev/null
  kill "$(cat "$SB/fake.pid" 2>/dev/null)" "$(cat "$SB/evil.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/home/.config/claude-fleet" XDG_CONFIG_HOME="$SB/home/.config"
export FLEET_CREDSEP_ROOT_BASE="$SB/db" FLEET_CREDSEP_RUN_BASE="$SB/run" FLEET_CREDSEP_LOG_BASE="$SB/log" \
       FLEET_CREDSEP_LIB="$SB/lib" FLEET_CREDSEP_DAEMON_DIR="$SB/daemons" FLEET_CREDSEP_ROLE="$ME" \
       FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO=''
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_CRED_SEPARATE
C=$FLEET_CONF_DIR R="$SB/db/$ME"
mkdir -p "$C/accounts/main.hub" "$HOME/.codex" "$HOME/.codex-accounts/work" "$HOME/.codex-accounts/mine" \
         "$HOME/.ccquota" "$SB/daemons"

FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }

# ── the login as a node leaves it today ────────────────────────────────────────
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-MAIN","refreshToken":null,"expiresAt":4102444800000,"scopes":["user:inference"]}}' \
  > "$C/accounts/main.hub/.credentials.json"
printf 'hub:main\n' > "$C/accounts/main"
printf '{"tokens":{"access_token":"at-DEFAULT","refresh_token":"hub-managed","account_id":"acct-d"}}' > "$HOME/.codex/auth.json"
printf '{"tokens":{"access_token":"at-WORK","refresh_token":"hub-managed","account_id":"acct-w"}}' > "$HOME/.codex-accounts/work/auth.json"
printf '{"tokens":{"access_token":"at-MINE","refresh_token":"rt-personal","account_id":"acct-m"}}' > "$HOME/.codex-accounts/mine/auth.json"
cat > "$C/node.env" <<'EOF'
# claude-fleet node-join (issue #1418) — this login's ccquota agent. Holds a credential: 0600.
CCQUOTA_HUB_URL=http://127.0.0.1:1
CCQUOTA_TOKEN=ccq_NODE_SECRET_0123
CCQUOTA_FLEET=1
CCQUOTA_FLEET_CREDS=1
EOF
chmod 600 "$C"/node.env "$C/accounts/main.hub/.credentials.json"
cat > "$HOME/.ccquota/run-agent.sh" <<EOF
#!/bin/sh
PATH="/usr/bin:/bin"
export PATH
set -a
. "$C/node.env"
set +a
cd "\$HOME" || exit 1
exec "$SB/fake-agent" agent --state "$HOME/.ccquota"
EOF
if [ "$(uname)" = Darwin ]; then
  AGENT_DEF="$SB/daemons/com.ccquota.agent.$ME.plist"
  python3 - "$AGENT_DEF" "$HOME/.ccquota/run-agent.sh" "$ME" "$HOME/.ccquota/agent.log" <<'PY'
import plistlib, sys
plistlib.dump({"Label": "com.ccquota.agent." + sys.argv[3], "ProgramArguments": [sys.argv[2]],
               "RunAtLoad": True, "KeepAlive": True, "UserName": sys.argv[3],
               "StandardOutPath": sys.argv[4], "StandardErrorPath": sys.argv[4]}, open(sys.argv[1], "wb"))
PY
else
  AGENT_DEF="$SB/daemons/ccquota-agent-$ME.service"
  printf '[Service]\nUser=%s\nExecStart=%s\nStandardOutput=append:%s\nStandardError=append:%s\n' \
    "$ME" "$HOME/.ccquota/run-agent.sh" "$HOME/.ccquota/agent.log" "$HOME/.ccquota/agent.log" > "$AGENT_DEF"
fi
# the "agent": proves where its token came from
cat > "$SB/fake-agent" <<'EOF'
#!/bin/sh
{ printf 'fd3=%s\n' "$(head -n 1 <&3 2>/dev/null)"; env | grep -c ccq_NODE_SECRET | sed 's/^/envhits=/'
  printf 'store=%s\n' "$CCQUOTA_FLEET_CRED_STORE"; printf 'args=%s\n' "$*"; } > "$HOME/agent.out"
EOF
chmod +x "$SB/fake-agent"

snap() { # every file under the login's tree + the service dir: path, kind, bytes
  (cd "$SB" && find home daemons -path home/Library -prune -o \( -type f -o -type l \) -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
     if [ -L "$f" ]; then printf '%s L %s\n' "$f" "$(readlink "$f")"
     else printf '%s F %s\n' "$f" "$(cksum < "$f" | tr -s ' ' ' ')"; fi
   done)
}
BEFORE=$(snap)

# ── A: off ⇒ nothing ───────────────────────────────────────────────────────────
out=$(FLEET_CRED_SEPARATE=0 bash "$BIN/fleet-credsep.sh" apply 2>&1)
if [ "$out" = "credsep: skip — off (FLEET_CRED_SEPARATE=0)" ] && [ "$(snap)" = "$BEFORE" ] && [ ! -e "$SB/db" ]; then
  pass "A off: apply skips, every file byte for byte, no store"
else fail "A off: '$out'"; fi
out=$(FLEET_CRED_SEPARATE=0 bash "$BIN/fleet-credsep.sh" check 2>&1)
case "$out" in "credsep: INFO — off"*) pass "A off: check is INFO off (the doctor prints no row)" ;; *) fail "A check: $out" ;; esac

# ── H: the dry run needs no sudo and changes nothing (issue #2135) ──────────────
out=$(FLEET_CREDSEP_SUDO=false bash "$BIN/fleet-credsep.sh" install --dry-run 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "would move $C/node.env" \
   && printf '%s' "$out" | grep -q "would move $C/accounts/main.hub/.credentials.json" \
   && [ "$(snap)" = "$BEFORE" ] && [ ! -e "$SB/db" ] && [ ! -e "$SB/lib" ]; then
  pass "H install --dry-run without sudo: names every move, changes nothing"
else fail "H dry run rc=$rc: $out"; fi
printf '%s' "$out" | grep -q 'sk-ant-\|ccq_' && fail "H the dry run printed a credential" || pass "H the dry run prints paths, no credential"
out=$(FLEET_CREDSEP_SUDO=false bash "$BIN/fleet-credsep.sh" uninstall --dry-run 2>&1); rc=$?
case "$rc:$out" in "0:credsep: not separated"*) pass "H uninstall --dry-run when not separated: nothing to undo" ;; *) fail "H uninstall dry rc=$rc: $out" ;; esac

# ── N: --fresh is for a login nothing runs as yet (issue #2294) ─────────────────
out=$(FLEET_CREDSEP_PREFLIGHT=1 bash "$BIN/fleet-credsep.sh" install --fresh 2>&1); rc=$?
if [ "$rc" = 6 ] && printf '%s' "$out" | grep -q 'not a fresh login' && [ "$(snap)" = "$BEFORE" ] && [ ! -e "$R" ]; then
  pass "N --fresh on a login with processes: refused (exit 6), nothing made"
else fail "N --fresh rc=$rc: $out"; fi
# macOS's own per-user agents never make a login "not fresh" (issue #2210)
out=$(python3 -c 'import importlib.util as u,sys; s=u.spec_from_file_location("c",sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m)
print(" ".join(str(m.os_agent(c)) for c in sys.argv[2:]))' "$BIN/fleet-credsep.py" \
  /usr/sbin/cfprefsd /usr/libexec/lsd /System/Library/Frameworks/Contacts.framework/Support/contactsd \
  /bin/zsh /Users/x/.local/bin/claude /usr/bin/ssh git 2>&1)
case "$out" in "True True True False False False False") pass "N the OS's per-user agents are not a session; a shell, claude, ssh are" ;; *) fail "N os_agent: $out" ;; esac
out=$(bash "$BIN/fleet-credsep.sh" install --pool-src "$SB" 2>&1); rc=$?
case "$rc:$out" in 2:*"--pool-src is for a login just opened"*) pass "N --pool-src without --fresh: exit 2" ;; *) fail "N pool-src rc=$rc: $out" ;; esac
[ "$(snap)" = "$BEFORE" ] && [ ! -e "$R" ] && pass "N refusals changed nothing" || fail "N a refusal changed something"

# ── B: install ─────────────────────────────────────────────────────────────────
out=$(FLEET_CRED_SEPARATE=1 bash "$BIN/fleet-credsep.sh" apply 2>&1); rc=$?
[ "$rc" = 0 ] && case "$out" in "credsep: ok — credsep: ON"*) true ;; *) false ;; esac \
  && pass "B install via apply: $out" || fail "B apply rc=$rc: $out"
same() { [ -f "$2" ] && [ "$(cksum < "$2")" = "$1" ]; }
ck() { cksum < "$1"; }
[ ! -e "$C/accounts/main.hub/.credentials.json" ] && grep -q sk-ant-oat01-MAIN "$R/accounts/main.hub/.credentials.json" \
  && pass "B claude credential moved into the store" || fail "B claude credential"
[ "$(cat "$C/accounts/main")" = "hub:main" ] && pass "B the label marker (no credential) stays" || fail "B marker"
[ ! -e "$HOME/.codex/auth.json" ] && grep -q at-DEFAULT "$R/codex/default/auth.json" \
  && [ ! -e "$HOME/.codex-accounts/work/auth.json" ] && grep -q at-WORK "$R/codex/work/auth.json" \
  && pass "B hub-managed codex auth.json moved (default + work)" || fail "B codex"
grep -q at-MINE "$HOME/.codex-accounts/mine/auth.json" && [ ! -e "$R/codex/mine" ] \
  && pass "B a personal codex login (own refresh token) stays put" || fail "B personal codex moved"
[ -L "$C/node.env" ] && [ "$(readlink "$C/node.env")" = "$R/node.env" ] && grep -q ccq_NODE_SECRET "$R/node.env" \
  && pass "B node.env → symlink into the store" || fail "B node.env"
grep -q '^CCQUOTA_HUB_URL=' "$C/node.pub.env" && ! grep -q TOKEN "$C/node.pub.env" \
  && pass "B node.pub.env: the token-less lines" || fail "B node.pub.env: $(cat "$C/node.pub.env")"
[ -f "$C/credsep.json" ] && [ -f "$SB/lib/fleet-credsep-launch.py" ] && [ -f "$SB/lib/fleet-cred-proxy.py" ] \
  && pass "B record + the code copy" || fail "B record/lib"
python3 - "$R/meta.json" "$SB/fake-agent" <<'PY' && pass "B meta: agent argv from run-agent.sh" || fail "B meta"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["agent_argv"][0] == sys.argv[2] and m["agent_argv"][1] == "agent", m
assert m["path"] == "/usr/bin:/bin", m
PY
if grep -q "^ExecStart=.*fleet-credsep-launch.py.* agent $ME\$" "$AGENT_DEF.d/credsep.conf" 2>/dev/null \
     && grep -q '^User=root$' "$AGENT_DEF.d/credsep.conf" \
   || python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); sys.exit(0 if "UserName" not in p and p["ProgramArguments"][-2:]==["agent",sys.argv[2]] else 1)' "$AGENT_DEF" "$ME" 2>/dev/null; then
  pass "B the agent's service starts the launcher (root, no UserName)"
else fail "B agent service: $(cat "$AGENT_DEF" "$AGENT_DEF.d/credsep.conf" 2>/dev/null | head -20)"; fi
{ [ -e "$SB/daemons/com.claude-fleet.credsep.$ME.plist" ] || [ -e "$SB/daemons/claude-fleet-credsep-$ME.service" ]; } && pass "B the proxy service is written" || fail "B proxy service"
out=$(FLEET_CRED_SEPARATE=1 bash "$BIN/fleet-credsep.sh" apply 2>&1)
case "$out" in *"credsep: ON"*) pass "B apply again: idempotent" ;; *) fail "B re-apply: $out" ;; esac
grep -q at-DEFAULT "$R/codex/default/auth.json" && [ -L "$C/node.env" ] && pass "B re-apply moved nothing twice" || fail "B re-apply damage"

# ── M: the root agent's log is not in the home (issue #2296) ───────────────────
# the effective stdout path of the agent's definition (plist / unit + drop-in)
agent_log_of() {
  python3 - "$AGENT_DEF" <<'PY'
import glob, plistlib, re, sys
p = sys.argv[1]
if p.endswith(".plist"):
    d = plistlib.load(open(p, "rb"))
    print(d.get("StandardOutPath", "") if d.get("StandardOutPath") == d.get("StandardErrorPath") else "MISMATCH")
else:
    v = ""
    for f in [p] + sorted(glob.glob(p + ".d/*.conf")):
        for l in open(f):
            m = re.match(r"StandardOutput=(?:file|append|truncate):(.*)$", l.strip())
            if m:
                v = m.group(1)
    print(v)
PY
}
rootlogs() { FLEET_CREDSEP_HOMES="$SB/home" bash "$BIN/fleet-credsep.sh" rootlogs 2>&1; }
lg=$(agent_log_of)
mode=$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$SB/log/$ME" 2>/dev/null)
[ "$lg" = "$SB/log/$ME/agent.log" ] && [ "$mode" = 0o700 ] \
  && pass "M the root agent logs to \$LOG_BASE/$ME/agent.log (dir 0700), not the home" || fail "M agent log=$lg dir mode=$mode"
out=$(rootlogs); rc=$?
case "$rc:$out" in "0:rootlog: OK"*) pass "M rootlogs after install: $out" ;; *) fail "M rootlogs rc=$rc: $out" ;; esac
# a definition separated before #2296: the agent's log back in the home
python3 - "$AGENT_DEF" "$HOME/.ccquota/agent.log" <<'PY'
import plistlib, sys
p, log = sys.argv[1], sys.argv[2]
if p.endswith(".plist"):
    d = plistlib.load(open(p, "rb")); d["StandardOutPath"] = d["StandardErrorPath"] = log
    plistlib.dump(d, open(p, "wb"))
else:
    f = p + ".d/credsep.conf"
    keep = "".join(l for l in open(f) if not l.startswith("Standard"))
    open(f, "w").write(keep)
PY
out=$(rootlogs); rc=$?
case "$rc:$out" in 1:"rootlog: WARN"*"check --fix --login <login> for $ME"*) pass "M an old definition (log in the home) is WARN naming the fix" ;;
  *) fail "M old definition rc=$rc: $out" ;; esac
out=$(bash "$BIN/fleet-credsep.sh" check --fix 2>&1)
printf '%s' "$out" | grep -q "agent: log .*→ $SB/log/$ME/agent.log" && [ "$(agent_log_of)" = "$SB/log/$ME/agent.log" ] \
  && rootlogs | grep -q '^rootlog: OK' && pass "M check --fix moves the old definition's log out of the home" \
  || fail "M check --fix: $out / $(agent_log_of)"
out=$(bash "$BIN/fleet-credsep.sh" check --fix 2>&1)
printf '%s' "$out" | grep -q 'nothing to move' && pass "M check --fix again: nothing to move" || fail "M fix again: $out"
# a root service that is not the fleet's, and one that runs as its login
if [ "$(uname)" = Darwin ]; then
  python3 -c 'import plistlib,sys; plistlib.dump({"Label":"x.other","ProgramArguments":["/bin/true"],"StandardErrorPath":sys.argv[2]}, open(sys.argv[1],"wb"))' \
    "$SB/daemons/x.other.plist" "$HOME/other.err"
  python3 -c 'import plistlib,sys; plistlib.dump({"Label":"x.mine","UserName":"nobody","ProgramArguments":["/bin/true"],"StandardErrorPath":sys.argv[2]}, open(sys.argv[1],"wb"))' \
    "$SB/daemons/x.mine.plist" "$HOME/mine.err"
  junk="$SB/daemons/x.other.plist $SB/daemons/x.mine.plist"
else
  printf '[Service]\nExecStart=/bin/true\nStandardError=file:%s\n' "$HOME/other.err" > "$SB/daemons/x.other.service"
  printf '[Service]\nUser=nobody\nExecStart=/bin/true\nStandardError=file:%s\n' "$HOME/mine.err" > "$SB/daemons/x.mine.service"
  junk="$SB/daemons/x.other.service $SB/daemons/x.mine.service"
fi
out=$(rootlogs); rc=$?
case "$rc:$out" in 1:"rootlog: WARN — 1 root service(s)"*"not the fleet's"*x.other*) pass "M a foreign root service logging in a home is named; a UserName one is not" ;;
  *) fail "M foreign rc=$rc: $out" ;; esac
# shellcheck disable=SC2086
rm -f $junk

# ── C: the proxy, started by the launcher ──────────────────────────────────────
cat > "$SB/fake.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SB = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        with open(SB + "/fake.log", "a") as f:
            f.write("%s %s auth=%s\n" % (self.command, self.path, self.headers.get("authorization", "")))
        try: trust = open(SB + "/trust").read().strip()
        except OSError: trust = "trusted"
        if self.path.endswith("/v1/node/self"): d = {"trust": trust}
        elif self.path.endswith("/v1/fleet/session-cred") and self.command == "POST":
            d = {"cred": "fcp-h1.PASS-sep.sig", "id": "pass-sep"}
        else: d = {"ok": True}
        b = json.dumps(d).encode()
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = do_DELETE = any
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(SB + "/fake.port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$SB/fake.py" "$SB" & echo $! > "$SB/fake.pid"
mkdir -p "$SB/evil"; python3 "$SB/fake.py" "$SB/evil" & echo $! > "$SB/evil.pid"
for _ in $(seq 1 300); do [ -s "$SB/fake.port" ] && break; sleep 0.1; done   # a slow runner: 30s
FP=$(cat "$SB/fake.port" 2>/dev/null)
[ -n "$FP" ] || { fail "C the fake far end never published its port"; }
sed -i.bak "s#^CCQUOTA_HUB_URL=.*#CCQUOTA_HUB_URL=http://127.0.0.1:$FP#" "$R/node.env" && rm -f "$R/node.env.bak"
# the upstreams come from root's settings only (issue #2290); install wrote the file
[ -f "$SB/lib/$ME.conf" ] && pass "C install wrote root's settings $SB/lib/$ME.conf" || fail "C no root settings file"
printf 'FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:%s\nFLEET_CRED_CODEX_URL=http://127.0.0.1:%s/codex\n' "$FP" "$FP" >> "$SB/lib/$ME.conf"
python3 -I "$BIN/fleet-credsep-launch.py" proxy "$ME" 2>"$SB/launch.err" &
LPID=$!
for _ in $(seq 1 300); do [ -S "$SB/run/$ME/ctl.sock" ] && [ -s "$SB/run/$ME/port" ] && break; sleep 0.1; done
PORT=$(cat "$SB/run/$ME/port" 2>/dev/null)
[ -n "$PORT" ] && pass "C the launcher started the proxy (127.0.0.1:$PORT, run dir)" \
  || { fail "C proxy did not start: $(cat "$SB/launch.err")"; }
m=$(ls -l "$SB/run/$ME/ctl.sock" 2>/dev/null | cut -c1-10)
[ "$m" = srw-rw-rw- ] && pass "C ctl.sock 0666 (the peer-uid gate decides)" || fail "C ctl.sock mode $m"
m=$(ls -l "$SB/run/$ME/port" 2>/dev/null | cut -c1-10)
[ "$m" = -rw-r--r-- ] && pass "C port 0644 (the login is another uid)" || fail "C port mode $m"
[ "$(bash "$BIN/fleet-cred-proxy.sh" port 2>&1)" = "$PORT" ] && pass "C fleet-cred-proxy.sh port reads the run dir" \
  || fail "C port: $(bash "$BIN/fleet-cred-proxy.sh" port 2>&1)"
tok=$(bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid s1 2>&1)
code=$(curl -s --max-time 60 -o "$SB/c.body" -w '%{http_code}' -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/v1/messages")
grep -q "POST /v1/messages auth=Bearer sk-ant-oat01-MAIN" "$SB/fake.log" 2>/dev/null \
  && pass "C a session's request carries the credential from the store" \
  || fail "C direct: HTTP $code $(cat "$SB/c.body" 2>/dev/null) · fake saw: $(tail -3 "$SB/fake.log" 2>/dev/null)"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-RENEWED"}}' | bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label main
grep -q RENEWED "$R/accounts/main.hub/.credentials.json" && [ ! -e "$C/accounts/main.hub/.credentials.json" ] \
  && pass "C store: the agent's lease lands in the store, not the login" || fail "C store"
printf 'rp-PASS-1\n' | bash "$BIN/fleet-cred-proxy.sh" relay
[ "$(cat "$R/cred-proxy/relay.token" 2>/dev/null)" = rp-PASS-1 ] \
  && pass "C relay: the login's minted relay pass lands in the proxy's state" || fail "C relay pass"
printf 'x' | bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label ../evil 2>/dev/null \
  && fail "C store accepted ../evil" || pass "C store refuses a path-like label"

# ── D: the hub broker ─────────────────────────────────────────────────────────
pair=$(bash "$BIN/fleet-cred-proxy.sh" node-token 2>&1)
burl=${pair%%	*} btok=${pair#*	}
case "$btok" in fcpn1.*) pass "D node-token: $burl + fcpn1." ;; *) fail "D node-token: $pair" ;; esac
: > "$SB/fake.log"
code=$(curl -s --max-time 60 -o "$SB/d.body" -w '%{http_code}' -H "Authorization: Bearer $btok" "$burl/v1/node/self")
grep -q "GET /v1/node/self auth=Bearer ccq_NODE_SECRET_0123" "$SB/fake.log" \
  && pass "D broker: the node token is put in on the way out" \
  || fail "D broker fwd: HTTP $code $(cat "$SB/d.body" 2>/dev/null) · fake saw: $(cat "$SB/fake.log")"
: > "$SB/fake.log"
for p in /v1/node/credentials /v1/node/credentials/ //v1/node/credentials /v1/node/./credentials /v1/node/%63redentials /V1/NODE/CREDENTIALS; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $btok" "$burl$p")
  [ "$c" = 403 ] || { fail "D broker let $p through ($c)"; }
done
[ ! -s "$SB/fake.log" ] && pass "D broker: /v1/node/credentials refused in every spelling, the hub never asked" \
  || fail "D the hub saw: $(cat "$SB/fake.log")"
c=$(curl -s -o /dev/null -w '%{http_code}' "$burl/v1/node/self")
[ "$c" = 401 ] && pass "D broker: no credential → 401" || fail "D no cred → $c"
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" "$burl/v1/node/self")
[ "$c" = 401 ] && pass "D broker: a session credential (fcp1.) is not a node credential" || fail "D fcp1 → $c"
want=$(printf 'ccq_NODE_SECRET_0123' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
[ "$(bash "$BIN/fleet-cred-proxy.sh" node-hash)" = "$want" ] && pass "D node-hash = sha256(node token)" || fail "D node-hash"
# a session's view: node.env unreadable (here: a dangling link) + the record
S="$SB/session-conf"; mkdir -p "$S"; ln -s "$SB/nowhere/node.env" "$S/node.env"
cp "$C/credsep.json" "$C/node.pub.env" "$S/"
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_node_env_val CCQUOTA_TOKEN")
case "$v" in fcpn1.*) pass "D fleet-lib: _fleet_node_env_val CCQUOTA_TOKEN → the broker's credential" ;; *) fail "D lib token: '$v'" ;; esac
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_node_env_val CCQUOTA_FLEET")
[ "$v" = 1 ] && pass "D fleet-lib: other keys from node.pub.env" || fail "D lib key: '$v'"
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_hub_env; printf '%s %s' \"\$CCQUOTA_HUB_URL\" \"\${CCQUOTA_TOKEN%%.*}\"")
[ "$v" = "$burl fcpn1" ] && pass "D fleet-lib: _fleet_hub_env exports the broker PAIR" || fail "D hub_env: '$v'"
# a central session on a separated login (issue #2392): fleet-session-cred.sh's
# hub pass rides the broker too — before, it read node.env, found nothing and
# `fleet claude` refused to launch ("central route: no hub / node token")
echo untrusted > "$SB/trust"
FLEET_CONF_DIR="$S" bash "$BIN/fleet-cred-proxy.sh" route --provider claude --refresh >/dev/null 2>&1
: > "$SB/fake.log"
row=$(FLEET_CONF_DIR="$S" FLEET_CRED_PROXY=1 FLEET_WORKER_ASSERT=fwa1.test.sig \
      bash "$BIN/fleet-session-cred.sh" mint --provider claude --sid sep1 2>"$SB/d.err")
case "$row" in central"	"*"	"fcp-h1.PASS-sep.sig) pass "D session-cred: a central pass on a separated login" ;;
  *) fail "D session-cred mint: '$row' $(cat "$SB/d.err")" ;; esac
grep -q "POST /v1/fleet/session-cred auth=Bearer ccq_NODE_SECRET_0123" "$SB/fake.log" \
  && pass "D session-cred: the pass request went through the broker (node token put in)" \
  || fail "D session-cred: the hub saw: $(cat "$SB/fake.log")"
FLEET_CONF_DIR="$S" bash "$BIN/fleet-session-cred.sh" revoke --sid sep1
grep -q "DELETE /v1/fleet/session-cred/pass-sep auth=Bearer ccq_NODE_SECRET_0123" "$SB/fake.log" \
  && pass "D session-cred: revoke DELETEs the pass through the broker" \
  || fail "D session-cred revoke: the hub saw: $(cat "$SB/fake.log")"
rm -f "$SB/trust"
FLEET_CONF_DIR="$S" bash "$BIN/fleet-cred-proxy.sh" route --provider claude --refresh >/dev/null 2>&1

# ── E: one peer uid ──────────────────────────────────────────────────────────────
mkdir -p "$SB/e/state" "$SB/e/run"
FLEET_CONF_DIR="$SB/e" FLEET_CRED_CTL_DIR="$SB/e/run" FLEET_CRED_CTL_UID=99999 FLEET_CRED_PROXY_LOG="$SB/e/log" \
  python3 -I "$BIN/fleet-cred-proxy.py" --state "$SB/e/state" serve --max-seconds 90 2>"$SB/e/err" &
P2=$!
for _ in $(seq 1 300); do [ -S "$SB/e/run/ctl.sock" ] && break; sleep 0.1; done   # a slow runner: 30s
[ -S "$SB/e/run/ctl.sock" ] || echo "E proxy stderr: $(cat "$SB/e/err")"
out=$(FLEET_CRED_CTL_DIR="$SB/e/run" python3 -I "$BIN/fleet-cred-proxy.py" --state "$SB/e/state" status 2>&1); rc=$?
[ "$rc" != 0 ] && case "$out" in *"not this login"*) true ;; *) false ;; esac \
  && pass "E ctl refuses a peer that is not the login's uid" || fail "E ctl answered uid $(id -u): $out"
kill "$P2" 2>/dev/null; P2=''

# ── F: the agent's launch ────────────────────────────────────────────────────────
python3 -I "$BIN/fleet-credsep-launch.py" agent "$ME" 2>"$SB/agent.err"
grep -q '^fd3=ccq_NODE_SECRET_0123$' "$HOME/agent.out" && grep -q '^envhits=0$' "$HOME/agent.out" \
  && grep -q "^store=$SB/run/$ME/ctl.sock$" "$HOME/agent.out" \
  && pass "F agent: token on fd 3, not in its environment; the store socket handed over" \
  || fail "F agent: $(cat "$HOME/agent.out" "$SB/agent.err" 2>/dev/null)"
rm -f "$HOME/agent.out"

# ── F2: one agent per login (issue #2663) — the launcher stops a stray first ─────
# an agent from before the separation (an orphan at PPID=1) on the same --state;
# beside it one on another --state and the machine's node program: both stay
mkdir -p "$SB/oldbin"
printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$SB/oldbin/ccquota"; chmod +x "$SB/oldbin/ccquota"
"$SB/oldbin/ccquota" agent --state "$HOME/.ccquota" & STRAY=$!
"$SB/oldbin/ccquota" agent --state "$SB/other-state" & OTHER=$!
"$SB/oldbin/ccquota" agent --machine --state "$HOME/.ccquota" & MACH=$!
sleep 0.3
out=$(python3 -I "$BIN/fleet-credsep-launch.py" agents "$ME" 2>&1)
printf '%s\n' "$out" | grep -q "^$STRAY " && printf '%s\n' "$out" | grep -q "^$OTHER " \
  && ! printf '%s\n' "$out" | grep -q "^$MACH " \
  && pass "F2 agents: this login's ccquota agents listed, the machine's node program not" \
  || fail "F2 agents ($STRAY $OTHER, not $MACH): $out"
python3 -I "$BIN/fleet-credsep-launch.py" agent "$ME" 2>"$SB/agent.err"
sleep 0.2
gone() { ! kill -0 "$1" 2>/dev/null || ps -o stat= -p "$1" 2>/dev/null | grep -q '^Z'; }
if gone "$STRAY" && ! gone "$OTHER" && ! gone "$MACH" && grep -q '^fd3=ccq_NODE_SECRET_0123$' "$HOME/agent.out" \
   && grep -q "stopped a stray agent pid $STRAY" "$SB/agent.err"; then
  pass "F2 launcher: the stray agent on the same --state stopped before the new one ran; another state and --machine untouched"
else fail "F2 launcher: stray=$STRAY $(gone "$STRAY" && echo gone) other=$(gone "$OTHER" && echo gone) mach=$(gone "$MACH" && echo gone) · $(cat "$SB/agent.err")"; fi
kill "$STRAY" "$OTHER" "$MACH" 2>/dev/null; wait "$STRAY" "$OTHER" "$MACH" 2>/dev/null
rm -f "$HOME/agent.out"

# ── I: the way back, read by the login that cannot read the store ─────────────
chmod 000 "$R"
out=$(FLEET_CREDSEP_SUDO=false bash "$BIN/fleet-credsep.sh" uninstall --dry-run 2>&1); rc=$?
chmod 700 "$R"
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "$R/accounts/main.hub/.credentials.json → $C/accounts/main.hub/.credentials.json" \
   && printf '%s' "$out" | grep -qF "$R/node.env → $C/node.env" \
   && printf '%s' "$out" | grep -qF "$R/codex/work/auth.json → $HOME/.codex-accounts/work/auth.json" \
   && printf '%s' "$out" | grep -q "agent: com.ccquota.agent.$ME\|agent: ccquota-agent-$ME.service"; then
  pass "I uninstall --dry-run, store unreadable: every way back from credsep.json"
else fail "I rc=$rc: $out"; fi
[ -f "$R/node.env" ] && [ -L "$C/node.env" ] && pass "I the dry run moved nothing back" || fail "I the dry run moved something"
grep -q 'sk-ant-\|ccq_\|at-WORK' "$C/credsep.json" && fail "I credsep.json holds a credential" || pass "I credsep.json: paths only"

# ── J: plan ──────────────────────────────────────────────────────────────────────
mkdir -p "$SB/homes/ann/.claude/fleet/bin" "$SB/homes/bob" && : > "$SB/homes/ann/.claude/fleet/bin/fleet-credsep.sh"
printf 'ann:%s\nbob:%s\nroot:/var/root\n' "$SB/homes/ann" "$SB/homes/bob" > "$SB/users"
out=$(FLEET_CREDSEP_HOMES="$SB/homes" FLEET_CREDSEP_USERS="$SB/users" bash "$BIN/fleet-credsep.sh" plan 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "sudo bash $SB/homes/ann/.claude/fleet/bin/fleet-credsep.sh install --login ann" \
   && printf '%s' "$out" | grep -qF "sudo -u ann env HOME=$SB/homes/ann bash" \
   && ! printf '%s' "$out" | grep -q '^bob\|^root'; then
  pass "J plan: one block per login with an install, the one sudo carries --login"
else fail "J plan rc=$rc: $out"; fi

# ── K: a login name may start with a digit (issue #2257) ───────────────────────
mkdir -p "$SB/homes/24haowan/.config/claude-fleet"
printf '24haowan:%s:%s:%s\n' "$(id -u)" "$(id -g)" "$SB/homes/24haowan" > "$SB/pw"
out=$(FLEET_CREDSEP_PW="$SB/pw" bash "$BIN/fleet-credsep.sh" machine install --dry-run --logins 24haowan 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^== 24haowan' && [ ! -e "$SB/db/24haowan" ]; then
  pass "K machine install --dry-run accepts 24haowan"
else fail "K 24haowan rc=$rc: $out"; fi
for bad in 'Bad Name' '-x' 'a/b'; do
  out=$(FLEET_CREDSEP_PW="$SB/pw" bash "$BIN/fleet-credsep.sh" machine install --dry-run "--logins=$bad" 2>&1); rc=$?
  case "$rc:$out" in 2:*"bad login"*) pass "K '$bad' still refused (exit 2)" ;; *) fail "K '$bad' rc=$rc: $out" ;; esac
done

# ── L: the login's own files cannot move an upstream or the hub (issue #2290) ──
for _ in $(seq 1 300); do [ -s "$SB/evil/fake.port" ] && break; sleep 0.1; done
EP=$(cat "$SB/evil/fake.port" 2>/dev/null)
cp "$R/node.env" "$SB/node.env.keep"
grep -v '^CCQUOTA_HUB_URL=' "$SB/node.env.keep" > "$R/node.env"   # the hub would come from FLEET_HUB_URL
printf 'FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:%s\nFLEET_CRED_CODEX_URL=http://127.0.0.1:%s/codex\nFLEET_CRED_CENTRAL_URL=http://127.0.0.1:%s\nFLEET_HUB_URL=http://127.0.0.1:%s\nFLEET_CRED_PROXY_TIMEOUT=30\n' \
  "$EP" "$EP" "$EP" "$EP" >> "$C/fleet.conf"
kill "$(cat "$SB/run/$ME/pid" 2>/dev/null)" 2>/dev/null; kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
rm -f "$SB/run/$ME/port"
python3 -I "$BIN/fleet-credsep-launch.py" proxy "$ME" 2>"$SB/launch.err" &
LPID=$!
for _ in $(seq 1 300); do [ -s "$SB/run/$ME/port" ] && break; sleep 0.1; done
PORT=$(cat "$SB/run/$ME/port" 2>/dev/null)
: > "$SB/fake.log"
tok=$(bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid s2 2>&1)
curl -s --max-time 60 -o /dev/null -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/v1/messages"
[ -n "$EP" ] && [ ! -s "$SB/evil/fake.log" ] && grep -q 'POST /v1/messages' "$SB/fake.log" \
  && pass "L a login-file upstream / FLEET_HUB_URL: never asked, root's upstream served it" \
  || fail "L the login's listener saw: $(cat "$SB/evil/fake.log" 2>/dev/null) · root's: $(cat "$SB/fake.log") · $(cat "$SB/launch.err")"
grep -q "ignored FLEET_CRED_ANTHROPIC_URL from $C/fleet.conf" "$SB/launch.err" && grep -q 'ignored FLEET_HUB_URL' "$SB/launch.err" \
  && grep -q '^FLEET_HUB_URL ' "$SB/run/$ME/ignored.$ME" && ! grep -q 'PROXY_TIMEOUT\|127.0.0.1' "$SB/run/$ME/ignored.$ME" \
  && pass "L the launcher says what it ignored (key names, no value) for credsep check" \
  || fail "L ignored note: $(cat "$SB/launch.err" "$SB/run/$ME/ignored.$ME" 2>&1)"
cp "$SB/node.env.keep" "$R/node.env"
# install --adopt: root takes the login's values — an https URL to an allowed host only
printf 'FLEET_HUB_URL=https://ccquota.24haowan.com\nFLEET_CRED_RELAY_URL=https://evil.example/relay\nFLEET_CRED_ALLOW_HOSTS=evil.example\n' > "$C/fleet.conf"
out=$(bash "$BIN/fleet-credsep.sh" install --adopt 2>&1); rc=$?
if [ "$rc" = 0 ] && grep -qx 'FLEET_HUB_URL=https://ccquota.24haowan.com' "$SB/lib/$ME.conf" \
   && ! grep -q evil "$SB/lib/$ME.conf" && grep -q "^FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:$FP\$" "$SB/lib/$ME.conf"; then
  pass "L install --adopt: the allowed hub taken, evil.example and ALLOW_HOSTS refused, root's other lines kept"
else fail "L adopt rc=$rc: $out · $(cat "$SB/lib/$ME.conf")"; fi
m=$(ls -l "$SB/lib/$ME.conf" | cut -c1-10)
[ "$m" = -rw------- ] && pass "L root's settings 0600 (a relay pass may be in it)" || fail "L root conf mode $m"

# ── G: uninstall ───────────────────────────────────────────────────────────────
kill "$(cat "$SB/run/$ME/pid" 2>/dev/null)" 2>/dev/null; kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null; LPID=''
# the renewal C stored goes back too; put the original bytes back in the store
# so the before/after comparison is exact
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-MAIN","refreshToken":null,"expiresAt":4102444800000,"scopes":["user:inference"]}}' \
  > "$R/accounts/main.hub/.credentials.json"
sed -i.bak "s#^CCQUOTA_HUB_URL=.*#CCQUOTA_HUB_URL=http://127.0.0.1:1#" "$R/node.env" && rm -f "$R/node.env.bak"
rm -f "$C/fleet.conf"
out=$(FLEET_CRED_SEPARATE=0 bash "$BIN/fleet-credsep.sh" apply 2>&1); rc=$?
case "$rc:$out" in "0:credsep: ok — credsep: OFF"*) pass "G uninstall via apply: $out" ;; *) fail "G rc=$rc: $out" ;; esac
AFTER=$(snap)
if [ "$AFTER" = "$BEFORE" ]; then pass "G every file back where it was, byte for byte (and the service definition)"
else fail "G differs:"; diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"); fi
[ ! -e "$R" ] && [ ! -e "$C/credsep.json" ] && [ ! -e "$SB/lib" ] && [ ! -e "$SB/daemons/com.claude-fleet.credsep.$ME.plist" ] \
  && [ ! -e "$SB/daemons/claude-fleet-credsep-$ME.service" ] \
  && pass "G the store, the record, the code copy and the proxy service are gone" || fail "G leftovers: $(ls "$SB/db" "$SB/daemons" 2>&1)"

[ "$FAIL" = 0 ] && echo "fleet-credsep selftest PASS" || { echo "fleet-credsep selftest FAIL"; exit 1; }
