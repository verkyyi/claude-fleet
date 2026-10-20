#!/usr/bin/env bash
# fleet-cred-rollout-selftest.sh — `fleet cred-proxy status` and its switch
# (bin/fleet-cred-rollout.sh, issue #2134, EPIC #2133 C4; issue #4674) on a
# sandbox login: sandbox HOME + FLEET_CONF_DIR, a proxy on loopback, a process
# table from a fixture file.
#
#   A  off (the degenerate): status reads `off · - · sessions 0/4` and changes
#      no byte; no proxy runs
#   B  on, with the machine's proxy this login is a tenant of: status counts the
#      sessions that talk to it on its port and no other (a login's old port is
#      not served since T600)
#   C  a login's own enable / disable left with the per-login proxy (#4674), and
#      disable --machine with the way back to a home (#4675):
#      exit 2 naming the machine's switch (--machine), not a byte written; the
#      old `run` entry starts nothing
#   F  --all-logins: fleet-sync-logins.sh --cred-proxy status runs each other
#      login's own fleet-cred-rollout.sh as that login (its HOME /
#      FLEET_CONF_DIR), and status ends with the machine's `all:` line; its
#      --cred-proxy enable is refused
#   G  rails: status prints no environment value; status --ctl still reaches the
#      control socket's status
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SB=$(mktemp -d /tmp/crst.XXXXXX)   # short: the proxy's ctl.sock must fit AF_UNIX's 104 bytes
SB=$(cd "$SB" && pwd -P)
PXPID=''
cleanup() {
  [ -n "$PXPID" ] && kill "$PXPID" 2>/dev/null
  kill "$(cat "$SB/conf/cred-proxy/pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/conf" XDG_CONFIG_HOME="$SB/xdg"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$XDG_CONFIG_HOME"
unset FLEET_CRED_PROXY FLEET_CRED_RELAY_URL FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN CCQUOTA_FLEET FLEET_PROBE_FORCE_UNREACHABLE
export FLEET_CRED_ROLLOUT_WAIT=120 FLEET_CRED_ROLLOUT_PROCS="$SB/procs"

st_tally
waitfor() { local i=0; while [ "$i" -lt 300 ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
up() { [ -S "$FLEET_CONF_DIR/cred-proxy/ctl.sock" ] && kill -0 "$(cat "$FLEET_CONF_DIR/cred-proxy/pid" 2>/dev/null)" 2>/dev/null; }
R() { bash "$BIN/fleet-cred-rollout.sh" "$@"; }

SECRET='sk-ant-oat01-NEVER-PRINT-ME'
procs() {   # [port] — three claudes (one through THIS proxy, one through another
            # port), a codex through it, a node; no port = today's wiring, no proxy
  if [ -z "${1:-}" ]; then
    {
      printf '%s\t%s\n' /Users/x/.local/bin/claude "claude --resume CLAUDE_CODE_OAUTH_TOKEN=$SECRET HOME=/x"
      printf '%s\t%s\n' claude "claude CLAUDE_CODE_OAUTH_TOKEN=$SECRET HOME=/x"
      printf '%s\t%s\n' /opt/codex/codex "codex resume"
      printf '%s\t%s\n' node "node /x/codex"
      printf '%s\t%s\n' claude "claude HOME=/x"
    } > "$SB/procs"
    return
  fi
  {
    printf '%s\t%s\n' /Users/x/.local/bin/claude "claude --resume ANTHROPIC_BASE_URL=http://127.0.0.1:$1 CLAUDE_CODE_OAUTH_TOKEN=$SECRET HOME=/x"
    printf '%s\t%s\n' claude "claude CLAUDE_CODE_OAUTH_TOKEN=$SECRET HOME=/x"
    printf '%s\t%s\n' /opt/codex/codex "codex -c model_provider=\"fleet\" FLEET_CODEX_SESSION_CRED=fcp1.x"
    printf '%s\t%s\n' node "node /x/codex ANTHROPIC_BASE_URL=http://127.0.0.1:$1"
    printf '%s\t%s\n' claude "claude ANTHROPIC_BASE_URL=http://127.0.0.1:1 HOME=/x"
  } > "$SB/procs"
}
procs

cat > "$FLEET_CONF_DIR/fleet.conf" <<'CONF'
# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.

# ---- [common] ----
FLEET_HOST=1
export FLEET_HUB_URL_UNUSED="http://127.0.0.1:9"
_fcs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/secrets.env"; [ -f "$_fcs" ] && . "$_fcs"; unset _fcs

# ---- [client] — only the shell (FLEET_SHELL=1) reads this section ----
if [ "${FLEET_SHELL:-0}" = 1 ]; then
:
fi  # ---- [client] end ----

# ---- [node] — the shell (FLEET_SHELL=1) does not read this section ----
if [ "${FLEET_SHELL:-0}" != 1 ]; then
FLEET_MAX_SESSIONS=9
fi  # ---- [node] end ----
CONF
cp "$FLEET_CONF_DIR/fleet.conf" "$SB/orig.conf"

# ── A: off ─────────────────────────────────────────────────────────────────
out=$(R status); rc=$?
if [ "$rc" = 0 ] && [ "$out" = 'off · - · sessions 0/4' ] && cmp -s "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf" && ! up; then
  st_ok_all "A off: '$out', conf untouched, no proxy"
else st_miss "A off: rc=$rc out='$out'"; fi

# ── C: a login's own switch is gone (#4674) ────────────────────────────────
for v in enable disable; do
  out=$(R "$v" 2>&1); rc=$?
  if [ "$rc" = 2 ] && case "$out" in *"fleet cred-proxy $v --machine"*) true ;; *) false ;; esac \
     && cmp -s "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf" && ! up; then
    st_ok_all "C $v: a login has no proxy of its own to $v — exit 2, names --machine, nothing written"
  else st_miss "C $v rc=$rc: $out"; fi
done
out=$(R disable --machine 2>&1); rc=$?
case "$rc:$out" in "2:"*"disable --machine is gone (issue #4675)"*) st_ok_all "C disable --machine: gone — exit 2, no way back to a home (#4675)" ;; *) st_miss "C disable --machine rc=$rc: $out" ;; esac
out=$(R enable --all-logins 2>&1); rc=$?
[ "$rc" = 2 ] && cmp -s "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf" && st_ok_all "C enable --all-logins: exit 2 too" || st_miss "C --all-logins rc=$rc: $out"
out=$(bash "$BIN/fleet-cred-proxy.sh" run 2>&1); rc=$?
[ "$rc" = 2 ] && ! up && st_ok_all "C the per-login launcher's old entry \`run\` is gone (exit 2), starts nothing" || st_miss "C run rc=$rc: $out"

