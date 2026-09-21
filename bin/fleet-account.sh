#!/bin/bash
# fleet-account.sh — rotate a POOL of Claude subscription accounts so the fleet
# fails over to a fresh subscription when one hits its usage limit (the rolling
# 5-hour "session" window or the weekly cap).
#
# Why tokens, not config dirs? `CLAUDE_CONFIG_DIR` moves EVERYTHING (settings,
# hooks, transcripts) — and on macOS the subscription token lives in the
# Keychain, which CLAUDE_CONFIG_DIR does NOT override, so it can't switch
# accounts there at all. `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`)
# selects the account per-invocation on every OS while keeping ONE shared
# ~/.claude — so the fleet hooks, the collector's transcript reads, and the
# usage proxy all keep working unchanged. That is the whole design.
#
# An "account" is a file in $FLEET_ACCOUNTS_DIR whose NAME is the label and
# whose CONTENTS are that account's OAuth token (one line, chmod 600). No files
# there → multi-account is OFF and every command below is a no-op, so the fleet
# behaves exactly as a single-account install. An OPTIONAL companion conf
# "<label>.conf" (same dir) may set LIMIT_TTL=<N>[smhd] — the FALLBACK bench
# window after a usage-limit hit whose banner carries no reset time (default:
# FLEET_ACCOUNT_LIMIT_TTL).
#
# State (account-wide, like usage/ratelimit → the global/ cache dir, issue #181):
#   global/account.active   — one line: the label new sessions should use
#   global/account.limited  — label<TAB>until-epoch<TAB>banner  (one row per limited acct);
#                             until-epoch is the banner's own "resets …" instant when it
#                             carries one, else now+LIMIT_TTL (issue #490)
#   global/account.phase    — label<TAB>slot-epoch<TAB>planned-at<TAB>note  (issue #598):
#                             the 5h-window PHASE plan — the instant each idle account may
#                             OPEN its next 5h window, so the pool's windows don't all
#                             reset together. Pool-level state, hence global/ like the two
#                             above. Absent ⇒ no phase policy at all (the historic default)
#
# Commands:
#   active               — print the label new sessions should use (rotating past
#                          any account still inside its limit window); empty = off.
#                          With EVERY account benched it keeps the current one (best
#                          effort — a spawn has no better answer), so a caller that
#                          MOVES sessions must treat target == source, or a benched
#                          target, as "no move available" (fleet-migrate.sh, #567)
#   token [label]        — print the OAuth token for <label> (default: active)
#   env                  — print `CLAUDE_CODE_OAUTH_TOKEN=…` for the active acct (or nothing)
#   list                 — aligned table: label · active(●) · rotation window · state
#                          (state = ok | limited · back in ~Nm | NO TOKEN)
#   inventory [--refresh] — provider-aware local subscriptions + ccquota readings
#   choose --agent claude|codex [--exclude KEY] [--spawn] — JSON decision
#   reconcile --session S [--dry-run] — bounded per-session quota continuation
#   failover-status      — durable waiting/cutover/recovery requests (JSON)
#   use <label>          — pin <label> active
#   rotate               — advance active to the next eligible account
#   mark-limited <label> [banner]
#                        — record <label> limited until its window actually refreshes:
#                          the banner's "resets <time> (<zone>)" instant when it has one,
#                          else now + the bench duration (per-account LIMIT_TTL in
#                          <label>.conf, else FLEET_ACCOUNT_LIMIT_TTL). If it was the
#                          active one, rotate. Prints the (new) active label.
#                          Exit 10 iff this call rotated the active account away
#                          (the collector uses that to notify exactly once).
#   clear [label]        — drop the limit flag for <label> (or all)
#   limited-until <label>
#                        — epoch until which <label> is benched (0 = not benched)
#   quota [--refresh|--cached] [--json]
#                        — exact, account-wide utilization per POOL label from ccquota
#                          (issue #513): label · 5h% · 7d% · headroom% · 5h-reset ·
#                          7d-reset · %/h, one TSV row each. Cached FLEET_ACCOUNT_QUOTA_TTL s
#                          (--refresh forces; --cached never fetches). Fail-open: no
#                          ccquota / no CCQUOTA_HUB_URL / hub unreachable → no rows, exit 0.
#                          An account ccquota says it CANNOT read (available:false) gets
#                          no row either, and says why on stderr (issue #628) — never a
#                          row of zeroes, which reads as a brand-new idle subscription.
#   bench <label> <until-epoch> [reason]
#                        — bench <label> until an EXACT instant (ccquota's reset) and
#                          rotate if it was active; exit 10 iff rotated (like mark-limited)
#   migrate …            — move LIVE sessions onto the active account by close +
#                          `--resume` in a new window (issue #512): delegates to
#                          bin/fleet-migrate.sh — see its header for the selectors
#                          (<window-id>… | --limited | --idle | --all | --account L);
#                          a window already on the active account, or any window
#                          while the active account is benched itself, is skipped
#                          (#567) — only a --model relaunch is exempt
#   whoami [<window-id>] — the account a window really runs (token truth; heals a
#                          stale @cc_account stamp) — fleet-migrate.sh whoami. With
#                          NO window-id: the caller's own pane — "which account is
#                          THIS session on", the question either side of a rotation.
#                          Outside a pane of that fleet there is no "me" to report,
#                          so it says so and exits 2 rather than printing nothing
#   phase [--plan [--apply]] [--clear [label]] [--hold-until <label>]
#                        — the 5h-window PHASE stagger (issue #598). Bare: the pool's
#                          phase table (each account's live window + any pending slot).
#                          --plan computes the `5h / N` stagger for the accounts that
#                          have NO live window and prints it; --apply also writes it, and
#                          only then does anything change. --clear drops it. See
#                          phase_plan() for the grid, and pick_active() for how a pending
#                          slot is honoured (fail-open: it can never starve the pool).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"                       # FLEET_C, FLEET_CONF_DIR

ACCT_DIR="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}"
TTL="${FLEET_ACCOUNT_LIMIT_TTL:-18000}"     # how long a limited acct stays out (5h)
MODEL_TTL="${FLEET_MODEL_LIMIT_TTL:-604800}" # a per-MODEL cap with no reset in its banner (7d; #524)
RESET_BUFFER=60                             # grace past a banner-parsed reset, so an
                                            # account is not un-benched seconds early
