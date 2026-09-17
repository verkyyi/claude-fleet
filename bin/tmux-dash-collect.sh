#!/bin/bash
# tmux-dash-collect.sh — background collector for the dash. Owns ALL the slow /
# external status work and writes it to cache files; the dash producer only READS
# these, so the dashboard renders instantly. Run from launchd
# (com.claude-fleet.collect, StartInterval 60s) or a systemd user timer.
# PR status (prmap_<slug>, the flat prmap mirror, and @prci/@pfg) is NOT written
# here — it lives in bin/tmux-pr-refresh.sh, which owns it on a faster ~15s tick
# (see #81). The collector still WRITES sessmap and git_<key>, which that
# refresher reads; the two never write the same cache file.
# Writes under $C = $TMPDIR/.claude-dash, one directory per fleet (issue #181):
#   global/sessmap        — session<TAB>slug<TAB>repo  (one row per live tmux session)
#   fleets/<slug>/issues  — milestone<TAB>#num<TAB>assignee<TAB>title per repo (gh, ≥90s)
#   fleets/<slug>/labels  — #num<TAB>comma-joined-labels per repo, split from the SAME
#                           issues fetch (no extra gh call). Read by the dash's
#                           priority sort (bin/dash-issue-priority.sh)
#   fleets/<slug>/parents — child<TAB>parent per repo for sub-issues (issue #335), from
#                           a small separate GraphQL pass (parent isn't in `gh issue
#                           list --json`). Lets the backlog nest a child under its parent
#   global/git_<key>      — branch<TAB>  per live worktree (budgeted, round-robin —
#                           issue #552). Keyed by a globally-unique worktree path, so it
#                           lives in global/ (not per-fleet) — the reader resolves it
#                           without a slug lookup. Field 2 was a dirty star no reader
#                           ever consumed and is now always empty; see the git phase
#                           below for why `git status` is gone
#   global/collect.git.cursor — the worktree the git phase CLAIMED last; the next tick
#                           resumes after it, so one wedged worktree can't starve the rest
#   global/collect.repoqueue — repo<TAB>slug the sessmap phase resolved, read by the
#                           issues phase. On disk, not in a shell array, because each
#                           phase now runs inside fleet_timebox's subshell and the
#                           phase rotation can reach `issues` in a tick that skipped
#                           `sessmap` (issue #653)
#   global/collect.phase.cursor — the phase the last tick was TRUNCATED at (whole-tick
#                           budget); the next tick starts there and wraps round, so a
#                           truncated phase waits one round instead of starving. Absent
#                           ⇒ the last tick completed and this one starts at the top
#   global/ctx_<key>      — model<TAB>context-tokens per worktree (every run)
#   global/usage          — token-consumption proxy 5h/7d       (≥300s)
#   global/usage.filecache— per-file raw token sums keyed by (mtime,size) — memoizes
#                           the usage scan so unchanged transcripts aren't re-read
#   global/ratelimit      — last-seen official weekly-% line + epoch (scrape, every run)
#   global/collect.pid    — "pid<TAB>start-epoch" of the running tick (overlap guard, #551)
#   global/collect.heartbeat — key=value: pid/start/phase/phase_ts/phases/over/skipped/
#                           end/dur — the tick's progress + per-phase seconds (last
#                           complete tick), so a slow or wedged phase is visible in one
#                           look (#551). over= names the phases that spent their own
#                           budget and skipped= the ones the whole-tick budget deferred
#                           (#653); fleet-doctor.sh prints both with the slowest phase
# The ccquota PRE-EMPTIVE rotation (issue #513) is NOT a block of this tick any more
# (issue #551): it lives in bin/fleet-quotawatch.sh, its own 60s daemon
# (com.claude-fleet.quotawatch), and is ALSO run first thing below — before any gh
# work — so its cadence never rides this tick's gh latency.
#
# Overlap guard (#551): ONE tick at a time. launchd/systemd never overlap a
# StartInterval job themselves, but a tick can be started by hand / by fleet-up
# while one runs; and a tick wedged on an un-timeboxed `gh` blocked every later
# phase (git/ctx/usage — and, pre-#551, the quota watch) for hours. So: a live
# previous tick younger than FLEET_COLLECT_DEADLINE (600s) ⇒ this one skips; older
# ⇒ it is killed (whole process tree) and superseded.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# --- scheduling heartbeat (issue #639) ---------------------------------------
# collect.heartbeat below already proves PROGRESS (phase_ts advances at every
# phase boundary, so a long tick keeps saying it is alive). This stamp proves
# SCHEDULING, which is a different question and the one #639 is about: a tick
# that skips because a younger one holds collect.pid, or bails before its first
# phase, writes no heartbeat at all — yet launchd did spawn it. Stamped before
# every early exit so the two signals can only ever agree upward.
# The source is GUARDED and the stamp is a side errand: liveness instrumentation
# must never be able to kill the daemon it instruments. A half-synced install
# missing the lib then costs this unit its alarm (it reads `never`, which is
# silent by design) instead of costing the fleet the daemon.
# shellcheck source=/dev/null
[ -f "$BIN/fleet-daemon-lib.sh" ] && { . "$BIN/fleet-daemon-lib.sh"
  fleet_daemon_stamp_tick collect "$BIN/.."; }

. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"     # fleet_limit_banner (pure lib, no dispatch)
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
# Per-fleet cache layout (issue #181): slug-keyed fetches live under fleets/<slug>/
# and machine-wide caches under global/. G is the global bucket.
G="$C/global"; mkdir -p "$G"
# Sweep this run's PID-unique temps on exit (across the global/ + fleets/<slug>/
# subdirs now): the per-repo gh fetches only `mv` their temp on success, so a failed
# fetch would otherwise orphan a 0-byte issues.<pid> (and sessmap.<pid>) forever.
trap 'find "$C" -maxdepth 3 -name "*.'"$$"'" -delete 2>/dev/null || true; [ "$(cut -f1 "$G/collect.pid" 2>/dev/null)" = "$$" ] && rm -f "$G/collect.pid"' EXIT
trap 'exit 143' INT TERM   # a supersede's SIGTERM still runs the EXIT trap (temp sweep)
REPO="${FLEET_REPO:-}"
BASE="${FLEET_BASE_BRANCH:-main}"
now() { date +%s; }
# ASCII unit separator: the field delimiter for the multi-field `tmux list-windows`
# formats below (a window name can contain anything a tab or colon could, so the
# separator has to be a byte no name carries). Defined HERE, in the head, because
# both the banner and escalate phases read it and the phase rotation (issue #653)
# does not guarantee which of them runs first.
US=$'\x1f'

# utf8_scrub — DROP invalid-UTF-8 byte sequences from stdin (issue #382). A stray
# non-UTF-8 byte in an issue title/milestone (surfaced in the monorepo fleet) makes
# byte-validating ops (cut/sort) abort with "Illegal byte sequence" — both in this
# collector's OWN cut below and in every downstream reader (backlog + dash). Scrub
# the gh fetch here, at the single source, so the issues/labels caches carry clean
# UTF-8 and no consumer ever sees the bad byte. `iconv -c` drops only invalid
# sequences (ASCII tabs/newlines + valid multibyte pass through, so the column/line
# structure is preserved). Fail-open: no iconv ⇒ pass through untouched — the
# reader's LC_ALL=C byte-shuffle ops still tolerate the raw bytes (defense in depth).
if command -v iconv >/dev/null 2>&1; then
  utf8_scrub() { iconv -c -f UTF-8 -t UTF-8; }
else
  utf8_scrub() { cat; }
fi

# Targeted mode (issue #315): `--issues <owner/repo>` refreshes JUST that repo's
# issues/labels cache NOW and exits (the webhook handler's instant kick,
# bin/fleet-webhook.sh), skipping the git/ctx/usage/snapshot work of a full 60s
# tick. The collector stays the SINGLE writer of issues_<slug>. Normal (no-arg)
# invocation is byte-for-byte unchanged.
TARGET_ISSUES_REPO=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issues) TARGET_ISSUES_REPO="${2:-}"; shift ;;
    -*)       printf 'tmux-dash-collect: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)        printf 'tmux-dash-collect: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# atomic_write DEST — stream stdin to a PID-unique temp, then rename into place.
