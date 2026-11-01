#!/usr/bin/env python3
"""Bubble Cloud proposal workbench: the studio's second profile (task APVZ).

Beside the LivePage studio projection (fleet_studio.py) and under the same webchat
state directory, this keeps what that profile adds:

  config.json  the company profile, client cards and template list the deck agent reads
  images.json  every rendering and uploaded asset: model, prompt, parent, cost, score, pick
  media/       the image files (full size + a 320 px thumbnail)

Images are made by the Bubble Cloud quote server's /api/studio/* (the client's own app, hosted
outside the fleet): one fixed origin, its bearer token read at call time from the environment
or ~/.config/bc-preview/studio.key, never stored here.
Publishing stays with the studio's right-panel confirmation; nothing here touches space.

CLI: fleet_bc_studio.py <op>  (JSON arguments on stdin, JSON result on stdout; exit 2 + {error}).
"""
import base64
import contextlib
import copy
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

import fleet_studio

ORIGIN = 'https://bubblecloud.quotehand.com'  # oss-ok: the one client's own quote server; fixed origin, no caller-supplied URL
MODELS = ('gemini', 'gpt', 'seedream')
ID = re.compile(r'[a-f0-9]{12}')
DATA_URL = re.compile(r'data:image/(jpeg|png|webp);base64,([A-Za-z0-9+/=]+)')
PORTFOLIO = ['arch-1', 'arch-2', 'bubble-bouquet-1', 'bubble-bouquet-2', 'center-medium-1', 'floral-low-1',
             'floral-low-2', 'ground-small-1', 'ground-small-2', 'half-arch-1', 'half-arch-2', 'hotel-proposal-1',
             'marquee-1', 'marry-me-1', 'marry-me-2', 'neon-1', 'neon-2', 'petal-aisle-1']

# Facts gathered from the Skill page, the Makera proposal and the quote server's company.js (design page APVZ).
DEFAULT_CONFIG = {
    'rev': 1,
    'company': {
        'name': 'Bubble Cloud Events',
        'legal': 'Bubble Cloud Balloon Design, INC.',
        'positioning': 'Full-service corporate events for Bay Area tech companies (est. 2020).',
        'address': '3070 Scott Blvd, Santa Clara, CA 95054',
        'website': 'bubblecloudevents.com',
        'contacts': 'Lily 510-514-3000 · Joe 510-329-9805 · bubblecloudevents@gmail.com',
        'services': 'Theme & key visual · Installations & sets · Interactive experiences (AI photo booth) · '
                    'Tech moments (mosaic reveal, multi-office live link) · Catering · Entertainment & production',
        'cases': 'Olight O-Fan Day 2025 (New York) · Tencent Project Up at CVPR 2025 (Nashville) · Moutai Night (San Francisco)',
        'procurement': 'Itemized quotes, W-9, insurance (COI), NDA on request',
        'theme': 'House theme when the client has no brand: background #F7F5F1, surface #FFFFFF, border #E4E2DC, '
                 'dark #1F2430 / #2A3040, accent #E4572E (on dark #F08A5D), muted #5B6170, DM Sans.',
        'voice': 'English by default; confident, concrete, no paragraphs on slides.',
    },
    'clients': [],
    'templates': [
        {'id': 'tpl-html', 'name': 'Corporate event proposal (13 pages, HTML — start here)', 'kind': 'template',
         'proposal_id': '01M68G0M7HQBVME7F61HNA8T7D', 'version_id': '01M68G0S0FJP9KWHBZBEG9KJ4A',
         'note': 'LivePage deck: index.html + fonts/ + img/; theme in --bc-* CSS variables; data-bc-block on every block.'},
        {'id': 'tpl-13', 'name': 'Corporate event proposal (13 pages, PDF original)', 'kind': 'reference',
         'proposal_id': '01M68AV5CJCXHB2V9KBN0QQG7H', 'version_id': '01M68B7YN6PEGWRN6Z2QMFKQK6',
         'note': 'Layouts m-hero / m-cards / m-trio / m-duo / m-list / m-reveal.'},
        {'id': 'ex-tiktok', 'name': 'Example · Year One · TikTok USDS JV', 'kind': 'example',
         'proposal_id': '01M68AV2QYHBY6JM1RNQ0WDG5N', 'version_id': '01M68B86BREX75WRXDQ55QPKT0',
         'note': 'Multi-office, live link, mosaic reveal. Internal note 01M68BCMW90WKFYPMPSRE7CW61.'},
        {'id': 'ex-databricks', 'name': 'Example · Around the World · Databricks', 'kind': 'example',
         'proposal_id': '01M68AV474DTA11R09V3C1CFQG', 'version_id': '01M68B9G880QHV8QSHGQ850CF4',
         'note': 'Single office, passport festival, floor plan. Internal note 01M68BCZG9VXND46SFGWQPRW4D.'},
    ],
}
CLIENT_KEYS = ('name', 'event', 'date', 'venue', 'guests', 'budget', 'brand', 'prefs', 'contacts', 'quote_url',
               'notes', 'include_prices', 'venue_assets', 'proposals')
