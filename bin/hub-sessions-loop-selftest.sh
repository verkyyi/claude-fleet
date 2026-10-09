#!/bin/bash
# hub-sessions-loop-selftest.sh — the other machines' sessions keep refreshing
# while NOBODY is looking (issue #1596, EPIC #1645 C6).
#
# The collector (a launchd job, 60s) runs `fleet-hub-sessions.sh --ensure`, which
# starts a ~70s refresh loop. When a launchd job's tick exits, launchd kills every
# process left in its process group — the loop died ~1 s after each start, and
# with no client attached (the sidebar's keeper is the other caller) remote_<sess>
# stood still for 10 hours on m4. Legs:
#   A. survives the tick — --ensure run by a process-group leader that is then
#      SIGKILLed as a group (what launchd does): the loop lives on, in a process
#      group of its own, and keeps writing the cache (hub_ok moves)
#   B. one at a time     — a second --ensure with the loop alive starts nothing
#   C. recycled pid      — a pid file naming a live process that is NOT a --loop
#      (pid reuse) does not count as alive: --ensure starts a real loop
#   D. --status          — `loop <pid> · cache <age>s`, rc 0 with a live loop and
#      a fresh cache; `loop none`, rc 1, with none; `off` with the hub off
#   E. systemd parity    — claude-fleet-collect.service says KillMode=process, and
#      fleet-doctor reads --status (the `hub-sessions` row)
#   F. two loops at once — two `--loop` started together (two shells' --ensure
#      racing past one pid file, issue #2630): ONE stays, it holds
#      global/hubsess.lock, and --status names it
#   G. no nohup          — a `nohup` that exits (macOS's, under a LaunchDaemon:
#      「can't detach from console」) is on PATH: --ensure still starts a loop
#   H. node token + 401  — against a 127.0.0.1 hub: the node token from node.env
#      goes out first, as a bearer; refused, the round records
#      global/hub_auth_fail (`hub-sessions`), and the next round that stands
#      clears it; the token never appears in curl's argv
#   I. doctor            — a cache older than FLEET_HUB_SESSIONS_FAIL_SECS is a
#      `hub-sessions` FAIL; a reader refused past FLEET_HUB_AUTH_FAIL_SECS is a
#      `hubauth` FAIL (younger: WARN)
# Drives bin/fleet-hub-sessions.sh, names bin/tmux-dash-collect.sh (its caller),
# bin/fleet-doctor.sh and bin/fleet-lib.sh (fleet_hub_auth_note).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HUBS="$BIN/fleet-hub-sessions.sh"
command -v python3 >/dev/null 2>&1 || { echo 'hub-sessions-loop selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hubloop-selftest.XXXXXX")" || exit 2
S="hubl$$"
G="$WORK/.claude-dash/global"
killloop() { local p; { read -r p < "$G/hubsess.pid"; } 2>/dev/null && kill "$p" 2>/dev/null; :; }
HUBPID=''
cleanup() { killloop; [ -z "$HUBPID" ] || kill "$HUBPID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_HUB_SESSIONS_CLIENT TMUX TMUX_PANE \
      FLEET_HUB_URL FLEET_CERT XDG_CONFIG_HOME FLEET_ACCOUNTS_DIR CODEX_HOME
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/bin" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/$S/conf"
# no tmux server here: the loop's `watched` probe and local rows see nothing
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
printf '{"machines": [], "sessions": [], "nodes": []}\n' > "$WORK/sessions.json"
export FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_LOOP_SECS=30

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
# wait_for <secs> <cmd…> — poll every 0.2s until <cmd> succeeds; rc 1 on timeout
wait_for() { local n=$(( $1 * 5 )); shift; while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n-1)); done; return 1; }
loop_alive() { local p; { read -r p < "$G/hubsess.pid"; } 2>/dev/null && kill -0 "$p" 2>/dev/null; }

