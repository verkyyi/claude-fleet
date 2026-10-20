#!/bin/bash
# daemon-processtype-selftest.sh — the shipped daemon units: the RIGHT scheduling
# class, every unit deliberately classified (issue #588), and the long-lived ones
# started with a real file limit (issue #1080; was daemon-nofile-selftest.sh).
#
# macOS `ProcessType=Background` puts the job's whole process TREE at QoS
# BACKGROUND, which THROTTLES disk I/O: two identical 20k-file deletes ran at 104
# files/s (Background) vs 10967 (Standard); in the field a 308k-file `git worktree
# remove` took 67 minutes. So a daemon whose real work is bulk filesystem I/O on
# somebody's critical path stays OFF Background; a pure poller (gh/tmux/network)
# stays ON it. The table below IS that decision, pinned from both ends: an I/O
# unit must not drift back, a poller must not be quietly promoted, and a NEW
# daemon must be classified here before it can land.
#
# launchd also starts a job at the machine's default file limit (256 on macOS):
# the hub, the spinner and the credential proxy hold sockets and pipes for every
# live session, and running out shows only as events that stop arriving. So each
# carries NumberOfFiles 65536 (soft AND hard) / LimitNOFILE=65536 and logs one
# `nofile=<n>` line at every start.
#
# Exit 0 = pass. Hermetic: file reads + one python import, no launchctl/systemctl.
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
#   reconcile                     registry + transcript reads, and the sleep scan's native resume on
#                                 the user's entry/message path
#   install-sync                  `git merge --ff-only` rewrites the live
#                                 install's bin/ that every daemon and hook
#                                 execs from, then reloads the changed daemons
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
#   memguard                      a 2s KeepAlive sampler whose whole job is to act
#                                 within seconds WHILE the machine is under memory
#                                 pressure (issue #1292) — the moment a Background
#                                 QoS job is starved first
#   peerlink                      the home machine's standing ssh masters (issue
#                                 #3002): every session a view shows from another
#                                 machine streams through them, and its 2 s beat
#                                 is the rebuild bound
# POLL: gh / tmux / network polling only — Background is correct and stays.
IO_UNITS='cleanup worktree-autoclean diskguard base-sync reconcile install-sync'
CADENCE_UNITS='collect memguard peerlink'  # cred-proxy: one per machine now, not a login unit (#4710, #4809)
POLL_UNITS='spinner quotawatch ledger-watch'

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

# --- 7. the long-lived daemons start with a real file limit (#1080) ---------
WANT=65536
# the credential proxy has no per-login unit any more (issue #4674): the machine's
# one runs under the node daemon, whose own definition carries the limit its
# children inherit — its start line is still pinned below
# shellcheck disable=SC2043  # one long-lived per-login unit left (#4899)
for u in spinner; do
  f="$ROOT/launchd/com.claude-fleet.$u.plist.tmpl"
  [ -f "$f" ] || fail "$f missing"
  for k in SoftResourceLimits HardResourceLimits; do
    v=$(tr -d '\n' < "$f" | sed -n "s|.*<key>$k</key>[[:space:]]*<dict>[[:space:]]*<key>NumberOfFiles</key>[[:space:]]*<integer>\([0-9]*\)</integer>.*|\1|p")
    [ "$v" = "$WANT" ] || fail "$u plist: $k NumberOfFiles is '${v:-absent}', want $WANT"; ok
  done
  if command -v plutil >/dev/null 2>&1; then
    sed "s|__HOME__|/h|g; s|__BREW_PREFIX__|/b|g" "$f" | plutil -lint - >/dev/null || fail "$u plist no longer lints"; ok
  fi
  f="$ROOT/systemd/claude-fleet-$u.service"
  grep -qx "LimitNOFILE=$WANT" "$f" || fail "$u systemd unit: no LimitNOFILE=$WANT"; ok
done

# The hub's plist is generated by fleet-hub-service.py's launch_agent().
got=$(cd "$ROOT/bin" && python3 - <<'PY'
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location("svc", "fleet-hub-service.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = m.launch_agent(pathlib.Path("/h"), pathlib.Path("/h/py"), pathlib.Path("/h/hub.py"),
                   pathlib.Path("/h/state"), "https://mini.example:8450/mcp", 8766)
print(d["SoftResourceLimits"]["NumberOfFiles"], d["HardResourceLimits"]["NumberOfFiles"])
PY
) || fail "could not build the hub plist"
[ "$got" = "$WANT $WANT" ] || fail "hub plist NumberOfFiles soft/hard is '$got', want $WANT $WANT"; ok

# The start lines: each daemon logs nofile=<its limit> once per start.
grep -q 'nofile=.*ulimit -n' "$ROOT/bin/tmux-spinner.sh"  || fail "tmux-spinner.sh: no nofile= start line"; ok
grep -q '"nofile=".*RLIMIT_NOFILE' "$ROOT/bin/fleet_hub.py" || fail "fleet_hub.py: no nofile= start line"; ok
grep -q 'nofile=%d.*nofile)' "$ROOT/bin/fleet-cred-proxy.py" || fail "fleet-cred-proxy.py: no nofile= start line"; ok

# The spinner's line really prints, and reports the limit it was started with.
line=$(cd "$ROOT/bin" && ( ulimit -n 1000 2>/dev/null; sh -c 'BIN=.; eval "$(sed -n "/nofile=/p" tmux-spinner.sh)"' 2>&1 >/dev/null ))
case "$line" in *"nofile=1000"*) ok ;; *) fail "spinner start line printed '$line', want nofile=1000" ;; esac


n_io=0;   for u in $IO_UNITS;   do : "$u"; n_io=$((n_io + 1));     done
n_cad=0;  for u in $CADENCE_UNITS; do : "$u"; n_cad=$((n_cad + 1)); done
n_poll=0; for u in $POLL_UNITS; do : "$u"; n_poll=$((n_poll + 1)); done
printf 'selftest OK: daemon-processtype (%s assertions — %s I/O + %s cadence daemons Standard, %s pollers Background, systemd twins unthrottled, file limits %s)\n' \
  "$CHECKS" "$n_io" "$n_cad" "$n_poll" "$WANT"
