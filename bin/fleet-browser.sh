#!/bin/bash
# fleet-browser.sh — a session's web pages open on YOUR computer, and an OAuth
# callback to localhost:<port> comes back to the session (issue #3236).
#
#   fleet-browser.sh <url>            the agent's browser: $BIN/fleet-open.sh --browser <url>
#   fleet-browser.sh on | off | status
#   fleet-browser.sh enabled          exit 0 ⇔ on (the launchers ask this)
#   fleet-browser.sh hook             the plugin's SessionStart hook: BROWSER for Bash
#
# OFF unless the person turns it on. ON = the marketplace plugin `fleet-browser`
# is installed and enabled for this login (Claude Code's own `enabledPlugins`
# in ~/.claude/settings.json — the one record; `on` / `off` only run
# `claude plugin install|enable|disable`). While on:
#   * every session the fleet opens here gets BROWSER=<this script> — Claude Code
#     runs `$BROWSER <url>` for an MCP authorization, /login, a page it opens; a
#     Codex on Linux reads the same variable (its macOS build opens through
#     LaunchServices and ignores it — said in `status`). A plugin cannot set its
#     agent's own environment (a plugin settings.json keeps only `agent`), so
#     fleet-claude.sh / fleet-codex.sh export it — the one place outside the plugin;
#   * the plugin's SessionStart hook writes the same BROWSER into CLAUDE_ENV_FILE,
#     so a `gh auth login --web`, an `npm login`, a dev server's «open the
#     browser» in the Bash tool take the same road;
#   * fleet-open.sh --browser reads an OAuth page's loopback redirect_uri port
#     (`cport`) and the person's client forwards exactly that port over its own
#     ssh to this machine before it opens the page — one line on their screen
#     names the port, the session and when it closes; it closes as soon as the
#     session's callback server is gone, or after FLEET_OPEN_CALLBACK_SECS (600).
# OFF: no BROWSER, nothing read, nothing forwarded — byte for byte as before.
#
# Log: $FLEET_CONF_DIR/logs/browser.log — time · result · host · cport (never the
# URL: an authorize URL carries its state).
#
# Exit: <url> 0 handed on (fleet-open's result line on stderr), 1 fleet-open
# refused the address · enabled 0 on / 1 off · on/off 0 done, 1 `claude plugin`
# failed · 2 usage.
# Seams (tests): FLEET_BROWSER_SETTINGS (the settings.json read), FLEET_BROWSER_CLAUDE
# (the claude binary), FLEET_BROWSER_OPEN (fleet-open.sh), FLEET_BROWSER (0|1: the
# answer of `enabled`, over the plugin's state).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="fleet-browser@claude-fleet"
CONF="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
LOG="$CONF/logs/browser.log"

say_what() {
  cat <<'EOF'
fleet-browser：会话要打开网页时，在你的电脑上打开；授权回调要回到会话时，
在你的 ssh 连接上临时转发那一个端口，用完即关（每次转发都会提示一行，并记日志）。
EOF
}

enabled() {
  case "${FLEET_BROWSER:-}" in 1) return 0 ;; 0) return 1 ;; esac
  local f="${FLEET_BROWSER_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
  [ -f "$f" ] || return 1
  python3 - "$f" "$PLUGIN" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if (d.get("enabledPlugins") or {}).get(sys.argv[2]) is True else 1)
PY
}

claude_cmd() {
  local c="${FLEET_BROWSER_CLAUDE:-}"
  [ -n "$c" ] || c=$(command -v claude 2>/dev/null) || c=''
  [ -n "$c" ] || { printf 'fleet-browser: claude not found\n' >&2; return 1; }
  printf '%s' "$c"
}

log() {  # <result> <host> <cport>
  { mkdir -p "$(dirname "$LOG")" && printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$LOG"; } 2>/dev/null
  return 0
}

case "${1:-}" in
  enabled) enabled; exit $? ;;
  status)
    if enabled; then echo 'fleet-browser: on'; else echo 'fleet-browser: off'; fi
    say_what
    [ "$(uname -s)" = Darwin ] && echo '（Codex 在 macOS 上自己开浏览器，不读 BROWSER：它的授权仍需手动粘贴回调地址。）'
    exit 0 ;;
  on)
    c=$(claude_cmd) || exit 1
    say_what
    "$c" plugin install "$PLUGIN" >/dev/null 2>&1 || :
    "$c" plugin enable "$PLUGIN" >/dev/null 2>&1 || :
    enabled || { printf 'fleet-browser: 没能打开（claude plugin install %s 失败）\n' "$PLUGIN" >&2; exit 1; }
    echo 'fleet-browser: on — 新开的会话生效（已开的会话 /fleet-handoff 或重开后生效）'
    exit 0 ;;
  off)
    c=$(claude_cmd) || exit 1
    "$c" plugin disable "$PLUGIN" >/dev/null 2>&1 || :
    enabled && { printf 'fleet-browser: 没能关掉（claude plugin disable %s 失败）\n' "$PLUGIN" >&2; exit 1; }
    echo 'fleet-browser: off — 新开的会话不再转发'
    exit 0 ;;
  hook)
    # SessionStart (the plugin is enabled, or this would not run): the Bash tool's
    # commands get the same opener. Never fails a session start.
    if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
      printf 'export BROWSER=%q\n' "$BIN/fleet-browser.sh" >> "$CLAUDE_ENV_FILE" 2>/dev/null || :
    fi
    exit 0 ;;
  ''|-h|--help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    [ -n "${1:-}" ] && exit 0 || exit 2 ;;
esac

# ---- the agent's browser: one URL --------------------------------------------
url="$1"
host=$(python3 -c 'import sys
from urllib.parse import urlsplit
try: print(urlsplit(sys.argv[1]).hostname or "-")
except Exception: print("-")' "$url" 2>/dev/null)
cport=$(FLEET_OPEN_CALLBACK=1 python3 "$BIN/fleet-open-addr.py" "$url" 2>/dev/null | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read().split("\t")[1]).get("cport") or "-")
except Exception: print("-")' 2>/dev/null)
res=$(bash "${FLEET_BROWSER_OPEN:-$BIN/fleet-open.sh}" --browser -- "$url"); rc=$?
log "${res:-rc=$rc}" "${host:--}" "${cport:--}"
[ "$rc" = 1 ] && exit 1
exit 0
