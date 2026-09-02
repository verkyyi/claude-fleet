#!/bin/bash
# fleet-account-selftest.sh — hermetic unit tests for the pure ROTATION MATH in
# bin/fleet-account.sh (the multi-account usage-limit failover). Correctness here
# decides whether the fleet fails over to a fresh subscription cleanly or thrashes
# straight back into a limited one, so the branching logic is worth pinning.
#
# Covered (all pure / deterministic — real `date` only, no network, no real tokens):
#   • dur_secs   — s/m/h/d suffixes, bare seconds, and garbage → empty.
#   • human_dur  — seconds → the coarsest d/h/m unit.
#   • acct_ttl   — per-account <label>.conf LIMIT_TTL override vs the global
#                  default, with fallback when the override is absent/invalid/0.
#   • acct_limited_until / acct_eligible — read known epochs from a temp
#                  account.limited (future = benched, past/absent = eligible;
#                  duplicate rows → the furthest-future epoch wins).
#   • pick_active — keep-current-if-eligible, rotate-past-limited round-robin
#                  (incl. wraparound), and the all-limited best-effort fallback.
#   • banner_reset_epoch — the limit banner's "resets <time> (<zone>)" → epoch:
#                  zone travels with the banner (host TZ must not change it),
#                  midnight wrap, 12h-clock edges, a DST-transition day, and
#                  every unparseable form falling back instead of guessing.
#   • cmd_mark_limited — benches to that instant (+RESET_BUFFER) when there is
#                  one, and to now+LIMIT_TTL (per-account conf included) when not.
#
# Sourced (not run): fleet-account.sh guards its bottom dispatch with
# `[ "${BASH_SOURCE[0]}" = "$0" ]`, so sourcing defines the helpers WITHOUT
# running any command — no rotation, no state writes, hermetic even if a
# repo-root fleet.conf points FLEET_ACCOUNTS_DIR at real accounts. The state
# globals are then repointed at a scratch tree. (The empty temp
# FLEET_ACCOUNTS_DIR below is belt-and-suspenders on top of that guard.)
#
# Exit 0 = pass, non-zero = fail (prints what diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$BIN/fleet-account.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-account-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

# Empty accounts dir at source time → OFF → the bottom dispatch is a no-op that
# can't read/rotate the caller's real accounts.
export FLEET_ACCOUNTS_DIR="$WORK/accounts"
mkdir -p "$FLEET_ACCOUNTS_DIR"

# shellcheck source=/dev/null
. "$SCRIPT"

# Repoint every piece of state fleet-account resolved at source time onto the
# scratch tree (the functions read these globals at CALL time, so this takes).
ACCT_DIR="$WORK/accounts"
# shellcheck disable=SC2034  # read by the sourced acct_ttl() as its global default
TTL=18000
FLEET_C="$WORK/cache"; mkdir -p "$FLEET_C"
STATE_LIMITED="$FLEET_C/account.limited"   # only the limited-state file is read by the tested fns

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() {  # <desc> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"
}
rc_is() {  # <desc> <expected-rc> <actual-rc>
  CHECKS=$((CHECKS + 1))
  [ "$2" = "$3" ] || fail "$1 — expected rc $2, got rc $3"
}

# ============================================================================
# dur_secs — <N>[smhd] | bare seconds | garbage→empty
# ============================================================================
eq "dur_secs 30s" 30      "$(dur_secs 30s)"
eq "dur_secs 5m"  300     "$(dur_secs 5m)"
eq "dur_secs 2h"  7200    "$(dur_secs 2h)"
eq "dur_secs 1d"  86400   "$(dur_secs 1d)"
eq "dur_secs bare 45" 45  "$(dur_secs 45)"
eq "dur_secs 0s"  0       "$(dur_secs 0s)"
eq "dur_secs empty"  ""   "$(dur_secs '')"
eq "dur_secs garbage abc" "" "$(dur_secs abc)"
eq "dur_secs bad suffix 10x" "" "$(dur_secs 10x)"
eq "dur_secs lone suffix m"  "" "$(dur_secs m)"

