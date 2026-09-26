# Worker hibernation

Fleet can retain a worker's window and worktree while its coding agent exits.
Going to the window shows a sleeping page; pressing its Wake button twice resumes
the exact native conversation, with no new prompt.
The dashboard and tmux tabs show `z` while sleeping, `↻` during a transition,
and `!` if recovery needs attention. The task's `done/working/needs` state remains
separate from the process lifecycle.

## Controls

`FLEET_SLEEP=observe` is the initial default: scan and report reasons without
exiting agents. Set `FLEET_SLEEP=on` in the global or per-fleet configuration to
enable automatic sleep. `off` disables scans. `FLEET_SLEEP_AFTER=1800` sets the
continuous idle interval in seconds. Codex uses its native completed-turn time,
including for workers already idle at installation. After resume, the interval
starts no earlier than the wake time; no extra conversation turn is required.
Claude still requires a matching Stop event. Resume never manufactures one.
While enabled, sleep supersedes the older idle scratch-window disposal policy.

From another window or terminal:

```sh
bash ~/.claude/fleet/bin/fleet-sleep.sh status fleet-name
bash ~/.claude/fleet/bin/fleet-sleep.sh scan fleet-name --dry-run
bash ~/.claude/fleet/bin/fleet-sleep.sh sleep fleet-name @123
bash ~/.claude/fleet/bin/fleet-sleep.sh wake fleet-name @123
bash ~/.claude/fleet/bin/fleet-sleep.sh keep-awake fleet-name @123
bash ~/.claude/fleet/bin/fleet-sleep.sh allow-sleep fleet-name @123
```

The same three are taps in the session list (issue #1051): a sleeping row reads
`z <age>` (`z 42m`, `z 3h`, `z 2d` — from the window option `@sleep_since`,
epoch seconds, which `phase()` stamps on entering `sleeping` and clears on any
other phase), and the sidebar's row menu (`.`) carries **唤醒** (`w`, only on a
sleeping row; runs `wake` detached, at once) and a **保持唤醒 / 允许休眠** toggle
(`k`, the label follows `@sleep_keep_awake`).

Manual sleep bypasses only the idle duration, never safety checks. A client
viewing the window prevents sleep, even if it has not typed recently.

### Waking it yourself (issue #1050)

By default (`FLEET_SLEEP_WAKE=confirm`) nothing about *looking* at a sleeper
wakes it: tmux navigation, sidebar selection, client attach, the scan finding it
on screen, or entering it while it is going to sleep only show its page. It wakes
when you press the page's one button, **Wake**, twice: the first ⏎ (or a tap on
the button's row) arms it — amber, `⏎ again to wake · 3…` counting down — and a
second one at least 0.3 s later and within `FLEET_SLEEP_WAKE_ARM` seconds
(default 3) draws `↻ waking…` and starts the wake. Past the window the arm lapses
silently and the next press arms again. The sidebar row menu's Wake wakes at
once (opening the menu and picking it is already two steps).

