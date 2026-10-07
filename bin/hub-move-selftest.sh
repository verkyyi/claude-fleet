#!/bin/bash
# hub-move-selftest.sh — moving a session between machines THROUGH THE HUB
# (issue #1426, EPIC #1419 C7): bin/fleet-move.sh --via hub / --rebalance, the
# fleet_hub_move seam in bin/fleet-lib.sh, and the target half it ends in —
# bin/fleet-control-read.sh movein → bin/fleet-move-remote.sh movein.
#
# The rig is fleet-move-selftest.sh's: two HOMEs + two tmux sockets on one box,
# a fake `claude` (perl named claude), one bare origin both sides cloned. The
# difference is the transport: no ssh at all. FLEET_HUB_MOVE_CMD is a fake hub
# that answers `plan` from a script and, on `send`, does what the real hub +
# target agent do — hands the issue's lease to the target, drops the uploaded
# bundle in the target's move-in dir, and runs the target's REAL adapter
# (`fleet-control-read.sh movein`) under the target's HOME. So everything this
# repo ships for a hub move runs for real; the Go hub's half (lease hand-over,
# bundle access, the journalled write) is tokenledger/internal/api/
# fleet_move_test.go.
#
# The fake hub names the target fleet DST_UUID (the source's is its real
# fleet_uuid, read from the control database seeded below).
#
# Cases:
#   1. off: CCQUOTA_FLEET unset → `--via hub` refuses (usage, exit 2) and the
#      hub is never asked — a one-machine fleet behaves as it always has.
#   2. --dry-run: asks the hub's plan, touches nothing on either side.
#   3. refused:busy — a `working` session is never moved; nothing is sent.
#   4. the real move of an idle session: source pushed + stopped + closed; the
#      target window resumes the SAME session id on the SAME branch (commit
#      present), the transcript arrives byte-identical, the lease is the
#      target's, the bundle is gone from the move-in dir.
#   5. a target that fails (stale branch there) → failed:target, the lease is
#      given back to the source's worker_id.
#   6. --rebalance moves only `done` sessions, oldest-idle first, stops at a
#      LOCAL answer, and never touches a `working` one.
#   7. --rebalance past a REFUSED answer (#1513): that session is skipped (↷),
#      the next two move; summary `moved 2 · skipped 1 · left 1`.
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
MOVE="$BIN/fleet-move.sh"
[ -f "$MOVE" ] && [ -f "$BIN/fleet-move-remote.sh" ] && [ -f "$BIN/fleet-control-read.sh" ] \
  || { printf 'selftest: fleet-move.sh / fleet-move-remote.sh / fleet-control-read.sh not found\n' >&2; exit 2; }

CHECKS=0
fail() { printf 'hub-move selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -z "$REAL_TMUX" ] || ! command -v perl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 \
   || ! command -v python3 >/dev/null 2>&1; then
  printf 'hub-move selftest: OK (%d checks; tmux/perl/git/python3 absent — e2e skipped)\n' "$CHECKS"; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-move-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
LSRC="hubmv-src-$$"; LDST="hubmv-dst-$$"
SOCKD="$(mktemp -d /tmp/hmvsel.XXXXXX)" || exit 2
DST_UUID=bbbbbbbb-0000-4000-8000-000000000002

mkdir -p "$WORK/shim" "$WORK/src-home/projects" "$WORK/dst-home/projects" "$WORK/tmp" "$WORK/hub"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then s="$SOCKD/sock.\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
exec "$REAL_TMUX" -S "$SOCKD/sock.none" "\$@"
EOF
# A hub move never uses ssh: any call fails the test.
cat > "$WORK/shim/ssh" <<EOF
#!/bin/sh
echo "ssh \$*" >> "$WORK/ssh-called"; exit 255
EOF
chmod +x "$WORK/shim/tmux" "$WORK/shim/ssh"

FB="$WORK/fakebin"; mkdir -p "$FB"
ln -s "$(command -v perl)" "$FB/claude"
cat > "$WORK/claude.pl" <<'EOS'
my $sid = $ENV{FAKE_SID} // 'nosid';
for (my $i = 0; $i < @ARGV; $i++) { $sid = $ARGV[$i+1] if $ARGV[$i] eq '--resume' }
open(my $r, '>', "$ENV{FLEET_CC_SESSIONS_DIR}/$$.json") or die; print $r "{\"pid\":$$,\"sessionId\":\"$sid\",\"cwd\":\"x\"}\n"; close $r;
$| = 1; print "fake claude sid=$sid pid=$$\n";
while (my $l = <STDIN>) { exit 0 if $l =~ m{/exit} }
exit 0;
EOS
cat > "$FB/src-runner" <<EOS
#!/bin/sh
export FAKE_SID="\$1" FLEET_CC_SESSIONS_DIR="$WORK/src-home/.claude/sessions"
mkdir -p "\$FLEET_CC_SESSIONS_DIR"
WIN=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
"$FB/claude" "$WORK/claude.pl" </dev/tty
tmux run-shell -b "tmux kill-window -t '\$WIN'"
EOS
cat > "$FB/dst-launch" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/dst-launched"
mkdir -p "$WORK/dst-home/.claude/sessions"
export FLEET_CC_SESSIONS_DIR="$WORK/dst-home/.claude/sessions"
exec "$FB/claude" "$WORK/claude.pl" "\$@"
EOS

# --- the fake hub: `<cmd> plan|send …` ---------------------------------------
# plan answers the next line of $WORK/hub/plan (or REMOTE dsthost movable);
# send = hub + target agent: the lease goes to the target, the bundle lands in
# the target's move-in dir, and the target's REAL adapter runs it.
cat > "$FB/fakehub" <<EOS
#!/bin/bash
W="$WORK"; sub="\$1"; shift
printf '%s %s\n' "\$sub" "\$*" >> "\$W/hub/calls"
node='' bundle='' args=() pos=()
while [ \$# -gt 0 ]; do
  case "\$1" in
    --node) node="\$2"; shift 2 ;;
    --bundle) bundle="\$2"; shift 2 ;;
    --pushed) args+=(--pushed); shift ;;
    --handle) shift 2 ;;                       # a target picks its own handle
    --origin-wid) args+=(--origin-wid "\$2"); shift 2 ;;
    --*) args+=("\$1" "\$2"); shift 2 ;;
    *) pos+=("\$1"); shift ;;
  esac
