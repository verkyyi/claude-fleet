#!/bin/bash
# fleet-keys-selftest.sh — drift guard for the keymap cheatsheet (issue #110).
#
# fleet-keys.sh is a CURATED source of truth; this test keeps it honest by
# cross-checking it against the binds actually shipped, so the sheet can't go
# stale silently:
#
#   1. Every `prefix <k>` row in the sheet has a matching `bind <k> ...` line in
#      conf/tmux-shell.conf — the CLIENT's, the only place a person's key is bound
#      since issue #1714 — (and F9 has a `bind -n F9`).
#   2. Every prefix `bind`/`bind -n` in the conf (minus the mouse status bind) is
#      documented in the sheet — no missing entries.
#   3. The `?` popup bind exists in the conf, and the dash (`?`) + backlog (`?`)
#      each open fleet-keys.sh — scoped to their own panel (issue #265).
#   4. The sheet renders non-empty in --plain mode and lists all four groups.
#   5. Context scoping (issue #265): `--context dash`/`--context backlog` show
#      that panel + the global `tmux prefix` group, and drop the OTHER panels.
#   6. The dash's keys are a THREE-way lockstep (issue #556): every action in
#      bin/dash-keymap.sh's table is bound as `--bind "$DASH_KEY_<ACTION>:"` in
#      tmux-dashboard.sh (and nothing is bound by a literal ctrl chord — tmux
#      eats its prefix, so the resolver owns the key), every such bind is a table
#      action, and every table glyph has a `$(dg <action>)` sheet row / every
#      `⌃<k>` row is a table glyph — so neither a new key nor a pruned one can
#      drift (issue #449, which re-wired ⌃e rename and is asserted by name
#      below). Pinned to the stock C-b prefix so it is deterministic anywhere;
#      one extra render under a C-s prefix checks the sheet shows the remap.
#
#   8. The node binds none of them (issue #1714, EPIC #1710 C4): a server that
#      sources conf/tmux-attention.conf lists EXACTLY tmux's stock keys, and one
#      that sources the client's conf has every sheet key — on an isolated socket.
#
# Exit 0 = pass. Non-zero = fail (prints what diverged). No network.
set -uo pipefail
# A block is searched with `grep -q … <<< "$block"`, never `printf … | grep -q`:
# grep -q exits on its first match, and under pipefail a writer still flushing
# the rest of the block dies of SIGPIPE (141) — a spurious, timing-dependent
# FAIL that showed up on a loaded macOS runner (PR #1468). A here-string has
# no writer to kill.
export FLEET_UI_LANG=en

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
KEYS="$BIN/fleet-keys.sh"
CONF="$ROOT/conf/tmux-shell.conf"
NODE="$ROOT/conf/tmux-attention.conf"
DASH="$BIN/tmux-dashboard.sh"
ISSUES="$BIN/tmux-issues.sh"
KEYMAP="$BIN/dash-keymap.sh"

for f in "$KEYS" "$CONF" "$NODE" "$DASH" "$ISSUES" "$KEYMAP"; do
  [ -f "$f" ] || { printf 'selftest: missing %s\n' "$f" >&2; exit 2; }
done

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# The dash keys are resolved against the tmux prefix (issue #556); pin the stock
# C-b so the sheet renders its defaults on every machine (an operator whose prefix
# collides with a dash key would otherwise see the ⌥ remap here and this guard
# would compare against the wrong glyph).
export FLEET_TMUX_PREFIX=C-b FLEET_TMUX_PREFIX2=''

SHEET="$(NO_COLOR=1 bash "$KEYS" --plain)" || fail "fleet-keys.sh --plain exited non-zero"
[ -n "$SHEET" ] || fail "sheet rendered empty"

# --- 4. all four group headers present ----------------------------------------
for g in "tmux prefix" "task sidebar" "dashboard" "backlog" "config modal"; do
  grep -qi "^$g " <<< "$SHEET" || fail "sheet missing group: $g"
done

# Keys after "prefix " in each sheet row (a, j, G, b, A, c, r, ?). Set as text,
# one key per line — compared with grep -Fxq so metachars like ? stay literal.
sheet_prefix_keys="$(printf '%s\n' "$SHEET" \
  | sed -nE 's/^  prefix ([^ ]|Space) .*/\1/p' | sort -u)"   # one char, or a named key (Space, #902)
