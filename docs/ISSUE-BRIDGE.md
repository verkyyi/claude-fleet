# claude-fleet — issue-as-event-bus (the issue-bridge)

> Answers issue #132: *"make the GitHub issue the single event-bus /
> collaboration layer for a worker session."*

A worker is bound one-to-one to a GitHub issue (`@issue`). The **issue-bridge**
turns a comment on that issue into the worker's **next turn** — so the issue
thread becomes the single durable, auditable channel for driving a worker:

- **steward → worker** — the steward comments a handback instead of a flaky
  `tmux send-keys`.
- **external collaborator / teammate → worker** — anyone GitHub trusts
  (`author_association`) can nudge the worker by commenting.
- **worker → steward** — already exists, via the PR + issue comments.

One shared daemon (`com.claude-fleet.issue-bridge`, like `pr-refresh` — NOT
per-worker) receives comments and injects the qualifying ones.

It is **opt-in and OFF by default** (`FLEET_ISSUE_BRIDGE=1` per fleet). A relayed
comment becomes autonomous tool-use in a bypass-permissions worker, so **treat a
relayed comment as remote code execution** — the `author_association` gate is the
headline control, and un-gated relay on a **public** repo is unsafe.

## The relay pipeline

For every new comment the bridge decides, in order:

1. **dedup** — a comment id handled once is never re-injected (GitHub redelivers
   on any non-2xx; the poll and webhook ingresses can overlap).
2. **self / marker** — the comment is **suppressed** if it is fleet-internal, by
   *either* signal: (a) its body carries `<!-- fleet:no-relay -->` (the intent
   flag), or (b) it is the bound worker talking to itself — a
   `<!-- fleet:from role=worker … issue=<N> -->` provenance marker whose issue
   equals the comment's own issue (the positive self-ID backstop). Feed-by-default:
   an external human's unmarked comment relays. See *Loop-safety* below.
3. **gate** — relay only from a **trusted `author_association`** (default floor
   `OWNER MEMBER COLLABORATOR`, via `FLEET_ISSUE_BRIDGE_ASSOC_FLOOR`). `NONE` /
   `CONTRIBUTOR` are never relayed.
