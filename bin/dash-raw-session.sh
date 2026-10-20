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
# #4898, and its --desk / --no-desk with it.)
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
# naming, reaping — is the plain scratch. The seed is the launch argument:
# delivering a prompt into a running TUI would mean `send-keys` — the TUI's
# bracketed paste eats the trailing Enter (the same reason inter-agent messaging
# never send-keys), so the only prompt channel that is deterministic is the
# launch argument.
set -uo pipefail

# Args (order-independent): --name <n> / --name=<n> is the optional window name
# and input draft; --prompt <t> / --prompt=<t> is the optional submitted seed;
# --bg backgrounds the slow half of the spawn (the dash ⌃s / typed-↵ path — see
# below); the lone positional is the headless <fleet-session>. --placeholder
# (T652, EPIC T651 C1): the --name is only a blank session's placeholder
# (「新会话」) — never typed into its input; stamped `@title_pending` before the
# agent starts, so its first prompt renames the window (and the record) once
# (set-claude-state.sh's @task_line block).
set_agent() {   # a row of the adapter table (bin/fleet_agent_adapter.py beside this script or its link's target, T620)
  local s=$0 d
  d=$(cd "$(dirname "$s")" && pwd); [ -f "$d/fleet_agent_adapter.py" ] || { [ -L "$s" ] && d=$(cd "$(dirname "$s")" && cd "$(dirname "$(readlink "$s")")" && pwd); }
  python3 "$d/fleet_agent_adapter.py" known "$1" 2>/dev/null \
    || { printf 'dash-raw-session: unknown --agent %s (claude|codex)\n' "$1" >&2; exit 2; }
  [ -z "$AGENT" ] || [ "$AGENT" = "$1" ] || { printf 'dash-raw-session: contradictory --agent values\n' >&2; exit 2; }
  AGENT=$1
}
NAME=""; PROMPT=""; DRAFT=""; TARGET_SESS=""; BG=0; PIN=0; ORIGIN=""; AGENT=""; REPO_ARG=""; NOREPO=0; SEL=""; NODE_ARG=""; ORIGIN_WID=""; PRINT_WIN=0; REAP=""; TEST_ID=0; TASK_REF=""; AS_ARG=""; RESUME_SID=""; SEED_FILE=""; WT_ARG=""; PREV_ID=""; REOPEN_FID=""; ID_TASK=""; ID_PARENT=""; PLACEHOLDER=0; REAP_ORIGIN=""
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
    # validated below so only a known token is embedded in a command string.
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
    # --reap <policy> (issue #1902): when the fleet may close this session on its
    # own — merged[:<dur>] | done[:<dur>] | loop-end | at:<time> | keep. None =
    # the kind's default, stamped below: done:15m, or loop-end for a /loop seed.
    --reap)        REAP="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --reap=*)      REAP="${1#--reap=}"; shift ;;
    # --reap-origin <word> (T694, 回收 B): where it came from, when the spawn
    # knows better than its own facts — decide (waits on a person's call) ·
    # probe (a scheduled job, a drill) · person · dispatched · member · driver ·
    # orchestrator. None = read off the spawn (fleet_reap_origin). It picks the
    # default policy (fleet_reap_policy.py ORIGINS) and is stamped @reap_origin.
    --reap-origin)   REAP_ORIGIN="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --reap-origin=*) REAP_ORIGIN="${1#--reap-origin=}"; shift ;;
    # --test-identity (issue #2505): a session the TEST identity's client placed
    # (`fleet --test-identity`, #1931) — stamped @test_identity 1, named test-…,
    # closed once done 10 minutes unless a --reap says otherwise; the person's
    # list hides it and `fleet ls` marks it.
    --test-identity) TEST_ID=1; shift ;;
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
    # A Claude `--worktree` creation was admitted by the launch proof / the start
    # reservation; both are retired (EPIC T497 C8), and so is the flag.
    --native-worktree) printf 'dash-raw-session: --native-worktree is retired (EPIC T497 C8)\n' >&2; exit 2 ;;
    # --prev <ID> / --fid <ID> (EPIC T497 C4, design §4.4): 「从这一段继续」 opens a
    # NEW ID whose prev is that one; 「恢复这个窗口」 reopens the SAME ID (fleet-id.sh
    # continue / reopen --exec). Both go with --resume.
    --prev)        PREV_ID="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --prev=*)      PREV_ID="${1#--prev=}"; shift ;;
    --fid)         REOPEN_FID="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    # --id-task T<n> / --id-parent <ID> (EPIC T497 C18): what a 「从这一段继续」
    # carries over from the ID it continues — its record (stamped @task, written
    # into the new ID's ledger; never a claim, an admission or @task_flow: the
    # record is the old window's, not a new dispatch) and its parent's ID, so an
    # EPIC driver's successor still owns its batch.
    --id-task)     ID_TASK="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --id-task=*)   ID_TASK="${1#--id-task=}"; shift ;;
    --id-parent)   ID_PARENT="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --id-parent=*) ID_PARENT="${1#--id-parent=}"; shift ;;
    --fid=*)       REOPEN_FID="${1#--fid=}"; shift ;;
    --placeholder) PLACEHOLDER=1; shift ;;
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
case "$PREV_ID" in *[!0-9a-f-]*) PREV_ID='' ;; esac
case "$REOPEN_FID" in *[!0-9a-f-]*) REOPEN_FID='' ;; esac
case "$ID_TASK" in T[1-9]*) case "${ID_TASK#T}" in *[!0-9]*) ID_TASK='' ;; esac ;; *) ID_TASK='' ;; esac
case "$ID_PARENT" in *[!0-9a-f-]*) ID_PARENT='' ;; esac
[ -z "$TASK_REF" ] || ID_TASK=''   # a dispatch's own record wins
# A parked session's return (issue #3387): its seed is the first turn.
if [ -n "$RESUME_SID" ] || [ -n "$SEED_FILE" ] || [ -n "$WT_ARG" ]; then
  [ -z "$NODE_ARG" ] && NODE_ARG=local          # its transcript and worktree are here
  if [ -z "$PROMPT" ] && [ -n "$SEED_FILE" ] && [ -s "$SEED_FILE" ]; then PROMPT=$(cat "$SEED_FILE"); fi
