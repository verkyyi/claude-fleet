#!/bin/bash
# fleet-role-selftest.sh — every role starts as its definition says (issue #2782,
# EPIC #2781 C1). bin/fleet-role.py renders agents/<role>.md into launch
# arguments; the orchestrator's and the steward's launchers, fleet-claude.sh's
# `--role` (dash-issue-session.sh, dash-raw-session.sh --role epic-driver) and the
# wrapper's resume all go through it.
#
#   A  golden: with no override, render gives exactly what the four launch points
#      passed before — 4 roles × claude / codex (orchestrator `--model fable
#      --effort high` + its role, steward `--model opus --effort medium` + its
#      role, worker / epic-driver `--model opus` and the login's own effort)
#   B  the bodies: orchestrator / steward ≡ skills/*/role.md (the generated copy
#      a window opened before #2782 still reads — compat-1v), ≤ 60 lines; worker /
#      epic-driver ≤ 40; every role names itself; subagent-only fields ignored
#   C  the old knobs still win for one version: FLEET_ORCH_MODEL='' (no --model),
#      FLEET_ORCH_EFFORT, FLEET_STEWARD_MODEL, FLEET_ORCH_CODEX_MODEL
#   D  fleet-claude.sh --role: the definition's model is the FLEET_MODEL default,
#      its effort rides when the login has none, a caller's flag wins, --role never
#      reaches claude; no --role = byte for byte as before
#   E  the repo root is the plugin root: plugin.json says "agents": [] so the four
#      roles never register as plugin subagents (verified on Claude Code 2.1.295:
#      without it agents/x.md registers as `fleet:x`)
#   F  the wiring: the launchers call render and hard-code no model / effort /
#      prompt file; the wrapper keeps the rendered group; the spawners pass --role
#   G  change agents/steward.md's model ⇒ the next `fleet-steward.sh ensure` starts
#      on it, and @fleet_role_file names the new definition (an isolated tmux)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/role-st.XXXXXX")
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done
cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$WORK/t.sock" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 HOME="$WORK/home"
unset FLEET_ORCH_MODEL FLEET_ORCH_EFFORT FLEET_ORCH_CODEX_MODEL FLEET_STEWARD_MODEL \
      FLEET_STEWARD_EFFORT FLEET_STEWARD_CODEX_MODEL FLEET_MODEL FLEET_MODEL_FALLBACK \
      FLEET_ROLE_AGENTS_DIR CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude" "$FLEET_CONF_DIR"
printf '{"effortLevel": "xhigh"}\n' > "$HOME/.claude/settings.json"   # the shipped default, filled
R() { python3 "$BIN/fleet-role.py" "$@"; }
line() { R render "$@" 2>&1 | paste -sd' ' -; }

# --- A golden ---------------------------------------------------------------
want() {  # want <label> <got> <expected>
  [ "$2" = "$3" ] && ok "A: $1" || bad "A: $1 — got [$2], want [$3]"
}
o=$(line orchestrator --agent claude); ob=$(R render orchestrator --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')
want "orchestrator · claude" "$o" "--model fable --effort high --append-system-prompt-file $ob"
want "orchestrator · codex"  "$(line orchestrator --agent codex)" '-c model_reasoning_effort="high"'
s=$(line steward); sb=$(R render steward --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')
want "steward · claude" "$s" "--model opus --effort medium --append-system-prompt-file $sb"
want "steward · codex"  "$(line steward --agent codex)" '-c model_reasoning_effort="medium"'
for r in worker epic-driver; do
  want "$r · claude (the login's effortLevel stands)" "$(line $r)" "--model opus"
  want "$r · codex (config.toml stands)" "$(line $r --agent codex)" ""
done
mv "$HOME/.claude/settings.json" "$WORK/settings.json"
want "worker · claude, a login with no effortLevel: the definition's" "$(line worker)" "--model opus --effort xhigh"
mv "$WORK/settings.json" "$HOME/.claude/settings.json"
case "$ob" in "$FLEET_CONF_DIR/roles/orchestrator-"*.md) ok "A: the body is a content-addressed copy under \$FLEET_CONF_DIR/roles" ;;
  *) bad "A: body path $ob" ;; esac
