#!/bin/bash
# dash-agent-prompt.sh [agent|prompt|ghost|actions] — the ONE derivation of the
# dash prompt line's agent label (issue #554).
#
# Since #547 a fleet spawns its workers on Claude Code or OpenAI Codex CLI
# (FLEET_AGENT), and nothing on the dash said which one a NEW session would get.
# Now the always-visible prompt line carries it: `claude ▸ ` / `codex ▸ `, resolved
# from the fleet's EFFECTIVE FLEET_AGENT by the SAME ladder every spawn path walks
# (bin/fleet-claude.sh): global fleet.conf → this fleet's overlay (fleet_load_conf)
# → `claude` when unset/empty. `codex` is drawn in the colour the row tag from #547
# uses (bin/tmux-dashboard-rows.sh IN), `claude` stays in the prompt's own colour,
# and an UNKNOWN value renders as-is in red (the launcher warns + falls back to
# claude for it; the dash must not crash on it). The ghost text is ONE short line
# (iPad height, #534/#536) saying what ↵ does and which key flips the agent:
# `↵ 新开空 scratch · 切换 agent: ⌃v` (issue #559 — the `<agent>:` one-off prefix
# hint it carried from #554 is gone with the prefix itself; the toggle key is the
# one way to pick the agent from the dash).
#
# The key in the ghost is NEVER a literal: it is the key the dash ACTUALLY bound —
# bin/dash-keymap.sh resolves every ⌃-chord against the tmux prefix at launch
# (issue #556; ⌃v moves to ⌥v when ⌃v IS the prefix). tmux-dashboard.sh exports
# that launch-time resolution as DASH_GLYPH_AGENT, so the launch `--ghost`, every
# `load`/⌃r tick and the toggle's `change-ghost` (all run under the dash's env)
# name the SAME key the fzf bind holds — and a prefix changed mid-dash can't make
# the ghost drift from the bind. Off the dash (no env: selftests, a hand run) it
# asks the resolver directly, the way the toast (dash-agent-toggle.sh) and the `?`
# sheet (fleet-keys.sh `dg`) do; last resort the ⌃v default.
#
# Modes (stdout):
#   agent    the effective agent token (claude | codex | <whatever the conf says>)
#   prompt   the fzf --prompt string (ANSI inside; fzf renders colour in a prompt)
#   ghost    the fzf --ghost string
#   actions  `change-prompt(<prompt>)+change-ghost(<ghost>)` — for an fzf `transform`
#            bind. Prints NOTHING while a rename/bind is armed (dash-rename.sh's
#            `rename ▸ ` owns the prompt then; the 1Hz `load` tick must not clobber
#            it — dash-enter.sh/dash-esc.sh restore through `prompt` when it ends).
#
# One script, three callers, so the initial launch (`--prompt=$(… prompt)`), the
# reload ticks (`load` / ⌃r → transform(… actions)) and the mode restores can never
# disagree: any writer changing FLEET_AGENT — ⌃v (dash-agent-toggle.sh), the
# prefix+c config modal, a hand edit of the conf — shows on the next tick.
#
# NB: the values go INSIDE fzf `change-prompt(…)` — fzf stops at the FIRST ')' — so
# parens/newlines are stripped from a conf value before it is rendered.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
mode="${1:-actions}"
C="${TMPDIR:-/tmp}/.claude-dash"

# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
sess="${FLEET_SESSION:-}"
[ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
[ -n "$sess" ] && fleet_load_conf "$sess"
agent="${FLEET_AGENT:-claude}"
agent=${agent//[()]/}; agent=${agent//[$'\n\r']/}
[ -n "$agent" ] || agent=claude

E=$'\033['; R="${E}0m"
IN="${E}38;2;187;154;247m"   # = the #547 agent row tag colour (tmux-dashboard-rows.sh)
RD="${E}38;2;247;118;142m"   # unknown value: visibly wrong, the launcher falls back to claude
case "$agent" in
  claude) label="claude" ;;
  codex)  label="${IN}codex${R}" ;;
  *)      label="${RD}${agent}${R}" ;;
esac
prompt="${label} ▸ "
glyph="${DASH_GLYPH_AGENT:-}"
[ -n "$glyph" ] || glyph=$(bash "$BIN/dash-keymap.sh" glyph agent 2>/dev/null)
[ -n "$glyph" ] || glyph='⌃v'
glyph=${glyph//[()]/}; glyph=${glyph//[$'\n\r']/}   # goes inside change-ghost(…) too
ghost="↵ 新开空 scratch · 切换 agent: ${glyph}"

case "$mode" in
  agent)  printf '%s\n' "$agent" ;;
  prompt) printf '%s\n' "$prompt" ;;
  ghost)  printf '%s\n' "$ghost" ;;
  actions)
    # a rename/bind in progress owns the prompt line — emit nothing (no fzf action).
    [ -f "$C/rename_target" ] || [ -f "$C/bind_target" ] && exit 0
    printf 'change-prompt(%s)+change-ghost(%s)\n' "$prompt" "$ghost" ;;
  *) printf 'dash-agent-prompt: unknown mode %s (agent|prompt|ghost|actions)\n' "$mode" >&2; exit 2 ;;
esac
exit 0
