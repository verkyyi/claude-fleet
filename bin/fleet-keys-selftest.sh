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
#  10. The switch keys (issue #1903): dash-keymap.sh --panel switch ⇄ the conf's
#      user-keys + User<code> binds + prefix keys ⇄ the sheet ⇄ the iTerm2 profile.
#
#   9. The recovery page's keys (bin/fleet-session-page.py, issue #1862): ↵ / r / q
#      always, and p (reopen without the personal layer) only when the login has
#      one — the keys row and choice() agree, and with no personal layer the row
#      is exactly the three keys it always was.
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

# --- 7. the task list takes NO keys (issue #1950, EPIC #1949 C1) ---------------
# It shows and taps (#896's input line, its key table and its ⌃ actions went):
# no `fleet-sidebar` key table in the client conf and nothing there or in the row
# menu switches a client into one, no `sidebar` panel in the keymap, and the view
# reads no key but its wakes (F10 F11 F12), a resize and the mouse — its actions
# are verbs parked in @sidebar_ask (fleet-sidebar.py `act`).
SIDEBAR_PY="$BIN/fleet-sidebar.py"
grep -Eq '^bind -T fleet-sidebar ' "$CONF" \
  && fail "7: the client conf binds a fleet-sidebar key table again — the list takes no keys (#1950)"
grep -n -- '-T fleet-sidebar' "$CONF" "$BIN/fleet-sidebar-menu.sh" "$SIDEBAR_PY" | grep -v ':[0-9]*:[[:space:]]*#' | grep -q . \
  && fail "7: something still switches a client into the list's key table: $(grep -n -- '-T fleet-sidebar' "$CONF" "$BIN/fleet-sidebar-menu.sh" "$SIDEBAR_PY" | head -3)"
bash "$KEYMAP" --panel sidebar list >/dev/null 2>&1 \
  && fail "7: dash-keymap.sh still has a sidebar panel — the list has no keys to map"
grep -nE '\bkey (==|in) \(?([0-9]|curses\.KEY_(UP|DOWN|LEFT|RIGHT|HOME|END|ENTER|BTAB|BACKSPACE))' "$SIDEBAR_PY" | grep -q . \
  && fail "7: fleet-sidebar.py reads a key again: $(grep -nE '\bkey (==|in) \(?([0-9]|curses\.KEY_(UP|DOWN|LEFT|RIGHT|HOME|END|ENTER))' "$SIDEBAR_PY" | head -3)"
for k in F10 F11 F12 RESIZE MOUSE; do
  grep -q "key == curses.KEY_$k" "$SIDEBAR_PY" || fail "7: fleet-sidebar.py no longer wakes on KEY_$k"
done
# The list's short sheet (issue #948, cut to one screen by #963) is its taps.
SSHEET="$(FLEET_UI_LANG=zh NO_COLOR=1 bash "$KEYS" --context sidebar --plain)" || fail "fleet-keys.sh --context sidebar exited non-zero"
[ "$(printf '%s\n' "$SSHEET" | wc -l | tr -d ' ')" -le 10 ] \
  || fail "the sidebar sheet is $(printf '%s\n' "$SSHEET" | wc -l | tr -d ' ') lines — it must fit its popup (≤ 10)"
printf '%s\n' "$SSHEET" | head -1 | grep -q '任务栏' || fail "the sidebar sheet lacks its 任务栏 title"
for k in "点一行" "再点一次 / 右键" "点 ▸ ▾"; do
  grep -qF "  $k " <<< "$SSHEET" || fail "the sidebar sheet does not list '$k'"
done
grep -qE '⌃|↑|prefix E|打字' <<< "$SSHEET" && fail "the sidebar sheet still lists a key: $SSHEET"
grep -Eq '^(task sidebar|row menu|tmux prefix|dashboard|backlog|config modal) ' <<< "$SSHEET" \
  && fail "the sidebar sheet shows a full-sheet group"
