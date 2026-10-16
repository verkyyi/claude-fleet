# Task authority acceptance rehearsal

This is the repeatable C9 procedure for [EPIC #4390](https://github.com/verkyyi/claude-fleet/issues/4390).
It preserves #3570's **7/7 automated fixture** baseline and adds twelve contract
rows. A fixture pass is never a deployed-version or live-provider claim.

## Automated fixture run

[task-acceptance.yml](../../.github/workflows/task-acceptance.yml) is the complete
Linux recipe. It builds this checkout's hub and three Go test binaries, prepares
Chromium, then runs [nogh-task-acceptance.py](../../bin/nogh-task-acceptance.py).
Preparation may download dependencies; acceptance begins only after that phase.
The worker relies on PR CI; do not run the whole suite on a managed worker.

To reproduce on a disposable Linux test machine, copy the workflow's preparation
and run commands with `RUNNER_TEMP` pointing outside the checkout and
`GITHUB_WORKSPACE` naming the checkout. Required tools: Go 1.25, Node 22, Python 3,
git, curl, jq, ssh-keygen, tmux, strace, util-linux and iproute2. Privilege is used
only to create a **new network namespace** and enable its loopback; the fixture
process drops root before running. No production network policy is changed.
Missing tools, failed namespace setup, missing named tests, skipped tests,
timeouts and unreadable trace formats do not pass. macOS can run the existing
member fixtures, but cannot claim this Linux network-denied rehearsal.

The namespace has no external interface or route. A failing `gh` shim counts CLI
attempts independently of a descendant `execve`/`execveat` observer, which sees
absolute paths and fixture-overridden `gh` executables too. These fixtures call
`gh` as an executable, not as sourced shell code. Restored-response mock CLI
reads are classified by their explicit private executable paths and exact counts;
they do not become control-plane zeros. `strace -v -s0` retains executable paths
and complete socket destination arrays while suppressing argv, env and payload
strings. It observes `connect`, `sendto`, `sendmsg`, and `sendmmsg`, including
failures such as `ENETUNREACH`. Connected-socket destinations are observed at
connect; unconnected datagrams carry their destination on send. The test trace
uses `inject=io_uring_setup:error=ENOSYS` so Node/libuv falls back to observable
syscalls; its epoll batching would otherwise create a ring even with
`UV_USE_IO_URING=0`. This affects only traced fixture descendants, never production.
An explicit probe verifies ENOSYS, the trace records each injected denial, and
any unfenced ring setup or submission fails acceptance. Unrecognized addresses
or executable trace formats fail closed.

Non-loopback destinations on ports 80/443 form a conservative upper bound for
direct GitHub HTTP attempts (not a count of successful HTTP requests). Other
external destinations, including DNS and SSH, also fail acceptance. Loopback
fixture servers remain available. Positive controls exercise PATH, absolute and
overridden CLI paths, execveat, IPv4/IPv6 TCP and UDP sendto/sendmsg/sendmmsg before
any row. They also check that a payload/argv/env sentinel is absent from the
trace. Their nonzero counters are separate. Zero counters without working
positive controls are not proof.

The driver runs sequentially, with individual 60/90-second bounds (300 seconds
for the historical baseline) and a 600-second total command budget. It creates no
resident service. Existing fixtures own their temporary processes/sockets and
clean them up; a Linux subreaper additionally ends/reaps detached fixture helpers
after their test exits, archives that cleanup and preserves the test's exit.
It addresses only its own descendants. The CI job has an outer 11-minute bound for the acceptance step.
No load generator is needed. If a later live drill requires load, use only
`fleet-loadgen.sh`, with a short declared bound and normal admission.

The `task-acceptance-fixtures` CI artifact contains:

- `acceptance.json`: A1–A12, each linked to executed boundary records; separate
  fixture and live statuses. Live always starts **NOT RUN**.
- `provenance.json` and `deny-policy.json`: source SHA, binary hashes, UTC time,
  network policy and the independent merged/deployed/live columns.
- Per-boundary JSON command, cwd, UTC start/end, exit and counters; adjacent logs
  and syscall traces. Go fixture logs include task/lease/event snapshots.
- `baseline-summary.json`: the old seven steps and its own CLI/HTTP tripwires.
  The old installer/agent recorder is still a fixture, not a real Codex process.
- `recovery-native.json`: the C6 public CLI sequence, isolated process identity,
  explicit result, native exit, lost acknowledgement and repeated replay. Its
  Python sleeper is explicitly a native-process **stand-in**, never Codex proof.
- `pr-gate-commands.json`: denied GitHub read (exit 2, no verdict), followed by
  local restored-response fixtures for PENDING, FAILING, READY. The deliberate
  denied read has its own CLI counter and does not contaminate control zeros.
- Desktop/mobile portal screenshots and browser read/keyboard assertions. The
  offline browser fulfils committed assets and API fixtures through Playwright
  routes, avoiding Chromium's unrelated IPv6 reachability probe; attempted
  network access is still counted and fails the row.

Raw fixture state directories, credentials and transcripts are not uploaded.
The harness composes existing store/API, controller, shell and browser seams;
it does not claim a real multi-machine Codex end-to-end run. PostgreSQL coverage
remains in the existing hub CI; this bounded driver uses SQLite.

| Row | Executed fixture boundaries | Live default |
|---|---|---|
| A1 | #3570 forge-none baseline; accepted explicit dispatch; verified launch supervisor; provider resolver | NOT RUN |
| A2 | Durable controller restart/lost ack; same native identity; lost identity refuses new launch | NOT RUN |
| A3 | Task children/await shell; parent-generation report delivery; store fencing | NOT RUN |
| A4 | GitHub-backed repo cutover; work/PR projection; denied then restored PR gate | NOT RUN |
| A5 | Explicit choice over stale label/default; invalid and contradictory providers refused | NOT RUN |
| A6 | Duplicate acceptance, changed payload, one launch, lost receipt acknowledgement/replay | NOT RUN |
| A7 | Old-generation report, explicit transfer and immutable terminal result | NOT RUN |
| A8 | Same number in two repos, qualified references, foreign owner/endpoint refusal | NOT RUN |
| A9 | Retained native across outage; bounded outbox/expiry/conflicts; confirmed stale browser state | NOT RUN |
| A10 | Cancel intent versus completion; confirmed native stop; same-generation resume fence | NOT RUN |
| A11 | Dry-run/freeze/apply/rollback; active native/start reservation; unchanged second repo | NOT RUN |
| A12 | Committed portal build, mobile/desktop nav, keyboard tabs/details, thin-client PTY and verified native inbox | NOT RUN |

## Live run: select and authorize the target first

This document does not authorize a live drill, install sync, restart, production
canary or migration. Record an explicit decision naming the disposable hub,
two test nodes/logins, one forge-none repo and one GitHub-hosted repo, source and
deployed versions, provider account, bounded test window and rollback owner.
Keep existing production and peer workers outside the targets. Recheck external
owners #3401/#3955 for credential/restore prerequisites, #4434/PR4480 for native
snapshot evidence and #4488/PR4489 for warm-pool fleet identity. A merged fix does
not establish that a participating node runs it. Leave dependent live rows NOT
RUN when the target or prerequisite is absent. #4354 and #4352 retain their work.

Use a private evidence directory outside git, mode 0700. For **each command**
record UTC start/end, command without credentials, real exit/status, and artifact
paths. Keep a table with `row | fixture | live | merged | deployed | evidence`.
Record the hub `/version` and every node's running executable/version plus loaded
capabilities. Record `ps -p <verified-pid> -o pid=,ppid=,lstart=,comm=` on the
actual remote node and the native thread/session receipt: task, owner, operation,
attempt, generation, fleet/session identity, executable, process birth and native
session. Never accept the issue label, window title or source checkout SHA as
provider/deployment evidence. Archive task, operation, lease, children and outbox
snapshots keyed by their qualified identities, not bare issue integers.

Before A1/A4, apply the selected test environment's network deny policy on **both
hub and nodes**, retaining hub and native-provider connectivity. Archive the exact
policy, IPv4/IPv6 and DNS coverage, route/proxy configuration and separate CLI and
direct HTTP attempted-access counters. A `gh` shim alone is insufficient. Probe
`gh api /rate_limit`, direct `curl https://api.github.com/rate_limit`, a direct-IP
`curl --resolve` request using the recorded address, and IPv6 when enabled; all
must fail and increment the proper counters. A successful probe aborts the drill.
Save positive-control counts, then start new per-row counters. Do not alter a
shared machine's firewall or assume an HTTPS proxy blocks bypasses. If the
selected test network cannot enforce this, live acceptance remains NOT RUN.

## Live command sequence and assertions

Run through the existing coordinator tools or an operator shell on the selected
test nodes. Scripts below document the operator shell road; a worker uses its
equivalent fleet MCP tool. Tokens are read at runtime and passed through stdin
headers, never recorded in argv, artifacts, public comments or config.

1. **A1 / A5 / A6 — accept once.** Submit `POST /v1/fleet/worker_start` on the
   selected hub with a private JSON body containing `repo`, `kind: scratch`,
   `coding_agent: codex`, a unique `idempotency_key` and a harmless bounded body.
   Do this for the forge-none test repo first. Save the accepted operation and T
   reference. Repeat the identical body/key: require the same T/operation and one
   native launch. Change the provider/body under that key: require conflict and
   no launch. Try an unknown provider under a new key: require refusal before
   execution. Existing stale Claude labels/defaults must not change accepted
   Codex. Verify the remote process and native session before input is delivered.
   Control counters must remain gh=0/direct GitHub HTTP=0.
2. **A2 — reconnect/restart.** Disconnect/reconnect only the chosen test client's
   transport, then restart only its authorized test adapter. Read
   `GET /v1/fleet/operation_get?operation_id=<id>` and
   `fleet-task-record.sh get <T>`. Require the same T, generation, worker and
   native session and one launch. In a separate disposable run remove availability
   of the native identity: require unknown/interrupted and no automatic rerun.
   Do not kill or restart a shared fleet server.
3. **A3 / A7 / A8 — children and fencing.** From the chosen coordinator create
   one remote child with the parent's task/session/generation; retain the accepted
   envelope. Use `fleet-children.sh <parent-T> --json` and
   `fleet-await.sh <child-T> --timeout 60 --no-spawn`. Have the child explicitly
   `report` with `outcome: succeeded`; retain the report event ID. Replay its
   existing delivery after dropping the acknowledgement: one result and one
   delivery. Run two repos with the same ticket integer and attempt a foreign
   owner read/write: no crossed attribution, 404/refusal. After an explicitly
   authorized, confirmed-stop transfer, replay the old report: historical/refused,
   no new-generation mutation. Never manufacture a stop receipt or switch providers
   silently to complete this row.
4. **A4 — GitHub work and PR completion.** Repeat the accepted control path on
   the GitHub test repo while blocked. Commit a harmless change in its worker
   worktree and explicitly report the work outcome. Require the T outcome to be
   retained while PR/CI remains waiting/unverified. `pr_verdict` must return an
   unreadable/error result, never READY inferred from work success. Record this
   intentional denied GitHub attempt separately from the zero-access control
   interval. Restore only the test deny policy; read the real PR and checks with
   `pr_verdict`. Capture PENDING/FAILING when present and actual READY only after
   passing checks. If landing is authorized, call `pr_merge` and require confirmed
   MERGED. A queued merge request is not confirmation. Preserve both evidence
   intervals; the fixture's local restored response cannot fill this live cell.
5. **A9 / A10 — partition and cancel.** Block the chosen node's hub control link
   while its bounded native work continues. Show the process still alive, the
   portal's unchanged last-confirmed timestamp, and refused new dispatch. Request
   cancellation without a stop proof: outcome must not become cancelled and no
   replacement may launch, even after lease expiry. Explicitly report completion
   while offline, then end that isolated native process through the supported
   stop road. Reconnect; use the existing `fleet-hub-node.sh replay` reconnect
   path twice, including one lost acknowledgement. Count one committed outcome
   and one matching stop acknowledgement. In a second run resume the same native
   session before replay: old stop proof must be rejected. Run expiry/overflow
   only in disposable fixture state (7-day/1,000-event limits); never fill a real
   user's journal or call unresolved expiry success. No new polling service.
6. **A11 — migration and rollback.** Save
   `fleet_repo_authority.py <repo> --session <test-fleet> --dry-run` twice and
   compare. Record active/unknown owners and repo B bytes. Use the saved manifest
   with `--freeze`, `--apply` or `--rollback` only under the named cutover approval;
   refresh the manifest at each revision. An active/unverified legacy owner must
   block cutover. Drain or explicitly adopt only verified owners. Require one
   authority and unchanged repo B. After accepted hub work exists, rollback must
   retain its hub authority until terminal and confirmed stopped; never mirror
   T state into GitHub or roll the database back. Warm-pool owners keep their
   owning fleet UUID (verify the deployed #4488 fix).
7. **A12 — operator view.** On the actual current portal, use desktop and mobile
   viewports, keyboard tabs/details and the native terminal link. Capture honest
   unknown/failed/cancelled/succeeded rows, retained native execution after work
   completion, provider mismatch, qualified tickets and PR status independent of
   outcome. Confirm navigation/theme and direct terminal behavior remain intact.
   Reconnect the thin client to the same native identity. Archive screenshots and
   network/process observations as live evidence, separately from CI screenshots.

End by removing only the named test deny rules, ending only test sessions through
their normal close path and verifying their processes/servers are gone. Record
cleanup commands/exits too. Do not leave a helper server running. Any missing,
ambiguous or stale observation is NOT RUN/FAIL, never a pass by inference.

## Retirement gate

C8 remains open without a waiting implementation worker until **all** are
evidenced: one released compatible version, at least seven days since explicit
canary cutover, successful applicable C9 live rows, and zero active legacy owners.
Keep merged, deployed and live-accepted as independent columns in every report.
Release-train publication alone does not prove node deployment. A merged C9
harness does not authorize C8 deletion or production cutover.
