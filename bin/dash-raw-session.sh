#!/bin/bash
# dash-raw-session.sh [--name <name>] [--prompt <text>] [--agent <a>] [--pin] [--node <m>] [<fleet-session>] — open a
# RAW (non-issue-bound) scratch Claude window in a fleet: plain `claude` on the
# fleet's socket, with NO GitHub issue and (unless --prompt) NO seed prompt, but in
# its OWN git worktree off the base branch (issue #290). It is the counterpart to the issue-bound spawners
# (dash-issue-session.sh / backlog Enter / prefix+n), every one of which binds a
# window to exactly one issue (issue #214). Use it for ad-hoc exploration,
# experiments, or throwaway commands that may need to WRITE code.
#
# Why a worktree (not $FLEET_MAIN) — the three wins, issue #290:
#   1. WRITABLE — the base checkout is hook-enforced read-only; a scratch sitting
#      there literally can't edit code. In its own `scratch-<N>` worktree it can
#      experiment freely without touching base.
#   2. ESCALATABLE FOR FREE — a scratch that turns real just pushes its branch and
#      opens a PR (`fixes #N` optional). The prmap is repo-wide, so the janitor
#      reaps a merged `scratch-<N>` like any worker on merge — zero new machinery.
#      Or escalate it PROPERLY (issue #520): once the requirement is clear, file
#      the issue and BIND this same session to it —
#      `fleet-issue-file.sh --title "…" --bind`, or `fleet-bind.sh <N>` for an
#      issue that already exists. That renames the branch `scratch-<K>` →
#      `issue-<N>` in place (the DIRECTORY keeps its name, so the running Claude's
#      cwd never moves), stamps @issue, drops @raw, and claims the issue — so the
#      session that holds all the context becomes the worker, instead of spawning
#      a second one to re-ground from zero.
#   3. RESOLVABLE TRANSCRIPTS — the unique cwd fixes the "can't resolve the
#      transcript from the shared base checkout" limit (#214): a scratch's own
#      transcript is findable, and (issue #466) it is now CAPTURED in the
#      /fleet-history ledger when its window closes — keyed by the `scratch-<N>`
#      slug this script allocates below — so it browses and RESUMES like a worker.
#
# The window:
#   * runs in a fresh `<repo-parent>/<repo-dir>-scratch-<N>` worktree on a new
#     `scratch-<N>` branch off origin/<base> (mirrors dash-issue-session.sh's
#     worktree mechanics), so it can edit code and land via PR like a worker.
#   * is marked @raw=1, carries @worktree=<path>, and has NO @issue, so the
#     issue machinery leaves it alone.
#   * is named `scratch-<N>` (matching its worktree suffix) by default, OR an
#     optional name via --name (issue #225). The full name also prefills the first
#     input as an UNSENT draft (unless --prompt supplies a seed). Everything
#     downstream keys off @raw=1 / absence
#     of @issue, NOT the window name — but it must not collide with a panel name
#     (plan/dash/backlog), which the dash hides; such a name (or one that empties
#     out after sanitizing) falls back to the auto `scratch-<N>` name.
#
# How the rest of the fleet treats it (all handled gracefully, most for free):
#   * dash        — LISTED (only plan/dash/backlog are excluded from the list),
#                   with `~<N>` in the id column, in indigo against a worker's
#                   green `#<N>` (issue #529). The id is read from @worktree, so
#                   it survives a --name/⌃n rename and a wandered cwd — the two
#                   states where the window name stops carrying `scratch-<N>`.
#   * session cap — COUNTS toward FLEET_MAX_SESSIONS / the global cap (it is a
#                   real Claude session holding a slot), so it is cap-checked here.
#   * classifier — runs normally (its state shows in the dash).
#   * worktree janitor — REAPS it by the scratch rules (issue #290): once the window
#                        is gone, a clean+no-unpushed `scratch-<N>` worktree is
#                        removed silently; a dirty/unpushed one is KEPT and surfaced
#                        once — an experiment is never silently deleted. `dash ⌃x`
#                        force-reap covers manual disposal.
#   * reapers     — SKIP @raw windows (no issue/PR/land → nothing to act on),
#                   and it holds a slot so headroom checks see one fewer free slot.
#   * fleet-restore — snapshots and restores worktree-backed scratch windows with
#                     @raw/@worktree intact (#680); legacy shared-base windows are
#                     excluded. Idle/done sessions resume parked, without a nudge.
#   * /fleet-history — INDEXED on close and resumable (#466): keyed `scratch-<N>`,
#                     listed as `~<N>`, restored with ⌃o into a fresh @raw window.
#
# With no <fleet-session> the window is created in the CALLER's fleet (the
# interactive dash path). A HEADLESS caller — no fleet pane: a script, a daemon, a
# selftest — names the fleet with <fleet-session>; in that mode focus never moves.
# From INSIDE a fleet it may only name that same fleet: a different one is refused
# (issue #980). One fleet per login (EPIC #977) holds every repo, so the old
# spawn-into-another-fleet move is gone — pick the repo with --repo instead.
#
# --repo <owner/name> / --no-repo (issue #789): which repo the scratch belongs to.
# In a fleet hosting 2+ repos an omitted --repo gives the session NO repo (the
# view is always `all`, #1034) — unless the caller names the row the operator
# has highlighted: --selection <row-id> (issue #997; `@<wid>`,
# `hdr:<owner/name>`, `hdr:none`, fleet_selection_repo) takes THAT row's repo, or
# $HOME for a no-repo row, and anything it cannot resolve keeps the rule above.
# A one-repo fleet takes its only repo.
# --no-repo starts the agent in $HOME with no worktree, for work that spans repos:
# stamped `@norepo 1` (never mistaken for a legacy untagged window) with no
# @repo/@worktree/@raw, so no reaper ever resolves a worktree to remove; a Claude
# one launches with `--session-id <uuid>`, stamped as @norepo_sid, so fleet-restore
# resumes THAT conversation in $HOME, not whatever else ran there last. No ledger
# row (nothing lands).
#
# The dash's ⌃s is a ONE-KEYSTROKE spawn (issue #444): no name popup, no confirm —
# press it and the scratch window is on its way. Naming was a prompt nobody filled
# in (the auto `scratch-<N>` matches the worktree and reads better in the dash), and
# a popup on the tap-first path cost a keyboard round-trip for an empty line. A name
# is still available non-interactively via --name, and any window can be renamed
# after the fact.
#
# --prompt <text>: a SEEDED scratch — a CLI / headless caller's path (e.g.
# `--prompt '/fleet-handoff pickup <file>' --repo <owner/name>`). The
# dash prompt line hands its text over as --name-file: a window name plus an
# editable, unsent draft. Only --prompt is handed to `claude` as its initial prompt,
# exactly how dash-issue-session.sh seeds a worker, so the session starts WORKING on
# it instead of sitting at an empty `❯`. Everything else — worktree, @raw, cap,
# naming, reaping — is the plain scratch. A seeded scratch always takes the COLD
# path (never a warm-pool window): the pool's value is an instantly TYPEABLE `❯`,
# which a seeded session has no use for, and delivering a prompt into a running
# TUI would mean `send-keys` — the TUI's bracketed paste eats the trailing Enter
# (the same reason inter-agent messaging never send-keys), so the only prompt
# channel that is deterministic is the launch argument.
set -uo pipefail

