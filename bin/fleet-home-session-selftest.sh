#!/bin/bash
# fleet-home-session-selftest.sh — `fleet claude` / `fleet codex` (issue #2264,
# EPIC #2259 C5): bin/fleet → bin/fleet-home-session.sh → bin/fleet-shell.sh
# `home-session` → bin/fleet-client-place.sh `- home`.
#
#   A. the dispatch: `fleet codex hi` reaches fleet-home-session.sh (never the
#      node's fleet-codex.sh launcher) — the client started without attaching and
#      without its own first session (FLEET_SHELL_NO_ATTACH / NO_FIRST), then
#      `home-session codex` with "hi" in its body file; --node travels; a bad
#      option is exit 2 and starts nothing
#   B. `fleet claude --here …` is `fleet run claude …`: the same script, the same
#      words, the same answer (here: FLEET_CRED_PROXY off → exit 3, one line)
#   C. on a fake node (no hub: fleet-client-place.sh's LOCAL road into a sandbox
#      fleet on a private tmux socket): `fleet codex "hi"` opens a window with
#      agent codex, @norepo 1, its pane in $HOME, and the launch carried "hi";
#      home-session.first is written
#   D. `fleet-client-place.sh - home` is `- scratch`; a home with a repo is exit 2
#   E. a newcomer's first session: a client start with FLEET_CLIENT_LAYOUT=solo
#      opens ONE HOME claude session (first_home) — not with the marker there,
#      not without solo, not under FLEET_SHELL_NO_FIRST
#   E2. (issue #2240) the first session REFUSED: 没开出来 · 原因 · 下一步 in
#      home-first.failed, on the client's line and on the solo view's waiting page;
#      ONE retry, none once a HOME session was made meanwhile
#   F. the guard (#1931): a session's `fleet codex` is a client start; `--here` is not
#
# Every tmux call goes to a private socket via a PATH shim; the agents are
# recorders. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
# the real tmux — never the fleet's tmux-shim (a session's PATH starts with it):
# it finds `tmux` on PATH again, which is the private-socket shim below → a loop
REAL_TMUX=''
_ifs=$IFS; IFS=:
for d in $PATH; do
  case "$d" in */tmux-shim) continue ;; esac
  [ -x "$d/tmux" ] && { REAL_TMUX="$d/tmux"; break; }
done
IFS=$_ifs
[ -n "$REAL_TMUX" ] || { printf 'fleet-home-session selftest: tmux not installed — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-home-session selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fhs-st.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/cc" "$WORK/rec" "$WORK/tmp"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
while [ "\${1:-}" = -L ] || [ "\${1:-}" = -S ]; do shift 2; done
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
# The agents: record argv + where they run, then idle.
for a in claude codex; do
  cat > "$WORK/bin/$a" <<EOF
#!/bin/bash
case "\${1:-}" in --version|-V) echo "$a 9.9.9"; exit 0 ;; esac   # the launchers' probe
w=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}' 2>/dev/null)
printf '%s\n' "\$*" >> "$WORK/rec/$a.\$w.args"
pwd -P > "$WORK/rec/$a.\$w.cwd"
exec sleep 300
EOF
done
chmod +x "$WORK/bin/"*

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export PATH="$WORK/bin:$PATH" HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/cc" CODEX_HOME="$WORK/codex"
export FLEET_CONF_DIR="$WORK/conf" XDG_CONFIG_HOME="$WORK/home/.config" XDG_CACHE_HOME="$WORK/home/.cache"
export FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp" FLEET_SHELL_CACHE="$WORK/shellcache"
export FLEET_GLOBAL_MAX_SESSIONS=999 FLEET_PRESPAWN_DEDUP=0 FLEET_SCRATCH_POOL=0 FLEET_CLIENT_IDENTITY=test
mkdir -p "$FLEET_CONF_DIR" "$CODEX_HOME"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_MODEL FLEET_AGENT FLEET_HUB_URL FLEET_HUB_TOKEN \
      CCQUOTA_FLEET CCQUOTA_HUB_URL FLEET_CLIENT_LAYOUT FLEET_SHELL_NO_ATTACH FLEET_SHELL_NO_FIRST FLEET_HOME_SHELL

FAILS=0; CHECKS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }
eq()   { CHECKS=$((CHECKS + 1)); if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ok "$1" ;; *) fail "$1: [$2] lacks [$3]" ;; esac; }

