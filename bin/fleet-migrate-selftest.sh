#!/bin/bash
# selftest-parts: 4
# fleet-migrate-selftest.sh — hermetic tests for bin/fleet-migrate.sh (issue #512:
# reopen a live session by close + `--resume` in a new window; since T550 it moves
# no session between subscriptions — the pool picks behind the credential proxy).
#
# Two layers:
#   1. PURE matrices, sourced: migrate_eligible (panels / hub / raw@FLEET_MAIN),
#      migrate_selected (--account / explicit; --limited / --idle / --all /
#      --stuck are retired, T546; --target-account too, T550).
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
#        fake claude under the token of the account it was NAMED (none: no token,
#        the login's own), so the token-truth verify step has something to read.
#      Cases: the hook path (new window, options carried, argv has --resume <sid>
#      + the interrupted-turn nudge, A → the own login verified), the stuck path
#      (a claude that ignores /exit is left alone, nothing typed), the no-hook path
#      (relaunch typed in place), --dry-run (nothing moves), whoami (truth heals a
#      stale stamp; a pool session answers 「本会话由池子挑」).
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-sections.sh"
selftest_sections 4
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

sel()   { ok; migrate_selected "$2" "$3" "$4" || fail "$1 — expected selected"; }
unsel() { ok; migrate_selected "$2" "$3" "$4" && fail "$1 — expected NOT selected"; }
#       desc                          mode     label wanted
sel   "account: match"                account  acctA acctA
unsel "account: other"                account  acctB acctA
unsel "account: unknown label"        account  ""    acctA
sel   "explicit: always"              explicit ""    ""
# The quota failover's and the pace rebalance's selectors are retired (T546):
# no mode selects, and the CLI refuses each with 「已不用」 (exit 2).
for m in limited idle all stuck; do unsel "$m: retired" "$m" acctA ""; done

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
# the transcript tail, rendered on start — on a --resume that re-renders the OLD
# account's wall onto the new pane (#870)
if (open(my $w, '<', "$ENV{FLEET_CC_SESSIONS_DIR}/../wall")) { print while <$w>; close $w }
# a background command this session started (issue #873): its pid is recorded
# for the test, and it outlives Claude's /exit unless the migrate stops it
if ($ENV{FAKE_BG} && !grep { $_ eq '--resume' } @ARGV) { my $c = fork; if (!$c) { exec 'sleep', '97' } open(my $b, '>', "$ENV{FLEET_CC_SESSIONS_DIR}/../bg.pid"); print $b "$c\n"; close $b }
# a command this session runs as its CHILD (= the Bash tool, issue #1474): the
# migrate-myself case runs fleet-migrate.sh from inside the target's own process tree
if ($ENV{FAKE_RUN_CMD} && !grep { $_ eq '--resume' } @ARGV) { my $c = fork; if (!$c) { exec '/bin/sh', '-c', $ENV{FAKE_RUN_CMD} } }
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
# runner-hook-bg: the hook runner whose Claude starts a background command (#873)
# — launched with --strict-mcp-config, as every fleet spawn is (FLEET_MCP_CONFIG),
# so the MCP half of the inventory reads the argv, never a ~/.claude.json the CI
# runner does not have
sed -e 's/FAKE_SID=/FAKE_BG=1 FAKE_SID=/' -e 's|claude.pl" </dev/tty|claude.pl" --strict-mcp-config </dev/tty|' \
  "$FB/runner-hook" > "$FB/runner-hook-bg"
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
# fake launcher (= fleet-claude.sh): log argv, run the fake claude on the NAMED account's token
cat > "$FB/launcher" <<EOS
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/launched"
tmux display-message -p -t "\$TMUX_PANE" '#{@launch}|#{@launch_receipt}|#{@launch_started}|#{@task}|#{@fleet_id}|#{@worktree}' >> "$WORK/launch-opts" 2>/dev/null
printf '%s\n%s\n' "\${FLEET_ACCOUNT_LABEL:-}" "\${FLEET_ACCOUNT_TARGET:-}" > "$WORK/manual-env"
export CLAUDE_CODE_OAUTH_TOKEN="\$(bash '$BIN/fleet-account.sh' token "\${FLEET_ACCOUNT_LABEL:-}")" FLEET_CC_SESSIONS_DIR="$FLEET_CC_SESSIONS_DIR"
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

mkdir -p "$WORK/wt1" "$WORK/wt2" "$WORK/wt3" "$WORK/wt4" "$WORK/wt5"
WALL="hit your weekly limit · resets Sep 25 at 7am (Asia/Shanghai)"
printf "  ⎿  You've %s\n" "$WALL" > "$WORK/wall"
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
# issue #936: w1's outcome already reached its parent (fleet-report-parent.sh
# stamps exactly this); w2 and w3 never reported. The move must hand each window
# back its OWN value, not a blanket clear.
TM set-window-option -t "$w1" @reported 1
# issue #2970: what the reapers read rides the move — w1 carries a role and a
# policy, w5 (below) carries neither and comes back a worker.
TM set-window-option -t "$w1" @fleet_role worker; TM set-window-option -t "$w1" @reap_policy merged
TM set-window-option -t "$w1" @epic 'acme/repo#7'
sleep 1.5
diag() { printf 'windows: %s\nlaunched: %s\ntyped: %s\n' "$(TM list-windows -t "$SESS" -F '#{window_id}:#{window_name}' | tr '\n' ' ')" "$(cat "$WORK/launched" 2>/dev/null)" "$(cat "$WORK/typed" 2>/dev/null)"; }

SP=$(TM display-message -p '#{socket_path}')

if selftest_section 1; then
# --- whoami: token truth (A) beats a wrong stamp, and heals it
TM set-window-option -t "$w1" @cc_account acctB
ok; [ "$(bash "$SCRIPT" whoami --session "$SESS" "$w1")" = acctA ] || fail "whoami must read the token (acctA) not the stamp (acctB)"
ok; [ "$(TM display-message -p -t "$w1" '#{@cc_account}')" = acctA ] || fail "whoami must heal the stale @cc_account stamp"

