#!/bin/bash
# fleet-claude.sh — launch `claude` for a fleet session, then hand off with exec.
#
# It never chooses a subscription (T550, EPIC T542 C4): through this login's
# credential proxy (FLEET_CRED_SID) the pool picks one per request; otherwise the
# session runs on this login's own Claude login, exactly as with no accounts/ at
# all. The one exception is a caller that already NAMED the account — a migrate or
# a handoff carrying a session over (FLEET_ACCOUNT_LABEL): that account's token is
# exported and the window's @cc_account says so.
#
# Since issue #547 it is also the AGENT switch: FLEET_AGENT=codex (or a caller's
# `--agent codex`) execs bin/fleet-codex.sh instead — see the dispatch block below.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# The steps both agents share — the configuration (the global conf, the login's,
# the per-fleet overlay #472), trust, the tool service, the composed configuration,
# the session credential — are bin/fleet-launch-lib.sh's (T620, EPIC T580 C4); what
# the agents really differ in is the adapter table it reads (fleet_agent_adapter.py).
LAUNCH_AGENT=claude
_fl_lib="$BIN/fleet-launch-lib.sh"   # beside this script, else beside its link's target
[ -f "$_fl_lib" ] || _fl_lib="$(cd "$BIN" && cd "$(dirname "$(readlink "$0")")" && pwd)/fleet-launch-lib.sh"
# shellcheck source=/dev/null
. "$_fl_lib"

# The account CLASS (issue #1540) chose among this login's accounts — gone with the
# pick (T550): the class only ever narrowed `fleet-account.sh active`. An older
# window's @account_class changes nothing here.
unset FLEET_ACCOUNT_CLASS

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
#
# `--as <name>` (issue #3122, EPIC #3111 C11) is OURS too: the standard agent
# file this session starts as — `claude --agent <name>` (bin/fleet-agent-def.py
# finds it the way Claude Code does: project .claude/agents > ~/.claude/agents >
# a plugin). Consumed here, handed on through a failover re-entry; a Codex launch
# reads the same file (body → its instructions, `fleet.codex_model` → -m).
_fc_agent="${FLEET_AGENT:-}"; _fc_explicit=0; _fc_as=''
_fc_args=(); _fc_want=''
for _fc_a in "$@"; do
  if [ "$_fc_want" = agent ]; then _fc_agent="$_fc_a"; _fc_explicit=1; _fc_want=''; continue; fi
  if [ "$_fc_want" = as ]; then _fc_as="$_fc_a"; _fc_want=''; continue; fi
  case "$_fc_a" in
    --agent)   _fc_want=agent ;;
    --agent=*) _fc_agent="${_fc_a#--agent=}"; _fc_explicit=1 ;;
    --as)      _fc_want=as ;;
    --as=*)    _fc_as="${_fc_a#--as=}" ;;
    *)         _fc_args+=("$_fc_a") ;;
  esac
done
set -- ${_fc_args[@]+"${_fc_args[@]}"}
if [ "$_fc_explicit" != 1 ]; then
  case " $* " in
    *" --resume "*|*" --continue "*|*" --from-pr "*|*" --fork-session "*|*" --model "*|*" --model="*) _fc_agent=claude ;;
  esac
  # a DeepSeek profile (task J7BN) is Claude Code on DeepSeek's Anthropic API:
  # FLEET_MODEL=deepseek|deepseek-pro picks Claude even on a FLEET_AGENT=codex fleet
  case "$(printf '%s' "${FLEET_MODEL:-}" | tr '[:upper:]' '[:lower:]')" in
    deepseek|deepseek-pro) _fc_agent=claude ;;
  esac
