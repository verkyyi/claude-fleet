#!/usr/bin/env python3
"""Start new macOS fleet servers in Aqua; never replace a live server (T1332)."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time


def run(argv):
    return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=10)


def alive(sock):
    # list-sessions returns nonzero for a resident server with no sessions.
    return run(['tmux', '-L', sock, '-N', 'show-options', '-s', 'exit-empty']).returncode == 0


def job(label, tmux, sock, conf, log):
    # Deliberate allowlist: no worker credentials, tokens, TMUX or pane binding
    # may enter a plist or the environment of another session's server.
    env = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME', 'PATH', 'LANG',
           'LC_ALL', 'TMPDIR', 'TMUX_TMPDIR', 'FLEET_CONF_DIR') if k in os.environ}
    return {'Label': label, 'ProgramArguments': [tmux, '-D', '-L', sock, '-f', conf],
            'EnvironmentVariables': env, 'RunAtLoad': True,
            'LimitLoadToSessionType': 'Aqua', 'ProcessType': 'Interactive',
            'StandardOutPath': log, 'StandardErrorPath': log}


def real_tmux():
    # A worker's safety shim must not be the resident LaunchAgent executable.
    found = shutil.which('tmux')
    if found and Path(found).parent.name != 'tmux-shim':
        return found
    for directory in os.environ.get('PATH', '').split(os.pathsep):
        p = Path(directory) / 'tmux'
        if p.parent.name != 'tmux-shim' and p.is_file() and os.access(p, os.X_OK):
            return str(p.resolve())
    raise RuntimeError('tmux executable not found')


def ensure(sock, conf):
    if alive(sock):
        return  # Existing Background servers need an operator-approved migration.
    domain = 'gui/%d' % os.getuid()
    if run(['launchctl', 'print', domain]).returncode:
        raise RuntimeError('%s unavailable; sign in to this macOS account graphically before starting fleet; no Background fallback' % domain)
    identity = os.environ.get('TMUX_TMPDIR', '/tmp') + '/' + sock + '/' + conf
    label = 'com.claude-fleet.tmux.' + hashlib.sha256(identity.encode()).hexdigest()[:20]
    target = domain + '/' + label
    root = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet'))) / 'launchd-tmux'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    plist = root / (label + '.plist')
    if run(['launchctl', 'print', target]).returncode:
        # Atomic and private; the only files we create are below launchd-tmux.
        temp = root / (label + '.%d.tmp' % os.getpid())
        try:
            with temp.open('xb') as f:
                os.chmod(temp, 0o600)
                plistlib.dump(job(label, real_tmux(), sock, conf, str(root / (label + '.log'))), f)
            temp.replace(plist)
        finally:
            temp.unlink(missing_ok=True)
        result = run(['launchctl', 'bootstrap', domain, str(plist)])
        if result.returncode and run(['launchctl', 'print', target]).returncode:
            raise RuntimeError('bootstrap %s failed: %s' % (domain, result.stderr.strip()))
    else:
        # No -k: an already running job is never terminated. A deliberately
        # stopped server can start again without booting out a launchd service.
        run(['launchctl', 'kickstart', target])
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if alive(sock):
            return
        time.sleep(0.1)
    raise RuntimeError('%s did not create its socket; inspect %s (no server was killed)' % (target, root / (label + '.log')))


def stamp():
    """Called BY tmux/run-shell or a pane, never by a background collector."""
    if sys.platform != 'darwin' or not os.environ.get('TMUX'):
        return
    try:
        manager = run(['launchctl', 'managername']).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        manager = 'unknown'
    if manager not in ('Aqua', 'Background', 'LoginWindow', 'System', 'StandardIO'):
        manager = 'unknown'
    warning = '' if manager == 'Aqua' else 'launchd: ' + manager
    run(['tmux', 'set-option', '-g', '@launchd_warning', warning])


def main():
    try:
        if sys.argv[1:] == ['--stamp']:
            stamp()
        elif len(sys.argv) == 3:
            ensure(sys.argv[1], sys.argv[2])
        else:
            raise RuntimeError('usage: fleet-launchd-tmux.py <socket> <config> | --stamp')
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as e:
        print('fleet launchd: %s' % e, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
