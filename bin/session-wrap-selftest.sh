#!/bin/bash
# session-wrap-selftest.sh — a session survives its agent's exit, and the fleet
# survives its last session (issue #1784, EPIC #1776 C8).
#
#   A  lint: no spawn path runs fleet-claude.sh in a window / pane directly —
#      every one names fleet-session-wrap.sh (a `# wrap-ok: <why>` line excepts)
#   B  fleet-session-wrap.sh on a REAL isolated tmux server (-S socket, killed at
#      exit) with a fake launcher: the agent exits 0 / 130 / kill -9 → the window
#      stays, @claude_state=exited, the recovery page is drawn, ↵ relaunches with
#      `--resume <the same id>`; r starts new; a fleet exit (@wrap_quiet) and a
#      fast launch failure return the status with no page; q → session-end-hook
#      --recycle
#   B' the worker credential (issue #1809): with fleet-mcp.py beside it the wrapper
#      hands the launch a FLEET_WORKER_CRED that verifies, for this window's
#      @fleet_id, and revokes it when the agent exits; without it (every leg
#      above) nothing is minted
#   B'' the credential-proxy sid (issue #1972): FLEET_CRED_PROXY=0 sets nothing
#      (the launch as before); =1 hands each launch its own FLEET_CRED_SID, stamps
#      @cred_sid, and the exit revokes the session record and drops the options
#   C  session-end-hook.sh: under a live wrapper a manual exit closes nothing;
#      with @wrap_quiet the old close-on-exit policy runs
#   D  fleet_server_resident / fleet_home_resident: `exit-empty off`, and the
#      home window's shell exiting leaves the window (a fresh shell in it)
#      — and fleet_home_heal (the tick's backstop, #1801) respawns a home left dead
#   E  fleet-restore.sh --auto (the diskguard tick): a fleet whose server was
#      killed comes back with ONLY its unfinished sessions; held while the machine
#      is busy; never for a fleet fleet-down took down (restore.down), one with no
#      conf, or one whose map is a day old; the tick calls it (restore_watch)
#   F  claude is found with PATH=/usr/bin:/bin (~/.local/bin, fleet-claude.sh),
#      and a miss names every place tried
#
# tmux / python3 absent → SKIP (exit 0).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'session-wrap: python3 absent — SKIP\n'; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'session-wrap: tmux absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/swrap.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/s"
tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
cleanup() { tf kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
CHECKS=0
fail() { printf 'session-wrap FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
waitfor() {  # <what> <command…> — up to 10s
  local what="$1"; shift
  for _ in $(seq 1 100); do "$@" && { CHECKS=$((CHECKS + 1)); return 0; }; sleep 0.1; done
  fail "timed out: $what"
}

# ------------------------------------------------------------------ A: lint ----
bad=$(cd "$BIN" && python3 - <<'PY'
import glob, re
out = []
for path in sorted(glob.glob('*.sh') + glob.glob('*.py') + glob.glob('.*.py')):
    if 'selftest' in path or path in ('fleet-claude.sh', 'fleet-session-wrap.sh'):
        continue
    for n, line in enumerate(open(path, errors='replace'), 1):
        i = line.find('fleet-claude.sh')
        if i < 0 or 'wrap-ok:' in line:
            continue
        if line.lstrip().startswith(('#', '//')) or re.search(r'(^|\s)#', line[:i]):
            continue
        out.append('%s:%d: %s' % (path, n, line.strip()[:120]))
print('\n'.join(out))
PY
)
CHECKS=$((CHECKS + 1))
[ -z "$bad" ] || fail "A: a spawn path launches fleet-claude.sh directly — name fleet-session-wrap.sh" "$bad"
# The five spawners name the wrapper (a rename of it must break this test, not them).
for f in dash-issue-session.sh dash-raw-session.sh dash-restore-session.sh fleet-restore.sh \
         fleet-migrate.sh fleet-move-remote.sh fleet-transfer.sh scratch-pool.sh fleet-sleep.py; do
  CHECKS=$((CHECKS + 1))
  grep -q 'fleet-session-wrap\.sh' "$BIN/$f" || fail "A: $f does not launch through fleet-session-wrap.sh"
done
# Every fleet-initiated /exit stamps @wrap_quiet first.
for f in fleet-migrate.sh fleet-move.sh fleet-worker-stop.sh fleet-transfer.sh fleet-sleep.py; do
  CHECKS=$((CHECKS + 1))
  grep -q '@wrap_quiet' "$BIN/$f" || fail "A: $f types /exit without stamping @wrap_quiet"
done
CHECKS=$((CHECKS + 1))
grep -q '^    restore_watch' "$BIN/fleet-diskguard.sh" || fail "A: the diskguard --watch tick does not call restore_watch"

# --------------------------------------------- B: the wrapper, on a real tmux ----
mkdir -p "$WORK/wbin"
for f in fleet-session-wrap.sh fleet-session-page.py fleet_sleep_park.py; do ln -s "$BIN/$f" "$WORK/wbin/$f"; done
cat > "$WORK/wbin/session-end-hook.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/recycled"
EOF
cat > "$WORK/fake-launch" <<'EOF'
#!/bin/bash
# The agent: logs its argv, stamps the session id the way the hooks do, waits
# for `go`, then leaves the way $CTL/mode says.
printf '%s\n' "$*" >> "$CTL/argv"
printf 'cred=%s\n' "${FLEET_WORKER_CRED:+set}" >> "$CTL/cred"
tmux set-option -w -t "$TMUX_PANE" @cc_session_id SID-1
tmux set-option -w -t "$TMUX_PANE" @cc_agent claude
[ "$(cat "$CTL/mode" 2>/dev/null)" = fast ] && exit 3
while [ ! -e "$CTL/go" ]; do sleep 0.05; done
rm -f "$CTL/go"
case "$(cat "$CTL/mode")" in
  rc0) exit 0 ;; rc130) exit 130 ;; kill) kill -9 $$ ;;
