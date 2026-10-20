#!/bin/bash
# fleet-codex-selftest.sh — the FLEET_AGENT switch (issue #547).
#
# bin/fleet-claude.sh is the single door every fleet session walks through; with
# FLEET_AGENT=codex (or a caller's `--agent codex`) it must hand the launch to
# bin/fleet-codex.sh, which execs OpenAI Codex CLI with the fleet's rails wired in.
# The rails pinned here:
#
#   * DEFAULT UNCHANGED — an unset/empty/`claude` FLEET_AGENT execs `claude` with
#     byte-for-byte the argv it always had; @cc_agent claude (T493).
#   * PRECEDENCE — per-fleet conf overlays global; a caller's --agent wins over both
#     (either spelling) and is CONSUMED (never reaches claude/codex argv).
#   * RESUME IS CLAUDE — a --resume/--continue/--from-pr/--fork-session/--model
#     launch on a codex fleet still execs claude (restore/migrate resume Claude
#     transcripts), unless the caller said --agent explicitly.
#   * CODEX ARGV — full-access + hook-trust bypass, the CLAUDE.md project-doc
#     fallback, the four hook events wired to THIS install's scripts (busy /
#     bash-guard / base-readonly-guard on PreToolUse; working; done) as TOML that
#     actually parses; NO --model / --mcp-config / CLAUDE_CODE_SUBAGENT_MODEL leak;
#     FLEET_CODEX_MODEL → -m (caller -m wins); @cc_agent codex (+ @cc_model) stamped.
#   * SEED SKILLS — a bare `/fleet-history` seed becomes Codex's native
#     `$fleet-history` skill when $CODEX_HOME has it and Codex exposes skills;
#     older Codex or an unsynced home falls back to the historic prose expansion:
#     conf/codex-preamble.md + commands/fleet-history.md with $ARGUMENTS
#     substituted. Non-slash prompts and unknown skills pass through verbatim;
#     the prompt stays the LAST argument; no prompt → no positional.
#   * cwd is the worktree (codex runs where the pane runs); `codex` missing from
#     PATH → exit 127 and claude is NOT launched in its place.
#
# Hermetic: a temp install root (bin/ symlinks + the real commands/ conf/ hooks/),
# its own fleet.conf + FLEET_CONF_DIR, fake `claude` / `codex` / `tmux` /
# `fleet-account.sh` on PATH. No tmux server, no network, no real config. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
for f in "$BIN/fleet-claude.sh" "$BIN/fleet-codex.sh" "$BIN/fleet-lib.sh" "$BIN/set-claude-state.sh" \
         "$ROOT/commands/fleet-history.md" "$ROOT/conf/codex-preamble.md" \
         "$ROOT/hooks/bash-guard.py" "$ROOT/hooks/base-readonly-guard.py"; do
  [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-codex.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
# Canonical path: macOS's $TMPDIR ends in '/', so mktemp yields `…/T//fleet-codex.X`
# while the launcher's `cd … && pwd` collapses it — the path assertions below
# compare strings, so both sides must spell it the same way.
WORK="$(cd "$WORK" && pwd -P)"
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# temp install root: bin/ holds symlinks to the scripts under test; commands/,
# conf/, hooks/ are the repo's own (fleet-codex.sh resolves them as $BIN/..).
mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf/fleets/f1" "$WORK/conf/fleets/f2" "$WORK/wt/repo-issue-42"
# fleet-hooks-emit.sh materialises the codex hook table from hooks/*.json
# (issue #611) — without it the launcher wires no hooks at all.
for s in fleet_codex_trust.py fleet-agent-defaults.py fleet-claude.sh fleet-codex.sh fleet-lib.sh fleet-client-core.sh set-claude-state.sh fleet-hooks-emit.sh; do ln -s "$BIN/$s" "$WORK/bin/$s"; done
ln -s "$ROOT/commands" "$WORK/commands"
ln -s "$ROOT/conf"     "$WORK/conf-real"
ln -s "$ROOT/hooks"    "$WORK/hooks"
# fleet-codex.sh reads $ROOT/conf/codex-preamble.md; FLEET_CONF_DIR is a separate
# tree ($WORK/conf), so give the install root a conf/ with just the preamble.
mkdir -p "$WORK/conf-install"; ln -s "$ROOT/conf/codex-preamble.md" "$WORK/conf-install/codex-preamble.md"
rm -rf "$WORK/conf-real"
# $WORK/conf is FLEET_CONF_DIR (fleets/<s>/conf); the install's conf/ must be a
# sibling of bin/ → make bin/../conf resolve to conf-install by placing bin under
# a nested install dir instead.
mkdir -p "$WORK/install"; mv "$WORK/bin" "$WORK/install/bin"; mv "$WORK/commands" "$WORK/install/commands"
mv "$WORK/hooks" "$WORK/install/hooks"; mv "$WORK/conf-install" "$WORK/install/conf"
IBIN="$WORK/install/bin"

# fake fleet-account.sh: no accounts → transparent passthrough
printf '#!/bin/sh\nexit 0\n' > "$IBIN/fleet-account.sh"; chmod +x "$IBIN/fleet-account.sh"

# fake `claude` / `codex`: each records WHICH ran, its argv (one per line, so a
# multi-line prompt is still one arg), cwd and the env the launcher shapes.
for agent in claude codex; do
  cat > "$WORK/fakebin/$agent" <<EOS
#!/bin/sh
if [ "$agent" = codex ] && [ "\${1:-}" = debug ] && [ "\${2:-}" = prompt-input ]; then
  printf '%s\n' '<skills_instructions>'
  exit 0
fi
printf '%s\n' "$agent" > "$WORK/ran"
: > "$WORK/argv"; for a in "\$@"; do printf '%s\036' "\$a" >> "$WORK/argv"; done
pwd -P > "$WORK/cwd"
printf '%s\n' "\${CLAUDE_CODE_SUBAGENT_MODEL:-}" > "$WORK/subm"
touch "$WORK/agent-exited"
exit "\${FAKE_AGENT_RC:-0}"
EOS
  chmod +x "$WORK/fakebin/$agent"
done

# The launcher's close request is separate from the reap policy (covered by
# session-end-hook-selftest). It must happen AFTER the CLI exits and only on 0.
cat > "$IBIN/session-end-hook.sh" <<EOS
#!/bin/sh
[ -f "$WORK/agent-exited" ] || exit 99
printf '%s\n' "\$*" >> "$WORK/close"
EOS

# fake tmux: display-message names the session ($SESS_FILE); set-option is logged.
SESS_FILE="$WORK/sess"; printf 'f1' > "$SESS_FILE"
cat > "$WORK/fakebin/tmux" <<EOS
#!/bin/sh
case "\$*" in *'#{@repo}|'*) printf '%s|%s|' "\${TEST_REPO:-}" "\${TEST_NOREPO:-}"; exit 0 ;; esac
case "\$*" in *'#{@norepo}'*) printf '%s' "\${TEST_NOREPO:-}"; exit 0 ;; esac
case "\$1" in display-message) cat "$SESS_FILE" ;; set-option|set-window-option) printf '%s\n' "\$*" >> "$WORK/tmuxlog" ;; *) : ;; esac
exit 0
EOS
chmod +x "$WORK/fakebin/tmux"
# fakes first; the rest of PATH is the system dirs only, so no real `claude` /
# `codex` (typically ~/.local/bin, /opt/homebrew/bin) can ever be reached.
export PATH="$WORK/fakebin:/usr/bin:/bin"
# …and fleet_path_fill (fleet-claude.sh) must not add them back: its default dirs
# (~/.local/bin, /opt/homebrew/bin) hold a real codex on a Mac, which leg G reached.
export FLEET_TOOL_DIRS="$WORK/no-tool-dirs"
export FLEET_CONF_DIR="$WORK/conf"
# A pane's env: $TMUX_PANE names the window to stamp, and set-claude-state.sh is
# a no-op without $TMUX (a non-tmux shell is never a fleet) — CI has neither, so
# both are faked here; the fake `tmux` on PATH is what answers.
export TMUX_PANE="%0"
export TMUX="$WORK/fake-tmux-sock,1,0"
export FLEET_SKIP_GLOBAL_CONF=1
printf 'FLEET_MODEL="opus"\n' > "$WORK/install/fleet.conf"     # the global conf the lib sources
# a fake CODEX_HOME: the trust pre-check reads $CODEX_HOME/config.toml — ours, never
# the operator's. Trusted for the fake base checkout by default (case H flips it).
export CODEX_HOME="$WORK/codexhome"; mkdir -p "$CODEX_HOME" "$WORK/wt/repo"
FAKE_MAIN="$(cd "$WORK/wt/repo" && pwd -P)"
printf 'model = "x"\n\n[projects."%s"]\ntrust_level = "trusted"\n' "$FAKE_MAIN" > "$CODEX_HOME/config.toml"
for s in fleet-history fleet-handoff; do
  mkdir -p "$CODEX_HOME/skills/$s"
  printf -- '---\nname: %s\ndescription: fake %s\n---\n\n<!-- fleet codex command skill -->\n' "$s" "$s" > "$CODEX_HOME/skills/$s/SKILL.md"
