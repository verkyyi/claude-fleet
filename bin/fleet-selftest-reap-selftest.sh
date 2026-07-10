#!/bin/bash
# fleet-selftest-reap-selftest.sh — hermetic test for the selftest cruft reaper.
#
# Drives the REAL bin/fleet-selftest-reap.sh against a fully SANDBOXED filesystem:
# both the tmux socket dir and the mktemp roots it sweeps are redirected into a
# private temp tree via FLEET_SELFTEST_REAP_{SOCKDIR,ROOTS}, so the test never
# touches the machine's real /tmp, its live `default` server, or any real debris.
# Real isolated tmux servers (each on its own -S socket, all torn down at exit)
# stand in for the leaked ones.
#
# Asserts the reaper's four rails (issue #152):
#   • DEAD socket        a socket whose server is gone is removed.
#   • `default` NEVER    a `default` socket is spared even when its server is dead.
#   • LIVE non-selftest  a live server on a non-`selftest` socket is spared.
#   • LIVE selftest      a live `*selftest*` server, aged past the gate, is
#                        killed (server + socket gone); a FRESH one is spared.
#   • ORPHAN temp dir    an aged `*selftest*` mktemp dir (with an inner server) is
#                        reaped — server killed, dir removed; a FRESH one spared.
#   • --dry-run          reports would-reap counts but changes nothing.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAP="$BIN/fleet-selftest-reap.sh"
[ -x "$REAP" ] || { printf 'selftest: %s missing/not executable\n' "$REAP" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

# Base the sandbox at /tmp (not $TMPDIR): a unix socket path has a ~104-char
# limit, and macOS's per-user $TMPDIR is long enough to blow it once nested.
WORK="$(mktemp -d /tmp/reaptest.XXXXXX)" || exit 2
SOCKDIR="$WORK/s"                        # stands in for ${TMUX_TMPDIR}/tmux-$UID
TMPROOT="$WORK/t"                        # stands in for $TMPDIR (mktemp root)
mkdir -p "$SOCKDIR" "$TMPROOT"

# Every server we start lives on a socket UNDER $WORK; one kill-all + rm at exit
# guarantees we leak nothing even if an assertion aborts mid-run (INT/TERM too).
started=""   # newline-separated list of sockets we booted
boot() {     # boot <socket-path> [session-name] → start a detached isolated server
  local s="$1" n="${2:-t}"
  "$REAL_TMUX" -S "$s" new-session -d -s "$n" -x 80 -y 24 2>/dev/null \
    || fail "could not start isolated server on $s"
  started="$started$s"$'\n'
}
cleanup() {
  local s
  while IFS= read -r s; do [ -n "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done <<< "$started"
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# run the reaper with the sandbox wired in; args pass through
reap() { FLEET_SELFTEST_REAP_SOCKDIR="$SOCKDIR" FLEET_SELFTEST_REAP_ROOTS="$TMPROOT" \
           bash "$REAP" "$@"; }

# age a path past the default 30m gate (BSD+GNU touch both take -t CCYYMMDDhhmm).
age() { touch -t 202001010000 "$1" 2>/dev/null; }

# ============================================================================
# Socket-dir fixtures (sweeps 1 & 2)
# ============================================================================
# (a) DEAD ordinary socket — a plain file the reaper can't `ls` → litter.
touch "$SOCKDIR/deadone"
# (b) DEAD `default` — must be spared even though it's dead (production rail).
touch "$SOCKDIR/default"
# (c) LIVE non-selftest server — must be spared.
boot "$SOCKDIR/keepme" keepme
# (d) LIVE selftest server, AGED → must be killed.
boot "$SOCKDIR/bindtest-selftest" oldst
age  "$SOCKDIR/bindtest-selftest"
# (e) LIVE selftest server, FRESH → must be spared (an in-flight run).
boot "$SOCKDIR/fresh-selftest" freshst

# ============================================================================
# mktemp-root fixtures (sweep 3)
# ============================================================================
# (f) ORPHAN aged temp dir with an inner live server → reaped (server + dir).
ORPH="$TMPROOT/dm-selftest.orphanAA"; mkdir -p "$ORPH"
boot "$ORPH/tmux.sock" orph
age  "$ORPH"
# (g) FRESH temp dir → spared.
FRESHD="$TMPROOT/dm-selftest.freshBB"; mkdir -p "$FRESHD"
# (h) a NON-selftest dir → never considered.
KEEPD="$TMPROOT/unrelated-work"; mkdir -p "$KEEPD"

# ============================================================================
# 1. --dry-run changes nothing
# ============================================================================
out="$(reap --dry-run 2>&1)" || fail "dry-run should exit 0"
case "$out" in *"would reap"*) ;; *) fail "dry-run summary should say 'would reap' (got: $out)";; esac
[ -e "$SOCKDIR/deadone" ]                || fail "dry-run must NOT remove the dead socket"
"$REAL_TMUX" -S "$SOCKDIR/bindtest-selftest" ls >/dev/null 2>&1 \
  || fail "dry-run must NOT kill the aged selftest server"
[ -d "$ORPH" ]                           || fail "dry-run must NOT remove the orphan temp dir"

# ============================================================================
# 2. real reap — the destructive pass
# ============================================================================
out="$(reap 2>&1)" || fail "reap should exit 0"

# (a) dead socket gone
[ -e "$SOCKDIR/deadone" ] && fail "dead socket should be removed"
# (b) default spared
[ -e "$SOCKDIR/default" ] || fail "default socket must NEVER be removed"
# (c) live non-selftest spared
"$REAL_TMUX" -S "$SOCKDIR/keepme" ls >/dev/null 2>&1 \
  || fail "a live non-selftest server must be spared"
# (d) aged live selftest killed + socket gone
"$REAL_TMUX" -S "$SOCKDIR/bindtest-selftest" ls >/dev/null 2>&1 \
  && fail "an aged live *selftest* server should be killed"
[ -e "$SOCKDIR/bindtest-selftest" ] && fail "the killed selftest server's socket should be removed"
# (e) fresh live selftest spared (younger than the age gate)
"$REAL_TMUX" -S "$SOCKDIR/fresh-selftest" ls >/dev/null 2>&1 \
  || fail "a FRESH live selftest server must be spared (in-flight run)"
# (f) aged orphan temp dir reaped (inner server killed, dir gone)
[ -d "$ORPH" ] && fail "an aged orphan *selftest* temp dir should be removed"
# (g) fresh temp dir spared
[ -d "$FRESHD" ] || fail "a FRESH selftest temp dir must be spared"
# (h) unrelated dir untouched
[ -d "$KEEPD" ] || fail "a non-selftest dir must never be touched"

# summary must report the three aged reaps (1 dead sock + 1 live srv + 1 dir).
case "$out" in
  *"reaped 1 dead socket(s), 1 live selftest server(s), 1 orphan temp dir(s)"*) ;;
  *) fail "unexpected reap summary: $out" ;;
esac

# ============================================================================
# 3. idempotent — a second reap finds nothing new to reap
# ============================================================================
out="$(reap 2>&1)" || fail "second reap should exit 0"
case "$out" in
  *"reaped 0 dead socket(s), 0 live selftest server(s), 0 orphan temp dir(s)"*) ;;
  *) fail "a second reap should be a no-op (got: $out)" ;;
esac

printf 'selftest PASS: reaper drops dead sockets + aged selftest servers/dirs, spares default/live/fresh\n'
exit 0