# rename(2) is atomic on one filesystem, so a concurrent reader (the dash) always
# sees either the old file or the complete new one, never a half-written cache.
# The EXIT trap above sweeps any <name>.$$ temp orphaned by a crash mid-write.
atomic_write() {
  local dest="$1" tmp="$1.$$"
  cat > "$tmp" && mv "$tmp" "$dest"
}

# cache_key PATH — filesystem-safe, collision-FREE cache key for a worktree path.
# Reversibly escapes the escape char first, then '/' and ' ' to DISTINCT tokens,
# so no two distinct paths ever map to the same git_/ctx_ cache (the old
# tr '/ ' '__' collided '/a b' with '/a/b'). MUST stay byte-identical to the
# reader in bin/tmux-dashboard-rows.sh and the Python encoder further below.
cache_key() {
  local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"
}

# fetch_issues_for REPO SLUG [FORCE] — the SINGLE issues/labels fetch, shared by the
# per-repo TTL-gated loop below AND the targeted `--issues <repo>` webhook kick
# (issue #315) so the two can never drift on the jq/column contract. FORCE=1
# bypasses the TTL (the kick wants it NOW); else it fetches only when the cache is
# older than GH_TTL. No-op (return) when gh is missing.
#
# ONE fetch, TWO caches. The gh --jq emits a 5-column raw line whose LEADING column
# is the comma-joined labels, FOLLOWED by the historical 4 (milestone, #num,
# assignee, title). Putting the extra column FIRST keeps the title LAST, so a tab
# inside an issue title is absorbed into the title field (harmless) instead of
# shifting the label column and dropping the issue. We then derive:
#   issues_<slug>  — the 4-column backlog (milestone, #num, assignee, title), keeping
#                    its contract EXACTLY (readers `cut`/`read` fields 1-4).
#   labels_<slug>  — #num<TAB>labels for EVERY open issue, read by the dash's
#                    priority sort (bin/dash-issue-priority.sh).
# Deriving both from one fetch keeps the labels cache zero-extra-token. The raw temp
# is <name>.$$, so the EXIT trap sweeps it if we die mid-split.
fetch_issues_for() {
  local rp="$1" sg="$2" force="${3:-0}" FD its raw ttl owner name
  command -v gh >/dev/null 2>&1 || return 0
  ttl="${GH_TTL:-${FLEET_GH_TTL:-90}}"
  FD=$(fleet_cache_dir "$sg")          # fleets/<slug>/ (issue #181)
  its=$(cat "$FD/issues.ts" 2>/dev/null || echo 0)
  if [ "$force" = 1 ] || [ $(( $(now) - its )) -ge "$ttl" ]; then
    raw="$FD/issuesx.$$"
    if gh issue list --repo "$rp" --state open --limit 300 \
      --json number,title,milestone,assignees,labels \
      --jq '.[] | (.labels|map(.name)) as $l | ($l|join(","))+"\t"+(.milestone.title // "· no milestone")+"\t#"+(.number|tostring)+"\t"+((((.assignees|map(.login)|join(","))[0:10]) | if .=="" then "·" else . end))+"\t"+(.title)' \
      2>/dev/null | utf8_scrub > "$raw"; then
      cut -f2-5 "$raw" > "$FD/issues.$$" \
        && mv "$FD/issues.$$" "$FD/issues"
      awk -F'\t' '{n=$3; sub(/^#/,"",n); print n"\t"$1}' "$raw" > "$FD/labels.$$" \
        && mv "$FD/labels.$$" "$FD/labels"
    fi
    rm -f "$raw"
    # parent→child links (issue #335): sub-issues are NOT exposed by the `gh issue
    # list --json` field set (there's no parent field), so fetch them with a tiny
    # SEPARATE GraphQL pass — number + parent.number only, one paginated call per
    # repo per TTL. Best-effort + fail-closed: an old gh, a GraphQL error, or a
    # repo without the sub-issues API just leaves parents_<slug> stale/absent and
    # the backlog renders FLAT (bin/tmux-issues-rows.sh degrades to today's
    # behaviour). Sibling of issues/labels under fleets/<slug>/ (no own .ts —
    # fleet_cache's new-layout fallback serves it exactly like labels). Writes
    # child<TAB>parent for every open issue that HAS a parent; the reader nests a
    # child under its parent row. The <name>.$$ temp is swept by the EXIT trap.
    owner="${rp%%/*}"; name="${rp#*/}"
    if gh api graphql --paginate \
      -f query='query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){issues(first:100,states:OPEN,after:$endCursor){pageInfo{hasNextPage endCursor}nodes{number parent{number}}}}}' \
      -F owner="$owner" -F name="$name" \
      --jq '.data.repository.issues.nodes[]|select(.parent!=null)|"\(.number)\t\(.parent.number)"' \
      > "$FD/parents.$$" 2>/dev/null; then
      mv "$FD/parents.$$" "$FD/parents"
    else
      rm -f "$FD/parents.$$"
    fi
    now > "$FD/issues.ts"
  fi
}

# Targeted issues kick (issue #315): `--issues <owner/repo>` force-refreshes JUST
# that repo's issues/labels cache and exits — the webhook handler's instant kick,
# skipping all the git/ctx/usage/escalation/snapshot work a full tick does. Placed
# BEFORE the tmux/socket enumeration so it stays cheap.
if [ -n "$TARGET_ISSUES_REPO" ]; then
  _tr=$(fleet_norm_repo "$TARGET_ISSUES_REPO")
  [ -n "$_tr" ] && fetch_issues_for "$_tr" "$(fleet_slug "$_tr")" 1
  exit 0
fi

# --- overlap guard (issue #551): one full tick at a time -------------------------
# global/collect.pid holds "pid<TAB>start-epoch" of the running tick. A live
# holder that really IS a collector (pid recycling: verify the command line, never
# trust a bare `kill -0`) younger than FLEET_COLLECT_DEADLINE ⇒ skip this tick, say
# so on stderr (→ logs/collect.launchd.log). Older ⇒ it is wedged: TERM its whole
# process tree (pipeline subshells, a hung gh/python) and take over. The targeted
# `--issues` kick above bypasses this on purpose (short, single writer of its own
# file, and the webhook wants it NOW).
kill_tree() {  # TERM <pid> and every descendant (children first is not needed: TERM, not KILL)
  local ps p kids; ps=$(ps -axo pid=,ppid=) || { kill -TERM "$1" 2>/dev/null; return 0; }
  set -- "$1"
  while [ $# -gt 0 ]; do
    p=$1; shift
    kids=$(printf '%s\n' "$ps" | awk -v p="$p" '$2==p{print $1}')
    kill -TERM "$p" 2>/dev/null
    # shellcheck disable=SC2086  # deliberate word-split: one pid per word
    set -- "$@" $kids
  done
  return 0
}
PIDF="$G/collect.pid"; DEADLINE="${FLEET_COLLECT_DEADLINE:-600}"
opid=''; ots=''
[ -f "$PIDF" ] && IFS=$'\t' read -r opid ots < "$PIDF"
case "$opid" in ''|*[!0-9]*) opid='';; esac
case "$ots"  in ''|*[!0-9]*) ots=0;;   esac
if [ -n "$opid" ] && [ "$opid" != "$$" ] && kill -0 "$opid" 2>/dev/null \
   && ps -o command= -p "$opid" 2>/dev/null | grep -q 'tmux-dash-collect'; then
  _age=$(( $(now) - ots ))
  if [ "$_age" -lt "$DEADLINE" ]; then
    printf 'fleet-collect: skip — tick %s still running (%ss, deadline %ss)\n' "$opid" "$_age" "$DEADLINE" >&2
    exit 0
  fi
  printf 'fleet-collect: tick %s exceeded the %ss deadline (%ss) — killing it and taking over\n' "$opid" "$DEADLINE" "$_age" >&2
  kill_tree "$opid"
fi
printf '%s\t%s\n' "$$" "$(now)" > "$PIDF"

