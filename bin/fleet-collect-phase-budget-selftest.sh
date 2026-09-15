#!/bin/bash
# fleet-collect-phase-budget-selftest.sh — EVERY collector phase has a budget, the
# whole tick has one, and truncation rotates instead of starving (issue #653).
#
# Background (#653): the tick is a serial chain of phases and for a long time only
# ONE of them was budgeted. That is a losing game — whichever phase is currently the
# most expensive drags the whole tick past its 60s StartInterval, and launchd does
# not overlap a StartInterval job, so "tick duration" IS the collector's real
# cadence. #552 budgeted `git` (571s → 56s); the very next tick measured
#
#     dur=454  phases=quotawatch=17 sessmap=12 issues=14 git=126 ctx=34 usage=226 …
#
# — the bottleneck had simply moved to `usage`, which had no budget at all, and
# `runs` advanced ONCE in 514s against a 60s interval. This pins the general
# mechanism that replaced the per-phase patching:
#
#   1. PER-PHASE   — every phase runs under its own budget. A phase that blows it is
#                    killed and the tick RUNS ON; stderr names the phase and its knob.
#   2. WHOLE-TICK  — FLEET_COLLECT_TICK_BUDGET bounds the sum. A phase's own budget is
#                    CLAMPED to the time left in the tick, so the tick cannot overrun
#                    by more than its last phase's tail.
#   3. ROTATION    — the phase the tick truncated at is parked in
#                    global/collect.phase.cursor and the NEXT tick STARTS there,
#                    wrapping round: a truncated phase waits one round, never forever.
#   4. CLEAN TICK  — a tick that gets all the way round clears the cursor, so a
#                    healthy machine always runs the historical order.
#   5. HEARTBEAT   — over= names the phases that spent their budget and skipped= the
#                    ones the tick budget deferred, so "which phase ate the tick" is
#                    readable (fleet-doctor.sh prints it) instead of a hand
#                    investigation every time the bottleneck moves.
#   6. QUEUE       — sessmap hands the repo queue to `issues` through
#                    global/collect.repoqueue, because a budgeted phase runs in a
#                    SUBSHELL (an array would not survive) and rotation can reach
#                    `issues` in a tick that skipped `sessmap`.
#
# Drives the REAL collector against a FAKE git / gh / tmux / ccquota (no network, no
# tmux server, no repos). HOME is the scratch dir so the usage scan never touches
# real transcripts. Needs python3 (collector hard dep) — SKIPs if absent.
# Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-restore.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/collect-phase-budget-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
# Unique per run, so a peer selftest's wedge is never counted as this one's.
HANGMARK="collect-phase-budget-hang-$$"
trap 'pkill -9 -f "$HANGMARK" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh fleet-restore.sh; do
  cp "$BIN/$f" "$WORK/bin/"
done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
C="$WORK/.claude-dash"; G="$C/global"

WT1="$WORK/wt1"; WT2="$WORK/wt2"
printf '%s\n%s\n' "$WT1" "$WT2" > "$WORK/panepaths"

# fake tmux — answers the pane-path enumeration; everything else is a silent exit 0.
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
label=""
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then label="$2"; shift 2; fi
case "${1:-}" in
  has-session)   exit 0 ;;
  list-sessions) [ -n "$label" ] && printf '%s\n' "$label"; exit 0 ;;
  list-windows)
    for a in "$@"; do [ "$a" = '#{pane_current_path}' ] && { cat "$FAKE_PANEPATHS"; exit 0; }; done
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE

# fake git — optionally WEDGES on a path suffix, which is how a phase is made to
# spend its budget without depending on real machine load.
cat > "$WORK/fakepath/git" <<'FAKE'
#!/bin/bash
path=''
if [ "${1:-}" = "-C" ]; then path="$2"; shift 2; fi
# The marker makes the wedged child findable in the process table, so a tick can
# be asked whether it left ORPHANS behind rather than only whether it returned
# (issue #682). It goes in argv[0] via `exec -a`, NOT in a trailing comment: with
# a single command `bash -c "sleep 120 # mark"` execs the sleep and the comment
# leaves with the old argv, so `pgrep -f` matched nothing and hang_survivors()
# answered 0 whether or not the tick leaked (issue #698).
case "$path" in *"${FAKE_GIT_HANG:-__nomatch__}")
  exec -a "${FAKE_HANG_MARK:-fleet-collect-hang}" sleep 120 ;;
