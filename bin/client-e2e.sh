#!/bin/bash
# client-e2e.sh — install a FRESH client from the install line and use it,
# against a hub built from this same checkout (issue #1724, EPIC #1718 C6).
#
#   bin/client-e2e.sh --ccquota <ccquota binary built from tokenledger/>
#
# The one way in is `curl -fsSL <hub>/install | sh` and then `fleet`; when either
# breaks, nobody gets in — and until this ran on every merge, that breakage was
# found only by the next person who opened their client. So, end to end, nothing
# mocked between the install line and the list:
#
#   1. hub     — `ccquota hub` on 127.0.0.1 with the fleet module, a throwaway
#                SSH CA and placeholder GitHub sign-in settings (the two things
#                /install needs before it serves the installer — never a real
#                secret), and CCQUOTA_FLEET_STABLE_REPO=off: it serves the
#                client packed from THIS checkout — following GitHub's stable
#                (#1805) it had been installing stable's, never the change
#                under test (#2096)
#   2. node    — a FAKE node: a join code from the operator API, redeemed at
#                /v1/node/join, and the REAL `ccquota agent` with that token in a
#                home of its own whose ~/.claude/fleet/bin/fleet-control.py
#                answers with two canned sessions (a worker and a scratch) — so
#                the rows reach the hub over the real control channel
#   3. install — `curl -fsSL <hub>/install | sh` into a temp HOME (deps step on:
#                it is part of the line), `fleet` lands in ~/.local/bin, every
#                file is the hub's copy
#   4. open    — that `fleet`, headless (FLEET_SHELL_NO_ATTACH=1, its own tmux
#                socket), with the operator's viewer token as its identity: the
#                hub picks the node, the right pane is that machine
#   5. list    — the client's own loop writes the node's sessions; the list
#                (tmux-dashboard-rows.sh --sidebar, what the left pane draws)
#                shows both rows
#   6. switch  — `open` on the worker row: the right pane now points at it
#                (@remote=<node>:<worker_id>)
#
# The only stand-in is ssh to the node (a fake node has no sshd): a shim that
# holds the control socket the client expects and records the remote command —
# the one thing CI cannot reach. Every temp server binds 127.0.0.1, and the
# whole run is bounded (CLIENT_E2E_DEADLINE, default 240s).
#
# Env: CLIENT_E2E_WORK (keep the work dir there instead of a temp one, not
# removed) · CLIENT_E2E_NO_DEPS=1 (pass --no-deps to the install line; CI keeps
# the deps step on). Exit 0 = every step green; 1 = a step failed (its name and
# the logs are printed); 2 = usage.
set -uo pipefail

CCQ=''
while [ $# -gt 0 ]; do
  case "$1" in
    --ccquota) CCQ=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'client-e2e: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$CCQ" ] && [ -x "$CCQ" ] || { printf 'client-e2e: --ccquota <built ccquota binary> is required\n' >&2; exit 2; }
CCQ=$(cd "$(dirname "$CCQ")" && pwd -P)/$(basename "$CCQ")
for c in curl python3 ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || { printf 'client-e2e: %s is required\n' "$c" >&2; exit 2; }
done

KEEP=0
if [ -n "${CLIENT_E2E_WORK:-}" ]; then WORK=$CLIENT_E2E_WORK; KEEP=1; mkdir -p "$WORK" || exit 2
else WORK=$(mktemp -d "${TMPDIR:-/tmp}/cfe2e.XXXXXX") || exit 2; fi
WORK=$(cd "$WORK" && pwd -P)
SESS="cfe2e$$"                      # the client's session = its own tmux socket
VT="e2e-viewer-$$-$RANDOM"          # the operator's viewer token, this run only
REAL_TMUX=tmux                      # resolved after the install (its tmux step)
START=$(date +%s)
DEADLINE=${CLIENT_E2E_DEADLINE:-240}
HUB_PID='' AGENT_PID='' SC=''

