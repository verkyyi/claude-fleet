#!/bin/bash
# Real tmux on a private socket: layout/focus, input, narrow screens, lifecycle,
# fleet isolation, shared row order, and the spinner's sidebar activity guard.
set -uo pipefail
# The list is drawn on a fleet socket here: on a real node it is the client's
# only (issue #1713), so the drawer's tests take the seam fleet-sidebar.sh offers.
export FLEET_SIDEBAR_NODE=1
# Every session its own row (issue #2675): these legs are about layout, input
# and lifecycle, not the batch view — sidebar-batch-view-selftest.sh pins that.
export FLEET_SIDEBAR_FOLD=off
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null 2>&1 || { echo 'selftest SKIP: tmux missing'; exit 0; }
python3 - "$BIN" <<'PY'
import importlib.util
import fcntl
import os
from pathlib import Path
import pty
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

real_bin = Path(sys.argv[1])
os.environ['FLEET_UI_LANG'] = 'zh'
sys.path.insert(0, str(real_bin))   # as when it runs: fleet_reap_policy beside it
spec = importlib.util.spec_from_file_location('sidebar', real_bin / 'fleet-sidebar.py')
sidebar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sidebar)
assert sidebar.clip('修复仪表盘', 5) == '修复'
assert sidebar.clip('e\u0301\x1b[31m', 1) == 'e\u0301'
assert not sidebar.visible(['0', '0', '1', ''], 100)
assert not sidebar.visible(['1', '1', '1', ''], 100)
assert not sidebar.visible(['1', '0', '0', ''], 100)
assert not sidebar.visible(['1', '0', '1', '99'], 100)
assert sidebar.visible(['1', '0', '1', '1'], 100)
# The popup pause is event-driven (issue #1536): `@popup_pid <epoch>:<pid>` names
# the holder of THAT epoch, and a gone holder ends the pause at once — no 30s.
holder = subprocess.Popen(['sleep', '30'])
assert not sidebar.visible(['1', '0', '1', '99', '99:%d' % holder.pid], 100), 'a live holder must pause the list'
holder.kill(); holder.wait()
assert sidebar.visible(['1', '0', '1', '99', '99:%d' % holder.pid], 100), 'a dead holder must not pause the list'
assert not sidebar.visible(['1', '0', '1', '99', '98:%d' % holder.pid], 100), "another epoch's holder: the 30s bound"
assert sidebar.visible(['1', '0', '1', '60', '60:%d' % os.getpid()], 100), 'a flag past 30s never pauses'
assert sidebar.tail('abc修复', 5) == 'c修复' and sidebar.tail('abc', 9) == 'abc'
# The bar's refresh icon (issue #2228): lit while the list waits, and once lit it
# stays at least REFRESH_HOLD — a frame landing just past STALE_SECS never blinks it.
lit = sidebar.refresh_lit
assert lit(False, 10.0, None) == (False, None), 'nothing waited on: dark'
assert lit(True, 10.0, None) == (True, 10.0), 'waiting: lit, and when'
assert lit(True, 12.0, 10.0) == (True, 10.0), 'still waiting: the first lighting counts'
assert lit(False, 10.4, 10.0) == (True, 10.0), 'a frame inside the hold: still lit'
assert lit(False, 11.0, 10.0) == (False, None), 'past the hold: dark'
assert sidebar.STALE_SECS == 3 and sidebar.REFRESH_HOLD == 1.0
# The view's width is HELD (issue #1521): tmux scales every pane when a window
# takes a client's size (210 → 189 columns), and the manual width used to stay
# where the scale left it until the next move — 37 ↔ 26 on every switch.
fit = sidebar.fit_plan
assert fit(26, 189, '@1', False, '37', [], (37, 210, '@1', '')) == (('resize', 37), (37, 189, '@1', '')), 'scaled: back to the manual width'
assert fit(26, 189, '@1', False, '37', [], None) == (('resize', 37), (37, 189, '@1', '')), 'a fresh view corrects too'
assert fit(37, 189, '@1', False, '37', [], (37, 189, '@1', '')) == (None, (37, 189, '@1', '')), 'at its width: zero calls'
assert fit(30, 189, '@2', False, '37', [], (37, 189, '@1', '')) == (('resize', 37), (37, 189, '@2', '')), 'moved to another window: not a drag'
assert fit(40, 189, '@1', False, '37', [], (37, 189, '@1', '')) == (('manual', 40), (40, 189, '@1', '')), 'same window, same width, pane moved: the operator dragged'
assert fit(40, 189, '@1', False, '40', [], (40, 189, '@1', '')) == (None, (40, 189, '@1', '')), 'the dragged width is then held'
# The view left @1 and came back between two ticks (move_view's stamp moved on)
# while @1 was scaled 210 → 189 and back: not a drag — the hole tmux 3.4 found.
assert fit(12, 189, '@1', False, '37', [], (37, 189, '@1', '1'), '2') == (('resize', 37), (37, 189, '@1', '2')), 'moved away and back since the last fit: not a drag'
assert fit(26, 189, '@1', True, '37', [], (37, 210, '@1', '')) == (None, (37, 210, '@1', '')), 'zoomed: nothing'
assert fit(26, 117, '@1', False, '37', [], (37, 210, '@1', '')) == (None, (26, 117, '@1', '')), 'too narrow for 37 + the worker 80: nothing'
assert fit(26, 118, '@1', False, '37', [], (37, 210, '@1', ''))[0] == ('resize', 37), 'just wide enough: corrected'
assert fit(26, 189, '@1', False, '', [], (30, 210, '@1', '')) == (('resize', 30), (30, 189, '@1', '')), 'no manual width: auto_width is re-applied as before'
assert fit(26, 100, '@1', False, '', [], (30, 160, '@1', '')) == (None, (26, 100, '@1', '')), 'auto, too narrow: nothing'
# The bar's line for the highlighted row (issue #1377 → #2305): its whole name,
# then what the row no longer carries. Which `!` / why a ↻ waits (field 7) moved
# to the worker header, @title_info.
parent = ['@1', 'looping', '↻', '阿里云成本', '▸', '1/2', '0', '等子任务 1/2']
assert sidebar.detail_line(parent) == '阿里云成本', sidebar.detail_line(parent)
assert '等子任务' not in sidebar.detail_line(parent)
# ←/→ fold AT ONCE (issue #1530): the view's guess, the producer's rules — ←
# shuts the innermost OPEN block the cursor is in, a needs row and the current
# window stay, → redraws the block from the rows last seen in it.
fr = lambda w, st, tree, d: [w, st, '·', 'x', tree, '', str(d), '', '']
frows = [['hdr', 'o/a', '', 'a (4)', ' '], fr('@1', 'working', '▾', 0), fr('@2', 'done', '└▾', 1),
         fr('@3', 'done', ' └', 2), fr('@4', 'needs', '└', 1), ['hdr', 'o/b', '', 'b (1)', ' '],
         fr('@5', 'done', '', 0)]
fcache = {}
sidebar.remember_folds(frows, fcache)
assert sorted(fcache) == ['@1', '@2', 'hdr:o/a', 'hdr:o/b'], fcache
ids = lambda rows: [r[0] for r in rows]
shut, holder = sidebar.fold_now(frows, '@3', 'collapse', '@9', fcache)
assert holder == '@2' and ids(shut) == ['hdr', '@1', '@2', '@4', 'hdr', '@5'] and shut[2][4] == '└▸', shut
# a root shut in the batch view (issue #2675) takes its needs row in too; with
# FLEET_SIDEBAR_FOLD=off it stays, as before
old_shut, holder = sidebar.fold_now(shut, '@1', 'collapse', '@9', dict(fcache))
assert holder == '@1' and ids(old_shut) == ['hdr', '@1', '@4', 'hdr', '@5'] and old_shut[1][4] == '▸', old_shut
os.environ['FLEET_SIDEBAR_FOLD'] = 'batch'
shut, holder = sidebar.fold_now(shut, '@1', 'collapse', '@9', fcache)
assert holder == '@1' and ids(shut) == ['hdr', '@1', 'hdr', '@5'] and shut[1][4] == '▸', shut
os.environ['FLEET_SIDEBAR_FOLD'] = 'off'
opened, holder = sidebar.fold_now(shut, '@1', 'expand', '@9', fcache)
assert holder == '@1' and ids(opened) == ['hdr', '@1', '@2', '@4', 'hdr', '@5'], opened
shut, holder = sidebar.fold_now(frows, 'hdr:o/a', 'collapse', '@2', fcache)
assert ids(shut) == ['hdr', '@2', '@4', 'hdr', '@5'] and shut[0][3] == '▸ a (4)', shut
opened, _ = sidebar.fold_now(shut, 'hdr:o/a', 'expand', '@2', fcache)
assert ids(opened) == ids(frows) and opened[0][3] == 'a (4)', opened
assert sidebar.fold_now(frows, '@5', 'collapse', '@9', fcache)[1] is None
assert sidebar.fold_now(frows, '@1', 'expand', '@9', fcache)[1] is None
assert sidebar.fold_now(frows, 'wid:m4/x', 'collapse', '@9', fcache)[1] is None
# A row is state · name · (an EPIC's) N/N and nothing else (issue #2305); the
# producer's fields 9-15 — machine · issue · PR · ctx% · cfg · reap — are the
# bar's, for the highlighted row (detail_line → @fleet_hint_name).
r12 = sidebar.row_fields('\x1f'.join(['@1', 'working', '·', 'issue-1532', ' ', '', '0', '', 'm4', '#1532', '#1552✓', '45%', '', '', 'merged']))
assert len(r12) == sidebar.ROW_FIELDS == 19 and r12[9:12] == ['#1532', '#1552✓', '45%'] and r12[14] == 'merged', r12   # 13: cfg (#1783) · 14: title (#1921) · 15: reap (#1902) · 17-18: ask (#2538) · 19: ctx (#2717, #2963)
want = 'issue-1532 · #1532 · @m4 · #1552✓ · 合并后回收 · 45%'
assert sidebar.detail_line(r12) == want, repr(sidebar.detail_line(r12))
assert sidebar.bar_hint([r12], '@1', '@1', 30)[1] == want.replace('#', '##'), 'the bar: # doubled for tmux'
assert sidebar.bar_hint([['hdr', 'o/a', '', 'a (1)', ' '], r12], 'hdr:o/a', '@1', 30)[1] == '', 'a heading: no detail'
assert sidebar.detail_line(['@3', 'idle', '·', 'notes', ' ', '', '0', '', '', '', '—', '·']) == 'notes', 'placeholders stay out'
for w in (24, 30, 44):
    for badge in ('', '2/3'):
        line = sidebar.row_text('▶', '·', ' ', 'issue-1532 一个很长很长的名字', badge, w)
        assert sidebar.width_of(line) <= w and not re.search(r'#1532|@m4|45%|合并', line), repr(line)
        assert not badge or line.endswith('· ' + badge), 'the N/N stays whole: %r' % line
assert sidebar.row_need(r12) == sidebar.row_need(r12[:10] + [''] * 6), 'row_need asks nothing for the moved fields'
# The row ends in its issue number, whole and right-aligned at any width (issue
# #2545): the name is the issue's short use, the number tells two alike apart;
# the bar leads with the issue's full title (field 13) when the row has one.
for w in (24, 30, 44):
    for badge in ('', '2/3'):
        line = sidebar.row_text('▶', '·', ' ', '常备会话预热把机器锁死一个很长的名字', badge, w, sidebar.row_num(r12))
        assert sidebar.width_of(line) <= w and line.endswith('#1532'), repr(line)
        assert not badge or line.endswith('· 2/3 #1532'), repr(line)
assert sidebar.row_need(r12) == sidebar.row_need(r12[:9] + [''] * 7) + len(' #1532'), 'row_need keeps room for the number'
assert sidebar.row_num(r12[:9] + ['—']) == '' and sidebar.row_num(r12[:9] + ['#12x']) == '', 'only a #<digits> number'
# 「新任务」 ends in what waits behind the orchestrator (issue #2617): orch_<sess>'s
# 7th column → 「排队 N」 where a session row has its #N; no 7th column (Codex, an
# older node) or 0 → the row byte for byte as before. The bar's busy line only
# for a busy orchestrator that cannot count.
import tempfile
_g, _stage = os.environ.get('FLEET_STATUS_G'), sidebar.STAGE
os.environ['FLEET_STATUS_G'] = tempfile.mkdtemp()
sidebar.STAGE = 'fleet-shell'
def _orch(cols):
    with open(os.path.join(os.environ['FLEET_STATUS_G'], 'orch_x'), 'w', encoding='utf-8') as f:
        f.write('\x1f'.join(['f/o', 'm4', 'online'] + cols) + '\n')
_orch(['working', '', ''])
before = sidebar.with_portal([r12], None, 'x')[0]
assert sidebar.row_num(before) == '' and sidebar.orch_busy('x') == sidebar.tr('orch_busy_hint'), before
# the glyph is the working spinner's frame, which turns every 0.25 s: never compared
_ng = lambda r: r[:2] + r[3:]
_orch(['working', '', '', '0'])
assert _ng(sidebar.with_portal([r12], None, 'x')[0]) == _ng(before) and sidebar.orch_busy('x') == '', 'a 0 count: as before, no bar line'
_orch(['working', '', '', '2'])
top = sidebar.with_portal([r12], None, 'x')[0]
assert sidebar.row_num(top) == sidebar.tr('orch_queue_row_fmt', '2') and _ng(top[:9]) == _ng(before[:9]), top
for w in (24, 30):
    line = sidebar.row_text(' ', top[2], top[4], top[3], top[5], w, sidebar.row_num(top))
    assert sidebar.width_of(line) <= w and line.endswith(sidebar.tr('orch_queue_row_fmt', '2')), repr(line)
_orch(['done', '', '', '2'])
assert sidebar.orch_busy('x') == '', 'idle: no bar line'
assert sidebar.bar_hint([r12], '@1', '@1', 30, True, 'a#b')[3] == 'a##b', 'the busy line: # doubled for tmux'
sidebar.STAGE = _stage
if _g is None: os.environ.pop('FLEET_STATUS_G', None)
else: os.environ['FLEET_STATUS_G'] = _g
titled = r12[:13] + ['托管机器上旧版 fleet host on 以登录身份重登记：入口换发令牌'] + r12[14:]
assert sidebar.detail_line(titled).startswith('托管机器上旧版 fleet host on 以登录身份重登记：入口换发令牌 · #1532'), sidebar.detail_line(titled)
# The urgent conditions take the state glyph's cell: a broken configuration a
# red ✗, a lost machine ⊘; a question keeps its red ? / ! (STATE_PAIR needs).
broken = r12[:12] + ['broken'] + r12[13:]
assert sidebar.row_glyph(broken) == ('✗', 'broken') and sidebar.row_glyph(r12) == ('·', '')
assert sidebar.row_glyph(r12[:8] + ['m4!'] + r12[9:]) == ('⊘', 'lost')
assert sidebar.detail_line(broken).endswith('· 会坏·需重开'), sidebar.detail_line(broken)
# A warm start whose issue never got filed (issue #2235): field 16 `failed` — a red
# ∅ in the glyph's cell, 单子没建上 on the bar; a broken configuration still wins.
nofile = r12[:15] + ['failed']
assert sidebar.row_glyph(nofile) == ('∅', 'backfill') and sidebar.row_glyph(broken + ['failed']) == ('✗', 'broken')
assert sidebar.detail_line(nofile).endswith('· 单子没建上'), sidebar.detail_line(nofile)
long12 = r12[:3] + ['阿里云月成本评估-再看一遍'] + r12[4:]
assert sidebar.auto_width([long12], 400, 30, 44) == min(44, max(30, sidebar.row_need(long12))), 'the width follows the bare row'
# ⌃t's landed list: `fleet-history.sh rows` as the view's rows — a heading that
# names the list, then one restore target per row, whitespace folded to fit.
landed_text = ('hdr\x1fhdr\x1f  issue  window\n'
               'landed:1548@o/r\x1fk\x1f\x1b[32m✓\x1b[0m #1512    入口认得-fleet' + ' ' * 12 + ' cf  3 mins  #1548  ·\n'
               'landed:scratch:scratch-5\x1fk\x1f✓ ~5       epic-run                    cf  5 hours\n')
