#!/bin/bash
# fleet-codex.sh — launch OpenAI Codex CLI as a fleet session (issue #547).
#
# bin/fleet-claude.sh is the single door every spawn / restore / migrate walks
# through; with FLEET_AGENT=codex (or a caller's `--agent codex`) it hands the
# whole launch to THIS script instead of `exec claude`. Same contract: run in the
# pane the spawner created (cwd = the issue-<N> / scratch-<N> worktree, $TMUX_PANE
# set), take the seed prompt as the LAST positional, exec the agent.
#
# What Codex needs translated — everything else in the worker path is agent-
# agnostic (the worktree, the @issue binding, claim-at-spawn, the PR map, the
# cleanup daemon, the session cap):
#
#   * The seed is a bare SLASH COMMAND (`/fleet-claim`, issue #299) because Claude
#     Code expands one supplied as the initial prompt. Codex has no slash commands
#     — it takes a positional [PROMPT] — so a `/name [args]` seed is EXPANDED here
#     into prose: conf/codex-preamble.md (how to read a Claude Code skill as a
#     Codex agent: no /fleet-handoff, no AskUserQuestion, run the scripts) followed
#     by commands/name.md with `$ARGUMENTS` substituted. The lifecycle text stays
#     single-sourced in commands/; a non-slash prompt passes through verbatim.
#   * Hooks. Codex's hook system IS Claude Code's schema (verified on codex-cli
#     0.154: the same event names, the same stdin JSON — `tool_name` "Bash" with
#     `tool_input.command`, "apply_patch" with the patch text in `command` — exit 2
#     blocks, and the hook inherits the pane env, $TMUX_PANE included). So the
#     fleet's own hooks ride along inline as `-c hooks.<Event>=[…]`, resolved to
#     THIS install's paths: PreToolUse → `busy` + bash-guard.py (Bash) +
#     base-readonly-guard.py (apply_patch); PostToolUse / UserPromptSubmit →
#     `working`; Stop → `done`. That is what colours a Codex window on the dash
#     and keeps the two bypass-permissions rails (issue #355). NOT wired: the
#     Claude-only SessionStart handoff latch, the Stop classifier (reads a Claude
#     transcript), and SessionEnd close-on-exit — Codex reports `reason=other` for
#     EVERY end, so the matcher that tells a manual /exit from a /clear cannot
#     fire; the cleanup daemon + ledger-watch (poll path) reap a Codex window
#     instead. Hooks need persisted trust in Codex; the fleet vets its own, so
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
#     --mcp-config / FLEET_MCP_CONFIG, CLAUDE_CODE_SUBAGENT_MODEL, and the
#     CLAUDE_CODE_OAUTH_TOKEN account rotation (Codex auth is `codex login`).
#   * Project trust: Codex prompts once per project; a worktree inherits its main
#     repo's trust, so the fleet needs $FLEET_MAIN trusted in ~/.codex/config.toml
#     (one-time). The launcher pre-reads it and flags an untrusted base on the dash
#     (`needs`) rather than letting the first pane stall silently — see below.
#   * Stamps @cc_agent=codex on the window so the dash can tag it and the Claude-
#     only tooling (migrate, ctx, peer-send) can tell it apart; a Claude window
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
# slash-command seed (`/fleet-claim`) | native | translated | Codex has no slash commands — it takes a positional prompt, so the launcher expands `conf/codex-preamble.md` + `commands/<name>.md` into prose. The lifecycle text stays single-sourced in `commands/`.
# per-repo trust prompt | pre-granted | one manual Yes | `bin/fleet-trust.sh` pre-answers Claude's dialog. Codex persists trust in `~/.codex/config.toml` and no flag or `-c` override satisfies it, so the base checkout needs one manual Yes; the launcher pre-reads it and turns the pane red rather than letting the first spawn stall silently.
# red `needs` + bell when a session is blocked on you | ✅ | ❌ | **Codex has no `Notification` event.** 0.154's hook set is PreToolUse · PermissionRequest · PostToolUse · Pre/PostCompact · SessionStart · SessionEnd · UserPromptSubmit · SubagentStart/Stop · Stop · Interrupt — and its nearest analogue, `PermissionRequest`, cannot fire under the fleet's bypass posture. A Codex worker that stops to ask you something reads green `done`, like any finished turn.
# `AskUserQuestion` + the dash's ⌃k answer key | ✅ | ❌ | A Claude-only tool; `bin/fleet-answer.sh` answers it by driving that dialog's keystrokes. Codex has no equivalent dialog to drive.
# close the window when the operator exits the agent | ✅ | ❌ | Codex does fire `SessionEnd`, but reports `reason=other` for every end — it never emits Claude's `prompt_input_exit` / `logout` — so the matcher that tells a manual `/exit` from a `/clear` cannot fire. The cleanup daemon's poll reaps a Codex window instead: a minute later, not instantly.
# `/fleet-handoff` + the auto-handoff nudge | ✅ | ❌ | Reads Claude Code's `~/.claude/projects/**.jsonl` transcript and re-seeds the pane. Codex keeps its own rollout files — the mechanism is not missing on Codex, the adapter is.
# `/fleet-context` + the dash's ctx % | ✅ | ❌ | Same transcript, plus `conf/statusline.sh` stamping `@ctx_pct` on every render. Codex's status line is a built-in TUI toggle, not a user command that could stamp that bus.
# Stop classifier (haiku) | ✅ | ❌ | Reads the Claude transcript to correct a state the semantic-blind hooks got wrong. Same adapter gap.
# `--resume` paths (restore · migrate · `/fleet-history`) | ✅ | ❌ | `bin/fleet-claude.sh` routes every `--resume` / `--continue` / `--from-pr` / `--fork-session` launch to Claude — those resume Claude transcripts. Codex has `codex resume`; the fleet does not wire it.
# multi-account rotation + the 5h/7d quota collector | ✅ | ❌ | The fleet swaps accounts by exporting `CLAUDE_CODE_OAUTH_TOKEN` per launch. Codex auth is `codex login` — persisted credentials with no per-launch token seam, so there is nothing for the rotator to hand over.
# per-model cap fallback (in-pane `/model` switch) | ✅ | ❌ | Keyed to Claude's per-model subscription caps and typed into a Claude dialog. `FLEET_CODEX_MODEL → -m` is fixed at launch.
# MCP servers + subagent model | ✅ | ❌ | Deliberately skipped, **not** a Codex limit: Codex has both (`codex mcp`, its own subagents). `FLEET_MCP_CONFIG` / `FLEET_SUBAGENT_MODEL` are Claude-shaped and are not materialised into Codex config.
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
  [ -n "$_fx_sess" ] && fleet_load_conf "$_fx_sess"
  unset _fx_sess
