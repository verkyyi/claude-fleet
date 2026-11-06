#!/usr/bin/env python3
"""Clamp native JS test runners and enter the existing machine-wide queue."""
import os
from pathlib import Path
import sys


def bounded(argv):
    # Enforce the fleet's two-worker budget even when a repository requests all
    # cores. Preserve smaller explicit limits; percentages are capped as well.
    result, maximum, minimum = [], 2, 1
    i = 0
    while i < len(argv):
        arg = argv[i]
        key, _, value = arg.partition('=')
        if key in ('--maxWorkers', '--minWorkers', '--maxThreads', '--minThreads', '-w'):
            if not value and i + 1 < len(argv):
                i += 1
                value = argv[i]
            if key in ('--maxWorkers', '--maxThreads', '-w') and value.isdigit():
                maximum = min(maximum, max(1, int(value)))
        else:
            result.append(arg)
        i += 1
    # Jest's runInBand conflicts with maxWorkers; it is already serial.
    if '--runInBand' not in result and '-i' not in result:
        result.append('--maxWorkers=%d' % maximum)
        if 'vitest' in argv[1]:
            result.append('--minWorkers=%d' % min(minimum, maximum))
    return result


def main():
    argv = bounded(sys.argv[1:])
    env = dict(os.environ, VITEST_MAX_WORKERS='2', VITEST_MIN_WORKERS='1',
               VITEST_MAX_THREADS='2', VITEST_MIN_THREADS='1')
    wrapper = Path(__file__).resolve().with_name('fleet-heavy.sh')
    os.execve(str(wrapper), [str(wrapper), '--label', 'js-tests', '--', *argv], env)


if __name__ == '__main__':
    main()
