#!/bin/bash
# scratch-pool.sh — a WARM POOL of pre-started scratch sessions, so dash ⌃s hands
# you a window you can type into IMMEDIATELY instead of one you have to wait for.
#
# The problem it removes (measured on a real client, not `send-keys` injection —
# injection writes straight into the pane's pty and hides the whole client leg):
#
#     ⌃s ............................................. 0.0s
#     window created (fetch 0.7s + worktree add 2.5s)  4.2s
#     `❯` input box rendered — LOOKS ready to a human   5.9s
#     first keystroke that actually survives            7.0s
#
# The last gap is NOT ours: Claude Code's TUI discards whatever input is in flight
# at the instant it mounts its input handler (type `a1b a2b a3b` into a cold
# `claude` half a second apart and the line ends up `a1ba3b` — the middle one is
# swallowed, the earlier one, still sitting in the pty buffer, survives). We cannot
# stop that flush. We CAN make it happen minutes earlier, to a window nobody is
# looking at — which is all this pool does.
#
# Mechanics: warm windows are parked in a HOLDING SESSION `<fleet>-pool` on the
# fleet's own socket (fleet_pool_session). ⌃s then `move-window`s a ready one into
# the fleet and renames it — the pane, its pty and the running claude survive the
# move untouched, and the window is typeable in the same tick (measured 0.29s, the
# poll granularity, vs 7.0s cold).
#
# Why a holding SESSION rather than a marked window in the fleet: every consumer
# that must not see warm entries already excludes them for free —
#   * fleet_session_count      — only counts sessions that have a plan/dash window
#   * fleet_session_count_for  — fleet-scoped
#   * the dash rows            — scoped by FLEET_SESSION
#   * fleet-restore            — @raw rows are never snapshotted
# so there is no per-consumer opt-out list to forget to register in (the failure
# mode that bites every "add it in N places" design). Nothing walks `list-windows
# -a` across the whole socket any more (the dash summarizer, which did, retired in
# issue #535); a helper that ever does should key off @claude_state — a warm entry
# has never run a turn, so nothing has ever set that option.
#
# Commands:
#   ensure <sess>   top the pool up to FLEET_SCRATCH_POOL ready entries (slow —
#                   spawns + waits for readiness; callers background it). The
#                   diskguard --watch tick runs it for every fleet (pool_watch),
#                   so a claimed slot is refilled without anyone asking; --tick
#                   marks that caller (it skips a slot another ensure is warming).
#   claim <sess>    move one READY entry into <sess>. Prints "<wid>\t<slug>\t<wt>"
#                   on success, nothing when the pool is cold (caller falls back
#                   to the normal cold spawn). Never blocks.
#   claim [<sess>] --repo <owner/name|-> --agent <claude|codex>
#                   the node's entry (issue #2233, EPIC #2230 C3): prints the
#                   claimed window's `@id` alone, exit 3 when that slot has no
#                   ready entry, and asks for the slot's refill a few seconds
#                   later. `--repo -` is the HOME slot. Either an --agent or no
#                   <sess> selects this contract; the 3-field form is unchanged.
#   reap <sess>     retire stale / dead / never-ready entries and their worktrees
#   status <sess>   one `slot` line per (repo | HOME) × agent, then one line per
#                   entry (for humans + the selftest). `--status` with no <sess>
#                   reads the caller's fleet.
#
# SLOTS (issue #2233): one per hosted repo AND one for HOME — a no-repo session
# warmed in $HOME, stamped `@norepo 1` (no worktree, no @raw, no @repo), the way
# dash-raw-session.sh --no-repo opens one. Each slot is per agent (`--agent`,
# else the slot's FLEET_AGENT). A slot grows only while the machine has room:
# load per core at most FLEET_POOL_LOAD_PER_CORE (1) and the disk above
# FLEET_DISK_WARN_GB (15) — otherwise it only shrinks. An entry whose agent
# configuration went old (fleet_cfg_state stale / renew / broken — an upgrade) is
# never handed out and is retired on the next pass, so an upgrade replaces the
# whole pool; a repo entry's worktree is fast-forwarded to origin/<base> before it
# is handed out (the tick fetches, the claim only moves the branch).
#
# One pool PER HOSTED REPO (issue #797), however many the fleet hosts (#1941):
# every warm window is stamped @repo, and each command takes `--repo <owner/name>`:
#   ensure/reap/status  with --repo: that repo's entries only, under that repo's
#                       conf (fleet conf + its overlay: FLEET_MAIN, base, agent,
#                       FLEET_SCRATCH_POOL…). Without: fan out over every hosted
#                       repo, one after another, and retire any entry whose repo
#                       the fleet no longer hosts.
#   claim               with --repo: only an entry of that repo. Without: the
#                       fleet's first repo.
# All repos share the one holding session; @repo is what tells them apart (an
# older unstamped entry is told by its worktree's origin, pool_repo). A fleet
# with no repo has no pool.
#
# Config (per-fleet conf; a repo overlay overrides any of it):
#   FLEET_SCRATCH_POOL       how many warm entries to keep per slot. Default 1
#                            (issue #2233); 0 or "" = OFF, and then every command
#                            behaves as it did before the default changed.
#   FLEET_POOL_MAX_AGE       seconds before an unclaimed entry is retired (1800).
#                            A warm worktree is a snapshot of origin/<base> taken
#                            when it was created; handing out a stale one silently
#                            branches your work off an old master.
#   FLEET_POOL_PROBE_TIMEOUT seconds to wait for an entry to become typeable (120).
#
# Readiness is not "the box rendered" — that is exactly the lie this file exists to
# fix (the box paints ~1.1s before input is accepted). But it is ALSO not "poke it
# and see if the poke echoes": typing into the TUI while it mounts permanently
# deafens it. See wait_settled() for the evidence and for what we watch instead.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