# --- D (off) ------------------------------------------------------------------
out=$(bash "$HUBS" --status 2>&1); rc=$?
CHECKS=$((CHECKS+1)); [ "$out" = off ] && [ "$rc" = 0 ] || fail "D: hub off — --status must say off, rc 0 (rc=$rc)" "$out"
export CCQUOTA_FLEET=1
out=$(bash "$HUBS" --status 2>&1); rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" = 1 ] || fail "D: no loop — --status rc must be 1 (rc=$rc)" "$out"
case "$out" in 'loop none · cache none') : ;; *) fail "D: no loop, no cache — wrong line" "$out" ;; esac
CHECKS=$((CHECKS+1))

# --- A: launchd's group kill ------------------------------------------------------
# A group leader of its own runs --ensure, then the WHOLE group is SIGKILLed —
# exactly launchd's cleanup of a job without AbandonProcessGroup.
python3 - "$HUBS" <<'PY'   # dies by its own SIGKILL: its rc is not the verdict
import os, signal, subprocess, sys, time
os.setsid()                                   # we are the job: our own group
subprocess.run(["bash", sys.argv[1], "--ensure"], check=False)
time.sleep(0.5)                               # the loop is up and in its first round
signal.signal(signal.SIGTERM, signal.SIG_IGN)
os.killpg(os.getpgid(0), signal.SIGKILL)      # launchd: the tick is over
PY
wait_for 5 loop_alive || fail "A: the loop died with the tick's process group"
CHECKS=$((CHECKS+1))
read -r P < "$G/hubsess.pid"
pg=$(ps -o pgid= -p "$P" 2>/dev/null | tr -d ' ')
CHECKS=$((CHECKS+1)); [ "$pg" = "$P" ] || fail "A: the loop must lead a process group of its own (pid $P pgid $pg)"
wait_for 5 test -s "$G/hub_ok" || fail "A: the surviving loop never wrote hub_ok"
read -r t1 < "$G/hub_ok"
wait_for 6 sh -c '[ "$(cat "$1")" -gt "$2" ]' _ "$G/hub_ok" "$t1" || fail "A: hub_ok does not move — the loop is not refreshing"
CHECKS=$((CHECKS+1))

# --- D (alive) ----------------------------------------------------------------
out=$(bash "$HUBS" --status 2>&1); rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" = 0 ] || fail "D: live loop + fresh cache — --status rc must be 0 (rc=$rc)" "$out"
case "$out" in "loop $P · cache "[0-9]*s) : ;; *) fail "D: live loop — wrong line" "$out" ;; esac
CHECKS=$((CHECKS+1))

# --- B: one at a time ---------------------------------------------------------------
bash "$HUBS" --ensure
sleep 1
read -r P2 < "$G/hubsess.pid"
CHECKS=$((CHECKS+1)); [ "$P2" = "$P" ] || fail "B: a second --ensure replaced the live loop ($P → $P2)"

# --- C: a recycled pid ----------------------------------------------------------
killloop; wait_for 5 sh -c '! kill -0 "$1" 2>/dev/null' _ "$P" || fail "C: could not stop the leg-A loop"
sleep 30 & DECOY=$!                           # alive, and not a --loop
printf '%s\n' "$DECOY" > "$G/hubsess.pid"
out=$(bash "$HUBS" --status 2>&1)
case "$out" in 'loop none'*) : ;; *) kill "$DECOY" 2>/dev/null; fail "C: a recycled pid counted as the loop" "$out" ;; esac
CHECKS=$((CHECKS+1))
bash "$HUBS" --ensure
wait_for 5 sh -c 'read -r p < "$1" && [ "$p" != "$2" ] && kill -0 "$p"' _ "$G/hubsess.pid" "$DECOY" \
  || { kill "$DECOY" 2>/dev/null; fail "C: --ensure trusted a recycled pid and started no loop"; }
CHECKS=$((CHECKS+1))
kill "$DECOY" 2>/dev/null

# --- E: systemd parity + the doctor row -----------------------------------------
CHECKS=$((CHECKS+1)); grep -q '^KillMode=process$' "$BIN/../systemd/claude-fleet-collect.service" \
  || fail "E: claude-fleet-collect.service must say KillMode=process (the loop outlives the tick)"
