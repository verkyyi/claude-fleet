#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

BIN = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('accounts', BIN / 'fleet-codex-account.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)


class Accounts(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='codex-accounts-'); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.homes = [str(self.root / x) for x in ("account one's home", 'account two')]
        for home in self.homes: Path(home).mkdir()
        self.env = patch.dict(os.environ, FLEET_CONF_DIR=str(self.root/'conf'), FLEET_CODEX_ACCOUNTS='one two',
                              FLEET_CODEX_QUOTA_TTL='300', FLEET_CODEX_QUOTA_FLOOR='5', FLEET_CODEX_QUOTA_GATE='0',
                              FLEET_CODEX_HOME='', FLEET_CODEX_MODEL='')
        self.env.start(); self.addCleanup(self.env.stop)
        a.register('one', self.homes[0]); a.register('two', self.homes[1])
        self.fake = self.root / 'bin'; self.fake.mkdir()
        codex = self.fake/'codex'
        codex.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys,time
home=pathlib.Path(os.environ['CODEX_HOME'])
if 'app-server' not in sys.argv:
 (home/'launch.json').write_text(json.dumps(sys.argv[1:]));sys.exit(0)
(home/'server.pid').write_text(str(os.getpid()))
for line in sys.stdin:
 r=json.loads(line)
 if r.get('method')=='initialize': print(json.dumps({'id':r['id'],'result':{}}),flush=True)
 if r.get('method')=='account/rateLimits/read':
  if (home/'stall').exists():time.sleep(60)
  print(json.dumps({'id':r['id'],'result':json.loads((home/'response.json').read_text())}),flush=True)
'''); codex.chmod(0o755)
        self.pathenv = patch.dict(os.environ, PATH=str(self.fake)+':'+os.environ['PATH'])
        self.pathenv.start(); self.addCleanup(self.pathenv.stop)

    def response(self, used=20, duration=10080, reset=None):
        return {'accountId': 'must-not-cache', 'email':'private@example.invalid', 'rateLimits':
                {'primary':{'usedPercent':used,'windowDurationMins':duration,'resetsAt':reset or time.time()+1000}},
                'rateLimitsByLimitId':{}}

    def quota(self, idx=0, used=20, **kw):
        home=self.homes[idx]; response=self.response(used, **kw)
        a.save(a.cache_path(home), dict(a.normalize(response), home=home, auth=a.fingerprint(home), at=time.time(), attempt=time.time()))
        return response

    def test_registry_is_metadata_only_and_duplicate_home_rejected(self):
        self.assertEqual(a.registry(), dict(zip(('one','two'),self.homes)))
        with self.assertRaises(ValueError): a.register('alias',self.homes[0])
        with self.assertRaises(ValueError): a.register('one',self.homes[1])
        self.assertEqual((a.root()/'accounts.json').stat().st_mode & 0o777,0o600)
        self.assertEqual(list(Path(self.homes[0]).iterdir()),[])

    def test_selection_fresh_known_then_unknown_never_claude_quota(self):
        self.quota(0,90);self.quota(1,10)
        self.assertEqual(a.choose()['label'],'two')
        self.quota(1,100)
        self.assertEqual(a.choose()['label'],'one')
        a.cache_path(self.homes[0]).unlink()
        self.assertEqual(a.choose()['label'],'one')
        with self.assertRaises(ValueError):a.choose(require_known=True)
        self.quota(0,100)
        self.assertEqual(a.selection(),self.homes[0])
        with patch.dict(os.environ,FLEET_CODEX_QUOTA_GATE='1'):
            with self.assertRaises(ValueError):a.selection()

    def test_window_lengths_are_native_and_resets_are_unknown(self):
        self.quota(duration=10080)
        s=a.status(self.homes[0]);self.assertEqual(s['windows'][0]['windowDurationMins'],10080)
        self.quota(reset=time.time()-1)
        self.assertEqual(a.status(self.homes[0])['state'],'unknown')
        data=a.read(a.cache_path(self.homes[0]));data['rateLimits']['secondary']={'usedPercent':40,'resetsAt':time.time()+500}
        a.save(a.cache_path(self.homes[0]),data)
        self.assertEqual(a.status(self.homes[0])['state'],'unknown')
        data['ordinaryUsageAllowed']=False;a.save(a.cache_path(self.homes[0]),data)
        self.assertEqual(a.status(self.homes[0])['state'],'low')

    def test_stale_future_and_auth_replacement_are_unknown(self):
        self.quota()
        data=a.read(a.cache_path(self.homes[0]))
        for at in (time.time()-301,time.time()+50):
            data['at']=at;a.save(a.cache_path(self.homes[0]),data)
            self.assertEqual(a.status(self.homes[0])['state'],'unknown')
        self.quota();(Path(self.homes[0])/'auth.json').write_text('do not read tokens')
        self.assertEqual(a.status(self.homes[0])['state'],'unknown')

    def test_model_bucket_only_applies_to_exact_native_model_slug(self):
        self.quota()
        data=a.read(a.cache_path(self.homes[0]))
        data['rateLimitsByLimitId']={'special':{'normalModelSlug':'fixture-model','primary':{'usedPercent':100}}}
        a.save(a.cache_path(self.homes[0]),data)
        self.assertEqual(a.status(self.homes[0])['state'],'available')
        self.assertEqual(a.status(self.homes[0],'fixture-model')['state'],'low')
        self.assertEqual(a.status(self.homes[0],'other-model')['state'],'available')

    def test_native_stdio_accounts_stay_isolated_and_credentials_not_cached(self):
        for i, home in enumerate(self.homes):
            (Path(home)/'response.json').write_text(json.dumps(self.response(10+i*30)))
            a.refresh(home,force=True)
        self.assertEqual([a.status(h)['remaining'] for h in self.homes],[90,60])
        cache=a.cache_path(self.homes[0]).read_text()
        self.assertNotIn('must-not-cache',cache);self.assertNotIn('private@example',cache)
        for home in self.homes:
            pid=int((Path(home)/'server.pid').read_text())
            with self.assertRaises(ProcessLookupError):os.kill(pid,0)

    def test_rpc_timeout_terminates_server_and_keeps_fresh_reading(self):
        self.quota()
        (Path(self.homes[0])/'stall').touch()
        before=time.monotonic();a.refresh(self.homes[0],force=True,timeout=.1)
        self.assertLess(time.monotonic()-before,4)
        self.assertEqual(a.status(self.homes[0])['remaining'],80)
        pid=int((Path(self.homes[0])/'server.pid').read_text())
        with self.assertRaises(ProcessLookupError):os.kill(pid,0)

    def test_launcher_selection_and_explicit_recovery_home(self):
        self.quota(0,90);self.quota(1,10)
        install=self.root/'install';dest=install/'bin';dest.mkdir(parents=True)
        for name in ('fleet-lib.sh','fleet-codex.sh','fleet-codex-account.py','fleet-hooks-emit.sh'):
            shutil.copy2(BIN/name,dest/name)
        shutil.copytree(BIN.parent/'hooks',install/'hooks')
        env=dict(os.environ,HOME=str(self.root));env.pop('TMUX',None);env.pop('TMUX_PANE',None)
        def launch(*args):
            p=subprocess.run(['bash',str(dest/'fleet-codex.sh'),*args],env=env,capture_output=True,text=True)
            self.assertEqual(p.returncode,0,p.stderr)
        launch('seed');self.assertTrue((Path(self.homes[1])/'launch.json').exists())
        launch('--codex-home',self.homes[0],'--resume','saved-session')
        self.assertIn('resume',json.loads((Path(self.homes[0])/'launch.json').read_text()))
        env['CODEX_HOME']=self.homes[0]
        launch('resume','native-saved-session')
        self.assertIn('native-saved-session',json.loads((Path(self.homes[0])/'launch.json').read_text()))

    def test_watch_never_moves_busy_unknown_or_unconfigured_sessions(self):
        # The native RPC is mandatory and controller rechecks idle before /exit.
        with patch.object(a,'idle',side_effect=AssertionError('must not probe')),patch.object(a,'registry',side_effect=AssertionError('must not read')):
            with patch.dict(os.environ,FLEET_CODEX_QUOTA_MIGRATE='0'):a.watch('fixture')
        source=dict(home=self.homes[0],owner='123',session_id='sid',model='fixture')
        actions=[]
        def tm(args,sock):
            if args[0]=='list-windows': return '%1|done|codex|123|'+json.dumps(source)
            actions.append(args);return ''
        with patch.dict(os.environ,FLEET_CODEX_QUOTA_MIGRATE='1'),patch.object(a.runpy,'run_path',return_value={'tmux':tm,'saved_identity':lambda raw,owner:json.loads(raw)}),patch.object(a,'idle',return_value=True):
            self.quota(0,100);self.quota(1,10);a.watch('fixture');a.watch('fixture')
        self.assertEqual(len(actions),1)
        self.assertIn('--require-codex-idle',actions[0][-1]);self.assertIn('--expected-source',actions[0][-1])

    def test_watch_preserves_busy_workers_and_requires_known_destination(self):
        source=dict(home=self.homes[0],owner='123',session_id='sid')
        def tm(args,sock):
            if args[0]=='list-windows':return '%1|done|codex|123|'+json.dumps(source)
            self.fail('must not schedule a transfer')
        with patch.dict(os.environ,FLEET_CODEX_QUOTA_MIGRATE='1'),patch.object(a.runpy,'run_path',return_value={'tmux':tm,'saved_identity':lambda raw,owner:json.loads(raw)}):
            self.quota(0,100)
            with patch.object(a,'idle',side_effect=AssertionError('no healthy destination')):a.watch('fixture')
            self.quota(1,10)
            with patch.object(a,'idle',return_value=False):a.watch('fixture')


unittest.main(verbosity=2)
