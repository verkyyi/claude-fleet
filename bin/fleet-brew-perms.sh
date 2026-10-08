#!/bin/bash
# fleet-brew-perms.sh — a Homebrew keg the other logins cannot read (issue #2283).
#
# WHY: brew makes its directories with the CALLER's umask. On a machine where the
# brew prefix's owner runs umask 077 (m5, 2026-10-07, #2277), one upgrade poured
# nine kegs as drwx------ — Cellar/<formula>/, Cellar/<formula>/<version>/, the
# files inside them and the opt/<formula> link. The owner noticed nothing; every
# OTHER login on the machine lost `import ssl` (errno 13) in Homebrew's python3,
# its credential proxy and its tmux (libjemalloc.2.dylib, errno 13). Nothing said
# so anywhere, and it was fixed by hand with `chmod -R go+rX`.
#
# This puts the paths that are meant for everyone back to Homebrew's default
# (go+rX), on a machine with more than one login, and only as the prefix's owner:
#   - <prefix>/Cellar, <prefix>/opt, Cellar/*, Cellar/*/* (directories) and
#     anything under a keg (directories go+rx, files go+r, X keeps exec-ness);
#   - the links brew makes for everyone: opt/*, bin/*, sbin/*, lib/*,
#     Frameworks/* (macOS honours a link's own mode for readlink(2), which is how
#     python finds its prefix; Linux ignores it, so links are macOS-only).
# Never etc/ (etc/*/private is private on purpose), var/, Caskroom/ or anything
# else under the prefix. Not the owner ⇒ change nothing, only report (the doctor's
# `brew` row names the owner and the one line to run).
#
# Modes:
#   --scan     print "<what>\t<path>" for every unit that needs repair, one per
#              line (what = keg | dir | link); exit 0, no output = clean
#   --fix      the tick (bin/fleet-diskguard.sh --watch): on a multi-login machine,
#              as the prefix's owner, repair every unit --scan prints and log one
#              line per repair to $FLEET_CONF_DIR/diskguard/brew-perms.log;
#              otherwise change nothing. Always exit 0.
#   --doctor   one line "<ok|warn|skip>\t<message>" for bin/fleet-doctor.sh
#
# Knobs / seams:
#   FLEET_BREW_PERMS=0      off (every mode prints nothing / skip)
#   FLEET_BREW_PREFIX       the prefix (default `brew --prefix`, else
#                           /opt/homebrew, else /usr/local — whichever has Cellar/)
#   FLEET_BREW_LOGINS       how many logins this machine has (default: counted)
#   FLEET_BREW_ME           who this login is, for the owner check (default `id -un`)
#   FLEET_BREW_LOG          the repair log (default $FLEET_CONF_DIR/diskguard/brew-perms.log)
set -uo pipefail

[ "${FLEET_BREW_PERMS:-1}" = 0 ] && { [ "${1:-}" = --doctor ] && printf 'skip\tFLEET_BREW_PERMS=0\n'; exit 0; }

brew_prefix() {
  local p="${FLEET_BREW_PREFIX:-}"
  if [ -z "$p" ] && command -v brew >/dev/null 2>&1; then p="$(brew --prefix 2>/dev/null)"; fi
  if [ -z "$p" ] || [ ! -d "$p/Cellar" ]; then
    p=''
    for c in /opt/homebrew /usr/local /home/linuxbrew/.linuxbrew; do [ -d "$c/Cellar" ] && { p="$c"; break; }; done
  fi
  printf '%s' "$p"
}

# Real people's logins: macOS UniqueID ≥ 501 with a home under /Users (the `_`
# daemons and nobody are below it); Linux uid 1000..65533 with a login shell.
login_count() {
  case "${FLEET_BREW_LOGINS:-}" in ''|*[!0-9]*) ;; *) printf '%s' "$FLEET_BREW_LOGINS"; return ;; esac
  if command -v dscl >/dev/null 2>&1; then
    dscl . -list /Users UniqueID 2>/dev/null | while read -r n u; do
      case "$n" in _*) continue ;; esac
      [ "${u:-0}" -ge 501 ] 2>/dev/null && [ -d "/Users/$n" ] && echo "$n"
    done | wc -l | tr -d ' '
  else
    getent passwd 2>/dev/null | awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/' | wc -l | tr -d ' '
  fi
}

owner_of() { stat -f '%Su' "$1" 2>/dev/null || stat -c '%U' "$1" 2>/dev/null; } # portable-ok: both-ways fallback