CMD="${1:-}"; SESS=''; DELAY=0; REPO_ARG=''; AGENT_ARG=''; TICK=0; SOON=0; NEWCLAIM=0
[ -n "$CMD" ] || { echo "usage: scratch-pool.sh {ensure|claim|reap|status} [<session>] [--delay] [--repo <owner/name|->] [--agent <a>]" >&2; exit 2; }
shift
case "$CMD" in --status|--ensure|--claim|--reap) CMD=${CMD#--} ;; esac
case "${1:-}" in ''|-*) NEWCLAIM=1 ;; *) SESS=$1; shift ;; esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --delay)   DELAY=1 ;;
    --tick)    TICK=1 ;;
    --soon)    SOON=1 ;;
    --repo)    REPO_ARG="${2:-}"; [ "$#" -gt 1 ] && shift ;;
    --repo=*)  REPO_ARG="${1#--repo=}" ;;
    --agent)   AGENT_ARG="${2:-}"; [ "$#" -gt 1 ] && shift ;;
    --agent=*) AGENT_ARG="${1#--agent=}" ;;
  esac
  shift
done
case "$AGENT_ARG" in '') ;; claude|codex) NEWCLAIM=1 ;; *) echo "scratch-pool: --agent is claude or codex" >&2; exit 2 ;; esac

# No <session>: the caller's fleet — the one it was spawned for, else the session
# its pane sits in, else the login's only fleet (one fleet per login, #980).
if [ -z "$SESS" ]; then
  SESS=${FLEET_SESSION:-}
  [ -z "$SESS" ] && [ -n "${TMUX:-}" ] && SESS=$(fleet_session_canon "$(fleet_current_session)")
  if [ -z "$SESS" ]; then
    _n=0
    for _s in $(fleet_sockets 2>/dev/null); do _n=$((_n + 1)); SESS=$_s; done
    [ "$_n" = 1 ] || SESS=''
  fi
  [ -n "$SESS" ] || { echo "scratch-pool: no session (pass one, or run it inside the fleet)" >&2; exit 2; }
fi

# The pool is never the CALLER's window: a claim runs from whichever pane pressed
# ⌃s, and fleet_load_conf would lay that window's repo overlay on top — leaking
# repo A's FLEET_AGENT / FLEET_SCRATCH_POOL into repo B's pool. No-op in a fleet
# (fleet_load_conf would otherwise read TMUX_PANE for the window's overlay).
unset TMUX_PANE
# A fleet is one fleet-up wrote a conf for: a session with none (a test server, a
# sandbox reading another login's sockets) has no pool, and nothing here touches it.
[ -f "$(fleet_conf_file "$SESS")" ] || { [ "$CMD" = claim ] && [ "$NEWCLAIM" = 1 ] && exit 3; exit 0; }
fleet_load_conf "$SESS"
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }
POOL=$(fleet_pool_session "$SESS")

# REPO: the one slot this pass serves — a hosted repo, or `-` for HOME (#2233).
# The pool is per repo, one road whatever the count (#1941). With no --repo,
# ensure/reap/status fan out over every hosted repo plus HOME, and claim takes the
# first repo.
if [ -z "$REPO_ARG" ]; then
  case "$CMD" in
    ensure|reap|status)
      # Fan out: one pass per slot, each under its own conf. The refill delay is
      # paid ONCE, here, and only when some slot has its pool on — with every
      # pool off this costs nothing (see cmd_ensure).
      if [ "$CMD" = ensure ] && [ "$DELAY" = 1 ]; then
        while IFS= read -r _r; do
          [ -n "$_r" ] || continue
          if [ "$_r" = - ]; then _w=${FLEET_SCRATCH_POOL-1}
          else _w=$( fleet_load_repo_conf "$SESS" "$_r" >/dev/null 2>&1; printf '%s' "${FLEET_SCRATCH_POOL-1}" ); fi
          case "$_w" in ''|*[!0-9]*|0) continue ;; esac
          sleep "${FLEET_POOL_REFILL_DELAY:-45}"; break
        done <<EOF
