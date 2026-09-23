#!/bin/bash
# fleet-fold-selftest.sh — fleet-repo.sh fold (issue #796): move a one-repo fleet
# into another, then retire it. Two sandbox fleets, each on its OWN socket:
#   A (target, hosts o/a) and B (source, hosts o/b) with a dash panel, a warm-pool
#   window, idle workers (issue-12, scratch-4, needs/blocked issue-15), a hibernating one (issue-14),
#   a busy one (issue-13) and a plain window with no worker binding.
#   1. --dry-run prints the plan (carry / WARN / per-window action / retire: NO)
#      and changes NOTHING: no overlay, no stop/restore/down call, B untouched.
#   2. the real run prints the SAME plan, adds o/b with the carried keys, moves the
#      idle + hibernating workers into A with @repo=o/b, leaves the busy and the
#      unbound window in B, and does NOT retire B (exit 1, conf in place).
#   3. with those settled, a re-run keeps the overlay as is, --wait moves the
#      worker that goes idle mid-wait, then fleet-down B and ARCHIVE its conf dir.
#   4. refusals: fold into itself, a 2-repo source, a stopped target with work.
#   5. degenerate: a failed restore leaves the fleet un-retired (never a blind down).
#
# The movers (fleet-worker-stop / dash-restore-session / fleet-sleep / fleet-down)
# are unit-tested on their own; here a sandbox bin/ swaps them for stubs that do
# the tmux half and log the call, so the fold's own sequencing is what is pinned.
# tmux: a PATH shim maps every `-L <label>` to a private socket under $WORK.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-fold-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/shim" "$WORK/sbin" "$WORK/home" "$WORK/tmp"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then s="$WORK/sock.\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
exec "$REAL_TMUX" -S "$WORK/sock.none" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/shim/gh"
chmod +x "$WORK/shim/tmux" "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

