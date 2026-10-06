#!/bin/bash
# fleet-update.sh — ONE update path: every computer follows stable
# (claude-fleet#1805, EPIC #1813 C3). `fleet update` on any computer.
#
#   fleet update [status]   one line: what this computer is, the version it runs,
#                           the stable it follows and where it stands
#   fleet update stable     the commit refs/tags/stable names, as this computer
#                           sees it: the hub's /version (`stable`) when it has a
#                           hub that says, else GitHub's API — 40 hex, rc 1 when
#                           neither answers
#   fleet update tick [--root <dir>] [args…]   one beat of this computer's layer
#
# There is one version — stable's commit — and one place it moves: the operator
# moves refs/tags/stable (bin/fleet-stable.sh). Two layers take it, each at its
# own pace, and nothing else is ever redeployed for either to follow:
#
#   基础 (the part everyone has — an install-line client, ~/.claude/fleet with
#        a .client-version): fleet-client-update.sh. The hub only REPORTS
#        stable (its /version, and stable's files through it, reachable where
#        GitHub is not); with no hub it asks GitHub. Staged in the background, switched in place
#        once nobody is typing (the previous batch's 「空闲时原地换」).
#   承载 (a full install — a checkout of stable): fleet-install-sync.sh, the
#        install-sync daemon's tick. Deferred while a session is busy and while
#        an EPIC batch's heartbeat is fresh; rolled back on a new doctor FAIL.
#
# `tick` is the dispatch: a full install → fleet-install-sync.sh with the rest
# of the arguments (the daemon's beat; --dry-run / --status pass through); an
# installed client → fleet-client-update.sh tick (the client keeper's beat);
# neither (a copy nobody installed) → nothing, exit 0.
#
# Exit: status 0 · stable 0 / 1 · tick: the layer's own exit code.
# Env: FLEET_UPDATE_ROOT (the install; default this script's ../) ·
# FLEET_STABLE_API / FLEET_STABLE_RAW (GitHub's, the selftests' seam) ·
# FLEET_CLIENT_TIMEOUT (seconds per request, 3).
set -uo pipefail

SELF="$0"; [ -L "$SELF" ] && SELF=$(readlink "$SELF")
BIN="$(cd "$(dirname "$SELF")" && pwd -P)"
ROOT="${FLEET_UPDATE_ROOT:-$(cd "$BIN/.." && pwd -P)}"
case "$ROOT" in *.versions/*) [ -n "${FLEET_UPDATE_ROOT:-}" ] || ROOT=${ROOT%.versions/*} ;; esac
CONF_DIR="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
API="${FLEET_STABLE_API:-https://api.github.com/repos/verkyyi/claude-fleet/commits/stable}"
TMO="${FLEET_CLIENT_TIMEOUT:-3}"
case "$TMO" in ''|*[!0-9]*) TMO=3 ;; esac

# layer <root> — full | client | none
layer() {
  if [ -d "$1/.git" ] || [ -f "$1/bin/fleet-up.sh" ]; then echo full
  elif [ -f "$1/.client-version" ]; then echo client
  else echo none; fi
}
mark_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
is_sha() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" -eq 40 ]; }

# hub_url — fleet.conf's FLEET_HUB_URL (the machine's one config file), or
# CCQUOTA_HUB_URL; empty = no hub
hub_url() {
  local u="${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}"
  if [ -z "$u" ] && [ -f "$CONF_DIR/fleet.conf" ]; then
    # shellcheck disable=SC2034  # FLEET_SHELL=1 picks fleet.conf's [client] section
    u=$(FLEET_SHELL=1; . "$CONF_DIR/fleet.conf" >/dev/null 2>&1; printf '%s' "${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}")
  fi
  printf '%s' "${u%/}"
}

# stable_sha — what stable names: the hub's word first, GitHub's after
stable_sha() {
  local hub s=''
  hub=$(hub_url)
  if [ -n "$hub" ]; then
    s=$(curl -fsS --max-time "$TMO" "$hub/version" 2>/dev/null | python3 -c 'import json, sys
try:
    print(json.load(sys.stdin).get("stable") or "")
except Exception:
    pass' 2>/dev/null)
  fi
  if ! is_sha "$s"; then
    s=$(curl -fsS --max-time "$TMO" -H 'Accept: application/vnd.github.sha' "$API" 2>/dev/null | tr -d ' \r\n' | cut -c1-40)
  fi
  is_sha "$s" || return 1
  printf '%s\n' "$s"
}

cmd_status() {
  local l v st res
  l=$(layer "$ROOT")
  case "$l" in
    full)
      v=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
      st=$(sed -n 's/^stable: //p' "$CONF_DIR/global/install-sync.state" 2>/dev/null | head -n 1)
      res=$(sed -n 's/^result: //p' "$CONF_DIR/global/install-sync.state" 2>/dev/null | head -n 1)
      is_sha "$st" || st=$(stable_sha) || st=''
      printf '承载 · 版本 %.7s · ' "${v:-?}"
      if [ -z "$st" ]; then printf 'stable 问不到'
      elif [ "$st" = "$v" ]; then printf '跟 stable 同版'
      else printf 'stable %.7s（上次：%s）' "$st" "${res:-还没跑过}"; fi
      printf ' · 由 install-sync 每 30 分钟跟上（忙时、EPIC 跑批时推迟）\n' ;;
    client)
      v=$(mark_get "$ROOT/.client-version" version)
      st=$(stable_sha) || st=''
      printf '基础 · 版本 %s · ' "$(is_sha "$v" && printf '%.7s' "$v" || printf '%s' "${v:-?}")"
      if [ -z "$st" ]; then printf 'stable 问不到'
      elif [ "$st" = "$v" ]; then printf '跟 stable 同版'
      else printf 'stable %.7s 待换上' "$st"; fi
      if [ -n "$(hub_url)" ]; then printf ' · 经入口取'; else printf ' · 从 GitHub 取'; fi
      printf ' · 空闲时原地换上\n' ;;
    *)
      printf '这里没有装 fleet（%s）\n' "$ROOT" ;;
  esac
}

cmd_tick() {
  local r="$ROOT" a prev=''
  for a in "$@"; do [ "$prev" = --root ] && r=$a; prev=$a; done
  case "$(layer "$r")" in
    full)   exec bash "$BIN/fleet-install-sync.sh" "$@" ;;
    client) FLEET_CLIENT_ROOT="$r" exec bash "$BIN/fleet-client-update.sh" tick "${FLEET_SHELL_SESSION:-fleet-shell}" ;;
  esac
  return 0
}

case "${1:-status}" in
  status) cmd_status ;;
  stable) stable_sha; exit $? ;;
  tick)   shift; cmd_tick "$@"; exit $? ;;
  -h|--help|help) sed -n '2,32p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *) printf 'fleet update: 不认识 %s（status · stable · tick）\n' "$1" >&2; exit 2 ;;
esac
