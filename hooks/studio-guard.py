#!/usr/bin/env python3
"""Native remote space calls in studio sessions obey the right-panel receipts.

New studio sessions read this hook at launch. Existing ordinary sessions keep
their prior behavior; the gateway uses the same guard for stdio space servers.
This is a misuse rail, not isolation from arbitrary code run by the same login.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'bin'))
from fleet_studio import guard_space, root


def main():
    if not (root() / 'studio.json').exists() or not os.environ.get('TMUX_PANE'):
        return
    data = json.load(sys.stdin)
    name = data.get('tool_name', '')
    prefix = 'mcp__space__'
    if not name.startswith(prefix):
        return
    fid = subprocess.check_output(['tmux', 'display-message', '-p', '-t', os.environ['TMUX_PANE'], '#{@fleet_id}'],
                                  text=True, timeout=3).strip()
    if not fid:
        raise ValueError('cannot verify studio session identity')
    guard_space(fid, name[len(prefix):], data.get('tool_input') or {})


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('活页工作台：' + str(exc), file=sys.stderr)
        sys.exit(2)
