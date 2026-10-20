#!/usr/bin/env bash
# fleet-credsep-selftest.sh — separated credentials (issue #1971, EPIC #1967 C4),
# in a sandbox: bin/fleet-credsep.sh + fleet-credsep.py + fleet-credsep-launch.py
# + fleet-cred-proxy.py, with every root path moved under a temp dir
# (FLEET_CREDSEP_* seams), no sudo, the role account played by this user and no
# launchctl / systemctl run. The OS half — a real role account, and a session
# that gets "Permission denied" — is the issue's on-machine evidence, not this.
#
#   A  no way out (issues #4607, #4675): FLEET_CRED_SEPARATE=0, with or without the
#      retired FLEET_CREDSEP_OPTIONAL=1, check FAILs on a login not separated
#   B  install: leased credentials, hub-managed Codex auth.json and node.env
#      move into the store (same bytes); a personal Codex login stays; node.env
#      becomes a symlink, node.pub.env holds no token; the agent's service now
#      starts the launcher, its agent argv comes from run-agent.sh; the login is
#      a TENANT of the machine's shared proxy — the machine's first brings its
#      service up, and no proxy of the login's own is written (issue #4674)
#   C  the shared launcher starts the proxy against the store: a minted session
#      reads the moved credential; `store` (the agent's lease) lands in the
#      store, never the login
#   D  the hub broker: fcpn1. → the real node token on the way out; POST
#      /v1/node/credentials (any spelling) refused before the hub sees it; no
#      credential → 401; node-hash = sha256(token); fleet-lib's
#      _fleet_node_env_val / _fleet_hub_env hand a session the broker pair, and
#      fleet-session-cred.sh's central pass (mint + revoke) rides it (issue #2392)
#   E  the ctl socket answers ONE peer uid (another uid is refused)
#   F  the launcher's agent mode: the token arrives on fd 3, never in the env
#   G  `uninstall` and `machine uninstall` are gone (issue #4675): exit 2, every
#      credential stays in the store, nothing comes back into the home
#   H  install --dry-run with NO sudo (issue #2135): runs as the login, names
#      every move, changes nothing
#   I  credsep.json, the login-readable record, holds paths only (no secret)
#   J  plan: every login under the homes dir, the ONE sudo line per login
#      carries --login, a `sudo -u` line carries that login's HOME
#   K  a login name may start with a digit (issue #2257): `machine install
#      --dry-run --logins 24acme` passes; `Bad Name` / `-x` are still exit 2
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
. "$BIN/selftest-lib.sh"
SB=$(mktemp -d "/tmp/credsep-st.XXXXXX")
ME=$(id -un)
SR="$SB/run/.shared"   # the machine's one proxy's run dir (issue #4674: no login runs its own)
cleanup() {
  kill "$(cat "$SR/pid" 2>/dev/null)" 2>/dev/null
  [ -n "${LPID:-}" ] && kill "$LPID" 2>/dev/null
  [ -n "${P2:-}" ] && kill "$P2" 2>/dev/null
  kill "$(cat "$SB/fake.pid" 2>/dev/null)" "$(cat "$SB/evil.pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/home/.config/claude-fleet" XDG_CONFIG_HOME="$SB/home/.config"
SPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
export FLEET_NODE_STATE="$SB/node" FLEET_CREDSEP_ROOT_BASE="$SB/db" FLEET_CREDSEP_RUN_BASE="$SB/run" FLEET_CREDSEP_LOG_BASE="$SB/log" \
       FLEET_CREDSEP_LIB="$SB/lib" FLEET_CREDSEP_DAEMON_DIR="$SB/daemons" FLEET_CREDSEP_ROLE="$ME" \
       FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' \
       FLEET_CREDSEP_JOIN_WAIT=0 FLEET_CRED_SHARED_PORT="$SPORT"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_CRED_SEPARATE
C=$FLEET_CONF_DIR R="$SB/db/$ME"
mkdir -p "$C/accounts/main.hub" "$HOME/.codex" "$HOME/.codex-accounts/work" "$HOME/.codex-accounts/mine" \
         "$HOME/.ccquota" "$SB/daemons"

st_tally

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

# ── A: no way out (issues #4607, #4675) ─────────────────────────────────────────
# FLEET_CRED_SEPARATE=0 is not a way out, and neither is the retired
# FLEET_CREDSEP_OPTIONAL=1 beside it: a node login not separated is red
for env_ in "FLEET_CRED_SEPARATE=0" "FLEET_CREDSEP_OPTIONAL=1 FLEET_CRED_SEPARATE=0"; do
  # shellcheck disable=SC2086 # the words are the environment
  out=$(env $env_ bash "$BIN/fleet-credsep.sh" check 2>&1); rc=$?
  case "$rc:$out" in "1:credsep: FAIL — this login is not separated"*) st_ok_all "A $env_: check FAILs (no way out, #4675)" ;; *) st_miss "A $env_ check rc=$rc: $out" ;; esac
