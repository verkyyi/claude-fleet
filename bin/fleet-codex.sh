#!/bin/bash
# fleet-codex.sh — launch OpenAI Codex CLI as a fleet session (issue #547). The one
# door, bin/fleet-claude.sh, execs it for Codex: the pane the spawner made, the seed
# LAST. The steps both agents share are bin/fleet-launch-lib.sh's and what really
# differs is the table bin/fleet_agent_adapter.py (T620, EPIC T580 C4); what stays
# here is Codex's alone — CODEX_HOME (a named profile, a pinned home, the proxy's
# credential-free mirror), the hooks inlined as TOML, CLAUDE.md as the project doc,
# the full-access posture, the version check, @codex_pending. What each agent can do
# is README.md's «Agents» table.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
# shellcheck disable=SC2034  # read by fleet-launch-lib.sh
LAUNCH_AGENT=codex
_fl_lib="$BIN/fleet-launch-lib.sh"   # beside this script, else beside its link's target
[ -f "$_fl_lib" ] || _fl_lib="$(cd "$BIN" && cd "$(dirname "$(readlink "$0")")" && pwd)/fleet-launch-lib.sh"
# shellcheck source=/dev/null
. "$_fl_lib"
if [ "${FLEET_CODEX_NATIVE_USAGE:-0}" = 1 ]; then export FLEET_CODEX_NATIVE_USAGE=1; else unset FLEET_CODEX_NATIVE_USAGE; fi   # #4557: only exported reaches the runtime

# A managed release pins its CLI beside the scripts. A login's inherited PATH
# may still name an older Homebrew/npm Codex first (T944); use the release tool
# for both the private app-server and its terminal client. Ordinary checkouts
# without release tools keep their existing PATH selection.
if [ -x "$ROOT/tools/bin/codex" ]; then
  PATH="$ROOT/tools/bin:$PATH"
  export PATH
fi
command -v codex >/dev/null 2>&1 || { fleet_launch_say 'FLEET_AGENT=codex but `codex` is not on PATH — install OpenAI Codex CLI (npm i -g @openai/codex) and `codex login`, or set FLEET_AGENT back to claude.'; exit 127; }

# Recovery callers carry the account home explicitly, and the shared resume spelling
# (Claude's --resume <id> [--fork-session]) becomes Codex's `resume|fork <id>` (the
# table's resume_flag / fork_flag); native positional forms pass through unchanged.
normal=(); resume_id=''; fork_session=0; _codex_home_explicit=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex-profile)
      [ "$#" -ge 2 ] || { echo 'fleet-codex: --codex-profile requires a ccquota profile' >&2; exit 2; }
      export FLEET_CODEX_PROFILE="$2"; shift 2 ;;
    --codex-home)
      [ "$#" -ge 2 ] && [ -d "$2" ] || { echo 'fleet-codex: recorded CODEX_HOME is missing' >&2; exit 2; }
      export CODEX_HOME="$2"; _codex_home_explicit=1; shift 2
      # a session's credential-free home (issue #1972) names the account home it mirrors
      _fx_rh=$(head -n 1 "$CODEX_HOME/.fleet-real-home" 2>/dev/null)
      [ -n "$_fx_rh" ] && [ -d "$_fx_rh" ] && export CODEX_HOME="$_fx_rh" ;;
    --resume)
      [ "$#" -ge 2 ] || { echo 'fleet-codex: --resume requires a session id' >&2; exit 2; }
      resume_id="$2"; shift 2 ;;
    --fork-session) fork_session=1; shift ;;
    *) normal+=("$1"); shift ;;
  esac
done
_codex_resuming="$resume_id"
for _arg in ${normal[@]+"${normal[@]}"}; do
  case "$_arg" in resume|fork) _codex_resuming=1; break ;; esac
done
# A pinned home (FLEET_CODEX_HOME) is the only one a fleet names (T560): through the
# credential proxy the pool picks per request, else the session runs on its own login.
if [ "$_codex_home_explicit" = 0 ] && [ -z "${FLEET_CODEX_PROFILE:-}" ] && [ -n "${FLEET_CODEX_HOME:-}" ]; then
  [ -d "$FLEET_CODEX_HOME" ] || { echo 'fleet-codex: FLEET_CODEX_HOME is missing' >&2; exit 2; }
  export CODEX_HOME="$FLEET_CODEX_HOME"
fi
if [ -n "$resume_id" ]; then
  verb=$(fleet_agent_get codex resume_flag); [ "$fork_session" = 1 ] && verb=$(fleet_agent_get codex fork_flag)
  set -- "$verb" "$resume_id" ${normal[@]+"${normal[@]}"}
