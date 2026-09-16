#!/bin/bash
# usage-lib.sh — shared helpers for the Claude usage / subscription-limit signal
# (issue #239). Sourced by three consumers so the freshness gate, the % parse,
# and the warn/crit thresholds live in ONE place and can't drift:
#   • bin/tmux-status.sh   — colors the footer usage stat by severity (no text)
#   • bin/usage-modal.sh   — the usage/limit detail header + account picker body
#                            (issue #289 merged the old usage-popup + account-pick)
#
# Pure: sourcing defines functions only, runs nothing (like fleet-lib.sh). No
# tmux, no network — every read is a cache file the collector already writes.
#
# State (machine-wide, one shared ~/.claude → the global/ cache dir, issue #181):
#   $C/usage      — local 5h/7d token-consumption proxy line (any freshness)
#   $C/ratelimit  — "epoch<TAB>line", written whenever a session prints
#                   "N% of your weekly limit"; surfaced only while fresh.
#   $C/collect.heartbeat — the dash collector's per-phase progress stamp; its age
#                   is the collector's LIVENESS (issue #636).
#   $C/collect.kick.ts   — epoch of the last self-heal kickstart of the collector
#                   daemon (bin/fleet-collect-kick.sh) — rate limit + dash trace.
#
# Knobs (fleet.conf, read at call time so callers just need it sourced first):
#   FLEET_USAGE_WARN_PCT  (default 75) — usage stat turns yellow at/above this %
#   FLEET_USAGE_CRIT_PCT  (default 90) — … turns red at/above this %
#   FLEET_RATELIMIT_TTL   (default 21600 = 6h) — staleness window, shared with
#                          the collector + the old footer segment.

# Machine-wide cache dir (global/, issue #181). Honors $TMPDIR like the rest.
fleet_usage_cache_dir() { printf '%s/.claude-dash/global' "${TMPDIR:-/tmp}"; }

# Echo the local 5h/7d token-usage proxy line (empty when the cache is absent).
fleet_usage_proxy() { cat "$(fleet_usage_cache_dir)/usage" 2>/dev/null; }

# Echo "pct<TAB>line" for the official ratelimit scrape when present AND fresh
# (within FLEET_RATELIMIT_TTL). `pct` is the leading integer % of `line` (empty
# when the line has no leading number). Echoes NOTHING when the cache is
# absent / stale / has a non-numeric epoch — a stale limit % is worse than none.
fleet_usage_ratelimit() {
  local f ts line pct tab
  tab=$(printf '\t')                             # POSIX tab (ANSI-C quoting is a bashism dash ignores)
  f="$(fleet_usage_cache_dir)/ratelimit"
  [ -f "$f" ] || return 0
  # The collector writes "epoch<TAB>line" with NO trailing newline, so `read`
  # returns non-zero at EOF even though it assigned ts/line — don't treat that
  # as failure (the case guard below rejects a genuinely empty/garbage epoch).
  IFS="$tab" read -r ts line < "$f" 2>/dev/null
  case "$ts" in ''|*[!0-9]*) return 0 ;; esac   # missing / non-numeric epoch → skip
  [ -n "$line" ] || return 0
  [ "$(( $(date +%s) - ts ))" -lt "${FLEET_RATELIMIT_TTL:-21600}" ] || return 0
  pct="${line%%[!0-9]*}"                          # leading run of digits ("85% …" → 85)
  printf '%s\t%s' "$pct" "$line"
}

# Map a usage % (integer, possibly empty) to a severity token: crit | warn | ok.
# Empty / non-numeric ⇒ ok (no signal). Thresholds are inclusive; crit wins ties.
fleet_usage_severity() {
  local pct="${1:-}" warn crit
  case "$pct" in ''|*[!0-9]*) echo ok; return ;; esac
  warn="${FLEET_USAGE_WARN_PCT:-75}"; crit="${FLEET_USAGE_CRIT_PCT:-90}"
  if [ "$pct" -ge "$crit" ]; then echo crit
  elif [ "$pct" -ge "$warn" ]; then echo warn
  else echo ok; fi
}

