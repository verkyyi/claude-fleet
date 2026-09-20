#!/bin/bash
# blocked-state-selftest.sh — a worker's declared blocker survives the turn (#704).
# Real tmux, on an isolated socket; fake classifier/oracle responses. No live Claude.
# Drive the same hook arguments as settings-hooks.json, including the PostToolUse
# of the declaring Bash call, the later report call and Stop. Slow-reader races are
# deterministic: the fake helper stamps blocked before returning its old verdict.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
TEST_REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$TEST_REAL_TMUX" ] || { printf 'blocked-state: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'blocked-state: python3 absent — SKIP\n'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/b704.XXXXXX")" || exit 2
TEST_SOCK="$WORK/s"
tf() { "$TEST_REAL_TMUX" -S "$TEST_SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
fail() { printf 'FAIL: %s\n' "$1" >&2; tf show-window-options -t "$TEST_PANE" >&2; exit 1; }
CHECKS=0
same() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }

mkdir -p "$WORK/path" "$WORK/inst/bin" "$WORK/inst/logs" "$WORK/conf"
for f in set-claude-state.sh classify-sessions.sh tmux-spinner.sh; do
  cp "$BIN/$f" "$WORK/inst/bin/$f"
done
TEST_HOOK="$WORK/inst/bin/set-claude-state.sh"
# Auto-handoff is enabled so preserving blocked at Stop must also suppress its nudge.
cat > "$WORK/inst/bin/fleet-hook-conf.sh" <<'SH'
#!/bin/sh
printf '1\n0\n'
SH
cat > "$WORK/inst/bin/fleet-lib.sh" <<'SH'
fleet_helper_claude_auth() { :; }
SH
cat > "$WORK/path/tmux" <<'SH'
#!/bin/sh
case "${1:-}" in -L|-S) shift 2 ;; esac
exec "$TEST_REAL_TMUX" -S "$TEST_SOCK" "$@"
SH
cat > "$WORK/path/claude" <<'SH'
#!/bin/sh
cat >/dev/null
printf 'called\n' >> "$TEST_CALLS"
if [ "${BLOCK_DURING_CLASSIFY:-0}" = 1 ]; then
  env TMUX="$TEST_TMUX" TMUX_PANE="$TEST_PANE" sh "$TEST_HOOK" blocked >/dev/null
fi
printf '%s\n' "${CLASSIFY_VERDICT:-STOPPED}"
SH
cat > "$WORK/inst/bin/fleet-pending-tool.sh" <<'SH'
#!/bin/sh
# Called after the spinner's candidate scan; stamp a new blocker mid-probe.
env TMUX="$TEST_TMUX" TMUX_PANE="$TEST_PANE" sh "$TEST_HOOK" blocked >/dev/null
exit 1
SH
chmod +x "$WORK/path/tmux" "$WORK/path/claude" "$WORK/inst/bin/fleet-pending-tool.sh"
export TEST_REAL_TMUX TEST_SOCK TEST_HOOK
PATH="$WORK/path:$PATH"; export PATH
tf -f /dev/null new-session -d -s fleet704 -n worker 'printf "Blocked fixture screen\n"; exec sleep 300' \
  || { printf 'blocked-state: cannot start isolated tmux server\n' >&2; exit 1; }
TEST_PANE=$(tf display-message -p -t fleet704:worker '#{pane_id}')
TEST_TMUX="$TEST_SOCK,1,0"
TEST_CALLS="$WORK/calls"
export TEST_PANE TEST_TMUX TEST_CALLS
tf set-window-option -t "$TEST_PANE" @issue 704
tf set-window-option -t "$TEST_PANE" @ctx_pct 99
snapshot() { tf display-message -p -t "$TEST_PANE" '#{@claude_state}/#{@claude_needs}/#{@claude_state_ts}'; }
state() { tf display-message -p -t "$TEST_PANE" '#{@claude_state}/#{@claude_needs}'; }
hook() {
  printf '%s\n' "${2:-}" | env TMUX="$TEST_TMUX" TMUX_PANE="$TEST_PANE" \
    CLAUDE_CODE_ENTRYPOINT=cli sh "$TEST_HOOK" "$1" > "$WORK/hook.out" 2>/dev/null
}
# Resolve the actual shipped bindings rather than assume PostToolUse and prompts
# still share a verb. A binding change must exercise the production argument here.
hook_arg() {
  python3 - "$BIN/../hooks/settings-hooks.json" "$1" <<'PY'
import json, shlex, sys
for group in json.load(open(sys.argv[1]))['hooks'][sys.argv[2]]:
    for hook in group.get('hooks', []):
        parts = shlex.split(hook.get('command', ''))
        for i, part in enumerate(parts):
            if part.endswith('/set-claude-state.sh'):
                print(parts[i + 1])
                sys.exit(0)
sys.exit(1)
PY
}
PRE=$(hook_arg PreToolUse) || exit 1
POST=$(hook_arg PostToolUse) || exit 1
STOP=$(hook_arg Stop) || exit 1
PROMPT=$(hook_arg UserPromptSubmit) || exit 1

