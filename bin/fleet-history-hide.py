#!/usr/bin/env python3
"""Submit one reviewed owner+FID hide manifest. Dry-run unless --apply.

Reads FLEET_HUB_URL and FLEET_HISTORY_ADMIN_TOKEN from the environment. No sweep,
no discovery, no history/task/transcript deletion. --undo restores visibility.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('manifest', type=Path)
    p.add_argument('--apply', action='store_true')
    p.add_argument('--undo', action='store_true')
    a = p.parse_args()
    body = {'manifest': json.loads(a.manifest.read_text()), 'apply': a.apply, 'undo': a.undo}
    base = os.environ['FLEET_HUB_URL'].rstrip('/')
    token = os.environ['FLEET_HISTORY_ADMIN_TOKEN']
    req = urllib.request.Request(base + '/v1/fleet/history-hide', data=json.dumps(body).encode(),
                                 headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
                                          'X-Fleet-History-Review': '1'}, method='POST')
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(resp.read().decode())
    except urllib.error.HTTPError as exc:
        print(exc.read().decode(), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
