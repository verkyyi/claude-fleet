#!/bin/bash
# tmux-status.sh — right side of the tmux status bar.
# ONE layout in both modes (issue #1534, EPIC #1529 E5 — its 改后 mockup is the
# contract; conf/tmux-bar.conf draws the left side):
#   local  本机 · 负载 0.3 · 内存 49% · 盘 61% │ icloud 5h 1% · 周 74% │ ✖ 1  ▲ 2
#   hub    m5 ● · 负载 0.3 · 内存 49% │ icloud 5h 1% · 周 74% │ ● 入口 │ ✖ 1  ▲ 2
# `·` joins the fields of a chip, `│` separates chips; the counts at the end are
# the alerts (fixed width, issue #1238) — the alerts themselves are in the
# `prefix !` popup (bin/fleet-alerts.sh). Narrower than 120 columns 内存 goes
# first, narrower than 100 负载 too (`cw=`, the client's width).
# 负载 = the 1-minute load per core (green < 0.5, yellow < 0.8, red);
# 内存 = used % (green < 60, yellow < 85, red); 盘 = the guarded volume's use %,
#        coloured by its FREE GB against FLEET_DISK_FLOOR_GB (red ≤ floor,
#        yellow ≤ 1.5×floor) — the spawn gate's own knob.
# The account chip is the CURRENT window's @cc_account with its 5h / 周 quota
# (hub_limits in hub mode, else the window's own @rl5h/@rl7d); none → no chip.
# Every colour comes from conf/fleet-palette.conf (bin/fleet-palette.sh).
# Optional: set FLEET_STATUS_CONTAINER in fleet.conf to show a docker
# container's ●/○ running indicator ahead of 本机.
#
# HUB MODE (issue #1482, EPIC #1479 C3) — three chips about THE SESSION YOU ARE
# LOOKING AT, not this machine:  m4 ● · 负载 0.2 · 内存 25% │ icloud 5h 63% · 周 65% │ ● 入口
#   1. the machine the current window's session is on — this one for a local
#      window (its live 负载/内存, as above), the OTHER machine for a proxy
#      window (`@remote`, fleet-remote-view.sh): `● ` + its load and memory off
#      the hub's cache, `○ 失联 3m` when the hub calls it lost — or when the hub
#      itself is silent (#1483): nothing here can hear that machine, so its word
#      is as old as the silence — `?` when the cache has no row for it. `· 旧`
#      at the chip's end (issue #644, EPIC #1524 R4) when that machine's live
#      install is behind the stable mark: the refresh loop judges each node's
#      reported version against this login's local refs/tags/stable and writes
#      `old:<n>` into its hub_nodes row; this machine's own row says it too, so
#      the one that was never looked at is the one that shows it. At stable,
#      ahead, unknown or no version → nothing (unknown is never drawn current);
#   2. the account the window runs on (`@cc_account`) with its 5h / week quota
#      off the hub's limits cache, else the window's own reading — omitted when
#      neither knows it;
#   3. the hub itself: `● 入口` while global/hub_ok — fleet-hub-sessions.sh's stamp of
#      the last round that stood (issue #1483, EPIC #1479 C4) — is fresh, `○ 失联
#      Nm` once it is older than FLEET_HUB_SESSIONS_STALE (60s): the ONE rule,
#      fleet_status_hub_lost, that the sidebar's lost groups and the remote-row
#      actions read too. A local window's chip keeps its live readings whatever
#      the hub does: 本机照常.
#   The window list goes blank in hub mode and comes back when it leaves
#   (fleet_status_window_list). The cue is the `k=v` args the conf's status-right
#   passes from the CLIENT'S CURRENT WINDOW (`sess= win= remote= acct= wsf= wscf=
#   wsaved=`, and since #1534 `cw= rl5= rl7=`): tmux re-runs the job the moment the expanded command changes, so
#   switching from a local window to an m4 proxy swaps the chip at once, not a
#   status-interval later. Hub mode = CCQUOTA_FLEET=1 + the fleet's
#   FLEET_SIDEBAR_SOURCE=hub + a remote_<sess> cache on disk (the sidebar's own
#   gate, #1480); otherwise — and with no args at all, the pre-#1482 conf — the
#   bar is the local layout above. Data: bin/fleet-status-lib.sh reads the two
#   summaries fleet-hub-sessions.sh --loop writes (hub_nodes / hub_limits); the
#   render path never touches the network (EPIC #1479 rule 2).
set -uo pipefail

