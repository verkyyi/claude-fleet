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
#      (Binding a scratch to an issue in place — issue #520 — left
#      with issue #4898.)
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
# A session the hub's task record owns (`--task T<n>`, issue #3325 — the hub's
# start passes it) is stamped `@task T<n>`: the record is its ticket. (The desk
# ticket of #2676 — a GitHub issue filed for a no-code session — left with issue
# #4898; --desk / --no-desk are accepted and do nothing. # compat-1v: 下一批删)
#
# --resume <sid> + --seed-file <f> [+ --worktree <dir>] (issue #3387): a PARKED
# session with no issue coming back (a park's wake; the parker left with #4339) — the scratch
# counterpart of dash-issue-session.sh --resume. The window opens on the same
# conversation (`--resume <sid>`, Claude only, and only while its transcript is
# still in the project dir of where it ran — $HOME for --no-repo, else the
# worktree) and its first turn is the file's text. --worktree reopens it in its
# OWN kept scratch worktree (with --repo; the dir must be a `*-scratch-<N>`
# worktree that still exists) instead of allocating a new one. No transcript ⇒ a
# fresh session seeded with the file. Always cold, always on this machine.
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
set_agent() {
  case "$1" in claude|codex) ;; *) printf 'dash-raw-session: unknown --agent %s (claude|codex)\n' "$1" >&2; exit 2 ;; esac
  [ -z "$AGENT" ] || [ "$AGENT" = "$1" ] || { printf 'dash-raw-session: contradictory --agent values\n' >&2; exit 2; }
  AGENT=$1
}
NAME=""; PROMPT=""; DRAFT=""; TARGET_SESS=""; BG=0; PIN=0; ORIGIN=""; AGENT=""; REPO_ARG=""; NOREPO=0; SEL=""; NODE_ARG=""; ORIGIN_WID=""; PRINT_WIN=0; REAP=""; WARM_ONLY=0; TEST_ID=0; TASK_REF=""; AS_ARG=""; RESUME_SID=""; SEED_FILE=""; WT_ARG=""; NATIVE_WT=0
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
    --draft)       DRAFT="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --draft=*)     DRAFT="${1#--draft=}"; shift ;;
    --draft-file=*) f="${1#--draft-file=}"; DRAFT="$(cat "$f")" || exit 1; rm -f "$f"; shift ;;
    # --prompt-file=<f>: same staging as --name-file — the seed is arbitrary user
    # text and is NEVER interpolated into the run-shell string.
    --prompt-file=*) f="${1#--prompt-file=}"; PROMPT="$(cat "$f" 2>/dev/null)"; rm -f "$f"; shift ;;
    # --agent (issue #547): `claude` | `codex` for THIS scratch, overriding the
    # fleet's FLEET_AGENT. Rides the --bg re-exec and lands in the launcher's argv;
    # validated below so only a known token is embedded in a command string. An
    # explicit agent always takes the COLD path — the warm pool holds windows
    # launched under the fleet default, which may be the other agent.
    --agent)       set_agent "${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --agent=*)     set_agent "${1#--agent=}"; shift ;;
    # --as <name> (issue #3122, EPIC #3111 C11): the standard agent file this
    # session starts as — `claude --agent <name>`, found the way Claude Code finds
    # it (the checkout's .claude/agents > ~/.claude/agents > a plugin); named but
    # not found ⇒ refused, naming where it looked. Its `fleet:` key fills --reap /
    # --repo / --agent when the spawn names none. Opens on THIS machine (the file
    # is here). None = a plain scratch, as before.
    --as)          AS_ARG="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --as=*)        AS_ARG="${1#--as=}"; shift ;;
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
    # --warm-only (issue #2234, EPIC #2230 C4): a window from the warm pool or
    # NOTHING — exit 3 when that (repo | HOME) × agent slot has no ready entry, so
    # the caller takes its own cold path. A seed (--prompt / --prompt-file) is
    # SUBMITTED into the claimed window as its first turn (fleet-pane-submit.sh),
    # never a launch argument; --print adds `<t_window>\t<t_ready>\t<t_prompt>`
    # (epoch ms) after the receipt's four fields. Headless callers only.
    --warm-only)   WARM_ONLY=1; shift ;;
    # --reap <policy> (issue #1902): when the fleet may close this session on its
    # own — merged[:<dur>] | done[:<dur>] | loop-end | at:<time> | keep. None =
    # the kind's default, stamped below: done:15m, or loop-end for a /loop seed.
    --reap)        REAP="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --reap=*)      REAP="${1#--reap=}"; shift ;;
    # --test-identity (issue #2505): a session the TEST identity's client placed
    # (`fleet --test-identity`, #1931) — stamped @test_identity 1, named test-…,
    # closed once done 10 minutes unless a --reap says otherwise; the person's
    # list hides it and `fleet ls` marks it.
    --test-identity) TEST_ID=1; shift ;;
    --desk|--desk=*|--no-desk) shift ;;   # the retired desk ticket (#4898)
    # --task T<n> (issue #3325): the hub's task record this session belongs to —
    # stamped @task (the top bar's number when there is no issue); the record is
    # its ticket.
    --task)        TASK_REF="${2:-}"; shift 2 ;;
    --task=*)      TASK_REF="${1#--task=}"; shift ;;
    # --resume <sid> / --seed-file <f> / --worktree <dir> (issue #3387): see above.
    --resume)      RESUME_SID="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --resume=*)    RESUME_SID="${1#--resume=}"; shift ;;
    --seed-file)   SEED_FILE="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --seed-file=*) SEED_FILE="${1#--seed-file=}"; shift ;;
    --worktree)    WT_ARG="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --worktree=*)  WT_ARG="${1#--worktree=}"; shift ;;
    --native-worktree) NATIVE_WT=1; shift ;;
    *)             TARGET_SESS="$1"; shift ;;
  esac