# Args (order-independent): --name <n> / --name=<n> is the optional window name
# and input draft; --prompt <t> / --prompt=<t> is the optional submitted seed;
# --bg backgrounds the slow half of the spawn (the dash ⌃s / typed-↵ path — see
# below); the lone positional is the headless <fleet-session>.
NAME=""; PROMPT=""; TARGET_SESS=""; BG=0; PIN=0; ORIGIN=""; AGENT=""; REPO_ARG=""; NOREPO=0; SEL=""; NODE_ARG=""; ORIGIN_WID=""; PRINT_WIN=0; REAP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)        NAME="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --name=*)      NAME="${1#--name=}"; shift ;;
    # --origin (issue #503): spawn provenance. Stated by a caller that knows it;
    # empty → auto-detected from the calling pane in the FOREGROUND pass below
    # (the --bg re-exec has no caller pane, so the value rides this flag through).
    --origin)      ORIGIN="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --origin=*)    ORIGIN="${1#--origin=}"; shift ;;
    # --name-file=<f> (issue #304): the BACKGROUND spawn pass — the --bg pass staged
    # the (arbitrary user) name in a temp file and re-exec'd us via fleet_bg; read +
    # delete it. No --bg on that pass, so it falls straight through and spawns.
    --name-file=*) f="${1#--name-file=}"; NAME="$(cat "$f" 2>/dev/null)"; rm -f "$f"; shift ;;
    --prompt)      PROMPT="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --prompt=*)    PROMPT="${1#--prompt=}"; shift ;;
    # --prompt-file=<f>: same staging as --name-file — the seed is arbitrary user
    # text and is NEVER interpolated into the run-shell string.
    --prompt-file=*) f="${1#--prompt-file=}"; PROMPT="$(cat "$f" 2>/dev/null)"; rm -f "$f"; shift ;;
    # --agent (issue #547): `claude` | `codex` for THIS scratch, overriding the
    # fleet's FLEET_AGENT. Rides the --bg re-exec and lands in the launcher's argv;
    # validated below so only a known token is embedded in a command string. An
    # explicit agent always takes the COLD path — the warm pool holds windows
    # launched under the fleet default, which may be the other agent.
    --agent)       AGENT="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --agent=*)     AGENT="${1#--agent=}"; shift ;;
    --bg)          BG=1; shift ;;
    # --pin (issue #1169): stamp @pin 1 so the window sorts to the top of the
    # dash (dash-pin-toggle.sh's tier) — fleet-up's first-fleet guide.
    --pin)         PIN=1; shift ;;
    --repo)        REPO_ARG="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --repo=*)      REPO_ARG="${1#--repo=}"; shift ;;
    --no-repo)     NOREPO=1; shift ;;
    --selection)   SEL="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --selection=*) SEL="${1#--selection=}"; shift ;;
    # --node (issues #1425, #1541): which machine opens it — the same word it is
    # for an issue session. `auto` (the hub picks by load, account headroom and
    # the per-person cap), `local`, or a machine name. Default with the hub
    # module on (CCQUOTA_FLEET=1): FLEET_SPAWN_NODE, else auto (#1475). A start
    # the hub itself sent is already placed: fleet-control-read.sh says --node
    # local. With the module off nothing changes unless --node names another
    # machine (refused). See «Which machine opens it» below.
    --node)        NODE_ARG="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --node=*)      NODE_ARG="${1#--node=}"; shift ;;
    # --origin-wid (issue #1541): the parent's worker_id when the parent is on
    # ANOTHER machine (a hub-placed start; fleet-control-read.sh passes it) —
    # stamped as the window's @origin_wid verbatim, its key as @origin.
    --origin-wid)  ORIGIN_WID="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --origin-wid=*) ORIGIN_WID="${1#--origin-wid=}"; shift ;;
    # --print (issue #1541): a headless caller's receipt — once the window
    # exists, ONE stdout line `<window_id>\t<name>\t<worktree>\t<fleet_id>`. Foreground pass
    # only (the --bg pass's stdout is silenced, #446). The hub's node reads it.
    --print)       PRINT_WIN=1; shift ;;
    # --reap <policy> (issue #1902): when the fleet may close this session on its
    # own — merged[:<dur>] | done[:<dur>] | loop-end | at:<time> | keep. None =
    # the kind's default, stamped below: done:2h, or loop-end for a /loop seed.
    --reap)        REAP="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --reap=*)      REAP="${1#--reap=}"; shift ;;
    *)             TARGET_SESS="$1"; shift ;;
  esac
