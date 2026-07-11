#!/bin/bash
# tmux-status.sh — right side of the tmux status bar.
# Shows: [● container] │ CPU 23% │ MEM 1.2G/4G │ DSK 34G │ N claude │ hostname
# Color coding: CPU green <50%, yellow 50-80%, red >80%;
#               MEM green <60%, yellow 60-85%, red >85%;
#               DSK green >1.5×floor, yellow ≤1.5×floor, red ≤FLEET_DISK_FLOOR_GB.
# Optional: set FLEET_STATUS_CONTAINER in fleet.conf to show a docker
# container's ●/○ running indicator.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/usage-lib.sh"

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

# --- Claude token consumption (5h/7d proxy, written by the dash collector) ---
# The official weekly/N-hour limit % (scraped into $C/ratelimit) is no longer a
# separate always-on footer segment — that text was noise on the status bar
# (issue #239). Instead it COLORS this one usage stat: indigo = ok, yellow =
# approaching the limit (≥FLEET_USAGE_WARN_PCT), red = at/near it
# (≥FLEET_USAGE_CRIT_PCT). The full story — which limit, reset time, which
# account — lives in the usage popup, opened on demand: click this stat
# (range=user|usage) or press prefix+u. Severity math + freshness gate are
# shared with the popup via usage-lib.sh so they can't drift.
INDIGO="#[fg=#bb9af7]"
usage=$(fleet_usage_proxy)
usage_seg=""
if [ -n "$usage" ]; then
    rl_pct="$(fleet_usage_ratelimit | cut -f1)"
    case "$(fleet_usage_severity "$rl_pct")" in
        crit) usage_col="$RED" ;;
        warn) usage_col="$YELLOW" ;;
        *)    usage_col="$INDIGO" ;;
    esac
    # Clickable range → the usage popup (a MouseDown1Status bind opens it; same
    # target as prefix+u). Emitted only when a stat exists, so no dead click.
    usage_seg="${DIM}│ #[range=user|usage]${usage_col}${usage} #[norange]"
fi

# --- Active subscription account (multi-account only; display-only read, no
# side effects — resolving via `fleet-account.sh active` could ROTATE, which a
# status repaint must never do, so read the cached pointer directly). ---
acct_dir="${FLEET_ACCOUNTS_DIR:-$HOME/.config/claude-fleet/accounts}"
acct_seg=""
if [ -d "$acct_dir" ] && [ -n "$(find "$acct_dir" -maxdepth 1 -type f ! -name '.*' ! -name '*~' ! -name '*.conf' 2>/dev/null)" ]; then
    act=$(sed -n '1p' "${TMPDIR:-/tmp}/.claude-dash/global/account.active" 2>/dev/null)   # global/ (issue #181)
    # Wrap the chip in a clickable range (acct) — a MouseDown1Status bind in
    # conf/tmux-attention.conf opens the account picker (same as prefix A). Only
    # emitted when a chip exists, so there's no dead click target when off.
    [ -n "$act" ] && acct_seg="${DIM}│ #[range=user|acct]${GREEN}◉ ${act} #[norange]"
fi

# --- Output --- (claude count + hostname dropped — the window list and dash cover those;
# name your tmux session after your fleet so status-left carries the title)
printf " %s${BLUE}CPU %s ${DIM}│ ${BLUE}MEM %s %s%s%s" \
    "$container" "$cpu_out" "$mem_out" "$dsk_seg" "$acct_seg" "$usage_seg"
