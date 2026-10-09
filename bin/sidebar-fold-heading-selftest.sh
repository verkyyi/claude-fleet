#!/bin/bash
# sidebar-fold-heading-selftest.sh — the 置顶 / 已结束 headings fold with the
# mouse (issue #2723): before it a tap on 「已结束 (N)」 only highlighted it, and
# opening it was the keyboard's alone. fleet-sidebar.py's fold_tap /
# heading_text / fold_now, then dash-fold-toggle.sh on an isolated socket.
#
#   A. a tap anywhere on `hdr:ended` / `hdr:pin` folds — every column, at a
#      phone / iPad width (40) as at a wide one; a session row folds on its caret
#      only, a repo heading on its ▸ / ▾ only (its name keeps the two-tap
#      「新会话」), a bare heading never.
#   B. tap `hdr:ended` once → open (its rows drawn), again → shut — the verb the
#      click handler takes off fold_open, fold_now's guess both ways; its rows are
#      ordinary session rows: a tap jumps, a second opens the menu (dash-reap).
#   C. painted: ▸ shut / ▾ open in the heading's first two cells, the tapped
#      one's `› ` after it; a one-repo list's open repo heading wears no ▾.
#   D. the write behind it: dash-fold-toggle.sh expand / collapse hdr:ended
#      adds / drops the `ended:open` token in @repo_fold.
#
# Exit 0 = pass.
set -uo pipefail
export FLEET_SIDEBAR_NODE=1
BIN="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d /tmp/sbfh.XXXXXX)
trap 'tmux -S "$W/s" kill-server >/dev/null 2>&1; rm -rf "$W"' EXIT
FLEET_UI_LANG=zh python3 - "$BIN" <<'PY' || exit 1
import importlib.util
import sys

spec = importlib.util.spec_from_file_location('sidebar', sys.argv[1] + '/fleet-sidebar.py')
sb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sb)
checks = 0


def check(cond, msg):
    global checks
    if not cond:
        print('FAIL: ' + msg)
        sys.exit(1)
    checks += 1


def row(wid, state, label, tree='', depth='0'):
    return [wid, state, '●', label, tree, '', depth] + [''] * (sb.ROW_FIELDS - 7)


ended_shut = row('hdr', 'ended', '▸ 已结束 (2)')
ended_open = row('hdr', 'ended', '已结束 (2)')
pin = row('hdr', 'pin', '置顶')
repo = row('hdr', 'acme/app', 'acme/app')
repo2 = row('hdr', 'acme/web', 'acme/web')
bare = row('hdr', '', '?')
parent = row('@1', 'working', 'PARENT', '▸')
kid1 = row('@7', 'done', 'DONE1')
kid2 = row('@8', 'exited', 'GONE2')

# A
for width in (40, 120):
    for x in range(width):
        check(sb.fold_tap(ended_shut, 'hdr:ended', x), 'ended heading: x=%d of %d does not fold' % (x, width))
        check(sb.fold_tap(pin, 'hdr:pin', x), 'pin heading: x=%d of %d does not fold' % (x, width))
check(sb.fold_tap(repo, 'hdr:acme/app', 0) and sb.fold_tap(repo, 'hdr:acme/app', 1), 'repo heading caret')
check(not sb.fold_tap(repo, 'hdr:acme/app', 4), 'repo heading name folded: its two-tap grammar is gone')
check(sb.tap('hdr:acme/app', 'hdr:acme/app') == 'new', 'repo heading second tap')
check(sb.fold_tap(parent, '@1', 0) and not sb.fold_tap(parent, '@1', 30), 'session row caret')
check(not sb.fold_tap(bare, 'hdr', 0), 'a bare heading folded')
check(not sb.fold_tap(None, None, 0), 'no row folded')

# B — the click handler: verb off fold_open, then fold_now
rows = [repo, row('@2', 'working', 'W'), ended_shut]
cache = {'hdr:ended': [kid1, kid2]}
verb = 'collapse' if sb.fold_open(ended_shut) else 'expand'
check(verb == 'expand', 'first tap on a shut 已结束 is not expand: ' + verb)
rows, holder = sb.fold_now(rows, 'hdr:ended', verb, '@2', cache)
check(holder == 'hdr:ended' and sb.fold_open(rows[2]), 'first tap did not open 已结束')
check([r[0] for r in rows[3:]] == ['@7', '@8'], 'opened 已结束 does not draw its rows: %r' % rows)
check(sb.tap('@7', 'hdr:ended') == 'jump' and sb.tap('@7', '@7') == 'menu', 'an ended row is not jump-then-menu')
verb = 'collapse' if sb.fold_open(rows[2]) else 'expand'
check(verb == 'collapse', 'second tap is not collapse: ' + verb)
rows, holder = sb.fold_now(rows, 'hdr:ended', verb, '@2', cache)
check(holder == 'hdr:ended' and not sb.fold_open(rows[2]) and len(rows) == 3, 'second tap did not shut it: %r' % rows)

# C
check(sb.heading_text(ended_shut, False) == '▸ 已结束 (2)', sb.heading_text(ended_shut, False))
check(sb.heading_text(ended_open, False) == '▾ 已结束 (2)', sb.heading_text(ended_open, False))
check(sb.heading_text(ended_open, True) == '▾ › 已结束 (2)', sb.heading_text(ended_open, True))
check(sb.heading_text(pin, False, many=False) == '▾ 置顶', 'pin folds in a one-repo list too')
check(sb.repo_folds([repo, repo2, ended_open]) and not sb.repo_folds([repo, ended_open, pin]), 'repo_folds')
check(sb.heading_text(repo, False, many=True) == '▾ acme/app', sb.heading_text(repo, False, True))
check(sb.heading_text(repo, False, many=False) == 'acme/app', 'a one-repo open heading wears ▾')
check(sb.heading_text(bare, False) == '?', 'a bare heading wears a caret')
check(all(sb.on_caret(r, x) for r in (ended_open, repo) for x in (0, 1)), 'the painted caret is not on_caret')
print('A-C: %d checks' % checks)
PY

# D — the bit, on an isolated socket
command -v tmux >/dev/null 2>&1 || { echo 'selftest PASS (D skipped: tmux missing)'; exit 0; }
export FLEET_CONF_DIR="$W/conf" TMPDIR="$W"
unset TMUX_PANE
tmux -S "$W/s" -f /dev/null new-session -d -s fh -x 80 -y 20 'sleep 60' || { echo 'FAIL: tmux session'; exit 1; }
export TMUX="$W/s,1,0"   # bare tmux (the toggle's) talks to the test server
fold() { FLEET_SESSION=fh DASH_FOLD_PLAIN=1 bash "$BIN/dash-fold-toggle.sh" "$1" hdr:ended >/dev/null 2>&1; tmux show-option -t '=fh:' -qv @repo_fold; }
v=$(fold expand); case " $v " in *' ended:open '*) ;; *) echo "FAIL: D expand wrote '$v'"; exit 1 ;; esac
v=$(fold collapse); case " $v " in *' ended:open '*) echo "FAIL: D collapse left '$v'"; exit 1 ;; esac
echo 'selftest PASS'
