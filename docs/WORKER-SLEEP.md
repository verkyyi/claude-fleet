# Worker hibernation

Fleet can retain a worker's window and worktree while its coding agent exits.
Entering the window resumes the exact native conversation, with no new prompt.
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

Manual sleep bypasses only the idle duration, never safety checks. A client
viewing the window prevents sleep, even if it has not typed recently. Normal
tmux navigation, sidebar selection and client attach wake a sleeping worker;
highlighting a dashboard row does not. During resume, wait for the native input
prompt before typing. No wake action authorizes an additional model turn. Codex resumes its saved native
permission profile. Its existing hook authorization is carried as exact native
hashes in temporary launch arguments; user trust configuration is not modified.
Changed hooks may still require review. Startup update checks are suppressed for
the resume invocation so a version notification cannot block entry; fresh launches
keep their normal update policy. Both standalone and npm-installed Codex are
supported.

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
Owned tool processes, pending interactions, Fleet loops, transfers, failover,
an unsubmitted draft or an unrecognized input layout prevent sleep. Unknown
probes always keep the worker running. Worktree modifications are preserved and
are not a reason to delete or commit anything.

A verified proactive quota-switch request that is only waiting does not prevent
sleep. The sleep operation holds the quota reconciler's lock through exit; quota
reconciliation skips retained workers and rechecks their identity after wake.
Hard quota failures, cutovers in progress and ambiguous deliveries still prevent
sleep. A text status flag alone cannot authorize this exception.

Codex's persistent `codex-code-mode-host` is allowed only as a direct child of
this worker's exact app-server, with its kernel executable path matching the
server's bundled release. Children of that host still undergo tool-process checks.
The empty Codex composer can be recognized beneath its colored dot animation
only with the native faint placeholder and cursor at the start. Real drafts,
attachments and unrecognized layouts still prevent sleep.

## Retained state and recovery

Private records live at `fleets/<session>/sleep/` below `FLEET_CONF_DIR`. They
contain the exact source session, transcript, account home, worktree, native
permission mode, restart options and a last-screen preview. Files are written atomically with
mode 0600. Treat these records as sensitive conversation data.

A per-worker kernel lock serializes sleep, wake and message delivery; the
worktree transition lock also excludes migration. A saved record precedes exit.
Only a confirmed exited process and a dead pane or childless shell can be
replaced. A timeout does not kill an agent. The retained-exit check prevents the
ordinary SessionEnd cleanup from closing the task. Automatic cleanup and screen
classification recognize retained workers.

Messages are persisted before waking and sent to the exact resumed agent's
native inbox. Failed delivery is not reported as success. A delivery timeout is
recorded as uncertain and is not blindly replayed. These native transports
confirm acceptance, not completion of the requested work.

The sleep daemon runs one bounded scan per minute. It also reconciles interrupted
transitions. Crash snapshots retain the sleep record; restoring a fleet recreates
the placeholder rather than starting every sleeping agent. A missing worktree,
transcript or account leaves an actionable failure; it never silently starts a
new conversation.

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
Unknown descendant processes (including unverified MCP/tool infrastructure) keep
a worker awake. A quiet screen alone is never sufficient.