[ -n "$sheet_prefix_keys" ] || fail "no 'prefix X' rows parsed from the sheet"
# Prefix binds shipped in the conf: `bind <key> ...` or `bind-key <key> ...`,
# excluding root-table `bind -n ...` ($2 == "-n"). F9/mouse are surfaced as the
# F9 / "● N" rows and checked separately, so they must not be `bind <key>` here.
# Also EXCLUDE the "restore-a-tmux-default" binds (issue #289): `bind n
# next-window` and `bind r refresh-client` exist only so a live server reverts
# cleanly when the fleet stops overriding those keys (a bare unbind would leave
# them dead) — they are not fleet shortcuts, so the cheatsheet deliberately omits
# them and this guard must not demand a sheet row for them.
# Explicit -T bindings belong to an inner key table (sidebar navigation), not
# the prefix table; the sidebar selftest exercises that table through a PTY.
conf_prefix_keys="$(awk '$1=="bind"||$1=="bind-key"{ if ($2!="-n" && $2!="-T" && $3!="next-window" && $3!="refresh-client") print $2 }' "$CONF" | sort -u)"
[ -n "$conf_prefix_keys" ] || fail "no prefix binds parsed from the conf"

# --- 1. every 'prefix X' row in the sheet is bound in the conf -----------------
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -Fxq "$k" <<< "$conf_prefix_keys" \
    || fail "sheet lists 'prefix $k' but conf has no matching bind"
done <<EOF
$sheet_prefix_keys
EOF

# F9 (root-table) is documented in the sheet and must exist as `bind -n F9`.
grep -q 'F9' <<< "$SHEET" || fail "sheet missing the F9 row"
grep -Eq '^bind[[:space:]]+-n[[:space:]]+F9([[:space:]]|$)' "$CONF" \
  || fail "sheet lists F9 but conf has no 'bind -n F9'"

# --- 2. every prefix bind in the conf is documented in the sheet --------------
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -Fxq "$k" <<< "$sheet_prefix_keys" \
    || fail "conf binds 'prefix $k' but the sheet does not document it"
done <<EOF
$conf_prefix_keys
EOF

# --- 3. the popup wiring is present -------------------------------------------
grep -q '/fleet-keys.sh' "$CONF"   || fail "conf has no fleet-keys.sh popup bind"
# The `?` bind opens its popup through the one door, dash-popup.sh (issue #1535),
# which stamps the @popup_open epoch (#308/#431) and draws the one title row.
grep -Eq '^bind[[:space:]]+\?[[:space:]]+run-shell -b ".*dash-popup\.sh .*fleet-keys\.sh' "$CONF" \
  || fail "conf 'prefix ?' does not open fleet-keys.sh through dash-popup.sh"
# The in-panel opens are scoped to their own panel (issue #265): the dash `?`
# passes `--context dash`, the backlog `⌃k` passes `--context backlog` — while the
# global `prefix ?` (checked above) stays the full sheet.
grep -Eq -- '--bind "\?:.*fleet-keys.sh --context dash' "$DASH" \
  || fail "dashboard '?' does not open fleet-keys.sh scoped '--context dash'"
# `?` opens the cheatsheet two ways depending on mode (#123, renamed ⌃k→? in
# #289 for one `?` convention everywhere): a windowed panel binds `?` straight to
# fleet-keys.sh; the prefix+b popup can't nest a popup, so `?` drops a 'keys'
# sentinel that the gap dispatcher maps to fleet-keys.sh. Assert both halves of
# the chain so a break in either fails the guard (not a loose grep).
grep -Eq -- '\?:.*(keys|fleet-keys\.sh.*--context backlog)' "$ISSUES" \
  || fail "backlog has no '?' bind wired to the (backlog-scoped) keys cheatsheet"
grep -Eq -- 'keys\).*fleet-keys\.sh.*--context backlog' "$ISSUES" \
  || fail "backlog '?' keys-sentinel dispatch does not open '--context backlog'"

