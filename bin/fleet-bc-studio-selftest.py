#!/usr/bin/env python3
# selftest-entry
# Reads fleet_bc_studio.py (task APVZ): the Bubble Cloud workbench's store and its calls to the
# quote server's /api/studio/*, against a local double — config revisions, uploads, a planned and
# run batch with refs and parent, the spending cap passed through, scoring, picking, the origin pin.
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import fleet_bc_studio as bc

PNG = 'data:image/png;base64,' + base64.b64encode(bytes.fromhex(
    '89504e470d0a1a0a0000000d4948445200000001000000010806000000'
    '1f15c4890000000d49444154789c63f8cfc0f00f00050001ff5a8a2d3a0000000049454e44ae426082')).decode()
SEEN = []
STORE = {'media': {}}


class Double(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def answer(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer t0k':
            return self.answer(401, {'error': 'studio_token_required'})
        if self.path == '/api/studio/store/meta':
            if STORE.get('down'):
                return self.answer(503, {'error': 'down'})
            return self.answer(200, STORE['meta']) if 'meta' in STORE else self.answer(404, {'error': 'no_store'})
        if self.path.startswith('/api/studio/store/media/'):
            raw = STORE['media'].get(self.path.rsplit('/', 1)[1])
            if raw is None:
                return self.answer(404, {'error': 'no_media'})
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.end_headers()
            return self.wfile.write(raw)
        self.answer(200, {'spent': 0.1, 'cap': 5, 'models': ['gemini', 'gpt', 'seedream']})

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.headers.get('Authorization') != 'Bearer t0k':
            return self.answer(401, {'error': 'studio_token_required'})
        if self.path == '/api/studio/store/meta':
            STORE['meta'] = body
            STORE['puts'] = STORE.get('puts', 0) + 1
            return self.answer(200, {'ok': True})
        name = self.path.rsplit('/', 1)[1]
        STORE['media'][name] = base64.b64decode(body['data'].split(',', 1)[1])
        self.answer(200, {'ok': True})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        SEEN.append((self.path, body))
        if self.headers.get('Authorization') != 'Bearer t0k':
            return self.answer(401, {'error': 'studio_token_required'})
        if self.path == '/api/studio/judge':
            return self.answer(200, {'score': 8.2, 'venue_kept': 9, 'props_real': 8, 'palette_ok': 8, 'artifacts': 8,
                                     'photoreal': 8, 'notes': 'ok', 'cost': 0.01})
        if body['prompt'] == 'over':
            return self.answer(402, {'error': 'over_cap', 'spent': 5.1, 'cap': 5})
        self.answer(200, {'images': [{'image': PNG, 'cost': 0.05}] * body['n'], 'cost': 0.05 * body['n']})


class BcStudioTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Double)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {'FLEET_WEBCHAT_STATE': self.tmp.name, 'BC_STUDIO_TOKEN': 't0k',
                                           'BC_STUDIO_URL': f'http://127.0.0.1:{self.server.server_port}'})
        self.env.start()
        SEEN.clear()
        STORE.clear()
        STORE['media'] = {}

    def test_backup_and_restore(self):
        bc.call('save', {'rev': 1, 'clients': [{'name': 'Acme', 'event': 'Launch'}]})
        self.assertEqual(STORE['meta']['config']['clients'][0]['name'], 'Acme')
        venue = bc.call('asset', {'data': PNG, 'label': 'lobby'})
        self.assertIn(venue['id'] + '.jpg', STORE['media'])
        self.assertIn(venue['id'] + '.t.jpg', STORE['media'])
        puts = STORE['puts']
        bc.call('read', {})
        self.assertEqual(STORE['puts'], puts, 'a read pushes nothing')
        # a new home: the store comes back from the copy, files included
        with tempfile.TemporaryDirectory() as fresh, patch.dict(os.environ, {'FLEET_WEBCHAT_STATE': fresh}):
            back = bc.call('read', {})
            self.assertEqual(back['config']['clients'][0]['name'], 'Acme')
            self.assertEqual([a['id'] for a in back['assets']], [venue['id']])
            self.assertTrue(bc.media(venue['id']).exists())
        # the copy unreadable: an empty store refuses rather than start over it
        STORE['down'] = True
        with tempfile.TemporaryDirectory() as fresh, patch.dict(os.environ, {'FLEET_WEBCHAT_STATE': fresh}):
            with self.assertRaisesRegex(ValueError, 'saved copy could not be read'):
                bc.call('read', {})
        STORE.pop('down')

    def test_stale_running_render_fails(self):
        planned = bc.call('plan', {'proposal': 'p1', 'prompt': 'arch'})
        with bc.store() as st:
            bc.find(st, planned['ids'][0])['at'] = time.time() - bc.STALE_RUN - 5
        r = bc.call('read', {'proposal': 'p1'})['renders'][0]
        self.assertEqual(r['status'], 'failed')
        self.assertIn('timed out', r['error'])

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_config_defaults_and_revisions(self):
        cfg = bc.call('read', {})['config']
        self.assertEqual(cfg['rev'], 1)
        self.assertIn('corporate events', cfg['company']['positioning'])
        self.assertEqual(cfg['templates'][0]['id'], 'tpl-html')
        self.assertEqual(bc.call('save', {'rev': 1, 'clients': [{'name': 'Google', 'include_prices': 'yes', 'event': 'Holiday'}, {'event': 'no name'}]}), {'rev': 2})
        clients = bc.call('read', {})['config']['clients']
        self.assertEqual(len(clients), 1)
        self.assertIs(clients[0]['include_prices'], False)       # only a real true turns prices on
        self.assertTrue(clients[0]['id'].startswith('c-'))
        with self.assertRaisesRegex(ValueError, 'changed elsewhere'):
            bc.call('save', {'rev': 1, 'company': {}})

    def test_batch_refs_parent_score_pick(self):
        venue = bc.call('asset', {'data': PNG, 'label': 'lobby'})
        self.assertTrue(venue['thumb'].startswith('data:image/'))
        planned = bc.call('plan', {'proposal': 'p1', 'slide': '4', 'models': ['gemini', 'gpt', 'dalle'], 'n': 2, 'prompt': 'arch', 'refs': [venue['id']]})
        self.assertEqual(len(planned['ids']), 4)                   # an unknown model is dropped
        self.assertEqual({e['status'] for e in bc.call('read', {'proposal': 'p1'})['renders']}, {'running'})
        done = bc.call('run', {'ids': planned['ids']})['images']
        self.assertEqual([e['status'] for e in done], ['ok'] * 4)
        self.assertEqual(len(SEEN), 2)                             # one service call per model
        self.assertEqual(SEEN[0][1]['refs'][0], bc.data_url(bc.media(venue['id'])))
        child = bc.call('generate', {'proposal': 'p1', 'slide': '4', 'prompt': 'warmer', 'parent': planned['ids'][0]})['images'][0]
        self.assertEqual(child['parent'], planned['ids'][0])
        self.assertEqual(SEEN[-1][1]['refs'][0], bc.data_url(bc.media(planned['ids'][0])))   # the parent leads
        scored = bc.call('judge', {'id': child['id']})
        self.assertEqual(scored['score'], 8.2)
        self.assertAlmostEqual(scored['cost'], 0.06)
        bc.call('pick', {'id': planned['ids'][1]})
        bc.call('pick', {'id': child['id']})
        picked = [e['id'] for e in bc.call('read', {'proposal': 'p1'})['renders'] if e.get('picked')]
        self.assertEqual(picked, [child['id']])                     # one pick per slide
        self.assertEqual(bc.call('read', {'proposal': 'other'})['renders'], [])

    def test_cap_and_failures_are_recorded(self):
        out = bc.call('generate', {'proposal': 'p1', 'prompt': 'over'})['images'][0]
        self.assertEqual(out['status'], 'failed')
        self.assertIn('over_cap', out['error'])
        self.assertIn('$5.1 of $5', out['error'])
        with self.assertRaisesRegex(ValueError, 'proposal is required'):
            bc.call('plan', {'prompt': 'x'})
        with self.assertRaisesRegex(ValueError, 'image not found'):
            bc.call('plan', {'proposal': 'p', 'prompt': 'x', 'refs': ['0123456789ab']})
        with self.assertRaisesRegex(ValueError, 'image not found'):
            bc.call('media', {'id': '../../etc'})

    def test_origin_is_pinned_and_token_required(self):
        with patch.dict(os.environ, {'BC_STUDIO_URL': 'https://example.com'}):
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                bc.call('usage', {'proposal': 'p'})
        with patch.dict(os.environ, {'BC_STUDIO_TOKEN': 'nope'}):
            with self.assertRaisesRegex(ValueError, 'studio_token_required'):
                bc.call('usage', {'proposal': 'p'})
        self.assertEqual(bc.call('usage', {'proposal': 'p'})['cap'], 5)


if __name__ == '__main__':
    unittest.main()
