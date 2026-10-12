#!/bin/bash
# fleet-feedback-switch.sh — /fleet-feedback on or off for this login (issue #3360,
# EPIC #3354 C6). `fleet feedback on|off|status` dispatches here.
#
#   fleet-feedback-switch.sh on | off | status
#   fleet-feedback-switch.sh enabled          exit 0 ⇔ on
#
# ON = the marketplace plugin `fleet-feedback` is installed and enabled for this
# login — Claude Code's own `enabledPlugins` in ~/.claude/settings.json is the one
# record (as fleet-browser.sh); `on` / `off` only run `claude plugin
# install|enable|disable`.
#
# Who has it by default:
#   * a MANAGED login (fleet_node_manages — the machine daemon runs it): the
#     install-apply `plugins` pass installs + enables it ONCE and writes it into
#     $FLEET_CONF_DIR/plugins-defaulted.json; from then on it is the person's —
#     `off` stays off through every upgrade (docs/dev/MANAGED-NODE.md §18);
#   * anyone's own computer: nothing is installed; `on` turns it on.
#
# Exit: enabled 0 on / 1 off · on/off 0 done, 1 `claude plugin` failed · status 0 ·
#       2 usage.
# Seams (tests): FLEET_FEEDBACK_PLUGIN_SETTINGS (the settings.json read — the same
# seam fleet-feedback.sh reads), FLEET_FEEDBACK_CLAUDE (the claude binary),
# FLEET_FEEDBACK_MANAGED (0|1 over fleet_node_manages).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="fleet-feedback@claude-fleet"
CONF="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
REC="$CONF/plugins-defaulted.json"

enabled() {
  local f="${FLEET_FEEDBACK_PLUGIN_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
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

managed() {
  case "${FLEET_FEEDBACK_MANAGED:-}" in 1) return 0 ;; 0) return 1 ;; esac
  # shellcheck source=/dev/null
  [ -f "$BIN/fleet-daemon-lib.sh" ] && . "$BIN/fleet-daemon-lib.sh" 2>/dev/null \
    && command -v fleet_node_manages >/dev/null 2>&1 && fleet_node_manages
}

defaulted() {  # the record holds fleet-feedback
  [ -f "$REC" ] && python3 -c 'import json, sys
sys.exit(0 if "fleet-feedback" in json.load(open(sys.argv[1])) else 1)' "$REC" 2>/dev/null
}

claude_cmd() {
  local c="${FLEET_FEEDBACK_CLAUDE:-}"
  [ -n "$c" ] || c=$(command -v claude 2>/dev/null) || c=''
  [ -n "$c" ] || { printf 'fleet feedback: claude not found\n' >&2; return 1; }
  printf '%s' "$c"
}

case "${1:-}" in
  enabled) enabled; exit $? ;;
  status)
    if managed; then kind='托管登录（默认开；fleet feedback off 关掉后升级也不再开）'
    else kind='自己的电脑（默认关；fleet feedback on 打开）'; fi
    if enabled; then echo "fleet-feedback: 开 · /fleet-feedback 可用 · $kind"
    else echo "fleet-feedback: 关 · $kind"; fi
    if managed; then
      if defaulted; then echo '默认    已在这个登录默认装过一次（plugins-defaulted.json），之后由你决定'
      else echo '默认    还没装过：下次同步（install-apply 的 plugins 一步）装上并打开'; fi
    fi
    # the sender's own view: hub · token · outbox (its plugin line is the one above)
    [ -f "$BIN/fleet-feedback.sh" ] && bash "$BIN/fleet-feedback.sh" status 2>/dev/null | grep -v '^plugin '
    exit 0 ;;
  on)
    c=$(claude_cmd) || exit 1
    "$c" plugin install "$PLUGIN" >/dev/null 2>&1 || :
    "$c" plugin enable "$PLUGIN" >/dev/null 2>&1 || :
    enabled || { printf 'fleet feedback: 没能打开（claude plugin install %s 失败）\n' "$PLUGIN" >&2; exit 1; }
    echo 'fleet-feedback: 开 — 新开的会话里有 /fleet-feedback（已开的会话 /fleet-handoff 或重开后生效）'
    exit 0 ;;
  off)
    c=$(claude_cmd) || exit 1
    "$c" plugin disable "$PLUGIN" >/dev/null 2>&1 || :
    enabled && { printf 'fleet feedback: 没能关掉（claude plugin disable %s 失败）\n' "$PLUGIN" >&2; exit 1; }
    if managed; then echo 'fleet-feedback: 关 — 新开的会话不再有 /fleet-feedback；升级也不会再打开它'
    else echo 'fleet-feedback: 关 — 新开的会话不再有 /fleet-feedback'; fi
    exit 0 ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