# One-line PLAIN summary (no ANSI) — proxy + the official limit line when fresh —
# for the usage-modal.sh picker header. Empty when neither cache has anything to
# show.
fleet_usage_summary_plain() {
  local proxy rl line out="" tab
  tab=$(printf '\t')                             # POSIX tab (ANSI-C quoting is a bashism dash ignores)
  proxy=$(fleet_usage_proxy)
  [ -n "$proxy" ] && out="this machine · rolling  ${proxy}"
  rl=$(fleet_usage_ratelimit)
  if [ -n "$rl" ]; then
    line="${rl#*"$tab"}"
    if [ -n "$out" ]; then out="${out}  ·  ${line}"; else out="$line"; fi
  fi
  printf '%s' "$out"
}

# fleet_limit_banner — stdin: pane text. Print the ONE line that proves the account
# hit its usage limit (the collector hands it to `fleet-account.sh mark-limited`),
# or nothing. Two shapes exist (issue #511):
#   • the classic "hit your <session|weekly|Opus> limit · resets <t> (<zone>)" — its
#     tail is the reset instant mark-limited benches to (#490), so it WINS whenever
#     present (last occurrence, like the collector always took);
#   • the newer sticky footer "Usage limit reached · continuing automatically at
#     <t> · esc to cancel", which stays on screen after the classic line scrolled
#     out of the capture window. No zone in it → the caller benches by TTL.
# Either match stops at the pane border (│) so a split pane can't bleed in.
fleet_limit_banner() {
  local text classic sticky
  text=$(cat)
  # Fast reject, fork-free (issue #706). Every pattern below requires the literal
  # word `limit` — including "Usage limit reached" — so a pane that does not
  # contain it cannot match any of them. Without this the ABSENCE of a banner, by
  # far the common case, was the most expensive answer this function could give:
  # three `grep -aoE | tail` pipelines, ~8 forks, on every window of every
  # fleet-model-switch sweep. That sweep runs inside fleet-quotawatch's 60 s tick
  # at macOS QoS BACKGROUND, where a fork costs ~10x — it was 4 of the probe's
  # 12 s. A `case` is exact here, not a heuristic: it can only skip work the
  # greps were guaranteed to find nothing in.
  case "$text" in *limit*) ;; *) return 0 ;; esac
  classic=$(printf '%s\n' "$text" | grep -aoE "hit your [A-Za-z0-9 .-]*limit[^│]*" | tail -1)
  if [ -n "$classic" ]; then printf '%s\n' "$classic"; return 0; fi
  # The per-MODEL wall's second shape (issue #524): "You've reached your Fable
  # limit. Run /usage-credits to continue or switch models with /model." — sticky
  # like the footer, but names the model and carries no reset instant.
  sticky=$(printf '%s\n' "$text" | grep -aoE "reached your [A-Za-z0-9 .-]*limit[^│]*" | tail -1)
  if [ -n "$sticky" ]; then printf '%s\n' "$sticky"; return 0; fi
  # The ` · ` separator is REQUIRED: the bare words also occur as a source-code
  # string in a worker's tool output (`"Usage limit reached"` lives in this very
  # repo) — that false positive benched a healthy account on 2026-09-02.
  printf '%s\n' "$text" | grep -aoE "Usage limit reached · [^│]*" | tail -1
}