$(fleet_repos "$SESS")
-
EOF
      fi
      # An entry whose repo the fleet no longer hosts (or cannot be told) belongs
      # to no pass below: retire the window. Its worktree cannot be freed without
      # that repo's MAIN — the scratch janitor owns what is left. A HOME entry
      # (@norepo) belongs to the `-` pass.
      [ "$CMD" = status ] || for _w in $(TM list-windows -t "$POOL" -F '#{window_id}' 2>/dev/null); do
        [ "$(TM display-message -p -t "$_w" '#{@norepo}' 2>/dev/null)" = 1 ] && continue
        _r=$(TM display-message -p -t "$_w" '#{@repo}' 2>/dev/null)
        [ -n "$_r" ] && fleet_repo_hosted "$SESS" "$_r" && continue
        [ -z "$_r" ] && _wt=$(TM display-message -p -t "$_w" '#{@worktree}' 2>/dev/null) \
          && [ -n "$_wt" ] && [ -n "$(fleet_worktree_repo "$SESS" "$_wt")" ] && continue
        fleet_win_retire "$_w" "$SOCK"
        TM kill-window -t "$_w" 2>/dev/null
      done
      _pass=''
      [ "$TICK" = 1 ] && _pass="$_pass --tick"
      [ -n "$AGENT_ARG" ] && _pass="$_pass --agent $AGENT_ARG"
      while IFS= read -r _r; do
        [ -n "$_r" ] || continue
        # shellcheck disable=SC2086
        bash "$0" "$CMD" "$SESS" --repo "$_r" $_pass
      done <<EOF
$(fleet_repos "$SESS")
-
EOF
      exit 0 ;;
    *) REPO_ARG=$(fleet_repos "$SESS" | head -n1) ;;
  esac
fi
# claim's answer when it hands nothing out: the 3-field form says it with silence
# (exit 0, the caller's cold path follows), the node's form with exit 3.
empty() { if [ "$CMD" = claim ] && [ "$NEWCLAIM" = 1 ]; then exit 3; fi; exit 0; }
if [ "$REPO_ARG" = - ]; then
  REPO=-                                             # HOME: the fleet conf already loaded
else
  REPO=$(fleet_norm_repo "$REPO_ARG")
  [ -n "$REPO" ] || empty                            # no repo hosted: no repo pool
  fleet_load_repo_conf "$SESS" "$REPO" || empty      # not hosted: an empty pool
fi

WANT="${FLEET_SCRATCH_POOL-1}"; case "$WANT" in ''|*[!0-9]*) WANT=0;; esac
AGENT="${AGENT_ARG:-${FLEET_AGENT:-claude}}"
case "$AGENT" in claude|codex) ;; *) AGENT=claude ;; esac
MAXAGE="${FLEET_POOL_MAX_AGE:-1800}"; case "$MAXAGE" in ''|*[!0-9]*) MAXAGE=1800;; esac
PTIMEOUT="${FLEET_POOL_PROBE_TIMEOUT:-120}"; case "$PTIMEOUT" in ''|*[!0-9]*) PTIMEOUT=120;; esac
MAIN="${FLEET_MAIN:-}"
BASE="${FLEET_BASE_BRANCH:-master}"
[ "$REPO" = - ] && MAIN=''                          # HOME has no worktree to free
SLOT_NAME=$REPO; [ "$REPO" = - ] && SLOT_NAME=HOME
NOW() { date +%s; }
# What a fresh session would be started with now (fleet_cfg_state's reference),
# read once: an entry warmed before an upgrade is never handed out.
fleet_cfg_expected_load

# The account a warm entry was launched under is baked into its claude process
# (fleet-claude.sh exports CLAUDE_CODE_OAUTH_TOKEN at exec time), so an entry
# warmed under a rotated-away account must not be handed out.
acct_now() {
  if [ "$AGENT" = codex ]; then
    if [ -n "${FLEET_CODEX_ACCOUNTS:-}" ]; then
      local chome
      chome=$(FLEET_CONF_DIR="$FLEET_CONF_DIR" "$BIN/fleet-codex-account.sh" select --session "$SESS") || return 1
      printf 'codex:%s\n' "$chome"
    else
      printf 'codex:%s\n' "${FLEET_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"
    fi
  else
    "$BIN/fleet-account.sh" active 2>/dev/null
  fi
}

# The holding session MUST be the same size as the fleet session. A warm window
# born at 80x24 and moved into a 145x34 fleet gets resized on arrival, and Claude
# Code's TUI does not survive that resize: the pane goes on rendering the old
# 80-column frame and stops acting on input entirely — the exact "the box is there
# but typing does nothing" failure this pool exists to remove, re-created by the
# cure. So: create the pool session at the fleet's dimensions, and re-assert them
# on every top-up in case the operator's terminal changed size since.
fleet_dims() {
  local w h
  w=$(TM display-message -p -t "$SESS" '#{window_width}' 2>/dev/null)
  h=$(TM display-message -p -t "$SESS" '#{window_height}' 2>/dev/null)
  case "$w" in ''|*[!0-9]*) w=80;; esac
  case "$h" in ''|*[!0-9]*) h=24;; esac
  printf '%s %s\n' "$w" "$h"
}

wopt() { TM display-message -p -t "$1" "#{$2}" 2>/dev/null; }

