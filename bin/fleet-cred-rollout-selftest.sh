#!/usr/bin/env bash
# fleet-cred-rollout-selftest.sh — `fleet cred-proxy enable|disable|status`
# (bin/fleet-cred-rollout.sh, issue #2134, EPIC #2133 C4) on a sandbox login:
# sandbox HOME + FLEET_CONF_DIR, a real launcher (bin/fleet-cred-proxy.sh run)
# and its proxy on loopback, a process table from a fixture file.
#
#   A  off (the degenerate): status reads `off · - · sessions 0/4` and changes
#      no byte; the launcher runs no proxy
#   B  enable: `export FLEET_CRED_PROXY=1` under [common], the running launcher
#      is nudged (USR1 — its own re-read is 600s away) and the proxy is up in seconds;
#      status counts only the sessions that talk to THIS proxy
#   C  disable: fleet.conf byte for byte as before enable, the proxy stops
#   D  twice more, on a conf that already holds FLEET_CRED_PROXY=0 in [node] and a
#      FLEET_CRED_RELAY_URL, with --relay-url: each key put back where it was —
#      byte for byte after both round trips
#   E  switched on by hand (nothing remembered): disable writes FLEET_CRED_PROXY=0
#   F  --all-logins: fleet-sync-logins.sh --cred-proxy runs each other login's
#      own fleet-cred-rollout.sh as that login (its HOME / FLEET_CONF_DIR), and
#      status ends with the machine's `all:` line
#   G  rails: no fleet.conf → exit 3 and nothing written; --relay-url with a
#      credential in it is refused; status prints no environment value
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SB=$(mktemp -d /tmp/crst.XXXXXX)   # short: the proxy's ctl.sock must fit AF_UNIX's 104 bytes
SB=$(cd "$SB" && pwd -P)
RUNPID=''
cleanup() {
  [ -n "$RUNPID" ] && kill "$RUNPID" 2>/dev/null
  kill "$(cat "$SB/conf/cred-proxy/pid" 2>/dev/null)" 2>/dev/null
  rm -rf "$SB"
}
trap cleanup EXIT
export HOME="$SB/home" FLEET_CONF_DIR="$SB/conf" XDG_CONFIG_HOME="$SB/xdg"
mkdir -p "$HOME" "$FLEET_CONF_DIR" "$XDG_CONFIG_HOME"
unset FLEET_CRED_PROXY FLEET_CRED_RELAY_URL FLEET_HUB_URL CCQUOTA_HUB_URL CCQUOTA_TOKEN CCQUOTA_FLEET FLEET_PROBE_FORCE_UNREACHABLE
export FLEET_CRED_ROLLOUT_WAIT=120 FLEET_CRED_ROLLOUT_PROCS="$SB/procs"