done
case "$ORIGIN_WID" in ''|*[!A-Za-z0-9/:._-]*) ORIGIN_WID='' ;; esac
# Trim the seed; a whitespace-only prompt is no prompt (plain scratch).
PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"; PROMPT="${PROMPT%"${PROMPT##*[![:space:]]}"}"
case "$AGENT" in
  ''|claude|codex) : ;;
  *) printf 'dash-raw-session: unknown --agent %s (claude|codex) — using the fleet default\n' "$AGENT" >&2
     tmux display-message "raw: unknown --agent $AGENT — using the fleet default" 2>/dev/null; AGENT="" ;;
esac

BIN="$(cd "$(dirname "$0")" && pwd)"
# The reap policy, canonical or refused before anything opens (issue #1902).
if [ -n "$REAP" ]; then
  REAP=$(python3 "$BIN/fleet_reap_policy.py" norm "$REAP") || exit 2
fi
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
. "$BIN/fleet-ui-lang.sh"   # fleet_ui_fail — the one failure line (issue #1618)

# A machine name is one token (it is embedded in the --bg re-exec and handed to
# the hub); anything else is refused rather than guessed.
case "$NODE_ARG" in *[!A-Za-z0-9._-]*)
  printf 'dash-raw-session: --node %s is not a machine name (auto / local / <name>)\n' "$NODE_ARG" >&2
  fleet_ui_fail "raw: --node $NODE_ARG is not a machine name" "auto / local / <name>"
  exit 1 ;;
esac

SESS="${TARGET_SESS:-$(fleet_current_session)}"
[ -z "$SESS" ] && { printf 'dash-raw-session: no target tmux session\n' >&2; fleet_ui_fail "raw: no target tmux session"; exit 1; }
fleet_load_conf "$SESS"                       # multi-fleet: target THIS fleet's checkout
# Each fleet is its OWN tmux server on a named socket (== session name, issue
# #159). Route EVERY tmux call through TM() so it names the target fleet's socket
# explicitly — correct in-session ($TMUX set) and headless alike.
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }
# A refusal is a stderr line AND a toast (issue #683): a scratch is spawned
# headless too — a script's seeded scratch, dash-enter's guarded --name-file
# path — and a toast is on no screen that caller can read.
# stderr is the record; the status line is the glance. Exit 2 = at capacity
# (retry later), 1 = infrastructure, 4 = no live parent (issue #1355), matching
# dash-issue-session.sh.
refuse() { printf 'dash-raw-session: %s\n' "${1#raw: }" >&2; FLEET_UI_SOCK=$SOCK fleet_ui_fail "$1"; }
# No spawning into ANOTHER fleet (issue #980): a caller sitting in a fleet pane may
# name only its own fleet. A caller outside any fleet (no pane, or an ad-hoc
# session with no fleet conf) is headless and names the fleet it means.
if [ -n "$TARGET_SESS" ] && [ -n "${TMUX:-}" ]; then
  _here=$(fleet_current_session)
  if [ -n "$_here" ] && [ "$_here" != "$TARGET_SESS" ] && [ -f "$(fleet_conf_file "$_here")" ]; then
    printf 'dash-raw-session: refusing to spawn into fleet %s from fleet %s — one fleet per login; pick the repo with --repo\n' "$TARGET_SESS" "$_here" >&2
    fleet_ui_fail "raw: no spawning into another fleet ($TARGET_SESS)" "use --repo"
    exit 1
  fi
  unset _here
fi
# Spawn provenance (issue #503): detect BEFORE the --bg re-exec below — the
# backgrounded pass runs under run-shell -b with no caller pane, so this
# foreground detect is the only chance; the value rides --origin through.
# issue-<N>/scratch-<N> when a worker or scratch spawned us; empty ≡ hub (⌃s,
# the dash PROMPT line). fleet_origin_canon arbitrates it against an explicit
# --origin (a canonical key is honoured as given; a worktree BASENAME folds to its
# key; garbage yields to the detected key). The spawn never crosses fleets (#980,
# refused above), so canon's #516 source-fleet rule has no source to apply here.
# Sanitized inside canon (window option + re-exec embed).
ORIGIN_RAW=$ORIGIN                             # pre-canon: `hub` canonicalizes to empty
_det=$(fleet_origin_key)
ORIGIN=$(fleet_origin_canon "$ORIGIN" "$_det" "$TARGET_SESS" "")
unset _det
# A parent on another machine still needs its KEY as @origin (issue #1541, as
# dash-issue-session.sh does): the child-report path treats an empty @origin as
# hub-spawned and stays silent; with @origin_wid beside it, it routes by worker_id.
if [ -n "$ORIGIN_WID" ] && [ -z "$ORIGIN" ]; then ORIGIN=$(fleet_origin_canon "${ORIGIN_WID#*/}" '' '' ''); fi
# The parent must be a LIVE session (issue #1355, EPIC #1645 C2) — exit 4, as
# dash-issue-session.sh: no $TMUX_PANE and no --origin, or a dead parent key.
_why=$(fleet_origin_gate "$SESS" "$ORIGIN_RAW" "$ORIGIN" "$ORIGIN_WID") \
  || { refuse "raw: $_why"; exit 4; }
