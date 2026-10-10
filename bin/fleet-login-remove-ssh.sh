#!/bin/bash
# fleet-login-remove-ssh.sh — delete a macOS login through a LOCAL ssh session,
# for a remover with no Full Disk Access (issue #2994).
#
# macOS privacy protection (TCC) lets no process without Full Disk Access delete
# a user record: `dscl . -delete` answers eDSPermissionError even as root
# (#2973). The node program (root, started by the machine daemon's python) has
# none unless a person grants it on the machine's own screen. A session that
# arrives through sshd does, when Remote Login's 「允许远程用户完全磁盘访问」
# ("Allow full disk access for remote users") is on — so the delete rides one:
# root's own key, authorized on the admin login for loopback only, with a forced
# command that runs THIS script's `forced` and nothing else.
#
#   setup --admin <login>   (root) make the key + known_hosts, put ONE line in
#                           ~<admin>/.ssh/authorized_keys:
#                           from="127.0.0.1,::1",restrict,command="<this> forced" <key> fleet-login-remove-ssh
#                           Idempotent: a line already right is left byte for byte.
#   probe --admin <login>   (root) can the road work? exit 0 yes · 5 no, why on stderr
#   run <login> --admin <a> (root) delete <login> over the road
#   forced                  the authorized command (sshd runs it as the admin):
#                           $SSH_ORIGINAL_COMMAND is `probe` or `delete <login>`,
#                           anything else is refused. A login must be a plain
#                           name (^[a-z_][a-z0-9_-]{0,31}$), exist, have a uid
#                           ≥ 501, not be the admin itself, not be in admin.
#
# Exit (run / forced): 0 deleted (probe: works) · 1 the delete failed · 2 usage /
# bad argument · 3 refused · 4 no such login · 5 the road cannot work here (why
# on stderr: Remote Login off, the key not authorized, no key) · 7 the ssh
# session has no Full Disk Access (the Remote Login switch).
# Env (test seams): FLEET_REMOVE_SSH_DIR (/var/db/fleet-node/remove-ssh) ·
#   FLEET_REMOVE_SSH_HOMES (/Users) · FLEET_REMOVE_SSH_HOSTKEYS (/etc/ssh) ·
#   FLEET_REMOVE_SSH_FORCED (the command= path) · FLEET_REMOVE_SSH_TEST=1 (no
#   root needed, no chown) · FLEET_LOGIN_REMOVE_TCC_DB (the TCC database read
#   for Full Disk Access) · FLEET_LOGIN_REMOVE_DELETE_SECS (120).
set -uo pipefail

PROG=fleet-login-remove-ssh
BIN="$(cd "$(dirname "$0")" && pwd)"
DIR=${FLEET_REMOVE_SSH_DIR:-/var/db/fleet-node/remove-ssh}
KEY="$DIR/id_ed25519" KNOWN="$DIR/known_hosts"
HOMES=${FLEET_REMOVE_SSH_HOMES:-/Users}
HOSTKEYS=${FLEET_REMOVE_SSH_HOSTKEYS:-/etc/ssh}
TCC_DB=${FLEET_LOGIN_REMOVE_TCC_DB:-/Library/Application Support/com.apple.TCC/TCC.db}
MARK=fleet-login-remove-ssh
LOGIN_RE='^[a-z_][a-z0-9_-]{0,31}$'
# The command= path stays put across versions: the machine runtime's `current`
# when there is one (a managed machine), else this script where it stands.
RT_FORCED="/Library/Application Support/claude-fleet/current/bin/$PROG.sh"
if [ -n "${FLEET_REMOVE_SSH_FORCED:-}" ]; then FORCED=$FLEET_REMOVE_SSH_FORCED
elif [ -f "$RT_FORCED" ]; then FORCED=$RT_FORCED
else FORCED="$BIN/$PROG.sh"; fi

say() { printf '%s: %s\n' "$PROG" "$*" >&2; }
die() { say "$1"; exit "${2:-2}"; }
need_root() { [ "${FLEET_REMOVE_SSH_TEST:-0}" = 1 ] || [ "$EUID" = 0 ] || die "$1 needs root (sudo)" 3; }
valid_login() { printf '%s' "$1" | grep -Eq "$LOGIN_RE"; }

# The words a person acts on, one per reason the road is shut.
WHY_FDA='the ssh session has no Full Disk Access — turn on System Settings › General › Sharing › Remote Login › ⓘ › 「允许远程用户完全磁盘访问」 (Allow full disk access for remote users)'
WHY_OFF='Remote Login is off (System Settings › General › Sharing › Remote Login) — sshd refused 127.0.0.1'

admin_arg() {
  ADMIN=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --admin) ADMIN=${2:-}; shift 2 ;;
      --admin=*) ADMIN=${1#*=}; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$ADMIN" ] && valid_login "$ADMIN" || die "--admin <login>: a plain login name"
}

