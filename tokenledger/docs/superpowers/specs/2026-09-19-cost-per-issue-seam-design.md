# Cost per issue, step one: the seam on the spend side — design

Date: 2026-09-19. Status: proposed for #57, under EPIC #46 (reserve layer).
Supersedes nothing. Blocks #58 (the issue-axis view), which cannot start until
a spend row can name an issue at all.

Read this before the code. Every decision below is meant to be arguable, and
§2.3, §4 and §5 are the three an operator should push back on if any of them
is wrong.

## 1. What is actually missing

`internal/store/schema.sql:359` says the issue number is "the same key [that]
makes cost-per-issue answerable". That is a statement of intent. The connection
does not exist:

- `usage_events` and `usage_hourly` carry `git_branch`
  (`schema.sql:170`, `schema.sql:288`) and **no issue column**.
- `repo_issues` (`schema.sql:373-396`) carries no session, no account and no
  cost, and deliberately no `account_uuid` (`schema.sql:361-367`).
- No query in `internal/store` joins the two sides.

So the hub answers "which issues are stalled, how fast does this repo close"
and cannot answer "what did issue #34 cost" at all. This document is the first
half of closing that: **where an issue number comes from, what it is attached
to, and what it says when it does not know.** It does not design the view —
that is #58 — and it does not touch the repo ingest protocol.

## 2. Where the issue number comes from

### 2.1 The three candidates

| candidate | available today? | what it costs |
|---|---|---|
| **branch name** (`git_branch`) | **yes**, on both tables and both sources | nothing — the column is already there |
| session binding (orchestrator knows session → issue) | no | a new declaration on the usage ingest |
| commit message | no | the hub holds no commits |

The branch is free because the hub never reads git: it stores what the reporter
already recorded. Claude events copy the transcript's own `gitBranch` verbatim
(`internal/scan/parse.go:27,104`); Codex events take `session_meta.git.branch`
(`internal/scan/codex.go:75,230`). There is no `exec.Command("git", …)` anywhere
in `internal/`, and this design does not add one.

The session binding is strictly better data — an orchestrator knows the repo,
the issue *and* the session — but it is orchestrator-specific and needs a
protocol change. The commit message arrives after the fact and binds a commit,
not a turn of spend; `repo_issues.shipped_ref` already covers what it can say.

Step one therefore reads the branch. §6 says what step two is.

### 2.2 Measured: what branch names actually look like

Method: the corpus the collector itself reads — every `*.jsonl` under
`~/.claude/projects` on this machine — counting the lines that carry a `usage`
block (the same lines `scan/parse.go` turns into events) and the `gitBranch`
each one records. **420,237 events, 2,415 distinct branch values.**

This is one machine running mostly one team's branch convention. A different
team would show a different mix, and §2.3 is written so that this does not
matter: the rule is a declared convention, not a claim about all repositories.

| shape | events | share | distinct |
|---|---|---|---|
| `issue-<N>` | 149,109 | **35.48%** | 707 |
| `issue-<N>-<slug>` | 4,210 | **1.00%** | 62 |
| no digit at all (`main`, `master`, feature slugs) | 160,356 | 38.16% | 1,157 |
| `scratch-<N>` | 65,722 | 15.64% | — |
| `HEAD` (detached) | 29,892 | 7.11% | 1 |
| `<type>/<N>-<slug>` | 6,783 | 1.61% | 22 |
| `worktree-<hex>` | 3,022 | 0.72% | — |
| `gitBranch` absent or empty | **0** | 0.00% | 0 |

Two things to read off it.

**The miss rate is high, and that is the acceptable half.** An anchored
`issue-<N>` rule reads **36.48%** of events. The other 63.52% is genuinely not
attributable: 38.16% of events carry no number anywhere in the branch, and
7.11% are `HEAD`, which is what a worktree checked out at a SHA looks like.
No rule recovers those; they are work whose branch never said what it was for.

**The false-positive rate is the half that must be zero.** A rule of "the first
integer anywhere in the branch name" would claim another 25.4% of events, and
the largest family inside it is `scratch-<N>` at **15.64%** — fleet scratch
sessions, where `N` is a session ordinal. Those checkouts sit in a repository
whose issues run from #1 to #7,625, so `scratch-104` resolves to a real issue
#104, in the right repository, describing the wrong work. Nothing downstream
can tell such a row from a correct one.

