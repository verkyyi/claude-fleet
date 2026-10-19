#!/usr/bin/env python3
"""Real isolated tmux/git cleanup versus the existing transition lock. No native launch."""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fleet_native_continue as continuation

BIN = Path(__file__).resolve().parent
TRANSFER = runpy.run_path(str(BIN / '.fleet-transfer.py'))


@unittest.skipUnless(shutil.which('tmux'), 'tmux required')
class Cleanup(unittest.TestCase):
    def run_cmd(self, *args, **kw):
        return subprocess.run(list(map(str, args)), env=self.env, cwd=self.root,
                              text=True, capture_output=True, timeout=20, **kw)

    def tm(self, *args):
        r = self.run_cmd('tmux', '-S', self.socket, *args)
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='continue-cleanup-', dir='/tmp')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.base, self.work = self.root/'base', self.root/'work'
        self.conf = self.root/'conf'; self.conf.mkdir()
        self.socket = str(self.root/'tmux')
        self.env = dict(PATH=os.environ['PATH'], HOME=str(self.root), TMPDIR=str(self.root),
                        FLEET_CONF_DIR=str(self.conf), FLEET_SESSION='fixture',
                        FLEET_REPO='fixture/repo', FLEET_MAIN=str(self.base),
                        FLEET_BASE_BRANCH='master', FLEET_CLEANUP_MERGED_GRACE='0',
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        for args in [('init','-q',self.base), ('-C',self.base,'config','user.email','fixture@example.invalid'),
                     ('-C',self.base,'config','user.name','fixture'),
                     ('-C',self.base,'commit','--allow-empty','-qm','base'),
                     ('-C',self.base,'worktree','add','-qb','issue-42',self.work)]:
            self.run_cmd('git', *args, check=True)
        fake = self.root/'fake'; fake.mkdir()
        gh = fake/'gh'
        gh.write_text('#!/bin/sh\nprintf "MERGED\\tfixture-head\\tissue-42\\t-\\t2020-01-01T00:00:00Z\\tfixture/repo#42\\n"\n')
        gh.chmod(0o755)
        self.env['PATH'] = str(fake)+os.pathsep+self.env['PATH']
        local = self.root/'bin'; local.mkdir()
        for source in BIN.iterdir():
            if source.is_file(): (local/source.name).symlink_to(source)
        self.clean = local/'fleet-cleanup.sh'
        self.addCleanup(lambda: self.run_cmd('tmux','-S',self.socket,'kill-server'))
        self.pane = self.tm('-f','/dev/null','new-session','-d','-s','fixture','-c',self.work,
                            '-P','-F','#{pane_id}', 'sleep 120')
        self.win = self.tm('display-message','-p','-t',self.pane,'#{window_id}')
        self.env['TMUX'] = self.socket+','+self.tm('display-message','-p','#{pid}')+',0'
        for k,v in {'@repo':'fixture/repo','@issue':'42','@worktree':str(self.work),
                    '@fleet_role':'worker','@fleet_id':'11111111-1111-4111-8111-111111111111',
                    '@cc_agent':'codex','@cc_launcher_pid':'123','@authority_receipt':'source-receipt',
                    '@claude_state':'done'}.items():
            self.tm('set-option','-w','-t',self.pane,k,v)

    def clean_now(self, *args):
        result = self.run_cmd('bash',self.clean,'--pr','42',*args)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        return result.stdout.strip()

    def test_each_continuation_stage_excludes_cleanup_and_unknown_retains_lock(self):
        test = self
        plan = dict(binding={'@worktree':str(self.work)}, proof={'native_session':'fixture-source'},
                    message={'operation':'0b9d7f3e-6a0e-4c8f-9a51-6f0c2b1d4e77','text':'continue'})
        class Backend:
            def __init__(self, failure): self.failure=failure
            def __getattr__(self, stage):
                def run(*args, **kwargs):
                    test.assertEqual(test.clean_now(), 'skip:transition', stage)
                    if stage == self.failure: raise ValueError('unconfirmed fixture')
                    return {'verified':stage, 'native_identity':{'pid':43}}
                return run
        with patch.dict(os.environ,self.env,clear=True):
            for stage in ('preflight','stop','stopped','reserve','launch','started','deliver','bound','consumed',''):
                with self.subTest(stage=stage):
                    path=self.root/('continue-'+(stage or 'success')+'.json')
                    result=continuation.protected_execute(path,plan,Backend(stage))
                    locks=list((self.conf/'rotating').glob('*.transfer-lock'))
                    if stage and stage != 'preflight':
                        self.assertEqual(len(locks),1)
                        request=json.loads((locks[0]/'request').read_text())
                        self.assertEqual(request['journal'],str(path))
                        self.assertEqual(self.clean_now(),'skip:transition')
                        self.assertNotEqual(result['state'],'consumed')
                        # Fixture-only teardown of retained lock; product has no
                        # automatic unlock/retry or TTL escape for this outcome.
                        shutil.rmtree(locks[0])
                    else:
                        self.assertEqual(locks,[])

    def test_controller_crash_leaves_same_lock_for_cleanup_and_rotate(self):
        script='''import os, pathlib, runpy, sys
m=runpy.run_path(sys.argv[1])
with m['transition_lock'](sys.argv[2]) as p:
    (p/'request').write_text('unknown fixture outcome')
    os._exit(9)
'''
        r=self.run_cmd(sys.executable,'-c',script,BIN/'.fleet-transfer.py',self.work)
        self.assertEqual(r.returncode,9)
        self.assertEqual(self.clean_now(),'skip:transition')
        r=self.run_cmd('bash','-c','. "$1"; fleet_transition_lock_take "$2"',
                       'fixture',BIN/'fleet-lib.sh',self.work)
        self.assertNotEqual(r.returncode,0)

    def test_uncontended_cleanup_still_reaps_and_releases_transition(self):
        self.assertEqual(self.clean_now(),'cleaned:fixture-head')
        self.assertFalse(self.work.exists())
        self.assertEqual(list((self.conf/'rotating').glob('*.transfer-lock')),[])

    def test_windowless_autoclean_keeps_unknown_transition_but_prunes_unrelated_worktree(self):
        # Keep a fixture-only fleet server alive, with its cwd outside both
        # candidates. Autoclean deliberately refuses an absent tmux inventory.
        self.tm('new-window','-d','-t','fixture','-c',self.root,'sleep 120')
        self.tm('kill-window','-t',self.win)  # this fixture's isolated socket only
        self.run_cmd('git','-C',self.base,'commit','--allow-empty','-qm','advance',check=True)
        sibling=self.root/'other-work'
        self.run_cmd('git','-C',self.base,'worktree','add','-qb','issue-43',sibling,'HEAD~1',check=True)
        self.env.update(FLEET_FORGE='none', FLEET_REAP_KEPT_PROCS='0')
        (self.conf/'fixture.conf').write_text('FLEET_MAIN='+str(self.base)+'\nFLEET_REPO=fixture/repo\nFLEET_BASE_BRANCH=master\nFLEET_FORGE=none\n')
        # The fleet enumerator uses named sockets; forward ONLY this fixture's
        # label to its private absolute socket, never a managed server.
        real_tmux=shutil.which('tmux'); shim=self.root/'fake/tmux'
        shim.write_text('#!/bin/sh\nif [ "$1" = -L ]; then shift 2; fi\nexec '+real_tmux+' -S '+self.socket+' "$@"\n')
        shim.chmod(0o755)
        with patch.dict(os.environ,self.env,clear=True), TRANSFER['transition_lock'](str(self.work)):
            r=self.run_cmd('bash',self.root/'bin/worktree-autoclean.sh')
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('transition retained',(self.conf/'logs/worktree-autoclean.log').read_text())
            self.assertTrue(self.work.is_dir())
            self.assertFalse(sibling.exists(),r.stdout+r.stderr)
        self.assertEqual(list((self.conf/'rotating').glob('*.transfer-lock')),[])

    def test_held_transition_and_expired_rotation_lease_keep_dirty_index_and_binding(self):
        (self.work/'file').write_text('staged\n')
        self.run_cmd('git','-C',self.work,'add','file',check=True)
        (self.work/'file').write_text('working\n')
        before = self.run_cmd('git','-C',self.work,'ls-files','--stage').stdout
        with patch.dict(os.environ,self.env,clear=True), TRANSFER['transition_lock'](str(self.work)):
            lease = next((self.conf/'rotating').glob('*.transfer-lock'))
            Path(str(lease).removesuffix('.transfer-lock')).write_text('999 1 1 expired\n')
            self.assertEqual(self.clean_now(), 'skip:transition')
        self.assertEqual((self.work/'file').read_text(),'working\n')
        self.assertEqual(self.run_cmd('git','-C',self.work,'ls-files','--stage').stdout,before)
        self.assertEqual(self.tm('show-option','-wqv','-t',self.pane,'@authority_receipt'),'source-receipt')

    def test_old_cleanup_cannot_reap_successor_after_wait(self):
        # Pause the REAL cleanup at its base pull; mutate the isolated execution
        # after the initial binding read, before the final destructive gate.
        real_git=shutil.which('git'); git=self.root/'fake/git'
        git.write_text('#!/bin/sh\ncase "$*" in *"pull --ff-only"*) '
                       'touch "$HOME/pulling"; read line < "$HOME/release"; exit 0;; esac\n'
                       'exec '+str(real_git)+' "$@"\n')
        git.chmod(0o755); os.mkfifo(self.root/'release')
        p=subprocess.Popen(['bash',str(self.clean),'--pr','42'],env=self.env,cwd=self.root,
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(lambda: p.kill() if p.poll() is None else None)
        until=time.monotonic()+10
        while not (self.root/'pulling').exists() and p.poll() is None and time.monotonic()<until:
            time.sleep(.02)
        self.assertTrue((self.root/'pulling').exists(), 'cleanup did not reach barrier')
        with patch.dict(os.environ,self.env,clear=True), TRANSFER['transition_lock'](str(self.work)):
            self.tm('respawn-pane','-k','-t',self.pane,'-c',self.work,'sleep 120')
            self.tm('set-option','-w','-t',self.pane,'@cc_launcher_pid','456')
            self.tm('set-option','-w','-t',self.pane,'@authority_receipt','successor-receipt')
            (self.work/'dirty').write_text('retained successor\n')
        with (self.root/'release').open('w') as f: f.write('continue\n')
        out,err=p.communicate(timeout=15)
        self.assertEqual(p.returncode,0,err)
        self.assertEqual(out.strip(),'skip:binding')
        self.assertEqual((self.work/'dirty').read_text(),'retained successor\n')
        self.assertEqual(self.tm('show-option','-wqv','-t',self.pane,'@authority_receipt'),'successor-receipt')

    def test_cleanup_holds_rotate_lock_through_final_teardown(self):
        real_tmux=shutil.which('tmux'); shim=self.root/'fake/tmux'
        shim.write_text('#!/bin/sh\ncase "$*" in *"kill-window"*) '
                        'touch "$HOME/killing"; read line < "$HOME/release";; esac\n'
                        'exec '+real_tmux+' "$@"\n')
        shim.chmod(0o755); os.mkfifo(self.root/'release')
        p=subprocess.Popen(['bash',str(self.clean),'--pr','42'],env=self.env,cwd=self.root,
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.addCleanup(lambda: p.kill() if p.poll() is None else None)
        until=time.monotonic()+10
        while not (self.root/'killing').exists() and p.poll() is None and time.monotonic()<until:
            time.sleep(.02)
        self.assertTrue((self.root/'killing').exists(),'cleanup did not reach teardown')
        r=self.run_cmd('bash','-c','. "$1"; fleet_transition_lock_take "$2"',
                       'fixture',BIN/'fleet-lib.sh',self.work)
        self.assertNotEqual(r.returncode,0,'rotate must not enter cleanup critical section')
        self.assertTrue(self.work.is_dir())
        with (self.root/'release').open('w') as f: f.write('continue\n')
        out,err=p.communicate(timeout=15)
        self.assertEqual(p.returncode,0,err)
        self.assertEqual(out.strip(),'cleaned:fixture-head')
        self.assertFalse(self.work.exists())

    def test_detached_cleanup_reenters_gate_and_never_adopts_successor(self):
        path=self.run_cmd('bash','-c','. "$1"; fleet_repo_conf_file fixture fixture/repo',
                          'fixture',BIN/'fleet-lib.sh',check=True).stdout
        conf=Path(path); conf.parent.mkdir(parents=True,exist_ok=True)
        conf.write_text('FLEET_REPO=fixture/repo\nFLEET_MAIN='+str(self.base)+'\nFLEET_BASE_BRANCH=master\n')
        real_tmux=shutil.which('tmux'); shim=self.root/'fake/tmux'
        shim.write_text('#!/bin/sh\ncase "$*" in *"run-shell"*) '
                        'for last do :; done; printf "%s" "$last" > "$HOME/queued"; exit 0;; esac\n'
                        'exec '+real_tmux+' "$@"\n')
        shim.chmod(0o755)
        self.env['TMUX_PANE']=self.pane
        self.assertEqual(self.clean_now(),'deferred:cleanup')
        queued=(self.root/'queued').read_text()
        self.assertIn('--expected-binding',queued)
        self.assertNotIn('kill-window',queued)
        with patch.dict(os.environ,self.env,clear=True), TRANSFER['transition_lock'](str(self.work)):
            self.tm('respawn-pane','-k','-t',self.pane,'-c',self.work,'sleep 120')
            self.tm('set-option','-w','-t',self.pane,'@authority_receipt','successor-receipt')
        self.assertEqual(self.run_cmd('bash','-c',queued).returncode,0)
        self.assertTrue(self.work.is_dir())
        self.assertEqual(self.tm('show-option','-wqv','-t',self.pane,'@authority_receipt'),'successor-receipt')
        # An unchanged, newly authorized fixture cleanup still traverses and
        # completes that same child road; the negative was not a broken launch.
        self.assertEqual(self.clean_now(),'deferred:cleanup')
        fresh=(self.root/'queued').read_text()
        self.assertEqual(self.run_cmd('bash','-c',fresh).returncode,0)
        self.assertFalse(self.work.exists())


if __name__ == '__main__': unittest.main()
