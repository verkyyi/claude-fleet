#!/usr/bin/env python3
"""Native ownership transaction: real process identities and crash boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BIN = Path(__file__).resolve().parent
loader = importlib.util.spec_from_file_location('durable', BIN/'fleet_transfer_durable.py')
durable = importlib.util.module_from_spec(loader)
loader.loader.exec_module(durable)


class DurableTransferTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name).resolve()
        (self.home/'.claude').mkdir()
        self.source = subprocess.Popen([sys.executable, '-c', 'import signal,time; signal.alarm(60); time.sleep(60)'])
        self.addCleanup(self.stop_source)
        self.store = self.home/'.claude/scheduled_tasks.json'
        self.lock = self.home/'.claude/scheduled_tasks.lock'
        self.record = dict(id='reminder', cron='13 9 21 10 *', prompt='deliver once',
                           createdAt=int(time.time()*1000), createdInProject=str(self.home),
                           createdByPid=self.source.pid, createdByProcStart=durable.proc_start(self.source.pid),
                           createdBySessionId='before-clear')
        self.native_lock = dict(pid=self.source.pid, procStart=self.record['createdByProcStart'],
                                sessionId='before-clear', acquiredAt=int(time.time()*1000))
        self.store.write_text(json.dumps(dict(tasks=[self.record])))
        self.lock.write_text(json.dumps(self.native_lock))
        self.store.chmod(0o640)
        self.bundle = self.home/'packet'; self.bundle.mkdir()
        self.job = dict(id='reminder', prompt='deliver once', cron=self.record['cron'],
                        recurring=False, next_run_at=time.time()+3600)
        (self.bundle/'loop-spec.json').write_text(json.dumps(dict(jobs=[self.job])))

    def stop_source(self):
        if self.source.poll() is None:
            self.source.terminate()
        self.source.wait(timeout=5)

    def prepare(self):
        proof = durable.probe(self.home, self.source.pid, [self.job], '2.1.295')
        durable.prepare(self.bundle, proof)

    def test_stage_withdraw_and_claim_after_exact_source_exit(self):
        self.prepare()
        self.assertEqual(json.loads(self.store.read_text())['tasks'], [self.record])
        durable.withdraw(self.bundle, os.getpid())
        self.assertEqual(json.loads(self.store.read_text())['tasks'], [])
        self.assertEqual(self.store.stat().st_mode & 0o777, 0o640)
        with self.assertRaisesRegex(ValueError, 'source.*alive'):
            durable.claim(self.bundle, os.getpid())
        self.stop_source()
        durable.claim(self.bundle, os.getpid())
        self.assertFalse(durable.guard(self.bundle, os.getpid()))
        with self.assertRaisesRegex(ValueError, 'still alive'):
            durable.abort(self.bundle)
        durable.activate(self.bundle, os.getpid())
        durable.guard(self.bundle, os.getpid())
        durable.claim(self.bundle, os.getpid())
        with self.assertRaisesRegex(ValueError, 'active'):
            durable.abort(self.bundle)
        durable.complete(self.bundle, os.getpid())
        self.assertFalse(self.lock.exists())
        self.assertEqual(json.loads(self.store.read_text())['tasks'], [])

    def test_changed_owner_or_native_record_never_mutates(self):
        self.prepare()
        changed = dict(self.record, prompt='changed by source')
        self.store.write_text(json.dumps(dict(tasks=[changed])))
        with self.assertRaises(ValueError): durable.withdraw(self.bundle, os.getpid())
        self.assertEqual(json.loads(self.store.read_text())['tasks'], [changed])
        self.assertEqual(json.loads(self.lock.read_text()), self.native_lock)

    def test_abort_restores_source_and_keeps_unrelated_new_tasks(self):
        self.prepare(); durable.withdraw(self.bundle, os.getpid())
        extra = dict(self.record, id='new-task')
        self.store.write_text(json.dumps(dict(tasks=[extra])))
        durable.abort(self.bundle)
        self.assertEqual(json.loads(self.store.read_text())['tasks'], [extra, self.record])
        self.assertEqual(json.loads(self.lock.read_text()), self.native_lock)
        self.assertIsNone(self.source.poll())
        durable.abort(self.bundle)

    def test_foreign_creator_unsupported_runtime_and_near_due_refuse(self):
        for version, job, record in [('unknown', self.job, self.record),
                                     ('2.1.295', dict(self.job,next_run_at=time.time()+30), self.record),
                                     ('2.1.295', dict(self.job,cron='0 9 21 10 *'), dict(self.record,cron='0 9 21 10 *')),
                                     ('2.1.295', self.job, dict(self.record,createdByPid=os.getpid()))]:
            self.store.write_text(json.dumps(dict(tasks=[record])))
            before=self.store.read_bytes()
            with self.assertRaises(ValueError):
                durable.probe(self.home,self.source.pid,[job],version)
            self.assertEqual(before,self.store.read_bytes())

    def test_killed_controller_at_each_native_write_recovers(self):
        self.prepare()
        # Real SIGKILL immediately after a native write, before its receipt.
        for suffix in ('scheduled_tasks.lock', 'scheduled_tasks.json'):
            script = '''import importlib.util,os,signal,sys
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1]).parent))
s=importlib.util.spec_from_file_location('d',sys.argv[1]); d=importlib.util.module_from_spec(s); s.loader.exec_module(d)
real=d.atomic
def die_after(path,value,mode=0o600):
    real(path,value,mode)
    if Path(path).name==sys.argv[3]: os.kill(os.getpid(),signal.SIGKILL)
d.atomic=die_after
d.withdraw(Path(sys.argv[2]),os.getpid())
'''
            child=subprocess.run([sys.executable,'-c',script,str(BIN/'fleet_transfer_durable.py'),str(self.bundle),suffix])
            self.assertEqual(child.returncode,-signal.SIGKILL)
            durable.abort(self.bundle)
            self.assertEqual(json.loads(self.store.read_text())['tasks'],[self.record])
            self.assertEqual(json.loads(self.lock.read_text()),self.native_lock)
            self.assertIsNone(self.source.poll())
            self.bundle=self.home/('packet-'+suffix); self.bundle.mkdir()
            (self.bundle/'loop-spec.json').write_text(json.dumps(dict(jobs=[self.job])))
            self.prepare()


if __name__ == '__main__': unittest.main()
