#!/bin/bash
# fleet-selftest-reap.sh — reap the debris the hermetic selftests leave behind.
#
# WHY: the fleet's selftests spin up REAL, isolated tmux servers (each on its own
# `-S <tmpdir>/tmux.sock` socket inside a `mktemp -d …selftest…` dir, torn down by
# an EXIT trap). That is well-behaved on a clean pass — but a run killed by SIGKILL,
# an OOM, or an older `-L <name>`-socket harness can leave litter on the machine
# that also runs the PRODUCTION fleet: dead sockets in the tmux socket dir, a
# long-lived orphaned `*selftest*` server still running a background loop, or an
# abandoned temp dir. Over days these pile up (issue #152 found ~50 dead sockets +
# a 2-day-old `fleet-selftest` server looping fzf against files deleted in the
# flat→checkout migration) — wasted fds/CPU and red-herrings during incident triage.
#
# This reaper is the safety net for that debris. It NEVER touches the shared
# `default` server (the production fleet lives there): every action is scoped to
# either a socket whose server is provably dead, or a socket/dir carrying the
# `selftest` token (our own naming — no real server uses it). Live selftest
# servers and temp dirs are additionally age-gated so an IN-PROGRESS run (CI or a
# worker's `run-selftests.sh`) is never yanked out from under itself.
#
# What it reaps (in the tmux socket dir ${TMUX_TMPDIR:-/tmp}/tmux-$UID and the
# mktemp roots $TMPDIR + /tmp):
#   1. DEAD sockets      — any socket (except `default`) whose `tmux -S … ls`
#                          fails: the server is gone, the file is pure litter.
#   2. LIVE selftest srv — a server whose socket name contains `selftest`, older
#                          than the age gate: kill-server (reaps its process tree,
#                          e.g. a looping-fzf orphan) + remove the socket.
#   3. ORPHAN temp dirs  — a `*selftest*` mktemp dir older than the age gate: kill
#                          any tmux server on its inner `tmux.sock`, then rm -rf it.
#   4. ORPHAN processes  — a tree whose top is ours, reparented to init (its maker
#                          is gone), older than FLEET_SELFTEST_PROC_SECS, with its
#                          argv or cwd under a test root (`fleet-selftest-root.*`,
#                          `*selftest*`, `fns.*` … in a mktemp root) and no live
#                          process outside it naming that root: TERM, then KILL
#                          (bin/fleet_selftest_procs.py, issue #4360 — a removed
#                          dir does not stop what ran from it).
#
# Modes:
#   (default)     reap; print a one-line summary of what was reaped
#   -n|--dry-run  report what WOULD be reaped; change nothing
#   --count       read-only, no age gate, one line `live=<n> dead=<n>`: live
#                 selftest servers + dead sockets (fleet-doctor's `testtmux` row)
#   --age MINS    override the age gate for live servers + temp dirs
#   --proc-age S  override the orphan-process age gate (seconds)
#   -v|--verbose  print each item as it is handled
#   -h|--help
#
# Config (fleet.conf / per-fleet conf; optional):
#   FLEET_SELFTEST_REAP_MIN_AGE   age gate in minutes (default 30). Dead sockets
#                                 are age-INDEPENDENT (a gone server is never live).
#   FLEET_SELFTEST_REAP_SOCKDIR   override the tmux socket dir to sweep
#                                 (default ${TMUX_TMPDIR:-/tmp}/tmux-$UID).
#   FLEET_SELFTEST_REAP_ROOTS     space-separated mktemp roots to sweep for
#                                 orphan temp dirs (default "$TMPDIR /tmp").
#   FLEET_SELFTEST_PROC_SECS      orphan-process age gate in seconds (default
#                                 3600; 0 = leave processes alone).
#   FLEET_SELFTEST_PROC_GLOBS     test-root names (default `fleet-selftest-root.*
#                                 fleet-selftest-* *selftest* fns.* fns-*`).
# (The two path overrides exist to scope the reaper and to let its own hermetic
#  selftest sandbox every path — the defaults are what you want in production.)
#
# Safe to run by hand or on a slow timer. Always exits 0 (a reaper must not fail
# loud). Uses the REAL tmux from PATH — its own `-S`/`-L` calls pass through the
# cw.zsh destroy-guard untouched, and it issues no destructive op on `default`.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

