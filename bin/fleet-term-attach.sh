#!/bin/bash
# fleet-term-attach.sh --view web-<id> --target personal|worker:<fleet_id>
#
# Fixed entry from ccquota term-pty, AFTER the hub grant and run-as checks.
# The lifecycle helper resolves the authorized target, claims control BEFORE
# attach, and disposes only this connection. Personal shell/workers survive.
# Exit 2 usage · 3 no fleet · 4 missing worker/occupied controller · 5 ended/view taken.
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"

say() { printf '%s\r\n' "$*"; }
view='' target=''
while [ $# -gt 0 ]; do
  case "$1" in
    --view) view="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    *) say "fleet-term-attach: unknown argument $1"; exit 2 ;;
  esac
done
case "$view" in web-*) ;; *) say "fleet-term-attach: --view is web-<id>"; exit 2 ;; esac
case "${view#web-}" in ''|*[!A-Za-z0-9-]*) say "fleet-term-attach: bad --view"; exit 2 ;; esac
case "$target" in
  personal) ;;
  worker:*) case "${target#worker:}" in ''|*[!A-Za-z0-9-]*) say "fleet-term-attach: bad --target"; exit 2 ;; esac ;;
  *) say "fleet-term-attach: --target is personal or worker:<fleet id>"; exit 2 ;;
esac

# term-pty sets it; a terminal with none (or dumb) cannot attach at all
case "${TERM:-}" in ''|dumb) export TERM=xterm-256color ;; esac

# Keep C1's fixed, validated entry point for old node binaries. C4 owns the
# lifecycle, control lease and native client; never make an ordinary view first.
exec python3 "$BIN/fleet-webterm.py" connect --conn "$view" --target "$target"