done
[ "$(snap)" = "$BEFORE" ] || st_miss "A a check changed something"

# ── H: the dry run needs no sudo and changes nothing (issue #2135) ──────────────
out=$(FLEET_CREDSEP_SUDO=false bash "$BIN/fleet-credsep.sh" install --dry-run 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "would move $C/node.env" \
   && printf '%s' "$out" | grep -q "would move $C/accounts/main.hub/.credentials.json" \
   && [ "$(snap)" = "$BEFORE" ] && [ ! -e "$SB/db" ] && [ ! -e "$SB/lib" ]; then
  st_ok_all "H install --dry-run without sudo: names every move, changes nothing"
else st_miss "H dry run rc=$rc: $out"; fi
printf '%s' "$out" | grep -q 'sk-ant-\|ccq_' && st_miss "H the dry run printed a credential" || st_ok_all "H the dry run prints paths, no credential"
out=$(FLEET_CREDSEP_SUDO=false bash "$BIN/fleet-credsep.sh" uninstall --dry-run 2>&1); rc=$?
case "$rc:$out" in "2:"*"uninstall is gone (issue #4675)"*) st_ok_all "H uninstall --dry-run: gone (exit 2, #4675)" ;; *) st_miss "H uninstall dry rc=$rc: $out" ;; esac

# ── N: --fresh is for a login nothing runs as yet (issue #2294) ─────────────────
out=$(FLEET_CREDSEP_PREFLIGHT=1 bash "$BIN/fleet-credsep.sh" install --fresh 2>&1); rc=$?
if [ "$rc" = 6 ] && printf '%s' "$out" | grep -q 'not a fresh login' && [ "$(snap)" = "$BEFORE" ] && [ ! -e "$R" ]; then
  st_ok_all "N --fresh on a login with processes: refused (exit 6), nothing made"
else st_miss "N --fresh rc=$rc: $out"; fi
# macOS's own per-user agents never make a login "not fresh" (issue #2210)
out=$(python3 -c 'import importlib.util as u,sys; s=u.spec_from_file_location("c",sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m)
print(" ".join(str(m.os_agent(c)) for c in sys.argv[2:]))' "$BIN/fleet-credsep.py" \
  /usr/sbin/cfprefsd /usr/libexec/lsd /System/Library/Frameworks/Contacts.framework/Support/contactsd \
  /bin/zsh /Users/x/.local/bin/claude /usr/bin/ssh git 2>&1)
case "$out" in "True True True False False False False") st_ok_all "N the OS's per-user agents are not a session; a shell, claude, ssh are" ;; *) st_miss "N os_agent: $out" ;; esac
out=$(bash "$BIN/fleet-credsep.sh" install --pool-src "$SB" 2>&1); rc=$?
case "$rc:$out" in 2:*"--pool-src is for a login just opened"*) st_ok_all "N --pool-src without --fresh: exit 2" ;; *) st_miss "N pool-src rc=$rc: $out" ;; esac
[ "$(snap)" = "$BEFORE" ] && [ ! -e "$R" ] && st_ok_all "N refusals changed nothing" || st_miss "N a refusal changed something"

# ── B: install ─────────────────────────────────────────────────────────────────
out=$(FLEET_CRED_SEPARATE=1 bash "$BIN/fleet-credsep.sh" apply 2>&1); rc=$?
[ "$rc" = 0 ] && case "$out" in "credsep: ok — shared: $ME — "*) true ;; *) false ;; esac \
  && grep -q '"shared": true' "$C/credsep.json" && grep -q '"mode": "shared"' "$R/meta.json" \
  && st_ok_all "B install via apply: a tenant of the machine's shared proxy — $out" || st_miss "B apply rc=$rc: $out"
