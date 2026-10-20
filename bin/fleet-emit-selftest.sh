#!/bin/bash
# fleet-emit-selftest.sh — hermetic tests for issue #625: the fleet emits session
# lifecycle facts (session → issue → PR) so spend can be joined to outcome.
#
# What is load-bearing, and therefore what is pinned here:
#   OFF IS OFF     with no FLEET_EMIT_URL the emitter touches NOTHING — no spool
#                  directory, no file, no network. This is the promise that the
#                  fleet still works on a laptop with nothing else installed, and
#                  it is the first thing anyone will (rightly) check before
#                  enabling an agent orchestrator that phones home.
#   ALLOWLIST      the payload carries ONLY the declared fields. Every value goes
#                  through a per-field charset filter, which is simultaneously the
#                  privacy rail (nothing else can ride along) and the JSON safety
#                  rail (no quote/backslash/newline can break the object or smuggle
#                  a second key in). Both directions are tested.
#   NEVER BLOCKS   a dead endpoint is a silent no-op: exit 0, event spooled, caller
#                  free. Nothing retries in the foreground.
#   BOUNDED        the spool is capped and drops the OLDEST on overflow, so a
#                  permanently dead endpoint costs fixed disk and keeps the fresh
#                  tail rather than wedging on stale events.
#   4xx IS FINAL   one malformed event must not wedge the queue forever.
#   HEADLESS       a `claude -p` helper inherits the pane's hooks (issue #571); it
#                  is not this pane's session and must emit nothing.
#
# The emitter in isolation (a real localhost sink, no tmux), then its wiring.
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
CLI="$BIN/fleet-emit.sh"
[ -x "$CLI" ] || { printf 'selftest: %s missing/not executable\n' "$CLI" >&2; exit 2; }

