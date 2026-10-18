#!/bin/bash
# fleet-stream-resume-selftest.sh — bin/fleet-stream-resume.sh (issue #4714): a turn
# an API error cut off («Connection lost mid-response») is resumed by itself, once
# per failure, within a budget, never over a person or for a non-transient error.
# An isolated tmux server (-S), a stub sender; hooks/settings-hooks.json wires it.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
REAL_TMUX=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v tmux-shim | paste -sd: -) command -v tmux)
[ -n "$REAL_TMUX" ] || { echo "SKIP: no tmux"; exit 0; }
W=$(mktemp -d "${TMPDIR:-/tmp}/fsr.XXXXXX") || exit 2
SOCK="$W/sock"
trap '"$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/tbin"
printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$W/tbin/tmux"; chmod +x "$W/tbin/tmux"
cat > "$W/send" <<EOF
#!/bin/sh
printf '%s\t%s\n' "\$1" "\$2" >> "$W/sent"
EOF
chmod +x "$W/send"
"$REAL_TMUX" -S "$SOCK" new-session -d -s t -x 80 -y 20 'sleep 600' || { echo "SKIP: tmux will not start"; exit 0; }
PANE=$("$REAL_TMUX" -S "$SOCK" display-message -p -t t '#{pane_id}')
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
opt() { "$REAL_TMUX" -S "$SOCK" show-options -wqv -t "$PANE" "$1"; }
hook() {   # <error> [env…]
  local e="$1"; shift
  printf '{"hook_event_name":"StopFailure","error":"%s","error_details":"Connection lost mid-response"}' "$e" \
    | env PATH="$W/tbin:$PATH" TMUX="$SOCK,1,0" TMUX_PANE="$PANE" FLEET_CONF_DIR="$W/conf" \
      FLEET_STREAM_RESUME_FG=1 FLEET_STREAM_RESUME_SECS=0 FLEET_STREAM_RESUME_SEND_CMD="$W/send" "$@" \
      bash "$BIN/fleet-stream-resume.sh"
}
sent() { [ -f "$W/sent" ] && wc -l < "$W/sent" | tr -d ' ' || echo 0; }

# A — the stream cut: resumed, over the pane's own inbox, with the error named
"$REAL_TMUX" -S "$SOCK" set-option -w -t "$PANE" @claude_state exited
hook unknown
if [ "$(sent)" = 1 ] && grep -q "^$PANE	.*cut off by an API error (unknown).*Continue" "$W/sent"; then
  pass "A Connection lost (unknown) → one resume to $PANE"
else fail "A no resume: $(cat "$W/sent" 2>/dev/null)"; fi
[ "$(opt @stream_resume | cut -d' ' -f1)" = 1 ] && [ -z "$(opt @stream_fail_ts)" ] \
  && pass "A booked 1 in the budget, the failure mark cleared" || fail "A book: [$(opt @stream_resume)] mark [$(opt @stream_fail_ts)]"

# B — not transient: a quota, an auth / request error stay for their owners
for e in rate_limit authentication_failed invalid_request billing_error ""; do hook "$e"; done
[ "$(sent)" = 1 ] && pass "B rate_limit / auth / request / billing / none → no resume" || fail "B sent for a non-transient error: $(cat "$W/sent")"

# C — a person (or anything) moved the session before the delay: dropped
"$REAL_TMUX" -S "$SOCK" set-option -w -t "$PANE" @claude_state working
hook server_error
[ "$(sent)" = 1 ] && grep -q "dropped error=server_error: the session moved on (state working)" "$W/conf/logs/stream-resume.log" \
  && pass "C state working at send time → dropped, logged" || fail "C resumed over a working session: $(tail -2 "$W/conf/logs/stream-resume.log")"
"$REAL_TMUX" -S "$SOCK" set-option -w -t "$PANE" @claude_state exited

# D — the budget: 3 per window (C's booking counted), the next left for a person
hook overloaded
hook unknown
[ "$(sent)" = 2 ] && grep -q "skip error=unknown: 3 resumes since" "$W/conf/logs/stream-resume.log" \
  && pass "D past FLEET_STREAM_RESUME_MAX=3 per window → left for a person" || fail "D budget: sent $(sent), log: $(tail -2 "$W/conf/logs/stream-resume.log")"
#   …and a window that has passed opens a new budget
"$REAL_TMUX" -S "$SOCK" set-option -w -t "$PANE" @stream_resume "3 $(( $(date +%s) - 4000 ))"
hook unknown
[ "$(sent)" = 3 ] && [ "$(opt @stream_resume | cut -d' ' -f1)" = 1 ] && pass "D a window past FLEET_STREAM_RESUME_WINDOW starts again" \
  || fail "D the old window still held: sent $(sent) book [$(opt @stream_resume)]"

# E — off, headless, no pane: nothing
hook unknown FLEET_STREAM_RESUME=0
hook unknown CLAUDE_CODE_ENTRYPOINT=sdk-cli
printf '{"error":"unknown"}' | env -u TMUX_PANE TMUX="$SOCK,1,0" FLEET_STREAM_RESUME_FG=1 FLEET_STREAM_RESUME_SECS=0 \
  FLEET_STREAM_RESUME_SEND_CMD="$W/send" FLEET_CONF_DIR="$W/conf" bash "$BIN/fleet-stream-resume.sh"
[ "$(sent)" = 3 ] && pass "E FLEET_STREAM_RESUME=0 / headless / no pane → nothing" || fail "E sent: $(tail -1 "$W/sent")"

# F — a later failure supersedes the first's pending resume (the background road)
"$REAL_TMUX" -S "$SOCK" set-option -wu -t "$PANE" @stream_resume
printf '{"error":"unknown"}' | env PATH="$W/tbin:$PATH" TMUX="$SOCK,1,0" TMUX_PANE="$PANE" FLEET_CONF_DIR="$W/conf" \
  FLEET_STREAM_RESUME_SECS=2 FLEET_STREAM_RESUME_SEND_CMD="$W/send" bash "$BIN/fleet-stream-resume.sh"
"$REAL_TMUX" -S "$SOCK" set-option -w -t "$PANE" @stream_fail_ts 1
sleep 3
[ "$(sent)" = 3 ] && grep -q "a later failure booked its own" "$W/conf/logs/stream-resume.log" \
  && pass "F returns at once; a later failure's mark drops the earlier resume" || fail "F: sent $(sent)"

# G — wired: the hook table runs it on StopFailure; Codex says why it has none
python3 - "$ROOT" <<'PY' && pass "G settings-hooks.json StopFailure → fleet-stream-resume.sh; codex-map names it" || fail "G not wired"
import json, sys
r = sys.argv[1]
t = json.load(open(r + "/hooks/settings-hooks.json"))["hooks"].get("StopFailure") or []
ok = any("fleet-stream-resume.sh" in h.get("command", "") for g in t for h in g.get("hooks", []))
m = json.load(open(r + "/hooks/codex-map.json"))["events"].get("StopFailure")
sys.exit(0 if ok and isinstance(m, str) else 1)
PY

[ "$FAIL" = 0 ] && { echo "fleet-stream-resume-selftest: all passed"; exit 0; }
echo "fleet-stream-resume-selftest: $FAIL failed"; exit 1