The trap is not limited to the obviously-wrong family. `<type>/<N>-<slug>` is
the shape that looks safe, and 21 of its 22 branches are honest conventional
branches (`fix/594-handoff-preserves-loop`, `chore/2391-reseed-corpus`). The
twenty-second is `release/2026-09-02-aicall-box` — 116 events that a
first-integer rule files under issue **#2026**, which also exists. 1.7% of that
family, plausible, and indistinguishable after the fact.

### 2.3 Decision

The rule is anchored on the whole branch name:

```
^issue-([0-9]+)(?:-.*)?$
```

- **`<type>/<N>-<slug>` is not taken in step one.** It buys 1.61% more coverage
  at a measured 1.7% wrong-and-plausible rate inside that coverage. A team that
  wants it should say so deliberately, as its own change, with its own evidence.
- **The rule is a declared convention, not a truth about repositories.** A team
  that names branches differently gets 0% attributed and an honest empty answer
  — never a guessed one. This is the same stance the repo already takes on
  close-time thresholds: they come from the repository, never from a default
  baked into the hub.
- A leading zero, a number that overflows, or a bare `issue-` matches nothing
  and is unattributed. No normalisation, no trimming, no case folding: a rule
  you cannot state in one line is a rule nobody can audit.

## 3. Which layer it binds to

Both tables, with `usage_hourly` the durable one.

- The issue number is a **pure function of `git_branch`**, which is already
  column 9 of `usage_hourly`'s 13-column primary key (`schema.sql:307-308`).
  Adding `issue_number` as an ordinary column therefore adds **no grain**: no
  new hourly rows, no primary-key change, and none of the rename-recreate-copy
  dance that `provider_migration.go` needs. A plain `ALTER TABLE ADD COLUMN`
  through the existing `migrate()` list (`internal/store/store.go:98-136`)
  covers every existing database.
- `usage_events` is bounded by `--retention-days`; `usage_hourly` is kept
  forever. #58 wants "what did this issue cost between open and close", and
  issues outlive the raw ledger, so the permanent table is the one that has to
  carry the answer.
- Because the number is derived from a column that stays on the row, a change
  to the rule can be **re-derived in place** on both tables. It never needs raw
  events that retention may already have pruned.

That last point is why the rule version is **not** folded into `rollupVersion`.
Bumping that constant forces a rebuild of `usage_hourly` from `usage_events`,
which refuses outright on pruned history (`unreconstructableRowsError`,
`rollup.go:83-89`) — a rule tweak would become an operator incident. A separate
`rollup_meta` key plus an `UPDATE … WHERE git_branch = ?` per distinct branch
is cheaper and cannot fail that way.

## 4. Saying "I do not know"

- **`issue_number INTEGER`, NULL when unattributed. Never 0.** This is the
  precedent `cost_usd` already sets three lines above it in the same table
  (`schema.sql:164-166`): "NULL means the model is not in the pricing table.
  Never 0 — that would claim the work was free." Zero is a value; NULL is the
  absence of one, and only one of them survives being summed by accident.
- **No `issue_source` column in step one.** *Why* a row is unattributed is
  already on the row: `git_branch` stays, so the unattributed bucket breaks
  down into `HEAD` / `scratch-<N>` / `main` for free. A column whose only
  possible value is `'branch'` states nothing. It earns its place the day a
  second origin exists (§6), and adding it then is another one-line `ALTER`.
- **The rule version is recorded**, as `rollup_meta['issue_rule_version']`. A
  changed rule re-derives every row, and the stored version says which rule
  produced the numbers now in the table.
- **The invariant every consumer inherits: attributed + unattributed = total,
  and the unattributed share is always shown.** On the corpus above it is
  **63.52%** of events. A chart that quietly drops it is not slightly off; it
  is off by a factor of three, and it is off in the flattering direction.

## 5. Cross-repo: the number is deliberately repo-less

`repo_issues` is keyed `(repo, number)` (`schema.sql:395`). A branch name
carries the number and nothing else.

The only repo-shaped thing on the spend side is `cwd`, a local filesystem path,
and it is not a repository identity:

- **one repo, many paths** — this fleet gives every issue its own worktree
  (`…/tokenledger-issue-57`), so one repository appears under dozens of paths;
- **one repo, changing paths** — ccquota was renamed TokenLedger in #7, and
  both checkouts still exist on this machine as two paths for one GitHub repo;
- **no owner anywhere** — `owner/name` does not appear on the spend side at
  all, in any column, from either source.