fi

if ! command -v codex >/dev/null 2>&1; then
  printf 'fleet-codex: FLEET_AGENT=codex but `codex` is not on PATH — install OpenAI Codex CLI (npm i -g @openai/codex) and `codex login`, or set FLEET_AGENT back to claude.\n' >&2
  exit 127
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

# --- expand a `/name [args]` seed into prose (Codex has no slash commands) -----
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
  expand_slash "$prompt" && prompt="$EXPANDED"
fi

# --- hooks, inline (Codex reads `-c hooks.<Event>=[…]` as TOML) ----------------
# DERIVED, not hand-written (issue #611). This block used to carry its own copy of
# the fleet's hook table, transcoded to TOML by hand — a second source that could
# (and did) drift from hooks/settings-hooks.json. Now bin/fleet-hooks-emit.sh
# materializes the ONE table for the codex target, applying the declared Codex
# delta (hooks/codex-map.json): which events Codex has, `Edit|Write|MultiEdit|
# NotebookEdit` → `apply_patch`, no Artifact tool, no transcript-reading hooks.
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
  --dangerously-bypass-approvals-and-sandbox
  --dangerously-bypass-hook-trust
  -c 'project_doc_fallback_filenames=["CLAUDE.md"]'
  ${hook_flags[@]+"${hook_flags[@]}"}
)

# --- model: FLEET_CODEX_MODEL → -m, unless the caller already chose one ---------
launch_model=''
if [ -n "${FLEET_CODEX_MODEL:-}" ]; then
  case " ${pass[*]+"${pass[*]}"} " in
    *" -m "*|*" --model "*|*" --model="*) : ;;
    *) launch_model="$FLEET_CODEX_MODEL"; flags+=(-m "$launch_model") ;;
  esac
fi

# --- stamp THIS pane's window (issue #511: -t "$TMUX_PANE", never the current window)
if [ -n "${TMUX_PANE:-}" ]; then
  tmux set-option -w -t "$TMUX_PANE" @cc_agent codex 2>/dev/null || true
  [ -n "$launch_model" ] && tmux set-option -w -t "$TMUX_PANE" @cc_model "$launch_model" 2>/dev/null || true
fi

if [ "$have_prompt" = 1 ]; then
  exec codex "${flags[@]}" ${pass[@]+"${pass[@]}"} "$prompt"
else
  exec codex "${flags[@]}" ${pass[@]+"${pass[@]}"}
fi
