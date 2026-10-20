#!/bin/bash
# fleet-agent-bundle-selftest.sh — the Agent configuration package (issue
# #1725, EPIC #1718 C7) and how a computer with ONLY the client lives without it
# (issue #4826, EPIC #4823 C3: the package is 承载's — the client package
# carries none, `fleet host on` installs it with the whole tree).
#
# Drives bin/fleet-install.sh (--no-hub, the files from this repo over file://,
# no node step) into a throwaway HOME, then reads what landed:
#
#   A. package    conf/agent-bundle.manifest expands (fleet-agent-bundle.py
#                 files) to existing files, every hook script the hook table
#                 wires from hooks/ is in it, the version is a stable 12-hex
#                 digest; the hub's client manifest carries NONE of it
#                 (fleet-client-mirror.sh --check, issue #4826)
#   I. client     (issue #4826) the install line, client only: no package file
#                 in ~/.claude/fleet, nothing written into the login's Claude /
#                 Codex config, the doctor has no agents row; a login an earlier
#                 client wired (hooks through its fleet-hook-run.sh, a personal
#                 hook through fleet-hook-personal.sh, github / fetch MCP at its
#                 bin/mcp-*.sh — Claude's and Codex's) → exactly those entries
#                 go, the person's own stay byte for byte, each file kept beside
#                 once; again → nothing; ~/.claude/fleet the full install, or
#                 FLEET_HOST=1 → nothing touched
#
# Legs B–H pin the package's apply (fleet-install-apply.sh --bundle) the way an
# earlier client ran it — the package laid beside the client by hand, then
# applied — until that road is deleted:
#
#   B. install    client-only → the four categories are there: Claude's hooks
#                 (wired through <root>/bin/fleet-hook-run.sh, identity kept),
#                 skills + commands, MCP servers (github / fetch at the
#                 package's bin/), the mod; Codex's skills + MCP servers;
#                 `fleet doctor` prints `PASS agents 4/4`
#   C. overrides  agent-overrides.json / settings.fleet-override.json and a
#                 server the login already had are never written
#   D. again      a second apply changes no file (idempotent), no .bak
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
. "$BIN/selftest-lib.sh"
real="$BIN/fleet-agent-bundle.py"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-agent-bundle-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
st_tally

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
# line <home> [<files dir>] — the one line, client only, from this repo; the
# files land in the one fleet directory, ~/.claude/fleet (#1804), unless a
# second argument names another (FLEET_INSTALL_HOME — legs E–G's separate one)
line() {
  env -i PATH="$SYS_PATH" HOME="$1" SHELL=/bin/zsh TMPDIR="$WORK" ${2:+FLEET_INSTALL_HOME="$2"} \
    FLEET_INSTALL_NO_HUB=1 FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 \
    FLEET_INSTALL_SRC="file://$REPO" sh "$REPO/bin/fleet-install.sh" 2>&1
}
# install <home> [<files dir>] — what the line did before #4826: the client,
# then the package laid beside it and applied (fleet-install-apply.sh --bundle)
install() {
  local r=${2:-$1/.claude/fleet} f out rc
  out=$(line "$@") || { printf '%s\n' "$out"; return 1; }
  "$PY" "$REPO/bin/fleet-agent-bundle.py" files --root "$REPO" | while IFS= read -r f; do
    mkdir -p "$r/$(dirname "$f")"; cp -p "$REPO/$f" "$r/$f"
  done
  apply "$1" "$r"
}
# apply <home> [<files dir>] — the package's apply alone, again
apply() {
  env -i PATH="$SYS_PATH" HOME="$1" TMPDIR="$WORK" bash "${2:-$1/.claude/fleet}/bin/fleet-install-apply.sh" --bundle --root "${2:-$1/.claude/fleet}" 2>&1
}
# snap <home> — a digest of every file the apply may write
snap() {
  # never the install itself: ~/.claude/fleet IS the files' directory now (#1804),
  # where python leaves its __pycache__
  (cd "$1" && find .claude .claude.json .codex .config/claude-fleet -path .claude/fleet -prune -o -type f -print 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done)
}

