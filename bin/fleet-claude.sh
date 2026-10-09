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
# A refusal to start the agent at all (issue #2404) says so on the pane before the
# exit: fleet-session-wrap.sh then stops on the recovery page with the reason
# (cred | account) instead of handing the window to the caller's bare shell.
_fc_refused() { [ -n "${TMUX_PANE:-}" ] && tmux set-option -p -t "$TMUX_PANE" @launch_refused "$1" 2>/dev/null; return 0; }
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"     # also sources the sibling global fleet.conf
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"   # kept for a lib-less install
# claude and tmux even from a PATH-less ssh / daemon shell (issue #1774): the dirs
# they install to are appended to PATH when missing — an existing PATH order wins.
command -v fleet_path_fill >/dev/null 2>&1 && { PATH=$(fleet_path_fill); export PATH; }
_fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"; [ -f "$_fs/fleet.settings" ] && . "$_fs/fleet.settings"; [ -f "$_fs/fleet.conf" ] && . "$_fs/fleet.conf"   # the login's settings win (#979); the machine's one file (#1623)

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
  _fc_fleet="$_fc_sess"   # kept for the trusted node's pre-trust (issue #2282)
  unset _fc_sess
fi

# Account CLASS (issue #1540, EPIC #1529 R2): which kind of subscription this
# session may run on — `local` (this login's own token files), `pool` (the hub's
# leased `hub:<label>` accounts, #1415) or `any` (the pick as it always was). The
# window's @account_class — stamped by dash-issue-session.sh --account inside the
# pane's own command, before this runs — wins over the FLEET_ACCOUNT_CLASS the
# fleet conf / environment carry: a session's choice beats the fleet's default.
# Exported so fleet-account.sh (`active`, and `launch` under FLEET_FAILOVER)
# narrows its pick; a class from the conf is stamped back so the window says what
# it runs on. `any` / unset / garbage: the variable is gone and nothing changes.
_fc_cls=''
[ -n "${TMUX_PANE:-}" ] && _fc_cls=$(tmux show-options -wqv -t "$TMUX_PANE" @account_class 2>/dev/null)
case "$_fc_cls" in local|pool) : ;; *) _fc_cls="${FLEET_ACCOUNT_CLASS:-}" ;; esac
case "$_fc_cls" in
  local|pool)
    export FLEET_ACCOUNT_CLASS="$_fc_cls"
    [ -n "${TMUX_PANE:-}" ] && tmux set-option -w -t "$TMUX_PANE" @account_class "$_fc_cls" 2>/dev/null ;;
  *) unset FLEET_ACCOUNT_CLASS ;;