CHECKS=0
eq()   { st_count; [ "$2" = "$3" ] || st_fail "$1" "expected: [$2]"$'\n'"got:      [$3]"; }
has()  { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-emit.XXXXXX")" || exit 2
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1          # install-independent: never read the real conf
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
unset TMUX TMUX_PANE
SPOOL="$WORK/spool"
export FLEET_EMIT_DIR="$SPOOL"
cleanup() { [ -n "${SINK_PID:-}" ] && kill "$SINK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

depth() { bash "$CLI" --queue-depth; }
spooled() { cat "$SPOOL"/*.json 2>/dev/null; }

# ============================================================================
# 1. OFF IS OFF — the whole point of an off-by-default emitter
# ============================================================================
out=$(bash "$CLI" session.start --repo a/b --issue 7 2>&1); rc=$?
eq "no endpoint configured exits 0" 0 "$rc"
eq "no endpoint configured prints nothing" "" "$out"
st_count; [ ! -e "$SPOOL" ] || st_fail "OFF must not even create the spool dir" "$(ls -a "$SPOOL")"

# A usage error is the ONE non-zero exit (a caller bug, not a runtime condition).
out=$(bash "$CLI" 2>&1); rc=$?
eq "no event name exits 2" 2 "$rc"
out=$(bash "$CLI" session.start --bogus x 2>&1); rc=$?
eq "an unknown flag exits 2" 2 "$rc"
out=$(bash "$CLI" -h 2>&1); rc=$?
eq "--help exits 0" 0 "$rc"
st_count; has 'fleet-emit.sh' "$out" || st_fail "--help must print the usage header" "$out"

# ============================================================================
# 2. A DEAD ENDPOINT IS A SILENT NO-OP — spooled, exit 0, nothing in the way
# ============================================================================
# Port 9 (discard) refuses instantly, so this is a real failed POST, not a wait.
export FLEET_EMIT_URL="http://127.0.0.1:9/dead"
export FLEET_EMIT_TIMEOUT=2
out=$(bash "$CLI" session.start --session fleet-x --repo o/r --issue 41 --source startup 2>&1); rc=$?
eq "a dead endpoint still exits 0" 0 "$rc"
eq "a dead endpoint prints nothing" "" "$out"
eq "the event is spooled, not lost" 1 "$(depth)"

# ============================================================================
# 3. THE ALLOWLIST — exactly the declared fields, and nothing can be smuggled in
# ============================================================================
line=$(spooled)
st_count; python3 -c 'import json,sys; json.loads(sys.argv[1])' "$line" 2>/dev/null \
  || st_fail "the spooled event must be valid JSON" "$line"
for f in event ts session repo issue source branch; do
  st_count; has "\"$f\"" "$line" || st_fail "the payload must carry $f" "$line"
done
st_count; has '"issue":41' "$line" || st_fail "issue must be a NUMBER, not a string" "$line"
st_count; has '"branch":"issue-41"' "$line" || st_fail "a bound issue names its branch by construction" "$line"

# An empty field is OMITTED rather than sent as null — a consumer reads "absent"
# the same way and the line stays small.
st_count; has '"pr"' "$line" && st_fail "an unset field must be omitted, not sent empty" "$line"

# The injection rail, both halves: structure and payload. Every one of these values
# would end the JSON string and open a new key if it survived verbatim.
rm -f "$SPOOL"/*.json
bash "$CLI" session.end --via hook \
  --repo 'o/r","leaked":"secret' \
  --session-id $'id"\n{"evil":1}' \
  --reason 'prompt_input_exit' >/dev/null 2>&1
line=$(spooled)
st_count; python3 -c 'import json,sys; json.loads(sys.argv[1])' "$line" 2>/dev/null \
  || st_fail "a hostile field value must still yield valid JSON" "$line"
# The quote is STRIPPED, not escaped, so the hostile text survives only as inert
# characters inside the field it was passed to — never as a key of its own.
st_count; has '"leaked"' "$line" && st_fail "a quote in a value must not open a second key" "$line"
st_count; has '"repo":"o/rleakedsecret"' "$line" || st_fail "the repo filter must strip the quote in place" "$line"
st_count; python3 - "$line" <<'PY' || st_fail "the object must contain ONLY allowlisted keys" "$line"
import json, sys
allowed = {"event","ts","session","session_id","repo","issue","pr","branch",
           "from_branch","via","source","reason","state","action","outcome","verdict"}
extra = set(json.loads(sys.argv[1])) - allowed
sys.exit(1 if extra else 0)
PY

# ============================================================================
# 4. HEADLESS HELPERS EMIT NOTHING (issue #571)
# ============================================================================
rm -f "$SPOOL"/*.json
CLAUDE_CODE_ENTRYPOINT=sdk-cli bash "$CLI" session.start --repo o/r --issue 41 >/dev/null 2>&1
eq "a headless \`claude -p\` must not emit a phantom session" 0 "$(depth)"

# ============================================================================
# 5. THE HOOK PAYLOAD — session_id / source / reason come off stdin
# ============================================================================
rm -f "$SPOOL"/*.json
printf '%s' '{"session_id":"abc-123","transcript_path":"/x/y.jsonl","cwd":"/w","hook_event_name":"SessionStart","source":"clear"}' \
  | bash "$CLI" session.start --stdin-json --session fleet-x --repo o/r >/dev/null 2>&1
line=$(spooled)
st_count; has '"session_id":"abc-123"' "$line" || st_fail "--stdin-json must lift the ledger's join key" "$line"
st_count; has '"source":"clear"' "$line" || st_fail "--stdin-json must lift the SessionStart source" "$line"
st_count; has 'transcript' "$line" && st_fail "the transcript path must NEVER leave the machine" "$line"
st_count; has '/w' "$line" && st_fail "the cwd must NEVER leave the machine" "$line"

rm -f "$SPOOL"/*.json
printf '%s' '{"session_id":"abc-123","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}' \
  | bash "$CLI" session.end --via hook --stdin-json --repo o/r >/dev/null 2>&1
line=$(spooled)
st_count; has '"reason":"prompt_input_exit"' "$line" || st_fail "--stdin-json must lift the SessionEnd reason" "$line"
st_count; has '"via":"hook"' "$line" || st_fail "the hook end must be distinguishable from the reap end" "$line"

# ============================================================================
# 6. THE QUEUE IS BOUNDED, AND DROPS THE OLDEST
# ============================================================================
# The spool NAME is the only order the cap and the drain have — a plain glob,
# trusted to be oldest-first. `<sec>-$$-$RANDOM` was that only ACROSS seconds:
# within one second it fell to the PID, unpadded, so on a runner whose PIDs
# crossed 99999→100000 mid-burst the 6-digit ones sorted FIRST, the cap dropped
# pr 4 and kept pr 1, and this test went red on 2 of 5 master runs (issue #815).
# The old assertion ("6 kept, 1 dropped") passed by luck whenever the six writes
# straddled a second. Three pins now, each one a distinct way the order can rot:
#
#  (a) the name is fixed-width digits — lexical order == numeric order, in every
#      locale, whatever the PID width;
#  (b) a same-second burst's names sort in EMISSION order, with a strictly
#      increasing stamp — a whole-second clock would tie, a PID-ordered name would
#      sort by luck;
#  (c) with cap+3 writes, what survives is EXACTLY the newest cap, oldest-first —
#      the set, not one member of it.
spooled_names() { local p; for p in "$SPOOL"/*.json; do [ -f "$p" ] && printf '%s\n' "${p##*/}"; done; }
spooled_prs()   { local p; for p in "$SPOOL"/*.json; do [ -f "$p" ] && sed -n 's/.*"pr":\([0-9]*\).*/\1/p' "$p"; done | tr '\n' ' '; }

# (a) fixed width: 10-digit seconds, 6-digit microseconds, 7-digit PID (Linux
#     pid_max tops out at 4194304), 5-digit RANDOM (0..32767).
rm -f "$SPOOL"/*.json
bash "$CLI" session.pr --repo o/r --pr 1 >/dev/null 2>&1
name=$(spooled_names)
st_count; printf '%s\n' "$name" | grep -Eq '^[0-9]{10}-[0-9]{6}-[0-9]{7}-[0-9]{5}\.json$' \
  || st_fail "a spool name must be fixed-width digits (sec-usec-pid-random), so lexical order is arrival order" "$name"

# (b) a burst inside one second: emission order == sorted order, stamps strictly
#     increasing. Each emit is its own process, so consecutive stamps are at
#     least a fork apart — a tie means the sub-second clock is not live.
rm -f "$SPOOL"/*.json
emitted=''
for i in 1 2 3 4 5 6 7 8; do
  bash "$CLI" session.pr --repo o/r --pr "$i" >/dev/null 2>&1
  new=''
  for n in $(spooled_names); do
    case "$emitted" in *"$n"*) ;; *) new=$n ;; esac
  done
  [ -n "$new" ] || st_fail "emit $i left no new spool file" "$(spooled_names)"
  emitted="$emitted$new"$'\n'
done
eq "a same-second burst must sort in emission order" "$emitted" "$(printf '%s' "$emitted" | sort)"$'\n'
prev=0
for n in $emitted; do
  sec=${n%%-*}; rest=${n#*-}; usec=${rest%%-*}
  st=$(( 10#${sec}${usec} ))
  st_count; [ "$st" -gt "$prev" ] || st_fail "the microsecond stamp must strictly increase across a burst" "$emitted"
  prev=$st
done

# (c) cap+3 writes ⇒ exactly the newest cap survive, oldest-first (the drain's
#     order too — it walks the same glob).
rm -f "$SPOOL"/*.json
export FLEET_EMIT_QUEUE_MAX=3
for i in 1 2 3 4 5 6; do bash "$CLI" session.pr --repo o/r --pr "$i" >/dev/null 2>&1; done
eq "the spool is capped at FLEET_EMIT_QUEUE_MAX" 3 "$(depth)"
kept=$(spooled)
st_count; has '"pr":6' "$kept" || st_fail "overflow must keep the NEWEST events" "$kept"
st_count; has '"pr":1' "$kept" && st_fail "overflow must drop the OLDEST events" "$kept"
eq "overflow must keep EXACTLY the newest cap events, oldest-first" "4 5 6 " "$(spooled_prs)"
unset FLEET_EMIT_QUEUE_MAX

# ============================================================================
# 7. END TO END against a real sink — delivery, the bearer token, and the drain
# ============================================================================
PORT=0
for p in 18931 18932 18933 18934 18935; do
  (exec 3<>/dev/tcp/127.0.0.1/$p) 2>/dev/null || { PORT=$p; break; }
done
[ "$PORT" != 0 ] || st_fail "could not find a free loopback port for the sink"

cat > "$WORK/sink.py" <<'PY'
import http.server, sys
LOG, MODE = sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        with open(LOG, 'a') as f:
            f.write(self.headers.get('Authorization', '-') + ' ' + body.strip() + '\n')
        self.send_response(400 if MODE == 'reject' else 200)
        self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY

start_sink() {  # $1=mode
  rm -f "$WORK/sink.log"
  python3 "$WORK/sink.py" "$PORT" "$WORK/sink.log" "$1" >/dev/null 2>&1 &
  SINK_PID=$!
  disown "$SINK_PID" 2>/dev/null || :   # else bash prints "Terminated" when we kill it
  local i
  for i in $(seq 1 60); do
    (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && { exec 3>&-; return 0; }
    sleep 0.1
  done
  st_fail "the test sink never came up on port $PORT"
}
drained() {  # wait for the detached drain, bounded
  local i
  for i in $(seq 1 100); do [ "$(depth)" = 0 ] && return 0; sleep 0.1; done
  return 1
}

rm -f "$SPOOL"/*.json
export FLEET_EMIT_URL="http://127.0.0.1:$PORT/e"
export FLEET_EMIT_TOKEN="tok-123"
start_sink accept
bash "$CLI" session.pr --session fleet-x --repo o/r --issue 41 --pr 99 \
  --state MERGED --action merged >/dev/null 2>&1
st_count; drained || st_fail "the detached drain must empty the spool" "$(spooled)"
got=$(cat "$WORK/sink.log" 2>/dev/null)
st_count; has 'Bearer tok-123' "$got" || st_fail "the bearer token must be sent" "$got"
st_count; has '"event":"session.pr"' "$got" || st_fail "the sink must receive the event" "$got"
st_count; has '"pr":99' "$got" || st_fail "the PR number must be delivered" "$got"
kill "$SINK_PID" 2>/dev/null; SINK_PID=

# The drain delivers OLDEST-FIRST — the same fixed-width glob the cap trusts
# (issue #815). Queue four behind a dead endpoint, then point --flush at the sink
# and read the order the sink saw. A kick from the dead-endpoint emits may still
# hold the flush lock for a moment, so the flush is retried, bounded.
rm -f "$SPOOL"/*.json
export FLEET_EMIT_URL="http://127.0.0.1:9/dead"
for i in 1 2 3 4; do bash "$CLI" session.pr --repo o/r --pr "$i" >/dev/null 2>&1; done
eq "four events wait behind the dead endpoint" 4 "$(depth)"
export FLEET_EMIT_URL="http://127.0.0.1:$PORT/e"
start_sink accept
flushed() {
  local i
  for i in $(seq 1 50); do bash "$CLI" --flush >/dev/null 2>&1; [ "$(depth)" = 0 ] && return 0; sleep 0.1; done
  return 1
}
st_count; flushed || st_fail "--flush must drain a waiting spool" "$(spooled)"
eq "the drain must deliver oldest-first" "1 2 3 4 " \
  "$(sed -n 's/.*"pr":\([0-9]*\).*/\1/p' "$WORK/sink.log" 2>/dev/null | tr '\n' ' ')"
kill "$SINK_PID" 2>/dev/null; SINK_PID=

# A 4xx is PERMANENT — the event is dropped, not retried forever. One bad event
# must never wedge every event behind it.
rm -f "$SPOOL"/*.json
start_sink reject
bash "$CLI" session.end --via reap --repo o/r --issue 41 --outcome landed >/dev/null 2>&1
st_count; drained || st_fail "a 4xx must DROP the event, not wedge the queue" "$(spooled)"
kill "$SINK_PID" 2>/dev/null; SINK_PID=

# ============================================================================
# 9. THE WIRING — the four facts are actually hung off the existing paths
# ============================================================================
st_count; grep -q 'fleet-emit.sh session.start --stdin-json' "$BIN/../hooks/settings-hooks.json" \
  || st_fail "session.start must hang off the SessionStart hook"
st_count; grep -q 'fleet-emit.sh session.end --via hook --stdin-json' "$BIN/../hooks/settings-hooks.json" \
  || st_fail "session.end (via=hook) must hang off the SessionEnd hook"
st_count; grep -q 'session\.end --via reap' "$BIN/fleet-lib.sh" \
  || st_fail "session.end (via=reap) must ride fleet_reap_record, the one reap choke point"

printf 'fleet-emit selftest: OK (%d checks)\n' "$CHECKS"
exit 0
