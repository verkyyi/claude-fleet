#!/bin/bash
# fleet-agent-as-selftest.sh — a custom session is ONE standard agent file
# (issue #3122, EPIC #3111 C11): bin/fleet-agent-def.py finds it the way Claude
# Code does and bin/fleet-claude.sh starts `claude --agent <name>`.
#
#   A  the lookup: the project's .claude/agents (nearest up to the repo root)
#      beats ~/.claude/agents, which beats an installed plugin's agents/ (also as
#      <plugin>:<name>); the frontmatter `name` is the match; nowhere ⇒ exit 1
#      naming every place looked; an unreadable file ⇒ exit 1 naming the file
#   B  the `fleet:` key: reap / repo / agent / codex_model / codex_effort read;
#      no `fleet:` key reads exactly like an empty one
#   C  fleet-claude.sh: `--as <name>` ⇒ the argv carries `--agent <name>` and the
#      file's model is the FLEET_MODEL default (a fleet's FLEET_MODEL still wins);
#      no --as ⇒ no agent / role argument at all, byte for byte as before; the old
#      `--role worker|epic-driver|debugger` reads as --as fleet-worker|epic-driver|
#      fleet-debugger; a file gone at launch ⇒ a plain session and one stderr line
#   D  a Claude Code with no `--agent` (its --help says so): the same file rides
#      --tools / --disallowedTools / --append-system-prompt-file instead; one that
#      hangs on --help is given ~5 s, then counts as knowing it
#   E  Codex: the body goes into the instructions file (`-c model_instructions_file`,
#      a content-addressed copy), `fleet.codex_model` ⇒ -m, codex_effort ⇒
#      model_reasoning_effort; no tools list carried
#   F  ship: the core's agent files land in ~/.claude/agents once, follow the
#      release while still the fleet's bytes, and are never touched once the
#      person edits (theirs) or deletes (left out) one
#   G  the wiring: both spawners take --as and hand it to the wrapper, the wrapper's
#      resume keeps it, the `spawn` tool's `agent` reaches dash-issue-session.sh
#      --as; the shipped fleet-worker / epic-driver have an EMPTY body (a body
#      replaces Claude Code's own system prompt)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agent-as-st.XXXXXX")" && pwd)
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got [$2], want [$3]"; }

export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1
export FLEET_AGENT_PLUGINS_CMD="cat '$WORK/plugins.json'"
unset CLAUDE_CONFIG_DIR FLEET_MODEL FLEET_AGENT TMUX TMUX_PANE
mkdir -p "$HOME/.claude/agents" "$FLEET_CONF_DIR" "$WORK/repo/sub" "$WORK/repo/.claude/agents" "$WORK/plug/agents"
git -C "$WORK/repo" init -q 2>/dev/null || mkdir -p "$WORK/repo/.git"
printf '[]\n' > "$WORK/plugins.json"
AD() { python3 "$BIN/fleet-agent-def.py" "$@"; }
kv() { AD launch "$@" 2>/dev/null; }
field() { awk -F'\t' -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'; }

agent() {  # agent <path> <name> [frontmatter lines…] — body "正文 <name>"
  local p="$1" n="$2"; shift 2
  { printf -- '---\nname: %s\ndescription: d\n' "$n"; for l in "$@"; do printf '%s\n' "$l"; done
    printf -- '---\n正文 %s\n' "$n"; } > "$p"
}

# --- A lookup ------------------------------------------------------------------
agent "$HOME/.claude/agents/doc-only.md" doc-only 'model: sonnet'
eq "A: the user layer answers" "$(kv doc-only --dir "$WORK/repo/sub" | field file)" "$HOME/.claude/agents/doc-only.md"
agent "$WORK/repo/.claude/agents/doc-only.md" doc-only 'model: haiku'
eq "A: the project layer beats the user layer (looked for up to the repo root)" \
  "$(kv doc-only --dir "$WORK/repo/sub" | field model)" haiku
agent "$WORK/repo/.claude/agents/other-file-name.md" renamed
eq "A: the frontmatter name is the match, not the file name" \
  "$(kv renamed --dir "$WORK/repo" | field file)" "$WORK/repo/.claude/agents/other-file-name.md"
agent "$WORK/plug/agents/reviewer.md" reviewer
printf '[{"id": "acme@market", "enabled": true, "installPath": "%s"}]\n' "$WORK/plug" > "$WORK/plugins.json"
eq "A: an installed plugin's agent answers last" "$(kv reviewer --dir "$WORK" | field file)" "$WORK/plug/agents/reviewer.md"
eq "A: …and as <plugin>:<name>" "$(kv acme:reviewer --dir "$WORK" | field file)" "$WORK/plug/agents/reviewer.md"
agent "$HOME/.claude/agents/reviewer.md" reviewer
eq "A: the user layer beats a plugin" "$(kv reviewer --dir "$WORK" | field file)" "$HOME/.claude/agents/reviewer.md"
err=$(AD launch nobody --dir "$WORK/repo" 2>&1); rc=$?
[ "$rc" = 1 ] && case "$err" in *"no agent file 'nobody'"*"$WORK/repo/.claude/agents"*"$HOME/.claude/agents"*"$WORK/plug/agents"*) true ;; *) false ;; esac \
  && ok "A: nowhere ⇒ exit 1 naming every place looked" || bad "A: missing file: rc=$rc [$err]"
