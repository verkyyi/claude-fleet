#!/bin/bash
# tmux-status.sh — right side of the tmux status bar.
# Shows: [● container] │ CPU 23% │ MEM 1.2G/4G │ DSK 34G │ <usage stat>
#        [│ ⚠ quota stale 47m | ⚠ quota blind 6m] [│ ⚠ quota via banner] [│ ⚠ dash stale 12m ↻2m | ↻ dash kicked 2m]
#        [│ ⚠ daemon stale cleanup,dispatch+2 ↻3m | ↻ daemon kicked 3m]
# Color coding: CPU green <50%, yellow 50-80%, red >80%;
#               MEM green <60%, yellow 60-85%, red >85%;
#               DSK green >1.5×floor, yellow ≤1.5×floor, red ≤FLEET_DISK_FLOOR_GB.
# Optional: set FLEET_STATUS_CONTAINER in fleet.conf to show a docker
# container's ●/○ running indicator.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/usage-lib.sh"
# The interval-daemon liveness registry + relative-interval thresholds (issue
# #639). Sourced HERE and not from usage-lib.sh so nothing has to guess a lib's
# own directory: it is also what makes fleet_collect_stale_secs relative rather
# than the absolute 600s that read `fresh` through a 7–14-minute collector.
. "$BIN/fleet-daemon-lib.sh"

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

# --- quota-watch staleness (issue #551): the ONE always-on alarm on the bar.
# The pre-emptive rotation's cache (account.quota.ts) is restamped by every
# fleet-quotawatch tick; with a pool + hub configured, a stamp older than
# FLEET_ACCOUNT_QUOTA_STALE means no tick has run for that long and the 70%/85%
# rotation is BLIND (2026-09-11: 2.5h blind ⇒ 21 sessions rode a window to 100%).
# Silent fail-open is exactly what cost that window, so this is red and never
# gated by freshness. Empty when fresh, or when the watch isn't configured.
# Its twin (issue #684): the cache can also be FRESH and EMPTY. The stamp says a
# tick RAN; it says nothing about whether the tick brought anything back, and the
# fetch restamps either way by design — so a hub answering with zero rows leaves
# this bar green while the rotation has nothing to act on (2026-09-15: at least
# six minutes of it, `--status` reading `fresh 117`). One alarm at a time: stale
# is the deeper failure (nothing is ticking at all) and fleet_quota_blind already
# stands down while it holds.
quota_seg=""
qstale=$(fleet_quota_stale_age)
if [ -n "$qstale" ]; then
    quota_seg="${DIM}│ ${RED}⚠ quota stale $(fleet_usage_human_secs "$qstale") "
