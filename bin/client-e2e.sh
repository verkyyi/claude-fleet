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
#   4. open    — that `fleet`: the thin client (fleet-thin.py — the only client
#                since issue #3008), which asks its home for a 看台 over one ssh:
#                `fleet-remote-view.sh attach --thin --view … --device … --token …`
#
# Two stand-ins, the ones CI cannot reach: the home's pick (FLEET_THIN_ARGV_CMD in
# place of fleet-connect.py --argv, which needs a person's certificate) and ssh to
# it (a fake node has no sshd) — a shim that records the remote command and ends
# it like a detach. (The old client's list and switch steps went with it; the
# home's list is the node's own, fleet-view-*-selftest.sh.) Every temp server
# binds 127.0.0.1, and the whole run is bounded (CLIENT_E2E_DEADLINE, default 240s).
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
VT="e2e-viewer-$$-$RANDOM"          # the operator's viewer token, this run only
START=$(date +%s)
DEADLINE=${CLIENT_E2E_DEADLINE:-240}
HUB_PID='' AGENT_PID=''

STEP=''
step() { STEP=$1; printf '\n== %s · %ss\n' "$1" "$(( $(date +%s) - START ))"; }
ok() { printf '   ✓ %s\n' "$1"; }
logs() {
  local f
  for f in hub.log agent.log install.log fleet.err ssh.log thin.log; do
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
cleanup() {
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null
  [ -n "$HUB_PID" ] && kill "$HUB_PID" 2>/dev/null
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
[ -f "$IH/bin/fleet-thin.py" ] && [ -x "$IH/bin/fleet-connect.py" ] || die 'the client files are not in ~/.claude/fleet' "$(find "$IH" -maxdepth 2 2>&1 | head -20)"
[ ! -e "$IH/bin/fleet-shell.sh" ] || die 'the install line still ships the old client (#3008)' "$IH/bin/fleet-shell.sh"
grep -qs "FLEET_HUB_URL=\"\\{0,1\\}$HUB" "$CH/.config/claude-fleet/fleet.conf" || die 'fleet.conf does not carry the hub address' "$(cat "$CH/.config/claude-fleet/fleet.conf" 2>&1)"
ok "fleet installed ($(find "$IH" -type f | wc -l | tr -d ' ') files), fleet.conf names $HUB"

# =============================================================================
step 'open: the installed fleet is the thin client, and asks its home for a 看台'
# ssh to the home is the stand-in (a fake node has no sshd): it records the remote
# command and ends like a detach (exit 0), so the client ends too
SHIM="$WORK/shim"; mkdir -p "$SHIM"
cat > "$SHIM/ssh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/ssh.log"
exit 0
EOF
chmod +x "$SHIM/ssh"
cat > "$WORK/ptyrun.py" <<'EOPTY'
import os, select, sys
# run argv[1:] on a pseudo-terminal of its own (the thin client wants one), its
# output on stdout once it ends, its exit code ours
pid, fd = os.forkpty()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
out = b""
while True:
    r, _, _ = select.select([fd], [], [], 60)
    if not r:
        break
    try:
        d = os.read(fd, 65536)
    except OSError:
        break
    if not d:
        break
    out += d
_, st = os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
sys.exit(os.waitstatus_to_exitcode(st) if hasattr(os, "waitstatus_to_exitcode") else (st >> 8))
EOPTY
# the home's pick (fleet-connect.py --argv needs a person's certificate): the node
cat > "$SHIM/argv.sh" <<EOF
#!/bin/sh
printf '{"argv": ["$SHIM/ssh", "%s"], "host": 1, "route": {"name": "lan"}}\n' "$NODE"
EOF
out=$(cd "$CH" && env -i PATH="$CH/.local/bin:$PATH" HOME="$CH" SHELL=/bin/bash TERM=xterm-256color LANG=C.UTF-8 \
        FLEET_NODE_STATE="$WORK/no-node" FLEET_THIN_ARGV_CMD="sh $SHIM/argv.sh" FLEET_THIN_LOG="$WORK/thin.log" \
        FLEET_HUB_TOKEN="$VT" CCQUOTA_VIEWER_TOKEN="$VT" FLEET_ITERM_KEYS=0 \
        python3 "$WORK/ptyrun.py" "$FLEET" </dev/null 2>"$WORK/fleet.err"); rc=$?
[ "$rc" = 0 ] || die "fleet exited $rc" "$(tail -n 5 "$WORK/fleet.err") $out"
grep -q 'fleet-remote-view.sh attach --thin' "$WORK/ssh.log" || die 'the client never asked its home for a 看台' "$(cat "$WORK/ssh.log" 2>/dev/null)"
for w in --view --device --token; do
  grep -q -- "$w" "$WORK/ssh.log" || die "the 看台's attach carries no $w" "$(cat "$WORK/ssh.log")"
done
grep -q "$NODE" "$WORK/ssh.log" || die "the ssh did not go to the home ($NODE)" "$(cat "$WORK/ssh.log")"
ok "fleet → fleet-thin.py → ssh $NODE … attach --thin ($(wc -l < "$WORK/ssh.log" | tr -d ' ') connection)"

printf '\nclient-e2e: GREEN — installed from %s/install and opened the client in %ss\n' "$HUB" "$(( $(date +%s) - START ))"
