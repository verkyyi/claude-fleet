#!/bin/bash
# Coverage of the issue #4500 families, including newly added cases, and of the
# `# selftest-parts:` / `# selftest-part:` headers run-selftests.sh reads (T525).
# Reads fleet-break-it-selftest.sh, fleet-break-it-node-selftest.sh,
# fleet-break-it-thin-selftest.sh, fleet-cleanup-idle-selftest.sh,
# fleet-hub-selftest.sh, fleet-quotawatch-selftest.sh, fleet-await-stall-selftest.sh,
# fleet-break-it-part.py, break-it-durations.txt, selftest_part.py and fleet-hub.yml.
# Also covers fleet-break-it-cred-sep-selftest.sh, fleet-break-it-hub-selftest.sh
# and fleet-sleep-selftest.sh (issue #3884).
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import collections
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

root = Path(sys.argv[1])
sys.dont_write_bytecode = True
sys.path.insert(0, str(root))
import selftest_part

# SDK-dependent cases can fall in any part. The SDK job must discover the whole
# family too, not silently run only the parent's slice after a repartition.
workflow = (root.parent / '.github/workflows/fleet-hub.yml').read_text()
assert re.search(r'run-selftests\.sh fleet-hub\s*$', workflow, re.M)

families = {
    'fleet-break-it-selftest.sh': 'BREAK_PART',
    'fleet-break-it-node-selftest.sh': 'BREAK_PART',
    'fleet-break-it-thin-selftest.sh': 'BREAK_PART',
    'fleet-cleanup-idle-selftest.py': 'SELFTEST_PART',
    'fleet-hub-selftest.py': 'SELFTEST_PART',
    'fleet-quotawatch-selftest.sh': 'SELFTEST_PART',
    'fleet-await-stall-selftest.sh': 'SELFTEST_PART',
    'fleet-break-it-cred-sep-selftest.sh': 'BREAK_PART',
    'fleet-break-it-hub-selftest.sh': 'BREAK_PART',
    'fleet-sleep-selftest.sh': 'SELFTEST_PART',
}

def header(text):
    """The parts a test declares (T525): (N, VAR, {k: explicit words})."""
    m = re.findall(r'^# selftest-parts: (\d+)(?: (\w+))?$', text, re.M)
    assert len(m) <= 1, 'one `# selftest-parts:` line per test'
    n, var = (int(m[0][0]), m[0][1] or 'SELFTEST_PART') if m else (0, '')
    ex = {int(k): w.split() for k, w in re.findall(r'^# selftest-part: (\d+)[ \t]*(.*)$', text, re.M)}
    return n, var, ex

# The parts are declared, never a file per part (T525): no `<base>-<k>-selftest.sh`
# beside a test that declares parts, and every declared test lists its ids.
ids = subprocess.run(['sh', str(root / 'run-selftests.sh'), '--ids'], text=True, check=True,
                     env=dict(os.environ, FLEET_SELFTEST_NO_SHADOW='1', FLEET_HEAVY='0'),
                     stdout=subprocess.PIPE).stdout.split()
declared = 0
for path in sorted(list(root.glob('*-selftest.sh')) + list(root.glob('*-selftest.py'))):
    n, var, ex = header(path.read_text())
    if not (n or ex):
        continue
    declared += 1
    stem = re.sub(r'-selftest\.(sh|py)$', '', path.name)
    left = [p.name for p in root.glob(stem + '-*-selftest.sh') if re.fullmatch(re.escape(stem) + r'-\d+-selftest\.sh', p.name)]
    assert not left, (path.name, 'a part file beside a declared test', left)
    top = max([n] + list(ex))
    assert all(k in ex for k in range(n + 1, top + 1)), (path.name, 'a part past N with no words')
    want = ['%s#%d' % (path.name, k) for k in range(1, top + 1)]
    assert [i for i in ids if i.split('#')[0] == path.name] == want, (path.name, want)
    if path.suffix == '.py':
        assert os.access(path, os.X_OK) and path.read_text().startswith('#!'), (path.name, 'an entry runs by its shebang')
        assert re.search(r'^# selftest-entry\b', path.read_text(), re.M), path.name
print('PASS %d tests declare their parts; no part file left; ids listed' % declared)

def default_n(text, var):
    m = re.search(r'\$\{' + var + r':[-=]1/(\d+)\}', text)
    return int(m[1]) if m else None

