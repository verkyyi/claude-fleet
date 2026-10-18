---
name: fleet-steward
description: Open a steward session — a new session started from the `steward` template (agent file), bound to no issue, that keeps watch while the person is away: on its own /loop it answers what a batch's charter already says, spawns a red base's fixer and lands a green batch nobody drives. Use when the person types /fleet-steward or asks for someone to keep watch / mind the batches.
---

# fleet-steward — open a steward session

<!-- fleet skill -->
<!-- owner: steward — the plain marker above is what the install takes (issue #2110) -->

The steward is a session template now, not a seat this session takes (issue #4336,
EPIC #4333 C3): **open one steward session** — the same as `spawn agent:steward` bound to
no issue — and tell the person, in one line, that it is open and patrols until they close it.

```
bin/dash-raw-session.sh --no-repo --as steward --no-desk --name 管家 --prompt '巡查一轮'
```

Run it from this pane, so the new session is this one's child. Its instructions are the
template's body (`~/.claude/agents/steward.md`, shipped by the install), its system prompt:
a compaction or a resume keeps them. Its first turn starts the patrol and its own `/loop`;
its `fleet: reap: keep` keeps it open until the person closes it. Closed is closed: nothing
patrols after that — no tick program, no decision-sheet pane, no seat behind it.

- The agent file is missing (the spawn refuses, naming where it looked): the install has
  not shipped it yet — say so; `bin/fleet-agent-def.py ship` puts it in `~/.claude/agents`.
