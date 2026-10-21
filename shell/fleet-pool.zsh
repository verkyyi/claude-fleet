# fleet-pool.zsh — `claude` and `codex` typed at a managed login's shell run on the
# fleet's shared subscriptions (task KEA0): bin/fleet-pool-run.sh mints a session
# credential from this login's proxy, as a fleet session's launcher does.
# fleet-install-apply.sh's `pool` pass sources this from ~/.zshrc on a managed login
# (the `# >>> fleet-pool` block) and takes the block out again when released.
#   touch ~/.fleet-pool-off   — back to the plain programs (FLEET_SHELL_POOL=0: this shell only)
#   command claude …          — the plain program once
() {
  local run=${1:h}/../bin/fleet-pool-run.sh
  [[ -f $run ]] || return 0
  eval "claude() { bash ${(q)run} claude \"\$@\"; }"
  eval "codex() { bash ${(q)run} codex \"\$@\"; }"
} "${(%):-%x}"
