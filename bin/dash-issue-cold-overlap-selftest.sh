#!/bin/bash
# dash-issue-cold-overlap-selftest.sh — the cold start overlaps the agent's start
# with the checkout (issue #2237, EPIC #2230 C7).
#
# With no session ready to hand out, a task opens the old way: dash-issue-session.sh.
# It used to do every step one after the other — fetch, a full checkout (3 s on the
# monorepo), a dozen tmux stamps, then the agent (~2.5 s to start), then the start
# adapter read the WHOLE fleet back (3.5 s at 30 windows) before saying "opened".
# Now the worktree is made with no files, the files an agent reads as it starts
# are checked out, the window opens, and the rest fills beside the agent's start;
# its first prompt and every tool call wait in set-claude-state.sh until the tree
# is whole (FLEET_WT_PENDING). The adapter reads back only the window the spawn
# names (--print).
#
# Real tmux on an isolated socket, a real git repo, the real dash-issue-session.sh,
# fleet-session-wrap.sh, set-claude-state.sh and fleet-control-read.sh; the agent
# is a fake launcher (FLEET_WRAP_LAUNCH) that "starts" in BOOT seconds and then
# runs the UserPromptSubmit hook the way Claude does; the checkout is slowed by the
# FLEET_SPAWN_FILL_CMD seam.
#
#   OVERLAP   the agent starts before the tree is whole, with CLAUDE.md already
#             there; its first prompt waits until the tree is whole; ↵→ready
#             (t_accepted → t_ready) ≤ 4.5 s where the old order needs ≥ 5 s;
#             --print names the window; the spawn returns only once filled.
#   STAMPS    the window carries @issue @fleet_id @born @fleet_role @reap_policy
#             @repo @worktree from the one batched call.
#   SCOPED    `fleet-control-read.sh workers <sess> <window>` lists that window
#             alone; without it, every window, as before.
#   FAILFILL  a checkout that fails closes the window, removes the worktree and
#             exits 1 "worktree checkout" — no orphan window.
#   OFF       FLEET_SPAWN_OVERLAP=0: the old order — the tree is whole before the
#             agent starts, no FLEET_WT_PENDING.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
command -v tmux >/dev/null 2>&1 || { echo "SKIP no tmux"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP no python3"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cold-ovl.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SESS="ovl2237-$$"
TM() { tmux -L "$SESS" "$@"; }
cleanup() { TM kill-server >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2
         [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- spawn.err ---\n%s\n--- agent ---\n%s\n' "$(cat "$WORK/spawn.err" 2>/dev/null)" \
           "$(cat "$WORK"/agent-* 2>/dev/null)" >&2
         exit 1; }
now() { python3 -c 'import time; print("%.3f" % time.time())'; }

# --- a real repo with a remote, CLAUDE.md and a "big" file --------------------
mkdir -p "$WORK/origin.git" "$WORK/main" "$WORK/fakebin" "$WORK/conf" "$WORK/tmp"
git init -q --bare "$WORK/origin.git"
(
  cd "$WORK/main" || exit 1
  git init -q -b master . && git config user.email t@t && git config user.name t
  printf 'project rules\n' > CLAUDE.md
  mkdir -p src && printf 'body\n' > src/big.txt
  git add -A && git commit -qm init
  git remote add origin "$WORK/origin.git" && git push -q origin master
) || fail "setup: repo"

# --- fake gh: nothing to say ---------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/gh"
# --- the fake agent: starts in BOOT s, then submits its first prompt -----------
# It notes what it saw as it started and once its UserPromptSubmit hook let the
# prompt through (the hook is the real set-claude-state.sh, as Claude runs it).
cat > "$WORK/fakebin/agent" <<'AGENT'
#!/bin/bash
w=$(tmux display-message -p -t "$TMUX_PANE" '#{@issue}')
out="$AGENT_LOG-$w"
{ printf 't_boot=%s\n' "$(python3 -c 'import time; print("%.3f" % time.time())')"
  [ -f CLAUDE.md ] && echo boot_claude=1 || echo boot_claude=0
  [ -f src/big.txt ] && echo boot_big=1 || echo boot_big=0
  printf 'pending=%s\n' "${FLEET_WT_PENDING:-}"; } > "$out"
sleep "$BOOT"
sh "$STATE_HOOK" working </dev/null
{ printf 't_ready=%s\n' "$(python3 -c 'import time; print("%.3f" % time.time())')"
  [ -f src/big.txt ] && echo ready_big=1 || echo ready_big=0; } >> "$out"
sleep 60
AGENT
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/agent"

unset CCQUOTA_FLEET FLEET_SPAWN_NODE FLEET_AGENT FLEET_WORKTREE_SETUP
export FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp"
env PATH="$WORK/fakebin:$PATH" FLEET_WRAP_LAUNCH="$WORK/fakebin/agent" FLEET_WRAP_FAST_FAIL=0 \
  AGENT_LOG="$WORK/agent" BOOT=2.5 STATE_HOOK="$BIN/set-claude-state.sh" \
  tmux -L "$SESS" -f /dev/null new-session -d -s "$SESS" -n home || fail "setup: tmux"

# spawn <issue> [env…] — the real spawn, headless into $SESS, its start time kept
spawn() {
  local n=$1; shift
  rm -f "$WORK/spawn.out" "$WORK/spawn.err"
  T0=$(now)
  env "$@" PATH="$WORK/fakebin:$PATH" FLEET_ORIGIN_GATE=0 FLEET_PRESPAWN_DEDUP=0 \
    FLEET_REPO=acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master \
    FLEET_WORKTREE_ROOT="$WORK/wt" \
    "$SPAWN" "$n" "$SESS" --title "task $n" --origin hub --print \
    >"$WORK/spawn.out" 2>"$WORK/spawn.err"
  SRC=$?
  T1=$(now)
}
field() { sed -n "s/^$2=//p" "$WORK/agent-$1" 2>/dev/null | tail -1; }
wait_ready() { local i=0; while [ -z "$(field "$1" t_ready)" ] && [ $i -lt 150 ]; do sleep 0.1; i=$((i + 1)); done; }
secs() { python3 -c "print('%.2f' % ($2 - $1))"; }
le() { python3 -c "import sys; sys.exit(0 if $1 <= $2 else 1)"; }

# ===== OVERLAP ================================================================
spawn 11 FLEET_SPAWN_FILL_CMD='sleep 2.5; git -C "$1" reset -q --hard'
[ "$SRC" = 0 ] || fail "OVERLAP spawn rc=$SRC"
win=$(tail -1 "$WORK/spawn.out")
case "$win" in @[0-9]*) ;; *) fail "OVERLAP --print names the window" "$(cat "$WORK/spawn.out")" ;; esac
[ -f "$WORK/wt/main-issue-11/src/big.txt" ] || [ -n "$(find "$WORK/wt" -path '*issue-11/src/big.txt' 2>/dev/null)" ] \
  || fail "OVERLAP the spawn returns only once the tree is whole" "$(ls -R "$WORK/wt" 2>/dev/null | head)"
