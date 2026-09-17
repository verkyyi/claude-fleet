#!/usr/bin/env python3
"""Identity resolution and actual tmux renumbering, without live-server access."""
import importlib.util
from pathlib import Path
import os
import shutil
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
BIN = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('target', BIN / 'fleet-reap-target.py')
target = importlib.util.module_from_spec(spec)
spec.loader.exec_module(target)


class TargetTests(unittest.TestCase):
    def resolve(self, value, rows):
        def read(*args):
            if args[1] == 'list-windows':
                return '\n'.join(rows)
            wid, fmt = args[4], args[5]
            if wid == '%30':
                wid = '@3'
            if wid not in rows:
                raise subprocess.CalledProcessError(1, args)
            key = fmt[2:-1]
            return wid if key == 'window_id' else rows[wid].get(key, '')
        with patch.object(target, 'read', side_effect=read):
            return target.resolve(value)

    def test_exact_ids_handles_and_explicit_issues(self):
        rows = {'@3': {'@wid': 'a1', '@issue': '57'}, '@4': {}}
        for value in ('@3', '%30', 'a1', 'issue-57', '#57'):
            self.assertEqual(self.resolve(value, rows), '@3')
        for value in ('57', ':3', 'fleet:3', 'name', 'a2', 'issue-99', '@99'):
            with self.assertRaises((ValueError, subprocess.SubprocessError)):
                self.resolve(value, rows)

    def test_missing_and_duplicate_identity_never_fall_back(self):
        rows = {'@3': {'@wid': 'a1', '@issue': '57'}, '@4': {'@wid': 'a1', '@issue': '57'}}
        for value in ('a1', 'issue-57', '#57'):
            with self.assertRaisesRegex(ValueError, 'matched 2'):
                self.resolve(value, rows)
        with self.assertRaisesRegex(ValueError, 'matched 0'):
            self.resolve('a2', {'@3': {'window_name': 'a2'}})

    def test_scratch_binding_is_authoritative_and_path_is_not_delimited(self):
        rows = {'@3': {'@worktree': '/repo with | spaces-scratch-7', 'pane_current_path': '/repo-scratch-8'},
                '@4': {'pane_current_path': '/repo-scratch-9/'}}
        self.assertEqual(self.resolve('scratch-7', rows), '@3')
        self.assertEqual(self.resolve('scratch-9', rows), '@4')
        for value in ('scratch-8', 'scratch-10'):
            with self.assertRaises(ValueError):
                self.resolve(value, rows)
        rows['@4']['@worktree'] = '/other-scratch-7'
        with self.assertRaisesRegex(ValueError, 'matched 2'):
            self.resolve('scratch-7', rows)
        for path in ('/repo-scratch-7/docs', '/repo-scratch-7 ', '/repo-scratch-7\n'):
            with self.assertRaises(ValueError):
                self.resolve('scratch-7', {'@3': {'@worktree': path}})

    def test_metadata_errors_fail_closed(self):
        for error in (OSError('missing tmux'), subprocess.TimeoutExpired('tmux', 5)):
            with patch.object(target, 'read', side_effect=error), patch.object(sys, 'argv', ['probe', '@3']):
                self.assertEqual(target.main(), 4)
        with patch.object(target, 'read', return_value='@4'):
            with self.assertRaisesRegex(ValueError, 'disappeared'):
                target.resolve('@3')

    @unittest.skipUnless(shutil.which('tmux'), 'tmux unavailable')
    def test_real_renumber_preserves_captured_row_identity(self):
        tmux = shutil.which('tmux')
        label = 'reap-target-selftest-'+str(os.getpid())
        def tm(*args):
            return subprocess.check_output([tmux, '-L', label, *args], text=True, stderr=subprocess.DEVNULL).strip()
        try:
            first = tm('-f', '/dev/null', 'new-session', '-d', '-s', label, '-P', '-F', '#{window_id}', 'sleep 45')
            tm('set-option', '-t', label, 'renumber-windows', 'on')
            selected = tm('new-window', '-d', '-t', label, '-P', '-F', '#{window_id}', 'sleep 45')
            index = tm('display-message', '-p', '-t', selected, '#{window_index}')
            other = tm('new-window', '-d', '-t', label, '-P', '-F', '#{window_id}', 'sleep 45')
            tm('kill-window', '-t', first)  # private fixture server ONLY
            self.assertEqual(tm('display-message', '-p', '-t', label+':'+index, '#{window_id}'), other)
            original = target.read
            with patch.object(target, 'read', side_effect=lambda *args: original(tmux, '-L', label, *args[1:])):
                self.assertEqual(target.resolve(selected), selected)
                for value in (index, ':'+index, label+':'+index):
                    with self.assertRaisesRegex(ValueError, 'refused'):
                        target.resolve(value)
        finally:
            subprocess.run([tmux, '-L', label, 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == '__main__':
    unittest.main(verbosity=2)
