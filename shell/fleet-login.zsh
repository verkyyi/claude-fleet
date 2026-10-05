# fleet-login.zsh — what an interactive login shell does for claude-fleet
# (issues #1068, #1166, #1711). Source it from ~/.zshrc:
#   source ~/.claude/fleet/shell/fleet-login.zsh
#
# 1. The login banner (shell/fleet-intro.sh): this login's fleet, its repo count
#    and the one `fleet` line to get in.
# 2. An interactive SSH login then opens the fleet CLIENT — bin/fleet, the same
#    client you run on your own computer (issue #1711, EPIC #1710 C1): on this
#    machine it reads this machine (no hub: #1712), its bar says 客户端在 <机器>
#    上运行. It is the one way in; the node's own session is never attached here.
#    Detaching (or the client failing) leaves you at this shell, as before.
#
# The gate lives HERE, not in the scripts: an interactive shell only, never inside
# tmux (every fleet pane — and every client pane — sources .zshrc too). scp /
# rsync / `ssh host cmd` (the client's own ssh into a machine included) run a
# non-interactive shell and never reach either step; a local terminal has no
# $SSH_TTY and gets the banner only.
#
#   touch ~/.hushfleet          no banner, no client
#   touch ~/.hushfleet-attach   banner only — `fleet` stays yours to type
#
# An anonymous function, so nothing is left behind in the login shell.
() {
  [[ -o interactive ]] && [[ -z "$TMUX" ]] && [[ ! -f ~/.hushfleet ]] || return 0
  local here=${1:h}
  [[ -x $here/fleet-intro.sh ]] && $here/fleet-intro.sh
  [[ -n "$SSH_TTY" ]] && [[ ! -f ~/.hushfleet-attach ]] || return 0
  [[ -x $here/../bin/fleet ]] && $here/../bin/fleet
  return 0
} "${(%):-%x}"
