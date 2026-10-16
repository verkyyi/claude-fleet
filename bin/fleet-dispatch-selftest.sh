#!/bin/bash
# Accepted provider envelopes and the MCP/controller boundary (#4392).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$BIN" <<'PY'
import importlib.util
import json
import pathlib
import sys
sys.path.insert(0, sys.argv[1])
from fleet_dispatch import resolve, placement_check
from fleet_hub_common import validate_write, Fault
import fleet_control

explicit = resolve(["codex"], template="claude", label="claude", default="claude", request_id="fixture-1")
accepted = dict(explicit, task="T17", generation=3, attempt_id="task:T17:g3")
assert resolve(["codex"], template="claude", label="claude", default="claude", accepted=accepted) == accepted
placement_check(accepted, "T17", 0)
for envelope, task, code in [(explicit,"T9",0), (accepted,"T9",0), (accepted,"T17",1), (accepted,"T17",6)]:
    try:
        placement_check(envelope, task, code)
    except ValueError:
        pass
    else:
        raise AssertionError("placement replaced task identity or fell back after uncertain send")
for choices in (["unknown"], ["codex", "claude"]):
    try:
        resolve(choices)
    except ValueError:
        pass
    else:
        raise AssertionError("invalid explicit input accepted")
try:
    resolve(["claude"], accepted=accepted)
except ValueError:
    pass
else:
    raise AssertionError("accepted provider replaced")
for hints, expected, source in [({}, "claude", "default"), ({"default":"codex"},"codex","fleet"),
        ({"label":"codex", "default":"claude"},"codex","label"),
        ({"template":"codex", "label":"claude"},"codex","template")]:
    d=resolve(request_id="fixture-default", **hints)
    assert (d["resolved_agent"],d["agent_source"],d["requested_agent"])==(expected,source,"default"),d
params=dict(issue=7,repo="org/repo",agent="codex",task="T17",dispatch=accepted)
validate_write("worker_start",params)
try:
    validate_write("worker_start",dict(params,agent="claude"))
except Fault:
    pass
else:
    raise AssertionError("remote contradiction accepted")

# The actual adapter transports the accepted generation as data to the shell.
controller=object.__new__(fleet_control.Control)
controller.bin=pathlib.Path("/fixture/bin")
controller.environment=lambda: {}
seen=[]
fleet_control.run=lambda argv, **kw: seen.append((argv,kw))
controller.adapter("start", "fleet", "7", "codex", task="T17", dispatch=accepted)
assert json.loads(seen[0][1]["env"]["FLEET_DISPATCH"]) == accepted
assert seen[0][1]["env"]["FLEET_CONTROL_TASK"] == "T17"

spec=importlib.util.spec_from_file_location("fleet_mcp",pathlib.Path(sys.argv[1])/"fleet-mcp.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
seen=[]
m.spawn_gate=lambda:None
m.check_repo=lambda args:[]
m.hub_env=lambda ttl:{}
m.script=lambda argv,*args,**kw:seen.append(argv)
m.tool_spawn(dict(issue=7,agent="reviewer",coding_agent="codex"))
assert seen[0][-4:]==["--as","reviewer","--agent","codex"],seen
print("PASS provider acceptance: title-independent choice, frozen defaults, invalid/conflicting input rejected")
print("PASS controller: task T17 / generation 3 / attempt task:T17:g3 / request fixture-1 unchanged")
print("PASS MCP: agent=reviewer -> --as reviewer; coding_agent=codex -> --agent codex")
PY