fi
# A SEPARATED login (credsep.json, #1971) through its credential proxy does not
# choose its subscription (issue #2412): the session credential names no account
# and the proxy picks one per request, moving it when it fills — so no @cc_account
# here, not even a caller-named one.
_fc_sep=0
# …and so does a person's own pod (render.py --cred-central): no credsep.json, and
# nothing is ever leased into it (node.env CCQUOTA_FLEET_CREDS=0) — the hub's
# central proxy picks, there is nothing here to plan over (#3554)
[ -n "${FLEET_CRED_SID:-}" ] && { [ -f "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/credsep.json" ] \
  || { [ -n "${FLEET_CRED_CENTRAL_URL:-}" ] && command -v _fleet_node_env_val >/dev/null 2>&1 \
       && [ "$(_fleet_node_env_val CCQUOTA_FLEET_CREDS 2>/dev/null)" = 0 ]; }; } && _fc_sep=1
# The agent file's launch (`fleet-agent-def.py launch`, key TAB value): its sha,
# model and spawn grant, and the argv words it adds. A file gone since the spawn
# looked opens a plain session and says so — never no session at all.
_fc_as_sha=''; _fc_as_model=''; _fc_as_spawn=0; as_flag=()
fleet_as_resolve() {   # <claude|codex> [--no-agent-flag]
  _fc_as_sha=''; _fc_as_model=''; _fc_as_spawn=0; as_flag=()
  [ -n "$_fc_as" ] || return 0
  local k v out rc
  out=$(python3 "$BIN/fleet-agent-def.py" launch "$_fc_as" --agent "$@" 2>&1) || {
    rc=$?
    if [ "$rc" = 3 ]; then printf 'fleet-claude: %s\n' "${out##*fleet-agent-def: }" >&2; exit 3; fi
    printf 'fleet-claude: %s — starting a plain session\n' "${out##*fleet-agent-def: }" >&2; return 1; }
  while IFS=$'\t' read -r k v; do
    case "$k" in
      sha) _fc_as_sha="$v" ;; model) _fc_as_model="$v" ;; spawn) _fc_as_spawn="$v" ;;
      arg) as_flag+=("$v") ;;
    esac
  done <<EOF
$out
EOF
}
fleet_as_stamp() {
  [ -n "$_fc_as_sha" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  tmux set-option -w -t "$TMUX_PANE" @agent_def "$_fc_as" \; \
    set-option -w -t "$TMUX_PANE" @agent_def_sha "$_fc_as_sha" \; \
    set-option -w -t "$TMUX_PANE" @agent_spawn "$_fc_as_spawn" 2>/dev/null || true
}
# The one door: any agent the table has but Claude runs its own launcher.
if [ -n "$_fc_agent" ] && ! fleet_agent_known "$_fc_agent"; then
  printf 'fleet-claude: unknown agent %s (FLEET_AGENT / --agent must be %s) — launching claude\n' "$_fc_agent" "$(printf '%s' "$FLEET_AGENTS" | tr ' ' '|')" >&2
elif [ -n "$_fc_agent" ] && [ "$_fc_agent" != "$LAUNCH_AGENT" ]; then
  fleet_as_resolve "$_fc_agent"; fleet_as_stamp
  exec "$BIN/$(fleet_agent_get "$_fc_agent" launcher)" ${as_flag[@]+"${as_flag[@]}"} "$@"
fi
unset _fc_agent _fc_explicit _fc_args _fc_want _fc_a

# DeepSeek (task J7BN, P0): FLEET_MODEL (or a carried-over `--model`) deepseek /
# deepseek-pro is a MODEL PROFILE, not a Claude model name. Claude Code talks to
# DeepSeek's Anthropic-compatible API through this login's credential proxy, at
# /deepseek on its port — the proxy's ONE road for it is the cluster's central
# proxy with this session's hub pass (no machine holds the key). So it needs the
# proxy (FLEET_CRED_SID): without it the launch refuses rather than quietly run
# on an Anthropic account. No --model reaches claude; the account cap, a named
# account and the subscription pick play no part.
fleet_ds_profile() {   # <model> → deepseek | deepseek-pro, rc 1 = not a DeepSeek profile
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    deepseek)     printf deepseek ;;
    deepseek-pro) printf deepseek-pro ;;
    *) return 1 ;;
  esac
}
_fc_ds=''; _fc_args=(); _fc_want=''
for _fc_a in "$@"; do      # a caller's --model deepseek* (a migrate carrying @cc_model): ours
  if [ "$_fc_want" = model ]; then
    _fc_want=''
    if _fc_p=$(fleet_ds_profile "$_fc_a"); then _fc_ds="$_fc_p"; continue; fi
    _fc_args+=(--model "$_fc_a"); continue
  fi
  case "$_fc_a" in
    --model) _fc_want=model ;;
    --model=*) if _fc_p=$(fleet_ds_profile "${_fc_a#--model=}"); then _fc_ds="$_fc_p"; else _fc_args+=("$_fc_a"); fi ;;
    *) _fc_args+=("$_fc_a") ;;
  esac
