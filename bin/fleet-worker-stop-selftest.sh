#!/bin/bash
# fleet-worker-stop-selftest.sh — pins bin/fleet-worker-stop.sh (issue #834): the
# Fleet Hub's graceful stop addresses a worker by its DURABLE key (issue-N /
# scratch-N), re-resolves the window on the fleet at action time, and refuses
# whenever that resolution is not exactly one awake window.
#
# Real tmux on an ISOLATED socket (`-L fleetS` under a private TMUX_TMPDIR), a
# fake `claude` per pane (a shell loop that exits on `/exit`, widened into
# fleet_pane_claude_pid via FLEET_CLAUDE_COMM), a scratch conf estate and a
# scratch /fleet-history ledger. No live fleet, no gh, no model.
#
#   1. a stop by key exits THAT agent, records a closed-unlanded row, closes only
#      that window — the neighbour keeps its pid; no git command ran (no git here)
#   2. a key nobody holds       → refused:not-found (5), nothing touched
#   3. a key two windows hold   → refused:ambiguous (6), both survive
#   4. an old `sleeping` stamp (T548: read as empty) → stopped like any
#   5. a window at a bare shell → stopped:shell, window closed, row recorded
#   6. an agent that will not exit → failed:no-exit (7), window + pid survive
#   7. a scratch key resolves through @raw + @worktree, Codex gets its bracketed /exit
#   8. usage: a window NUMBER is not a key (2)
#   9. multi-repo: `<repo>:issue-N` stops only that repo's window (issue #1018)
#  10. fid:<@fleet_id> (issue #1873): a --no-repo window (no key) stops by identity,
#      no ledger row; a keyed worker stops by fid too, keyed row as by key; an
#      unknown fid → 5, a fid two windows carry → 6, a malformed one → 2; a
#      pool window / the hub never answer
#  11. dash-reap.sh on a no-repo row: done → the same graceful stop (reaped:full),
#      working → skip:live, untouched (no more refused:no-issue); no state at all
#      (issue #2505): skip:live while an agent runs there, reaped:full once it is
#      a test identity's (@test_identity) or no agent runs (@wrap_gone); the
#      agent's own OSC 7501 word (issue #2540) outranks the stamp — blocked keeps,
#      done stops — and no word, no state, no agent process stops as exited
#  12. a bare PATH (ssh / the peerlink: no tmux on it) still finds the window (#4822)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

# Short scratch name on purpose: a unix socket path is capped at ~104 bytes.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wstop.XXXXXX")" || exit 2
export TMUX_TMPDIR="$WORK/tmt"; mkdir -p "$TMUX_TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/fleetS"
mkdir -p "$WORK/main" "$WORK/wt-scratch-7" "$WORK/issue-1" "$WORK/issue-2"
: > "$FLEET_CONF_DIR/fleets/fleetS/conf"
fx_repo "$FLEET_CONF_DIR" "fleetS" acme/fleetS FLEET_MAIN="$WORK/main"
export FLEET_HISTORY_LEDGER="$WORK/ledger.tsv"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export CLAUDE_PROJECTS_DIR="$WORK/projects"; mkdir -p "$CLAUDE_PROJECTS_DIR"
export FLEET_CLAUDE_COMM='FLEETFAKECLAUDE'
# CLOSE_WAIT 0: a SHELLED pane models «no SessionEnd hook», so the wait for the hook
# to close its window can never end early — 0 goes straight to the same verdict
# (stopped:closed). Leg 7's BARE pane, which does die with its agent, keeps 1 s.
export FLEET_STOP_EXIT_WAIT=8 FLEET_STOP_CLOSE_WAIT=0
unset TMUX TMUX_PANE