# ============================================================================
# human_dur — seconds → coarsest d/h/m
# ============================================================================
eq "human_dur 90000 → 1d" 1d "$(human_dur 90000)"
eq "human_dur 86400 → 1d" 1d "$(human_dur 86400)"
eq "human_dur 7200 → 2h"  2h "$(human_dur 7200)"
eq "human_dur 3600 → 1h"  1h "$(human_dur 3600)"
eq "human_dur 120 → 2m"   2m "$(human_dur 120)"

# ============================================================================
# acct_ttl — per-account LIMIT_TTL override vs global default
# ============================================================================
eq "acct_ttl: no conf → global default" 18000 "$(acct_ttl noconf)"

printf 'LIMIT_TTL=7d\n' > "$ACCT_DIR/weekly.conf"
eq "acct_ttl: LIMIT_TTL=7d override" 604800 "$(acct_ttl weekly)"

printf 'LIMIT_TTL = 90m \n' > "$ACCT_DIR/spaced.conf"   # whitespace tolerated
eq "acct_ttl: whitespace-tolerant override" 5400 "$(acct_ttl spaced)"

printf 'LIMIT_TTL=garbage\n' > "$ACCT_DIR/bad.conf"
eq "acct_ttl: invalid override → global fallback" 18000 "$(acct_ttl bad)"

printf 'LIMIT_TTL=0s\n' > "$ACCT_DIR/zero.conf"          # 0 is not >0 → fallback
eq "acct_ttl: zero override → global fallback" 18000 "$(acct_ttl zero)"

# ============================================================================
# acct_limited_until / acct_eligible — epochs in a temp account.limited
# ============================================================================
NOW=$(now)
FUT=$((NOW + 10000)); PAST=$((NOW - 10000)); FUT2=$((NOW + 20000))

# No state file → not limited, eligible.
eq "limited_until: no state file" 0 "$(acct_limited_until acctA)"
acct_eligible acctA; rc_is "eligible: no state file" 0 $?

{ printf 'acctA\t%s\tbenched\n' "$FUT"
  printf 'acctB\t%s\texpired\n' "$PAST"
  printf 'acctA\t%s\tbenched-longer\n' "$FUT2"   # dup row → furthest-future wins
} > "$STATE_LIMITED"

eq "limited_until: future row picks furthest epoch" "$FUT2" "$(acct_limited_until acctA)"
eq "limited_until: expired row → 0" 0 "$(acct_limited_until acctB)"
eq "limited_until: unknown label → 0" 0 "$(acct_limited_until acctZ)"

acct_eligible acctA; rc_is "eligible: benched acct is NOT eligible" 1 $?
acct_eligible acctB; rc_is "eligible: expired acct IS eligible" 0 $?
acct_eligible acctZ; rc_is "eligible: unknown acct IS eligible" 0 $?

# ============================================================================
# pick_active — keep / rotate round-robin / all-limited fallback
# ============================================================================
# Three real token files; pin their order with FLEET_ACCOUNTS so the round-robin
# is deterministic regardless of readdir/sort locale.
: > "$ACCT_DIR/a"; : > "$ACCT_DIR/b"; : > "$ACCT_DIR/c"
export FLEET_ACCOUNTS="a b c"

limit() { printf '%s\t%s\ttest\n' "$1" "$((NOW + 10000))" >> "$STATE_LIMITED"; }
clear_limits() { : > "$STATE_LIMITED"; }

# 1. current is eligible → keep it (no rotation).
clear_limits
eq "pick_active: keep eligible current" b "$(pick_active b)"

# 2. current limited, next eligible → rotate to the next round-robin.
clear_limits; limit a
eq "pick_active: rotate past limited current → next" b "$(pick_active a)"

# 3. current + next both limited → skip to the first eligible after them.
clear_limits; limit a; limit b
eq "pick_active: skip two limited → c" c "$(pick_active a)"

# 4. wraparound: current is the LAST and limited → wrap to the first eligible.
clear_limits; limit c
eq "pick_active: wraparound from last → a" a "$(pick_active c)"

# 5. current not in the pool (start<0), all eligible → first eligible.
clear_limits
eq "pick_active: unknown current → first eligible" a "$(pick_active zzz)"

