#!/usr/bin/env python3
"""C7: wrapper preflight and doctor evidence; no scheduler or second wake road."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

from fleet_agent_adapter import ADAPTERS
import fleet_session_gate as gate


def recorded_version(path, field):
    """Last version-bearing record; bounded reads also cover a rollout header."""
    if not path:
        return ''
    found = ''
    try:
        with Path(path).open('rb') as stream:
            first = stream.readline(2 * 1024 * 1024)
            stream.seek(0, 2)
            size = stream.tell()
            stream.seek(max(0, size - 2 * 1024 * 1024))
            if stream.tell():
                stream.readline()  # partial JSON at the tail boundary
            chunks = [first, *stream.readlines()]
        for line in chunks:
            try:
                value = json.loads(line)
                for key in field.split('.'):
                    value = value.get(key) if isinstance(value, dict) else None
                if isinstance(value, str) and re.fullmatch(r'\d+\.\d+\.\d+(?:[-+][\w.-]+)?', value):
                    found = value
            except (ValueError, TypeError):
                continue
    except OSError:
        pass
    return found


def transcript(w, adapter):
    if adapter['transcript'] == 'project':
        return gate.claude_transcript(w['sid'])
    if adapter['transcript'] == 'home':
        # The native identity carries the exact account home and rollout; never
        # substitute the latest conversation from another account.
        import runpy
        native = runpy.run_path(str(gate.BIN / 'fleet-codex-session.py'))
        data = native['identity'](w['pane'], w['sock'])
        if data.get('session_id') == w['sid']:
            return native['rollout'](data)[0]
    return None


def local_version(adapter):
    seam = os.environ.get('FLEET_PARK_VERSION_CMD')
    cmd = shlex.split(seam) if seam else ['bash', '-c',
        '. "$1/fleet-lib.sh" >/dev/null 2>&1; p=$(fleet_find_tool "$2") && "$p" --version',
        'park-version', str(gate.BIN), adapter['park_version_tool']]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=3)
        match = re.search(r'\b\d+\.\d+\.\d+(?:[-+][\w.-]+)?', result.stdout)
        return match.group() if result.returncode == 0 and match else ''
    except (OSError, subprocess.SubprocessError):
        return ''


def prepare(path, manual=False):
    meta = gate.read_json(path) or {}
    w = gate.window(meta.get('fid', ''))
    if not w or not w['sid']:
        return ''
    adapter = ADAPTERS.get(w['agent'], {})
    if not adapter.get('park_version_field'):
        return ''
    try:
        old = recorded_version(transcript(w, adapter), adapter['park_version_field'])
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        old = ''
    current = local_version(adapter) if old else ''
    reason = '手动选择新会话，原话保留' if manual else ''
    if old and current and old.split('.')[0] != current.split('.')[0]:
        reason = '主版本不兼容（记录 %s，本机 %s），已改为新会话，原话保留' % (old, current)
    if not reason:
        return ''  # unknown is not evidence of incompatibility
    meta['fresh'] = dict(old_sid=w['sid'], reason=reason)
    gate.write_json(path, meta)
    gate.write_json(meta['seed'] + '.fresh', meta['fresh'])
    gate.tmux(w['sock'], 'set-option', '-w', '-t', w['win'], '@park_fresh_reason', reason)
    return reason


def doctor():
    for path in sorted(gate.gate_root().glob('*/park-health.json')):
        fid = path.parent.name
        if not gate.FID_RE.fullmatch(fid) or not gate.window(fid):
            continue
        health = gate.read_json(path) or {}
        if health.get('disabled'):
            print('WARN\t%s 连续接回失败，已禁止自动停放；原话仍保留' % fid)
        if health.get('fresh_reason'):
            print('INFO\t%s %s' % (fid, health['fresh_reason']))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['prepare', 'doctor'])
    p.add_argument('--meta', type=Path)
    p.add_argument('--manual', default='')
    args = p.parse_args()
    if args.command == 'doctor':
        doctor()
    elif args.meta:
        reason = prepare(args.meta, args.manual == '1')
        if reason:
            print(reason)


if __name__ == '__main__':
    main()