esac
unset _fc_cls

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
# A SEPARATED login (credsep.json, #1971) through its credential proxy does not
# choose its subscription (issue #2412): the session credential names no account
# and the proxy picks one per request, moving it when it fills — so no pick, no
# failover planner, no @cc_account here. Byte for byte as before anywhere else.
_fc_sep=0
[ -n "${FLEET_CRED_SID:-}" ] && [ -f "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/credsep.json" ] && _fc_sep=1
# Opted-in fresh launches use the same strict subscription planner as recovery.
# Native resume/model-specific calls retain their explicit provider contract.
if [ "${FLEET_FAILOVER:-0}" = 1 ] && [ "${FLEET_ACCOUNT_SELECTED:-0}" != 1 ] \
  && [ -z "${FLEET_HANDOFF_MANIFEST:-}" ] && [ "$_fc_sep" != 1 ]; then
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
#
# A TRUSTED NODE goes wider (issue #2282): when `fleet-trust.sh node` reads this
# machine as trusted (the credential proxy's cached word from the hub), the grant
# names EVERY repo this fleet hosts (fleet_repos → each one's FLEET_MAIN), so a
# worktree of the second repo is covered whatever the window's overlay said, and
# — for a window the fleet opened with no repo (@norepo 1, or the orchestrator)
# whose cwd is the login's $HOME — `--home`, that one directory. Still the same
# door: the ↵ on the recovery page, fleet-migrate, fleet-restore and a sleeper's
# wake all relaunch through here. Not trusted / cannot tell ⇒ the narrow call
# below, byte for byte; nothing already running is touched.
_fc_tr_args='' _fc_tr_home=0
if [ "${FLEET_PRETRUST:-1}" != 0 ] && [ -f "$BIN/fleet-trust.sh" ]; then
  _fc_norepo=''
  if [ -n "${TMUX_PANE:-}" ]; then
    _fc_norepo=$(tmux display-message -p -t "$TMUX_PANE" '#{@norepo}|#{@fleet_role}' 2>/dev/null)
  fi
  case "$_fc_norepo" in
    1\|*|*\|orchestrator)
      [ "$(cd "$PWD" 2>/dev/null && pwd -P)" = "$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" ] \
        && _fc_tr_home=1 ;;
  esac
  unset _fc_norepo
  # nothing the wide form could add (no checkout, not a no-repo window in $HOME) ⇒
  # no question asked, exactly as before
  if { [ -n "${FLEET_MAIN:-}" ] || [ "$_fc_tr_home" = 1 ]; } \
     && sh "$BIN/fleet-trust.sh" node >/dev/null 2>&1; then
    _fc_tr_args=wide
  fi
fi
if [ "$_fc_tr_args" = wide ]; then
  _fc_tr=()
  [ -n "${FLEET_MAIN:-}" ] && _fc_tr+=(--main "$FLEET_MAIN")
  if [ -n "${_fc_fleet:-}" ] && command -v fleet_repos >/dev/null 2>&1; then
    while IFS= read -r _fc_r; do
      [ -n "$_fc_r" ] || continue
      _fc_m=$(fleet_repo_conf_get "$_fc_fleet" "$_fc_r" FLEET_MAIN 2>/dev/null)
      [ -n "$_fc_m" ] && [ "$_fc_m" != "${FLEET_MAIN:-}" ] && _fc_tr+=(--main "$_fc_m")
    done <<EOF_FC_REPOS
$(fleet_repos "$_fc_fleet" 2>/dev/null)
EOF_FC_REPOS
    unset _fc_r _fc_m
  fi
  [ "${_fc_tr_home:-0}" = 1 ] && _fc_tr+=(--home)
  if [ "${#_fc_tr[@]}" -gt 0 ]; then
    _fc_granted=$(sh "$BIN/fleet-trust.sh" grant ${_fc_tr[@]+"${_fc_tr[@]}"} "$PWD" 2>"${TMPDIR:-/tmp}/.fleet-trust.$$")
    _fc_rc=$?
    if [ -n "$_fc_granted" ]; then
      printf 'fleet-claude: pre-trusted %s in %s (trusted node, issue #2282)\n' "$(printf '%s' "$_fc_granted" | tr '\n' ' ')" "$(sh "$BIN/fleet-trust.sh" file)" >&2
    fi
    case "$_fc_rc" in 0|2|3) : ;; *) cat "${TMPDIR:-/tmp}/.fleet-trust.$$" >&2 ;; esac
    rm -f "${TMPDIR:-/tmp}/.fleet-trust.$$"
    unset _fc_granted _fc_rc
  fi
  unset _fc_tr _fc_tr_home
