# claude-fleet — fresh PR/issue/CI status via `gh webhook forward` (no public endpoint)

The dash and status bar learn of "CI went green" / "PR merged" / a new issue only
when the pollers next tick — the collector (~60s, issues) and pr-refresh (~15s,
PR/CI). That is exactly the moment the steward is watching a PR go green (to review
/ land) and the cleanup daemon is waiting to reap it. The **webhook daemon**
(`bin/fleet-webhook.sh`, `com.claude-fleet.webhook`) makes those edges near-instant
(~1s) by wiring GitHub's real-time webhook stream to the SAME single-writer
refreshers — with **no public endpoint**.

OFF by default (issue #315). A fleet opts in with `FLEET_WEBHOOK=1`.

## Why `gh webhook forward` (no endpoint)

There is no `gh` push/stream API; GitHub's only real-time push is webhooks, which
normally need a public URL (ngrok / cloudflared / an exposed HMAC endpoint).
**`gh webhook forward`** (the `cli/gh-webhook` extension) avoids all of that: it
registers the repo webhook against **GitHub's own hosted relay**, then the running
process **pulls deliveries over an authenticated channel (your `gh` token)** and
re-POSTs each to a **localhost** URL. No tunnel, no inbound port, no HMAC endpoint
exposed to the internet.

**Prerequisite:** `gh extension install cli/gh-webhook` (registers a repo webhook —
needs repo admin, which the operator has). `gh` ≥ 2.91 is fine.

## Shape — one KeepAlive supervisor (like the spinner)

```
com.claude-fleet.webhook  (KeepAlive supervisor)
├── one local handler        http://127.0.0.1:<port>   (python3)
└── one `gh webhook forward`  per opted-in LIVE fleet repo  ──► that same --url
        gh webhook forward --repo <owner/repo> \
          --events pull_request,check_run,check_suite,status,issues \
          --url http://127.0.0.1:<port>
```

- The supervisor fans out over **every live fleet** (like `fleet-watch.sh` iterates
  the sockets/confs), deduped **per repo** — a single forward per repo, even if two
  sessions serve it. Dead forwards are auto-restarted each rescan; a repo that opts
  out or whose fleet goes down has its forward reaped.
- The handler binds to **127.0.0.1 only**. It is threaded, so a slow kick never
  head-of-line-blocks the next delivery, and it ACKs `200` immediately.

## The handler TRIGGERS a targeted refresh — it never writes a cache

This is the load-bearing rail. `tmux-pr-refresh.sh` is the **single writer** of
`prmap`/`@prci` and the collector **owns** `issues_<slug>` (issues #180/#81). The
handler routes each delivery, by the repo in its payload, to the right owner:

| Event | Kick | Effect |
|---|---|---|
| `pull_request`, `check_run`, `check_suite`, `status` | `tmux-pr-refresh.sh --repo <repo>` | force-refresh that repo's PR/CI map NOW |
| `issues` | `tmux-dash-collect.sh --issues <repo>` | force-refresh that repo's issues/labels cache NOW |

Both targeted modes narrow the fetch to the ONE repo in the payload and bypass the
poll TTL (the kick wants it now), but run the exact same fetch code the pollers do —
so the write-side ownership is unchanged and there is no double-writer race.

## Polling stays the BACKSTOP

pr-refresh (~15s) + the collector (~60s) keep running. A missed delivery, a dead
forward process, or a relay hiccup can therefore only cost **freshness**, never
**correctness** — the next poll tick still repaints. The webhook is a freshness
optimization, not a replacement.

## Surviving sleep → wake

On host **sleep** a `gh webhook forward` dies but the **relay hook it registered
lingers**, and no deliveries replay for the gap. Three things restore fresh status
fast after wake — with no manual intervention:

1. **Reap the orphaned hook before each (re)spawn** (issue #391). The lingering
   hook would make the fresh forward's create `422 "Hook already exists"` and
   crash-loop; the supervisor deletes any hook whose `config.url` host is the relay
   (a user's own webhook, different host, is left untouched) so the recreate is
   clean. The restart also backs off exponentially (capped) so a persistent create
   failure can't hot-loop.
2. **Wake-triggered reconcile** (issue #410). Bash has no monotonic clock, so the
   supervisor idles between rescans in short `FLEET_WEBHOOK_WAKE_TICK`-second chunks
   and infers a host suspend from the **wall-clock gap** across a chunk (a chunk that
   overran its sleep by ≥ `FLEET_WEBHOOK_WAKE_SLACK` seconds = the host slept). On
   detecting it, it clears any backoff deadline and reconciles **immediately** —
   reconnect lands within ~a tick of wake instead of up to a full `RESCAN` later.
3. **Catch-up on every (re)connect** (issue #410). `gh webhook forward` never
   replays what fired while it was down, so each (re)spawn is paired with **one kick
   of both single-writers** — `tmux-pr-refresh.sh --repo <repo>` +
   `tmux-dash-collect.sh --issues <repo>` — reconciling whatever changed during the
   gap the instant the forward is back. This is the piece that closes the
   "missed during sleep" hole; the pollers remain the backstop for anything else.

Keeping the WS alive *during* sleep is physically impossible; fast restore + catch-up
covers it.

## Storm coalescing

A single CI run fires many `check_run`/`status` deliveries per PR. The handler
debounces per `(event-class, repo)`: a kick for the same pair fired < `DEBOUNCE`
seconds ago is skipped (the poll backstop still catches anything dropped). Default
3s; `FLEET_WEBHOOK_DEBOUNCE=0` disables it.

## Enable it

Per fleet, in `~/.config/claude-fleet/<session>.conf` (or the global `fleet.conf`):

```sh
FLEET_WEBHOOK=1
# optional (global): FLEET_WEBHOOK_PORT (default 8917), FLEET_WEBHOOK_SECRET (HMAC)
```

Install the extension + the daemon (macOS launchd shown; Linux systemd is the
always-on `claude-fleet-webhook.service` — see `systemd/README.md`):

```sh
gh extension install cli/gh-webhook
# substitute __HOME__ + __BREW_PREFIX__ like the other plists, then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude-fleet.webhook.plist
```

## Security notes

- The handler binds to **localhost only**, so an unauthenticated delivery can at
  worst cause a spurious **local** refresh — never a cache write of its own, never
  anything outbound. That is why the HMAC is **optional** here (contrast the
  issue-bridge `--deliver`, which drives a bypass-permissions worker and MUST
  verify).
- For defense-in-depth on the relay→localhost hop, set `FLEET_WEBHOOK_SECRET`: it is
  passed to `gh webhook forward --secret` and the handler verifies the
  `X-Hub-Signature-256` header (the same HMAC check as the issue-bridge).
- `gh webhook forward` is marketed as a local-dev tool; running it as a persistent
  daemon is slightly off-label. The relay is GitHub-hosted (reliable), and the
  supervisor auto-restarts a forward that dies + the polling backstop covers any gap.

## Tunables

| Env (per-fleet conf / global `fleet.conf` / environment) | Scope | Default | Meaning |
|---|---|---|---|
| `FLEET_WEBHOOK` | fleet | `0` (off) | `1` to forward this fleet's repo |
| `FLEET_WEBHOOK_PORT` | global | `8917` | localhost port the handler binds + forwards target |
| `FLEET_WEBHOOK_SECRET` | global | — | optional HMAC secret (`--secret` + verify) |
| `FLEET_WEBHOOK_EVENTS` | env | `pull_request,check_run,check_suite,status,issues` | events forwarded |
| `FLEET_WEBHOOK_RESCAN` | env | `30` | supervisor rescan cadence (seconds) |
| `FLEET_WEBHOOK_WAKE_TICK` | env | `5` | wake-detect chunk granularity (seconds); reconnect lands ≤ ~this after wake (clamped to `RESCAN`) |
| `FLEET_WEBHOOK_WAKE_SLACK` | env | `5` | a sleep chunk overrunning by ≥ this many seconds is treated as a host suspend (above jitter, below a real sleep) |
| `FLEET_WEBHOOK_DEBOUNCE` | env | `3` | per-(event,repo) kick debounce, seconds (0 disables) |
| `FLEET_WEBHOOK_STATE_DIR` | env | `~/.config/claude-fleet/webhook` | forward pidfiles + debounce state |

## Post-land (this repo's own tooling)

claude-fleet's own daemons need a live-install re-apply after landing: sync the
merged files and install the new daemon (`launchctl`/`systemctl`), plus
`gh extension install cli/gh-webhook`. The steward handles the sync + daemon install
separately (see the auto-land + sync-install flow).

## Verify

```sh
# hermetic logic test (fake refreshers/forwards — no gh, tmux, or network):
bash ~/.claude/fleet/bin/fleet-webhook-selftest.sh

# route ONE fake delivery by hand → see which refresher it kicks:
printf '{"repository":{"full_name":"OWNER/REPO"},"pull_request":{"number":1}}' \
  | bash ~/.claude/fleet/bin/fleet-webhook.sh --route --event pull_request

# which repos would be forwarded (opted-in, live):
bash ~/.claude/fleet/bin/fleet-webhook.sh --desired
```