# 6. empty current, all eligible → first in order.
clear_limits
eq "pick_active: empty current → first" a "$(pick_active '')"

# 7. ALL limited, current present → best-effort keep current (sessions still launch).
clear_limits; limit a; limit b; limit c
eq "pick_active: all limited, keep current" b "$(pick_active b)"

# 8. ALL limited, current NOT in pool → fall back to the first label.
eq "pick_active: all limited, unknown current → L[0]" a "$(pick_active zzz)"

# ── banner_reset_epoch + its wiring into mark-limited (issue #490) ────────────
# The banner carries the account's real refresh instant; benching for a duration
# instead is wrong in both directions (idle past the refresh, or released early
# into the same wall). Epochs below are pinned constants computed independently
# (python zoneinfo), NOT re-derived from the code under test.
#
# Zone note: every expectation is an ABSOLUTE epoch, so these hold whatever the
# host TZ is — and the "host in another zone" case pins that explicitly.

Z='(America/Los_Angeles)'
B_1020="hit your session limit · resets 10:20pm $Z"

# 2026-08-22 20:08 PDT → the banner's 22:20 PDT the same day.
eq "banner: resets 10:20pm + zone" 1787462400 "$(banner_reset_epoch "$B_1020" 1787454480)"

# The zone travels with the BANNER: a host in Shanghai must land on the same
# instant, not on 22:20 local. This is the case a naive local-time parse breaks.
eq "banner: host TZ ≠ account TZ" 1787462400 \
   "$(TZ=Asia/Shanghai banner_reset_epoch "$B_1020" 1787454480)"
eq "banner: host TZ = UTC" 1787462400 \
   "$(TZ=UTC banner_reset_epoch "$B_1020" 1787454480)"

# 23:00 seeing "12:30am" means TOMORROW — not 22.5h in the past.
eq "banner: midnight wrap → tomorrow" 1787470200 \
   "$(banner_reset_epoch "hit your session limit · resets 12:30am $Z" 1787464800)"

# 12-hour clock edges: 12pm is noon, 12am is midnight (the h=12 special cases).
eq "banner: 12:00pm is noon" 1787425200 \
   "$(banner_reset_epoch "hit your session limit · resets 12:00pm $Z" 1787410800)"

# No zone in the banner → host local time. Pin TZ so the expectation is stable.
eq "banner: no zone → host local" 1787436000 \
   "$(TZ=America/Los_Angeles banner_reset_epoch 'hit your 5-hour limit · resets 3pm' 1787410800)"

# A DST-transition day (2026-11-01, US fall-back): formatting the candidate date
# FROM an epoch keeps the answer on the right side of the shift.
eq "banner: DST fall-back day" 1793604600 \
   "$(banner_reset_epoch "hit your session limit · resets 11:30pm $Z" 1793592000)"

# --- everything below must FALL BACK (empty), never guess an epoch ------------
eq "banner: weekly banner has no clock time" '' \
   "$(banner_reset_epoch 'hit your weekly limit · resets Monday' 1787454480)"
eq "banner: no banner at all" '' "$(banner_reset_epoch '' 1787454480)"
eq "banner: limit banner without a resets clause" '' \
   "$(banner_reset_epoch 'hit your Opus limit' 1787454480)"
# An unknown zone resolves to UTC on both glibc and macOS — silently the WRONG
# instant. Strict validation turns that into a fallback instead.
eq "banner: unknown zone → fallback, not silent UTC" '' \
   "$(banner_reset_epoch 'hit your session limit · resets 10:20pm (Mars/Olympus)' 1787454480)"
eq "banner: 24h clock without am/pm" '' \
   "$(banner_reset_epoch "hit your session limit · resets 22:20 $Z" 1787454480)"
eq "banner: hour out of 12h range" '' \
   "$(banner_reset_epoch "hit your session limit · resets 13:20pm $Z" 1787454480)"