STEP=''
step() { STEP=$1; printf '\n== %s · %ss\n' "$1" "$(( $(date +%s) - START ))"; }
ok() { printf '   ✓ %s\n' "$1"; }
logs() {
  local f
  for f in hub.log agent.log install.log fleet.err ssh.log; do
    [ -s "$WORK/$f" ] || continue
    printf -- '--- %s (last 40)\n' "$f"; tail -n 40 "$WORK/$f"
  done
}
die() {
  printf '   ✗ %s: %s\n' "$STEP" "$1" >&2
  [ $# -gt 1 ] && printf '     got: %s\n' "$2" >&2
  logs >&2
  printf '\nclient-e2e: RED at step "%s" after %ss\n' "$STEP" "$(( $(date +%s) - START ))" >&2
  exit 1
}
# waitfor <secs> <cmd…> — until the command succeeds (re-run each try)
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
  # the client's own loops (keeper, hub-sessions) run from its cache's bin/
  [ -n "$SC" ] && pkill -f "$SC/bin/" 2>/dev/null
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null
  [ -f "$WORK/master.pid" ] && kill "$(cat "$WORK/master.pid")" 2>/dev/null
  [ -n "$SC" ] && rm -rf "$SC"
  [ "$KEEP" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
HUB="http://127.0.0.1:$PORT"
api() { curl -fsS -m 10 -H "Authorization: Bearer $VT" "$@"; }

# =============================================================================
step 'hub: ccquota hub on 127.0.0.1 with the fleet module'
ssh-keygen -q -t ed25519 -N '' -C client-e2e-ca -f "$WORK/ca" || die 'ssh-keygen could not make the CA key'
mkdir -p "$WORK/dist"
# /install is served only once the hub can sign someone in (an SSH CA + GitHub
# sign-in); these are placeholders for a hub that never meets a person.
env CCQUOTA_FLEET=1 CCQUOTA_VIEWER_TOKEN="$VT" CCQUOTA_FLEET_DIST_DIR="$WORK/dist" \
    CCQUOTA_FLEET_SSH_CA_KEY="$WORK/ca" CCQUOTA_GITHUB_CLIENT_ID=client-e2e \
    CCQUOTA_GITHUB_CLIENT_SECRET="placeholder-$RANDOM$RANDOM" \
    CCQUOTA_FLEET_STABLE_REPO=off \
  "$CCQ" hub --addr "127.0.0.1:$PORT" --db "$WORK/hub.db" >"$WORK/hub.log" 2>&1 &
HUB_PID=$!
waitfor 20 curl -fs -m 2 -o /dev/null "$HUB/healthz" || die 'the hub never answered /healthz'
ok "hub up at $HUB"
code=$(curl -s -m 10 -o "$WORK/install.sh" -w '%{http_code}' "$HUB/install")
[ "$code" = 200 ] || die 'GET /install did not serve the installer' "HTTP $code"
ok 'GET /install serves the installer'

# =============================================================================
step 'node: a fake node joins and reports two sessions over the real agent'
NH="$WORK/node"; mkdir -p "$NH/.claude/fleet/bin" "$NH/state"
code=$(api -X POST -H 'Content-Type: application/json' -d '{}' "$HUB/v1/fleet/join-codes") \
  || die 'the operator API minted no join code'
JC=$(printf '%s' "$code" | python3 -c 'import json,sys; print(json.load(sys.stdin)["code"])' 2>/dev/null)
[ -n "$JC" ] || die 'the join-code answer had no code' "$code"
J=$(curl -fsS -m 10 -H 'Content-Type: application/json' -X POST \
      -d "{\"code\":\"$JC\",\"hostname\":\"e2enode\",\"os_user\":\"$(id -un)\"}" "$HUB/v1/node/join") \
  || die '/v1/node/join refused the code'
NTOK=$(printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null)
NODE=$(printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("label") or "")' 2>/dev/null)
[ -n "$NTOK" ] && [ -n "$NODE" ] || die 'the join answer had no token / label' "$(printf '%s' "$J" | sed 's/"token":"[^"]*"/"token":"…"/')"
ok "joined as node $NODE"
MID=7e2e0000-0000-4000-8000-000000000001
# fleet_id derives from the machine (the hub skips a fleet whose id does not):
# uuid5(machine_id, canonical([session, repo, checkout])), as fleet_control.py.
FID=$(python3 -c 'import json,sys,uuid; print(uuid.uuid5(uuid.UUID(sys.argv[1]), json.dumps(sys.argv[2:], ensure_ascii=False, sort_keys=True, separators=(",", ":"))))' "$MID" acme acme/app /w/acme)
# The node's ONE fleet interface, fleet-control.py (the agent never reads tmux):
# discover names one fleet, fleet_status answers its two sessions.
cat > "$NH/.claude/fleet/bin/fleet-control.py" <<EOF
#!/usr/bin/env python3
import json, sys, time
req = json.load(sys.stdin)
m = req.get("method")
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def w(key, issue, scratch, state):
    return {"worker_id": "$FID/" + key, "key": key, "window_id": "@" + str(issue or 9), "issue": issue,
            "repo": "acme/app", "scratch": scratch, "worktree": "/w/" + key, "state": state,
            "lifecycle": "awake", "agent": "claude", "handle": ""}
if m == "discover":
    r = {"machine_id": "$MID", "hostname": "e2enode", "protocol": 1, "observed_at": now,
         "fleets": [{"fleet_id": "$FID", "machine_id": "$MID", "name": "acme", "repo": "acme/app",
                     "repos": ["acme/app"], "checkout": "/w/acme", "agent": "claude"}]}
elif m == "ready":
    r = {"ready": True, "gh": True, "creds": True, "checkouts": True, "missing": [], "observed_at": now}
elif m == "fleet_status":
    r = {"state": "running", "observed_at": now,
         "workers": [w("issue-7", 7, False, "working"), w("scratch-3", None, True, "idle")]}
else:
    print(json.dumps({"error": {"code": "INVALID_ARGUMENT", "message": "client-e2e fake node"}})); sys.exit(1)
print(json.dumps({"protocol": 1, "machine_id": "$MID", "result": r}))
EOF
chmod +x "$NH/.claude/fleet/bin/fleet-control.py"
# Its route is configured, as an operator configures a node's (no tailnet route:
# CI has none, and a dev box's would make the run depend on it). The client's
# ssh never dials it — the shim below stands in for the node's sshd.
( cd "$NH" && exec env HOME="$NH" CCQUOTA_HUB_URL="$HUB" CCQUOTA_TOKEN="$NTOK" CCQUOTA_FLEET=1 \
    CCQUOTA_FLEET_NODE_ROUTES=lan=127.0.0.1:22 CCQUOTA_FLEET_NODE_TAILNET=0 \
    "$CCQ" agent --hub "$HUB" --home "$NH" --state "$NH/state" ) >"$WORK/agent.log" 2>&1 &
AGENT_PID=$!
has_rows() {
  api "$HUB/v1/fleet/fleet_sessions" >"$WORK/sessions.json" 2>/dev/null &&
    grep -q "$FID/issue-7" "$WORK/sessions.json" && grep -q "$FID/scratch-3" "$WORK/sessions.json"
}
waitfor 60 has_rows || die 'the hub never listed the node'"'"'s two sessions' "$(head -c 600 "$WORK/sessions.json" 2>/dev/null)"
# the machine's name is what its agent reports (the host's own name), not the
# join label — the client knows it by that name
NODE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sessions"][0]["machine_name"])' "$WORK/sessions.json")
ok "the hub lists issue-7 and scratch-3 on machine $NODE"

# =============================================================================
step 'install: curl -fsSL <hub>/install | sh into a fresh HOME'
CH="$WORK/client"; mkdir -p "$CH"
deps=''; [ "${CLIENT_E2E_NO_DEPS:-0}" = 1 ] && deps='-s -- --no-deps'
# shellcheck disable=SC2086  # $deps is deliberately split into sh's arguments
( cd "$CH" && curl -fsSL "$HUB/install" | env -i PATH="$PATH" HOME="$CH" SHELL=/bin/bash TERM=dumb \
    FLEET_INSTALL_NO_RUN=1 sh $deps ) >"$WORK/install.log" 2>&1 || die 'the install line failed' "$(tail -n 5 "$WORK/install.log")"
FLEET="$CH/.local/bin/fleet"
[ -x "$FLEET" ] || die 'no fleet in ~/.local/bin after the install' "$(ls -la "$CH/.local/bin" 2>&1)"
IH="$CH/.claude/fleet"   # the one fleet directory (#1804)
[ -x "$IH/bin/fleet-shell.sh" ] && [ -f "$IH/conf/tmux-shell.conf" ] || die 'the client files are not in ~/.claude/fleet' "$(find "$IH" -maxdepth 2 2>&1 | head -20)"
grep -qs "FLEET_HUB_URL=\"\\{0,1\\}$HUB" "$CH/.config/claude-fleet/fleet.conf" || die 'fleet.conf does not carry the hub address' "$(cat "$CH/.config/claude-fleet/fleet.conf" 2>&1)"
# tmux is the install line's to provide (its deps step) — from here on it must be there
REAL_TMUX=$(PATH="$CH/.local/bin:$CH/.local/share/claude-fleet-vendor/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" command -v tmux) || die 'no tmux after the install line' "$(grep -i tmux "$WORK/install.log")"
ok "fleet installed ($(find "$IH" -type f | wc -l | tr -d ' ') files), fleet.conf names $HUB"

# =============================================================================
step 'open: the installed fleet, headless, on its own tmux socket'
# ssh to the node is the one stand-in (a fake node has no sshd): a master holds
# the control socket the client checks, select/watch answer like the far end.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ssh" <<EOF
#!/bin/bash
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
host=\$1; shift
printf '%s\t%s\n' "\$host" "\$*" >> "$WORK/ssh.log"
case "\$*" in
  *" attach "*)
    [ -n "\$ctl" ] && python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(1); time.sleep(600)' "\$ctl" &
    echo \$! > "$WORK/master.pid"; wait ;;
  *" watch "*) sleep 600 ;;
esac
exit 0
EOF
chmod +x "$SHIM/ssh"
# A unix socket path must fit in 104 bytes: the client's cache (its control
# sockets) goes under a short dir, not the work dir.
SC=$(mktemp -d /tmp/cfe2e-c.XXXXXX) || die 'no short cache dir'
# The agent reports this computer's own hostname as the node's: the client must
# not take itself for that machine (with no fleet of this login here it would
# show the home page instead of connecting — issue #2219). Its own dir, not
# $SHIM: an `ssh` on the PATH would answer fleet-connect's `ssh -G` too.
HSHIM="$WORK/hshim"; mkdir -p "$HSHIM"
printf '#!/bin/sh\necho client-laptop\n' > "$HSHIM/hostname"; chmod +x "$HSHIM/hostname"
cenv() {
  env -i PATH="$HSHIM:$CH/.local/bin:$PATH" HOME="$CH" SHELL=/bin/bash TERM=xterm-256color LANG=C.UTF-8 \
    FLEET_SHELL_SESSION="$SESS" FLEET_SHELL_CACHE="$SC" FLEET_SHELL_NO_ATTACH=1 FLEET_SHELL_WARM=0 \
    FLEET_HUB_TOKEN="$VT" CCQUOTA_VIEWER_TOKEN="$VT" FLEET_REMOTE_SSH_CMD="$SHIM/ssh" \
    FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_LOOP_SECS=8 "$@"
}
out=$(cenv "$FLEET" 2>"$WORK/fleet.err"); rc=$?
[ "$rc" = 0 ] || die "fleet exited $rc" "$(tail -n 5 "$WORK/fleet.err")"
[ "$out" = "$SESS" ] || die 'fleet did not print its session' "$out"
ts has-session -t "=$SESS" 2>/dev/null || die 'the client tmux server is not up'
# a client attached (the list is drawn for an attached session): control mode,
# its stdin a fifo held open until the end
mkfifo "$WORK/client.fifo"
"$REAL_TMUX" -L "$SESS" -C attach-session -t "=$SESS" <"$WORK/client.fifo" >/dev/null 2>&1 &
exec 7>"$WORK/client.fifo"
# The proxy windows: on the client's STAGE server (`<session>-stage`, issue
# #1759), or — a client installed before it — on its own server.
P="$SESS"; waitfor 5 "$REAL_TMUX" -L "$SESS-stage" has-session -t "=$SESS-stage" && P="$SESS-stage"
tp() { "$REAL_TMUX" -L "$P" "$@"; }
STG=''; [ "$P" = "$SESS" ] || STG=$P
w1=$(tp list-windows -t "=$P" -F '#{window_id}' | head -1)
remote=$(tp show-options -wqv -t "$w1" @remote)
[ "$remote" = "$NODE:" ] || die "the right pane is not the node ($NODE:)" "@remote=$remote · $(tp list-windows -t "=$P" -F '#{window_name}' | tr '\n' ' ')"
waitfor 15 grep -q "attach --shell" "$WORK/ssh.log" || die 'the client never asked the node for attach --shell' "$(cat "$WORK/ssh.log" 2>/dev/null)"
ok "client up on -L $SESS: window $(tp display-message -p -t "$w1" '#{window_name}') on -L $P (@remote=$remote)"

# =============================================================================
step 'list: the client lists the node'"'"'s sessions'
G="$SC/tmp/.claude-dash/global"
waitfor 30 test -s "$G/remote_$SESS" || die 'the client loop wrote no session cache' "$(ls -la "$G" 2>&1)"
waitfor 15 grep -q "$FID/issue-7" "$G/remote_$SESS" || die 'the session cache has no issue-7' "$(tr '\037' '|' <"$G/remote_$SESS")"
sock=$(ts display-message -p '#{socket_path}')
rows() {
  ( cd "$SC/bin" && cenv TMUX="$sock,0,0" FLEET_SHELL=1 FLEET_SESSION="$SESS" FLEET_SIDEBAR_CURRENT="$w1" \
      FLEET_SIDEBAR_SOURCE=hub CCQUOTA_FLEET=1 TMPDIR="$SC/tmp" FLEET_HUB_SESSIONS_CLIENT="$SESS" \
      bash "$SC/bin/tmux-dashboard-rows.sh" --sidebar 2>/dev/null | tr '\037' '|' )
}
r=$(rows)
case "$r" in *issue-7*) ;; *) die 'the list has no issue-7 row' "$r" ;; esac
case "$r" in *scratch-3*) ;; *) die 'the list has no scratch-3 row' "$r" ;; esac
case "$r" in *"$NODE!"*) die 'the list marks the node lost while the hub answers' "$r" ;; esac
ok 'the list shows issue-7 and scratch-3 on the node'