esac
EOF
chmod +x "$WORK/wbin/session-end-hook.sh" "$WORK/fake-launch"

# win <name> <fast-fail secs> — a window running the wrapper as the spawners do.
win() {
  mkdir -p "$WORK/$1"; : > "$WORK/$1/argv"
  local cmd="env CTL='$WORK/$1' FLEET_WRAP_LAUNCH='$WORK/fake-launch' FLEET_WRAP_FAST_FAIL=$2 FLEET_UI_LANG=zh"
  cmd="$cmd '$WORK/wbin/fleet-session-wrap.sh' --agent claude 'the seed prompt'; echo WRAP_RC=\$?; exec sleep 600"
  if tf has-session -t sw 2>/dev/null; then tf new-window -d -t sw: -n "$1" "$cmd"
  else tf -f /dev/null new-session -d -s sw -n "$1" -x 100 -y 30 "$cmd" || fail "cannot start the isolated tmux server"; fi
}
o() { tf display-message -p -t "sw:$1" "#{$2}" 2>/dev/null; }
launches() { [ "$(grep -c . "$WORK/$1/argv")" = "$2" ]; }
state_is() { [ "$(o "$1" @claude_state)" = "$2" ]; }
screen_has() { tf capture-pane -p -t "sw:$1" | grep -qF -- "$2"; }

