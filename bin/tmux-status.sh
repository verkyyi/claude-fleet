#!/bin/bash
# tmux-status.sh — right side of the tmux status bar.
# Shows: [● container] │ CPU 23% │ MEM 1.2G/4G │ N claude │ hostname
# Color coding: CPU green <50%, yellow 50-80%, red >80%;
#               MEM green <60%, yellow 60-85%, red >85%.
# Optional: set FLEET_STATUS_CONTAINER in fleet.conf to show a docker
# container's ●/○ running indicator.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"

# Palette (Tokyo Night)
RED="#[fg=#f7768e]"
YELLOW="#[fg=#e0af68]"
GREEN="#[fg=#9ece6a]"
BLUE="#[fg=#7aa2f7]"
DIM="#[fg=#565f89]"

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
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: aggregate CPU from ps + core count
    cpu_sum=$(ps -A -o %cpu | awk '{s+=$1} END {printf "%.0f", s}')
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
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
if [[ "$(uname)" == "Darwin" ]]; then
    total=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
    # Pages: active + wired + compressed ≈ used
    active=$(vm_stat 2>/dev/null | awk '/Pages active/ {gsub(/\./,"",$3); print $3}')
    wired=$(vm_stat 2>/dev/null | awk '/Pages wired/ {gsub(/\./,"",$4); print $4}')
    compressed=$(vm_stat 2>/dev/null | awk '/Pages occupied by compressor/ {gsub(/\./,"",$5); print $5}')
    used_pages=$(( ${active:-0} + ${wired:-0} + ${compressed:-0} ))
    used=$(( used_pages * page_size / 1024 / 1024 ))
elif command -v free &>/dev/null; then
    read -r used total <<< "$(free -m | awk '/Mem:/ {print $3, $2}')"
fi

if [ -n "${used:-}" ] && [ -n "${total:-}" ] && [ "${total:-0}" -gt 0 ]; then
    mem_pct=$((used * 100 / total))
    mem_display=$(awk "BEGIN {printf \"%.1fG/%.1fG\", $used/1024, $total/1024}")
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

# --- Claude token consumption (5h/7d proxy, written by the dash collector) ---
INDIGO="#[fg=#bb9af7]"
usage=$(cat "${TMPDIR:-/tmp}/.claude-dash/usage" 2>/dev/null)
usage_seg=""
[ -n "$usage" ] && usage_seg="${DIM}│ ${INDIGO}${usage} "

# --- Official weekly/N-hour limit % (opportunistically scraped by the collector) ---
# The collector writes "$C/ratelimit" as "epoch<TAB>line" whenever a session prints
# "N% of your weekly limit". Surface that authoritative number next to the local
# proxy, but only while fresh — a stale weekly % is worse than none. Staleness
# window is FLEET_RATELIMIT_TTL seconds (default 6h).
ORANGE="#[fg=#ff9e64]"
rl_seg=""
rl_file="${TMPDIR:-/tmp}/.claude-dash/ratelimit"
if [ -f "$rl_file" ]; then
    rl_ts="" rl_line=""
    IFS=$'\t' read -r rl_ts rl_line < "$rl_file" 2>/dev/null
    case "$rl_ts" in
        ''|*[!0-9]*) : ;;   # missing / non-numeric epoch → skip
        *)  if [ -n "$rl_line" ] && \
               [ "$(( $(date +%s) - rl_ts ))" -lt "${FLEET_RATELIMIT_TTL:-21600}" ]; then
                rl_seg="${DIM}│ ${ORANGE}${rl_line} "
            fi;;
    esac
fi

# --- Output --- (claude count + hostname dropped — the window list and dash cover those;
# name your tmux session after your fleet so status-left carries the title)
printf " %s${BLUE}CPU %s ${DIM}│ ${BLUE}MEM %s %s%s" \
    "$container" "$cpu_out" "$mem_out" "$usage_seg" "$rl_seg"