wait_ready 11
[ -n "$(field 11 t_ready)" ] || fail "OVERLAP the agent's first prompt went through"
[ "$(field 11 boot_claude)" = 1 ] || fail "OVERLAP CLAUDE.md is there as the agent starts"
[ "$(field 11 boot_big)" = 0 ] || fail "OVERLAP the agent starts BEFORE the rest of the tree (no overlap)"
[ -n "$(field 11 pending)" ] || fail "OVERLAP the agent carries FLEET_WT_PENDING"
[ "$(field 11 ready_big)" = 1 ] || fail "OVERLAP the first prompt waits until the tree is whole"
took=$(secs "$T0" "$(field 11 t_ready)")
le "$took" 4.5 || fail "OVERLAP t_accepted → t_ready ${took}s > 4.5s (checkout 2.5s + start 2.5s run one after the other)"
ok "OVERLAP the agent starts beside the checkout: accepted → ready ${took}s ≤ 4.5s (spawn returned in $(secs "$T0" "$T1")s)"

# ===== STAMPS =================================================================
opts=$(TM show-options -w -t "$win" 2>/dev/null)
for o in '@issue 11' '@fleet_role worker' '@reap_policy merged' '@repo acme/widgets' '@born' '@fleet_id' '@worktree'; do
  printf '%s\n' "$opts" | grep -q "^$o" || fail "STAMPS the window carries $o" "$opts"
done
ok "STAMPS one batched call stamps every plain option"

# ===== SCOPED =================================================================
spawn 12 FLEET_SPAWN_FILL_CMD='git -C "$1" reset -q --hard'
[ "$SRC" = 0 ] || fail "SCOPED second spawn rc=$SRC"
one=$(PATH="$WORK/fakebin:$PATH" bash "$BIN/fleet-control-read.sh" workers "$SESS" "$win" 2>/dev/null)
all=$(PATH="$WORK/fakebin:$PATH" bash "$BIN/fleet-control-read.sh" workers "$SESS" 2>/dev/null)
[ "$(printf '%s\n' "$one" | grep -c .)" = 1 ] && [ "$(printf '%s\n' "$one" | cut -f1)" = "$win" ] \
  || fail "SCOPED workers <sess> <window> lists that window alone" "$one"
printf '%s\n' "$all" | cut -f2 | grep -qx 12 && printf '%s\n' "$all" | cut -f2 | grep -qx 11 \
  || fail "SCOPED without a window it lists every window" "$all"
ok "SCOPED the adapter reads one window back when told which"

# ===== FAILFILL ===============================================================
spawn 13 FLEET_SPAWN_FILL_CMD='sleep 0.5; exit 1'
[ "$SRC" = 1 ] || fail "FAILFILL a failed checkout exits 1 (rc=$SRC)"
grep -q 'worktree checkout' "$WORK/spawn.err" || fail "FAILFILL says why"
TM list-windows -t "$SESS" -F '#{@issue}' | grep -qx 13 && fail "FAILFILL the window is closed (no orphan)"
[ -z "$(find "$WORK/wt" -maxdepth 1 -name '*issue-13' 2>/dev/null)" ] || fail "FAILFILL the worktree is removed"
ok "FAILFILL a failed checkout leaves no window and no worktree"

# ===== OFF ====================================================================
spawn 14 FLEET_SPAWN_OVERLAP=0 FLEET_SPAWN_FILL_CMD='exit 1'
[ "$SRC" = 0 ] || fail "OFF spawn rc=$SRC"
wait_ready 14
[ "$(field 14 boot_big)" = 1 ] && [ -z "$(field 14 pending)" ] \
  || fail "OFF FLEET_SPAWN_OVERLAP=0 checks the whole tree out before the agent starts"
ok "OFF FLEET_SPAWN_OVERLAP=0 keeps the old order"

printf 'dash-issue-cold-overlap-selftest: %d passed\n' "$pass"