TEMPLATE_KEYS = ('name', 'kind', 'proposal_id', 'version_id', 'note')


def root():
    return fleet_studio.root() / 'bubble-cloud'


STALE_RUN = 600  # a rendering still `running` after this many seconds was lost (a service restart)


@contextlib.contextmanager
def store():
    d = root()
    (d / 'media').mkdir(mode=0o700, parents=True, exist_ok=True)
    changed = False
    with open(d / 'store.lock', 'a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not (d / 'config.json').exists() and not (d / 'images.json').exists():
            restore()
        state = {}
        for name, default in (('config', DEFAULT_CONFIG), ('images', [])):
            try:
                state[name] = json.loads((d / f'{name}.json').read_text())
            except FileNotFoundError:
                state[name] = copy.deepcopy(default)
        before = json.dumps(state, sort_keys=True)
        for e in state['images']:
            if e.get('status') == 'running' and time.time() - e.get('at', 0) > STALE_RUN:
                e.update(status='failed', error='timed out (service restarted?) — retry')
        yield state
        if json.dumps(state, sort_keys=True) != before:
            changed = True
            for name in ('config', 'images'):
                fd, tmp = tempfile.mkstemp(prefix=f'.{name}-', dir=d)
                try:
                    with os.fdopen(fd, 'w') as out:
                        json.dump(state[name], out, ensure_ascii=False)
                    os.replace(tmp, d / f'{name}.json')
                finally:
                    if os.path.exists(tmp):
                        os.unlink(tmp)
            meta = {'config': state['config'], 'images': state['images']}
    if changed:
        backup(meta)


# ---- the store's copy on the quote server (task APVZ): pushed after every change, pulled into an empty store ----
# PUT/GET /api/studio/store/meta {config, images} · PUT/GET /api/studio/store/media/<id>[.t].jpg. A failure never
# fails the local op: it is logged in backup.log, and the next change pushes again (media not yet sent included).

def backup_on():
    return os.environ.get('BC_STUDIO_BACKUP', '1') != '0'


def backup_log(line):
    with contextlib.suppress(OSError):
        with open(root() / 'backup.log', 'a') as f:
            f.write(time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()) + ' ' + line + '\n')


def sent_file():
    return root() / 'media-sent.json'


def backup(meta):
    if not backup_on():
        return
    try:
        token()
    except ValueError:
        return
    try:
        remote('/api/studio/store/meta', meta, timeout=60, method='PUT')
    except ValueError as exc:
        backup_log('meta: ' + str(exc))
        return
    try:
        sent = set(json.loads(sent_file().read_text()))
    except (OSError, ValueError):
        sent = set()
    pushed = 0
    for f in sorted((root() / 'media').glob('*.jpg')):
        if f.name in sent or not re.fullmatch(r'[a-f0-9]{12}(\.t)?\.jpg', f.name):
            continue
        try:
            remote('/api/studio/store/media/' + f.name, {'data': data_url(f)}, timeout=120, method='PUT')
        except ValueError as exc:
            backup_log(f'media {f.name}: {exc}')
            break
        sent.add(f.name)
        pushed += 1
    if pushed:
        with contextlib.suppress(OSError):
            sent_file().write_text(json.dumps(sorted(sent)))


