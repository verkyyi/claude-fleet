#!/bin/bash
# fleet-agent-bundle-selftest.sh — a computer with ONLY the client gets the same
# Agent configuration a full install does (issue #1725, EPIC #1718 C7).
#
# Drives bin/fleet-install.sh (--no-hub, the files from this repo over file://,
# no node step) into a throwaway HOME, then reads what landed:
#
#   A. package    conf/agent-bundle.manifest expands (fleet-agent-bundle.py
#                 files) to existing files, every hook script the hook table
#                 wires from hooks/ is in it, the version is a stable 12-hex
#                 digest; the hub's client manifest carries the package
#                 (fleet-client-mirror.sh --check)
#   B. install    client-only → the four categories are there: Claude's hooks
#                 (wired through <root>/bin/fleet-hook-run.sh, identity kept),
#                 skills + commands, MCP servers (github / fetch at the
#                 package's bin/), the mod; Codex's skills + MCP servers;
#                 `fleet doctor` prints `PASS agents 4/4`
#   C. overrides  agent-overrides.json / settings.fleet-override.json and a
#                 server the login already had are never written
#   D. again      a second install changes no file (idempotent), no .bak
#   E. shim       a guard runs from the package and still blocks; pane
#                 plumbing the package does not carry exits 0; a full
#                 install's script at ~/.claude/fleet wins
#   F. node       with ~/.claude/fleet here, --bundle says so and writes nothing;
#                 a later node merge replaces the client wiring in place
#   G. retired    a command the previous package had and this one dropped is
#                 removed; a personal one of the same kind is left alone
#   H. no codex   no ~/.codex → nothing is created there
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
real="$BIN/fleet-agent-bundle.py"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-agent-bundle-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

GITDIR="$(dirname "$(command -v git)")"
PY="$(command -v python3)"
SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin:$GITDIR:$(dirname "$PY")"

# fresh <name> — a HOME that has run Claude Code once (an empty ~/.claude.json)
# and has Codex set up (~/.codex); prints its path
fresh() {
  local h="$WORK/$1/home"
  mkdir -p "$h/.codex" "$h/.claude"
  echo '{"numStartups": 1}' > "$h/.claude.json"
  printf '%s\n' "$h"
}
# install <home> — the one line, client only, from this repo
install() {
  env -i PATH="$SYS_PATH" HOME="$1" SHELL=/bin/zsh TMPDIR="$WORK" \
    FLEET_INSTALL_NO_HUB=1 FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 \
    FLEET_INSTALL_SRC="file://$REPO" sh "$REPO/bin/fleet-install.sh" 2>&1
}
# snap <home> — a digest of every file the apply may write
snap() {
  (cd "$1" && find .claude .claude.json .codex .config/claude-fleet -type f 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done)
}

# ── A — the package ──────────────────────────────────────────────────────────
files=$("$PY" "$REPO/bin/fleet-agent-bundle.py" files --root "$REPO"); rc=$?
[ "$rc" = 0 ] && [ -n "$files" ] && ok "A the manifest expands ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files)" || bad "A files rc=$rc"
miss=''
for c in hooks/settings-hooks.json bin/fleet-hook-run.sh conf/agent-defaults/claude/mcp.default.json \
         bin/mcp-github.sh mod/fleet/.claude-plugin/plugin.json skills/doc-preview/SKILL.md commands/fleet-claim.md; do
  printf '%s\n' "$files" | grep -xF >/dev/null "$c" || miss="$miss $c"
done
for h in $(grep -o '\.claude/fleet/hooks/[^ "]*' "$REPO/hooks/settings-hooks.json" | sed 's#^\.claude/fleet/##' | sort -u); do
  printf '%s\n' "$files" | grep -xF >/dev/null "$h" || miss="$miss $h"
