#!/bin/bash
# newcomer-e2e.sh — a person who has never been here, from the admin adding
# them to a working client, against a hub built from this checkout (issue
# #2096, EPIC #1982).
#
#   bin/newcomer-e2e.sh --ccquota <ccquota binary built from tokenledger/>
#
# client-e2e.sh proves the installed client works — as the OPERATOR (a viewer
# token, no scan). Every way a newcomer got stuck on 2026-10-07 was before
# that: the list, the scan, the certificate, the machine login. So this one
# walks the newcomer's road and holds no operator credential on the client:
#
#   1. admin   — `fleet users add <name> --machine-login <login>` (the hub
#                looks the name up on a GitHub API stand-in on 127.0.0.1 —
#                CCQUOTA_GITHUB_API_BASE; sign-in itself is never faked) and a
#                drill person on the fake node (`fleet drill invite`): the
#                stand-in colleague whose one-time approve code confirms the
#                scan, as /fleet-onboard-drill does
#   2. install — `curl -fsSL <hub>/install | sh` into a CLEAN home: an empty
#                ~/.ssh, no ~/.config/claude-fleet, no ~/.local
#   3. login   — `fleet login`: the code and the link are on the terminal
#                within seconds, the drill code confirms it, the certificate
#                (0600, the drill's login as its principal), ~/.ssh/fleet-ssh-config
#                and ONE Include block in ~/.ssh/config land
#   4. fleet   — `fleet` with that certificate only: the hub picks the node,
#                ssh is asked for it as the newcomer's login with the
#                certificate (a PATH `ssh` stand-in: a fake node has no sshd);
#                a second `fleet` asks for no scan; under the renew threshold
#                it renews with the device key, no scan (the 12-hour roll)
#   4b. home   — `fleet` ON the machine the hub picks, with no fleet of this
#                login there (issue #2219): the right pane is the home page,
#                never 「正在连接 <本机>」 / 「没有活着的 fleet 会话」
#   5. leave   — the person deleted (DELETE /v1/self, the drill's own
#                teardown): `fleet login renew` says scan again (exit 3), and
#                the list no longer carries them after `fleet users remove`
#   6. edges   — `fleet login` on a hub that is down, or mid-release (the
#                「正在更新」 backend's 503): one line that says so, no traceback
#
# Every temp server binds 127.0.0.1; the run is bounded
# (NEWCOMER_E2E_DEADLINE, default 300s). No credential is printed: the approve
# code and tokens stay in variables, and logs are scrubbed before they show.
#
# Env: NEWCOMER_E2E_WORK (keep the work dir) · NEWCOMER_E2E_NO_DEPS=1 (pass
# --no-deps to the install line) · NEWCOMER_E2E_STABLE=1 (install GitHub's
# stable client, as a person gets it, instead of this checkout's) ·
# NEWCOMER_E2E_HOLD=<secs> (on red, keep everything up that long). Exit 0 = every step green; 1 = a step failed
# (its name and the logs are printed); 2 = usage.
set -uo pipefail

CCQ=''
while [ $# -gt 0 ]; do
  case "$1" in
    --ccquota) CCQ=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'newcomer-e2e: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$CCQ" ] && [ -x "$CCQ" ] || { printf 'newcomer-e2e: --ccquota <built ccquota binary> is required\n' >&2; exit 2; }
CCQ=$(cd "$(dirname "$CCQ")" && pwd -P)/$(basename "$CCQ")
for c in curl python3 ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || { printf 'newcomer-e2e: %s is required\n' "$c" >&2; exit 2; }
done
BIN="$(cd "$(dirname "$0")" && pwd -P)"

