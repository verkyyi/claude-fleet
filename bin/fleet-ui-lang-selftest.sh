#!/bin/bash
# fleet-ui-lang-selftest.sh — FLEET_UI_LANG selector and core tmux UI strings.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
pass=0
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; st_pass "$1"; }

eq 'en forced' "$(FLEET_UI_LANG=en "$BIN/fleet-ui-lang.sh" lang)" en
eq 'zh forced' "$(FLEET_UI_LANG=zh "$BIN/fleet-ui-lang.sh" lang)" zh
eq 'auto follows zh locale' "$(LC_ALL='' LC_MESSAGES='' LC_CTYPE='' FLEET_UI_LANG=auto LANG=zh_CN.UTF-8 "$BIN/fleet-ui-lang.sh" lang)" zh
eq 'auto follows en locale' "$(LC_ALL='' LC_MESSAGES='' LC_CTYPE='' FLEET_UI_LANG=auto LANG=en_US.UTF-8 "$BIN/fleet-ui-lang.sh" lang)" en
eq 'auto preserves Chinese in C locale' "$(LC_ALL='' LC_MESSAGES='' LC_CTYPE='' FLEET_UI_LANG=auto LANG=C "$BIN/fleet-ui-lang.sh" lang)" zh

eq 'empty list English' "$(FLEET_UI_LANG=en "$BIN/fleet-ui-lang.sh" t empty_dash 2>/dev/null)" 'No sessions — start one from ⌘P'
eq 'empty list Chinese' "$(FLEET_UI_LANG=zh "$BIN/fleet-ui-lang.sh" t empty_dash 2>/dev/null)" '暂无会话 — ⌘P 里新开一个'

# --- ONE TABLE (issue #1535, EPIC #1529 E6) ---------------------------------
# fleet-ui-lang.sh is THE table: no script grows a zh/en branch of its own. (The
# old client's sidebar and row menu had their own tables once; they went with it,
# issue #3008 — and fleet-keys.sh's zh sheet with the sheet, issue #4902.)
ROOT="$(cd "$BIN/.." && pwd)"
branchy=$(grep -nE '(case "\$\(fleet_ui_lang\)"|"\$\(fleet_ui_lang\)" = (zh|en))' "$BIN"/*.sh | grep -v '/fleet-ui-lang\.sh:' | grep -v -- '-selftest\.sh:')
[ -z "$branchy" ] || fail 'a script branches on the language instead of using fleet_ui_t' "$branchy"
st_pass 'no script branches on the language itself'
# (no hardcoded English toast in conf/, #3008: conf/gone.list)

# every key exists in BOTH languages
table="$BIN/fleet-ui-lang.sh"
zk=$(sed -n 's/^ *zh:\([A-Za-z0-9_]*\)).*/\1/p' "$table" | sort)
ek=$(sed -n 's/^ *en:\([A-Za-z0-9_]*\)).*/\1/p' "$table" | sort)
[ "$zk" = "$ek" ] || fail 'zh and en keys differ' "$(diff <(printf '%s\n' "$zk") <(printf '%s\n' "$ek"))"
[ -z "$(printf '%s\n' "$zk" | uniq -d)" ] || fail 'a key is defined twice' "$(printf '%s\n' "$zk" | uniq -d)"
st_pass "zh and en carry the same $(printf '%s\n' "$zk" | wc -l | tr -d ' ') keys"

# every key the code asks for is in the table (a typo would print the key itself)
used=$( { grep -hE 'fleet_ui_t [a-z]' "$BIN"/*.sh | grep -Ev '^[[:space:]]*#' | grep -oE 'fleet_ui_t [a-z][a-z0-9_]+' | awk '{print $2}'
          grep -ohE -- '--title[", ]+popup_[a-z0-9_]+' "$BIN"/*.sh "$BIN"/*.py "$ROOT"/conf/*.conf | grep -oE 'popup_[a-z0-9_]+$'
          grep -ohE "(toast|hint) '#\{client_name\}' [a-z_]+" "$ROOT"/conf/*.conf | awk '{print $3}'
          grep -ohE 'fleet-ui-lang\.sh" t [a-z_]+' "$BIN"/*.sh | awk '{print $3}'
          grep -ohE 'fleet-ui-lang\.sh" hint "[^"]*" [a-z_]+' "$BIN"/*.sh | awk '{print $NF}'   # issue #1618
        } | grep -vxE 'remote_label_|needs_' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$zk"))
[ -z "$missing" ] || fail 'the code asks for keys the table lacks' "$missing"
st_pass "every key the code asks for exists ($(printf '%s\n' "$used" | wc -l | tr -d ' ') used)"

# dump: what a Python reader takes in one call — KEY NUL TEXT NUL, a printf argument a \001 slot
d=$(FLEET_UI_LANG=zh sh "$BIN/fleet-ui-lang.sh" dump sidebar_new_to no_repo | tr '\0\001' '|@')
eq 'dump slots' "$d" 'no_repo|无仓库|sidebar_new_to_fmt|新会话 → @…|'
eq 'pinned lookup' "$(FLEET_UI_LANG=en bash -c '. "$1"; fleet_ui_pin; FLEET_UI_LANG=zh; fleet_ui_t ui_close' _ "$table")" 'Esc close'

printf 'selftest OK: %s assertions passed (FLEET_UI_LANG)\n' "$pass"
