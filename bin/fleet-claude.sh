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
#
# Since issue #547 it is also the AGENT switch: FLEET_AGENT=codex (or a caller's
# `--agent codex`) execs bin/fleet-codex.sh instead — see the dispatch block below.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"     # also sources the sibling global fleet.conf
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"   # kept for a lib-less install
_fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings"; [ -f "$_fs" ] && . "$_fs"   # the login's settings win (#979)

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
  # A holding session uses the owning fleet's overlay before it is claimed.
  if [ -n "${FLEET_LAUNCH_SESSION:-}" ] && [ "$_fc_sess" = "${FLEET_LAUNCH_SESSION}-pool" ]; then
    _fc_sess="$FLEET_LAUNCH_SESSION"
  fi
  [ -n "$_fc_sess" ] && fleet_load_conf "$_fc_sess"
  unset _fc_sess
fi

# Agent CLI dispatch (issue #547). FLEET_AGENT — per-fleet overlay ▸ global ▸
# `claude` — picks which agent a spawned session runs; a caller's `--agent <a>`
# (dash-issue-session.sh / dash-raw-session.sh `--agent` — scripts and selftests;
# the dash prompt line has no agent prefix since #559) wins over the conf, the
# rule --model already follows. The flag
# is OURS: consumed here, never passed on. `codex` hands the whole launch to the
# sibling bin/fleet-codex.sh — nothing below (model alias + cap fallback, MCP
# allowlist, subagent model, OAuth token) applies to Codex. Anything else — unset,
# empty, `claude` — falls through to the unchanged Claude path, so a default
# fleet's argv is byte-for-byte what it was.
#
# A resume-shaped launch is ALWAYS Claude unless the caller said `--agent`
# explicitly: --resume / --continue / --from-pr / --fork-session (fleet-restore,
# fleet-migrate, dash-restore-session) resume a CLAUDE transcript, and --model is
# only ever passed by those same Claude-side callers (migrate's fresh-launch
# fallback) — a fleet that flipped to codex must still bring its earlier Claude
# sessions back, and a Claude model alias must never reach `codex -m`.
_fc_agent="${FLEET_AGENT:-}"; _fc_explicit=0
_fc_args=(); _fc_want=0
for _fc_a in "$@"; do
  if [ "$_fc_want" = 1 ]; then _fc_agent="$_fc_a"; _fc_explicit=1; _fc_want=0; continue; fi
  case "$_fc_a" in
    --agent)   _fc_want=1 ;;
    --agent=*) _fc_agent="${_fc_a#--agent=}"; _fc_explicit=1 ;;
    *)         _fc_args+=("$_fc_a") ;;
  esac
done
set -- ${_fc_args[@]+"${_fc_args[@]}"}
if [ "$_fc_explicit" != 1 ]; then
  case " $* " in
    *" --resume "*|*" --continue "*|*" --from-pr "*|*" --fork-session "*|*" --model "*|*" --model="*) _fc_agent=claude ;;
  esac
fi
# Opted-in fresh launches use the same strict subscription planner as recovery.
# Native resume/model-specific calls retain their explicit provider contract.
if [ "${FLEET_FAILOVER:-0}" = 1 ] && [ "${FLEET_ACCOUNT_SELECTED:-0}" != 1 ] \
  && [ -z "${FLEET_HANDOFF_MANIFEST:-}" ]; then
  case " $* " in
    *" --resume "*|*" --continue "*|*" --from-pr "*|*" --fork-session "*|*" resume "*|*" fork "*|*" --codex-home "*|*" --codex-profile "*) : ;;
    *) export FLEET_FAILOVER FLEET_FAILOVER_AGENTS FLEET_MODEL
       exec bash "$BIN/fleet-account.sh" launch --agent "${_fc_agent:-claude}" -- "$@" ;;
  esac
fi
case "$_fc_agent" in
  codex)     exec "$BIN/fleet-codex.sh" "$@" ;;
  ''|claude) : ;;
  *) printf 'fleet-claude: unknown agent %s (FLEET_AGENT / --agent must be claude|codex) — launching claude\n' "$_fc_agent" >&2 ;;