# ------------------------------------------------------------------ forced --
# Runs as the admin, under sshd: Full Disk Access is the session's (when the
# switch is on), sudo is the admin's own (NOPASSWD, as the node program's is).
has_fda() { sudo -n head -c 1 "$TCC_DB" >/dev/null 2>&1; }

acl_values() { dscl . -read "/Groups/$1" "$2" 2>/dev/null | awk -v a="$2:" '$1==a {for (i = 2; i <= NF; i++) print $i; f = 1; next} f && /^ / {print $1; next} {f = 0}'; }

forced_delete() {
  local login=$1 uid groups guid g secs rc n
  valid_login "$login" || die "refusing: '$login' is not a plain login name" 2
  uid=$(id -u "$login" 2>/dev/null) || { say "no login $login on this machine: nothing to remove"; exit 4; }
  case "$uid" in ''|*[!0-9]*) die "refusing: cannot read uid of $login" 3 ;; esac
  [ "$uid" -ge 501 ] || die "refusing: $login is a system account (uid $uid)" 3
  [ "$login" != "$(id -un)" ] || die "refusing: $login is the admin this runs as" 3
  groups=$(id -Gn "$login" 2>/dev/null) || die "refusing: cannot read groups of $login" 3
  case " $groups " in *' admin '*) die "refusing: $login is in the admin group" 3 ;; esac
  has_fda || { say "$WHY_FDA"; exit 7; }
  # the GUID is readable only while the record stands: the access groups after
  guid=$(dscl . -read "/Users/$login" GeneratedUID 2>/dev/null | awk '$1=="GeneratedUID:" {print $2; exit}')
  secs=${FLEET_LOGIN_REMOVE_DELETE_SECS:-120}
  say "deleting $login (uid $uid) from a local ssh session"
  # Bounded like the direct road (#2866): sudo is ours to signal.
  sudo -n sysadminctl -deleteUser "$login" & g=$!
  n=0
  while kill -0 "$g" 2>/dev/null; do
    [ "$n" -lt $((secs * 5)) ] || { say "WARN sysadminctl -deleteUser $login: past ${secs}s, killed"; kill -TERM "$g" 2>/dev/null; break; }
    sleep 0.2; n=$((n + 1))
  done
  wait "$g"; rc=$?
  [ "$rc" = 0 ] || say "WARN sysadminctl -deleteUser $login: exit $rc — checking what it left"
  if dscl . -read "/Users/$login" UniqueID >/dev/null 2>&1; then
    sudo -n dscl . -delete "/Users/$login" || :
  fi
  if dscl . -read "/Users/$login" UniqueID >/dev/null 2>&1; then
    say "login $login is still on this machine (deleteUser and dscl -delete over ssh)"
    exit 1
  fi
  for g in $(dscl . -list /Groups 2>/dev/null | grep '^com\.apple\.access_' || :); do
    acl_values "$g" GroupMembership | grep -Fxq -- "$login" && { sudo -n dscl . -delete "/Groups/$g" GroupMembership "$login" || :; }
    [ -n "$guid" ] && acl_values "$g" GroupMembers | grep -Fxq -- "$guid" && { sudo -n dscl . -delete "/Groups/$g" GroupMembers "$guid" || :; }
  done
  say "deleted $login"
  exit 0
}

forced() {
  # Never a shell: the words are split here, and only these two shapes pass.
  local cmd=${SSH_ORIGINAL_COMMAND:-} a b c
  case "$cmd" in *[!a-z0-9_\ -]*) die "refusing: '$cmd' is not 'probe' or 'delete <login>'" 2 ;; esac
  read -r a b c <<<"$cmd"
  case "$a:${b:+1}:${c:+1}" in
    probe::) if has_fda; then echo 'fda: yes'; exit 0; else say "$WHY_FDA"; exit 7; fi ;;
    delete:1:) forced_delete "$b" ;;
    *) die "refusing: '$cmd' is not 'probe' or 'delete <login>'" 2 ;;
  esac
}

# ------------------------------------------------------------------- setup --
admin_home() {
  local h
  h=$(dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '$1=="NFSHomeDirectory:" {print $2; exit}')
  [ -n "$h" ] || h="$HOMES/$1"
  printf '%s\n' "$h"
}

# The command= runs through the admin's login shell: the path is single-quoted
# for it ("Application Support" has a space), bash named so no exec bit counts.
key_line() {
  printf 'from="127.0.0.1,::1",restrict,command="/bin/bash '"'"'%s'"'"' forced" %s %s\n' \
    "$FORCED" "$(awk '{print $1, $2}' "$KEY.pub")" "$MARK"
}

