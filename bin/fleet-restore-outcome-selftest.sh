#!/bin/bash
# fleet-restore-outcome-selftest.sh — every restored window ends with ONE outcome
# (issue #1265), and a window restore cannot resume is never silently replaced by
# a context-less fresh session.
#
# Run against a REAL isolated tmux server (its own -S socket, torn down at exit —
# never the live one) with a PATH-shimmed fake `claude` whose behaviour is keyed by
# the session id it is asked to resume:
#   ok-*    paints Claude's input prompt          → @restore_outcome=resumed
#   gone-*  prints "No conversation found", exits → failed  (and NO fresh launch)
#   die-*   exits silently back to the shell      → failed  (the @restore_exit marker)
#   pick-*  paints a session picker               → attention (never answered)
#   (no transcript in the map)                    → awaiting: NO claude at all
# then `--fresh` on the awaiting window → fresh, and the dash tags the parked rows.
# The end-of-run outcome table is printed (it is the issue's evidence).
#
# tmux/python3 absent → SKIP cleanly (exit 0), per the run-selftests convention.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RESTORE="$BIN/fleet-restore.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
[ -f "$RESTORE" ] || { printf 'selftest: %s not found\n' "$RESTORE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 absent — SKIP\n' >&2; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
unset QUIET

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fro-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK" FLEET_CONF_DIR="$WORK/conf" SHELL=/bin/sh FLEET_SKIP_GLOBAL_CONF=1
mkdir -p "$WORK/bin" "$FLEET_CONF_DIR"
SOCK="$WORK/tmux.sock"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# The fake claude: records "<cwd>|<argv>", then plays the screen its resume id names.
cat > "$WORK/bin/claude" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$PWD" "\$*" >> "$WORK/claude-argv"
case " \$* " in
  *" --resume ok-"*)   printf 'Welcome back\n\n────────\n❯ \n────────\n  ? for shortcuts\n'; exec sleep 600 ;;
  *" --resume gone-"*) printf 'No conversation found with session ID: gone-2\n'; exit 1 ;;
  *" --resume die-"*)  exit 3 ;;
  *" --resume pick-"*) printf ' Resume Session\n ❯ 1. fix the dash      2h ago\n   2. another one      1d ago\n'; exec sleep 600 ;;
  *)                   printf '────────\n❯ \n────────\n'; exec sleep 600 ;;
esac
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
opt() { tmux show-window-options -v -t "oc:$1" "$2" 2>/dev/null; }

# ------------------------------------------------------------------ fixture ----
MAIN="$WORK/main"; mkdir -p "$MAIN"
for n in 1 2 3 4 5; do mkdir -p "$WORK/repo-issue-$n"; done
cat > "$FLEET_CONF_DIR/oc.conf" <<EOF
FLEET_REPO=acme/widgets
FLEET_MAIN=$MAIN
FLEET_BASE_BRANCH=main
EOF
mkdir -p "$FLEET_CONF_DIR/fleets/oc"
{ printf 'FLEET\toc\tacme/widgets\t%s\tmain\n' "$MAIN"
  printf 'WIN\tissue-1\t%s\tok-1\t1\tdone\t-\t-\n'      "$WORK/repo-issue-1"
  printf 'WIN\tissue-2\t%s\tgone-2\t2\tdone\t-\t-\n'    "$WORK/repo-issue-2"
  printf 'WIN\tissue-3\t%s\tdie-3\t3\tdone\t-\t-\n'     "$WORK/repo-issue-3"
  printf 'WIN\tissue-4\t%s\tpick-4\t4\tdone\t-\t-\n'    "$WORK/repo-issue-4"
  printf 'WIN\tissue-5\t%s\t-\t5\tworking\t-\t-\n'      "$WORK/repo-issue-5"
} > "$FLEET_CONF_DIR/fleets/oc/restore.map"

# A live, hub-only fleet: restore reconciles it and reopens the five windows.
tmux new-session -d -s oc -x 200 -y 50 -c "$MAIN" 'sleep 600' 2>/dev/null \
  || fail "could not start the isolated tmux server"
tmux rename-window -t oc dash

# ------------------------------------------------------------------ restore ----
: > "$WORK/claude-argv"
out=$(FLEET_RESTORE_PROBE_SECS=5 bash "$RESTORE" 2>&1)
printf '%s\n' "$out"

eq "issue-1 (prompt came up)"         resumed   "$(opt issue-1 @restore_outcome)"
eq "issue-2 (No conversation found)"  failed    "$(opt issue-2 @restore_outcome)"
eq "issue-3 (agent exited)"           failed    "$(opt issue-3 @restore_outcome)"
eq "issue-4 (session picker)"         attention "$(opt issue-4 @restore_outcome)"
eq "issue-5 (no transcript)"          awaiting  "$(opt issue-5 @restore_outcome)"

