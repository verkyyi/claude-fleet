---
name: fleet-orchestrate
description: Open an orchestrator session — a new session started from the `orchestrator` template (agent file), bound to no issue, that talks a request through with the person and then hands it out. Use when the person types /fleet-orchestrate or asks for an orchestrator / someone to dispatch work.
---

# fleet-orchestrate — open an orchestrator session

<!-- fleet skill -->
<!-- owner: orchestrator — the plain marker above is what the install takes (issue #2110) -->

Orchestrating is a session template now, not a seat this session takes (issue #4335,
EPIC #4333 C2): **open one orchestrator session** — the same as `spawn agent:orchestrator`
bound to no issue — and tell the person, in one line, that it is open and they talk to it there.

```
bin/dash-raw-session.sh --no-repo --as orchestrator --no-desk --name 编排
```

Run it from this pane, so the new session is this one's child. Its instructions are the
template's body (`~/.claude/agents/orchestrator.md`, shipped by the install), its system
prompt: a compaction or a resume keeps them, so it still knows it is the orchestrator. Its
`fleet: reap: keep` keeps it open until the person closes it. Several may run at once;
each looks after what it dispatched.

- The agent file is missing (the spawn refuses, naming where it looked): the install has
  not shipped it yet — say so; `bin/fleet-agent-def.py ship` puts it in `~/.claude/agents`.