# ── A — the package ──────────────────────────────────────────────────────────
files=$("$PY" "$REPO/bin/fleet-agent-bundle.py" files --root "$REPO"); rc=$?
[ "$rc" = 0 ] && [ -n "$files" ] && st_ok_all "A the manifest expands ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files)" || st_miss "A files rc=$rc"
miss=''
for c in hooks/settings-hooks.json bin/fleet-hook-run.sh conf/agent-defaults/claude/mcp.default.json \
         bin/mcp-github.sh bin/fleet-codex-rpc.py mod/fleet/.claude-plugin/plugin.json skills/fleet-open/SKILL.md commands/fleet-context.md; do
  printf '%s\n' "$files" | grep -xF >/dev/null "$c" || miss="$miss $c"
done
for h in $(grep -o '\.claude/fleet/hooks/[^ "]*' "$REPO/hooks/settings-hooks.json" | sed 's#^\.claude/fleet/##' | sort -u); do
  printf '%s\n' "$files" | grep -xF >/dev/null "$h" || miss="$miss $h"
done
[ -z "$miss" ] && st_ok_all "A every category's anchor + every wired hooks/ script is in the package" || st_miss "A missing:$miss"
v1=$("$PY" "$REPO/bin/fleet-agent-bundle.py" version --root "$REPO"); v2=$("$PY" "$REPO/bin/fleet-agent-bundle.py" version --root "$REPO")
case "$v1" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) [ "$v1" = "$v2" ] && st_ok_all "A version $v1, stable" || st_miss "A version moves: $v1 $v2" ;; *) st_miss "A version: $v1" ;; esac
if [ -x "$REPO/bin/fleet-client-mirror.sh" ] && [ -d "$REPO/tokenledger/hub/api/fleetclient" ]; then
  out=$(bash "$REPO/bin/fleet-client-mirror.sh" --check 2>&1) && st_ok_all "A the hub's client manifest is current (mirror --check)" || st_miss "A mirror: $out"
  # (fleet_redact.py is the client's too: its config scan reads it)
  inman=$(awk '!/^[[:space:]]*#/ && NF { print $1 }' "$REPO/tokenledger/hub/api/fleetclient/manifest" | grep -xF -f <(printf '%s\n' "$files") | grep -vx 'bin/fleet_redact.py')
  [ -z "$inman" ] && st_ok_all "A the client package carries none of it (承载's, #4826)" || st_miss "A the client manifest still lists: $(printf '%s' "$inman" | tr '\n' ' ')"
fi

# ── I — client only, since #4826 ─────────────────────────────────────────────
H=$(fresh i); out=$(line "$H"); rc=$?
R="$H/.claude/fleet"
left=$(printf '%s\n' "$files" | grep -vx 'bin/fleet_redact.py' | while IFS= read -r f; do [ -e "$R/$f" ] && printf '%s ' "$f"; done)
[ "$rc" = 0 ] && [ -x "$R/bin/fleet" ] && [ -z "$left" ] && ! printf '%s' "$out" | grep -q 'Agent 配置' \
  && st_ok_all "I the line installs no package file and says nothing of it" || st_miss "I rc=$rc left=[$left] $out"
[ ! -e "$H/.claude/settings.json" ] && [ "$(cat "$H/.claude.json")" = '{"numStartups": 1}' ] && [ -z "$(ls -A "$H/.codex")" ] \
  && st_ok_all "I nothing written into the login's Claude / Codex config" || st_miss "I wrote: $(ls -A "$H/.claude" "$H/.codex" | tr '\n' ' ') $(cat "$H/.claude.json")"