else
  [ "$fork_session" = 0 ] || { echo 'fleet-codex: --fork-session requires --resume' >&2; exit 2; }
  set -- ${normal[@]+"${normal[@]}"}
fi
_codex_pending_sid=''; _pv=''   # the thread a resume reopens (#4728), for @codex_pending; a fork is new
for _arg in "$@"; do
  if [ "$_pv" = resume ]; then
    printf '%s' "$_arg" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
      && { _codex_pending_sid="$_arg"; break; }
    _pv=''
  fi
  case "$_arg" in resume) _pv=resume ;; esac
done

# A NAMED ccquota profile (--codex-profile, a handoff) runs under ccquota's run lock
# and isolated environment for the whole launch (its default profile: no pane's home)
if [ -n "${FLEET_CODEX_PROFILE:-}" ] && [ "${FLEET_CODEX_MANAGED:-0}" != 1 ]; then
  export FLEET_CODEX_MANAGED=1; unset CODEX_HOME
  exec "${FLEET_QUOTA_BIN:-ccquota}" codex --codex-bin "$BIN/fleet-codex.sh" run "$FLEET_CODEX_PROFILE" -- "$@"
fi

# The slow steps start now, beside everything below (T683, a cold start ≤ 5 s): the
# session credential's mint (not for a ccquota profile — the mint below says the same)
# and the folder trust — fleet_launch_early (the lib); the trust is waited for before
# the credential-free mirror copies config.toml, the mint reads its pipe.
if [ -z "${FLEET_CODEX_PROFILE:-}" ]; then fleet_launch_early --codex-home "${CODEX_HOME:-$HOME/.codex}"
else fleet_launch_early --no-mint; fi

# --- argv: the LAST argument is the seed prompt unless it looks like a flag; flags
# before it pass through to codex untouched (`--agent codex` means codex flags)
pass=(); prompt=''; have_prompt=0
n=$#; i=0
for a in "$@"; do
  i=$((i + 1))
  if [ "$i" -eq "$n" ]; then
    case "$a" in -*) pass+=("$a") ;; *) prompt="$a"; have_prompt=1 ;; esac
  else
    pass+=("$a")
  fi
done

