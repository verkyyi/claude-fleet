# /fleet-sync-install — re-apply the merged fleet tooling to the live install

<!-- fleet skill · owner: steward -->

The tooling-fleet-only counterpart to `/fleet-land`: after claude-fleet's *own*
changes land on master, this re-applies them to the **live install**
(`~/.claude/fleet` — the checkout the daemons, hooks, and dash actually read).
It **mutates the live install and this machine's Claude config**: fast-forwards
`~/.claude/fleet`, reloads only the daemons that changed, re-merges the
`settings-hooks.json` delta into `~/.claude/settings.json`, and installs
new/changed `commands/*.md` into `~/.claude/commands/` (removing any renamed or
retired ones). Idempotent — safe to
re-run; a no-op when the live install is already at master. Steward-only.

Because it only makes sense for the fleet that *hosts this tooling*, it **refuses
on every other fleet** (see step 1). The normal flow: land the tooling PR(s) with
`/fleet-land` or `/fleet-land-train`, then run `/fleet-sync-install` **once** to make the live
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
  live install) — not `$FLEET_MAIN`, which `/fleet-land` already fast-forwarded.

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

Compute what changed between the two revs — this drives steps 3–8, so nothing
reloads or re-merges unless it actually moved. Use `--name-status -M` so
**renames** (`R old → new`) and **deletions** (`D old`) surface, not just the new
paths — step 5 needs the old path to remove a retired command:

```sh
git -C ~/.claude/fleet diff --name-status -M "$before" "$after"
```

## 2b. Migrate durable state to the per-fleet layout (idempotent — issue #181)

The fleet keeps its durable state as **one directory per fleet** —
`~/.config/claude-fleet/fleets/<session>/{conf,restore.map,bridge/,watch/,sweep.due}`.
Run the migrator once, right after the fast-forward, so an estate written in the
old flat layout (`<session>.conf`, `restore/<session>.map`,
`issue-bridge/bridge_<slug>.*`, …) moves to the new one. It is **idempotent and
safe to re-run** (already-migrated files are left in place), and the new bins
DUAL-READ both layouts, so a fleet keeps working across the land→migrate window.

