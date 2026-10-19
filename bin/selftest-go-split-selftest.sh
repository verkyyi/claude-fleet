#!/bin/bash
# Exercise fleet-break-it-revoke-selftest.sh's real Go-half dispatch. The real
# TestRevocations tests remain in tokenledger/hub/api and tokenledger.yml.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).parent
source = (root / 'bin/fleet-break-it-revoke-selftest.sh').read_text()
start = source.index('  # The shell/Go split')
block = source[start:source.index('\n  WHAT=', start)]
with tempfile.TemporaryDirectory(prefix='revoke-go-gate.') as tmp:
    work = Path(tmp)
    api = work / 'tokenledger/hub/api'
    api.mkdir(parents=True)
    tests = api / 'fleet_revocations_test.go'
    tests.write_bytes((root / 'tokenledger/hub/api/fleet_revocations_test.go').read_bytes())
    fake = work / 'bin'
    fake.mkdir()
    go = fake / 'go'
    go.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$GO_CALLS"\n'
                  'echo "${GO_REPLY:-ok api}"\nexit "${GO_EXIT:-0}"\n')
    go.chmod(0o755)
    script = work / 'probe.sh'
    script.write_text('ROOT=$1\nprobe() {\n' + block + '\n}\nprobe\n')
    log = work / 'calls'
    env = dict(os.environ, PATH=str(fake) + os.pathsep + os.environ['PATH'], GO_CALLS=str(log))
    def run(enabled, **extra):
        log.write_text('')
        result = subprocess.run(['bash', str(script), str(work)],
            env=dict(env, BREAK_GO=str(enabled), **extra), capture_output=True, text=True, timeout=3)
        return result.returncode, log.read_text().splitlines()
    assert run(0) == (0, []), 'BREAK_GO=0 invoked Go'
    command = 'test -count=1 -run ^TestRevocations ./hub/api'
    assert run(1) == (0, [command]), 'enabled Go half did not execute its test family'
    assert run(1, GO_EXIT='1')[0] != 0, 'Go failure swallowed'
    assert run(1, GO_REPLY='ok api [no tests to run]')[0] != 0, 'empty Go run accepted'
    tests.write_text('')
    assert run(0)[0] != 0, 'shell-only mode accepted missing independent Go coverage'

# The independent workflow discovers all API test names, then deals that list by
# recorded cost (bin/go-test-shard.sh deal, claude-fleet#4817 — the union is the
# whole package, go-test-shard-selftest.sh A); the six revocation tests must each
# belong to exactly one API shard.
workflow = (root / '.github/workflows/tokenledger.yml').read_text()
assert "go test -race -list '.*' ./api/" in workflow
assert 'go-test-shard.sh deal' in workflow
assert re.search(r'go test -race -v \$COUNT -timeout 20m', workflow)
names = sorted(re.findall(r'^func (Test\w+)\(', (root / 'tokenledger/hub/api/fleet_revocations_test.go').read_text(), re.M))
assert len([n for n in names if n.startswith('TestRevocations')]) == 6
print('PASS Go-half dispatch: disabled makes zero calls; enabled exact family; failure/empty/missing coverage refused')
print('PASS independent tokenledger gate dynamically discovers the six revocation tests (structural; real Go run separate)')
PY