st_tally
tf() { "$REAL_TMUX" -L fleetS "$@"; }
cleanup() { "$REAL_TMUX" -L fleetS kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# A fake agent: reads lines off its tty and exits on one ending in `/exit`
# (the Escape byte the stop sends first lands on the same line). The stubborn
# one ignores everything, like an agent wedged in a modal. Each is a SEPARATE
# process under the pane's `sh -c` — the token fleet_pane_claude_pid matches
# (FLEET_CLAUDE_COMM) sits in the CHILD's argv only, so the probe resolves the
# agent, not the pane shell, exactly as it resolves a real `claude` under the
# launcher's runner.
cat > "$WORK/fc" <<'EOF'
#!/bin/bash
exec bash -c ': FLEETFAKECLAUDE; while IFS= read -r l; do case "$l" in *"/exit"*) exit 0;; esac; done'
EOF
cat > "$WORK/fs" <<'EOF'
#!/bin/bash
exec bash -c ': FLEETFAKECLAUDE; while :; do sleep 300; done'
EOF
chmod +x "$WORK/fc" "$WORK/fs"
# The real launcher ends `…; exec $SHELL`, so after /exit the pane sits at a
# shell and only the SessionEnd hook (absent here) would close the window —
# SHELLED models that; BARE lets the pane die with the agent.
BARE="$WORK/fc"
SHELLED="$WORK/fc; while :; do sleep 300; done"
STUBBORN="$WORK/fs; while :; do sleep 300; done"
tf -f /dev/null new-session -d -s fleetS -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { printf 'selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }

# mkwin <name> <cmd> <issue|-> [raw-worktree] [lifecycle] [agent] → prints window id
mkwin() {
  local name="$1" cmd="$2" iss="$3" wt="${4:-}" lc="${5:-}" agent="${6:-}" wid
  wid=$(tf new-window -d -P -F '#{window_id}' -n "$name" -c "${wt:-$WORK}" "$cmd")
  [ "$iss" != - ] && tf set-window-option -t "$wid" @issue "$iss"
  [ -n "$wt" ] && { tf set-window-option -t "$wid" @raw 1; tf set-window-option -t "$wid" @worktree "$wt"; }
  [ -n "$lc" ] && tf set-window-option -t "$wid" @worker_lifecycle "$lc"
  [ -n "$agent" ] && tf set-window-option -t "$wid" @cc_agent "$agent"
  printf '%s' "$wid"
}
# agents_up <wid>… — wait (≤ 2 s) until every window's fake agent runs under its pane
agents_up() {
  local w p
  for w in "$@"; do
    p=$(tf display-message -p -t "$w" '#{pane_pid}')
    for _ in $(seq 1 20); do pgrep -P "$p" -f FLEETFAKECLAUDE >/dev/null && break; sleep 0.1; done
  done
}
pid_of() { (. "$BIN/fleet-lib.sh"; fleet_pane_claude_pid "$1" fleetS 2>/dev/null); }
# display-message -t <gone window> answers with an empty line and exit 0, so
# existence is a list-windows membership test, never a display-message probe.
has_win() { tf list-windows -t fleetS -F '#{window_id}' 2>/dev/null | grep -qx -- "$1"; }
run_stop() { out=$(bash "$BIN/fleet-worker-stop.sh" "$@" 2>"$WORK/err"); rc=$?; }
# bg_stop <tag> <cmd>… — run one stop / reap in the background, its out/rc in $WORK/<tag>.*;
# bg_read <tag> waits for it and sets out / rc (independent windows' graceful
# stops each wait ~2 s for /exit: they overlap)
bg_stop() { local t="$1"; shift; ( "$@" >"$WORK/$t.out" 2>"$WORK/$t.err"; echo $? >"$WORK/$t.rc" ) & eval "BG_$t=\$!"; }
bg_read() { eval "wait \$BG_$1"; out=$(cat "$WORK/$1.out"); rc=$(cat "$WORK/$1.rc"); }
ledger_has() { [ -f "$FLEET_HISTORY_LEDGER" ] && awk -F'\t' -v k="$1" '$2==k{f=1} END{exit !f}' "$FLEET_HISTORY_LEDGER"; }

# --- 1. stop by key: exits that agent, closes that window, neighbour untouched --
w1=$(mkwin one "$SHELLED" 1); w2=$(mkwin two "$SHELLED" 2)
agents_up "$w1" "$w2"
p1=$(pid_of "$w1"); p2=$(pid_of "$w2")
[ -n "$p1" ] && [ -n "$p2" ] || st_miss "fixture: fake agents not resolved under $w1/$w2" "p1=$p1 p2=$p2"
run_stop fleetS issue-1
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || st_miss "1: expected stopped:closed/0" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w1" && st_miss "1: window $w1 still exists after the stop"
has_win "$w2" || st_miss "1: neighbour window $w2 was closed"
kill -0 "$p1" 2>/dev/null && st_miss "1: agent pid $p1 still alive after /exit"
kill -0 "$p2" 2>/dev/null || st_miss "1: neighbour agent pid $p2 died"
ledger_has 1 || st_miss "1: no closed-unlanded ledger row keyed 1" "$(cat "$FLEET_HISTORY_LEDGER" 2>/dev/null)"
ledger_has 2 && st_miss "1: a row was recorded for the neighbour"

# --- 6. an agent that will not exit — its 2 s wait runs beside legs 2–5 (it
#        writes no row and touches no other window); read back before leg 7 ------
w6=$(mkwin six "$STUBBORN" 6); agents_up "$w6"
p6=$(pid_of "$w6")
( FLEET_STOP_EXIT_WAIT=2 bash "$BIN/fleet-worker-stop.sh" fleetS issue-6 >"$WORK/out6" 2>"$WORK/err6"; echo $? >"$WORK/rc6" ) &
leg6=$!

# --- 2. a key nobody holds -------------------------------------------------------
run_stop fleetS issue-9
[ "$rc" = 5 ] && [ "$out" = refused:not-found ] || st_miss "2: expected refused:not-found/5" "rc=$rc out=$out"
has_win "$w2" || st_miss "2: a not-found stop closed a window"

# --- 3. a key two windows hold ---------------------------------------------------
w3a=$(mkwin three-a "$SHELLED" 3); w3b=$(mkwin three-b "$SHELLED" 3); agents_up "$w3a" "$w3b"
run_stop fleetS issue-3
[ "$rc" = 6 ] && [ "$out" = refused:ambiguous ] || st_miss "3: expected refused:ambiguous/6" "rc=$rc out=$out"
has_win "$w3a" && has_win "$w3b" || st_miss "3: an ambiguous stop closed a window"

# --- 4. an old `sleeping` stamp refuses nothing since hibernation went (T548) -----
w4=$(mkwin four "$SHELLED" 4 "" sleeping); agents_up "$w4"
run_stop fleetS issue-4
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || st_miss "4: an old sleeping stamp must stop like any" "rc=$rc out=$out"
has_win "$w4" && st_miss "4: window $w4 still exists after the stop"

# --- 5. a window at a bare shell (no agent under the pane) -----------------------
w5=$(mkwin five 'while :; do sleep 300; done' 5); sleep 0.3
run_stop fleetS issue-5
[ "$rc" = 0 ] && [ "$out" = stopped:shell ] || st_miss "5: expected stopped:shell/0" "rc=$rc out=$out"
has_win "$w5" && st_miss "5: shell-only window $w5 survived the stop"
ledger_has 5 || st_miss "5: no ledger row for the shell-only stop"

wait "$leg6"; out=$(cat "$WORK/out6"); rc=$(cat "$WORK/rc6")
[ "$rc" = 7 ] && [ "$out" = failed:no-exit ] || st_miss "6: expected failed:no-exit/7" "rc=$rc out=$out"
has_win "$w6" || st_miss "6: window of a still-running agent was closed"
kill -0 "${p6:-0}" 2>/dev/null || st_miss "6: a stop that reported no-exit killed the agent"

# --- 7. scratch key via @raw + @worktree (pane dies with the agent, as when a
#        hook closed it: stopped:exit — or stopped:closed where tmux never noticed
#        the pane die (tmux 3.4 on Linux loses SIGCHLD, #781) — row recorded either
#        way); Codex bracketed /exit --------------------------------------------
w7=$(mkwin scratch-7 "$BARE" - "$WORK/wt-scratch-7"); w8=$(mkwin eight "$SHELLED" 8 "" "" codex)
agents_up "$w7" "$w8"
bg_stop s7 env FLEET_STOP_CLOSE_WAIT=1 bash "$BIN/fleet-worker-stop.sh" fleetS scratch-7
bg_stop s8 bash "$BIN/fleet-worker-stop.sh" fleetS issue-8
bg_read s7
case "$rc:$out" in 0:stopped:exit|0:stopped:closed) ;; *) st_miss "7: scratch key expected stopped:exit|closed/0" "rc=$rc out=$out err=$(cat "$WORK/s7.err")" ;; esac
has_win "$w7" && st_miss "7: scratch window survived"
ledger_has scratch-7 || st_miss "7: no ledger row keyed scratch-7" "$(cat "$FLEET_HISTORY_LEDGER" 2>/dev/null)"
bg_read s8
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || st_miss "7: codex expected stopped:closed/0" "rc=$rc out=$out"
has_win "$w8" && st_miss "7: codex window survived"