AGE="${FLEET_SELFTEST_REAP_MIN_AGE:-30}"
PROC_AGE="${FLEET_SELFTEST_PROC_SECS:-3600}"
DRY=0; VERBOSE=0; COUNT=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    --count)      COUNT=1 ;;
    --age)        AGE="${2:-$AGE}"; shift ;;
    --age=*)      AGE="${1#*=}" ;;
    --proc-age)   PROC_AGE="${2:-$PROC_AGE}"; shift ;;
    -h|--help)    sed -n '2,64p' "$0"; exit 0 ;;
    *)            printf 'fleet-selftest-reap: unknown arg %s\n' "$1" >&2; exit 0 ;;
  esac
  shift
done
case "$AGE" in ''|*[!0-9]*) AGE=30 ;; esac   # non-numeric → back to the default
case "$PROC_AGE" in ''|*[!0-9]*) PROC_AGE=3600 ;; esac
[ "$COUNT" = 1 ] && { DRY=1; VERBOSE=0; AGE=0; }

TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$TMUX" ] || { echo "fleet-selftest-reap: tmux not installed — nothing to do"; exit 0; }

# tmux resolves its socket dir from TMUX_TMPDIR, else the hardcoded /tmp — it does
# NOT consult TMPDIR (mktemp does, which is why selftest temp dirs live elsewhere).
SOCKDIR="${FLEET_SELFTEST_REAP_SOCKDIR:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)}"
# mktemp roots to sweep for orphan temp dirs — $TMPDIR (where selftests mktemp -d)
# plus a bare /tmp for the harnesses that hardcode it; deduped below.
ROOTS="${FLEET_SELFTEST_REAP_ROOTS:-${TMPDIR:-/tmp} /tmp}"
[ "$COUNT" = 1 ] && ROOTS=''          # the count is about sockets only

sockets=0; servers=0; dirs=0; procs=0   # reaped counters
say()  { [ "$VERBOSE" = 1 ] && printf '  %s\n' "$*"; return 0; }
alive() { "$TMUX" -S "$1" ls >/dev/null 2>&1; }   # server behind this socket is up?
# stale <path> — true when <path>'s mtime is older than the age gate (spares a
# run in flight). find -mmin +N is supported on both BSD (macOS) and GNU find.
stale() { [ "$COUNT" = 1 ] && return 0; [ -n "$(find "$1" -maxdepth 0 -mmin "+$AGE" 2>/dev/null)" ]; }
# test_server <sock> — the server behind <sock> was started `-f /dev/null` (every
# selftest's form; a fleet's server and a person's load a conf) and has no client.
test_server() {
  local pid
  pid=$("$TMUX" -S "$1" display-message -p '#{pid}' 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "$("$TMUX" -S "$1" list-clients 2>/dev/null)" ] || return 1
  case " $(ps -o command= -p "$pid" 2>/dev/null) " in *" -f /dev/null "*) return 0 ;; esac
  return 1
}

# --- 4 (first): orphaned processes under a test root ----------------------------
# Before the dirs go: a process keeps running from a removed dir, and its argv
# still names it, so order is not needed for the match — only for the log.
if [ "$COUNT" != 1 ] && [ "$PROC_AGE" -gt 0 ] && command -v python3 >/dev/null 2>&1 \
   && [ -f "$BIN/fleet_selftest_procs.py" ]; then
  pmode=reap; [ "$DRY" = 1 ] && pmode=list
  # shellcheck disable=SC2086
  pout="$(python3 "$BIN/fleet_selftest_procs.py" "$pmode" --min-age "$PROC_AGE" $ROOTS 2>/dev/null)"
  if [ -n "$pout" ]; then
    procs=$(printf '%s\n' "$pout" | grep -c .)
    [ "$VERBOSE" = 1 ] && printf '%s\n' "$pout" | sed 's/^/  orphan process /'
  fi
fi

