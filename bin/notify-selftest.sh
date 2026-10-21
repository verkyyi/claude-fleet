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
#   C. done     a done turn is no 做完 (T894): only a handed-in RESULT is — the
#               ID's merged report → ONE 「✓ 做完 · <title>」「PR #N 已合并 · node」,
#               no sound, never the phone; more done turns, the same result →
#               nothing more; a stop with no result → nothing; a probe / a test
#               identity → nothing (logged skip); English wording; a second of
#               the same batch within 10 minutes → ONE notification grown (same
#               group, 「✓ 批次 <parent title> 做完 2 件」); FLEET_NOTIFY_DONE=0 → none
#   D. quiet    inside FLEET_NOTIFY_QUIET: still notified, no sound, no phone
#   E. orch     an old orchestrator row is ordinary (issue #3118): its result → 做完
#   H. off      FLEET_NOTIFY=0: nothing — no notification, no state, no log
# No network, no live fleet. Exit 0 = pass.
#
# Drives: bin/fleet_notify.py.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_need python3
WORK="$(mktemp -d "${TMPDIR:-/tmp}/notify-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT INT TERM
unset FLEET_NOTIFY FLEET_NOTIFY_DONE FLEET_NOTIFY_QUIET FLEET_NOTIFY_SEND_CMD FLEET_NOTIFY_LOG FLEET_NOTIFY_DONE_MERGE
export HOME="$WORK/home" TMPDIR="$WORK/t" FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh \
       FLEET_NOTIFY_LOG="$WORK/notify.ndjson" FLEET_NOTIFY_QUIET=off
mkdir -p "$HOME" "$TMPDIR" "$FLEET_CONF_DIR"
G="$WORK/g"; mkdir -p "$G"

st_tally count

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
st_eq "A: the first round only remembers (a client starting with one waiting is no notification)" 0 "$(lines)"
[ -s "$G/notify.state.json" ] || st_fail "A: no state file after the first round" "$(cat "$WORK/round.err")"
answer "$(row issue-1909 needs ask '演练放在 mac-b 还是只在 mac-a？')" "$(row issue-7 needs ask '早就在问的')"
round; settle 1
st_eq "A: needs → one notification: who, what, where, with a sound" "#1909 在问你|演练放在 mac-b 还是只在 mac-a？ · mac-b|1" "$(last)"
round; round; sleep 0.5
st_eq "A: the same question every round → nothing more" 1 "$(lines)"
answer "$(row issue-1909 working)" "$(row issue-7 needs ask '早就在问的')"; round
answer "$(row issue-1909 needs perm 'Bash: git push')" "$(row issue-7 needs ask '早就在问的')"; round; settle 2
st_eq "A: working → needs → working → needs = 2" 2 "$(lines)"
st_eq "A: …the second says what is asked now" "#1909 要你批准|Bash: git push · mac-b|1" "$(last)"
answer "$(row issue-1909 needs ask '换一个问题')" "$(row issue-7 needs ask '早就在问的')"; round; settle 3
st_eq "A: a new question while still asking → a new one" "#1909 在问你|换一个问题 · mac-b|1" "$(last)"

# ============================================================================ B
answer "$(row issue-1909 needs blocked 'CI 红了，等你看')" "$(row issue-7 failed)"; round; settle 5
st_eq "B: needs/blocked → 卡住, with a sound" 1 "$(grep -c '^#1909 被卡住了|CI 红了，等你看 · mac-b|1$' "$NOTIFY_OUT")"
st_eq "B: failed → 失败了, with a sound" 1 "$(grep -c '^#7 失败了|mac-b|1$' "$NOTIFY_OUT")"

# ============================================================================ C
IDS="$FLEET_CONF_DIR/ids"; mkdir -p "$IDS"
fid() { printf '%08d-0000-4000-8000-000000000000' "$1"; }
P=$(fid 2756)
for n in 1909 7 8 10; do printf '%s/issue-%s\t%s\n' "$F" "$n" "$(fid "$n")"; done > "$G/wid_ids"
# ledger <n> <title> [parent] — an ID's opening; result <n> <state> [pr] — its report
ledger() { printf '{"ev":"opened","title":"%s","parent":"%s"}\n' "$2" "${3:-}" > "$IDS/$(fid "$1").ndjson"; }
result() { printf '{"ev":"result","state":"%s","pr":"%s","ts":%s}\n' "$2" "${3:-}" "$(date +%s)" >> "$IDS/$(fid "$1").ndjson"; }
printf '{"ev":"opened","title":"EPIC 网页终端"}\n' > "$IDS/$P.ndjson"
ledger 1909 '做完的会话还挂着'; ledger 7 '接管与交回' "$P"; ledger 8 '收消息' "$P"; ledger 10 '放置计时探针'
E=',"epic":"o/r#2756:1/3"'
answer "$(row issue-1909 working)" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working '' '' "$E")" "$(row issue-10 working)"; round
n0=$(lines)
answer "$(row issue-1909 'done')" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working '' '' "$E")" "$(row issue-10 working)"; round
answer "$(row issue-1909 working)" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working '' '' "$E")" "$(row issue-10 working)"; round
answer "$(row issue-1909 'done')" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working '' '' "$E")" "$(row issue-10 working)"; round; sleep 0.5
st_eq "C: done turns with no result → no 做完 (a turn is not a done task)" "$n0" "$(lines)"
result 1909 merged 5223; round; settle $((n0 + 1))
st_eq "C: its merged report → ONE 做完 with the result, no sound" "✓ 做完 · 做完的会话还挂着|PR #5223 已合并 · mac-b|" "$(last)"
for _ in 1 2 3; do
  answer "$(row issue-1909 working)" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working '' '' "$E")" "$(row issue-10 working)"; round
  answer "$(row issue-1909 'done')" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working '' '' "$E")" "$(row issue-10 working)"; round