# --- heartbeat (issue #551): where the tick is + how long each phase took ---------
# global/collect.heartbeat, key=value lines, rewritten atomically at every phase
# boundary: pid, start, phase (the one RUNNING; `done` after the tick), phase_ts,
# phases ("sessmap=1 issues=12 …" — seconds, accumulated as they complete), and
# end + dur once complete. `fleet-doctor.sh` reads it (last tick age, duration,
# slowest phase); a tick that died mid-way leaves phase=<where> with no end=.
HB="$G/collect.heartbeat"; HB_START=$(now); HB_PHASE=''; HB_PHASE_TS=$HB_START; HB_PHASES=''
HB_OVER=''      # phases that spent their own budget this tick (issue #653)
HB_SKIP=''      # phases the TICK budget truncated away this tick (issue #653)
hb_phase() {  # $1 = the phase now starting ('' = the tick is done)
  local t; t=$(now)
  [ -n "$HB_PHASE" ] && HB_PHASES="${HB_PHASES}${HB_PHASES:+ }${HB_PHASE}=$(( t - HB_PHASE_TS ))"
  HB_PHASE="$1"; HB_PHASE_TS=$t
  { printf 'pid=%s\nstart=%s\nphase=%s\nphase_ts=%s\nphases=%s\n' "$$" "$HB_START" "${HB_PHASE:-done}" "$t" "$HB_PHASES"
    # over=/skipped= are APPENDED keys (issue #653): every reader looks its key up
    # with `sed -n 's/^k=//p'`, so adding lines cannot move an existing one.
    printf 'over=%s\nskipped=%s\n' "$HB_OVER" "$HB_SKIP"
    [ -z "$HB_PHASE" ] && printf 'end=%s\ndur=%s\n' "$t" "$(( t - HB_START ))"; } | atomic_write "$HB"
}

# --- every phase has a budget, and so does the whole tick (issue #653) ------------
# The tick is a serial chain of phases, and for a long time only ONE of them had a
# budget. That is a losing game: whichever phase is currently the most expensive
# drags the whole tick past its own 60s StartInterval — launchd does not overlap a
# StartInterval job, so "tick duration" IS the collector's real cadence — and then
# we file an issue for that one phase and box it. #552 boxed `git` (571s → 56s) and
# the very next tick measured:
#
#   dur=454  phases=quotawatch=17 sessmap=12 issues=14 git=126 ctx=34 usage=226 …
#
# i.e. the bottleneck had simply moved to `usage`, which had no budget at all, and
# `runs` advanced once in 514s against a 60s interval. So budget them ALL, the same
# way, and bound their sum:
#
#   1. PER-PHASE — every phase runs under fleet_timebox with its own knob. A phase
#      that blows its budget is killed and the tick CONTINUES; it never takes the
#      rest of the tick down with it.
#   2. WHOLE-TICK — FLEET_COLLECT_TICK_BUDGET bounds the sum. Before each phase the
#      remaining time is checked, and each phase's own budget is CLAMPED to what is
#      left, so the tick cannot overrun by more than the last phase's tail. Without
#      the clamp a phase starting one second before the deadline could still add
#      its full budget on top.
#   3. ROUND-ROBIN — truncation is not starvation. The phase the tick stopped at is
#      parked in global/collect.phase.cursor and the NEXT tick starts there, wrapping
#      round. A tick that completes clears the cursor, so a healthy machine always
#      runs the historical order. Better some caches miss a round than the whole
#      tick drifting away from its interval.
#
# This only works because fleet_timebox measures WALL CLOCK (issue #653 again): it
# used to count `sleep 1` iterations, which under this daemon's
# `ProcessType=Background` tier inflated a 30s budget to 126s — the same factor that
# made the work slow. Ten phases each holding an elastic budget would have been ten
# copies of one bug; see bin/fleet-lib.sh.
TICK_BUDGET="${FLEET_COLLECT_TICK_BUDGET:-120}"   # 2x the 60s StartInterval
case "$TICK_BUDGET" in ''|*[!0-9]*) TICK_BUDGET=120 ;; esac
PHASE_CURSOR="$G/collect.phase.cursor"
PHASE_MIN=5     # less headroom than this left in the tick ⇒ don't start a phase at all

# The rotating body, in the order a healthy tick runs them. Rotation is only safe
# because no phase reads shell state another one set THIS tick: the expensive
# handoff (sessmap → issues) goes through global/collect.repoqueue on disk, so
# `issues` works off the last good queue whatever order it is reached in. $SOCKETS
# and the shared helpers are resolved in the head below, before any of them.
#
# `quotawatch` is deliberately NOT in this list: #551 put it first precisely so its
# cadence never rides the tick's gh/git latency, and rotating it would hand it back
# the variable position it was moved out of. It runs in the head, budgeted like
# everything else, and the tick budget still bounds it.
PHASE_LIST=(sessmap issues git ctx usage scrape banner escalate snapshot)

# phase_budget NAME — seconds. Each has its own knob so one slow phase can be given
# room without loosening the others; the tick budget is the backstop over all of them.
phase_budget() {
  case "$1" in
    quotawatch) printf '%s' "${FLEET_COLLECT_QUOTAWATCH_BUDGET:-30}" ;;
    sockets)    printf '%s' "${FLEET_COLLECT_SOCKETS_BUDGET:-20}" ;;
    sessmap)    printf '%s' "${FLEET_COLLECT_SESSMAP_BUDGET:-30}" ;;
    issues)     printf '%s' "${FLEET_COLLECT_ISSUES_BUDGET:-45}" ;;
    git)        printf '%s' "${FLEET_COLLECT_GIT_BUDGET:-30}" ;;
    ctx)        printf '%s' "${FLEET_COLLECT_CTX_BUDGET:-45}" ;;
    usage)      printf '%s' "${FLEET_COLLECT_USAGE_BUDGET:-60}" ;;
    scrape)     printf '%s' "${FLEET_COLLECT_SCRAPE_BUDGET:-30}" ;;
    banner)     printf '%s' "${FLEET_COLLECT_BANNER_BUDGET:-30}" ;;
    escalate)   printf '%s' "${FLEET_COLLECT_ESCALATE_BUDGET:-30}" ;;
    snapshot)   printf '%s' "${FLEET_COLLECT_SNAPSHOT_BUDGET:-30}" ;;
    *)          printf '30' ;;
  esac
}

# phase_knob NAME — the env var that tunes it, named in the over-budget line so the
# log says what to change and not just that something was cut off.
phase_knob() {
  case "$1" in
    git) printf 'FLEET_COLLECT_GIT_BUDGET' ;;   # predates the others (issue #552)
    *)   printf 'FLEET_COLLECT_%s_BUDGET' "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" ;;
  esac
}

# tick_left — seconds of the whole-tick budget still unspent (never negative).
tick_left() {
  local spent=$(( $(now) - HB_START ))
  [ "$spent" -ge "$TICK_BUDGET" ] && { printf '0'; return 0; }
  printf '%s' $(( TICK_BUDGET - spent ))
}

# run_phase NAME — mark the boundary, run ph_NAME under its (clamped) budget, and
# account for it. Returns 1 when there was no room left in the tick to start it —
# the driver parks the cursor there and stops.
run_phase() {
  local name="$1" b left rc
  left=$(tick_left)
  [ "$left" -lt "$PHASE_MIN" ] && return 1
  b=$(phase_budget "$name")
  case "$b" in ''|*[!0-9]*) b=30 ;; esac
  [ "$b" -gt "$left" ] && b="$left"        # clamp: the tick budget wins
  hb_phase "$name"
  fleet_timebox "$b" "ph_$name"; rc=$?
  if [ "$rc" = 124 ]; then
    HB_OVER="${HB_OVER}${HB_OVER:+ }$name"
    printf 'fleet-collect: phase %s hit the %ss budget (%s) — killed; the tick runs on (next tick retries it)\n' \
      "$name" "$b" "$(phase_knob "$name")" >&2
    # Optional per-phase postscript: detail only that phase can give (how far its
    # own round-robin got, say). Runs in the PARENT, because the phase's subshell
    # has just been killed and cannot report anything itself.
    command -v "ph_${name}_over" >/dev/null 2>&1 && "ph_${name}_over"
  fi
  return 0
}