# --- wiring: mark-limited must bench to the PARSED instant, not now+TTL -------
# Repoint the write-side state too (the read-side already is), and pin now() so
# the assertion is exact.
STATE_ACTIVE="$FLEET_C/account.active"
# shellcheck disable=SC2034  # both read by the sourced cmd_mark_limited at CALL time
STATE_DIR="$FLEET_C"
# shellcheck disable=SC2034
LOCK="$FLEET_C/account.lock"
now() { printf '%s' "${NOW_FIXED:-1787454480}"; }
: > "$STATE_LIMITED"; printf 'a\n' > "$STATE_ACTIVE"

cmd_mark_limited a "$B_1020" >/dev/null
eq "mark-limited: benches to the banner instant + buffer" \
   "$((1787462400 + RESET_BUFFER))" "$(awk -F'\t' '$1=="a"{print $2}' "$STATE_LIMITED")"

# Same call, banner with no parseable instant → the LIMIT_TTL path, unchanged.
: > "$STATE_LIMITED"; printf 'a\n' > "$STATE_ACTIVE"
cmd_mark_limited a 'hit your weekly limit · resets Monday' >/dev/null
eq "mark-limited: no instant → now + LIMIT_TTL (unchanged)" \
   "$((1787454480 + TTL))" "$(awk -F'\t' '$1=="a"{print $2}' "$STATE_LIMITED")"

# And a per-account LIMIT_TTL still wins on that fallback path.
printf 'LIMIT_TTL=7d\n' > "$ACCT_DIR/a.conf"
: > "$STATE_LIMITED"; printf 'a\n' > "$STATE_ACTIVE"
cmd_mark_limited a '' >/dev/null
eq "mark-limited: fallback still honours per-account LIMIT_TTL" \
   "$((1787454480 + 604800))" "$(awk -F'\t' '$1=="a"{print $2}' "$STATE_LIMITED")"
rm -f "$ACCT_DIR/a.conf"; : > "$STATE_LIMITED"

# ============================================================================
# ccquota (issue #513): quota_parse fixture → rows; pick_active prefers headroom
# under the ceiling (with hysteresis) and falls back to round-robin; cmd_bench
# benches to an exact instant (+RESET_BUFFER) and rotates the active pointer.
# ============================================================================
STATE_QUOTA="$FLEET_C/account.quota"; STATE_QUOTA_TS="$FLEET_C/account.quota.ts"
# shellcheck disable=SC2034  # read by the sourced pick_active at call time
CEILING=85
: > "$STATE_LIMITED"; rm -f "$STATE_QUOTA"; printf 'a\n' > "$STATE_ACTIVE"
# labels a b c already exist as token files; pin c to a uuid via c.conf
printf 'CCQUOTA_ACCOUNT=uuid-cccc\n' > "$ACCT_DIR/c.conf"
fixture='{"verdict":"go","accounts":[
 {"account_uuid":"uuid-aaaa","label":"a","headroom_pct":24,"five_hour":{"utilization":76,"resets_at":"2026-09-02T14:00:00Z","percent_per_hour":36.4},"seven_day":{"utilization":34,"resets_at":"2026-09-07T05:00:00Z"}},
 {"account_uuid":"uuid-bbbb","label":"b","headroom_pct":75,"five_hour":{"utilization":0,"resets_at":"2026-09-02T13:50:00Z"},"seven_day":{"utilization":25,"resets_at":"2026-09-04T14:00:00Z"}},
 {"account_uuid":"uuid-cccc","label":"c-renamed-in-ccquota","headroom_pct":0,"five_hour":{"utilization":100,"resets_at":"2026-09-02T11:50:00Z"},"seven_day":{"utilization":21,"resets_at":"2026-09-06T06:00:00Z"}},
 {"account_uuid":"uuid-zzzz","label":"not-in-pool","headroom_pct":90,"five_hour":{"utilization":10},"seven_day":{"utilization":10}}]}'
