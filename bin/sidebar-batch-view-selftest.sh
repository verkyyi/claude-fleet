#!/bin/bash
# sidebar-batch-view-selftest.sh — the list is the batches and what wants you
# (issue #2675, EPIC #2668 C7): fleet-sidebar.py's batch_view over the producer's
# rows (tmux-dashboard-rows.sh --sidebar), no tmux needed.
#
#   A. 7 batches + 4 sessions with no batch in 2 repos → ≤ 10 rows by default,
#      「新任务」 counted; each repo's strays are ONE 「单独的活 · N」 row (solo:<repo>).
#   B. a row waiting on you under a folded batch: hidden, the batch wears `!`
#      (never red, never opened); fold_now shutting a batch takes it in too.
#   C. open / shut is remembered: a solo group's bit (solo_fold_<sess>, through
#      fold_write) and a batch's (the producer's ▾) both survive the next frame;
#      the current window never hides from itself.
#   D. 停放 / 待你动手 rows off orch_<sess>'s tagged columns; a tap opens the
#      orchestrator, no other action takes them.
#   E. 40 columns: a batch row keeps its name's first 8 glyphs whole.
#   F. FLEET_SIDEBAR_FOLD=off: the producer's rows untouched, byte for byte; no
#      steward row; fold_now as before.
#
# Exit 0 = pass.
set -uo pipefail
export FLEET_SIDEBAR_NODE=1
BIN="$(cd "$(dirname "$0")" && pwd)"
G=$(mktemp -d "${TMPDIR:-/tmp}/sbv.XXXXXX")
trap 'rm -rf "$G"' EXIT
FLEET_STATUS_G="$G" FLEET_UI_LANG=zh python3 - "$BIN" <<'PY'
import copy
import importlib.util
import os
import sys
from pathlib import Path

real_bin = Path(sys.argv[1])
sys.path.insert(0, str(real_bin))
spec = importlib.util.spec_from_file_location('sidebar', real_bin / 'fleet-sidebar.py')
sb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sb)
N = sb.ROW_FIELDS
CHECKS = [0]


def check(what, ok, got=None):
    CHECKS[0] += 1
    if not ok:
        print('selftest FAIL: %s%s' % (what, '' if got is None else ' — got %r' % (got,)), file=sys.stderr)
        sys.exit(1)


def row(wid, state, name, tree='', badge='', depth=0, issue=''):
    r = [wid, state, '●' if state != 'needs' else '!', name, tree, badge, str(depth), '', '', issue]
    return r + [''] * (N - len(r))


def hdr(target, name):
    return ['hdr', target, '', name, ''] + [''] * (N - 5)


A, B = 'verkyyi/claude-fleet', 'verkyyi/24haowan-monorepo'


def frame(opened=()):
    """The producer's frame: folded batches (▸) keep only a needs child; an
    opened one (▾) shows all of its children."""
    rows = [hdr(A, 'claude-fleet (11)')]
    kids = {'@1': [row('@11', 'needs', '真机演练临时账号', '└', depth=1), row('@12', 'working', '升级后会话还在', '└', depth=1)],
            '@2': [row('@21', 'working', '收编短信通知', '└', depth=1)]}
    names = {'@1': '单会话像本地', '@2': '后台服务与定时任务', '@3': '派任务的入口', '@4': '角色不丢', '@5': '编排架构'}
    for wid in ('@1', '@2', '@3', '@4', '@5'):
        is_open = wid in opened
        rows.append(row(wid, 'looping', names[wid], '▾' if is_open else '▸', '5/8'))
        for k in kids.get(wid, []):
            if is_open or k[1] == 'needs':
                rows.append(k)
    rows += [row('@31', 'working', '节点侧读入口失败', issue='#2630'),
             row('@32', 'needs', '托管机器升级卡住', issue='#2631'),
             row('@33', 'working', '写设计页')]
    rows.append(hdr(B, '24haowan-monorepo (4)'))
    for wid, name in (('@6', 'TUOKE多人同空间'), ('@7', '拓客第二版')):
        rows.append(row(wid, 'looping', name, '▾' if wid in opened else '▸', '9/9'))
    rows.append(row('@41', 'done', '写设计页（拓客第二版）'))
    rows.append(hdr('pin', '置顶 (1)'))
    rows.append(row('@51', 'working', '钉住的会话'))
    return rows


def shown(rows):
    return [r for r in rows if r[0] != 'hdr']