done
repo="\${pos[0]}"; wid="\${pos[1]}"; key="\${wid#*/}"
if [ "\$sub" = plan ]; then
  line=''
  if [ "\$node" = auto ]; then line=\$(head -n1 "\$W/hub/plan" 2>/dev/null); [ -n "\$line" ] && sed -i.bak 1d "\$W/hub/plan"; fi
  printf '%s\n' "\${line:-REMOTE dsthost movable	chose dsthost (score 0.900)}"
  case "\$line" in REFUSED*) exit 4 ;; esac; exit 0
fi
[ -f "\$bundle" ] || { echo "FAILED BUNDLE	no bundle"; exit 5; }
cp "\$bundle" "\$W/hub/last-bundle.tar"
printf '%s\n' "$DST_UUID/\$key" > "\$W/hub/lease.\${key##*-}"
mid=\$(printf '%032d' "\$RANDOM")
D="\$W/dst-home/.config/claude-fleet/control/move-in"; mkdir -p "\$D"; cp "\$bundle" "\$D/\$mid.tar"
iss=''; case "\$key" in *issue-*) iss="\${key##*issue-}" ;; esac
out=\$(env -u TMUX HOME="\$W/dst-home" FLEET_CONF_DIR="\$W/dst-home/.config/claude-fleet" \\
  FLEET_MOVE_LAUNCH="$FB/dst-launch" FLEET_MOVE_BOOT_WAIT=5 FLEET_DISK_FLOOR_GB=0 \\
  bash "$BIN/fleet-control-read.sh" movein "$LDST" "\$mid" --repo "\$repo" \${iss:+--issue "\$iss"} \${args[@]+"\${args[@]}"} 2>"\$W/hub/target.err"); rc=\$?
printf '%s\n' "\$out" > "\$W/hub/target.out"
if [ "\$rc" -ne 0 ]; then
  printf '%s\n' "\$wid" > "\$W/hub/lease.\${key##*-}"     # given back
  printf 'FAILED EXECUTION_FAILED\ttarget exit %s: %s\n' "\$rc" "\$(tail -n1 "\$W/hub/target.err")"; exit 5
