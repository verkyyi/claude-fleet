# /fleet-sync-install — re-apply the merged fleet tooling to the live install

<!-- fleet skill · owner: steward -->

The tooling-fleet-only counterpart to `/land`: after claude-fleet's *own*
changes land on master, this re-applies them to the **live install**
(`~/.claude/fleet` — the checkout the daemons, hooks, and dash actually read).
It **mutates the live install and this machine's Claude config**: fast-forwards
`~/.claude/fleet`, reloads only the daemons that changed, re-merges the
`settings-hooks.json` delta into `~/.claude/settings.json`, and installs
new/changed `commands/*.md` into `~/.claude/commands/`. Idempotent — safe to
re-run; a no-op when the live install is already at master. Steward-only.

Because it only makes sense for the fleet that *hosts this tooling*, it **refuses
on every other fleet** (see step 1). The normal flow: land the tooling PR(s) with
`/land` or `/land-train`, then run `/fleet-sync-install` **once** to make the live
install match master.

**Argument** (`$ARGUMENTS`): none — takes no argument.

## 0. Resolve fleet + guard seat (run FIRST, every time)

Env vars do NOT persist across separate Bash tool calls — run this once, then
reuse the literal values it prints:

```sh
source ~/.claude/fleet/bin/fleet-lib.sh
S=$(fleet_current_session); fleet_load_conf "$S"   # → FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH
SEAT=$(fleet_seat)                                 # → worker | steward | "" (ambiguous)
echo "repo=${FLEET_REPO:-} main=${FLEET_MAIN:-} base=${FLEET_BASE_BRANCH:-master} seat=${SEAT:-unknown}"
```

- **No fleet** (`FLEET_REPO` empty) → **ABORT** in one line: *"not inside a
  fleet — run this from a fleet session."* Never guess a repo.
- **Wrong seat** — this skill is `owner: steward`. If `$SEAT` isn't `steward`,
  **refuse in one line and stop**, e.g. *"/fleet-sync-install is steward-only;
  you're in the worker seat."* Never proceed from the wrong seat.

## 1. Tooling-fleet guard (run BEFORE any mutation)

This skill only applies to the fleet whose `$FLEET_REPO` **is** the repo the live
install tracks. Compare `$FLEET_REPO` to the origin slug of `~/.claude/fleet`:

```sh
live_slug=$(git -C ~/.claude/fleet remote get-url origin 2>/dev/null \
  | sed -E 's#^(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')
echo "fleet_repo=${FLEET_REPO:-} live_slug=${live_slug:-none}"
```

- If `~/.claude/fleet` is missing/not a git checkout (`live_slug` empty), or
  `live_slug` **!=** `$FLEET_REPO` → **refuse in one line and stop**:
  *"/fleet-sync-install re-applies the fleet tooling to the live install — only
  runs on the claude-fleet tooling fleet."* Mutate nothing.
- If they match → proceed. Everything below operates on `~/.claude/fleet` (the
  live install) — not `$FLEET_MAIN`, which `/land` already fast-forwarded.

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
nothing to sync" and stop; the rest is a no-op.

Compute what changed between the two revs — this drives steps 3–5, so nothing
reloads or re-merges unless it actually moved:

```sh
git -C ~/.claude/fleet diff --name-only "$before" "$after"
```

## 3. Reload only the daemons that changed

Most script-body changes need **no reload**: an *interval* daemon
(collector / classify / summarize / diskguard / dispatch) re-reads its script
from disk on its next tick. Reload only when the diff (step 2) touched:

- a **plist/timer** under `launchd/` or `systemd/` (an interval or arguments
  changed) — reload that unit (macOS: `launchctl bootout` then `bootstrap`;
  Linux: `systemctl --user daemon-reload` + restart the timer), **or**
- the **KeepAlive spinner** (`bin/tmux-spinner.sh` /
  `com.claude-fleet.spinner`) — it's long-lived, so
  `launchctl kickstart -k gui/$(id -u)/com.claude-fleet.spinner`
  (Linux: `systemctl --user restart claude-fleet-spinner.service`).

If the diff touched none of these, say "no daemon reload needed" and move on.

## 4. Re-merge the settings-hooks delta (only if it changed)

If the diff (step 2) touched `hooks/settings-hooks.json`, re-merge the delta into
`~/.claude/settings.json` — **append** to the hook arrays, never clobber existing
entries, and **back it up first**:

```sh
cp ~/.claude/settings.json ~/.claude/settings.json.bak.$(date +%s)
```

Merge each hook array with jq using `+=` (creating keys that don't exist), then
de-dup so a re-run doesn't stack duplicate entries. If `settings-hooks.json`
didn't change, skip this step.

## 5. Install new/changed fleet commands

If the diff (step 2) touched any `commands/*.md`, copy the changed ones into
`~/.claude/commands/` — **append/overwrite the fleet skills only** (the ones
carrying the `<!-- fleet skill · owner: … -->` marker); never touch the user's
personal commands. A rename in the repo (an `R` line in the step-2 diff, old →
new path) leaves the **old** file behind in `~/.claude/commands/` — remove the
stale fleet skill too, so a retired command name doesn't linger. If no
`commands/*.md` changed, skip.

## 6. Report — keep it short

One line naming what synced: the `before → after` sha, and which of
{daemons reloaded, settings re-merged, commands installed/removed} actually ran.
If you stopped at step 1 (wrong fleet) or step 2 (diverged / already current),
report that instead with the one-line reason.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. `/fleet-sync-install` mutates the live install
(`~/.claude/fleet`) and `~/.claude` config, so it is deliberately fenced to the
self-hosting tooling fleet and refuses everywhere else. Landing is `/land`'s job;
this only re-applies already-landed tooling to the live install.