# --- whoami on a pool session (T550): the session names no account — the pool
# picks — so the answer says so; the hub's central route here (a separated login
# reads the proxy's `picks` the same way)
TM set-window-option -t "$w1" @cred_sid sid-pool; TM set-window-option -t "$w1" @cred_route central
ok; bash "$SCRIPT" whoami --session "$SESS" "$w1" | grep -q '^本会话由池子挑' || fail "whoami on a pool session must say the pool picks: $(bash "$SCRIPT" whoami --session "$SESS" "$w1" 2>&1)"
ok; [ "$(bash "$SCRIPT" whoami --verified --session "$SESS" "$w1")" = acctA ] || fail "whoami --verified still reads the token truth"
TM set-window-option -t "$w1" -u @cred_sid; TM set-window-option -t "$w1" -u @cred_route

# --- whoami with NO window id (issue #703)
# The bug: WIDS stayed empty, and the bare "${WIDS[@]}" is a FATAL unbound variable
# on macOS's bash 3.2 — so the one command an operator runs either side of a
# rotation ("which account is this session on?") died, while the paths that always
# had candidates looked fine. The contract now: default to the CALLER'S OWN pane;
# with no caller pane to read, a usage error — never a silent empty, which is the
# same bug with the crash filed off. portability-selftest.sh guards the SHAPE
# repo-wide; these guard the BEHAVIOUR.
ok; out=$(bash "$SCRIPT" whoami --session "$SESS" 2>"$WORK/w.err"); rc=$?
[ "$rc" = 2 ] || fail "whoami with no window and no pane context must exit 2, got $rc (out='$out' err='$(cat "$WORK/w.err")')"
ok; [ -z "$out" ] || fail "whoami must print NOTHING on stdout when it cannot resolve a window, got '$out'"
ok; grep -q 'no window to report on' "$WORK/w.err" || fail "whoami must say WHY it has no answer: $(cat "$WORK/w.err")"
ok; ! grep -qi 'unbound variable' "$WORK/w.err" || fail "whoami walked an empty array again (#703): $(cat "$WORK/w.err")"

# Inside a pane of THIS fleet ⇒ that pane's own window, in the same bare-label form.
P1=$(TM display-message -p -t "$w1" '#{pane_id}')
ok; [ "$(env TMUX="$SP,0,0" TMUX_PANE="$P1" bash "$SCRIPT" whoami 2>/dev/null)" = acctA ] \
  || fail "bare whoami inside a pane must report THAT window's account"

# Never across servers: pane ids are per-SERVER, so honouring $TMUX_PANE against a
# --session that is not the caller's own fleet would confidently name a window on
# the wrong machine-local server. Refuse instead.
ok; env TMUX="$SP,0,0" TMUX_PANE="$P1" bash "$SCRIPT" whoami --session "not-$SESS" >/dev/null 2>&1 \
  && fail "bare whoami must refuse when --session names a fleet other than the caller's"

# --- dry-run moves nothing
out=$(bash "$SCRIPT" --session "$SESS" --dry-run --account acctA)
rig_diag() {  # on failure: what the walk saw (CI-only failures are otherwise blind)
  printf '\n--account acctA: %s\nlimited-until acctA: %s (now %s)\nlist:\n%s\nwindows:\n%s\nps:\n%s\n' \
    "$(bash "$SCRIPT" --session "$SESS" --dry-run --account acctA 2>&1)" \
    "$(bash "$BIN/fleet-account.sh" limited-until acctA 2>&1)" "$(date +%s)" \
    "$(bash "$BIN/fleet-account.sh" list 2>&1)" \
    "$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name} state=#{@claude_state} raw=#{@raw} acct=#{@cc_account} pid=#{pane_pid}' 2>&1)" \
    "$(ps -axo pid=,ppid=,comm= 2>&1 | grep -E "claude|runner|perl" | head -8)"
}
ok; printf '%s' "$out" | grep -q 'would /exit' || fail "dry-run must print the plan: $out $(rig_diag)"
ok; [ ! -f "$WORK/launched" ] || fail "dry-run must not launch anything"
ok; TM display-message -p -t "$w1" '#{pane_pid}' >/dev/null 2>&1 || fail "dry-run must not close windows"

