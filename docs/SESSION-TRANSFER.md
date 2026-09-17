# Transfer one Claude session to Codex

`bin/fleet-transfer.sh` hands one existing Claude Code task to Codex CLI in the
same fleet window and git worktree. The incoming agent is explicitly told the
source agent, source session ID, original transcript path and snapshot path.
It can search the source conversation whenever the handoff notes need detail.

This is a new Codex conversation with provenance, not `codex resume` of a Claude
session. v1 supports **Claude → Codex CLI**, one issue worker or scratch session
at a time. Desktop-app transfer and the reverse direction are not implemented.

## Use the existing fleet-handoff skill

In the source Claude conversation, invoke:

```text
/fleet-handoff --to codex
```

A plugin-only install spells this `/fleet:fleet-handoff --to codex`. The existing
skill is the entry point; no second transfer skill is needed. It uses the base
`handoff` skill to compose task state and the exact next action, writes private
notes outside the repo, then calls the script with `--after-turn` as its final
tool call. Default `/fleet-handoff` still clears/resumes Claude; `pickup` still
reads an existing handoff. Unknown targets or options never fall back to clear.

The detached waiter pins the source pane, process and session. It waits for a
**fresh clean Stop hook** after arming; a pre-existing `done` stamp is insufficient.
During this bounded wait the Stop hook suppresses the automatic context-cycle
nudge. Recent operator typing defers the switch. A timeout, identity change or
competing cycle aborts with the notes preserved. The final source transcript is
captured after the handoff turn ends, so Codex also sees that turn's last message.

The script prints a private request directory with copied `notes.md`, pinned
`request.json`, `state.json` and `wait.log`. `started` links to the completed
packet's manifest; `failed` records the reason. `FLEET_TRANSFER_IDLE_WAIT` bounds
the wait (default/max 240 seconds); `FLEET_HANDOFF_DEFER_SECS` controls the typing
hold (default 30 seconds). Inspect these files if the pane has not switched.

Only the source needs the skill. Codex receives a normal initial pickup prompt
containing the handoff and source paths and continues in the same worktree.

## Preview and transfer

Run from the hub, another pane or an external terminal. The source must be idle
(`done`), with no pending `/fleet-handoff` cycle, and must have its own linked
worktree. The base checkout and panel windows are refused. A source agent may
use `--prepare-only` itself, or `--after-turn --handoff <notes>` as the final tool
call of a handoff turn. An immediate cutover cannot run inside its own source.

```sh
bin/fleet-transfer.sh --session my-fleet --window b3 --to codex --dry-run
bin/fleet-transfer.sh --session my-fleet --window b3 --to codex
```

`--window` accepts a fleet handle, window name or tmux window ID. The command
always addresses the named fleet's socket; it never scans a shared default
server. Install/sync the script and its companion hook changes together before
using it. Codex must already be installed, logged in and trusted for the base
repository, as for any existing fleet Codex worker.

For the best continuation, first ask Claude to write notes outside the repo:
the objective and latest user corrections, decisions, completed/remaining work,
tests already run, background jobs, and the exact next action. Include the
conversation's language. Then pass the file:

```sh
bin/fleet-transfer.sh --session my-fleet --window b3 --to codex \
  --handoff ~/.claude/handoff/my-task.md
```

Notes are optional. Without them, the packet contains the visible conversation,
first/last recorded user messages and git evidence, and directs Codex to recover
the task before editing. It does not pretend an automatically extracted excerpt
is an agent-written summary. No extra Claude/model call is needed to export.

## Export without switching

```sh
bin/fleet-transfer.sh --session my-fleet --window b3 --to codex --prepare-only
```

`--dry-run` writes nothing. `--prepare-only` writes a private packet while leaving
Claude and tmux unchanged; its snapshot may be taken during a turn. A real
transfer creates a fresh packet and checks again that the source is idle and its
transcript has not changed before requesting `/exit`.

## Provenance and evidence

Packets live outside the repo under
`$FLEET_CONF_DIR/handoffs/<fleet>-<source-session>-<unique>/`, with directory mode
0700 and file mode 0600. They are not committed, posted to GitHub, or added to the
project's instructions. Keep them as long as the successor needs the history.

| File | Purpose |
|---|---|
| `manifest.json` | Versioned source/target identities, host, original transcript and registry paths, fleet/window/issue, worktree/branch/HEAD, snapshot checksum and byte count |
| `source.jsonl` | Frozen copy of complete source records at handoff time |
| `history.md` | Searchable messages and tool records; omits thinking/signatures and binary attachments |
| `handoff.md` | Provenance, optional source notes, and pickup instructions |
| `pickup.md` | The actual initial prompt delivered to Codex, including original session ID and paths |
| `git-status.txt`, `staged.patch`, `unstaged.patch` | Evidence of the index and local changes; never reapplied automatically |
| `state.json` | Prepared, source-exited, starting, started or failed transfer state |
| `pane-before-exit.txt` | Source screen captured before clearing the prompt for `/exit` |
| `resume-source.sh` | Explicit recovery recipe for the original Claude session |

The source is resolved from the Claude process **under the selected pane** and
its `~/.claude/sessions/<pid>.json` registry record. That session ID must match
exactly one transcript. There is no “newest JSONL” fallback: fleet's classifier
and other helper sessions can be newer than the real conversation. Missing or
ambiguous provenance refuses the transfer.

The target window retains its issue/raw, worktree, origin and handle bindings.
It also carries `@handoff_manifest`, `@source_agent`, `@source_session_id` and
`@source_transcript`; the launcher receives `FLEET_HANDOFF_MANIFEST`. The target
reads the original absolute path on this host or the frozen snapshot if the
source file has subsequently changed or disappeared. These files can contain
private conversation content; they stay local.

## Cutover and failure handling

The controller acquires a per-worktree lock and a bounded rotation lease before
requesting Claude's `/exit`. A matching `@agent_transfer_until` marker makes the
SessionEnd hook retain the window and worktree, and cleanup respects the lease
even for merged PRs. The controller waits for the source PID to exit. It only
replaces a dead pane or the verified childless shell left behind; an editor,
tool process or another Claude is refused. It then uses `fleet-claude.sh --agent
codex` so the existing Codex hooks and worktree guardrails apply.

No git add, commit, stash, reset, branch switch or worktree removal occurs. Index,
uncommitted and untracked files stay in place. A started Codex process is reported
as **started**, not as proof that login, a trust prompt or the task has completed.
Running tools, subagents, scheduled loops and provider-specific credentials/MCP
configuration are not migrated; the pickup instructions require checking them.

On failure the packet remains. An immediate cutover returns nonzero with its
location; an after-turn request records the failure in `state.json` / `wait.log`.
After source exit, a failed target leaves a retained pane and a temporary cleanup
lease (15 minutes). Inspect the pane and `state.json`. **Stop any Codex writer
before manually running `bash /path/to/packet/resume-source.sh`** from another
pane or terminal. It resumes the original Claude session in the retained pane,
including a dead pane, and refuses to replace a running agent or tool. The
command never automatically starts a second writer as a rollback.
A controller killed outright can leave a `.transfer-lock`; inspect the recorded
PID and pane before removing that lock. The cleanup protections expire.

## Verification

```sh
bin/run-selftests.sh fleet-transfer fleet-handoff auto-handoff session-end-hook fleet-cleanup
```

The transfer test uses its own named tmux socket, fake agents and real temporary
worktrees. Never test the cutover against a live fleet.
