#!/bin/bash
# fleet-login-new.sh <login> --full-name <name> --pubkey <file> [--share-pool]
#                    [--pool-src <dir>] [--machine <name>] [--apply]
#   — open a new person's OS login on a shared machine in ONE command
#     (issue #1164, EPIC #1163).
#
# docs/SHARED-MACHINE.md steps 1–2b used to be ~7 hand-typed admin commands
# spread over two docs; a missed chown or group membership meant the person
# could not log in, or could not use the pool, and the admin had to go hunting.
# This script is those steps, in order:
#
#   1. sudo sysadminctl -addUser <login> -fullName <name> -password -
#                                     (prompts for the new password)
#   2. sudo createhomedir -c -u <login>          (the home, so step 4 has a place)
#   3. sudo dseditgroup … com.apple.access_ssh   (only when that group exists —
#                                     without it Remote Login admits every user)
#   4. ~/.ssh/authorized_keys ← --pubkey, .ssh 700 / key file 600, owned by <login>
#   5. --share-pool: every Claude pool token + its <label>.conf from --pool-src
#      (default: YOUR accounts dir) → ~<login>/.config/claude-fleet/accounts,
#      dir 700 / files 600, owned by <login> — SHARED-MACHINE step 2b. Never
#      ~/.codex/auth.json: Codex rotates its refresh token, so the new login gets
#      its own device-code session instead (printed as a manual step).
#
# and then prints what only a human can do (first GUI login, the Codex device
# code, the person's own `gh auth login`, the ccquota enrollment).
#
# DEFAULT IS A DRY RUN: it prints every command it would run and runs none.
# --apply runs them, stopping at the first failure. Run it as the admin login,
# NOT under sudo — it sudo's each step itself, and your $HOME is where the pool
# comes from.
#
# Only ever ADDS: it refuses (exit 3) when the login or its home already exists,
# never overwrites, and writes nothing in the new home outside `.ssh/` and
# `.config/claude-fleet/accounts/` (plus owning the `.config` dirs it creates).
#
# Exit: 0 ok · 1 a step failed under --apply · 2 bad arguments · 3 the login
#       (or its home) already exists
#
# Env (tests): FLEET_LOGIN_HOMES (default /Users) — the homes root.
set -u

PROG=fleet-login-new
usage() {
  sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

LOGIN='' FULL='' PUBKEY='' SHARE=0 APPLY=0 MACHINE=mini POOL_SRC=''
while [ $# -gt 0 ]; do
  case "$1" in
    --full-name) [ $# -ge 2 ] || usage; FULL=$2; shift 2 ;;
    --pubkey)    [ $# -ge 2 ] || usage; PUBKEY=$2; shift 2 ;;
    --pool-src)  [ $# -ge 2 ] || usage; POOL_SRC=$2; shift 2 ;;
    --machine)   [ $# -ge 2 ] || usage; MACHINE=$2; shift 2 ;;
    --share-pool) SHARE=1; shift ;;
    --apply)     APPLY=1; shift ;;
    -h|--help)   sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*)          die2 "unknown option: $1" ;;
    *)           [ -z "$LOGIN" ] || die2 "one login at a time (got '$LOGIN' and '$1')"
                 LOGIN=$1; shift ;;
  esac
done

[ -n "$LOGIN" ] || usage
printf '%s' "$LOGIN" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' \
  || die2 "bad login name '$LOGIN' (lowercase letters, digits, _ and -; at most 32)"
[ -n "$FULL" ] || die2 "--full-name is required"
[ -n "$PUBKEY" ] || die2 "--pubkey <file> is required"
[ -r "$PUBKEY" ] || die2 "--pubkey: cannot read '$PUBKEY'"
[ "$EUID" != 0 ] || die2 "run this as the admin login, not under sudo — it sudo's each step itself"

KEYS=$(grep -Ec '^(ssh-|ecdsa-|sk-)' "$PUBKEY" 2>/dev/null) || KEYS=0
if [ "$KEYS" -eq 0 ] && [ "$APPLY" = 1 ]; then
  die2 "--pubkey '$PUBKEY' holds no public key line (ssh-… / ecdsa-… / sk-…)"
fi

HOMES=${FLEET_LOGIN_HOMES:-/Users}
H="$HOMES/$LOGIN"

# The pool: every regular file but dotfiles and editor backups — i.e. each
# <label> token AND its <label>.conf (fleet-account.sh's acct_labels, .conf kept).
POOL=()
if [ "$SHARE" = 1 ]; then
  [ -n "$POOL_SRC" ] || POOL_SRC="${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/accounts}"
  [ -d "$POOL_SRC" ] || die2 "--share-pool: no pool at '$POOL_SRC' (--pool-src <dir>)"
  for f in "$POOL_SRC"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in .*|*~) continue ;; esac
    POOL+=("$f")
  done
  [ "${#POOL[@]}" -gt 0 ] || die2 "--share-pool: '$POOL_SRC' holds no tokens"
fi

