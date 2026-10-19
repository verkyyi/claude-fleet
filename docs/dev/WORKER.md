# Worker lifecycle — background and troubleshooting

The executable instructions are [commands/fleet-claim.md](../../commands/fleet-claim.md). This document holds their rationale, incident references and troubleshooting, indexed by the same section titles. It is reference material, not another charter to preload. Issue #4325 (EPIC #4322) separates the two without changing the workflow, tool names, heading anchors or guards; the command stays at most 13,000 bytes. Codex's native skill continues to be generated from that command and `conf/codex-preamble.md` through `conf/agent-bundle.manifest`; do not maintain a second instruction copy.

A worker is a full agent, not a deckhand (#441): it owns the implementation and landing. The rails protect shared state; they do not make the operator a routine approval gate. One worker owns one issue, one worktree and one PR. Work finishes with a confirmed merge and a report, or an explicit blocker.

## 0. Resolve fleet + guard seat + read the issue — ONE call (run FIRST)

`brief` combines the old four-step preamble into one atomic read (#458). The old flow cost about thirteen turns, and shell variables did not persist between tool calls. One call prevents a half-resolved fleet or a skipped charter (#454).

The window's `@issue` is authoritative, with the `issue-<N>` cwd as recovery when the binding is lost. The seat gate refuses the hub or a stray shell rather than guessing. Exit 5 deliberately distinguishes a successful fleet/charter read from a failed ticket read: partial context is not authorization to implement.

Claim goes through the ticket door (#3598): hub tickets have an atomic claim, where a second session gets exit 3; GitHub tickets use the assignee (#283). Spawn normally already claimed it, so `HELD` must not trigger a second claim.

The built-in charter is extended by the repo charter only when `FLEET_REPO_CHARTER=1`: repository content is an injection surface, so loading it is fail-closed. The operator's fleet overlay is always trusted and has highest precedence. The implementation directive is the fleet's HOW-to guidance (#234).

`origin:` identifies the session waiting for the outcome (#574). It can be local, on another machine, absent, or already gone by the time work finishes; reporting handles all of these.

Every fleet step reaches the same implementation through [FLEET-MCP.md](FLEET-MCP.md) (#1811). The MCP service validates identity and arguments and returns the script's exit code/stdout/stderr; using tools preserves caps, guards and deduplication. Script fallback is only for a session with no fleet service (see 排障).

## 1. Ground yourself, then implement

Read the issue's entire discussion, design and parent charter before choosing an approach; a brief implementation directive supplements that context, not replaces it. Enough grounding is more valuable than blindly minimizing reads.

### Ground cheaply — keep the broad sweep out of the main context

Measurement across ten worker sessions found grounding cost a median 53k output tokens versus 4.9k for the preamble, with 91k context loaded before the first write (#460). Broad searches repeated in the main context cause premature handoffs and another round of grounding. Read-only search fan-out and symbol-sized reads keep the implementation context useful; history (`git log -p --follow`, `git log -S`) often explains a prior change more cheaply than all its callers.

`hooks/agent-guard.py` permits only read-only Explore, Plan and claude-code-guide subagents (#811). Writing subagents bypass the fleet's visible worker window, quota migration, state, handoff and PR ownership. Several can edit the same worktree, and an isolated fork worktree is still blocked by the base guard. `FLEET_ALLOW_SUBAGENT=1` is the operator's escape hatch, not a normal worker workflow.

Any session may spawn, a worker too (#4591 lifted #2960's refusal). A worker's `await` spawns the issue's worker when none is live (#812), and that grandchild reports to the worker; once the worker is reaped its reports climb to the nearest live ancestor (`fleet_live_ancestor`, #1352), else they become the person's reminder (#3117) — the parked-parent loss that motivated #2960. The caps and the claim dedup still bound how many run.

`fleet gh` reads the daemon's shared issue/PR/check cache (#1263): issues roughly every 90 seconds, PR state/CI every 15 seconds. Eighteen to thirty workers fetching independently exhausted shared GraphQL quota. The default maximum age is 120 seconds for issues, 30 for PRs; missing fields or stale data cause one fetch, with REST fallback under GraphQL limits. `_source` and `_age` expose the provenance; this is a useful default, not a ban on a fresh read. The merge verdict remains a separate gate.

### Before you touch code: the 「改动前」 capture

EPIC planning writes an `上线证据:` line for each member (#809). `evidence` stores captures outside the worktree under the fleet's EPIC/member evidence directory, or under the standalone issue's evidence directory. Before and after must use the same URL, command or pane for a meaningful comparison (#810).

A before taken after editing would be fiction. The batch report collects the actual files and says **无证据** for missing evidence; it never reconstructs or re-shoots a worker's past. `gh` cannot attach an image to a comment, so the evidence post records file paths and notes while the files remain on the machine. Moving a `.playwright-mcp/` capture out avoids a dirty worktree at ship time.

## 2. The standing contract (built-in charter — the base layer)

**Worktree and conversation.** The base is shared by other sessions; `hooks/base-readonly-guard.py` protects it. The issue comment wrapper adds the no-relay marker and sender footer. A bare close-with-comment once relayed an unmarked final comment back to its own worker as a new turn (#486); bare `gh issue comment` is rewritten by the guard (#528), but the tool is the normal path.

Omitting `repo` makes comment use the window's `@repo`; explicitly supplying it once selected the fleet's first repo instead (#1461). A default `mode: note` comment is record-only even when it returns a URL and exit 0 (#489). A peer instruction needs `send` (dispatch group, #3113) or `mode: to-worker`; its receipt tells whether delivery occurred. Window indexes drift on close (#1046), and `tmux send-keys` races bracketed paste (#437), so neither is a peer channel. `FLEET_ALLOW_SENDKEYS=1` exists only for deliberate fleet plumbing; a private test socket owning no fleet config is outside that pane guard.

**Spot something else? Three moves.** The one filer channel keeps adjacent work in the backlog (#332). Related work becomes a GitHub sub-issue with `parent: N`, still an ordinary issue/worktree/PR with its own number. `bind` escalates an unbound scratch session and refuses an already-bound worker (#520). A worker that needs the adjacent work to finish may file it with `spawn` and `await` it; the child reports back to the worker (#4591).

The in-place exception is intentionally local: a generated drill password missing a digit (#2950) fit; the hub answering “no login there” (#2941) required a separate issue and the parent. A change to a shared API, protocol, database, release/deploy path or credentials never qualifies simply because its diff is small. When the base is red, use the breakage path below.

**Hand off before you run out of context.** The model cannot rely on the context meter shown to the human; `context` exposes the same WATCH/HANDOFF bands as the nudge (#464). A durable handoff prevents a fresh worker from repeating the entire investigation.

**Done = ship it AND land it.** Nobody else is queued to merge a worker's green PR (#441). CI is the verdict when it already runs the PR suite: one full local run took 21 minutes for only 159 of 270 tests on a shared machine (#1374). For this repo, Ubuntu tests gate the PR and macOS runs on master after merge (#2286). A specific local reproduction is appropriate after a CI failure; another full suite is not.

A `land: fleet` repo has no PR (#3602). Its merge tool rebases on the latest base, runs the registered check and fast-forwards through the fleet gate. This path uses the same verdict words and reports merged without a PR number; it is not permission to manually commit in the base checkout.

`pr_verdict` folds state, mergeability and every relevant check into one answer. `pr_merge` rechecks READY, merges with `FLEET_MERGE_METHOD` (default squash), deletes the remote branch only after successful merge and confirms the result. Under GraphQL exhaustion it uses REST, pins the head SHA and deletes only after GitHub confirms (#1042). A green PR need not wait for GraphQL quota.

The separate-delete failure is why merge and branch cleanup are ONE call (#544): #534 used `gh pr merge … | tail && git push origin --delete …`; the squash lost a conflict race, `tail` returned success, and deletion closed the unmerged PR. The worker was killed during attempted recovery. Local branch/worktree cleanup belongs to the daemon after the merged grace and liveness checks (default ten minutes), not the merge caller.

`pr_verdict wait: true` blocks and paces reads to the shared budget (#950), waits out checks not registered yet or reset after push, and fails fast on the first red check. TIMEOUT is undetermined, with the merge state on stderr. An armed auto-merge is not a completed merge (#1247); report's own merged check refuses to announce it prematurely.

Base breakage is one issue for the fleet (#2078): three workers once filed three issues and fixes for one duplicate route within sixteen seconds. `file_issue breakage: true` fingerprints/deduplicates the failure and returns the existing issue with exit 5, or files and queues the steward with exit 0. Workers wait for that single fixer. Only the explicit flag selects this path (#4271); ordinary text saying “red” must not swallow an unrelated issue.

A report is unconditional after merge (#574). `reported` means arrived; `queued` means delivery will retry when the parent wakes or reconnects (#1647); `orphaned` becomes a reminder when the parent is gone (#3117); `undelivered` means neither arrival nor queue and must be disclosed (#3439). Reports use the same hub path for a parent on another machine. This reporting cannot undo a successful merge.

**A draft-only ticket stops at the draft.** The draft gate (#3715) changes the finish line: the brief supplies body markers; worker reports waiting and stops. Approval through `fleet-draft.sh approve` is delivered as the next turn, while rejection closes the PR. `@reap_policy merged` keeps an open draft's window from being reaped. See [DRAFT-PR.md](DRAFT-PR.md).

**Merged is not live, and making it live is not yours.** In EPIC #883 a worker synced immediately after its own merge and swapped scripts and a daemon under the rest of the batch (#953). The live install is every session's floor. Workers take branch evidence; the driver takes the 已上线 column after batch-end synchronization, and install-sync follows stable when the operator moves it. A live-only evidence request never grants a worker permission to install.

**Host for the operator with doc-preview, never an Artifact.** Artifacts are tied to the publishing claude.ai account, while fleet rotates accounts; the operator cannot know which login owns the page (#526). The artifact guard blocks publishing, not reading/commenting on an existing artifact. Doc-preview shares append to one machine-hosted collection. Follow its current skill for URL delivery and privacy rather than inventing hosting.

**Show the operator a file on THEIR terminal, never `open` it here.** The operator is connected over SSH; `open` would display on the unattended node (#1367). `show` sends an image/PDF/QR file to the operator's computer and answers with its receipt (#3541): `saved:<path>` names where it landed on their side, `unconfirmed` means handed over with no answer, `failed:<why>` (exit 4) that their side could not take it. Inline display holds the screen until a key; PATH signals unavailable transfer or an over-cap file. Reading documents still belongs to doc-preview.

**Open a page in the operator's browser with `fleet-open`, never `open`.** The open tool routes through the operator's connection and forwards node-local ports (#1379), including dev server URLs. Its skill defines the delivery receipts and fallback behavior.

**A temp server binds 127.0.0.1 and dies with your work.** Common dev servers bind all interfaces by default. A 2026-09-24 audit found an orphan serving an entire scratchpad root for two days (#1154). Loopback limits exposure; teardown and diskguard reap orphans, and doctor warns about fleet listeners on the LAN.

**Blocked = say why, never stall silently.** `ask` both records the blocker and marks the window `needs/blocked`; hooks/classifier/Stop preserve the red state until new user input. A child report that does not resolve it requires re-asking before stopping. Required review, unavailable credentials or a decision only the operator can make are blockers; wanting another opinion is not.

A question carries `suggest` and a reason; `default`/`due` are hints written under it — since #4337 nobody answers at a deadline (EPIC #4333). `ask` also sends a copy to the parent session (fid first); no parent, and the question waits for the person on the issue and the red row. Decisions received in the pane still get a `决定（直达）：` issue comment so the record stays on the issue.

**A `[child-report]` arriving in YOUR pane: acknowledge, don't take over.** Reports from a pre-rule child or an adopted wait are context, not new assignments. The literal `no reply needed` avoids echo turns. One `status`/`children` read joins ledger, live state and cached PR state; opening each child's PR and capturing its pane added an average 3.3 tool calls per report (#940) and encouraged workers to take over a second issue. Clear only a blocker actually owned by your task.

## 3. Report + proceed

The claim is already the go-ahead; the opening status line identifies the issue, claim and charter layers rather than asking whether to start. Shared fleet state remains outside the worker's scope.

One fleet has its own named tmux socket (#159). Destroying that server, session or a sibling window interrupts every worker on it (#158). Tests use `tmux -L scratch` or an isolated `-S` shim such as `bin/dash-marker-selftest.sh`. The shell's `tmux()` guard in `shell/cw.zsh` catches common accidents, not a hostile operator; `FLEET_ALLOW_TMUX_DESTROY=1` is the deliberate live-server escape hatch.

## 排障 — scripts, for when a tool is not enough

Everything above is a tool call. The scripts below have no tool, because a
worker's day does not include them — they are for a deliberate experiment or a
diagnosis — and this section is the one place a worker skill spells a path.

**No `fleet` tool in the session at all** (`FLEET_MCP=0`, a session started
before the tool service, a Codex build without MCP): every tool above names its
script in its description, and docs/dev/FLEET-MCP.md lists each tool's exact argv —
run that, unchanged, from `~/.claude/fleet/bin/`. Say in your report that the
tools were missing; it is a setup gap, not a way of working.

**Putting the machine under load? Use `bin/fleet-loadgen.sh`, never your own
`trap`.** Load experiments are legitimate — verifying an assertion on a busy box
is real work. Hand-rolled ones are how the machine dies: on 2026-09-15 a worker's
`(while :; do :; done) & … trap 'kill $BURN' EXIT` leaked 8 spinners that ran
**3h20m at ~70% CPU each** as `PPID=1` orphans, took the box to load 108 until
`ps` itself timed out, wedged both daemons and poisoned another issue's evidence
(issue #697). The trap never fired — a trap lives in the parent, and the parent
died. Every worker sharing the machine paid for it.

    ~/.claude/fleet/bin/fleet-loadgen.sh 4 120 -- <your experiment>   # load only while it runs
    ~/.claude/fleet/bin/fleet-loadgen.sh --status / --stop            # a detached batch

Each burner carries its own kernel deadline, so SIGKILLing the parent or closing
your pane cannot leak one, and the caps refuse an absurd `n`/duration. It also
refuses (exit 3) while the box is already above 1 load/core and clamps to half
the cores (issue #922) — that is the fleet daemons' headroom, not an obstacle;
keep the run short, or `--force` only for a deliberate saturation run. If you
suspect something already leaked — yours or anyone's —
`~/.claude/fleet/bin/fleet-diskguard.sh --orphans` lists the `PPID=1` runaways
the worktree- and pane-keyed reapers structurally cannot see.
