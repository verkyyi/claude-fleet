#!/bin/bash
# fleet-list.sh — list fleets: configured (a per-fleet conf) and/or live (a tmux
# session). Columns: ● live/○ down · name · repo · checkout.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

printf '%-2s %-22s %-40s %s\n' '' 'FLEET' 'REPO' 'CHECKOUT'
seen=' '

emit() {  # $1=name $2=repo $3=main
  local live='○'
  tmux has-session -t "$1" 2>/dev/null && live='●'
  printf '%-2s %-22s %-40s %s\n' "$live" "$1" "${2:-·}" "${3:-·}"
  seen="$seen$1 "
}

# configured fleets (one conf each — new fleets/<sess>/conf or a legacy flat one)
while IFS=$'\t' read -r name cf; do
  [ -n "$name" ] || continue
  IFS=$'\t' read -r r m < <( . "$cf" >/dev/null 2>&1; printf '%s\t%s' "${FLEET_REPO:-}" "${FLEET_MAIN:-}" )
  emit "$name" "$r" "$m"
done < <(fleet_each_conf)

# live sessions the collector resolved to a repo but that have no conf
# (derived-only fleets — e.g. the global default, or a hand-opened session)
SESSMAP=$(fleet_sessmap_file)
if [ -f "$SESSMAP" ]; then
  while IFS=$'\t' read -r s _sl r; do
    [ -z "$s" ] && continue
    case "$seen" in *" $s "*) continue;; esac
    emit "$s" "$r" ''
  done < "$SESSMAP"
fi