# ── A. the default count ──────────────────────────────────────────────────────
os.environ.pop('FLEET_SIDEBAR_FOLD', None)
raw = frame()
before = copy.deepcopy(raw)
cache = {}
v = sb.batch_view(raw, '@99', set(), cache)
check('A batch_view leaves the producer rows alone', raw == before)
keys = [sb.key_of(r) for r in v]
batches = ['@1', '@2', '@3', '@4', '@5', '@6', '@7']
check('A every batch is a row', all(k in keys for k in batches), keys)
check('A one solo group per repo', [k for k in keys if k.startswith('solo:')] == ['solo:' + A, 'solo:' + B], keys)
check('A the strays are folded', not any(k in keys for k in ('@31', '@32', '@33', '@41')), keys)
check('A the pinned row stays', '@51' in keys, keys)
solo_a = next(r for r in v if r[0] == 'solo:' + A)
check('A 单独的活 · 3', solo_a[3] == '单独的活 · 3' and solo_a[4] == '▸', solo_a[:6])
check('A the solo group sits at its repo section end', keys.index('solo:' + A) < keys.index('hdr:' + B)
      and keys.index('solo:' + A) > keys.index('@5'), keys)
# the claim the issue makes: 「新任务」 + the rows, no heading, the pinned group aside
count = 1 + len([r for r in shown(v) if r[0] != '@51'])
check('A ≤ 10 rows by default (7 batches + 2 groups + 「新任务」)', count <= 10, count)
check('A the solo kids are cached for an instant open', [r[0] for r in cache['solo:' + A]] == ['@31', '@32', '@33'])
check('A a solo kid is drawn one level in', all(r[4] == '└' and r[6] == '1' for r in cache['solo:' + A]))

# ── B. a row waiting on you folds into its batch, the batch wears `!` ─────────
b1 = next(r for r in v if r[0] == '@1')
check('B the needs child is hidden', '@11' not in keys, keys)
check('B the batch wears `!`', b1[5] == '! 5/8', b1[5])
check('B the batch is not red', b1[1] == 'looping', b1[1])
check('B the batch stays folded', b1[4] == '▸', b1[4])
check('B a quiet batch has no `!`', next(r for r in v if r[0] == '@3')[5] == '5/8')
check('B the solo group with a needs row wears `!`', solo_a[5] == '!', solo_a[5])
check('B a quiet solo group has none', next(r for r in v if r[0] == 'solo:' + B)[5] == '')
check('B no row but 「新任务」 may be red: none here is needs', not any(r[1] in sb.FOLD_KEEP for r in v))
# an opened batch shows its children (its own choice); shutting it hides the loud one too
vo = sb.batch_view(frame(opened={'@1'}), '@99', set(), {})
check('B an opened batch shows all its children', [r[0] for r in vo if r[0] in ('@11', '@12')] == ['@11', '@12'])
shut, holder = sb.fold_now(vo, '@1', 'collapse', '@99', {})
check('B ← on a batch hides its needs child too', holder == '@1' and '@11' not in [r[0] for r in shut])
shut, holder = sb.fold_now(vo, '@12', 'collapse', '@12', {})
check('B ← from a child shuts the batch but keeps the current window',
      holder == '@1' and [r[0] for r in shut if r[0] in ('@11', '@12')] == ['@12'])

# ── C. open / shut is remembered ─────────────────────────────────────────────
sess = 'fleet'
env = {'FLEET_SESSION': sess}
check('C nothing opened yet', sb.solo_opened(sess) == set())
fc = {}
v = sb.batch_view(frame(), '@99', sb.solo_opened(sess), fc)
opened, holder = sb.fold_now(v, 'solo:' + A, 'expand', '@99', fc)
check('C → opens the solo group at once', holder == 'solo:' + A and
      [r[0] for r in opened if r[0] in ('@31', '@32', '@33')] == ['@31', '@32', '@33'])
check('C fold_write keeps a solo bit itself (no toggle process)',
      sb.fold_write(None, 'expand', 'solo:' + A, env, holder) is None)
