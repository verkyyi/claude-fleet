#!/bin/bash
# fleet-batch-green-selftest.sh — bin/fleet-batch-green.sh (issue #3369): a batch
# nobody drives says how many of its member PRs are green, once per count.
#
#   A. no epic-running mark (fleet-epic not installed) → nothing read, said, written;
#   B. a stale mark, its EPIC open, nobody wearing @epic: the READY member PRs off
#      prmap are counted (a red / draft / closed member and a closed sub-issue are
#      not) — one batch-green event naming the batch, the count and the PRs;
#   C. the same count again → silent (also past the throttle); a new count → said;
#      inside FLEET_BATCH_GREEN_SECS → the member list is not even read;
#   D. a live window wearing the batch's @epic (either spelling) → nothing;
#      a fresh mark → nothing; an unread member list → no «0», nothing said;
#   E. the batch stops being stale → it leaves the book; FLEET_BATCH_GREEN=0 → off.
# Hermetic: a sandbox FLEET_CONF_DIR and TMPDIR, seams for gh / tmux / the alert.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
G="$BIN/fleet-batch-green.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/batch-green-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
N=0 BAD=0
ok() { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL: %s\n' "$1" >&2; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 — wanted «$3» in:
$2" ;; esac; }
eq() { [ "$2" = "$3" ] && ok || bad "$1 — wanted «$2», got «$3»"; }

export FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp"
mkdir -p "$FLEET_CONF_DIR/global" "$TMPDIR/.claude-dash/fleets/o-r" "$TMPDIR/.claude-dash/fleets/o-x"
C="$TMPDIR/.claude-dash"
ALOG="$WORK/alerts"; MLOG="$WORK/members-calls"
cat > "$WORK/alert" <<EOF
#!/bin/bash
printf '%s\t%s\n' "\$2" "\$3" >> "$ALOG"
EOF
cat > "$WORK/members" <<EOF
#!/bin/bash
echo "\$1#\$2" >> "$MLOG"
[ -f "$WORK/members.out" ] && cat "$WORK/members.out"
EOF
cat > "$WORK/driven" <<EOF
#!/bin/bash
[ -f "$WORK/driven.out" ] && cat "$WORK/driven.out"
EOF
chmod +x "$WORK/alert" "$WORK/members" "$WORK/driven"
export FLEET_BATCH_GREEN_ALERT_CMD="$WORK/alert" FLEET_BATCH_GREEN_MEMBERS_CMD="$WORK/members" \
       FLEET_BATCH_GREEN_DRIVEN_CMD="$WORK/driven"
run() { OUT=$(bash "$G" "$@" 2>&1); RC=$?; [ -z "${DBG:-}" ] || printf "%s\n" "$OUT" >&2; }
said() { cat "$ALOG" 2>/dev/null | grep -c . | tr -d ' '; }
calls() { cat "$MLOG" 2>/dev/null | grep -c . | tr -d ' '; }
NOW=$(date +%s)
mark() {   # mark <epoch>
  mkdir -p "$FLEET_CONF_DIR/global/epic-running.d"
  printf 'epoch: %s\nttl: 2700\nepic: 50\nrepo: o/r\nsession: fleet\ntick: 3\n' "$1" \
    > "$FLEET_CONF_DIR/global/epic-running.d/o-r-50"
}

# --- A. no mark ----------------------------------------------------------------
run; eq "A: exit 0" 0 "$RC"; eq "A: nothing said" 0 "$(said)"; eq "A: no member read" 0 "$(calls)"
[ -e "$FLEET_CONF_DIR/global/batch-green.tsv" ] && bad "A: a book was written" || ok

# --- B. a stale batch with green members -----------------------------------------
mark $((NOW - 4000))
printf 'm\t#50\t\tThe batch\nm\t#51\t\tone\n' > "$C/fleets/o-r/issues"
printf 'o/r\t51\topen\no/r\t52\tOPEN\no/r\t53\topen\no/r\t54\tclosed\no/x\t7\topen\no/r\t55\topen\n' > "$WORK/members.out"
printf 'issue-51\t#151\tOPEN\t✓\tready\t\t\nissue-52\t#152\tOPEN\t✗\t\t\tci\nissue-53\t#153\tOPEN\t✓\tdraft\t\t\nissue-54\t#154\tOPEN\t✓\tready\t\t\nissue-55\t#155\tMERGED\t✓\t\tabc\t\n' > "$C/fleets/o-r/prmap"
printf 'issue-7\t#9\tOPEN\t✓\tready\t\t\n' > "$C/fleets/o-x/prmap"
run; eq "B: exit 0" 0 "$RC"
eq "B: one event" 1 "$(said)"
L=$(cat "$ALOG" 2>/dev/null)
has "B: kind batch-green" "$L" "batch-green"
has "B: names the batch" "$L" "o/r#50"
has "B: the title" "$L" "The batch"
has "B: two green (o/r #51 + cross-repo o/x #7)" "$L" "还有 2 张已全绿"
has "B: the PRs" "$L" "#151 #9"
case "$L" in *"#152"*|*"#153"*|*"#154"*|*"#155"*) bad "B: a non-green PR counted: $L" ;; *) ok ;; esac
eq "B: the book" "o/r#50	2" "$(cut -f1,3 "$FLEET_CONF_DIR/global/batch-green.tsv")"

