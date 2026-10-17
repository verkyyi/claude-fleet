#!/bin/bash
# fleet-codex-plugins-selftest.sh — a Codex session reads the same plugins (issue
# #3123, EPIC #3111 C12). bin/fleet-codex-plugins.py follows what the Claude side
# has installed (a fake `claude plugin list --json`) into a sandbox CODEX_HOME:
#
#   A  nothing installed ⇒ sync writes nothing (config.toml byte for byte, no
#      fleet-plugin-* entry), `dirs` prints nothing
#   B  fleet-orchestrate installed ⇒ its skill linked as fleet-plugin-fleet-orchestrate,
#      one marker block with [mcp_servers.fleet-orch] (env_vars, timeout) at the end
#      of config.toml, every other line byte for byte; a second sync changes nothing;
#      a personal fleet-plugin-* entry is left alone
#   C  a server the login defines itself is its own: no block for it
#   D  uninstalled (and: disabled) ⇒ only the fleet-plugin-* links / adapters go,
#      the block goes, config.toml is the original again
#   E  fleet-hooks-emit.sh --plugin-dir: the plugin's SessionStart is in the codex
#      output, its PreCompact is not (one stderr line says so); no --plugin-dir ⇒
#      byte for byte as before
#   I  fleet-feedback's /fleet-feedback becomes a marked adapter skill (issue #3358)
#   F  fleet-epic's commands become marked adapter skills; doctor names what Codex
#      cannot carry (mod modules · PreCompact · tools limits · /plugin); `mention`
#      names a linked skill <plugin>:<name> (how Codex lists it); no Codex
#      home ⇒ doctor says nothing (exit 3)
#   G  codex.plugins in agent-overrides.json ⇒ nothing written
#   H  wiring: fleet-codex.sh syncs + passes --plugin-dir, install-apply and the
#      doctor run it
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
CP="$BIN/fleet-codex-plugins.py"
EMIT="$BIN/fleet-hooks-emit.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-codex-plugins-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
CHECKS=0
fail() { printf 'selftest FAIL: %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }
has() { case "$2" in *"$1"*) ok ;; *) fail "$3" "$2" ;; esac; }
hasnt() { case "$2" in *"$1"*) fail "$3" "$2" ;; *) ok ;; esac; }

export FLEET_CONF_DIR="$WORK/conf" CLAUDE_CONFIG_DIR="$WORK/claude"
mkdir -p "$FLEET_CONF_DIR" "$CLAUDE_CONFIG_DIR"
HOME_C="$WORK/codex"; mkdir -p "$HOME_C/skills/own-skill"
printf -- '---\nname: own-skill\ndescription: mine\n---\n' > "$HOME_C/skills/own-skill/SKILL.md"
cat > "$HOME_C/config.toml" <<'T'
# my codex config
model = "gpt-5"
approval_policy = "never"

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]

[projects."/x"]
trust_level = "trusted"
T
cp "$HOME_C/config.toml" "$WORK/orig.toml"

# the plugins' installed copies (Claude Code's cache shape: <name>/<version>)
CACHE="$WORK/cache"
for p in fleet-orchestrate fleet-epic fleet-feedback; do
  mkdir -p "$CACHE/$p/0.1.0" && cp -R "$ROOT/plugins/$p/." "$CACHE/$p/0.1.0/"
done
mkdir -p "$CACHE/fleet-orchestrate/0.1.0/hooks"
cat > "$CACHE/fleet-orchestrate/0.1.0/hooks/hooks.json" <<'J'
{"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/probe-session-start.py"}]}],
  "PreCompact":   [{"hooks": [{"type": "command", "command": "python3 ${CLAUDE_PLUGIN_ROOT}/probe-precompact.py"}]}]
}}
J