# ── B: on, through the proxy this login's sessions use ─────────────────────
printf 'export FLEET_CRED_PROXY=1\n' >> "$FLEET_CONF_DIR/fleet.conf"
# the machine's proxy with this login its one tenant
python3 -c 'import json,os,sys; c=sys.argv[1]; st=os.path.join(c,"cred-proxy")
json.dump({"state":st,"run":st,"user":"me","version":"-","port":0,"tenants":[{"login":"me","uid":os.getuid(),
"state":st,"accounts":os.path.join(c,"accounts"),"codex_auth":os.path.join(c,"auth.json"),"codex_homes":os.path.join(c,"ch"),
"node_env":os.path.join(c,"node.env"),"probe":os.path.join(c,"node-probe.json"),"settings":{}}]},
open(os.path.join(c,"machine.json"),"w"))' "$FLEET_CONF_DIR"
mkdir -p "$FLEET_CONF_DIR/cred-proxy"
python3 -I "$BIN/fleet-cred-proxy.py" serve --shared "$FLEET_CONF_DIR/machine.json" --max-seconds 300 2>"$SB/proxy.err" & PXPID=$!
waitfor up || st_miss "B the proxy did not start: $(cat "$SB/proxy.err")"
PORT=$(cat "$FLEET_CONF_DIR/cred-proxy/port" 2>/dev/null); procs "$PORT"
out=$(R status)
case "$out" in
  'on · down ·'*|'on · - ·'*) st_miss "B status: route missing — $out" ;;
  'on · '*' · sessions 2/4') st_ok_all "B status: '$out' (its port counts, no other)" ;;
  *) st_miss "B status: $out" ;;