def restore():
    """An empty store (a new home, a lost disk) from the server's copy; nothing there ⇒ the defaults."""
    if not backup_on():
        return
    try:
        token()
    except ValueError:
        return
    try:
        meta = remote('/api/studio/store/meta', timeout=60)
    except ValueError as exc:
        if 'no_store' in str(exc) or 'not_found' in str(exc):  # nothing saved, or a server without the store yet
            return
        # never start an empty store over a copy we could not read: its first push would replace it
        backup_log('restore meta: ' + str(exc))
        raise ValueError('the workbench store is empty here and its saved copy could not be read (%s) — try again shortly' % exc)
    if not isinstance(meta.get('config'), dict) or not isinstance(meta.get('images'), list):
        return
    d = root()
    got = set()
    for e in meta['images']:
        if e.get('status', 'ok') != 'ok' or not ID.fullmatch(str(e.get('id', ''))):
            continue
        for name in (e['id'] + '.jpg', e['id'] + '.t.jpg'):
            if (d / 'media' / name).exists():
                got.add(name)
                continue
            try:
                raw = remote_bytes('/api/studio/store/media/' + name)
            except ValueError as exc:
                backup_log(f'restore {name}: {exc}')
                continue
            (d / 'media' / name).write_bytes(raw)
            got.add(name)
    for name in ('config', 'images'):
        (d / f'{name}.json').write_text(json.dumps(meta[name], ensure_ascii=False))
    with contextlib.suppress(OSError):
        sent_file().write_text(json.dumps(sorted(got)))
    backup_log(f'restored {len(meta["images"])} images, {len(got)} files')