# fleet_limit_kind — stdin: a fleet_limit_banner line. Prints `subscription` for the
# account-wide wall (the session / weekly / N-hour banners and the sticky footer) or
# `model:<alias>` for a PER-MODEL cap — "hit your Fable 5 limit", "reached your
# Fable limit", "hit your Opus limit" — where <alias> is the first word after
# "your", lowercased (Fable 5 → fable), i.e. the grammar FLEET_MODEL speaks. The
# two are different walls (issue #524): a model cap leaves the account's 5h/7d
# headroom intact for every other model, so it must never bench the account.
# Empty input → nothing.
fleet_limit_kind() {
  local b w
  b=$(cat); [ -n "$b" ] || return 0
  case "$b" in *"Usage limit reached"*) printf 'subscription\n'; return 0 ;; esac
  w=$(printf '%s\n' "$b" | sed -nE 's/.*(hit|reached) your +([A-Za-z0-9.-]+).*limit.*/\2/p' | head -1 | tr '[:upper:]' '[:lower:]')
  case "$w" in
    ''|session|weekly|daily|monthly|usage|*hour*|*day) printf 'subscription\n' ;;
    *) printf 'model:%s\n' "$w" ;;
  esac
}

# --- ccquota pre-emptive watch liveness (issue #551) ---------------------------
# The quota watch (bin/fleet-quotawatch.sh) restamps $C/account.quota.ts on every
# tick — even when the hub is unreachable (empty rows still refresh the stamp) —
# so the stamp's age is the watch's LIVENESS, not the hub's. Once the pool + hub
# are configured and the stamp is older than FLEET_ACCOUNT_QUOTA_STALE (default
# 600 s = 10× the fetch TTL), no tick has run for that long and the 70%/85%
# pre-emptive rotation is blind. Surfaced by the status bar (⚠ quota stale 47m),
# fleet-doctor, and the watch's own --status. POSIX sh (fleet-doctor sources
# nothing bash-only; keep it that way).

# fleet_quota_watch_configured — 0 iff the watch is armed: an accounts pool dir
# AND a ccquota hub URL. Mirrors the watch's own fail-open gate exactly.
fleet_quota_watch_configured() {
  [ -d "${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/accounts}" ] \
    && [ -n "${CCQUOTA_HUB_URL:-}" ]
}

# fleet_quota_stale_age — print the stamp's age in seconds IFF the watch is
# configured AND the stamp is stale (or absent: a configured pool with no stamp
# has never been watched — that is stale too). Prints nothing when fresh or off.
fleet_quota_stale_age() {
  fleet_quota_watch_configured || return 0
  _qts=$(cat "$(fleet_usage_cache_dir)/account.quota.ts" 2>/dev/null)
  case "$_qts" in ''|*[!0-9]*) _qts=0 ;; esac
  _qage=$(( $(date +%s) - _qts ))
  [ "$_qage" -ge "${FLEET_ACCOUNT_QUOTA_STALE:-600}" ] && printf '%s' "$_qage"
  return 0
}

# --- ccquota FRESH-BUT-EMPTY alarm (issue #684) --------------------------------
# The second way the pre-emptive rotation goes blind, and the one no stamp can
# see. `account.quota.ts` is restamped even when the fetch came back with nothing
# (deliberately — a dead hub must be retried at TTL cadence, not on every call),
# so a hub that answers with zero rows leaves a cache that is FRESH and EMPTY.
# Every alarm above reads that as healthy: on 2026-09-15 `--status` said
# `fresh 117`, fleet-doctor PASSed, and the 70%/85% rotation had nothing to act on
# for at least six minutes with every dial green. bin/fleet-account.sh counts the
# consecutive empty fetches (quota_empty_streak) — this is the read side.
#
# ONE empty fetch is noise: a hub blip, a fetch killed on its budget. The STREAK
# is the verdict, exactly as the model-cap probe's is (#706).
# FLEET_ACCOUNT_QUOTA_BLIND_STREAK: consecutive empty fetches before the alarm
# (default 3 ≈ 3 min at the 60s TTL); 0 turns it off.