# --- 8. usage: a window number / index is not a key ------------------------------
refuse_all() {   # refuse_all <leg> <arg>… — each a usage refusal (2), run at once
  local leg="$1" i=0 bad p pids=""; shift
  for bad in "$@"; do i=$((i + 1))
    ( bash "$BIN/fleet-worker-stop.sh" fleetS "$bad" >"$WORK/u$i" 2>&1; echo $? >"$WORK/u$i.rc" ) &
    pids="$pids $!"
  done
  for p in $pids; do wait "$p"; done; i=0
  for bad in "$@"; do i=$((i + 1))
    [ "$(cat "$WORK/u$i.rc")" = 2 ] || st_miss "$leg: '$bad' should be a usage refusal (2)" "rc=$(cat "$WORK/u$i.rc") out=$(cat "$WORK/u$i")"
  done
}
refuse_all 8 "@12" "12" "issue-" "issue-x" "scratch-0"
has_win "$w2" || st_miss "8: a usage refusal closed a window"

# --- 10. fid:<@fleet_id> (issue #1873) -------------------------------------------
F1=11111111-1111-4111-8111-111111111111; F2=22222222-2222-4222-8222-222222222222
F3=33333333-3333-4333-8333-333333333333; F4=44444444-4444-4444-8444-444444444444
w10=$(mkwin daily-x "$SHELLED" -); tf set-window-option -t "$w10" @norepo 1
tf set-window-option -t "$w10" @fleet_id "$F1"
w10n=$(mkwin daily-y "$SHELLED" -); tf set-window-option -t "$w10n" @norepo 1
tf set-window-option -t "$w10n" @fleet_id "$F2"
agents_up "$w10" "$w10n"
p10=$(pid_of "$w10"); p10n=$(pid_of "$w10n")
rows0=$(wc -l < "$FLEET_HISTORY_LEDGER" 2>/dev/null | tr -d ' ')
run_stop fleetS "fid:$F1"
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || st_miss "10: no-repo by fid expected stopped:closed/0" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w10" && st_miss "10: no-repo window survived its fid stop"
kill -0 "${p10:-0}" 2>/dev/null && st_miss "10: no-repo agent still alive after /exit"
has_win "$w10n" || st_miss "10: the other no-repo window was closed"
kill -0 "${p10n:-0}" 2>/dev/null || st_miss "10: the other no-repo agent died"
[ "$(wc -l < "$FLEET_HISTORY_LEDGER" 2>/dev/null | tr -d ' ')" = "$rows0" ] \
  || st_miss "10: a no-repo stop wrote a ledger row" "$(tail -1 "$FLEET_HISTORY_LEDGER")"