case "$0" in */*) BIN="${0%/*}" ;; *) BIN=. ;; esac   # forkless dirname (issue #888)
BIN="$(cd "${BIN:-/}" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
_fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.settings"; [ -f "$_fs" ] && . "$_fs"   # the login's settings win (#979)
. "$BIN/usage-lib.sh"
. "$BIN/fleet-status-lib.sh"

# The current window, as the conf's status-right passes it (issue #1482). Absent
# (an older conf) → every value empty → never hub mode.
STATUS_SESS='' STATUS_REMOTE='' STATUS_ACCT='' STATUS_WSF='' STATUS_WSCF='' STATUS_WSAVED=''
STATUS_CW='' STATUS_RL5='' STATUS_RL7=''
for _a in "$@"; do
    case "$_a" in
        sess=*)   STATUS_SESS=${_a#sess=} ;;
        win=*)    ;;   # the window id is only the re-run cue (tmux re-runs #() when the expanded command changes)
        remote=*) STATUS_REMOTE=${_a#remote=} ;;
        acct=*)   STATUS_ACCT=${_a#acct=} ;;
        wsf=*)    STATUS_WSF=${_a#wsf=} ;;
        wscf=*)   STATUS_WSCF=${_a#wscf=} ;;
        wsaved=*) STATUS_WSAVED=${_a#wsaved=} ;;
        cw=*)     STATUS_CW=${_a#cw=} ;;
        rl5=*)    STATUS_RL5=${_a#rl5=} ;;
        rl7=*)    STATUS_RL7=${_a#rl7=} ;;
    esac
done

# status_conf_key <file> <KEY> → $_sck: the key's last assignment in a conf file
# (bare or `export`, quotes stripped), '' when absent. A builtin `read` loop, not
# fleet_load_conf: the bar does not source fleet-lib.sh (#888), and it wants ONE
# per-fleet key, not the fleet's whole overlay on top of fleet.conf's knobs.
status_conf_key() {
    local line; _sck=''
    [ -f "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$2="*|"export $2="*)
                line=${line#*=}; line=${line%%#*}; line=${line%"${line##*[![:space:]]}"}
                line=${line#\"}; line=${line%\"}; line=${line#\'}; line=${line%\'}
                _sck=$line ;;
        esac
    done < "$1"
}

# Hub mode (issue #1482): CCQUOTA_FLEET=1, the current session's fleet set to
# FLEET_SIDEBAR_SOURCE=hub (its own conf wins over fleet.conf / fleet.settings),
# and the sidebar's remote_<sess> cache on disk — no cache, no hub mode: the bar
# renders exactly as before until the loop's first answer (as the sidebar does).
HUB_MODE=0
if [ "${CCQUOTA_FLEET:-0}" = 1 ] && [ -n "$STATUS_SESS" ]; then
    _src="${FLEET_SIDEBAR_SOURCE:-local}"
    _cd="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
    if [ -f "$_cd/fleets/$STATUS_SESS/conf" ]; then status_conf_key "$_cd/fleets/$STATUS_SESS/conf" FLEET_SIDEBAR_SOURCE
    else status_conf_key "$_cd/$STATUS_SESS.conf" FLEET_SIDEBAR_SOURCE; fi
    [ -n "$_sck" ] && _src=$_sck
    [ "$_src" = hub ] && fleet_status_remote_head "$STATUS_SESS" && HUB_MODE=1
fi
# The window list: blank while in hub mode, restored on the way out (#1482). Both
# are transitions — a tmux call only when the passed-in formats say so.
if [ "$HUB_MODE" = 1 ]; then
    [ -n "$STATUS_WSF$STATUS_WSCF" ] && fleet_status_window_list on
elif [ -n "$STATUS_WSAVED" ]; then
    fleet_status_window_list off
fi
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

# Palette: conf/fleet-palette.conf, the fleet's ONE colour table (issue #1534) —
# never a hex here. No palette file → no colour at all, never a colour of our own.
. "$BIN/fleet-palette.sh"
if fleet_palette_load "$BIN/../conf/fleet-palette.conf"; then
    RED="#[fg=$PAL_RED]" YELLOW="#[fg=$PAL_YELLOW]" GREEN="#[fg=$PAL_GREEN]"
    BLUE="#[fg=$PAL_BLUE]" DIM="#[fg=$PAL_DIM]"
else
    RED='' YELLOW='' GREEN='' BLUE='' DIM=''
fi
US=$'\x1f'

# status_pct_color <pct> <yellow-at> <red-at> → $_spc: the palette colour for a
# percentage; DIM for anything that is not one.
status_pct_color() {
    case "${1:-}" in ''|*[!0-9]*) _spc=$DIM; return 0 ;; esac
    if   [ "$1" -ge "$3" ]; then _spc=$RED
    elif [ "$1" -ge "$2" ]; then _spc=$YELLOW
    else _spc=$GREEN; fi
}

# status_load <load1> <ncpu> → $_sl: 负载 — the 1-minute load PER CORE with one
# decimal (`1.57` on 10 cores → `0.2`), through the bands the CPU % had (≥ 0.5
# yellow, ≥ 0.8 red); DIM `–` when either reading is unusable. The same number for
# this machine (sysctl / /proc/loadavg) and another one (the hub's load1 + ncpu),
# so 「负载 0.3」 means one thing on every bar. Integer math on hundredths, no awk.
status_load() {
    local lp lf pc t
    lp=${1%%.*}; lf=${1#*.}; [ "$lf" = "$1" ] && lf=0
    lf="${lf}00"; lf=${lf:0:2}
    case "$lp" in ''|*[!0-9]*) _sl="${DIM}–"; return 0 ;; esac
    case "$lf" in *[!0-9]*) lf=00 ;; esac
    case "${2:-}" in ''|*[!0-9]*|0) _sl="${DIM}–"; return 0 ;; esac
    pc=$(( (10#$lp * 100 + 10#$lf) / $2 )); t=$(( (pc + 5) / 10 ))
    status_pct_color "$pc" 50 80
    _sl="${_spc}$(( t / 10 )).$(( t % 10 ))"
}

# --- Machine stats: container ● / 负载 / 内存 / 盘 (issue #890, #1534). These
# are the only readings that exec anything per render (sysctl, vm_stat, df, docker
# — /proc on Linux), and tmux runs this script every status-interval PER ATTACHED
# CLIENT — so two terminals meant two of everything for the same machine-wide
# numbers. status_machine_compute measures them once; status_machine_cached shares
# the result through ${TMPDIR}/fleet-status.cache (see below), so N clients cost
# one measurement per FLEET_STATUS_CACHE_SECS. Sets the four coloured values
# m_ctr m_load m_mem m_dsk ('' = not shown); no subshell. They stay four values,
# not one string, because which of them a client draws depends on ITS width.
status_machine_compute() {
    local sysv rest ncpu='' memsize=0 page_size=16384 load1='' used='' total='' used_pages
    local mem_pct disk_target disk_floor dsk_free='' dsk_pct=''
    m_ctr='' m_load='' m_mem='' m_dsk=''
    # --- Optional container status ---
    if [ -n "${FLEET_STATUS_CONTAINER:-}" ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${FLEET_STATUS_CONTAINER}$"; then
            m_ctr="${GREEN}●"
        else
            m_ctr="${RED}○"
        fi
    fi

    # --- 负载 + 内存 ---
    if [ "$IS_DARWIN" = 1 ]; then
        # hw.ncpu / hw.memsize / hw.pagesize / vm.loadavg in ONE sysctl; the last
        # prints `{ 1.57 1.60 1.70 }`.
        sysv=$(sysctl -n hw.ncpu hw.memsize hw.pagesize vm.loadavg 2>/dev/null)
        read -r ncpu memsize page_size rest <<< "${sysv//$'\n'/ }"
        rest=${rest#\{ }; load1=${rest%% *}
        case "${memsize:-}" in ''|*[!0-9]*) memsize=0 ;; esac
        case "${page_size:-}" in ''|*[!0-9]*|0) page_size=16384 ;; esac
        total=$(( memsize / 1024 / 1024 ))
        # Pages: active + wired + compressed ≈ used — one vm_stat, one awk
        used_pages=$(vm_stat 2>/dev/null | awk '
          /Pages active/                 {gsub(/\./,"",$3); u+=$3}
          /Pages wired/                  {gsub(/\./,"",$4); u+=$4}
          /Pages occupied by compressor/ {gsub(/\./,"",$5); u+=$5}
          END {printf "%d", u}')
        case "${used_pages:-}" in ''|*[!0-9]*) used_pages=0 ;; esac
        used=$(( used_pages * page_size / 1024 / 1024 ))
    else
        read -r load1 rest < /proc/loadavg 2>/dev/null
        ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
        command -v free &>/dev/null && read -r used total <<< "$(free -m | awk '/Mem:/ {print $3, $2}')"
    fi
    status_load "$load1" "$ncpu"; m_load=$_sl
    if [ -n "${used:-}" ] && [ -n "${total:-}" ] && [ "${total:-0}" -gt 0 ] 2>/dev/null; then
        mem_pct=$(( used * 100 / total ))
        status_pct_color "$mem_pct" 60 85; m_mem="${_spc}${mem_pct}%"
    else
        m_mem="${DIM}–"
    fi

    # --- 盘 (passive at-a-glance gauge; the diskguard daemon still owns the
    # reactive gate/notify/forensics). Measure the SAME volume diskguard guards
    # ($FLEET_DISK_TARGET, via the same portable `df -Pk`) and colour it by the SAME
    # floor knob, in free GB (don't invent a new threshold); the number drawn is the
    # volume's use %, the unit 内存 has. Display-only — df is cheap + local, never a
    # diskguard mutation path. Suppress with FLEET_STATUS_DISK=0 (default on). ---
    if [ "${FLEET_STATUS_DISK:-1}" != "0" ]; then
        disk_target="${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}"
        disk_floor="${FLEET_DISK_FLOOR_GB:-12}"
        read -r dsk_free dsk_pct <<< "$(df -Pk "$disk_target" 2>/dev/null | awk 'NR==2 { printf "%d %s", int($4/1048576), $5 }')"
        case "$dsk_free" in
            ''|*[!0-9]*) m_dsk="${DIM}–" ;;
            *) if [ "$dsk_free" -le "$disk_floor" ]; then m_dsk=$RED
               elif [ "$dsk_free" -le "$(( disk_floor * 3 / 2 ))" ]; then m_dsk=$YELLOW
               else m_dsk=$GREEN; fi
               m_dsk="${m_dsk}${dsk_pct:-–}" ;;
        esac
    fi
}

# status_machine_cached — sets m_ctr m_load m_mem m_dsk, measured at most once per
# FLEET_STATUS_CACHE_SECS (default 5) across every client on the machine (issue
# #890). The cache is two lines, `<epoch>\t<key>` then the four values joined by
# US; the key is every knob the values depend on (plus the layout version), so a
# sandbox, a second install with another disk target / container, or a cache an
# older bar wrote never shows here.
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
    key="v2|${FLEET_STATUS_CONTAINER:-}|${FLEET_STATUS_DISK:-1}|${FLEET_DISK_TARGET:-${TMPDIR:-/tmp}}|${FLEET_DISK_FLOOR_GB:-12}"
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
    _smc_use() { IFS=$US read -r m_ctr m_load m_mem m_dsk <<< "$val"; }
    _smc_read
    if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then _smc_use; return; fi
    if mkdir "$lock" 2>/dev/null; then
        status_machine_compute
        printf '%s\t%s\n%s\n' "$now" "$key" "${m_ctr}${US}${m_load}${US}${m_mem}${US}${m_dsk}" > "$cache.$$" 2>/dev/null \
            && mv -f "$cache.$$" "$cache" 2>/dev/null || rm -f "$cache.$$"
        rmdir "$lock" 2>/dev/null
        return
    fi
    if [ "$age" -ge 0 ] && [ "$age" -lt $(( ttl * 6 )) ]; then _smc_use; return; fi
    while [ -d "$lock" ] && [ "$tries" -lt 30 ]; do
        sleep 0.1; tries=$((tries + 1))
    done
    _smc_read
    if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then _smc_use; return; fi
    [ -d "$lock" ] && rmdir "$lock" 2>/dev/null
    status_machine_compute
}

# status_fields <负载> <内存> <盘> → $_sf: the machine chip's fields, each
# `· <label> <value> ` ('' = not shown). Narrower than 120 columns (the client's
# width, `cw=`) 内存 goes first, narrower than 100 负载 too (issue #1534); no
# width (an older conf) = room for all of them. 盘 stays: it is the floor the
# spawn gate keys on.
status_fields() {
    local w="${STATUS_CW:-}"
    case "$w" in ''|*[!0-9]*) w=999 ;; esac
    _sf=''
    [ -n "$1" ] && [ "$w" -ge 100 ] && _sf="${_sf}${DIM}· 负载 $1 "
    [ -n "$2" ] && [ "$w" -ge 120 ] && _sf="${_sf}${DIM}· 内存 $2 "
    [ -n "$3" ] && _sf="${_sf}${DIM}· 盘 $3 "
    return 0
}

# status_account <label> <5h> <周> → $_sa: `│ <label> 5h N% · 周 N% `, the
# numbers through the account knobs' bands; `–` for a missing one.
status_account() {
    local c5 cw
    status_pct_color "$2" "${FLEET_ACCOUNT_WARN_PCT:-70}" "${FLEET_ACCOUNT_CEILING:-85}"; c5=$_spc
    status_pct_color "$3" "${FLEET_ACCOUNT_WARN_PCT:-70}" "${FLEET_ACCOUNT_CEILING:-85}"; cw=$_spc
    _sa="${DIM}│ ${BLUE}$1 ${DIM}5h ${c5}${2:-–}% ${DIM}· 周 ${cw}${3:-–}% "
}

# status_window_account → rc 0 + $_sa when the current window names its account
# and carries a reading of its own (`rl5=`/`rl7=`, the window's @rl5h/@rl7d that
# conf/statusline.sh stamps) — the account chip off the hub (issue #1534).
status_window_account() {
    local a="${STATUS_RL5:-}" b="${STATUS_RL7:-}"
    case "$a" in *[!0-9]*) a='' ;; esac
    case "$b" in *[!0-9]*) b='' ;; esac
    [ -n "$STATUS_ACCT" ] && [ -n "$a$b" ] || return 1
    status_account "$STATUS_ACCT" "$a" "$b"
}

m_ctr='' m_load='' m_mem='' m_dsk=''
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

# --- GitHub rate limit (issue #989, EPIC #1262 C2): `⚠ GitHub 受限至 HH:MM` while
# the shared gh-limit marker (bin/fleet-gh-lib.sh, written by whichever caller saw
# the refusal) says a bucket is limited — so "every gh call is failing" reads as
# the account's shared limit at a glance, not as N unrelated breakages. READ only,
# never a probe; absent (zero width, zero forks) when nothing is limited. An
# injected limit (FLEET_GH_FAKE_LIMIT) has no reset time, so it shows bare.
gh_seg=""
_FLEET_GH_LIB_DIR="$BIN"
if [ -f "$BIN/fleet-gh-lib.sh" ] && . "$BIN/fleet-gh-lib.sh" && gh_until=$(fleet_gh_limit_until 2>/dev/null); then
    case "$gh_until" in
        ''|*[!0-9]*) gh_seg="${DIM}│ ${YELLOW}⚠ GitHub 受限 " ;;
        *)           gh_seg="${DIM}│ ${YELLOW}⚠ GitHub 受限至 $(fleet_gh_hhmm "$gh_until") " ;;
    esac
fi

# --- The account chip is PER WINDOW (issue #1534). The old green `◉ <account>`
# segment (issue #289) mirrored the fleet-wide global/account.active pointer —
# since #513 re-picked on every spawn, so it was a stale snapshot of a moving
# target and went away. What the bar shows now is the CURRENT WINDOW's account
# (@cc_account) and its quota: off the hub's limits cache in hub mode, else the
# window's own last reading (@rl5h/@rl7d); no account or no reading → no chip.
# The usage + account modal stays one key away on `prefix u`. ---

# --- Hub mode (issue #1482): the three chips, off the caches alone. ---
status_hub_render() {
    local me h a node_seg acct_seg hub_seg mem age hub_lost hub_fsa have
    # 入口通不通, decided once (#1483): global/hub_ok, else this cache's own #ts
    fleet_status_hub_ok "$FSR_TS"
    hub_lost=0; hub_fsa=''
    if fleet_status_hub_lost "$_FLEET_NOW"; then hub_lost=1; fleet_status_age "$FSH_AGE"; hub_fsa=$FSA; fi
    # this machine's label: the cache's #me, else FLEET_NODE_ALIASES over $HOSTNAME
    me=$FSR_ME
    if [ -z "$me" ]; then
        h=${HOSTNAME:-?}; h=${h%%.*}; me=$h
        for a in ${FLEET_NODE_ALIASES:-}; do case "$a" in "$h="*) me=${a#*=} ;; esac; done
    fi
    fleet_status_node "$STATUS_REMOTE" "$me"
    # that machine's hub_nodes row, read once: a proxy window's load and memory
    # (below), and — this machine's own row too — its fleet version's word (#644)
    have=0; fleet_status_hub_node "$FSN_NODE" && have=1
    if [ "$FSN_KIND" = local ]; then
        # here: the live readings, same numbers and colours as the plain bar
        status_fields "$m_load" "$m_mem" ''
        node_seg="${BLUE}${FSN_NODE} ${GREEN}● ${_sf}"
    elif [ "$have" = 1 ] && [ "$HN_AV" != online ]; then
        # the hub's own word on it: lost — dated by its last observation plus the
        # cache's age (longer than any silence of the hub's, so it wins the next)
        age=$(( ${HN_AGE:-0} + _FLEET_NOW - HN_TS )); [ "$age" -lt 0 ] && age=0
        fleet_status_age "$age"
        node_seg="${BLUE}${FSN_NODE} ${RED}○ 失联 ${FSA} "
    elif [ "$hub_lost" = 1 ]; then
        # the hub silent (#1483): whatever it last said of that machine — online,
        # or nothing — is as old as the silence, and this bar hears nothing itself
        node_seg="${BLUE}${FSN_NODE} ${RED}○ 失联 ${hub_fsa} "
    elif [ "$have" = 1 ]; then
        # that machine's 负载 and 内存 off the hub's row, the same units and bands
        status_load "$HN_LOAD1" "$HN_NCPU"
        case "${HN_MEM:-}" in
            ''|*[!0-9]*) mem="${DIM}–" ;;
            *) status_pct_color "$HN_MEM" 60 85; mem="${_spc}${HN_MEM}%" ;;
        esac
        status_fields "$_sl" "$mem" ''
        node_seg="${BLUE}${FSN_NODE} ${GREEN}● ${_sf}"
        # the hub could not read a fleet there (#1465): its session count is
        # unknown — say so, rather than let the machine look idle
        [ "$HN_SESS" = '?' ] && node_seg="${node_seg}${YELLOW}· 会话 ? "
    elif fleet_status_remote_node "$STATUS_SESS" "$FSN_NODE"; then
        # no hub_nodes row (a certificate identity, the shell on a colleague's
        # computer — #1484, #1502): the hub's word from the sessions cache, online
        # or lost, without the load — never a `?` for a machine the hub does list
        if [ "$RN_AV" = online ] || [ "$RN_AV" = maintenance ]; then
            node_seg="${BLUE}${FSN_NODE} ${GREEN}● "
        else
            age=$(( _FLEET_NOW - ${RN_SEEN:-0} )); [ "$age" -lt 0 ] && age=0
            fleet_status_age "$age"
            node_seg="${BLUE}${FSN_NODE} ${RED}○ 失联 ${FSA} "
        fi
    else
        node_seg="${BLUE}${FSN_NODE} ${DIM}? "
    fi
    # 旧 (issue #644): only the `old:<n>` word draws it — `ok`, `ahead`, `off`,
    # `?` and a row without the field (a pre-#644 cache) leave the chip as it was.
    case "${HN_VST:-}" in old:*) [ "$have" = 1 ] && node_seg+="${DIM}· ${YELLOW}旧 " ;; esac
    acct_seg=''
    if [ -n "$STATUS_ACCT" ] && fleet_status_hub_limit "$STATUS_ACCT"; then
        status_account "$STATUS_ACCT" "$HL_5H" "$HL_WK"; acct_seg=$_sa
    elif status_window_account; then
        acct_seg=$_sa
    fi
    if [ "$hub_lost" = 1 ]; then
        hub_seg="${DIM}│ ${RED}○ ${BLUE}入口 ${RED}失联 ${hub_fsa} "
    else
        hub_seg="${DIM}│ ${GREEN}● ${BLUE}入口 "
    fi
    printf -v HUB_BAR ' %s%s%s' "$node_seg" "$acct_seg" "$hub_seg"
}

# status_local_render → $LOCAL_BAR: the bar off hub mode — this machine, its
# fields per the client's width, and the window's account chip when it has one.
status_local_render() {
    local ctr='' acct=''
    [ -n "$m_ctr" ] && ctr="${BLUE}${FLEET_STATUS_CONTAINER:-} ${m_ctr} ${DIM}│ "
    status_fields "$m_load" "$m_mem" "$m_dsk"
    status_window_account && acct=$_sa
    printf -v LOCAL_BAR ' %s%s本机 %s%s' "$ctr" "$BLUE" "$_sf" "$acct"
}

# --- Output --- (claude count + hostname dropped — the window list and dash cover those;
# name your tmux session after your fleet so status-left carries the title)
if [ "$HUB_MODE" = 1 ]; then
    HUB_BAR=''; status_hub_render
    printf '%s%s%s' "$HUB_BAR" "$gh_seg" "$FA_BAR"
else
    LOCAL_BAR=''; status_local_render
    printf '%s%s%s' "$LOCAL_BAR" "$gh_seg" "$FA_BAR"
fi
