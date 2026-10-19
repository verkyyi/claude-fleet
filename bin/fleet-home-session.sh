#!/bin/bash
# fleet-home-session.sh — `fleet claude` / `fleet codex`: a new session in one
# command (issue #2264, EPIC #2259 C5).
#
#   fleet claude|codex [--node <m>] [--new] [<first sentence>…]
#   fleet claude|codex --here [args…]
#
# Without --here: a HOME session — no repo, in your home directory on a fleet
# machine, with that agent (EPIC #2259 共同约定 2) — and the thin client onto it.
# The LAST one, when you never /exit-ed it (issue #2564, EPIC #2563 C1): the hub
# answers `RESUME` and this goes back to it — 「回到你上一次的会话」, from any of
# your computers; ⌃D, a closed terminal or a dropped network leave it running and
# current. `--new` opens another all the same (it is the current one then); words
# after the options go to a new session only, never into the resumed one — they
# are its first turn, submitted as it starts. Two steps, each an existing road
# (issue #3004, EPIC #2999 C7; the old client's own road went with it, #3008):
#   1. the HOME machine opens it: fleet-client-place.sh `- home` run there over
#      `fleet-thin.py --run` — with no lease of its own it opens through that
#      machine's adapter, or answers RESUME for your current one
#   2. `fleet --thin <its window | worker id>`: the 看台 lands on it
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
#   fleet claude again  back to the same one  a new one
#   on the list       yes                     no
#
# Exit: the thin client's · fleet-client-place.sh's code when nothing was placed ·
# fleet-run.sh's with --here · 2 usage. FLEET_HOME_THIN_CMD (the selftests)
# replaces step 2 and gets the window / worker id as its argument.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
helpn=$(awk '/^set -uo pipefail/ { print NR - 1; exit }' "$0")

agent="${1:-}"; [ $# -gt 0 ] && shift
case "$agent" in
  claude|codex) ;;
  -h|--help) sed -n "2,${helpn}p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

# --here anywhere: the rest, untouched, is fleet run's — 承载's (issue #4826:
# a computer with only the client has no fleet-run.sh, and says so)
for a in "$@"; do
  if [ "$a" = --here ]; then
    [ -f "$BIN/fleet-run.sh" ] || { echo "fleet $agent --here 在这台电脑上跑会话，开了承载才有：fleet host on（或去掉 --here，在 fleet 机器上开）" >&2; exit 3; }
    rest=()
    for b in "$@"; do [ "$b" = --here ] || rest+=("$b"); done
    exec bash "$BIN/fleet-run.sh" "$agent" ${rest[@]+"${rest[@]}"}
  fi
done

node=''; words=(); fresh=''
while [ $# -gt 0 ]; do
  case "$1" in
    --node)   [ $# -ge 2 ] || usage; node="$2"; shift 2 ;;
    --node=*) node="${1#--node=}"; shift ;;
    --new)    fresh=1; shift ;;
    -h|--help) sed -n "2,${helpn}p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; words+=("$@"); break ;;
    -*) printf 'fleet %s: 不认识的选项 %s（fleet %s --help）\n' "$agent" "$1" "$agent" >&2; exit 2 ;;
    *) words+=("$1"); shift ;;
  esac
done
case "$node" in ''|auto) node='' ;; *[!A-Za-z0-9._-]*) printf 'fleet %s: 机器名不对：%s\n' "$agent" "$node" >&2; exit 2 ;; esac
text="${words[*]-}"
# a first sentence is for a session that starts with it: never typed into the
# one this would go back to
[ -z "$text" ] || fresh=1

# The thin client needs a terminal (bin/fleet's own rule); the seam attaches nothing.
if [ -z "${FLEET_HOME_THIN_CMD:-}" ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
  printf 'fleet %s: 要在终端里运行（这里是管道或脚本）\n' "$agent" >&2
  exit 2
fi

# 1. the HOME machine opens it — a window id there, a worker id another machine's
rbin="${FLEET_REMOTE_BIN:-.claude/fleet/bin}"
# the first sentence rides as an argument and becomes the body file there
hline=$(python3 "$BIN/fleet-thin.py" --run -- sh -c \
  'f=; if [ -n "$1" ]; then f=$(mktemp "${TMPDIR:-/tmp}/fleet-home-body.XXXXXX") && printf %s "$1" > "$f"; fi; shift
   bash "$@" ${f:+--body-file "$f"}; rc=$?; [ -z "$f" ] || rm -f "$f"; exit $rc' \
  fleet-home "$text" "$rbin/fleet-client-place.sh" - home --agent "$agent" ${node:+--node "$node"} ${fresh:+--new} \
  | tail -n 1); rc=$?
[ "$rc" = 0 ] || { [ -z "$hline" ] || printf '%s\n' "${hline#*$'\t'}" >&2; exit "$rc"; }
head=${hline%%$'\t'*}; why=''; case "$hline" in *$'\t'*) why=${hline#*$'\t'} ;; esac
case "$head" in
  RESUME\ *) want=$(printf '%s' "$head" | awk '{ print $3 }') ;;
  REMOTE\ *) want=$(printf '%s' "$head" | awk '{ print $5 }') ;;
  # this machine's own adapter: dash-raw-session.sh --print's receipt, its window first
  LOCAL\ *)  want=$(printf '%s' "$why" | awk '{ print ($1 == "warm" ? $2 : $1) }') ;;
  *) want='' ;;
esac
case "$want" in @[0-9]*|*/*) ;; *) want='' ;; esac
# 2. the thin client onto it
[ -n "${FLEET_HOME_THIN_CMD:-}" ] && exec sh -c "$FLEET_HOME_THIN_CMD" fleet-home ${want:+"$want"}
exec bash "$BIN/fleet" --thin ${want:+"$want"}
