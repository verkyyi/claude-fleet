#!/bin/bash
# dash-agent-toggle.sh — the ⌃v handler for the dash (issue #554): flip THIS
# fleet's default agent for NEW sessions between claude and codex, persisted.
#
# Called from an fzf `transform` bind. It flips FLEET_AGENT in the fleet's own
# conf through the SAME write path the prefix+c config modal uses
# (bin/dash-config-edit.sh → fleet-config-lib.sh: fcfg_validate + fcfg_write —
# @scope=fleet, @edit=enum, backup-first, atomic temp+rename, other keys kept
# verbatim; never a sed over the file), then emits the fzf actions that relabel
# the prompt line at once (bin/dash-agent-prompt.sh actions) and toasts one line
# (`fleet: new sessions → codex`). Because it is the REAL conf that changed, every
# spawn path follows — the dash prompt line, ⌃s, dash-issue-session.sh, autofill /
# dispatch, other sessions' scripts — and the dash shows the truth. This key,
# prefix+c and the conf are the ONLY ways to pick the agent (issue #559 retired the
# `codex:` / `claude:` prompt-line prefix); `--agent` on the CLI spawners stays for
# scripts.
#
# Flip table (the effective value, same ladder as the prompt): claude / unset →
# codex; codex → claude; an UNKNOWN value → claude (the only state the launcher
# would not already be falling back to). Outside a fleet (no session ⇒ no per-fleet
# conf) it toasts and changes nothing. While a rename/bind is armed on the query
# line it is a no-op — a fleet-wide flip mid-edit is never what was meant.
#
# The key is ⌃v BY DEFAULT (issue #556 — it was ⌃a, which is the operator's tmux
# prefix, so tmux ate it): the dash resolves it through bin/dash-keymap.sh at
# launch (the ⌥ fallback when ⌃v IS the prefix), and the toast below asks the
# same resolver for the glyph so it never tells the operator to press a dead key.
#
# Prints nothing (⇒ no fzf action) on every refusal; the toast carries the why.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
C="${TMPDIR:-/tmp}/.claude-dash"

[ -f "$C/rename_target" ] || [ -f "$C/bind_target" ] && exit 0

# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-config-lib.sh"
# shellcheck source=/dev/null
. "$BIN/fleet-ui-lang.sh"

sess="${FLEET_SESSION:-}"
[ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
if [ -z "$sess" ]; then
  tmux display-message "$(fleet_ui_t agent_no_fleet)" 2>/dev/null || true
  exit 0
fi
[ -n "$sess" ] && fleet_load_conf "$sess"

cur=$(bash "$BIN/dash-agent-prompt.sh" agent 2>/dev/null)
case "$cur" in
  ''|claude) new=codex  ;;
  *)         new=claude ;;   # codex → claude; unknown → claude
esac

target=$(fcfg_target_conf "$sess" fleet)
if ! reason=$(fcfg_validate enum "$new" FLEET_AGENT); then
  msg=$(fleet_ui_t agent_not_flipped_fmt "$reason")
  tmux display-message "$msg" 2>/dev/null || true
  exit 0
fi
if ! fcfg_write "$target" FLEET_AGENT "$new" enum >/dev/null; then
  msg=$(fleet_ui_t agent_write_failed_fmt "${target##*/}")
  tmux display-message "$msg" 2>/dev/null || true
  exit 0
fi
glyph=$(bash "$BIN/dash-keymap.sh" glyph agent 2>/dev/null); [ -n "$glyph" ] || glyph='⌃v'
msg=$(fleet_ui_t agent_flipped_fmt "$new" "$glyph")
tmux display-message "$msg" 2>/dev/null || true
bash "$BIN/dash-agent-prompt.sh" actions