KEEP=0
if [ -n "${NEWCOMER_E2E_WORK:-}" ]; then WORK=$NEWCOMER_E2E_WORK; KEEP=1; mkdir -p "$WORK" || exit 2
else WORK=$(mktemp -d "${TMPDIR:-/tmp}/ncE2E.XXXXXX") || exit 2; fi
WORK=$(cd "$WORK" && pwd -P)
SESS="nce2e$$"
VT="nce2e-viewer-$$-$RANDOM"        # the ADMIN's token — never in the newcomer's env
REAL_TMUX=tmux
START=$(date +%s)
DEADLINE=${NEWCOMER_E2E_DEADLINE:-300}
HUB_PID='' AGENT_PID='' GH_PID='' LOGIN_PID='' UPD_PID='' SC=''
APPROVE=''                          # the drill's approve code (a credential: never printed)
NEWBIE=octo-newbie                  # the GitHub name the admin adds
NEWBIE_ID=424242

STEP=''
step() { STEP=$1; printf '\n== %s · %ss\n' "$1" "$(( $(date +%s) - START ))"; }
ok() { printf '   ✓ %s\n' "$1"; }
scrub() { sed -E 's/fd_[a-z2-7]{20,}/fd_…/g; s/"(token|approve_code|certificate)":"[^"]*"/"\1":"…"/g'; }
logs() {
  local f
  for f in hub.log agent.log install.log login.out fleet.err fleet2.err fleet4.err ssh.log; do
    [ -s "$WORK/$f" ] || continue
    printf -- '--- %s (last 40)\n' "$f"; tail -n 40 "$WORK/$f" | scrub
  done
  local s w
  for s in "$SESS" "$SESS-stage"; do
    for w in $("$REAL_TMUX" -L "$s" list-panes -a -F '#{pane_id}' 2>/dev/null); do
      printf -- '--- pane %s on -L %s\n' "$w" "$s"
      "$REAL_TMUX" -L "$s" capture-pane -p -t "$w" 2>/dev/null | grep -v '^$' | tail -n 15 | scrub
    done
  done
}
die() {
  printf '   ✗ %s: %s\n' "$STEP" "$1" >&2
  [ $# -gt 1 ] && printf '     got: %s\n' "$(printf '%s' "$2" | scrub)" >&2
  logs >&2
  printf '\nnewcomer-e2e: RED at step "%s" after %ss\n' "$STEP" "$(( $(date +%s) - START ))" >&2
  # NEWCOMER_E2E_HOLD=<secs>: keep the hub, node and client up that long to look around
  case "${NEWCOMER_E2E_HOLD:-}" in ''|*[!0-9]*) ;; *) sleep "$NEWCOMER_E2E_HOLD" ;; esac
  exit 1
}
waitfor() {
  local n=$(( $1 * 5 )); shift
  while [ "$n" -gt 0 ]; do
    "$@" && return 0
    [ $(( $(date +%s) - START )) -lt "$DEADLINE" ] || return 1
    sleep 0.2; n=$((n - 1))
  done
  return 1
}
ts() { "$REAL_TMUX" -L "$SESS" "$@"; }
cleanup() {
  ts kill-server 2>/dev/null
  "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null
  pkill -f "fleet-shell.sh [a-z]* $SESS" 2>/dev/null
  [ -n "$SC" ] && pkill -f "$SC/bin/" 2>/dev/null
  [ -n "$LOGIN_PID" ] && kill "$LOGIN_PID" 2>/dev/null
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null
  [ -n "$GH_PID" ] && kill "$GH_PID" 2>/dev/null
  [ -n "$UPD_PID" ] && kill "$UPD_PID" 2>/dev/null
  [ -f "$WORK/master.pid" ] && kill "$(cat "$WORK/master.pid")" 2>/dev/null
  [ -n "$SC" ] && rm -rf "$SC"
  [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# The client served: this checkout's pack (off), or — NEWCOMER_E2E_STABLE=1 —
# GitHub's stable, the one a person gets today (the hub follows it, #1805).
STABLE=off; [ "${NEWCOMER_E2E_STABLE:-0}" = 1 ] && STABLE=''
freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT=$(freeport); GHPORT=$(freeport)
HUB="http://127.0.0.1:$PORT"
# the admin's calls: the token rides a header from stdin, never an argv
api() { printf 'Authorization: Bearer %s\n' "$VT" | curl -fsS -m 10 -H @- "$@"; }
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k] if isinstance(d,dict) else d[int(k)]
print(d)' "$1"; }

# =============================================================================
step 'hub: ccquota hub on 127.0.0.1 + a GitHub API stand-in'
cat > "$WORK/gh.py" <<EOF
import json, http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.rsplit("/", 1)[-1]
        if self.path.startswith("/users/") and name.lower() == "$NEWBIE":
            b = json.dumps({"id": $NEWBIE_ID, "login": "$NEWBIE"}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        else:
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", $GHPORT), H).serve_forever()
EOF
python3 "$WORK/gh.py" >"$WORK/gh.log" 2>&1 &
GH_PID=$!
ssh-keygen -q -t ed25519 -N '' -C newcomer-e2e-ca -f "$WORK/ca" || die 'ssh-keygen could not make the CA key'
mkdir -p "$WORK/dist"
env CCQUOTA_FLEET=1 CCQUOTA_VIEWER_TOKEN="$VT" CCQUOTA_FLEET_DIST_DIR="$WORK/dist" \
    CCQUOTA_FLEET_SSH_CA_KEY="$WORK/ca" CCQUOTA_GITHUB_CLIENT_ID=newcomer-e2e \
    CCQUOTA_GITHUB_CLIENT_SECRET="placeholder-$RANDOM$RANDOM" \
    CCQUOTA_GITHUB_API_BASE="http://127.0.0.1:$GHPORT" CCQUOTA_FLEET_PUBLIC_URL="$HUB" \
    CCQUOTA_FLEET_STABLE_REPO="$STABLE" \
  "$CCQ" hub --addr "127.0.0.1:$PORT" --db "$WORK/hub.db" >"$WORK/hub.log" 2>&1 &
HUB_PID=$!
waitfor 20 curl -fs -m 2 -o /dev/null "$HUB/healthz" || die 'the hub never answered /healthz'
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$HUB/install")
[ "$code" = 200 ] || die 'GET /install did not serve the installer' "HTTP $code"
ok "hub up at $HUB, /install served"

# =============================================================================
step 'node: a fake node joins and reports one session'
NH="$WORK/node"; mkdir -p "$NH/.claude/fleet/bin" "$NH/state"
JC=$(api -X POST -H 'Content-Type: application/json' -d '{}' "$HUB/v1/fleet/join-codes" | jget code) \
  || die 'the operator API minted no join code'
J=$(curl -fsS -m 10 -H 'Content-Type: application/json' -X POST \
      -d "{\"code\":\"$JC\",\"hostname\":\"e2enode\",\"os_user\":\"$(id -un)\"}" "$HUB/v1/node/join") \
  || die '/v1/node/join refused the code'
NTOK=$(printf '%s' "$J" | jget token 2>/dev/null)
[ -n "$NTOK" ] || die 'the join answer had no token' "$J"
MID=7e2e0000-0000-4000-8000-000000002096
FID=$(python3 -c 'import json,sys,uuid; print(uuid.uuid5(uuid.UUID(sys.argv[1]), json.dumps(sys.argv[2:], ensure_ascii=False, sort_keys=True, separators=(",", ":"))))' "$MID" acme acme/app /w/acme)
cat > "$NH/.claude/fleet/bin/fleet-control.py" <<EOF
#!/usr/bin/env python3
import json, sys, time
req = json.load(sys.stdin)
m = req.get("method")
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
if m == "discover":
    r = {"machine_id": "$MID", "hostname": "e2enode", "protocol": 1, "observed_at": now,
         "fleets": [{"fleet_id": "$FID", "machine_id": "$MID", "name": "acme", "repo": "acme/app",
                     "repos": ["acme/app"], "checkout": "/w/acme", "agent": "claude"}]}
elif m == "ready":
    r = {"ready": True, "gh": True, "creds": True, "checkouts": True, "missing": [], "observed_at": now}
elif m == "fleet_status":
    r = {"state": "running", "observed_at": now,
         "workers": [{"worker_id": "$FID/scratch-3", "key": "scratch-3", "window_id": "@9", "issue": None,
                      "repo": "acme/app", "scratch": True, "worktree": "/w/scratch-3", "state": "idle",
                      "lifecycle": "awake", "agent": "claude", "handle": ""}]}
else:
    print(json.dumps({"error": {"code": "INVALID_ARGUMENT", "message": "newcomer-e2e fake node"}})); sys.exit(1)
print(json.dumps({"protocol": 1, "machine_id": "$MID", "result": r}))
EOF
chmod +x "$NH/.claude/fleet/bin/fleet-control.py"
( cd "$NH" && exec env HOME="$NH" CCQUOTA_HUB_URL="$HUB" CCQUOTA_TOKEN="$NTOK" CCQUOTA_FLEET=1 \
    CCQUOTA_FLEET_NODE_ROUTES=lan=127.0.0.1:22 CCQUOTA_FLEET_NODE_TAILNET=0 \
    "$CCQ" agent --hub "$HUB" --home "$NH" --state "$NH/state" ) >"$WORK/agent.log" 2>&1 &
AGENT_PID=$!
node_up() { api "$HUB/v1/fleet/fleet_sessions" >"$WORK/sessions.json" 2>/dev/null && grep -q "$FID/scratch-3" "$WORK/sessions.json"; }
waitfor 60 node_up || die 'the hub never listed the node'"'"'s session' "$(head -c 600 "$WORK/sessions.json" 2>/dev/null)"
# the machine's name is what its agent reports (the host's own name), not the join label
NODE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sessions"][0]["machine_name"])' "$WORK/sessions.json")
[ -n "$NODE" ] || die 'the session row names no machine' "$(head -c 600 "$WORK/sessions.json")"
ok "node $NODE online"

# =============================================================================
step 'admin: fleet users add + a drill person on the node'
# The admin's own client is this checkout's bin/ (the newcomer's comes later).
aenv() { env FLEET_HUB_URL="$HUB" CCQUOTA_VIEWER_TOKEN="$VT" HOME="$WORK/admin" FLEET_CONF_DIR="$WORK/admin/conf" "$@"; }
mkdir -p "$WORK/admin/conf"
out=$(aenv "$BIN/fleet" users add "$NEWBIE" --machine-login newbie 2>&1) || die 'fleet users add failed' "$out"
case "$out" in *"$NEWBIE"*) ;; *) die 'fleet users add did not list the new person' "$out" ;; esac
out=$(aenv "$BIN/fleet" users add no-such-person-2096 2>&1) && die 'fleet users add accepted a name GitHub does not know' "$out"
D=$(aenv bash "$BIN/fleet-drill.sh" invite --host "$NODE" --login drillnew --ttl 30m --json 2>"$WORK/drill.err") \
  || die 'fleet drill invite failed' "$(cat "$WORK/drill.err")"
