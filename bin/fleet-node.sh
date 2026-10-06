#!/bin/bash
# fleet-node.sh — `fleet node join` / `fleet node status` (issue #1627): adding
# a machine as a node is the same one command and one scan as `fleet login`.
#
#   fleet node join [--hub URL] [--invert] [--compute 0|1]
#                   [--no-fleet] [--no-deps] [--no-admin]
#       Run on the new machine, as the login that will run the fleet. No code,
#       no web page, no switches: the hub address is the one `fleet login` uses
#       (FLEET_HUB_URL / fleet.conf — fleet-login.py hub), the device key is the
#       one `fleet login` made (or makes it), and the QR opens the same
#       confirmation page, titled 「把 <机器名> 加为节点」. The confirmation
#       returns this machine's node pass; then fleet-node-join.sh runs its deps /
#       agent / service / online / fleet steps on their defaults, one `✓ …` line
#       each, and a failure is one `✗ …` line ending 「重跑同一条命令即可」.
#       A rerun whose node.env token the hub still accepts skips the scan and
#       redoes only what is missing. FLEET_ROLE gains `node` (fleet-conf.sh).
#       A first join only COORDINATES (issue #1719): node.env gets
#       CCQUOTA_FLEET_COMPUTE=0, so the hub places no session here and leases no
#       account; --compute 1 opens it. --no-fleet / --no-deps / --no-admin go to
#       fleet-node-join.sh as they are — the install line (fleet-install.sh)
#       joins with all three: the client is already there, and a laptop needs
#       no Homebrew packages and runs no account ops.
#   fleet node status
#       Like `fleet login status`: is this login a node, of which hub, and does
#       the hub see it online. Exit 0 only when it does.
#
# The old way — a join code from the hub's /nodes page and
# `fleet-node-join.sh --hub … --token fj_…` — still works for one version
# (EPIC #1615 decision 11).
#
# Env: FLEET_CONF_DIR (~/.config/claude-fleet) · FLEET_NODE_JOIN_ARGS (extra
# fleet-node-join.sh options, the selftest's seam — never needed by a person).
# Exit: 0 joined / online · 1 a step failed (rerun the same command) · 2 usage
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
ENVF="$CONF/node.env"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# envval <KEY> — one value from node.env ('' when absent)
envval() { [ -f "$ENVF" ] && sed -n "s/^$1=//p" "$ENVF" | head -n 1; }

# self <hub> <token> — the hub's /v1/node/self body; exit 0 iff it answered 200
self() { curl -fsS --max-time 15 -H "Authorization: Bearer $2" "$1/v1/node/self" 2>/dev/null; }

jfield() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -n 1; }

cmd_join() {
  local hub_arg="" invert="" hub tok work rc
  local pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --hub) hub_arg="${2:-}"; shift ;;
      --hub=*) hub_arg="${1#--hub=}" ;;
      --invert) invert=--invert ;;
      --compute) pass+=(--compute "${2:-}"); shift ;;
      --no-fleet|--no-deps|--no-admin) pass+=("$1") ;;
      -h|--help) usage; return 0 ;;
      *) echo "fleet node join: unknown option $1 (see fleet node --help)" >&2; return 2 ;;
    esac
    shift
  done
  if [ -n "$hub_arg" ]; then hub=$("$here/fleet-login.py" hub --hub "$hub_arg") || return 2
  else hub=$("$here/fleet-login.py" hub) || return 2; fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/fleet-node.XXXXXX") || { echo "fleet node join: no temp dir" >&2; return 1; }
  # the node pass is a credential: it lives in this 0700 dir only until
  # fleet-node-join.sh has moved it into node.env
  chmod 700 "$work"
  local joined=()
  tok=$(envval CCQUOTA_TOKEN)
  if [ -n "$tok" ] && [ "$(envval CCQUOTA_HUB_URL)" = "$hub" ] && self "$hub" "$tok" >/dev/null; then
    : # already a node of this hub: no scan; the join script skips its join step
  else
    # shellcheck disable=SC2086
    "$here/fleet-login.py" node --hub "$hub" --out "$work/node.json" $invert || { rc=$?; rm -rf "$work"; return "$rc"; }
    joined=(--joined "$work/node.json")
  fi
  "$here/fleet-conf.sh" set-hub "$hub" --role node >/dev/null 2>&1 \
    || echo "! 没能在 $CONF/fleet.conf 里记下 node 角色（fleet-conf.sh set-hub）" >&2

  # shellcheck disable=SC2086
  "$here/fleet-node-join.sh" --hub "$hub" --ui ${joined[@]+"${joined[@]}"} ${pass[@]+"${pass[@]}"} ${FLEET_NODE_JOIN_ARGS:-}
  rc=$?
  rm -rf "$work"
  return "$rc"
}

cmd_status() {
  local hub tok body st label
  tok=$(envval CCQUOTA_TOKEN)
  hub=$(envval CCQUOTA_HUB_URL)
  if [ -z "$tok" ] || [ -z "$hub" ]; then
    echo "这台机器（$(id -un)）还不是节点 — 运行：fleet node join"
    return 1
  fi
  if ! body=$(self "$hub" "$tok"); then
    echo "✗ $hub 不认这台机器的节点通行证（${ENVF}）— 重跑：fleet node join"
    return 1
  fi
  st=$(printf '%s' "$body" | jfield status)
  label="$(printf '%s' "$body" | jfield hostname)"
  [ -n "$label" ] || label=$(hostname -s 2>/dev/null || hostname)
  case "$st" in
    online) echo "✓ $label/$(id -un) 是 $hub 的节点：在线" ;;
    *) echo "✗ $label/$(id -un) 是 $hub 的节点，但入口看到的状态是「${st:-?}」— 看 ~/.ccquota/agent.log，或重跑：fleet node join"
       return 1 ;;
  esac
}

case "${1:-}" in
  join) shift; cmd_join "$@" ;;
  status) shift; cmd_status "$@" ;;
  ''|-h|--help|help) usage ;;
  *) echo "fleet node: unknown command ${1} — fleet node join | fleet node status" >&2; exit 2 ;;
esac
