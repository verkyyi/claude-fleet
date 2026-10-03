#!/bin/bash
# transcript-archive-selftest.sh — hermetic tests for bin/fleet-transcript-archive.sh
# and its daily hook in bin/fleet-diskguard.sh (issue #1299).
#
# The contract worth pinning:
#   A. a REFERENCED transcript never moves, whatever its age — restore map,
#      /fleet-history ledger, a live window's @cc_session_id, the newest resumable
#      transcript in a live window's cwd, a running Claude's session registry
#   B. what DOES move: a session idle past KEEP_DAYS, a helper (`marker`) idle past
#      the helper lease — and nothing else (fresh helpers, thin chats, recent
#      sessions, non-uuid files); its sibling <id>/ dir travels with it
#   C. --dry-run moves nothing; the budget leaves work for the next tick (exit 75)
#   D. --restore puts it back, sibling dir included, with a fresh lease
#   E. /fleet-history resume still works: a ledger-referenced transcript is kept,
#      and a resume --exec brings back one that was archived anyway
#   F. diskguard's transcript_watch runs once a day, not every tick
#
# Fully hermetic: a temp HOME / FLEET_CONF_DIR / CLAUDE_PROJECTS_DIR, a PATH-shim
# `tmux` that never reaches a real server. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
TA="$BIN/fleet-transcript-archive.sh"
[ -x "$TA" ] || { echo "selftest: $TA not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/transcript-archive-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }

export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" CLAUDE_PROJECTS_DIR="$WORK/projects"
export FLEET_HISTORY_LEDGER="$WORK/ledger.tsv" FLEET_CC_SESSIONS_DIR="$WORK/home/.claude/sessions"
mkdir -p "$HOME" "$FLEET_CONF_DIR/fleets/sf" "$CLAUDE_PROJECTS_DIR" "$FLEET_CC_SESSIONS_DIR" "$WORK/shim"
: > "$FLEET_CONF_DIR/fleets/sf/conf"
: > "$FLEET_HISTORY_LEDGER"

# A `tmux` that claims fleet `sf` is up with two windows: one whose hook recorded
# a session id, one with none (its session is the newest transcript in its cwd).
LIVE_WT="$WORK/wt-live"; LIVE2_WT="$WORK/wt-live2"; mkdir -p "$LIVE_WT" "$LIVE2_WT"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
case " \$* " in
  *' has-session '*)  exit 0 ;;
  *' list-windows '*) printf '%s|%s\n' 00000000-0000-4000-8000-000000000165 "$LIVE_WT"
                      printf '|%s\n' "$LIVE2_WT" ;;
esac
exit 0
EOF
chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH"

enc() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-'; }
age() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }
DAY=86400
D="$CLAUDE_PROJECTS_DIR/-w-a"; mkdir -p "$D"
SP="$CLAUDE_PROJECTS_DIR/-private-tmp-claude-501-x-scratchpad"; mkdir -p "$SP"
LD="$CLAUDE_PROJECTS_DIR/$(enc "$LIVE2_WT")"; mkdir -p "$LD"

real() {   # $1=file — a substantive session (60 lines, a tool call)
  { printf '{"type":"user","message":"hi"}\n'
    printf '{"type":"assistant","content":[{"type":"tool_use"}]}\n'
    i=0; while [ $i -lt 60 ]; do printf '{"type":"x","n":%d}\n' $i; i=$((i+1)); done; } > "$1"
}
helper() { printf '{"content":"You are a status classifier for a coding-agent terminal session."}\n' > "$1"; }
thin()   { printf '{"type":"user","message":"quick question"}\n' > "$1"; }
id() { printf '00000000-0000-4000-8000-%012d' "$1"; }

