#!/usr/bin/env python3
"""Resolve only explicit identities for the destructive dash reap command."""

from pathlib import Path
import re
import subprocess
import sys


def read(*args):
    output = subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=5)
    return output[:-1] if output.endswith('\n') else output


def field(wid, name):
    return read('tmux', 'display-message', '-p', '-t', wid, '#{'+name+'}')


def resolve(target):
    if re.fullmatch(r'[@%]\d+', target):
        wid = field(target, 'window_id')
        if not re.fullmatch(r'@\d+', wid) or (target.startswith('@') and wid != target):
            raise ValueError('target disappeared')
        return wid
    handle = re.fullmatch(r'[a-z][1-9]', target)
    issue = re.fullmatch(r'(?:issue-|#)(\d+)', target)
    scratch = re.fullmatch(r'scratch-(\d+)', target)
    if not (handle or issue or scratch):
        # Diagnostic only: never act on the result of an unstable tmux target.
        try:
            current = field(target, 'window_id')
        except (OSError, subprocess.SubprocessError):
            current = '(unresolved)'
        raise ValueError(f'index/name target refused: {target!r}; currently resolves to {current!r}; use @id, %pane, handle, issue-N or scratch-N')
    windows = read('tmux', 'list-windows', '-a', '-F', '#{window_id}').splitlines()
    if not all(re.fullmatch(r'@\d+', w) for w in windows):
        raise ValueError('invalid window inventory')
    matches = set()
    for wid in dict.fromkeys(windows):
        if handle:
            matched = field(wid, '@wid') == target
        elif issue:
            matched = field(wid, '@issue') == issue[1]
        else:
            # Same strict basename rule as fleet_scratch_key. A bound worktree
            # is authoritative; only an absent binding permits the cwd fallback.
            path = field(wid, '@worktree') or field(wid, 'pane_current_path')
            key = re.fullmatch(r'(?:.*-)?scratch-(\d+)', Path(path).name)
            matched = bool(key and key[1] == scratch[1])
        if matched:
            matches.add(wid)
    if len(matches) != 1:
        raise ValueError(f'{target!r} matched {len(matches)} windows; use an explicit @id')
    return matches.pop()


def main():
    try:
        if len(sys.argv) != 2 or not sys.argv[1]:
            raise ValueError('exactly one target is required')
        print(resolve(sys.argv[1]))
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print('reap: '+str(exc), file=sys.stderr)
        return 4
    return 0


if __name__ == '__main__':
    sys.exit(main())