same() { [ -f "$2" ] && [ "$(cksum < "$2")" = "$1" ]; }
ck() { cksum < "$1"; }
[ ! -e "$C/accounts/main.hub/.credentials.json" ] && grep -q sk-ant-oat01-MAIN "$R/accounts/main.hub/.credentials.json" \
  && st_ok_all "B claude credential moved into the store" || st_miss "B claude credential"
[ "$(cat "$C/accounts/main")" = "hub:main" ] && st_ok_all "B the label marker (no credential) stays" || st_miss "B marker"
[ ! -e "$HOME/.codex/auth.json" ] && grep -q at-DEFAULT "$R/codex/default/auth.json" \
  && [ ! -e "$HOME/.codex-accounts/work/auth.json" ] && grep -q at-WORK "$R/codex/work/auth.json" \
  && st_ok_all "B hub-managed codex auth.json moved (default + work)" || st_miss "B codex"
grep -q at-MINE "$HOME/.codex-accounts/mine/auth.json" && [ ! -e "$R/codex/mine" ] \
  && st_ok_all "B a personal codex login (own refresh token) stays put" || st_miss "B personal codex moved"
[ -L "$C/node.env" ] && [ "$(readlink "$C/node.env")" = "$R/node.env" ] && grep -q ccq_NODE_SECRET "$R/node.env" \
  && st_ok_all "B node.env → symlink into the store" || st_miss "B node.env"
grep -q '^CCQUOTA_HUB_URL=' "$C/node.pub.env" && ! grep -q TOKEN "$C/node.pub.env" \
  && st_ok_all "B node.pub.env: the token-less lines" || st_miss "B node.pub.env: $(cat "$C/node.pub.env")"
[ -f "$C/credsep.json" ] && [ -f "$SB/lib/fleet-credsep-launch.py" ] && [ -f "$SB/lib/fleet-cred-proxy.py" ] \
  && st_ok_all "B record + the code copy" || st_miss "B record/lib"
python3 - "$R/meta.json" "$SB/fake-agent" <<'PY' && st_ok_all "B meta: agent argv from run-agent.sh" || st_miss "B meta"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["agent_argv"][0] == sys.argv[2] and m["agent_argv"][1] == "agent", m
assert m["path"] == "/usr/bin:/bin", m
PY
if grep -q "^ExecStart=.*fleet-credsep-launch.py.* agent $ME\$" "$AGENT_DEF.d/credsep.conf" 2>/dev/null \
     && grep -q '^User=root$' "$AGENT_DEF.d/credsep.conf" \
   || python3 -c 'import plistlib,sys; p=plistlib.load(open(sys.argv[1],"rb")); sys.exit(0 if "UserName" not in p and p["ProgramArguments"][-2:]==["agent",sys.argv[2]] else 1)' "$AGENT_DEF" "$ME" 2>/dev/null; then
  st_ok_all "B the agent's service starts the launcher (root, no UserName)"
else st_miss "B agent service: $(cat "$AGENT_DEF" "$AGENT_DEF.d/credsep.conf" 2>/dev/null | head -20)"; fi
{ [ -e "$SB/daemons/com.claude-fleet.cred-proxy-shared.plist" ] || [ -e "$SB/daemons/claude-fleet-cred-proxy-shared.service" ]; } \
  && ! compgen -G "$SB/daemons/*credsep[.-]$ME*" >/dev/null \
  && st_ok_all "B the machine's shared proxy service is written; no proxy of the login's own (#4674)" \
  || st_miss "B proxy service: $(ls "$SB/daemons")"
out=$(FLEET_CRED_SEPARATE=1 bash "$BIN/fleet-credsep.sh" apply 2>&1)
case "$out" in "credsep: ok — shared"*) st_ok_all "B apply again: idempotent ($out)" ;; *) st_miss "B re-apply: $out" ;; esac
grep -q at-DEFAULT "$R/codex/default/auth.json" && [ -L "$C/node.env" ] && st_ok_all "B re-apply moved nothing twice" || st_miss "B re-apply damage"

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
  && st_ok_all "M the root agent logs to \$LOG_BASE/$ME/agent.log (dir 0700), not the home" || st_miss "M agent log=$lg dir mode=$mode"
out=$(rootlogs); rc=$?
case "$rc:$out" in "0:rootlog: OK"*) st_ok_all "M rootlogs after install: $out" ;; *) st_miss "M rootlogs rc=$rc: $out" ;; esac
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
case "$rc:$out" in 1:"rootlog: WARN"*"check --fix --login <login> for $ME"*) st_ok_all "M an old definition (log in the home) is WARN naming the fix" ;;
  *) st_miss "M old definition rc=$rc: $out" ;; esac