Measured: four repository checkouts on this machine use `issue-<N>` branches
(24haowan-monorepo 129,605 events; claude-fleet 9,674; tokenledger 1,318;
ccquota 1,103). Across 714 distinct issue numbers, **zero** collide between
them today — but that is arithmetic luck, not a property. The monorepo is past
#7,600, the fleet past #690, this repo is at #70, and every one of them started
at #1. Meanwhile the hub itself currently holds exactly **one** repository
(`list_repos`: `GuangZhouShanyouGame/24haowan-monorepo`, 3,097 issues), so a
number-only join is correct today and silently wrong the day a second shipper
enrolls.

**Decision, and it is the mirror image of the rule directly above it in the
schema.** Repo rows carry no account because a repository is not owned by a
subscription. Spend rows carry no repo because **the hub was never told which
repository a `cwd` is**. Stamping one on would be the same guess presented as a
fact, in the other direction.

So step one stores the bare number, and the *read* — #58's, not this PR's — is
gated:

1. A cost-per-issue read takes a **required `repo`**, exactly as
   `list_repo_issues` already does: a backlog blended across repositories would
   be scaled by one repo's percentiles, and the same sentence holds for money.
2. While the hub holds exactly one repository, that binding is sound and the
   read answers.
3. When the hub holds two or more and nothing on the spend side names one, the
   read **refuses** — `409`, the same answer `/v1/repo/issues?stale=1` already
   gives when no percentiles have been shipped. A confident cost-per-issue
   computed across a number space nobody disambiguated is worse than no answer,
   because a reader cannot tell it from a measured one.

That gate is uncomfortable on purpose. It is also exactly today's state, and it
converts "we might be wrong" into "we will not answer until the binding
exists" — which is the pressure that gets the binding built.

## 6. What step two is (not this PR)

The binding that removes the §5 gate: **the endpoint agent declares the
repository.** It runs inside the checkout, so `git -C <cwd> remote get-url
origin`, resolved once per distinct `cwd` and cached, yields `owner/name` at
the source and travels as one new field on the usage ingest. This does not make
the *hub* shell out to git — the hub keeps storing only what the reporter
recorded, which is the existing stance, not a new exception to it.

The alternative — a session → issue declaration from the orchestrator — is
better data but works only for orchestrators that implement it, whereas a
remote URL exists for every checkout. Either lands as its own issue, after this
seam exists and #58 has shown what the numbers look like.

Explicitly still out of scope, now and then: cost-per-PR, cost-per-merge, and
any change to the repo ingest protocol.

### What step two actually landed (#84)

As designed, with three decisions this section did not pre-empt:

- **The remote URL is read by an anchored rule, like the branch name was.**
  `owner/name` comes only from a URL that names a HOST (`scheme://host/a/b` or
  the scp-like `host:a/b`). A filesystem remote — `/srv/git/repos/app.git` — is
  a real remote naming no repository, and splitting it on `/` yields `repos/app`,
  which is §2.3's fabrication wearing a different hat. So is `group/sub/app`
  truncated to `sub/app`. Both are undeclared instead, and the result is checked
  by the same `model.ValidRepoName` the repo ingest uses, so this side cannot
  emit a key the other side would reject.
- **'' is a third state, not a second one.** Undeclared is not "not this
  repository": it is an older agent, a cwd that is no checkout, and — forever —
  every row written before the column existed, which nothing can fill in
  afterwards because the hub does not read git. Scoping excludes it and the
  response discloses it (`declaration.undeclared`), which is §4's invariant one
  level up: a filter whose discards are invisible reads as "this repository cost
  nothing".
- **The §5 refusal narrowed rather than vanished.** While NOT ONE row declares,
  nothing has changed and §5's answer still stands — the sole-repo hub answers
  whole-hub (`binding: "sole_repo"`), any other hub still gets the 409. Scoping
  there would return a hard zero indistinguishable from a measured one, which is
  the exact failure the refusal existed to prevent.

## 7. What lands with this design

Schema and write path only — no API, no MCP, no UI (that is #58 and R4):

1. `issue_number INTEGER` on `usage_events` and `usage_hourly` (`schema.sql`),
   plus both entries in `migrate()`'s `adds` list for existing databases.
2. The rule as one small, tested pure function, stamped at insert on both the
   event insert and the hourly upsert, and carried through `hourlyFoldSQL`
   (`resolve.go`) so an account merge does not drop it.
3. An in-place re-derivation keyed on `rollup_meta['issue_rule_version']`, run
   on `Open` and at the end of a rollup rebuild — one `UPDATE` per distinct
   branch, never a rebuild from raw events.
4. Tests covering the measured traps by name: `issue-57`, `issue-4059-track-a`,
   `scratch-94`, `HEAD`, `release/2026-09-02-aicall-box`,
   `chore/2391-reseed-corpus`, `main`, and the empty branch.
