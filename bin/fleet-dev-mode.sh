#!/bin/bash
# fleet-dev-mode.sh — `fleet host dev on <checkout> | off | status` (issue #2779,
# EPIC #2770 R3): a developer's own checkout used as this login's install.
#
# With the hub the one source of new versions (EPIC #2770), a person changing
# fleet itself had no proper way to try a change no stable carries yet. This is
# that way, the old practice made explicit:
#
#   fleet host dev on <checkout>
#       ~/.claude/fleet → <checkout> (one rename of the link; a plain-directory
#       install is adopted into ~/.claude/fleet.versions/ first, as install-sync
#       does) and $FLEET_CONF_DIR/global/dist-mode records it (mode · checkout ·
#       prev · since). While it is there install-sync answers `off · dev` and
#       never switches the link, so no new stable from the hub overwrites the
#       checkout; the doctor's `dist` row says `dev <checkout>` (INFO, never a
#       WARN). The daemons and hooks run ~/.claude/fleet/bin/… — the checkout's
#       code from their next call. On a MANAGED login (accounts.json) root has to
#       consent first — `sudo …/fleet-node-supervisor.py account dev <login> on`
#       — or the machine updater would put the link back on its next tick; with
#       no consent this refuses (exit 1) and names the command.
#   fleet host dev off
#       The link goes back to what it pointed at before (`prev`; gone ⇒ the
#       version that holds the repository), the record goes, and the next
#       install-sync tick follows the hub again (`switched` when stable moved).
#   fleet host dev status
#       One line: 开发模式 已开 · dev <checkout> … or 未开 · ~/.claude/fleet → ….
#
# The record is ONE file, read by install-sync, fleet-dist-source.sh,
# fleet-install-follow.sh and fleet-installs.sh (`mode: dev` / `checkout: …`).
# Nothing here applies the checkout (hooks, launchd templates, settings): the
# paths already lead into it; a change to those steps is replayed by hand.
#
# Exit: 0 done / status · 1 refused or a step failed · 2 usage.
# Env: FLEET_CONF_DIR · FLEET_LIVE_DIR (~/.claude/fleet) · FLEET_NODE_STATE
# (/var/db/fleet-node) · FLEET_NODE_ROOT (the runtime root).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=/dev/null
. "$here/fleet-versions-lib.sh"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
LIVE="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"; LIVE=${LIVE%/}
REC="$CONF/global/dist-mode"
NSTATE="${FLEET_NODE_STATE:-/var/db/fleet-node}"
NROOT="${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}"
LOGIN=$(id -un 2>/dev/null || printf '%s' "${USER:-?}")

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
rec_get() { [ -f "$REC" ] && sed -n "s/^$1: //p" "$REC" | head -n 1; }
is_dev() { [ "$(rec_get mode)" = dev ]; }
iso_of() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$1"; }

# acct <field> — this login's accounts.json entry: exit 0 when <field> is set
acct() {
  [ -r "$NSTATE/accounts.json" ] || return 1
  python3 -c 'import json, sys
try:
    a = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
e = a.get(sys.argv[2]) if isinstance(a, dict) else None
sys.exit(0 if isinstance(e, dict) and e.get(sys.argv[3]) else 1)' "$NSTATE/accounts.json" "$LOGIN" "$1" 2>/dev/null
}
# managed — the machine updater moves this login's install (#2334, #4669)
managed() { acct managed || [ "$(readlink "$LIVE" 2>/dev/null)" = "$NROOT/current" ]; }

write_rec() { # <checkout> <prev>
  local tmp
  mkdir -p "$CONF/global" || return 1
  tmp="$REC.tmp.$$"
  printf 'mode: dev\ncheckout: %s\nprev: %s\nsince: %s\n' "$1" "${2:--}" "$(date +%s)" > "$tmp" && mv -f "$tmp" "$REC"
}

