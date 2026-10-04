<!-- fleet:agent-defaults begin -->
## claude-fleet — rules on a managed machine

This login is managed by claude-fleet (`~/.claude/fleet`); a fleet session runs
with `approval_policy = "never"` / `sandbox_mode = "danger-full-access"` and the
fleet's hooks are its rails. Whatever the project:

- **A base checkout is read-only.** Fleet work happens in an `issue-<N>` /
  `scratch-<N>` git worktree and lands through its own PR; never commit to a
  repo's main checkout.
- **Never run destructive tmux on a fleet socket** (`kill-server`,
  `kill-session`, `kill-window` aimed at a sibling): every window on that socket
  is another live session. Test tmux tooling on an isolated socket (`tmux -L scratch`).
- **The operator's screen is their own computer**, reached over SSH. `open <url|file>`
  here shows it to nobody — use `~/.claude/fleet/bin/fleet-open.sh` /
  `fleet-show.sh`, or the doc-preview skill for a document.
- **A temp server binds `127.0.0.1`, never `*`**, and dies with the work.
- **Credentials never enter a config, a commit, an issue or a comment.** Tokens
  are read at start (`gh auth token`, the environment), never written down.
- **Load experiments go through `~/.claude/fleet/bin/fleet-loadgen.sh`**, never a
  hand-written background loop with a `trap`.
<!-- fleet:agent-defaults end -->