elif [ "${FLEET_PRETRUST:-1}" != 0 ] && [ -n "${FLEET_MAIN:-}" ] && [ -f "$BIN/fleet-trust.sh" ]; then
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
unset _fc_tr_args _fc_fleet

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
# FLEET_PICK_MODEL: this fleet's model, resolved here with its per-fleet overlay
# (fleet-account.sh re-sources only the global conf) — the account pick prefers
# one whose cap ledger leaves it free (issue #1073).
label="${FLEET_ACCOUNT_LABEL:-}"
[ "$_fc_sep" = 1 ] && label=''      # the proxy picks (issue #2412)
[ -n "$label" ] || [ "$_fc_sep" = 1 ] || label=$(FLEET_PICK_MODEL="${FLEET_MODEL-opus}" "$BIN/fleet-account.sh" active 2>/dev/null)
# --account pool with no pool account registered here (issue #1540): refuse rather
# than fall to this login's own subscription — the one thing the choice ruled out.
# (`local` with no local token file is the ambient login, which IS local.)
if [ -z "$label" ] && [ "${FLEET_ACCOUNT_CLASS:-}" = pool ] && [ "$_fc_sep" != 1 ]; then
  echo 'fleet-claude: --account pool, but no hub-pool account is registered on this login (fleet-account.sh list) — refusing to launch on its own subscription' >&2
  _fc_refused account; exit 1
fi
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
# Recommended: the shipped minimal worker set, ~/.claude/fleet/conf/mcp-worker.json
# (issue #1078; docs/INSTALL.md "MCP servers on demand").
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

# The fleet's own tool service (issue #1807, EPIC #1813 C5): every session mounts
# bin/fleet-mcp.py as the MCP server `fleet` — the same tools bin/fleet-codex.sh
# hands Codex — defined ONCE in conf/mcp-worker.json. Additive: it rides next to
# whatever FLEET_MCP_CONFIG chose (an allowlist, `none`, or unset = every server),
# and is not added twice when the allowlist IS that file. FLEET_MCP_BIN points the
# server at THIS install's bin/; FLEET_MCP_SERVER=1 tells the mod not to register
# its own three fallback tools under the same `fleet` name. FLEET_MCP=0, a
# caller's own MCP flags, or no file beside bin/ adds nothing (byte for byte).
unset FLEET_MCP_SERVER                                     # never inherit a parent's mount
_fc_mw="$BIN/../conf/mcp-worker.json"
if [ "${FLEET_MCP:-1}" != 0 ] && [ -f "$_fc_mw" ] && [ -f "$BIN/fleet-mcp.py" ]; then
  case " $* " in
    *" --mcp-config "*|*" --mcp-config="*|*" --strict-mcp-config "*) : ;;   # caller already chose
    *)
      export FLEET_MCP_BIN="$BIN" FLEET_MCP_SERVER=1
      # An allowlist that already names a `fleet` server (this file, or a copy a
      # repo extended — docs/INSTALL.md) mounts it; a second one would collide.
      case "${FLEET_MCP_CONFIG:-}" in
        ''|none) _fc_mwin='' ;;
        '{'*)    _fc_mwin="$FLEET_MCP_CONFIG" ;;
        *)       _fc_mwin=$(cat "${FLEET_MCP_CONFIG/#\~/$HOME}" 2>/dev/null) ;;
      esac
      case "$_fc_mwin" in
        *'"fleet":'*|*'"fleet" :'*) : ;;
        *) mcp_flag+=("--mcp-config=$_fc_mw") ;;               # the =form (#476, above)
      esac
      unset _fc_mwin
      ;;
  esac
fi
unset _fc_mw

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
_fc_route=''
if [ -n "${FLEET_CRED_SID:-}" ]; then
  _fc_px=$(bash "$BIN/fleet-session-cred.sh" mint --provider claude --sid "$FLEET_CRED_SID" ${label:+--account "$label"})
  _fc_rc=$?
  case "$_fc_rc" in
    0)
      IFS=$'\t' read -r _fc_route _fc_port _fc_cred <<< "$_fc_px"
      unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR
      unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
      export ANTHROPIC_BASE_URL="http://127.0.0.1:$_fc_port" CLAUDE_CODE_OAUTH_TOKEN="$_fc_cred"
      export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
      unset _fc_cred _fc_port
      if [ -n "${TMUX_PANE:-}" ]; then
        tmux set-option -w -t "$TMUX_PANE" @cred_route "$_fc_route" 2>/dev/null || true
        if [ "$_fc_sep" = 1 ]; then tmux set-option -wu -t "$TMUX_PANE" @cc_account 2>/dev/null || true
        elif [ "$_fc_route" != central ]; then tmux set-option -w -t "$TMUX_PANE" @cc_account "$label" 2>/dev/null || true; fi
      fi ;;
    4) : ;;
    *) echo 'fleet-claude: FLEET_CRED_PROXY=1 but no session credential could be had from the proxy — refusing to launch (fleet-cred-proxy.sh status; logs/cred-proxy.log)' >&2
       _fc_refused cred; exit 1 ;;
  esac
  unset _fc_px _fc_rc