unset _why

# Which machine (issue #1541; the issue path's rule, #1425/#1475): --node, else —
# with the hub module on — FLEET_SPAWN_NODE, else auto. PLACING = the hub may
# send this scratch to another machine; decided for good below, after the repo
# is known (a no-repo or seeded scratch never travels).
NODE="$NODE_ARG"
if [ -z "$NODE" ] && [ "${CCQUOTA_FLEET:-0}" = 1 ]; then
  NODE="${FLEET_SPAWN_NODE:-$(fleet_spawn_node_default)}"   # personal machine → local (#1721)
  case "$NODE" in ''|*[!A-Za-z0-9._-]*) NODE=auto ;; esac
fi
PLACING=0
[ -n "$NODE" ] && ! fleet_node_is_self "$NODE" && PLACING=1

# Session cap (issues #28, #70): a raw session is a real Claude session, so it is
# subject to the SAME global + per-fleet ceilings as an issue spawn. Refuse (with a
# human-readable reason) once a cap is reached, rather than quietly overspend.
# Placing (issue #1541): a scratch the hub may send to ANOTHER machine must not be
# stopped by THIS machine's caps — that is exactly when it should go elsewhere —
# so the verdict is held until placement answers, and enforced only if it opens here.
CAP_HELD=''
if ! cap_msg=$(fleet_session_cap_ok "$SESS"); then
  if [ "$PLACING" = 1 ] && [ "${CCQUOTA_FLEET:-0}" = 1 ]; then CAP_HELD=$cap_msg
  else refuse "$cap_msg"; exit 2; fi
fi

# Which repo (issue #789) — see the header. ONE rule, however many repos the fleet
# hosts (issue #1943): --repo, else the selected row's repo, else the fleet's only
# repo; several and none chosen ⇒ a no-repo scratch. The chosen repo's overlay
# replaces what fleet_load_conf resolved (possibly the CALLER window's repo).
if [ "$NOREPO" != 1 ]; then
  if [ -z "$REPO_ARG" ] && [ -n "$SEL" ]; then
    REPO_ARG=$(fleet_selection_repo "$SESS" "$SEL")
    [ "$REPO_ARG" = none ] && { REPO_ARG=''; NOREPO=1; }
  fi
  if [ -z "$REPO_ARG" ] && [ "$NOREPO" != 1 ]; then
    _all=$(fleet_repos "$SESS")
    case "$(printf '%s' "$_all" | grep -c .)" in
      1) REPO_ARG=$_all ;;
      # A fleet with no repo at all (issue #1937): every session is a no-repo one.
      # compat-1v: 下一批删 — a pre-#1937 conf naming only FLEET_MAIN keeps its checkout.
      0) [ -n "${FLEET_MAIN:-}" ] || NOREPO=1 ;;
      *) NOREPO=1 ;;
    esac
    unset _all
  fi
  if [ -n "$REPO_ARG" ]; then
    REPO_ARG=$(fleet_norm_repo "$REPO_ARG")
    fleet_load_repo_conf "$SESS" "$REPO_ARG" \
      || { refuse "raw: $REPO_ARG is not a repo this fleet hosts"; exit 1; }
  fi
fi
[ "$NOREPO" = 1 ] && REPO_ARG=''

MAIN="${FLEET_MAIN:-}"
if [ "$NOREPO" != 1 ]; then
  [ -d "$MAIN/.git" ] || { refuse "raw: FLEET_MAIN is not a git checkout — set it in fleet.conf"; exit 1; }
fi
BASE="${FLEET_BASE_BRANCH:-master}"

# Backgrounded spawn (issues #304, #444): the cheap/authoritative checks above (session
# cap, MAIN) have passed synchronously, so a refusal is immediate and lands on the
# status line. Now hand the SLOW half — `git fetch` + the `git worktree add` retry
# loop + the window launch — to the BACKGROUND so the ⌃s keypress returns INSTANTLY
# instead of freezing the dash on checkout. Re-exec ourselves with no --bg (so the
# bg pass just spawns) and any name staged in a temp file (arbitrary user text —
# NEVER interpolated into the run-shell string). Only --bg backgrounds; a headless
# CLI call falls straight through and spawns in the foreground. The dash pane has
# $TMUX on THIS fleet's server, so bare fleet_bg lands correctly.
#
# The trailing `>/dev/null 2>&1` is REQUIRED, not tidiness (issues #192, #446):
# `run-shell` surfaces a backgrounded job's STDOUT as a view-mode overlay on the
# INVOKING pane — which is now the dash itself, not a popup that closes. One stray
# line (`git worktree add`'s "HEAD is now at …") therefore covered the dash until
# the user pressed Esc. Outcomes are reported via `tmux display-message`, so the
# job has nothing to say on stdout; the redirect keeps it that way for good.
if [ "$BG" = 1 ]; then
  nfarg=""; pfarg=""
  if [ -n "$NAME" ]; then
    nf=$(mktemp "${TMPDIR:-/tmp}/dash-raw.XXXXXX") || { refuse "raw: cannot stage the scratch name"; exit 1; }
    printf '%s' "$NAME" > "$nf"
    nfarg=" --name-file='$nf'"
  fi
  if [ -n "$PROMPT" ]; then
    pf=$(mktemp "${TMPDIR:-/tmp}/dash-raw.XXXXXX") || { refuse "raw: cannot stage the scratch prompt"; exit 1; }
    printf '%s' "$PROMPT" > "$pf"
    pfarg=" --prompt-file='$pf'"
  fi
  # The RESOLVED repo rides along (issue #789), so the bg pass cannot re-resolve
  # the highlighted row the operator moved off in between.
  rarg=''; [ "$NOREPO" = 1 ] && rarg=' --no-repo'; [ -n "$REPO_ARG" ] && rarg=" --repo='$REPO_ARG'"
  pinarg=''; [ "$PIN" = 1 ] && pinarg=' --pin'
  # --node rides along (issue #1541): the placement itself runs in the bg pass, so
  # the keypress returns at once while the hub is asked; the pass must see the
  # same decision whatever its environment. One sanitized token (checked above),
  # as is --origin-wid.
  nodearg=''; [ -n "$NODE" ] && nodearg=" --node=$NODE"
  owarg=''; [ -n "$ORIGIN_WID" ] && owarg=" --origin-wid=$ORIGIN_WID"
  # canonical (checked above): no quote or space can be in it
  [ -n "$REAP" ] && owarg="$owarg --reap=$REAP"
  fleet_bg "FLEET_SPAWN_FOCUS='${FLEET_SPAWN_FOCUS:-0}' bash '$0'$nfarg$pfarg$pinarg$nodearg$owarg --origin='${ORIGIN:-hub}'${AGENT:+ --agent=$AGENT}$rarg${TARGET_SESS:+ '$TARGET_SESS'} >/dev/null 2>&1" \
    || { [ -n "$nfarg" ] && rm -f "$nf"; [ -n "$pfarg" ] && rm -f "$pf"
         refuse "raw: background dispatch failed"; exit 1; }
  exit 0