APPROVE=$(printf '%s' "$D" | jget approve_code 2>/dev/null)
DPID=$(printf '%s' "$D" | jget person_id 2>/dev/null)
[ -n "$APPROVE" ] && [ -n "$DPID" ] || die 'the drill answer had no approve code / person' "$D"
ok "$NEWBIE on the list (machine login newbie); drill person drillnew@$NODE minted"

# =============================================================================
step 'install: curl -fsSL <hub>/install | sh into a clean HOME'
CH="$WORK/client"; mkdir -p "$CH/.ssh"; chmod 700 "$CH/.ssh"
deps=''; [ "${NEWCOMER_E2E_NO_DEPS:-0}" = 1 ] && deps='-s -- --no-deps'
# shellcheck disable=SC2086  # $deps is deliberately split into sh's arguments
( cd "$CH" && curl -fsSL "$HUB/install" | env -i PATH="$PATH" HOME="$CH" SHELL=/bin/zsh TERM=dumb LANG=zh_CN.UTF-8 \
    FLEET_INSTALL_NO_RUN=1 sh $deps ) >"$WORK/install.log" 2>&1 </dev/null || die 'the install line failed' "$(tail -n 5 "$WORK/install.log")"
FLEET="$CH/.local/bin/fleet"
[ -x "$FLEET" ] || die 'no fleet in ~/.local/bin after the install' "$(ls -la "$CH/.local/bin" 2>&1)"
grep -qs "FLEET_HUB_URL=\"\\{0,1\\}$HUB" "$CH/.config/claude-fleet/fleet.conf" || die 'fleet.conf does not carry the hub address' "$(cat "$CH/.config/claude-fleet/fleet.conf" 2>&1)"
grep -qs '\.local/bin' "$CH/.zshrc" || die 'the install did not put ~/.local/bin on the PATH of a new zsh' "$(cat "$CH/.zshrc" 2>&1)"
[ -n "$(ls -A "$CH/.ssh")" ] && die 'the install wrote into ~/.ssh before any login' "$(ls -la "$CH/.ssh")"
REAL_TMUX=$(PATH="$CH/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" command -v tmux) || die 'no tmux after the install line' "$(grep -i tmux "$WORK/install.log")"
ok "fleet installed, fleet.conf names $HUB, ~/.ssh untouched"