# --- quota watch FIRST (issue #551): before any gh/git/python work ---------------
# The ccquota pre-emptive rotation (bin/fleet-quotawatch.sh) has its own 60s
# daemon; running it here too, at the very top, keeps an install whose daemon set
# predates #551 watching at THIS tick's cadence. stderr passes through to the
# collector log.
#
# It stays FIRST and out of the phase rotation (issue #653). #551 moved it to the
# top precisely so its cadence never rides this tick's gh/git latency; letting the
# rotation place it would hand back the variable position it was moved out of. It is
# budgeted like every other phase, and the whole-tick budget still bounds it.
#
# The fallback is now CONDITIONAL (issue #671). It used to be unconditional, on the
# claim that it "costs nothing on a healthy one" — its fetch is TTL-gated, its lock
# skips an in-flight tick, its markers dedup every action. Measurement falsified
# that: the modelcap sweep is the tick's expensive half and is gated by NEITHER the
# TTL nor the dedup markers (it has budgets of its own — 20s a fleet, 40s a sweep),
# so on a multi-fleet host the collector's copy routinely ran the full sweep and was
# killed at the 30s phase budget. Sampled durations were 46 · 56 · 35 · 57 · 25 · 17
# · 10 · 3 seconds, `quotawatch` sat permanently in the heartbeat's over= list and in
# fleet-doctor's "over budget" line, and one phase was eating a quarter of a 120s
# tick to duplicate work a dedicated 60s unit had already done.
#
# So: run it here only when the unit is not demonstrably running on its own. The
# comment's stated purpose — cover an install whose daemon set predates #551 —
# is kept whole, and a healthy install genuinely pays ~0.
#
# The gate asks "is com.claude-fleet.quotawatch actually TICKING?", not "is it
# loaded?", which is the sharper question #639 established and a strict superset of
# it: a unit that is absent, unloaded, OR loaded-but-pended all fall back. It is
# also the cheap question — two file reads against fleet_daemon_tick_ts, no
# launchctl round-trip — and, critically, it cannot flap, because #639 already made
# `--caller collect` the one caller that does NOT stamp the scheduling heartbeat.
# The collector can therefore never mistake its own fallback for the unit being
# healthy; the fallback stays engaged until the real unit ticks again.
#
# FLEET_COLLECT_QUOTAWATCH=always|never forces the old unconditional behaviour or
# switches the fallback off entirely; the default `auto` is the gate.
quotawatch_in_tick() {   # 0 ⇒ this tick runs the watch itself
  local ts age
  case "${FLEET_COLLECT_QUOTAWATCH:-auto}" in
    always|1) return 0 ;;
    never|0)  return 1 ;;
  esac
  # Lib absent (a half-synced install) ⇒ fail OPEN to the historical behaviour: the
  # watch running twice is a cost, the watch not running at all is a blind fleet.
  command -v fleet_daemon_tick_ts >/dev/null 2>&1 || return 0
  ts=$(fleet_daemon_tick_ts quotawatch "$BIN/..")
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ "$ts" -gt 0 ] || return 0                 # never ticked: no unit, or a fresh install
  age=$(( $(now) - ts ))
  [ "$age" -ge "$(fleet_daemon_stale_secs quotawatch)" ]   # ticking ⇒ 1 ⇒ skip
}
ph_quotawatch() {
  # Deliberately still a PHASE even when gated off: the boundary is recorded, so the
  # heartbeat keeps reading `phases=quotawatch=0 …` and "the gate is on" is visible
  # as a number rather than as a phase that silently vanished from the list.
  quotawatch_in_tick || return 0
  bash "$BIN/fleet-quotawatch.sh" --caller collect >/dev/null || true
}
run_phase quotawatch || true

# Each fleet runs on its OWN tmux server/socket now (issue #159), so there is no
# single shared server to probe — enumerate the live fleet sockets ONCE and fan
# every tmux query out across them. NB: we do NOT early-exit when the set is empty
# (unlike the old `tmux info` gate): the per-repo issue fetch below still refreshes
# every CONFIGURED repo's cache even with no live fleet, so the backlog has data
# the moment a fleet opens. The tmux-dependent sections (sessmap, git/ctx, capture,
# escalation, snapshot) each iterate $SOCKETS / lw_all and simply no-op when empty.
#
# This is the tick's one PRECONDITION rather than a rotating phase — every tmux
# phase needs it — so it runs in the head and is never skipped. It is still budgeted
# and still shows up in the heartbeat (issue #653): `fleet_sockets` does a
# `tmux has-session` per configured fleet, and a wedged tmux server used to charge
# that silently to whichever phase happened to follow.
#
# On a timeout the PARTIAL list is discarded rather than used. A truncated
# enumeration is not a smaller fleet, it is an incomplete view of the same one, and
# sessmap's write-guard (#203) only protects against an EMPTY map — a partial one
# would publish, dropping live sessions from the dash's session→repo resolution.
# Empty is a state every consumer already handles ("no live fleet"): the guard keeps
# the last good map and the git/ctx caches keep their last values.
hb_phase sockets
SOCKETS=$(fleet_timebox "$(phase_budget sockets)" fleet_sockets); sock_rc=$?
if [ "$sock_rc" = 124 ]; then
  printf 'fleet-collect: socket enumeration hit the %ss budget (FLEET_COLLECT_SOCKETS_BUDGET) — dropping the partial list; this tick sees no live fleet and every cache keeps its last value\n' \
    "$(phase_budget sockets)" >&2
  SOCKETS=''
fi
# lw_all FMT — the per-fleet-socket replacement for the old `tmux list-windows -a
# -F FMT`: run it against every live fleet socket and concatenate. Reuses the
# cached $SOCKETS (no re-probe). Read-only callers use this; writers loop $SOCKETS
# themselves so they hold the -L label to target (see the escalation block).
lw_all() { local s; for s in $SOCKETS; do tmux -L "$s" list-windows -a -F "$1" 2>/dev/null; done; }

# python3 powers the context% and usage caches (below). It's a hard dep for
# those, so guard it once with a diagnostic to stderr (StandardErrorPath →
# logs/collect.launchd.log) rather than letting a `command not found` get
# swallowed and leaving those caches silently empty forever.
py_warned=0
have_py3() {
  command -v python3 >/dev/null 2>&1 && return 0
  [ "$py_warned" = 0 ] && printf 'fleet-collect: python3 not found on PATH (%s) — context%% and usage caches will be empty\n' "$PATH" >&2
  py_warned=1
  return 1
}

# gh fetch TTL (issues + PR map). FLEET_GH_TTL in fleet.conf tunes staleness
# vs API chatter; GH_TTL=0 on a one-off run forces a fetch.
GH_TTL="${GH_TTL:-${FLEET_GH_TTL:-90}}"

# --- resolve the repo set from live tmux sessions (multi-fleet) ---
# Each tmux session ≡ one fleet ≡ one repo. Seed the fetch queue with the global
# FLEET_REPO (so its slug'd cache stays fresh even with no live session), then add
# every other repo a live session resolves to. No fleet is "primary": every fleet's
# cache is issues_<slug> only, and no flat mirror is written as any one fleet's copy
# (issue #180). Write sessmap for the read-side producers.
#
# The (repo,slug) queue this builds is handed to the `issues` phase through
# global/collect.repoqueue rather than a shell array (issue #653). Two reasons, and
# both are requirements now: a budgeted phase runs in fleet_timebox's SUBSHELL, so
# an array it built would not survive; and the phase rotation can reach `issues` in
# a tick where `sessmap` was skipped, which the file handles by simply serving the
# last good queue. The queue is derived state, so a stale one is at worst a round
# late — never wrong.
ph_sessmap() {
declare -a Q_REPO Q_SLUG          # unique (repo,slug) fetch queue (indexed arrays; bash 3.2 ok)
SEEN=' '
queue() {                          # $1=repo → add once
  local r="$1" s
  [ -z "$r" ] && return
  s=$(fleet_slug "$r")
  case "$SEEN" in *" $s "*) return;; esac
  SEEN="$SEEN$s "; Q_REPO+=("$r"); Q_SLUG+=("$s")
}
[ -n "$REPO" ] && queue "$(fleet_norm_repo "$REPO")"
SM="$G/sessmap.$$"; : > "$SM"          # PID-unique tmp: safe if two collectors overlap (global bucket, issue #181)
# Fan the session enumeration across every live fleet socket (issue #159): no
# single shared server sees them all now.
for sock in $SOCKETS; do
  for sess in $(tmux -L "$sock" list-sessions -F '#{session_name}' 2>/dev/null); do
    r=$(fleet_resolve_repo_for_session "$sess")
    [ -z "$r" ] && continue
    printf '%s\t%s\t%s\n' "$sess" "$(fleet_slug "$r")" "$r" >> "$SM"
    queue "$r"
  done
