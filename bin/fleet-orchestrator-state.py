#!/usr/bin/env python3
"""fleet-orchestrator-state.py — retired (EPIC #4333 C7, issue #4340).

The orchestrator is a session template now (conf/agent-defaults/claude/agents/
orchestrator.md): its instructions are its system prompt and ride a compaction, so
no state relay carries them. A copy of the fleet-orchestrate plugin installed before
this version still runs `fleet-orchestrator-state.py hook` on every prompt until it
updates to the empty 已下架 one; this file answers every call with nothing, exit 0,
so such a session never sees a hook error.
# compat-1v: 下一批删
"""
import sys

if __name__ == "__main__":
    sys.exit(0)