win w 0
waitfor "w: first launch" launches w 1
eq "w: the first launch carries the spawn's argv" "--agent claude the seed prompt" "$(sed -n 1p "$WORK/w/argv")"
n=1
for leg in 'rc0:0:会话已退出' 'rc130:130:会话已退出（按了 Ctrl+C）' 'kill:137:会话被结束（信号 9）'; do
  mode=${leg%%:*}; rest=${leg#*:}; rc=${rest%%:*}; head=${rest#*:}
  printf '%s' "$mode" > "$WORK/w/mode"; : > "$WORK/w/go"
  waitfor "w/$mode: state exited" state_is w exited
  eq "w/$mode: the exit status is on the window" "$rc" "$(o w @wrap_exit_rc)"
  waitfor "w/$mode: the recovery page says [$head]" screen_has w "$head"
  waitfor "w/$mode: the page says the window stays" screen_has w '这个窗口不会关'
  CHECKS=$((CHECKS + 1)); tf list-windows -t sw -F '#{window_name}' | grep -qx w || fail "w/$mode: the window closed"
  tf send-keys -t sw:w x                       # a stray key does nothing
  sleep 0.3
  eq "w/$mode: a stray key relaunches nothing" "$n" "$(grep -c . "$WORK/w/argv")"
  tf send-keys -t sw:w Enter
  n=$((n + 1))
  waitfor "w/$mode: ↵ relaunched" launches w "$n"
  eq "w/$mode: ↵ resumes the SAME conversation" "--agent claude --resume SID-1" "$(sed -n "${n}p" "$WORK/w/argv")"
  eq "w/$mode: back from the page, the state is cleared" "" "$(o w @claude_state)"
done
# r: a new conversation in the same window
printf rc0 > "$WORK/w/mode"; : > "$WORK/w/go"
waitfor "w/r: state exited" state_is w exited
tf send-keys -t sw:w r
n=$((n + 1))
waitfor "w/r: r relaunched" launches w "$n"
eq "w/r: r starts NEW (no --resume, no seed)" "--agent claude" "$(sed -n "${n}p" "$WORK/w/argv")"
# The fleet's own exit (sleep / migrate / move / stop / transfer): no page.
tf set-option -w -t sw:w @wrap_quiet 1
printf rc0 > "$WORK/w/mode"; : > "$WORK/w/go"
waitfor "w/quiet: the wrapper returned" screen_has w 'WRAP_RC=0'
CHECKS=$((CHECKS + 1)); [ "$(o w @claude_state)" != exited ] || fail "w/quiet: a fleet exit drew the recovery page"
eq "w/quiet: no relaunch" "$n" "$(grep -c . "$WORK/w/argv")"
eq "w/quiet: the marker is consumed" "" "$(o w @wrap_quiet)"

# A launch that fails fast (not 0/130): the caller's own failure path decides.
win f 5; printf fast > "$WORK/f/mode"
waitfor "f: the wrapper returned the launch's status" screen_has f 'WRAP_RC=3'
CHECKS=$((CHECKS + 1)); [ "$(o f @claude_state)" != exited ] || fail "f: a fast launch failure drew the page"

# q: recycle through the SessionEnd hook.
win q 0
waitfor "q: first launch" launches q 1
printf rc0 > "$WORK/q/mode"; : > "$WORK/q/go"
waitfor "q: state exited" state_is q exited
tf send-keys -t sw:q q
waitfor "q: session-end-hook --recycle was asked" grep -sqx -- '--recycle' "$WORK/recycled"
waitfor "q: the wrapper returned 0" screen_has q 'WRAP_RC=0'
eq "q: recycled windows read done" "done" "$(o q @claude_state)"

# U (issue #1842 ①): commits on no remote are counted on the page.
git init -q --bare "$WORK/u-origin.git"
git init -q "$WORK/u"; git -C "$WORK/u" config user.email t@t; git -C "$WORK/u" config user.name t
git -C "$WORK/u" commit -q --allow-empty -m seed; git -C "$WORK/u" checkout -qb issue-7
git -C "$WORK/u" remote add origin "$WORK/u-origin.git"; git -C "$WORK/u" push -q origin issue-7 2>/dev/null
git -C "$WORK/u" commit -q --allow-empty -m one; git -C "$WORK/u" commit -q --allow-empty -m two
mkdir -p "$WORK/uc"; : > "$WORK/uc/argv"
tf new-window -d -t sw: -n u -c "$WORK/u" "env CTL='$WORK/uc' FLEET_WRAP_LAUNCH='$WORK/fake-launch' FLEET_WRAP_FAST_FAIL=0 FLEET_UI_LANG=zh '$WORK/wbin/fleet-session-wrap.sh' --agent claude; exec sleep 600"
waitfor "u: first launch" launches uc 1
printf rc0 > "$WORK/uc/mode"; : > "$WORK/uc/go"
waitfor "u: the page counts the unpushed commits" screen_has u '未推送：2 个提交（分支 issue-7）'

# P (issue #1842 ③): the page itself fails → a plain prompt, never an exit.
mkdir -p "$WORK/pbin"
for f in fleet-session-wrap.sh fleet_sleep_park.py; do ln -s "$BIN/$f" "$WORK/pbin/$f"; done
printf 'import sys\nraise SystemExit(1)\n' > "$WORK/pbin/fleet-session-page.py"
ln -s "$WORK/wbin/session-end-hook.sh" "$WORK/pbin/session-end-hook.sh"
mkdir -p "$WORK/pc"; : > "$WORK/pc/argv"
tf new-window -d -t sw: -n p "env CTL='$WORK/pc' FLEET_WRAP_LAUNCH='$WORK/fake-launch' FLEET_WRAP_FAST_FAIL=0 FLEET_UI_LANG=zh '$WORK/pbin/fleet-session-wrap.sh' --agent claude; echo WRAP_RC=\$?; exec sleep 600"
waitfor "p: first launch" launches pc 1
printf rc0 > "$WORK/pc/mode"; : > "$WORK/pc/go"
waitfor "p: a broken page falls to the plain prompt" screen_has p '↵ 接着原对话   r 新开'
CHECKS=$((CHECKS + 1)); screen_has p 'WRAP_RC=' && fail "p: a broken page closed the session"
tf send-keys -t sw:p Enter
waitfor "p: ↵ on the plain prompt resumes" launches pc 2
eq "p: the same conversation" "--agent claude --resume SID-1" "$(sed -n 2p "$WORK/pc/argv")"

# B': the worker credential (issue #1809) — minted per launch, revoked on exit.
mkdir -p "$WORK/kbin" "$WORK/kconf"
for f in fleet-session-wrap.sh fleet-session-page.py fleet_sleep_park.py fleet-mcp.py fleet-lib.sh; do
  ln -s "$BIN/$f" "$WORK/kbin/$f"
done
cat > "$WORK/cred-launch" <<EOF
#!/bin/bash
printf '%s\n' "\${FLEET_WORKER_CRED:+set}" > "\$CTL/had"
python3 "$BIN/fleet-mcp.py" --cred check > "\$CTL/claims" 2> "\$CTL/check.err"
while [ ! -e "\$CTL/go" ]; do sleep 0.05; done
EOF
chmod +x "$WORK/cred-launch"
mkdir -p "$WORK/k"
tf new-window -d -t sw: -n k "env CTL='$WORK/k' FLEET_WRAP_LAUNCH='$WORK/cred-launch' FLEET_WRAP_FAST_FAIL=0 \
  FLEET_CONF_DIR='$WORK/kconf' FLEET_CRED_FID_WAIT=0 '$WORK/kbin/fleet-session-wrap.sh' --agent claude; echo WRAP_RC=\$?; exec sleep 600"
waitfor "k: the launch ran" test -s "$WORK/k/had"
eq "k: the launch has FLEET_WORKER_CRED" set "$(cat "$WORK/k/had")"
waitfor "k: the credential was checked" test -s "$WORK/k/claims"
kfid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fid"])' "$WORK/k/claims")
eq "k: the credential names this window's @fleet_id" "$(o k @fleet_id)" "$kfid"
knonce=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["nonce"])' "$WORK/k/claims")
tf set-option -w -t sw:k @wrap_quiet 1; : > "$WORK/k/go"
waitfor "k: the wrapper returned" screen_has k 'WRAP_RC=0'
waitfor "k: the agent's exit revoked the credential" grep -sq "^$knonce " "$WORK/kconf/worker-cred/revoked"
eq "w: a wrapper with no fleet-mcp.py beside it mints nothing" "cred=" "$(sort -u "$WORK/w/cred")"

