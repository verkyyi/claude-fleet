#!/bin/bash
# fleet-keys-selftest.sh — drift guard for the keymap cheatsheet (issue #110).
#
# fleet-keys.sh is a CURATED source of truth; this test keeps it honest by
# cross-checking it against the binds actually shipped, so the sheet can't go
# stale silently. (The old client's own legs — its conf's prefix keys and F9 (1,
# 2), the task list's key table and its row menu (7), its server's keys and bar
# (8's client half), the conf's ⌘ codes (10's conf half) and the keys of a local
# Claude through its three servers (12) — went with that client, issue #3008.)
#
#   3. The dash (`?`) + backlog (`?`) each open fleet-keys.sh — scoped to their
#      own panel (issue #265).
#   4. The sheet renders non-empty in --plain mode and lists its three groups.
#   5. Context scoping (issue #265): `--context dash`/`--context backlog` show
#      that panel and drop the OTHER panels.
#   6. The dash's keys are a THREE-way lockstep (issue #556): every action in
#      bin/dash-keymap.sh's table is bound as `--bind "$DASH_KEY_<ACTION>:"` in
#      tmux-dashboard.sh (and nothing is bound by a literal ctrl chord — tmux
#      eats its prefix, so the resolver owns the key), every such bind is a table
#      action, and every table glyph has a `$(dg <action>)` sheet row / every
#      `⌃<k>` row is a table glyph — so neither a new key nor a pruned one can
#      drift (issue #449, which re-wired ⌃e rename and is asserted by name
#      below). Pinned to the stock C-b prefix so it is deterministic anywhere;
#      one extra render under a C-s prefix checks the sheet shows the remap.
#      #558: the panel tables, the source binds, the help and fzf's argv agree.
#
#  10. The switch keys (issue #1903): dash-keymap.sh --panel switch — the 看台's
#      table — its rows and codes, and the iTerm2 profile fleet-iterm-profile.py
#      writes for it (⌘P by default, FLEET_KEY_PANEL, FLEET_KEYS_EXTRA).
#  11. No page of keys (issue #2362): no --page, the client ships no fleet-keys.sh,
#      the sheet names no ⌘J / ⌘/.
#
#   9. The recovery page's keys (bin/fleet-session-page.py, issue #1862): ↵ / r / q
#      always, and p (reopen without the personal layer) only when the login has
#      one — the keys row and choice() agree, and with no personal layer the row
#      is exactly the three keys it always was.
#
#   8. The node binds none of them (issue #1714, EPIC #1710 C4): a server that
#      sources conf/tmux-attention.conf lists EXACTLY tmux's stock keys in root
#      and prefix — its only keys of its own live in the 看台's tables (issue
#      #3000: fleet-view = root copied + by default ONE action, the panel —
#      User927 (⌘P) and the phone keys ⌃空格 · F12 · ⌃] p (issue #3185); a
#      FLEET_KEYS_EXTRA adds its codes, FLEET_KEY_PHONE narrows the phone's) — on
#      an isolated socket.
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
NODE="$ROOT/conf/tmux-attention.conf"
DASH="$BIN/tmux-dashboard.sh"
ISSUES="$BIN/tmux-issues.sh"
KEYMAP="$BIN/dash-keymap.sh"

for f in "$KEYS" "$NODE" "$DASH" "$ISSUES" "$KEYMAP"; do
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

# --- 4. the three group headers present ---------------------------------------
for g in "dashboard" "backlog" "config modal"; do
  grep -qi "^$g " <<< "$SHEET" || fail "sheet missing group: $g"
done
for g in "tmux prefix" "task sidebar" "row menu" "switch sessions"; do
  grep -qi "^$g " <<< "$SHEET" && fail "sheet still lists the old client's group: $g"
done

# --- 3. the popup wiring is present -------------------------------------------
# The client opens no key sheet any more (issue #2362, leg 11); the panels' `?`
# still open it through the one door, dash-popup.sh (issue #1535).
# The in-panel opens are scoped to their own panel (issue #265): the dash `?`
# passes `--context dash`, the backlog `⌃k` passes `--context backlog`.
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
# `--context dash` ⇒ dashboard only; backlog/config gone.
DSHEET="$(NO_COLOR=1 bash "$KEYS" --plain --context dash)" \
  || fail "fleet-keys.sh --context dash exited non-zero"
