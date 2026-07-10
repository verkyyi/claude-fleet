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
#
# Modes:
#   (default)     reap; print a one-line summary of what was reaped
#   -n|--dry-run  report what WOULD be reaped; change nothing
#   --age MINS    override the age gate for live servers + temp dirs
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
DRY=0; VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    --age)        AGE="${2:-$AGE}"; shift ;;
    --age=*)      AGE="${1#*=}" ;;
    -h|--help)    sed -n '2,49p' "$0"; exit 0 ;;
    *)            printf 'fleet-selftest-reap: unknown arg %s\n' "$1" >&2; exit 0 ;;
  esac
  shift
done
case "$AGE" in ''|*[!0-9]*) AGE=30 ;; esac   # non-numeric → back to the default

TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$TMUX" ] || { echo "fleet-selftest-reap: tmux not installed — nothing to do"; exit 0; }

# tmux resolves its socket dir from TMUX_TMPDIR, else the hardcoded /tmp — it does
# NOT consult TMPDIR (mktemp does, which is why selftest temp dirs live elsewhere).
SOCKDIR="${FLEET_SELFTEST_REAP_SOCKDIR:-${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)}"
# mktemp roots to sweep for orphan temp dirs — $TMPDIR (where selftests mktemp -d)
# plus a bare /tmp for the harnesses that hardcode it; deduped below.
ROOTS="${FLEET_SELFTEST_REAP_ROOTS:-${TMPDIR:-/tmp} /tmp}"

sockets=0; servers=0; dirs=0        # reaped counters
say()  { [ "$VERBOSE" = 1 ] && printf '  %s\n' "$*"; return 0; }
alive() { "$TMUX" -S "$1" ls >/dev/null 2>&1; }   # server behind this socket is up?
# stale <path> — true when <path>'s mtime is older than the age gate (spares a
# run in flight). find -mmin +N is supported on both BSD (macOS) and GNU find.
stale() { [ -n "$(find "$1" -maxdepth 0 -mmin "+$AGE" 2>/dev/null)" ]; }

# --- 1 & 2: sockets in the tmux socket dir -----------------------------------
# NEVER `default` — that is the production fleet's shared server.
if [ -d "$SOCKDIR" ]; then
  for sock in "$SOCKDIR"/*; do
    [ -e "$sock" ] || continue                       # empty glob → literal, skip
    name="$(basename "$sock")"
    [ "$name" = default ] && continue                # hard rail: never the prod server
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
      *) say "live server    $name  → SPARED (not a selftest socket)" ;;
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
      rm -rf "$d" 2>/dev/null
    fi
    dirs=$((dirs + 1))
  done
done

verb="reaped"; [ "$DRY" = 1 ] && verb="would reap"
printf 'fleet-selftest-reap: %s %d dead socket(s), %d live selftest server(s), %d orphan temp dir(s)\n' \
  "$verb" "$sockets" "$servers" "$dirs"
exit 0
