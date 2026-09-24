#!/bin/sh
# fleet-install-follow.sh [--self | --others | --all] [--summary] [--json]
#                         [--dir <install>] [--conf-dir <dir>] [--homes <dir>]
#   — is each login on this machine following refs/tags/stable, and if not, why?
#     (issue #1123, EPIC #1117 C7)
#
# The install-sync daemon (bin/fleet-install-sync.sh, #1120) moves every login's
# live install to the stable mark on its own — and when it STOPS moving one
# (refused: a hand sync pushed HEAD past stable, or tracked local edits; rolled
# back: the new version failed the doctor; deferred: a session has been busy for
# a day; never ticked: the daemon is not loaded) nothing said so. Its state file
# has every fact; this is the ONE reader that turns it into a verdict, so the
# doctor's `install` rows (own login + the others) and
# fleet-install-version.sh's `follow:` / `logins:` lines never parse it twice.
#
# Verdicts (the `verdict:` key / column, one token):
#   OK       following: `current` at stable, just `updated`, or `deferred` for
#            less than a day (a busy session is normal — it follows when idle)
#   STUCK    not following, and someone should know why: `refused`,
#            `rolled-back` / `skipped` (that version is not retried until stable
#            moves), `failed` (the rollback itself failed — fix by hand),
#            `deferred` past FLEET_INSTALL_FOLLOW_STUCK_SECS (24h), a state older
#            than that (the daemon stopped ticking), no tick ever, or an install
#            that predates the daemon. The doctor WARNs on these.
#   OFF      FLEET_INSTALL_SYNC=0 in that login's fleet.settings / fleet.conf —
#            a choice, never a warning (the documented way to silence one)
#   UNSEEN   the last tick could not read the mark (`fetch-failed`, offline) or
#            there is no tag yet (`none`) — not seen ≠ not following; INFO only
#   UNKNOWN  the state cannot be read (another login's home without passwordless
#            sudo) or carries a token this reader does not know — never OK
#
# Other logins (--others / --all) are found the way fleet-sync-logins.sh finds
# them — every <homes>/<login>/.claude/fleet (homes: /Users, or /home) that is
# not this install — and their files are read AS THE OWNER (`sudo -n -u <owner>`,
# EPIC #1117 rule 5) when this login cannot read them; without passwordless sudo
# the login reads UNKNOWN and the line names the command, nothing is changed.
# Their conf dir is assumed at the default ~/.config/claude-fleet.
#
# Output — `--self` (the doctor's form): line-anchored `key:  value` pairs
# (login follow result checked head stable verdict why). `--others --summary`
# (the version script's form): ONE line, a `login on/result age` token per login
# (`⚠` on a STUCK one) ending `· N stuck` when any is, nothing at all when there
# is no other login; exit 1 iff N > 0. `--all` (default): a table, self first.
# `--json`: one object per login (an array for --all / --others).
#
# Read-only: it never fetches, never writes, never touches another login.
# Env: FLEET_LIVE_DIR / FLEET_CONF_DIR (this login's install / conf),
# FLEET_SYNC_LOGINS_HOMES / _SUDO / _ME (shared with fleet-sync-logins.sh so one
# sandbox serves both), FLEET_INSTALL_FOLLOW_STUCK_SECS (default 86400).
# Exit: 0; 1 = `--summary` found a stuck login; 2 = usage.
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
dir="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
conf_dir="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
case "$(uname -s 2>/dev/null)" in Darwin) homes_default=/Users ;; *) homes_default=/home ;; esac
homes="${FLEET_SYNC_LOGINS_HOMES:-$homes_default}"
SUDO="${FLEET_SYNC_LOGINS_SUDO-sudo -n}"
me="${FLEET_SYNC_LOGINS_ME:-$(id -un 2>/dev/null || echo me)}"
STUCK_SECS="${FLEET_INSTALL_FOLLOW_STUCK_SECS:-86400}"
case "$STUCK_SECS" in ''|*[!0-9]*) STUCK_SECS=86400 ;; esac
scope=all summary=0 as_json=0

usage() { sed -n '2,/^set -u/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --self)     scope=self ;;
    --others)   scope=others ;;
    --all)      scope=all ;;
    --summary)  summary=1; [ "$scope" = self ] && scope=others ;;
    --json)     as_json=1 ;;
    --dir)      shift; dir="${1:-}" ;;
    --conf-dir) shift; conf_dir="${1:-}" ;;
    --homes)    shift; homes="${1:-}" ;;
    -h|--help)  usage; exit 0 ;;
    *) printf 'fleet-install-follow: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[ "$summary" -eq 1 ] && [ "$scope" = all ] && scope=others

