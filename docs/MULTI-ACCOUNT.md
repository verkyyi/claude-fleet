# claude-fleet — multiple subscription accounts, with auto-failover

> Answers issue #20: *"how does a fleet support multiple Claude subscription
> accounts, and auto-switch to another subscription when the window limit is
> reached?"*

A busy fleet burns through one subscription's rolling **5-hour window** fast.
This lets you register **several Claude subscriptions** and have the fleet
**fail over to a fresh one** the moment a session hits its limit — so new work
keeps flowing instead of parking until the window resets.

It is **opt-in and off by default**: with no accounts registered, the fleet
uses your single logged-in account exactly as before.

## How account selection actually works (the constraint that shapes this)

Claude Code picks *which* subscription a `claude` process runs under from one of
two places:

- **`~/.claude`** (or `$CLAUDE_CONFIG_DIR`) — holds settings, hooks, transcripts,
  **and on Linux the OAuth token** (`~/.claude/.credentials.json`).
- **the macOS Keychain** — on macOS the OAuth token lives here, and
  `CLAUDE_CONFIG_DIR` does **not** override it.

So "just point each session at a different config dir" **fails on macOS** (same
Keychain token) and, even on Linux, would scatter every session's transcripts
and hooks across N directories — breaking the collector's usage/context reads
and forcing you to merge the fleet hooks into each dir.

The clean lever is an **environment variable**:

```sh
CLAUDE_CODE_OAUTH_TOKEN=<token>  claude …
```

`CLAUDE_CODE_OAUTH_TOKEN` selects the account **per invocation on every OS**,
while every session still shares one `~/.claude`. That means the fleet's hooks,
the collector's `~/.claude/projects` transcript reads, and the usage proxy all
keep working untouched. **That is the whole design.** Each account is just a
token; switching accounts is just switching the env var.

Generate one long-lived token per subscription with:

```sh
claude setup-token      # log in as that subscription → prints an OAuth token
```

(`ANTHROPIC_API_KEY` would also select an identity, but that bills pay-as-you-go
API credits, **not** your subscription — the opposite of what this is for.)

## Setup

1. **Mint a token per subscription.** Log into each account and run
   `claude setup-token`. Do this in a scratch shell / separate machine so you
   don't disturb your primary login.

2. **Drop each token in the accounts dir**, one file per account — **filename =
   label, contents = the token**, mode `600`:

   ```sh
   mkdir -p ~/.config/claude-fleet/accounts
   umask 077
   printf '%s\n' "<token-for-work>"     > ~/.config/claude-fleet/accounts/work
   printf '%s\n' "<token-for-personal>" > ~/.config/claude-fleet/accounts/personal
   chmod 600 ~/.config/claude-fleet/accounts/*
   ```

   **Different windows per account?** Usually you need nothing: the limit banner
   carries the account's own refresh instant (`… · resets 10:20pm
   (America/Los_Angeles)`), and a benched account comes back exactly then — so
   accounts on different tiers, or on the same tier with windows that started
   hours apart, each keep their own schedule for free.

   The duration knob below is the **fallback** for banners that carry no clock
   time (the weekly `resets Monday` form). Give such an account its own bench
   duration with a companion `<label>.conf` next to its token:

   ```sh
   printf 'LIMIT_TTL=7d\n' > ~/.config/claude-fleet/accounts/max20x.conf   # weekly-capped
   printf 'LIMIT_TTL=5h\n' > ~/.config/claude-fleet/accounts/pro.conf      # 5h session window
   ```

   `LIMIT_TTL` takes `<N>[smhd]` or bare seconds; accounts without a `.conf` use
   `FLEET_ACCOUNT_LIMIT_TTL` (default 5h). This stops a weekly-limited account
   from being un-benched every 5h and thrashing straight back into the same wall.
   It only applies when the banner had no instant to parse — a duration is a
   guess, and it is wrong in both directions: too long and the account sits out
   hours past its real refresh (silent idle capacity), too short and it is
   released early into the same wall.

3. **(Optional) tune it in `fleet.conf`:**

   ```sh
   FLEET_ACCOUNTS_DIR="$HOME/.config/claude-fleet/accounts"  # default; override to relocate
   FLEET_ACCOUNTS="work personal"        # pin order/subset (default: all files, sorted)
   FLEET_ACCOUNT_LIMIT_TTL=18000         # FALLBACK bench window (5h), used only when
                                         # the banner carries no "resets …" time
   ```

4. **Verify:** `sh ~/.claude/fleet/bin/fleet-doctor.sh` reports the token count
   and warns on empty or group/other-readable files. `bin/fleet-account.sh list`
   shows the pool, which one is active (`●`), and any that are limited.

That's it — the next session you spawn launches under the active account.

**Switch by hand.** Press `prefix u` to open the usage + account modal — the
account pool is the selectable body under the usage detail (issue #289 merged
the old `prefix A` picker + `prefix u` popup into one; #1100 moved it back onto
`prefix u` when the footer usage stat it was clicked from left the bar). Enter sets
the account new sessions start from **and moves this fleet's idle Claude
windows onto it** (`fleet-account.sh migrate --idle`, issue #512: close +
`--resume` in a new window, so each resumes its own transcript under the new
account). Windows mid-turn (`working`) or between `/loop` iterations
(`looping`) are left alone; they pick up the switch on their next restart. Esc
cancels.

There is **no fixed or default account**, so the footer shows no account chip:
the pick is a starting point, and every spawn re-picks on ccquota headroom
(issue #513, below) and rotates past a limited account. The old green
`◉ <account>` chip mirrored `global/account.active`, which is now re-written
per spawn — a stale snapshot. Per-window truth lives in the window's
`@cc_account` (the dash) and `fleet-account.sh whoami [<window-id>]` — with no
window id it reports the pane you run it in.

## How it runs

Two things authenticate against the pool, not one. The obvious one is a **worker
session**. The other is the fleet's own **helper `claude -p` call** — the
looping-detector (`bin/classify-sessions.sh`; the dash summarizer that shared the
wire retired in issue #535) — which routes through `fleet_helper_claude_auth`
(`bin/fleet-lib.sh`) and pick up the same ACTIVE-account token, *unless* one is
already in the environment: the Stop-hook path runs as a child of a worker's
claude and must keep THAT worker's account rather than re-resolving `active`
mid-turn.

Those helpers used to run bare, on the machine's ambient login — the one
credential nothing else in the fleet depends on. When it lapsed (issue #497) all
the workers kept running and only the summary column and the looping-detector
went dark, which is a confusing shape of failure to walk into. With multi-account
OFF the helpers fall back to that ambient login, which is then correct.

```
spawn a session ──► bin/fleet-claude.sh ──► exports CLAUDE_CODE_OAUTH_TOKEN
   (dash/backlog/cw)   (the launcher)        for the ACTIVE account, stamps the
                                             window's @cc_account label, exec claude
                                             │
