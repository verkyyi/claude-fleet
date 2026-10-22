#!/bin/bash
# nogh-e2e-selftest.sh — no GitHub from the sign-in to the report (issue #3605,
# EPIC #3570 C13). The EPIC's metric 「没有 GitHub 账号时走得通的步骤」 is read
# here: a person with no GitHub account, a repo that is not on GitHub, and the
# fleet's whole road — each step 1 when it passes, and the line at the end says
# `steps: N/7 · gh calls: 0 · github http: 0`.
#
#   bin/nogh-e2e-selftest.sh [--ccquota <the hub's ccquota, built from tokenledger/hub>] [--node-ccquota <the node's, tokenledger/agent>]
#
#   0. install  `curl <hub>/install | sh` into a clean HOME (C12, #2862): the
#               client lands from the hub, never from GitHub
#   1. 登录     a hub with ONLY WeChat sign-in (no GitHub client at all) and a
#               WeChat stand-in on 127.0.0.1 (CCQUOTA_WECHAT_*_BASE): an invite,
#               the scan, the first scan bound by the invite (never a new account
#               by itself — wechat-first-scan-autocreate), /v1/me says wechat; the
#               operator maps the person to this machine's login; `fleet login`
#               in the terminal confirmed by that browser — the certificate lands
#   2. 开单     a hub task record (issue #4898: no issue anywhere) for a repo at
#               ssh://mac-a/~/repos/demo.git (a bare repo here, C7); it is the
#               person's: their browser lists it (任务)
#   3. 派活     dash-raw-session.sh --repo --task opens it on a private tmux
#               server: the worktree remembers the record, the window is bound to
#               it, the agent (a recorder) starts with the person's words
#   4. 执行     in the session's pane: the brief reads the record off the hub; a commit
#   5. 落地     pr_verdict → READY, pr_merge → MERGED (bin/fleet-land.sh, C9): the
#               repo's check ran, the bare repo's master carries the commit, git
#               says landed (fleet_landed, C8), and the session's `merged` report
#               is taken with no PR and closes the record
#   6. 回收     one cleanup-daemon tick (its git prmap): the window,
#               the worktree and the branch go, the history ledger has the row
#   7. 报告     what the person reads: the record closed in their list, the landing
#               record (the check passed)
#
# Throughout: `gh` on PATH is a stand-in that records every call and fails; the
# hub's GitHub API base and the stable API point at a recorder; git's github.com
# addresses lead nowhere. The run is red if any of them saw one request.
#
# Hermetic: a sandbox HOME / FLEET_CONF_DIR / CLAUDE_CONFIG_DIR / TMPDIR, a tmux
# server on its own socket (a PATH shim folds every -L/-S), every server on
# 127.0.0.1, GIT_ALLOW_PROTOCOL=file. The hub is the real tokenledger (`ccquota
# hub`, SQLite) built from this checkout with its client pack (`bin/fleet-client-pack.sh
# && go build ./cmd/ccquota`) — `--ccquota`, else $NOGH_E2E_CCQUOTA, else SKIP: the
# selftest gate has none, CI's client-e2e job builds it and runs this.
# Env: NOGH_E2E_WORK=<dir> keeps the work dir; NOGH_E2E_DEADLINE (default 240s).
# NOGH_E2E_SUMMARY=<file> archives credential-free fixture counters, including
# failures, for nogh-task-acceptance.py. The historical seven steps stay separate
# from EPIC #4390's twelve rows; neither is live provider/deployment evidence.
#
# Drives: bin/fleet-install.sh (served), bin/fleet-login.py, bin/fleet-hub-admin.py,
# bin/fleet-repo.sh, bin/fleet-task-record.sh, bin/dash-raw-session.sh,
# bin/fleet-brief.sh, bin/fleet-pr-verdict.sh, bin/fleet-pr-merge.sh,
# bin/fleet-land.sh, bin/fleet-cleanup-daemon.sh,
# bin/fleet-cleanup.sh, bin/fleet-report-parent.sh, fleet_landed /
# fleet_task_closed / fleet_repo_register (bin/fleet-lib.sh).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd -P)"
CCQ="${NOGH_E2E_CCQUOTA:-}"; CCQN="${NOGH_E2E_NODE_CCQUOTA:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --ccquota) CCQ=${2:-}; shift 2 ;;
    --node-ccquota) CCQN=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'nogh-e2e: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
# Nothing of the caller's fleet comes along (a pane's FLEET_CRED_PROXY, a hub URL …)
for v in $(compgen -e | grep -E '^(FLEET_|CCQUOTA_)'); do unset "$v"; done
for c in git python3 curl jq ssh-keygen go; do
  command -v "$c" >/dev/null 2>&1 || { printf 'nogh-e2e: %s not installed — SKIP\n' "$c" >&2; exit 0; }
done
# the real tmux, past the fleet's own guard shim (bin/tmux-shim) when a pane put it first
REAL_TMUX=''
for t in $(type -ap tmux 2>/dev/null); do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done
[ -n "$REAL_TMUX" ] || { printf 'nogh-e2e: tmux not installed — SKIP\n' >&2; exit 0; }

KEEP=0
if [ -n "${NOGH_E2E_WORK:-}" ]; then WORK=$NOGH_E2E_WORK; KEEP=1; mkdir -p "$WORK" || exit 2
else WORK=$(mktemp -d "${TMPDIR:-/tmp}/nogh-e2e.XXXXXX") || exit 2; fi
WORK=$(cd "$WORK" && pwd -P)

if [ -z "$CCQ" ] || [ ! -x "$CCQ" ]; then
  printf 'nogh-e2e: no ccquota to run the hub (--ccquota / NOGH_E2E_CCQUOTA) — SKIP (CI client-e2e builds one and runs this)\n' >&2
  [ "$KEEP" = 1 ] || rm -rf "$WORK"
  exit 0