done
# Sessmap write-guard (issue #203, mirror of the #160 restore-map shrink-guard):
# NEVER let an EMPTY sessmap replace/shadow a non-empty one. If discovery hiccups
# — fleet_sockets momentarily returns nothing (the very #203 regression, or a
# transient tmux) — a 0-row sessmap makes fleet_slug_cached return empty, so
# fleet_cache falls back to a stale flat file and the backlog renders ANOTHER
# repo's issues. So only publish an empty map when there's nothing good to protect.
smrows() { if [ -f "$1" ]; then grep -c . "$1" 2>/dev/null || true; else echo 0; fi; }
new_rows=$(smrows "$SM")
if [ "${new_rows:-0}" -gt 0 ]; then
  mv "$SM" "$G/sessmap"                 # real rows → publish
else
  rm -f "$SM"
  g_rows=$(smrows "$G/sessmap")         # existing new-layout global map
  l_rows=$(smrows "$C/sessmap")         # legacy flat map (fleet_sessmap_file's fallback)
  if [ "${g_rows:-0}" -eq 0 ] && [ "${l_rows:-0}" -gt 0 ]; then
    # An empty global/sessmap would SHADOW the good legacy flat rows (fleet_sessmap_file
    # prefers global/ once it exists) — drop it so the fallback un-shadows and serves
    # the correct repo. A NON-empty global map is always kept as-is.
    rm -f "$G/sessmap"
  fi
  # else: nothing good anywhere (genuinely no live fleet) — leave the map absent so
  # readers show "loading"/empty rather than a wrong-repo flat leftover.
fi

# Prune dead pre-#180 flat mirrors (issue #203): current code writes issues/prmap/
# labels/parents ONLY under fleets/<slug>/ (never the flat $C root), so a leftover
# unsuffixed issues/prmap/labels/parents is a PRE-#180 artifact that fleet_cache's
# degenerate (unresolved-session) fallback would serve as ANOTHER repo's data —
# worse than empty. Remove them so that fallback reads absent → "loading". The flat
# `sessmap` is deliberately NOT pruned: fleet_sessmap_file dual-reads it as the
# cold-start fallback until global/sessmap is populated.
for _stale in issues prmap labels parents; do
  rm -f "$C/$_stale" "$C/$_stale.ts" 2>/dev/null || true
done
# The dash summary cache retired with the summary column (issue #535): sweep the
# per-window summary_* files and the summarizer's sumhash/ change-gate dir. Cheap
# (a glob over global/), idempotent, and gone-for-good once nothing writes them.
rm -f "$G"/summary_* 2>/dev/null || true
rm -rf "$G/sumhash" 2>/dev/null || true

# pin repos with NO live session so their caches stay fresh (a repo you're
# watching but haven't opened; a fleet-up'd-but-closed fleet): FLEET_REPOS list +
# every configured per-fleet conf.
for r in ${FLEET_REPOS:-}; do queue "$(fleet_norm_repo "$r")"; done
while IFS=$'\t' read -r _s cf; do
  [ -f "$cf" ] || continue
  r=$( . "$cf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
  [ -n "$r" ] && queue "$(fleet_norm_repo "$r")"
done < <(fleet_each_conf)

# Publish the queue for the `issues` phase. Same write-guard reasoning as sessmap
# above: never let an empty queue replace a good one — a momentary discovery hiccup
# would otherwise stop every repo's issues cache refreshing until sessmap next
# succeeds.
if [ "${#Q_REPO[@]}" -gt 0 ]; then
  i=0
  while [ "$i" -lt "${#Q_REPO[@]}" ]; do
    printf '%s\t%s\n' "${Q_REPO[$i]}" "${Q_SLUG[$i]}"; i=$((i+1))
  done | atomic_write "$G/collect.repoqueue"
fi
}

# --- per-repo issues (TTL-gated per repo) ---
# NB: PR status (prmap_<slug> + the flat prmap mirror + @prci/@pfg) is NOT built
# here anymore — it moved to bin/tmux-pr-refresh.sh so it can refresh on a ~15s
# cadence instead of this 60s tick. That script is the SINGLE writer of all PR
# state; the collector only touches issues/git/usage. See issue #81.
# Reads the (repo,slug) queue `sessmap` published (global/collect.repoqueue) —
# see there for why it travels on disk rather than in an array (issue #653).
ph_issues() {
  local rp sg
  command -v gh >/dev/null 2>&1 || return 0
  [ -f "$G/collect.repoqueue" ] || return 0
  while IFS=$'\t' read -r rp sg; do
    [ -n "$rp" ] && [ -n "$sg" ] || continue
    fetch_issues_for "$rp" "$sg" 0   # TTL-gated (see fetch_issues_for above)
  done < "$G/collect.repoqueue"
}

# No flat issues mirror is written (issue #180 — all fleets equal, no primary):
# every reader routes through fleet_cache, which returns issues_<slug> for a
# resolved fleet and only falls back to the un-slug'd name during cold start.

# --- git per live worktree (every run) — BUDGETED + round-robin (issue #552) ------
# This phase was the tick's sinkhole. One `git status --porcelain` on a
# 24haowan-monorepo worktree held the loop for 4m42s, and with ~15 such worktrees
# live the phase alone ran minutes. launchd does NOT overlap a StartInterval job,
# so a tick longer than its own 60s interval degrades the collector's REAL cadence
# to "one tick's duration" — measured at 5.3 min between runs, which is why the
# dash could show a two-hours-stale world (#636). Three changes fix it:
#
#   1. NO `git status`. The dirty column (✱) this loop used to compute is read by
#      NOTHING: tmux-dashboard-rows.sh takes field 1 (`read -r branch _`) and
#      tmux-pr-refresh.sh does `cut -f1`. So the most expensive call per worktree —
#      a full working-tree scan of a large monorepo — produced a value nobody
#      consumed. The on-disk format is unchanged (branch<TAB>, field 2 now always
#      empty = byte-identical to what a clean worktree already wrote), so no reader
#      moves. A future reader that wants dirtiness back must fetch it INSIDE the
#      budget below, never as an un-timeboxed call here.
#   2. A WALL-CLOCK BUDGET around the whole phase (FLEET_COLLECT_GIT_BUDGET, 30s).
#      Around the whole phase, not each call: fleet_timebox polls at 1s, so
#      per-call it puts a 1s FLOOR on ~50 calls (measured: 53s for a scan whose
#      real work is ~1.5s). One box costs ~1s a tick and still kills the tree.
#      The box is now applied by run_phase like every other phase's (issue #653) —
#      this phase stopped being the only budgeted one. FLEET_COLLECT_GIT_BUDGET is
#      unchanged and still the knob; it is read through phase_budget.
#   3. ROUND-ROBIN, so the budget cannot starve anyone. The cursor
#      (global/collect.git.cursor) is stamped with a worktree BEFORE its git work
#      and the next tick resumes at the one AFTER it — a worktree that wedges is
#      retried once per rotation instead of eating every tick's budget, and the
#      worktrees behind it still refresh.
#
# A worktree slower than FLEET_COLLECT_GIT_SLOW (10s) is named on stderr (→
# logs/collect.launchd.log): the heartbeat only carries the phase total.
GIT_SLOW="${FLEET_COLLECT_GIT_SLOW:-10}"
GIT_CURSOR="$G/collect.git.cursor"
GIT_DONE="$G/collect.git.done.$$"   # how far the scan got; read back after the box
                                    # (it runs in fleet_timebox's subshell, so a
                                    # counter variable would not survive). The $$
                                    # suffix puts it in the EXIT trap's sweep.