# --- A. the dispatch ------------------------------------------------------------------
# A stub shell: one line per call — its argv, the two switches, and a body file's text.
cat > "$WORK/stubshell.sh" <<EOF
#!/bin/bash
{ printf 'call:%s|attach=%s|first=%s' "\$*" "\${FLEET_SHELL_NO_ATTACH:-}" "\${FLEET_SHELL_NO_FIRST:-}"
  prev=''; for a in "\$@"; do [ "\$prev" = --body-file ] && printf '|body=%s' "\$(cat "\$a")"; prev=\$a; done
  printf '\n'; } >> "$WORK/stub.log"
exit 0
EOF
chmod +x "$WORK/stubshell.sh"
: > "$WORK/stub.log"
FLEET_HOME_SHELL="$WORK/stubshell.sh" FLEET_SHELL_NO_ATTACH=1 sh "$BIN/fleet" codex hi there >/dev/null 2>&1; rc=$?
eq "A fleet codex hi: exit 0" "$rc" 0
eq "A first call: the client, not attached, no first session" "$(sed -n 1p "$WORK/stub.log")" "call:|attach=1|first=1"
has "A second call: home-session codex" "$(sed -n 2p "$WORK/stub.log")" "call:home-session codex --body-file "
has "A the first sentence rides in the body file" "$(sed -n 2p "$WORK/stub.log")" "|body=hi there"
eq "A two calls, nothing attached" "$(wc -l < "$WORK/stub.log" | tr -d ' ')" 2
: > "$WORK/stub.log"
FLEET_HOME_SHELL="$WORK/stubshell.sh" FLEET_SHELL_NO_ATTACH=1 sh "$BIN/fleet" claude --node m4 >/dev/null 2>&1
eq "A --node: the client onto that machine" "$(sed -n 1p "$WORK/stub.log")" "call:m4|attach=1|first=1"
eq "A --node: the place names it, no body" "$(sed -n 2p "$WORK/stub.log")" "call:home-session claude --node m4|attach=1|first="
: > "$WORK/stub.log"
FLEET_HOME_SHELL="$WORK/stubshell.sh" FLEET_SHELL_NO_ATTACH=1 sh "$BIN/fleet" codex --bogus >/dev/null 2>&1; rc=$?
eq "A a bad option: exit 2" "$rc" 2
eq "A a bad option starts nothing" "$(wc -l < "$WORK/stub.log" | tr -d ' ')" 0
FLEET_HOME_SHELL="$WORK/stubshell.sh" sh "$BIN/fleet" codex hi </dev/null >/dev/null 2>&1; rc=$?
eq "A no terminal: exit 2, nothing started" "$rc:$(wc -l < "$WORK/stub.log" | tr -d ' ')" "2:0"

# --- B. --here is fleet run -----------------------------------------------------------
oa=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" claude --here --model x 2>&1); ra=$?
ob=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" run claude --model x 2>&1); rb=$?
eq "B fleet claude --here answers as fleet run claude" "$ra|$oa" "$rb|$ob"
eq "B (switched off: exit 3)" "$ra" 3
oa=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" codex hi --here 2>&1); ra=$?
ob=$(FLEET_CRED_PROXY=0 sh "$BIN/fleet" run codex hi 2>&1); rb=$?
eq "B --here anywhere: the other words are fleet run's" "$ra|$oa" "$rb|$ob"

# --- D. client-place: home = a no-repo scratch ----------------------------------------
bash "$BIN/fleet-client-place.sh" o/a home >/dev/null 2>&1; rc=$?
eq "D a home with a repo: exit 2" "$rc" 2