out=$(bash "$BIN/fleet-credsep.sh" check --fix 2>&1)
printf '%s' "$out" | grep -q "agent: log .*→ $SB/log/$ME/agent.log" && [ "$(agent_log_of)" = "$SB/log/$ME/agent.log" ] \
  && rootlogs | grep -q '^rootlog: OK' && st_ok_all "M check --fix moves the old definition's log out of the home" \
  || st_miss "M check --fix: $out / $(agent_log_of)"
out=$(bash "$BIN/fleet-credsep.sh" check --fix 2>&1)
printf '%s' "$out" | grep -q 'nothing to move' && st_ok_all "M check --fix again: nothing to move" || st_miss "M fix again: $out"
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
case "$rc:$out" in 1:"rootlog: WARN — 1 root service(s)"*"not the fleet's"*x.other*) st_ok_all "M a foreign root service logging in a home is named; a UserName one is not" ;;
  *) st_miss "M foreign rc=$rc: $out" ;; esac
# shellcheck disable=SC2086
rm -f $junk

# ── C: the machine's proxy, started by the shared launcher ───────────────────────
cat > "$SB/fake.py" <<'PY'
import json, os, sys
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
            d = {"cred": open(SB + "/hubpass").read().strip() if os.path.exists(SB + "/hubpass") else "", "id": "pass-sep"}
        else: d = {"ok": True}
        b = json.dumps(d).encode()
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = do_DELETE = any
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(SB + "/fake.port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -c 'import base64, json, time; n = int(time.time())
c = json.dumps({"v": 1, "id": "pass-sep", "iat": n, "exp": n + 3600}).encode()
print("fcp-h1." + base64.urlsafe_b64encode(c).rstrip(b"=").decode() + ".sig")' > "$SB/hubpass"
python3 "$SB/fake.py" "$SB" & echo $! > "$SB/fake.pid"
mkdir -p "$SB/evil"; python3 "$SB/fake.py" "$SB/evil" & echo $! > "$SB/evil.pid"
for _ in $(seq 1 300); do [ -s "$SB/fake.port" ] && break; sleep 0.1; done   # a slow runner: 30s
FP=$(cat "$SB/fake.port" 2>/dev/null)
[ -n "$FP" ] || { st_miss "C the fake far end never published its port"; }
sed -i.bak "s#^CCQUOTA_HUB_URL=.*#CCQUOTA_HUB_URL=http://127.0.0.1:$FP#" "$R/node.env" && rm -f "$R/node.env.bak"
# the upstreams come from root's settings only (issue #2290); install wrote the file
[ -f "$SB/lib/$ME.conf" ] && st_ok_all "C install wrote root's settings $SB/lib/$ME.conf" || st_miss "C no root settings file"
printf 'FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:%s\nFLEET_CRED_CODEX_URL=http://127.0.0.1:%s/codex\n' "$FP" "$FP" >> "$SB/lib/$ME.conf"
# the shared proxy's upstreams are the process's, the same for every tenant (the
# sandbox launcher hands its FLEET_CRED_* through)
export FLEET_CRED_ANTHROPIC_URL="http://127.0.0.1:$FP" FLEET_CRED_CODEX_URL="http://127.0.0.1:$FP/codex"
python3 -I "$BIN/fleet-credsep-launch.py" shared 2>"$SB/launch.err" &
LPID=$!
for _ in $(seq 1 300); do [ -S "$SR/ctl.sock" ] && [ -s "$SR/port" ] && break; sleep 0.1; done
PORT=$(cat "$SR/port" 2>/dev/null)
[ -n "$PORT" ] && st_ok_all "C the shared launcher started the machine's proxy (127.0.0.1:$PORT, run dir)" \
  || { st_miss "C proxy did not start: $(cat "$SB/launch.err")"; }
m=$(ls -l "$SR/ctl.sock" 2>/dev/null | cut -c1-10)
[ "$m" = srw-rw-rw- ] && st_ok_all "C ctl.sock 0666 (the peer-uid gate decides)" || st_miss "C ctl.sock mode $m"
m=$(ls -l "$SR/port" 2>/dev/null | cut -c1-10)
[ "$m" = -rw-r--r-- ] && st_ok_all "C port 0644 (the login is another uid)" || st_miss "C port mode $m"
[ "$(bash "$BIN/fleet-cred-proxy.sh" port 2>&1)" = "$PORT" ] && st_ok_all "C fleet-cred-proxy.sh port reads the run dir" \
  || st_miss "C port: $(bash "$BIN/fleet-cred-proxy.sh" port 2>&1)"
tok=$(bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid s1 2>&1)
code=$(curl -s --max-time 60 -o "$SB/c.body" -w '%{http_code}' -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/v1/messages")
grep -q "POST /v1/messages auth=Bearer sk-ant-oat01-MAIN" "$SB/fake.log" 2>/dev/null \
  && st_ok_all "C a session's request carries the credential from the store" \
  || st_miss "C direct: HTTP $code $(cat "$SB/c.body" 2>/dev/null) · fake saw: $(tail -3 "$SB/fake.log" 2>/dev/null)"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-RENEWED"}}' | bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label main
grep -rq RENEWED "$SB/db" && [ ! -e "$C/accounts/main.hub/.credentials.json" ] \
  && st_ok_all "C store: the agent's lease lands in the store (the shared pool), not the login" || st_miss "C store"
printf 'rp-PASS-1\n' | bash "$BIN/fleet-cred-proxy.sh" relay
[ "$(cat "$R/cred-proxy/relay.token" 2>/dev/null)" = rp-PASS-1 ] \
  && st_ok_all "C relay: the login's minted relay pass lands in the proxy's state" || st_miss "C relay pass"
printf 'x' | bash "$BIN/fleet-cred-proxy.sh" store --kind claude --label ../evil 2>/dev/null \
  && st_miss "C store accepted ../evil" || st_ok_all "C store refuses a path-like label"

# ── D: the hub broker ─────────────────────────────────────────────────────────
pair=$(bash "$BIN/fleet-cred-proxy.sh" node-token 2>&1)
burl=${pair%%	*} btok=${pair#*	}
case "$btok" in fcpn1.*) st_ok_all "D node-token: $burl + fcpn1." ;; *) st_miss "D node-token: $pair" ;; esac
: > "$SB/fake.log"
code=$(curl -s --max-time 60 -o "$SB/d.body" -w '%{http_code}' -H "Authorization: Bearer $btok" "$burl/v1/node/self")
grep -q "GET /v1/node/self auth=Bearer ccq_NODE_SECRET_0123" "$SB/fake.log" \
  && st_ok_all "D broker: the node token is put in on the way out" \
  || st_miss "D broker fwd: HTTP $code $(cat "$SB/d.body" 2>/dev/null) · fake saw: $(cat "$SB/fake.log")"
: > "$SB/fake.log"
for p in /v1/node/credentials /v1/node/credentials/ //v1/node/credentials /v1/node/./credentials /v1/node/%63redentials /V1/NODE/CREDENTIALS; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $btok" "$burl$p")
  [ "$c" = 403 ] || { st_miss "D broker let $p through ($c)"; }
done
[ ! -s "$SB/fake.log" ] && st_ok_all "D broker: /v1/node/credentials refused in every spelling, the hub never asked" \
  || st_miss "D the hub saw: $(cat "$SB/fake.log")"
c=$(curl -s -o "$SB/d.body" -w '%{http_code}' "$burl/v1/node/self")
# issue #4906: say «no credential», never «names no login» — ccquota's tokenless
# viewer-door ask read as a login problem on every EPIC tick
[ "$c" = 401 ] && grep -q "no node credential on the request" "$SB/d.body" \
  && st_ok_all "D broker: no credential → 401 that says so" || st_miss "D no cred → $c $(cat "$SB/d.body")"
c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" "$burl/v1/node/self")
[ "$c" = 401 ] && st_ok_all "D broker: a session credential (fcp1.) is not a node credential" || st_miss "D fcp1 → $c"
want=$(printf 'ccq_NODE_SECRET_0123' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
[ "$(bash "$BIN/fleet-cred-proxy.sh" node-hash)" = "$want" ] && st_ok_all "D node-hash = sha256(node token)" || st_miss "D node-hash"
# a session's view: node.env unreadable (here: a dangling link) + the record
S="$SB/session-conf"; mkdir -p "$S"; ln -s "$SB/nowhere/node.env" "$S/node.env"
cp "$C/credsep.json" "$C/node.pub.env" "$S/"
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_node_env_val CCQUOTA_TOKEN")
case "$v" in fcpn1.*) st_ok_all "D fleet-lib: _fleet_node_env_val CCQUOTA_TOKEN → the broker's credential" ;; *) st_miss "D lib token: '$v'" ;; esac
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_node_env_val CCQUOTA_FLEET")
[ "$v" = 1 ] && st_ok_all "D fleet-lib: other keys from node.pub.env" || st_miss "D lib key: '$v'"
v=$(FLEET_CONF_DIR="$S" bash -c ". '$BIN/fleet-lib.sh'; _fleet_hub_env; printf '%s %s' \"\$CCQUOTA_HUB_URL\" \"\${CCQUOTA_TOKEN%%.*}\"")
[ "$v" = "$burl fcpn1" ] && st_ok_all "D fleet-lib: _fleet_hub_env exports the broker PAIR" || st_miss "D hub_env: '$v'"
# a central session on a separated login (issue #2392): fleet-session-cred.sh's
# hub pass rides the broker too — before, it read node.env, found nothing and
# `fleet claude` refused to launch ("central route: no hub / node token")
echo untrusted > "$SB/trust"
FLEET_CONF_DIR="$S" bash "$BIN/fleet-cred-proxy.sh" route --provider claude --refresh >/dev/null 2>&1
: > "$SB/fake.log"
row=$(FLEET_CONF_DIR="$S" FLEET_CRED_PROXY=1 FLEET_WORKER_ASSERT=fwa1.test.sig \
      bash "$BIN/fleet-session-cred.sh" mint --provider claude --sid sep1 2>"$SB/d.err")
