#!/bin/bash
# tmux-status.sh — right side of the tmux status bar.
# Shows: [● container] │ CPU 23% │ MEM 1.2G/4G │ DSK 34G
#        [│ ⚠ quota stale 47m | ⚠ quota blind 6m] [│ ⚠ quota via banner] [│ ⚠ dash stale 12m ↻2m | ↻ dash kicked 2m]
#        [│ ⚠ daemon stale cleanup,dispatch+2 ↻3m | ↻ daemon kicked 3m]
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

# --- No usage stat (issue #1100). The `5h … · 7d …` token-proxy figure used to
# sit here, colored by the scraped limit % — but the signal was the color, the
# digits were noise on a bar read dozens of times a day, and the limit ALARMS
# below (quota stale / blind / banner-only) are what actually carry the bad news.
# The usage + account modal it opened on click moved to `prefix u`
# (conf/tmux-attention.conf); usage-lib.sh stays, the modal still reads it. ---

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
# The weekly PACE spread (issue #1231): the pool's most-ahead and most-behind
# accounts more than FLEET_ACCOUNT_PACE_SPREAD_WARN (30) points apart — one
# week is being drained while another sits unused; `fleet-account.sh list`
# names them. Yellow, not red: the watch's rebalance is already working on it,
# and nothing is blind. Read off $G/quota.pace, which the watch writes per tick.
qspread=$(fleet_quota_pace_spread)
[ -n "$qspread" ] && quota_seg="${quota_seg}${DIM}│ ${YELLOW}⚠ quota pace spread ${qspread%%	*} "

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
# `fleet-account.sh whoami`); the usage + account modal it opened stays one key
# away on `prefix u`. ---

# --- Output --- (claude count + hostname dropped — the window list and dash cover those;
# name your tmux session after your fleet so status-left carries the title)
printf '%s%s%s%s' "$machine" "$quota_seg" "$collect_seg" "$daemon_seg"