esac
case "${1:-} ${2:-}" in
  'rev-parse --git-dir')    printf '.git\n';   exit 0 ;;
  'rev-parse --abbrev-ref') printf 'b-%s\n' "${path##*/}"; exit 0 ;;
  'rev-list --left-right')  printf '1\t2\n';   exit 0 ;;
esac
exit 0
FAKE

# fake gh — logs that the issues phase actually fetched, so "issues ran off the
# queue FILE" is observable rather than inferred.
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
exit 0
FAKE
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
# verdict: go|hold|unknown only (cmd/ccquota/budget.go) — never "ok" (issue #668).
printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":90,"five_hour":{"utilization":10,"resets_at":"2026-09-12T05:00:00Z"},"seven_day":{"utilization":5,"resets_at":"2026-09-16T05:00:00Z"}}]}'
FAKE
chmod +x "$WORK/fakepath/"*

GH_LOG="$WORK/gh.log"
run_collector() {
  : > "$GH_LOG"
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  GH_TTL="${TTL:-0}" \
  FLEET_REPO="" FLEET_REPOS="" FLEET_NOTIFY_CMD="" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_ACCOUNTS_DIR="$WORK/accounts" CCQUOTA_HUB_URL="http://hub.test:8787" FLEET_ACCOUNT_QUOTA_TTL=999999 \
  FAKE_PANEPATHS="$WORK/panepaths" FAKE_GH_LOG="$GH_LOG" FAKE_GIT_HANG="${HANG:-}" \
  FAKE_HANG_MARK="$HANGMARK" \
  FLEET_COLLECT_TICK_BUDGET="${TICK:-120}" FLEET_COLLECT_GIT_BUDGET="${GITB:-30}" \
    bash "$WORK/bin/tmux-dash-collect.sh" >"$WORK/stdout" 2>"$WORK/stderr"
}
fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- stderr ---\n' >&2; cat "$WORK/stderr" >&2 2>/dev/null
         printf -- '--- heartbeat ---\n' >&2; cat "$G/collect.heartbeat" >&2 2>/dev/null
         printf -- '--- phase cursor ---\n%s\n' "$(cat "$G/collect.phase.cursor" 2>/dev/null)" >&2
         exit 1; }
ok()     { printf '  ok — %s\n' "$1"; }
hbget()  { sed -n "s/^$1=//p" "$G/collect.heartbeat" | head -1; }
# the phase NAMES of the last tick, in the order they ran
order()  { hbget phases | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' '; }
pcur()   { cat "$G/collect.phase.cursor" 2>/dev/null; }
has()    { case " $2 " in *" $1 "*) return 0;; esac; return 1; }
# hang_survivors — wedged children still alive. A tick is only bounded if the
# PROCESSES stop too (issue #682): the budget used to bound the ledger, printing
# "killed" over a tree that ran on, and the next tick piled another on top.
hang_survivors() { sleep 2; pgrep -f "$HANGMARK" 2>/dev/null | wc -l | tr -d ' '; }

# 1. CLEAN TICK — every phase runs, in the historical order, nothing deferred ------
run_collector || fail "1: a full tick must exit 0"
[ "$(hbget phase)" = "done" ] || fail "1: the tick must reach phase=done"
exp='quotawatch sockets sessmap issues git ctx usage scrape banner escalate snapshot '
[ "$(order)" = "$exp" ] || fail "1: phase order wrong.
  want: $exp
  got : $(order)"
ok "a clean tick runs every phase, quotawatch first, in the historical order"
[ -z "$(hbget over)" ]    || fail "1: over= must be empty on a clean tick (got: $(hbget over))"
[ -z "$(hbget skipped)" ] || fail "1: skipped= must be empty on a clean tick (got: $(hbget skipped))"
[ -z "$(pcur)" ]          || fail "1: a completed tick must clear the phase cursor (got: $(pcur))"
ok "over=/skipped= empty and no phase cursor parked — a healthy tick never rotates"