lrows = sidebar.landed_rows(landed_text)
assert [r[0] for r in lrows] == ['hdr', 'landed:1548@o/r', 'landed:scratch:scratch-5'], lrows
assert lrows[0][3] == '已落地 (2) · ↵ 恢复' and lrows[1][2:4] == ['✓', '#1512 入口认得-fleet'], lrows
assert sidebar.selectable(lrows) == ['landed:1548@o/r', 'landed:scratch:scratch-5']
assert sidebar.landed_rows('hdr\x1fhdr\x1fx\n')[1][3] == '（还没有已落地的会话）'
assert sidebar.acts('landed:1548') == '' and sidebar.tap('landed:7', 'landed:7') == 'menu'
# A batch nobody drives (issue #1916): the producer's grey `epicstale:` row has
# no window — a tap highlights it, a second asks 「重开驱动会话？」 (one menu line),
# ↵ reopens the driver seeded `/fleet-epic-run <N> --repo <repo>`: on this
# machine through dash-raw-session.sh, from the shell / for another machine's row
# through fleet-client-place.sh (the seed as its body, the row's machine).
ek, ekr = 'epicstale:acme/app#1949', 'epicstale:acme/tool#77@m4'
assert sidebar.epic_stale_ref(ek) == ('acme/app', '1949', '') and sidebar.epic_stale_ref(ekr) == ('acme/tool', '77', 'm4')
assert sidebar.epic_stale_ref('epicstale:x;y#1') is None and sidebar.epic_stale_ref('@1') is None
assert sidebar.tap(ek, '@1') == 'select' and sidebar.tap(ek, ek) == 'epic', 'two taps: select, then ask'
assert sidebar.acts(ek) == '' and sidebar.folds(ek) == '' and ek in sidebar.selectable([[ek, 'epicstale']])
assert sidebar.sessions([['@1', 'working'], [ek, 'epicstale']]) == ['@1'], 'no window: never a place a close lands'
erow = sidebar.row_fields('\x1f'.join([ek, 'epicstale', '○', '#1949 侧栏改版', ' ', '没人在跑', '0', 'd', '', '#1949']))
ea = sidebar.ask_epic(ek, erow)
assert ea.kind == 'epic' and ea.prompt == '#1949 没人在跑 — 重开驱动会话？' and ea.menu[0][0] == 'reopen' \
    and ea.menu[0][2] == '#1949 侧栏改版' and not ea.menu[0][3], vars(ea)
assert sidebar.ask_epic('@1') is None
got = []
real_start, real_shell = sidebar.start_job, sidebar.SHELL
sidebar.start_job = lambda args, env, done: got.append((args, env)) or 'job'
try:
    sidebar.SHELL = False
    assert sidebar.reopen_epic(ek, {'X': '1'}) == 'job'
    assert got[-1][0][1:] == [str(real_bin / 'dash-raw-session.sh'), '--origin', 'hub', '--name', 'EPIC 1949',
                              '--prompt', '/fleet-epic-run 1949 --repo acme/app', '--repo', 'acme/app'], got[-1][0]
    assert got[-1][1].get('FLEET_SPAWN_FOCUS') == '1'
    for shell, key, node in ((False, ekr, 'm4'), (True, ek, 'auto')):
        sidebar.SHELL = shell
        sidebar.reopen_epic(key, {})
        a = got[-1][0]
        assert a[1:5] == [str(real_bin / 'fleet-client-place.sh'), sidebar.epic_stale_ref(key)[0], 'scratch', '--name'] \
            and a[5].startswith('EPIC ') and '#' not in a[5] and a[a.index('--node') + 1] == node, a
        seed = open(a[a.index('--body-file') + 1]).read()
        n, repo = sidebar.epic_stale_ref(key)[1], sidebar.epic_stale_ref(key)[0]
        assert seed == '/fleet-epic-run %s --repo %s' % (n, repo), seed
    assert sidebar.reopen_epic('@1', {}) is None
finally:
    sidebar.start_job, sidebar.SHELL = real_start, real_shell
# The question's line editor (issue #1097 — the list's input line's until #1950,
# bin/fleet-ask.py now): a cursor, readline's moves and kills.
aspec = importlib.util.spec_from_file_location('fleet_ask', real_bin / 'fleet-ask.py')
fask = importlib.util.module_from_spec(aspec)
aspec.loader.exec_module(fask)
Line = fask.Line
line = Line('ab'); line.left(); line.insert('c')
assert (line.text, line.pos) == ('acb', 2)
line.home(); assert line.pos == 0; line.end(); assert line.pos == 3
line.home(); line.backspace(); assert line.text == 'acb'  # nothing before the cursor
line.delete(); assert (line.text, line.pos) == ('cb', 0)
line = Line('foo bar  baz'); line.word_left(); assert line.pos == 9
line.word_left(); assert line.pos == 4
line.word_right(); assert line.pos == 7
line.kill_eol(); assert line.text == 'foo bar'
line.kill_word(); assert (line.text, line.pos) == ('foo ', 4)
line = Line('新会话 测试'); line.word_left(); line.insert('x')
assert line.text == '新会话 x测试' and line.view(30) == '新会话 x▏测试'
# CJK takes two cells: the cursor keeps its place in a view too narrow for all.
line = Line('修复仪表盘侧栏'); line.pos = 3
assert line.view(7) == '复仪▏表', line.view(7)
line.end(); assert line.view(7) == '盘侧栏▏'; line.home(); assert line.view(7) == '▏修复仪'
assert Line('abc').view(9) == 'abc▏' and Line().view(5) == '▏'
# One meaning per key on the question's line (issue #1950): the list's double
# meaning (an empty line's ←→ fold, ⌃k jump) went with its input line.
import curses
assert [fask.edit_of(k) for k in (curses.KEY_LEFT, curses.KEY_RIGHT, curses.KEY_HOME, curses.KEY_END)] == \
    ['left', 'right', 'home', 'end']
assert fask.edit_of(curses.KEY_UP) == '' and fask.edit_of(curses.KEY_DOWN) == ''
assert [fask.edit_of(k) for k in (1, 5, 23, 21, 11)] == ['home', 'end', 'kill_word', 'clear', 'kill_eol']
assert fask.edit_of(fask.WORD_LEFT) == 'word_left' and fask.edit_of(ord('a')) == ''
assert fask.paste_text('a\nb\tc\n') == 'a b c'
assert fask.typed('q') and fask.typed('修') and fask.typed(' ')
assert not fask.typed('\x0e') and not fask.typed('\x7f')
# The list has no line editor and reads no key (issue #1950): its strings and
# its editor are the question's.
for gone in ('Line', 'edit_of', 'escape_word', 'pasted', 'HELP_ROW', 'PLACEHOLDER', 'PIN_KEY', 'mark_input'):
    assert not hasattr(sidebar, gone), 'the list still has ' + gone
# A question is a spec bin/fleet-ask.py draws: a rename starts on the old name,
# a hintless line names its keys; a one-key question and a menu carry theirs.
q = sidebar.Ask('rename', '改名› ', arg='@1', text='旧名').spec()
assert (q['prompt'], q['text'], q['hint']) == ('改名›', '旧名', '↵ 确定 · esc 取消'), q
q = sidebar.Ask('restore', 'y / r› ', hint='PR 已关', keys='yYrR').spec()
assert (q['keys'], q['hint']) == ('yYrR', 'PR 已关'), q
q = sidebar.Ask('place-where', '开在哪', menu=[('m4', 'm4', '', True), ('m5', 'm5', 'idle', False)]).spec()
assert q['menu'][1] == ['m5', 'm5', 'idle', False] and q['at'] == 1 and q['hint'] == '', q
nq = sidebar.Ask('new', '新任务› ')
nq.choices, nq.at, nq.repo = [('o/a', 'o/a'), ('o/b', 'o/b')], 0, 'o/a'
q = nq.spec()
assert [c[0] for c in q['choices']] == ['o/a', 'o/b'] and 'b' in q['choices'][1][1] and not q.get('fill'), q
sq = sidebar.Ask('sub', '切到› ', arg='@1'); sq.choices = [('acct1', 'acct1 · 5h 10%')]
assert sidebar.Ask('sub', '').spec().get('choices') is None and sq.spec()['fill'] and sq.spec()['at'] == -1
q = fask.Question(sq.spec()); q.step(); assert q.line.text == 'acct1' and q.answer() == {'text': 'acct1', 'choice': 'acct1'}
q = fask.Question(sidebar.Ask('place-where', '', menu=[('m4', 'm4', '', True), ('m5', 'm5', '', False)]).spec())
q.move(1); assert q.answer() == {'choice': 'm5'}, 'a greyed item is never picked'
# A tap on a row's caret folds it (issue #1950: the mouse's ←/→) — on a session
# row anywhere left of its name (issue #2167: ▸ / ▾, the gap after it, the glyph,
# the marker), a heading's first two cells; a row with no block never.
crow = ['@1', 'working', '·', 'x', '▾', '', '0', '', '']
cx = sidebar.width_of(sidebar.row_left(' ', '·', '▾', '')) - 2
assert sidebar.row_left(' ', '·', '▾', 'x')[cx] == '▾' and sidebar.on_caret(crow, cx)
assert all(sidebar.on_caret(crow, c) for c in range(cx + 2)), 'the prefix left of the name is the caret'
assert not sidebar.on_caret(crow, cx + 2) and not sidebar.on_caret(crow[:4] + [' '] + crow[5:], cx)
assert sidebar.on_caret(['hdr', 'o/a', '', '▸ a (2)', ''] + [''] * 4, 0) and not sidebar.on_caret(['hdr', 'o/a', '', 'a (2)', ''] + [''] * 4, 5)
R = lambda k, st: [k, st, '', k] + [''] * 8
rows = [['hdr', '', '!', '! 2'] + [''] * 8, R('@1', 'done'), R('@2', 'needs'),
        R('@3', 'working'), R('@4', 'failed'), R('@5', 'done')]
assert sidebar.next_attention(rows, '@1') == '@2'
assert sidebar.next_attention(rows, '@2') == '@4'
assert sidebar.next_attention(rows, '@5') == '@2'          # wraps round
assert sidebar.next_attention(rows, 'gone') == '@2'
assert sidebar.next_attention([R('@1', 'done')], '@1') == ''
# the producer's 要你处理 summary row (issue #1750) is told apart — and never drawn
# since issue #1950 (the list is sessions only; a row waiting is its own red !)
assert sidebar.is_attn_summary(rows[0]) and not sidebar.is_attn_summary(rows[1])
assert not sidebar.is_attn_summary(None) and sidebar.key_of(rows[0]) == 'hdr'
assert not sidebar.is_attn_summary(['hdr', 'o/b', '', 'b (1)'])

real_tmux = shutil.which('tmux')
work = Path(tempfile.mkdtemp(prefix='sidebar-selftest.'))
# A sandbox install root (issue #896): the input line spawns through the REAL
# dash-raw-session.sh, so every script is the shipped one except the agent
# launcher, which only holds its window open. Its fleet.conf lifts the machine-
# wide session cap and the memory admit gate — the operator's own live sessions
# must not refuse this test.
root = work / 'root'
bin_dir = root / 'bin'
bin_dir.mkdir(parents=True)
for source in real_bin.iterdir():
    if source.name != 'fleet-claude.sh':
        (bin_dir / source.name).symlink_to(source)
(bin_dir / 'fleet-claude.sh').write_text('#!/bin/sh\nexec sleep 600\n')
(bin_dir / 'fleet-claude.sh').chmod(0o755)
(root / 'conf').symlink_to(real_bin.parent / 'conf')
(root / 'fleet.conf').write_text('FLEET_GLOBAL_MAX_SESSIONS=0\nFLEET_ADMIT=0\n')   # nor a busy box's memory gate
main = work / 'main'
main.mkdir()
for git in (['init', '-q'], ['config', 'user.email', 't@t'], ['config', 'user.name', 't'],
            ['commit', '-q', '--allow-empty', '-m', 'seed']):
    subprocess.run(['git', '-C', str(main), *git], check=True, timeout=15,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
base = subprocess.run(['git', '-C', str(main), 'branch', '--show-current'], text=True,
                      capture_output=True, timeout=15).stdout.strip()
fleet_conf = 'FLEET_SIDEBAR=1\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=%s\n' % (main, base)
sock = str(work / 'fleet-test')
env = dict(os.environ, TMPDIR=str(work), FLEET_CONF_DIR=str(work / 'conf'),
           FLEET_HUB_VISITS_LOGDIR=str(work / 'logs'), TERM='xterm-256color',
           FLEET_UI_LANG='zh', FLEET_SIDEBAR_WATCHDOG_SECS='1')
shim = work / 'path'
shim.mkdir()
(shim / 'tmux').write_text('#!/bin/sh\nexec ' + shlex.quote(real_tmux) +
                          ' -S ' + shlex.quote(sock) + ' "$@"\n')
(shim / 'tmux').chmod(0o755)
env['PATH'] = str(shim) + os.pathsep + env['PATH']
conf = work / 'conf/fleets/fleet-test/conf'
conf.parent.mkdir(parents=True)
conf.write_text(fleet_conf)
client = None
terminal = None
checks = 0

def command(args, **kwargs):
    return subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=15, **kwargs)

def tm(*args):
    result = command([real_tmux, '-S', sock, *args])
    if result.returncode:
        raise AssertionError((args, result.stderr))
    return result.stdout.rstrip('\n').replace('\\037', '\x1f')

def check(condition, message):
    global checks
    assert condition, message
    checks += 1

def wait_for(predicate, message, secs=8):
    deadline = time.monotonic() + secs
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    snapshots = [tm('display-message', '-p', '-t', p[0],
                    '#{pane_id} top=#{pane_top} height=#{pane_height} width=#{pane_width} window=#{window_height}x#{window_width} client=#{client_height}x#{client_width} zoomed=#{window_zoomed_flag}') +
                 '\n' + tm('capture-pane', '-p', '-t', p[0]) for p in views()]
    raise AssertionError(message + '\n' + '\n'.join(snapshots))

def views():
    return [line.split() for line in tm('list-panes', '-a', '-F',
            '#{pane_id} #{window_id} #{@sidebar}').splitlines()
            if line.endswith(' 1')]

def call(verb='sync', *args):
    result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), verb, 'fleet-test', *args])
    check(result.returncode == 0, result.stderr)

def view_on(window):
    return [p[0] for p in views() if p[1] == window]

def click(pane, row=0, column=8, repeat=False, count=1):
    # A row tap lands on the row's NAME (column 8): everything left of it is a
    # parent's fold caret since issue #2167.
    # Separate ordinary single clicks from tmux's delayed double-click zoom.
    # The repeat-click regression below deliberately stays inside that interval.
    # count=2 is a deliberate double-click: both press/release pairs go out in
    # ONE write, so a loaded box cannot stretch them past tmux's click timeout.
    if not repeat:
        time.sleep(.6)
    x = int(tm('display-message', '-p', '-t', pane, '#{pane_left}')) + column + 1
    y = int(tm('display-message', '-p', '-t', pane, '#{pane_top}')) + row + 1
    os.write(terminal, ('\x1b[<0;%d;%dM\x1b[<0;%d;%dm' % (x, y, x, y)).encode() * count)

def zoomed(window):
    return tm('display-message', '-p', '-t', window, '#{window_zoomed_flag}')

def copied():
    try:
        return tm('show-buffer')
    except AssertionError:
        return ''

def navigation():
    # a client in the list's old key table — there is none since issue #1950
    return 'fleet-sidebar' in tm('list-clients', '-F', '#{client_key_table}')

def list_only(pane):
    """The view is sessions only (issue #1950): no input line (#896/#1620's `›`),
    no `? 快捷键` row (#948), no 要你处理 summary (#1750) — anywhere in it."""
    text = tm('capture-pane', '-p', '-t', pane)
    lines = [l.rstrip() for l in text.splitlines()]
    return (not any(l == '›' or l.startswith('› ') or l.startswith('改名›') for l in lines)
            and '快捷键' not in text and '在问你' not in text)

def refreshing(pane):
    """The bar's refresh icon is lit (issue #2228; #1536 drew a 「刷新中…」 top
    row instead): a stalled producer's frame is past STALE_SECS, and the list's
    window carries `@fleet_refreshing` — the slot conf/tmux-shell.conf keeps."""
    return tm('show-options', '-wqv', '-t', pane, '@fleet_refreshing') == '1'

