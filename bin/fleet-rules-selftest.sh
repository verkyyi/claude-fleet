#!/bin/bash
# fleet-rules-selftest.sh — dispatch and the steward's three tiers follow ONE
# editable rule table (issue #2786, EPIC #2781 C5). bin/fleet_rules.py reads
# conf/role-rules.default.md < the person's layer (person-bundle.json `rules`) <
# this computer's ($FLEET_CONF_DIR/roles/rules.md); bin/fleet-role.py renders the
# role's rows into the orchestrator's / steward's system prompt; bin/fleet_decision.py
# classifies off the table's `ask` rows.
#
#   A  the default table: numbers unique, the keywords ≡ fleet_decision.NEVER_WORDS
#      class by class, and classify gives the same verdict as the code's list on
#      every string fleet-decision-selftest.sh uses (逐条对拍)
#   B  the person's layer adds 「金额 ⇒ ask」 (rule 101, never:money): a question
#      with 报价 is never:money; without the layer it is normal; the row's source
#      reads 你的 vN; this computer's layer wins over it by number
#   C  `档位 off` removes a rule (its keywords stop counting); the number stays
#      unused
#   D  a layer that cannot be read (a new rule under 100, a bad 档位) is not used
#      at all and says why; the rest of the table stands
#   E  versions: a different table is a different v=; every rendered version is
#      kept, `rules --version <old>` still shows the old row; --mark N prints the
#      ticket's line, an unknown N is refused
#   F  render: the orchestrator's prompt ends with its rows only (≤ 40 lines),
#      the steward's with its; a worker's launch carries no table
#   G  a broken fleet table: classify falls back to the code's list, a role
#      still renders (body alone)
#   H  the words live in the table only: docs/DECISIONS.md lists no keywords, the
#      orchestrator's body no longer spells the shapes
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
cls() { PY 'import sys, fleet_decision as d; print(d.classify(sys.argv[1] or None, sys.argv[2]))' "$1" "$2"; }

# --- A the default table ----------------------------------------------------------
got=$(PY '
import fleet_rules as r, fleet_decision as d
t = r.load()
ns = [x["n"] for x in t["rows"]]
print(len(ns), len(set(ns)) == len(ns), r.never_words(t) == {k: tuple(v) for k, v in d.NEVER_WORDS.items()},
      t["problems"])')
[ "$got" = "21 True True []" ] && ok "A: 21 rules, unique numbers, keywords ≡ NEVER_WORDS class by class" \
  || bad "A: default table — $got"
corpus=$(grep -oE "\"[^\"]{2,}\"|'[^']{2,}'" "$BIN/fleet-decision-selftest.sh" | sed 's/^.//; s/.$//')
diff=$(printf '%s\n' "$corpus" | PY '
import sys, fleet_decision as d
lines = [l for l in sys.stdin.read().split("\n") if l]
lines += [w.upper() for ws in d.NEVER_WORDS.values() for w in ws] + ["要不要付费", "一个普通问题"]
bad, n = [], 0
for decl in (None, "normal", "never:rule", "never:money", "never:publish"):
    for s in lines:
        d._WORDS = None; a = d.classify(decl, s)
        d._WORDS = d.NEVER_WORDS; b = d.classify(decl, s)
        n += 1
        if a != b: bad.append((decl, s, a, b))
print(n, len(bad), bad[:3])')
case "$diff" in [1-9]*" 0 []") ok "A: classify(table) ≡ classify(code list) on ${diff%% *} cases from fleet-decision-selftest.sh (逐条对拍)" ;;
  *) bad "A: classify differs — $diff" ;; esac

# --- B the person's layer -----------------------------------------------------------
Q='这份报价要不要接受'
[ "$(cls '' "$Q")" = normal ] && ok "B: without a layer, 「${Q}」 is normal" || bad "B: baseline $(cls '' "$Q")"
python3 - "$FLEET_CONF_DIR/person-bundle.json" <<'EOF'
import json, sys
rules = "| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n" \
        "| 101 | steward | 问的是金额 | 必须问你（never:money） | ask | 报价, 金额 |\n"
json.dump({"version": 3, "rules": rules}, open(sys.argv[1], "w"), ensure_ascii=False)
EOF
[ "$(cls '' "$Q")" = never:money ] && [ "$(cls normal "$Q")" = never:money ] \
  && ok "B: the person adds 「金额 ⇒ ask」 ⇒ 「${Q}」 is never:money (a declared normal does not beat it)" \
  || bad "B: with the layer: $(cls '' "$Q")"
