#!/bin/bash
# fleet-release-key.sh — the hub's release signing key this login trusts
# (issue #2773, EPIC #2770 C3 · 发起人拍板 5).
#
# Every release a login takes from the hub (fleet-install-sync.sh) is checked
# against ONE key, pinned the first time this login met the hub
# ($FLEET_CONF_DIR/release.pub, 0644 — fleet-install.sh or the first tick, see
# fleet-release-lib.sh). A hub that starts signing with another key is refused
# until a person says otherwise, here:
#
#   fleet-release-key.sh [status]      the pinned key's fingerprint, the hub's,
#                                      and whether they are the same
#   fleet-release-key.sh trust [--yes] take the hub's key: both fingerprints
#                                      printed, asked (y/N); --yes = compared
#                                      already. `fleet host trust-release-key`.
#
# No hub, or a hub that keeps no releases: says so, changes nothing.
# Exit: 0 same / trusted · 1 different (status) or not taken · 2 usage / no hub.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=fleet-release-lib.sh
. "$here/fleet-release-lib.sh"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
PK="$CONF/release.pub"
TMO="${FLEET_RELEASE_KEY_TIMEOUT:-10}"

verb="${1:-status}"; [ $# -gt 0 ] && shift
YES=0
for a in "$@"; do
  case "$a" in -y|--yes) YES=1 ;; *) echo "fleet host trust-release-key: 不认识 ${a}（--yes）" >&2; exit 2 ;; esac
done
case "$verb" in -h|--help|help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
hub=$(fleet_rel_hub_url)
# shellcheck disable=SC2034,SC1091  # FLEET_SHELL=1 picks fleet.conf's [client] section
[ -n "$hub" ] || hub=$(FLEET_SHELL=1; [ -f "$CONF/fleet.conf" ] && . "$CONF/fleet.conf" >/dev/null 2>&1; fleet_rel_hub_url)
[ -n "$hub" ] || { echo "这台没有接入口 — 没有要认的发布签名钥匙"; exit 2; }
tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-release-key.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
code=$(fleet_rel_http "$hub/v1/fleet/release/key" "$tmp" "$TMO")
case "$code" in
  200) fleet_rel_keyline "$tmp" || { echo "✗ 入口 ${hub} 答的不是一把 ed25519 钥匙"; exit 1; } ;;
  404) echo "入口 ${hub} 不存发布包（没有发布签名钥匙）— 什么都没改"; exit 2 ;;
  *)   echo "✗ 入口不可达（${hub}）：${REL_ERR:-HTTP $code}"; exit 1 ;;
esac
new=$(fleet_rel_fp "$tmp")
if [ -s "$PK" ]; then old=$(fleet_rel_fp "$PK"); else old=''; fi
case "$verb" in
  status)
    if [ -z "$old" ]; then echo "还没记下入口的钥匙；入口现在用的指纹 ${new}（下次取版本时记下）"; exit 0; fi
    if cmp -s <(head -n 1 "$tmp") "$PK"; then echo "认的钥匙 ${old} = 入口现在用的"; exit 0; fi
    echo "认的钥匙 ${old} ≠ 入口现在用的 ${new} — 入口的新版本不会被换上；确认是你们换了钥匙后：fleet host trust-release-key"
    exit 1 ;;
  trust)
    if [ -n "$old" ] && cmp -s <(head -n 1 "$tmp") "$PK"; then echo "认的钥匙 ${old} 就是入口现在用的 — 不用改"; exit 0; fi
    echo "入口 ${hub} 的发布签名钥匙"
    echo "  现在认的：${old:-（还没有）}"
    echo "  入口用的：${new}"
    if [ "$YES" != 1 ]; then
      if ! ( : </dev/tty ) 2>/dev/null; then echo "没有终端可问 — 核对指纹后加 --yes"; exit 1; fi
      printf '核对过这枚指纹、确认换成它？[y/N] ' >/dev/tty
      read -r ans </dev/tty || ans=''
      case "$ans" in y|Y|yes) ;; *) echo "没换"; exit 1 ;; esac
    fi
    mkdir -p "$CONF" && head -n 1 "$tmp" > "$PK.tmp" && chmod 0644 "$PK.tmp" && mv -f "$PK.tmp" "$PK" \
      || { echo "✗ 写不了 $PK"; exit 1; }
    echo "✓ 之后只认 ${new}（${PK}）"
    exit 0 ;;
  *) echo "fleet-release-key: status | trust [--yes]" >&2; exit 2 ;;
esac