# B'': the credential-proxy sid (issue #1972) — FLEET_CRED_PROXY=0: nothing set,
# the launch is what it was; =1: a per-launch FLEET_CRED_SID on the launch and on
# the window (@cred_sid), its session record revoked and the option gone at exit.
mkdir -p "$WORK/xbin"
for f in fleet-session-wrap.sh fleet-session-page.py fleet_sleep_park.py fleet-session-cred.sh fleet-cred-proxy.sh fleet-cred-proxy.py; do
  ln -s "$BIN/$f" "$WORK/xbin/$f"
done
cat > "$WORK/sid-launch" <<'EOF'
#!/bin/bash
printf 'sid=%s\n' "${FLEET_CRED_SID:-}" > "$CTL/sid"
printf 'opt=%s\n' "$(tmux display-message -p -t "$TMUX_PANE" '#{@cred_sid}')" >> "$CTL/sid"
if [ -n "${FLEET_CRED_SID:-}" ]; then   # what a mint leaves: a session record
  mkdir -p "$FLEET_CONF_DIR/cred-proxy/sessions"
  printf 'route=central\n' > "$FLEET_CONF_DIR/cred-proxy/sessions/$FLEET_CRED_SID"
  tmux set-option -w -t "$TMUX_PANE" @cred_route central