# pool_repo <wid> → the repo a warm entry was built from: its @repo stamp, else
# (an entry warmed before #797) its worktree's origin. Empty when neither says.
pool_repo() {
  local r wt
  [ "$(wopt "$1" @norepo)" = 1 ] && { printf -- '-\n'; return 0; }   # the HOME slot
  r=$(wopt "$1" @repo)
  if [ -z "$r" ]; then
    wt=$(wopt "$1" @worktree)
    [ -n "$wt" ] && [ -d "$wt" ] && r=$(git -C "$wt" remote get-url origin 2>/dev/null)
  fi
  fleet_norm_repo "$r"
}

# pool_windows [all] → this slot's entries: REPO's (or HOME's) only — the holding
# session is shared by every slot — and of this pass's AGENT; `all` keeps every
# agent's (the reap of a slot's default agent retires the others').
pool_windows() {
  local w a
  for w in $(TM list-windows -t "$POOL" -F '#{window_id}' 2>/dev/null); do
    [ "$(pool_repo "$w")" = "$REPO" ] || continue
    if [ "${1:-}" != all ]; then a=$(wopt "$w" @pool_agent); [ "${a:-claude}" = "$AGENT" ] || continue; fi
    printf '%s\n' "$w"
  done
}

# retire <wid> — kill the window and free its worktree+branch. Idempotent.
retire() {
  local wid="$1" wt slug
  wt=$(wopt "$wid" @worktree); slug=$(wopt "$wid" @pool_slug)
  fleet_win_retire "$wid" "$SOCK"   # the pool's close (#1840)
  TM kill-window -t "$wid" 2>/dev/null
  [ -n "$MAIN" ] && [ -n "$slug" ] && [ -n "$wt" ] && fleet_scratch_free "$MAIN" "$slug" "$wt"
  return 0
}

# ---------------------------------------------------------------- readiness ----
# wait_settled <wid> — block until the entry is safe to hand out. NON-INVASIVE:
# it never sends the window a keystroke.
#
# The obvious design — type a probe char and wait for it to echo — is what this
# function used to do, and it BRICKS the session. Keystrokes delivered to Claude
# Code's TUI while it is still mounting leave it alive, idle, in the foreground
# process group, rendering a perfectly normal `❯` box — and permanently deaf: 30s
# of injected input after that produces nothing. The identical spawn with ZERO
# keystrokes sent to it is typeable 0.29s after the claim. So the readiness test
# must not touch the input at all; anything that "just pokes it to check" is the
# bug it is checking for.
#
# What we watch instead, both free and side-effect-less:
#   * the `❯` box is on screen (the TUI got as far as painting its input), and
#   * the claude process has gone quiet — POOL_QUIET_HITS consecutive samples
#     under POOL_QUIET_CPU% — and
#   * at least POOL_SETTLE_MIN seconds have passed since the box appeared, which
#     covers the ~1.1s input-mount flush with room to spare.
# Warming happens minutes before anyone presses ⌃s, so being generous here is free.
POOL_SETTLE_MIN="${FLEET_POOL_SETTLE_MIN:-10}"
POOL_STABLE_HITS="${FLEET_POOL_STABLE_HITS:-8}"   # x0.5s of an unchanging screen

input_line() { TM capture-pane -p -t "$1" 2>/dev/null | LC_ALL=C grep -m1 '❯'; }
screen_hash() { TM capture-pane -p -t "$1" 2>/dev/null | LC_ALL=C cksum | awk '{print $1}'; }