esac
unset _fc_agent _fc_explicit _fc_args _fc_want _fc_a

# --- project trust: pre-answer "trust this folder?" for THIS fleet's checkout ---
# (issue #563). Claude Code keys trust on the resolved project root — a linked
# worktree resolves to its MAIN checkout — with an exact lookup in ~/.claude.json
# (`projects[<root>].hasTrustDialogAccepted`). When that entry is missing or
# false for $FLEET_MAIN, EVERY spawned worker stops at "Quick safety check: Is this
# a project you created or one you trust?" and, with nobody in the pane, sits
# there for good — on 2026-09-12 two autofill-dispatched workers on the macmini did
# exactly that for 7+ minutes while the dispatcher counted their slots as filled.
# So the single door every spawn walks through writes the trust itself, scoped:
# bin/fleet-trust.sh grants ONLY the base checkout and worktrees OF it (this cwd,
# when it is one), atomically (temp + rename, compare-and-swap against a claude
# process saving its own state at the same instant). Not a --dangerously-* flag:
# the dialog stays per-directory; we answer it for our own directories only.
# Best-effort: no python3 / no FLEET_MAIN / a cwd that is not ours → skip quietly;
# claude is still the authority. FLEET_PRETRUST=0 opts a fleet out.
if [ "${FLEET_PRETRUST:-1}" != 0 ] && [ -n "${FLEET_MAIN:-}" ] && [ -f "$BIN/fleet-trust.sh" ]; then
  _fc_granted=$(sh "$BIN/fleet-trust.sh" grant --main "$FLEET_MAIN" "$PWD" 2>"${TMPDIR:-/tmp}/.fleet-trust.$$")
  _fc_rc=$?
  if [ -n "$_fc_granted" ]; then
    printf 'fleet-claude: pre-trusted %s in %s (issue #563)\n' "$(printf '%s' "$_fc_granted" | tr '\n' ' ')" "$(sh "$BIN/fleet-trust.sh" file)" >&2
  fi
  # 3 = a refused path (a cwd outside this fleet's checkout — expected for a plain
  # launch from elsewhere), 2 = no python3: both silent. Anything else is a real
  # write failure the pane should show before claude clears the screen.
  case "$_fc_rc" in 0|2|3) : ;; *) cat "${TMPDIR:-/tmp}/.fleet-trust.$$" >&2 ;; esac
  rm -f "${TMPDIR:-/tmp}/.fleet-trust.$$"
  unset _fc_granted _fc_rc
fi

# Default spawned sessions to opus (never let a new window fall back to sonnet).
# Overridable per install/fleet via FLEET_MODEL in fleet.conf; set it empty to
# defer to the user's own `claude` default. Skipped if the caller already passed
# an explicit --model (so an intentional override still wins).
#
# Per-MODEL cap fallback (issue #524). "You've hit your Fable 5 limit · resets Sep 6"
# walls ONE model on ONE account while the subscription keeps its 5h/7d headroom;
# fleet-account.sh records that per (account, model) — `model-limited-until`,
# stamped by the collector off the banner — and this launcher, the single door
# every spawn / restore / migrate walks through, swaps FLEET_MODEL for
# FLEET_MODEL_FALLBACK (default opus) while the cap holds. So autofill and hand
# spawns stop dying at their first turn, and once the cap resets new sessions are
# back on FLEET_MODEL with nobody flipping a switch. Same rules as --model: an
# explicit caller --model wins, an empty knob disables it, and a fallback equal
# to FLEET_MODEL is a no-op (the cap IS the fallback — nothing to swap to). The
# active account is resolved here (the token export below reuses it).
label="${FLEET_ACCOUNT_LABEL:-}"
[ -n "$label" ] || label=$("$BIN/fleet-account.sh" active 2>/dev/null)
model_flag=()
launch_model=""
if [ -z "${FLEET_MODEL+x}" ]; then FLEET_MODEL="opus"; fi
if [ -z "${FLEET_MODEL_FALLBACK+x}" ]; then FLEET_MODEL_FALLBACK="opus"; fi
if [ -n "$FLEET_MODEL" ]; then
  case " $* " in
    *" --model "*|*" --model="*) : ;;               # caller already chose a model
    *)
      launch_model="$FLEET_MODEL"
      if [ -n "$label" ] && [ -n "$FLEET_MODEL_FALLBACK" ] && [ "$FLEET_MODEL_FALLBACK" != "$FLEET_MODEL" ]; then
        _fc_until=$("$BIN/fleet-account.sh" model-limited-until "$label" "$FLEET_MODEL" 2>/dev/null)
        case "$_fc_until" in ''|*[!0-9]*) _fc_until=0 ;; esac
        [ "$_fc_until" -gt "$(date +%s)" ] && launch_model="$FLEET_MODEL_FALLBACK"
        unset _fc_until
      fi
      model_flag=(--model "$launch_model") ;;
  esac
