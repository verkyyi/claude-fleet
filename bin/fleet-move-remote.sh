#!/bin/bash
# fleet-move-remote.sh — the TARGET half of fleet-move.sh (issue #1067). Lives
# in the normal install (`~/.claude/fleet/bin/`, same as every other script
# here) and is invoked over ssh, once per subcommand, with plain argv — the
# caller (fleet-move.sh) %q-escapes every argument for THIS shell before ssh
# ever sees it, so nothing here needs to guess at word-splitting either.
#
# Never run by hand: fleet-move.sh is the only intended caller. Subcommands:
#   home                                          → this login's $HOME
#   plan     --repo <o/n> [--fleet <sess>]        → READ-ONLY feasibility check
#   provision --repo <o/n> --branch <br> [--pushed] [--fleet <sess>]
#                                                  → allocate + land a worktree
#   receive  --dest <encoded-dir-name>            → tar -x a transcript from stdin
#   launch   --wt <dir> --sid <uuid> [--name <n>] [--wid <h>] [--issue <n>]
#            [--raw 0|1] [--origin <o>] [--repo <o/n>] [--state <s>]
#            [--fleet <sess>]                     → open + resume + verify
#   discard  --wt <dir> --branch <br> --repo <o/n> [--fleet <sess>]
#                                                  → undo a failed provision
#   movein   --fleet <sess> --bundle <tar> --repo <o/n> --branch <br> --sid <uuid>
#            [--pushed] [--name <n>] [--wid <h>] [--issue <n>] [--raw 0|1]
#            [--origin <o>] [--origin-wid <w>] [--state <s>]
#                                                  → provision + receive + launch
#                                                    in ONE call, from a bundle
#                                                    file (issue #1426)
#
# `movein` is the hub path (fleet-move.sh --via hub, issue #1426): the source
# never reaches this machine, so the hub hands the target a journalled
# worker_move_in, this login's ccquota agent downloads the transcript tar to
# <bundle>, and fleet_control.py runs `movein` — the same provision, receive and
# launch the ssh path drives one call at a time, run here back to back, with a
# failed receive undoing its provision. Prints `<window>\t<pid>\t<worktree>`.
# Exit: 0 moved · 1 usage/refused · 7 provision failed · 8 transcript unpack
# failed (provision undone) · 10 the window opened but no agent appeared.
#
# One-fleet-per-login (#979/#980): every subcommand that needs "the fleet"
# resolves the login's ONE configured fleet unless --fleet names one (the
# legacy multi-fleet case). Two or zero configured fleets with no --fleet is a
# refusal, never a guess.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-move-remote: %s\n' "$*" >&2; exit 1; }

# resolve_fleet [<wanted>] → the one fleet this login runs, or <wanted> when it
# is one of the configured ones.
resolve_fleet() {
  local wanted="${1:-}" list n
  list=$(fleet_each_conf | cut -f1)
  if [ -n "$wanted" ]; then
    printf '%s\n' "$list" | grep -qFx "$wanted" || return 1
    printf '%s' "$wanted"; return 0
  fi
  n=$(printf '%s\n' "$list" | grep -c .)
  [ "$n" -eq 1 ] || return 1
  printf '%s\n' "$list" | head -n1
}

# load_repo <fleet> <repo> → FLEET_MAIN/FLEET_BASE_BRANCH for <repo> on <fleet>,
# refusing when it is not hosted there or has no base checkout on disk.
load_repo() {
  fleet_load_repo_conf "$1" "$2" >/dev/null 2>&1 || return 1
  [ -n "${FLEET_MAIN:-}" ] && [ -d "$FLEET_MAIN" ]
}

cmd="${1:-}"; shift || :

