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
# The "real" executable is a recorder: no actual tmux server is needed here.
cat > "$root/recorder" <<'REC'
#!/bin/sh
printf '<%s>\n' "$@"
REC
chmod +x "$root/recorder"
REAL_TMUX="$root/recorder"
st_tmux_socket "$bin" "$root/socket ' \$x"
st_eq 'socket and argv stay literal' "$(printf '<%s>\n' -S "$root/socket ' \$x" -L other 'two words')" "$("$bin/tmux" -L other 'two words')"
test_path=$PATH; PATH="$bin"
st_real_tmux
PATH=$test_path
st_eq 'resolve before use' "$bin/tmux" "$REAL_TMUX"
mkdir -p "$root/empty"
out=$(PATH="$root/empty" st_real_tmux 2>&1); rc=$?
st_eq 'absent tmux skips' 0 "$rc"
st_has 'absent tmux explains skip' "$out" SKIP
(st_sandbox "$root/sandbox.XXXXXX" physical; printf '%s' "$WORK" > "$root/path"; exit 7)
rc=$?; sandbox=$(cat "$root/path")
st_eq 'cleanup preserves exit' 7 "$rc"
[ ! -e "$sandbox" ] || st_fail 'sandbox not removed'
(st_sandbox "$root/missing/fail.XXXXXX") 2>/dev/null; rc=$?
st_eq 'mktemp failure exits 2' 2 "$rc"
st_ok 'selftest-lib primitives'
TEST
done