done
if [ -n "$DRAFT" ] && [ -n "$PROMPT$SEED_FILE$RESUME_SID$TASK_REF$AS_ARG" ]; then
  printf 'dash-raw-session: draft cannot be combined with a seed, resume, task or agent role\n' >&2
  exit 2
fi
case "$ORIGIN_WID" in ''|*[!A-Za-z0-9/:._-]*) ORIGIN_WID='' ;; esac
case "$TASK_REF" in T[1-9]*) case "${TASK_REF#T}" in *[!0-9]*) TASK_REF='' ;; esac ;; *) TASK_REF='' ;; esac
case "$RESUME_SID" in *[!0-9a-fA-F-]*) RESUME_SID='' ;; esac
# A parked session's return (issue #3387): its seed is the first turn.
if [ -n "$RESUME_SID" ] || [ -n "$SEED_FILE" ] || [ -n "$WT_ARG" ]; then
  [ -z "$NODE_ARG" ] && NODE_ARG=local          # its transcript and worktree are here
  if [ -z "$PROMPT" ] && [ -n "$SEED_FILE" ] && [ -s "$SEED_FILE" ]; then PROMPT=$(cat "$SEED_FILE"); fi
fi
# Trim the seed; a whitespace-only prompt is no prompt (plain scratch).
PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"; PROMPT="${PROMPT%"${PROMPT##*[![:space:]]}"}"
case "$AS_ARG" in
  '') ;;
  *[!A-Za-z0-9_.:-]*|[!A-Za-z0-9]*) printf 'dash-raw-session: not an agent name: %s\n' "$AS_ARG" >&2; exit 1 ;;
  *) [ -z "$NODE_ARG" ] && NODE_ARG=local ;;   # the agent file is on this machine
esac
BIN="$(cd "$(dirname "$0")" && pwd)"
EXPLICIT_AGENT=$AGENT
DISPATCH="${FLEET_DISPATCH:-}"
if [ -n "$DISPATCH" ]; then
  DISPATCH=$(python3 "$BIN/fleet_dispatch.py" ${AGENT:+--agent "$AGENT"} --accepted "$DISPATCH") || exit 2
  AGENT=$(printf '%s' "$DISPATCH" | python3 -c 'import json,sys; print(json.load(sys.stdin)["resolved_agent"])')
fi

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
# The onboarding guide — the pinned `guide` window seeded /fleet-onboard — is a
# newcomer's first window: the memory room estimate is waived for it, the floor
# and the kernel's pressure are not (issue #3472, fleet_machine_admit). Only this
# admission sees the flag; nothing the window runs inherits it.
_admit_guide=0
[ "$NAME" = guide ] && [ "$PIN" = 1 ] && [ "$PROMPT" = /fleet-onboard ] && _admit_guide=1
if ! cap_msg=$(FLEET_ADMIT_GUIDE=$_admit_guide fleet_session_cap_ok "$SESS"); then
  if [ "$PLACING" = 1 ] && [ "${CCQUOTA_FLEET:-0}" = 1 ]; then CAP_HELD=$cap_msg
  else refuse "$cap_msg"; exit 2; fi
fi

# Which repo (issue #789) — see the header. ONE rule, however many repos the fleet
# hosts (issue #1943): --repo, else the selected row's repo, else the fleet's only
# repo; several and none chosen ⇒ a no-repo scratch. The chosen repo's overlay
# replaces what fleet_load_conf resolved (possibly the CALLER window's repo).
# A named agent file's `fleet: repo` is the repo when the spawn names none (#3122).
# A start already known to be Codex never asks the Claude CLI for plugins (#4726).
AS_FOR=claude; [ "${AGENT:-${FLEET_AGENT:-claude}}" = codex ] && AS_FOR=codex
if [ "$NOREPO" != 1 ] && [ -z "$REPO_ARG" ] && [ -z "$SEL" ] && [ -n "$AS_ARG" ]; then
  REPO_ARG=$(python3 "$BIN/fleet-agent-def.py" launch "$AS_ARG" --dir "${FLEET_MAIN:-$PWD}" --for "$AS_FOR" 2>/dev/null \
    | awk -F'\t' '$1 == "repo" { print $2; exit }')
fi
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
      0) NOREPO=1 ;;
      *) NOREPO=1 ;;
    esac
    unset _all
  fi
  if [ -n "$REPO_ARG" ]; then
    _registered=$(fleet_target_repo "$SESS" "$REPO_ARG") \
      || { refuse "raw: $REPO_ARG is not a uniquely registered repo this fleet hosts"; exit 1; }
    REPO_ARG=$_registered
    fleet_load_repo_conf "$SESS" "$REPO_ARG" \
      || { refuse "raw: $REPO_ARG is not a repo this fleet hosts"; exit 1; }
  fi
fi
[ "$NOREPO" = 1 ] && REPO_ARG=''

