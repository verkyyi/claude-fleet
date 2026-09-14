#!/bin/bash
# fleet-migrate-selftest.sh — hermetic tests for bin/fleet-migrate.sh (issue #512:
# move a live session onto the active account by close + `--resume` in a new window).
#
# Two layers:
#   1. PURE matrices, sourced: migrate_eligible (panels / hub / raw@FLEET_MAIN),
#      migrate_selected (--limited / --idle / --all / --account / explicit) and
#      migrate_noop (target == source is no move, #567; --model exempt).
#   2. END-TO-END on a DEDICATED tmux server on its own -L label (never the live
#      server), the way the fleet itself isolates (issue #159) — it must be -L,
#      not a -S shim, because fleet-migrate.sh targets servers as `tmux -L
#      <session>` and a trailing -L would override a shim's -S — with:
#      • a fake `claude` = a symlink to perl named claude (comm is `claude` like the
#        real binary) that registers itself in a scratch ~/.claude/sessions and
#        exits when a line containing `/exit` arrives on its tty;
#      • a runner that launches it under account A's token, then either kills its
#        own window (= the SessionEnd hook, #403) or drops to a fake shell that
#        RECORDS typed lines (= FLEET_CLOSE_ON_EXIT=0);
#      • a fake launcher (FLEET_MIGRATE_LAUNCH) that logs its argv and re-runs the
#        fake claude under the ACTIVE account's token, so the token-truth verify
#        step has something real to read.
#      Cases: the hook path (new window, options carried, argv has --resume <sid>
#      + the interrupted-turn nudge, account A → B verified), the stuck path (a
#      claude that ignores /exit is left alone, nothing typed), the no-hook path
#      (relaunch typed in place), --dry-run (nothing moves), whoami (truth heals a
#      stale stamp), and the every-account-benched case (#567: `--account <the
#      active one>` reports each window as already there and launches nothing).
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/fleet-migrate.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