menu_keys="$(bash "$BIN/fleet-sidebar-menu.sh" --keys)" || fail "fleet-sidebar-menu.sh --keys exited non-zero"
[ "$(printf '%s\n' "$menu_keys" | cut -f1 | tr -d '\n')" = rtpaswklvxn1-9ogemqcb ] \
  || fail "the row menu's key table is not r t p a s w k l v x n 1-9 o g e m q c b (i 详情列 left with #2305; b: 进编排会话, #2146): $(printf '%s' "$menu_keys" | cut -f1 | tr '\n' ' ')"
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
  # Exactly tmux's stock keys — except the human layer (conf/tmux-node-human.conf,
  # issue #1840), which may only TAKE AWAY the stock deletes and swap the pane's
  # right-click menus for a read-only one, and drop whatever else this tmux ships
  # that deletes (its sweep): no other key differs, and no key on the node deletes
  # or respawns anything.
  HUMAN_KEYS=' prefix:x prefix:& prefix:$ prefix:< prefix:> root:MouseDown3Pane root:M-MouseDown3Pane root:MouseDown3Status root:MouseDown3StatusLeft root:MouseDown3StatusRight root:M-MouseDown3Status root:M-MouseDown3StatusLeft root:M-MouseDown3StatusRight '
  # tmux pads the key column to the longest key, so a removed key re-pads every
  # line: compare whitespace-normalised.
  hk() { awk -v hk="$HUMAN_KEYS" '/kill-(pane|window|session|server)|respawn-(pane|window)|rename-session/ { next } { k = $3 ":" $4; gsub(/\\/, "", k); if (index(hk, " " k " ") == 0) { $1 = $1; print } }' "$1"; }
  ndiff=$(diff <(hk "$KW/stock.keys") <(hk "$KW/node.keys"))
  [ -z "$ndiff" ] || { ktm stock kill-server; ktm node kill-server; ktm shell kill-server; fail "8: the node binds keys of its own (beyond the human layer it must list exactly tmux's stock keys):
$ndiff"; }
  if grep -Eq 'kill-(pane|window|session|server)|respawn-(pane|window)|rename-session' "$KW/node.keys"; then
    ktm stock kill-server; ktm node kill-server; ktm shell kill-server
    fail "8: a node key still deletes, respawns or renames: $(grep -E 'kill-|respawn-|rename-session' "$KW/node.keys" | awk '{print $3, $4}' | tr '\n' ' ')"
  fi
  for k in x '&' '$' '<' '>'; do
    awk -v k="$k" '$3 == "prefix" { kk = $4; gsub(/\\/, "", kk); if (kk == k) f = 1 } END { exit !f }' "$KW/node.keys" \
      && fail "8: the node still binds prefix $k"
  done
  grep -q 'MouseDown3Pane.*display-menu' "$KW/node.keys" || fail "8: the node's right-click is not the read-only menu"
  ktm node list-keys -T fleet-sidebar >/dev/null 2>&1 && ktm node list-keys -T fleet-sidebar | grep -q . \
    && fail "8: the node still has a fleet-sidebar key table"
  ktm node show-options -g status-right | grep -q '#(' && fail "8: the node's status line still runs a job"
  ktm node show-hooks -g | grep -Eq '\[(71|73)\]' && fail "8: the node still carries the list's [71] / hub-visit [73] hooks"
  # the client: every sheet key is bound, and to something that is not tmux's stock
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    # the whole table, filtered: `list-keys -T <table> <key>` prints nothing on tmux 3.7
    sk=$(ktm stock list-keys -T prefix 2>/dev/null | awk -v k="$k" '$4 == k')
    ck=$(ktm shell list-keys -T prefix 2>/dev/null | awk -v k="$k" '$4 == k')
    [ -n "$ck" ] || fail "8: the client does not bind 'prefix $k'"
    [ "$ck" != "$sk" ] || fail "8: the client's 'prefix $k' is still tmux's stock bind"
  done <<EOF
$sheet_prefix_keys
EOF
  ktm shell list-keys -T root | awk '$4 == "F9"' | grep -q 'resize-pane' || fail "8: the client does not bind F9"
  ktm shell list-keys -T fleet-sidebar 2>/dev/null | grep -q . && fail "8: the client still has a fleet-sidebar key table — the list takes no keys (#1950)"
  ktm stock kill-server; ktm node kill-server; ktm shell kill-server
  rm -rf "$KW"
fi

# --- 10. the switch keys: table ⇄ conf ⇄ sheet ⇄ iTerm2 profile (issue #1903) --
# `dash-keymap.sh --panel switch` is the one table. Every row: the conf catches its
# private code (`user-keys[<code>] "\e[<code>~"` + `bind -n User<code>`) and binds
# its prefix key (F9: a root key) to the SAME body — prefix h alone adds a branch
# for no list on screen; the sheet's 切会话 group lists the prefix key with the ⌘
# glyph; the profile fleet-iterm-profile.py writes sends exactly `ESC [<code>~` for
# the ⌘ chord. On the client server of leg 8's kind the codes are live.
sw_table="$(bash "$KEYMAP" --panel switch list)" || fail "10: dash-keymap.sh --panel switch list exited non-zero"
# `new` (⌘N / prefix c, issue #1953): the writing area — private code 928.
# `fold` (⌘. / prefix ., issue #2167): the session in view's sub-tasks — 929.
# `switcher` (⌘K / prefix s, issue #2266): every session + new + the layout — 930.
[ "$(printf '%s\n' "$sw_table" | grep -c .)" = 11 ] || fail "10: the switch table is not the 8 actions of #1903 + #1953's new + #2167's fold + #2266's switcher: $sw_table"
[ "$(printf '%s\n' "$sw_table" | awk '{print $1}' | tr '\n' ' ')" = "next prev back fwd needs zoom help quickopen new fold switcher " ] \
  || fail "10: the switch actions are not next prev back fwd needs zoom help quickopen new fold switcher"
printf '%s\n' "$sw_table" | awk '$1 == "switcher" && $2 == "⌘K" && $3 == "0x6b-0x100000" && $4 == 930 && $5 == "s"' | grep -q . \
  || fail "10: switcher is not ⌘K · 0x6b-0x100000 · code 930 · prefix s"
grep -E '^bind -n User930 ' "$CONF" | grep -q 'fleet-quickopen.py --switch' || fail "10: ⌘K does not open the switcher (fleet-quickopen.py --switch)"
grep -F '@fleet_hint_solo ' "$CONF" | grep -q 'key-User930]' || fail "10: the one-session bar's ⌘K is not the switcher's key (User930)"
printf '%s\n' "$sw_table" | awk '$1 == "new" && $2 == "⌘N" && $4 == 928 && $5 == "c"' | grep -q . \
  || fail "10: new is not ⌘N · code 928 · prefix c"
printf '%s\n' "$sw_table" | awk '$1 == "fold" && $2 == "⌘." && $3 == "0x2e-0x100000" && $4 == 929 && $5 == "."' | grep -q . \
  || fail "10: fold is not ⌘. · 0x2e-0x100000 · code 929 · prefix ."
sw_block="$(printf '%s\n' "$FULL_SHEET" | awk '/^switch sessions /{f=1;next} f && NF && /^[^ ]/{f=0} f')"
[ -n "$sw_block" ] || fail "10: the full sheet has no 'switch sessions' group"
body_of() {   # the body of the conf's bind for key $2 in table $1 (root / prefix)
  awk -v t="$1" -v k="$2" '
    t == "root"   && $1 == "bind" && $2 == "-n" && $3 == k { sub(/^bind -n [^ ]+ /, ""); print; exit }
    t == "prefix" && $1 == "bind" && $2 == k             { sub(/^bind [^ ]+ /, ""); print; exit }' "$CONF"
}
SW_PROF=$(mktemp -d "${TMPDIR:-/tmp}/fkeys-iterm.XXXXXX") || fail "10: mktemp"
FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_PREFS=/dev/null ITERM_PROFILE='' python3 "$BIN/fleet-iterm-profile.py" write \
  || fail "10: fleet-iterm-profile.py write exited non-zero"
[ -f "$SW_PROF/fleet.json" ] || fail "10: fleet-iterm-profile.py wrote no fleet.json"
while read -r sa sg sk sc sp; do
  [ -n "$sa" ] || continue
  grep -Fxq "set -s user-keys[$sc] \"\\e[$sc~\"" "$CONF" || fail "10: $sa: the conf does not catch its code ($sc) as user-keys[$sc]"
  ub=$(body_of root "User$sc"); [ -n "$ub" ] || fail "10: $sa: the conf has no 'bind -n User$sc'"
  case "$sp" in F[0-9]*) pb=$(body_of root "$sp") ;; *) pb=$(body_of prefix "$sp") ;; esac
  [ -n "$pb" ] || fail "10: $sa: its prefix key '$sp' is not bound in the conf"
  if [ "$sa" = back ]; then
    # ⌘['s body less its last two closers (the one-pane branch's else, #1904, and
    # the bind's own): prefix h carries on from there with its no-list else
    case "$pb" in "${ub% \} \}}"*) ;; *) fail "10: back: prefix h does not run ⌘['s body first: $pb" ;; esac
  else
    [ "$ub" = "$pb" ] || fail "10: $sa: ⌘ (User$sc) and '$sp' run different bodies:
  $ub
  $pb"
  fi
  case "$sp" in F[0-9]*) row="  $sp" ;; *) row="  prefix $sp" ;; esac
  grep -F "$row " <<< "$sw_block" | grep -qF " $sg " || fail "10: $sa: the sheet has no '$row … $sg' row"
  case "$sk" in 0x[0-9a-f]*-0x[0-9a-f]*) ;; *) fail "10: $sa: '$sk' is not an iTerm2 key spec" ;; esac
  [ $(( $(printf '%d' "${sk#*-}") & 0x100000 )) -ne 0 ] || fail "10: $sa: '$sk' carries no ⌘"
  python3 - "$SW_PROF/fleet.json" "$sk" "$sc" <<'PY' || fail "10: $sa: the profile does not send ESC [$sc~ for $sk"