fi
while [ ! -e "$CTL/go" ]; do sleep 0.05; done
EOF
chmod +x "$WORK/sid-launch"
for sw in 0 1; do
  mkdir -p "$WORK/x$sw" "$WORK/xconf$sw"
  tf new-window -d -t sw: -n "x$sw" "env CTL='$WORK/x$sw' FLEET_WRAP_LAUNCH='$WORK/sid-launch' FLEET_WRAP_FAST_FAIL=0 \
    FLEET_CONF_DIR='$WORK/xconf$sw' FLEET_CRED_PROXY=$sw FLEET_MCP=0 '$WORK/xbin/fleet-session-wrap.sh' --agent claude; echo WRAP_RC=\$?; exec sleep 600"
  waitfor "x$sw: the launch ran" test -s "$WORK/x$sw/sid"
done
eq "x0: switched off — no FLEET_CRED_SID, no @cred_sid" "sid= opt=" "$(tr '\n' ' ' < "$WORK/x0/sid" | sed 's/ $//')"
xsid=$(sed -n 's/^sid=//p' "$WORK/x1/sid")
CHECKS=$((CHECKS + 1)); case "$xsid" in w-[0-9]*-[0-9]*) ;; *) fail "x1: FLEET_CRED_SID is not a per-launch id" "$xsid" ;; esac
eq "x1: the window carries the same sid" "opt=$xsid" "$(sed -n 2p "$WORK/x1/sid")"
for sw in 0 1; do tf set-option -w -t "sw:x$sw" @wrap_quiet 1; : > "$WORK/x$sw/go"; waitfor "x$sw: the wrapper returned" screen_has "x$sw" 'WRAP_RC=0'; done
eq "x1: the exit revoked the session record" no "$([ -e "$WORK/xconf1/cred-proxy/sessions/$xsid" ] && echo yes || echo no)"
eq "x1: @cred_sid / @cred_route are gone" "" "$(o x1 @cred_sid)$(o x1 @cred_route)"
eq "x0: nothing written under cred-proxy/" no "$([ -e "$WORK/xconf0/cred-proxy" ] && echo yes || echo no)"

