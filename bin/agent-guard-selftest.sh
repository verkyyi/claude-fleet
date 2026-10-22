#!/bin/bash
# Old launch-time hook tables must keep working after native subagents are
# enabled. Exercise their Agent/Task payloads with no override and legacy env;
# new installs must not register the retired hook. No live tmux or fleet calls.
set -euo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
python3 - "$BIN/.." <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
guard = root / "hooks/agent-guard.py"
env = dict(os.environ, FLEET_MAIN="/nonexistent/fleet/base",
           TMUX="/nonexistent/fleet/socket,1,0", FLEET_LIB="/nonexistent/lib.sh")
env.pop("FLEET_ALLOW_SUBAGENT", None)
count = 0
for override in (None, "0", "1"):
    current = dict(env)
    if override is not None:
        current["FLEET_ALLOW_SUBAGENT"] = override
    for tool in ("Agent", "Task"):
        for kind in (None, "Explore", "Plan", "claude-code-guide", "general-purpose", "claude", "fork", "new-native-type"):
            for isolation in (None, "worktree"):
                payload = {"tool_name": tool, "tool_input": {"prompt": "Implement the assigned change"}}
                if kind:
                    payload["tool_input"]["subagent_type"] = kind
                if isolation:
                    payload["tool_input"]["isolation"] = isolation
                result = subprocess.run([sys.executable, str(guard)], env=current,
                                        input=json.dumps(payload), text=True, capture_output=True, timeout=5)
                assert (result.returncode, result.stdout, result.stderr) == (0, "", ""), (override, payload, result)
                count += 1
for payload in ("", "not json", "[]", '{"tool_name":"Write"}'):
    result = subprocess.run([sys.executable, str(guard)], input=payload, env=env,
                            text=True, capture_output=True, timeout=5)
    assert (result.returncode, result.stdout, result.stderr) == (0, "", ""), result
    count += 1
source = json.loads((root / "hooks/settings-hooks.json").read_text())
commands = [h.get("command", "") for groups in source["hooks"].values()
            for group in groups for h in group.get("hooks", [])]
assert not any("agent-guard.py" in command for command in commands), commands
assert any("base-readonly-guard.py" in command for command in commands), commands
assert any("bash-guard.py" in command for command in commands), commands
print(f"PASS native subagents: {count} legacy hook calls silently allowed; new table retains filesystem/session guards")
PY