def row_y(pane, text):
    """The painted row of the list that shows `text`."""
    return next(i for i, line in enumerate(tm('capture-pane', '-p', '-t', pane).splitlines()) if text in line)

def row_ys(pane):
    """Every painted line's y, by its text — refreshing must move none (issue #2228).
    The ⠋ spinner's frame is dropped from the key: it turns between two reads."""
    spin = re.compile('[\u2800-\u28ff]')
    return {spin.sub('', line).strip(): i for i, line in enumerate(tm('capture-pane', '-p', '-t', pane).splitlines()) if line.strip()}

def ask_pane(window):
    """The question open under the session (bin/fleet-ask.py, `@stage_ask`)."""
    for line in tm('list-panes', '-t', window, '-F', '#{pane_id} #{@stage_ask} #{pane_active}').splitlines():
        part = line.split()
        if len(part) == 3 and part[1] == '1':
            return part[0], part[2] == '1'
    return '', False

def ask_line(window):
    pane = ask_pane(window)[0]
    return tm('capture-pane', '-p', '-t', pane).rstrip() if pane else ''

def painted_text():
    return bytes(screen_out).decode('utf-8', 'replace')

# Focus on a pane's top line is COLOUR ONLY (issue #999): the focused style is
# the bg, and the words never change with focus — so no label jumps in or out.
WORKER_FOCUS = 'bg=#7aa2f7'
TASKS_FOCUS = 'bg=#e0af68'

def border(pane):
    return tm('display-message', '-p', '-t', pane, '#{E:pane-border-format}')

def border_text(pane):
    return re.sub(r'#\[[^]]*\]', '', border(pane))

def windows():
    return tm('list-windows', '-t', 'fleet-test', '-F', '#{window_id}').splitlines()

def server_version():
    found = re.search(r'(\d+)\.(\d+)', tm('display-message', '-p', '#{version}'))
    return tuple(map(int, found.groups())) if found else (0, 0)

def type_keys(text):
    """Type into the attached terminal as a burst: ONE write, as an IME commit
    (「你好世界」 in one go) or a paste-speed typist sends it. Every key must
    land in the sidebar on every supported tmux (issue #1098) — see
    ARCHITECTURE.md for the two mechanisms that make that hold on < 3.7."""
    os.write(terminal, text.encode())

def row_data(current='', compact=True, summary=False):
    row_env = dict(env, FLEET_SESSION='fleet-test', FLEET_SIDEBAR_CURRENT=current)
    result = subprocess.run(['bash', str(bin_dir / 'tmux-dashboard-rows.sh')] +
                            (['--sidebar'] if compact else []), env=row_env,
                            text=True, capture_output=True, timeout=15)
    check(result.returncode == 0, result.stderr)
    rows = [line.split('\x1f') for line in result.stdout.split('\n') if '\x1f' in line]
    # the 要你处理 summary line (issue #1750) only where a check asks for it: the
    # rest index the list as it was before it
    return rows if summary else [r for r in rows if not (r[0] == 'hdr' and '在问你' in ''.join(r))]

def cleanup(*_):
    if client:
        client.terminate()
        try:
            client.wait(timeout=5)
        except subprocess.TimeoutExpired:
            client.kill()
    if terminal is not None:
        os.close(terminal)
    subprocess.run([real_tmux, '-S', sock, 'kill-server'], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(work, ignore_errors=True)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))

