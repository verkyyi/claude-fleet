#!/bin/bash
# Codex snapshot/history identity survives without a Claude cwd fallback.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
import json, os, pathlib, re, subprocess, sys, tempfile, unittest

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
