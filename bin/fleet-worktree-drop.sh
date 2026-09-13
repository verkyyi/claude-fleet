#!/bin/bash
# fleet-worktree-drop.sh <main-checkout> <worktree-dir> [--force] — CLI shim over
# fleet_worktree_drop (bin/fleet-lib.sh, issue #586): retire a worktree by RENAMING
# it into a sibling `.fleet-trash/` (O(1)) and pruning git's admin entry, instead of
# paying for a synchronous, file-by-file `git worktree remove`.
#
# It exists because the DETACHED teardown in bin/fleet-cleanup.sh hands its whole
# teardown as a command STRING to `tmux run-shell`, which runs it under /bin/sh —
# where sourcing this bash library is not an option. Every other caller sources
# fleet-lib.sh and calls the function directly.
#
# Prints one token (trashed:<path> · removed:<dir> · gone · dirty · error:<reason>);
# rc 0 ⇔ the worktree is gone from `git worktree list`, 1 = dirty (needs --force),
# 2 = error. Without --force a worktree holding uncommitted or untracked work is
# REFUSED, exactly as `git worktree remove` (no -f) refuses it.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

fleet_worktree_drop "$@"
