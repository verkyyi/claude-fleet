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
#                   spawns + waits for readiness; callers background it)
#   claim <sess>    move one READY entry into <sess>. Prints "<wid>\t<slug>\t<wt>"
#                   on success, nothing when the pool is cold (caller falls back
#                   to the normal cold spawn). Never blocks.
#   reap <sess>     retire stale / dead / never-ready entries and their worktrees
#   status <sess>   one line per entry (for humans + the selftest)
#
# One pool PER HOSTED REPO (issue #797). In a fleet hosting 2+ repos every warm
# window is stamped @repo, and each command takes `--repo <owner/name>`:
#   ensure/reap/status  with --repo: that repo's entries only, under that repo's
#                       conf (fleet conf + its overlay: FLEET_MAIN, base, agent,
#                       FLEET_SCRATCH_POOL…). Without: fan out over every hosted
#                       repo, one after another, and retire any entry whose repo
#                       the fleet no longer hosts.
#   claim               with --repo: only an entry of that repo. Without: the
#                       fleet conf's own repo (the pre-#797 pool).
# All repos share the one holding session; @repo is what tells them apart. A
# one-repo fleet (fleet_multirepo false) ignores all of it: no @repo stamp, no
# filter — byte for byte the historic single pool.
#
# Config (per-fleet conf; in a 2+ repo fleet a repo overlay overrides any of it):
#   FLEET_SCRATCH_POOL       how many warm entries to keep. 0 (default) = OFF.
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

CMD="${1:-}"; SESS="${2:-}"; DELAY=0; REPO_ARG=''
[ -n "$CMD" ] || { echo "usage: scratch-pool.sh {ensure|claim|reap|status} <session> [--delay] [--repo <owner/name>]" >&2; exit 2; }
[ -n "$SESS" ] || { echo "scratch-pool: no session" >&2; exit 2; }
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --delay)  DELAY=1 ;;
    --repo)   REPO_ARG="${2:-}"; [ "$#" -gt 1 ] && shift ;;
    --repo=*) REPO_ARG="${1#--repo=}" ;;
  esac
  shift
done

# The pool is never the CALLER's window: a claim runs from whichever pane pressed
# ⌃s, and fleet_load_conf would lay that window's repo overlay on top — leaking
# repo A's FLEET_AGENT / FLEET_SCRATCH_POOL into repo B's pool. No-op in a fleet
# without repos/ (fleet_load_conf returns before it reads TMUX_PANE).
unset TMUX_PANE
fleet_load_conf "$SESS"
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }
POOL=$(fleet_pool_session "$SESS")

# REPO is set iff this fleet hosts 2+ repos — the one switch every per-repo branch
# below keys on, so a one-repo fleet never reaches any of them.
REPO=''
if fleet_multirepo "$SESS"; then
  if [ -z "$REPO_ARG" ]; then
    case "$CMD" in
      ensure|reap|status)
        # Fan out: one pass per hosted repo, each under its own conf. The refill
        # delay is paid ONCE, here, and only when some repo has its pool on — with
        # every pool off this costs nothing (see cmd_ensure).
        if [ "$CMD" = ensure ] && [ "$DELAY" = 1 ]; then
          while IFS= read -r _r; do
            [ -n "$_r" ] || continue
            _w=$( fleet_load_repo_conf "$SESS" "$_r" >/dev/null 2>&1; printf '%s' "${FLEET_SCRATCH_POOL:-0}" )
            case "$_w" in ''|*[!0-9]*|0) continue ;; esac
            sleep "${FLEET_POOL_REFILL_DELAY:-45}"; break
          done <<EOF
$(fleet_repos "$SESS")
EOF
        fi
        # An entry whose repo the fleet no longer hosts (or cannot be told) belongs
        # to no pass below: retire the window. Its worktree cannot be freed without
        # that repo's MAIN — the scratch janitor owns what is left.
        [ "$CMD" = status ] || for _w in $(TM list-windows -t "$POOL" -F '#{window_id}' 2>/dev/null); do
          _r=$(TM display-message -p -t "$_w" '#{@repo}' 2>/dev/null)
          [ -n "$_r" ] && fleet_repo_hosted "$SESS" "$_r" && continue
          [ -z "$_r" ] && _wt=$(TM display-message -p -t "$_w" '#{@worktree}' 2>/dev/null) \
            && [ -n "$_wt" ] && [ -n "$(fleet_worktree_repo "$SESS" "$_wt")" ] && continue
          TM kill-window -t "$_w" 2>/dev/null
        done
        while IFS= read -r _r; do
          [ -n "$_r" ] || continue
          bash "$0" "$CMD" "$SESS" --repo "$_r"
        done <<EOF