4. **target + idle-gate** — resolve the worker window bound to the issue
   (`@issue`) and inject **only when it is idle** (`@claude_state` ≠ `working`);
   a busy worker's comment is queued to a later tick. The idle-gate also
   inspects the pane's **input line**: a human typing an un-submitted line does
   **not** flip `@claude_state`, so the bridge `capture-pane`s the pane, finds the
   `❯`-anchored input row, and if it holds **real typed text defers** the relay too
   (issue #191) — otherwise the paste would prepend onto the partial and submit the
   merged line. "Real" is cursor/style-aware (issue #199): Claude draws a **dim
   "ghost" autosuggestion** in that same row when the input is empty, so text counts
   only if it sits to the **left of the cursor** (a ghost never enters the buffer,
   so the cursor stays parked at input-start) **or** is **not faint-styled** (the
   ghost is dim, SGR 2) — otherwise a ghost would be misread as a half-typed line
   and defer forever. A parse-miss (no input row / cursor resolvable) falls back to
   delivering, so a bad read never wedges the queue. That defer is also **bounded**
   (issue #195): after `FLEET_BRIDGE_MAX_TYPING_DEFERS` *consecutive* typing-defers
   of the same comment the bridge delivers anyway and logs a WARNING — so a row that
   reads non-empty *persistently* (a stuck render, a future TUI placeholder the
   ghost/faint heuristics don't catch) degrades to delivery, not a silent dead
   channel. The per-comment counter resets the instant the input clears, so a
   genuine multi-minute pause is respected. Injection is a two-step bracketed
   **paste** + a **separate Enter** (the send-keys/bracketed-paste gotcha eats an
   inline Enter and would submit a multi-line body early).
5. **revive** *(opt-in `FLEET_ISSUE_BRIDGE_REVIVE=1`)* — if the issue is **open**
   but its worker window is gone, re-spawn it (`dash-issue-session.sh`); the
   fresh worker's `/fleet-claim` re-reads the issue, comment and all. A
   closed/landed issue is left alone (resume via #130 is a follow-up).

## Loop-safety (the shared-identity problem)

The worker and the steward both act as the repo `OWNER`, so **author-filtering
cannot tell them apart** — if the bridge relayed every OWNER comment, the
worker's own progress comments would loop back into itself. So the bridge decides
self-vs-3rd-party by **marker**, not by author:

- Every fleet-internal comment (worker progress, PR links, steward record notes)
  is posted through **`bin/fleet-comment.sh`**, which stamps
  `<!-- fleet:no-relay -->` (an invisible HTML comment). The bridge suppresses
  those. This is the **intent flag** — "don't drive a worker with this."
- A comment **meant** to drive the worker is posted with
  `fleet-comment.sh <issue> --to-worker` (left unmarked → relayed once), or by an
  external human (unmarked by default → relayed, subject to the gate).

### The positive self-ID backstop (issue #425)

The no-relay flag is a *convention*: it works only as long as every fleet-internal
write goes through `fleet-comment.sh`. A worker's own comment posted some other way
— a raw `gh issue comment`, a future tool that forgets the wrapper — carries no
flag, so it looks exactly like a 3rd-party OWNER comment and would be **relayed
back into that worker once**. Dedup does **not** cover this: it only suppresses the
*second* delivery of a comment id, never the *first*, so the spurious self-turn
still fires.

So the bridge also reads the **provenance** marker `fleet-comment.sh` already
stamps — `<!-- fleet:from role=… session=… issue=<N> -->` — and suppresses a
comment whose marker is `role=worker` with an `issue=<N>` **equal to the issue it
is being relayed to**. That is, definitionally, the bound worker talking to
itself — flag or no flag. It is scoped tightly so nothing legitimate is caught:

- **steward `--to-worker`** carries `role=steward` (and the steward hub pane has no
  `@issue`, so its marker has no `issue=` field at all) → not matched → still relays.
- an **external human** has no `fleet:from` marker → not matched → relays.
- a **cross-worker** comment (worker A driving worker B's issue) has `issue=A` ≠ B
  → not matched → relays.
- the `issue=` compare is space-anchored, so `issue=10` never matches `issue=100`.

Because suppression is the **safe** direction — a comment that isn't relayed can't
drive a worker — this backstop can only ever make a comment *more* suppressed,
never bypass the trust gate to relay something. (A 3rd party who pastes a fake
`fleet:from` marker only gets their *own* comment dropped; they can't smuggle a
relay.) So it runs **before** the association gate, ungated. Dedup on comment id
remains the last-ditch guard against a comment being *re-*delivered.

```sh
# steward hands work back to the worker (relayed):
fleet-comment.sh 132 --to-worker --body "rebase on master and re-push"
# fleet records a note for humans (NOT relayed):
fleet-comment.sh 132 --note --body "landed in a train with #130"
```

## Steward control issue (the wake / async channel)

> Answers issue #146.

A worker is reachable because it is bound to an issue (`@issue`). The **steward**
lives in the `plan` hub — a pane with **no `@issue`** — so the bridge has no route
to it by default. Give the steward its own long-lived **control / inbox issue** and
it becomes a bridge endpoint like a worker: a comment on that issue is relayed
**into the `@steward` pane** as its next turn. That buys you

- an **operator ↔ steward async channel** — comment from anywhere (phone, laptop,
  a teammate) and the steward takes a turn, no attached tmux client required;
- an **event sink** for a fleet watcher (a daemon can comment to wake the steward);
- a durable **audit log** of wake-events + steward decisions, on one issue thread.

Bind it per fleet with **`FLEET_STEWARD_ISSUE`** (its issue number):

```sh
# in ~/.config/claude-fleet/<session>.conf (or global fleet.conf):
FLEET_ISSUE_BRIDGE=1
FLEET_STEWARD_ISSUE=146      # a long-lived, non-closing control issue for THIS fleet
```

Create **one non-closing issue per fleet** (e.g. titled `🛰 steward · <fleet>`,
label `steward-control`) and record its number. It is a **dedicated bridge
endpoint, never a worker task** — a comment on it always routes to the steward, so
it must not also be a backlog issue a worker binds to. Give it the `steward-control`
label: the spawn-eligibility filters exclude that label so a worker is never spawned
on the control issue. The steward route reuses the whole relay pipeline unchanged:

- **same gates** — `author_association` floor, the `<!-- fleet:no-relay -->`
  marker, dedup. The steward posts its own record notes through
  `bin/fleet-comment.sh` (marked no-relay), so its comments on its **own** control
  issue never loop back into it.
- **its own channel + watermark (issue #198)** — the steward control issue is
  polled on its **own per-issue endpoint** with its **own watermark + seen-set**,
  fully decoupled from the worker relay stream. A busy steward pins **only** the
  steward watermark; worker relays on the same repo advance independently. This
  fixes the head-of-line jam where a continuously-busy steward, holding the single
  shared per-repo watermark, starved unrelated worker relays too — and, because the
  repo-wide comment fetch is a single non-paginated 100-comment page, silently lost
  newer worker comments once >100 comments accrued past the pinned mark.
- **idle-gate (+ staleness escape)** — the steward is the only Claude session in
  the `plan` window, so its window `@claude_state` is the gate: a comment lands
  only when the steward is **not** `working`; a busy steward's wakes are queued to
  a later tick (holding only the steward watermark). The `plan` window's
  `#{window_activity}` is kept fresh by the co-resident dash pane, so the spinner's
  stuck-working demote never fires there — to stop a **missed `Stop` hook** wedging
  the channel forever, a `working` state whose `@claude_state_ts` is older than
  `FLEET_STUCK_WORKING_SECS` is treated as stale and relayed anyway. The same
  **input-content check** as a worker applies: the operator types into the
  `@steward` pane too, so an idle steward whose input row holds an un-submitted line
  defers the relay rather than prepending onto it (issue #191) — and, like the worker
  gate, that defer is **bounded** by `FLEET_BRIDGE_MAX_TYPING_DEFERS` (issue #195, a
  channel-level counter for the coalesced batch) so a persistently non-empty read
  can't silently wedge the control channel.
- **coalesce-on-drain (issue #198)** — when a queue of steward wakes finally drains
  to an idle steward, superseded/duplicate wakes are **collapsed to one line per
  subject** (newest wins) and delivered as a single digest, so the steward wakes to
  **current state** — not a temporal replay of "PR #168 green ×3" or a stale
  "shipped #196" ahead of a fresh "#196 green". The subject of each wake line is
  read from a trailing `<!-- fleet:wake <slug>:<num> … -->` marker that `fleet-watch`
  stamps (subjects aligned, in order, with the `- ` lines); a comment that isn't a
  parseable watcher wake — an operator note — is kept whole and never collapsed. No
  distinct current subject is ever dropped (still at-least-once); only stale
  duplicates are.
- **hub-down holds, not drops (no revive)** — if no `@steward` pane exists this tick
  (the hub is mid-respawn on a `/clear`/restart, or misconfigured) the queued wakes
  are **held** (not marked seen, steward watermark not advanced) and retried next
  tick. Pre-#198 this dropped terminally, because a held *shared* watermark would
  starve worker relays; now the steward channel has its **own** watermark + a
  paginated per-issue fetch, so holding costs only a cheap re-fetch and survives a
  transient absence — a drop would silently lose every queued wake (the watcher's
  edges are deduped, so they never re-fire). A genuinely down/misconfigured hub just
  re-holds each tick until it comes back. (A present-but-*stuck* steward is handled by
  the staleness escape above, so this path is genuinely "no pane", not "busy".)

Routing is by issue number: a comment whose issue **is** the repo's
`FLEET_STEWARD_ISSUE` goes to the steward; everything else routes to the bound
worker exactly as before. A same-numbered control issue in another fleet never
collides — the pane is matched to the repo by the same slug logic worker routing
uses.

## Ingress A — poll (default, no inbound port)

The daemon lists new issue comments across every enabled fleet's repo via
`gh api` with a `since` watermark. Reads are effectively free (conditional /
`since` requests), so a ~15s tick is cheap. This is the robust default — nothing
to expose, no secret required. It is installed as `com.claude-fleet.issue-bridge`
(launchd `StartInterval=15`) or the `claude-fleet-issue-bridge.timer` on Linux.

Per repo the tick runs **two independent channels** (issue #198), each with its
own `since` watermark + dedup seen-set so neither can head-of-line-block the
other: a **worker** channel (the repo-wide comment stream minus the steward
control issue) and a **steward** channel (the control issue's own per-issue
stream, coalesced on drain — see above). Per fleet (issue #181) the channel state
lives at `~/.config/claude-fleet/fleets/<session>/bridge/` as `{since,seen}`
(worker) and `{steward.since,steward.seen}` (steward), with the legacy flat
`bridge_<slug>.*` under `FLEET_ISSUE_BRIDGE_STATE_DIR` dual-read as a fallback.

Enable it per fleet:

```sh
# in ~/.config/claude-fleet/<session>.conf (or global fleet.conf):
FLEET_ISSUE_BRIDGE=1
```

## Ingress B — webhook (`--deliver`, sub-second latency)

For instant delivery, forward GitHub `issue_comment` events to the bridge's
`--deliver` mode, which validates an HMAC and relays the single comment. The
fleet host is a 24/7 Mac Mini, so either forwarder works:

**`gh webhook forward`** (simplest — no home-network port-forwarding, authed via
`gh`):

```sh
# pipe each delivery into --deliver, passing the signature header through:
gh webhook forward --repo OWNER/REPO --events issue_comment \
  --url 'http://localhost:9899/' &
# a tiny receiver (any HTTP server) hands the raw body on stdin + the
# X-Hub-Signature-256 header to:
FLEET_REPO=OWNER/REPO \
FLEET_ISSUE_BRIDGE_SECRET="$SECRET" \
FLEET_DELIVERY_SIG="$HTTP_X_HUB_SIGNATURE_256" \
  ~/.claude/fleet/bin/fleet-issue-bridge.sh --deliver < delivery.json
```

**cloudflared** — a named tunnel to a standalone public endpoint if you want a
stable URL independent of `gh`.

Either way: create the repo webhook with a strong **secret**, set
`FLEET_ISSUE_BRIDGE_SECRET` to it, and pass the delivery's `X-Hub-Signature-256`
header as `FLEET_DELIVERY_SIG`. `--deliver` refuses any delivery whose HMAC does
not match — this is what guarantees **only GitHub** can drive a worker over the
webhook path.

The webhook and the poll daemon share the same dedup state, so you can run both
(webhook for latency, poll as the backstop if the tunnel drops).

## Cost

There are **no GitHub fees** — the cost is **tokens**: each relayed comment is
one real worker LLM turn. Comment *writes* are bounded by GitHub's content
secondary limit (~500/hr); reads/polling are effectively free. Keep the trusted
set tight and don't wire a chatty bot to comment on bound issues.

## Config knobs (see `fleet.conf.example`)

| Knob | Default | Meaning |
|---|---|---|
| `FLEET_ISSUE_BRIDGE` | `0` | per-fleet opt-in |
| `FLEET_ISSUE_BRIDGE_ASSOC_FLOOR` | `OWNER MEMBER COLLABORATOR` | trusted authors (verbatim GitHub values) |
| `FLEET_ISSUE_BRIDGE_SECRET` | *(unset)* | webhook HMAC secret (`--deliver` only) |
| `FLEET_ISSUE_BRIDGE_REVIVE` | `0` | re-spawn a gone worker for an open issue |
| `FLEET_BRIDGE_MAX_TYPING_DEFERS` | `20` | consecutive typing-defers before a relay is delivered anyway (≈5 min at 15s poll, issue #195) |
| `FLEET_STEWARD_ISSUE` | *(unset)* | control/inbox issue relayed into the `@steward` pane (#146) |
| `FLEET_ISSUE_BRIDGE_STATE_DIR` | `~/.config/claude-fleet/issue-bridge` | legacy flat watermark+dedup dir. Since issue #181, state lives per fleet at `~/.config/claude-fleet/fleets/<session>/bridge/{seen,since}`; this dir is only the fallback for a repo with no configured fleet, and is dual-read until `bin/fleet-migrate-layout.sh` moves it |

## Verify

```sh
# hermetic logic test (fake gh/tmux — no network):
bash ~/.claude/fleet/bin/fleet-issue-bridge-selftest.sh
# one poll tick by hand (needs a fleet with FLEET_ISSUE_BRIDGE=1 + gh auth):
bash ~/.claude/fleet/bin/fleet-issue-bridge.sh --poll
# then comment `--to-worker` on a live worker's issue and watch it take a turn.
```
