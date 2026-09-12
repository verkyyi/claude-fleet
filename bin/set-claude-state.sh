#!/bin/sh
# set-claude-state.sh <state> [bell]
# Stamps the current tmux window's @claude_state (semantic: working|done|needs).
# The tmux-spinner.sh daemon reads @claude_state and renders ALL the visuals
# (spinner glyph + its pulsing font color + name color) via @spin, so this hook
# only sets the semantic state and (for needs) rings the bell.
# Registered as a Claude Code hook (see hooks/settings-hooks.json).
# Always exits 0 so it never blocks a turn.
set -u  # POSIX sh: pipefail is bash-only (dash has none)
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0
# A HEADLESS claude is NOT this pane's session (issue #571). A `claude -p` helper —
# the Stop-hook classifier (bin/classify-sessions.sh), or any headless claude a
# worker spawns from its Bash tool — inherits the pane's TMUX/TMUX_PANE *and* the
# global hooks, so its own Stop landed here: it flipped the pane's @claude_state,
# and (worse) read the PANE's @ctx_pct, got the auto-handoff block decision meant
# for the TUI, ran /fleet-handoff on ITSELF and /clear-ed the operator's pane —
# 16 cycles in one day, several under the operator's fingers. Claude Code marks
# the entrypoint in the environment its hooks inherit: `cli` for the interactive
# TUI, `sdk-cli` for `-p` (verified on 2.1.269). Only the TUI owns the pane;
# anything else touches nothing. Unset (an older CLI, the selftests' `env -i`) ⇒ TUI.
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) : ;; *) exit 0 ;; esac

handoff_prev=''   # prior @claude_state, captured in the done branch (issue #330)

case "${1:-}" in
  needs)
    # The Notification hook fires this path unconditionally, but Claude Code emits
    # a benign idle_prompt Notification ("Claude is waiting for your input") ~60s
    # after ANY session goes idle. Left unfiltered it flips every finished session
    # to needs+bell and re-flips the classifier's verdict — cry-wolf. Discriminate
    # on the payload (mirrors the AskUserQuestion stdin-inspection in 'busy'). The
    # payload exposes no structured type field (only `message`), so we substring
    # the wording; if Claude Code rephrases it we fall back to needs+bell — the
    # safe direction (an idle session rings, not a real prompt silently missed).
    # A benign idle prompt -> 'leave': DON'T write state, just drop the bell, so
    # whatever the Stop-hook classifier decided (done for finished, needs for a
    # real pending question) stays authoritative. A real permission/elicitation
    # prompt (and anything unrecognised) keeps needs+bell.
    sem="needs"
    if [ ! -t 0 ]; then
      case "$(cat 2>/dev/null)" in
        *'waiting for your input'*)
          sem="leave"; set -- "leave" ;;   # idle_prompt: leave state as-is, no bell
      esac
    fi
    ;;
  done)
    sem="done"
    # Auto-handoff (issue #330): capture the PRIOR state BEFORE the write below
    # overwrites @claude_state — the nudge must not hijack a pane that stopped in
    # a needs-attention state (an open operator question). Only the Stop hook
    # passes 'done', so this one extra read never touches the per-tool hot path.
    handoff_prev=$(tmux display-message -p -t "$TMUX_PANE" '#{@claude_state}' 2>/dev/null)
    ;;
  busy)
    # PreToolUse heartbeat = working, EXCEPT the AskUserQuestion tool: it opens a
    # blocking multiple-choice popup mid-turn and NO Notification hook fires for it
    # (AskUserQuestion isn't a Notification matcher), so without this the window
    # would masquerade as 'working' the whole time it's really waiting on the user.
    # PreToolUse is the only caller that passes 'busy'; its stdin JSON carries the
    # tool_name. PostToolUse (arg 'working') fires when the user answers -> working.
    sem="working"
    if [ ! -t 0 ]; then
      case "$(cat 2>/dev/null)" in
        *'"tool_name":"AskUserQuestion"'*|*'"tool_name": "AskUserQuestion"'*)
          sem="needs"; set -- needs bell ;;
      esac
    fi
    ;;
  *)     sem="working" ;;   # PostToolUse / prompt submitted
