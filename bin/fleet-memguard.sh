#!/bin/bash
# fleet-memguard.sh — stop a session's command that is eating the machine's
# memory, within seconds; report a long-lived orphan holding memory the same day
# (issue #1292, EPIC #1291).
#
# WHY: 2026-10-03 the Mac mini froze and rebooted with every session on it. One
# inspection `git` went from nothing to ~40 GB in about two seconds; beside it,
# three headless-browser orphans had been holding ~50 GB for five days. Nothing
# in the fleet watched memory. The diskguard tick is 60s — that git was over in
# 2 — so this is its own KeepAlive daemon sampling every FLEET_MEM_INTERVAL (2s).
# A sample is ONE `ps` (fleet_proc_mem_rows, ~40ms); the pressure probe and any
# lsof run only when a row has already crossed a line.
#
# Three rules, every one scoped to OUR processes (fleet_proc_mem_rows' class:
# a command an agent or a fleet pane started, or an orphan whose cwd is a fleet
# anchor) — never the operator's own apps, never a machine-wide hunt:
#
#   A  spike   all THREE at once → kill (FLEET_MEM_SPIKE_ACTION, default kill):
#              ① RSS grew ≥ FLEET_MEM_SPIKE_GROW_MB (4096) within the last
#                FLEET_MEM_SPIKE_WINDOW seconds (10; a process younger than the
#                window grew from nothing);
#              ② the machine is already under pressure (fleet_mem_probe ≥ warn);
#              ③ it is not an agent (claude / codex — losing a session is the
#                outage this guards against, so a session is only ever RECORDED)
#                and not FLEET_MEM_EXEMPT_RE.
#              A build that grows slowly to 12 GB never meets ①; a fast spike on
#              a relaxed machine meets ① but not ② — both are recorded, not killed.
#   A' hard    a non-agent, non-exempt fleet process at ≥ FLEET_MEM_PROC_HARD_PCT
#              (50) % of physical memory → kill, whatever its growth or the
#              pressure (same ACTION knob).
#   B  orphan  PPID=1, cwd a fleet anchor, RSS > FLEET_MEM_ORPHAN_MB (2048), alive
#              > FLEET_MEM_ORPHAN_SECS (6h) → FLEET_MEM_ORPHAN_ACTION (default
#              report). Swept every FLEET_MEM_ORPHAN_EVERY (60s).
#
# A kill is SIGKILL to that ONE pid — not its group, not its session: the shell
# that ran it sees exit 137 and the session carries on. The pane's window gets
# `@mem_killed` (what was stopped, how big, when) for the dash, FLEET_NOTIFY_CMD
# gets one message, and diskguard/incident-mem-<ts>.log keeps the evidence.
# Every pid is notified ONCE, whatever happens to it next.
#
# Modes:
#   --daemon            the KeepAlive loop (com.claude-fleet.memguard)
#   --once [--dry-run]  one pass, printing every candidate and the action it gets
#                       (`--dry-run`: act on nothing, write nothing). A single pass
#                       has no history, so growth counts only for a process younger
#                       than the window. Also prints diskguard's CPU orphans, so the
#                       two watchdogs' views sit side by side.
#   --help
#
# Config (fleet.conf / fleet.settings; all optional):
#   FLEET_MEMGUARD            0 = the daemon idles (default 1)
#   FLEET_MEM_INTERVAL        seconds between samples        (default 2)
#   FLEET_MEM_SPIKE_GROW_MB   growth that counts as a spike  (default 4096)
#   FLEET_MEM_SPIKE_WINDOW    seconds the growth is measured over (default 10)
#   FLEET_MEM_SPIKE_ACTION    kill | report                  (default kill; rules A and A')
#   FLEET_MEM_PROC_HARD_PCT   % of physical memory for rule A' (default 50; 0 = off)
#   FLEET_MEM_EXEMPT_RE       ERE of argv never killed (recorded as exempt)
#   FLEET_MEM_ORPHAN_MB       orphan RSS floor               (default 2048)
#   FLEET_MEM_ORPHAN_SECS     orphan minimum age             (default 21600 = 6h)
#   FLEET_MEM_ORPHAN_ACTION   report | kill                  (default report)
#   FLEET_MEM_ORPHAN_EVERY    seconds between orphan sweeps  (default 60)
#   FLEET_MEM_KILLED_TTL      seconds the dash keeps `@mem_killed` (default 3600)
#   FLEET_METRICS             0 = no 10s machine-metrics rows under pressure (default 1;
#                             the rows land beside diskguard's in machine/metrics-*.tsv, #1294)
#   FLEET_NOTIFY_CMD          notifier run as `$CMD "<markdown>"`
# Stubs (selftests): FLEET_MEM_PS_CMD, FLEET_MEM_PROBE_CMD, FLEET_MEM_TOTAL_MB.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
_fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings"; [ -f "$_fs" ] && . "$_fs"   # the login's settings win (#979)
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
# shellcheck source=/dev/null
[ -f "$BIN/fleet-daemon-lib.sh" ] && . "$BIN/fleet-daemon-lib.sh"