import json, sys
p = json.load(open(sys.argv[1]))["Profiles"][0]
assert p["Name"] == "fleet" and p["Guid"]
m = p["Keyboard Map"][sys.argv[2]]
assert m == {"Action": 10, "Text": "[%s~" % sys.argv[3]}, m
PY
done <<EOF
$sw_table
EOF
# the table's 11 + ⇧↵ → 0x0a (the writing area's newline, issue #1953)
[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["Profiles"][0]["Keyboard Map"]))' "$SW_PROF/fleet.json")" = 12 ] \
  || fail "10: the profile maps keys beyond the table + ⇧↵ (no parent map to keep here)"
python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["Profiles"][0]["Keyboard Map"]; assert m["0xd-0x20000"] == {"Action": 11, "Text": "0x0a"}, m' "$SW_PROF/fleet.json" \
  || fail "10: the profile does not send 0x0a for ⇧↵"
FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_KEYS=0 python3 "$BIN/fleet-iterm-profile.py" write
[ -f "$SW_PROF/fleet.json" ] && fail "10: FLEET_ITERM_KEYS=0 left the profile in place"
rm -rf "$SW_PROF"
if command -v tmux >/dev/null 2>&1; then
  KW=$(mktemp -d "${TMPDIR:-/tmp}/fkeys.XXXXXX") || fail "10: mktemp"
  sed -e "s#__BIN__#$BIN#g" -e 's#__PREFIX__#C-b#g' "$CONF" > "$KW/shell.conf"
  HOME="$KW" tmux -S "$KW/s" -f /dev/null new-session -d -s k -x 120 -y 30 || fail "10: tmux did not start"
  HOME="$KW" tmux -S "$KW/s" source-file "$KW/shell.conf" || fail "10: the client conf failed to source"
  uk=$(HOME="$KW" tmux -S "$KW/s" show-options -s user-keys); rk=$(HOME="$KW" tmux -S "$KW/s" list-keys -T root)
  HOME="$KW" tmux -S "$KW/s" kill-server; rm -rf "$KW"
  while read -r sa _ _ sc _; do
    [ -n "$sa" ] || continue
    grep -Fq "user-keys[$sc] \\033[$sc~" <<< "$uk" || fail "10: $sa: user-keys[$sc] is not live on the client server: $uk"
    awk -v k="User$sc" '$4 == k' <<< "$rk" | grep -q . || fail "10: $sa: User$sc is not bound on the client server"
  done <<EOF