# --- the operator's pick of a destination is retired (T550)
out=$(bash "$SCRIPT" --session "$SESS" --target-account acctB "$w1" 2>&1); rc=$?
ok; [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '已不用' || fail "--target-account must answer 已不用 and exit 2 (rc $rc): $out"
ok; TM display-message -p -t "$w1" '#{pane_pid}' >/dev/null 2>&1 && [ ! -f "$WORK/launched" ] || fail '--target-account must touch nothing'

# --- the real thing: --account acctA moves w1 (hook), leaves w2 (stuck), relaunches w3 in place
out=$(bash "$SCRIPT" --session "$SESS" --account acctA 2>&1)
# w1: hook path → a NEW window named w1 in wt1, options carried, argv has --resume + nudge
nw1=$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="w1"{print $1}' | head -1)
ok; [ -n "$nw1" ] && [ "$nw1" != "$w1" ] || fail "w1 must be re-opened as a NEW window — $out $(diag)"
# (physical path: macOS reports /private/var/… for a /var/… mktemp dir)
ok; [ "$(cd "$(TM display-message -p -t "$nw1" '#{pane_current_path}')" && pwd -P)" = "$(cd "$WORK/wt1" && pwd -P)" ] || fail "new w1 must run in the same cwd (got $(TM display-message -p -t "$nw1" '#{pane_current_path}'))"
for opt in @raw=1 @worktree="$WORK/wt1" @origin=scratch-9 @claude_state=working; do
  ok; [ "$(TM display-message -p -t "$nw1" "#{${opt%%=*}}")" = "${opt#*=}" ] || fail "new w1 must carry ${opt%%=*}=${opt#*=} (got $(TM display-message -p -t "$nw1" "#{${opt%%=*}}"))"
done
for opt in @fleet_role=worker @reap_policy=merged '@epic=acme/repo#7'; do
  ok; [ "$(TM display-message -p -t "$nw1" "#{${opt%%=*}}")" = "${opt#*=}" ] || fail "#2970: new w1 must carry ${opt%%=*}=${opt#*=} (got '$(TM display-message -p -t "$nw1" "#{${opt%%=*}}")')"
done
ok; [ -n "$(TM display-message -p -t "$nw1" '#{@migrated_at}')" ] || fail "new w1 must be stamped @migrated_at"
# #870: the wall w1 left behind rides to the new window, and the copy its resume
# re-rendered there reads as a replay — the collector will not bench acctB on it
ok; [ "$(TM display-message -p -t "$nw1" '#{@migrated_banner}')" = "$WALL" ] || fail "new w1 must carry the wall it left as @migrated_banner (got '$(TM display-message -p -t "$nw1" '#{@migrated_banner}')')"
( . "$BIN/usage-lib.sh"
  b=$(TM capture-pane -p -S -200 -t "$nw1" | fleet_limit_banner)
  [ -n "$b" ] && fleet_banner_replayed "$b" "$(TM display-message -p -t "$nw1" '#{@migrated_banner}')" ) \
  || { ok; fail "the resumed pane's replayed wall must read as a replay: $(TM capture-pane -p -t "$nw1")"; }
ok; [ "$(TM display-message -p -t "$nw1" '#{history_size}')" = 0 ] || fail "new w1's scrollback must be cleared after the resume verified"
ok; grep -q -- '--resume sid-1111 Your previous turn was interrupted' "$WORK/launched" 2>/dev/null \
  || fail "the launcher must get --resume <sid> + the interrupted-turn nudge (launched: $(cat "$WORK/launched" 2>/dev/null))"
ok; printf '%s' "$out" | grep -q 'w1 .*acctA → own login' || fail "the report must verify A → the own login off the new process's token: $out"
# #936: a DELIVERED report survives the move — cleared, the resumed session's next
# Stop sends the parent a late "stopped" duplicate after its MERGED
ok; [ "$(TM display-message -p -t "$nw1" '#{@reported}')" = 1 ] \
  && printf 'case #936 reported: new w1 @reported=%s (was 1)\n' "$(TM display-message -p -t "$nw1" '#{@reported}')" \
  || fail "a window that already reported must keep @reported 1 after the move (got '$(TM display-message -p -t "$nw1" '#{@reported}')')"
# w2: stuck claude → left alone, still there, not launched
ok; TM display-message -p -t "$w2" '#{pane_pid}' >/dev/null 2>&1 || fail "a claude that ignores /exit must be left as is (window gone) — $out"
ok; printf '%s' "$out" | grep -q 'w2 .*did not exit' || fail "the stuck window must be reported: $out"
ok; ! grep -q 'sid-2222' "$WORK/launched" 2>/dev/null || fail "a stuck session must never be relaunched"
ok; [ -z "$(TM display-message -p -t "$w2" '#{@reported}')" ] \
  || fail "#936: a window left as is must not keep the move's @reported suppression — it would never report (got '$(TM display-message -p -t "$w2" '#{@reported}')')"
# w3: no hook → relaunch typed IN PLACE into the surviving shell, same window
ok; TM display-message -p -t "$w3" '#{pane_pid}' >/dev/null 2>&1 || fail "no-hook path must keep the window — $out $(diag)"
for _ in $(seq 1 20); do grep -q 'sid-3333' "$WORK/typed" 2>/dev/null && break; sleep 0.3; done
ok; grep -q -- "--resume 'sid-3333'" "$WORK/typed" 2>/dev/null || fail "no-hook path must type the resume line into the shell (typed: $(cat "$WORK/typed" 2>/dev/null))"
ok; [ "$(TM display-message -p -t "$w3" '#{@migrated_banner}')" = "$WALL" ] && [ -n "$(TM display-message -p -t "$w3" '#{@migrated_at}')" ] \
  || fail "no-hook path must stamp @migrated_at + @migrated_banner on the reused window"
ok; [ -z "$(TM display-message -p -t "$w3" '#{@reported}')" ] \
  || fail "#936: an unreported session relaunched in place still owes its report — @reported must be empty (got '$(TM display-message -p -t "$w3" '#{@reported}')')"
ok; printf '%s' "$out" | grep -q 'moved 2, skipped 1' || fail "summary must be 'moved 2, skipped 1': $out"

# --- the quota failover's and the pace rebalance's selectors are retired (T546)
for sel in --limited --idle --all --stuck "--from acctA" --quota-request "--target-account acctB"; do
  # shellcheck disable=SC2086  # "--from acctA" is two words on purpose
  out=$(bash "$SCRIPT" --session "$SESS" $sel 2>&1); rc=$?
  ok; [ "$rc" = 2 ] && printf '%s' "$out" | grep -q '已不用' || fail "$sel must answer 已不用 and exit 2 (rc $rc): $out"
done

fi

if [ "$SELFTEST_SECTION" = 4 ]; then
  # The first section already checks A -> B and the no-hook exit. Start here
  # with that resulting process layout, without repeating those migrations.
  TM respawn-pane -k -t "$w1" "$FB/runner-hook-b sid-1111"
  TM set-window-option -t "$w1" @cc_account acctB
  TM respawn-pane -k -t "$w3" "$FB/fakeshell"
  nw1=$w1
  sleep 1.5
fi
if selftest_section 4; then
# --- --force-bg (issue #873): a walled worker held by a background command,
# moved by hand. Rig: w5 on A with a live `sleep 97` child.
w5=$(spawn w5 runner-hook-bg sid-5555 "$WORK/wt5"); sleep 1.5
bgpid=$(cat "$WORK/bg.pid" 2>/dev/null)
ok; [ -n "$bgpid" ] && kill -0 "$bgpid" 2>/dev/null || fail "rig: w5's background command must be running (pid '$bgpid')"
out=$(bash "$SCRIPT" --session "$SESS" --dry-run --force-bg "$w5" 2>&1)
ok; printf '%s' "$out" | grep -q 'w5 .*\[acctA\] would /exit' || fail "--dry-run --force-bg must plan the named window: $out $(diag)"
ok; printf '%s' "$out" | grep -q "would stop 1 background command" && printf '%s' "$out" | grep -q "$bgpid  sleep 97" \
  || fail "--dry-run --force-bg must list the background command it would stop: $out"
ok; kill -0 "$bgpid" 2>/dev/null || fail "--dry-run must not stop anything"
: > "$WORK/launched"
out=$(bash "$SCRIPT" --session "$SESS" --force-bg "$w5" 2>&1)
ok; printf '%s' "$out" | grep -q 'w5 .*acctA → own login' || fail "--force-bg must move w5 off A: $out $(diag)"
nw5=$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="w5"{print $1}' | head -1)
ok; [ -n "$nw5" ] && [ "$nw5" != "$w5" ] && [ -z "$(TM display-message -p -t "$nw5" '#{@reported}')" ] \
  && printf 'case #936 unreported: new w5 @reported=%s (was empty)\n' "'$(TM display-message -p -t "$nw5" '#{@reported}')'" \
  || fail "#936: an unreported session's NEW window must have @reported empty (window '$nw5', got '$(TM display-message -p -t "$nw5" '#{@reported}')')"
ok; [ "$(TM display-message -p -t "$nw5" '#{@fleet_role}')" = worker ] && [ -z "$(TM display-message -p -t "$nw5" '#{@reap_policy}')" ] \
  || fail "#2970: a role-less window must come back @fleet_role worker with no invented policy (got '$(TM display-message -p -t "$nw5" '#{@fleet_role}')' / '$(TM display-message -p -t "$nw5" '#{@reap_policy}')')"
ok; printf '%s' "$out" | grep -q "stopped 1 background command" || fail "the move must report what it stopped: $out"
for _ in $(seq 1 20); do kill -0 "$bgpid" 2>/dev/null || break; sleep 0.3; done
ok; ! kill -0 "$bgpid" 2>/dev/null || fail "--force-bg must stop the background command Claude left running (pid $bgpid)"
ok; grep -q -- '--resume sid-5555 Your previous turn was interrupted.* Background commands terminated by migration .*forced this move.*sleep 97 (cwd ' "$WORK/launched" 2>/dev/null \
  || fail "the resume nudge must name the stopped command (launched: $(cat "$WORK/launched" 2>/dev/null))"
ok; [ "$(wc -l < "$WORK/launched" | tr -d ' ')" = 1 ] || fail "the nudge must stay ONE line (the no-hook branch types it): $(cat "$WORK/launched")"

# --- explicit window ids need no account filter: reopen w1 again.
: > "$WORK/launched"
out=$(bash "$SCRIPT" --session "$SESS" --nudge 'custom nudge' "$nw1" 2>&1)
ok; grep -q -- '--resume sid-1111 custom nudge' "$WORK/launched" 2>/dev/null || fail "--nudge must replace the default nudge (launched: $(cat "$WORK/launched"); out: $out)"
ok; printf '%s' "$out" | grep -q 'w1 .*→ own login' || fail "the explicit reopen must verify where it landed: $out"

# --- --model <m> (issue #524): a model-capped session is relaunched on the fallback
# model. The launcher gets --model BEFORE --resume (fleet-claude.sh then sees an
# explicit model and skips its FLEET_MODEL default), the default nudge names the
# MODEL cap rather than the subscription, and the report says which model.
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

fi

if selftest_section 2; then
# ============================================================================
# 3. the caller's OWN window (issue #1474)
# ============================================================================
# 2026-10-04: a scratch ran `fleet-migrate.sh a1` on itself from its own pane; the
# SessionEnd hook that closes the window killed the migrate with it — no new
# window, a closed-unlanded history row for a live session, six orphaned
# children. Now: refused (exit 3, window untouched) by either tell — the window
# $TMUX_PANE sits in, or the target's Claude among the caller's ancestors — and
# `--force-self` runs the move from a detached process that waits for the turn to
# end, so SessionEnd killing the caller's whole tree still leaves a new window.

# pure: pid_is_ancestor
ok; pid_is_ancestor 1 $$ || fail "pid_is_ancestor: pid 1 is everyone's ancestor"
ok; pid_is_ancestor $$ 1 && fail "pid_is_ancestor: a child is not an ancestor of pid 1"
ok; pid_is_ancestor $$ $$ && fail "pid_is_ancestor: a pid is not its own (strict) ancestor"
# (a background child, not $BASHPID — bash 3.2 has no BASHPID, issue #703's class)
sleep 30 & _kid=$!
ok; pid_is_ancestor $$ "$_kid" || fail "pid_is_ancestor: the shell is the ancestor of its own child"
kill "$_kid" 2>/dev/null; wait "$_kid" 2>/dev/null
ok; pid_is_ancestor x $$ && fail "pid_is_ancestor: a non-numeric pid is never an ancestor"
ok; pid_is_ancestor $$ '' && fail "pid_is_ancestor: an empty pid is never a descendant"

# rig: runner-hook with a command the fake claude runs as its child (Bash tool)
spawn_self() {  # <name> <sid> <cwd> <child-cmd|''> → window id
  local w
  w=$(TM new-window -d -t "$SESS": -n "$1" -c "$3" -P -F '#{window_id}' "FAKE_RUN_CMD='$4' $FB/runner-hook $2") || fail "spawn $1"
  TM set-window-option -t "$w" @raw 1; TM set-window-option -t "$w" @worktree "$3"
  TM set-window-option -t "$w" @claude_state working; TM set-window-option -t "$w" @cc_account acctA
  printf '%s' "$w"
}
cat > "$FB/self-refuse" <<EOS
#!/bin/sh
sleep 1
W=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
env -u TMUX_PANE bash '$SCRIPT' --session '$SESS' "\$W" >'$WORK/anc.out' 2>&1; echo \$? >'$WORK/anc.rc'
EOS
cat > "$FB/self-force" <<EOS
#!/bin/sh
sleep 1
W=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
FLEET_MIGRATE_SELF_IDLE_WAIT=40 bash '$SCRIPT' --force-self --session '$SESS' "\$W" >'$WORK/fs.out' 2>&1; echo \$? >'$WORK/fs.rc'
EOS
chmod +x "$FB/self-refuse" "$FB/self-force"
mkdir -p "$WORK/wt7" "$WORK/wt8" "$WORK/x-scratch-7" "$WORK/wt-kid"

# --- tell 1: the window $TMUX_PANE sits in. Refused, exit 3, nothing touched.
w7=$(spawn_self self7 sid-7777 "$WORK/wt7" ''); sleep 1.5
P7=$(TM display-message -p -t "$w7" '#{pane_id}')
cp7=$(fleet_pane_claude_pid "$w7" "$LBL" 2>/dev/null)
ok; [ -n "$cp7" ] || fail "rig: self7 must have a Claude ($(diag))"
: > "$WORK/launched"
out=$(env TMUX="$SP,0,0" TMUX_PANE="$P7" bash "$SCRIPT" "$w7" 2>&1); rc=$?
ok; [ "$rc" = 3 ] || fail "migrating the caller's own window must exit 3, got $rc: $out"
ok; printf '%s' "$out" | grep -q "CALLER'S OWN window" || fail "the refusal must say why: $out"
ok; printf '%s' "$out" | grep -q 'fleet-handoff' || fail "the refusal must point at the way out (hub / another session / fleet-handoff): $out"
ok; TM display-message -p -t "$w7" '#{pane_pid}' >/dev/null 2>&1 || fail "a refused self-move must leave the window alone"
ok; kill -0 "$cp7" 2>/dev/null || fail "a refused self-move must leave Claude running"
ok; [ ! -s "$WORK/launched" ] || fail "a refused self-move must launch nothing (launched: $(cat "$WORK/launched"))"
# the same window named by its PANE id is still the caller's own (normalised first)
out=$(env TMUX="$SP,0,0" TMUX_PANE="$P7" bash "$SCRIPT" "$P7" 2>&1); rc=$?
ok; [ "$rc" = 3 ] || fail "a pane-id target of the caller's own window must be refused too, got $rc: $out"
# --dry-run only says so, still prints the plan, exit 0
out=$(env TMUX="$SP,0,0" TMUX_PANE="$P7" bash "$SCRIPT" --dry-run "$w7" 2>&1); rc=$?
ok; [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "CALLER'S OWN window" && printf '%s' "$out" | grep -q 'would /exit' \
  || fail "--dry-run on the caller's own window must note it and still plan (rc $rc): $out"
# from ANOTHER pane of the same fleet it is an ordinary target (not refused): the
# plan prints with no self note
P1=$(TM display-message -p -t "$w2" '#{pane_id}')
out=$(env TMUX="$SP,0,0" TMUX_PANE="$P1" bash "$SCRIPT" --dry-run "$w7" 2>&1)
ok; printf '%s' "$out" | grep -q 'would /exit' && ! printf '%s' "$out" | grep -q "CALLER'S OWN" \
  || fail "another pane's migrate of self7 must not read as self: $out"

# --- tell 2: no $TMUX_PANE, but the target's Claude is this process's ANCESTOR
# (the migrate runs as the fake claude's child). Refused the same way.
w8=$(spawn_self self8 sid-8888 "$WORK/wt8" "$FB/self-refuse")
for _ in $(seq 1 40); do [ -s "$WORK/anc.rc" ] && break; sleep 0.5; done
ok; [ "$(cat "$WORK/anc.rc" 2>/dev/null)" = 3 ] \
  || fail "a migrate run from INSIDE the target's process tree (no \$TMUX_PANE) must exit 3 — rc='$(cat "$WORK/anc.rc" 2>/dev/null)' out: $(cat "$WORK/anc.out" 2>/dev/null) $(diag)"
ok; grep -q "CALLER'S OWN window" "$WORK/anc.out" || fail "the ancestry refusal must say why: $(cat "$WORK/anc.out")"
ok; TM display-message -p -t "$w8" '#{pane_pid}' >/dev/null 2>&1 || fail "the ancestry refusal must leave the window alone"
ok; ! grep -q 'sid-8888' "$WORK/launched" 2>/dev/null || fail "the ancestry refusal must launch nothing"

# --- --force-self: detached, waits for the turn, survives SessionEnd. self9 lives
# in a SCRATCH-keyed worktree and has a child (kid, @origin scratch-7) so the
# children's parent pointer can be checked after the move (part 3 of #1474).
kid=$(spawn kid runner-stuck sid-kid "$WORK/wt-kid"); TM set-window-option -t "$kid" @origin scratch-7
w9=$(spawn_self self9 sid-9999 "$WORK/x-scratch-7" "$FB/self-force")
: > "$WORK/launched"
for _ in $(seq 1 40); do [ -s "$WORK/fs.rc" ] && break; sleep 0.5; done
ok; [ "$(cat "$WORK/fs.rc" 2>/dev/null)" = 0 ] \
  || fail "--force-self must return 0 at once (the move is detached) — rc='$(cat "$WORK/fs.rc" 2>/dev/null)' out: $(cat "$WORK/fs.out" 2>/dev/null)"
ok; grep -q 'runs DETACHED' "$WORK/fs.out" || fail "--force-self must say the move is detached: $(cat "$WORK/fs.out")"
ok; grep -q 'detached 1' "$WORK/fs.out" || fail "the summary must count the detached move: $(cat "$WORK/fs.out")"
cp9=$(fleet_pane_claude_pid "$w9" "$LBL" 2>/dev/null)
ok; [ -n "$cp9" ] || fail "rig: self9 must have a Claude ($(diag))"
# while the caller's turn is running (@claude_state working) the detached move
# WAITS: no Escape, no /exit, nothing launched
sleep 4
ok; TM display-message -p -t "$w9" '#{pane_pid}' >/dev/null 2>&1 && kill -0 "$cp9" 2>/dev/null \
  || fail "a detached self-move must wait while the session is working — it closed the window / exited Claude early ($(diag))"
ok; ! grep -q 'sid-9999' "$WORK/launched" 2>/dev/null || fail "…and must not relaunch yet (launched: $(cat "$WORK/launched"))"
# the turn ends (the Stop hook marks `done`): /exit, the runner kills the window —
# the SessionEnd that killed the caller's whole tree in the incident — and a NEW
# window still opens, resumed
TM set-window-option -t "$w9" @claude_state "done"
LOG="$FLEET_CONF_DIR/fleets/$SESS/migrate-self.log"
nw9=''
for _ in $(seq 1 80); do
  nw9=$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk -v o="$w9" '$2=="self9" && $1!=o {print $1}' | head -1)
  [ -n "$nw9" ] && grep -q '✓ self9' "$LOG" 2>/dev/null && break
  sleep 0.5
done
ok; [ -n "$nw9" ] || fail "--force-self: a NEW self9 window must open after SessionEnd closed the old one — $(diag) log: $(cat "$LOG" 2>/dev/null)"
ok; ! kill -0 "$cp9" 2>/dev/null || fail "the old Claude (pid $cp9) must be gone after the move"
ok; grep -q -- '--resume sid-9999' "$WORK/launched" 2>/dev/null || fail "the detached move must resume the same session (launched: $(cat "$WORK/launched" 2>/dev/null))"
ok; [ "$(TM display-message -p -t "$nw9" '#{@worktree}')" = "$WORK/x-scratch-7" ] || fail "the new window must carry the worktree binding"
ok; grep -q '✓ self9 .*acctA → own login' "$LOG" 2>/dev/null || fail "the detached move must log its verified result: $(cat "$LOG" 2>/dev/null)"
ok; grep -q 'turn ended after' "$LOG" 2>/dev/null || fail "the detached move must log that it waited for the turn to end: $(cat "$LOG" 2>/dev/null)"
# part 3: the children's parent pointer. @origin is the KEY (scratch-7), never a
# window id, so the resumed window — same worktree, new id — IS the parent again:
# the dash's grouping, fleet_win_for_key and a child's report all resolve to it.
ok; [ "$(fleet_win_for_key scratch-7 "$LBL")" = "$nw9" ] \
  || fail "fleet_win_for_key scratch-7 must resolve to the resumed window $nw9 (got '$(fleet_win_for_key scratch-7 "$LBL")')"
rp=$(bash "$BIN/fleet-report-parent.sh" -L "$LBL" --win "$kid" --state blocked --summary 'kid is stuck' --dry-run 2>&1)
ok; printf '%s' "$rp" | grep -q "would send to scratch-7 ($nw9," \
  || fail "a child's report must address the RESUMED parent window $nw9: $rp"

fi

if selftest_section 3; then
# --- a Loop between rounds rides the move (issue #2189): its ScheduleWakeup lived
# in the process the /exit ends; the transcript says what it had pending, and the
# resume's first turn is `/loop <that input>` — the person's text whole, a quote
# included. A transcript with nothing pending ⇒ a bare resume, as before.
loop_tr() {  # <sid> <prompt> <delay> → a transcript holding ONE ScheduleWakeup, made now
  mkdir -p "$FLEET_CC_PROJECTS_DIR/loopproj"
  python3 - "$FLEET_CC_PROJECTS_DIR/loopproj/$1.jsonl" "$2" "$3" <<'PY'
import datetime, json, sys
t = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'timestamp': t, 'message': {'content': [{'type': 'tool_use', 'id': 'u0', 'name': 'ScheduleWakeup',
            'input': {'delaySeconds': int(sys.argv[3]), 'prompt': sys.argv[2]}}]}}) + '\n')
    f.write(json.dumps({'timestamp': t, 'toolUseResult': 'ok', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'u0'}]}}) + '\n')