FAIL=0
pass() { printf 'PASS %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAIL=1; }
waitfor() { local i=0; while [ "$i" -lt 200 ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
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

# the login's daemon: idles 600s between re-reads — only the nudge can be in time
# (a slow runner — macOS CI — takes many seconds to start a proxy at all)
FLEET_CRED_PROXY_IDLE_SECS=600 bash "$BIN/fleet-cred-proxy.sh" run --max-seconds 900 >/dev/null 2>&1 & RUNPID=$!
waitfor test -s "$FLEET_CONF_DIR/cred-proxy/launcher.pid" || fail "launcher wrote no launcher.pid"

# ── A: off ─────────────────────────────────────────────────────────────────
out=$(R status); rc=$?
if [ "$rc" = 0 ] && [ "$out" = 'off · - · sessions 0/4' ] && cmp -s "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf" && ! up; then
  pass "A off: '$out', conf untouched, no proxy"
else fail "A off: rc=$rc out='$out'"; fi

# ── B: enable ──────────────────────────────────────────────────────────────
t0=$(date +%s)
out=$(R enable 2>&1); rc=$?
t1=$(date +%s)
if grep -qx 'export FLEET_CRED_PROXY=1' "$FLEET_CONF_DIR/fleet.conf" \
   && [ "$(sed -n '/^# ---- \[common\] ----$/{n;p;}' "$FLEET_CONF_DIR/fleet.conf")" = 'export FLEET_CRED_PROXY=1' ]; then
  pass "B enable: FLEET_CRED_PROXY=1 written under [common]"
else fail "B enable: conf is"; cat "$FLEET_CONF_DIR/fleet.conf"; fi
if [ "$rc" = 0 ] && up && [ $((t1 - t0)) -lt 300 ]; then
  pass "B enable: launcher nudged, proxy up in $((t1 - t0))s (its own re-read is 600s away)"
else fail "B enable: rc=$rc up=$(up && echo y || echo n) $((t1 - t0))s — $out"; fi
case "$out" in *'doctor cred:'*) pass "B enable: prints the doctor's cred row" ;; *) fail "B enable: no cred row — $out" ;; esac
PORT=$(cat "$FLEET_CONF_DIR/cred-proxy/port"); procs "$PORT"
out=$(R status)
case "$out" in
  'on · down ·'*|'on · - ·'*) fail "B status: route missing — $out" ;;
  'on · '*' · sessions 2/4') pass "B status: '$out' (only this proxy's port counts)" ;;
  *) fail "B status: $out" ;;
esac
case "$out" in *"$SECRET"*|*fcp1.*) fail "G status printed an environment value" ;; *) pass "G status prints counts only" ;; esac

# ── C: disable ─────────────────────────────────────────────────────────────
out=$(R disable 2>&1); rc=$?
if [ "$rc" = 0 ] && cmp -s "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf"; then
  pass "C disable: fleet.conf byte for byte as before"
else fail "C disable: rc=$rc — $out"; diff "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf"; fi
if ! up; then pass "C disable: proxy stopped"; else fail "C disable: proxy still up"; fi
case "$(R status)" in 'off · - · sessions '*) pass "C status reads off" ;; *) fail "C status: $(R status)" ;; esac
ls "$FLEET_CONF_DIR/cred-proxy"/rollout.prior* >/dev/null 2>&1 && fail "C disable left a rollout.prior record" || pass "C no record left behind"

# ── D: two round trips over keys that are already there ────────────────────
sed -e 's|^FLEET_MAX_SESSIONS=9$|FLEET_MAX_SESSIONS=9\nFLEET_CRED_PROXY=0|' \
    -e 's|^FLEET_HOST=1$|FLEET_HOST=1\nFLEET_CRED_RELAY_URL=http://old.example/relay  # kept|' \
    "$SB/orig.conf" > "$FLEET_CONF_DIR/fleet.conf"
cp "$FLEET_CONF_DIR/fleet.conf" "$SB/orig2.conf"
ok=1
for round in 1 2; do
  R enable --relay-url http://127.0.0.1:9/relay >/dev/null 2>&1 || { ok=0; echo "round $round enable failed"; }
  grep -qx 'export FLEET_CRED_PROXY=1' "$FLEET_CONF_DIR/fleet.conf" \
    && grep -qx 'export FLEET_CRED_RELAY_URL="http://127.0.0.1:9/relay"' "$FLEET_CONF_DIR/fleet.conf" \
    && [ "$(grep -c 'FLEET_CRED_PROXY=' "$FLEET_CONF_DIR/fleet.conf")" = 1 ] || { ok=0; echo "round $round conf:"; cat "$FLEET_CONF_DIR/fleet.conf"; }
  up || { ok=0; echo "round $round: proxy not up"; }
  R disable >/dev/null 2>&1 || { ok=0; echo "round $round disable failed"; }
  cmp -s "$SB/orig2.conf" "$FLEET_CONF_DIR/fleet.conf" || { ok=0; diff "$SB/orig2.conf" "$FLEET_CONF_DIR/fleet.conf"; }
