#!/bin/bash
# fleet-role-selftest.sh — the orchestrator / steward role definitions
# (agents/<role>.md, issue #2782) and what reads them, all that is left of the
# role engine: a session started AS something is a standard agent file
# (bin/fleet-agent-def.py — fleet-agent-as-selftest.sh), and the launchers that
# rendered a role onto a resident window went with the seat (issue #3118).
#
#   B  the bodies: orchestrator / steward prompt ≡ the plugins' skills/*/role.md
#      (the body + the role's rule-table rows, issue #2786), the body ≤ 60 lines,
#      name / description / model / effort; a role that is not orchestrator /
#      steward is refused
#   E  the repo root is the plugin root: plugin.json says "agents": [] so the
#      definitions never register as plugin subagents
#   F  nothing renders a role any more: no `render` command, no fleet_role_render,
#      no FLEET_ORCH_* / FLEET_STEWARD_MODEL knob read (issue #3118); the wrapper's
#      resume still keeps a session's launch group and `--as`
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/role-st.XXXXXX")
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
trap 'rm -rf "$WORK"' EXIT

export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 HOME="$WORK/home"
unset FLEET_ROLE_AGENTS_DIR CLAUDE_CONFIG_DIR
mkdir -p "$HOME/.claude" "$FLEET_CONF_DIR"
R() { python3 "$BIN/fleet-role.py" "$@"; }

# --- B bodies ---------------------------------------------------------------
cmp -s <(R prompt orchestrator) "$ROOT/plugins/fleet-orchestrate/skills/fleet-orchestrate/role.md" \
  && ok "B: orchestrator prompt ≡ plugins/fleet-orchestrate/skills/fleet-orchestrate/role.md" \
  || bad "B: agents/orchestrator.md + the rule table and plugins/fleet-orchestrate/skills/fleet-orchestrate/role.md differ — regenerate: fleet-role.py prompt orchestrator > plugins/fleet-orchestrate/skills/fleet-orchestrate/role.md"
cmp -s <(R prompt steward) "$ROOT/plugins/fleet-steward/skills/fleet-steward/role.md" \
  && ok "B: steward prompt ≡ plugins/fleet-steward/skills/fleet-steward/role.md" \
  || bad "B: agents/steward.md + the rule table and plugins/fleet-steward/skills/fleet-steward/role.md differ — regenerate: fleet-role.py prompt steward > plugins/fleet-steward/skills/fleet-steward/role.md"
for r in orchestrator steward; do
  n=$(R body $r | wc -l | tr -d ' ')
  cap=60
  [ "$n" -le "$cap" ] && [ "$(R get $r name)" = "$r" ] && [ -n "$(R get $r description)" ] \
    && [ -n "$(R get $r model)" ] && [ -n "$(R get $r effort)" ] \
    && ok "B: $r — name, description, model, effort; body $n ≤ $cap lines" || bad "B: $r: name=$(R get $r name) body=$n lines (cap $cap)"
done
R body nobody >/dev/null 2>&1; [ $? = 2 ] && ok "B: an unknown role is refused (exit 2)" || bad "B: unknown role not refused"
R body worker >/dev/null 2>&1; [ $? = 2 ] && ok "B: worker is an agent file now, not a role here (exit 2)" || bad "B: worker still a role"

# --- E plugin root ------------------------------------------------------------
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("agents") == [] else 1)' "$ROOT/.claude-plugin/plugin.json" \
  && ok "E: plugin.json says \"agents\": [] — agents/ never registers as plugin subagents" \
  || bad "E: .claude-plugin/plugin.json must say \"agents\": [] (the repo root is the plugin root)"

# --- F nothing renders a role (issue #3118) --------------------------------------
R render orchestrator >/dev/null 2>&1; [ $? = 2 ] && ok "F: fleet-role.py has no render (exit 2)" || bad "F: fleet-role.py still renders a role"
if grep -q 'fleet_role_render' "$BIN/fleet-lib.sh"; then bad "F: fleet-lib.sh still defines fleet_role_render"
else ok "F: no fleet_role_render in fleet-lib.sh"; fi
if grep -q "'FLEET_ORCH_\|'FLEET_STEWARD_MODEL\|'FLEET_STEWARD_EFFORT" "$BIN/fleet-role.py"; then
  bad "F: fleet-role.py still reads an old seat knob"
else ok "F: no FLEET_ORCH_* / FLEET_STEWARD_MODEL|EFFORT read"; fi
pol=$(sed -n '/^policy=(); want=/,/^done/p' "$BIN/fleet-session-wrap.sh")
miss=''; for f in --model --effort --append-system-prompt-file --permission-mode --as '--tools=' '--disallowedTools=' model_reasoning_effort; do
  case "$pol" in *"$f"*) ;; *) miss="$miss $f" ;; esac
done
[ -z "$miss" ] && ok "F: the wrapper's resume keeps the whole launch group" || bad "F: the wrapper's resume drops:$miss"

[ "$fails" = 0 ] && { echo "fleet-role selftest: all green"; exit 0; }
echo "fleet-role selftest: $fails FAILED"; exit 1