# =============================================================================
step 'switch: open the issue-7 row, the right pane points at it'
waitfor 10 test -S "$(tp show-options -wqv -t "$w1" @remote_ctl)" || die 'no live @remote_ctl on the node window' "$(tp show-options -wqv -t "$w1" @remote_ctl)"
got=$(cd "$SC/bin" && cenv TMUX="$sock,0,0" FLEET_SHELL=1 ${STG:+FLEET_SHELL_STAGE="$STG"} FLEET_SESSION="$SESS" CCQUOTA_FLEET=1 TMPDIR="$SC/tmp" \
        FLEET_CONF_DIR="$CH/.config/claude-fleet" bash "$SC/bin/fleet-remote-view.sh" open "wid:$FID/issue-7" 2>&1)
remote=$(tp show-options -wqv -t "$w1" @remote)
[ "$remote" = "$NODE:$FID/issue-7" ] || die "the right pane does not point at issue-7" "open → $got · @remote=$remote"
grep -q "select '$FID/issue-7'" "$WORK/ssh.log" || die 'the node was not asked to select issue-7' "$(cat "$WORK/ssh.log")"
ok "@remote=$remote, window $(tp display-message -p -t "$w1" '#{window_name}')"

printf '\nclient-e2e: GREEN — installed from %s/install, listed and switched in %ss\n' "$HUB" "$(( $(date +%s) - START ))"