printf -- '---\nname: broken\nthis line is no field\n---\n' > "$HOME/.claude/agents/broken.md"
err=$(AD launch broken --dir "$WORK" 2>&1); rc=$?
[ "$rc" = 1 ] && case "$err" in *"$HOME/.claude/agents/broken.md"*) true ;; *) false ;; esac \
  && ok "A: an unreadable file ⇒ exit 1 naming the file" || bad "A: broken file: rc=$rc [$err]"
AD launch '../x' >/dev/null 2>&1; eq "A: a name with a path in it is refused" "$?" 1

# --- B the fleet: key -----------------------------------------------------------
agent "$HOME/.claude/agents/plain.md" plain 'model: opus'
agent "$HOME/.claude/agents/keyed.md" keyed 'model: opus' 'fleet:' '  reap: done:2h' '  repo: acme/docs' \
  '  agent: codex' '  codex_model: gpt-5.5' '  codex_effort: high'
k=$(kv keyed --dir "$WORK")
eq "B: fleet.reap / repo / agent read" "$(printf '%s\n' "$k" | field reap)|$(printf '%s\n' "$k" | field repo)|$(printf '%s\n' "$k" | field agent)" "done:2h|acme/docs|codex"
agent "$HOME/.claude/agents/empty-key.md" empty-key 'model: opus' 'fleet:'
strip() { kv "$1" --dir "$WORK" | grep -Ev '^(file|sha|name|arg)	'; }
eq "B: no fleet: key ≡ an empty one" "$(strip plain)" "$(strip empty-key)"
eq "B: …and every fleet field is empty" "$(strip plain | awk -F'\t' '$1 ~ /^(reap|repo|agent|codex_model|codex_effort)$/ && $2 != ""' | wc -l | tr -d ' ')" 0

# --- C fleet-claude.sh ------------------------------------------------------------
mkfake() {  # mkfake <path> <help text>
  cat > "$1" <<EOF
#!/bin/sh
if [ "\$1" = --help ]; then printf '%s\n' '$2'; exit 0; fi
for a in "\$@"; do printf '%s\n' "\$a"; done
EOF
  chmod +x "$1"
}
mkfake "$WORK/claude" 'Options:  --agent <agent>   Agent for the current session.'
mkfake "$WORK/claude-old" 'Options:  --model <model>'
fc() { env -u TMUX -u TMUX_PANE -u FLEET_CRED_SID -u FLEET_CRED_PROXY FLEET_CLAUDE_BIN="${FCBIN:-$WORK/claude}" FLEET_MCP=0 \
         FLEET_AGENT_CFG=0 FLEET_MOD=0 FLEET_STATUS_7501=0 FLEET_AGENT=claude FLEET_PRETRUST=0 "$@" 2>"$WORK/fc.err" | paste -sd' ' -; }
cd "$WORK" || exit 2
eq "C: no --as — byte for byte as before" "$(fc bash "$BIN/fleet-claude.sh" /fleet-claim)" "--model opus /fleet-claim"
eq "C: --as doc-only ⇒ --agent doc-only, its model the default" "$(fc bash "$BIN/fleet-claude.sh" --as doc-only x)" "--model sonnet --agent doc-only x"
eq "C: --as=doc-only" "$(fc bash "$BIN/fleet-claude.sh" --as=doc-only x)" "--model sonnet --agent doc-only x"
eq "C: a fleet's FLEET_MODEL still wins" "$(fc env FLEET_MODEL=fable bash "$BIN/fleet-claude.sh" --as doc-only x)" "--model fable --agent doc-only x"
case "$(fc bash "$BIN/fleet-claude.sh" x)" in *--agent*|*--role*|*append-system-prompt*) bad "C: a plain launch carries a role argument" ;;
  *) ok "C: a plain launch carries no agent / role argument" ;; esac
