#!/usr/bin/env bash
# fleet-web-open.sh fid:<fleet_id> | wid:<worker id> — 「在网页里打开」(task PQ41,
# 会话合一): ⌘P's actions page opens the row's session in the console on the
# person's own screen — /app/s/<ref>, the page that talks to it (or reads it).
# Nothing moves: the session stays where it runs, its terminal keeps it, there
# is no lock (the old 「在 WebChat 里继续」 handed it over — fleet-webchat-handoff.sh
# to-web, read one more version by the end page). The hub's address is the
# node's (CCQUOTA_HUB_URL / FLEET_HUB_URL / node.env); the page goes through
# fleet-open.sh, never `open` here.
#
# rc 0 opened · 2 no address / no hub · else fleet-open.sh's.
set -u
BIN=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fleet-client-core.sh
. "$BIN/fleet-client-core.sh"
# shellcheck source=fleet-ui-lang.sh
. "$BIN/fleet-ui-lang.sh"

addr=${1:-}
case "$addr" in
  fid:?*) ref=${addr#fid:} ;;
  wid:?*) ref=${addr#wid:} ;;
  *) printf 'usage: fleet-web-open.sh fid:<fleet_id> | wid:<worker id>\n' >&2; exit 2 ;;
esac
case "$ref" in *[!A-Za-z0-9._:/-]*) printf 'fleet-web-open.sh: not a session id: %s\n' "$ref" >&2; exit 2 ;; esac
url=${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)}}
if [ -z "$url" ]; then
  printf '%s\n' "$(fleet_ui_t view_webopen_why_nohub)" >&2
  exit 2
fi
# a worker id's "/" is part of the ref, never a path step
ref=$(printf '%s' "$ref" | sed 's|/|%2F|g')
exec bash "$BIN/fleet-open.sh" "${url%/}/app/s/$ref"
