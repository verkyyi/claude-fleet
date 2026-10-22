# Transfer one session between Claude and Codex

`bin/fleet-transfer.sh` hands one existing Claude Code or Codex task to the selected Coding Agent in the
same fleet window and git worktree. The incoming agent is explicitly told the
source agent, source session ID, original transcript path and snapshot path.
It can search the source conversation whenever the handoff notes need detail.

Cross-agent transfers start a new conversation with provenance. Both
**Claude → Codex** and **Codex → Claude** work in one registered issue/scratch
worktree at a time. Claude account migration uses native `--resume`; Codex home
migration uses the packet. Desktop-app sessions are outside this controller.

## One road, four directions

A handoff (same agent, a fresh context) and a switch (Claude ↔ Codex) run the
same code (T630, EPIC T580 C7): Claude → Claude, Claude → Codex, Codex → Claude
and Codex → Codex differ only in where the source is read and how the target is
started, and both are columns of the agent adapter table
(`bin/fleet_agent_adapter.py`, the shell copy `bin/fleet-agent-adapter.sh`), never
a test of the agent's name:

| column | what it says |
|---|---|
| `transfer_source` | `registry` (the process's session registry + its projects transcript) or `thread` (the native thread identity + rollout + account home); `.fleet-transfer.py source` is the one reader, its line `PID SID HOME TRANSCRIPT REGISTRY` |
| `home_flag` · `resume_flag` | the source's own resume (`source_resume_argv`) and the target's account home |
| `account_env` | the variable a pinned target account rides on |
| `loop_settled` | when a `looping` source between rounds counts as idle |
| `exit_paste` | `/exit` as one bracketed paste, or typed |
| `armed_cycle` | whether a pending `@handoff_armed` is an in-place cycle a switch must wait for |
| `native_cron` | whether the agent's own scheduler holds timers a no-repo switch carries |
| `bind_proof` | what proves the target started: its native session, or its process |
| `account_resume` | whether `--native-resume` may reopen the same conversation |

`fleet-transfer-selftest.sh` part 5 runs all four directions in one sandbox and
asserts each bundle the same way; the proxy-home drill (BREAK-IT
`transfer-proxy-home`) runs from a Codex and from a Claude source.

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

`FLEET_AUTO_HANDOFF_PCT` also applies to Codex but defaults to 0 / off: native
Agent compaction is the normal context-management path. Explicit manual transfer
does not require enabling auto-handoff. At a clean Stop above an explicitly configured
threshold, the hook requests notes and this native command; the new launch clears
the nudge latch. A failed after-turn transfer also releases that latch when the
same Codex launcher and session are still alive, allowing the next clean Stop to
retry. A replacement session's latch is never cleared. It never sends Claude's
slash command to Codex. An active Fleet
loop keeps its recorded schedule across the cycle; a paused or ambiguous loop
must be resolved first. Loop dispatch waits while a handoff is pending.

## Preview and transfer

Web sessions use the same controller automatically after a native hard-quota
API error or an explicit empty Claude subscription inventory response (T943).
The hub emits `claude_pool_unavailable` only for absent provider inventory;
existing credentials refused by authentication, pausing or policy keep their
original refusal. The shared session gate reads only the exact Claude transcript,
waits at most 30 seconds for a clean boundary, and writes one continuation receipt
per source session before starting `fleet-transfer.sh --to codex --quota-continuation`.
It first runs a bounded read-only `--dry-run`, recorded as `phase=preflight` and
`controller_attempted=false`. A refused or unavailable preview does not launch a
target. After correcting the reported prerequisite, explicitly recheck the exact
receipt (values come from its private JSON):

```sh
python3 ~/.claude/fleet/bin/fleet_session_gate.py quota-recover \
  --fid FID --source-session SOURCE_SID --request-id REQUEST_ID
```

This archives the previous receipt and queues one new preview with a new request
ID. Repeating the old command refuses. Source/error changes, unsettled deliveries,
legacy receipts without evidence, and any actual/uncertain controller attempt
refuse recovery. A queued, interrupted or still-running read-only preview may be
superseded the same way: its old worker must pass the request-ID comparison before
it could launch anything. Before launching the mutating controller, the worker rechecks
identity and deliveries under the gate lock, then writes
`controller_attempted=true`; a crash after that point never authorizes another
launch. A late preview/worker cannot consume or overwrite a replacement request.
Native API errors can leave OSC 7501 at `exited` while Claude is still at its
prompt. The controller verifies the exact quota error, native error/idle state,
empty prompt and no live tool, background process, approval or loop twice before
accepting this boundary. Even after native Stop-and-wait or Escape, OSC `exited`
is not a Stop acknowledgement: the live module must independently prove no main
turn and an empty underlying prompt through `park.v1`. The strict tool transcript
oracle must also confirm no unreturned `tool_use`, including tools without a child
process; malformed/unreadable records refuse. Missing/expired module
evidence keeps the source safely refused. It never restamps the source `done`.
Subscription quota can instead open the native `needs` choice menu. The controller
requires the exact quota transcript, OSC `blocked/dialog open`, fully visible known
quota choices, no recent terminal input, the existing native `park.v1` proof of an
empty underlying prompt and stopped main turn, and the tool and scheduler proofs.
Under its transfer mutex and rotation lease it records one Escape before sending it;
then it requires the native error/idle boundary and empty input, and runs all normal
transfer checks again, including exact source and input after target authentication
immediately before exit. Any draft or unknown composer holds the transfer before
Escape; input that appears during cancellation holds it again. An approval, changed/unknown menu, armed auto-resume, scheduler
without proof or unconfirmed cancellation remains recoverable without another keypress.
Dry-run only previews this cancellation and conditional recheck; it never authorizes
exit from `needs`. Private evidence is in `quota-dialog-stop/<source-hash>.json`.
Drafts remain unsent. Network,
authentication, per-minute request throttling, personal budget refusals and user
cancellation do not trigger it. The existing controller may refuse unsafe input,
pending tools, schedules or target authentication; no force flag is added.
`session-gate/<fid>/quota-continuation.json` and `quota-transfer.log` retain the
result and controller evidence privately. Unknown completion is recovery, never
another automatic launch. Queued unsent words return to the page; accepted words
are never resubmitted. A controller failure after binding Codex keeps that target
in recovery too, without a second writer. Codex does not automatically switch back.
An earlier refusal for an unsettled delivery or missing boundary, before any
controller was launched, can be reconsidered once the delivery settles and a native
boundary appears. It still must pass every controller proof. An attempted controller
or uncertain keypress is never retried through this exception.
Trial admission reads the default agent's pool. The unified open route resolves
and pins the trial's actual provider and checks that pool before counting a line;
explicit Claude cannot borrow Codex headroom, and local defaults cannot change the
admitted provider. A missing team default keeps the dispatch protocol's Claude
compatibility default; an invalid stored default refuses default admission/open.
Provider changes retain
the person's budget, seat, identity and resource limits.

**Preserve waiting or completed tasks.** Native `done` only means a turn ended;
it does not prove task completion or approval. An operator transferring a safely
settled live session may explicitly add `--disposition waiting` or
`--disposition completed` with private `--handoff FILE` describing the original
intent and pending approval/completion. The manifest and pickup preserve that
disposition: the target acknowledges the switch and waits for a new instruction;
it must not execute historical requests, submit drafts or interpret migration as
approval or GO. The default `continue` keeps normal task continuation. These
options do not relax source/input/tool/scheduler guards: an approval dialog still
refuses, and an active/uncertain loop must be resolved through its controller.
Non-continuing transfers do not support after-turn, native resume, scheduling
takeover or automatic login retries, which could otherwise lose this intent.

Run from the hub, another pane or an external terminal. The source must be idle
(`done`), with no pending `/fleet-handoff` cycle, and must have its own linked
worktree or be a managed no-repo HOME session (below). The base checkout and panel windows are refused. A source agent may
use `--prepare-only` itself, or `--after-turn --handoff <notes>` as the final tool
call of a handoff turn. An immediate cutover cannot run inside its own source.
There must be exactly one worker pane. A marked task-list sidebar (`@sidebar 1`) is allowed and
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

## Managed no-repo sessions

A Fleet-created no-repo conversation in the physical login HOME can use the same
panel action. The controller requires `@norepo 1`, a worker role and a lifelong
`@fleet_id`, with no repo/issue/raw/worktree binding. Panel windows, the base
checkout, arbitrary directories and unmarked HOME shells still refuse. It never
creates a repository or manufactures a worktree stamp. The packet records a
`norepo` workspace and the existing role, agent definition, parent identity and
task record; it performs no git operations. The target uses the common launcher
and the source's agent definition, preserving its tool grant and role skill.

The exact source process, native session and transcript are required. Before
exiting it, transfer checks the source input and preserves an exportable unsent
draft as **unsent**, never as an instruction. Unknown/multiline input refuses.
Transfer and the common Codex launcher share HOME trust handling (#3029). A
dry-run reads the effective TOML config, including single-quoted entries and a
proxy home's symlink. An absent entry is ready only on a currently trusted node
with pre-trust enabled and a writable durable config destination. The actual
cutover fills the entry before source exit; a normal no-repo launch in physical
HOME does the same. It preserves symlinks, permissions and unrelated settings.
Explicit `untrusted` and `FLEET_PRETRUST=0` never grant a missing HOME entry.

Both dry-run and cutover refuse a busy source, pending handoff, missing target
launcher/hooks, invalid target auth, unknown scheduling or unreadable input.
One exception (T521): a `--dry-run` asked from the source's OWN pane — the
`transfer check` of `/fleet-handoff --to`, run mid-turn — is not refused for
`working`; the `--after-turn` arm that follows waits for the real Stop. Identity,
target auth and scheduling are checked as for any dry-run.
The no-repo target must bind its native identity in the retained pane, with the
same lifelong identity, role and routing. A live process alone is insufficient.
A target still running without a proven binding is retained for inspection;
rollback must not replace it with a second writer.

### Native cron handover

The panel asks the source to prepare through the normal peer bridge when native
scheduling needs verification. The source remains running while it reads its
current tasks, exports the verified plan, writes private handoff notes and arms
the switch as its final tool call. The request pins pid, native sid, lifelong fid
and target, with a five-minute deadline checked at arm and before source exit.
Each request also carries a fresh UUID, embedded literally in its source message
and in the first line of the handoff notes (`Fleet-Preparation-Request: <UUID>`).
The source uses the existing transfer tool with those notes; no new MCP argument
is required in an already-running session. Arm, the detached waiter and the
last check before exit require that same UUID, never the latest request file's
identity alone. Old notes, waiters, rejections and completion receipts cannot
authorize or modify a newer generation.

Repeated clicks deduplicate a valid, confirmed request. After it expires, or
after the source explicitly rejects it using the exact command supplied in the
request message, a new explicit click creates a fresh generation. A send with
unknown delivery remains blocked even after expiry; it is never blindly resent.
The final exit check atomically commits the generation, preventing replacement
during cutover. A failed attempt with the exact source still alive records its
rejection; an unresolved cutover requires recovery rather than a second writer.

The old interval import does not establish that a native cron is still active.
For a no-repo Claude source with native scheduling, first have **that source**
call `CronList`. It must be from the current process, less than five minutes old,
with no subsequent scheduler mutation and no round due within sixty seconds.
Historical creates, stale markers and
ambiguous lists refuse before the source exits.

The source writes a private JSON plan with `jobs`, one object per current id:
`id`, exact `prompt`, five-field `cron`, boolean `recurring`, IANA `timezone`,
Unix `expires_at` and explicit `stop_when` (an empty string means no additional
termination condition). Every current native job must be present, including
one-shot jobs; deleted jobs must be absent. A one-shot with no separate expiry
uses explicit `expires_at: null` and ends after its first accepted delivery.
The plan also contains `native_source: {"confirmed": true, "job_evidence": …}`.
When the native list omits or truncates prompt, cron, timezone, expiry or termination, `job_evidence` must
record each missing field as `{ "value": <exact value>, "source": <verified evidence> }`
under that job id. An unknown value is a blocker, never an invitation to infer it
from a fifteen-minute frequency or the marker's grace-extended expiry.
The text form of CronList proves current membership and recurrence, while its
truncated prompt needs a separately verified complete record. Every job's
`durable` flag must be proven. Session-only jobs move to Fleet's scheduler.
Transfer checks HOME's `~/.claude/scheduled_tasks.json` even without a native
marker or transcript entry (another session can create a project task): a durable
record still there, with no single-owner handover, refuses before exit or arming
(#4263's guard, still the fallback). Unknown table/project formats also block.

### Durable one-shot tasks: the single-owner handover (#4280)

A durable task survives the source's exit on disk, but nothing delivers it on
time afterwards (a later Claude only offers a catch-up). `bin/fleet_transfer_durable.py`
moves it to the Fleet loop of the switched conversation with exactly one owner at
every instant, recorded in `$FLEET_CONF_DIR/transfer-durable/<fid>.json`:

| state | owner | how it gets there |
|---|---|---|
| `staged` | native | the inert Fleet copy + the native record are written and read back; Fleet's dispatch answers *wait* |
| `withdrawing` | native while the record is in the table, else Fleet | written **before** any native change |
| `withdrawn` | Fleet (inert) | the record is gone and its evidence agrees (below) |
| `active` | Fleet | the source process is verified gone (pid + procStart, never the session id — a `/clear` keeps the process) and the target's loop is bound; the only state Fleet delivers in |
| `complete` | done | Fleet's delivery was accepted; a copy a stale writer put back meanwhile is withdrawn again |
| `rolled_back` / `returned` | native | before activation, or the record reappeared before Fleet delivered it |

**Road 1 — the live source holds the scheduler lock (the panel's default).** The
preparation message has the source include the task in its plan (durable evidence
true); `export-cron` stages it; the source runs `fleet_transfer_durable.py begin`
(write-ahead), its native **CronDelete**, a native **CronList**, then `confirm`,
which needs every id's CronDelete receipt, a later CronList without them (no
scheduler call after it) and the table without them. Fleet never writes the native
table on this road. Arm only after `confirm`.

**Road 2 — the source cannot cooperate** (`--durable-takeover`):
the controller stages the records the source process itself created, `/exit`s it,
and only after the exit withdraws them — inside the isolation boundary: Fleet holds
the **launch gate** (`transfer-durable/launch.gate`; `fleet-session-wrap.sh` starts
no Claude in that HOME until it is released) and **every live Claude process of the
login** must be registered (`~/.claude/sessions/<pid>.json`) and run outside the
HOME project — native writers rewrite the whole table and share no lock, so an
unknown, old or HOME-bound Claude refuses before any write, naming its pid (and one
appearing during the write is shown as `attention`). The rewrite is a plain
read-modify-write: re-read right before an atomic rename, only the staged records
go, every other record stays byte for byte. A scheduler lock held by another live
process refuses; the lock is a hint, never the proof. A source with an active
session-only schedule (its `@loop` mark, or a replay of its transcript) is refused
here: only its own verified plan can move those.

**Failure keeps one owner.** Before the receipt / the withdrawal the native record
never left (`rolled_back`, nothing to restore). After it, a target that does not
bind rolls back by resuming the source **through the same Fleet loop** (the
recovery loop carries the job and activates it); a check that fails while the
source still runs asks it to re-create the task with native CronCreate, and only
its receipt plus the table settle `restoring` → `rolled_back`. A controller killed
mid-way is settled by the quota tick's sweep (`fleet-loop.py recover` →
`recover_all`): record still in the table ⇒ native; already withdrawn ⇒ Fleet,
marked `attention` until `resume-source.sh` takes it into the loop; a source killed
between its CronDelete receipts and its CronList counts its receipts plus the
table. Evidence that settles nothing is shown (`fleet_transfer_durable.py status
<fid>`), never resent. Only Claude 2.1.295's formats are accepted, and a native
one-shot at :00/:30 (native picks an early jitter) does not move.

For verified session-only tasks, the panel instructs the owning Claude session
to run this exporter itself without stopping any task (not an operator step):

```sh
python3 ~/.claude/fleet/bin/fleet-loop.py export-cron \
  --session <fleet> --jobs-file /private/path/verified-cron-jobs.json
```

The exporter reads the exact source through transfer's inspector, pins its pid,
native sid and fid, checks the current list, and stores the private plan under
`$FLEET_CONF_DIR/transfer-plans/<fid>.json`. The panel's transfer reads it, repeats
validation, and rechecks it immediately before `/exit`. A fresh list/export is
needed if the evidence ages or the source process changes. The source keeps its
native tasks until it exits; only then can the target's Fleet scheduler bind.
Only a selected native exit dialog listing exactly the verified scheduled tasks
may be confirmed; other background work or a different dialog refuses.

Fleet retains each job's prompt, wall-clock phase, timezone, expiry and stop
condition. Due jobs use the same native conversation writer. An accepted wakeup
advances only its due jobs and retires a one-shot after its first accepted
delivery; a delivery whose result is uncertain is paused and
never resent automatically. The owner ends one responsibility with
`fleet-loop.py stop --job <id>`; `defer` refuses multi-cron plans. A recurring
job keeps its rounds until its expiry and then delivers ONE final round, the first
match at or after it (native 2.1.295 deletes a 7-day-old job after that fire);
a one-shot ends at its expiry. Native's per-id lateness jitter is not reproduced. On a failed target that has exited, rollback resumes the
source conversation through the Fleet scheduler with the last recorded schedule;
it does not assume `Claude --resume` restores in-memory CronCreate jobs. An
ambiguous target delivery requires inspection before recovery.

## Target login check

On a separated login (`credsep.json`), an unpinned Codex target uses the
credential proxy, just as the Codex launcher does. The check maps the target
home to its proxy account and asks that login's authenticated control socket
for a metadata-only verdict: its subscription lease must exist, be unexpired
and have no upstream rejection for the same credential. No credential is copied
to the login. An unavailable or older proxy refuses the transfer; deploy the
matching proxy version before retrying. An explicit Codex profile/account keeps
the local registry check. A central-only route cannot be attested by a local
lease and remains refused until central target attestation is available.

Before a cutover asks the source anything, `--dry-run` and the first step of a
real transfer ask `bin/fleet-account.sh target-auth` whether the TARGET account
can log in (issue #1667): a Codex profile whose ccquota login state is not
`valid` / `refresh_due`, or whose home is missing; a Claude pool label marked by
`fleet-account.sh mark-reauth`, whose hub-managed token has expired, or whose
token file is unreadable. A pinned `--target-file` (a retry's) goes through
`check-target` the same way. A refusal prints `fleet-transfer: target-auth: …`,
exits 1, leaves the source running and
records a `▲ transfer-refused` row for the `prefix !` alerts popup. The same
read happens once more right before `/exit`. With no registry to ask (no
ccquota, multi-account off) the verdict is `unknown` and the launch behaves as
it always did. `fleet-account.sh migrate` makes the same check before each
window's `/exit`; `clear-reauth <label>` lifts a mark after a new login.

## Re-login, then the switch finishes itself

A switch stopped by the TARGET's login leaves a retry record (issue #1669):
a target-auth refusal, or a rollback after which
`target-auth` refuses the target. One record per window, under
`$FLEET_CONF_DIR/handoffs/retry/<fleet>-<id>/` (0700): the window's
`@fleet_id`, the source session id, `--to`, and copies of the target file,
notes and loop spec. Metadata only.

↵ on the `▲ accounts · reauth · <profile>` alert runs
`bin/fleet-relogin.sh login <agent>/<profile>` in the popup — Codex:
`ccquota codex login <profile> --device-auth`, a link and a code you can open
on a phone; Claude: `claude setup-token`, then the token pasted (hidden) into
the pool file and `clear-reauth`. Once `target-auth` says `ok`, every pending
record waiting on that login is run again with `fleet-transfer.sh --retry
<dir>`. The status bar also hands pending records to `fleet-relogin.sh resume`
on its minute refresh, so a login fixed anywhere else is picked up too.

A record is retried ONCE: `pending → retrying → done | failed`. The retry runs
with no record of its own, so a retry that is refused or rolls back again ends
`failed` (`▲ transfer-retry-failed`) and nothing runs again. A target that still
cannot log in leaves the record pending (`--retry` exits 3); a source mid-turn
gives the claim back. A window that is gone or now runs another conversation
cancels it; a switch done another way supersedes it; a record older than
`FLEET_RELOGIN_RETRY_TTL` (24h) expires.

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

### Authority authentication failure before native start

The wrapper and `resume-source.sh` both retain the repo-authority admission gate.
The ticket client uses an explicit endpoint/token pair as supplied; a URL alone
uses the existing node/broker reader's complete pair. A token without its endpoint
is refused, and a rejected explicit pair is never retried as another identity
(#4490). The fallback changes only the reader subprocess environment.

Publishing the fix does **not** update every existing recovery packet. A packet
records `source_resume_argv`; its generated `resume-source.sh` embeds the launcher
and helper paths from the install that created it. If those paths name an old
version directory, switching `current` leaves them pointing at the old resolver.
The #4490 rollback fixture generates its packet from the fixed fixture install;
it does not test recovery through an existing packet pinned to an older install.

Before attempting recovery, the original owner rechecks the retained window's
repo, issue/task, Fleet identity, source SID, worktree, original launcher arguments
and packet. Confirm that the previous wrapper and every native writer have
stopped, and inspect which helper/wrapper/resolver the recovery will actually
execute. Use the original packet's public recovery entry only when that path
consumes the fix and all source/idle/lease/authority gates remain intact. A packet
pinned to an unfixed version remains **BLOCKED** until its recovery owner verifies
a supported original-SID path. Normal publication alone is not that verification.
Do not rewrite the packet, alter files in an old live install, invoke internal
`--run-source` directly, or replace the task to make it appear recovered.

For an initial start that never reached native, the original owner likewise
verifies that the supported standard wrapper entry resolves to the fixed version
before using the original task parameters in the same window and worktree. Do
not dispatch a replacement, change global authentication, or skip admission/leases.

Record the actual native executable/PID and SID in the retained pane, authority
admission and its native observation receipt, and preserved uncommitted work
before reporting recovery. A dispatch receipt, shell prompt, or native process
without its registered SID/authority receipt is insufficient. An ambiguous binding, live writer,
held recovery lease or renewed authentication refusal leaves the original work
retained for its owner; it does not authorize repeated starts. A merged fix and
an isolated fixture do not establish that an affected live task has recovered.

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

**When a due wakeup is sent (#4431).** Never on the panel's word: `looping`
(a Stop with a pending Loop) is re-asked — the children / bg / tool / human
reasons are read fresh and only `loop`, this ledger's own pending wakeup, is
dropped; `working` / `needs` / lifecycle / transfer / quota / handoff / 30 s of
typing / an unsent draft still hold it. Then the pane's own road (the C3 launch-proof
tier left with EPIC T497 C8; a `pending_delivery` it left is dropped, the round still due) —
every pane, this transfer bridge too: Codex `thread/read` idle +
`turn/start`, Claude inbox + transcript ack. `last_attempt.fence` says
`legacy_unfenced`, which is **not** an atomic accept. The ledger carries
`due_since`, `deferred_reason`, `last_attempt` (at · fence · state · reason ·
delivery id · native session · task / owner generation · observed_at) and
`accepted_turn` beside the old `last_turn_id`; an active controller is never
read as an accepted delivery.

The owning Codex session can use `defer --seconds 3600` to choose its next delay,
add `--prompt-file /private/path/updated-task.md` to update the task, or use `stop`
when finished/cancelled. Without a change, the last interval repeats. This is
Fleet scheduling, not restoration of Claude's in-memory `ScheduleWakeup` object.
The source must exit before the target timer can start.
When Claude shows its native exit confirmation for a single self-paced `/loop`,
an explicit `--loop` transfer confirms the selected **Exit and stop tasks** once.
Different dialogs and other background jobs are left for inspection. Verified multi-cron plans use the separate no-repo handover checks above.

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


## Subscription failover (retired)

The per-session quota failover planner (`.fleet-failover.py`: request queue under
`handoffs/quota-requests/`, `fleet-account.sh reconcile` / `failover-status`, the
`@quota_failover` / `@quota_stuck` marks, `fleet-migrate.sh --limited / --idle /
--all / --stuck`, the doctor's `failover` / `failover-stuck` rows) is retired
(T546, EPIC T542): it never completed a move, and a full subscription is the
credential pool's to change — the session keeps running where it is. The two old
entry points answer 「已不用：订阅由池子挑」 for one version. What a manual move
still borrows from it lives in `bin/fleet_transfer_source.py`: `settled` (a
`looping` Codex between rounds), `background` and `terminate-background`
(`fleet-migrate.sh --force-bg`, issue #873). Switching a row's subscription by
hand is retired too (T550): the sidebar item, `dash-migrate.sh` and the hub's
`worker_switch` are gone or answer 「已不用」 — the pool picks.

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
its recovery (`fleet-loop.py recover`) can reattach a dead controller only to the
same restored native UUID
and worktree. Explicitly stopped/paused loops and replacement threads stay off.
A restored loop runs at the existing tick cadence; missed intervals coalesce.

### External recovery of a quota-stuck session loop

A quota-stuck Claude need not reply, run CronList, write handoff, or produce a
new Stop hook. An operator can use the existing controller with
`--quota-continuation --quota-loop-replacement /private/replacement.json`,
`--expected-source PANE:PID:SID`, `--expected-session-id SID` and private
`--handoff` notes. Dry-run checks without keys; actual cutover uses the same
mutex, lease, native quota cancellation, two-phase identity/input/tool checks,
and target admission. Automatic web continuation does not enable this option.

The JSON contains `prompt`, `interval_seconds`, and `quota_replacement` with
`version: 1`, exact `fid`, `session_id`, `pid`, `proc_start` (the existing durable
controller's process fingerprint), original `user_message_uuid`, and exact
`invocation`, for example `/loop 30m check the task`. The prompt and cadence must
match that exact original user text in the registered transcript. This is an
**authorized replacement**, not a live native export. Historical ScheduleWakeup
records never prove current membership, a pending deadline, or successful work.
The replacement begins with a fresh interval; missed ticks are never replayed.

For a task command rearmed by ScheduleWakeup (rather than a literal `/loop`),
use `basis: "historical-wakeup-spec"` in `quota_replacement`. Bind the exact
source user-command record with `user_message_uuid` and its text's
`user_message_sha256`, plus `schedule_message_uuid` and `schedule_tool_use_id`.
The original `<command-name>` must match `invocation` and `prompt`; the latest
confirmed scheduler tool must be that exact ScheduleWakeup call, with a native
`scheduledFor`/`clampedDelaySeconds` receipt matching the chosen interval.
The historical deadline is discarded. A later scheduler mutation, missing
receipt or mismatched task refuses. These records supply specification provenance;
the transcript's `user` role alone is not a new business approval. The operator's
private handoff must retain current task authorization, completion and waiting
conditions from the durable task/control record. Starting the timer never grants
an EPIC GO that the task did not have.

Only a single session wakeup is supported here. Durable records/journals,
competing Fleet loop controllers, unknown marks, autonomous loop specifications,
and multi-cron plans refuse with the missing evidence. Durable tasks continue to
use `--durable-takeover` and its existing isolation/journal road. No source-model
cooperation is needed on that road either; mixed/session-only schedules still
need a separately supported ownership proof.

The live native module must prove an empty prompt and stopped main turn; exact
transcript and process inventories must show no unfinished tool or live work.
The normal `/exit` confirmation, if present, must list exactly the authorized
single `/loop` invocation and selected “Exit and stop tasks”. Unknown dialogs
get no confirmation. Source transcript is checked again after process death to hold any racing tick.
Source process death and a childless shell/dead pane are
required before the single Fleet timer starts. The private package retains
original intent, source transcript, authorization, fingerprint, spec hash and
native exit screen. Changing the spec after packaging refuses. If the target
fails or its completion is unknown, the timer remains paused in that package;
there is no automatic source/timer restart. Inspect the retained target before
using explicit recovery. Drafts and business approvals keep their existing rules.