fi
# Trim the seed; a whitespace-only prompt is no prompt (plain scratch).
PROMPT="${PROMPT#"${PROMPT%%[![:space:]]*}"}"; PROMPT="${PROMPT%"${PROMPT##*[![:space:]]}"}"
# An EPIC charter whose FIRST line is the bare `/fleet-epic-run` (every charter
# /fleet-epic-plan wrote before T646): Claude Code reads the head of a first turn
# as a slash command, and a plugin's command is only `/fleet-epic:fleet-epic-run`
# — so the turn ended at 「Unknown command」 without ever reaching the model, and
# the panel filed the new driver under 做完待收. That line becomes the words
# /fleet-epic-plan writes now (FLEET_EPIC_RUN_LINE, plugins/fleet-epic/commands/
# fleet-epic-plan.md §5 — KEEP IN SYNC): plain words, no namespace, Codex alike;
# its arguments ride along. Any other seed: byte for byte.
FLEET_EPIC_RUN_LINE='按 fleet-epic-run 的流程驱动这一批：先调用技能 fleet-epic:fleet-epic-run，本条消息下面是这一批的章程。'
case "$PROMPT" in
  /fleet-epic-run|/fleet-epic-run[[:space:]]*)
    _er_head=${PROMPT%%"
"*}; _er_args=${_er_head#/fleet-epic-run}
    _er_args="${_er_args#"${_er_args%%[![:space:]]*}"}"; _er_args="${_er_args%"${_er_args##*[![:space:]]}"}"
    _er_rest=''; [ "$_er_head" != "$PROMPT" ] && _er_rest=${PROMPT#*"
"}
    PROMPT="$FLEET_EPIC_RUN_LINE${_er_args:+（参数：${_er_args}）}${_er_rest:+
$_er_rest}"
    unset _er_head _er_args _er_rest ;;
esac
# An EPIC member's redo (EPIC T497 C5): the driver's retry words carry
# `<!-- fleet:prev <ID> -->` (fleet-epic-tick.py), the failed baton's ID — this
# window's ledger opens with it as prev, so the member's chain goes on by ID.
if [ -z "$PREV_ID" ] && [ -n "$TASK_REF" ]; then
  case "$PROMPT" in *'fleet:prev '*)
    PREV_ID=$(printf '%s\n' "$PROMPT" | sed -n 's/.*<!-- *fleet:prev \([0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}\) *-->.*/\1/p' | head -n 1) ;;
  esac
fi
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
case "$REAP_ORIGIN" in ''|person|dispatched|member|driver|orchestrator|decide|probe) ;;
  *) printf 'dash-raw-session: --reap-origin takes person|dispatched|member|driver|orchestrator|decide|probe\n' >&2; exit 2 ;;