# --- 1 & 2: sockets in the tmux socket dir -----------------------------------
# NEVER `default` — that is the production fleet's shared server.
if [ -d "$SOCKDIR" ]; then
  for sock in "$SOCKDIR"/*; do
    [ -e "$sock" ] || continue                       # empty glob → literal, skip
    name="$(basename "$sock")"
    [ "$name" = default ] && continue                # hard rail: never the prod server
    # nor any fleet's own socket (issue #2970) — a configured fleet, the client's
    # fleet-shell servers. Any other `fleet*` label is a drill's / test's (BCYB:
    # 19 `fleet-drill-drill<pid>` left behind): its dead socket goes, once past
    # the age gate (a server only busy for a moment is never taken for dead).
    case "$name" in
      fleet|fleet-shell*) continue ;;
      fleet*) { [ ! -S "$sock" ] || [ -d "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleets/$name" ] || ! stale "$sock" || alive "$sock"; } && continue ;;
    esac
    if ! alive "$sock"; then
      # dead server → the socket file is litter; remove it regardless of age.
      say "dead socket   $name"
      [ "$DRY" = 1 ] || rm -f "$sock" 2>/dev/null
      sockets=$((sockets + 1))
      continue
    fi
    # live server: only reap our own (`selftest`-named) orphans, and only once
    # they are older than the age gate (don't yank a run that's in flight).
    case "$name" in
      *selftest*)
        if stale "$sock"; then
          say "live selftest server  $name  → kill-server"
          [ "$DRY" = 1 ] || { "$TMUX" -S "$sock" kill-server 2>/dev/null; rm -f "$sock" 2>/dev/null; }
          servers=$((servers + 1))
        else
          say "live selftest server  $name  → SPARED (younger than ${AGE}m)"
        fi
        ;;
      *)
        # A selftest server under any label (issue #2970: `hubs$$`, `brk*`…): it
        # was started `-f /dev/null` — a fleet's server and a person's load a conf
        # — and nobody is attached to it. Same age gate.
        if test_server "$sock" && stale "$sock"; then
          say "live test server  $name  → kill-server (-f /dev/null, no client)"
          [ "$DRY" = 1 ] || { "$TMUX" -S "$sock" kill-server 2>/dev/null; rm -f "$sock" 2>/dev/null; }
          servers=$((servers + 1))
        else
          say "live server    $name  → SPARED (not a selftest server)"
        fi ;;
    esac
  done
fi

# --- 3: orphaned mktemp `*selftest*` dirs ------------------------------------
# Selftests mktemp -d under $TMPDIR (and some plain /tmp). A clean pass rm -rf's
# its own dir on the EXIT trap; what survives here was killed before the trap ran.
seen_root=" "
for root in $ROOTS; do
  root="${root%/}"
  case "$seen_root" in *" $root "*) continue ;; esac   # dedup TMPDIR==/tmp
  seen_root="$seen_root$root "
  [ -d "$root" ] || continue
  for d in "$root"/*selftest*; do
    [ -d "$d" ] || continue                            # dirs only (skip the socket-dir sweep's files)
    if ! stale "$d"; then
      say "temp dir       $(basename "$d")  → SPARED (younger than ${AGE}m)"
      continue
    fi
    say "orphan temp dir $(basename "$d")"
    if [ "$DRY" != 1 ]; then
      # kill any server still holding the inner socket, then drop the whole dir.
      [ -e "$d/tmux.sock" ] && "$TMUX" -S "$d/tmux.sock" kill-server 2>/dev/null
      # …and any server in a TMUX_TMPDIR it held (run-selftests.sh's per-test dir)
      for s in "$d"/tmux-*/*; do [ -S "$s" ] && "$TMUX" -S "$s" kill-server 2>/dev/null; done
      chmod u+w "$d" 2>/dev/null; [ -L "$d/bin" ] || chmod u+w "$d/bin" 2>/dev/null   # a read-only shadow root (#4668)
      rm -rf "$d" 2>/dev/null
    fi
    dirs=$((dirs + 1))
  done
done

[ "$COUNT" = 1 ] && { printf 'live=%d dead=%d\n' "$servers" "$sockets"; exit 0; }
verb="reaped"; [ "$DRY" = 1 ] && verb="would reap"
printf 'fleet-selftest-reap: %s %d dead socket(s), %d live selftest server(s), %d orphan temp dir(s), %d orphan process tree(s)\n' \
  "$verb" "$sockets" "$servers" "$dirs" "$procs"
exit 0