MAIN="${FLEET_MAIN:-}"
# The agent file it starts as (issue #3122), looked for from where it will run.
AS_KV=''; TEMPLATE_AGENT=''
if [ -n "$AS_ARG" ]; then
  _asdir=$HOME; [ "$NOREPO" != 1 ] && [ -n "$MAIN" ] && _asdir=$MAIN
  if [ -n "$NODE_ARG" ] && ! fleet_node_is_self "$NODE_ARG"; then
    refuse "raw: --as $AS_ARG opens on this machine (the agent file is here), not on $NODE_ARG"; exit 1
  fi
  if ! AS_KV=$(python3 "$BIN/fleet-agent-def.py" launch "$AS_ARG" --dir "$_asdir" --for "$AS_FOR" 2>&1); then
    refuse "raw: ${AS_KV##*fleet-agent-def: }"; exit 1
  fi
  unset _asdir
fi
as_kv() { printf '%s\n' "$AS_KV" | awk -F'\t' -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'; }
if [ -n "$AS_KV" ]; then
  if [ -z "$REAP" ] && [ -n "$(as_kv reap)" ]; then
    REAP=$(python3 "$BIN/fleet_reap_policy.py" norm "$(as_kv reap)") \
      || { refuse "raw: $(as_kv file): fleet.reap is not a reap policy"; exit 1; }
  fi
  TEMPLATE_AGENT=$(as_kv agent)
  [ -n "$AGENT" ] || AGENT=$TEMPLATE_AGENT
fi
DISPATCH=$(python3 "$BIN/fleet_dispatch.py" --with-agent ${EXPLICIT_AGENT:+--agent "$EXPLICIT_AGENT"} \
  --template "$TEMPLATE_AGENT" --default "${FLEET_AGENT:-}" --accepted "$DISPATCH") || exit 2
AGENT=${DISPATCH%%$'\n'*}
DISPATCH=${DISPATCH#*$'\n'}

if [ "$NOREPO" != 1 ]; then
  [ -d "$MAIN/.git" ] || { refuse "raw: FLEET_MAIN is not a git checkout — set it in fleet.conf"; exit 1; }
fi
BASE="${FLEET_BASE_BRANCH:-master}"
if [ "$NATIVE_WT" = 1 ]; then
  [ "$NOREPO" = 0 ] && [ -n "$REPO_ARG" ] && [ "${AGENT:-${FLEET_AGENT:-claude}}" = claude ] \
    && [ "$NODE_ARG" = local ] \
    && [ "$WARM_ONLY" = 0 ] && [ -z "$WT_ARG$RESUME_SID" ] \
    || { refuse "raw: native worktree requires a fresh local Claude repository session"; exit 2; }
  [ -z "${FLEET_WORKTREE_SETUP:-}" ] && [ "${FLEET_DEPS_SHARE:-0}" != 1 ] \
    || { refuse "raw: native worktree requires migrating explicit Fleet setup/dependency sharing first"; exit 2; }
  if [ -n "$TASK_REF${FLEET_LAUNCH:-}" ]; then
    [ -n "$TASK_REF" ] && [ -n "${FLEET_LAUNCH:-}" ] \
      && python3 "$BIN/fleet_dispatch.py" --accepted "$DISPATCH" --task "$TASK_REF" --placement-code 0 >/dev/null \
      || { refuse "raw: native worktree requires the accepted task dispatch"; exit 2; }
  else
    { [ "${CCQUOTA_FLEET:-0}" = 1 ] || [ -n "$(fleet_task_authority "$SESS" "${REPO_ARG:-${FLEET_REPO:-}}")" ]; } \
      && [ -z "$PROMPT$SEED_FILE" ] \
      || { refuse "raw: native local creation requires repository admission and an unsubmitted draft"; exit 2; }
  fi
fi
[ "$NOREPO" = 1 ] || fleet_repo_authority_guard "${REPO_ARG:-${FLEET_REPO:-}}" --gate "$SESS" >/dev/null \
  || { refuse "$FLEET_AUTHORITY_ERROR"; exit 1; }

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
  nfarg=""; pfarg=""; dfarg=""
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
  if [ -n "$DRAFT" ]; then
    df=$(mktemp "${TMPDIR:-/tmp}/dash-raw.XXXXXX") || { refuse "raw: cannot stage the scratch draft"; exit 1; }
    printf '%s' "$DRAFT" > "$df"
    dfarg=" --draft-file='$df'"
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
  [ "$TEST_ID" = 1 ] && owarg="$owarg --test-identity"
  [ -n "$TASK_REF" ] && owarg="$owarg --task=$TASK_REF"   # T<n>, checked above
  [ "$NATIVE_WT" = 1 ] && owarg="$owarg --native-worktree"
  [ -n "$RESUME_SID" ] && owarg="$owarg --resume=$RESUME_SID"   # hex + dashes, checked above
  case "$WT_ARG" in '') ;; *"'"*) refuse "raw: --worktree path has a quote"; exit 1 ;;
    *) owarg="$owarg --worktree='$WT_ARG'" ;; esac
  _dispatch_q=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$DISPATCH") || exit 2
  _launch_q=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "${FLEET_LAUNCH:-}") || exit 2
  fleet_bg "FLEET_LAUNCH=$_launch_q FLEET_DISPATCH=$_dispatch_q FLEET_SPAWN_FOCUS='${FLEET_SPAWN_FOCUS:-0}' bash '$0'$nfarg$pfarg$dfarg$pinarg$nodearg$owarg --origin='${ORIGIN:-hub}'${AGENT:+ --agent=$AGENT}${AS_ARG:+ --as=$AS_ARG}$rarg${TARGET_SESS:+ '$TARGET_SESS'} >/dev/null 2>&1" \
    || { [ -n "$nfarg" ] && rm -f "$nf"; [ -n "$pfarg" ] && rm -f "$pf"; [ -n "$dfarg" ] && rm -f "$df"
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
  if [ "$NOREPO" = 1 ] || [ -n "$PROMPT$DRAFT" ]; then
    _why='a no-repo scratch'
    [ -n "$PROMPT" ] && _why='a seeded scratch (--prompt)'
    [ -n "$DRAFT" ] && _why='a draft scratch (--draft)'
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
  python3 "$BIN/fleet_dispatch.py" --accepted "$DISPATCH" --task "$TASK_REF" --placement-code 0 >/dev/null || exit 2
  _dispatch_result=$(mktemp "${TMPDIR:-/tmp}/fleet-dispatch.XXXXXX") || exit 1
  place_out=$(FLEET_DISPATCH_RESULT="$_dispatch_result" FLEET_DISPATCH="$DISPATCH" fleet_hub_place "$SESS" "$_prepo" scratch "$NODE" "$_pw" "$AGENT" '' '' "$NAME" "$REAP"); place_rc=$?
  if [ -s "$_dispatch_result" ]; then
    DISPATCH=$(python3 "$BIN/fleet_dispatch.py" --agent "$AGENT" --accepted "$(cat "$_dispatch_result")") || { rm -f "$_dispatch_result"; exit 2; }
    TASK_REF=$(printf '%s' "$DISPATCH" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("task", ""))')
  fi
  rm -f "$_dispatch_result"

  _pv=${place_out%%$'\t'*}; _why=''; case "$place_out" in *$'\t'*) _why=${place_out#*$'\t'} ;; esac
  # Issue #1610: machines that declined first (the hub tried the next one).
  case "$_why" in *$'\t'after\ *)
    printf 'dash-raw-session: scratch 先被 %s 拒绝，入口已换下一台\n' "$(printf '%s' "${_why##*$'\t'after }" | sed 's/:[^,]*//g; s/,/、/g')" >&2
    _why=${_why%$'\t'after *} ;;
  esac
  case "$place_rc:$_pv" in
    4:REFUSED\ ALL_DECLINED)
      refuse "raw: scratch 每台机器都拒绝了: ${_why:-no reason given}"; exit 1 ;;
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
      python3 "$BIN/fleet_dispatch.py" --accepted "$DISPATCH" --placement-code "$place_rc" >/dev/null || exit 1
      [ "$place_rc" = 4 ] && printf 'dash-raw-session: 没有机器能接这个 scratch (%s) — 开在本机\n' "$_why" >&2 ;;
  esac
  unset _pw _u _pv _why _prepo