$sw_table
EOF
fi

# --- 11. ⌘/ — the one page (issue #1952) ------------------------------------
# fleet-keys.sh --page is what ⌘/ and prefix ? open on the stage: it fits a
# 38-row window and the stage's 119 columns, in both languages; it names every
# chord of the switch table with that action's key for any other terminal on the
# same line (⌘↑ ⌘↓ and ⌘[ ⌘] a pair each — 9 lines for the 11 actions); its three
# groups are the ⌘ keys, the writing area's and the mouse's; and it lists no ⌃
# key — the list has none (leg 7). Both binds open it (leg 10 holds them equal).
for lang in zh en; do
  PG="$(FLEET_UI_LANG=$lang NO_COLOR=1 bash "$KEYS" --page --plain)" || fail "11: fleet-keys.sh --page ($lang) exited non-zero"
  n=$(printf '%s\n' "$PG" | wc -l | tr -d ' ')
  [ "$n" -le 38 ] || fail "11: the $lang page is $n lines — it must fit a 38-row window"
  wmax=$(printf '%s\n' "$PG" | python3 -c 'import sys, unicodedata
print(max(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in l.rstrip("\n")) for l in sys.stdin))')
  [ "$wmax" -le 119 ] || fail "11: the $lang page is $wmax cells wide — the stage is 119"
  grep -q '⌃' <<< "$PG" && fail "11: the $lang page lists a ⌃ key: $(grep '⌃' <<< "$PG" | head -2)"
  while read -r sa sg _ _ sp; do
    [ -n "$sa" ] || continue
    line=$(grep -F "$sg" <<< "$PG" | head -1)
    [ -n "$line" ] || fail "11: the $lang page does not name $sa's $sg"
    case "$sp" in F[0-9]*) want=$sp ;; *) want=$sp ;; esac
    case "$line" in *"prefix "*"$want"*|*" $want") ;; *) fail "11: $sa: the $lang page's $sg line lacks its key '$want': $line" ;; esac
  done <<EOF