doc=$(env -i PATH="$SYS_PATH" HOME="$H" FLEET_NOTIFY=0 "$H/.local/bin/fleet" doctor 2>&1)
printf '%s\n' "$doc" | grep -q ' agents ' && st_miss "I the doctor still has an agents row: $doc" || st_ok_all "I the doctor has no agents row"
# a login an earlier client wired
wire() {   # wire <home> — what fleet-install-apply.sh --bundle left there, plus the person's own
  mkdir -p "$1/.claude" "$1/.codex"
  cat > "$1/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "sh \"$HOME/.claude/fleet/./bin/fleet-hook-run.sh\" python3 ~/.claude/fleet/hooks/bash-guard.py"},
          {"type": "command", "command": "my-own-guard.sh"}
        ]
      }
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "sh \"$HOME/.claude/fleet/./bin/fleet-hook-run.sh\" bash ~/.claude/fleet/bin/set-claude-state.sh done"}]},
      {"hooks": [{"type": "command", "command": "sh \"$HOME/.claude/fleet/bin/fleet-hook-personal.sh\" Stop -- 'say done'"}]}
    ]
  }
}
EOF
  cat > "$1/.claude.json" <<'EOF'
{"numStartups": 9, "mcpServers": {"github": {"command": "bash", "args": ["-lc", "exec \"$HOME/.claude/fleet/bin/mcp-github.sh\""]}, "fetch": {"command": "bash", "args": ["-lc", "exec \"$HOME/.claude/fleet/bin/mcp-fetch.sh\""]}, "mine": {"command": "my-mcp"}}}
EOF
  printf 'model = "o3"\n\n[mcp_servers.github]\ncommand = "bash"\nargs = ["-lc", "exec \\"$HOME/.claude/fleet/bin/mcp-github.sh\\""]\n\n[mcp_servers.mine]\ncommand = "my-mcp"\n' > "$1/.codex/config.toml"
}
H=$(fresh u); wire "$H"; out=$(line "$H"); rc=$?
chk=$("$PY" - "$H" <<'PY'
import json, os, sys
h = sys.argv[1]
s = json.load(open(os.path.join(h, ".claude/settings.json")))
cmds = [x["command"] for gs in s.get("hooks", {}).values() for g in gs for x in g["hooks"]]
c = json.load(open(os.path.join(h, ".claude.json")))
print(s["model"], cmds, sorted(c["mcpServers"]), c["numStartups"])
PY
)
[ "$rc" = 0 ] && [ "$chk" = "opus ['my-own-guard.sh'] ['mine'] 9" ] && st_ok_all "I an earlier client's hooks + MCP go, the person's own stay" || st_miss "I unwire rc=$rc chk=$chk"
[ "$(cat "$H/.codex/config.toml")" = "$(printf 'model = "o3"\n\n[mcp_servers.mine]\ncommand = "my-mcp"')" ] \
  && st_ok_all "I Codex: its [mcp_servers.github] table goes as text, the rest byte for byte" || st_miss "I codex: $(cat "$H/.codex/config.toml")"
printf '%s' "$out" | grep -q '^Agent 配置: 撤下了旧客户端接进来的 钩子 3 条、Claude MCP fetch·github、Codex MCP github' \
  && st_ok_all "I one line says what went" || st_miss "I said: $(printf '%s' "$out" | grep 'Agent 配置')"