# resumed keeps the snapshot state; every other outcome is red with the restore reason
eq "issue-1 state untouched"          done      "$(opt issue-1 @claude_state)"
for w in issue-2 issue-3 issue-4 issue-5; do
  eq "$w is red"                      needs     "$(opt "$w" @claude_state)"
  eq "$w red because of restore"      restore   "$(opt "$w" @claude_needs)"
done

# NO silent fresh session: the refused resume launched claude exactly once (the
# resume), and the window with no transcript launched none at all.
eq "issue-2 launched once (no fallback)" 1 "$(grep -c "^$WORK/repo-issue-2|" "$WORK/claude-argv")"
eq "issue-3 launched once (no fallback)" 1 "$(grep -c "^$WORK/repo-issue-3|" "$WORK/claude-argv")"
eq "issue-5 launched no claude"          0 "$(grep -c "^$WORK/repo-issue-5|" "$WORK/claude-argv")"
cmd5=$(tmux display-message -p -t oc:issue-5 '#{pane_current_command}')
case "$cmd5" in *claude*) fail "issue-5: a claude process is running in an awaiting window ($cmd5)";; esac
CHECKS=$((CHECKS + 1))
# the picker is left alone: nothing typed into it, the agent still running there
tmux capture-pane -p -t oc:issue-4 | grep -q 'Resume Session' || fail "issue-4: the picker should still be on screen"
CHECKS=$((CHECKS + 1))

# the table: one line per window, with its outcome
for pair in 'resumed issue-1' 'failed issue-2' 'failed issue-3' 'attention issue-4' 'awaiting issue-5'; do
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$out" | grep -E "^  ${pair% *} +oc +${pair#* }( |$)" >/dev/null \
    || fail "outcome table lacks [$pair]" "$out"
done
printf '%s\n' "$out" | grep -q 'restore outcome (5 windows):' || fail "outcome table header missing" "$out"
CHECKS=$((CHECKS + 1))

# ------------------------------------------------------------------- dash -----
US=$(printf '\037')
if tmux list-windows -t oc -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -q 611f62; then
  rows=$(FLEET_SESSION=oc FZF_COLUMNS=180 TMPDIR="$WORK" bash "$ROWS" 2>/dev/null \
         | LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g' -e $'s/\x1f/ /g')
  for w in issue-4 issue-5; do
    CHECKS=$((CHECKS + 1))
    printf '%s\n' "$rows" | grep " $w " | grep -Eq '需要你|needs you' || fail "dash: $w should be tagged 需要你" "$rows"
  done
  CHECKS=$((CHECKS + 1))
  printf '%s\n' "$rows" | grep " issue-1 " | grep -Eq '需要你|needs you' && fail "dash: resumed issue-1 must not be tagged" "$rows"
fi

# ------------------------------------------------------------------ --fresh ----
bash "$RESTORE" --fresh issue-1 --session oc >/dev/null 2>&1 \
  && fail "--fresh must refuse a window that resumed"
CHECKS=$((CHECKS + 1))
bash "$RESTORE" --fresh issue-4 --session oc >/dev/null 2>&1 \
  && fail "--fresh must refuse an attention window (an agent is still running there)"
CHECKS=$((CHECKS + 1))
bash "$RESTORE" --fresh issue-5 --session oc || fail "--fresh issue-5 failed"
eq "issue-5 after --fresh"            fresh     "$(opt issue-5 @restore_outcome)"
eq "issue-5 no longer red"            ''        "$(opt issue-5 @claude_needs)"
for _n in $(seq 1 50); do
  grep -q "^$WORK/repo-issue-5|" "$WORK/claude-argv" && break
  perl -e 'select undef,undef,undef,0.1' 2>/dev/null || sleep 1
done
line5=$(grep "^$WORK/repo-issue-5|" "$WORK/claude-argv")
[ -n "$line5" ] || fail "--fresh did not start a claude in issue-5"
case "$line5" in *--resume*) fail "--fresh must start a FRESH session, not a resume ($line5)";; esac
CHECKS=$((CHECKS + 1))

# --dry-run plans, it never probes or prints a table
tmux kill-session -t oc 2>/dev/null
dry=$(bash "$RESTORE" --dry-run 2>&1)
printf '%s\n' "$dry" | grep -q 'restore outcome' && fail "--dry-run must not print an outcome table" "$dry"
printf '%s\n' "$dry" | grep 'issue-5 ' | grep -q 'awaiting you (no transcript found)' \
  || fail "--dry-run should announce issue-5 as awaiting" "$dry"
CHECKS=$((CHECKS + 2))

printf 'selftest PASS: restore outcomes (#1265) — %s checks: resumed / failed (refused + exited, no fresh fallback) / attention (picker untouched) / awaiting (no claude) / --fresh → fresh, dash tags 需要你, per-window table printed\n' "$CHECKS"
exit 0
