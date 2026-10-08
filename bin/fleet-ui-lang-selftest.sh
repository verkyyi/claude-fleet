#!/bin/bash
# fleet-ui-lang-selftest.sh — FLEET_UI_LANG selector and core tmux UI strings.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
pass=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; ok "$1"; }

eq 'en forced' "$(FLEET_UI_LANG=en "$BIN/fleet-ui-lang.sh" lang)" en
eq 'zh forced' "$(FLEET_UI_LANG=zh "$BIN/fleet-ui-lang.sh" lang)" zh
eq 'auto follows zh locale' "$(LC_ALL='' LC_MESSAGES='' LC_CTYPE='' FLEET_UI_LANG=auto LANG=zh_CN.UTF-8 "$BIN/fleet-ui-lang.sh" lang)" zh
eq 'auto follows en locale' "$(LC_ALL='' LC_MESSAGES='' LC_CTYPE='' FLEET_UI_LANG=auto LANG=en_US.UTF-8 "$BIN/fleet-ui-lang.sh" lang)" en
eq 'auto preserves Chinese in C locale' "$(LC_ALL='' LC_MESSAGES='' LC_CTYPE='' FLEET_UI_LANG=auto LANG=C "$BIN/fleet-ui-lang.sh" lang)" zh

# Importing fleet-sidebar.py would run none of its main loop, but its filename has
# a dash. Probe through a tiny importlib shim so the constants are tested as used.
probe_sidebar() {
  FLEET_UI_LANG=$1 python3 - "$BIN/fleet-sidebar.py" <<'PY'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("fleet_sidebar", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.target_name("hdr:none"))
print(mod.Ask("rename", mod.tr("sidebar_rename")).spec()["hint"])
PY
}

# The list has no input line since issue #1950: its strings are the question's,
# asked on the line under the session (bin/fleet-ask.py) — a hintless one gets
# the keys.
eq 'sidebar English strings' "$(probe_sidebar en | paste -sd'|' -)" 'no repo|↵ ok · esc cancel'
eq 'sidebar Chinese strings' "$(probe_sidebar zh | paste -sd'|' -)" '无仓库|↵ 确定 · esc 取消'
eq 'ghost English' "$(FLEET_UI_LANG=en FLEET_SESSION='' "$BIN/dash-agent-prompt.sh" ghost 2>/dev/null)" '↵ new scratch (prefilled, unsent) · switch agent: ⌃v'
eq 'ghost Chinese' "$(FLEET_UI_LANG=zh FLEET_SESSION='' "$BIN/dash-agent-prompt.sh" ghost 2>/dev/null)" '↵ 新开 scratch（预填不发送） · 切换 agent: ⌃v'

