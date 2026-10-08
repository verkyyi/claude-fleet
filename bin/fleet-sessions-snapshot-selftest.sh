#!/bin/bash
# fleet-sessions-snapshot-selftest.sh — pin, kill-server, restore (issue #2484).
#
# Against a REAL tmux server on an isolated socket (never a fleet's), with
# bin/fleet-sessions-snapshot.sh and the fleet-restore.sh it drives running from a
# sandbox install (fleet-up.sh a stub that builds the session the way the real one
# leaves it, `claude` a stub that records its argv):
#   A  save pins the unfinished sessions only (a `done` one is not pinned), with
#      their reap policy, in global/sessions.snapshot + a per-fleet map copy
#   B  kill-server → restore: every pinned session is back, same name, same cwd,
#      resumed on its own transcript; one whose issue was CLOSED meanwhile is not
#      reopened; restore exits 0 and prints `back` / `closed` per session
#   C  restore again → nothing duplicated
#   D  a worktree deleted while the server was down is never woken (`gone`)
#   E  a fleet fleet-down took down on purpose stays down (`down`)
#   F  no snapshot → exit 3
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { echo "selftest: tmux not installed — SKIP" >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fss-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/sock"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK/tbin" "$WORK/inst/bin" "$WORK/home" "$WORK/main" "$WORK/conf/fleets/oc"
cat > "$WORK/tbin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
cat > "$WORK/tbin/claude" <<EOF
#!/bin/sh
printf '%s|%s\n' "\$PWD" "\$*" >> "$WORK/claude-argv"
printf '────────\n❯ \n────────\n'; exec sleep 600
EOF
cat > "$WORK/state-cmd" <<EOF
#!/bin/sh
grep -qx "\$2" "$WORK/closed" 2>/dev/null && echo CLOSED || echo OPEN
EOF
chmod +x "$WORK/tbin/tmux" "$WORK/tbin/claude" "$WORK/state-cmd"
for f in "$BIN"/* "$BIN"/.*.py; do [ -e "$f" ] && ln -s "$f" "$WORK/inst/bin/${f##*/}"; done
rm -f "$WORK/inst/bin/fleet-up.sh"
cat > "$WORK/inst/bin/fleet-up.sh" <<EOF
#!/bin/bash
tmux new-session -d -s oc -n home -c "$WORK/main" 'exec sleep 600'
EOF
chmod +x "$WORK/inst/bin/fleet-up.sh"
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s\nFLEET_BASE_BRANCH=main\n' "$WORK/main" > "$WORK/conf/oc.conf"

nt() { "$REAL_TMUX" -S "$SOCK" "$@"; }
ss() {
  env PATH="$WORK/tbin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
    SHELL=/bin/sh FLEET_RESTORE_PROBE_SECS=2 FLEET_SESSIONS_STATE_CMD="$WORK/state-cmd" \
    bash "$WORK/inst/bin/fleet-sessions-snapshot.sh" "$@"
}
until_ok() { local secs="$1" _; shift; for _ in $(seq 1 $((secs * 10))); do "$@" && return 0; sleep 0.1; done; "$@"; }

# a live fleet: home + four sessions mid-work, one finished
nt -f /dev/null new-session -d -s oc -n home -x 120 -y 30 -c "$WORK/main" 'exec sleep 600' || fail "no isolated server"
win() {  # win <name> <issue> <state> <sid> <fid>
  mkdir -p "$WORK/wt-$1"
  nt new-window -d -t oc: -n "$1" -c "$WORK/wt-$1" 'exec sleep 600'
  nt set-window-option -t "oc:$1" @repo acme/widgets
  [ "$2" != - ] && nt set-window-option -t "oc:$1" @issue "$2"
  nt set-window-option -t "oc:$1" @claude_state "$3"
  nt set-window-option -t "oc:$1" @cc_session_id "$4"
  nt set-window-option -t "oc:$1" @fleet_id "$5"
  # the resolver resumes a hook-recorded id only when its transcript is on disk
  local pd="$WORK/home/.claude/projects/$(printf '%s' "$WORK/wt-$1" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$pd"; printf '{"type":"user","message":{"content":"work"}}\n' > "$pd/$4.jsonl"
}
win issue-1 1 working sid-1 f0000000-0000-4000-8000-000000000001
win issue-2 2 idle    sid-2 f0000000-0000-4000-8000-000000000002
win issue-4 4 done    sid-4 f0000000-0000-4000-8000-000000000004
win issue-5 5 working sid-5 f0000000-0000-4000-8000-000000000005
win scratch-3 - idle  sid-3 f0000000-0000-4000-8000-000000000003
nt set-window-option -t oc:issue-1 @reap_policy merged:48h