# --- 5. context scoping drops the OTHER panels (issue #265) --------------------
# `--context dash` ⇒ tmux prefix + dashboard only; backlog/config gone.
DSHEET="$(NO_COLOR=1 bash "$KEYS" --plain --context dash)" \
  || fail "fleet-keys.sh --context dash exited non-zero"
grep -qi '^tmux prefix ' <<< "$DSHEET"  || fail "--context dash dropped the global 'tmux prefix' group"
grep -qi '^dashboard ' <<< "$DSHEET"    || fail "--context dash missing its own 'dashboard' group"
grep -qi '^backlog ' <<< "$DSHEET"      && fail "--context dash should NOT list the 'backlog' group"
grep -qi '^config modal ' <<< "$DSHEET" && fail "--context dash should NOT list the 'config modal' group"
# `--context backlog` ⇒ tmux prefix + backlog only; dashboard/config gone.
BSHEET="$(NO_COLOR=1 bash "$KEYS" --plain --context backlog)" \
  || fail "fleet-keys.sh --context backlog exited non-zero"
grep -qi '^tmux prefix ' <<< "$BSHEET"  || fail "--context backlog dropped the global 'tmux prefix' group"
grep -qi '^backlog ' <<< "$BSHEET"      || fail "--context backlog missing its own 'backlog' group"
grep -qi '^dashboard ' <<< "$BSHEET"    && fail "--context backlog should NOT list the 'dashboard' group"
grep -qi '^config modal ' <<< "$BSHEET" && fail "--context backlog should NOT list the 'config modal' group"

# --- 6. dashboard ⌃-keys ⇄ the dash's fzf --binds ⇄ the keymap table ----------
# Section 1/2 guard the `prefix` binds; the DASHBOARD group had no such guard, so
# a ⌃-key could be bound with no sheet row (undiscoverable) or listed with no bind
# (a lie — exactly what ⌃e was between #289 and #449). Since #556 the dash binds
# no literal chord: each key is `$DASH_KEY_<ACTION>` from dash-keymap.sh's table
# and the sheet renders the same resolution via `$(dg <action>)`. Cross-check all
# three ways.
# The sheet's dashboard block: rows are two-space indented, the next group header
# is flush-left, and blank lines inside the block are kept.
dash_block="$(printf '%s\n' "$SHEET" | awk '/^dashboard /{f=1;next} f && NF && /^[^ ]/{f=0} f')"
[ -n "$dash_block" ] || fail "could not parse the sheet's dashboard group"
# `⌃X` is the first token of the key column; the `⌃` prefix is matched literally,
# so the capture is the plain ASCII letter after it (byte- and UTF-8-locale safe).
sheet_dash_keys="$(printf '%s\n' "$dash_block" | sed -n 's/^  ⌃\(.\).*/\1/p' | sort -u)"
[ -n "$sheet_dash_keys" ] || fail "no '⌃X' rows parsed from the sheet's dashboard group"
# the table, resolved under the pinned C-b: `action key glyph default remap state`
table="$(bash "$KEYMAP" list)" || fail "dash-keymap.sh list exited non-zero"
table_actions="$(printf '%s\n' "$table" | awk '{print $1}' | sort -u)"
[ -n "$table_actions" ] || fail "no actions parsed from dash-keymap.sh list"
table_keys="$(printf '%s\n' "$table" | awk '{print $3}' | sed -n 's/^⌃\(.\)$/\1/p' | sort -u)"
[ "$(printf '%s\n' "$table_keys" | grep -c .)" = "$(printf '%s\n' "$table_actions" | grep -c .)" ] \
  || fail "under C-b every table glyph must be a plain ⌃<letter> (got: $(printf '%s' "$table" | awk '{print $3}' | tr '\n' ' '))"
# the dash's binds: `--bind "$DASH_KEY_<ACTION>:` → action, lowercased
# an action name's `-` is `_` in its env name (repo-add → DASH_KEY_REPO_ADD, #1103)
dash_actions="$(grep -oE -- '--bind "\$DASH_KEY_[A-Z_]+:' "$DASH" | sed 's/.*DASH_KEY_\([A-Z_]*\):.*/\1/' | tr '[:upper:]_' '[:lower:]-' | sort -u)"
[ -n "$dash_actions" ] || fail "no '\$DASH_KEY_<ACTION>' --binds parsed from tmux-dashboard.sh"
grep -Eq -- '--bind "(ctrl|alt)-' "$DASH" \
  && fail "tmux-dashboard.sh binds a literal ctrl/alt chord — add the action to dash-keymap.sh and bind \$DASH_KEY_<ACTION> (#556)"