# ANSI for the `list` table (rendered by fzf --ansi in usage-modal.sh, and by a
# terminal when run directly). Always emitted: the modal pipes us and needs the
# codes, so gating on [ -t 1 ] would strip colour exactly where it's wanted.
A_DIM=$'\033[2m'; A_RST=$'\033[0m'; A_GRN=$'\033[32m'; A_YEL=$'\033[33m'; A_RED=$'\033[31m'
# account state is machine-wide (not per-fleet) → global/ (issue #181)
STATE_DIR="$FLEET_C/global"
STATE_ACTIVE="$STATE_DIR/account.active"
STATE_LIMITED="$STATE_DIR/account.limited"
STATE_MODEL_LIMITED="$STATE_DIR/account.model-limited"   # label<TAB>model<TAB>until<TAB>banner (#524)
LOCK="$STATE_DIR/account.lock"
# ccquota-driven pre-emptive rotation (issue #513): quota cache + policy knobs.
# CEILING: bench + move sessions at/above this utilization (5h OR 7d, whichever is
# higher). WARN_PCT: message the sessions on the account first. QUOTA_TTL: how
# stale the cached ccquota answer may be before `quota` refetches (the collector
# refetches; the spawn-path `active` reads the cache only, so a slow hub never
# delays a spawn). CCQUOTA_HUB_URL (+ optional CCQUOTA_VIEWER_TOKEN) come from the
# environment / fleet.conf; ccquota itself reads them.
CEILING="${FLEET_ACCOUNT_CEILING:-85}"
WARN_PCT="${FLEET_ACCOUNT_WARN_PCT:-70}"
QUOTA_TTL="${FLEET_ACCOUNT_QUOTA_TTL:-60}"
CCQUOTA="${FLEET_QUOTA_BIN:-ccquota}"
STATE_QUOTA="$STATE_DIR/account.quota"
STATE_QUOTA_TS="$STATE_DIR/account.quota.ts"
# Consecutive EMPTY fetches: "<streak>\t<epoch the streak started>" (issue #684).
# The stamp above is the watch's LIVENESS — it says a tick RAN. This one says
# whether the tick brought anything BACK. They are different failures, and until
# #684 only the first had an alarm.
STATE_QUOTA_EMPTY="$STATE_DIR/account.quota.empty"
# --- which account a new spawn lands on (issue #598) ---------------------------
# PICK_MODE decides how the ccquota rows are RANKED once the ceiling gate has
# thrown out the accounts that are too hot to use at all:
#   5h      (default) 5h-headroom × 2 + 7d-headroom — the 5-HOUR window weighted
#           double, the weekly still counted (see the score note below).
#   minmax  the pre-#598 ranking: ccquota's own headroom_pct = 100 - max(5h, 7d).
# Why the default changed. `minmax` reads the two windows as if they were the same
# budget, and they are not: 5h capacity is USE-IT-OR-LOSE-IT — whatever a window
# does not spend evaporates at its reset and can never be recovered — while 7d
# capacity just sits there. So an account at `5h 0% · 7d 80%` scored 20 and an
# account at `5h 77% · 7d 51%` scored 23, and every spawn kept piling onto the
# second one. Live on 2026-09-13 that is exactly what happened: verky@24helpful
# went 8% → 77% of its 5h window in four hours while ly297's 5h window sat at 0%
# for the whole window and then reset — a full window of a paid subscription
# thrown away, silently, with the fleet's own rotation logic doing the throwing.
# Ranking on the 5h window puts the fresh window first; the 7d CEILING is what
# still protects the weekly budget, as a gate rather than as a score.
#
# The score is `room5 * 2 + room7` — the 5h window counts DOUBLE because it
# expires, the 7d window still counts because it gates. Not a lexicographic
# ordering: `5h 0% · 7d 84%` (216) loses to `5h 30% · 7d 0%` (240), which is the
# right call — the first account is one spawn from its weekly ceiling and would be
# benched immediately, while the second has most of a window AND a fresh week. A
# 5h-first tie-break alone would have picked the doomed one.
PICK_MODE="${FLEET_ACCOUNT_PICK:-5h}"
PICK_W5=2                                    # the expiring window's weight in the score
PICK_HYST="${FLEET_ACCOUNT_PICK_HYST:-10}"   # keep the current account while it is within
                                             # this many 5h-equivalent POINTS of the best,
                                             # so near-equal accounts don't flip-flop
# --- 5h-window phase stagger (issue #598) --------------------------------------
# PHASE=0 is the kill switch: pick_active then ignores account.phase entirely, as
# if no plan had ever been written. PHASE_AUTO is read by bin/fleet-quotawatch.sh,
# not here — it decides whether the 60s watch re-plans on its own.
PHASE_ON="${FLEET_ACCOUNT_PHASE:-1}"
PHASE_WINDOW="${FLEET_ACCOUNT_PHASE_WINDOW:-18000}"   # the rolling window being staggered (5h)
STATE_PHASE="$STATE_DIR/account.phase"

now() { date +%s; }

# Registered labels, in FLEET_ACCOUNTS order if pinned, else sorted filenames.
# Skips dotfiles and editor backups (~). Empty output ⇒ multi-account is off.
acct_labels() {
  [ -d "$ACCT_DIR" ] || return 0
  local l f
  if [ -n "${FLEET_ACCOUNTS:-}" ]; then
    # shellcheck disable=SC2086  # deliberate word-split of the space-separated list
    for l in $FLEET_ACCOUNTS; do [ -f "$ACCT_DIR/$l" ] && printf '%s\n' "$l"; done
  else
    for f in "$ACCT_DIR"/*; do
      [ -f "$f" ] || continue
      l=${f##*/}
      case "$l" in .*|*~|*.conf) continue;; esac   # .conf = per-account settings, not a token
      printf '%s\n' "$l"
    done
  fi
}

acct_token() { [ -f "$ACCT_DIR/$1" ] && sed -n '1{s/[[:space:]]*$//;p;}' "$ACCT_DIR/$1"; }

# <N>[smhd] or bare seconds → seconds (empty on garbage). Suffix must follow a digit.
dur_secs() { case "$1" in
  *[0-9]s) printf '%s' $(( ${1%s} ));;
  *[0-9]m) printf '%s' $(( ${1%m}*60 ));;
  *[0-9]h) printf '%s' $(( ${1%h}*3600 ));;
  *[0-9]d) printf '%s' $(( ${1%d}*86400 ));;
  ''|*[!0-9]*) : ;;                 # empty or non-numeric → nothing
  *) printf '%s' $(( $1 ));;        # bare seconds
esac; }
human_dur() { local s="$1"
  if   [ "$s" -ge 86400 ]; then printf '%sd' $(( s/86400 ))
  elif [ "$s" -ge 3600 ];  then printf '%sh' $(( s/3600 ))
  else printf '%sm' $(( s/60 )); fi; }

# --- the account's REAL refresh instant, read off the limit banner (issue #490) -
# The banner Claude prints when a subscription runs out already carries the
# moment the window refreshes ("… · resets 10:20pm (America/Los_Angeles)").
# Benching for a DURATION instead throws that away and is wrong in both
# directions: a limit hit partway into a 5h window benches ~2-3h past the real
# refresh (idle capacity, silent), while a weekly cap benched for 5h is released
# early and walks straight back into the same wall. So parse the instant when it
# is there, and keep LIMIT_TTL as the fallback for when it is not.
#
# STRICT by design: a wrong epoch is worse than the conservative TTL, so anything
# unexpected (no clock time, an unknown zone, a `date` that won't parse) returns
# empty and the caller falls back.

# One-shot dialect probe: BSD/macOS `date` takes -j/-f/-r, GNU takes -d. Probed
# with the harmless -j form — the GNU `-d` probe would be `date -d` on BSD, which
# is the SET-daylight-saving flag, not a parse.
DATE_BSD=0
date -j -f '%Y-%m-%d %H:%M' '2000-01-01 00:00' +%s >/dev/null 2>&1 && DATE_BSD=1

# `date` with TZ applied only when a zone was parsed. TZ="" does NOT mean "local"
# — it means UTC — so an empty zone must not reach the environment at all.
_tz_date() { local z="$1"; shift
  if [ -n "$z" ]; then TZ="$z" date "$@"; else date "$@"; fi
}
# Wall-clock date (%F) at <epoch>, as seen in <zone> (empty zone = host local).
tz_ymd() { local z="$1" e="$2"
  if [ "$DATE_BSD" = 1 ]; then _tz_date "$z" -r "$e" +%F
  else                        _tz_date "$z" -d "@$e" +%F; fi
}
# "<Y-m-d> <H:M>" read as a wall clock in <zone> → epoch (empty if unparseable).
# Seconds are spelled out: BSD `date -j` leaves any field the FORMAT omits at its
# current value, so a "%H:%M" parse silently inherits the wall clock's seconds
# (a 0-59s jitter that makes the result untestable and the bench end fuzzy).
tz_epoch() { local z="$1" ymd="$2" hm="$3"
  if [ "$DATE_BSD" = 1 ]; then _tz_date "$z" -j -f '%Y-%m-%d %H:%M:%S' "$ymd $hm:00" +%s 2>/dev/null
  else                        _tz_date "$z" -d "$ymd $hm:00" +%s 2>/dev/null; fi
}