num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
INTERVAL=$(num "${FLEET_MEM_INTERVAL:-}" 2); [ "$INTERVAL" -ge 1 ] || INTERVAL=1
METRICS_EVERY=$(( 10 / INTERVAL )); [ "$METRICS_EVERY" -ge 1 ] || METRICS_EVERY=1   # samples per ~10s metrics row
GROW_MB=$(num "${FLEET_MEM_SPIKE_GROW_MB:-}" 4096)
WINDOW=$(num "${FLEET_MEM_SPIKE_WINDOW:-}" 10)
HARD_PCT=$(num "${FLEET_MEM_PROC_HARD_PCT:-}" 50)
SPIKE_ACTION="${FLEET_MEM_SPIKE_ACTION:-kill}"
ORPHAN_MB=$(num "${FLEET_MEM_ORPHAN_MB:-}" 2048)
ORPHAN_SECS=$(num "${FLEET_MEM_ORPHAN_SECS:-}" 21600)
ORPHAN_ACTION="${FLEET_MEM_ORPHAN_ACTION:-report}"
ORPHAN_EVERY=$(num "${FLEET_MEM_ORPHAN_EVERY:-}" 60)
EXEMPT_RE="${FLEET_MEM_EXEMPT_RE:-}"
GDIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/diskguard"
SEEN="$GDIR/memguard-seen"          # "<pid>:<argv-cksum>" per line — notify once per process
MARKS="$GDIR/memguard-marks"        # "<epoch>\t<socket>\t<window_id>" — @mem_killed to clear
MARK_TTL=$(num "${FLEET_MEM_KILLED_TTL:-}" 3600)
TAB="$(printf '\t')"

now() { date +%s; }

notify() {   # $1 = markdown — best-effort, never fails the caller
  [ -n "${FLEET_NOTIFY_CMD:-}" ] || return 0
  "$FLEET_NOTIFY_CMD" "$1" >/dev/null 2>&1 || true
}

# pressure → 1|2|4 (1 when the probe says nothing: never kill on a missing reading)
pressure() {
  local l; l="$(fleet_mem_probe | awk 'NF{print $1+0; exit}')"
  case "$l" in 2|4) printf '%s' "$l" ;; *) printf '1' ;; esac
}

