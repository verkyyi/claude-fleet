#!/bin/bash
# fleet-diskguard.sh — disk-pressure circuit-breaker + runaway-writer forensics,
# plus a runaway-CPU watchdog.
#
# WHY: the fleet's tmux server is a single point of failure. When the volume that
# holds $TMPDIR/.claude-dash fills to 0 bytes, the collector's writes fail with
# ENOSPC and the tmux SERVER itself dies — taking every Claude session in every
# fleet down at once. A machine-wide disk-full is not isolated between fleets.
# The SAME shared server is also vulnerable to sustained CPU: a detached orphan
# spinning a core (issue #151, crash #3) is a second, non-disk way to overload it.
#
# This guards that in two ways:
#   1. GATE (--gate): a cheap precondition. fleet-up.sh (spawn) and
#      fleet-restore.sh --if-down (auto-restore) call it and REFUSE to add load
#      when free space is below FLEET_DISK_FLOOR_GB. That stops the crash-LOOP
#      where auto-restore rebuilds fleets straight back into a full disk.
#   2. WATCH (--watch): run frequently by launchd/systemd. When free space drops
#      below FLEET_DISK_WARN_GB it captures a forensic INCIDENT — the open-but-
#      deleted files (an unlinked fd is where a runaway's bytes hide and why they
#      vanish the instant the writer is killed), the largest just-written files,
#      and the top RSS processes — to a durable log, and fires FLEET_NOTIFY_CMD.
#      That is how we catch the next runaway red-handed instead of inferring it.
#
# Measures the volume backing $TMPDIR (where the crash actually happens), not "/".
# No sudo, no full-volume scans: lsof/find are scoped to the user + bounded roots.
#
# Modes:
#   --free            print integer GB free on the target volume; exit 0
#   --gate [floor]    exit 0 if free >= floor (default FLEET_DISK_FLOOR_GB), else
#                     print a one-line reason to stderr and exit 3
#   --watch           if free < FLEET_DISK_WARN_GB, capture an incident (cooldown-
#                     gated) + notify; ALSO runs the CPU + ORPHAN watchdogs; always
#                     exit 0 (a watcher must never fail loud)
#   --cpu-watch       run only the runaway-CPU check (what --watch also does); for
#                     testing or a standalone timer. No-op unless the CPU knobs are set
#   --orphan-watch    run only the orphaned-runaway check (what --watch also does)
#   --orphans         print the CURRENT orphan candidates, one per line, no sustain
#                     filter and no state written — what bin/fleet-doctor.sh reads,
#                     and what a human runs when the machine feels wrong. Exit 0
#                     with no output = nothing flagged.
#   --probe           capture an incident right now regardless of free space
#   --help
#
# Config (fleet.conf; all optional):
#   FLEET_DISK_FLOOR_GB     gate refusal threshold      (default 12)
#   FLEET_DISK_WARN_GB      watch capture threshold     (default 15)
#   FLEET_NOTIFY_CMD        notifier run as `$CMD "<markdown>"` on an incident
# Internal constants (no longer surfaced in fleet.conf.example / the prefix+c modal
# — issue #237 — but an override in an old conf is still honored for back-compat):
#   FLEET_DISK_TARGET       dir whose volume to measure (default $TMPDIR)
#   FLEET_DISK_COOLDOWN     min seconds between captures (default 300)
#   FLEET_RUNAWAY_CPU_PCT   %CPU that counts as "hot"    (default 0 = watchdog OFF)
#   FLEET_RUNAWAY_CPU_SECS  seconds hot before it's a runaway (default 300)
#   FLEET_RUNAWAY_CPU_ACTION on a runaway: notify | kill (default notify)
#   FLEET_ORPHAN_CPU_PCT    orphan watchdog %CPU floor   (default 50; 0 = OFF)
#   FLEET_ORPHAN_CPU_SECS   seconds hot before flagged   (default 300)
#   FLEET_ORPHAN_CPU_ACTION notify | kill                (default notify)
#   FLEET_ORPHAN_EXTRA_RE   extra ERE OR'd into the fleet fingerprint
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# --- scheduling heartbeat (issue #639) ---------------------------------------
# Stamped at the TOP, before any early exit, so "launchd never spawned me" stays
# distinguishable from "I ran and had nothing to do" — a conf-gated tick that
# exits immediately still proves it was scheduled. bin/fleet-daemon-watch.sh
# alarms on, and kicks, a unit whose stamp ages past FLEET_DAEMON_STALE_MULT ×
# this unit's StartInterval; without it, a pended unit is silent (issue #639:
# launchd stopped scheduling EVERY interval unit in this user domain and the only
# daemon anyone noticed was the one collector heartbeat #638 had instrumented).
# Only the UNIT's own mode counts: `--gate` is called by cleanup / dispatch /
# base-sync / ledger-watch on every one of THEIR ticks, and crediting those
# would keep this stamp fresh while com.claude-fleet.diskguard was never run.
# Sourcing inside the case also keeps `--gate` — four other daemons' hot path —
# from loading a lib it has no use for.
# The source is GUARDED and the stamp is a side errand: liveness instrumentation
# must never be able to kill the daemon it instruments. A half-synced install
# missing the lib then costs this unit its alarm (it reads `never`, which is
# silent by design) instead of costing the fleet the daemon.
# shellcheck source=/dev/null
case " $* " in *' --watch '*) [ -f "$BIN/fleet-daemon-lib.sh" ] && { . "$BIN/fleet-daemon-lib.sh"
  fleet_daemon_stamp_tick diskguard "$BIN/.."; } ;; esac

