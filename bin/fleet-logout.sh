#!/bin/bash
# fleet-logout.sh — `fleet logout [--keep-node]`: sign this computer out of the
# hub (issue #2212, 登录即登记's way back).
#
#   fleet logout               the node this computer's login registered leaves
#                              the hub (`fleet node leave`: its token retired,
#                              its agent stopped, node.env deleted), then the
#                              certificate, the ssh snippet and the DEVICE KEY
#                              are removed — so `fleet` cannot renew silently
#                              and the next `fleet` / `fleet login` scans again
#   fleet logout --keep-node   the same, but the node stays on the hub
#
# A computer with no node.env skips the leave; one with no certificate is
# already signed out (exit 0). The device record on the hub stays, unusable
# without its key; the operator removes it on the 连接 page if they want.
#
# Exit: 0 signed out · 1 the node could not leave (nothing else removed — rerun,
#   or --keep-node) · 2 usage
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
KEY="$HOME/.ssh/fleet-cert"

keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep-node) keep=1 ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fleet logout: unknown option $1 (fleet logout [--keep-node])" >&2; exit 2 ;;
  esac
  shift
done

if [ "$keep" = 0 ] && grep -q '^CCQUOTA_TOKEN=.' "$CONF/node.env" 2>/dev/null; then
  if ! FLEET_CONF_DIR="$CONF" "$here/fleet-node-leave.sh" --reason "fleet logout"; then
    echo "✗ 节点没能退出入口 — 什么都没删；重跑 fleet logout，或 fleet logout --keep-node 只退登录" >&2
    exit 1
  fi
fi
gone=0
for f in "$KEY-cert.pub" "$HOME/.ssh/fleet-ssh-config" "$KEY" "$KEY.pub"; do
  [ -e "$f" ] && rm -f "$f" && gone=1
done
if [ "$gone" = 1 ]; then
  echo "✓ 已退出登录：证书、ssh 配置和这台电脑的设备钥匙已删除（下次 fleet login 重新扫码）" >&2
else
  echo "✓ 这台电脑本来就没登录" >&2
fi
[ "$keep" = 1 ] && [ -f "$CONF/node.env" ] && echo "  节点保留在入口（node.env 未动；要退：fleet node leave）" >&2
exit 0