esac
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
# @placed (issue T672): `hub` when the hub chose this machine, `fallback-local`
# when it could not be asked and the session opened here anyway; the bg pass
# decides it itself.
PLACED=''

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
# what this session's agent can do is asked of its adapter-table row (T620) — never its name
agent_col() { fleet_agent_get "$(fleet_agent_or_default "${AGENT:-${FLEET_AGENT:-}}")" "$1"; }
AS_FOR=$(fleet_agent_or_default "${AGENT:-${FLEET_AGENT:-}}")
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
  # A file shipped with the release is on every machine (issue T672): it travels;
  # a file only here opens here.
  if [ -n "$NODE_ARG" ] && ! fleet_node_is_self "$NODE_ARG" && ! fleet_agent_file_travels "$AS_ARG"; then
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
  [ -n "$REAP_ORIGIN" ] && owarg="$owarg --reap-origin=$REAP_ORIGIN"   # a word, checked above
  [ "$TEST_ID" = 1 ] && owarg="$owarg --test-identity"
  [ "$PLACEHOLDER" = 1 ] && owarg="$owarg --placeholder"
  [ -n "$TASK_REF" ] && owarg="$owarg --task=$TASK_REF"   # T<n>, checked above
  [ -n "$RESUME_SID" ] && owarg="$owarg --resume=$RESUME_SID"   # hex + dashes, checked above
  case "$WT_ARG" in '') ;; *"'"*) refuse "raw: --worktree path has a quote"; exit 1 ;;
    *) owarg="$owarg --worktree='$WT_ARG'" ;; esac
  _dispatch_q=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$DISPATCH") || exit 2
  fleet_bg "FLEET_DISPATCH=$_dispatch_q FLEET_SPAWN_FOCUS='${FLEET_SPAWN_FOCUS:-0}' bash '$0'$nfarg$pfarg$dfarg$pinarg$nodearg$owarg --origin='${ORIGIN:-hub}'${AGENT:+ --agent=$AGENT}${AS_ARG:+ --as=$AS_ARG}$rarg${TARGET_SESS:+ '$TARGET_SESS'} >/dev/null 2>&1" \
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
# A seeded scratch travels (issue T672): its words ride the start as the
# scratch's body — a task's past the hub's 4000 characters cut, the record keeps
# them all. An agent file only this machine has keeps it here.
PLACE_AS=''
if [ "$PLACING" = 1 ] && [ -n "$AS_ARG" ]; then
  if fleet_agent_file_travels "$AS_ARG"; then PLACE_AS=$AS_ARG; else _as_here=1; fi
fi
if [ "$PLACING" = 1 ]; then
  if [ "$NOREPO" = 1 ] || [ -n "$DRAFT" ] || [ -n "${_as_here:-}" ]; then
    _why='a no-repo scratch'
    [ -n "$DRAFT" ] && _why='a draft scratch (--draft)'
    [ -n "${_as_here:-}" ] && _why="a session as $AS_ARG (the agent file is here)"
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
  _body=''
  if [ -n "$PROMPT" ]; then
    _body=$(mktemp "${TMPDIR:-/tmp}/fleet-place-body.XXXXXX") || exit 1
    printf '%s' "$PROMPT" | python3 -c 'import sys
t = sys.stdin.read(); ref = sys.argv[1]
if len(t) > 4000:
    note = "\n\n…（全文见任务记录 %s）" % ref if ref else "\n\n…"
    t = t[:4000 - len(note)].rstrip() + note