collector (every ~60s) ── scrapes each window ┘
   sees "You've hit your … limit · resets …"  in a window whose @cc_account = work
        │
        ▼
   bin/fleet-account.sh mark-limited work
        ├─ records: work is limited until the banner's "resets …" instant
        │            (no instant in the banner? → now + FLEET_ACCOUNT_LIMIT_TTL)
        ├─ rotates the active pointer → personal
        └─ (if FLEET_NOTIFY_CMD set) pings you once: "work hit its limit → personal"
        │
        ▼
   the NEXT spawned session launches under personal, AND the collector
   dispatches `fleet-account.sh migrate --limited` in the background (issue
   #512): every window still running on work — the banner window and any other,
   mid-turn or idle — is asked to /exit, the SessionEnd hook closes it, and a NEW
   window in the same worktree runs `fleet-claude.sh --resume <session-id>`
   under personal, with a re-orient nudge — so RUNNING sessions follow the
   rotation too, without a manual /login
```

- **`bin/fleet-account.sh`** is the single owner of the rotation state
  (`account.active` + `account.limited` in the shared cache dir). Commands:
  `active`, `token [label]`, `env`, `list`, `use <label>`, `rotate`,
  `mark-limited <label>`, `clear [label]`, `limited-until <label>`, and the two
  that act on LIVE sessions (delegated to `bin/fleet-migrate.sh`): `migrate …`
  and `whoami [<window-id>]` — see [Moving live sessions](#moving-live-sessions)
  below.
- **`bin/fleet-claude.sh`** is a transparent launcher: with a pool it exports the
  active token and tags the window; **with no pool it is just `exec claude`** —
  which is why every spawn path can route through it safely.
- The **collector** (`bin/tmux-dash-collect.sh`) does the detection. It already
  scrapes each pane for the usage-% line; this adds the limit-banner match
  (`fleet_limit_banner` in `usage-lib.sh`: the classic "hit your … limit ·
  resets …" line, else the newer sticky "Usage limit reached · continuing
  automatically at …" footer that outlives it on screen, #511), attributes it to
  the window's `@cc_account`, and rotates. The whole banner is passed through,
  because its `· resets …` tail is what sets the bench end (the footer carries
  no zone, so it benches by TTL).
- **The bench ends when the account's window actually refreshes.** The zone in
  the banner is the *account's*, not the host's, so a fleet running in another
  timezone still lands on the right instant. Anything the parser can't read
  strictly — no clock time, an unknown zone — falls back to the duration rather
  than guessing, because a wrong epoch is worse than a conservative one.

Rotation is **round-robin over eligible accounts**: a limited one is skipped
until its bench ends (or you clear it with `fleet-account.sh clear <label>`). If
*every* account is limited, the active pointer stays put so sessions still launch
(they'll just wait on the limit like a single-account fleet would).

## What auto-switch does and does **not** do

- ✅ **New sessions** spawned after a limit hit use the next healthy account.
- ✅ Works on **macOS and Linux** (token env var, not config-dir juggling).
- ✅ **Zero cost when off** — no token files ⇒ every code path is a no-op and the
  fleet is byte-for-byte its old single-account self.
- ⚠️ **A live process cannot hot-swap its token — a close + `--resume` is how
  sessions follow a rotation.** Claude Code binds its credential at launch, and
  every in-place alternative was falsified on issue #495: `settings.json`'s
  `apiKeyHelper` (the only documented periodically-re-run credential hook) is an
  **API-key** path — its output is sent as both `X-Api-Key` and `Bearer`, but a
  subscription OAuth token fed through it just 401-loops, while the *same* token
  works via `CLAUDE_CODE_OAUTH_TOKEN`; env vars are never re-read mid-session.
  So both switch paths go through `fleet-account.sh migrate` (issue #512, below):
  the manual picker (`prefix u` → usage + account modal)
  moves idle windows (`--idle`), and the automatic limit-hit rotation moves every
  window still on the benched account (`--limited`) — mid-turn ones included,
  their turn is already dead — with a nudge so each re-orients and continues.
  Sessions mid-turn on *other* accounts, and `/loop` windows, keep their
  account until their next natural restart.
- ⚠️ **The usage proxy (`5h/7d` in the usage modal) is aggregate**, summed across
  *all* accounts' transcripts — it can't attribute past tokens to an account
  after the fact. Treat it as total fleet consumption, not per-subscription.
- ⚠️ **Hooks/settings are shared** across accounts (one `~/.claude`). That's the
  point (it keeps the fleet working), but it means per-account settings aren't
  possible via this mechanism.

## A limit banner is a hint; ccquota decides (#874)

Two writers used to decide "this account is out of quota": ccquota's reading,
and a scrape of each pane for the limit banner. The scrape guesses at a fact
ccquota states exactly, and it guessed wrong twice — #782 (a Codex banner benched
a Claude account) and 2026-09-22 (a `--resume` replayed an old weekly banner and
benched an account at **7d 34%**, starting a failover cascade across the pool).

Now there is one entry point, `fleet-account.sh quota-verdict <label> [--axis 5h|7d] [--refresh]`:

| Answer | Meaning | What a banner does |
|---|---|---|
| `limited <until>` | a fresh ccquota row has the named window (both, without `--axis`) at/above `FLEET_ACCOUNT_CEILING` | bench until ccquota's reset instant |
| `ok` | a fresh row with headroom on that window | **nothing** — one line in the collector log; the next tick asks again (the hub runs ~60s behind a real wall) |
| `unknown` | no hub/ccquota, a stale cache (`FLEET_ACCOUNT_QUOTA_STALE`), or no row for the account (blind hub, `available:false`, not on the hub) | the pre-#874 banner bench, and the status bar shows **`⚠ quota via banner`** |

- The banner names its window: `session`/N-hour → `5h`, `weekly` → `7d`; the
  sticky "Usage limit reached" footer names neither, so both are weighed.
- Every subscription banner buys **one forced refetch**; `--refresh` skips it
  while the cache is younger than `FLEET_ACCOUNT_VERDICT_REFETCH` (20s), so N
  walled windows in one tick cost one fetch.
- The failover controller's **hard** evidence (`.fleet-failover.py`
  `claude_wall`) follows the same rule, so a replayed banner cannot make a
  source "hard" either.
- **Not covered, on purpose:** per-model caps (below — ccquota does not report
  them, the banner stays their only source) and Codex (its native
  `quota_error` stays the hard signal).

## Per-model caps are not the subscription wall (#524)

`You've hit your Fable 5 limit · resets Sep 6 at 10pm` — and its sticky twin,
`You've reached your Fable limit. Run /usage-credits to continue or switch models
with /model.` — is a **per-model** cap: one model is walled on one account while
the account's 5h/7d subscription headroom stays intact for every other model. Up
to #524 the collector read it as the subscription banner, benched the account and
`migrate`d every session off it — onto an account with the same Fable cap, where
they hit the same wall (the 2026-09-02 cascade: 19 sessions parked, an account
benched at 14% utilization by a source string that merely *contained* "Usage
limit reached").

Now the two walls are told apart (`fleet_limit_kind` in `usage-lib.sh`), and a
model cap is handled without touching the account pool:

```
fleet-quotawatch.sh (≤60s tick) — or the collector, as the backstop — sees
"hit your Fable 5 limit" on a window running on account work
   ├─ fleet-account.sh model-limited work fable "<banner>"
   │     records (work, fable) capped until the banner's "resets Sep 6 at 10pm"
   │     instant — the dated form is parsed in the banner's zone — else now +
   │     FLEET_MODEL_LIMIT_TTL (7d). Ledger: global/account.model-limited.
   │     account.limited and the active pointer are NOT touched: no rotation.
   ├─ fleet-model-switch.sh --capped --model opus   (backgrounded, per fleet)
   │     types Escape + `/model opus` + Enter at the walled session's OWN
   │     prompt, confirms Claude Code's "Switch model?" dialog, then VERIFIES
   │     the flip off the pane's `◆ <model>` status line. ~5s, and the process
   │     never dies: background agents, context and cost all survive. The nudge
   │     that follows rides fleet_peer_send (the SendMessage channel), never
   │     send-keys.
   │     └─ flip unverifiable → fleet-migrate.sh --model opus <window>
   │           the pre-#569 fallback: Escape + /exit → SessionEnd hook → new
   │           window running fleet-claude.sh --model opus --resume <sid>
   └─ notify once per (account, model) episode
```

**Why in place (#569).** A model cap needs no new token — same account, same
OAuth — so the close + `--resume` dance #524 borrowed from account rotation was
pure cost. Measured on the 2026-09-12 episode (9 walled workers over two
fleets): ~30–60s of cold boot per window and strictly one at a time, every
background agent killed with the process (one worker was 13 min into a
general-purpose agent), the whole transcript re-read as fresh *input* tokens on
the one account not already benched, plus the #543/#544 reap hazards of closing
a worker's window. And it was gated behind the collector's tick, which on that
fleet ran 17 minutes (the git scan alone took 551s) — so the recovery trickled
out for the better part of an hour. Detection now rides the 60s quotawatch tick
and the recovery is a keystroke.

and every **new** session on that account — autofill, a hand spawn, a restore, a
migrate — goes through `fleet-claude.sh`, which asks `model-limited-until` for
its FLEET_MODEL and launches on **`FLEET_MODEL_FALLBACK`** (default `opus`)
while the cap holds; subagents follow (`CLAUDE_CODE_SUBAGENT_MODEL`), and the
pane is stamped `@cc_model`. When the cap resets, new sessions are back on
`FLEET_MODEL` with nobody flipping a switch. Sessions already running on the
fallback stay there until they end.

Rules, same as `--model`'s: an explicit caller `--model` wins; an empty
`FLEET_MODEL_FALLBACK` turns the whole path off (a model cap then behaves like
the subscription wall: bench + rotate); a fallback equal to the capped model is a
no-op (nothing to swap to — the pre-#524 bench path runs). The knob is
`@scope=global`: one policy for every fleet on the machine.

The in-place switch refuses three more cases (#569), and says which in its
report: a window **mid-turn** (`@claude_state working` — an Escape there would
cancel a live turn; the next tick takes it), a window whose status line already
reads something other than the capped model (nothing to do — this, not a marker
file, is what makes a second pass idempotent even with the banner still in the
scrollback), and a fallback that is **itself** capped on that account, which is
handed to the subscription path instead of flipped onto a second wall.

```sh
bin/fleet-model-switch.sh --capped --dry-run       # what a sweep would do, here
bin/fleet-model-switch.sh --capped --model opus    # do it
bin/fleet-model-switch.sh --model opus @37         # one window, on the operator's word
```

```sh
bin/fleet-account.sh model-limited-until work fable   # epoch, 0 = not capped
bin/fleet-account.sh model-clear work fable           # lift it by hand
bin/fleet-account.sh migrate --model opus <window>    # relaunch one window on opus
```

### Knowing the cap before the wall (ccquota's per-model window, #1073)

A banner is the LAST symptom of a model cap: it prints only after a session has
walked into it, a session idle when the cap landed never prints one, and the
ledger's until is a TTL guess. The cap itself is a window of its own — a Fable
response carries `anthropic-ratelimit-unified-7d_oi-{utilization,reset,status}`
beside the account's 5h/7d (on 2026-09-23 three of four pool accounts were at
7d_oi 1.0 while their 7d read 0.68–0.80). TokenLedger records it and states it in
`ccquota budget --json` as `accounts[].models[<model-id>]` (tokenledger#155).

Every quota fetch (`quota_fetch` — the quotawatch tick, `quota --refresh`, a
banner's forced refetch) now also runs `model_quota_sync`:

- **capped** (`status: rejected`, utilization ≥ `FLEET_MODEL_CAP_PCT`, or
  `model_available` false) → the `(account, model)` ledger row, until ccquota's
  **real** reset (+60 s), replacing a banner's TTL guess for the same model.
- **available again** → ccquota's own row is dropped, and so is a banner row
  written *before* the reading was observed. A banner that landed after it is
  newer evidence and stands until ccquota catches up: a banner is now a hint that
  the next reading confirms or clears, as #874 made the subscription banner.

With the ledger seeded, everything downstream already reads it: `pick_active`
runs a **model pass** first (an account whose FLEET_MODEL is uncapped beats one
whose phase slot is due), the provider-aware selector ranks `model_primary`
accounts first, `fleet-claude.sh` launches on `FLEET_MODEL_FALLBACK` when every
account is capped, and quotawatch's `fleet-model-switch.sh --capped` flips idle
sessions on a newly capped account on its next tick — no banner anywhere.

An older ccquota with no `models` field seeds nothing and opens no ledger: the
fleet behaves exactly as before, and `fleet-doctor` says so on its `modelcap`
line (INFO), or lists each account's per-model utilization (PASS).

```sh
bin/fleet-account.sh model-quota      # label · model · capped|ok|unknown · reset · observed · util% · status
```

## Pre-emptive rotation with ccquota

The banner path is reactive: an account has to be walled — and a session stuck
for up to five hours — before the fleet reacts. If you run
[TokenLedger](https://github.com/verkyyi/tokenledger) with a hub, the fleet can
act first (issue #513). **The product is TokenLedger; the binary is `ccquota`**
— the command, the `CCQUOTA_*` variables and the cache paths below all still
read `ccquota`, so do not go looking for a `tokenledger` command. Install it per
[INSTALL.md](INSTALL.md) (step 6).

ccquota knows every subscription's **exact, account-wide**
5-hour and 7-day utilization and reset instants, across devices; set
`export CCQUOTA_HUB_URL=…` in `fleet.conf` (ccquota reads the viewer token from
`~/.ccquota/viewer-token`) and the **quota watch** — `bin/fleet-quotawatch.sh`,
its own 60s daemon `com.claude-fleet.quotawatch` since issue #551, with the
collector as a fallback first thing in its tick when that unit stops ticking
(issue #671) — does, per pool account, every tick:

| utilization (higher of 5h / 7d) | action |
|---|---|
| ≥ `FLEET_ACCOUNT_WARN_PCT` (70%) | message every session running on it over its **peer inbox** (`fleet-peer-send.sh`, the `SendMessage` channel) that a move is coming, with the ETA at the current burn rate, so it can commit WIP; toast + `FLEET_NOTIFY_CMD` once |
| ≥ `FLEET_ACCOUNT_CEILING` (85%) | **bench** it until ccquota's reset instant (`fleet-account.sh bench`), which rotates the active pointer at once, then **move** every session still on it (`migrate --account <label>`, per fleet, backgrounded) — the same close + `--resume` a banner triggers, minus the wall. **Nowhere to move** (issue #567: every other account is benched or at its ceiling too) ⇒ bench only, no fan-out — the toast/notify say so, and the sessions stay put until the reset; a walled session waiting for its own reset beats one cold-booted back into the same wall |

Each step fires once per (account, reset window). New sessions, meanwhile, go
to the eligible account that **ranks best** (`fleet-account.sh active` reads the
cached ccquota rows; the current account is kept while it is within
`FLEET_ACCOUNT_PICK_HYST` (10) points of the best, so spawns don't flip-flop) —
see [the ranking](#which-account-a-new-spawn-lands-on-issue-598) for what "best"
means. Everything fails open: no ccquota on `PATH`, no URL, an unreachable hub or
an `unknown` verdict → no rows → the banner path above, unchanged.

### Which account a new spawn lands on (issues #598, #1231)

The ranking is `5h-headroom × 2 + (100 − weekly pace) × 20`, over the eligible
accounts the ceiling has not already thrown out — the #598 score below with its
flat 7d term replaced by the **weekly pace** (next section). `FLEET_ACCOUNT_PICK=5h`
restores the #598 score, `minmax` the one before it.

#### The #598 half: the 5-hour window counts double

Under `5h` the ranking is `5h-headroom × 2 + 7d-headroom`, and the 5h term is
unchanged in `pace`. **The 5-hour window counts double because it
expires**: whatever a window does not spend evaporates at its reset and can never
be recovered, while weekly headroom just sits there. The 7-day term still counts,
so an account one spawn away from its weekly ceiling does not win on a fresh 5h
window alone.

It used to be ccquota's own `headroom_pct` = `100 - max(5h, 7d)`, which reads the
two windows as if they were one budget. Live pool, 2026-09-13:

```
ly297@georgetown.edu     5h  0% · 7d 80%     headroom 20
verky@24helpful.com   ●  5h 77% · 7d 51%     headroom 23
```

The account with a **completely unused 5-hour window** scored *below* the one
that was already three-quarters through its own, so every spawn kept landing on
the second — which went 8% → 77% in four hours while the first sat at 0% for the
whole window and then reset. That is not a phase problem; that is a full window
of a paid subscription thrown away by the fleet's own rotation logic. Under the
ranking above the same rows score 220 and 95, and the spawn goes to the idle
window.

`FLEET_ACCOUNT_PICK=minmax` restores the old answer — a one-line rollback, not a
recommendation.

### Pacing the weekly budget across the pool (issue #1231)

#598 fixed the 5-hour waste and created a weekly one. Its 7d term is a flat
0..100 under a 5h term worth 0..200, so an account with a **fresh 5h window**
outscored one with a half-spent window whatever their weeks looked like. Live
pool, 2026-09-25 ~15:50 PT:

```
24helpful   5h  2% · 7d 90%   score 206   (7d resets in 31h)
icloud      5h  0% · 7d 90%   score 210   (7d resets in 67h)
ly297       5h  1% · 7d 86%   score 212   (7d resets in 54h)
gmail       5h 72% · 7d 45%   score 111   (7d resets in 159h)
```

Only the 85% ceiling ever stopped a spawn landing on the top three, so spawns
went to whichever account was **closest to exhausting its week** until each hit
the ceiling in turn: three of four benched for one to three days, the EPIC driver
dead with them, and ~45% of gmail's week unused. The weekly budget is the scarcer
resource — a 5h window comes back in five hours, a benched week in days.

**The pace.** For each account with a ccquota row,

```
elapsed = 1 − (7d-reset − now) / 7d          (clamped to 0..1)
pace    = 7d-utilization − CEILING × elapsed  (points; + = ahead of an even burn, − = behind)
```

is how far ahead of, or behind, an even burn of the week's *spendable* budget
(the ceiling, not 100) the account is. At an even fleet-wide burn it is also, to a
constant, the hours the account would sit **benched** before its reset (ahead) or
the budget it would leave **unspent** at the reset (behind) — which is why the
score ranks *behind* up: that budget evaporates at the weekly reset exactly the
way an idle 5h window does at its own. No 7d reset in the row ⇒ pace 0, no
opinion.

**The score** is `5h-headroom × 2 + (100 − pace) × W`, with `W = 200 /
FLEET_ACCOUNT_PACE_LEAD` (default 20): a weekly lead of `PACE_LEAD` points (10) is
worth an entire 5h window, so within a lead that size the 5h window still decides
— accounts on the same pace get exactly #598's answer — and beyond it the week
does. Two rails sit on top of the score, both **fail-open** the way a phase slot
is (they can never be the reason a spawn has no account): an account more than
`FLEET_ACCOUNT_PACE_HOLD` (25) points ahead, or with its 7d within
`FLEET_ACCOUNT_PACE_MARGIN` (5) of the ceiling, is **held** for new spawns.
`fleet-account.sh list` shows `pace ±N` per account (red = held, yellow = more
than a 5h window ahead); `fleet-account.sh pace` prints the table.

**Running sessions move too — gently.** The ceiling branch is a cliff: nothing
until 85%, then every session on the account at once. The quota watch now also,
every tick, mirrors the pace table to `global/quota.pace` and, when the
most-ahead un-benched account leads the *current pick* (`fleet-account.sh
active`, which honours the holds) by `FLEET_ACCOUNT_PACE_REBALANCE` (15) points or
more while that pick is itself on pace with 5h room (under `FLEET_ACCOUNT_WARN_PCT`),
moves **one idle session** (done/needs — a working turn is worth more than the
points it spends) off the leader per fleet — `migrate --idle --from <leader>
--max 1` — then waits `FLEET_ACCOUNT_PACE_COOLDOWN` (600 s) before the next. A
lead closes one cold boot at a time and a pick that flips never ping-pongs a
session. `FLEET_ACCOUNT_PACE_REBALANCE=0` switches the moves off; the table is
still written. A fleet on the failover planner (`FLEET_FAILOVER=1`) is left to
the planner, as the ceiling branch leaves it.

**Visibility.** The status bar shows `⚠ quota pace spread N` (yellow) when the
most-ahead and most-behind accounts are more than `FLEET_ACCOUNT_PACE_SPREAD_WARN`
(30) points apart — one week is being drained while another sits unused, and
`list` names them. Codex subscriptions get the same pace and score in the
provider-aware selector (`.fleet-account.py`), so the batch driver is placed by
the same rule as a worker.

On the 2026-09-25 rows above the three hot accounts are held (and over the
ceiling) and gmail wins; two days earlier, when all four were under the ceiling
(`24helpful 7d 72% · icloud 60% · ly297 65% · gmail 30%`, gmail a day from its
reset), the old score sent the spawn to ly297 at 235 vs gmail's 160 and the pace
score sends it to gmail at 2790 vs ly297's 1560 — which is the spawn that would
have spent the week that went unused.

### Staggering the 5h windows so they don't all reset together (issue #598)

N subscriptions first used at around the same time keep their 5-hour windows in
the **same phase**: they burn down together and reset together, so the pool's
total headroom is a sawtooth whose trough is a full outage. The bigger the pool,
the sharper it gets.

A window's phase is not settable — the window opens when the account is first
used and runs five hours from there. So the only lever is **when each account is
first used**, and the plan is a queue of start slots, not a rotation:

```
fleet-account.sh phase                  # the pool's phase table: live windows + pending slots
fleet-account.sh phase --plan           # the 5h/N stagger it WOULD apply (dry run)
fleet-account.sh phase --plan --apply   # …write it; new spawns honour the slots
fleet-account.sh phase --clear [label]  # drop it
```

With three accounts and nothing running, that is the textbook case — slots at
T+0, T+100min, T+200min. What it does *not* do matters as much:

- **An account mid-window is never held.** Its phase is a fact, not a choice; the
  plan is anchored on it and everything else is placed relative to it.
- **A benched account is not in the plan at all** — no row, so no hold.
- **A slot that already went by is released at once**, not pushed into the next
  window. Waiting costs up to a full window of a paid subscription, and buying a
  textbook phase with a window nobody spends is the loss this is here to stop.
- **A hold can never starve the pool.** `pick_active` runs twice — once honouring
  the plan, once ignoring it — so a spawn always has an account to run on.
- Window starts come from ccquota (`five_hour.resets_at - 5h`), never from a
  local guess. ccquota reports a `resets_at` even for an account with no live
  window, so `utilization > 0` is what says a window is really open.

`FLEET_ACCOUNT_PHASE=0` ignores any written plan (kill switch).
`FLEET_ACCOUNT_PHASE_AUTO=1` lets the quota watch re-plan once per window instead
of only when you run it by hand — **off by default**: that tick is what keeps the
fleet alive, so arming it is a deliberate act.

### The watch is its own tick, and it tells you when it is blind (issue #551)

Until #551 this policy was the **last** block of the dash collector's tick —
after the per-repo `gh` fetches and the git/ctx/usage scans. On a 21-window
fleet a tick took 2–3 minutes, and a tick that wedged (an un-timeboxed `gh`) or
died early never reached it: on 2026-09-11 the cache sat 2.5h stale, neither
branch fired, and every session on the account rode the 5-hour window to 100%.
Now:

- **Own unit.** `com.claude-fleet.quotawatch` (`systemd/claude-fleet-quotawatch.timer`)
  runs `bin/fleet-quotawatch.sh` every 60s, independent of the collector.
- **Collector fallback, conditional (issue #671).** The collector runs the same
  script **first** in its tick (before any `gh`) — but only when the unit is not
  demonstrably ticking, so an install whose daemon set predates #551 keeps
  watching at the collector's cadence while a healthy one pays ~0. The gate reads
  `global/<root>/quotawatch.tick`, the #639 scheduling stamp, against
  `FLEET_DAEMON_STALE_MULT × 60s` (floor 180s ⇒ 300s): absent (no unit, fresh
  install) or stale (loaded but **pended**) ⇒ the collector runs it; fresh ⇒ it
  skips. It cannot flap, because `--caller collect` is the one caller that does
  **not** write that stamp (#639) — the fallback can never mistake itself for the
  unit being healthy. `FLEET_COLLECT_QUOTAWATCH=always|never` forces the old
  unconditional call or switches the fallback off.
  Why conditional: the doubled call was documented as free — TTL-gated fetch,
  `mkdir` lock (`global/quotawatch.lock`) skipping an in-flight tick (a tick older
  than 120s is superseded), once-per-reset-window markers deduping every action —
  and that was measurably wrong. The **modelcap sweep** is gated by none of those
  (it carries its own 20s-per-fleet / 40s-per-sweep budgets), so the collector's
  copy kept running the whole sweep and being killed at its 30s phase budget:
  46 · 56 · 35 · 57 · 25 · 17 · 10 · 3 seconds sampled, `quotawatch` permanently in
  the heartbeat's `over=` list, a quarter of a 120s tick spent redoing work the
  unit had just done.
- **Heartbeat.** `global/quotawatch.heartbeat` (key=value: `pid caller start
  phase phase_ts fetched rows end dur`) — and the collector's own
  `global/collect.heartbeat` with per-phase seconds, so "which phase was slow"
  is one `cat` away.
- **Staleness alarm.** `account.quota.ts` is restamped by every watch tick (an
  unreachable hub restamps too — empty rows still refresh the stamp), so its age
  is the watch's *liveness*. With a pool + hub configured and the stamp older
  than `FLEET_ACCOUNT_QUOTA_STALE` (600s = 10× the TTL) the rotation is blind,
  and that is never silent: the tmux status bar shows **`⚠ quota stale 47m`**
  (red, never freshness-gated), `fleet-doctor.sh` **FAILs** its `quotawatch`
  line (plus a `collect` line with the last tick's age/duration/slowest phase),
  and the next tick that does run sends one `FLEET_NOTIFY_CMD` saying how long
  the watch was blind.
- **Blindness alarm** (issue #684). The stamp says a tick *ran*; it says nothing
  about whether the tick brought anything *back*, and the fetch restamps either
  way on purpose. So a hub that answers with zero rows leaves a cache that is
  **fresh and empty** — which every stamp-keyed alarm above reads as healthy
  while the rotation has nothing to act on. On 2026-09-15 that state held for at
  least six minutes with `--status` printing `fresh 117`, `fleet-doctor` PASSing
  and `ccquota budget --account all --json` answering perfectly on the same box.
  `fleet-account.sh` now counts the consecutive empty fetches
  (`global/account.quota.empty`, cleared by the first fetch that returns rows),
  and `FLEET_ACCOUNT_QUOTA_BLIND_STREAK` (default 3 ≈ 3 min at the 60s TTL, 0 =
  off) is where that becomes an alarm: **`⚠ quota blind 6m`** on the status bar,
  a **FAIL** on `fleet-doctor`'s `qwatch` line, `--status` answering `blind`
  instead of `fresh`, and one `FLEET_NOTIFY_CMD` per episode. One empty read is
  noise (a hub blip, a fetch killed on its budget) — the streak is the verdict.
  A pool with **no token files** is not blind, just unconfigured, and never
  raises it. Stale wins where both could fire: a stamp that has stopped moving
  means no fetch is happening at all, so the streak is frozen history.
- **Rehearsal.** `fleet-quotawatch.sh --dry-run` prints what each account
  would trigger without writing a marker, benching or moving anything;
  `--status` prints `off|never|fresh|stale|blind<TAB>age-seconds<TAB>empty-streak`
  (column 2 is the stamp's age for `fresh`/`stale`, the blind spell's length for
  `blind` — in each case, how long column 1 has been true).

```
fleet-quotawatch.sh --status      # off|never|fresh|stale|blind + age (s) + empty streak
fleet-quotawatch.sh --dry-run     # what this tick WOULD do per account, no side effects
fleet-account.sh quota            # what the watch sees: label · 5h% · 7d% · headroom · resets · %/h
fleet-account.sh quota --refresh  # bypass the FLEET_ACCOUNT_QUOTA_TTL (60s) cache
fleet-account.sh list             # …the same numbers, coloured, next to each account,
                                  #    plus each live 5h window's time left (`win 40m left`)
                                  #    or `win idle` — an idle window is capacity bleeding away
fleet-account.sh phase            # the 5h-window phase table (issue #598)
fleet-account.sh phase --plan     # the 5h/N stagger it would apply, dry
fleet-doctor.sh                   # "quota" row: hub reachable, N/M pool labels mapped
```

Label ↔ account: ccquota's name for the account (`ccquota name`) must equal the
fleet label, or pin `CCQUOTA_ACCOUNT=<uuid>` in the label's `<label>.conf`.

**No reading ⇒ no row** (issue #628). ccquota is explicit when it cannot read an
account — `"available": false` with a `reason`, and then its `five_hour` /
`seven_day` keys disappear from the JSON entirely (they are `omitempty`, and
TokenLedger returns before filling them). The fleet used to read neither, so such
an account arrived as `label 0 0 0 …`: **0% used and 0% headroom at the same
time**. A 0 never crosses the 85% ceiling, so it was never benched — and `u < 85`
is exactly what qualifies a *migrate target*, so it was the first account a
ceiling fan-out moved N sessions onto. Now `quota_parse` drops it: no row, which
is the same word the pool already uses for "ccquota has never heard of this
label", and every consumer already reads it as *no opinion* — `pick_active` skips
it, `list` prints no quota columns for it, the watch's policy loop never sees it,
and `quota_move_target` refuses it as a landing spot (a bench with nowhere to move
beats moving 12 sessions onto an account nobody can read — the #567 reasoning).

That last one is a **behaviour change worth knowing**: a ceiling fan-out now
requires the destination to have an actual reading under the ceiling, so a pool
label ccquota does not cover — for any reason, unreadable *or* merely unmapped —
is no longer a migrate target. It puts the fan-out in step with the spawn path,
which has always worked that way (`pick_best` skips a label with no row and falls
back to round-robin only when *no* account has one); a label being un-spawnable
yet a legitimate landing spot for a dozen sessions at once was never a defensible
pair. Map the pool (`ccquota name`, or `CCQUOTA_ACCOUNT=` in `<label>.conf`) and
`fleet-doctor.sh` goes back to a green `quota` line.

Because "no row" is silent by construction, the diagnosis is on **stderr** and in
the doctor:

- `fleet-account.sh quota --refresh` prints one line per unreadable account
  (`ccquota has no reading for <label> (available=false, reason: …)`), and the
  watch tick logs the same — **once per change**, not once per 60s tick, with a
  line when the condition clears.
- `fleet-doctor.sh` **WARNs** its `quota` line and *names* the accounts.
- A payload carrying **neither window** for an account that is *not* flagged
  unavailable is a different animal — the contract drifted — and turns that line
  **red (FAIL)**: `bin/fleet-doctor-quota-selftest.sh` pins all four verdicts.

One more shape note: `budget --json` states `resets_at` as **RFC3339**
(`cmd/ccquota/budget.go`), while the stamp API in the same binary uses **unix
seconds** (`stamp.go`). `quota_parse` now accepts either — an integer used to
except into `0`, which silently flattened every `fleet_same_window` comparison.

## Moving live sessions

`fleet-account.sh migrate …` (`bin/fleet-migrate.sh`, issue #512) is the one
mechanism that moves a RUNNING session onto the active account. It replaced the
#263/#495 in-place `--continue` restart, which could not work on an install whose
SessionEnd hook closes the window the instant Claude exits (issue #403) — there
was never a shell left to type a relaunch into. Per window it:

1. reads the window (name, cwd, `@issue`/`@raw`/`@worktree`/`@origin`,
   state) and the **session id off Claude Code's own registry**
   (`~/.claude/sessions/<pid>.json` — exact, not "the newest transcript");
2. types `Esc` (which also cancels a "Usage limit reached · continuing
   automatically" wait), `/exit`, `Enter`, and waits for the Claude **process**
   to be gone — never typing anything else while it lives (issue #511);
3. lets the SessionEnd hook close the window (it records the `/fleet-history`
   row too); with no hook (`FLEET_CLOSE_ON_EXIT=0`) it relaunches in the
   surviving shell instead;
4. opens a NEW window, same name and cwd, running
   `fleet-claude.sh --resume <session-id> [nudge]`, re-binds the options, and
   **verifies** by reading the new process's token out of its environment.

```
fleet-account.sh migrate --limited          # every window on a benched account (the banner path's call)
fleet-account.sh migrate --idle             # done|needs windows not on the active account (the picker's call)
fleet-account.sh migrate --all              # everything not on the active account
fleet-account.sh migrate --account work     # everything running on `work`
fleet-account.sh migrate @12 @15            # these windows, whatever they run on
fleet-account.sh migrate --stuck            # every window whose failover request is ⚠ stuck (#872)
fleet-account.sh migrate --force-bg @12     # move despite background commands: stop them,
                                            # name them in the resume nudge (#873; = dash ⌃l)
fleet-account.sh migrate --dry-run --all    # print the plan only
fleet-account.sh whoami @12                 # the account a window REALLY runs (token truth;
                                            # heals a stale @cc_account stamp)
fleet-account.sh whoami                     # …and bare: the pane you ran it in ("which
                                            # account is THIS session on"). Outside a pane
                                            # of that fleet it exits 2, never silently empty
```

Never touched: panels (`dash`/`plan`/`backlog`), the operator hub (`@hub`),
windows with no Claude process, and a raw scratch parked at `FLEET_MAIN`
without a registry session id. Windows move one at a time (each is a cold
`claude` boot). From outside tmux pass `--session <fleet>`.

### Messaging a live session

`bin/fleet-peer-send.sh <target> <text>` delivers a message to a running session
over Claude Code's local inbox socket — the same channel the `SendMessage` /
`ListAgents` tools use between sessions on one machine — so fleet tooling can
talk to a worker without `tmux send-keys` into its prompt (issue #437). The
recipient sees it as a message from another session on its next turn.

**Address a worker by identity, not by window number** (issue #1046):
`fleet-peer-send.sh issue:<N> …` (also `#<N>` / `issue-<N>`; `scratch-<N>` or an
exact window name for a scratch) is resolved to exactly ONE live window at send
time — zero or several matches refuse, and `--repo <o/r>` narrows a number two
repos share. A `<sess>:<idx>` target is a *position*: closing any window
renumbers the ones after it, and a remembered or handed-off index silently lands
on a different worker (three operator-authorising instructions went astray that
way on 2026-09-23). Positional targets still work; pin one with
`--expect-issue <N>` and it refuses when the window there is someone else. A
window id (`@N`), pane id, pid or session uuid is stable and needs no pin. Every
call prints exactly one outcome line — `sent → … (<window> · <worktree>)` on
success, one stderr line + non-zero exit on any failure. The body rides Claude Code's
canonical `<cross-session-message from-name=… from-mode=…>` envelope, attesting
`FLEET_PEER_MODE` (default `bypass`, the mode fleet sessions run in): without
that attestation a bypass-mode recipient HOLDS the message behind an approve/
deny dialog in the pane — the very stall this tooling exists to prevent.

## Security & terms

- Token files are secrets: keep them `600`; `fleet-doctor.sh` warns if not. They
  sit under `~/.config/claude-fleet/`, never in the repo. `.gitignore` covers the
  in-repo `fleet.conf`, and tokens live outside the tree regardless.
- **Which subscriptions go in the pool, and which logins share it, is the
  operator's decision.** The tooling spreads load over whatever tokens it finds
  and neither checks nor enforces who holds them. On a machine with several
  logins, each login can bring its own subscriptions or copy the operator's
  pool — see [SHARED-MACHINE.md step 2b](SHARED-MACHINE.md#2b-optional-join-the-machines-shared-account-pool).

## Troubleshooting

| Symptom | Check |
|---|---|
| Sessions still use the old account | `fleet-account.sh list` — is the pool non-empty and a token present? Is `fleet-claude.sh` on the spawn path (re-copy `bin/` after upgrading)? |
| No auto-switch on a limit | The window must carry `@cc_account` (only sessions launched via `fleet-claude.sh` do). Confirm with `tmux show-options -w @cc_account`. Before #511 the stamp landed on the hub window instead of the worker's — re-sync the install if your workers are unstamped. |
| Which account is a window REALLY on? | The stamp is set at launch and can go stale (a hand restart, an older install). The truth is the Claude process's own env: `ps -E -o command= -p <claude pid> \| tr ' ' '\n' \| grep ^CLAUDE_CODE_OAUTH_TOKEN=` (macOS; `/proc/<pid>/environ` on Linux) and compare with the token files. `claude auth status` *inside a worker's Bash tool* is wrong here — the token is stripped from tool subprocesses, so it reports the Keychain login. |
| An account never comes back | It's within its TTL. `fleet-account.sh clear <label>` forces it eligible now. |
| macOS: switching seems ignored | You must use token files — the Keychain ignores `CLAUDE_CONFIG_DIR`. `fleet-doctor.sh` reminds you of this. |
