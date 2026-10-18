#!/bin/bash
# fleet-webhook-machine-selftest.sh — the machine's ONE webhook forwarder
# (bin/fleet-webhook-machine.py, issue #4358, EPIC #4354 C4), hermetic: a sandbox
# daemon state, two fake logins (FLEET_NODE_TEST=1 + FLEET_NODE_PASSWD, both this
# uid), each with a stub fleet-webhook.sh that records what it was asked as whom.
# No gh, no network, no root; the real launchd/com.claude-fleet.webhook.plist.tmpl.
#
#   A  ONE program, every login: alice and bob both forwarded (each its own forward,
#      the same repo too), their URLs /u/<login> on the one listener
#   B  routing by login: a delivery to /u/bob runs bob's --route (event, signature,
#      body), never alice's; an unknown login and a path trick are 404, routed nowhere
#   C  a dead forward is restarted (backoff) and caught up
#   D  按变化醒: idle ticks rescan nobody; a changed conf rescans that login only
#   E  a login whose sessions went to 0 has its forwards stopped and leaves the list
#   F  host wake (the wall clock jumps past the monotonic one): a forward held in a
#      long backoff comes back within one tick, its catch-up forced
#   G  start / exit: TERM stops every forward and clears the books; a SIGKILLed
#      copy's forwards are stopped by the next start (by its book, never by name)
#   H  supervisor: with the program in the runtime the `webhook` unit leaves every
#      login and `webhook-machine` is a child; FLEET_NODE_WEBHOOK=0 / seated keep
#      the old road; fleet-webhook.sh's supervise exits when the machine serves it
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$BIN")"
command -v python3 >/dev/null 2>&1 || { echo "fleet-webhook-machine selftest: SKIP (no python3)"; exit 0; }
PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
until_ok() { local n=$(( $1 * 10 )); shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.1; n=$((n - 1)); done; return 1; }

S=$(mktemp -d "${TMPDIR:-/tmp}/fwm.XXXXXX")
MPID=''
cleanup() {
  [ -n "$MPID" ] && kill "$MPID" 2>/dev/null
  # every stub forward carries the sandbox path in its argv: stop exactly those
  pkill -f "fwm-forward $S" 2>/dev/null
  rm -rf "$S"
}
trap cleanup EXIT

UID_=$(id -u); GID_=$(id -g)
mkdir -p "$S/state/locks" "$S/log" "$S/rt" "$S/sessions"
ln -s "$ROOT/launchd" "$S/rt/launchd"
ln -s "$ROOT/conf" "$S/rt/conf"
printf '{"alice":{"uid":%s,"gid":%s,"home":"%s/home/alice"},"bob":{"uid":%s,"gid":%s,"home":"%s/home/bob"}}\n' \
  "$UID_" "$GID_" "$S" "$UID_" "$GID_" "$S" > "$S/passwd.json"
printf '{"alice":{"managed":true,"home":"%s/home/alice"},"bob":{"managed":true,"home":"%s/home/bob"}}\n' "$S" "$S" \
  > "$S/state/accounts.json"
for u in alice bob; do
  h="$S/home/$u"; mkdir -p "$h/.claude/fleet/bin" "$h/.claude/fleet/logs" "$h/.config/claude-fleet/fleets/f"
  : > "$h/.config/claude-fleet/fleets/f/conf"
  cat > "$h/.claude/fleet/bin/fleet-webhook.sh" <<'STUB'
#!/bin/bash
# a stand-in for fleet-webhook.sh: records each mode as the login it ran as
rec="$HOME/rec"
case "$1" in
  --desired) echo "desired $USER" >> "$rec"; cat "$HOME/desired" 2>/dev/null ;;
  --forward) echo "forward $USER $2 $4 ${FLEET_WH_MACHINE_PID:-}" >> "$rec"
             exec python3 -c 'import time; time.sleep(120)' fwm-forward "$FWM_SB" --repo "$2" ;;
  --catchup) echo "catchup $USER $2 ${3:-}" >> "$rec" ;;
  --route)   body=$(cat); echo "route $USER $3 ${FLEET_DELIVERY_SIG:-} $body" >> "$rec" ;;
