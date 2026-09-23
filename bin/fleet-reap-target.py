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


def window_repo(wid):
    """The window's repo (owner/name): @repo when stamped, else its @worktree's
    git origin. Empty when unknown or @norepo — an unknown never matches."""
    repo = field(wid, '@repo')
    if repo or field(wid, '@norepo') == '1':
        return repo
    worktree = field(wid, '@worktree')
    if not worktree:
        return ''
    try:
        url = read('git', '-C', worktree, 'remote', 'get-url', 'origin')
    except (OSError, subprocess.SubprocessError):
        return ''
    url = re.sub(r'^git@[^:]*:|^https?://[^/]*/', '', url)
    url = re.sub(r'/+$', '', re.sub(r'\.git$', '', url))
    return url if re.fullmatch(r'[^/]+/[^/]+', url) else ''


def repo_matches(repo, want):
    return bool(repo) and want in (repo, repo.replace('/', '-'), repo.split('/', 1)[1])


def resolve(target):
    if re.fullmatch(r'[@%]\d+', target):
        wid = field(target, 'window_id')
        if not re.fullmatch(r'@\d+', wid) or (target.startswith('@') and wid != target):
            raise ValueError('target disappeared')
        return wid
    handle = re.fullmatch(r'[a-z][1-9]', target)
    issue = re.fullmatch(r'(?:issue-|#)(\d+)', target)
    # <repo>#N / <repo>:issue-N (issue #790): in a fleet hosting several repos a
    # bare #N can name two windows; the qualified form names one. <repo> is
    # owner/name, its slug (owner-name) or the bare name.
    qual = re.fullmatch(r'([A-Za-z0-9._/-]+)(?:#|:issue-)(\d+)', target)
    if qual and not issue:
        issue = qual
        want_repo = qual[1]
    else:
        want_repo = None
    scratch = re.fullmatch(r'scratch-(\d+)', target)
    if not (handle or issue or scratch):
        # Diagnostic only: never act on the result of an unstable tmux target.
        try:
            current = field(target, 'window_id')
        except (OSError, subprocess.SubprocessError):
            current = '(unresolved)'
        raise ValueError(f'index/name target refused: {target!r}; currently resolves to {current!r}; use @id, %pane, handle, issue-N, <repo>#N or scratch-N')
    windows = read('tmux', 'list-windows', '-a', '-F', '#{window_id}').splitlines()
    if not all(re.fullmatch(r'@\d+', w) for w in windows):
        raise ValueError('invalid window inventory')
    matches = set()
    for wid in dict.fromkeys(windows):
        if handle:
            matched = field(wid, '@wid') == target
        elif issue:
            matched = field(wid, '@issue') == issue[issue.lastindex]
            if matched and want_repo is not None:
                matched = repo_matches(window_repo(wid), want_repo)
        else:
            # Same strict basename rule as fleet_scratch_key. A bound worktree
            # is authoritative; only an absent binding permits the cwd fallback.
            path = field(wid, '@worktree') or field(wid, 'pane_current_path')
            key = re.fullmatch(r'(?:.*-)?scratch-(\d+)', Path(path).name)
            matched = bool(key and key[1] == scratch[1])
        if matched:
            matches.add(wid)
    if len(matches) != 1:
        hint = 'an explicit @id'
        if issue and want_repo is None and len(matches) > 1:
            repos = sorted({window_repo(w) or '?' for w in matches})
            hint = 'an explicit @id or <repo>#'+issue[1]+' ('+', '.join(repos)+')'
        raise ValueError(f'{target!r} matched {len(matches)} windows; use {hint}')
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
