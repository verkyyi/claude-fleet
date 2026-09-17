#!/bin/bash
# worktree-autoclean-rotation-selftest.sh — the ROTATION GAP guard (issue #550).
#
# What went wrong: an account rotation (bin/fleet-migrate.sh) is a close + resume.
# It asks the walled Claude to /exit, lets the SessionEnd hook close the window,
# and opens a replacement seconds later. Through that gap the worktree has no
# window, no `@issue=<N>` binding and a pane_current_path that has not settled —
# which is precisely the state every pre-#550 gate reads as "this worker is done".
# On 2026-09-11 the janitor ticked inside such a gap on a DIRTY worktree, took the
# KEEP-but-sweep-its-orphans path (#469) and killed all 15 processes anchored to
# it — claude and the pane's shell included, so the window vanished with them. The
# same gap on a CLEAN+merged worktree would have deleted the tree out from under a
# live session instead.
#
# Two gates close it, and this pins both END TO END through the real script:
#   * LEASE      a worktree the mover has leased is KEPT, whatever tmux reports —
#                this is the only signal that covers the instant when nothing at
#                all is running in the tree (old claude gone, new one not booted).
#   * EXPIRY     a lease older than FLEET_ROTATE_LEASE_TTL is ignored, so a mover
#                killed mid-move cannot park a worktree forever.
#   * LIVE PROCS a worktree with a process running under a LIVE tmux pane is KEPT,
#                and its processes are NOT swept — the rail that would have saved
#                the 15 pids.
#   * UNCHANGED  a worktree with neither (no lease, nothing running) is still
#                PRUNEd exactly as before: this guard must not become a leak.
#
# Hermetic: the real worktree-autoclean.sh + fleet-lib.sh are symlinked into a temp
# bin/ (so $BIN/../fleet.conf cannot leak the operator's install), a per-fleet conf
# drives fleet_sockets, and fake `tmux`/`gh` stand in for the live facts. The live
# PROCESS is real — a double-forked `sleep` for the orphan, and a `sleep` under a
# tmux on a PRIVATE `-S` socket for the pane case (never a fleet's server, #159).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/worktree-autoclean.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$SRC" "$LIB"; do [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }; done
command -v git  >/dev/null 2>&1 || { echo "selftest: git absent — SKIP" >&2; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "selftest: tmux absent — SKIP" >&2; exit 0; }
if ! command -v lsof >/dev/null 2>&1 && [ ! -d /proc ]; then
  echo "selftest: neither lsof nor /proc — SKIP" >&2; exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wac-rotation.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
PROBES=""; PANE_SOCK=""
cleanup() {
  [ -n "$PROBES" ] && kill $PROBES 2>/dev/null
  # ISOLATED socket only — this is never a fleet's server (issue #159).
  [ -n "$PANE_SOCK" ] && tmux -S "$PANE_SOCK" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/logs"
ln -s "$SRC" "$WORK/bin/worktree-autoclean.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"

# --- a real base checkout + three CLEAN worktrees at HEAD ---------------------
# All three read `ancestor` from the reap gate, and no fake pane binds @issue or
# sits in any of them — so the ONLY thing deciding KEEP vs PRUNE is the #550 pair.
BASE="$WORK/base"
git init -q "$BASE"
git -C "$BASE" config user.email t@t; git -C "$BASE" config user.name t
printf 'seed\n' > "$BASE/f"; git -C "$BASE" add f; git -C "$BASE" commit -qm seed
BASE_BR="$(git -C "$BASE" branch --show-current)"
for b in 100 200 300; do
  git -C "$BASE" worktree add -q -b "issue-$b" "$WORK/base-issue-$b" >/dev/null 2>&1
done
# Keep the ancestry path independently eligible, so the liveness/lease
# assertions cannot pass merely because tip == base now refuses automatic reap.
git -C "$BASE" commit --allow-empty -qm base-advance
WT100="$WORK/base-issue-100"   # leased (rotation in flight)
WT200="$WORK/base-issue-200"   # a live pane is running in it
WT300="$WORK/base-issue-300"   # neither — must still be pruned

# --- fake tmux: a live fleet with NO panes bound anywhere ---------------------
# This is the rotation gap itself: `list-panes` answers with nothing, so @issue and
# pane_current_path are both blank for every worktree below.
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
[ "\$1" = -L ] && shift 2
cmd="\$1"; shift 2>/dev/null || true
case "\$cmd" in
  has-session)     exit 0 ;;
  list-panes)      : ;;
  list-sessions)   : ;;
  display-message) : ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$*" in
  *"pr list"*)    : ;;
  *"issue view"*) printf 'OPEN\n' ;;
  *) : ;;
esac
exit 0
GHFAKE
chmod +x "$WORK/fakebin/gh"

cat > "$WORK/conf/sess1.conf" <<EOCONF
FLEET_MAIN="$BASE"
FLEET_REPO="fake/repo"
FLEET_BASE_BRANCH="$BASE_BR"
FLEET_PROTECTED_RE='^(master|main|develop|test)\$'
EOCONF