# The newcomer's environment: nothing of the admin's — no token, no viewer token.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
SC=$(mktemp -d /tmp/nce2e-c.XXXXXX) || die 'no short cache dir'
nenv() {
  env -i PATH="$SHIM:$CH/.local/bin:$PATH" HOME="$CH" SHELL=/bin/zsh TERM=xterm-256color LANG=zh_CN.UTF-8 \
    PYTHONUNBUFFERED=1 "$@"
}

# =============================================================================
step 'login: fleet login shows a code, the drill confirms it, the certificate lands'
nenv "$FLEET" login >"$WORK/login.out" 2>&1 </dev/null &
LOGIN_PID=$!
ucode() { grep -Eo '[A-Z]{4}-[A-Z]{4}' "$WORK/login.out" | head -1; }
has_code() { [ -n "$(ucode)" ]; }
waitfor 15 has_code || die 'fleet login printed no 验证码 within 15s' "$(cat "$WORK/login.out")"
grep -q "$HUB/fleet/login?code=" "$WORK/login.out" || die 'fleet login printed no link to open' "$(cat "$WORK/login.out")"
UC=$(ucode)
out=$(env FLEET_HUB_URL="$HUB" FLEET_DRILL_INVITE="$APPROVE" HOME="$WORK/admin" FLEET_CONF_DIR="$WORK/admin/conf" \
        bash "$BIN/fleet-drill.sh" approve "$UC" 2>&1) || die 'the drill could not confirm the scan' "$out"