real "$D/$(id 1).jsonl"; age "$D/$(id 1).jsonl" $((40*DAY))                 # stale, unreferenced → archived
mkdir -p "$D/$(id 1)/subagents"; echo sub > "$D/$(id 1)/subagents/agent-x.jsonl"
real "$D/$(id 2).jsonl"; age "$D/$(id 2).jsonl" $((40*DAY))                 # in a restore map
real "$D/$(id 3).jsonl"; age "$D/$(id 3).jsonl" $((40*DAY))                 # in the history ledger
real "$D/$(id 4).jsonl"; age "$D/$(id 4).jsonl" $((40*DAY))                 # a running claude's registry
real "$D/$(id 165).jsonl"; age "$D/$(id 165).jsonl" $((40*DAY))             # a live window's @cc_session_id
real "$LD/$(id 6).jsonl"; age "$LD/$(id 6).jsonl" $((40*DAY))               # newest in a live window's cwd
helper "$LD/$(id 7).jsonl"; age "$LD/$(id 7).jsonl" $((2*DAY))              # …and the helper beside it goes
helper "$SP/$(id 8).jsonl"; age "$SP/$(id 8).jsonl" $((2*DAY))              # helper, 2d → archived
helper "$SP/$(id 9).jsonl"; age "$SP/$(id 9).jsonl" 3600                    # helper, 1h → kept
thin "$D/$(id 10).jsonl"; age "$D/$(id 10).jsonl" $((2*DAY))                # thin real chat → kept
real "$D/$(id 11).jsonl"; age "$D/$(id 11).jsonl" $((5*DAY))                # recent session → kept
real "$D/not-a-session.jsonl"; age "$D/not-a-session.jsonl" $((40*DAY))     # not a uuid → kept
helper "$D/$(id 12).jsonl"; age "$D/$(id 12).jsonl" $((60*DAY))             # helper AND in a restore map → kept

printf 'FLEET\tsf\to/r\t/x\tmaster\nWIN\tissue-2\t/w/a\t%s\t2\tdone\t-\t-\t-\nWIN\tissue-12\t/w/a\t%s\t12\tdone\n' \
  "$(id 2)" "$(id 12)" > "$FLEET_CONF_DIR/fleets/sf/restore.map"
WT3="$WORK/wt-3"; mkdir -p "$WT3"
printf '2026-01-01T00:00:00Z\t3\tt\t9\tabc\t%s\t%s\t%s\t-\tlanded\t-\n' "$WT3" "$D" "$(id 3)" > "$FLEET_HISTORY_LEDGER"
printf '{"pid":1,"sessionId":"%s","cwd":"/w/a"}\n' "$(id 4)" > "$FLEET_CC_SESSIONS_DIR/1.json"

present() { [ -f "$1/$2.jsonl" ]; }
ARCH="$FLEET_CONF_DIR/transcript-archive"

# ---- referenced set ----------------------------------------------------------
refs=$("$TA" --referenced)
for n in 2 3 4 165 6 12; do
  printf '%s\n' "$refs" | grep -qx "$(id $n)" || fail "--referenced is missing $(id $n)" "$refs"; ok
done

# ---- C. dry run moves nothing ------------------------------------------------
out=$("$TA" --run --dry-run) || fail "dry run exit $?" "$out"
case "$out" in *"would-archive 3 (stale 1, helper 2)"*) ok ;; *) fail "dry run summary" "$out" ;; esac
present "$D" "$(id 1)" || fail "dry run moved a file"; ok
[ ! -d "$ARCH" ] || [ -z "$(find "$ARCH" -name '*.tar.gz')" ] || fail "dry run wrote a tarball"; ok

# ---- C. budget 0 → exit 75, nothing done -------------------------------------
"$TA" --run --budget 0 >/dev/null; rc=$?
[ "$rc" = 75 ] || fail "budget 0 should exit 75, got $rc"; ok
present "$D" "$(id 1)" || fail "budget 0 still archived"; ok

# ---- A + B. the real pass ----------------------------------------------------
out=$("$TA" --run) || fail "run exit $?" "$out"
case "$out" in *"archived 3 (stale 1, helper 2)"*"left 0"*) ok ;; *) fail "run summary" "$out" ;; esac
for n in 2 3 4 165 12; do present "$D" "$(id $n)" || fail "referenced $(id $n) was moved"; ok; done
present "$LD" "$(id 6)" || fail "live window's newest transcript was moved"; ok
present "$SP" "$(id 9)"  || fail "fresh helper was moved"; ok
present "$D" "$(id 10)"  || fail "thin chat was moved"; ok
present "$D" "$(id 11)"  || fail "recent session was moved"; ok
[ -f "$D/not-a-session.jsonl" ] || fail "non-uuid file was moved"; ok
present "$D" "$(id 1)"  && fail "stale session was not archived"; ok
[ ! -e "$D/$(id 1)" ]   || fail "sibling dir left behind"; ok
present "$SP" "$(id 8)" && fail "old helper was not archived"; ok
present "$LD" "$(id 7)" && fail "old helper in a live dir was not archived"; ok
[ -f "$ARCH/-w-a/$(id 1).tar.gz" ] || fail "no tarball for $(id 1)" "$(find "$ARCH")"; ok
[ "$(grep -c $'\tarchived\t' "$ARCH/archive.log")" = 3 ] || fail "archive.log rows" "$(cat "$ARCH/archive.log")"; ok
"$TA" --list | grep -q "$(id 8)" || fail "--list misses $(id 8)"; ok