setup() {
  need_root setup
  admin_arg "$@"
  local h ssh ak line tmp hk
  case "$FORCED" in *[\'\"\\]*) die "refusing: a quote in $FORCED" 3 ;; esac
  id -u "$ADMIN" >/dev/null 2>&1 || die "no login $ADMIN" 2
  install -d -m 700 "$DIR" || die "cannot make $DIR" 1
  if [ ! -f "$KEY" ] || [ ! -f "$KEY.pub" ]; then
    rm -f "$KEY" "$KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C "$MARK" -f "$KEY" </dev/null >/dev/null || die "ssh-keygen failed" 1
    say "made $KEY"
  fi
  chmod 600 "$KEY"
  # known_hosts from the host's own keys: exact, never trust-on-first-use
  tmp=$(mktemp "$DIR/.known.XXXXXX") || die "mktemp in $DIR" 1
  for hk in "$HOSTKEYS"/ssh_host_*_key.pub; do
    [ -f "$hk" ] && awk 'NF >= 2 {print "127.0.0.1,::1", $1, $2}' "$hk"
  done > "$tmp"
  if [ ! -s "$tmp" ]; then rm -f "$tmp"; die "no host key under $HOSTKEYS (Remote Login never on?)" 5; fi
  if cmp -s "$tmp" "$KNOWN"; then rm -f "$tmp"; else chmod 644 "$tmp" && mv -f "$tmp" "$KNOWN"; fi
  h=$(admin_home "$ADMIN"); ssh="$h/.ssh"; ak="$ssh/authorized_keys"
  [ -d "$h" ] && [ ! -L "$h" ] || die "no home for $ADMIN at $h" 1
  [ ! -L "$ssh" ] && [ ! -L "$ak" ] || die "refusing: symlinked $ssh" 3
  line=$(key_line)
  if [ -f "$ak" ] && grep -Fxq -- "$line" "$ak" && [ "$(grep -c " $MARK\$" "$ak")" = 1 ]; then
    echo "$PROG: ready ($ADMIN, $ak)"; return 0
  fi
  if [ ! -d "$ssh" ]; then
    mkdir -m 700 "$ssh" || die "cannot make $ssh" 1
    [ "${FLEET_REMOVE_SSH_TEST:-0}" = 1 ] || chown "$ADMIN" "$ssh"
  fi
  tmp=$(mktemp "$ssh/.authorized_keys.XXXXXX") || die "mktemp in $ssh" 1
  { [ ! -f "$ak" ] || grep -v " $MARK\$" "$ak"; printf '%s\n' "$line"; } > "$tmp"
  chmod 600 "$tmp"
  [ "${FLEET_REMOVE_SSH_TEST:-0}" = 1 ] || chown "$ADMIN" "$tmp"
  mv -f "$tmp" "$ak" || { rm -f "$tmp"; die "cannot write $ak" 1; }
  echo "$PROG: authorized for $ADMIN ($ak)"
}

# --------------------------------------------------------------- probe/run --
ssh_to() {
  ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
      -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" -o GlobalKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o LogLevel=ERROR -F /dev/null "$ADMIN@127.0.0.1" "$@"
}

# road <words…>: one call over the road; an ssh-level failure (255) is read into
# the reason a person acts on, exit 5.
road() {
  local err rc
  [ -f "$KEY" ] || { say "no key $KEY — run: sudo $FORCED setup --admin $ADMIN"; return 5; }
  err=$(mktemp "${TMPDIR:-/tmp}/$PROG.XXXXXX") || return 1
  ssh_to "$@" 2>"$err"; rc=$?
  if [ "$rc" = 255 ]; then
    if grep -qi 'connection refused\|connect to host' "$err"; then say "$WHY_OFF"
    elif grep -qi 'permission denied' "$err"; then
      say "$ADMIN@127.0.0.1 did not take the key — run: sudo $FORCED setup --admin $ADMIN (and $ADMIN must be allowed by Remote Login)"
    elif grep -qi 'host key' "$err"; then say "127.0.0.1's host key is not the one in $KNOWN — run setup again"
    else say "ssh to $ADMIN@127.0.0.1 failed: $(head -n 1 "$err")"; fi
    rm -f "$err"; return 5
  fi
  sed '/^$/d' "$err" >&2; rm -f "$err"
  return "$rc"
}

probe() { need_root probe; admin_arg "$@"; road probe >/dev/null; }

run_delete() {
  need_root run
  local login=${1:-}; shift || :
  valid_login "$login" || die "run <login>: a plain login name" 2
  admin_arg "$@"
  road delete "$login"
}

case "${1:-}" in
  forced) forced ;;
  setup) shift; setup "$@" ;;
  probe) shift; probe "$@" ;;
  run) shift; run_delete "$@" ;;
  *) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