else
    qblind=$(fleet_quota_blind)
    [ -n "$qblind" ] && quota_seg="${DIM}│ ${RED}⚠ quota blind $(fleet_usage_human_secs "${qblind#*	}") "
fi
# Its consequence (issue #874): with no fresh reading, a limit banner benched an
# account by itself — the path that false-benched healthy accounts twice — so it
# says so, beside (not instead of) the stale/blind alarm that usually explains it.
[ -n "$(fleet_quota_via_banner)" ] && quota_seg="${quota_seg}${DIM}│ ${RED}⚠ quota via banner "

# --- collector staleness + self-heal trace (issue #636): the SECOND always-on
# alarm. Every number the dash draws comes out of the collector's caches, so a
# collector that stops does not empty the dash — it freezes it, confidently, with
# no tell. On 2026-09-14 launchd pended com.claude-fleet.collect for 103 minutes
# (`pended nondemand spawn = interval`, last exit 0) and the dash showed a
# two-hour-old world; the only signal was one line in the hand-run fleet-doctor.
# So: red `⚠ dash stale 47m` off the collector's own heartbeat, and — since
# `launchctl kickstart -k` fixes it instantly — a rate-limited self-heal, whose
# `↻` trace stays on the bar for FLEET_COLLECT_KICK_TRACE AFTER recovery so the
# outage is never silently papered over. The kick is gated in-process first
# (two file reads) and only then forked, detached: this runs every 5s per client.
collect_seg=""
cstale=$(fleet_collect_stale_age)
ckick=$(fleet_collect_kick_age)
ktrace="${FLEET_COLLECT_KICK_TRACE:-1800}"
if [ -n "$cstale" ]; then
    collect_seg="${DIM}│ ${RED}⚠ dash stale $(fleet_usage_human_secs "$cstale")"
    if [ -n "$ckick" ] && [ "$ckick" -lt "$ktrace" ]; then
        collect_seg="${collect_seg} ↻$(fleet_usage_human_secs "$ckick")"
    fi
    collect_seg="${collect_seg} "
    if fleet_collect_kick_due; then
        ( bash "$BIN/fleet-collect-kick.sh" </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
elif [ -n "$ckick" ] && [ "$ckick" -lt "$ktrace" ]; then
    # Recovered, but recently self-healed — leave the trace up.
    collect_seg="${DIM}│ ${YELLOW}↻ dash kicked $(fleet_usage_human_secs "$ckick") "
fi

# --- every OTHER interval daemon (issue #639): the THIRD always-on alarm. The
# collector was only the unit we happened to have instrumented. When launchd stops
# scheduling this user domain it stops scheduling all of them at once — cleanup
# stops reaping workers, dispatch stops autofilling, base-sync stops
# fast-forwarding the base, issue-bridge stops relaying comments, ledger-watch
# stops indexing closed sessions — and every one of those failures is INVISIBLE:
# nothing empties, nothing errors, the fleet just quietly stops doing its
# housekeeping. So one compact red segment naming the units, on the same
# always-on terms as the two alarms above (never freshness-gated, never silent),
# with the same `↻` trace that outlives the recovery.
#
# `collect` is excluded because it has the segment above — a frozen dash is the
# symptom the operator already knows `⚠ dash stale` for, and printing it twice
# would only make the bar noisier at the moment it needs to be read. Names are
# capped at two plus a `+N` so a whole-domain outage (all ten units) stays one
# glance wide instead of wrapping the bar. The KICK is NOT driven from here: the
# spinner is KeepAlive, i.e. the one daemon that cannot itself be pended, and it
# runs the watch every 30s whether or not anybody is attached (bin/tmux-spinner.sh).
daemon_seg=""
dtrace="${FLEET_DAEMON_KICK_TRACE:-$ktrace}"
dnames=""; dn=0
for du in $(fleet_daemon_overdue_list "$BIN/.." collect); do
    dn=$((dn + 1))
    [ "$dn" -le 2 ] && dnames="${dnames:+$dnames,}$du"
done
dkick=$(fleet_daemon_recent_kick "$BIN/.." collect)
if [ "$dn" -gt 0 ]; then
    [ "$dn" -gt 2 ] && dnames="$dnames+$((dn - 2))"
    daemon_seg="${DIM}│ ${RED}⚠ daemon stale $dnames"
    if [ -n "$dkick" ] && [ "$dkick" -lt "$dtrace" ]; then
        daemon_seg="${daemon_seg} ↻$(fleet_usage_human_secs "$dkick")"
    fi
    daemon_seg="${daemon_seg} "
elif [ -n "$dkick" ] && [ "$dkick" -lt "$dtrace" ]; then
    daemon_seg="${DIM}│ ${YELLOW}↻ daemon kicked $(fleet_usage_human_secs "$dkick") "
fi

# --- No account chip. The green `◉ <account>` segment (issue #289) mirrored the
# fleet-wide global/account.active pointer, i.e. "the account new sessions use".
# Since #513 that pointer is RE-PICKED on every spawn from ccquota headroom, so
# there is no fixed or default account to show — the chip was a stale snapshot
# of a moving target. The truth is per window (@cc_account, shown by the dash and
# `fleet-account.sh whoami`); the usage + account modal it opened stays one tap
# away on the usage stat below. ---

# --- Output --- (claude count + hostname dropped — the window list and dash cover those;
# name your tmux session after your fleet so status-left carries the title)
printf " %s${BLUE}CPU %s ${DIM}│ ${BLUE}MEM %s %s%s%s%s%s" \
    "$container" "$cpu_out" "$mem_out" "$dsk_seg" "$usage_seg" "$quota_seg" "$collect_seg" "$daemon_seg"