cleanup() {
  local s; for s in "$WORK"/sock.*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export CALLS="$WORK/calls"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION FLEET_MODEL FLEET_MCP_CONFIG
unset FLEET_SLEEP_MCP_RESTARTABLE FLEET_MAX_SESSIONS
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ;; *) fail "$1: [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1: [$3] unexpectedly in: $2" ;; esac; }
leg()  { if [ "$FAILS" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; _legf=$FAILS; }

# ---- sandbox bin/: the real scripts, with the four movers stubbed ----------
for f in "$BIN"/*; do ln -s "$f" "$WORK/sbin/$(basename "$f")"; done
rm -f "$WORK/sbin/fleet-worker-stop.sh" "$WORK/sbin/dash-restore-session.sh" \
      "$WORK/sbin/fleet-sleep.sh" "$WORK/sbin/fleet-down.sh"
# stop <sess> <key>: the worker windows are NAMED by their key here.
cat > "$WORK/sbin/fleet-worker-stop.sh" <<'EOF'
#!/bin/bash
printf 'stop %s %s\n' "$1" "$2" >> "$CALLS"
tmux -L "$1" kill-window -t "=$1:$2" 2>/dev/null || { echo refused:not-found; exit 5; }
echo stopped:exit
EOF
# restore landed:<…> <sess> --repo <r>: reopen the window in <sess>, as the real
# one binds it (@issue, or @raw + @worktree; @repo). FAIL_RESTORE=<key> = refuse.
cat > "$WORK/sbin/dash-restore-session.sh" <<'EOF'
#!/bin/bash
printf 'restore %s\n' "$*" >> "$CALLS"
case "$1" in landed:scratch:*) k=${1#landed:scratch:} ;; landed:issue:*) k=issue-${1#landed:issue:} ;; esac
[ "$k" = "${FAIL_RESTORE:-}" ] && exit 2
w=$(tmux -L "$2" new-window -d -P -F '#{window_id}' -t "$2:" -n "$k" 'sleep 3600')
case "$k" in
  scratch-*) tmux -L "$2" set -w -t "$w" @raw 1; tmux -L "$2" set -w -t "$w" @worktree "/wt/b-$k" ;;
  *)         tmux -L "$2" set -w -t "$w" @issue "${k#issue-}" ;;
esac
tmux -L "$2" set -w -t "$w" @repo "$4"
EOF
cat > "$WORK/sbin/fleet-sleep.sh" <<'EOF'
#!/bin/bash
printf 'sleep %s\n' "$*" >> "$CALLS"
[ "$1" = wake ] && tmux -L "$2" set -wu -t "$3" @worker_lifecycle
EOF
cat > "$WORK/sbin/fleet-down.sh" <<'EOF'
#!/bin/bash
printf 'down %s\n' "$*" >> "$CALLS"
tmux -L "$1" kill-session -t "=$1"
EOF
chmod +x "$WORK/sbin"/fleet-worker-stop.sh "$WORK/sbin"/dash-restore-session.sh \
         "$WORK/sbin"/fleet-sleep.sh "$WORK/sbin"/fleet-down.sh
FR="$WORK/sbin/fleet-repo.sh"

mkrepo() { git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git"; }
mkrepo "$WORK/mainA" o/a; mkrepo "$WORK/mainB" o/b

A=fa B=fb
mkdir -p "$FLEET_CONF_DIR/fleets/$A" "$FLEET_CONF_DIR/fleets/$B"
cat > "$FLEET_CONF_DIR/fleets/$A/conf" <<EOF
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/mainA"
FLEET_BASE_BRANCH="master"
FLEET_MODEL="fable"
FLEET_MCP_CONFIG="mcp-image"
FLEET_MAX_SESSIONS="8"
EOF
cat > "$FLEET_CONF_DIR/fleets/$B/conf" <<EOF
FLEET_REPO="o/b"
FLEET_MAIN="$WORK/mainB"
FLEET_BASE_BRANCH="main"
FLEET_MODEL="opus"
FLEET_MCP_CONFIG=""
FLEET_SLEEP_MCP_RESTARTABLE="plugin:playwright:playwright"
FLEET_MAX_SESSIONS="4"
FLEET_SESSION_BANNER="same"
EOF
printf 'FLEET_SESSION_BANNER="same"\n' >> "$FLEET_CONF_DIR/fleets/$A/conf"

TA() { tmux -L "$A" "$@"; }
TB() { tmux -L "$B" "$@"; }
TA new-session -d -s "$A" -n dash 'sleep 3600'
TB new-session -d -s "$B" -n dash 'sleep 3600'
bwin() {  # bwin <name> <opt=val>... — a window of B, with its options
  local n="$1" w kv; shift
  w=$(TB new-window -d -P -F '#{window_id}' -t "$B:" -n "$n" 'sleep 3600')
  for kv in "$@"; do TB set -w -t "$w" "${kv%%=*}" "${kv#*=}"; done
  printf '%s' "$w"
}
bwin pool-1 @pool=1 @raw=1 @worktree=/wt/b-scratch-9 >/dev/null
bwin issue-12  @issue=12 @claude_state=done >/dev/null
bwin scratch-4 @raw=1 @worktree=/wt/b-scratch-4 @claude_state=idle >/dev/null
W13=$(bwin issue-13 @issue=13 @claude_state=working)
bwin issue-14  @issue=14 @worker_lifecycle=sleeping >/dev/null
bwin notes >/dev/null
bwin issue-15 @issue=15 @claude_state=needs @claude_needs=blocked >/dev/null
bnames() { TB list-windows -t "=$B" -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' '; }
anames() { TA list-windows -t "=$A" -F '#{window_name}|#{@repo}' 2>/dev/null | sort | tr '\n' ' '; }
OVL="$FLEET_CONF_DIR/fleets/$A/repos/o-b.conf"
[ "$(fleet_repo_conf_file "$A" o/b)" = "$OVL" ] || OVL=$(fleet_repo_conf_file "$A" o/b)
B_BEFORE=$(bnames)

# ---- 1. dry run: the plan, and nothing else --------------------------------
dry=$(bash "$FR" fold "$B" --into "$A" --dry-run 2>&1); rc=$?
eq "dry rc" "$rc" 0
has "dry header"  "$dry" "fold $B → $A (o/b)"
has "dry add"     "$dry" "add o/b main=$WORK/mainB base=main"
has "dry model"   "$dry" "carry:   FLEET_MODEL=\"opus\""
has "dry mcp"     "$dry" "carry:   FLEET_MCP_CONFIG=\"\""
has "dry sleep"   "$dry" "carry:   FLEET_SLEEP_MCP_RESTARTABLE=\"plugin:playwright:playwright\""
has "dry warn"    "$dry" "not carried: FLEET_MAX_SESSIONS: $B=\"4\" $A=\"8\""
hasnt "dry same"  "$dry" "FLEET_SESSION_BANNER"
for row in "panel    -           dash —" "pool     -           pool-1 —" "move     issue-12" \
           "move     scratch-4" "move     issue-15    issue-15 — needs/blocked" "left     issue-13" "wake     issue-14" "left     -           notes —"; do
  has "dry row [$row]" "$dry" "$row"
done
has "dry retire"  "$dry" "retire:  NO — 2 window(s) stay in $B"
[ -e "$OVL" ] && fail "dry run wrote the overlay"
[ -e "$CALLS" ] && fail "dry run called a mover: $(cat "$CALLS")"
eq "dry B untouched" "$(bnames)" "$B_BEFORE"
leg "1 dry run = plan only"

# ---- 2. real run: same plan, moves the idle + hibernating, B stays -----------
real=$(bash "$FR" fold "$B" --into "$A" 2>&1); rc=$?
eq "real rc (not retired)" "$rc" 1
eq "real plan = dry run" "$(printf '%s\n' "$real" | head -n "$(printf '%s\n' "$dry" | wc -l)")" "$dry"
has "real overlay model" "$(cat "$OVL" 2>/dev/null)" 'FLEET_MODEL="opus"'
has "real overlay sleep" "$(cat "$OVL" 2>/dev/null)" 'FLEET_SLEEP_MCP_RESTARTABLE="plugin:playwright:playwright"'
eq "real overlay mcp get" "$(fleet_repo_conf_get "$A" o/b FLEET_MCP_CONFIG)" ""
eq "real fleet mcp kept" "$(fleet_repo_conf_get "$A" o/a FLEET_MCP_CONFIG)" "mcp-image"
eq "real overlay model get" "$(fleet_repo_conf_get "$A" o/b FLEET_MODEL)" "opus"
eq "real fleet model kept" "$(fleet_repo_conf_get "$A" o/a FLEET_MODEL)" "fable"
eq "A windows" "$(anames)" "dash| issue-12|o/b issue-14|o/b issue-15|o/b scratch-4|o/b "
eq "B windows" "$(bnames)" "dash issue-13 notes pool-1 "
has "wake before stop" "$(cat "$CALLS")" "sleep wake $B"
has "restore scratch"  "$(cat "$CALLS")" "restore landed:scratch:scratch-4 $A --repo o/b"
has "restore issue"    "$(cat "$CALLS")" "restore landed:issue:12 $A --repo o/b"
hasnt "no down"        "$(cat "$CALLS")" "down "
has "real says not retired" "$real" "$B NOT retired — 2 session(s)"
[ -f "$FLEET_CONF_DIR/fleets/$B/conf" ] || fail "B's conf gone before retire"
leg "2 real run moves idle + hibernating, leaves busy + unbound"

# ---- 3. re-run with --wait: issue-13 finishes mid-wait → moved, B retired -----
TB kill-window -t "=$B:notes"
ovl_before=$(cat "$OVL")
: > "$CALLS"
( sleep 2; tmux -L "$B" set -w -t "$W13" @claude_state "done" ) &
flip=$!
out=$(FLEET_FOLD_POLL=1 FLEET_FOLD_WAIT=30 bash "$FR" fold "$B" --into "$A" --wait 2>&1); rc=$?
wait "$flip" 2>/dev/null
eq "wait rc" "$rc" 0
has "wait hosted"  "$out" "$A already hosts o/b — its overlay is left as is"
has "wait row"     "$out" "wait     issue-13"
has "wait moved"   "$out" "issue-13: moved (stopped:exit) → $A"
eq "overlay untouched" "$(cat "$OVL")" "$ovl_before"
has "A has 13" "$(anames)" "issue-13|o/b"
has "down called" "$(cat "$CALLS")" "down $B"
TB has-session -t "=$B" 2>/dev/null && fail "B's server still up"
[ -e "$FLEET_CONF_DIR/fleets/$B" ] && fail "B's conf dir still in fleets/"
arch=$(ls -d "$FLEET_CONF_DIR/archive/$B-folded-into-$A-"* 2>/dev/null | head -1)
[ -f "$arch/conf" ] || fail "B's conf not archived under archive/$B-folded-into-$A-<date>"
has "archived conf intact" "$(cat "$arch/conf" 2>/dev/null)" 'FLEET_REPO="o/b"'
has "retired line" "$out" "fold: $B retired"
leg "3 --wait moves the late finisher, then retires + archives"

# ---- 4. refusals --------------------------------------------------------------
out=$(bash "$FR" fold "$A" --into "$A" 2>&1); rc=$?
eq "self rc" "$rc" 1; has "self msg" "$out" "cannot fold $A into itself"
out=$(bash "$FR" fold "$B" --into "$A" 2>&1); rc=$?
eq "archived source rc" "$rc" 1; has "archived source msg" "$out" "'$B' is not a fleet"
out=$(bash "$FR" fold "$A" 2>&1); rc=$?
eq "no --into = usage" "$rc" 2
# a source that already hosts two repos
C="fc"; mkrepo "$WORK/mainC" o/c
mkdir -p "$FLEET_CONF_DIR/fleets/$C"
printf 'FLEET_REPO="o/c"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/mainC" > "$FLEET_CONF_DIR/fleets/$C/conf"
out=$(bash "$FR" fold "$A" --into "$C" --dry-run 2>&1); rc=$?
eq "2-repo source rc" "$rc" 1; has "2-repo source msg" "$out" "$A hosts 2 repos"
leg "4 refusals"

# ---- 5. a stopped target / a failed restore never retires the source ----------
D="fd"; mkrepo "$WORK/mainD" o/d
mkdir -p "$FLEET_CONF_DIR/fleets/$D"
printf 'FLEET_REPO="o/d"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/mainD" > "$FLEET_CONF_DIR/fleets/$D/conf"
tmux -L "$D" new-session -d -s "$D" -n dash 'sleep 3600'
w=$(tmux -L "$D" new-window -d -P -F '#{window_id}' -t "$D:" -n issue-7 'sleep 3600')
tmux -L "$D" set -w -t "$w" @issue 7
out=$(bash "$FR" fold "$D" --into "$C" 2>&1); rc=$?
eq "stopped target rc" "$rc" 1; has "stopped target msg" "$out" "$C is not running"
fleet_repo_hosted "$C" o/d && fail "stopped target: repo added anyway"
tmux -L "$C" new-session -d -s "$C" -n dash 'sleep 3600'
: > "$CALLS"
out=$(FAIL_RESTORE=issue-7 bash "$FR" fold "$D" --into "$C" 2>&1); rc=$?
eq "failed restore rc" "$rc" 1
has "failed restore msg" "$out" "issue-7: stopped (stopped:exit) but not resumed in $C"
hasnt "failed restore: no down" "$(cat "$CALLS")" "down "
[ -f "$FLEET_CONF_DIR/fleets/$D/conf" ] || fail "failed restore: D's conf archived anyway"
leg "5 stopped target / failed restore keep the source"

[ "$FAILS" = 0 ] && { printf 'fleet-fold-selftest: all passed\n'; exit 0; }
printf 'fleet-fold-selftest: %d failure(s)\n' "$FAILS"; exit 1