# 6a. dash ⇄ table
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -Fxq "$k" <<< "$table_actions" \
    || fail "tmux-dashboard.sh binds \$DASH_KEY_$(printf '%s' "$k" | tr '[:lower:]-' '[:upper:]_') but dash-keymap.sh's table has no '$k' action"
done <<EOF
$dash_actions
EOF
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -Fxq "$k" <<< "$dash_actions" \
    || fail "dash-keymap.sh lists '$k' but tmux-dashboard.sh has no --bind \"\$DASH_KEY_$(printf '%s' "$k" | tr '[:lower:]-' '[:upper:]_'):…\""
  grep -q "key \"\$(dg $k)" "$KEYS" \
    || fail "dash-keymap.sh lists '$k' but fleet-keys.sh has no \$(dg $k) row for it"
done <<EOF
$table_actions
EOF

# 6b. sheet ⇄ table (the rendered ⌃-letters)
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -Fxq "$k" <<< "$table_keys" \
    || fail "sheet lists dashboard '⌃$k' but dash-keymap.sh resolves no action to ctrl-$k"
done <<EOF
$sheet_dash_keys
EOF
while IFS= read -r k; do
  [ -n "$k" ] || continue
  grep -Fxq "$k" <<< "$sheet_dash_keys" \
    || fail "dash-keymap.sh resolves an action to ctrl-$k but the dashboard sheet does not show ⌃$k"
done <<EOF
$table_keys
EOF

# 6c. the sheet honours the resolution: under a C-s prefix the scratch row is ⌥s
# with the why, and ⌃s is gone — the help never names a key tmux will eat.
RSHEET="$(FLEET_TMUX_PREFIX=C-s NO_COLOR=1 bash "$KEYS" --plain --context dash)" \
  || fail "fleet-keys.sh under a C-s prefix exited non-zero"
grep -q '^  ⌥s .*⌃s is your tmux prefix C-s' <<< "$RSHEET" \
  || fail "under a C-s tmux prefix the sheet must list ⌥s for scratch and say why"
grep -q '^  ⌃s ' <<< "$RSHEET" \
  && fail "under a C-s tmux prefix the sheet must NOT still list ⌃s"

# ⌃e rename by name (issue #449): the bijection above passes if BOTH sides drop a
# key, so pin the one this guard was extended for — sheet row, bind, and the
# transform helper the bind calls (an inline action would break on a ')' in a
# window name, which is why dash-rename.sh is a script).
grep -q '⌃e' <<< "$dash_block" \
  || fail "dashboard sheet is missing the ⌃e (rename window) row"
grep -Eq -- '--bind "\$DASH_KEY_RENAME:transform\(bash [^)]*dash-rename\.sh' "$DASH" \
  || fail "dashboard ⌃e is not bound (via \$DASH_KEY_RENAME) to a transform(dash-rename.sh ...) action"
[ -x "$BIN/dash-rename.sh" ] || fail "bin/dash-rename.sh missing or not executable"
# and the #556 key by name: the agent flip is ⌃v, never ⌃a (the operator's prefix)
grep -q '^  ⌃v .*flip this fleet' <<< "$dash_block" \
  || fail "dashboard sheet must list the agent flip on ⌃v"
grep -q '^  ⌃a ' <<< "$dash_block" \
  && fail "dashboard sheet lists ⌃a — that is a common tmux prefix (#556)"

# --- 7. task sidebar: keymap table ⇄ tmux key table ⇄ view ⇄ sheet (#896) ------
# The sidebar's navigation table is a tmux key table whose `Any` bind types every
# other key into the input line, so: no plain-letter bind may shadow typing, each
# `--panel sidebar` action's ⌃ default reaches the view as a byte it handles, its
# ⌥ fallback is rewritten to that ⌃ byte in the conf, and the sheet lists it.
SIDEBAR_PY="$BIN/fleet-sidebar.py"
grep -Eq '^bind -T fleet-sidebar Any ' "$CONF" \
  || fail "conf has no 'bind -T fleet-sidebar Any' — typed keys cannot reach the input line (#896)"
