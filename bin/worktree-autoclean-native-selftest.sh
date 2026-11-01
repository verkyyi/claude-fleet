#!/bin/bash
# worktree-autoclean-native-selftest.sh — the janitor's native-worktree gate
# (task T1253, FLEET_NATIVE_WORKTREE_IDLE). A Claude Code native worktree (its git
# dir carries CLAUDE_BASE — a subagent's `.claude/worktrees/agent-*`) left behind
# for days used to be KEPT forever (`error:native-owned`); one machine held 18 GB of
# them. With the knob on (default 86400 s):
#   agent-1  clean, merged, idle          → PRUNE into .fleet-trash, branch deleted
#   agent-2  clean, unmerged commit, idle → PRUNE, branch KEPT (the commit survives)
#   agent-3  dirty, idle                  → KEEP (uncommitted work)
#   agent-4  clean, recent                → KEEP (idle < knob)
#   agent-5  idle, a live pane in it      → KEEP
#   agent-6  idle, a process runs in it   → KEEP (never swept for orphans)
# FLEET_NATIVE_WORKTREE_IDLE=0 keeps every one (`error:native-owned`, as before),
# and fleet_worktree_drop still refuses a native worktree without --native.
#
# Hermetic: the real script + fleet-lib.sh in a temp bin, fake tmux/gh, a real local
# git repo; ageing is `touch -t` on the worktree dir and its git files.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
SRC="$BIN/worktree-autoclean.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SRC" "$LIB"; do [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }; done
st_need git

st_sandbox "${TMPDIR:-/tmp}/wac-native.XXXXXX"
WORK="$(cd "$WORK" && pwd -P)"
pass=0

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf/logs" "$WORK/tmp/.claude-dash/global"
ln -s "$SRC" "$WORK/bin/worktree-autoclean.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
for f in fleet-client-core.sh fleet-reap-live.py fleet-alerts.sh usage-lib.sh fleet-daemon-lib.sh; do
  [ -e "$BIN/$f" ] && ln -s "$BIN/$f" "$WORK/bin/$f"
done
LIVE_FILE="$WORK/live"; : > "$LIVE_FILE"

BASE="$WORK/base"
git init -q "$BASE"
git -C "$BASE" config user.email t@t; git -C "$BASE" config user.name t
printf 'seed\n' > "$BASE/f"; git -C "$BASE" add f; git -C "$BASE" commit -qm seed
BASE_BR="$(git -C "$BASE" branch --show-current)"
OLD=202601010000

native() {   # $1=name — a worktree the way Claude Code makes one, CLAUDE_BASE and all
  local d="$BASE/.claude/worktrees/$1" gd
  git -C "$BASE" worktree add -q -b "$1" "$d" >/dev/null 2>&1 || st_fail "cannot add $1"
  gd="$(git -C "$d" rev-parse --absolute-git-dir)"
  git -C "$BASE" rev-parse HEAD > "$gd/CLAUDE_BASE"
}
age() {   # $1=name
  local d="$BASE/.claude/worktrees/$1" gd f
  gd="$(git -C "$d" rev-parse --absolute-git-dir)"
  for f in "$d" "$gd/index" "$gd/HEAD" "$gd/logs/HEAD"; do [ -e "$f" ] && touch -t "$OLD" "$f"; done
  return 0
}
printf '.claude/\n' >> "$BASE/.git/info/exclude"
for n in 1 2 3 4 5 6; do native "agent-$n"; done
printf 'a\n' > "$BASE/.claude/worktrees/agent-1/a"; git -C "$BASE/.claude/worktrees/agent-1" add a
git -C "$BASE/.claude/worktrees/agent-1" commit -qm merged-work
git -C "$BASE" merge -q --ff-only agent-1
printf 'b\n' > "$BASE/.claude/worktrees/agent-2/b"; git -C "$BASE/.claude/worktrees/agent-2" add b
git -C "$BASE/.claude/worktrees/agent-2" commit -qm unmerged-work
printf 'dirt\n' > "$BASE/.claude/worktrees/agent-3/untracked"
for n in 1 2 3 5 6; do age "agent-$n"; done
printf '%s\n' "$BASE/.claude/worktrees/agent-5" > "$LIVE_FILE"
( cd "$BASE/.claude/worktrees/agent-6" && exec sleep 300 ) &
SLEEPER=$!
trap 'kill "$SLEEPER" 2>/dev/null' EXIT

cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
[ "\$1" = -L ] && shift 2
case "\$1" in
  has-session) exit 0 ;;
  list-panes)  cat "$LIVE_FILE" 2>/dev/null ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"
printf '#!/bin/bash\nexit 0\n' > "$WORK/fakebin/gh"; chmod +x "$WORK/fakebin/gh"