$sw_table
EOF
  [ "$(grep -c '⌘' <<< "$(printf '%s\n' "$PG" | awk '/^    ⌘/')")" = 9 ] \
    || fail "11: the $lang page's ⌘ group is not 9 lines: $(printf '%s\n' "$PG" | awk '/^    ⌘/')"
done
PG="$(FLEET_UI_LANG=zh NO_COLOR=1 bash "$KEYS" --page --plain)"
[ "$(printf '%s\n' "$PG" | grep -E '^  [^ ]' | sed -e 1d -e 's/^  //' | tr '\n' '|')" = '⌘ 键|写作区|鼠标|面板里的按键：在那个面板里按 ?|' ] \
  || fail "11: the page's groups are not ⌘ 键 · 写作区 · 鼠标: $(printf '%s\n' "$PG" | grep -E '^  [^ ]' | tr '\n' '|')"
grep -q '输入 > 是命令' <<< "$PG" || fail "11: the page does not say ⌘P's > is commands"
for b in 'bind ?' 'bind -n User926'; do
  grep -E "^$b " "$CONF" | grep -q 'fleet-shell.sh keys __SESS__' \
    || fail "11: '$b' does not open the page on the stage (fleet-shell.sh keys)"
  grep -E "^$b " "$CONF" | grep -q 'fleet-keys.sh --page' \
    || fail "11: '$b' has no popup fallback with the page"
done
grep -q '^keys)$' "$BIN/fleet-shell.sh" || fail "11: fleet-shell.sh has no keys mode"
grep -A12 '^keys)$' "$BIN/fleet-shell.sh" | grep -q 'fleet-keys.sh") --page' || fail "11: fleet-shell.sh keys does not run fleet-keys.sh --page"

# 9 — the recovery page's keys (issue #1862)
page_out=$(python3 - "$BIN" <<'PY'
import importlib.util, os, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("page", os.path.join(sys.argv[1], "fleet-session-page.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
plain = lambda t: __import__("re").sub(r"\x1b\[[0-9;]*m", "", t)
w = m.TEXT["zh"]
errs = []
if plain(m.keys_line(w)) != "↵ 接着原对话   r 新开   q 回收这个窗口": errs.append("no-layer row: %r" % plain(m.keys_line(w)))
if plain(m.keys_line(w, "off")) != plain(m.keys_line(w)): errs.append("off row differs")
if plain(m.keys_line(w, "on")) != "↵ 接着原对话   r 新开   q 回收这个窗口   p 不带个人配置重开": errs.append("on row: %r" % plain(m.keys_line(w, "on")))
for ch, want, pers in (("\r", m.RESUME, False), ("r", m.NEW, False), ("q", m.QUIT, False),
                       ("p", None, False), ("p", m.PERSONAL, True)):
    if m.choice(ch, 24, pers) != want: errs.append("choice(%r, personal=%s) = %r" % (ch, pers, m.choice(ch, 24, pers)))
print("\n".join(errs) or "ok")
PY
)
[ "$page_out" = ok ] || fail "9: the recovery page's keys: $page_out"

printf 'selftest OK: cheatsheet matches shipped binds (%s prefix keys, %s dashboard ⌃-keys checked)\n' \
  "$(printf '%s\n' "$sheet_prefix_keys" | grep -c .)" \
  "$(printf '%s\n' "$sheet_dash_keys" | grep -c .)"