grep -Eq '^bind -T fleet-sidebar [[:alnum:]] ' "$CONF" \
  && fail "conf binds a plain letter/digit in the fleet-sidebar table — it types into the input line since #896 (hide is prefix e)"
side_block="$(awk '/^  if want sidebar; then/{f=1;next} f && /^  fi$/{f=0} f' "$KEYS")"
[ -n "$side_block" ] || fail "fleet-keys.sh has no 'if want sidebar' block"
side_table="$(bash "$KEYMAP" --panel sidebar list)" || fail "dash-keymap.sh --panel sidebar list exited non-zero"
[ -n "$side_table" ] || fail "dash-keymap.sh --panel sidebar has no actions"
while read -r action _ _ def _; do
  [ -n "$action" ] || continue
  grep -q "\$(dg $action)" <<< "$side_block" \
    || fail "sidebar action '$action' has no \$(dg $action) row in fleet-keys.sh"
  grep -q "\$(dn $action)" <<< "$side_block" \
    || fail "sidebar action '$action' has no \$(dn $action) remap note in fleet-keys.sh"
  # A printable punctuation default (`menu` = `.`, #898) acts only on an EMPTY
  # input line, so it reaches the view through the `Any` bind as its own byte
  # (read as `press`, which also folds an IME's full-width 。/？ onto it, #965).
  case "$def" in [[:punct:]])
    grep -qF "press == \"$def\" and not line.text" "$SIDEBAR_PY" \
      || fail "sidebar action '$action' ($def) must act only on an empty input line in fleet-sidebar.py"
    continue ;;
  esac
  letter="${def#ctrl-}"
  [ "$letter" != "$def" ] && [ "${#letter}" = 1 ] || fail "sidebar default '$def' must be a ctrl-<letter> or one punctuation key (a letter types)"
  byte=$(( $(printf '%d' "'$letter") - 96 ))
  grep -q "key == $byte\b" "$SIDEBAR_PY" \
    || fail "sidebar action '$action' ($def = byte $byte) is not handled in fleet-sidebar.py"
  grep -Eq "^bind -T fleet-sidebar M-$letter .*send-keys -t '\{top-left\}' C-$letter" "$CONF" \
    || fail "sidebar action '$action': conf does not rewrite its ⌥$letter fallback to C-$letter"
done <<EOF
$side_table
EOF
# The sidebar's own `?` sheet (issue #948, cut to one screen by #963): its
# popup cannot scroll, so it is the seven everyday keys + a title and nothing
# else — the input line's editing keys share ONE row (#1097). Every sidebar action and every row-menu letter still has a row — in the
# FULL sheet (prefix ?), which is what the checks above and below read.
SSHEET="$(FLEET_UI_LANG=zh NO_COLOR=1 bash "$KEYS" --context sidebar --plain)" || fail "fleet-keys.sh --context sidebar exited non-zero"
[ "$(printf '%s\n' "$SSHEET" | wc -l | tr -d ' ')" -le 10 ] \
  || fail "the sidebar sheet is $(printf '%s\n' "$SSHEET" | wc -l | tr -d ' ') lines — it must fit its popup (≤ 10)"
printf '%s\n' "$SSHEET" | head -1 | grep -q '任务栏快捷键' || fail "the sidebar sheet lacks its 任务栏快捷键 title"
for k in "打字 ↵" "↑ ↓" "编辑" ". / 再点一次" "esc" "F9" "prefix ?"; do
  grep -qF "  $k " <<< "$SSHEET" || fail "the sidebar sheet does not list '$k'"
done
for k in "⌃o" "⌃n" "prefix E" "prefix Space"; do
  grep -qF "$k" <<< "$SSHEET" && fail "the sidebar sheet lists '$k' — only the seven everyday keys belong there"
