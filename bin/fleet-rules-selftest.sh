#!/bin/bash
# fleet-rules-selftest.sh — dispatch follows ONE editable rule table (issue #2786,
# EPIC #2781 C5). bin/fleet_rules.py reads the built-in rows < the person's layer
# (person-bundle.json `rules`) < this computer's ($FLEET_CONF_DIR/roles/rules.md);
# bin/fleet-role.py prompt appends the role's rows to the orchestrator's body (the
# plugin's role.md). The steward's rows (13–19 · 21) left with its tick program
# (issue #4339).
#
#   A  the default table: 13 rows, numbers unique, no steward row, no problem
#   B  the person's layer adds 「金额 ⇒ ask」 (rule 101, never:money): its keywords
#      count for never:money; without the layer there are none; the row's source
#      reads 你的 vN; this computer's layer wins over it by number
#   C  `档位 off` removes a rule; the number stays unused
#   D  a layer that cannot be read (a new rule under 100, a bad 档位) is not used
#      at all and says why; the rest of the table stands
#   E  versions: a different table is a different v=; every rendered version is
#      kept, `rules --version <old>` still shows the old row; --mark N prints the
#      ticket's line, an unknown N is refused
#   F  render: the orchestrator's prompt ends with its rows only (≤ 40 lines),
#      the steward's is its body alone; a worker's launch carries no table
#   G  a broken fleet table: a role still renders (body alone)
#   H  the orchestrator's body spells its shapes itself (the old decisions doc left
#      with the steward's programs, issue #4339)
#   I  the built-in rows live in the skill dir (issue #3114): the orchestrate
#      plugin's rules.md holds only orchestrator rows, the loader reads it, and
#      conf/role-rules.default.md (kept one version for the hub's view) is exactly
#      it — same version
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rules-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
export FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home"
unset FLEET_RULES_DEFAULT FLEET_ROLE_AGENTS_DIR
mkdir -p "$FLEET_CONF_DIR/roles" "$HOME"
R() { python3 "$BIN/fleet-role.py" "$@"; }
PY() { (cd "$BIN" && python3 -c "$1" "${@:2}"); }
nw() {  # nw <class> — that class's keywords in the merged table, comma-joined
  PY 'import sys, fleet_rules as r; print(",".join(r.never_words(r.load())[sys.argv[1]]))' "$1" 2>/dev/null; }

# --- A the default table ----------------------------------------------------------
got=$(PY '
import fleet_rules as r
t = r.load()
ns = [x["n"] for x in t["rows"]]
print(len(ns), len(set(ns)) == len(ns), any(x["role"] == "steward" for x in t["rows"]), t["problems"])')
[ "$got" = "13 True False []" ] && ok "A: 13 rules, unique numbers, no steward row (#4339)" \
  || bad "A: default table — $got"

# --- B the person's layer -----------------------------------------------------------
[ -z "$(nw money)" ] && ok "B: without a layer, nothing is never:money" || bad "B: baseline $(nw money)"
python3 - "$FLEET_CONF_DIR/person-bundle.json" <<'EOF'
import json, sys
rules = "| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n" \
        "| 101 | steward | 问的是金额 | 必须问你（never:money） | ask | 报价, 金额 |\n"
json.dump({"version": 3, "rules": rules}, open(sys.argv[1], "w"), ensure_ascii=False)
EOF
[ "$(nw money)" = 报价,金额 ] && ok "B: the person adds 「金额 ⇒ ask」 ⇒ 报价, 金额 count for never:money" \
  || bad "B: with the layer: $(nw money)"
src=$(R rules --json 2>/dev/null | python3 -c 'import json,sys; print([r["source"] for r in json.load(sys.stdin)["rows"] if r["n"]==101])')
[ "$src" = "['你的 v3']" ] && ok "B: rule 101's source reads 你的 v3" || bad "B: source $src"
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 101 | steward | 问的是金额 | 必须问你（never:money） | ask | 金额 |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
[ "$(nw money)" = 金额 ] && ok "B: this computer's layer wins by number (101 without 报价)" || bad "B: local over person: $(nw money)"

# --- C off ------------------------------------------------------------------------
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 11 | orchestrator | 没写优先级 | - | off | |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
n11=$(R rules --json 2>/dev/null | python3 -c 'import json,sys; print(sum(r["n"]==11 for r in json.load(sys.stdin)["rows"]))')
[ "$n11" = 0 ] && [ "$(nw money)" = 报价,金额 ] \
  && ok "C: 档位 off drops rule 11; the person's 101 still counts" \
  || bad "C: off — $n11 / $(nw money)"

# --- D a layer that cannot be read ----------------------------------------------------
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 50 | steward | x | y | ask | 什么 |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
err=$(R rules 2>&1 >/dev/null)
case "$err" in *'local layer not used'*'starts at 100'*) [ "$(nw money)" = 报价,金额 ] \
  && ok "D: a new rule under 100 ⇒ the whole local layer unused, said on stderr; the rest stands" || bad "D: under-100 layer leaked" ;;
  *) bad "D: no reason given: $err" ;; esac
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 5 | orchestrator | x | y | sometimes | |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
err=$(R rules 2>&1 >/dev/null)
case "$err" in *'档位'*sometimes*) ok "D: a bad 档位 ⇒ the layer unused, said why" ;; *) bad "D: bad tier: $err" ;; esac
rm -f "$FLEET_CONF_DIR/roles/rules.md"