fi
# Opening here after all: this machine's cap verdict, held above, now applies.
if [ -n "$CAP_HELD" ]; then refuse "$CAP_HELD"; exit 2; fi
# Opening here: a node the hub typed client runs no session (issue #4886).
if fleet_client_refuse '开会话' --kept 2>/dev/null; then
  refuse "raw: 这台是客户端，任务在托管节点上跑"; exit 1
fi

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
# An accepted task opening HERE (issue #4754): the hub binds only a remote
# start, so a local one claims the task itself and carries the same launch
# binding — refused, never opened unbound. Before --finish, which reads it.
# A parked or closed task session's RETURN (--resume with --task, claude-fleet#4974)
# is the same executor, not a new claim: while the record still names that
# conversation, its own binding is what the window carries (fleet_launch.py
# rebind) — a fresh claim of a running task is refused, and so was the session.
REBIND=''
if [ -n "$TASK_REF" ] && [ -n "$RESUME_SID" ] && [ -z "${FLEET_LAUNCH:-}" ]; then
  REBIND=$(python3 "$BIN/fleet_launch.py" rebind "$TASK_REF" "$RESUME_SID"); _rb=$?
  case "$_rb" in
    0) FLEET_LAUNCH=$(printf '%s' "$REBIND" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["launch"], separators=(",", ":")))') \
         || { refuse "raw: $TASK_REF rebind answer unreadable"; exit 1; }
       export FLEET_LAUNCH ;;
    3|4) REBIND='' ;;   # not this session's / no record here: as before
    *) refuse "raw: $TASK_REF is still this session's but cannot continue now"; exit 1 ;;
  esac
fi
if [ -n "$TASK_REF" ] && [ -z "${FLEET_LAUNCH:-}" ]; then
  _fu=$(fleet_uuid "$SESS" 2>/dev/null) || _fu=''   # none: `local` refuses a tasked dispatch
  FLEET_LAUNCH=$(printf '%s' "$DISPATCH" | python3 "$BIN/fleet_launch.py" local "$_fu") \
    || { refuse "raw: $TASK_REF could not be claimed for a local launch"; exit 1; }
  [ -z "$FLEET_LAUNCH" ] || export FLEET_LAUNCH   # empty: the dispatch carries no task
fi
if [ -n "$TASK_REF" ] && [ -z "$REBIND" ]; then
  printf '%s' "$DISPATCH" | python3 "$BIN/fleet_launch.py" admit || exit 1
fi
[ "$NOREPO" = 1 ] || fleet_repo_authority_guard "${REPO_ARG:-${FLEET_REPO:-}}" --finish "$SESS" >/dev/null \
  || { refuse "$FLEET_AUTHORITY_ERROR"; exit 1; }