fi
CCQ=$(cd "$(dirname "$CCQ")" && pwd -P)/$(basename "$CCQ")
# The node is its own build since claude-fleet#4814 (the hub's answers a node
# command with exit 2): --node-ccquota, else ccquota-node beside the hub's,
# else the same binary (a build from before the split runs both).
[ -n "${CCQN:-}" ] || CCQN=$(dirname "$CCQ")/ccquota-node
[ -x "$CCQN" ] || CCQN=$CCQ

START=$(date +%s)
DEADLINE=${NOGH_E2E_DEADLINE:-240}
SOCK="$WORK/tmux.sock"
HUB_PID='' WX_PID='' GHAPI_PID='' LOGIN_PID='' AGENT_PID=''
VT="nogh-viewer-$$-$RANDOM$RANDOM"     # the operator's token: never in the person's env
STEPS=0 STEP='' STEPNO=''

step() { STEPNO=$1; STEP=$2; printf '\n== %s. %s · %ss\n' "$1" "$2" "$(( $(date +%s) - START ))"; }
ok()   { printf '   ✓ %s\n' "$1"; }
passed() { [ "$STEPNO" = 0 ] || STEPS=$((STEPS + 1)); }
scrub() { sed -E 's/"(token|code|access_token|approve_code|certificate)":"[^"]*"/"\1":"…"/g; s/Bearer [^ ]+/Bearer …/g'; }
logs() {
  local f
  for f in hub.log agent.log wx.log ghapi.log gh.log install.log login.out err out; do
    [ -s "$WORK/$f" ] || continue
    printf -- '--- %s (last 30)\n' "$f"; tail -n 30 "$WORK/$f" | scrub
  done
  local p
  for p in $("$REAL_TMUX" -S "$SOCK" list-panes -a -F '#{pane_id}' 2>/dev/null); do
    printf -- '--- pane %s: %s\n' "$p" "$("$REAL_TMUX" -S "$SOCK" display-message -p -t "$p" '#{window_name} dead=#{pane_dead} #{pane_start_command}' 2>/dev/null | cut -c1-300)"
    "$REAL_TMUX" -S "$SOCK" capture-pane -p -t "$p" 2>/dev/null | grep -v '^$' | tail -n 15 | scrub
  done
}
die() {
  printf '   ✗ %s: %s\n' "$STEP" "$1" >&2
  [ $# -gt 1 ] && printf '     got: %s\n' "$(printf '%s' "$2" | scrub)" >&2
  logs >&2
  printf '\nnogh-e2e: RED at step %s 「%s」 — steps: %s/7 · gh calls: %s · github http: %s\n' \
    "$STEPNO" "$STEP" "$STEPS" "$(ghcalls)" "$(ghhttp)" >&2
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
cleanup() {
  local result=$?
  if [ -n "${NOGH_E2E_SUMMARY:-}" ]; then
    python3 - "$NOGH_E2E_SUMMARY" "$result" "$STEPS" "$(ghcalls)" "$(ghhttp)" <<'PY'
import datetime, json, sys
from pathlib import Path
path, code, steps, cli, http = sys.argv[1:]
Path(path).write_text(json.dumps(dict(at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    kind="fixture", baseline="3570", exit=int(code), steps=int(steps), total=7,
    github_cli=int(cli or 0), github_http=int(http or 0), live="NOT RUN"), indent=2)+"\n")
PY
  fi
  "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null
  for p in "$LOGIN_PID" "$AGENT_PID" "$HUB_PID" "$WX_PID" "$GHAPI_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  [ "$KEEP" = 1 ] || { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

freeport() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT=$(freeport); WXPORT=$(freeport); GHPORT=$(freeport)
HUB="http://127.0.0.1:$PORT"
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k] if isinstance(d,dict) else d[int(k)]
print(d)' "$1"; }
# the operator's calls: the token rides a header from stdin, never an argv
api() { printf 'Authorization: Bearer %s\n' "$VT" | curl -fsS -m 10 -H @- "$@"; }

# ---- the GitHub tripwires ------------------------------------------------------
mkdir -p "$WORK/shim" "$WORK/home" "$WORK/conf" "$WORK/cc" "$WORK/tmp" "$WORK/rec" "$WORK/leases"
GHLOG="$WORK/gh.log"; : > "$GHLOG"
cat > "$WORK/shim/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$GHLOG"
exit 1
EOF
# GitHub's REST API, as the hub (CCQUOTA_GITHUB_API_BASE) and a stable lookup
# (FLEET_STABLE_API / _RAW) would reach it: every request is a finding.
cat > "$WORK/ghapi.py" <<'EOF'
import http.server, sys
LOG = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def any(self):
        with open(LOG, "a") as f: f.write("%s %s\n" % (self.command, self.path))
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = any
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
: > "$WORK/ghapi.log"
python3 "$WORK/ghapi.py" "$GHPORT" "$WORK/ghapi.log" 2>/dev/null &
GHAPI_PID=$!
ghcalls() { awk 'END{print NR}' "$GHLOG" 2>/dev/null; }
ghhttp() { awk 'END{print NR}' "$WORK/ghapi.log" 2>/dev/null; }

# ---- the WeChat stand-in -------------------------------------------------------
# open.weixin.qq.com's /connect/qrconnect "scans" at once and sends the browser
# back with a code; api.weixin.qq.com trades it for a unionid and a nickname.
cat > "$WORK/wx.py" <<'EOF'
import http.server, json, sys, urllib.parse
LOG = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        with open(LOG, "a") as f: f.write("%s %s\n" % (u.path, ",".join(sorted(q))))
        if u.path in ("/connect/qrconnect", "/connect/oauth2/authorize"):
            to = q["redirect_uri"] + ("&" if "?" in q["redirect_uri"] else "?") + urllib.parse.urlencode(
                {"code": "wxcode-" + q["state"][:8], "state": q["state"]})
            self.send_response(302); self.send_header("Location", to); self.send_header("Content-Length", "0"); self.end_headers(); return
        if u.path == "/sns/oauth2/access_token":
            ok = q.get("appid") == "wxe2eapp" and q.get("code", "").startswith("wxcode-")
            d = {"access_token": "at-e2e", "openid": "o-e2e", "unionid": "u-nogh-e2e"} if ok else {"errcode": 40029}
        elif u.path == "/sns/userinfo":
            d = {"nickname": "小周", "unionid": "u-nogh-e2e"}
        else:
            d = {"errcode": 404}
        b = json.dumps(d, ensure_ascii=False).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
: > "$WORK/wx.log"
python3 "$WORK/wx.py" "$WXPORT" "$WORK/wx.log" 2>/dev/null &
WX_PID=$!

# ---- the person's browser: one cookie jar, redirects followed ------------------
cat > "$WORK/browser.py" <<'EOF'
"""browser.py <jar> get|post <url> [k=v …] — a browser that keeps cookies: prints
`<status> <final url>` then the body. A POST carries Origin (sameOrigin)."""
import http.cookiejar, sys, urllib.parse, urllib.request
jar_path, verb, url = sys.argv[1], sys.argv[2], sys.argv[3]
jar = http.cookiejar.MozillaCookieJar(jar_path)
try: jar.load(ignore_discard=True, ignore_expires=True)
except OSError: pass
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
hdr = {"Accept": "application/json" if "/v1/" in url else "text/html", "User-Agent": "nogh-e2e"}
data = None
if verb == "post":
    data = urllib.parse.urlencode([tuple(a.split("=", 1)) for a in sys.argv[4:]]).encode()
    p = urllib.parse.urlsplit(url); hdr["Origin"] = "%s://%s" % (p.scheme, p.netloc)
req = urllib.request.Request(url, data=data, headers=hdr)
try:
    r = op.open(req, timeout=15); code, final, body = r.status, r.geturl(), r.read()
except urllib.error.HTTPError as e:
    code, final, body = e.code, e.geturl(), e.read()
jar.save(ignore_discard=True, ignore_expires=True)
sys.stdout.write("%s %s\n" % (code, final)); sys.stdout.write(body.decode("utf-8", "replace"))
EOF
JAR="$WORK/browser.jar"
browse() { python3 "$WORK/browser.py" "$JAR" "$@"; }

# =============================================================================
step 0 'install: the client comes from the hub, not GitHub'
ssh-keygen -q -t ed25519 -N '' -C nogh-e2e-ca -f "$WORK/ca" || die 'ssh-keygen could not make the CA key'
# Sign-in: WeChat only — no CCQUOTA_GITHUB_CLIENT_ID. The admin login is another
# (CCQUOTA_FLEET_ADMIN_USERS): this machine's login is the person's own, so what it
# files is theirs (relayOwner), never the operator's. GitHub's API base and the
# stable lookup point at the recorder; the client served is this checkout's pack.
env CCQUOTA_FLEET=1 CCQUOTA_VIEWER_TOKEN="$VT" CCQUOTA_FLEET_SSH_CA_KEY="$WORK/ca" \
    CCQUOTA_WECHAT_WEB_APPID=wxe2eapp CCQUOTA_WECHAT_WEB_SECRET="wxsecret-$RANDOM$RANDOM" \
    CCQUOTA_WECHAT_AUTHORIZE_BASE="http://127.0.0.1:$WXPORT" CCQUOTA_WECHAT_API_BASE="http://127.0.0.1:$WXPORT" \
    CCQUOTA_SESSION_SECRET="nogh-session-$RANDOM$RANDOM$RANDOM" \
    CCQUOTA_GITHUB_API_BASE="http://127.0.0.1:$GHPORT" CCQUOTA_FLEET_PUBLIC_URL="$HUB" \
    CCQUOTA_FLEET_ADMIN_USERS=fleetadmin CCQUOTA_FLEET_STABLE_REPO=off CCQUOTA_FLEET_MAX_LOAD_PER_CORE=100 CCQUOTA_FLEET_MAX_CPU_BUSY=1 \
    PATH="$WORK/shim:$PATH" \
  "$CCQ" hub --addr "127.0.0.1:$PORT" --db "$WORK/hub.db" >"$WORK/hub.log" 2>&1 &
HUB_PID=$!
waitfor 20 curl -fs -m 2 -o /dev/null "$HUB/healthz" || die 'the hub never answered /healthz'
grep -q 'wechat sign-in: on' "$WORK/hub.log" || die 'the hub did not turn WeChat sign-in on' "$(grep -i wechat "$WORK/hub.log")"
CH="$WORK/client"; mkdir -p "$CH"
( cd "$CH" && curl -fsSL "$HUB/install" | env -i PATH="$WORK/shim:$PATH" HOME="$CH" SHELL=/bin/bash TERM=dumb \
    LANG=en_US.UTF-8 FLEET_INSTALL_NO_RUN=1 FLEET_STABLE_API="http://127.0.0.1:$GHPORT" \
    FLEET_STABLE_RAW="http://127.0.0.1:$GHPORT" sh -s -- --no-deps ) >"$WORK/install.log" 2>&1 </dev/null \
  || die 'the install line failed' "$(tail -n 5 "$WORK/install.log")"
[ -x "$CH/.local/bin/fleet" ] || die 'no fleet in ~/.local/bin after the install' "$(ls -la "$CH/.local/bin" 2>&1)"
[ "$(ghcalls)" = 0 ] && [ "$(ghhttp)" = 0 ] || die 'the install asked GitHub' "$(cat "$GHLOG" "$WORK/ghapi.log")"
ok "fleet installed from $HUB/install · gh 0 · github http 0"
passed

# =============================================================================
step 1 '登录: WeChat scan, bound by an invite, then fleet login in the terminal'
# The machine the person's login lives on: a node joined by the operator, as
# this OS login — the roster's evidence that the login exists (adoptMappedLogins).
L=$(id -un)
JC=$(api -X POST -H 'Content-Type: application/json' -d '{}' "$HUB/v1/fleet/join-codes" | jget code) \
  || die 'the operator API minted no join code'
J=$(curl -fsS -m 10 -H 'Content-Type: application/json' -X POST \
      -d "{\"code\":\"$JC\",\"hostname\":\"mac-a\",\"os_user\":\"$L\"}" "$HUB/v1/node/join") \
  || die '/v1/node/join refused the code'
NTOK=$(printf '%s' "$J" | jget token 2>/dev/null)
[ -n "$NTOK" ] || die 'the join answer had no token' "$J"
# Its agent is the real one (it puts the machine on the roster as $L); the fleet
# it reports is a stub: none until the test writes fleets.json (the fleet the
# sandbox login below hosts, so the hub knows the repo is here — #4898's task road).
NH="$WORK/node"; mkdir -p "$NH/.claude/fleet/bin" "$NH/state"
cat > "$NH/.claude/fleet/bin/fleet-control.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
req = json.load(sys.stdin); m = req.get("method")
try:
    FLEETS = json.load(open(os.path.join(os.environ["HOME"], "fleets.json")))
except (OSError, ValueError):
    FLEETS = []
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
if m == "discover":
    r = {"machine_id": "7e2e0000-0000-4000-8000-000000003605", "hostname": "mac-a", "protocol": 1,
         "observed_at": now, "fleets": FLEETS}
elif m == "ready":
    r = {"ready": True, "gh": False, "creds": True, "checkouts": True, "missing": [], "observed_at": now}
elif m == "fleet_status":
    r = {"state": "running", "observed_at": now, "workers": []}
else:
    print(json.dumps({"error": {"code": "INVALID_ARGUMENT", "message": "nogh-e2e stub node"}})); sys.exit(1)
print(json.dumps({"protocol": 1, "machine_id": "7e2e0000-0000-4000-8000-000000003605", "result": r}))
PY
chmod +x "$NH/.claude/fleet/bin/fleet-control.py"
( cd "$NH" && exec env -i PATH="$WORK/shim:$PATH" HOME="$NH" CCQUOTA_HUB_URL="$HUB" CCQUOTA_TOKEN="$NTOK" CCQUOTA_FLEET=1 \
    CCQUOTA_FLEET_NODE_ROUTES=lan=127.0.0.1:22 CCQUOTA_FLEET_NODE_TAILNET=0 \
    "$CCQN" agent --hub "$HUB" --home "$NH" --state "$NH/state" ) >"$WORK/agent.log" 2>&1 &
AGENT_PID=$!
on_roster() { api "$HUB/v1/nodes" 2>/dev/null | grep -q "\"$L\""; }
waitfor 60 on_roster || die "the machine's agent never reached the roster as $L" "$(api "$HUB/v1/nodes" 2>&1 | head -c 600; tail -n 5 "$WORK/agent.log")"
ok "the machine is on the roster: its agent runs as $L"
INV=$(api -X POST -H 'Content-Type: application/json' -d '{}' "$HUB/v1/fleet/invites" | jget code) \
  || die 'the operator API minted no invite'
out=$(browse get "$HUB/i/$INV") || die 'the invite link did not open' "$out"
out=$(browse get "$HUB/auth/wechat/start") || die 'the WeChat start did not answer' "$out"
case "$(head -1 <<<"$out")" in *"/auth/wechat/bind"*) ;; *) die 'a first scan did not land on the binding page' "$(head -c 400 <<<"$out")" ;; esac
grep -q '/sns/oauth2/access_token' "$WORK/wx.log" || die 'the hub never traded the code with WeChat' "$(cat "$WORK/wx.log")"
grep -q 'value="invite"' <<<"$out" || die 'the binding page did not offer the invite' "$(head -c 600 <<<"$out")"
me=$(browse get "$HUB/v1/me"); case "$me" in *'"via":"wechat"'*) die 'a first scan signed in before it was bound (an account made by itself)' "$me" ;; esac
out=$(browse post "$HUB/auth/wechat/bind" action=invite) || die 'the bind by invite failed' "$out"
me=$(browse get "$HUB/v1/me" | tail -n +2)
[ "$(printf '%s' "$me" | jget via 2>/dev/null)" = wechat ] || die '/v1/me does not say wechat after the bind' "$me"
PID=$(printf '%s' "$me" | jget person 2>/dev/null)
[ -n "$PID" ] || die '/v1/me names no person' "$me"
ok "WeChat scan bound by the invite: signed in as $PID (via wechat)"
# The operator gives the person their login on that machine (fleet hub set).
out=$(env -i PATH="$WORK/shim:$PATH" HOME="$WORK/op" CCQUOTA_VIEWER_TOKEN="$VT" FLEET_CONF_DIR="$WORK/op/conf" \
        python3 "$BIN/fleet-hub-admin.py" set --hub "$HUB" "user.$PID.machine_login" "$L" 2>&1) || die 'fleet hub set user.<id>.machine_login failed' "$out"
