#!/bin/bash
# daemon-processtype-selftest.sh — the shipped daemon units carry the RIGHT
# scheduling class, and every unit is deliberately classified (issue #588).
#
# Why this test exists. macOS `ProcessType=Background` in a launchd plist does
# not merely deprioritise CPU: it puts the job's whole process TREE at QoS
# BACKGROUND, which carries THROTTLED disk I/O. Measured on macOS 26 with two
# identical 20k-file trees deleted by two otherwise-identical LaunchAgents:
#
#     ProcessType=Background   20000 files in 192.05s →   104 files/s
#     ProcessType=Standard     20000 files in   1.82s → 10967 files/s
#
# ~100x, and the gap widens as the machine gets busier — in the field a
# `git worktree remove` of a 308k-file worktree crawled at ~0.4 files/s, 67
# minutes of wall clock for 54s of CPU. Every fleet daemon whose real work is
# BULK FILESYSTEM I/O on somebody's critical path (reclaim, checkout, tree walk)
# must therefore stay OFF Background; the pure pollers (gh/tmux/network, no bulk
# I/O) stay ON it, because for them Background is doing exactly what it says.
#
# The table below IS that decision, and this test pins it from both ends: an
# I/O-heavy unit must not drift back to Background, a polling unit must not be
# quietly promoted, and a NEW daemon must be classified here before it can land.
#
# Exit 0 = pass. Hermetic: pure file reads, no launchctl/systemctl, no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LA="$ROOT/launchd"
SD="$ROOT/systemd"
[ -d "$LA" ] || { printf 'selftest: %s not found\n' "$LA" >&2; exit 2; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

# --- the classification ------------------------------------------------------
# IO: bulk filesystem work on a latency-sensitive path — must NOT be Background.
#   cleanup / worktree-autoclean  `git worktree remove` (100k+ unlinks)
#   diskguard                     `du -shx` tree walks under an 8s timebox
#   base-sync                     `git pull --ff-only` rewrites the base tree
#                                 while holding the shared land lease
#   dispatch                      autofill spawns `git worktree add` (a full
#                                 checkout) synchronously as a CHILD process
#   sleep                         transcript inspection and native resume on
#                                 the user's entry/message path
# CADENCE: not bulk I/O, but a FORK-HEAVY tick whose cadence IS the product —
# must NOT be Background either (issue #651).
#   collect                       every dash cache; launchd never overlaps a
#                                 StartInterval job, so a tick longer than 60s
#                                 IS the collector's real cadence. It forks per
#                                 worktree / window / socket every tick, and
#                                 Background makes a fork ~8x dearer: 40 worktrees
#                                 x 2 git calls measured 16s under `taskpolicy -b`
#                                 vs 2s at load 12/10 cores. git, banner and
#                                 snapshot alone ate 50s of a 61s tick, and the
#                                 unit ran every 3.5-5 min instead of every 1.
# POLL: gh / tmux / network polling only — Background is correct and stays.
IO_UNITS='cleanup worktree-autoclean diskguard base-sync dispatch sleep'
CADENCE_UNITS='collect'
POLL_UNITS='pr-refresh spinner quotawatch issue-bridge ledger-watch webhook'

ptype() {  # $1 = unit → the ProcessType string, or the empty string if absent
  grep -o '<key>ProcessType</key><string>[A-Za-z]*</string>' \
    "$LA/com.claude-fleet.$1.plist.tmpl" 2>/dev/null \
    | sed 's|.*<string>||; s|</string>||'
}

# --- 1. every plist on disk is classified above (a new daemon must choose) ----
for f in "$LA"/com.claude-fleet.*.plist.tmpl; do
  u="$(basename "$f" .plist.tmpl)"; u="${u#com.claude-fleet.}"
  case " $IO_UNITS $CADENCE_UNITS $POLL_UNITS " in
    *" $u "*) ok ;;
    *) fail "daemon '$u' has a plist but no ProcessType classification in this test —
      decide whether it does bulk filesystem I/O (→ Standard) or only polls
      (→ Standard), is a fork-heavy tick whose cadence matters (→ Standard,
      CADENCE_UNITS, issue #651), or only polls (→ Background), then add it to
      IO_UNITS, CADENCE_UNITS or POLL_UNITS (issue #588)" ;;
  esac
done

# --- 2. …and every classified unit still has a plist (no stale table rows) ----
for u in $IO_UNITS $CADENCE_UNITS $POLL_UNITS; do
  [ -f "$LA/com.claude-fleet.$u.plist.tmpl" ] \
    || fail "classified unit '$u' has no launchd/com.claude-fleet.$u.plist.tmpl — retired? drop it from the table"
  ok
done

# --- 3. the I/O-heavy daemons are Standard, never Background -----------------
for u in $IO_UNITS; do
  p="$(ptype "$u")"
  [ "$p" = "Standard" ] \
    || fail "$u: ProcessType is '${p:-<absent>}', expected 'Standard' — Background throttles
      its disk I/O ~100x (issue #588). Absent is NOT good enough: launchd.plist(5)
      says an unspecified ProcessType also gets 'light resource limits ... throttling
      its CPU usage and I/O bandwidth', so the value is written out explicitly."
  ok
done

# --- 3b. the cadence-critical daemons are Standard too ----------------------
for u in $CADENCE_UNITS; do
  p="$(ptype "$u")"
  [ "$p" = "Standard" ] \
    || fail "$u: ProcessType is '${p:-<absent>}', expected 'Standard' — Background makes every
      fork of its tick ~8x dearer, so the tick outruns its 60s StartInterval and the
      dash shows a minutes-old world (issue #651)"
  ok
done

# --- 4. the pollers keep Background (don't unthrottle the whole fleet) -------
for u in $POLL_UNITS; do
  p="$(ptype "$u")"
  [ "$p" = "Background" ] \
    || fail "$u: ProcessType is '${p:-<absent>}', expected 'Background' — it only polls
      gh/tmux/network, so it should stay out of the foreground's way (issue #588)"
  ok
done

# --- 5. exactly one ProcessType key per plist (a dupe silently wins/loses) ----
for f in "$LA"/com.claude-fleet.*.plist.tmpl; do
  n="$(grep -c '<key>ProcessType</key>' "$f")"
  [ "$n" = 1 ] || fail "$(basename "$f"): $n ProcessType keys, expected exactly 1"
  ok
done

# --- 6. the systemd twins carry no Linux equivalent of the same throttle -----
# ionice idle / a positive Nice would reproduce the bug on Linux. Checked for the
# I/O-heavy units only — a poller is free to set them.
if [ -d "$SD" ]; then
  for u in $IO_UNITS $CADENCE_UNITS; do
    s="$SD/claude-fleet-$u.service"
    [ -f "$s" ] || continue          # not every launchd unit has a systemd twin
    if grep -qE '^[[:space:]]*IOSchedulingClass[[:space:]]*=[[:space:]]*(idle|3)' "$s"; then
      fail "$(basename "$s"): IOSchedulingClass=idle throttles the same bulk I/O launchd's Background did (issue #588)"
    fi
    if grep -qE '^[[:space:]]*Nice[[:space:]]*=[[:space:]]*[1-9]' "$s"; then
      fail "$(basename "$s"): a positive Nice deprioritises a reclaim path others wait on (issue #588)"
    fi
    ok
  done
fi

n_io=0;   for u in $IO_UNITS;   do : "$u"; n_io=$((n_io + 1));     done
n_cad=0;  for u in $CADENCE_UNITS; do : "$u"; n_cad=$((n_cad + 1)); done
n_poll=0; for u in $POLL_UNITS; do : "$u"; n_poll=$((n_poll + 1)); done
printf 'selftest OK: daemon-processtype (%s assertions — %s I/O + %s cadence daemons Standard, %s pollers Background, systemd twins unthrottled)\n' \
  "$CHECKS" "$n_io" "$n_cad" "$n_poll"
