#!/bin/bash
# fleet-onboard.sh — the onboarding wizard's memory + one-call brief (issue #1168,
# EPIC #1163 C5). The wizard itself is commands/fleet-onboard.md; this is the
# part of it that has to survive the conversation.
#
#   fleet-onboard.sh brief [--session <sess>] [--no-gh]   # everything step 0 needs
#   fleet-onboard.sh get   [<key>]                        # the saved progress
#   fleet-onboard.sh set   <key>=<value>…                 # record progress (merges)
#   fleet-onboard.sh reset                                # start over
#   fleet-onboard.sh path                                 # where it lives
#
# WHY A FILE. A newcomer does not finish in one sitting: they close the laptop
# while the worker runs, or the window is reaped, or they call the wizard back a
# day later (R1 #1171). The wizard must pick up at the step it left — never
# re-ask which repo, never re-file the issue it already filed. So progress lives
# on disk, not in the transcript: $FLEET_CONF_DIR/global/onboard.state. Global,
# not per-fleet, because a login has exactly ONE fleet (EPIC #977) and the
# newcomer is the login, not a session name.
#
# FORMAT. `key=value` lines, one per key, rewritten atomically (tmp + mv) with a
# fresh `updated=<epoch>`. Values are one line: a newline or CR in a value is
# folded to a space, so no value can forge a second key. Unknown keys are kept —
# a later wizard version may add some.
#
# STEPS, in order (`step=` holds the one the wizard is ON, i.e. not finished):
#   repo    pick / add the newcomer's own repo          → records repo=
#   issue   turn their first wish into an issue + spawn → records issue= window=
#   watch   read the session list while it works        → records pr= once one opens
#   merge   look at the PR together, they merge it
#   handoff how to do the next one alone
#   done    finished — calling the wizard back just offers the handoff again
# `set step=<x>` refuses anything else (exit 2), so a typo can't strand the resume.
#
# THE STARTER REPO. A newcomer's fleet is started on claude-fleet itself
# (`fleet-up.sh --seed`, C4 #1167), marked by FLEET_SEED=1 in the fleet conf and
# read ONLY through fleet_repo_is_seed — it marks the conf's OWN repo, never an
# overlay. `brief` tags it `[seed]` so the wizard can say plainly
# «this is the tool itself, not your repo» and never offer it as a place to work.
# Once another repo is hosted the tag also names the way out — `fleet-repo.sh
# remove <seed>` (issue #1172), which the wizard offers right after the add.
#
# Exit: 0 ok · 1 no such key (get) / write failed · 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

STEPS="repo issue watch merge handoff done"

usage() { sed -n '5,9p' "$0" | sed 's/^# //' >&2; exit 2; }

state_file() { printf '%s/global/onboard.state' "$FLEET_CONF_DIR"; }

# Print the saved state (nothing when there is none).
state_dump() {
  local f; f=$(state_file)
  [ -r "$f" ] && grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$f"
  return 0
}

state_get() {
  state_dump | awk -v k="$1" 'index($0, k"=")==1 { v=substr($0, length(k)+2); found=1 } END { if (found) print v; exit !found }'
}

valid_step() {
  case " $STEPS " in *" $1 "*) return 0 ;; esac
  return 1
}

# set k=v… — merge into the existing state, atomically.
state_set() {
  local f dir tmp kv k
  f=$(state_file); dir=${f%/*}
  [ $# -gt 0 ] || usage
  for kv in "$@"; do
    case "$kv" in
      [A-Za-z_]*=*) ;;
      *) echo "fleet-onboard: not key=value: $kv" >&2; exit 2 ;;
    esac
    k=${kv%%=*}
    case "$k" in *[!A-Za-z0-9_]*) echo "fleet-onboard: bad key: $k" >&2; exit 2 ;; esac
    if [ "$k" = step ] && ! valid_step "${kv#*=}"; then
      echo "fleet-onboard: unknown step '${kv#*=}' (one of: $STEPS)" >&2; exit 2
    fi
  done
  mkdir -p "$dir" 2>/dev/null || { echo "fleet-onboard: cannot create $dir" >&2; exit 1; }
  tmp=$(mktemp "$dir/.onboard.state.XXXXXX") || { echo "fleet-onboard: cannot write $dir" >&2; exit 1; }
  # Old lines, then the new ones, then the stamp; the LAST value of a key wins
  # and each key keeps the position it first appeared at.
  {
    state_dump
    for kv in "$@"; do
      printf '%s=%s\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | tr '\r\n' '  ')"
    done
    printf 'updated=%s\n' "$(date +%s)"
  } | awk '{ k=substr($0, 1, index($0,"=")-1); if (k == "updated") { u = $0; next }; if (!(k in v)) o[n++]=k; v[k]=$0 }
           END { for (i=0; i<n; i++) print v[o[i]]; print u }' > "$tmp"
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$f" || { rm -f "$tmp"; echo "fleet-onboard: write failed: $f" >&2; exit 1; }
}

brief() {
  local sess="" gh=1 conf r tag me="" step seat
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) shift; sess="${1:-}" ;;
      --no-gh)   gh=0 ;;
      *) usage ;;
    esac
    shift
  done
  [ -n "$sess" ] || sess=$(fleet_current_session)
  if [ -z "$sess" ] || ! conf=$(fleet_conf_file "$sess") || [ ! -f "$conf" ]; then
    echo "fleet-onboard: not inside a fleet (session='${sess:-}')" >&2
    exit 3
  fi
  fleet_load_conf "$sess"
  seat=$(fleet_seat)

  echo "===== fleet ====="
  echo "repo=${FLEET_REPO:-} session=$sess seat=${seat:-none}"
  if [ "$gh" = 1 ]; then
    me=$(gh api user --jq .login 2>/dev/null)
    echo "gh=${me:-NOT-LOGGED-IN}"
  fi
  echo "repos:"
  local nrepos; nrepos=$(fleet_repos "$sess" | grep -c .)
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    tag=""
    if fleet_repo_is_seed "$sess" "$r"; then
      tag="  [seed] 起步仓库 = 工具本身，不是新人的仓库"
      [ "$nrepos" -gt 1 ] && tag="$tag · 可拿掉: fleet-repo.sh remove $r"
    fi
    [ -n "$me" ] && [ -z "$tag" ] && [ "${r%%/*}" = "$me" ] && tag="  [mine]"
    echo "  $r$tag"
  done <<EOF
$(fleet_repos "$sess")
EOF

  echo "===== progress ($(state_file)) ====="
  if [ -s "$(state_file)" ]; then
    state_dump
    step=$(state_get step 2>/dev/null)
    echo "resume: ${step:-repo}"
  else
    echo "(none — a fresh start)"
    echo "resume: repo"
  fi
}

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
case "$cmd" in
  brief) brief "$@" ;;
  get)
    if [ $# -eq 0 ]; then state_dump
    else state_get "$1" || exit 1
    fi ;;
  set)   state_set "$@" ;;
  reset) rm -f "$(state_file)" ;;
  path)  state_file; echo ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