$(fleet_repos "$SESS")
EOF
        exit 0 ;;
      *) REPO_ARG=$(fleet_repos "$SESS" | head -n1) ;;
    esac
  fi
  REPO=$(fleet_norm_repo "$REPO_ARG")
  fleet_load_repo_conf "$SESS" "$REPO" || exit 0     # not hosted: an empty pool
elif [ -n "$REPO_ARG" ] && [ -n "${FLEET_REPO:-}" ] \
     && [ "$(fleet_norm_repo "$REPO_ARG")" != "$(fleet_norm_repo "$FLEET_REPO")" ]; then
  exit 0                                             # a one-repo fleet has no pool for it
fi

WANT="${FLEET_SCRATCH_POOL:-0}"; case "$WANT" in ''|*[!0-9]*) WANT=0;; esac
AGENT="${FLEET_AGENT:-claude}"
case "$AGENT" in claude|codex) ;; *) AGENT=claude ;; esac
MAXAGE="${FLEET_POOL_MAX_AGE:-1800}"; case "$MAXAGE" in ''|*[!0-9]*) MAXAGE=1800;; esac
PTIMEOUT="${FLEET_POOL_PROBE_TIMEOUT:-120}"; case "$PTIMEOUT" in ''|*[!0-9]*) PTIMEOUT=120;; esac
MAIN="${FLEET_MAIN:-}"
BASE="${FLEET_BASE_BRANCH:-master}"
NOW() { date +%s; }

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
  r=$(wopt "$1" @repo)
  if [ -z "$r" ]; then
    wt=$(wopt "$1" @worktree)
    [ -n "$wt" ] && [ -d "$wt" ] && r=$(git -C "$wt" remote get-url origin 2>/dev/null)
  fi
  fleet_norm_repo "$r"
}

# pool_windows → this pool's entries: every window in a one-repo fleet, only
# REPO's in a 2+ repo fleet (the holding session is shared by all of them).
pool_windows() {
  local w
  for w in $(TM list-windows -t "$POOL" -F '#{window_id}' 2>/dev/null); do
    if [ -z "$REPO" ] || [ "$(pool_repo "$w")" = "$REPO" ]; then printf '%s\n' "$w"; fi
  done
}

