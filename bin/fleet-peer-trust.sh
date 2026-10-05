#!/bin/bash
# fleet-peer-trust.sh — the standing machine-to-machine trust this login still keeps
# (issue #1626, EPIC #1615 C9): the lines of ~/.ssh/authorized_keys whose key
# comment names ANOTHER fleet machine (`verkyyi@macmini`, `verkyyi@m4`).
#
#   fleet-peer-trust.sh [<authorized_keys>]
#
# Cross-machine ssh now rides a five-minute certificate the hub signs per
# connection (fleet-peer-cert.sh); a key another machine left here admits it
# forever, and the hub never hears of it. fleet-doctor's `trust` row reads this.
#
# Which names are fleet machines — whatever this login already knows, never a
# network call: FLEET_NODE_ALIASES (`macmini=m5`, both sides), FLEET_REMOTE_SSH
# (`m4=m4-lan`, both sides), the Host names of ~/.ssh/fleet-ssh-config, the hub's
# roster cache (global/hub_nodes), and FLEET_TRUST_MACHINES (extra names, space
# separated). This machine's own names are not "another machine".
#
# stdout: one line per entry, `<line number>	<key type>	<comment>` — never the key.
# Exit: 0 entries found · 1 none · 3 no fleet machine known here (a one-machine
# install: nothing to judge — the doctor prints no row).
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AK="${1:-$HOME/.ssh/authorized_keys}"
conf_dir="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

_val() {  # <KEY> → env value, else the last assignment in the config files
  local v="${!1:-}" f
  if [ -z "$v" ]; then
    for f in "$conf_dir/fleet.conf" "$conf_dir/fleet.settings" "$BIN/../fleet.conf"; do
      [ -f "$f" ] || continue
      v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}'"$1"'[[:space:]]*=[[:space:]]*\([^#]*\).*/\2/p' "$f" | tail -1 | tr -d "\"'")
      [ -n "$v" ] && break
    done
  fi
  printf '%s' "$v"
}

names=$(
  for p in $(_val FLEET_NODE_ALIASES) $(_val FLEET_REMOTE_SSH); do
    printf '%s\n%s\n' "${p%%=*}" "${p#*=}"
  done
  for n in $(_val FLEET_TRUST_MACHINES); do printf '%s\n' "$n"; done
  [ -f "$HOME/.ssh/fleet-ssh-config" ] && awk '$1 == "Host" { for (i = 2; i <= NF; i++) print $i }' "$HOME/.ssh/fleet-ssh-config"
  hn="${TMPDIR:-/tmp}/.claude-dash/global/hub_nodes"
  [ -f "$hn" ] && awk -F '\037' '$1 !~ /^#/ && $1 != "" { print $1 }' "$hn"
)
# This machine's own names: its hostname and what FLEET_NODE_ALIASES calls it.
me=$(hostname -s 2>/dev/null || hostname)
# shellcheck disable=SC2046  # the aliases are space-separated words, split on purpose
me_alias=$(printf '%s\n' $(_val FLEET_NODE_ALIASES) | awk -F= -v h="$me" 'tolower($1) == tolower(h) { print $2; exit }')

printf '%s\n' "$names" | awk 'NF' | grep -q . || exit 3

[ -r "$AK" ] || exit 1
awk -v names="$(printf '%s\n' "$names" | awk 'NF' | tr '\n' ' ')" -v me="$me" -v me_alias="$me_alias" '
  function first(s) { sub(/\..*/, "", s); return tolower(s) }
  BEGIN {
    n = split(names, a, " ")
    for (i = 1; i <= n; i++) { k = first(a[i]); sub(/^fleet-/, "", k); known[k] = 1 }
    self[first(me)] = 1; if (me_alias != "") self[first(me_alias)] = 1
  }
  /^[[:space:]]*(#|$)/ { next }
  {
    # the key type is the first field that looks like one (options may precede it)
    t = 0
    for (i = 1; i <= NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { t = i; break }
    if (!t || NF <= t + 1) next
    c = $(t + 2); for (i = t + 3; i <= NF; i++) c = c " " $i
    host = c; if (host !~ /@/) next
    sub(/^[^@]*@/, "", host); sub(/[[:space:]].*/, "", host); h = first(host)
    if ((h in known) && !(h in self)) { printf "%d\t%s\t%s\n", NR, $t, c; hit = 1 }
  }
  END { exit hit ? 0 : 1 }
' "$AK"
