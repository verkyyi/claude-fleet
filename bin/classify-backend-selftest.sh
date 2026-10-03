#!/bin/bash
# classify-backend-selftest.sh — the three CLASSIFY_BACKEND legs of the screen
# classifier (issue #1229): haiku (default, byte-for-byte today), jev (Jev decides
# when confident, haiku otherwise), shadow (haiku decides, Jev is logged).
#
# Jev is a FAKE HTTP server on 127.0.0.1 (never `*`, issue #1154), an ephemeral
# port, answers scripted per leg through $WORK/jev-out + $WORK/jev-status +
# $WORK/jev-sleep, and records every request (body + Authorization header) so the
# wire shape is asserted, not assumed. `claude` is the same fake the other classify
# selftests use — it records each call and answers from $WORK/claude-out. No network,
# no real key, no real credentials.
#
# Asserted:
#   • DEFAULT       no CLASSIFY_BACKEND ⇒ haiku decides, the Jev endpoint is never hit,
#                   no shadow log; an unknown value logs one line and behaves as haiku
#   • HOST CONF     the test runs from a conf-free re-root, so a host fleet.conf's
#                   CLASSIFY_BACKEND cannot decide DEFAULT; a planted one would (#1251)
#   • JEV-DECIDES   conf ≥ CLASSIFY_JEV_MIN_CONF ⇒ Jev's answer sets the state,
#                   claude is NOT called, the log line carries via=jev, the hash is stamped
#   • JEV-WIRE      Bearer <key> reaches the server; body.state == the capture;
#                   the five rubric words are the choice criteria; model == jev-latest
#   • JEV-LOWCONF   conf below the floor ⇒ haiku is asked and haiku's answer wins
#   • JEV-NOKEY     no TYPESAFE_API_KEY and no key file ⇒ endpoint untouched, haiku decides
#   • JEV-DOWN      connection refused ⇒ haiku decides, one `jev unavailable` line
#   • JEV-TIMEOUT   a server slower than CLASSIFY_JEV_TIMEOUT ⇒ haiku, bounded wait
#   • JEV-HTTP      an http 401 ⇒ haiku
#   • JEV-WORKING   WORKING is not a choice (#1252): a WORKING answer is outside the
#                   criteria ⇒ haiku decides; a quiet window is never promoted (#846)
#   • RUBRIC        the haiku prompt carries no WORKING line (#1252)
#   • NO-PERSIST    the haiku call carries --no-session-persistence (#1296)
#   • PREP          the Stop-hooks spinner + its Tip line never reach either backend;
#                   `✻ Worked for … · done` does (#1252)
#   • SHADOW        haiku's verdict sets the state; one ndjson row with both verdicts,
#                   conf, hash; capture text only on a disagreement; a Jev outage
#                   still yields a row (jev null + jev_err); the report script reads it
#
# tmux or python3 absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# Re-root onto a CONF-FREE shadow of this install (issue #1251). The classifier
# reads its backend from `$BIN/../fleet.conf` (fleet-lib.sh), and a conf line
# outranks the environment — so run straight from the live install, where the
# operator set CLASSIFY_BACKEND=jev, this test measured the HOST, not the code.
# It also keeps `$BIN/../logs` (classify.log, .classify-cache) off the live
# fleet's state. The gate already does this (run-selftests.sh); this covers a
# direct run, and costs one ~100ms mirror when nested.
if [ "${_CLASSIFY_SELFTEST_ROOT:-}" != "$BIN" ]; then
  _root="$(sh "$BIN/selftest-shadow-root.sh" "$BIN/..")" || exit 2
  # Spell the marker the way the child computes $BIN (logical pwd) — a `//` from
  # macOS's trailing-slash $TMPDIR here once never matched, and recursed (#1305).
  _CLASSIFY_SELFTEST_ROOT="$(cd "$_root/bin" && pwd)" bash "$_root/bin/${0##*/}" "$@"; _rc=$?
  rm -rf "$_root"; exit "$_rc"
