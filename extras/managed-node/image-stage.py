#!/usr/bin/env python3
"""The image's own half of a Linux managed node (#3022, #3212).

  stage <src> <seed>   build time: lay out a signature-verified hub release as
                       <seed>/<sha> + <seed>/current (the image's version)
  boot [args…]         container start: seed the disk runtime from the image when
                       it has none, or when the image's signed seq is newer and
                       the updater is at rest; then exec <root>/current's
                       fleet-node-linux.py foreground [args…]
  live                 liveness: the foreground loop's heartbeat is fresh
  need <src> <arch>    the artifact names stage takes for linux-<arch>, one a line
                       (prepare-image.sh checks its context against them)

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
import runpy
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time

SHA = re.compile('[0-9a-f]{40}')
SEED = os.environ.get('FLEET_NODE_SEED', '/opt/claude-fleet/seed')
HEARTBEAT = os.environ.get('FLEET_NODE_HEARTBEAT', '/run/fleet-node-loop')


def wanted(spec, arch):
    """[(binary, artifact name)] stage takes from a release for linux-<arch>:
    each tool's artifact and its helpers (#3017: codex's codex-code-mode-host)
    — the ONE list, read by stage and by prepare-image.sh (`need`)."""
    out = []
    for tool in ('ccquota', 'claude', 'codex', 'tmux'):
        component = spec['components'][tool]
        binaries = {tool: component['artifact'], **component.get('helpers', {})}
        for binary, template in binaries.items():
            if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', binary):
                raise ValueError('invalid tool/helper name')
            name = template.format(os='linux', arch=arch, version=component.get('version', ''))
            if Path(name).name != name or name in ('.', '..'):
                raise ValueError('invalid artifact name')
            out.append((tool, binary, name))
    return out


def need(src, arch):
    """The artifact names stage will want from <src>, one a line."""
    spec = json.loads((Path(src) / 'release.json').read_text())
    return [name for _t, _b, name in wanted(spec, arch)]


def stage_managed_guards(source, published, staged=None):
    """Prepare an inactive native configuration inside the version being staged."""
    source, published = Path(source).resolve(), Path(published).resolve()
    mapping = source / 'hooks/codex-map.json'
    if not mapping.exists() and not mapping.is_symlink():
        marker = source / '.release/staged.json'
        if marker.is_file() and 'codex_managed_preview' in json.loads(marker.read_text()):
            raise ValueError('staged managed guard configuration has lost its mapping')
        return False
    if not mapping.is_file() or mapping.resolve() != mapping:
        raise ValueError('managed guard mapping is not a regular release file')
    declared = json.loads(mapping.read_text())
    if not isinstance(declared, dict):
        raise ValueError('managed guard mapping must be an object')
    if 'managed_commands' not in declared:
        marker = source / '.release/staged.json'
        if marker.is_file() and 'codex_managed_preview' in json.loads(marker.read_text()):
            raise ValueError('staged managed guard configuration has lost its registration')
        return False
    import tomllib
    emitter = source / 'bin/fleet-hooks-emit.sh'
    metadata = source / '.release'
    if (not emitter.is_file() or emitter.resolve() != emitter or not metadata.is_dir()
            or metadata.resolve() != metadata):
        raise ValueError('managed guard staging requires regular release paths')
    result = subprocess.run(
        ['/bin/bash', str(emitter), '--target', 'codex-managed', '--managed-dir', str(published / 'hooks'),
         '--python', '/usr/bin/python3'],
        env={'PATH': '/usr/bin:/bin'}, cwd=source, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=15, check=True)
    rendered = tomllib.loads(result.stdout)
    if rendered['hooks']['managed_dir'] != str(published / 'hooks'):
        raise ValueError('managed guard staging produced a different runtime path')
    for group in rendered['hooks']['PreToolUse']:
        for hook in group['hooks']:
            argv = shlex.split(hook['command'])
            if len(argv) != 3 or argv[:2] != ['/usr/bin/python3', '-I']:
                raise ValueError('managed guard staging requires the isolated system interpreter')
            relative = Path(argv[2]).relative_to(published / 'hooks')
            script = source / 'hooks' / relative
            if not script.is_file() or script.resolve() != script:
                raise ValueError('managed guard script is missing or linked outside its release')
    target = metadata / 'staged.json'
    if staged is None:
        if not target.is_file() or target.is_symlink():
            raise ValueError('managed guard staging requires regular release metadata')
        staged = json.loads(target.read_text())
    if not isinstance(staged, dict):
        raise ValueError('managed guard release metadata must be an object')
    staged = dict(staged, codex_managed_preview=result.stdout)
    descriptor, temporary = tempfile.mkstemp(prefix='.codex-managed-', dir=metadata)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps(staged) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


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
    for tool, binary, name in wanted(spec, arch):
        component = spec['components'][tool]
        file = src / '.release/artifacts' / name
        if name not in artifacts:
            raise ValueError('the release carries no artifact ' + name)
        if not file.is_file():
            raise ValueError('the build context lacks %s (prepare-image.sh checks this; re-run it)' % name)
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
    # the logins' bytecode, made here as root (issue #3318): a login cannot write
    # it beside root's modules, so without it every ⌘P compiled fleet_view.py again
    subprocess.run([sys.executable, '-I', '-m', 'compileall', '-q', str(dest / 'bin')],
                   stdin=subprocess.DEVNULL, check=False)
    if not stage_managed_guards(dest, dest, got):
        (dest / '.release/staged.json').write_text(json.dumps(got) + '\n')
    (root / 'current').symlink_to(sha)
    print('image runtime: ' + sha)


def managed_root_owned(path):
    for initial in (Path(path).absolute(), Path(path).resolve()):
        for candidate in (initial, *initial.parents):
            try:
                info = candidate.lstat()
            except OSError:
                return False
            if info.st_uid != 0 or (not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o022):
                return False
    return True


def install_managed_guards(current, system, check_only=False):
    """Explicit root-only policy installation; never called by stage/seed/boot."""
    import tomllib
    if os.geteuid() != 0:
        raise ValueError('managed guard installation requires the administrator')
    current, system = Path(current).absolute(), Path(system).absolute()
    source = current.resolve()
    if (current.name != 'current' or not current.is_symlink() or not SHA.fullmatch(source.name)
            or source.parent != current.parent.resolve() or not release_dir_ok(source)):
        raise ValueError('managed guards require an existing staged current release')
    if not system.is_dir() or system.is_symlink():
        raise ValueError('managed requirements directory must already exist and cannot be linked')
    required = ('bin/fleet-hooks-emit.sh', 'bin/fleet-codex-runtime.py', 'hooks/codex-map.json',
                'hooks/settings-hooks.json', '.release/manifest.json', '.release/staged.json')
    if not all(managed_root_owned(path) for path in (current, system, '/bin/bash', '/usr/bin/python3')):
        raise ValueError('managed guard paths must be root-owned and not writable by other users')
    for relative in required:
        path = source / relative
        if not path.is_file() or path.resolve() != path or not managed_root_owned(path):
            raise ValueError('managed guard release input is not a protected regular file: ' + relative)
    if json.loads((source / '.release/manifest.json').read_text()).get('sha') != source.name:
        raise ValueError('managed guard manifest does not match the active release')
    result = subprocess.run(
        ['/bin/bash', str(source / 'bin/fleet-hooks-emit.sh'), '--target', 'codex-managed',
         '--managed-dir', str(current / 'hooks'), '--python', '/usr/bin/python3'],
        env={'PATH': '/usr/bin:/bin'}, cwd=source, stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=15, check=True)
    generated = tomllib.loads(result.stdout)
    if generated.get('features') != {'hooks': True} or generated['hooks']['managed_dir'] != str(current / 'hooks'):
        raise ValueError('managed guard renderer produced a different policy destination')
    for group in generated['hooks']['PreToolUse']:
        for hook in group['hooks']:
            argv = shlex.split(hook['command'])
            if len(argv) != 3 or argv[:2] != ['/usr/bin/python3', '-I']:
                raise ValueError('managed guards require the isolated system interpreter')
            script = Path(argv[2])
            if (script.parent != current / 'hooks' or not script.is_file() or script.is_symlink()
                    or script.resolve().parent != source / 'hooks' or not managed_root_owned(script)):
                raise ValueError('managed guard script is not protected inside the active release')
    serialize = runpy.run_path(str(source / 'bin/fleet-codex-runtime.py'))['toml_value']
    directory = os.open(system, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        target = system / 'requirements.toml'
        if target.is_symlink() or (target.exists() and (not target.is_file() or not managed_root_owned(target))):
            raise ValueError('existing requirements are not a protected regular file')
        previous = target.read_bytes() if target.exists() else None
        previous_stat = target.stat() if previous is not None else None
        existing = tomllib.loads(previous.decode('utf-8')) if previous is not None else {}
        features = existing.get('features', {})
        if not isinstance(features, dict) or features.get('hooks', True) is not True:
            raise ValueError('existing requirements conflict with managed hooks; nothing changed')
        if 'hooks' in existing and existing['hooks'] != generated['hooks']:
            raise ValueError('existing hook policy is not this exact Fleet policy; administrator review required')
        merged = dict(existing, features=dict(features, hooks=True), hooks=generated['hooks'])
        output = ''.join(json.dumps(key) + ' = ' + serialize(value) + '\n' for key, value in merged.items()).encode('utf-8')
        if tomllib.loads(output.decode('utf-8')) != merged:
            raise ValueError('managed requirements serialization did not preserve policy values')
        if current.resolve() != source:
            raise ValueError('active release changed during managed guard validation')
        if existing == merged:
            return 'kept'
        if check_only:
            return 'would-install'
        descriptor, temporary = tempfile.mkstemp(prefix='.fleet-requirements-', dir=system)
        try:
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(output)
                os.fchmod(stream.fileno(), stat.S_IMODE(previous_stat.st_mode) if previous_stat else 0o644)
                if previous_stat:
                    os.fchown(stream.fileno(), previous_stat.st_uid, previous_stat.st_gid)
                stream.flush()
                os.fsync(stream.fileno())
            if (target.is_symlink() or (target.read_bytes() if target.exists() else None) != previous
                    or current.resolve() != source):
                raise ValueError('requirements or active release changed before publication')
            os.replace(temporary, target)
            os.fsync(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return 'installed'
    finally:
        os.close(directory)


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


def prune(root):
    """Every version dir under <root> but `current` and `.prev`, and any
    `.seed-partial` left by a killed copy — gone; returns the names removed.
    Only for an image-owned runtime (#4283): no updater runs there to retire
    a version, and a person's pod copied 1.3 GB per new image onto its PVC
    until the disk guard refused new sessions. Run at boot, before anything
    starts from the runtime, so no process can stand on what goes."""
    root = Path(root)
    keep = set()
    for link in ('current', '.prev'):
        try:
            keep.add(os.path.basename(os.readlink(root / link)))
        except OSError:
            pass
    gone = []
    for d in sorted(root.iterdir()) if root.is_dir() else []:
        n = d.name
        if n in keep or d.is_symlink() or not d.is_dir():
            continue
        if SHA.fullmatch(n) or (n.endswith('.seed-partial') and SHA.fullmatch(n[:-len('.seed-partial')])):
            shutil.rmtree(d, ignore_errors=True)
            gone.append(n)
    return gone


def seed(seed_root, root, state, force=False):
    """The disk runtime <root> from the image's <seed_root>; returns one word:
    seeded (none on disk) · newer (the image's seq is past the disk's) · kept.
    force (FLEET_NODE_UPDATE_OWNER=image, the self-update off): the image's
    version, whatever the disk holds — the old image-owned way — and only
    `current` and `.prev` stay on the disk (prune)."""
    word = _seed(seed_root, root, state, force)
    if force:
        for n in prune(root):
            print('fleet-image: pruned runtime %s' % n[:12], file=sys.stderr)
    return word


def _seed(seed_root, root, state, force):
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
        stage_managed_guards(part, seed_root / img[0] if force else dest)
        os.rename(part, dest)
    else:
        stage_managed_guards(dest, seed_root / img[0] if force else dest)
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
    elif verb == 'need' and len(rest) == 2:
        print('\n'.join(need(*rest)))
    elif verb == 'stage' and len(rest) == 2:
        stage(*rest)
    elif verb == 'guards-install' and (len(rest) == 2 or len(rest) == 3 and rest[2] == '--check'):
        print(install_managed_guards(*rest[:2], check_only=len(rest) == 3))
    elif len(sys.argv) == 3:   # the old form: <src> <root>
        stage(*sys.argv[1:])
    else:
        sys.exit('usage: image-stage.py stage <src> <seed> | need <src> <arch> | seed <seed> <root> <state> | guards-install <current> <system-dir> [--check] | boot | live')
