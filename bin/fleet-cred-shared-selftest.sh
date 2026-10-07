#!/usr/bin/env bash
# fleet-cred-shared-selftest.sh — the machine's ONE shared credential proxy
# (issue #2217), in a sandbox: bin/fleet-credsep.sh machine … +
# fleet-credsep.py + fleet-credsep-launch.py shared + fleet-cred-proxy.py
# serve --shared + fleet-cred-proxy.sh / fleet-cred-rollout.sh --machine, with
# every root path under a temp dir (FLEET_CREDSEP_* seams), no sudo, no
# launchctl / systemctl, and TWO logins played on this one real user
# (FLEET_CREDSEP_PW: alpha = this uid, beta = a uid nobody has; the proxy's
# FLEET_CRED_SHARED_TEST seam lets a control call say it is beta's uid — the
# kernel's peer uid is what decides everywhere else). The OS half — the role
# account, a session that gets "Permission denied" on the store — is the
# issue's on-machine evidence, not this.
#
#   A  no shared proxy: `machine status` says per-login (exit 3), `status
#      --machine` says per-login, nothing is written — the degenerate case
#   B  machine install --logins alpha,beta: both stores, credentials moved,
#      alpha's own proxy key moved (not copied), FLEET_CRED_PROXY=1 in each
#      fleet.conf, credsep.json `shared`, ONE service file, the record
#   C  the launcher starts ONE proxy for both: alpha's and beta's sessions each
#      reach their OWN credential; the audit (each login's log) is each login's
#   D  isolation: alpha cannot mint as beta (--as), a token re-labelled to
#      beta fails the signature, beta's token on alpha's old port is refused,
#      an unknown uid is refused, a hub pass is only the login's that filed it
#   E  alpha's per-login proxy hands over: a session minted BEFORE the switch
#      keeps working on its old port, through the shared proxy, alpha's account
#   F  `status --machine` / the doctor's `cred` row: shared · user · k/N · a/b
#   G  machine uninstall: every fleet.conf, credential and key byte for byte
#      where it was; the record, the store and the service gone
#   H  a half install (issue #2273: the store and its meta.json, no credsep.json):
#      `uninstall --dry-run` says HALF INSTALLED, not "nothing to undo", and
#      `uninstall --login beta` puts it back byte for byte from meta.json
#   I  machine install whose agent bootstrap fails AND whose way back fails too:
#      exit 5, the credentials back anyway, the store kept as <login>.rolledback-*,
#      the steps to do by hand printed (the clean rollback is BREAK-IT
#      `cred-sep-bootstrap-fails`)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d "/tmp/credshared-st.XXXXXX")
ME=$(id -un); MYUID=$(id -u); MYGID=$(id -g); BUID=1999991
cleanup() {
  for f in "$SB/shared.pid" "$SB/alpha-own.pid" "$SB/fake.pid"; do kill "$(cat "$f" 2>/dev/null)" 2>/dev/null; done
  kill "$(cat "$SB/run/.shared/pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export FLEET_CREDSEP_ROOT_BASE="$SB/db" FLEET_CREDSEP_RUN_BASE="$SB/run" FLEET_CREDSEP_LOG_BASE="$SB/log" \
       FLEET_CREDSEP_LIB="$SB/lib" FLEET_CREDSEP_DAEMON_DIR="$SB/daemons" FLEET_CREDSEP_ROLE="$ME" \
       FLEET_CREDSEP_SVC=0 FLEET_CREDSEP_TEST=1 FLEET_CREDSEP_PREFLIGHT=0 FLEET_CREDSEP_SUDO='' \
       FLEET_CREDSEP_PW="$SB/pw" FLEET_CREDSEP_USERS="$SB/users" FLEET_CREDSEP_HOMES="$SB/homes"
unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_CRED_SEPARATE FLEET_CRED_PROXY FLEET_CRED_AS
FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
export FLEET_CRED_SHARED_PORT; FLEET_CRED_SHARED_PORT=$(freeport)
mkdir -p "$SB/daemons"

# ── the far end: echoes which credential it was handed ──────────────────────────
cat > "$SB/fake.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        b = json.dumps({"auth": self.headers.get("authorization", "")}).encode()
        self.send_response(200); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    do_GET = do_POST = any
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$SB/fake.py" "$SB/fake.port" & echo $! > "$SB/fake.pid"
for _ in $(seq 1 300); do [ -s "$SB/fake.port" ] && break; sleep 0.1; done
FP=$(cat "$SB/fake.port")
export FLEET_CRED_ANTHROPIC_URL="http://127.0.0.1:$FP"

# ── two logins, as a node leaves them today ─────────────────────────────────────
printf 'alpha:%s:%s:%s\nbeta:%s:%s:%s\n' "$MYUID" "$MYGID" "$SB/homes/alpha" "$BUID" "$MYGID" "$SB/homes/beta" > "$SB/pw"
printf 'alpha:%s\nbeta:%s\n' "$SB/homes/alpha" "$SB/homes/beta" > "$SB/users"
for L in alpha beta; do
  H="$SB/homes/$L"; C="$H/.config/claude-fleet"
  mkdir -p "$C/accounts/main.hub" "$H/.claude/fleet/bin"
  : > "$H/.claude/fleet/bin/fleet-credsep.sh"
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-%s","refreshToken":null,"expiresAt":4102444800000}}' "$L" \
    > "$C/accounts/main.hub/.credentials.json"
  printf 'hub:main\n' > "$C/accounts/main"
  printf '# claude-fleet\n# ---- [common] ----\nexport FLEET_HOST=1\n' > "$C/fleet.conf"
done
CA="$SB/homes/alpha/.config/claude-fleet" CB="$SB/homes/beta/.config/claude-fleet"
printf 'export FLEET_CRED_PROXY=0\n' >> "$CB/fleet.conf"     # beta had the switch spelled off

# alpha already runs a proxy of its own (the per-login one) and a session on it
FLEET_CONF_DIR="$CA" python3 -I "$BIN/fleet-cred-proxy.py" --state "$CA/cred-proxy" serve \
  --log "$SB/alpha-own.log" 2>/dev/null & echo $! > "$SB/alpha-own.pid"
for _ in $(seq 1 300); do [ -S "$CA/cred-proxy/ctl.sock" ] && [ -s "$CA/cred-proxy/port" ] && break; sleep 0.1; done
OLDPORT=$(cat "$CA/cred-proxy/port")
T0=$(FLEET_CONF_DIR="$CA" python3 -I "$BIN/fleet-cred-proxy.py" --state "$CA/cred-proxy" mint --account main --sid old1)
case "$T0" in fcp1.*) pass "setup: alpha's own proxy on :$OLDPORT, a session minted on it" ;; *) fail "setup: $T0" ;; esac