fi
CLS="$BIN/classify-sessions.sh"
REP="$BIN/classify-shadow-report.py"
for f in "$CLS" "$REP" "$BIN/fleet-lib.sh"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/classify-backend-selftest.XXXXXX")" || exit 2

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# --- tmux on a private socket via a PATH shim (the classifier calls bare `tmux`)
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/req"
cat > "$WORK/bin/tmux" <<EOS
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOS
chmod +x "$WORK/bin/tmux"

# --- FAKE claude: one line per call in $WORK/claude-calls, answers $WORK/claude-out
cat > "$WORK/bin/claude" <<EOS
#!/bin/sh
echo call >> "$WORK/claude-calls"
printf '%s\n' "\$*" > "$WORK/claude-argv"
cat > "$WORK/claude-in"
cat "$WORK/claude-out" 2>/dev/null
exit "\$(cat "$WORK/claude-rc" 2>/dev/null || echo 0)"
EOS
chmod +x "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

# --- FAKE Jev: loopback only, ephemeral port written to $WORK/jev-port. Exits on
# its own when this test's shell is gone (ppid check) or after 300s, so a SIGKILLed
# gate cannot leave it listening (issue #1154).
cat > "$WORK/jev-server.py" <<'PY'
import http.server, json, os, sys, time
work = sys.argv[1]; reqd = os.path.join(work, "req")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        n = len([f for f in os.listdir(reqd) if f.endswith(".json")]) + 1   # numbered per leg: the test empties req/
        with open(os.path.join(reqd, "%03d.json" % n), "wb") as f: f.write(body)
        with open(os.path.join(reqd, "%03d.auth" % n), "w") as f: f.write(self.headers.get("Authorization", ""))
        try: time.sleep(float(open(os.path.join(work, "jev-sleep")).read().strip()))
        except Exception: pass
        try: st = int(open(os.path.join(work, "jev-status")).read().strip())
        except Exception: st = 200
        try: data = open(os.path.join(work, "jev-out"), "rb").read()
        except Exception: data = b"{}"
        self.send_response(st); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(work, "jev-port"), "w") as f: f.write(str(srv.server_address[1]))
srv.timeout = 0.5; ppid = os.getppid(); t0 = time.time()
while os.getppid() == ppid and time.time() - t0 < 300:
    srv.handle_request()
PY
python3 "$WORK/jev-server.py" "$WORK" &
JEV_PID=$!
i=0; while [ "$i" -lt 50 ] && [ ! -s "$WORK/jev-port" ]; do i=$((i+1)); sleep 0.1; done
[ -s "$WORK/jev-port" ] || fail "fake Jev server never bound"
JEV_URL="http://127.0.0.1:$(cat "$WORK/jev-port")/v1/systemone"