done
[ "$_fc_want" = model ] && _fc_args+=(--model)
set -- ${_fc_args[@]+"${_fc_args[@]}"}
[ -z "$_fc_ds" ] && [ -n "${FLEET_MODEL:-}" ] && _fc_ds=$(fleet_ds_profile "$FLEET_MODEL")
unset _fc_args _fc_want _fc_a _fc_p
fleet_ds_need_proxy() {
  [ -n "$_fc_ds" ] && [ -z "${FLEET_CRED_SID:-}" ] || return 0
  printf 'fleet-claude: FLEET_MODEL=%s runs only through the credential proxy (FLEET_CRED_PROXY=1) — no DeepSeek key exists on this machine; refusing to start\n' "$_fc_ds" >&2
  fleet_launch_refused deepseek; exit 1
}
fleet_ds_need_proxy
[ -n "$_fc_ds" ] && _fc_sep=1   # no account of this login is named, picked or exported

# The slow steps start now, beside everything below (T683, a cold start ≤ 5 s): the
# session credential's mint and the folder trust — fleet_launch_early (the lib); the
# mint further down reads its pipe, fleet_launch_settle waits for both before the exec.
_fc_label="${FLEET_ACCOUNT_LABEL:-}"; [ "$_fc_sep" = 1 ] && _fc_label=''
if [ -n "$_fc_ds" ]; then fleet_launch_early --provider deepseek
else fleet_launch_early ${_fc_label:+--account "$_fc_label"}; fi
unset _fc_label

# The agent file's model is this launch's FLEET_MODEL default (issue #3122) — the
# per-model cap, the subagent tier and @cc_model below go on as they always did,
# and a fleet's FLEET_MODEL still wins; Claude Code reads the rest (tools, body)
# off the file itself. No --as: opus, byte for byte as before.
fleet_as_resolve claude
if [ -z "${FLEET_MODEL+x}" ]; then
  FLEET_MODEL="${_fc_as_model:-opus}"
  # an agent file whose model is a DeepSeek profile: the early mint asked for
  # Claude — drop its pipe, the mint below asks again for deepseek
  if [ -z "$_fc_ds" ] && _fc_p=$(fleet_ds_profile "$FLEET_MODEL"); then
    _fc_ds="$_fc_p"; fleet_ds_need_proxy; _fc_sep=1
    [ "$_fl_mint_early" = 1 ] && { exec 7<&-; _fl_mint_early=0; }
  fi
  unset _fc_p
fi
fleet_as_stamp

# Project trust (issue #563; a trusted node's wide form, #2282): every spawn, restore,
# migrate and wake walks through this door, so it answers "trust this folder?" for the
# fleet's own directories — fleet_launch_trust (the lib), started early (above) and
# waited for by fleet_launch_settle before the exec (which runs it in place when
# FLEET_LAUNCH_EARLY=0).

