#!/bin/bash
# Selection and entry-point coverage for bin/selftest-sections.sh (#3884).
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
for invalid in ('0', '4', '-1', '2/3', 'garbage'):
    result = run(invalid)
    assert result.returncode == 2 and not result.stdout, (invalid, result)

# Every declared section has a discoverable entry point. A missing wrapper
# would otherwise silently drop assertions from both full and --changed runs.
parents = 0
for parent in bin_dir.glob('*-selftest.sh'):
    source = parent.read_text()
    match = re.search(r'^selftest_sections (\d+)$', source, re.M)
    if not match:
        continue
    parents += 1
    count = int(match[1])
    stem = parent.name.removesuffix('-selftest.sh')
    for number in range(2, count + 1):
        wrapper = bin_dir / f'{stem}-{number}-selftest.sh'
        text = wrapper.read_text()
        assert f'# selftest-part-of: {parent.name}\n' in text, wrapper
        assert f'SELFTEST_PART={number} exec bash ' in text, wrapper
        assert f'/{parent.name}" "$@"' in text, wrapper
        assert os.access(wrapper, os.X_OK), wrapper
assert parents >= 9, parents
print(f'PASS section selection and complete entry points ({parents} parents)')
PY
