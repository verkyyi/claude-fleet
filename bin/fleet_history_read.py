#!/usr/bin/env python3
"""Read an exact local FID's native history. No tmux, worker, or agent launch."""
import json
import os
from pathlib import Path
import runpy
import sys
import fleet_id


def codex_source(sid, home):
    reader = runpy.run_path(str(Path(__file__).with_name('fleet-codex-session.py')))
    return reader['rollout']({'session_id': sid, 'home': str(home)})


def landing(fid, sid):
    """An imported rollout is a receipt only for its recorded FID and native ID.

    Older moves did not append placement events; their verified import already
    keeps both IDs and rewrites the native cwd to the landing worktree.
    """
    if not fleet_id.is_fid(sid):
        return {}
    home = Path(fleet_id.conf_dir()) / 'moves' / 'codex' / sid
    try:
        receipt = json.loads((home / 'move.json').read_text())
        if (receipt.get('format') != 1 or receipt.get('agent') != 'codex'
                or receipt.get('sid') != sid or receipt.get('metadata', {}).get('@fleet_id') != fid):
            return {}
        path, meta = codex_source(sid, home)
        if path and os.path.isabs(meta.get('cwd', '')):
            return {'worktree': meta['cwd'], 'codex_home': str(home), 'transcript': path}
    except (OSError, ValueError, TypeError):
        pass
    return {}


def history(fid, seg=None):
    if not fleet_id.is_fid(fid):
        raise ValueError('expected a full FID')
    rec = fleet_id.fold(fleet_id.read(fid))
    if not rec['opened']:
        return {'history_status': 'offline_unknown', 'reason': 'No local identity ledger'}
    if not rec['segments']:
        return {'history_status': 'never_started', 'reason': 'No recorded native segment'}
    p = fleet_id.continue_plan(fid, seg)
    sid, agent = p['native'], p['agent']
    out = dict(p, sid=sid, state='ended', busy=False, historical=True, can_talk=False)
    path = p.get('transcript', '')
    if not path and agent == 'codex':
        homes = [p.get('codex_home'), os.environ.get('CODEX_HOME'), str(Path.home() / '.codex')]
        for home in dict.fromkeys(h for h in homes if h):
            path, _ = codex_source(sid, home)
            if path:
                out['codex_home'] = home
                break
    elif not path and agent == 'claude' and fleet_id.is_fid(sid):
        root = Path(os.environ.get('CLAUDE_PROJECTS_DIR') or str(Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude'))) / 'projects'))
        for candidate in root.glob('*/' + sid + '.jsonl'):
            # Filename plus a native sessionId witness, never title/cwd/recency.
            with candidate.open() as stream:
                for line in stream:
                    try:
                        if json.loads(line).get('sessionId') == sid:
                            path = str(candidate)
                            break
                    except (ValueError, AttributeError):
                        continue
            if path:
                break
    readable = bool(path and os.path.isfile(path) and os.access(path, os.R_OK))
    resumable = readable and (not p['repo'] or os.path.isdir(p['worktree']))
    out.update(transcript=path if readable else '', readable=readable, resumable=resumable,
               history_status='resumable' if resumable else 'readable' if readable else 'offline_unknown')
    if not readable:
        out['reason'] = 'Native file not located; absence and backup inventory are not proven'
    elif not resumable:
        out['reason'] = 'Recorded worktree is gone; no verified exact revision is available for automatic reconstruction'
    return out


if __name__ == '__main__':
    try:
        print(json.dumps(history(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None), ensure_ascii=False))
    except (OSError, ValueError, IndexError) as exc:
        print(json.dumps({'history_status': 'offline_unknown', 'reason': str(exc)}))
        sys.exit(1)
