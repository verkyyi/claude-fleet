#!/bin/bash
# fleet-node-leave.sh — `fleet node leave` (issue #1928, EPIC #2140 C6): this
# login takes itself off the hub, with no one inside the cluster.
#
#   fleet node leave [--reason <text>] [--hub-only] [--dry-run]
#
# Three steps, one `✓ …` / `✗ …` line each:
#   1. hub    POST <hub>/v1/node/leave with this login's node token (node.env):
#             the hub retires the enrollment — the token stops working
#             everywhere, its open link closes, its session passes and relay
#             credential go — drops its row from the machines page, and writes
#             one node_revoke audit row (actor node:<login>@<machine>). A token
#             the hub no longer knows (401) is already gone: the local steps
#             still run.
#   2. agent  stop the ccquota agent `fleet node join` started and remove its
#             service file: the LaunchAgent com.ccquota.agent, the LaunchDaemon
#             com.ccquota.agent.<login> (sudo -n — else the command to run is
#             printed), the systemd unit ccquota-agent[-<login>].service, or the
#             detached agent.pid.
#   3. env    delete node.env (the node token's one file).
# --hub-only does step 1 and 3 and leaves the agent alone — fleet-login-remove.sh
# runs it as the login it is deleting, whose services it boots out itself.
# --dry-run prints what would happen and changes nothing.
#
# A login that never joined (no node.env) has nothing to leave: one line, exit 0.
# The token is handed to curl on stdin (`-H @-`), never in an argv or a log.
#
# Exit: 0 left (or nothing to leave) · 1 the hub could not be asked
#   (unreachable — nothing changed; rerun) or a local step failed · 2 usage ·
#   4 the hub refused (a hub before #1928 answers 404/405 — nothing changed; the
#   operator can still remove it on the machines page)
#
# Env: FLEET_CONF_DIR (~/.config/claude-fleet) · seams for the selftest:
#   FLEET_HUB_CURL (curl), FLEET_LEAVE_OS (uname -s), FLEET_JOIN_SUDO (sudo -n),
#   FLEET_LEAVE_HOME ($HOME — where ~/.ccquota and LaunchAgents live),
#   FLEET_LEAVE_DAEMON_DIR (/Library/LaunchDaemons),
#   FLEET_LEAVE_UNIT_DIR (/etc/systemd/system)
set -uo pipefail

CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
ENVF="$CONF/node.env"
H="${FLEET_LEAVE_HOME:-$HOME}"
STATE="$H/.ccquota"
DDIR="${FLEET_LEAVE_DAEMON_DIR:-/Library/LaunchDaemons}"
UDIR="${FLEET_LEAVE_UNIT_DIR:-/etc/systemd/system}"
CURL="${FLEET_HUB_CURL:-curl}"
SUDO="${FLEET_JOIN_SUDO-sudo -n}"
OS="$(printf '%s' "${FLEET_LEAVE_OS:-$(uname -s)}" | tr '[:upper:]' '[:lower:]')"
ME="$(id -un)"
UID_N="$(id -u)"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

REASON='' HUBONLY=0 DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) [ $# -ge 2 ] || { echo "fleet node leave: --reason needs a text" >&2; exit 2; }; REASON=$2; shift ;;
    --reason=*) REASON=${1#--reason=} ;;
    --hub-only) HUBONLY=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fleet node leave: unknown option $1 (see fleet node leave --help)" >&2; exit 2 ;;
  esac
  shift
done
[ "${#REASON}" -le 200 ] || { echo "fleet node leave: --reason is at most 200 characters" >&2; exit 2; }
case "$REASON" in *'"'*|*\\*) echo "fleet node leave: --reason may not hold a quote or a backslash" >&2; exit 2 ;; esac

envval() { [ -f "$ENVF" ] && sed -n "s/^$1=//p" "$ENVF" | head -n 1; }
jfield() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -n 1; }
priv() {
  if [ "$UID_N" = 0 ]; then "$@"; return; fi
  [ -n "$SUDO" ] || return 1
  # shellcheck disable=SC2086
  $SUDO "$@"
}
# act <cmd…> — run it, or under --dry-run only say it
act() { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; return 0; fi; "$@"; }

TOK=$(envval CCQUOTA_TOKEN)
HUB=$(envval CCQUOTA_HUB_URL); HUB=${HUB%/}
if [ -z "$TOK" ]; then
  echo "这台电脑（${ME}）没有接入口，不用退出（this login is not a node: no ${ENVF}）"
  exit 0
fi
[ -n "$HUB" ] || { echo "✗ $ENVF 里没有入口地址（CCQUOTA_HUB_URL）— 没法让入口移除这台电脑；请管理员在机器页点「移除」（no hub URL in node.env）" >&2; exit 1; }