# --- C. the real road, on a fake node -------------------------------------------------
S=ft
# codex straight, not behind fleet-codex-runtime.py's app server: the seed is
# then its last word (fleet-codex.sh), which the recorder can read
export FLEET_CODEX_SERVER=0
mkdir -p "$FLEET_CONF_DIR/fleets/$S"
printf '# a fleet hosting no repo (issue #1937)\n' > "$FLEET_CONF_DIR/fleets/$S/conf"
"$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s "$S" -n home -x 200 -y 50 || { echo "could not start isolated tmux" >&2; exit 1; }
# the client's server, as fleet-shell.sh leaves it (its environment written by write_conf)
SESS=fleet-shell
tmux new-session -d -s "$SESS" -n home
tmux set-environment -g TMPDIR "$WORK/shellcache/tmp"
mkdir -p "$WORK/shellcache/tmp"
# the stub shell starts nothing; home-session is the real one
cat > "$WORK/realshell.sh" <<EOF
#!/bin/bash
[ "\${1:-}" = home-session ] || exit 0
exec bash "$BIN/fleet-shell.sh" "\$@"
EOF
chmod +x "$WORK/realshell.sh"
before=$(tmux list-windows -t "=$S" -F '#{window_id}' | wc -l | tr -d ' ')
out=$(FLEET_HOME_SHELL="$WORK/realshell.sh" FLEET_SHELL_NO_ATTACH=1 FLEET_HOME_OPEN_WAIT=1 sh "$BIN/fleet" codex hi 2>&1); rc=$?
eq "C fleet codex hi on the fake node: exit 0" "$rc" 0
[ "$rc" = 0 ] || printf '      %s\n' "$out" >&2
w=$(tmux list-windows -t "=$S" -F '#{window_id}' | tail -1)
eq "C one window more in the fleet" "$(tmux list-windows -t "=$S" -F '#{window_id}' | wc -l | tr -d ' ')" "$((before + 1))"
eq "C @norepo" "$(tmux display-message -p -t "$w" '#{@norepo}')" 1
eq "C no @repo" "$(tmux display-message -p -t "$w" '#{@repo}')" ""
# the test identity's session (issue #2505): marked, named test-…, done:10m
eq "C @test_identity (FLEET_CLIENT_IDENTITY=test)" "$(tmux display-message -p -t "$w" '#{@test_identity}')" 1
eq "C named test-…" "$(tmux display-message -p -t "$w" '#{window_name}')" test-我的会话   # the no-repo name since #2359
eq "C its reap policy done:10m" "$(tmux display-message -p -t "$w" '#{@reap_policy}')" done:10m
eq "C the seam prints the placement's line" "LOCAL" "$(printf '%s\n' "$out" | grep -o '^LOCAL' | head -1)"
for _ in $(seq 1 100); do [ -s "$WORK/rec/codex.$w.cwd" ] && break; sleep 0.1; done
[ -s "$WORK/rec/codex.$w.args" ] && ok "C the agent is codex" || fail "C codex never launched in $w ($(ls "$WORK/rec"))"
[ -s "$WORK/rec/claude.$w.args" ] && fail "C claude launched in a codex session"
eq "C its cwd is \$HOME" "$(cat "$WORK/rec/codex.$w.cwd" 2>/dev/null)" "$HOME"
eq "C the first sentence was submitted (its last word)" "$(tail -n1 "$WORK/rec/codex.$w.args" 2>/dev/null | awk '{ print $NF }')" "hi"
[ -e "$FLEET_CONF_DIR/home-session.first" ] && ok "C home-session.first written" || fail "C no home-session.first"