done

run() {   # run the launcher from the fake worktree with a fresh env; args pass through
  rm -f "$WORK/ran" "$WORK/argv" "$WORK/cwd" "$WORK/subm" "$WORK/tmuxlog" "$WORK/close" "$WORK/agent-exited"
  ( unset FLEET_AGENT FLEET_MODEL FLEET_SUBAGENT_MODEL FLEET_MCP_CONFIG CLAUDE_CODE_SUBAGENT_MODEL \
          FLEET_MODEL_FALLBACK FLEET_CODEX_MODEL FLEET_MAIN
    export FLEET_MAIN="$FAKE_MAIN"
    cd "${TEST_CWD:-$WORK/wt/repo-issue-42}" && bash "$IBIN/fleet-claude.sh" "$@" ) >"$WORK/out" 2>"$WORK/err"
  echo $? > "$WORK/rc"
}
ran()   { cat "$WORK/ran" 2>/dev/null; }
# argv helpers over the RS-separated record: nargs / arg N (1-based) / last / has <exact-arg>
nargs() { tr -cd '\036' < "$WORK/argv" 2>/dev/null | wc -c | tr -d ' '; }
arg()   { awk -v n="$1" 'BEGIN{RS="\036"} NR==n{printf "%s", $0}' "$WORK/argv" 2>/dev/null; }
last()  { arg "$(nargs)"; }
argv1l(){ tr '\036' '\n' < "$WORK/argv" 2>/dev/null; }
# NB: no `grep -q` on the argv pipe — the prompt arg is several KB, and under
# `pipefail` a -q grep that exits at the first match SIGPIPEs the producer and
# the pipeline reads as failed even though it matched. Consume to EOF instead.
hasarg(){ argv1l | grep -xF -- "$1" >/dev/null; }
hasprefix(){ argv1l | grep -- "^$1" >/dev/null; }

# ============================================================================
# A. default fleet: unchanged claude launch, @cc_agent claude (T493: every launch says its agent)
# ============================================================================
if [ "${1:-}" != --resume-defaults ]; then
: > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
[ "$(ran)" = claude ] || fail "A default must exec claude" "$(cat "$WORK/err")"
[ "$(argv1l | paste -sd' ' -)" = "--model opus /fleet-history" ] || fail "A default argv changed" "$(argv1l)"
grep '@cc_agent' "$WORK/tmuxlog" 2>/dev/null | grep -qv '@cc_agent claude' && fail "A a claude launch must stamp only claude" "$(cat "$WORK/tmuxlog")"
ok "A FLEET_AGENT unset → claude, argv byte-for-byte unchanged, @cc_agent claude"

printf 'FLEET_AGENT="claude"\n' > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
[ "$(ran)" = claude ] && [ "$(argv1l | paste -sd' ' -)" = "--model opus /fleet-history" ] || fail "A FLEET_AGENT=claude must be identical to unset" "$(argv1l)"
ok "A FLEET_AGENT=claude ≡ unset"

