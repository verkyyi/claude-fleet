#!/bin/bash
# selftest-lib.sh: assertions fail closed; fixtures cannot call live commands;
# sourcing is inert, and sandbox cleanup preserves the caller's exit status.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_sandbox "${TMPDIR:-/tmp}/selftest-lib.XXXXXX"
for test_shell in bash sh zsh; do
  command -v "$test_shell" >/dev/null 2>&1 || continue
  mkdir -p "$WORK/$test_shell"
  "$test_shell" -u -s -- "$BIN/selftest-lib.sh" "$WORK/$test_shell" <<'TEST' || exit 1
lib=$1; root=$2
before=$-; CHECKS=7; pass=9
trap ':' EXIT
before_trap=$(trap)
. "$lib"
st_eq 'source keeps options' "$before" "$-"
st_eq 'source keeps trap' "$before_trap" "$(trap)"
st_eq 'source keeps CHECKS' 7 "$CHECKS"
st_eq 'source keeps pass' 9 "$pass"
st_count; st_pass counter > "$root/ok"
st_eq 'count exactly once' 8 "$CHECKS"
st_eq 'pass exactly once' 10 "$pass"
st_eq 'pass prints' 'ok   counter' "$(cat "$root/ok")"
st_eq 'ok prints first arg' 'ok   first' "$(st_ok first second)"
st_eq 'ok_all prints args' 'ok   first second' "$(st_ok_all first second)"
st_has 'literal match' 'prefix [*] suffix' '[*]'
st_hasnt 'literal absence' 'prefix xyz suffix' '[*]'
for assertion in st_fail st_eq st_has st_hasnt; do
  case "$assertion" in
    st_fail) set -- 'message
second line' 'detail
last line' ;;
    st_eq) set -- unequal expected actual ;;
    st_has) set -- missing haystack needle ;;
    st_hasnt) set -- present haystack stack ;;
  esac
  out=$(ST_LEG=leg "$assertion" "$@" 2>&1); rc=$?
  st_eq "$assertion exits 1" 1 "$rc"
  st_has "$assertion format" "$out" 'FAIL: leg: '
  st_eq "$assertion one line" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