PY
}
mkdir -p "$WORK/wtl" "$WORK/wtn"
loop_tr sid-loop "/loop check CI, it's slow" 1200
loop_tr sid-noloop "/loop gone" 1200
printf '' > "$FLEET_CC_PROJECTS_DIR/loopproj/sid-noloop.jsonl"     # nothing pending
wl=$(spawn wloop runner-hook sid-loop "$WORK/wtl"); wn=$(spawn wnoloop runner-hook sid-noloop "$WORK/wtn")
TM set-window-option -t "$wl" @claude_state 'done'; TM set-window-option -t "$wn" @claude_state 'done'
sleep 1.5
: > "$WORK/launched"
out=$(bash "$SCRIPT" --session "$SESS" "$wl" 2>&1)
for _ in $(seq 1 30); do grep -q 'sid-loop' "$WORK/launched" 2>/dev/null && break; sleep 0.5; done
ok; printf '%s' "$out" | grep -q "wloop ($wl): a pending Loop rides the resume: /loop check CI, it's slow" \
  || fail "a pending Loop must be named on the move: $out $(diag)"
ok; grep -qF -- "--resume sid-loop /loop check CI, it's slow" "$WORK/launched" 2>/dev/null \
  || fail "the resume's first turn must re-enter the Loop, its text whole (launched: $(cat "$WORK/launched" 2>/dev/null))"
