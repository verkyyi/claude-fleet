#!/usr/bin/env python3
"""fleet preview register app.sock | list | renew ID | close ID.
Uses the same verified-worker MCP handler; no separate identity or proxy road.
"""
import argparse
import json
import os
from pathlib import Path
import sys


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('register', 'list', 'renew', 'close'))
    p.add_argument('value', nargs='?')
    a = p.parse_args()
    if (a.action == 'list') != (a.value is None):
        p.error('register needs a socket basename; renew/close need a preview ID; list takes no argument')
    args = {'action': a.action}
    if a.value:
        args['socket' if a.action == 'register' else 'id'] = a.value
    os.execv(sys.executable, [sys.executable, str(Path(__file__).with_name('fleet-mcp.py')),
                             '--call', 'preview', json.dumps(args)])


if __name__ == '__main__':
    main()
