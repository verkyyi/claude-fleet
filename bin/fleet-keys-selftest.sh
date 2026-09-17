#!/bin/bash
# fleet-keys-selftest.sh — drift guard for the keymap cheatsheet (issue #110).
#
# fleet-keys.sh is a CURATED source of truth; this test keeps it honest by
# cross-checking it against the binds actually shipped, so the sheet can't go
# stale silently:
#
#   1. Every `prefix <k>` row in the sheet has a matching `bind <k> ...` line in
#      conf/tmux-attention.conf (and F9 has a `bind -n F9`).
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
# Exit 0 = pass. Non-zero = fail (prints what diverged). No network / no tmux.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
KEYS="$BIN/fleet-keys.sh"
CONF="$ROOT/conf/tmux-attention.conf"
DASH="$BIN/tmux-dashboard.sh"
ISSUES="$BIN/tmux-issues.sh"
KEYMAP="$BIN/dash-keymap.sh"

for f in "$KEYS" "$CONF" "$DASH" "$ISSUES" "$KEYMAP"; do
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
for g in "tmux prefix" "dashboard" "backlog" "config modal"; do
  printf '%s\n' "$SHEET" | grep -qi "^$g " || fail "sheet missing group: $g"
done

# Keys after "prefix " in each sheet row (a, j, G, b, A, c, r, ?). Set as text,
# one key per line — compared with grep -Fxq so metachars like ? stay literal.
sheet_prefix_keys="$(printf '%s\n' "$SHEET" \
  | sed -n 's/^  prefix \([^ ]\) .*/\1/p' | sort -u)"
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
  printf '%s\n' "$conf_prefix_keys" | grep -Fxq "$k" \
    || fail "sheet lists 'prefix $k' but conf has no matching bind"
done <<EOF
$sheet_prefix_keys
EOF

# F9 (root-table) is documented in the sheet and must exist as `bind -n F9`.
printf '%s\n' "$SHEET" | grep -q 'F9' || fail "sheet missing the F9 row"
grep -Eq '^bind[[:space:]]+-n[[:space:]]+F9([[:space:]]|$)' "$CONF" \
  || fail "sheet lists F9 but conf has no 'bind -n F9'"

# --- 2. every prefix bind in the conf is documented in the sheet --------------
while IFS= read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$sheet_prefix_keys" | grep -Fxq "$k" \
    || fail "conf binds 'prefix $k' but the sheet does not document it"
done <<EOF
$conf_prefix_keys
EOF

# --- 3. the popup wiring is present -------------------------------------------
grep -q 'bin/fleet-keys.sh' "$CONF"   || fail "conf has no fleet-keys.sh popup bind"
# The `?` bind opens a display-popup; since issue #308 it is wrapped with a
# `run-shell "tmux set -g @popup_open $(date +%s)" \; … \; set -g @popup_open 0`
# flag (pause the dash repaint under the modal — the open stamps an epoch so a
# stranded flag self-heals, issue #431), so allow anything between the key and
# `display-popup`.
grep -Eq '^bind[[:space:]]+\?[[:space:]].*display-popup' "$CONF" \
  || fail "conf 'prefix ?' does not open a display-popup"
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
printf '%s\n' "$DSHEET" | grep -qi '^tmux prefix '  || fail "--context dash dropped the global 'tmux prefix' group"
printf '%s\n' "$DSHEET" | grep -qi '^dashboard '    || fail "--context dash missing its own 'dashboard' group"
printf '%s\n' "$DSHEET" | grep -qi '^backlog '      && fail "--context dash should NOT list the 'backlog' group"
printf '%s\n' "$DSHEET" | grep -qi '^config modal ' && fail "--context dash should NOT list the 'config modal' group"
# `--context backlog` ⇒ tmux prefix + backlog only; dashboard/config gone.
BSHEET="$(NO_COLOR=1 bash "$KEYS" --plain --context backlog)" \
  || fail "fleet-keys.sh --context backlog exited non-zero"
printf '%s\n' "$BSHEET" | grep -qi '^tmux prefix '  || fail "--context backlog dropped the global 'tmux prefix' group"
printf '%s\n' "$BSHEET" | grep -qi '^backlog '      || fail "--context backlog missing its own 'backlog' group"
printf '%s\n' "$BSHEET" | grep -qi '^dashboard '    && fail "--context backlog should NOT list the 'dashboard' group"
printf '%s\n' "$BSHEET" | grep -qi '^config modal ' && fail "--context backlog should NOT list the 'config modal' group"

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
dash_actions="$(grep -oE -- '--bind "\$DASH_KEY_[A-Z]+:' "$DASH" | sed 's/.*DASH_KEY_\([A-Z]*\):.*/\1/' | tr '[:upper:]' '[:lower:]' | sort -u)"
[ -n "$dash_actions" ] || fail "no '\$DASH_KEY_<ACTION>' --binds parsed from tmux-dashboard.sh"
grep -Eq -- '--bind "(ctrl|alt)-' "$DASH" \
  && fail "tmux-dashboard.sh binds a literal ctrl/alt chord — add the action to dash-keymap.sh and bind \$DASH_KEY_<ACTION> (#556)"