check('C the bit is written', sb.solo_opened(sess) == {'solo:' + A}, sb.solo_opened(sess))
v2 = sb.batch_view(frame(), '@99', sb.solo_opened(sess), {})
check('C the next frame keeps it open', [r[0] for r in v2 if r[0] in ('@31', '@32', '@33')] == ['@31', '@32', '@33'])
check('C …with its caret ▾', next(r for r in v2 if r[0] == 'solo:' + A)[4] == '▾')
# ← from a child of the open group: the holder is the group, the bit goes
shut, holder = sb.fold_now(v2, '@31', 'collapse', '@31', {})
check('C ← from a solo child shuts the group', holder == 'solo:' + A)
sb.fold_write(None, 'collapse', '@31', env, holder)
check('C …and its bit', sb.solo_opened(sess) == set(), sb.solo_opened(sess))
v3 = sb.batch_view(frame(opened={'@6'}), '@99', set(), {})
check('C a batch opened (the producer\'s ▾) stays open', next(r for r in v3 if r[0] == '@6')[4] == '▾')
v4 = sb.batch_view(frame(), '@33', set(), {})
check('C the current window shows under its folded group', '@33' in [r[0] for r in v4] and '@31' not in [r[0] for r in v4])
check('C a solo row folds on a tap anywhere: no jump, no menu',
      sb.tap('solo:' + A, '') == 'select' and sb.acts('solo:' + A) == '' and sb.folds('solo:' + A) == 'solo:' + A)
check('C a solo group is no session', 'solo:' + A not in sb.sessions(v))

# ── D. 停放 / 待你动手 ─────────────────────────────────────────────────────────
line = ['fleet/abc', 'm5', '1', 'working', '', '', '0', 'decide=2', 'park=1', 'todo=3']
st = sb.steward_rows(line)
check('D two rows', [r[0] for r in st] == ['steward:park', 'steward:todo'], st)
check('D their words', [r[3] for r in st] == ['停放 1', '待你动手 3'], [r[3] for r in st])
check('D a zero is no row', sb.steward_rows(line[:8] + ['park=0']) == [])
check('D no tagged column (no steward, an older node) is no row', sb.steward_rows(line[:7]) == [])
check('D a tap opens the orchestrator', sb.tap('steward:park', '') == 'jump')
check('D no other action, no fold', sb.acts('steward:park') == '' and sb.folds('steward:todo') == '')
check('D not a session', sb.sessions(st) == [])
check('D the queue column still reads', sb.orch_queue(line) == 0)
# 待换新 (issue #2733): `renew=1` — the orchestrator runs an older fleet version
# than its machine has; 「新任务」 says so at its end, and it is no steward row
rl = ['fleet/abc', 'm5', '1', 'done', '', '', '', 'renew=1']
check('D renew=1 is no steward row', sb.steward_rows(rl) == [])
_ol, _st = sb.orch_line, sb.STAGE
sb.orch_line, sb.STAGE = (lambda s: rl), '1'
_top = sb.with_portal([], None, 'fleet')[0]
check('D renew=1: 「新任务」 ends 待换新', _top[0] == sb.PORTAL_KEY and _top[9] == '待换新', _top)
sb.orch_line = lambda s: rl[:7]
check('D no renew tag: no word', sb.with_portal([], None, 'fleet')[0][9] == '')
sb.orch_line, sb.STAGE = _ol, _st

# ── E. a phone's 40 columns ──────────────────────────────────────────────────
name = '托管节点升级与回滚全流程走通'   # 14 glyphs: wider than the room
text = sb.row_text(' ', '●', '▸', name, '! 12/15', 39, '')
check('E 40 columns keep the batch name\'s first 8 glyphs', name[:8] in text, text)
check('E …and the whole badge', text.endswith('· ! 12/15'), text)
text = sb.row_text(' ', sb.SOLO_GLYPH, '▸', sb.tr('sidebar_solo_fmt', 12), '!', 39, '')
check('E the solo group whole at 40', '单独的活 · 12' in text, text)

# ── F. FLEET_SIDEBAR_FOLD=off: byte for byte ─────────────────────────────────
os.environ['FLEET_SIDEBAR_FOLD'] = 'off'
raw = frame()
check('F off: the producer\'s rows, untouched', sb.batch_view(raw, '@99', {'solo:' + A}, {}) is raw)
check('F off: no steward row', sb.steward_rows(line) == [])
vo = frame(opened={'@1'})
shut, holder = sb.fold_now(vo, '@1', 'collapse', '@99', {})
check('F off: ← keeps the needs child, as before', holder == '@1' and '@11' in [r[0] for r in shut])
os.environ.pop('FLEET_SIDEBAR_FOLD')
print('selftest OK: %d checks' % CHECKS[0])
PY
