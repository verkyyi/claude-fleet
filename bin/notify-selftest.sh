#!/bin/bash
# notify-selftest.sh — a session needs you, and this computer says so (issue
# #2759, EPIC #2756 C3): bin/fleet_notify.py's ONE rule, driven through `beat`
# over a round's rows with a fake sender (FLEET_NOTIFY_SEND_CMD) — what the home's
# refresh loop hands it (fleet-hub-sessions.sh, node mode, #3005). The thin
# sender itself (OSC 9 to the 看台 holding the lease) is
# fleet-thin-notify-selftest.sh's; the old client's sender — terminal-notifier,
# a Bark push, a click on the list — went with that client (issue #3008).
#
#   A. ask      the first round only remembers; needs → ONE notification (who,
#               what, where, with a sound); the same question every round →
#               none; working → needs → working → needs = 2; a new question
#               while still asking = a new one
#   B. stuck    needs/blocked → 卡住 with a sound; failed → 失败了
#   C. done     working → done: 做完, no sound, never the phone; a second of the
#               same batch within 10 minutes → ONE notification grown (same
#               group, 「做完了 2 个」); FLEET_NOTIFY_DONE=0 → none, logged skip
#   D. quiet    inside FLEET_NOTIFY_QUIET: still notified, no sound, no phone
#   E. orch     an old orchestrator row is ordinary (issue #3118): done → 做完
#   H. off      FLEET_NOTIFY=0: nothing — no notification, no state, no log
# No network, no live fleet. Exit 0 = pass.
#
# Drives: bin/fleet_notify.py.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
command -v python3 >/dev/null 2>&1 || { echo 'notify selftest: python3 absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notify-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM
unset FLEET_NOTIFY FLEET_NOTIFY_DONE FLEET_NOTIFY_QUIET FLEET_NOTIFY_SEND_CMD FLEET_NOTIFY_LOG FLEET_NOTIFY_DONE_MERGE
export HOME="$WORK/home" TMPDIR="$WORK/t" FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh \
       FLEET_NOTIFY_LOG="$WORK/notify.ndjson" FLEET_NOTIFY_QUIET=off
mkdir -p "$HOME" "$TMPDIR" "$FLEET_CONF_DIR"
G="$WORK/g"; mkdir -p "$G"

CHECKS=0
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || st_fail "$1 (want '$2', got '$3')" "${4:-}"; }
has() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) ;; *) st_fail "$1 (no '$3')" "$2" ;; esac; }

F=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
# the sender: title|body|sound, and a phone line when it was asked for one
cat > "$WORK/sender.py" <<'PY'
import sys
a = sys.argv[1:]
def opt(k):
    return a[a.index(k) + 1] if k in a else ""
with open(sys.argv[0] + ".out", "a") as f:
    f.write("%s|%s|%s\n" % (opt("--title"), opt("--body"), "1" if "--sound" in a else ""))
if "--phone" in a:
    with open(sys.argv[0] + ".phone", "a") as f:
        f.write(opt("--title") + "\n")
PY
export FLEET_NOTIFY_SEND_CMD="python3 $WORK/sender.py"
NOTIFY_OUT="$WORK/sender.py.out"; PHONE="$WORK/sender.py.phone"
: > "$NOTIFY_OUT"; : > "$PHONE"

# row <key> <state> [needs] [detail] [extra json] — one row as the refresh loop hands it
row() { printf '{"wid":"%s/%s","node":"mac-b","issue":%s,"state":"%s","needs":"%s","detail":"%s","name":"%s"%s}' \
          "$F" "$1" "${1#issue-}" "$2" "${3:-}" "${4:-}" "$1" "${5:-}"; }