fi
IFS=\$'\t' read -r nw pid _ <<<"\$out"
printf 'MOVED dsthost %s %s\t%s\n' "\$nw" "\$pid" "$DST_UUID/\$key"
EOS
chmod +x "$FB"/*

export PATH="$WORK/shim:$FB:$PATH"
unset TMUX TMUX_PANE CCQUOTA_FLEET
export FLEET_CONF_DIR="$WORK/src-home/.config/claude-fleet"
export FLEET_HUB_MOVE_CMD="$FB/fakehub"
cleanup() {
  "$REAL_TMUX" -S "$SOCKD/sock.$LSRC" kill-server 2>/dev/null
  "$REAL_TMUX" -S "$SOCKD/sock.$LDST" kill-server 2>/dev/null
  rm -rf "$WORK" "$SOCKD"
}
trap cleanup EXIT; trap 'exit 130' INT TERM HUP
TSRC() { tmux -L "$LSRC" "$@"; }
TDST() { tmux -L "$LDST" "$@"; }

# --- git: one bare origin, each side's own base checkout -----------------------
git init --bare -q "$WORK/origin.git"
git -C "$WORK/origin.git" symbolic-ref HEAD refs/heads/master
SEED="$WORK/tmp/seed"; git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t.com; git -C "$SEED" config user.name Test
echo hello > "$SEED/README.md"; git -C "$SEED" add -A; git -C "$SEED" commit -q -m init
git -C "$SEED" remote add origin "$WORK/origin.git"; git -C "$SEED" push -q origin master
rm -rf "$SEED"
for side in src dst; do
  git clone -q "$WORK/origin.git" "$WORK/$side-home/projects/repo"
  git -C "$WORK/$side-home/projects/repo" config user.email t@t.com
  git -C "$WORK/$side-home/projects/repo" config user.name Test
done
# new_worktree <N> [ahead] → a source worktree on issue-<N>, one commit ahead
new_worktree() {
  local wt="$WORK/src-home/projects/repo-issue-$1"
  git -C "$WORK/src-home/projects/repo" worktree add -q -b "issue-$1" "$wt" origin/master
  git -C "$wt" config user.email t@t.com; git -C "$wt" config user.name Test
  echo "work $1" > "$wt/work-$1.txt"; git -C "$wt" add -A; git -C "$wt" commit -q -m "work $1"
  printf '%s' "$wt"
}

for side in src dst; do
  sess=$LSRC; [ "$side" = dst ] && sess=$LDST
  mkdir -p "$WORK/$side-home/.config/claude-fleet/fleets/$sess"
  cat > "$WORK/$side-home/.config/claude-fleet/fleets/$sess/conf" <<EOF
FLEET_REPO="o/n"
FLEET_MAIN="$WORK/$side-home/projects/repo"
FLEET_BASE_BRANCH="master"
EOF
done
# A fleet UUID needs the control database's machine id (fleet_uuid reads it).
mkdir -p "$FLEET_CONF_DIR/control"
python3 - "$FLEET_CONF_DIR/control/state.sqlite3" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
c.execute("INSERT INTO metadata VALUES ('machine_id', '12345678-1234-4234-8234-123456789abc')")
c.commit()
PY

TSRC new-session -d -s "$LSRC" -n hub -c "$WORK/src-home"
TDST new-session -d -s "$LDST" -n hub -c "$WORK/dst-home"

spawn_source() {  # <handle> <sid> <cwd> <issue> <state> [<state_ts>] → window id
  local w; w=$(TSRC new-window -d -t "$LSRC:" -n "issue-$4" -c "$3" -P -F '#{window_id}' "'$FB/src-runner' '$2'")
  TSRC set-window-option -t "$w" @issue "$4"
  TSRC set-window-option -t "$w" @worktree "$3"
  TSRC set-window-option -t "$w" @repo o/n
  TSRC set-window-option -t "$w" @claude_state "$5"
  TSRC set-window-option -t "$w" @claude_state_ts "${6:-$(date +%s)}"
  TSRC set-window-option -t "$w" @wid "$1"
  printf '%s' "$w"
}
# The transcript where Claude Code itself keeps it: every non-alphanumeric → `-`.
seed_transcript() {  # <cwd> <sid>
  local pdir
  pdir="$WORK/src-home/.claude/projects/$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$pdir/$2"
  printf '{"line":1,"sid":"%s"}\n{"line":2}\n' "$2" > "$pdir/$2.jsonl"
  printf 'sidecar\n' > "$pdir/$2/note.txt"
  printf '%s' "$pdir"
}
win_alive() { [ -n "$("$1" display-message -p -t "$2" '#{window_id}' 2>/dev/null)" ]; }
move() { HOME="$WORK/src-home" FLEET_MOVE_EXIT_WAIT=10 FLEET_MOVE_CLOSE_WAIT=6 "$MOVE" "$@" --session "$LSRC" 2>&1; }

SID1="11111111-1111-4111-8111-111111111111"
WT1=$(new_worktree 42); PD1=$(seed_transcript "$WT1" "$SID1")
w1=$(spawn_source b1 "$SID1" "$WT1" 42 'done')
sleep 1

# ============================================================ 1: hub module off
out=$(move b1 --via hub --to dsthost); rc=$?
[ "$rc" -eq 2 ] || fail "--via hub with CCQUOTA_FLEET unset must refuse (2), got $rc: $out"
printf '%s\n' "$out" | grep -q 'CCQUOTA_FLEET' || fail "the refusal must name CCQUOTA_FLEET: $out"
[ -f "$WORK/hub/calls" ] && fail "the hub must not be asked while the module is off"
win_alive TSRC "$w1" || fail "an off-module refusal must not touch the window"
ok
export CCQUOTA_FLEET=1

# ============================================================ 2: --dry-run
out=$(move b1 --via hub --to dsthost --dry-run); rc=$?
[ "$rc" -eq 0 ] || fail "dry-run should exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -q 'hub: REMOTE dsthost' || fail "dry-run must report the hub's plan: $out"
grep -q '^plan ' "$WORK/hub/calls" || fail "dry-run must ask the hub's plan"
grep -q '^send ' "$WORK/hub/calls" && fail "dry-run must never send"
win_alive TSRC "$w1" || fail "dry-run must not touch the source window"
git -C "$WORK/origin.git" show-ref --verify --quiet refs/heads/issue-42 && fail "dry-run must not push"
ok

# ============================================================ 3: refused:busy
SID2="22222222-2222-4222-8222-222222222222"
WT2=$(new_worktree 43); seed_transcript "$WT2" "$SID2" >/dev/null
w2=$(spawn_source b2 "$SID2" "$WT2" 43 working)
sleep 1
: > "$WORK/hub/calls"
out=$(move b2 --via hub --to dsthost); rc=$?
[ "$rc" -eq 11 ] || fail "a working session must refuse with 11, got $rc: $out"
printf '%s\n' "$out" | grep -q 'refused:busy' || fail "must name refused:busy: $out"
[ -s "$WORK/hub/calls" ] && fail "a busy refusal must not reach the hub: $(cat "$WORK/hub/calls")"
win_alive TSRC "$w2" || fail "a busy session's window must be left alone"
ok

# ============================================================ 4: the real move
out=$(move b1 --via hub --to dsthost); rc=$?
[ "$rc" -eq 0 ] || fail "the hub move should exit 0, got $rc: $out (target: $(cat "$WORK/hub/target.err" 2>/dev/null))"
printf '%s\n' "$out" | grep -q 'moved through the hub' || fail "must report the hub move: $out"
win_alive TSRC "$w1" && fail "the source window must close after a verified move"
[ -f "$WORK/ssh-called" ] && fail "a hub move must never use ssh: $(cat "$WORK/ssh-called")"
git -C "$WORK/origin.git" show-ref --verify --quiet refs/heads/issue-42 || fail "the branch was never pushed"
nw=$(TDST list-windows -F '#{window_id} #{@issue}' | awk '$2==42{print $1; exit}')
[ -n "$nw" ] || fail "no target window carries @issue=42"
dwt=$(TDST display-message -p -t "$nw" '#{@worktree}')
[ "$(git -C "$dwt" branch --show-current)" = issue-42 ] || fail "target worktree is not on issue-42"
[ "$(git -C "$dwt" rev-parse HEAD)" = "$(git -C "$WT1" rev-parse HEAD)" ] || fail "target branch tip differs from the source's"
[ -f "$dwt/work-42.txt" ] || fail "target worktree is missing the moved commit"
grep -q -- "--resume $SID1" "$WORK/dst-launched" || fail "the target must resume the SAME session id"
denc="$WORK/dst-home/.claude/projects/$(printf '%s' "$dwt" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
cmp -s "$PD1/$SID1.jsonl" "$denc/$SID1.jsonl" || fail "the transcript did not arrive byte-identical at $denc"
[ -f "$denc/$SID1/note.txt" ] || fail "the transcript's sidecar dir did not travel"
[ "$(cat "$WORK/hub/lease.42")" = "$DST_UUID/o-n:issue-42" ] || fail "the lease must now be the target's (keys carry the repo, #1939)" "$(cat "$WORK/hub/lease.42")"
[ -z "$(ls "$WORK/dst-home/.config/claude-fleet/control/move-in" 2>/dev/null)" ] || fail "the bundle must be removed once used"
grep -q '^send .* o/n [0-9a-f-]*/o-n:issue-42$' "$WORK/hub/calls" || fail "send must name the source worker_id"
ok

