#!/bin/bash
# fleet-hub-url.sh — this computer's hub address, read ONE way (issue #2024).
#
#   fleet-hub-url.sh          print it (no trailing /), exit 0 · exit 1 = none anywhere
#   . fleet-hub-url.sh --lib  define fleet_hub_url() in the caller instead
#
# Where it looks, first answer wins — every place a node OR a client-only
# computer keeps it:
#   1. the environment: FLEET_HUB_URL, CCQUOTA_HUB_URL
#   2. fleet.conf ($FLEET_CONF_DIR, else $XDG_CONFIG_HOME/claude-fleet, else
#      ~/.config/claude-fleet), SOURCED in a subshell — [common], then [client]
#      (FLEET_SHELL=1), then [node]: a sed for one `export FLEET_HUB_URL=` line
#      at column 0 misses a client's guarded sections, and was how
#      `fleet drill invite` said "no hub" on a MacBook that had one (#2024)
#   3. the files #1623 folded into fleet.conf, still read for one version:
#      shell.conf, the install's fleet.conf beside bin/, node.env's
#      CCQUOTA_HUB_URL (grepped — never sourced: it holds the node token),
#      hub.json's "url"
# Only an http:// or https:// answer counts.
_fleet_hub_url_ok() { case "$1" in http://*|https://*) printf '%s\n' "${1%/}"; return 0 ;; esac; return 1; }

# _fleet_hub_url_src <file> [FLEET_SHELL] — the hub its sourcing sets, in a subshell
_fleet_hub_url_src() {
  [ -f "$1" ] || return 1
  ( set +eu; unset FLEET_HUB_URL CCQUOTA_HUB_URL
    # shellcheck disable=SC2034  # FLEET_SHELL picks the conf's [client] / [node] section
    if [ -n "${2-}" ]; then FLEET_SHELL=$2; else unset FLEET_SHELL; fi
    . "$1" >/dev/null 2>&1 </dev/null
    printf '%s' "${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}" )
}

fleet_hub_url() {
  local u d f bin
  _fleet_hub_url_ok "${FLEET_HUB_URL:-}" && return 0
  _fleet_hub_url_ok "${CCQUOTA_HUB_URL:-}" && return 0
  for d in "${FLEET_CONF_DIR:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet" "$HOME/.config/claude-fleet"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for f in 1 0 ''; do
      u=$(_fleet_hub_url_src "$d/fleet.conf" "$f") && _fleet_hub_url_ok "$u" && return 0
    done
    u=$(_fleet_hub_url_src "$d/shell.conf" 1) && _fleet_hub_url_ok "$u" && return 0
  done
  bin=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
  if [ -n "$bin" ]; then
    u=$(_fleet_hub_url_src "$bin/../fleet.conf" 0) && _fleet_hub_url_ok "$u" && return 0
  fi
  for d in "${FLEET_CONF_DIR:-}" "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet" "$HOME/.config/claude-fleet"; do
    [ -n "$d" ] || continue
    if [ -f "$d/node.env" ]; then
      u=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}CCQUOTA_HUB_URL=["'\'']\{0,1\}\([^"'\'' ]*\).*/\2/p' "$d/node.env" | tail -n 1)
      _fleet_hub_url_ok "$u" && return 0
    fi
    if [ -f "$d/hub.json" ]; then
      u=$(python3 -c 'import json, sys
try: print(str(json.load(open(sys.argv[1])).get("url") or "").strip())
except Exception: pass' "$d/hub.json" 2>/dev/null)
      _fleet_hub_url_ok "$u" && return 0
    fi
  done
  return 1
}

if [ "${1-}" != --lib ]; then
  fleet_hub_url
fi
