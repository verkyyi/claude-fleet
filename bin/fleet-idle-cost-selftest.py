#!/usr/bin/env python3
"""A malformed argv from ps must not abort a capacity observation."""
import runpy
import sys
from pathlib import Path

sampler = runpy.run_path(str(Path(__file__).with_name("fleet-idle-cost.py")))["Sampler"]([])
raw = sampler.run([sys.executable, "-c", "import os; os.write(1, b'123 1 501 00:01 0:00.10 bad\\xffname\\n')"])
assert "bad\ufffdname" in raw, repr(raw)
sampler.run = lambda *args, **kwargs: raw
assert sampler.sample() == {123}
assert sampler.ppid[123] == 1 and sampler.last[123] == (1.0, 0.1)
print("PASS: invalid argv is replaced; process identity and CPU time preserved")
