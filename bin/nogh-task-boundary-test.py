#!/usr/bin/env python3
"""A4: the real PR gate refuses denied reads, then checks restored fixture data."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile

BIN = Path(__file__).resolve().parent
records = []


def check(env, expected, verdict):
    command = ["bash", str(BIN/"fleet-pr-verdict.sh"), "77", "--repo", "fixture/github", "-q"]
    p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=15)
    records.append(dict(at=datetime.datetime.now(datetime.timezone.utc).isoformat(), command=command,
                        exit=p.returncode, stdout=p.stdout, stderr=p.stderr))
    assert (p.returncode, p.stdout.strip()) == (expected, verdict), records[-1]


with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    env = dict(os.environ, FLEET_SKIP_GLOBAL_CONF="1", FLEET_CONF_DIR=str(root/"conf"), TMPDIR=temp)
    # The harness's deny shim is still first on PATH. A denied read produces no
    # verdict, even after the authoritative work result was recorded separately.
    check(env, 2, "")
    gh = root/"gh"
    gh.write_text('#!/bin/sh\nprintf "%s\\n" "$GATE_ROW"\n')
    gh.chmod(0o700)
    env["PATH"] = temp+os.pathsep+env["PATH"]
    for checks, expected, verdict in (("pending", 1, "PENDING"), ("fail", 1, "FAILING"), ("pass", 0, "READY")):
        env["GATE_ROW"] = "OPEN\nMERGEABLE\nCLEAN\n\n"+checks+"\n"
        check(env, expected, verdict)
    Path(os.environ["NOGH_ACCEPTANCE_EVIDENCE"], "pr-gate-commands.json").write_text(json.dumps(records, indent=2)+"\n")
print("PASS GitHub read denied rc2, no verdict; restored fixture PENDING -> FAILING -> READY; no merge performed")