sys.stdout.write(t)' "$TASK_REF" > "$_body" || exit 1
  fi
  place_out=$(FLEET_DISPATCH_RESULT="$_dispatch_result" FLEET_DISPATCH="$DISPATCH" FLEET_PLACE_NOT_HERE="$CAP_HELD" \
    FLEET_PLACE_AS="$PLACE_AS" FLEET_PLACE_BODY_FILE="$_body" \
    fleet_hub_place "$SESS" "$_prepo" scratch "$NODE" "$_pw" "$AGENT" '' '' "$NAME" "$REAP"); place_rc=$?
  [ -n "$_body" ] && rm -f "$_body"
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
      refuse "raw: scratch 每台机器都拒绝了: ${_why:-no reason given}"
      [ -n "$CAP_HELD" ] && exit 2; exit 1 ;;
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
      PLACED=hub
      printf 'dash-raw-session: scratch 开在本机 %s — %s\n' "${_pv#LOCAL }" "$_why" >&2 ;;
    *)
      if [ "$NODE" != auto ]; then
        refuse "raw: scratch 不能开在 $NODE: ${_why:-${_pv:-hub unreachable}}"
        [ "$place_rc" = 4 ] && exit 2; exit 1
      fi
      # The hub placed it nowhere and this machine already said no (T672): refused,
      # both reasons named — never opened here past its own gate.
      if [ "$place_rc" = 4 ] && [ -n "$CAP_HELD" ]; then
        refuse "raw: scratch 没有机器能接 — 入口: ${_why:-${_pv:-no reason given}}；本机: $CAP_HELD"; exit 2
      fi
      # Never reached (T672, rc 11): nothing was sent, so opening here can double
      # nothing — this machine's fallback, said and stamped. A send that may have
      # arrived (rc 1, a timeout) is not opened here (#4392).
      _pc=$place_rc; [ "$place_rc" = 11 ] && _pc=10
      python3 "$BIN/fleet_dispatch.py" --accepted "$DISPATCH" --placement-code "$_pc" >/dev/null || exit 1
      [ "$place_rc" = 4 ] && printf 'dash-raw-session: 没有机器能接这个 scratch (%s) — 开在本机\n' "$_why" >&2
      if [ "$place_rc" = 11 ]; then
        PLACED=fallback-local
        [ -n "$CAP_HELD" ] || printf 'dash-raw-session: hub 不可达 — scratch 本机兜底 (@placed fallback-local)\n' >&2
      fi
      unset _pc ;;
  esac
  unset _pw _u _pv _why _prepo _body
fi
unset _as_here
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

# A task's window is admitted by its own ID (EPIC T497 C8): nothing is claimed,
# a --resume with --task is the same session back (its ID's ledger names the
# conversation), and the gate below asks only the person's authority.
[ "$NOREPO" = 1 ] || fleet_repo_authority_guard "${REPO_ARG:-${FLEET_REPO:-}}" --finish "$SESS" >/dev/null \
  || { refuse "$FLEET_AUTHORITY_ERROR"; exit 1; }
win=""; slug=""; wt=""

# --- allocate a scratch worktree off the base branch (issue #290) -------------
# The branch `scratch-<N>` + worktree `<repo-parent>/<repo-dir>-scratch-<N>` mirror
# dash-issue-session.sh's mechanics. The allocator lives in fleet-lib.sh
# (fleet_scratch_alloc); `git worktree add -b` is itself the serialization point
# vs concurrent ⌃s presses.
if [ "$NOREPO" = 1 ]; then
  slug=norepo; wt="$HOME"                        # no worktree: the agent runs in $HOME
elif [ -n "$WT_ARG" ]; then
  # A parked scratch's own kept worktree (issue #3387): reopened, never allocated.
  slug="scratch-${WT_ARG##*-scratch-}"
  case "${slug#scratch-}" in ''|*[!0-9]*) refuse "raw: --worktree $WT_ARG is not a scratch worktree"; exit 1 ;; esac
  [ -d "$WT_ARG" ] && [ -e "$WT_ARG/.git" ] || { refuse "raw: --worktree $WT_ARG is gone"; exit 1; }
  wt=$WT_ARG
else
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

# A task's window goes by the task's own ID (EPIC T644 C2): the hub minted it with
# the record (C1), so the first window opened for it takes that ID, and a redo
# here — the driver's retry, a re-dispatch — is the same ID's next attempt, never a
# new ID with prev. Stamped before the agent starts (its SessionStart hook would
# otherwise mint one). Another machine holding it, or a hub that cannot say ⇒ a
# new ID whose prev is the task's (the old road); a record with no ID ⇒ as before.
TASK_FID=''; TASK_TAKE=''
if [ -n "$TASK_REF" ] && ! fleet_is_fid "$REOPEN_FID"; then
  _tt=$(fleet_task_take "$TASK_REF"); _ttrc=$?
  case "$_ttrc" in
    0) TASK_FID=${_tt%%	*}; TASK_TAKE=${_tt#*	}
       [ "$PREV_ID" = "$TASK_FID" ] && PREV_ID='' ;;   # its own redo: no prev to itself
    2) [ -n "$PREV_ID" ] || PREV_ID=${_tt%%	*} ;;
  esac
  unset _tt _ttrc
