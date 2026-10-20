# shellcheck shell=bash
# fleet-launch-lib.sh — the launch steps every agent shares (T620, EPIC T580 C4).
#
# bin/fleet-claude.sh and bin/fleet-codex.sh used to write each of these twice, and
# a fix on one side reached the other only after it broke there too (permissions,
# a Codex opened as Claude, a Claude CLI asked for Codex's plugins). Both source this
# file instead, with BIN set and LAUNCH_AGENT=claude|codex; where the agents really
# differ, the step asks the adapter table (bin/fleet-agent-adapter.sh, generated
# from bin/fleet_agent_adapter.py) — never the agent's name. What stays in each
# launcher is only what that agent alone needs: Claude's model / subagent tier /
# mod / named account; Codex's CODEX_HOME, hooks as TOML, posture, version check.
#
# Sourcing it LOADS THE CONFIGURATION at the top level (so a sourced conf's
# assignments are the script's, never a function's locals): fleet-lib.sh (which also
# reads the global fleet.conf), the install's fleet.conf for a lib-less install, the
# login's settings + its one fleet.conf (#979, #1623), the per-fleet overlay (#472).
# Then the steps:
#   fleet_launch_say <words>              one `fleet-<agent>: …` line on stderr
#   fleet_launch_wset [-u] <opt> [<val>]  a window option on this pane's window
#   fleet_launch_refused <why>            @launch_refused on the pane (#2404)
#   fleet_launch_seed <prompt>            the first turn in this agent's spelling (the table's `seed`)
#   fleet_launch_browser                  BROWSER for the fleet-browser plugin (#3236)
#   fleet_launch_trust                    pre-answer "trust this folder?" (#563, #2282, #2401)
#   fleet_launch_mcp [<model>] -- <argv>  the fleet's tool service + an allowlist (#473, #1807)
#   fleet_launch_cfg [args…]              the session's composed configuration (#1782)
#   fleet_launch_cfg_stamp                its fingerprint on the window
#   fleet_launch_mint [args…]             a session credential from the proxy (#1972)
#   fleet_launch_end <rc>                 the agent exited: the one close, when the
#                                         table's `end` says its exit code is the word (T631)

# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"     # also sources the sibling global fleet.conf
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"   # kept for a lib-less install
FLEET_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # where this file (and the table) is
# shellcheck source=/dev/null
. "$FLEET_LAUNCH_DIR/fleet-agent-adapter.sh"
# the agent CLIs and tmux even from a PATH-less ssh / daemon shell (issue #1774):
# the dirs they install to are appended when missing — an existing PATH order wins
command -v fleet_path_fill >/dev/null 2>&1 && { PATH=$(fleet_path_fill); export PATH; }
_fl_conf="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
# shellcheck source=/dev/null
[ -f "$_fl_conf/fleet.settings" ] && . "$_fl_conf/fleet.settings"
# shellcheck source=/dev/null
[ -f "$_fl_conf/fleet.conf" ] && . "$_fl_conf/fleet.conf"
unset _fl_conf
# Per-fleet overlay (issue #472): a spawned window inherits none of its spawner's
# environment, so the fleet's own conf is read here from $TMUX_PANE's session —
# without it every @scope=fleet key only a launcher reads was silently inert (two
# fleets set FLEET_MODEL=fable and ran opus). fleet_load_conf strips
# $_FLEET_GLOBAL_ONLY (#237). No tmux / no conf / no lib → a clean no-op.
FLEET_LAUNCH_FLEET=''
if command -v fleet_load_conf >/dev/null 2>&1; then
  FLEET_LAUNCH_FLEET="$(fleet_current_session 2>/dev/null)"
  [ -n "$FLEET_LAUNCH_FLEET" ] && fleet_load_conf "$FLEET_LAUNCH_FLEET"
fi

fleet_launch_say() { printf 'fleet-%s: %s\n' "$LAUNCH_AGENT" "$*" >&2; }
# A window option on THIS pane's window (issue #511: -t "$TMUX_PANE", never the
# current window); `-u <opt>` unsets. No pane → nothing.
fleet_launch_wset() {
  [ -n "${TMUX_PANE:-}" ] || return 0
  if [ "$1" = -u ]; then tmux set-option -wu -t "$TMUX_PANE" "$2" 2>/dev/null || true
  else tmux set-option -w -t "$TMUX_PANE" "$1" "$2" 2>/dev/null || true; fi
}

