#!/usr/bin/env python3
"""LivePage studio's local projection. No network, credentials or publishing.

The native agent supplies space results; the webchat relay reads the projection
and sends approved actions through the ordinary session gate. All writers share
one lock, including different MCP processes and a restarted webchat service.
"""
import copy
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


def public(value):
    if isinstance(value, dict):
        return {k: public(v) for k, v in value.items() if k != '_renewal'}
    if isinstance(value, list):
        return [public(v) for v in value]
    return value


def operate(state, op, a):
    if op == 'read':
        result = public(state)
        for item in result['sessions'].values():
            for receipt in item.get('actions', []):
                if receipt.get('state') in ('queued', 'sent', 'executing') and time.time() - receipt['at'] > 600:
                    receipt['state'] = 'unknown'
        return result
    if op == 'bind':
        key, fid = a['key'], a['fid']
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', key) or not re.fullmatch(r'[a-f0-9-]{36}', fid):
            raise ValueError('invalid studio identity')
        if key not in state['sessions']:
            state['sessions'][key] = {'key': key, 'fid': fid, 'agent': a['agent'],
                                      'proposal_id': a.get('proposal_id', ''), 'versions': [],
                                      'embed_origin': a['embed_origin'], 'actions': []}
        return state['sessions'][key]
    s = session(state, a['fid'], a.get('proposal_id', '') if op in ('action', 'renewal', 'renewed', 'renewal_failed', 'delivery', 'claim') else '')
    if op == 'target':
        related = [x for x in state['sessions'].values() if x['fid'] == a['fid']]
        return {**public(s), 'related_pages': public(related),
                'actions': [a for x in related for a in x['actions']],
                'rules': 'All edits MUST use hold. Preview first. Only a confirmed right-panel action authorizes publishing its exact version or changing visibility / pushing to self. Never invent metrics.'}
    if op in ('renewal', 'renewed', 'renewal_failed'):
        v = next((v for v in s['versions'] if v['version_id'] == a.get('version_id')), None)
        if not v:
            raise ValueError('version_not_found')
        if op == 'renewal':
            return copy.deepcopy({'version': v, 'embed_origin': s['embed_origin']})
        if a.get('renewal_key') != v.get('_renewal', {}).get('key'):
            return {'stale': True}
        if op == 'renewal_failed':
            v['preview_error'] = text(a.get('error'), 80)
            v['retry_at'] = time.time() + (3600 if a.get('terminal') else 30)
        else:
            v['embed'] = https(a['embed_url'])
            v['embed_exp'] = text(a['embed_expires'], 60)
            v['preview_updated_at'] = time.time()
            v.pop('preview_error', None)
            v.pop('retry_at', None)
        return {'updated': True}
    if op in ('delivery', 'claim'):
        receipt = next((r for r in s['actions'] if r['id'] == a['id']), None)
        if not receipt:
            raise ValueError('operation_not_found')
        if op == 'claim':
            if receipt.get('used') or receipt.get('state', 'pending') not in ('pending', 'failed'):
                return {'claimed': False, 'state': receipt.get('state', 'unknown')}
            receipt['state'] = 'unknown'
            receipt['message'] = '正在送达；中断时先核实结果'
            return {'claimed': True}
        if receipt.get('state') not in ('succeeded', 'executing'):
            receipt['state'] = a['state']
            receipt['message'] = text(a.get('message'))
        return public(receipt)
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
                 'note': text(a.get('note', prior.get('note'))), 'at': prior.get('at', time.time()),
                 'preview_updated_at': time.time()}
            if prior.get('_renewal'):
                v['_renewal'] = prior['_renewal']
            if a.get('embed_renewal_key'):
                if not re.fullmatch(r'[A-Za-z0-9_-]{43}', a['embed_renewal_key']):
                    raise ValueError('invalid renewal key')
                v['_renewal'] = {'key': a['embed_renewal_key'], 'expires': text(a.get('embed_renewal_expires'), 60)}
            v['renewable'] = bool(v.get('_renewal') and epoch(v['_renewal']['expires']) > time.time())
            s['versions'] = [v if x['version_id'] == v['version_id'] else x for x in s['versions']] if prior else s['versions'] + [v]
            s['versions'] = s['versions'][-8:]
        for key in ('analytics', 'leads'):
            if key in a:
                s[key] = {'summary': text(a[key], 4000), 'at': time.time()}
        if 'qr_url' in a:
            s['qr_url'] = https(a['qr_url'])
        if a.get('action_id'):
            receipt = next((r for r in s['actions'] if r['id'] == a['action_id']), None)
            if not receipt or receipt['proposal_id'] != proposal:
                raise ValueError('operation_not_found')
            if a.get('action_state') not in ('succeeded', 'failed', 'unknown'):
                raise ValueError('invalid operation result')
            receipt['state'] = a['action_state']
            receipt['message'] = text(a.get('action_message'))
        # A read-back of the exact published version is sufficient evidence for
        # older agents whose cached tool schema has no action result fields.
        for receipt in s['actions']:
            if receipt['action'] == 'preview' and receipt['version_id'] == a.get('version_id') and a.get('embed_url'):
                receipt['state'] = 'succeeded'
            if receipt.get('used') and receipt['action'] == 'publish' and receipt['version_id'] == a.get('version_id') and a.get('status') == 'ready':
                receipt['state'] = 'succeeded'
        s['updated_at'] = time.time()
        return {'shown': True}
    if op == 'action':
        action = a.get('action')
        allowed = ('publish', 'visibility', 'wechat', 'links', 'analytics', 'leads', 'preview')
        if action not in allowed or not s['proposal_id']:
            raise ValueError('select a page first')
        prior = next((r for r in s['actions'] if r['id'] == a.get('id')), None)
        if prior:
            for k in ('action', 'version_id', 'visibility', 'confirmed'):
                if prior.get(k, '') != a.get(k, '' if k != 'confirmed' else False):
                    raise ValueError('operation_id_conflict')
            return prior
        for receipt in reversed(s['actions']):
            if receipt['action'] != action or receipt.get('version_id', '') != a.get('version_id', ''):
                continue
            if receipt.get('state') in ('pending', 'sent', 'queued', 'executing', 'unknown'):
                if action == 'preview' and time.time() - receipt['at'] < 600:
                    return receipt
                if action in ('publish', 'visibility', 'wechat'):
                    raise ValueError('已有操作正在执行或结果待核实，请先在会话中读取实际状态')
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
                   'confirmed': a.get('confirmed') is True, 'to': 'self', 'at': time.time(), 'state': 'pending'}
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
            receipt['state'] = 'executing'
            receipt['used'] = True  # an unknown result must be read back, never replayed
            return
        raise ValueError('studio: confirm this exact action in the right panel first')


if __name__ == '__main__':
    try:
        print(json.dumps(call(sys.argv[1], json.load(sys.stdin)), ensure_ascii=False))
    except (ValueError, KeyError) as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False))
        sys.exit(2)