# ============================================================ 5: a target that fails
SID3="33333333-3333-4333-8333-333333333333"
WT3=$(new_worktree 44); seed_transcript "$WT3" "$SID3" >/dev/null
git -C "$WT3" push -q -u origin issue-44
git -C "$WORK/dst-home/projects/repo" fetch -q origin issue-44:refs/remotes/origin/issue-44
git -C "$WORK/dst-home/projects/repo" worktree add -q -b issue-44 "$WORK/dst-home/projects/stale" origin/issue-44
w3=$(spawn_source b3 "$SID3" "$WT3" 44 'done')
sleep 1
out=$(move b3 --via hub --to dsthost); rc=$?
[ "$rc" -eq 8 ] || fail "a failing target must be failed:target (8), got $rc: $out"
printf '%s\n' "$out" | grep -q 'failed:target' || fail "must name failed:target: $out"
src_wid=$(sed -n 's/^send .* o\/n \([^ ]*\)$/\1/p' "$WORK/hub/calls" | tail -n1)
[ "$(cat "$WORK/hub/lease.44")" = "$src_wid" ] || fail "a failed move must give the lease back to the source ($src_wid)"
TDST list-windows -F '#{@issue}' | grep -qx 44 && fail "a failed move must leave no window on the target"
ok

# ============================================================ 6: --rebalance
TSRC kill-window -t "$w3" 2>/dev/null
now=$(date +%s)
SID4="44444444-4444-4444-8444-444444444444"; WT4=$(new_worktree 45); seed_transcript "$WT4" "$SID4" >/dev/null
SID5="55555555-5555-4555-8555-555555555555"; WT5=$(new_worktree 46); seed_transcript "$WT5" "$SID5" >/dev/null
w4=$(spawn_source b4 "$SID4" "$WT4" 45 'done' $((now - 60)))     # idle 1 min
w5=$(spawn_source b5 "$SID5" "$WT5" 46 'done' $((now - 3600)))   # idle 1 h — goes first
sleep 1
: > "$WORK/hub/calls"
printf 'REMOTE dsthost movable\tchose dsthost (score 0.9)\nLOCAL srchost\tchose srchost (score 0.8)\n' > "$WORK/hub/plan"
out=$(move --rebalance --max 5); rc=$?
[ "$rc" -eq 0 ] || fail "rebalance should exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -q 'rebalance moved 1' || fail "rebalance must move exactly one (then LOCAL): $out"
win_alive TSRC "$w5" && fail "the longest-idle session must move first"
win_alive TSRC "$w4" || fail "rebalance must stop at the hub's LOCAL answer"
win_alive TSRC "$w2" || fail "rebalance must never touch a working session"
TDST list-windows -F '#{@issue}' | grep -qx 46 || fail "the moved session must be on the target"
grep -q '^plan --node auto ' "$WORK/hub/calls" || fail "rebalance must ask the hub with --node auto"
ok

