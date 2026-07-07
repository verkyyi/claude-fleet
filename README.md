# claude-fleet

Run a **fleet of parallel Claude Code sessions** in one tmux session — one
window per task, each in its own git worktree, with **GitHub issues as the
backlog** and the tmux status bar as a live attention monitor.

Born from driving ~7 concurrent Claude sessions (including long-running
`/loop`s) against a production monorepo from a single always-on Mac mini.

![dashboard](docs/img/dashboard.svg)
![status bar](docs/img/statusbar.svg)

<sub>Screenshots are the real UI captured from a live tmux server, staged with
demo repo data.</sub>

## What you get

- **Attention signals in the window list.** Claude Code hooks stamp each
  window's state the instant it changes: a **cyan braille spinner** pulses
  while a session works, **indigo** while a `/loop` waits between iterations,
  **green ✓** when a turn finishes, **red ! + bell** when a session is blocked
  on your answer. No polling lag — colors flip on the hook, not on the
  status-interval timer.

- **Urgency-sorted windows.** Windows re-slot themselves so position 1 is
  always the session that needs you most (needs > done > working > looping >
  idle). Your view never jumps — the sorter restores focus after every move.
  `prefix+a` hops to the neediest window.

- **A mission-control dashboard** (`prefix+j`): an fzf panel listing every
  session with state glyph, bound issue, model, context %, and a one-line LLM
  summary of what it's doing. `Enter` jumps. **Type a task and press Enter** —
  it files a GitHub issue and spawns a new worktree session bound to it.
  `Ctrl-G` binds a window to an existing issue, `Ctrl-E` renames.

![backlog](docs/img/backlog.svg)

- **GitHub backlog panel** (`prefix+b`): open issues grouped by milestone
  (roadmap | unplanned panes). `Enter` on an issue creates a worktree
  `issue-<N>` off your base branch and starts `claude` seeded to read, claim,
  and implement it. Issues being worked show `▶ <window>`.

- **Background collectors** keep it all instant: a 45-second daemon caches
  git status per worktree, the repo's PR/CI map, open issues, per-session
  context tokens, and a local 5h/7d token-usage proxy. The dashboard only
  ever reads caches — zero inline git/gh/LLM calls.

- **Worktree lifecycle**: `cw <branch>` spawns a worktree + Claude window;
  an hourly janitor removes worktrees that are merged + clean + not attached
  to any live pane (and never anything else).

## Architecture

```
Claude Code hooks (PreToolUse/PostToolUse/Stop/Notification)
      │  instant, semantic-blind
      ▼
@claude_state on the tmux window ──► spinner daemon (0.12s frames, single
      ▲                               writer, change-detected) ──► window list
      │  slow, semantic                                            colors/glyphs
LLM classifier (haiku, ~5min, change-gated)                        + urgency sort
      
collector daemon (45s) ──► cache files ──► fzf dashboard / backlog panels
  git · gh PRs+issues ·                     (read-only producers, render instantly)
  ctx tokens · usage proxy
summarizer daemon (haiku, 3min, change-gated) ──► one-line summary column
```

Design rules that made it work:

- **Hooks are fast but blind; the LLM is smart but slow.** Hooks give the
  instant working/done/needs signal; a change-gated haiku classifier later
  corrects what hooks can't know (e.g. "done" that's actually a `/loop`
  between iterations). Both write the same `@claude_state`.
- **One writer per surface.** A single spinner daemon owns all window styling
  (one `tmux source-file` per frame = one repaint); a single collector owns
  every cache file; producers are read-only.
- **Loud/quiet hierarchy.** Only "needs you" is loud (red, bold, bell).
  Everything else is quiet fg-color text — 7 spinning windows shouldn't shout.
- **Change-gate every LLM call.** Summaries/classifications only fire when a
  pane's content checksum changed; a parked session costs zero tokens.
- **Every session is bound to a GitHub issue.** New work enters through the
  backlog (typed tasks auto-file an issue), so nothing runs untracked.

## Install

The installer is Claude itself — `CLAUDE.md` in this repo is the playbook:

```sh
git clone https://github.com/verkyyi/claude-fleet.git
cd claude-fleet
claude "install claude-fleet on this machine"
```

Claude will check dependencies, copy the scripts to `~/.claude/fleet/`, write
your `fleet.conf` (backlog repo, main checkout, base branch), append one
source line to `~/.tmux.conf`, merge five hook entries into
`~/.claude/settings.json`, set up the launchd daemons (or systemd timers on
Linux), and verify each piece — asking before it touches anything.

Prefer manual? Every step is in [CLAUDE.md](CLAUDE.md); the pieces are plain
shell scripts with no hidden state.

### Dependencies

tmux ≥ 3.2 · [fzf](https://github.com/junegunn/fzf) ≥ 0.44 ·
[gh](https://cli.github.com/) (authed) · python3 · jq ·
[Claude Code](https://claude.com/claude-code) (the `claude` CLI; also used by
the two optional LLM daemons)

## Keybindings (prefix defaults to your tmux prefix)

| Key | Action |
|---|---|
| `prefix a` | jump to the next window that needs you (red first, then green) |
| `prefix j` | dashboard — jump / new task / bind issue / rename |
| `prefix b` | toggle the backlog window (roadmap \| unplanned) |
| `prefix i` | popup: open PRs (+CI) & issues for the current pane's repo |
| `prefix r` | reload tmux config |

## Configuration

One file, `~/.claude/fleet/fleet.conf` (see
[fleet.conf.example](fleet.conf.example)):

```sh
FLEET_REPO="you/your-repo"            # backlog + PR/CI source
FLEET_MAIN="$HOME/projects/your-repo" # worktrees are created as its siblings
FLEET_BASE_BRANCH="main"
FLEET_PROTECTED_RE="^(master|main|develop|test)$"
FLEET_CTX_WINDOW=200000               # 1000000 if you run 1M-context models
```

## Opening links over SSH

`--web`-style commands open a browser on the *remote* host — useless over
SSH. Everything here routes URLs through `bin/open-url.sh` instead:

1. **Tunnel mode (recommended)** — on your laptop, add to `~/.ssh/config`:

   ```
   Host your-remote
     RemoteForward 2226 127.0.0.1:2226
   ```

   and keep `extras/laptop-url-opener.sh` running (ad hoc, or as a login
   item). URLs sent by the remote host then open instantly in your local
   browser, riding the existing SSH connection — nothing else exposed.

2. **Fallback (zero setup)** — without the tunnel, you get a tmux popup with
   the URL (cmd-clickable in iTerm) already OSC52-copied to your local
   clipboard (`set-clipboard on` is in the shipped tmux conf).

## Assumptions & limitations

- **One tmux session ↔ one GitHub repo.** The PR/issue map is one repo-wide
  `gh` call. Multi-repo fleets would need per-window repo detection.
- Windows named `dash`, `plan`, or `backlog` are treated as panels, not
  Claude sessions.
- Window **numbers are not stable** (the urgency sorter re-slots them). The
  lowest-indexed window is pinned — keep your dashboard there. Navigate by
  name/position; slot 1 is always the most urgent.
- The `Notification` hook (red/bell) can lag a question by up to ~1 min
  (Claude Code's idle threshold); the classifier corrects stragglers.
- The token-usage figures are a **local proxy** — the official rate-limit %
  isn't exposed by any API. Weights: output×1 + input×0.25 + cache-write×0.25
  + cache-read×0.02 over rolling 5h/7d windows.
- The summarizer and classifier spend real (haiku-sized, change-gated)
  tokens. Both are optional; everything else works without them.
- Daemon templates are macOS launchd; Linux users need to translate to
  systemd user timers (Claude will do this during install).

## Safety notes for parallel fleets

Things that bit us and are worth adding on top (not included here because
they're environment-specific): a `PreToolUse` guard hook that blocks
dangerous commands (force-push to main, prod-database writes, destructive
`kubectl`), a lease file so only one session at a time deploys to a shared
test environment, and "claim the issue before working it" as convention.
The issue-per-session binding in this repo is the foundation for all three.

## License

MIT