case "$row" in central"	"*"	"*) st_ok_all "D session-cred: a central pass on a separated login" ;;
  *) st_miss "D session-cred mint: '$row' $(cat "$SB/d.err")" ;; esac
grep -q "POST /v1/fleet/session-cred auth=Bearer ccq_NODE_SECRET_0123" "$SB/fake.log" \
  && st_ok_all "D session-cred: the pass request went through the broker (node token put in)" \
  || st_miss "D session-cred: the hub saw: $(cat "$SB/fake.log")"
FLEET_CONF_DIR="$S" bash "$BIN/fleet-session-cred.sh" revoke --sid sep1
grep -q "DELETE /v1/fleet/session-cred/pass-sep auth=Bearer ccq_NODE_SECRET_0123" "$SB/fake.log" \
  && st_ok_all "D session-cred: revoke DELETEs the pass through the broker" \
  || st_miss "D session-cred revoke: the hub saw: $(cat "$SB/fake.log")"
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
  && st_ok_all "E ctl refuses a peer that is not the login's uid" || st_miss "E ctl answered uid $(id -u): $out"
kill "$P2" 2>/dev/null; P2=''

# ── F: the agent's launch ────────────────────────────────────────────────────────
python3 -I "$BIN/fleet-credsep-launch.py" agent "$ME" 2>"$SB/agent.err"
grep -q '^fd3=ccq_NODE_SECRET_0123$' "$HOME/agent.out" && grep -q '^envhits=0$' "$HOME/agent.out" \
  && grep -q "^store=$SR/ctl.sock$" "$HOME/agent.out" \
  && st_ok_all "F agent: token on fd 3, not in its environment; the store socket handed over" \
  || st_miss "F agent: $(cat "$HOME/agent.out" "$SB/agent.err" 2>/dev/null)"
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
  && st_ok_all "F2 agents: this login's ccquota agents listed, the machine's node program not" \
  || st_miss "F2 agents ($STRAY $OTHER, not $MACH): $out"