While armed, one line above the button says what the wake will cost (issue
#1053): `resumes claude + 2 tools (~5s)`. That covers the agent and the MCP servers
the contract lets it restart (`source.sleep_mcp`), and the median `wake_seconds`
of this worker's earlier naps. The worker is matched by worktree; with no naps of
its own, the median across the fleet's sleep records is used. With no recorded wake
anywhere, the line is left off. The records are read once, at the first arm.

The page owns the pane's input while it sleeps: every other key, and any click
outside the button, is read and discarded, so nothing typed there reaches the
resumed agent. It turns on SGR mouse reporting for the tap and turns it off
before the wake respawns the pane. The wake runs detached (`tmux run-shell -b …
fleet-sleep.sh wake`), because the respawn kills the page's own process.

`FLEET_SLEEP_WAKE=dwell` restores the old wake-on-arrival: the navigation and
attach hooks (`wake --dwell 2 --nav`) wake a sleeper once its window has stayed
current for two seconds (a window only passed over — the sidebar's ↑↓ follow,
`prefix n` past a sleeper — is not resumed), and the scan wakes any sleeper a
client is viewing. `--nav` is a no-op under `confirm`; the CLI's `wake` and
`wake --dwell` are unaffected by the knob. Automatic wakes — a due loop, a
quota-waiting loop finding an account, an incoming message — are unchanged in
both modes. Highlighting a dashboard row never wakes. During resume, wait for the native input
prompt before typing. No wake action authorizes an additional model turn. Codex resumes its saved native
permission profile. Its existing hook authorization is carried as exact native
hashes in temporary launch arguments; user trust configuration is not modified.
Changed hooks may still require review. Startup update checks are suppressed for
the resume invocation so a version notification cannot block entry; fresh launches
keep their normal update policy. Both standalone and npm-installed Codex are
supported.

### Sleepers and the session limit (issue #1058)

A sleeping worker has no live agent, so it holds no session slot. Both caps —
`FLEET_GLOBAL_MAX_SESSIONS` and the per-fleet `FLEET_MAX_SESSIONS` — count a
window only when it is not a panel and its `@worker_lifecycle` is neither
`sleeping` nor `failed`; `preparing` and `waking` still count. The slots chip
shows sleepers apart (`slots 12/30 · z8`), and a spawn refused at the limit says
how many are asleep. A fleet with no sleepers counts exactly as before.

Waking puts a worker back into the count, so each wake source decides what a
full fleet means for it:

| Wake source | At the limit |
|---|---|
| The page's double press, the sidebar menu's Wake (`wake --over-cap`) | wakes anyway, one over; while armed the page reads `fleet full 30/30 — waking makes 31` |
| An incoming message (`deliver`) | defers — the message is saved first; the scan's drain delivers it once a slot frees |
| A due loop, a quota-waiting loop finding an account | defers — retried on the next 60 s scan; runs late, never twice |
| A bare `fleet-sleep.sh wake` | refuses with `fleet full N/M — pass --over-cap to wake anyway` |
| Spawns | unchanged — refused at the limit, counting awake workers only |

A deferred wake stamps `@sleep_wake_deferred=cap`; its row reads
`z · waiting for a slot` until the wake runs (or nothing is waiting any more).
The check and the `waking` stamp are one step under a lock, so a burst of due
loops cannot push the awake count past the limit.

## Evidence and exclusions

A real Stop hook binds idle evidence to the native session, owning process and
pane. Tool use and submitted prompts invalidate it. Codex can also supply idle
evidence through its exact private endpoint: matching UUID, worktree and history,
an idle thread, a completed turn with a valid completion timestamp and no active
tool items. Display classification and stale-working demotion cannot create this
evidence.

Claude requires empty `background_tasks` and `session_crons` arrays and a known
permission mode. Missing arrays mean unknown and prevent sleep. Codex additionally
requires its exact private app-server thread to be idle with a completed turn.
Owned tool processes, pending interactions, unresolved loop deliveries, transfers, failover,
an unsubmitted draft or an unrecognized input layout prevent sleep. Unknown
probes always keep the worker running. Worktree modifications are preserved and
are not a reason to delete or commit anything.

A verified proactive quota-switch request that is only waiting does not prevent
sleep. The sleep operation holds the quota reconciler's lock through exit; quota
reconciliation skips retained workers and rechecks their identity after wake.
Successful native resume clears the retired process's quota marker before the
new owner is reconciled. An aborted sleep that leaves the original process alive
keeps its marker.
Hard quota failures, cutovers in progress and ambiguous deliveries still prevent
sleep. A text status flag alone cannot authorize this exception.

A waiting text marker whose exact request has disappeared can be treated as
orphaned only while holding the quota lock and after checking every request for
that window or native session. Any nonterminal/ambiguous request still vetoes
sleep. Native completion, input, process and history checks remain mandatory;
dry-run does not clear the marker. Successful exact resume retires it.

Codex's persistent `codex-code-mode-host` is allowed only as a direct child of
this worker's exact app-server, with its kernel executable path matching the
server's bundled release. Children of that host still undergo tool-process checks.
The empty Codex composer can be recognized beneath its colored dot animation
only with the native faint placeholder and cursor at the start. Real drafts,
attachments and unrecognized layouts still prevent sleep.

## Loops and restartable tool services

An exact `active` or `waiting-quota` Fleet loop can now hibernate. Fleet saves
its ownership generation, schedule and delivery counters before exit, marks the
loop `hibernating`, and rebinds it to the same native conversation after wake.
Failed exit restores the original loop. A changed owner, explicit stop, changed
schedule or uncertain delivery is never silently revived. Loops due within the
next scan interval remain awake.

The existing sleep scan wakes an active loop when its saved deadline arrives.
A quota-waiting loop wakes only when fresh account policy reports a usable
subscription (its own, or a failover target when failover is enabled). User entry
and incoming messages can still wake it immediately. Native resume submits no
turn; the existing quota tick resumes dispatch after exact rebind, preserving
the one-delivery/no-catch-up rule. There is no additional scheduler process.

MCP presence alone is not evidence of an active tool call. Set
`FLEET_SLEEP_MCP_RESTARTABLE` to comma-separated **native MCP server names** whose
volatile service state may be discarded, for example after verifying that a
particular deployment of `mcp-image` is stateless:

```sh
FLEET_SLEEP_MCP_RESTARTABLE=mcp-image
```

The default is empty. This is an explicit restartability contract, not a global
process-name allowlist. Fleet matches the live server's effective configuration
to exact stdio launcher argv and kernel executable paths. Supported npm/uv
entrypoint wrappers are checked separately; additional jobs/browser descendants
still prevent sleep. Native threads must be idle with no active tool items.
Only config digests and service names are retained, never MCP credentials.
After resume, the same configuration and initialized service inventory must be
available before the worker is declared awake. A changed configuration leaves
a reviewable failed recovery; a slow service can finish on a later scan.

The contract covers both agents, with a different inventory behind the same
matcher (issue #784). Codex reports its effective config and per-server runtime
status over the app-server RPC. Claude has no such channel — `claude mcp list`
starts every approved server to health-check it, so a daemon cannot ask — and
Fleet rebuilds the effective set the way the CLI resolves it: the `--mcp-config`
documents on the live process's argv (the whole set under `--strict-mcp-config`,
which is how every fleet spawn passes `FLEET_MCP_CONFIG`), else those over the
CLI's own store — local scope (`projects[<worktree>].mcpServers` in
`.claude.json` under the worker's `CLAUDE_CONFIG_DIR`), the approved project
`.mcp.json` (`enabledMcpjsonServers`), then user scope — plus the servers the
enabled plugins ship, under the CLI's own names, `plugin:<plugin>:<server>`
(issue #830: `enabledPlugins` in the settings files, the install root from
`plugins/installed_plugins.json`, its `.mcp.json` or `plugin.json`, with
`${CLAUDE_PLUGIN_ROOT}` substituted). A contract that wants one lists that full
name, e.g. `plugin:playwright:playwright`; a plugin that cannot be resolved
contributes nothing, so its server vetoes as an unverified process. A server
approved only through a settings file is still not inventoried, and the skip
reason names the process. **Claude readiness is process-fingerprint plus config digest only**:
the worker is declared awake once every saved server runs again as a direct
child from an unchanged configuration, which does not prove the server finished
initializing — the first tool call after a wake can still meet a server that is
starting. Codex additionally waits for its native `ready` status.

Do not list a stateful browser or REPL merely because it currently uses little
CPU. Native conversation resume preserves history, not process memory. Legacy
workers without a bound native identity or private endpoint remain awake with
an explicit diagnostic; Fleet does not guess their account/session or restart
them to manufacture evidence.

## Retained state and recovery

Private records live at `fleets/<session>/sleep/` below `FLEET_CONF_DIR`. They
contain the exact source session, transcript, account home, worktree, native
permission mode, restart options and a last-screen preview. Files are written atomically with
mode 0600. Treat these records as sensitive conversation data.

A per-worker kernel lock serializes sleep, wake and message delivery; the
worktree transition lock also excludes migration. A saved record precedes exit.
Only a confirmed exited process and a dead pane or childless shell can be
replaced. The exit check compares the saved start-time fingerprint and reads the
process state: an exited agent that tmux has not reaped yet is a zombie, which
Linux `ps` prints with the same start time and command as the live process
(tmux 3.4 on the Ubuntu CI runners can lose the SIGCHLD that reaps it, leaving
`pane_dead` set with the process still listed). A timeout does not kill an
agent. The retained-exit check prevents the ordinary SessionEnd cleanup from
closing the task. Automatic cleanup and screen classification recognize retained
workers.

Messages are persisted before waking and sent to the exact resumed agent's
native inbox. Failed delivery is not reported as success. A delivery timeout is
recorded as uncertain and is not blindly replayed. These native transports
confirm acceptance, not completion of the requested work.

The sleep daemon runs one bounded scan per minute. It also reconciles interrupted
transitions. Crash snapshots retain the sleep record; restoring a fleet recreates
the placeholder rather than starting every sleeping agent. A missing worktree,
transcript or account leaves an actionable failure; it never silently starts a
new conversation.

### The sleeping page

The placeholder process (`fleet-sleep.py park`) draws a card sized to the
current pane, not the screen captured at sleep time (issue #1049). It answers
the two questions a person asks of a sleeping worker — what got done, and what
happens next — in plain words (issue #1237):

```
Sleeping · 只留微信登录                         2h 32m
⚠ 有改动还没保存到 GitHub，唤醒后会继续
──────────
DONE
✓ 用户可以用微信扫码登录，也能在微信里直接登录
✓ 旧的登录入口已去掉；改动已合并，还没上线

NEXT
等别人  还有 8 个活跃账号没绑定微信，密码登录先保留
你      全部绑定后，决定何时上线并关掉密码登录
──────────
 ⏎ Wake   press ⏎ (or tap) twice to resume
```

The first line is the state (`Sleeping`, `Waking…`, or `Wake failed`) and the
window name, with how long it has been asleep on the right. A failed wake adds
one red line with the most specific cause (what the launcher said, when it said
anything). The `⚠` line appears only when the worktree has uncommitted or
unpushed work, and names no branch. The issue number, repo, idle time, agent,
model, account, memory freed and PR state are not on the page: the sidebar row
shows the first two, and `fleet-sleep.sh status` / the record keep the rest.

**DONE / NEXT** come from a digest written once per sleep record, not on
redraw, so `render_park()` stays pure. The page launches it, detached, the
first time it draws a record that has no `digest` key: `fleet-sleep.py digest`
reads the last reply — for Claude the last `assistant` entry of its transcript,
for Codex the last assistant `message` item of its rollout (issue #1052) — and
hands it, with the PR state (`@prci` / `@reap_key`) and the automatic wakes, to
`claude -p --model haiku` (no MCP, pool-authenticated — the
`classify-sessions.sh` helper's shape). The prompt asks for plain, non-technical
language, at most three items each, and each NEXT item tagged with who acts
(`you` / `others`). The answer is stored as
`digest: {done: [...], next: [{who, text}]}` in the record, under the worker
lock, and the digest process sends the page SIGWINCH so it redraws. Sleep never
waits for it; a re-parked page (issue #1064) or a Codex worker gets the same
treatment. A model that fails, times out or answers nothing usable is recorded
as `digest: {done: [], next: [], error: …}`, so no later page retries it.

A due loop or a quota wait is always a NEXT item tagged `自动` / `Auto`, drawn
from the record rather than the model, so its time stays exact. Tags and fixed
lines follow `FLEET_UI_LANG` (`zh` → 你 / 等别人 / 自动, `en` → You / Others /
Auto), resolved the way the sidebar resolves it; the model writes in the same
language.

Without a digest (not written yet, or failed), the page shows the last reply in
plain text — links reduced to their text, `**` and backticks removed — under
the same frame. When even that can't be read, the saved screen is shown
instead, dimmed, labelled as old, and without the agent's input box and status
line. The card is redrawn on SIGWINCH and on input, and on a timer only while
the button is armed (its countdown). The renderer is `render_park()` in
`bin/fleet_sleep_park.py`, a pure function of the record, the window facts,
and the size. Callers can pass their own `footer_lines`.

| Knob | Default | Effect |
|---|---|---|
| `FLEET_SLEEP_DIGEST` | `on` | `off`: no digest; the page keeps the plain last reply |
| `FLEET_SLEEP_DIGEST_MODEL` | `haiku` | model for the helper `claude -p` |
| `FLEET_SLEEP_DIGEST_SECS` | `120` | time box for one digest |
| `FLEET_SLEEP_DIGEST_CMD` | — | a shell command that reads the prompt on stdin and prints the JSON (the selftests' fake model) |

### When a wake fails

A wake whose launcher exits before the agent is ready (a missing tool, a
setting the resume refuses) leaves the record `failed` and a dead pane. Fleet
puts the sleeping page back in that pane (issue #1054): the first line reads
`Wake failed`, then one line with the launcher's last output (or the error). The button
reads **Retry** and takes the same double press as Wake. The sleep scan also
re-parks a `failed` record left on a dead pane, for a wake that was killed
before it could.

Retry is offered only when a wake can start: the original agent has exited,
and the worktree and the saved transcript are still there. Otherwise the
page shows `can't wake from here: <reason>` and no button. Fix the cause (for
example, restore the missing transcript), then press ⏎ once; the page checks
again and the button returns. The check is repeated at the confirming press,
so a cause that appears between the two presses stops the wake before it
starts. A failed wake whose pane still runs something (the resumed agent
waiting on a dialog, say) is never replaced; answer it in the pane, or run
`fleet-sleep.sh wake <session> <window>` once it has exited.

## Rollout and validation

Run `bash bin/run-selftests.sh fleet-sleep` for the isolated tmux integration
tests. Run the complete selftest gate before release. Do not edit `bin/` while
the gate runs: the shadow root links those files.

Install `com.claude-fleet.sleep` on macOS or `claude-fleet-sleep.timer` on Linux,
following `docs/INSTALL.md`. Start with observation, review skipped candidates,
test manual sleep/wake with both native agents, and then enable automatic sleep
on each fleet. Check the actual native session ID, window identity, account,
process exit and worktree after recovery. `wake_seconds` in the durable record
measures successful resume latency; repeated trials are needed for percentiles.

### Native rollout evidence (2026-09-18)

Isolated sockets on both deployment machines were exercised with real native
agents: normal exit, retained window, exact UUID/account/worktree, navigation
wake and no extra model turn. Local Codex also passed the automatic scanner with
a short test-only threshold. Production uses 1,800 seconds.

| Host / agent | Resume sample | Agent tree RSS before → settled placeholder |
| --- | ---: | ---: |
| Local Codex 0.155.0 | 4.3 s | 392 MiB → 31 MiB |
| mini Claude 2.1.276 | 0.6 s | 313 MiB → 30 MiB |
| mini Codex 0.154.0 (npm) | 1.0 s | 575 MiB → 30 MiB |

These are individual samples, not percentile guarantees. A placeholder readiness
marker precedes the RSS sample so it does not measure the transient shell. The
older mini Claude 2.1.269 test also exposed registry removal before SessionEnd;
the retained-exit guard now checks the saved live process fingerprint and pane
ancestry instead of requiring that registry entry to survive shutdown.

Claude workers already idle when this feature is installed need a subsequent real
Stop event before they can sleep; Codex can use native completion evidence.
Unknown descendant processes (including unapproved MCP/tool infrastructure) keep
a worker awake, for Claude and Codex alike. A quiet screen alone is never sufficient.
