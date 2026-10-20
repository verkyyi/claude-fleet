#!/bin/sh
# fleet-tool-yield.sh <command> — what a Claude session RUNS yields to the 看台 (T691).
#
# fleet-claude.sh sets CLAUDE_CODE_SHELL_PREFIX to this file, so Claude Code runs
# every Bash tool command and every hook as `fleet-tool-yield.sh '<command>'`. On a
# full machine those commands (tests, builds, gh, git) are what took the CPU from
# the tmux server, sshd and the panel: measured on mac-b (10 cores, its own load
# 30-50 plus fleet-loadgen.sh's 20 burners), the panel's start went p50 274 · p90
# 588 · max 796 ms with the load at the default class, 71 · 182 · 306 with it at
# QoS background (utility: 200 · 654 · 1011 — no help). So the command runs one
# class lower than the agent: a Mac's `taskpolicy -c background` (E-cores, throttled
# disk; a CPU-bound command takes ~3× as long), elsewhere `nice -n 10` on top of
# the agent's own. The agent process itself is not clamped this far — its screen
# echoes your typing — and neither are the fleet's own hooks (`<interpreter>
# ~/.claude/fleet/…`, or this install's path), which stamp the state the 看台 shows.
#
# FLEET_TOOL_YIELD (exported by the door): background (default) · utility · 0 = run
# the command exactly as Claude Code would have. The command runs in the shell
# Claude Code chose ($CLAUDE_CODE_SHELL, else $SHELL), exec'd: its stdin, exit
# code and pid chain are the command's own.
cmd=${1-}
sh_=${CLAUDE_CODE_SHELL:-${SHELL:-/bin/sh}}
lvl=${FLEET_TOOL_YIELD:-background}
here=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
case "$lvl" in 0|off|none) exec "$sh_" -c "$cmd" ;; utility) ;; *) lvl=background ;; esac
# the fleet's own hooks, as the hook table spells them — `bash ~/.claude/fleet/bin/…`,
# `python3 ~/.claude/fleet/hooks/…`: an interpreter, then the install's path, first.
# A Bash tool command never starts so (Claude Code wraps it in its own shell lines),
# so an agent running a fleet script (run-selftests.sh, a build) still yields.
case "$cmd" in bash\ *|sh\ *|python3\ *) p=${cmd#* } ;; *) p=$cmd ;; esac
# shellcheck disable=SC2088  # the literal `~/` the hook table writes, never expanded here
case "$p" in "~/.claude/fleet/"*|"$HOME/.claude/fleet/"*) exec "$sh_" -c "$cmd" ;; esac
[ -n "$here" ] && case "$p" in "$here/"*) exec "$sh_" -c "$cmd" ;; esac
case "$(uname -s)" in
  Darwin) [ -x /usr/sbin/taskpolicy ] && exec /usr/sbin/taskpolicy -c "$lvl" "$sh_" -c "$cmd" ;;
  *) if [ "$lvl" = background ]; then exec nice -n 10 "$sh_" -c "$cmd"; else exec nice -n 5 "$sh_" -c "$cmd"; fi ;;
esac
exec "$sh_" -c "$cmd"
