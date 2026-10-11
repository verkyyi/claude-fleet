#!/usr/bin/env python3
"""The image's own half of a Linux managed node (#3022, #3212).

  stage <src> <seed>   build time: lay out a signature-verified hub release as
                       <seed>/<sha> + <seed>/current (the image's version)
  boot [args…]         container start: seed the disk runtime from the image when
                       it has none, or when the image's signed seq is newer and
                       the updater is at rest; then exec <root>/current's
                       fleet-node-linux.py foreground [args…]
  live                 liveness: the foreground loop's heartbeat is fresh

After the first boot the runtime on the persistent volume is the machine
updater's (fleet-node-update.py), exactly as on a Mac: a container restart
never puts the image's older version back (BREAK-IT linux-image-pins-old).
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
import time

SHA = re.compile('[0-9a-f]{40}')
SEED = os.environ.get('FLEET_NODE_SEED', '/opt/claude-fleet/seed')
HEARTBEAT = os.environ.get('FLEET_NODE_HEARTBEAT', '/run/fleet-node-loop')


def stage(src, root):
    src, root = Path(src), Path(root)
    manifest = json.loads((src / '.release/manifest.json').read_text())
    spec = json.loads((src / 'release.json').read_text())
    sha = manifest['sha']
    if not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('invalid release SHA')
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine(), platform.machine())
    artifacts = {x['name']: x for x in manifest['artifacts']}
    selected = []
    got = {'release': sha}
    for tool in ('ccquota', 'claude', 'codex', 'tmux'):
        component = spec['components'][tool]
        binaries = {tool: component['artifact'], **component.get('helpers', {})}
        for binary, template in binaries.items():
            if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', binary):
                raise ValueError('invalid tool/helper name')
            name = template.format(os='linux', arch=arch, version=component.get('version', ''))
            if Path(name).name != name or name in ('.', '..'):
                raise ValueError('invalid artifact name')
            file = src / '.release/artifacts' / name
            if file.is_symlink() or hashlib.sha256(file.read_bytes()).hexdigest() != artifacts[name]['sha256']:
                raise ValueError('artifact checksum mismatch: ' + name)
            selected.append((binary, file))
            got[binary] = component.get('version', artifacts[name]['sha256'])
    root.mkdir(parents=True, exist_ok=True)
    dest = root / sha
    if dest.exists() or (root / 'current').exists():
        raise ValueError('image runtime already exists')
    shutil.move(str(src), dest)
    for tool, file in selected:
        target = dest / ('bin' if tool == 'ccquota' else 'tools/bin') / tool
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(dest / file.relative_to(src), target)
        target.chmod(0o755)
    (dest / '.release/staged.json').write_text(json.dumps(got) + '\n')
    (root / 'current').symlink_to(sha)
    print('image runtime: ' + sha)


def release_dir_ok(d):
    return (d / '.release/staged.json').is_file() and (d / 'bin/fleet-node-linux.py').is_file()


def release(link):
    """(sha, signed seq) of the staged release a `current` link names, or None."""
    try:
        sha = os.path.basename(os.readlink(link))
    except OSError:
        return None
    d = Path(link).parent / sha
    if not SHA.fullmatch(sha) or not release_dir_ok(d):
        return None
    try:
        seq = int(json.loads((d / '.release/manifest.json').read_text()).get('seq') or 0)
    except (OSError, ValueError, TypeError):
        seq = 0
    return sha, seq


def swap(link, target):
    tmp = '%s.tmp-%d' % (link, os.getpid())
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    os.symlink(target, tmp)
    os.replace(tmp, link)


def seed(seed_root, root, state, force=False):
    """The disk runtime <root> from the image's <seed_root>; returns one word:
    seeded (none on disk) · newer (the image's seq is past the disk's) · kept.
    force (FLEET_NODE_UPDATE_OWNER=image, the self-update off): the image's
    version, whatever the disk holds — the old image-owned way."""
    seed_root, root = Path(seed_root), Path(root)
    img = release(seed_root / 'current')
    if img is None:
        raise ValueError('the image has no staged runtime under %s' % seed_root)
    disk = release(root / 'current')
    if disk is not None and disk[0] == img[0]:
        return 'kept'
    if disk is not None and not force:
        if img[1] <= disk[1]:
            return 'kept'
        # a switch the updater has under way is its own to finish (or roll back)
        try:
            phase = json.loads((Path(state) / 'update.json').read_text()).get('phase')
        except (OSError, ValueError):
            phase = None
        if phase not in (None, 'idle'):
            return 'kept'
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o755)
    dest = root / img[0]
    if not release_dir_ok(dest):
        part = root / (img[0] + '.seed-partial')
        shutil.rmtree(part, ignore_errors=True)
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(seed_root / img[0], part, symlinks=True)
        os.rename(part, dest)
    if disk is not None:
        swap(root / '.prev', disk[0])
    swap(root / 'current', img[0])
    return 'newer' if disk is not None else 'seeded'


def boot(args):
    root = os.environ.get('FLEET_NODE_ROOT', '/var/db/fleet-node/runtime')
    state = os.environ.get('FLEET_NODE_STATE', '/var/db/fleet-node')
    os.makedirs(state, exist_ok=True)
    # the same PVC lock foreground holds: one writer seeds
    with open(os.path.join(state, 'container.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        word = seed(SEED, root, state, force=os.environ.get('FLEET_NODE_UPDATE_OWNER') == 'image')
    cur = release(os.path.join(root, 'current'))
    print('fleet-image: runtime %s %s' % (word, cur[0][:12]), file=sys.stderr)
    script = os.path.join(root, cur[0], 'bin', 'fleet-node-linux.py')
    os.execv(sys.executable, [sys.executable, '-I', script, 'foreground'] + list(args))


def live(max_age=None):
    """The loop is alive: its heartbeat names a live pid and moved lately.
    A supervisor restarting for a new release never fails this (#3212)."""
    max_age = max_age or int(os.environ.get('FLEET_NODE_HEARTBEAT_SECS', '120'))
    try:
        st = os.stat(HEARTBEAT)
        pid = int(Path(HEARTBEAT).read_text().split()[0])
        os.kill(pid, 0)
    except (OSError, ValueError, IndexError):
        return 1
    return 0 if time.time() - st.st_mtime <= max_age else 1


if __name__ == '__main__':
    verb, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ('', [])
    if verb == 'boot':
        boot(rest)
    elif verb == 'live':
        sys.exit(live())
    elif verb == 'seed':
        print(seed(*rest))
    elif verb == 'stage' and len(rest) == 2:
        stage(*rest)
    elif len(sys.argv) == 3:   # the old form: <src> <root>
        stage(*sys.argv[1:])
    else:
        sys.exit('usage: image-stage.py stage <src> <seed> | seed <seed> <root> <state> | boot | live')