rows=$(printf '%s' "$fixture" | quota_parse)
eq "quota_parse: one row per pool label, by name" "a	76	34	24	1788357600	1788757200	36" "$(printf '%s\n' "$rows" | grep '^a	')"
eq "quota_parse: uuid pin via <label>.conf"        "c	100	21	0	1788349800	1788674400	0"  "$(printf '%s\n' "$rows" | grep '^c	')"
eq "quota_parse: accounts outside the pool are dropped" "" "$(printf '%s\n' "$rows" | grep 'not-in-pool')"
eq "quota_parse: row count" 3 "$(printf '%s\n' "$rows" | grep -c .)"
eq "quota_parse: unknown verdict → no rows" "" "$(printf '{"verdict":"unknown","accounts":[]}' | quota_parse)"
eq "quota_parse: garbage → no rows" "" "$(printf 'not json' | quota_parse)"
eq "quota_field: 5h reset epoch of a" 1788357600 "$(quota_field "$rows" a 5)"
eq "quota_field: missing label → empty" "" "$(quota_field "$rows" nope 4)"

printf '%s' "$rows" > "$STATE_QUOTA"; NOW > "$STATE_QUOTA_TS" 2>/dev/null || date +%s > "$STATE_QUOTA_TS"
eq "pick_active(quota): most headroom wins (a 24 → b 75)"          b "$(pick_active a)"
eq "pick_active(quota): keep current within 10 points of best"      b "$(pick_active b)"
eq "pick_active(quota): c is at the ceiling → never picked"         b "$(pick_active c)"
rows2=$(printf '%s\n' "$rows" | sed 's/^a	76	34	24/a	5	34	70/')   # a now 70 headroom vs b 75 → within 10 → keep a
printf '%s' "$rows2" > "$STATE_QUOTA"
eq "pick_active(quota): hysteresis keeps current within 10 points" a "$(pick_active a)"
limit b                                                            # b benched → a is the only candidate
eq "pick_active(quota): benched accounts are skipped"               a "$(pick_active b)"
clear_limits
printf 'a	90	34	10	1	2	0\nb	95	1	5	1	2	0\nc	100	21	0	1	2	0\n' > "$STATE_QUOTA"
eq "pick_active(quota): everyone at the ceiling → round-robin keeps current" b "$(pick_active b)"
rm -f "$STATE_QUOTA"
eq "pick_active(no quota): plain round-robin"                       b "$(pick_active b)"

# cmd_bench: exact instant + buffer, rotates when the benched one was active (exit 10)
: > "$STATE_LIMITED"; printf 'a\n' > "$STATE_ACTIVE"
until=$(( $(now) + 3600 ))                                          # NB: now() is the selftest's fixed clock
out=$(cmd_bench a "$until" "ccquota: 5-hour window at 86%"); rc=$?
eq "cmd_bench: benched until the instant + buffer" "$(( until + RESET_BUFFER ))" "$(awk -F'\t' '$1=="a"{print $2}' "$STATE_LIMITED")"
eq "cmd_bench: note recorded"                       "ccquota: 5-hour window at 86%" "$(awk -F'\t' '$1=="a"{print $3}' "$STATE_LIMITED")"
rc_is "cmd_bench: rotated the active away → exit 10" 10 "$rc"
eq "cmd_bench: new active printed"                  b "$out"
out=$(cmd_bench c "$(( $(now) - 5 ))" past); rc=$?
eq "cmd_bench: a past instant falls back to now+LIMIT_TTL" "$(( $(now) + TTL ))" "$(awk -F'\t' '$1=="c"{print $2}' "$STATE_LIMITED")"
rc_is "cmd_bench: benching a non-active account does not rotate" 0 "$rc"
rm -f "$ACCT_DIR/c.conf"; : > "$STATE_LIMITED"; rm -f "$STATE_QUOTA" "$STATE_QUOTA_TS"

