#!/bin/bash
# fleet-tool-yield-selftest.sh — what a Claude session runs yields to the 看台 (T691).
#
# bin/fleet-tool-yield.sh is CLAUDE_CODE_SHELL_PREFIX: Claude Code runs every Bash
# tool command and hook as `fleet-tool-yield.sh '<command>'`. Pinned:
#   A  the command is the command: its output, its stdin, its exit code, run by the
#      shell Claude Code chose ($CLAUDE_CODE_SHELL, else $SHELL)
#   B  it runs one class lower — a Mac: QoS background (ps pri 4; utility leaves the
#      priority band alone), elsewhere nice +10 (utility +5); 0/off/none: as is
#   C  the fleet's own hooks (`<bash|sh|python3> ~/.claude/fleet/…`, $HOME/.claude/
#      fleet/, this install's path — first) stay at the agent's class; a command that
#      merely runs a fleet script still yields
# Drives the real bin/fleet-tool-yield.sh under zsh-less sh; no tmux, no claude.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
Y="$BIN/fleet-tool-yield.sh"
[ -x "$Y" ] || { echo "selftest: $Y missing or not executable" >&2; exit 2; }
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
export SHELL=/bin/sh; unset CLAUDE_CODE_SHELL FLEET_TOOL_YIELD
# run <level> <command> — as Claude Code composes it: the outer shell, two quoted words
run() { FLEET_TOOL_YIELD="$1" /bin/sh -c "'$Y' '$2'"; }
mark() { case "${OSTYPE:-}" in darwin*) ps -o pri= -p "$1" | tr -d ' ' ;; *) ps -o nice= -p "$1" | tr -d ' ' ;; esac; }

# ---- A: the command is the command --------------------------------------------------
[ "$(run background 'echo hi $((1+2))')" = "hi 3" ] || fail "A the command's output"
run background 'exit 7'; [ $? = 7 ] || fail "A the command's exit code"
[ "$(printf '{"a":1}' | run background 'cat')" = '{"a":1}' ] || fail "A the command's stdin"
[ "$(CLAUDE_CODE_SHELL=/bin/bash run background 'echo $BASH')" = /bin/bash ] || fail "A CLAUDE_CODE_SHELL is the shell"
[ "$(run 0 'echo plain; exit 3')" = plain ] || fail "A off: the command as is"
ok "A the command's output, stdin and exit code; the shell Claude Code chose"

# ---- B: one class lower ------------------------------------------------------------------
base=$(mark $$)
bg=$(run background 'ps -o pri=,nice= -p $$')
ut=$(run utility 'ps -o pri=,nice= -p $$')
off=$(run 0 'ps -o pri=,nice= -p $$')
dflt=$(run '' 'ps -o pri=,nice= -p $$')
case "${OSTYPE:-}" in
  darwin*)
    if [ -x /usr/sbin/taskpolicy ]; then
      [ "$(echo $bg | cut -d' ' -f1)" = 4 ] || fail "B a Mac: background runs at pri 4, got [$bg]"
      [ "$(echo $dflt | cut -d' ' -f1)" = 4 ] || fail "B a Mac: the default is background, got [$dflt]"
      [ "$(echo $off | cut -d' ' -f1)" = "$base" ] || fail "B a Mac: off keeps pri $base, got [$off]"
      [ "$(echo $ut | cut -d' ' -f1)" = "$base" ] || fail "B a Mac: utility keeps the band ($base), got [$ut]"
    fi ;;
  *)
    [ "$(echo $bg | cut -d' ' -f2)" = $((base + 10)) ] || fail "B nice +10 for background, got [$bg] from $base"
    [ "$(echo $dflt | cut -d' ' -f2)" = $((base + 10)) ] || fail "B the default is background, got [$dflt]"
    [ "$(echo $ut | cut -d' ' -f2)" = $((base + 5)) ] || fail "B nice +5 for utility, got [$ut]"
    [ "$(echo $off | cut -d' ' -f2)" = "$base" ] || fail "B off keeps nice $base, got [$off]" ;;
esac
ok "B one class lower (a Mac: QoS background · elsewhere nice +10); off: as is"

# ---- C: the fleet's own hooks stay at the agent's class --------------------------------
want=$(echo $off | cut -d' ' -f1)
case "${OSTYPE:-}" in darwin*) col=1 ;; *) col=2; want=$(echo $off | cut -d' ' -f2) ;; esac
for h in 'sh ~/.claude/fleet/bin/none 2>/dev/null; ps -o pri=,nice= -p $$' \
         "sh $HOME/.claude/fleet/bin/none 2>/dev/null; ps -o pri=,nice= -p \$\$" \
         "sh $(cd "$BIN/.." && pwd)/bin/none 2>/dev/null; ps -o pri=,nice= -p \$\$"; do
  got=$(run background "$h" | awk -v c=$col '{ print $c }')
  [ "$(echo $got)" = "$want" ] || fail "C a fleet hook was clamped: [$h] → [$got], want $want"
done
# …only hook-shaped: a command that RUNS a fleet script (a test, a load) still yields
lo=$(echo $bg | awk -v c=$col '{ print $c }')
for h in 'cd /tmp && sh ~/.claude/fleet/bin/none 2>/dev/null; ps -o pri=,nice= -p $$' \
         "echo x >/dev/null; sh $(cd "$BIN/.." && pwd)/bin/none 2>/dev/null; ps -o pri=,nice= -p \$\$"; do
  got=$(run background "$h" | awk -v c=$col '{ print $c }')
  [ "$(echo $got)" = "$lo" ] || fail "C a command running a fleet script escaped: [$h] → [$got], want $lo"
done
ok "C the fleet's own hooks (~/.claude/fleet, \$HOME/.claude/fleet, this install) keep the agent's class"

printf 'fleet-tool-yield selftest OK: %s checks (T691)\n' "$pass"