cmd_on() {
  local co="${1:-}" prev key nr lv
  [ -n "$co" ] || { echo "fleet host dev on <checkout> — 要当安装用的代码目录" >&2; return 2; }
  co=$(cd "$co" 2>/dev/null && pwd -P) || { echo "✗ 没有这个目录：$1" >&2; return 1; }
  [ -f "$co/bin/fleet-install-sync.sh" ] && [ -f "$co/bin/fleet-lib.sh" ] \
    || { echo "✗ $co 不是 claude-fleet 的代码目录（没有 bin/fleet-lib.sh）" >&2; return 1; }
  nr=$(cd "$NROOT" 2>/dev/null && pwd -P) || nr=''
  lv=$(cd "$LIVE.versions" 2>/dev/null && pwd -P) || lv=''
  case "$co/" in "${lv:-/nonexistent}/"*|"${nr:-/nonexistent}/"*)
    echo "✗ $co 是一个发布版本，不是你的代码目录" >&2; return 1 ;; esac
  if is_dev && [ "$(rec_get checkout)" = "$co" ] && [ "$(cd "$LIVE" 2>/dev/null && pwd -P)" = "$co" ]; then
    echo "开发模式 已开 — ~/.claude/fleet 已经指向 $co"; return 0
  fi
  if managed && ! acct dev; then
    echo "✗ 这是托管登录：机器更新器会在下一拍把 ~/.claude/fleet 指回 $NROOT/current。" >&2
    echo "  先请管理员同意：sudo \"$NROOT/current/bin/fleet-node-supervisor.py\" account dev $LOGIN on，再重跑这条" >&2
    return 1
  fi
  if is_dev; then
    prev=$(rec_get prev)      # switching checkouts: the way back stays the same
  else
    if [ -d "$LIVE" ] && [ ! -L "$LIVE" ]; then
      key=$(git -C "$LIVE" rev-parse HEAD 2>/dev/null) || key="own-$(date +%s)"
      fleet_versions_adopt "$LIVE" "$key" || { echo "✗ 没能把 $LIVE 收进 $LIVE.versions/（$key 已在？）" >&2; return 1; }
    fi
    prev=$(readlink "$LIVE" 2>/dev/null || :)
  fi
  write_rec "$co" "$prev" || { echo "✗ 写不了 $REC" >&2; return 1; }
  mkdir -p "$(dirname "$LIVE")"
  if ! fleet_versions_point "$LIVE" "$co"; then
    is_dev || rm -f "$REC"
    echo "✗ 没能把 $LIVE 指向 $co" >&2; return 1
  fi
  echo "✓ 开发模式 已开：~/.claude/fleet → $co"
  echo "  入口的新版不覆盖它（install-sync 答 off · dev）；后台程序和 hook 下一次调用就跑这里的代码"
  echo "  改了 hook 表 / 守护模板 / 设置这类装机步骤：照旧手动重放一次（/fleet-sync-install）"
  echo "  退出：fleet host dev off"
}

cmd_off() {
  local prev to v
  is_dev || { echo "开发模式 本来就没开"; return 0; }
  prev=$(rec_get prev)
  if [ -e "$LIVE" ] && [ ! -L "$LIVE" ]; then
    echo "✗ $LIVE 不再是链接（被换成了目录）— 手动收拾后再关" >&2; return 1
  fi
  to=''
  if [ -n "$prev" ] && [ "$prev" != - ] && [ -d "$prev" ]; then
    to=$prev
  else
    # gone (pruned, moved): the version that holds the repository, else .prev's
    for v in "$LIVE.versions"/*/; do
      [ -d "$v.git" ] && { to=${v%/}; break; }
    done
    if [ -z "$to" ] && [ -s "$LIVE.versions/.prev" ]; then
      v="$LIVE.versions/$(head -n 1 "$LIVE.versions/.prev")"; [ -d "$v" ] && to=$v
    fi
  fi
  [ -n "$to" ] || { echo "✗ 找不到开发模式之前的那一版（${prev:--} 不在了）— ~/.claude/fleet 没动" >&2; return 1; }
  fleet_versions_point "$LIVE" "$to" || { echo "✗ 没能把 $LIVE 指回 $to" >&2; return 1; }
  rm -f "$REC"
  echo "✓ 开发模式 已关：~/.claude/fleet → $to"
  if managed; then
    echo "  机器更新器照常跟它；不再需要时请管理员收回同意：sudo \"$NROOT/current/bin/fleet-node-supervisor.py\" account dev $LOGIN off"
  else
    echo "  下一拍（≤ 30 分钟）回到入口那一版；现在就跟：bash ~/.claude/fleet/bin/fleet-install-sync.sh"
  fi
}

cmd_status() {
  local s
  if is_dev; then
    s=$(rec_get since)
    printf '开发模式 已开 · dev %s（自 %s）· 入口的新版不覆盖它 · 关掉后回到 %s\n' \
      "$(rec_get checkout)" "$(iso_of "${s:-0}")" "$(rec_get prev)"
    [ "$(cd "$LIVE" 2>/dev/null && pwd -P)" = "$(rec_get checkout)" ] \
      || echo "! ~/.claude/fleet 现在指向 $(readlink "$LIVE" 2>/dev/null || echo '?')，不是记录里的代码目录 — 重跑 fleet host dev on $(rec_get checkout)"
  else
    printf '开发模式 未开 · ~/.claude/fleet → %s\n' "$(readlink "$LIVE" 2>/dev/null || echo "$LIVE")"
  fi
  return 0
}

verb="${1:-status}"; [ $# -gt 0 ] && shift
case "$verb" in
  on) cmd_on "$@" ;;
  off) cmd_off ;;
  status) cmd_status ;;
  -h|--help|help) usage ;;
  *) echo "fleet host dev: on <checkout> | off | status" >&2; exit 2 ;;
esac
