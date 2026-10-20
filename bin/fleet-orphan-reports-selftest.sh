#!/bin/bash
# fleet-orphan-reports-selftest.sh — bin/fleet-orphan-reports.py (issue #3369): the
# one reader of global/orphan-reports.ndjson, what the sidebar and the entry list.
#
#   A. no file → list / cell print nothing, exit 0;
#   B. list: unread rows newest first, `id ts repo child state pr summary`, a tab or
#      newline in a summary flattened, junk lines skipped, the id stable;
#   C. cell: the inventory's column-31 cell (\x1f fields, \x1e entries), --max caps;
#   D. read <id>: never listed again (list and cell), idempotent; a bad id → exit 2;
#   E. a row older than FLEET_ORPHAN_REPORT_DAYS is not listed; show <id> prints it.
# Hermetic: a sandbox FLEET_CONF_DIR. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
R="$BIN/fleet-orphan-reports.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/orphan-reports-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
N=0 BAD=0
ok() { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL: %s\n' "$1" >&2; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 — wanted «$3» in:
$2" ;; esac; }
eq() { [ "$2" = "$3" ] && ok || bad "$1 — wanted «$2», got «$3»"; }
export FLEET_CONF_DIR="$WORK/conf"
f() { OUT=$(python3 "$R" "$@" 2>&1); RC=$?; }

# --- A. no file -------------------------------------------------------------------
f list; eq "A: list exits 0" 0 "$RC"; eq "A: nothing" "" "$OUT"
f cell; eq "A: cell empty" "" "$OUT"

# --- B. list ----------------------------------------------------------------------
NOW=$(date +%s)
mkdir -p "$FLEET_CONF_DIR/global"
F="$FLEET_CONF_DIR/global/orphan-reports.ndjson"
{
  printf '{"ts": %s, "child_key": "issue-41", "state": "MERGED", "pr": "12", "summary": "landed\\tthe fix\\nline two", "repo": "o/r", "title": "fix it", "parent": "scratch-3"}\n' $((NOW - 100))
  printf 'not json\n{"ts": 1}\n'
  printf '{"ts": %s, "child_key": "app:issue-42", "state": "BLOCKED", "pr": "", "summary": "needs a token"}\n' $((NOW - 50))
} > "$F"
f list; eq "B: two rows" 2 "$(printf '%s\n' "$OUT" | grep -c .)"
eq "B: newest first" "app:issue-42" "$(printf '%s\n' "$OUT" | head -1 | cut -f4)"
L2=$(printf '%s\n' "$OUT" | sed -n 2p)
eq "B: the fields" "o/r|issue-41|MERGED|12|landed the fix line two" "$(printf '%s' "$L2" | awk -F'\t' '{ print $3 "|" $4 "|" $5 "|" $6 "|" $7 }')"
ID41=$(printf '%s' "$L2" | cut -f1)
case "$ID41" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok ;; *) bad "B: a 12-hex id: $ID41" ;; esac
f list; eq "B: the id is stable" "$ID41" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -f1)"

# --- C. cell ----------------------------------------------------------------------
f cell
eq "C: two entries" 2 "$(printf '%s' "$OUT" | awk -v RS=$'\036' 'NF { n++ } END { print n }')"
has "C: \\x1f fields" "$OUT" "$ID41"$'\037'"$((NOW - 100))"$'\037'"o/r"$'\037'"issue-41"$'\037'"MERGED"$'\037'"12"$'\037'"landed the fix line two"
f cell --max 1; eq "C: --max 1" "app:issue-42" "$(printf '%s' "$OUT" | cut -d$'\037' -f4)"

# --- D. read ----------------------------------------------------------------------
f read "$ID41"; eq "D: read exits 0" 0 "$RC"
f list; eq "D: one row left" 1 "$(printf '%s\n' "$OUT" | grep -c .)"
case "$OUT" in *"$ID41"*) bad "D: a read row listed" ;; *) ok ;; esac
f cell; case "$OUT" in *"$ID41"*) bad "D: a read row in the cell" ;; *) ok ;; esac
f read "$ID41"; eq "D: idempotent" 1 "$(grep -c . "$FLEET_CONF_DIR/global/orphan-reports.read")"
f read 'nope!'; eq "D: a bad id → exit 2" 2 "$RC"