# Refuse, never overwrite (exit 3) — checked in both modes, so a dry run that
# looks clean is one --apply will actually carry out.
if id "$LOGIN" >/dev/null 2>&1; then
  printf '%s: login %s already exists — refusing (this script only adds)\n' "$PROG" "$LOGIN" >&2
  exit 3
fi
if [ -e "$H" ]; then
  printf '%s: %s already exists (no such login) — refusing to write into it\n' "$PROG" "$H" >&2
  exit 3
fi

if [ "$APPLY" = 1 ]; then
  for t in sudo sysadminctl createhomedir; do
    command -v "$t" >/dev/null 2>&1 || { printf '%s: %s not found — nothing was changed\n' "$PROG" "$t" >&2; exit 1; }
  done
fi

SSH_GROUP=com.apple.access_ssh
HAVE_SSH_GROUP=0
dscl . -read "/Groups/$SSH_GROUP" >/dev/null 2>&1 && HAVE_SSH_GROUP=1

N=0
say() { printf '%s\n' "$*"; }
show() { local q; q=$(printf '%q ' "$@"); printf '  $ %s\n' "${q% }"; }
fail() { printf '%s: FAILED at step %s — stopped; nothing after it ran\n' "$PROG" "$N" >&2; exit 1; }
# run <argv…>: print, and under --apply execute.
run() { show "$@"; [ "$APPLY" = 1 ] || return 0; "$@" || fail; }
# append <src> <dst>: sudo tee -a <dst> < <src>
append() {
  local q; q=$(printf "%q " sudo tee -a "$2")
  printf "  \$ %s < %s\n" "${q% }" "$(printf %q "$1")"
  [ "$APPLY" = 1 ] || return 0
  # shellcheck disable=SC2024  # the key is read as the admin on purpose; only the write needs root
  sudo tee -a "$2" < "$1" >/dev/null || fail
}
step() { N=$((N + 1)); say ""; say "[$N] $*"; }

if [ "$APPLY" = 1 ]; then
  say "fleet-login-new: creating login '$LOGIN' ($FULL) — running each step:"
else
  say "fleet-login-new: DRY RUN — nothing below is executed. Re-run with --apply to do it."
fi
say "  login=$LOGIN  full-name=$FULL  home=$H  share-pool=$([ "$SHARE" = 1 ] && echo yes || echo no)"
[ "$KEYS" -gt 0 ] || say "  WARN: --pubkey '$PUBKEY' holds no public key line; --apply will refuse it"

step "create the OS login (prompts for the new password)"
run sudo sysadminctl -addUser "$LOGIN" -fullName "$FULL" -password -
step "create its home directory"
run sudo createhomedir -c -u "$LOGIN"

step "allow SSH (Remote Login)"
if [ "$HAVE_SSH_GROUP" = 1 ]; then
  run sudo dseditgroup -o edit -a "$LOGIN" -t user "$SSH_GROUP"
else
  say "  (skipped: no $SSH_GROUP group — Remote Login is open to all users)"
fi

step "install the public key ($KEYS key line(s) from $PUBKEY)"
run sudo mkdir -p "$H/.ssh"
append "$PUBKEY" "$H/.ssh/authorized_keys"
run sudo chown -R "$LOGIN:staff" "$H/.ssh"
run sudo chmod 700 "$H/.ssh"
run sudo chmod 600 "$H/.ssh/authorized_keys"

if [ "$SHARE" = 1 ]; then
  D="$H/.config/claude-fleet/accounts"
  step "join the shared Claude pool (${#POOL[@]} files from $POOL_SRC — SHARED-MACHINE 2b)"
  DST=()
  for f in ${POOL[@]+"${POOL[@]}"}; do DST+=("$D/${f##*/}"); done
  run sudo mkdir -p "$D"
  run sudo cp -p ${POOL[@]+"${POOL[@]}"} "$D/"
  run sudo chown "$LOGIN:staff" "$H/.config" "$H/.config/claude-fleet"
  run sudo chown -R "$LOGIN:staff" "$D"
  run sudo chmod 700 "$D"
  run sudo chmod 600 ${DST[@]+"${DST[@]}"}
fi

say ""
if [ "$APPLY" = 1 ]; then
  say "done: login '$LOGIN' created. Left for a human:"
else
  say "after --apply, left for a human:"
fi
say "  1. sign in as $LOGIN ONCE in the GUI (console or Screen Sharing) — creates the"
say "     login Keychain and the gui/<uid> launchd domain the ccquota agent needs"
say "  2. as $LOGIN: ccquota codex login personal --device-auth   — approve the device code"
say "     (never copy ~/.codex/auth.json between logins)"
say "  3. as $LOGIN: gh auth login   — their own GitHub identity"
say "  4. on the hub: ccquota enroll --name $MACHINE-$LOGIN   — give $LOGIN the token privately"
say "     (then docs/SHARED-MACHINE.md steps 4–5: ccquota agent + install claude-fleet)"
exit 0