# --- C. once per count; throttled ------------------------------------------------
run; eq "C: inside the throttle: no member read" 1 "$(calls)"; eq "C: silent" 1 "$(said)"
FLEET_BATCH_GREEN_SECS=0 run; eq "C: same count past the throttle: silent" 1 "$(said)"
printf 'issue-52\t#152\tOPEN\t✓\tready\t\t\n' >> "$C/fleets/o-r/prmap"
sed -i.bak '/^issue-52	#152	OPEN	✗/d' "$C/fleets/o-r/prmap"
FLEET_BATCH_GREEN_SECS=0 run; eq "C: a new count speaks" 2 "$(said)"
has "C: the new count" "$(tail -1 "$ALOG")" "还有 3 张已全绿"

# --- D. driven / fresh / unread --------------------------------------------------
: > "$ALOG"; rm -f "$FLEET_CONF_DIR/global/batch-green.tsv"
echo 'o/r#50:1/5' > "$WORK/driven.out"; FLEET_BATCH_GREEN_SECS=0 run; eq "D: a driver window (full ref)" 0 "$(said)"
echo '#50' > "$WORK/driven.out"; FLEET_BATCH_GREEN_SECS=0 run; eq "D: a driver window (#N)" 0 "$(said)"
rm -f "$WORK/driven.out"
mark "$NOW"; FLEET_BATCH_GREEN_SECS=0 run; eq "D: a fresh mark" 0 "$(said)"
mark $((NOW - 4000)); mv "$WORK/members.out" "$WORK/members.keep"
FLEET_BATCH_GREEN_SECS=0 run; eq "D: unread member list: nothing said" 0 "$(said)"
mv "$WORK/members.keep" "$WORK/members.out"
FLEET_BATCH_GREEN_SECS=0 run --dry-run; has "D: --dry-run prints" "$OUT" "would say:"; eq "D: --dry-run says nothing" 0 "$(said)"

# --- E. leaves the book; off -----------------------------------------------------
FLEET_BATCH_GREEN_SECS=0 run; eq "E: said once" 1 "$(said)"
mark "$NOW"; run
[ -e "$FLEET_CONF_DIR/global/batch-green.tsv" ] && bad "E: a batch no longer stale stays in the book" || ok
mark $((NOW - 4000)); : > "$ALOG"
FLEET_BATCH_GREEN=0 run; eq "E: off" 0 "$(said)"

printf '%d checks, %d failed\n' "$N" "$BAD"
[ "$BAD" = 0 ]
