#!/bin/bash
# fleet-agent-defaults-selftest.sh — ONE default package for both agents (issue #1559,
# EPIC #1524 C12): conf/agent-defaults/ filled by bin/fleet-agent-defaults.py into
# ~/.claude.json (user-scope MCP), $CODEX_HOME/config.toml (approval_policy /
# sandbox_mode / model_reasoning_effort + the same MCP), and one marker block in
# ~/.claude/CLAUDE.md / $CODEX_HOME/AGENTS.md, with bin/mcp-github.sh and
# bin/mcp-fetch.sh as the two servers' wrappers. Hermetic: a sandbox install root
# whose conf/agent-defaults IS the repo's (symlink), a sandbox skills/ of its own.
#
#   1  the shipped defaults: shape, the four servers, the three Codex keys, no
#      `model`, both doc blocks marked; tomllib agrees with the fleet's reader
#   2  empty: {} .claude.json + a one-key config.toml + no docs → every default
#      in; `filled claude 5 · codex 8`; check reads 0 missing (skills once installed)
#   3  own: a same-name server (both agents) and a login's approval_policy are
#      never rewritten; the login's lines survive byte for byte; the personal
#      AGENTS.md text survives under the appended block
#   4  idempotent: a second apply writes nothing, cmp-equal files
#   5  a stale fleet block is replaced in place; the login's text around it stays
#   6  the override file + --skip shield items; `codex` alone shields that agent
#   7  absent: no .claude.json is never created; no $CODEX_HOME is n/a, not created
#   8  a held .claude.json.lock is never stolen (exit 2, nothing written)
#   9  `mcp_servers = { … }` inline at the top is reported, not extended; the
#      merged file still parses
#  10  malformed defaults are refused (exit 2): `model`, a credential-shaped key,
#      a doc block missing its end marker
#  11  no token anywhere: the shipped files, the wrappers and the merged configs
#  12  the wrappers: github takes `gh auth token` into the env and execs the
#      server with `stdio`; no token → exit 1; fetch execs uvx when present
#  13  the no-tomllib path (macOS /usr/bin/python3 3.9) fills the same files
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
SCRIPT="$BIN/fleet-agent-defaults.py"
pass=0
ok()   { pass=$((pass+1)); printf '  ok  %s\n' "$1"; }
fail() { printf 'fleet-agent-defaults-selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
[ -f "$SCRIPT" ] || fail "no $SCRIPT"
command -v python3 >/dev/null 2>&1 || fail 'python3 missing'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/agent-defaults.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

# --- the sandbox install root: the REPO's conf/agent-defaults + its own skills/ ------
SR="$WORK/root"; mkdir -p "$SR/conf" "$SR/skills/sk1" "$SR/skills/sk2" "$SR/bin"
ln -s "$ROOT/conf/agent-defaults" "$SR/conf/agent-defaults"
printf -- '---\nname: sk1\n---\n<!-- fleet skill -->\n' > "$SR/skills/sk1/SKILL.md"
printf -- '---\nname: sk2\n---\n<!-- fleet skill -->\n' > "$SR/skills/sk2/SKILL.md"
ln -s "$BIN/fleet-agent-defaults.py" "$SR/bin/fleet-agent-defaults.py"
ln -s "$BIN/fleet-hooks-merge.py" "$SR/bin/fleet-hooks-merge.py"
HAS_TOML=0; python3 -c 'import tomllib' 2>/dev/null && HAS_TOML=1
toml_get() { # $1 file $2 python expr over `d` → prints repr, or FAIL when tomllib is absent
  [ "$HAS_TOML" = 1 ] || { echo NOTOML; return; }
  F="$1" E="$2" python3 -c 'import os,tomllib; d=tomllib.load(open(os.environ["F"],"rb")); print(eval(os.environ["E"]))'
}
toml_ok() { [ "$HAS_TOML" = 1 ] || return 0; python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$1"; }
json_get() { F="$1" E="$2" python3 -c 'import os,json; d=json.load(open(os.environ["F"])); print(eval(os.environ["E"]))'; }
fresh() { # $1 case dir — an empty login: {} .claude.json, a one-key config.toml, no docs
  rm -rf "$1"; mkdir -p "$1/claude/skills" "$1/codex/skills"
  printf '{}\n' > "$1/claude/.claude.json"
  printf 'cli_auth_credentials_store = "file"\n' > "$1/codex/config.toml"
}
# run <python> <action> <case dir> [extra…]
run() { local py="$1" act="$2" c="$3"; shift 3
  "$py" "$SCRIPT" "$act" --root "$SR" --claude-config "$c/claude/.claude.json" --claude-md "$c/claude/CLAUDE.md" \
    --claude-skills "$c/claude/skills" --codex-home "$c/codex" --override "${OVR:-$WORK/no-override.json}" "$@"
}
install_skills() { for n in sk1 sk2; do mkdir -p "$1/claude/skills/$n" "$1/codex/skills/$n"; cp "$SR/skills/$n/SKILL.md" "$1/claude/skills/$n/"; cp "$SR/skills/$n/SKILL.md" "$1/codex/skills/$n/"; done; }

# --- 1. the shipped defaults -----------------------------------------------------------
D="$ROOT/conf/agent-defaults"
for f in claude/mcp.default.json codex/config.default.toml claude/CLAUDE.default.md codex/AGENTS.default.md; do
  [ -r "$D/$f" ] || fail "conf/agent-defaults/$f missing"
done
[ "$(json_get "$D/claude/mcp.default.json" 'sorted(d["mcpServers"])')" = "['context7', 'fetch', 'github', 'playwright']" ] \
  || fail 'mcp.default.json must ship exactly context7 / fetch / github / playwright' "$(cat "$D/claude/mcp.default.json")"
[ "$(json_get "$D/claude/mcp.default.json" 'set(d)')" = "{'mcpServers'}" ] || fail 'mcp.default.json has a key besides mcpServers'
grep -q 'gh auth token' "$BIN/mcp-github.sh" || fail 'mcp-github.sh does not take the token from gh auth token'
grep -q 'mcp-github.sh' "$D/claude/mcp.default.json" && grep -q 'mcp-github.sh' "$D/codex/config.default.toml" \
  || fail 'the github server must run through bin/mcp-github.sh on both agents'
if [ "$HAS_TOML" = 1 ]; then
  [ "$(toml_get "$D/codex/config.default.toml" 'sorted(k for k in d if k != "mcp_servers")')" = "['approval_policy', 'model_reasoning_effort', 'sandbox_mode']" ] \
    || fail 'config.default.toml top-level keys are not approval_policy / model_reasoning_effort / sandbox_mode' "$(cat "$D/codex/config.default.toml")"
  [ "$(toml_get "$D/codex/config.default.toml" 'sorted(d["mcp_servers"])')" = "['context7', 'fetch', 'github', 'playwright']" ] \
    || fail 'config.default.toml must ship the same four servers'
  [ "$(toml_get "$D/codex/config.default.toml" 'd["approval_policy"], d["sandbox_mode"]')" = "('never', 'danger-full-access')" ] \
    || fail 'config.default.toml posture is not never / danger-full-access'
fi
grep -q '^model *=' "$D/codex/config.default.toml" && fail 'config.default.toml ships `model` — it stays the login'\''s'
for f in claude/CLAUDE.default.md codex/AGENTS.default.md; do
  grep -q '<!-- fleet:agent-defaults begin -->' "$D/$f" && grep -q '<!-- fleet:agent-defaults end -->' "$D/$f" \
    || fail "$f lacks the begin/end markers"
done
# the fleet's own TOML reader agrees with tomllib on the shipped file (check on an
# empty login names every top key + server exactly once)
fresh "$WORK/c1"
run python3 check "$WORK/c1" > "$WORK/o1"; rc=$?
[ "$rc" = 1 ] || fail "check on an empty login should exit 1 (got $rc)" "$(cat "$WORK/o1")"
head -1 "$WORK/o1" | grep -q '^claude 5 missing · codex 8 missing · skills 4 missing$' || fail 'check head line on an empty login' "$(cat "$WORK/o1")"
[ "$(grep -c '^missing    codex\[.*\] mcp ' "$WORK/o1")" = 4 ] || fail 'check did not name 4 missing Codex servers' "$(cat "$WORK/o1")"
grep -q '^missing    codex\[.*\] approval_policy (default "never")$' "$WORK/o1" || fail 'check did not name approval_policy with its default' "$(cat "$WORK/o1")"
grep -q '^missing    claude doc CLAUDE.md fleet block (absent)$' "$WORK/o1" || fail 'check did not name the absent CLAUDE.md block' "$(cat "$WORK/o1")"
grep -q '^missing    claude skill sk1$' "$WORK/o1" && grep -q '^missing    codex\[.*\] skill sk2$' "$WORK/o1" || fail 'check did not count the skills' "$(cat "$WORK/o1")"
ok '1 shipped defaults: four servers, three Codex keys, no model, marked doc blocks; check names each missing item once'

# --- 2. empty login → every default in --------------------------------------------------
run python3 apply "$WORK/c1" > "$WORK/o2" || fail 'apply on an empty login failed' "$(cat "$WORK/o2")"
grep -q '^filled  claude 5 · codex 8$' "$WORK/o2" || fail 'apply summary' "$(cat "$WORK/o2")"
[ "$(grep -c '^set ' "$WORK/o2")" = 13 ] || fail 'apply did not print one set per item' "$(cat "$WORK/o2")"
[ "$(json_get "$WORK/c1/claude/.claude.json" 'sorted(d["mcpServers"])')" = "['context7', 'fetch', 'github', 'playwright']" ] \
  || fail '.claude.json did not get the four servers' "$(cat "$WORK/c1/claude/.claude.json")"
[ "$(json_get "$WORK/c1/claude/.claude.json" 'd["mcpServers"]["context7"]')" = "$(json_get "$D/claude/mcp.default.json" 'd["mcpServers"]["context7"]')" ] \
  || fail 'the context7 entry is not the default object'
toml_ok "$WORK/c1/codex/config.toml" || fail 'merged config.toml does not parse' "$(cat "$WORK/c1/codex/config.toml")"
grep -q '^cli_auth_credentials_store = "file"$' "$WORK/c1/codex/config.toml" || fail 'the login'\''s own key vanished'
grep -q '^approval_policy = "never"$' "$WORK/c1/codex/config.toml" && grep -q '^sandbox_mode = "danger-full-access"$' "$WORK/c1/codex/config.toml" \
  && grep -q '^model_reasoning_effort = ' "$WORK/c1/codex/config.toml" || fail 'the three Codex keys are not in config.toml' "$(cat "$WORK/c1/codex/config.toml")"
for n in context7 playwright github fetch; do
  grep -q "^\[mcp_servers\.$n\]$" "$WORK/c1/codex/config.toml" || fail "config.toml lacks [mcp_servers.$n]" "$(cat "$WORK/c1/codex/config.toml")"
done
if [ "$HAS_TOML" = 1 ]; then
  [ "$(toml_get "$WORK/c1/codex/config.toml" 'd["mcp_servers"]["github"]["args"]')" = "$(toml_get "$D/codex/config.default.toml" 'd["mcp_servers"]["github"]["args"]')" ] \
    || fail 'the merged github args differ from the default'
fi
grep -q '^<!-- fleet:agent-defaults begin -->' "$WORK/c1/claude/CLAUDE.md" && grep -q '^<!-- fleet:agent-defaults end -->' "$WORK/c1/claude/CLAUDE.md" \
  || fail 'CLAUDE.md was not created with the block'
grep -q '^<!-- fleet:agent-defaults begin -->' "$WORK/c1/codex/AGENTS.md" || fail 'AGENTS.md was not created with the block'
grep -q '^skills  4 not installed yet' "$WORK/o2" || fail 'apply did not report the uninstalled skills' "$(cat "$WORK/o2")"
# the skills passes install them → check reads all zeros
install_skills "$WORK/c1"
run python3 check "$WORK/c1" > "$WORK/o2c" || fail 'check after apply + skills still unhappy' "$(cat "$WORK/o2c")"
grep -q '^ok claude 0 missing · codex 0 missing · skills 0 missing$' "$WORK/o2c" || fail 'check ok line' "$(cat "$WORK/o2c")"
ok '2 empty login: 4+4 servers, 3 Codex keys, both doc blocks; filled 5 · 8; check 0 missing'

# --- 3. the login's own is never rewritten ---------------------------------------------------
fresh "$WORK/c3"
cat > "$WORK/c3/claude/.claude.json" <<'EOF'
{
  "numStartups": 3,
  "mcpServers": {
    "playwright": {"type": "stdio", "command": "npx", "args": ["@playwright/mcp@1.2.3", "--headless"], "env": {}},
    "langfuse": {"type": "http", "url": "https://example.invalid/mcp"}
  },
  "projects": {"/x": {"hasTrustDialogAccepted": true}}
}
EOF
cat > "$WORK/c3/codex/config.toml" <<'EOF'
# my codex
approval_policy = "on-request"
model = "gpt-6-sol"

[mcp_servers.fetch]
command = "bash"
args = ["-lc", 'exec "$HOME/.codex/bin/fetch-mcp.sh"']

[projects."/Users/me/x"]
trust_level = "trusted"
EOF
printf '# Global AGENTS.md\n\nMy own rules.\n' > "$WORK/c3/codex/AGENTS.md"
cp "$WORK/c3/codex/config.toml" "$WORK/c3/toml.before"
run python3 apply "$WORK/c3" > "$WORK/o3" || fail 'apply over a login'\''s own failed' "$(cat "$WORK/o3")"
[ "$(json_get "$WORK/c3/claude/.claude.json" 'd["mcpServers"]["playwright"]["args"]')" = "['@playwright/mcp@1.2.3', '--headless']" ] \
  || fail 'the login'\''s playwright was rewritten' "$(cat "$WORK/c3/claude/.claude.json")"
[ "$(json_get "$WORK/c3/claude/.claude.json" 'sorted(d["mcpServers"])')" = "['context7', 'fetch', 'github', 'langfuse', 'playwright']" ] \
  || fail 'the other servers were not added beside the login'\''s' "$(cat "$WORK/c3/claude/.claude.json")"
[ "$(json_get "$WORK/c3/claude/.claude.json" 'd["numStartups"], d["projects"]')" = "(3, {'/x': {'hasTrustDialogAccepted': True}})" ] \
  || fail 'another .claude.json key changed'
grep -q '^own            claude mcp playwright — this login'\''s (npx @playwright/mcp@1.2.3 --headless)$' "$WORK/o3" || fail 'apply did not report the login'\''s playwright' "$(cat "$WORK/o3")"
grep -q '^set            claude mcp context7$' "$WORK/o3" && ! grep -q '^set            claude mcp playwright' "$WORK/o3" || fail 'set lines wrong for the own case' "$(cat "$WORK/o3")"
# every original TOML line is still there, in order; the new keys sit before the first table
toml_ok "$WORK/c3/codex/config.toml" || fail 'merged config.toml (own case) does not parse' "$(cat "$WORK/c3/codex/config.toml")"
python3 - "$WORK/c3/toml.before" "$WORK/c3/codex/config.toml" <<'PY' || fail 'the login'\''s config.toml lines did not survive in order' "$(cat "$WORK/c3/codex/config.toml")"
import sys
before = open(sys.argv[1]).read().split("\n"); after = open(sys.argv[2]).read().split("\n")
i = 0
for line in before:
    while i < len(after) and after[i] != line: i += 1
    if i == len(after): sys.exit(1)
    i += 1
PY
grep -q '^approval_policy = "on-request"$' "$WORK/c3/codex/config.toml" && [ "$(grep -c '^approval_policy' "$WORK/c3/codex/config.toml")" = 1 ] \
  || fail 'approval_policy was rewritten or doubled'
grep -q '^model = "gpt-6-sol"$' "$WORK/c3/codex/config.toml" || fail 'the login'\''s model vanished'
[ "$(grep -n '^sandbox_mode = ' "$WORK/c3/codex/config.toml" | cut -d: -f1)" -lt "$(grep -n '^\[mcp_servers.fetch\]' "$WORK/c3/codex/config.toml" | cut -d: -f1)" ] \
  || fail 'sandbox_mode was not inserted before the first table' "$(cat "$WORK/c3/codex/config.toml")"
[ "$(grep -c '^\[mcp_servers\.fetch\]' "$WORK/c3/codex/config.toml")" = 1 ] && grep -q 'fetch-mcp.sh' "$WORK/c3/codex/config.toml" \
  || fail 'the login'\''s fetch table was rewritten or doubled'
grep -q '^\[mcp_servers\.github\]$' "$WORK/c3/codex/config.toml" && grep -q '^\[mcp_servers\.context7\]$' "$WORK/c3/codex/config.toml" \
  || fail 'the missing servers were not appended'
grep -q '^own            codex\[.*\] approval_policy = "on-request" (default "never")$' "$WORK/o3" || fail 'apply did not report the login'\''s approval_policy' "$(cat "$WORK/o3")"
grep -q '^own            codex\[.*\] mcp fetch — this login'\''s$' "$WORK/o3" || fail 'apply did not report the login'\''s fetch' "$(cat "$WORK/o3")"
head -3 "$WORK/c3/codex/AGENTS.md" | grep -q '^# Global AGENTS.md$' && grep -q '^My own rules.$' "$WORK/c3/codex/AGENTS.md" \
  && grep -q '^<!-- fleet:agent-defaults begin -->' "$WORK/c3/codex/AGENTS.md" || fail 'AGENTS.md: personal text lost or block not appended' "$(cat "$WORK/c3/codex/AGENTS.md")"
grep -q '^filled  claude 4 · codex 6$' "$WORK/o3" || fail 'own-case summary' "$(cat "$WORK/o3")"
ok '3 own: same-name servers and the login'\''s approval_policy / model kept; its lines survive in order; personal AGENTS.md text under the block'

# --- 4. idempotent ----------------------------------------------------------------------
for f in claude/.claude.json codex/config.toml claude/CLAUDE.md codex/AGENTS.md; do cp "$WORK/c3/$f" "$WORK/c3/$(echo "$f" | tr / _).before"; done
run python3 apply "$WORK/c3" > "$WORK/o4" || fail 'second apply failed' "$(cat "$WORK/o4")"
grep -q '^unchanged — ' "$WORK/o4" || fail 'second apply was not a no-op' "$(cat "$WORK/o4")"
grep -q '^wrote ' "$WORK/o4" && fail 'second apply wrote a file' "$(cat "$WORK/o4")"
for f in claude/.claude.json codex/config.toml claude/CLAUDE.md codex/AGENTS.md; do
  cmp -s "$WORK/c3/$f" "$WORK/c3/$(echo "$f" | tr / _).before" || fail "no-op apply rewrote $f"
done
[ -z "$(find "$WORK/c3/claude" "$WORK/c3/codex" -maxdepth 1 -name '*.bak.*' 2>/dev/null)" ] || fail 'apply left a backup'
ok '4 idempotent: second apply writes nothing, no backup'

# --- 5. a stale block is replaced in place ---------------------------------------------------
sed 's/rules on a managed machine/OLD HEADING/' "$WORK/c3/codex/AGENTS.md" > "$WORK/c3/codex/AGENTS.md.new" && mv "$WORK/c3/codex/AGENTS.md.new" "$WORK/c3/codex/AGENTS.md"
printf '\nTrailing personal note.\n' >> "$WORK/c3/codex/AGENTS.md"
run python3 check "$WORK/c3" > "$WORK/o5c"; [ $? = 1 ] || fail 'check passed over a stale block'
grep -q '^missing    codex\[.*\] doc AGENTS.md fleet block (stale)$' "$WORK/o5c" || fail 'check did not call the block stale' "$(cat "$WORK/o5c")"
run python3 apply "$WORK/c3" > "$WORK/o5" || fail 'apply over a stale block failed' "$(cat "$WORK/o5")"
grep -q '^set            codex\[.*\] doc AGENTS.md fleet block (replaced)$' "$WORK/o5" || fail 'apply did not replace the stale block' "$(cat "$WORK/o5")"
grep -q 'OLD HEADING' "$WORK/c3/codex/AGENTS.md" && fail 'the stale text is still there'
grep -q '^My own rules.$' "$WORK/c3/codex/AGENTS.md" && grep -q '^Trailing personal note.$' "$WORK/c3/codex/AGENTS.md" \
  && [ "$(grep -c '<!-- fleet:agent-defaults begin -->' "$WORK/c3/codex/AGENTS.md")" = 1 ] || fail 'text around the block changed, or the block doubled' "$(cat "$WORK/c3/codex/AGENTS.md")"
# one marker without its pair: left alone, reported
printf '# mine\n<!-- fleet:agent-defaults begin -->\nhalf\n' > "$WORK/c3/claude/CLAUDE.md"
run python3 apply "$WORK/c3" > "$WORK/o5b" || fail 'apply over a malformed block failed'
grep -q '^own            claude doc CLAUDE.md — a fleet marker without its pair; left alone$' "$WORK/o5b" || fail 'a half block was not reported' "$(cat "$WORK/o5b")"
[ "$(cat "$WORK/c3/claude/CLAUDE.md")" = "$(printf '# mine\n<!-- fleet:agent-defaults begin -->\nhalf')" ] || fail 'a half block was edited'
ok '5 stale block replaced in place, text around it kept; a half block is left alone and reported'

# --- 6. the override file and --skip -------------------------------------------------------
fresh "$WORK/c6"; install_skills "$WORK/c6"
printf '["playwright", "codex.sandbox_mode", "claude.doc"]\n' > "$WORK/ovr6.json"
OVR="$WORK/ovr6.json" run python3 apply "$WORK/c6" > "$WORK/o6" || fail 'apply with an override failed' "$(cat "$WORK/o6")"
[ "$(json_get "$WORK/c6/claude/.claude.json" 'sorted(d["mcpServers"])')" = "['context7', 'fetch', 'github']" ] || fail 'a bare server name did not shield it on Claude'
grep -q '^\[mcp_servers\.playwright\]' "$WORK/c6/codex/config.toml" && fail 'a bare server name did not shield it on Codex'
grep -q '^sandbox_mode' "$WORK/c6/codex/config.toml" && fail 'codex.sandbox_mode was not shielded'
grep -q '^approval_policy = "never"$' "$WORK/c6/codex/config.toml" || fail 'the unshielded key was not filled'
[ -e "$WORK/c6/claude/CLAUDE.md" ] && fail 'claude.doc was not shielded — CLAUDE.md written'
[ -e "$WORK/c6/codex/AGENTS.md" ] || fail 'codex.doc was shielded by mistake'
grep -q '^kept    4 item(s) left to this login: claude.mcp.playwright, claude.doc, codex\[.*\].sandbox_mode, codex\[.*\].mcp.playwright$' "$WORK/o6" \
  || fail 'apply did not list the kept items' "$(cat "$WORK/o6")"
OVR="$WORK/ovr6.json" run python3 check "$WORK/c6" > "$WORK/o6c" || fail 'check with the same override unhappy' "$(cat "$WORK/o6c")"
grep -q '^ok claude 0 missing · codex 0 missing · skills 0 missing; 4 left to this login: ' "$WORK/o6c" || fail 'check did not list the kept items' "$(cat "$WORK/o6c")"
run python3 check "$WORK/c6" > "$WORK/o6d"; [ $? = 1 ] || fail 'check without the override passed over the shielded items'
head -1 "$WORK/o6d" | grep -q '^claude 2 missing · codex 2 missing · skills 0 missing$' || fail 'check without the override miscounted' "$(cat "$WORK/o6d")"
# `codex` alone shields that agent; --skip adds from the command line; an object override works too
fresh "$WORK/c6b"; install_skills "$WORK/c6b"
printf '{"codex": "my own Codex config"}\n' > "$WORK/ovr6b.json"
cp "$WORK/c6b/codex/config.toml" "$WORK/c6b/toml.before"
OVR="$WORK/ovr6b.json" run python3 apply "$WORK/c6b" --skip claude.mcp.github > "$WORK/o6b" || fail 'apply with codex shielded failed' "$(cat "$WORK/o6b")"
cmp -s "$WORK/c6b/codex/config.toml" "$WORK/c6b/toml.before" && [ ! -e "$WORK/c6b/codex/AGENTS.md" ] || fail '`codex` in the override did not shield the agent'
[ "$(json_get "$WORK/c6b/claude/.claude.json" 'sorted(d["mcpServers"])')" = "['context7', 'fetch', 'playwright']" ] || fail '--skip claude.mcp.github did not shield it'
OVR="$WORK/ovr6b.json" run python3 check "$WORK/c6b" --skip claude.mcp.github > "$WORK/o6bc" || fail 'check with codex shielded unhappy' "$(cat "$WORK/o6bc")"
grep -q '^ok claude 0 missing · codex kept · skills 0 missing' "$WORK/o6bc" || fail 'check did not say codex kept' "$(cat "$WORK/o6bc")"
ok '6 override: a bare name shields a server on both agents, dotted paths shield a key / a doc, `codex` the agent; --skip adds one; check stops counting them'

# --- 7. absent files are not created -------------------------------------------------------
rm -rf "$WORK/c7"; mkdir -p "$WORK/c7/claude/skills"
run python3 apply "$WORK/c7" > "$WORK/o7" || fail 'apply on a login with nothing failed' "$(cat "$WORK/o7")"
[ -e "$WORK/c7/claude/.claude.json" ] && fail 'a .claude.json Claude Code never wrote was created'
[ -e "$WORK/c7/codex" ] && fail 'a Codex home was created'
grep -q '^absent  .*\.claude\.json — Claude Code has not run on this login yet; its 4 server(s) wait for the next sync$' "$WORK/o7" || fail 'apply did not say .claude.json is absent' "$(cat "$WORK/o7")"
grep -q '^absent  .*/c7/codex — Codex is not set up on this login; nothing created$' "$WORK/o7" || fail 'apply did not say the Codex home is absent' "$(cat "$WORK/o7")"
[ -e "$WORK/c7/claude/CLAUDE.md" ] || fail 'CLAUDE.md (under an existing ~/.claude) was not written'
run python3 check "$WORK/c7" > "$WORK/o7c"; [ $? = 1 ] || fail 'check passed with no .claude.json'
head -1 "$WORK/o7c" | grep -q '^claude 4 missing · codex n/a (no .*/c7/codex) · skills 2 missing$' || fail 'check head with no .claude.json / no Codex' "$(cat "$WORK/o7c")"
grep -q '^missing    claude mcp context7 — Claude Code has not run on this login yet$' "$WORK/o7c" || fail 'check did not say why the servers are missing' "$(cat "$WORK/o7c")"
ok '7 absent: no .claude.json / no Codex home is never created; check says n/a for Codex'

# --- 8. a held .claude.json.lock is never stolen -----------------------------------------------
fresh "$WORK/c8"
mkdir "$WORK/c8/claude/.claude.json.lock"
FLEET_KEYS_LOCK_WAIT=0.3 run python3 apply "$WORK/c8" > "$WORK/o8" 2>&1; rc=$?
[ "$rc" = 2 ] || fail "apply through a held lock should exit 2 (got $rc)" "$(cat "$WORK/o8")"
[ "$(cat "$WORK/c8/claude/.claude.json")" = '{}' ] || fail 'apply wrote .claude.json while its lock was held'
[ -d "$WORK/c8/claude/.claude.json.lock" ] || fail 'apply removed someone else'\''s lock'
rmdir "$WORK/c8/claude/.claude.json.lock"
run python3 apply "$WORK/c8" > /dev/null || fail 'apply after the lock was released failed'
[ -e "$WORK/c8/claude/.claude.json.lock" ] && fail 'apply left its lock behind'
ok '8 a held .claude.json.lock: exit 2, nothing written, lock untouched; clean after release'

# --- 9. an inline mcp_servers table is not extended ----------------------------------------------
fresh "$WORK/c9"
printf 'mcp_servers = { mine = { command = "x" } }\n' > "$WORK/c9/codex/config.toml"
run python3 apply "$WORK/c9" > "$WORK/o9" || fail 'apply over an inline mcp_servers failed' "$(cat "$WORK/o9")"
toml_ok "$WORK/c9/codex/config.toml" || fail 'merged config.toml (inline case) does not parse' "$(cat "$WORK/c9/codex/config.toml")"
grep -q '^\[mcp_servers\.' "$WORK/c9/codex/config.toml" && fail 'a [mcp_servers.x] header was appended under an inline table (invalid TOML)'
grep -q '^approval_policy = "never"$' "$WORK/c9/codex/config.toml" || fail 'the top keys were not filled beside an inline table'
[ "$(grep -c '^own            codex\[.*\] mcp .* — mcp_servers is an inline table, not extended$' "$WORK/o9")" = 4 ] || fail 'the inline table was not reported for each server' "$(cat "$WORK/o9")"
ok '9 inline mcp_servers: top keys filled, servers reported not appended, file still parses'

# --- 10. malformed defaults are refused ----------------------------------------------------------
BR="$WORK/badroot"; rm -rf "$BR"; mkdir -p "$BR/conf/agent-defaults" "$BR/skills"
cp -R "$ROOT/conf/agent-defaults/claude" "$ROOT/conf/agent-defaults/codex" "$BR/conf/agent-defaults/"
fresh "$WORK/c10"
bad() { # $1 label — apply from $BR must exit 2 and write nothing
  python3 "$SCRIPT" apply --root "$BR" --claude-config "$WORK/c10/claude/.claude.json" --claude-md "$WORK/c10/claude/CLAUDE.md" \
    --claude-skills "$WORK/c10/claude/skills" --codex-home "$WORK/c10/codex" --override "$WORK/no-override.json" > "$WORK/o10" 2>&1; rc=$?
  [ "$rc" = 2 ] || fail "$1: expected exit 2, got $rc" "$(cat "$WORK/o10")"
  [ "$(cat "$WORK/c10/claude/.claude.json")" = '{}' ] || fail "$1: wrote .claude.json anyway"
}
printf 'model = "x"\napproval_policy = "never"\n' > "$BR/conf/agent-defaults/codex/config.default.toml"; bad 'defaults with model'
grep -q 'model. is never shipped' "$WORK/o10" || fail 'model refusal did not say why' "$(cat "$WORK/o10")"
cp "$ROOT/conf/agent-defaults/codex/config.default.toml" "$BR/conf/agent-defaults/codex/config.default.toml"
printf '{"mcpServers": {"github": {"command": "x", "env": {"GITHUB_TOKEN": "ghp_abc"}}}}\n' > "$BR/conf/agent-defaults/claude/mcp.default.json"; bad 'defaults with a token key'
grep -q 'credential-shaped key' "$WORK/o10" || fail 'token refusal did not say why' "$(cat "$WORK/o10")"
cp "$ROOT/conf/agent-defaults/claude/mcp.default.json" "$BR/conf/agent-defaults/claude/mcp.default.json"
printf '<!-- fleet:agent-defaults begin -->\nno end\n' > "$BR/conf/agent-defaults/codex/AGENTS.default.md"; bad 'doc block without end'
python3 "$SCRIPT" apply --root "$WORK/nowhere" --claude-config "$WORK/c10/claude/.claude.json" --codex-home "$WORK/c10/codex" >/dev/null 2>&1; [ $? = 2 ] || fail 'a root without conf/agent-defaults was not refused with exit 2'
ok '10 malformed defaults (model, a credential-shaped key, a half doc block, no defaults dir) exit 2 and write nothing'

# --- 11. no token anywhere ---------------------------------------------------------------------
TOKRE='gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|GITHUB_PERSONAL_ACCESS_TOKEN'
grep -rEl "$TOKRE" "$ROOT/conf/agent-defaults" "$WORK/c1/claude/.claude.json" "$WORK/c1/codex/config.toml" "$WORK/c3/claude/.claude.json" "$WORK/c3/codex/config.toml" \
  && fail 'a token (or the token env key) appears in a shipped or merged file'
grep -E 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_' "$BIN/mcp-github.sh" && fail 'mcp-github.sh carries a token literal'
grep -E '>>? *["$]?[A-Za-z0-9_./~$"-]*(conf|json|toml|log)' "$BIN/mcp-github.sh" && fail 'mcp-github.sh writes to a file'
ok '11 no token in the shipped files, the wrappers or the merged configs; the token env key is set only by the wrapper'

# --- 12. the wrappers -------------------------------------------------------------------------------
bash -n "$BIN/mcp-github.sh" && bash -n "$BIN/mcp-fetch.sh" || fail 'a wrapper does not parse'
SH="$WORK/shim"; mkdir -p "$SH"
cat > "$SH/gh" <<'EOF'
#!/bin/bash
[ "$1 $2" = "auth token" ] || exit 9
[ -n "${SHIM_TOKEN:-}" ] || exit 1
printf '%s\n' "$SHIM_TOKEN"
EOF
cat > "$SH/github-mcp-server" <<'EOF'
#!/bin/bash
printf 'argv=%s\n' "$*"
printf 'token=%s\n' "${GITHUB_PERSONAL_ACCESS_TOKEN:-unset}"
EOF
cat > "$SH/uvx" <<'EOF'
#!/bin/bash
printf 'uvx %s\n' "$*"
EOF
chmod +x "$SH/gh" "$SH/github-mcp-server" "$SH/uvx"
out=$(PATH="$SH:/usr/bin:/bin" SHIM_TOKEN=shim-secret-value bash "$BIN/mcp-github.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf 'argv=stdio\ntoken=shim-secret-value')" ] || fail "mcp-github.sh did not exec the server with stdio + the gh token (rc=$rc)" "$out"
out=$(PATH="$SH:/usr/bin:/bin" bash "$BIN/mcp-github.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'no GitHub token' || fail "mcp-github.sh without a token should exit 1 and say so (rc=$rc)" "$out"
out=$(PATH="$SH:/usr/bin:/bin" bash "$BIN/mcp-fetch.sh" --extra 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = 'uvx mcp-server-fetch --extra' ] || fail "mcp-fetch.sh did not exec uvx mcp-server-fetch (rc=$rc)" "$out"
out=$(PATH="/usr/bin:/bin" bash "$BIN/mcp-fetch.sh" 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'brew install uv' || fail "mcp-fetch.sh with no runner should exit 1 naming the install (rc=$rc)" "$out"
ok '12 wrappers: github execs the server with stdio + the gh token in env (exit 1 without one); fetch execs uvx, names the install when none'

# --- 13. the no-tomllib path: macOS /usr/bin/python3 (3.9) fills the same files -----------------
if [ -x /usr/bin/python3 ] && ! /usr/bin/python3 -c 'import tomllib' 2>/dev/null; then
  fresh "$WORK/c13"
  run /usr/bin/python3 apply "$WORK/c13" > "$WORK/o13" || fail 'apply under /usr/bin/python3 (no tomllib) failed' "$(cat "$WORK/o13")"
  cmp -s "$WORK/c13/codex/config.toml" "$WORK/c1/codex/config.toml" || fail 'the no-tomllib merge differs from the tomllib one' "$(diff "$WORK/c13/codex/config.toml" "$WORK/c1/codex/config.toml")"
  [ "$(json_get "$WORK/c13/claude/.claude.json" 'sorted(d["mcpServers"])')" = "['context7', 'fetch', 'github', 'playwright']" ] || fail 'no-tomllib: .claude.json servers'
  run /usr/bin/python3 apply "$WORK/c13" > "$WORK/o13b" || fail 'second no-tomllib apply failed'
  grep -q '^unchanged' "$WORK/o13b" || fail 'no-tomllib apply is not idempotent' "$(cat "$WORK/o13b")"
  ok '13 /usr/bin/python3 without tomllib produces the same config.toml, idempotently'
else
  ok '13 (skipped: no tomllib-less /usr/bin/python3 on this box — the macOS CI leg runs it)'
fi

printf 'PASS  fleet-agent-defaults-selftest (%d checks)\n' "$pass"
