#!/bin/bash
# fleet-session-shell-agent-selftest.sh — `codex` / `claude` in a session's shell
# (⌃\, issue #3463): bin/session-shell/{codex,claude} → fleet-session-shell-agent.sh.
#
#   A  the session's own agent, still running → no run, exit 2, 「按 ⌃\ 回到会话」
#   B  …its agent exited → 「在退出页按 ↵ 接回原对话」
#   C  an unstamped window is a Claude session: `claude` is said back too
#   D  passes through to the real command, untouched: another agent · --version ·
#      FLEET_RAW_AGENT=1 · no session behind the shell · that window gone
#   E  fleet_view.py's here-shell (⌃\ on this machine) gets the same PATH + window,
#      as fleet-remote-view.sh shell-here does (pinned in fleet-remote-view-selftest S)
#
# On a real isolated tmux server (-S socket, killed at exit); tmux absent → SKIP.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'session-shell-agent: tmux absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ssagent.XXXXXX")" || exit 2
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
CHECKS=0
fail() { printf 'session-shell-agent FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq()  { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — no [$3] in" "$2" ;; esac; }

# the real agents (they say they ran) and a tmux that is the isolated server —
# the script addresses the session's fleet socket by label (-L), dropped here
mkdir -p "$WORK/real"
for a in codex claude; do
  printf '#!/bin/bash\necho "REAL %s${*:+ $*}"\n' "$a" > "$WORK/real/$a"; chmod +x "$WORK/real/$a"
done
cat > "$WORK/real/tmux" <<EOF
#!/bin/bash
[ "\${1:-}" = -L ] && shift 2
PATH='$PATH' exec '$REAL_TMUX' -S '$SOCK' "\$@"   # the caller's PATH: a tmux shim finds the real one
EOF
chmod +x "$WORK/real/tmux"

tf -f /dev/null new-session -d -s sh -n sess -x 100 -y 30 'sleep 600' || fail "cannot start the isolated tmux server"
W=$(tf display-message -p -t sh:sess '#{window_id}')
tf set-option -w -t "$W" @cc_agent codex
tf set-option -w -t "$W" @claude_state working

PTH="$BIN/session-shell:$WORK/real:/usr/bin:/bin"
run() {  # <env assignments…> -- <cmd…>: stdout+stderr, then rc=<n>
  local -a e=()
  while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  env PATH="$PTH" FLEET_UI_LANG=zh FLEET_SESSION_SHELL_SOCK=fleet ${e[@]+"${e[@]}"} "$@" 2>&1; printf 'rc=%s' "$?"
}

# A
out=$(run FLEET_SESSION_SHELL_WIN="$W" -- codex)
has "A: the session's own Codex, running — said back to it" "$out" '这是会话「sess」旁边的 shell，不是会话本身。它的 Codex 还在会话里运行：按 ⌃\ 回到会话。'
has "A: …why a bare one asks to log in" "$out" '没有 fleet 的登录'
has "A: …exit 2" "$out" 'rc=2'
CHECKS=$((CHECKS + 1)); case "$out" in *REAL*) fail "A: the real codex ran" "$out" ;; esac
out=$(run FLEET_SESSION_SHELL_WIN="$W" -- codex resume abc)
CHECKS=$((CHECKS + 1)); case "$out" in *REAL*) fail "A: \`codex resume\` reached the real codex" "$out" ;; esac

# B
tf set-option -w -t "$W" @claude_state exited
out=$(run FLEET_SESSION_SHELL_WIN="$W" -- codex)
has "B: its Codex exited — ↵ on its page resumes it" "$out" '它的 Codex 已经退出：按 ⌃\ 回到会话，在退出页按 ↵ 接回原对话。'
has "B: …exit 2" "$out" 'rc=2'
out=$(run FLEET_SESSION_SHELL_WIN="$W" FLEET_UI_LANG=en -- codex)
has "B: in English too" "$out" 'Its Codex has exited'

# C
tf set-option -wu -t "$W" @cc_agent
out=$(run FLEET_SESSION_SHELL_WIN="$W" -- claude)
has "C: an unstamped window is Claude's — \`claude\` said back" "$out" '它的 Claude 已经退出'
out=$(run FLEET_SESSION_SHELL_WIN="$W" -- codex hi)
eq "C: …and \`codex\` there is not its agent: the real one" "REAL codex hi
rc=0" "$out"
tf set-option -w -t "$W" @cc_agent codex

# D
eq "D: another agent passes through" "REAL claude -p x
rc=0" "$(run FLEET_SESSION_SHELL_WIN="$W" -- claude -p x)"
eq "D: --version passes through" "REAL codex --version
rc=0" "$(run FLEET_SESSION_SHELL_WIN="$W" -- codex --version)"
eq "D: FLEET_RAW_AGENT=1 passes through" "REAL codex
rc=0" "$(run FLEET_SESSION_SHELL_WIN="$W" FLEET_RAW_AGENT=1 -- codex)"
eq "D: no session behind the shell passes through" "REAL codex a b
rc=0" "$(run -- codex a b)"
tf new-window -d -t sh: -n other 'sleep 600'
tf kill-window -t "$W"
eq "D: the session's window gone passes through" "REAL codex
rc=0" "$(run FLEET_SESSION_SHELL_WIN="$W" -- codex)"
eq "D: no real one anywhere — 127" "codex: command not found
rc=127" "$(env PATH="$BIN/session-shell:/usr/bin:/bin" bash "$BIN/session-shell/codex" 2>&1; printf 'rc=%s' "$?")"

# E: the 看台's own here-shell (fleet_view.shell_pane) puts the same in front
W2=$(tf new-window -d -P -F '#{window_id}' -t sh: -n s2 'sleep 600')
cat > "$WORK/fakesh" <<EOF
#!/bin/bash
printf 'win=%s path=%s\n' "\$FLEET_SESSION_SHELL_WIN" "\${PATH%%:*}" > '$WORK/e.out'
EOF
chmod +x "$WORK/fakesh"
SHELL="$WORK/fakesh" TMUX="$SOCK,0,0" PATH="$WORK/real:$PATH" python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import fleet_view
fleet_view.shell_pane("v", "here", "m", "l", sys.argv[2])' "$BIN" "$W2" >/dev/null 2>&1
eq "E: the here-shell is told its session and leads with session-shell/" "win=$W2 path=$BIN/session-shell" "$(cat "$WORK/e.out" 2>/dev/null)"

printf 'session-shell-agent selftest: PASS (%d checks)\n' "$CHECKS"