# ============================================================================
# B. FLEET_AGENT=codex (per-fleet) → codex, with the rails; conf precedence
# ============================================================================
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
[ "$(ran)" = codex ] || fail "B per-fleet FLEET_AGENT=codex must exec codex" "$(cat "$WORK/err")"
hasarg --dangerously-bypass-approvals-and-sandbox || fail "B codex must run full-access (hooks are the rails)" "$(argv1l)"
hasarg --dangerously-bypass-hook-trust            || fail "B codex must bypass hook trust (fleet-vetted hooks)" "$(argv1l)"
hasarg 'project_doc_fallback_filenames=["CLAUDE.md"]' || fail "B CLAUDE.md project-doc fallback missing" "$(argv1l)"
hasprefix 'hooks.PreToolUse=' && hasprefix 'hooks.PostToolUse=' && hasprefix 'hooks.UserPromptSubmit=' && hasprefix 'hooks.Stop=' \
  || fail "B the four hook events must be wired" "$(argv1l)"
pre=$(argv1l | grep '^hooks.PreToolUse=')
case "$pre" in *"matcher=\"Bash\""*"$WORK/install/hooks/bash-guard.py"*) : ;; *) fail "B PreToolUse must wire bash-guard.py on Bash" "$pre" ;; esac
case "$pre" in *"matcher=\"apply_patch\""*"$WORK/install/hooks/base-readonly-guard.py"*) : ;; *) fail "B PreToolUse must wire base-readonly-guard.py on apply_patch" "$pre" ;; esac
case "$pre" in *"$IBIN/set-claude-state.sh' busy"*) : ;; *) fail "B PreToolUse must stamp busy via THIS install's set-claude-state.sh" "$pre" ;; esac
case "$(argv1l | grep '^hooks.Stop=')" in *"set-claude-state.sh' done"*) : ;; *) fail "B Stop must stamp done" "$(argv1l)" ;; esac
case "$(argv1l | grep '^hooks.PostToolUse=')" in *"set-claude-state.sh' working"*) : ;; *) fail "B PostToolUse must stamp working" "$(argv1l)" ;; esac
hasarg --model && fail "B --model must not leak to codex" "$(argv1l)"
hasprefix '--mcp-config' && fail "B --mcp-config must not leak to codex" "$(argv1l)"
[ -z "$(cat "$WORK/subm")" ] || fail "B CLAUDE_CODE_SUBAGENT_MODEL must not be exported for codex" "$(cat "$WORK/subm")"
grep -q 'set-option -w -t %0 @cc_agent codex' "$WORK/tmuxlog" || fail "B @cc_agent codex must be stamped on THIS pane's window" "$(cat "$WORK/tmuxlog" 2>/dev/null)"
[ "$(cat "$WORK/cwd")" = "$(cd "$WORK/wt/repo-issue-42" && pwd -P)" ] || fail "B codex must run in the worktree (the pane cwd)" "$(cat "$WORK/cwd")"
ok "B FLEET_AGENT=codex → codex: full-access, hook-trust bypass, CLAUDE.md fallback, 4 hook events to this install, no --model/--mcp/subagent leak, @cc_agent stamped, cwd = worktree"

# the hook TOML parses (python ≥3.11 has tomllib; older → skip this one check)
if python3 -c 'import tomllib' 2>/dev/null; then
  argv1l | grep '^hooks\.' | while IFS= read -r kv; do
    python3 - "$kv" <<'PYT' || exit 1
import sys, tomllib
kv = sys.argv[1]; key, _, val = kv.partition('=')
d = tomllib.loads(f'{key} = {val}')
ev = d['hooks'][key.split('.',1)[1]]
assert isinstance(ev, list) and ev and all('hooks' in g and g['hooks'] and all(h['type']=='command' and h['command'] for h in g['hooks']) for g in ev), d
PYT
  done || fail "B a hooks.* value is not valid TOML / not the hook shape" "$(argv1l | grep '^hooks\.')"
  ok "B every inline hooks.<Event> value is valid TOML in the hook-group shape"
else
  printf 'skip python3 <3.11: TOML parse check\n'
fi

# the per-fleet value beats a global one, and a second fleet keeps its own
printf 'FLEET_AGENT="codex"\n' > "$WORK/install/fleet.conf"
printf 'FLEET_AGENT="claude"\n' > "$WORK/conf/fleets/f2/conf"
printf 'f2' > "$SESS_FILE"; run '/fleet-history'
[ "$(ran)" = claude ] || fail "B a per-fleet claude must beat a global codex" "$(ran)"
: > "$WORK/conf/fleets/f2/conf"; run '/fleet-history'
[ "$(ran)" = codex ] || fail "B an empty per-fleet conf falls through to the global codex" "$(ran)"
printf 'FLEET_MODEL="opus"\n' > "$WORK/install/fleet.conf"; printf 'f1' > "$SESS_FILE"
ok "B per-fleet FLEET_AGENT overlays the global one (#472 precedence)"

# ============================================================================
# C. --agent from the caller wins, either spelling, and is consumed
# ============================================================================
: > "$WORK/conf/fleets/f1/conf"                       # claude fleet
run --agent codex '/fleet-history'
[ "$(ran)" = codex ] || fail "C --agent codex on a claude fleet must exec codex" "$(ran)"
hasarg --agent && fail "C --agent must be consumed, never passed on" "$(argv1l)"
hasarg codex   && fail "C the --agent VALUE must be consumed too" "$(argv1l)"
run --agent=codex '/fleet-history'
[ "$(ran)" = codex ] || fail "C --agent=codex spelling must work" "$(ran)"
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"   # codex fleet
run --agent claude '/fleet-history'
[ "$(ran)" = claude ] || fail "C --agent claude on a codex fleet must exec claude" "$(ran)"
[ "$(argv1l | paste -sd' ' -)" = "--model opus /fleet-history" ] || fail "C the claude path after --agent claude must be the plain claude argv" "$(argv1l)"
run --agent gemini '/fleet-history'
[ "$(ran)" = claude ] || fail "C an unknown --agent must fall back to claude" "$(ran)"
grep -q 'unknown agent gemini' "$WORK/err" || fail "C an unknown agent should be reported on stderr" "$(cat "$WORK/err")"
ok "C caller --agent (both spellings) beats the conf, is consumed; unknown → claude + a stderr note"

# ============================================================================
# D. resume-shaped launches stay Claude on a codex fleet (explicit --agent wins)
# ============================================================================
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"
for shape in '--resume abc-123' '--continue' '--from-pr 77' '--resume abc --fork-session' '--model haiku'; do
  # shellcheck disable=SC2086  # deliberate word-split: the shape IS several args
  run $shape
  [ "$(ran)" = claude ] || fail "D '$shape' on a codex fleet must exec claude" "$(ran)"
