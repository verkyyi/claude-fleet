#!/bin/bash
# needs-reconcile-selftest.sh — the stale-`needs` reconcile (issue #658).
#
# #640 made a red window say WHY it is red; #656 made it say so correctly. Neither
# re-reads the stamp afterwards, and `@claude_state` is written on EVENTS only — so a
# red that was right when stamped stays red after its cause is gone. On 2026-09-14 two
# windows on the live fleet sat at `⊘` ("only a human may press this") over an OPEN
# AskUserQuestion: stamped by the pre-#657 wording rule minutes before the fix went
# live, and out of its reach forever after, because a session blocked on a dialog
# fires no further hook. That mislabel is self-sealing — it is precisely what stops
# the operator from answering and ending it.
#
# So bin/tmux-spinner.sh reconciles the stamp against the transcript, and this test
# drives the REAL daemon end-to-end on an isolated `-L` socket (never the user's live
# server), with a fake `claude` in each pane and a scratch session-registry +
# transcript tree, so it tests the shipped chain — pane → Claude pid → registry
# sessionId → transcript → verdict — and not a copy of it.
#
#   PART A — bin/fleet-pending-tool.sh's TARGET form: the oracle now answers about a
#     WINDOW, not just a transcript path, and distinguishes "nothing pending" (1)
#     from "no Claude here" (3) from "I could not find out" (4). #658 was filed off a
#     `fleet-pending-tool.sh %83` that printed nothing and was read as "that pane is
#     idle" — a pane id is not a file, so it had simply exited 1. The path form's
#     contract is re-pinned here too: it must not change for its hook callers.
#
#   PART B — the reconcile itself, over one fixture fleet:
#     · a red window whose Claude EXITED            → cleared to idle
#     · a red `perm` whose transcript holds nothing  → cleared to done
#     · a red `perm` over a pending AskUserQuestion  → STAYS red, subtype → ask
#     · a red `ask` over a pending Bash              → STAYS red, subtype → perm
#     · an EMPTY-subtype red past FLEET_NEEDS_PLAIN_SECS, nothing pending
#                                                    → cleared to done (#699)
#     · the same red INSIDE that dwell               → STAYS red: an empty subtype is the
#       classifier's screen verdict, and "a worker stopped to ask you a question in
#       prose" has no tool_use open either — it must outlive the 20s ask/perm grace
#     · an EMPTY-subtype red over a PENDING Bash     → untouched, subtype still empty
#       (the reconcile re-settles `ask` ⇄ `perm`; it never INVENTS a subtype)
#     · a red `perm` over a pending Bash             → untouched (it is real)
#     · a red whose session is unregistered          → untouched (unknown ⇒ never act)
#     · a fresh stamp                                → untouched (the settling grace)
#     · and NOTHING anywhere becomes `needs`: the reconcile only ever clears.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPINNER="$BIN/tmux-spinner.sh"
ORACLE="$BIN/fleet-pending-tool.sh"
[ -f "$SPINNER" ] || { printf 'selftest: %s not found\n' "$SPINNER" >&2; exit 2; }
[ -f "$ORACLE" ]  || { printf 'selftest: %s not found\n' "$ORACLE" >&2; exit 2; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

# SHORT scratch name on purpose: a unix socket path is capped at ~104 bytes, and
# macOS's $TMPDIR is already ~55 of them — "needs-reconcile-selftest.XXXXXX" put
# $TMUX_TMPDIR/tmux-<uid>/fleetR over the limit and tmux refused with
# "File name too long".
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nrec.XXXXXX")" || exit 2

# Isolation, exactly as attn-signal-selftest.sh does it: a private TMUX_TMPDIR puts
# the `-L fleetR` socket inside this test's scratch dir, and a private FLEET_CONF_DIR
# is what the spinner's fleet_sockets enumerates — so the daemon under test can see
# this fleet and ONLY this fleet.
export TMUX_TMPDIR="$WORK/tmt"; mkdir -p "$TMUX_TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
printf 'FLEET_REPO="acme/fleetR"\n' > "$FLEET_CONF_DIR/fleetR.conf"
# The two lookup trees the resolution chain walks, pointed at scratch (both overrides
# already exist for exactly this purpose: FLEET_CC_SESSIONS_DIR in fleet-lib.sh,
# CLAUDE_PROJECTS_DIR in fleet_transcript_dir / the oracle's target form).
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export CLAUDE_PROJECTS_DIR="$WORK/projects";   mkdir -p "$CLAUDE_PROJECTS_DIR/proj"
# A fake `claude` is a shell loop, whose comm is the interpreter — FLEET_CLAUDE_COMM
# is the sanctioned widening for exactly that (fleet_pane_claude_pid).
export FLEET_CLAUDE_COMM='FLEETFAKECLAUDE'

FAIL=0 CHECKS=0
fail() { FAIL=1; printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
tf() { "$REAL_TMUX" -L fleetR "$@"; }

SPIN_PID=''
cleanup() {
  [ -n "$SPIN_PID" ] && kill "$SPIN_PID" 2>/dev/null
  "$REAL_TMUX" -L fleetR kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# mk_transcript <out> <tool> [answered] — same shape needs-reason-selftest.sh builds:
# the newest tool_use is <tool>, optionally already answered (⇒ nothing pending).
mk_transcript() {
  OUT="$1" TOOL="$2" ANS="${3:-}" python3 - <<'PY'
import json, os
rows = [{"type": "user", "message": {"role": "user", "content": "go"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_658", "name": os.environ["TOOL"], "input": {}}]}}]
if os.environ.get("ANS"):
    rows.append({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_658", "content": "done"}]}})
with open(os.environ["OUT"], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
PY
}

# ---------------------------------------------------------------------------
# Fixture: one window per case, each holding a fake Claude (or deliberately not).
# ---------------------------------------------------------------------------
NOW=$(date +%s)
OLD=$((NOW - 600))     # a stamp old enough to be past the settling grace
# …and a stamp that is past the ask/perm grace but still INSIDE the empty-subtype
# dwell PART B runs with (FLEET_NEEDS_PLAIN_SECS=300). The gap between the two is
# what #699's fix is made of, so the test needs a stamp in it.
MID=$((NOW - 60))

# mkwin <name> <claude:yes|no> <state> <subtype> <ts> [tool] [answered]
# Creates the window, resolves the pane's "Claude" through the REAL probe, then
# registers that pid + writes its transcript — so the test exercises the same
# pid→sessionId→jsonl chain production walks, rather than handing over a path.
mkwin() {
  local name="$1" hasc="$2" state="$3" sub="$4" ts="$5" tool="${6:-}" ans="${7:-}"
  local cmd pid sid
  if [ "$hasc" = yes ]; then
    cmd=": $FLEET_CLAUDE_COMM; while :; do sleep 300; done"
  else
    cmd="while :; do sleep 300; done"
  fi
  tf new-window -d -n "$name" "$cmd" 2>/dev/null
  tf set-window-option -t "$name" @claude_state "$state" 2>/dev/null
  tf set-window-option -t "$name" @claude_needs "$sub" 2>/dev/null
  tf set-window-option -t "$name" @claude_state_ts "$ts" 2>/dev/null
  [ "$hasc" = yes ] || return 0
  # shellcheck source=/dev/null
  pid=$(. "$BIN/fleet-lib.sh" 2>/dev/null; fleet_pane_claude_pid "$name" fleetR 2>/dev/null)
  [ -n "$pid" ] || { fail "fixture: no fake claude resolved under window $name"; return 0; }
  [ -n "$tool" ] || return 0                       # registered=no: the "unknown" case
  sid="sid-$name"
  printf '{"sessionId":"%s","cwd":"/x"}\n' "$sid" > "$FLEET_CC_SESSIONS_DIR/$pid.json"
  mk_transcript "$CLAUDE_PROJECTS_DIR/proj/$sid.jsonl" "$tool" "$ans"
}

tf new-session -d -s fleetR -n home "while :; do sleep 300; done" \
  || { printf 'selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }

mkwin w-dead     no  needs perm "$OLD"                          # Claude exited while red
mkwin w-stale    yes needs perm "$OLD" Bash            answered # red, but nothing is open
mkwin w-askfix   yes needs perm "$OLD" AskUserQuestion          # the live 2026-09-14 case
mkwin w-permfix  yes needs ask  "$OLD" Bash                     # the same error, mirrored
mkwin w-plainold yes needs ""   "$OLD" Bash            answered # empty subtype, dwell served
mkwin w-plainnew yes needs ""   "$MID" Bash            answered # empty subtype, still dwelling
mkwin w-plainpnd yes needs ""   "$OLD" Bash                     # empty subtype, something IS open
mkwin w-real     yes needs perm "$OLD" Bash                     # a genuine permission prompt
mkwin w-unreg    yes needs perm "$OLD"                          # alive but unregistered
mkwin w-fresh    yes needs perm "$((NOW + 60))" Bash   answered # stamp younger than the grace
mkwin w-working  no  working ""  "$OLD"                         # never a reconcile candidate

# ---------------------------------------------------------------------------
# PART A — the oracle's target form
# ---------------------------------------------------------------------------
orc() { sh "$ORACLE" -L fleetR "$1" >/dev/null 2>&1; printf '%s' "$?"; }
CHECKS=$((CHECKS+1)); [ "$(orc w-askfix)" = 0 ] || fail "oracle: a pending AskUserQuestion must exit 0" "$(orc w-askfix)"
CHECKS=$((CHECKS+1)); [ "$(sh "$ORACLE" -L fleetR w-askfix 2>/dev/null)" = AskUserQuestion ] \
  || fail "oracle: …and must NAME it" "$(sh "$ORACLE" -L fleetR w-askfix 2>/dev/null)"
CHECKS=$((CHECKS+1)); [ "$(orc w-stale)" = 1 ]  || fail "oracle: an answered transcript must exit 1 (nothing pending)" "$(orc w-stale)"
CHECKS=$((CHECKS+1)); [ "$(orc w-dead)" = 3 ]   || fail "oracle: a pane with no Claude must exit 3, not 1 — 'nothing here' is not 'nothing pending'" "$(orc w-dead)"
CHECKS=$((CHECKS+1)); [ "$(orc w-unreg)" = 4 ]  || fail "oracle: a live Claude with no resolvable transcript must exit 4 (unknown)" "$(orc w-unreg)"
CHECKS=$((CHECKS+1)); [ "$(orc nosuchwindow)" = 3 ] || fail "oracle: a target with no pane must exit 3" "$(orc nosuchwindow)"

# The PATH form is unchanged — its hook callers depend on every one of these.
T_ASK="$WORK/t-ask.jsonl"; mk_transcript "$T_ASK" AskUserQuestion
CHECKS=$((CHECKS+1)); [ "$(sh "$ORACLE" "$T_ASK")" = AskUserQuestion ] \
  || fail "oracle: the path form must still name a pending tool" "$(sh "$ORACLE" "$T_ASK")"
sh "$ORACLE" "$WORK/no-such-transcript.jsonl" >/dev/null 2>&1; rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" = 1 ] \
  || fail "oracle: a MISSING path must stay exit 1 (the hooks' fail-safe), never be retried as a tmux target" "$rc"
sh "$ORACLE" >/dev/null 2>&1; rc=$?
CHECKS=$((CHECKS+1)); [ "$rc" = 2 ] || fail "oracle: no argument must exit 2 (usage)" "$rc"

# ---------------------------------------------------------------------------
# PART B — the reconcile, driven by the REAL spinner
# ---------------------------------------------------------------------------
# One check per second, so the 2-strike debounce converges in ~2-3s. The stuck-working
# sweep is OFF so nothing else can write a state here and muddy the verdicts.
# FLEET_NEEDS_PLAIN_SECS=300 shrinks the empty-subtype dwell from its 900s default so
# OLD (-600s) is past it and MID (-60s) is inside it — the two directions #699 needs
# pinned. It is deliberately NOT 1: a dwell equal to the ordinary grace is exactly the
# behaviour this test exists to rule out.
env FLEET_NEEDS_RECONCILE_SECS=1 FLEET_NEEDS_PLAIN_SECS=300 FLEET_STUCK_WORKING_SECS=0 \
  SPIN_INTERVAL=0.05 sh "$SPINNER" >/dev/null 2>&1 &
SPIN_PID=$!

wo() { tf show-window-options -t "$1" 2>/dev/null | awk -v k="$2" '$1==k{$1="";sub(/^ /,"");gsub(/^"|"$/,"");print}'; }
st() { tf display-message -p -t "$1" '#{@claude_state}' 2>/dev/null; }
sb() { tf display-message -p -t "$1" '#{@claude_needs}' 2>/dev/null; }

# Converge or give up: poll EVERY window that must move — all four, not a subset.
# One pass walks its candidates in window order and re-reads a transcript per
# candidate, so the writes inside a single pass are hundreds of milliseconds apart:
# breaking as soon as the 3rd window settled read the 4th before its own write had
# landed, and CI failed on it (the 1-in-2 flake this comment exists to prevent).
for _ in $(seq 1 60); do
  [ "$(st w-dead)" != needs ] && [ "$(st w-stale)" = "done" ] \
    && [ "$(st w-plainold)" = "done" ] \
    && [ "$(sb w-askfix)" = ask ] && [ "$(sb w-permfix)" = perm ] && break
  sleep 0.5
done
# …then let a few more passes run before asserting what must NOT have moved. A rail
# that the reconcile would wrongly touch gets several chances to prove it.
sleep 3

# The clears.
CHECKS=$((CHECKS+1)); [ -z "$(st w-dead)" ] \
  || fail "a red window whose Claude exited must be cleared to idle" "state=$(st w-dead)"
CHECKS=$((CHECKS+1)); [ -z "$(sb w-dead)" ] || fail "…and its subtype cleared with it" "needs=$(sb w-dead)"
CHECKS=$((CHECKS+1)); [ "$(st w-stale)" = "done" ] \
  || fail "a red 'perm' with nothing pending in the transcript must clear to done" "state=$(st w-stale)"
CHECKS=$((CHECKS+1)); [ -z "$(sb w-stale)" ] || fail "…and drop the stale reason" "needs=$(sb w-stale)"
# #699: the guard that required ask|perm here produced NO verdict for an empty
# subtype, so the class that goes stale most — the classifier writes an empty subtype
# by design, and only ever at Stop, where nothing can be pending — was the one class
# nothing could ever clear.
CHECKS=$((CHECKS+1)); [ "$(st w-plainold)" = "done" ] \
  || fail "an EMPTY-subtype red past FLEET_NEEDS_PLAIN_SECS with nothing pending must clear to done (#699)" "state=$(st w-plainold)"
CHECKS=$((CHECKS+1)); [ -z "$(sb w-plainold)" ] || fail "…and stay subtype-less" "needs=$(sb w-plainold)"

# The subtype re-settle — the live 2026-09-14 defect, in both directions. The window
# stays RED: the operator still has to act, they were just told the wrong reflex.
CHECKS=$((CHECKS+1)); [ "$(st w-askfix)" = needs ] \
  || fail "a window with a pending AskUserQuestion must STAY red" "state=$(st w-askfix)"
CHECKS=$((CHECKS+1)); [ "$(sb w-askfix)" = ask ] \
  || fail "…and a stale 'perm' over an open AskUserQuestion must re-settle to 'ask' (#656's ⊘-on-a-question, corrected late)" "needs=$(sb w-askfix)"
CHECKS=$((CHECKS+1)); [ "$(st w-permfix)" = needs ] && [ "$(sb w-permfix)" = perm ] \
  || fail "a stale 'ask' over a pending Bash must re-settle to 'perm'" "state=$(st w-permfix) needs=$(sb w-permfix)"

# The rails: what must NOT be touched.
CHECKS=$((CHECKS+1)); [ "$(st w-plainnew)" = needs ] && [ -z "$(sb w-plainnew)" ] \
  || fail "an EMPTY-subtype red inside its dwell must STAY red — it is the classifier's screen verdict, and a worker that stopped to ask a prose question waits with no tool_use open" "state=$(st w-plainnew) needs=$(sb w-plainnew)"
CHECKS=$((CHECKS+1)); [ "$(st w-plainpnd)" = needs ] && [ -z "$(sb w-plainpnd)" ] \
  || fail "an EMPTY-subtype red over a PENDING tool_use must be left exactly as it is — the reconcile re-settles a WRONG subtype, it never invents a missing one" "state=$(st w-plainpnd) needs=$(sb w-plainpnd)"
CHECKS=$((CHECKS+1)); [ "$(st w-real)" = needs ] && [ "$(sb w-real)" = perm ] \
  || fail "a genuine permission prompt must be left alone" "state=$(st w-real) needs=$(sb w-real)"
CHECKS=$((CHECKS+1)); [ "$(st w-unreg)" = needs ] && [ "$(sb w-unreg)" = perm ] \
  || fail "an unresolvable transcript is UNKNOWN, not idle — the red must stand" "state=$(st w-unreg) needs=$(sb w-unreg)"
CHECKS=$((CHECKS+1)); [ "$(st w-fresh)" = needs ] \
  || fail "a stamp younger than the grace window must not be reconciled yet" "state=$(st w-fresh)"
CHECKS=$((CHECKS+1)); [ "$(st w-working)" = working ] \
  || fail "a 'working' window is not a reconcile candidate" "state=$(st w-working)"

# ONE DIRECTION ONLY: nothing that was not red may have BECOME red. Checked as a set
# difference, not an exact list, so this assertion fails for exactly one reason.
newreds=$(tf list-windows -a -F '#{window_name} #{@claude_state}' 2>/dev/null \
  | awk '$2=="needs"{print $1}' | grep -x -e home -e w-dead -e w-stale -e w-plainold -e w-working | tr '\n' ' ')
CHECKS=$((CHECKS+1)); [ -z "$newreds" ] \
  || fail "the reconcile must only ever CLEAR — these windows were not red and now are" "newly red: $newreds"

# ---------------------------------------------------------------------------
# PART C — the 2-strike grace, pinned by COUNT (not by wall clock)
# ---------------------------------------------------------------------------
# `--needs-check` runs exactly one pass of the SAME code the frame loop calls, so the
# "two consecutive checks must agree" rule is testable directly: one pass may only
# arm, the second acts. A wall-clock version of this assertion is worthless — on a
# fixture this size a single-strike build still takes >2s to converge, so it passes
# for the wrong reason (which is the very mistake #658 was filed on).
kill "$SPIN_PID" 2>/dev/null; SPIN_PID=''
rm -f "$BIN/../logs/.needs-strikes"
# PART B is done asserting on the two empty-subtype reds that must stay red, and a
# pass walks its candidates in window order under NEEDS_BUDGET=8 — leaving them red
# would let w-debounce, created last, be the one starved out of a pass. Retire them.
tf set-window-option -t w-plainnew @claude_state 'done' 2>/dev/null
tf set-window-option -t w-plainpnd @claude_state 'done' 2>/dev/null
mkwin w-debounce yes needs perm "$OLD" Bash answered

one_pass() { env FLEET_NEEDS_RECONCILE_SECS=1 sh "$SPINNER" --needs-check >/dev/null 2>&1; }

one_pass
CHECKS=$((CHECKS+1)); [ "$(st w-debounce)" = needs ] \
  || fail "the FIRST reconcile pass may only arm a strike, never act — a stamp gets one check of grace" "state=$(st w-debounce)"
one_pass
CHECKS=$((CHECKS+1)); [ "$(st w-debounce)" = "done" ] \
  || fail "the SECOND pass agreeing with the first must act" "state=$(st w-debounce)"

# A strike table older than 3x the interval is not "the previous check" — after a
# restart (or a one-shot from an hour ago) the grace starts over.
tf set-window-option -t w-debounce @claude_state needs 2>/dev/null
tf set-window-option -t w-debounce @claude_needs perm 2>/dev/null
tf set-window-option -t w-debounce @claude_state_ts "$OLD" 2>/dev/null
# The aged table holds the EXACT strike this pass will produce, so the age check is
# the only thing that can stop it from counting as agreement.
DWID=$(tf display-message -p -t w-debounce '#{window_id}' 2>/dev/null)
printf '%s |fleetR:%s:idle|\n' "$OLD" "$DWID" > "$BIN/../logs/.needs-strikes"
one_pass
CHECKS=$((CHECKS+1)); [ "$(st w-debounce)" = needs ] \
  || fail "a STALE strike table must not count as the previous check" "state=$(st w-debounce)"

# The knob must switch the whole errand off.
kill "$SPIN_PID" 2>/dev/null; SPIN_PID=''
tf set-window-option -t w-stale @claude_state needs 2>/dev/null
tf set-window-option -t w-stale @claude_needs perm 2>/dev/null
tf set-window-option -t w-stale @claude_state_ts "$OLD" 2>/dev/null
env FLEET_NEEDS_RECONCILE_SECS=0 FLEET_STUCK_WORKING_SECS=0 SPIN_INTERVAL=0.05 \
  sh "$SPINNER" >/dev/null 2>&1 &
SPIN_PID=$!
sleep 4
CHECKS=$((CHECKS+1)); [ "$(st w-stale)" = needs ] \
  || fail "FLEET_NEEDS_RECONCILE_SECS=0 must disable the reconcile entirely" "state=$(st w-stale)"

printf '%s checks\n' "$CHECKS"
[ "$FAIL" = 0 ] || exit 1
printf 'needs-reconcile-selftest: OK\n'
exit 0
