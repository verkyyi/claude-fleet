#!/bin/bash
# codex-matrix-selftest.sh — the public capability matrix cannot drift (issue #608).
#
# README.md tells the world exactly what a `FLEET_AGENT=codex` worker can and
# cannot do. The failure mode this test exists to prevent is the one that makes a
# published feature table worthless: the adapter changes, the table does not, and
# nobody notices because nothing checks. So two layers are pinned here:
#
#   1. RENDER / DRIFT — bin/codex-matrix.sh renders the MATRIX block in
#      bin/fleet-codex.sh's header into a well-formed markdown table, README.md's
#      generated region matches it TODAY (this is the live gate), a mutated README
#      is caught, `--write` restores it byte-for-byte, and a missing block or
#      missing markers fail loudly (exit 2) instead of emitting an empty table.
#   2. THE VERDICTS ARE STILL TRUE — the ✅/❌ columns are cross-checked against
#      what bin/fleet-codex.sh's CODE actually does: the flags it passes, the hook
#      events it wires, and the Claude-only knobs it must never leak. A row that
#      claims MCP is skipped while the launcher started passing --mcp-config, or a
#      gap row quietly deleted from the matrix, fails here.
#
# Hermetic: a temp copy of the README and of the source file; no tmux, no network,
# no writes to the repo. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
MATRIX="$BIN/codex-matrix.sh"
SRC="$BIN/fleet-codex.sh"
README="$ROOT/README.md"