src=$(R rules --json 2>/dev/null | python3 -c 'import json,sys; print([r["source"] for r in json.load(sys.stdin)["rows"] if r["n"]==101])')
[ "$src" = "['你的 v3']" ] && ok "B: rule 101's source reads 你的 v3" || bad "B: source $src"
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 101 | steward | 问的是金额 | 必须问你（never:money） | ask | 金额 |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
[ "$(cls '' "$Q")" = normal ] && [ "$(cls '' '金额多少')" = never:money ] \
  && ok "B: this computer's layer wins by number (101 without 报价)" || bad "B: local over person: $(cls '' "$Q")"

# --- C off ------------------------------------------------------------------------
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 17 | steward | 花钱 | - | off | |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
n17=$(R rules --json 2>/dev/null | python3 -c 'import json,sys; print(sum(r["n"]==17 for r in json.load(sys.stdin)["rows"]))')
[ "$(cls '' '要不要购买')" = normal ] && [ "$(cls '' "$Q")" = never:money ] && [ "$n17" = 0 ] \
  && ok "C: 档位 off drops rule 17 (购买 no longer asks); the person's 101 still counts" \
  || bad "C: off — $(cls '' '要不要购买') / $n17"

# --- D a layer that cannot be read ----------------------------------------------------
printf '| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| 50 | steward | x | y | ask | 什么 |\n' \
  > "$FLEET_CONF_DIR/roles/rules.md"
err=$(R rules 2>&1 >/dev/null)
case "$err" in *'local layer not used'*'starts at 100'*) [ "$(cls '' '什么')" = normal ] && [ "$(cls '' "$Q")" = never:money ] \
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

# --- F render --------------------------------------------------------------------
ob=$(R render orchestrator --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')
sec=$(sed -n '/^## 规则表 v=/,$p' "$ob")
nl=$(printf '%s\n' "$sec" | wc -l | tr -d ' ')
case "$sec" in *"v=$v2"*'| 1 | 一处改动 | 一律先问 | ask |'*'| 12 |'*)
    printf '%s' "$sec" | grep -q '^| 13 |' && bad "F: a steward row in the orchestrator's prompt" \
      || { [ "$nl" -le 40 ] && ok "F: the orchestrator's prompt ends with its $((nl - 3)) rows at v=$v2 (≤ 40 lines), the local edit in" || bad "F: $nl lines"; } ;;
  *) bad "F: orchestrator section: $sec" ;; esac
rm -f "$FLEET_CONF_DIR/roles/rules.md"
sb=$(R render steward --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["body"])')
grep -q '^| 16 | 改 fleet 的铁律' "$sb" && ! grep -q '^| 1 |' "$sb" && ok "F: the steward's prompt carries its rules only (13–19, 21)" || bad "F: steward section"
case "$(R render worker)" in *append-system-prompt*) bad "F: a worker launch carries a prompt file" ;; *) ok "F: a worker's launch carries no table" ;; esac

# --- G a broken fleet table ------------------------------------------------------------
printf 'not a table\n| 编号 | 角色 | 条件 | 动作 | 档位 | 关键词 |\n|---|---|---|---|---|---|\n| x | nobody | | | | |\n' > "$WORK/broken.md"
[ "$(FLEET_RULES_DEFAULT="$WORK/broken.md" cls '' '要不要付费')" = never:money ] \
  && ok "G: an unreadable table ⇒ classify falls back to the code's list" || bad "G: fallback"
p=$(FLEET_RULES_DEFAULT="$WORK/broken.md" R prompt orchestrator 2>/dev/null)
[ "$p" = "$(R body orchestrator)" ] && ok "G: …and the orchestrator still renders, on its body alone" || bad "G: prompt with a broken table"

# --- H the words live in the table only ------------------------------------------------
grep -q '付费 · 花钱' "$ROOT/docs/DECISIONS.md" && bad "H: docs/DECISIONS.md still lists keywords" \
  || { grep -q 'role-rules.default.md' "$ROOT/docs/DECISIONS.md" && ok "H: docs/DECISIONS.md points at the rule table" || bad "H: DECISIONS.md names no table"; }
R body orchestrator | grep -q '几处独立改动或跨仓库' && bad "H: the orchestrator's body still spells the shapes" \
  || ok "H: the orchestrator's body says 按规则表派, the shapes are the table's"

[ "$fails" = 0 ] && { echo "fleet-rules selftest: all green"; exit 0; }
echo "fleet-rules selftest: $fails FAILED"; exit 1
