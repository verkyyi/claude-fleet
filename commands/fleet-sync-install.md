# /fleet-sync-install — re-apply the merged fleet tooling to the live install

<!-- fleet skill · owner: steward -->

The live-install maintenance skill: after claude-fleet's *own*
changes land on master, this re-applies them to the **live install**
(`~/.claude/fleet` — the checkout the daemons, hooks, and dash actually read).
It **mutates the live install and this machine's Claude config**: fast-forwards
`~/.claude/fleet`, reloads only the daemons that changed, re-merges the
`settings-hooks.json` delta into `~/.claude/settings.json`, and installs
new/changed `commands/*.md` into `~/.claude/commands/` (removing any renamed or
retired ones). Idempotent — safe to
re-run; a no-op when the live install is already at master. Steward-only.

The live install is **shared, machine-global tooling** every fleet uses, so this
**runs from ANY fleet** — not only the one whose `$FLEET_REPO` is claude-fleet
(issue #256). It operates on `~/.claude/fleet` (always a claude-fleet checkout)
regardless of which fleet invokes it; the only precondition is that
`~/.claude/fleet` is a git checkout to fast-forward (see step 1). The normal flow:
get the tooling PR(s) merged (auto-merge, armed at ship; or `gh pr merge` by hand),
then run `/fleet-sync-install` **once** to make the live install match master.

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

**Scope-rail note:** this is a DELIBERATE, explicit exception to the steward
"work only on your bound repo" rail. `/fleet-sync-install` touches **machine-global
shared tooling** (`~/.claude/fleet` + `~/.claude` config), NOT the current or any
other fleet's repo, sessions, or ledger — it never mutates another fleet's
checkout. That's what makes it safe to run from a fleet bound to a different repo.

## 2. Fast-forward the live install

```sh
before=$(git -C ~/.claude/fleet rev-parse HEAD)
# Snapshot the PRE-SYNC conf right here — while HEAD is still `before` and the sha
# is freshly in hand — into a durable FILE. Step 8's unbind-aware reload needs the
# OLD conf to diff which binds were removed. Capturing it now (not re-deriving it
# from `$before` several Bash calls later) is the fix for issue #295: a lost/empty
# snapshot silently degraded the reload to "0 removed" while dropped binds (A/R/u)
# stayed live on both servers. A conf that didn't exist at `before` (brand-new file)
# legitimately yields an empty snapshot.
beforeconf=$(mktemp)
# BRACE the ref: this snippet runs in the operator's shell (zsh), and unbraced
# "$before:conf/…" makes zsh apply history/variable MODIFIER parsing to `:c`,
# mangling the ref to `<sha>onf/…` → `git show` fails → the `|| :` truncates the
# snapshot to EMPTY → step 8 reports "no readable before-conf" and can't diff
# removed binds (issue #325). "${before}:…" is safe in both zsh and bash.
git -C ~/.claude/fleet show "${before}:conf/tmux-attention.conf" > "$beforeconf" 2>/dev/null || : > "$beforeconf"
git -C ~/.claude/fleet pull --ff-only
after=$(git -C ~/.claude/fleet rev-parse HEAD)
echo "before=$before after=$after beforeconf=$beforeconf"
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
(collector / summarize / diskguard) re-reads its script
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
  bare-named one with `rm -f ~/.claude/commands/<old-basename>`. (Worked examples:
  the #283 renames `claim.md → fleet-claim.md`, likewise `ship.md`, `blocked.md`,
  `land.md`, `land-train.md` → `fleet-*.md`; and the #286 **deletions**
  `fleet-new-issue.md`, `fleet-status.md`, `fleet-cleanup.md` — folded into the new
  `/fleet-steward` charter — whose live copies must be `rm -f`'d, same D-pass.)

If no `commands/*.md` changed, skip.

## 5b. Install new/changed fleet skills — the `skills/` tree (issue #311)

Fleet also ships **skills** (`skills/<name>/` dirs) — repo-versioned base
skills that a fleet command or the agent may delegate to (e.g. `/fleet-handoff`
runs the base `handoff` skill verbatim). They install into Claude Code's user
skills dir `~/.claude/skills/`, the mirror of the `commands/` install — same
marker gate, same never-clobber-personal rule.

**A skill is a whole directory, not just its `SKILL.md`.** `skills/handoff/` is
SKILL.md-only, but `skills/doc-preview/` ships `share.sh` + `server.py` +
`render.mjs` beside its SKILL.md — and that SKILL.md invokes them at
`~/.claude/skills/doc-preview/…`, so the scripts must land alongside it or the
skill is a broken stub (issue #354). The unit of install/removal is therefore the
whole `skills/<name>/` dir.

If the step-2 diff touched any `skills/**` path, resolve the affected skill
`<name>`s (the second path segment) and, for each:

- **Install** each added/modified skill — any skill dir with an `A`/`M` file
  (or the **new** path of an `R` rename) — by mirroring the **entire**
  `skills/<name>/` dir into `~/.claude/skills/<name>/` (`mkdir -p` first, copy
  every file with `cp -p` to preserve executable bits like `share.sh`). Gate on
  the skill's `SKILL.md` carrying the `<!-- fleet skill -->` marker — that marker
  (which lives in the SKILL.md) is how sync recognises a repo-managed skill among
  the operator's **personal** skills, so it never touches a personal skill.
- **Never clobber a personal skill.** Before overwriting an existing
  `~/.claude/skills/<name>/`, check its `SKILL.md` for the `<!-- fleet skill -->`
  marker:
  - marker present → it's already fleet-managed; overwrite (a normal update).
  - marker **absent** → it's a personal skill (or, on THIS machine's **first**
    sync, the operator's pre-import copy an adoption issue absorbed). Overwrite
    it **only if its `SKILL.md` is byte-identical to the repo's imported version**
    (`cmp -s`); otherwise **warn and skip** the whole dir — the old steward.md
    dance: surface that a personal skill diverges from the repo copy and let the
    operator reconcile by hand, never silently replacing their edits.

  ```sh
  # per changed skill dir (e.g. rel="doc-preview" or "handoff"):
  src=~/.claude/fleet/skills/$rel          # source skill DIR (marker lives in SKILL.md)
  dst=~/.claude/skills/$rel                # dest skill DIR
  grep -qF '<!-- fleet skill -->' "$src/SKILL.md" || continue      # source gate
  if [ -f "$dst/SKILL.md" ] && ! grep -qF '<!-- fleet skill -->' "$dst/SKILL.md" \
       && ! cmp -s "$src/SKILL.md" "$dst/SKILL.md"; then
    echo "skills: $rel is a personal skill that diverges from the repo copy — leaving it; reconcile by hand (e.g. adopt the marked repo version), then re-run" >&2
  else
    mkdir -p "$dst" && cp -p "$src"/* "$dst"/                      # mirror SKILL.md + any scripts
  fi
  ```

- **Remove** each retired skill from `~/.claude/skills/` — a skill is retired
  when its `SKILL.md` is deleted (`D`) or renamed away (the **old** path of an
  `R`) — but, same gate as install, only when the live
  `~/.claude/skills/<name>/SKILL.md` still carries the `<!-- fleet skill -->`
  marker (never remove a personal skill). Remove the whole dir
  (`rm -rf ~/.claude/skills/<name>` — the marker confirms it's fleet-managed) so
  the supporting scripts go with it.

If no `skills/**` path changed, skip.

## 6. Steward charter — nothing extra to re-apply (issue #286)

The flat `~/.claude/steward.md` is **retired**. The steward charter is now the
`/fleet-steward` skill's built-in text (installed/updated by **step 5** like any
other `commands/*.md`), layered at spawn by `bin/steward-charter.sh` over an
optional gated repo `.fleet/steward.md` (synced with the bound repo, not by this)
and an operator overlay `~/.config/claude-fleet/fleets/<session>/steward.md`
(machine-local, never touched by sync — local edits live here now). So there is
**no separate charter copy-up step** — step 5 already carried it, and the old
local-edits dance is gone (the overlay is the proper home for edits).

One migration nicety: if a pre-#286 install still has a stale flat charter, point
it out (don't auto-delete — it may hold edits the operator wants to move to the
overlay):

```sh
[ -f ~/.claude/steward.md ] && echo "steward.md: obsolete flat charter present (issue #286) — the charter is now the /fleet-steward skill; move any local edits to ~/.config/claude-fleet/fleets/<session>/steward.md, then rm ~/.claude/steward.md"
```

A running steward re-adopts the charter on its next `/fleet-steward` (spawn/respawn
or `/clear`); it won't retroactively change a live session's already-adopted orders.

## 7 + 8. Refresh the UI on ALL live fleet servers — only what changed

Steps 7 (respawn stale dash panes) and 8 (unbind-aware conf reload) both re-apply
a landed **per-server** UI change — and the live install (`~/.claude/fleet`) is
**shared by every fleet**, yet each fleet runs on its OWN tmux socket (issue #159).
So a sync that touches the dash launcher or the conf must reach **every** live
fleet's server, not just this one — otherwise every OTHER fleet keeps a stale dash
pane + stale server binds until respawned by hand (issue #248). `bin/fleet-ui-refresh.sh
--all` fans BOTH refreshes out over `fleet_sockets` (the live fleets), running each
per-server against its own `-L <label>`.

**Why fan out here but nowhere else:** the one-fleet scoping rail stays for
everything NON-UI (daemons in step 3, settings in step 4, commands in step 5,
charter in step 6) — those touch machine-global or current-fleet state. Only the
open dash pane and the server binds are held *per tmux server*, so only these two
refreshes fan out across sockets.

**What each refresh fixes:**
- **Dash panes (step 7):** an already-open dash keeps running the **old**
  `bin/tmux-dashboard.sh` — fzf reads its `--bind`/`--header` **once at launch**, so
  new binds don't appear until it's reopened. The most-used dash is often the
  **embedded pane in the steward/`plan` split** (not a `dash` window), so panes are
  found by the `@dash=1` marker (`bin/tmux-dashboard.sh` sets it on launch), not a
  name. NOTE: the `dash-*.sh` bind **targets** are re-exec'd on each keypress (fresh
  `bash`), so they're live without a respawn — only the launcher needs one. The
  backlog/config modals are `display-popup`s (reopened fresh), never stale.
- **Conf binds (step 8):** `tmux source-file` only **adds/overwrites** bindings — it
  **cannot remove** a `bind` deleted from the conf, so a dropped `bind` stays live in
  every existing session until an explicit `unbind` (issue #139; #135 removed
  `bind j` but `prefix+j` stayed bound). `fleet-ui-refresh.sh --conf` drives the same
  `bin/tmux-conf-reload.sh` (now with `--socket`) per server: diff before/after,
  `unbind-key` every removed `(table, key)`, **then** re-source.

**Trigger — call it once, passing only the refreshes whose inputs changed:**

```sh
dash_changed=$(git -C ~/.claude/fleet diff --name-only "$before" "$after" \
  | grep -qE '^bin/tmux-dashboard(-rows)?\.sh$' && echo 1)
conf_changed=$(git -C ~/.claude/fleet diff --name-only "$before" "$after" \
  | grep -qx 'conf/tmux-attention.conf' && echo 1)

args=()
[ -n "$dash_changed" ] && args+=(--dash)
if [ -n "$conf_changed" ]; then
  # Use the durable pre-sync snapshot captured in step 2 ($beforeconf) — do NOT
  # re-derive it from `$before` here (a var that may be empty by now, or a git show
  # that silently yields the post-sync conf → "0 removed" + stale binds, issue #295).
  # If it came up empty while the conf DID change, the pre-sync conf was lost: the
  # reload can't diff removals, so say so — don't leave it silent.
  [ -s "$beforeconf" ] || echo "sync: pre-sync conf snapshot empty but conf/tmux-attention.conf changed — removed binds can't be diffed; the reload will report it, re-run with the real pre-change conf if a bind was dropped" >&2
  args+=(--conf "$beforeconf" ~/.claude/fleet/conf/tmux-attention.conf ~/.tmux.conf)
fi

if [ ${#args[@]} -gt 0 ]; then
  bash ~/.claude/fleet/bin/fleet-ui-refresh.sh --all "${args[@]}"
fi
[ -n "${beforeconf:-}" ] && rm -f "$beforeconf"
```

It prints a per-fleet line plus a summary (`refreshed N fleet(s); dash panes: X;
conf reloaded: Y`) — surface those counts in step 9. `--dry-run` previews without
touching anything. If neither the launcher nor the conf changed, skip this step
entirely (leave every fleet's dash + binds alone). Note the fan-out reaches only
CONFIGURED, live fleets (`fleet_sockets`) — never the user's ad-hoc default-socket
tmux; the same before-conf is handed to every server (a fleet may have sourced a
different vintage, but the live install is one checkout and the unbind is harmless
when a key is already gone).

## 9. Report — keep it short

One line naming what synced: the `before → after` sha, and which of
{daemons reloaded, settings re-merged, commands installed/removed (the
`/fleet-steward` charter rides here now), skills installed/removed (with any
personal-skill-diverged warning), dash panes refreshed (with the count),
conf reloaded (with the unbound count)} actually ran.
If you stopped at step 1 (wrong fleet) or step 2 (diverged / already current),
report that instead with the one-line reason.

---

Rails: `/fleet-sync-install` is the one deliberate exception to the steward
"operate on YOUR fleet's `$FLEET_REPO` only" rail — it mutates **machine-global
shared tooling** (the live install `~/.claude/fleet` + `~/.claude` config), never
another fleet's repo, sessions, or ledgers, so **any** fleet's steward may run it;
it refuses only when `~/.claude/fleet` isn't a git checkout to fast-forward.
Merging is GitHub auto-merge's job (the fleet never merges); this only re-applies
already-merged tooling to the live install.