cleanup() { kill "$JEV_PID" 2>/dev/null; tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export TMPDIR="$WORK"
export FLEET_CONF_DIR="$WORK/conf"
export CLASSIFY_SETTLE=0
export CLASSIFY_JEV_URL="$JEV_URL"
export CLASSIFY_JEV_TIMEOUT=1
export CLASSIFY_JEV_KEY_FILE="$WORK/key"       # never the operator's ~/.config/typesafe
export CLASSIFY_SHADOW_LOG="$WORK/shadow.ndjson"
unset CLASSIFY_SOCK CLASSIFY_BACKEND TYPESAFE_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLASSIFY_JEV_MIN_CONF
printf 'test-key-123\n' > "$WORK/key"

# --- a fleet-shaped pane -------------------------------------------------------
tmux -f /dev/null new-session -d -s fleet-t -x 140 -y 40 || fail "could not start isolated tmux server"
ww="$(tmux display-message -p '#{window_id}')"
tmux rename-window -t "$ww" issue-1229
tmux set-window-option -t "$ww" @issue 1229
tmux respawn-pane -k -t "$ww" "printf 'recap of the turn\nwaiting 30 seconds before the next /loop iteration\n'; sleep 300" 2>/dev/null \
  || fail "could not seed the worker pane"
i=0
while [ "$i" -lt 40 ]; do
  [ -n "$(tmux capture-pane -p -t "$ww" 2>/dev/null | tr -d '[:space:]')" ] && break
  i=$((i+1)); sleep 0.1
done
[ -n "$(tmux capture-pane -p -t "$ww" 2>/dev/null | tr -d '[:space:]')" ] || fail "isolated pane never rendered"
CAP="$(tmux capture-pane -p -t "$ww" | sed '/^[[:space:]]*$/d' | tail -35)"
HASH="$(printf '%s' "$CAP" | cksum | awk '{print $1}')"

wopt()  { tmux show-options -w -t "$1" -v "$2" 2>/dev/null; }
CCACHE="$BIN/../logs/.classify-cache"; LOGF="$BIN/../logs/classify.log"; mkdir -p "$CCACHE"
ckey="$(printf '%s' "$ww" | tr '/:@' '___')"
nreq()  { n=0; for f in "$WORK"/req/*.json; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }
ncall() { [ -f "$WORK/claude-calls" ] && wc -l < "$WORK/claude-calls" | tr -d ' ' || echo 0; }
jev_answer() {   # <choice> <conf> → the fake server's next reply
  printf '{"answers":{"status":{"choice":"%s","confidence":%s,"probabilities":{"%s":%s}}},"usage":{"input_tokens":1234}}\n' "$1" "$2" "$1" "$2" > "$WORK/jev-out"
}
# fresh <state> — reset the pane state, the change-gate hash, call counters and the log
fresh() {
  tmux set-window-option -t "$ww" @claude_state "$1"; tmux set-window-option -t "$ww" @claude_needs ""
  rm -f "$CCACHE/$ckey.hash" "$WORK/claude-calls" "$WORK/jev-sleep" "$WORK/jev-status"; rm -f "$WORK"/req/*; : > "$LOGF"
}
run() { bash "$CLS" --window "$ww" || fail "classifier exited non-zero ($*)"; }

# ================================================================ DEFAULT (haiku)
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; printf '0\n' > "$WORK/claude-rc"; jev_answer LOOPING 0.99
run default
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "default: state moved to [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 1 ] || fail "default: claude called $(ncall) times, expected 1"
[ "$(nreq)" = 0 ] || fail "default: the Jev endpoint was hit $(nreq) times with no backend set"
[ ! -f "$WORK/shadow.ndjson" ] || fail "default: a shadow log was written"
case " $(cat "$WORK/claude-argv" 2>/dev/null) " in *" --no-session-persistence "*) : ;;
  *) fail "default: the helper claude -p would persist a transcript into the worktree (#1296)" "$(cat "$WORK/claude-argv" 2>/dev/null)" ;; esac
ok "default backend: haiku decides, Jev endpoint never touched, no shadow log"
ok "the haiku helper runs with --no-session-persistence — no transcript in the worktree (#1296)"

# ================================================================ HOST CONF (#1251)
# The DEFAULT leg ran from a root with no fleet.conf — so a host's
# CLASSIFY_BACKEND cannot have decided it. Then prove that is load-bearing: the
# same leg with a conf line planted beside this bin/ DOES flip, so the leak is
# real and the re-root above is what closes it (not a stale assertion).
[ ! -e "$BIN/../fleet.conf" ] || fail "host conf: the selftest root carries a fleet.conf — the DEFAULT leg would read the host's backend"
printf 'CLASSIFY_BACKEND=jev\n' > "$BIN/../fleet.conf"
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; printf '0\n' > "$WORK/claude-rc"; jev_answer LOOPING 0.99
# Unset the gate's own FLEET_SKIP_GLOBAL_CONF for this one run: a direct run has none.
( unset FLEET_SKIP_GLOBAL_CONF _FLEET_GLOBAL_CONF_SOURCED; run hostconf ) || exit 1
rm -f "$BIN/../fleet.conf"
[ "$(wopt "$ww" @claude_state)" = "looping" ] \
  || fail "host conf: a planted CLASSIFY_BACKEND=jev no longer reaches the classifier — the root-isolation check above proves nothing"
ok "host conf: no fleet.conf in the selftest root, and a planted one would flip the DEFAULT leg"

fresh "done"; printf 'LOOPING\n' > "$WORK/claude-out"
CLASSIFY_BACKEND=bogus run bogus
[ "$(wopt "$ww" @claude_state)" = looping ] || fail "bogus backend: haiku's LOOPING did not land — [$(wopt "$ww" @claude_state)]"
[ "$(nreq)" = 0 ] || fail "bogus backend hit the Jev endpoint"
grep -q 'CLASSIFY_BACKEND=bogus unknown' "$LOGF" || fail "bogus backend: no log line" "$(cat "$LOGF")"
ok "unknown CLASSIFY_BACKEND: logged once, behaves as haiku"

# ================================================================ JEV
export CLASSIFY_BACKEND=jev
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; jev_answer LOOPING 0.93
run jev-decides
[ "$(wopt "$ww" @claude_state)" = looping ] || fail "jev: confident LOOPING did not set the state — [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 0 ] || fail "jev: claude was called $(ncall) times although Jev was confident"
[ "$(nreq)" = 1 ] || fail "jev: expected exactly one request, saw $(nreq)"
[ -f "$CCACHE/$ckey.hash" ] || fail "jev: change-gate hash not stamped after a Jev verdict"
grep -q 'done     -> looping  via=jev conf=0.930' "$LOGF" || fail "jev: verdict line lacks via=jev" "$(cat "$LOGF")"
ok "jev: a confident verdict sets the state without a claude call; hash stamped; log says via=jev"

# JEV-WIRE — the request that just went out
[ "$(cat "$WORK/req/001.auth")" = "Bearer test-key-123" ] || fail "jev: Authorization was [$(cat "$WORK/req/001.auth")]"
python3 - "$WORK/req/001.json" "$CAP" <<'PY' || fail "jev: request body is not the expected shape"
import json, sys
b = json.load(open(sys.argv[1], encoding="utf-8")); cap = sys.argv[2]
assert b["model"] == "jev-latest", b["model"]
assert b["state"] == cap, "state != capture"
q = b["questions"]["status"]; assert q["type"] == "choice"
assert sorted(q["criteria"]) == ["ERROR", "LOOPING", "STOPPED", "WAITING"], sorted(q["criteria"])   # no WORKING (#1252)
assert "ALREADY ENDED" in q["instructions"], "instructions do not say the turn has ended"
assert "scheduled wakeup" in q["criteria"]["LOOPING"], "criteria text is not the rubric's"
PY
ok "jev wire: Bearer key from the key file, state == capture, four rubric criteria (no WORKING), model jev-latest"

# TYPESAFE_API_KEY outranks the file
fresh "done"; jev_answer LOOPING 0.93
TYPESAFE_API_KEY=env-key-456 run jev-envkey
[ "$(cat "$WORK/req/001.auth")" = "Bearer env-key-456" ] || fail "jev: TYPESAFE_API_KEY not used — [$(cat "$WORK/req/001.auth")]"
ok "jev: TYPESAFE_API_KEY outranks the key file"

# JEV-LOWCONF
fresh "done"; printf 'WAITING\n' > "$WORK/claude-out"; jev_answer LOOPING 0.41
run jev-lowconf
[ "$(wopt "$ww" @claude_state)" = needs ] || fail "jev low-conf: haiku's WAITING did not win — [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 1 ] || fail "jev low-conf: claude called $(ncall) times"
grep -q 'jev LOOPING conf=0.410 < 0.7 — falling back to haiku' "$LOGF" || fail "jev low-conf: no fallback line" "$(cat "$LOGF")"
grep -q 'via=jev' "$LOGF" && fail "jev low-conf: verdict line claims via=jev" "$(cat "$LOGF")"
ok "jev: confidence under the floor falls back to haiku (one log line, haiku's answer lands)"

# the floor is a knob
fresh "done"; printf 'WAITING\n' > "$WORK/claude-out"; jev_answer LOOPING 0.41
CLASSIFY_JEV_MIN_CONF=0.4 run jev-floor
[ "$(wopt "$ww" @claude_state)" = looping ] || fail "CLASSIFY_JEV_MIN_CONF=0.4 did not let a 0.41 verdict through — [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 0 ] || fail "jev floor: claude called despite the lowered floor"
ok "jev: CLASSIFY_JEV_MIN_CONF is honoured"

# JEV-NOKEY — the endpoint must not even be contacted
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; jev_answer LOOPING 0.99
CLASSIFY_JEV_KEY_FILE="$WORK/no-such-key" run jev-nokey
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "jev no-key: state moved to [$(wopt "$ww" @claude_state)]"
[ "$(nreq)" = 0 ] || fail "jev no-key: endpoint hit $(nreq) times without a key"
[ "$(ncall)" = 1 ] || fail "jev no-key: claude called $(ncall) times"
grep -q 'jev unavailable (no key) — falling back to haiku' "$LOGF" || fail "jev no-key: no log line" "$(cat "$LOGF")"
ok "jev: no key ⇒ endpoint untouched, haiku decides, one log line (today's behaviour)"

# JEV-DOWN — connection refused
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"
CLASSIFY_JEV_URL='http://127.0.0.1:1/v1/systemone' run jev-down
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "jev down: state moved to [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 1 ] || fail "jev down: claude called $(ncall) times"
grep -q 'jev unavailable (net ' "$LOGF" || fail "jev down: no unavailable line" "$(cat "$LOGF")"
ok "jev: connection refused ⇒ haiku decides, log names the failure"

# JEV-TIMEOUT — bounded by CLASSIFY_JEV_TIMEOUT, then haiku
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; jev_answer LOOPING 0.99; printf '4\n' > "$WORK/jev-sleep"
t0=$(date +%s); run jev-timeout; el=$(( $(date +%s) - t0 ))
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "jev timeout: state moved to [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 1 ] || fail "jev timeout: claude called $(ncall) times"
[ "$el" -lt 4 ] || fail "jev timeout: took ${el}s — the 1s timeout did not bound the wait"
grep -q 'jev unavailable (timeout)' "$LOGF" || fail "jev timeout: no timeout line" "$(cat "$LOGF")"
ok "jev: a slow endpoint is cut at CLASSIFY_JEV_TIMEOUT (${el}s) and haiku decides"
rm -f "$WORK/jev-sleep"; sleep 4   # let the fake server finish its sleep before the next request

# JEV-HTTP — 401
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; printf '401\n' > "$WORK/jev-status"
run jev-401
[ "$(ncall)" = 1 ] || fail "jev 401: claude called $(ncall) times"
grep -q 'jev unavailable (http 401)' "$LOGF" || fail "jev 401: no http line" "$(cat "$LOGF")"
ok "jev: an http error falls back to haiku"

# a body without the answer shape
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; printf '{"answers":{}}\n' > "$WORK/jev-out"
run jev-badbody
[ "$(ncall)" = 1 ] || fail "jev bad body: claude called $(ncall) times"
grep -q 'jev unavailable (bad-response)' "$LOGF" || fail "jev bad body: no bad-response line" "$(cat "$LOGF")"
ok "jev: an unparseable answer falls back to haiku"

# JEV-WORKING — WORKING is no longer a choice (#1252); #846 still holds either way
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; jev_answer WORKING 0.97
run jev-working
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "jev WORKING promoted a quiet window to [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 1 ] || fail "jev WORKING: an out-of-criteria answer should fall back to haiku, claude called $(ncall) times"
grep -q 'jev unavailable (bad-choice WORKING)' "$LOGF" || fail "jev WORKING: no bad-choice line" "$(cat "$LOGF")"
ok "jev: WORKING is outside the four criteria (#1252) ⇒ haiku decides, the quiet window stays quiet"

# RUBRIC — the haiku prompt offers no WORKING either (#1252)
grep -q '^WORKING - ' "$WORK/claude-in" && fail "haiku prompt still offers WORKING" "$(head -n 8 "$WORK/claude-in")"
grep -q '^LOOPING - ' "$WORK/claude-in" || fail "haiku prompt lost the rubric" "$(head -n 8 "$WORK/claude-in")"
grep -q 'ALREADY ENDED' "$WORK/claude-in" || fail "haiku prompt does not say the turn has ended"
fresh "done"; printf 'WORKING\n' > "$WORK/claude-out"; unset CLASSIFY_BACKEND
run haiku-working
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "haiku WORKING promoted a quiet window to [$(wopt "$ww" @claude_state)]"
grep -q 'working-read ignored (screen never promotes; #846)' "$LOGF" || fail "haiku WORKING: no ignored line" "$(cat "$LOGF")"
export CLASSIFY_BACKEND=jev
ok "rubric: haiku is offered four words and told the turn ended; a stray WORKING is still ignored (#846)"

# a claude failure under jev fallback still leaves the hash unwritten (issue #497)
fresh "done"; printf 'auth error\n' > "$WORK/claude-out"; printf '1\n' > "$WORK/claude-rc"; jev_answer LOOPING 0.2
run jev-claude-fails
[ -f "$CCACHE/$ckey.hash" ] && fail "jev fallback: a failed claude call stamped the hash"
printf '0\n' > "$WORK/claude-rc"
ok "jev fallback: a failed claude call still leaves the hash unwritten (#497)"

# ================================================================ SHADOW
export CLASSIFY_BACKEND=shadow
rm -f "$WORK/shadow.ndjson"
fresh looping; printf 'STOPPED\n' > "$WORK/claude-out"; jev_answer WAITING 0.81
run shadow-disagree
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "shadow: haiku's STOPPED did not decide — [$(wopt "$ww" @claude_state)]"
[ "$(ncall)" = 1 ] || fail "shadow: claude called $(ncall) times"
[ "$(nreq)" = 1 ] || fail "shadow: Jev asked $(nreq) times"
grep -q 'via=jev' "$LOGF" && fail "shadow: verdict line claims via=jev" "$(cat "$LOGF")"
[ "$(wc -l < "$WORK/shadow.ndjson" | tr -d ' ')" = 1 ] || fail "shadow: expected 1 row" "$(cat "$WORK/shadow.ndjson")"
python3 - "$WORK/shadow.ndjson" "$ww" "$HASH" "$CAP" <<'PY' || fail "shadow row: wrong shape" "$(cat "$WORK/shadow.ndjson")"
import json, sys
r = json.loads(open(sys.argv[1], encoding="utf-8").read().splitlines()[-1])
assert r["window"] == sys.argv[2] and r["hash"] == sys.argv[3], (r["window"], r["hash"])
assert r["hook_state"] == "looping" and r["haiku"] == "STOPPED" and r["jev"] == "WAITING", r
assert abs(r["conf"] - 0.81) < 1e-6 and isinstance(r["jev_ms"], int) and isinstance(r["haiku_s"], int), r
assert r["jev_err"] is None and r["capture"] == sys.argv[4], "capture missing on a disagreement"
assert r["ts"].endswith("Z")
PY
ok "shadow: haiku decides; one row {ts, window, hook_state, haiku, jev, conf, hash, latencies} + capture on disagreement"
mode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$WORK/shadow.ndjson")"   # GNU stat -f means something else
[ "$mode" = 0o600 ] || fail "shadow log not 0600 — screen text is in it (mode $mode)"
ok "shadow: the log is created 0600"

fresh looping; printf 'LOOPING\n' > "$WORK/claude-out"; jev_answer LOOPING 0.9
run shadow-agree
[ "$(wopt "$ww" @claude_state)" = looping ] || fail "shadow agree: state is [$(wopt "$ww" @claude_state)]"
python3 - "$WORK/shadow.ndjson" <<'PY' || fail "shadow agree row: wrong shape" "$(tail -n 1 "$WORK/shadow.ndjson")"
import json, sys
r = json.loads(open(sys.argv[1], encoding="utf-8").read().splitlines()[-1])
assert r["haiku"] == "LOOPING" == r["jev"] and "capture" not in r, r
PY
ok "shadow: an agreeing row carries the hash only, no capture text"

fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"
CLASSIFY_JEV_URL='http://127.0.0.1:1/v1/systemone' run shadow-jev-down
[ "$(wopt "$ww" @claude_state)" = "done" ] || fail "shadow jev-down: state [$(wopt "$ww" @claude_state)]"
python3 - "$WORK/shadow.ndjson" <<'PY' || fail "shadow outage row: wrong shape" "$(tail -n 1 "$WORK/shadow.ndjson")"
import json, sys
r = json.loads(open(sys.argv[1], encoding="utf-8").read().splitlines()[-1])
assert r["haiku"] == "STOPPED" and r["jev"] is None and r["conf"] is None and (r["jev_err"] or "").startswith("net"), r
assert "capture" in r
PY
grep -q 'jev unavailable (net .*shadow row without a jev verdict' "$LOGF" || fail "shadow jev-down: no log line" "$(cat "$LOGF")"
ok "shadow: a Jev outage still logs a row (jev null + jev_err) and never touches the state"

out="$(python3 "$REP" "$WORK/shadow.ndjson" 2>&1)" || fail "report script failed" "$out"
printf '%s\n' "$out" | grep -q '^rows=3  both-verdicts=2' || fail "report: header wrong" "$out"
printf '%s\n' "$out" | grep -q 'agreement  raw= 50.0%' || fail "report: agreement wrong" "$out"
printf '%s\n' "$out" | grep -q '^1 disagreements:' || fail "report: disagreement count wrong" "$out"
printf '%s\n' "$out" | grep -q 'waiting 30 seconds' || fail "report: disagreement capture tail missing" "$out"
printf '{"%s":"STOPPED"}\n' "$HASH" > "$WORK/labels.json"
out="$(python3 "$REP" --labels "$WORK/labels.json" "$WORK/shadow.ndjson" 2>&1)" || fail "report --labels failed" "$out"
printf '%s\n' "$out" | grep -q 'labelled subset: n=2  jev-acc=  0.0%  haiku-acc= 50.0%' || fail "report: labelled accuracy wrong" "$out"
ok "shadow report: agreement, disagreement list and labelled accuracy come out of the log"

# ================================================================ PREP (#1252)
# The Stop hook runs this classifier while Claude's own Stop-hooks spinner is still up.
out="$(printf 'recap\n✢ Crunching… (running Stop hooks… 3/4 · 29s · ↓ 1.5k tokens)\n  ⎿  Tip: Use /permissions to pre-approve\n✻ Worked for 9s · done · 1 shell still running\n❯ \n' | bash "$CLS" --prep-capture)"
[ "$out" = "$(printf 'recap\n✻ Worked for 9s · done · 1 shell still running\n❯ ')" ] || fail "--prep-capture: wrong output" "$out"
tmux respawn-pane -k -t "$ww" "printf 'recap of the turn\n✢ Crunching… (running Stop hooks… 3/4 · 29s)\n  ⎿  Tip: Run /install-slack-app\n✻ Worked for 9s · done\n'; sleep 300" 2>/dev/null \
  || fail "could not re-seed the worker pane"
i=0; while [ "$i" -lt 40 ] && ! tmux capture-pane -p -t "$ww" | grep -q 'Worked for'; do i=$((i+1)); sleep 0.1; done
export CLASSIFY_BACKEND=jev
fresh "done"; printf 'STOPPED\n' > "$WORK/claude-out"; jev_answer LOOPING 0.2
run prep
python3 - "$WORK/req/001.json" <<'PY' || fail "prep: the capture Jev saw still carries residue" "$(cat "$WORK/req/001.json")"
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))["state"]
assert "running Stop hooks" not in st and "Tip:" not in st, st
assert "Worked for 9s" in st and "recap of the turn" in st, st
PY
grep -q 'running Stop hooks\|Tip:' "$WORK/claude-in" && fail "prep: the haiku prompt still carries residue" "$(tail -n 5 "$WORK/claude-in")"
grep -q 'Worked for 9s' "$WORK/claude-in" || fail "prep: the haiku prompt lost the screen" "$(tail -n 5 "$WORK/claude-in")"
ok "prep: the Stop-hooks spinner and its Tip never reach Jev or haiku; the done line does (#1252)"

rm -f "$CCACHE/$ckey.hash"
printf 'selftest OK: %s checks — CLASSIFY_BACKEND haiku|jev|shadow: Jev decides only when confident, every failure falls back to haiku, shadow only logs (issue #1229)\n' "$pass"