answer() { local IFS=,; printf '[%s]\n' "$*" > "$WORK/rows.json"; }
round() { python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import fleet_notify
fleet_notify.beat(json.load(open(sys.argv[2])), sys.argv[3], "")' "$BIN" "$WORK/rows.json" "$G" 2>"$WORK/round.err"; }
lines() { wc -l < "$NOTIFY_OUT" | tr -d ' '; }
# the send is detached: wait for the n-th line (or 5 s), then a beat more
settle() { local i=0; while [ "$i" -lt 50 ] && [ "$(lines)" -lt "$1" ]; do sleep 0.1; i=$((i+1)); done; sleep 0.3; }
last() { tail -1 "$NOTIFY_OUT"; }

# ============================================================================ A
answer "$(row issue-1909 working)" "$(row issue-7 needs ask '早就在问的')"
round
eq "A: the first round only remembers (a client starting with one waiting is no notification)" 0 "$(lines)"
[ -s "$G/notify.state.json" ] || st_fail "A: no state file after the first round" "$(cat "$WORK/round.err")"
answer "$(row issue-1909 needs ask '演练放在 mac-b 还是只在 mac-a？')" "$(row issue-7 needs ask '早就在问的')"
round; settle 1
eq "A: needs → one notification: who, what, where, with a sound" "#1909 在问你|演练放在 mac-b 还是只在 mac-a？ · mac-b|1" "$(last)"
round; round; sleep 0.5
eq "A: the same question every round → nothing more" 1 "$(lines)"
answer "$(row issue-1909 working)" "$(row issue-7 needs ask '早就在问的')"; round
answer "$(row issue-1909 needs perm 'Bash: git push')" "$(row issue-7 needs ask '早就在问的')"; round; settle 2
eq "A: working → needs → working → needs = 2" 2 "$(lines)"
eq "A: …the second says what is asked now" "#1909 要你批准|Bash: git push · mac-b|1" "$(last)"
answer "$(row issue-1909 needs ask '换一个问题')" "$(row issue-7 needs ask '早就在问的')"; round; settle 3
eq "A: a new question while still asking → a new one" "#1909 在问你|换一个问题 · mac-b|1" "$(last)"

# ============================================================================ B
answer "$(row issue-1909 needs blocked 'CI 红了，等你看')" "$(row issue-7 failed)"; round; settle 5
eq "B: needs/blocked → 卡住, with a sound" 1 "$(grep -c '^#1909 被卡住了|CI 红了，等你看 · mac-b|1$' "$NOTIFY_OUT")"
eq "B: failed → 失败了, with a sound" 1 "$(grep -c '^#7 失败了|mac-b|1$' "$NOTIFY_OUT")"

# ============================================================================ C
E=',"epic":"o/r#2756:1/3"'
answer "$(row issue-1909 working '' '' "$E")" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working)"; round
answer "$(row issue-1909 'done' '' '' "$E")" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working)"; round; settle 6
eq "C: working → done: 做完, no sound" "#1909 做完了|mac-b|" "$(last)"
answer "$(row issue-1909 'done' '' '' "$E")" "$(row issue-7 'done' '' '' "$E")" "$(row issue-8 working)"; round; settle 7
eq "C: the same batch within 10 minutes → its one notification grown" "#2756 做完了 2 个|最新：#7 · mac-b|" "$(last)"
answer "$(row issue-1909 'done' '' '' "$E")" "$(row issue-7 'done' '' '' "$E")" "$(row issue-8 'done')"
FLEET_NOTIFY_DONE=0 round; sleep 0.5
eq "C: FLEET_NOTIFY_DONE=0 → no 做完" 7 "$(lines)"
has "C: …logged as a skip" "$(tail -1 "$WORK/notify.ndjson")" '"skip": "done-off"'
eq "C: a done never asks for the phone" 0 "$(grep -c '做完' "$PHONE")"

# ============================================================================ D
answer "$(row issue-1909 working)" "$(row issue-7 working)" "$(row issue-8 working)"; round
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-7 working)" "$(row issue-8 working)"
q=$(python3 -c 'import time; t=time.localtime(); h=t.tm_hour; print("%02d:00-%02d:00" % (h, (h + 2) % 24))')
: > "$PHONE"
FLEET_NOTIFY_QUIET=$q round; settle 8
eq "D: quiet hours: still notified, no sound" "#1909 在问你|夜里的问题 · mac-b|" "$(last)"
eq "D: …and no phone asked" "" "$(cat "$PHONE")"

# ============================================================================ E
# an old orchestrator row (issue #3118: no session is special) is a row like any other
O='"role":"orchestrator"'
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 working '' '' ",$O")"; round
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 'done' '' '' ",$O,\"orch_decide\":2")"; round; settle 9
eq "E: an old orchestrator's row is an ordinary row — its done is 做完, no decide count" "#90 做完了|mac-b|" "$(last)"
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 'done' '' '' ",$O,\"orch_decide\":2")" "$(row issue-91 needs ask '合不合？')"; round; settle 10
eq "E: …and a new ask beside it rings" "#91 在问你|合不合？ · mac-b|1" "$(last)"
eq "E: …and asks for the phone (outside quiet hours)" "#91 在问你" "$(cat "$PHONE")"

# ============================================================================ H
rm -f "$G/notify.state.json" "$WORK/notify.ndjson"; : > "$NOTIFY_OUT"
answer "$(row issue-1909 working)"; FLEET_NOTIFY=0 round
answer "$(row issue-1909 needs ask 'x')"; FLEET_NOTIFY=0 round; sleep 0.5
eq "H: FLEET_NOTIFY=0 → no notification, no state, no log" "0||" "$(lines)|$(cat "$G/notify.state.json" 2>/dev/null)|$(cat "$WORK/notify.ndjson" 2>/dev/null)"

printf 'notify selftest: PASS (%s checks)\n' "$CHECKS"