done
[ "$ok" = 1 ] && pass "D two enable/disable round trips, keys in place: byte for byte" || fail "D round trips"

# ── E: switched on by hand ─────────────────────────────────────────────────
cp "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf"
printf 'FLEET_CRED_PROXY=1\n' >> "$FLEET_CONF_DIR/fleet.conf"
R disable >/dev/null 2>&1
if [ "$(grep -c 'FLEET_CRED_PROXY=' "$FLEET_CONF_DIR/fleet.conf")" = 1 ] && grep -qx 'export FLEET_CRED_PROXY=0' "$FLEET_CONF_DIR/fleet.conf" \
   && [ "$(R status | cut -d' ' -f1)" = off ]; then
  pass "E nothing remembered: disable writes FLEET_CRED_PROXY=0 in place"
else fail "E"; cat "$FLEET_CONF_DIR/fleet.conf"; fi
cp "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf"
kill "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null; RUNPID=''

# ── F: --all-logins ────────────────────────────────────────────────────────
SRC="$SB/src"; mkdir -p "$SRC"
cp -R "$BIN" "$SRC/bin"
( cd "$SRC" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm src ) || fail "F source repo"
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
  pass "F status --all-logins: each login's own line, the stale install named, the all: line (rc 6)"
else fail "F status --all-logins rc=$rc:"; printf '%s\n' "$out"; fi
# enable on alice only (no launcher there: the daemon step is the seam), then back
out=$(FLEET_CRED_ROLLOUT_DAEMON=true FLEET_CRED_ROLLOUT_WAIT=0 bash "$SB/sync.sh" --cred-proxy enable --logins alice 2>&1)
if grep -qx 'export FLEET_CRED_PROXY=1' "$SB/homes/alice/.config/claude-fleet/fleet.conf" \
   && cmp -s "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf" \
   && printf '%s\n' "$out" | grep -q '^alice: cred-proxy: fleet.conf: FLEET_CRED_PROXY=1'; then
  pass "F --cred-proxy enable --logins alice: alice's own fleet.conf, as alice; this login untouched"
else fail "F enable alice:"; printf '%s\n' "$out"; cat "$SB/homes/alice/.config/claude-fleet/fleet.conf"; fi
FLEET_CRED_ROLLOUT_DAEMON=true FLEET_CRED_ROLLOUT_WAIT=0 bash "$SB/sync.sh" --cred-proxy disable --logins alice >/dev/null 2>&1
cmp -s "$SB/alice.conf" "$SB/homes/alice/.config/claude-fleet/fleet.conf" \
  && pass "F --cred-proxy disable: alice's conf byte for byte" || fail "F alice disable"
unset FLEET_SYNC_LOGINS_SUDO FLEET_SYNC_LOGINS_ME FLEET_LIVE_DIR

# ── G: rails ───────────────────────────────────────────────────────────────
mv "$FLEET_CONF_DIR/fleet.conf" "$SB/held.conf"
R enable >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ ! -e "$FLEET_CONF_DIR/fleet.conf" ] && pass "G no fleet.conf: enable exits 3, writes nothing" || fail "G no conf rc=$rc"
mv "$SB/held.conf" "$FLEET_CONF_DIR/fleet.conf"
R enable --relay-url 'https://user:pw@relay.example/x' >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && cmp -s "$SB/orig.conf" "$FLEET_CONF_DIR/fleet.conf" && pass "G a credential in --relay-url is refused (exit 2)" || fail "G relay url rc=$rc"
bash "$BIN/fleet-cred-proxy.sh" status --ctl >/dev/null 2>&1; [ $? != 2 ] && pass "G status --ctl still reaches the control socket's status" || fail "G status --ctl"

[ "$FAIL" = 0 ] && echo "fleet-cred-rollout-selftest: OK" || echo "fleet-cred-rollout-selftest: FAILED"
exit "$FAIL"