fi

# Spawn non-invasive by default (matches dash-issue-session.sh): -d creates the
# window WITHOUT making it current, so a user attached to $SESS is not yanked over.
# The new session surfaces via the dash. Opt into jump-to-it with FLEET_SPAWN_FOCUS=1
# (the prefix bind sets this — a raw spawn from a keypress is an explicit "take me
# there"); a headless spawn (TARGET_SESS set) never steals focus. Route through
# fleet-claude.sh — no seed prompt, so it is a plain `claude` under the active
# subscription account + the fleet's default model (transparent when single-account).
# On a new-window failure, roll back the just-created worktree + branch so a failed
# spawn leaves no orphan (the janitor would otherwise inherit it).
{
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
  # transcript is still where it ran and the agent comes back into its own
  # conversation (the table's park_resume); else a fresh one.
  rsid=''
  if [ -n "$RESUME_SID" ] && [ "$(agent_col park_resume)" = 1 ] \
     && [ -f "$(fleet_transcript_dir "$wt")/$RESUME_SID.jsonl" ]; then
    rsid=$RESUME_SID
  fi
  if [ "$NOREPO" = 1 ]; then
    if [ -n "$rsid" ]; then
      nsid=$rsid; launch="$launch --resume $nsid"
    elif [ -n "$(agent_col preset_sid_flag)" ]; then   # a new conversation under an id we chose
      nsid=$(uuidgen 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
      nsid=$(printf '%s' "$nsid" | tr 'A-F' 'a-f' | LC_ALL=C tr -cd '0-9a-f-')
      [ -n "$nsid" ] && launch="$launch $(agent_col preset_sid_flag) $nsid"
    fi
    stamp=$(fleet_win_stamp_cmd @norepo 1 ${nsid:+@norepo_sid "$nsid"})
  elif [ -n "$REPO_ARG" ]; then
    stamp=$(fleet_win_stamp_cmd @repo "$REPO_ARG" @worktree "$wt")
    # A development task's worktree remembers its record (issue #4897): the
    # reapers ask the record whether the work is over once the window is gone.
    [ -n "$TASK_REF" ] && fleet_worktree_task_mark "$wt" "$TASK_REF"
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
  # A task's record rides on the window before its agent starts (EPIC T497 C8:
  # no claim, no launch binding — the window's ID is the session).
  [ -n "$TASK_REF" ] && stamp="$stamp$(fleet_win_stamp_cmd @task "$TASK_REF")"
  [ -n "$PLACED" ] && stamp="$stamp$(fleet_win_stamp_cmd @placed "$PLACED")"
  # a blank session's placeholder name, renamed by its first prompt (T652)
  [ "$PLACEHOLDER" = 1 ] && [ -n "$NAME" ] && stamp="$stamp$(fleet_win_stamp_cmd @title_pending "$NAME")"
  # C2: the task's ID, and — a redo here — its next attempt opened before the agent
  # starts, so the new window's first segment is that attempt's (`reopened`, which
  # the hub reads too)
  [ -n "$TASK_FID" ] && stamp="$stamp$(fleet_win_stamp_cmd @fleet_id "$TASK_FID")"
  [ "$TASK_TAKE" = here ] && python3 "$BIN/fleet_id.py" attempt "$TASK_FID" >/dev/null 2>&1
  # a 看台's new session is clocked from its ↵ (T684, fleet_timing.py): the window
  # carries it so the agent's start (fleet_id.hook) writes `ready` under that run
  case "${FLEET_TIMING_T0:-}" in
    ''|*[!0-9.]*) : ;;
    *) stamp="$stamp$(fleet_win_stamp_cmd @timing_t0 "$FLEET_TIMING_T0")" ;;
  esac
  win=$(TM new-window -d -P -F '#{window_id}' -t "$SESS:" -n "$name" -c "$wt" "$stamp$launch; exec \$SHELL") \
    || { [ "$NOREPO" = 1 ] || [ -n "$WT_ARG" ] || fleet_scratch_free "$MAIN" "$slug" "$wt"
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
    TM set-window-option -t "$win" @worktree "$wt" 2>/dev/null
  fi
}
# The session's lifelong identity (issue #1646). Minted once; restore / migrate /
# move carry it.
# 「恢复这个窗口」 (EPIC T497 C4): the same ID goes on here — its ledger says
# `reopened`, and the fleet's earlier close is no longer one restore must honour.
if fleet_is_fid "$REOPEN_FID"; then
  TM set-window-option -t "$win" @fleet_id "$REOPEN_FID" 2>/dev/null
  rm -f "$(fleet_retired_dir)/$REOPEN_FID" 2>/dev/null
  python3 "$BIN/fleet_id.py" reopen "$REOPEN_FID" --window "$win" >/dev/null 2>&1 || :