snap() { # every file of both logins: path + bytes
  (cd "$SB/homes" && find . -path '*/cred-proxy/*' -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
     printf '%s %s\n' "$f" "$(cksum < "$f")"; done)
}
BEFORE=$(snap); KEY0=$(cksum < "$CA/cred-proxy/key")
call() { # <port> <token> → the far end's view of the credential
  curl -s -m 10 -H "Authorization: Bearer $2" -H 'content-type: application/json' -d '{}' \
    "http://127.0.0.1:$1/v1/messages"
}

# ── A: no shared proxy ⇒ per-login, nothing written ─────────────────────────────
out=$(bash "$BIN/fleet-credsep.sh" machine status 2>&1); rc=$?
[ "$rc" = 3 ] && [ "$out" = "per-login (no shared proxy on this machine)" ] \
  && pass "A machine status: per-login, exit 3" || fail "A machine status rc=$rc: $out"
out=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-rollout.sh" status --machine 2>&1)
case "$out" in "per-login · no shared proxy · 2 login(s) with a fleet install") pass "A status --machine: $out" ;;
  *) fail "A status --machine: $out" ;; esac
[ ! -e "$SB/db" ] && [ "$(snap)" = "$BEFORE" ] && pass "A nothing written" || fail "A something written"

# ── B: one install for the machine ──────────────────────────────────────────────
out=$(bash "$BIN/fleet-credsep.sh" machine install --logins alpha,beta 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "^shared: ON — .* 2 login(s): alpha, beta" \
  && pass "B machine install: $(printf '%s' "$out" | tail -n 1)" || fail "B install rc=$rc: $out"
for L in alpha beta; do
  C="$SB/homes/$L/.config/claude-fleet"; R="$SB/db/$L"
  [ ! -e "$C/accounts/main.hub/.credentials.json" ] && grep -q "sk-ant-oat01-$L" "$R/accounts/main.hub/.credentials.json" \
    && pass "B $L: credential moved into its store" || fail "B $L: credential"
  grep -q '^export FLEET_CRED_PROXY=1$' "$C/fleet.conf" && [ "$(grep -c FLEET_CRED_PROXY "$C/fleet.conf")" = 1 ] \
    && pass "B $L: FLEET_CRED_PROXY=1 (one line)" || fail "B $L fleet.conf: $(cat "$C/fleet.conf")"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r.get("shared") and r["run"].endswith("/.shared") else 1)' \
    "$C/credsep.json" && pass "B $L: credsep.json says shared" || fail "B $L credsep.json"
