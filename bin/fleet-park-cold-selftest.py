#!/usr/bin/env python3
# selftest-entry
"""Cold park (fleet_park_cold.py) on Park's isolated tmux socket: a held park is
cooled by fleet-cleanup-idle.py's Cleaner.cool (window, wrapper and hold page
gone, ID open, cold.json written), and the next wake reopens the window into the
saved screen through fleet-session-wrap.sh's FLEET_PARK_RESTORE_FID road, then
resumes the same conversation. Also: due()'s warm / age rule, and the switch off
writes nothing. BREAK-IT park-cold-wake. No model or live login is used.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
from importlib.util import spec_from_file_location, module_from_spec  # noqa: E402

spec = spec_from_file_location('park_fixture', BIN / 'fleet-park-selftest.py')
fixture = module_from_spec(spec)
spec.loader.exec_module(fixture)
spec = spec_from_file_location('cleanup_idle', BIN / 'fleet-cleanup-idle.py')
cleanup = module_from_spec(spec)
spec.loader.exec_module(cleanup)
import fleet_park_cold as cold  # noqa: E402
import fleet_session_gate as gate  # noqa: E402

FID2 = 'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'


class Due(unittest.TestCase):
    def test_warm_newest_and_age(self):
        now = 100000
        parks = [(fixture_fid(i), now - 4000 + i * 10) for i in range(5)] + [('not-a-fid', 1)]
        with patch.dict(os.environ, FLEET_PARK_WARM='2', FLEET_PARK_COLD_AFTER='1800'):
            got = cold.due(parks, now)
        # the two newest stay warm; the rest are old enough
        self.assertEqual(sorted(got), sorted(fixture_fid(i) for i in range(3)))
        with patch.dict(os.environ, FLEET_PARK_WARM='0', FLEET_PARK_COLD_AFTER='5000'):
            self.assertEqual(cold.due(parks, now), [], 'a park younger than the threshold went cold')

    def test_off_by_default(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop('FLEET_PARK_COLD', None)
            self.assertFalse(cold.enabled())


def fixture_fid(i):
    return '%08x-1111-4222-8333-444444444444' % i


class Cold(fixture.Park):
    def cleaner(self):
        args = SimpleNamespace(socket_name=self.label, session='test', dry_run=False, repo='', main='',
                               base='', limit=4, park_only=True, skip_park=False, forge='none',
                               window_repo=False, only='', grace=None, plan_room=False, fold=False)
        return cleanup.Cleaner(args)

    def reopen_seam(self):
        """fleet-id.sh reopen stands in: a new window running the real wrapper
        with --resume <sid>, the locate seam pointed at it."""
        seam = self.root / 'reopen'
        env = ' '.join(shlex.quote(k + '=' + v) for k, v in self.env.items()
                       if (k.startswith('FLEET_') or k == 'PATH') and 'CRED' not in k and 'ASSERT' not in k)
        seam.write_text('#!/bin/bash\n'
                        'w=$(tmux -L %s new-window -d -P -F "#{window_id}" -t test '
                        '"env %s FLEET_PARK_RESTORE_FID=$1 bash %s --resume %s")\n'
                        'tmux -L %s set-option -w -t "$w" @fleet_id "$1"\n'
                        'tmux -L %s set-option -w -t "$w" @fleet_role worker\n'
                        'printf "%s\\t%%s\\n" "$w" > %s\n'
                        'printf "%%s\\n" "$w" > %s\n'
                        % (self.label, env.replace('"', '\\"'), shlex.quote(str(BIN / 'fleet-session-wrap.sh')),
                           self.sid, self.label, self.label, self.label,
                           shlex.quote(str(self.root / 'locate.out')), shlex.quote(str(self.root / 'new-win'))))
        seam.chmod(0o755)
        loc = self.root / 'locate'
        # as fleet_id_window: a window that is gone is not found (rc 1)
        loc.write_text('#!/bin/sh\n[ -s %s ] && exec cat %s\n'
                       'tmux -L %s list-windows -a -F "#{window_id}" | grep -qx %s || exit 1\n'
                       'printf "%s\\t%s\\n"\n'
                       % (shlex.quote(str(self.root / 'locate.out')), shlex.quote(str(self.root / 'locate.out')),
                          self.label, self.win, self.label, self.win))
        loc.chmod(0o755)
        self.env['FLEET_PARK_COLD_REOPEN_CMD'] = str(seam)

    def test_cool_then_wake_reopens_into_park_then_resumes(self):
        self.parked()
        self.wait(lambda: self.opt('@park_held'))
        self.set('@park_since', str(int(time.time()) - 7200))
        self.env.update(FLEET_PARK_COLD='1', FLEET_PARK_WARM='0', FLEET_PARK_COLD_AFTER='60',
                        FLEET_PARK_COLD_WAKE_SECS='10', FLEET_WINDOW_REAP='0')
        self.reopen_seam()
        old = self.win
        with patch.dict(os.environ, self.env):
            c = self.cleaner()
            snap = c.snapshot(old)
            self.assertIn(self.fid, c.cold_due())
            self.assertTrue(c.cool(old, snap), c.why)
            self.assertNotIn(old, self.tm('list-windows', '-t', 'test', '-F', '#{window_id}').split())
            rec = cold.read(self.fid)
            self.assertTrue(rec, 'no cold record after the window went')
            self.assertEqual(rec['sid'], self.sid)
            self.assertTrue((gate.conf_dir() / 'global/retired' / self.fid).exists(), 'the close was not retired')
            ids = gate.conf_dir() / 'ids' / (self.fid + '.ndjson')
            if ids.exists():
                self.assertNotIn('"closed"', ids.read_text(), 'a cold park ended its ID')
            result = gate.wake(self.fid, why='消息')
        if not result.get('ok'):
            nw = (self.root / 'new-win').read_text().strip() if (self.root / 'new-win').exists() else ''
            log = self.root / 'conf/logs/park.ndjson'
            self.fail('%s\nnew window %s parked=%r\n%s\n--- log\n%s\n--- launch-args\n%s' % (
                result, nw, self.tm('display-message', '-p', '-t', nw, '#{@parked}|#{@park_held}|#{@fleet_id}', check=False) if nw else '',
                self.tm('capture-pane', '-p', '-t', nw, check=False) if nw else '',
                log.read_text() if log.exists() else '',
                (self.root / 'launch-args').read_text() if (self.root / 'launch-args').exists() else ''))
        self.win = (self.root / 'new-win').read_text().strip()
        self.wait(lambda: self.opt('@park_relay'))
        self.assertFalse((self.root / 'conf/session-gate' / self.fid / cold.NAME).exists(),
                         'the cold record outlived its wake')
        self.assertEqual(self.opt('@fleet_id'), self.fid)
        self.assertEqual(self.opt('@cc_session_id'), self.sid)
        self.assertFalse(self.opt('@parked'))
        rows = [json.loads(line) for line in (self.root / 'conf/logs/park.ndjson').read_text().splitlines()]
        self.assertIn('cold-warm', [r.get('event') for r in rows])

    def test_switch_off_cools_nothing(self):
        self.parked()
        self.wait(lambda: self.opt('@park_held'))
        self.set('@park_since', str(int(time.time()) - 7200))
        self.env.pop('FLEET_PARK_COLD', None)
        with patch.dict(os.environ, self.env):
            os.environ.pop('FLEET_PARK_COLD', None)
            self.assertEqual(self.cleaner().cold_due(), set())
        self.assertIn(self.win, self.tm('list-windows', '-t', 'test', '-F', '#{window_id}').split())
        self.assertFalse((gate.fid_dir(self.fid) / cold.NAME).exists())

    def test_draft_keeps_it_warm(self):
        self.parked()
        self.wait(lambda: self.opt('@park_held'))
        self.set('@park_since', str(int(time.time()) - 7200))
        self.env.update(FLEET_PARK_COLD='1', FLEET_PARK_WARM='0', FLEET_PARK_COLD_AFTER='60')
        with patch.dict(os.environ, self.env):
            (gate.fid_dir(self.fid) / 'park-input.txt').write_text('half a sentence')
            c = self.cleaner()
            self.assertFalse(c.cool(self.win, c.snapshot(self.win)))
            self.assertEqual(c.why, 'live')
        self.assertIn(self.win, self.tm('list-windows', '-t', 'test', '-F', '#{window_id}').split())
        self.assertFalse((gate.fid_dir(self.fid) / cold.NAME).exists())


def load_tests(loader, tests, pattern):
    """Only this file's cases: Cold borrows Park's fixture, not its tests."""
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(Due))
    for name in sorted(n for n in vars(Cold) if n.startswith('test_')):
        suite.addTest(Cold(name))
    return suite


if __name__ == '__main__':
    unittest.main()