python3 -I "$BIN/fleet-credsep-launch.py" agent "$ME" 2>"$SB/agent.err"
sleep 0.2
gone() { ! kill -0 "$1" 2>/dev/null || ps -o stat= -p "$1" 2>/dev/null | grep -q '^Z'; }
if gone "$STRAY" && ! gone "$OTHER" && ! gone "$MACH" && grep -q '^fd3=ccq_NODE_SECRET_0123$' "$HOME/agent.out" \
   && grep -q "stopped a stray agent pid $STRAY" "$SB/agent.err"; then
  st_ok_all "F2 launcher: the stray agent on the same --state stopped before the new one ran; another state and --machine untouched"
else st_miss "F2 launcher: stray=$STRAY $(gone "$STRAY" && echo gone) other=$(gone "$OTHER" && echo gone) mach=$(gone "$MACH" && echo gone) · $(cat "$SB/agent.err")"; fi
kill "$STRAY" "$OTHER" "$MACH" 2>/dev/null; wait "$STRAY" "$OTHER" "$MACH" 2>/dev/null
rm -f "$HOME/agent.out"

# ── I: the login-readable record ─────────────────────────────────────────────
grep -q 'sk-ant-\|ccq_\|at-WORK' "$C/credsep.json" && st_miss "I credsep.json holds a credential" || st_ok_all "I credsep.json: paths only"