CHECKS=$((CHECKS+1)); grep -q 'fleet-hub-sessions.sh" --status' "$BIN/fleet-doctor.sh" \
  || fail "E: fleet-doctor must read fleet-hub-sessions.sh --status"
CHECKS=$((CHECKS+1)); grep -q 'fleet-hub-sessions.sh" --ensure' "$BIN/tmux-dash-collect.sh" \
  || fail "E: the collector no longer runs --ensure every tick"

# --- F: two loops at once --------------------------------------------------------
killloop; wait_for 5 sh -c '! pgrep -f "^bash $1 --loop" >/dev/null' _ "$HUBS" || fail "F: could not stop the leg-C loop"
bash "$HUBS" --loop & bash "$HUBS" --loop &
sleep 2
n=$(pgrep -f "^bash $HUBS --loop" | wc -l | tr -d ' ')
CHECKS=$((CHECKS+1)); [ "$n" = 1 ] || fail "F: two --loop started together — $n stayed, want 1" "$(pgrep -fl "^bash $HUBS --loop")"
read -r LP < "$G/hubsess.lock"
CHECKS=$((CHECKS+1)); [ "$LP" = "$(pgrep -f "^bash $HUBS --loop")" ] || fail "F: the lock names $LP, the loop is $(pgrep -f "^bash $HUBS --loop")"
out=$(bash "$HUBS" --status 2>&1)
case "$out" in "loop $LP · "*) : ;; *) fail "F: --status does not name the lock holder $LP" "$out" ;; esac
CHECKS=$((CHECKS+1))
kill "$LP" 2>/dev/null; wait 2>/dev/null
wait_for 5 sh -c '! kill -0 "$1" 2>/dev/null' _ "$LP" || fail "F: could not stop the loop"
out=$(bash "$HUBS" --status 2>&1)
case "$out" in 'loop none'*) : ;; *) fail "F: a killed holder still reads as the loop (the lock must die with it)" "$out" ;; esac
CHECKS=$((CHECKS+1))

# --- G: a nohup that cannot detach ---------------------------------------------------
printf '#!/bin/sh\necho "nohup: can'"'"'t detach from console" >&2\nexit 127\n' > "$WORK/bin/nohup"; chmod +x "$WORK/bin/nohup"
bash "$HUBS" --ensure
wait_for 5 sh -c 'pgrep -f "^bash $1 --loop" >/dev/null' _ "$HUBS" || fail "G: with a nohup that exits, --ensure started no loop (the LaunchDaemon case)"
CHECKS=$((CHECKS+1))
CHECKS=$((CHECKS+1)); sed -n '/^ensure() {/,/^}/p' "$HUBS" | grep -q nohup && fail "G: ensure() must not go through nohup"
rm -f "$WORK/bin/nohup"
killloop; wait_for 5 sh -c '! pgrep -f "^bash $1 --loop" >/dev/null' _ "$HUBS" || fail "G: could not stop the loop"

# --- H: the node token first, and a refusal on record --------------------------------
cat > "$WORK/hub.py" <<'PY'
import http.server, os, sys
work = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self):
        auth = self.headers.get("Authorization", "")
        with open(os.path.join(work, "hub.auth"), "a") as f:
            f.write(self.path + " " + auth + "\n")
        ok = os.path.exists(os.path.join(work, "hub.open")) and auth == "Bearer node-tok-2630"
        body = b'{"machines": [], "sessions": [], "nodes": [], "per_account": []}' if ok else b'{"error":"a viewer token is required"}'
        self.send_response(200 if ok else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = answer
    do_POST = answer
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(work, "hub.port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$WORK/hub.py" "$WORK" & HUBPID=$!
wait_for 5 test -s "$WORK/hub.port" || fail "H: the 127.0.0.1 test hub did not start"
printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=node-tok-2630\n' "$(cat "$WORK/hub.port")" > "$WORK/conf/node.env"
chmod 600 "$WORK/conf/node.env"
# curl on PATH that records its argv, then runs the real one
REALCURL=$(command -v curl)
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/curl.argv"\nexec "%s" "$@"\n' "$WORK" "$REALCURL" > "$WORK/bin/curl"; chmod +x "$WORK/bin/curl"
out=$(env -u FLEET_HUB_SESSIONS_CMD CCQUOTA_HUB_URL="http://127.0.0.1:$(cat "$WORK/hub.port")" FLEET_CERT="$WORK/no-cert" HOME="$WORK" \
      bash "$HUBS" --identity 2>&1)
case "$out" in "node $WORK/conf/node.env") : ;; *) fail "H: --identity must name the node token first" "$out" ;; esac
CHECKS=$((CHECKS+1))
env -u FLEET_HUB_SESSIONS_CMD CCQUOTA_HUB_URL="http://127.0.0.1:$(cat "$WORK/hub.port")" FLEET_CERT="$WORK/no-cert" HOME="$WORK" \
  bash "$HUBS" --refresh >/dev/null 2>&1
