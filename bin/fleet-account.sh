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
# "<label>.conf" (same dir) may set LIMIT_TTL=<N>[smhd] — this account's bench
# window after a usage-limit hit (default: FLEET_ACCOUNT_LIMIT_TTL).
#
# State (account-wide, like usage/ratelimit → shared cache dir):
#   $C/account.active    — one line: the label new sessions should use
#   $C/account.limited   — label<TAB>until-epoch<TAB>banner   (one row per limited acct)
#
# Commands:
#   active               — print the label new sessions should use (rotating past
#                          any account still inside its limit window); empty = off
#   token [label]        — print the OAuth token for <label> (default: active)
#   env                  — print `CLAUDE_CODE_OAUTH_TOKEN=…` for the active acct (or nothing)
#   list                 — human table: label · active · state
#   use <label>          — pin <label> active
#   rotate               — advance active to the next eligible account
#   mark-limited <label> [banner]
#                        — record <label> limited for its bench window (per-account
#                          LIMIT_TTL in <label>.conf, else FLEET_ACCOUNT_LIMIT_TTL); if it
#                          was the active one, rotate. Prints the (new) active label.
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
STATE_ACTIVE="$FLEET_C/account.active"
STATE_LIMITED="$FLEET_C/account.limited"
LOCK="$FLEET_C/account.lock"

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
  mkdir -p "$FLEET_C"
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
  mkdir -p "$FLEET_C"; acct_lock; printf '%s\n' "$l" | atomic_write "$STATE_ACTIVE"; acct_unlock
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
  mkdir -p "$FLEET_C"; acct_lock; printf '%s\n' "$nxt" | atomic_write "$STATE_ACTIVE"; acct_unlock
  printf '%s' "$nxt"
}

cmd_mark_limited() {
  local label="$1" banner="${2:-}" until cur nxt rotated=0
  [ -n "$label" ] || { echo "mark-limited: usage: mark-limited <label> [banner]" >&2; return 1; }
  acct_labels | grep -qx "$label" || { echo "mark-limited: unknown account '$label'" >&2; return 1; }
  until=$(( $(now) + $(acct_ttl "$label") ))
  mkdir -p "$FLEET_C"; acct_lock
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

cmd_list() {
  local labels active l until state tok
  labels=$(acct_labels)
  if [ -z "$labels" ]; then
    printf 'multi-account: OFF (no token files in %s)\n' "$ACCT_DIR"
    printf 'register accounts with:  claude setup-token  → save the token to %s/<label> (chmod 600)\n' "$ACCT_DIR"
    return 0
  fi
  active=$(cmd_active)
  printf '%-16s %-8s %-8s %s\n' ACCOUNT ACTIVE WINDOW STATE
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    until=$(acct_limited_until "$l")
    if [ "$until" -gt "$(now)" ]; then
      state="limited (~$(( (until - $(now)) / 60 ))m left)"
    else
      tok=$(acct_token "$l"); [ -n "$tok" ] && state="ok" || state="NO TOKEN"
    fi
    printf '%-16s %-8s %-8s %s\n' "$l" "$([ "$l" = "$active" ] && echo '  ●' || echo '')" "$(human_dur "$(acct_ttl "$l")")" "$state"
  done <<EOF
$labels
EOF
}

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