# A refusal to start the agent at all (issue #2404) says so on the pane before the
# exit: fleet-session-wrap.sh then stops on the recovery page with the reason
# (cred | cred_unknown | account) instead of handing the window to a bare shell.
fleet_launch_refused() { [ -n "${TMUX_PANE:-}" ] && tmux set-option -p -t "$TMUX_PANE" @launch_refused "$1" 2>/dev/null; return 0; }

# The first turn (issue #299): a `/name [args]` seed in this agent's spelling — as
# typed for Claude; an installed `$name` skill, else the prose expansion from the
# install's commands/ + conf/codex-preamble.md for Codex. Anything else, or a
# converter that cannot run, is the prompt as typed. Prints it (no newline added).
fleet_launch_seed() {
  local out
  case "$1" in /*) : ;; *) printf '%s' "$1"; return 0 ;; esac
  out=$(python3 "$FLEET_LAUNCH_DIR/fleet_agent_adapter.py" seed "$LAUNCH_AGENT" "$1" --root "$BIN/.." && printf x) \
    && printf '%s' "${out%x}" || printf '%s' "$1"
}

# The agent's browser (issue #3236): with the fleet-browser plugin installed and
# enabled for this login (off by default) the agent runs `$BROWSER <url>` for an MCP
# authorization, /login or a page, and fleet-browser.sh hands it to the person's own
# computer. A plugin cannot set its agent's environment, so the launcher does.
fleet_launch_browser() {
  if bash "$BIN/fleet-browser.sh" enabled 2>/dev/null; then export BROWSER="$BIN/fleet-browser.sh"; fi
}

# --- project trust ------------------------------------------------------------------
# An unattended fleet pane has nobody to answer "trust this folder?" (on 2026-09-12
# two workers sat on it 7+ minutes, issue #563), so the door answers it for the
# fleet's OWN directories through bin/fleet-trust.sh — scoped, atomic, fill only.
# A TRUSTED NODE (`fleet-trust.sh node`, the credential proxy's word from the hub)
# goes wider: every hosted repo's checkout, and — for a window the fleet opened with
# no repo (@norepo 1) whose cwd is the login's $HOME — that one directory (#2282).
# Where the answer is written is the table's `trust`:
#   claude-json  ~/.claude.json, the base checkout on every spawn, wider on a trusted node
#   codex-toml   $CODEX_HOME/config.toml, on a trusted node only (fill only, so a login's
#                own "untrusted" stands); an untrusted base then says so on the pane and
#                the window goes `needs` rather than stall silently (#2401)
# FLEET_PRETRUST=0 opts a fleet out of the pre-grant.
fleet_launch_trust() {
  local home=0 nr ta=() granted rc m r err="${TMPDIR:-/tmp}/.fleet-trust.$$" root conf ft=0
  [ -f "$BIN/fleet-trust.sh" ] && ft=1
  if [ -n "${TMUX_PANE:-}" ]; then
    nr=$(tmux display-message -p -t "$TMUX_PANE" '#{@norepo}' 2>/dev/null)
    [ "$nr" = 1 ] && [ "$(cd "$PWD" 2>/dev/null && pwd -P)" = "$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" ] && home=1
  fi
  case "$(fleet_agent_get "$LAUNCH_AGENT" trust)" in
  claude-json)
    [ "${FLEET_PRETRUST:-1}" != 0 ] && [ "$ft" = 1 ] || return 0
    if { [ -n "${FLEET_MAIN:-}" ] || [ "$home" = 1 ]; } && sh "$BIN/fleet-trust.sh" node >/dev/null 2>&1; then
      [ -n "${FLEET_MAIN:-}" ] && ta+=(--main "$FLEET_MAIN")
      if [ -n "$FLEET_LAUNCH_FLEET" ] && command -v fleet_repos >/dev/null 2>&1; then
        while IFS= read -r r; do
          [ -n "$r" ] || continue
          m=$(fleet_repo_conf_get "$FLEET_LAUNCH_FLEET" "$r" FLEET_MAIN 2>/dev/null)
          [ -n "$m" ] && [ "$m" != "${FLEET_MAIN:-}" ] && ta+=(--main "$m")
        done <<EOF_FL_REPOS
$(fleet_repos "$FLEET_LAUNCH_FLEET" 2>/dev/null)
EOF_FL_REPOS
      fi
      [ "$home" = 1 ] && ta+=(--home)
      [ "${#ta[@]}" -gt 0 ] || return 0
      granted=$(sh "$BIN/fleet-trust.sh" grant ${ta[@]+"${ta[@]}"} "$PWD" 2>"$err"); rc=$?
      [ -n "$granted" ] && fleet_launch_say "pre-trusted $(printf '%s' "$granted" | tr '\n' ' ') in $(sh "$BIN/fleet-trust.sh" file) (trusted node, issue #2282)"
    elif [ -n "${FLEET_MAIN:-}" ]; then
      granted=$(sh "$BIN/fleet-trust.sh" grant --main "$FLEET_MAIN" "$PWD" 2>"$err"); rc=$?
      [ -n "$granted" ] && fleet_launch_say "pre-trusted $(printf '%s' "$granted" | tr '\n' ' ') in $(sh "$BIN/fleet-trust.sh" file) (issue #563)"
    else
      return 0
    fi
    # 3 = a refused path (a cwd outside this fleet's checkout), 2 = no python3: both
    # silent; anything else is a real write failure the pane shows
    case "$rc" in 0|2|3) : ;; *) cat "$err" >&2 ;; esac
    rm -f "$err" ;;
  codex-toml)
    # a git worktree inherits its MAIN repo's trust; a `-c projects…` override does
    # not satisfy the prompt (trust is persisted state in config.toml)
    root=''; [ -n "${FLEET_MAIN:-}" ] && root=$(cd "$FLEET_MAIN" 2>/dev/null && pwd -P)
    [ "$home" = 1 ] && root=$(pwd -P)
    conf="${CODEX_HOME:-$HOME/.codex}/config.toml"
    if [ "$home" = 1 ]; then
      [ "$ft" = 1 ] && sh "$BIN/fleet-trust.sh" codex-grant --home >/dev/null 2>&1 || :
    elif [ -n "$root" ] && [ "${FLEET_PRETRUST:-1}" != 0 ] && [ "$ft" = 1 ] && sh "$BIN/fleet-trust.sh" node >/dev/null 2>&1 \
         && granted=$(sh "$BIN/fleet-trust.sh" codex-grant --main "$root" 2>/dev/null) && [ -n "$granted" ]; then
      fleet_launch_say "pre-trusted $granted in $conf (trusted node, issue #2401)"
    fi
    if [ -n "$root" ] && [ -r "$conf" ] && ! python3 "$BIN/fleet_codex_trust.py" check "$root" >/dev/null 2>&1; then
      printf '\n' >&2
      fleet_launch_say "the directory $root is not trusted in $conf — Codex will ask"
      fleet_launch_say '"Do you trust the contents of this directory?" below. Answer 1 (Yes) ONCE: Codex'
      if [ "$home" = 1 ]; then fleet_launch_say 'persists that choice for this login HOME.'
      else fleet_launch_say 'persists it for the repo, and every issue-<N>/scratch-<N> worktree inherits it.'; fi
      printf '\n' >&2
      # </dev/null: the stamper's `needs` path reads a hook payload off stdin
      [ -n "${TMUX_PANE:-}" ] && sh "$BIN/set-claude-state.sh" needs </dev/null >/dev/null 2>&1
    fi ;;
  esac
  return 0
}

# --- the fleet's tool service + an MCP allowlist ----------------------------------------
# Every session mounts bin/fleet-mcp.py as the MCP server `fleet` (issue #1807, defined
# once in conf/mcp-worker.json) and its dispatch group `fleet-orch` (issue #3113,
# every session since #4703; FLEET_MCP_ORCH=1 tells the core server it is beside it).
# FLEET_MCP_CONFIG (issue #473) narrows the rest: unset = every configured server,
# `none` = no other, <path|json> = only these (recommended: conf/mcp-worker.json, #1078).
# FLEET_MCP=0 or no file beside bin/ mounts nothing. How it is handed over is the
# table's `mcp`:
#   flags   --strict-mcp-config + --mcp-config=<file> into mcp_flag[] (the =form: the
#           option is VARIADIC and would swallow the seed that follows — #476, keep it);
#           a caller's own MCP flags win, and an allowlist that already names `fleet`
#           mounts it itself
#   config  -c values into flags[]: the allowlist (and the subagent model / effort)
#           through bin/fleet-codex-policy.py against the effective config, then the
#           fleet's own servers (fleet-mcp.py --mount codex: the env Codex withholds
#           from a server, TMUX_PANE …). A policy that cannot be applied refuses (2).
fleet_launch_mcp() {   # [<launch model>] -- <the agent argv>
  local model='' mw="$BIN/../conf/mcp-worker.json" have v mount pol mcp sub
  [ "${1:-}" = -- ] || { model="${1:-}"; shift; }
  [ "${1:-}" = -- ] && shift
  unset FLEET_MCP_SERVER FLEET_MCP_ORCH                       # never inherit a parent's mount
  case "$(fleet_agent_get "$LAUNCH_AGENT" mcp)" in
  flags)
    case " $* " in *" --mcp-config "*|*" --mcp-config="*|*" --strict-mcp-config "*) return 0 ;; esac
    if [ -n "${FLEET_MCP_CONFIG:-}" ]; then
      v="$FLEET_MCP_CONFIG"; [ "$v" = none ] && v='{"mcpServers":{}}'
      mcp_flag+=(--strict-mcp-config "--mcp-config=$v")
    fi
    [ "${FLEET_MCP:-1}" != 0 ] && [ -f "$mw" ] && [ -f "$BIN/fleet-mcp.py" ] || return 0
    # FLEET_MCP_SERVER=1 tells the mod not to register its own fallback tools
    export FLEET_MCP_BIN="$BIN" FLEET_MCP_SERVER=1
    case "${FLEET_MCP_CONFIG:-}" in
      ''|none) have='' ;;
      '{'*)    have="$FLEET_MCP_CONFIG" ;;
      *)       have=$(cat "${FLEET_MCP_CONFIG/#\~/$HOME}" 2>/dev/null) ;;
    esac
    case "$have" in *'"fleet":'*|*'"fleet" :'*) : ;; *) mcp_flag+=("--mcp-config=$mw") ;; esac
    if [ -f "$BIN/../conf/mcp-orch.json" ]; then
      mcp_flag+=("--mcp-config=$BIN/../conf/mcp-orch.json"); export FLEET_MCP_ORCH=1
    fi ;;
  config)
    mcp="${FLEET_CODEX_MCP_CONFIG-${FLEET_MCP_CONFIG:-}}"
    sub="${FLEET_CODEX_SUBAGENT_MODEL-$model}"
    if [ -n "$mcp$sub${FLEET_CODEX_SUBAGENT_EFFORT:-}" ] && [ -f "$BIN/fleet-codex-policy.py" ]; then
      pol=$(FLEET_CODEX_MCP_CONFIG="$mcp" FLEET_CODEX_SUBAGENT_MODEL="$sub" \
        FLEET_CODEX_SUBAGENT_EFFORT="${FLEET_CODEX_SUBAGENT_EFFORT:-}" \
        python3 "$BIN/fleet-codex-policy.py" -- "$@") || exit 2
      while IFS= read -r v; do [ -z "$v" ] || flags+=(-c "$v"); done <<< "$pol"
    fi
    [ "${FLEET_MCP:-1}" != 0 ] && [ -f "$mw" ] && [ -f "$BIN/fleet-mcp.py" ] || return 0
    mount=$(python3 "$BIN/fleet-mcp.py" --mount codex 2>/dev/null) && [ -n "$mount" ] || return 0
    export FLEET_MCP_BIN="$BIN"
    flags+=(-c "$mount")
    python3 "$BIN/fleet-mcp.py" --bridge-seat 2>/dev/null \
      && mount=$(python3 "$BIN/fleet-mcp.py" --mount codex --group orch 2>/dev/null) && [ -n "$mount" ] \
      && { flags+=(-c "$mount"); export FLEET_MCP_ORCH=1; } ;;
  esac
  return 0
}

# --- the session's configuration, fixed at launch (issue #1782, EPIC #1776 C6) ----------
# bin/fleet-agent-team.py composes fleet default < team < local NOW and hands exactly
# what the login's own files lack — Claude: a --settings and a --mcp-config file into
# cfg_flag[]; Codex: `-c` values into flags[] (ahead of the caller's own -c, so a
# caller still wins). Locked items follow FLEET_AGENT_LOCK (warn: the login's value,
# said on one line; enforce: the fleet's). The fingerprint is for fleet_launch_cfg_stamp:
# @agent_cfg (+ @agent_cfg_src, @agent_ver #1895, @agent_cfg_manifest #2076).
# FLEET_AGENT_CFG=0 or no composer beside bin/ adds nothing, byte for byte.
_fl_cfg_fp=''; _fl_cfg_src=''; _fl_cfg_ver=''; _fl_cfg_man=''; _fl_cfg_mod=''
fleet_launch_cfg() {   # [composer args…]
  local k v locks='' say=''
  [ "${FLEET_AGENT_CFG:-1}" != 0 ] && [ -f "$BIN/fleet-agent-team.py" ] && command -v python3 >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r k v; do
    case "$k" in
      fp)       _fl_cfg_fp="$v" ;;
      src)      _fl_cfg_src="$v" ;;
      ver)      _fl_cfg_ver="$v" ;;
      manifest) _fl_cfg_man="$v" ;;
      say)      say="$v" ;;
      mod)      _fl_cfg_mod="$v" ;;
      mcp)      cfg_flag+=("--mcp-config=$v") ;;   # the =form: --mcp-config is variadic
      settings) cfg_flag+=("--settings=$v") ;;
      c)        flags+=(-c "$v") ;;
      lock)     locks="${locks:+$locks; }$v" ;;
      note)     fleet_launch_say "$v (issue #1862)" ;;   # the personal layer written badly
      hint)     fleet_launch_say "本机新加了 ${v#promote } — 要带到别的机器：fleet config $v" ;;   # said once (#1863)
    esac
  done < <(FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}" \
             python3 "$BIN/fleet-agent-team.py" session "$LAUNCH_AGENT" "$@" 2>/dev/null)
  # where this session's configuration comes from (EPIC #1855 C6) — only with a personal layer
  [ -n "$say" ] && fleet_launch_say "配置 $say"
  [ -n "$locks" ] && fleet_launch_say "locked agent config overridden on this login: $locks (issue #1782)"
  return 0
}
fleet_launch_cfg_stamp() {
  [ -n "$_fl_cfg_fp" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  tmux set-option -w -t "$TMUX_PANE" @agent_cfg "$_fl_cfg_fp" 2>/dev/null || true
  tmux set-option -w -t "$TMUX_PANE" @agent_cfg_src "$_fl_cfg_src" 2>/dev/null || true
  # the fleet version it runs (#1895) — differs from the expected ver ⇒ 待换新; what it
  # started with (#2076) — fleet-oldcfg-check.sh tells 会坏 from merely 旧 off it
  if [ -n "$_fl_cfg_ver" ]; then fleet_launch_wset @agent_ver "$_fl_cfg_ver"; else fleet_launch_wset -u @agent_ver; fi
  if [ -n "$_fl_cfg_man" ]; then fleet_launch_wset @agent_cfg_manifest "$_fl_cfg_man"; else fleet_launch_wset -u @agent_cfg_manifest; fi
}

# --- through this login's credential proxy (issue #1972, EPIC #1967 C5) ------------------
# The wrapper handed this launch a FLEET_CRED_SID (FLEET_CRED_PROXY=1): the proxy mints
# a SESSION credential (fcp1.; on an untrusted machine an fcp-h1. pass from the hub)
# and the session talks to 127.0.0.1 — no subscription credential enters the
# environment. Sets _fl_route _fl_port _fl_cred and returns 0; 4 = nothing to bind
# (the ambient login) → the launch goes on as before; 404 from the hub, or any other
# failure, REFUSES — a session never quietly falls back to holding the credential.
_fl_route=''; _fl_port=''; _fl_cred=''
fleet_launch_mint() {   # [mint args…]
  local px rc
  px=$(bash "$BIN/fleet-session-cred.sh" mint --provider "$LAUNCH_AGENT" --sid "$FLEET_CRED_SID" "$@"); rc=$?
  case "$rc" in
    0) IFS=$'\t' read -r _fl_route _fl_port _fl_cred <<< "$px"; return 0 ;;
    4) return 4 ;;
    5) fleet_launch_say 'the hub does not know this session (404: not registered for this node) — refusing to launch; ↵ on the page re-registers it and retries'
       fleet_launch_refused cred_unknown; exit 1 ;;
    *) fleet_launch_say 'FLEET_CRED_PROXY=1 but no session credential could be had from the proxy — refusing to launch (fleet-cred-proxy.sh status; logs/cred-proxy.log)'
       fleet_launch_refused cred; exit 1 ;;
  esac
}

# fleet_launch_end <rc> — the agent this launcher waited on has exited with <rc>
# (T631, EPIC T580 C8). Where the table's `end` column is `exit`, an exit 0 is the
# person walking away and runs the ONE close (session-end-hook.sh --agent-exit, the
# same gates a SessionEnd hook passes); a non-zero exit (killed, crashed) closes
# nothing — the recovery page / the reapers decide. `hook` agents (exec'd, their
# SessionEnd hook is the word) never reach here. Outside a tmux pane: nothing.
fleet_launch_end() {
  [ "$(fleet_agent_get "$LAUNCH_AGENT" end)" = exit ] || return 0
  [ "${1:-}" = 0 ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
    && [ -f "$BIN/session-end-hook.sh" ] || return 0
  bash "$BIN/session-end-hook.sh" --agent-exit "$LAUNCH_AGENT" "$$" </dev/null
  return 0
}