python3 "$BIN/fleet-agent-def.py" ship >/dev/null
eq "C: --role worker reads as --as fleet-worker" "$(fc bash "$BIN/fleet-claude.sh" --role worker x)" "--model opus --agent fleet-worker x"
eq "C: --role=epic-driver" "$(fc bash "$BIN/fleet-claude.sh" --role=epic-driver x)" "--model opus --agent epic-driver x"
eq "C: --role debugger reads as fleet-debugger" "$(fc bash "$BIN/fleet-claude.sh" --role debugger x)" "--model opus --agent fleet-debugger x"
eq "C: a file gone at launch ⇒ a plain session" "$(fc bash "$BIN/fleet-claude.sh" --as gone-now x)" "--model opus x"
grep -q "no agent file 'gone-now'.*starting a plain session" "$WORK/fc.err" && ok "C: …and one stderr line says so" || bad "C: no stderr line: $(cat "$WORK/fc.err")"

# --- D a Claude Code with no --agent -------------------------------------------------
agent "$HOME/.claude/agents/ro.md" ro 'model: sonnet' 'tools: Read, Grep' 'disallowedTools:' '  - Edit'
got=$(FCBIN="$WORK/claude-old" fc bash "$BIN/fleet-claude.sh" --as ro x)
case "$got" in "--model sonnet --tools=Read,Grep --disallowedTools=Edit --append-system-prompt-file $FLEET_CONF_DIR/agents/ro-"*".md x")
  ok "D: no --agent ⇒ --tools / --disallowedTools / --append-system-prompt-file" ;; *) bad "D: fallback launch [$got]" ;; esac
f=$(printf '%s\n' "$got" | grep -o "$FLEET_CONF_DIR/agents/ro-[0-9a-f]*\.md")
[ "$(cat "$f" 2>/dev/null)" = '正文 ro' ] && ok "D: …the appended file is the body" || bad "D: body copy [$(cat "$f" 2>/dev/null)]"
eq "D: the answer is kept per binary (a second launch asks no --help)" "$(set -- "$FLEET_CONF_DIR"/agents/agent-flag.*; echo $#)" 2
printf '#!/bin/sh\nif [ "$1" = --help ]; then exec sleep 60; fi\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$WORK/claude-hang"; chmod +x "$WORK/claude-hang"
t0=$(date +%s); got=$(FCBIN="$WORK/claude-hang" fc bash "$BIN/fleet-claude.sh" --as doc-only x); dt=$(( $(date +%s) - t0 ))
[ "$got" = "--model sonnet --agent doc-only x" ] && [ "$dt" -le 10 ] \
  && ok "D: a binary that hangs on --help costs ≤ ~5 s and launches as the file says (${dt}s)" || bad "D: hung --help: ${dt}s [$got]"

# --- E Codex ----------------------------------------------------------------------
mkdir -p "$WORK/cbin"
cp "$BIN/fleet-claude.sh" "$BIN/fleet-agent-def.py" "$WORK/cbin/"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$WORK/cbin/fleet-codex.sh"; chmod +x "$WORK/cbin/fleet-codex.sh"
got=$(env -u TMUX -u TMUX_PANE FLEET_FAILOVER=0 bash "$WORK/cbin/fleet-claude.sh" --agent codex --as keyed x 2>/dev/null | paste -sd' ' -)
case "$got" in "-m gpt-5.5 -c model_reasoning_effort=\"high\" -c model_instructions_file=\"$FLEET_CONF_DIR/agents/keyed-"*".md\" x")
  ok "E: Codex — codex_model ⇒ -m, codex_effort, the body as its instructions file" ;; *) bad "E: codex launch [$got]" ;; esac
f=$(printf '%s\n' "$got" | grep -o "$FLEET_CONF_DIR/agents/keyed-[0-9a-f]*\.md")
[ "$(cat "$f" 2>/dev/null)" = '正文 keyed' ] && ok "E: …the instructions file holds the body" || bad "E: codex body [$(cat "$f" 2>/dev/null)]"
case "$(env -u TMUX -u TMUX_PANE FLEET_FAILOVER=0 bash "$WORK/cbin/fleet-claude.sh" --agent codex --as ro x 2>/dev/null | paste -sd' ' -)" in
  *tools*|*Grep*) bad "E: a tools list reached Codex" ;; *) ok "E: no tools list carried to Codex" ;; esac
eq "E: no --as ⇒ nothing added for Codex" "$(env -u TMUX -u TMUX_PANE FLEET_FAILOVER=0 bash "$WORK/cbin/fleet-claude.sh" --agent codex x 2>/dev/null | paste -sd' ' -)" "x"

