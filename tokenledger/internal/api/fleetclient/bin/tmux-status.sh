#!/bin/bash
# tmux-status.sh — right side of the tmux status bar.
# IT DRAWS ONLY WHAT WANTS YOUR HAND (issue #1616, EPIC #1615 C1). The left side
# (conf/tmux-bar.conf) is always there — ☰ · login · ● N, the sessions waiting on
# you; this side is EMPTY while all is well, and each segment appears only on its
# condition, in this order:
#   <machine>        the current window is a session on ANOTHER machine (hub mode,
#                    `@remote`): its name; `○ 失联 Nm` after it when the hub calls
#                    that machine lost; `旧` when its live install is behind the
#                    stable mark (#644 — this machine's own row says it too)
#   <account> 5h N%  the current window's account (`@cc_account`) is at or past
#                    FLEET_STATUS_QUOTA_PCT (80) on max(5h, 周) — off the hub's
#                    limits cache in hub mode, else the window's own @rl5h/@rl7d;
#                    only the window(s) past the line are drawn
#   ⚠ GitHub 受限    the shared gh-limit marker says a bucket is limited (#989)
#   ✖ N  ▲ N         alarms / warnings (bin/fleet-alerts.sh), each only when ≠ 0;
#                    负载 / 内存 / 盘 in the red are warnings there now, not chips
#   ○ 入口 Nm        hub mode, and the hub has been silent past
#                    FLEET_HUB_SESSIONS_STALE (fleet_status_hub_lost, #1483)
#   <ctr> ○          FLEET_STATUS_CONTAINER is set and that container is down
# Narrower than 60 columns (`cw=`, the client's width) the account's label goes
# and only the highest window is drawn, so a 54-column iPad / iPhone in portrait
# keeps the bad news whole. 本机名, 负载, 内存, 盘 and ● 入口 are not drawn while
# normal: they took room on every client and said nothing (issue #1616).
# Every colour comes from conf/fleet-palette.conf (bin/fleet-palette.sh).
#
# HUB MODE (issue #1482) is the same layout; what it adds is where the numbers
# come from and the two hub-only segments (the machine of a proxy window, the
# hub's silence). The window list goes blank in hub mode and comes back when it
# leaves (fleet_status_window_list). The cue is the `k=v` args the conf's
# status-right passes from the CLIENT'S CURRENT WINDOW (`sess= win= remote= acct=
# wsf= wscf= wsaved= cw= rl5= rl7=`): tmux re-runs the job the moment the
# expanded command changes, so a window switch swaps the segments at once. Hub
# mode = CCQUOTA_FLEET=1 + the fleet's FLEET_SIDEBAR_SOURCE=hub + a remote_<sess>
# cache on disk (the sidebar's own gate, #1480); otherwise — and with no args at
# all — it is off. Data: bin/fleet-status-lib.sh reads the summaries
# fleet-hub-sessions.sh --loop writes (hub_nodes / hub_limits); the render path
# never touches the network (EPIC #1479 rule 2).
set -uo pipefail