waitfor 15 sh -c "! kill -0 $LOGIN_PID 2>/dev/null" || die 'fleet login still waiting 15s after the confirm' "$(cat "$WORK/login.out")"
wait "$LOGIN_PID"; rc=$?; LOGIN_PID=''
[ "$rc" = 0 ] || die "fleet login exited $rc" "$(cat "$WORK/login.out")"
CERT="$CH/.ssh/fleet-cert-cert.pub"
[ -f "$CH/.ssh/fleet-cert" ] && [ -f "$CERT" ] || die 'no key / certificate in ~/.ssh' "$(ls -la "$CH/.ssh")"
perm=$(ls -l "$CH/.ssh/fleet-cert" | cut -c1-10)
[ "$perm" = '-rw-------' ] || die 'the device key is not 0600' "$perm"
princ=$(ssh-keygen -L -f "$CERT" | awk '/Principals:/{f=1;next} f&&/:/{f=0} f{print $1}' | tr '\n' ' ')
case "$princ" in 'drillnew ') ;; *) die 'the certificate does not carry the login drillnew' "$princ" ;; esac
[ "$(grep -c '>>> fleet login' "$CH/.ssh/config" 2>/dev/null)" = 1 ] || die 'the ssh config does not carry exactly one fleet Include' "$(cat "$CH/.ssh/config" 2>&1)"
grep -q '^Host ' "$CH/.ssh/fleet-ssh-config" || die 'fleet-ssh-config names no machine' "$(cat "$CH/.ssh/fleet-ssh-config" 2>&1)"
ok "certificate for [$princ] in ~/.ssh (0600), one Include, $(grep -c '^Host ' "$CH/.ssh/fleet-ssh-config") Host block(s)"

