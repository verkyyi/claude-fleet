# fleet-login.zsh — what an interactive login shell does for claude-fleet
# (issues #1068, #1166). Source it from ~/.zshrc:
#   source ~/.claude/fleet/shell/fleet-login.zsh
#
# 1. The login banner (shell/fleet-intro.sh): this login's fleet, its repos and
#    the one `cf` line to get in.
# 2. An interactive SSH login then goes straight into the fleet — `cf` attaches
#    to it, or starts it first when it isn't running. Detaching (or `cf` failing)
#    leaves you at this shell, as before.
#
# The gate lives HERE, not in the scripts: an interactive shell only, never inside
# tmux (every fleet pane sources .zshrc too). scp / rsync / `ssh host cmd` run a
# non-interactive shell and never reach either step; a local terminal has no
# $SSH_TTY and gets the banner only.
#
#   touch ~/.hushfleet          no banner, no auto-attach
#   touch ~/.hushfleet-attach   banner only — `cf` stays yours to type
#
# An anonymous function, so nothing but `cf` (from cw.zsh, when not already
# sourced) is left behind in the login shell.
() {
  [[ -o interactive ]] && [[ -z "$TMUX" ]] && [[ ! -f ~/.hushfleet ]] || return 0
  local here=${1:h}
  [[ -x $here/fleet-intro.sh ]] && $here/fleet-intro.sh
  [[ -n "$SSH_TTY" ]] && [[ ! -f ~/.hushfleet-attach ]] || return 0
  (( $+functions[cf] )) || source $here/cw.zsh
  cf
  return 0
} "${(%):-%x}"