CHECKS=0
fail() { printf 'fleet-migrate selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-migrate-selftest.XXXXXX")" || exit 2
# Everything the script reads from the environment is re-homed under $WORK:
export TMPDIR="$WORK"                                   # FLEET_C (account state, summaries)
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export FLEET_ACCOUNTS_DIR="$WORK/accounts"; mkdir -p "$FLEET_ACCOUNTS_DIR"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_CC_PROJECTS_DIR="$WORK/projects"; mkdir -p "$FLEET_CC_PROJECTS_DIR"
export FLEET_MAIN="$WORK/main"; mkdir -p "$FLEET_MAIN/.git"
export FLEET_MIGRATE_EXIT_WAIT=8 FLEET_MIGRATE_CLOSE_WAIT=6 FLEET_MIGRATE_BOOT_WAIT=8
unset TMUX TMUX_PANE FLEET_ACCOUNTS
printf 'tokA-secret\n' > "$FLEET_ACCOUNTS_DIR/acctA"; printf 'tokB-secret\n' > "$FLEET_ACCOUNTS_DIR/acctB"
chmod 600 "$FLEET_ACCOUNTS_DIR"/*

# ============================================================================
# 1. pure matrices
# ============================================================================
# shellcheck source=/dev/null
. "$SCRIPT"
command -v migrate_eligible >/dev/null 2>&1 || fail "migrate_eligible not defined after sourcing"
elig() { ok; migrate_eligible "$2" "$3" "$4" "$5" "$6" "$7" || fail "$1 — expected eligible"; }
inel() { ok; migrate_eligible "$2" "$3" "$4" "$5" "$6" "$7" && fail "$1 — expected NOT eligible"; }
#       desc                        name      hub raw cwd            main         sid
elig "issue worker"                issue-12  ""  ""  "$WORK/wt-12"  "$WORK/main" sid
elig "raw scratch in own worktree" thing     ""  1   "$WORK/s-3"    "$WORK/main" sid
elig "raw at FLEET_MAIN WITH sid"  thing     ""  1   "$WORK/main"   "$WORK/main" sid
inel "raw at FLEET_MAIN, no sid"   thing     ""  1   "$WORK/main/"  "$WORK/main" ""
inel "dash panel"                  dash      ""  ""  "$WORK/main"   "$WORK/main" sid
inel "plan hub"                    plan      ""  ""  "$WORK/main"   "$WORK/main" sid
inel "backlog panel"               backlog   ""  ""  "$WORK/main"   "$WORK/main" sid
inel "@hub pane"                   hub-claude 1  ""  "$WORK/wt"     "$WORK/main" sid

sel()   { ok; migrate_selected "$2" "$3" "$4" "$5" "$6" "$7" || fail "$1 — expected selected"; }
unsel() { ok; migrate_selected "$2" "$3" "$4" "$5" "$6" "$7" && fail "$1 — expected NOT selected"; }
#       desc                          mode     label state    active benched wanted
sel   "limited: benched, working"     limited  acctA working  acctB  1  ""
sel   "limited: benched, done"        limited  acctA "done"     acctB  1  ""
unsel "limited: not benched"          limited  acctA working  acctB  0  ""
unsel "limited: unknown account"      limited  ""    "done"     acctB  1  ""
sel   "idle: done off-active"         idle     acctA "done"     acctB  0  ""
sel   "idle: needs off-active"        idle     acctA needs    acctB  0  ""
unsel "idle: working off-active"      idle     acctA working  acctB  0  ""
unsel "idle: done ON active"          idle     acctB "done"     acctB  0  ""
sel   "all: working off-active"       all      acctA working  acctB  0  ""
unsel "all: on active"                all      acctB working  acctB  0  ""
sel   "account: match"                account  acctA "done"     acctB  0  acctA
unsel "account: other"                account  acctB "done"     acctB  0  acctA
sel   "explicit: always"              explicit ""    ""       ""     0  ""

# migrate_noop <label> <active> <model> <active-benched> — the #567 guard, every
# caller goes through it
noop() { ok; migrate_noop "$2" "$3" "$4" "$5" || fail "$1 — expected a no-op (no move available)"; }
move() { ok; migrate_noop "$2" "$3" "$4" "$5" && fail "$1 — expected a real move"; }
#      desc                                    label active model benched
noop "same account, no model"                 acctB acctB ""   0
move "different account"                      acctA acctB ""   0
move "same account but --model (#524)"        acctB acctB opus 0
move "ambient login → the pool"               ""    acctB ""   0
move "no pool at all (empty active)"          ""    ""    ""   0
noop "other account, but the target is benched" acctA acctB "" 1
move "target benched, --model still relaunches" acctB acctB opus 1

# ============================================================================
# 2. end-to-end on an isolated tmux server
# ============================================================================
REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -z "$REAL_TMUX" ] || ! command -v perl >/dev/null 2>&1; then
  printf 'fleet-migrate selftest: OK (%d checks; tmux/perl absent — e2e skipped)\n' "$CHECKS"; rm -rf "$WORK"; exit 0
fi
# Isolation the way the fleet ITSELF isolates (issue #159): a DEDICATED tmux
# server on its own -L LABEL, unique to this test run — never the live server,
# never a -S PATH shim. It must be -L, not -S: fleet-migrate.sh targets every
# server as `tmux -L "$(fleet_socket <session>)"` (fleet_socket echoes the
# session name), and a trailing -L overrides a shim's leading -S, so a -S rig
# would send migrate's keystrokes to the wrong server. So the label IS the
# session name the script is given, and every tmux call here names it too.
LBL="migtest-$$-$RANDOM"; SESS="$LBL"
TM() { tmux -L "$LBL" "$@"; }
FB="$WORK/fakebin"; mkdir -p "$FB"
ln -s "$(command -v perl)" "$FB/claude"
# the fake claude program: register in the scratch sessions dir, then read the tty
# until a line with /exit (or ignore stdin entirely when FAKE_STUCK=1).
cat > "$WORK/claude.pl" <<'EOS'
my $sid = $ENV{FAKE_SID} // 'nosid';
for (my $i = 0; $i < @ARGV; $i++) { $sid = $ARGV[$i+1] if $ARGV[$i] eq '--resume' }
open(my $r, '>', "$ENV{FLEET_CC_SESSIONS_DIR}/$$.json") or die; print $r "{\"pid\":$$,\"sessionId\":\"$sid\",\"cwd\":\"x\"}\n"; close $r;
open(my $t, '>', "$ENV{FLEET_CC_SESSIONS_DIR}/$$.tok") or die; print $t ($ENV{CLAUDE_CODE_OAUTH_TOKEN} // ''), "\n"; close $t;
$| = 1; print "fake claude sid=$sid\n";
if ($ENV{FAKE_STUCK}) { sleep 1 while 1 }
while (my $l = <STDIN>) { exit 0 if $l =~ m{/exit} }
exit 0;
EOS
# fake shell: records typed lines (the no-hook path types the relaunch here)
cat > "$FB/fakeshell" <<EOS
#!/bin/sh
while IFS= read -r l; do printf '%s\n' "\$l" >> "$WORK/typed"; done
EOS
# runner-hook: claude under account A, then kill its own window = SessionEnd hook.
# The kill goes through `run-shell -b` by WINDOW id exactly as session-end-
# hook.sh does (server-side, detached, dispatched while Claude is still alive in
# the real hook — here right after it exits; the window may already be gone by
# the time the job runs, which is fine and happens in production too).
cat > "$FB/runner-hook" <<EOS
#!/bin/sh
export CLAUDE_CODE_OAUTH_TOKEN=tokA-secret FAKE_SID="\$1" FLEET_CC_SESSIONS_DIR="$FLEET_CC_SESSIONS_DIR"
WIN=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
"$FB/claude" "$WORK/claude.pl" </dev/tty
tmux run-shell -b "tmux kill-window -t '\$WIN'"
EOS
# runner-hook-b: the hook runner, but under account B's token (the #567 case below)
sed 's/tokA-secret/tokB-secret/' "$FB/runner-hook" > "$FB/runner-hook-b"
# runner-nohook: same, but drops to the recording shell (FLEET_CLOSE_ON_EXIT=0)
cat > "$FB/runner-nohook" <<EOS
#!/bin/sh
export CLAUDE_CODE_OAUTH_TOKEN=tokA-secret FAKE_SID="\$1" FLEET_CC_SESSIONS_DIR="$FLEET_CC_SESSIONS_DIR"
"$FB/claude" "$WORK/claude.pl" </dev/tty
exec "$FB/fakeshell"
EOS
# runner-stuck: a claude that never exits on /exit
cat > "$FB/runner-stuck" <<EOS
#!/bin/sh
export CLAUDE_CODE_OAUTH_TOKEN=tokA-secret FAKE_SID="\$1" FAKE_STUCK=1 FLEET_CC_SESSIONS_DIR="$FLEET_CC_SESSIONS_DIR"
WIN=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
"$FB/claude" "$WORK/claude.pl" </dev/tty
tmux run-shell -b "tmux kill-window -t '\$WIN'"
EOS
# fake launcher (= fleet-claude.sh): log argv, run the fake claude on the ACTIVE token
cat > "$FB/launcher" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/launched"
export CLAUDE_CODE_OAUTH_TOKEN="\$(bash '$BIN/fleet-account.sh' token)" FLEET_CC_SESSIONS_DIR="$FLEET_CC_SESSIONS_DIR"
exec "$FB/claude" "$WORK/claude.pl" "\$@"
EOS
# token probe seam: the fake claude wrote its token next to its registry record
# (macOS `ps -E` shows no environment for Apple-signed binaries such as perl).
cat > "$FB/tokprobe" <<EOS
#!/bin/sh
cat "$FLEET_CC_SESSIONS_DIR/\$1.tok" 2>/dev/null
EOS
chmod +x "$FB"/*
export PATH="$FB:$PATH" FLEET_MIGRATE_LAUNCH="$FB/launcher" FLEET_TOKEN_PROBE="$FB/tokprobe"
cleanup() { tmux -L "$LBL" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT; trap 'exit 130' INT TERM HUP

# account state: A benched (limited), B active
bash "$BIN/fleet-account.sh" use acctB >/dev/null || fail "use acctB"
bash "$BIN/fleet-account.sh" mark-limited acctA >/dev/null
[ "$(bash "$BIN/fleet-account.sh" active)" = acctB ] || fail "rig: active should be acctB"

mkdir -p "$WORK/wt1" "$WORK/wt2" "$WORK/wt3" "$WORK/wt4"
TM new-session -d -s "$SESS" -n plan -c "$FLEET_MAIN" || fail "isolated server"
spawn() {  # <name> <runner> <sid> <cwd> → window id (a claude-bearing window with fleet options)
  local w
  w=$(TM new-window -d -t "$SESS": -n "$1" -c "$4" -P -F '#{window_id}' "$FB/$2 $3") || fail "spawn $1"
  TM set-window-option -t "$w" @raw 1; TM set-window-option -t "$w" @worktree "$4"
  TM set-window-option -t "$w" @claude_state working
  TM set-window-option -t "$w" @origin scratch-9; TM set-window-option -t "$w" @cc_account acctA
  printf '%s' "$w"
}
w1=$(spawn w1 runner-hook sid-1111 "$WORK/wt1")
w2=$(spawn w2 runner-stuck sid-2222 "$WORK/wt2")
w3=$(spawn w3 runner-nohook sid-3333 "$WORK/wt3")
sleep 1.5
diag() { printf 'windows: %s\nlaunched: %s\ntyped: %s\n' "$(TM list-windows -t "$SESS" -F '#{window_id}:#{window_name}' | tr '\n' ' ')" "$(cat "$WORK/launched" 2>/dev/null)" "$(cat "$WORK/typed" 2>/dev/null)"; }

# --- whoami: token truth (A) beats a wrong stamp, and heals it
TM set-window-option -t "$w1" @cc_account acctB
ok; [ "$(bash "$SCRIPT" whoami --session "$SESS" "$w1")" = acctA ] || fail "whoami must read the token (acctA) not the stamp (acctB)"
ok; [ "$(TM display-message -p -t "$w1" '#{@cc_account}')" = acctA ] || fail "whoami must heal the stale @cc_account stamp"

# --- dry-run moves nothing
out=$(bash "$SCRIPT" --session "$SESS" --dry-run --limited)
rig_diag() {  # on failure: what the walk saw (CI-only failures are otherwise blind)
  printf '\n--all: %s\nlimited-until acctA: %s (now %s)\nlist:\n%s\nwindows:\n%s\nps:\n%s\n' \
    "$(bash "$SCRIPT" --session "$SESS" --dry-run --all 2>&1)" \
    "$(bash "$BIN/fleet-account.sh" limited-until acctA 2>&1)" "$(date +%s)" \
    "$(bash "$BIN/fleet-account.sh" list 2>&1)" \
    "$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name} state=#{@claude_state} raw=#{@raw} acct=#{@cc_account} pid=#{pane_pid}' 2>&1)" \
    "$(ps -axo pid=,ppid=,comm= 2>&1 | grep -E "claude|runner|perl" | head -8)"
}
ok; printf '%s' "$out" | grep -q 'would /exit' || fail "dry-run must print the plan: $out $(rig_diag)"
ok; [ ! -f "$WORK/launched" ] || fail "dry-run must not launch anything"
ok; TM display-message -p -t "$w1" '#{pane_pid}' >/dev/null 2>&1 || fail "dry-run must not close windows"

# --- the real thing: --limited moves w1 (hook), leaves w2 (stuck), relaunches w3 in place
out=$(bash "$SCRIPT" --session "$SESS" --limited 2>&1)
# w1: hook path → a NEW window named w1 in wt1, options carried, argv has --resume + nudge
nw1=$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="w1"{print $1}' | head -1)
ok; [ -n "$nw1" ] && [ "$nw1" != "$w1" ] || fail "w1 must be re-opened as a NEW window — $out $(diag)"
# (physical path: macOS reports /private/var/… for a /var/… mktemp dir)
ok; [ "$(cd "$(TM display-message -p -t "$nw1" '#{pane_current_path}')" && pwd -P)" = "$(cd "$WORK/wt1" && pwd -P)" ] || fail "new w1 must run in the same cwd (got $(TM display-message -p -t "$nw1" '#{pane_current_path}'))"
for opt in @raw=1 @worktree="$WORK/wt1" @origin=scratch-9 @claude_state=working; do
  ok; [ "$(TM display-message -p -t "$nw1" "#{${opt%%=*}}")" = "${opt#*=}" ] || fail "new w1 must carry ${opt%%=*}=${opt#*=} (got $(TM display-message -p -t "$nw1" "#{${opt%%=*}}"))"
done
ok; [ -n "$(TM display-message -p -t "$nw1" '#{@migrated}')" ] || fail "new w1 must be stamped @migrated"
ok; grep -q -- '--resume sid-1111 Your previous turn was interrupted' "$WORK/launched" 2>/dev/null \
  || fail "the launcher must get --resume <sid> + the interrupted-turn nudge (launched: $(cat "$WORK/launched" 2>/dev/null))"
ok; printf '%s' "$out" | grep -q 'w1 .*acctA → acctB' || fail "the report must verify A → B off the new process's token: $out"
# w2: stuck claude → left alone, still there, not launched
ok; TM display-message -p -t "$w2" '#{pane_pid}' >/dev/null 2>&1 || fail "a claude that ignores /exit must be left as is (window gone) — $out"
ok; printf '%s' "$out" | grep -q 'w2 .*did not exit' || fail "the stuck window must be reported: $out"
ok; ! grep -q 'sid-2222' "$WORK/launched" 2>/dev/null || fail "a stuck session must never be relaunched"
# w3: no hook → relaunch typed IN PLACE into the surviving shell, same window
ok; TM display-message -p -t "$w3" '#{pane_pid}' >/dev/null 2>&1 || fail "no-hook path must keep the window — $out $(diag)"
for _ in $(seq 1 20); do grep -q 'sid-3333' "$WORK/typed" 2>/dev/null && break; sleep 0.3; done
ok; grep -q -- "--resume 'sid-3333'" "$WORK/typed" 2>/dev/null || fail "no-hook path must type the resume line into the shell (typed: $(cat "$WORK/typed" 2>/dev/null))"
ok; printf '%s' "$out" | grep -q 'moved 2, skipped 1' || fail "summary must be 'moved 2, skipped 1': $out"

# --- a second pass finds nothing benched (w1 is on B now; w2's truth is still A but
# it is stuck → it is reported again, not silently dropped)
out=$(bash "$SCRIPT" --session "$SESS" --idle 2>&1)
ok; printf '%s' "$out" | grep -q 'nothing to move' || fail "--idle after the move must find nothing (all working or on B): $out"

# --- explicit window ids need no account filter: move w1 (now on B) again, onto
# A — un-benched and pinned active for it (a move onto the account a window
# already runs on is a no-op since #567, see below).
bash "$BIN/fleet-account.sh" clear acctA >/dev/null; bash "$BIN/fleet-account.sh" use acctA >/dev/null
ok; [ "$(bash "$BIN/fleet-account.sh" active)" = acctA ] || fail "rig: active should be acctA now"
: > "$WORK/launched"
out=$(bash "$SCRIPT" --session "$SESS" --nudge 'custom nudge' "$nw1" 2>&1)
ok; grep -q -- '--resume sid-1111 custom nudge' "$WORK/launched" 2>/dev/null || fail "--nudge must replace the default nudge (launched: $(cat "$WORK/launched"); out: $out)"
ok; printf '%s' "$out" | grep -q 'w1 .*acctB → acctA' || fail "the explicit move must verify B → A: $out"

# --- --model <m> (issue #524): a model-capped session is relaunched on the fallback
# model. The launcher gets --model BEFORE --resume (fleet-claude.sh then sees an
# explicit model and skips its FLEET_MODEL default), the default nudge names the
# MODEL cap rather than the subscription, and the report says which model. w1 is
# on A and A is active: a same-account relaunch, which is exactly what --model
# is for — the #567 no-op guard must not catch it.
nw1=$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="w1"{print $1}' | head -1)
: > "$WORK/launched"
out=$(bash "$SCRIPT" --session "$SESS" --model opus "$nw1" 2>&1)
ok; grep -q -- '--model opus --resume sid-1111 ' "$WORK/launched" 2>/dev/null || fail "--model must reach the launcher ahead of --resume (launched: $(cat "$WORK/launched" 2>/dev/null); out: $out)"
ok; grep -q -- 'model usage limit' "$WORK/launched" 2>/dev/null || fail "--model must select the model-cap nudge (launched: $(cat "$WORK/launched" 2>/dev/null))"
# Issue #620: the nudge is the first thing the resumed model reads, after a
# transcript that may be entirely non-English — it has to say "keep that language".
ok; grep -q -- 'Continue replying in the language this session was using' "$WORK/launched" 2>/dev/null \
  || fail "the default nudge must carry the language rule (issue #620) (launched: $(cat "$WORK/launched" 2>/dev/null))"
ok; printf '%s' "$out" | grep -q -- 'on opus' || fail "the report must name the fallback model: $out"

# --- every account benched (issue #567). State: w1 on A (moved above), w2 on A
# (stuck), w3 has no Claude any more (its fake shell only records), plus a fresh
# w4 on B; active = A. Bench B first (pointer stays on A), then A: nothing is
# eligible, so the pointer stays on A — there is nowhere better. `--account
# acctA` — what the quota watch's ceiling branch fans out after benching A — must
# NOT close + resume w1/w2 onto A again: each is reported as already there (w2
# before any /exit is typed), nothing is launched, the windows survive, exit 0.
# And a benched window on ANOTHER benched account (w4 on B) is not bounced onto A
# either: nowhere to move.
nw1=$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="w1"{print $1}' | head -1)
w4=$(spawn w4 runner-hook-b sid-4444 "$WORK/wt4"); TM set-window-option -t "$w4" @cc_account acctB; sleep 1.5
bash "$BIN/fleet-account.sh" mark-limited acctB >/dev/null
bash "$BIN/fleet-account.sh" mark-limited acctA >/dev/null
ok; [ "$(bash "$BIN/fleet-account.sh" active)" = acctA ] || fail "rig: with A and B both benched, active must fall back to acctA (got $(bash "$BIN/fleet-account.sh" active))"
: > "$WORK/launched"
out=$(bash "$SCRIPT" --session "$SESS" --account acctA 2>&1); rc=$?
ok; [ "$rc" = 0 ] || fail "--account onto itself must still exit 0 (got $rc): $out"
ok; printf '%s' "$out" | grep -q 'w1 .*already on acctA — skipped' || fail "w1 (on A, active A) must be reported as already there: $out $(diag)"
ok; printf '%s' "$out" | grep -q 'w2 .*already on acctA — skipped' || fail "w2 (stuck, on A) must be skipped BEFORE any /exit is typed: $out $(diag)"
ok; printf '%s' "$out" | grep -q 'moved 0, skipped 2' || fail "summary must be 'moved 0, skipped 2': $out"
ok; [ ! -s "$WORK/launched" ] || fail "a same-account move must launch nothing (launched: $(cat "$WORK/launched"))"
ok; TM display-message -p -t "$nw1" '#{pane_pid}' >/dev/null 2>&1 || fail "a same-account move must not close the window — $out $(diag)"
# --dry-run explains the same skip, for --account and for --limited (w4: B → A, both benched)
out=$(bash "$SCRIPT" --session "$SESS" --dry-run --account acctA 2>&1)
ok; printf '%s' "$out" | grep -q 'already on acctA — skipped' || fail "--dry-run must print the same-account skip: $out"
ok; ! printf '%s' "$out" | grep -q 'would /exit' || fail "--dry-run must plan no /exit for a same-account move: $out"
out=$(bash "$SCRIPT" --session "$SESS" --dry-run --limited 2>&1)
ok; printf '%s' "$out" | grep -q 'w1 .*already on acctA — skipped' || fail "--limited must skip a benched window whose account is still the active one: $out"
ok; printf '%s' "$out" | grep -q 'w4 .*nowhere to move (acctB → acctA, benched too) — skipped' || fail "--limited must not bounce w4 from benched B onto benched A: $out $(diag)"
ok; ! printf '%s' "$out" | grep -q 'would /exit' || fail "--limited with every account benched must plan nothing: $out"
# …but the SAME windows move once another account is eligible again
bash "$BIN/fleet-account.sh" clear acctB >/dev/null
ok; [ "$(bash "$BIN/fleet-account.sh" active)" = acctB ] || fail "rig: B un-benched ⇒ active rotates to acctB (got $(bash "$BIN/fleet-account.sh" active))"
out=$(bash "$SCRIPT" --session "$SESS" --dry-run --account acctA 2>&1)
ok; printf '%s' "$out" | grep -q 'w1 .*\[acctA → acctB\] would /exit' || fail "with B eligible again, --account acctA must plan the move A → B: $out"

cleanup; trap - EXIT
printf 'fleet-migrate selftest: OK (%d checks)\n' "$CHECKS"
exit 0