CHECKS=$((CHECKS+1)); grep -q '^/v1/fleet/fleet_sessions Bearer node-tok-2630$' "$WORK/hub.auth" \
  || fail "H: the node token did not go out as the bearer" "$(cat "$WORK/hub.auth" 2>/dev/null)"
CHECKS=$((CHECKS+1)); grep -q $'^hub-sessions\t[0-9]*\t[0-9]*\tHTTP 401' "$G/hub_auth_fail" 2>/dev/null \
  || fail "H: a refused round must be recorded in global/hub_auth_fail" "$(cat "$G/hub_auth_fail" 2>/dev/null)"
CHECKS=$((CHECKS+1)); grep -q 'node-tok-2630' "$WORK/curl.argv" && fail "H: the node token is in curl's argv" "$(cat "$WORK/curl.argv")"
: > "$WORK/hub.open"
env -u FLEET_HUB_SESSIONS_CMD CCQUOTA_HUB_URL="http://127.0.0.1:$(cat "$WORK/hub.port")" FLEET_CERT="$WORK/no-cert" HOME="$WORK" \
  FLEET_HUB_SESSIONS_NODE_REFUSED_TTL=0 bash "$HUBS" --refresh >/dev/null 2>&1
CHECKS=$((CHECKS+1)); [ ! -s "$G/hub_auth_fail" ] || fail "H: the round that stood must clear hub-sessions from hub_auth_fail" "$(cat "$G/hub_auth_fail")"
kill "$HUBPID" 2>/dev/null; HUBPID=''
rm -f "$WORK/bin/curl" "$WORK/conf/node.env"

# --- I: the doctor's rows ----------------------------------------------------------
docrow() { env HOME="$WORK" CCQUOTA_FLEET=1 bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E "^ *(PASS|WARN|FAIL) +$1 "; }
echo $(( $(date +%s) - 700 )) > "$G/hub_ok"
out=$(docrow hub-sessions)
case "$out" in *FAIL*hub-sessions*"loop none"*) : ;; *) fail "I: a 700s cache with no loop must be a hub-sessions FAIL" "$out" ;; esac
CHECKS=$((CHECKS+1))
printf 'quota\t%s\t%s\tHTTP 401: a viewer token is required\n' "$(( $(date +%s) - 2000 ))" "$(date +%s)" > "$G/hub_auth_fail"
out=$(docrow hubauth)
case "$out" in *FAIL*hubauth*"quota refused 33m"*) : ;; *) fail "I: a reader refused 2000s must be a hubauth FAIL" "$out" ;; esac
CHECKS=$((CHECKS+1))
printf 'quota\t%s\t%s\tHTTP 401\n' "$(( $(date +%s) - 100 ))" "$(date +%s)" > "$G/hub_auth_fail"
out=$(docrow hubauth)
case "$out" in *WARN*hubauth*) : ;; *) fail "I: a reader refused 100s must be a hubauth WARN" "$out" ;; esac
CHECKS=$((CHECKS+1))
rm -f "$G/hub_auth_fail"
CHECKS=$((CHECKS+1)); [ -z "$(docrow hubauth)" ] || fail "I: nothing refused must print no hubauth row"

printf 'hub-sessions-loop selftest: PASS (%s checks)\n' "$CHECKS"
