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
| [`/fleet-land-train`](fleet-land-train.md) | steward | The batch complement to `/fleet-land`: a serial single-writer "land train" that lands a batch of green PRs one at a time (update-branch → wait green → merge → base-pull → clean up → next), ejecting any that can't land. A thin batch driver over the shared [`bin/fleet-land.sh`](../bin/fleet-land.sh) (each lap is one full mechanical land), so it's a client-side stand-in for a merge queue under `strict:true` branch protection. Backed by [`bin/land-train.sh`](../bin/land-train.sh). |
| [`/fleet-sync-install`](fleet-sync-install.md) | steward | Any fleet: maintains the shared live install (`~/.claude/fleet`) — after claude-fleet's own PRs land, re-apply them: pull + reload changed daemons + re-merge the hooks delta + install changed commands. Idempotent; refuses only if `~/.claude/fleet` isn't a git checkout. |
| [`/fleet-status`](fleet-status.md) | steward | Read-only estate digest for this fleet — live windows + state, open PRs, ownerless issues, disk/usage health — capped with recommended next actions. Mutates nothing; prefers the collector caches. |
| [`/fleet-history`](fleet-history.md) | steward | Browse & resume **landed** (merged + cleaned-up) sessions from the land-time history ledger (written by `/fleet-land` / `/fleet-land-train` before worktree removal). Lists finished work, opens the PR, pages the surviving transcript, and **resumes** a session by reconstructing its removed worktree off the squash SHA → `claude --resume` (or `--from-pr`). Backed by [`bin/fleet-history.sh`](../bin/fleet-history.sh); mirrored in the dash's live⇄landed **⌃t** toggle. |
| [`/fleet-new-issue`](fleet-new-issue.md) | steward | File a new issue in this fleet's repo from a task brief, then spawn a worker window (`issue-<N>` worktree + `claude`, bound via `@issue`) to implement it. **Thin inline file-and-spawn:** guard → dedup → live milestone best-fit → thin title + one-line brief → create → spawn → report, no code reading and no sub-agent — the spawned worker grounds the thin issue itself (via `/fleet-claim`). |
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

### Create skills: auto-categorize from the LIVE milestone list

A kind-A skill that **files** an issue (`/fleet-new-issue`) also assigns a
best-fit **milestone** — the fleet's component categories. Fetch them at file
time — never hardcode, since the user adds/renames/closes them: `gh api
"repos/$FLEET_REPO/milestones?state=open" --jq '.[].title'`, pick the one title
that best fits the task, and pass only a title that came back from that live
list. When nothing clearly fits (or there are no open milestones), file with
**no** milestone — never force a wrong/stale name (a bad `--milestone` fails the
create). `/fleet-new-issue` does this and notes the choice in its report.

> **A note on inline vs. delegated work.** Most kind-A skills run their whole
> playbook inline on the caller's thread, which is right when the work is cheap
> (`/fleet-claim` posts a comment; `/fleet-new-issue` fires a handful of `gh`
> calls). `/fleet-new-issue` used to offload its body to a background sub-agent
> to keep the steward's turn short, but its grounding step was removed (the
> spawned worker grounds itself), so the thin inline path is fast enough to not
> need one. If a future steward skill does something genuinely expensive inline,
> the sub-agent-proxy shape is available — guard inline and fail-fast first, then
> launch one self-contained `general-purpose` agent (not a fork) with every rail
> baked into its prompt and a one-line output contract to relay back.

## The contract every fleet skill follows

> This section describes **kind A** (interactive/role skills). For **kind B**
> (background-job prompts) see *Two kinds of fleet skill* above.

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