# =============================================================================
step 'fleet: the certificate alone opens the client on the node as drillnew'
# ssh is the stand-in (a fake node has no sshd): everything up to the ssh argv is real.
cat > "$SHIM/ssh" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in -G|-V|-Q) exec /usr/bin/ssh "\$@" ;; esac; done
printf '%s\n' "\$*" >> "$WORK/ssh.log"
op=''; ctl=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    -O) op=\$2; shift 2 ;;
    -S) ctl=\$2; shift 2 ;;
    -o) case "\$2" in ControlPath=*) ctl=\${2#ControlPath=} ;; esac; shift 2 ;;
    -[bcDEeFIiJLlmpQRWw]) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
if [ -n "\$op" ]; then [ "\$op" = check ] && [ -S "\$ctl" ]; exit \$?; fi
case "\$*" in
  *" attach "*|*attach*)
    [ -n "\$ctl" ] && python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(600)' "\$ctl" &
    echo \$! > "$WORK/master.pid"; wait ;;
  *" watch "*) sleep 600 ;;
esac
exit 0
EOF
chmod +x "$SHIM/ssh"
# The agent reports this computer's own hostname as the node's, so the client
# must not take itself for that machine (it would run the node's side here).
printf '#!/bin/sh\necho newcomer-laptop\n' > "$SHIM/hostname"; chmod +x "$SHIM/hostname"
fenv() {
  nenv FLEET_SHELL_SESSION="$SESS" FLEET_SHELL_CACHE="$SC" FLEET_SHELL_NO_ATTACH=1 FLEET_SHELL_WARM=0 \
    FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_LOOP_SECS=8 "$@"
}
before=$(ssh-keygen -L -f "$CERT" | awk '/Serial:/{print $2}')
out=$(fenv "$FLEET" 2>"$WORK/fleet.err" </dev/null); rc=$?
[ "$rc" = 0 ] || die "fleet exited $rc" "$(tail -n 8 "$WORK/fleet.err")"
[ "$out" = "$SESS" ] || die 'fleet did not print its session' "$out · $(tail -n 5 "$WORK/fleet.err")"
grep -Eq '[A-Z]{4}-[A-Z]{4}' "$WORK/fleet.err" && die 'fleet asked for a scan with a fresh certificate' "$(cat "$WORK/fleet.err")"
ts has-session -t "=$SESS" 2>/dev/null || die 'the client tmux server is not up'
mkfifo "$WORK/client.fifo"
"$REAL_TMUX" -L "$SESS" -C attach-session -t "=$SESS" <"$WORK/client.fifo" >/dev/null 2>&1 &
exec 7>"$WORK/client.fifo"
P="$SESS"; waitfor 5 "$REAL_TMUX" -L "$SESS-stage" has-session -t "=$SESS-stage" && P="$SESS-stage"
tp() { "$REAL_TMUX" -L "$P" "$@"; }
w1=$(tp list-windows -t "=$P" -F '#{window_id}' | head -1)
remote=$(tp show-options -wqv -t "$w1" @remote)
case "$remote" in "$NODE":*) ;; *) die "the right pane is not the node $NODE" "@remote=$remote · $(cat "$WORK/fleet.err")" ;; esac
waitfor 20 grep -q -- '-l drillnew' "$WORK/ssh.log" || die 'ssh was never asked for the node as drillnew' "$(cat "$WORK/ssh.log" 2>/dev/null)"
grep -q -- "CertificateFile=$CERT" "$WORK/ssh.log" || die 'ssh was not handed the certificate' "$(cat "$WORK/ssh.log")"
ok "client up, right pane @remote=$remote, ssh as drillnew with the certificate"