run_wac() {   # the real janitor, with the fakes and an isolated conf dir
  PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" \
    bash "$WORK/bin/worktree-autoclean.sh" "$@" 2>"$WORK/err"
}

# --- the live pane in WT200 (a real tmux on a private socket) -----------------
PANE_SOCK="$WORK/pane.sock"
tmux -S "$PANE_SOCK" new-session -d -s t -c "$WT200" 'sleep 90' 2>/dev/null
pane_pid=""; i=0
while [ "$i" -lt 50 ]; do
  pane_pid="$(tmux -S "$PANE_SOCK" list-panes -F '#{pane_pid}' 2>/dev/null | head -1)"
  [ -n "$pane_pid" ] && break
  i=$((i+1)); sleep 0.1
done
[ -n "$pane_pid" ] || { echo "selftest: tmux would not start on an isolated socket — SKIP" >&2; exit 0; }

# --- the lease on WT100, taken the way fleet-migrate.sh takes it --------------
# shellcheck source=/dev/null
( export FLEET_CONF_DIR="$WORK/conf"; . "$LIB"; fleet_rotate_lease_take "$WT100" "selftest migrate" ) \
  || fail "could not take a rotation lease on $WT100"

# ============================ DRY RUN: the decisions =========================
out="$(run_wac --dry-run)"
printf '%s\n' "$out" | grep -Eq 'KEEP +issue-100 .*rotation in flight' \
  || fail "issue-100: a LEASED worktree must be KEPT through the rotation gap" "$out"
printf '%s\n' "$out" | grep -Eq 'PRUNE +issue-100 ' \
  && fail "issue-100: a leased worktree must never be pruned (the #550 gap)" "$out"
ok "DRY: a worktree with a rotation lease is KEPT although no pane binds it"

printf '%s\n' "$out" | grep -Eq 'KEEP +issue-200 .*live pane procs' \
  || fail "issue-200: a live pane's processes must KEEP the worktree" "$out"
printf '%s\n' "$out" | grep -Eq 'PRUNE +issue-200 ' \
  && fail "issue-200: a worktree with a live pane in it must never be pruned" "$out"
ok "DRY: a worktree running a live pane's processes is KEPT (the 15-pid repro)"

printf '%s\n' "$out" | grep -Eq 'PRUNE +issue-300 ' \
  || fail "issue-300: no lease, nothing running → must still PRUNE (no leak)" "$out"
ok "DRY: a worktree with neither signal is still pruned — the guard is not a leak"

# ============================ EXPIRY: a stale lease is ignored ===============
# Backdate the stamp past the TTL: a mover that died mid-move must not be able to
# park a worktree forever, so the gate has to fall through to the normal rules.
lease_f="$( export FLEET_CONF_DIR="$WORK/conf"; . "$LIB"; fleet_rotate_lease_file "$WT100" )"
[ -f "$lease_f" ] || fail "the lease file was not written ($lease_f)"
printf '%s %s %s %s\n' 999 "$(( $(date +%s) - 4000 ))" 900 'stale' > "$lease_f"
out="$(run_wac --dry-run)"
printf '%s\n' "$out" | grep -Eq 'PRUNE +issue-100 ' \
  || fail "issue-100: a lease older than the TTL must be ignored" "$out"
ok "EXPIRY: a lease past FLEET_ROTATE_LEASE_TTL stops protecting the worktree"
( export FLEET_CONF_DIR="$WORK/conf"; . "$LIB"; fleet_rotate_lease_take "$WT100" "selftest migrate" ) \
  || fail "could not re-take the lease"

# ============================ REAL RUN: nobody's processes die ===============
# The whole point: on the KEEP paths the janitor sweeps orphans (#469), and this is
# where it used to kill the live worker. The pane's processes must survive it.
pane_sleep="$(pgrep -P "$pane_pid" 2>/dev/null | head -1)"
run_wac >/dev/null
[ -d "$WT100" ] || fail "REAL: the leased worktree issue-100 was removed"
[ -d "$WT200" ] || fail "REAL: the worktree with a live pane (issue-200) was removed"
[ -d "$WT300" ] && fail "REAL: issue-300 (no lease, nothing running) should have been pruned"
kill -0 "$pane_pid" 2>/dev/null || fail "REAL: the live pane's shell $pane_pid was killed (the #550 false-reap)"
[ -n "$pane_sleep" ] && { kill -0 "$pane_sleep" 2>/dev/null || fail "REAL: the live pane's child $pane_sleep was killed"; }
ok "REAL: leased + pane-occupied worktrees survive, with every live process intact"
git -C "$BASE" show-ref --verify -q refs/heads/issue-100 || fail "issue-100 branch must survive"
git -C "$BASE" show-ref --verify -q refs/heads/issue-200 || fail "issue-200 branch must survive"
ok "REAL: their branches survive too"

printf '\nselftest OK: %s assertions passed (rotation-gap guard, issue #550)\n' "$pass"
exit 0
