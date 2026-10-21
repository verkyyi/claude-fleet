#!/usr/bin/env bash
# fleet-pool-run.sh claude|codex [args…] — a person's own `claude` / `codex`, typed at
# a managed login's shell, on the fleet's shared subscriptions (task KEA0).
#
# shell/fleet-pool.zsh routes the two commands here. A fleet session gets its
# credential from its launcher (fleet-claude.sh / fleet-codex.sh); a person who
# ssh'd in and types `claude` had none, and wrote a script of their own to reach
# the pool. This is that script, once, the launchers' own road:
#
#   1. a sid of its own and `fleet-session-cred.sh mint` for it (the login's
#      credential proxy; this process is the session's wrapper — it stays alive
#      while the agent runs, so the proxy keeps the session);
#   2. claude: ANTHROPIC_BASE_URL=127.0.0.1:<port> + CLAUDE_CODE_OAUTH_TOKEN=<the
#      session credential> + CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 (共同约定 2);
#      codex: a credential-free CODEX_HOME mirror and the `fleet` model provider,
#      FLEET_CODEX_SESSION_CRED its env_key — as bin/fleet-codex.sh does;
#   3. the agent as a child; at its exit `fleet-session-cred.sh revoke`.
#
# The credential travels in the agent's environment only — never argv, a file or
# a log. Nothing is bound (exit 3 switched off · 4 the ambient login) or the mint
# failed ⇒ one line says so and the program runs as it would without this.
# Passed straight through: ~/.fleet-pool-off, FLEET_SHELL_POOL=0, or an
# environment already wired (FLEET_CRED_SID, or ANTHROPIC_BASE_URL for claude).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
tool="${1:-}"
case "$tool" in claude|codex) shift ;; *) echo "usage: fleet-pool-run.sh claude|codex [args…]" >&2; exit 2 ;; esac

say() { printf '\033[2mfleet · %s\033[0m\n' "$1" >&2; }

# the program itself: the first on PATH that is not this script
real=''
IFS=: read -r -a _dirs <<< "${PATH:-}"
for d in ${_dirs[@]+"${_dirs[@]}"}; do
  [ -n "$d" ] && [ -x "$d/$tool" ] && [ ! -d "$d/$tool" ] || continue
  [ "$d/$tool" -ef "$0" ] && continue
  real="$d/$tool"; break
done
[ -n "$real" ] || { echo "fleet-pool-run: no $tool on PATH" >&2; exit 127; }

plain() { exec "$real" "$@"; }
[ "${FLEET_SHELL_POOL:-1}" = 0 ] && plain "$@"
[ -e "${HOME:-/nonexistent}/.fleet-pool-off" ] && plain "$@"
[ -n "${FLEET_CRED_SID:-}" ] && plain "$@"
[ "$tool" = claude ] && [ -n "${ANTHROPIC_BASE_URL:-}" ] && plain "$@"

SC="${FLEET_POOL_SESSION_CRED:-$BIN/fleet-session-cred.sh}"
sid="pool-$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')"
[ "$sid" != pool- ] || sid="pool-$$-$(date +%s)"
mintargs=(--provider "$tool" --sid "$sid")
[ "$tool" = codex ] && mintargs+=(--codex-home "${CODEX_HOME:-$HOME/.codex}")
px=$(FLEET_SESSION_WRAP=$$ bash "$SC" mint "${mintargs[@]}" 2>/dev/null); rc=$?
case "$rc" in
  0) ;;
  3|4) plain "$@" ;;
  *) say "共享订阅这次没接上（凭证代理没给会话凭证，rc=${rc}）— 照常运行 ${tool}"; plain "$@" ;;
esac
IFS=$'\t' read -r route port cred <<< "$px"; px=''
case "$port" in ''|*[!0-9]*) say "共享订阅这次没接上（凭证代理的回答不对）— 照常运行 ${tool}"; plain "$@" ;; esac

flags=()
if [ "$tool" = claude ]; then
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
  export ANTHROPIC_BASE_URL="http://127.0.0.1:$port" CLAUDE_CODE_OAUTH_TOKEN="$cred"
  export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
else
  home=$(bash "$SC" codex-home --sid "$sid" --real "${CODEX_HOME:-$HOME/.codex}" 2>/dev/null) || home=''
  if [ -z "$home" ]; then
    bash "$SC" revoke --sid "$sid" >/dev/null 2>&1
    say "共享订阅这次没接上（没能做出不带凭证的 CODEX_HOME）— 照常运行 codex"; plain "$@"
  fi
  export CODEX_HOME="$home" FLEET_CODEX_SESSION_CRED="$cred"
  flags=(-c 'model_provider="fleet"'
         -c "model_providers.fleet={name=\"fleet\",base_url=\"http://127.0.0.1:$port/codex\",env_key=\"FLEET_CODEX_SESSION_CRED\",wire_api=\"responses\"}"
         -c 'features.apps=false' -c 'analytics.enabled=false' -c 'features.plugins=false')
fi
cred=''
say "共享订阅 · 本登录的凭证代理（${route:-direct}）· 关掉：touch ~/.fleet-pool-off"
export FLEET_POOL_SID="$sid"
trap ':' INT QUIT   # a handler, never SIG_IGN (which the agent would inherit): the agent takes ⌃C, this waits and revokes
"$real" ${flags[@]+"${flags[@]}"} "$@"
st=$?
bash "$SC" revoke --sid "$sid" >/dev/null 2>&1 || :
exit "$st"