# <banner> <now-epoch> → the epoch the account's window refreshes, or EMPTY when
# the banner doesn't carry one (caller then falls back to acct_ttl).
banner_reset_epoch() {
  local b hm h m ap zone ymd e i mon="" day="" md yr
  b=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')   # lowercase once: BSD sed has no //I
  local now_s="$2"
  # A clock time is REQUIRED. "resets monday" (the weekly banner) carries no
  # instant, so it falls back by design rather than guessing a weekday boundary.
  # DATED form (issue #524): the weekly per-model cap says "resets Sep 6 at 10pm
  # (zone)". Lift the month/day out, fold the tail back onto the clock-only grammar
  # below ("resets 10pm"), and resolve the date in the banner's zone — this year, or
  # next when that instant is already behind now (a Dec 31 banner naming Jan 1).
  md=$(printf '%s' "$b" | grep -aoE 'resets +(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]* +[0-9]{1,2},? +(at +)?[0-9]{1,2}(:[0-9]{2})? *[ap]\.?m\.?' | tail -1)
  if [ -n "$md" ]; then
    mon=$(printf '%s' "$md" | sed -nE 's/^resets +([a-z]{3})[a-z]* +.*/\1/p')
    day=$(printf '%s' "$md" | sed -nE 's/^resets +[a-z]+ +([0-9]{1,2}).*/\1/p')
    b=$(printf '%s' "$b" | sed -E 's/resets +[a-z]+ +[0-9]{1,2},? +(at +)?/resets /')
  fi
  hm=$(printf '%s' "$b" | grep -aoE 'resets +[0-9]{1,2}(:[0-9]{2})? *[ap]\.?m\.?' | tail -1)
  [ -n "$hm" ] || return 0
  h=$(printf '%s' "$hm" | sed -nE 's/^resets +([0-9]{1,2}).*/\1/p')
  m=$(printf '%s' "$hm" | sed -nE 's/^resets +[0-9]{1,2}:([0-9]{2}).*/\1/p')
  ap=$(printf '%s' "$hm" | sed -nE 's/.*([ap])\.?m\.?$/\1/p')
  [ -n "$h" ] && [ -n "$ap" ] || return 0
  h=$((10#$h)); m=$((10#${m:-0}))
  [ "$h" -ge 1 ] && [ "$h" -le 12 ] && [ "$m" -lt 60 ] || return 0
  case "$ap" in p) [ "$h" -lt 12 ] && h=$((h + 12));; a) [ "$h" -eq 12 ] && h=0;; esac
  # The zone travels WITH the banner ("(America/Los_Angeles)") and is not the
  # host's. Validate it: an unknown TZ silently resolves to UTC on both glibc and
  # macOS, which is exactly the wrong-epoch failure this must not produce.
  zone=$(printf '%s' "$1" | sed -nE 's/.*\(([A-Za-z]+\/[A-Za-z_+-]+(\/[A-Za-z_+-]+)?)\).*/\1/p' | tail -1)
  [ -z "$zone" ] || [ -f "/usr/share/zoneinfo/$zone" ] || return 0
  if [ -n "$mon" ] && [ -n "$day" ]; then
    case "$mon" in jan) mon=01;; feb) mon=02;; mar) mon=03;; apr) mon=04;; may) mon=05;; jun) mon=06;;
                   jul) mon=07;; aug) mon=08;; sep) mon=09;; oct) mon=10;; nov) mon=11;; dec) mon=12;; esac
    day=$(printf '%02d' "$((10#$day))")
    yr=$(tz_ymd "$zone" "$now_s"); yr=${yr%%-*}
    [ -n "$yr" ] || return 0
    for i in 0 1; do
      e=$(tz_epoch "$zone" "$((yr + i))-$mon-$day" "$(printf '%02d:%02d' "$h" "$m")")
      [ -n "$e" ] || return 0
      [ "$e" -gt "$now_s" ] && { printf '%s' "$e"; return 0; }
    done
    return 0
  fi
  # Today's or tomorrow's wall clock, whichever lands in the future: a banner
  # seen at 11pm saying "resets 12:30am" means tomorrow. Both candidates are
  # formatted FROM an epoch, so a DST day can't shift the answer by an hour.
  for i in 0 86400; do
    ymd=$(tz_ymd "$zone" "$((now_s + i))")
    [ -n "$ymd" ] || return 0
    e=$(tz_epoch "$zone" "$ymd" "$(printf '%02d:%02d' "$h" "$m")")
    [ -n "$e" ] || return 0
    [ "$e" -gt "$now_s" ] && { printf '%s' "$e"; return 0; }
  done
  return 0
}

# Per-account bench duration after a limit hit: LIMIT_TTL from the account's
# companion conf ($ACCT_DIR/<label>.conf), else the global FLEET_ACCOUNT_LIMIT_TTL.
# Lets tiers with different reset windows (a weekly-cap account vs a 5h-session
# one) bench for the right length instead of being un-benched too early and
# thrashing straight back into the same limit.
acct_ttl() {
  local conf="$ACCT_DIR/$1.conf" v s
  if [ -f "$conf" ]; then
    v=$(sed -n 's/^[[:space:]]*LIMIT_TTL[[:space:]]*=[[:space:]]*//p' "$conf" | head -1 | tr -d '[:space:]')
    s=$(dur_secs "$v"); [ -n "$s" ] && [ "$s" -gt 0 ] && { printf '%s' "$s"; return; }
  fi
  printf '%s' "$TTL"
}

# Epoch until which <label> is limited (0 if not limited or already expired).
acct_limited_until() {
  [ -f "$STATE_LIMITED" ] || { echo 0; return; }
  awk -F'\t' -v l="$1" -v now="$(now)" '
    $1==l && ($2+0)>now && ($2+0)>u { u=$2+0 } END { print u+0 }' "$STATE_LIMITED"
}
acct_eligible() { [ "$(acct_limited_until "$1")" -le "$(now)" ]; }

