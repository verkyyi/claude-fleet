# Fleet commands — the repo-shipped `/skill` contract

This directory holds **fleet skills**: Claude Code slash commands, shipped with
the repo, that operate on a fleet (a tmux session ↔ one GitHub repo). They are
the fleet-aware cousins of your personal `~/.claude/commands/` skills
(`/sweep`, …) — optional quality-of-life helpers a fleet operator
runs from inside a session.

They are **installed by copying** `commands/*.md` into the Claude Code user
commands dir (`~/.claude/commands/`), appended alongside — never clobbering —
any personal commands you already have. See the install step in
[`CLAUDE.md`](../CLAUDE.md).

> Phase 0 landed **just the contract** — this README and
> [`_template.md`](_template.md); the functional skills (`/fleet-claim`, `/fleet-ship`,
> `/fleet-land`, `/fleet-land-train`, …) land one per sub-issue, each cloning the template and filling in
> its body. See **Shipped skills** below for what's live so far.

## Shipped skills

| Skill | Owner | What it does |
|---|---|---|
| [`/fleet-claim`](fleet-claim.md) | worker | Startup ritual: read the window's bound issue, stake a collision-proof claim (assignee + `▶ claiming` comment), restate scope + sketch a plan. Idempotent. |
| [`/fleet-ship`](fleet-ship.md) | worker | Finish line: verify, ensure the `issue-<N>` worktree is clean + pushed, open/update a PR that `Closes #<issue>`. Never merges. |
| [`/fleet-blocked`](fleet-blocked.md) | worker | Signal a blocker on the bound issue instead of stalling silently. |
| [`/fleet-land`](fleet-land.md) | steward | Land one worker PR: verify it's genuinely mergeable (update-branch + re-check CI if merely behind, never merge red), squash-merge, fast-forward the fleet's base checkout, clean up the merged worktree + window. Fleet-agnostic — the general finish work only. |
| [`/fleet-land-self`](fleet-land-self.md) | worker | The worker-owned mirror of `/fleet-land` scoped to its OWN PR (opt-in `FLEET_SELF_LAND=1`). After `/fleet-ship` the worker waits; when the steward triggers by commenting `/land` (relayed by the #132 bridge), it re-verifies green, sanitizes its diff, takes the per-repo land lease (hold-through-green, `--match-head-commit`, steal-if-stale), squash-merges, fast-forwards the base, and self-destructs (kill window + remove worktree). Deliberately relaxes the "workers never self-merge" rail, re-gated by the trigger; failure → `/fleet-blocked`. Backed by [`bin/fleet-land-self.sh`](../bin/fleet-land-self.sh) + [`bin/fleet-land-lease.sh`](../bin/fleet-land-lease.sh). See [docs/SELF-LAND.md](../docs/SELF-LAND.md). |
| [`/fleet-land-train`](fleet-land-train.md) | steward | The batch complement to `/fleet-land`: a serial single-writer "land train" that merges a batch of green PRs one at a time (update-branch → wait green → merge → next), ejecting any that can't land, then base-pulls once and cleans up per merged PR. A client-side stand-in for a merge queue under `strict:true` branch protection. Backed by [`bin/land-train.sh`](../bin/land-train.sh). |
| [`/fleet-sync-install`](fleet-sync-install.md) | steward | Tooling-fleet only: after claude-fleet's own PRs land, re-apply them to the live install (`~/.claude/fleet`) — pull + reload changed daemons + re-merge the hooks delta + install changed commands. Idempotent; refuses on any other fleet. |
| [`/fleet-status`](fleet-status.md) | steward | Read-only estate digest for this fleet — live windows + state, open PRs, ownerless issues, disk/usage health — capped with recommended next actions. Mutates nothing; prefers the collector caches. |
| [`/fleet-history`](fleet-history.md) | steward | Browse & resume **landed** (merged + cleaned-up) sessions from the land-time history ledger (written by `/fleet-land` / `/fleet-land-train` before worktree removal). Lists finished work, opens the PR, pages the surviving transcript, and **resumes** a session by reconstructing its removed worktree off the squash SHA → `claude --resume` (or `--from-pr`). Backed by [`bin/fleet-history.sh`](../bin/fleet-history.sh); mirrored in the dash's live⇄landed **⌃t** toggle. |
| [`/fleet-new-issue`](fleet-new-issue.md) | steward | File a new issue in this fleet's repo from a task brief, then spawn a worker window (`issue-<N>` worktree + `claude`, bound via `@issue`) to implement it. **Delegates by default:** after an inline fail-fast seat guard, offloads dedup + grounding + create + spawn to one background sub-agent so the steward's turn stays short; `--quick` is a thin inline capture. A [delegating kind-A skill](#delegating-kind-a-skills-offload-heavy-inline-work). |
| [`/fleet-scout`](fleet-scout.md) | steward | Delegate a **read-only investigation**: file a `scout`-labeled issue (durable question + report sink) and spawn a read-only worker (`dash-issue-session.sh <N> --scout`) that investigates + reports and **never branches/ships/lands**. The heavyweight tier of the *scout task shape*; the lightweight tier is an ephemeral `Explore`/`Agent` sub-agent run inline (no issue, no window). See [docs/SCOUT.md](../docs/SCOUT.md). |
| [`/fleet-scout-report`](fleet-scout-report.md) | worker | A scout's finish line (the `/fleet-ship` analogue for an investigation): post the findings as an issue comment, decide **close vs. leave-open-for-ship-conversion**, then self-clean the window/worktree via [`bin/fleet-scout-clean.sh`](../bin/fleet-scout-clean.sh) (ordered teardown, no PR to merge). |

## Two kinds of fleet skill

Not every fleet skill is a human-invoked playbook. The contract covers **two
kinds**, distinguished by how they are invoked and what they may do:

| | **A. Interactive / role skill** | **B. Background-job prompt** |
|---|---|---|
| Examples | `/fleet-claim`, `/fleet-ship`, `/fleet-land` | `classify-session`, `summarize-session` |
| Invoked by | a human/steward, on demand | a `claude -p` daemon (on a timer/hook) |
| Template | [`_template.md`](_template.md) | [`_template-background.md`](_template-background.md) |
| Step-0 preamble | **yes** — resolve fleet + guard seat | **no** — a daemon has no seat |
| Marker | `<!-- fleet skill · owner: … -->` | frontmatter `disable-model-invocation: true` |
| Body | a numbered playbook that runs `gh`/`git`/tmux | a **pure prompt**, no tool use |
| Contracts | seat guard + fleet guard | an **input** contract + an **output** contract |

Everything under *The contract every fleet skill follows* below describes **kind
A**. Kind B is a versioned prompt, not a playbook: today the daemons carry their
prompt as a hardcoded heredoc (`bin/classify-sessions.sh`, `bin/tmux-summarize.sh`);
kind B is where those prompts move so they can be reviewed, diffed, and reused.

### The two contracts a kind-B skill declares

- **Input contract** — where the dynamic payload arrives. The daemon appends the
  prompt body as a system prompt and pipes the payload (a terminal capture, a
  diff, …) on **stdin**; the human/`/why` slash path passes it as **`$ARGUMENTS`**.
  The body is written so it refers to "the input/screen below".
- **Output contract** — the exact, machine-parseable reply shape, stated in one
  line (e.g. *"reply with EXACTLY ONE word and nothing else"*). The caller parses
  the reply, so it must be deterministic and preamble-free.

### How the daemon consumes a kind-B prompt

The cheapest, most deterministic path — used by the `claude -p` daemons — feeds
the prompt body as a system prompt and the payload on stdin (verified on claude
2.1.204):

```sh
printf '%s' "$payload" \
  | claude --bare -p --model haiku --allowedTools "" \
      --append-system-prompt-file <body>
```

- `--bare` skips hooks/LSP/plugins (fast, no side effects); `--allowedTools ""`
  forbids tool use (a kind-B body is a pure prompt); `--model haiku` keeps it
  cheap; `<body>` is the skill's prompt body (frontmatter stripped).
- The **human/`/why` path** may invoke the same prompt as a slash command
  (`/classify-session`). That path pays the normal slash-command discovery cost
  and **won't load under `--bare`** — so it's for interactive one-offs, not the
  hot daemon loop. `disable-model-invocation: true` keeps the prompt from ever
  auto-triggering on either path; it runs only when invoked explicitly.

### Delegating kind-A skills (offload heavy inline work)

Most kind-A skills run their whole playbook **inline** on the caller's thread.
That's fine when the work is cheap (`/fleet-claim` posts a comment; `/fleet-ship`
pushes a branch). It's a problem when a *steward* skill does something expensive
inline — the steward is single-threaded, so a long turn blocks every other thing
it could be doing (landing PRs, triaging, filing the next issue), and firing the
skill N times serializes into N long turns.

A **delegating kind-A skill** keeps the cheap, fail-fast part inline and hands
the expensive part to a **sub-agent** (the Agent tool), so the caller's turn
ends fast and N calls run in parallel. `/fleet-new-issue` is the reference: the
steward's turn is just step-0 (resolve fleet + guard seat) + one Agent launch;
the sub-agent does the grounding + drafting + `gh issue create` + spawn.

The rules that make delegation safe:

- **Guard inline, before spending an agent.** Step 0 (fleet + seat) stays inline
  and fail-fast so a wrong-seat / no-fleet call aborts *without* launching a
  sub-agent. Nothing else runs inline in the default path.
- **One self-contained sub-agent, not a fork.** Launch a fresh `general-purpose`
  agent with a prompt that carries everything it needs — do **not** fork the
  caller (a fork inherits cross-fleet context the proxy must not have).
- **Bake the rails into the prompt.** The sub-agent can't see the skill's header,
  so the delegation prompt must restate every rail: the resolved
  `$FLEET_REPO` / `$FLEET_MAIN` / `$FLEET_BASE_BRANCH` **literals** (this fleet
  only), what it may mutate, cap/limit handling, and — crucially — that it is a
  **proxy for the mutation, not a worker**: it files/spawns but never implements.
- **A one-line output contract.** The sub-agent returns a single machine-relayable
  line (`#<N> <title> — worker spawned`, or a cap refusal) so the caller just
  relays it, exactly like a kind-B output contract.
- **Auto-categorize on create, from the LIVE list.** A create skill that files
  an issue also assigns a best-fit **milestone** (the fleet's component
  categories). Fetch them at file time — never hardcode, since the user
  adds/renames/closes them: `gh api "repos/$FLEET_REPO/milestones?state=open"
  --jq '.[].title'`, pick the one title that best fits, and pass only a title
  that came back from that live list. When nothing clearly fits (or there are no
  open milestones), file with **no** milestone — never force a wrong/stale name
  (a bad `--milestone` fails the create). `/fleet-new-issue` does this in both
  its delegate and `--quick` paths and notes the choice in its report.
- **Graceful inline fallback.** If the runtime has no Agent-tool capability, run
  the sub-agent's steps inline instead of hard-failing — slower, but the work
  still lands.

This is still **kind A** (a seat-guarded, human-invoked role skill) — it just
offloads its body. It is distinct from **kind B**, where a *daemon* runs a pure
prompt on a timer with no seat; here a *human/steward* invokes the skill and the
sub-agent is a one-shot proxy for that single invocation.

## The contract every fleet skill follows

> This section describes **kind A** (interactive/role skills), including the
> delegating variant above. For **kind B** (background-job prompts) see *Two
> kinds of fleet skill* above.

A fleet skill is a markdown playbook (a header + a numbered body, exactly like
`sweep.md`). Two rules make it *fleet-aware*:

### 1. It opens with the resolve-and-guard preamble (step 0)

Every skill's first step resolves **which fleet** it is running in and **which
seat** the caller occupies, then refuses early if either is wrong. Copy this
verbatim from [`_template.md`](_template.md):

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **abort** in one line. Never guess a repo.
- Capture the printed values: env vars do **not** persist across separate Bash
  tool calls, so read them back from the `echo` and reuse the literals.
- Everything after step 0 operates on the resolved `$FLEET_REPO` / `$FLEET_MAIN`
  / `$FLEET_BASE_BRANCH` only — never another fleet's.

### 2. It declares an `owner:` seat and enforces it

The two seats a fleet skill can run from (`fleet_seat` prints these):

| Seat | How it's detected | Who it is |
|---|---|---|
| `worker`  | the current tmux window has `@issue` set **and** cwd is inside an `issue-<N>` git worktree | a session bound to one issue, implementing it |
| `steward` | no `@issue` on the window **and** cwd is the fleet base checkout (`$FLEET_MAIN`) | the hub session that triages/backlogs, doesn't implement |
| `""`      | neither (a stray shell, or cwd somewhere else) | ambiguous — treat as wrong-seat |

Each skill declares which seat(s) it belongs to, on its marker line (see below):

- `owner: worker`  — only a worker may run it (e.g. `/fleet-ship` a branch).
- `owner: steward` — only the steward may run it (e.g. `/fleet-new-issue`, `/sweep`).
- `owner: either`  — seat-agnostic.

If `$SEAT` doesn't match a non-`either` `owner`, the skill **refuses in one
line and stops** — e.g. *"/fleet-ship is worker-only; you're in the steward seat."*
Never proceed from the wrong seat.

### 3. It carries the `fleet skill` marker

Just under the `#` title line, every fleet skill carries an HTML comment
declaring the contract and the owner seat:

```
<!-- fleet skill · owner: worker|steward|either -->
```

This marker is how tooling recognises a fleet skill among your personal
commands: `bin/fleet-doctor.sh` scans the head of each `~/.claude/commands/*.md`
for `fleet skill · owner:` to report how many are installed. Keep it near the
top (within the first few lines) so the scan finds it.

## `fleet-lib.sh` helpers a skill may use

Already exposed (all cheap, `set -u`-safe — see `bin/fleet-lib.sh`):

- `fleet_current_session` — the tmux session the caller runs in.
- `fleet_load_conf "$S"` — overlay that fleet's conf (sets `FLEET_REPO` etc.).
- `fleet_seat` — `worker` / `steward` / `""` (needs `FLEET_MAIN`, so call
  `fleet_load_conf` first).
- `fleet_slug_cached "$S"` — session → filesystem slug from the collector cache.

## Adding a new fleet skill

**Kind A (interactive/role):**

1. Copy `_template.md` → `commands/<name>.md`.
2. Set the title, the `owner:` on the marker line, and the intent sentence.
3. Fill in the numbered body **after** step 0 (leave the preamble intact).
4. Keep every mutation behind the resolved fleet + seat guard. The base
   checkout is read-only (hook-enforced) — a worker edits inside its
   `issue-<N>` worktree and lands via PR.

**Kind B (background-job prompt):**

1. Copy `_template-background.md` → `commands/<name>.md`.
2. Keep the `disable-model-invocation: true` frontmatter; set the title.
3. Rewrite the body as a **pure prompt** — no step-0 preamble, no tools —
   declaring the **input** and **output** contracts (see *Two kinds* above).
4. Point the consuming daemon at the body via
   `claude --bare -p … --append-system-prompt-file <body>`.
