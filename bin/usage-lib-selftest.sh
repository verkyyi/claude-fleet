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

# --- fleet_limit_banner: which line of a pane proves the account hit its limit --
# (issue #511) Two shapes exist. The classic line carries the reset instant + zone
# (what mark-limited benches to); the newer sticky footer ("Usage limit reached ·
# continuing automatically at …") stays on screen after the classic line has
# scrolled out of the capture window. Prefer the classic line whenever it is
# there; fall back to the footer; stop at the pane border either way.
CLASSIC="hit your session limit · resets 1:50am (America/Los_Angeles)"
FOOTER="Usage limit reached · continuing automatically at 1:50am · esc to cancel"
eq "banner: nothing limit-shaped → empty" "" \
   "$(printf 'working…\n❯ \n' | fleet_limit_banner)"
eq "banner: the classic line" "$CLASSIC" \
   "$(printf "  ⎿  You've hit your session limit · resets 1:50am (America/Los_Angeles)\n" | fleet_limit_banner)"
eq "banner: the sticky footer alone" "$FOOTER" \
   "$(printf '  ⚠ %s\n' "$FOOTER" | fleet_limit_banner)"
eq "banner: classic wins even when the footer comes later" "$CLASSIC" \
   "$(printf "  ⎿  You've %s\n⏺ Usage limit reached · continuing automatically at 1:50am · esc or type to cancel\n  ⚠ %s\n" "$CLASSIC" "$FOOTER" | fleet_limit_banner)"
eq "banner: the LAST classic line wins" "hit your weekly limit · resets Mon" \
   "$(printf "You've hit your session limit · resets 1:50am (America/Los_Angeles)\nYou've hit your weekly limit · resets Mon\n" | fleet_limit_banner)"
eq "banner: stops at the pane border" "hit your weekly limit · resets Mon " \
   "$(printf 'hit your weekly limit · resets Mon │ other pane\n' | fleet_limit_banner)"

# --- Codex's wall is not a Claude account's --------------------------------------
# A Codex pane switched to Claude in place keeps Codex's scrollback; its "hit your
# usage limit." line benched a healthy Claude account on 2026-09-18 and every spawn
# was left at a bare shell. Each shape codex-rs prints must scan as NO banner, and a
# genuine Claude wall in the same capture must still win.
CODEX_PRO="■ You’ve hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 24th, 2026 1:10"
CODEX_FREE="You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at 3:00 PM."
CODEX_TEAM="You've hit your usage limit. To get more access now, send a request to your admin or try again in 2 hours."
CODEX_BARE="You've hit your usage limit. Try again at 3:00 PM."
eq "banner: Codex Pro wall → empty"  "" "$(printf '%s\nPM.\n\n› handoff to claude\n' "$CODEX_PRO" | fleet_limit_banner)"
eq "banner: Codex Free wall → empty" "" "$(printf '%s\n' "$CODEX_FREE" | fleet_limit_banner)"
eq "banner: Codex Team wall → empty" "" "$(printf '%s\n' "$CODEX_TEAM" | fleet_limit_banner)"
eq "banner: Codex bare wall → empty" "" "$(printf '%s\n' "$CODEX_BARE" | fleet_limit_banner)"
eq "banner: Claude wall after a Codex one still wins" "$CLASSIC" \
   "$(printf "%s\n  ⎿  You've %s\n" "$CODEX_PRO" "$CLASSIC" | fleet_limit_banner)"
eq "banner: Claude wall before a Codex one still wins" "$CLASSIC" \
   "$(printf "  ⎿  You've %s\n%s\n" "$CLASSIC" "$CODEX_PRO" | fleet_limit_banner)"
eq "banner: Claude's own usage-limit wall still counts" "hit your usage limit · resets 3pm (America/Los_Angeles)" \
   "$(printf "  ⎿  You've hit your usage limit · resets 3pm (America/Los_Angeles)\n" | fleet_limit_banner)"

# --- model-specific caps (Fable / Opus) vs the subscription (issue #524) ---------
# A model cap is NOT a subscription limit: the account keeps its 5h/7d headroom for
# every other model. Treating "hit your Fable 5 limit" as the subscription banner
# benched the account and migrated everything off it — onto an account with the
# same Fable cap (the 2026-09-02 cascade). Two Fable shapes exist on screen; both
# must SURFACE from fleet_limit_banner and CLASSIFY as model:fable, while every
# subscription shape stays `subscription`. The sticky footer must carry its ` · `
# separator, so a source string like `"Usage limit reached"` scrolling by in a
# worker's tool output (how gmail got benched that day) is never taken for it.
FABLE_HIT="hit your Fable 5 limit · resets Sep 6 at 10pm (America/Los_Angeles)"
FABLE_STICKY="reached your Fable limit. Run /usage-credits to continue or switch models with /model."
eq "banner: the sticky Fable line surfaces" "$FABLE_STICKY" \
   "$(printf "  ⎿  You've %s\n" "$FABLE_STICKY" | fleet_limit_banner)"
eq "banner: a quoted source string is not the footer" "" \
   "$(printf '  ⎿    printf "Usage limit reached" ⎿ bench +\n' | fleet_limit_banner)"
