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
#
# Commands:
#   active               — print the label new sessions should use (rotating past
#                          any account still inside its limit window); empty = off
#   token [label]        — print the OAuth token for <label> (default: active)
#   env                  — print `CLAUDE_CODE_OAUTH_TOKEN=…` for the active acct (or nothing)
#   list                 — aligned table: label · active(●) · rotation window · state
#                          (state = ok | limited · back in ~Nm | NO TOKEN)
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
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"                       # FLEET_C, FLEET_CONF_DIR

ACCT_DIR="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}"
TTL="${FLEET_ACCOUNT_LIMIT_TTL:-18000}"     # how long a limited acct stays out (5h)
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
LOCK="$STATE_DIR/account.lock"

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
  local b hm h m ap zone ymd e i
  b=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')   # lowercase once: BSD sed has no //I
  local now_s="$2"
  # A clock time is REQUIRED. "resets monday" (the weekly banner) carries no
  # instant, so it falls back by design rather than guessing a weekday boundary.
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

# Choose the account new sessions should use, starting from $1 (the current
# active). Keep it if eligible; else the next eligible one round-robin; if ALL
# are limited, keep the current (best effort) so sessions still launch.
pick_active() {
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
  local label="$1" banner="${2:-}" until cur nxt rotated=0
  [ -n "$label" ] || { echo "mark-limited: usage: mark-limited <label> [banner]" >&2; return 1; }
  acct_labels | grep -qx "$label" || { echo "mark-limited: unknown account '$label'" >&2; return 1; }
  # Bench until the account's REAL refresh instant when the banner carries one
  # (issue #490); LIMIT_TTL is the fallback for banners that do not.
  until=$(banner_reset_epoch "$banner" "$(now)")
  if [ -n "$until" ]; then until=$(( until + RESET_BUFFER ))
  else                    until=$(( $(now) + $(acct_ttl "$label") )); fi
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

# Aligned, scannable table — first token of every data row is the bare label, so
# usage-modal.sh can extract the pick with `awk '{print $1}'`. Colour lives only
# in the marker glyph (fixed 1-col) and the trailing STATE field (no padding after
# it), so the ANSI bytes never throw the column widths off. Row 1 is the column
# header (fzf pins it via --header-lines=1). Columns:
#   ACCOUNT  ●(active)  FALLBACK(bench TTL used only when a banner carries no
#   reset time — a live bench ends at the banner's instant, shown in STATE)
#   STATE(ok | limited · back in ~Nm | NO TOKEN)
cmd_list() {
  local labels active l until state tok w now_s hdr
  local fmt='%-*s  %s  %-7s %s\n'
  labels=$(acct_labels)
  if [ -z "$labels" ]; then
    printf 'multi-account: OFF (no token files in %s)\n' "$ACCT_DIR"
    printf 'register accounts with:  claude setup-token  → save the token to %s/<label> (chmod 600)\n' "$ACCT_DIR"
    return 0
  fi
  active=$(cmd_active)
  now_s=$(now)
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
  active)        cmd_active ;;
  token)         cmd_token "${2:-}" ;;
  env)           cmd_env ;;
  list)          cmd_list ;;
  use)           cmd_use "${2:-}" ;;
  rotate)        cmd_rotate ;;
  mark-limited)  cmd_mark_limited "${2:-}" "${3:-}" ;;
  clear)         cmd_clear "${2:-}" ;;
  *) echo "fleet-account.sh: unknown command '$1' (active|token|env|list|use|rotate|mark-limited|clear)" >&2; exit 2 ;;
esac
fi
