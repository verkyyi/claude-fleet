# Transfer one session between Claude and Codex

`bin/fleet-transfer.sh` hands one existing Claude Code or Codex task to the selected Coding Agent in the
same fleet window and git worktree. The incoming agent is explicitly told the
source agent, source session ID, original transcript path and snapshot path.
It can search the source conversation whenever the handoff notes need detail.

Cross-agent transfers start a new conversation with provenance. Both
**Claude → Codex** and **Codex → Claude** work in one registered issue/scratch
worktree at a time. Claude account migration uses native `--resume`; Codex home
migration uses the packet. Desktop-app sessions are outside this controller.

## Use the existing fleet-handoff skill

In the source conversation, select the target:

```text
/fleet-handoff --to codex
/fleet-handoff --to claude
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

## Native Codex context cycling

Inside a Codex worker, write private handoff notes outside the repository, then
run this as the last tool call and end the turn after it confirms arming:

```sh
bash ~/.claude/fleet/bin/fleet-transfer.sh --window "$TMUX_PANE" --to codex \
  --handoff /absolute/path/to/notes.md --after-turn
```

The same waiter, typing hold, transfer lock and worktree lease apply. The source
is the exact SessionStart UUID and its launcher process, checked against the
pane's process tree. The packet renders Codex message records and retains its
CODEX_HOME; the fresh conversation and manual recovery recipe use that home.
The rollout, index and uncommitted files remain available. A missing or stale
identity never selects a Claude transcript or another Codex session.

`FLEET_AUTO_HANDOFF_PCT` also applies to Codex. At a clean Stop above the configured
threshold, the hook requests notes and this native command; the new launch clears
the nudge latch. A failed after-turn transfer also releases that latch when the
same Codex launcher and session are still alive, allowing the next clean Stop to
retry. A replacement session's latch is never cleared. It never sends Claude's
slash command to Codex. An active Fleet
loop keeps its recorded schedule across the cycle; a paused or ambiguous loop
must be resolved first. Loop dispatch waits while a handoff is pending.

## Preview and transfer

Run from the hub, another pane or an external terminal. The source must be idle
(`done`), with no pending `/fleet-handoff` cycle, and must have its own linked
worktree. The base checkout and panel windows are refused. A source agent may
use `--prepare-only` itself, or `--after-turn --handoff <notes>` as the final tool
call of a handoff turn. An immediate cutover cannot run inside its own source.
There must be exactly one worker pane. A marked TASKS sidebar is allowed and
stays in the window; another ordinary pane still prevents transfer.

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
| `pane-exit-timeout.txt` | Source screen retained if the exit request times out |
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
requesting the source's `/exit`. On Codex the command uses bracketed paste, so a
fast Enter cannot be absorbed as a pasted newline and leave `/exit` unsubmitted.
A matching `@agent_transfer_until` marker makes the
SessionEnd hook retain the window and worktree, and cleanup respects the lease
even for merged PRs. The controller waits for the source PID to exit. It only
replaces a dead pane or the verified childless shell left behind; an editor,
tool process or another Claude is refused. It then uses `fleet-claude.sh --agent
codex` so the existing Codex hooks and worktree guardrails apply.

No git add, commit, stash, reset, branch switch or worktree removal occurs. Detached
HEAD worktrees stay detached (the manifest's branch is `null`). Issue workers
without a legacy `@worktree` stamp resolve their actual pane cwd and still pass
the linked-worktree, owning-repository and source-registry checks. Index,
uncommitted and untracked files stay in place. A started Codex process is reported
as **started**, not as proof that login, a trust prompt or the task has completed.
Running tools, subagents and provider-specific credentials/MCP configuration are
not migrated; the pickup instructions require checking them. Interval loops may
be explicitly continued through the Fleet adapter below.

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

## Continue a loop on Codex

Add `--loop /private/path/loop.json` to the immediate or after-turn transfer:

```json
{"prompt":"Check the existing task and continue unfinished work; stop when complete.","interval_seconds":3600}
```

The optional `next_run_at` is a Unix timestamp. Without it the first wakeup is one
interval after the transfer. Delays are 30 seconds to seven days. The source
agent should record its current task, cadence and stopping conditions; an operator
can export the last **successful** self-paced `ScheduleWakeup` with:

```sh
python3 ~/.claude/fleet/bin/fleet-loop.py from-claude \
  --transcript /exact/source/session.jsonl --output /private/path/loop.json