```sh
bash ~/.claude/fleet/bin/fleet-migrate-layout.sh          # or --dry-run first to preview
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

## 5. Install new/changed fleet commands — and remove retired ones

If the step-2 diff touched any `commands/*.md`:

- **Install** each added/modified skill — every `A`/`M` path, plus the **new**
  path of each `R` rename — by copying it into `~/.claude/commands/`
  (overwriting). Only files carrying the `<!-- fleet skill · owner: … -->`
  marker; never touch the user's personal commands.
- **Remove** each retired skill from `~/.claude/commands/` — the **old** path of
  every `R` rename **and** every `D` deletion. A plain pull+copy only ever adds
  files, so a renamed skill would linger under **both** names; delete the stale
  bare-named one with `rm -f ~/.claude/commands/<old-basename>`. (This PR is the
  worked example: `claim.md → fleet-claim.md`, and likewise `ship.md`,
  `blocked.md`, `land.md`, `land-train.md` → `fleet-*.md` — the five old
  bare-named files must be removed, same rename-delete pattern as the earlier
  `merge-train.md → land-train.md`.)

If no `commands/*.md` changed, skip.

## 6. Re-apply the steward charter — only if it changed

The steward's standing orders live **flat** at `~/.claude/steward.md` (a personal
rail, *not* under the checkout — `bin/steward-session.sh` reads it from there when
it spawns/respawns a `plan` hub), while the canonical copy is `steward.md` at the
repo root. So a landed charter rewrite doesn't reach the live steward until it's
copied up. If the step-2 diff touched `steward.md`, re-apply it — but **don't
clobber local edits**: only overwrite when the live file still matches the
*pre-sync* repo version (or doesn't exist yet); otherwise leave it and warn.

```sh
if git -C ~/.claude/fleet diff --name-only "$before" "$after" | grep -qx 'steward.md'; then
  live=~/.claude/steward.md
  bsteward=$(mktemp)
  git -C ~/.claude/fleet show "$before:steward.md" > "$bsteward" 2>/dev/null || : > "$bsteward"
  if [ ! -f "$live" ] || cmp -s "$live" "$bsteward"; then
    cp ~/.claude/fleet/steward.md "$live"
    echo "steward.md: charter updated"
  else
    echo "steward.md: LOCAL EDITS — not overwritten; diff ~/.claude/fleet/steward.md against $live by hand"
  fi
  rm -f "$bsteward"
fi
```

A running steward re-reads the charter on its next respawn (or an explicit
re-read); it won't retroactively change a live session's already-adopted orders.
If `steward.md` didn't change, skip this step.

## 7. Refresh open (stale) dash panes in place — only if the launcher changed

An already-open dash keeps running the **old** `bin/tmux-dashboard.sh`: fzf reads
its `--bind`/`--header` **once at launch**, so new binds (e.g. a landed toggle)
don't appear until it's closed and reopened. If the step-2 diff touched the dash
**launcher**, respawn this fleet's open dash panes in place so they pick up the
new script automatically.

The most-used dash is often **not** the standalone `dash` window but an
**embedded pane in the steward/`plan` split** (dash above, steward below —
reached via `prefix+g` / `steward-zoom.sh`), so a window-name match alone misses
it. Instead, target **every dash pane in this fleet's session** by its pane
marker: `bin/tmux-dashboard.sh` sets `@dash=1` on launch (mirroring the steward
pane's `@steward=1`), so the pane — which just runs `bash` — is found robustly
without brittle `pane_current_command`/name heuristics.

**Trigger** — the diff touched `bin/tmux-dashboard.sh` (the fzf launcher — its
`--bind`/`--header` are fixed at launch) or `bin/tmux-dashboard-rows.sh`
(header-lines / row format). NOTE: the `dash-*.sh` bind **targets** are re-exec'd
on each keypress (fresh `bash`), so they're picked up live and do **not** need a
respawn — only the launcher does. The backlog (`prefix+b`) and config
(`prefix+c`) modals are `display-popup`s — ephemeral, reopened fresh each time —
so they're never stale and need no handling.

**Fleet-scoping (critical rail):** operate ONLY on the current fleet's tmux
session (`$S` from step 0 — `fleet_current_session`). NEVER respawn another
fleet's dash. Find every `@dash=1` pane in this session and respawn each in
place:

```sh
if git -C ~/.claude/fleet diff --name-only "$before" "$after" \
   | grep -qE '^bin/tmux-dashboard(-rows)?\.sh$'; then
  n=0
  for p in $(tmux list-panes -s -t "$S" -F '#{pane_id} #{@dash}' 2>/dev/null \
               | awk '$2==1{print $1}'); do
    tmux respawn-pane -k -t "$p" "bash ~/.claude/fleet/bin/tmux-dashboard.sh"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] && echo "refreshed $n dash pane(s)" || echo "no open dash to refresh"
fi
```

If the launcher didn't change, skip this step (leave the open dash alone). If no
`@dash` pane is open for this fleet, it's a no-op — report "no open dash".

## 8. Reload the tmux conf — unbind removed binds, then re-source (only if it changed)

`conf/tmux-attention.conf` is sourced into the **live tmux server**, but
`tmux source-file` only **adds/overwrites** bindings — it **cannot remove** a
`bind` that was *deleted* from the conf. So a landed change that drops a `bind`
line leaves the **old binding live** in every existing session until an explicit
`unbind` or a full tmux restart (issue #139; live precedent #135 removed
`bind j`, but `prefix+j` stayed bound and resurrected the standalone dash it had
just removed). Make the reload idempotent w.r.t. removals: diff the before/after
conf, `unbind-key` every bind that disappeared, **then** re-source so adds and
changes still apply.

`bin/tmux-conf-reload.sh` does exactly this — it parses the bind lines from the
`before` and `after` conf, computes `before \ after` = removed `(table, key)`
pairs (handling the prefix / `bind -n` / `bind -T <tbl>` forms plus the `-r`/`-N`
flags), unbinds each, then `source-file`s. **Trigger only** when the step-2 diff
touched `conf/tmux-attention.conf`:

```sh
if git -C ~/.claude/fleet diff --name-only "$before" "$after" \
   | grep -qx 'conf/tmux-attention.conf'; then
  # `before` conf as it was pre-sync (empty if the file is brand-new)
  bconf=$(mktemp)
  git -C ~/.claude/fleet show "$before:conf/tmux-attention.conf" > "$bconf" 2>/dev/null || : > "$bconf"
  bash ~/.claude/fleet/bin/tmux-conf-reload.sh \
    "$bconf" ~/.claude/fleet/conf/tmux-attention.conf ~/.tmux.conf
  rm -f "$bconf"
fi
```

It prints `reloaded conf (unbound N removed binds)` — surface that N in step 9.
Binds are **server-global** in tmux, so the unbind hits the ambient server (this
fleet's) — it doesn't target another server/socket. If the conf didn't change,
skip this step (no reload needed).

## 9. Report — keep it short

One line naming what synced: the `before → after` sha, and which of
{daemons reloaded, settings re-merged, commands installed/removed, steward charter
re-applied, dash panes refreshed (with the count), conf reloaded (with the
unbound count)} actually ran.
If you stopped at step 1 (wrong fleet) or step 2 (diverged / already current),
report that instead with the one-line reason.

---

Rails: operate on YOUR fleet's `$FLEET_REPO` only — never another fleet's repo,
sessions, or ledgers. `/fleet-sync-install` mutates the live install
(`~/.claude/fleet`) and `~/.claude` config, so it is deliberately fenced to the
self-hosting tooling fleet and refuses everywhere else. Landing is `/fleet-land`'s job;
this only re-applies already-landed tooling to the live install.