# 2. QUEUE — sessmap publishes the repo queue on disk, issues consumes it ----------
[ -s "$G/collect.repoqueue" ] || fail "2: sessmap must publish global/collect.repoqueue"
grep -q 'acme/widgets' "$G/collect.repoqueue" \
  || fail "2: the queue must carry the configured repo (got: $(cat "$G/collect.repoqueue"))"
grep -q 'issue list' "$GH_LOG" \
  || fail "2: the issues phase must have fetched off the queue (gh log: $(cat "$GH_LOG"))"
ok "sessmap publishes the repo queue to disk and issues fetches off it"

# 3. PER-PHASE BUDGET — a wedged phase is killed; the tick runs on -----------------
# git wedges on wt1. Its own budget is well inside the tick budget, so this isolates
# "a phase is killed at ITS budget" from "the tick ran out of room".
HANG=/wt1 GITB=3 TICK=120 run_collector || fail "3: a wedged phase must not fail the tick"
[ "$(hbget phase)" = "done" ] || fail "3: the tick must still reach phase=done with a wedged phase"
has git "$(hbget over)" || fail "3: over= must name the phase that spent its budget (got: $(hbget over))"
[ -z "$(hbget skipped)" ] || fail "3: nothing should be deferred — the tick budget was not reached (got: $(hbget skipped))"
grep -q 'phase git hit the 3s budget (FLEET_COLLECT_GIT_BUDGET)' "$WORK/stderr" \
  || fail "3: stderr must name the phase, its budget and its knob"
case "$(order)" in *' snapshot '*) : ;; *) fail "3: every later phase must still run (got: $(order))" ;; esac
n=$(hang_survivors)
[ "$n" = 0 ] || fail "3: $n wedged child(ren) outlived the tick — the budget bounded the ledger, not the processes (#682)"
ok "a wedged phase is killed at its own budget, named on stderr, and the tick runs on"
ok "…and leaves NO residue: the wedged child is gone once the tick returns"

# 4. WHOLE-TICK BUDGET — truncation, and the cursor parks where it stopped ---------
# git wedges for longer than the whole tick has left, so the phases after it get no
# room at all. That is the case the per-phase budgets alone could not cover: ten
# phases each inside its own budget can still sum past the interval.
rm -f "$G/collect.phase.cursor"
HANG=/wt1 GITB=20 TICK=10 run_collector || fail "4: a truncated tick must still exit 0"
[ "$(hbget phase)" = "done" ] || fail "4: a truncated tick must still reach phase=done"
skipped="$(hbget skipped)"
for p in ctx usage scrape banner escalate snapshot; do
  has "$p" "$skipped" || fail "4: skipped= must name the deferred phase '$p' (got: $skipped)"
done
[ "$(pcur)" = "ctx" ] || fail "4: the cursor must park on the FIRST deferred phase (want ctx, got: $(pcur))"
grep -q 'tick hit its 10s budget (FLEET_COLLECT_TICK_BUDGET)' "$WORK/stderr" \
  || fail "4: stderr must say the tick budget was hit and what it deferred"
ok "the tick budget truncates the chain and parks the cursor on the first deferred phase"

# 5. ROTATION — the next tick STARTS at the cursor and wraps round -----------------
# This is what makes truncation cost a phase one round instead of starving it: the
# phases that already ran are the ones that wait.
TICK=120 run_collector || fail "5: the resuming tick must exit 0"
# The deferred phases run FIRST, then the wrap picks up the ones this rotation has
# not served yet — including `git`, which ran last tick and is now last in line.
exp='quotawatch sockets ctx usage scrape banner escalate snapshot sessmap issues git '
[ "$(order)" = "$exp" ] || fail "5: the tick must resume at the cursor and wrap.
  want: $exp
  got : $(order)"
ok "the next tick resumes at the parked phase and wraps round (ctx → … → sessmap → issues → git)"
[ -z "$(pcur)" ] || fail "5: completing the round must clear the cursor (got: $(pcur))"
ok "completing a full round clears the cursor — the tick is back to its normal order"

printf 'selftest PASS: collect phase budgets — per-phase · whole-tick · rotation · heartbeat · repo queue (#653)\n'