fi
# A task's own ID (EPIC T644 C2, taken above): on the window from its first moment
# (an earlier attempt's close is no longer one restore must honour).
if fleet_is_fid "$TASK_FID"; then
  TM set-window-option -t "$win" @fleet_id "$TASK_FID" 2>/dev/null
  rm -f "$(fleet_retired_dir)/$TASK_FID" 2>/dev/null
fi
fid=$(fleet_window_fid "$SESS" "$win" "$SOCK" 2>/dev/null) || fid=''
# The ID's ledger opens with the spawn (EPIC T497 C1) — agent, repo, what it is for;
# the short code lands as @task_short. Backgrounded: the hook fills a missing `opened`.
# C4: its parent (the spawning session's ID), its prev (the ID it continues — given,
# or the one whose segment --resume picks up) and its worktree ride along.
# The parent is the spawning session's ID however it came (C9): a handed-over
# worker_id, a keyless parent's own ID as --origin (every `task` dispatch from an
# orchestrator / a driver), or the ID of the window its key names.
_idpar=$(fleet_spawn_parent_id "$SESS" "$ORIGIN" "$ORIGIN_WID" "$SOCK") || _idpar=''
[ -n "$_idpar" ] || _idpar=$ID_PARENT   # a continued ID keeps its parent (C18)
_idwt=''; [ -n "${wt:-}" ] && [ "$NOREPO" != 1 ] && _idwt=$wt
fleet_is_fid "$fid" && ( bash "$BIN/fleet-id.sh" open "$fid" --window "$win" --socket "$SOCK" \
  --agent "${AGENT:-claude}" ${REPO_ARG:+--repo "$REPO_ARG"} ${NAME:+--title "$NAME"} \
  ${TASK_REF:+--task "$TASK_REF"} ${ID_TASK:+--task "$ID_TASK"} ${_idpar:+--parent "$_idpar"} ${PREV_ID:+--prev "$PREV_ID"} \
  ${RESUME_SID:+--from-native "$RESUME_SID"} ${_idwt:+--worktree "$_idwt"} >/dev/null 2>&1 & )
# The worktree remembers its ID beside its record (C4): `fleet-id` in its git dir.
[ -n "$_idwt" ] && fleet_is_fid "$fid" && fleet_worktree_id_mark "$_idwt" "$fid"
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
# Every repo scratch carries its repo (issue #789).
[ -n "$REPO_ARG" ] && stamp_option @repo "$REPO_ARG" 2>/dev/null
[ "$PIN" = 1 ] && stamp_option @pin 1 2>/dev/null
# When the fleet may close it on its own (issue #1902): the one asked for, else
# where it came from decides (T694, 回收 B — fleet_reap_policy.py ORIGINS, the one
# table): a person's own (⌘N / ⌘P) idle 2 hours, a dispatched one / a batch
# member / a driver once its work is over, an orchestrator never (and pinned), a
# probe (the TEST identity's, issue #2505) once done; a /loop seed until its loop
# stops. A no-repo session's `idle` counts a finished turn; its `done` waits for
# the agent to EXIT (issue #2565).
[ "$TEST_ID" = 1 ] && stamp_option @test_identity 1 2>/dev/null
stamp_option @dispatch "$DISPATCH" 2>/dev/null
[ -n "$TASK_REF" ] && stamp_option @task "$TASK_REF" 2>/dev/null   # the hub's record (#3325)
[ -n "$ID_TASK" ] && stamp_option @task "$ID_TASK" 2>/dev/null    # a continued ID's record (C18)
[ -n "$REAP_ORIGIN" ] || REAP_ORIGIN=$(fleet_reap_origin "$SOCK" "$AS_ARG" "$ORIGIN" "$ORIGIN_WID" \
  "$TEST_ID" "$_idpar" "${REOPEN_FID:-$PREV_ID}")
