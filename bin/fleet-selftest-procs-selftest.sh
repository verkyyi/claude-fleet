#!/bin/bash
# fleet-selftest-procs-selftest.sh — what a killed selftest left RUNNING does not
# stay overnight (issue #4360, EPIC #4354 C6): bin/fleet_selftest_procs.py and the
# step bin/fleet-selftest-reap.sh runs it as (hourly, on the diskguard tick).
#
# The gap: a sandbox's processes outlived their run — a host machine had
# `…/T/fns.yyu6qtxh/Users/alice/.claude/fleet/bin/keep.sh` (fleet-node-supervisor-
# selftest.py's account child) alive 2 days 15 hours and 13 `-zsh` shells sitting
# in removed `fleet-selftest-root.*` shadows for 4–6 days; the reaper removed the
# dirs and left what ran from them.
#
# Asserts (every root is a sandbox under this test's own WORK dir — the machine's
# real $TMPDIR and /tmp are never swept):
#   • YOUNG     with the 1 h gate, a fresh orphan under a test root is spared.
#   • ARGV      an orphan whose argv names a test root (its dir already removed)
#               is reaped — TERM then KILL, its child too.
#   • CWD       an orphan whose only tie is its cwd inside a test root is reaped.
#   • CREATOR   a root some live process outside the orphans still names (its
#               maker, a run in flight) keeps its orphans.
#   • NAME      an orphan under a dir that is not a test root's name survives.
#   • CHILD     a test-root process whose parent is alive (not PPID=1) survives.
#   • DRY       `fleet-selftest-reap.sh -n` counts, kills nothing; a real run
#               reports «N orphan process tree(s)».
#   • TEARDOWN  fleet-node-supervisor-selftest.py's Sandbox teardown sweeps every
#               process naming its sandbox (`sweep(...)`), so the run itself leaks none.
# Exit 0 = pass; non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
PROCS="$BIN/fleet_selftest_procs.py"
REAP="$BIN/fleet-selftest-reap.sh"
command -v python3 >/dev/null 2>&1 || { printf 'selftest: no python3 — SKIP\n' >&2; exit 0; }
[ -f "$PROCS" ] || { printf 'selftest: %s missing\n' "$PROCS" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fsprocs.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
R="$WORK/t"                         # stands in for $TMPDIR (a mktemp root)
mkdir -p "$R"

PIDS=""
cleanup() {
  local p
  for p in $PIDS; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  pkill -KILL -f "$WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
alive() { kill -0 "$1" 2>/dev/null; }
wait_gone() {   # <secs> <pid>…
  local n=$(( $1 * 10 )) p any; shift
  while [ "$n" -gt 0 ]; do
    any=0; for p in "$@"; do alive "$p" && any=1; done
    [ "$any" = 0 ] && return 0
    sleep 0.1; n=$((n - 1))
  done
  return 1
}
procs() { FLEET_SELFTEST_REAP_ROOTS="$R" python3 "$PROCS" "$@"; }

# orphan <cwd> <script> → ORPHAN = a double-forked bash (PPID=1) running <script>,
# which keeps a `sleep` child (two levels). CHILD = that sleep.
ORPHAN=""; CHILD=""
orphan() {
  local d="$1" s="$2" f="$WORK/o.$RANDOM"
  ( cd "$d" && exec nohup bash "$s" "$f" >/dev/null 2>&1 & )
  local i=0; while [ ! -s "$f.child" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  ORPHAN="$(cat "$f" 2>/dev/null)"; CHILD="$(cat "$f.child" 2>/dev/null)"; rm -f "$f" "$f.child"
  [ -n "$ORPHAN" ] && [ -n "$CHILD" ] || fail "could not start an orphan in $d"
  PIDS="$PIDS $ORPHAN $CHILD"
}
mkscript() {   # <path> — writes its pid to $1, its sleep child's to $1.child, waits
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/bash\necho $$ > "$1"\nsleep 120 & echo $! > "$1.child"\nwait\n' > "$1"
}

# ── fixtures ──────────────────────────────────────────────────────────────────
# ARGV: fns.argv/…/keep.sh — the dir is removed once it runs (as the leak was).
mkscript "$R/fns.argv/Users/alice/.claude/fleet/bin/keep.sh"
orphan "$WORK" "$R/fns.argv/Users/alice/.claude/fleet/bin/keep.sh"; P_ARGV="$ORPHAN"; C_ARGV="$CHILD"
# CWD: a `-zsh`-like shell whose argv names nothing, sitting in a shadow root.
mkdir -p "$R/fleet-selftest-root.cwd/bin"; mkscript "$WORK/cwd.sh"
orphan "$R/fleet-selftest-root.cwd/bin" "$WORK/cwd.sh"; P_CWD="$ORPHAN"; C_CWD="$CHILD"
# CREATOR: an orphan in a root whose maker still runs (a live child of this test
# whose argv names the root, as run-selftests.sh does from its shadow).
mkdir -p "$R/fleet-selftest-root.live/bin"; mkscript "$WORK/live.sh"
orphan "$R/fleet-selftest-root.live/bin" "$WORK/live.sh"; P_LIVE="$ORPHAN"
bash -c 'sleep 120; :' "$R/fleet-selftest-root.live/bin/run-selftests.sh" >/dev/null 2>&1 & P_MAKER=$!; PIDS="$PIDS $P_MAKER"
# NAME: an orphan under a dir that is no test root's name.
mkdir -p "$R/someapp.xyz"; mkscript "$WORK/name.sh"
orphan "$R/someapp.xyz" "$WORK/name.sh"; P_NAME="$ORPHAN"
# CHILD: a process naming a test root whose parent (this test) is alive.
mkscript "$R/fns.kid/kid.sh"
bash "$R/fns.kid/kid.sh" "$WORK/kid" >/dev/null 2>&1 & P_KID=$!; PIDS="$PIDS $P_KID"
sleep 0.3
rm -rf "$R/fns.argv"

# ── YOUNG ─────────────────────────────────────────────────────────────────────
out="$(procs reap --min-age 3600)"
[ -z "$out" ] || fail "YOUNG: a fresh orphan was reaped under the 1 h gate" "$out"
alive "$P_ARGV" && alive "$P_CWD" || fail "YOUNG: a fresh orphan died"
ok "YOUNG: with the 1 h gate nothing fresh is touched"

sleep 2
# ── DRY ───────────────────────────────────────────────────────────────────────
dry="$(FLEET_SELFTEST_REAP_ROOTS="$R" FLEET_SELFTEST_REAP_SOCKDIR="$WORK/nosock" bash "$REAP" -n --proc-age 1)"
case "$dry" in *"would reap"*", 2 orphan process tree(s)"*) ;; *) fail "DRY: expected 2 would-reap trees" "$dry" ;; esac
alive "$P_ARGV" && alive "$P_CWD" || fail "DRY: -n killed something"
ok "DRY: -n counts the two orphan trees and kills nothing"

# ── ARGV / CWD / CREATOR / NAME / CHILD ───────────────────────────────────────
t0=$(date +%s)
out="$(FLEET_SELFTEST_REAP_ROOTS="$R" FLEET_SELFTEST_REAP_SOCKDIR="$WORK/nosock" bash "$REAP" --proc-age 1 -v)"
case "$out" in *"reaped 0 dead socket(s), 0 live selftest server(s), 0 orphan temp dir(s), 2 orphan process tree(s)"*) ;;
  *) fail "the reaper's summary does not say 2 orphan process trees" "$out" ;; esac