fi

# --- Which machine opens it (issue #1541, EPIC #1529 R3) ------------------------
# `--node` means for a scratch what it means for an issue session (#1425): `auto`
# / `local` / this machine's name open it here; another machine's name — or
# `auto`, when the hub picks another machine — opens it THERE. The hub's pick_node
# chooses among this person's machines that host the repo (offline, >0.8
# load/core, <1 GiB free or at the per-person cap are out, the rest scored on
# account headroom + load); the chosen machine's node runs this script headless
# (fleet-control-read.sh start … scratch), with this scratch's name and — when a
# worker or scratch spawned us — our worker_id as its parent; nothing opens here
# and we exit 0 with the machine on stderr and the toast. No lease is involved: a
# scratch has no issue, and its scratch-<N> is minted on the machine that opens
# it. REMOTE is waited on (the hub's 30 s) until that machine really opened the
# window or really refused it (#1586): refused ⇒ its reason and the exit a refusal
# here gives (2 full · 1 else); no final state ⇒ exit 1, never a success. A hub
# that cannot be asked, or no machine that can take it, falls back to opening it
# here for `auto` — and refuses for a machine named explicitly. Never placed: a
# no-repo scratch (no repo to place by) and a seeded one (--prompt rides the
# launch argument, here only) — named elsewhere they are refused, under `auto`
# they open here. Hub module off: nothing runs unless --node names another machine.
if [ "$PLACING" = 1 ]; then
  if [ "$NOREPO" = 1 ] || [ -n "$PROMPT" ]; then
    _why='a no-repo scratch'; [ -n "$PROMPT" ] && _why='a seeded scratch (--prompt)'
    if [ "$NODE" != auto ]; then refuse "raw: $_why opens on this machine only — not opening it on $NODE"; exit 1; fi
    PLACING=0
  elif [ "${CCQUOTA_FLEET:-0}" != 1 ]; then
    if [ "$NODE" != auto ]; then refuse "raw: --node $NODE needs the hub (CCQUOTA_FLEET=1) — not opening a scratch elsewhere"; exit 1; fi
    PLACING=0
  fi
  unset _why
fi
if [ "$PLACING" = 1 ]; then
  _pw="$ORIGIN_WID"
  if [ -z "$_pw" ] && _fleet_wid_split "$ORIGIN" >/dev/null 2>&1; then
    _pw=$(fleet_key_wid "$SESS" "$ORIGIN") || _pw=''   # by identity (#1646)
  fi
  _prepo="${REPO_ARG:-$(fleet_norm_repo "${FLEET_REPO:-}")}"
  place_out=$(fleet_hub_place "$SESS" "$_prepo" scratch "$NODE" "$_pw" "$AGENT" '' '' "$NAME" "$REAP"); place_rc=$?
  _pv=${place_out%%$'\t'*}; _why=''; case "$place_out" in *$'\t'*) _why=${place_out#*$'\t'} ;; esac
  case "$place_rc:$_pv" in
    0:REMOTE\ *)
      read -r _ _m _op _st _w <<<"$_pv"
      if [ "$_st" = 'done' ]; then
        printf 'dash-raw-session: scratch → %s 已开窗 %s (hub operation %s) — %s\n' "$_m" "$_w" "$_op" "$_why" >&2
      else
        printf 'dash-raw-session: scratch → %s (hub operation %s, %s) — %s\n' "$_m" "$_op" "$_st" "$_why" >&2
      fi
      exit 0 ;;   # placed: its row on the list is the answer (issue #1618)
    5:DECLINED\ *)
      # That machine's spawn refused it: its reason, its class of exit.
      read -r _ _m _op _x <<<"$_pv"
      refuse "raw: scratch 被 $_m 拒绝 (exit $_x): ${_why:-no reason given}"
      [ "$_x" = 2 ] && exit 2; exit 1 ;;
    6:UNKNOWN\ *)
      read -r _ _m _op <<<"$_pv"
      refuse "raw: scratch 已派到 $_m (hub operation $_op)，但没等到结果 — 未知，不当成功: ${_why:-no final state}"
      exit 1 ;;
    0:LOCAL\ *)
      printf 'dash-raw-session: scratch 开在本机 %s — %s\n' "${_pv#LOCAL }" "$_why" >&2 ;;
    *)
      if [ "$NODE" != auto ]; then
        refuse "raw: scratch 不能开在 $NODE: ${_why:-${_pv:-hub unreachable}}"
        [ "$place_rc" = 4 ] && exit 2; exit 1
      fi
      [ "$place_rc" = 4 ] && printf 'dash-raw-session: 没有机器能接这个 scratch (%s) — 开在本机\n' "$_why" >&2 ;;
  esac
  unset _pw _u _pv _why _prepo