# shellcheck disable=SC2329  # invoked as run_phase's "ph_$name", not by name
ph_git() {
  local p n i pos=0 cur key branch ab behind ahead s0 d
  local -a paths; paths=()
  while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done \
    < <(lw_all '#{pane_current_path}' | sort -u)
  n=${#paths[@]}; [ "$n" -gt 0 ] || return 0
  # Resume just AFTER the worktree the last tick was working on (the cursor names
  # the one it CLAIMED, which is the one that wedged if the budget blew).
  cur=$(cat "$GIT_CURSOR" 2>/dev/null)
  if [ -n "$cur" ]; then
    i=0
    while [ "$i" -lt "$n" ]; do
      [ "${paths[$i]}" = "$cur" ] && { pos=$(( (i + 1) % n )); break; }
      i=$((i+1))
    done
  fi
  SECONDS=0   # per-worktree timing with no `date` fork (bash builtin)
  i=0
  while [ "$i" -lt "$n" ]; do
    p="${paths[$(( (pos + i) % n ))]}"; i=$((i+1))
    printf '%s' "$p" > "$GIT_CURSOR"    # claim BEFORE the work: a wedge rotates back
    printf '%s' "$i" > "$GIT_DONE"
    s0=$SECONDS
    if git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then
      key=$(cache_key "$p")
      branch=$(git -C "$p" rev-parse --abbrev-ref HEAD 2>/dev/null)
      ab=$(git -C "$p" rev-list --left-right --count "$BASE...HEAD" 2>/dev/null)
      # "<behind>\t<ahead>" → two ints with no awk fork (2 per worktree, every tick)
      behind=0; ahead=0
      case "$ab" in *[0-9]*) behind=${ab%%[!0-9]*}; ahead=${ab##*[!0-9]} ;; esac
      [ "$ahead"  != 0 ] && branch="$branch+$ahead"
      [ "$behind" != 0 ] && branch="$branch-$behind"
      printf '%s\t' "$branch" | atomic_write "$G/git_$key"
    fi
    d=$(( SECONDS - s0 ))
    [ "$d" -ge "$GIT_SLOW" ] && printf 'fleet-collect: git took %ss on %s\n' "$d" "$p" >&2
  done
  return 0
}
# ph_git_over — run_phase calls ph_<name>_over (when defined) after a phase spends
# its budget, for detail only that phase can give. The generic line names the phase
# and the budget; this adds how far the rotation got, which is what tells you a
# wedged worktree is being retried once per rotation rather than eating every tick.
# shellcheck disable=SC2329  # invoked as run_phase's "ph_${name}_over", not by name
ph_git_over() {
  printf 'fleet-collect: git covered %s worktree(s) — the rest keep last tick'\''s branch; next tick resumes after %s\n' \
    "$(cat "$GIT_DONE" 2>/dev/null || echo 0)" "$(cat "$GIT_CURSOR" 2>/dev/null)" >&2
  rm -f "$GIT_DONE"
}

# --- per-window context tokens (every run): newest transcript's last-turn input+cache ---
# Claude Code writes transcripts to ~/.claude/projects/<cwd-slug>/*.jsonl; the last
# assistant turn's input+cache tokens = the conversation's current context weight.
# NB: paths passed as ARGV, not stdin — stdin is the heredoc script (can't be both).
# Gather paths into an ARRAY (not a word-split string) so a path containing a
# space stays a single argv entry end-to-end. Guard the length for bash 3.2,
# where "${arr[@]}" on an empty array trips `set -u`. $$ lets Python suffix its
# temp files so the EXIT trap can sweep any it orphans.
ph_ctx() {
local p codex_socket
if have_py3 && [ -f "$BIN/fleet-codex-account.py" ]; then
  # Registered homes only, oldest attempt first, bounded before transcript work.
  # No model call; offline pool accounts can recover quota without a live pane.
  if [ "${FLEET_FAILOVER:-0}" != 1 ] && [ -f "$FLEET_CONF_DIR/codex/accounts.json" ]; then
    FLEET_CONF_DIR="$FLEET_CONF_DIR" python3 "$BIN/fleet-codex-account.py" refresh --budget 15
  fi
  for codex_socket in $SOCKETS; do
    if ( fleet_load_conf "$codex_socket"; [ "${FLEET_FAILOVER:-0}" = 1 ]; ); then
      fleet_bg -L "$codex_socket" "bash '$BIN/fleet-account.sh' reconcile --session '$codex_socket'"
    elif [ -f "$FLEET_CONF_DIR/codex/accounts.json" ]; then
      FLEET_CONF_DIR="$FLEET_CONF_DIR" "$BIN/fleet-codex-account.sh" watch --session "$codex_socket"
    fi
  done
fi
if have_py3 && [ -f "$BIN/fleet-codex-session.py" ]; then
  # Exact Codex session identity; Claude's cwd cache below is never consumed by
  # a Codex row. JSON is last, so pipes/spaces inside paths remain untouched.
  lw_all '#{session_name}|#{window_id}|#{@cc_agent}|#{@cc_launcher_pid}|#{@codex_identity}' \
    | python3 "$BIN/fleet-codex-session.py" collect --cache "$G"
fi
CTX_PATHS=()
while IFS= read -r p; do [ -n "$p" ] && CTX_PATHS+=("$p"); done \
  < <(lw_all '#{pane_current_path}' | sort -u)
if [ "${#CTX_PATHS[@]}" -gt 0 ] && have_py3; then
python3 - "$G" "$$" ${CTX_PATHS[@]+"${CTX_PATHS[@]}"} <<'PY'
import json, glob, os, sys, re
C=sys.argv[1]; pid=sys.argv[2]   # C = the global/ cache bucket (ctx_<key> lives here)
for path in sys.argv[3:]:
    if not path: continue
    slug=re.sub(r'[/._]', '-', path)
    files=sorted(glob.glob(os.path.expanduser(f'~/.claude/projects/{slug}/*.jsonl')),
                 key=os.path.getmtime, reverse=True)
    if not files: continue
    ctx=0; model=''
    try: lines=open(files[0], errors='ignore').readlines()[-250:]
    except OSError: continue
    for line in lines:
        if '"usage"' not in line: continue
        try: d=json.loads(line)
        except: continue
        m=d.get('message') or {}; u=m.get('usage')
        if u and d.get('type')=='assistant':
            ctx=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)
            model=m.get('model','') or model
    # cache key: keep byte-identical to cache_key() in the shell above
    key=path.replace('_','_u').replace('/','_s').replace(' ','_w')
    tmp=f'{C}/ctx_{key}.{pid}'
    with open(tmp,'w') as fh: fh.write(f'{model}\t{ctx}')  # model<TAB>context-tokens
    os.replace(tmp, f'{C}/ctx_{key}')                     # atomic: readers never see a partial cache
PY
fi
}