wait_gone 5 "$P_ARGV" "$C_ARGV" || fail "ARGV: the orphan (or its child) naming a removed fns.* root still runs" "$out"
ok "ARGV: an orphan naming a removed test root is reaped with its child"
wait_gone 5 "$P_CWD" "$C_CWD" || fail "CWD: the orphan sitting in a shadow root still runs" "$out"
ok "CWD: an orphan whose cwd is a test root is reaped"
alive "$P_LIVE" || fail "CREATOR: an orphan whose root's maker still runs was reaped" "$out"
ok "CREATOR: a root still named by a live process outside the orphans keeps its orphans"
alive "$P_NAME" || fail "NAME: an orphan under a non-test dir was reaped" "$out"
ok "NAME: an orphan under a dir that is no test root survives"
alive "$P_KID" || fail "CHILD: a test-root process with a live parent was reaped" "$out"
ok "CHILD: a process still under its parent survives"
[ $(( $(date +%s) - t0 )) -le 10 ] || fail "the sweep took longer than 10s"

# ── the maker gone ⇒ its orphans go on the next pass ──────────────────────────
pkill -KILL -P "$P_MAKER" 2>/dev/null; kill "$P_MAKER" 2>/dev/null; wait "$P_MAKER" 2>/dev/null
procs reap --min-age 1 --grace 0.5 >/dev/null
wait_gone 5 "$P_LIVE" || fail "CREATOR: once the maker is gone the orphan should go"
ok "CREATOR: once the maker is gone, the next pass reaps its orphans"

# ── TEARDOWN ──────────────────────────────────────────────────────────────────
SUPT="$BIN/fleet-node-supervisor-selftest.py"
grep -q '^def sweep(' "$SUPT" && grep -q 'sweep(self.d, getattr(self, "short", None))' "$SUPT" \
  || fail "TEARDOWN: fleet-node-supervisor-selftest.py's Sandbox no longer sweeps its sandbox's processes"
ok "TEARDOWN: the supervisor selftest's Sandbox kills every process naming its sandbox"

printf 'PASS: selftest-procs selftest (%d checks)\n' "$pass"