grep -qi '^dashboard ' <<< "$DSHEET"    || fail "--context dash missing its own 'dashboard' group"
grep -qi '^backlog ' <<< "$DSHEET"      && fail "--context dash should NOT list the 'backlog' group"
grep -qi '^config modal ' <<< "$DSHEET" && fail "--context dash should NOT list the 'config modal' group"
# `--context backlog` ⇒ backlog only; dashboard/config gone.
BSHEET="$(NO_COLOR=1 bash "$KEYS" --plain --context backlog)" \
  || fail "fleet-keys.sh --context backlog exited non-zero"
grep -qi '^backlog ' <<< "$BSHEET"      || fail "--context backlog missing its own 'backlog' group"
grep -qi '^dashboard ' <<< "$BSHEET"    && fail "--context backlog should NOT list the 'dashboard' group"
grep -qi '^config modal ' <<< "$BSHEET" && fail "--context backlog should NOT list the 'config modal' group"

# --- 6. dashboard ⌃-keys ⇄ the dash's fzf --binds ⇄ the keymap table ----------
# The DASHBOARD group had no guard of its own, so a ⌃-key could be bound with no sheet row (undiscoverable) or listed with no bind
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

# --- 8. the node binds none of a person's keys ----------------------------------
# (issue #1714, EPIC #1710 C4). Two throwaway servers on sockets of our own
# (never the fleet's): stock tmux and one that sourced the node conf. HOME is a
# scratch dir so the node conf's one-shot reap never reaches a live install.
if command -v tmux >/dev/null 2>&1; then
  KW=$(mktemp -d "${TMPDIR:-/tmp}/fkeys.XXXXXX") || fail "8: mktemp"
  ktm() { local s="$1"; shift; HOME="$KW" tmux -S "$KW/$s" -f /dev/null "$@"; }
  for s in stock node; do ktm "$s" new-session -d -s k -x 120 -y 30 || fail "8: tmux $s server did not start"; done
  ktm node source-file "$NODE" 2>"$KW/node.err" || fail "8: the node conf failed to source: $(cat "$KW/node.err")"
  ktm stock list-keys > "$KW/stock.keys"; ktm node list-keys > "$KW/node.keys"
  # Exactly tmux's stock keys — except the human layer (conf/tmux-node-human.conf,
  # issue #1840), which may only TAKE AWAY the stock deletes and swap the pane's
  # right-click menus for a read-only one, and drop whatever else this tmux ships
  # that deletes (its sweep): no other key differs, and no key on the node deletes
  # or respawns anything.
  HUMAN_KEYS=' prefix:x prefix:& prefix:$ prefix:< prefix:> root:MouseDown3Pane root:M-MouseDown3Pane root:MouseDown3Status root:MouseDown3StatusLeft root:MouseDown3StatusRight root:M-MouseDown3Status root:M-MouseDown3StatusLeft root:M-MouseDown3StatusRight '
  # tmux pads the key column to the longest key, so a removed key re-pads every
  # line: compare whitespace-normalised.
  # The 看台's own tables (issue #3000, conf/tmux-view.conf) are the node's only
  # keys of its own: compared apart, below — root and prefix stay tmux's.
  hk() { awk -v hk="$HUMAN_KEYS" '$3 == "fleet-view" || $3 == "fleet-view-pfx" { next } /kill-(pane|window|session|server)|respawn-(pane|window)|rename-session/ { next } { k = $3 ":" $4; gsub(/\\/, "", k); if (index(hk, " " k " ") == 0) { $1 = $1; print } }' "$1"; }
  ndiff=$(diff <(hk "$KW/stock.keys") <(hk "$KW/node.keys"))
  [ -z "$ndiff" ] || { ktm stock kill-server; ktm node kill-server; fail "8: the node binds keys of its own (beyond the human layer it must list exactly tmux's stock keys):
$ndiff"; }
  # fleet-view = the node's root, copied (the 看台's mouse: tmux does not fall back
  # to root for a key a session's key-table lacks), + the 看台's keys — by default
  # ONE action, the panel (issue #3185, EPIC #3178 C7): User927 (⌘P), the phone
  # keys ⌃空格 and F12, ⌃] p; ⌃] itself.
  fv_ours='$4 ~ /^User9[0-9][0-9]$/ || $4 == "C-]" || $4 == "C-\\\\" || $4 == "C-Space" || $4 == "F12"'
  fv_copy=$(awk '$3 == "fleet-view" && !('"$fv_ours"') { $3 = "root"; $1 = $1; print }' "$KW/node.keys")
  [ "$fv_copy" = "$(awk '$3 == "root" && !('"$fv_ours"') { $1 = $1; print }' "$KW/node.keys")" ] \
    || fail "8: the 看台's fleet-view is not a copy of the node's root: $(diff <(printf '%s\n' "$fv_copy") <(awk '$3 == "root" { $1 = $1; print }' "$KW/node.keys") | head -5)"
  # + the codes of the keys issue #3328 folded into ⌘P — ⌘↓ ⌘↑ ⌘[ ⌘] ⌘N ⌘K ⌘Q ⌘T —
  # and ⌃\, each the panel `--forward <action>`
  fv_user=$(awk '$3 == "fleet-view" && $4 ~ /^User/ { print $4 }' "$KW/node.keys" | sort | tr '\n' ' ')
  [ "$fv_user" = "User920 User921 User922 User923 User927 User928 User930 User931 User932 " ] \
    || fail "8: by default the 看台 binds User927 (⌘P) + the forwarded codes of #3328 — got: $fv_user"
  awk '$3 == "fleet-view" && $4 == "User927"' "$KW/node.keys" | grep -q -- '--forward' && fail "8: ⌘P itself is a forward"
  for kf in User920:next User921:prev User922:back User923:fwd User928:new User930:switcher User931:quit User932:dispatch 'C-\\\\:shell'; do   # awk -v unescapes: C-\\ as list-keys prints ⌃\
    awk -v k="${kf%%:*}" '$3 == "fleet-view" && $4 == k' "$KW/node.keys" | grep -q "dash-popup.sh.*--forward ${kf#*:} " \
      || fail "8: ${kf%%:*} does not open the panel as the forward of ${kf#*:}: $(awk -v k="${kf%%:*}" '$3 == "fleet-view" && $4 == k' "$KW/node.keys")"
  done
  for k in C-Space F12; do
    awk -v k="$k" '$3 == "fleet-view" && $4 == k' "$KW/node.keys" | grep -q 'dash-popup.sh' || fail "8: the phone key $k does not open the panel"
  done
  grep -q 'fleet-quick-dispatch' "$KW/node.keys" && fail "8: a 看台 key still opens the 派一件事 popup (fleet-quick-dispatch.py, gone with #3328)"
  fv_pfx=$(awk '$3 == "fleet-view-pfx" { print $4 }' "$KW/node.keys" | sort | tr '\n' ' ')
  [ "$fv_pfx" = "C-] p " ] || fail "8: by default ⌃] takes p and ⌃] only — got: $fv_pfx"
  # a person's extra (the client's FLEET_KEYS_EXTRA, carried by the attach): one more code
  FLEET_KEYS_EXTRA="next=cmd+down" TMUX="$KW/node,0,0" HOME="$KW" python3 "$BIN/fleet-quickopen.py" view-keys \
    || fail "8: view-keys with FLEET_KEYS_EXTRA exited non-zero"
  ktm node list-keys -T fleet-view | awk '$4 == "User920"' | grep -q 'do next' \
    || fail "8: FLEET_KEYS_EXTRA=next=cmd+down does not bind User920 to ⌘↓'s own action (not the forward): $(ktm node list-keys -T fleet-view | awk '$4 == "User920"')"
  ktm node list-keys -T fleet-view | awk '$4 == "User921"' | grep -q -- '--forward prev' || fail "8: an extra for ⌘↓ took ⌘↑'s forward away"
  # the phone keys are this machine's: FLEET_KEY_PHONE=f12 leaves F12 alone (and the extra stays: kept on the server)
  FLEET_KEY_PHONE=f12 TMUX="$KW/node,0,0" HOME="$KW" python3 "$BIN/fleet-quickopen.py" view-keys \
    || fail "8: view-keys with FLEET_KEY_PHONE exited non-zero"
  ktm node list-keys -T fleet-view | awk '$4 == "F12"' | grep -q . || fail "8: FLEET_KEY_PHONE=f12 dropped F12"
  ktm node list-keys -T fleet-view | awk '$4 == "C-Space"' | grep -q . && fail "8: FLEET_KEY_PHONE=f12 still binds ⌃空格"
  # (the whole list, filtered: tmux 3.7 prints nothing for `list-keys -T <t>` when C-] is its only key)
  [ "$(ktm node list-keys | awk '$3 == "fleet-view-pfx" { print $4 }' | tr '\n' ' ')" = "C-] " ] \
    || fail "8: FLEET_KEY_PHONE=f12 still binds ⌃] p: $(ktm node list-keys | awk '$3 == "fleet-view-pfx"')"
  ktm node list-keys -T fleet-view | awk '$4 == "User920"' | grep -q 'do next' || fail "8: a later build dropped the kept FLEET_KEYS_EXTRA (User920)"
  ktm node list-keys > "$KW/node.keys"
  awk '($3 == "fleet-view" && ($4 ~ /^User/ || $4 == "C-]" || $4 == "C-\\\\")) || $3 == "fleet-view-pfx"' "$KW/node.keys" \
    | grep -Eq 'kill-(pane|window|session|server)|respawn-(pane|window)|rename-session' && fail "8: a 看台 key deletes, respawns or renames"
  awk '$3 == "root" || $3 == "prefix"' "$KW/node.keys" | grep -q 'fleet-quickopen' && fail "8: a 看台 key leaked into root / prefix"
  if awk '$3 != "fleet-view"' "$KW/node.keys" | grep -Eq 'kill-(pane|window|session|server)|respawn-(pane|window)|rename-session'; then
    ktm stock kill-server; ktm node kill-server
    fail "8: a node key still deletes, respawns or renames: $(awk '$3 != "fleet-view"' "$KW/node.keys" | grep -E 'kill-|respawn-|rename-session' | awk '{print $3, $4}' | tr '\n' ' ')"
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
  ktm stock kill-server; ktm node kill-server
  rm -rf "$KW"
fi

# --- 10. the switch keys: the 看台's table ⇄ the iTerm2 profile (issue #1903) ---
# `dash-keymap.sh --panel switch` is the one table: fleet_view.py binds the 看台's
# keys off it, fleet-iterm-profile.py writes the ⌘ chords that send its codes.
sw_table="$(bash "$KEYMAP" --panel switch list)" || fail "10: dash-keymap.sh --panel switch list exited non-zero"
# `new` (⌘N / prefix c, issue #1953 → #3119): a new session — private code 928.
# `fold` (⌘. / prefix ., issue #2167): the session in view's sub-tasks — 929.
# `switcher` (⌘K / prefix s, code 930) went with issue #3185: ⌘K is iTerm2's again.
# `needs` (⌘J · 924 · prefix k) and `help` (⌘/ · 926 · prefix ?) went with issue #2362.
# `quit` (⌘Q / prefix Q, issue #2349): 退出 fleet — 931.
# `dispatch` (⌘T / prefix t, issue #2753): 派一件事 — 932.
[ "$(printf '%s\n' "$sw_table" | grep -c .)" = 10 ] || fail "10: the switch table is not #1903's 6 (less needs / help, #2362) + #1953's new + #2167's fold + #2349's quit + #2753's dispatch (less #2266's switcher, #3185): $sw_table"
[ "$(printf '%s\n' "$sw_table" | awk '{print $1}' | tr '\n' ' ')" = "next prev back fwd zoom quickopen new fold quit dispatch " ] \
  || fail "10: the switch actions are not next prev back fwd zoom quickopen new fold quit dispatch"
# one action is bound by default (issue #3185): the panel
[ "$(bash "$KEYMAP" --panel switch default | tr '\n' ' ')" = "quickopen " ] || fail "10: the default-bound column names more than quickopen"
[ "$(bash "$KEYMAP" --panel switch full | awk '{ print $1, $2, $3, $4, $5 }')" = "$sw_table" ] || fail "10: full's first five columns are not list"
printf '%s\n' "$sw_table" | awk '$1 == "dispatch" && $2 == "⌘T" && $3 == "0x74-0x100000" && $4 == 932 && $5 == "t"' | grep -q . \
  || fail "10: dispatch is not ⌘T · 0x74-0x100000 · code 932 · prefix t"
printf '%s\n' "$sw_table" | awk '$4 == 924 || $4 == 926 || $2 == "⌘J" || $2 == "⌘/"' | grep -q . \
  && fail "10: a retired code / chord is back in the switch table (924 ⌘J, 926 ⌘/ — issue #2362)"
printf '%s\n' "$sw_table" | awk '$1 == "quit" && $2 == "⌘Q" && $3 == "0x71-0x100000" && $4 == 931 && $5 == "Q"' | grep -q . \
  || fail "10: quit is not ⌘Q · 0x71-0x100000 · code 931 · prefix Q"
printf '%s\n' "$sw_table" | awk '$4 == 930 || $2 == "⌘K"' | grep -q . \
  && fail "10: ⌘K / code 930 is back in the switch table (retired with issue #3185)"
printf '%s\n' "$sw_table" | awk '$1 == "new" && $2 == "⌘N" && $4 == 928 && $5 == "c"' | grep -q . \
  || fail "10: new is not ⌘N · code 928 · prefix c"
printf '%s\n' "$sw_table" | awk '$1 == "fold" && $2 == "⌘." && $3 == "0x2e-0x100000" && $4 == 929 && $5 == "."' | grep -q . \
  || fail "10: fold is not ⌘. · 0x2e-0x100000 · code 929 · prefix ."
while read -r sa _ sk _ _; do
  [ -n "$sa" ] || continue
  case "$sk" in 0x[0-9a-f]*-0x[0-9a-f]*) ;; *) fail "10: $sa: '$sk' is not an iTerm2 key spec" ;; esac
  [ $(( $(printf '%d' "${sk#*-}") & 0x100000 )) -ne 0 ] || fail "10: $sa: '$sk' carries no ⌘"