# 6a. dash ⇄ table
while IFS= read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$table_actions" | grep -Fxq "$k" \
    || fail "tmux-dashboard.sh binds \$DASH_KEY_$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]') but dash-keymap.sh's table has no '$k' action"
done <<EOF
$dash_actions
EOF
while IFS= read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$dash_actions" | grep -Fxq "$k" \
    || fail "dash-keymap.sh lists '$k' but tmux-dashboard.sh has no --bind \"\$DASH_KEY_$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]'):…\""
  grep -q "key \"\$(dg $k)" "$KEYS" \
    || fail "dash-keymap.sh lists '$k' but fleet-keys.sh has no \$(dg $k) row for it"
done <<EOF
$table_actions
EOF

# 6b. sheet ⇄ table (the rendered ⌃-letters)
while IFS= read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$table_keys" | grep -Fxq "$k" \
    || fail "sheet lists dashboard '⌃$k' but dash-keymap.sh resolves no action to ctrl-$k"
done <<EOF
$sheet_dash_keys
EOF
while IFS= read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$sheet_dash_keys" | grep -Fxq "$k" \
    || fail "dash-keymap.sh resolves an action to ctrl-$k but the dashboard sheet does not show ⌃$k"
done <<EOF
$table_keys
EOF

# 6c. the sheet honours the resolution: under a C-s prefix the scratch row is ⌥s
# with the why, and ⌃s is gone — the help never names a key tmux will eat.
RSHEET="$(FLEET_TMUX_PREFIX=C-s NO_COLOR=1 bash "$KEYS" --plain --context dash)" \
  || fail "fleet-keys.sh under a C-s prefix exited non-zero"
printf '%s\n' "$RSHEET" | grep -q '^  ⌥s .*⌃s is your tmux prefix C-s' \
  || fail "under a C-s tmux prefix the sheet must list ⌥s for scratch and say why"
printf '%s\n' "$RSHEET" | grep -q '^  ⌃s ' \
  && fail "under a C-s tmux prefix the sheet must NOT still list ⌃s"

# ⌃e rename by name (issue #449): the bijection above passes if BOTH sides drop a
# key, so pin the one this guard was extended for — sheet row, bind, and the
# transform helper the bind calls (an inline action would break on a ')' in a
# window name, which is why dash-rename.sh is a script).
printf '%s\n' "$dash_block" | grep -q '⌃e' \
  || fail "dashboard sheet is missing the ⌃e (rename window) row"
grep -Eq -- '--bind "\$DASH_KEY_RENAME:transform\(bash [^)]*dash-rename\.sh' "$DASH" \
  || fail "dashboard ⌃e is not bound (via \$DASH_KEY_RENAME) to a transform(dash-rename.sh ...) action"
[ -x "$BIN/dash-rename.sh" ] || fail "bin/dash-rename.sh missing or not executable"
# and the #556 key by name: the agent flip is ⌃v, never ⌃a (the operator's prefix)
printf '%s\n' "$dash_block" | grep -q '^  ⌃v .*flip this fleet' \
  || fail "dashboard sheet must list the agent flip on ⌃v"
printf '%s\n' "$dash_block" | grep -q '^  ⌃a ' \
  && fail "dashboard sheet lists ⌃a — that is a common tmux prefix (#556)"


# #558: panel tables, source bindings, rendered help and actual fzf argv agree.
# Only test subprocesses run: fake tmux/gh cannot contact a fleet or GitHub, and
# fake fzf records argv instead of accepting actions. The windowed backlog loops
# by design; terminate that test shell after the first completed render. The
# rows producer has finished (fzf consumes stdin), and the stub immediately exits.
python3 - "$BIN" <<'PYTEST' || exit 1
import json, os, pathlib, re, subprocess, sys, tempfile, time
root=pathlib.Path(sys.argv[1])
keymap=root/'dash-keymap.sh'
base_env=dict(os.environ,FLEET_TMUX_PREFIX='C-b',FLEET_TMUX_PREFIX2='',NO_COLOR='1')

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
                    header=next(arg for arg in args if arg.startswith('--header='))
                    hints=['new'] if panel=='backlog' and not popup else (['scope','reload'] if panel=='config' else [])
                    for action in hints: assert resolved[action][2] in header,(panel,'stale header',header)
                finally:
                    if proc.poll() is None:
                        proc.terminate()
                    proc.wait(timeout=5)
print('panel keys: table/binds/help lockstep; popup/windowed fzf argv, headers, prefix2 and unreachable cases passed')
PYTEST

printf 'selftest OK: cheatsheet matches shipped binds (%s prefix keys, %s dashboard ⌃-keys checked)\n' \
  "$(printf '%s\n' "$sheet_prefix_keys" | grep -c .)" \
  "$(printf '%s\n' "$sheet_dash_keys" | grep -c .)"
