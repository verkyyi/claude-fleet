#!/bin/bash
# fleet-move-selftest.sh — hermetic end-to-end test for bin/fleet-move.sh +
# bin/fleet-move-remote.sh (issue #1067): move a session to "another login" on
# localhost. Two logins are not required — two HOMEs + two tmux sockets are:
#   • SOURCE: its own $HOME (srcfleet's conf, sessions registry, project dir),
#     its own tmux -L label.
#   • TARGET: a SEPARATE $HOME (dstfleet's conf + its own base checkout of the
#     SAME origin repo — "each login, its own local checkout" per
#     docs/ARCHITECTURE.md), its own tmux -L label.
#   • `ssh <user>@<host>` is shimmed to route ONLY the fixed fake target host
#     to `env HOME=<dst-home> … bash -c "$*"` — everything fleet-move.sh sends
#     over ssh (the %q-escaped remote_cmd strings, and the tar-pipe receive)
#     goes through this, so the escaping is exercised for real, never bypassed.
#   • `tmux -L <label>` is PATH-shimmed to a private `-S` socket per label —
#     isolation the way the fleet itself isolates (issue #159): never the live
#     server.
#   • a fake `claude` (issue #1067's own header borrows fleet-migrate-
#     selftest.sh's trick: a symlink to perl named `claude`, so its `comm` on
#     both macOS and Linux is `claude` like the real binary) registers itself
#     in the target/source registry and blocks on stdin until a line contains
#     `/exit` (or ignores stdin forever under FAKE_STUCK=1, for the SIGTERM-
#     fallback case).
#
# Cases:
#   1. --dry-run: prints the plan (incl. the target probe), moves nothing.
#   2. the real move: source pushes+stops+closes, target lands the pushed
#      branch and resumes — verified by reading BOTH sides' real state, not
#      the tool's own report.
#   3. refused:dirty — an uncommitted change in the source worktree — leaves
#      everything untouched on both sides.
#   4. --keep-source — target resumes, source window is left running.
#   5. a STUCK agent (ignores `/exit`) falls back to SIGTERM (the exact
#      recipe issue #1067 verified by hand) and still completes the move.
#   6. refused:not-found for a window handle that resolves to nothing live.
#   7. regression: a branch already checked out in ANOTHER worktree on the
#      target (a stale leftover) refuses with a clear reason instead of the
#      opaque git error this test caught by hand while writing case 2.
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
MOVE="$BIN/fleet-move.sh"; REMOTE="$BIN/fleet-move-remote.sh"
[ -f "$MOVE" ] && [ -f "$REMOTE" ] || { printf 'selftest: fleet-move.sh/-remote.sh not found\n' >&2; exit 2; }

CHECKS=0
fail() { printf 'fleet-move selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -z "$REAL_TMUX" ] || ! command -v perl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  printf 'fleet-move selftest: OK (%d checks; tmux/perl/git absent — e2e skipped)\n' "$CHECKS"; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-move-selftest.XXXXXX")" || exit 2
# Resolve symlinks NOW (macOS: $TMPDIR is under /var, itself a symlink to
# /private/var) — tmux's pane_current_path and `pwd -P` both report the
# resolved form, and every fixture path built below must match that or the
# transcript lookup silently misses (caught by hand while writing this test).
WORK="$(cd "$WORK" && pwd -P)"
LSRC="movesel-src-$$"; LDST="movesel-dst-$$"   # tmux -L labels = the fleet names
TO="dstuser@dsthost"                            # the fixed fake target host

# Sockets in a SHORT dir of their own (fleet-one-per-login-selftest.sh's own
# gotcha): a unix socket path is capped at ~104 bytes, and $TMPDIR alone (under
# which $WORK lives) already eats half of that on macOS.
SOCKD="$(mktemp -d /tmp/fmvsel.XXXXXX)" || exit 2

mkdir -p "$WORK/shim" "$WORK/src-home/projects" "$WORK/dst-home/projects" "$WORK/tmp"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then s="$SOCKD/sock.\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
exec "$REAL_TMUX" -S "$SOCKD/sock.none" "\$@"
EOF
# ssh shim: ONLY the fixed target host is routed anywhere — to a plain `bash
# -c` under the target's own HOME/launcher/PATH. Every remaining arg (after
# any `-o Key Value` pairs) is joined with real spaces, exactly like real ssh
# joins argv into one remote command string — so this exercises fleet-move.sh's
# OWN %q escaping end to end, never a hand-quoted stand-in for it.
cat > "$WORK/shim/ssh" <<EOF
#!/bin/bash
target=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift 2 ;;
    *) target="\$1"; shift; break ;;
  esac