# claude_pid <wid> — the claude process under the pane. It is never the pane's own
# process: the pane runs `sh -c '<launch>; exec $SHELL'`, the launch is the
# session wrapper (#1784) that stays as claude's parent, and fleet-claude.sh may
# hand it to fleet-loop.py's bridge — so claude sits 2–4 levels down. Looking only
# one level down (the pre-wrapper layout) meant no entry ever settled (#2233).
claude_pid() {
  local pp c lvl=0 next
  pp=$(wopt "$1" pane_pid); [ -n "$pp" ] || return 1
  while [ -n "$pp" ] && [ "$lvl" -le 5 ]; do
    next=''
    for c in $pp; do
      ps -o command= -p "$c" 2>/dev/null | grep -qE '(^|/)claude( |$)' && { printf '%s\n' "$c"; return 0; }
      next="$next $(pgrep -P "$c" 2>/dev/null | tr '\n' ' ')"
    done
    pp=$(printf '%s' "$next" | tr -s ' '); pp=${pp# }; lvl=$((lvl + 1))
  done
  return 1
}

# wait_settled <wid> — block until the TUI has finished MOUNTING. Nothing is typed
# here; the gate has to be right, because a keystroke that lands during mount
# bricks the session for good (see warm_input).
#
# The load-bearing signal is that the SCREEN HAS STOPPED CHANGING: a mounting TUI
# repaints (banner → status → MCP warnings → footer), a mounted idle one does not
# repaint at all. So: box painted, screen hash unchanged for POOL_STABLE_HITS
# samples, and a floor of POOL_SETTLE_MIN seconds since the box first appeared.
#
# Deliberately NOT gated on CPU. Two measurements killed that idea from both ends:
# mount is mostly I/O wait at ~0% CPU, so a CPU-quiet gate fires EARLY (and an early
# warm-up keystroke bricks the session); and `ps -o %cpu` on macOS is a decaying
# AVERAGE since process start, so after a heavy boot — the operator's real fleet
# config, with its full MCP set — it stays above any sane threshold for minutes and
# the gate never opens at all. Warming timed out at 120s twice on the live fleet
# for exactly that reason, while that pane's screen had been stable since t=3s.
wait_settled() {
  local wid="$1" deadline rendered_at="" h last="" stable=0
  deadline=$(( $(NOW) + PTIMEOUT ))
  while [ "$(NOW)" -lt "$deadline" ]; do
    TM has-session -t "$POOL" 2>/dev/null || return 1
    [ "$(wopt "$wid" pane_dead)" = 1 ] && return 1
    if [ -z "$rendered_at" ]; then
      [ -n "$(input_line "$wid")" ] && rendered_at=$(NOW)
      sleep 0.5; continue
    fi
    h=$(screen_hash "$wid")
    if [ -n "$h" ] && [ "$h" = "$last" ]; then stable=$((stable + 1)); else stable=0; fi
    last="$h"
    claude_pid "$wid" >/dev/null || { sleep 0.5; continue; }   # still coming up
    if [ "$stable" -ge "$POOL_STABLE_HITS" ] \
       && [ $(( $(NOW) - rendered_at )) -ge "$POOL_SETTLE_MIN" ]; then
      return 0                                    # mounted; warm_input decides ready
    fi
    sleep 0.5
  done
  return 1
}

# warm_input <wid> — pay the FIRST-KEYSTROKE cost here, in the pool, and use it as
# the definitive readiness proof.
#
# Two measurements motivate this. (a) A window that has only ever been parked —
# never focused, never typed into — takes ~40s to echo its FIRST keystroke after
# being claimed, and 0.29s for every one after that. Handing that out relocates the
# stall instead of removing it. (b) Typing into the TUI while it MOUNTS bricks it
# permanently (see wait_settled). So the warm-up keystroke must come strictly after
# a settled mount — which is exactly what wait_settled establishes — and never
# before it.
#
# It doubles as the only trustworthy readiness signal there is: an entry is ready
# because we watched it echo, not because a box was painted. Anything that does not
# echo inside FLEET_POOL_WARM_TIMEOUT is retired rather than handed out — a bricked
# entry must never reach the operator.
POOL_WARM_CH='~'
POOL_WARM_TIMEOUT="${FLEET_POOL_WARM_TIMEOUT:-120}"

warm_input() {
  local wid="$1" deadline after rest
  TM send-keys -t "$wid" -l "$POOL_WARM_CH" 2>/dev/null
  deadline=$(( $(NOW) + POOL_WARM_TIMEOUT ))
  while [ "$(NOW)" -lt "$deadline" ]; do
    sleep 0.5
    [ "$(wopt "$wid" pane_dead)" = 1 ] && return 1
    after=$(input_line "$wid"); rest=${after#*❯}
    case "$rest" in
      *"$POOL_WARM_CH"*)
        TM send-keys -t "$wid" C-u 2>/dev/null      # clear the char we just typed
        sleep 0.5
        rest=$(input_line "$wid"); rest=${rest#*❯}
        case "$rest" in
          *[![:space:]]*) return 1 ;;               # would hand over a dirty prompt
        esac
        TM set-window-option -t "$wid" @pool_ready 1 2>/dev/null
        return 0 ;;
    esac
  done
  return 1
}

# ------------------------------------------------------------------- ensure ----
spawn_one() {
  local alloc slug='' wt acct launch stamp='' nsid='' wname win
  # Never warm the fleet past its own ceiling, and always leave one slot of
  # headroom so a warm entry can't be the reason a real spawn is refused.
  if [ "$REPO" = - ]; then
    wt=$HOME; wname=warm-home                 # HOME: the agent runs in $HOME, no worktree
    fleet_session_cap_ok "$SESS" >/dev/null || return 1
    acct=$(acct_now) || return 1
  else
    [ -n "$MAIN" ] || return 1
    [ -d "$MAIN/.git" ] || return 1
    fleet_session_cap_ok "$SESS" >/dev/null || return 1
    acct=$(acct_now) || return 1
    alloc=$(fleet_scratch_alloc "$MAIN" "$BASE" "$SESS") || return 1
    slug=${alloc%%	*}; wt=${alloc#*	}; wname="warm-${slug#scratch-}"
  fi
  read -r _w _h <<EOF
$(fleet_dims)
EOF
  printf -v launch 'env FLEET_LAUNCH_SESSION=%q %q --agent %q' "$SESS" "$BIN/fleet-session-wrap.sh" "$AGENT"
  if [ "$AGENT" = codex ]; then
    printf -v launch '%s --codex-home %q' "$launch" "${acct#codex:}"
  fi
  if [ "$REPO" = - ]; then
    # Same identity a cold --no-repo session gets (dash-raw-session.sh): a Claude
    # one runs under a session id of its own, stamped @norepo_sid so restore
    # resumes THAT conversation in $HOME; the window stamps @norepo before the
    # launcher reads its conf (#789).
    if [ "$AGENT" = claude ]; then
      nsid=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
      nsid=$(printf '%s' "$nsid" | tr 'A-F' 'a-f' | LC_ALL=C tr -cd '0-9a-f-')
      [ -n "$nsid" ] && launch="$launch --session-id $nsid"
    fi
    stamp=$(fleet_win_stamp_cmd @norepo 1 ${nsid:+@norepo_sid "$nsid"})
  fi
  if TM has-session -t "$POOL" 2>/dev/null; then
    TM set-option -t "$POOL" window-size manual >/dev/null 2>&1
    TM resize-window -t "$POOL" -x "$_w" -y "$_h" >/dev/null 2>&1
    win=$(TM new-window -d -P -F '#{window_id}' -t "$POOL:" -n "$wname" -c "$wt" \
            "$stamp$launch; exec \$SHELL" 2>/dev/null)
  else
    TM new-session -d -s "$POOL" -x "$_w" -y "$_h" -n "$wname" -c "$wt" \
      "$stamp$launch; exec \$SHELL" >/dev/null 2>&1
    TM set-option -t "$POOL" window-size manual >/dev/null 2>&1
    win=$(TM list-windows -t "$POOL" -F '#{window_id}' 2>/dev/null | head -1)
  fi
  [ -n "$win" ] || { [ -n "$slug" ] && fleet_scratch_free "$MAIN" "$slug" "$wt"; return 1; }
  TM set-window-option -t "$win" @pool 1 2>/dev/null
  TM set-window-option -t "$win" @pool_born "$(NOW)" 2>/dev/null
  TM set-window-option -t "$win" @pool_account "$acct" 2>/dev/null
  TM set-window-option -t "$win" @pool_agent "$AGENT" 2>/dev/null
  if [ "$REPO" = - ]; then
    TM set-window-option -t "$win" @norepo 1 2>/dev/null    # deliberately no repo, no worktree
    [ -n "$nsid" ] && TM set-window-option -t "$win" @norepo_sid "$nsid" 2>/dev/null
  else
    TM set-window-option -t "$win" @raw 1 2>/dev/null
    TM set-window-option -t "$win" @pool_slug "$slug" 2>/dev/null
    TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null
    TM set-window-option -t "$win" @repo "$REPO" 2>/dev/null
  fi
  if [ "$AGENT" = codex ]; then
    if python3 "$BIN/fleet-codex-warm.py" --socket "$SOCK" --pane "$win" --timeout "$PTIMEOUT" \
        --settle "$POOL_SETTLE_MIN" --stable-hits "$POOL_STABLE_HITS"; then
      TM set-window-option -t "$win" @pool_ready 1 2>/dev/null
      return 0
    fi
  elif wait_settled "$win" && warm_input "$win"; then return 0; fi
  retire "$win"; return 1                     # never came up — don't leave a husk
}

usable() {                                    # usable <wid> — ready, fresh, right account, current config
  local wid="$1" born age agent
  [ "$(wopt "$wid" @pool_ready)" = 1 ] || return 1
  agent=$(wopt "$wid" @pool_agent); [ "${agent:-claude}" = "$AGENT" ] || return 1
  [ "$(wopt "$wid" pane_dead)" = 1 ] && return 1
  born=$(wopt "$wid" @pool_born); case "$born" in ''|*[!0-9]*) return 1;; esac
  age=$(( $(NOW) - born )); [ "$age" -le "$MAXAGE" ] || return 1
  [ "$(wopt "$wid" @pool_account)" = "$(acct_now)" ] || return 1
  # Started on an older configuration (an upgrade since it was warmed, #2233):
  # 配置旧 / 待换新 / 会坏 are the list's own words for it — never handed out.
  # No fingerprint on it, or none expected, reads unknown and passes, as before.
  fleet_cfg_state "${agent:-claude}" "$(wopt "$wid" @agent_cfg)" "$(wopt "$wid" @agent_ver)"
  case "$FCFG_STATE" in stale|renew|broken) return 1 ;; esac
  # Geometry gate (see fleet_dims): handing out a window that will be resized on
  # arrival trades a 7s wait for a permanently wedged pane.
  read -r _fw _fh <<EOF
$(fleet_dims)
EOF
  [ "$(wopt "$wid" window_width)" = "$_fw" ] && [ "$(wopt "$wid" window_height)" = "$_fh" ] || return 1
  return 0
}

