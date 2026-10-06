#!/bin/bash
# fleet-host.sh — `fleet host on|off|status` (issue #1806, EPIC #1813 C4): the
# one switch for 承载 (host) — whether this computer runs sessions.
#
# Every computer has the fleet (the part everyone has: the client, `fleet`, the
# Agent package); 承载 is the optional part on top. The machine's config says it
# in one key, FLEET_HOST=1 in fleet.conf (fleet-conf.sh). The hub's protocol
# keeps its own word for it — node (node.env, /v1/node/*, `fleet node …`) — and
# this command is the person's spelling of those internal steps
# (docs/TERMS.md「承载 ↔ node」):
#
#   fleet host on [--yes] [--force] [--personal|--shared]
#       Says what will happen, asks (y/N; --yes = already asked), then:
#       with a hub — `fleet node join` when this login is no node yet or has no
#       fleet of its own here (deps, the agent, ~/.claude/fleet; a node whose
#       pass still works is not scanned again), then `fleet node compute on`
#       (it probes first and refuses with the reason; --force / --personal /
#       --shared go to it as they are); without one — the fleet on this
#       computer runs the sessions, nothing to join. Then FLEET_HOST=1.
#   fleet host off
#       `fleet node compute off` (the hub places nothing here any more), and
#       FLEET_HOST=0. When `fleet host on` was what made this login a node, off
#       takes that back too: the agent it started stops, and node.env is put
#       aside (node.env.host-off) so a later `on` needs no new scan — the
#       processes and the config are what they were before `on`.
#   fleet host status
#       One line: 能力 基础 · 承载 已开 / 未开, then the hub's word when this
#       login is a node.
#
# No terminal and no --yes: prints what `on` would do and exits 2 — never a
# silent change. Exit 0 done / on / off · 1 a step failed or was refused · 2 usage
# or not confirmed.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
ENVF="$CONF/node.env"
JOINED="$CONF/host-joined"      # `on` made this login a node — `off` undoes it
MARK="claude-fleet node-join (issue #1418)"   # what fleet-node-join.sh writes into its service files

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

envval() { [ -f "$ENVF" ] && sed -n "s/^$1=//p" "$ENVF" | head -n 1; }
is_node() { [ -n "$(envval CCQUOTA_TOKEN)" ]; }

# hub — this machine's hub address ('' = none: one computer on its own)
hub() {
  local u="${FLEET_HUB_URL:-}"
  [ -n "$u" ] || u=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}FLEET_HUB_URL=//p' "$CONF/fleet.conf" 2>/dev/null \
    | tail -n 1 | sed 's/[[:space:]]#.*$//' | tr -d "\"' ")
  printf '%s' "${u%/}"
}

# runtime — does this computer have the part that runs sessions (the git
# install with fleet-up.sh — never on the client's file list)?
runtime() { [ -f "$here/fleet-up.sh" ] || [ -f "${FLEET_LIVE_DIR:-$HOME/.claude/fleet}/bin/fleet-up.sh" ]; }

host_now() { bash "$here/fleet-conf.sh" host 2>/dev/null || echo 0; }

cap_line() {   # the doctor's 能力 row, in words
  if [ "$(host_now)" = 1 ]; then echo "能力: 基础 · 承载 已开      关掉：fleet host off"
  else echo "能力: 基础 · 承载 未开      要在这台跑会话：fleet host on"; fi
}

# ask <what> — 0 = go. --yes skips; no terminal = never a silent yes.
ask() {
  [ "$YES" = 1 ] && return 0
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "（这里没有终端可问：确认就敲 fleet host $1 --yes）"
    return 2
  fi
  local a
  printf '要%s吗？ [y/N] ' "$( [ "$1" = on ] && echo 打开 || echo 关掉 )"
  read -r a || a=''
  case "$a" in y|Y|yes|是) return 0 ;; esac
  echo "没改：能力照旧"
  return 2
}

# agent_stop — the agent fleet-node-join.sh started for this login (only a file
# carrying its mark; a LaunchDaemon needs root and is only named).
agent_stop() {
  local p="$HOME/Library/LaunchAgents/com.ccquota.agent.plist"
  local u="$HOME/.config/systemd/user/ccquota-agent.service"
  local pidf="$HOME/.ccquota/agent.pid" d
  if [ -f "$p" ] && grep -q "$MARK" "$p" 2>/dev/null; then
    launchctl bootout "gui/$(id -u)/com.ccquota.agent" >/dev/null 2>&1
    rm -f "$p"; echo "✓ 停了入口程序（LaunchAgent com.ccquota.agent）"
  fi
  if [ -f "$u" ] && grep -q "$MARK" "$u" 2>/dev/null; then
    systemctl --user disable --now ccquota-agent.service >/dev/null 2>&1
    rm -f "$u"; echo "✓ 停了入口程序（systemd ccquota-agent）"
  fi
  if [ -f "$pidf" ]; then
    kill "$(cat "$pidf")" 2>/dev/null && echo "✓ 停了入口程序（pid $(cat "$pidf")）"
    rm -f "$pidf"
  fi
  d="/Library/LaunchDaemons/com.ccquota.agent.$(id -un).plist"
  if [ -f "$d" ] && grep -q "$MARK" "$d" 2>/dev/null; then
    echo "! 入口程序是系统服务 ${d}，要 root 才能停：sudo launchctl bootout system/com.ccquota.agent.$(id -un) && sudo rm $d"
  fi
}