fi

if [ -n "$label" ] && [ -z "$_fc_route" ]; then          # (resolved above, with the model)
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
    _fc_refused account; exit 1
  fi
fi

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

# The session's configuration, fixed at launch (issue #1782, EPIC #1776 C6).
# bin/fleet-agent-team.py composes fleet default < team < local NOW — not whatever
# the last sync happened to leave in the files — and hands exactly what the login's
# files lack: a --settings file (missing fleet hooks by identity, missing
# fleet-managed keys; --settings outranks user AND project settings, so a key a
# project sets is never filled) and a --mcp-config file (missing fleet servers;
# never under a FLEET_MCP_CONFIG allowlist or a caller's own MCP flags — the
# allowlist governs). Locked items (conf/agent-locked.list: mod, fleet hooks, fleet
# MCP) follow FLEET_AGENT_LOCK: warn (default) uses the login's own value and says
# so on one stderr line; enforce hands the fleet's. The composed result's
# fingerprint lands on the window as @agent_cfg (+ @agent_cfg_src: each layer's
# version) — what C7 (#1783) compares against global/agent-cfg.expected. Both
# files are content-addressed, so concurrent launches share them. FLEET_AGENT_CFG=0
# or no composer beside bin/ (a lib-less install, a selftest sandbox) adds nothing:
# the argv is byte for byte what it was.
cfg_flag=()
if [ "${FLEET_AGENT_CFG:-1}" != 0 ] && [ -f "$BIN/fleet-agent-team.py" ] && command -v python3 >/dev/null 2>&1; then
  _fc_ca=(--lock "${FLEET_AGENT_LOCK:-warn}")
  [ -n "${FLEET_MCP_CONFIG:-}" ] && _fc_ca+=(--no-mcp)
  case " $* " in *" --mcp-config "*|*" --mcp-config="*|*" --strict-mcp-config "*) _fc_ca+=(--no-mcp) ;; esac
  case " $* " in *" --settings "*|*" --settings="*) _fc_ca+=(--no-settings) ;; esac
  if command -v fleet_mod_on >/dev/null 2>&1 && ! fleet_mod_on; then _fc_ca+=(--mod-off); fi
  _fc_fp=''; _fc_src=''; _fc_ver=''; _fc_man=''; _fc_modw=''; _fc_locks=''; _fc_say=''
  while IFS=$'\t' read -r _fc_k _fc_v; do
    case "$_fc_k" in
      fp)       _fc_fp="$_fc_v" ;;
      src)      _fc_src="$_fc_v" ;;
      ver)      _fc_ver="$_fc_v" ;;
      manifest) _fc_man="$_fc_v" ;;
      say)      _fc_say="$_fc_v" ;;
      mod)      _fc_modw="$_fc_v" ;;
      mcp)      cfg_flag+=("--mcp-config=$_fc_v") ;;      # the =form: --mcp-config is variadic (see above)
      settings) cfg_flag+=("--settings=$_fc_v") ;;
      lock)     _fc_locks="${_fc_locks:+$_fc_locks; }$_fc_v" ;;
      note)     printf 'fleet-claude: %s (issue #1862)\n' "$_fc_v" >&2 ;;   # the personal layer written badly
      hint)     printf 'fleet-claude: 本机新加了 %s — 要带到别的机器：fleet config %s\n' "${_fc_v#promote }" "$_fc_v" >&2 ;;   # said once (issue #1863)
    esac
  done < <(FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}" \
             python3 "$BIN/fleet-agent-team.py" session claude ${_fc_ca[@]+"${_fc_ca[@]}"} 2>/dev/null)
  # enforce on a locked mod: FLEET_MOD=0 is ignored, the mod loads anyway
  if [ "$_fc_modw" = on ] && [ "${#mod_flag[@]}" -eq 0 ] && command -v fleet_mod_dir >/dev/null 2>&1; then
    _fc_mod=$(fleet_mod_dir 2>/dev/null) && mod_flag=("--plugin-dir=$_fc_mod")
    unset _fc_mod
  fi
  # where this session's configuration comes from, in the person's words (EPIC
  # #1855 C6): the composer's `status --short` line, reprinted — only with a
  # personal layer, so a login without one launches byte for byte as before
  [ -n "$_fc_say" ] && printf 'fleet-claude: 配置 %s\n' "$_fc_say" >&2
  [ -n "$_fc_locks" ] && printf 'fleet-claude: locked agent config overridden on this login: %s (issue #1782)\n' "$_fc_locks" >&2
  if [ -n "$_fc_fp" ] && [ -n "${TMUX_PANE:-}" ]; then
    tmux set-option -w -t "$TMUX_PANE" @agent_cfg "$_fc_fp" 2>/dev/null || true
    tmux set-option -w -t "$TMUX_PANE" @agent_cfg_src "$_fc_src" 2>/dev/null || true
    # the fleet version it runs (issue #1895): differs from the expected ver ⇒ 待换新
    if [ -n "$_fc_ver" ]; then tmux set-option -w -t "$TMUX_PANE" @agent_ver "$_fc_ver" 2>/dev/null || true
    else tmux set-option -wu -t "$TMUX_PANE" @agent_ver 2>/dev/null || true; fi
    # what it started with (issue #2076): fleet-oldcfg-check.sh reads it to tell a
    # session a release BREAKS (会坏·需重开) from one that only lacks a new feature
    if [ -n "$_fc_man" ]; then tmux set-option -w -t "$TMUX_PANE" @agent_cfg_manifest "$_fc_man" 2>/dev/null || true
    else tmux set-option -wu -t "$TMUX_PANE" @agent_cfg_manifest 2>/dev/null || true; fi
  fi
  unset _fc_ca _fc_fp _fc_src _fc_ver _fc_man _fc_modw _fc_locks _fc_say _fc_k _fc_v