run_stop fleetS "fid:$F3"
[ "$rc" = 5 ] && [ "$out" = refused:not-found ] || st_miss "10: unknown fid expected refused:not-found/5" "rc=$rc out=$out"
refuse_all 10 "fid:" "fid:nope" "fid:AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" "$F2" "daily-y"
has_win "$w10n" || st_miss "10: a refused fid stop closed a window"
# two windows carrying one identity (a copy made by hand) — never a pick
tf set-window-option -t "$w2" @fleet_id "$F2"
run_stop fleetS "fid:$F2"
[ "$rc" = 6 ] && [ "$out" = refused:ambiguous ] || st_miss "10: shared fid expected refused:ambiguous/6" "rc=$rc out=$out"
has_win "$w10n" && has_win "$w2" || st_miss "10: an ambiguous fid stop closed a window"
tf set-window-option -u -t "$w2" @fleet_id
# a keyed worker by fid: its row is keyed issue-<N>, exactly as a stop by key
tf set-window-option -t "$w2" @fleet_id "$F4"
run_stop fleetS "fid:$F4"
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || st_miss "10: worker by fid expected stopped:closed/0" "rc=$rc out=$out"
has_win "$w2" && st_miss "10: worker window survived its fid stop"
ledger_has 2 || st_miss "10: a worker stopped by fid recorded no row keyed 2"
# the hub never answers to an identity
w10h=$(mkwin hubby 'while :; do sleep 300; done' -); tf set-window-option -t "$w10h" @hub 1
tf set-window-option -t "$w10h" @fleet_id "$F3"
run_stop fleetS "fid:$F3"
[ "$rc" = 5 ] || st_miss "10: the hub answered to its fid" "rc=$rc out=$out"
has_win "$w10h" || st_miss "10: a refused hub fid stop closed the window"

