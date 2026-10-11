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
for p in fleet-orchestrate fleet-epic; do
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
[ "\$1 \$2 \$3" = "plugin list --json" ] && exec cat "$LIST"
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

# ---- G: override ------------------------------------------------------------------------
echo '["codex.plugins"]' > "$FLEET_CONF_DIR/agent-overrides.json"
printf '[%s]\n' "$(row fleet-orchestrate true)" > "$LIST"
cx sync --override "$FLEET_CONF_DIR/agent-overrides.json" >/dev/null
[ -L "$L" ] && fail "G codex.plugins override still linked"; ok
cmp -s "$HOME_C/config.toml" "$WORK/orig.toml" || fail "G override still wrote config.toml"; ok

# ---- H: wiring ----------------------------------------------------------------------------
grep -q 'fleet-codex-plugins.py" sync' "$BIN/fleet-codex.sh" && grep -q -- '--plugin-dir' "$BIN/fleet-codex.sh" \
  || fail "H fleet-codex.sh does not sync / pass --plugin-dir"; ok
grep -q 'fleet-codex-plugins.py" sync' "$BIN/fleet-install-apply.sh" || fail "H install-apply does not sync"; ok
grep -q 'fleet-codex-plugins.py' "$BIN/fleet-doctor.sh" || fail "H the doctor's plugins row does not ask"; ok

echo "fleet-codex-plugins-selftest: PASS ($CHECKS checks)"
