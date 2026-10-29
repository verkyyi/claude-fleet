#!/usr/bin/env python3
"""LivePage studio's local projection. No network, credentials or publishing.

The native agent supplies space results; the webchat relay reads the projection
and sends approved actions through the ordinary session gate. All writers share
one lock, including different MCP processes and a restarted webchat service.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from urllib.parse import urlparse
import fleet_iso


def root():
    conf = Path(os.environ.get('FLEET_CONF_DIR', str(Path.home() / '.config/claude-fleet')))
    return Path(os.environ.get('FLEET_WEBCHAT_STATE', str(conf / 'webchat')))


@contextlib.contextmanager
def book():
    directory = root()
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(directory / 'studio.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / 'studio.json'
        try:
            state = json.loads(path.read_text())
        except FileNotFoundError:
            state = {'sessions': {}, 'projects': [], 'updated_at': None}
        yield state
        fd, tmp = tempfile.mkstemp(prefix='.studio-', dir=directory)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(state, out, ensure_ascii=False)
            os.replace(tmp, path)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


def text(value, limit=200):
    return str(value or '')[:limit]


def https(value):
    value = text(value, 4000)
    u = urlparse(value)
    return value if u.scheme == 'https' and u.hostname and not u.username and not u.password else ''


def epoch(value):
    return fleet_iso.epoch(value, utc=True)


def session(state, fid, proposal=''):
    for s in state['sessions'].values():
        if s['fid'] == fid and (not proposal or s['proposal_id'] == proposal):
            return s
    raise ValueError('this session has no studio binding; reopen from the studio')


def operate(state, op, a):
    if op == 'read':
        return state
    if op == 'bind':
        key, fid = a['key'], a['fid']
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', key) or not re.fullmatch(r'[a-f0-9-]{36}', fid):
            raise ValueError('invalid studio identity')
        if key not in state['sessions']:
            state['sessions'][key] = {'key': key, 'fid': fid, 'agent': a['agent'],
                                      'proposal_id': a.get('proposal_id', ''), 'versions': [],
                                      'embed_origin': a['embed_origin'], 'actions': []}
        return state['sessions'][key]
    s = session(state, a['fid'], a.get('proposal_id', '') if op == 'action' else '')
    if op == 'target':
        related = [x for x in state['sessions'].values() if x['fid'] == a['fid']]
        return {**s, 'related_pages': related,
                'actions': [a for x in related for a in x['actions']],
                'rules': 'All edits MUST use hold. Preview first. Only a confirmed right-panel action authorizes publishing its exact version or changing visibility / pushing to self. Never invent metrics.'}
    if op == 'projects':
        projects = a.get('projects')
        if not isinstance(projects, list) or len(projects) > 1000:
            raise ValueError('projects must be a list of at most 1000 space results')
        state['projects'] = [{'proposal_id': text(p.get('proposal_id'), 100),
                              'title': text(p.get('title')), 'url': https(p.get('url')),
                              'visibility': text(p.get('visibility'), 40)} for p in projects if p.get('proposal_id')]
        state['updated_at'] = time.time()
        return {'shown': len(state['projects'])}
    if op == 'show':
        proposal = text(a.get('proposal_id'), 100)
        if not proposal or (s['proposal_id'] and proposal != s['proposal_id'] and not a.get('related')):
            raise ValueError('show_page must name the bound page')
        # Discovery sessions do not become a project's editing session.
        if s['key'] == 'catalog':
            raise ValueError('open the page from the studio project list before editing')
        other = next((x for x in state['sessions'].values() if x['proposal_id'] == proposal and x['fid'] != s['fid']), None)
        if other:
            raise ValueError('this page already has a studio session; open it from the project list')
        if s['proposal_id'] and proposal != s['proposal_id']:
            # A multilingual task has one native session but a projection and
            # explicit publish confirmation per language/page.
            related = next((x for x in state['sessions'].values() if x['proposal_id'] == proposal), None)
            if related:
                s = related
            else:
                key = 'page-' + proposal
                if key in state['sessions']:
                    raise ValueError('related page key is already in use')
                s = dict(key=key, fid=a['fid'], agent=s['agent'], proposal_id=proposal,
                         versions=[], actions=[], embed_origin=s['embed_origin'])
                state['sessions'][key] = s
        s['proposal_id'] = proposal
        p = {'proposal_id': proposal, 'title': text(a.get('title', s.get('title'))),
             'url': https(a.get('url', s.get('url'))),
             'visibility': text(a.get('visibility', s.get('visibility')), 40)}
        state['projects'] = [x for x in state['projects'] if x['proposal_id'] != proposal] + [p]
        s.update(p)
        if a.get('version_id'):
            prior = next((v for v in s['versions'] if v['version_id'] == a['version_id']), {})
            status = a.get('status')
            if status not in ('hold', 'review', 'ready', 'failed'):
                raise ValueError('status must be hold, review, ready or failed')
            v = {**p, 'version_id': text(a['version_id'], 100), 'version': text(a.get('version', prior.get('version')), 30),
                 'status': status, 'embed': https(a.get('embed_url', prior.get('embed'))),
                 'embed_exp': text(a.get('embed_expires', prior.get('embed_exp')), 60),
                 'note': text(a.get('note', prior.get('note'))), 'at': time.time()}
            s['versions'] = [x for x in s['versions'] if x['version_id'] != v['version_id']] + [v]
            s['versions'] = s['versions'][-8:]
        for key in ('analytics', 'leads'):
            if key in a:
                s[key] = {'summary': text(a[key], 4000), 'at': time.time()}
        if 'qr_url' in a:
            s['qr_url'] = https(a['qr_url'])
        s['updated_at'] = time.time()
        return {'shown': True}
    if op == 'action':
        action = a.get('action')
        allowed = ('publish', 'visibility', 'wechat', 'links', 'analytics', 'leads', 'preview')
        if action not in allowed or not s['proposal_id']:
            raise ValueError('select a page first')
        version = next((v for v in s['versions'] if v['version_id'] == a.get('version_id')), None)
        if action in ('publish', 'visibility', 'wechat') and a.get('confirmed') is not True:
            raise ValueError('confirm this action first')
        if action == 'publish' and (not version or version['status'] != 'hold' or not version['embed'] or epoch(version['embed_exp']) <= time.time()):
            raise ValueError('preview a held version before publishing; refresh an expired preview')
        if action == 'visibility' and a.get('visibility') not in ('private', 'passcode', 'public'):
            raise ValueError('invalid visibility')
        if not re.fullmatch(r'[a-f0-9-]{36}', str(a.get('id', ''))):
            raise ValueError('an action id is required')
        prior = next((v for v in s['actions'] if v['id'] == a['id']), None)
        if prior:
            return prior
        receipt = {'id': a['id'], 'action': action, 'proposal_id': s['proposal_id'],
                   'version_id': a.get('version_id', ''), 'visibility': a.get('visibility', ''),
                   'confirmed': a.get('confirmed') is True, 'to': 'self', 'at': time.time()}
        s['actions'] = (s['actions'] + [receipt])[-32:]
        return receipt
    raise ValueError('unknown studio operation')


def call(op, args):
    with book() as state:
        return operate(state, op, args)


def guard_space(fid, tool, args):
    """Prevent accidental publication through the native MCP gateway.

    A convenience rail, not a sandbox against a login's arbitrary code. The
    agent definition also prohibits other roads around the confirmation.
    """
    if not (root() / 'studio.json').exists():
        return
    with book() as state:
        try:
            s = session(state, fid)
        except ValueError:
            return
        if tool in ('publish_file', 'finalize_upload', 'create_upload_link'):
            if args.get('hold') is not True:
                raise ValueError('studio: every edit requires hold=true; preview before publishing')
            if s['key'] == 'catalog':
                raise ValueError('studio: open an editing session first')
            return
        action = {'publish_version': 'publish', 'set_visibility': 'visibility', 'push_to_wechat': 'wechat'}.get(tool)
        if not action:
            # Known writes with broader scope are outside the MVP.
            if tool in ('delete_proposal', 'delete_version', 'set_indexable', 'push_to_wecom'):
                raise ValueError('studio: this action is outside the workbench scope')
            return
        related = [x for x in state['sessions'].values() if x['fid'] == fid]
        if action != 'publish' and args.get('proposal_id') not in [x['proposal_id'] for x in related]:
            raise ValueError('studio: action targets another page')
        if action == 'wechat' and args.get('to', 'self') != 'self':
            raise ValueError('studio: WeChat delivery is to self only')
        for receipt in reversed([a for x in related for a in x['actions']]):
            if receipt['action'] != action or not receipt['confirmed'] or receipt.get('used') or time.time() - receipt['at'] > 600:
                continue
            if action == 'publish' and receipt['version_id'] != args.get('version_id'):
                continue
            if action == 'visibility' and receipt['visibility'] != args.get('visibility'):
                continue
            if action != 'publish' and receipt['proposal_id'] != args.get('proposal_id'):
                continue
            receipt['used'] = True  # an unknown result must be read back, never replayed
            return
        raise ValueError('studio: confirm this exact action in the right panel first')


if __name__ == '__main__':
    try:
        print(json.dumps(call(sys.argv[1], json.load(sys.stdin)), ensure_ascii=False))
    except (ValueError, KeyError) as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False))
        sys.exit(2)
