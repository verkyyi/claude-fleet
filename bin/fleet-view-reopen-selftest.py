#!/usr/bin/env python3
# selftest-entry
"""已收起's closed IDs: 恢复 reopens this machine's own through fleet-id.sh reopen,
every other closed row says why it cannot, and no probe is listed.

  A  fleet-id.sh reopen --check: `ok` when --exec would spawn, the refusal (rc 1)
     when the conversation is gone — and --check never spawns
  B  a ledger row of this machine, no task: 恢复 on its page and in its menu;
     grey with the reason when the check refuses
  C  恢复 runs fleet-id.sh reopen <ID> --exec, then the 看台 goes to the window
     carrying that @fleet_id; a refusal is said, nothing gone to
  D  a task's closed row: no 恢复 (its history is read-only, #5396) — the page
     says so instead of being empty; another machine's says where it is
  E  board_apply: the hub's closed probe rows are left out; a closed row is
     `home` only when its machine and login are these
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import fleet_view as view

BIN = Path(__file__).resolve().parent
FID = '11111111-1111-4111-8111-111111111111'
NAT = '22222222-2222-4222-8222-222222222222'


def ledger_row(**kw):
    row = dict(kind='sess', target='id:' + FID, fid=FID, gone=True, ledger=True, far=True, record_only=True,
               home=True, sec='gone', state='exited', text='hello', machine='mac-a', login='alice')
    row.update(kw)
    return row


class ReopenCheckTests(unittest.TestCase):
    """A: the road itself, in a sandbox (a ledger, a transcript, a fake spawner)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = Path(self.tmp.name)
        (t / 'conf/ids').mkdir(parents=True)
        self.proj = t / 'home/.claude/projects/-tmp-x'
        self.proj.mkdir(parents=True)
        (t / 'conf/ids' / (FID + '.ndjson')).write_text(''.join(json.dumps(e) + '\n' for e in (
            dict(ev='opened', agent='claude', title='hello', id=FID, seq=1, ts=1700000000),
            dict(ev='native', agent='claude', native=NAT, trigger='startup', source='startup', seg=1, id=FID,
                 seq=2, ts=1700000001),
            dict(ev='closed', reason='exited', id=FID, seq=3, ts=1700000100))))
        (self.proj / (NAT + '.jsonl')).write_text(json.dumps(
            dict(type='user', sessionId=NAT, cwd='/tmp/x', message=dict(role='user', content='hi'))) + '\n')
        self.spawned = t / 'spawned'
        spawn = t / 'spawn'
        spawn.write_text('#!/bin/sh\necho "$*" > "%s"\n' % self.spawned)
        spawn.chmod(0o755)
        self.env = dict(PATH='/usr/bin:/bin:' + os.environ.get('PATH', ''), HOME=str(t / 'home'),
                        FLEET_CONF_DIR=str(t / 'conf'), FLEET_ID_PUSH='0', FLEET_ID_SPAWN=str(spawn))

    def reopen(self, *flags):
        return subprocess.run(['bash', str(BIN / 'fleet-id.sh'), 'reopen', FID] + list(flags), env=self.env,
                              capture_output=True, text=True, timeout=60)

    def test_check_says_ok_and_spawns_nothing(self):
        p = self.reopen('--check')
        self.assertEqual((p.returncode, p.stdout.strip()), (0, 'ok'), p.stderr)
        self.assertFalse(self.spawned.exists(), '--check must not spawn')
        p = self.reopen('--exec')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('--resume %s' % NAT, self.spawned.read_text())
        self.assertIn('--fid %s' % FID, self.spawned.read_text())

    def test_check_refuses_with_the_reason_when_the_conversation_is_gone(self):
        (self.proj / (NAT + '.jsonl')).unlink()
        p = self.reopen('--check')
        self.assertEqual(p.returncode, 1)
        self.assertIn('Native file not located', p.stderr)
        self.assertFalse(self.spawned.exists())
        p = self.reopen('--check', '--rebuild')
        self.assertEqual(p.returncode, 1, '--rebuild never stands in for a missing conversation')