# --- E. age, show -----------------------------------------------------------------
printf '{"ts": %s, "child_key": "issue-7", "state": "FAILED", "pr": "3", "summary": "old"}\n' $((NOW - 20 * 86400)) >> "$F"
f list; case "$OUT" in *issue-7*) bad "E: a 20-day-old row listed" ;; *) ok ;; esac
FLEET_ORPHAN_REPORT_DAYS=30 f list; has "E: inside a longer window it is" "$OUT" "issue-7"
f show "$ID41"; eq "E: show exits 0" 0 "$RC"
has "E: show: child + state + PR" "$OUT" "issue-41 MERGED (PR #12)"
has "E: show: the result" "$OUT" "line two"
has "E: show: the parent" "$OUT" "scratch-3"
f show 000000000000; eq "E: show unknown → exit 1" 1 "$RC"

# --- F. list --us (T493): 0x1f, an empty repo stays its own field; agent, issue last
printf '{"ts": %s, "child_key": "scratch-9", "state": "SUCCEEDED", "pr": "", "summary": "no repo", "agent": "codex", "issue": "4539"}\n' "$NOW" >> "$F"
f list --us
row=$(printf '%s\n' "$OUT" | grep scratch-9)
eq "F: the child key is field 4 with an empty repo" "scratch-9" "$(printf '%s' "$row" | awk -F$'\037' '{print $4}')"
eq "F: agent · issue last" "codex|4539" "$(printf '%s' "$row" | awk -F$'\037' '{print $8 "|" $9}')"

# --- G. count · once · redeliver · clear (T660) -------------------------------------
f count; eq "G: count = the unread rows" "$(python3 "$R" list --max 1000 | grep -c .)" "$OUT"
f once scratch-3; eq "G: once — the first push of a batch" 0 "$RC"
f once scratch-3; eq "G: once — the same batch again: none" 1 "$RC"
f once scratch-4; eq "G: once — another batch pushes" 0 "$RC"
FLEET_ORPHAN_NOTIFY_SECS=0 f once scratch-3; eq "G: once — past the window it pushes again" 0 "$RC"
TO=178b03b8-8fee-4762-b3f3-93bf497fe632
printf '#!/bin/sh\nprintf "%%s\\n---\\n" "$*" >> "%s"\n' "$WORK/sent" > "$WORK/send.sh"
f redeliver --to "$TO" --since $((NOW - 10)); has "G: redeliver lists first" "$OUT" "would redeliver"
has "G: …today's row" "$OUT" "scratch-9"
case "$OUT" in *issue-42*) bad "G: an older row is not redelivered" ;; *) ok ;; esac
eq "G: …and sends nothing" no "$([ -e "$WORK/sent" ] && echo yes || echo no)"
FLEET_ORPHAN_SEND="$WORK/send.sh" f redeliver --to "$TO" --since $((NOW - 10)) --apply
has "G: --apply delivers" "$OUT" "redelivered"
has "G: …to the ID" "$(cat "$WORK/sent")" "fid:$TO"
has "G: …as a child-report envelope" "$(cat "$WORK/sent")" "[child-report] scratch-9"
FLEET_ORPHAN_SEND="$WORK/send.sh" f redeliver --to "$TO" --since $((NOW - 10)) --apply
eq "G: never twice" 1 "$(grep -c 'child-report' "$WORK/sent")"
f list; case "$OUT" in *scratch-9*) bad "G: a redelivered row still listed" ;; *) ok ;; esac
f redeliver --to nope; eq "G: a bad ID → exit 2" 2 "$RC"
f clear --before $((NOW - 10)); has "G: clear lists first" "$OUT" "would clear"
f clear --before $((NOW - 10)) --apply; has "G: clear --apply" "$OUT" "cleared"
f count; eq "G: nothing left unread" 0 "$OUT"

printf '%d checks, %d failed\n' "$N" "$BAD"
[ "$BAD" = 0 ]