# ============================================================================
# model-specific caps (issue #524): banner_reset_epoch's DATED form + the
# account.model-limited ledger — separate from the subscription bench, no rotation
# ============================================================================
# (STATE_ACTIVE / STATE_DIR / LOCK already point at the scratch tree — see the
#  cmd_mark_limited section above; only the model ledger is new here)
STATE_MODEL_LIMITED="$FLEET_C/account.model-limited"
: > "$STATE_LIMITED"; printf 'a\n' > "$STATE_ACTIVE"; rm -f "$STATE_MODEL_LIMITED"
# The weekly model cap's banner carries a DATE: "resets Sep 6 at 10pm (zone)".
# 2026-09-06 22:00 America/Los_Angeles = 1788757200 (what ccquota reports too).
FABLE_HIT="hit your Fable 5 limit · resets Sep 6 at 10pm $Z"
NOW_0902=1788381000                                     # 2026-09-02 13:30 PDT
eq "banner: dated reset (Sep 6 at 10pm)" 1788757200 "$(banner_reset_epoch "$FABLE_HIT" $NOW_0902)"
eq "banner: dated reset, host TZ ≠ zone" 1788757200 "$(TZ=Asia/Shanghai banner_reset_epoch "$FABLE_HIT" $NOW_0902)"
eq "banner: dated reset with minutes" 1788758100 \
   "$(banner_reset_epoch "hit your Fable 5 limit · resets Sep 6 at 10:15pm $Z" $NOW_0902)"
eq "banner: dated reset already past this year → next year" 1798794000 \
   "$(banner_reset_epoch "hit your Fable 5 limit · resets Jan 1 at 1am $Z" 1798747200)"
eq "banner: clock-only form still works beside the dated one" 1787462400 "$(banner_reset_epoch "$B_1020" 1787454480)"

# cmd_model_limited <label> <model> [banner] → benches (label, model) to the banner's
# reset (+RESET_BUFFER); the SUBSCRIPTION ledger and the active pointer are untouched
# — a model cap must never rotate accounts, that rotation was the cascade.
# (the ledger uses the REAL clock, so the expected instant is the parser's answer
#  for now — the parse itself is pinned above with fixed clocks)
exp=$(( $(banner_reset_epoch "$FABLE_HIT" "$(now)") + RESET_BUFFER ))
u=$(cmd_model_limited a fable "$FABLE_HIT"); rc=$?
rc_is "model-limited: rc 0" 0 "$rc"
eq "model-limited: prints the until epoch" "$exp" "$u"
eq "model-limited: (a, fable) benched to reset+buffer" "$exp" "$(acct_model_limited_until a fable)"
eq "model-limited: model match is case-insensitive"   "$exp" "$(acct_model_limited_until a Fable)"
eq "model-limited: a model id containing the alias matches" "$exp" "$(acct_model_limited_until a claude-fable-5-1)"
eq "model-limited: other model → 0"   0 "$(acct_model_limited_until a opus)"
eq "model-limited: other account → 0" 0 "$(acct_model_limited_until b fable)"
eq "model-limited: subscription ledger untouched" "" "$(cat "$STATE_LIMITED")"
eq "model-limited: active pointer untouched"      a  "$(cat "$STATE_ACTIVE")"
# no parseable reset in the banner → now + MODEL_TTL (a weekly cap: 7 days by default)
: > "$STATE_MODEL_LIMITED"
t0=$(now); u=$(cmd_model_limited b fable "reached your Fable limit. Run /usage-credits to continue or switch models with /model.")
CHECKS=$((CHECKS + 1)); [ "$u" -ge $((t0 + 604800)) ] && [ "$u" -le $((t0 + 604800 + 5)) ] \
  || fail "model-limited: no reset in banner → now+7d TTL — got $u (now $t0)"
eq "model-limited: unknown account refused" 1 "$(cmd_model_limited nobody fable x >/dev/null 2>&1; echo $?)"
# an expired row reads as 0 and is dropped on the next write
printf 'a\tfable\t%s\told\n' $(( $(now) - 10 )) > "$STATE_MODEL_LIMITED"
eq "model-limited: expired row → 0" 0 "$(acct_model_limited_until a fable)"
cmd_model_limited b opus "hit your Opus limit · resets 10:20pm $Z" >/dev/null
eq "model-limited: expired row dropped on write" 1 "$(wc -l < "$STATE_MODEL_LIMITED" | tr -d ' ')"
# model-clear
cmd_model_clear b opus
eq "model-clear: (b, opus) cleared" 0 "$(acct_model_limited_until b opus)"

printf 'selftest OK: fleet-account rotation math (%s assertions — dur/human, acct_ttl, limited/eligible, pick_active, banner reset instant, ccquota quota/bench)\n' "$CHECKS"