done <<EOF
$sw_table
EOF
SW_PROF=$(mktemp -d "${TMPDIR:-/tmp}/fkeys-iterm.XXXXXX") || fail "10: mktemp"
# the client's profile (issue #3185, EPIC #3178 C7): ONE ⌘ chord, ⌘P, + ⇧↵ — and
# the ⌘ keys issue #3328 folded into ⌘P, at their old
# codes (the 看台 forwards them to the panel); FLEET_KEY_PANEL=off none;
# FLEET_KEYS_EXTRA adds exactly what it names (a forward of the same chord goes)
sw_map() { FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_PREFS=/dev/null ITERM_PROFILE='' FLEET_CONF_DIR="$SW_PROF/conf" "$@" python3 "$BIN/fleet-iterm-profile.py" json \
  | python3 -c 'import json,sys; m=json.load(sys.stdin)["Profiles"][0]["Keyboard Map"]; print(" ".join("%s=%s" % (k, m[k].get("Text")) for k in sorted(m)))'; }
FWD="0x5b-0x100000=[922~ 0x5d-0x100000=[923~ 0x6b-0x100000=[930~ 0x6e-0x100000=[928~"
FWD_T="0x71-0x100000=[931~ 0x74-0x100000=[932~"
FWD_A="0xf700-0x300000=[921~ 0xf701-0x300000=[920~"
[ "$(sw_map env)" = "$FWD 0x70-0x100000=[927~ $FWD_T 0xd-0x20000=0x0a $FWD_A" ] || fail "10: the default profile is not ⌘P + ⇧↵ + #3328's forwards: $(sw_map env)"
[ "$(sw_map env FLEET_KEY_PANEL=off)" = "0xd-0x20000=0x0a" ] || fail "10: FLEET_KEY_PANEL=off still maps a ⌘ key: $(sw_map env FLEET_KEY_PANEL=off)"
[ "$(sw_map env "FLEET_KEY_PANEL=cmd+'" 'FLEET_KEYS_EXTRA=next=cmd+down shell=ctrl+\ bogus=cmd+z')" = "0x27-0x100000=[927~ $FWD $FWD_T 0xd-0x20000=0x0a $FWD_A" ] \
  || fail "10: FLEET_KEY_PANEL=cmd+' + FLEET_KEYS_EXTRA=next=cmd+down is not ⌘' + ⌘↓: $(sw_map env "FLEET_KEY_PANEL=cmd+'" 'FLEET_KEYS_EXTRA=next=cmd+down shell=ctrl+\ bogus=cmd+z')"
# read from fleet.conf's [client] section when the environment has none
mkdir -p "$SW_PROF/conf"
printf '[ "${FLEET_SHELL:-0}" = 1 ] && FLEET_KEYS_EXTRA="new=cmd+n"\n' > "$SW_PROF/conf/fleet.conf"
[ "$(sw_map env -u FLEET_KEYS_EXTRA)" = "$FWD 0x70-0x100000=[927~ $FWD_T 0xd-0x20000=0x0a $FWD_A" ] || fail "10: FLEET_KEYS_EXTRA in fleet.conf [client] is not read: $(sw_map env -u FLEET_KEYS_EXTRA)"
python3 -c 'import json,sys; m=json.load(sys.stdin)["Profiles"][0]["Keyboard Map"]; assert "0x6a-0x100000" not in m and "0x2f-0x100000" not in m, m' \
  < <(FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_PREFS=/dev/null ITERM_PROFILE='' python3 "$BIN/fleet-iterm-profile.py" json) \
  || fail "10: the profile maps ⌘J or ⌘/ (issue #2362)"
FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_PREFS=/dev/null ITERM_PROFILE='' python3 "$BIN/fleet-iterm-profile.py" write
FLEET_ITERM_DIR="$SW_PROF" FLEET_ITERM_KEYS=0 python3 "$BIN/fleet-iterm-profile.py" write
[ -f "$SW_PROF/fleet.json" ] && fail "10: FLEET_ITERM_KEYS=0 left the profile in place"
rm -rf "$SW_PROF"

# --- 11. no page of keys, no ⌘J (issue #2362) ---------------------------------
grep -q -- '--page' "$KEYS" && fail "11: fleet-keys.sh still has its --page"
SH="$(FLEET_UI_LANG=zh NO_COLOR=1 bash "$KEYS" --plain)"
grep -Eq '^  prefix (k|\?) ' <<< "$SH" && fail "11: the sheet still lists prefix k / prefix ?: $(grep -E '^  prefix (k|\?) ' <<< "$SH")"
grep -Eq '⌘J|⌘/' <<< "$SH" && fail "11: the sheet still names ⌘J / ⌘/"
grep -qx 'bin/fleet-keys.sh' "$ROOT/tokenledger/hub/api/fleetclient/manifest" && fail "11: the client still ships fleet-keys.sh"

# 9 — the recovery page's keys (issue #1862)
page_out=$(python3 - "$BIN" <<'PY'
import importlib.util, os, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("page", os.path.join(sys.argv[1], "fleet-session-page.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
plain = lambda t: __import__("re").sub(r"\x1b\[[0-9;]*m", "", t)
w = m.TEXT["zh"]
errs = []
if plain(m.keys_line(w)) != "↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口": errs.append("no-layer row: %r" % plain(m.keys_line(w)))
if plain(m.keys_line(w, "off")) != plain(m.keys_line(w)): errs.append("off row differs")
if plain(m.keys_line(w, "on")) != "↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口 · p 不带个人配置重开": errs.append("on row: %r" % plain(m.keys_line(w, "on")))
# the line under the conversation (issue #2743): one line, two wordings
if plain(m.render({"rc": 0, "lang": "zh", "sid": "s"}, 80)) != "会话已结束 · ↵ 重开 · ⌘P 回列表   r 新对话 · q 关窗口": errs.append("ended line: %r" % plain(m.render({"rc": 0, "lang": "zh", "sid": "s"}, 80)))
if not plain(m.render({"rc": 137, "lang": "zh", "sid": "s"}, 80)).startswith("会话意外退出 · "): errs.append("crash line: %r" % plain(m.render({"rc": 137, "lang": "zh"}, 80)))
for ch, want, pers in (("\r", m.RESUME, False), ("r", m.NEW, False), ("q", m.QUIT, False),
                       ("p", None, False), ("p", m.PERSONAL, True)):
    if m.choice(ch, 24, pers) != want: errs.append("choice(%r, personal=%s) = %r" % (ch, pers, m.choice(ch, 24, pers)))
print("\n".join(errs) or "ok")
PY
)
[ "$page_out" = ok ] || fail "9: the recovery page's keys: $page_out"

printf 'selftest OK: cheatsheet matches shipped binds (%s dashboard ⌃-keys checked)\n' \
  "$(printf '%s\n' "$sheet_dash_keys" | grep -c .)"