done
[ ! -e "$CA/cred-proxy/key" ] && [ "$(cksum < "$SB/db/alpha/cred-proxy/key")" = "$KEY0" ] \
  && pass "B alpha's signing key MOVED into the store (no copy left to forge with)" || fail "B alpha key"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); sys.exit(0 if m["legacy_port"]==int(sys.argv[2]) else 1)' \
  "$SB/db/alpha/meta.json" "$OLDPORT" && pass "B alpha's old port :$OLDPORT recorded" || fail "B legacy port"
n=0; per=0
for f in "$SB/daemons"/*; do case "${f##*/}" in *cred-proxy-shared*) n=$((n + 1)) ;; *credsep.*) per=$((per + 1)) ;; esac; done
[ "$n" = 1 ] && [ "$per" = 0 ] && pass "B ONE service for the machine, none per login" || fail "B services: $(ls "$SB/daemons")"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r["logins"]==["alpha","beta"] and r["port"]==int(sys.argv[2]) else 1)' \
  "$SB/db/.shared.json" "$FLEET_CRED_SHARED_PORT" && pass "B the record: both logins, the fixed port" || fail "B record"

# alpha's own launcher would let go of the port now: its proxy stops
kill "$(cat "$SB/alpha-own.pid")" 2>/dev/null

# ── C: one proxy, each login its own ─────────────────────────────────────────────
python3 -I "$SB/lib/fleet-credsep-launch.py" shared 2>"$SB/launch.err" & echo $! > "$SB/shared.pid"
for _ in $(seq 1 300); do [ -S "$SB/run/.shared/ctl.sock" ] && [ -s "$SB/run/.shared/port" ] && break; sleep 0.1; done
PORT=$(cat "$SB/run/.shared/port" 2>/dev/null)
[ "$PORT" = "$FLEET_CRED_SHARED_PORT" ] && pass "C the shared proxy on the fixed port :$PORT" \
  || fail "C did not start ($PORT): $(cat "$SB/launch.err")"
m=$(ls -l "$SB/run/.shared/ctl.sock" | cut -c1-10); t=$(ls -l "$SB/db/.shared/tenants.json" | cut -c1-10)
[ "$m" = srw-rw-rw- ] && [ "$t" = -rw------- ] && pass "C ctl.sock 0666 (the peer uid decides), tenants.json 0600" \
  || fail "C modes $m $t"
for L in alpha beta; do [ "$(FLEET_CONF_DIR="$SB/homes/$L/.config/claude-fleet" bash "$BIN/fleet-cred-proxy.sh" port)" = "$PORT" ] \
  || fail "C $L: port"; done
TA=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid a1 --wrap $$ 2>&1)
TB=$(FLEET_CRED_TEST_PEER_UID=$BUID FLEET_CONF_DIR="$CB" bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid b1 --wrap $$ 2>&1)
case "$TA:$TB" in fcp1.*:fcp1.*) pass "C each login mints on the one socket" ;; *) fail "C mint: $TA / $TB" ;; esac
ra=$(call "$PORT" "$TA"); rb=$(call "$PORT" "$TB")
case "$ra" in *sk-ant-oat01-alpha*) pass "C alpha's session → alpha's credential" ;; *) fail "C alpha: $ra" ;; esac
case "$rb" in *sk-ant-oat01-beta*) pass "C beta's session → beta's credential" ;; *) fail "C beta: $rb" ;; esac
grep -q '"sid": "a1"' "$SB/log/alpha.log" && ! grep -q '"sid": "b1"' "$SB/log/alpha.log" \
  && grep -q '"sid": "b1"' "$SB/log/beta.log" && ! grep -q '"sid": "a1"' "$SB/log/beta.log" \
  && pass "C the audit is each login's own (log/alpha.log, log/beta.log)" || fail "C logs"
! grep -q 'sk-ant-' "$SB/log/alpha.log" "$SB/log/beta.log" "$SB/log/shared.log" 2>/dev/null \
  && pass "C no credential in any log" || fail "C a credential leaked into a log"

# ── D: no login reaches another's ────────────────────────────────────────────────
out=$(FLEET_CRED_AS=beta FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid x 2>&1); rc=$?
[ "$rc" != 0 ] && case "$out" in *"not your login"*) true ;; *) false ;; esac \
  && pass "D alpha asking as beta: refused ($out)" || fail "D --as beta rc=$rc: $out"
out=$(FLEET_CRED_TEST_PEER_UID=4242 FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" mint --account main --sid x 2>&1); rc=$?
[ "$rc" != 0 ] && case "$out" in *"has not joined"*) true ;; *) false ;; esac \
  && pass "D an unknown uid: refused" || fail "D unknown uid rc=$rc: $out"