done
[ "\$target" = "$TO" ] || { echo "ssh-shim: unknown host \$target" >&2; exit 255; }
exec env HOME="$WORK/dst-home" FLEET_CONF_DIR="$WORK/dst-home/.config/claude-fleet" PATH="$WORK/shim:$WORK/fakebin:\$PATH" \\
  FLEET_MOVE_LAUNCH="$WORK/fakebin/dst-launch" FLEET_MOVE_BOOT_WAIT=5 \\
  bash -c "\$*"
EOF
chmod +x "$WORK/shim/tmux" "$WORK/shim/ssh"

# --- fake claude (comm == claude, like fleet-migrate-selftest.sh) --------------
FB="$WORK/fakebin"; mkdir -p "$FB"
ln -s "$(command -v perl)" "$FB/claude"
cat > "$WORK/claude.pl" <<'EOS'
my $sid = $ENV{FAKE_SID} // 'nosid';
for (my $i = 0; $i < @ARGV; $i++) { $sid = $ARGV[$i+1] if $ARGV[$i] eq '--resume' }
open(my $r, '>', "$ENV{FLEET_CC_SESSIONS_DIR}/$$.json") or die; print $r "{\"pid\":$$,\"sessionId\":\"$sid\",\"cwd\":\"x\"}\n"; close $r;
$| = 1; print "fake claude sid=$sid pid=$$\n";
if ($ENV{FAKE_STUCK}) { sleep 1 while 1 }
while (my $l = <STDIN>) { exit 0 if $l =~ m{/exit} }
exit 0;
EOS
# source runner: NOT `exec`'d into a bare shell first — a plain subprocess call
# so the wrapper survives the fake claude's exit and explicitly closes its own
# window, standing in for the SessionEnd hook exactly like fleet-migrate-
# selftest.sh's runner-hook does. fleet-move.sh's own explicit kill-window
# (issue #1067's "never rely on the hook" gotcha) is what actually closes the
# window in cases where THIS wrapper is skipped (the stuck-agent case below).
cat > "$FB/src-runner" <<EOS
#!/bin/sh
export FAKE_SID="\$1" FLEET_CC_SESSIONS_DIR="$WORK/src-home/.claude/sessions"
mkdir -p "\$FLEET_CC_SESSIONS_DIR"
WIN=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
"$FB/claude" "$WORK/claude.pl" </dev/tty
tmux run-shell -b "tmux kill-window -t '\$WIN'"
EOS
# stuck runner: ignores /exit; never closes its own window either — this is
# what a genuinely wedged agent looks like, and fleet-move.sh must fall back
# to SIGTERM against the pid it already resolved, never against this wrapper.
cat > "$FB/src-runner-stuck" <<EOS
#!/bin/sh
export FAKE_SID="\$1" FAKE_STUCK=1 FLEET_CC_SESSIONS_DIR="$WORK/src-home/.claude/sessions"
mkdir -p "\$FLEET_CC_SESSIONS_DIR"
"$FB/claude" "$WORK/claude.pl" </dev/tty
EOS
cat > "$FB/dst-launch" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/dst-launched"
mkdir -p "$WORK/dst-home/.claude/sessions"
export FLEET_CC_SESSIONS_DIR="$WORK/dst-home/.claude/sessions"
exec "$FB/claude" "$WORK/claude.pl" "\$@"
EOS
chmod +x "$FB"/*

export PATH="$WORK/shim:$FB:$PATH"
# Run from a fleet pane, $TMUX would send fleet-lib's bare-tmux reads
# (_fleet_tmux, fleet_window_repo) to the LIVE server instead of this rig.
unset TMUX TMUX_PANE
# Each side's conf dir pinned explicitly (the gate exports its own shadow one);
# the ssh shim sets the target's, as a real login's fresh env would.
export FLEET_CONF_DIR="$WORK/src-home/.config/claude-fleet"
cleanup() {
  # Direct -S, matching the shim's own -L → -S mapping exactly — never via
  # PATH (a trap can fire after something has already restored/changed it).
  "$REAL_TMUX" -S "$SOCKD/sock.$LSRC" kill-server 2>/dev/null
  "$REAL_TMUX" -S "$SOCKD/sock.$LDST" kill-server 2>/dev/null
  rm -rf "$WORK" "$SOCKD"
}
trap cleanup EXIT; trap 'exit 130' INT TERM HUP

# Through the SAME PATH-shimmed `tmux` fleet-move.sh itself resolves (its `TM()`
# is bare `tmux -L "$SOCK"` too) — never the raw binary directly, or this
# harness and the script under test would land on two different servers.
TSRC() { tmux -L "$LSRC" "$@"; }
TDST() { tmux -L "$LDST" "$@"; }

# --- git fixture: one bare origin, cloned as each side's OWN base checkout ----
git init --bare -q "$WORK/origin.git"
git -C "$WORK/origin.git" symbolic-ref HEAD refs/heads/master
SEED="$WORK/tmp/seed"; git init -q -b master "$SEED"
git -C "$SEED" config user.email t@t.com; git -C "$SEED" config user.name Test
echo hello > "$SEED/README.md"; git -C "$SEED" add -A; git -C "$SEED" commit -q -m init
git -C "$SEED" remote add origin "$WORK/origin.git"; git -C "$SEED" push -q origin master
rm -rf "$SEED"

git clone -q "$WORK/origin.git" "$WORK/src-home/projects/repo"
git -C "$WORK/src-home/projects/repo" config user.email t@t.com
git -C "$WORK/src-home/projects/repo" config user.name Test
git clone -q "$WORK/origin.git" "$WORK/dst-home/projects/repo"
git -C "$WORK/dst-home/projects/repo" config user.email t@t.com
git -C "$WORK/dst-home/projects/repo" config user.name Test

# a worker worktree, one commit ahead of base — the common "move a live issue
# worker" case the recipe (#1067) was hand-verified against.
git -C "$WORK/src-home/projects/repo" worktree add -q -b issue-42 \
  "$WORK/src-home/projects/repo-issue-42" origin/master
git -C "$WORK/src-home/projects/repo-issue-42" config user.email t@t.com
git -C "$WORK/src-home/projects/repo-issue-42" config user.name Test
echo work > "$WORK/src-home/projects/repo-issue-42/work.txt"
git -C "$WORK/src-home/projects/repo-issue-42" add -A
git -C "$WORK/src-home/projects/repo-issue-42" commit -q -m 'do work'

# --- fleet confs (one-fleet-per-login: exactly one `fleets/<sess>/conf` each) --
mkdir -p "$WORK/src-home/.config/claude-fleet/fleets/$LSRC"
cat > "$WORK/src-home/.config/claude-fleet/fleets/$LSRC/conf" <<EOF
FLEET_REPO="o/n"
FLEET_MAIN="$WORK/src-home/projects/repo"
FLEET_BASE_BRANCH="master"
EOF
mkdir -p "$WORK/dst-home/.config/claude-fleet/fleets/$LDST"
cat > "$WORK/dst-home/.config/claude-fleet/fleets/$LDST/conf" <<EOF
FLEET_REPO="o/n"
FLEET_MAIN="$WORK/dst-home/projects/repo"
FLEET_BASE_BRANCH="master"
EOF
mkdir -p "$WORK/dst-home/.claude/fleet/bin"
ln -s "$REMOTE" "$WORK/dst-home/.claude/fleet/bin/fleet-move-remote.sh"
ln -s "$BIN/fleet-lib.sh" "$WORK/dst-home/.claude/fleet/bin/fleet-lib.sh"

TSRC new-session -d -s "$LSRC" -n hub -c "$WORK/src-home"
TDST new-session -d -s "$LDST" -n hub -c "$WORK/dst-home"

# spawn_source <handle> <name> <sid> <cwd> <issue> <state> <runner> → window id
spawn_source() {
  local hnd="$1" name="$2" sid="$3" cwd="$4" iss="$5" state="$6" runner="${7:-src-runner}"
  local w; w=$(TSRC new-window -d -t "$LSRC:" -n "$name" -c "$cwd" -P -F '#{window_id}' \
    "'$FB/$runner' '$sid'")
  TSRC set-window-option -t "$w" @issue "$iss"
  TSRC set-window-option -t "$w" @worktree "$cwd"
  TSRC set-window-option -t "$w" @repo o/n      # stamped at spawn, as every worker is (#789)
  TSRC set-window-option -t "$w" @claude_state "$state"
  TSRC set-window-option -t "$w" @wid "$hnd"
  printf '%s' "$w"
}
# put a session's transcript on disk at the path fleet-move.sh will look for
# (Claude Code's own encoding: / and . → -), so the tar-copy has something real.
seed_transcript() {
  local home="$1" cwd="$2" sid="$3"
  local pdir
  pdir="$home/.claude/projects/$(printf '%s' "$cwd" | tr '/.' '--')"
  mkdir -p "$pdir"
  printf '{"line":1}\n{"line":2}\n' > "$pdir/$sid.jsonl"
}
# win_alive <TSRC|TDST> <window> — 0 iff that window still exists. NEVER just
# the exit code: `display-message -t <gone-window-id>` exits 0 with EMPTY
# output on this tmux (caught by hand writing this test) — the same reason
# fleet-move.sh's own window_closed() reads the OUTPUT, not the exit code.
win_alive() { [ -n "$("$1" display-message -p -t "$2" '#{window_id}' 2>/dev/null)" ]; }

SID1="11111111-1111-1111-1111-111111111111"
WT1="$WORK/src-home/projects/repo-issue-42"

# ============================================================ case 1: --dry-run
seed_transcript "$WORK/src-home" "$WT1" "$SID1"
w1=$(spawn_source b1 issue-42 "$SID1" "$WT1" 42 working)
sleep 1
out=$(HOME="$WORK/src-home" "$MOVE" b1 --to "$TO" --session "$LSRC" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "dry-run should exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -q 'target ready' || fail "dry-run must probe the target: $out"
printf '%s\n' "$out" | grep -q 'ahead of master' || fail "dry-run must report the branch is ahead of base: $out"
win_alive TSRC "$w1" || fail "dry-run must not touch the source window"
git -C "$WORK/dst-home/projects/repo" worktree list | grep -q scratch && fail "dry-run must not provision anything on the target"
ok

# ============================================================ case 2: the real move
out=$(HOME="$WORK/src-home" FLEET_MOVE_EXIT_WAIT=10 FLEET_MOVE_CLOSE_WAIT=6 \
  "$MOVE" b1 --to "$TO" --session "$LSRC" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "the real move should exit 0, got $rc: $out"
win_alive TSRC "$w1" && fail "source window must be closed after a verified move: $out"
nw=$(TDST list-windows -F '#{window_id} #{@issue}' | awk '$2==42{print $1; exit}')
[ -n "$nw" ] || fail "no target window carries @issue=42 after the move: $out"
dwt=$(TDST display-message -p -t "$nw" '#{@worktree}')
[ -d "$dwt" ] || fail "target window's @worktree does not exist: $dwt"
[ "$(git -C "$dwt" branch --show-current)" = issue-42 ] || fail "target worktree is not on branch issue-42"
[ -f "$dwt/work.txt" ] || fail "target worktree is missing the pushed commit's file"
git -C "$WORK/origin.git" show-ref --verify --quiet refs/heads/issue-42 \
  || fail "the branch was never pushed to origin"
denc="$(printf '%s' "$dwt" | tr '/.' '--')"
[ -f "$WORK/dst-home/.claude/projects/$denc/$SID1.jsonl" ] || fail "transcript was not copied to the target"
ok

# ============================================================ case 3: refused:dirty
SID2="22222222-2222-2222-2222-222222222222"
WT2="$WORK/src-home/projects/repo-issue-43"
git -C "$WORK/src-home/projects/repo" worktree add -q -b issue-43 "$WT2" origin/master
git -C "$WT2" config user.email t@t.com; git -C "$WT2" config user.name Test
echo dirty > "$WT2/dirty.txt"          # UNCOMMITTED — never staged
seed_transcript "$WORK/src-home" "$WT2" "$SID2"
w2=$(spawn_source b2 issue-43 "$SID2" "$WT2" 43 working)
sleep 1
out=$(HOME="$WORK/src-home" "$MOVE" b2 --to "$TO" --session "$LSRC" 2>&1); rc=$?
[ "$rc" -eq 6 ] || fail "a dirty worktree must refuse with rc 6, got $rc: $out"
printf '%s\n' "$out" | grep -q 'refused:dirty' || fail "must name refused:dirty: $out"
win_alive TSRC "$w2" || fail "a refused move must leave the source window alone"
git -C "$WORK/dst-home/projects/repo" worktree list | grep -q issue-43 && fail "a refused move must not touch the target"
TSRC send-keys -t "$w2" -l '/exit'; TSRC send-keys -t "$w2" Enter; sleep 1
TSRC kill-window -t "$w2" 2>/dev/null
ok

# ============================================================ case 4: --keep-source
SID3="33333333-3333-3333-3333-333333333333"
WT3="$WORK/src-home/projects/repo-issue-44"
git -C "$WORK/src-home/projects/repo" worktree add -q -b issue-44 "$WT3" origin/master
git -C "$WT3" config user.email t@t.com; git -C "$WT3" config user.name Test
seed_transcript "$WORK/src-home" "$WT3" "$SID3"
w3=$(spawn_source b3 issue-44 "$SID3" "$WT3" 44 'done')
sleep 1
out=$(HOME="$WORK/src-home" "$MOVE" b3 --to "$TO" --session "$LSRC" --keep-source 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "--keep-source should still exit 0 on a verified move, got $rc: $out"
printf '%s\n' "$out" | grep -q 'SOURCE LEFT RUNNING' || fail "--keep-source must say the source is left running: $out"
win_alive TSRC "$w3" || fail "--keep-source must NOT close the source window"
nw3=$(TDST list-windows -F '#{window_id} #{@issue}' | awk '$2==44{print $1; exit}')
[ -n "$nw3" ] || fail "--keep-source must still resume on the target"
TSRC send-keys -t "$w3" -l '/exit'; TSRC send-keys -t "$w3" Enter; sleep 1
TSRC kill-window -t "$w3" 2>/dev/null
ok

# ============================================================ case 5: stuck agent → SIGTERM fallback
SID4="44444444-4444-4444-4444-444444444444"
WT4="$WORK/src-home/projects/repo-issue-45"
git -C "$WORK/src-home/projects/repo" worktree add -q -b issue-45 "$WT4" origin/master
git -C "$WT4" config user.email t@t.com; git -C "$WT4" config user.name Test
seed_transcript "$WORK/src-home" "$WT4" "$SID4"
w4=$(spawn_source b4 issue-45 "$SID4" "$WT4" 45 working src-runner-stuck)
sleep 1
out=$(HOME="$WORK/src-home" FLEET_MOVE_EXIT_WAIT=3 FLEET_MOVE_TERM_WAIT=6 FLEET_MOVE_CLOSE_WAIT=5 \
  "$MOVE" b4 --to "$TO" --session "$LSRC" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "a stuck agent must still complete via the SIGTERM fallback, got $rc: $out"
win_alive TSRC "$w4" && fail "a stuck agent, once SIGTERM'd, must still have its window closed: $out"
nw4=$(TDST list-windows -F '#{window_id} #{@issue}' | awk '$2==45{print $1; exit}')
[ -n "$nw4" ] || fail "the stuck-agent case must still resume on the target: $out"
ok

# ============================================================ case 6: refused:not-found
out=$(HOME="$WORK/src-home" "$MOVE" @9999 --to "$TO" --session "$LSRC" 2>&1); rc=$?
[ "$rc" -eq 3 ] || fail "a bogus window must refuse with rc 3, got $rc: $out"
printf '%s\n' "$out" | grep -q 'refused:not-found' || fail "must name refused:not-found: $out"
ok

# ============================================================ case 7: stale branch on target refuses cleanly
SID5="55555555-5555-5555-5555-555555555555"
WT5="$WORK/src-home/projects/repo-issue-46"
git -C "$WORK/src-home/projects/repo" worktree add -q -b issue-46 "$WT5" origin/master
git -C "$WT5" config user.email t@t.com; git -C "$WT5" config user.name Test
echo more >> "$WT5/README.md"; git -C "$WT5" commit -q -am more
git -C "$WT5" push -q -u origin issue-46
# simulate a stale leftover: the branch already checked out in ANOTHER worktree
# on the target (exactly what a previous aborted/failed move can leave behind)
git -C "$WORK/dst-home/projects/repo" fetch -q origin issue-46:refs/remotes/origin/issue-46
git -C "$WORK/dst-home/projects/repo" worktree add -q -b issue-46 "$WORK/dst-home/projects/stale" origin/issue-46
seed_transcript "$WORK/src-home" "$WT5" "$SID5"
w5=$(spawn_source b5 issue-46 "$SID5" "$WT5" 46 working)
sleep 1
out=$(HOME="$WORK/src-home" "$MOVE" b5 --to "$TO" --session "$LSRC" 2>&1); rc=$?
[ "$rc" -eq 8 ] || fail "a branch already checked out elsewhere on the target must refuse (failed:target), got $rc: $out"
printf '%s\n' "$out" | grep -qi 'already checked out\|failed:target' || fail "must name the stale-worktree reason: $out"
win_alive TSRC "$w5" || fail "a target-side refusal must never touch the source"
TSRC send-keys -t "$w5" -l '/exit'; TSRC send-keys -t "$w5" Enter; sleep 1
TSRC kill-window -t "$w5" 2>/dev/null
ok

printf 'fleet-move selftest: OK (%d checks)\n' "$CHECKS"
