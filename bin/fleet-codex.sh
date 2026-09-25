#!/bin/bash
# fleet-codex.sh — launch OpenAI Codex CLI as a fleet session (issue #547).
#
# bin/fleet-claude.sh is the single door every spawn / restore / migrate walks
# through; with FLEET_AGENT=codex (or a caller's `--agent codex`) it hands the
# whole launch to THIS script instead of `exec claude`. Same contract: run in the
# pane the spawner created (cwd = the issue-<N> / scratch-<N> worktree, $TMUX_PANE
# set), take the seed prompt as the LAST positional, and run the agent. The
# launcher waits for normal CLI exit to apply the shared close-on-exit policy.
#
# What Codex needs translated — everything else in the worker path is agent-
# agnostic (the worktree, the @issue binding, claim-at-spawn, the PR map, the
# cleanup daemon, the session cap):
#
#   * The seed is a bare SLASH COMMAND (`/fleet-claim`, issue #299) because Claude
#     Code expands one supplied as the initial prompt. Modern Codex has native
#     skills under $CODEX_HOME/skills, invoked as `$name`, so a `/name [args]`
#     seed becomes `$name [args]` when the installed Codex home carries that skill.
#     Older Codex builds — or a home that has not been synced yet — still get the
#     historic prose expansion from conf/codex-preamble.md + commands/name.md.
#     The lifecycle text stays single-sourced in commands/; a non-slash prompt
#     passes through verbatim.
#   * Hooks. Codex's hook system IS Claude Code's schema (verified on codex-cli
#     0.154: the same event names, the same stdin JSON — `tool_name` "Bash" with
#     `tool_input.command`, "apply_patch" with the patch text in `command` — exit 2
#     blocks, and the hook inherits the pane env, $TMUX_PANE included). So the
#     fleet's own hooks ride along inline as `-c hooks.<Event>=[…]`, resolved to
#     THIS install's paths: PreToolUse → `busy` + bash-guard.py (Bash) +
#     base-readonly-guard.py (apply_patch); PostToolUse / UserPromptSubmit →
#     `working`; Stop → `done`. That is what colours a Codex window on the dash
#     and keeps the two bypass-permissions rails (issue #355). SessionStart and
#     SessionEnd emit lifecycle facts. The Claude handoff latch reset remains
#     excluded; the screen classifier supports both agents.
#     Codex reports `reason=other` for thread ends,
#     so window cleanup follows a successful CLI process exit instead (#730).
#     Hooks need persisted trust in Codex; the fleet vets its own, so
#     --dangerously-bypass-hook-trust.
#   * Posture: --dangerously-bypass-approvals-and-sandbox — the same footing as a
#     bypassPermissions Claude worker (nobody is watching a fleet pane to approve;
#     the hooks are the rails). A stricter workspace-write sandbox is a follow-up
#     (issue #548): it may also fence AF_UNIX (the tmux socket every fleet script
#     talks to) and the worktree's `.git` gitdir under the base checkout, and
#     `codex sandbox` could not be driven here to prove either way.
#   * Project doc: Codex reads AGENTS.md; `project_doc_fallback_filenames` makes
#     it read a repo's CLAUDE.md when there is no AGENTS.md.
#   * Model: FLEET_CODEX_MODEL → `-m` (Codex names ≠ Claude aliases, so FLEET_MODEL
#     never applies); empty defers to ~/.codex/config.toml. Stamped as @cc_model.
#   * Skipped on purpose: --model / FLEET_MODEL + the per-model cap fallback,
#     Claude --mcp-config flags, CLAUDE_CODE_SUBAGENT_MODEL, and the
#     CLAUDE_CODE_OAUTH_TOKEN token rotation. Codex uses its own home-based pool.
#   * Project trust: Codex prompts once per project; a worktree inherits its main
#     repo's trust, so the fleet needs $FLEET_MAIN trusted in ~/.codex/config.toml
#     (one-time). The launcher pre-reads it and flags an untrusted base on the dash
#     (`needs`) rather than letting the first pane stall silently — see below.
#   * Stamps @cc_agent=codex on the window so the dash can tag it and the Claude-
#     only tooling (migrate) can tell it apart; a Claude window
#     carries no @cc_agent, so the default fleet is unchanged.
#
# --- CAPABILITY MATRIX · SOURCE OF TRUTH (issue #608) -------------------------
# Everything above is the WHY; the block below is the public, per-capability
# grading — and it lives HERE, next to the code it describes, so it cannot quietly
# stop matching the launcher. README.md's "Agents: Claude Code and Codex" table is
# a RENDER of this block: `bin/codex-matrix.sh` prints the markdown, `--write`
# re-renders the README in place, `--check` fails on drift, and
# bin/codex-matrix-selftest.sh runs that check in CI alongside assertions that the
# verdicts still match the flags this script actually sets. Edit a row here, then
# run `bin/codex-matrix.sh --write` — never edit the README table by hand.
#
# Grading rule (issue #608): a ❌ says WHICH kind of gap it is. "Codex has no such
# mechanism" and "the mechanism exists, we have not adapted it" are different
# claims, and collapsing them into one shrug is the dishonesty this matrix exists
# to avoid. Cells are ` | `-separated, so no cell may contain a pipe.
#
# MATRIX-BEGIN
# Capability | Claude Code | Codex | Why
# worktree per task · `@issue` binding · claim-at-spawn · PR/CI map · cleanup · session caps | ✅ | ✅ | Not agent code at all — `git`, `gh` and tmux window options. The whole worker path is agent-agnostic.
# hook state signals → dash colours (busy / working / done) | ✅ | ✅ | Codex's hook system *is* Claude Code's schema — same event names, same stdin JSON, `exit 2` blocks, `$TMUX_PANE` inherited (measured on codex-cli 0.154). This launcher inlines the fleet's own hooks as `-c hooks.<Event>=[…]`.
# bypass-permissions guardrails (bash-guard · base-checkout read-only) | ✅ | ✅ | `--dangerously-bypass-approvals-and-sandbox` + `--dangerously-bypass-hook-trust`; the base-checkout guard matches `apply_patch` on Codex where Claude matches Edit/Write/MultiEdit.
# session keeps ONE language (non-English sessions stay non-English) | ✅ | ✅ | `bin/fleet-claim-brief.sh` ends every worker's preamble with the seed rule, and every text the fleet injects later (resume nudge, quota warning, child report, auto-handoff directive) carries its own — one English sentence per injection point instead of a translated nudge per language (issue #620, `bin/fleet-lang.sh`). Codex additionally has the rule in `conf/codex-preamble.md`, where it originated.
# project instructions file | `CLAUDE.md` | `AGENTS.md` | `-c project_doc_fallback_filenames=["CLAUDE.md"]` makes a Codex worker read this repo's `CLAUDE.md` when it has no `AGENTS.md`.
# worker model pinned at spawn | `FLEET_MODEL` | `FLEET_CODEX_MODEL` | Two knobs on purpose: Codex model names are not Claude aliases, so `FLEET_MODEL` never reaches a Codex pane.
# transferred recurring loop | Fleet adapter / native `/loop` | Fleet adapter | Active Fleet loops keep their ID, cadence and ownership generation across agent/account transfers. Codex uses private RPC; Claude inbox delivery requires transcript acknowledgement. Exact crash restore can reattach active owners; stopped or ambiguous deliveries never replay. Calendar cron is not converted.
# fleet command seed (`/fleet-claim`) | native | native | Claude Code expands `/fleet-claim`; Codex invokes the installed `$fleet-claim` skill from `$CODEX_HOME/skills/fleet-claim/SKILL.md`. If an old Codex build has no skills, or that home has not been synced, the launcher falls back to the prose expansion.
# per-repo trust prompt | pre-granted | one manual Yes | `bin/fleet-trust.sh` pre-answers Claude's dialog. Codex persists trust in `~/.codex/config.toml` and no flag or `-c` override satisfies it, so the base checkout needs one manual Yes; the launcher pre-reads it and turns the pane red rather than letting the first spawn stall silently.
# red `needs` + bell when a session is blocked on you | ✅ | ✅ | The private-server monitor reads native waitingOnUserInput/waitingOnApproval flags and marks the exact launcher/thread. No Notification hook is needed. Resolved native attention clears only its own subtype; explicit worker blockers survive.
# `AskUserQuestion` + the dash’s answer key | ✅ | ✅ | Codex has native request_user_input. The dashboard replies to the replayed server request, including choices and free text; exact launcher/thread/request fingerprints prevent stale answers. Esc sends nothing; native resolution confirms completion.
# permission prompts readable + refusable from the dash | ✅ | ✅ | Native command/file/additional-permission and MCP requests are readable. fleet-permission.sh --deny sends only the native refusal, requires the displayed request token and the existing opt-in. Default bypass posture normally suppresses command/file prompts; no approval is automated.
# close the window when the operator exits the agent | ✅ | ✅ | The Codex launcher waits for a successful CLI exit, then calls the shared close-on-exit policy. Dirty/unmerged work survives, hubs/panels are excluded, and the global `FLEET_CLOSE_ON_EXIT=0` opt-out applies. Failed launches stay visible; thread `SessionEnd(reason=other)` never closes a window.
# session lifecycle events | ✅ | ✅ | Both agents emit `session.start` and `session.end` through the shared hook table. Codex thread lifecycle events are separate from process-exit window cleanup.
# `/fleet-handoff` + the auto-handoff nudge | ✅ | ✅ | Codex runs `fleet-transfer.sh --to codex --handoff NOTES --after-turn` directly. The same clean-Stop, typing hold, lease and source-identity checks preserve notes, exact rollout, account home and worktree before a fresh conversation. `FLEET_AUTO_HANDOFF_PCT` nudges this native path.
# `/fleet-context` + the dash's ctx % | ✅ | ✅ | Run `fleet-context.sh` directly on Codex. SessionStart binds the exact root UUID, launcher lifetime and CODEX_HOME; rollout token telemetry supplies the current model/window. Missing data stays unknown; no Claude transcript or default denominator is reused.
# peer messages + child reports | ✅ | ✅ | Fleet pane launches give each worker a private local app-server. `codex queue` reaches that exact endpoint, UUID and CODEX_HOME; failed delivery is never stamped as success. A guardian shuts down the owned server even if the launcher is killed. `FLEET_CODEX_SERVER=0` opts back into embedded mode without live queue delivery.
# peer tools (`list_agents` / `send_message`) | native | fleet-peer MCP | Claude has native `ListAgents` / `SendMessage`; the shipped `conf/mcp-worker.json` mounts fleet-peer so Codex workers get tool-shaped equivalents backed by `fleet-children.sh`, tmux window options and `fleet-peer-send.sh`.
# Stop classifier (haiku) | ✅ | ✅ | The shared optional helper now uses an agent-aware rubric, including Codex placeholders. Codex Stop invokes it; exact native attention and explicit worker blockers outrank screen inference. Slow verdicts cannot replace a newer launcher or hook state.
# `--resume` paths (restore · migrate · `/fleet-history`) | ✅ | ✅ | Crash snapshots and history retain the exact Codex UUID, CODEX_HOME and rollout. Native resume/fork stays in that home; account migration uses a durable packet to start fresh in a different home with source recovery preserved.
# multi-account rotation + native quota collector | ✅ | ✅ | Register independent CODEX_HOME directories and select fresh launches by native quota headroom. Windows/reset times are reported by Codex. Unknown data stays unknown; gating and idle-only protected account migration are separate opt-ins.
# subscription failover across Coding Agents | opt-in | opt-in | `FLEET_FAILOVER=1` reuses fleet-account, ccquota, quotawatch and transfer: eligible same-agent subscription first, then the allowed other agent, otherwise durable waiting. Exact source paths, target authentication, unsent drafts and Fleet loops follow the task.
# per-model cap fallback (same thread) | ✅ | ✅ | Native thread/settings/update changes an idle Codex model and verifies it without keystrokes or restart. Opt-in fallback requires explicit model-to-limit IDs and fresh quota on both buckets. Only an exact native quota-failed turn receives a continuation.
# MCP servers + subagent model | ✅ | ✅ | `FLEET_MCP_CONFIG` translates stdio/HTTP allowlists — recommended value `~/.claude/fleet/conf/mcp-worker.json`, the minimal worker set shipped with the fleet (fleet-peer only: `list_agents` / `send_message`, issues #1078/#1185); `FLEET_CODEX_MCP_CONFIG` also accepts native JSON/TOML. Strict policies disable inherited servers and apps. Codex subagent model/effort use separate native knobs; explicit caller overrides win. Both TUI and private server receive the policy.
# warm scratch pool | ✅ | ✅ | A Codex-specific stable-screen probe checks the current launcher, echoes and clears one unsubmitted character, and never makes a model request. Claims require the matching agent, account home, dimensions and age; startup/trust failures use the cold path.
# MATRIX-END
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"     # also sources the sibling global fleet.conf
# shellcheck source=/dev/null
[ -f "$ROOT/fleet.conf" ] && . "$ROOT/fleet.conf"       # kept for a lib-less install
# Per-fleet overlay (issue #472) — same as fleet-claude.sh: the spawned pane does
# not inherit the spawner's env, so read the fleet's conf from $TMUX_PANE's session.
if command -v fleet_load_conf >/dev/null 2>&1; then
  _fx_sess="$(fleet_current_session 2>/dev/null)"
  # A holding session uses the owning fleet's overlay before it is claimed.
  if [ -n "${FLEET_LAUNCH_SESSION:-}" ] && [ "$_fx_sess" = "${FLEET_LAUNCH_SESSION}-pool" ]; then
    _fx_sess="$FLEET_LAUNCH_SESSION"
  fi
  [ -n "$_fx_sess" ] && fleet_load_conf "$_fx_sess"
  unset _fx_sess
