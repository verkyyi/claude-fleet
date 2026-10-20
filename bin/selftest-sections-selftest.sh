#!/bin/bash
# Selection and declared-part coverage for bin/selftest-sections.sh (#3884, T525).
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys

bin_dir = Path(sys.argv[1])
probe = '''. "$1/selftest-sections.sh"
selftest_sections "$2"
for n in 1 2 3; do
  if selftest_section "$n"; then echo "$n"; fi
done
'''
env = dict(os.environ)
env.pop('SELFTEST_PART', None)
def run(part=None):
    e = dict(env)
    if part is not None:
        e['SELFTEST_PART'] = part
    return subprocess.run(['bash', '-c', probe, '_', str(bin_dir), '3'], env=e,
                          text=True, capture_output=True)

assert run().stdout == '1\n'
parts = [run(str(n)) for n in range(1, 4)]
assert all(p.returncode == 0 for p in parts)
assert ''.join(p.stdout for p in parts) == run('all').stdout == '1\n2\n3\n'
# run-selftests.sh hands K/N off the `# selftest-parts: N` header (T525)
assert [run('%d/3' % n).stdout for n in range(1, 4)] == ['1\n', '2\n', '3\n']
for invalid in ('0', '01', '4', '-1', 'garbage', '2/4', '4/3', '0/3', '/3'):
    result = run(invalid)
    assert result.returncode == 2 and not result.stdout, (invalid, result)

# Every section is a declared part (`# selftest-parts: N`, T525), so the runner
# gives each its id; a count off by one would silently drop assertions from both
# full and --changed runs.
parents = 0
for parent in bin_dir.glob('*-selftest.sh'):
    source = parent.read_text()
    match = re.search(r'^selftest_sections (\d+)$', source, re.M)
    if not match:
        continue
    parents += 1
    count = int(match[1])
    stem = parent.name.removesuffix('-selftest.sh')
    assert re.search(r'^# selftest-parts: %d$' % count, source, re.M), (parent.name, count)
    assert not list(bin_dir.glob(f'{stem}-[0-9]*-selftest.sh')), (parent.name, 'a part file')
# The ninth original parent (sidebar) retired with the old client in #4423.
assert parents >= 8, parents
print(f'PASS section selection and every section a declared part ({parents} parents)')
PY