# seen <key> — 0 if already notified; mark <key> seen otherwise (unless dry).
seen() {
  grep -qxF -- "$1" "$SEEN" 2>/dev/null && return 0
  [ "$DRY" = 1 ] && return 1
  mkdir -p "$GDIR" 2>/dev/null && printf '%s\n' "$1" >> "$SEEN"
  if [ "$(wc -l < "$SEEN" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 200 "$SEEN" > "$SEEN.t" 2>/dev/null && mv "$SEEN.t" "$SEEN"
  fi
  return 1
}

# The pane a pid runs under, as "<socket>\t<window_id>", from the tick's own ps
# table (ancestry) and each fleet socket's pane pids. Nothing when none is.
pane_of() {   # $1=pid $2=rows
  local pid="$1" rows="$2" chain s
  chain="$(printf '%s\n' "$rows" | awk -F'\t' -v p="$pid" '
    { par[$1] = $2 } END { q = p; h = 0; while (q > 1 && h++ < 64) { print q; q = par[q] } }')"
  command -v fleet_sockets >/dev/null 2>&1 || return 0
  for s in $(fleet_sockets 2>/dev/null); do
    tmux -L "$s" list-panes -a -F '#{pane_pid}	#{window_id}' 2>/dev/null \
      | awk -F'\t' -v s="$s" -v c="$(printf '%s' "$chain" | tr '\n' ' ')" '
        BEGIN { n = split(c, a, / +/); for (i = 1; i <= n; i++) if (a[i] != "") w[a[i]] = 1 }
        ($1 in w) { print s "\t" $2; f = 1; exit } END { exit !f }' && return 0
  done
  return 0
}

incident() {   # $1=title $2=body → path on stdout
  local ts inc
  mkdir -p "$GDIR" 2>/dev/null || return 0
  ts=$(date '+%Y%m%dT%H%M%S'); inc="$GDIR/incident-mem-$ts-$$.log"
  {
    echo "# fleet-memguard — $1 — $ts"
    echo "host:     $(hostname 2>/dev/null)"
    echo "pressure: $(fleet_mem_probe) (level avail% compressor% swapMB) of $(fleet_mem_total_mb) MB"
    echo
    printf '%s\n' "$2"
    echo
    echo "## top processes by RSS (pid ppid rssMB age_s class argv)"
    printf '%s\n' "$ROWS" | head -15 | awk -F'\t' '{ printf "%-7s %-7s %7s %8s %-6s %s\n", $1, $2, $3, $4, $5, substr($6, 1, 160) }'
  } >> "$inc" 2>/dev/null
  printf '%s' "$inc"
}

# act <rule> <pid> <rssMB> <grewMB> <age> <class> <argv> <action>
#   action: kill | report | record (record = log only, no notify)
act() {
  local rule="$1" pid="$2" rss="$3" grew="$4" age="$5" cls="$6" argv="$7" action="$8"
  local key short verdict="" pane="" inc gb
  # once per PROCESS: the pid plus its argv, so a reused pid is a new process
  key="$pid:$(printf '%s' "$argv" | cksum | tr -c '0-9\n' '_')"
  short="$(printf '%s' "$argv" | awk '{ print substr($0, 1, 100) }')"
  gb="$(awk -v m="$rss" 'BEGIN{ printf "%.1f", m/1024 }')"
  if [ "$ONCE" = 1 ]; then
    printf '%s\t%s\t%s\t%sMB\t+%sMB\t%s\t%s\n' "$rule" "$([ "$DRY" = 1 ] && echo "would-$action" || echo "$action")" \
      "$pid" "$rss" "$grew" "$cls" "$short"
  fi
  [ "$DRY" = 1 ] && return 0
  if [ "$action" = kill ]; then
    # The kill is NOT gated on "seen": a process that survived an earlier pass
    # (a report-only window, a failed kill) and still crosses the line goes now.
    [ "$pid" -gt 1 ] 2>/dev/null && [ "$pid" != "$$" ] || return 0
    pane="$(pane_of "$pid" "$ROWS")"
    if kill -KILL "$pid" 2>/dev/null; then verdict="killed (SIGKILL; its shell sees exit 137)"
    else verdict="kill FAILED (gone already, or not ours)"; fi
    if [ -n "$pane" ]; then
      tmux -L "${pane%%"$TAB"*}" set-option -w -t "${pane#*"$TAB"}" @mem_killed \
        "$(date '+%H:%M') $rule pid $pid ${gb}G exit 137: $short" 2>/dev/null \
        && { mkdir -p "$GDIR" 2>/dev/null; printf '%s\t%s\n' "$(now)" "$pane" >> "$MARKS"; }
    fi
  fi
  seen "$key" && return 0
  case "$action" in
    report) verdict="reported (not killed: action=report)" ;;
    record) verdict="recorded only" ;;
  esac
  inc="$(incident "$rule pid $pid" "rule:    $rule
action:  $verdict
pid:     $pid (class $cls, up ${age}s)
rss:     ${rss} MB (grew ${grew} MB in ${WINDOW}s)
argv:    $argv
window:  ${pane:-none}")"
  [ "$action" = record ] && return 0
  notify "# ⚠ fleet memguard: $([ "$action" = kill ] && echo "stopped" || echo "flagged") pid $pid at ${gb} GB
