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

   **Different windows per account?** If your accounts are on different tiers
   (Pro vs Max 5×/20×) whose limits reset over different windows, give an account
   its own bench duration with a companion `<label>.conf` next to its token:

   ```sh
   printf 'LIMIT_TTL=7d\n' > ~/.config/claude-fleet/accounts/max20x.conf   # weekly-capped
   printf 'LIMIT_TTL=5h\n' > ~/.config/claude-fleet/accounts/pro.conf      # 5h session window
   ```

   `LIMIT_TTL` takes `<N>[smhd]` or bare seconds; accounts without a `.conf` use
   `FLEET_ACCOUNT_LIMIT_TTL` (default 5h). This stops a weekly-limited account
   from being un-benched every 5h and thrashing straight back into the same wall.

3. **(Optional) tune it in `fleet.conf`:**

   ```sh
   FLEET_ACCOUNTS_DIR="$HOME/.config/claude-fleet/accounts"  # default; override to relocate
   FLEET_ACCOUNTS="work personal"        # pin order/subset (default: all files, sorted)
   FLEET_ACCOUNT_LIMIT_TTL=18000         # how long a limited acct sits out (5h)
   ```

4. **Verify:** `sh ~/.claude/fleet/bin/fleet-doctor.sh` reports the token count
   and warns on empty or group/other-readable files. `bin/fleet-account.sh list`
   shows the pool, which one is active (`●`), and any that are limited.

That's it — the next session you spawn launches under the active account.

**Switch by hand.** `prefix A` opens a popup picker; Enter makes a choice active
for new sessions **and restarts this fleet's idle Claude windows in place** —
each gets a double ctrl-c, then relaunches via `fleet-claude.sh --continue`, so
it resumes its own transcript under the new account. Windows mid-turn
(`working`) or between `/loop` iterations (`looping`) are left alone; they pick
up the switch on their next restart. Esc cancels. The status-bar footer also
shows the active account as a green `◉ <account>` chip — **click it** to open
the same picker (it only appears, and is only clickable, when multi-account is
on).

## How it runs

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
        ├─ records: work is limited for FLEET_ACCOUNT_LIMIT_TTL
        ├─ rotates the active pointer → personal
        └─ (if FLEET_NOTIFY_CMD set) pings you once: "work hit its limit → personal"
        │
        ▼
   the NEXT spawned session launches under personal
```

- **`bin/fleet-account.sh`** is the single owner of the rotation state
  (`account.active` + `account.limited` in the shared cache dir). Commands:
  `active`, `token [label]`, `env`, `list`, `use <label>`, `rotate`,
  `mark-limited <label>`, `clear [label]`.
- **`bin/fleet-claude.sh`** is a transparent launcher: with a pool it exports the
  active token and tags the window; **with no pool it is just `exec claude`** —
  which is why every spawn path can route through it safely.
- The **collector** (`bin/tmux-dash-collect.sh`) does the detection. It already
  scrapes each pane for the usage-% line; this adds the "hit your … limit"
  banner match, attributes it to the window's `@cc_account`, and rotates.

Rotation is **round-robin over eligible accounts**: a limited one is skipped
until its TTL passes (or you clear it with `fleet-account.sh clear <label>`). If
*every* account is limited, the active pointer stays put so sessions still launch
(they'll just wait on the limit like a single-account fleet would).

## What auto-switch does and does **not** do

- ✅ **New sessions** spawned after a limit hit use the next healthy account.
- ✅ Works on **macOS and Linux** (token env var, not config-dir juggling).
- ✅ **Zero cost when off** — no token files ⇒ every code path is a no-op and the
  fleet is byte-for-byte its old single-account self.
- ⚠️ **A live process cannot hot-swap its token.** Claude Code binds its
  credential at launch. The manual picker (`prefix A`) compensates by
  restarting idle windows with `--continue` (they resume their transcript on
  the new account), but a session that is mid-turn — including one parked on a
  limit banner mid-response — keeps its old account until it is restarted.
  The automatic limit-hit rotation only redirects *new* spawns; it never
  restarts windows itself.
- ⚠️ **The usage proxy (`5h/7d` in the status bar) is aggregate**, summed across
  *all* accounts' transcripts — it can't attribute past tokens to an account
  after the fact. Treat it as total fleet consumption, not per-subscription.
- ⚠️ **Hooks/settings are shared** across accounts (one `~/.claude`). That's the
  point (it keeps the fleet working), but it means per-account settings aren't
  possible via this mechanism.

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
| No auto-switch on a limit | The window must carry `@cc_account` (only sessions launched via `fleet-claude.sh` do). Confirm with `tmux show-options -w @cc_account`. |
| An account never comes back | It's within its TTL. `fleet-account.sh clear <label>` forces it eligible now. |
| macOS: switching seems ignored | You must use token files — the Keychain ignores `CLAUDE_CONFIG_DIR`. `fleet-doctor.sh` reminds you of this. |