[ "$(R render orchestrator --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')" = "$ob" ] \
  && ok "A: rendering twice names the same file (made once)" || bad "A: the body path moved on a second render"

# --- B bodies ---------------------------------------------------------------
cmp -s "$ob" "$ROOT/skills/fleet-orchestrate/role.md" && cmp -s <(R body orchestrator) "$ROOT/skills/fleet-orchestrate/role.md" \
  && ok "B: orchestrator body ≡ skills/fleet-orchestrate/role.md (compat-1v copy)" \
  || bad "B: agents/orchestrator.md body and skills/fleet-orchestrate/role.md differ — regenerate: fleet-role.py body orchestrator > skills/fleet-orchestrate/role.md"
cmp -s "$sb" "$ROOT/skills/fleet-steward/role.md" \
  && ok "B: steward body ≡ skills/fleet-steward/role.md (compat-1v copy)" \
  || bad "B: agents/steward.md body and skills/fleet-steward/role.md differ — regenerate: fleet-role.py body steward > skills/fleet-steward/role.md"
for r in orchestrator steward worker epic-driver; do
  n=$(R body $r | wc -l | tr -d ' ')
  cap=60; case "$r" in worker|epic-driver) cap=40 ;; esac
  [ "$n" -le "$cap" ] && [ "$(R get $r name)" = "$r" ] && [ -n "$(R get $r description)" ] \
    && [ -n "$(R get $r model)" ] && [ -n "$(R get $r effort)" ] \
    && ok "B: $r — name, description, model, effort; body $n ≤ $cap lines" || bad "B: $r: name=$(R get $r name) body=$n lines (cap $cap)"