# ── 1. hub ──────────────────────────────────────────────────────────────────
body='{}'
[ -z "$REASON" ] || body="{\"reason\":\"$REASON\"}"
if [ "$DRY" = 1 ]; then
  echo "  would ask: POST $HUB/v1/node/leave (node token on stdin)"
else
  resp=$(printf 'Authorization: Bearer %s\n' "$TOK" | "$CURL" -sS --max-time 15 -o - -w '\n%{http_code}' \
    -H @- -H 'Content-Type: application/json' -X POST --data-binary "$body" "$HUB/v1/node/leave" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ -n "$resp" ] || { echo "✗ 连不上入口 ${HUB}（curl exit ${rc}）— 什么都没改；重跑同一条命令即可（hub unreachable, nothing changed）" >&2; exit 1; }
  code=$(printf '%s\n' "$resp" | tail -n 1)
  json=$(printf '%s\n' "$resp" | sed '$d')
  case "$code" in
    200)
      ep=$(printf '%s' "$json" | jfield endpoint_id)
      if printf '%s' "$json" | grep -q '"already":true'; then
        echo "✓ 入口早已移除这台电脑（${ep}）（the hub had already retired it）"
      else
        echo "✓ 入口已移除这台电脑：$ep 的通行证作废，机器页不再列它（the hub retired ${ep}）"
      fi ;;
    401) echo "✓ 入口已经不认这台电脑的通行证 — 当它已移除（the hub no longer knows this token）" ;;
    404|405) echo "✗ 入口 $HUB 还没有退出这条路（HTTP ${code}，早于 #1928）— 什么都没改；请管理员在机器页点「移除」，或升级入口（the hub predates node leave）" >&2; exit 4 ;;
    *) echo "✗ 入口拒绝了（HTTP ${code}：$(printf '%s' "$json" | head -c 200)）— 什么都没改（the hub refused）" >&2; exit 4 ;;
  esac
fi

# ── 2. agent ────────────────────────────────────────────────────────────────
LEFT=0
stop_agent() {
  local found=0 f label
  case "$OS" in
    darwin)
      f="$H/Library/LaunchAgents/com.ccquota.agent.plist"
      if [ -f "$f" ]; then
        found=1
        act launchctl bootout "gui/$UID_N/com.ccquota.agent" 2>/dev/null
        act rm -f "$f" || LEFT=1
      fi
      label="com.ccquota.agent.$ME"; f="$DDIR/$label.plist"
      if [ -f "$f" ]; then
        found=1
        if ! { act priv launchctl bootout "system/$label" 2>/dev/null; act priv rm -f "$f"; }; then
          echo "! 系统服务 $label 要管理员权限才能删，请运行：sudo launchctl bootout system/$label && sudo rm -f ${f}（needs sudo）" >&2
          LEFT=1
        fi
      fi ;;
    linux)
      f="$H/.config/systemd/user/ccquota-agent.service"
      if [ -f "$f" ]; then
        found=1
        act systemctl --user disable --now ccquota-agent.service 2>/dev/null
        act rm -f "$f" || LEFT=1
        act systemctl --user daemon-reload 2>/dev/null
      fi
      f="$UDIR/ccquota-agent-$ME.service"
      if [ -f "$f" ]; then
        found=1
        if ! { act priv systemctl disable --now "ccquota-agent-$ME.service" 2>/dev/null; act priv rm -f "$f"; }; then
          echo "! 系统服务 ccquota-agent-$ME 要管理员权限才能删，请运行：sudo systemctl disable --now ccquota-agent-$ME.service && sudo rm -f ${f}（needs sudo）" >&2
          LEFT=1
        fi
        act priv systemctl daemon-reload 2>/dev/null
      fi ;;
  esac
  f="$STATE/agent.pid"
  if [ -f "$f" ]; then
    found=1
    local pid; pid=$(cat "$f" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null && act kill "$pid" ;; esac
    act rm -f "$f"
  fi
  if [ "$found" = 0 ]; then echo "✓ 这台电脑没有在跑的入口 agent（no agent service found）"
  elif [ "$LEFT" = 0 ]; then echo "✓ agent 已停，服务已删（agent stopped, service removed）"; fi
}
[ "$HUBONLY" = 1 ] || stop_agent

# ── 3. env ──────────────────────────────────────────────────────────────────
if act rm -f "$ENVF"; then
  [ "$DRY" = 1 ] || rm -f "$(dirname "$ENVF")/node-login.ok" "$(dirname "$ENVF")/node-login.why"   # 登录即登记's once-per-hub mark (#2212) + its refusal (#2249)
  echo "✓ 已删 ${ENVF}（node token removed）"
else
  echo "✗ 删不掉 ${ENVF}（cannot remove node.env）" >&2; LEFT=1
fi
[ "$LEFT" = 0 ] || exit 1
exit 0