warm=0; win=""; slug=""; wt=""
claimed=""
# One pool per hosted repo (issue #797): the claim names the scratch's repo, so it
# only ever gets a window warmed from THAT repo's worktree. A no-repo scratch never
# claims.
_pool_ok=1; { [ "$NOREPO" = 1 ] || [ -n "${FLEET_LAUNCH:-}" ]; } && _pool_ok=0
[ -z "${FLEET_AUTHORITY_START:-}" ] || _pool_ok=0
[ "$NATIVE_WT" = 0 ] || _pool_ok=0
_pool_repo=$REPO_ARG
if [ "$WARM_ONLY" = 1 ]; then
  # A pre-existing native process cannot consume a new admission reservation.
  [ -z "${FLEET_AUTHORITY_START:-}" ] || { refuse "authority reservation requires a cold start"; exit 3; }
  # The node's slot contract (issue #2233): the window id alone, exit 3 = none
  # ready. HOME is `--repo -`. Its worktree (and so its slug) is read off the
  # window: the claim clears @pool_slug. Nothing ready: nothing opened, exit 3.
  win=$(bash "$BIN/scratch-pool.sh" claim "$SESS" --repo "$([ "$NOREPO" = 1 ] && echo - || echo "$REPO_ARG")" \
          --agent "${AGENT:-${FLEET_AGENT:-claude}}" 2>/dev/null | head -1)
  case "$win" in @[0-9]*) ;; *) exit 3 ;; esac
  t_window=$(fleet_now_ms)
  warm=1
  # Read both fields in one round trip, after the claim, preserving empty fields.
  IFS=$'\t' read -r _warm_wt _wa <<EOF