# ------------------------------------------- C: the SessionEnd hook's gate -----
# A pane stands in for the wrapper (its pid on @session_wrap); the hook's trace
# shows whether it went on to resolve the fleet (= the close-on-exit path).
win c 0
waitfor "c: first launch" launches c 1
cpid=$(tf display-message -p -t sw:c '#{pane_pid}')
tf set-option -p -t sw:c @session_wrap "$cpid"
cpane=$(tf display-message -p -t sw:c '#{pane_id}')
hook_goes_on() {
  env -u FLEET_CONF_DIR TMUX="$SOCK,0,0" TMUX_PANE="$cpane" FLEET_SESSION_WRAP="$cpid" \
    FLEET_SESSION_END_REASON=prompt_input_exit PATH="$WORK/tbin:$PATH" HOME="$WORK" \
    bash -x "$BIN/session-end-hook.sh" </dev/null >"$WORK/hook.trace" 2>&1
  grep -q 'fleet_current_session' "$WORK/hook.trace"
}
mkdir -p "$WORK/tbin"; printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCK" > "$WORK/tbin/tmux"; chmod +x "$WORK/tbin/tmux"
CHECKS=$((CHECKS + 1)); hook_goes_on && fail "C: under a live wrapper a manual exit still ran close-on-exit"
tf set-option -w -t sw:c @wrap_quiet 1
CHECKS=$((CHECKS + 1)); hook_goes_on || fail "C: a fleet exit (@wrap_quiet) no longer runs close-on-exit" "$(tail -5 "$WORK/hook.trace")"
tf set-option -wu -t sw:c @wrap_quiet

# ------------------------------------------------ D: the resident server -----
(
  PATH="$WORK/tbin:$PATH"; HOME="$WORK"; FLEET_CONF_DIR="$WORK/dconf"; export PATH HOME FLEET_CONF_DIR
  . "$BIN/fleet-lib.sh"
  tf new-window -d -t sw: -n home 'exec sh'
  fleet_server_resident whatever sw
)
eq "D: exit-empty is off" off "$(tf show-options -sv exit-empty)"
eq "D: home keeps its pane when its shell exits" on "$(tf show-options -wv -t sw:home remain-on-exit)"
# home_exit: type `exit` into home's shell once it is really up (its pane pid has
# exec'd sh — before that a key can be lost, issue #2042), again while that
# same shell is still alive, so what is timed is the respawn, never the keystroke.
home_up() { local p; p=$(o home pane_pid); [ -n "$p" ] && [ "$(o home pane_dead)" = 0 ] \
  && [ "$(ps -o comm= -p "$p" 2>/dev/null | sed 's|.*/||')" = sh ]; }
home_exit() {
  waitfor "D: home's shell is up" home_up
  hpid=$(o home pane_pid)
  for _ in $(seq 1 5); do
    tf send-keys -t sw:home 'exit' Enter
    for _ in $(seq 1 20); do kill -0 "$hpid" 2>/dev/null && [ "$(ps -o stat= -p "$hpid" 2>/dev/null | cut -c1)" != Z ] || return 0; sleep 0.1; done
  done
}
home_exit
waitfor "D: home respawned a fresh shell" sh -c "[ \"\$('$REAL_TMUX' -S '$SOCK' display-message -p -t sw:home '#{pane_pid}')\" != '$hpid' ] && [ \"\$('$REAL_TMUX' -S '$SOCK' display-message -p -t sw:home '#{pane_dead}')\" = 0 ]"
# The tick's backstop (#1801): tmux ≤ 3.4 can lose the shell's SIGCHLD and leave
# home dead with no pane-died — made here by dropping the hook. fleet_home_heal
# respawns a dead home and leaves a live one alone.
heal() ( PATH="$WORK/tbin:$PATH"; FLEET_CONF_DIR="$WORK/dconf"; export PATH FLEET_CONF_DIR
         . "$BIN/fleet-lib.sh"; fleet_home_heal whatever sw )