if [ -z "$REAP" ]; then
  _rk=scratch; case "$PROMPT" in /loop|/loop[[:space:]]*) _rk=loop ;; esac
  REAP=$(python3 "$BIN/fleet_reap_policy.py" origin-default "${REAP_ORIGIN:-person}" --kind "$_rk") || REAP=done:15m
  unset _rk
fi
[ -n "$REAP" ] && stamp_option @reap_policy "$REAP" 2>/dev/null
[ -n "$REAP_ORIGIN" ] && stamp_option @reap_origin "$REAP_ORIGIN" 2>/dev/null
# A `keep` a SESSION asked for when it dispatched this one lapses once the work is
# over (T694): only a person's keep holds (fleet_reap_policy.effective).
[ "$REAP" = keep ] && case "$REAP_ORIGIN" in dispatched|member) stamp_option @reap_keep_by session 2>/dev/null ;; esac
# An orchestrator is pinned from its first moment (回收 B): never closed on its own.
[ "$REAP_ORIGIN" = orchestrator ] && [ "$PIN" != 1 ] && stamp_option @pin 1 2>/dev/null
# A no-repo session opened with no words (⌘N, a plain `fleet` whose last session is
# gone — issue #4000): its first turn is tracked (`@prompted`, set-claude-state.sh's
# `working`), so one nobody ever typed into is closed after its grace
# (fleet-cleanup-idle.py `empty`) — never one resumed, seeded or given words.
[ "$NOREPO" = 1 ] && [ -z "$PROMPT$RESUME_SID$SEED_FILE" ] && [ "$TEST_ID" = 0 ] \
  && stamp_option @prompt_track 1 2>/dev/null
# Spawn provenance (issue #503).
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
# Window handle (issue #566). Best-effort — the dash backfills a window that ends
# up without one. Last: its lock + scan is the dearest stamp, and nothing the
# launch reads needs it (issue #2352).
fleet_wid_stamp "$win" "$SOCK" >/dev/null 2>&1 || :

# Keep the full name separate from the clipped/deduplicated window title. The
# helper waits for the agent's input to settle, then pastes WITHOUT Enter. Pin a
# pane id now so a later split/focus change cannot redirect the draft elsewhere.
# Explicit --prompt keeps its existing seeded behavior and takes precedence.
INPUT_DRAFT=${DRAFT:-$NAME}
[ "$PLACEHOLDER" = 1 ] && INPUT_DRAFT=$DRAFT   # a placeholder name is never typed in (T652)
if [ -n "${INPUT_DRAFT//[[:space:]]/}" ] && [ -z "$PROMPT" ]; then
  df=$(mktemp "${TMPDIR:-/tmp}/scratch-draft.XXXXXX")
  pane=$(TM display-message -p -t "$win" '#{pane_id}' 2>/dev/null)
  if [ -n "$df" ] && [ -n "$pane" ] && printf '%s' "$INPUT_DRAFT" > "$df"; then
    TM run-shell -b "python3 '$BIN/scratch-prefill.py' '$SOCK' '$pane' '$df' 0 >/dev/null 2>&1 || { rm -f '$df'; tmux -L '$SOCK' display-message 'raw: could not prefill the scratch name' 2>/dev/null; }" 2>/dev/null \
      || { rm -f "$df"; FLEET_UI_SOCK=$SOCK fleet_ui_fail 'raw: could not prefill the scratch name'; }
  else
    [ -n "$df" ] && rm -f "$df"
    FLEET_UI_SOCK=$SOCK fleet_ui_fail 'raw: could not stage the scratch input' 
  fi
fi

# The headless caller's receipt (issue #1541, --print): the window, its name, its
# worktree — what the hub's node reads back as the start's window — and its
# @fleet_id (issue #1873), the address `fleet-worker-stop.sh <sess> fid:<id>` stops
# it by later (a no-repo session has no key). Readers split on the tab and take
# the fields they know, so the 4th column is additive.
if [ "$PRINT_WIN" = 1 ]; then
  printf '%s\t%s\t%s\t%s\n' "$win" "$name" "$wt" "$fid"
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