now=$(date +%s)
self_real=''; [ -d "$dir" ] && self_real=$(cd "$dir" && pwd -P)

# --- reading another login's files ---------------------------------------------
# as_owner <owner> — can this shell act as <owner> through $SUDO? Probed once.
owner_ok='' owner_no=''
as_owner() {
  [ "$1" != "$me" ] && [ -n "$SUDO" ] || return 1
  case " $owner_ok " in *" $1 "*) return 0 ;; esac
  case " $owner_no " in *" $1 "*) return 1 ;; esac
  if $SUDO -u "$1" true 2>/dev/null; then owner_ok="$owner_ok $1"; return 0; fi
  owner_no="$owner_no $1"; return 1
}
# oread <owner> <file> → the contents on stdout; 0 = read, 1 = absent (known),
# 2 = cannot tell (unreadable and no way to ask the owner).
oread() {
  if [ -r "$2" ]; then cat "$2" 2>/dev/null; return 0; fi
  if as_owner "$1"; then
    $SUDO -u "$1" sh -c 'test -e "$1" || exit 3; cat "$1" || exit 4' _ "$2" 2>/dev/null
    case $? in 0) return 0 ;; 3) return 1 ;; *) return 2 ;; esac
  fi
  absent_known "$2" && return 1
  return 2
}
# oexists <owner> <file> → 0 present, 1 absent, 2 cannot tell.
oexists() {
  [ -e "$2" ] && return 0
  if as_owner "$1"; then
    $SUDO -u "$1" test -e "$2" 2>/dev/null && return 0
    return 1
  fi
  absent_known "$2" && return 1
  return 2
}
# absent_known <path> → 0 iff the path does not exist AND this shell can tell:
# its nearest existing ancestor is traversable (a login whose ~/.config has no
# global/ yet is "no tick", not "cannot read"; one behind a 700 dir is the latter).
absent_known() {
  [ -e "$1" ] && return 1
  _p=$(dirname "$1")
  while [ ! -e "$_p" ] && [ "$_p" != / ]; do _p=$(dirname "$_p"); done
  [ -x "$_p" ]
}
# conf_val <text> <KEY> → the LAST uncommented assignment's value, quotes/blanks
# stripped ('' if none) — what sourcing the file would leave in KEY.
conf_val() {
  printf '%s\n' "$1" | sed -n 's/^[[:space:]]*'"$2"'[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p' | tail -1 | tr -d "\"' 	"
}
short() { printf '%.7s' "${1:-}"; }
# fmt_age <secs> → 3m / 5h / 2d (never "0m": a just-written state is "<1m")
fmt_age() {
  case "$1" in ''|*[!0-9]*) printf '?'; return ;; esac
  if [ "$1" -lt 60 ]; then printf '<1m'
  elif [ "$1" -lt 3600 ]; then printf '%dm' $(( $1 / 60 ))
  elif [ "$1" -lt 172800 ]; then printf '%dh' $(( $1 / 3600 ))
  else printf '%dd' $(( $1 / 86400 )); fi
}