# --- token-usage proxy (≥300s): sum across ALL session transcripts, 5h + 7d ---
# The official rate-limit % is not exposed by any API, so this is a local proxy
# over Claude's official limit windows (rolling 5h + 7d), weighted like limits
# meter: output heavy, cache-read light.
#
# Memoized per file: ~/.claude/projects/ grows unbounded (thousands of *.jsonl,
# 1GB+), and re-parsing every in-window transcript each tick costs seconds — yet
# steady-state almost none of them changed. So cache each file's RAW per-file
# token sums keyed by (mtime,size) in $C/usage.filecache; on the next tick reuse
# the cached sums for any file whose (mtime,size) is unchanged and only re-read
# the handful actively being appended. Bucketing into 5h/7d is still done by file
# mtime (a cached-mtime-vs-cutoff compare, no re-read) exactly as before, so the
# rolling cutoffs still move correctly. Weighting is linear, so summing raw tokens
# per file then weighting is identical to weighting per line: warm == cold output.
#
# The scan CHECKPOINTS that memo cache as it goes (issue #653), which is what makes
# it safe to put a budget on this phase at all. This was the tick's biggest
# unbudgeted block — 226s measured, against 0.2s for the same glob+stat at
# foreground priority — and it is otherwise all-or-nothing: a killed scan would
# throw away everything it read, so a budget smaller than one full scan would mean
# the usage cache NEVER refreshed rather than refreshing late. Writing the per-file
# sums out periodically makes progress monotone instead: each tick starts warmer
# than the last and the scan converges. The checkpoint MERGES over the previous
# cache rather than replacing it (a partial `new` would prune every file the scan
# had not reached yet, which is the memo it is trying to keep), so pruning of
# vanished / >7d files still only happens on a pass that completes.
#
# The AGGREGATE is still written only on a complete pass. A partial 5h/7d sum is not
# a stale number, it is a WRONG-LOW one, and this feeds the account rotation
# decisions (FLEET_ACCOUNT_WARN_PCT / FLEET_ACCOUNT_CEILING) — under-reporting usage
# there is worse than reporting it a few minutes late.
ph_usage() {
local uts
uts=$(cat "$G/usage.ts" 2>/dev/null || echo 0)
if [ $(( $(now) - uts )) -ge 300 ] && have_py3; then
  python3 - "$G/usage" "$$" <<'PY'
import json, glob, os, sys, time
out=sys.argv[1]; pid=sys.argv[2]; t=time.time()
cachef=out+'.filecache'                                # $C/usage.filecache
w={'5h':t-5*3600, '7d':t-7*86400}
agg={k:0.0 for k in w}
# load prior per-file cache (path -> {mtime,size,tok:[out,in,cc,cr]}); tolerate any corruption
try:
    old=json.load(open(cachef))
    if not isinstance(old, dict): old={}
except Exception:
    old={}
new={}                                                 # rebuilt fresh → prunes vanished / >7d files
ckpt=cachef+'.'+pid                                    # checkpoint temp (swept by the EXIT trap)
def checkpoint():
    # Merge over the prior cache: `new` is partial mid-scan, and writing it alone
    # would drop the memo for every file not yet visited.
    try:
        merged=dict(old); merged.update(new)
        with open(ckpt,'w') as fh: json.dump(merged, fh)
        os.replace(ckpt, cachef)
    except Exception:
        pass                                           # a checkpoint is an optimisation, never a failure
last_ck=time.time()
for f in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')):
    if time.time()-last_ck >= 10:                      # ~every 10s of wall clock
        checkpoint(); last_ck=time.time()
    try: st=os.stat(f)
    except OSError: continue
    mt=st.st_mtime
    if mt < w['7d']: continue
    ent=old.get(f)
    if ent and ent.get('mtime')==mt and ent.get('size')==st.st_size:
        tot=ent['tok']                                 # unchanged → reuse cached raw sums, no open()
    else:
        tot=[0,0,0,0]                                  # output / input / cache_creation / cache_read
        try: fh=open(f, errors='ignore')
        except OSError: continue
        with fh:
            for line in fh:
                if '"usage"' not in line: continue     # fast-path prefilter (kept)
                try: d=json.loads(line)
                except: continue
                m=d.get('message') or {}; u=m.get('usage')
                if not u or d.get('type')!='assistant': continue
                tot[0]+=u.get('output_tokens',0)
                tot[1]+=u.get('input_tokens',0)
                tot[2]+=u.get('cache_creation_input_tokens',0)
                tot[3]+=u.get('cache_read_input_tokens',0)
    new[f]={'mtime':mt,'size':st.st_size,'tok':tot}
    tok=tot[0]*1.0 + tot[1]*0.25 + tot[2]*0.25 + tot[3]*0.02
    for k,cut in w.items():
        if mt>=cut: agg[k]+=tok
def fmt(n):
    n=int(n)
    return f"{n/1e6:.1f}M" if n>=1e6 else (f"{n/1e3:.0f}k" if n>=1e3 else str(n))
tmp=f'{out}.{pid}'
with open(tmp,'w') as fh: fh.write(f"5h {fmt(agg['5h'])} · 7d {fmt(agg['7d'])}")
os.replace(tmp, out)                                   # atomic: readers never see a partial cache
ctmp=f'{cachef}.{pid}'
with open(ctmp,'w') as fh: json.dump(new, fh)          # the COMPLETE pass: `new` alone, so it prunes
os.replace(ctmp, cachef)                               # atomic: overlapping collectors can't corrupt it
PY
  now > "$G/usage.ts"
fi
}

# --- opportunistic scrape of the official weekly-% line (every run) ---
# If any session happens to print "N% of your weekly limit", capture it.
# tolerant by design: grep exits 1 when no session shows the line (the common
# case) — that non-zero pipeline status is intentionally discarded; only the
# captured $line matters.
ph_scrape() {
local line sock w
line=$(for sock in $SOCKETS; do
  for w in $(tmux -L "$sock" list-windows -a -F '#{session_name}:#{window_index}' 2>/dev/null); do
    tmux -L "$sock" capture-pane -p -S -600 -t "$w" 2>/dev/null
  done
done | grep -aoE "[0-9]+% of your (weekly|[0-9]+-hour) limit[^│]*" | tail -1)
if [ -n "$line" ]; then printf '%s\t%s' "$(now)" "$line" | atomic_write "$G/ratelimit"; fi
}

# --- multi-account auto-switch (every run) ---
# When a window running under a registered account shows the "You've hit your …
# limit · resets …" banner, mark THAT account limited and rotate the active
# pointer so NEW sessions spawn on a fresh subscription. The window carries its
# account label in @cc_account (stamped by bin/fleet-claude.sh at launch).
# No-op unless accounts are registered — so single-account installs skip it.
ph_banner() {
local sock win wid acct banner kind lm fb muntil mig msw mk muntilt newact rc
if [ -d "${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}" ]; then
  for sock in $SOCKETS; do
  tmux -L "$sock" list-windows -a -F "#{session_name}:#{window_index}${US}#{window_id}${US}#{@cc_account}" 2>/dev/null | \
  while IFS="$US" read -r win wid acct; do
    [ -n "$acct" ] || continue
    # fleet_limit_banner (usage-lib.sh, issue #511) prefers the classic "hit your
    # <session|weekly|Opus> limit · resets …" line — its tail is what mark-limited
    # benches to (issue #490), so the whole banner is passed, not just the head —
    # and falls back to the newer sticky "Usage limit reached · continuing
    # automatically at …" footer, which outlives the classic line on screen.
    banner=$(tmux -L "$sock" capture-pane -p -S -200 -t "$win" 2>/dev/null | fleet_limit_banner)
    [ -n "$banner" ] || continue
    # A PER-MODEL cap (issue #524) — "hit your Fable 5 limit · resets Sep 6" /
    # "reached your Fable limit" — is NOT the subscription wall: the account keeps
    # its 5h/7d headroom for every other model. Benching it here moved every
    # session onto an account with the same cap (the 2026-09-02 cascade). Instead:
    # record the (account, model) cap (fleet-claude.sh launches new sessions on
    # FLEET_MODEL_FALLBACK while it holds), clear the wall on THIS window IN
    # PLACE (fleet-model-switch.sh types `/model <fallback>` at its prompt: ~5s,
    # process and background agents and context all kept; it falls back to
    # fleet-migrate.sh --model itself when it cannot verify the flip, issue #569),
    # and notify once per episode. @model_migrating guards the window across ticks
    # and is SHARED with the quotawatch sweep, which normally gets here first —
    # this branch is the backstop for a daemon set that predates #569. No usable
    # fallback (knob empty, or it IS the capped model) → the pre-#524
    # subscription path below, unchanged.
    kind=$(printf '%s\n' "$banner" | fleet_limit_kind)
    case "$kind" in
      model:*)
        lm=${kind#model:}; fb="${FLEET_MODEL_FALLBACK-opus}"
        if [ -n "$fb" ] && [ "$fb" != "$lm" ]; then
          muntil=$("$BIN/fleet-account.sh" model-limited "$acct" "$lm" "$banner" 2>/dev/null)
          case "$muntil" in ''|*[!0-9]*) muntil=0;; esac
          mig=$(tmux -L "$sock" display-message -p -t "$wid" '#{@model_migrating}' 2>/dev/null)
          case "$mig" in ''|*[!0-9]*) mig=0;; esac
          if [ $(( $(now) - mig )) -gt 180 ]; then
            tmux -L "$sock" set-window-option -t "$wid" @model_migrating "$(now)" 2>/dev/null
            msw="$BIN/fleet-model-switch.sh"; [ -x "$msw" ] || msw="$BIN/fleet-migrate.sh"
            fleet_bg -L "$sock" "bash '$msw' --model '$fb' --session '$sock' --toast '$wid'"
          fi
          mk="$G/model.limited.$acct.$lm"
          if ! fleet_same_window "$mk" "$muntil"; then
            printf '%s' "$muntil" | atomic_write "$mk"
            muntilt=$(date -r "$muntil" '+%b %d %H:%M' 2>/dev/null || date -d "@$muntil" '+%b %d %H:%M' 2>/dev/null || echo "?")
            tmux -L "$sock" display-message "fleet: $acct hit its $lm cap (until $muntilt) — switching walled sessions to $fb in place; new sessions on it launch on $fb" 2>/dev/null
            if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
              $FLEET_NOTIFY_CMD "# model cap reached — falling back to $fb