out=$(bash "$SCRIPT" --session "$SESS" "$wn" 2>&1)
for _ in $(seq 1 30); do grep -q 'sid-noloop' "$WORK/launched" 2>/dev/null && break; sleep 0.5; done
ok; grep -qx -- "--resume sid-noloop" "$WORK/launched" 2>/dev/null \
  || fail "nothing pending ⇒ a bare resume, as before (launched: $(cat "$WORK/launched" 2>/dev/null)) $out"

# --- a hub task's session (claude-fleet#4974): its launch binding rides the
# reopen, stamped BEFORE the launcher runs (the launcher reads it at once), so the
# new window is the same executor the record names — never a fresh start the hub
# refuses (409, the session lost). Asked before the /exit: a binding the record
# no longer holds leaves the session running and launches nothing.
mkdir -p "$WORK/wtt"
wt9=$(spawn wtask runner-hook sid-task "$WORK/wtt")
TM set-window-option -t "$wt9" @claude_state 'done'
set -- @launch '{"task":"T9","v":1}' @launch_receipt '{"native_session":"sid-task"}' \
       @task T9 @task_flow 1 @fleet_id fid-task-9
while [ "$#" -ge 2 ]; do TM set-window-option -t "$wt9" "$1" "$2"; shift 2; done
printf '#!/bin/sh\necho "launch: task generation is terminal" >&2; exit 1\n' > "$FB/tcheck-no"
printf '#!/bin/sh\n[ "$2" = "%s" ] || { echo "launch: wrong window $2" >&2; exit 1; }\n' "$wt9" > "$FB/tcheck-ok"
chmod +x "$FB/tcheck-no" "$FB/tcheck-ok"
sleep 1.5
: > "$WORK/launched"; : > "$WORK/launch-opts"
out=$(FLEET_MIGRATE_TASK_CHECK="$FB/tcheck-no" bash "$SCRIPT" --session "$SESS" "$wt9" 2>&1)
ok; printf '%s' "$out" | grep -q "task binding: task generation is terminal — left running" \
  || fail "#4974: a binding the record no longer holds must leave the session running: $out"