tf set-hook -wu -t sw:home pane-died
home_exit
waitfor "D: home left dead with no hook" sh -c "[ \"\$('$REAL_TMUX' -S '$SOCK' display-message -p -t sw:home '#{pane_dead}')\" = 1 ]"
out=$(heal)
CHECKS=$((CHECKS + 1)); case "$out" in "healed @"*) ;; *) fail "D: fleet_home_heal on a dead home printed [$out], want healed @<id>" ;; esac
waitfor "D: fleet_home_heal respawned the dead home" sh -c "[ \"\$('$REAL_TMUX' -S '$SOCK' display-message -p -t sw:home '#{pane_pid}')\" != '$hpid' ] && [ \"\$('$REAL_TMUX' -S '$SOCK' display-message -p -t sw:home '#{pane_dead}')\" = 0 ]"
eq "D: fleet_home_heal leaves a live home alone" "" "$(heal)"
tf kill-session -t sw
CHECKS=$((CHECKS + 1)); tf show-options -sv exit-empty >/dev/null 2>&1 || fail "D: the server died with its last session"
tf kill-server 2>/dev/null

# --------------------------------------------- E: --auto, the tick's pull-up ----
# A sandbox install: every bin/ file linked, fleet-up.sh a stub that only builds
# the session (the real one is fleet-up-selftest's), the claude a fake on PATH.
mkdir -p "$WORK/inst/bin" "$WORK/econf/fleets/oc" "$WORK/emain"
for f in "$BIN"/*; do ln -s "$f" "$WORK/inst/bin/${f##*/}"; done
for f in "$BIN"/.*.py; do [ -e "$f" ] && ln -s "$f" "$WORK/inst/bin/${f##*/}"; done
rm -f "$WORK/inst/bin/fleet-up.sh"
cat > "$WORK/inst/bin/fleet-up.sh" <<EOF
#!/bin/bash
tmux new-session -d -s oc -n home -c "$WORK/emain" 'exec sleep 600'
EOF
cat > "$WORK/tbin/claude" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$PWD" "\$*" >> "$WORK/claude-argv"
printf '────────\n❯ \n────────\n'; exec sleep 600
EOF
chmod +x "$WORK/inst/bin/fleet-up.sh" "$WORK/tbin/claude"
for n in 1 2 3; do mkdir -p "$WORK/wt-$n"; done
cat > "$WORK/econf/oc.conf" <<EOF
FLEET_REPO=acme/widgets
FLEET_MAIN=$WORK/emain
FLEET_BASE_BRANCH=main
EOF
{ printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$WORK/emain"
  printf 'WIN\tissue-1\t%s\tsid-1\t1\tworking\t-\t-\n' "$WORK/wt-1"
  printf 'WIN\tissue-2\t%s\tsid-2\t2\tdone\t-\t-\n'    "$WORK/wt-2"
  printf 'WIN\tissue-3\t%s\tsid-3\t3\texited\t-\t-\n'  "$WORK/wt-3"
} > "$WORK/econf/fleets/oc/restore.map"
auto() {
  env PATH="$WORK/tbin:$PATH" HOME="$WORK" FLEET_CONF_DIR="$WORK/econf" FLEET_SKIP_GLOBAL_CONF=1 \
    SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_DISK_FLOOR_GB=0 "$@" bash "$WORK/inst/bin/fleet-restore.sh" --auto
}
up() { tf has-session -t oc 2>/dev/null; }
# a busy machine: the tick never calls --auto (the admission gate is restore_watch's)
CHECKS=$((CHECKS + 1))
sed -n '/^restore_watch()/,/^}/p' "$BIN/fleet-diskguard.sh" | grep -q 'fleet_machine_admit' \
  || fail "E: restore_watch does not hold a busy machine (fleet_machine_admit)"
