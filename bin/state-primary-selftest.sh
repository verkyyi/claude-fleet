#!/bin/bash
# state-primary-selftest.sh — @claude_state has ONE primary source (issue #2537,
# EPIC #2535 C2): the agent's own OSC 7501 report outranks the hooks, the hooks
# outrank the guessers, and a lower source speaks only while the primary is absent
# (@agent_status_ts older than FLEET_STATE_PRIMARY_SECS, 120 s, or its last word the
# relay's `exited`).
#
# A real tmux server on a private socket (a PATH shim pins every bare `tmux`), the
# real bin/set-claude-state.sh, bin/fleet-status-7501.py (pipe mode),
# bin/classify-sessions.sh with a FAKE `claude` (records each call, answers
# STOPPED) and fleet-lib.sh's fleet_primary_fresh / fleet_state_carry.
#
# Asserted:
#   A  HOOK-HELD     7501 said `working` 10 s ago: a Stop `done`, a Notification
#                    `needs` and a PreToolUse AskUserQuestion change nothing
#   B  BLOCKED       the worker's own `blocked` is never held; the new prompt that
#                    clears it is not held either
#   C  STALE         silent 200 s: the hook's `done` lands, labelled hook
#   D  EXITED        a fresh `exited` record from the relay holds nothing
#   E  SAME-VALUE    a hook re-saying the 7501 value keeps the 7501 label
#   F  RELAY         a blocked/permission report → needs/perm + its words, src 7501
#   G  CLASSIFIER    fresh 7501: `skip:7501`, no model call, state kept; silent past
#                    120 s: the screen read decides (done), labelled classifier
#   H  REASSERT      the same report again after another writer took the window
#                    puts the agent's word back
#   I  CARRY         fleet_state_carry stamps `carried` only before the first report
#   J  LAUNCH        fleet-session-wrap.sh clears @agent_status before each launch
#   K  OFF           FLEET_STATE_PRIMARY_SECS=0 holds nothing (byte for byte as before)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# Re-root onto a conf-free shadow of this install (as classify-backend-selftest.sh
# does): the classifier reads `$BIN/../fleet.conf` and writes `$BIN/../logs`.
if [ "${_STATE_PRIMARY_ROOT:-}" != "$BIN" ]; then
  _root="$(sh "$BIN/selftest-shadow-root.sh" "$BIN/..")" || exit 2
  _STATE_PRIMARY_ROOT="$(cd "$_root/bin" && pwd)" bash "$_root/bin/${0##*/}" "$@"; _rc=$?
  rm -rf "$_root"; exit "$_rc"
