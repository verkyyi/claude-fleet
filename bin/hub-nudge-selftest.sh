#!/bin/bash
# hub-nudge-selftest.sh — «a state change reaches the hub now» (issue #1481, EPIC
# #1479 C2): the fleet half of the nudge, and the sidebar loop's conditional fetch.
#
# Drives the REAL bin/fleet-lib.sh (fleet_hub_nudge), bin/set-claude-state.sh (the
# hook's inline copy, change-only) and bin/fleet-hub-sessions.sh (If-None-Match /
# 304 / the watched 2 s cadence), and asserts:
#
#   A. OFF (no CCQUOTA_FLEET): fleet_hub_nudge writes nothing; the hook's state
#      write touches no nudge file; the loop keeps its 10 s cadence. The
#      degenerate case, byte for byte (CLAUDE.md «Degenerate case is sacred»).
#   B. ON: fleet_hub_nudge creates $FLEET_CONF_DIR/global/hub-nudge; a second call
#      MOVES its mtime (the `: >` builtin on an already-empty file — the whole
#      contract the agent's 250 ms mtime poll rests on); a fake agent polling the
#      way the Go one does sees a nudge within 500 ms.
#   C. The hook nudges on a CHANGE of @claude_state/@claude_needs and NOT on a
#      per-tool re-stamp of the same state (a `busy` on a working window).
#   D. ETag: against a loopback hub, the first fetch stores the validator, the
#      second goes out with If-None-Match and a 304 keeps the rows while
#      re-stamping #ts (so they never read 失联 while the hub answers), and a new
#      validator with a new body replaces the rows. A failed fetch keeps rows AND
#      validator (the cache on disk is what it vouches for; the hub says 304 or
#      sends the body when it is back); a cache that failed to WRITE drops it.
#   E. Cadence: --loop refreshes every 2 s while a client is attached to a fleet
#      session here, every 10 s when nobody is.
#
# Hermetic: temp FLEET_CONF_DIR + FLEET_C, a PATH-shim tmux, the hub is a python3
# http.server on 127.0.0.1 that dies with the test. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
HUBS="$BIN/fleet-hub-sessions.sh"
HOOK="$BIN/set-claude-state.sh"
command -v python3 >/dev/null 2>&1 || { echo 'hub-nudge selftest: python3 absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hubnudge-selftest.XXXXXX")" || exit 2
SRV_PID=''
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_HUB_SESSIONS_EVERY FLEET_HUB_SESSIONS_WATCHED_EVERY \
      FLEET_HUB_SESSIONS_LOOP_SECS TMUX TMUX_PANE
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home"
S="nudge$$"
G="$WORK/.claude-dash/global"
NUDGE="$FLEET_CONF_DIR/global/hub-nudge"
mkdir -p "$G" "$FLEET_CONF_DIR/fleets/$S" "$FLEET_CONF_DIR/global" "$WORK/bin" "$HOME" "$WORK/main"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$S/conf"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }
absent() { CHECKS=$((CHECKS+1)); [ ! -e "$2" ] || fail "$1 — $2 exists"; }

# mtime in ns: GNU stat first (BSD's -c is "filesystem status"), python as the
# tie-breaker for sub-second resolution on both.
mtime_ns() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"; }

# tmux shim: display-message answers from FAKE_PREV, set-window-option logs,
# list-clients prints a client while $WORK/attached exists. Everything else fails.
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
verb="${1:-}"; args="$*"
case "$verb" in
  display-message) case "$args" in
      *@claude_state*) printf '%s\n' "${FAKE_PREV:-done/}" ;;
      *) : ;; esac ;;
  set-window-option) printf '%s\n' "$args" >> "${SETOPT_LOG:-/dev/null}" ;;
  list-clients) [ -e "$ATTACHED" ] && printf '/dev/ttys001 @1\n' ;;
  has-session) exit 0 ;;
  *) exit 1 ;;
esac
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
SHIMPATH="$WORK/bin:$PATH"
export ATTACHED="$WORK/attached" SETOPT_LOG="$WORK/setopt.log"

