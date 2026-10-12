#!/usr/bin/env python3
"""Install the dedicated connector; token must already be in System Keychain."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from urllib.parse import urlsplit
import zipfile

p = argparse.ArgumentParser()
p.add_argument('--wheel', required=True, type=Path)
p.add_argument('--url', required=True)
a = p.parse_args()
if sys.platform != 'darwin' or os.geteuid() != 0:
    p.error('run as root on macOS')
u = urlsplit(a.url)
if u.scheme != 'wss' or not u.hostname or u.username or u.password or u.query or u.fragment or u.path != '/_fleet/us-egress':
    p.error('use the TLS ingress URL without credentials')
wheel = a.wheel.read_bytes()
if hashlib.sha256(wheel).hexdigest() != 'dc284bbc8d7c78a6c69e0c7325ab46ee5e40bb4d50e494d8131a07ef47500e9e':
    p.error('use the verified websockets-12.0-py3-none-any.whl')
subprocess.run(['/usr/bin/security', 'find-generic-password', '-a', 'fleet-us-egress', '-s',
                'fleet-us-egress', '/Library/Keychains/System.keychain'], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
label = 'com.claude-fleet.us-egress'
base = Path('/usr/local/lib/fleet-us-egress')
base.mkdir(parents=True, exist_ok=True)
base.chmod(0o755)
for name in ('us-egress.py', 'client-run.sh'):
    dst = base / name
    shutil.copyfile(Path(__file__).resolve().parent / name, dst)
    dst.chmod(0o755)
(base / 'lib').mkdir(exist_ok=True)
with zipfile.ZipFile(a.wheel) as z:
    z.extractall(base / 'lib')
# Register with the Fleet supervisor's supported root-owned expected-set extension.
keep = Path('/var/db/fleet-node/keep-labels')
keep.parent.mkdir(parents=True, exist_ok=True)
text = keep.read_text() if keep.exists() else ''
if label not in text.splitlines():
    tmp = keep.with_name('keep-labels.tmp-us-egress')
    tmp.write_text(text.rstrip() + '\n' + label + '\n')
    tmp.chmod(0o644)
    os.replace(tmp, keep)
plist = Path('/Library/LaunchDaemons/' + label + '.plist')
subprocess.run(['/bin/launchctl', 'bootout', 'system/' + label],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
with plist.open('wb') as f:
    plistlib.dump({'Label': label, 'ProgramArguments': ['/bin/bash', str(base / 'client-run.sh')],
                  'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
                  'EnvironmentVariables': {'FLEET_US_EGRESS_URL': a.url,
                                           'FLEET_US_EGRESS_CONNECTIONS': '16'},
                  'StandardOutPath': '/var/log/fleet-us-egress.log',
                  'StandardErrorPath': '/var/log/fleet-us-egress.log'}, f)
plist.chmod(0o644)
subprocess.run(['/bin/launchctl', 'bootstrap', 'system', str(plist)], check=True)
print('US connector installed; token read only at launch from System Keychain')