class RebuildTests(unittest.TestCase):
    """A': a scratch worktree the reaper removed, its conversation whole — --rebuild
    makes it again at the same path, off the old branch when origin has it."""

    def git(self, *a, cwd=None):
        subprocess.run(['git', '-c', 'user.email=t@t', '-c', 'user.name=t'] + list(a), cwd=cwd, check=True,
                       capture_output=True, timeout=60)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        t = Path(self.tmp.name).resolve()
        self.git('init', '-q', '--bare', '-b', 'master', str(t / 'origin.git'))
        self.main = t / 'proj/repo'
        self.git('clone', '-q', str(t / 'origin.git'), str(self.main))
        (self.main / 'a').write_text('master\n')
        self.git('add', 'a', cwd=self.main)
        self.git('commit', '-qm', 'one', cwd=self.main)
        self.git('push', '-q', 'origin', 'master', cwd=self.main)
        self.git('checkout', '-qb', 'feat', cwd=self.main)
        (self.main / 'a').write_text('feat\n')
        self.git('commit', '-qam', 'feat', cwd=self.main)
        self.git('push', '-q', 'origin', 'feat', cwd=self.main)
        self.git('checkout', '-q', 'master', cwd=self.main)
        conf = t / 'conf'
        (conf / 'fleets/fs/repos').mkdir(parents=True)
        (conf / 'fleets/fs/conf').write_text('')
        (conf / 'fleets/fs/repos/o-r.conf').write_text(
            'FLEET_REPO="o/r"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH=master\n' % self.main)
        (conf / 'fleets/fs/repos/.order').write_text('o-r\n')
        (conf / 'ids').mkdir()
        self.wt = t / 'proj/repo-scratch-3'
        (conf / 'ids' / (FID + '.ndjson')).write_text(''.join(json.dumps(e) + '\n' for e in (
            dict(ev='opened', agent='claude', title='hello', id=FID, repo='o/r', worktree=str(self.wt), seq=1,
                 ts=1700000000),
            dict(ev='native', agent='claude', native=NAT, trigger='startup', source='startup', seg=1, id=FID,
                 seq=2, ts=1700000001),
            dict(ev='closed', reason='exited', id=FID, seq=3, ts=1700000100))))
        self.proj = t / 'home/.claude/projects/-proj-repo-scratch-3'
        self.proj.mkdir(parents=True)
        self.spawned = t / 'spawned'
        spawn = t / 'spawn'
        spawn.write_text('#!/bin/sh\necho "$*" > "%s"\n' % self.spawned)
        spawn.chmod(0o755)
        self.env = dict(PATH='/usr/bin:/bin:' + os.environ.get('PATH', ''), HOME=str(t / 'home'),
                        FLEET_CONF_DIR=str(conf), FLEET_SESSION='fs', FLEET_ID_PUSH='0',
                        FLEET_ID_SPAWN=str(spawn), FLEET_WORKTREE_ROOT='', GIT_TERMINAL_PROMPT='0')

    def transcript(self, branch):
        (self.proj / (NAT + '.jsonl')).write_text(json.dumps(
            dict(type='user', sessionId=NAT, cwd=str(self.wt), gitBranch=branch,
                 message=dict(role='user', content='hi'))) + '\n')

    def reopen(self, *flags):
        return subprocess.run(['bash', str(BIN / 'fleet-id.sh'), 'reopen', FID] + list(flags), env=self.env,
                              capture_output=True, text=True, timeout=120)

    def test_rebuilds_off_the_base_when_its_branch_never_reached_origin(self):
        self.transcript('scratch-3')
        p = self.reopen('--check')
        self.assertEqual(p.returncode, 1)
        self.assertIn('Recorded worktree is gone', p.stderr)
        p = self.reopen('--check', '--rebuild')
        self.assertEqual((p.returncode, p.stdout.strip()), (0, 'ok rebuild master'), p.stderr)
        self.assertFalse(self.wt.exists(), '--check makes nothing')
        p = self.reopen('--exec', '--rebuild')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((self.wt / 'a').read_text(), 'master\n')
        self.assertIn('restore-11111111', subprocess.run(['git', '-C', str(self.wt), 'branch', '--show-current'],
                                                         capture_output=True, text=True).stdout)
        self.assertIn('made again off origin/master', p.stderr)
        self.assertIn('--worktree %s' % self.wt, self.spawned.read_text())
        self.assertIn('--fid %s' % FID, self.spawned.read_text())

    def test_rebuilds_off_its_own_branch_when_origin_has_it(self):
        self.transcript('feat')
        p = self.reopen('--check', '--rebuild')
        self.assertEqual(p.stdout.strip(), 'ok rebuild feat', p.stderr)
        p = self.reopen('--exec', '--rebuild')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual((self.wt / 'a').read_text(), 'feat\n')

    def test_refuses_a_worktree_that_was_not_a_scratch(self):
        led = Path(self.env['FLEET_CONF_DIR']) / 'ids' / (FID + '.ndjson')
        led.write_text(led.read_text().replace('repo-scratch-3', 'repo-issue-9'))
        self.transcript('scratch-3')
        p = self.reopen('--check', '--rebuild')
        self.assertEqual(p.returncode, 1)
        self.assertIn('was not a scratch worktree', p.stderr)


