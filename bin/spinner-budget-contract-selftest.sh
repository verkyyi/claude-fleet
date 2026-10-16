#!/bin/bash
# Count boundaries for spinner-budget-selftest.py; no processes or clocks faked
# in its real observation. These mutations prove which extra costs must fail.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import importlib.util
from pathlib import Path
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('budget', Path(sys.argv[1]) / 'spinner-budget-selftest.py')
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)
startup = [(0, 1, 0, 'spinner'), (.01, 2, 1, 'tmux'), (.02, 3, 1, 'lease')]
fresh = [(20.1, 4, 1, 'ps'), (40.1, 5, 1, 'ps')]
checks = {'needs_check': [20, 40]}
assert budget.due_times(20, 60) == [20, 40]
assert budget.due_times(20, 42) == [20, 40]
assert budget.due_times(15, 42) == [15, 30]
assert budget.due_times(20, 42, initial=True) == [0, 20, 40]
for fixture, commands in [('idle', startup), ('maintenance', startup + fresh)]:
    result = budget.check_costs(fixture, commands, checks, 42)
    assert result['protocol_read_query_limit'] == 42
    assert result['projected_reference_processes'] == (3 if fixture == 'idle' else 5)
for name, commands, queries in [
    ('fourth startup process', startup + [(.03, 6, 1, 'extra')] + fresh, 42),
    ('second process in one observation', startup + fresh + [(20.2, 6, 1, 'ps')], 42),
    ('off-schedule process', startup + fresh + [(15, 6, 1, 'ps')], 42),
    ('extra recurring helper', startup + [fresh[0], (40.1, 5, 1, 'helper')], 42),
    ('missing second fresh observation', startup + fresh[:1], 42),
    ('43rd query in 42 seconds', startup + fresh, 43),
]:
    try:
        budget.check_costs('maintenance', commands, checks, queries)
    except AssertionError:
        print('PASS rejects ' + name)
    else:
        raise AssertionError('accepted ' + name)
print('PASS 42s integer query budget and fixed-startup/unchanged-maintenance accounting')
PY