for name, var in families.items():
    parent = root / name
    source = parent.read_text()
    n, hvar, ex = header(source)
    assert hvar == var, (name, hvar)
    if name in ('fleet-break-it-cred-sep-selftest.sh', 'fleet-break-it-hub-selftest.sh'):
        assert 'bin/break-it-durations.txt' in source, (name, 'missing weight selection dependency')
    sh = parent.with_suffix('.sh')
    if parent.suffix == '.py':
        assert default_n(source, var) is None, (name, 'the .py has no default slice: no part ⇒ every case')
    else:
        assert default_n(source, var) == n, (name, 'header N != the default K/N', n)
    base = name.rsplit('-selftest.', 1)[0]
    pyfile = parent.with_suffix('.py')

    if base in ('fleet-cleanup-idle', 'fleet-hub', 'fleet-sleep'):
        # Use unittest discovery itself, including inherited test methods.
        saved = sys.argv[:]
        sys.argv = [str(pyfile), str(root)]
        spec = importlib.util.spec_from_file_location('partition_cases', pyfile)
        module = importlib.util.module_from_spec(spec)
        sys.modules['partition_cases'] = module
        spec.loader.exec_module(module)
        sys.argv = saved
        cases = [t.id() for t in selftest_part._flat(unittest.defaultTestLoader.loadTestsFromModule(module))]
        split = lambda values: [values[k::n] for k in range(n)]
    else:
        prefix = 'drill_' if var == 'BREAK_PART' else 'test_'
        cases = re.findall(r'^(' + prefix + r'[a-z0-9_]+)\(\) *\{', source, re.M)
        if var == 'BREAK_PART':
            cases = [s[6:].replace('_', '-') for s in cases]
        if base == 'fleet-break-it':
            rows = re.findall(r'\| `([a-z0-9-]+)` \|', (root.parent / 'docs/dev/BREAK-IT.md').read_text())
            cases = [r for r in rows if r in cases]
        table = str(root / 'break-it-durations.txt') if var == 'BREAK_PART' else os.devnull
        def split(values):
            return [subprocess.check_output([sys.executable, str(root / 'fleet-break-it-part.py'),
                    '%d/%d' % (k, n), table, *values], text=True).split() for k in range(1, n + 1)]

    assert cases and len(cases) == len(set(cases)), base
    parts = split(cases)
    assert all(parts), (base, 'empty segment')
    assert collections.Counter(x for p in parts for x in p) == collections.Counter(cases), base
    grown = cases + ['new_case_without_duration']
    assert collections.Counter(x for p in split(grown) for x in p) == collections.Counter(grown), base
    # A part regrouped into explicit parts (issue #3884): cleanup-idle's part 4/4 runs
    # as its ids #4..#8, each naming whole cases. Together they are exactly that
    # part's cases, each once — never a bare 4/4 beside them.
    if ex:
        regroup = min(ex)
        assert regroup == n, (base, 'the regrouped part is the last one')
        want = [c.split('.', 1)[1] for c in parts[regroup - 1]]
        named = [c for k in sorted(ex) for c in ex[k] if '=' not in c]
        assert len(named) == len(set(named)), (base, 'a case in two groups', named)
        assert collections.Counter(named) == collections.Counter(want), \
            (base, 'groups != part', sorted(set(want) - set(named)), sorted(set(named) - set(want)))
        print('PASS %s: part %d/%d regrouped into %d ids, %d cases, every case once'
              % (base, regroup, n, len(ex), len(want)))
    print('PASS %s: %d discovered cases, %d parts, every case once; growth covered' % (base, len(cases), n))

# Execute the actual shell dispatch with harmless groups, so all/default and
# automatic discovery cannot silently diverge from the metadata above.
for base in ('fleet-quotawatch', 'fleet-await-stall'):
    source = (root / (base + '-selftest.sh')).read_text()
    dispatch = source[source.index('# Discover groups,'):]
    groups = re.findall(r'^(test_[a-z0-9_]+)\(\) *\{', source, re.M) + ['test_new_case_2']
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / 'probe.sh'
        script.write_text('CHECKS=0\npart=$1\nBIN=$2\n' +
                          ''.join('%s() { echo CASE:%s; }\n' % (g, g) for g in groups) + dispatch)
        def run(part):
            out = subprocess.check_output(['bash', str(script), part, str(root)], text=True)
            return re.findall(r'^CASE:(.*)$', out, re.M)
        n = header(source)[0]
        assert run('all') == groups
        assert [g for k in range(1, n + 1) for g in run('%d/%d' % (k, n))] == groups
        assert subprocess.run(['bash', str(script), '0/2', str(root)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 2
    print('PASS %s: direct all, sliced dispatch, growth and invalid part' % base)
PY
