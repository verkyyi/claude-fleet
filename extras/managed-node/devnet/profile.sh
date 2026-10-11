# fleet: machine-wide dev settings for every login (claude-fleet#3348).
# Sourced by /etc/zsh/zshenv, /etc/bash.bashrc and login shells. The values live
# in /etc/fleet-devnet.env, which fleet-node-linux.py writes at each start from
# the pod's settings (render.py --cn-mirrors / --github-proxy); a value the login
# already has wins, and the login's own ~/.zshrc runs after this.
if [ -r /etc/fleet-devnet.env ] && [ -z "${FLEET_DEVNET_LOADED:-}" ]; then
  while IFS='=' read -r _fd_k _fd_v; do
    case "$_fd_k" in ''|'#'*|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    eval "[ -n \"\${$_fd_k:-}\" ] || export $_fd_k=\"\$_fd_v\""
  done < /etc/fleet-devnet.env
  unset _fd_k _fd_v
  export FLEET_DEVNET_LOADED=1
fi
# fnm reads a repo's .nvmrc on cd — interactive shells only, and not for a login
# that brought its own nvm (its ~/.zshrc puts nvm's node first anyway).
case "$-" in
  *i*)
    if command -v fnm >/dev/null 2>&1 && [ ! -s "$HOME/.nvm/nvm.sh" ] && [ -z "${FNM_MULTISHELL_PATH:-}" ]; then
      if [ -n "${ZSH_VERSION:-}" ]; then eval "$(fnm env --use-on-cd --shell zsh 2>/dev/null)"
      elif [ -n "${BASH_VERSION:-}" ]; then eval "$(fnm env --use-on-cd --shell bash 2>/dev/null)"
      fi
    fi ;;
esac