try:
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'fleet-test', '-x', '160', '-y', '30',
       '-n', 'worker-one', 'sleep 600')
    env['TMUX'] = sock + ',1,0'
    tm('set-option', '-g', 'default-shell', '/bin/sh')
    w1 = tm('display-message', '-p', '#{window_id}')
    # tmux 3.4 crashes creating a detached window when the GLOBAL size is manual.
    # Only this fixture needs a fixed size; leave new windows on tmux's default.
    tm('set-option', '-w', '-t', w1, 'window-size', 'manual')
    p1 = tm('display-message', '-p', '#{pane_id}')
    tm('set-option', '-w', '-t', w1, '@issue', '1')
    tm('set-option', '-w', '-t', w1, '@wid', 'a1')
    tm('set-option', '-w', '-t', w1, '@claude_state', 'working')
    w2 = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', '修复侧栏', 'sleep 600')
    p2 = tm('display-message', '-p', '-t', w2, '#{pane_id}')
    tm('set-option', '-w', '-t', w2, '@raw', '1')
    tm('set-option', '-w', '-t', w2, '@worktree', str(work / 'repo-scratch-2'))
    tm('set-option', '-w', '-t', w2, '@wid', 'b1')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'needs')
    tm('set-option', '-w', '-t', w2, '@claude_needs', 'ask')
    hub = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'plan', 'sleep 600')
    hp = tm('display-message', '-p', '-t', hub, '#{pane_id}')
    tm('set-option', '-p', '-t', hp, '@dash', '1')

    # Load the shipped sidebar wiring, without unrelated status commands/daemons.
    # The list's keys and hooks are the CLIENT's (conf/tmux-shell.conf, rendered as
    # fleet-shell.sh renders it) since issue #1714 — a node binds none; each
    # window's header (pane-border-format) and the baseline are still the node's.
    shell_conf = ((bin_dir.parent / 'conf/tmux-shell.conf').read_text()
                  .replace('__BIN__', str(bin_dir)).replace('__PREFIX__', 'C-b'))
    node_conf = (bin_dir.parent / 'conf/tmux-attention.conf').read_text()
    shipped = shell_conf
    # The list takes NO keys (issue #1950): no key table routes the keyboard to
    # it, and nothing in the conf switches a client into one.
    check(not any(line.startswith('bind -T fleet-sidebar ') or
                  ('-T fleet-sidebar' in line and not line.startswith('#'))
                  for line in shipped.splitlines()),
          'the client conf still routes keys to the list (a fleet-sidebar key table)')
    swc = next(line for line in shipped.splitlines()
               if line.startswith('set-hook -g session-window-changed[71] '))
    swc_skip = swc.split("if -F '", 1)[1].split("'", 1)[0] if "if -F '" in swc else ''
    check(swc_skip.startswith('#{?') and 'fleet-sidebar.sh sync' in swc,
          'session-window-changed sync lost its already-there fast path')
    selected = [line for line in shell_conf.splitlines() if not line.startswith('#') and
                ('fleet-sidebar' in line or 'after-select-pane[71]' in line or 'client-detached' in line or
                 'MouseDown1Pane' in line or 'MouseDown1Border' in line or 'DoubleClick1Pane' in line or 'DoubleClick1Border' in line or
                 'MouseDown3Pane' in line or line.startswith('bind -n Any ') or
                 line in ('unbind E', 'unbind g', 'unbind Space') or
                 line.startswith('bind -n F9 ') or
                 line.startswith('bind z ') or line.startswith('bind [ ') or line.startswith('bind k '))]
    selected += [line for line in node_conf.splitlines() if
                 line.startswith('set -g pane-border') or line.startswith('set -g default-terminal') or
                 line.startswith('set -g assume-paste-time ') or
                 line == 'set -g mouse on']
    fixture = work / 'sidebar.conf'
    fixture.write_text('\n'.join(selected) + '\n')
    tm('source-file', str(fixture))
    check(not tm('list-keys', '-T', 'fleet-sidebar').strip() if
          subprocess.run([real_tmux, '-S', sock, 'list-keys', '-T', 'fleet-sidebar'], env=env,
                         capture_output=True).returncode == 0 else True,
          'the loaded conf has a fleet-sidebar key table')
    tm('set-hook', '-g', 'session-window-changed[72]',
       "set-option -wF -t fleet-test: @sidebar_ready_on_select '#{@sidebar_worker}'")

    call()
    check(not views(), 'detached fleets must not create sidebar processes')
    terminal, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 160, 0, 0))
    client_env = {k: v for k, v in env.items() if k not in ('TMUX', 'TMUX_PANE')}
    client = subprocess.Popen([real_tmux, '-S', sock, 'attach-session', '-t', 'fleet-test'],
                              env=client_env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    # A tmux menu is a client overlay that capture-pane never shows, so keep
    # what the attached terminal was sent (issue #898): `painted()` reads it.
    screen_out = bytearray()
    def drain():
        try:
            while True:
                chunk = os.read(terminal, 65536)
                if not chunk:
                    return
                screen_out.extend(chunk)
                if len(screen_out) > 1 << 20:
                    del screen_out[:1 << 19]
        except OSError:
            pass
    threading.Thread(target=drain, daemon=True).start()
    wait_for(lambda: bool(view_on(w1)), 'attach hook did not create sidebar')
    # Keep resize fixtures within the attached terminal minus its status bar.
    # A manual height of 30 would put the last pane row under the client's bar.
    window_height = '29'
    tm('resize-window', '-t', w1, '-y', window_height)
    side = view_on(w1)[0]
    side_pid = tm('display-message', '-p', '-t', side, '#{pane_pid}')
    check(Path(tm('display-message', '-p', '-t', side, '#{pane_current_path}')).resolve() == bin_dir.parent.resolve(),
          'a reusable sidebar must not anchor the departed worker worktree')
    check(tm('display-message', '-p', '-t', side, '#{pane_left}:#{pane_width}') == '0:30',
          'sidebar should occupy 30 cells at the left edge')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1, 'split stole worker focus')
    call()
    check(len(views()) == 1, 'sync must be idempotent')
    wait_for(lambda: '修复侧栏' in tm('capture-pane', '-p', '-t', side), 'sidebar did not render tasks')
    # Sessions only (issue #1950 — #1620's input line, #948's `? 快捷键` row and
    # #1750's 要你处理 summary went): the whole height is the list's.
    wait_for(lambda: list_only(side), 'the view still draws a row that is not a session')
    # Only the state glyph has a colour (issue #1622): every other painted cell
    # is PAL_FG or PAL_DIM text, on the default ground or the PAL_SEL raise that
    # the current row (▶) shares with the keyboard's row (›).
    pal = sidebar.palette_colors(sidebar.palette(), 256)
    states = {pal[n] for n in ('PAL_CYAN', 'PAL_RED', 'PAL_GREEN', 'PAL_MAGENTA')}
    text_fg = {pal['PAL_FG'], pal['PAL_DIM']}
    glyphs = {}
    for y, line in enumerate(tm('capture-pane', '-e', '-p', '-t', side).splitlines()):
        fg = bg = None
        x = 0
        for code, ch in re.findall(r'\x1b\[([0-9;]*)m|(.)', line):
            if not ch:
                parts = [int(n) if n else 0 for n in code.split(';')]
                while parts:
                    n = parts.pop(0)
                    if n in (38, 48) and parts[:1] == [5]:
                        if n == 38:
                            fg = parts[1]
                        else:
                            bg = parts[1]
                        parts = parts[2:]
                    elif n == 0:
                        fg = bg = None
                    elif n == 39:
                        fg = None
                    elif n == 49:
                        bg = None
                continue
            if ch != ' ' and x == 2 and fg in states:
                glyphs[(y, ch)] = fg
            elif ch != ' ':
                check(fg in text_fg, 'sidebar cell %r at %d,%d is colour %r, not PAL_FG/PAL_DIM' % (ch, y, x, fg))
            check(bg in (None, pal['PAL_SEL']), 'sidebar cell %r at %d,%d sits on colour %r' % (ch, y, x, bg))
            x += max(1, sidebar.width_of(ch))
    check(pal['PAL_RED'] in glyphs.values() and pal['PAL_CYAN'] in glyphs.values(),
          'the needs / working glyphs lost their state colour: %r' % glyphs)
    # (the 要你处理 summary, issue #1750, is not drawn since #1950: the first row
    # is a session — the producer still writes the summary, below)
    first = tm('capture-pane', '-p', '-t', side).splitlines()[0]
    check('worker-one' in first or '修复侧栏' in first,
          'sidebar should start with a task, not an internal title row: %r' % first)
    check(WORKER_FOCUS in border(p1),
          'active worker border must identify input focus')
    check('INPUT' not in border_text(p1) + border_text(side), 'a border still names its focus')
    tm('select-pane', '-t', side)
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1,
          'sidebar must not become the agent identity for window-targeted tools')
    check(tm('display-message', '-p', '-t', side, '#{@dash}') == '', 'sidebar masquerades as hub')

    full = row_data(compact=False)
    compact = row_data()
    check(all('a1' not in r[3] and 'b1' not in r[3] for r in compact),
          'sidebar displays internal worker handles instead of task descriptions')
    check(all('a1' not in r[2] and 'b1' not in r[2] for r in full if r[0] != 'hdr'),
          'full hub list displays internal worker handles')
    check(tm('show-options', '-wqv', '-t', w1, '@wid') == 'a1', 'rendering changed the internal worker handle')
    check([r[1] for r in full if r[0] != 'hdr'] == [r[0] for r in compact if r[0] != 'hdr'],
          'sidebar order diverges from hub')
    # ONE red `!` for every needs kind since #1328; the kind rides the detail field.
    # (in place since #1750 — the born order — with the 要你处理 summary on top)
    asking = next((r for r in compact if r[0] == w2), None)
    check(asking is not None and asking[2] == '!', 'needs cue was lost')
    check(asking[7] != '', 'a needs row lost its detail (which kind of `!`)')
    top = row_data(summary=True)[0]
    check(top[0] == 'hdr' and top[2] == '!' and '1 个在问你' in top[3],
          'the producer lost the 要你处理 summary (the list drops it; #1940 retires it): %r' % (top,))
    check('在问你' not in tm('capture-pane', '-p', '-t', side), 'the list draws the 要你处理 summary again (#1950)')
    tm('set-option', '-w', '-t', w1, '@pin', '1')
    # The 置顶 group (issue #1170): its heading, then the pinned row — bare, no
    # `* ` — then ONE inert rule the view clips to its width.
    pinned = row_data()
    check(pinned[0][:2] == ['hdr', 'pin'] and pinned[0][3] == '置顶 (1)', 'no 置顶 heading above the pin')
    check(pinned[1][0] == w1, 'sidebar ignored hub pin')
    check(not pinned[1][3].startswith('* '), 'a pinned row still wears the old `* ` mark')
    check(pinned[2][:2] == ['hdr', ''] and set(pinned[2][3]) == {'─'}, 'no rule closes the 置顶 group')
    check(sum(1 for r in pinned if r[0] == 'hdr' and r[3].startswith('─')) == 1, 'more than one rule')
    check(sidebar.key_of(pinned[0]) == 'hdr:pin' and sidebar.key_of(pinned[2]) == 'hdr',
          'the 置顶 heading must be a fold stop and the rule never a cursor stop')
    check(sidebar.tap('hdr:pin', 'hdr:pin') == 'select' and sidebar.target_name('hdr:pin') == '',
          'the 置顶 heading names no repo: a tap only selects it')
    tm('set-option', '-uw', '-t', w1, '@pin')
    check(not any(r[0] == 'hdr' for r in row_data()), 'the 置顶 frame outlived the pin')
    tm('set-option', '-w', '-t', w2, '@origin', 'issue-1')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'done')
    check(w2 not in [r[0] for r in row_data()], 'folded child visible without current/needs exemption')
    check(w2 in [r[0] for r in row_data(current=w2)], 'fold hid the current worker')
    tm('set-option', '-w', '-t', w1, '@expand', '1')
    # The hierarchy glyph is its OWN field since #836 (field 5), not spliced into
    # the label — so a 30-column sidebar draws `marker glyph tree label` and every
    # name starts at the same column whatever its depth.
    kid = [r for r in row_data() if r[0] == w2]
    check(bool(kid) and kid[0][4] == '└', 'parent-child tree cell was lost')
    check(bool(kid) and kid[0][3].startswith('修复侧栏'),
          'the label still carries the tree glyph — it belongs in its own field')
    # (field 13, cfg, rides only a row whose configuration is known — #1783;
    # field 14, title, only a row whose issue title is known — #1921; field
    # 15, reap, only a row with a @reap_policy — #1902; field 16, backfill, only a
    # warm start whose issue was never filed — #2235; fields 17-18, what a needs
    # row asks, only when it asks something — #2538)
    check(all(len(r) == 5 if r[0] == 'hdr' else 12 <= len(r) <= sidebar.ROW_FIELDS
              for r in row_data()),
          'sidebar rows must carry 9 fields (a heading 5)')
    root = [r for r in row_data() if r[0] == w1]
    check(bool(root) and root[0][4] in ('▾', '▸'), 'a holder row must carry its caret in the tree cell')
    cache = work / '.claude-dash/global'
    cache.mkdir(parents=True, exist_ok=True)
    (cache / 'dash_view_fleet-test').write_text('landed')
    check(w1 in [r[0] for r in row_data()], 'hub history toggle hid live sidebar')
    (cache / 'dash_view_fleet-test').unlink()

    # A tap selects by stable window ID; the keyboard never moves (issue #1950).
    wait_for(lambda: '└ 修复侧栏' in tm('capture-pane', '-p', '-t', side), 'fold update did not reach view')
    # `marker glyph tree label` — a root's name and a child's start at the same column.
    pane = [l for l in tm('capture-pane', '-p', '-t', side).split('\n') if '修复侧栏' in l]
    check(bool(pane) and pane[0].index('修复侧栏') == 6,
          'the sidebar name column moved: ' + repr(pane[:1]))
    os.write(terminal, b'\x02E')  # prefix E: the list's old "keyboard onto it" — gone
    time.sleep(.5)
    check(not navigation(), 'prefix E still puts the keyboard on the list (#1950)')
    tm('set-option', '-g', '@switches', '')
    tm('set-hook', '-g', 'session-window-changed[73]', "set-option -gaF @switches '#{window_id} '")
    switches = lambda: tm('show-options', '-gv', '@switches').split()
    started = time.monotonic()
    time.sleep(.6)
    click(side, row_y(side, "修复侧栏"), repeat=True)
    wait_for(lambda: bool(view_on(w2)), 'a tap did not move to the second worker')
    # Informational (issue #1033): the tap → switched latency on this box.
    print('sidebar timing: tap → view on the next worker in %.2fs' % (time.monotonic() - started))
    check(len(views()) == 1, 'background worker retained a sidebar process')
    check(view_on(w2) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'a tap recreated the sidebar instead of moving its populated grid')
    check(tm('show-options', '-wqv', '-t', w1, '@sidebar_worker') == '',
          'source window retained sidebar worker metadata after the move')
    check(tm('show-options', '-wqv', '-t', w2, '@sidebar_ready_on_select') == p2,
          'destination was selected before its sidebar layout was ready')
    check(tm('display-message', '-p', '-t', w2, '#{pane_id}') == p2, 'jump did not focus worker input')
    check(switches() == [w2], 'one tap made %r window switches' % switches())
    check(not navigation(), 'a tap moved the keyboard onto the list')
    tm('set-hook', '-gu', 'session-window-changed[73]')
    # A terminal mouse event exercises the shipped root-table forwarding bind.
    side2 = view_on(w2)[0]
    wait_for(lambda: 'worker-one' in tm('capture-pane', '-p', '-t', side2), 'new view not ready')
    tm('move-window', '-d', '-s', w1, '-t', 'fleet-test:9')
    click(side2)
    wait_for(lambda: bool(view_on(w1)), 'single-click did not jump to first row')
    check(view_on(w1) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'mouse navigation recreated the sidebar')
    check(tm('show-options', '-wqv', '-t', w2, '@sidebar_worker') == '',
          'mouse move left stale worker metadata')
    check(tm('show-options', '-wqv', '-t', w1, '@sidebar_ready_on_select') == p1,
          'mouse navigation showed a destination without its sidebar')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1, 'click changed worker pane identity')
    # The keyboard stays with the session (issue #1950): a key after a tap types
    # into the worker, and the list never shows it.
    worker_before = tm('capture-pane', '-p', '-t', p1)
    type_keys('zq\r')   # its own line: the select-word leg below reads that pane
    wait_for(lambda: 'zq' in tm('capture-pane', '-p', '-t', p1), 'a key after a tap did not reach the session')
    check('zq' not in tm('capture-pane', '-p', '-t', side), 'a key after a tap reached the list')
    check(not navigation(), 'a tap left the client in a key table of the list')
    check(WORKER_FOCUS in border(p1), 'the worker lost its input-focus border after a tap')
    check(TASKS_FOCUS not in border(side), 'sidebar border paints keyboard focus')
    nav_text = [border_text(p1), border_text(side)]

    # The window-changed fast path (issue #1033): a window that already holds a
    # live view naming its worker skips the sync fork; one without a view syncs.
    check(tm('display-message', '-p', '-t', w1, swc_skip) == '',
          'the hook would re-sync a window the jump already moved the view into')
    check(tm('display-message', '-p', '-t', w2, swc_skip) == '1',
          'the hook would skip the sync for a window with no view')
    # window-layout-changed (issue #1530): the jump's own join-pane fires it on the
    # window the view lands in — no sync there (it queued on the jump's lock to do
    # nothing); the window the view left, with none, still syncs.
    wlc = next(line for line in shipped.splitlines()
               if line.startswith('set-hook -g window-layout-changed[71] '))
    wlc_skip = wlc.split("if -F '", 1)[1].split("'", 1)[0] if "if -F '" in wlc else ''
    check('fleet-sidebar.sh sync' in wlc and
          tm('display-message', '-p', '-t', w1, wlc_skip) == '' and
          tm('display-message', '-p', '-t', w2, wlc_skip) == '1',
          'window-layout-changed must sync only a window with no live view: %r' % wlc_skip)

    # The row producer runs BESIDE the UI loop (issue #1033): with it stalled,
    # an arrow still moves the highlight, the follow still switches, and the
    # moved view repaints `▶` on its new row from the rows it already has.
    stall = work / 'rows-stall'
    rows_bin = bin_dir / 'tmux-dashboard-rows.sh'
    (bin_dir / 'tmux-dashboard-rows-real.sh').symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    staged = work / 'rows-wrapper'
    staged.write_text('#!/bin/bash\nn=0\nwhile [ -f %s ] && [ $n -lt 300 ]; do sleep .1; n=$((n+1)); done\n'
                      'exec bash %s "$@"\n' % (shlex.quote(str(stall)),
                                               shlex.quote(str(bin_dir / 'tmux-dashboard-rows-real.sh'))))
    before = row_ys(side)
    stall.write_text('')
    os.replace(staged, rows_bin)
    time.sleep(1.5)  # the view's next refresh is now stuck in the producer
    wait_for(lambda: refreshing(side), 'a stalled producer never lit the refresh icon')
    # The list itself does not move (issue #2228): no 「刷新中…」 row pushes it
    # down — the top line is still a real row, and every row keeps its y.
    lit_rows = row_ys(side)
    check('刷新中…' not in lit_rows, 'the list still draws a 「刷新中…」 row: %r' % list(lit_rows)[:3])
    check(lit_rows == before, 'refreshing moved the list: %r → %r' % (before, lit_rows))
    time.sleep(.6)   # past the double-click window, THEN read where the row is
    y = row_y(side, '修复侧栏')
    started = time.monotonic()
    click(side, y, repeat=True)
    wait_for(lambda: bool(view_on(w2)), 'a stalled producer blocked the tap')
    moved = time.monotonic() - started
    wait_for(lambda: any(l.startswith('▶') and '修复侧栏' in l
                         for l in tm('capture-pane', '-p', '-t', side).splitlines()),
             'the moved view did not repaint ▶ from its cached rows')
    repainted = time.monotonic() - started
    check(stall.exists(), 'the producer stall ended before the repaint was checked')
    check(repainted < 3, 'input waited on the row producer: follow %.2fs, repaint %.2fs' % (moved, repainted))
    stall.unlink()
    rows_bin.unlink()
    rows_bin.symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    (bin_dir / 'tmux-dashboard-rows-real.sh').unlink()
    wait_for(lambda: not refreshing(side), 'the list did not recover its frame')
    time.sleep(.6)
    click(side, row_y(side, 'worker-one'), repeat=True)
    wait_for(lambda: bool(view_on(w1)), 'a tap did not go back after the stalled-producer leg')

    # A fold AT ONCE (issue #1530; a tap on the caret since #1950 took ←/→):
    # with the producer stalled — no frame can land — a tap on the parent's ▾
    # hides its child and a tap on its ▸ brings it back from the rows last seen
    # open. The bit is written all the same, and the first frame after the stall
    # agrees with what was painted.
    kid_shown = lambda: '└ 修复侧栏' in tm('capture-pane', '-p', '-t', side)
    wait_for(kid_shown, 'the child row is not on the list before the fold leg')
    (bin_dir / 'tmux-dashboard-rows-real.sh').symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    staged.write_text('#!/bin/bash\nn=0\nwhile [ -f %s ] && [ $n -lt 300 ]; do sleep .1; n=$((n+1)); done\n'
                      'exec bash %s "$@"\n' % (shlex.quote(str(stall)),
                                               shlex.quote(str(bin_dir / 'tmux-dashboard-rows-real.sh'))))
    stall.write_text('')
    os.replace(staged, rows_bin)
    time.sleep(1.5)  # the view's next refresh is now stuck in the producer
    caret = sidebar.width_of(sidebar.row_left(' ', '·', '▾', '')) - 2
    wait_for(lambda: refreshing(side), 'a stalled producer never lit the refresh icon')
    time.sleep(.6)   # past the double-click window, THEN read where the row is
    y = row_y(side, 'worker-one')
    started = time.monotonic()
    click(side, y, column=caret, repeat=True)
    wait_for(lambda: not kid_shown(), 'a tap on ▾ did not fold the child away before a producer frame')
    folded = time.monotonic() - started
    wait_for(lambda: tm('show-options', '-wqv', '-t', w1, '@expand') == '', 'the fold tap did not write the fold bit', 20)   # dash-fold-toggle.sh: bash 3.2 sourcing fleet-lib
    check(refreshing(side), 'the stall ended before the unfold tap')
    time.sleep(.6)   # past the double-click window, THEN read where the row is
    y = row_y(side, 'worker-one')
    started = time.monotonic()
    click(side, y, column=caret, repeat=True)
    wait_for(kid_shown, 'a tap on ▸ did not draw the child row before a producer frame')
    opened = time.monotonic() - started
    wait_for(lambda: tm('show-options', '-wqv', '-t', w1, '@expand') == '1', 'the unfold tap did not write the fold bit', 20)
    check(bool(view_on(w1)), 'a tap on the caret switched windows')
    check(stall.exists(), 'the producer stall ended before the fold was checked')
    print('sidebar timing: ▾ ▸ taps painted in %.2fs / %.2fs with the producer stalled' % (folded, opened))
    stall.unlink()
    time.sleep(1.5)  # the stale run lands, is dropped, and a fresh one paints
    check(kid_shown(), 'the first frame after the stall disagrees with the fold the view painted')
    rows_bin.unlink()
    rows_bin.symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    (bin_dir / 'tmux-dashboard-rows-real.sh').unlink()

    # Never frozen on the lock (issue #1536): a hook sync holding the view lock
    # for 2s must not freeze the list — a tap moves the highlight at once (the
    # local state), the switch waits, and lands once the lock frees.
    held = open(str(conf) + '.sidebar.lock', 'w')
    fcntl.flock(held, fcntl.LOCK_EX)
    try:
        time.sleep(.6)   # past the double-click window, THEN read where the row is
        y = row_y(side, '修复侧栏')
        started = time.monotonic()
        click(side, y, repeat=True)
        wait_for(lambda: any(l.startswith('›') and '修复侧栏' in l
                             for l in tm('capture-pane', '-p', '-t', side).splitlines()),
                 'a held lock froze the highlight')
        highlighted = time.monotonic() - started
        check(highlighted < 1, 'the highlight waited %.2fs on the held lock' % highlighted)
        time.sleep(max(0, 2 - (time.monotonic() - started)))
        check(view_on(w1) and not view_on(w2), 'the view switched while the lock was held')
    finally:
        fcntl.flock(held, fcntl.LOCK_UN)
        held.close()
    wait_for(lambda: bool(view_on(w2)), 'the switch did not land after the lock freed')
    print('sidebar timing: highlight %.2fs under a 2s-held lock' % highlighted)
    wait_for(lambda: not refreshing(side), 'the list did not recover its frame')
    time.sleep(.6)
    click(side, row_y(side, 'worker-one'), repeat=True)
    wait_for(lambda: bool(view_on(w1)), 'a tap did not go back after the lock leg')

    # The popup pause ends WITH the popup (issue #1536), not 30s later: a window
    # renamed under a live holder stays unpainted, and shows within a second of
    # the holder going — even one SIGKILLed past dash-popup.sh's trap.
    side = view_on(w1)[0]
    holder = subprocess.Popen(['sleep', '60'])
    epoch = str(int(time.time()))
    tm('set', '-g', '@popup_open', epoch, ';', 'set', '-g', '@popup_pid', '%s:%d' % (epoch, holder.pid))
    time.sleep(1.5)  # the view's next tick sees the popup and stops painting
    tm('rename-window', '-t', w2, '弹窗下改名')
    time.sleep(2)
    check('弹窗下改名' not in tm('capture-pane', '-p', '-t', side), 'the list repainted under a live popup')
    started = time.monotonic()
    holder.kill(); holder.wait()
    wait_for(lambda: '弹窗下改名' in tm('capture-pane', '-p', '-t', side),
             'the list did not resume after the popup holder died')
    resumed = time.monotonic() - started
    print('sidebar timing: resumed %.2fs after the popup holder died' % resumed)
    check(resumed < (3 if os.environ.get('CI') else 1.5), 'the list resumed %.2fs after the popup closed' % resumed)
    tm('set', '-g', '@popup_open', '0', ';', 'set', '-gu', '@popup_pid')
    tm('rename-window', '-t', w2, '修复侧栏')
    wait_for(lambda: '修复侧栏' in tm('capture-pane', '-p', '-t', side), 'the rename back did not paint')

    # Never blank (issue #1536): a producer hung for 15s — past its own 10s kill,
    # through a restart that hangs again — leaves the last rows painted under a
    # lit refresh icon (issue #2228; a 「刷新中…」 top row before it), and the
    # watchdog writes ONE line for the stall.
    stall_log = bin_dir.parent / 'logs' / 'sidebar-stall.log'
    logged = len(stall_log.read_text().splitlines()) if stall_log.exists() else 0
    (bin_dir / 'tmux-dashboard-rows-real.sh').symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    staged.write_text('#!/bin/bash\nn=0\nwhile [ -f %s ] && [ $n -lt 300 ]; do sleep .1; n=$((n+1)); done\n'
                      'exec bash %s "$@"\n' % (shlex.quote(str(stall)),
                                               shlex.quote(str(bin_dir / 'tmux-dashboard-rows-real.sh'))))
    stall.write_text('')
    os.replace(staged, rows_bin)
    started, flagged, blank = time.monotonic(), None, []
    while time.monotonic() - started < 15:
        screen = tm('capture-pane', '-p', '-t', side)
        if '修复侧栏' not in screen or 'worker-one' not in screen:
            blank.append(round(time.monotonic() - started, 1))
        if flagged is None and refreshing(side):
            flagged = time.monotonic() - started
            check('刷新中…' not in screen, 'a hung producer drew a 「刷新中…」 row')
        time.sleep(.25)
    check(not blank, 'the list went blank under a hung producer at %r s' % blank)
    check(flagged is not None, 'a hung producer never lit the refresh icon')
    lines = stall_log.read_text().splitlines() if stall_log.exists() else []
    check(len(lines) == logged + 1 and 'producer' in lines[-1] and 'restarted' in lines[-1],
          'the watchdog did not log the stall exactly once: %r' % lines[logged:])
    print('sidebar timing: ⟳ after %.1fs of a hung producer; stall log: %s' % (flagged, lines[-1]))
    stall.unlink()
    wait_for(lambda: not refreshing(side), 'the refresh icon stayed lit after the producer recovered')
    rows_bin.unlink()
    rows_bin.symlink_to(real_bin / 'tmux-dashboard-rows.sh')
    (bin_dir / 'tmux-dashboard-rows-real.sh').unlink()

    # Degenerate case (a one-repo fleet, no repos/ overlay): the async producer
    # paints exactly what the painter always has — `marker glyph tree label`,
    # one row per producer row, `▶` on the window in view.
    def painted_rows():
        want = []
        for row in row_data(current=w1):
            wid, state, glyph, label, tree = row[:5]
            badge = row[5] if len(row) > 5 else ''
            text = label if wid == 'hdr' else sidebar.row_text(
                '▶' if wid == w1 else ' ', glyph, tree, label, badge, 29, sidebar.row_num(row))
            want.append(sidebar.clip(text, 29).rstrip())
        return want
    # A working row's glyph is the spinner, which animates between the two reads:
    # compare every cell but that one.
    spin = lambda l: l[:2] + '*' + l[3:] if l[:1] in ('▶', ' ') and len(l) > 3 else l
    def same_frame():
        lines = [spin(l.rstrip()) for l in tm('capture-pane', '-p', '-t', side).splitlines()]
        want = [spin(l) for l in painted_rows()]
        # nothing below the rows (issue #1950): no `? 快捷键` row, no input line
        return lines[:len(want)] == want and not any(l.strip() for l in lines[len(want):])
    wait_for(same_frame, 'a one-repo sidebar frame differs from its rows: %r' % painted_rows())

    # The right pane was already tmux-active: clicking it keeps it so. Actual
    # typing then reaches that pane, not the sidebar.
    click(p1, row=3)
    check(not navigation(), 'clicking the worker entered a key table of the list')
    check(WORKER_FOCUS in border(p1),
          'worker click did not restore its input badge')
    check([border_text(p1), border_text(side)] == nav_text,
          'border text changed with focus: %r != %r' % ([border_text(p1), border_text(side)], nav_text))
    os.write(terminal, b'worker-input-check')
    wait_for(lambda: 'worker-input-check' in tm('capture-pane', '-p', '-t', p1),
             'typing after a worker click did not reach the worker')

    # Double-click on the worker while its sidebar is on screen is the
    # select-word gesture (issue #820), never zoom: the view stays, the window
    # does not zoom, tmux's stock copy lands in a buffer, and copy mode ends.
    for name in tm('list-buffers', '-F', '#{buffer_name}').splitlines():
        tm('delete-buffer', '-b', name)
    text_row = next(i for i, line in enumerate(tm('capture-pane', '-p', '-t', p1).splitlines())
                    if 'worker-input-check' in line)
    click(p1, row=text_row, column=2, count=2)
    wait_for(lambda: copied() and copied() in 'worker-input-check',
             'double-click on the worker did not select-word: buffer=%r' % copied())
    check(zoomed(w1) == '0', 'double-click zoomed the worker and hid its sidebar')
    check(view_on(w1) == [side] and tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
          'double-click on the worker lost the sidebar view')
    wait_for(lambda: tm('display-message', '-p', '-t', p1, '#{pane_in_mode}') == '0',
             'select-word left the worker in copy mode')
    check(not navigation(), 'double-click on the worker entered sidebar navigation')
    # Zoomed, the sidebar is off screen: the double-click stays the way back.
    tm('resize-pane', '-Z', '-t', p1)
    check(zoomed(w1) == '1', 'worker zoom broken with a sidebar present')
    click(p1, row=text_row, column=2, count=2)
    wait_for(lambda: zoomed(w1) == '0', 'double-click on a zoomed worker did not unzoom it')
    wait_for(lambda: view_on(w1) == [side], 'unzoom by double-click lost the sidebar view')
    check(tm('display-message', '-p', '-t', p1, '#{pane_in_mode}') == '0',
          'double-click on a zoomed worker entered copy mode')
    # The sidebar/worker divider is the sidebar's border, so its double-click
    # runs through navigation — and must still zoom the worker (issue #823).
    divider = int(tm('display-message', '-p', '-t', side, '#{pane_width}'))
    click(side, row=5, column=divider, count=2)
    wait_for(lambda: zoomed(w1) == '1', 'double-click on the divider did not zoom the worker')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1,
          'double-click on the divider zoomed the sidebar, not the worker')
    check(not navigation(), 'double-click on the divider left sidebar navigation on')
    tm('resize-pane', '-Z', '-t', p1)
    wait_for(lambda: view_on(w1) == [side] and
             tm('display-message', '-p', '-t', side, '#{pane_pid}') == side_pid,
             'unzoom after a divider double-click lost the sidebar view')

    # Blank space and rapid repeat clicks on the list do nothing (issue #1950:
    # they were the keyboard's way onto it): no switch, no key table, no menu.
    click(side, row=8)
    click(side, row=8, repeat=True)
    click(side, row=8, repeat=True)
    time.sleep(.5)
    check(not navigation(), 'a tap on blank list space took the keyboard')
    check(view_on(w1) == [side], 'a tap on blank space moved the list')
    os.write(terminal, b'\x1b[B\r')
    time.sleep(1)
    check(view_on(w1) == [side] and not view_on(w2), '↓ ↵ after a tap still drive the list')
    # A top-border click (tmux 3.7+ exposes it) is no way onto the list either.
    if server_version() >= (3, 7):
        click(side, row=-1)
        time.sleep(.5)
        check(not navigation(), 'clicking the top border entered a key table of the list')
    tm('resize-window', '-t', w1, '-x', '100', '-y', window_height)
    wait_for(lambda: not views(), 'narrow screen did not hide sidebar')
    check(not navigation(), 'auto-hidden sidebar retained keyboard focus')
    check('FLEET_SIDEBAR=1' in conf.read_text(), 'auto-hide changed saved preference')
    tm('resize-window', '-t', w1, '-x', '160', '-y', window_height)
    wait_for(lambda: bool(view_on(w1)), 'wide screen did not restore sidebar')
    legacy = view_on(w1)[0]
    tm('set-option', '-p', '-t', legacy, '@sidebar_version', '2')
    call()
    check(view_on(w1) != [legacy] and len(view_on(w1)) == 1,
          'sync must replace a pre-upgrade renderer once before reusing panes')
    side = view_on(w1)[0]
    wait_for(lambda: '修复侧栏' in tm('capture-pane', '-p', '-t', side), 'upgraded view not ready')
    screen = tm('capture-pane', '-p', '-t', side)
    check('Hide' not in screen and 'q hide' not in screen, 'sidebar still paints a click target for hide')
    check('new task' not in screen and 'Keyboard' not in screen and '↑↓' not in screen,
          'the footer hint rows survived: ' + repr(screen))
    check(list_only(side), 'the upgraded view draws a row that is not a session: ' + repr(screen))

    # A question opens on ONE line under the session (issue #1950 — it was the
    # list's own last row, #1620): parked on the view like the row menu parks
    # one, it is a pane of its own (`@stage_ask`) holding the keyboard; Esc
    # cancels it, the pane goes and the keyboard is back on the session.
    height = int(tm('display-message', '-p', '-t', side, '#{pane_height}'))
    def popup_open():
        return tm('show-options', '-gqv', '@popup_open') not in ('', '0')
    def park(verb):
        tm('set-option', '-p', '-t', side, '@sidebar_ask', verb, ';', 'send-keys', '-t', side, 'F12')
    conf.write_text(fleet_conf + 'FLEET_REPO=example/repo\n')
    park('new')
    try:
        wait_for(lambda: ask_pane(w1)[0], 'a parked `new` opened no question under the session')
    except AssertionError as error:
        raise AssertionError('%s\npanes: %s\nbar: %r' % (error, tm('list-panes', '-a', '-F',
            '#{pane_id} #{window_id} #{@sidebar} #{@stage_ask} #{@sidebar_worker} #{pane_start_command}'),
            painted_text()[-400:]))
    pane_q, active = ask_pane(w1)
    wait_for(lambda: '新任务›' in ask_line(w1) and '→ repo' in ask_line(w1),
             'the question line does not ask for the title and name the repo: %r' % ask_line(w1))
    check(active and not navigation(), 'the question line does not hold the keyboard')
    check(int(tm('display-message', '-p', '-t', pane_q, '#{pane_height}')) == 1 and
          tm('display-message', '-p', '-t', pane_q, '#{pane_left}') == tm('display-message', '-p', '-t', p1, '#{pane_left}'),
          'the question is not one line under the session')
    check(not popup_open() and view_on(w1) == [side] and list_only(side),
          'the question opened a popup, moved the list or drew on it')
    type_keys('标题')
    wait_for(lambda: '新任务› 标题' in ask_line(w1), 'the title did not type on the question line: %r' % ask_line(w1))
    check('标题' not in tm('capture-pane', '-p', '-t', p1), 'the title leaked into the session')
    os.write(terminal, b'\x1b')
    wait_for(lambda: not ask_pane(w1)[0], 'Esc did not close the question line')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1, 'the keyboard did not come back to the session')
    check(not popup_open(), 'the question raised @popup_open')
    conf.write_text(fleet_conf)

    # Why a session could not open is on the BAR (issue #1950: it was the input
    # line's, for 4 seconds): the per-fleet cap refuses a scratch — the reason is
    # drawn on the client's status line, nothing spawns, the list stays sessions.
    before = set(windows())
    conf.write_text(fleet_conf + 'FLEET_MAX_SESSIONS=1\n')
    del screen_out[:]
    park('scratch')
    wait_for(lambda: '✗' in painted_text() and 'capacity' in painted_text(),
             'a refused spawn did not say why on the bar: %r' % painted_text()[-300:])
    check(set(windows()) == before, 'a refused spawn created a window')
    check(list_only(side), 'the refusal was drawn on the list')
    conf.write_text(fleet_conf)
    time.sleep(1.5)   # the refused spawn's script exits after its word (one spawn at a time, #1608)

    # The list's own actions are verbs (issue #1950 — its ⌃s ⌃i ⌃t ⌃r ⌃o went
    # with the keyboard): `scratch` a scratch session NOW — the hub's ⌃s, unnamed
    # (dash-raw-session.sh --selection) — and it becomes current.
    def side_rows():
        return tm('capture-pane', '-p', '-t', side).splitlines()
    def row_line(text):
        return next((l.rstrip() for l in side_rows() if text in l), '')
    tm('select-window', '-t', w1)
    wait_for(lambda: view_on(w1) == [side], 'the view is not on the first worker before `scratch`')
    before = set(windows())
    park('scratch')
    wait_for(lambda: set(windows()) - before, '`scratch` did not spawn a scratch session')
    new = (set(windows()) - before).pop()
    wait_for(lambda: tm('show-options', '-wqv', '-t', new, '@raw') == '1',
             '`scratch` spawned something other than a scratch')
    check(tm('show-options', '-wqv', '-t', new, '@origin') == '', '`scratch` nested its scratch under the worker (must be the hub ⌃s)')
    wait_for(lambda: tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}') == new,
             'the `scratch` session did not become the current window')
    wait_for(lambda: view_on(new) == [side], 'the view did not follow to the `scratch` session')
    check(not navigation(), 'the spawn left a client in a key table of the list')
    time.sleep(1)  # the spawn's script exits after its window shows (issue #1608)
    tm('select-window', '-t', w1)
    wait_for(lambda: view_on(w1) == [side], 'the view did not come back after `scratch`')
    tm('kill-window', '-t', new)

    # The ▶ row is state · name · its issue number (issues #2305, #2545):
    # worker-one's `#1` ends the row, right-aligned; the rest of the detail
    # rides the bar — @fleet_hint_name on the list's window, `#` doubled — and
    # the old ⌃i `info` verb is gone (a stale tap changes nothing).
    wait_for(lambda: 'worker-one' in row_line('▶'), 'worker-one is not the ▶ row')
    check(row_line('▶').rstrip().endswith('#1') and '—' not in row_line('▶'),
          'the row carries more than state · name · #N: %r' % row_line('▶'))
    hint = lambda: tm('show-options', '-wqv', '-t', side, '@fleet_hint_name')
    # it leads with the issue's full title when the row carries one (#2545), else the name
    wait_for(lambda: re.match(r'[^#]+ · ##1\b', hint()), 'the bar does not carry the ▶ row\'s detail: %r' % hint())
    park('info')
    time.sleep(0.5)
    check(not re.search(r'#1\b.*#1\b', row_line('▶')) and '—' not in row_line('▶'),
          'a stale `info` tap opened a column: %r' % row_line('▶'))

    # `view`: running ⇄ landed, in place — the rows `fleet-history.sh rows` gives
    # the hub's ⌃t (stubbed: the ledger is not this test's subject). `reload`
    # re-reads it at once (the view itself re-reads a landed list only every
    # 10 s), and a second tap on a landed row restores it through
    # `fleet-history.sh resume` — the hub's ⌃o — and puts the running list back.
    hist_log, hist_rows = work / 'history.log', work / 'history.rows'
    hist_rows.write_text('hdr\x1fhdr\x1fhead\nlanded:77\x1fk\x1f✓ #77      已落地一号' + ' ' * 16 + ' cf\n')
    (bin_dir / 'fleet-history.sh').unlink()
    (bin_dir / 'fleet-history.sh').write_text(
        '#!/bin/sh\nprintf \'%%s\\n\' "$*" >> %s\n[ "$1" = rows ] && cat %s\nexit 0\n'
        % (shlex.quote(str(hist_log)), shlex.quote(str(hist_rows))))
    (bin_dir / 'fleet-history.sh').chmod(0o755)
    park('view')
    wait_for(lambda: row_line('已落地 (1)') and row_line('已落地一号'), '`view` did not show the landed list')
    check(not row_line('worker-one'), 'the running rows stayed up under the landed list')
    with hist_rows.open('a') as rows_file:
        rows_file.write('landed:78\x1fk\x1f✓ #78      第二个落地' + ' ' * 16 + ' cf\n')
    park('reload')
    wait_for(lambda: row_line('已落地 (2)') and row_line('第二个落地'), '`reload` did not re-read the landed list')
    landed_y = next(y for y, l in enumerate(side_rows()) if '已落地一号' in l)
    click(side, landed_y)
    click(side, landed_y)
    wait_for(lambda: hist_log.exists() and re.search(r'^resume .*#77$', hist_log.read_text(), re.M),
             'a second tap on a landed row did not reach fleet-history.sh resume: %r' %
             (hist_log.read_text() if hist_log.exists() else ''))
    wait_for(lambda: row_line('worker-one') and not row_line('已落地'),
             'after the restore the running list did not come back')
    # `restore` (issue #901; the row menu's last item parks `landed`): the same
    # landed list, in place — no popup (issue #1620).
    for verb in ('restore', 'landed'):
        park(verb)
        wait_for(lambda: row_line('已落地') and not row_line('worker-one'), '`%s` did not show the landed list' % verb)
        check(not popup_open(), '`%s` opened a popup' % verb)
        park('view')
        wait_for(lambda: row_line('worker-one') and not row_line('已落地'), '`view` did not come back from `%s`' % verb)
    (bin_dir / 'fleet-history.sh').unlink()
    (bin_dir / 'fleet-history.sh').symlink_to(real_bin / 'fleet-history.sh')

    # A row waiting on you is its own red `!` (issue #1950: the 要你处理 summary
    # line went); a tap on the bar's 「! N 等你」 (F10 to the list, conf/tmux-shell.conf)
    # — and the `needs` verb — land on it and switch to it, with the keyboard on
    # the session. prefix k, its key until issue #2362, does nothing now.
    was_on = tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}')
    was_state = tm('show-options', '-wqv', '-t', w2, '@claude_state')
    def on_window():
        return tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}')
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'the needs leg needs the sidebar on the first worker')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'needs')
    tm('set-option', '-w', '-t', w2, '@claude_needs', 'ask')
    wait_for(lambda: any(l[2:3] == '!' for l in side_rows()), 'the row waiting on you lost its red !')
    check(list_only(side), 'the list draws a 要你处理 summary with a row waiting on you')
    click(p1, row=3)
    wait_for(lambda: tm('display-message', '-p', '-t', w1 + '.{top-left}', '#{pane_id}') == side and
             any(l.startswith('▶') and 'worker-one' in l for l in tm('capture-pane', '-p', '-t', side).splitlines()),
             'the list on the first worker did not settle')
    # prefix, then k, as a person types them: one write is a paste burst
    # (assume-paste-time), and tmux runs no key binding inside a paste
    os.write(terminal, b'\x02')
    time.sleep(.3)
    os.write(terminal, b'k')
    time.sleep(1.5)
    check(on_window() == w1, 'prefix k (retired, issue #2362) still switched windows')
    tm('send-keys', '-t', side, 'F10')   # what a tap on 「! N 等你」 sends the list
    wait_for(lambda: bool(view_on(w2)) and on_window() == w2,
             'a tap on 「! N 等你」 (F10) did not switch to the row waiting on you')
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'the sidebar did not come back to the first worker')
    park('needs')
    wait_for(lambda: bool(view_on(w2)) and on_window() == w2,
             'the `needs` verb did not switch to the row waiting on you')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'done')
    tm('set-option', '-uw', '-t', w2, '@claude_needs')
    if was_state:
        tm('set-option', '-w', '-t', w2, '@claude_state', was_state)
    tm('select-window', '-t', was_on)
    wait_for(lambda: bool(view_on(was_on)), 'the sidebar did not come back after the needs leg')

    # The row menu (issue #898): a right-click on a row, or a tap on the
    # highlighted row (the second tap on a row the first one switched to), opens
    # a tmux display-menu of the hub's per-row actions — each the hub's own
    # script, handed the row's @id.
    def painted(*texts):
        seen = bytes(screen_out).decode('utf-8', 'replace')
        return all(t in seen for t in texts)
    def menu_open():
        return painted('改名', '置顶', '回收')
    def menu_items(wid):
        result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', wid, '--print'])
        check(result.returncode == 0, result.stderr)
        return {line.split('\t')[0]: line.split('\t')[1]
                for line in result.stdout.splitlines() if line.count('\t') == 2}
    def menu_commands(wid):
        result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', wid, '--print'])
        return {line.split('\t')[0]: line.split('\t')[2]
                for line in result.stdout.splitlines() if line.count('\t') == 2}
    def menu_shape(wid):
        # the row menu's frame (issue #1535): its title, and its letters in order
        # with `|` for a rule and `E` for the closing 「Esc 关闭」 row
        out = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', wid, '--print']).stdout
        title = next((l.split('\t', 1)[1] for l in out.splitlines() if l.startswith('title\t')), None)
        shape = ''
        for l in out.splitlines():
            if l.count('\t') != 2:
                continue
            k, name, _ = l.split('\t')
            shape += 'E' if name == '-Esc 关闭' else (k if name else '|')
        return title, shape
    def current():
        return tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}')
    tm('set-option', '-g', 'status-keys', 'emacs')
    tm('set-option', '-w', '-t', w1, '@claude_state', 'working')
    tm('set-option', '-w', '-t', w2, '@claude_state', 'needs')
    items = menu_items(w1)
    check(set('rtpavxnos') <= set(items), 'the row menu lacks an action: %r' % items)
    check(items['o'] == '恢复已收工…' and '@sidebar_ask' in menu_commands(w1)['o'] and 'landed' in menu_commands(w1)['o'],
          'the row menu\'s last item does not show the landed list in place (#901/#1620): %r' % items)
    # Every item that takes input asks on one line under the session (issues
    # #1620, #1950): no row menu item opens a popup any more.
    check(not any('dash-popup.sh' in c or 'fleet-restore-pick.sh' in c for c in menu_commands(w1).values()),
          'a row menu item still opens a popup: %r' % menu_commands(w1))
    check(items['p'].startswith('-') and items['a'].startswith('-'),
          'a row with no PR / no pending question must grey those items: %r' % items)
    check(items['s'].startswith('-') and not menu_commands(w1)['s'],
          'a row without a Claude process must disable subscription switching: %r' % items)
    check(not items['r'].startswith('-') and not items['x'].startswith('-'), 'rename/reap greyed: %r' % items)
    check(not menu_items(w2)['a'].startswith('-'), 'a needs row greyed its answer item')
    # A PR for the branch the worktree is on (the dash's prmap) enables the item.
    conf.write_text(fleet_conf + 'FLEET_REPO=example/repo\n')
    prmap = Path(command(['bash', '-c', '. "$1/fleet-lib.sh"; fleet_cache prmap fleet-test',
                          '_', str(bin_dir)]).stdout.strip())
    prmap.parent.mkdir(parents=True, exist_ok=True)
    prmap.write_text(base + '\t#42\tOPEN\t✓\tready\t\n')
    tm('set-option', '-w', '-t', w1, '@worktree', str(main))
    # --print shows names as tmux gets them: a format, where ## is a literal #.
    check(menu_items(w1)['p'] == '打开 PR ##42', 'a row with a PR did not offer it: %r' % menu_items(w1))
    tm('set-option', '-uw', '-t', w1, '@worktree')
    prmap.unlink()
    conf.write_text(fleet_conf)

    # A right-click on a row opens its menu at once (issue #1950 — `.` went with
    # the keyboard); the letter acts on that row and switches nothing.
    def right_click(pane, row=0, column=2):
        time.sleep(.6)
        x = int(tm('display-message', '-p', '-t', pane, '#{pane_left}')) + column + 1
        y = int(tm('display-message', '-p', '-t', pane, '#{pane_top}')) + row + 1
        os.write(terminal, ('\x1b[<2;%d;%dM\x1b[<2;%d;%dm' % (x, y, x, y)).encode())
    w1_row = lambda: next(i for i, line in enumerate(tm('capture-pane', '-p', '-t', side).splitlines())
                          if 'worker-one' in line)
    tm('select-window', '-t', w1)
    wait_for(lambda: view_on(w1) == [side], 'the view is not on the first worker before the right-click leg')
    for pin in ('1', ''):
        del screen_out[:]
        right_click(side, w1_row())
        wait_for(menu_open, 'a right-click on a row did not open its menu')
        os.write(terminal, b't')
        wait_for(lambda: tm('show-options', '-wqv', '-t', w1, '@pin') == pin, 'the menu\'s pin did not toggle the pin')
        check(current() == w1, 'pinning from the menu switched windows')
        if pin:
            check(menu_items(w1)['t'] == '取消置顶', 'a pinned row does not offer unpin')
        # the next tap reads the row off a frame that shows the pin as it is now
        wait_for(lambda: ('置顶' in tm('capture-pane', '-p', '-t', side)) == bool(pin),
                 'the list did not repaint the pin')
    # Rename: the question line under the session, pre-filled; Enter hands the
    # name to dash-rename.sh --wid as argv — quotes, $, # and ; survive. The
    # line edits like Claude's prompt (issue #1097).
    odd = "名'$HOME\"#;x"
    del screen_out[:]
    right_click(side, w1_row())
    wait_for(menu_open, 'the menu did not open for rename')
    os.write(terminal, b'r')
    wait_for(lambda: '改名› worker-one' in ask_line(w1),
             'rename did not pre-fill the question line: %r' % ask_line(w1))
    check(ask_pane(w1)[1] and not navigation(), 'the rename line does not hold the keyboard')
    os.write(terminal, b'\x1b[DX')
    wait_for(lambda: '改名› worker-onXe' in ask_line(w1), '← did not move the rename cursor: %r' % ask_line(w1))
    os.write(terminal, b'\x1bbY')
    wait_for(lambda: '改名› worker-YonXe' in ask_line(w1), '⌥← did not move the rename cursor a word: %r' % ask_line(w1))
    os.write(terminal, b'\x15')  # C-u: clear the pre-filled current name
    wait_for(lambda: 'worker' not in ask_line(w1), '⌃u did not clear the rename line')
    type_keys(odd)
    wait_for(lambda: odd in ask_line(w1), 'the odd name did not type: %r' % ask_line(w1))
    if os.environ.get('FLEET_SIDEBAR_EVIDENCE'):
        Path(os.environ['FLEET_SIDEBAR_EVIDENCE'], 'rename.txt').write_text(
            tm('capture-pane', '-p', '-t', side) + '\n---\n' + ask_line(w1) + '\n')
    os.write(terminal, b'\r')
    # tmux <=3.4 vis-escapes a window name, and again in format output (`$`
    # reads back backslashed; the hub's own rename included). `odd` has no
    # backslash, so dropping them compares the name itself — $HOME unexpanded.
    renamed = lambda: tm('display-message', '-p', '-t', w1, '#{window_name}')
    wait_for(lambda: renamed() == odd or (server_version() < (3, 5) and renamed().replace('\\', '') == odd),
             'the menu rename did not apply')
    check(current() == w1 and tm('show-options', '-pqv', '-t', side, '@sidebar_rename') == ''
          and tm('show-options', '-pqv', '-t', side, '@sidebar_ask') == '',
          'rename switched windows or left its parked id behind')
    check(not popup_open(), 'the rename raised @popup_open (it must never be a popup, #1620)')
    wait_for(lambda: not ask_pane(w1)[0], 'the rename line did not close after ↵')
    check(tm('display-message', '-p', '-t', w1, '#{pane_id}') == p1, 'the keyboard did not come back to the session after rename')
    check(list_only(side), 'the rename left a line on the list')
    tm('rename-window', '-t', w1, 'worker-one')


    # Touch: a tap on another row only switches (no menu); a second tap on that
    # row, now highlighted, opens its menu and switches nothing.
    wait_for(lambda: '修复侧栏' in tm('capture-pane', '-p', '-t', side), 'rows not painted for the tap test')
    row2 = next(i for i, line in enumerate(tm('capture-pane', '-p', '-t', side).splitlines())
                if '修复侧栏' in line)
    del screen_out[:]
    click(side, row=row2)
    wait_for(lambda: current() == w2 and view_on(w2) == [side], 'a tap on a row did not switch to it')
    time.sleep(.8)
    check(not menu_open(), 'a single tap on another row opened the menu')
    click(side, row=row2)
    wait_for(menu_open, 'the second tap on the highlighted row did not open its menu')
    check(current() == w2, 'the second tap switched windows')
    check(painted('回答它的提问'), 'the tapped row\'s menu is not that row\'s')
    os.write(terminal, b'\x1b')
    time.sleep(.8)
    tm('select-window', '-t', w1)
    wait_for(lambda: view_on(w1) == [side], 'the view did not return to the first worker')

    # Reap: confirm-before first (n keeps the window), then dash-reap.sh --yes;
    # a refusal is toasted from its result token, never silent (#869).
    w3 = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'reap-me', 'sleep 600')
    tm('set-option', '-w', '-t', w3, '@raw', '1')
    tm('set-option', '-w', '-t', w3, '@claude_state', 'done')
    for answer in (b'n', b'y'):
        del screen_out[:]
        # display-menu holds its caller until the menu closes — the view never
        # waits on it (open_menu), and neither may this test.
        opener = subprocess.Popen(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', w3],
                                  env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(menu_open, 'the reap test menu did not open')
        os.write(terminal, b'x')
        wait_for(lambda: painted('回收「reap-me」'), 'reap did not ask for confirmation')
        os.write(terminal, answer)
        opener.wait(timeout=10)
        if answer == b'n':
            time.sleep(1)
            check(w3 in windows(), 'declining the reap confirm still reaped the window')
    wait_for(lambda: w3 not in windows(), 'a confirmed menu reap did not close the window')
    wait_for(lambda: painted('fleet: 已回收'), 'a confirmed reap did not toast its outcome')
    check(current() == w1 and w1 in windows(), 'the reap touched the window in view')
    del screen_out[:]
    call('reap', hub)
    wait_for(lambda: painted('未回收'), 'a refused reap was silent')
    check(hub in windows(), 'the menu reap disposed of the hub')

    # A no-repo session in $HOME (issue #996) carries `@norepo 1` and none of
    # @issue / @raw / @worktree — it still gets the view, and the toggle (prefix e's
    # verb until issue #1714 took the key off the node) hides and brings it back. A plain window with none of the four marks: none.
    before = set(windows())
    # --origin hub: this harness has $TMUX but no pane, which the spawn refuses
    # unstated (issue #1355).
    spawned = command(['bash', str(bin_dir / 'dash-raw-session.sh'), '--no-repo', '--origin', 'hub',
                       '--name', 'home-work', 'fleet-test'], stdin=subprocess.DEVNULL)
    check(spawned.returncode == 0, 'the no-repo spawn failed: ' + spawned.stderr)
    wait_for(lambda: set(windows()) - before, 'dash-raw-session.sh --no-repo made no window')
    home = (set(windows()) - before).pop()
    check(tm('show-options', '-wqv', '-t', home, '@norepo') == '1' and
          tm('display-message', '-p', '-t', home, '#{@issue}#{@raw}#{@worktree}') == '',
          'the no-repo fixture carries a repo mark')
    tm('select-window', '-t', home)
    snap = os.environ.get('FLEET_SIDEBAR_SNAPSHOT')  # evidence only: the window as seen
    if snap:
        time.sleep(2)
        Path(snap).write_text(''.join(
            '[%s]\n%s\n' % (pane, tm('capture-pane', '-p', '-t', pane.split()[0]))
            for pane in tm('list-panes', '-t', home, '-F',
                           '#{pane_id} left=#{pane_left} width=#{pane_width} sidebar=#{@sidebar}').splitlines()))
    wait_for(lambda: view_on(home) == [side], 'a no-repo ($HOME) session got no task bar')
    call('toggle')
    wait_for(lambda: not views(), 'toggle did not hide the task bar in a no-repo session')
    call('toggle')
    wait_for(lambda: bool(view_on(home)),
             'toggle did not bring the task bar back in a no-repo session')
    side = view_on(home)[0]
    plain = tm('new-window', '-d', '-P', '-F', '#{window_id}', '-n', 'plain', 'sleep 600')
    tm('select-window', '-t', plain)
    call()
    wait_for(lambda: not view_on(plain), 'a window with no @issue/@raw/@worktree/@norepo got a task bar')
    tm('kill-window', '-t', plain)
    tm('kill-window', '-t', home)
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'the view did not return after the no-repo leg')
    side = view_on(w1)[0]

    # Hide is the toggle verb — never a click and never a letter (no key is bound
    # to it since issue #1714: the client's list is not optional).
    call('toggle')
    wait_for(lambda: not views(), 'toggle left a view')
    check('FLEET_SIDEBAR=0' in conf.read_text(), 'collapse was not saved')
    # A hook sync that loaded the conf BEFORE the hide (enabled=1 on its argv)
    # and got the lock AFTER it must not recreate the view (issue #826).
    stale = command(['python3', str(bin_dir / 'fleet-sidebar.py'), 'sync', 'fleet-test',
                     str(conf) + '.sidebar.lock', '1', '30', '', str(conf)])
    check(stale.returncode == 0, stale.stderr)
    check(not views(), 'a sync holding a pre-hide conf read recreated the sidebar')
    tm('select-window', '-t', w2)
    call()
    check(not views(), 'switching reopened a manually collapsed sidebar')
    call('toggle')
    wait_for(lambda: bool(view_on(w2)), 'toggle did not reopen sidebar')
    tm('resize-pane', '-Z', '-t', p2)
    check(tm('display-message', '-p', '-t', w2, '#{window_zoomed_flag}') == '1', 'worker zoom broken')
    tm('resize-pane', '-Z', '-t', p2)

    # Enabling while another pane is zoomed must wait, then appear on unzoom.
    call('hide')
    extra = tm('split-window', '-d', '-h', '-t', p2, '-P', '-F', '#{pane_id}', 'sleep 600')
    # Without a sidebar the double-click still zooms (the hub and dash rely on it).
    check(tm('show-options', '-wqv', '-t', w2, '@sidebar_worker') == '',
          'hidden sidebar left its worker metadata on the window')
    click(p2, row=3, count=2)
    wait_for(lambda: zoomed(w2) == '1', 'double-click without a sidebar did not zoom the worker')
    call('toggle')
    check(not views(), 'enabling sidebar interrupted a zoomed worker')
    tm('resize-pane', '-Z', '-t', p2)
    wait_for(lambda: bool(view_on(w2)), 'unzoom did not restore the enabled sidebar')
    tm('kill-pane', '-t', extra)

    # The width is held across a window scale (issue #1521). A 210-column window
    # (what a since-gone client left behind) takes the 160-column client's size
    # the moment it is shown — `window-size latest`; resize-window drives the same
    # layout_resize — and every pane scales with it. The view snaps back to the
    # manual width in the same window, without a move; a drag (the pane moved
    # while the window did not) is still the operator's and is kept from then on.
    tm('set-option', '-t', 'fleet-test:', '@sidebar_width_manual', '37')
    side = view_on(w2)[0]
    def side_width():
        return tm('display-message', '-p', '-t', side, '#{pane_width}')
    wait_for(lambda: side_width() == '37', 'a manual width set on the session was not applied to the open view')
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'the view did not follow to the first worker')
    tm('resize-window', '-t', w2, '-x', '210', '-y', window_height)
    tm('select-window', '-t', w2)
    wait_for(lambda: view_on(w2) == [side], 'the view did not follow back to the 210-column worker')
    wait_for(lambda: side_width() == '37', 'the view did not join the 210-column window at the manual width')
    tm('resize-window', '-t', w2, '-x', '160', '-y', window_height)
    wait_for(lambda: side_width() == '37' and
             tm('display-message', '-p', '-t', w2, '#{window_width}') == '160',
             'the view stayed where the 210 → 160 scale left it (issue #1521)')
    check(view_on(w2) == [side], 'the width came back by a move, not a fit')
    check(tm('show-options', '-qv', '-t', 'fleet-test:', '@sidebar_width_manual') == '37',
          'a window scale was recorded as a drag')
    tm('resize-pane', '-t', side, '-x', '40')   # the operator drags the divider
    wait_for(lambda: tm('show-options', '-qv', '-t', 'fleet-test:', '@sidebar_width_manual') == '40',
             'a drag in the same window at the same width was not kept as the manual width')
    time.sleep(1.5)
    check(side_width() == '40', 'the held width fought the drag: %s' % side_width())
    tm('set-option', '-u', '-t', 'fleet-test:', '@sidebar_width_manual')
    wait_for(lambda: side_width() != '40', 'clearing the manual width did not return the view to auto_width')
    check(30 <= int(side_width()) <= 40, 'auto_width left its 30..window/4 band: %s' % side_width())

    # F9 zooms the SESSION pane on the right — the client's key (issue #1714; the
    # node's three-state F9 went with its list): first press zooms the worker, the
    # second unzooms and the view is back, the keyboard never moves to the list.
    check(not navigation(), 'fixture should start with the worker holding input')
    os.write(terminal, b'\x1b[20~')  # F9
    wait_for(lambda: zoomed(w2) == '1', 'F9 did not zoom the session')
    check(tm('display-message', '-p', '-t', w2, '#{pane_id}') == p2, 'F9 zoomed the list, not the session')
    os.write(terminal, b'\x1b[20~')  # F9 again
    wait_for(lambda: zoomed(w2) == '0', 'F9 again did not unzoom')
    wait_for(lambda: bool(view_on(w2)), 'the list did not come back after the F9 unzoom')
    check(not navigation(), 'F9 put the keyboard on the list')
    foreign = tm('new-session', '-d', '-s', 'adhoc', '-P', '-F', '#{window_id}', 'sleep 600')
    tm('set-option', '-w', '-t', foreign, '@issue', '99')
    check(foreign not in [r[0] for r in row_data()], 'another session leaked into sidebar')
    result = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'toggle', 'adhoc'])
    check(not (work / 'conf/fleets/adhoc/conf').exists(), 'ad-hoc session was turned into a fleet')
    adhoc_conf = work / 'conf/fleets/adhoc/conf'
    adhoc_conf.parent.mkdir(parents=True)
    adhoc_conf.write_text('FLEET_SIDEBAR=1\n')
    command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'toggle', 'adhoc'])
    check(adhoc_conf.read_text() == 'FLEET_SIDEBAR=1\n', 'a matching conf on the wrong socket was treated as a fleet')

    # The list from the hub (issue #1480, EPIC #1479 C1): FLEET_SIDEBAR_SOURCE=hub
    # takes the row SET from the hub's cache. A row of THIS machine the cache
    # names is still its own window — its `@` id, so Enter is the local
    # select-window path, unchanged — a local window the cache does not name is
    # not a row, and a row on another machine is a `wid:` whose Enter goes
    # through fleet-remote-view.sh open.
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'the hub-source leg needs a sidebar on the first worker')
    side = view_on(w1)[0]
    F = '11111111-2222-3333-4444-555555555555'
    cache = work / '.claude-dash/global'
    cache.mkdir(parents=True, exist_ok=True)
    now = str(int(time.time()))
    US = '\x1f'
    (cache / 'remote_fleet-test').write_text(
        '#ts' + US + now + '\n#me' + US + 'm5\n#node' + US + 'm4' + US + 'online' + US + '1' + US + now + '\n' +
        US.join(('wid:' + F + '/issue-1423', 'm4', 'online', '1423', 'acme/app', 'working', 'claude',
                 '侧边栏', '', '', '0', '')) + '\n' +
        US.join(('wid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/issue-1', 'm5', 'online', '1', '', 'working',
                 'claude', 'worker-one', '', '', '1', w1)) + '\n')
    saved_conf = conf.read_text()
    conf.write_text(saved_conf + 'CCQUOTA_FLEET=1\nFLEET_SIDEBAR_SOURCE=hub\n')
    ids = [r[0] for r in row_data(current=w1)]
    check(w1 in ids and 'wid:' + F + '/issue-1423' in ids and w2 not in ids,
          "hub source: the row set must be the cache's — a local row by its @ id, a remote one by wid:, "
          'an unlisted window gone: ' + repr(ids))
    check(not any(i.startswith('wid:') and i.endswith('/issue-1') for i in ids),
          'hub source: a local row must never be a wid: row')
    # Enter on the local row: the local path — select-window to that window.
    tm('select-window', '-t', w2)
    wait_for(lambda: bool(view_on(w2)), 'the view did not follow the second worker')
    jump = work / 'jump.py'
    jump.write_text('import importlib.util, sys\n'
                    'spec = importlib.util.spec_from_file_location("sb", sys.argv[1])\n'
                    'sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)\n'
                    'sb.jump(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])\n')
    lock = str(conf) + '.sidebar.lock'
    result = command(['python3', str(jump), str(bin_dir / 'fleet-sidebar.py'), 'fleet-test', w1,
                      view_on(w2)[0], lock])
    check(result.returncode == 0, 'jump on a hub-sourced local row failed: ' + result.stderr)
    wait_for(lambda: tm('display-message', '-p', '-t', 'fleet-test:', '#{window_id}') == w1,
             'Enter on a hub-sourced local row did not select its window')
    wait_for(lambda: bool(view_on(w1)), 'the view did not move with the hub-sourced local jump')
    # Enter on the other machine's row: fleet-remote-view.sh open, on that worker_id.
    link = bin_dir / 'fleet-remote-view.sh'
    opened = work / 'opened'
    link.unlink()
    link.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> ' + shlex.quote(str(opened)) +
                    '\nprintf "%s\\n" ' + shlex.quote(w2) + '\n')
    link.chmod(0o755)
    try:
        result = command(['python3', str(jump), str(bin_dir / 'fleet-sidebar.py'), 'fleet-test',
                          'wid:' + F + '/issue-1423', view_on(w1)[0], lock])
        check(result.returncode == 0, 'jump on a remote row failed: ' + result.stderr)
        check(opened.exists() and opened.read_text().strip() == 'open wid:' + F + '/issue-1423',
              'Enter on a remote row must go through fleet-remote-view.sh open: ' +
              (opened.read_text() if opened.exists() else '<not called>'))
    finally:
        link.unlink()
        link.symlink_to(real_bin / 'fleet-remote-view.sh')

    # The remote row's menu (issue #1487, EPIC #1479 C8): message / answer / stop /
    # resume / reap are hub WRITES — every item runs fleet-sidebar-remote.sh, whose
    # one way out is fleet-hub-write.sh (stubbed here through FLEET_HUB_WRITE_CMD,
    # which records the tool + its JSON); the local row's menu names neither
    # script. The answer item is greyed unless the row needs its person (col 10 =
    # ask / perm, or state needs). Both menus list «new task on m4…» for the one
    # online machine in the cache; without the cache (the hub off) neither does.
    remote_wid = 'wid:' + F + '/issue-1423'
    remote_items = menu_items(remote_wid)
    remote_cmds = menu_commands(remote_wid)
    check({'e', 'm', 'a', 'r', 's', 'q', 'c', 'l', 'x', 'n', '1', 'o', 'g'} <= set(remote_items),
          'the remote row menu lacks an action: %r' % remote_items)
    # s = 换到可用订阅 (issue #2102): the shell's way to move a walled row — the
    # guide included — onto a subscription with headroom, a hub write like stop
    for k in 'sqcx':
        check('fleet-sidebar-remote.sh' in remote_cmds[k], 'remote %s does not go through fleet-sidebar-remote.sh: %r' % (k, remote_cmds[k]))
    # r = 改名… (issue #2358): a remote row renames too — asked on the line under
    # the session like a local row's (parked `rename wid:…`, never a popup), then
    # a hub write; greyed only when no view is up to ask on
    check(not remote_items['r'].startswith('-') and '@sidebar_ask' in remote_cmds['r']
          and 'rename ' + remote_wid in remote_cmds['r'] and 'dash-popup.sh' not in remote_cmds['r'],
          'remote r does not ask the new name on the question line: %r %r' % (remote_items.get('r'), remote_cmds.get('r')))
    # l = 改回收方式… (issue #2368): the local row's second menu of the five
    # policies, drawn for the remote row — each pick a hub write (reappol)
    check('fleet-reap-policy.sh' in remote_cmds['l'] and ' menu ' in remote_cmds['l']
          and remote_wid in remote_cmds['l'] and not remote_items['l'].startswith('-'),
          'remote l does not open the reap-policy menu for the row: %r %r' % (remote_items.get('l'), remote_cmds.get('l')))
    pol_menu = command(['bash', str(bin_dir / 'fleet-reap-policy.sh'), 'menu', 'fleet-test', remote_wid, '', '--print']).stdout
    pol_rows = [l.split('\t') for l in pol_menu.splitlines() if l.count('\t') == 2]
    check(len(pol_rows) == 5 and all('fleet-sidebar-remote.sh' in c and 'reappol' in c and remote_wid in c for _, _, c in pol_rows)
          and 'FLEET_SIDEBAR_TEXT=done:2h' in pol_rows[1][2] and 'command-prompt' in pol_rows[3][2],
          'the remote reap-policy menu does not send worker_reap_policy picks: %r' % pol_menu)
    # message asks for its text on the line under the session (issues #1620,
    # #1950), not in a popup — and parks it without moving the keyboard to the list
    check('@sidebar_ask' in remote_cmds['m'] and 'message' in remote_cmds['m'] and 'dash-popup.sh' not in remote_cmds['m']
          and 'switch-client' not in remote_cmds['m'],
          'remote m does not ask on the question line: %r' % remote_cmds['m'])
    check(remote_items['a'].startswith('-'), 'a remote row that needs nothing greyed nothing: %r' % remote_items['a'])
    check('confirm-before' in remote_cmds['x'] and 'm4' in remote_cmds['x'], 'the remote reap does not confirm first, naming the machine: %r' % remote_cmds['x'])
    check(remote_items['1'] == '新建到 m4…' and '@sidebar_ask' in remote_cmds['1'] and 'new m4' in remote_cmds['1'],
          'the remote menu does not offer «new task on m4» with --node=m4: %r %r' % (remote_items.get('1'), remote_cmds.get('1')))
    t1, _ = menu_shape(w1)
    check(t1 == tm('display-message', '-p', '-t', w1, '#{window_name}') + ' · m5',
          'with the hub on the local menu title does not name this machine: %r' % t1)
    _, rshape = menu_shape(remote_wid)
    check(rshape == 'e|ma|rsqclx|n1og|E',
          'the remote row menu is not grouped 进入/消息/控制/其它 + Esc: %r' % rshape)
    # In the SHELL (issue #1518) the row-less group is gone — new task, new on
    # m4, restore, add repo run scripts its computer does not have — and the
    # frame closes cleanly (no rule left dangling). Unset, the shape above is
    # the golden: the machine's menu is byte for byte what it was.
    sh_out = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', remote_wid, '--print'],
                            env=dict(env, FLEET_SHELL='1'), text=True, capture_output=True, timeout=15).stdout
    sh_shape = ''.join('E' if l.split('\t')[1] == '-Esc 关闭' else (l.split('\t')[0] if l.split('\t')[1] else '|')
                       for l in sh_out.splitlines() if l.count('\t') == 2 and not l.startswith('title\t'))
    # …and its own group instead: 我的客户端 (issue #1932), d
    check(sh_shape == 'e|ma|rsqclx|odz|E', 'the shell remote menu: not the row-less group gone + 已落地 · 我的客户端 · 退出 fleet (#1952; 详情列 left with #2305; z #2349; r #2358; l #2368): %r' % sh_shape)
    check(not any(s in sh_out for s in ('dash-issue-new.sh', 'fleet-restore-pick.sh', 'dash-repo-add.sh')),
          'the shell remote menu names a machine-only script: %r' % sh_out)
    check(sh_out.split('\n', 1)[0] == 'title\t' + menu_shape(remote_wid)[0],
          'the shell remote menu title differs: %r' % sh_out.split('\n', 1)[0])
    sh_keys = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-menu.sh'), '--keys'],
                             env=dict(env, FLEET_SHELL='1'), text=True, capture_output=True, timeout=15).stdout
    all_keys = command(['bash', str(bin_dir / 'fleet-sidebar-menu.sh'), '--keys']).stdout
    check({l.split('\t')[0] for l in all_keys.splitlines()} - {l.split('\t')[0] for l in sh_keys.splitlines()} == {'n', '1-9', 'g'},
          'the shell `?` sheet does not drop exactly the row-less items (已落地 o stays, #1952): %r' % sh_keys)
    local_items = menu_items(w1)
    local_cmds = menu_commands(w1)
    check(local_items.get('1') == '新建到 m4…' and 'new m4' in local_cmds['1'],
          'the local menu does not offer «new task on m4» while the hub is on: %r' % local_items.get('1'))
    check(not any('fleet-sidebar-remote.sh' in c or 'fleet-hub-write.sh' in c for c in local_cmds.values()),
          'a local row item goes through the hub write client: %r' % local_cmds)
    # a remote row that is asking offers the answer item
    text = (cache / 'remote_fleet-test').read_text()
    (cache / 'remote_fleet-test').write_text(text.replace(
        US.join(('wid:' + F + '/issue-1423', 'm4', 'online', '1423', 'acme/app', 'working', 'claude', '侧边栏', '', '', '0', '')),
        US.join(('wid:' + F + '/issue-1423', 'm4', 'online', '1423', 'acme/app', 'needs', 'claude', '侧边栏', '', 'perm', '0', ''))))
    asking = menu_items(remote_wid)
    check(not asking['a'].startswith('-') and 'answer ' + remote_wid + ' perm' in menu_commands(remote_wid)['a'],
          'a remote row waiting on a permission prompt did not offer the answer item: %r' % asking['a'])
    # Run the printed stop / reap / answer commands' scripts with the write client
    # stubbed: each records ONE write with the row's worker_id; the answer popup
    # body takes its decision from the keyboard (here: y → yes).
    writes = work / 'hub-writes'
    stub = ('printf "%s\\t%s\\n" "$1" "$2" >> ' + shlex.quote(str(writes)) +
            '; printf \'{"operation_id":"00000000-0000-4000-8000-000000000001","status":"succeeded","result":{"how":"stopped:exit"}}\\n\'')
    env_w = dict(env, FLEET_HUB_WRITE_CMD=stub, FLEET_SESSION='fleet-test')
    for action in ('stop', 'switch', 'reap'):
        r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), action, 'fleet-test', remote_wid],
                           env=env_w, text=True, capture_output=True, timeout=30)
        check(r.returncode == 0, 'fleet-sidebar-remote.sh %s failed: %s' % (action, r.stderr))
    r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'answer', 'fleet-test', remote_wid],
                       env=env_w, text=True, input='y', capture_output=True, timeout=30)
    check(r.returncode == 0 and ('已完成' in r.stderr), 'the answer popup did not report the outcome: %s' % r.stderr)
    rows = [l.split('\t') for l in writes.read_text().splitlines()] if writes.exists() else []
    check([r[0] for r in rows] == ['worker_stop', 'worker_switch', 'worker_reap', 'worker_answer'], 'hub writes = %r' % rows)
    for tool, js in rows:
        import json as _json
        payload = _json.loads(js)
        check(payload.get('worker_id') == F + '/issue-1423' and payload.get('idempotency_key'),
              '%s was sent without the worker_id / an idempotency key: %r' % (tool, payload))
    check(_json.loads(rows[3][1]).get('answer') == 'yes', 'y did not become answer=yes: %r' % rows[3])
    # a local row never writes to the hub, whatever the stub says
    r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'stop', 'fleet-test', w1],
                       env=env_w, text=True, capture_output=True, timeout=30)
    check(r.returncode == 0 and len(writes.read_text().splitlines()) == 4, 'a local @ id reached the hub write client')
    # The sidebar's input line hands the text over in FLEET_SIDEBAR_TEXT (issue
    # #1620): no terminal is read, nothing waits on a key, the write carries it.
    r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'message', 'fleet-test', remote_wid],
                       env=dict(env_w, FLEET_SIDEBAR_TEXT='你好 $HOME'), text=True, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=30)
    last = writes.read_text().splitlines()[-1].split('\t')
    check(r.returncode == 0 and last[0] == 'worker_message' and _json.loads(last[1]).get('text') == '你好 $HOME',
          'the line-asked message did not go out verbatim: %r %s' % (last, r.stderr))
    check('按任意键' not in r.stderr and 'press any' not in r.stderr, 'the line-asked message waited on a key')
    # 改名 (issue #2358): the new name from the line goes out as worker_rename's
    # `name`, verbatim; the old name unchanged (or blank) sends nothing
    r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'rename', 'fleet-test', remote_wid],
                       env=dict(env_w, FLEET_SIDEBAR_TEXT="登录页 'a' $HOME"), text=True, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=30)
    last = writes.read_text().splitlines()[-1].split('\t')
    check(r.returncode == 0 and last[0] == 'worker_rename' and _json.loads(last[1]).get('name') == "登录页 'a' $HOME"
          and _json.loads(last[1]).get('worker_id') == F + '/issue-1423',
          'the line-asked rename did not go out as worker_rename: %r %s' % (last, r.stderr))
    n_now = len(writes.read_text().splitlines())
    for same in ('侧边栏', '  '):
        subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'rename', 'fleet-test', remote_wid],
                       env=dict(env_w, FLEET_SIDEBAR_TEXT=same), stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    check(len(writes.read_text().splitlines()) == n_now, 'an unchanged / blank rename reached the hub')
    # the view's line starts on the row's cached name and hands ↵ to the hub write
    os.environ['FLEET_STATUS_G'] = str(cache)
    try:
        prefill = sidebar.remote_name('fleet-test', remote_wid)
    finally:
        del os.environ['FLEET_STATUS_G']
    check(prefill == '侧边栏', 'the rename line does not start on the remote row name: %r' % prefill)
    # 改回收方式 (issue #2368): the pick goes out as worker_reap_policy's `policy`,
    # canonical — an `at:HH:MM` resolved on this clock; a typo sends nothing
    r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'reappol', 'fleet-test', remote_wid],
                       env=dict(env_w, FLEET_SIDEBAR_TEXT='done'), text=True, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=30)
    last = writes.read_text().splitlines()[-1].split('\t')
    check(r.returncode == 0 and last[0] == 'worker_reap_policy' and _json.loads(last[1]).get('policy') == 'done:2h'
          and _json.loads(last[1]).get('worker_id') == F + '/issue-1423',
          'the picked reap policy did not go out as worker_reap_policy: %r %s' % (last, r.stderr))
    subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'reappol', 'fleet-test', remote_wid],
                   env=dict(env_w, FLEET_SIDEBAR_TEXT='at:18:00'), stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    last = writes.read_text().splitlines()[-1].split('\t')
    check(last[0] == 'worker_reap_policy' and re.fullmatch(r'at:\d{4}-\d\d-\d\dT\d\d:\d\d:00Z', _json.loads(last[1]).get('policy', '')),
          'an at:HH:MM was not resolved before it went out: %r' % last)
    n_now = len(writes.read_text().splitlines())
    for bad in ('never', 'done:0', ''):
        subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'reappol', 'fleet-test', remote_wid],
                       env=dict(env_w, FLEET_SIDEBAR_TEXT=bad), stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    check(len(writes.read_text().splitlines()) == n_now, 'a reap policy that is not one reached the hub')
    # 入口失联 (issue #1483, EPIC #1479 C4): global/hub_ok older than
    # FLEET_HUB_SESSIONS_STALE — the one word the rows and the bar read too — and
    # no action is sent: the popups say 入口失联 on stderr before asking anything,
    # the detached ones toast it (tmux's display-message, not asserted), the menu
    # title carries it, «新建到 m4…» is greyed with the reason, the actions stay
    # listed. A fresh hub_ok brings everything back — nothing restarted.
    (cache / 'hub_ok').write_text('%d\n' % (int(time.time()) - 300))
    n_writes = len(writes.read_text().splitlines())
    r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'message', 'fleet-test', remote_wid],
                       env=env_w, text=True, input='hello\n', capture_output=True, timeout=30)
    check(r.returncode == 0 and '入口失联 5m，稍后再试' in r.stderr and '发给' in r.stderr,
          'the message popup did not refuse with 入口失联 while the hub is silent: %s' % r.stderr)
    for action in ('stop', 'reap', 'answer', 'rename', 'reappol'):
        r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), action, 'fleet-test', remote_wid],
                           env=env_w if action not in ('rename', 'reappol') else dict(env_w, FLEET_SIDEBAR_TEXT='keep'),
                           text=True, input='y', capture_output=True, timeout=30)
        check(r.returncode == 0, 'fleet-sidebar-remote.sh %s while the hub is silent failed: %s' % (action, r.stderr))
    check(len(writes.read_text().splitlines()) == n_writes, 'a hub write went out while the hub is silent: %r' % writes.read_text())
    printed = command(['bash', str(bin_dir / 'fleet-sidebar.sh'), 'menu', 'fleet-test', remote_wid, '--print']).stdout
    title = next((l.split('\t', 1)[1] for l in printed.splitlines() if l.startswith('title\t')), '')
    # 「名称 · 机器 · 状态」 (issue #1535): the row still waits on a permission
    check(title == '侧边栏 · m4 · 等授权 · 入口失联 5m', 'the remote menu title does not say the hub is silent: %r' % title)
    lost_items, lost_cmds = menu_items(remote_wid), menu_commands(remote_wid)
    check(lost_items.get('1') == '-新建到 m4… · 入口失联 5m' and lost_cmds.get('1') == '',
          '«new task on m4» is not greyed with the reason while the hub is silent: %r %r' % (lost_items.get('1'), lost_cmds.get('1')))
    check({'m', 'a', 'r', 'q', 'c', 'x'} <= set(lost_items) and all('fleet-sidebar-remote.sh' in lost_cmds[k] for k in 'qcx')
          and all('@sidebar_ask' in lost_cmds[k] for k in 'mar'),
          'the remote row actions left the menu while the hub is silent: %r' % lost_items)
    check(menu_items(w1).get('1') == '-新建到 m4… · 入口失联 5m', 'the local menu still offers «new task on m4» while the hub is silent: %r' % menu_items(w1).get('1'))
    (cache / 'hub_ok').write_text('%d\n' % int(time.time()))
    check(menu_items(remote_wid).get('1') == '新建到 m4…', '«new task on m4» did not come back with a fresh hub_ok: %r' % menu_items(remote_wid).get('1'))
    r = subprocess.run(['bash', str(bin_dir / 'fleet-sidebar-remote.sh'), 'stop', 'fleet-test', remote_wid],
                       env=env_w, text=True, capture_output=True, timeout=30)
    check(r.returncode == 0 and len(writes.read_text().splitlines()) == n_writes + 1, 'a write did not go out once hub_ok is fresh again: %s' % r.stderr)
    (cache / 'hub_ok').unlink()
    conf.write_text(saved_conf)
    (cache / 'remote_fleet-test').unlink()
    # Degenerate (CLAUDE.md): with no cache the menus are the one-machine menus —
    # no «new task on …» item anywhere, no remote script named.
    plain = menu_items(w1)
    check('1' not in plain and not any('fleet-sidebar-remote.sh' in c for c in menu_commands(w1).values()),
          'the one-machine menu changed without the hub: %r' % plain)
    # One frame (issue #1535): 进入 / 消息 / 控制 / 其它, a rule between, Esc last;
    # with the hub off the title is the row's name alone — no machine to name.
    t1, shape1 = menu_shape(w1)
    check(shape1 == 'p|a|rtsklx|vnog|E', 'the local row menu is not grouped 进入/消息/控制/其它 + Esc: %r' % shape1)
    check(t1 == tm('display-message', '-p', '-t', w1, '#{window_name}'), 'the hub-off menu title is not the bare row name: %r' % t1)
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'the view did not return after the hub-source leg')
    check(w2 in [r[0] for r in row_data()], 'the default source did not come back after the hub-source leg')

    # Drive the real stuck_check function with a deterministic clock and real
    # pane captures. Sidebar repaints keep window_activity fresh; only changes
    # to the worker's own screen may reset the stale-worker timer.
    tm('select-window', '-t', w1)
    wait_for(lambda: bool(view_on(w1)), 'activity fixture needs a sidebar')
    spin_bin = work / 'spin-bin'
    spin_bin.mkdir()
    (spin_bin / 'classify-sessions.sh').write_text('#!/bin/sh\nexit 0\n')
    (spin_bin / 'classify-sessions.sh').chmod(0o755)
    source = (bin_dir / 'tmux-spinner.sh').read_text()
    # stuck_check scans through the spinner's inline fleet_lw copy (issue #1489),
    # defined above the slice: bring _lw_fmt / _lw_filter along. TMUX_N is the
    # read counter it bumps — unset under `set -u`, bash-as-sh (macOS) dies on it
    # with status 0 and this leg would pass without running.
    lw = source[source.index('_lw_fmt() {'):source.index('# Where `tmux -L <label>` puts its socket')]
    body = lw + source[source.index("STUCK_STRIKES='|'"):source.index('# --- stale-`needs` reconcile')]
    script = work / 'activity.sh'
    script.write_text("set -u\nTMUX_N=0\nNL='\n'\nSOCKETS=fleet-test\nSTUCK_SECS=5\n" +
        'BIN=' + shlex.quote(str(spin_bin)) + '\nSTUCK_LOG=' + shlex.quote(str(work / 'stuck.log')) + '\n' +
        'fake_now=100\ndate() { if [ "$1" = +%s ]; then echo "$fake_now"; else command date "$@"; fi; }\n' +
        body + '\n' + r'''
state() { tmux display-message -p -t "$worker_window" '#{@claude_state}'; }
stuck_check
[ "$(state)" = working ] || exit 10
fake_now=106; stuck_check
[ "$(state)" = working ] || exit 11
# A real worker screen change must cancel that first stale strike.
tmux respawn-pane -k -t "$worker_pane" 'printf fresh-worker-output; exec sleep 600'
i=0
while ! tmux capture-pane -p -t "$worker_pane" | grep -q fresh-worker-output; do
  i=$((i+1)); [ "$i" -lt 100 ] || exit 12; sleep 0.05
done
fake_now=107; stuck_check
[ "$(state)" = working ] || exit 13
fake_now=113; stuck_check
[ "$(state)" = working ] || exit 14
fake_now=114; stuck_check
[ "$(state)" = done ] || exit 15
''')
    result = subprocess.run(['sh', str(script)], env=dict(env, worker_window=w1, worker_pane=p1),
                            text=True, capture_output=True, timeout=15)
    check(result.returncode == 0, 'sidebar broke stale-worker detection: ' + result.stderr + str(result.returncode))

    # Close the agent while its sidebar is present: the view must not keep an
    # otherwise dead worker window alive (nor touch the neighbouring worker).
    tm('select-window', '-t', w2)
    wait_for(lambda: bool(view_on(w2)), 'sidebar did not follow worker selection')
    tm('kill-pane', '-t', p2)
    wait_for(lambda: w2 not in tm('list-windows', '-t', 'fleet-test', '-F', '#{window_id}').splitlines(),
             'sidebar kept a closed worker window alive')
    check(w1 in tm('list-windows', '-t', 'fleet-test', '-F', '#{window_id}').splitlines(),
          'sidebar cleanup closed an unrelated worker')

    tm('set-option', '-g', '@popup_open', str(int(time.time())))
    client.terminate()
    client.wait(timeout=5)
    wait_for(lambda: not views(), 'detach left sidebar refresh processes')
    check(tm('show-options', '-gv', '@popup_open') == '0', 'sidebar detach hook displaced popup cleanup')
    # (Last, after the detach: the detach hook's `#{session_id}` is whichever
    # session tmux ranks first, and a slow leg just before it tipped that to the
    # `adhoc` session above.)
    # The sidebar's one refresh (issue #1530): 10 windows over a 700-line
    # child-report ledger — the shape that took 4 s on a real machine — within
    # 300 ms (600 on CI), read off the producer's own `--time`. Its own server and
    # fleet, so no leg here sees these windows. Every @origin names a REAPED key,
    # so each chain asks the ledger; one climbs two reaped hops to its live
    # grandparent and must still nest under it.
    bsock = str(work / 'fleet-bench')
    bshim = work / 'bpath'
    bshim.mkdir()
    (bshim / 'tmux').write_text('#!/bin/sh\nexec ' + shlex.quote(real_tmux) + ' -S ' +
                                shlex.quote(bsock) + ' "$@"\n')
    (bshim / 'tmux').chmod(0o755)
    benv = dict(env, PATH=str(bshim) + os.pathsep + env['PATH'], FLEET_SESSION='fleet-bench')
    bconf = work / 'conf/fleets/fleet-bench/conf'
    (bconf.parent / 'children').mkdir(parents=True)
    bconf.write_text(fleet_conf)
    for parent in range(1, 55):
        (bconf.parent / 'children' / ('issue-%d.ndjson' % parent)).write_text(''.join(
            '{"child": "issue-%d", "state": "merged"}\n' % (parent * 100 + c) for c in range(1, 14)))
    (bconf.parent / 'children/issue-5501.ndjson').write_text('{"child": "issue-9001"}\n')
    (bconf.parent / 'children/issue-9001.ndjson').write_text('{"child": "issue-9002"}\n')
    def bt(*args):
        return subprocess.run([real_tmux, '-S', bsock, *args], env=benv, text=True,
                              capture_output=True, timeout=15).stdout.strip()
    try:
        bt('-f', '/dev/null', 'new-session', '-d', '-s', 'fleet-bench', '-n', 'dash', 'sleep 600')
        bwins = {}
        for n in range(5501, 5511):
            bw = bt('new-window', '-d', '-P', '-F', '#{window_id}', '-t', 'fleet-bench:', '-n', 'issue-%d' % n, 'sleep 600')
            bwins[n] = bw
            bt('set-option', '-w', '-t', bw, '@issue', str(n), ';',
               'set-option', '-w', '-t', bw, '@claude_state', 'working', ';',
               'set-option', '-w', '-t', bw, '@origin', 'issue-%d' % (n % 100 * 100 + 7))
        bt('set-option', '-w', '-t', bwins[5510], '@origin', 'issue-9002', ';',
           'set-option', '-w', '-t', bwins[5501], '@expand', '1')
        took, brows = [], []
        for _ in range(3):
            out = subprocess.run(['bash', str(bin_dir / 'tmux-dashboard-rows.sh'), '--sidebar', '--time'],
                                 env=benv, text=True, capture_output=True, timeout=30)
            check(out.returncode == 0 and out.stdout.rstrip().splitlines()[-1].startswith('#took '),
                  '--time did not end the rows with `#took <ms>`: %r' % out.stdout[-200:])
            took.append(int(out.stdout.rstrip().splitlines()[-1].split()[1]))
            brows = [l.split('\x1f') for l in out.stdout.splitlines() if '\x1f' in l]
        check(len((bconf.parent / 'children/.origin-map').read_text().splitlines()) >= 700,
              'the bench ledger is not the 700-line shape')
        order = [r[0] for r in brows]
        check(bwins[5510] in order and order.index(bwins[5510]) == order.index(bwins[5501]) + 1 and
              brows[order.index(bwins[5510])][6] == '1',
              'a child two reaped hops below its live parent did not nest under it: %r' % brows)
        budget = 600 if os.environ.get('CI') else 300
        print('sidebar timing: --sidebar over 10 windows + 700-line ledger took %s ms' % took)
        check(sorted(took)[1] <= budget, 'the sidebar refresh is slow again: %r ms (median over %d)' % (took, budget))
        plain = subprocess.run(['bash', str(bin_dir / 'tmux-dashboard-rows.sh'), '--sidebar'],
                               env=benv, text=True, capture_output=True, timeout=30).stdout
        check('#took' not in plain, 'the rows carry `#took` without --time')
    finally:
        subprocess.run([real_tmux, '-S', bsock, 'kill-server'], env=benv,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print('selftest PASS: sidebar (%d checks), isolated tmux layout/input/lifecycle and shared rows' % checks)
finally:
    cleanup()
PY