\`$short\`
Rule **$rule** — $verdict.$([ -n "$pane" ] && printf ' Window %s:%s has `@mem_killed`.' "${pane%%"$TAB"*}" "${pane#*"$TAB"}")
Forensics: \`$inc\`"
  return 0
}

# The dash badge is news, not history: clear @mem_killed once it is MARK_TTL old.
clear_marks() {
  [ -s "$MARKS" ] || return 0
  local t keep='' ts sock win; t=$(now)
  while IFS="$TAB" read -r ts sock win; do
    [ -n "$win" ] || continue
    if [ $(( t - ${ts:-0} )) -ge "$MARK_TTL" ]; then
      tmux -L "$sock" set-option -wu -t "$win" @mem_killed 2>/dev/null || :
    else keep="$keep$ts$TAB$sock$TAB$win
"; fi
  done < "$MARKS"
  printf '%s' "$keep" > "$MARKS.t" 2>/dev/null && mv "$MARKS.t" "$MARKS"
}

exempt() { [ -n "$EXEMPT_RE" ] && printf '%s' "$1" | grep -Eq -- "$EXEMPT_RE"; }

# Is an orphan row ours? Only asked for a row that has already crossed a line.
orphan_ours() { [ -n "$(fleet_listen_anchor "$(fleet_proc_cwd "$1")")" ]; }

TOTAL_MB=$(num "$(fleet_mem_total_mb)" 0)
HIST=''          # "<ts>\t<pid>\t<rssMB>" samples inside the window (daemon only)
LAST_ORPHAN=0
PRIMED=0         # 1 once the ring holds a sample (see tick)
ROWS=''

tick() {
  local t; t=$(now)
  ROWS="$(fleet_proc_mem_rows)"
  [ -n "$ROWS" ] || return 0
  local hard=0
  [ "$HARD_PCT" -gt 0 ] && [ "$TOTAL_MB" -gt 0 ] && hard=$(( TOTAL_MB * HARD_PCT / 100 ))
  # growth per pid: now − min(sample in window); a process younger than the window
  # grew from nothing. The history keeps only rows ≥ 256 MB (a busy box has ~600
  # processes), so once a sample exists (PRIMED) a pid ABSENT from it was small a
  # moment ago and counts from 0 — a 100 MB node that jumps to 5 GB is a spike.
  # Before the first sample (a fresh daemon, --once) absence means nothing.
  local cands
  cands="$( { printf '%s\n' "$HIST" | sed 's/^/H\t/'; printf '%s\n' "$ROWS" | sed 's/^/R\t/'; } | awk -F'\t' \
    -v t="$t" -v w="$WINDOW" -v g="$GROW_MB" -v hard="$hard" -v primed="$PRIMED" '
    $1 == "H" && $2 != "" { if ($2 >= t - w) { if (!($3 in mn) || $4 < mn[$3]) mn[$3] = $4 }; next }
    $1 == "R" { pid = $2; rss = $4; age = $5; cls = $6
      if (cls == "other") next
      base = (age <= w ? 0 : ((pid in mn) ? mn[pid] : (primed && age > w ? 0 : rss))); grew = rss - base
      if (grew < 0) grew = 0
      r = ""
      if (hard > 0 && rss >= hard) r = "hard"
      else if (grew >= g) r = "spike"
      if (r != "") { a = ""; for (i = 7; i <= NF; i++) a = a (i > 7 ? "\t" : "") $i
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", r, pid, rss, grew, age, cls, a } }')"
  if [ "$ONCE" = 0 ]; then
    HIST="$( { printf '%s\n' "$HIST"; printf '%s\n' "$ROWS" | awk -F'\t' -v t="$t" '$3 >= 256 { print t "\t" $1 "\t" $3 }'; } \
      | awk -F'\t' -v c="$(( t - WINDOW - INTERVAL ))" 'NF == 3 && $1 >= c')"
    PRIMED=1
  fi

  local rule pid rss grew age cls argv lvl=''
  while IFS="$TAB" read -r rule pid rss grew age cls argv; do
    [ -n "$pid" ] || continue
    [ "$pid" = "$$" ] && continue
    if [ "$cls" = orphan ]; then orphan_ours "$pid" || continue; cls="orphan@fleet"; fi
    if [ "$cls" = agent ]; then act "$rule" "$pid" "$rss" "$grew" "$age" "$cls" "$argv" record; continue; fi
    if exempt "$argv"; then act "$rule-exempt" "$pid" "$rss" "$grew" "$age" "$cls" "$argv" record; continue; fi
    if [ "$rule" = spike ]; then
      [ -n "$lvl" ] || lvl="$(pressure)"
      if [ "$lvl" -lt 2 ]; then act spike-relaxed "$pid" "$rss" "$grew" "$age" "$cls" "$argv" record; continue; fi
    fi
    case "$SPIKE_ACTION" in kill) act "$rule" "$pid" "$rss" "$grew" "$age" "$cls" "$argv" kill ;;
      *) act "$rule" "$pid" "$rss" "$grew" "$age" "$cls" "$argv" report ;; esac
  done <<EOF
$cands
EOF

  # B — long-lived orphans holding memory (throttled; lsof only for the few over the line)
  if [ "$ONCE" = 1 ] || [ $(( t - LAST_ORPHAN )) -ge "$ORPHAN_EVERY" ]; then
    LAST_ORPHAN=$t

    printf '%s\n' "$ROWS" | awk -F'\t' -v m="$ORPHAN_MB" -v s="$ORPHAN_SECS" \
      '$5 == "orphan" && $3 > m && $4 > s' | while IFS="$TAB" read -r pid _ rss age cls argv; do
      [ -n "$pid" ] || continue
      orphan_ours "$pid" || continue
      exempt "$argv" && continue
      case "$ORPHAN_ACTION" in kill) act orphan "$pid" "$rss" 0 "$age" "$cls" "$argv" kill ;;
        *) act orphan "$pid" "$rss" 0 "$age" "$cls" "$argv" report ;; esac
    done
  fi
  return 0
}

DRY=0; ONCE=0; MODE=''
for a in "$@"; do
  case "$a" in
    --daemon) MODE=daemon ;;
    --once) MODE=once ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,66p' "$0"; exit 0 ;;
    *) printf 'fleet-memguard: unknown argument %s (see --help)\n' "$a" >&2; exit 2 ;;
  esac
done

case "$MODE" in
  once)
    ONCE=1
    printf '# fleet-memguard --once%s — %s · pressure %s · %s MB physical · spike ≥+%sMB/%ss · hard ≥%s%% · orphan >%sMB >%ss\n' \
      "$([ "$DRY" = 1 ] && echo ' --dry-run')" "$(date '+%Y-%m-%dT%H:%M:%S')" "$(fleet_mem_probe)" "$(fleet_mem_total_mb)" \
      "$GROW_MB" "$WINDOW" "$HARD_PCT" "$ORPHAN_MB" "$ORPHAN_SECS"
    printf '# rule\taction\tpid\trss\tgrew\tclass\targv\n'
    out="$(tick)"; [ -n "$out" ] && printf '%s\n' "$out" || printf '(no candidates)\n'
    ROWS="$(fleet_proc_mem_rows)"
    printf '# top fleet processes by RSS (pid rssMB age_s class argv)\n'
    printf '%s\n' "$ROWS" | awk -F'\t' '$5 != "other"' | head -5 \
      | awk -F'\t' '{ printf "%s\t%s\t%s\t%s\t%s\n", $1, $3, $4, $5, substr($6, 1, 100) }'
    if [ -f "$BIN/fleet-diskguard.sh" ]; then
      printf '# diskguard --orphans (CPU: pid %%cpu etime rssMB argv)\n'
      dg="$(bash "$BIN/fleet-diskguard.sh" --orphans 2>/dev/null)"
      [ -n "$dg" ] && printf '%s\n' "$dg" || printf '(none)\n'
    fi
    ;;
  daemon)
    self="$(cksum < "$0" 2>/dev/null)"; n=0
    while :; do
      if [ "${FLEET_MEMGUARD:-1}" != 0 ]; then tick; fi
      n=$((n + 1))
      # Liveness for bin/fleet-daemon-watch.sh, and a self re-exec when the install
      # sync rewrote this script (a KeepAlive loop would otherwise run the old copy
      # until the next reboot). Every ~10s / ~60s, not every sample.
      if [ $((n % 5)) = 0 ] && command -v fleet_daemon_stamp_tick >/dev/null 2>&1; then
        fleet_daemon_stamp_tick memguard "$BIN/.."
      fi
      # FLEET_MEM_MAX_TICKS: stop after N samples (the selftest drives the ring with it)
      [ -n "${FLEET_MEM_MAX_TICKS:-}" ] && [ "$n" -ge "$FLEET_MEM_MAX_TICKS" ] && exit 0
      # Under pressure, a machine-metrics row every ~10s beside diskguard's per-minute
      # one (issue #1294): the minutes before a freeze are the ones worth resolving.
      if [ $((n % METRICS_EVERY)) = 0 ] && [ "${FLEET_METRICS:-1}" != 0 ] && [ "$(pressure)" -ge 2 ]; then
        fleet_metrics_append memguard
      fi
      [ $((n % 30)) = 0 ] && clear_marks
      if [ $((n % 30)) = 0 ] && [ "$(cksum < "$0" 2>/dev/null)" != "$self" ]; then
        exec /bin/bash "$0" --daemon
      fi
      sleep "$INTERVAL"
    done
    ;;
  *) sed -n '2,66p' "$0"; exit 0 ;;
esac
exit 0
