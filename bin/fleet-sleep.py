#!/usr/bin/env python3
"""Worker hibernation was deleted (T548, EPIC T542 C8): an idle session stays idle.

This name answers for one version: its delivery / busy / reap / restore
subcommands forward to fleet_worker_life.py (T545, C7), every hibernation one
(scan · sleep · wake · park · repark · digest · keep-awake · allow-sleep · …)
exits 0 doing nothing, and a module that loads this file gets the life
module's names. # compat-1v: 下一批删
"""
import runpy
import subprocess
import sys
from pathlib import Path

LIFE = runpy.run_path(str(Path(__file__).absolute().with_name('fleet_worker_life.py')))
globals().update({k: v for k, v in LIFE.items() if not k.startswith('__')})

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] in LIFE['ACTIONS']:
        sys.argv[0] = str(Path(__file__).absolute().with_name('fleet_worker_life.py'))
        try: sys.exit(LIFE['main']())
        except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
            print('fleet-sleep: ' + str(exc), file=sys.stderr); sys.exit(2 if sys.argv[1] == 'busy' else 1)
    sys.exit(0)