# --- 11. dash-reap.sh on a no-repo row (issue #1873) -------------------------------
#        Inside the fleet: bare tmux reaches the isolated server through $TMUX.
SPATH=$(tf display-message -p '#{socket_path}')
reap() { out=$(TMUX="$SPATH,1,0" bash "$BIN/dash-reap.sh" "$@" 2>"$WORK/err"); rc=$?; }
# The windows first, then the reaps that keep (skip:live) one by one, then the five
# that stop at once — each on its own window, each a graceful /exit's wait.
F5=55555555-5555-4555-8555-555555555555; F6=66666666-6666-4666-8666-666666666666
w11a=$(mkwin test-norepo "$SHELLED" -); tf set-window-option -t "$w11a" @norepo 1
tf set-window-option -t "$w11a" @fleet_id "$F5"
w11b=$(mkwin norepo-2 "$SHELLED" -); tf set-window-option -t "$w11b" @norepo 1
tf set-window-option -t "$w11b" @fleet_id "$F6"
# the agent's own word (issue #2540): OSC 7501's @agent_status outranks the stamp
F7=77777777-7777-4777-8777-777777777777; F8=88888888-8888-4888-8888-888888888888
w11c=$(mkwin norepo-3 "$SHELLED" -); tf set-window-option -t "$w11c" @norepo 1
tf set-window-option -t "$w11c" @fleet_id "$F7"
w11d=$(mkwin norepo-4 'while :; do sleep 300; done' -); tf set-window-option -t "$w11d" @norepo 1
tf set-window-option -t "$w11d" @fleet_id "$F8"
agents_up "$w11a" "$w11b" "$w11c"
tf set-window-option -t "$w10n" @claude_state working
reap "$w10n" --yes
[ "$rc" = 3 ] && [ "$out" = skip:live ] || st_miss "11: a working no-repo row expected skip:live/3" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w10n" || st_miss "11: a working no-repo row was closed"
# no state (issue #2505): a session that never took a turn
tf set-window-option -u -t "$w11a" @claude_state 2>/dev/null; tf set-window-option -u -t "$w11b" @claude_state 2>/dev/null
reap "$w11b" --yes
[ "$rc" = 3 ] && [ "$out" = skip:live ] || st_miss "11: no state, an agent running expected skip:live/3" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w11b" || st_miss "11: a no-state row with its agent was closed"
tf set-window-option -t "$w11c" @claude_state "done"
tf set-window-option -t "$w11c" @agent_status '{"state":"blocked","kind":"permission","msg":"","app":"claude","ts":1}'
reap "$w11c" --yes
[ "$rc" = 3 ] && [ "$out" = skip:live ] || st_miss "11: 7501 blocked over a done stamp expected skip:live/3" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w11c" || st_miss "11: a 7501-blocked row was closed"
# now the five that stop
tf set-window-option -t "$w10n" @claude_state "done"
tf set-window-option -t "$w11a" @test_identity 1
tf set-window-option -t "$w11b" @wrap_gone 1
tf set-window-option -t "$w11c" @claude_state working
tf set-window-option -t "$w11c" @agent_status '{"state":"done","kind":"","msg":"","app":"claude","ts":1}'
tf set-window-option -u -t "$w11d" @claude_state 2>/dev/null
for w in w10n w11a w11b w11c w11d; do
  eval "bg_stop r_$w env TMUX=\"\$SPATH,1,0\" bash \"\$BIN/dash-reap.sh\" \"\$$w\" --yes"
done
bg_read r_w10n
[ "$rc" = 0 ] && [ "$out" = reaped:full ] || st_miss "11: a done no-repo row expected reaped:full/0" "rc=$rc out=$out err=$(cat "$WORK/r_w10n.err")"
has_win "$w10n" && st_miss "11: the done no-repo row survived ⌃x"
kill -0 "${p10n:-0}" 2>/dev/null && st_miss "11: the reaped no-repo agent is still alive (not a graceful /exit)"
bg_read r_w11a
[ "$rc" = 0 ] && [ "$out" = reaped:full ] || st_miss "11: a test identity's no-state row expected reaped:full/0" "rc=$rc out=$out err=$(cat "$WORK/r_w11a.err")"
has_win "$w11a" && st_miss "11: the test identity's row survived ⌃x"
bg_read r_w11b
[ "$rc" = 0 ] && [ "$out" = reaped:full ] || st_miss "11: no state, no agent expected reaped:full/0" "rc=$rc out=$out err=$(cat "$WORK/r_w11b.err")"
has_win "$w11b" && st_miss "11: the no-agent row survived ⌃x"
bg_read r_w11c
[ "$rc" = 0 ] && [ "$out" = reaped:full ] || st_miss "11: 7501 done over a working stamp expected reaped:full/0" "rc=$rc out=$out err=$(cat "$WORK/r_w11c.err")"
has_win "$w11c" && st_miss "11: the 7501-done row survived ⌃x"
# no word, no stamp, no agent process (an agent that never started): exited
bg_read r_w11d
[ "$rc" = 0 ] && [ "$out" = reaped:full ] || st_miss "11: no word, no state, no agent process expected reaped:full/0" "rc=$rc out=$out err=$(cat "$WORK/r_w11d.err")"
has_win "$w11d" && st_miss "11: the agentless row survived ⌃x"