# --- ccquota: exact, account-wide utilization (issue #513) ----------------------
# ccquota — the binary from TokenLedger (https://github.com/verkyyi/tokenledger)
# — knows every subscription's 5-hour
# and 7-day utilization + reset instants, account-wide, across devices — the
# number the limit banner is the LAST symptom of. Reading it lets the fleet
# rotate BEFORE a session is walled, instead of after one prints a banner.
#
# quota_parse: ccquota's `budget --account all --json` on stdin → one TSV row per
# POOL label:  label  5h%  7d%  headroom%  5h-reset-epoch  7d-reset-epoch  %/h
# Label ↔ account: ccquota's name for the account (`ccquota name`) equals the
# fleet label, or the label's companion <label>.conf pins CCQUOTA_ACCOUNT=<uuid>.
# Accounts ccquota knows but the pool doesn't (and vice versa) are simply absent.
# %/h is the 5h window's burn rate when ccquota reports one (else 0). Pure
# (python3 + stdin), so the selftest pins it on a fixture.
#
# NO ROW is the only honest answer for an account we have no reading for (issue
# #628), and it is the SAME word the pool already uses for "ccquota has never
# heard of this label": every consumer treats a missing row as no opinion —
# pick_best skips it, `list` prints no quota columns, the quotawatch policy loop
# never sees it, and (since #628) quota_move_target refuses it as a landing spot.
# The two ways a reading goes missing, both of which used to become `0`:
#   available:false — TokenLedger SAYS SO (cmd/ccquota/budget.go flatten: it sets
#     available+reason, then returns early, so headroom_pct stays at its 0 value
#     and both omitempty windows vanish from the JSON). Publishing a row here
#     printed `label 0 0 0 …` — 0% used AND 0% headroom — which reads to the
#     rotation as a brand-new idle subscription: never benched, and the FIRST
#     account a ceiling fan-out would move N sessions onto.
#   neither window present — a payload shape this parser does not understand.
#     That one is loud (stderr + a RED `quota` line in fleet-doctor.sh), because
#     it means ccquota and the fleet have drifted apart, not that an account is
#     unreadable today.
# Both diagnostics go to stderr, which quota_fetch lets through: the quotawatch
# tick logs them (deduped, see fleet-quotawatch.sh) and `quota --refresh` hands
# them to the doctor. Silence here is what made this a 2026-09-11-shaped bug.
quota_parse() {
  local map="" l conf u
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    conf="$ACCT_DIR/$l.conf"; u=""
    [ -f "$conf" ] && u=$(sed -n 's/^[[:space:]]*CCQUOTA_ACCOUNT[[:space:]]*=[[:space:]]*//p' "$conf" | head -1 | tr -d '[:space:]"')
    map="${map}${l}"$'\t'"${u}"$'\n'
  done <<EOF
$(acct_labels)
EOF
  # the JSON rides the environment: `python3 -` takes its PROGRAM from stdin
  local js; js=$(cat)
  QP_MAP="$map" QP_JSON="$js" python3 - <<'PY'
import json, os, sys, datetime
try:
    d = json.loads(os.environ.get("QP_JSON", ""))
except Exception:
    sys.exit(0)
accts = d.get("accounts") or []
if not accts or d.get("verdict") == "unknown":
    sys.exit(0)
def diag(fmt, *a):
    sys.stderr.write(("fleet-account: ccquota " + fmt + "\n") % a)
def num(v):
    """A utilization/headroom as a number, or None when it is absent or not one.
    None is 'no reading' — never 0: see the header. A non-numeric value is the
    same unknown (and falls into the shape complaint below) rather than an
    exception that would drop EVERY account's row."""
    if v is None or isinstance(v, bool): return None
    try: return float(v)
    except (TypeError, ValueError): return None
def ep(v):
    """Reset instant → epoch seconds. `budget --json` states it as RFC3339
    (cmd/ccquota/budget.go: resets_at is a *time.Time) — that is the shape this
    parser is pinned to. The stamp API in the same binary (stamp.go) uses unix
    seconds instead, and feeding one of those in used to except into 0, which
    silently flattened every fleet_same_window comparison; accept both."""
    if v is None or v == "" or isinstance(v, bool): return 0
    if isinstance(v, (int, float)): return int(v)
    try:
        return int(datetime.datetime.fromisoformat(str(v).replace("Z", "+00:00")).timestamp())
    except Exception:
        return 0
by_uuid = {a.get("account_uuid"): a for a in accts}
by_label = {a.get("label"): a for a in accts}
for line in os.environ.get("QP_MAP", "").splitlines():
    if not line.strip(): continue
    label, _, uuid = line.partition("\t")
    a = by_uuid.get(uuid) if uuid else by_label.get(label)
    if not a: continue
    av = a.get("available")
    if av is not None and not av:                      # TokenLedger: "I cannot read this one"
        why = a.get("reason") or "no reason given"
        diag("has no reading for %s (available=false, reason: %s) — no row: "
             "not a rotation candidate, not a migrate target", label, why)
        continue
    fh, sd = a.get("five_hour") or {}, a.get("seven_day") or {}
    u5, u7 = num(fh.get("utilization")), num(sd.get("utilization"))
    if u5 is None and u7 is None:                      # neither window — shape we don't know
        diag("payload shape not recognized for %s: available is not false, yet "
             "neither five_hour nor seven_day carries a utilization — no row "
             "(is ccquota newer than this fleet?)", label)
        continue
    # One window missing while the other is real IS a reading: every consumer
    # ranks on max(5h, 7d), so a 0 for the absent one simply never wins.
    u5 = 0 if u5 is None else u5; u7 = 0 if u7 is None else u7
    room = num(a.get("headroom_pct")); room = 100 - max(u5, u7) if room is None else room
    print("%s\t%d\t%d\t%d\t%d\t%d\t%d" % (label, round(u5), round(u7), round(room),
          ep(fh.get("resets_at")), ep(sd.get("resets_at")), round(num(fh.get("percent_per_hour")) or 0)))
PY
}
# quota_empty_streak <rows> — maintain the consecutive-EMPTY-fetch counter, which
# is the only reading anything has of the BLIND axis (issue #684). The stamp is
# refreshed unconditionally by design (see quota_fetch), so a hub that answers
# with nothing leaves a cache that is FRESH and EMPTY — a state every alarm keyed
# on the stamp's age reads as healthy. Live on 2026-09-15 it held for at least six
# minutes with `--status` printing `fresh 117`, fleet-doctor PASSing its qwatch
# line, and the 70%/85% pre-emptive rotation quietly doing nothing, because zero
# rows is also exactly what "no pool" looks like to every consumer downstream.
#   rows      ⇒ 0 (and the stamp of the streak's start cleared with it)
#   no rows   ⇒ +1, keeping the epoch the streak started so the alarm can say
#               how LONG it has lasted, not just how many reads it took.
# An EMPTY POOL is NOT blind: with no token files there is nothing for ccquota to
# have a reading about, and the fleet says that elsewhere already (fleet-doctor's
# `account` line). Counting it here would pin `⚠ quota blind` permanently on
# every machine that sets a hub URL before it has any accounts — an alarm that is
# on by default on a healthy install is one nobody reads by the second week.
quota_empty_streak() {
  local rows="$1" prev n since
  mkdir -p "$STATE_DIR"
  if printf '%s' "$rows" | grep -q . || [ -z "$(acct_labels)" ]; then
    printf '0\t0\n' | atomic_write "$STATE_QUOTA_EMPTY"; return 0
  fi
  prev=$(cat "$STATE_QUOTA_EMPTY" 2>/dev/null || true)
  n=${prev%%$'\t'*}; since=0
  case "$prev" in *$'\t'*) since=${prev#*$'\t'} ;; esac
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  if [ "$n" -le 0 ] || [ "$since" -le 0 ]; then since=$(now); fi
  printf '%s\t%s\n' "$(( n + 1 ))" "$since" | atomic_write "$STATE_QUOTA_EMPTY"
}
# quota_fetch — ask ccquota (10s cap) and rewrite the cache; silent no-op without
# ccquota / a hub URL. Empty rows (unknown verdict, unreachable) still refresh the
# stamp so a dead hub is retried at TTL cadence, not on every call. ccquota's own
# stderr is dropped, quota_parse's is NOT: its no-reading / bad-shape complaints
# (issue #628) are the only place the chain speaks up, and the stamp below says
# nothing about them — it is refreshed unconditionally, which is exactly why
# #551's `⚠ quota stale` can never catch a cache full of confident zeroes.
# quota_empty_streak is the axis that does (issue #684); it runs on EVERY fetch,
# including the ones that succeed, because the clear-on-success half is what keeps
# the alarm off a hub that merely blinked.
quota_fetch() {
  command -v "$CCQUOTA" >/dev/null 2>&1 || return 0
  [ -n "${CCQUOTA_HUB_URL:-}" ] || return 0
  local rows raw
  raw=$("$CCQUOTA" budget --account all --json --timeout 10s 2>/dev/null)
  rows=$(printf '%s' "$raw" | quota_parse)
  mkdir -p "$STATE_DIR"
  printf '%s' "$raw" | atomic_write "$STATE_DIR/account.quota.json"
  printf '%s' "$rows" | atomic_write "$STATE_QUOTA"
  now | atomic_write "$STATE_QUOTA_TS"
  quota_empty_streak "$rows"
}

# Metadata-only adapter for the provider-aware selector. Keep Claude's scores,
# phase preference, model fallback and benches in their existing policy owner.
cmd_claude_inventory() {
  local rows ts fresh=0 l conf uuid used score u5 u7 r5 r7 reset token model_ok until fallback
  rows=$(quota_rows "$([ "${1:-}" = --refresh ] && printf refresh || :)")
  ts=$(cat "$STATE_QUOTA_TS" 2>/dev/null || echo 0)
  case "$ts" in ''|*[!0-9]*) ts=0;; esac
  [ "$ts" -le "$(now)" ] && [ $(( $(now) - ts )) -lt "$QUOTA_TTL" ] && fresh=1
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    conf="$ACCT_DIR/$l.conf"; uuid=""
    [ -f "$conf" ] && uuid=$(sed -n 's/^[[:space:]]*CCQUOTA_ACCOUNT[[:space:]]*=[[:space:]]*//p' "$conf" | head -1 | tr -d '[:space:]"')
    if [ -z "$uuid" ] && [ -f "$STATE_DIR/account.quota.json" ]; then
      uuid=$(python3 - "$STATE_DIR/account.quota.json" "$l" <<'PY'
import json, sys
try:
    rows = json.load(open(sys.argv[1])).get('accounts', [])
    match = [a.get('account_uuid', '') for a in rows if a.get('label') == sys.argv[2]]
    if len(match) == 1: print(match[0])
except (OSError, ValueError, AttributeError): pass
PY
)
    fi
    u5=$(quota_field "$rows" "$l" 2); u7=$(quota_field "$rows" "$l" 3); used=""; reset=0
    if [ -n "$u5" ]; then
      used=$u5; [ "${u7:-0}" -gt "$used" ] && used=$u7
      r5=$(quota_field "$rows" "$l" 5); r7=$(quota_field "$rows" "$l" 6)
      [ "$u5" -ge "$CEILING" ] && [ "${r5:-0}" -gt "$reset" ] && reset=$r5
      [ "${u7:-0}" -ge "$CEILING" ] && [ "${r7:-0}" -gt "$reset" ] && reset=$r7
    fi
    score=$(pick_score "$rows" "$l"); token=0
    [ -n "$(acct_token "$l")" ] && token=1
    model_ok=1; until=$(acct_model_limited_until "$l" "${FLEET_MODEL:-opus}")
    if [ "$until" -gt "$(now)" ]; then
      fallback="${FLEET_MODEL_FALLBACK-opus}"
      if [ -z "$fallback" ] || [ "$fallback" = "${FLEET_MODEL:-opus}" ] \
        || [ "$(acct_model_limited_until "$l" "$fallback")" -gt "$(now)" ]; then model_ok=0; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$l" "$uuid" "$used" "$score" \
      "$(acct_limited_until "$l")" "$(acct_phase_hold "$l")" "$reset" "$fresh" "$token" "$model_ok"
  done <<EOF