esac
STUB
  chmod +x "$h/.claude/fleet/bin/fleet-webhook.sh"
  printf '1 %s\n' "$(date +%s)" > "$S/sessions/$u"
done
echo "o/a" > "$S/home/alice/desired"
printf 'o/a\no/b\n' > "$S/home/bob/desired"

export FLEET_NODE_TEST=1 FLEET_NODE_PASSWD="$S/passwd.json" FLEET_NODE_STATE="$S/state" FLEET_NODE_LOG="$S/log" \
  FLEET_NODE_RUNTIME="$S/rt" FLEET_MACHINE_SESSIONS_DIR="$S/sessions" FLEET_NODE_WEBHOOK_PORT=0 \
  FLEET_NODE_WEBHOOK_TICK=1 FLEET_NODE_WEBHOOK_RESCAN=1000 FLEET_WH_BACKOFF_BASE=1 FLEET_NODE_SESSION_HOLD=0 \
  FLEET_WH_TEST_SKEW_FILE="$S/skew" FWM_SB="$S"
LF="$S/state/webhook-machine.logins" JF="$S/state/webhook-machine.json"
start() { python3 -I "$BIN/fleet-webhook-machine.py" run 2>>"$S/machine.err" & MPID=$!; }
fwd_pid() { python3 -c 'import json,sys
st=json.load(open(sys.argv[1]))
print(" ".join(str(g["pid"]) for g in st["groups"] if g["login"]==sys.argv[2] and g["repo"]==sys.argv[3]))' "$JF" "$1" "$2" 2>/dev/null; }
port() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$JF" 2>/dev/null; }
post() { # path event body → http code
  python3 - "$(port)" "$@" <<'PY'
import sys, urllib.request, urllib.error
port, path, event, body = sys.argv[1:5]
r = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path), data=body.encode(), method="POST",
                           headers={"X-GitHub-Event": event, "X-Hub-Signature-256": "sha256=feed"})
try:
    print(urllib.request.urlopen(r, timeout=10).status)
except urllib.error.HTTPError as e:
    print(e.code)
PY
}
has_fwd() { [ -n "$(fwd_pid "$1" "$2")" ]; }
served() { [ -f "$LF" ] && [ "$(tail -n +2 "$LF" | tr '\n' ' ')" = "$1" ]; }
both_up() { [ -n "$(fwd_pid alice o/a)" ] && [ -n "$(fwd_pid bob o/a)" ] && [ -n "$(fwd_pid bob o/b)" ]; }

# ---- A: one program for every login --------------------------------------------
start
until_ok 15 both_up || { fail "A the forwards never came up: $(tail -20 "$S/machine.err") · state: $(cat "$JF" 2>/dev/null) · alice: $(cat "$S/home/alice/rec" 2>/dev/null)"; exit 1; }
served "alice bob " && ok "A one program serves alice and bob (webhook-machine.logins)" || fail "A served list: $(cat "$LF")"
[ "$(head -1 "$LF" | cut -d' ' -f1)" = "$MPID" ] && ok "A the list names the program's pid" || fail "A pid line: $(head -1 "$LF")"
P=$(port)
grep -q "^forward alice o/a http://127.0.0.1:$P/u/alice $MPID$" "$S/home/alice/rec" \
  && grep -q "^forward bob o/b http://127.0.0.1:$P/u/bob $MPID$" "$S/home/bob/rec" \
  && ok "A each login's forward runs as it, into /u/<login> on the one listener" \
  || fail "A forward lines: $(grep forward "$S"/home/*/rec | tr '\n' '|')"
# the program, not this script: `$(…)` is a child of $$ whose argv names this file
n=$(pgrep -P $$ -f 'fleet-webhook-machine[.]py run' | grep -c .)
[ "$n" = 1 ] && ok "A one fleet-webhook process (the program; every forward is its child, no second copy)" \
  || fail "A process count $n"

# ---- B: routing by login --------------------------------------------------------
c=$(post /u/bob pull_request '{"repository":{"full_name":"o/b"}}')
until_ok 5 grep -q '^route bob pull_request sha256=feed {"repository":{"full_name":"o/b"}}$' "$S/home/bob/rec" \
  && [ "$c" = 200 ] && ! grep -q '^route' "$S/home/alice/rec" \
  && ok "B /u/bob runs bob's --route (event, signature, body), never alice's" \
  || fail "B route: code $c · bob $(grep route "$S/home/bob/rec") · alice $(grep route "$S/home/alice/rec")"