fi

# The binary (issue #1774): $FLEET_CLAUDE_BIN, else `claude` when PATH has it (the
# argv byte for byte as before), else ~/.local/bin → /opt/homebrew/bin →
# /usr/local/bin. Nowhere → one line naming every place tried, and exit 127.
_fc_claude=claude
if command -v fleet_find_tool >/dev/null 2>&1; then
  _fc_claude=$(fleet_find_tool claude) || exit 127
fi
if [ -n "${FLEET_LOOP_SPEC:-}" ] && [ "${FLEET_LOOP_AGENT:-}" = claude ]; then
  exec python3 "$BIN/fleet-loop.py" bridge -- "$_fc_claude" ${model_flag[@]+"${model_flag[@]}"} ${mcp_flag[@]+"${mcp_flag[@]}"} ${mod_flag[@]+"${mod_flag[@]}"} ${cfg_flag[@]+"${cfg_flag[@]}"} "$@"
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
exec ${_fc_relay[@]+"${_fc_relay[@]}"} "$_fc_claude" ${model_flag[@]+"${model_flag[@]}"} ${mcp_flag[@]+"${mcp_flag[@]}"} ${mod_flag[@]+"${mod_flag[@]}"} ${cfg_flag[@]+"${cfg_flag[@]}"} "$@"