fi
# The real binary, never the fleet's tmux-shim: that one execs the next `tmux` on
# PATH — which would be our own shim below, and the two would call each other.
REAL_TMUX=''
for _t in $(type -ap tmux); do case "$_t" in */tmux-shim/*) ;; *) REAL_TMUX=$_t; break ;; esac; done
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/state-primary-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOS
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOS
cat > "$WORK/bin/claude" <<EOS
#!/bin/sh
echo call >> "$WORK/claude-calls"
cat >/dev/null
echo STOPPED
EOS
chmod +x "$WORK/bin/tmux" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" CLASSIFY_SETTLE=0 TMUX="$SOCK,1,0"
unset CLASSIFY_SOCK CLASSIFY_BACKEND FLEET_STATE_PRIMARY_SECS CCQUOTA_FLEET CLAUDE_CODE_ENTRYPOINT
mkdir -p "$FLEET_CONF_DIR/global"

tmux -f /dev/null new-session -d -s sp -n issue-1 -x 100 -y 30 "printf 'hello\n'; exec sleep 600" \
  || fail "cannot start the isolated tmux server"
W=$(tmux display-message -p -t sp:issue-1 '#{window_id}')
P=$(tmux display-message -p -t "$W" '#{pane_id}')
o()   { tmux display-message -p -t "$W" "#{$1}"; }
st()  { printf '%s/%s/%s' "$(o @claude_state)" "$(o @claude_needs)" "$(o @claude_state_src)"; }
# reset <state> <needs> <src> <7501 age|-> [status json]
reset() {
  tmux set-option -w -t "$W" @claude_state "$1" \; set-option -w -t "$W" @claude_needs "$2" \
    \; set-option -w -t "$W" @claude_state_src "$3" \; set-option -w -t "$W" @claude_state_ts 1 \
    \; set-option -wu -t "$W" @claude_needs_detail \; set-option -wu -t "$W" @agent_status \; set-option -wu -t "$W" @agent_status_ts
  if [ "$4" != - ]; then
    tmux set-option -w -t "$W" @agent_status_ts "$(( $(date +%s) - $4 ))" \
      \; set-option -w -t "$W" @agent_status "${5:-{\"state\":\"$1\"}}"
  fi
}
hook() {   # hook <stdin> <args…> — set-claude-state.sh as a hook edge on our pane
  local in="$1"; shift
  printf '%s' "$in" | TMUX_PANE="$P" sh "$BIN/set-claude-state.sh" "$@" >/dev/null 2>&1
}

# ── A ──
reset working '' 7501 10
hook '{"hook_event_name":"Stop"}' done
[ "$(st)" = working//7501 ] || fail "A: a Stop during a fresh 7501 working changed the state to [$(st)]"
hook '{"hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}' needs
[ "$(st)" = working//7501 ] || fail "A: a Notification needs during a fresh 7501 working wrote [$(st)]"
hook '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' busy
[ "$(st)" = working//7501 ] || fail "A: a PreToolUse AskUserQuestion during a fresh 7501 working wrote [$(st)]"
ok "A  HOOK-HELD: Stop / Notification / PreToolUse leave the agent's fresh word alone"

# ── B ──
reset working '' 7501 10
hook '' blocked
[ "$(st)" = needs/blocked/hook ] || fail "B: the worker's own blocked was held: [$(st)]"
hook '{"hook_event_name":"PostToolUse"}' working
[ "$(st)" = needs/blocked/hook ] || fail "B: a PostToolUse cleared blocked: [$(st)]"
hook '{"hook_event_name":"UserPromptSubmit"}' working
[ "$(st)" = working//hook ] || fail "B: the new prompt did not clear blocked under a fresh 7501: [$(st)]"
ok "B  BLOCKED: the declaration and the prompt that clears it are never held"

# ── C ──
reset working '' 7501 200
hook '{"hook_event_name":"Stop"}' done
[ "$(st)" = done//hook ] || fail "C: 7501 silent 200 s, the hook's done did not land: [$(st)]"
ok "C  STALE: two minutes of silence and the hook speaks"

# ── D ──
reset working '' 7501 5 '{"state":"exited","rc":0}'
hook '{"hook_event_name":"Stop"}' done
[ "$(st)" = done//hook ] || fail "D: a fresh relay exited record held the hook: [$(st)]"
ok "D  EXITED: the relay's exited record holds nothing"

# ── E ──
reset working '' 7501 300
hook '{"hook_event_name":"PostToolUse"}' working
[ "$(st)" = working//7501 ] || fail "E: a hook re-saying working relabelled the window: [$(st)]"
reset done '' classifier -
hook '{"hook_event_name":"UserPromptSubmit"}' working
[ "$(st)" = working//hook ] || fail "E: a hook changing a classifier's value did not take the label: [$(st)]"
ok "E  SAME-VALUE: a lower source re-saying the value keeps the higher label"

# ── F ──
reset working '' hook -
msg=$(printf 'Bash: git push origin main' | base64 | tr -d '\n')
printf '\033]7501;state=blocked:app=claude-code:kind=permission:msg=%s\033\\' "$msg" \
  | TMUX_PANE="$P" python3 "$BIN/fleet-status-7501.py" pipe
[ "$(st)" = needs/perm/7501 ] || fail "F: a blocked/permission report wrote [$(st)]"
[ "$(o @claude_needs_detail)" = 'Bash: git push origin main' ] || fail "F: the words are [$(o @claude_needs_detail)]"
case "$(o @agent_status_ts)" in ''|*[!0-9]*) fail "F: no @agent_status_ts" ;; esac
hook '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' busy
[ "$(st)" = needs/perm/7501 ] || fail "F: waiting on permission, a PreToolUse working overwrote it: [$(st)]"
ok "F  RELAY: needs/perm with its words, src 7501, and the hooks held off"

# ── G ──
rm -f "$WORK/claude-calls"
reset needs perm 7501 10 '{"state":"blocked","kind":"permission"}'
bash "$BIN/classify-sessions.sh" --window "$W"
[ "$(st)" = needs/perm/7501 ] || fail "G: the classifier overwrote a fresh 7501 blocked: [$(st)]"
[ ! -f "$WORK/claude-calls" ] || fail "G: the classifier called the model while 7501 was fresh"
grep -q "skip:7501" "$BIN/../logs/classify.log" 2>/dev/null || fail "G: no skip:7501 line" "$(tail -3 "$BIN/../logs/classify.log" 2>/dev/null)"
reset needs perm 7501 130 '{"state":"blocked","kind":"permission"}'
bash "$BIN/classify-sessions.sh" --window "$W"
[ "$(st)" = done//classifier ] || fail "G: 130 s after the last report the screen read did not decide: [$(st)]" "$(tail -3 "$BIN/../logs/classify.log" 2>/dev/null)"
[ -f "$WORK/claude-calls" ] || fail "G: past the window the classifier never asked the model"
ok "G  CLASSIFIER: skip:7501 while fresh; after 120 s the screen decides"

# ── H ──
reset working '' hook -
{ printf '\033]7501;state=working:app=claude-code\033\\'
  sleep 1.5
  tmux set-option -w -t "$W" @claude_state done \; set-option -w -t "$W" @claude_state_src classifier
  printf '\033]7501;state=working:app=claude-code\033\\'
  sleep 1.5; } | TMUX_PANE="$P" FLEET_7501_REFRESH_SECS=0 python3 "$BIN/fleet-status-7501.py" pipe
[ "$(st)" = working//7501 ] || fail "H: the same report after a guess did not put the agent's word back: [$(st)]"
ok "H  REASSERT: the agent's repeated word takes the window back"

# ── I ──
reset working '' hook -
tmux set-option -wu -t "$W" @claude_state_src
bash -c '. "$1/fleet-lib.sh"; fleet_state_carry "" "$2" looping' _ "$BIN" "$W"
[ "$(st)" = looping//carried ] || fail "I: a carry before the first report wrote [$(st)]"
reset working '' 7501 3
bash -c '. "$1/fleet-lib.sh"; fleet_state_carry "" "$2" looping' _ "$BIN" "$W"
[ "$(st)" = working//7501 ] || fail "I: a carry after the agent spoke overwrote it: [$(st)]"
ok "I  CARRY: a migrated state is a bootstrap value, never over the agent's word"

# ── J ──
awk '/wset -u @agent_status;/{c=1} c && /"\$LAUNCH"/{print "ok"; exit}' "$BIN/fleet-session-wrap.sh" | grep -q ok \
  || fail "J: fleet-session-wrap.sh does not clear @agent_status before it launches the agent"
ok "J  LAUNCH: the wrapper clears the last agent's report before each launch"

# ── K ──
reset working '' 7501 10
printf '{}' | TMUX_PANE="$P" FLEET_STATE_PRIMARY_SECS=0 sh "$BIN/set-claude-state.sh" done >/dev/null 2>&1
[ "$(st)" = done//hook ] || fail "K: FLEET_STATE_PRIMARY_SECS=0 still held the hook: [$(st)]"
bash -c '. "$1/fleet-lib.sh"; FLEET_STATE_PRIMARY_SECS=0 fleet_primary_fresh "$2"' _ "$BIN" "$W" \
  && fail "K: fleet_primary_fresh answered fresh with the knob at 0"
ok "K  OFF: FLEET_STATE_PRIMARY_SECS=0 holds nothing"

printf 'state-primary selftest: OK (%d legs)\n' "$pass"