# align <wid> — bring a repo entry's worktree up to origin/<base> before it is
# handed out (#2233): it was cut when the entry was warmed, and work started on
# it would otherwise branch off an old master. Local only — a fast-forward of the
# scratch branch to the remote-tracking ref the tick's fetch (pool_fetch) keeps
# current — so a claim stays well under half a second. A worktree with commits of
# its own, or one git cannot move, fails: the caller retires it instead of
# handing it out. HOME entries and an entry with no worktree on disk pass.
align() {
  local wt
  [ "$REPO" = - ] && return 0
  wt=$(wopt "$1" @worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse --verify -q "refs/remotes/origin/$BASE" >/dev/null 2>&1 || return 0
  git -C "$wt" merge-base --is-ancestor "refs/remotes/origin/$BASE" HEAD 2>/dev/null && return 0
  git -C "$wt" merge --ff-only -q "refs/remotes/origin/$BASE" >/dev/null 2>&1
}

# pool_fetch — refresh origin/<base> once per pass, so align has the newest
# master to move to. Only a repo slot that holds an entry pays it (a spawn's
# fleet_scratch_alloc fetches on its own).
pool_fetch() {
  [ "$REPO" != - ] && [ -n "$MAIN" ] && [ -d "$MAIN/.git" ] || return 0
  git -C "$MAIN" fetch origin "$BASE" --quiet >/dev/null 2>&1
  return 0
}

# grow_hold — why this slot must not grow right now (prints it, exit 0), or
# nothing (exit 1): the machine's load per core above FLEET_POOL_LOAD_PER_CORE
# (default 1 — stricter than admission's 1.5: a warm entry is a nice-to-have, a
# real spawn is not), or the disk under diskguard's warn line FLEET_DISK_WARN_GB.
# A held slot only shrinks (#2233). An unreadable probe never holds.
pool_free_gb() {
  if [ -n "${FLEET_POOL_DISK_PROBE_CMD:-}" ]; then
    sh -c "$FLEET_POOL_DISK_PROBE_CMD" 2>/dev/null | awk 'NF{print int($1); exit}'; return 0
  fi
  df -Pk "${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}" 2>/dev/null | awk 'NR==2 { printf "%d", int($4/1048576) }'
}
grow_hold() {
  local lim="${FLEET_POOL_LOAD_PER_CORE:-1}" per warn="${FLEET_DISK_WARN_GB:-15}" free
  case "$lim" in ''|*[!0-9.]*) lim=1 ;; esac
  case "$warn" in ''|*[!0-9]*) warn=15 ;; esac
  per=$(_fleet_load_per_core)
  if [ -n "$per" ] && awk -v p="$per" -v m="$lim" 'BEGIN{ exit !(m > 0 && p > m) }'; then
    printf 'load %s/core > %s\n' "$per" "$lim"; return 0
  fi
  free=$(pool_free_gb)
  case "$free" in ''|*[!0-9]*) return 1 ;; esac
  [ "$free" -lt "$warn" ] && { printf 'disk %sGB < %sGB\n' "$free" "$warn"; return 0; }
  return 1
}