# The hub reads sessions by their window's ID (EPIC T497, switched on in
# production before C8 retired the launch proof): a record's end is its ID's.
out=$(env -i PATH="$WORK/shim:$PATH" HOME="$WORK/op" CCQUOTA_VIEWER_TOKEN="$VT" FLEET_CONF_DIR="$WORK/op/conf" \
        python3 "$BIN/fleet-hub-admin.py" set --hub "$HUB" fleet.id_switch on 2>&1) || die 'fleet hub set fleet.id_switch on failed' "$out"
# The terminal: fleet login, confirmed in the person's browser.
PH="$WORK/person"; mkdir -p "$PH/.ssh"; chmod 700 "$PH/.ssh"
# The person's terminal is this machine, where their login lives — a managed
# machine (FLEET_NODE_STATE/machine.env): `fleet login` asks for no device-key node
# pass and starts no join (fleet-node.sh ensure, #2904), so it runs the same on a
# CI runner as on the real machine.
mkdir -p "$WORK/nodestate"; : > "$WORK/nodestate/machine.env"
env -i PATH="$WORK/shim:$PATH" HOME="$PH" LANG=en_US.UTF-8 FLEET_LOGIN_BROWSER=0 PYTHONUNBUFFERED=1 \
  FLEET_NODE_STATE="$WORK/nodestate" \
  python3 "$BIN/fleet-login.py" --hub "$HUB" >"$WORK/login.out" 2>&1 </dev/null &
