#!/bin/bash
# The old command paths remain callable for one version, but never arrange
# dispatch, a periodic driver or a closing report. Historical tick readers stay.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in ('plan', 'run', 'report'):
    text = (root / f'plugins/fleet-epic/commands/fleet-epic-{name}.md').read_text()
    assert 'EPIC_RETIRED' in text and 'compat-1v' in text, name
    for removed in ('mcp__fleet-orch__task', 'fleet-epic-tick.py status', 'fleet_task_control.py progress',
                    'report: pending', 'Run `/fleet-epic-report` right here'):
        assert removed not in text, (name, removed)
    assert '/fleet-task-plan' in text, name
assert (root / 'bin/fleet-epic-tick.py').is_file(), 'historical reader must remain'
print('epic-autoreport-selftest OK (retired entrypoints; historical reader retained)')
PY