# pool_lock — one ensure per slot at a time: a warm-up outlasts the tick that
# started it, and two passes counting the same empty slot would warm two. The
# tick (--tick) skips a held slot; any other caller (a claim's refill, ⌃s's) waits
# for it, up to FLEET_POOL_LOCK_WAIT seconds. A holder that died frees it.
LOCKD=''
pool_unlock() { [ -n "$LOCKD" ] && rm -rf "$LOCKD" 2>/dev/null; LOCKD=''; return 0; }
pool_lock() {
  local d waited=0 max="${FLEET_POOL_LOCK_WAIT:-300}" holder slot
  case "$max" in ''|*[!0-9]*) max=300 ;; esac
  slot=home; [ "$REPO" = - ] || slot=$(fleet_slug "$REPO")
  d="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleets/$(fleet_slug "$SESS")/pool/$slot-$AGENT.lock"
  mkdir -p "${d%/*}" 2>/dev/null
  while ! mkdir "$d" 2>/dev/null; do
    holder=$(cat "$d/pid" 2>/dev/null)
    if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
      sleep 1; holder=$(cat "$d/pid" 2>/dev/null)          # a holder still writing its pid
      if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then rm -rf "$d" 2>/dev/null; continue; fi
    fi
    [ "$TICK" = 1 ] && return 1
    [ "$waited" -ge "$max" ] && return 1
    sleep 1; waited=$((waited + 1))
  done
  printf '%s\n' "$$" > "$d/pid" 2>/dev/null
  LOCKD=$d
  trap pool_unlock EXIT
  return 0
}

cmd_reap() {
  local wid set=''
  # The slot's default pass (no --agent) also retires an entry of another agent —
  # what is left after FLEET_AGENT changed; an --agent pass keeps to its own.
  [ -z "$AGENT_ARG" ] && set=all
  for wid in $(pool_windows $set); do usable "$wid" && continue
    # an entry still inside its probe window is neither usable nor stale yet
    [ "$(wopt "$wid" @pool_ready)" = 1 ] || {
      born=$(wopt "$wid" @pool_born)
      case "$born" in ''|*[!0-9]*) retire "$wid"; continue;; esac
      [ $(( $(NOW) - born )) -le $(( PTIMEOUT + 30 )) ] && continue
    }
    retire "$wid"
  done
}

