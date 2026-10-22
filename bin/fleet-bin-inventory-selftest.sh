#!/bin/bash
set -eu
BIN="$(cd "$(dirname "$0")" && pwd)"
# COMPONENTS.md owns the mapping; this wrapper makes the embedded fixtures a CI test.
python3 "$BIN/fleet-bin-inventory.py" --selftest
# Keep real program names in a test source: the inventory scans its own source too.
python3 - "$BIN" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile

bin_dir = Path(sys.argv[1]).resolve()
script = bin_dir / 'fleet-bin-inventory.py'
spec = importlib.util.spec_from_file_location('inventory', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as folder:
    root = Path(folder)

    def put(path, text):
        file = root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def check_cli(expected, rows):
        for flag, render in (('--summary', module.summary), ('--tsv', module.tsv)):
            result = subprocess.run([sys.executable, str(script), '--root', str(root), flag],
                                    capture_output=True, text=True)
            assert result.returncode == expected, (flag, result.returncode, result.stderr)
            assert result.stdout == render(rows), (flag, result.stdout)

    put('docs/dev/COMPONENTS.md', (script.resolve().parent.parent /
                                'docs/dev/COMPONENTS.md').read_text())
    groups = {
        '终端看台与薄客户端': ('fleet_pending_tool.py',),
        '执行会话与跨会话协作 MCP': ('fleet_task_control.py',),
        '宿主清理与保护': ('fleet_wake_guard.py',),
        '构建与验证': ('nogh-task-acceptance.py', 'nogh-task-boundary-test.py',
                   'nogh-task-browser.mjs', 'nogh-task-deny-probe.py'),
    }
    names = [name for group in groups.values() for name in group]
    for name in names:
        put('bin/' + name, '# fixture\n')
    put('hooks/start.sh', '\n'.join(names))
    put('bin/fleet-pending-tool.sh', '# unreferenced mapped fixture\n')
    rows = module.inventory(root)
    by = {r['file']: r for r in rows}
    for component, group in groups.items():
        for name in group:
            assert by['bin/' + name]['component'].startswith(component), name
            assert by['bin/' + name]['category'] == '核心', name
    assert by['bin/fleet-pending-tool.sh']['reason'].startswith('扫描范围内无')
    check_cli(0, rows)
    unknown = ('fleet_pending_tool_future.py', 'fleet_native_proc_future.py',
               'fleet_task_control_future.py', 'nogh-task-future.py', 'fleet_wake_guard_future.py')
    for name in unknown:
        put('bin/' + name, '# fixture\n')
    put('hooks/start.sh', '\n'.join(names + list(unknown)))
    rows = module.inventory(root)
    assert '未归类\t5\n' in module.summary(rows)
    assert '待删候选\t1\n' in module.summary(rows)
    check_cli(1, rows)
    print('PASS shipped rules: eight exact owners; adjacent unknowns exit 1; orphan retained; full summary/TSV')

    # Include the ACTUAL scanner and test source, so moving literals into a
    # production file regresses this check even if the ordinary fixture passes.
    for name in (script.name, 'fleet-bin-inventory-selftest.sh'):
        put('bin/' + name, (bin_dir / name).read_text())
    for row in module.inventory(root):
        if row['file'] in {'bin/' + name for name in names}:
            assert row['production'] == ['hooks/start.sh'], row
            assert 'bin/fleet-bin-inventory-selftest.sh' in row['callers'], row
    (root / 'hooks/start.sh').unlink()
    rows = module.inventory(root)
    for row in rows:
        if row['file'] in {'bin/' + name for name in names}:
            assert row['production'] == [], row
            assert row['reason'].startswith('仅测试'), row
    check_cli(0, rows)
    print('PASS reference provenance: real test source is test-only; removing runtime callers restores eight candidates')
PY
python3 "$BIN/fleet-bin-inventory.py" --summary