# --- the seed: a `/name [args]` first turn in Codex's spelling (the table's `seed`):
# an installed `$name` skill, else the prose expansion; anything else verbatim
if [ "$have_prompt" = 1 ]; then
  case "$prompt" in
    /*) prompt=$(fleet_launch_seed "$prompt"; printf x); prompt=${prompt%x} ;;
  esac
fi

# --- hooks as `-c hooks.<Event>=[…]`, derived from the ONE table (issue #611) with
# the Codex delta (hooks/codex-map.json); a failure launches without them, said so
hook_flags=()
if [ -x "$BIN/fleet-hooks-emit.sh" ]; then
  while IFS=$'\t' read -r _ev _toml; do
    [ -n "$_ev" ] && [ -n "$_toml" ] && hook_flags+=(-c "hooks.$_ev=$_toml")
  done < <("$BIN/fleet-hooks-emit.sh" --target codex --root "$ROOT" 2>/dev/null)
fi
if [ "${#hook_flags[@]}" -eq 0 ]; then
  fleet_launch_say "could not materialise the hook table from $ROOT/hooks/settings-hooks.json — launching WITHOUT hooks: this window will not colour on the dash and the two bypass-permissions guards (bash-guard / base-readonly-guard) are NOT wired for it."
fi
[ -n "${FLEET_MAIN:-}" ] && export FLEET_MAIN    # the base-checkout guard reads it off the env first

fleet_launch_browser

# check_for_update_on_startup=false (issue #2401): a fresh home's «Update available!»
# picker has nobody to answer it; Codex's version is the release's to move. Hooks need
# persisted trust in Codex; the fleet vets its own (--dangerously-bypass-hook-trust).
flags=(
  --dangerously-bypass-hook-trust
  -c 'check_for_update_on_startup=false'
  -c 'features.hooks=true'
  -c 'project_doc_fallback_filenames=["CLAUDE.md"]'
  ${hook_flags[@]+"${hook_flags[@]}"}
)
# Codex's plugins OFF (issue #4848: its startup sync fetches github on every start)
# unless agent-overrides.json says `"codex_plugins": "on"`
python3 "$FLEET_LAUNCH_DIR/fleet-codex-posture.py" plugins-on "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/agent-overrides.json" 2>/dev/null \
  || flags+=(-c 'features.plugins=false')

# --- model: FLEET_CODEX_MODEL → -m (the table's model_env / model_flag) unless the caller chose
launch_model=''
if [ -n "${FLEET_CODEX_MODEL:-}" ]; then
  case " ${pass[*]+"${pass[*]}"} " in
    *" -m "*|*" --model "*|*" --model="*) : ;;
    *) launch_model="$FLEET_CODEX_MODEL"; flags+=(-m "$launch_model") ;;
  esac
fi

# MCP policy + the tool service, then the composed configuration (the lib) — ahead of
# the caller's -c; the composer adds no MCP server under a policy
fleet_launch_mcp "$launch_model" -- "$@"
_cfg_args=(--lock "${FLEET_AGENT_LOCK:-warn}" --codex-home "${CODEX_HOME:-$HOME/.codex}")
[ -z "$_codex_resuming" ] || _cfg_args+=(--resume-permissions)
[ -n "${FLEET_CODEX_MCP_CONFIG-${FLEET_MCP_CONFIG:-}}" ] && _cfg_args+=(--no-mcp)
fleet_launch_cfg "${_cfg_args[@]}"
unset _cfg_args

# --- full access (a bypassPermissions worker's footing; the hooks are the rails) for a
# fresh thread only, and not as a flag when config.toml already says it: a flag blocks
# every in-TUI /resume (issue #4724)
if [ -z "$_codex_resuming" ]; then
  if [ "${FLEET_CODEX_POSTURE_FROM_CONFIG:-1}" = 0 ] || [ ! -f "$BIN/fleet-codex-posture.py" ] \
     || ! python3 "$BIN/fleet-codex-posture.py" check --home "${CODEX_HOME:-$HOME/.codex}" --cwd "$PWD" \
          -- ${flags[@]+"${flags[@]}"} ${pass[@]+"${pass[@]}"} >/dev/null 2>&1; then
    flags=(--dangerously-bypass-approvals-and-sandbox ${flags[@]+"${flags[@]}"})
  fi
fi

# --- version drift: warn, never block (issue #1079); the line rides into @codex_identity
unset FLEET_CODEX_VERSION_WARNING FLEET_CODEX_NATIVE_COMPLETION   # never inherit a parent's verdict
if [ "${FLEET_CODEX_VERSION_CHECK:-1}" != 0 ] && [ -f "$BIN/fleet-codex-runtime.py" ]; then
  _vline=$(python3 "$BIN/fleet-codex-runtime.py" version-check 2>/dev/null); _vrc=$?
  [ "$_vrc" = 1 ] && { fleet_launch_say "warning: $_vline"; export FLEET_CODEX_VERSION_WARNING="$_vline"; }
  case "$_vrc:$_vline" in '0:codex 0.162.1 (rollout format verified '*) export FLEET_CODEX_NATIVE_COMPLETION=1 ;; esac
fi

# --- through the credential proxy (the lib's mint): a custom provider (base_url +
# env_key; plugins / apps / analytics off) and a credential-free mirror of the account
# home as CODEX_HOME (@codex_home keeps the REAL one). Not for a ccquota profile.
_fx_real_home=''; _fx_route=''
fleet_launch_trust_wait                      # started early (above); in place when FLEET_LAUNCH_EARLY=0
if [ -n "${FLEET_CRED_SID:-}" ] && [ -z "${FLEET_CODEX_PROFILE:-}" ] \
   && fleet_launch_mint --codex-home "${CODEX_HOME:-$HOME/.codex}"; then
  # shellcheck disable=SC2154  # the lib's mint sets them
  _fx_route=$_fl_route; export FLEET_CODEX_SESSION_CRED="$_fl_cred"; _fl_cred=''
  _fx_real_home="${CODEX_HOME:-$HOME/.codex}"
  _fx_home=$(bash "$BIN/fleet-session-cred.sh" codex-home --sid "$FLEET_CRED_SID" --real "$_fx_real_home") \
    || { fleet_launch_say 'could not make this session a credential-free CODEX_HOME — refusing to launch'; fleet_launch_refused cred; exit 1; }
  export CODEX_HOME="$_fx_home"
  # every account out (#4606) ⇒ say when each is back; FLEET_CODEX_QUOTA_GATE=1 refuses
  _fx_out=''
  if [ "$(sed -n 's/^account=//p' "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/cred-proxy/sessions/$FLEET_CRED_SID" 2>/dev/null | tail -n 1)" = proxy ]; then
    _fx_out=$(bash "$BIN/fleet-session-cred.sh" standing --provider codex) && _fx_out=''
  fi
  if [ -n "$_fx_out" ]; then
    fleet_launch_say "$_fx_out"
    if [ -z "$_codex_resuming" ] && [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
      fleet_launch_say 'FLEET_CODEX_QUOTA_GATE=1 — not launching on an account with no quota'
      fleet_launch_refused account; exit 2
    fi
  fi
  flags+=(-c 'model_provider="fleet"'
          -c "model_providers.fleet={name=\"fleet\",base_url=\"http://127.0.0.1:$_fl_port/codex\",env_key=\"FLEET_CODEX_SESSION_CRED\",wire_api=\"responses\"}"
          -c 'features.apps=false' -c 'analytics.enabled=false')
  # plugins off whatever agent-overrides says (the proxy's provider has no marketplace)
  case " ${flags[*]} " in *" features.plugins=false "*) ;; *) flags+=(-c 'features.plugins=false') ;; esac # bash32-ok: flags is populated above
  unset _fx_home _fx_out; _fl_port=''
fi

# --- stamp THIS pane's window
export FLEET_CODEX_LAUNCHER_PID="$$" FLEET_CODEX_REMOTE=''
_remote_next=0
for a in ${pass[@]+"${pass[@]}"}; do
  if [ "$_remote_next" = 1 ]; then FLEET_CODEX_REMOTE="$a"; _remote_next=0; fi
  case "$a" in --remote) _remote_next=1 ;; --remote=*) FLEET_CODEX_REMOTE="${a#--remote=}" ;; esac
done
if [ -n "${TMUX_PANE:-}" ]; then
  _fx_home="${_fx_real_home:-${CODEX_HOME:-$HOME/.codex}}"
  tmux set-option -w -t "$TMUX_PANE" @cc_agent codex 2>/dev/null || true
  fleet_launch_wset @codex_home "$_fx_home"
  [ -n "$_fx_route" ] && fleet_launch_wset @cred_route "$_fx_route"
  # @cc_account names only an account a caller named (T560, as fleet-claude.sh T550)
  fleet_launch_wset @cc_account "${FLEET_CODEX_PROFILE:+codex:$FLEET_CODEX_PROFILE}"
  fleet_launch_wset @cc_launcher_pid "$$"
  # New ownership invalidates the old JSON even if the process died before its
  # SessionEnd. Clear visible context too; the first root hook supplies truth.
  for _opt in @codex_identity @codex_session_id @codex_attention @ctx_pct @ctx_limit @ctx_band @ctx_left @ctx_ts @ctx_src @model @effort @cc_model @handoff_armed; do
    fleet_launch_wset -u "$_opt"
  done
  # a resume's thread until its first hook writes @codex_identity, in its shape (#4728)
  _pend=''
  [ -n "$_codex_pending_sid" ] && _pend=$(python3 -c 'import json,os,sys; print(json.dumps({"session_id":sys.argv[1],"owner":sys.argv[2],"home":os.path.realpath(sys.argv[3]),"transcript":"","pending":True},separators=(",",":")))' \
      "$_codex_pending_sid" "$$" "$_fx_home" 2>/dev/null)
  if [ -n "$_pend" ]; then fleet_launch_wset @codex_pending "$_pend"; else fleet_launch_wset -u @codex_pending; fi
  [ -n "$launch_model" ] && fleet_launch_wset @cc_model "$launch_model"
  fleet_launch_cfg_stamp                     # issue #1782
  unset _fx_home _pend
fi

# The runner: the pane's private app-server (a loop's own bridge), else codex. Only a
# successful CLI exit closes the window (#730: SessionEnd always says reason=other) —
# the table's `end` column, run by fleet_launch_end.
fleet_launch_settle                          # nothing early left behind for the agent to inherit
runner=(codex)
if [ -n "${FLEET_LOOP_SPEC:-}" ]; then
  runner=(python3 "$BIN/fleet-loop.py" bridge --)
elif [ -n "${TMUX:-}" ] && [ "${FLEET_CODEX_SERVER:-1}" != 0 ] && [ -z "$FLEET_CODEX_REMOTE" ] \
   && [ -f "$BIN/fleet-codex-runtime.py" ]; then
  runner=(python3 "$BIN/fleet-codex-runtime.py" --)
fi
fleet_launch_yield   # the agent one scheduling class below the 看台 (T691)
fleet_timing_at exec   # the new session's clock (T716): the agent runs now
unset FLEET_TIMING_T0 FLEET_TIMING_WHAT
# shellcheck disable=SC2154  # fleet_launch_yield sets _fl_yield
runner=(${_fl_yield[@]+"${_fl_yield[@]}"} "${runner[@]}") # bash32-ok: runner is always populated
if [ "$have_prompt" = 1 ]; then
  "${runner[@]}" "${flags[@]}" ${pass[@]+"${pass[@]}"} "$prompt" # bash32-ok: runner and flags are always populated
else
  "${runner[@]}" "${flags[@]}" ${pass[@]+"${pass[@]}"} # bash32-ok: runner and flags are always populated
fi
rc=$?
fleet_launch_end "$rc"                       # the one close (T631): the table's end = exit
exit "$rc"