# Default spawned sessions to opus (never let a new window fall back to sonnet).
# Overridable per install/fleet via FLEET_MODEL in fleet.conf; set it empty to
# defer to the user's own `claude` default. Skipped if the caller already passed
# an explicit --model (so an intentional override still wins).
#
# The account: only one a caller NAMED (a migrate / handoff carrying a session over,
# FLEET_ACCOUNT_LABEL) — never a pick among this login's accounts (T550, EPIC T542
# C4). The pool picks behind the credential proxy; with no proxy the session runs
# on this login's own login, as with no accounts/ at all.
label="${FLEET_ACCOUNT_LABEL:-}"
[ "$_fc_sep" = 1 ] && label=''      # the proxy picks (issue #2412)
model_flag=()
launch_model=""
if [ -n "$_fc_ds" ]; then
  : # a DeepSeek profile: the model rides ANTHROPIC_MODEL & co. (below), never --model
elif [ -n "$FLEET_MODEL" ]; then
  case " $* " in
    *" --model "*|*" --model="*) : ;;               # caller already chose a model
    *)
      launch_model="$FLEET_MODEL"
      model_flag=(--model "$launch_model") ;;
  esac
fi
# The agent this window runs (T493): every Claude launch says so itself — a
# restore, a move, a resume or a window someone opened by hand — so no list
# reads Claude off a blank @cc_agent (fleet-codex.sh stamps codex the same way).
[ -n "${TMUX_PANE:-}" ] && tmux set-option -w -t "$TMUX_PANE" @cc_agent claude 2>/dev/null || true
# The effective model, stamped so the dash / migrate can see what a pane runs.
if [ -n "${launch_model:-$_fc_ds}" ] && [ -n "${TMUX_PANE:-}" ]; then
  tmux set-option -w -t "$TMUX_PANE" @cc_model "${launch_model:-$_fc_ds}" 2>/dev/null || true
fi

# Force the session's SUBAGENTS (Task/Agent spawns) onto the same tier — this is
# the only global knob for subagent models (no settings.json key exists), and it
# overrides even the pinned built-ins (claude-code-guide=haiku, statusline=sonnet).
# Defaults to FLEET_MODEL; set FLEET_SUBAGENT_MODEL=inherit in fleet.conf to let
# each subagent resolve normally, or empty to not touch it at all.
# Subagents follow the EFFECTIVE model; an explicit FLEET_SUBAGENT_MODEL wins.
if [ -z "${FLEET_SUBAGENT_MODEL+x}" ]; then FLEET_SUBAGENT_MODEL="${launch_model:-$FLEET_MODEL}"; fi
[ -n "$FLEET_SUBAGENT_MODEL" ] && export CLAUDE_CODE_SUBAGENT_MODEL="$FLEET_SUBAGENT_MODEL"
# DeepSeek (task J7BN): every tier is a DeepSeek model — a Claude alias (opus, an
# agent file's sonnet) resolves through these, a subagent rides the flash model
if [ -n "$_fc_ds" ]; then
  _fc_dsm='deepseek-flash[1m]'; [ "$_fc_ds" = deepseek-pro ] && _fc_dsm='deepseek-v4-pro[1m]'
  export ANTHROPIC_MODEL="$_fc_dsm" ANTHROPIC_DEFAULT_OPUS_MODEL="$_fc_dsm" ANTHROPIC_DEFAULT_SONNET_MODEL="$_fc_dsm"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-flash CLAUDE_CODE_SUBAGENT_MODEL=deepseek-flash
  export CLAUDE_CODE_AUTO_COMPACT_WINDOW=786432
  unset ANTHROPIC_SMALL_FAST_MODEL _fc_dsm
fi

# MCP: an allowlist (FLEET_MCP_CONFIG, issue #473 — every server costs start time and
# resident children) and the fleet's own tool service + dispatch group (#1807, #3113),
# as --mcp-config files: fleet_launch_mcp (the lib). A caller's own MCP flags win.
mcp_flag=()
fleet_launch_mcp -- "$@"
fleet_launch_browser

