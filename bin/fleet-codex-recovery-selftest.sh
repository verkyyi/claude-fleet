#!/bin/bash
# Codex snapshot/history identity survives without a Claude cwd fallback.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import json, os, pathlib, re, shlex, subprocess, sys, tempfile, unittest

BIN=pathlib.Path(sys.argv[1]); SID='11111111-1111-4111-8111-111111111111'

class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='codex-recovery-')
        self.root=pathlib.Path(self.tmp.name);self.wt=self.root/'work tree';self.wt.mkdir()
        self.home=self.root/"codex home's account";self.home.mkdir()
        self.trans=self.home/'sessions/2026/09/17'/('rollout-'+SID+'.jsonl');self.trans.parent.mkdir(parents=True)
        self.trans.write_text(json.dumps(dict(type='session_meta',payload=dict(id=SID,cwd=str(self.wt))))+'\n')
        self.data=dict(session_id=SID,owner='1234',home=str(self.home),cwd=str(self.wt),transcript=str(self.trans))
        # A newer Claude transcript in the identical cwd must NEVER be chosen.
        slug=re.sub(r'[^A-Za-z0-9]','-',str(self.wt));claude=self.root/'.claude/projects'/slug;claude.mkdir(parents=True)
        (claude/'wrong-claude-session.jsonl').write_text('{}\n')
        self.env=dict(os.environ,HOME=str(self.root),FLEET_HISTORY_LEDGER=str(self.root/'history.tsv'),FLEET_CONF_DIR=str(self.root/'conf'))
        self.env.pop('TMUX',None);self.env.pop('TMUX_PANE',None)

    def tearDown(self):self.tmp.cleanup()

    def run_cli(self,name,*args,input=None):
        exe=[sys.executable] if name.endswith('.py') else ['bash']
        p=subprocess.run([*exe,str(BIN/name),*args],env=self.env,input=input,text=True,capture_output=True)
        self.assertEqual(p.returncode,0,p.stderr)
        return p.stdout.strip()

    def test_restore_snapshot_is_provider_and_home_exact(self):
        line='|'.join(['worker',str(self.wt),'42','working','','','','issue-7','codex','1234',json.dumps(self.data)])+'\n'
        fields=self.run_cli('.fleet-restore-resolve.py',input=line).split('\t')
        self.assertEqual(fields[3],SID)
        self.assertEqual(fields[8:],[ 'issue-7','codex',str(self.home),str(self.trans)])
        line=line.replace('|1234|','|9999|')
        fields=self.run_cli('.fleet-restore-resolve.py',input=line).split('\t')
        self.assertEqual(fields[3],'-');self.assertEqual(fields[9],'codex')
        self.assertNotIn('wrong-claude-session',fields)

    def test_active_raw_loop_keeps_exact_provenance_in_crash_map(self):
        manifest=self.root/'packet/manifest.json';record=manifest.parent/'loop/state.json'
        record.parent.mkdir(parents=True);manifest.write_text('{}')
        r=dict(status='active',thread_id=SID,worktree=str(self.wt))
        record.write_text(json.dumps(r))
        line='|'.join(['scratch',str(self.wt),'','done','','','1','','codex','1234',str(manifest),json.dumps(self.data)])+'\n'
        fields=self.run_cli('.fleet-restore-resolve.py',input=line).split('\t')
        self.assertEqual(fields[3],SID);self.assertEqual(fields[12:], [str(manifest),'1'])
        r['status']='waiting-quota';record.write_text(json.dumps(r))
        fields=self.run_cli('.fleet-restore-resolve.py',input=line).split('\t')
        self.assertEqual(fields[3],SID);self.assertEqual(fields[12:], [str(manifest),'1'])
        r['status']='stopped';record.write_text(json.dumps(r))
        self.assertEqual(self.run_cli('.fleet-restore-resolve.py',input=line),'')

    def test_raw_scratch_without_loop_keeps_provider_home_and_marker(self):
        main=self.root/'main';main.mkdir()
        line='|'.join(['renamed scratch',str(self.wt),'','done','','','1','issue-7','codex','1234','',json.dumps(self.data)])+'\n'
        fields=self.run_cli('.fleet-restore-resolve.py',str(main),input=line).split('\t')
        self.assertEqual(len(fields),14,fields)
        self.assertEqual(fields[3],SID)
        self.assertEqual(fields[8:],['issue-7','codex',str(self.home),str(self.trans),'-','1'])
        fields=self.run_cli('.fleet-restore-resolve.py',str(main),input=line.replace('|1234|','|9999|')).split('\t')
        self.assertEqual(fields[3],'-');self.assertEqual(fields[9],'codex')
        self.assertNotIn('wrong-claude-session',fields)

    def test_raw_shared_base_alias_subdirectory_and_unknown_main_are_excluded(self):
        main=self.root/'main';main.mkdir();(main/'subdir').mkdir()
        alias=self.root/'base-alias';alias.symlink_to(main,target_is_directory=True)
        for path in (main,alias,main/'subdir'):
            line=f'scratch|{path}||done|||1\n'
            self.assertEqual(self.run_cli('.fleet-restore-resolve.py',str(main),input=line),'')
        self.assertEqual(self.run_cli('.fleet-restore-resolve.py',input=f'scratch|{self.wt}||done|||1\n'),'')

    def test_raw_scratch_preserves_only_live_matching_loop_provenance(self):
        main=self.root/'main';main.mkdir()
        manifest=self.root/'packet/manifest.json';record=manifest.parent/'loop/state.json'
        record.parent.mkdir(parents=True);manifest.write_text('{}')
        line='|'.join(['scratch',str(self.wt),'','idle','','','1','','codex','1234',str(manifest),json.dumps(self.data)])+'\n'
        for state in ('active','waiting-quota','stopped','paused'):
            record.write_text(json.dumps(dict(status=state,thread_id=SID,worktree=str(self.wt))))
            fields=self.run_cli('.fleet-restore-resolve.py',str(main),input=line).split('\t')
            self.assertEqual(len(fields),14,fields)
            self.assertEqual(fields[3],SID);self.assertEqual(fields[13],'1')
            self.assertEqual(fields[12],str(manifest) if state in ('active','waiting-quota') else '-')
        record.write_text(json.dumps(dict(status='active',thread_id='different',worktree=str(self.wt))))
        fields=self.run_cli('.fleet-restore-resolve.py',str(main),input=line).split('\t')
        self.assertEqual(fields[12],'-')

    def test_restore_reads_raw_after_manifest_and_keeps_old_codex_maps(self):
        main=self.root/'main';main.mkdir()
        manifest=self.root/'packet/manifest.json';record=manifest.parent/'loop/state.json'
        record.parent.mkdir(parents=True);manifest.write_text('{}')
        record.write_text(json.dumps(dict(status='active',thread_id=SID,worktree=str(self.wt))))
        line='|'.join(['scratch',str(self.wt),'','done','','','1','','codex','1234',str(manifest),json.dumps(self.data)])+'\n'
        fields=self.run_cli('.fleet-restore-resolve.py',str(main),input=line).split('\t')
        self.assertEqual(len(fields),14,fields)
        maps=self.root/'conf/restore';maps.mkdir(parents=True)
        stub=self.root/'bin';stub.mkdir();log=self.root/'tmux.jsonl'
        tmux=stub/'tmux'
        tmux.write_text('#!/usr/bin/env python3\n'+
            'import json,sys\n'+
            f'with open({str(log)!r},"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'+
            'args=sys.argv[3:]\n'+
            'if args[0]=="new-window": print("@88")\n'+
            'elif args[0]=="list-windows": print("plan")\n')
        tmux.chmod(0o755);self.env['PATH']=str(stub)+os.pathsep+self.env['PATH']
        # 12/13-column pre-#680 maps must still route to the exact account.
        for columns in (12,13,14):
            (maps/'fixture.map').write_text(f'FLEET\tfixture\tacme/widgets\t{main}\tmaster\n'+'\t'.join(fields[:columns])+'\n')
            log.write_text('');self.run_cli('fleet-restore.sh')
            calls=[json.loads(row)[2:] for row in log.read_text().splitlines()]
            launch=next(call[-1] for call in calls if call[0]=='new-window')
            argv=shlex.split(launch)
            self.assertEqual(argv[argv.index('--agent')+1],'codex')
            self.assertEqual(argv[argv.index('--codex-home')+1],str(self.home))
            self.assertEqual(argv[argv.index('resume')+1],SID)
            self.assertNotIn('First re-check',launch)
            options={call[-2]:call[-1] for call in calls if call[0] in ('set-option','set-window-option')}
            self.assertEqual(options.get('@raw'),'1' if columns==14 else None)
            self.assertEqual(options.get('@handoff_manifest'),str(manifest) if columns>=13 else None)
            if columns>=13:self.assertEqual(options.get('@worktree'),str(self.wt))

    def record(self,identity=None,owner='1234'):
        return self.run_cli('fleet-history.sh','record-closed','--repo','fixture/repo','--key','42','--worktree',str(self.wt),
             '--agent','codex','--launcher-pid',owner,'--agent-identity',json.dumps(identity or self.data),'--sha','abcdef','--origin','issue-7')

    def test_history_resume_and_fork_keep_account_and_id(self):
        self.record()
        row=(self.root/'history.tsv').read_text().strip().split('\t')
        self.assertEqual(len(row),14)
        self.assertEqual(row[7],SID)
        self.assertEqual(row[10:],['issue-7','codex',str(self.home),str(self.trans)])
        out=self.run_cli('fleet-history.sh','resume','--repo','fixture/repo','42').split('\t')
        self.assertEqual(out[:5],['CODEX-RESUME',str(self.wt),SID,str(self.home),'fork'])
        out=self.run_cli('fleet-history.sh','resume','--repo','fixture/repo','--no-fork','42').split('\t')
        self.assertEqual(out[4],'resume')
        self.assertNotIn('claude --resume',' '.join(out))
        self.record();self.assertEqual(len((self.root/'history.tsv').read_text().splitlines()),1)
        self.assertTrue(self.run_cli('fleet-history.sh','meta','--repo','fixture/repo','42').endswith('issue-7'))

    def test_unknown_metadata_stays_codex_review_only(self):
        self.record(owner='9999')
        row=(self.root/'history.tsv').read_text().strip().split('\t')
        self.assertEqual(row[7],'-');self.assertEqual(row[11],'codex')
        out=self.run_cli('fleet-history.sh','resume','--repo','fixture/repo','42')
        self.assertTrue(out.startswith('REVIEW-ONLY\t'))
        self.assertNotIn('claude',out)

    def test_pruned_rollout_never_uses_another_agent(self):
        self.record();self.trans.unlink()
        out=self.run_cli('fleet-history.sh','resume','--repo','fixture/repo','42')
        self.assertTrue(out.startswith('REVIEW-ONLY\t'))
        self.assertNotIn('FROM-PR',out)

    def test_old_claude_rows_keep_their_format(self):
        self.run_cli('fleet-history.sh','record-closed','--repo','fixture/repo','--key','43','--worktree',str(self.wt),'--sha','abcdef')
        row=(self.root/'history.tsv').read_text().strip().split('\t')
        self.assertEqual(len(row),11)
        self.assertEqual(row[7],'wrong-claude-session')
        out=self.run_cli('fleet-history.sh','resume','--repo','fixture/repo','43')
        self.assertIn('claude --resume wrong-claude-session',out)

unittest.main(argv=['codex-recovery'],verbosity=2)
PY