cmd_on() {
  local h was_node=0 restored=0 rc
  h=$(hub)
  if [ "$(host_now)" = 1 ] && { [ -z "$h" ] || { is_node && [ "$(envval CCQUOTA_FLEET_COMPUTE)" != 0 ]; }; }; then
    echo "承载 已开 — 什么都不用做"; cap_line; return 0
  fi
  if [ -z "$h" ] && ! runtime; then
    echo "✗ 这台没有跑会话的那部分 fleet（~/.claude/fleet），也没接入口可以帮它装：按 docs/INSTALL.md 装上后再敲 fleet host on"
    return 1
  fi
  echo "这会让这台电脑跑执行会话："
  if [ -n "$h" ]; then
    is_node && runtime || echo "  · 装 tmux、git 和跑会话的 fleet（已有就跳过）"
    echo "  · 起后台进程：入口程序和 fleet 的后台程序，合盖前自动进维护"
    echo "  · 入口开始往这台派会话（个人电脑只派你自己开的）"
  else
    echo "  · 这台的 fleet 跑会话，不接入口"
  fi
  ask on || return $?
  if [ -n "$h" ]; then
    is_node && was_node=1
    # the pass `off` put aside: back in place, and the join reruns (no scan —
    # the hub still takes it) to start the agent `off` stopped
    if [ "$was_node" = 0 ] && [ -f "$ENVF.host-off" ] && [ ! -f "$ENVF" ]; then
      mv -f "$ENVF.host-off" "$ENVF" && restored=1 && echo "✓ 沿用上次关掉时留下的入口通行证"
    fi
    if [ "$restored" = 1 ] || ! is_node || ! runtime; then
      "$here/fleet-node.sh" join; rc=$?
      [ "$rc" = 0 ] || { echo "✗ 没连上入口（上面一行说了哪步）— 重跑 fleet host on 即可"; return 1; }
      [ "$was_node" = 1 ] || : > "$JOINED"
    fi
    "$here/fleet-node.sh" compute on ${PASS[@]+"${PASS[@]}"}; rc=$?
    [ "$rc" = 0 ] || { echo "✗ 承载 没开（上面一行是原因）"; cap_line; return 1; }
  fi
  bash "$here/fleet-conf.sh" set-host 1 || { echo "✗ 写不了 $CONF/fleet.conf"; return 1; }
  cap_line
}

cmd_off() {
  if [ "$(host_now)" != 1 ] && ! { is_node && [ "$(envval CCQUOTA_FLEET_COMPUTE)" != 0 ]; }; then
    echo "承载 本来就没开"; cap_line; return 0
  fi
  if is_node; then
    "$here/fleet-node.sh" compute off || { echo "✗ 没关成（上面一行是原因）"; return 1; }
  fi
  if [ -f "$JOINED" ]; then
    agent_stop
    [ -f "$ENVF" ] && mv -f "$ENVF" "$ENVF.host-off" && echo "✓ 入口通行证放到一边（$ENVF.host-off，再打开时不用重扫）"
    rm -f "$JOINED"
  fi
  bash "$here/fleet-conf.sh" set-host 0 || { echo "✗ 写不了 $CONF/fleet.conf"; return 1; }
  cap_line
}

cmd_status() {
  cap_line | sed 's/      .*//'
  if is_node; then
    "$here/fleet-node.sh" compute status 2>/dev/null | head -n 1 | sed 's/^/入口: /'
  elif [ -z "$(hub)" ]; then
    echo "入口: 不接（这台自己跑）"
  fi
  return 0
}

YES=0; PASS=()
verb="${1:-status}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) YES=1 ;;
    --force|--personal|--shared) PASS+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fleet host: 不认识 $1 — fleet host on [--yes] [--force] [--personal|--shared] | off | status" >&2; exit 2 ;;
  esac
  shift
done
case "$verb" in
  on) cmd_on ;;
  off) cmd_off ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) echo "fleet host: on | off | status（fleet host --help）" >&2; exit 2 ;;
esac