# fleet_quota_blind — print "<streak><TAB><seconds-blind>" IFF the watch is
# configured, is TICKING, and the last N fetches all came back empty. Nothing
# otherwise. STALE WINS: a stamp that has stopped moving means no fetch is
# happening at all, so the streak is frozen history rather than a live condition
# — reporting both would put two red alarms on the bar for one broken daemon.
fleet_quota_blind() {
  fleet_quota_watch_configured || return 0
  [ -z "$(fleet_quota_stale_age)" ] || return 0
  _qbmin="${FLEET_ACCOUNT_QUOTA_BLIND_STREAK:-3}"
  case "$_qbmin" in ''|*[!0-9]*) _qbmin=3 ;; esac
  [ "$_qbmin" -eq 0 ] && return 0                      # 0 = alarm off
  _qbe=$(cat "$(fleet_usage_cache_dir)/account.quota.empty" 2>/dev/null)
  _qbn=${_qbe%%	*}; _qbs=0
  case "$_qbe" in *'	'*) _qbs=${_qbe#*	} ;; esac
  case "$_qbn" in ''|*[!0-9]*) return 0 ;; esac
  case "$_qbs" in ''|*[!0-9]*) _qbs=0 ;; esac
  [ "$_qbn" -ge "$_qbmin" ] || return 0
  _qbage=0
  [ "$_qbs" -gt 0 ] && _qbage=$(( $(date +%s) - _qbs ))
  [ "$_qbage" -lt 0 ] && _qbage=0
  printf '%s\t%s' "$_qbn" "$_qbage"
  return 0
}

# fleet_usage_human_secs <secs> — 47s | 47m | 3h | 2d (coarsest unit, floor).
fleet_usage_human_secs() {
  _s="${1:-0}"
  case "$_s" in ''|*[!0-9]*) _s=0 ;; esac
  if   [ "$_s" -ge 86400 ]; then printf '%sd' $(( _s / 86400 ))
  elif [ "$_s" -ge 3600 ];  then printf '%sh' $(( _s / 3600 ))
  elif [ "$_s" -ge 60 ];    then printf '%sm' $(( _s / 60 ))
  else                           printf '%ss' "$_s"; fi
}

# --- collector liveness (issue #636) ------------------------------------------
# EVERY number on the dash — PR state, worker state, context %, quota — is read
# out of the collector's caches. When the collector stops, the dash does NOT go
# blank: it keeps rendering the last tick's world, with nothing to say it is old.
# On 2026-09-14 launchd PENDED com.claude-fleet.collect for 103 minutes
# (`pended nondemand spawn = interval`, state `not running`, last exit 0) and the
# only signal anywhere was one WARN inside the manually-run fleet-doctor.
#
# `global/collect.heartbeat` already carries the answer: bin/tmux-dash-collect.sh
# rewrites it at every phase boundary, so `phase_ts` is the last moment the
# collector PROVABLY made progress — a finished tick stamps it together with
# `end`, a running tick advances it once per phase. Age past FLEET_COLLECT_STALE
# therefore covers both failure shapes with one number: no tick started (the #636
# pend) and a tick wedged in one phase (the #551 deadline case). Surfaced as
# `⚠ dash stale 47m` on the status bar, self-healed by bin/fleet-collect-kick.sh,
# and reported by fleet-doctor. POSIX sh — fleet-doctor sources nothing bash-only.

# fleet_collect_stale_secs — the staleness threshold. RELATIVE to the collector's
# own StartInterval since issue #639: FLEET_DAEMON_STALE_MULT (×5) × 60s = 300s.
# It used to default to the collector's supersede deadline (600s), which sounded
# safe — a tick that outlives the deadline is killed and superseded, so it can
# never be the reason the heartbeat is old — but it is blind to the failure that
# actually happens. #639 measured launchd running this 60s unit once per 7–14
# MINUTES: every number on the dash twelve times too old, and the heartbeat age
# never crossing 600s, so the verdict read `fresh 401 472` throughout. Age
# measured in MULTIPLES OF THE INTERVAL catches the degraded case and the stopped
# one with one number. The single definition lives in bin/fleet-daemon-lib.sh,
# which the collector-liveness consumers source alongside this file; the literal
# below is the fallback for a caller that did not (same value this shipped with).
fleet_collect_stale_secs() {
  if command -v fleet_daemon_stale_secs >/dev/null 2>&1; then
    fleet_daemon_stale_secs collect; return 0
  fi
  printf '%s' "${FLEET_COLLECT_STALE:-${FLEET_COLLECT_DEADLINE:-600}}"
}