done
run --model haiku --resume abc 'nudge text'
[ "$(argv1l | paste -sd' ' -)" = "--model haiku --resume abc nudge text" ] || fail "D the resume argv must pass through intact" "$(argv1l)"
run --agent codex --resume abc
[ "$(ran)" = codex ] || fail "D an explicit --agent codex overrides the resume heuristic" "$(ran)"
hasarg --dangerously-bypass-approvals-and-sandbox && fail "D remote resume must retain native permissions without unsupported overrides" "$(argv1l)"
ok "D --resume/--continue/--from-pr/--fork-session/--model → claude on a codex fleet; explicit --agent still wins"

# D2. full access from config.toml, not a CLI flag (issue #4724): held as a flag it
# is a session override, and Codex refuses every in-TUI /resume on the private
# runtime («Permission overrides are not supported when resuming a remote task»).
# bin/fleet-codex-posture.py says when the login's config.toml already gives it.
ln -s "$BIN/fleet-codex-posture.py" "$IBIN/fleet-codex-posture.py"
cp "$CODEX_HOME/config.toml" "$WORK/codex.d2"
printf 'approval_policy = "never"\nsandbox_mode = "danger-full-access"\n' > "$WORK/posture"
cat "$WORK/posture" "$WORK/codex.d2" > "$CODEX_HOME/config.toml"
run '/fleet-history'
[ "$(ran)" = codex ] || fail "D2 codex must run" "$(cat "$WORK/err")"
hasarg --dangerously-bypass-approvals-and-sandbox && fail "D2 config.toml already gives full access — no CLI permission override" "$(argv1l)"
argv1l | grep -E '^(approval_policy|sandbox_mode)=' >/dev/null && fail "D2 no -c permission override either" "$(argv1l)"
hasarg --dangerously-bypass-hook-trust || fail "D2 hook-trust bypass stays" "$(argv1l)"
FLEET_CODEX_POSTURE_FROM_CONFIG=0 run '/fleet-history'
hasarg --dangerously-bypass-approvals-and-sandbox || fail "D2 FLEET_CODEX_POSTURE_FROM_CONFIG=0 keeps the old flag" "$(argv1l)"
run -s read-only '/fleet-history'
hasarg --dangerously-bypass-approvals-and-sandbox || fail "D2 a caller permission flag keeps the old launch" "$(argv1l)"
printf 'approval_policy = "never"\nsandbox_mode = "workspace-write"\n' | cat - "$WORK/codex.d2" > "$CODEX_HOME/config.toml"
run '/fleet-history'
hasarg --dangerously-bypass-approvals-and-sandbox || fail "D2 config.toml without full access keeps the flag" "$(argv1l)"
printf 'approval_policy = "never"\nsandbox_mode = "danger-full-access"\nprofile = "p"\n' | cat - "$WORK/codex.d2" > "$CODEX_HOME/config.toml"
run '/fleet-history'
hasarg --dangerously-bypass-approvals-and-sandbox || fail "D2 a profile can move the posture — keep the flag" "$(argv1l)"
cat "$WORK/posture" "$WORK/codex.d2" > "$CODEX_HOME/config.toml"
mkdir -p "$WORK/wt/repo-issue-42/.codex"; printf 'sandbox_mode = "read-only"\n' > "$WORK/wt/repo-issue-42/.codex/config.toml"
run '/fleet-history'
hasarg --dangerously-bypass-approvals-and-sandbox || fail "D2 a project .codex/config.toml above the user's keeps the flag" "$(argv1l)"
rm -f "$WORK/wt/repo-issue-42/.codex/config.toml"; rmdir "$WORK/wt/repo-issue-42/.codex"
run --agent codex --resume abc
hasarg --dangerously-bypass-approvals-and-sandbox && fail "D2 a resume never carries the flag" "$(argv1l)"
rm -f "$IBIN/fleet-codex-posture.py"; cp "$WORK/codex.d2" "$CODEX_HOME/config.toml"
ok "D2 config.toml full access ⇒ no CLI permission override (in-TUI /resume works); anything that can move it keeps the flag (#4724)"

# ============================================================================
# E. FLEET_CODEX_MODEL → -m (+ @cc_model); caller -m wins; empty = no -m
# ============================================================================
printf 'FLEET_AGENT="codex"\nFLEET_CODEX_MODEL="gpt-5.5"\n' > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
argv1l | paste -sd' ' - | grep -- '-m gpt-5.5' >/dev/null || fail "E FLEET_CODEX_MODEL must become -m" "$(argv1l)"
grep -q '@cc_model gpt-5.5' "$WORK/tmuxlog" || fail "E the codex model must be stamped as @cc_model" "$(cat "$WORK/tmuxlog")"
run -m o3 '/fleet-history'
argv1l | paste -sd' ' - | grep -- '-m gpt-5.5' >/dev/null && fail "E a caller -m must win over FLEET_CODEX_MODEL" "$(argv1l)"
hasarg o3 || fail "E the caller's -m value must pass through" "$(argv1l)"
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
hasarg -m && fail "E no FLEET_CODEX_MODEL → no -m (codex's own default)" "$(argv1l)"
hasarg 'features.hooks=true' || fail "E fleet guard hooks must be enabled even in a fresh CODEX_HOME"
hasarg 'check_for_update_on_startup=false' || fail "E a fresh CODEX_HOME opens on an update picker nobody answers (#2401)" "$(argv1l)"
grep -q 'set-option -w -t %0 @cc_model ' "$WORK/tmuxlog" && fail "E no model → no invented @cc_model stamp" "$(cat "$WORK/tmuxlog")"
grep -q 'set-option -wu -t %0 @cc_model' "$WORK/tmuxlog" || fail "E new launch must clear the predecessor's model"
ok "E FLEET_CODEX_MODEL → -m + @cc_model; caller -m wins; empty defers to codex"

# ============================================================================
# F. seed skill: /fleet-history → native $fleet-history when installed, else fallback
# ============================================================================
run '/fleet-history'
p="$(last)"
case "$p" in '$fleet-history') : ;; *) fail "F the bare slash seed must become the native Codex skill trigger" "$(argv1l)" ;; esac
ok "F /fleet-history becomes native \$fleet-history, as the last argument"