class PanelTests(unittest.TestCase):
    def setUp(self):
        view._REOPEN.clear()
        self.addCleanup(view._REOPEN.clear)
        for name, value in (('ui_lang', 'en'), ('say', lambda key, *a: ' '.join((key,) + tuple(map(str, a))))):
            p = patch.object(view, name, return_value=value) if name == 'ui_lang' else patch.object(view, name, value)
            p.start()
            self.addCleanup(p.stop)

    def test_B_own_ledger_row_offers_restore(self):
        row = ledger_row()
        self.assertTrue(view.reopen_row(row))
        self.assertEqual([a['id'] for a, _ in view.menu_of(row)], ['resume'])
        with patch.object(view, 'reopen_why', return_value=''):
            self.assertEqual([(a['id'], why) for a, _, why in view.page_of(row)], [('resume', '')])
        with patch.object(view, 'reopen_why', return_value="Can't restore: worktree is gone"):
            self.assertEqual([(a['id'], why) for a, _, why in view.page_of(row)],
                             [('resume', "Can't restore: worktree is gone")])
        # a ledger row made here (no hub row): far is False, home by default
        local = ledger_row(far=False, record_only=False)
        local.pop('home')
        self.assertTrue(view.reopen_row(local))

    def test_B_check_reason_is_asked_once(self):
        calls = []

        def run(argv, **kw):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 1, '', 'Native file not located\n')
        with patch.object(view.subprocess, 'run', side_effect=run):
            why = view.reopen_why(ledger_row())
            self.assertEqual(why, "Can't restore: Native file not located")
            view.reopen_why(ledger_row())
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-4:], ["reopen", FID, "--check", "--rebuild"])

    def test_C_restore_runs_the_reopen_road_and_goes_there(self):
        row = ledger_row()
        runs = []

        def run(argv, **kw):
            runs.append(argv)
            return subprocess.CompletedProcess(argv, 0, '', '')
        with patch.object(view.subprocess, 'run', side_effect=run), \
                patch.object(view, 'act_env', return_value={}), \
                patch.object(view, 'tm', return_value=(0, '@7\tother\n@9\t' + FID)), \
                patch.object(view, 'go', return_value=0) as go:
            rc, said, went = view.act_run(None, 'v', 'fleet', view.ACTION['resume'], row, '')
        self.assertEqual((rc, went), (0, True))
        self.assertEqual(runs[0][-4:], ["reopen", FID, "--exec", "--rebuild"])
        self.assertEqual(go.call_args.args[2], '@9')
        with patch.object(view.subprocess, 'run',
                          return_value=subprocess.CompletedProcess([], 1, '', 'Recorded worktree is gone\n')), \
                patch.object(view, 'act_env', return_value={}), patch.object(view, 'go') as go:
            rc, said, went = view.act_run(None, 'v', 'fleet', view.ACTION['resume'], row, '')
        self.assertEqual((rc, went), (1, False))
        self.assertIn('Recorded worktree is gone', said)
        go.assert_not_called()

    def test_D_task_rows_reopen_the_conversation_only(self):
        for task in (ledger_row(task='T42'),
                     dict(ledger_row(task='T42', far=False, ledger=False, record_only=False),
                          target='landed:scratch:scratch-3@o/r')):
            self.assertTrue(view.reopen_row(task), task['target'])
            self.assertEqual([a['id'] for a, _ in view.menu_of(task)], ['resume'])
            with patch.object(view, 'reopen_check', return_value=('', 'master')):
                page = view.page_of(task)
            self.assertEqual(page[0][2], '')
            self.assertIn('worktree rebuilt from master', page[0][1])
            self.assertIn('conversation only, task unchanged', page[0][1])
            runs = []
            with patch.object(view.subprocess, 'run', side_effect=lambda argv, **kw: runs.append(argv) or
                              subprocess.CompletedProcess(argv, 0, '', '')), \
                    patch.object(view, 'act_env', return_value={}), patch.object(view, 'tm', return_value=(0, '')), \
                    patch.object(view, 'continue_task', side_effect=AssertionError('no task write')):
                self.assertEqual(view.act_run(None, 'v', 'fleet', view.ACTION['resume'], task, '')[0], 0)
            self.assertEqual(runs[0][-4:], ['reopen', FID, '--exec', '--rebuild'])

    def test_D_far_and_unrecorded_rows_say_why(self):
        far = ledger_row(home=False, machine='mac-b')
        self.assertFalse(view.reopen_row(far))
        self.assertEqual(view.page_of(far)[0][2], 'On mac-b — restore it from that machine')
        bare = dict(ledger_row(task='T42', far=False, ledger=False), target='landed:scratch:scratch-3@o/r', fid='')
        self.assertFalse(view.reopen_row(bare))
        self.assertEqual(view.page_of(bare)[0][2], 'No session is recorded for this row — nothing to reopen')
        with patch.object(view.subprocess, 'run', side_effect=AssertionError('nothing to launch')):
            self.assertEqual(view.act_run(None, 'v', 'fleet', view.ACTION['resume'], bare, '')[0], 1)

    def test_E_board_drops_probes_and_marks_home(self):
        board = {'rows': [
            dict(id=FID, group='gone', title='hello', machine='mac-a', login='alice', tag='ended'),
            dict(id=NAT, group='gone', title='Controlled acceptance only. Reply exactly OK', machine='mac-a',
                 login='alice', tag='ended'),
            dict(id='33333333-3333-4333-8333-333333333333', group='gone', title='x', machine='mac-b',
                 login='alice', tag='ended')]}
        groups, gone = view.board_apply(board, {g: [] for g in view.GROUPS}, [], [], 'mac-a', 'alice')
        self.assertEqual([e['fid'] for e in gone], [FID, '33333333-3333-4333-8333-333333333333'])
        self.assertEqual([e['home'] for e in gone], [True, False])


if __name__ == '__main__':
    unittest.main()
