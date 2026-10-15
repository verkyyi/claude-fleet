#!/usr/bin/env python3
"""Idle sampler acceptance under fleet-loadgen, without shared-host noise.

The fake really starts true + sleep every 0.1s, with an independent alarm.
Its own counter substitutes for the machine-wide kernel counter and ps is
restricted to that process tree. This tests sampling, ancestry and the <=30%
rate bound without attributing another worker's processes to our fake.
The shell test exercises the unmodified machine sampler and guard end to end.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("idle_cost", Path(sys.argv[2]) / "fleet-idle-cost.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
work = Path(sys.argv[1])
count = work / "forks"
count.write_text("0")
fake = work / "fake.py"
fake.write_text('''import os, signal, subprocess, sys, time
signal.alarm(15)
end = time.monotonic() + 12
n = 0
while time.monotonic() < end:
    for command in (["/usr/bin/true"], ["sleep", "0.1"]):
        n += 1
        with open(sys.argv[1] + ".tmp", "w") as f: f.write(str(n))
        os.replace(sys.argv[1] + ".tmp", sys.argv[1])
        subprocess.run(command, check=True)
''')
p = subprocess.Popen([sys.executable, str(fake), str(count)])
try:
    time.sleep(1.2)
    real_sample = m.Sampler.sample
    sampler = []

    def scoped_sample(self):
        if not sampler:
            sampler.append(self)
        alive = real_sample(self)
        # Retain the real ancestry but select the fake's descendants, the same
        # isolation that a private PID namespace provides on Linux.
        def belongs(pid):
            seen = set()
            while pid in self.ppid and pid not in seen:
                if pid == p.pid:
                    return True
                seen.add(pid)
                pid = self.ppid[pid]
            return False
        keep = {pid for pid in self.ppid if belongs(pid)}
        self.ppid = {pid: pp for pid, pp in self.ppid.items() if pid in keep}
        self.first &= keep
        return alive & keep

    def counter():
        # Observer subprocesses are part of a real kernel counter too, and must
        # be removed exactly once (including ps visible in its own snapshot).
        return int(count.read_text()) + sampler[0].own

    a = SimpleNamespace(exclude=[], configs=None, secs=6, interval=0.05,
                        min_age=1, top=10, out=str(work / "scoped.json"))
    n0, t0 = int(count.read_text()), time.monotonic()
    with patch.object(m.Sampler, "sample", scoped_sample), patch.object(m, "fork_counter", counter):
        assert m.cmd_sample(a) == 0
    truth = (int(count.read_text()) - n0) / (time.monotonic() - t0)
    r = json.loads(Path(a.out).read_text())
    top = r["spawn_top"][0]
    assert top["pid"] == p.pid, (p.pid, r)
    assert truth > 0 and abs(top["rate"] - truth) <= 0.3 * truth, (truth, r)
    assert r["state"] == "unverified", r  # raw sampler never certifies idle
    print("PASS C real spawner first; %.2f/s vs %.2f/s (<=30%%), %s observations" %
          (top["rate"], truth, top["seen"]))
finally:
    p.terminate()
    p.wait(timeout=5)

# A ps child seen in the snapshot must not be removed twice from the rate.
s = m.Sampler([])
s.own_pids.add(99)
s.ppid = {99: os.getpid(), 77: p.pid}
assert s.excluded(99)

# The exact same window id on another socket cannot be the caller.
a = SimpleNamespace(configs="", conf_dir="", self_socket="/mine", self_window="@1",
                    sessions_dir=str(work / "empty"), login="me")
g = m.IdleGuard(a, s)
with patch.object(g, "local", return_value={("/other", "@1"): ("working", "1", "")}):
    assert g.check(set()).startswith("working:")
with patch.object(g, "local", return_value={("/mine", "@1"): ("working", "1", "")}):
    assert g.check(set()) == ""
# A worker that starts AND finishes between probes still changes its timestamp.
g.previous = {("/other", "@1"): ("done", "1", "")}
with patch.object(g, "local", return_value={("/other", "@1"): ("done", "2", "")}):
    assert "busy interval" in g.check(set())
print("PASS caller socket identity and between-probe activity")
