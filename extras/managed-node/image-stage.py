#!/usr/bin/env python3
"""Lay out a previously signature-verified hub release inside the image."""
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import sys


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


if __name__ == '__main__':
    stage(*sys.argv[1:])