def remote_bytes(path, timeout=120):
    req = urllib.request.Request(origin() + path, headers={'Authorization': 'Bearer ' + token(), 'User-Agent': 'fleet-bc-studio'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        e.close()
        raise ValueError(f'HTTP {e.code}')
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise ValueError(f'unreachable: {e}')


def text(v, limit=2000):
    return str(v if v is not None else '')[:limit]


def media(i, thumb=False):
    if not ID.fullmatch(str(i)):
        raise ValueError('bad image id')
    return root() / 'media' / (f'{i}.t.jpg' if thumb else f'{i}.jpg')


def shrink(src, dst, px, quality=82):
    """A JPEG at most px on its longer side (sips on macOS); elsewhere the file as it is."""
    if shutil.which('sips'):
        r = subprocess.run(['sips', '-Z', str(px), '-s', 'format', 'jpeg', '-s', 'formatOptions', str(quality), str(src), '--out', str(dst)],
                           capture_output=True, timeout=60)
        if r.returncode == 0 and Path(dst).exists():
            return
    shutil.copyfile(src, dst)


def save_data_url(i, value):
    m = DATA_URL.fullmatch(str(value or ''))
    if not m:
        raise ValueError('expected a JPEG, PNG or WebP data URL')
    (root() / 'media').mkdir(mode=0o700, parents=True, exist_ok=True)
    raw = root() / 'media' / f'{i}.src'
    raw.write_bytes(base64.b64decode(m.group(2)))
    try:
        shrink(raw, media(i), 2048)
        shrink(media(i), media(i, True), 320, 68)
    finally:
        raw.unlink(missing_ok=True)


def data_url(path):
    return 'data:image/jpeg;base64,' + base64.b64encode(Path(path).read_bytes()).decode()


def token():
    t = os.environ.get('BC_STUDIO_TOKEN', '')
    if not t:
        with contextlib.suppress(OSError):
            t = (Path.home() / '.config/bc-preview/studio.key').read_text().strip()
    if not t:
        raise ValueError('image service is not configured on this machine (BC_STUDIO_TOKEN / ~/.config/bc-preview/studio.key)')
    return t


def origin():
    # Tests point it at a local double; nothing else may.
    o = os.environ.get('BC_STUDIO_URL', ORIGIN)
    if o != ORIGIN and not re.fullmatch(r'http://127\.0\.0\.1:\d+', o):
        raise ValueError('unsupported image service origin')
    return o


def remote(path, body=None, timeout=240, method=None):
    req = urllib.request.Request(origin() + path, data=json.dumps(body).encode() if body is not None else None,
                                 method=method or ('POST' if body is not None else 'GET'),
                                 headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json',
                                          'User-Agent': 'fleet-bc-studio'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            j = json.loads(e.read())
        except ValueError:
            j = {}
        finally:
            e.close()
        raise ValueError(j.get('error', f'image service {e.code}') + (f": {j['detail']}" if j.get('detail') else '')
                         + (f" (spent ${j['spent']} of ${j['cap']})" if 'cap' in j else ''))
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise ValueError(f'image service unreachable: {e}')


def public(entry, with_thumb=True):
    e = {k: v for k, v in entry.items()}
    if with_thumb and e.get('status', 'ok') == 'ok' and media(e['id'], True).exists():
        e['thumb'] = data_url(media(e['id'], True))
    e['path'] = str(media(e['id'])) if e.get('status', 'ok') == 'ok' else ''
    return e


def find(state, i):
    e = next((x for x in state['images'] if x['id'] == i), None)
    if not e:
        raise ValueError('image not found')
    return e


def op_read(a):
    with store() as s:
        proposal = text(a.get('proposal'), 100)
        assets = [public(e) for e in s['images'] if e['kind'] == 'asset']
        renders = [public(e) for e in s['images'] if e['kind'] == 'render' and (not proposal or e.get('proposal') == proposal)]
        return {'config': s['config'], 'assets': assets, 'renders': renders[-120:]}


def clean_client(c):
    out = {k: c[k] for k in CLIENT_KEYS if k in c}
    out['id'] = c.get('id') if re.fullmatch(r'[a-z0-9-]{3,40}', str(c.get('id', ''))) else 'c-' + uuid.uuid4().hex[:8]
    for k, v in list(out.items()):
        if k == 'include_prices':
            out[k] = v is True
        elif isinstance(v, list):
            out[k] = [text(x, 200) for x in v][:50]
        elif k != 'id':
            out[k] = text(v)
    return out


def op_save(a):
    with store() as s:
        cfg = s['config']
        if a.get('rev') != cfg['rev']:
            raise ValueError('configuration changed elsewhere; reload and edit again')
        if isinstance(a.get('company'), dict):
            cfg['company'] = {text(k, 60): text(v, 4000) for k, v in a['company'].items()}
        if isinstance(a.get('clients'), list):
            cfg['clients'] = [clean_client(c) for c in a['clients'] if isinstance(c, dict) and c.get('name')][:200]
        if isinstance(a.get('templates'), list):
            cfg['templates'] = [{'id': text(t.get('id') or 't-' + uuid.uuid4().hex[:8], 40),
                                 **{k: text(t.get(k), 400) for k in TEMPLATE_KEYS}}
                                for t in a['templates'] if isinstance(t, dict) and t.get('name')][:100]
        cfg['rev'] += 1
        return {'rev': cfg['rev']}


def op_asset(a):
    i = uuid.uuid4().hex[:12]
    save_data_url(i, a.get('data'))
    entry = {'id': i, 'kind': 'asset', 'label': text(a.get('label'), 120) or 'Upload', 'group': text(a.get('group'), 40) or 'venue',
             'client': text(a.get('client'), 40), 'at': time.time()}
    with store() as s:
        s['images'].append(entry)
    return public(entry)


def op_import_portfolio(_a):
    """Bubble Cloud's own work photos (the website's, served by the quote server) as reference assets."""
    with store() as s:
        have = {e.get('source') for e in s['images']}
    added = []
    for name in PORTFOLIO:
        src = f'/img/catalog/{name}.jpg'
        if src in have:
            continue
        try:
            with urllib.request.urlopen(urllib.request.Request(origin() + src, headers={'User-Agent': 'fleet-bc-studio'}), timeout=30) as r:
                raw = r.read()
        except (urllib.error.URLError, OSError):
            continue
        i = uuid.uuid4().hex[:12]
        (root() / 'media').mkdir(mode=0o700, parents=True, exist_ok=True)
        tmp = root() / 'media' / f'{i}.src'
        tmp.write_bytes(raw)
        try:
            shrink(tmp, media(i), 2048)
            shrink(media(i), media(i, True), 320, 68)
        finally:
            tmp.unlink(missing_ok=True)
        added.append({'id': i, 'kind': 'asset', 'label': name.replace('-', ' '), 'group': 'portfolio', 'source': src, 'at': time.time()})
    with store() as s:
        s['images'].extend(added)
    return {'added': len(added)}


def op_plan(a):
    """Record N pending renderings per model at once, so the page shows them while they run."""
    proposal = text(a.get('proposal'), 100).strip()
    if not proposal:
        raise ValueError('proposal is required (the LivePage page id, or the studio key before the first version)')
    prompt = text(a.get('prompt'), 4000).strip()
    if not prompt:
        raise ValueError('prompt is required')
    models = [m for m in (a.get('models') or [a.get('model') or 'gemini']) if m in MODELS]
    if not models:
        raise ValueError('models: gemini, gpt or seedream')
    n = max(1, min(4, int(a.get('n') or 1)))
    refs = [r for r in (a.get('refs') or []) if ID.fullmatch(str(r))][:4]
    with store() as s:
        for r in refs:
            find(s, r)
        parent = text(a.get('parent'), 12)
        if parent:
            find(s, parent)
        batch = uuid.uuid4().hex[:8]
        entries = [{'id': uuid.uuid4().hex[:12], 'kind': 'render', 'proposal': proposal, 'slide': text(a.get('slide'), 40),
                    'model': m, 'prompt': prompt, 'op': text(a.get('op'), 30) or 'generate', 'parent': parent, 'refs': refs,
                    'batch': batch, 'status': 'running', 'at': time.time()} for m in models for _ in range(n)]
        s['images'].extend(entries)
    return {'batch': batch, 'ids': [e['id'] for e in entries]}


def op_run(a):
    """Make the planned renderings: one service call per model, results written back as they land."""
    ids = [i for i in a.get('ids', []) if ID.fullmatch(str(i))]
    with store() as s:
        todo = [copy.deepcopy(find(s, i)) for i in ids]
    marked = a.get('marked')
    by_model = {}
    for e in todo:
        by_model.setdefault(e['model'], []).append(e)
    done = []
    for model, entries in by_model.items():
        e0 = entries[0]
        refs = ([marked] if marked and DATA_URL.fullmatch(str(marked)) else []) + [data_url(media(r)) for r in e0['refs'] if media(r).exists()]
        if e0['parent'] and not marked and media(e0['parent']).exists():
            refs.insert(0, data_url(media(e0['parent'])))
        try:
            got = remote('/api/studio/image', {'proposal': e0['proposal'], 'model': model, 'prompt': e0['prompt'],
                                               'refs': refs[:4], 'n': len(entries), 'override': a.get('override') is True})
            images, err = got.get('images', []), ''
        except ValueError as exc:
            images, err = [], str(exc)
        with store() as s:
            for k, e in enumerate(entries):
                live = find(s, e['id'])
                if k < len(images):
                    try:
                        save_data_url(e['id'], images[k]['image'])
                        live.update(status='ok', cost=images[k].get('cost', 0))
                    except ValueError as exc:
                        live.update(status='failed', error=str(exc))
                else:
                    live.update(status='failed', error=err or 'the service returned fewer images')
                done.append(public(live, with_thumb=False))
    return {'images': done}


def op_generate(a):
    planned = op_plan(a)
    return op_run({**a, 'ids': planned['ids']})


def op_media(a):
    i = text(a.get('id'), 12)
    with store() as s:
        find(s, i)
    p = media(i)
    if not p.exists():
        raise ValueError('image file missing')
    return {'id': i, 'data': data_url(p)}


def op_judge(a):
    i = text(a.get('id'), 12)
    with store() as s:
        e = copy.deepcopy(find(s, i))
    if e['kind'] != 'render' or e.get('status') != 'ok':
        raise ValueError('only a finished rendering can be scored')
    refs = [data_url(media(r)) for r in e.get('refs', []) if media(r).exists()][:3]
    got = remote('/api/studio/judge', {'proposal': e['proposal'], 'image': data_url(media(i)), 'refs': refs,
                                       'brief': text(a.get('brief') or e['prompt'], 1500), 'palette': a.get('palette') or []})
    with store() as s:
        live = find(s, i)
        live['score'] = got.get('score')
        live['judge'] = {k: got.get(k) for k in ('venue_kept', 'props_real', 'palette_ok', 'artifacts', 'photoreal', 'notes')}
        live['cost'] = round((live.get('cost') or 0) + (got.get('cost') or 0), 4)
        return public(live, with_thumb=False)


def op_pick(a):
    i = text(a.get('id'), 12)
    with store() as s:
        e = find(s, i)
        for x in s['images']:
            if x['kind'] == 'render' and x.get('proposal') == e.get('proposal') and x.get('slide') == e.get('slide'):
                x['picked'] = x['id'] == i and not e.get('picked')
        return public(e, with_thumb=False)


def op_usage(a):
    return remote('/api/studio/usage?proposal=' + urllib.request.quote(text(a.get('proposal'), 100)), timeout=20)


OPS = {'read': op_read, 'save': op_save, 'asset': op_asset, 'import_portfolio': op_import_portfolio, 'plan': op_plan,
       'run': op_run, 'generate': op_generate, 'media': op_media, 'judge': op_judge, 'pick': op_pick, 'usage': op_usage}


def call(op, args):
    if op not in OPS:
        raise ValueError('unknown operation')
    return OPS[op](args or {})


if __name__ == '__main__':
    try:
        print(json.dumps(call(sys.argv[1], json.load(sys.stdin)), ensure_ascii=False))
    except (ValueError, KeyError, TypeError) as exc:
        print(json.dumps({'error': str(exc)}, ensure_ascii=False))
        sys.exit(2)
