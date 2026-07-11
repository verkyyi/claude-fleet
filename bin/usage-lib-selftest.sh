#!/bin/bash
# usage-lib-selftest.sh — hermetic unit tests for bin/usage-lib.sh, the shared
# reader behind the footer usage-stat COLOR + the usage popup (issue #239).
# Correctness here decides whether an "approaching / at limit" state is shown
# truthfully (and only while fresh), so the pure logic is worth pinning.
#
# Covered (all pure / deterministic — real `date`, no network, no tmux):
#   • fleet_usage_severity — empty/garbage → ok; the inclusive warn/crit
#     thresholds; crit wins ties; custom FLEET_USAGE_WARN_PCT/CRIT_PCT knobs.
#   • fleet_usage_ratelimit — absent/stale/bad-epoch → nothing; a fresh line →
#     "pct<TAB>line"; a line with no leading number → empty pct, line intact.
#   • fleet_usage_proxy / fleet_usage_summary_plain — proxy only, proxy + limit,
#     limit only, neither.
#
# Sourced (not run): usage-lib.sh is a pure lib (no dispatch), so sourcing only
# defines functions. The cache dir is repointed at a scratch $TMPDIR tree so no
# real collector cache is read.
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/usage-lib.sh"
[ -f "$LIB" ] || { printf 'selftest: %s not found\n' "$LIB" >&2; exit 2; }

# Isolate the cache dir: usage-lib reads "$TMPDIR/.claude-dash/global". Point
# TMPDIR at a scratch tree BEFORE sourcing (functions resolve it at call time).
WORK="$(mktemp -d "${TMPDIR:-/tmp}/usage-lib-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
CACHE="$WORK/.claude-dash/global"
mkdir -p "$CACHE"

# Deterministic thresholds regardless of any repo-root fleet.conf.
export FLEET_USAGE_WARN_PCT=75 FLEET_USAGE_CRIT_PCT=90 FLEET_RATELIMIT_TTL=21600

# shellcheck source=/dev/null
. "$LIB"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() {  # <desc> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"
}

now() { date +%s; }

# --- fleet_usage_severity: empty / non-numeric → ok --------------------------
eq "severity: empty → ok"        ok "$(fleet_usage_severity '')"
eq "severity: non-numeric → ok"  ok "$(fleet_usage_severity 'N/A')"
eq "severity: 0 → ok"            ok "$(fleet_usage_severity 0)"

# --- thresholds (warn=75, crit=90; inclusive; crit wins) ---------------------
eq "severity: 74 → ok"      ok   "$(fleet_usage_severity 74)"
eq "severity: 75 → warn"    warn "$(fleet_usage_severity 75)"
eq "severity: 89 → warn"    warn "$(fleet_usage_severity 89)"
eq "severity: 90 → crit"    crit "$(fleet_usage_severity 90)"
eq "severity: 100 → crit"   crit "$(fleet_usage_severity 100)"
eq "severity: 150 → crit"   crit "$(fleet_usage_severity 150)"

# --- custom knobs take effect (warn=50, crit=60) -----------------------------
eq "severity: knob warn=50 → 55 warn" warn \
   "$(FLEET_USAGE_WARN_PCT=50 FLEET_USAGE_CRIT_PCT=60 fleet_usage_severity 55)"
eq "severity: knob crit=60 → 60 crit" crit \
   "$(FLEET_USAGE_WARN_PCT=50 FLEET_USAGE_CRIT_PCT=60 fleet_usage_severity 60)"

# --- fleet_usage_ratelimit: absent cache → nothing ---------------------------
rm -f "$CACHE/ratelimit"
eq "ratelimit: no file → empty" "" "$(fleet_usage_ratelimit)"

# fresh line → "pct<TAB>line"
printf '%s\t%s' "$(now)" '85% of your weekly limit · resets Thu 9am' > "$CACHE/ratelimit"
eq "ratelimit: fresh → pct+line" \
   "85	85% of your weekly limit · resets Thu 9am" "$(fleet_usage_ratelimit)"

# stale line (older than TTL) → nothing
printf '%s\t%s' "$(( $(now) - 100000 ))" '85% of your weekly limit' > "$CACHE/ratelimit"
eq "ratelimit: stale → empty" "" "$(fleet_usage_ratelimit)"

# non-numeric epoch → nothing (guards a garbage/partial write)
printf '%s\t%s' 'notanepoch' '85% of your weekly limit' > "$CACHE/ratelimit"
eq "ratelimit: bad epoch → empty" "" "$(fleet_usage_ratelimit)"

# fresh line with no leading number → empty pct, line preserved (→ severity ok)
printf '%s\t%s' "$(now)" 'approaching your weekly limit' > "$CACHE/ratelimit"
eq "ratelimit: no leading number → empty pct + line" \
   "	approaching your weekly limit" "$(fleet_usage_ratelimit)"
eq "ratelimit: no-number line → severity ok" ok \
   "$(fleet_usage_severity "$(fleet_usage_ratelimit | cut -f1)")"

# --- fleet_usage_proxy + fleet_usage_summary_plain ---------------------------
rm -f "$CACHE/ratelimit" "$CACHE/usage"
eq "proxy: no file → empty"    "" "$(fleet_usage_proxy)"
eq "summary: neither → empty"  "" "$(fleet_usage_summary_plain)"

printf '%s' '5h 7.5M · 7d 9.2M' > "$CACHE/usage"
eq "proxy: reads usage file" "5h 7.5M · 7d 9.2M" "$(fleet_usage_proxy)"
eq "summary: proxy only" "this machine · rolling  5h 7.5M · 7d 9.2M" "$(fleet_usage_summary_plain)"

printf '%s\t%s' "$(now)" '92% of your weekly limit · resets Fri' > "$CACHE/ratelimit"
eq "summary: proxy + limit" \
   "this machine · rolling  5h 7.5M · 7d 9.2M  ·  92% of your weekly limit · resets Fri" \
   "$(fleet_usage_summary_plain)"

rm -f "$CACHE/usage"
eq "summary: limit only (no proxy)" \
   "92% of your weekly limit · resets Fri" "$(fleet_usage_summary_plain)"

printf 'selftest OK: usage-lib severity + freshness gate + summary (%s assertions)\n' "$CHECKS"