fi
# Opening here after all: this machine's cap verdict, held above, now applies.
if [ -n "$CAP_HELD" ]; then refuse "$CAP_HELD"; exit 2; fi

# In-flight marker (issue #531). Only the FOREGROUND pass reaches here — the --bg
# dispatcher above re-execs + exits, so its instant return holds no slot. From now
# until this spawn's WINDOW exists (and counts via fleet_session_count) the marker
# makes THIS spawn visible to every other spawn's cap check, so a flood — the
# multi-line paste storm, a wedged Enter/⌃s key — can't all pass the cap before any
# of them lands a window (the 2026-09-03 incident: 244 concurrent `worktree add`s,
# global cap 4 bypassed, disk 30→6 GB). Removed on ANY exit (success, a
# worktree-add failure, a lost-cap race). The cap check already ran above, so this
# spawn is never counted against itself.
_inflight="$(fleet_inflight_mark "$SESS")"
trap 'rm -f "$_inflight" 2>/dev/null' EXIT

# Window name (issue #225): an optional --name wins; otherwise the auto
# `scratch-<N>` (N == the worktree suffix, allocated below). A custom name is
# sanitized (trim; strip control chars + `#`, the tmux format char; cap 24 display
# columns — 12 CJK glyphs)
# but its casing/spacing is PRESERVED — it's the user's scratch label, not a kebab
# slug. If it sanitizes to a panel name the dash hides (plan/dash/backlog), or
# empties out, fall back to the auto name with a one-line note (non-blocking: the
# user still gets a window).
note=""
custom=""
if [ -n "$NAME" ]; then
  san=$(printf '%s' "$NAME" \
    | LC_ALL=C tr -d '[:cntrl:]#' \
    | LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  # Cap at 24 DISPLAY columns — not 24 code points, not 24 bytes (issue #534). The
  # dash prompt line hands its text over as this name, so CJK is the everyday case:
  # a CJK glyph is 2 columns (12 glyphs fit), and the old byte-wise `cut -c` under
  # the C locale (the spawn runs under run-shell, whose locale is not ours to
  # assume) split the last glyph in half — a lone lead byte in the status line.
  # fleet_clip_display is wcwidth-aware and locale-independent (the same clip the
  # dash rows use); re-trim, since the clip can land right after a space.
  fleet_clip_display 24 "$san"; san="${clip_out:-}"
  san=$(printf '%s' "$san" | LC_ALL=C sed -e 's/[[:space:]]*$//')
  case "$san" in
    plan|dash|backlog|home) note="'$san' is reserved — named it scratch instead" ;;
    "")                note="name empty after sanitize — named it scratch instead" ;;
    *)                 custom="$san" ;;
  esac
fi