case "$0" in */*) BIN="${0%/*}" ;; *) BIN=. ;; esac   # forkless dirname (issue #888)
BIN="$(cd "${BIN:-/}" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
_fs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"; [ -f "$_fs/fleet.settings" ] && . "$_fs/fleet.settings"; [ -f "$_fs/fleet.conf" ] && . "$_fs/fleet.conf"   # the login's settings win (#979); the machine's one file (#1623)
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
# status_conf_has <file> <KEY> is the same read, rc 0 only when the file spells
# the key at all (an explicit `KEY=` counts) — what lets a fleet's own line beat
# the environment.
status_conf_key() {
    local line; _sck=''; _sch=0
    [ -f "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$2="*|"export $2="*)
                line=${line#*=}; line=${line%%#*}; line=${line%"${line##*[![:space:]]}"}
                line=${line#\"}; line=${line%\"}; line=${line#\'}; line=${line%\'}
                _sck=$line; _sch=1 ;;
        esac
    done < "$1"
}
status_conf_has() { status_conf_key "$1" "$2"; [ "$_sch" = 1 ]; }

# Hub mode (issue #1482): CCQUOTA_FLEET=1, the current session's fleet set to
# FLEET_SIDEBAR_SOURCE=hub (its own conf wins over fleet.conf / fleet.settings),
# and the sidebar's remote_<sess> cache on disk — no cache, no hub mode: the bar
# renders exactly as before until the loop's first answer (as the sidebar does).
# The hub switch itself is per fleet too (issue #1539): the session's own conf
# line wins over the environment, as fleet_hub_on reads it in fleet-lib.sh.
HUB_MODE=0
if [ -n "$STATUS_SESS" ]; then
    _cd="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
    _sconf="$_cd/fleets/$STATUS_SESS/conf"; [ -f "$_sconf" ] || _sconf="$_cd/$STATUS_SESS.conf"
    _hub="${CCQUOTA_FLEET:-0}"
    status_conf_has "$_sconf" CCQUOTA_FLEET && _hub=$_sck
    if [ "$_hub" = 1 ]; then
        _src="${FLEET_SIDEBAR_SOURCE:-local}"
        status_conf_key "$_sconf" FLEET_SIDEBAR_SOURCE
        [ -n "$_sck" ] && _src=$_sck
        [ "$_src" = hub ] && fleet_status_remote_head "$STATUS_SESS" && HUB_MODE=1
    fi
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

# Palette: conf/fleet-palette.conf, the fleet's ONE colour table (issue #1534) —
# never a hex here. No palette file → no colour at all, never a colour of our own.
. "$BIN/fleet-palette.sh"
if fleet_palette_load "$BIN/../conf/fleet-palette.conf"; then
    RED="#[fg=$PAL_RED]" YELLOW="#[fg=$PAL_YELLOW]" GREEN="#[fg=$PAL_GREEN]"
    BLUE="#[fg=$PAL_BLUE]" DIM="#[fg=$PAL_DIM]"
else
    RED='' YELLOW='' GREEN='' BLUE='' DIM=''
fi

# status_pct_color <pct> <yellow-at> <red-at> → $_spc: the palette colour for a
# percentage; DIM for anything that is not one.
status_pct_color() {
    case "${1:-}" in ''|*[!0-9]*) _spc=$DIM; return 0 ;; esac
    if   [ "$1" -ge "$3" ]; then _spc=$RED
    elif [ "$1" -ge "$2" ]; then _spc=$YELLOW
    else _spc=$GREEN; fi
}

# --- The container's ●/○ (FLEET_STATUS_CONTAINER, optional). `docker ps` is the
# only reading the bar execs, and tmux runs this script every status-interval PER
# ATTACHED CLIENT — so it is measured once per FLEET_STATUS_CACHE_SECS (default 5)
# across every client through ${TMPDIR}/fleet-status.cache (issue #890):
#   fresh            → printed as is: zero forks.
#   expired          → the first caller to `mkdir` the lock re-measures and
#                      publishes atomically (tmp + mv); the rest print the previous
#                      value — one render late, never blank, never doubled.
#   none / ancient   → (cold start, or no client for 6 intervals) wait for a holder
#   (≥ 6 intervals)    up to 3s; a lock still held after that is a dead holder's —
#                      break it and measure here.
# FLEET_STATUS_CACHE_SECS=0 turns sharing off. No container configured → nothing
# is measured and no cache is touched. 负载 / 内存 / 盘 are no longer the bar's
# (issue #1616): fleet-alerts.sh raises them as warnings when they turn red.
# Sets m_ctr ('' = running or none, else the coloured `○`).
status_ctr_compute() {
    m_ctr=''
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${FLEET_STATUS_CONTAINER}$" || m_ctr="${RED}○"
}
status_ctr_cached() {
    local ttl="${FLEET_STATUS_CACHE_SECS:-5}" d="${TMPDIR:-/tmp}" cache lock key
    local ts="" k="" val="" age=-1 tries=0 now="$_FLEET_NOW"
    m_ctr=''
    [ -n "${FLEET_STATUS_CONTAINER:-}" ] || return 0
    case "$ttl" in ''|*[!0-9]*) ttl=5 ;; esac
    if [ "$ttl" -eq 0 ]; then status_ctr_compute; return; fi
    cache="${FLEET_STATUS_CACHE:-${d%/}/fleet-status.cache}"; lock="$cache.lock"
    key="v3|${FLEET_STATUS_CONTAINER}"
    _smc_read() {   # → ts/val + age; age=-1 when there is no usable entry
        ts="" k="" val="" age=-1
        { IFS=$'\t' read -r ts k; IFS= read -r val; } 2>/dev/null < "$cache"
        case "$ts" in ''|*[!0-9]*) return 0 ;; esac
        [ "$k" = "$key" ] || return 0
        if [ "$now" -ge "$ts" ]; then age=$(( now - ts ))
        elif [ $(( ts - now )) -le "$ttl" ]; then age=0   # a holder that pinned its clock after ours
        fi
        return 0
    }
    # the value line is `=<m_ctr>`: a running container is an empty value, and an
    # empty line must still read as an entry
    _smc_use() { m_ctr=${val#=}; }
    _smc_read
    if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then _smc_use; return; fi
    if mkdir "$lock" 2>/dev/null; then
        status_ctr_compute
        printf '%s\t%s\n=%s\n' "$now" "$key" "$m_ctr" > "$cache.$$" 2>/dev/null \
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
    status_ctr_compute
}

# The client's width (`cw=`): narrower than 60 columns is the phone layout. No
# width (an older conf) = room for everything.
STATUS_NARROW=0
case "${STATUS_CW:-}" in ''|*[!0-9]*) ;; *) [ "$STATUS_CW" -lt 60 ] && STATUS_NARROW=1 ;; esac

# status_quota <label> <5h> <周> → $_sq: the account segment when max(5h, 周) is at
# or past FLEET_STATUS_QUOTA_PCT (default 80), else ''. Only the window(s) past
# the line are drawn, coloured through the account knobs' bands; narrow, the
# label goes and only the higher one stays.
status_quota() {
    local line="${FLEET_STATUS_QUOTA_PCT:-80}" a="${2:-}" b="${3:-}" c
    case "$line" in ''|*[!0-9]*) line=80 ;; esac
    case "$a" in *[!0-9]*) a='' ;; esac
    case "$b" in *[!0-9]*) b='' ;; esac
    _sq=''
    [ -n "$a" ] && [ "$a" -lt "$line" ] && a=''
    [ -n "$b" ] && [ "$b" -lt "$line" ] && b=''
    [ -n "$a$b" ] || return 0
    if [ "$STATUS_NARROW" = 1 ] && [ -n "$a" ] && [ -n "$b" ]; then
        if [ "$a" -ge "$b" ]; then b=''; else a=''; fi
    fi
    if [ -n "$a" ]; then
        status_pct_color "$a" "${FLEET_ACCOUNT_WARN_PCT:-70}" "${FLEET_ACCOUNT_CEILING:-85}"; c=$_spc
        _sq="${DIM}5h ${c}${a}%"
    fi
    if [ -n "$b" ]; then
        status_pct_color "$b" "${FLEET_ACCOUNT_WARN_PCT:-70}" "${FLEET_ACCOUNT_CEILING:-85}"; c=$_spc
        _sq="${_sq:+$_sq ${DIM}· }${DIM}周 ${c}${b}%"
    fi
    [ "$STATUS_NARROW" = 1 ] || _sq="${BLUE}$1 ${_sq}"
    return 0
}

# status_account → $_sq: the quota segment of the current window's account — off
# the hub's limits cache in hub mode when it knows the account, else the window's
# own reading (`rl5=`/`rl7=`, the @rl5h/@rl7d conf/statusline.sh stamps).
status_account() {
    _sq=''
    [ -n "$STATUS_ACCT" ] || return 0
    if [ "$HUB_MODE" = 1 ] && fleet_status_hub_limit "$STATUS_ACCT"; then
        status_quota "$STATUS_ACCT" "$HL_5H" "$HL_WK"
    else
        status_quota "$STATUS_ACCT" "${STATUS_RL5:-}" "${STATUS_RL7:-}"
    fi
}

# SEGS: the segments drawn so far, two spaces apart; status_seg <seg> adds one.
SEGS=''
status_seg() { [ -n "$1" ] && SEGS="${SEGS:+$SEGS  }$1"; return 0; }

m_ctr=''
status_ctr_cached

# --- Alerts: COUNTS only (issue #1238), and only when not zero (issue #1616).
# The ONE producer, bin/fleet-alerts.sh, writes $G/alerts.ndjson (quota stale /
# unreadable / from banner / uneven, dash + daemon stale with their ↻ self-heal
# traces, disk low, machine load / memory high, accounts all capped, model
# capped, needs), and the bar draws `✖ N ▲ N` off it; `prefix !` (or a click on a
# count) opens the table.
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
# injected limit (FLEET_GH_FAKE_LIMIT) has no reset time, so it shows bare; so
# does a narrow client.
gh_seg=""
_FLEET_GH_LIB_DIR="$BIN"
if [ -f "$BIN/fleet-gh-lib.sh" ] && . "$BIN/fleet-gh-lib.sh" && gh_until=$(fleet_gh_limit_until 2>/dev/null); then
    gh_seg="${YELLOW}⚠ GitHub 受限"
    case "$gh_until" in
        ''|*[!0-9]*) ;;
        *) [ "$STATUS_NARROW" = 1 ] || gh_seg="${gh_seg}至 $(fleet_gh_hhmm "$gh_until")" ;;
    esac
fi

# --- Hub mode (issue #1482): the machine of a proxy window and the hub's silence,
# off the caches alone. Sets MACH_SEG and HUB_SEG ('' = nothing to say).
status_hub_render() {
    local me h a have age
    MACH_SEG='' HUB_SEG=''
    # 入口通不通, decided once (#1483): global/hub_ok, else this cache's own #ts
    fleet_status_hub_ok "$FSR_TS"
    if fleet_status_hub_lost "$_FLEET_NOW"; then
        fleet_status_age "$FSH_AGE"
        HUB_SEG="${RED}○ ${BLUE}入口 ${RED}${FSA}"
    fi
    # this machine's label: the cache's #me, else FLEET_NODE_ALIASES over $HOSTNAME
    me=$FSR_ME
    if [ -z "$me" ]; then
        h=${HOSTNAME:-?}; h=${h%%.*}; me=$h
        for a in ${FLEET_NODE_ALIASES:-}; do case "$a" in "$h="*) me=${a#*=} ;; esac; done
    fi
    fleet_status_node "$STATUS_REMOTE" "$me"
    # that machine's hub_nodes row, read once: whether the hub calls it lost, and
    # — this machine's own row too — its fleet version's word (#644)
    have=0; fleet_status_hub_node "$FSN_NODE" && have=1
    if [ "$FSN_KIND" != local ]; then
        MACH_SEG="${BLUE}${FSN_NODE}"
        if [ -n "$HUB_SEG" ]; then
            :   # the hub silent (#1483): ○ 入口 says it — nothing here hears that machine
        elif [ "$have" = 1 ] && [ "$HN_AV" != online ]; then
            # the hub's own word on it: lost — dated by its last observation plus
            # the cache's age
            age=$(( ${HN_AGE:-0} + _FLEET_NOW - HN_TS )); [ "$age" -lt 0 ] && age=0
            fleet_status_age "$age"
            MACH_SEG="${MACH_SEG} ${RED}○ 失联 ${FSA}"
        elif [ "$have" = 0 ] && fleet_status_remote_node "$STATUS_SESS" "$FSN_NODE" &&
             [ "$RN_AV" != online ] && [ "$RN_AV" != maintenance ]; then
            # no hub_nodes row (a certificate identity, #1484/#1502): the sessions
            # cache's word on it
            age=$(( _FLEET_NOW - ${RN_SEEN:-0} )); [ "$age" -lt 0 ] && age=0
            fleet_status_age "$age"
            MACH_SEG="${MACH_SEG} ${RED}○ 失联 ${FSA}"
        fi
    fi
    # 旧 (issue #644): only the `old:<n>` word draws it — `ok`, `ahead`, `off`,
    # `?` and a row without the field (a pre-#644 cache) say nothing. This
    # machine's own row draws its name with it: the one that was never looked at
    # is the one that shows it.
    case "${HN_VST:-}" in old:*)
        [ "$have" = 1 ] && MACH_SEG="${MACH_SEG:-${BLUE}${FSN_NODE}} ${YELLOW}旧" ;;
    esac
    return 0
}

# --- Output: the segments in their order, nothing at all while all is well.
MACH_SEG='' HUB_SEG=''
[ "$HUB_MODE" = 1 ] && status_hub_render
status_account
status_seg "$MACH_SEG"
status_seg "$_sq"
status_seg "$gh_seg"
status_seg "$FA_BAR"
status_seg "$HUB_SEG"
[ -n "$m_ctr" ] && status_seg "${BLUE}${FLEET_STATUS_CONTAINER} ${m_ctr}"
[ -n "$SEGS" ] && printf ' %s ' "$SEGS"
exit 0