done
FAIL=0
out=$(ST_LEG=leg st_miss 'missed
twice' 'got
this' 2>&1; printf 'after %s' "$FAIL"); rc=$?
st_eq 'st_miss returns' 0 "$rc"
st_has 'st_miss format' "$out" 'FAIL: leg: missed twice — got this'
st_has 'st_miss counts and continues' "$out" 'after 1'
# The opt-in knobs: ST_COUNT counts each assertion, ST_MISS reports and goes on.
CHECKS=0; FAIL=0
out=$( { ST_COUNT=1; ST_MISS=1; st_eq e 1 2 why; st_has h abc z; st_hasnt n abc b; st_eq e2 1 1
  printf 'checks %s fail %s' "$CHECKS" "$FAIL"; } 2>&1); rc=$?
st_eq 'knobs return' 0 "$rc"
st_has 'eq detail' "$out" 'expected [1], got [2] — why'
st_has 'knobs count and miss' "$out" 'checks 4 fail 3'
st_eq 'no knob counts nothing' 0 "$CHECKS"
out=$( (FAIL=2; CHECKS=5; ST_LEG=leg st_done) 2>&1); rc=$?
st_eq 'st_done red exits 1' 1 "$rc"
st_has 'st_done red names the count' "$out" 'FAIL: leg: 2 failed of 5 checks'
out=$( (FAIL=0; unset CHECKS; st_done) 2>&1); rc=$?
st_hasnt 'st_done green names no checks it did not count' "$out" checks
(st_tally count miss; st_eq t 1 2; st_has h a a; [ "$FAIL:$CHECKS:$ST_COUNT:$ST_MISS" = 1:2:1:1 ]) 2>/dev/null \
  || st_fail 'st_tally starts the tally and sets the words'
st_eq 'st_done green exits 0' 0 "$rc"
st_has 'st_done green says so' "$out" ': none failed'
# Apostrophes, spaces and shell metacharacters remain literal in generated files.
bin="$root/bin ' \$x"; log="$root/log ' \$x"
st_fake_tmux "$bin" "$log"; st_fake_gh "$bin"
"$bin/tmux" list-windows 'two words' || st_fail 'fake tmux exit'
st_eq 'tmux logs one call' 'list-windows two words' "$(cat "$log")"
"$bin/gh" auth token; rc=$?
st_eq 'gh offline' 1 "$rc"
st_fake_tmux "$bin"
"$bin/tmux" kill-server || st_fail 'no-op tmux exit'
st_eq 'no-log stub does not append' 1 "$(wc -l < "$log" | tr -d ' ')"
st_fake_tmux_wlist "$root/wl"; printf 'row1\n' > "$root/wlist"
st_eq 'wlist answers a formatted list-windows' row1 "$(WLIST_FILE="$root/wlist" "$root/wl/tmux" list-windows -F "a$(printf '\037')b")"
st_eq 'wlist is silent otherwise' '' "$(WLIST_FILE="$root/wlist" "$root/wl/tmux" list-windows -F x)"
if command -v python3 >/dev/null 2>&1; then
  st_fake_tmux_opts "$root/op"; st_fake_tmux_opts "$root/op2" list-panes no-send
  export FAKE_OPTS="$root/opts"
  "$root/op/tmux" -L x set-window-option -t @1 k 'v w' || st_fail 'opts set'
  st_eq 'opts fill a format' 'v w|b' "$("$root/op/tmux" display-message -p '#{k}|#{?#{none},a,b}')"
  "$root/op/tmux" set-window-option -u -t @1 k
  st_eq 'opts unset' '' "$("$root/op/tmux" display-message -p '#{k}')"
  "$root/op/tmux" list-panes; st_eq 'opts: list-panes is a word' 1 "$?"
  "$root/op2/tmux" send-keys x; st_eq 'opts: no-send refuses' 1 "$?"
  unset FAKE_OPTS
fi
# The "real" executable is a recorder: no actual tmux server is needed here.
cat > "$root/recorder" <<'REC'
#!/bin/sh
printf '<%s>\n' "$@"
REC
chmod +x "$root/recorder"
REAL_TMUX="$root/recorder"
st_tmux_socket "$bin" "$root/socket ' \$x"
st_eq 'socket and argv stay literal' "$(printf '<%s>\n' -S "$root/socket ' \$x" -L other 'two words')" "$("$bin/tmux" -L other 'two words')"
st_tmux_socket "$bin" "$root/socket ' \$x" strip
st_eq 'strip drops one -L pair' "$(printf '<%s>\n' -S "$root/socket ' \$x" 'two words')" "$("$bin/tmux" -L other 'two words')"
st_eq 'strip keeps a bare argv' "$(printf '<%s>\n' -S "$root/socket ' \$x" ls)" "$("$bin/tmux" ls)"
test_path=$PATH; PATH="$bin"
st_real_tmux
PATH=$test_path
st_eq 'resolve before use' "$bin/tmux" "$REAL_TMUX"
mkdir -p "$root/empty"
out=$(PATH="$root/empty" st_real_tmux 2>&1); rc=$?
st_eq 'absent tmux skips' 0 "$rc"
st_has 'absent tmux explains skip' "$out" SKIP
out=$(st_need sh no-such-tool-x 2>&1; echo after); rc=$?
st_eq 'st_need skips' 0 "$rc"
st_has 'st_need names the tool' "$out" 'no-such-tool-x absent — SKIP'
st_hasnt 'st_need stops the test' "$out" after
(st_sandbox "$root/sandbox.XXXXXX" physical; printf '%s' "$WORK" > "$root/path"; exit 7)
rc=$?; sandbox=$(cat "$root/path")
st_eq 'cleanup preserves exit' 7 "$rc"
[ ! -e "$sandbox" ] || st_fail 'sandbox not removed'
(st_sandbox "$root/missing/fail.XXXXXX") 2>/dev/null; rc=$?
st_eq 'mktemp failure exits 2' 2 "$rc"
st_ok 'selftest-lib primitives'
TEST
done