# The fleet mod (issue #1335, EPIC #1334): every Claude session this door opens
# loads mod/fleet/ — the plugin that reports from INSIDE the session (version
# gate + heartbeat on the window's @mod_* options; later EPIC members add state,
# context and commands). FLEET_MOD=0, or no plugin folder beside bin/ (a lib-less
# or pre-#1335 install, a selftest sandbox), adds nothing: the argv is byte for
# byte what it was. The =form, like --mcp-config's above, so the value can never
# be read off a following positional (the #476 lesson), and `--plugin-dir` loads
# without the hot-reload question (measured on 2.1.288). A caller's own
# --plugin-dir is additive, so it is never skipped for one.
mod_flag=()
if command -v fleet_mod_on >/dev/null 2>&1 && fleet_mod_on; then
  _fc_mod=$(fleet_mod_dir 2>/dev/null) && mod_flag=("--plugin-dir=$_fc_mod")
  unset _fc_mod
fi

# The session's configuration, fixed at launch (issue #1782): fleet_launch_cfg (the
# lib) hands a --settings and a --mcp-config file for what the login's files lack
# (never an MCP file under an allowlist or a caller's own MCP flags), and the
# fingerprint lands on the window as @agent_cfg.
cfg_flag=()
_fc_ca=(--lock "${FLEET_AGENT_LOCK:-warn}")
[ -n "${FLEET_MCP_CONFIG:-}" ] && _fc_ca+=(--no-mcp)
case " $* " in *" --mcp-config "*|*" --mcp-config="*|*" --strict-mcp-config "*) _fc_ca+=(--no-mcp) ;; esac
case " $* " in *" --settings "*|*" --settings="*) _fc_ca+=(--no-settings) ;; esac
if command -v fleet_mod_on >/dev/null 2>&1 && ! fleet_mod_on; then _fc_ca+=(--mod-off); fi
fleet_launch_cfg ${_fc_ca[@]+"${_fc_ca[@]}"}
# enforce on a locked mod: FLEET_MOD=0 is ignored, the mod loads anyway
# shellcheck disable=SC2154  # fleet_launch_cfg sets it
if [ "$_fl_cfg_mod" = on ] && [ "${#mod_flag[@]}" -eq 0 ] && command -v fleet_mod_dir >/dev/null 2>&1; then
  _fc_mod=$(fleet_mod_dir 2>/dev/null) && mod_flag=("--plugin-dir=$_fc_mod")
  unset _fc_mod
fi
fleet_launch_cfg_stamp
unset _fc_ca

# (After the composed configuration above, so the early mint — fleet_launch_early —
# has that long to finish beside it: T683.)
# Through this login's credential proxy (issue #1972, EPIC #1967 C5): the wrapper
# handed this launch a FLEET_CRED_SID because FLEET_CRED_PROXY=1. The proxy mints a
# SESSION credential for it (fcp1. bound to $label; on an untrusted machine an
# fcp-h1. pass from the hub) and the session talks to 127.0.0.1 — the EPIC's one
# wiring (共同约定 2): ANTHROPIC_BASE_URL + CLAUDE_CODE_OAUTH_TOKEN=<that> +
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1, never CLAUDE_SECURESTORAGE_CONFIG_DIR.
# fleet_claude_export_auth is not called: no subscription credential enters this
# environment. A migrate is then the proxy's rebind of the sid. Exit 4 = nothing to
# bind (no account here: the ambient login) → the launch below, as before. Any other
# failure refuses: a session never quietly falls back to holding the credential.
# The wiring (共同约定 2): ANTHROPIC_BASE_URL + CLAUDE_CODE_OAUTH_TOKEN=<the session
# credential> + CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1, never
# CLAUDE_SECURESTORAGE_CONFIG_DIR; a migrate is then the proxy's rebind of the sid.
_fc_route=''
_fc_mint=(${label:+--account "$label"}); [ -n "$_fc_ds" ] && _fc_mint=(--provider deepseek)
if [ -n "${FLEET_CRED_SID:-}" ] && fleet_launch_mint ${_fc_mint[@]+"${_fc_mint[@]}"}; then
  # shellcheck disable=SC2154  # the lib's mint sets it
  _fc_route=$_fl_route
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  export ANTHROPIC_BASE_URL="http://127.0.0.1:$_fl_port${_fc_ds:+/deepseek}" CLAUDE_CODE_OAUTH_TOKEN="$_fl_cred"
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  _fl_cred=''; _fl_port=''
  if [ -n "${TMUX_PANE:-}" ]; then
    tmux set-option -w -t "$TMUX_PANE" @cred_route "$_fc_route" 2>/dev/null || true
    if [ -n "$label" ] && [ "$_fc_route" != central ]; then tmux set-option -w -t "$TMUX_PANE" @cc_account "$label" 2>/dev/null || true
    else tmux set-option -wu -t "$TMUX_PANE" @cc_account 2>/dev/null || true; fi
  fi