LOGIN_PID=$!
ucode() { grep -Eo '[A-Z]{4}-[A-Z]{4}' "$WORK/login.out" | head -1; }
has_code() { [ -n "$(ucode)" ]; }
waitfor 15 has_code || die 'fleet login printed no code' "$(cat "$WORK/login.out")"
UC=$(ucode)
out=$(browse get "$HUB/fleet/login?code=$UC") || die 'the login page did not open' "$out"
out=$(browse post "$HUB/fleet/login" code="$UC" action=approve) || die 'the confirm was refused' "$out"
waitfor 30 sh -c "! kill -0 $LOGIN_PID 2>/dev/null" || die 'fleet login still waiting after the confirm' "$(cat "$WORK/login.out")"
wait "$LOGIN_PID"; rc=$?; LOGIN_PID=''
[ "$rc" = 0 ] || die "fleet login exited $rc" "$(cat "$WORK/login.out"; printf '%s' "$out" | head -c 600)"
[ -f "$PH/.ssh/fleet-cert-cert.pub" ] || die 'no certificate in ~/.ssh' "$(ls -la "$PH/.ssh")"
princ=$(ssh-keygen -L -f "$PH/.ssh/fleet-cert-cert.pub" | awk '/Principals:/{f=1;next} f&&/:/{f=0} f{print $1}' | tr '\n' ' ')
case " $princ " in *" $L "*) ;; *) die "the certificate does not carry the login $L" "$princ" ;; esac
[ "$(ghcalls)" = 0 ] && [ "$(ghhttp)" = 0 ] || die 'the sign-in asked GitHub' "$(cat "$GHLOG" "$WORK/ghapi.log")"
ok "fleet login confirmed by the WeChat session: certificate for [${princ% }] · gh 0 · github http 0"
passed

