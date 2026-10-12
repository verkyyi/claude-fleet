#!/bin/bash
# fleet-session-shell-agent.sh <codex|claude> [args…] — what `codex` / `claude` do
# in a SESSION's shell (⌃\ in a 看台: fleet-remote-view.sh shell-here, or
# fleet_view.py's here-shell; issue #3463). That shell sits beside the session —
# the session's agent is still running in its own window — and a bare `codex`
# there opens the login's default home, which holds no credential (the fleet's
# sessions get theirs from the credential proxy at launch), so Codex asks to log
# in: on 2026-10-11 that read as «the Codex session dropped to a shell and won't
# come back» while it ran on untouched.
#
# So when the command is the session's own agent (its window's @cc_agent, Claude
# when unstamped), say where the session is instead — ⌃\ goes back to it; when its
# agent has exited, ↵ on its page resumes the same conversation — and exit 2.
# Anything else passes through to the real command, untouched: another agent, a
# --version / --help, no session behind this shell (FLEET_SESSION_SHELL_WIN unset),
# that window gone, or FLEET_RAW_AGENT=1 (the person's deliberate bare run).
# bin/session-shell/{codex,claude} lead the shell's PATH and land here.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
name="${1:-}"; [ "$#" -gt 0 ] && shift
case "$name" in codex|claude) ;; *) echo 'fleet-session-shell-agent: codex|claude' >&2; exit 2 ;; esac

real() {  # the command this one shadows: the first on PATH that is not session-shell/
  local d IFS=:
  for d in $PATH; do
    [ -n "$d" ] && [ "$d" != "$HERE/session-shell" ] && [ -x "$d/$name" ] && [ ! -d "$d/$name" ] \
      && { printf '%s/%s' "$d" "$name"; return 0; }
  done
  return 1
}
pass() {
  local r; r=$(real) || { echo "$name: command not found" >&2; exit 127; }
  exec "$r" "$@"
}

[ "${FLEET_RAW_AGENT:-}" = 1 ] && pass "$@"
w="${FLEET_SESSION_SHELL_WIN:-}"
[ -n "$w" ] || pass "$@"
case "${1:-}" in --version|-V|--help|-h) pass "$@" ;; esac
T() { tmux ${FLEET_SESSION_SHELL_SOCK:+-L "$FLEET_SESSION_SHELL_SOCK"} "$@"; }
# `|`, not a tab (IFS whitespace folds an empty @cc_agent away) nor a control
# byte (tmux rewrites those): none of the first three holds one, the name is last
info=$(T display-message -p -t "$w" '#{window_id}|#{@cc_agent}|#{@claude_state}|#{window_name}' 2>/dev/null) || pass "$@"
IFS='|' read -r wid agent state wname <<< "$info"
[ "$wid" = "$w" ] || pass "$@"                     # that window is gone
[ "$agent" = codex ] || agent=claude
[ "$agent" = "$name" ] || pass "$@"                # not this session's agent
label=Claude; [ "$agent" = codex ] && label=Codex
if [ "${FLEET_UI_LANG:-zh}" = en ]; then
  if [ "$state" = exited ]; then
    printf 'This is the shell beside the session "%s", not the session. Its %s has exited: press ⌃\\ to go back to it, then ↵ on its page resumes the same conversation.\n' "$wname" "$label" >&2
  else
    printf 'This is the shell beside the session "%s", not the session. Its %s is still running there: press ⌃\\ to go back to it.\n' "$wname" "$label" >&2
  fi
  printf '%s run here uses the default home, without the fleet login. To run it anyway: FLEET_RAW_AGENT=1 %s\n' "$name" "$name" >&2
else
  if [ "$state" = exited ]; then
    printf '这是会话「%s」旁边的 shell，不是会话本身。它的 %s 已经退出：按 ⌃\\ 回到会话，在退出页按 ↵ 接回原对话。\n' "$wname" "$label" >&2
  else
    printf '这是会话「%s」旁边的 shell，不是会话本身。它的 %s 还在会话里运行：按 ⌃\\ 回到会话。\n' "$wname" "$label" >&2
  fi
  printf '在这里直接运行 %s 用的是默认配置，没有 fleet 的登录。确实要这样运行：FLEET_RAW_AGENT=1 %s\n' "$name" "$name" >&2
fi
exit 2