# ---- A. save ---------------------------------------------------------------
out=$(ss save) || fail "A: save exited non-zero ($out)"
SNAP="$WORK/conf/global/sessions.snapshot"
[ -s "$SNAP" ] || fail "A: no snapshot written"
rows=$(grep -v '^#' "$SNAP")
[ "$(printf '%s\n' "$rows" | grep -c .)" = 4 ] || fail "A: want 4 pinned sessions (got: $rows)"
printf '%s\n' "$rows" | grep -q $'\tissue-4\t' && fail "A: a done session was pinned ($rows)"
printf '%s\n' "$rows" | grep -q $'^oc\tissue-1\t'"$WORK/wt-issue-1"$'\tsid-1\tmerged:48h\t' \
  || fail "A: issue-1's row lacks cwd / sid / reap policy ($rows)"
grep -q $'^WIN\tissue-2\t' "$WORK/conf/global/sessions.snapshot.d/oc.map" || fail "A: no map copy"

# ---- B. kill-server → restore ------------------------------------------------
echo 5 > "$WORK/closed"
nt kill-server
: > "$WORK/claude-argv"
out=$(ss restore); rc=$?
[ "$rc" = 0 ] || fail "B: restore exit $rc ($out)"
for k in issue-1 issue-2 scratch-3; do
  printf '%s\n' "$out" | grep -q "^back	oc	$k	" || fail "B: $k not reported back ($out)"
  cwd=$(nt display-message -p -t "oc:$k" '#{pane_current_path}' 2>/dev/null)
  [ "$cwd" = "$WORK/wt-$k" ] || fail "B: $k came back in '$cwd', not $WORK/wt-$k"
done
printf '%s\n' "$out" | grep -q "^closed	oc	issue-5	" || fail "B: closed issue-5 not reported closed ($out)"
nt list-windows -t oc -F '#{window_name}' | grep -qxE 'issue-5|issue-4' && fail "B: a closed / done session was reopened"
[ "$(nt show-window-options -v -t oc:issue-1 @reap_policy)" = merged:48h ] || fail "B: reap policy not stamped back"
until_ok 15 grep -q -- '--resume sid-1' "$WORK/claude-argv" || fail "B: issue-1 not resumed on sid-1 ($(cat "$WORK/claude-argv"))"
until_ok 15 grep -q -- '--resume sid-3' "$WORK/claude-argv" || fail "B: scratch-3 not resumed on sid-3"

# ---- C. idempotent -----------------------------------------------------------
ss restore >/dev/null || fail "C: second restore not all back"
[ "$(nt list-windows -t oc -F '#{window_name}' | grep -cxF issue-1)" = 1 ] || fail "C: issue-1 duplicated"

# ---- D. a deleted worktree is never woken ---------------------------------------
ss save >/dev/null
nt kill-server
rm -rf "$WORK/wt-issue-2"
out=$(ss restore)
printf '%s\n' "$out" | grep -q "^gone	oc	issue-2	" || fail "D: issue-2 not reported gone ($out)"
nt list-windows -t oc -F '#{window_name}' | grep -qxF issue-2 && fail "D: issue-2 woke up in a deleted directory"
printf '%s\n' "$out" | grep -q "^back	oc	issue-1	" || fail "D: issue-1 not back ($out)"

# ---- E. a fleet taken down on purpose stays down ------------------------------------
ss save >/dev/null
nt kill-server
: > "$WORK/conf/fleets/oc/restore.down"
out=$(ss restore)
printf '%s\n' "$out" | grep -q "^down	oc	issue-1	" || fail "E: issue-1 not reported down ($out)"
nt has-session -t oc 2>/dev/null && fail "E: a fleet-down fleet was brought back"
rm -f "$WORK/conf/fleets/oc/restore.down"

# ---- F. no snapshot ---------------------------------------------------------------
rm -f "$SNAP"
ss restore >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || fail "F: restore with no snapshot exit $rc, want 3"

echo "selftest PASS: fleet-sessions-snapshot — save pins unfinished sessions; kill-server → restore brings each back (same name, cwd, transcript, reap policy); closed / gone / down stay closed; idempotent"