account **$acct** hit its **$lm** cap (until $muntilt); the subscription itself is fine, so the account stays active — sessions showing the wall are switched to **$fb** IN PLACE (\`/model\` typed at their own prompt: same process, same transcript, background agents kept) and new sessions on this account launch on **$fb** until the cap resets
> ${banner}" >/dev/null 2>&1
            fi
          fi
          continue
        fi ;;
    esac
    newact=$("$BIN/fleet-account.sh" mark-limited "$acct" "$banner" 2>/dev/null); rc=$?
    # exit 10 = this call rotated the active account away → fires ONCE per bench.
    # A running session cannot hot-swap its token (apiKeyHelper only carries
    # API-key credentials, not subscription OAuth tokens — verified on #495), so
    # following the rotation means moving sessions: every window still running on
    # a benched account — the banner window and any other on that account, mid-
    # turn or idle (their next request fails anyway) — is closed and `--resume`d
    # in a new window under the new active account (fleet-migrate.sh, issue
    # #512), backgrounded via fleet_bg so the collector never blocks on the
    # per-window exit/boot waits. run-shell sets $TMUX for the job, so migrate's
    # bare tmux calls stay on THIS fleet's server; --toast reports the count.
    # fleet_bg, not a hand-rolled `run-shell -b` (#575): migrate's say() report is
    # stdout, which run-shell would overlay on the operator's window (Esc to
    # dismiss) — fleet_bg silences it; the status-line --toast is unchanged.
    if ( fleet_load_conf "$sock"; [ "${FLEET_FAILOVER:-0}" = 1 ] ); then
      fleet_bg -L "$sock" "bash '$BIN/fleet-account.sh' reconcile --session '$sock'"
    elif [ "$rc" -eq 10 ]; then
      fleet_bg -L "$sock" "bash '$BIN/fleet-account.sh' migrate --limited --session '$sock' --toast"
      if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
        $FLEET_NOTIFY_CMD "# subscription limit reached
account **$acct** hit its usage limit — new sessions now use **${newact:-?}**; every session still on it is being moved (close + \`--resume\` in a new window)
> ${banner}" >/dev/null 2>&1
      fi
    fi
  done
  done
fi

}

# NB: the ccquota-driven PRE-EMPTIVE rotation (issue #513) — warn at
# FLEET_ACCOUNT_WARN_PCT, bench + migrate at FLEET_ACCOUNT_CEILING — used to sit
# HERE, at the tail of the tick. It moved to bin/fleet-quotawatch.sh (issue #551):
# its own 60s daemon, and run at the TOP of this tick (see above), so it no longer
# waits on the gh/git/python phases and a tick that dies early can't skip it.

# NB: the PR/CI attention signal (@prci/@pfg per window) moved to
# bin/tmux-pr-refresh.sh (single writer, ~15s cadence) — see #81. The collector
# no longer touches it.

# --- detached-attention escalation (every run) ---
# A window stuck on 'needs' >FLEET_ESCALATE_AFTER sec while NO tmux client is
# attached → run FLEET_NOTIFY_CMD (fleet.conf) with the message as $1 — plug in
# any notifier (Slack webhook curl, WeCom bot, ntfy, …). One ping per episode.
# Per-fleet-socket now (issue #159): the "no client attached" gate is evaluated
# PER FLEET (its own server), so an unwatched fleet still escalates even while
# you're attached to a DIFFERENT fleet — strictly better than the old shared
# server, where any attached client suppressed escalation for every fleet.
ph_escalate() {
local ESC_AFTER nowts sock win name st ts esc wid msg
ESC_AFTER="${FLEET_ESCALATE_AFTER:-300}"
if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
  nowts=$(now)
  for sock in $SOCKETS; do
  [ -z "$(tmux -L "$sock" list-clients 2>/dev/null)" ] || continue   # someone's watching THIS fleet → skip it
  tmux -L "$sock" list-windows -a -F "#{session_name}:#{window_index}${US}#{window_name}${US}#{@claude_state}${US}#{@claude_state_ts}${US}#{@escalated}${US}#{window_id}" 2>/dev/null | \
  while IFS="$US" read -r win name st ts esc wid; do
    [ "$st" = "needs" ] || continue
    case "$ts" in ''|*[!0-9]*) continue;; esac
    [ $(( nowts - ts )) -ge "$ESC_AFTER" ] || continue
    [ "$esc" = "$ts" ] && continue
    msg="# session blocked
**${name}** has been waiting for your input for $(( (nowts-ts)/60 ))m (no client attached)"
    $FLEET_NOTIFY_CMD "$msg" >/dev/null 2>&1 \
      && tmux -L "$sock" set-window-option -t "$win" @escalated "$ts" 2>/dev/null
  done
  done
fi

}

# --- crash-recovery snapshot (every run) ---
# Durably record the live fleet layout (which fleets, work windows, worktrees,
# Claude session ids) so fleet-restore.sh can rebuild every fleet and
# `claude --resume` every session after a tmux-server-wide crash. Cheap; never
# fatal to the collector.
ph_snapshot() {
  bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1 || true
}

# --- run the phases: rotate, budget, truncate (issue #653) -----------------------
# Start where the last tick was truncated and wrap round, so truncation costs a
# phase one ROUND rather than starving it: a tick that ran out of budget at `usage`
# begins the next one at `usage`, and the phases that already ran this tick are the
# ones that wait. A tick that gets all the way round clears the cursor, so a healthy
# machine always runs the historical order and this is invisible.
PH_N=${#PHASE_LIST[@]}
PH_START=0
_cur=$(cat "$PHASE_CURSOR" 2>/dev/null || true)
if [ -n "$_cur" ]; then
  _i=0
  while [ "$_i" -lt "$PH_N" ]; do
    [ "${PHASE_LIST[$_i]}" = "$_cur" ] && { PH_START=$_i; break; }
    _i=$((_i+1))
  done
fi

PH_TRUNC=''
_i=0
while [ "$_i" -lt "$PH_N" ]; do
  _name="${PHASE_LIST[$(( (PH_START + _i) % PH_N ))]}"; _i=$((_i+1))
  if [ -z "$PH_TRUNC" ] && run_phase "$_name"; then continue; fi
  # No room left in the tick: this phase and every one after it wait for the next.
  [ -z "$PH_TRUNC" ] && PH_TRUNC="$_name"
  HB_SKIP="${HB_SKIP}${HB_SKIP:+ }$_name"
done

if [ -n "$PH_TRUNC" ]; then
  printf '%s' "$PH_TRUNC" | atomic_write "$PHASE_CURSOR"
  printf 'fleet-collect: tick hit its %ss budget (FLEET_COLLECT_TICK_BUDGET) — deferred to the next tick, resuming at %s: %s\n' \
    "$TICK_BUDGET" "$PH_TRUNC" "$HB_SKIP" >&2
else
  rm -f "$PHASE_CURSOR"    # a full round: the next tick starts at the top again
fi

hb_phase ''
exit 0