FLEET_CODEX_NATIVE_SKILLS=0 run '/fleet-history'
p="$(last)"
case "$p" in /fleet-history|'$fleet-history') fail "F old-Codex fallback must expand the slash seed into prose" ;; esac
case "$p" in *'running on OpenAI Codex CLI'*) : ;; *) fail "F the expanded seed must start with the Codex preamble" "$(printf '%s' "$p" | head -5)" ;; esac
case "$p" in *'browse & resume closed sessions'*) : ;; *) fail "F the expanded seed must carry the /fleet-history skill body" "$(printf '%s' "$p" | head -20)" ;; esac
case "$p" in *'$ARGUMENTS'*) fail "F \$ARGUMENTS must be substituted (empty here)" ;; esac
# preamble first, skill body after it
pre_at=$(printf '%s' "$p" | grep -n 'running on OpenAI Codex CLI' | head -1 | cut -d: -f1)
body_at=$(printf '%s' "$p" | grep -n '^# /fleet-history' | head -1 | cut -d: -f1)
[ "$pre_at" -lt "$body_at" ] || fail "F the preamble must precede the skill body" "pre=$pre_at body=$body_at"
ok "F old-Codex /fleet-history fallback expands to preamble + skill prose"

# /name args → $ARGUMENTS substituted
run '/fleet-handoff pickup /tmp/h.md'
p="$(last)"
case "$p" in '$fleet-handoff pickup /tmp/h.md') : ;; *) fail "F /name args must stay on the native skill trigger" "$(argv1l)" ;; esac
FLEET_CODEX_NATIVE_SKILLS=0 run '/fleet-handoff pickup /tmp/h.md'
p="$(last)"
case "$p" in *'pickup /tmp/h.md'*) : ;; *) fail "F old-Codex /name args must substitute \$ARGUMENTS" "$(printf '%s' "$p" | grep -n 'Argument' | head -3)" ;; esac
case "$p" in *'/fleet-handoff'*) : ;; *) fail "F the expanded skill should be fleet-handoff's" ;; esac
ok "F /fleet-handoff pickup <file> is native when available; fallback substitutes \$ARGUMENTS"

# a non-slash prompt passes through verbatim; an unknown skill too (with a note)
run 'plain prose seed with $(injection) and "quotes"'
[ "$(last)" = 'plain prose seed with $(injection) and "quotes"' ] || fail "F a prose prompt must pass through verbatim" "$(last)"
run '/no-such-skill x'
[ "$(last)" = '/no-such-skill x' ] || fail "F an unknown slash command must pass through verbatim" "$(last)"
grep -q 'no commands/no-such-skill.md' "$WORK/err" || fail "F an unknown skill should be noted on stderr" "$(cat "$WORK/err")"
ok "F prose and unknown-skill prompts pass through verbatim"

# no prompt → no positional; a trailing flag is a flag, not a prompt
run
[ "$(nargs)" -gt 0 ] || fail "F codex still gets its flags with no prompt" "$(argv1l)"
case "$(last)" in hooks.SessionEnd=*|features.plugins=false) : ;; *) fail "F with no prompt the last arg must be the last flag value, not a positional" "$(last)" ;; esac
run --search
[ "$(last)" = '--search' ] || fail "F a trailing flag must stay a flag" "$(last)"
ok "F no prompt → no positional; a trailing flag is a flag"

# F2: only the owning launcher's successful process exit requests cleanup.
run
owner=$(awk '/@cc_launcher_pid/{print $NF}' "$WORK/tmuxlog")
case "$owner" in ''|*[!0-9]*) fail "F2 launcher ownership must be stamped" ;; esac
[ "$(cat "$WORK/close")" = "--agent-exit codex $owner" ] \
  || fail "F2 successful CLI exit must request cleanup with the stamped owner" "$(cat "$WORK/close" 2>/dev/null)"
ok "F2 normal Codex exit requests cleanup after the process ends, with its owner PID"

FAKE_AGENT_RC=42 run
[ "$(cat "$WORK/rc")" = 42 ] || fail "F2 failed CLI status must propagate"
[ ! -e "$WORK/close" ] || fail "F2 failed launch must stay visible, not close"
FAKE_AGENT_RC=130 run
[ "$(cat "$WORK/rc")" = 130 ] || fail "F2 interrupted CLI status must propagate"
[ ! -e "$WORK/close" ] || fail "F2 interrupted process must not request normal-exit cleanup"
( unset TMUX; run )
[ ! -e "$WORK/close" ] || fail "F2 a non-tmux launch must not request window cleanup"
ok "F2 failures, interruption, and non-tmux launches never request window cleanup"

# The launcher's runtime selection is independent of the runtime's own process
# lifecycle tests. Stub just this hop, preserving the exact downstream argv.
cat > "$IBIN/fleet-codex-runtime.py" <<PY
import os,sys
if sys.argv[1:2] == ['version-check']:  # the launch-time version check (#1079)
    print('codex 0.162.0'); sys.exit(0)
open('$WORK/runtime-used','w').write('yes')
os.execvp('codex',['codex']+sys.argv[2:])
PY
run 'runtime fixture'
[ -f "$WORK/runtime-used" ] || fail "F3 pane launch must use its private runtime by default"
[ "$(last)" = 'runtime fixture' ] || fail "F3 runtime must preserve the final prompt"
rm -f "$WORK/runtime-used"
FLEET_CODEX_SERVER=0 run 'embedded fixture'
[ ! -f "$WORK/runtime-used" ] || fail "F3 explicit embedded opt-out must skip the runtime"
run --remote unix:///explicit.sock 'remote fixture'
[ ! -f "$WORK/runtime-used" ] || fail "F3 a caller endpoint must retain its own lifecycle"
rm -f "$IBIN/fleet-codex-runtime.py"
ok "F3 private runtime is default inside a pane; embedded opt-out and explicit remote are preserved"