# ---- the fleet's side: a sandbox login on the same machine ---------------------
# Real git, a real tmux server on a private socket, the agent a recorder. The repo
# lives at ssh://mac-a/~/repos/demo.git — git reaches a bare repo here for it.
REAL_GIT=$(command -v git)
cat > "$WORK/shim/tmux" <<EOF
#!/bin/bash
while [ "\${1:-}" = -L ] || [ "\${1:-}" = -S ]; do shift 2; done
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# The agent is a NATIVE stand-in (a few lines of Go, built here): a process whose
# kernel executable is named claude and answers `--version` as Claude Code, with
# the SessionStart hooks run by that process — the ID's segment, and the merged
# report on that ID that closes the record, come from the real hooks.
mkdir -p "$WORK/fakeclaude"
cat > "$WORK/fakeclaude/main.go" <<'GO'
package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "--version" {
		fmt.Println("9.9.9 (Claude Code)")
		return
	}
	if len(args) > 1 && args[0] == "plugin" {
		fmt.Println("[]")
		return
	}
	w, _ := exec.Command("tmux", "display-message", "-p", "-t", os.Getenv("TMUX_PANE"), "#{window_id}").Output()
	os.WriteFile(os.Getenv("FAKE_CLAUDE_REC")+"/"+strings.TrimSpace(string(w))+".args", []byte(strings.Join(args, " ")+"\n"), 0o644)
	b := make([]byte, 16)
	rand.Read(b)
	b[6], b[8] = b[6]&0x0f|0x40, b[8]&0x3f|0x80
	sid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
	cwd, _ := os.Getwd()
	// the transcript where the fleet looks for it (fleet_transcript_dir): a session the history ledger can resume
	dir := os.Getenv("HOME") + "/.claude/projects/" + strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			return r
		}
		return '-'
	}, cwd)
	os.MkdirAll(dir, 0o755)
	tr := dir + "/" + sid + ".jsonl"
	os.WriteFile(tr, []byte(`{"type":"summary"}`+"\n"), 0o644)
	ev, _ := json.Marshal(map[string]string{"hook_event_name": "SessionStart", "source": "startup", "session_id": sid, "cwd": cwd, "transcript_path": tr})
	for _, a := range args {
		if !strings.HasPrefix(a, "--settings=") {
			continue
		}
		var st struct {
			Hooks map[string][]struct {
				Hooks []struct{ Command string } `json:"hooks"`
			} `json:"hooks"`
		}
		raw, _ := os.ReadFile(strings.TrimPrefix(a, "--settings="))
		json.Unmarshal(raw, &st)
		for _, m := range st.Hooks["SessionStart"] {
			for _, h := range m.Hooks {
				c := exec.Command("/bin/sh", "-c", h.Command)
				c.Stdin = strings.NewReader(string(ev))
				c.Run()
			}
		}
	}
	time.Sleep(600 * time.Second)
}
GO
(cd "$WORK/fakeclaude" && GOTOOLCHAIN=local GOFLAGS="" GO111MODULE=off go build -o "$WORK/shim/claude" main.go) 2>"$WORK/err" \
  || die 'could not build the native stand-in for claude (go)' "$(cat "$WORK/err")"