# --- get a scratch window: WARM POOL first, cold spawn otherwise --------------
# With FLEET_SCRATCH_POOL>0 the slow half of a spawn already happened, minutes ago,
# to a window parked in the `<sess>-pool` holding session: worktree built, claude
# booted, and — the part that actually bites — PAST the TUI's input-mount flush,
# the ~1s window in which Claude Code silently discards whatever you type even
# though the `❯` box is already on screen. Claiming one is a `move-window` +
# rename: the pane, its pty and the running claude survive untouched, so the
# window is typeable in the same tick (measured 0.29s vs 7.0s cold).
# An empty claim (pool off, cold, stale, or account-rotated) falls straight
# through to the original cold path below — the pool is never load-bearing.
# A SEEDED scratch (--prompt) never claims: the prompt goes in as the launch
# argument, which only a cold spawn can carry (see the header).
warm=0; win=""; slug=""; wt=""
claimed=""
# One pool per hosted repo (issue #797): the claim names the scratch's repo, so it
# only ever gets a window warmed from THAT repo's worktree. A no-repo scratch never
# claims.
_pool_ok=1; [ "$NOREPO" = 1 ] && _pool_ok=0
_pool_repo=$REPO_ARG
[ "$_pool_ok" = 1 ] && [ -z "$PROMPT" ] && { [ -z "$AGENT" ] || [ "$AGENT" = "${FLEET_AGENT:-claude}" ]; } && claimed=$(bash "$BIN/scratch-pool.sh" claim "$SESS" ${_pool_repo:+--repo "$_pool_repo"} 2>/dev/null | head -1)
if [ -n "$claimed" ]; then
  warm=1
  win=${claimed%%	*}; _rest=${claimed#*	}; slug=${_rest%%	*}; wt=${_rest#*	}
fi

# --- allocate a scratch worktree off the base branch (issue #290) -------------
# The branch `scratch-<N>` + worktree `<repo-parent>/<repo-dir>-scratch-<N>` mirror
# dash-issue-session.sh's mechanics. The allocator lives in fleet-lib.sh
# (fleet_scratch_alloc) because the warm pool allocates identically; `git worktree
# add -b` is itself the serialization point vs concurrent ⌃s presses.
if [ "$NOREPO" = 1 ]; then
  slug=norepo; wt="$HOME"                        # no worktree: the agent runs in $HOME
elif [ "$warm" = 0 ]; then
  alloc=$(fleet_scratch_alloc "$MAIN" "$BASE" "$SESS") || alloc=""
  if [ -n "$alloc" ]; then slug=${alloc%%	*}; wt=${alloc#*	}; fi
  [ -n "$slug" ] || { refuse "raw: could not create a scratch worktree"; exit 1; }
fi

# Distinct, stable-ish window name. Default is the worktree slug `scratch-<N>` so a
# window and its worktree read alike; a custom --name is deduped against THIS
# fleet's live window names (<name>, <name>-2, …). The name is cosmetic — the
# worktree/branch uniqueness is what git/fs guarantee above.
# No repo tag, even with 2+ repos (issue #1023 dropped #793's `tl·` prefix): the
# dash shows the repo, and identity is `@repo`, never the name.
base="${custom:-$slug}"
existing=$(TM list-windows -t "$SESS" -F '#{window_name}' 2>/dev/null)
name="$base"; n=2
while printf '%s\n' "$existing" | grep -qxF "$name"; do name="$base-$n"; n=$((n + 1)); done

# Spawn non-invasive by default (matches dash-issue-session.sh): -d creates the
# window WITHOUT making it current, so a user attached to $SESS is not yanked over.
# The new session surfaces via the dash. Opt into jump-to-it with FLEET_SPAWN_FOCUS=1
# (the prefix bind sets this — a raw spawn from a keypress is an explicit "take me
# there"); a headless spawn (TARGET_SESS set) never steals focus. Route through
# fleet-claude.sh — no seed prompt, so it is a plain `claude` under the active
# subscription account + the fleet's default model (transparent when single-account).
# On a new-window failure, roll back the just-created worktree + branch so a failed
# spawn leaves no orphan (the janitor would otherwise inherit it).
if [ "$warm" = 1 ]; then
  # already spawned + already warm: it only needs this fleet's name on it. @raw /
  # @worktree were stamped when it was warmed; the @pool_* marks were cleared by
  # the claim, so from here on it is indistinguishable from a cold scratch window.
  TM rename-window -t "$win" -- "$name" 2>/dev/null
else
  # A seed prompt rides in a file read AT LAUNCH (`"$(cat …)"`), never inline in the
  # new-window command string — same handoff dash-issue-session.sh uses, so
  # arbitrary user text (quotes, `$`, backticks) can't break or inject into it.
  # Keyed by the scratch slug under this fleet's cache dir; left in place like the
  # worker seed (tiny, and the path is the debug trail for "what did I seed?").
  # `--agent <a>` (issue #547) rides in the command when a caller chose one; the
  # launcher consumes it. Validated to claude|codex above, so bare is safe.
  launch="'$BIN/fleet-session-wrap.sh'${AGENT:+ --agent $AGENT}"
  # The window stamps its own repo identity BEFORE the launcher reads its conf
  # (issue #789 — see fleet_win_stamp_cmd).
  stamp=''; nsid=''
  if [ "$NOREPO" = 1 ]; then
    if [ "${AGENT:-${FLEET_AGENT:-claude}}" = claude ]; then
      nsid=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
      nsid=$(printf '%s' "$nsid" | tr 'A-F' 'a-f' | LC_ALL=C tr -cd '0-9a-f-')
      [ -n "$nsid" ] && launch="$launch --session-id $nsid"
    fi
    stamp=$(fleet_win_stamp_cmd @norepo 1 ${nsid:+@norepo_sid "$nsid"})
  elif [ -n "$REPO_ARG" ]; then
    stamp=$(fleet_win_stamp_cmd @repo "$REPO_ARG" @worktree "$wt")
  fi
  if [ -n "$PROMPT" ]; then
    tf="$(fleet_cache_dir "$(fleet_slug "${REPO_ARG:-${FLEET_REPO:-$SESS}}")")/task_$slug.txt"
    [ "$NOREPO" = 1 ] && tf="$(fleet_cache_dir "$(fleet_slug "$SESS")")/task_norepo-$$.txt"
    printf '%s' "$PROMPT" > "$tf" 2>/dev/null \
      && launch="$launch \"\$(cat '$tf')\""
  fi
  win=$(TM new-window -d -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$wt" "$stamp$launch; exec \$SHELL") \
    || { [ "$NOREPO" = 1 ] || fleet_scratch_free "$MAIN" "$slug" "$wt"
         refuse "raw: new-window failed in $SESS"; exit 1; }
# A session is on its way: wake the idle-gated daemons so the dash is fresh on
# their very next tick, not up to FLEET_DAEMON_IDLE_AFTER later (issue #1077).
[ -f "$BIN/fleet-daemon-lib.sh" ] && ( . "$BIN/fleet-daemon-lib.sh" && fleet_daemon_wake "$BIN/.." ) 2>/dev/null || true
  if [ "$NOREPO" = 1 ]; then
    TM set-window-option -t "$win" @norepo 1 2>/dev/null    # deliberately no repo, no worktree
    [ -n "$nsid" ] && TM set-window-option -t "$win" @norepo_sid "$nsid" 2>/dev/null
  else
    TM set-window-option -t "$win" @raw 1 2>/dev/null        # mark: raw/scratch, NOT issue-bound
    TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null # so ⌃x can resolve+reap the worktree
  fi
fi
# The session's lifelong identity (issue #1646), warm or cold: a pool window was no
# session until this claim. Minted once; restore / migrate / move carry it.
fid=$(fleet_window_fid "$SESS" "$win" "$SOCK" 2>/dev/null) || fid=''
fleet_window_born "$SESS" "$win" "$SOCK" >/dev/null 2>&1 || :   # its place on the list (#1750)
fleet_win_role_stamp "$win" worker "$SOCK"   # what it IS, whatever it is renamed to (#1844)
# Every repo scratch carries its repo (issue #789), warm or cold.
[ -n "$REPO_ARG" ] && TM set-window-option -t "$win" @repo "$REPO_ARG" 2>/dev/null
[ "$PIN" = 1 ] && TM set-window-option -t "$win" @pin 1 2>/dev/null
# When the fleet may close it on its own (issue #1902): the one asked for, else the
# kind's default — a /loop seed until its loop stops, any other scratch once done
# and idle 2 hours. A no-repo session is never closed automatically (#791), so it
# carries only an explicit one.
if [ -z "$REAP" ] && [ "$NOREPO" != 1 ]; then
  case "$PROMPT" in /loop|/loop[[:space:]]*) REAP=loop-end ;; *) REAP=done:2h ;; esac