nb=$(ls "$H/.claude/"settings.json.fleet-bak-* "$H/".claude.json.fleet-bak-* "$H/.codex/"config.toml.fleet-bak-* 2>/dev/null | wc -l | tr -d ' ')
[ "$nb" = 3 ] && grep -q fleet-hook-run "$H/.claude/"settings.json.fleet-bak-* && st_ok_all "I each file kept beside once" || st_miss "I backups: $nb"
# cfg <home> — the three files the unwire may touch, and the backups beside them
cfg() { (cd "$1" && for f in .claude/*fleet-bak* .codex/*fleet-bak* .*fleet-bak*; do [ -e "$f" ] && echo "$f"; done; cksum .claude/settings.json .claude.json .codex/config.toml 2>/dev/null); }
before=$(cfg "$H"); out=$(line "$H"); rc=$?
[ "$rc" = 0 ] && [ "$before" = "$(cfg "$H")" ] && ! printf '%s' "$out" | grep -q 'Agent 配置' && st_ok_all "I again → nothing" || st_miss "I again rc=$rc: $out"
# ~/.claude/fleet the full install (its files apart from the client's) → nothing
H=$(fresh f); wire "$H"; mkdir -p "$H/.claude/fleet/bin"; : > "$H/.claude/fleet/bin/fleet-up.sh"
before=$(cfg "$H"); out=$(line "$H" "$WORK/f/client"); rc=$?
[ "$rc" = 0 ] && [ "$before" = "$(cfg "$H")" ] && st_ok_all "I ~/.claude/fleet the full install → untouched" || st_miss "I full rc=$rc: $out"
H=$(fresh g); wire "$H"; mkdir -p "$H/.config/claude-fleet"; printf 'FLEET_HOST=1\n' > "$H/.config/claude-fleet/fleet.conf"
before=$(cfg "$H"); out=$(line "$H" "$WORK/g/client"); rc=$?
[ "$before" = "$(cfg "$H")" ] && st_ok_all "I FLEET_HOST=1 → untouched" || st_miss "I host rc=$rc: $out"

# ── B — client-only install: the four categories ─────────────────────────────
H=$(fresh b); out=$(install "$H"); rc=$?
R="$H/.claude/fleet"
[ "$rc" = 0 ] && echo "$out" | grep >/dev/null '^apply: ok' && st_ok_all "B install + apply exit 0, the apply says ok" || st_miss "B rc=$rc: $out"
[ -f "$R/bin/fleet" ] && [ ! -e "$R/.git" ] && [ ! -e "$R/bin/fleet-up.sh" ] && [ ! -e "$H/.local/share/claude-fleet" ] \
  && st_ok_all "B the base in ~/.claude/fleet — one directory, no git, no part that runs sessions (#1804)" || st_miss "B layout: $(ls -a "$R" "$H/.local/share" 2>&1 | tr '\n' ' ')"
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
case "$nh" in 0/*|'') st_miss "B hooks: $chk" ;; *) [ "${nh%/*}" = "${nh#*/}" ] && st_ok_all "B Claude hooks: all $nh wired through the package's shim" || st_miss "B hooks: $nh" ;; esac
printf '%s\n' "$chk" | grep -x >/dev/null 'mcp context7,fetch,github,playwright' && st_ok_all "B Claude MCP: context7 · fetch · github · playwright" || st_miss "B mcp: $chk"
printf '%s\n' "$chk" | grep >/dev/null "^github .*\$HOME/.claude/fleet/bin/mcp-github.sh" && [ -x "$R/bin/mcp-github.sh" ] \
  && st_ok_all "B github MCP runs the package's bin/mcp-github.sh" || st_miss "B github args: $chk"
[ -f "$H/.claude/skills/fleet-open/SKILL.md" ] && [ -f "$H/.claude/commands/fleet-context.md" ] \
  && st_ok_all "B Claude skills + commands" || st_miss "B claude skills: $(ls "$H/.claude/skills" "$H/.claude/commands" 2>&1 | tr '\n' ' ')"
[ -f "$H/.codex/skills/fleet-open/SKILL.md" ] && [ -f "$H/.codex/skills/fleet-context/SKILL.md" ] \
  && st_ok_all "B Codex skills (repo skills + command skills)" || st_miss "B codex skills: $(ls "$H/.codex/skills" 2>&1 | tr '\n' ' ')"
# #4325: inspect the fresh HOME's generated content, not just source/existence.
"$PY" - "$REPO/commands/fleet-context.md" "$H" <<'PYCLAIM'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
home = Path(sys.argv[2])
claude = (home / ".claude/commands/fleet-context.md").read_text()
codex = (home / ".codex/skills/fleet-context/SKILL.md").read_text()
assert claude == source, "Claude's installed command drifted from the source"
assert codex.endswith(source.replace("$ARGUMENTS", "the text after this skill name")), "Codex's generated skill is stale or incomplete"
PYCLAIM
[ "$?" = 0 ] && st_ok_all "B fresh HOME: Claude and generated Codex skill carry the complete command" || st_miss "B command content drift"
n=$(grep -c '^\[mcp_servers\.' "$H/.codex/config.toml" 2>/dev/null)
[ "$n" = 4 ] && grep -q '\.claude/fleet/bin/mcp-fetch.sh' "$H/.codex/config.toml" && st_ok_all "B Codex MCP: 4 servers, fetch at the package's bin/" || st_miss "B codex mcp: $n $(cat "$H/.codex/config.toml" 2>&1)"
[ -f "$R/mod/fleet/.claude-plugin/plugin.json" ] && st_ok_all "B the mod (mod/fleet/.claude-plugin/plugin.json) is in the package" || st_miss "B no mod"
# The sandbox install names no version (FLEET_INSTALL_SRC, no .client-version —
# the installer's selftest seam), and the doctor rightly WARNs on that (#2145):
# that WARN must be the ONLY thing short of PASS (#2183) ...
# (FLEET_NOTIFY=0: the macOS notify row WARNs on a box with no terminal-notifier
# — the machine's, not the package's — #2868)
doc=$(env -i PATH="$SYS_PATH" HOME="$H" FLEET_NOTIFY=0 FLEET_STABLE_API="file://$WORK/stable-api" "$H/.local/bin/fleet" doctor 2>&1); rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s\n' "$doc" | grep -cv '^ *PASS ')" = 1 ] && printf '%s\n' "$doc" | grep >/dev/null '^ *WARN  fleet .*没有 .client-version' \
  && st_ok_all "B unversioned sandbox: the doctor's one WARN is the missing .client-version (#2145)" || st_miss "B unversioned doctor rc=$rc: $doc"
# ... and with the mark a line install writes (following a fake stable over
# file://, never the network) the doctor is all PASS.
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$WORK/stable-api"
printf 'version=0123456789abcdef0123456789abcdef01234567\ncompat=\ncommit=0123456\nhub=\nat=%s\n' "$(date +%s)" > "$R/.client-version"
doc=$(env -i PATH="$SYS_PATH" HOME="$H" FLEET_NOTIFY=0 FLEET_STABLE_API="file://$WORK/stable-api" "$H/.local/bin/fleet" doctor 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$doc" | grep >/dev/null 'PASS  agents   4/4 · hooks .* · skills .* · mcp ok · mod ' \
  && st_ok_all "B fleet doctor: $(printf '%s' "$doc" | sed 's/^ *//')" || st_miss "B fleet doctor rc=$rc: $doc"

# ── C — the login's own: overrides and what it already had ───────────────────
H=$(fresh c)
mkdir -p "$H/.config/claude-fleet"
echo '["playwright", "codex.skills", "claude.doc"]' > "$H/.config/claude-fleet/agent-overrides.json"
echo '["precomputeCompactionEnabled"]' > "$H/.claude/settings.fleet-override.json"
echo '{"numStartups": 1, "mcpServers": {"github": {"type": "stdio", "command": "my-github"}}}' > "$H/.claude.json"
out=$(install "$H"); rc=$?
chk=$("$PY" - "$H" <<'PY'
import json, os, sys
h = sys.argv[1]
c = json.load(open(os.path.join(h, ".claude.json")))
s = json.load(open(os.path.join(h, ".claude/settings.json")))
print(sorted(c["mcpServers"]), c["mcpServers"]["github"]["command"], "precomputeCompactionEnabled" in s, "agentPushNotifEnabled" in s)
PY
)
[ "$rc" = 0 ] && [ "$chk" = "['context7', 'fetch', 'github'] my-github False True" ] \
  && st_ok_all "C overrides kept: no playwright, own github untouched, no precomputeCompactionEnabled (agentPushNotifEnabled filled)" || st_miss "C rc=$rc chk=$chk out=$out"
[ ! -e "$H/.codex/skills" ] && st_ok_all "C codex.skills overridden → no Codex skills written" || st_miss "C codex skills: $(ls "$H/.codex/skills")"
grep -q 'fleet:agent-defaults' "$H/.claude/CLAUDE.md" 2>/dev/null && st_miss "C claude.doc overridden but CLAUDE.md got the block" || st_ok_all "C claude.doc overridden → no CLAUDE.md block"
doc=$(env -i PATH="$SYS_PATH" HOME="$H" "$H/.local/bin/fleet" doctor 2>&1)
printf '%s\n' "$doc" | grep >/dev/null 'PASS  agents   4/4' && st_ok_all "C what the login keeps is not counted missing" || st_miss "C doctor: $doc"

# ── D — again: nothing changes ───────────────────────────────────────────────
H="$WORK/b/home"
before=$(snap "$H"); out=$(apply "$H"); rc=$?
after=$(snap "$H")
[ "$rc" = 0 ] && [ "$before" = "$after" ] && st_ok_all "D a second apply writes nothing ($(printf '%s\n' "$after" | wc -l | tr -d ' ') files compared)" \
  || st_miss "D changed: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5)"
ls "$H/.claude/"settings.json.bak.* >/dev/null 2>&1 && st_miss "D a settings backup appeared" || st_ok_all "D no settings.json.bak"

# ── E — the shim ─────────────────────────────────────────────────────────────
# the wired path as it arrives when the hook's shell left the ~ unexpanded
TL='~'
# a client whose files sit apart from ~/.claude/fleet (FLEET_INSTALL_HOME, the
# pre-#1804 layout) — so ~/.claude/fleet below can be a full install's
H=$(fresh e); R="$H/.local/share/claude-fleet"
install "$H" "$R" >/dev/null || st_miss "E the separate-directory install failed"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' \
  | env -i PATH="$SYS_PATH" HOME="$H" TMUX=/tmp/x,1,0 TMUX_PANE=%1 sh "$R/bin/fleet-hook-run.sh" python3 "$TL/.claude/fleet/hooks/bash-guard.py" 2>&1); rc=$?
[ "$rc" = 2 ] && st_ok_all "E bash-guard runs from the package and blocks (exit 2)" || st_miss "E guard rc=$rc: $out"
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
  | env -i PATH="$SYS_PATH" HOME="$H" sh "$R/bin/fleet-hook-run.sh" python3 "$TL/.claude/fleet/hooks/bash-guard.py" 2>&1); rc=$?
[ "$rc" = 0 ] && st_ok_all "E a harmless command passes" || st_miss "E ls rc=$rc: $out"
env -i PATH="$SYS_PATH" HOME="$H" sh "$R/bin/fleet-hook-run.sh" sh "$TL/.claude/fleet/bin/set-claude-state.sh" busy </dev/null; rc=$?
[ "$rc" = 0 ] && st_ok_all "E pane plumbing the package does not carry → exit 0" || st_miss "E plumbing rc=$rc"
mkdir -p "$H/.claude/fleet/bin"; printf 'echo node-ran "$@"\n' > "$H/.claude/fleet/bin/set-claude-state.sh"
out=$(env -i PATH="$SYS_PATH" HOME="$H" sh "$R/bin/fleet-hook-run.sh" sh "$H/.claude/fleet/bin/set-claude-state.sh" busy 2>&1)
[ -z "$out" ] && st_ok_all "E the install line's base at ~/.claude/fleet (no fleet-up.sh, #1804) is no full install" || st_miss "E base taken for a node: $out"
: > "$H/.claude/fleet/bin/fleet-up.sh"
out=$(env -i PATH="$SYS_PATH" HOME="$H" sh "$R/bin/fleet-hook-run.sh" sh "$H/.claude/fleet/bin/set-claude-state.sh" busy 2>&1)
[ "$out" = "node-ran busy" ] && st_ok_all "E a full install's script wins" || st_miss "E node script: $out"
rm -rf "$H/.claude/fleet"

# ── F — a login with the full install ────────────────────────────────────────
mkdir -p "$H/.claude/fleet/bin"; : > "$H/.claude/fleet/bin/fleet-lib.sh"
before=$(snap "$H")
out=$(env -i PATH="$SYS_PATH" HOME="$H" bash "$R/bin/fleet-install-apply.sh" --bundle --root "$R" 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep >/dev/null '^bundle: skip — this login has the full install' && [ "$before" = "$(snap "$H")" ] \
  && st_ok_all "F full install here → --bundle skips, nothing written" || st_miss "F rc=$rc: $out"
rm -rf "$H/.claude/fleet"
cp "$H/.claude/settings.json" "$WORK/node-settings.json"
"$PY" "$REPO/bin/fleet-hooks-merge.py" merge --source "$REPO/hooks/settings-hooks.json" --settings "$WORK/node-settings.json" >/dev/null 2>&1
out=$("$PY" "$REPO/bin/fleet-hooks-merge.py" check --source "$REPO/hooks/settings-hooks.json" --settings "$WORK/node-settings.json" 2>&1); rc=$?
[ "$rc" = 0 ] && ! grep -q fleet-hook-run "$WORK/node-settings.json" && st_ok_all "F a later node merge replaces the client wiring in place ($out)" || st_miss "F node merge rc=$rc: $out"

# ── G — a retired command goes, a personal one stays ─────────────────────────
printf '# /fleet-gone\n\n<!-- fleet skill · owner: worker -->\n' > "$H/.claude/commands/fleet-gone.md"
printf '# mine\n' > "$H/.claude/commands/fleet-mine.md"
st="$H/.config/claude-fleet/agent-bundle.state"
printf 'commands/fleet-gone.md\ncommands/fleet-mine.md\n' >> "$st"
out=$(env -i PATH="$SYS_PATH" HOME="$H" bash "$R/bin/fleet-install-apply.sh" --bundle --root "$R" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$H/.claude/commands/fleet-gone.md" ] && [ -e "$H/.claude/commands/fleet-mine.md" ] \
  && st_ok_all "G retired fleet command removed, a personal file of that name left alone" || st_miss "G rc=$rc: $out"
grep -q 'fleet-gone' "$st" && st_miss "G the state still lists the retired file" || st_ok_all "G the state records the new package"

# ── H — no Codex on this login ───────────────────────────────────────────────
H="$WORK/h/home"; mkdir -p "$H"; echo '{"numStartups": 1}' > "$H/.claude.json"
out=$(install "$H"); rc=$?
[ "$rc" = 0 ] && [ ! -e "$H/.codex" ] && st_ok_all "H no ~/.codex → nothing created there" || st_miss "H rc=$rc codex=$(ls -R "$H/.codex" 2>&1 | head -3)"

st_done
