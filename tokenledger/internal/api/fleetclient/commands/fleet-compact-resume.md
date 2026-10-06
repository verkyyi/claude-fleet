# /fleet-compact-resume — pick the work back up after an in-place compaction

<!-- fleet skill · owner: either -->

The fleet submits this command itself, right after it compacted your session in
place (issue #1441) — you rarely type it. The prep step ended your last turn on
purpose and `/compact` leaves the session idle, so without this turn nothing would
start the next one. It mutates nothing: it prints your recovery map and git state,
and you continue from there.

**Argument** (`$ARGUMENTS`): none.

## 1. Read where you were

```sh
~/.claude/fleet/bin/fleet-compact-resume.sh --brief
```

It prints the line for your seat (a worker's issue + ship contract, or a scratch
session's map check), the recovery map you wrote before the compaction, and
`git status` + the last three commits.

## 2. Check, then continue

Compare the map with what the brief shows — and, when it names a PR, its state
(`~/.claude/fleet/bin/fleet-gh.sh pr view <N> --json state,mergeStateStatus`).
Fix any drift in the map's favour of reality, then carry on with its **next step**
in this same turn. Do not stop to ask whether to continue, and do not restate the
map back — the operator has seen it.

If the map's next step was waiting on something (CI, a child worker, the
operator), resume that wait the way the map says (e.g. `fleet-pr-verdict.sh <PR>
--wait` in the background) rather than idling.
