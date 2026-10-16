#!/bin/bash
# Count boundaries for spinner-budget-selftest.py; no processes or clocks faked
# in its real observation. These mutations prove which extra costs must fail.
# selftest-part-of: spinner-budget-selftest.py tmux-spinner.py fleet-render-watch.py fleet_pending_tool.py
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
startup = [(0, 1, 0, 'spinner', 'tmux-spinner.sh'),
           (.01, 2, 1, 'tmux', '-L test -C attach-session'),
           (.02, 3, 1, 'bash', '/tmp/fixture/fleet-client-where.sh --json')]
ps_args = '-axo pid=,ppid=,stat=,lstart=,comm='
fresh = [(20.1, 4, 1, 'ps', ps_args), (40.1, 5, 1, 'ps', ps_args)]
checks = {'needs_check': [20, 40]}
assert budget.due_times(20, 60) == [20, 40]
assert budget.due_times(20, 44) == [20, 40]
assert budget.due_times(15, 44) == [15, 30]
assert budget.due_times(20, 44, initial=True) == [0, 20, 40]
for fixture, commands in [('idle', startup), ('maintenance', startup + fresh)]:
    result = budget.check_costs(fixture, commands, checks, 44)
    assert result['protocol_read_query_limit'] == 44
    assert result['projected_reference_processes'] == (3 if fixture == 'idle' else 5)
for name, commands, queries in [
    ('fourth startup process', startup + [(.03, 6, 1, 'extra', '')] + fresh, 44),
    ('second process in one observation', startup + fresh + [(20.2, 6, 1, 'ps', ps_args)], 44),
    ('off-schedule process', startup + fresh + [(15, 6, 1, 'ps', ps_args)], 44),
    ('extra recurring helper', startup + [fresh[0], (40.1, 5, 1, 'helper', '')], 44),
    ('wrong startup source', startup[:2] + [(.02, 3, 1, 'bash', 'other.sh')] + fresh, 44),
    ('wrong fresh parent', startup + [fresh[0], (40.1, 5, 999, 'ps', ps_args)], 44),
    ('missing second fresh observation', startup + fresh[:1], 44),
    ('45th query in 44 seconds', startup + fresh, 45),
]:
    try:
        budget.check_costs('maintenance', commands, checks, queries)
    except AssertionError:
        print('PASS rejects ' + name)
    else:
        raise AssertionError('accepted ' + name)
print('PASS 44s integer query budget and fixed-startup/unchanged-maintenance accounting')
PY

# Actual Spinner.run/check paths under a controlled clock; no real-time claim.
python3 "$BIN/spinner-budget-schedule-selftest.py"
