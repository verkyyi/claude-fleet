#!/bin/bash
# Coverage of the issue #4500 families, including newly added cases.
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
assert "run-selftests.sh fleet-hub 'fleet-hub-[0-9]*'" in workflow

families = {
    'fleet-break-it': ('BREAK_PART', 21),
    'fleet-break-it-node': ('BREAK_PART', 6),
    'fleet-break-it-thin': ('BREAK_PART', 3),
    'fleet-cleanup-idle': ('SELFTEST_PART', 4),
    'fleet-hub': ('SELFTEST_PART', 4),
    'fleet-quotawatch': ('SELFTEST_PART', 3),
    'fleet-await-stall': ('SELFTEST_PART', 2),
    'fleet-break-it-cred-sep': ('BREAK_PART', 2),
    'fleet-break-it-hub': ('BREAK_PART', 2),
    'fleet-sleep': ('SELFTEST_PART', 3),
}
for base, (var, n) in families.items():
    parent = root / (base + '-selftest.sh')
    source = parent.read_text()
    assert re.search(r'\$\{' + var + r':[-=]1/' + str(n) + r'\}', source), base
    wrappers = {}
    for path in root.glob(base + '-*-selftest.sh'):
        if not re.fullmatch(re.escape(base) + r'-\d+-selftest.sh', path.name):
            continue
        text = path.read_text()
        assert '# selftest-part-of: ' + parent.name in text, path
        match = re.search(var + r'=(\d+)/(\d+) exec bash', text)
        assert match and int(match[2]) == n, path
        k = int(match[1])
        assert k not in wrappers, path
        wrappers[k] = path
    assert set(wrappers) == set(range(2, n + 1)), (base, wrappers)

    if base in ('fleet-cleanup-idle', 'fleet-hub', 'fleet-sleep'):
        # Use unittest discovery itself, including inherited test methods.
        saved = sys.argv[:]
        sys.argv = [str(parent.with_suffix('.py')), str(root)]
        spec = importlib.util.spec_from_file_location('partition_cases', parent.with_suffix('.py'))
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
        n = families[base][1]
        assert run('all') == groups
        assert [g for k in range(1, n + 1) for g in run('%d/%d' % (k, n))] == groups
        assert subprocess.run(['bash', str(script), '0/2', str(root)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 2
    print('PASS %s: direct all, sliced dispatch, growth and invalid part' % base)
PY