# ============================================================ 7: --rebalance skips a REFUSED one (#1513)
# Three idle sessions; the hub refuses the longest-idle (no machine can take
# it). That one is skipped with a ↷ line — not a stop — and the next two move.
now=$(date +%s)
SID6="66666666-6666-4666-8666-666666666666"; WT6=$(new_worktree 47); seed_transcript "$WT6" "$SID6" >/dev/null
SID7="77777777-7777-4777-8777-777777777777"; WT7=$(new_worktree 48); seed_transcript "$WT7" "$SID7" >/dev/null
w6=$(spawn_source b6 "$SID6" "$WT6" 47 'done' $((now - 7200)))   # refused (oldest); b4 is still here from 6
w7=$(spawn_source b7 "$SID7" "$WT7" 48 'done' $((now - 60)))
sleep 1
: > "$WORK/hub/calls"
printf 'REFUSED NO_ELIGIBLE_NODE\tno node is eligible for this repo\n' > "$WORK/hub/plan"
out=$(move --rebalance --max all); rc=$?
[ "$rc" -eq 0 ] || fail "rebalance past a REFUSED should exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -q "↷ issue-47 ($w6): NO_ELIGIBLE_NODE — no node" || fail "the refused session must print a ↷ line: $out"
printf '%s\n' "$out" | grep -q 'stopping' && fail "a REFUSED answer must not stop the rebalance: $out"
printf '%s\n' "$out" | grep -q 'rebalance moved 2 · skipped 1 · left 1$' || fail "summary must read moved 2 · skipped 1 · left 1: $out"
win_alive TSRC "$w6" || fail "the refused session must stay"
win_alive TSRC "$w4" && fail "the second session must move"
win_alive TSRC "$w7" && fail "the third session must move"
[ "$(grep -c '^plan --node auto ' "$WORK/hub/calls")" -eq 3 ] || fail "the hub must be asked once per session: $(cat "$WORK/hub/calls")"
ok

printf 'hub-move selftest: OK (%d checks)\n' "$CHECKS"
