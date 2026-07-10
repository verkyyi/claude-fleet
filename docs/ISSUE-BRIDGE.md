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
2. **marker** — the comment is **suppressed** if its body carries
   `<!-- fleet:no-relay -->`. Feed-by-default: only fleet-internal-not-for-worker
   comments are marked (see *Loop-safety* below).
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
worker's own progress comments would loop back into itself.

The fix is a **marker convention**, not an author filter:

- Every fleet-internal comment (worker progress, PR links, steward record notes)
  is posted through **`bin/fleet-comment.sh`**, which stamps
  `<!-- fleet:no-relay -->` (an invisible HTML comment). The bridge suppresses
  those.
- A comment **meant** to drive the worker is posted with
  `fleet-comment.sh <issue> --to-worker` (left unmarked → relayed once), or by an
  external human (unmarked by default → relayed, subject to the gate).
- Dedup on comment id is the backstop if a marker is ever forgotten.

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
label: the autofill dispatcher excludes that label so it can't auto-spawn a worker
on the control issue. The steward route reuses the whole relay pipeline unchanged:

- **same gates** — `author_association` floor, the `<!-- fleet:no-relay -->`
  marker, dedup. The steward posts its own record notes through
  `bin/fleet-comment.sh` (marked no-relay), so its comments on its **own** control
  issue never loop back into it.
- **idle-gate (+ staleness escape)** — the steward is the only Claude session in
  the `plan` window, so its window `@claude_state` is the gate: a comment lands
  only when the steward is **not** `working`; a busy steward's comment is queued to
  a later tick. The `plan` window's `#{window_activity}` is kept fresh by the
  co-resident dash pane, so the spinner's stuck-working demote never fires there —
  to stop a **missed `Stop` hook** wedging the channel forever, a `working` state
  whose `@claude_state_ts` is older than `FLEET_STUCK_WORKING_SECS` is treated as
  stale and relayed anyway. The same **input-content check** as a worker applies:
  the operator types into the `@steward` pane too, so an idle steward whose input
  row holds an un-submitted line defers the relay rather than prepending onto it
  (issue #191) — and, like the worker gate, that defer is **bounded** by
  `FLEET_BRIDGE_MAX_TYPING_DEFERS` (issue #195) so a persistently non-empty read
  can't silently wedge the control channel.
- **hub-down drops (no revive)** — if no `@steward` pane exists (the hub isn't
  running / is misconfigured) the wake-comment is **dropped terminally**, exactly
  like a worker's revive-off *gone*. Retrying instead would pin the repo watermark
  forever and — since the comment fetch is a single non-paginated page — eventually
  starve **worker** relays on that repo, a silent repo-wide failure far worse than a
  lost wake. The comment still lives on the durable issue thread; re-comment once
  the hub is up. (A present-but-*stuck* steward is handled by the staleness escape
  above, so this path is genuinely "no pane", not "busy".)

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