# ============================================================================
# G. codex missing from PATH → loud failure, claude is NOT substituted
# ============================================================================
# PATH is narrowed to the fakes + the system dirs so a REAL codex installed under
# ~/.local/bin or /opt/homebrew can't be found once the fake is gone (this test
# must never launch a real agent).
rm -f "$WORK/fakebin/codex"
PATH="$WORK/fakebin:/usr/bin:/bin" run '/fleet-history'
[ "$(cat "$WORK/rc")" = 127 ] || fail "G missing codex must exit 127" "rc=$(cat "$WORK/rc") err=$(cat "$WORK/err")"
[ -z "$(ran)" ] || fail "G missing codex must NOT silently launch claude" "$(ran)"
grep -q 'not on PATH' "$WORK/err" || fail "G the missing-codex error should say so" "$(cat "$WORK/err")"
ok "G codex missing → exit 127 with a clear error, no silent claude fallback"

# ============================================================================
# H. project trust pre-check: an untrusted base checkout is flagged, never fixed
# ============================================================================
# Codex prompts "trust this directory?" once per project and a worktree inherits
# its main repo's trust (measured) — so the base checkout must be trusted.
# Trusted (the default above) → silent. Untrusted → a stderr note + `needs` stamped
# on the pane's window (red on the dash), and codex is STILL exec'd (it is the
# authority). The operator's config is never written.
# (G removed the fake codex — put a minimal one back: records that it ran + argv.)
printf '#!/bin/sh\nif [ "${1:-}" = debug ] && [ "${2:-}" = prompt-input ]; then printf "%%s\\n" "<skills_instructions>"; exit 0; fi\nprintf "%%s\\n" codex > "%s/ran"\n: > "%s/argv"; for a in "$@"; do printf "%%s\\036" "$a" >> "%s/argv"; done\nexit 0\n' "$WORK" "$WORK" "$WORK" > "$WORK/fakebin/codex"; chmod +x "$WORK/fakebin/codex"
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
[ "$(ran)" = codex ] || fail "H (setup) codex must run" "$(cat "$WORK/err")"
grep -q 'not trusted' "$WORK/err" && fail "H a trusted base must not be flagged" "$(cat "$WORK/err")"
grep -q '@claude_state needs' "$WORK/tmuxlog" 2>/dev/null && fail "H a trusted base must not stamp needs" "$(cat "$WORK/tmuxlog")"
before=$(cat "$CODEX_HOME/config.toml")
printf 'model = "x"\n' > "$CODEX_HOME/config.toml"                  # no trust table at all
run '/fleet-history'
[ "$(ran)" = codex ] || fail "H codex must still be exec'd when the base is untrusted (Codex is the authority)" "$(cat "$WORK/err")"
grep -q "not trusted" "$WORK/err" || fail "H an untrusted base must be reported in the pane" "$(cat "$WORK/err")"
grep -q 'set-window-option -t %0 @claude_state needs' "$WORK/tmuxlog" || fail "H an untrusted base must stamp needs on THIS window" "$(cat "$WORK/tmuxlog" 2>/dev/null)"
[ "$(cat "$CODEX_HOME/config.toml")" = 'model = "x"' ] || fail "H the launcher must never write the operator's codex config" "$(cat "$CODEX_HOME/config.toml")"
printf 'model = "x"\n\n[projects."%s"]\ntrust_level = "untrusted"\n' "$FAKE_MAIN" > "$CODEX_HOME/config.toml"
run '/fleet-history'
grep -q "not trusted" "$WORK/err" || fail "H an explicitly UNtrusted base must be reported too" "$(cat "$WORK/err")"
printf 'model = "x"\n\n[projects."%s"]\ntrust_level = "trusted"\n[projects."/elsewhere"]\ntrust_level = "untrusted"\n' "$FAKE_MAIN" > "$CODEX_HOME/config.toml"
run '/fleet-history'
grep -q "not trusted" "$WORK/err" && fail "H a trusted table followed by another project's table must still read trusted" "$(cat "$WORK/err")"
rm -f "$CODEX_HOME/config.toml"; run '/fleet-history'
grep -q "not trusted" "$WORK/err" && fail "H no codex config at all → skip the check quietly" "$(cat "$WORK/err")"
printf '%s\n' "$before" > "$CODEX_HOME/config.toml"
ok "H untrusted base checkout → pane note + needs stamp, codex still runs, config never written; trusted → silent"
# H2 (issue #2401): on a TRUSTED node the launcher answers the question itself —
# fleet-trust.sh codex-grant writes the base's table, fill only: the login's own
# "untrusted" stands (and is still reported), every other line kept byte for byte.
[ -f "$IBIN/fleet-trust.sh" ] || ln -s "$BIN/fleet-trust.sh" "$IBIN/fleet-trust.sh"
[ -d "$FAKE_MAIN/.git" ] || git -C "$FAKE_MAIN" init -q
mkdir -p "$FLEET_CONF_DIR/cred-proxy"
printf '{"trust":"trusted","why":"selftest","ts":%s}\n' "$(date +%s)" > "$FLEET_CONF_DIR/cred-proxy/trust.json"
printf 'model = "x"\n' > "$CODEX_HOME/config.toml"
run '/fleet-history'
[ "$(ran)" = codex ] || fail "H2 codex must run" "$(cat "$WORK/err")"
grep -q "not trusted" "$WORK/err" && fail "H2 a trusted node must answer the trust question, not report it" "$(cat "$WORK/err")"
grep -q 'pre-trusted' "$WORK/err" || fail "H2 the pre-trust is not said in the pane" "$(cat "$WORK/err")"
[ "$(cat "$CODEX_HOME/config.toml")" = "$(printf 'model = "x"\n\n[projects."%s"]\ntrust_level = "trusted"' "$FAKE_MAIN")" ] \
  || fail "H2 codex-grant did not append exactly the base's table" "$(cat "$CODEX_HOME/config.toml")"
printf 'model = "x"\n\n[projects."%s"]\ntrust_level = "untrusted"\n' "$FAKE_MAIN" > "$CODEX_HOME/config.toml"
cp "$CODEX_HOME/config.toml" "$WORK/codex.own"
run '/fleet-history'
cmp -s "$CODEX_HOME/config.toml" "$WORK/codex.own" || fail "H2 a login's own untrusted answer was overwritten" "$(cat "$CODEX_HOME/config.toml")"
grep -q "not trusted" "$WORK/err" || fail "H2 the login's own untrusted base must still be reported" "$(cat "$WORK/err")"
rm -f "$FLEET_CONF_DIR/cred-proxy/trust.json"
printf '%s\n' "$before" > "$CODEX_HOME/config.toml"
ok "H2 trusted node → codex-grant answers Codex's trust question (fill only; the login's untrusted stands)"