fi

unset _fc_mint
if [ -n "$_fc_ds" ] && [ "$_fc_route" != central ]; then
  # the mint answered «nothing to bind» (4): a DeepSeek session has no other road
  echo "fleet-claude: FLEET_MODEL=$_fc_ds needs a hub pass for the central proxy and the mint gave none — refusing to start" >&2
  fleet_launch_refused deepseek; exit 1
fi
if [ -n "$label" ] && [ -z "$_fc_route" ]; then          # a caller-named account (above)
  tok=$("$BIN/fleet-account.sh" token "$label" 2>/dev/null)
  if [ -n "$tok" ]; then
    if [ -n "${FLEET_ACCOUNT_TARGET:-}" ]; then
      unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
      unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
    fi
    # A plain token → CLAUDE_CODE_OAUTH_TOKEN; a hub-managed account (#1415) →
    # CLAUDE_SECURESTORAGE_CONFIG_DIR at the file the agent keeps renewed.
    fleet_claude_export_auth "$tok"
    # Stamp THIS pane's window (issue #511). An untargeted `set-option -w` resolves
    # to the session's CURRENT window, and every spawn is `new-window -d` (the hub
    # stays current on purpose) — so the label used to land on the hub while the
    # worker stayed unstamped.
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
  else
    echo 'fleet-claude: pinned subscription is unavailable; refusing an ambient login fallback' >&2
    fleet_launch_refused account; exit 1
  fi
fi

# The binary (issue #1774): $FLEET_CLAUDE_BIN, else `claude` when PATH has it (the
# argv byte for byte as before), else ~/.local/bin → /opt/homebrew/bin →
# /usr/local/bin. Nowhere → one line naming every place tried, and exit 127.
_fc_claude=claude
if command -v fleet_find_tool >/dev/null 2>&1; then
  _fc_claude=$(fleet_find_tool claude) || exit 127