# ── J: plan ──────────────────────────────────────────────────────────────────────
mkdir -p "$SB/homes/ann/.claude/fleet/bin" "$SB/homes/bob" && : > "$SB/homes/ann/.claude/fleet/bin/fleet-credsep.sh"
printf 'ann:%s\nbob:%s\nroot:/var/root\n' "$SB/homes/ann" "$SB/homes/bob" > "$SB/users"
out=$(FLEET_CREDSEP_HOMES="$SB/homes" FLEET_CREDSEP_USERS="$SB/users" bash "$BIN/fleet-credsep.sh" plan 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "sudo bash $SB/homes/ann/.claude/fleet/bin/fleet-credsep.sh install --login ann" \
   && printf '%s' "$out" | grep -qF "sudo -u ann env HOME=$SB/homes/ann bash" \
   && ! printf '%s' "$out" | grep -q '^bob\|^root'; then
  st_ok_all "J plan: one block per login with an install, the one sudo carries --login"
else st_miss "J plan rc=$rc: $out"; fi

# ── K: a login name may start with a digit (issue #2257) ───────────────────────
mkdir -p "$SB/homes/24acme/.config/claude-fleet"
printf '24acme:%s:%s:%s\n' "$(id -u)" "$(id -g)" "$SB/homes/24acme" > "$SB/pw"
out=$(FLEET_CREDSEP_PW="$SB/pw" bash "$BIN/fleet-credsep.sh" machine install --dry-run --logins 24acme 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^== 24acme' && [ ! -e "$SB/db/24acme" ]; then
  st_ok_all "K machine install --dry-run accepts 24acme"
else st_miss "K 24acme rc=$rc: $out"; fi
for bad in 'Bad Name' '-x' 'a/b'; do
  out=$(FLEET_CREDSEP_PW="$SB/pw" bash "$BIN/fleet-credsep.sh" machine install --dry-run "--logins=$bad" 2>&1); rc=$?
  case "$rc:$out" in 2:*"bad login"*) st_ok_all "K '$bad' still refused (exit 2)" ;; *) st_miss "K '$bad' rc=$rc: $out" ;; esac
done

# ── L: the login's own files cannot move an upstream or the hub (issue #2290) ──
for _ in $(seq 1 300); do [ -s "$SB/evil/fake.port" ] && break; sleep 0.1; done
EP=$(cat "$SB/evil/fake.port" 2>/dev/null)
cp "$R/node.env" "$SB/node.env.keep"
grep -v '^CCQUOTA_HUB_URL=' "$SB/node.env.keep" > "$R/node.env"   # the hub would come from FLEET_HUB_URL
printf 'FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:%s\nFLEET_CRED_CODEX_URL=http://127.0.0.1:%s/codex\nFLEET_CRED_CENTRAL_URL=http://127.0.0.1:%s\nFLEET_HUB_URL=http://127.0.0.1:%s\nFLEET_CRED_PROXY_TIMEOUT=30\n' \
  "$EP" "$EP" "$EP" "$EP" >> "$C/fleet.conf"
kill "$(cat "$SR/pid" 2>/dev/null)" 2>/dev/null; kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
rm -f "$SR/port"
python3 -I "$BIN/fleet-credsep-launch.py" shared 2>"$SB/launch.err" &
LPID=$!
for _ in $(seq 1 300); do [ -s "$SR/port" ] && break; sleep 0.1; done
PORT=$(cat "$SR/port" 2>/dev/null)
: > "$SB/fake.log"
tok=$(bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid s2 2>&1)
curl -s --max-time 60 -o /dev/null -H "Authorization: Bearer $tok" -H 'content-type: application/json' -d '{}' "http://127.0.0.1:$PORT/v1/messages"
[ -n "$EP" ] && [ ! -s "$SB/evil/fake.log" ] && grep -q 'POST /v1/messages' "$SB/fake.log" \
  && st_ok_all "L a login-file upstream / FLEET_HUB_URL: never asked, root's upstream served it" \
  || st_miss "L the login's listener saw: $(cat "$SB/evil/fake.log" 2>/dev/null) · root's: $(cat "$SB/fake.log") · $(cat "$SB/launch.err")"