# shellcheck source=/dev/null
[ -f "$BIN/fleet-lib.sh" ] && . "$BIN/fleet-lib.sh"

FLOOR_GB="${FLEET_DISK_FLOOR_GB:-12}"
WARN_GB="${FLEET_DISK_WARN_GB:-15}"
TARGET="${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}"
COOLDOWN="${FLEET_DISK_COOLDOWN:-300}"
CPU_PCT="${FLEET_RUNAWAY_CPU_PCT:-0}"          # 0 = watchdog OFF (opt-in)
CPU_SECS="${FLEET_RUNAWAY_CPU_SECS:-300}"
CPU_ACTION="${FLEET_RUNAWAY_CPU_ACTION:-notify}"
# The orphan watchdog is ON by default — see orphan_candidates() for why it can
# afford to be where the tty-based one above cannot.
ORPHAN_PCT="${FLEET_ORPHAN_CPU_PCT:-50}"
ORPHAN_SECS="${FLEET_ORPHAN_CPU_SECS:-300}"
ORPHAN_ACTION="${FLEET_ORPHAN_CPU_ACTION:-notify}"
# The fleet fingerprint. `shell-snapshots/snapshot-` is the strong one: Claude
# Code sources a per-session snapshot into every shell it starts, so that literal
# appears in the argv of Claude-spawned shells and of essentially nothing else.
ORPHAN_RE_DEFAULT='shell-snapshots/snapshot-|FLEET_LOADGEN_BURNER#|/\.claude/fleet/bin/|claude-fleet'
ORPHAN_RE="$ORPHAN_RE_DEFAULT${FLEET_ORPHAN_EXTRA_RE:+|$FLEET_ORPHAN_EXTRA_RE}"
GDIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/diskguard"
STAMP="$GDIR/last-capture"

now() { date +%s; }