LIST="$WORK/list.json"
cat > "$WORK/claude-fake" <<SH
#!/bin/sh
[ "\$1 \$2 \$3" = "plugin list --json" ] && { printf 'list\n' >> "$WORK/list.calls"; exec cat "$LIST"; }
exit 1
SH
chmod +x "$WORK/claude-fake"
# Claude Code's own record of an install (the launch's cheap pre-check reads it)
mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
mark_installed() { printf '{"version":2,"plugins":{"fleet-orchestrate@claude-fleet":[]}}\n' > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"; }
row() { # name enabled
  printf '{"id":"%s@claude-fleet","version":"0.1.0","enabled":%s,"installPath":"%s/%s/0.1.0"}' "$1" "$2" "$CACHE" "$1"
}
cx() { python3 "$CP" "$@" --root "$ROOT" --claude "$WORK/claude-fake" --cache '' --codex-home "$HOME_C"; }

# ---- A: nothing installed -------------------------------------------------------
echo '[]' > "$LIST"
out=$(cx sync); rc=$?
[ "$rc" = 0 ] || fail "A sync rc $rc" "$out"; ok
has 'unchanged' "$out" "A sync should change nothing"
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "A config.toml changed" "$(diff "$WORK/orig.toml" "$HOME_C/config.toml")"; ok
for e in "$HOME_C/skills"/fleet-plugin-*; do [ -e "$e" ] || [ -L "$e" ] && fail "A a fleet-plugin-* entry appeared" "$e"; done; ok
[ -z "$(cx dirs)" ] || fail "A dirs printed something"; ok
out=$(cx sync --print-dirs 2>"$WORK/sync.stderr"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -f "$WORK/list.calls" ] || fail "A combined sync queried Claude or emitted paths" "$out"; ok
has 'unchanged' "$(cat "$WORK/sync.stderr")" "A combined sync diagnostics must go to stderr"

# ---- B: fleet-orchestrate installed ---------------------------------------------
mkdir -p "$HOME_C/skills/fleet-plugin-mine"
printf -- '---\nname: mine\ndescription: personal\n---\n' > "$HOME_C/skills/fleet-plugin-mine/SKILL.md"
printf '[%s]\n' "$(row fleet-orchestrate true)" > "$LIST"
# no installed_plugins.json naming ours ⇒ claude is never asked, nothing written
mv "$WORK/claude-fake" "$WORK/claude-fake.off"
out=$(cx sync); has 'unchanged · plugins: none' "$out" "B0 with no install record, sync should not ask claude"
mv "$WORK/claude-fake.off" "$WORK/claude-fake"
[ -L "$HOME_C/skills/fleet-plugin-fleet-orchestrate" ] && fail "B0 linked without an install record"; ok
mark_installed
dry=$(cx sync --dry-run)
has 'link ' "$dry" "B dry run should plan the link"
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "B --dry-run wrote config.toml"; ok
[ -e "$HOME_C/skills/fleet-plugin-fleet-orchestrate" ] && fail "B --dry-run linked a skill"; ok
out=$(cx sync); rc=$?
[ "$rc" = 0 ] || fail "B sync rc $rc" "$out"; ok
: > "$WORK/list.calls"
combined=$(cx sync --print-dirs 2>"$WORK/sync.stderr"); rc=$?
[ "$rc" = 0 ] && [ "$combined" = "$CACHE/fleet-orchestrate/0.1.0" ] || fail "B combined sync stdout must contain only installed hook paths" "$combined"; ok
[ "$(wc -l < "$WORK/list.calls" | tr -d ' ')" = 1 ] || fail "B combined sync must read installed plugins exactly once"; ok
has 'unchanged' "$(cat "$WORK/sync.stderr")" "B combined sync must retain diagnostics on stderr"
L="$HOME_C/skills/fleet-plugin-fleet-orchestrate"
[ -L "$L" ] && [ -f "$L/SKILL.md" ] || fail "B the skill is not linked" "$out"; ok
[ "$(readlink "$L")" = "$CACHE/fleet-orchestrate/0.1.0/skills/fleet-orchestrate" ] || fail "B link target" "$(readlink "$L")"; ok
grep -q '^name: fleet-orchestrate' "$L/SKILL.md" || fail "B linked SKILL.md is not fleet-orchestrate's"; ok
conf=$(cat "$HOME_C/config.toml")
has '# >>> fleet plugins' "$conf" "B no marker block"
has '[mcp_servers.fleet-orch]' "$conf" "B no fleet-orch server"
has 'env_vars = ["TMUX", "TMUX_PANE"' "$conf" "B the server does not forward the pane env"
has 'tool_timeout_sec = ' "$conf" "B no tool timeout"
has 'fleet-mcp.py\" --group orch' "$conf" "B the server is not the dispatch group"
head -c "$(wc -c < "$WORK/orig.toml")" "$HOME_C/config.toml" | cmp -s - "$WORK/orig.toml" \
  || fail "B the login's lines are not byte for byte" "$(diff "$WORK/orig.toml" "$HOME_C/config.toml")"; ok
[ "$(tail -n 1 "$HOME_C/config.toml")" = '# <<< fleet plugins <<<' ] || fail "B the block is not at the end"; ok
grep -q 'name: mine' "$HOME_C/skills/fleet-plugin-mine/SKILL.md" || fail "B the personal fleet-plugin-mine was touched"; ok
has 'own     ' "$out" "B the personal entry should be reported as own"
if python3 -c 'import tomllib' 2>/dev/null; then
  python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$HOME_C/config.toml" \
    || fail "B config.toml does not parse"; ok
fi
cp "$HOME_C/config.toml" "$WORK/after-b.toml"
out=$(cx sync)
has 'unchanged' "$out" "B a second sync should change nothing"
cmp -s "$HOME_C/config.toml" "$WORK/after-b.toml" || fail "B second sync rewrote config.toml"; ok
[ "$(cx dirs)" = "$CACHE/fleet-orchestrate/0.1.0" ] || fail "B dirs" "$(cx dirs)"; ok

# ---- C: the login's own server ----------------------------------------------------
C2="$WORK/codex2"; mkdir -p "$C2"
printf '[mcp_servers.fleet-orch]\ncommand = "mine"\n' > "$C2/config.toml"; cp "$C2/config.toml" "$WORK/c2.toml"
out=$(python3 "$CP" sync --root "$ROOT" --claude "$WORK/claude-fake" --cache '' --codex-home "$C2")
has "mcp fleet-orch — this login's" "$out" "C the login's server should be its own"
cmp -s "$C2/config.toml" "$WORK/c2.toml" || fail "C the login's server was rewritten" "$(cat "$C2/config.toml")"; ok

# ---- D: uninstalled, then disabled ---------------------------------------------------
echo '[]' > "$LIST"
out=$(cx sync)
has 'unlink' "$out" "D uninstall should unlink"
[ -e "$L" ] || [ -L "$L" ] && fail "D the link survived" "$out"; ok
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "D config.toml is not the original again" "$(diff "$WORK/orig.toml" "$HOME_C/config.toml")"; ok
[ -f "$HOME_C/skills/fleet-plugin-mine/SKILL.md" ] && [ -f "$HOME_C/skills/own-skill/SKILL.md" ] || fail "D a personal skill was removed"; ok
printf '[%s]\n' "$(row fleet-orchestrate true)" > "$LIST"; cx sync >/dev/null
printf '[%s]\n' "$(row fleet-orchestrate false)" > "$LIST"
cx sync >/dev/null
[ -L "$L" ] && fail "D a disabled plugin's skill stayed"; ok
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "D disabled: config.toml not the original"; ok

# ---- E: hooks ----------------------------------------------------------------------
base=$("$EMIT" --target codex --root "$ROOT")
withp=$("$EMIT" --target codex --root "$ROOT" --plugin-dir "$CACHE/fleet-orchestrate/0.1.0" 2>"$WORK/emit.err")
ss=$(printf '%s\n' "$withp" | grep '^SessionStart')
has "$CACHE/fleet-orchestrate/0.1.0/probe-session-start.py" "$ss" "E the plugin's SessionStart is missing"
hasnt 'probe-precompact' "$withp" "E PreCompact must not reach Codex"
has 'PreCompact not carried' "$(cat "$WORK/emit.err")" "E the dropped event should be said"
[ "$(printf '%s\n' "$base" | grep -c '^SessionStart')" = 1 ] && [ "$(printf '%s\n' "$withp" | grep -c '^SessionStart')" = 1 ] \
  || fail "E SessionStart should be one merged line"; ok
nob=$("$EMIT" --target codex --root "$ROOT" --plugin-dir "$CACHE/fleet-epic/0.1.0")
[ "$nob" = "$base" ] || fail "E a plugin with no hooks.json changed the table"; ok

# ---- F: commands as adapters; doctor ---------------------------------------------------
printf '[%s,%s]\n' "$(row fleet-orchestrate true)" "$(row fleet-epic true)" > "$LIST"
cx sync >/dev/null
: > "$WORK/list.calls"
combined=$(cx sync --print-dirs 2>"$WORK/sync.stderr"); rc=$?
expected=$(printf '%s\n%s' "$CACHE/fleet-epic/0.1.0" "$CACHE/fleet-orchestrate/0.1.0")
[ "$rc" = 0 ] && [ "$combined" = "$expected" ] && [ "$(wc -l < "$WORK/list.calls" | tr -d ' ')" = 1 ] \
  || fail "F combined sync must emit every enabled plugin once, in stable order" "$combined"; ok
cp "$LIST" "$WORK/list.before"
cp "$HOME_C/config.toml" "$WORK/config.before-query-failure"
printf 'not JSON\n' > "$LIST"
combined=$(cx sync --print-dirs 2>"$WORK/sync.stderr"); rc=$?
[ "$rc" = 0 ] && [ -z "$combined" ] || fail "F failed plugin query must not turn diagnostics into hook paths" "$combined"; ok
has 'cannot tell' "$(cat "$WORK/sync.stderr")" "F failed query must explain why sync was skipped"
cmp -s "$HOME_C/config.toml" "$WORK/config.before-query-failure" && [ -L "$L" ] \
  || fail "F failed query changed previous MCP or skill artifacts"; ok
cp "$WORK/list.before" "$LIST"
A="$HOME_C/skills/fleet-plugin-fleet-epic-run/SKILL.md"
[ -f "$A" ] && grep -q '<!-- fleet codex plugin skill -->' "$A" && grep -q '^name: fleet-epic-run' "$A" \
  || fail "F fleet-epic-run is not a marked adapter skill" "$(ls "$HOME_C/skills")"; ok
[ -L "$HOME_C/skills/fleet-plugin-epic-page" ] || fail "F epic-page skill not linked"; ok
[ "$(python3 "$CP" mention fleet-orchestrate --codex-home "$HOME_C")" = fleet-orchestrate:fleet-orchestrate ] \
  || fail "F mention of a linked plugin skill should be <plugin>:<name>"; ok
[ "$(python3 "$CP" mention fleet-epic-run --codex-home "$HOME_C")" = fleet-epic-run ] || fail "F mention of an adapter"; ok
python3 "$CP" mention mine --codex-home "$HOME_C" >/dev/null && fail "F a personal entry has no mention"; ok
doc=$(cx doctor); rc=$?
[ "$rc" = 0 ] || fail "F doctor rc $rc" "$doc"; ok
for w in 'mod 界面模块' 'PreCompact' 'tools 限制' '/plugin' 'fleet-orch'; do has "$w" "$doc" "F doctor should name $w"; done
python3 "$CP" doctor --root "$ROOT" --claude "$WORK/claude-fake" --cache '' --codex-home "$WORK/none" >/dev/null; rc=$?
[ "$rc" = 3 ] || fail "F doctor with no Codex home should exit 3 (got $rc)"; ok
echo '[]' > "$LIST"; cx sync >/dev/null
[ -e "$A" ] && fail "F uninstall left the adapter"; ok
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "F config.toml not the original after uninstall"; ok

# ---- I: fleet-feedback's command (issue #3358) ------------------------------------------
printf '[%s]\n' "$(row fleet-feedback true)" > "$LIST"
cx sync >/dev/null
A="$HOME_C/skills/fleet-plugin-fleet-feedback/SKILL.md"
[ -f "$A" ] && grep -q '<!-- fleet codex plugin skill -->' "$A" && grep -q '^name: fleet-feedback' "$A" \
  || fail "I fleet-feedback is not a marked adapter skill" "$(ls "$HOME_C/skills")"; ok
grep -q 'fleet-feedback.sh preview' "$A" && grep -q '1 附上' "$A" && ! grep -q '\$ARGUMENTS' "$A" \
  || fail "I the adapter lost the preview step, the 1/2/3 question, or kept \$ARGUMENTS" "$(cat "$A")"; ok
echo '[]' > "$LIST"; cx sync >/dev/null
[ -e "$A" ] && fail "I uninstall left the fleet-feedback adapter"; ok

# ---- G: override ------------------------------------------------------------------------
echo '["codex.plugins"]' > "$FLEET_CONF_DIR/agent-overrides.json"
printf '[%s]\n' "$(row fleet-orchestrate true)" > "$LIST"
cx sync --override "$FLEET_CONF_DIR/agent-overrides.json" >/dev/null
[ -L "$L" ] && fail "G codex.plugins override still linked"; ok
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "G override still wrote config.toml"; ok
out=$(cx dirs); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "G override still injects Claude plugin hooks" "$out"; ok
: > "$WORK/list.calls"
out=$(cx sync --print-dirs 2>"$WORK/sync.stderr"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -s "$WORK/list.calls" ] || fail "G combined sync ignored native ownership override" "$out"; ok
echo '["codex"]' > "$WORK/parent-override.json"
out=$(cx dirs --override "$WORK/parent-override.json"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "G explicit parent override still injects hooks" "$out"; ok
echo '[]' > "$WORK/no-override.json"
out=$(cx dirs --override "$WORK/no-override.json"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$CACHE/fleet-orchestrate/0.1.0" ] \
  || fail "G explicit non-override lost legacy hooks" "$out"; ok

# ---- H: wiring ----------------------------------------------------------------------------
grep -q 'fleet-codex-plugins.py" sync' "$BIN/fleet-codex.sh" && grep -q -- '--plugin-dir' "$BIN/fleet-codex.sh" \
  || fail "H fleet-codex.sh does not sync / pass --plugin-dir"; ok
if grep -q 'fleet-codex-plugins.py" sync --print-dirs' "$BIN/fleet-codex.sh" \
  && ! grep -q 'fleet-codex-plugins.py" dirs' "$BIN/fleet-codex.sh"; then
  ok
else
  fail "H launcher must use a single plugin snapshot"
fi
grep -q 'fleet-codex-plugins.py" sync' "$BIN/fleet-install-apply.sh" || fail "H install-apply does not sync"; ok
grep -q 'fleet-codex-plugins.py' "$BIN/fleet-doctor.sh" || fail "H the doctor's plugins row does not ask"; ok

printf '[%s,%s]\n' "$(row fleet-orchestrate true)" "$(row fleet-epic true)" > "$LIST"
cx sync --override "$WORK/no-override.json" >/dev/null || fail "retire setup sync"
cp "$HOME_C/config.toml" "$WORK/retire-before.toml"
cx retire --override "$WORK/no-override.json" --apply >"$WORK/retire.out" 2>&1 && fail "retire accepted an active bridge"; ok
{ [ -L "$L" ] && cmp -s "$HOME_C/config.toml" "$WORK/retire-before.toml"; } || fail "retire refusal changed artifacts"; ok
out=$(cx retire); rc=$?
[ "$rc" = 0 ] || fail "retire preview failed" "$out"; ok
has 'preview only' "$out" "retire should default to preview"
{ [ -L "$L" ] && cmp -s "$HOME_C/config.toml" "$WORK/retire-before.toml"; } || fail "retire preview changed artifacts"; ok

SECOND="$WORK/second-home"; mkdir -p "$SECOND/skills"
printf '# untouched second account\n# >>> fleet plugins — bin/fleet-codex-plugins.py sync writes this block; edit outside it >>>\n' > "$SECOND/config.toml"
python3 "$CP" retire --apply --root "$ROOT" --claude "$WORK/claude-fake" \
  --codex-home "$HOME_C" --codex-home "$SECOND" >"$WORK/retire.out" 2>&1 && fail "retire accepted malformed second account"; ok
{ [ -L "$L" ] && cmp -s "$HOME_C/config.toml" "$WORK/retire-before.toml"; } || fail "retire edited first home before validating second"; ok
cat "$WORK/retire-before.toml" "$WORK/retire-before.toml" > "$SECOND/config.toml"
cx retire --apply --codex-home "$SECOND" >"$WORK/retire.out" 2>&1 && fail "retire accepted duplicate MCP markers"; ok
rm "$SECOND/config.toml"
ln -s "$WORK/retire-before.toml" "$SECOND/config.toml"
cx retire --apply --codex-home "$SECOND" >"$WORK/retire.out" 2>&1 && fail "retire accepted shared config symlink"; ok
cmp -s "$HOME_C/config.toml" "$WORK/retire-before.toml" || fail "retire changed shared config target"; ok
rm "$SECOND/config.toml"
printf '# untouched second account\n' > "$SECOND/config.toml"

ln -s "$HOME_C/skills/own-skill" "$HOME_C/skills/fleet-plugin-personal-link"
cx retire --apply >"$WORK/retire.out" 2>&1 && fail "retire accepted an unproven symlink"; ok
[ -L "$L" ] && [ -L "$HOME_C/skills/fleet-plugin-personal-link" ] || fail "retire removed a link before full preflight"; ok
rm "$HOME_C/skills/fleet-plugin-personal-link"
ADAPTER="$HOME_C/skills/fleet-plugin-fleet-epic-run"
echo personal > "$ADAPTER/notes.txt"
cx retire --apply >"$WORK/retire.out" 2>&1 && fail "retire accepted an adapter with user files"; ok
[ -f "$ADAPTER/notes.txt" ] && [ -f "$ADAPTER/SKILL.md" ] && [ -L "$L" ] || fail "retire touched adapter user files"; ok
rm "$ADAPTER/notes.txt"
mv "$ADAPTER/SKILL.md" "$WORK/linked-skill.md"
ln -s "$WORK/linked-skill.md" "$ADAPTER/SKILL.md"
cx retire --apply >"$WORK/retire.out" 2>&1 && fail "retire accepted a linked SKILL.md"; ok
[ -L "$ADAPTER/SKILL.md" ] && [ -f "$WORK/linked-skill.md" ] || fail "retire touched linked SKILL.md target"; ok
rm "$ADAPTER/SKILL.md"
mv "$WORK/linked-skill.md" "$ADAPTER/SKILL.md"

cat >> "$HOME_C/config.toml" <<'T'

[plugins."fleet-feedback@claude-fleet"]
enabled = false
T
cat "$WORK/orig.toml" > "$WORK/retire-expected.toml"
cat >> "$WORK/retire-expected.toml" <<'T'

[plugins."fleet-feedback@claude-fleet"]
enabled = false
T
mkdir -p "$HOME_C/plugins/cache/native-fixture"
echo native > "$HOME_C/plugins/cache/native-fixture/keep"
printf '[%s,%s]\n' "$(row fleet-orchestrate false)" "$(row fleet-epic false)" > "$LIST"
echo 'outside user file' > "$WORK/outside-user-file"
ln -s "$WORK/outside-user-file" "$HOME_C/config.toml.fleet-codex-plugins.tmp"
out=$(cx retire --apply --codex-home "$SECOND"); rc=$?
[ "$rc" = 0 ] || fail "retire failed for known disabled plugins" "$out"; ok
[ "$(cat "$WORK/outside-user-file")" = 'outside user file' ] || fail "retire followed a preexisting temporary-file symlink"; ok
[ ! -L "$HOME_C/config.toml" ] || fail "retire published a temporary-file symlink as config"; ok
[ ! -L "$L" ] && [ ! -e "$ADAPTER" ] || fail "retire left generated skill artifacts"; ok
cmp -s "$HOME_C/config.toml" "$WORK/retire-expected.toml" || fail "retire changed non-bridge config"; ok
[ -f "$HOME_C/skills/own-skill/SKILL.md" ] && [ -f "$HOME_C/plugins/cache/native-fixture/keep" ] || fail "retire touched user/native files"; ok
[ "$(cat "$SECOND/config.toml")" = '# untouched second account' ] || fail "retire changed the second account"; ok
out=$(cx retire --apply); rc=$?
[ "$rc" = 0 ] || fail "retire second apply failed" "$out"; ok
has '0 bridge artifact(s)' "$out" "retire must be idempotent"
cx sync >/dev/null || fail "sync after retirement failed"
{ [ ! -L "$L" ] && cmp -s "$HOME_C/config.toml" "$WORK/retire-expected.toml"; } || fail "sync revived retired bridge artifacts"; ok
[ -z "$(cx dirs)" ] || fail "dirs revived retired hooks"; ok

echo "fleet-codex-plugins-selftest: PASS ($CHECKS checks)"