# --- ONE TABLE (issue #1535, EPIC #1529 E6) ---------------------------------
# fleet-ui-lang.sh is THE table. The four it replaced stay gone: fleet-sidebar.py's
# TEXT dict, fleet-sidebar-menu.sh's MENU_KEYS literal + m_* labels, fleet-keys.sh's
# whole zh sheet — and no script grows a zh/en branch of its own.
ROOT="$(cd "$BIN/.." && pwd)"
grep -qE '^TEXT = \{' "$BIN/fleet-sidebar.py" && fail 'fleet-sidebar.py has its own TEXT table again'
ok 'fleet-sidebar.py has no table of its own'
grep -qE "^MENU_KEYS='|^ *m_[a-z_]+='" "$BIN/fleet-sidebar-menu.sh" && fail 'fleet-sidebar-menu.sh has its own string table again'
ok 'fleet-sidebar-menu.sh has no table of its own'
grep -q 'print_sheet_zh' "$BIN/fleet-keys.sh" && fail 'fleet-keys.sh has a zh sheet of its own again'
# a row's text is a lookup ("$(fleet_ui_t …)"), never a literal in either language
grep -E '^ *s?key "[^"]*" "[^$]' "$BIN/fleet-keys.sh" | grep -qv '# ui-lang-ok:' && fail 'fleet-keys.sh writes a row literally instead of through fleet_ui_t'
ok 'fleet-keys.sh reads every row from the table'
branchy=$(grep -nE '(case "\$\(fleet_ui_lang\)"|"\$\(fleet_ui_lang\)" = (zh|en))' "$BIN"/*.sh | grep -v '/fleet-ui-lang\.sh:' | grep -v -- '-selftest\.sh:')
[ -z "$branchy" ] || fail 'a script branches on the language instead of using fleet_ui_t' "$branchy"
ok 'no script branches on the language itself'
grep -n "display-message[^|]*'Tasks:" "$ROOT"/conf/*.conf "$BIN/hub-zoom.sh" | grep -Ev ':[0-9]+:[[:space:]]*#' | grep -q . \
  && fail 'a hardcoded English toast is back (hub-zoom.sh / conf)'
ok 'the sidebar toasts are translated'

# every key exists in BOTH languages
table="$BIN/fleet-ui-lang.sh"
zk=$(sed -n 's/^ *zh:\([A-Za-z0-9_]*\)).*/\1/p' "$table" | sort)
ek=$(sed -n 's/^ *en:\([A-Za-z0-9_]*\)).*/\1/p' "$table" | sort)
[ "$zk" = "$ek" ] || fail 'zh and en keys differ' "$(diff <(printf '%s\n' "$zk") <(printf '%s\n' "$ek"))"
[ -z "$(printf '%s\n' "$zk" | uniq -d)" ] || fail 'a key is defined twice' "$(printf '%s\n' "$zk" | uniq -d)"
ok "zh and en carry the same $(printf '%s\n' "$zk" | wc -l | tr -d ' ') keys"

# every key the code asks for is in the table (a typo would print the key itself)
used=$( { grep -hE 'fleet_ui_t [a-z]' "$BIN"/*.sh | grep -Ev '^[[:space:]]*#' | grep -oE 'fleet_ui_t [a-z][a-z0-9_]+' | awk '{print $2}'
          grep -ohE '\$\(t [a-z][a-z0-9_]+' "$BIN/fleet-sidebar-menu.sh" | awk '{print $2}'
          grep -ohE 'tr\("[a-z0-9_]+"' "$BIN/fleet-sidebar.py" | sed 's/tr("//; s/"//'
          grep -ohE -- '--title[", ]+popup_[a-z0-9_]+' "$BIN"/*.sh "$BIN"/*.py "$ROOT"/conf/*.conf | grep -oE 'popup_[a-z0-9_]+$'
          grep -ohE "(toast|hint) '#\{client_name\}' [a-z_]+" "$ROOT"/conf/*.conf | awk '{print $3}'
          grep -ohE 'fleet-ui-lang\.sh" t [a-z_]+' "$BIN"/*.sh | awk '{print $3}'
          grep -ohE 'fleet-ui-lang\.sh" hint "[^"]*" [a-z_]+' "$BIN"/*.sh | awk '{print $NF}'   # issue #1618
        } | grep -vxE 'remote_label_|needs_' | sort -u)
missing=$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$zk"))
[ -z "$missing" ] || fail 'the code asks for keys the table lacks' "$missing"
ok "every key the code asks for exists ($(printf '%s\n' "$used" | wc -l | tr -d ' ') used)"

# dump: what fleet-sidebar.py reads — KEY NUL TEXT NUL, a printf argument a \001 slot
d=$(FLEET_UI_LANG=zh sh "$BIN/fleet-ui-lang.sh" dump sidebar_new_to no_repo | tr '\0\001' '|@')
eq 'dump slots' "$d" 'no_repo|无仓库|sidebar_new_to_fmt|新会话 → @…|'
eq 'menu letters come from the table' "$(FLEET_UI_LANG=en bash "$BIN/fleet-sidebar-menu.sh" --keys | cut -f1 | tr -d '\n')" 'rtpaswklvxn1-9ogemqcb'
eq 'pinned lookup' "$(FLEET_UI_LANG=en bash -c '. "$1"; fleet_ui_pin; FLEET_UI_LANG=zh; fleet_ui_t ui_close' _ "$table")" 'Esc close'

printf 'selftest OK: %s assertions passed (FLEET_UI_LANG)\n' "$pass"