FORGED=$(python3 - "$TA" <<'PY'
import base64, json, sys
t, p, s = sys.argv[1].split(".")
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
c["lg"] = "beta"
print(".".join([t, base64.urlsafe_b64encode(json.dumps(c, separators=(",", ":")).encode()).rstrip(b"=").decode(), s]))
PY
)
case "$(call "$PORT" "$FORGED")" in *"bad signature"*) pass "D alpha's token re-labelled to beta: bad signature" ;;
  *) fail "D forged: $(call "$PORT" "$FORGED")" ;; esac
for _ in $(seq 1 100); do grep -q legacy_port "$SB/log/alpha.log" 2>/dev/null && break; sleep 0.1; done
case "$(call "$OLDPORT" "$TB")" in *sk-ant*) fail "D beta's token on alpha's old port was served" ;;
  *) pass "D beta's token on alpha's old port: refused" ;; esac
HP=$(python3 -c 'import base64,json,time; e=lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode(); print("fcp-h1."+e(json.dumps({"id":"pass-b","exp":int(time.time())+3600}).encode())+".sig")')
case "$(call "$PORT" "$HP")" in *"not registered"*) pass "D an unregistered hub pass: 401" ;; *) fail "D hub pass: $(call "$PORT" "$HP")" ;; esac
printf '%s\n' "$HP" | FLEET_CRED_TEST_PEER_UID=$BUID FLEET_CONF_DIR="$CB" bash "$BIN/fleet-cred-proxy.sh" pass >/dev/null 2>&1
call "$PORT" "$HP" >/dev/null
grep -q '"sid": "h-' "$SB/log/beta.log" && ! grep -q '"sid": "h-' "$SB/log/alpha.log" \
  && pass "D a hub pass beta filed is beta's (its log, its renewal)" || fail "D hub pass not beta's"

# ── E: alpha's session from BEFORE the switch, on its old port ────────────────────
ro=$(call "$OLDPORT" "$T0")
case "$ro" in *sk-ant-oat01-alpha*) pass "E a session minted on alpha's own proxy keeps working on :$OLDPORT (shared, alpha's account)" ;;
  *) fail "E old session: $ro" ;; esac

# ── F: the person's line and the doctor row ──────────────────────────────────────
printf 'claude\tx\nclaude\tx\ncodex\tx\nzsh\tx\n' > "$SB/procs"
out=$(FLEET_CRED_ROLLOUT_PROCS="$SB/procs" FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-rollout.sh" status --machine 2>&1)
case "$out" in "shared · $ME · on 2/2 logins · sessions 3/3") pass "F status --machine: $out" ;;
  *) fail "F status --machine: $out" ;; esac
out=$(FLEET_CRED_PROXY=1 FLEET_CONF_DIR="$CA" bash "$BIN/fleet-cred-proxy.sh" doctor 2>&1)
case "$out" in *"shared 全机共享（$ME 跑，2 个登录，版本 "*) pass "F doctor cred row: shared, $ME, 2 logins, the version" ;;
  *) fail "F doctor: $out" ;; esac
out=$(FLEET_CONF_DIR="$CA" bash "$BIN/fleet-credsep.sh" apply 2>&1)
case "$out" in "credsep: ok — shared · shared: current"*) pass "F the sync pass leaves a tenant alone, keeps the code current" ;;
  *) fail "F apply: $out" ;; esac

# ── G: the way back, byte for byte ────────────────────────────────────────────────
kill "$(cat "$SB/shared.pid")" 2>/dev/null; sleep 0.3
out=$(bash "$BIN/fleet-credsep.sh" machine uninstall 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^shared: OFF' && pass "G machine uninstall" || fail "G rc=$rc: $out"
rm -f "$CA/cred-proxy/"*.json "$CA/cred-proxy/revoked" 2>/dev/null   # the copies it made, not the login's own files
[ "$(snap)" = "$BEFORE" ] && pass "G every fleet.conf and credential byte for byte" \
  || fail "G differs: $(diff <(printf '%s\n' "$BEFORE") <(snap) | head -6)"
[ "$(cksum < "$CA/cred-proxy/key" 2>/dev/null)" = "$KEY0" ] && pass "G alpha's key back: its own proxy verifies the old sessions" \
  || fail "G key"
[ ! -e "$SB/db/.shared.json" ] && [ ! -e "$SB/db/alpha" ] && [ ! -e "$SB/db/beta" ] && [ -z "$(ls "$SB/daemons")" ] \
  && pass "G the record, the stores and the service gone" || fail "G leftovers: $(ls -a "$SB/db" "$SB/daemons" 2>&1 | tr '\n' ' ')"

# ── H: a half install is undone from meta.json ─────────────────────────────────────
out=$(bash "$BIN/fleet-credsep.sh" machine install --logins beta 2>&1) || fail "H setup install: $out"
rm -f "$CB/credsep.json"                       # the install stopped before its last step
chmod 000 "$SB/db/beta/meta.json"              # as the login sees it: the store is not readable
out=$(HOME="$SB/homes/beta" python3 -I "$BIN/fleet-credsep.py" uninstall --dry-run --login beta --conf-dir "$CB" 2>&1)
chmod 600 "$SB/db/beta/meta.json"
case "$out" in *"HALF INSTALLED"*"uninstall --login beta"*) pass "H dry run names the half install and the one line" ;;
  *) fail "H dry run: $out" ;; esac