done
[ -z "$miss" ] && ok "A every category's anchor + every wired hooks/ script is in the package" || bad "A missing:$miss"
v1=$("$PY" "$REPO/bin/fleet-agent-bundle.py" version --root "$REPO"); v2=$("$PY" "$REPO/bin/fleet-agent-bundle.py" version --root "$REPO")
case "$v1" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) [ "$v1" = "$v2" ] && ok "A version $v1, stable" || bad "A version moves: $v1 $v2" ;; *) bad "A version: $v1" ;; esac
if [ -x "$REPO/bin/fleet-client-mirror.sh" ] && [ -d "$REPO/tokenledger/internal/api/fleetclient" ]; then
  out=$(bash "$REPO/bin/fleet-client-mirror.sh" --check 2>&1) && ok "A the hub's client manifest carries the package (mirror --check)" || bad "A mirror: $out"
fi

# ── B — client-only install: the four categories ─────────────────────────────
H=$(fresh b); out=$(install "$H"); rc=$?
R="$H/.local/share/claude-fleet"
[ "$rc" = 0 ] && echo "$out" | grep >/dev/null '^Agent 配置: 已装' && ok "B install exit 0, says the Agent configuration is in" || bad "B rc=$rc: $out"
[ ! -e "$H/.claude/fleet" ] && ok "B no ~/.claude/fleet (client only)" || bad "B a full install appeared"
chk=$("$PY" - "$H" "$R" <<'PY'
import json, os, sys
h, r = sys.argv[1], sys.argv[2]
out = []
s = json.load(open(os.path.join(h, ".claude/settings.json")))
cmds = [x["command"] for gs in s["hooks"].values() for g in gs for x in g["hooks"]]
via = [c for c in cmds if "/bin/fleet-hook-run.sh" in c and "~/.claude/fleet/" in c]
out.append("hooks %d/%d" % (len(via), len(cmds)))
c = json.load(open(os.path.join(h, ".claude.json")))
m = c.get("mcpServers", {})
out.append("mcp " + ",".join(sorted(m)))
out.append("github " + " ".join(m.get("github", {}).get("args", [])))
print("\n".join(out))
PY
)
nh=$(printf '%s\n' "$chk" | sed -n 's/^hooks //p')
case "$nh" in 0/*|'') bad "B hooks: $chk" ;; *) [ "${nh%/*}" = "${nh#*/}" ] && ok "B Claude hooks: all $nh wired through the package's shim" || bad "B hooks: $nh" ;; esac
printf '%s\n' "$chk" | grep -x >/dev/null 'mcp context7,fetch,github,playwright' && ok "B Claude MCP: context7 · fetch · github · playwright" || bad "B mcp: $chk"
printf '%s\n' "$chk" | grep >/dev/null "^github .*\$HOME/.local/share/claude-fleet/bin/mcp-github.sh" && [ -x "$R/bin/mcp-github.sh" ] \
  && ok "B github MCP runs the package's bin/mcp-github.sh" || bad "B github args: $chk"
[ -f "$H/.claude/skills/doc-preview/SKILL.md" ] && [ -x "$H/.claude/skills/doc-preview/share.sh" ] && [ -f "$H/.claude/commands/fleet-claim.md" ] \
  && ok "B Claude skills + commands (a skill's script executable)" || bad "B claude skills: $(ls "$H/.claude/skills" "$H/.claude/commands" 2>&1 | tr '\n' ' ')"
[ -f "$H/.codex/skills/doc-preview/SKILL.md" ] && [ -f "$H/.codex/skills/fleet-claim/SKILL.md" ] \
  && ok "B Codex skills (repo skills + command skills)" || bad "B codex skills: $(ls "$H/.codex/skills" 2>&1 | tr '\n' ' ')"