# --- E versions ---------------------------------------------------------------------
v1=$(R rules --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 1 | orchestrator | 一处改动 | 一律先问 | ask | |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
v2=$(R rules --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
old=$(R rules --version "$v1" | grep '^| 1 |')
[ "$v1" != "$v2" ] && [ -f "$FLEET_CONF_DIR/roles/rules-$v1.md" ] && case "$old" in *'建单并 spawn'*) true ;; *) false ;; esac \
  && ok "E: a changed table is a new v=; rules --version $v1 still shows the old rule 1" || bad "E: versions $v1/$v2 old=[$old]"
m=$(R rules --mark 1)
[ "$m" = "按规则 1 派发"$'\n'"<!-- fleet:rule n=1 v=$v2 -->" ] && ok "E: --mark 1 prints the ticket's two lines at the current v=" || bad "E: mark [$m]"
R rules --mark 77 >/dev/null 2>&1; [ $? = 2 ] && ok "E: --mark of a rule the table lacks is refused (exit 2)" || bad "E: unknown mark not refused"

# --- F prompt (body + the role's rows; the plugins' role.md copy it) ---------------
sec=$(R prompt orchestrator | sed -n '/^## 规则表 v=/,$p')
nl=$(printf '%s\n' "$sec" | wc -l | tr -d ' ')
case "$sec" in *"v=$v2"*'| 1 | 一处改动 | 一律先问 | ask |'*'| 12 |'*)
    printf '%s' "$sec" | grep -q '^| 13 |' && bad "F: a steward row in the orchestrator's prompt" \
      || { [ "$nl" -le 40 ] && ok "F: the orchestrator's prompt ends with its $((nl - 3)) rows at v=$v2 (≤ 40 lines), the local edit in" || bad "F: $nl lines"; } ;;
  *) bad "F: orchestrator section: $sec" ;; esac
rm -f "$FLEET_CONF_DIR/roles/rules.md"
rm -f "$FLEET_CONF_DIR/person-bundle.json"   # its 101 is a steward row
[ "$(R prompt steward)" = "$(R body steward)" ] && ok "F: the steward's prompt is its body alone (its rows left, #4339)" || bad "F: steward section"
R prompt worker >/dev/null 2>&1 && bad "F: a worker has a role prompt" || ok "F: a worker has no role prompt (no table)"

# --- G a broken fleet table ------------------------------------------------------------
printf 'not a table\n| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| x | nobody | | | | |\n' > "$WORK/broken.md"
p=$(FLEET_RULES_DEFAULT="$WORK/broken.md" R prompt orchestrator 2>/dev/null)
[ "$p" = "$(R body orchestrator)" ] && ok "G: an unreadable table ⇒ the orchestrator still renders, on its body alone" || bad "G: prompt with a broken table"

# --- H the words live in the table only ------------------------------------------------
# the orchestrator is a session template now (issue #4335, EPIC #4333 decision 7): the
# rows it really uses are in its own body, and it writes no 「按规则 N」 any more
R body orchestrator | grep -q '几处独立改动或跨仓库' && ! R body orchestrator | grep -q '按规则' \
  && ok "H: the orchestrator template spells its shapes itself, no 按规则 N" \
  || bad "H: the orchestrator template must carry its shapes and no 按规则 N"

# --- I the rows beside the skill (issue #3114) -----------------------------------------
OR="$ROOT/plugins/fleet-orchestrate/skills/fleet-orchestrate/rules.md"
PY 'import fleet_rules as r, sys
o = r.parse(open(sys.argv[1]).read())
assert o and all(x["role"] == "orchestrator" for x in o), "orchestrate rules.md"
assert [p.split("/")[-2] for p in r.default_paths()] == ["fleet-orchestrate"], r.default_paths()
c = r.parse(open(sys.argv[2]).read())
assert r.version_of(sorted(o, key=lambda x: x["n"])) == r.version_of(sorted(c, key=lambda x: x["n"])), "conf copy drifted"
' "$OR" "$ROOT/conf/role-rules.default.md" \
  && ok "I: the built-in rows are the orchestrate skill's rules.md, the conf copy the same" \
  || bad "I: the skill dir's rules.md and conf/role-rules.default.md disagree (or the loader reads neither)"

[ "$fails" = 0 ] && { echo "fleet-rules selftest: all green"; exit 0; }
echo "fleet-rules selftest: $fails FAILED"; exit 1