esac
case "$out" in *"$SECRET"*|*fcp1.*) st_miss "G status printed an environment value" ;; *) st_ok_all "G status prints counts only" ;; esac
bash "$BIN/fleet-cred-proxy.sh" status --ctl >/dev/null 2>&1; [ $? != 2 ] && st_ok_all "G status --ctl still reaches the control socket's status" || st_miss "G status --ctl"
kill "$PXPID" 2>/dev/null; wait "$PXPID" 2>/dev/null; PXPID=''
cp "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf"

# ── F: --all-logins ────────────────────────────────────────────────────────
SRC="$SB/src"; mkdir -p "$SRC"
cp -R "$BIN" "$SRC/bin"
# no background auto-gc: it packs the loose objects away while the clones below
# copy them ("failed to copy file … No such file") and a login went missing
( cd "$SRC" && git init -q && git config gc.auto 0 && git config maintenance.auto false && git add -A \
  && git -c user.email=t@t -c user.name=t commit -qm src ) || st_miss "F source repo"
for u in alice bob; do
  mkdir -p "$SB/homes/$u/.claude"
  git clone -q "$SRC" "$SB/homes/$u/.claude/fleet" 2>/dev/null
done
mkdir -p "$SB/homes/alice/.config/claude-fleet"
printf '# ---- [common] ----\nFLEET_HOST=1\n' > "$SB/homes/alice/.config/claude-fleet/fleet.conf"
cp "$SB/homes/alice/.config/claude-fleet/fleet.conf" "$SB/alice.conf"
rm -f "$SB/homes/bob/.claude/fleet/bin/fleet-cred-rollout.sh"   # an install from before #2134
FLEET_SYNC_LOGINS_ME=$(id -un)
export FLEET_SYNC_LOGINS_SUDO="" FLEET_SYNC_LOGINS_ME FLEET_LIVE_DIR="$SRC"
SYNCARGS="--homes $SB/homes"
cat > "$SB/sync.sh" <<SH
#!/bin/bash
exec bash "$BIN/fleet-sync-logins.sh" --source "$SRC" $SYNCARGS "\$@"
SH
procs
out=$(FLEET_CRED_ROLLOUT_SYNC="$SB/sync.sh" R status --all-logins 2>&1); rc=$?
me=$(id -un)
if printf '%s\n' "$out" | grep -qx "$me: off · - · sessions 0/4" \
   && printf '%s\n' "$out" | grep -qx 'alice: off · - · sessions 0/4' \
   && printf '%s\n' "$out" | grep -q '^bob: no fleet-cred-rollout.sh in its install — sync it first' \
   && printf '%s\n' "$out" | grep -qx 'all: on 0/2 logins · sessions 0/8' && [ "$rc" = 6 ]; then
  st_ok_all "F status --all-logins: each login's own line, the stale install named, the all: line (rc 6)"
else st_miss "F status --all-logins rc=$rc:"; printf '%s\n' "$out"; fi
out=$(bash "$SB/sync.sh" --cred-proxy enable --logins alice 2>&1); rc=$?
[ "$rc" = 2 ] && cmp -s "$SB/alice.conf" "$SB/homes/alice/.config/claude-fleet/fleet.conf" \
  && st_ok_all "F --cred-proxy enable: refused (a login has no proxy of its own to switch), alice untouched" \
  || st_miss "F sync enable rc=$rc: $out"
unset FLEET_SYNC_LOGINS_SUDO FLEET_SYNC_LOGINS_ME FLEET_LIVE_DIR

st_done