$(acct_labels)
EOF
}

account_adapter() {
  local adapter_session
  adapter_session=$(fleet_current_session 2>/dev/null)
  if [ -n "${FLEET_LAUNCH_SESSION:-}" ] && [ "$adapter_session" = "${FLEET_LAUNCH_SESSION}-pool" ]; then
    adapter_session="$FLEET_LAUNCH_SESSION"
  fi
  [ -z "$adapter_session" ] || fleet_load_conf "$adapter_session" || return 1
  export FLEET_C FLEET_CONF_DIR FLEET_ACCOUNTS_DIR FLEET_QUOTA_BIN
  export CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_MODEL FLEET_MODEL_FALLBACK
  export FLEET_FAILOVER FLEET_FAILOVER_AGENTS FLEET_ACCOUNT_QUOTA_TTL
  export FLEET_CODEX_ACCOUNTS FLEET_CODEX_HOME FLEET_CODEX_MODEL FLEET_CODEX_SERVER
  export FLEET_CODEX_MODEL_LIMIT_IDS FLEET_CODEX_MODEL_FALLBACK
  exec python3 "$BIN/.fleet-account.py" "$@"
}

account_reconcile() {
  local previous='' arg sess=''
  for arg in "$@"; do
    [ "$previous" != --session ] || sess="$arg"
    previous="$arg"
  done
  [ -z "$sess" ] || fleet_load_conf "$sess" || return 1
  export FLEET_C FLEET_CONF_DIR FLEET_ACCOUNTS_DIR FLEET_QUOTA_BIN
  export CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_MODEL FLEET_MODEL_FALLBACK
  export FLEET_FAILOVER FLEET_FAILOVER_AGENTS FLEET_CODEX_SERVER
  export FLEET_CODEX_ACCOUNTS FLEET_CODEX_HOME FLEET_CODEX_MODEL
  export FLEET_CODEX_MODEL_LIMIT_IDS FLEET_CODEX_MODEL_FALLBACK
  export FLEET_SLEEP_MCP_RESTARTABLE FLEET_ACCOUNT_CEILING FLEET_ACCOUNT_QUOTA_TTL FLEET_SLEEP
  exec python3 "$BIN/.fleet-failover.py" "$@"
}
# quota_rows [cached|refresh] — the TSV rows; default = cache if fresh else fetch.
quota_rows() {
  local mode="${1:-}" ts
  if [ "$mode" != cached ]; then
    ts=$(cat "$STATE_QUOTA_TS" 2>/dev/null || echo 0)
    if [ "$mode" = refresh ] || [ $(( $(now) - ts )) -ge "$QUOTA_TTL" ]; then quota_fetch; fi
  fi
  [ -f "$STATE_QUOTA" ] && cat "$STATE_QUOTA"
  return 0
}
# quota_field <rows> <label> <col> — one cell (cols: 2=5h 3=7d 4=headroom 5=5h-reset 6=7d-reset 7=%/h)
quota_field() { printf '%s\n' "$1" | awk -F'\t' -v l="$2" -v c="$3" '$1==l{print $c; exit}'; }
cmd_quota() {
  local mode="" json=0 a
  for a in "$@"; do case "$a" in --refresh) mode=refresh;; --cached) mode=cached;; --json) json=1;; esac; done
  if [ "$json" = 1 ]; then
    command -v "$CCQUOTA" >/dev/null 2>&1 && [ -n "${CCQUOTA_HUB_URL:-}" ] && "$CCQUOTA" budget --account all --json --timeout 10s 2>/dev/null
    return 0
  fi
  quota_rows "$mode"
}

# --- 5h-window PHASE stagger (issue #598) --------------------------------------
# Epoch before which <label> should not OPEN a new 5h window (0 = free to use).
# Self-expiring exactly like acct_limited_until: a slot in the past is no hold at
# all, so a stale plan decays into a no-op instead of benching the pool forever.
# Pure awk + one state file — this is on the spawn path.
acct_phase_hold() {
  [ "$PHASE_ON" = 0 ] && { echo 0; return; }
  [ -f "$STATE_PHASE" ] || { echo 0; return; }
  awk -F'\t' -v l="$1" -v now="$(now)" '
    $1==l && ($2+0)>now && ($2+0)>u { u=$2+0 } END { print u+0 }' "$STATE_PHASE"
}

# pick_score <rows> <label> → how good this account is for a NEW session (higher
# wins), or EMPTY when ccquota has no row for it (⇒ no opinion, not a candidate).
# See PICK_MODE above for why 5h headroom is the primary key.
pick_score() {
  local rows="$1" l="$2" u5 u7 m
  u5=$(quota_field "$rows" "$l" 2); u7=$(quota_field "$rows" "$l" 3)
  [ -n "$u5" ] && [ -n "$u7" ] || return 0
  case "$PICK_MODE" in
    minmax) m=$u5; [ "$u7" -gt "$m" ] && m=$u7; printf '%s' $(( (100 - m) * PICK_W5 )) ;;
    *)      printf '%s' $(( (100 - u5) * PICK_W5 + (100 - u7) )) ;;
  esac
}

# pick_best <rows> <cur> <honour-holds> → the winning label, or EMPTY when there
# is no candidate at all. A candidate is ELIGIBLE (un-benched), known to ccquota,
# and under the CEILING on both windows; with honour-holds=1 a pending phase slot
# also disqualifies it. The current account is KEPT while it is within PICK_HYST
# points of the best, so near-equal accounts don't flip-flop between spawns.
pick_best() {
  local rows="$1" cur="$2" holds="$3" best="" bestsc=-1 cursc=-1 l sc u5 u7 util
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    acct_eligible "$l" || continue
    [ "$holds" = 1 ] && [ "$(acct_phase_hold "$l")" -gt "$(now)" ] && continue
    u5=$(quota_field "$rows" "$l" 2); u7=$(quota_field "$rows" "$l" 3)
    [ -n "$u5" ] || continue                          # not in ccquota → no opinion
    util=$u5; [ "$u7" -gt "$util" ] && util=$u7
    [ "$util" -ge "$CEILING" ] && continue            # at the ceiling → not a candidate
    sc=$(pick_score "$rows" "$l")
    [ -n "$sc" ] || continue
    [ "$l" = "$cur" ] && cursc=$sc
    [ "$sc" -gt "$bestsc" ] && { best=$l; bestsc=$sc; }
  done <<EOF
$(acct_labels)
EOF
  [ -n "$best" ] || return 0
  if [ "$cursc" -ge 0 ] && [ $(( bestsc - cursc )) -le $(( PICK_HYST * PICK_W5 )) ]
  then printf '%s' "$cur"; else printf '%s' "$best"; fi
}