export FAKE_CLAUDE_REC="$WORK/rec"
# the hooks the agent runs name ~/.claude/fleet/bin/…: this login's install is this tree
mkdir -p "$WORK/home/.claude" && ln -sfn "$(cd "$BIN/.." && pwd -P)" "$WORK/home/.claude/fleet"
chmod +x "$WORK/shim/tmux"
mkdir -p "$WORK/srv/repos"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[init]
	defaultBranch = master
[user]
	name = nogh-e2e
	email = nogh@example.invalid
[url "file://$WORK/srv/repos/"]
	insteadOf = ssh://mac-a/~/repos/
[url "file://$WORK/nowhere-github/"]
	insteadOf = https://github.com/
	insteadOf = git@github.com:
EOF
"$REAL_GIT" init -q --bare "$WORK/srv/repos/demo.git"
"$REAL_GIT" init -q "$WORK/seed"
printf 'demo\n' > "$WORK/seed/README"
# the repo's own check: every line of NOTES says hello
printf '#!/bin/sh\n[ ! -f NOTES ] || ! grep -qv hello NOTES\n' > "$WORK/seed/check.sh"
chmod +x "$WORK/seed/check.sh"
"$REAL_GIT" -C "$WORK/seed" add -A && "$REAL_GIT" -C "$WORK/seed" commit -qm init \
  && "$REAL_GIT" -C "$WORK/seed" push -q "$WORK/srv/repos/demo.git" master || die 'could not seed the bare repo'

export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" CLAUDE_CONFIG_DIR="$WORK/cc" TMPDIR="$WORK/tmp"
export PATH="$WORK/shim:$PATH" FLEET_SKIP_GLOBAL_CONF=1 FLEET_GLOBAL_MAX_SESSIONS=999
export FLEET_DISPATCH_LEASE_DIR="$WORK/leases" FLEET_LAND_LEASE_DIR="$WORK/leases" FLEET_TRASH_SWEEP_BUDGET=0
export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 FLEET_STATUS_7501=0 FLEET_HEAVY=0 FLEET_MCP=0 FLEET_ADMIT=0
export FLEET_STABLE_API="http://127.0.0.1:$GHPORT" FLEET_STABLE_RAW="http://127.0.0.1:$GHPORT"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_MODEL FLEET_AGENT FLEET_SESSION CF_REPO \
      CCQUOTA_HUB_URL CCQUOTA_TOKEN FLEET_FORGE FLEET_LAND FLEET_HUB_URL
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$CLAUDE_CONFIG_DIR" "$TMPDIR"
# The login's node token (the task record's API reads it in a subshell, #1491) —
# the machine's, whose login the person now holds.
printf 'CCQUOTA_TOKEN=%s\nCCQUOTA_HUB_URL=%s\nCCQUOTA_FLEET=1\n' "$NTOK" "$HUB" > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"
S=nogh
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos"
printf 'FLEET_SESSION=%s\nCCQUOTA_FLEET=1\nFLEET_CLEANUP_MERGED_GRACE=0\nFLEET_REAP_MIN_AGE=0\n' "$S" > "$FLEET_CONF_DIR/fleets/$S/conf"
"$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s "$S" -n home -x 200 -y 50 || die 'could not start the private tmux server'
tmux set-option -w -t "$S:home" @fleet_role home >/dev/null 2>&1
ADDR='ssh://mac-a/~/repos/demo.git'
tok=$(bash "$BIN/fleet-repo.sh" add --session "$S" "$ADDR" 2>"$WORK/err") || die 'fleet repo add refused the ssh address' "$tok $(cat "$WORK/err")"
R=mac-a/demo
. "$BIN/fleet-lib.sh"
[ "$tok" = "added:$(fleet_slug "$R")" ] || die 'fleet repo add named the repo otherwise' "$tok"
RCONF=$(fleet_repo_conf_file "$S" "$R")
# The fleet's identity (fleet_uuid), minted as fleet-control.py mints it from the
# machine id and (session, repo, checkout), frozen in the fleet's identity file —
# and reported by the machine's (stub) node, so the hub knows this fleet hosts $R.
MAIN=$(fleet_repo_conf_get "$S" "$R" FLEET_MAIN)
FID=$(python3 -c 'import json,sys,uuid; print(uuid.uuid5(uuid.UUID(sys.argv[1]), json.dumps(sys.argv[2:5], ensure_ascii=False, sort_keys=True, separators=(",", ":"))))' \
        7e2e0000-0000-4000-8000-000000003605 "$S" "$R" "$MAIN")
printf '%s\n' "$FID" > "$(fleet_identity_file "$S")"
python3 -c 'import json,sys; json.dump([dict(fleet_id=sys.argv[1], machine_id="7e2e0000-0000-4000-8000-000000003605", name=sys.argv[2], repo=sys.argv[3], repos=[sys.argv[3]], checkout=sys.argv[4], agent="claude")], open(sys.argv[5], "w"))' \
  "$FID" "$S" "$R" "$MAIN" "$NH/fleets.json"
hosted() { api "$HUB/v1/fleet/fleet_list" 2>/dev/null | grep -q "$FID"; }
printf 'FLEET_CHECK_CMD="./check.sh"\n' >> "$RCONF"
[ "$(git -C "$MAIN" config --get remote.origin.url)" = "$ADDR" ] || die 'the checkout is not a clone of the address' "$MAIN"
ok "repo $R ← $ADDR: FLEET_FORGE=none · FLEET_LAND=fleet · check ./check.sh"
WT=$MAIN
inpane() { local w="$1"; shift; ( cd "$WT" && TMUX="$SOCK,1,0" TMUX_PANE="$(tmux display-message -p -t "$w" '#{pane_id}')" "$@" ); }

