#!/usr/bin/env python3
"""Context boundaries on a real isolated tmux bus; no native model requests."""
import importlib.util
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'bin' / file)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@unittest.skipUnless(shutil.which('tmux'), 'tmux required')
class Reset(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ctx-reset-')
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, HOME=self.tmp.name, TMPDIR=self.tmp.name, FLEET_CONF_DIR=self.tmp.name, FLEET_SKIP_GLOBAL_CONF='1', FLEET_UI_LANG='zh')
        self.sock = str(Path(self.tmp.name) / 'tmux')
        self.tmux('new-session', '-d', '-s', 'ctx', 'sleep 120')
        self.addCleanup(lambda: self.tmux('kill-server'))
        self.env.update(TMUX=self.sock + ',0,0', TMUX_PANE=self.tmux('display-message', '-p', '#{pane_id}'))
        env_patch = patch.dict(os.environ, self.env)
        env_patch.start()
        self.addCleanup(env_patch.stop)
        self.tmux('set-window-option', '@mod_alive', str(int(time.time())))
        self.feed('model=Opus 5.5', 'ctx_pct=95', 'ctx_limit=200000')

    def tmux(self, *args):
        return subprocess.check_output(['tmux', '-u', '-S', self.sock, *args], text=True).strip()

    def opt(self, name):
        return self.tmux('display-message', '-p', '#{@' + name + '}')

    def feed(self, *fields):
        subprocess.run(['bash', str(ROOT / 'conf/statusline.sh'), '--from', 'mod', *fields], env=self.env, check=True)

    def test_clear_and_first_measure(self):
        start = time.monotonic()
        self.feed('ctx_reset=clear')
        self.assertLess(time.monotonic() - start, 2)
        self.assertEqual((self.opt('ctx_pct'), self.opt('ctx_left'), self.opt('ctx_band'), self.opt('ctx_est')), ('', '', 'ok', '1'))
        self.assertGreaterEqual(int(self.opt('ctx_ts')), int(time.time()) - 2)
        # A stale statusLine redraw must not restore yesterday's reading.
        subprocess.run(['bash', str(ROOT / 'conf/statusline.sh')],
                       input='{"context_window":{"used_percentage":95}}', text=True, env=self.env, check=True)
        self.assertEqual(self.opt('ctx_pct'), '')
        transcript = Path(self.tmp.name) / 'old.jsonl'
        transcript.write_text(json.dumps({'type': 'assistant', 'message': {'usage': {
            'cache_read_input_tokens': 190000}}}) + '\n')
        context = subprocess.run(['bash', str(ROOT / 'bin/fleet-context.sh'), '--quiet', '--transcript', str(transcript)],
                                 env=self.env, capture_output=True, text=True)
        self.assertEqual(context.stdout.strip(), 'UNKNOWN')
        # Even a very high learned baseline must never enter the handoff input.
        self.feed('ctx_pct=90', 'ctx_measure=1')
        self.assertEqual((self.opt('ctx_pct'), self.opt('ctx_est')), ('90', ''))
        self.feed('ctx_reset=clear')
        self.assertEqual((self.opt('ctx_pct'), self.opt('ctx_left'), self.opt('ctx_band')), ('', '10', 'ok'))
        (Path(self.tmp.name) / 'global').mkdir(exist_ok=True)
        self.tmux('set-window-option', '@raw', '1')
        self.tmux('set-window-option', '@claude_state', 'working')
        stop = subprocess.run(['sh', str(ROOT / 'bin/set-claude-state.sh'), '--via', 'mod', 'done'],
                              env=dict(self.env, FLEET_AUTO_HANDOFF_PCT='80', FLEET_COMPACT_PREP_PCT='50'),
                              capture_output=True, text=True, timeout=15)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        self.assertNotIn('"decision":"block"', stop.stdout.replace(' ', ''))
        self.assertEqual(self.opt('handoff_armed'), '')
        self.assertEqual(self.opt('compact_stage'), '')
        self.feed('ctx_pct=20', 'ctx_measure=1')
        self.feed('ctx_reset=clear')
        self.assertEqual(self.opt('ctx_left'), '45')  # median used: 55
        # Model buckets do not borrow another model's baseline.
        self.feed('model=Sonnet 4.6')
        self.assertEqual(self.opt('ctx_left'), '')

    def test_boundary_hook(self):
        for source in ('startup', 'clear', 'compact', 'resume'):
            self.feed('ctx_pct=95', 'ctx_measure=1')
            subprocess.run(['sh', str(ROOT / 'bin/handoff-latch-reset-hook.sh')],
                           input='{"source":"' + source + '"}', text=True,
                           env=dict(self.env, CLAUDE_CODE_ENTRYPOINT='cli'), check=True)
            self.assertEqual(self.opt('ctx_pct'), '', source)
            self.assertEqual(self.opt('ctx_est'), '1', source)

    def test_without_mod_statusline_still_replaces_placeholder(self):
        self.tmux('set-window-option', '-u', '@mod_alive')
        self.feed('ctx_reset=startup')
        subprocess.run(['bash', str(ROOT / 'conf/statusline.sh')],
                       input='{"context_window":{"used_percentage":12}}', text=True, env=self.env, check=True)
        self.assertEqual((self.opt('ctx_pct'), self.opt('ctx_est')), ('12', ''))
        # A startup redraw before the mod begins must not consume its first sample.
        self.feed('ctx_pct=20', 'ctx_measure=1')
        self.feed('ctx_reset=clear')
        self.assertEqual(self.opt('ctx_left'), '80')

    def test_recent_five_and_resume_does_not_train(self):
        for n in (99, 10, 20, 30, 40, 50):
            self.feed('ctx_reset=startup')
            self.feed('ctx_pct=' + str(n), 'ctx_measure=1')
            self.feed('ctx_pct=98', 'ctx_measure=1')  # second turn is not a sample
        for reason in ('clear', 'compact', 'resume', 'load'):
            self.feed('ctx_reset=' + reason)
            self.assertEqual(self.opt('ctx_left'), '70')
            if reason in ('compact', 'resume'):
                self.feed('ctx_pct=100', 'ctx_measure=1')
        self.feed('ctx_reset=clear')
        self.assertEqual(self.opt('ctx_left'), '70')

    def test_local_and_remote_display(self):
        tb = module('ctx_topbar', 'fleet-topbar.py')
        cli = module('ctx_cli', 'fleet-session-cli.py')
        for band, left, word in [('reset', None, '已清空'), ('est', 10, '≈10%')]:
            rec = dict(ctx_band=band, ctx_ts=int(time.time()))
            if left is not None:
                rec['ctx_left'] = left
            parts = tb.ctx_parts(rec, 144, int(time.time()))
            self.assertIn(word, parts[0][0])
            self.assertEqual(parts[0][1], tb.DIM)
            self.assertIn(word, cli.left_cell(dict(left='' if left is None else str(left), band=band), True))
            self.assertIn('\x1b[90m', cli.left_cell(dict(left='' if left is None else str(left), band=band), True))
            panel = tb.FV
            cell = ('|' if left is None else str(left) + '|') + band
            self.assertIn(word, panel.context_word(cell))
            segs = panel.row_segs(dict(text='task', ctx=cell), 144, tb.cells, tb.clip)
            self.assertTrue(any(word in text and 'dim' in styles for text, styles in segs))


if __name__ == '__main__':
    unittest.main()