done; sleep 0.5
st_eq "C: three more done turns, the same result → still ONE" "$((n0 + 1))" "$(lines)"
result 10 merged 9; round; sleep 0.5
st_eq "C: a probe's result → nothing" "$((n0 + 1))" "$(lines)"
st_has "C: …logged as a skip" "$(tail -1 "$WORK/notify.ndjson")" '"skip": "probe"'
result 7 succeeded; round; settle $((n0 + 2))
st_eq "C: a batch member's result → 做完 (first of its batch)" "✓ 做完 · 接管与交回|mac-b|" "$(last)"
result 8 merged 12; round; settle $((n0 + 3))
st_eq "C: the same batch within 10 minutes → its one notification grown" "✓ 批次 EPIC 网页终端 做完 2 件|最后：收消息|" "$(last)"
st_eq "C: a done never asks for the phone" 0 "$(grep -c '做完' "$PHONE")"
ledger 1909 '做完的会话还挂着'; result 1909 merged 5300
FLEET_UI_LANG=en round; settle $((n0 + 4))
st_eq "C: English: ✓ Done · <title> · PR #N merged" "✓ Done · 做完的会话还挂着|PR #5300 merged · mac-b|" "$(last)"
ledger 1909 '做完的会话还挂着'; result 1909 merged 5301
FLEET_NOTIFY_DONE=0 round; sleep 0.5
st_eq "C: FLEET_NOTIFY_DONE=0 → no 做完" "$((n0 + 4))" "$(lines)"
st_has "C: …logged as a skip" "$(tail -1 "$WORK/notify.ndjson")" '"skip": "done-off"'
# a test identity's row: its result is never a 做完
answer "$(row issue-1909 'done' '' '' ',"test":true')" "$(row issue-7 working '' '' "$E")" "$(row issue-8 working '' '' "$E")" "$(row issue-10 working)"
ledger 1909 '做完的会话还挂着'; result 1909 merged 5302; round; sleep 0.5
st_eq "C: a test identity's result → nothing" "$((n0 + 4))" "$(lines)"

# ============================================================================ D
answer "$(row issue-1909 working)" "$(row issue-7 working)" "$(row issue-8 working)"; round
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-7 working)" "$(row issue-8 working)"
q=$(python3 -c 'import time; t=time.localtime(); h=t.tm_hour; print("%02d:00-%02d:00" % (h, (h + 2) % 24))')
: > "$PHONE"
FLEET_NOTIFY_QUIET=$q round; settle $((n0 + 5))
st_eq "D: quiet hours: still notified, no sound" "#1909 在问你|夜里的问题 · mac-b|" "$(last)"
st_eq "D: …and no phone asked" "" "$(cat "$PHONE")"

# ============================================================================ E
# an old orchestrator row (issue #3118: no session is special) is a row like any other
O='"role":"orchestrator"'
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 working '' '' ",$O")"; round
printf '%s/issue-90\t%s\n' "$F" "$(fid 90)" >> "$G/wid_ids"; ledger 90 '编排'; result 90 succeeded
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 'done' '' '' ",$O,\"orch_decide\":2")"; round; settle $((n0 + 6))
st_eq "E: an old orchestrator's row is an ordinary row — its result is 做完, no decide count" "✓ 做完 · 编排|mac-b|" "$(last)"
answer "$(row issue-1909 needs ask '夜里的问题')" "$(row issue-90 'done' '' '' ",$O,\"orch_decide\":2")" "$(row issue-91 needs ask '合不合？')"; round; settle $((n0 + 7))
st_eq "E: …and a new ask beside it rings" "#91 在问你|合不合？ · mac-b|1" "$(last)"
st_eq "E: …and asks for the phone (outside quiet hours)" "#91 在问你" "$(cat "$PHONE")"

# ============================================================================ H
rm -f "$G/notify.state.json" "$WORK/notify.ndjson"; : > "$NOTIFY_OUT"
answer "$(row issue-1909 working)"; FLEET_NOTIFY=0 round
answer "$(row issue-1909 needs ask 'x')"; FLEET_NOTIFY=0 round; sleep 0.5
st_eq "H: FLEET_NOTIFY=0 → no notification, no state, no log" "0||" "$(lines)|$(cat "$G/notify.state.json" 2>/dev/null)|$(cat "$WORK/notify.ndjson" 2>/dev/null)"

printf 'notify selftest: PASS (%s checks)\n' "$CHECKS"