esac

# 'leave' (benign idle_prompt) intentionally writes nothing — it preserves the
# existing @claude_state and its timestamp so the classifier stays authoritative.
if [ "$sem" != "leave" ]; then
  tmux set-window-option -t "$TMUX_PANE" @claude_state "$sem" 2>/dev/null
  # last-activity stamp (drives the dashboard's "Nm ago" column).
  tmux set-window-option -t "$TMUX_PANE" @claude_state_ts "$(date +%s)" 2>/dev/null
fi

# ── Auto-handoff nudge (issue #330) ──────────────────────────────────────────
# At a CLEAN Stop (done), if this session's context has crossed the operator's
# threshold, emit the Stop-hook block decision that steers the model into
# /fleet-handoff (cycle) — a structured handoff preserves task state far better
# than Claude's near-limit auto-compaction. This ONLY adds the trigger; the whole
# handoff/clear/resume machinery (commands/fleet-handoff.md + fleet-handoff-cycle.sh)
# is reused unchanged. Knobs: FLEET_AUTO_HANDOFF_PCT (0 = OFF; mirrors
# FLEET_RUNAWAY_CPU_PCT) and FLEET_HANDOFF_DEFER_SECS (the typing hold, issue #571).
# Only 'done' (the Stop hook) reaches here, so the JSON is only ever emitted in the
# Stop-hook context that parses it as a decision.
#
# THE KNOB IS READ FROM THE CONF, NOT THIS PROCESS'S ENVIRONMENT (issue #561). A
# hook inherits the pane's env, and nothing exports fleet.conf into it (the conf is
# assignments-only; the launcher never `set -a`s it) — so the original
# `${FLEET_AUTO_HANDOFF_PCT:-0}` read here was 0 in every real session while the
# operator's global conf said 60, and all 134 logged handoff cycles were the worker
# nudging itself. Resolution goes through bin/fleet-hook-conf.sh — the ONE
# hook-side path (global fleet.conf → this fleet's overlay via fleet_load_conf,
# global-only keys stripped per #237) that fleet-doctor.sh evaluates too. This
# script is `sh`-wired and cannot source the bash-only fleet-lib itself; the helper
# is the bash hop (≈20 ms, once per Stop — never on the per-tool hot path). Any
# failure (helper/lib missing, no server, no conf) yields '' ⇒ 0 ⇒ OFF: fail-open,
# exactly as before.
if [ "$sem" = "done" ]; then
  _bin=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
  _kv=''
  [ -n "$_bin" ] && [ -f "$_bin/fleet-hook-conf.sh" ] \
    && _kv=$(bash "$_bin/fleet-hook-conf.sh" FLEET_AUTO_HANDOFF_PCT FLEET_HANDOFF_DEFER_SECS 2>/dev/null)
  _hp=$(printf '%s\n' "$_kv" | sed -n 1p)
  _ds=$(printf '%s\n' "$_kv" | sed -n 2p)             # typing-deferral window (issue #571)
  case "$_hp" in ''|*[!0-9]*) _hp=0 ;; esac          # unset / non-numeric → off
  case "$_ds" in ''|*[!0-9]*) _ds=30 ;; esac         # unset / non-numeric → the 30s default
  # Loop-guard: the Stop-hook stdin carries stop_hook_active=true when the model is
  # ALREADY continuing because of a prior Stop-hook block — never re-block that
  # continuation (Claude Code's built-in anti-loop signal, belt-and-suspenders with
  # the @handoff_armed latch below). Read stdin only when armed and not a tty.
  if [ "$_hp" -gt 0 ] && [ ! -t 0 ]; then
    case "$(cat 2>/dev/null)" in
      *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) _hp=0 ;;
    esac
  fi
  if [ "$_hp" -gt 0 ]; then
    # Debounce latch: arming the handoff does NOT drop the context (only the
    # post-turn /clear does), so the very next Stop would re-nudge → loop. Set
    # @handoff_armed on the first nudge and skip while set; the SessionStart hook
    # (bin/handoff-latch-reset-hook.sh) clears it in the fresh, cleared session.
    _armed=$(tmux display-message -p -t "$TMUX_PANE" '#{@handoff_armed}' 2>/dev/null)
    # Scope: only a worker (@issue) or scratch (@raw) pane HAS /fleet-handoff.
    # Panels (dash/plan/backlog) and the operator hub carry neither → never nudged.
    _issue=$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}' 2>/dev/null)
    _raw=$(tmux display-message -p -t "$TMUX_PANE" '#{@raw}' 2>/dev/null)
    # Measure: the statusline (conf/statusline.sh) stamps the rounded context %
    # onto @ctx_pct each render — the Stop-hook stdin doesn't carry it, but the
    # statusline does. Unstamped / non-numeric ⇒ -1 ⇒ never crosses a positive PCT.
    _ctx=$(tmux display-message -p -t "$TMUX_PANE" '#{@ctx_pct}' 2>/dev/null)
    case "$_ctx" in ''|*[!0-9]*) _ctx=-1 ;; esac
    if [ "$_armed" != "1" ] && [ "$handoff_prev" != "needs" ] \
       && { [ -n "$_issue" ] || [ "$_raw" = "1" ]; } \
       && [ "$_ctx" -ge "$_hp" ]; then
      # Operator-typing deferral (issue #571). A handoff cycle Esc+`/clear`s this
      # pane a minute from now; typed into an input line holding a half-written
      # draft, that keeps the draft (a single Esc does not clear it) and submits
      # it with "/clear" glued on, and a queued message dies with the old session.
      # Claude Code hands a hook no draft/queue signal, so the proxy is tmux: a
      # client whose CURRENT window is this one with a keypress (#{client_activity})
      # within FLEET_HANDOFF_DEFER_SECS ⇒ skip THIS Stop — no nudge, no latch (the
      # next Stop re-judges) — and stamp @handoff_deferred_ts so the hold is visible.
      # Ceiling: at threshold+10 the nudge fires anyway, or a long conversation
      # would defer itself straight into autocompact.
      _hold=''
      if [ "$_ds" -gt 0 ] && [ "$_ctx" -lt $(( _hp + 10 )) ]; then
        _wid=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null)
        _now=$(date +%s 2>/dev/null || echo 0)
        [ -n "$_wid" ] && _hold=$(tmux list-clients -F '#{client_activity} #{window_id}' 2>/dev/null \
          | awk -v w="$_wid" -v now="$_now" -v ds="$_ds" \
              '$2 == w && $1 ~ /^[0-9]+$/ && (now - $1) <= ds { print 1; exit }')
      fi
      if [ "$_hold" = "1" ]; then
        tmux set-window-option -t "$TMUX_PANE" @handoff_deferred_ts "$_now" 2>/dev/null
      else
        # Latch FIRST (idempotent) so the next Stop skips, THEN emit the directive.
        tmux set-window-option -t "$TMUX_PANE" @handoff_armed 1 2>/dev/null
        printf '{"decision":"block","reason":"Context is at %s%% (>= %s%% auto-handoff threshold). Run /fleet-handoff now (cycle mode, no arguments): store a durable handoff, then this pane auto-clears and resumes clean. Do this instead of continuing — a structured handoff preserves task state better than near-limit auto-compaction."}\n' "$_ctx" "$_hp"
      fi
    fi
  fi
fi

[ "${2:-}" = "bell" ] && printf '\a' > /dev/tty 2>/dev/null

exit 0