n=$(grep -c '^\[mcp_servers\.' "$H/.codex/config.toml" 2>/dev/null)
[ "$n" = 4 ] && grep -q 'local/share/claude-fleet/bin/mcp-fetch.sh' "$H/.codex/config.toml" && ok "B Codex MCP: 4 servers, fetch at the package's bin/" || bad "B codex mcp: $n $(cat "$H/.codex/config.toml" 2>&1)"
[ -f "$R/mod/fleet/.claude-plugin/plugin.json" ] && ok "B the mod (mod/fleet/.claude-plugin/plugin.json) is in the package" || bad "B no mod"
doc=$(env -i PATH="$SYS_PATH" HOME="$H" "$H/.local/bin/fleet" doctor 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$doc" | grep >/dev/null 'PASS  agents   4/4 · hooks .* · skills .* · mcp ok · mod ' \
  && ok "B fleet doctor: $(printf '%s' "$doc" | sed 's/^ *//')" || bad "B fleet doctor rc=$rc: $doc"

# ── C — the login's own: overrides and what it already had ───────────────────
H=$(fresh c)
mkdir -p "$H/.config/claude-fleet"
echo '["playwright", "codex.skills", "claude.doc"]' > "$H/.config/claude-fleet/agent-overrides.json"
echo '["effortLevel"]' > "$H/.claude/settings.fleet-override.json"
echo '{"numStartups": 1, "mcpServers": {"github": {"type": "stdio", "command": "my-github"}}}' > "$H/.claude.json"
out=$(install "$H"); rc=$?
chk=$("$PY" - "$H" <<'PY'
import json, os, sys
h = sys.argv[1]
c = json.load(open(os.path.join(h, ".claude.json")))
s = json.load(open(os.path.join(h, ".claude/settings.json")))
print(sorted(c["mcpServers"]), c["mcpServers"]["github"]["command"], "effortLevel" in s, "outputStyle" in s)
PY
)
[ "$rc" = 0 ] && [ "$chk" = "['context7', 'fetch', 'github'] my-github False True" ] \
  && ok "C overrides kept: no playwright, own github untouched, no effortLevel (outputStyle filled)" || bad "C rc=$rc chk=$chk out=$out"
[ ! -e "$H/.codex/skills" ] && ok "C codex.skills overridden → no Codex skills written" || bad "C codex skills: $(ls "$H/.codex/skills")"
grep -q 'fleet:agent-defaults' "$H/.claude/CLAUDE.md" 2>/dev/null && bad "C claude.doc overridden but CLAUDE.md got the block" || ok "C claude.doc overridden → no CLAUDE.md block"
doc=$(env -i PATH="$SYS_PATH" HOME="$H" "$H/.local/bin/fleet" doctor 2>&1)
printf '%s\n' "$doc" | grep >/dev/null 'PASS  agents   4/4' && ok "C what the login keeps is not counted missing" || bad "C doctor: $doc"

# ── D — again: nothing changes ───────────────────────────────────────────────
H="$WORK/b/home"
before=$(snap "$H"); out=$(install "$H"); rc=$?
after=$(snap "$H")
[ "$rc" = 0 ] && [ "$before" = "$after" ] && ok "D a second install writes nothing ($(printf '%s\n' "$after" | wc -l | tr -d ' ') files compared)" \
  || bad "D changed: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5)"
ls "$H/.claude/"settings.json.bak.* >/dev/null 2>&1 && bad "D a settings backup appeared" || ok "D no settings.json.bak"

# ── E — the shim ─────────────────────────────────────────────────────────────
# the wired path as it arrives when the hook's shell left the ~ unexpanded
TL='~'
R="$H/.local/share/claude-fleet"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | env -i PATH="$SYS_PATH" HOME="$H" TMUX=/tmp/x,1,0 TMUX_PANE=%1 sh "$R/bin/fleet-hook-run.sh" python3 "$TL/.claude/fleet/hooks/bash-guard.py" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "E bash-guard runs from the package and blocks (exit 2)" || bad "E guard rc=$rc: $out"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -i PATH="$SYS_PATH" HOME="$H" sh "$R/bin/fleet-hook-run.sh" python3 "$TL/.claude/fleet/hooks/bash-guard.py" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "E a harmless command passes" || bad "E ls rc=$rc: $out"
env -i PATH="$SYS_PATH" HOME="$H" sh "$R/bin/fleet-hook-run.sh" sh "$TL/.claude/fleet/bin/set-claude-state.sh" busy </dev/null; rc=$?
[ "$rc" = 0 ] && ok "E pane plumbing the package does not carry → exit 0" || bad "E plumbing rc=$rc"
mkdir -p "$H/.claude/fleet/bin"; printf 'echo node-ran "$@"\n' > "$H/.claude/fleet/bin/set-claude-state.sh"
out=$(env -i PATH="$SYS_PATH" HOME="$H" sh "$R/bin/fleet-hook-run.sh" sh "$H/.claude/fleet/bin/set-claude-state.sh" busy 2>&1)
[ "$out" = "node-ran busy" ] && ok "E a full install's script wins" || bad "E node script: $out"
rm -rf "$H/.claude/fleet"

# ── F — a login with the full install ────────────────────────────────────────
mkdir -p "$H/.claude/fleet/bin"; : > "$H/.claude/fleet/bin/fleet-lib.sh"
before=$(snap "$H")
out=$(env -i PATH="$SYS_PATH" HOME="$H" bash "$R/bin/fleet-install-apply.sh" --bundle --root "$R" 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep >/dev/null '^bundle: skip — this login has the full install' && [ "$before" = "$(snap "$H")" ] \
  && ok "F full install here → --bundle skips, nothing written" || bad "F rc=$rc: $out"
rm -rf "$H/.claude/fleet"
cp "$H/.claude/settings.json" "$WORK/node-settings.json"
"$PY" "$REPO/bin/fleet-hooks-merge.py" merge --source "$REPO/hooks/settings-hooks.json" --settings "$WORK/node-settings.json" >/dev/null 2>&1
out=$("$PY" "$REPO/bin/fleet-hooks-merge.py" check --source "$REPO/hooks/settings-hooks.json" --settings "$WORK/node-settings.json" 2>&1); rc=$?
[ "$rc" = 0 ] && ! grep -q fleet-hook-run "$WORK/node-settings.json" && ok "F a later node merge replaces the client wiring in place ($out)" || bad "F node merge rc=$rc: $out"

# ── G — a retired command goes, a personal one stays ─────────────────────────
printf '# /fleet-gone\n\n<!-- fleet skill · owner: worker -->\n' > "$H/.claude/commands/fleet-gone.md"
printf '# mine\n' > "$H/.claude/commands/fleet-mine.md"
st="$H/.config/claude-fleet/agent-bundle.state"
printf 'commands/fleet-gone.md\ncommands/fleet-mine.md\n' >> "$st"
out=$(env -i PATH="$SYS_PATH" HOME="$H" bash "$R/bin/fleet-install-apply.sh" --bundle --root "$R" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$H/.claude/commands/fleet-gone.md" ] && [ -e "$H/.claude/commands/fleet-mine.md" ] \
  && ok "G retired fleet command removed, a personal file of that name left alone" || bad "G rc=$rc: $out"
grep -q 'fleet-gone' "$st" && bad "G the state still lists the retired file" || ok "G the state records the new package"

# ── H — no Codex on this login ───────────────────────────────────────────────
H="$WORK/h/home"; mkdir -p "$H"; echo '{"numStartups": 1}' > "$H/.claude.json"
out=$(install "$H"); rc=$?
[ "$rc" = 0 ] && [ ! -e "$H/.codex" ] && ok "H no ~/.codex → nothing created there" || bad "H rc=$rc codex=$(ls -R "$H/.codex" 2>&1 | head -3)"

[ "$fail" = 0 ] && echo "PASS fleet-agent-bundle-selftest" || echo "FAIL fleet-agent-bundle-selftest"
exit "$fail"
