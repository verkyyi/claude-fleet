#!/bin/bash
# fleet-role-selftest.sh — the orchestrator and the steward start as their
# definitions say (issue #2782), all that is left of the role engine since EPIC
# #3111 C11 (issue #3122): a worker, a batch driver and the debugger start as a
# standard agent file now (bin/fleet-agent-def.py — fleet-agent-as-selftest.sh).
#
#   A  golden: render gives exactly what the two launchers passed before
#      (orchestrator `--model fable --effort high` + its role, steward
#      `--model opus --effort medium` + its role) × claude / codex
#   B  the bodies: orchestrator / steward ≡ skills/*/role.md (the generated copy
#      a window opened before #2782 still reads — compat-1v: the body + the role's
#      rule-table rows, issue #2786), the body ≤ 60 lines; a role that is not
#      orchestrator / steward is refused
#   C  the old knobs still win for one version: FLEET_ORCH_MODEL='' (no --model),
#      FLEET_ORCH_EFFORT, FLEET_STEWARD_MODEL, FLEET_ORCH_CODEX_MODEL; then the
#      model the person set on the hub (person-bundle.json `roles.<role>`)
#   E  the repo root is the plugin root: plugin.json says "agents": [] so the
#      definitions never register as plugin subagents
#   F  the wiring: the launchers call render and hard-code no model / effort /
#      prompt file; the wrapper keeps the rendered group and `--as`
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
case "$ob" in "$FLEET_CONF_DIR/roles/orchestrator-"*.md) ok "A: the body is a content-addressed copy under \$FLEET_CONF_DIR/roles" ;;
  *) bad "A: body path $ob" ;; esac
[ "$(R render orchestrator --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')" = "$ob" ] \
  && ok "A: rendering twice names the same file (made once)" || bad "A: the body path moved on a second render"

# --- B bodies ---------------------------------------------------------------
cmp -s "$ob" "$ROOT/skills/fleet-orchestrate/role.md" && cmp -s <(R prompt orchestrator) "$ROOT/skills/fleet-orchestrate/role.md" \
  && ok "B: orchestrator prompt ≡ skills/fleet-orchestrate/role.md (compat-1v copy)" \
  || bad "B: agents/orchestrator.md + the rule table and skills/fleet-orchestrate/role.md differ — regenerate: fleet-role.py prompt orchestrator > skills/fleet-orchestrate/role.md"
cmp -s "$sb" "$ROOT/skills/fleet-steward/role.md" \
  && ok "B: steward prompt ≡ skills/fleet-steward/role.md (compat-1v copy)" \
  || bad "B: agents/steward.md + the rule table and skills/fleet-steward/role.md differ — regenerate: fleet-role.py prompt steward > skills/fleet-steward/role.md"
for r in orchestrator steward; do
  n=$(R body $r | wc -l | tr -d ' ')
  cap=60
  [ "$n" -le "$cap" ] && [ "$(R get $r name)" = "$r" ] && [ -n "$(R get $r description)" ] \
    && [ -n "$(R get $r model)" ] && [ -n "$(R get $r effort)" ] \
    && ok "B: $r — name, description, model, effort; body $n ≤ $cap lines" || bad "B: $r: name=$(R get $r name) body=$n lines (cap $cap)"
done
R render nobody >/dev/null 2>&1; [ $? = 2 ] && ok "B: an unknown role is refused (exit 2)" || bad "B: unknown role not refused"
R render worker >/dev/null 2>&1; [ $? = 2 ] && ok "B: worker is an agent file now, not a role here (exit 2)" || bad "B: worker still renders"
mkdir -p "$WORK/agents"; cp "$ROOT"/agents/*.md "$WORK/agents/"

# --- C the old knobs (compat-1v) -------------------------------------------
want2() { [ "$2" = "$3" ] && ok "C: $1" || bad "C: $1 — got [$2], want [$3]"; }
want2 "FLEET_ORCH_MODEL='' → no --model" "$(FLEET_ORCH_MODEL='' line orchestrator)" "--effort high --append-system-prompt-file $ob"
want2 "FLEET_ORCH_EFFORT=low" "$(FLEET_ORCH_EFFORT=low line orchestrator)" "--model fable --effort low --append-system-prompt-file $ob"
want2 "FLEET_ORCH_EFFORT='' → the definition's" "$(FLEET_ORCH_EFFORT='' line orchestrator)" "--model fable --effort high --append-system-prompt-file $ob"
want2 "FLEET_STEWARD_MODEL=sonnet" "$(FLEET_STEWARD_MODEL=sonnet line steward)" "--model sonnet --effort medium --append-system-prompt-file $sb"
want2 "FLEET_ORCH_CODEX_MODEL=gpt-x → -m" "$(FLEET_ORCH_CODEX_MODEL=gpt-x line orchestrator --agent codex)" '-m gpt-x -c model_reasoning_effort="high"'
want2 "FLEET_MODEL never reaches the orchestrator" "$(FLEET_MODEL=sonnet line orchestrator)" "--model fable --effort high --append-system-prompt-file $ob"
# the lib helper hands a sourced conf's (unexported) knob over
got=$(bash -c '. "$1/fleet-lib.sh"; FLEET_ORCH_MODEL=""; fleet_role_render orchestrator claude | grep -c "^arg	--model$"' _ "$BIN" 2>/dev/null)
[ "$got" = 0 ] && ok "C: fleet_role_render passes a shell variable the conf set (FLEET_ORCH_MODEL='')" || bad "C: fleet_role_render lost the conf's knob ($got --model)"
printf '{"version": 3, "bundle": {"roles": {"orchestrator": {"body": "", "front": {"model": "opus"}}, "steward": "---\\neffort: low\\n---\\n"}}}\n' > "$FLEET_CONF_DIR/person-bundle.json"
want2 "the person's orchestrator model on the hub (compat-1v)" "$(line orchestrator)" "--model opus --effort high --append-system-prompt-file $ob"
want2 "the person's steward effort, the overlay text form" "$(line steward)" "--model opus --effort low --append-system-prompt-file $sb"
want2 "a knob still beats it" "$(FLEET_ORCH_MODEL=sonnet line orchestrator)" "--model sonnet --effort high --append-system-prompt-file $ob"
rm -f "$FLEET_CONF_DIR/person-bundle.json"

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
pol=$(sed -n '/^policy=(); want=/,/^done/p' "$BIN/fleet-session-wrap.sh")
miss=''; for f in --model --effort --append-system-prompt-file --permission-mode --as '--tools=' '--disallowedTools=' model_reasoning_effort; do
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