# Choose the account new sessions should use, starting from $1 (the current
# active). With ccquota rows (issue #513): the best-ranked eligible account under
# the ceiling wins (pick_best above). Two passes: the first honours the phase plan,
# the second ignores it — a phase hold is a PREFERENCE about when to open a window
# and must never be the reason a spawn has no account to run on (issue #598).
# Without rows (or with every account at the ceiling): keep the current one if
# eligible; else the next eligible one round-robin; if ALL are limited, keep the
# current (best effort) so sessions still launch. Reads the quota CACHE only —
# this runs on the spawn path.
pick_active() {
  local cur="$1" rows best
  rows=$(quota_rows cached)
  if [ -n "$rows" ]; then
    best=$(pick_best "$rows" "$cur" 1)
    [ -n "$best" ] || best=$(pick_best "$rows" "$cur" 0)
    [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  fi
  pick_active_rr "$cur"
}
pick_active_rr() {
  local cur="$1" i n start from idx
  local L=()
  while IFS= read -r l; do [ -n "$l" ] && L+=("$l"); done <<EOF
$(acct_labels)
EOF
  n=${#L[@]}; [ "$n" -eq 0 ] && return 0
  start=-1
  for ((i=0; i<n; i++)); do [ "${L[$i]}" = "$cur" ] && { start=$i; break; }; done
  if [ "$start" -ge 0 ] && acct_eligible "$cur"; then printf '%s' "$cur"; return 0; fi
  from=$(( start<0 ? 0 : start+1 ))
  for ((i=0; i<n; i++)); do
    idx=$(( (from+i) % n ))
    acct_eligible "${L[$idx]}" && { printf '%s' "${L[$idx]}"; return 0; }
  done
  if [ "$start" -ge 0 ]; then printf '%s' "$cur"; else printf '%s' "${L[0]}"; fi
}

acct_lock() { local t=0; while ! mkdir "$LOCK" 2>/dev/null; do t=$((t+1)); [ "$t" -gt 50 ] && return 0; sleep 0.1; done; }
acct_unlock() { rmdir "$LOCK" 2>/dev/null || true; }
atomic_write() { local f="$1" tmp="$1.$$"; cat > "$tmp" && mv "$tmp" "$f"; }

# Resolve + persist the active label. Single owner of $STATE_ACTIVE.
cmd_active() {
  local labels cur nxt
  labels=$(acct_labels); [ -z "$labels" ] && return 0        # off → nothing
  mkdir -p "$STATE_DIR"
  cur=$(sed -n '1p' "$STATE_ACTIVE" 2>/dev/null || true)
  nxt=$(pick_active "$cur")
  [ -z "$nxt" ] && return 0
  if [ "$nxt" != "$cur" ]; then acct_lock; printf '%s\n' "$nxt" | atomic_write "$STATE_ACTIVE"; acct_unlock; fi
  printf '%s' "$nxt"
}

cmd_token() { local l="${1:-$(cmd_active)}"; [ -n "$l" ] && acct_token "$l"; }

cmd_env() {
  local l t; l=$(cmd_active); [ -z "$l" ] && return 0
  t=$(acct_token "$l"); [ -n "$t" ] && printf 'CLAUDE_CODE_OAUTH_TOKEN=%s' "$t"
}

cmd_use() {
  local l="$1"; acct_labels | grep -qx "$l" || { echo "use: unknown account '$l'" >&2; return 1; }
  mkdir -p "$STATE_DIR"; acct_lock; printf '%s\n' "$l" | atomic_write "$STATE_ACTIVE"; acct_unlock
  printf '%s' "$l"
}

cmd_rotate() {
  local cur nxt; cur=$(sed -n '1p' "$STATE_ACTIVE" 2>/dev/null || true)
  # rotate = pick starting AFTER cur even if cur is currently eligible
  local L=() i n idx
  while IFS= read -r l; do [ -n "$l" ] && L+=("$l"); done <<EOF
$(acct_labels)
EOF
  n=${#L[@]}; [ "$n" -eq 0 ] && return 0
  local start=-1; for ((i=0;i<n;i++)); do [ "${L[$i]}" = "$cur" ] && { start=$i; break; }; done
  for ((i=1;i<=n;i++)); do
    idx=$(( (start+i) % n ))
    acct_eligible "${L[$idx]}" && { nxt="${L[$idx]}"; break; }
  done
  nxt="${nxt:-$cur}"
  mkdir -p "$STATE_DIR"; acct_lock; printf '%s\n' "$nxt" | atomic_write "$STATE_ACTIVE"; acct_unlock
  printf '%s' "$nxt"
}

cmd_mark_limited() {
  local label="$1" banner="${2:-}" until
  [ -n "$label" ] || { echo "mark-limited: usage: mark-limited <label> [banner]" >&2; return 1; }
  acct_labels | grep -qx "$label" || { echo "mark-limited: unknown account '$label'" >&2; return 1; }
  # Bench until the account's REAL refresh instant when the banner carries one
  # (issue #490); LIMIT_TTL is the fallback for banners that do not.
  until=$(banner_reset_epoch "$banner" "$(now)")
  if [ -n "$until" ]; then until=$(( until + RESET_BUFFER ))
  else                    until=$(( $(now) + $(acct_ttl "$label") )); fi
  bench_write "$label" "$until" "$banner"
}
# bench <label> <until-epoch> [reason] — the pre-emptive form (issue #513): the
# collector benches an account at the ccquota ceiling until ccquota's own reset
# instant, before any banner exists. A bogus/past epoch falls back to LIMIT_TTL.
cmd_bench() {
  local label="$1" until="${2:-}" reason="${3:-ccquota ceiling}"
  [ -n "$label" ] || { echo "bench: usage: bench <label> <until-epoch> [reason]" >&2; return 1; }
  acct_labels | grep -qx "$label" || { echo "bench: unknown account '$label'" >&2; return 1; }
  case "$until" in ''|*[!0-9]*) until=0;; esac
  if [ "$until" -gt "$(now)" ]; then until=$(( until + RESET_BUFFER ))
  else                               until=$(( $(now) + $(acct_ttl "$label") )); fi
  bench_write "$label" "$until" "$reason"
}
# bench_write <label> <until-epoch> <note> — record the bench row, rotate the
# active pointer past it if needed. Exit 10 iff this call rotated the active away.
bench_write() {
  local label="$1" until="$2" banner="$3" cur nxt rotated=0
  mkdir -p "$STATE_DIR"; acct_lock
  # Rewrite: drop this label's old row + any expired rows, then add the fresh one.
  { [ -f "$STATE_LIMITED" ] && awk -F'\t' -v l="$label" -v now="$(now)" '$1!=l && ($2+0)>now' "$STATE_LIMITED"
    printf '%s\t%s\t%s\n' "$label" "$until" "$banner"; } | atomic_write "$STATE_LIMITED"
  cur=$(sed -n '1p' "$STATE_ACTIVE" 2>/dev/null || true)
  if [ -z "$cur" ] || [ "$cur" = "$label" ]; then
    nxt=$(pick_active "$label")
    printf '%s\n' "$nxt" | atomic_write "$STATE_ACTIVE"
    [ -n "$cur" ] && [ "$nxt" != "$cur" ] && rotated=1
  else
    nxt="$cur"
  fi
  acct_unlock
  printf '%s' "$nxt"
  [ "$rotated" = 1 ] && return 10
  return 0
}

cmd_clear() {
  local label="${1:-}"
  [ -f "$STATE_LIMITED" ] || return 0
  acct_lock
  if [ -z "$label" ]; then
    : | atomic_write "$STATE_LIMITED"
  else
    awk -F'\t' -v l="$label" '$1!=l' "$STATE_LIMITED" | atomic_write "$STATE_LIMITED"
  fi
  acct_unlock
}

# --- per-MODEL caps (issue #524) --------------------------------------------------
# "You've hit your Fable 5 limit · resets Sep 6 …" is a different wall from the
# subscription's: the account keeps its 5h/7d headroom for every other model. So it
# is recorded HERE, per (account, model), and never touches account.limited or the
# active pointer — benching + rotating on it moved every session onto an account
# with the same cap (the 2026-09-02 cascade). Readers: fleet-claude.sh (launch on
# FLEET_MODEL_FALLBACK while the cap holds) and the collector (relaunch the walled
# window). <model> is FLEET_MODEL's alias grammar (fable/opus/…), lowercased; the
# lookup matches an alias against a full model id either way (fable ~ claude-fable-5-1).
cmd_model_limited() {   # <label> <model> [banner] → prints the until-epoch
  local label="$1" model="${2:-}" banner="${3:-}" until
  [ -n "$label" ] && [ -n "$model" ] || { echo "model-limited: usage: model-limited <label> <model> [banner]" >&2; return 1; }
  acct_labels | grep -qx "$label" || { echo "model-limited: unknown account '$label'" >&2; return 1; }
  model=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
  until=$(banner_reset_epoch "$banner" "$(now)")
  if [ -n "$until" ]; then until=$(( until + RESET_BUFFER ))
  else                    until=$(( $(now) + MODEL_TTL )); fi
  mkdir -p "$STATE_DIR"; acct_lock
  { [ -f "$STATE_MODEL_LIMITED" ] && awk -F'\t' -v l="$label" -v m="$model" -v now="$(now)" '!($1==l && $2==m) && ($3+0)>now' "$STATE_MODEL_LIMITED"
    printf '%s\t%s\t%s\t%s\n' "$label" "$model" "$until" "$banner"; } | atomic_write "$STATE_MODEL_LIMITED"
  acct_unlock
  printf '%s' "$until"
}
acct_model_limited_until() {   # <label> <model|model-id> → epoch, 0 = not capped
  local m fleet_model_until=0; m=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
  [ -f "$STATE_MODEL_LIMITED" ] && [ -n "$m" ] || { echo 0; return; }
  fleet_model_limited_until "$STATE_MODEL_LIMITED" "${1:-}" "$m" "$(now)"
  printf '%s\n' "$fleet_model_until"
}
cmd_model_clear() {   # [label [model]] — no args clears everything
  [ -f "$STATE_MODEL_LIMITED" ] || return 0
  acct_lock
  if [ -z "${1:-}" ]; then : | atomic_write "$STATE_MODEL_LIMITED"
  else awk -F'\t' -v l="$1" -v m="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')" '!($1==l && (m=="" || $2==m))' "$STATE_MODEL_LIMITED" | atomic_write "$STATE_MODEL_LIMITED"; fi
  acct_unlock
}

# --- the phase plan (issue #598) ------------------------------------------------
# N subscriptions first used at around the same time have their 5-hour windows in
# the SAME PHASE: they burn down together and reset together, so the pool's total
# available headroom is a sawtooth whose trough is a full outage. Staggering the
# phases by `5h / N` flattens that sawtooth into a line — at any instant some
# account is early in its window.
#
# A 5h window's phase is NOT settable: the window opens when the account is first
# used and runs 5 hours from there. So the only lever is WHEN each account is
# first used, and the plan is therefore a queue of START SLOTS, not a rotation.
#
# phase_plan <rows> [now] → one TSV row per account IN the plan:
#   label  slot-epoch  k  state
#     running — a 5h window is already open on it. Its phase is a fact, not a
#               choice, so slot-epoch is that window's real START and it is never
#               held ("已在跑的 window 不受影响").
#     queued  — no live window: it owns grid index k and should not open one
#               before slot-epoch.
#     missed  — its grid point already went by this window. Reported so the plan
#               is readable, but NEVER held: see below.
# Accounts that are BENCHED, or that ccquota has no row for, are absent from the
# plan entirely ("被 bench 的账号不参与排相位") — no row, so no hold either.
#
# The grid. N = accounts in the plan, step = PHASE_WINDOW / N. The ring is
# anchored on the EARLIEST live window start, so the accounts already running keep
# their real phase and the idle ones are placed relative to them; with nothing
# running the anchor is `now` — which is the issue's own example: 3 accounts,
# step 100 min, slots at T+0 / T+100m / T+200m. Each running account claims the
# grid index nearest its real start; the queued ones take the lowest FREE indices
# in label order.
#
# A grid point that ALREADY WENT BY is not pushed into the next window — the
# account is released at once (state `missed`). Waiting costs up to a full window
# of a paid subscription, and buying a textbook phase with a window nobody spends
# is the exact loss this whole issue is about. Verified against the live pool on
# 2026-09-13: anchored on the account already running, the idle account's grid
# point had gone by 90 minutes earlier, and projecting forward would have held it
# out until 00:30 — parking its live, completely unused 5h window until the window
# itself expired. One cycle of imperfect phase is the cheaper mistake, and the
# next re-plan re-grids it anyway.
#
# Window start comes from ccquota, never from a local guess: `five_hour.resets_at
# - 5h`. ccquota reports a resets_at even for an account with NO live window (it
# is the next boundary, not a window), so `utilization > 0` is what says a window
# is really open — read that, not the timestamp alone.
#
# python3 for the arithmetic (like quota_parse); the SPAWN path never comes here —
# it only reads the written plan, in awk, via acct_phase_hold.
phase_plan() {
  local rows="$1" now_s="${2:-$(now)}" map="" l elig
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    elig=0; acct_eligible "$l" && elig=1
    map="${map}${l}"$'\t'"${elig}"$'\n'
  done <<EOF
$(acct_labels)
EOF
  PP_MAP="$map" PP_ROWS="$rows" PP_NOW="$now_s" PP_W="$PHASE_WINDOW" python3 - <<'PY'
import os, sys
try:
    W = int(os.environ.get("PP_W") or 18000)
    now = int(os.environ.get("PP_NOW") or 0)
except ValueError:
    sys.exit(0)
if W <= 0:
    sys.exit(0)
rows = {}
for line in os.environ.get("PP_ROWS", "").splitlines():
    c = line.split("\t")
    if len(c) < 7:
        continue
    rows[c[0]] = c
plan = []
for line in os.environ.get("PP_MAP", "").splitlines():
    if not line.strip():
        continue
    label, _, e = line.partition("\t")
    if e.strip() != "1":                 # benched → not in the plan
        continue
    if label not in rows:                # ccquota has no opinion → not in the plan
        continue
    plan.append(label)
if not plan:
    sys.exit(0)
def num(v):
    try:    return int(v)
    except (TypeError, ValueError): return 0
running, queued = [], []
for l in plan:
    u5, r5 = num(rows[l][1]), num(rows[l][4])
    if u5 > 0 and r5 > now: running.append((l, r5 - W))
    else:                   queued.append(l)
N = len(plan)
step = max(1, W // N)
anchor = min(st for _, st in running) if running else now
claimed = {}
for l, st in sorted(running, key=lambda p: p[1]):
    k = int(round((((st - anchor) % W) / step))) % N
    while k in claimed:                  # two live windows inside one step
        k = (k + 1) % N
    claimed[k] = l
out = {}
for k, l in claimed.items():
    out[l] = (dict(running)[l], k, "running")
free = [k for k in range(N) if k not in claimed]
for l, k in zip(queued, free):
    t = anchor + k * step
    # that grid point already went by: release now rather than park a live window
    out[l] = (t, k, "queued") if t >= now else (now, k, "missed")
for l in plan:
    if l in out:
        t, k, st = out[l]
        print("%s\t%d\t%d\t%s" % (l, t, k, st))
PY
}

# phase_write <plan> — persist the rows that are actually a WAIT as holds. A
# `running` row is a fact about a window already open and a `missed` row is an
# account that should start now, so neither is written: holding either one would
# bench live capacity for nothing. A queued slot that is already due is likewise
# no hold, so it is not written either.
phase_write() {
  mkdir -p "$STATE_DIR"; acct_lock
  printf '%s\n' "$1" | awk -F'\t' -v now="$(now)" '
    $4=="queued" && ($2+0)>now { printf "%s\t%s\t%s\tphase slot %s (issue #598)\n", $1, $2, now, $3 }' \
    | atomic_write "$STATE_PHASE"
  acct_unlock
}

# phase: show | --plan [--apply] | --clear [label] | --hold-until <label>
cmd_phase() {
  local mode=show apply=0 label="" a plan rows l slot k st hold now_s u5
  for a in "$@"; do
    case "$a" in
      --plan)       mode=plan ;;
      --apply)      apply=1 ;;
      --clear)      mode=clear ;;
      --hold-until) mode=hold ;;
      -*) printf 'phase: unknown flag %s (--plan [--apply] | --clear [label] | --hold-until <label>)\n' "$a" >&2; return 2 ;;
      *)  label="$a" ;;
    esac
  done
  [ -n "$(acct_labels)" ] || { printf 'multi-account: OFF (no token files in %s)\n' "$ACCT_DIR"; return 0; }
  now_s=$(now)
  case "$mode" in
    hold)
      [ -n "$label" ] || { echo "phase --hold-until: usage: phase --hold-until <label>" >&2; return 1; }
      acct_phase_hold "$label"; return 0 ;;
    clear)
      [ -f "$STATE_PHASE" ] || return 0
      acct_lock
      if [ -z "$label" ]; then : | atomic_write "$STATE_PHASE"
      else awk -F'\t' -v l="$label" '$1!=l' "$STATE_PHASE" | atomic_write "$STATE_PHASE"; fi
      acct_unlock; return 0 ;;
    plan)
      rows=$(quota_rows)
      [ -n "$rows" ] || { echo "phase: no ccquota rows — the plan needs real window starts, and guessing them is exactly what this must not do" >&2; return 1; }
      plan=$(phase_plan "$rows" "$now_s")
      [ -n "$plan" ] || { echo "phase: nothing to plan (every pool account is benched, or ccquota knows none of them)" >&2; return 1; }
      printf '%s%-24s %-8s %-4s %s%s\n' "$A_DIM" ACCOUNT STATE SLOT WHEN "$A_RST"
      while IFS=$'\t' read -r l slot k st; do
        [ -n "$l" ] || continue
        if [ "$st" = missed ]; then
          printf '%-24s %s%-8s%s %-4s its slot went by — free to open one now\n' "$l" "$A_DIM" "$st" "$A_RST" "$k"
        elif [ "$st" = running ]; then
          printf '%-24s %s%-8s%s %-4s window opened %s ago · resets in %s\n' "$l" "$A_GRN" "$st" "$A_RST" "$k" \
            "$(human_dur $(( now_s > slot ? now_s - slot : 0 )))" "$(human_dur $(( slot + PHASE_WINDOW > now_s ? slot + PHASE_WINDOW - now_s : 0 )))"
        else
          printf '%-24s %s%-8s%s %-4s may open its window in ~%s\n' "$l" "$A_YEL" "$st" "$A_RST" "$k" \
            "$(human_dur $(( slot > now_s ? slot - now_s : 0 )))"
        fi
      done <<EOF
