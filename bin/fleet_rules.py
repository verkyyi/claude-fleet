#!/usr/bin/env python3
"""fleet_rules.py — THE one reader of the rule table (issue #2786, EPIC #2781 C5).

How the orchestrator dispatches (one worker / an EPIC / a driver / the queue /
just an answer, when Codex, what a subagent may do) and what the steward may
answer on its own, by default, or never (auto / default / ask) are ONE numbered
table. Three layers, low → high, merged by number:

  自带   conf/role-rules.default.md           (the fleet's; ships with the tree)
  你的   $FLEET_CONF_DIR/person-bundle.json `rules`   (the person's layer, C3
         fetches it; a Markdown table in the same format, or a list of rows)
  本机   $FLEET_CONF_DIR/roles/rules.md        (this computer: development, an
         emergency)

A row is  编号 · 角色 · 条件 · 动作 · 档位 · 关键词. A layer's row replaces the
row with its number; `档位 off` removes it; a number is never reused — a layer's
NEW row starts at 100. A layer with any row that cannot be read is not used at
all (the rest stand), and says why under `problems`.

An `ask` row whose 动作 names `never:<rule|money|publish>` carries that class's
keywords: bin/fleet_decision.py's classify reads them instead of its own list
(the code's list is the backstop when the table cannot be read).

The merged table's version is the content address of its rows; every version a
machine renders is kept as $FLEET_CONF_DIR/roles/rules-<v>.md, so a ticket's
「按规则 N」 (`<!-- fleet:rule n=N v=<v> -->`) still finds the row it was
dispatched by after the table changed.
"""
import hashlib
import json
import os
import re

BIN = os.path.dirname(os.path.abspath(__file__))
ROLES = ('orchestrator', 'steward', 'worker', 'epic-driver')
TIERS = ('auto', 'default', 'ask', 'off')
CLASSES = ('rule', 'money', 'publish')
NEW_FROM = 100
HEAD = ('编号', '角色', '条件', '动作', '档位', '关键词')
CLASS_RE = re.compile(r'never:(rule|money|publish)')
MARK_RE = re.compile(r'<!-- fleet:rule n=(\d+) v=([0-9a-f]+) -->')
SECTION_MAX = 40


class RulesError(Exception):
    pass


def conf_dir():
    return os.environ.get('FLEET_CONF_DIR') or os.path.join(
        os.path.expanduser('~'), '.config', 'claude-fleet')


def default_path():
    """conf/role-rules.default.md beside this bin/, else beside the file a
    symlinked bin/ points at (a selftest's shadow root)."""
    if os.environ.get('FLEET_RULES_DEFAULT'):
        return os.environ['FLEET_RULES_DEFAULT']
    for root in (os.path.dirname(BIN), os.path.dirname(os.path.dirname(os.path.realpath(__file__)))):
        p = os.path.join(root, 'conf', 'role-rules.default.md')
        if os.path.isfile(p):
            return p
    return os.path.join(os.path.dirname(BIN), 'conf', 'role-rules.default.md')


def _words(cell):
    return [w.strip().lower() for w in re.split(r'[,，、]', cell or '') if w.strip()]


def _row(cells):
    """One row from its six cells (a list or a dict); RulesError when unreadable."""
    if isinstance(cells, dict):
        kw = cells.get('keywords', '')
        cells = [cells.get('n', ''), cells.get('role', ''), cells.get('cond', ''),
                 cells.get('action', ''), cells.get('tier', ''),
                 ', '.join(kw) if isinstance(kw, list) else kw]
    cells = [str(c).strip() for c in cells]
    if len(cells) != 6:
        raise RulesError('a row has %d cells, not 6: %s' % (len(cells), ' | '.join(cells)))
    n, role, cond, action, tier, kw = cells
    if not n.isdigit() or int(n) < 1:
        raise RulesError('编号 must be a positive number: %r' % n)
    if role not in ROLES:
        raise RulesError('rule %s: 角色 %r is not one of %s' % (n, role, ' '.join(ROLES)))
    if tier not in TIERS:
        raise RulesError('rule %s: 档位 %r is not one of %s' % (n, tier, ' '.join(TIERS)))
    if tier != 'off' and not (cond and action):
        raise RulesError('rule %s: 条件 and 动作 are required' % n)
    m = CLASS_RE.search(action)
    return {'n': int(n), 'role': role, 'cond': cond, 'action': action, 'tier': tier,
            'keywords': _words(kw), 'cls': m.group(1) if m else ''}


def parse(text):
    """The rows of a Markdown table whose header starts with 编号."""
    rows, inside = [], False
    for ln in (text or '').splitlines():
        s = ln.strip()
        if not s.startswith('|'):
            inside = False
            continue
        cells = [c.strip() for c in s.strip('|').split('|')]
        if cells and cells[0] == HEAD[0]:
            inside = True
            continue
        if not inside or set(''.join(cells)) <= set('-: '):
            continue
        rows.append(_row(cells))
    return rows


def _person_layer():
    """(rows, label) of the person-bundle's `rules`, or None when there is none."""
    p = os.path.join(conf_dir(), 'person-bundle.json')
    try:
        with open(p) as f:
            bundle = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(bundle, dict):
        return None
    ver = bundle.get('version')
    # the cache C3 writes is {version, bundle: {rules, roles, …}}; a flat
    # {version, rules} (written by hand) reads the same
    if isinstance(bundle.get('bundle'), dict) and 'rules' in bundle['bundle']:
        bundle = bundle['bundle']
    if bundle.get('rules') in (None, '', []):
        return None
    rules = bundle['rules']
    label = '你的 v%s' % ver if ver not in (None, '') else '你的'
    if isinstance(rules, str):
        return parse(rules), label
    if isinstance(rules, list):
        return [_row(r) for r in rules], label
    raise RulesError('person-bundle rules is neither a table nor a list')