c1=$(post /u/mallory issues '{}'); c2=$(post /u/alice/../bob issues '{}'); c3=$(post /x issues '{}')
sleep 0.3
[ "$c1" = 404 ] && [ "$c2" = 404 ] && [ "$c3" = 404 ] && [ "$(cat "$S"/home/*/rec | grep -c '^route')" = 1 ] \
  && ok "B an unknown login, a path trick and a bare path: 404, routed nowhere" \
  || fail "B unknown: $c1 $c2 $c3 · routes $(cat "$S"/home/*/rec | grep -c '^route')"

# ---- C: a dead forward comes back, caught up ------------------------------------
old=$(fwd_pid alice o/a); kill "$old"
back() { p=$(fwd_pid alice o/a); [ -n "$p" ] && [ "$p" != "$old" ]; }
until_ok 10 back && [ "$(grep -c '^catchup alice o/a' "$S/home/alice/rec")" -ge 2 ] \
  && ok "C a killed forward is restarted after its backoff and caught up" \
  || fail "C restart: $(fwd_pid alice o/a) (was $old) · $(grep -c catchup "$S/home/alice/rec") catch-ups"

# ---- D: 按变化醒 ---------------------------------------------------------------
da=$(grep -c '^desired' "$S/home/alice/rec"); db=$(grep -c '^desired' "$S/home/bob/rec")
sleep 3.5   # three idle ticks
[ "$(grep -c '^desired' "$S/home/alice/rec")" = "$da" ] && [ "$(grep -c '^desired' "$S/home/bob/rec")" = "$db" ] \
  && ok "D idle ticks rescan nobody (no fork while nothing changed)" \
  || fail "D idle rescans: alice ${da}→$(grep -c '^desired' "$S/home/alice/rec") bob ${db}→$(grep -c '^desired' "$S/home/bob/rec")"
echo "o/c" >> "$S/home/alice/desired"; sleep 1.1; echo "FLEET_WEBHOOK=1" > "$S/home/alice/.config/claude-fleet/fleets/f/conf"
until_ok 5 has_fwd alice o/c \
  && [ "$(grep -c '^desired' "$S/home/bob/rec")" = "$db" ] \
  && ok "D a changed conf rescans that login only, and its new repo is forwarded" \
  || fail "D change: alice o/c $(fwd_pid alice o/c) · bob rescans ${db}→$(grep -c '^desired' "$S/home/bob/rec")"

# ---- E: a login with no session ------------------------------------------------
bpids="$(fwd_pid bob o/a) $(fwd_pid bob o/b)"
printf '0 %s\n' "$(date +%s)" > "$S/sessions/bob"
gone() { for p in $bpids; do kill -0 "$p" 2>/dev/null && return 1; done; served "alice "; }
until_ok 8 gone && ok "E bob at 0 sessions: his forwards stopped, he leaves the list" \
  || fail "E bob: $(cat "$LF" | tr '\n' ' ') · pids $bpids"
printf '1 %s\n' "$(date +%s)" > "$S/sessions/bob"
until_ok 8 both_up && ok "E a session again: bob is forwarded again" || fail "E bob back: $(cat "$LF" | tr '\n' ' ')"

# ---- G (part 1): TERM stops everything, clears the books ------------------------
all=$(python3 -c 'import json,sys; print(" ".join(str(g["pid"]) for g in json.load(open(sys.argv[1]))["groups"]))' "$JF")
kill "$MPID"; wait "$MPID" 2>/dev/null; MPID=''
alive=''; for p in $all; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
[ -z "$alive" ] && [ ! -e "$LF" ] && [ ! -e "$JF" ] \
  && ok "G TERM: every forward stopped, the books cleared" || fail "G TERM left:$alive · $(ls "$S/state")"