$plan
EOF
      if [ "$apply" = 1 ]; then
        phase_write "$plan"
        printf '%sapplied%s → %s (new spawns honour these slots; FLEET_ACCOUNT_PHASE=0 disables, `phase --clear` drops it)\n' \
          "$A_GRN" "$A_RST" "$STATE_PHASE"
      else
        printf '%sdry run%s — nothing written. Re-run with --apply to make new spawns honour these slots.\n' "$A_DIM" "$A_RST"
      fi
      return 0 ;;
  esac
  # show: the pool's phase state as it stands right now
  rows=$(quota_rows cached)
  printf '%s%-24s %-10s %s%s\n' "$A_DIM" ACCOUNT HOLD WINDOW "$A_RST"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    hold=$(acct_phase_hold "$l")
    slot=$(quota_field "$rows" "$l" 5); u5=$(quota_field "$rows" "$l" 2)
    if [ -n "$slot" ] && [ "${u5:-0}" -gt 0 ] && [ "$slot" -gt "$now_s" ]; then
      st="open, resets in $(human_dur $(( slot - now_s ))) (started $(human_dur $(( now_s - (slot - PHASE_WINDOW) ))) ago)"
    else
      st="${A_DIM}no live 5h window${A_RST}"
    fi
    if [ "$hold" -gt "$now_s" ]; then
      printf '%-24s %s%-10s%s %s\n' "$l" "$A_YEL" "in $(human_dur $(( hold - now_s )))" "$A_RST" "$st"
    else
      printf '%-24s %-10s %s\n' "$l" "-" "$st"
    fi
  done <<EOF