for f in "$MATRIX" "$SRC" "$README"; do
  [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-matrix.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# --- 1. render is a well-formed table -----------------------------------------
table="$("$MATRIX")" || fail "render exited non-zero"
rows=$(printf '%s\n' "$table" | grep -c '^| ')
[ "$rows" -ge 15 ] || fail "matrix has only $rows rows — a gap row was probably dropped" "$table"
printf '%s\n' "$table" | head -1 | grep -q '^| Capability | Claude Code | Codex | Why |$' \
  || fail "header row is not the expected 4 columns" "$(printf '%s\n' "$table" | head -1)"
printf '%s\n' "$table" | sed -n 2p | grep -q '^|---|:--:|:--:|---|$' \
  || fail "missing / wrong alignment row" "$(printf '%s\n' "$table" | sed -n 2p)"
bad=$(printf '%s\n' "$table" | awk -F'|' '$0 !~ /^\|---\|/ && NF != 6 { print NR": "$0 }')
[ -z "$bad" ] || fail "row(s) with the wrong column count" "$bad"
empty=$(printf '%s\n' "$table" | awk -F'|' '$0 !~ /^\|---\|/ { for (i = 2; i <= 5; i++) { c = $i; gsub(/^[ \t]+|[ \t]+$/, "", c); if (c == "") print NR": empty column "(i-1) } }')
[ -z "$empty" ] || fail "row(s) with an empty cell — every capability needs a verdict AND a reason" "$empty"
ok "render: $rows rows, 4 columns each, no empty cell"

# --- 2. README matches the block, TODAY ----------------------------------------
"$MATRIX" --check >/dev/null || fail "README.md has drifted from the MATRIX block (run bin/codex-matrix.sh --write)"
ok "--check: README.md matches bin/fleet-codex.sh"

# --- 3. drift IS caught (the whole point) --------------------------------------
cp "$README" "$WORK/README.md"
# Flip the first Codex verdict in the generated region; a hand-edit exactly like
# the one this guard exists to catch.
awk '!done && /^\| worktree per task/ { sub(/\| ✅ \| ✅ \|/, "| ✅ | ❌ |"); done = 1 } { print }' \
  "$WORK/README.md" > "$WORK/README.mut" && mv "$WORK/README.mut" "$WORK/README.md"
cmp -s "$README" "$WORK/README.md" && fail "test setup: the mutation did not change the README copy"
if "$MATRIX" --check --readme "$WORK/README.md" >"$WORK/out" 2>"$WORK/err"; then
  fail "a hand-edited README passed --check" "$(cat "$WORK/err")"
fi
grep -q 'DRIFT' "$WORK/err" || fail "--check failed without saying DRIFT" "$(cat "$WORK/err")"
ok "--check: a hand-edited row is caught"

# --- 4. --write repairs it byte-for-byte ---------------------------------------
"$MATRIX" --write --readme "$WORK/README.md" >/dev/null || fail "--write exited non-zero"
cmp -s "$README" "$WORK/README.md" || fail "--write did not restore the README byte-for-byte" \
  "$(diff -u "$README" "$WORK/README.md" | head -20)"
ok "--write: regenerates the table byte-for-byte"

# --- 5. a missing block / missing markers fails LOUDLY, never silently ----------
grep -v 'codex-matrix:begin' "$README" > "$WORK/no-marker.md"
"$MATRIX" --check --readme "$WORK/no-marker.md" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a README with no begin marker did not exit 2"
grep -v '^# MATRIX-' "$SRC" > "$WORK/no-block.sh"
"$MATRIX" --source "$WORK/no-block.sh" >/dev/null 2>&1
[ $? -eq 2 ] || fail "a source with no MATRIX block did not exit 2"
ok "missing block / missing marker → exit 2"

# --- 6. the verdicts still match the launcher's CODE ---------------------------
# Comments stripped: this reads what fleet-codex.sh DOES, not what it says.
code="$(sed -n '/^set -uo pipefail/,$p' "$SRC" | grep -v '^[[:space:]]*#')"
has() { printf '%s\n' "$code" | grep -q -- "$1"; }

# ✅ rows: the guardrails, the project doc, the four wired hook events.
for tok in 'dangerously-bypass-approvals-and-sandbox' 'dangerously-bypass-hook-trust' \
           'project_doc_fallback_filenames' 'hooks.PreToolUse' 'hooks.PostToolUse' \
           'hooks.UserPromptSubmit' 'hooks.Stop' 'bash-guard.py' 'base-readonly-guard.py' \
           'FLEET_CODEX_MODEL'; do
  has "$tok" || fail "matrix claims a ✅ the launcher no longer implements: $tok is gone from $SRC"
done
ok "✅ rows: guardrails, project doc and the four hook events are really wired"

# ❌ rows: the Claude-only knobs must not have quietly appeared.
for tok in 'CLAUDE_CODE_OAUTH_TOKEN' 'CLAUDE_CODE_SUBAGENT_MODEL' 'mcp-config' 'FLEET_MODEL'; do
  has "$tok" && fail "matrix says Codex skips $tok, but $SRC now uses it — regrade the row"
done
# The three events the matrix grades ❌ are wired for Claude (hooks/settings-hooks.json)
# and must stay unwired here, or their rows are lying.
for ev in 'hooks.Notification' 'hooks.SessionEnd' 'hooks.SessionStart'; do
  has "$ev" && fail "matrix grades $ev ❌ on Codex, but the launcher now wires it"
done
ok "❌ rows: no Claude-only knob or ungraded hook event leaked in"

# --- 7. every named gap still has a row (a deletion is drift too) --------------
for gap in 'Notification' 'SessionEnd' 'fleet-handoff' 'fleet-context' 'AskUserQuestion' \
           'resume' 'MCP' 'rotation'; do
  printf '%s\n' "$table" | grep -qF "$gap" \
    || fail "the matrix no longer mentions '$gap' — a gap row was deleted, not fixed"
done
# Each ❌ must carry a reason, not a shrug: the row has to say something beyond the verdict.
short=$(printf '%s\n' "$table" | awk -F'|' '$4 ~ /❌/ { r = $5; gsub(/^[ \t]+|[ \t]+$/, "", r); if (length(r) < 40) print NR": "r }')
[ -z "$short" ] || fail "❌ row(s) with a one-word reason — say WHY (no mechanism vs not adapted)" "$short"
ok "every graded gap still has a row, and every ❌ carries a reason"

printf '\ncodex-matrix-selftest: %d checks passed\n' "$pass"