# hook <verb> — the hook as Claude Code runs it, stdin = a Notification payload.
hook() {
  printf '%s' '{"session_id":"s","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}' \
    | PATH="$SHIMPATH" TMUX="$WORK/fake-sock,1,0" TMUX_PANE='%1' CLAUDE_CODE_ENTRYPOINT=cli sh "$HOOK" "$@" >/dev/null 2>&1
}

# ============================================================================
# A. OFF — nothing is written anywhere
# ============================================================================
( . "$BIN/fleet-lib.sh"; fleet_hub_nudge ) || fail "A: fleet_hub_nudge (off) exited non-zero"
absent "A: off — fleet_hub_nudge writes nothing" "$NUDGE"
FAKE_PREV='done/' hook needs
has "A: the hook still stamps the state" "$(cat "$SETOPT_LOG")" "@claude_state needs"
absent "A: off — the hook touches no nudge file" "$NUDGE"
: > "$SETOPT_LOG"

# ============================================================================
# B. ON — the file, its mtime, and a fake agent's poll
# ============================================================================
export CCQUOTA_FLEET=1
( . "$BIN/fleet-lib.sh"; fleet_hub_nudge ) || fail "B: fleet_hub_nudge exited non-zero"
CHECKS=$((CHECKS+1)); [ -f "$NUDGE" ] || fail "B: fleet_hub_nudge must create $NUDGE"
m1=$(mtime_ns "$NUDGE"); sleep 0.05
( . "$BIN/fleet-lib.sh"; fleet_hub_nudge )
m2=$(mtime_ns "$NUDGE")
CHECKS=$((CHECKS+1)); [ "$m2" -gt "$m1" ] || fail "B: a second nudge must MOVE the mtime ($m1 -> $m2) — the agent polls exactly that"
eq "B: the file stays empty (a marker, never a log)" "0" "$(wc -c < "$NUDGE" | tr -d ' ')"
# The fake agent: the Go watcher's loop — stat every 250 ms, report when the
# mtime moves. Nudge 400 ms in; the signal must land within 500 ms of it.
python3 - "$NUDGE" "$BIN" > "$WORK/agent.out" 2>&1 <<'PY' &
import os, subprocess, sys, time
path, bindir = sys.argv[1], sys.argv[2]
last = os.stat(path).st_mtime_ns
time.sleep(0.4)
t0 = time.monotonic()
subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh"; fleet_hub_nudge', "x", bindir], check=True)
deadline = t0 + 3
while time.monotonic() < deadline:
    time.sleep(0.25)
    m = os.stat(path).st_mtime_ns
    if m != last:
        print("seen %d" % int((time.monotonic() - t0) * 1000))
        sys.exit(0)
print("missed")
sys.exit(1)
PY
wait $! ; CHECKS=$((CHECKS+1)); [ $? = 0 ] || fail "B: the fake agent never saw the nudge" "$(cat "$WORK/agent.out")"
seen=$(sed -n 's/^seen //p' "$WORK/agent.out")
CHECKS=$((CHECKS+1)); [ -n "$seen" ] && [ "$seen" -le 500 ] || fail "B: nudge seen after ${seen:-?} ms, want ≤ 500 (one 250 ms poll)"

# ============================================================================
# C. the hook: a CHANGE nudges, a re-stamp does not
# ============================================================================
rm -f "$NUDGE"
FAKE_PREV='done/' hook needs
CHECKS=$((CHECKS+1)); [ -f "$NUDGE" ] || fail "C: done → needs must nudge"
has "C: …and still stamps the state" "$(cat "$SETOPT_LOG")" "@claude_state needs"
rm -f "$NUDGE"; : > "$SETOPT_LOG"
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  | PATH="$SHIMPATH" TMUX="$WORK/fake-sock,1,0" TMUX_PANE='%1' FAKE_PREV='working/' sh "$HOOK" busy >/dev/null 2>&1
has "C: a busy on a working window still re-stamps working" "$(cat "$SETOPT_LOG")" "@claude_state working"
absent "C: …but the same state again is no nudge (the hub already knows)" "$NUDGE"
printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  | PATH="$SHIMPATH" TMUX="$WORK/fake-sock,1,0" TMUX_PANE='%1' FAKE_PREV='done/' sh "$HOOK" busy >/dev/null 2>&1
CHECKS=$((CHECKS+1)); [ -f "$NUDGE" ] || fail "C: done → working (a new turn) must nudge"
rm -f "$NUDGE"; : > "$SETOPT_LOG"

