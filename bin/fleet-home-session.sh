#!/bin/bash
# fleet-home-session.sh — `fleet claude` / `fleet codex`: a new session in one
# command (issue #2264, EPIC #2259 C5).
#
#   fleet claude|codex [--node <m>] [<first sentence>…]
#   fleet claude|codex --here [args…]
#
# Without --here: a HOME session — no repo, in your home directory on a fleet
# machine, with that agent (EPIC #2259 共同约定 2) — and the client attached onto
# it. Words after the options are its first turn, submitted as it starts. Three
# steps, every one an existing road:
#   1. the client up WITHOUT attaching (fleet-shell.sh, FLEET_SHELL_NO_ATTACH):
#      its lease is what signs the ask; FLEET_SHELL_NO_FIRST, so a newcomer's
#      automatic first session does not open a second one beside this
#   2. `fleet-shell.sh home-session` — fleet-client-place.sh `- home`: the hub
#      places it (the node takes one from its pool, #2233, or opens one cold);
#      `--no-stage`, so the client's own view stays where it is
#   3. ITS OWN VIEW (issue #2349, `fleet-shell.sh solo`): that one session, the
#      whole terminal, no list — whatever layout the client keeps, which is
#      neither read nor written. The agent's /exit (the session ending) or ⌃D
#      ends the view and the terminal is back at its prompt, with one line on
#      where the session is; a client this command had to start goes again with
#      it (`fleet-shell.sh quit`), so nothing of fleet stays behind. A LOCAL
#      placement (no hub) attaches the client, as before.
# A placement that fails says why (the hub's line) and exits with its code;
# nothing is attached.
#
# With --here: a session on THIS computer, through its credential proxy —
# exactly `fleet run claude|codex [args…]` (bin/fleet-run.sh, issue #2136; every
# other word goes to the agent as it would there).
#
#                     fleet claude            fleet claude --here (= fleet run)
#   runs on           a fleet machine         this computer
#   sees files of     that machine ($HOME)    this computer (the cwd)
#   after you leave   keeps running           ends with the agent
#   its /exit         back at the prompt      back at the prompt
#   another device    can pick it up          no
#   on the list       yes                     no
#
# Exit: the view's · the attach's · fleet-client-place.sh's code when nothing was placed ·
# fleet-run.sh's with --here · 2 usage. FLEET_SHELL_NO_ATTACH=1 (the selftests)
# stops after step 2 with its code.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SH="${FLEET_HOME_SHELL:-$BIN/fleet-shell.sh}"   # the selftests' seam

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

agent="${1:-}"; [ $# -gt 0 ] && shift
case "$agent" in
  claude|codex) ;;
  -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

# --here anywhere: the rest, untouched, is fleet run's
for a in "$@"; do
  if [ "$a" = --here ]; then
    rest=()
    for b in "$@"; do [ "$b" = --here ] || rest+=("$b"); done
    exec bash "$BIN/fleet-run.sh" "$agent" ${rest[@]+"${rest[@]}"}
  fi
done

node=''; words=()
while [ $# -gt 0 ]; do
  case "$1" in
    --node)   [ $# -ge 2 ] || usage; node="$2"; shift 2 ;;
    --node=*) node="${1#--node=}"; shift ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; words+=("$@"); break ;;
    -*) printf 'fleet %s: 不认识的选项 %s（fleet %s --help）\n' "$agent" "$1" "$agent" >&2; exit 2 ;;
    *) words+=("$1"); shift ;;
  esac
done
case "$node" in ''|auto) node='' ;; *[!A-Za-z0-9._-]*) printf 'fleet %s: 机器名不对：%s\n' "$agent" "$node" >&2; exit 2 ;; esac
text="${words[*]-}"

# A tmux client needs a terminal (bin/fleet's own rule); the seam starts nothing to attach.
if [ "${FLEET_SHELL_NO_ATTACH:-0}" != 1 ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
  printf 'fleet %s: 要在终端里运行（这里是管道或脚本）\n' "$agent" >&2
  exit 2
fi

# whether the client was already running (issue #2349): one this command starts
# for its ask goes again with the view — `fleet claude` leaves nothing behind
was_up=1
if [ "${FLEET_SHELL_NO_ATTACH:-0}" != 1 ]; then
  bash "$SH" running >/dev/null 2>&1 || was_up=''
fi

# 1. the client, up and holding its lease — not attached yet
FLEET_SHELL_NO_ATTACH=1 FLEET_SHELL_NO_FIRST=1 bash "$SH" ${node:+"$node"} >/dev/null || exit $?

# 2. the session — the client's own stage left where it is when this command
#    shows it in its own view (--no-stage, step 3)
bodyf=''
if [ -n "$text" ]; then
  bodyf=$(mktemp "${TMPDIR:-/tmp}/fleet-home-body.XXXXXX") || exit 1
  printf '%s' "$text" > "$bodyf"
fi
nostage=''; [ "${FLEET_SHELL_NO_ATTACH:-0}" = 1 ] || nostage=--no-stage
hline=$(bash "$SH" home-session "$agent" ${node:+--node "$node"} ${bodyf:+--body-file "$bodyf"} $nostage | tail -n 1); rc=$?   # pipefail: the ask's code
[ -z "$bodyf" ] || rm -f "$bodyf"
[ "$rc" = 0 ] || exit "$rc"
[ "${FLEET_SHELL_NO_ATTACH:-0}" = 1 ] && exit 0

# 3. onto it, in a view of its own (issue #2349): one session, no list, whatever
#    layout the client keeps — `REMOTE <machine> <op> done <worker id>`. Its /exit
#    or ⌃D returns to the prompt; a client this command started goes with it.
#    No hub (a LOCAL row, this computer's own fleet): the client, as before.
case "$hline" in
  REMOTE\ *)
    hm=$(printf '%s' "${hline%%$'\t'*}" | awk '{ print $2 }')
    hw=$(printf '%s' "${hline%%$'\t'*}" | awk '{ print $5 }')
    case "$hw" in
      */*)
        bash "$SH" solo "$hm" "$hw"; rc=$?
        [ -n "$was_up" ] || bash "$SH" quit --quiet
        exit "$rc" ;;
    esac ;;
esac
FLEET_SHELL_NO_FIRST=1 exec bash "$SH" ${node:+"$node"}