$(TM display-message -p -t "$win" $':#{@worktree}\t:#{@cc_agent}' 2>/dev/null)
EOF
  _warm_wt=${_warm_wt#:}; _wa=${_wa#:}
  if [ "$NOREPO" != 1 ]; then
    wt=$_warm_wt
    slug="scratch-${wt##*-scratch-}"
  fi
  # The agent it runs is the one asked for, or it is not handed out (issue #2403):
  # never another agent standing in — closed, and exit 3, so the caller opens the
  # asked-for agent cold. @cc_agent empty = a Claude (only a Codex stamps it).
  if [ "${_wa:-claude}" != "${AGENT:-${FLEET_AGENT:-claude}}" ]; then
    fleet_win_retire "$win" "$SOCK"
    TM kill-window -t "$win" 2>/dev/null
    [ "$NOREPO" = 1 ] || { [ -n "$wt" ] && fleet_scratch_free "$MAIN" "$slug" "$wt"; }
    printf 'dash-raw-session: the warm window runs %s, not %s — closed it\n' "${_wa:-claude}" "${AGENT:-${FLEET_AGENT:-claude}}" >&2
    exit 3
  fi
else
[ -n "$WT_ARG$RESUME_SID" ] && _pool_ok=0      # a parked session's return is always cold (#3387)
[ "$_pool_ok" = 1 ] && [ -z "$PROMPT" ] && [ -z "$AS_ARG" ] && { [ -z "$AGENT" ] || [ "$AGENT" = "${FLEET_AGENT:-claude}" ]; } && claimed=$(bash "$BIN/scratch-pool.sh" claim "$SESS" ${_pool_repo:+--repo "$_pool_repo"} 2>/dev/null | head -1)
if [ -n "$claimed" ]; then
  warm=1
  win=${claimed%%	*}; _rest=${claimed#*	}; slug=${_rest%%	*}; wt=${_rest#*	}
fi
fi
# A warm window is memory the machine already carries: this spawn's admission
# holds nothing more (issue #2502).
[ "${warm:-0}" = 1 ] && fleet_admit_release

# --- allocate a scratch worktree off the base branch (issue #290) -------------
# The branch `scratch-<N>` + worktree `<repo-parent>/<repo-dir>-scratch-<N>` mirror
# dash-issue-session.sh's mechanics. The allocator lives in fleet-lib.sh
# (fleet_scratch_alloc) because the warm pool allocates identically; `git worktree
# add -b` is itself the serialization point vs concurrent ⌃s presses.
if [ "$NOREPO" = 1 ]; then
  slug=norepo; wt="$HOME"                        # no worktree: the agent runs in $HOME
elif [ -n "$WT_ARG" ]; then
  # A parked scratch's own kept worktree (issue #3387): reopened, never allocated.
  slug="scratch-${WT_ARG##*-scratch-}"
  case "${slug#scratch-}" in ''|*[!0-9]*) refuse "raw: --worktree $WT_ARG is not a scratch worktree"; exit 1 ;; esac
  [ -d "$WT_ARG" ] && [ -e "$WT_ARG/.git" ] || { refuse "raw: --worktree $WT_ARG is gone"; exit 1; }
  wt=$WT_ARG
elif [ "$NATIVE_WT" = 1 ]; then
  fleet_fetch_bounded "$MAIN" "$BASE"
  native_alloc=$(python3 "$BIN/fleet_launch.py" native-worktree "$MAIN" "$BASE") \
    || { refuse "raw: could not prepare native worktree creation"; exit 1; }
  IFS=$'\t' read -r slug wt native_intent <<EOF
$native_alloc
EOF
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
# A no-repo session reads `我的会话` (issue #2359, EPIC #2563 约定 3), never
# `norepo-N`: what it is about is its @task_line, the first sentence, beside it.
[ "$NOREPO" = 1 ] && [ -z "$custom" ] && base='我的会话'
[ "$TEST_ID" = 1 ] && case "$base" in test-*) ;; *) base="test-$base" ;; esac
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
  launch="'$BIN/fleet-session-wrap.sh'${AGENT:+ --agent $AGENT}${AS_ARG:+ --as $AS_ARG}"
  # The window stamps its own repo identity BEFORE the launcher reads its conf
  # (issue #789 — see fleet_win_stamp_cmd).
  stamp=''; nsid=''
  # A parked session's return (issue #3387): the same conversation when its
  # transcript is still where it ran and the agent is Claude; else a fresh one.
  rsid=''
  if [ -n "$RESUME_SID" ] && [ "${AGENT:-${FLEET_AGENT:-claude}}" = claude ] \
     && [ -f "$(fleet_transcript_dir "$wt")/$RESUME_SID.jsonl" ]; then
    rsid=$RESUME_SID
  fi
  if [ "$NOREPO" = 1 ]; then
    if [ -n "$rsid" ]; then
      nsid=$rsid; launch="$launch --resume $nsid"
    elif [ "${AGENT:-${FLEET_AGENT:-claude}}" = claude ]; then
      nsid=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
      nsid=$(printf '%s' "$nsid" | tr 'A-F' 'a-f' | LC_ALL=C tr -cd '0-9a-f-')
      [ -n "$nsid" ] && launch="$launch --session-id $nsid"
    fi
    stamp=$(fleet_win_stamp_cmd @norepo 1 ${nsid:+@norepo_sid "$nsid"})
  elif [ -n "$REPO_ARG" ]; then
    if [ "$NATIVE_WT" = 1 ]; then
      stamp=$(fleet_win_stamp_cmd @repo "$REPO_ARG" @native_worktree "$native_intent")
    else
      stamp=$(fleet_win_stamp_cmd @repo "$REPO_ARG" @worktree "$wt")
      # A development task's worktree remembers its record (issue #4897): the
      # reapers ask the record whether the work is over once the window is gone.
      [ -n "$TASK_REF" ] && fleet_worktree_task_mark "$wt" "$TASK_REF"
    fi
    # A development task (issue #4897, EPIC #4895 批 0): a repo session bound to
    # the hub's record T<n> and no issue. @task_flow — stamped with @task before
    # the agent starts, as dash-issue-session.sh's @seed_words — tells the
    # SessionStart hook (fleet-worker-start-hook.sh) to put the task flow on it:
    # read the record, implement, PR, merge on green, report merged (closes it).
    [ -n "$TASK_REF" ] && stamp="$stamp$(fleet_win_stamp_cmd @task "$TASK_REF" @task_flow 1)"
  fi
  [ "$NOREPO" != 1 ] && [ -n "$rsid" ] && launch="$launch --resume $rsid"
  # A session opened with no agent file binds no issue: it may spawn (issue #4334,
  # @agent_spawn the one switch) — stamped before its launcher mounts the dispatch
  # group; an agent file's own grant is the launcher's (fleet-claude.sh).
  [ -z "$AS_ARG" ] && stamp="$stamp$(fleet_win_stamp_cmd @agent_spawn 1)"
  if [ -n "$PROMPT" ]; then
    tf="$(fleet_cache_dir "$(fleet_slug "${REPO_ARG:-${FLEET_REPO:-$SESS}}")")/task_$slug.txt"
    [ "$NOREPO" = 1 ] && tf="$(fleet_cache_dir "$(fleet_slug "$SESS")")/task_norepo-$$.txt"
    printf '%s' "$PROMPT" > "$tf" 2>/dev/null \
      && launch="$launch \"\$(cat '$tf')\""
  fi
  if [ -n "$REBIND" ] && [ -n "$rsid" ]; then
    # the record's own binding (#4974): resumed as that executor, no seed redelivered
    stamp="$stamp$(fleet_task_rebind_stamps "$REBIND")" || { refuse "raw: $TASK_REF rebind answer unreadable"; exit 1; }
  elif [ -n "$REBIND" ]; then
    refuse "raw: $TASK_REF's transcript ${RESUME_SID%%-*}… is not in $wt — not reopened"; exit 1
  elif [ -n "${FLEET_LAUNCH:-}" ]; then
    _launch_fid=$(python3 -c 'import json,os; print(json.loads(os.environ["FLEET_LAUNCH"])["worker_id"].split("/")[1])') || exit 1
    stamp="$stamp$(fleet_win_stamp_cmd @launch "$FLEET_LAUNCH" @launch_seed "${tf:-}" @fleet_id "$_launch_fid" @dispatch "$DISPATCH")"
  fi
  [ -z "${FLEET_AUTHORITY_START:-}" ] || launch="FLEET_AUTHORITY_START='$(printf '%s' "$FLEET_AUTHORITY_START" | sed "s/'/'\\\\''/g")' $launch"
  launch_dir=$wt; [ "$NATIVE_WT" = 0 ] || launch_dir=$MAIN
  win=$(TM new-window -d -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$launch_dir" "$stamp$launch; exec \$SHELL") \
    || { [ "$NOREPO" = 1 ] || [ -n "$WT_ARG" ] || [ "$NATIVE_WT" = 1 ] || fleet_scratch_free "$MAIN" "$slug" "$wt"
         # Say WHY when it is the server (issue #2477): the line rides into
         # the hub's DECLINED / UNKNOWN answer as the refusal.
         _why=''; _down=$(fleet_server_down "$SESS") && _why=" — $_down"
         refuse "raw: new-window failed in $SESS$_why"; exit 1; }
