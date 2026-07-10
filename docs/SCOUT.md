# Scout task — read-only investigation

> **Optional.** A delegation *shape*, not a daemon — nothing to enable. The
> heavyweight tier needs only `gh`; the lightweight tier needs nothing. Issue #148.

The steward is single-threaded, so doing *research* inline (reading code, greps,
tracing behaviour) ties it up for a long turn and serializes back-to-back
questions. A **scout** lets the steward delegate the *investigation* to a
separate read-only session so its own turn stays short.

A scout is **read-only**: it investigates and **reports**. It never edits the
base checkout, never opens a branch or PR, and self-cleans when done. That is the
whole contract.

## Two tiers, by weight

Pick by how substantial the question is and whether the answer needs to be
durable.

| | **Ephemeral sub-agent** | **Scout worker** |
|---|---|---|
| For | a quick, throwaway lookup | a substantial, trackable investigation |
| How | the steward runs its own `Explore`/`Agent` sub-agent inline | `/fleet-scout <question>` |
| Issue? | **no** | **yes** — a `scout`-labeled issue |
| Window? | **no** | **yes** — a read-only worker window (`@scout`) |
| Result | returns **inline** to the steward | a **comment** on the issue |
| Durable / linkable / bridge-reachable | no | **yes** |
| Converts to ship work | — | **yes** (leave the issue open) |
| Build needed | none (just do it) | the command + read-only spawn path below |

**Rule of thumb:** if the answer is small, one-shot, and you'll act on it
immediately, use the **ephemeral** tier — don't file an issue for it. If the
finding is worth tracking, linking, or following up on (or might become ship
work), use the **scout worker**.

### Ephemeral tier — no build

There's nothing to install. When the steward needs a throwaway answer, it fires
its own `Explore` (read-only search) or `Agent` sub-agent, reads the result, and
moves on. No issue, no window, no cleanup. This is the default for "where is X?"
/ "does Y still exist?" questions that don't deserve a durable record.

## Why an issue for the heavyweight scout

Consistency with the fleet's **"issue = inbox + durable channel"** model: the
scout's report is durable, linkable, and reachable by the issue-bridge (a
follow-up question comment relays in as the scout's next turn — if the issue is
still open and the bridge is enabled), and a good scout finding **converts**
cleanly into a ship issue.

## The scout worker lifecycle

```
steward                worker (read-only, @scout)
───────                ──────────────────────────
/fleet-scout <q>
  ├ ensure `scout` label exists
  ├ gh issue create --label scout      (the durable question + report sink)
  └ dash-issue-session.sh <N> --scout
        │
        └─────────────▶ /fleet-claim        (claim + plan)
                        investigate READ-ONLY (no edits, no branch, no PR)
                        /fleet-scout-report
                          ├ post findings as an issue comment
                          ├ decide: convert-to-ship (leave OPEN) | done (close)
                          └ fleet-scout-clean.sh  (kill window → drop worktree)
```

### `/fleet-scout <question>` (steward)

Files the `scout`-labeled issue and spawns the read-only worker. It ensures the
`scout` label exists first (so `--label scout` can't fail), writes a `Scout:`
issue whose body states the question + "read-only, no PR, findings as a comment",
optionally best-fit-matches a milestone (same live-fetched rule as
`/fleet-new-issue`), then `dash-issue-session.sh <N> --scout`. Obeys the global +
per-fleet session caps — a cap refusal is relayed verbatim, never forced.

### The read-only spawn path — `dash-issue-session.sh <N> --scout`

The same worker-spawn as a normal worker, with a **read-only seed prompt**:
investigate + **report**, do NOT implement — no code edits, no branch, no PR, no
ship mandate. The window is marked `@scout` so its self-clean can assert it's a
scout and tooling can tell "no PR expected" from a normal worker. `--scout`
**supersedes** `--self-land` (a scout has no PR to land). The scout still gets an
`issue-<N>` worktree — a clean, isolated place to *read* the code from; it just
never writes to it. (The base checkout is read-only regardless — hook-enforced.)

### `/fleet-scout-report` (worker) — the closing move

The `/fleet-ship` analogue for an investigation. Posts the findings as an issue
comment (via `fleet-comment.sh --note`, so it never loops back through the
bridge), decides **close vs. leave-open**:

- **converts to ship work** → leave the issue **open**, note "recommend
  converting to ship work" so the steward can spawn a normal worker; self-clean
  without `--close`.
- **done** → **close** the issue as part of teardown (`--close`).

then self-cleans via `bin/fleet-scout-clean.sh`.

### `bin/fleet-scout-clean.sh` — the teardown

A scout has **no PR to merge**, so this is teardown-only — no land lease, no base
pull, no history ledger. It mirrors self-land's **ordered self-destruct**: a
detached `tmux run-shell -b` kills the window **first** (releasing the worktree
cwd the scout's own process holds), then removes the worktree and the
`issue-<N>` branch. `--close` closes the bound issue before teardown.

Its guards make the destructive teardown safe:

- **`@scout`-gated** — refuses on a window not marked `@scout` (a normal worker's
  branch may hold unpushed work). `--force` is the escape hatch for a scout whose
  marker was lost (e.g. after a tmux restart).
- **`branch -d`, not `-D`** — a scout branch sits at base, so the safe delete
  removes it cleanly; but if the scout committed against the prompt, `-d` refuses
  (not merged) and the branch **survives**, preserving that work instead of
  force-discarding it.
- **Never the base checkout** — refuses if run from `$FLEET_MAIN`.
- **Needs a real window-id** — refuses rather than run an ordering-broken teardown
  it can't kill the window for.
- **`--close` needs a repo** — refuses rather than destroy the context and orphan
  the issue open when it can't reach `$FLEET_REPO`.

## Read-only guarantees (why a scout can't go rogue)

- **Prompt** — the seed says investigate + report, no edits/branch/PR, and
  routes the finish through `/fleet-scout-report`, not `/fleet-ship`.
- **Base checkout** — read-only for *every* worker (hook-enforced); a scout adds
  no exception.
- **No land path** — `fleet-scout-clean.sh` has no merge/lease code at all;
  there is no way for it to merge anything, and it refuses to remove the base.
- **Marked** — `@scout` on the window distinguishes it from a normal worker.

## When a finding converts to ship work

Leave the scout issue **open** and let the steward pick it up: relabel it (drop
`scout`, add the component), and spawn a normal worker (`/fleet-new-issue`-style
follow-up or `dash-issue-session.sh <N>` on the same issue once it's a build
task). The scout's comment is the grounding the ship worker starts from.

**Sequencing:** a scout and a ship worker for the same issue share the same
`issue-<N>` worktree, so they can't coexist — let the scout **finish and
self-clean first**, then spawn the worker on the (now window-less) issue. If you
try to spawn the worker while the scout is still alive, the spawn short-circuits
to the live scout and says so ("a live READ-ONLY scout holds it — wait for its
report"), rather than silently focusing a read-only window you expected to
implement.
