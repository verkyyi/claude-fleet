#!/bin/bash
# usage-lib.sh — shared helpers for the Claude usage / subscription-limit signal
# (issue #239). Sourced by three consumers so the freshness gate, the % parse,
# and the warn/crit thresholds live in ONE place and can't drift:
#   • bin/tmux-status.sh   — colors the footer usage stat by severity (no text)
#   • bin/usage-popup.sh   — the on-demand usage/limit detail popup
#   • bin/account-pick.sh  — the picker's usage header
#
# Pure: sourcing defines functions only, runs nothing (like fleet-lib.sh). No
# tmux, no network — every read is a cache file the collector already writes.
#
# State (machine-wide, one shared ~/.claude → the global/ cache dir, issue #181):
#   $C/usage      — local 5h/7d token-consumption proxy line (any freshness)
#   $C/ratelimit  — "epoch<TAB>line", written whenever a session prints
#                   "N% of your weekly limit"; surfaced only while fresh.
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
  local f ts line pct
  f="$(fleet_usage_cache_dir)/ratelimit"
  [ -f "$f" ] || return 0
  # The collector writes "epoch<TAB>line" with NO trailing newline, so `read`
  # returns non-zero at EOF even though it assigned ts/line — don't treat that
  # as failure (the case guard below rejects a genuinely empty/garbage epoch).
  IFS=$'\t' read -r ts line < "$f" 2>/dev/null
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
# for popup headers (account-pick.sh, usage-popup.sh --summary). Empty when
# neither cache has anything to show.
fleet_usage_summary_plain() {
  local proxy rl line out=""
  proxy=$(fleet_usage_proxy)
  [ -n "$proxy" ] && out="this machine · rolling  ${proxy}"
  rl=$(fleet_usage_ratelimit)
  if [ -n "$rl" ]; then
    line="${rl#*$'\t'}"
    if [ -n "$out" ]; then out="${out}  ·  ${line}"; else out="$line"; fi
  fi
  printf '%s' "$out"
}