eq "kind: session limit → subscription"    subscription "$(printf '%s\n' "hit your session limit · resets 1:50am (America/Los_Angeles)" | fleet_limit_kind)"
eq "kind: weekly limit → subscription"     subscription "$(printf '%s\n' "hit your weekly limit · resets Mon" | fleet_limit_kind)"
eq "kind: 5-hour limit → subscription"     subscription "$(printf '%s\n' "hit your 5-hour limit · resets 3pm" | fleet_limit_kind)"
eq "kind: sticky footer → subscription"    subscription "$(printf '%s\n' "$FOOTER" | fleet_limit_kind)"
eq "kind: Fable 5 cap → model:fable"       model:fable  "$(printf '%s\n' "$FABLE_HIT" | fleet_limit_kind)"
eq "kind: sticky Fable line → model:fable" model:fable  "$(printf '%s\n' "$FABLE_STICKY" | fleet_limit_kind)"
eq "kind: Opus cap → model:opus"           model:opus   "$(printf '%s\n' "hit your Opus limit · resets 3pm (America/Los_Angeles)" | fleet_limit_kind)"
eq "kind: nothing → nothing"               ""           "$(printf '' | fleet_limit_kind)"

# fleet_banner_replayed (#870): the wall a migrated session left behind vs a new one.
rp() { fleet_banner_replayed "$1" "$2" && echo replay || echo new; }
WK="hit your weekly limit · resets Sep 25 at 7am (Asia/Shanghai)"
eq "replay: same wall → replay"                  replay "$(rp "$WK" "$WK")"
eq "replay: redraw padding ignored → replay"     replay "$(rp "$WK   " "$WK")"
eq "replay: own reset instant → new"             new    "$(rp "hit your weekly limit · resets Sep 20 at 7am (Asia/Shanghai)" "$WK")"
eq "replay: never migrated (no stamp) → new"     new    "$(rp "$WK" "")"
eq "replay: no banner, no stamp → new"           new    "$(rp "" "")"
eq "replay: banner read off a real replayed pane" replay \
   "$(rp "$(printf "  ⎿  You've %s\n     /usage-credits to finish\n" "$WK" | fleet_limit_banner)" "$WK")"

# --- fleet_quota_merge (issue #1267): newest reading per account wins ---------
N=$(now)
QR=$(printf 'a\t10\t20\t80\t100\t200\t3\nb\t5\t5\t95\t300\t400\t0')
mg() { fleet_quota_merge "$QR" "$1" "$2" | sort; }
eq "merge: no stamps → ccquota rows + source + epoch" \
   "$(printf 'a\t10\t20\t80\t100\t200\t3\tccquota\t%s\nb\t5\t5\t95\t300\t400\t0\tccquota\t%s' $((N-100)) $((N-100)))" \
   "$(mg $((N-100)) '')"
eq "merge: newer stamp replaces %/resets, keeps %/h, headroom = 100-max" \
   "$(printf 'a\t72\t30\t28\t111\t222\t3\tstatusline\t%s' $((N-10)))" \
   "$(mg $((N-100)) "a $((N-10)) 72 30 111 222
a $((N-50)) 99 99 1 1" | grep '^a')"
eq "merge: stamp older than ccquota → ccquota" "ccquota" \
   "$(mg $((N-5)) "a $((N-10)) 72 30 111 222" | awk -F'\t' '$1=="a"{print $8}')"
eq "merge: tie → ccquota" "ccquota" \
   "$(mg $((N-10)) "a $((N-10)) 72 30 111 222" | awk -F'\t' '$1=="a"{print $8}')"
eq "merge: stamp past FLEET_QUOTA_RL_TTL → ccquota" "ccquota" \
   "$(FLEET_QUOTA_RL_TTL=5 mg $((N-100)) "a $((N-10)) 72 30 111 222" | awk -F'\t' '$1=="a"{print $8}')"
eq "merge: missing reset falls back to ccquota's" "100	200" \
   "$(mg $((N-100)) "a $((N-10)) 72 30 - -" | awk -F'\t' '$1=="a"{print $5"\t"$6}')"
eq "merge: unknown account with a fresh stamp gets a row" "$(printf 'c\t40\t88\t12\t5\t6\t0\tstatusline\t%s' $((N-5)))" \
   "$(mg $((N-100)) "c $((N-5)) 40 88 5 6" | grep '^c')"
eq "merge: '-', codex:, half, garbage and future stamps are ignored" "2" \
   "$(mg $((N-100)) "- $N 1 1
codex:x $N 99 99 1 1
a $N 99 - 1 1
a x 99 99 1 1
a $((N+3600)) 99 99 1 1" | awk -F'\t' '$8=="ccquota"' | grep -c .)"
eq "merge: ccquota empty → statusline rows only" "a	statusline" \
   "$(fleet_quota_merge '' 0 "a $N 50 60 1 2" | awk -F'\t' '{print $1"\t"$8}')"
eq "merge: nothing in → nothing out" "" "$(fleet_quota_merge '' 0 '')"

printf 'selftest OK: usage-lib severity + freshness gate + summary + limit banner + limit kind + replay + quota merge (%s assertions)\n' "$CHECKS"