# --- 12. a bare PATH (issue #4822): a stop sent over ssh / the peerlink runs with
#         `/usr/bin:/bin` — no tmux on it — and every key answered not-found while
#         the window stood. The fill finds tmux in FLEET_TOOL_DIRS: a PATH with
#         every system tool but tmux, and tmux only in a tool dir.
mkdir -p "$WORK/pbin" "$WORK/tbin"
for d in /usr/bin /bin; do
  for f in "$d"/*; do
    n=${f##*/}; [ "$n" = tmux ] || [ -e "$WORK/pbin/$n" ] || ln -s "$f" "$WORK/pbin/$n" 2>/dev/null
  done
done
for t in bash python3 ps awk; do   # where the runner keeps them outside /usr/bin:/bin
  [ -e "$WORK/pbin/$t" ] || { tp=$(command -v "$t") && ln -s "$tp" "$WORK/pbin/$t"; }
done
ln -s "$REAL_TMUX" "$WORK/tbin/tmux"
w12=$(mkwin twelve 'while :; do sleep 300; done' 12); sleep 0.3
out=$(env -i HOME="$HOME" PATH="$WORK/pbin" FLEET_TOOL_DIRS="$WORK/tbin" TMUX_TMPDIR="$TMUX_TMPDIR" \
        FLEET_CONF_DIR="$FLEET_CONF_DIR" FLEET_HISTORY_LEDGER="$FLEET_HISTORY_LEDGER" \
        CLAUDE_PROJECTS_DIR="$CLAUDE_PROJECTS_DIR" FLEET_CC_SESSIONS_DIR="$FLEET_CC_SESSIONS_DIR" \
        "$WORK/pbin/bash" "$BIN/fleet-worker-stop.sh" fleetS issue-12 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = stopped:shell ] || st_miss "12: a bare-PATH stop expected stopped:shell/0" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w12" && st_miss "12: the window survived a bare-PATH stop"

# --- 9. a multi-repo fleet (issue #1018): `<repo>:issue-N` stops THAT repo's -----
#        window only; a bare key two repos hold is ambiguous; an unhosted repo is
#        a usage refusal. Last, because the overlay makes the fleet multi-repo.
mkdir -p "$FLEET_CONF_DIR/fleets/fleetS/repos"
printf 'FLEET_REPO="acme/other"\n' > "$FLEET_CONF_DIR/fleets/fleetS/repos/acme-other.conf"
w9a=$(mkwin nine-a "$SHELLED" 9); w9b=$(mkwin nine-b "$SHELLED" 9); agents_up "$w9a" "$w9b"
tf set-window-option -t "$w9a" @repo acme/fleetS; tf set-window-option -t "$w9b" @repo acme/other
run_stop fleetS issue-9
[ "$rc" = 6 ] && [ "$out" = refused:ambiguous ] || st_miss "9: bare key held in two repos expected refused:ambiguous/6" "rc=$rc out=$out"
run_stop fleetS nope:issue-9
[ "$rc" = 2 ] || st_miss "9: an unhosted repo prefix should be a usage refusal (2)" "rc=$rc out=$out"
run_stop fleetS acme-other:issue-9
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || st_miss "9: expected stopped:closed/0" "rc=$rc out=$out err=$(cat "$WORK/err")"
has_win "$w9b" && st_miss "9: acme/other's window survived its stop"
has_win "$w9a" || st_miss "9: acme/fleetS's issue-9 window was closed by acme/other's stop"
run_stop fleetS acme/fleetS:issue-9
[ "$rc" = 0 ] && [ "$out" = stopped:closed ] || st_miss "9: owner/name prefix expected stopped:closed/0" "rc=$rc out=$out"
has_win "$w9a" && st_miss "9: acme/fleetS's window survived its stop"

st_done