# H3: the common launcher, including a second ephemeral proxy home, grants only
# the managed physical HOME. All node/trust choices remain fill-only.
(
  export HOME="$WORK/login" TEST_NOREPO=1 TEST_CWD="$WORK/login"
  mkdir -p "$HOME/.codex" "$WORK/proxy-one" "$WORK/proxy-two"
  export CODEX_HOME="$WORK/proxy-one"
  ln -s "$HOME/.codex/config.toml" "$CODEX_HOME/config.toml"
  ln -s "$HOME/.codex/config.toml" "$WORK/proxy-two/config.toml"
  printf '{"trust":"trusted","ts":%s}\n' "$(date +%s)" > "$FLEET_CONF_DIR/cred-proxy/trust.json"
  run --agent codex
  [ "$(ran)" = codex ] && [ -L "$CODEX_HOME/config.toml" ] || fail 'H3 launcher/proxy link'
  sh "$IBIN/fleet-trust.sh" codex-check "$HOME" >/dev/null || fail 'H3 HOME not trusted'
  cp "$HOME/.codex/config.toml" "$WORK/home-trust-before"
  export CODEX_HOME="$WORK/proxy-two"
  run --agent codex
  cmp -s "$HOME/.codex/config.toml" "$WORK/home-trust-before" || fail 'H3 subsequent proxy rewrote trust'
  printf 'model = "keep"\n' > "$HOME/.codex/config.toml"
  export TEST_CWD="$WORK/wt/repo-issue-42"
  run --agent codex
  sh "$IBIN/fleet-trust.sh" codex-check "$HOME" >/dev/null && fail 'H3 arbitrary cwd granted HOME'
  export TEST_CWD="$HOME" FLEET_PRETRUST=0
  run --agent codex
  sh "$IBIN/fleet-trust.sh" codex-check "$HOME" >/dev/null && fail 'H3 opt-out granted HOME'
  export FLEET_PRETRUST=1
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$HOME" > "$HOME/.codex/config.toml"
  run --agent codex
  [ "$(sh "$IBIN/fleet-trust.sh" codex-check "$HOME")" = untrusted ] || fail 'H3 explicit untrusted overwritten'
) || exit 1
rm -f "$FLEET_CONF_DIR/cred-proxy/trust.json"
ok "H3 managed HOME trust persists across proxy homes; arbitrary cwd, opt-out and explicit untrusted preserved"

# ============================================================================
# I. the fleet tool service (issue #1807): Codex mounts the same `fleet` server
# ============================================================================
# Every case above ran with no conf/mcp-worker.json / fleet-mcp.py beside bin/,
# so its argv is byte for byte what it was. With them, a Codex launch carries
# `-c mcp_servers.fleet={…}` — derived from that one file, with the env Codex
# withholds from a server — and the Claude launch the matching --mcp-config.
cp "$ROOT/conf/mcp-worker.json" "$WORK/install/conf/mcp-worker.json"
ln -s "$BIN/fleet-mcp.py" "$IBIN/fleet-mcp.py"
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
[ "$(ran)" = codex ] || fail "I codex must run" "$(cat "$WORK/err")"
m=$(argv1l | grep '^mcp_servers\.fleet=' || true)
case "$m" in
  'mcp_servers.fleet={command="bash",args=["-c",'*'fleet-mcp.py'*'env_vars=["TMUX","TMUX_PANE",'*'tool_timeout_sec='*'}') : ;;
  *) fail "I a Codex launch did not mount the fleet tool service" "$(argv1l)" ;;
esac
case "$(last)" in *fleet-history) : ;; *) fail "I the seed prompt is no longer last" "$(argv1l)" ;; esac
( export FLEET_MCP=0; run '/fleet-history' )
argv1l | grep '^mcp_servers\.fleet=' >/dev/null && fail "I FLEET_MCP=0 still mounted it" "$(argv1l)"
: > "$WORK/conf/fleets/f1/conf"
run '/fleet-history'
[ "$(ran)" = claude ] && hasprefix '--mcp-config=.*/conf/mcp-worker\.json$' || fail "I the Claude launch lacks the same server" "$(argv1l)"
ok "I Codex: -c mcp_servers.fleet (from conf/mcp-worker.json, TMUX env forwarded); Claude: --mcp-config of that file; FLEET_MCP=0 off"
fi

# J. A sparse home must not turn fleet permission defaults into explicit
# resume overrides. Exercise the real composer, absent from the earlier cases.
for s in fleet-agent-team.py fleet-hooks-merge.py; do ln -s "$BIN/$s" "$IBIN/$s"; done
ln -s "$ROOT/conf/agent-defaults" "$WORK/install/conf/agent-defaults"
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"
run --agent codex 'fresh fixture'
hasarg 'approval_policy="never"' && hasarg 'sandbox_mode="danger-full-access"' \
  || fail 'J fresh launch lost fleet permission defaults' "$(cat "$WORK/err")"
for shape in '--resume source-id' 'resume source-id' 'fork source-id'; do
  # shellcheck disable=SC2086
  run --agent codex $shape
  hasprefix 'approval_policy=' && fail 'J composer injected approval override into resume' "$(argv1l)"
  hasprefix 'sandbox_mode=' && fail 'J composer injected sandbox override into resume' "$(argv1l)"
  hasarg 'model_reasoning_effort="high"' && hasprefix 'hooks.SessionStart=' && hasprefix 'hooks.Stop=' \
    || fail 'J resume lost non-permission defaults or hooks' "$(argv1l)"
done
# Explicit caller choices still reach native validation; never silently strip them.
run --agent codex --resume source-id -c 'approval_policy="on-request"' 'nudge'
hasarg 'approval_policy="on-request"' || fail 'J explicit caller permission was discarded'
# Even when its value equals a default, a team policy is explicitly selected.
printf '%s\n' '{"version":1,"bundle":{"codex_config":{"approval_policy":"never"}}}' > "$FLEET_CONF_DIR/team-bundle.json"
run --agent codex --resume source-id
hasarg 'approval_policy="never"' || fail 'J explicit team permission was discarded'
rm -f "$FLEET_CONF_DIR/team-bundle.json"
# A locked default is policy, not a convenience fallback, and still refuses at native.
printf 'codex.approval_policy\n' > "$WORK/install/conf/agent-locked.list"
run --agent codex --resume source-id
hasarg 'approval_policy="never"' || fail 'J locked permission was discarded'
ok 'J resume preserves saved permissions; fresh defaults, explicit/locked policy and hooks retained'