cmd_ensure() {
  local have n wid hold
  [ "$WANT" -gt 0 ] || { cmd_reap; return 0; }
  # --delay: wait before rebuilding. Warming is a full cold claude boot, and the
  # caller is the ⌃s spawn — firing it at the instant the operator starts typing
  # into the window they just claimed is the one moment that contention is felt
  # (measured: first-keystroke echo went from sub-second to tens of seconds).
  # The sleep lives HERE, behind the pool-enabled gate, and not in the caller's
  # run-shell string: with the pool off this must cost nothing, and the spawner's
  # selftest executes run-shell synchronously — a sleep there added 45s to EVERY
  # spawn case and blew the CI job's 10-minute budget.
  [ "$DELAY" = 1 ] && sleep "${FLEET_POOL_REFILL_DELAY:-45}"
  # --soon: a claim's own refill (#2233) — a few seconds, so the slot is back
  # well inside the 30 s the batch promises, yet not on the claimer's first keys.
  [ "$SOON" = 1 ] && sleep "${FLEET_POOL_CLAIM_REFILL_DELAY:-5}"
  pool_lock || return 0
  cmd_reap
  # Count what is ready; an entry over the slot's size goes (a lowered
  # FLEET_SCRATCH_POOL shrinks the slot), and every one kept is moved to the
  # newest origin/<base> now, so the claim's own align is a no-op.
  have=0; n=0
  for wid in $(pool_windows); do
    usable "$wid" || continue
    if [ "$have" -ge "$WANT" ]; then retire "$wid"; continue; fi
    [ "$n" = 0 ] && { pool_fetch; n=1; }
    align "$wid" || { retire "$wid"; continue; }
    have=$((have + 1))
  done
  n=$(( WANT - have ))
  [ "$n" -gt 0 ] || return 0
  hold=$(grow_hold) && return 0               # a busy machine: only shrink (#2233)
  while [ "$n" -gt 0 ]; do spawn_one || break; n=$((n - 1)); done
}

# -------------------------------------------------------------------- claim ----
# Prints "<window-id>\t<slug>\t<worktree>" for a window now living in <sess> — or,
# for the node's form (NEWCLAIM), the window id alone. Exit 1 = nothing handed out.
cmd_claim() {
  local wid slug wt
  [ "$WANT" -gt 0 ] || return 1
  # @repo stays: a claimed window is a scratch OF that repo (dash-raw-session
  # stamps the same value again).
  TM has-session -t "$POOL" 2>/dev/null || return 1
  for wid in $(pool_windows); do
    usable "$wid" || continue
    # An entry git cannot bring up to origin/<base> is never handed out.
    align "$wid" || { retire "$wid"; continue; }
    slug=$(wopt "$wid" @pool_slug); wt=$(wopt "$wid" @worktree)
    # Claim-by-move: whoever's move-window succeeds owns it. A loser sees the
    # window gone from the pool session on the next iteration.
    TM move-window -s "$wid" -t "$SESS:" 2>/dev/null || continue
    TM set-window-option -t "$wid" -u @pool 2>/dev/null
    TM set-window-option -t "$wid" -u @pool_ready 2>/dev/null
    TM set-window-option -t "$wid" -u @pool_born 2>/dev/null
    TM set-window-option -t "$wid" -u @pool_account 2>/dev/null
    TM set-window-option -t "$wid" -u @pool_agent 2>/dev/null
    TM set-window-option -t "$wid" -u @pool_slug 2>/dev/null
    if [ "$NEWCLAIM" = 1 ]; then
      printf '%s\n' "$wid"
      # The node's caller has no ⌃s refill behind it: the slot asks for its own.
      TM run-shell -b "bash '$BIN/scratch-pool.sh' ensure '$SESS' --repo '$REPO' --agent '$AGENT' --soon >/dev/null 2>&1" 2>/dev/null
    else
      printf '%s\t%s\t%s\n' "$wid" "$slug" "$wt"
    fi
    return 0
  done
  return 1
}

cmd_status() {
  local wid ready=0 hold=''
  [ "$WANT" -gt 0 ] && hold=$(grow_hold)
  if TM has-session -t "$POOL" 2>/dev/null; then
    for wid in $(pool_windows); do usable "$wid" && ready=$((ready + 1)); done
  fi
  printf 'slot %s agent=%s want=%s ready=%s%s\n' "$SLOT_NAME" "$AGENT" "$WANT" "$ready" "${hold:+ hold=$hold}"
  TM has-session -t "$POOL" 2>/dev/null || { echo "pool: (none)  want=$WANT"; return 0; }
  for wid in $(pool_windows); do
    printf '%s  name=%s ready=%s age=%ss account=%s usable=%s repo=%s want=%s\n' \
      "$wid" "$(wopt "$wid" window_name)" "$(wopt "$wid" @pool_ready)" \
      "$(( $(NOW) - $(wopt "$wid" @pool_born) ))" "$(wopt "$wid" @pool_account)" \
      "$(usable "$wid" && echo yes || echo no)" "$SLOT_NAME" "$WANT"
  done
}

case "$CMD" in
  ensure) cmd_ensure ;;
  claim)  cmd_claim || empty ;;
  reap)   cmd_reap ;;
  status) cmd_status ;;
  *) echo "scratch-pool: unknown command '$CMD'" >&2; exit 2 ;;
esac
exit 0