# fleet_collect_hb_ts — epoch of the collector's last provable progress, or 0 when
# there is no heartbeat at all. phase_ts first (always written, and it is the one
# that advances mid-tick), then end, then start, for a partial/older file.
fleet_collect_hb_ts() {
  _chb="$(fleet_usage_cache_dir)/collect.heartbeat"
  [ -f "$_chb" ] || { printf '0'; return 0; }
  _cts=$(sed -n 's/^phase_ts=//p' "$_chb" | head -1)
  case "$_cts" in ''|*[!0-9]*) _cts=$(sed -n 's/^end=//p' "$_chb" | head -1) ;; esac
  case "$_cts" in ''|*[!0-9]*) _cts=$(sed -n 's/^start=//p' "$_chb" | head -1) ;; esac
  case "$_cts" in ''|*[!0-9]*) _cts=0 ;; esac
  printf '%s' "$_cts"
}

# fleet_collect_stale_age — the heartbeat's age in seconds IFF it is stale; prints
# nothing when fresh. NO heartbeat prints nothing either (fail-open): a fresh
# install has not completed its first tick yet, and an install that runs the
# collector by hand has no daemon to be pended — fleet-doctor's note covers that
# case, and a red bar on every new machine would only teach people to ignore it.
fleet_collect_stale_age() {
  # Delegate when bin/fleet-daemon-lib.sh is loaded: it asks the same question of
  # a WIDER set of evidence — the phase heartbeat below PLUS the scheduling stamp
  # and, crucially, `global/collect.pid`. A live tick counts as proof of life on
  # its own, which is what lets #639's much tighter threshold (300s, not 600s) be
  # safe: the phase heartbeat only advances at phase BOUNDARIES, and a single
  # phase can legitimately run for minutes (551s on a big monorepo fleet), so
  # without the pid guard the tighter threshold would paint `⚠ dash stale` over a
  # collector that is working perfectly well.
  if command -v fleet_daemon_overdue >/dev/null 2>&1; then
    fleet_daemon_overdue collect; return 0
  fi
  _cts=$(fleet_collect_hb_ts)
  [ "$_cts" -gt 0 ] || return 0
  _cage=$(( $(date +%s) - _cts ))
  [ "$_cage" -ge "$(fleet_collect_stale_secs)" ] && printf '%s' "$_cage"
  return 0
}

# fleet_collect_kick_age — seconds since the last self-heal kickstart (the stamp
# bin/fleet-collect-kick.sh writes), or nothing if it has never kicked. This is
# the TRACE: the bar keeps showing it for FLEET_COLLECT_KICK_TRACE after the
# collector recovers, so a self-heal is never a silent one.
fleet_collect_kick_age() {
  _kts=$(cat "$(fleet_usage_cache_dir)/collect.kick.ts" 2>/dev/null)
  case "$_kts" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' $(( $(date +%s) - _kts ))
  return 0
}

# fleet_collect_kick_due — 0 iff the collector is stale AND the last kick is older
# than FLEET_COLLECT_KICK_COOLDOWN. Callers gate on this BEFORE spawning the kick
# script, so the status bar (every 5s, per attached client) and the quota watch
# (every 60s) cost two file reads in the common case and fork nothing. The kick
# script re-checks and claims atomically — this is the cheap pre-filter, not the
# rate limit itself.
fleet_collect_kick_due() {
  [ -n "$(fleet_collect_stale_age)" ] || return 1
  _ka=$(fleet_collect_kick_age)
  [ -n "$_ka" ] || return 0
  [ "$_ka" -ge "${FLEET_COLLECT_KICK_COOLDOWN:-600}" ]
}
