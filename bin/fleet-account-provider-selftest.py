#!/usr/bin/env python3
"""Behavioral fixtures for the shared account selector and ccquota adapters."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('accounts', Path(__file__).with_name('.fleet-account.py'))
accounts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accounts)


def candidate(agent, name, used=10, **extra):
    return dict(agent=agent, key=agent + '/' + name, account=name, score=(100-used)*2,
                utilization=used, available=True, login='valid', **extra)


class Providers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.patch = patch.dict(os.environ, FLEET_C=str(self.root), FLEET_ACCOUNT_CEILING='85',
                                FLEET_ACCOUNT_PICK='5h', FLEET_ACCOUNT_PICK_HYST='10')
        self.patch.start()
        self.profile = dict(agent='codex', account='codex:account:fixture', home=str(self.root),
                            profile='work', login='valid')

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def test_same_agent_before_larger_other_pool_in_both_directions(self):
        for agent, other in (('claude','codex'), ('codex','claude')):
            rows = [candidate(other,'other',0), candidate(agent,'source',99), candidate(agent,'next',80)]
            r = accounts.choose({'accounts':rows}, agent, [agent+'/source'])
            self.assertEqual(r['target']['account'], 'next')
            rows.pop()
            self.assertEqual(accounts.choose({'accounts':rows}, agent)['reason'], 'cross-agent')

    def test_no_unreadable_stale_benched_or_auth_target(self):
        rows = [candidate('codex','full',100), candidate('claude','stale')]
        rows[1]['available'] = False
        rows.append(candidate('codex','bench',limited_until=time.time()+60))
        rows.append(candidate('codex','expired')); rows[-1]['login']='reauth_required'
        r = accounts.choose({'accounts':rows}, 'claude')
        self.assertEqual(r['state'], 'waiting-quota')

    def test_window_ids_are_not_durations(self):
        reading = dict(available=True, windows=[dict(id='codex:primary', minutes=10080, utilization=95)])
        r = accounts.normalize_codex(self.profile, reading)
        self.assertEqual(r['utilization'],95)
        self.assertFalse(accounts.eligible(r))

    def test_invalid_secondary_never_disappears_into_headroom(self):
        reading = dict(available=True, windows=[dict(id='a',minutes=300,utilization=5),
                                               dict(id='b',minutes=10080,utilization=None)])
        self.assertFalse(accounts.normalize_codex(self.profile,reading)['available'])

    def test_blocked_credits_and_reset_windows(self):
        self.assertFalse(accounts.normalize_codex(self.profile,dict(available=True,credits={'unlimited':True}))['available'])
        r=accounts.normalize_codex(self.profile,dict(available=True,blocked=True))
        self.assertEqual(r['utilization'],100)
        reading=dict(available=True,windows=[dict(id='old',minutes=300,utilization=100,resets_at=1)])
        self.assertFalse(accounts.normalize_codex(self.profile,reading)['available'])
        reading['windows']=[dict(id='a',minutes=300,utilization=90,resets_at=2000),
                            dict(id='b',minutes=10080,utilization=95,resets_at=3000)]
        self.assertEqual(accounts.normalize_codex(self.profile,reading,now=1000)['reset_at'],3000)

    def test_missing_duration_retains_known_percentage_without_five_hour_guess(self):
        reading=dict(available=True,windows=[dict(id='codex:primary',utilization=58),
                                            dict(id='special:primary',minutes=300,utilization=100)])
        row=accounts.normalize_codex(self.profile,reading,scope='codex')
        self.assertTrue(row['available']); self.assertEqual(row['utilization'],58)
        self.assertIsNone(row['windows'][0]['minutes'])
        self.assertEqual(row['score'],84)
        self.assertEqual(accounts.normalize_codex(self.profile,reading,scope='special')['utilization'],100)

    def test_profiles_share_account_exclusion_and_bench(self):
        a=candidate('codex','seat',home='/one',profile='one')
        b=dict(a,home='/two',profile='two')
        self.assertIsNone(accounts.choose({'accounts':[a,b]},'codex',['codex/seat'])['target'])
        accounts.bench('codex/seat',int(time.time())+60,'quota')
        benches=accounts.read(accounts.state_dir()/'account.codex-limited.json')
        self.assertIn('codex/seat',benches)

    def test_phase_and_hysteresis_keep_existing_preference(self):
        a=candidate('claude','a',20,hold_until=time.time()+100)
        b=candidate('claude','b',25)
        self.assertEqual(accounts.choose({'accounts':[a,b]},'claude')['target']['account'],'b')
        b['hold_until']=time.time()+100
        self.assertEqual(accounts.choose({'accounts':[a,b]},'claude',current='claude/b')['target']['account'],'b')

    def test_pace_ranks_the_week_and_holds_far_ahead(self):
        # issue #1231: the shortest window is the expiring one, the longest the week;
        # pace = week% − 85 × elapsed; a lead of 10 points outweighs a whole 5h window.
        # setUp pins the class to the #598 `5h` score; this test is the `pace` default.
        self.patch.stop(); self.patch = patch.dict(os.environ, FLEET_C=str(self.root), FLEET_ACCOUNT_CEILING='85',
                                                   FLEET_ACCOUNT_PICK='pace', FLEET_ACCOUNT_PICK_HYST='10')
        self.patch.start()
        now = 1_000_000
        ahead = dict(available=True, windows=[dict(id='codex:primary', minutes=300, utilization=0, resets_at=now + 3600),
                                              dict(id='codex:week', minutes=10080, utilization=65, resets_at=now + 6 * 86400)])
        behind = dict(available=True, windows=[dict(id='codex:primary', minutes=300, utilization=60, resets_at=now + 3600),
                                               dict(id='codex:week', minutes=10080, utilization=10, resets_at=now + 86400)])
        a = accounts.normalize_codex(dict(self.profile, account='a'), ahead, now=now)
        b = accounts.normalize_codex(dict(self.profile, account='b'), behind, now=now)
        self.assertEqual((a['pace'], a['pace_held']), (53, True))
        self.assertEqual((b['pace'], b['pace_held']), (-63, False))
        self.assertEqual(a['score'], 200 + (100 - 53) * 20)
        self.assertEqual(b['score'], 80 + (100 + 63) * 20)
        # the held account loses even with a fresh 5h window; alone, it is still picked (fail-open)
        self.assertEqual(accounts.choose({'accounts': [a, b]}, 'codex')['target']['account'], 'b')
        self.assertEqual(accounts.choose({'accounts': [a]}, 'codex')['target']['account'], 'a')
        # rollback: FLEET_ACCOUNT_PICK=5h is the #598 score, no pace, no hold
        with patch.dict(os.environ, FLEET_ACCOUNT_PICK='5h'):
            a5 = accounts.normalize_codex(dict(self.profile, account='a'), ahead, now=now)
        self.assertEqual((a5['score'], a5['pace'], a5['pace_held']), (200 + 35, 0, False))

    def test_claude_inventory_reads_pace_fields(self):
        # fleet-account.sh _claude-inventory grew fields 12–13 (pace, held); a pre-#1231
        # 11-field row still parses, with no hold.
        line13 = 'x\tuuid\t40\t3000\t0\t0\t0\t1\t1\t1\t1\t-12\t0'
        line11 = 'y\tuuid\t40\t3000\t0\t0\t0\t1\t1\t1\t1'
        held13 = 'z\tuuid\t70\t900\t0\t0\t0\t1\t1\t1\t1\t40\t1'
        with patch.object(accounts, 'run', return_value='\n'.join([line13, line11, held13])), \
             patch.object(accounts, 'profiles', return_value=[]), \
             patch.object(accounts, 'codex_reading', return_value={'accounts': [], 'reason': ''}):
            rows = {r['label']: r for r in accounts.inventory()['accounts']}
        self.assertEqual((rows['x']['pace'], rows['x']['pace_held']), (-12, False))
        self.assertEqual((rows['y']['pace'], rows['y']['pace_held']), (0, False))
        self.assertEqual((rows['z']['pace'], rows['z']['pace_held']), (40, True))
        # the hold is fail-open in choose(): z loses to x, wins alone
        self.assertEqual(accounts.choose({'accounts': [rows['z'], rows['x']]}, 'claude')['target']['label'], 'x')
        self.assertEqual(accounts.choose({'accounts': [rows['z']]}, 'claude')['target']['label'], 'z')

    def test_local_profile_intersection_and_uuid(self):
        raw=dict(source='codex',accounts=[dict(account_uuid=self.profile['account'],available=True,
            windows=[dict(id='codex:primary',minutes=300,utilization=10)]),
            dict(account_uuid='remote-only',available=True,windows=[dict(id='p',minutes=300,utilization=0)])])
        with patch.object(accounts,'profiles',return_value=[self.profile]), patch.object(accounts,'ccquota',return_value=raw), patch.object(accounts,'run',return_value=''):
            result=accounts.inventory(True)
        self.assertEqual(len(result['accounts']),1)
        self.assertEqual(result['accounts'][0]['account'],self.profile['account'])

    def test_failed_refresh_invalidates_old_success(self):
        path=accounts.state_dir()/'account.codex-quota.json'
        accounts.save(path,dict(fetched_at=time.time(),accounts=[{'account_uuid':'old'}]))
        with patch.object(accounts,'ccquota',side_effect=ValueError('unsupported')):
            self.assertEqual(accounts.codex_reading(True)['accounts'],[])
        self.assertEqual(accounts.read(path)['accounts'],[])

    def test_pinned_target_rejects_relogin(self):
        target=candidate('codex','old',profile='p',home='/home')
        data={'accounts':[candidate('codex','new',profile='p',home='/home')]}
        with patch.object(accounts,'inventory',return_value=data):
            with self.assertRaisesRegex(ValueError,'no longer eligible'):
                accounts.check_target(target)

    def test_existing_source_verifies_native_provider_without_rereading_startup_config(self):
        source=dict(session_id='exact-thread',worktree=str(self.root))
        native=dict(id='exact-thread',cwd=str(self.root),modelProvider='openai')
        auth=dict(account={'type':'chatgpt','email':'fixture@example.com'},requiresOpenaiAuth=True)
        calls=[]
        class Client:
            def __init__(self,*_,**__):pass
            def close(self):pass
            def call(self,method,params):
                calls.append(method)
                if method=='account/read':return auth
                if method=='thread/read':return {'thread':native}
                raise ValueError('startup feature override file no longer exists')
        expected=dict(self.profile,email='fixture@example.com')
        with patch.object(accounts,'read_subscription',return_value=expected), patch.object(accounts,'profile',return_value=expected), patch.object(accounts.runpy,'run_path',return_value={'Client':Client}):
            accounts.verify_codex_runtime('unix:///exact.sock',source=source)
            self.assertEqual(calls,['account/read','thread/read'])
            for key,value in (('id','replacement'),('cwd','/wrong'),('modelProvider','custom')):
                with patch.dict(native,{key:value}):
                    with self.assertRaises(ValueError):accounts.verify_codex_runtime('unix:///exact.sock',source=source)
            with patch.dict(auth['account'],email='other@example.com'):
                with self.assertRaises(ValueError):accounts.verify_codex_runtime('unix:///exact.sock',source=source)
            # A new destination still requires pre-TUI config verification.
            with self.assertRaisesRegex(ValueError,'startup feature'):
                accounts.verify_codex_runtime('unix:///exact.sock')


if __name__ == '__main__':
    unittest.main()
