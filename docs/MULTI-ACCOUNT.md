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

**Switch by hand.** Click the footer usage stat to open the usage + account
modal — the account pool is the selectable body under the usage detail (issue
#289 merged the old `prefix A` picker + `prefix u` popup into one). Enter sets
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
`@cc_account` (the dash) and `fleet-account.sh whoami <window-id>`.

## How it runs

Two things authenticate against the pool, not one. The obvious one is a **worker
session**. The other is the fleet's own **helper `claude -p` calls** — the dash
summary column (`bin/tmux-summarize.sh`) and the looping-detector
(`bin/classify-sessions.sh`) — which route through `fleet_helper_claude_auth`
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
  and `whoami <window-id>` — see [Moving live sessions](#moving-live-sessions)
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
  the manual picker (the footer usage stat → usage + account modal)
  moves idle windows (`--idle`), and the automatic limit-hit rotation moves every
  window still on the benched account (`--limited`) — mid-turn ones included,
  their turn is already dead — with a nudge so each re-orients and continues.
  Sessions mid-turn on *other* accounts, and `/loop` windows, keep their
  account until their next natural restart.
- ⚠️ **The usage proxy (`5h/7d` in the status bar) is aggregate**, summed across
  *all* accounts' transcripts — it can't attribute past tokens to an account
  after the fact. Treat it as total fleet consumption, not per-subscription.
- ⚠️ **Hooks/settings are shared** across accounts (one `~/.claude`). That's the
  point (it keeps the fleet working), but it means per-account settings aren't
  possible via this mechanism.

## Pre-emptive rotation with ccquota

The banner path is reactive: an account has to be walled — and a session stuck
for up to five hours — before the fleet reacts. If you run
[ccquota](https://github.com/verkyyi/ccquota) with a hub, the fleet can act
first (issue #513). ccquota knows every subscription's **exact, account-wide**
5-hour and 7-day utilization and reset instants, across devices; set
`export CCQUOTA_HUB_URL=…` in `fleet.conf` (ccquota reads the viewer token from
`~/.ccquota/viewer-token`) and the collector does, per pool account, every tick:

| utilization (higher of 5h / 7d) | action |
|---|---|
| ≥ `FLEET_ACCOUNT_WARN_PCT` (70%) | message every session running on it over its **peer inbox** (`fleet-peer-send.sh`, the `SendMessage` channel) that a move is coming, with the ETA at the current burn rate, so it can commit WIP; toast + `FLEET_NOTIFY_CMD` once |
| ≥ `FLEET_ACCOUNT_CEILING` (85%) | **bench** it until ccquota's reset instant (`fleet-account.sh bench`), which rotates the active pointer at once, then **move** every session still on it (`migrate --account <label>`, per fleet, backgrounded) — the same close + `--resume` a banner triggers, minus the wall |

Each step fires once per (account, reset window). New sessions, meanwhile, go
to the eligible account with the **most headroom** (`fleet-account.sh active`
reads the cached ccquota rows; the current account is kept while it is within
10 points of the best, so spawns don't flip-flop). Everything fails open: no
ccquota on `PATH`, no URL, an unreachable hub or an `unknown` verdict → no
rows → the banner path above, unchanged.

```
fleet-account.sh quota            # what the collector sees: label · 5h% · 7d% · headroom · resets · %/h
fleet-account.sh quota --refresh  # bypass the FLEET_ACCOUNT_QUOTA_TTL (60s) cache
fleet-account.sh list             # …the same numbers, coloured, next to each account
fleet-doctor.sh                   # "quota" row: hub reachable, N/M pool labels mapped
```

Label ↔ account: ccquota's name for the account (`ccquota name`) must equal the
fleet label, or pin `CCQUOTA_ACCOUNT=<uuid>` in the label's `<label>.conf`.

## Moving live sessions

`fleet-account.sh migrate …` (`bin/fleet-migrate.sh`, issue #512) is the one
mechanism that moves a RUNNING session onto the active account. It replaced the
#263/#495 in-place `--continue` restart, which could not work on an install whose
SessionEnd hook closes the window the instant Claude exits (issue #403) — there
was never a shell left to type a relaunch into. Per window it:

1. reads the window (name, cwd, `@issue`/`@raw`/`@worktree`/`@origin`/
   `@summary`, state) and the **session id off Claude Code's own registry**
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
fleet-account.sh migrate --limited          # every window on a benched account (the collector's call)
fleet-account.sh migrate --idle             # done|needs windows not on the active account (the picker's call)
fleet-account.sh migrate --all              # everything not on the active account
fleet-account.sh migrate --account work     # everything running on `work`
fleet-account.sh migrate @12 @15            # these windows, whatever they run on
fleet-account.sh migrate --dry-run --all    # print the plan only
fleet-account.sh whoami @12                 # the account a window REALLY runs (token truth;
                                            # heals a stale @cc_account stamp)
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
target is a window id, a pid, or a session uuid; the recipient sees it as a
message from another session on its next turn. The body rides Claude Code's
canonical `<cross-session-message from-name=… from-mode=…>` envelope, attesting
`FLEET_PEER_MODE` (default `bypass`, the mode fleet sessions run in): without
that attestation a bypass-mode recipient HOLDS the message behind an approve/
deny dialog in the pane — the very stall this tooling exists to prevent.

## Security & terms

- Token files are secrets: keep them `600`; `fleet-doctor.sh` warns if not. They
  sit under `~/.config/claude-fleet/`, never in the repo. `.gitignore` covers the
  in-repo `fleet.conf`, and tokens live outside the tree regardless.
- **Respect Anthropic's terms for your subscriptions.** This feature is for an
  operator who legitimately holds multiple subscriptions (e.g. a personal Max +
  a work Max) and wants to spread their own fleet's load across them. It is not a
  way to pool or share one subscription among multiple people.

## Troubleshooting

| Symptom | Check |
|---|---|
| Sessions still use the old account | `fleet-account.sh list` — is the pool non-empty and a token present? Is `fleet-claude.sh` on the spawn path (re-copy `bin/` after upgrading)? |
| No auto-switch on a limit | The window must carry `@cc_account` (only sessions launched via `fleet-claude.sh` do). Confirm with `tmux show-options -w @cc_account`. Before #511 the stamp landed on the hub window instead of the worker's — re-sync the install if your workers are unstamped. |
| Which account is a window REALLY on? | The stamp is set at launch and can go stale (a hand restart, an older install). The truth is the Claude process's own env: `ps -E -o command= -p <claude pid> \| tr ' ' '\n' \| grep ^CLAUDE_CODE_OAUTH_TOKEN=` (macOS; `/proc/<pid>/environ` on Linux) and compare with the token files. `claude auth status` *inside a worker's Bash tool* is wrong here — the token is stripped from tool subprocesses, so it reports the Keychain login. |
| An account never comes back | It's within its TTL. `fleet-account.sh clear <label>` forces it eligible now. |
| macOS: switching seems ignored | You must use token files — the Keychain ignores `CLAUDE_CONFIG_DIR`. `fleet-doctor.sh` reminds you of this. |