fi
[ -n "$REAP" ] && TM set-window-option -t "$win" @reap_policy "$REAP" 2>/dev/null
# Spawn provenance (issue #503) — stamped on the WARM path too: a pool window was
# pre-warmed with no requester, so its origin is decided at CLAIM time, here.
[ -n "$ORIGIN" ] && TM set-window-option -t "$win" @origin "$ORIGIN" 2>/dev/null
# The parent's worker_id (#1420): given verbatim when the parent is on another
# machine (a hub-placed start, #1541), else derived from the key; a parent on
# another machine has no generation here (#1538).
if [ -n "$ORIGIN_WID" ]; then TM set-window-option -t "$win" @origin_wid "$ORIGIN_WID" 2>/dev/null
elif [ -n "$ORIGIN" ]; then fleet_stamp_origin_wid "$SESS" "$win" "$ORIGIN" "$SOCK"; fi
[ -n "$ORIGIN" ] && [ -z "$ORIGIN_WID" ] && fleet_stamp_origin_gen "$SESS" "$win" "$ORIGIN" "$SOCK"
# Window handle (issue #566), likewise on BOTH paths: a warm-pool window is parked
# in the holding session with no handle, and only becomes a fleet window here at
# claim time. Best-effort — the dash backfills a window that ends up without one.
fleet_wid_stamp "$win" "$SOCK" >/dev/null 2>&1 || :

# Keep the full name separate from the clipped/deduplicated window title. The
# helper waits for the agent's input to settle, then pastes WITHOUT Enter. Pin a
# pane id now so a later split/focus change cannot redirect the draft elsewhere.
# Explicit --prompt keeps its existing seeded behavior and takes precedence.
if [ -n "${NAME//[[:space:]]/}" ] && [ -z "$PROMPT" ]; then
  df=$(mktemp "${TMPDIR:-/tmp}/scratch-draft.XXXXXX")
  pane=$(TM display-message -p -t "$win" '#{pane_id}' 2>/dev/null)
  if [ -n "$df" ] && [ -n "$pane" ] && printf '%s' "$NAME" > "$df"; then
    TM run-shell -b "python3 '$BIN/scratch-prefill.py' '$SOCK' '$pane' '$df' '$warm' >/dev/null 2>&1 || { rm -f '$df'; tmux -L '$SOCK' display-message 'raw: could not prefill the scratch name' 2>/dev/null; }" 2>/dev/null \
      || { rm -f "$df"; FLEET_UI_SOCK=$SOCK fleet_ui_fail 'raw: could not prefill the scratch name'; }
  else
    [ -n "$df" ] && rm -f "$df"
    FLEET_UI_SOCK=$SOCK fleet_ui_fail 'raw: could not stage the scratch input' 
  fi
fi

# Refill the pool in the background, so the NEXT ⌃s is instant too — but NOT right
# now. Warming costs a whole cold claude boot (node + the fleet's MCP set), and
# firing it at the instant the operator starts typing into the window they just
# claimed is the one moment it hurts: on a box already running several sessions
# that contention pushed the first keystroke's echo from sub-second to tens of
# seconds — reintroducing, from the other end, exactly the stall this removes.
# So the refill waits first — `--delay`, which scratch-pool.sh applies INSIDE the
# pool-enabled gate so that with the pool off this whole line costs nothing.
# run-shell -b because it is slow either way.
TM run-shell -b "bash '$BIN/scratch-pool.sh' ensure '$SESS' --delay >/dev/null 2>&1" 2>/dev/null

# The headless caller's receipt (issue #1541, --print): the window, its name, its
# worktree — what the hub's node reads back as the start's window — and its
# @fleet_id (issue #1873), the address `fleet-worker-stop.sh <sess> fid:<id>` stops
# it by later (a no-repo session has no key). Readers split on the tab and take
# the fields they know, so the 4th column is additive.
[ "$PRINT_WIN" = 1 ] && printf '%s\t%s\t%s\t%s\n' "$win" "$name" "$wt" "$fid"

if [ -z "$TARGET_SESS" ]; then
  # A spawn that worked draws nothing — the new window and its list row are the
  # answer (issue #1618). The one thing still said is a reserved-name fallback:
  # the name typed was NOT used, and the user should learn why.
  [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && TM select-window -t "$win" 2>/dev/null
  # An `if`, not `[ … ] &&`: as the script's last command a false test would make
  # a successful spawn exit 1 — and the sidebar's input line reads that code.
  if [ -n "$note" ]; then FLEET_UI_SOCK=$SOCK fleet_ui_fail "$note"; fi
fi