# ============================================================================
# J. the native usage pilot (#4557): the runtime reads FLEET_CODEX_NATIVE_USAGE from
#    its environment, so a fleet conf's 1 must reach the Codex launch exported; off
#    (unset, or anything but 1 — even inherited) reaches it as nothing at all.
# ============================================================================
# its own fake: an earlier leg replaced the shared one with a recorder of argv only
printf '#!/bin/sh\nprintf codex > "%s/ran"\nprintf "%%s\\n" "${FLEET_CODEX_NATIVE_USAGE-unset}" > "%s/nusage"\nexit 0\n' "$WORK" "$WORK" > "$WORK/fakebin/codex"; chmod +x "$WORK/fakebin/codex"
printf 'FLEET_AGENT="codex"\nFLEET_CODEX_NATIVE_USAGE=1\n' > "$WORK/conf/fleets/f1/conf"
rm -f "$WORK/nusage"; run '/fleet-history'
[ "$(ran)" = codex ] && [ "$(cat "$WORK/nusage")" = 1 ] || fail "J conf 1 did not reach the Codex launch" "$(cat "$WORK/nusage" 2>/dev/null) $(cat "$WORK/err")"
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f1/conf"
rm -f "$WORK/nusage"; run '/fleet-history'
[ "$(cat "$WORK/nusage")" = unset ] || fail "J the pilot must be off by default" "$(cat "$WORK/nusage")"
rm -f "$WORK/nusage"; FLEET_CODEX_NATIVE_USAGE=0 run '/fleet-history'
[ "$(cat "$WORK/nusage")" = unset ] || fail "J a 0 must not reach the runtime" "$(cat "$WORK/nusage")"
ok "J FLEET_CODEX_NATIVE_USAGE=1 in the fleet conf reaches the Codex launch; default and 0 reach it as unset"

# ============================================================================
# K. Codex's plugins are off in every fleet launch (issue #4848; #4696 did it
#    for FLEET_FORGE=none only): -c features.plugins=false, so its startup
#    plugin sync never fetches github.com/openai/plugins.git — a repo with no
#    GitHub, a GitHub repo and a no-repo window alike. agent-overrides.json
#    `"codex_plugins": "on"` (or the array form) keeps the person's plugins; a
#    Claude launch carries no Codex flag. Its own fleet f3 with a repos/ dir, so
#    the overlay legs above stay byte for byte.
# ============================================================================
cat > "$WORK/fakebin/codex" <<EOS
#!/bin/sh
if [ "\${1:-}" = debug ] && [ "\${2:-}" = prompt-input ]; then printf '%s\n' '<skills_instructions>'; exit 0; fi
printf codex > "$WORK/ran"
: > "$WORK/argv"; for a in "\$@"; do printf '%s\036' "\$a" >> "$WORK/argv"; done
exit 0
EOS
chmod +x "$WORK/fakebin/codex"
mkdir -p "$WORK/conf/fleets/f3/repos"; printf 'f3' > "$SESS_FILE"
printf 'FLEET_AGENT="codex"\n' > "$WORK/conf/fleets/f3/conf"
printf 'FLEET_REPO="local/demo"\nFLEET_MAIN="%s"\nFLEET_FORGE="none"\n' "$FAKE_MAIN" > "$WORK/conf/fleets/f3/repos/local-demo.conf"
TEST_REPO=local/demo run '/fleet-history'
[ "$(ran)" = codex ] && hasarg 'features.plugins=false' \
  || fail "K forge none: Codex must start with features.plugins=false (#4696)" "$(argv1l; cat "$WORK/err")"
printf 'FLEET_REPO="local/demo"\nFLEET_MAIN="%s"\n' "$FAKE_MAIN" > "$WORK/conf/fleets/f3/repos/local-demo.conf"
TEST_REPO=local/demo run '/fleet-history'
[ "$(ran)" = codex ] && hasarg 'features.plugins=false' \
  || fail "K a GitHub repo: Codex must start with features.plugins=false (#4848)" "$(argv1l)"
TEST_NOREPO=1 run '/fleet-history'
[ "$(ran)" = codex ] && hasarg 'features.plugins=false' \
  || fail "K a no-repo window: Codex must start with features.plugins=false (#4848)" "$(argv1l)"
printf '{"codex_plugins": "on"}\n' > "$FLEET_CONF_DIR/agent-overrides.json"
TEST_REPO=local/demo run '/fleet-history'
[ "$(ran)" = codex ] && ! hasarg 'features.plugins=false' \
  || fail "K codex_plugins on in agent-overrides.json must keep Codex's plugins" "$(argv1l)"
printf '["playwright", "codex_plugins:on"]\n' > "$FLEET_CONF_DIR/agent-overrides.json"
TEST_REPO=local/demo run '/fleet-history'
[ "$(ran)" = codex ] && ! hasarg 'features.plugins=false' \
  || fail "K the array form codex_plugins:on must keep Codex's plugins" "$(argv1l)"
printf '{"codex_plugins": "off"}\n' > "$FLEET_CONF_DIR/agent-overrides.json"
TEST_REPO=local/demo run '/fleet-history'
[ "$(ran)" = codex ] && hasarg 'features.plugins=false' \
  || fail "K codex_plugins off keeps the plugins off" "$(argv1l)"
rm -f "$FLEET_CONF_DIR/agent-overrides.json"
printf 'FLEET_AGENT="claude"\n' > "$WORK/conf/fleets/f3/conf"
TEST_REPO=local/demo run '/fleet-history'
[ "$(ran)" = claude ] && ! hasarg 'features.plugins=false' \
  || fail "K a Claude launch carries no Codex flag" "$(ran) $(argv1l)"
printf 'f1' > "$SESS_FILE"
ok "K every Codex launch → -c features.plugins=false; agent-overrides codex_plugins on keeps them; Claude carries no flag"

printf '\nselftest OK: %s assertions passed (FLEET_AGENT / fleet-codex.sh, issue #547)\n' "$pass"
exit 0