$(acct_labels)
EOF
  [ -f "$STATE_PHASE" ] || printf '%sno plan written — `phase --plan` to see one, `--plan --apply` to arm it%s\n' "$A_DIM" "$A_RST"
}

# Aligned, scannable table — first token of every data row is the bare label, so
# usage-modal.sh can extract the pick with `awk '{print $1}'`. Colour lives only
# in the marker glyph (fixed 1-col) and the trailing STATE field (no padding after
# it), so the ANSI bytes never throw the column widths off. Row 1 is the column
# header (fzf pins it via --header-lines=1). Columns:
#   ACCOUNT  ●(active)  FALLBACK(bench TTL used only when a banner carries no
#   reset time — a live bench ends at the banner's instant, shown in STATE)
#   STATE(ok | limited · back in ~Nm | NO TOKEN)
cmd_list() {
  local labels active l until state tok w now_s hdr r5 hold
  local fmt='%-*s  %s  %-7s %s\n'
  labels=$(acct_labels)
  if [ -z "$labels" ]; then
    printf 'multi-account: OFF (no token files in %s)\n' "$ACCT_DIR"
    printf 'register accounts with:  claude setup-token  → save the token to %s/<label> (chmod 600)\n' "$ACCT_DIR"
    return 0
  fi
  active=$(cmd_active)
  now_s=$(now)
  local qrows u5 u7 util qc; qrows=$(quota_rows cached)
  # Dynamic ACCOUNT width: the widest label, floored at len("ACCOUNT").
  w=7
  while IFS= read -r l; do [ -n "$l" ] && [ "${#l}" -gt "$w" ] && w=${#l}; done <<EOF
$labels
EOF
  # Header row (dimmed whole-line — wrapped OUTSIDE the padded fields so the
  # dim/reset bytes can't shift any column).
  hdr=$(printf "$fmt" "$w" ACCOUNT ' ' FALLBACK STATE)
  printf '%s%s%s\n' "$A_DIM" "$hdr" "$A_RST"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    until=$(acct_limited_until "$l")
    if [ "$until" -gt "$now_s" ]; then
      state="${A_YEL}limited${A_RST} ${A_DIM}· back in ~$(human_dur $(( until - now_s )))${A_RST}"
    else
      tok=$(acct_token "$l")
      if [ -n "$tok" ]; then state="${A_GRN}ok${A_RST}"; else state="${A_RED}NO TOKEN${A_RST}"; fi
    fi
    # ccquota columns when known (issue #513): "5h 42% · 7d 21%", coloured by the
    # higher of the two against the warn/ceiling knobs. Then the WINDOW itself
    # (issue #598): how long this account's live 5h window still has to run — the
    # column that makes a phase stagger visible, and the one that shows an account
    # sitting at `win idle` with a whole window going to waste. A pending phase
    # slot is shown the way a bench is, so "why is nothing spawning here" reads.
    if [ -n "$qrows" ]; then
      u5=$(quota_field "$qrows" "$l" 2); u7=$(quota_field "$qrows" "$l" 3)
      if [ -n "$u5" ]; then
        util=$u5; [ "$u7" -gt "$util" ] && util=$u7
        qc="$A_GRN"; [ "$util" -ge "$WARN_PCT" ] && qc="$A_YEL"; [ "$util" -ge "$CEILING" ] && qc="$A_RED"
        state="$state ${A_DIM}·${A_RST} ${qc}5h ${u5}% · 7d ${u7}%${A_RST}"
        r5=$(quota_field "$qrows" "$l" 5)
        if [ "$u5" -gt 0 ] && [ -n "$r5" ] && [ "$r5" -gt "$now_s" ]; then
          state="$state ${A_DIM}· win $(human_dur $(( r5 - now_s ))) left${A_RST}"
        else
          state="$state ${A_DIM}· win idle${A_RST}"
        fi
      fi
    fi
    hold=$(acct_phase_hold "$l")
    [ "$hold" -gt "$now_s" ] && state="$state ${A_DIM}·${A_RST} ${A_YEL}phase${A_RST} ${A_DIM}· opens in ~$(human_dur $(( hold - now_s )))${A_RST}"
    printf "$fmt" "$w" "$l" \
      "$([ "$l" = "$active" ] && printf '%s●%s' "$A_GRN" "$A_RST" || printf ' ')" \
      "$(human_dur "$(acct_ttl "$l")")" "$state"
  done <<EOF
$labels
EOF
}

# Dispatch ONLY when executed directly. Sourcing (the selftest does this to unit
# -test the pure helpers) must not run a command — no rotation, no state writes —
# so the tests can exercise dur_secs/acct_ttl/pick_active/… in isolation.
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
case "${1:-active}" in
  inventory|choose|profile|check-target|bench-codex|launch) account_adapter "$@" ;;
  reconcile) account_reconcile "$@" ;;
  failover-status) account_reconcile status ;;
  _claude-inventory) shift; cmd_claude_inventory "$@" ;;
  active)        cmd_active ;;
  token)         cmd_token "${2:-}" ;;
  env)           cmd_env ;;
  list)          cmd_list ;;
  use)           cmd_use "${2:-}" ;;
  rotate)        cmd_rotate ;;
  mark-limited)  cmd_mark_limited "${2:-}" "${3:-}" ;;
  clear)         cmd_clear "${2:-}" ;;
  limited-until) acct_limited_until "${2:-}" ;;
  quota)         shift; cmd_quota "$@" ;;
  bench)         cmd_bench "${2:-}" "${3:-}" "${4:-}" ;;
  model-limited) cmd_model_limited "${2:-}" "${3:-}" "${4:-}" ;;
  model-limited-until) acct_model_limited_until "${2:-}" "${3:-}" ;;
  model-clear)   cmd_model_clear "${2:-}" "${3:-}" ;;
  migrate)       shift; exec bash "$BIN/fleet-migrate.sh" "$@" ;;
  whoami)        shift; exec bash "$BIN/fleet-migrate.sh" whoami "$@" ;;
  phase)         shift; cmd_phase "$@" ;;
  *) echo "fleet-account.sh: unknown command '$1' (active|token|env|list|use|rotate|mark-limited|clear|limited-until|quota|bench|phase|model-limited|model-limited-until|model-clear|migrate|whoami)" >&2; exit 2 ;;
esac
fi