# =============================================================================
step 'again: a second fleet asks for no scan; under the threshold it renews by key'
ts kill-server 2>/dev/null; "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null
exec 7>&-
out=$(fenv "$FLEET" 2>"$WORK/fleet2.err" </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$SESS" ] || die "the second fleet exited $rc" "$(tail -n 8 "$WORK/fleet2.err")"
grep -Eq '[A-Z]{4}-[A-Z]{4}' "$WORK/fleet2.err" && die 'the second fleet asked for a scan' "$(cat "$WORK/fleet2.err")"
[ "$(ssh-keygen -L -f "$CERT" | awk '/Serial:/{print $2}')" = "$before" ] || die 'the second fleet replaced a fresh certificate'
ts kill-server 2>/dev/null; "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null
# 12 hours on: a certificate under FLEET_RENEW_BELOW_SECS renews with the device key
out=$(fenv FLEET_RENEW_BELOW_SECS=99999999 "$FLEET" 2>"$WORK/fleet3.err" </dev/null); rc=$?
[ "$rc" = 0 ] || die "fleet under the renew threshold exited $rc" "$(tail -n 8 "$WORK/fleet3.err")"
grep -Eq '[A-Z]{4}-[A-Z]{4}' "$WORK/fleet3.err" && die 'renewal asked for a scan' "$(cat "$WORK/fleet3.err")"
after=$(ssh-keygen -L -f "$CERT" | awk '/Serial:/{print $2}')
[ "$after" != "$before" ] || die 'the certificate was not renewed under the threshold' "$(cat "$WORK/fleet3.err")"
[ "$(grep -c '>>> fleet login' "$CH/.ssh/config")" = 1 ] || die 'renewal added a second Include' "$(cat "$CH/.ssh/config")"
ok "no scan the second time; renewed by key (serial $before → $after)"
ts kill-server 2>/dev/null; "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null

# =============================================================================
step 'home: on the very machine the hub picks, with no fleet of theirs there'
# The C8 drill (issue #2219): the newcomer's 「只看、只派」 client ran ON the
# machine the hub knows them by. This login has no fleet here, so the right pane
# is the home page — never 「正在连接 <本机>」 then 「没有活着的 fleet 会话」.
# the last step's shell fully gone first: its right pane (`viewer`) starts the
# stage again when the stage goes before it, and a stage left behind is reused
pkill -f "fleet-shell.sh [a-z]* $SESS" 2>/dev/null
ts kill-server 2>/dev/null; "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null
stage_gone() { ! "$REAL_TMUX" -L "$SESS-stage" has-session 2>/dev/null; }
waitfor 5 stage_gone || die 'the last step left its stage running'
printf '#!/bin/sh\necho %s\n' "$NODE" > "$SHIM/hostname"
out=$(fenv "$FLEET" 2>"$WORK/fleet4.err" </dev/null); rc=$?
printf '#!/bin/sh\necho newcomer-laptop\n' > "$SHIM/hostname"
[ "$rc" = 0 ] && [ "$out" = "$SESS" ] || die "fleet on the picked machine exited $rc" "$(tail -n 8 "$WORK/fleet4.err")"
P="$SESS"; waitfor 5 "$REAL_TMUX" -L "$SESS-stage" has-session -t "=$SESS-stage" && P="$SESS-stage"
w1=$(tp list-windows -t "=$P" -F '#{window_id}' | head -1)
remote=$(tp show-options -wqv -t "$w1" @remote)
[ "$remote" = '-:' ] || die "the right pane connects to this computer ($NODE) with no fleet here" "@remote=$remote"
homepg() { tp capture-pane -p -t "$w1" 2>/dev/null | grep -q '没有你的 fleet 会话'; }
waitfor 10 homepg || die 'the right pane is not the home page' "$(tp capture-pane -p -t "$w1" 2>/dev/null | grep -v '^$'
  tp list-windows -t "=$P" -F '#{window_id} @remote=#{@remote} #{pane_start_command}' 2>/dev/null)"