# Run a command with a hard wall-clock cap so a pathological directory can never
# hang the watcher. perl's alarm is present on macOS + Linux and needs no module;
# if perl is somehow absent the command simply doesn't run (the du is best-effort).
tmo() {
  local secs="$1"; shift
  command -v perl >/dev/null 2>&1 || return 0
  perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# Integer GB available on the volume backing $TARGET. Portable: df -Pk yields
# 1024-byte blocks (POSIX), Avail is field 4; macOS Data volume and Linux "/"
# both resolve correctly because we df the DIR, not a hardcoded mount.
free_gb() {
  df -Pk "$TARGET" 2>/dev/null | awk 'NR==2 { printf "%d", int($4/1048576) }'
}

notify() {   # $1=markdown message — best-effort, never fails the caller
  [ -n "${FLEET_NOTIFY_CMD:-}" ] || return 0
  "$FLEET_NOTIFY_CMD" "$1" >/dev/null 2>&1 || true
}

# Write a full forensic snapshot. $1=reason $2=free-GB. Cooldown-gated by the
# caller (--probe bypasses it). Returns the incident path on stdout.
capture() {
  local reason="$1" free="$2" ts inc
  mkdir -p "$GDIR" || return 1
  ts=$(date '+%Y%m%dT%H%M%S')
  inc="$GDIR/incident-$ts.log"
  {
    echo "# fleet-diskguard incident — $ts"
    echo "reason:   $reason"
    echo "free:     ${free}GB on volume backing $TARGET (warn<${WARN_GB} floor<${FLOOR_GB})"
    echo "host:     $(hostname 2>/dev/null)"
    echo
    echo "## df (target volume)"
    df -Ph "$TARGET" 2>/dev/null
    echo
    echo "## live fleets (tmux sessions × windows — how much load is up)"
    # Each fleet is its own tmux server on a named socket (issue #159), so fan the
    # forensic listing out across the live fleet sockets rather than one server.
    dg_socks="$(command -v fleet_sockets >/dev/null 2>&1 && fleet_sockets)"
    if [ -n "$dg_socks" ]; then
      for dg_s in $dg_socks; do
        tmux -L "$dg_s" list-sessions -F '#{session_name} (#{session_windows} windows, created #{t:session_created})' 2>/dev/null
      done
    else
      echo "(no live fleet)"
    fi
    echo
    # lsof is the primary forensic — fast (~0.2s) and it points straight at the
    # PROCESS holding the runaway. We deliberately do NOT walk the filesystem
    # (a full-tree `find` over $TMPDIR/~/.claude can take minutes and would hang
    # the watcher during the very emergency it exists for). Every open file has a
    # PID, so kill = free.
    echo "## open-but-DELETED files, largest first (lsof +L1)"
    echo "#  a runaway's bytes hide in an unlinked fd — this is what frees on kill."
    echo "#  COMMAND / PID / FD / SIZE-bytes / NAME:"
    # +L1 = files whose link count < 1 (deleted). Columns: COMMAND PID USER FD
    # TYPE DEVICE SIZE/OFF NLINK NODE NAME. Sort by SIZE/OFF (field 7) desc.
    lsof -nP +L1 2>/dev/null \
      | awk 'NR>1 && $7 ~ /^[0-9]+$/ { printf "%-14s %-8s %-5s %15d  %s\n", $1,$2,$4,$7,$NF }' \
      | sort -k4,4nr | head -20
    echo
    echo "## largest OPEN regular files >200MB (lsof) — a still-linked grower shows here"
    echo "#  COMMAND / PID / FD / SIZE-bytes / NAME:"
    lsof -nP -w 2>/dev/null \
      | awk '$5=="REG" && $7 ~ /^[0-9]+$/ && $7>209715200 { printf "%-14s %-8s %-5s %15d  %s\n", $1,$2,$4,$7,$NF }' \
      | sort -k4,4nr | awk '!seen[$0]++' | head -20
    echo
    echo "## size of fleet-owned dirs (bounded du, 8s watchdog each — never a full-volume walk)"
    for d in "${TMPDIR:-/tmp}/.claude-dash" "$HOME/.claude/projects" "$HOME/.config/claude-fleet" "$HOME/.colima"; do
      [ -d "$d" ] || continue
      printf '%12s  %s\n' "$(tmo 8 du -shx "$d" 2>/dev/null | awk '{print $1}')" "$d"
    done
    echo
    echo "## top processes by RSS"
    ps -Ao pid,rss,comm 2>/dev/null | sort -k2,2nr | head -15 \
      | awk '{ printf "%-8s %8.1fMB  %s\n", $1, $2/1024, $3 }'
  } > "$inc" 2>/dev/null
  printf '%s' "$inc"
}

# --- runaway-CPU watchdog (issue #151) --------------------------------------
# Candidate runaways: OUR-USER processes at/above $1 %CPU with NO controlling
# terminal. The no-tty filter is the safety discriminator — a reparented orphan
# has no tty, while a live worker pane has a pts, so this can never flag (or, in
# kill mode, touch) an interactive session. The shared tmux server + launchd/
# systemd are excluded outright: they are legitimately tty-less and must never be
# killed. Emits "pid|pcpu|comm" lines. Split out so the selftest can drive
# cpu_sustain() with synthetic input (real CPU load is not hermetic).
cpu_candidates() {
  local pct="$1" me; me="$(id -un 2>/dev/null)"
  ps -Ao pid=,user=,pcpu=,tty=,comm= 2>/dev/null | awk -v me="$me" -v pct="$pct" '
    { if ($2!=me) next;
      if (($3+0) < pct) next;
      t=$4; if (t!="?" && t!="??" && t!="-") next;         # has a tty → skip
      cmd=""; for (i=5;i<=NF;i++) cmd=cmd (i>5?" ":"") $i;
      if (cmd ~ /tmux|launchd|systemd|\/init$|^init$/) next; # protect infra
      print $1"|"($3+0)"|"cmd }'
}

# Sustain filter + cross-tick bookkeeping. Reads "pid|pcpu|comm" candidates on
# stdin, carries a firstseen epoch per pid across ticks in the state file ($3),
# and prints "pid<TAB>pcpu<TAB>comm" for pids continuously hot for >= $1 seconds
# (the runaways). Rewrites the state to exactly the currently-hot set, so a pid
# that cools drops out and its clock resets next time. The clock ($2) and state
# path are injected so the selftest can drive it deterministically.
cpu_sustain() {   # $1=secs  $2=nowt  $3=statefile   (candidates on stdin)
  local secs="$1" nowt="$2" state="$3" pid pcpu comm first tmp
  tmp="$(mktemp "${state}.XXXXXX" 2>/dev/null)" || tmp="${state}.new.$$"
  : > "$tmp"
  while IFS='|' read -r pid pcpu comm; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    first="$(awk -F'\t' -v p="$pid" '$1==p{print $2; exit}' "$state" 2>/dev/null)"
    case "$first" in ''|*[!0-9]*) first="$nowt" ;; esac
    printf '%s\t%s\t%s\t%s\n' "$pid" "$first" "$pcpu" "$comm" >> "$tmp"
    [ "$(( nowt - first ))" -ge "$secs" ] && printf '%s\t%s\t%s\n' "$pid" "$pcpu" "$comm"
  done
  mv -f "$tmp" "$state" 2>/dev/null || rm -f "$tmp"
}

