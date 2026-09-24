#!/bin/bash
# fleet-move.sh — move a LIVE (or done) fleet session to another login's fleet,
# on another machine, over ssh (issue #1067).
#
# fleet-migrate.sh is an account swap on ONE machine; fleet-transfer.sh is
# claude<->codex in ONE pane; /fleet-handoff writes a doc. None of them move a
# session's transcript + worktree to a DIFFERENT login/host. This does, driven
# entirely from the SOURCE side over ssh — it needs only ssh and the target's
# fleet install (bin/fleet-move-remote.sh, this script's other half).
#
#   fleet-move.sh <window>… --to <user>@<host> [opts]
#   opts: --fleet <sess>    the TARGET's fleet, when that login runs more than
#                           one (legacy multi-fleet; #979/#980 makes this rare) —
#                           default: the target's one configured fleet.
#         --session <sess>  the SOURCE fleet, when run outside tmux (default:
#                           the caller's own, like fleet-migrate.sh --session)
#         --dry-run         print the plan (incl. a READ-ONLY target probe);
#                           touch nothing on either machine.
#         --keep-source     copy + resume on the target, but never stop or close
#                           the source window — see the FORK HAZARD note below.
#
# What actually happens, per window (issue #1067's verified-by-hand recipe,
# reordered so every REVERSIBLE check runs before the one step that is not):
#   1. read the window's bindings (name/@issue/@raw/@worktree/@origin/@repo/
#      @wid) and its session id — the registry (~/.claude/sessions/<pid>.json),
#      falling back to the newest transcript in the cwd's project dir;
#   2. refuse a dirty worktree, and a detached HEAD;
#   3. push the branch when it is ahead of base (idempotent; safe to run twice);
#   4. ask the TARGET to allocate a fresh worktree for this repo and land the
#      pushed (or, if it never diverged from base, merely renamed) branch onto
#      it — nothing on the source is touched yet, so a target-side failure here
#      costs nothing to undo;
#   5. (skipped under --keep-source) gracefully stop the source agent — Escape,
#      `/exit`, Enter, then wait; a session that never exits this way (the
#      `failed:no-exit` fleet-worker-stop.sh can also return, on an idle raw
#      window) gets SIGTERM instead — verified by hand to leave the transcript
#      intact — then the SAME wait again;
#   6. copy the transcript (`<sid>.jsonl` + the `<sid>/` sidecar, when one
#      exists) to the target's `~/.claude/projects/<encoded target cwd>/` over
#      a tar pipe;
#   7. ask the target to open a window in that worktree running
#      `fleet-claude.sh --resume <sid>`, carry over @issue/@raw/@origin/@repo/
#      @wid, and verify a live Claude process actually appears under the pane;
#   8. only once that verify succeeds: close the source window (`kill-window`)
#      — unless --keep-source, which leaves it running on purpose.
#
# FORK HAZARD: a session's transcript is one append-only file. Two live agents
# resuming the SAME session id — one still running on the source, one just
# launched on the target — will both append to their own copy of it from the
# moment of the copy onward, and nothing here (or in Claude Code) reconciles
# that afterwards. Step 8 exists so that never happens on a plain move.
# --keep-source is the deliberate override (inspecting the target before
# committing, a throwaway duplicate) — it is on you to make sure only one side
# keeps talking to that session id.
#
# What this script does NOT do: it never deletes the source worktree/branch —
# only the WINDOW closes. The worktree is left exactly where the ordinary
# rotation-gap/janitor policy already handles an unbound worktree (docs/
# CLEANUP.md); nothing here special-cases "moved" vs. "abandoned".
#
# Exit status is the REASON (issue #683's convention: every script picks its
# own small table and documents it here, printing the same text on stderr):
#   0   moved — every requested window moved (or, for one window, that window)
#   1   partial — 2+ windows requested, at least one moved and at least one did
#       not (see stderr for which); never used for a single window
#   2   usage error
#   3   refused:not-found     the window/handle does not resolve to a live window
#   4   refused:not-eligible  a panel/hub window, a window with no @worktree/cwd
#                             worth moving, or one whose repo cannot be resolved
#   5   refused:hibernating   @worker_lifecycle is set; the sleep controller owns
#                             the pane (issue #808) — wake it there first
#   6   refused:dirty         the worktree has uncommitted changes, or a detached
#                             HEAD — commit/stash by hand, then retry
#   7   failed:push           `git push` of the branch ahead of base failed
#   8   failed:target         the target refused/failed before the source was
#                             touched (bad ssh, no fleet install, repo not
#                             hosted, worktree alloc/land, or the transcript copy)
#   9   failed:no-exit        the source agent did not exit (graceful, then
#                             SIGTERM) within the wait — left running, as is
#  10   failed:verify         the target window opened but no Claude ever
#                             appeared under its pane — SOURCE LEFT RUNNING
#                             (never closed on an unverified target)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