fleet_admit_confirm >/dev/null   # the window is open: its admission holds on its own (#2502)
# A session is on its way: wake the idle-gated daemons so the dash is fresh on
# their very next tick, not up to FLEET_DAEMON_IDLE_AFTER later (issue #1077).
[ -f "$BIN/fleet-daemon-lib.sh" ] && ( . "$BIN/fleet-daemon-lib.sh" && fleet_daemon_wake "$BIN/.." ) 2>/dev/null || true
  # the agent asked for, on the window before anyone reads it back (issue #2403):
  # the node's start checks the session it opened runs it — the launcher's own
  # stamp (fleet-codex.sh / fleet-claude.sh) comes later, from inside the pane.
  # Always the resolved one, Claude too (T493): a list never guesses from blank.
  TM set-window-option -t "$win" @cc_agent "${AGENT:-${FLEET_AGENT:-claude}}" 2>/dev/null
  if [ "$NOREPO" = 1 ]; then
    TM set-window-option -t "$win" @norepo 1 2>/dev/null    # deliberately no repo, no worktree
    [ -n "$nsid" ] && TM set-window-option -t "$win" @norepo_sid "$nsid" 2>/dev/null
  else
    TM set-window-option -t "$win" @raw 1 2>/dev/null        # mark: raw/scratch, NOT issue-bound
    [ "$NATIVE_WT" = 1 ] || TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null
  fi
fi
# The session's lifelong identity (issue #1646), warm or cold: a pool window was no
# session until this claim. Minted once; restore / migrate / move carry it.
[ -z "${_launch_fid:-}" ] || TM set-window-option -t "$win" @fleet_id "$_launch_fid" 2>/dev/null
fid=$(fleet_window_fid "$SESS" "$win" "$SOCK" 2>/dev/null) || fid=''
fleet_window_born "$SESS" "$win" "$SOCK" >/dev/null 2>&1 || :   # its place on the list (#1750)
fleet_win_role_stamp "$win" worker "$SOCK"   # what it IS, whatever it is renamed to (#1844)
# The agent file it starts as, before its agent starts (fleet-claude.sh stamps it
# again off the file it launched): whether that file grants `spawn` is recorded
# (issue #3122), never a gate — every session may spawn (issues #4591, #4703).
# All of these stamps precede input delivery. Send one argv command list; values
# stay arguments (including dispatch JSON), never shell/tmux source text.
window_stamps=()
stamp_option() {
  [ "${#window_stamps[@]}" = 0 ] || window_stamps+=(\;)
  window_stamps+=(set-window-option -t "$win" "$@")
}
[ -n "$AS_KV" ] && { stamp_option @agent_def "$AS_ARG"
  stamp_option @agent_def_sha "$(as_kv sha)"
  stamp_option @agent_spawn "$(as_kv spawn)"; }
[ -z "$AS_KV" ] && stamp_option @agent_spawn 1   # no agent file, no issue: may spawn (#4334)
# Every repo scratch carries its repo (issue #789), warm or cold.
[ -n "$REPO_ARG" ] && stamp_option @repo "$REPO_ARG" 2>/dev/null
[ "$PIN" = 1 ] && stamp_option @pin 1 2>/dev/null
# When the fleet may close it on its own (issue #1902): the one asked for, else the
# kind's default — a /loop seed until its loop stops, any other scratch once done
# and idle 15 minutes (issue #3352; 2 hours before). A no-repo (home) session takes `done:15m` too (issue #2565) —
# fleet-cleanup-idle.py reads it for such a session as "15 minutes after its agent
# EXITED": a turn that merely ended is the session waiting for you, not over.
[ "$TEST_ID" = 1 ] && { stamp_option @test_identity 1 2>/dev/null; [ -n "$REAP" ] || REAP=done:10m; }
stamp_option @dispatch "$DISPATCH" 2>/dev/null
[ -n "$TASK_REF" ] && stamp_option @task "$TASK_REF" 2>/dev/null   # the hub's record (#3325)
if [ -z "$REAP" ]; then
  case "$PROMPT" in /loop|/loop[[:space:]]*) REAP=loop-end ;; *) REAP=done:15m ;; esac
fi
[ -n "$REAP" ] && stamp_option @reap_policy "$REAP" 2>/dev/null
# A no-repo session opened with no words (⌘N, a plain `fleet` whose last session is
# gone — issue #4000): its first turn is tracked (`@prompted`, set-claude-state.sh's
# `working`), so one nobody ever typed into is closed after its grace
# (fleet-cleanup-idle.py `empty`) — never one resumed, seeded or given words.
[ "$NOREPO" = 1 ] && [ -z "$PROMPT$RESUME_SID$SEED_FILE" ] && [ "$TEST_ID" = 0 ] \
  && stamp_option @prompt_track 1 2>/dev/null
# Spawn provenance (issue #503) — stamped on the WARM path too: a pool window was
# pre-warmed with no requester, so its origin is decided at CLAIM time, here.
[ -n "$ORIGIN" ] && stamp_option @origin "$ORIGIN" 2>/dev/null
TM ${window_stamps[@]+"${window_stamps[@]}"} 2>/dev/null
unset window_stamps
unset -f stamp_option
# Attach only after the task and provenance stamps are visible to the reader.
[ -n "$TASK_REF" ] && [ -n "$ORIGIN" ] && [ "$ORIGIN" != hub ] \
  && ( bash "$BIN/fleet-task-record.sh" attach "$TASK_REF" "$win" >/dev/null 2>&1 & )