ok; TM display-message -p -t "$wt9" '#{pane_pid}' >/dev/null 2>&1 && [ ! -s "$WORK/launched" ] \
  || fail "#4974: a refused task binding must close nothing and launch nothing ($(diag))"
out=$(FLEET_MIGRATE_TASK_CHECK="$FB/tcheck-ok" bash "$SCRIPT" --session "$SESS" "$wt9" 2>&1)
for _ in $(seq 1 30); do grep -q 'sid-task' "$WORK/launched" 2>/dev/null && break; sleep 0.5; done
nwt=$(TM list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="wtask"{print $1}' | head -1)
ok; [ -n "$nwt" ] && [ "$nwt" != "$wt9" ] || fail "#4974: the task session must reopen in a new window: $out $(diag)"
ok; grep -qx -- "--resume sid-task" "$WORK/launched" 2>/dev/null || fail "#4974: the same conversation resumes (launched: $(cat "$WORK/launched" 2>/dev/null))"
ok; [ "$(head -n 1 "$WORK/launch-opts")" = "{\"task\":\"T9\",\"v\":1}|{\"native_session\":\"sid-task\"}|1|T9|fid-task-9|$WORK/wtt" ] \
  || fail "#4974: the launcher must see the task binding already stamped (saw '$(head -n 1 "$WORK/launch-opts")')"
for opt in "@task=T9" "@task_flow=1" "@fleet_id=fid-task-9" "@launch_started=1"; do
  ok; [ "$(TM display-message -p -t "$nwt" "#{${opt%%=*}}")" = "${opt#*=}" ] \
    || fail "#4974: the reopened window must carry ${opt%%=*}=${opt#*=} (got '$(TM display-message -p -t "$nwt" "#{${opt%%=*}}")')"
done

# --- a renamed home session through a ver-stale reopen stays on the list (issue
# #3444): no issue, no repo, in $HOME, renamed by its person, kept (`keep`). The
# fleet version moved (待换新), it has been idle — fleet-migrate.sh --cfg-stale
# reopens it. After the reopen it is `done` again (waiting on its person), and the
# row producer, `fleet ls` and ⌘P (fleet_view.entries) must still list it, under
# the name it was given — before #3444 a done no-issue root went to 已结束, which
# `fleet ls` drops and ⌘P folds, so a live session vanished from both.
mkdir -p "$WORK/home"
NM='语音 demo 调研'
wh=$(TM new-window -d -t "$SESS": -n "$NM" -c "$WORK/home" -P -F '#{window_id}' "$FB/runner-hook sid-home") || fail "spawn home"
set -- @norepo 1 @norepo_sid sid-home @name_manual "$NM" @reap_policy keep @task_line '帮我调研语音 demo' \
       @fleet_role worker @agent_cfg fpX @agent_ver oldver @claude_state 'done' @claude_state_ts 1 @cc_account acctB
while [ "$#" -ge 2 ]; do TM set-window-option -t "$wh" "$1" "$2"; shift 2; done
mkdir -p "$FLEET_CONF_DIR/global"
printf 'claude fpX t\nver newver\n' > "$FLEET_CONF_DIR/global/agent-cfg.expected"
sleep 1.5
ok; why=$(FLEET_CFG_RESTART_IDLE=0 fleet_cfg_restart_why "$LBL" "$wh" 0) \
  || fail "rig: the home session must qualify for a ver-stale reopen (said '$why')"
: > "$WORK/launched"
out=$(FLEET_CFG_RESTART_IDLE=0 bash "$SCRIPT" --cfg-stale --session "$SESS" "$wh" 2>&1)
nwh=''
for _ in $(seq 1 30); do
  nwh=$(TM list-windows -t "$SESS" -F '#{window_id}	#{@norepo_sid}' | awk -F'\t' -v o="$wh" '$2=="sid-home" && $1!=o {print $1}' | head -1)
  [ -n "$nwh" ] && break; sleep 0.5
done
ok; [ -n "$nwh" ] || fail "#3444: the home session must be reopened in a new window — $out $(diag)"
ok; grep -q -- '--resume sid-home' "$WORK/launched" 2>/dev/null || fail "#3444: the reopen must resume the same conversation (launched: $(cat "$WORK/launched" 2>/dev/null))"
for opt in "@norepo=1" "@name_manual=$NM" "@reap_policy=keep" "@claude_state=done"; do
  ok; [ "$(TM display-message -p -t "$nwh" "#{${opt%%=*}}")" = "${opt#*=}" ] \
    || fail "#3444: the reopened home window must carry ${opt%%=*}=${opt#*=} (got '$(TM display-message -p -t "$nwh" "#{${opt%%=*}}")')"
done
ok; [ "$(TM display-message -p -t "$nwh" '#{window_name}')" = "$NM" ] \
  || fail "#3444: the reopen must keep the name its person gave it (got '$(TM display-message -p -t "$nwh" '#{window_name}')')"
# the list, read the way every reader reads it: the producer on this server
RS="$WORK/rowshim"; mkdir -p "$RS"
# the PATH it was made under, not this one: a tmux further down the PATH may be a
# shim that runs `tmux` again (bin/tmux-shim/tmux), and would find this one. `-u`:
# tmux's own output stays UTF-8 under LC_ALL=C below — only bash is byte-wise, the
# world of a login whose LANG names a locale the machine does not have
printf '#!/bin/sh\nPATH=%s exec tmux -u -L %s "$@"\n' "'$PATH'" "$LBL" > "$RS/tmux"; chmod +x "$RS/tmux"
rows=$(PATH="$RS:$PATH" FLEET_SESSION="$SESS" FLEET_ROWS_UNFOLD=1 LC_ALL=C bash "$BIN/tmux-dashboard-rows.sh" --rows 2>/dev/null)
hrow=$(printf '%s\n' "$rows" | awk -F'\037' -v w="$nwh" '$1 == w')
ok; [ -n "$hrow" ] || fail "#3444: the producer must list the reopened home session: $(printf '%s' "$rows" | tr '\037' '|')"
ok; printf '%s' "$hrow" | grep -qF "$NM" || fail "#3444: its row must wear its name: $(printf '%s' "$hrow" | tr '\037' '|')"
ok; [ -z "$(printf '%s\n' "$rows" | awk -F'\037' -v w="$nwh" '$1 == "hdr" && $2 == "ended" { e = 1 } e && $1 == w')" ] \
  || fail "#3444: a kept, done home session is not 已结束: $(printf '%s' "$rows" | tr '\037' '|')"
# no UTF-8 locale (LC_ALL=C above, an ssh forced command's world): every byte the
# readers get must still decode — a byte-sliced spinner glyph killed `fleet ls`
TM set-window-option -t "$nwh" @claude_state working
rows=$(PATH="$RS:$PATH" FLEET_SESSION="$SESS" FLEET_ROWS_UNFOLD=1 LC_ALL=C bash "$BIN/tmux-dashboard-rows.sh" --rows 2>/dev/null)
ok; printf '%s' "$rows" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
  || fail "#3444: the rows must be valid UTF-8 without a UTF-8 locale: $(printf '%s' "$rows" | tr '\037' '|' | od -c | head -5)"
TM set-window-option -t "$nwh" @claude_state 'done'
# `fleet ls`: the rows full_rows reads (the producer, every subtree open), through
# the CLI's own seam — the road a client takes is not this rig's to drive
PATH="$RS:$PATH" FLEET_SESSION="$SESS" python3 - "$BIN" "$SESS" > "$WORK/ls-rows.tsv" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("qo", sys.argv[1] + "/fleet-quickopen.py")
qo = importlib.util.module_from_spec(spec); spec.loader.exec_module(qo)
rows = qo.full_rows(sys.argv[2])
for r in rows or []:
    print("\t".join((r["key"], r["state"], r["glyph"], r["name"], r["node"], r["group"], r["badge"],
                     r["issue"], r["pr"], r["reap"], r["title"], r["repo"], r["ended"])))
PY
lsout=$(FLEET_SESSION_CLI_ROWS="$WORK/ls-rows.tsv" python3 "$BIN/fleet-session-cli.py" ls --json 2>&1)
ok; printf '%s' "$lsout" | grep -qF "\"name\": \"$NM\"" || fail "#3444: fleet ls must list it by its name: $lsout"
vout=$(PATH="$RS:$PATH" FLEET_SESSION="$SESS" python3 - "$BIN" "$SESS" <<'PY'
import importlib.util, sys
sys.path.insert(0, sys.argv[1])
spec = importlib.util.spec_from_file_location("fv", sys.argv[1] + "/fleet_view.py")
fv = importlib.util.module_from_spec(spec); spec.loader.exec_module(fv)
fv.view_row = lambda vid: {}
fv.view_fleet = lambda vid, row: sys.argv[2]
for e in fv.entries("v", hub=False):
    if e.get("kind") == "sess":
        print(e["group"], e["name"], sep="\t")
PY
)
ok; printf '%s\n' "$vout" | grep -qF "$NM" && ! printf '%s\n' "$vout" | grep -q "^ended	$NM" \
  || fail "#3444: ⌘P (fleet_view.entries) must list it outside 已结束: $vout"

fi

cleanup; trap - EXIT
printf 'fleet-migrate selftest: OK (%d checks)\n' "$CHECKS"
exit 0