PANEL_RE='^(plan|dash|backlog)$'
EXIT_WAIT="${FLEET_MOVE_EXIT_WAIT:-30}"     # s to wait for a graceful `/exit`
TERM_WAIT="${FLEET_MOVE_TERM_WAIT:-10}"     # s to wait after a SIGTERM fallback
CLOSE_WAIT="${FLEET_MOVE_CLOSE_WAIT:-15}"   # s to wait for the SessionEnd hook
REMOTE_BIN_NAME='.claude/fleet/bin/fleet-move-remote.sh'   # relative to the target's $HOME

die() { printf 'fleet-move: %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }

# --- session id (byte-for-byte the fleet-migrate.sh recipe) --------------------
project_dir_for() {  # <cwd> → the Claude Code project dir for that cwd
  printf '%s/%s' "${FLEET_CC_PROJECTS_DIR:-$HOME/.claude/projects}" "$(printf '%s' "$1" | tr '/.' '--')"
}
session_id_for() {
  local cpid="$1" cwd="$2" sid pdir f
  sid=$(fleet_cc_session_id "$cpid" 2>/dev/null)
  [ -n "$sid" ] && { printf '%s' "$sid"; return 0; }
  pdir="$(project_dir_for "$cwd")"
  [ -d "$pdir" ] || return 1
  f=$(ls -t "$pdir"/*.jsonl 2>/dev/null | head -1); [ -n "$f" ] || return 1
  f=${f##*/}; printf '%s' "${f%.jsonl}"
}

wopt() { TM display-message -p -t "$1" "$2" 2>/dev/null; }
window_closed() {
  local o; o=$(TM display-message -p -t "$1" '#{pane_pid}|#{pane_dead}' 2>/dev/null) || return 0
  case "$o" in ''|'|'*|*'|1') return 0;; esac
  return 1
}
# agent_alive <pid> — see fleet-worker-stop.sh: a zombie (tmux/Linux can lose
# SIGCHLD, issue #781) still answers `kill -0` and must read as gone.
agent_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')
  case "$st" in Z*) return 1 ;; esac
  return 0
}

move_eligible() {  # <name> <hub>
  printf '%s' "$1" | grep -qE "$PANEL_RE" && return 1
  [ "$2" = 1 ] && return 1
  return 0
}

# --- ssh plumbing ----------------------------------------------------------------
# %q escapes each word for THIS shell's own quoting rules; joined with real
# spaces, the string ssh hands the remote shell reproduces the original argv —
# nothing here relies on the remote (or this) shell's word-splitting.
remote_cmd() {
  local out='' a
  for a in "$@"; do out="${out}${out:+ }$(printf '%q' "$a")"; done
  printf '%s' "$out"
}
ssh_run() { ssh -o BatchMode=yes "$TO" "$(remote_cmd "$@")"; }

# Sourced (fleet-move-selftest.sh pins the pure helpers above) → define only; a
# direct run dispatches. Same guard idiom as fleet-migrate.sh/fleet-account.sh.