pg=$(tp capture-pane -p -t "$w1" 2>/dev/null)
case "$pg" in *正在连接*|*没有活着的*) die 'the right pane still tries this computer' "$pg" ;; esac
ok "@remote=-: · the home page, no 正在连接 $NODE, no 没有活着的 fleet 会话"
ts kill-server 2>/dev/null; "$REAL_TMUX" -L "$SESS-stage" kill-server 2>/dev/null

# =============================================================================
step 'leave:the person removed — renew says scan again, the list forgets them'
code=$(printf '{"approve_code":"%s"}' "$APPROVE" | curl -s -m 10 -o "$WORK/self.out" -w '%{http_code}' \
         -X DELETE -H 'Content-Type: application/json' --data-binary @- "$HUB/v1/self")
case "$code" in 200|204) ;; *) die 'DELETE /v1/self refused' "HTTP $code $(cat "$WORK/self.out")" ;; esac
nenv "$FLEET" login renew >"$WORK/renew.out" 2>&1 </dev/null; rc=$?
[ "$rc" = 3 ] || die "fleet login renew after removal exited $rc (want 3: scan again)" "$(cat "$WORK/renew.out")"
out=$(aenv "$BIN/fleet" users remove "$NEWBIE" 2>&1) || die 'fleet users remove failed' "$out"
out=$(aenv "$BIN/fleet" users 2>&1)
case "$out" in *"$NEWBIE"*) die 'the list still carries the removed person' "$out" ;; esac
ok 'renew → exit 3 (scan again); the list no longer names them'

# =============================================================================
step 'edges: a hub that is down or updating says so in one line'
# what the newcomer reads when the address is wrong / the hub is mid-release
# (the 「正在更新」 backend's JSON, deploy/k8s/updating) — never a traceback
DEAD=$(freeport)
nenv "$FLEET" login --hub "http://127.0.0.1:$DEAD" >"$WORK/edge1.out" 2>&1 </dev/null; rc=$?
[ "$rc" = 1 ] && grep -q '连不上' "$WORK/edge1.out" && ! grep -q Traceback "$WORK/edge1.out" \
  || die "fleet login against a dead hub (exit $rc) did not say it cannot reach it" "$(cat "$WORK/edge1.out")"
UPD=$(freeport)
cat > "$WORK/updating.py" <<'EOF2'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = b'{"error":"updating","retry_after":30}'
        self.send_response(503); self.send_header("Retry-After", "30")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF2
python3 "$WORK/updating.py" "$UPD" >/dev/null 2>&1 &
UPD_PID=$!
waitfor 10 curl -s -m 1 -o /dev/null -X POST "http://127.0.0.1:$UPD/" || die 'the updating stand-in never answered'
nenv "$FLEET" login --hub "http://127.0.0.1:$UPD" >"$WORK/edge2.out" 2>&1 </dev/null; rc=$?
[ "$rc" = 1 ] && grep -q '正在更新' "$WORK/edge2.out" \
  || die "fleet login against an updating hub (exit $rc) did not say it is updating" "$(cat "$WORK/edge2.out")"
kill "$UPD_PID" 2>/dev/null; UPD_PID=''
ok 'a dead hub: 连不上 in one line; an updating hub: 正在更新'

printf '\nnewcomer-e2e: GREEN — added, installed, signed in, opened, renewed and removed in %ss\n' "$(( $(date +%s) - START ))"