# Forensic snapshot for a runaway-CPU incident. $1=runaway lines (pid\tpcpu\tcomm).
capture_cpu() {   # $1=runaways $2=pct $3=secs $4=action $5=killed-pids
  local runaways="$1" pct="$2" secs="$3" action="$4" killed="$5" ts inc pid
  mkdir -p "$GDIR" || return 1
  ts=$(date '+%Y%m%dT%H%M%S'); inc="$GDIR/incident-cpu-$ts.log"
  {
    echo "# fleet-diskguard runaway-CPU incident — $ts"
    echo "threshold: >=${pct}% CPU sustained >=${secs}s, no controlling tty"
    echo "action:    $action${killed:+ (SIGTERM/KILL sent to$killed)}"
    echo "host:      $(hostname 2>/dev/null)"
    echo
    echo "## flagged runaways (pid / %cpu / comm)"
    printf '%s\n' "$runaways" | awk -F'\t' 'NF{printf "%-8s %6s%%  %s\n",$1,$2,$3}'
    echo
    echo "## detail per runaway (ps: pid ppid pgid %cpu etime tty command)"
    printf '%s\n' "$runaways" | awk -F'\t' 'NF{print $1}' | while read -r pid; do
      [ -n "$pid" ] && ps -o pid=,ppid=,pgid=,pcpu=,etime=,tty=,command= -p "$pid" 2>/dev/null
    done
    echo
    echo "## top processes by %CPU"
    ps -Ao pid,pcpu,tty,comm 2>/dev/null | sort -k2,2nr | head -15
  } > "$inc" 2>/dev/null
  printf '%s' "$inc"
}