# --- F ship -------------------------------------------------------------------------
export CLAUDE_CONFIG_DIR="$WORK/cc" FLEET_CONF_DIR="$WORK/conf2"
out=$(AD ship); n=$(ls "$WORK/cc/agents" 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -ge 3 ] && cmp -s "$WORK/cc/agents/fleet-worker.md" "$ROOT/conf/agent-defaults/claude/agents/fleet-worker.md" \
  && ok "F: ship writes the core's agent files ($n)" || bad "F: first ship [$out]"
eq "F: a second ship changes nothing" "$(AD ship | grep -c '^wrote')" 0
printf '\nextra: 1\n' >> "$WORK/cc/agents/epic-driver.md"
rm -f "$WORK/cc/agents/fleet-debugger.md"
out=$(AD ship)
printf '%s\n' "$out" | grep -q '^theirs   epic-driver' && grep -q '^extra: 1' "$WORK/cc/agents/epic-driver.md" \
  && ok "F: an edited file is the person's — kept" || bad "F: edited [$out]"
printf '%s\n' "$out" | grep -q '^deleted  fleet-debugger' && [ ! -f "$WORK/cc/agents/fleet-debugger.md" ] \
  && ok "F: a deleted one stays deleted" || bad "F: deleted [$out]"
python3 - "$FLEET_CONF_DIR/agents-shipped.json" <<'EOF'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d['fleet-worker'] = 'an older release'; json.dump(d, open(p, 'w'))
EOF
printf 'old release\n' > "$WORK/cc/agents/fleet-worker.md"
python3 - "$FLEET_CONF_DIR/agents-shipped.json" "$WORK/cc/agents/fleet-worker.md" <<'EOF'
import hashlib, json, sys; p = sys.argv[1]; d = json.load(open(p))
d['fleet-worker'] = hashlib.sha256(open(sys.argv[2], 'rb').read()).hexdigest(); json.dump(d, open(p, 'w'))
EOF
out=$(AD ship)
printf '%s\n' "$out" | grep -q '^wrote    fleet-worker' && cmp -s "$WORK/cc/agents/fleet-worker.md" "$ROOT/conf/agent-defaults/claude/agents/fleet-worker.md" \
  && ok "F: an unedited older copy follows the release" || bad "F: follow [$out]"
eq "F: --check writes nothing" "$(rm -f "$WORK/cc/agents/fleet-worker.md"; AD ship --check | grep -c '^would write'; [ -f "$WORK/cc/agents/fleet-worker.md" ] && echo written)" 0
unset CLAUDE_CONFIG_DIR; export FLEET_CONF_DIR="$WORK/conf"

# --- G wiring -------------------------------------------------------------------------
grep -q -- "\${AS_ARG:+ --as \$AS_ARG}" "$BIN/dash-issue-session.sh" && grep -q -- "\${AS_ARG:+ --as \$AS_ARG}" "$BIN/dash-raw-session.sh" \
  && ok "G: both spawners hand --as to the wrapper" || bad "G: a spawner does not pass --as"
grep -q -- "--role worker" "$BIN/dash-issue-session.sh" && bad "G: dash-issue-session.sh still passes --role worker" || ok "G: no spawner passes --role"
pol=$(sed -n '/^policy=(); want=/,/^done/p' "$BIN/fleet-session-wrap.sh")
case "$pol" in *'--as|'*'--as=*'*) ok "G: the wrapper's resume keeps --as" ;; *) bad "G: the wrapper's resume drops --as" ;; esac
grep -q '"--as", args\["agent"\]' "$BIN/fleet-mcp.py" && ok "G: the spawn tool's agent ⇒ --as" || bad "G: the spawn tool does not pass --as"
for a in fleet-worker epic-driver; do
  b=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import importlib; m = importlib.import_module("fleet-agent-def"); print(repr(m.parse(open(sys.argv[2]).read())[1]))' \
        "$BIN" "$ROOT/conf/agent-defaults/claude/agents/$a.md")
  eq "G: the shipped $a has an empty body (Claude Code keeps its own system prompt)" "$b" "''"
done
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("agents") == [] else 1)' "$ROOT/.claude-plugin/plugin.json" \
  && ok "G: plugin.json still says \"agents\": []" || bad "G: .claude-plugin/plugin.json must say \"agents\": []"

[ "$fails" = 0 ] && { echo "fleet-agent-as selftest: all green"; exit 0; }
echo "fleet-agent-as selftest: $fails FAILED"; exit 1