fi

if ! command -v codex >/dev/null 2>&1; then
  printf 'fleet-codex: FLEET_AGENT=codex but `codex` is not on PATH — install OpenAI Codex CLI (npm i -g @openai/codex) and `codex login`, or set FLEET_AGENT back to claude.\n' >&2
  exit 127
fi

# Fleet recovery callers carry the provider and account home explicitly. Convert
# the shared resume spelling before parsing the final seed; native resume/fork
# positional forms still pass through unchanged.
normal=(); resume_id=''; fork_session=0; _codex_home_explicit=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex-profile)
      [ "$#" -ge 2 ] || { echo 'fleet-codex: --codex-profile requires a ccquota profile' >&2; exit 2; }
      export FLEET_CODEX_PROFILE="$2"; shift 2 ;;
    --codex-home)
      [ "$#" -ge 2 ] && [ -d "$2" ] || { echo 'fleet-codex: recorded CODEX_HOME is missing' >&2; exit 2; }
      export CODEX_HOME="$2"; _codex_home_explicit=1; shift 2 ;;
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
if [ "$_codex_home_explicit" = 0 ] && [ -z "${FLEET_CODEX_PROFILE:-}" ] && [ -n "${FLEET_CODEX_HOME:-}" ]; then
  [ -d "$FLEET_CODEX_HOME" ] || { echo 'fleet-codex: FLEET_CODEX_HOME is missing' >&2; exit 2; }
  export CODEX_HOME="$FLEET_CODEX_HOME"
  if [ -z "$_codex_resuming" ] && [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
    FLEET_CONF_DIR="$FLEET_CONF_DIR" FLEET_CODEX_HOME="$CODEX_HOME" FLEET_CODEX_QUOTA_GATE=1 \
      FLEET_CODEX_MODEL_LIMIT_IDS="${FLEET_CODEX_MODEL_LIMIT_IDS:-}" \
      FLEET_CODEX_MODEL="${FLEET_CODEX_MODEL:-}" FLEET_CODEX_QUOTA_FLOOR="${FLEET_CODEX_QUOTA_FLOOR:-5}" \
      FLEET_CODEX_QUOTA_TTL="${FLEET_CODEX_QUOTA_TTL:-300}" python3 "$BIN/fleet-codex-account.py" gate || exit 2
  fi
elif [ "$_codex_home_explicit" = 0 ] && [ -z "${FLEET_CODEX_PROFILE:-}" ] && [ -z "$_codex_resuming" ] && [ -n "${FLEET_CODEX_ACCOUNTS:-}" ]; then
  # Recovery identity is authoritative. Only fresh launches choose a pool home.
  # Pass the already-resolved overlay; a pool session has no overlay of its own.
  CODEX_HOME=$(FLEET_CONF_DIR="$FLEET_CONF_DIR" FLEET_CODEX_ACCOUNTS="$FLEET_CODEX_ACCOUNTS" \
    FLEET_CODEX_MODEL_LIMIT_IDS="${FLEET_CODEX_MODEL_LIMIT_IDS:-}" \
    FLEET_CODEX_MODEL="${FLEET_CODEX_MODEL:-}" FLEET_CODEX_QUOTA_GATE="${FLEET_CODEX_QUOTA_GATE:-0}" \
    FLEET_CODEX_QUOTA_FLOOR="${FLEET_CODEX_QUOTA_FLOOR:-5}" FLEET_CODEX_QUOTA_TTL="${FLEET_CODEX_QUOTA_TTL:-300}" \
    python3 "$BIN/fleet-codex-account.py" select) || exit 2
  export CODEX_HOME
fi
if [ -n "$resume_id" ]; then
  verb=resume; [ "$fork_session" = 1 ] && verb=fork
  set -- "$verb" "$resume_id" ${normal[@]+"${normal[@]}"}
else
  [ "$fork_session" = 0 ] || { echo 'fleet-codex: --fork-session requires --resume' >&2; exit 2; }
  set -- ${normal[@]+"${normal[@]}"}
fi

# Use ccquota's shared run lock and official isolated credential environment for
# the entire launcher/app-server/TUI lifetime. Do not change its global default.
if [ "${FLEET_FAILOVER:-0}" = 1 ] && [ -z "${FLEET_CODEX_PROFILE:-}" ]; then
  _profile=$(bash "$BIN/fleet-account.sh" profile --home "${CODEX_HOME:-$HOME/.codex}") || exit 1
  FLEET_CODEX_PROFILE=$(printf '%s' "$_profile" | python3 -c 'import json,sys; print(json.load(sys.stdin)["profile"])') || exit 1
  export FLEET_CODEX_PROFILE
fi
if [ -n "${FLEET_CODEX_PROFILE:-}" ]; then
  if [ "${FLEET_CODEX_MANAGED:-0}" != 1 ]; then
    export FLEET_CODEX_MANAGED=1
    # ccquota's default profile is machine-local, not the invoking pane's home.
    unset CODEX_HOME
    exec "${FLEET_QUOTA_BIN:-ccquota}" codex --codex-bin "$BIN/fleet-codex.sh" run "$FLEET_CODEX_PROFILE" -- "$@"
  fi
  FLEET_CODEX_SUBSCRIPTION=$(bash "$BIN/fleet-account.sh" profile --name "$FLEET_CODEX_PROFILE" \
    --home "${CODEX_HOME:-$HOME/.codex}" --account "${FLEET_CODEX_ACCOUNT:-}") || exit 1
  export FLEET_CODEX_SUBSCRIPTION
fi

# --- argv: the LAST argument is the seed prompt unless it looks like a flag ----
# Every fleet caller puts the prompt last (`fleet-claude.sh "$(cat task)"`); flags
# before it pass through to codex untouched (a caller that says `--agent codex`
# means codex flags). A last arg that starts with `-` is a flag, not a prompt.
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

# --- convert a `/name [args]` seed to a native Codex skill when available -------
codex_skills_supported() {
  case "${FLEET_CODEX_NATIVE_SKILLS:-auto}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  command -v codex >/dev/null 2>&1 || return 1
  # codex-cli 0.157 exposes the model-visible skill list through this debug read.
  # Old builds lack the subcommand; failures mean "use the historic expansion".
  codex debug prompt-input '$fleet-context' 2>/dev/null | grep -q '<skills_instructions>'
}
native_slash() {
  local p="$1" name rest home
  case "$p" in /*) : ;; *) return 1 ;; esac
  name="${p%%[[:space:]]*}"; name="${name#/}"
  case "$name" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  rest="${p#/"$name"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"       # trim leading whitespace
  home="${CODEX_HOME:-$HOME/.codex}"
  [ -r "$home/skills/$name/SKILL.md" ] || return 1
  codex_skills_supported || return 1
  EXPANDED="\$$name${rest:+ $rest}"
  return 0
}

# --- expand a `/name [args]` seed into prose (old Codex / unsynced home) -------
# Sets EXPANDED; returns 1 (prompt untouched) when it isn't a slash command or the
# skill file is missing — then the literal text is still handed to codex, and a
# one-line note says why, so a typo'd skill name is visible in the pane.
expand_slash() {
  local p="$1" name rest f body pre
  case "$p" in /*) : ;; *) return 1 ;; esac
  name="${p%%[[:space:]]*}"; name="${name#/}"
  case "$name" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  rest="${p#/"$name"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"       # trim leading whitespace
  f="$ROOT/commands/$name.md"
  if [ ! -r "$f" ]; then
    printf 'fleet-codex: no commands/%s.md to expand — passing the prompt through verbatim\n' "$name" >&2
    return 1
  fi
  body=$(cat "$f")
  body="${body//\$ARGUMENTS/$rest}"
  pre=$(cat "$ROOT/conf/codex-preamble.md" 2>/dev/null)
  [ -n "$pre" ] || pre='You are a claude-fleet WORKER running on OpenAI Codex CLI. The text below is a Claude Code skill: slash commands and Claude-only tools (AskUserQuestion, SendMessage, Artifact, /fleet-handoff, /fleet-context) are not available to you — run the shell scripts it names directly, never wait on the operator, and every rail (worktree-only edits, no destructive tmux, land your own PR) applies unchanged.'
  EXPANDED="$pre"$'\n\n'"$body"
  return 0
}
if [ "$have_prompt" = 1 ]; then
  EXPANDED=''
  if native_slash "$prompt"; then
    prompt="$EXPANDED"
  elif expand_slash "$prompt"; then
    prompt="$EXPANDED"
  fi
fi

# --- hooks, inline (Codex reads `-c hooks.<Event>=[…]` as TOML) ----------------
# DERIVED, not hand-written (issue #611). This block used to carry its own copy of
# the fleet's hook table, transcoded to TOML by hand — a second source that could
# (and did) drift from hooks/settings-hooks.json. Now bin/fleet-hooks-emit.sh
# materializes the ONE table for the codex target, applying the declared Codex
# delta (hooks/codex-map.json): which events Codex has, `Edit|Write|MultiEdit|
# NotebookEdit` → `apply_patch`, no Artifact tool, no Claude handoff/exit hooks.
# Resolved against THIS install (--root defaults to it), so a selftest or a
# re-homed install wires its own copies.
#
# Read as TAB-separated `<Event>\t<toml>` lines into the flag array below. A
# failure here is NOT fatal: Codex still launches, just without the dash colours —
# far better than refusing to spawn a worker over a hook table.
hook_flags=()
_hook_emit="$BIN/fleet-hooks-emit.sh"
if [ -x "$_hook_emit" ]; then
  while IFS=$'\t' read -r _ev _toml; do
    [ -n "$_ev" ] && [ -n "$_toml" ] && hook_flags+=(-c "hooks.$_ev=$_toml")
  done < <("$_hook_emit" --target codex --root "$ROOT" 2>/dev/null)
fi
if [ "${#hook_flags[@]}" -eq 0 ]; then
  printf 'fleet-codex: could not materialise the hook table from %s — launching WITHOUT\n' "$ROOT/hooks/settings-hooks.json" >&2
  printf 'fleet-codex: hooks: this window will not colour on the dash and the two bypass-permissions\n' >&2
  printf 'fleet-codex: guards (bash-guard / base-readonly-guard) are NOT wired for it.\n' >&2
fi
# The base-checkout guard resolves FLEET_MAIN from the env first (free) and only
# then via fleet-lib + $TMUX; export what the overlay resolved so the hook never
# has to.
[ -n "${FLEET_MAIN:-}" ] && export FLEET_MAIN

# --- project trust: Codex asks "Do you trust the contents of this directory?" ---
# for a project it has not seen, and a fleet pane has NOBODY to press Enter — the
# worker would sit on that prompt forever, reading `done` on the dash. Verified on
# 0.154: the prompt comes regardless of -a/-s/--dangerously-bypass flags, a `-c
# projects.….trust_level` override does NOT satisfy it (trust is persisted state in
# $CODEX_HOME/config.toml), and a git WORKTREE inherits the trust of its MAIN repo.
# So the one thing this fleet needs is the BASE CHECKOUT ($FLEET_MAIN) trusted,
# once per repo (`codex` in $FLEET_MAIN → "Yes"). This launcher never edits the
# operator's config; it pre-reads it and, when the base is not trusted, says so in
# the pane and stamps the window `needs` (red on the dash) so the one keypress the
# first spawn needs is visible instead of a silent stall. Best-effort: a missing /
# unreadable config just skips the check — Codex itself is still the authority.
_trust_root=''
[ -n "${FLEET_MAIN:-}" ] && _trust_root=$(cd "$FLEET_MAIN" 2>/dev/null && pwd -P)
_codex_conf="${CODEX_HOME:-$HOME/.codex}/config.toml"
if [ -n "$_trust_root" ] && [ -r "$_codex_conf" ] \
   && ! awk -v h="[projects.\"$_trust_root\"]" '
        $0 == h { t = 1; next }
        /^[[:space:]]*\[/ { t = 0 }
        t && /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"trusted"/ { f = 1 }
        END { exit(f ? 0 : 1) }' "$_codex_conf"; then
  printf '\nfleet-codex: the base checkout %s is not trusted in %s — Codex will ask\n' "$_trust_root" "$_codex_conf" >&2
  printf 'fleet-codex: "Do you trust the contents of this directory?" below. Answer 1 (Yes) ONCE: Codex\n' >&2
  printf 'fleet-codex: persists it for the repo, and every issue-<N>/scratch-<N> worktree inherits it.\n\n' >&2
  # </dev/null: the stamper's `needs` path reads a hook payload off a non-tty
  # stdin; give it EOF so it can never sit on an inherited descriptor.
  [ -n "${TMUX_PANE:-}" ] && sh "$BIN/set-claude-state.sh" needs </dev/null >/dev/null 2>&1
fi
unset _trust_root _codex_conf

flags=(
  --dangerously-bypass-hook-trust
  -c 'features.hooks=true'
  -c 'project_doc_fallback_filenames=["CLAUDE.md"]'
  ${hook_flags[@]+"${hook_flags[@]}"}
)
# Remote resume retains the native thread's permission policy and rejects CLI
# permission overrides. Only a fresh thread needs Fleet's initial full access.
[ -n "$_codex_resuming" ] || flags=(--dangerously-bypass-approvals-and-sandbox ${flags[@]+"${flags[@]}"})

# --- model: FLEET_CODEX_MODEL → -m, unless the caller already chose one ---------
launch_model=''
if [ -n "${FLEET_CODEX_MODEL:-}" ]; then
  case " ${pass[*]+"${pass[*]}"} " in
    *" -m "*|*" --model "*|*" --model="*) : ;;
    *) launch_model="$FLEET_CODEX_MODEL"; flags+=(-m "$launch_model") ;;
  esac
fi

# Native Codex policy. Fleet defaults precede the caller's -c overrides; the
# runtime sends the same effective flags to the app-server and the TUI.
_codex_mcp="${FLEET_CODEX_MCP_CONFIG-${FLEET_MCP_CONFIG:-}}"
_codex_subagent="${FLEET_CODEX_SUBAGENT_MODEL-${launch_model:-}}"
if [ -n "$_codex_mcp$_codex_subagent${FLEET_CODEX_SUBAGENT_EFFORT:-}" ] && [ -f "$BIN/fleet-codex-policy.py" ]; then
  _policy=$(FLEET_CODEX_MCP_CONFIG="$_codex_mcp" FLEET_CODEX_SUBAGENT_MODEL="$_codex_subagent" \
    FLEET_CODEX_SUBAGENT_EFFORT="${FLEET_CODEX_SUBAGENT_EFFORT:-}" \
    python3 "$BIN/fleet-codex-policy.py" -- "$@") || exit 2
  while IFS= read -r _value; do
    [ -z "$_value" ] || flags+=(-c "$_value")
  done <<< "$_policy"
fi
unset _codex_mcp _codex_subagent _policy _value

# --- version drift: warn once per launch, never block (issue #1079) ------------
# fleet reads context% from Codex's rollout file, a format verified only on the
# versions in fleet-codex-runtime.py. An unverified version launches anyway (the
# operator's call: warn, don't block) — one stderr line, and the same line rides
# FLEET_CODEX_VERSION_WARNING into the SessionStart hook, which records it in
# @codex_identity as `version_warning`. The ccquota relaunch above execs BEFORE
# this point, so a launch checks once. FLEET_CODEX_VERSION_CHECK=0 = off.
unset FLEET_CODEX_VERSION_WARNING   # never inherit a parent's verdict
if [ "${FLEET_CODEX_VERSION_CHECK:-1}" != 0 ] && [ -f "$BIN/fleet-codex-runtime.py" ]; then
  _vline=$(python3 "$BIN/fleet-codex-runtime.py" version-check 2>/dev/null)
  if [ $? = 1 ]; then
    printf 'fleet-codex: warning: %s\n' "$_vline" >&2
    export FLEET_CODEX_VERSION_WARNING="$_vline"
  fi
  unset _vline
fi

# --- stamp THIS pane's window (issue #511: -t "$TMUX_PANE", never the current window)
export FLEET_CODEX_LAUNCHER_PID="$$"
export FLEET_CODEX_REMOTE=''
_remote_next=0
for a in ${pass[@]+"${pass[@]}"}; do
  if [ "$_remote_next" = 1 ]; then FLEET_CODEX_REMOTE="$a"; _remote_next=0; fi
  case "$a" in --remote) _remote_next=1 ;; --remote=*) FLEET_CODEX_REMOTE="${a#--remote=}" ;; esac
done
if [ -n "${TMUX_PANE:-}" ]; then
  tmux set-option -w -t "$TMUX_PANE" @cc_agent codex 2>/dev/null || true
  tmux set-option -w -t "$TMUX_PANE" @codex_home "${CODEX_HOME:-$HOME/.codex}" 2>/dev/null || true
  _acct=$(FLEET_CONF_DIR="$FLEET_CONF_DIR" python3 "$BIN/fleet-codex-account.py" label "${CODEX_HOME:-$HOME/.codex}" 2>/dev/null) || _acct=''
  tmux set-option -w -t "$TMUX_PANE" @cc_account "${_acct:+codex:$_acct}" 2>/dev/null || true
  tmux set-option -w -t "$TMUX_PANE" @cc_launcher_pid "$$" 2>/dev/null || true
  # New ownership invalidates the old JSON even if the process died before its
  # SessionEnd. Clear visible context too; the first root hook supplies truth.
  for _opt in @codex_identity @codex_session_id @codex_attention @ctx_pct @ctx_limit @cc_model @handoff_armed; do
    tmux set-option -wu -t "$TMUX_PANE" "$_opt" 2>/dev/null || true
  done
  [ -n "$launch_model" ] && tmux set-option -w -t "$TMUX_PANE" @cc_model "$launch_model" 2>/dev/null || true
fi

# Codex's SessionEnd reason is always `other`, including thread lifecycle ends
# that do NOT mean the operator quit this TUI. Wait for the CLI itself instead
# (issue #730). Only a successful exit closes the window; a failed launch/crash
# stays visible. The shared hook owns the opt-out, panel/hub guards, and reap
# policy. Its owner check prevents an old launcher closing a replacement session.
runner=(codex)
if [ -n "${FLEET_LOOP_SPEC:-}" ]; then
  # Recurring handoffs already own a private endpoint and scheduler.
  runner=(python3 "$BIN/fleet-loop.py" bridge --)
elif [ -n "${TMUX:-}" ] && [ "${FLEET_CODEX_SERVER:-1}" != 0 ] && [ -z "$FLEET_CODEX_REMOTE" ] \
   && [ -f "$BIN/fleet-codex-runtime.py" ]; then
  runner=(python3 "$BIN/fleet-codex-runtime.py" --)
fi
if [ "$have_prompt" = 1 ]; then
  "${runner[@]}" "${flags[@]}" ${pass[@]+"${pass[@]}"} "$prompt" # bash32-ok: runner and flags are always populated
else
  "${runner[@]}" "${flags[@]}" ${pass[@]+"${pass[@]}"} # bash32-ok: runner and flags are always populated
fi
rc=$?
if [ "$rc" = 0 ] && [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
   && [ -f "$BIN/session-end-hook.sh" ]; then
  bash "$BIN/session-end-hook.sh" --codex-exit "$$" </dev/null
fi
exit "$rc"
