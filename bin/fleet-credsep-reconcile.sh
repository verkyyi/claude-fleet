#!/usr/bin/env bash
# fleet-credsep-reconcile.sh — a separated login's node.env back where it
# belongs (issue #2649). Root, once:
#
#   sudo bash fleet-credsep-reconcile.sh --login <login> [--prefer home|store] [--dry-run]
#
# A writer from before #2316 (`fleet host on`, `fleet node compute`) replaced
# the login's ~/.config/claude-fleet/node.env — a link into the credential store
# — with a plain file: the node token readable in the home again, and the
# store's copy left older. This folds the home copy into the store (the NEWER
# copy's value wins a key both have, --prefer overrides; a key only one has is
# kept), sets the plain file aside in the store's backup/, puts the link back,
# rewrites node.pub.env and restarts the agent through the launcher. On a
# managed machine an adopted login's /var/db/fleet-node/logins/<login>.env takes
# the same CCQUOTA_ lines (the node daemon reloads it); a login not adopted
# there is only named. No value is ever printed. Rerunning is a no-op.
#
# The work is fleet-credsep.py's `reconcile`; this is fleet-credsep.sh's
# `reconcile` verb under the name the doctor's credsep row prints.
# Exit 0 reconciled / nothing to do · 1 refused · 2 usage · 3 not separated ·
# 4 no root.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ $# -gt 0 ] || { echo "usage: sudo bash $0 --login <login> [--prefer home|store] [--dry-run]" >&2; exit 2; }
exec bash "$BIN/fleet-credsep.sh" reconcile "$@"