# retire <wid> — kill the window and free its worktree+branch. Idempotent.
retire() {
  local wid="$1" wt slug
  wt=$(wopt "$wid" @worktree); slug=$(wopt "$wid" @pool_slug)
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

# claude_pid <wid> — the claude process under the pane (the pane itself runs the
# zsh wrapper from fleet-claude.sh, so look one level down too).
claude_pid() {
  local pp c
  pp=$(wopt "$1" pane_pid); [ -n "$pp" ] || return 1
  if ps -o command= -p "$pp" 2>/dev/null | grep -qE '(^|/)claude( |$)'; then printf '%s\n' "$pp"; return 0; fi
  for c in $(pgrep -P "$pp" 2>/dev/null); do
    ps -o command= -p "$c" 2>/dev/null | grep -qE '(^|/)claude( |$)' && { printf '%s\n' "$c"; return 0; }
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
  local alloc slug wt win acct launch
  [ -n "$MAIN" ] || return 1
  [ -d "$MAIN/.git" ] || return 1
  # Never warm the fleet past its own ceiling, and always leave one slot of
  # headroom so a warm entry can't be the reason a real spawn is refused.
  fleet_session_cap_ok "$SESS" >/dev/null || return 1
  acct=$(acct_now) || return 1
  alloc=$(fleet_scratch_alloc "$MAIN" "$BASE") || return 1
  slug=${alloc%%	*}; wt=${alloc#*	}
  read -r _w _h <<EOF
$(fleet_dims)
EOF
  printf -v launch 'env FLEET_LAUNCH_SESSION=%q %q --agent %q' "$SESS" "$BIN/fleet-claude.sh" "$AGENT"
  if [ "$AGENT" = codex ]; then
    printf -v launch '%s --codex-home %q' "$launch" "${acct#codex:}"
  fi
  if TM has-session -t "$POOL" 2>/dev/null; then
    TM set-option -t "$POOL" window-size manual >/dev/null 2>&1
    TM resize-window -t "$POOL" -x "$_w" -y "$_h" >/dev/null 2>&1
    win=$(TM new-window -d -P -F '#{window_id}' -t "$POOL:" -n "warm-${slug#scratch-}" -c "$wt" \
            "$launch; exec \$SHELL" 2>/dev/null)
  else
    TM new-session -d -s "$POOL" -x "$_w" -y "$_h" -n "warm-${slug#scratch-}" -c "$wt" \
      "$launch; exec \$SHELL" >/dev/null 2>&1
    TM set-option -t "$POOL" window-size manual >/dev/null 2>&1
    win=$(TM list-windows -t "$POOL" -F '#{window_id}' 2>/dev/null | head -1)
  fi
  [ -n "$win" ] || { fleet_scratch_free "$MAIN" "$slug" "$wt"; return 1; }
  TM set-window-option -t "$win" @raw 1 2>/dev/null
  TM set-window-option -t "$win" @pool 1 2>/dev/null
  TM set-window-option -t "$win" @pool_slug "$slug" 2>/dev/null
  TM set-window-option -t "$win" @pool_born "$(NOW)" 2>/dev/null
  TM set-window-option -t "$win" @pool_account "$acct" 2>/dev/null
  TM set-window-option -t "$win" @pool_agent "$AGENT" 2>/dev/null
  TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null
  [ -n "$REPO" ] && TM set-window-option -t "$win" @repo "$REPO" 2>/dev/null
  if [ "$AGENT" = codex ]; then
    if python3 "$BIN/fleet-codex-warm.py" --socket "$SOCK" --pane "$win" --timeout "$PTIMEOUT" \
        --settle "$POOL_SETTLE_MIN" --stable-hits "$POOL_STABLE_HITS"; then
      TM set-window-option -t "$win" @pool_ready 1 2>/dev/null
      return 0
    fi
  elif wait_settled "$win" && warm_input "$win"; then return 0; fi
  retire "$win"; return 1                     # never came up — don't leave a husk
}

usable() {                                    # usable <wid> — ready, fresh, right account
  local wid="$1" born age agent
  [ "$(wopt "$wid" @pool_ready)" = 1 ] || return 1
  agent=$(wopt "$wid" @pool_agent); [ "${agent:-claude}" = "$AGENT" ] || return 1
  [ "$(wopt "$wid" pane_dead)" = 1 ] && return 1
  born=$(wopt "$wid" @pool_born); case "$born" in ''|*[!0-9]*) return 1;; esac
  age=$(( $(NOW) - born )); [ "$age" -le "$MAXAGE" ] || return 1
  [ "$(wopt "$wid" @pool_account)" = "$(acct_now)" ] || return 1
  # Geometry gate (see fleet_dims): handing out a window that will be resized on
  # arrival trades a 7s wait for a permanently wedged pane.
  read -r _fw _fh <<EOF
$(fleet_dims)
EOF
  [ "$(wopt "$wid" window_width)" = "$_fw" ] && [ "$(wopt "$wid" window_height)" = "$_fh" ] || return 1
  return 0
}

cmd_reap() {
  local wid
  for wid in $(pool_windows); do usable "$wid" && continue
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
  local have n
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
  cmd_reap
  have=0; for wid in $(pool_windows); do usable "$wid" && have=$((have + 1)); done
  n=$(( WANT - have ))
  while [ "$n" -gt 0 ]; do spawn_one || break; n=$((n - 1)); done
}

# -------------------------------------------------------------------- claim ----
# Prints "<window-id>\t<slug>\t<worktree>" for a window now living in <sess>.
cmd_claim() {
  local wid slug wt
  [ "$WANT" -gt 0 ] || return 0
  # @repo stays: a claimed window is a scratch OF that repo (dash-raw-session
  # stamps the same value again).
  TM has-session -t "$POOL" 2>/dev/null || return 0
  for wid in $(pool_windows); do
    usable "$wid" || continue
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
    printf '%s\t%s\t%s\n' "$wid" "$slug" "$wt"
    return 0
  done
  return 0
}

cmd_status() {
  local wid
  TM has-session -t "$POOL" 2>/dev/null || { echo "pool: (none)  want=$WANT"; return 0; }
  for wid in $(pool_windows); do
    printf '%s  name=%s ready=%s age=%ss account=%s usable=%s%s\n' \
      "$wid" "$(wopt "$wid" window_name)" "$(wopt "$wid" @pool_ready)" \
      "$(( $(NOW) - $(wopt "$wid" @pool_born) ))" "$(wopt "$wid" @pool_account)" \
      "$(usable "$wid" && echo yes || echo no)" "${REPO:+ repo=$REPO want=$WANT}"
  done
}

case "$CMD" in
  ensure) cmd_ensure ;;
  claim)  cmd_claim ;;
  reap)   cmd_reap ;;
  status) cmd_status ;;
  *) echo "scratch-pool: unknown command '$CMD'" >&2; exit 2 ;;
esac
exit 0