# --- E. a newcomer's first session ----------------------------------------------------
# first_home, lifted out of fleet-shell.sh and run against a stub shell.
fh=$(awk '/^first_home\(\) \{/,/^\}/' "$BIN/fleet-shell.sh")
[ -n "$fh" ] || fail "E no first_home in fleet-shell.sh"
first() {   # $@ = env assignments → the stub's calls
  : > "$WORK/stub.log"
  rm -rf "$WORK/fhcache"; mkdir -p "$WORK/fhcache"
  env "$@" CACHE="$WORK/fhcache" CONF_DIR="$WORK/fhconf" SHADOW="$WORK/fhshadow" bash -c "$fh"'
    first_home; wait' 2>/dev/null
  cat "$WORK/stub.log"
}
mkdir -p "$WORK/fhshadow" "$WORK/fhconf"; cp "$WORK/stubshell.sh" "$WORK/fhshadow/fleet-shell.sh"
has "E solo, no marker: one HOME claude session, --first" "$(first FLEET_CLIENT_LAYOUT=solo)" "call:home-session claude --first"
eq "E not solo (an existing install): nothing" "$(first FLEET_CLIENT_LAYOUT=auto)" ""
eq "E no layout at all: nothing" "$(first)" ""
eq "E FLEET_SHELL_NO_FIRST (fleet claude opens its own): nothing" "$(first FLEET_CLIENT_LAYOUT=solo FLEET_SHELL_NO_FIRST=1)" ""
: > "$WORK/fhconf/home-session.first"
eq "E once: the marker there, nothing" "$(first FLEET_CLIENT_LAYOUT=solo)" ""
grep -q '^first_home$' "$BIN/fleet-shell.sh" && ok "E first_home is called on start" || fail "E first_home never called"
# E2 (issue #2240): REFUSED — the screen says 没开出来 · 原因 · 下一步, not only
# home-first.log: home-first.failed (the solo view's `wait` page draws it), the
# client's line, ONE retry after FLEET_HOME_FIRST_RETRY — none once a HOME
# session was made meanwhile
cat > "$WORK/fhshadow/fleet-shell.sh" <<EOF
#!/bin/bash
printf 'call:%s\n' "\$*" >> "$WORK/stub.log"
[ -n "\${FLEET_HOME_FAILED:-}" ] && printf '没有机器能开：m4 只协调\n这台 (mini) 没被选：没开承载 → fleet host on\n' > "\$FLEET_HOME_FAILED"
[ -n "\${FH_MARK:-}" ] && : > "$WORK/fhconf/home-session.first"
exit 4
EOF
chmod +x "$WORK/fhshadow/fleet-shell.sh"
first2() {
  : > "$WORK/stub.log"; rm -f "$WORK/fhconf/home-session.first"
  rm -rf "$WORK/fhcache"; mkdir -p "$WORK/fhcache"
  env "$@" FLEET_CLIENT_LAYOUT=solo FLEET_UI_LANG=zh FLEET_HOME_FIRST_RETRY=0 BIN="$BIN" CACHE="$WORK/fhcache" \
    CONF_DIR="$WORK/fhconf" SHADOW="$WORK/fhshadow" bash -c 'T() { printf "T:%s\n" "$*" >> "'"$WORK"'/stub.log"; }
    '"$fh"'
    first_home; wait' 2>/dev/null
  cat "$WORK/stub.log"
}
out=$(first2)
eq "E2 refused: tried twice (one retry)" "$(printf '%s\n' "$out" | grep -c '^call:home-session claude --first')" 2
has "E2 the client's line says it" "$out" "T:display-message -d 60000 你的第一个会话没开出来 · 原因：没有机器能开：m4 只协调 · 下一步："
f=$(cat "$WORK/fhcache/home-first.failed" 2>/dev/null)
eq "E2 home-first.failed: 没开出来" "$(printf '%s\n' "$f" | sed -n 1p)" "你的第一个会话没开出来"
eq "E2 …原因 (the place's message)" "$(printf '%s\n' "$f" | sed -n 2p)" "原因：没有机器能开：m4 只协调"
eq "E2 …下一步 (what opens it, then try again)" "$(printf '%s\n' "$f" | sed -n 3p)" "下一步：这台 (mini) 没被选：没开承载 → fleet host on"
has "E2 the first failure says it retries" "$(printf '%s\n' "$out" | grep '^T:' | head -1)" "秒后自动再试一次"
[ -e "$WORK/fhcache/home-first.lock" ] && fail "E2 the lock left behind" || ok "E2 the lock released"
out=$(first2 FH_MARK=1)
eq "E2 a HOME session made meanwhile: no retry" "$(printf '%s\n' "$out" | grep -c '^call:')" 1
[ -e "$WORK/fhcache/home-first.failed" ] && fail "E2 …and nothing left to say" || ok "E2 …and nothing left to say"
# the solo view's waiting page draws the three lines (fleet-shell.sh wait, no server: it
# stops by itself; read in its first second)
first2 >/dev/null
( FLEET_SHELL_CACHE="$WORK/fhcache" FLEET_UI_LANG=zh bash "$BIN/fleet-shell.sh" wait fhs-nosuch > "$WORK/wait.out" 2>&1 & echo $! > "$WORK/wait.pid" )
sleep 1.5; kill "$(cat "$WORK/wait.pid")" 2>/dev/null
w=$(cat "$WORK/wait.out")
has "E2 the waiting page: 没开出来" "$w" "你的第一个会话没开出来"
has "E2 …原因" "$w" "原因：没有机器能开"
has "E2 …下一步" "$w" "下一步："

# --- F. the guard ---------------------------------------------------------------------
g() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
        | env -u FLEET_HUB FLEET_WORKER_CRED=fwc1.x FLEET_HEAVY=0 FLEET_LIB=/nonexistent python3 "$ROOT/hooks/bash-guard.py" >/dev/null 2>&1
      echo $?; }
eq "F a session's fleet codex is a client start" "$(g 'fleet codex hi')" 2
eq "F fleet claude --here is not" "$(g 'fleet claude --here')" 0
eq "F fleet --test-identity codex passes" "$(g 'fleet --test-identity codex')" 0

printf '%s checks, %s failed\n' "$CHECKS" "$FAILS"
[ "$FAILS" = 0 ]