# idempotent: a second pass finds nothing
out=$("$TA" --run); case "$out" in *"archived 0 "*) ok ;; *) fail "second pass not a no-op" "$out" ;; esac

# ---- D. restore ----------------------------------------------------------------
"$TA" --restore "$(id 1)" >/dev/null || fail "restore failed"; ok
present "$D" "$(id 1)" || fail "restore did not bring the jsonl back"; ok
[ "$(cat "$D/$(id 1)/subagents/agent-x.jsonl" 2>/dev/null)" = sub ] || fail "restore lost the sibling dir"; ok
[ ! -f "$ARCH/-w-a/$(id 1).tar.gz" ] || fail "restore left the tarball"; ok
out=$("$TA" --run); case "$out" in *"archived 0 "*) ok ;; *) fail "a just-restored session was re-archived" "$out" ;; esac
"$TA" --restore "$(id 999)" --quiet; [ $? = 1 ] || fail "restore of an unknown id should exit 1"; ok
"$TA" --restore "$(id 1)" >/dev/null || fail "restore of a present id should exit 0"; ok

# ---- E. /fleet-history resume -------------------------------------------------
v=$(bash "$BIN/fleet-history.sh" resume --exec --repo o/r 3 2>&1)
case "$v" in RESUME*"$(id 3)"*) ok ;; *) fail "history resume of a kept ledger row" "$v" ;; esac
# A row whose transcript got archived anyway (no ledger pinned at archive time):
WT13="$WORK/wt-13"; mkdir -p "$WT13"; real "$D/$(id 13).jsonl"; age "$D/$(id 13).jsonl" $((40*DAY))
FLEET_HISTORY_LEDGER="$WORK/empty.tsv" "$TA" --run >/dev/null
present "$D" "$(id 13)" && fail "fixture: $(id 13) should have been archived"; ok
printf '2026-01-02T00:00:00Z\t13\tt\t10\tdef\t%s\t%s\t%s\t-\tlanded\t-\n' "$WT13" "$D" "$(id 13)" >> "$FLEET_HISTORY_LEDGER"
v=$(bash "$BIN/fleet-history.sh" resume --exec --repo o/r 13 2>&1)
case "$v" in RESUME*"$(id 13)"*) ok ;; *) fail "history resume of an archived row" "$v" ;; esac
present "$D" "$(id 13)" || fail "history resume did not restore the transcript"; ok

# ---- degenerate: no projects dir ----------------------------------------------
CLAUDE_PROJECTS_DIR="$WORK/nope" "$TA" --run >/dev/null || fail "missing projects dir should exit 0"; ok

# ---- F. diskguard daily hook ---------------------------------------------------
helper "$SP/$(id 20).jsonl"; age "$SP/$(id 20).jsonl" $((2*DAY))
(
  FLEET_DISKGUARD_SOURCE=1 . "$BIN/fleet-diskguard.sh"
  transcript_watch
  [ -f "$GDIR/last-transcript-archive" ] || { echo "no stamp" >&2; exit 1; }
  [ -f "$CLAUDE_PROJECTS_DIR/-private-tmp-claude-501-x-scratchpad/$(id 20).jsonl" ] && { echo "first tick did not archive" >&2; exit 1; }
  helper "$SP/$(id 21).jsonl"; age "$SP/$(id 21).jsonl" $((2*DAY))
  transcript_watch
  [ -f "$SP/$(id 21).jsonl" ] || { echo "second tick the same day ran again" >&2; exit 1; }
  FLEET_TRANSCRIPT_ARCHIVE=0; echo 0 > "$GDIR/last-transcript-archive"; transcript_watch
  [ -f "$SP/$(id 21).jsonl" ] || { echo "FLEET_TRANSCRIPT_ARCHIVE=0 still ran" >&2; exit 1; }
) || fail "diskguard transcript_watch"; ok

echo "transcript-archive-selftest: OK ($CHECKS checks)"
