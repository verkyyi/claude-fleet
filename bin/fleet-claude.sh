#!/bin/bash
# fleet-claude.sh — launch `claude` under the fleet's currently-active
# subscription account, then hand off with exec. Transparent passthrough when
# no accounts are registered (bin/fleet-account.sh prints nothing) — so the
# spawn scripts can route EVERY session through this without changing behavior
# for single-account installs.
#
# It exports CLAUDE_CODE_OAUTH_TOKEN for the active account and stamps the
# window's @cc_account option with that account's label, so the collector can
# attribute a "hit your … limit" banner back to the right account and rotate.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"     # also sources the sibling global fleet.conf
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"   # kept for a lib-less install

# Per-fleet overlay (issue #472). Until now this script read the GLOBAL fleet.conf
# only — and nothing else carried the per-fleet conf into a spawned window either
# (`tmux new-window`'s command string does not inherit the spawner's shell env, and
# the fleet never set-environments the conf onto its server). So every @scope=fleet
# key that ONLY this script reads was silently inert: two fleets configured
# FLEET_MODEL="fable" and every session they spawned ran `--model opus`, this
# script's default for an unset value — a miss that fails quietly UPWARD, toward the
# most expensive model. fleet_load_conf strips $_FLEET_GLOBAL_ONLY (#237), so global
# still wins where it must; fleet_current_session reads $TMUX_PANE, which is set in
# the spawned pane. No tmux / no conf / no lib → clean no-op, as before.
if command -v fleet_load_conf >/dev/null 2>&1; then
  _fc_sess="$(fleet_current_session 2>/dev/null)"
  [ -n "$_fc_sess" ] && fleet_load_conf "$_fc_sess"
  unset _fc_sess
fi

# Default spawned sessions to opus (never let a new window fall back to sonnet).
# Overridable per install/fleet via FLEET_MODEL in fleet.conf; set it empty to
# defer to the user's own `claude` default. Skipped if the caller already passed
# an explicit --model (so an intentional override still wins).
model_flag=()
if [ -z "${FLEET_MODEL+x}" ]; then FLEET_MODEL="opus"; fi
if [ -n "$FLEET_MODEL" ]; then
  case " $* " in
    *" --model "*|*" --model="*) : ;;               # caller already chose a model
    *) model_flag=(--model "$FLEET_MODEL") ;;
  esac
fi

# Force the session's SUBAGENTS (Task/Agent spawns) onto the same tier — this is
# the only global knob for subagent models (no settings.json key exists), and it
# overrides even the pinned built-ins (claude-code-guide=haiku, statusline=sonnet).
# Defaults to FLEET_MODEL; set FLEET_SUBAGENT_MODEL=inherit in fleet.conf to let
# each subagent resolve normally, or empty to not touch it at all.
if [ -z "${FLEET_SUBAGENT_MODEL+x}" ]; then FLEET_SUBAGENT_MODEL="$FLEET_MODEL"; fi
[ -n "$FLEET_SUBAGENT_MODEL" ] && export CLAUDE_CODE_SUBAGENT_MODEL="$FLEET_SUBAGENT_MODEL"

# MCP allowlist (issue #473). A fleet session boots the operator's ENTIRE MCP set —
# on the machine this was measured on, 13 servers: 5 local stdio (3 resolved through
# npx, one pinned @latest so it hits the registry) plus 8 remote connectors over the
# network. That is ~2s of the ~5s before a new session accepts input, plus 4-5
# resident node children per session. A 30-day census of every mcp__* call across
# 4690 transcripts found ALL of it concentrated in three servers, in one fleet; the
# other fleet made zero MCP calls at all. This lets each fleet pay for what it uses:
#
#   unset/empty  every configured MCP server loads (unchanged — the default)
#   none         no MCP at all
#   <path|json>  ONLY these servers (the CLI takes a file path or inline JSON)
#
# --strict-mcp-config is what drops the REMOTE connectors too, not just local stdio.
# An explicit --mcp-config/--strict-mcp-config from the caller wins, same as --model.
mcp_flag=()
if [ -n "${FLEET_MCP_CONFIG:-}" ]; then
  case " $* " in
    *" --mcp-config "*|*" --mcp-config="*|*" --strict-mcp-config "*) : ;;   # caller already chose
    *)
      _fc_mcp="$FLEET_MCP_CONFIG"
      [ "$_fc_mcp" = none ] && _fc_mcp='{"mcpServers":{}}'
      # --mcp-config=<v>, NOT --mcp-config <v>: the option is VARIADIC
      # (`--mcp-config <configs...>`), so in the separated form it swallows
      # whatever positional follows it. Every issue-bound spawn passes the seed
      # prompt positionally (dash-issue-session.sh: `fleet-claude.sh "$(cat …)"`),
      # so the separated form read the PROMPT as a second config path and every
      # worker died at launch with `MCP config file not found: /fleet-claim`. The
      # =form binds the value to the flag and cannot reach past it, whatever
      # follows. Do not "tidy" it back into two words.
      mcp_flag=(--strict-mcp-config "--mcp-config=$_fc_mcp")
      unset _fc_mcp
      ;;
  esac
fi

label=$("$BIN/fleet-account.sh" active 2>/dev/null)
if [ -n "$label" ]; then
  tok=$("$BIN/fleet-account.sh" token "$label" 2>/dev/null)
  if [ -n "$tok" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$tok"
    tmux set-option -w @cc_account "$label" 2>/dev/null || true
  fi
fi

exec claude ${model_flag[@]+"${model_flag[@]}"} ${mcp_flag[@]+"${mcp_flag[@]}"} "$@"