def _layers(person=None):
    """[(name, source label, loader)] low → high. `person` (a callable) stands in
    for the cached person layer — a preview of a change not yet written (#2785)."""
    def default():
        with open(default_path(), encoding='utf-8') as f:
            return parse(f.read()), '自带'

    def local():
        p = os.path.join(conf_dir(), 'roles', 'rules.md')
        if not os.path.isfile(p):
            return None
        with open(p, encoding='utf-8') as f:
            return parse(f.read()), '本机'
    return [('default', default), ('person', person or _person_layer), ('local', local)]


def version_of(rows):
    canon = json.dumps([[r['n'], r['role'], r['cond'], r['action'], r['tier'], r['keywords']]
                        for r in rows], ensure_ascii=False, separators=(',', ':'))
    return hashlib.sha256(canon.encode('utf-8')).hexdigest()[:10]


def load(person=None):
    """The merged table: {version, rows, layers, problems}. Raises RulesError
    only when the fleet's own table cannot be read. `person`: see _layers."""
    merged, layers, problems = {}, [], []
    for name, loader in _layers(person):
        try:
            got = loader()
        except (OSError, RulesError, ValueError) as e:
            if name == 'default':
                raise RulesError('the fleet\'s rule table: %s' % e)
            problems.append('%s layer not used: %s' % (name, e))
            layers.append({'layer': name, 'used': False, 'problem': str(e)})
            continue
        if got is None:
            continue
        rows, label = got
        if name != 'default':
            bad = [r['n'] for r in rows if r['n'] not in merged and r['n'] < NEW_FROM]
            if bad:
                why = 'a new rule starts at %d (got %s)' % (NEW_FROM, ', '.join(map(str, bad)))
                problems.append('%s layer not used: %s' % (name, why))
                layers.append({'layer': name, 'used': False, 'problem': why})
                continue
        seen = set()
        for r in rows:
            if r['n'] in seen:
                continue                     # the first of a duplicated number in one layer
            seen.add(r['n'])
            r['source'] = label
            merged[r['n']] = r
        layers.append({'layer': name, 'used': True, 'source': label, 'rows': len(rows)})
    rows = sorted((r for r in merged.values() if r['tier'] != 'off'), key=lambda r: r['n'])
    return {'version': version_of(rows), 'rows': rows, 'layers': layers, 'problems': problems}


def never_words(table):
    """{class: (keyword, …)} off the table's `ask` rows — what classify matches."""
    out = {c: [] for c in CLASSES}
    for r in table['rows']:
        if r['tier'] == 'ask' and r['cls'] in out:
            out[r['cls']] += [w for w in r['keywords'] if w not in out[r['cls']]]
    return {c: tuple(w) for c, w in out.items()}


def markdown(table, role=None):
    rows = [r for r in table['rows'] if role in (None, r['role'])]
    lines = ['| ' + ' | '.join(HEAD) + ' |', '|---|---|---|---|---|---|']
    for r in rows:
        lines.append('| %d | %s | %s | %s | %s | %s |' % (
            r['n'], r['role'], r['cond'], r['action'], r['tier'], ', '.join(r['keywords'])))
    return '\n'.join(lines) + '\n'


def section(table, role):
    """The rows that apply to <role>, as the system prompt carries them (≤ 40 lines);
    '' when none do."""
    rows = [r for r in table['rows'] if r['role'] == role]
    if not rows:
        return ''
    lines = ['', '## 规则表 v=%s' % table['version'],
             '| 编号 | 条件 | 动作 | 档位 |', '|---|---|---|---|']
    for r in rows[:SECTION_MAX - len(lines)]:
        lines.append('| %d | %s | %s | %s |' % (r['n'], r['cond'], r['action'], r['tier']))
    return '\n'.join(lines) + '\n'


def save(table):
    """Keep this version's table as roles/rules-<v>.md (once); its path, or ''."""
    dst = os.path.join(conf_dir(), 'roles', 'rules-%s.md' % table['version'])
    try:
        if not os.path.isfile(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            tmp = '%s.%d.tmp' % (dst, os.getpid())
            with open(tmp, 'w', encoding='utf-8') as f:
                f.write('# 规则表 v=%s\n\n' % table['version'] + markdown(table))
            os.replace(tmp, dst)
        return dst
    except OSError:
        return ''


def find(version):
    """The rows of a kept version (a ticket's v=), or None."""
    if not re.fullmatch(r'[0-9a-f]{4,64}', version or ''):
        return None
    cur = load()
    if cur['version'].startswith(version):
        return cur
    d = os.path.join(conf_dir(), 'roles')
    try:
        names = [n for n in os.listdir(d) if n.startswith('rules-' + version) and n.endswith('.md')]
    except OSError:
        return None
    if len(names) != 1:
        return None
    with open(os.path.join(d, names[0]), encoding='utf-8') as f:
        rows = parse(f.read())
    return {'version': names[0][6:-3], 'rows': rows, 'layers': [], 'problems': []}


def mark(n, table):
    """The line a dispatched ticket ends with; RulesError for a number the table lacks."""
    row = next((r for r in table['rows'] if r['n'] == int(n)), None)
    if row is None:
        raise RulesError('no rule %s in the table (v=%s)' % (n, table['version']))
    return '按规则 %d 派发\n<!-- fleet:rule n=%d v=%s -->' % (row['n'], row['n'], table['version'])
