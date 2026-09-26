#!/bin/bash
# tmux-status.sh — right side of the tmux status bar.
# Shows: [● container] │ CPU 23% │ MEM 1.2G/4G │ DSK 34G │ ✖ 1  ▲ 2
#        — the alert COUNTS, fixed width (issue #1238); the alerts themselves
#        are in the `prefix !` popup (bin/fleet-alerts.sh).
# Color coding: CPU green <50%, yellow 50-80%, red >80%;
#               MEM green <60%, yellow 60-85%, red >85%;
#               DSK green >1.5×floor, yellow ≤1.5×floor, red ≤FLEET_DISK_FLOOR_GB.
# Optional: set FLEET_STATUS_CONTAINER in fleet.conf to show a docker
# container's ●/○ running indicator.
set -uo pipefail

case "$0" in */*) BIN="${0%/*}" ;; *) BIN=. ;; esac   # forkless dirname (issue #888)
BIN="$(cd "${BIN:-/}" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
_fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings"; [ -f "$_fs" ] && . "$_fs"   # the login's settings win (#979)
. "$BIN/usage-lib.sh"
# The interval-daemon liveness registry + relative-interval thresholds (issue
# #639). Sourced HERE and not from usage-lib.sh so nothing has to guess a lib's
# own directory: it is also what makes fleet_collect_stale_secs relative rather
# than the absolute 600s that read `fresh` through a 7–14-minute collector.
. "$BIN/fleet-daemon-lib.sh"
# One clock per render (issue #888): every stale/kick age below is read against
# this, instead of each one forking its own `date` (26 per render before). This
# script is one-shot — tmux runs it anew every status-interval — so a pinned clock
# is never older than the render itself.
fleet_now_pin

# The OS from $OSTYPE, not two `uname` forks per render (issue #888).
case "${OSTYPE:-}" in darwin*) IS_DARWIN=1 ;; *) IS_DARWIN=0 ;; esac

# Palette (Tokyo Night)
RED="#[fg=#f7768e]"
YELLOW="#[fg=#e0af68]"
GREEN="#[fg=#9ece6a]"
BLUE="#[fg=#7aa2f7]"
DIM="#[fg=#565f89]"

# mb_to_g1 <MB> — MB as GB with one decimal, byte-identical to awk's
# printf "%.1f" of MB/1024 (issue #888: was one awk fork per render). MB/1024 is
# exact in binary, so the only rounding is %.1f's own: nearest, ties to even.
mb_to_g1() {
    local t=$(( $1 * 10 )) q r
    q=$(( t / 1024 )); r=$(( t % 1024 ))
    if [ "$r" -gt 512 ] || { [ "$r" -eq 512 ] && [ $(( q % 2 )) -eq 1 ]; }; then q=$(( q + 1 )); fi
    printf '%d.%d' $(( q / 10 )) $(( q % 10 ))
}

# --- Machine stats: container ● / CPU / MEM / DSK (issue #890). These are the
# only segments that exec anything per render (ps, vm_stat, df, sysctl, docker),
# and tmux runs this script every status-interval PER ATTACHED CLIENT — so two
# terminals meant two of everything, every 5s, for the same machine-wide numbers.
# status_machine_compute measures them once; status_machine_cached shares the
# result through ${TMPDIR}/fleet-status.cache (see below), so N clients cost one
# measurement per FLEET_STATUS_CACHE_SECS. Sets $machine; no subshell.
status_machine_compute() {
    # --- Optional container status ---
    container=""
    if [ -n "${FLEET_STATUS_CONTAINER:-}" ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${FLEET_STATUS_CONTAINER}$"; then
            container="${GREEN}● ${DIM}│ "
        else
            container="${RED}○ ${DIM}│ "
        fi
    fi

    # --- CPU usage ---
    if [ "$IS_DARWIN" = 1 ]; then
        # hw.ncpu / hw.memsize / hw.pagesize in ONE sysctl (was three forks).
        sysv=$(sysctl -n hw.ncpu hw.memsize hw.pagesize 2>/dev/null)
        read -r ncpu memsize page_size <<< "${sysv//$'\n'/ }"
        case "${ncpu:-}" in ''|*[!0-9]*|0) ncpu=1 ;; esac
        case "${memsize:-}" in ''|*[!0-9]*) memsize=0 ;; esac
        case "${page_size:-}" in ''|*[!0-9]*|0) page_size=16384 ;; esac
        # macOS: aggregate CPU from ps + core count
        cpu_sum=$(ps -A -o %cpu | awk '{s+=$1} END {printf "%.0f", s}')
        cpu=$((cpu_sum / ncpu))
    else
        # Linux: from /proc/stat, cumulative since boot
        cpu=$(awk '/^cpu / {idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; printf "%.0f", 100-idle*100/total}' /proc/stat 2>/dev/null)
    fi

    if [ -n "$cpu" ]; then
        if [ "$cpu" -ge 80 ]; then
            cpu_out="${RED}${cpu}%"
        elif [ "$cpu" -ge 50 ]; then
            cpu_out="${YELLOW}${cpu}%"
        else
            cpu_out="${GREEN}${cpu}%"
        fi
    else
        cpu_out="${DIM}–"
    fi

    # --- Memory ---
    used="" total=""
    if [ "$IS_DARWIN" = 1 ]; then
        total=$(( memsize / 1024 / 1024 ))
        # Pages: active + wired + compressed ≈ used — one vm_stat, one awk (was 3 + 3)
        used_pages=$(vm_stat 2>/dev/null | awk '
          /Pages active/                 {gsub(/\./,"",$3); u+=$3}
          /Pages wired/                  {gsub(/\./,"",$4); u+=$4}
          /Pages occupied by compressor/ {gsub(/\./,"",$5); u+=$5}
          END {printf "%d", u}')
        case "${used_pages:-}" in ''|*[!0-9]*) used_pages=0 ;; esac
        used=$(( used_pages * page_size / 1024 / 1024 ))
    elif command -v free &>/dev/null; then
        read -r used total <<< "$(free -m | awk '/Mem:/ {print $3, $2}')"
    fi

    if [ -n "${used:-}" ] && [ -n "${total:-}" ] && [ "${total:-0}" -gt 0 ]; then
        mem_pct=$((used * 100 / total))
        mem_display="$(mb_to_g1 "$used")G/$(mb_to_g1 "$total")G"
        if [ "$mem_pct" -ge 85 ]; then
            mem_out="${RED}${mem_display}"
        elif [ "$mem_pct" -ge 60 ]; then
            mem_out="${YELLOW}${mem_display}"
        else
            mem_out="${GREEN}${mem_display}"
        fi
    else
        mem_out="${DIM}–"
    fi

    # --- Disk free (passive at-a-glance gauge; the diskguard daemon still owns the
    # reactive gate/notify/forensics). Measure the SAME volume diskguard guards
    # ($FLEET_DISK_TARGET, via the same portable `df -Pk` → int GB approach) so the
    # footer number and the spawn gate agree, and tie the colors to the SAME floor
    # knob (don't invent a new threshold). Display-only, no side effects — df is
    # cheap + local, never a diskguard mutation path. Suppress with
    # FLEET_STATUS_DISK=0 (default on). ---
    dsk_seg=""
    if [ "${FLEET_STATUS_DISK:-1}" != "0" ]; then
        disk_target="${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}"
        disk_floor="${FLEET_DISK_FLOOR_GB:-12}"
        dsk_free=$(df -Pk "$disk_target" 2>/dev/null | awk 'NR==2 { printf "%d", int($4/1048576) }')
        if [ -n "$dsk_free" ]; then
            if [ "$dsk_free" -le "$disk_floor" ]; then
                dsk_out="${RED}${dsk_free}G"
            elif [ "$dsk_free" -le "$(( disk_floor * 3 / 2 ))" ]; then
                dsk_out="${YELLOW}${dsk_free}G"
            else
                dsk_out="${GREEN}${dsk_free}G"
            fi
        else
            dsk_out="${DIM}–"
        fi
        dsk_seg="${DIM}│ ${BLUE}DSK ${dsk_out} "
    fi
    printf -v machine " %s${BLUE}CPU %s ${DIM}│ ${BLUE}MEM %s %s" "$container" "$cpu_out" "$mem_out" "$dsk_seg"
}

# status_machine_cached — sets $machine, measured at most once per
# FLEET_STATUS_CACHE_SECS (default 5 = status-interval) across every client on the
# machine (issue #890). The cache is two lines, `<epoch>\t<key>` then the rendered
# segment; the key is every knob the segment depends on, so a sandbox or a second
# install with another disk target / container never shows the other's numbers.
#   fresh            → printed as is: zero forks.
#   expired          → the first caller to `mkdir` the lock re-measures and
#                      publishes atomically (tmp + mv); the rest print the previous
#                      value — one render late, never blank, never doubled.
#   none / ancient   → (cold start, or no client for 6 intervals) wait for a holder
#   (≥ 6 intervals)    up to 3s; a lock still held after that is a dead holder's —
#                      break it and measure here.
# FLEET_STATUS_CACHE_SECS=0 turns sharing off.
status_machine_cached() {
    local ttl="${FLEET_STATUS_CACHE_SECS:-5}" d="${TMPDIR:-/tmp}" cache lock key
    local ts="" k="" val="" age=-1 tries=0 now="$_FLEET_NOW"
    case "$ttl" in ''|*[!0-9]*) ttl=5 ;; esac
    if [ "$ttl" -eq 0 ]; then status_machine_compute; return; fi
    cache="${FLEET_STATUS_CACHE:-${d%/}/fleet-status.cache}"; lock="$cache.lock"
    key="${FLEET_STATUS_CONTAINER:-}|${FLEET_STATUS_DISK:-1}|${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}|${FLEET_DISK_FLOOR_GB:-12}"
    _smc_read() {   # → ts/val + age; age=-1 when there is no usable entry
        ts="" k="" val="" age=-1
        { IFS=$'\t' read -r ts k; IFS= read -r val; } 2>/dev/null < "$cache"
        case "$ts" in ''|*[!0-9]*) return 0 ;; esac
        [ "$k" = "$key" ] && [ -n "$val" ] || return 0
        if [ "$now" -ge "$ts" ]; then age=$(( now - ts ))
        elif [ $(( ts - now )) -le "$ttl" ]; then age=0   # a holder that pinned its clock after ours
        fi
        return 0
    }
    _smc_read
    if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then machine=$val; return; fi
    if mkdir "$lock" 2>/dev/null; then
        status_machine_compute
        printf '%s\t%s\n%s\n' "$now" "$key" "$machine" > "$cache.$$" 2>/dev/null \
            && mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$"
        rmdir "$lock" 2>/dev/null
        return
    fi
    if [ "$age" -ge 0 ] && [ "$age" -lt $(( ttl * 6 )) ]; then machine=$val; return; fi
    while [ -d "$lock" ] && [ "$tries" -lt 30 ]; do
        sleep 0.1; tries=$((tries + 1))
    done
    _smc_read
    if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then machine=$val; return; fi
    [ -d "$lock" ] && rmdir "$lock" 2>/dev/null
    status_machine_compute
}
machine=""
status_machine_cached

# --- Alerts: COUNTS only (issue #1238). The bar used to spell every alarm out as
# a sentence (the weekly pace gap, `⚠ daemon stale cleanup,dispatch+2 ↻3m`,
# `⚠ dash stale 12m ↻2m` …) — its width moved with the bad news, so a phone cut
# it off exactly when there was something to read. Now the ONE producer,
# bin/fleet-alerts.sh, writes $G/alerts.ndjson (quota stale / unreadable / from
# banner / uneven, dash + daemon stale with their ↻ self-heal traces, disk low,
# accounts all capped, model capped, needs), and the bar draws a FIXED-width
# `✖ N ▲ N` off it; `prefix !` (or a click on a count) opens the table.
#
# The refresh rides here, TTL-gated (FLEET_ALERTS_TTL, one writer across every
# attached client): the collector's own stale alarm cannot come from the
# collector, and `--kick` keeps the rate-limited collector self-heal (#636/#638)
# on this render path, where it always lived. Every other reader only reads.
. "$BIN/fleet-alerts.sh"
fleet_alerts_refresh --kick
fleet_alerts_bar

# --- No account chip. The green `◉ <account>` segment (issue #289) mirrored the
# fleet-wide global/account.active pointer, i.e. "the account new sessions use".
# Since #513 that pointer is RE-PICKED on every spawn from ccquota headroom, so
# there is no fixed or default account to show — the chip was a stale snapshot
# of a moving target. The truth is per window (@cc_account, shown by the dash and
# `fleet-account.sh whoami`); the usage + account modal it opened stays one key
# away on `prefix u`. ---

# --- Output --- (claude count + hostname dropped — the window list and dash cover those;
# name your tmux session after your fleet so status-left carries the title)
printf '%s%s' "$machine" "$FA_BAR"