# ---- F: host wake ---------------------------------------------------------------
FLEET_WH_BACKOFF_BASE=1000 start
until_ok 15 both_up || fail "F restart: no forwards"
old=$(fwd_pid bob o/b); kill "$old"
until_ok 5 grep -q "forward o/b died .*restart in 1000s" "$S/machine.err" || fail "F no long backoff logged"
sleep 1.5
[ -z "$(fwd_pid bob o/b)" ] && ok "F a dead forward held in a 1000 s backoff" || fail "F respawned early"
echo 300 > "$S/skew"
until_ok 5 has_fwd bob o/b \
  && grep -q "host wake" "$S/machine.err" && grep -q '^catchup bob o/b --force$' "$S/home/bob/rec" \
  && ok "F a host wake: the forward is back within a tick, its catch-up forced" \
  || fail "F wake: pid $(fwd_pid bob o/b) · $(grep -c 'host wake' "$S/machine.err") wake lines · $(grep 'catchup bob o/b' "$S/home/bob/rec" | tail -1)"

# ---- G (part 2): a SIGKILLed copy's forwards ------------------------------------
left=$(python3 -c 'import json,sys; print(" ".join(str(g["pid"]) for g in json.load(open(sys.argv[1]))["groups"]))' "$JF")
kill -9 "$MPID"; wait "$MPID" 2>/dev/null; MPID=''
sleep 0.3
still=''; for p in $left; do kill -0 "$p" 2>/dev/null && still="$still $p"; done
[ -n "$still" ] || fail "G the SIGKILL took the forwards with it — nothing to test"
start
stopped() { for p in $left; do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }
until_ok 10 stopped && until_ok 10 both_up && grep -q "left by an earlier run — stopped" "$S/machine.err" \
  && ok "G the next start stops a killed copy's forwards (its book: pid · uid · group · repo) and starts its own" \
  || fail "G leftovers:$still"
python3 -I "$BIN/fleet-webhook-machine.py" run 2>"$S/second.err"; rc=$?
[ "$rc" = 1 ] && grep -q "another copy holds the lock" "$S/second.err" \
  && ok "G a second copy refuses (the lock)" || fail "G second copy rc $rc: $(cat "$S/second.err")"

# ---- H: fleet-webhook.sh supervise exits when the machine serves the login -------
out=$(HOME="$S/home/alice" USER=alice FLEET_CONF_DIR="$S/home/alice/.config/claude-fleet" \
      FLEET_WEBHOOK_STATE_DIR="$S/wh-alice" bash "$BIN/fleet-webhook.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "the machine's one forwarder serves this login" \
  && ok "H fleet-webhook.sh's supervise exits 0 for a login the machine serves (compat, one version)" \
  || fail "H supervise: rc $rc · $out"
kill "$MPID"; wait "$MPID" 2>/dev/null; MPID=''

# ---- H: the supervisor's table --------------------------------------------------
mkdir -p "$S/rt/bin"; ln -s "$BIN/fleet-webhook-machine.py" "$S/rt/bin/fleet-webhook-machine.py"
tbl() { python3 - "$BIN" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("s", os.path.join(sys.argv[1], "fleet-node-supervisor.py"))
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
d = s.Supervisor(s.Paths(), {"children": [], "tasks": []})
if os.environ.get("SEAT") == "1":
    d.seated = True
names = [c["name"] for c in d.all_children()] if os.environ.get("SEAT") != "1" else \
        [e["name"] for e in d.account_entries() if e.get("keepalive")]
print(" ".join(sorted(n for n in names if "webhook" in n)))
print(" ".join(sorted(e["name"] for e in d.account_entries(retired=True))))
PY
}
r=$(tbl 2>&1)
[ "$r" = "$(printf 'webhook-machine\nalice/webhook bob/webhook')" ] \
  && ok "H the runtime has the program: webhook-machine is a child, no login runs its webhook unit (the sweep stops old copies)" \
  || fail "H table: $r"
r=$(FLEET_NODE_WEBHOOK=0 tbl 2>&1)
[ "$(printf '%s' "$r" | head -1)" = "alice/webhook bob/webhook" ] \
  && ok "H FLEET_NODE_WEBHOOK=0: each login's webhook unit, no machine child (the old road)" || fail "H off: $r"
r=$(SEAT=1 tbl 2>&1)
[ "$(printf '%s' "$r" | head -1)" = "alice/webhook bob/webhook" ] \
  && ok "H seated: each login keeps its unit (the seat cannot run as a login)" || fail "H seated: $r"

printf 'fleet-webhook-machine selftest: %d ok, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
