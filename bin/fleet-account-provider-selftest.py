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


if __name__ == '__main__':
    unittest.main()
