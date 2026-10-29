#!/usr/bin/env python3
# selftest-entry
# Reads fleet_studio.py, hooks/studio-guard.py, extras/web-chat/studio.mjs and
# fleet-mcp.py. Isolated projection and native MCP publication confirmation.
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

import fleet_studio as studio

ROOT = Path(__file__).resolve().parent.parent
FID = '12345678-1234-4234-8234-123456789abc'


class StudioTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {'FLEET_WEBCHAT_STATE': self.tmp.name})
        self.env.start()
        studio.call('bind', {'key': 'new-one', 'fid': FID, 'agent': 'claude', 'embed_origin': 'https://hub.example.com'})

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def show(self, **kw):
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).isoformat()
        studio.call('show', dict(fid=FID, proposal_id='page1', title='A real page', version_id='v1',
                                 status='hold', embed_url='https://pages.example.com/preview', embed_expires=expires, **kw))

    def approve(self, **kw):
        return studio.call('action', dict(fid=FID, action='publish', id=str(uuid.uuid4()),
                                          version_id='v1', confirmed=True, **kw))

    def test_roundtrip_and_foreign_page(self):
        self.show()
        state = studio.call('read', {})
        self.assertEqual(state['sessions']['new-one']['proposal_id'], 'page1')
        self.assertEqual(state['projects'][0]['title'], 'A real page')
        with self.assertRaises(ValueError):
            studio.call('show', dict(fid=FID, proposal_id='page2', title='wrong'))
        self.assertEqual(studio.call('target', {'fid': FID})['versions'][0]['status'], 'hold')

    def test_preview_and_confirmation_required(self):
        with self.assertRaises(ValueError):
            self.approve()
        self.show()
        for changes in ({'confirmed': False}, {'version_id': 'other'}, {'version_id': ''}):
            with self.assertRaises(ValueError):
                studio.call('action', dict(fid=FID, action='publish', id=str(uuid.uuid4()), version_id='v1', confirmed=True) | changes)
        a = self.approve()
        self.assertEqual(studio.call('action', dict(a, fid=FID)), a)
        self.assertEqual(len(studio.call('target', {'fid': FID})['actions']), 1)

    def test_partial_updates_keep_links_and_preview(self):
        self.show(url='https://pages.example.com/live', visibility='private')
        studio.call('show', dict(fid=FID, proposal_id='page1', title='A real page', analytics='12 reads'))
        studio.call('show', dict(fid=FID, proposal_id='page1', title='A real page', version_id='v1', status='ready'))
        s = studio.call('target', {'fid': FID})
        self.assertEqual(s['url'], 'https://pages.example.com/live')
        self.assertEqual(s['visibility'], 'private')
        self.assertEqual(s['versions'][0]['embed'], 'https://pages.example.com/preview')
        self.assertGreater(studio.epoch(s['versions'][0]['embed_exp']), 0)
        self.assertEqual(s['analytics']['summary'], '12 reads')

    def test_expired_and_unsafe_preview(self):
        self.show()
        with studio.book() as state:
            state['sessions']['new-one']['versions'][0]['embed_exp'] = '2000-01-01T00:00:00Z'
        with self.assertRaises(ValueError):
            self.approve()
        self.assertEqual(studio.https('javascript:alert(1)'), '')
        self.assertEqual(studio.https('https://user:password@example.com'), '')

    def test_native_publish_guard_exact_once(self):
        self.show()
        with self.assertRaises(ValueError):
            studio.guard_space(FID, 'publish_file', {'proposal_id': 'page1'})
        studio.guard_space(FID, 'publish_file', {'proposal_id': 'page1', 'hold': True})
        with self.assertRaises(ValueError):
            studio.guard_space(FID, 'publish_version', {'version_id': 'v1'})
        self.approve()
        with self.assertRaises(ValueError):
            studio.guard_space(FID, 'publish_version', {'version_id': 'v2'})
        studio.guard_space(FID, 'publish_version', {'version_id': 'v1'})
        with self.assertRaises(ValueError):
            studio.guard_space(FID, 'publish_version', {'version_id': 'v1'})
        studio.guard_space('another-session', 'publish_version', {'version_id': 'v1'})

    def test_multilingual_confirmation_is_per_page(self):
        self.show()
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).isoformat()
        studio.call('show', dict(fid=FID, related=True, proposal_id='page-en', title='English', version_id='v-en',
                                status='hold', embed_url='https://pages.example.com/en', embed_expires=expires))
        self.assertEqual(len(studio.call('target', {'fid': FID})['related_pages']), 2)
        self.approve()
        with self.assertRaises(ValueError):
            studio.guard_space(FID, 'publish_version', {'version_id': 'v-en'})
        studio.call('action', dict(fid=FID, proposal_id='page-en', action='publish', version_id='v-en',
                                  id=str(uuid.uuid4()), confirmed=True))
        studio.guard_space(FID, 'publish_version', {'version_id': 'v-en'})

    def test_webchat_binding(self):
        subprocess.run(['node', str(ROOT / 'extras/web-chat/studio.test.mjs')], cwd=ROOT, check=True)

    def test_remote_space_hook(self):
        self.show()
        fake = Path(self.tmp.name) / 'tmux'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "' + FID + '"\n')
        fake.chmod(0o700)
        env = dict(os.environ, PATH=self.tmp.name + ':' + os.environ['PATH'], TMUX_PANE='%7')
        def run(tool, args):
            return subprocess.run(['python3', str(ROOT / 'hooks/studio-guard.py')],
                                  input=json.dumps({'tool_name': tool, 'tool_input': args}),
                                  env=env, text=True, capture_output=True).returncode
        self.assertEqual(run('mcp__space__publish_version', {'version_id': 'v1'}), 2)
        self.approve()
        self.assertEqual(run('mcp__space__publish_version', {'version_id': 'v1'}), 0)
        self.assertEqual(run('mcp__space__publish_version', {'version_id': 'v1'}), 2)
        self.assertEqual(run('mcp__space__list_examples', {}), 0)


if __name__ == '__main__':
    unittest.main()