grep -q "ignored FLEET_CRED_ANTHROPIC_URL from $C/fleet.conf" "$SB/launch.err" && grep -q 'ignored FLEET_HUB_URL' "$SB/launch.err" \
  && grep -q '^FLEET_HUB_URL ' "$SR/ignored.$ME" && ! grep -q 'PROXY_TIMEOUT\|127.0.0.1' "$SR/ignored.$ME" \
  && st_ok_all "L the launcher says what it ignored (key names, no value) for credsep check" \
  || st_miss "L ignored note: $(cat "$SB/launch.err" "$SR/ignored.$ME" 2>&1)"
cp "$SB/node.env.keep" "$R/node.env"
# install --adopt: root takes the login's values — an https URL to an allowed host only
OLDHUB=https://hub.example.com
printf 'FLEET_CRED_ALLOW_HOSTS=hub.example.com\n' >> "$SB/lib/$ME.conf"   # root's own word allows it
printf 'FLEET_HUB_URL=%s\nFLEET_CRED_RELAY_URL=https://evil.example/relay\nFLEET_CRED_ALLOW_HOSTS=evil.example\n' "$OLDHUB" > "$C/fleet.conf"
out=$(bash "$BIN/fleet-credsep.sh" install --adopt 2>&1); rc=$?
if [ "$rc" = 0 ] && grep -qx "FLEET_HUB_URL=$OLDHUB" "$SB/lib/$ME.conf" \
   && ! grep -q evil "$SB/lib/$ME.conf" && grep -q "^FLEET_CRED_ANTHROPIC_URL=http://127.0.0.1:$FP\$" "$SB/lib/$ME.conf"; then
  st_ok_all "L install --adopt: the allowed hub taken, evil.example and ALLOW_HOSTS refused, root's other lines kept"
else st_miss "L adopt rc=$rc: $out · $(cat "$SB/lib/$ME.conf")"; fi
m=$(ls -l "$SB/lib/$ME.conf" | cut -c1-10)
[ "$m" = -rw------- ] && st_ok_all "L root's settings 0600 (a relay pass may be in it)" || st_miss "L root conf mode $m"

# ── G: no way back (issue #4675) ─────────────────────────────────────────────
kill "$(cat "$SR/pid" 2>/dev/null)" 2>/dev/null; kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null; LPID=''
STORE_BEFORE=$(cd "$SB" && find db -type f 2>/dev/null | LC_ALL=C sort)
out=$(bash "$BIN/fleet-credsep.sh" uninstall 2>&1); rc=$?
case "$rc:$out" in "2:"*"uninstall is gone (issue #4675)"*) st_ok_all "G uninstall: gone (exit 2)" ;; *) st_miss "G uninstall rc=$rc: $out" ;; esac
out=$(bash "$BIN/fleet-credsep.sh" machine uninstall 2>&1); rc=$?
case "$rc:$out" in "2:"*"machine uninstall is gone (issue #4675)"*) st_ok_all "G machine uninstall: gone (exit 2)" ;; *) st_miss "G machine uninstall rc=$rc: $out" ;; esac
out=$(FLEET_CREDSEP_TEST=1 python3 -I "$BIN/fleet-credsep.py" uninstall --login "$ME" --conf-dir "$C" 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -q "invalid choice: 'uninstall'" \
  && st_ok_all "G fleet-credsep.py has no uninstall (exit 2, T600)" || st_miss "G py uninstall rc=$rc: $out"
STORE_AFTER=$(cd "$SB" && find db -type f 2>/dev/null | LC_ALL=C sort)
if [ "$STORE_AFTER" = "$STORE_BEFORE" ] && [ -f "$R/node.env" ] && [ -L "$C/node.env" ] && [ -e "$C/credsep.json" ] \
   && [ ! -e "$C/accounts/main.hub/.credentials.json" ] && [ ! -e "$HOME/.codex-accounts/work/auth.json" ]; then
  st_ok_all "G every credential still in the store, none back in the home"
else st_miss "G something moved: $(diff <(printf '%s\n' "$STORE_BEFORE") <(printf '%s\n' "$STORE_AFTER"))"; fi

st_done
