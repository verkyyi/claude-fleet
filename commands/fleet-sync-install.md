# /fleet-sync-install — re-apply the merged fleet tooling to the live install

<!-- fleet skill · owner: either -->

The live-install maintenance skill: after claude-fleet's *own*
changes land on master, this re-applies them to the **live install**
(`~/.claude/fleet` — the checkout the daemons, hooks, and dash actually read).
It **mutates the live install and this machine's Claude config**: fast-forwards
`~/.claude/fleet`, then hands the move to `bin/fleet-install-apply.sh` — which
reloads only the daemons that changed, re-merges the `settings-hooks.json` delta,
and installs new/changed commands and skills (removing retired ones). Idempotent — safe to
re-run; a no-op when the live install is already at master. Normally run from the
hub pane, but it has no seat gate (issue #439) — the live install is machine-global.

**On a plugin install those last three passes are Claude Code's job** (issue
#611): commands, `skills/` and the hook table ship as the `fleet` plugin, and
`/plugin update` replaces them. What stays here either way is the half no plugin
can do — `bin/`, `conf/` and the daemons, which live at the stable
`~/.claude/fleet` the daemons and tmux binds read. The apply step decides which.

The live install is **shared, machine-global tooling** every fleet uses, so this
**runs from ANY fleet** — not only the one whose `$FLEET_REPO` is claude-fleet
(issue #256). It operates on `~/.claude/fleet` (always a claude-fleet checkout)
regardless of which fleet invokes it; the only precondition is that
`~/.claude/fleet` is a git checkout to fast-forward (see step 1). The normal flow:
get the tooling PR(s) merged (the shipping worker lands its own on green, #441; or
`gh pr merge` by hand),
then run `/fleet-sync-install` **once** to make the live install match master.

**Do I need to run it?** `sh ~/.claude/fleet/bin/fleet-install-version.sh` answers
that in one line — `CURRENT`, or `BEHIND` with the commit count (issue #635). It
is the same check `fleet-doctor.sh`'s `install` line prints, and it exists because
this command is **per-machine and manual**: on 2026-09-14 macmini's live install
sat 28 commits behind master while doctor was green on both machines. Run it on
the machine you have not synced lately, not only the one you are typing on.

**Argument** (`$ARGUMENTS`): none — takes no argument.

## 0. Resolve fleet (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **No seat gate** (issue #439). The live install is shared machine-global
  tooling, so any fleet pane may run this — in practice the operator runs it from
  the hub after the tooling PRs land.

## 1. Live-install check (run BEFORE any mutation)

`/fleet-sync-install` maintains the **shared** live install (`~/.claude/fleet`) —
machine-global tooling every fleet uses — so it runs from ANY fleet, **not only**
the one whose `$FLEET_REPO` is claude-fleet. The only precondition is that the
live install actually is a git checkout to fast-forward. Confirm that:

```sh
live_slug=$(git -C ~/.claude/fleet remote get-url origin 2>/dev/null \
  | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
echo "live_slug=${live_slug:-none}"
```

- If `~/.claude/fleet` is missing / not a git checkout / has no origin
  (`live_slug` empty) → **refuse gracefully in one line and stop**:
  *"`~/.claude/fleet` isn't a git checkout — nothing to sync."* Mutate nothing.
  (On a file-copy install `live_slug` is empty, so this path correctly refuses.)
- Otherwise → proceed. **Do NOT compare `live_slug` to `$FLEET_REPO`** — the
  repo-match fence was deliberately dropped (issue #256): the skill only ever
  touches `~/.claude/fleet`, never `$FLEET_MAIN`, so the current fleet's repo is
  irrelevant. Everything below operates on `~/.claude/fleet` (the live install) —
  not `$FLEET_MAIN`, which the cleanup daemon already fast-forwarded.

**Scope-rail note:** this is a DELIBERATE, explicit exception to the
"work only on your bound repo" rail. `/fleet-sync-install` touches **machine-global
shared tooling** (`~/.claude/fleet` + `~/.claude` config), NOT the current or any
other fleet's repo, sessions, or ledger — it never mutates another fleet's
checkout. That's what makes it safe to run from a fleet bound to a different repo.

## 2. Fast-forward the live install

```sh
before=$(git -C ~/.claude/fleet rev-parse HEAD)
git -C ~/.claude/fleet pull --ff-only
after=$(git -C ~/.claude/fleet rev-parse HEAD)
echo "before=$before after=$after"
```

If it refuses to fast-forward, **stop and report** — the live install diverged
(someone edited it in place); resolve that by hand before re-running. If
`before == after`, the live install was already current — say "already at master,
nothing to sync" and **jump to step 4** (the other logins can drift while this
one is current).

## 3. Apply the move — ONE command (issue #1119)

Everything a move implies beyond the files themselves is one non-interactive
script, the same one the install-sync daemon runs, so a hand sync and an
automatic one cannot drift apart:

```sh
bash ~/.claude/fleet/bin/fleet-install-apply.sh --from "$before" --to "$after"
```

Driven by the `before..after` diff, so nothing reloads or re-merges unless it
actually moved. One line per step (`<step>: …`), in this order:

- **layout** — the per-fleet state migrator (`fleet-migrate-layout.sh`, #181).
- **daemons** — a changed `launchd/*.plist.tmpl` (or `systemd/` unit) is
  re-rendered and reloaded (`bootout`+`bootstrap`; `daemon-reload`+restart); an
  added one installed + loaded; a retired one unloaded + its plist removed; a
  changed `bin/tmux-spinner.sh` kickstarts the KeepAlive spinner. A script-only
  change reloads nothing — an interval daemon re-reads its script each tick. A
  changed unit this login never installed is left alone. A login whose daemons
  are system LaunchDaemons (`UserName`) keeps that shape; without passwordless
  sudo it prints the admin commands instead.
- **plugin** — on a plugin install, `claude plugin update fleet` replaces the
  three passes below (both run when a copy install sits beside it). The update
  reaches the NEXT session, not this one.
- **hooks** — `settings-hooks.json` changed → `fleet-hooks-merge.py merge`
  (identity merge, #818); its `replaced` / `removed …` / `appended` lines follow.
- **commands** — added/changed fleet commands installed into
  `~/.claude/commands/`, retired ones removed, personal ones never touched. The
  gate (#858) is a line that **is** `<!-- fleet skill · owner: <owner> -->`,
  outside a code fence — so `commands/README.md`, which only quotes the marker,
  is never installed as a `/README` skill (and one an older sync left behind is
  removed).
- **skills** — each changed `skills/<name>/` mirrored whole (scripts + exec
  bits); a personal skill that diverges is warned about and left alone.
- **ui** — dash launcher or `conf/tmux-attention.conf` changed →
  `fleet-ui-refresh.sh --all` on every live fleet, with `--from`'s conf as the
  before-file for the unbind diff (#248, #295).
- **repark** — stale sleeping-worker pages re-parked on every live fleet (#1064).

The last line is `apply: ok …`, or `apply: PARTIAL …` with exit 1 — the `FAIL`
lines above it name the step and what to do. Exit 2 is a usage error (`--to`
must be the install's HEAD). `--dry-run` previews without changing anything.

## 4. Bring the machine's other logins along (issue #1069)

A shared machine has one `~/.claude/fleet` **per login**, each with its own
daemons — and this command only ever moved yours. On 2026-09-23 four of the Mac
mini's five logins sat 5–13 days behind the fifth, 120–130 scripts each, with every
daemon green. So finish by syncing them from this install:

```sh
bash ~/.claude/fleet/bin/fleet-sync-logins.sh
```

It plans first (per login: shape, head, drift, local edits), then — as each login
— backs up what will change, rsyncs the git-tracked entries of THIS install's
HEAD (a guest install gets only the entries it already has; `fleet.conf`, `logs/`
and `.git/` are never touched), moves a checkout's HEAD to match, and kickstarts
that login's daemons. A machine with one login prints "nothing to sync" (exit 0).
Act on the exit code — it is the reason:

- **0** — every other login is at this commit.
- **4** — a login was **blocked**: it has local edits, or its install is NEWER
  than this one. Don't `--force` it blindly — newer means run the sync from THAT
  login instead; edits are someone's work (the plan line names the files).
- **5** — no passwordless sudo for another login's files. Nothing changed for it;
  relay the printed `sudo … --logins <u>` command to the operator.
- **6** — a sync or its verification failed; the line names the backup to
  restore from.

A login the table shows as shape `copy` is a file-copy install: it cannot say
which commit it holds (only a sync marker can) and cannot update itself. Turn it
into a clone once — `bash ~/.claude/fleet/bin/fleet-sync-logins.sh --to-git`
(`--dry-run` first; `--logins a,b` to pick) — and it becomes an ordinary
checkout at the version it had, origin = the public repo over https, with
`fleet.conf`, `logs/` and its local files carried across and the old dir kept
whole as `~u/.claude/fleet.copy-<date>` (issue #1121). Logins that are already
checkouts are skipped; a copy with local edits is blocked (`--force` converts,
the old dir keeps the edits). The same exit codes apply; `--to-git` never runs
the sync itself — run the plain command afterwards to bring the new checkout
forward.

`--dry-run` previews. Relay its last line
(`other logins on this machine: N synced / M skipped · K already current`) in
step 5.

## 5. Report — keep it short

One line naming what synced: the `before → after` sha, the apply's final line,
any of its lines that did something (a daemon reloaded / added / retired, hooks
re-merged, commands or skills installed / removed, a personal-skill WARN, dash
panes refreshed, conf reloaded, pages re-parked) or FAILed, and step 4's line.
If you stopped at step 1 (not a checkout) or step 2 (diverged / already current),
report that instead with the one-line reason.

---

Rails: `/fleet-sync-install` is the one deliberate exception to the
"operate on YOUR fleet's `$FLEET_REPO` only" rail — it mutates **machine-global
shared tooling** (the live install `~/.claude/fleet` + `~/.claude` config), never
another fleet's repo, sessions, or ledgers, so **any** fleet may run it;
it refuses only when `~/.claude/fleet` isn't a git checkout to fast-forward.
Merging belongs to the worker that shipped the PR (or the operator, by hand); this
only re-applies already-merged tooling to the live install.
