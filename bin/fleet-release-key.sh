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
#                                      and whether its chain endorses the root
#   fleet-release-key.sh trust [--yes] take the hub's key: both fingerprints
#                                      printed, asked (y/N); --yes = compared
#                                      already. `fleet host trust-release-key`.
#   fleet-release-key.sh scan [path…]  is a release signing PRIVATE key on this
#                                      computer (this environment, $FLEET_CONF_DIR,
#                                      ~/.ssh, ~/.config, or <path>)? One FOUND
#                                      line each, exit 1 (BREAK-IT
#                                      release-key-outside-train; the doctor's
#                                      releasekey row)
#
# Since issue #3559 the key a login pins is the offline ROOT: the signing key
# lives only in the release train, the root vouches for it (each release's
# key_chain) and revokes it (a root-signed list, kept in release.pub.revoked
# once seen). A login pinned to the hub's old signing key moves to the root by
# itself at its next update; `trust` is the manual road only for a root that
# itself changed. status says who signs and what is revoked; managed / runtime-
# linked logins use the machine pin, since their login pin does not drive updates.
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
if [ "$verb" = scan ]; then
  # no hub needed: what this computer holds (issue #3559)
  pin=""; [ -s "$PK" ] && pin="$PK"
  man=""
  for m in "$HOME/.claude/fleet/.release/manifest.json" "$CONF/release/manifest.json"; do [ -s "$m" ] && { man="$m"; break; }; done
  [ $# -gt 0 ] || set -- "$CONF" "$HOME/.ssh" "$HOME/.config"
  exec python3 "$here/fleet-release-sign.py" scan ${pin:+--pin "$pin"} ${man:+--manifest "$man"} "$@"
fi
YES=0
for a in "$@"; do
  case "$a" in -y|--yes) YES=1 ;; *) echo "fleet host trust-release-key: 不认识 ${a}（--yes）" >&2; exit 2 ;; esac
done
case "$verb" in -h|--help|help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
if [ "$verb" = status ]; then
  # Same ownership as install-sync: adopted accounts and runtime-linked logins
  # follow the machine updater. Only status reads its pin; trust is unchanged.
  # shellcheck source=fleet-daemon-lib.sh
  . "$here/fleet-daemon-lib.sh"
  node_root="${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}"
  # ~/.claude/fleet → <runtime>/current (#4669), or an older tree's .fleet-linked (compat-1v: 下一批删)
  linked_root=$(sed -n 's/.*"root": *"\([^"]*\)".*/\1/p' "$HOME/.claude/fleet/.fleet-linked" 2>/dev/null)
  _lt=$(readlink "$HOME/.claude/fleet" 2>/dev/null); _lt=${_lt%/}
  [ "${_lt##*/}" = current ] && linked_root=${_lt%/*}
  if fleet_node_manages || { [ -n "$linked_root" ] && [ -d "$linked_root" ] && [ -d "$node_root" ] \
      && [ "$(cd "$linked_root" && pwd -P)" = "$(cd "$node_root" && pwd -P)" ]; }; then
    PK="${FLEET_NODE_STATE:-/var/db/fleet-node}/release.pub"
    echo "托管登录：跟随机器运行时，登录级 pin 不起作用；以机器级 ${PK} 为准"
    [ -r "$PK" ] && [ -s "$PK" ] || { echo "机器级钥匙不可读：${PK} — 无法判断发布信任"; exit 1; }
  fi
fi
hub=$(fleet_rel_hub_url)
# shellcheck disable=SC2034,SC1091  # FLEET_SHELL=1 picks fleet.conf's [client] section
[ -n "$hub" ] || hub=$(FLEET_SHELL=1; [ -f "$CONF/fleet.conf" ] && . "$CONF/fleet.conf" >/dev/null 2>&1; fleet_rel_hub_url)
[ -n "$hub" ] || { echo "这台没有接入口 — 没有要认的发布签名钥匙"; exit 2; }
tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-release-key.XXXXXX") || exit 1
trap 'rm -f "$tmp" "$tmp.manifest"' EXIT
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
    signer=$(curl -sS --max-time "$TMO" -D - -o /dev/null "$hub/v1/fleet/release/key" 2>/dev/null |
      tr -d '\r' | awk -F': ' 'tolower($1) == "x-ccquota-release-signer" { print $2 }')
    case "$signer" in
      train) echo "签名的：发布列车（入口不握签名私钥，#3559）" ;;
      hub)   echo "签名的：入口自己（签名私钥还在入口里 — docs/dev/FLEET-HUB.md「发布签名」把它挪进列车）" ;;
      *)     echo "签名的：入口自己（这个入口早于 #3559）" ;;
    esac
    if [ -s "$PK.revoked" ]; then
      python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
k = d.get("keys") or []
print("作废单：记下 %d 把（%s）· 版本 %s" % (len(k), " ".join(k) or "-", d.get("version") or 0))' "$PK.revoked" 2>/dev/null || echo "作废单：$PK.revoked 读不了"
    else
      echo "作废单：没有"
    fi
    if [ -z "$old" ]; then echo "还没记下入口的钥匙；入口现在用的指纹 ${new}（下次取版本时记下）"; exit 0; fi
    if cmp -s <(head -n 1 "$tmp") "$PK"; then echo "认的钥匙 ${old} = 入口现在用的"; exit 0; fi
    # Certificates carry their own signatures. Ask the fetcher's trust reader
    # whether it would re-pin to this exact root; never save trust from status.
    code=$(fleet_rel_http "$hub/v1/fleet/release/stable" "$tmp.manifest" "$TMO")
    if [ "$code" != 200 ]; then
      echo "认的钥匙 ${old}，入口现在用的 ${new}：无法读取 stable 清单（HTTP ${code}），暂时无法核对担保链"
      exit 1
    fi
    python3 -B - "$here" "$PK" "$tmp" "$tmp.manifest" 2>/dev/null <<'PY'
import importlib.util, json, sys
try:
    spec = importlib.util.spec_from_file_location("verify", sys.argv[1] + "/fleet-release-verify.py")
    v = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(v)
    anchor, root = v._pubkey(sys.argv[2]), v._pubkey(sys.argv[3])
    with open(sys.argv[4]) as f:
        m = json.load(f)
    revs = [m["revoked"]] if isinstance(m.get("revoked"), dict) else []
    t = v.trust(anchor, m.get("key_chain") or [], revs, v.load_revoked(sys.argv[2] + ".revoked")[0])
    sys.exit(0 if t[3] == root else 1)
except (OSError, ValueError, TypeError, AttributeError, KeyError):
    sys.exit(2)
PY
    trust_rc=$?
    if [ "$trust_rc" = 0 ]; then
      echo "认的钥匙 ${old}：担保链认可 · 下次取版本自动重钉到根 ${new}"
      exit 0
    fi
    if [ "$trust_rc" != 1 ]; then
      echo "认的钥匙 ${old}，入口现在用的 ${new}：无法核对 stable 清单的担保链"
      exit 1
    fi
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