done
# The editing row names every edit key, each keymap one as it resolves (#1097).
edit_row="$(printf '%s\n' "$SSHEET" | grep -F '  编辑 ')"
for k in "←→" "Home" "End" "⌥←→" "$(bash "$KEYMAP" --panel sidebar glyph bol)" \
         "$(bash "$KEYMAP" --panel sidebar glyph eol)" "$(bash "$KEYMAP" --panel sidebar glyph kill_word)" \
         "$(bash "$KEYMAP" --panel sidebar glyph kill_eol)" "⌃u"; do
  grep -qF " $k" <<< "$edit_row" || fail "the sidebar sheet's 编辑 row lacks '$k': $edit_row"
done
grep -Eq '^(task sidebar|row menu|tmux prefix|dashboard|backlog|config modal) ' <<< "$SSHEET" \
  && fail "the sidebar sheet shows a full-sheet group"
menu_keys="$(bash "$BIN/fleet-sidebar-menu.sh" --keys)" || fail "fleet-sidebar-menu.sh --keys exited non-zero"
[ "$(printf '%s\n' "$menu_keys" | cut -f1 | tr -d '\n')" = rtpaswkvxn1-9ogemqc ] \
  || fail "the row menu's key table is not r t p a s w k v x n 1-9 o g e m q c: $(printf '%s' "$menu_keys" | cut -f1 | tr '\n' ' ')"
while IFS='	' read -r mk _; do
  [ -n "$mk" ] || continue
  grep -Eq "^  $mk +" <<< "$SSHEET" && fail "the sidebar sheet lists the row menu letter '$mk'"
done <<EOF
$menu_keys
EOF
FULL_SHEET="$(NO_COLOR=1 bash "$KEYS" --plain)"
grep -q '^task sidebar ' <<< "$FULL_SHEET" || fail "the full sheet lost the task sidebar group"
menu_block="$(printf '%s\n' "$FULL_SHEET" | awk '/^row menu /{f=1;next} f && NF && /^[^ ]/{f=0} f')"
[ -n "$menu_block" ] || fail "the full sheet lost the row menu group"
while IFS='	' read -r mk _; do
  [ -n "$mk" ] || continue
  grep -q "^  $mk  " <<< "$menu_block" || fail "the full sheet's row menu lacks '$mk'"
done <<EOF
$menu_keys
EOF
grep -Eq '^ *add "[^"]*" [a-z] ' "$BIN/fleet-sidebar-menu.sh" \
  && fail "fleet-sidebar-menu.sh hardcodes a menu letter — read it from MENU_KEYS (mk)"
DSHEET="$(NO_COLOR=1 bash "$KEYS" --context dash --plain)"
grep -Eq '^(row menu|task sidebar) ' <<< "$DSHEET" \
  && fail "the dash sheet shows a sidebar group"

NSHEET="$(FLEET_TMUX_PREFIX=C-n NO_COLOR=1 bash "$KEYS" --plain)" || fail "fleet-keys.sh under a C-n prefix exited non-zero"
printf '%s\n' "$NSHEET" | awk '/^task sidebar /{f=1;next} f && NF && /^[^ ]/{f=0} f' \
  | grep -q '^  ⌥n .*⌃n is your tmux prefix C-n' \
  || fail "under a C-n tmux prefix the sidebar group must list ⌥n for new task and say why"

# #558: panel tables, source bindings, rendered help and actual fzf argv agree.
# Only test subprocesses run: fake tmux/gh cannot contact a fleet or GitHub, and
# fake fzf records argv instead of accepting actions. The windowed backlog loops
# by design; terminate that test shell after the first completed render. The
# rows producer has finished (fzf consumes stdin), and the stub immediately exits.
python3 - "$BIN" <<'PYTEST' || exit 1
import json, os, pathlib, re, subprocess, sys, tempfile, time
root=pathlib.Path(sys.argv[1])
keymap=root/'dash-keymap.sh'
# FLEET_FZF_FOOTER pins fzf's --footer support (issue #1619): the stub below logs
# every call, so fleet-popup-lib.sh's capability probe must not be one of them.
base_env=dict(os.environ,FLEET_TMUX_PREFIX='C-b',FLEET_TMUX_PREFIX2='',NO_COLOR='1',FLEET_FZF_FOOTER='1')