# taken down on purpose: never
: > "$WORK/econf/fleets/oc/restore.down"
auto
CHECKS=$((CHECKS + 1)); up && fail "E: --auto restored a fleet fleet-down took down"
rm -f "$WORK/econf/fleets/oc/restore.down"
# a map nobody refreshed for a day: an old outage, not a crash — never
touch -t 202001010000 "$WORK/econf/fleets/oc/restore.map"
auto
CHECKS=$((CHECKS + 1)); up && fail "E: --auto revived a fleet down since 2020"
touch "$WORK/econf/fleets/oc/restore.map"
# a fleet this login no longer has (no conf): never
mv "$WORK/econf/oc.conf" "$WORK/econf/oc.conf.gone"
auto
CHECKS=$((CHECKS + 1)); up && fail "E: --auto revived a fleet with no conf"
mv "$WORK/econf/oc.conf.gone" "$WORK/econf/oc.conf"
# FLEET_AUTO_RESTORE=0: never
auto FLEET_AUTO_RESTORE=0
CHECKS=$((CHECKS + 1)); up && fail "E: FLEET_AUTO_RESTORE=0 still restored"
# down (a kill-server): one tick brings it back, unfinished sessions only
auto
CHECKS=$((CHECKS + 1)); up || fail "E: --auto did not bring the fleet back" "$(cat "$WORK/econf/restore/restore.log" 2>/dev/null)"
wins=$(tf list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')
eq "E: only the unfinished session came back" "home issue-1 " "$wins"
waitfor "E: issue-1 resumed its conversation" grep -q "^$WORK/wt-1|.*--resume sid-1" "$WORK/claude-argv"
CHECKS=$((CHECKS + 1)); tf list-windows -t oc -F '#{pane_start_command}' | grep -q 'fleet-session-wrap.sh' \
  || fail "E: the restored window does not run through the wrapper"
# up: a second tick changes nothing
auto
eq "E: a live fleet is left alone" "$wins" "$(tf list-windows -t oc -F '#{window_name}' | sort | tr '\n' ' ')"

# ---------------------------------------------- F: claude off a bare PATH ----
mkdir -p "$WORK/fhome/.local/bin"
printf '#!/bin/sh\necho "fake-claude $*"\n' > "$WORK/fhome/.local/bin/claude"; chmod +x "$WORK/fhome/.local/bin/claude"
printf '#!/bin/sh\necho "pinned-claude $*"\n' > "$WORK/pinned-claude"; chmod +x "$WORK/pinned-claude"
out=$(env -i HOME="$WORK/fhome" PATH=/usr/bin:/bin FLEET_CONF_DIR="$WORK/fconf" FLEET_MOD=0 FLEET_AGENT_CFG=0 \
      bash "$BIN/fleet-claude.sh" --version 2>&1)
CHECKS=$((CHECKS + 1)); case "$out" in "fake-claude "*" --version") ;; *) fail "F: ~/.local/bin/claude not found off PATH=/usr/bin:/bin" "$out" ;; esac
out=$(env -i HOME="$WORK/fhome" PATH=/usr/bin:/bin FLEET_CONF_DIR="$WORK/fconf" FLEET_MOD=0 FLEET_AGENT_CFG=0 \
      FLEET_CLAUDE_BIN="$WORK/pinned-claude" bash "$BIN/fleet-claude.sh" -p hi 2>&1)
CHECKS=$((CHECKS + 1)); case "$out" in "pinned-claude "*" -p hi") ;; *) fail "F: FLEET_CLAUDE_BIN does not win over PATH" "$out" ;; esac
rm -f "$WORK/fhome/.local/bin/claude"
out=$(env -i HOME="$WORK/fhome" PATH=/usr/bin:/bin FLEET_CONF_DIR="$WORK/fconf" FLEET_MOD=0 FLEET_AGENT_CFG=0 FLEET_TOOL_DIRS="$WORK/nowhere" \
      bash "$BIN/fleet-claude.sh" --version 2>&1); rc=$?
eq "F: nowhere → exit 127" 127 "$rc"
CHECKS=$((CHECKS + 1)); case "$out" in *"claude not found — tried PATH $WORK/nowhere/claude"*) ;; *) fail "F: the miss does not name the places tried" "$out" ;; esac

printf 'session-wrap selftest: OK (%d checks)\n' "$CHECKS"
