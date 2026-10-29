#!/usr/bin/env python3
"""Disposable GitHub-hosted mount-namespace test; never installs on a live node."""
import argparse
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib


def native_read(binary, repository):
    assert os.geteuid() != 0
    system = Path('/etc/codex')
    assert not os.access(system / 'requirements.toml', os.W_OK)
    assert not os.access(system / 'release/current/hooks/bash-guard.py', os.W_OK)
    with tempfile.TemporaryDirectory(prefix='fleet-guard-client-') as temporary:
        home = Path(temporary)
        (home / 'config.toml').write_text('[features]\nhooks=false\n')
        socket = home / 'rpc.sock'
        environment = dict(PATH='/usr/bin:/bin', HOME=temporary, CODEX_HOME=temporary)
        client_type = runpy.run_path(str(repository / 'bin/fleet-codex-rpc.py'))['Client']
        with (home / 'server.log').open('w') as log:
            child = subprocess.Popen([binary, 'app-server', '--listen', 'unix://' + str(socket)],
                                     cwd=home, env=environment, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log)
            client = None
            try:
                deadline = time.monotonic() + 15
                while not socket.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                assert socket.exists(), 'native backend did not start'
                client = client_type('unix://' + str(socket), peer_pid=child.pid)
                requirements = client.call('configRequirements/read', {})['requirements']
                assert requirements['featureRequirements']['hooks'] is True
                assert requirements['allowedApprovalPolicies'] == ['on-request']
                assert requirements['allowedSandboxModes'] == ['read-only']
                assert requirements['hooks']['managedDir'] == '/etc/codex/release/current/hooks'
                entries = client.call('hooks/list', {'cwds': [temporary]})['data']
                hooks = [hook for entry in entries for hook in entry['hooks'] if hook.get('isManaged')]
                assert len(hooks) == 3, 'installed guards must survive user hooks=false'
                assert all(hook['source'] == 'system' and hook['trustStatus'] == 'managed'
                           and hook['enabled'] is True for hook in hooks)
            finally:
                if client is not None:
                    client.close()
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
    print(json.dumps({'installed_native_requirements': 'pass', 'unprivileged_read': 'pass'}))


def install_fixture(arguments, repository):
    assert os.geteuid() == 0 and arguments.uid > 0 and arguments.gid > 0
    assert os.stat('/proc/self/ns/mnt').st_ino != arguments.parent_namespace
    system = Path('/etc/codex')
    assert system.samefile(arguments.backing) and not list(system.iterdir())
    system.chmod(0o755)
    os.chown(system, 0, 0)
    source = system / 'release' / ('a' * 40)
    relative_files = ('bin/fleet-hooks-emit.sh', 'bin/fleet-codex-runtime.py', 'bin/fleet-node-linux.py',
                      'hooks/codex-map.json', 'hooks/settings-hooks.json',
                      'hooks/bash-guard.py', 'hooks/base-readonly-guard.py', 'hooks/studio-guard.py', 'bin/fleet_studio.py', 'bin/fleet_iso.py')
    for relative in relative_files:
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repository / relative, target)
        target.chmod(0o644)
    (source / '.release').mkdir()
    (source / '.release/staged.json').write_text('{}')
    (source / '.release/manifest.json').write_text(json.dumps({'sha': source.name}))
    current = source.parent / 'current'
    current.symlink_to(source.name)
    target = system / 'requirements.toml'
    previous = b'allowed_approval_policies=["on-request"]\nallowed_sandbox_modes=["read-only"]\n'
    target.write_bytes(previous)
    install = runpy.run_path(str(repository / 'extras/managed-node/image-stage.py'))['install_managed_guards']
    assert install(current, system, check_only=True) == 'would-install'
    assert target.read_bytes() == previous
    assert install(current, system) == 'installed'
    installed = target.read_bytes()
    assert install(current, system) == 'kept' and target.read_bytes() == installed
    policy = tomllib.loads(installed.decode())
    assert policy['allowed_approval_policies'] == ['on-request']
    assert policy['allowed_sandbox_modes'] == ['read-only']
    guard = source / 'hooks/bash-guard.py'
    guard.chmod(0o664)
    try:
        install(current, system)
    except ValueError:
        pass
    else:
        raise AssertionError('group-writable guard accepted')
    assert target.read_bytes() == installed
    guard.chmod(0o644)
    subprocess.run(['setpriv', '--reuid', str(arguments.uid), '--regid', str(arguments.gid),
                    '--init-groups', '--no-new-privs', 'env', '-i', 'PATH=/usr/bin:/bin',
                    'GITHUB_ACTIONS=true', 'RUNNER_ENVIRONMENT=github-hosted',
                    '/usr/bin/python3', str(Path(__file__).resolve()), '--client', '--codex', arguments.codex],
                   check=True, timeout=45)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex', required=True)
    parser.add_argument('--root-fixture', action='store_true')
    parser.add_argument('--client', action='store_true')
    parser.add_argument('--backing')
    parser.add_argument('--parent-namespace', type=int)
    parser.add_argument('--uid', type=int)
    parser.add_argument('--gid', type=int)
    arguments = parser.parse_args()
    assert sys.platform == 'linux' and os.environ.get('GITHUB_ACTIONS') == 'true'
    assert os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
    repository = Path(__file__).resolve().parent.parent
    if arguments.client:
        native_read(arguments.codex, repository)
        return
    if arguments.root_fixture:
        install_fixture(arguments, repository)
        return
    assert os.geteuid() != 0 and not Path('/etc/codex').exists()
    namespace = os.stat('/proc/self/ns/mnt').st_ino
    subprocess.run(['sudo', '-n', 'mkdir', '/etc/codex'], check=True)
    try:
        with tempfile.TemporaryDirectory(prefix='fleet-guard-install-') as backing:
            try:
                subprocess.run(['sudo', '-n', 'unshare', '--mount', '--propagation', 'private',
                                '/bin/sh', '-eu', '-c', 'mount --bind "$1" /etc/codex; shift; exec "$@"',
                                'fixture', backing, 'env', '-i', 'PATH=/usr/bin:/bin',
                                'GITHUB_ACTIONS=true', 'RUNNER_ENVIRONMENT=github-hosted',
                                '/usr/bin/python3', str(Path(__file__).resolve()), '--root-fixture',
                                '--codex', str(Path(arguments.codex).resolve()), '--backing', backing,
                                '--parent-namespace', str(namespace), '--uid', str(os.getuid()),
                                '--gid', str(os.getgid())], check=True, timeout=90)
            finally:
                subprocess.run(['sudo', '-n', 'chown', '-R', f'{os.getuid()}:{os.getgid()}', backing], check=True)
        assert not list(Path('/etc/codex').iterdir()), 'fixture escaped namespace'
        assert os.stat('/proc/self/ns/mnt').st_ino == namespace
    finally:
        subprocess.run(['sudo', '-n', 'rmdir', '/etc/codex'], check=True)


if __name__ == '__main__':
    main()