def table(panel,env):
    rows=subprocess.check_output(['bash',str(keymap),'--panel',panel,'list'],env=env,text=True)
    return {r.split()[0]:r.split() for r in rows.splitlines()}

sources={'backlog':'tmux-issues.sh','config':'tmux-config.sh'}
key_source=(root/'fleet-keys.sh').read_text()
for panel,filename in sources.items():
    actions=set(table(panel,base_env))
    source=(root/filename).read_text()
    bound={a.lower() for a in re.findall(r'\$DASH_KEY_([A-Z]+):',source)}
    assert actions==bound, (panel,'table/binds drift',actions,bound)
    assert not re.search(r'(?:--bind |\w+_BIND=)"(?:ctrl|alt)-',source), (panel,'literal chord')
    sheet_source=key_source.split('if want '+panel+'; then',1)[1].split('\n  fi',1)[0]
    assert actions==set(re.findall(r'\$\(dg ([a-z]+)\)',sheet_source)), (panel,'table/help drift')
    assert actions==set(re.findall(r'\$\(dn ([a-z]+)\)',sheet_source)), (panel,'missing remap explanation')

with tempfile.TemporaryDirectory(prefix='panel-keymap-') as tmp:
    tmp=pathlib.Path(tmp);fake=tmp/'bin';fake.mkdir()
    for name in ('tmux','gh'):
        tool=fake/name;tool.write_text('#!/bin/sh\nexit 1\n');tool.chmod(0o755)
    fzf=fake/'fzf'
    fzf.write_text('#!/usr/bin/env python3\nimport json,os,sys\nsys.stdin.read()\n'+
                   'with open(os.environ["PANEL_ARGV"],"w") as f: json.dump(sys.argv[1:],f)\nsys.exit(1)\n')
    fzf.chmod(0o755)
    cases=[('C-b',''),('C-n','C-x'),('C-o','C-r'),('C-y','M-y')]
    for panel,filename in sources.items():
        for prefix,prefix2 in (cases if panel=='backlog' else [('C-b',''),('C-s','C-r'),('C-p',''),('C-s','M-s')]):
            env=dict(base_env,HOME=str(tmp),PATH=str(fake)+os.pathsep+os.environ['PATH'],
                     FLEET_C=str(tmp/'cache'),FLEET_CONF_DIR=str(tmp/'conf'),
                     FCFG_GLOBAL_CONF=str(tmp/'global.conf'),FCFG_FLEET_CONF=str(tmp/'fleet.conf'),
                     FLEET_TMUX_PREFIX=prefix,FLEET_TMUX_PREFIX2=prefix2,PANEL_ARGV=str(tmp/'argv.json'))
            resolved=table(panel,env)
            sheet=subprocess.check_output(['bash',str(root/'fleet-keys.sh'),'--plain'],env=env,text=True)
            title='backlog' if panel=='backlog' else 'config modal'
            section=sheet.split('\n'+title+' ',1)[1].split('\n\n',1)[0]
            for row in resolved.values():
                assert row[2] in section,(panel,'missing glyph',row,section)
                if row[5]=='remapped': assert 'tmux prefix '+row[4] in section,(panel,'missing reason')
                if row[5]=='unreachable': assert 'UNREACHABLE' in section,(panel,'missing warning')
            for popup in (('', '1') if panel=='backlog' else ('1',)):
                env['POPUP']=popup;log=tmp/'argv.json';log.unlink(missing_ok=True)
                proc=subprocess.Popen(['bash',str(root/filename)],env=env,stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL,start_new_session=True)
                try:
                    deadline=time.monotonic()+10
                    while not log.exists() and proc.poll() is None and time.monotonic()<deadline: time.sleep(.05)
                    assert log.exists(),(panel,prefix,popup,'no fzf render',proc.poll())
                    # The stub may still be completing its single small write.
                    args=None
                    while args is None and time.monotonic()<deadline:
                        try: args=json.loads(log.read_text())
                        except json.JSONDecodeError: time.sleep(.01)
                    assert args is not None,(panel,'incomplete fzf capture')
                    binds=[args[i+1] for i,arg in enumerate(args[:-1]) if arg=='--bind']
                    keys={bind.split(':',1)[0] for bind in binds}
                    for row in resolved.values():
                        assert row[1] in keys,(panel,prefix,popup,'missing bind',row,keys)
                        if row[5]=='remapped': assert row[3] not in keys,(panel,'old default still bound',row)
                    # the key hints may be the footer line now (fleet_fzf_hint, #1619)
                    header=' '.join(arg for arg in args if arg.startswith(('--header=','--footer=')))
                    hints=['new'] if panel=='backlog' and not popup else (['scope','reload'] if panel=='config' else [])
                    for action in hints: assert resolved[action][2] in header,(panel,'stale header',header)
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                    proc.wait(timeout=5)
print('panel keys: table/binds/help lockstep; popup/windowed fzf argv, headers, prefix2 and unreachable cases passed')
PYTEST