# =============================================================================
step 2 '开单: the task record, for a repo with no GitHub'
T=$(printf '在 NOTES 里加一行 hello。\n\n上线证据：`cat NOTES` 的输出\n' \
      | bash "$BIN/fleet-task-record.sh" dispatch --title '在 NOTES 里加一行 hello' --body-file - --repo "$R" 2>"$WORK/err") \
  || die 'the hub refused the task record' "$T $(cat "$WORK/err")"
# the task's code first, then T<n> (EPIC T644 C3); the window still binds T<n>
OUT=$T; CODE=$(printf '%s\n' "$OUT" | head -1); T=$(printf '%s\n' "$OUT" | grep -E '^T[1-9][0-9]*$' | head -1)
case "$T" in T[1-9]*) ;; *) die 'the dispatch named no record' "$OUT $(cat "$WORK/err")" ;; esac
[ "$CODE" != "$T" ] || die 'the dispatch did not lead with the task code (a task_ids hub)' "$OUT"
trec() { browse get "$HUB/v1/fleet/tasks" | tail -n +2 | jq -c --arg t "$T" '.tasks[] | select(.id == $t)' 2>/dev/null; }
[ "$(trec | jq -r .repo 2>/dev/null)" = "$R" ] || die "the person's own browser does not list $T for $R (任务)" "$(browse get "$HUB/v1/fleet/tasks")"
[ "$(ghcalls)" = 0 ] || die 'recording asked gh' "$(cat "$GHLOG")"
ok "task $CODE ($T) for $R on the hub, in the WeChat person's own list · no issue filed · gh 0"
passed

# =============================================================================
step 3 '派活: a session opens on the record'
# The same words again with --spawn: the same record (one per caller + words), and
# its session opens here bound to it (dash-raw-session.sh --repo --task: the
# window's ID is the session, nothing claims the record) — once the hub has heard
# this machine host $R.
waitfor 60 hosted || die "the hub never heard this machine host $R" "$(api "$HUB/v1/fleet/fleet_list" 2>&1 | head -c 600)"
T2=$(printf '在 NOTES 里加一行 hello。\n\n上线证据：`cat NOTES` 的输出\n' \
      | FLEET_SESSION="$S" bash "$BIN/fleet-task-record.sh" dispatch --title '在 NOTES 里加一行 hello' --body-file - --repo "$R" --spawn \
        2>"$WORK/err" | grep -E '^T[1-9][0-9]*$' | head -1)
[ "$T2" = "$T" ] || die "the same words named another record ($T2, not $T)" "$(cat "$WORK/err")"
W=$(tmux list-windows -t "$S" -F '#{window_id} #{@repo} #{@task}' | awk -v r="$R" -v t="$T" '$2==r && $3==t {print $1; exit}')
[ -n "$W" ] || die "no window bound to $T" "$(tmux list-windows -t "$S" -F '#{window_id} #{window_name} #{@repo} #{@task}'; cat "$WORK/err")"
WT=$(tmux display-message -p -t "$W" '#{@worktree}')
BR=$(git -C "$WT" symbolic-ref --short HEAD 2>/dev/null)
[ -d "$WT" ] && [ -n "$BR" ] || die 'the session has no worktree of its own' "$WT"
[ "$(fleet_worktree_task "$WT")" = "$T" ] || die 'the worktree does not remember its record' "$(fleet_worktree_task "$WT")"
seen() { [ -s "$WORK/rec/$W.args" ]; }
waitfor 20 seen || die 'the agent never started in the window' "$(tmux capture-pane -p -t "$W" | tail -20)"
# its first turn is the person's words; no launch proof binds the window (EPIC T497 C8)
grep -q 'NOTES' "$WORK/rec/$W.args" 2>/dev/null || die "the session's first turn is not the person's words" "$(cat "$WORK/rec/$W.args" 2>&1)"
[ -z "$(tmux display-message -p -t "$W" '#{@launch}')" ] || die 'the session holds a retired launch binding'
fleet_is_fid "$(tmux display-message -p -t "$W" '#{@fleet_id}')" || die 'the session has no ID'
[ "$(ghcalls)" = 0 ] || die 'the dispatch asked gh' "$(cat "$GHLOG")"
ok "window $W · worktree $(basename "$WT") on $BR · its ID bound to $T · its first turn the words · gh 0"
passed

# =============================================================================
step 4 '执行: the session reads its record and changes the repo'
inpane "$W" bash "$BIN/fleet-brief.sh" >"$WORK/out" 2>"$WORK/err" || die "the brief exited $?" "$(cat "$WORK/out" "$WORK/err")"
grep -q '在 NOTES 里加一行 hello' "$WORK/out" || die 'the brief did not read the record off the hub' "$(head -c 1500 "$WORK/out")"
printf 'hello\n' > "$WT/NOTES"
git -C "$WT" add NOTES && git -C "$WT" commit -qm "NOTES: hello ($T)" || die 'could not commit in the worktree'
[ "$(ghcalls)" = 0 ] || die 'the work asked gh' "$(cat "$GHLOG")"
ok "brief read $T off the hub · committed $(git -C "$WT" rev-parse --short HEAD) · gh 0"
passed

# =============================================================================
step 5 '落地: the fleet lands it — no pull request — and the report closes the record'
v=$(inpane "$W" bash "$BIN/fleet-pr-verdict.sh" 2>"$WORK/err"); rc=$?
[ "$v" = READY ] && [ "$rc" = 0 ] || die "pr_verdict said ${v:-nothing} (exit $rc)" "$(cat "$WORK/err")"
v=$(inpane "$W" bash "$BIN/fleet-pr-merge.sh" 2>"$WORK/err"); rc=$?
[ "$v" = MERGED ] && [ "$rc" = 0 ] || die "pr_merge said ${v:-nothing} (exit $rc)" "$(cat "$WORK/err")"
grep -q 'check passed' "$WORK/err" || die "the landing does not say the repo's check passed" "$(cat "$WORK/err")"
[ "$("$REAL_GIT" --git-dir="$WORK/srv/repos/demo.git" show master:NOTES 2>/dev/null)" = hello ] \
  || die "the bare repo's master does not carry the change" "$("$REAL_GIT" --git-dir="$WORK/srv/repos/demo.git" log --oneline master)"
