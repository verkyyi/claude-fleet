#!/bin/bash
# Fresh quota gate for an operator-selected Claude subscription. Automatic
# selection keeps its own, lower FLEET_ACCOUNT_CEILING.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
mode="${1:-}"; sess="${2:-}"; label="${3:-}"
[ -z "$sess" ] || fleet_load_conf "$sess" 2>/dev/null || :
account="${FLEET_MANUAL_ACCOUNT_BIN:-$BIN/fleet-account.sh}"
accounts="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}"
case "$mode" in list|check) ;; *) echo 'usage: fleet-manual-sub.sh list|check <session> [label]' >&2; exit 2 ;; esac
if [ "$mode" = check ]; then
  case "$label" in ''|*[!A-Za-z0-9._@-]*) echo 'manual sub: invalid account label' >&2; exit 2 ;; esac
  [ -s "$accounts/$label" ] || { echo "manual sub: $label has no token" >&2; exit 1; }
fi
# A forced fetch must have produced a new reading. quota --refresh otherwise
# returns cached rows when ccquota is absent, which cannot authorize a move.
started=$(date +%s)
cache="${FLEET_C}/global/account.quota.ts"
old_inode=$(ls -di "$cache" 2>/dev/null | awk '{print $1}')
rows=$(bash "$account" quota --refresh 2>/dev/null)
stamp=$(cat "$cache" 2>/dev/null || echo 0)
new_inode=$(ls -di "$cache" 2>/dev/null | awk '{print $1}')
case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
if [ "$stamp" -lt "$started" ] || [ -z "$rows" ] || [ -z "$new_inode" ] || [ "$old_inode" = "$new_inode" ]; then
  echo 'manual sub: fresh quota unavailable; no move authorized' >&2
  exit 1
fi
valid_pct() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -le 100 ]; }
classify() {
  local l="$1" five="$2" week="$3"
  [ -s "$accounts/$l" ] || { printf 'no-token'; return; }
  valid_pct "$five" && valid_pct "$week" || { printf 'unknown'; return; }
  if [ "$five" -ge 95 ] || [ "$week" -ge 95 ]; then printf 'blocked'
  elif [ "$five" -ge 85 ] || [ "$week" -ge 85 ]; then printf 'manual'
  else printf 'available'; fi
}
status_label() {
  if [ "${FLEET_UI_LANG:-}" = zh ]; then
    case "$1" in available) echo '可迁入' ;; manual) echo '需手动确认（超过自动 85% 保护线）' ;; blocked) echo '已达 95%，不可迁入' ;; unknown) echo '额度未知' ;; *) echo '无 token' ;; esac
  else
    case "$1" in available) echo 'available' ;; manual) echo 'manual confirmation (above 85% auto limit)' ;; blocked) echo 'at 95% limit' ;; unknown) echo 'quota unknown' ;; *) echo 'no token' ;; esac
  fi
}
if [ "$mode" = list ]; then
  if [ "${FLEET_UI_LANG:-}" = zh ]; then printf '账号\t5h\t7d\t状态\n'; else printf 'Account\t5h\t7d\tStatus\n'; fi
  for f in "$accounts"/*; do
    [ -f "$f" ] || continue
    l=${f##*/}; case "$l" in .*|*~|*.conf) continue ;; esac
    line=$(printf '%s\n' "$rows" | awk -F '\t' -v l="$l" '$1==l{print; exit}')
    five=$(printf '%s' "$line" | cut -f2); week=$(printf '%s' "$line" | cut -f3)
    printf '%s\t%s\t%s\t%s\n' "$l" "${five:+$five%}" "${week:+$week%}" "$(status_label "$(classify "$l" "$five" "$week")")"
  done
  exit 0
fi
found=0
while IFS=$'\t' read -r l five week _; do
  [ "$l" = "$label" ] || continue
  found=1
  status=$(classify "$l" "$five" "$week")
  printf 'manual sub: %s  5h %s%% · 7d %s%% — %s\n' "$l" "$five" "$week" "$(status_label "$status")"
  case "$status" in available|manual) exit 0 ;; *) exit 1 ;; esac
done <<< "$rows"
[ "$found" = 1 ] || echo "manual sub: $label has no fresh quota reading" >&2
exit 1