out=$(HOME="$SB/homes/beta" python3 -I "$BIN/fleet-credsep.py" uninstall --login beta --conf-dir "$CB" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(snap)" = "$BEFORE" ] && [ ! -e "$SB/db/beta" ] \
  && pass "H uninstall from meta.json alone: beta byte for byte" \
  || fail "H rc=$rc: $(diff <(printf '%s\n' "$BEFORE") <(snap) | head -4) $(printf '%s' "$out" | tail -2)"
bash "$BIN/fleet-credsep.sh" machine uninstall >/dev/null 2>&1

# ── I: the way back fails too: say so, keep the store, print the steps ──────────────
mkdir -p "$SB/shim"
cat > "$SB/shim/launchctl" <<'EOF'
#!/bin/sh
case "$1" in print) exit 113 ;; bootstrap) echo "Bootstrap failed: 5: Input/output error"; exit 5 ;; esac
exit 0
EOF
cat > "$SB/shim/systemctl" <<'EOF'
#!/bin/sh
case "$*" in *ccquota-agent-*) case "$1" in enable|restart) echo "Job failed"; exit 5 ;; esac ;; esac
exit 0
EOF
chmod +x "$SB/shim/launchctl" "$SB/shim/systemctl"
printf '#!/bin/sh\nexec /bin/sleep 1\n' > "$SB/homes/beta/run-agent.sh"; chmod +x "$SB/homes/beta/run-agent.sh"
if [ "$(uname)" = Darwin ]; then AG="$SB/daemons/com.ccquota.agent.beta.plist"
  python3 -c 'import plistlib, sys; open(sys.argv[1], "wb").write(plistlib.dumps({"Label": "com.ccquota.agent.beta",
"ProgramArguments": [sys.argv[2]], "RunAtLoad": True}))' "$AG" "$SB/homes/beta/run-agent.sh"
else AG="$SB/daemons/ccquota-agent-beta.service"; printf '[Service]\nExecStart=%s\n' "$SB/homes/beta/run-agent.sh" > "$AG"; fi
AG0=$(cksum < "$AG")
out=$(PATH="$SB/shim:$PATH" FLEET_CREDSEP_SVC=1 FLEET_CREDSEP_BOOT_TRIES=1 bash "$BIN/fleet-credsep.sh" machine install --logins beta 2>&1); rc=$?
[ "$rc" = 5 ] && printf '%s' "$out" | grep -q 'rollback: beta — FAILED at' \
  && printf '%s' "$out" | grep -q 'rollback INCOMPLETE' \
  && printf '%s' "$out" | grep -Eq '^  [0-9]+\. .*(launchctl bootstrap system|systemctl restart)' \
  && pass "I the way back failed: exit 5, the manual steps printed" || fail "I rc=$rc: $(printf '%s' "$out" | tail -8)"
grep -q 'sk-ant-oat01-beta' "$CB/accounts/main.hub/.credentials.json" 2>/dev/null && [ ! -L "$CB/node.env" ] \
  && [ "$(cksum < "$AG")" = "$AG0" ] \
  && pass "I the credentials and the agent definition are back all the same" || fail "I files: $(ls -la "$CB" | tr '\n' ' ')"
ls -d "$SB/db"/beta.rolledback-* >/dev/null 2>&1 && [ ! -e "$SB/db/beta" ] && [ ! -e "$CB/credsep.json" ] \
  && pass "I the store kept as beta.rolledback-* for the person; nothing reads it as separated" \
  || fail "I store: $(ls -a "$SB/db" 2>&1 | tr '\n' ' ')"

[ "$FAIL" = 0 ] && echo "fleet-cred-shared-selftest: OK" || { echo "fleet-cred-shared-selftest: FAILED"; exit 1; }