case "$cmd" in
  home)
    printf '%s' "$HOME"
    ;;

  plan)
    repo='' fleetw=''
    while [ $# -gt 0 ]; do case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --fleet) fleetw="${2:-}"; shift 2 ;;
      *) die "plan: unknown arg $1" ;;
    esac; done
    [ -n "$repo" ] || die 'plan: --repo required'
    sess=$(resolve_fleet "$fleetw") || die 'no single configured fleet on this login (pass --fleet)'
    load_repo "$sess" "$repo" || die "fleet $sess does not host $repo (or its base checkout is missing)"
    [ -w "$(dirname "$FLEET_MAIN")" ] || die "worktree root not writable: $(dirname "$FLEET_MAIN")"
    printf '%s\t%s\t%s\n' "$sess" "$FLEET_MAIN" "${FLEET_BASE_BRANCH:-master}"
    ;;

  provision)
    repo='' fleetw='' branch='' pushed=0
    while [ $# -gt 0 ]; do case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --fleet) fleetw="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --pushed) pushed=1; shift ;;
      *) die "provision: unknown arg $1" ;;
    esac; done
    [ -n "$repo" ] && [ -n "$branch" ] || die 'provision: --repo and --branch required'
    sess=$(resolve_fleet "$fleetw") || die 'no single configured fleet on this login (pass --fleet)'
    load_repo "$sess" "$repo" || die "fleet $sess does not host $repo (or its base checkout is missing)"
    # A branch can be checked out in only ONE worktree at a time: a stale one
    # left by an earlier failed/aborted move (or an operator retry before it was
    # cleaned up) makes the checkout below fail with an opaque git error — catch
    # it here with a message that names the actual stale worktree.
    stale=$(git -C "$FLEET_MAIN" worktree list --porcelain \
      | awk -v b="refs/heads/$branch" '/^worktree /{wt=$2} /^branch /{if ($2==b) print wt}')
    [ -z "$stale" ] || die "branch $branch is already checked out at $stale on this target — clean that up first (a previous move may have left it)"
    alloc=$(fleet_scratch_alloc "$FLEET_MAIN" "${FLEET_BASE_BRANCH:-master}" "$sess") || die 'scratch-N allocation failed'
    slug="${alloc%%$'\t'*}"; wt="${alloc#*$'\t'}"
    if [ "$branch" != "$slug" ]; then
      ok=0
      if [ "$pushed" = 1 ]; then
        git -C "$wt" fetch origin "$branch:refs/remotes/origin/$branch" >/dev/null 2>&1 \
          && git -C "$wt" checkout -B "$branch" "origin/$branch" >/dev/null 2>&1 && ok=1
      else
        git -C "$wt" checkout -B "$branch" >/dev/null 2>&1 && ok=1
      fi
      if [ "$ok" != 1 ]; then
        fleet_scratch_free "$FLEET_MAIN" "$slug" "$wt"
        die "cannot land branch $branch onto the allocated worktree"
      fi
      git -C "$wt" branch -D "$slug" >/dev/null 2>&1 || :
    fi
    printf '%s\t%s\t%s\n' "$sess" "$wt" "$(fleet_socket "$sess")"
    ;;

  receive)
    dest=''
    while [ $# -gt 0 ]; do case "$1" in
      --dest) dest="${2:-}"; shift 2 ;;
      *) die "receive: unknown arg $1" ;;
    esac; done
    case "$dest" in ''|*/*|.|..) die 'receive: bad --dest' ;; esac
    d="$HOME/.claude/projects/$dest"
    mkdir -p "$d" || die "mkdir failed: $d"
    tar -C "$d" -xf - || die 'tar extract failed'
    ;;

  launch)
    wt='' sid='' fleetw='' name='moved' wid='' issue='' raw=0 origin='' repo='' state='done'
    while [ $# -gt 0 ]; do case "$1" in
      --wt) wt="${2:-}"; shift 2 ;;
      --sid) sid="${2:-}"; shift 2 ;;
      --fleet) fleetw="${2:-}"; shift 2 ;;
      --name) name="${2:-}"; shift 2 ;;
      --wid) wid="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --raw) raw="${2:-0}"; shift 2 ;;
      --origin) origin="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --state) state="${2:-done}"; shift 2 ;;
      *) die "launch: unknown arg $1" ;;
    esac; done
    [ -n "$wt" ] && [ -n "$sid" ] && [ -d "$wt" ] || die 'launch: --wt (existing dir) and --sid required'
    sess=$(resolve_fleet "$fleetw") || die 'no single configured fleet on this login (pass --fleet)'
    SOCK=$(fleet_socket "$sess")
    TM() { tmux -L "$SOCK" "$@"; }
    LAUNCH="${FLEET_MOVE_LAUNCH:-$BIN/fleet-claude.sh}"
    boot="${FLEET_MOVE_BOOT_WAIT:-15}"
    cmdline="'$LAUNCH' --resume '$sid'; exec \$SHELL"
    nw=$(TM new-window -d -t "$sess:" -n "$name" -c "$wt" -P -F '#{window_id}' "$cmdline" 2>/dev/null)
    [ -n "$nw" ] || die 'tmux new-window failed'
    TM set-window-option -t "$nw" @worktree "$wt" 2>/dev/null
    # The session's lifelong identity (issue #1646) rode the bundle as
    # `<sid>.fleet-id` (fleet-move.sh fid_bundle) — stamped verbatim, never
    # re-minted. Either project-dir spelling: the hub road and the ssh road differ.
    for _d in "$(fleet_mangle_path "$wt")" "$(printf '%s' "$wt" | tr '/.' '--')"; do
      _ff="$HOME/.claude/projects/$_d/$sid.fleet-id"
      [ -f "$_ff" ] || continue
      _fid=$(head -c 64 "$_ff" 2>/dev/null | tr -d '[:space:]'); rm -f "$_ff"
      fleet_is_fid "$_fid" && TM set-window-option -t "$nw" @fleet_id "$_fid" 2>/dev/null
    done
    TM set-window-option -t "$nw" @raw "$raw" 2>/dev/null
    [ -n "$issue" ] && TM set-window-option -t "$nw" @issue "$issue" 2>/dev/null
    [ -n "$origin" ] && TM set-window-option -t "$nw" @origin "$origin" 2>/dev/null
    [ -n "$repo" ] && TM set-window-option -t "$nw" @repo "$repo" 2>/dev/null
    [ -n "$wid" ] && fleet_wid_stamp "$nw" "$SOCK" "$wid" >/dev/null 2>&1
    TM set-window-option -t "$nw" @claude_state "$state" 2>/dev/null
    TM set-window-option -t "$nw" @claude_state_ts "$(date +%s)" 2>/dev/null
    fleet_hub_nudge   # issue #1481
    ncp=''; i=0
    while [ "$i" -lt "$boot" ]; do
      ncp=$(fleet_pane_claude_pid "$nw" "$SOCK" 2>/dev/null) && [ -n "$ncp" ] && break
      i=$((i + 1)); sleep 1
    done
    printf '%s\t%s\t%s\n' "$nw" "${ncp:-}" "$sess"
    ;;

  discard)
    wt='' branch='' repo='' fleetw=''
    while [ $# -gt 0 ]; do case "$1" in
      --wt) wt="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --fleet) fleetw="${2:-}"; shift 2 ;;
      *) die "discard: unknown arg $1" ;;
    esac; done
    [ -n "$wt" ] && [ -n "$repo" ] || die 'discard: --wt and --repo required'
    sess=$(resolve_fleet "$fleetw") || die 'no single configured fleet on this login (pass --fleet)'
    load_repo "$sess" "$repo" || die "fleet $sess does not host $repo"
    fleet_scratch_free "$FLEET_MAIN" "${branch:-}" "$wt"
    ;;

  movein)
    fleetw='' bundle='' repo='' branch='' sid='' pushed='' name='moved' wid='' issue='' raw=0 origin='' owid='' state='done'
    while [ $# -gt 0 ]; do case "$1" in
      --fleet) fleetw="${2:-}"; shift 2 ;;
      --bundle) bundle="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --sid) sid="${2:-}"; shift 2 ;;
      --pushed) pushed=--pushed; shift ;;
      --name) name="${2:-}"; shift 2 ;;
      --wid) wid="${2:-}"; shift 2 ;;
      --issue) issue="${2:-}"; shift 2 ;;
      --raw) raw="${2:-0}"; shift 2 ;;
      --origin) origin="${2:-}"; shift 2 ;;
      --origin-wid) owid="${2:-}"; shift 2 ;;
      --state) state="${2:-done}"; shift 2 ;;
      *) die "movein: unknown arg $1" ;;
    esac; done
    [ -n "$fleetw" ] && [ -n "$repo" ] && [ -n "$branch" ] && [ -n "$sid" ] || die 'movein: --fleet, --repo, --branch and --sid required'
    [ -f "$bundle" ] || die "movein: no bundle at ${bundle:-<none>}"
    prov=$(bash "$0" provision --repo "$repo" --branch "$branch" ${pushed:+"$pushed"} --fleet "$fleetw") || exit 7
    IFS=$'\t' read -r rfleet twt _ <<<"$prov"
    [ -n "$twt" ] || exit 7
    # Claude Code names a project dir by turning EVERY non-alphanumeric into `-`.
    if ! bash "$0" receive --dest "$(fleet_mangle_path "$twt")" <"$bundle"; then
      bash "$0" discard --wt "$twt" --branch "$branch" --repo "$repo" --fleet "$rfleet" >/dev/null 2>&1 || :
      exit 8
    fi
    launch=$(bash "$0" launch --wt "$twt" --sid "$sid" --name "$name" --raw "$raw" --state "$state" --fleet "$rfleet" \
      ${wid:+--wid "$wid"} ${issue:+--issue "$issue"} ${origin:+--origin "$origin"} --repo "$repo") || exit 10
    IFS=$'\t' read -r nw ncp _ <<<"$launch"
    if [ -n "$nw" ] && [ -n "$owid" ]; then
      tmux -L "$(fleet_socket "$rfleet")" set-window-option -t "$nw" @origin_wid "$owid" 2>/dev/null
    fi
    printf '%s\t%s\t%s\n' "$nw" "$ncp" "$twt"
    [ -n "$ncp" ] || exit 10
    ;;

  *)
    die "unknown command: ${cmd:-<none>}"
    ;;
esac
