#!/usr/bin/env python3
"""Register legacy web history in the ordinary identity ledger, without an agent.

Input comes from the login's own conversation files, never a browser-supplied
path. Original transcripts and conversation files are retained. Replaying a
partially completed import fills the same ID; an existing native owner is reused.
"""
import fcntl
import json
import os
import subprocess
import sys
import uuid

import fleet_id


def import_entries(entries):
    if not isinstance(entries, list) or len(entries) > 500:
        raise ValueError('expected at most 500 legacy conversations')
    plans = []
    for row in entries:
        if not isinstance(row, dict) or row.get('agent') not in ('claude', 'codex'):
            raise ValueError('unknown legacy agent')
        chain = row.get('chain') or []
        if not isinstance(chain, list):
            raise ValueError('invalid legacy chain')
        ids = [x.get('id') if isinstance(x, dict) else None for x in chain] + [row.get('session')]
        if not all(fleet_id.is_fid(s) for s in ids):
            raise ValueError('invalid native session identity')
        plans.append((row, list(dict.fromkeys(ids))))
    os.makedirs(fleet_id.ids_dir(), exist_ok=True)
    out = []
    with open(os.path.join(fleet_id.ids_dir(), '.webchat-import.lock'), 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        for row, ids in plans:
            # Native identities are already unique. Never mint another owner or
            # close a live window merely because an old web file mentions it.
            own = fleet_id.owner_of(ids[-1])
            fid = str(uuid.uuid5(uuid.NAMESPACE_URL, 'claude-fleet:webchat:' + row['agent'] + ':' + ids[-1]))
            if own and own[0] != fid:
                out.append(own[0])
                continue
            fields = dict(agent=row['agent'], origin='web', worktree=row.get('cwd') or os.path.expanduser('~'),
                          title=row.get('title') or ('历史对话 · ' + row['agent'] + ' · ' + ids[-1][:8]),
                          legacy_webchat=True, legacy_at=row.get('at', ''),
                          legacy_cwds={x['id']: x['cwd'] for x in (row.get('chain') or []) if x.get('cwd')},
                          codex_home=row.get('codex_home', ''))
            fleet_id.open_id(fid, fields)
            for sid in ids:
                fleet_id.append(fid, None, decide=lambda evs, sid=sid: None if any(
                    e.get('ev') == 'native' and e.get('native') == sid for e in evs) else
                    dict(ev='native', agent=row['agent'], native=sid, trigger='migrated'))
            fleet_id.append(fid, None, decide=lambda evs: None if any(e.get('ev') == 'closed' for e in evs)
                            else dict(ev='closed', reason='legacy web history'))
            out.append(fid)
    if out and os.environ.get('FLEET_ID_PUSH', '1') != '0':
        # One sequential pusher, not hundreds of simultaneous hub requests.
        # The ordinary collector retries any interrupted or offline push.
        subprocess.Popen(['bash', os.path.join(os.path.dirname(__file__), 'fleet-id.sh'), 'push', *dict.fromkeys(out)],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    return out


if __name__ == '__main__':
    try:
        print(json.dumps({'ids': import_entries(json.load(sys.stdin))}))
    except (OSError, ValueError, TypeError) as exc:
        print(json.dumps({'error': str(exc)}))
        sys.exit(1)
