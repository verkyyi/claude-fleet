#!/bin/bash
# Driver verdict/counter regressions; full boundaries run in task-acceptance.yml.
# selftest-deps: nogh-task-acceptance.py nogh-task-boundary-test.py nogh-task-browser.mjs
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN" <<'PY'
import importlib.util
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("acceptance", Path(sys.argv[1])/"nogh-task-acceptance.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert not m.valid_output("go", "PASS\n", ["TestMissing"])
assert not m.valid_output("go", "--- SKIP: TestMissing (0s)\nPASS\n", ["TestMissing"])
assert m.valid_output("go", "--- PASS: TestReal (0.01s)\nPASS\n", ["TestReal"])
assert not m.valid_output("python", "Ran 0 tests\nOK\n")
assert not m.valid_output("python", "Ran 1 test\nOK (skipped=1)\n")
assert m.valid_output("python", "Ran 1 test in 0.1s\n\nOK\n")
assert not m.valid_output("baseline", "steps: 6/7 · gh calls: 0 · github http: 0")
trace = '''42 connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("192.0.2.1")}, 16) = -1 ENETUNREACH
42 connect(3, {sa_family=AF_INET, sin_port=htons(80), sin_addr=inet_addr("127.0.0.1")}, 16) = 0
43 connect(3, {sa_family=AF_INET6, sin6_port=htons(443), inet_pton(AF_INET6, "2001:db8::1", &sin6_addr)}, 28) = -1 ENETUNREACH
43 sendto(3, "", 0, 0, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("192.0.2.2")}, 16) = -1 ENETUNREACH
'''
assert m.network_counts(trace) == dict(external_http=2, other_external=1)
try:
    m.network_counts('connect(3, {sa_family=AF_INET, unrecognized}, 16) = -1')
except ValueError:
    pass
else:
    raise AssertionError("unknown trace silently counted as zero")
with tempfile.TemporaryDirectory() as temp:
    h = m.Harness(Path(temp))
    assert h.finish() == 1  # empty/missing evidence is never twelve green rows
    import json
    report = json.loads((Path(temp)/"evidence/acceptance.json").read_text())
    assert len(report["rows"]) == 12 and all(r["live"] == "NOT RUN" for r in report["rows"])
print("PASS acceptance requires executed boundaries and keeps live evidence separate; IPv4/IPv6/CLI/DNS counters fail closed")
PY