# The old charter instruction loses red in its own PostToolUse; the new verb must
# survive exactly that sequence, including timestamp and absence of a Stop nudge.
hook "$PRE" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
hook blocked
same 'blocked sets a distinct needs subtype' "$(state)" needs/blocked
tf set-window-option -t "$TEST_PANE" @claude_state_ts 123
BLOCKED=$(snapshot)
hook "$POST" '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
same 'declaring Bash PostToolUse preserves blocked and its age' "$(snapshot)" "$BLOCKED"
hook "$PRE" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
hook "$POST" '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
hook "$STOP" '{"hook_event_name":"Stop","stop_hook_active":false}'
same 'report tool call and Stop preserve blocked' "$(snapshot)" "$BLOCKED"
same 'blocked Stop emits no auto-handoff nudge' "$(cat "$WORK/hook.out")" ''
hook needs '{"hook_event_name":"Notification","notification_type":"idle_prompt"}'
same 'idle notification preserves blocked' "$(snapshot)" "$BLOCKED"

CLASSIFY_SETTLE=0 bash "$WORK/inst/bin/classify-sessions.sh" --window "$TEST_PANE"
same 'classifier preserves blocked before calling the helper' "$(snapshot)" "$BLOCKED"
[ ! -f "$TEST_CALLS" ] || fail 'blocked screen must not spend a classifier call'


# Invalid/missing/nested event data cannot masquerade as a new prompt.
for payload in '' 'not-json' '{"tool_response":{"hook_event_name":"UserPromptSubmit"},"hook_event_name":"PostToolUse"}'; do
  hook "$POST" "$payload"
  same 'non-prompt input leaves blocked alone' "$(snapshot)" "$BLOCKED"
done
hook "$PROMPT" $'{\n "hook_event_name" \t : \n "UserPromptSubmit"\n}'
same 'a new prompt clears blocked regardless of JSON whitespace' "$(state)" working/
hook "$POST" '{"hook_event_name":"PostToolUse"}'
same 'normal tool traffic resumes after a prompt' "$(state)" working/

# Live dialogs still own their normal lifecycle even after a declaration.
hook blocked
hook "$PRE" '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
same 'AskUserQuestion supersedes blocked' "$(state)" needs/ask
hook "$POST" '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
same 'answering the question clears ask' "$(state)" working/
hook blocked
hook needs '{"hook_event_name":"Notification","message":"Claude needs your permission"}'
same 'permission notification supersedes blocked' "$(state)" needs/perm
hook "$POST" '{"hook_event_name":"PostToolUse"}'
same 'permission result clears perm' "$(state)" working/
tf set-window-option -t "$TEST_PANE" @claude_needs blocked
hook "$POST" '{"hook_event_name":"PostToolUse"}'
same 'a stale subtype on working is not sticky' "$(state)" working/

# A classifier already in flight must not erase a later worker declaration.
hook needs
BLOCK_DURING_CLASSIFY=1 CLASSIFY_SETTLE=0 bash "$WORK/inst/bin/classify-sessions.sh" --window "$TEST_PANE"
[ -s "$TEST_CALLS" ] || fail 'race fixture never called the classifier helper'
same 'in-flight classifier cannot overwrite a new blocker' "$(state)" needs/blocked
WID=$(tf display-message -p -t "$TEST_PANE" '#{window_id}')
KEY=$(printf '%s' "$WID" | tr '/:@' '___')
[ ! -f "$WORK/inst/logs/.classify-cache/$KEY.hash" ] || fail 'discarded classifier verdict must stay unhashed'
hook "$PROMPT" '{"hook_event_name":"UserPromptSubmit"}'
hook needs
CLASSIFY_SETTLE=0 bash "$WORK/inst/bin/classify-sessions.sh" --window "$TEST_PANE"
same 'classifier still handles ordinary needs' "$(state)" done/

# Two agreeing idle probes cannot apply an old verdict to a new blocked stamp.
hook needs
OLD=$(( $(date +%s) - 600 ))
tf set-window-option -t "$TEST_PANE" @claude_state_ts "$OLD"
printf '%s |fleet704:%s:idle|\n' "$(date +%s)" "$WID" > "$WORK/inst/logs/.needs-strikes"
printf 'FLEET_REPO="test/blocked"\n' > "$WORK/conf/fleet704.conf"
FLEET_CONF_DIR="$WORK/conf" FLEET_NEEDS_PLAIN_SECS=1 FLEET_NEEDS_RECONCILE_SECS=1 \
  FLEET_NEEDS_STRIKE_TTL=120 sh "$WORK/inst/bin/tmux-spinner.sh" --needs-check
same 'in-flight reconcile cannot overwrite a new blocker' "$(state)" needs/blocked

# A4 (#846): a screen read never PROMOTES a quiet window to working. A WORKING
# verdict on a done window (a stale frame re-reddening what #806/#101 demoted)
# spends a call but changes nothing; only the UserPromptSubmit hook starts a turn.
tf set-window-option -t "$TEST_PANE" @claude_state done
tf set-window-option -t "$TEST_PANE" @claude_needs ''
tf set-window-option -t "$TEST_PANE" @claude_state_ts 123
A4WID=$(tf display-message -p -t "$TEST_PANE" '#{window_id}')
A4KEY=$(printf '%s' "$A4WID" | tr '/:@' '___')
rm -f "$WORK/inst/logs/.classify-cache/$A4KEY.hash" "$TEST_CALLS"
CLASSIFY_VERDICT=WORKING CLASSIFY_SETTLE=0 bash "$WORK/inst/bin/classify-sessions.sh" --window "$TEST_PANE"
[ -s "$TEST_CALLS" ] || fail 'A4 fixture never called the classifier helper'
same 'a WORKING screen read never promotes a quiet window' "$(state)" done/

printf 'blocked-state-selftest: OK (%s checks)\n' "$CHECKS"
