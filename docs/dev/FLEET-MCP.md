# The fleet tool service — `fleet` (bin/fleet-mcp.py)

One local stdio MCP server that every Claude **and** every Codex session the fleet
opens mounts under the name `fleet` (issue #1807, EPIC #1813 C5). Both agents see
the same tools; Claude shows them as `mcp__fleet__<action>`. **This file is the one
spec** — a later member (C6 报问记合, C7 identity, C8 the hub route, C9 the
skills) adds its tools here and in `bin/fleet-mcp.py`, nowhere else.

## The rule

A tool only **checks** its arguments, then runs the existing script **unchanged**
(EPIC #1813 decision 4 — the rule the mod's retired `tools.ts` kept):

- an unknown argument, a missing one, a wrong type, an out-of-range number, a
  malformed `repo`, a `repo` this fleet does not host, an unknown tool → refused
  with the reason, `isError: true`, text ending `Nothing ran.` — and nothing ran;
- a valid call runs the script and hands back its **exit code, stdout and stderr
  as they came** (`structuredContent: {command, exit, stdout, stderr}`; the text is
  `exit <rc> · <script>` then the output). A non-zero exit is data, not an error:
  `spawn` exit 2 is "at capacity", `await` exit 3 is "still running".

Caps, the origin gate and every guard live in the scripts — once.
No hub is needed for any tool (EPIC #1813 rule 1): with no hub configured all of
them are listed and run locally.

## Two groups — `fleet` and `fleet-orch` (issue #3113, EPIC #3111 C2)

The same script serves two servers. Every session mounts the **core**, `fleet`
(`conf/mcp-worker.json`): what a session works with — `status` · `repos` · `agents` ·
`brief` · `ask` · `report` · `pr_verdict` · `pr_merge` · `handoff` · `context` ·
`transfer` · `where` · `open` · `show` · `set_reap`. The **dispatch group** —
`spawn` · `await` · `children` · `answer_dialog` · `send` · `task` · `clear` — is listed only by
`fleet-mcp.py --group orch`, the server **`fleet-orch`** (`conf/mcp-orch.json`). It
ships with the core (issue #4334): no plugin registers it. Claude shows its tools as
`mcp__fleet-orch__<tool>`; Codex shows them on its `fleet-orch` server.

- **Every session has it** (issue #4703, after #4591 — any session may spawn; the
  session caps, in the scripts, are the only bounds). The launcher
  (`fleet_launch_mcp` in `bin/fleet-launch-lib.sh`, both agents' one step; for Codex it
  asks `fleet-mcp.py --bridge-seat`, 0 in any fleet pane) mounts `fleet-orch` for every launch and says `FLEET_MCP_ORCH=1`.
  `@agent_spawn` is still stamped (the agent file's grant) but gates nothing; EPIC
  #4333 C1's `@agent_spawn 1` switch (issue #4334) is gone. No plugin, seat or role
  name is asked (issue #3118).
- **A session launched before #4703 without the group** (`FLEET_MCP_ORCH` unset)
  needs no reopen: its `fleet` server, once it takes over the new version (#1898's
  exec + `tools/list_changed`), lists the dispatch group itself, and answers it
  (`road=legacy`) as it always did.
- **There is no role-taking tool** (issues #4334, #4340, EPIC #4333 C7): a role is a
  session template, `spawn` with `agent:orchestrator`.
- **There is no `rule`** on `task` (issue #4340: the dispatch rule
  table is gone; nothing writes 「按规则 N 派发」 or a `fleet:rule` marker).
- **Old sessions keep their tools (#2068, one version — `# compat-1v`).** `fleet`
  still ANSWERS every dispatch-group call under its old name; the call log marks it
  `road=legacy`. A server that takes over from a pre-group version (#1898's exec —
  the handover carries no `list`) keeps listing all 30 tools and passes that on, so
  Claude Code's re-list after `tools/list_changed` takes nothing away mid-session.
  `fleet-oldcfg-replay` counts a tool the new server no longer lists but still
  answers (its `--probe`) as kept.
- `fleet-mcp.py [--group orch] --list` prints a server's list, one name per line;
  `--mount codex --group orch` is Codex's `-c` value for `fleet-orch`;
  `hooks/bash-guard.py`'s `_DIRECT_TOOLS` names each script's tool on its own server.

## Tools

The first table's `children` · `spawn` · `await` · `send`, `answer_dialog` and `clear` (below)
are the dispatch group's — listed by `fleet-orch`, answered by `fleet` as legacy.

| tool | arguments | runs | exit codes |
|---|---|---|---|
| `status` | — | `tmux display-message` (this window's line) + `fleet-children.sh` + `fleet-repo.sh list` | read-only |
| `children` | — | `fleet-children.sh --json` | the script's |
| `repos` | — | `fleet-repo.sh list` (`structuredContent.repos` = the parsed `owner/name` list) | the script's |
| `agents` | — | `tmux list-windows` of this fleet, `fleet-children.sh --json`, `fleet_origin_key` | read-only; each row `key · issue · agent · state · is_self/is_parent/is_child` |
| `spawn` | `issue` (int ≥ 1), `repo`?, `reap`?, `agent`?, `coding_agent`? | `dash-issue-session.sh <issue> [--repo R] [--reap P]` | 0 spawned / window exists · 2 at capacity · 3 closed or already has a PR · 1 infrastructure |
| `set_reap` | `policy` (`merged[:<dur>]` · `done[:<dur>]` · `loop-end` · `at:<HH:MM\|ISO>` · `keep`) | `fleet-reap-policy.sh set <policy>` — this window's `@reap_policy` (issue #1902) | 0 set · 2 not a policy · 1 no window |
| `await` | `issue` or `task` (`T<n>`, issue #3330), `repo`?, `timeout`? (1–570 s, default 540) | `fleet-await.sh <issue\|T<n>> --timeout T [--repo R]` — an accepted task reads its authoritative outcome; an issue number whose window is an accepted launch waits on that window's `T<n>` (no `@task`: NO-WORKER), and a hub-authority repo never spawns by number (NO-WORKER — use `task`, issue #4398); legacy records wait on their issue worker (no issue: NO-WORKER) | accepted T: 0 SUCCEEDED · 1 FAILED · 2 CANCELLED/REFUSED · 3 WAITING/UNKNOWN; legacy: 0 MERGED · 3 TIMEOUT |
| `task` 派 | `title`, `body`?, `repo`?, `spawn`?, `reap`?, `agent`?, `coding_agent`? | `fleet-task-record.sh dispatch --title T --body-file - [--repo R] [--spawn] [--reap P] [--as A] [--agent claude|codex]` — the hub's task record FIRST (`T<n>`, `POST /v1/node/tasks` with the node token, issue #3330), then a repo task's session bound to the record alone (issue #4897: `dash-raw-session.sh --repo R --task T<n> --reap merged`, no issue — its SessionStart flow reads the record with `brief`, it lands its PR and `report merged` closes the record; reaped once the record is closed), or a no-repo session given the words (`dash-raw-session.sh --no-repo --task T<n>`). Nothing is filed as an issue (#4898). No hub: exit 3 | 0 · 1 the hub refused · 2 usage · 3 no hub (no-repo) · the filer's / spawner's own |
| `send` | `to` (`issue:<N>` · `<slug>:issue-<N>` · `scratch-<N>` · `agent:<name>` · `T-<code>` · `fid:<uuid>` · `parent`), `text` | `fleet-peer-send.sh <target> -` (text on stdin) | `{delivered}` · `{queued}` (exit 3) · `{ended}` (exit 2 + stdout) |

### 报 问 记 合 (issue #1808, EPIC #1813 C6)

The rest of a worker's day. Each argument is one flag of the script; a body or a doc travels on
**stdin**, never through argv. Arguments that only make sense together are checked
together (refused, nothing ran): `slug` is
`path`'s, `doc` / `issue` are `check`'s; `until_merged` / `timeout` need `wait`.

| tool | arguments | runs | exit codes |
|---|---|---|---|
| `report` 报 | `state` (`merged` · `blocked` · `failed` · `stopped` · `waiting`), `pr`?, `summary`?, `outcome`? (`succeeded` · `failed`, accepted tasks), `dry_run`? | `fleet-report-parent.sh --state S [--pr N] [--summary T] [--outcome O] [--dry-run]` | 0 reported / no parent · 3 queued (delivered later — don't resend) · 1 refused; `merged` is checked against the PR's real state |
| `ask` 问 | `question`, `kind`? (`question` · `permission`), `suggest`? `default`? `due`? (hints, written under the question off the `ask_hint_*` strings — nothing acts on them), `class`? (accepted and unused since #4337), `issue`? (accepted and unused since #4898) | the question goes on the window's task record (`fleet-task-record.sh`, 「问过你」) when it has one, `set-claude-state.sh blocked` turns the window red, and a copy goes to the parent session — no GitHub comment (issue #4898) | 0 asked |
| `answer_dialog` 答 | `window` (`@<id>` / `%<pane>`), `fp` (the dialog's fingerprint), `picks` (labels verbatim; `N=<label>` with several questions), `by`? (`person` · `session` · `default`), `basis`?, `issue`? (where the trail goes) | `fleet-dialog-answer.sh <window> --fp F --pick L … [--by B] [--basis T] [--issue R#N]` — reads the open AskUserQuestion off that window's transcript, refuses unless it is the one named (fingerprint + labels), refuses over a person typing / a draft, presses once through `fleet-answer.sh` and confirms in the transcript, leaves one line in the answer log (代答记录, `fleets/<session>/answers/answers-<day>.md`) + a record-only comment (issue #2958) | 0 answered · 1 no window / transcript · 2 usage · 3 refused, nothing sent · 4 pressed, unconfirmed (never pressed again) · 5 a person is typing |
| `clear` 清 | `id` (the full ID, `T-<code>` or the bare code, any case), `timeout`? (1–120 s, default 30) | `fleet-clear-send.sh <id> [--timeout T]` (= `fleet-id.sh clear`, T592) — the window carrying that ID on THIS machine (none ⇒ refused, no cross-machine road), only when its turn is over (`@claude_state` done / idle) and nobody typed there in `FLEET_HANDOFF_DEFER_SECS`; `/clear` through the mod's inbox, else keystrokes (Claude: Escape + 0.3 s gap; Codex: no Escape, 1 s gap); confirmed by a new native segment on the ID's ledger; one audit line in `logs/clear-send.log` (who · when · which ID) | 0 cleared · 1 no such ID / not here · 2 ambiguous · 3 refused, not idle (nothing typed) · 4 sent, unconfirmed (never typed twice) · 5 a person is typing |
| `handoff` 记 | `action` (`path` · `find` · `repo` · `check`), `slug`?, `doc`?, `issue`? | `fleet-handoff-file.sh <action> [--slug S]` · `check - [--issue N]` (doc on stdin) | 0 · 1 none · 3 check findings (advice) · 4 ambiguous |
| `pr_verdict` 合 | `pr`?, `repo`?, `wait`?, `until_merged`?, `timeout`? (1–570 s, default 540 with `wait`) | `fleet-pr-verdict.sh <PR> [--repo R] [--wait --timeout T [--until-merged]]` | 0 READY · 1 any other verdict · 2 error · 3 TIMEOUT (call again) |
| `pr_merge` 合 | `pr`?, `repo`? | `fleet-pr-merge.sh <PR> [--repo R]` (the fleet's merge method) | 0 MERGED · 1 not READY / refused · 2 error |

`pr` is required in a repo landed through a pull request. In a repo the fleet lands itself (`FLEET_LAND=fleet`, issue #3602) there is no PR: both scripts hand it to `bin/fleet-land.sh` — `pr` then names the issue whose branch `issue-<N>` lands, and left out it is the window's branch; the verdict words and exit codes are the same, and gh is never run.

### The rest of a worker skill (issue #1811, EPIC #1813 C9)

What `commands/fleet-handoff.md`, `fleet-compact-resume.md` and
`fleet-context.md` still had a session type by path. With these the worker-run
steps of every skill name a **tool**, never a script (`bin/skill-tools-selftest.sh`
lints it): a script path appears only under a heading marked `运营者` or `排障`.

| tool | arguments | runs | exit codes |
|---|---|---|---|
| `brief` | `kind`? (`task` default · `claim` the same · `resume`), `repo`? (`issue` / `no_comments` accepted and ignored) | `fleet-brief.sh [--repo R]` · `fleet-compact-resume.sh --brief` | 0 go · 2 not in a fleet · 4 nothing bound · 5 the record could not be read |
| `context` | `json`? | `fleet-context.sh [--json]` | 0 OK · 1 another verdict · 2 nothing to read |
| `transfer` | `action` (`check` · `arm` · `export_loop`); `to` (`claude` · `codex`) for check/arm; `handoff` + `loop`? for arm; `transcript` + `output` for export_loop | `fleet-transfer.sh --session S --window $TMUX_PANE --to T --dry-run` · `… --handoff DOC [--loop L] --after-turn` · `fleet-loop.py from-claude --transcript F --output F` | the script's |
| `handoff` `arm` | `doc` (a stored file's path) \| `issue` (+ `repo`?) | `fleet-handoff-cycle.sh --pane $TMUX_PANE --doc D \| --issue N [--repo R]`, **detached** — the call returns at once with its pid; it must be the turn's last call | 0 armed |
| `where` | `json`? | `fleet-client-where.sh [--json]` | 0 named · 3 nobody connected · 1 could not tell |
| `show` | `file`, `inline`? | `fleet-show.sh [--inline] -- <file>` | 0 `saved:<path>` / `unconfirmed` · 4 `failed:<why>` · 2 PATH + `failed:` (say the path) |
| `open` | `target` (URL · `:port[/path]` · file) | `fleet-open.sh -- <target>` — waits for the far side's receipt (issue #3538) | 0 `opened` / `unconfirmed` · 4 `failed:<why>` · 2 a file not sent (say the path) |

Nothing passes through a shell. `--` before a file / target keeps a name starting with `-` a name.

### In a skill

A worker step names the tool as `mcp__fleet__<tool>` — the name Claude shows; a
Codex session reaches the same tool on its `fleet` server. The script stays the
implementation and the 排障 path (`FLEET_MCP=0`, a session without the server);
it is written only under a `运营者` / `排障` heading. Operator skills
(`fleet-epic-*`, `fleet-sync-install`, `fleet-move`, `fleet-history`,
`fleet-onboard`) keep their script form — the operator is not a worker session.

Reverse delivery is untouched (EPIC #1813 rule 3): a report the parent cannot take
waits in the peer queue / hub outbox, an answer comes back through a prompt — no tool polls for one.

`repo` is `owner/name` of a repo **this fleet hosts** — checked against
`fleet-repo.sh list` before anything runs. Omitted = the window's repo, as the
script decides.

## A call that outlives the turn (issue #1880, EPIC #2074 C4)

Claude Code moves an MCP call that runs past 120 s — an `await`, a `pr_verdict`
with `wait` — to a background task: the model gets «still running», goes on, and
usually ends its turn there; the answer arrives as a task notification when the
script returns. The session is idle to the TUI but not finished, and the Stop hook
says so: the server runs every tool as a subprocess, so a `fleet-mcp.py` under the
pane with a live child is a call in flight — `fleet_window_tool_busy`
(`bin/fleet-lib.sh`), the fourth `fleet_window_wait` reason — and the Stop writes
`looping` + `@claude_wait=tool` (the sidebar's 「等 fleet 工具返回」) instead of
`done`. Every idle judge (cfg-restart, install-sync's busy gate, the EPIC backstop,
auto-sleep, the idle reap) reads that as busy; the first re-ask after the call
returns (the sleep tick's `fleet-wait-reeval.sh`, the next Stop) writes `done`
again. An idle server, or one probing a new version, is not a call.

The same fact guards the call while it is still in the foreground: no hook stamps
`working` for its whole length and the input line is empty, which the state
reconcile (`fleet-state-reconcile.py`, #806) read as an idle prompt whenever it
could not find the session's registry record — and it could not, for a Claude
started while a viewer's grouped `<fleet>@view-<id>` session was the active
client (its record names that session). It now strips the `@view-<id>` (a `busy`
record outranks the screen) and never demotes a window whose fleet MCP server
still runs a tool (`kept working …` in logs/reconcile.log). `FLEET_TOOL_WAIT=0`
turns the reason off everywhere. `fleet-wait-selftest.sh` F,
`fleet-state-reconcile-selftest.py` and the `tool-wait-idle` drill
(docs/BREAK-IT.md) pin it.

## How a session gets it

The definition lives once, in **`conf/mcp-worker.json`**:

```json
{"mcpServers": {"fleet": {"command": "bash",
  "args": ["-c", "exec python3 \"${FLEET_MCP_BIN:-$HOME/.claude/fleet/bin}/fleet-mcp.py\""]}}}
```

- **Claude** — `bin/fleet-claude.sh` adds `--mcp-config=<install>/conf/mcp-worker.json`
  (the `=` form, #476). It is **additive**: next to every configured server when
  `FLEET_MCP_CONFIG` is unset, next to the allowlist when it is set (`none`
  included), and not added again when the allowlist already names a `fleet`
  server. It exports `FLEET_MCP_BIN=<install>/bin` (the server runs THIS
  install's scripts) and `FLEET_MCP_SERVER=1` — which tells the mod the service is
  here, so it registers no tool of its own (decision 8; mod 0.4.0, issue #1812).
  **A session launched before the service** (`--plugin-dir` only, no
  `--mcp-config`; every pane from before #1828 that was never reopened) has no
  `FLEET_MCP_SERVER`, and its tool list — registered once at ITS start — still
  carries the mod's `fleet_status` / `fleet_spawn` / `fleet_await`: a hot reload of
  the mod swaps the code, never the list. So the mod keeps them as the **fallback**
  (issue #2057, mod 0.4.1, `mod/fleet/hooks/tools.ts`): without `FLEET_MCP_SERVER=1`
  it registers the three from `fleet-mcp.py --spec status spawn await` (the service's
  own schemas, so there is one copy) and forwards every call to
  `fleet-mcp.py --call <tool> <json>` — the same identity check, argument check,
  script and call log as a `tools/call` (logged `road=call`). When the forward
  itself cannot run (no `python3`, the install's `bin/` gone, a usage exit) the
  answer is one actionable line: reopen the session (`/fleet-handoff`, or `claude
  --resume`) so it mounts the service, or run the script by hand meanwhile. A served
  session sees nothing of this — no spec read, nothing registered, no second
  `fleet` tool.
- **Codex** — the launch library's `fleet_launch_mcp` (the adapter table's `mcp` = `config`) adds `-c "$(fleet-mcp.py --mount codex)"`:
  `mcp_servers.fleet={command, args, env_vars, tool_timeout_sec}` derived from the
  same file, after any allowlist policy and before the caller's `-c`. Codex hands a
  server only a short env allowlist, so `env_vars` forwards `TMUX`, `TMUX_PANE`,
  `FLEET_CONF_DIR`, `FLEET_SESSION`, `FLEET_WORKER_CRED`, `FLEET_MCP_BIN`; `tool_timeout_sec=600` lets a
  blocking `await` finish (Codex's default is 60 s).
- **Off** — `FLEET_MCP=0`, a caller's own `--mcp-config` / `--strict-mcp-config`
  (Claude), or no `conf/mcp-worker.json` / `fleet-mcp.py` beside `bin/`: nothing is
  added and the argv is byte for byte what it was.

### Coding agent selection

`spawn` and `task` accept `coding_agent: "codex" | "claude"` for the
executable. Existing `agent` still names an agent definition (`--as`); it is
not a provider alias. For example, `agent: "reviewer", coding_agent: "codex"`
keeps the reviewer definition and explicitly chooses Codex. CLI `--agent`
means provider; `fleet-task-record.sh dispatch --as` selects a definition.
Unknown providers and contradictory repeated explicit choices fail before work
is opened. No picker or tool availability changes are part of this contract.

A local start resolves explicit provider, definition hint, issue label, fleet
configuration, then built-in Claude, in that order. The client placement API
has no local repository configuration, so its unspecified provider resolves to
Claude. The request records the source. A `--title` fast path may use cached
labels only before acceptance. Its accepted `dispatch` envelope carries
`request_id`, `requested_agent`, `resolved_agent`, `agent_source` and, with hub
acceptance, `task`, `generation`, `attempt_id`. Detached re-entry and remote
placement preserve it, including when labels or defaults change. It is data,
not an executable-provider receipt.

New provider-bearing placement requests use C1's additive authoritative task
records and existing operation journal. Legacy requests remain readable; an
existing legacy T record is never implicitly adopted. An unsent draft is not
accepted work. Placement of an existing T requires its matching accepted
envelope; a failed or uncertain placement cannot fall back to a new local
start. Hub-off local starts still freeze their provider without inventing a
hub task. The operation journal records the accepted task and generation;
it does not claim a lifecycle transition or populate execution receipts.
Actual process verification and lifecycle receipts belong to
C3; source merge is not evidence of deployment or live acceptance.

### A task's ticket (#4506, T477)

`task` / `fleet-task-record.sh dispatch` keep `request_payload.rule` (empty since
the rule table left, issue #4340) in the immutable payload; v1 still rejects legacy top-level `rule`
and `issue` setters. The hub task record is the ticket: nothing files one after
acceptance (the filer left with #4898, the hub's `ticket_prepare` / `ticket_link`
mutations and its own tickets with T477). A task's `ticket_ref`, when its caller
names one, is a GitHub issue `gh:<repo>#<N>` matching the start's repo and issue
— it keys the issue lease; `hub:` is refused.

### Task children and results (#4394; EPIC T497 C8)

A task's session is its window's ID (EPIC T497 C8): nothing claims the record,
fences a report on a generation or proves a native process. `report` is a
result on the calling window's ID (`fleet-report-parent.sh`; `outcome:
"succeeded"` / `"failed"` becomes the result's state, `state: "merged"` still
needs a confirmed merged PR); the hub reads the record's end off that ID's
newest result. Several results are fine, the newest counts. `state: "failed"`
alone remains workflow progress (for example a red CI check).

`bin/fleet_task_control.py` keeps the record's reads and one write:
`closed` (one read — 0 closed · 1 open · 3 unknown, the reapers' reader),
`await --task T<n>`, `children --task T<n> [--json]` (a `summary` — one count per
outcome), `cancel --task T<n> --event E` (a record no window ever opened, the one
change the hub still takes — EPIC T497 C13), `progress` (an EPIC driver's tick:
a `progress` event on the calling window's ID, relayed to nobody — issue #4957,
C12) and `receive` (a child report a relay carried here from before C8: delivered
to the parent by its ID — the window carrying it, else down its `prev` chain,
else up its parent, else the person's reminder; one event delivered once across
reconnects). An unavailable or non-authoritative record answers `UNKNOWN`, never
a local-cache success. `report` (answers 5) and `finalize` (answers 0) stay one
version for an older caller (compat-1v).

**An EPIC is a parent task and its children** (issue #4957);
`bin/fleet-epic-tick.py status` is the batch's one read: the charter off the
parent's dispatch body, each member's state off its children and their IDs
(docs/dev/FLEET-ID.md «EPIC 批次»).

### Conditional idle acceptance and provider observations — retired (EPIC T497 C8)

`fleet_runtime.py`'s observations of a launch-proof session (`read`, `project`,
`idle-accept-capability`, `accept-if-idle`, the Claude mod's `event`) read the
window's launch receipt, which nothing writes since C8. The file stays one version
(compat-1v): `event` is taken and dropped, every read answers unknown. A due loop
round goes the pane's own road (`fleet-loop.py`: the Claude inbox, the Codex
thread); a pending delivery the old road left is dropped and the round stays due.

### Pending-tool observations (#4474)

`bin/fleet_pending_tool.py` owns the existing Claude transcript oracle and
pane→Claude BFS. `fleet-pending-tool.sh` and `fleet_pane_claude_pids` remain
compatibility entries; there is no second provider or background service.
The Python entry for #4444 is:

```python
from fleet_pending_tool import observe, read_panes, parse_panes, PANE_FORMAT

# Default transport: two tmux commands and one ps for the whole batch.
first = observe(lambda: read_panes("fleet"))
expected = {r["pane"]: r["identity"] for r in first}
# At the NEXT safety-check deadline, call observe again, never reuse first.
second = observe(lambda: read_panes("fleet"), expected=expected)

# A consumer with an existing tmux control connection supplies a synchronous
# command function. Each observation then forks only ONE ps, for every window.
def reader():
    return parse_panes(control_command("list-panes", "-a", "-F", PANE_FORMAT))
results = observe(reader, expected=expected)
```

`reader` must perform a fresh synchronous read on each invocation, returning
the requested rows from one socket. `PANE_FIELDS` names socket path, server PID,
window/pane IDs, pane PID, worker FID, agent and native SID; `PANE_FORMAT` carries
a final sentinel to preserve empty fields. Grouped-session duplicates are
deduplicated by socket/pane. Callers may filter to their candidates, retaining
every field. No binding, process or transcript cache survives `observe`.

Each version-1 result contains `pane`, `code`, `tool`, `reason`, `identity`,
`observed_at` and `expires_at`. Identity includes socket device/inode, server
kernel birth/executable, worker FID, window/pane, native PID/birth/executable/SID
and ancestry to the pane. Native registry PID, SID and published birth
(`startedAt`/`procStart`) must agree. Missing FID/SID/registry birth is unknown.
The optional `expected` argument must contain the complete first identities;
missing or changed entries refuse. It never renews an old observation.

Within one call, processes/argv and each transcript are parsed once. Before
returning a known result, the reader rechecks the live bindings, socket,
kernel process identities, registry SID and transcript inode/size/timestamps.
A failed process scan, PID reuse, process exit, recycled window, other socket,
malformed transcript or changed identity returns code 4. Transport exceptions
at the first read propagate: the consumer must retain **all** candidates.
An observation taking 5 seconds expires (`fleet_pending_tool.TTL`); consumers
must also reject results at or after `expires_at`. Two checks 20 seconds apart collect two process tables.

| Entry / condition | Output and exit/code |
|---|---|
| CLI path, newest tool without a matching result | Tool name, 0 (the historical selection order) |
| CLI path, no pending / absent / unreadable | Silence, 1; malformed JSON lines still skipped |
| CLI bad arguments | 2 |
| CLI target, no Claude or no such pane | 3 |
| CLI target, Codex/other agent or failed resolution/read | 4; malformed/empty transcripts now also refuse |
| Batch known pending / known no pending | 0 + name / 1; neither means runtime idle |
| Batch no native, missing birth, stale or unknown identity | 4, retain; no code 3 inference |

`Processes.collect()` uses one bounded `ps` on Linux/macOS; argv comes from the
existing kernel reader. `fleet_native_proc.process(pid, ps_row=(ppid, lstart))`
reuses that row but still checks kernel birth/executable and rejects a changed
parent/start. Its one-argument contract and birth format remain.
`fleet_pane_claude_pids` uses one interpreter plus that one ps, preserving BFS,
node/bun recognition, explicit fake-shell override and zombie rejection.

The isolated `fleet-pending-tool-selftest.py --cost` exercises two actual checks
20 seconds apart via a real control connection and prints raw PID/exec traces:
one control startup plus two ps, regardless of the two-window batch. The default
CLI transport instead costs two tmux + one ps per observation. Neither count
includes unrelated consumer maintenance. #4444 still owns spinner wiring and
its complete default 60-second budget. Real whole-machine idle/busy evidence and
deployment are separate. Background tools, active loops, children and all #4318
Stop/reap gates remain required; a `no_pending` result waives none of them.

### Task authority is a person's (#4896) — the hub contract

Tasks belong to their owner; a repo is only a field on one. The selection is
`fleet_settings["task-authority:owner:<owner>"]` = `{owner, mode legacy|frozen|hub,
revision, frozen_at, legacy_owners (the executions to drain), mappings}`; absent
= `legacy` at revision 0. Each person cuts over alone, and nobody else's mode,
starts or leftovers take part. The old per-repo rows (`task-authority:<repo>`,
#4885's hub default for a new repo included) are read as absent — on the live
hub both hosted repos were still legacy at revision 0, so nothing migrates.

**A new person starts on the hub** (T490): every road that puts a person on the
list for the first time — an invite, an admitted request (a trial made a member
too), an admin's add, a deploy admin's first row — goes through
`Store.AdmitHubUser`, which in the same transaction writes their row as
`{mode: hub, revision: 1}` and journals it as a `repo_authority` operation
(idem `owner:account-created`). Absence still reads `legacy`: a person already
on the list keeps no setting and is cut over by their own migration, never by
this; a newcomer who already owns a task record or any cutover blocker is left
unset too, and so is a hub with no fleet registry. Their login follows with no
hand-written conf: the first beat of a `repo_authority_v1` host pushes the
person's mode (`repo` empty when the host hosts no repo yet — the agent then
runs `fleet-hub-node.sh authority-sync` with no repo), and the sync writes
`FLEET_TASK_AUTHORITY="hub"` into that login's fleet.conf [node].

**Every gate asks whose action it is**, never which repo: a `worker_start`'s
journal by the principal's task owner (`fleet_operations.task_owner`, the node
placement's `nodeTaskOwner`, else the actor), a task's accept and start by
`t.Owner`, an issue lease by the claiming endpoint's person (written as the
lease's `account_owner`), a local start by its node's person, a hub dispatch by
the dispatcher's. `frozen` refuses every start of that person's — in any repo or
none; `hub` admits only an accepted dispatch, and only to a node that lists
`repo_authority_v1`. **Blockers are the person's own**: their local starts,
their legacy leases (`account_owner`, else one on their endpoint), their
unfinished v0 T, their unsettled worker_starts (task_owner, else the actor or
the fleet's endpoint), their accepted work (rollback). The manifest's hosts are
their own fleet rows (retired and superseded ones listed apart, as before) —
another person's host is theirs, never "foreign" — and every session on those
hosts that is not an accepted task's execution is a legacy execution, whatever
repo it works in. A task carries a `ticket_ref` only when its caller names one:
dispatch makes none up, and it must be `gh:<repo>#<N>` of the start.

The road (a node's token speaks for its login's person, a person's sign-in for
that person; only a caller who sees every owner — an admin, the operator's
door — may add `?owner=<owner>`, never a node, and each such read or change is
audited `task_authority_read|freeze|apply|rollback|stop_ack` with
fleet_id `owner:<owner>`):

| Request | Answer |
|---|---|
| `GET /v1/fleet/authority?gate=1` | the authority alone — a node's pre-start read |
| `GET /v1/fleet/authority[?repo=][&rollback=1]` | the dry-run manifest: `authority`, `nodes`, `retired_hosts`, `superseded_hosts`, `legacy_owners`, `blockers`, `starts`, `tasks` (`repo=` narrows the two lists, never the hosts or blockers); writes nothing |
| `POST /v1/fleet/authority` `{action, expected_revision, idempotency_key, worker_id?, evidence?}` | `freeze` · `stop_ack` (its node only; `evidence` is the native stop receipt) · `apply` · `rollback`: CAS on the revision, 409 + `blockers` while any remain; the same key with the same body replays the first answer, with another body 409 |
| `GET\|POST /v1/fleet/authority/start?repo=` | a node's local start, as before: `reserve` · `begin` · `observe` · `recover-observe` · `stopped` · `cancel` · `unobserved`; `GET reservation=` · `list=1` — fenced by its node's person's mode |

After a freeze / apply / rollback the hub sends `repo_authority` (`{repo, mode,
revision}` — the person's mode and revision) to each of the person's capable
hosts, once per repo that host's fleets host, and on such a host's first beat
when the person's revision is past 0; another person's hosts hear nothing.

An older node's `action: init` is refused 409 — a new repo selects nothing, and
`fleet_repo_authority.py --init-new`'s fallback gate read then writes the
person's own mode; `legacy_tickets` in a body is accepted and ignored. The old
per-repo road under `/v1/fleet/tickets` left with the hub's tickets (T477). The
node half is #4901 (below): the node reads and writes only this road.

### A person's authority cutover (#4395, per person since #4896 / #4901)

Who runs tasks is a **person's**, never a repo's: the hub keeps one row per
person (`task-authority:owner:<owner>`, the section above), and each of that
person's logins holds its copy as `FLEET_TASK_AUTHORITY` in
`$FLEET_CONF_DIR/fleet.conf` [node] — a global-only key no fleet conf or repo
overlay can set, read only through `fleet_task_authority` (an overlay's old line
is read one version and `fleet-conf.sh migrate` comments it out, `# compat-1v`).
A repo is a field on a task: it names the worktree a local start opens, or
narrows a manifest's lists, and takes part in no fence. Every step below looks
only at the person's own hosts and executions; another person working the same
repo — on another machine or another login of this one — neither blocks it nor
hears of it (`fleet-task-authority-login-selftest.sh`, BREAK-IT
`authority-other-owner-blocks`).

**New repos select nothing.** `fleet-repo.sh add` writes no authority line and
asks the hub nothing: #4885's «a new repo starts as hub» is gone, `add
--authority` is read one version and only said, and `fleet_repo_authority.py
--init-new` answers `legacy` (both `# compat-1v`). A repo added to a person who
is already on the hub runs on the hub from its first task.

The cutover is five stages, each its own command on one of the person's logins
(`fleet-repo.sh authority [<owner/repo>] …` = `fleet_repo_authority.py`; the
repo is optional and only narrows the lists; `--session` is ignored). Every
call goes to `/v1/fleet/authority` (`fleet_hub_rest.api` routes `/authority*`
there). Save a fresh dry-run between stages; an exact retry reuses the same
operation key (`owner-<sha256(owner, action, revision)>`), so a repeated stage
replays its first answer.

1. **Dry-run** — `--dry-run > FILE` (private, never posted) writes nothing and
   prints the person's manifest: `version: 2`, `scope: owner`, `owner`, `conf`
   (this login's fleet.conf) and its digest beside the hub's revision, the
   person's registered hosts and capabilities (`retired_hosts` /
   `superseded_hosts` apart), legacy owners (expired leases included), local
   starts with phase · endpoint · worker · native, task outcomes, ticket
   references and selective mappings, and `blockers`. Every blocker is the
   person's own: a local start on their endpoint, a legacy lease, an unfinished
   v0 T, an unsettled worker_start, a session on their hosts that is not an
   accepted task's execution. An unsettled worker_start the hub can check (its
   issue, or the window `fid:` its node named) settles on its own once the
   hub's books show the worker never appeared (#4932); one that names no worker
   — a no-repo start whose node named no window — is the person's to vouch for:
   an admin runs `fleet hub settle-start <operation_id> --reason <why>`
   (`POST /v1/fleet/operation_settle`, past 24 h, unknown / running only), it
   ends `failed` (`SETTLED_BY_OPERATOR`, the prior status and result kept) and
   fleet_audit records who and why (#4945).
   `--freeze | --apply | --rollback --manifest FILE`
   refuse a manifest that is not `version: 2` for this login's `conf` — an
   older per-repo one, another login's — or whose local settings changed since.
2. **Freeze** — `--freeze --manifest FILE` (CAS on the revision; the hub
   commits first, then this login's [node] line becomes `frozen`). Every one of
   the person's hosts must advertise `repo_authority_v1` and `launch_v1`; an
   unknown or offline host of theirs refuses. Freeze blocks the person's new
   accepted and legacy dispatch in every repo, lease-free scratches included;
   a legacy execution with no saved native identity refuses the freeze before
   any write — drain it on the legacy path first, then retry.
3. **Drain** — stop the person's legacy executions through the existing stop
   workflow (a session writes its handoff first; nothing here stops or adopts a
   live owner by itself). On the node that ran it, `--stop-receipt RECEIPT
   --manifest FILE` acknowledges one: the saved native receipt (worker, native
   session, PID, birth, executable) must match the identity journalled for that
   frozen owner, and the process must be gone (ESRCH, or a positively different
   identity; a permission or probe failure is unknown). `--settle [--apply]`
   (issue #4832, dry by default; no repo = every repo this login hosts) settles
   this node's own retained starts in bulk: cancels a `reserved`, marks
   `unobserved` a nativeless `starting` no live window or process holds, sends
   `stopped` for an `observed` whose native is proven gone, and counts the rest
   (alive, held, moved in the last 10 minutes, unknown) by why — one line each
   in `logs/authority.log`, no credential. `--cancel-start RESERVATION` revokes
   one never-begun reservation; a started or unobserved execution stays a
   blocker. A captured legacy owner stays one after its lease expires or it
   leaves the inventory: missing observation is not an acknowledgement.
4. **Apply** — a fresh dry-run with `blockers: []` and fresh post-freeze
   observations of every one of the person's hosts, then `--apply --manifest
   FILE`: the hub selects `hub` (409 + `blockers` while any remain) and this
   login's line becomes `hub`. From then on the person's starts need an
   accepted dispatch on a capable node; a local start reads the gate and fails
   closed on an authority outage. `FLEET_TICKETS`, `FLEET_FORGE` and
   `FLEET_LAND` stay per repo, byte for byte; existing ticket integers keep
   their pinned backend.
5. **Rollback** — freeze, fresh dry-run, `--rollback --manifest FILE`. Accepted
   work must have a terminal outcome and no retained execution lease before the
   person's starts return to legacy. Task history and ticket mappings stay; hub
   results are never mirrored to GitHub, and no database is rolled back.

**The person's other logins follow** (#4730): after each freeze / apply /
rollback the hub sends `repo_authority` (the person's mode and revision) to
each of the person's capable hosts, once per repo that host hosts, and on such a
host's first beat when the revision is past 0; the node runs `fleet-hub-node.sh
authority-sync owner/repo` → `fleet_repo_authority.py --sync`, which reads the
mode back with its own credential and rewrites only its login's [node] line. An
unknown answer leaves the line; `legacy` with no line stays byte for byte; a
failed read retries on the next beat. Another person's hosts hear nothing, and
a second login of the same machine that is another person's is untouched.

Inside one stage the local gate reserves a start in the existing operation
journal before any window is made; freeze, admission and cancellation serialize
on the person's authority (the hub) and this login's `fleet.conf.authority.lock`.
A paused launcher, an empty inventory or an elapsed lease never erases a
reservation. The session wrapper consumes each reservation once; resumes and
transfers through it need a new admission, its native startup hook binds the
process and its native wait records the stop.

Selective backlog adoption is `--adopt gh:owner/repo#N --title TEXT --manifest
FILE` (`--body-file FILE` optional): a new hub ticket that keeps the exact old
reference/URL in one transaction, the mapping kept on the person's authority —
no GitHub write, no whole-backlog import. The returned `hub:owner/repo#M` can be
passed as `ticket_ref` on an accepted `worker_start`; brief, comment, evidence
and cleanup reads use it even when the repo's pinned default is GitHub and the
number collides. The manifest projects a later confirmed `task_report` with
`status=merged` and `pr_state=merged` independently of the work outcome;
waiting or an old generation cannot turn that into a confirmed landing.
Explicit completion with a PR records `work_result` and `pr_state: waiting`
apart; only the existing merge verdict permits `pr_state: merged`. Fixture
tests do not establish deployment or live acceptance.

### Retiring the compatibility window (#4398)

The window closed on 2026-10-18. The 7-day wait was waived by the operator,
and three gates were met: a compatible released version, C9 live rows, and a
fresh dry-run showing `legacy_owners=[]`, `blockers=[]`. Since #4896 / #4901
that dry-run is the **person's** (`fleet-repo.sh authority --dry-run` on one of
their logins), never a repo's. Inventory of the C1–C7 branches: old peers are
kept out at the gate, not translated. That gate is:

- `launch_v1` for any accepted launch;
- `repo_authority_v1` for a hub-mode `worker_start`;
- cutover blockers for any of the person's non-capable hosts or live legacy
  owners;
- refusal of a downlevel report or legacy POST on a version-1 task.

The gate stays.

The legacy-mode path stays byte for byte: legacy relays, the version-0 record,
the issue lease, label resolution at a first dispatch, and `gh:` ticket refs.
A person who has not cut over still runs on it, in every repo.

The one superseded branch was the issue-number wait: a login whose person is
on the hub (`fleet_task_authority` = `hub`) refuses a by-number spawn. (Its other
half — a window carrying `@launch` waited on as its `T<n>` — left with the launch
proof, EPIC T497 C8.)

Before deleting more, confirm per person with `fleet-repo.sh authority
--dry-run`: hub mode with zero legacy owners. A person still in `legacy` keeps
every legacy reader. Rolling a person back is stage 5 above, unchanged. Rolling
back this code is a revert of its PR; no schema or stored row changed.

## Identity — the worker credential (issue #1809, EPIC #1813 C7)

Every session the fleet opens carries its own short-lived credential, and every
tool call is made **as that session**: no more working out who is calling from
the window's options, which drift when a window moves or a pane is not the one
the session lives in.

**Issued** by `bin/fleet-session-wrap.sh` — the one door every session opens
through (spawn, restore, migrate, move, transfer, a wake) — once
per launch: `fleet-mcp.py --cred mint` prints it to the wrapper, which exports it
as **`FLEET_WORKER_CRED`** for that launch only; the agent hands it to this server
(Claude: inherited; Codex: `env_vars` forwards the NAME). It is never in an argv,
a file, a config, a log, a comment or a tmux option (`fleet-mcp-selftest.sh` J
greps for it). **Revoked** when the agent exits (`--cred revoke` puts its nonce on
the revoked list). A migrated or moved session is launched again on its new
window and so gets a fresh credential for the **same** `worker_id` — and an older
one still holds there, since it names the session, not the pane.

**Format** — `fwc1.<base64url claims>.<base64url HMAC-SHA256>`, signed with this
login's key `$FLEET_CONF_DIR/worker-cred/key` (0600, made on first mint). Claims:

| claim | what |
|---|---|
| `v` | 1 |
| `fleet` | the fleet (its socket label — the same for a view session) |
| `fid` | the session's lifelong `@fleet_id` — its IDENTITY (#1646) |
| `fleet_uuid` | the fleet UUID (`fleet_uuid`), empty on a machine with none |
| `key` · `repo` · `issue` · `origin` | what the session was at issue time (informative; a scratch bound later keeps its `fid`) |
| `iat` · `exp` | issued · expires: **24 h**, renewed hourly in the server's memory while it holds (decision 7) |
| `nonce` | what the revoked list (`$FLEET_CONF_DIR/worker-cred/revoked`, nonces only) names |

`worker_id` = `<fleet_uuid>/<fid>` (`fid` alone without a fleet UUID) — the same
string `fleet_worker_id` prints.

**Checked on every call, before the arguments** — a credential that is present
and does not hold refuses the call (`isError`, `… Nothing ran.`), read-only tools
included:

| refused when | text |
|---|---|
| malformed / not this login's key / tampered | `credential is malformed` · `signature does not verify` |
| past `exp` | `credential expired` |
| its nonce is revoked | `credential was revoked (its session exited)` |
| called from another fleet | `credential is for fleet X, this pane is in Y` |
| called from a pane whose window is not the credential's session | `this pane's window (…) is not the credential's session (…)` |

**Scope** — what a holder may do, given the pane IS its session:

| tool | scope |
|---|---|
| `status` `children` `repos` `agents` | read: this session's view |
| `spawn` `await` | only as **itself** the parent — the script stamps the child's `@origin` from this pane, and the pane is pinned to the credential's session |
| `send` | only within **this fleet**: local keys (`issue:<N>` / `scratch-<N>` / `parent`), never a `wid:` address |
| `report` `ask` `handoff` | only **itself** — `fleet-report-parent.sh` reports the calling pane, pinned the same way |

**No credential** (a person in a shell, a session launched before this, `FLEET_MCP=0`):
the call runs as before, by the window's options — and is logged `via=marker`.

**The call log** — `$FLEET_CONF_DIR/logs/mcp-calls.log` (`FLEET_MCP_LOG`), one line per
call, never the credential:

```
2026-10-06T12:00:00-0700 tool=spawn via=cred who=<fleet uuid>/<fleet_id> verdict=exit=0
2026-10-06T12:00:05-0700 tool=spawn via=badcred who=<the window's @fleet_id> verdict=refused why="this pane's window … is not the credential's session …"
2026-10-06T12:01:00-0700 tool=status via=marker who=<@fleet_id or window name> verdict=ok
```

`via=cred` ÷ all is the EPIC's 「工具调用里认得出是哪个执行会话的」.
`fleet-mcp.py --cred check` prints the verified claims of `$FLEET_WORKER_CRED`. `--cred assert` prints
the session's OWN worker assertion (the hub on, the credential holding) — what
`bin/fleet-session-cred.sh` hands `POST /v1/fleet/session-cred` to borrow a session
pass on an untrusted machine (claude-fleet#1972).

What it is not: the key and the session share a uid, so a session that wants to
can read the key — this is an identity rail against a moved window or a borrowed
pane, not a wall against a hostile session. The hub checks again (C8, below).

## The hub route — a worker assertion (issue #1810, EPIC #1813 C8)

Whether a call goes through the hub is the **node's** configuration, never the
session's: the tools look the same either way (EPIC #1813 rule 2). When this
fleet runs with the hub (`fleet_hub_on` — the fleet conf's / environment's
`CCQUOTA_FLEET=1`) **and** the node has its token (`$CCQUOTA_TOKEN`, else
`node.env`), the three tools whose script may act on another machine hand that
script a **worker assertion** — who the call is for, signed by the node — in
**`$FLEET_WORKER_ASSERT`**, the environment only:

| tool | how it reaches the hub | lifetime |
|---|---|---|
| `spawn` · `await` | `dash-issue-session.sh` → `fleet_hub_place` → `ccquota place`, header `X-Fleet-Worker` on `POST /v1/node/place` | 10 min |
| `send` | `fleet-peer-send.sh` → `fleet_hub_put` → the relay's `worker` field (outbox → agent → hub) | 24 h — a relay may wait in the outbox while the hub is away |

**Only a call whose credential held** gets one (C7): no credential, a hub that is
off, no node token, no fleet UUID → nothing is minted and nothing about the hub is
read. **With no hub configured not one network request is made** — not by the
server, not by anything it runs on its behalf (`fleet-mcp-selftest.sh` K traps
every socket). A cross-machine call through a hub that cannot be reached fails in
its script as it always has; everything local runs unchanged.

**Format** — `fwa1.<base64url claims>.<base64url HMAC-SHA256>`, keyed with
`HashToken(node token)` (SHA-256 hex): the hub already stores exactly that, so it
verifies without a new secret, and nothing but the node holding the token (or the
hub) can sign. Claims: `v` 1 · `worker_id` (`<fleet UUID>/<fid>`) · `fleet_uuid` ·
`fid` · `key` (the session's key **now** — a relay's `from` names it by that) ·
`repo` · `issue` · `origin` · `node` (this host's short name) · `iat` · `exp`.

**The hub** (`tokenledger/hub/api/fleet_worker_assert.go`) adds a caller
kind, the 执行会话 — a node's call made for one of its sessions:

| the assertion | answer |
|---|---|
| absent | the node's own call, byte for byte as before |
| not signed with this node's token hash · tampered · expired · `exp-iat` over 24 h · malformed | **401** `UNAUTHENTICATED` (a relay: refused) — never read as "no assertion" |
| a session of a fleet this node does not run · a start whose `origin_wid` is not that session (by fid or key) · a relay whose `from` is not that session | **404** `NOT_FOUND` — a session acts only as itself: what it opens is its own child |
| holds | the call runs; a start with no `origin_wid` gets the session's |

Every such call — refused ones too — writes `worker_id` and `worker_key` beside
the node's `actor` in **`fleet_audit`**, and a placed start's journal row
(`fleet_operations.worker_id`) names the session. So the audit line for
「执行会话 issue-N @ mac-b → 在 mac-a 上开会话」 reads
`actor=node:<login>@mac-b worker_key=issue-N action=place outcome=REMOTE mac-a done`.
The envelope sent to the target node is unchanged (its `fields()` check is
strict). The call log marks a call that handed one out with ` hub=asserted`.

Needs, to take effect: the hub deployed with this change, and on each node a
`ccquota` (place) and agent (relay) built from it. An older `ccquota` / agent
drops the assertion — the node's own call, exactly as before.

## The old road — closed (issue #1812, EPIC #1813 C10)

A **worker** seat reaches the fleet through these tools, not by running the
script a tool wraps. `hooks/bash-guard.py` holds ONE table (`_DIRECT_TOOLS`,
script → tool) and judges two roads with it: a Bash statement whose **command**
is one of the scripts below (the live install's copy or a bare name — a `grep`
of it, or a worktree's own `bin/` under test, is not a call), and a call to one
of the mod's old tools by its MCP name (`mcp__fleet__fleet_status|spawn|await`
→ `status` / `spawn` / `await`; `hooks/settings-hooks.json` routes those names to
the guard, Codex never had them) — in a session that HAS the service
(`FLEET_MCP_SERVER=1`). In a session with none (launched before #1828) those three
are the mod's fallback and its only road (issue #2057, «How a session gets it»):
logged `fallback`, never blocked, whatever the mode.

**The fallback is kept by a gate, not by memory** (issue #2075, EPIC #2074 C2):
before `fleet-stable.sh move`, `bin/fleet-oldcfg-replay.py` replays what a session
of the current stable registered — every mod tool of its `tools.ts` through the new
`tools.ts`'s `TOOL_RE` and `fleet-mcp.py --call`, every tool its `fleet` server
listed against the new server's `tools/list`, every hook command of its table —
and a tool with no handler refuses the move (`oldcfg:`). #2068's rules say what a
handler is: forward it, or answer how to reopen (CONTRIBUTING «老会话兼容»).

**And after the move, the sessions it would still break are named** (issue #2076,
EPIC #2074 C3): every launch writes its start down — the hook table it was handed,
the mod tools it registered (the `FALLBACK` list), its MCP servers — as
`$FLEET_CONF_DIR/agentcfg/<sha>.json` (`@agent_cfg_manifest`), and
`bin/fleet-oldcfg-check.sh` judges it against the live install with the gate's own
functions (`fleet-oldcfg-replay.py --manifest`, static): a tool with no handler in
the new `TOOL_RE`, a hook script gone, an MCP script gone ⇒ `broken`, the sidebar's
red 会坏·需重开; anything merely new ⇒ `stale`, the yellow 配置旧 as before. The
collector sweeps it every tick, `fleet-install-apply.sh`'s `oldcfg:` step names the
broken and the looping stale sessions right after a move, and nothing reopens them
for you (#2068 B).

| script | tool |
|---|---|
| `fleet-children.sh` · `fleet-repo.sh list` | `children` · `repos` |
| `dash-issue-session.sh` · `fleet-await.sh` · `fleet-peer-send.sh` | `spawn` · `await` · `send` |
| `fleet-report-parent.sh` · `set-claude-state.sh blocked` | `report` · `ask` |
| `fleet-handoff-file.sh` | `handoff` |
| `fleet-pr-verdict.sh` · `fleet-pr-merge.sh` | `pr_verdict` · `pr_merge` |
| `fleet-brief.sh` | `brief` |
| `fleet-dialog-answer.sh` | `answer_dialog` |
| `fleet-clear-send.sh` | `clear` |
| `fleet-task-record.sh dispatch` | `task` |

`FLEET_DIRECT_SCRIPTS` (env, or `fleet.conf`) picks what happens:

- `log` (the default — the week of record): allowed, one line appended to
  `logs/mcp-bypass.log`: `<UTC>\tlogged\tissue=<N>\tscript=<s>\ttool=<t>` — never
  the command line (a comment body is not a log's business);
- `block` (after the week, once the log reads clean): refused, exit 2, naming the
  tool to call; logged `blocked`;
- `off`: neither.

`FLEET_ALLOW_DIRECT_SCRIPTS=1` (env or inline) is the escape hatch: allowed and
logged `hatch`. Only `fleet_seat` = `worker` counts: the operator's hub
(`FLEET_HUB=1`), a scratch draft and a person's own shell are never logged or
blocked, and a guard that cannot read the seat lets the call through. The
week's count is `grep -c $'\tlogged\t' logs/mcp-bypass.log`.

## A new version, taken between calls (issue #1898, EPIC #1906 C5)

The install is a link to one version (`~/.claude/fleet → fleet.versions/<sha>/`,
#1894). Before each request, and every `FLEET_MCP_RELOAD_POLL_S` (30 s) while the
client is quiet, the server compares the file it was launched as (the link path,
never resolved) with the one it runs — another real path, inode, size or mtime is a
new version. Requests are served one at a time, so a call in flight always finishes
on the old code first. The new file must answer `fleet-mcp.py --probe` (its tool
names, exit 0); then the server `os.execv`s it: same pid, same stdin/stdout, so the
MCP connection never drops, and the credential rides in the environment as it is
(renewed in place). Request bytes already read but not served pass to the new
process through a 0600 carry file it deletes at once. The new process sends
`notifications/tools/list_changed`.

| Client | On `list_changed` | So a running session… |
|---|---|---|
| Claude Code (2.1.292, tested) | re-lists at once — **only** when `initialize` declared `tools.listChanged` (it does since #1898) | gets the new tools on its next turn; a session that met an older server keeps its list until reopened |
| Codex (0.160, `codex-rs/rmcp-client`) | logs it, keeps its first list | keeps its tool list; the exec still moves its tools' scripts onto the new version. New tools reach it through the C4 notice + C3 idle reopen |

A version that fails its probe is refused (`tool=(reload) verdict=refused` in
`logs/mcp-calls.log`) and the running one keeps serving; each exec logs
`verdict=exec` and `verdict=resumed` under the one pid. `FLEET_MCP_RELOAD=0` turns
it off. The legacy `fleet-peer` shim never reloads.

## Retired tools (issue #4904)

`whats_new` and the debugger's `debug_bundle` · `debug_publish` · `debug_propose`
are gone with their scripts. A session launched before still has them in its
list, so the server keeps answering them for one version — never listed, every
call refused with the reason (`RETIRED` in `fleet-mcp.py`), and `--probe` names
them so the release gate's replay counts them as handled.

The same holds for `comment` · `evidence` · `file_issue` · `gh` (issue #4898): the
GitHub issue layer — claim, comment, evidence, filing, the ticket cache — left with
EPIC #4895 批 1; the hub task record `T<n>` is the only ticket. Each answers
`removed (claude-fleet#4898): …` naming the road that replaced it.

## Protocol

Newline-delimited JSON-RPC 2.0 on stdin/stdout, stdlib only (macOS python 3.9):
`initialize` (echoes the client's `protocolVersion`, declares `tools.listChanged`),
`tools/list`, `tools/call`, `ping`; notifications get no answer. The server sends
one notification of its own: `notifications/tools/list_changed`, after a reload.

## Tests

`bin/fleet-mcp-selftest.sh` — the list, every refusal (nothing ran), each tool once
against fake scripts, no-hub degenerate, the legacy shim, the Codex mount; for 报问记合
(G–I) every new tool's refusals, its exact argv + stdin, and script ≡ tool through the
REAL `fleet-report-parent.sh --dry-run` (the same envelope, on an isolated tmux server); L the C9 tools the same way,
and `handoff arm` answering before its detached helper ends.
`bin/skill-tools-selftest.sh` — no worker-run skill step names a `~/.claude/fleet/bin`
script, and every `mcp__fleet__<tool>` / `mcp__fleet-orch__<tool>` a skill names is a
tool THAT server lists.
`bin/fleet-mcp-selftest.sh` Q — the two groups: `fleet-orch` lists the dispatch group,
`fleet` answers it `road=legacy`, a pre-group takeover keeps all 21,
spawn follows the group, one server definition for Codex and the plugin.
`bin/fleet-mcp-selftest.sh` J — the credential: valid / expired / forged /
tampered / another pane / another fleet / revoked, migration, renewal, no leak.
`bin/fleet-mcp-selftest.sh` M — a new version between calls: the in-flight call
finishes on the old code, exec keeps pid + connection + credential, `list_changed`,
the new tool listed, a broken version refused, the quiet poll, `FLEET_MCP_RELOAD=0`.
`bin/fleet-mcp-selftest.sh` K — the hub route: assertion only with hub + token +
credential, its signature and claims, zero network with no hub, `fleet_hub_put`'s
`worker`. Hub: `TestWorkerAssertion*` (`hub/api/fleet_worker_assert_test.go`)
— valid → placed + audited + journalled, forged → 401, out of scope → 404, the
relay; `TestPlaceCarriesWorkerAssertion` (`agent/cli`).
`bin/session-wrap-selftest.sh` B' — the wrapper mints per launch and revokes on exit.
`bin/fleet-claude-selftest.sh` #1807 and `bin/fleet-codex-selftest.sh` I — the
launch command lines carry the server. `mod/fleet/tests/lifecycle.test.ts`
«fallback tools» + `tests/tools.test.ts` + `bin/fleet-mod-selftest.sh` E — with the
service the mod registers no tool; without it the three, from `--spec`, every call
forwarded to `--call`, no schema / check / script of its own, the retreat message
when the forward cannot run (issue #2057). `bin/fleet-mcp-selftest.sh` N — `--spec`
is the `tools/list` entry byte for byte; `--call` runs the same argv, prints the
same text, exit 0 / 1 / 2, logs `road=call`.
`bin/fleet-oldcfg-replay-selftest.sh` — the release gate (issue #2075): a deleted
hook script, a dropped `TOOL_RE` handler, a tool gone from the server, a hook
erroring or hanging — each red and named, restored green, old == new green at
once; J replays this repo's own table against its live tree. `fleet-stable-selftest.sh`
I — the refusal (`oldcfg:`, tag untouched, `--dry-run` too) and `--force` + its log
line; `fleet-break-it-selftest.sh` `oldcfg-deleted-hook` does it through the real
`move` on a rig repo.
`bin/fleet-oldcfg-check-selftest.sh` — the per-session half (issue #2076): a launch
writes its manifest (Claude with the mod's tools, Codex without), a manifest naming a
dropped tool / a deleted hook script / a gone MCP script is `broken` and names it, one
that only lacks a new hook is `stale`, a missing manifest is `stale` with a note; the
sweep on an isolated socket writes exactly the broken windows, `fleet_cfg_state` reads
`broken` for them, the rows producer's field 13 and the sidebar's word follow, the
cfg-restart counts and the idle reopen include them; `fleet-break-it-selftest.sh`
`oldcfg-broken-unmarked` is the drill.
`bin/bash-guard-selftest.sh` «direct-script rail» — the old road (above): a worker
seat logged / blocked, the operator seat and the hatch passing, the MCP road with
the service, the fallback without it (logged `fallback`, never blocked).
