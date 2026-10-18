#!/bin/bash
# blocked-state-selftest.sh — a worker's declared blocker survives the turn (#704).
# Real tmux, on an isolated socket; fake oracle responses. No live Claude.
# Drive the same hook arguments as settings-hooks.json, including the PostToolUse
# of the declaring Bash call, the later report call and Stop. Slow-reader races are
# deterministic: the fake oracle stamps blocked before returning its old verdict.
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

mkdir -p "$WORK/path" "$WORK/inst/bin" "$WORK/conf/logs"
# the spinner's strikes are the login's records (#4668)
export FLEET_CONF_DIR="$WORK/conf"
for f in set-claude-state.sh tmux-spinner.sh tmux-spinner.py fleet-render-watch.py; do
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
cat > "$WORK/inst/bin/fleet_pending_tool.py" <<'PYORACLE'
import os, subprocess, time
PANE_FORMAT = '#{pane_id}'
def parse_panes(text): return [dict(pane=p) for p in text.splitlines()]
def observe(reader, expected=None):
    rows = reader()
    if os.environ.get('BLOCK_DURING_RECONCILE') == '1':
        subprocess.run(['sh', os.environ['TEST_HOOK'], 'blocked'], check=True,
                       env=dict(os.environ, TMUX=os.environ['TEST_TMUX'], TMUX_PANE=os.environ['TEST_PANE']))
    reader()
    return [dict(pane=r['pane'], code=1, tool='', identity={'pane':r['pane']}, expires_at=time.time()+10) for r in rows]
PYORACLE
chmod +x "$WORK/path/tmux"
export TEST_REAL_TMUX TEST_SOCK TEST_HOOK
PATH="$WORK/path:$PATH"; export PATH
tf -f /dev/null new-session -d -s fleet704 -n worker 'printf "Blocked fixture screen\n"; exec sleep 300' \
  || { printf 'blocked-state: cannot start isolated tmux server\n' >&2; exit 1; }
TEST_PANE=$(tf display-message -p -t fleet704:worker '#{pane_id}')
TEST_TMUX="$TEST_SOCK,1,0"
export TEST_PANE TEST_TMUX
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

WID=$(tf display-message -p -t "$TEST_PANE" '#{window_id}')

# Two agreeing idle probes cannot apply an old verdict to a new blocked stamp.
hook needs
OLD=$(( $(date +%s) - 600 ))
tf set-window-option -t "$TEST_PANE" @claude_state_ts "$OLD"
printf '%s |fleet704:%s:idle|\n' "$(date +%s)" "$WID" > "$WORK/conf/logs/.needs-strikes"
printf 'FLEET_REPO="test/blocked"\n' > "$WORK/conf/fleet704.conf"
for race in 0 1; do
  BLOCK_DURING_RECONCILE="$race" FLEET_CONF_DIR="$WORK/conf" FLEET_NEEDS_PLAIN_SECS=1 FLEET_NEEDS_RECONCILE_SECS=1 \
    FLEET_NEEDS_STRIKE_TTL=120 sh "$WORK/inst/bin/tmux-spinner.sh" --needs-check
done
same 'in-flight reconcile cannot overwrite a new blocker' "$(state)" needs/blocked

printf 'blocked-state-selftest: OK (%s checks)\n' "$CHECKS"