# The parent's worker_id (#1420): given verbatim when the parent is on another
# machine (a hub-placed start, #1541), else derived from the key; a parent on
# another machine has no generation here (#1538).
if [ -n "$ORIGIN_WID" ]; then TM set-window-option -t "$win" @origin_wid "$ORIGIN_WID" 2>/dev/null
  # the parent's identity, when the worker_id carries one (issue #3439)
  fleet_is_fid "${ORIGIN_WID#*/}" && TM set-window-option -t "$win" @origin_fid "${ORIGIN_WID#*/}" 2>/dev/null
elif [ -n "$ORIGIN" ]; then fleet_stamp_origin_wid "$SESS" "$win" "$ORIGIN" "$SOCK"; fi
[ -n "$ORIGIN" ] && [ -z "$ORIGIN_WID" ] && fleet_stamp_origin_gen "$SESS" "$win" "$ORIGIN" "$SOCK"
# --warm-only's seed (issue #2234): the claimed window is an agent at rest past its
# input-mount flush, so the seed goes in as its FIRST TURN — paste + a separate
# Enter, only once its input is seen empty (fleet-pane-submit.sh). One that never
# shows an idle, empty input is broken: it is closed (the pool's own close) and
# nothing is left open — exit 3, the caller's cold path carries the seed instead.
t_ready=''; t_prompt=''
if [ "$WARM_ONLY" = 1 ] && [ -n "$PROMPT" ]; then
  sf=$(mktemp "${TMPDIR:-/tmp}/dash-raw-seed.XXXXXX") || sf=''
  if [ -n "$sf" ] && printf '%s' "$PROMPT" > "$sf"; then
    stamps=$(bash "$BIN/fleet-pane-submit.sh" "$SOCK" "$win" "$sf"); src=$?
  else
    stamps=''; src=3
  fi
  [ -n "$sf" ] && rm -f "$sf"
  if [ "$src" = 3 ] || [ "$src" = 1 ] || [ "$src" = 2 ]; then
    fleet_win_retire "$win" "$SOCK"
    TM kill-window -t "$win" 2>/dev/null
    [ "$NOREPO" = 1 ] || { [ -n "$slug" ] && [ -n "$wt" ] && fleet_scratch_free "$MAIN" "$slug" "$wt"; }
    printf 'dash-raw-session: the warm window would not take the first turn — closed it\n' >&2
    exit 3
  fi
  t_ready=${stamps%%	*}; t_prompt=${stamps#*	}
  [ "$src" = 0 ] || t_prompt=${t_prompt:-$(fleet_now_ms)}
  # exit 4 (issue #2430): the seed is in the window, its turn never seen to start
  # after four Enters — said, never passed off as a clean start
  [ "$src" = 4 ] && printf 'dash-raw-session: the seed is in %s but its first turn was not seen to start\n' "$win" >&2
fi

# Window handle (issue #566), likewise on BOTH paths: a warm-pool window is parked
# in the holding session with no handle, and only becomes a fleet window here at
# claim time. Best-effort — the dash backfills a window that ends up without one.
# After the first turn, not before: its lock + scan is the dearest stamp, and
# nothing the turn starts reads it (发出即开 ≤1 s, issue #2352).
fleet_wid_stamp "$win" "$SOCK" >/dev/null 2>&1 || :

# Keep the full name separate from the clipped/deduplicated window title. The
# helper waits for the agent's input to settle, then pastes WITHOUT Enter. Pin a
# pane id now so a later split/focus change cannot redirect the draft elsewhere.
# Explicit --prompt keeps its existing seeded behavior and takes precedence.
INPUT_DRAFT=${DRAFT:-$NAME}
if [ -n "${INPUT_DRAFT//[[:space:]]/}" ] && [ -z "$PROMPT" ]; then
  df=$(mktemp "${TMPDIR:-/tmp}/scratch-draft.XXXXXX")
  pane=$(TM display-message -p -t "$win" '#{pane_id}' 2>/dev/null)
  if [ -n "$df" ] && [ -n "$pane" ] && printf '%s' "$INPUT_DRAFT" > "$df"; then
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
[ "$NATIVE_WT" = 1 ] || TM run-shell -b "bash '$BIN/scratch-pool.sh' ensure '$SESS' --delay >/dev/null 2>&1" 2>/dev/null

# The headless caller's receipt (issue #1541, --print): the window, its name, its
# worktree — what the hub's node reads back as the start's window — and its
# @fleet_id (issue #1873), the address `fleet-worker-stop.sh <sess> fid:<id>` stops
# it by later (a no-repo session has no key). Readers split on the tab and take
# the fields they know, so the 4th column is additive.
if [ "$PRINT_WIN" = 1 ]; then
  if [ "$WARM_ONLY" = 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$win" "$name" "$wt" "$fid" "$t_window" "$t_ready" "$t_prompt"
  else
    printf '%s\t%s\t%s\t%s\n' "$win" "$name" "$wt" "$fid"
  fi
fi

if [ -z "$TARGET_SESS" ]; then
  # A spawn that worked draws nothing — the new window and its list row are the
  # answer (issue #1618). The one thing still said is a reserved-name fallback:
  # the name typed was NOT used, and the user should learn why.
  [ "${FLEET_SPAWN_FOCUS:-0}" = 1 ] && TM select-window -t "$win" 2>/dev/null
  # An `if`, not `[ … ] &&`: as the script's last command a false test would make
  # a successful spawn exit 1 — and the sidebar's input line reads that code.
  if [ -n "$note" ]; then FLEET_UI_SOCK=$SOCK fleet_ui_fail "$note"; fi
fi