# --- judge <login> <owner> <conf-dir> <install> — sets F_* -----------------------
# F_FOLLOW on|off|?  F_RESULT <token>|no-tick|no-daemon|?  F_AGE secs|''
# F_HEAD F_STABLE (7-char)  F_VERDICT OK|STUCK|OFF|UNSEEN|UNKNOWN  F_WHY text
judge() {
  F_FOLLOW=on F_RESULT='?' F_AGE='' F_HEAD='' F_STABLE='' F_VERDICT=UNKNOWN F_WHY=''
  j_login=$1 j_owner=$2 j_conf=$3 j_inst=$4
  j_state="$j_conf/global/install-sync.state"

  # on / off: the login's settings file (issue #979), else the install's fleet.conf
  # it replaces (dual-read) — the same two files fleet-lib.sh gives the daemon.
  j_val=''; j_unread=0
  for j_f in "$j_conf/fleet.settings" "$j_inst/fleet.conf"; do
    j_txt=$(oread "$j_owner" "$j_f"); j_rc=$?
    [ "$j_rc" -eq 2 ] && j_unread=1
    [ "$j_rc" -eq 0 ] && j_val=$(conf_val "$j_txt" FLEET_INSTALL_SYNC)
    [ -n "$j_val" ] && break
  done
  if [ "$j_val" = 0 ]; then
    F_FOLLOW=off F_RESULT=off F_VERDICT=OFF
    F_WHY="FLEET_INSTALL_SYNC=0 — this login does not follow refs/tags/stable (a hand /fleet-sync-install still works; set it to 1, or delete the line, to follow)"
    return 0
  fi
  [ "$j_unread" -eq 1 ] && [ -z "$j_val" ] && F_FOLLOW='?'

  # an install from before the daemon existed cannot be following anything
  oexists "$j_owner" "$j_inst/bin/fleet-install-sync.sh"; j_rc=$?
  if [ "$j_rc" -eq 1 ]; then
    F_RESULT=no-daemon F_VERDICT=STUCK
    F_WHY="this install predates install-sync (#1120) — nothing follows stable here; sync it once by hand (fleet-sync-logins.sh --logins $j_login, or /fleet-sync-install as $j_login) and the daemon comes with it"
    return 0
  fi

  j_txt=$(oread "$j_owner" "$j_state"); j_rc=$?
  if [ "$j_rc" -eq 2 ]; then
    F_RESULT='?' F_VERDICT=UNKNOWN
    F_WHY="cannot read $j_state as $me — needs passwordless sudo (sudo -n -u $j_owner cat $j_state)"
    return 0
  fi
  if [ "$j_rc" -eq 1 ]; then
    F_RESULT=no-tick F_VERDICT=STUCK
    F_WHY="no tick has run yet (no $j_state) — is com.claude-fleet.install-sync loaded for $j_login? (\`launchctl list | grep install-sync\`; it runs at load and every 30 min; /fleet-sync-install installs + loads it)"
    return 0
  fi

  j_get() { printf '%s\n' "$j_txt" | sed -n "s/^$1: //p" | head -1; }
  j_result=$(j_get result); j_last=$(j_get last_check); j_reason=$(j_get reason)
  j_since=$(j_get deferred_since); j_from=$(j_get from); j_to=$(j_get to)
  F_HEAD=$(short "$(j_get head)"); F_STABLE=$(short "$(j_get stable)")
  F_RESULT="${j_result:-?}"
  case "$j_last" in ''|*[!0-9]*) F_AGE='' ;; *) F_AGE=$(( now - j_last )); [ "$F_AGE" -lt 0 ] && F_AGE=0 ;; esac

  case "$j_result" in
    off)
      # the conf says on now; the last tick still saw 0 — the next one follows
      F_VERDICT=OK; F_WHY="switched on since the last tick (which saw FLEET_INSTALL_SYNC=0) — the next tick follows stable" ;;
    current)
      F_VERDICT=OK; F_WHY="at stable ${F_STABLE:-?}" ;;
    updated)
      F_VERDICT=OK; F_WHY="updated $(short "$j_from")..$(short "$j_to") to stable — $j_reason" ;;
    deferred)
      j_wait=''
      case "$j_since" in ''|*[!0-9]*) ;; *) j_wait=$(( now - j_since )); [ "$j_wait" -lt 0 ] && j_wait=0 ;; esac
      if [ -n "$j_wait" ] && [ "$j_wait" -gt "$STUCK_SECS" ]; then
        F_VERDICT=STUCK
        F_WHY="deferred for $(fmt_age "$j_wait") — $j_reason; a session busy for over a day is usually a stuck one (check the dash), or sync by hand: /fleet-sync-install"
      else
        F_VERDICT=OK
        F_WHY="deferred${j_wait:+ for $(fmt_age "$j_wait")} (a session is busy) — follows when every window is idle; stable ${F_STABLE:-?} waiting"
      fi ;;
    refused|rolled-back|skipped|failed)
      F_VERDICT=STUCK; F_WHY="$j_result — $j_reason" ;;
    fetch-failed|none)
      F_VERDICT=UNSEEN; F_WHY="$j_result — $j_reason" ;;
    '')
      F_VERDICT=UNKNOWN; F_WHY="$j_state has no result line" ;;
    *)
      F_VERDICT=UNKNOWN; F_WHY="unrecognised result '$j_result' in $j_state (a newer daemon than this reader?)" ;;
  esac
  # a tick that stopped coming is the same silence this exists to break
  if [ -n "$F_AGE" ] && [ "$F_AGE" -gt "$STUCK_SECS" ] && [ "$F_VERDICT" != OFF ]; then
    F_VERDICT=STUCK
    F_WHY="last tick $(fmt_age "$F_AGE") ago (every 30 min expected) — is com.claude-fleet.install-sync loaded for $j_login? (\`launchctl list | grep install-sync\`); before it stopped: $F_WHY"
  fi
  return 0
}

jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
emit_json() { # $1 login $2 self(0/1)
  printf '{"login":"%s","self":%s,"follow":"%s","result":"%s","age":%s,"head":"%s","stable":"%s","verdict":"%s","why":"%s"}' \
    "$(jstr "$1")" "$( [ "$2" = 1 ] && echo true || echo false )" "$F_FOLLOW" "$(jstr "$F_RESULT")" \
    "${F_AGE:-null}" "$F_HEAD" "$F_STABLE" "$F_VERDICT" "$(jstr "$F_WHY")"
}
emit_block() { # $1 login
  printf 'login:    %s\n' "$1"
  printf 'follow:   %s\n' "$F_FOLLOW"
  printf 'result:   %s\n' "$F_RESULT"
  printf 'checked:  %s\n' "$( [ -n "$F_AGE" ] && printf '%s ago' "$(fmt_age "$F_AGE")" || printf 'never' )"
  printf 'head:     %s\n' "${F_HEAD:--}"
  printf 'stable:   %s\n' "${F_STABLE:--}"
  printf 'verdict:  %s\n' "$F_VERDICT"
  printf 'why:      %s\n' "$F_WHY"
}
emit_row() { # $1 login
  printf '%-12s %-6s %-12s %-6s %-7s %-7s %-7s %s\n' "$1" "$F_FOLLOW" "$F_RESULT" \
    "$( [ -n "$F_AGE" ] && fmt_age "$F_AGE" || printf -- - )" "${F_HEAD:--}" "${F_STABLE:--}" "$F_VERDICT" "$F_WHY"
}
# one summary token: `alice on/current 12m`, `bob off`, `carol on/deferred 26h ⚠`
emit_token() { # $1 login
  case "$F_VERDICT" in
    OFF)     printf '%s off' "$1" ;;
    UNKNOWN) printf '%s ?' "$1" ;;
    *)       printf '%s %s/%s' "$1" "$F_FOLLOW" "$F_RESULT"
             [ -n "$F_AGE" ] && printf ' %s' "$(fmt_age "$F_AGE")"
             [ "$F_VERDICT" = STUCK ] && printf ' ⚠' ;;
  esac
}

# --- self ------------------------------------------------------------------------
if [ "$scope" != others ]; then
  if [ -d "$dir" ]; then
    judge "$me" "$me" "$conf_dir" "$dir"
  else
    F_FOLLOW='?' F_RESULT='?' F_AGE='' F_HEAD='' F_STABLE='' F_VERDICT=UNKNOWN
    F_WHY="no live install at $dir"
  fi
  if [ "$scope" = self ]; then
    if [ "$as_json" -eq 1 ]; then emit_json "$me" 1; printf '\n'; else emit_block "$me"; fi
    exit 0
  fi
  self_json=$(emit_json "$me" 1); self_row=$(emit_row "$me")
fi

# --- the other logins ---------------------------------------------------------------
tokens='' rows='' jsons='' n=0 nstuck=0
for d in "$homes"/*/.claude/fleet; do
  [ -d "$d" ] || continue
  rd=$(cd "$d" && pwd -P)
  [ -n "$self_real" ] && [ "$rd" = "$self_real" ] && continue
  home=$(dirname "$(dirname "$d")"); login=$(basename "$home")
  [ "$login" = "$me" ] && continue
  owner=$(ls -ld "$d" 2>/dev/null | awk '{print $3}'); [ -n "$owner" ] || owner=$login
  judge "$login" "$owner" "$home/.config/claude-fleet" "$d"
  n=$((n + 1)); [ "$F_VERDICT" = STUCK ] && nstuck=$((nstuck + 1))
  tokens="$tokens${tokens:+ · }$(emit_token "$login")"
  rows="$rows$(emit_row "$login")
"
  jsons="$jsons${jsons:+,}$(emit_json "$login" 0)"
done

if [ "$summary" -eq 1 ]; then
  if [ "$n" -gt 0 ]; then
    printf '%s' "$tokens"
    [ "$nstuck" -gt 0 ] && printf ' · %d stuck' "$nstuck"
    printf '\n'
  fi
  [ "$nstuck" -gt 0 ] && exit 1
  exit 0
fi
if [ "$as_json" -eq 1 ]; then
  if [ "$scope" = all ]; then printf '[%s%s%s]\n' "$self_json" "${jsons:+,}" "$jsons"
  else printf '[%s]\n' "$jsons"; fi
  exit 0
fi
printf '%-12s %-6s %-12s %-6s %-7s %-7s %-7s %s\n' login follow result age head stable verdict why
[ "$scope" = all ] && printf '%s\n' "$self_row"
[ -n "$rows" ] && printf '%s' "$rows"
exit 0
