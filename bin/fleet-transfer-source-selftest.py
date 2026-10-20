#!/usr/bin/env python3
# selftest-entry  (run-selftests.sh runs this file by its shebang; T525)
"""fleet_transfer_source.py — the source checks a manual move keeps (T546).

Moved unchanged from the retired quota failover planner: `settled` (a looping
Codex between rounds, #786), the background inventory (#873) and
`terminate-background` (#871). Isolated: no live tmux or provider calls.
"""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m


src = module('transfer_source', 'fleet_transfer_source.py')


class Settled(unittest.TestCase):
    def test_manual_transfer_accepts_only_a_settled_looping_codex_round(self):
        source = dict(session='test', window='@2', pane='%2', pid=42, session_id='source', agent='codex', state='looping')
        idle = lambda last, items=(dict(status='completed'),), kind='idle': dict(
            status={'type': kind}, turns=[dict(status=last, items=list(items))])
        with patch.object(src, 'inspect', return_value=source), patch.object(src, 'native_thread') as thread:
            thread.return_value = idle('completed'); src.settled('test', '%2')
            for bad, why in ((idle('interrupted'), 'between rounds'), (idle('completed', kind='active'), 'still active'),
                             (idle('completed', [dict(status='inProgress')]), 'tool is still active')):
                thread.return_value = bad
                with self.assertRaisesRegex(ValueError, why): src.settled('test', '%2')
            thread.return_value = idle('completed')
            for other in (dict(source, state='working'), dict(source, agent='claude')):
                src.inspect.return_value = other
                with self.assertRaisesRegex(ValueError, 'between rounds'): src.settled('test', '%2')


class Background(unittest.TestCase):
    def setUp(self):
        self.source = dict(session='test', window='@2', pane='%2', pid=42, session_id='s', agent='claude',
                           worktree='/w', transcript='/t', state='working')
        self.sleep = module('sleep_bg', 'fleet_worker_life.py')
        # A `next dev` shell: zsh (43) → node (44), neither an MCP server.
        rows = {43: (42, 'zsh'), 44: (43, 'node')}
        self.argv = {42: ['claude'], 43: ['/bin/zsh', '-c', 'next dev -p 3117'], 44: ['node', 'next', 'dev']}
        mods = {'fleet_worker_life.py': vars(self.sleep), 'fleet_agent_argv.py': {'process_argv': lambda pid: self.argv[pid]}}
        for p in (patch.dict(self.sleep.TRANSFER, process_rows=lambda: rows),
                  patch.dict(self.sleep.MCP, claude_inventory=lambda *a: {}, classify=lambda *a: set()),
                  patch.dict(self.sleep.ARGV, process_argv=lambda pid: self.argv[pid],
                             process_executable=lambda pid: Path(self.argv[pid][0])),
                  patch.object(src.runpy, 'run_path', side_effect=lambda f: mods[Path(f).name]),
                  patch.object(src, 'process_start', return_value=('S', 'Mon Sep 20 10:00:00 2026')),
                  patch.object(src, 'process_cwd', return_value='/w/web')):
            p.start(); self.addCleanup(p.stop)

    def test_the_inventory_collects_what_hibernation_would_veto(self):
        with self.assertRaisesRegex(ValueError, 'pid=43'): self.sleep.quiet_processes(self.source)
        bg = src.background_inventory(self.source)
        self.assertEqual([(e['pid'], e['argv'], e['cwd']) for e in bg],
                         [(43, self.argv[43], '/w/web'), (44, self.argv[44], '/w/web')])
        note = src.background_note(bg)
        self.assertIn('Background commands terminated by migration', note)
        self.assertIn("/bin/zsh -c 'next dev -p 3117'", note)

    def test_claude_background_collects_a_named_pids_children(self):
        with patch.object(src, 'background_inventory', side_effect=lambda s: [s]):
            s = src.claude_background('42', '/w', 'fleet-x')[0]
        self.assertEqual((s['pid'], s['agent'], s['worktree'], s['session']), (42, 'claude', '/w', 'fleet-x'))


class TerminateBackground(unittest.TestCase):
    def test_only_the_recorded_live_process_is_stopped_and_named(self):
        with tempfile.TemporaryDirectory() as tmp:
            req = Path(tmp) / 'req'; bundle = Path(tmp) / 'bundle'; req.mkdir(); bundle.mkdir()
            (bundle / 'pickup.md').write_text('pickup\n'); (bundle / 'handoff.md').write_text('handoff\n')
            job = subprocess.Popen(['sleep', '60']); self.addCleanup(lambda p=job: (p.kill(), p.wait()))
            reused = subprocess.Popen(['sleep', '60']); self.addCleanup(lambda p=reused: (p.kill(), p.wait()))
            start = src.process_start(job.pid)[1]
            src.save(req / 'background.json', [
                dict(pid=job.pid, argv=['sleep', '60'], cwd=tmp, start=start),
                # a recorded pid now held by a DIFFERENT process must survive
                dict(pid=reused.pid, argv=['old'], cwd=tmp, start='Thu Jan  1 00:00:00 1970')])
            src.terminate_background(req, bundle)
            self.assertEqual(job.wait(timeout=5), -15)
            self.assertIsNone(reused.poll())
            self.assertEqual([e['stopped'] for e in src.read(req / 'background.json')], ['SIGTERM', 'exited'])
            for name in ('pickup.md', 'handoff.md'):
                text = (bundle / name).read_text()
                self.assertIn('Background commands terminated by migration', text)
                self.assertIn('`sleep 60` (cwd `%s`)' % tmp, text)

    def test_forced_migrate_prints_its_own_note_and_touches_no_bundle(self):
        # fleet-migrate.sh --force-bg (#873): the note comes back on stdout.
        with tempfile.TemporaryDirectory() as tmp:
            req = Path(tmp) / 'req'; req.mkdir()
            job = subprocess.Popen(['sleep', '61']); self.addCleanup(lambda p=job: (p.kill(), p.wait()))
            src.save(req / 'background.json', [dict(pid=job.pid, argv=['sleep', '61'], cwd=tmp,
                                                    start=src.process_start(job.pid)[1])])
            out = io.StringIO()
            with contextlib.redirect_stdout(out): src.terminate_background(req, None, 'The operator forced this move')
            self.assertEqual(job.wait(timeout=5), -15)
            self.assertIn('The operator forced this move, so these background commands', out.getvalue())
            self.assertEqual(list(Path(tmp).iterdir()), [req])


class Cli(unittest.TestCase):
    def test_the_retired_planner_and_its_entry_points_are_gone(self):
        bin_ = Path(__file__).parent
        self.assertFalse((bin_ / '.fleet-failover.py').exists())
        for args, word in ((['bash', str(bin_ / 'fleet-account.sh'), 'reconcile', '--session', 'x'], '已不用'),
                           (['bash', str(bin_ / 'fleet-account.sh'), 'failover-status'], '已不用')):
            r = subprocess.run(args, capture_output=True, text=True, timeout=30,
                               env=dict(os.environ, FLEET_SKIP_GLOBAL_CONF='1'))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(word, r.stderr)
        r = subprocess.run(['bash', str(bin_ / 'fleet-migrate.sh'), '--limited', '--session', 'x'],
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 2); self.assertIn('已不用', r.stderr)


if __name__ == '__main__':
    unittest.main()