```

This export is historical evidence, not proof that a timer remains active. Check
the source's latest intent before opting in. Calendar cron jobs, external jobs,
and cancelled loops are not automatically converted. `--prepare-only` never
starts a timer; after-turn transfers freeze the supplied spec before waiting.

The Codex TUI gets a private app server on a mode-0600 Unix socket in a mode-0700
directory. Fleet uses its native `thread/read` and `turn/start` API, so wakeups
target the **same** loaded thread without typing into its terminal or starting a
second Codex writer. The original launcher configuration and guard hooks still
apply. Plain transfers without `--loop` retain the ordinary Codex launch path.

On pickup, Codex runs `python3 ~/.claude/fleet/bin/fleet-loop.py bind` in its own
tool environment. Its exact `CODEX_THREAD_ID`, worktree, pane process, source
manifest and private socket become the binding. `status` shows the binding,
next wakeup and last accepted turn ID. The timer waits while Codex works or the
operator is typing. It never catches up missed intervals with a burst.

The owning Codex session can use `defer --seconds 3600` to choose its next delay,
add `--prompt-file /private/path/updated-task.md` to update the task, or use `stop`
when finished/cancelled. Without a change, the last interval repeats. This is
Fleet scheduling, not restoration of Claude's in-memory `ScheduleWakeup` object.
The source must exit before the target timer can start.
When Claude shows its native exit confirmation for a single self-paced `/loop`,
an explicit `--loop` transfer confirms the selected **Exit and stop tasks** once.
Different dialogs, other background jobs and multiple timers are left for inspection.

Runtime state and the app-server log live under `<handoff packet>/loop/`. A
replaced pane/thread, unloaded thread, or ambiguous delivery failure pauses the
timer for inspection; a send that may have succeeded is never blindly retried.
Exiting the Codex TUI stops its controller and private server. This version does
not automatically restart loops after a TUI exit or machine reboot. Read the
record and source provenance before arranging a new explicit continuation.

## Verification

```sh
bin/run-selftests.sh fleet-loop fleet-transfer fleet-codex fleet-handoff auto-handoff session-end-hook fleet-cleanup
```

The transfer test uses its own named tmux socket, fake agents and real temporary
worktrees. Never test the cutover against a live fleet.


## Subscription failover

Enable `FLEET_FAILOVER=1` globally or in a fleet overlay, with
`FLEET_FAILOVER_AGENTS=claude,codex` (or a single allowed agent). Register Codex
logins through `ccquota codex add NAME --codex-home DIR`; Fleet does not copy
credentials or change the default login. The existing `FLEET_CODEX_ACCOUNTS`
allowlist accepts ccquota profile names and previously registered home labels.
Claude retains its existing account registry, phase and model fallback policy.

The existing quotawatch/banner paths prefer an eligible subscription of the
current agent, then the other allowed agent. Targets require current quota,
local verified authentication, and headroom below `FLEET_ACCOUNT_CEILING`.
Same-account aliases share an exclusion/bench key. Unknown readings are never
migration destinations. All unavailable leaves the original session waiting;
later ticks retry independently of alert deduplication. A confirmed reset can
continue the original session once; an uncertain send is retained for inspection.

```sh
bin/fleet-account.sh inventory --refresh
bin/fleet-account.sh choose --agent codex
bin/fleet-account.sh reconcile --session my-fleet --dry-run
bin/fleet-account.sh failover-status
```

Per-session attempts live under `$FLEET_CONF_DIR/handoffs/quota-requests/` and
link to their transfer packet. `waiting-quota` means no eligible destination;
`waiting` includes busy tools, recent typing and unreadable drafts;
`ambiguous` requires inspection of the retained pane/packet and never starts a
second writer. The dashboard shows the quota state; doctor shows its reason.
A running background command (a dev server, a long test) keeps a request
`waiting`, as it keeps a worker awake. After a **hard** wall that has waited
`FLEET_FAILOVER_BG_GRACE` seconds (default 600; `0` disables), the move proceeds:
the commands' pid/argv/cwd go to the request's `background.json`, they are
stopped once the source has exited, and the resume prompt lists them under
"Background commands terminated by migration" for the new session to restart
as needed. Proactive moves and hibernation keep the veto.
A request that records the same state and reason `FLEET_FAILOVER_STUCK_ATTEMPTS`
times in a row (default 5, one per ~60s tick; digits are ignored so a countdown
is one reason) is **stuck**: `FLEET_NOTIFY_CMD` fires once for that episode with
the window, account, reason and the `fleet-account.sh migrate` command that
unsticks it, the window is stamped `@quota_stuck=1` (dash: `⚠ stuck`), and
doctor's `failover-stuck` line counts it. A new reason restarts the count and
clears the mark; so does the request ending.
The unstick is one key (issue #873): the dash's migrate key (`DASH_KEY_MIGRATE`,
default ⌃l) on the row opens a confirm popup with `fleet-migrate.sh`'s own dry
run — the account it would land on and every background command the move will
stop — and `y` runs `fleet-migrate.sh --force-bg --toast <window>`. `--force-bg`
takes the same inventory as the hard-wall grace before `/exit`, stops the
survivors after it (fingerprint checked) and names them in the resume nudge.
`fleet-account.sh migrate --stuck [--force-bg] [--dry-run]` does the same for
every `@quota_stuck` window. Neither moves a window when no account has room
(#567).
Disable `FLEET_FAILOVER` to cancel pending requests on the next tick. Packets and
source recovery recipes remain available. Existing sessions without a verified
native identity stay `unsupported`; never infer a session from the newest file.

A fully visible single-line draft is saved as `unsent-draft.txt`, marked `unsent`
and referenced by path. Its text is never submitted as the pickup prompt. An
unrecoverable multiline, wrapped or partially hidden draft prevents automatic
cutover. For a manual transfer, `--draft-file FILE` supplies an explicitly saved
private draft.

Active Fleet loops retain their ID, cadence, due time and delivery count, and
advance an ownership generation on each transfer. Codex uses its private native
RPC; Claude uses the existing inbox and requires the nonce to appear in the
exact session transcript before counting the wakeup. An ambiguous delivery is
never repeated. Waiting for quota pauses the durable loop record, so controllers
already running before the update also stop waking the source. Subsequent
handoffs carry that waiting loop and any still-unsent saved draft. A verified
quota reset releases only the exact owner and schedules its next interval after
the recovery continuation. The existing crash restore map retains active and
quota-waiting loop provenance;
quotawatch can reattach a dead controller only to the same restored native UUID
and worktree. Explicitly stopped/paused loops and replacement threads stay off.
A restored loop runs at the existing tick cadence; missed intervals coalesce.