# The watchdog tick. No-op unless both CPU knobs are positive (opt-in). On a
# runaway: optionally SIGTERM→KILL (never self/parent/pid<=1/tmux), then capture
# forensics + notify (cooldown-gated separately from the disk incident). Always
# returns 0 — a watcher must never fail loud.
cpu_watch() {
  { [ "$CPU_PCT" -gt 0 ] && [ "$CPU_SECS" -gt 0 ]; } 2>/dev/null || return 0
  mkdir -p "$GDIR" 2>/dev/null || return 0
  local state="$GDIR/cpu-seen" nowt runaways; nowt="$(now)"
  runaways="$(cpu_candidates "$CPU_PCT" | cpu_sustain "$CPU_SECS" "$nowt" "$state")"
  [ -n "$runaways" ] || return 0

  local killed="" pid
  if [ "$CPU_ACTION" = kill ]; then
    local list=""
    while IFS=$'\t' read -r pid _; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      [ "$pid" -gt 1 ] || continue
      [ "$pid" = "$$" ] && continue
      [ "$pid" = "${PPID:-0}" ] && continue
      list="$list $pid"
    done <<EOF
$runaways
EOF
    if [ -n "$list" ]; then
      kill -TERM $list 2>/dev/null
      sleep 2
      for pid in $list; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null; done
      killed="$list"
    fi
  fi

  # Cooldown-gate the capture+notify (a kill, if any, already happened above).
  local cstamp="$GDIR/last-cpu-capture" last age
  last="$(cat "$cstamp" 2>/dev/null || echo 0)"; age=$(( nowt - last ))
  [ "$age" -lt "$COOLDOWN" ] && return 0
  local inc; inc="$(capture_cpu "$runaways" "$CPU_PCT" "$CPU_SECS" "$CPU_ACTION" "$killed")"
  now > "$cstamp" 2>/dev/null || true
  notify "# ⚠ fleet runaway CPU
One or more processes held ≥${CPU_PCT}% CPU for ≥${CPU_SECS}s with no controlling
terminal — a detached/reparented orphan (issue #151) that can overload the shared
tmux server. Action: \`${CPU_ACTION}\`${killed:+ — killed$killed}. Forensics:
\`$inc\`"
  return 0
}

# --- orphaned-runaway watchdog (issue #697) ---------------------------------
# The gap the 8 leaked zsh burners of 2026-09-15 fell through. Every other fleet
# orphan defense — fleet_reap_worktree_procs, the #353 liveness guard, the #550
# pane-ancestor gate — finds its targets THROUGH a worktree or a pane. Those
# burners belonged to neither: `PPID=1`, no cwd in any worktree, no pane above
# them. They held ~70% CPU each for 3h20m, took the machine to load 108 until
# `ps` itself timed out, wedged both daemons, and poisoned the orphan-rate
# evidence in #682 — and nothing in the fleet could see them.
#
# cpu_candidates() above could not cover this, and that is not an oversight: its
# discriminator is "no controlling terminal", which is ALSO true of every healthy
# Claude Bash-tool shell (measured — they run on tty `??`). Flagging those would
# make it cry wolf on every build and every test run, which is exactly why it
# ships OFF.
#
# This one discriminates on `PPID == 1` instead. A live Bash-tool shell's parent
# is its `claude`; only a process whose parent DIED reparents to init. Paired
# with a fleet argv fingerprint (ORPHAN_RE — see above) that is precise enough to
# be on by default, and it stays REPORT-ONLY by default anyway: killing a real
# long-running job by mistake is worse than missing one, so `kill` is opt-in.
#
# Emits "pid|pcpu|comm" — the same shape cpu_sustain() consumes, so the sustain
# bookkeeping is shared rather than reimplemented.
ps_all() {   # full process table, timeboxed — the machine this fires on is slow
  if command -v perl >/dev/null 2>&1; then
    tmo 15 ps -Ao pid=,ppid=,user=,pcpu=,command= 2>/dev/null
  else
    ps -Ao pid=,ppid=,user=,pcpu=,command= 2>/dev/null
  fi
}

orphan_candidates() {   # $1=pct → "pid|pcpu|comm" lines
  local pct="$1" me; me="$(id -un 2>/dev/null)"
  ps_all | awk -v me="$me" -v pct="$pct" -v re="$ORPHAN_RE" '
    { if ($3!=me) next;                                    # ours only
      if ($2!=1) next;                                     # PPID=1 ⇒ reparented
      if (($4+0) < pct) next;                              # not hot
      cmd=""; for (i=5;i<=NF;i++) cmd=cmd (i>5?" ":"") $i;
      if (cmd !~ re) next;                                 # not a fleet shape
      # Infra is legitimately PPID=1 and must never be flagged, let alone killed.
      if (cmd ~ /(^|\/)tmux |(^|\/)(launchd|systemd)( |$)|\/init$/) next;
      print $1"|"($4+0)"|"cmd }'
}

# Descendants of $1, one "pid pcpu command" row each — the burners of 2026-09-15
# each carried 8 spinning subshells, so the root alone understates the damage.
orphan_kids() {
  ps_all | awk -v p="$1" '$2==p { printf "%s %s%%", $1, $4;
    for (i=5;i<=NF;i++) printf " %s", $i; print "" }'
}

capture_orphan() {   # $1=runaways(pid\tpcpu\tcomm) $2=action $3=killed-pids
  local runaways="$1" action="$2" killed="$3" ts inc pid
  mkdir -p "$GDIR" || return 1
  ts=$(date '+%Y%m%dT%H%M%S'); inc="$GDIR/incident-orphan-$ts.log"
  {
    echo "# fleet-diskguard orphaned-runaway incident — $ts"
    echo "threshold: PPID=1, >=${ORPHAN_PCT}% CPU sustained >=${ORPHAN_SECS}s, argv matching the fleet fingerprint"
    echo "fingerprint: $ORPHAN_RE"
    echo "action:    $action${killed:+ (SIGTERM/KILL sent to$killed)}"
    echo "host:      $(hostname 2>/dev/null)"
    echo "load:      $(machine_load) on $(machine_cores) core(s)"
    echo
    echo "## flagged orphans (pid / %cpu / argv)"
    printf '%s\n' "$runaways" | awk -F'\t' 'NF{printf "%-8s %6s%%  %s\n",$1,$2,$3}'
    echo
    echo "## per-orphan detail + its descendants (each child is more load)"
    printf '%s\n' "$runaways" | awk -F'\t' 'NF{print $1}' | while read -r pid; do
      [ -n "$pid" ] || continue
      ps -o pid=,ppid=,pgid=,pcpu=,etime=,tty=,command= -p "$pid" 2>/dev/null
      orphan_kids "$pid" | sed 's/^/    ↳ /'
    done
    echo
    echo "## top processes by %CPU"
    ps -Ao pid,ppid,pcpu,etime,comm 2>/dev/null | sort -k3,3nr | head -15
  } > "$inc" 2>/dev/null
  printf '%s' "$inc"
}

# The tick. ON by default, report-only by default, always returns 0.
orphan_watch() {
  { [ "$ORPHAN_PCT" -gt 0 ] && [ "$ORPHAN_SECS" -gt 0 ]; } 2>/dev/null || return 0
  mkdir -p "$GDIR" 2>/dev/null || return 0
  local state="$GDIR/orphan-seen" nowt runaways; nowt="$(now)"
  runaways="$(orphan_candidates "$ORPHAN_PCT" | cpu_sustain "$ORPHAN_SECS" "$nowt" "$state")"
  # The doctor reads this marker, so it is refreshed (or cleared) EVERY tick —
  # a stale "runaway!" outlives the runaway and trains the operator to ignore it.
  if [ -n "$runaways" ]; then printf '%s\n' "$runaways" > "$GDIR/orphan-current"
  else rm -f "$GDIR/orphan-current" 2>/dev/null; return 0; fi

  local killed="" pid list=""
  if [ "$ORPHAN_ACTION" = kill ]; then
    while IFS=$'\t' read -r pid _; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      [ "$pid" -gt 1 ] || continue
      [ "$pid" = "$$" ] && continue
      [ "$pid" = "${PPID:-0}" ] && continue
      list="$list $pid"
    done <<EOF
$runaways
EOF
    if [ -n "$list" ]; then
      # Kill the GROUP, not the pid: the 2026-09-15 burners each carried spinning
      # subshells that a bare `kill <pid>` would have left behind as the next
      # generation of orphans.
      for pid in $list; do kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; done
      sleep 2
      for pid in $list; do kill -0 "$pid" 2>/dev/null && { kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null; }; done
      killed="$list"
    fi
  fi

  local cstamp="$GDIR/last-orphan-capture" last age
  last="$(cat "$cstamp" 2>/dev/null || echo 0)"; age=$(( nowt - last ))
  [ "$age" -lt "$COOLDOWN" ] && return 0
  local inc; inc="$(capture_orphan "$runaways" "$ORPHAN_ACTION" "$killed")"
  now > "$cstamp" 2>/dev/null || true
  notify "# ⚠ fleet orphaned runaway
$(printf '%s\n' "$runaways" | grep -c . ) process(es) with **PPID=1** held ≥${ORPHAN_PCT}% CPU for ≥${ORPHAN_SECS}s
with a fleet argv fingerprint — a leaked experiment or a worker's abandoned child
(issue #697). They belong to no worktree and no pane, so nothing else reaps them.
Action: \`${ORPHAN_ACTION}\`${killed:+ — killed$killed}. Forensics: \`$inc\`
Stop leaked load experiments with \`bin/fleet-loadgen.sh --stop\`."
  return 0
}

# --- machine load (issue #697) ----------------------------------------------
# Shared by --orphans and the incident capture, and re-read by bin/fleet-doctor.sh
# through --orphans. Portable across macOS (sysctl) and Linux (/proc).
machine_cores() {
  { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; } \
    | head -1 | awk '{ n=$1+0; print (n>0 ? n : 1) }'
}
machine_load() {   # 1-minute load average, or '' if unreadable
  { sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' \
    || awk '{print $1}' /proc/loadavg 2>/dev/null; } \
    | head -1 | awk '{ print ($1+0) }'
}

# When sourced by the selftest (FLEET_DISKGUARD_SOURCE=1) stop here: expose the
# functions above, run no mode. `return` is valid because we're being sourced.
[ "${FLEET_DISKGUARD_SOURCE:-}" = 1 ] && return 0 2>/dev/null

case "${1:-}" in
  --free)
    free_gb; echo
    ;;
  --gate)
    floor="${2:-$FLOOR_GB}"
    free=$(free_gb)
    # If df failed (empty), fail OPEN — never block the fleet on a measurement bug.
    [ -z "$free" ] && exit 0
    if [ "$free" -lt "$floor" ]; then
      echo "fleet-diskguard: LOW DISK — ${free}GB free < ${floor}GB floor on $TARGET; refusing to add fleet load" >&2
      exit 3
    fi
    ;;
  --probe)
    free=$(free_gb); [ -z "$free" ] && free=-1
    inc=$(capture "manual --probe" "$free")
    now > "$STAMP" 2>/dev/null || true
    echo "fleet-diskguard: incident written → $inc"
    ;;
  --cpu-watch)
    cpu_watch
    ;;
  --orphan-watch)
    orphan_watch
    ;;
  --orphans)
    # No sustain filter and no state: "what is hot RIGHT NOW". A human (or the
    # doctor) asking this question wants the current truth, not a 5-minute-old
    # verdict. Columns: pid / %cpu / etime / argv.
    orphan_candidates "$ORPHAN_PCT" | while IFS='|' read -r opid opcpu ocmd; do
      [ -n "$opid" ] || continue
      oet="$(ps -o etime= -p "$opid" 2>/dev/null | tr -d ' ')"
      printf '%s\t%s\t%s\t%s\n' "$opid" "$opcpu" "${oet:-?}" "$ocmd"
    done
    ;;
  --watch)
    cpu_watch                                     # runaway-CPU check runs every tick
    orphan_watch                                  # orphaned-runaway check (#697), likewise
    free=$(free_gb)
    [ -z "$free" ] && exit 0                      # measurement failed — stay quiet
    [ "$free" -ge "$WARN_GB" ] && exit 0          # healthy
    # Below warn. Cooldown-gate so a sustained low-disk episode captures once, but
    # re-capture immediately if it got materially worse (dropped ≥5GB since last).
    last=$(cat "$STAMP" 2>/dev/null || echo 0)
    lastfree=$(cat "$STAMP.free" 2>/dev/null || echo 999)
    age=$(( $(now) - last ))
    if [ "$age" -lt "$COOLDOWN" ] && [ "$free" -ge $(( lastfree - 5 )) ]; then
      exit 0
    fi
    inc=$(capture "watch: free below ${WARN_GB}GB" "$free")
    now > "$STAMP" 2>/dev/null || true
    echo "$free" > "$STAMP.free" 2>/dev/null || true
    notify "# ⚠ fleet disk low: ${free}GB free
Volume backing \`$TARGET\` is under the ${WARN_GB}GB warn line. Forensic snapshot:
\`$inc\`
Fleet spawn/auto-restore is now gated at ${FLOOR_GB}GB — inspect the incident for the runaway writer."
    ;;
  -h|--help|"")
    sed -n '2,58p' "$0"
    ;;
  *)
    echo "fleet-diskguard: unknown mode '$1' (see --help)" >&2; exit 2
    ;;
esac
exit 0
