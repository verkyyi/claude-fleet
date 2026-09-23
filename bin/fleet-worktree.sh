#!/bin/bash
# fleet-worktree.sh — CLI shim over the ONE worktree-path exit in bin/fleet-lib.sh
# (issue #886), for callers that cannot source the bash library — `cw`/`cwrm` in
# shell/cw.zsh run in the operator's zsh.
#
#   fleet-worktree.sh dir    <main> <slug>                    print the worktree path
#   fleet-worktree.sh create <main> <slug> [<base>] [--reuse] create it, print the path
#
# FLEET_WORKTREE_ROOT is read from the conf of the fleet whose FLEET_MAIN is <main>
# (over the global fleet.conf), so a manual `cw` in a fleet's checkout lands where
# that fleet's spawns do. A checkout no fleet owns gets the global value; an env
# FLEET_WORKTREE_ROOT set by the caller wins over both. See fleet_worktree_create
# for <base> / --reuse.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

case "${1:-}" in
  -h|--help|'') sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; [ -n "${1:-}" ]; exit $? ;;
esac
cmd="$1"; shift
main="${1:-}"
[ -n "$main" ] || { echo "fleet-worktree.sh: need <main>" >&2; exit 2; }

if [ -z "${FLEET_WORKTREE_ROOT+x}" ]; then
  # shellcheck source=/dev/null
  [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
  rmain=$(cd "$main" 2>/dev/null && pwd -P) || rmain="$main"
  while IFS=$'\t' read -r s cf; do
    [ -f "$cf" ] || continue
    fm=$( . "$cf" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
    [ -n "$fm" ] || continue
    fm=$(cd "$fm" 2>/dev/null && pwd -P) || continue
    if [ "$fm" = "$rmain" ]; then fleet_load_conf "$s"; break; fi
  done < <(fleet_each_conf)
fi

case "$cmd" in
  dir)    fleet_worktree_dir "$@" ;;
  create) fleet_worktree_create "$@" ;;
  *)      echo "fleet-worktree.sh: unknown command '$cmd' (dir|create)" >&2; exit 2 ;;
esac