# --- 8. the node binds none of a person's keys; the client binds them all ------
# (issue #1714, EPIC #1710 C4). Three throwaway servers on sockets of our own
# (never the fleet's): stock tmux, one that sourced the node conf, one that
# sourced the client's conf as fleet-shell.sh renders it. HOME is a scratch dir
# so the node conf's one-shot reap never reaches a live install.
if command -v tmux >/dev/null 2>&1; then
  KW=$(mktemp -d "${TMPDIR:-/tmp}/fkeys.XXXXXX") || fail "8: mktemp"
  ktm() { local s="$1"; shift; HOME="$KW" tmux -S "$KW/$s" -f /dev/null "$@"; }
  for s in stock node shell; do ktm "$s" new-session -d -s k -x 120 -y 30 || fail "8: tmux $s server did not start"; done
  sed -e "s#__BIN__#$BIN#g" -e 's#__PREFIX__#C-b#g' "$CONF" > "$KW/shell.conf"
  ktm node source-file "$NODE" 2>"$KW/node.err" || fail "8: the node conf failed to source: $(cat "$KW/node.err")"
  ktm shell source-file "$KW/shell.conf" 2>"$KW/shell.err" || fail "8: the client conf failed to source: $(cat "$KW/shell.err")"
  ktm stock list-keys > "$KW/stock.keys"; ktm node list-keys > "$KW/node.keys"
  ndiff=$(diff "$KW/stock.keys" "$KW/node.keys")
  [ -z "$ndiff" ] || { ktm stock kill-server; ktm node kill-server; ktm shell kill-server; fail "8: the node binds keys of its own (it must list exactly tmux's stock keys):
$ndiff"; }
  ktm node list-keys -T fleet-sidebar >/dev/null 2>&1 && ktm node list-keys -T fleet-sidebar | grep -q . \
    && fail "8: the node still has a fleet-sidebar key table"
  ktm node show-options -g status-right | grep -q '#(' && fail "8: the node's status line still runs a job"
  ktm node show-hooks -g | grep -Eq '\[(71|73)\]' && fail "8: the node still carries the list's [71] / hub-visit [73] hooks"
  # the client: every sheet key is bound, and to something that is not tmux's stock
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    sk=$(ktm stock list-keys -T prefix -- "$k" 2>/dev/null)
    ck=$(ktm shell list-keys -T prefix -- "$k" 2>/dev/null)
    [ -n "$ck" ] || fail "8: the client does not bind 'prefix $k'"
    [ "$ck" != "$sk" ] || fail "8: the client's 'prefix $k' is still tmux's stock bind"
  done <<EOF
$sheet_prefix_keys
EOF
  ktm shell list-keys -T root F9 | grep -q 'resize-pane' || fail "8: the client does not bind F9"
  ktm shell list-keys -T fleet-sidebar | grep -q . || fail "8: the client has no fleet-sidebar key table"
  ktm stock kill-server; ktm node kill-server; ktm shell kill-server
  rm -rf "$KW"
fi

printf 'selftest OK: cheatsheet matches shipped binds (%s prefix keys, %s dashboard ⌃-keys checked)\n' \
  "$(printf '%s\n' "$sheet_prefix_keys" | grep -c .)" \
  "$(printf '%s\n' "$sheet_dash_keys" | grep -c .)"