write_conf() {   # $1 = an extra conf line
  rm -rf "$WORK/conf/fleets/sess1/repos"
  fx_repo "$WORK/conf" sess1 fake/repo FLEET_MAIN="$BASE" FLEET_BASE_BRANCH="$BASE_BR"
  printf '%s\n' "$1" > "$WORK/conf/sess1.conf"
}
run_wac() {
  PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp" CLAUDE_PROJECTS_DIR="$WORK/projects" \
    env ${KNOB:+FLEET_NATIVE_WORKTREE_IDLE=$KNOB} bash "$WORK/bin/worktree-autoclean.sh" "$@" 2>"$WORK/err"
}

# --- OFF: every native worktree stays, as before -----------------------------------
write_conf ""
out="$(KNOB=0 run_wac --dry-run)"
[ "$(printf '%s\n' "$out" | grep -c 'KEEP .*(error:native-owned)')" = 6 ] \
  || st_fail "FLEET_NATIVE_WORKTREE_IDLE=0 must keep all six native worktrees" "$out"
st_pass "OFF: knob 0 keeps every native worktree (error:native-owned)"

# --- ON (the default): dry-run decisions -------------------------------------------
out="$(run_wac --dry-run)"
printf '%s\n' "$out" | grep -Eq 'PRUNE +agent-1 +\(native idle [0-9]+h, (ancestor|landed|at-[a-z]+)\)' \
  || st_fail "agent-1 (merged, idle) should PRUNE with its branch" "$out"
printf '%s\n' "$out" | grep -Eq 'PRUNE +agent-2 .*\[branch kept\]' || st_fail "agent-2 (unmerged) should PRUNE, branch kept" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +agent-3 +\(native: dirty' || st_fail "agent-3 (dirty) must KEEP" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +agent-4 +\(native: idle [0-9]+s <' || st_fail "agent-4 (recent) must KEEP" "$out"
printf '%s\n' "$out" | grep -Eq 'KEEP +agent-5 +\(native: live tmux session' || st_fail "agent-5 (live pane) must KEEP" "$out"
printf '%s\n' "$out" | grep -Eq "KEEP +agent-6 +\(native: in use — pids .*$SLEEPER" || st_fail "agent-6 (a process in it) must KEEP" "$out"
st_pass "ON: merged/unmerged idle native worktrees prune; dirty, recent, live and busy ones stay"

# --- the real run ------------------------------------------------------------------
run_wac >/dev/null
[ -e "$BASE/.claude/worktrees/agent-1" ] && st_fail "agent-1 must be gone" "$(cat "$WORK/conf/logs/worktree-autoclean.log")"
[ -e "$BASE/.claude/worktrees/agent-2" ] && st_fail "agent-2 must be gone" "$(cat "$WORK/conf/logs/worktree-autoclean.log")"
git -C "$BASE" rev-parse -q --verify refs/heads/agent-1 >/dev/null && st_fail "agent-1's merged branch must be deleted"
git -C "$BASE" rev-parse -q --verify refs/heads/agent-2 >/dev/null || st_fail "agent-2's unmerged branch must be kept"
for n in 3 4 5 6; do [ -d "$BASE/.claude/worktrees/agent-$n" ] || st_fail "agent-$n must still be there"; done
# into the base checkout's own trash (the one the sweep reads) — or already swept
# from there; never left in `.claude/worktrees/.fleet-trash`, which nothing empties.
[ -e "$BASE/.claude/worktrees/.fleet-trash" ] \
  && st_fail "a native drop must not stay in .claude/worktrees/.fleet-trash" "$(ls -a "$BASE/.claude/worktrees/.fleet-trash")"
grep -q "PRUNED agent-2 .*trashed:$WORK/.fleet-trash/agent-2\." "$WORK/conf/logs/worktree-autoclean.log" \
  || st_fail "agent-2 must go to the base checkout's trash" "$(cat "$WORK/conf/logs/worktree-autoclean.log")"
grep -q 'PRUNED agent-2 (native idle .* · branch kept' "$WORK/conf/logs/worktree-autoclean.log" \
  || st_fail "the log must say agent-2's branch was kept" "$(cat "$WORK/conf/logs/worktree-autoclean.log")"
st_pass "RUN: two native worktrees trashed, the unmerged branch kept, the rest untouched"

# --- the lib still refuses a native worktree unless asked --------------------------
tok="$( . "$LIB"; fleet_worktree_drop "$BASE" "$BASE/.claude/worktrees/agent-4" )"
[ "$tok" = error:native-owned ] || st_fail "fleet_worktree_drop without --native must refuse, got '$tok'"
st_pass "LIB: fleet_worktree_drop refuses a native worktree without --native"

printf '\nselftest OK: %s assertions passed (worktree-autoclean native gate)\n' "$pass"
exit 0