# --- arg parsing -------------------------------------------------------------
move_main() {
  SESS='' TO='' TARGET_FLEET='' DRY=0 KEEP=0; WIDS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) TO="${2:-}"; shift 2 ;;
      --to=*) TO="${1#--to=}"; shift ;;
      --fleet) TARGET_FLEET="${2:-}"; shift 2 ;;
      --fleet=*) TARGET_FLEET="${1#--fleet=}"; shift ;;
      --session) SESS="${2:-}"; shift 2 ;;
      --session=*) SESS="${1#--session=}"; shift ;;
      --dry-run) DRY=1; shift ;;
      --keep-source) KEEP=1; shift ;;
      -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
      --*) die "unknown option '$1'" ;;
      *) WIDS+=("$1"); shift ;;
    esac
  done
  [ "${#WIDS[@]}" -gt 0 ] || die 'no window given'
  case "$TO" in *@*) ;; *) die "--to needs <user>@<host>" ;; esac

  [ -n "$SESS" ] || SESS=$(fleet_current_session)
  [ -n "$SESS" ] || die 'no tmux session (pass --session <fleet>)'
  fleet_load_conf "$SESS" 2>/dev/null || :
  SOCK=$(fleet_socket "$SESS")
  TM() { tmux -L "$SOCK" "$@"; }
  SK() { FLEET_ALLOW_SENDKEYS=1 tmux -L "$SOCK" send-keys "$@"; }

  _norm=(); for _w in ${WIDS[@]+"${WIDS[@]}"}; do _norm+=("$(fleet_wid_target "$_w" "$SOCK")"); done
  WIDS=(${_norm[@]+"${_norm[@]}"})

  # One cheap probe up front: the target's $HOME (so REMOTE_BIN is a concrete
  # path — no reliance on the remote shell expanding `~`/`$HOME` inside an
  # already-%q-escaped word, which would defeat the escaping) and that its
  # fleet-move-remote.sh half is actually installed.
  REMOTE_HOME=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TO" 'printf %s "$HOME"' 2>/dev/null)
  [ -n "$REMOTE_HOME" ] || die "cannot reach $TO over ssh"
  REMOTE_BIN="$REMOTE_HOME/$REMOTE_BIN_NAME"
  ssh -o BatchMode=yes "$TO" test -x "$REMOTE_BIN" 2>/dev/null \
    || die "$TO has no $REMOTE_BIN_NAME — update its fleet install first"

  moved=0; failed=0; total="${#WIDS[@]}"; LAST_RC=0

  move_one() {
    local wid="$1" lockdir rc
    lockdir=$(wopt "$wid" '#{@worktree}')
    if [ -n "$lockdir" ] && [ -d "$lockdir" ]; then
      fleet_transition_lock_take "$lockdir" || { say "  – $wid: another transition owns this worktree — skipped"; return 4; }
    fi
    move_one_body "$wid"; rc=$?
    [ -z "$lockdir" ] || [ ! -d "$lockdir" ] || fleet_transition_lock_drop "$lockdir"
    return "$rc"
  }

  move_one_body() {
    local wid="$1" name cwd state raw iss wt origin hnd norepo hub
    name=$(wopt "$wid" '#{window_name}')
    [ -n "$name" ] || { say "  ✗ $wid: no such window — refused:not-found"; return 3; }
    hub=$(wopt "$wid" '#{@hub}'); cwd=$(wopt "$wid" '#{pane_current_path}')
    state=$(wopt "$wid" '#{@claude_state}'); raw=$(wopt "$wid" '#{@raw}')
    iss=$(wopt "$wid" '#{@issue}'); wt=$(wopt "$wid" '#{@worktree}')
    origin=$(wopt "$wid" '#{@origin}'); norepo=$(wopt "$wid" '#{@norepo}')
    hnd=$(wopt "$wid" '#{@wid}')

    if ! move_eligible "$name" "$hub"; then
      say "  – $name ($wid): not eligible (panel/hub) — refused:not-eligible"; return 4
    fi
    if [ -n "$(wopt "$wid" '#{@worker_lifecycle}')" ]; then
      say "  – $name ($wid): hibernating — wake it before moving — refused:hibernating"; return 5
    fi
    if [ "$norepo" = 1 ]; then
      say "  – $name ($wid): a no-repo (\$HOME) session cannot be moved — refused:not-eligible"; return 4
    fi
    # Resolve the window's REPO before deciding whether @cwd is its own worktree
    # or the repo's read-only base checkout — fleet_window_repo re-reads the
    # window's own options, so this needs no local $wt/$FLEET_MAIN yet, and a
    # multi-repo fleet's later fleet_load_repo_conf then loads the RIGHT main.
    local repo; repo=$(fleet_window_repo "$SESS" "$wid")
    [ -n "$repo" ] || { say "  – $name ($wid): cannot resolve this window's repo — refused:not-eligible"; return 4; }
    fleet_load_repo_conf "$SESS" "$repo" >/dev/null 2>&1 || :
    local wmain="${FLEET_MAIN:-}"
    [ -n "$wt" ] || { [ -n "$cwd" ] && [ -n "$wmain" ] && [ "${cwd%/}" != "${wmain%/}" ] && wt="$cwd"; }
    [ -n "$wt" ] && [ -d "$wt" ] || { say "  – $name ($wid): no worktree to move — refused:not-eligible"; return 4; }
    wt=$(cd "$wt" && pwd -P)

    local dirty; dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
    local branch; branch=$(git -C "$wt" branch --show-current 2>/dev/null)
    if [ -n "$dirty" ]; then
      say "  – $name ($wid): worktree has uncommitted changes — refused:dirty"; return 6
    fi
    if [ -z "$branch" ]; then
      say "  – $name ($wid): detached HEAD — refused:dirty"; return 6
    fi

    local base="${FLEET_BASE_BRANCH:-master}"
    local ahead; ahead=$(git -C "$wt" rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 0)
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac

    local cpid; cpid=$(fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null) || cpid=""
    local sid; sid=$(session_id_for "${cpid:-0}" "$cwd") || sid=""
    [ -n "$sid" ] || { say "  – $name ($wid): no session id (registry + transcript lookup failed) — refused:not-eligible"; return 4; }

    local ahead_msg='' keep_msg=''
    [ "$ahead" -gt 0 ] 2>/dev/null && ahead_msg=" (+$ahead ahead of $base)"
    [ "$KEEP" = 1 ] && keep_msg=' [keep-source]'
    say "  → $name ($wid): $repo @ $branch$ahead_msg → $TO${TARGET_FLEET:+ (fleet $TARGET_FLEET)}$keep_msg"

    if [ "$DRY" = 1 ]; then
      local plan
      plan=$(ssh_run "$REMOTE_BIN" plan --repo "$repo" ${TARGET_FLEET:+--fleet "$TARGET_FLEET"})
      if [ -z "$plan" ]; then
        say "    ✗ target probe failed (reason above) — failed:target"; return 8
      fi
      say "    ✓ target ready: fleet=${plan%%$'\t'*}"
      [ "$ahead" -gt 0 ] 2>/dev/null && say "    would push $branch ($ahead commit(s) ahead of $base)"
      say "    would stop pid ${cpid:-<none>}, copy session ${sid%%-*}…, resume on $TO, then $([ "$KEEP" = 1 ] && echo 'LEAVE this window running' || echo 'close this window')"
      return 0
    fi

    # --- 3. push, if ahead of base (idempotent; before anything destructive) ----
    if [ "$ahead" -gt 0 ] 2>/dev/null; then
      git -C "$wt" push -u origin "$branch" >/dev/null 2>&1 \
        || { say "  ✗ $name ($wid): git push of $branch failed — failed:push"; return 7; }
    fi

    # --- 4. target: allocate + land the worktree (nothing on source touched) ----
    local pushed_flag=''; [ "$ahead" -gt 0 ] 2>/dev/null && pushed_flag='--pushed'
    local prov; prov=$(ssh_run "$REMOTE_BIN" provision --repo "$repo" --branch "$branch" \
      ${pushed_flag:+"$pushed_flag"} ${TARGET_FLEET:+--fleet "$TARGET_FLEET"})
    if [ -z "$prov" ]; then
      say "  ✗ $name ($wid): target could not provision a worktree for $repo — failed:target"; return 8
    fi
    local rfleet twt _tsock
    IFS=$'\t' read -r rfleet twt _tsock <<<"$prov"
    [ -n "$rfleet" ] && [ -n "$twt" ] || { say "  ✗ $name ($wid): target provision returned no worktree — failed:target"; return 8; }

    local prior_reported; prior_reported=$(wopt "$wid" '#{@reported}')
    local ldir="$wt"; fleet_rotate_lease_take "$ldir" "move $name ($wid) → $TO" 2>/dev/null || :

    # Every remaining call pins the SAME target fleet `provision` resolved — never
    # re-derive it from (possibly empty) --fleet, which could re-resolve
    # differently if the target's fleet set changed mid-move.
    abort_target() { ssh_run "$REMOTE_BIN" discard --wt "$twt" --branch "$branch" --repo "$repo" --fleet "$rfleet" >/dev/null 2>&1 || :; }

    # --- 5. stop the source agent (skipped under --keep-source) -----------------
    if [ "$KEEP" != 1 ] && [ -n "$cpid" ]; then
      TM set-window-option -t "$wid" @reported 1 2>/dev/null
      SK -t "$wid" Escape 2>/dev/null; sleep 0.6
      SK -t "$wid" -l '/exit' 2>/dev/null; sleep 0.6; SK -t "$wid" Enter 2>/dev/null
      local i alive=1
      for ((i = 1; i <= EXIT_WAIT; i++)); do
        agent_alive "$cpid" || { alive=0; break; }
        [ "$i" = 6 ] && ! window_closed "$wid" && SK -t "$wid" Enter 2>/dev/null
        sleep 1
      done
      if [ "$alive" = 1 ]; then
        # A `/exit` that never lands (fleet-worker-stop.sh's failed:no-exit on an
        # idle raw window) still yields to SIGTERM, verified by hand to leave the
        # transcript intact.
        if fleet_pane_claude_pid "$wid" "$SOCK" 2>/dev/null | grep -qx "$cpid"; then
          kill -TERM "$cpid" 2>/dev/null || :
          for ((i = 1; i <= TERM_WAIT; i++)); do agent_alive "$cpid" || { alive=0; break; }; sleep 1; done
        fi
      fi
      if [ "$alive" = 1 ]; then
        fleet_rotate_lease_drop "$ldir"; abort_target
        [ "${prior_reported:-}" = 1 ] && TM set-window-option -t "$wid" @reported 1 2>/dev/null || TM set-window-option -t "$wid" -u @reported 2>/dev/null
        say "  ✗ $name ($wid): pid $cpid did not exit — left running — failed:no-exit"; return 9
      fi
    fi

    # --- 6. copy the transcript over a tar pipe ----------------------------------
    local pdir; pdir="$(project_dir_for "$cwd")"
    local dest; dest="$(printf '%s' "$twt" | tr '/.' '--')"
    local sidecar=(); [ -d "$pdir/$sid" ] && sidecar=("$sid")
    if ! tar -C "$pdir" -cf - "$sid.jsonl" ${sidecar[@]+"${sidecar[@]}"} 2>/dev/null | ssh -o BatchMode=yes "$TO" "$(remote_cmd "$REMOTE_BIN" receive --dest "$dest")"; then
      fleet_rotate_lease_drop "$ldir"; abort_target
      say "  ✗ $name ($wid): transcript copy to $TO failed — failed:target"; return 8
    fi

    # --- 7. target: open the window, resume, verify ------------------------------
    local launch; launch=$(ssh_run "$REMOTE_BIN" launch --wt "$twt" --sid "$sid" --name "$name" \
      --raw "${raw:-0}" --state "${state:-done}" --fleet "$rfleet" \
      ${hnd:+--wid "$hnd"} ${iss:+--issue "$iss"} ${origin:+--origin "$origin"} ${repo:+--repo "$repo"})
    local nw ncp
    IFS=$'\t' read -r nw ncp _ <<<"$launch"
    fleet_rotate_lease_drop "$ldir"
    if [ -z "$ncp" ]; then
      say "  ? $name ($wid): resumed on $TO ($nw) but no Claude appeared — SOURCE LEFT RUNNING — failed:verify"
      say "    inspect by hand: ssh $TO tmux -L $rfleet attach -t $nw"
      return 10
    fi

    # --- 8. verified: close the source (unless --keep-source) -------------------
    if [ "$KEEP" = 1 ]; then
      say "  ✓ $name ($wid → $TO:$nw, pid $ncp): resumed — SOURCE LEFT RUNNING (--keep-source): do not let both sides keep talking to session ${sid%%-*}…"
    else
      for ((i = 1; i <= CLOSE_WAIT; i++)); do window_closed "$wid" && break; sleep 1; done
      TM kill-window -t "$wid" 2>/dev/null || :
      say "  ✓ $name ($wid → $TO:$nw, pid $ncp): moved, session ${sid%%-*}…"
    fi
    return 0
  }

  for wid in ${WIDS[@]+"${WIDS[@]}"}; do
    move_one "$wid"; rc=$?
    LAST_RC=$rc
    if [ "$rc" -eq 0 ]; then moved=$((moved + 1)); else failed=$((failed + 1)); fi
  done

  failed_msg=''; [ "$failed" -gt 0 ] && failed_msg=", $failed failed"
  dry_msg=''; [ "$DRY" = 1 ] && dry_msg=' (dry-run)'
  say "fleet-move: $moved/$total moved$failed_msg$dry_msg"
  if [ "$total" -eq 1 ]; then exit "$LAST_RC"; fi
  [ "$failed" -eq 0 ] && exit 0
  [ "$moved" -eq 0 ] && exit "$LAST_RC"
  exit 1
}
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then move_main "$@"; exit $?; fi