fleet_landed "$R" "$BR" "$MAIN" master >/dev/null || die "git does not say $BR landed (fleet_landed)"
inpane "$W" bash "$BIN/fleet-report-parent.sh" --state merged --summary 'NOTES 加了一行 hello' >"$WORK/out" 2>"$WORK/err" \
  || die "the session's merged report was refused (exit $?)" "$(cat "$WORK/out" "$WORK/err")"
grep -q 'NOT reporting MERGED' "$WORK/err" && die "the merged report with no PR was re-filed as not merged" "$(cat "$WORK/err")"
closed() { fleet_task_closed "$T" >/dev/null; }
waitfor 15 closed || die "the record $T is still open after the merged report" "$(trec; cat "$WORK/err")"
[ "$(ghcalls)" = 0 ] || die 'landing asked gh' "$(cat "$GHLOG")"
ok "READY → MERGED: master at $("$REAL_GIT" --git-dir="$WORK/srv/repos/demo.git" rev-parse --short master) · check passed · fleet_landed · $T closed by the report · gh 0"
passed

# =============================================================================
step 6 '回收: the cleanup daemon reaps the window, the worktree and the branch'
# The fake native process above deliberately has no Claude mod/composer. Give
# its completed turn an explicit native idle proof through the existing seam;
# a done stamp alone must no longer bypass unknown input at final close.
cat > "$WORK/native-idle.py" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"ok": True}))
PY
chmod +x "$WORK/native-idle.py"
export FLEET_GATE_PARK_PROBE_CMD="$WORK/native-idle.py"
tmux set-option -w -t "$W" @claude_state "done"
tmux set-option -w -t "$W" @claude_state_ts "$(( $(date +%s) - 3600 ))"
bash "$BIN/fleet-cleanup-daemon.sh" "$S" >"$WORK/out" 2>"$WORK/err" || die "the cleanup tick exited $?" "$(cat "$WORK/err")"
# The first tick only shows the window its notice (a minute, #565); the next one,
# that minute later, reaps — the minute is moved, not waited.
due=$(tmux display-message -p -t "$W" '#{@reap_due}' 2>/dev/null)
case "$due" in ''|*[!0-9]*) die 'the first cleanup tick did not put up its notice' "$(cat "$WORK/out" "$WORK/err")" ;; esac
tmux set-option -w -t "$W" @reap_due "$(( $(date +%s) - 1 ))"
bash "$BIN/fleet-cleanup-daemon.sh" "$S" >"$WORK/out" 2>"$WORK/err" || die "the second cleanup tick exited $?" "$(cat "$WORK/err")"
gone() { ! tmux list-windows -a -F '#{window_id}' | grep -qxF "$W"; }
waitfor 20 gone || die 'the window is still there after the cleanup tick' "$(cat "$WORK/out" "$WORK/err")"
# the cleanup tick closes the window (history first) and keeps the worktree for
# the janitor, which prunes a closed record's clean worktree and its branch (#4897)
bash "$BIN/worktree-autoclean.sh" >"$WORK/out" 2>"$WORK/err" || die "the worktree janitor exited $?" "$(cat "$WORK/out" "$WORK/err")"
[ ! -d "$WT" ] || die 'the worktree is still there after the janitor' "$(cat "$WORK/out" "$WORK/err")"
! git -C "$MAIN" rev-parse --verify -q "refs/heads/$BR" >/dev/null || die "the branch $BR is still there" "$(cat "$WORK/err")"
# the resume ledger (fleet-history.sh): the session's key, its record, the native session, the commit
LEDGER="$FLEET_CONF_DIR/logs/landed_$(fleet_slug "$R").tsv"   # the login's records, never the install (#4668)
awk -F'\t' -v k="$BR" -v t="$T" '$2 == k && $15 == t && $8 ~ /^[0-9a-f-]{36}$/ && $5 ~ /^[0-9a-f]{40}$/' "$LEDGER" 2>/dev/null | grep -q . \
  || die 'no landed row for the reaped session in the history ledger' "$(cat "$LEDGER" 2>&1; cat "$WORK/err")"
[ "$(ghcalls)" = 0 ] || die 'the cleanup asked gh' "$(cat "$GHLOG")"
ok "window closed by its record, worktree and branch pruned; the history ledger has the resumable row · gh 0"
passed

# =============================================================================
step 7 '报告: what the person reads'
[ "$(trec | jq -r '.outcome // .state')" != open ] || die "the person's list still shows $T open" "$(trec)"
LREC="$FLEET_CONF_DIR/landed/$(fleet_slug "$R").ndjson"
jq -e --arg b "$BR" 'select(.branch == $b and .check == "pass")' "$LREC" >/dev/null 2>&1 \
  || die 'no landing record that says the check passed' "$(cat "$LREC" 2>&1)"
[ "$(ghcalls)" = 0 ] && [ "$(ghhttp)" = 0 ] || die 'the report asked GitHub' "$(cat "$GHLOG" "$WORK/ghapi.log")"
ok "$T: $(trec | jq -r '.outcome // .state') in the person's list · landing record (check pass) · gh 0"
passed

printf '\nnogh-e2e: steps: %s/7 · gh calls: %s · github http: %s\n' "$STEPS" "$(ghcalls)" "$(ghhttp)"
[ "$STEPS" = 7 ] && [ "$(ghcalls)" = 0 ] && [ "$(ghhttp)" = 0 ]