done
mkdir -p "$WORK/agents"; cp "$ROOT"/agents/*.md "$WORK/agents/"
python3 - "$WORK/agents/worker.md" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace('model: opus\n','model: opus\nmaxTurns: 3\ncolor: red\nisolation: worktree\n',1); open(p,'w').write(s)
EOF
j=$(FLEET_ROLE_AGENTS_DIR="$WORK/agents" R render worker --json)
case "$j" in *'"maxTurns"'*) : ;; *) bad "B: ignored fields not listed: $j" ;; esac
[ "$(FLEET_ROLE_AGENTS_DIR="$WORK/agents" line worker)" = "--model opus" ] \
  && ok "B: subagent-only fields (maxTurns, color, isolation) are read and ignored" || bad "B: a subagent-only field reached the launch"
R render nobody >/dev/null 2>&1; [ $? = 2 ] && ok "B: an unknown role is refused (exit 2)" || bad "B: unknown role not refused"

# --- C the old knobs (compat-1v) -------------------------------------------
want2() { [ "$2" = "$3" ] && ok "C: $1" || bad "C: $1 — got [$2], want [$3]"; }
want2 "FLEET_ORCH_MODEL='' → no --model" "$(FLEET_ORCH_MODEL='' line orchestrator)" "--effort high --append-system-prompt-file $ob"
want2 "FLEET_ORCH_EFFORT=low" "$(FLEET_ORCH_EFFORT=low line orchestrator)" "--model fable --effort low --append-system-prompt-file $ob"
want2 "FLEET_ORCH_EFFORT='' → the definition's" "$(FLEET_ORCH_EFFORT='' line orchestrator)" "--model fable --effort high --append-system-prompt-file $ob"
want2 "FLEET_STEWARD_MODEL=sonnet" "$(FLEET_STEWARD_MODEL=sonnet line steward)" "--model sonnet --effort medium --append-system-prompt-file $sb"
want2 "FLEET_ORCH_CODEX_MODEL=gpt-x → -m" "$(FLEET_ORCH_CODEX_MODEL=gpt-x line orchestrator --agent codex)" '-m gpt-x -c model_reasoning_effort="high"'
want2 "FLEET_MODEL=fable for a worker" "$(FLEET_MODEL=fable line worker)" "--model fable"
want2 "FLEET_MODEL never reaches the orchestrator" "$(FLEET_MODEL=sonnet line orchestrator)" "--model fable --effort high --append-system-prompt-file $ob"
# the lib helper hands a sourced conf's (unexported) knob over
got=$(bash -c '. "$1/fleet-lib.sh"; FLEET_ORCH_MODEL=""; fleet_role_render orchestrator claude | grep -c "^arg	--model$"' _ "$BIN" 2>/dev/null)
[ "$got" = 0 ] && ok "C: fleet_role_render passes a shell variable the conf set (FLEET_ORCH_MODEL='')" || bad "C: fleet_role_render lost the conf's knob ($got --model)"

# --- D fleet-claude.sh --role -----------------------------------------------
cat > "$WORK/claude" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done
EOF
chmod +x "$WORK/claude"
fc() { env -u TMUX -u TMUX_PANE -u FLEET_CRED_SID -u FLEET_CRED_PROXY FLEET_CLAUDE_BIN="$WORK/claude" FLEET_MCP=0 \
         FLEET_AGENT_CFG=0 FLEET_MOD=0 FLEET_STATUS_7501=0 FLEET_AGENT=claude "$@" 2>/dev/null | paste -sd' ' -; }
d() { [ "$2" = "$3" ] && ok "D: $1" || bad "D: $1 — got [$2], want [$3]"; }
d "no --role: byte for byte as before" "$(fc bash "$BIN/fleet-claude.sh" /fleet-claim)" "--model opus /fleet-claim"
d "--role worker: consumed, the definition's model" "$(fc bash "$BIN/fleet-claude.sh" --role worker /fleet-claim)" "--model opus /fleet-claim"
d "--role=epic-driver" "$(fc bash "$BIN/fleet-claude.sh" --role=epic-driver x)" "--model opus x"
d "FLEET_MODEL still wins (compat-1v)" "$(fc env FLEET_MODEL=fable bash "$BIN/fleet-claude.sh" --role worker x)" "--model fable x"
d "a caller's --model wins" "$(fc bash "$BIN/fleet-claude.sh" --role worker --model haiku x)" "--model haiku x"
mv "$HOME/.claude/settings.json" "$WORK/settings.json"
d "no login effortLevel: the definition's effort rides" "$(fc bash "$BIN/fleet-claude.sh" --role worker x)" "--model opus --effort xhigh x"
d "a caller's --effort wins" "$(fc bash "$BIN/fleet-claude.sh" --role worker --effort low x)" "--model opus --effort low x"
mv "$WORK/settings.json" "$HOME/.claude/settings.json"
sed 's/^model: opus$/model: sonnet/' "$ROOT/agents/worker.md" > "$WORK/agents/worker.md"
d "an edited worker.md moves the default model" "$(fc env FLEET_ROLE_AGENTS_DIR="$WORK/agents" bash "$BIN/fleet-claude.sh" --role worker x)" "--model sonnet x"
d "…and a role-less launch's too" "$(fc env FLEET_ROLE_AGENTS_DIR="$WORK/agents" bash "$BIN/fleet-claude.sh" x)" "--model sonnet x"

# --- E plugin root ------------------------------------------------------------
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("agents") == [] else 1)' "$ROOT/.claude-plugin/plugin.json" \
  && ok "E: plugin.json says \"agents\": [] — agents/ never registers as plugin subagents" \
  || bad "E: .claude-plugin/plugin.json must say \"agents\": [] (the repo root is the plugin root)"

# --- F wiring ---------------------------------------------------------------
for f in fleet-orchestrator.sh fleet-steward.sh; do
  if grep -nE -- '--(model|effort|append-system-prompt-file) |model_reasoning_effort|role\.md"' "$BIN/$f" | grep -v '^[0-9]*:#' | grep -q .; then
    bad "F: $f still hard-codes a model / effort / prompt file: $(grep -nE -- '--(model|effort|append-system-prompt-file) |model_reasoning_effort|role\.md"' "$BIN/$f" | grep -v '^[0-9]*:#' | head -2)"
  else
    grep -q 'fleet_role_render ' "$BIN/$f" && ok "F: $f launches what fleet_role_render says" || bad "F: $f does not call fleet_role_render"
  fi
done
grep -q -- "fleet-session-wrap.sh'\${AGENT:+ --agent \$AGENT} --role worker" "$BIN/dash-issue-session.sh" \
  && ok "F: dash-issue-session.sh starts a worker with --role worker" || bad "F: dash-issue-session.sh passes no --role worker"
grep -q -- '--role epic-driver' "$ROOT/skills/fleet-orchestrate/SKILL.md" && grep -q -- '${ROLE:+ --role $ROLE}' "$BIN/dash-raw-session.sh" \
  && ok "F: the orchestrator opens a driver with dash-raw-session.sh --role epic-driver" || bad "F: no --role epic-driver road"
pol=$(sed -n '/^policy=(); want=/,/^done/p' "$BIN/fleet-session-wrap.sh")
miss=''; for f in --model --effort --append-system-prompt-file --permission-mode --role '--tools=' '--disallowedTools=' model_reasoning_effort; do
  case "$pol" in *"$f"*) ;; *) miss="$miss $f" ;; esac
done
[ -z "$miss" ] && ok "F: the wrapper's resume keeps the whole rendered group" || bad "F: the wrapper's resume drops:$miss"

# --- G an edited definition, the next ensure ------------------------------------
if [ -z "$REAL_TMUX" ]; then
  echo "SKIP  G: no tmux"
else
  mkdir -p "$WORK/tbin"
  cat > "$WORK/tbin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$WORK/t.sock" "\$@"
EOF
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/args"\nexec sleep 600\n' "$WORK" > "$WORK/agent"
  chmod +x "$WORK/tbin/tmux" "$WORK/agent"
  "$REAL_TMUX" -S "$WORK/t.sock" -f /dev/null new-session -d -s st -n home -x 100 -y 30 'exec sh'
  TT() { "$REAL_TMUX" -S "$WORK/t.sock" "$@"; }
  ens() { env PATH="$WORK/tbin:$PATH" FLEET_AGENT=claude FLEET_STEWARD=1 FLEET_ROLE_AGENTS_DIR="$WORK/agents" \
            FLEET_WRAP_LAUNCH="$WORK/agent" bash "$BIN/fleet-steward.sh" ensure st 2>/dev/null; }
  waitargs() { i=0; while [ ! -s "$WORK/args" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }
  : > "$WORK/args"; w=$(ens | head -1); waitargs
  sha1=$(TT display-message -p -t "$w" '#{@fleet_role_file}' 2>/dev/null)
  grep -q -- '--model opus --effort medium' "$WORK/args" && [ "$sha1" = "$(FLEET_ROLE_AGENTS_DIR="$WORK/agents" R sha steward)" ] \
    && [ -f "$(TT display-message -p -t "$w" '#{@fleet_role_body}' 2>/dev/null)" ] \
    && ok "G: the steward opens as agents/steward.md says; @fleet_role_file / @fleet_role_body name it" \
    || bad "G: first open: $(cat "$WORK/args") sha=$sha1"
  sed 's/^model: opus$/model: sonnet/' "$ROOT/agents/steward.md" > "$WORK/agents/steward.md"
  TT kill-window -t "$w"; : > "$WORK/args"
  w=$(ens | head -1); waitargs
  sha2=$(TT display-message -p -t "$w" '#{@fleet_role_file}' 2>/dev/null)
  grep -q -- '--model sonnet --effort medium' "$WORK/args" && [ -n "$sha2" ] && [ "$sha2" != "$sha1" ] \
    && ok "G: model: sonnet in agents/steward.md ⇒ the next ensure starts it on sonnet, @fleet_role_file moves" \
    || bad "G: after the edit: $(cat "$WORK/args") sha $sha1 → $sha2"
fi

[ "$fails" = 0 ] && { echo "fleet-role selftest: all green"; exit 0; }
echo "fleet-role selftest: $fails FAILED"; exit 1