# ============================================================================
# D. ETag / 304 against a loopback hub
# ============================================================================
F=ffffffff-ffff-4fff-8fff-ffffffffffff
cat > "$WORK/hub.py" <<'PY'
import json, os, sys, http.server
work = sys.argv[1]
def body(state):
    return json.dumps({"machines": ["mini2"], "count": 1, "sessions": [{
        "worker_id": "ffffffff-ffff-4fff-8fff-ffffffffffff/issue-7", "machine_name": "mini2.local",
        "os_user": "someone", "fleet_id": "ffffffff-ffff-4fff-8fff-ffffffffffff", "fleet_name": "far",
        "availability": "online", "observed_at": "2026-10-04T00:00:00Z", "age_sec": 1,
        "worker": {"key": "issue-7", "issue": 7, "repo": "acme/app", "state": state, "name": "faraway"}}]}).encode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(os.path.join(work, "hub.mode")) as f:
            mode = f.read().strip()          # "<etag> <state>" or "noetag <state>"
        tag, state = mode.split(" ", 1)
        with open(os.path.join(work, "hub.log"), "a") as f:
            f.write("GET inm=%s auth=%s\n" % (self.headers.get("If-None-Match", "-"), "y" if self.headers.get("Authorization") else "n"))
        if tag != "noetag" and self.headers.get("If-None-Match") == '"%s"' % tag:
            self.send_response(304); self.send_header("ETag", '"%s"' % tag); self.end_headers(); return
        b = body(state)
        self.send_response(200); self.send_header("Content-Type", "application/json")
        if tag != "noetag": self.send_header("ETag", '"%s"' % tag)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(work, "hub.port.tmp"), "w") as f: f.write(str(srv.server_address[1]))
os.rename(os.path.join(work, "hub.port.tmp"), os.path.join(work, "hub.port"))
srv.serve_forever()
PY
printf 'A working\n' > "$WORK/hub.mode"
python3 "$WORK/hub.py" "$WORK" & SRV_PID=$!
# Up to 30 s: a cold python3 on a loaded CI runner (macOS shards) takes well over
# the 2 s the first cut allowed — the same budget the other loopback-hub tests use.
for _ in $(seq 1 300); do [ -s "$WORK/hub.port" ] && break; kill -0 "$SRV_PID" 2>/dev/null || break; sleep 0.1; done
[ -s "$WORK/hub.port" ] || fail "D: the loopback hub did not start"
hubport=$(cat "$WORK/hub.port")
export CCQUOTA_HUB_URL="http://127.0.0.1:$hubport" CCQUOTA_VIEWER_TOKEN=tok FLEET_HUB_SESSIONS_USER='*'
US=$'\x1f'
row_state() { LC_ALL=C awk -F"$US" -v w="wid:$F/issue-7" '$1 == w { print $6 }' "$G/remote_$S" 2>/dev/null; }
ts_of() { head -1 "$G/remote_$S" | cut -d"$US" -f2; }

PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err" || fail "D: first --refresh failed" "$(cat "$WORK/err")"
eq  "D: the first fetch sends no validator"     "GET inm=- auth=y" "$(sed -n 1p "$WORK/hub.log")"
eq  "D: …and writes the row"                    "working" "$(row_state)"
eq  "D: …and keeps the hub's ETag"              '"A"' "$(cat "$G/hubsess.etag" 2>/dev/null)"
t1=$(ts_of); sleep 1
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err" || fail "D: a 304 refresh must succeed" "$(cat "$WORK/err")"
eq  "D: the second fetch sends If-None-Match"   'GET inm="A" auth=y' "$(sed -n 2p "$WORK/hub.log")"
eq  "D: a 304 keeps the rows"                   "working" "$(row_state)"
CHECKS=$((CHECKS+1)); [ "$(ts_of)" -gt "$t1" ] || fail "D: a 304 must re-stamp #ts ($t1 -> $(ts_of)) — else the rows read 失联 while the hub answers"
eq  "D: …and says nothing on stderr"            "" "$(cat "$WORK/err")"
printf 'B needs\n' > "$WORK/hub.mode"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null || fail "D: refresh after a change failed"
eq  "D: a new validator comes with the new rows" "needs" "$(row_state)"
eq  "D: …and replaces the stored ETag"          '"B"' "$(cat "$G/hubsess.etag")"
# A cache the validator vouches for that is gone from disk: the body is fetched.
rm -f "$G/remote_$S"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null || fail "D: refresh with a missing cache failed"
eq  "D: a missing cache sends no validator"      "GET inm=- auth=y" "$(sed -n 4p "$WORK/hub.log")"
eq  "D: …and the row is back"                   "needs" "$(row_state)"
# A hub without ETags (older than #1481): full fetches, no validator kept.
printf 'noetag done\n' > "$WORK/hub.mode"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null || fail "D: refresh against a no-ETag hub failed"
eq  "D: an older hub's rows still land"          "done" "$(row_state)"
absent "D: …and no validator is kept for it"      "$G/hubsess.etag"
# A failed fetch keeps the rows and the validator they came with.
printf 'C working\n' > "$WORK/hub.mode"
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>/dev/null
eq  "D: a validator is back once the hub sends one" '"C"' "$(cat "$G/hubsess.etag" 2>/dev/null)"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=''
PATH="$SHIMPATH" bash "$HUBS" --refresh 2>"$WORK/err"
eq  "D: a dead hub returns 1"                    "1" "$?"
eq  "D: …keeps the last rows"                    "working" "$(row_state)"
has "D: …and says so"                            "$(cat "$WORK/err")" "hub unreachable"
eq  "D: …and keeps the validator of the rows on disk" '"C"' "$(cat "$G/hubsess.etag" 2>/dev/null)"

# ============================================================================
# E. cadence: 2 s while someone is attached, 10 s otherwise
# ============================================================================
unset CCQUOTA_HUB_URL
export FLEET_HUB_SESSIONS_CMD="printf x >> '$WORK/fetches'; printf '%s' '{\"machines\":[],\"count\":0,\"sessions\":[]}'"
export FLEET_HUB_SESSIONS_LOOP_SECS=5
rm -f "$WORK/fetches" "$G/hubsess.pid"
: > "$ATTACHED"
PATH="$SHIMPATH" bash "$HUBS" --loop 2>/dev/null
n=$(wc -c < "$WORK/fetches" | tr -d ' ')
CHECKS=$((CHECKS+1)); [ "$n" -ge 2 ] || fail "E: watched — a 5 s loop fetched $n times, want ≥ 2 (every 2 s)"
rm -f "$WORK/fetches" "$ATTACHED" "$G/hubsess.pid"
PATH="$SHIMPATH" bash "$HUBS" --loop 2>/dev/null
eq  "E: unwatched — a 5 s loop fetches once (every 10 s, as before)" "1" "$(wc -c < "$WORK/fetches" | tr -d ' ')"
rm -f "$WORK/fetches" "$G/hubsess.pid"
: > "$ATTACHED"
FLEET_HUB_SESSIONS_WATCHED_EVERY=10 PATH="$SHIMPATH" bash "$HUBS" --loop 2>/dev/null
eq  "E: FLEET_HUB_SESSIONS_WATCHED_EVERY sets the watched cadence" "1" "$(wc -c < "$WORK/fetches" | tr -d ' ')"
# OFF: the loop is a no-op — nothing fetched, no pid file.
rm -f "$WORK/fetches" "$G/hubsess.pid"
CCQUOTA_FLEET='' PATH="$SHIMPATH" bash "$HUBS" --loop 2>/dev/null
absent "E: off — the loop fetches nothing" "$WORK/fetches"
absent "E: off — and leaves no pid file"  "$G/hubsess.pid"

printf 'PASS: hub-nudge — %d checks (nudge file + mtime, hook change-only, ETag/304 with #ts re-stamp, 2 s watched / 10 s idle)\n' "$CHECKS"
exit 0