# Units, not paths: a bad file deep in a keg reports its keg once.
scan() {
  local p="$1" c="$1/Cellar" d
  [ -d "$c" ] || return 0
  for d in "$c" "$p/opt"; do
    [ -d "$d" ] && [ -n "$(find "$d" -maxdepth 0 -type d ! -perm -055 2>/dev/null)" ] && printf 'dir\t%s\n' "$d"
  done
  # Cellar/<formula> on its own (its kegs are units of their own).
  find "$c" -mindepth 1 -maxdepth 1 -type d ! -perm -055 2>/dev/null | sed 's/^/dir	/'
  # A keg is bad when it, or anything a reader needs inside it, lacks go+r(x).
  local lk=''; [ "$(uname -s)" = Darwin ] && lk=y
  find "$c" -mindepth 2 \( -type d ! -perm -055 -o -type f ! -perm -044 ${lk:+-o -type l ! -perm -044} \) -print 2>/dev/null \
    | awk -v c="$c/" 'index($0, c) == 1 { r = substr($0, length(c) + 1); n = split(r, a, "/"); if (n >= 2) { k = c a[1] "/" a[2]; if (!(k in s)) { s[k] = 1; print "keg\t" k } } }'
  [ "$(uname -s)" = Darwin ] || return 0
  for d in opt bin sbin lib Frameworks; do
    [ -d "$p/$d" ] && find "$p/$d" -mindepth 1 -maxdepth 1 -type l ! -perm -044 2>/dev/null | sed 's/^/link	/'
  done
}

fix_unit() {   # $1=what $2=path → 0 repaired
  case "$1" in
    keg)  chmod -R go+rX "$2" || return 1
          [ "$(uname -s)" = Darwin ] || return 0
          find "$2" -type l ! -perm -044 -exec chmod -h go+rx {} + ;;
    dir)  chmod go+rx "$2" ;;
    link) chmod -h go+rx "$2" ;;
    *) return 1 ;;
  esac
}

P="$(brew_prefix)"
case "${1:-}" in
  --scan)
    [ -n "$P" ] && scan "$P"
    exit 0 ;;
  --fix)
    [ -n "$P" ] || exit 0
    n="$(login_count)"; [ "${n:-0}" -ge 2 ] 2>/dev/null || exit 0
    [ "$(owner_of "$P/Cellar")" = "${FLEET_BREW_ME:-$(id -un)}" ] || exit 0
    bad="$(scan "$P")"; [ -n "$bad" ] || exit 0
    log="${FLEET_BREW_LOG:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/diskguard/brew-perms.log}"
    mkdir -p "$(dirname "$log")" 2>/dev/null
    printf '%s\n' "$bad" | while IFS="$(printf '\t')" read -r what pth; do
      [ -n "$pth" ] || continue
      if err="$(fix_unit "$what" "$pth" 2>&1)"; then r=fixed; else r="failed: $(printf '%s' "$err" | head -1)"; fi
      printf '%s %s %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$what" "$pth" "$r" >> "$log" 2>/dev/null
    done
    exit 0 ;;
  --doctor)
    [ -n "$P" ] || { printf 'skip\tno Homebrew prefix\n'; exit 0; }
    n="$(login_count)"
    [ "${n:-0}" -ge 2 ] 2>/dev/null || { printf 'skip\tone login on this machine — nobody else reads %s\n' "$P"; exit 0; }
    bad="$(scan "$P")"
    [ -n "$bad" ] || { printf 'ok\t%s readable by all %s logins\n' "$P" "$n"; exit 0; }
    cnt="$(printf '%s\n' "$bad" | wc -l | tr -d ' ')"
    first="$(printf '%s\n' "$bad" | head -3 | cut -f2 | sed "s|^$P/||" | tr '\n' ' ')"
    own="$(owner_of "$P/Cellar")"
    cmd="chmod -R go+rX $P/Cellar $P/opt"
    [ "$(uname -s)" = Darwin ] && cmd="$cmd && find $P/Cellar $P/opt $P/bin $P/lib -type l ! -perm -044 -exec chmod -h go+rx {} +"
    if [ "$own" = "${FLEET_BREW_ME:-$(id -un)}" ]; then
      printf 'warn\t%s path(s) under %s other logins cannot read (%s) — the diskguard tick repairs them within 5 min; now: %s\n' "$cnt" "$P" "${first% }" "$cmd"
    else
      printf 'warn\t%s path(s) under %s other logins cannot read (%s) — owned by %s, this login cannot repair them; as %s run: %s\n' "$cnt" "$P" "${first% }" "${own:-?}" "${own:-?}" "$cmd"
    fi
    exit 0 ;;
  --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
  *) echo "usage: $0 --scan | --fix | --doctor" >&2; exit 2 ;;
esac
