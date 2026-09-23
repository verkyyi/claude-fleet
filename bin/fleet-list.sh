#!/bin/bash
# fleet-list.sh — list fleets: configured (a per-fleet conf) and/or live (a tmux
# session). Columns: ● live/○ down · name · repo · checkout. A fleet hosting 2+
# repos (issue #788) lists each further repo under its row as `↳ owner/name
# checkout` (issue #980: the fleet and its repos — one fleet per login holds them
# all); a one-repo fleet prints its single row exactly as before.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

printf '%-2s %-22s %-40s %s\n' '' 'FLEET' 'REPO' 'CHECKOUT'
seen=' '

emit() {  # $1=name $2=repo $3=main
  local live='○'
  # Each fleet runs on its own named socket (== session name, issue #159), so the
  # liveness probe must name that socket — a bare has-session hits only the default.
  tmux -L "$(fleet_socket "$1")" has-session -t "$1" 2>/dev/null && live='●'
  printf '%-2s %-22s %-40s %s\n' "$live" "$1" "${2:-·}" "${3:-·}"
  seen="$seen$1 "
}

# configured fleets (one conf each — new fleets/<sess>/conf or a legacy flat one)
while IFS=$'\t' read -r name cf; do
  [ -n "$name" ] || continue
  IFS=$'\t' read -r r m < <( . "$cf" >/dev/null 2>&1; printf '%s\t%s' "${FLEET_REPO:-}" "${FLEET_MAIN:-}" )
  emit "$name" "$r" "$m"
  # further hosted repos (the fleet conf's FLEET_REPO is the row above)
  while IFS= read -r hr; do
    [ -n "$hr" ] && [ "$hr" != "$(fleet_norm_repo "$r")" ] || continue
    hm=$( unset FLEET_MAIN; . "$(fleet_repo_conf_file "$name" "$hr")" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
    printf '%-2s %-22s %-40s %s\n' '' '  ↳' "$hr" "${hm:-·}"
  done < <(fleet_repos "$name")
done < <(fleet_each_conf)

# live sessions the collector resolved to a repo but that have no conf
# (derived-only fleets — e.g. the global default, or a hand-opened session)
SESSMAP=$(fleet_sessmap_file)
if [ -f "$SESSMAP" ]; then
  while IFS=$'\t' read -r s _sl r; do
    [ -z "$s" ] && continue
    # the collector rows every session on a fleet's socket — its warm-pool holding
    # session included, which is not a fleet (issue #1020)
    fleet_is_pool_session "$s" && continue
    case "$seen" in *" $s "*) continue;; esac
    emit "$s" "$r" ''
  done < "$SESSMAP"
fi