fi
# The effective model, stamped so the dash / migrate can see what a pane runs.
if [ -n "$launch_model" ] && [ -n "${TMUX_PANE:-}" ]; then
  tmux set-option -w -t "$TMUX_PANE" @cc_model "$launch_model" 2>/dev/null || true
fi

# Force the session's SUBAGENTS (Task/Agent spawns) onto the same tier — this is
# the only global knob for subagent models (no settings.json key exists), and it
# overrides even the pinned built-ins (claude-code-guide=haiku, statusline=sonnet).
# Defaults to FLEET_MODEL; set FLEET_SUBAGENT_MODEL=inherit in fleet.conf to let
# each subagent resolve normally, or empty to not touch it at all.
# Subagents follow the EFFECTIVE model (a Fable-capped launch on opus must not spawn
# Fable subagents that die at their first turn); an explicit FLEET_SUBAGENT_MODEL wins.
if [ -z "${FLEET_SUBAGENT_MODEL+x}" ]; then FLEET_SUBAGENT_MODEL="${launch_model:-$FLEET_MODEL}"; fi
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

if [ -n "$label" ]; then                                 # (resolved above, with the model)
  tok=$("$BIN/fleet-account.sh" token "$label" 2>/dev/null)
  if [ -n "$tok" ]; then
    if [ -n "${FLEET_ACCOUNT_TARGET:-}" ]; then
      unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
      unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
    fi
    export CLAUDE_CODE_OAUTH_TOKEN="$tok"
    # Stamp THIS pane's window (issue #511). An untargeted `set-option -w` resolves
    # to the session's CURRENT window, and every spawn is `new-window -d` (the hub
    # stays current on purpose) — so the label used to land on the hub while the
    # worker stayed unstamped, invisible to the collector's banner attribution.
    # No $TMUX_PANE (launched outside tmux) → nothing to stamp.
    if [ -n "${TMUX_PANE:-}" ]; then
      tmux set-option -w -t "$TMUX_PANE" @cc_account "$label" 2>/dev/null || true
      if [ -n "${FLEET_ACCOUNT_TARGET:-}" ]; then
        _fc_binding=$(FLEET_BIND_OWNER="$$" python3 - <<'PY'
import json, os
p = json.loads(os.environ['FLEET_ACCOUNT_TARGET'])
p['owner'] = os.environ['FLEET_BIND_OWNER']
print(json.dumps(p))
PY
)
        tmux set-option -w -t "$TMUX_PANE" @subscription_identity "$_fc_binding" 2>/dev/null || true
      fi
    fi
  elif [ -n "${FLEET_ACCOUNT_LABEL:-}" ]; then
    echo 'fleet-claude: pinned subscription is unavailable; refusing an ambient login fallback' >&2
    exit 1
  fi
fi

if [ -n "${FLEET_LOOP_SPEC:-}" ] && [ "${FLEET_LOOP_AGENT:-}" = claude ]; then
  exec python3 "$BIN/fleet-loop.py" bridge -- claude ${model_flag[@]+"${model_flag[@]}"} ${mcp_flag[@]+"${mcp_flag[@]}"} "$@"
fi
exec claude ${model_flag[@]+"${model_flag[@]}"} ${mcp_flag[@]+"${mcp_flag[@]}"} "$@"