fi
# A Claude Code with no `--agent` (EPIC #3111's risk list): the same file rides
# --model / --tools / --disallowedTools / --append-system-prompt-file instead, and
# the doctor's `agents` row says to update it.
if [ ${#as_flag[@]} -gt 0 ] && [ "${as_flag[0]}" = --agent ] \
   && command -v fleet_claude_has_agent_flag >/dev/null 2>&1 && ! fleet_claude_has_agent_flag "$_fc_claude"; then
  fleet_as_resolve claude --no-agent-flag
fi
fleet_launch_settle
fleet_launch_yield   # the agent one scheduling class below the 看台 (T691)
# …and what it runs one more (T691): every Bash tool command and hook goes through
# bin/fleet-tool-yield.sh (QoS background on a Mac, nice +10 elsewhere; the fleet's
# own hooks stay at the agent's). FLEET_TOOL_YIELD=0, a prefix of the person's own,
# or a path Claude Code would split (" -") ⇒ none, the environment as before.
_fc_ty="${FLEET_TOOL_YIELD:-background}"
case "$_fc_ty" in 0|off|none) case "${CLAUDE_CODE_SHELL_PREFIX:-}" in */fleet-tool-yield.sh) unset CLAUDE_CODE_SHELL_PREFIX ;; esac ;; *)
  case "$BIN" in *" -"*|*"'"*) ;; *)
    case "${CLAUDE_CODE_SHELL_PREFIX:-}" in ''|*/fleet-tool-yield.sh)   # none, or ours (a nested launch)
      [ -x "$BIN/fleet-tool-yield.sh" ] && export CLAUDE_CODE_SHELL_PREFIX="$BIN/fleet-tool-yield.sh" FLEET_TOOL_YIELD="$_fc_ty" ;;
    esac ;;
  esac ;;
esac
unset _fc_ty
# The new session's clock (T716): the agent runs now — `exec`, then the ↵ stays
# out of its environment (a dispatch it makes starts a clock of its own).
fleet_timing_at exec
unset FLEET_TIMING_T0 FLEET_TIMING_WHAT
_fc_native=()
if [ -n "${FLEET_TASK_EXECUTION:-}" ]; then
  _fc_native=(python3 "$BIN/fleet_task_execution.py" native --component agent --)
fi
if [ -n "${FLEET_LOOP_SPEC:-}" ] && [ "${FLEET_LOOP_AGENT:-}" = claude ]; then
  # shellcheck disable=SC2154  # fleet_launch_yield sets _fl_yield
  exec python3 "$BIN/fleet-loop.py" bridge -- ${_fl_yield[@]+"${_fl_yield[@]}"} ${_fc_native[@]+"${_fc_native[@]}"} "$_fc_claude" ${model_flag[@]+"${model_flag[@]}"} ${as_flag[@]+"${as_flag[@]}"} ${mcp_flag[@]+"${mcp_flag[@]}"} ${mod_flag[@]+"${mod_flag[@]}"} ${cfg_flag[@]+"${cfg_flag[@]}"} "$@"
fi
# The agent's own report (issue #2536, EPIC #2535 C1): Claude Code ≥ 2.1.295 says
# working / blocked / done as OSC 7501, but only to a terminal that answers its
# probe — and inside tmux nobody does. bin/fleet-status-7501.py runs it under a pty
# relay that answers in the stream and stamps @agent_status (+ @claude_state) off
# what it says. Only a tmux pane with a terminal on it; FLEET_STATUS_7501=0 runs
# the agent bare, byte for byte as before.
_fc_relay=()
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && [ "${FLEET_STATUS_7501:-1}" != 0 ] \
   && [ -t 0 ] && [ -t 1 ] && [ -f "$BIN/fleet-status-7501.py" ]; then
  # …and passes each report on to the person's terminal (issue #2539), wrapped for
  # up to FLEET_STATUS_REPLAY_DEPTH tmux on the way (0 = keep it on this machine).
  _fc_relay=(python3 "$BIN/fleet-status-7501.py" relay --replay "${FLEET_STATUS_REPLAY_DEPTH:-3}" --)
fi
# shellcheck disable=SC2154  # fleet_launch_yield sets _fl_yield
exec ${_fc_relay[@]+"${_fc_relay[@]}"} ${_fl_yield[@]+"${_fl_yield[@]}"} ${_fc_native[@]+"${_fc_native[@]}"} "$_fc_claude" ${model_flag[@]+"${model_flag[@]}"} ${as_flag[@]+"${as_flag[@]}"} ${mcp_flag[@]+"${mcp_flag[@]}"} ${mod_flag[@]+"${mod_flag[@]}"} ${cfg_flag[@]+"${cfg_flag[@]}"} "$@"
